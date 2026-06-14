--[[
  HT Installer — one command sets up ANY node. (CC: Tweaked)
  ===========================================================================
  Every node gets the SAME firmware (ht_node.lua); it figures out the rest on
  first boot (name + tube calibration) and self-organizes the routing. So this
  installer takes no node id — run the same line on every computer.

  EDIT `BASE` to your raw repo URL (ends with a slash), e.g.
    https://raw.githubusercontent.com/<user>/<repo>/main/

  Then on each node:
    wget run BASE/installer.lua            -- a normal node
    wget run BASE/installer.lua junction   -- optional: tag an update group
  After this, code updates arrive over the air (ht_push). You never run this
  again unless you add a brand-new computer.
--]]

local BASE = "https://raw.githubusercontent.com/MakarenkoVlad/Hypertube-Node-Network/main/"

local args  = { ... }
local group = args[1]   -- optional update-group tag

local function fetch(path, dest, required)
  io.write("  " .. path .. " ... ")
  local res = http and http.get(BASE .. path)
  if not res then
    if required then error("\ndownload failed: " .. BASE .. path .. "\n(check BASE and that http is allowed)") end
    print("skipped"); return false
  end
  local data = res.readAll(); res.close()
  local f = fs.open(dest, "w"); f.write(data); f.close()
  print("ok (" .. #data .. " B)")
  return true
end

print("Installing HT node from:")
print("  " .. BASE)
fetch("src/ht_boot.lua", "startup", true)        -- bootstrap + over-the-air updates
fetch("src/ht_node.lua", "firmware.lua", true)   -- the ONE firmware, same on every node
fetch("src/ht_push.lua", "ht_push.lua", false)   -- handy admin tool; optional

if group and group ~= "" then
  local f = fs.open("ht_group", "w"); f.write(group); f.close()
  print("  group = " .. group)
end

print("Done. Rebooting - first boot runs setup (name this node + calibrate its tubes).")
sleep(1)
os.reboot()
