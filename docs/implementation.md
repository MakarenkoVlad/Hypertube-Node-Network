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

**Per node:** Advanced Computer; **Ender Modem** (unlimited / cross-dimension range); one Hypertube Entrance + Create Clutch + Redstone Relay (+ Wired Modem) **per exit**; Networking Cable; Advanced Monitor (≥3×2) if it's a boarding station; a **Player Detector** (Advanced Peripherals) at the boarding pad for "who is standing here" detection; optional arrival plate/attachment and indicator lamps.

---

## 6. Build per node

1. **Entrances** — one departure entrance per exit, each aimed down its tube, with a boarding/arrival pad they can reach. Set the gap from Step 0.
2. **Power + gating** — two options per entrance. **(a) Rotational Speed Controller** (recommended if the computer drives it): feed the entrance's rotation through an RSC and let the computer set its target speed — an RPM to run, `0` to stop. Config: `{ controller = "<RSC name/side>", rpm = 32 }`. **(b) Create Clutch + Redstone Relay**: rotation through a clutch (`redstone ON = braked = off`); config `{ relay, side, invert = true }`.
3. **Wire the gate to the computer** — for an **RSC**, place it against the computer (wrap by side) or on a **Wired Modem** + **Networking Cable** (network name like `Create_RotationSpeedController_0`). For a **relay**, put a Wired Modem on each Redstone Relay and cable it to the computer. Confirm names in-game with `peripheral.getNames()`.
4. **Computer + modem** — Advanced Computer with the **Ender Modem** on a free face; Advanced Monitor against it for stations.
5. **Lock mode** — wrench entrances to the mode chosen in Step 0.
6. **Optional arrival detector** — arrival plate/attachment into a **side of the computer** so it pulses when someone exits here.
7. **Boarding pad + Player Detector** — one block the rider stands on, with this node's 2–3 departure entrances **facing that block** from different sides. Place a **Player Detector** (Advanced Peripherals) at the pad, connected to the computer (wired modem, or adjacent). The node opens only the entrance toward the chosen destination, so the rider on the pad is pulled into the right tube.

**Player detection.** With a Player Detector set (`PAD_DETECTOR`), the node reads who's on the pad via `getPlayersInRange(BOARD_RANGE)`: it greets them by name and only launches while a player is actually standing there. The rider's name rides along and shows on the destination's screen ("Arriving: …"). Leave `PAD_DETECTOR = nil` to disable this (a bare pressure plate can still confirm presence, but not identity). The computer also labels itself with its node id on boot, so each machine is named in-game.

---

## 7. Control software & protocol

`src/hypertube_node.lua` runs on every computer and is both the routing node and (if it has a monitor) the boarding terminal.

Wireless protocol (rednet, `"hypertube"`). Every message is a table with a `type`:

- `ROUTE{ trip }` — broadcast when a destination is tapped. `trip = { id, from, to, rider, ts, path }`. Each node records it as the shared `active` trip and powers its exit toward `to` **only if it is on `path`** — so a junction never grabs a passer-by for a trip routed elsewhere. `rider` is the boarder's name from the Player Detector.
- `ARRIVED{ tripId, at }` — the destination node broadcasts this when its arrival detector fires; every node clears `active` and releases its gates.
- `SYNC_REQ{}` / `SYNC_RES{ active, recent }` — on boot a node asks the others for the current state and adopts it, so a freshly placed or rebooted computer catches up on a trip already in progress.

**Shared travel state.** Every node holds the *same* view: `active` (the current trip, or nil) and `recent` (a short log of finished trips). It's replicated by the messages above and resynced on boot, so all terminals show the same live status (e.g. "Net: Alice  Home→Farm"). Player detection stays local — only the optional `rider` name goes on the wire; the node polls `getPlayersInRange` to greet whoever's on the pad and listens for `playerClick` to refresh instantly.

Still **one trip at a time** network-wide (single-occupancy): while `active` is set, terminals show busy and refuse a new launch until `ARRIVED` or `TRIP_TIMEOUT` (default 30 s).

Trip flow (A→C through junction B):

```
Tap "Station C" at A
  -> ROUTE{ trip = { from=a, to=c, path={a,b,c}, rider="Alice", ... } } broadcast
  -> a powers toB;  b is on path -> powers toC (switch!);  c releases (arrive);
     d is OFF-path -> stays released, grabs nobody
  -> you board a's exit, fly through B onto the C tube, drop out at C
  -> C detector -> ARRIVED{tripId} -> every node clears
```

---

## 8. Install & configure

On each computer: `edit startup`, paste `hypertube_node.lua`, save, reboot. Then edit the CONFIG block:

- `STATION` — this node's id.
- `STATIONS` — destination directory for the menu (stations only; identical on every terminal).
- `EXITS` — one entry per departure entrance: a speed controller `{ controller, rpm }` (Create RSC) **or** a relay `{ relay, side, invert }`.
- `ROUTES` — destination → exit (or `"RELEASE"`).
- `MODEM`, `MONITOR` (nil for headless junctions), optional `DETECT` (arrival plate).
- `PAD_DETECTOR` — Advanced Peripherals Player Detector at the pad (name/side), or `nil` to disable player detection; `BOARD_RANGE` — blocks around it counted as "on the pad" (default 2).

`config/stations.example.lua` has a complete worked network including the junction. Find peripheral names with `lua` → `peripheral.getNames()`. For anything bigger than a few nodes, generate these blocks instead of hand-writing them (§9) and deploy them with the installer (§10).

---

