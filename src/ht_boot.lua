--[[
  HT Boot — node bootstrap + firmware auto-update. (CC: Tweaked)
  ===========================================================================
  Install this as `startup` on every node, ONCE - then it keeps ITSELF and the
  firmware up to date forever (config /ht_node.cfg is never touched):

    1. AUTO-UPDATE FROM GITHUB: at boot AND every UPDATE_CHECK seconds while
       running, the node fetches the latest firmware (ht_node.lua) AND this
       bootstrap (ht_boot.lua), installing either if it's a newer version and
       rebooting itself. So a single `git push` propagates to every node -
       INCLUDING bootstrap changes - with no per-node visits or hand reboots.
       Drop a /ht_pin file to freeze a node on its current code.
    2. RENDET PUSH (instant, optional): `ht_push.lua` broadcasts firmware to
       nodes that are loaded RIGHT NOW.

  SAFETY: a fetched file is installed only if it contains its marker, its
  end-of-file sentinel is present in the file's TAIL (rejects a truncated
  download), it COMPILES, and its version is strictly newer; it's staged to a
  temp file and verified before swapping into place. So a bad download can't
  brick a node. Bump BVERSION whenever you change this file.

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

local BVERSION = "b2"   -- bootstrap version; bump when ht_boot.lua changes so it self-updates like firmware
local PROTO = "ht_ota"
local FW    = "/firmware.lua"
local BASE  = "https://raw.githubusercontent.com/MakarenkoVlad/Hypertube-Node-Network/main/"

-- ---- tiny fs/util --------------------------------------------------------
local function readAll(p)   -- never throws (returns nil on any fs error)
  if not fs.exists(p) then return nil end
  local ok, s = pcall(function() local f = fs.open(p, "r"); local s = f.readAll(); f.close(); return s end)
  return ok and s or nil
end
local function writeAll(p, s)   -- returns true on success; NEVER throws (a disk error must not crash the node)
  return pcall(function() local f = fs.open(p, "w"); f.write(s); f.close() end)
end

local GROUP   -- this node's optional OTA update-group; assigned in the boot section, used by otaListener.

-- ---- self-update (firmware AND this bootstrap) ---------------------------
local SENTINEL  = "@HT-NODE-EOF"          -- ht_node.lua's last line; required in the TAIL -> COMPLETE download
local BSENTINEL = "@HT-BOOT-" .. "EOF"    -- ht_boot.lua's end marker. Built by CONCAT so the full
                                          -- marker string appears ONLY in the end-of-file line and
                                          -- never here - else a truncation ending after this line
                                          -- would still contain it and wrongly pass as complete.
local UPDATE_CHECK = 300           -- seconds between online checks WHILE running (chunk-loaded nodes
                                   -- update with no manual reboot). ht_push is the instant alternative.

local function versionOf(t)  if type(t) ~= "string" then return 0 end return tonumber(t:match('VERSION%s*=%s*"v(%d+)"')) or 0 end
local function bversionOf(t) if type(t) ~= "string" then return 0 end return tonumber(t:match('BVERSION%s*=%s*"b(%d+)"')) or 0 end

-- bounded HTTP GET: returns the body, or nil on failure/timeout. NEVER hangs (a dead/slow host times out).
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

-- Generic SAFE self-update of one file. Fetch `url`; install to `path` ONLY if the body is a COMPLETE
-- download (contains `marker`, AND `sentinel` is found in the file's TAIL so a truncated transfer is
-- rejected - a tail check, because the sentinel literal can appear earlier in this very bootstrap) AND
-- compiles AND is strictly newer (or `path` is compile-broken/missing -> self-heal). Returns
-- (installed?, newV, wasBroken). The install is an in-place truncate-write + byte-verify: writeAll reuses
-- the file's OWN disk space (so it's robust to disk-full) and never leaves the path MISSING - so a bad
-- download or disk hiccup can't brick a node. (NOTE: self-heal only catches files that won't COMPILE; a
-- file that compiles but errors at runtime needs a version BUMP to replace.)
local function tryUpdateFile(path, url, marker, sentinel, verOf)
  if fs.exists("/ht_pin") then return false end
  local code = httpGet(url .. "?t=" .. tostring(os.epoch("utc")), 8)   -- ?t= dodges the CDN cache
  if type(code) ~= "string" or not code:find(marker, 1, true) then return false end
  if not code:sub(-256):find(sentinel, 1, true) or not load(code) then return false end   -- truncated / invalid
  local cur = readAll(path)
  if code == cur then return false end                          -- already this exact file
  local curBroken = type(cur) ~= "string" or not load(cur)      -- compile-broken or missing
  local newV, curV = verOf(code), curBroken and -1 or verOf(cur)
  if newV <= curV then return false end
  if not writeAll(path, code) then return false end             -- in-place truncate-write (reuses own space)
  if readAll(path) ~= code then return false end                -- verify EXACT bytes landed
  return true, newV, curBroken
end

local function tryUpdate()     return tryUpdateFile(FW,         BASE .. "src/ht_node.lua", "HT Node", SENTINEL,  versionOf)  end
local function tryUpdateBoot() return tryUpdateFile("/startup", BASE .. "src/ht_boot.lua", "HT Boot", BSENTINEL, bversionOf) end

-- Update checks run HERE, in the background under parallel - NEVER blocking boot. Their HTTP fetches can
-- be slow or time out (8s each), but because this runs as a coroutine alongside the firmware, that delay
-- doesn't hold up a freshly chunk-loaded node from routing (it's live in ~1s, not ~16s waiting on GitHub).
-- First check is a few seconds after boot so updates still propagate; then every UPDATE_CHECK seconds.
local function autoUpdateLoop()
  sleep(3)                                   -- let the firmware boot + catch any approaching rider FIRST
  while true do
    local okB, didB = pcall(tryUpdateBoot)   -- pcall: a throw here must never kill the node (it's under parallel)
    if okB and didB then print("[auto-update] new bootstrap is live - rebooting..."); sleep(0.5); os.reboot() end
    local okF, didF, newV = pcall(tryUpdate)
    if okF and didF then print(("[auto-update] firmware v%d is live - rebooting..."):format(newV or 0)); sleep(0.5); os.reboot() end
    sleep(UPDATE_CHECK)
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
-- Start the firmware IMMEDIATELY; every GitHub update check (bootstrap AND firmware) happens in the
-- background autoUpdateLoop under parallel. So a node that chunk-loads as a rider approaches is routing in
-- ~1s instead of blocking ~16s on two HTTP fetches that may time out (which is what dropped riders at the
-- hops loading just-in-time ahead of them). Updates still propagate - the loop checks a few seconds in.
GROUP = (readAll("/ht_group") or "all"):gsub("%s+", "")
if GROUP == "" then GROUP = "all" end
print("HT node boot " .. BVERSION .. " (group " .. GROUP .. ").")
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
-- The line below must stay LAST: this bootstrap self-updates and checks for this marker in the
-- file's TAIL to confirm a complete download before replacing /startup. Add nothing after it.
-- @HT-BOOT-EOF
