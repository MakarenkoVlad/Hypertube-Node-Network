--[[
  HT Boot — node bootstrap + firmware auto-update. (CC: Tweaked)
  ===========================================================================
  Install this as `startup` on every node, ONCE. After that you never visit a
  node to change code again. Two update paths, both keep this node's config
  (/ht_node.cfg) untouched - they only swap the firmware CODE:

    1. AUTO-UPDATE FROM GITHUB: at boot AND every UPDATE_CHECK seconds while
       running, the node fetches the latest firmware and installs it IF it's a
       newer version - rebooting itself when it updates while running. So a
       single `git push` propagates to every node (chunk-loaded ones within a
       few minutes, the rest as their chunks load) - no per-node visits, no
       reboots by hand. Drop a /ht_pin file to freeze a node on its firmware.
    2. RENDET PUSH (instant, optional): `ht_push.lua` broadcasts to nodes that
       are loaded RIGHT NOW.

  Auto-update is FORWARD-ONLY (installs only a strictly-newer version). To roll
  back, push a HIGHER version number that contains the old code - an ht_push of
  an older version is reverted by the next GitHub check.

  Files on each node:
    /startup       this bootstrap
    /firmware.lua  the node program (ht_node.lua, identical on every node)
    /ht_node.cfg   this node's name + tube map (written by first-boot setup)
    /ht_group      (optional) one word; rednet pushes can target a group, or "all"
    /ht_pin        (optional) if present, this node skips GitHub auto-update
--]]

local PROTO = "ht_ota"
local FW    = "/firmware.lua"
local BASE  = "https://raw.githubusercontent.com/MakarenkoVlad/Hypertube-Node-Network/main/"

