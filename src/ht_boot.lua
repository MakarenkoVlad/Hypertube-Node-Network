--[[
  HT Boot — node bootstrap + over-the-air firmware updates. (CC: Tweaked)
  ===========================================================================
  Install this as `startup` on every node, ONCE. After that you never visit a
  node to change code again: it runs the node's firmware and listens on the
  ender-modem network for pushed updates. An update replaces the firmware CODE
  only — this node's config lives in a SEPARATE file and is left untouched.

  Files on each node:
    /startup       this bootstrap
    /firmware.lua  the node program (ht_node.lua, identical on every node)
    /ht_node.cfg   this node's name + tube map (written by first-boot setup)
    /ht_group      (optional) one word; updates can target a group, or "all"

  Push updates from any computer with an ender modem using ht_push.lua.
--]]

local PROTO = "ht_ota"
local FW    = "/firmware.lua"

-- ---- tiny fs/util --------------------------------------------------------
local function readAll(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r"); local s = f.readAll(); f.close(); return s
end
local function writeAll(p, s)
  local f = fs.open(p, "w"); f.write(s); f.close()
end

local GROUP = (readAll("/ht_group") or "all"):gsub("%s+", "")
if GROUP == "" then GROUP = "all" end

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
        writeAll(FW, msg.code)
        print("[OTA] rebooting into new firmware...")
        sleep(0.5); os.reboot()
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
if openModem() then
  parallel.waitForAny(runFirmware, otaListener)
else
  print("[warn] no modem - running firmware only, no remote updates.")
  runFirmware()
end
