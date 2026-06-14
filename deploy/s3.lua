-- ===========================================================================
-- AUTO-GENERATED — config for node 's3'
-- Source graph: config/hub_4spoke.lua   (regenerate with tools/build_routes.lua)
-- Don't hand-edit — change the graph, rebuild, and redeploy (src/install.lua).
-- ===========================================================================
local STATION = "s3"

local STATIONS = {
  { id = "hub", name = "Hub"    },
  { id = "s1",  name = "Stop 1" },
  { id = "s2",  name = "Stop 2" },
  { id = "s3",  name = "Stop 3" },
  { id = "s4",  name = "Stop 4" },
}

local EXITS = {
  to_hub = { controller = "Create_RotationSpeedController_0", rpm = 32 },
}

local ROUTES = {
  hub = "to_hub",
  s1  = "to_hub",
  s2  = "to_hub",
  s3  = "RELEASE",   -- arrive here
  s4  = "to_hub",
}

local PATHS = {
  hub = { "s3", "hub" },
  s1  = { "s3", "hub", "s1" },
  s2  = { "s3", "hub", "s2" },
  s4  = { "s3", "hub", "s4" },
}

local MODEM   = "top"
local MONITOR = "right"
local DETECT  = nil
local PAD_DETECTOR = "player_detector_0"
local BOARD_RANGE  = 2
