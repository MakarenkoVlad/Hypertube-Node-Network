--[[
  HT Push — send a firmware update to every node over rednet. (CC: Tweaked)
  ===========================================================================
  Run on any computer that has an ender modem. Reads a firmware file and
  broadcasts it; each node keeps its own config and reboots into the new code
  (see ht_boot.lua). No need to visit nodes.

  Usage:
    ht_push <firmware.lua> [group]
      <firmware.lua>  the new node firmware (must contain the @HT-CONFIG markers)
      [group]         only update nodes whose /ht_group matches (default: all)

  Example:
    ht_push firmware.lua            -- update every node
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

if not code:find("@HT-CONFIG-START", 1, true) then
  -- No markers: the unified ht_node.lua model, whose config lives in a separate
  -- /ht_node.cfg the update never touches. Whole-file replace is correct here.
  print("note: no @HT-CONFIG markers - nodes will replace the whole firmware.")
  print("(fine for ht_node.lua; its config is in /ht_node.cfg and is preserved.)")
end

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
print("Matching nodes will keep their config and reboot into the new firmware.")
