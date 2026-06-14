--[[
  Return Station — a one-way "send me back to the hub". (CC: Tweaked + Create)
  ===========================================================================
  The lean counterpart to auto_hub: no monitor needed. It auto-finds the single
  Rotational Speed Controller driving the return entrance (and a Player Detector
  if present). Press a button wired to the computer and it spins the return tube
  until you've passed through, then stops.

  WIRE: at the destination, the return Hypertube Entrance (aimed back at the hub)
  on its own RSC, that RSC attached to this computer (wired modem, ring red), a
  Player Detector at the pad, and a vanilla Button on/next to the computer (so a
  press gives it a redstone pulse). An Ender Modem is optional (only needed later
  for shared travel state).

  WHY A BUTTON, not step-on-pad: you ARRIVE on this same pad from the hub, so an
  auto-launch would ping-pong you straight back. The button makes the return
  deliberate.

  Deploy: pastebin get <code> startup  ->  reboot.
--]]

local RPM         = 32   -- launch RPM (<= 256)
local RUN_SECONDS = 20   -- safety cap; normally stops the moment you leave the pad

-- ---- discover the return controller + detector (by capability) ------------
local function findOne(test)
  for _, n in ipairs(peripheral.getNames()) do
    local ok, p = pcall(peripheral.wrap, n)
    if ok and p and test(n, p) then return p, n end
  end
end

local rsc, rscName = findOne(function(_, p) return p.setTargetSpeed ~= nil end)
local detector     = findOne(function(_, p) return p.getPlayersInRange ~= nil end)

while not rsc do
  print("No speed controller found. Attach the return entrance's RSC")
  write("(right-click its wired modem until red), then press Enter... "); read()
  rsc, rscName = findOne(function(_, p) return p.setTargetSpeed ~= nil end)
end

-- ---- helpers -------------------------------------------------------------
local function onPad()
  if not detector then return true end                 -- no detector = don't gate
  local ok, players = pcall(detector.getPlayersInRange, 2)
  return ok and type(players) == "table" and players[1] ~= nil
end

local function spin(on) pcall(rsc.setTargetSpeed, on and RPM or 0) end

local function buttonPressed()
  for _, side in ipairs(redstone.getSides()) do
    if redstone.getInput(side) then return true end
  end
  return false
end

-- ---- run -----------------------------------------------------------------
spin(false)
term.clear(); term.setCursorPos(1, 1)
print("=== Return Station ===")
print(("Controller: %s | Detector: %s"):format(rscName, detector and "yes" or "no"))
print("Stand on the pad and press the button to go back to the hub.")

local active, fallback, poll = false, nil, nil
local function stop(msg) spin(false); active = false; if msg then print(msg) end end

while true do
  local ev = { os.pullEvent() }
  local e = ev[1]
  if e == "redstone" and not active and buttonPressed() then
    if onPad() then
      spin(true); active = true
      fallback = os.startTimer(RUN_SECONDS)
      poll = os.startTimer(0.4)
      print("Launching back to the hub...")
    else
      print("Step onto the pad first.")
    end
  elseif e == "timer" and active then
    if ev[2] == poll then
      if onPad() then poll = os.startTimer(0.4)         -- still boarding
      else stop("Sent. Ready.") end                     -- passed through -> stop
    elseif ev[2] == fallback then
      stop("Ready.")                                     -- safety stop
    end
  end
end
