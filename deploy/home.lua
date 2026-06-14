-- ===========================================================================
-- AUTO-GENERATED — config for node 'home'
-- Source graph: config/starter_2station.lua   (regenerate with tools/build_routes.lua)
-- Don't hand-edit — change the graph, rebuild, and redeploy (src/install.lua).
-- ===========================================================================
local STATION = "home"

local STATIONS = {
  { id = "home",    name = "Home"    },
  { id = "outpost", name = "Outpost" },
}

local EXITS = {
  toOutpost = { relay = "redstone_relay_0", side = "back", invert = true },
}

local ROUTES = {
  home    = "RELEASE",   -- arrive here
  outpost = "toOutpost",
}

local MODEM   = "top"
local MONITOR = "right"
local DETECT  = nil
local PAD_DETECTOR = "player_detector_0"
local BOARD_RANGE  = 2