-- ---- tiny fs/util --------------------------------------------------------
local function readAll(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r"); local s = f.readAll(); f.close(); return s
end
local function writeAll(p, s)   -- returns true on success; NEVER throws (a disk error must not crash the node)
  return pcall(function() local f = fs.open(p, "w"); f.write(s); f.close() end)
end

local GROUP = (readAll("/ht_group") or "all"):gsub("%s+", "")
if GROUP == "" then GROUP = "all" end

-- ---- auto-update on boot -------------------------------------------------
-- The "v18" in `local VERSION = "v18"` -> the number 18, for comparing builds.
local function versionOf(text)
  if type(text) ~= "string" then return 0 end
  return tonumber(text:match('VERSION%s*=%s*"v(%d+)"')) or 0
end

-- bounded HTTP GET: returns the body, or nil on failure/timeout. NEVER hangs boot
-- (a dead/slow host just times out and the node runs its existing firmware).
local function httpGet(url, secs)
  if not http or not pcall(http.request, url) then return nil end
  local timer = os.startTimer(secs or 8)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "http_success" and ev[2] == url then
      local body = ev[3].readAll(); ev[3].close(); return body
    elseif ev[1] == "http_failure" and ev[2] == url then return nil
    elseif ev[1] == "timer" and ev[2] == timer then return nil end
  end
end

local SENTINEL = "@HT-NODE-EOF"   -- ht_node.lua's last line; its presence proves a COMPLETE download
local UPDATE_CHECK = 300          -- seconds between online checks WHILE running (so a chunk-loaded node
                                  -- updates itself with no reboot). ht_push gives an instant alternative.

-- Fetch the latest firmware from GitHub and install it IF it's a valid, complete, strictly-newer build
-- (or repairs a broken one). Returns (installed?, newVersion). Heavily guarded so a partial/garbage
-- download can NEVER brick a node:
--   * skipped if /ht_pin exists;
--   * the body must look like our firmware, END WITH the sentinel (rejects a truncated transfer), AND
--     compile as valid Lua;
--   * the write is VERIFIED before reporting success, so a failed write can't trigger a reboot loop.
local function tryUpdate()
  if fs.exists("/ht_pin") then return false end
  local code = httpGet(BASE .. "src/ht_node.lua?t=" .. tostring(os.epoch("utc")), 8)  -- ?t= dodges the CDN cache
  if type(code) ~= "string" or not code:find("HT Node", 1, true) then return false end
  local cur = readAll(FW)
  if code == cur then return false end                          -- already running this exact firmware
  if not code:find(SENTINEL, 1, true) or not load(code) then return false end   -- truncated / invalid
  local curBroken = type(cur) ~= "string" or not load(cur)      -- installed firmware won't compile
  local newV, curV = versionOf(code), curBroken and -1 or versionOf(cur)
  if newV <= curV then return false end
  if not writeAll(FW, code) then return false end               -- write failed (disk) -> don't claim success
  if readAll(FW) ~= code then return false end                  -- verify EXACT bytes landed (catches a truncated write)
  return true, newV, curBroken
end

-- boot-time: install a newer firmware BEFORE running it (no reboot needed - we run the new code).
local function autoUpdate()
  local ok, newV, broken = tryUpdate()
  if ok then print(broken and "[auto-update] repaired firmware." or ("[auto-update] firmware -> v%d (from GitHub)"):format(newV)) end
end

-- runtime: while the node is chunk-loaded, poll GitHub; when a newer firmware lands, install it and
-- reboot INTO it - so an always-loaded node updates itself with NO manual reboot.
local function autoUpdateLoop()
  while true do
    sleep(UPDATE_CHECK)
    local ok, newV = tryUpdate()
    if ok then print(("[auto-update] v%d is live - rebooting into it..."):format(newV)); sleep(0.5); os.reboot() end
  end
end

-- ---- modem ---------------------------------------------------------------
local function openModem()
  for _, n in ipairs(peripheral.getNames()) do          -- prefer wireless (ender)
    if peripheral.hasType(n, "modem") then
      local p = peripheral.wrap(n)
      if p and p.isWireless and p.isWireless() then rednet.open(n); return true end
    end
  end
  for _, n in ipairs(peripheral.getNames()) do           -- else any modem
    if peripheral.hasType(n, "modem") then rednet.open(n); return true end
  end
  return false
end

-- ---- the two parallel jobs -----------------------------------------------
-- An update is a whole-file replace: the firmware is identical on every node and
-- the per-node config (/ht_node.cfg) is a separate file the update never touches.
local function otaListener()
  while true do
    local _, msg = rednet.receive(PROTO)
    if type(msg) == "table" and msg.type == "HT_UPDATE" and type(msg.code) == "string" then
      local g = msg.group or "all"
      if g == "all" or g == GROUP then
        print("[OTA] update received (group " .. g .. ") - config in /ht_node.cfg is kept.")
        if writeAll(FW, msg.code) and readAll(FW) == msg.code then   -- crash-safe + verify the write landed
          print("[OTA] rebooting into new firmware...")
          sleep(0.5); os.reboot()
        else
          print("[OTA] write failed - keeping current firmware.")
        end
      end
    end
  end
end

local function runFirmware()
  if not fs.exists(FW) then
    print("No " .. FW .. " yet. Waiting for first install or OTA push (group " .. GROUP .. ")...")
    while true do os.pullEvent("ht_idle") end             -- block; let the OTA job run
  end
  local ok, err = pcall(function() shell.run(FW) end)
  if not ok then printError("firmware error: " .. tostring(err)) end
  printError("firmware stopped - OTA still listening. Push a fix to recover.")
  while true do os.pullEvent("ht_idle") end
end

-- ---- boot ----------------------------------------------------------------
print("HT node boot (group " .. GROUP .. ").")
autoUpdate()    -- self-update from GitHub if a newer firmware was pushed (propagates on chunk load)
-- First boot: run the firmware's SETUP blocking (NOT under parallel) so its
-- on-screen typing works normally; it writes /ht_node.cfg and exits.
if fs.exists(FW) and not fs.exists("/ht_node.cfg") then
  print("First-time setup - type your answers on this screen:")
  shell.run(FW, "setup")                       -- runs ALONE here; the OTA listener
  if fs.exists("/ht_node.cfg") then            -- below hasn't started yet, so your
    print("Setup saved - rebooting...")        -- keystrokes can't be stolen.
    sleep(1); os.reboot()
  end
end
-- Run the firmware alongside: the rednet OTA listener (instant pushes) and the GitHub
-- auto-update poller (keeps a chunk-loaded node current with no manual reboot).
if openModem() then
  parallel.waitForAny(runFirmware, otaListener, autoUpdateLoop)
else
  print("[warn] no modem - no rednet OTA (GitHub auto-update still on).")
  parallel.waitForAny(runFirmware, autoUpdateLoop)
end
