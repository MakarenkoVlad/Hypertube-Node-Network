-- ===========================================================================
-- AUTO-GENERATED — config for node 'c'
-- Source graph: config/starter_4station.lua   (regenerate with tools/build_routes.lua)
-- Don't hand-edit — change the graph, rebuild, and redeploy (src/install.lua).
-- ===========================================================================
local STATION = "c"

local STATIONS = {
  { id = "a", name = "Station A" },
  { id = "b", name = "Station B" },
  { id = "c", name = "Station C" },
  { id = "d", name = "Station D" },
}

local EXITS = {
  toB = { controller = "Create_RotationSpeedController_0", rpm = 32 },
}

local ROUTES = {
  a = "toB",
  b = "toB",
  c = "RELEASE",   -- arrive here
  d = "toB",
}

local PATHS = {
  a = { "c", "b", "a" },
  b = { "c", "b" },
  d = { "c", "b", "d" },
}

local MODEM   = "top"
local MONITOR = "right"
local DETECT  = nil
local PAD_DETECTOR = "player_detector_0"
local BOARD_RANGE  = 2
