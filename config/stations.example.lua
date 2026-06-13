--[[
  EXAMPLE NETWORK with a junction that switches among two tubes.

      main_base ==== mine ==== [ JCT ] ==== farm
                                  ||
                               nether

  "JCT" is a headless junction node. Travellers coming from mine are switched
  onto the FARM tube or the NETHER tube depending on their destination — that's
  the "switch among two tubes" case. Every other node is a normal station.

  Copy the matching block into the CONFIG section of src/hypertube_node.lua on
  each computer. The STATIONS directory is the same everywhere (stations only —
  junctions are not destinations, so they are not listed).
--]]

-- Shared on every STATION (not needed on the headless junction):
-- local STATIONS = {
--   { id = "main_base", name = "Main Base"  },
--   { id = "mine",      name = "Mineshaft"  },
--   { id = "farm",      name = "Farm"       },
--   { id = "nether",    name = "Nether Hub" },
-- }

--==================================================================
-- NODE: main_base  (station, end of line)
--==================================================================
-- local STATION = "main_base"
-- local EXITS = { toMine = { relay="redstone_relay_0", side="back", invert=true } }
-- local ROUTES = {
--   main_base = "RELEASE",
--   mine = "toMine", farm = "toMine", nether = "toMine",
-- }
-- MONITOR = "right"

--==================================================================
-- NODE: mine  (station, passes deeper traffic toward the junction)
--==================================================================
-- local STATION = "mine"
-- local EXITS = {
--   toMain = { relay="redstone_relay_0", side="back", invert=true },
--   toJct  = { relay="redstone_relay_1", side="back", invert=true },
-- }
-- local ROUTES = {
--   mine = "RELEASE",
--   main_base = "toMain",
--   farm = "toJct", nether = "toJct",
-- }
-- MONITOR = "right"

--==================================================================
-- NODE: jct  (JUNCTION — headless, switches among two forward tubes)
--==================================================================
-- local STATION = "jct"
-- local EXITS = {
--   toMine   = { relay="redstone_relay_0", side="back", invert=true },
--   toFarm   = { relay="redstone_relay_1", side="back", invert=true },  -- tube A
--   toNether = { relay="redstone_relay_2", side="back", invert=true },  -- tube B
-- }
-- local ROUTES = {
--   main_base = "toMine", mine = "toMine",   -- send "back" travellers toward mine
--   farm   = "toFarm",                       -- switch onto tube A
--   nether = "toNether",                     -- switch onto tube B
-- }
-- MONITOR = nil    -- headless; no touchscreen

--==================================================================
-- NODE: farm  (station, end of a branch)
--==================================================================
-- local STATION = "farm"
-- local EXITS = { toJct = { relay="redstone_relay_0", side="back", invert=true } }
-- local ROUTES = {
--   farm = "RELEASE",
--   main_base = "toJct", mine = "toJct", nether = "toJct",
-- }
-- MONITOR = "right"

--==================================================================
-- NODE: nether  (station, end of a branch)
--==================================================================
-- local STATION = "nether"
-- local EXITS = { toJct = { relay="redstone_relay_0", side="back", invert=true } }
-- local ROUTES = {
--   nether = "RELEASE",
--   main_base = "toJct", mine = "toJct", farm = "toJct",
-- }
-- MONITOR = "right"
