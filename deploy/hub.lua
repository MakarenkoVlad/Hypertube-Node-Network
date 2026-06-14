-- ===========================================================================
-- AUTO-GENERATED — config for node 'hub'
-- Source graph: config/hub_4spoke.lua   (regenerate with tools/build_routes.lua)
-- Don't hand-edit — change the graph, rebuild, and redeploy (src/install.lua).
-- ===========================================================================
local STATION = "hub"

local STATIONS = {
  { id = "hub", name = "Hub"    },
  { id = "s1",  name = "Stop 1" },
  { id = "s2",  name = "Stop 2" },
  { id = "s3",  name = "Stop 3" },
  { id = "s4",  name = "Stop 4" },
}

local EXITS = {
  to_s1 = { controller = "Create_RotationSpeedController_0", rpm = 32 },
  to_s2 = { controller = "Create_RotationSpeedController_1", rpm = 32 },
  to_s3 = { controller = "Create_RotationSpeedController_2", rpm = 32 },
  to_s4 = { controller = "Create_RotationSpeedController_3", rpm = 32 },
}

local ROUTES = {
  hub = "RELEASE",   -- arrive here
  s1  = "to_s1",
  s2  = "to_s2",
  s3  = "to_s3",
  s4  = "to_s4",
}

local PATHS = {
  s1 = { "hub", "s1" },
  s2 = { "hub", "s2" },
  s3 = { "hub", "s3" },
  s4 = { "hub", "s4" },
}

local MODEM   = "top"
local MONITOR = "right"
local DETECT  = nil
local PAD_DETECTOR = "player_detector_0"
local BOARD_RANGE  = 2
