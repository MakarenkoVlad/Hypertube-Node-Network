-- ===========================================================================
-- AUTO-GENERATED — config for node 'a'
-- Source graph: config/starter_4station.lua   (regenerate with tools/build_routes.lua)
-- Don't hand-edit — change the graph, rebuild, and redeploy (src/install.lua).
-- ===========================================================================
local STATION = "a"

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
  a = "RELEASE",   -- arrive here
  b = "toB",
  c = "toB",
  d = "toB",
}

local PATHS = {
  b = { "a", "b" },
  c = { "a", "b", "c" },
  d = { "a", "b", "d" },
}

local MODEM   = "top"
local MONITOR = "right"
local DETECT  = nil
local PAD_DETECTOR = "player_detector_0"
local BOARD_RANGE  = 2
