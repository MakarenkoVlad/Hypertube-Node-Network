--[[
  HT one-shot installer (pastebin). (CC: Tweaked)
  ===========================================================================
  Sets up a node in one command. Replaces those three `pastebin get` lines.

  SETUP (once):
    1. Upload these to pastebin.com and note each code:
         src/ht_boot.lua   (the bootstrap + OTA)
         src/ht_node.lua   (the ONE firmware, same on every node)
         src/ht_push.lua   (admin push tool; optional)
    2. Paste those codes below.
    3. Upload THIS file to pastebin too, note its code.

  THEN, on every node's computer, just run:
        pastebin run <thisCode>
  It downloads everything and reboots into first-boot setup (name + calibrate).
--]]

----------------------------------------------------------------
-- fill in your pastebin codes:
local BOOT = "pANB9APv"   -- ht_boot.lua  -> startup
local NODE = "KUTCcf57"   -- ht_node.lua  -> firmware.lua
local PUSH = "DDMztPkm"   -- ht_push.lua  -> ht_push.lua  (optional)
----------------------------------------------------------------

local function get(code, file, optional)
  if not code or code == "" or code:find("PASTE_", 1, true) then
    if optional then print("  " .. file .. " skipped (no code)"); return end
    error("Set the " .. file .. " pastebin code at the top of this installer.")
  end
  if fs.exists(file) then fs.delete(file) end
  io.write("  " .. file .. "  <-  " .. code .. "  ... ")
  local ok = shell.run("pastebin", "get", code, file)
  print(ok and "ok" or "FAILED")
  if not ok and not optional then
    error("Download failed for " .. file .. " (code " .. code .. "). Check the code and that HTTP is enabled.")
  end
end

term.clear(); term.setCursorPos(1, 1)
print("=== Installing HT node ===")
get(BOOT, "startup")
get(NODE, "firmware.lua")
get(PUSH, "ht_push.lua", true)
print("Done. Rebooting - first boot will run setup (name this node + calibrate its tubes).")
sleep(1.5)
os.reboot()