## 9. Auto-generating routes (build step)

Hand-writing ROUTES per node is fine for a few stations but gets error-prone as the network grows: every new station or junction means editing *every* node's table. Since the topology is just a graph, describe it **once** and generate every node's tables by shortest path.

- **Describe the network** in one file — `config/network.example.lua`. It `return`s `{ stations = {...}, nodes = {...} }`, where each node lists its physical `exits` and, per exit, the neighbour it leads `to` (the graph edge) plus the same `relay`/`side`/`invert` gate wiring that goes into EXITS.
- **Generate** with the off-game build step:

  ```bash
  lua tools/build_routes.lua config/network.example.lua      # writes config/generated/<node>.lua
  lua tools/build_routes.lua config/network.example.lua -     # or print the blocks to stdout
  ```

  For every node it runs a shortest-path (BFS) search to each station and emits that node's next-hop EXITS + ROUTES block, plus the shared STATIONS directory (every node carries it so each config is self-contained). It prints a routing matrix for review and warns about unreachable destinations.
- **Deploy** the emitted block by pasting it over the CONFIG section at the top of `src/hypertube_node.lua` on that node, or automate it with the installer (§10).

The emitted EXITS/ROUTES are the **same runtime format** the firmware already consumes — nothing in `hypertube_node.lua` changes and hand-written configs keep working. A junction still falls out for free: the generator simply finds that a node with 2+ exits sends different destinations down different tubes.

`tools/build_routes.lua` is the only non-firmware file in the repo: it runs on your dev machine's `lua` (standard Lua I/O), not on an in-game computer. `config/generated/` is git-ignored — it's a build artifact; regenerate it from the graph whenever the topology changes.

---

## 10. Deploying with the installer

`src/install.lua` turns the build output into a ready `/startup` on a fresh computer — no hand-editing the config block.

1. **Build the bundle** off-game (config blocks plus pre-spliced startups):

   ```bash
   lua tools/build_routes.lua config/network.example.lua --startup
   ```

   Per node this writes both `config/generated/<node>.lua` (config block) and `config/generated/<node>.startup.lua` (firmware + config already spliced).
2. **Get the files in-game**, either way:
   - **Disk** — copy `src/hypertube_node.lua`, `src/install.lua`, and the `config/generated/` files onto a floppy; or
   - **HTTP** — host the repo somewhere with raw URLs (GitHub raw, pastebin).
3. **Run it on each computer**:

   ```
   install                -- pick this node from a menu (disk)
   install <node>         -- install a named node
   install --src /disk    -- use a specific directory as the bundle
   install --url <base>   -- fetch firmware + config over HTTP from <base>
   ```

   The installer locates this node's config, splices it into the firmware between the `@HT-CONFIG-START` / `@HT-CONFIG-END` markers (or copies a pre-built `<node>.startup.lua` if present), writes `/startup`, sets the computer label to the node id, and offers to reboot.

The markers are the only firmware change this needs: everything between them is per-node config (STATION/STATIONS/EXITS/ROUTES/MODEM/MONITOR/DETECT); PROTO and TRIP_TIMEOUT sit below the end marker and are never touched. Hand deployment still works (paste the firmware, paste a `<node>.lua` block between the markers) — the installer just automates it.

---

## 11. Limitations & tradeoffs

- **One traveller at a time** per network — the shared `active` state is replicated to every node, and a node only powers gates when it's on the active trip's path, so off-path stations stay idle. Concurrent trips would need block-signalling (future work).
- **Adding a station is two edits** — one `nodes` entry (for its monitor/detector) plus one `links` connection per tube. The builder fills routes, paths, and the reciprocal exit at both ends, and warns on one-way or unreachable tubes (§9).
- **Step 0 is load-bearing** — everything assumes hand-off, release, and switch/redirect behave as tested.

---

## 12. Growth

- **More stations / branches** — add nodes and exits; extend each affected node's ROUTES. A new junction is just a node with another exit.
- **Cross-dimension** — Ender Modems make a Nether/End station just another node.
- **Hub-and-spoke** — one node with one exit per base; every base tubes into it; it switches you out the right spoke. Same model, routing concentrated at the hub.
- **Auto-generated routes** — the topology is a graph, so `tools/build_routes.lua` computes each node's ROUTES (shortest path) from one network description instead of hand-writing them (§9). Adding a station/branch is then a one-line graph edit plus a regenerate.

---

## 13. Troubleshooting

- **Won't forward / catch:** recheck Step 0 gap + facing; confirm the forward exit is actually powered (clutch un-braked) during the trip.
- **Junction sends you the wrong way:** check that node's `ROUTES[dest]` and that each `EXITS` name maps to the right physical tube.
- **Overshoots the stop:** destination node isn't releasing — it should have `ROUTES[dest] = "RELEASE"` (or no entry) for itself.
- **"No route to X":** this node's ROUTES has no entry for X — add it (or, if you generate routes, fix the graph so X is reachable; `tools/build_routes.lua` warns about exactly this and leaves the entry out).
- **Stuck "Line busy":** no `ARRIVED` received — wire a detector or lower `TRIP_TIMEOUT`.
- **Relay not found:** the network name doesn't match config — right-click the relay's wired modem to read it.
- **Modem range warning:** swap the plain modem for an **Ender Modem**.
- **Installer can't find the bundle:** insert the deploy disk, or pass `--src <dir>` / `--url <base>`. If it errors about missing `@HT-CONFIG` markers, the firmware on the bundle has had them removed — restore them around the config region.
```
