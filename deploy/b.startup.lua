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

-- @HT-CONFIG-START  -- per-node config. Generate it with tools/build_routes.lua
-- ===========================================================================
-- AUTO-GENERATED — config for node 'b'
-- Source graph: config/starter_4station.lua   (regenerate with tools/build_routes.lua)
-- Don't hand-edit — change the graph, rebuild, and redeploy (src/install.lua).
-- ===========================================================================
local STATION = "b"

local STATIONS = {
  { id = "a", name = "Station A" },
  { id = "b", name = "Station B" },
  { id = "c", name = "Station C" },
  { id = "d", name = "Station D" },
}

local EXITS = {
  toA = { controller = "Create_RotationSpeedController_0", rpm = 32 },
  toC = { controller = "Create_RotationSpeedController_1", rpm = 32 },
  toD = { controller = "Create_RotationSpeedController_2", rpm = 32 },
}

local ROUTES = {
  a = "toA",
  b = "RELEASE",   -- arrive here
  c = "toC",
  d = "toD",
}

local PATHS = {
  a = { "b", "a" },
  c = { "b", "c" },
  d = { "b", "d" },
}

local MODEM   = "top"
local MONITOR = "right"
local DETECT  = nil
local PAD_DETECTOR = "player_detector_0"
local BOARD_RANGE  = 2

-- @HT-CONFIG-END

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

-- node identity: label the in-game computer with its node id (set at setup)
if os.getComputerLabel() ~= STATION then os.setComputerLabel(STATION) end

-- optional Player Detector at the boarding pad (Advanced Peripherals)
local padDetector = PAD_DETECTOR and peripheral.wrap(PAD_DETECTOR) or nil
if PAD_DETECTOR and not padDetector then
  print("[warn] no player detector on '" .. PAD_DETECTOR .. "' — boarding won't gate on presence.")
end

local wrapped = {}
local function getp(name)
  if not wrapped[name] then
    wrapped[name] = assert(peripheral.wrap(name),
      "No peripheral '" .. name .. "' — check its side / wired-modem name.")
  end
  return wrapped[name]
end

-- ---- gates ---------------------------------------------------------------
-- A gate is ONE of:
--   speed controller (Create Rotational Speed Controller):
--       { controller = "<name/side>", rpm = N }  -> on = setTargetSpeed(rpm), off = 0
--   redstone relay + Create Clutch:
--       { relay = "redstone_relay_0", side = "back", invert = true }
local function setGate(g, enable)
  if g.controller then
    getp(g.controller).setTargetSpeed(enable and (g.rpm or 32) or 0)
  else
    local signal = g.invert and (not enable) or enable
    getp(g.relay).setOutput(g.side, signal)
  end
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

-- ---- player presence (Advanced Peripherals Player Detector) --------------
-- username of a player standing on the pad, or nil. getPlayersInRange returns
-- a list of usernames; we take the first. pcall-guarded so a missing or
-- different-version API can't crash the node.
local function riderOnPad()
  if not padDetector then return nil end
  local ok, players = pcall(padDetector.getPlayersInRange, BOARD_RANGE)
  if not ok or type(players) ~= "table" then return nil end
  local p = players[1]
  if type(p) == "table" then return p.name end   -- defensive: some versions return objects
  return p
end

-- ---- shared travel state (replicated across every node via rednet) -------
-- One trip travels the network at a time. Every node holds the SAME view:
-- `active` (the current trip, or nil) and `recent` (a short log). ROUTE starts
-- a trip, ARRIVED ends it, and a node that just booted asks the others for the
-- current state with SYNC_REQ. A trip carries its PATH (node ids origin..dest),
-- so a node only powers an entrance when it is actually on that route.
local LOG_MAX      = 6
local active       = nil    -- { id, from, to, rider, ts, path } or nil
local recent       = {}     -- finished trips, newest first
local timeoutTimer = nil

local function busy() return active ~= nil end
local function armTimeout() timeoutTimer = os.startTimer(TRIP_TIMEOUT) end
local function pushRecent(t)
  table.insert(recent, 1, t)
  while #recent > LOG_MAX do table.remove(recent) end
end

-- am I on this trip's path? (no path given = unconfined; everyone participates)
local function onPath(path)
  if type(path) ~= "table" then return true end
  for _, id in ipairs(path) do if id == STATION then return true end end
  return false
end

