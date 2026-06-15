--[[
  HT Push — send a firmware update to every node over rednet. (CC: Tweaked)
  ===========================================================================
  Run on any computer that has an ender modem. Reads a firmware file and
  broadcasts it; each node replaces its code and reboots (see ht_boot.lua). The
  per-node config (/ht_node.cfg) is a separate file and is left untouched, so no
  node needs visiting.

  NOTE: this only reaches nodes whose chunks are currently LOADED. Visit-update
  any that were offline with:  wget <raw>/src/ht_node.lua firmware.lua && reboot

  Usage:
    ht_push <firmware.lua> [group]
      <firmware.lua>  the new node firmware (usually ht_node.lua fetched as firmware.lua)
      [group]         only update nodes whose /ht_group matches (default: all)

  Example:
    ht_push firmware.lua            -- update every loaded node
    ht_push firmware.lua junction   -- update only nodes tagged "junction"
--]]

local PROTO = "ht_ota"
local args = { ... }
local src, group = args[1], args[2] or "all"

if not src then
  print("usage: ht_push <firmware.lua> [group]")
  return
end
if not fs.exists(src) then
  printError("No such file: " .. src)
  return
end

local f = fs.open(src, "r"); local code = f.readAll(); f.close()

local opened = false
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.hasType(n, "modem") then rednet.open(n); opened = true; break end
end
if not opened then
  printError("No modem on this computer - attach one to broadcast.")
  return
end

rednet.broadcast({ type = "HT_UPDATE", group = group, code = code }, PROTO)
print(("Pushed %s (%d bytes) to group '%s'."):format(src, #code, group))
print("Loaded nodes will reboot into the new firmware; their config is preserved.")
