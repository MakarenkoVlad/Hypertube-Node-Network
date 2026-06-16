# Hypertube Network — design, hardware & protocol reference

One firmware (`src/ht_node.lua`) runs on every computer, unchanged. There is no central network
graph and no per-node generated code — each node discovers its hardware, learns the topology from
its peers, and routes for itself. This is the canonical reference; `README.md` is the quickstart.

## 1. What each node does on its own

1. **Discovers its peripherals** by capability — the Ender modem, the monitor (largest if several),
   the Player Detector, and every Create Rotational Speed Controller (one per tube). No names typed.
2. **First boot — on-screen setup** (saved to `/ht_node.cfg`; re-run with `firmware.lua setup`):
   - name the node (e.g. `hub`, `mine`, `nether_hub`);
   - for each tube, type which node it reaches (use `firmware.lua spin` first to see which tube is which);
   - optionally add **portal links** — a neighbour reached by walking through a portal (no tube).
3. **Gossips the topology** over rednet — every node holds the whole map and computes shortest paths
   itself. Add a node and the rest learn it automatically.
4. **Routes any node to any node**, opening only the tube toward the next hop at each junction.

### The boarding menu

The Advanced Monitor shows a control bar — **Sort** (tap to cycle nearest-first → farthest-first → A–Z)
and **Find** (tap for an on-screen keyboard that filters the list by name substring) — over a scrollable
list where each stop shows its **hop-distance** (`direct` / `N hops`). A **▲/▼** bar appears when the list
overflows. Tap a stop to travel. Hop-distance comes from the same shortest-path used for routing.

## 2. Hardware per node

- **Advanced Computer** (gold) — runs the firmware. Advanced so the colour touch menu renders.
- **Advanced Monitor** — the destination menu; tap to travel.
- **Ender Modem** on the computer — the only link between nodes. Wireless and **cross-dimension**,
  so the network spans Overworld/Nether/End with no cabling between nodes.
- **Player Detector** (Advanced Peripherals, type `player_detector`) at the boarding pad — greets the
  rider, gates launches until someone is on the pad, and confirms arrival.
- One **Create Rotational Speed Controller (RSC)** per tube entrance, on the computer's wired network.

### One node = one isolated wired network

The computer connects by **networking cable + wired modems** to **only its own** monitor, detector,
and controllers. **Never** bridge two nodes onto one wired network — if you do, every computer sees
every peripheral, reports the wrong tube count, and several computers fight over one monitor. The
Ender modem (wireless) is the *only* thing that should cross between nodes. Use `firmware.lua diag`
to see exactly what one computer sees; more than one monitor or detector is the tell-tale of a
shared network.

### Gates

A tube is **opened** by spinning its controller (`setTargetSpeed(RPM)`, `RPM = 128`) and **closed**
with `setTargetSpeed(0)`. Create: Hypertubes entrances need **≥16 RPM** to activate, so the
calibration spin (`firmware.lua spin`) uses 20 RPM — visible but gentle.

### Junction geometry (physical — code can't fix it)

A hypertube ejects you straight out of its mouth. At a junction the through-tube's entrance must
**catch you at roughly 90°** as you cross it; two entrances pointed **head-on** blow against each
other and the hand-off fails. A hub (one computer, several tubes around a central pad) is a junction:
arrange the tubes so each through-route turns rather than meeting an opposing mouth.

## 3. Routing & shared map

