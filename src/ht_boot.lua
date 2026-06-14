--[[
  HT Boot — node bootstrap + over-the-air firmware updates. (CC: Tweaked)
  ===========================================================================
  Install this as `startup` on every node, ONCE. After that you never visit a
  node to change code again: it runs the node's firmware and listens on the
  ender-modem network for pushed updates. When an update arrives it keeps THIS
  node's own config and only swaps the code, then reboots.

  Files on each node:
    /startup       this bootstrap
    /firmware.lua  the node program (hypertube_node.lua spliced with this node's
                   config between the @HT-CONFIG markers). Pushed updates replace
                   the code around those markers but keep the config inside them.
    /ht_group      (optional) one word; updates can target a group, or "all".

  Push updates from any computer with an ender modem using ht_push.lua.
--]]

local PROTO = "ht_ota"
local FW    = "/firmware.lua"
local START_MARK, END_MARK = "@HT-CONFIG-START", "@HT-CONFIG-END"

-- ---- tiny fs/util --------------------------------------------------------
local function readAll(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r"); local s = f.readAll(); f.close(); return s
end
local function writeAll(p, s)
  local f = fs.open(p, "w"); f.write(s); f.close()
end
local function lines(s)
  local t = {} for l in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end return t
end

local GROUP = (readAll("/ht_group") or "all"):gsub("%s+", "")
if GROUP == "" then GROUP = "all" end

-- ---- config-preserving splice --------------------------------------------
-- pull the text BETWEEN this node's config markers (its per-node settings)
local function extractConfig(text)
  local L = lines(text); local s, e
  for i, l in ipairs(L) do
    if not s and l:find(START_MARK, 1, true) then s = i end
    if not e and l:find(END_MARK, 1, true) then e = i end
  end
  if not s or not e or s >= e then return nil end
  local out = {} for i = s + 1, e - 1 do out[#out + 1] = L[i] end
  return table.concat(out, "\n")
end

-- put a config block into NEW firmware between its markers, keeping the markers
local function splice(newfw, configText)
  local L = lines(newfw); local s, e
  for i, l in ipairs(L) do
    if not s and l:find(START_MARK, 1, true) then s = i end
    if not e and l:find(END_MARK, 1, true) then e = i end
  end
  if not s or not e or s >= e then return nil end
  local out = {}
  for i = 1, s do out[#out + 1] = L[i] end       -- up to & incl. START
  out[#out + 1] = configText
  for i = e, #L do out[#out + 1] = L[i] end        -- END onward
  return table.concat(out, "\n")
end

local function applyUpdate(newCode)
  local current = readAll(FW)
  local cfg = current and extractConfig(current) or nil
  local merged = newCode
  if cfg then
    local m = splice(newCode, cfg)               -- keep our config, take their code
    if m then merged = m end
  end
  writeAll(FW, merged)
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
local function otaListener()
  while true do
    local _, msg = rednet.receive(PROTO)
    if type(msg) == "table" and msg.type == "HT_UPDATE" and type(msg.code) == "string" then
      local g = msg.group or "all"
      if g == "all" or g == GROUP then
        print("[OTA] update received (group " .. g .. ") - keeping local config...")
        applyUpdate(msg.code)
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
  shell.run(FW, "setup")
end
if openModem() then
  parallel.waitForAny(runFirmware, otaListener)
else
  print("[warn] no modem - running firmware only, no remote updates.")
  runFirmware()
end
