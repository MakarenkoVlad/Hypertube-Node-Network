--[[
  Smart Hypertube Station  -  CC: Tweaked + Create: Hypertubes
  ==============================================================
  Tap a destination on the Advanced Monitor. The computer releases the
  brake on that ONE tube (a Create Clutch) and lights its lamp, while every
  other tube stays braked/off. After a timeout it re-brakes everything so
  the next traveller starts from a clean menu.

  Why "one tube per destination": Create: Hypertubes has no in-tube
  junction/splitter yet, so you cannot reroute a single shared tube. Each
  destination gets its own entrance; the computer just enables the right one.

  SAVE on the computer as "startup" so it runs automatically on chunk load:
     edit startup        (paste this in, Ctrl+S, Ctrl+X, then reboot)
  or run it by hand:     hypertube_station
--]]

----------------------------------------------------------------
-- CONFIG  -  edit this to match your build
----------------------------------------------------------------
local MONITOR      = "right"   -- side or network name of the Advanced Monitor
local OPEN_SECONDS = 12        -- how long the chosen tube stays open before reset
local TEXT_SCALE   = 1         -- monitor text size (0.5 - 5)

-- One row per destination, in the order they appear on screen.
--   name  : label shown on the touchscreen
--   relay : network name of THAT tube's Redstone Relay (right-click its
--           wired modem to see the name, e.g. "redstone_relay_0")
--   brake : the relay side wired to that tube's Create Clutch
--   lamp  : the relay side wired to that tube's indicator lamp
local DEST = {
  { name = "Main Base",  relay = "redstone_relay_0", brake = "back", lamp = "top" },
  { name = "Mineshaft",  relay = "redstone_relay_1", brake = "back", lamp = "top" },
  { name = "Nether Hub", relay = "redstone_relay_2", brake = "back", lamp = "top" },
  { name = "Farm",       relay = "redstone_relay_3", brake = "back", lamp = "top" },
}
----------------------------------------------------------------

-- ---- wrap peripherals -----------------------------------------------------
local mon = peripheral.wrap(MONITOR)
assert(mon and mon.setTextScale,
  "No monitor found on '" .. MONITOR .. "'. Fix MONITOR in the config.")
mon.setTextScale(TEXT_SCALE)

local relay = {}
for _, d in ipairs(DEST) do
  if not relay[d.relay] then
    relay[d.relay] = assert(peripheral.wrap(d.relay),
      "No relay named '" .. d.relay ..
      "'. Right-click its wired modem and copy the printed name.")
  end
end

-- ---- redstone logic -------------------------------------------------------
-- Redstone ON  = clutch braked = tube OFF.
-- Chosen tube  : brake OFF (spins) and lamp ON. Everything else braked.
local function select(idx)
  for i, d in ipairs(DEST) do
    local chosen = (i == idx)
    relay[d.relay].setOutput(d.brake, not chosen)
    relay[d.relay].setOutput(d.lamp, chosen)
  end
end

local function brakeAll()
  for _, d in ipairs(DEST) do
    relay[d.relay].setOutput(d.brake, true)
    relay[d.relay].setOutput(d.lamp, false)
  end
end

-- ---- drawing --------------------------------------------------------------
local rowDest = {}  -- monitor row (y) -> destination index

local function center(y, text, fg, bg)
  local w = mon.getSize()
  mon.setBackgroundColor(bg or colors.black)
  mon.setTextColor(fg or colors.white)
  mon.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
  mon.write(text)
end

local function drawMenu()
  rowDest = {}
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local w, h = mon.getSize()

  -- title bar
  mon.setBackgroundColor(colors.blue)
  mon.setCursorPos(1, 1)
  mon.clearLine()
  center(1, "HYPERTUBE STATION", colors.white, colors.blue)

  -- destination buttons (every other row, so taps are easy)
  local y = 3
  for i, d in ipairs(DEST) do
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.white)
    mon.setCursorPos(2, y)
    local label = (" %d. %s"):format(i, d.name)
    mon.write(label .. string.rep(" ", math.max(0, w - 2 - #label)))
    rowDest[y] = i
    rowDest[y + 1] = i          -- count the blank line below as the same button
    y = y + 2
  end

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.lightGray)
  mon.setCursorPos(1, h)
  mon.write("Tap a destination")
end

local function drawDeparting(idx)
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local _, h = mon.getSize()
  center(math.floor(h / 2) - 1, "DEPARTING", colors.lime)
  center(math.floor(h / 2),     DEST[idx].name, colors.white)
  center(math.floor(h / 2) + 1, "step into the lit tube", colors.lightGray)
  center(h, "tap to cancel", colors.gray)
end

-- ---- main loop ------------------------------------------------------------
brakeAll()
drawMenu()

while true do
  local _, _, _, y = os.pullEvent("monitor_touch")
  local idx = rowDest[y]
  if idx then
    select(idx)
    drawDeparting(idx)
    local timer = os.startTimer(OPEN_SECONDS)
    while true do
      local ev, a = os.pullEvent()
      if (ev == "timer" and a == timer) or ev == "monitor_touch" then
        break  -- time's up, or tapped again to cancel
      end
    end
    brakeAll()
    drawMenu()
  end
end