- Each node keeps the whole topology: `graph` (node → neighbours) and `gen` (node → last-refresh
  epoch ms). Nodes broadcast their **entire** known map (`STATE`), so one reply hands a newcomer the
  full network. On merge, the newer timestamp wins (a node's own fresh news beats a stale gossiped copy).
- **The trip is shared state too.** The same `STATE` message carries the single network `trip`
  (`{ id,from,to,path,rider,ts,done }`), saved to `/ht_graph.dat` next to the map. `pathTo` is BFS
  shortest path; `startTrip` writes the trip and gossips it, and each node `reconcile`s — opening only
  the tube toward its next hop — to whatever the shared trip says. The destination flips `done = true`.
- The map (and trip) are **persisted to `/ht_graph.dat`** and quiet nodes are **not** forgotten —
  "quiet" almost always means "chunk unloaded", and a node must route to (and resume a trip through) a
  stop whose computer is off.

### Seed the map once

A fresh node knows only its own tubes until it hears the map. So after setup, **take one trip from
each station to its direct neighbour** — a direct hop needs no map, and the reply teaches that
station the whole network, which it saves. After that, multi-hop is reliable even with other nodes
unloaded.

## 4. Chunk-tolerance (why multi-hop works with nodes offline)

A CC computer **stops when its chunk unloads** and **cold-boots (RAM wiped, files kept) when it
reloads**. So a junction is usually *off* when you launch toward it. Because the trip is **shared
state** (gossiped + persisted), the firmware copes without ever needing a *specific* peer alive:

- routes — and **resumes a trip** — from the **persisted** map+trip even if every peer is offline. A
  junction that reloads mid-route reads the trip straight off its own `/ht_graph.dat`;
- gossips the trip in `STATE`; `adoptTrip` merges it by a **(ts, id) total order** so every node
  converges on the same trip, and `done` is **monotonic** (once true, never un-done);
- the trip **ages out at `TRIP_TIMEOUT`** — the absolute deadline AND the finished-marker that blocks a
  late gossip from resurrecting it. `ts` is fixed per id, so a beat/gossip can never push the deadline;
- on boot a node restores the trip from disk, then `broadcastState` + `LSREQ` pull the latest trip/`done`
  from any reachable peer;
- **gates are DETECTOR-GATED.** A node opens its onward tube only while the trip's **own rider** (by name)
  is on its pad, and closes it the instant they leave. A gate **never opens speculatively** for a trip
  whose rider isn't here — so a finished, phantom-live (destination missed the arrival), or resurrected
  trip can't suck a bystander in, even when a reloaded node can't reach a peer. A reloaded junction still
  delivers: the rider drops onto its pad and is flung onward. (`RELAUNCH_HOLD` is a brief, trip-scoped
  cooldown after the rider leaves, so a bounce isn't instantly re-grabbed.)
- the destination flips the shared trip to `done` only when its detector sees **the trip's own rider**
  (matched by name, so a bystander can't complete someone else's trip); the `done` then gossips network-wide.

`test/htsim.lua` reproduces exactly this — including a junction that **reloads alone with no peer
reachable** and recovers the trip from its own disk (Phase 14) — and asserts the merge order, expiry,
suck-back guard, and convergence behave. Run it after any change to routing or the trip/gossip logic.

## 5. Cross-dimension (Nether / End)

Ender modems carry rednet (and the live trip) across dimensions, but a tube can't cross a portal, so
a cross-dimension hop is a **portal link**. The route brings you to the portal node; its screen says
*"Walk through the portal to <node>"*; the node on the far side already has the trip from the shared
broadcast and resumes it when its detector sees you arrive. Add a portal neighbour during setup (the
"Portal (walk-through) to which node?" prompt); leave it blank for a normal tube-only node.

**Example — a portal to a roof base:** build a portal between your hub and the roof spot; put a node at
each end (e.g. `hub` and `roof`); on `hub` answer the portal prompt with `roof`, and on `roof` answer it
with `hub`. Now any stop can route to `roof`: you ride to the hub, the screen says *"Walk through the
portal to roof,"* you step through, and you're there. A roof/Nether node needs no tubes at all — a
detector + computer + ender modem is enough. Covered end-to-end by `test/htsim.lua` Phase 11
(`Surface → Hub → Roof`, where the `Hub → Roof` hop is a portal).

## 6. rednet protocol

Protocol strings: `"hypertube"` (routing/gossip), `"ht_ota"` (updates), `"ht_log"` (the log viewer).
Messages are typed tables; receivers filter by protocol and guard on shape.

| Type | Sent by | Meaning |
|---|---|---|
| `STATE{ nodes, trip }` | boot, heartbeat, beat, on `LSREQ` | the WHOLE shared state: the map `nodes[name]={ nbrs, ts }` **and** the single `trip` (`{id,from,to,path,rider,ts,done}` or nil). Receiver merges the map (fresher ts wins) and the trip (`adoptTrip`: (ts,id) order, `done` monotonic). |
| `LSREQ{}` | boot, warm-up | "send me your shared state" — each node replies with `STATE` (map + trip). |
| `HT_UPDATE{ code,group }` (`ht_ota`) | `ht_push` | OTA push; `ht_boot` replaces `/firmware.lua` and reboots. |
| `{ ping }` / `{ node,ver,msg }` (`ht_log`) | `htlog` / each node's `log` | version ping / live log line. |

**OTA preserves config because config is a separate file.** `/ht_node.cfg` is independent of
`/firmware.lua`, so an update is a whole-file replace — nothing in the firmware needs preserving.

## 7. Install / update / operate

**Install** (same on every node — set `BASE` in `src/installer.lua` first):

```
wget run <BASE>/src/installer.lua            # a normal node
wget run <BASE>/src/installer.lua junction   # optional: tag an OTA update-group
```

Pastebin alternative: fill the codes in `src/pastebin_install.lua`, then `pastebin run <code>`.

**Update — push once, it propagates on chunk load.** Edit `src/ht_node.lua`, then `./push.sh`. Every node
**auto-updates from GitHub when its chunk loads**: `ht_boot` fetches `BASE/src/ht_node.lua` on boot and
installs it if strictly newer (config untouched). So you push once and never visit a node to update it.

The download is integrity-checked before it's ever written: it must end with the **`@HT-NODE-EOF`
sentinel** (so a connection dropped mid-transfer is rejected) AND compile as valid Lua, so a partial or
garbage fetch can't brick a node; a node that's somehow already corrupt self-heals on the next boot. Drop
a `/ht_pin` file on a node to freeze it on its current firmware. (Maintenance invariant: keep `@HT-NODE-EOF`
the last line of `ht_node.lua` — nothing after it.)

For nodes that are **already loaded** (auto-update only fires on boot), push instantly over rednet:
```
wget <BASE>/src/ht_node.lua firmware.lua
ht_push firmware.lua
```

**Confirm the rollout** with `htlog` → press **V** (or `htlog versions`): a census of every *loaded* node
and its firmware version, flagging any on an older build. Travel the line so the stragglers' chunks load
and auto-update, until it's all-green. The version is also on each monitor's top-right and the boot line.

**Operate** (on a node's computer):

| Command | What |
|---|---|
| `firmware.lua setup` | rename / re-map tubes (type on the computer, not the monitor). |
| `firmware.lua spin [n]` | spin tubes to identify them (step off the pad — 5 s countdown). |
| `firmware.lua diag` | print name, version, peripherals, and which monitor it draws to; warn on a shared wired network. |
| `firmware.lua monitor` | pick which screen is this node's menu when it has several monitors (pinned in config, survives OTA). |
| `firmware.lua reset` | wipe config + learned map; reboot into fresh setup. |
| `firmware.lua forget` | drop only the learned map (re-learn topology); keep name + tubes. |
| `firmware.lua log` | print this node's local event log. |
| `firmware.lua report` | write a full diagnostic snapshot to `/ht_report.txt` (config, peripherals, map, log) — `pastebin put` it to share. |
| `firmware.lua set <KEY> <n>` | tweak a tunable in-game (`/ht_tune.cfg`, survives OTA, reboots to apply). Keys: RPM, CALIBRATE_RPM, TRIP_TIMEOUT, TRIP_BEAT, RELAUNCH_HOLD, LS_INTERVAL, BOARD_RANGE, BOARD_HEIGHT. |

For a whole-network trace, run `htlog` while reproducing an issue — it tees every node's log to
`/htlog.txt`; `pastebin put /htlog.txt` to share it.

## 8. Limits

- **Single-occupancy** — one trip at a time across the whole network (re-tapping re-routes; a trip
  clears on arrival or `TRIP_TIMEOUT`). Concurrency is on the roadmap (`CLAUDE.md`).
- The physical hand-off (gap, facing, lock mode) is only settled in-game; record what works here once confirmed.
