-- ===========================================================================
-- AUTO-GENERATED — config for node 'd'
-- Source graph: config/starter_4station.lua   (regenerate with tools/build_routes.lua)
-- Don't hand-edit — change the graph, rebuild, and redeploy (src/install.lua).
-- ===========================================================================
local STATION = "d"

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
  c = "toB",
  d = "RELEASE",   -- arrive here
}

local PATHS = {
  a = { "d", "b", "a" },
  b = { "d", "b" },
  c = { "d", "b", "c" },
}

local MODEM   = "top"
local MONITOR = "right"
local DETECT  = nil
local PAD_DETECTOR = "player_detector_0"
local BOARD_RANGE  = 2
