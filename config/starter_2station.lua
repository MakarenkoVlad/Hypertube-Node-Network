--[[
  STARTER NETWORK — two stations, one tube. The smallest real build.

      Home  ============ tube ============  Outpost

  Stand on a pad, tap the other station, ride. This doubles as the Step 0
  mechanic test: if travel works here, the hand-off / release behaviour the
  whole design relies on is confirmed.

  Build it, then generate the two deployables:
      lua tools/build_routes.lua config/starter_2station.lua deploy --startup
  -> deploy/home.startup.lua  and  deploy/outpost.startup.lua
     (each = firmware + that node's config; drop on the matching computer.)

  The peripheral names below are the DEFAULTS you get if you wire each station
  the way docs/survival-quickstart.md describes (one relay and one player
  detector on the computer's wired network, monitor on the right, ender modem
  on top). Wire it that way and you won't have to edit anything.

  Tip for the very first power-on: if catching/boarding is fussy, set
  pad_detector = nil on both nodes to remove the presence gate, get the tube
  itself working, then add the detector back.
--]]

return {

  stations = {
    { id = "home",    name = "Home"    },
    { id = "outpost", name = "Outpost" },
  },

  nodes = {

    home = {
      monitor      = "right",              -- Advanced Monitor on the computer's right
      pad_detector = "player_detector_0",  -- Player Detector at the pad (nil to disable)
      board_range  = 2,
      exits = {
        -- the single entrance at Home, aimed down the tube toward Outpost
        toOutpost = { to = "outpost", relay = "redstone_relay_0", side = "back", invert = true },
      },
    },

    outpost = {
      monitor      = "right",
      pad_detector = "player_detector_0",
      board_range  = 2,
      exits = {
        -- the single entrance at Outpost, aimed back toward Home
        toHome = { to = "home", relay = "redstone_relay_0", side = "back", invert = true },
      },
    },

  },
}
