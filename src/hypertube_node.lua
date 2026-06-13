--[[
  Hypertube Network — Node firmware (station, junction, or both)
  CC: Tweaked + Create: Hypertubes  |  NeoForge 1.21.1
  ===========================================================================
  ONE program for every computer in the network. A node can be:
    * a STATION   — has a touchscreen; you board here and you can arrive here
    * a JUNCTION  — headless; switches travellers onto one of several tubes
    * both        — a station that also forks the line

  How routing works: each node has named EXITS (the entrances it can power) and
  a ROUTES table saying, for every destination, which exit forwards toward it.
  To switch among two tubes, a junction simply lists two exits and routes some
  destinations to one and the rest to the other. The destination node routes to
  "RELEASE", so nothing catches the traveller and they drop out = arrived.

  Deploy: edit startup -> paste -> Ctrl+S, Ctrl+X -> reboot.
--]]

------------------------------------------------------------------
-- THIS NODE
------------------------------------------------------------------
local STATION = "main_base"   -- this node's unique id

------------------------------------------------------------------
-- DIRECTORY — destinations shown on the touchscreen (terminals only).
-- Keep identical on every station that has a monitor. id must be unique.
------------------------------------------------------------------
local STATIONS = {
  { id = "main_base", name = "Main Base"  },
  { id = "mine",      name = "Mineshaft"  },
  { id = "farm",      name = "Farm"       },
  { id = "nether",    name = "Nether Hub" },
}

------------------------------------------------------------------
-- EXITS — the powered entrances this node can send a traveller out through.
-- Name them after the physical tube ("toMine", "north", "up"...).
--   relay  = network name of that entrance's Redstone Relay
--   side   = relay output wired to the gate
--   invert = true  -> redstone ON brakes the entrance (Create Clutch)
--            false -> redstone ON enables it (redstone-lockable entrance)
------------------------------------------------------------------
local EXITS = {
  toMine = { relay = "redstone_relay_0", side = "back", invert = true },
}

------------------------------------------------------------------
-- ROUTES — for each destination id, the EXIT that forwards toward it.
-- Use "RELEASE" for destinations reached BY dropping out here (this node).
-- A JUNCTION switches among tubes simply by pointing different destinations
-- at different exits, e.g.  farm = "toFarm",  nether = "toNether".
------------------------------------------------------------------
local ROUTES = {
  main_base = "RELEASE",   -- I am main_base
  mine      = "toMine",
  farm      = "toMine",
  nether    = "toMine",
}

------------------------------------------------------------------
-- PERIPHERALS
------------------------------------------------------------------
local MODEM   = "top"      -- side of the ENDER (wireless) modem
local MONITOR = "right"    -- monitor side/name, or nil for a headless junction
local DETECT  = nil        -- a COMPUTER side wired to an arrival plate, or nil

local PROTO        = "hypertube"
local TRIP_TIMEOUT = 30     -- seconds before the line auto-clears with no arrival
------------------------------------------------------------------

-- ---- peripherals ---------------------------------------------------------
local modem = peripheral.wrap(MODEM)
assert(modem, "No modem found on '" .. MODEM .. "'. Fix MODEM.")
if modem.isWireless and not modem.isWireless() then
  print("[warn] modem on '" .. MODEM .. "' is wired — limited range. Use an Ender modem for full-map / cross-dimension range.")
end
rednet.open(MODEM)

local mon = MONITOR and peripheral.wrap(MONITOR) or nil

local relays = {}
local function relay(name)
  if not relays[name] then
    relays[name] = assert(peripheral.wrap(name), "No relay '" .. name .. "' — check its wired-modem name.")
  end
  return relays[name]
end

-- ---- gates ---------------------------------------------------------------
local function setGate(g, enable)
  local signal = g.invert and (not enable) or enable
  relay(g.relay).setOutput(g.side, signal)
end

local function releaseAll()
  for _, g in pairs(EXITS) do setGate(g, false) end
end

