--[[
  HUB with 4 spokes — one central computer, four entrances facing the pad.
  Matches the in-game build: stand in the middle, pick a stop, the matching
  Rotational Speed Controller spins up and launches you down that tube.

         Stop 2
            |
  Stop 1 --HUB-- Stop 3        (HUB = your one computer; 4 RSC-driven exits)
            |
         Stop 4

  ONE computer at the hub wraps all four RSCs over a wired network. Attach the
  four wired modems in order so the names line up:
     Create_RotationSpeedController_0 -> tube to Stop 1
     Create_RotationSpeedController_1 -> tube to Stop 2
     Create_RotationSpeedController_2 -> tube to Stop 3
     Create_RotationSpeedController_3 -> tube to Stop 4
  (Confirm the real names in-game with peripheral.getNames(); edit if different.)

  RENAME the four stops below to your actual bases, then regenerate:
     lua tools/build_routes.lua config/hub_4spoke.lua deploy --startup
  Deploy ONLY the hub computer to start — outbound trips work on their own. Add a
  small computer at each stop later for return trips + shared state.

  rpm = launch speed (<=256). Raise it if the entrances need a faster spin.
--]]

return {

  stations = {
    { id = "hub", name = "Hub"    },
    { id = "s1",  name = "Stop 1" },
    { id = "s2",  name = "Stop 2" },
    { id = "s3",  name = "Stop 3" },
    { id = "s4",  name = "Stop 4" },
  },

  nodes = {
    hub = { monitor = "right", pad_detector = "player_detector_0", board_range = 2 },
    s1  = { monitor = "right", pad_detector = "player_detector_0", board_range = 2 },
    s2  = { monitor = "right", pad_detector = "player_detector_0", board_range = 2 },
    s3  = { monitor = "right", pad_detector = "player_detector_0", board_range = 2 },
    s4  = { monitor = "right", pad_detector = "player_detector_0", board_range = 2 },
  },

  -- one link per tube; controller gates at both ends (RSC). rpm applies to both.
  links = {
    { a = "hub", b = "s1", a_controller = "Create_RotationSpeedController_0", b_controller = "Create_RotationSpeedController_0", rpm = 32 },
    { a = "hub", b = "s2", a_controller = "Create_RotationSpeedController_1", b_controller = "Create_RotationSpeedController_0", rpm = 32 },
    { a = "hub", b = "s3", a_controller = "Create_RotationSpeedController_2", b_controller = "Create_RotationSpeedController_0", rpm = 32 },
    { a = "hub", b = "s4", a_controller = "Create_RotationSpeedController_3", b_controller = "Create_RotationSpeedController_0", rpm = 32 },
  },
}
