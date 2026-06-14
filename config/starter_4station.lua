--[[
  4-STATION STARTER — a star with a junction at B.  (Gates = Create Rotational
  Speed Controllers: the computer sets each entrance's target RPM; 0 = stopped.)

                 Station C
                     |
     Station A ===== B =====      (B forks: up to C, down to D)
                     |
                 Station D

  Edges: A-B, B-C, B-D.  B is BOTH a station (you can board/arrive there) AND a
  3-way junction: travelling A->C or A->D passes through B, which switches you
  onto the right tube. B is the "pad with 2-3 entrances facing it" node.

  Generate the four deployables:
      lua tools/build_routes.lua config/starter_4station.lua deploy --startup
  -> deploy/a.startup.lua, b.startup.lua, c.startup.lua, d.startup.lua

  GATES: each exit drives one Rotational Speed Controller via
      { controller = "<peripheral>", rpm = 32 }   -- on = setTargetSpeed(32), off = 0
  Confirm the real peripheral names in-game with `peripheral.getNames()`. A node
  with a SINGLE RSC sitting against the computer can use its side instead of a
  network name, e.g. controller = "bottom". At B (three RSCs) put each on a wired
  modem; attach them in toA, toC, toD order so the names line up below, or edit
  to match getNames(). `rpm` is whatever speed your entrances need (<=256).

  Tip: get A<->B working first, then add C and D — the junction redirect at B is
  the trickiest geometry (Step 0 test 3).
--]]

return {

  stations = {
    { id = "a", name = "Station A" },
    { id = "b", name = "Station B" },
    { id = "c", name = "Station C" },
    { id = "d", name = "Station D" },
  },

  nodes = {

    -- leaf station: one entrance, aimed down the tube to B
    a = {
      monitor = "right", pad_detector = "player_detector_0", board_range = 2,
      exits = {
        toB = { to = "b", controller = "Create_RotationSpeedController_0", rpm = 32 },
      },
    },

    -- station + 3-way JUNCTION: a central hub pad with three entrances
    b = {
      monitor = "right", pad_detector = "player_detector_0", board_range = 2,
      exits = {
        toA = { to = "a", controller = "Create_RotationSpeedController_0", rpm = 32 },
        toC = { to = "c", controller = "Create_RotationSpeedController_1", rpm = 32 },
        toD = { to = "d", controller = "Create_RotationSpeedController_2", rpm = 32 },
      },
    },

    -- leaf station
    c = {
      monitor = "right", pad_detector = "player_detector_0", board_range = 2,
      exits = {
        toB = { to = "b", controller = "Create_RotationSpeedController_0", rpm = 32 },
      },
    },

    -- leaf station
    d = {
      monitor = "right", pad_detector = "player_detector_0", board_range = 2,
      exits = {
        toB = { to = "b", controller = "Create_RotationSpeedController_0", rpm = 32 },
      },
    },

  },
}
