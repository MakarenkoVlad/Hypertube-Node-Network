--[[
  NETWORK GRAPH — single source of truth for the whole topology.

      main_base ==== mine ==== [ JCT ] ==== farm
                                  ||
                               nether

  Describe the network ONCE here, then generate every node's EXITS + ROUTES:

      lua tools/build_routes.lua config/network.example.lua
        -> writes config/generated/<node>.lua  (paste each into its computer)

      lua tools/build_routes.lua config/network.example.lua -
        -> prints the blocks to stdout instead of writing files

  The generator computes each node's ROUTES by shortest path over this graph,
  so a junction is — as always — just a node with 2+ exits pointing different
  destinations at different tubes. The emitted EXITS/ROUTES are the SAME runtime
  format src/hypertube_node.lua already consumes; hand-written configs (see
  config/stations.example.lua) keep working unchanged.

  This file is plain data: it `return`s a table. It is not deployed to a
  computer — it only feeds the off-game build step.

  CONNECTIONS, TWO WAYS:
    * Per-node `exits` (used below): each node lists the entrances it powers,
      with `to = <neighbour>`. You wire BOTH ends yourself.
    * A top-level `links` list: declare a tube ONCE and the builder creates the
      reciprocal exit at both ends, so a connection is never half-wired:

        links = {
          { a = "main_base", b = "mine",
            a_relay = "redstone_relay_0", a_side = "back",   -- main_base's entrance -> mine
            b_relay = "redstone_relay_0", b_side = "back",   -- mine's entrance -> main_base
            invert = true },                                  -- both are clutches (default)
        }

  ADD A STATION: add one `nodes` entry (for its monitor/detector) plus one
  `links` connection per tube, then rebuild. The builder fills routes, paths and
  reciprocal exits, and warns on one-way or unreachable tubes.
--]]

return {

  -- Destinations shown on terminals. Order = on-screen menu order. Stations
  -- only; junctions are not destinations, so they are NOT listed here. The
  -- generator copies this list verbatim into every node that has a monitor.
  stations = {
    { id = "main_base", name = "Main Base"  },
    { id = "mine",      name = "Mineshaft"  },
    { id = "farm",      name = "Farm"       },
    { id = "nether",    name = "Nether Hub" },
  },

  -- Every computer in the network — stations AND headless junctions. Each node
  -- lists the physical entrances it can power (its exits). Per exit:
  --   to     = the neighbour node a traveller lands at when this exit is powered
  --            (this is the graph edge; the generator uses it for shortest path)
  --   relay  = network name of that entrance's Redstone Relay      ┐ copied
  --   side   = relay output wired to the gate                      │ verbatim
  --   invert = true -> redstone ON brakes the entrance (Clutch)    ┘ into EXITS
  -- Optional per node: monitor (side/name; omit for a headless junction),
  --   modem (default "top"), detect (arrival-plate computer side; default nil),
  --   pad_detector (Advanced Peripherals Player Detector name/side at the
  --     boarding pad; default nil = no player detection),
  --   board_range (blocks around that detector counted as "on the pad"; default 2).
  nodes = {

    main_base = {
      monitor = "right", pad_detector = "player_detector_0",
      exits = {
        toMine = { to = "mine", relay = "redstone_relay_0", side = "back", invert = true },
      },
    },

    mine = {
      monitor = "right", pad_detector = "player_detector_0",
      exits = {
        toMain = { to = "main_base", relay = "redstone_relay_0", side = "back", invert = true },
        toJct  = { to = "jct",       relay = "redstone_relay_1", side = "back", invert = true },
      },
    },

    jct = {
      -- headless junction: no monitor, switches travellers among three tubes
      exits = {
        toMine   = { to = "mine",   relay = "redstone_relay_0", side = "back", invert = true },
        toFarm   = { to = "farm",   relay = "redstone_relay_1", side = "back", invert = true },
        toNether = { to = "nether", relay = "redstone_relay_2", side = "back", invert = true },
      },
    },

    farm = {
      monitor = "right", pad_detector = "player_detector_0",
      exits = {
        toJct = { to = "jct", relay = "redstone_relay_0", side = "back", invert = true },
      },
    },

    nether = {
      monitor = "right", pad_detector = "player_detector_0",
      exits = {
        toJct = { to = "jct", relay = "redstone_relay_0", side = "back", invert = true },
      },
    },

  },
}
