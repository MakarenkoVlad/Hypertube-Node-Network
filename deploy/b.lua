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
