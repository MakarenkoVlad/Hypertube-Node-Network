# Smart Hypertube Network — Implementation

A wireless, computer-routed hypertube system for Minecraft (NeoForge 1.21.1) using **Create: Hypertubes** + **CC: Tweaked**. Walk up to any station, tap a destination, and the network routes you there — including across **junctions that switch you onto one of several tubes**.

Firmware: `src/hypertube_node.lua` (one file on every computer).

---

## 1. The core idea

Create: Hypertubes has **no junction/splitter block yet**, so the whole system is built from one primitive: a **computer-toggled entrance**. A powered entrance catches a passing traveller and forwards them (this is how the mod's Hypertube *cannon* chains work); an unpowered one lets them drop out where they are.

From that single primitive you get everything:

- **Hand off** — power the forward entrance so a through-traveller continues.
- **Release** — leave entrances off so the traveller drops out = *arrived*.
- **Switch** — at a junction with two (or more) forward entrances, power the one toward the destination. That is the "switch among two tubes" behaviour.

The computer at each node just decides which of its entrances, if any, to power for the current trip.

---

## 2. Routing model: exits + route tables

Every node has:

- **EXITS** — the named entrances it can power (e.g. `toMine`, `toFarm`, `toNether`).
- **ROUTES** — for each destination id, which exit forwards toward it. A destination reached by dropping out *here* maps to `"RELEASE"`.

A trip is one broadcast: `ROUTE{ dest }`. Every node looks up `ROUTES[dest]`:

```
exit = ROUTES[dest]
  exit == "RELEASE" / nil  ->  power nothing  (traveller drops out here)
  otherwise                ->  power EXITS[exit], leave the rest off
```

That one rule covers all three roles:

| Node role | EXITS | ROUTES example |
|---|---|---|
| End station | one (`toLine`) | every other dest → `toLine`; self → `RELEASE` |
| Pass-through | two (`toA`,`toB` opposite ways) | "forward" dests → `toA`, "back" dests → `toB` |
| **Junction (switch)** | two+ (`toFarm`,`toNether`,…) | `farm`→`toFarm`, `nether`→`toNether`, … |

This is distributed routing: each node only knows its *own* next hop for each destination. No central map, no junction block — a junction is just a node whose ROUTES point different destinations at different exits.

---

## 3. A switching junction, concretely

```
      main_base ==== mine ==== [ JCT ] ==== farm
                                  ||
                               nether
```

`JCT` is headless (no monitor). It has three exits — `toMine`, `toFarm`, `toNether` — and this table:

```lua
ROUTES = {
  main_base = "toMine", mine = "toMine",  -- traffic heading back
  farm   = "toFarm",                      -- switch onto tube A
  nether = "toNether",                    -- switch onto tube B
}
```

So a traveller from `mine` bound for `nether` reaches `JCT`, which powers **only** `toNether`; they're caught and sent down the Nether tube. Bound for `farm`, `JCT` powers `toFarm` instead. Same hardware, the computer flips the switch per trip. (Full per-node config for this network: `config/stations.example.lua`.)

Physically a junction is an **arrival point with two+ departure entrances**, each aimed down its branch; the powered one grabs the arriving traveller and redirects them onto its tube.

---

## 4. Step 0 — verify the mechanic FIRST (do not skip)

Confirm these in a flat **creative** world before building anything large:

1. **Hand-off** — `Entrance A → tube → gap → Entrance B`, both powered, same facing. Ride in: does B catch you across the gap and send you on? Note the largest gap that still catches (≈1–2 blocks).
2. **Release** — cut B's power (Create Clutch + redstone, or a redstone-lock if supported). Ride in: do you drop out at the gap?
3. **Switch / redirect** — two powered exits aimed different ways at one arrival point; power only one. Does an arriving traveller get redirected onto the powered branch (even at an angle)? This is what junctions rely on.

Also note which **lock mode** (wrench) still lets an in-flight traveller be caught, and whether the entrance can be **redstone-disabled directly** (if so, skip the Clutch and set `invert = false`). Record the working gap, facing, switch geometry, and gate method — those are the only physical unknowns.

---

## 5. Bill of materials

**Shared:** CC: Tweaked **1.114+** (Redstone Relay block; runs natively on NeoForge 1.21.1), one Create rotation source with enough SU, and the hypertube tubes themselves.

**Per node:** Advanced Computer; **Ender Modem** (unlimited / cross-dimension range); one Hypertube Entrance + Create Clutch + Redstone Relay (+ Wired Modem) **per exit**; Networking Cable; Advanced Monitor (≥3×2) if it's a boarding station; optional arrival plate/attachment and indicator lamps.

---

## 6. Build per node

1. **Entrances** — one departure entrance per exit, each aimed down its tube, with a boarding/arrival pad they can reach. Set the gap from Step 0.
2. **Power + gating** — rotation from the shared source through a **Create Clutch** into each entrance (`redstone ON = braked = off`). If the entrance is redstone-lockable, wire that instead and set `invert = false`.
3. **Relays** — a **Redstone Relay** per exit, output wired to its clutch (and optional lamp). Put a **Wired Modem** on each relay; connect by **Networking Cable** to a wired modem on the computer. Right-click each modem and note the printed name (e.g. `redstone_relay_1`).
4. **Computer + modem** — Advanced Computer with the **Ender Modem** on a free face; Advanced Monitor against it for stations.
5. **Lock mode** — wrench entrances to the mode chosen in Step 0.
6. **Optional detector** — arrival plate/attachment into a **side of the computer** so it pulses when someone exits here.

---

## 7. Control software & protocol

`src/hypertube_node.lua` runs on every computer and is both the routing node and (if it has a monitor) the boarding terminal.

Wireless protocol (rednet, `"hypertube"`):

- `ROUTE{ dest, trip }` — broadcast when a destination is tapped. Every node sets its gates from `ROUTES[dest]`.
- `ARRIVED{ at, trip }` — broadcast by the destination node when its detector fires; every node clears the line (gates off, ready for the next trip).

Without detectors, each node clears after `TRIP_TIMEOUT` (default 30 s). Because gate states are network-wide, **one trip travels at a time**: while a trip is live, terminals show "Line busy" and refuse a new launch until `ARRIVED` or timeout.

Trip flow:

```
Tap "Nether Hub" at Mine
  -> ROUTE{dest=nether} broadcast
  -> mine powers toJct; JCT powers toNether (switch!); nether powers nothing
  -> you board mine's toJct exit, fly through JCT onto the Nether tube, drop out at Nether
  -> Nether detector -> ARRIVED -> whole line resets
```

---

## 8. Install & configure

On each computer: `edit startup`, paste `hypertube_node.lua`, save, reboot. Then edit the CONFIG block:

- `STATION` — this node's id.
- `STATIONS` — destination directory for the menu (stations only; identical on every terminal).
- `EXITS` — one entry per departure entrance, with its relay name/side and `invert`.
- `ROUTES` — destination → exit (or `"RELEASE"`).
- `MODEM`, `MONITOR` (nil for headless junctions), optional `DETECT`.

`config/stations.example.lua` has a complete worked network including the junction. Find peripheral names with `lua` → `peripheral.getNames()`. For anything bigger than a few nodes, generate these blocks instead of hand-writing them — see §9.

---

## 9. Auto-generating routes (build step)

Hand-writing ROUTES per node is fine for a few stations but gets error-prone as the network grows: every new station or junction means editing *every* node's table. Since the topology is just a graph, describe it **once** and generate every node's tables by shortest path.

- **Describe the network** in one file — `config/network.example.lua`. It `return`s `{ stations = {...}, nodes = {...} }`, where each node lists its physical `exits` and, per exit, the neighbour it leads `to` (the graph edge) plus the same `relay`/`side`/`invert` gate wiring that goes into EXITS.
- **Generate** with the off-game build step:

  ```bash
  lua tools/build_routes.lua config/network.example.lua      # writes config/generated/<node>.lua
  lua tools/build_routes.lua config/network.example.lua -     # or print the blocks to stdout
  ```

  For every node it runs a shortest-path (BFS) search to each station and emits that node's next-hop EXITS + ROUTES block (plus STATIONS on any node with a monitor). It prints a routing matrix for review and warns about unreachable destinations.
- **Deploy** the emitted block by pasting it over the CONFIG section at the top of `src/hypertube_node.lua` on that node, then reboot.

The emitted EXITS/ROUTES are the **same runtime format** the firmware already consumes — nothing in `hypertube_node.lua` changes and hand-written configs keep working. A junction still falls out for free: the generator simply finds that a node with 2+ exits sends different destinations down different tubes.

`tools/build_routes.lua` is the only non-firmware file in the repo: it runs on your dev machine's `lua` (standard Lua I/O), not on an in-game computer. `config/generated/` is git-ignored — it's a build artifact; regenerate it from the graph whenever the topology changes.

---

## 10. Limitations & tradeoffs

- **One traveller at a time** per network (gate states are shared). Fine for a base/SMP; concurrent trips need block-signalling (future work).
- **Static routing tables** — each node lists its next hop per destination. Clear and flexible; for larger networks, generate them from a single graph with `tools/build_routes.lua` instead of hand-writing (§9).
- **Step 0 is load-bearing** — everything assumes hand-off, release, and switch/redirect behave as tested.

---

## 11. Growth

- **More stations / branches** — add nodes and exits; extend each affected node's ROUTES. A new junction is just a node with another exit.
- **Cross-dimension** — Ender Modems make a Nether/End station just another node.
- **Hub-and-spoke** — one node with one exit per base; every base tubes into it; it switches you out the right spoke. Same model, routing concentrated at the hub.
- **Auto-generated routes** — the topology is a graph, so `tools/build_routes.lua` computes each node's ROUTES (shortest path) from one network description instead of hand-writing them (§9). Adding a station/branch is then a one-line graph edit plus a regenerate.

---

## 12. Troubleshooting

- **Won't forward / catch:** recheck Step 0 gap + facing; confirm the forward exit is actually powered (clutch un-braked) during the trip.
- **Junction sends you the wrong way:** check that node's `ROUTES[dest]` and that each `EXITS` name maps to the right physical tube.
- **Overshoots the stop:** destination node isn't releasing — it should have `ROUTES[dest] = "RELEASE"` (or no entry) for itself.
- **"No route to X":** this node's ROUTES has no entry for X — add it (or, if you generate routes, fix the graph so X is reachable; `tools/build_routes.lua` warns about exactly this and leaves the entry out).
- **Stuck "Line busy":** no `ARRIVED` received — wire a detector or lower `TRIP_TIMEOUT`.
- **Relay not found:** the network name doesn't match config — right-click the relay's wired modem to read it.
- **Modem range warning:** swap the plain modem for an **Ender Modem**.
```