-- sanity: every route target must be RELEASE or a defined exit
for dest, exit in pairs(ROUTES) do
  if exit ~= "RELEASE" and not EXITS[exit] then
    error("ROUTES['" .. dest .. "'] points at unknown exit '" .. tostring(exit) .. "'")
  end
end

-- ---- directory helpers ---------------------------------------------------
local function nameById(id)
  for _, s in ipairs(STATIONS) do if s.id == id then return s.name end end
  return id
end

-- which exit (if any) this node uses for a destination; nil means release here
local function exitFor(dest)
  local e = ROUTES[dest]
  if e == nil or e == "RELEASE" then return nil end
  return e
end

local function applyRoute(dest)
  local chosen = exitFor(dest)
  for name, g in pairs(EXITS) do
    setGate(g, name == chosen)   -- power only the exit toward dest
  end
end

-- ---- state ---------------------------------------------------------------
local lineBusy     = false
local activeTrip   = nil
local timeoutTimer = nil
local function armTimeout() timeoutTimer = os.startTimer(TRIP_TIMEOUT) end

-- ---- UI ------------------------------------------------------------------
local rowDest = {}
local function draw(status, color)
  if not mon then return end
  rowDest = {}
  mon.setBackgroundColor(colors.black); mon.clear()
  local w, h = mon.getSize()

  mon.setBackgroundColor(colors.blue); mon.setCursorPos(1, 1); mon.clearLine()
  mon.setTextColor(colors.white)
  local title = " " .. nameById(STATION) .. " "
  mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
  mon.write(title)

  local y = 3
  for _, s in ipairs(STATIONS) do
    if s.id ~= STATION then
      mon.setCursorPos(2, y)
      local reachable = exitFor(s.id) ~= nil
      mon.setBackgroundColor((lineBusy or not reachable) and colors.gray or colors.green)
      mon.setTextColor(reachable and colors.white or colors.lightGray)
      local label = " " .. s.name
      mon.write(label .. string.rep(" ", math.max(0, w - 2 - #label)))
      rowDest[y] = s.id; rowDest[y + 1] = s.id
      y = y + 2
    end
  end

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(color or colors.lightGray)
  mon.setCursorPos(1, h)
  mon.write((status or "Tap a destination"):sub(1, w))
end

-- ---- trip control --------------------------------------------------------
local function clearLine()
  lineBusy = false; activeTrip = nil
  releaseAll()
  draw()
end

local function startTrip(destId)
  if lineBusy then draw("Line busy — please wait", colors.orange); return end
  if destId == STATION then return end
  local boardExit = exitFor(destId)
  if not boardExit then draw("No route to " .. nameById(destId), colors.red); return end
  local msg = { type = "ROUTE", dest = destId, trip = os.epoch("utc") }
  rednet.broadcast(msg, PROTO)
  activeTrip = msg; lineBusy = true
  applyRoute(destId)
  armTimeout()
  draw("Board: " .. boardExit .. "  ->  " .. nameById(destId), colors.lime)
end

local function handleMessage(msg)
  if type(msg) ~= "table" then return end
  if msg.type == "ROUTE" then
    activeTrip = msg; lineBusy = true
    applyRoute(msg.dest)
    armTimeout()
    draw("Line in use  ->  " .. nameById(msg.dest), colors.orange)
  elseif msg.type == "ARRIVED" then
    clearLine()
  end
end

-- ---- boot ----------------------------------------------------------------
releaseAll()
draw()

while true do
  local e = { os.pullEvent() }
  local ev = e[1]
  if ev == "monitor_touch" then
    local id = rowDest[e[4]]                          -- {event, side, x, y}
    if id then startTrip(id) end
  elseif ev == "rednet_message" then
    if e[4] == PROTO then handleMessage(e[3]) end     -- {event, sender, msg, protocol}
  elseif ev == "timer" then
    if e[2] == timeoutTimer then clearLine() end
  elseif ev == "redstone" then
    if DETECT and activeTrip and activeTrip.dest == STATION and redstone.getInput(DETECT) then
      rednet.broadcast({ type = "ARRIVED", at = STATION, trip = activeTrip.trip }, PROTO)
      clearLine()
    end
  end
end