-- set my gates for a trip: power the exit toward its destination, but only if
-- I'm on its path; otherwise stay released so I never grab a passer-by.
local function gateForTrip(t)
  if onPath(t.path) then applyRoute(t.to) else releaseAll() end
end

-- ---- UI ------------------------------------------------------------------
local rowDest = {}

-- the shared status line, rendered for THIS node's role in the current trip
local function netStatus()
  if active then
    if active.from == STATION then
      return ("Board %s  ->  %s"):format(exitFor(active.to) or "?", nameById(active.to)), colors.lime
    elseif active.to == STATION then
      return ("Arriving: %s"):format(active.rider or "traveller"), colors.lime
    end
    return ("Net: %s  %s->%s"):format(active.rider or "rider", nameById(active.from), nameById(active.to)), colors.orange
  end
  if padDetector then
    local who = riderOnPad()
    if who then return "Welcome, " .. who .. " - tap a destination", colors.lime end
    return "Step onto the pad to travel", colors.lightGray
  end
  return "Tap a destination", colors.lightGray
end

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
      mon.setBackgroundColor((busy() or not reachable) and colors.gray or colors.green)
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

local function refresh() draw(netStatus()) end

-- ---- trip control --------------------------------------------------------
local function finishActive(how)
  if active then
    pushRecent({ rider = active.rider, from = active.from, to = active.to, ts = active.ts, how = how })
  end
  active = nil
  releaseAll()
  refresh()
end

local function startTrip(destId)
  if busy() then refresh(); return end
  if destId == STATION then return end
  local boardExit = exitFor(destId)
  if not boardExit then draw("No route to " .. nameById(destId), colors.red); return end
  -- player-detection gate: only launch while someone is on the pad
  local rider = riderOnPad()
  if padDetector and not rider then draw("Step onto the pad first", colors.orange); return end
  local now = os.epoch("utc")
  local t = { id = now, from = STATION, to = destId, rider = rider, ts = now, path = PATHS[destId] }
  rednet.broadcast({ type = "ROUTE", trip = t }, PROTO)
  active = t
  gateForTrip(t)
  armTimeout()
  refresh()
end

local function handleMessage(sender, msg)
  if type(msg) ~= "table" then return end
  if msg.type == "ROUTE" then
    local t = msg.trip
    if type(t) ~= "table" or not t.to then return end
    if active and active.id ~= t.id then return end   -- single-occupancy: first trip holds
    active = t
    gateForTrip(t)
    armTimeout()
    refresh()
  elseif msg.type == "ARRIVED" then
    if not active or not msg.tripId or msg.tripId == active.id then finishActive("delivered") end
  elseif msg.type == "SYNC_REQ" then
    if sender then rednet.send(sender, { type = "SYNC_RES", active = active, recent = recent }, PROTO) end
  elseif msg.type == "SYNC_RES" then
    if not active and type(msg.active) == "table" then
      active = msg.active; gateForTrip(active); armTimeout()
    end
    if #recent == 0 and type(msg.recent) == "table" then recent = msg.recent end
    refresh()
  end
end

-- ---- boot ----------------------------------------------------------------
local presenceTimer
local function armPresence()
  if padDetector then presenceTimer = os.startTimer(1) end
end

releaseAll()
refresh()
armPresence()
rednet.broadcast({ type = "SYNC_REQ" }, PROTO)   -- catch up on a trip already in progress

while true do
  local e = { os.pullEvent() }
  local ev = e[1]
  if ev == "monitor_touch" then
    local id = rowDest[e[4]]                          -- {event, side, x, y}
    if id then startTrip(id) end
  elseif ev == "rednet_message" then
    if e[4] == PROTO then handleMessage(e[2], e[3]) end  -- {event, sender, msg, protocol}
  elseif ev == "timer" then
    if e[2] == timeoutTimer then
      finishActive("timeout")
    elseif e[2] == presenceTimer then
      if not busy() then refresh() end                -- refresh the greeting
      armPresence()
    end
  elseif ev == "playerClick" then                     -- someone clicked the pad detector
    if not busy() then refresh() end
  elseif ev == "redstone" then
    if DETECT and active and active.to == STATION and redstone.getInput(DETECT) then
      rednet.broadcast({ type = "ARRIVED", tripId = active.id, at = STATION }, PROTO)
      finishActive("delivered")
    end
  end
end
