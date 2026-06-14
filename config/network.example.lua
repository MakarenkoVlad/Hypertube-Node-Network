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
  --   modem (default "top"), detect (arrival-plate computer side; default nil).
  nodes = {

    main_base = {
      monitor = "right",
      exits = {
        toMine = { to = "mine", relay = "redstone_relay_0", side = "back", invert = true },
      },
    },

    mine = {
      monitor = "right",
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
      monitor = "right",
      exits = {
        toJct = { to = "jct", relay = "redstone_relay_0", side = "back", invert = true },
      },
    },

    nether = {
      monitor = "right",
      exits = {
        toJct = { to = "jct", relay = "redstone_relay_0", side = "back", invert = true },
      },
    },

  },
}
