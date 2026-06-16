# CLAUDE.md — Hypertube Network

Operating manual for Claude Code working in this repo. Read this fully before changing anything.

## What this project is

A **wireless, self-organizing, computer-routed hypertube transport network for Minecraft**
(NeoForge **1.21.1**). Players tap a destination on an in-game touchscreen and the network routes
them there, switching them through **junctions** and across **Nether/End portals**.

It runs **inside Minecraft**, not on this machine. The code targets **CC: Tweaked** (ComputerCraft),
drives **Create: Hypertubes**, and reads players with the **Player Detector** from **Advanced
Peripherals**. You can read, refactor, lint, simulate, and document the Lua here, but you **cannot
integration-test it in-game** — that only happens on a real ComputerCraft computer. The verification
bar is: `luacheck src/` clean, `lua test/htsim.lua` green, and careful reasoning through the event
loop and the distributed protocol.

## The architecture (one firmware, every node identical)

`src/ht_node.lua` runs on **every** computer, unchanged. There is **no per-node generated code** and
**no central network graph**. A node figures itself out:

- **Peripheral discovery by capability** (`findAll`): the wireless modem, the monitor (largest), the
  Player Detector (`getPlayersInRange`), and every Create Rotational Speed Controller (`setTargetSpeed`).
- **Config in `/ht_node.cfg`** — `{ name, links = { controllerName -> neighbourNodeName }, portals }`, plus,
  for a **portal mouth**, `{ mode = "mouth", bridge = { a, d, near } }` (see *Portal mouths* below).
  Written by on-screen `runSetup` on first boot; never touched by code updates.
- **Gossiped link-state.** Each node holds the WHOLE topology: `graph` (node -> neighbours) + `gen`
  (per-node last-refresh epoch). Nodes broadcast their entire known map (`STATE`); one reply hands a
  newcomer the full network. Timestamps make merges safe (fresher wins). The map is **persisted to
  `/ht_graph.dat`** so a node can route even while other nodes' chunks are unloaded.
- **Routing** is BFS shortest path over the undirected graph (`pathTo`). **The trip is SHARED state**,
  not a message: `startTrip` writes the single `trip` (`{ id,from,to,path,rider,ts,done }`) and gossips it
  inside `STATE`; each node `reconcile`s its gate to whatever the shared trip says (junction opens **only**
  the tube toward its next hop), and the destination flips `trip.done = true`.
- **A junction is just a node with several tubes.** No separate junction program.

### Chunk-tolerance is the hard requirement

A CC computer **stops completely when its chunk unloads** and **cold-boots (RAM wiped, files persist)
when it reloads**. So you cannot assume any other node is running. **The whole point of making the trip
shared state is this:** a reloaded node learns the trip from its OWN disk or ANY peer's gossip — never
from one specific live peer (the user's requirement: "peers might be offloaded"). The design copes by:

- persisting the **map AND the trip** to `/ht_graph.dat` (one shared-state file), so a node routes — and
  resumes a trip — from disk even with every peer unloaded;
- gossiping the trip in `STATE`; `adoptTrip` merges by a **(ts, id) total order** so every node converges
  on the same trip, with `done` **monotonic** (sticky-true) so a finished trip can't be un-finished;
- the trip **ages out at `TRIP_TIMEOUT`** (acting as the absolute deadline AND the finished-marker that
  blocks a late gossip from resurrecting it); `ts` is fixed per id, so beats/gossip can never push it;
- on boot, `loadGraph` restores the trip, then `broadcastState` + `LSREQ` converge the latest trip/`done`
  from peers;
- **gate policy by role.** A **JUNCTION** (mid-path) opens its onward tube **in advance / fly-through**
  while the trip is live (`reconcile` → `gateToward`), so a *moving* rider sails straight through and one
  who drops onto the pad lands at an already-open mouth and is pulled on (riders physically land **on the
  detector block**, so the tube must already be open). The **ORIGIN** is **detector-gated** (pad poll):
  it opens the launch tube only when the rider is on the pad — so a reload re-launches a rider still
  standing there — and auto-closes after `RELAUNCH_HOLD` (trip-id-scoped, anti-bounce). The **DESTINATION**
  flips `done` when its detector sees the trip's **own rider** (by name). Tradeoff: fly-through means a
  phantom-live/resurrected trip can hold a junction tube open until it **ages out at `TRIP_TIMEOUT`**
  (bounded, self-clearing) — accepted so riders never drop mid-route.

- **Auto-reboard (the sparse-loading workaround).** A node also remembers each rider's DESTINATION
  (`riderDest`, gossiped + persisted in `dests`). When a rider drops onto a hub that has **no live trip
  and no reachable peer** — the normal case when the whole line is unloaded except where you're standing —
  the hub **re-launches them itself** toward their remembered destination, using its own map (`startTrip`
  from there). So the destination "follows" the rider as durable state; a hub only needs to have heard it
  once (during a split-second pre-load) to recover a stranded rider with nobody else online. Cleared on
  arrival (a `to=nil` tombstone) and pruned after `DEST_TTL`.

This is the property `test/htsim.lua` exists to protect — it models unload/reload, a junction that
**reloads alone with no peer reachable** yet recovers the trip from its own disk (Phase 14), and a hub
that **auto-reboards a rider from memory with no live trip and no peer** (Phase 23). **Run it after any
change to routing, the trip merge/expiry, the rider-dest logic, or the gossip logic.**

### Portal mouths (bridge mode)

A cross-dimension hop where the portal sits **between two tubes** (ride → walk the portal → ride) is built
with **portal mouths**, not extra named stations. The two real stations on either side just point a normal
tube **at each other** (`A: tube → D`, `D: tube → A`) — one undirected graph edge `A—D`; the screen and menu
only ever show real stations. Each portal mouth (`cfg.mode == "mouth"`, `cfg.bridge = { a, d, near }`) is its
own computer + tube placed at the portal, configured in setup with **only the two real stations it bridges**
plus which side its tube flings toward (`near`); it auto-names itself `portal:near|far`.

A mouth is **off the routed path**: it advertises **no graph row** (`broadcastState`/the top-level `graph`
seed skip it when `MODE == "mouth"`), so it is never a routable destination and never appears in any menu. It
runs its own loop (`runMouth`, branched to before the station boot) that watches the single SHARED trip and
spins its tube toward `near` **in advance** iff the live trip's `path` contains the pair `(far, near)` as
**consecutive** entries — i.e. a rider is crossing this portal in this mouth's direction — and keeps it shut
otherwise, so a rider crossing the **other** way isn't re-grabbed. It reuses the same trip machinery
(`adoptTrip`/`live`/`mergeState`/`saveGraph`/`loadGraph`/`gateToward`), so a mouth that reloads mid-crossing
recovers the live trip from its own disk (Phase 24). Station logic is untouched — mouths are purely additive.
Distinct from the older walk-through `portals` field (a tubeless "walk through to X" neighbour, Phase 11),
which still exists for portals that drop you straight onto the far station's pad.

## Hard constraints (do not violate)

- **Minecraft 1.21.1 / NeoForge.** CC: Tweaked runs natively (no Sinytra Connector needed for CC).
  The Player Detector peripheral is from **Advanced Peripherals** (type `player_detector`).
- **CC: Tweaked Lua runtime = Lua 5.2 (Cobalt)** with some 5.3 features. No LuaJIT, no `require` of
  external libraries, no Lua 5.4-only syntax. Each program is a **single self-contained file**.
- **Globals are CC's APIs only** (`os`, `peripheral`, `rednet`, `term`, `colors`, `fs`, `parallel`,
  `textutils`, `read`, `sleep`, `http`, `shell`, `keys`, …). File I/O is the `fs` API, not `io`.
  See `.luacheckrc` for the allowed set.
- **No blocking `sleep()` inside the main event loop.** `sleep`/`rednet.receive` discard every event
  except their own while waiting — a blocking wait in the loop drops `timer`/`rednet_message`/
  `monitor_touch` events and can wedge a node. Use `os.pullEvent` + `os.startTimer` only. (`sleep` is
  fine in one-shot CLI subcommands like `spin`, which exit before the loop starts.)
- **`rednet.broadcast` throws if no modem is open.** Always go through the `bcast` helper (it
  `pcall`s and no-ops when no modem) so a modem-less node still boots, draws its screen, and runs.
- **Gate abstraction:** a tube is opened with `setTargetSpeed(RPM)` and closed with `setTargetSpeed(0)`.
  Entrances need **≥16 RPM** to open (so `CALIBRATE_RPM` is 20, above the threshold). Drive controllers
  only through `gateToward`/`allStop`.
- **Setup must own the keyboard.** `runSetup` runs **before** the main loop / OTA listener starts
  (see `ht_boot.lua`), blanks the monitor, and drains queued input — otherwise the live menu loop
  steals keystrokes (this was a real, repeatedly-hit bug). Don't reintroduce a concurrent loop during setup.

## One node = one isolated wired network (physical, but it shapes the code)

Each node's computer must be on its **own** wired-modem network — only its monitor, its detector, and
its own controllers. If two nodes' peripherals share one wired network, every computer sees all of
them, reports the wrong tube count, and fights over a shared monitor. The firmware can't fully fix a
miswire, but it should make it **diagnosable**: `firmware.lua diag` prints what the node sees and warns
on suspicious multiples (more than one monitor or detector). Keep that diagnostic working.

## rednet protocol (protocol string `"hypertube"`, plus `"ht_ota"` and `"ht_log"`)

Messages are plain tables with a `type`; always filter incoming by `protocol`. Keep senders and
handlers in sync — a message no one handles, or a handler for a shape no one sends, is a bug
(`probeNetwork` once parsed a `LS` reply that nodes had stopped sending).

| Type | Sent by | Meaning |
|---|---|---|
| `STATE{ nodes, trip, dests, tombs }` | `broadcastState` (boot, heartbeat, beat, on `LSREQ`) | the WHOLE shared state: the map `nodes[name]={ nbrs, ts }`, the single `trip` (`{id,from,to,path,rider,ts,done}` or nil), `dests` (`name -> { to, ts }`, each rider's remembered destination), AND `tombs` (`name -> removalTs`, node-removal tombstones). Receiver merges the map (fresher ts wins), the trip (`adoptTrip`: (ts,id) order, `done` monotonic), dests (`mergeDest`: newer ts wins; `to=nil` is an arrival tombstone), and tombs (`mergeTomb`: newer removalTs wins, never self). A tomb suppresses any row for that name with `ts <= removalTs`; a row with `ts > removalTs` un-removes the node. |
| `LSREQ{}` | boot, warm-up | "send me your shared state" — each node replies with `STATE` (map + trip). |
| `HT_UPDATE{ code,group }` (`ht_ota`) | `ht_push` | OTA firmware push; `ht_boot` swaps `/firmware.lua` and reboots. |
| `{ ping }` / `{ node,ver,msg }` (`ht_log`) | `htlog` / every node's `log` | version ping / live log line. |

> **The trip is shared state, not a message.** `startTrip` and arrival are just writes to `trip` that
> gossip via `STATE`; there are **no** `ROUTE`/`ARRIVED`/`TRIPREQ` messages (a reloaded node would lose
> them if no peer were live). Don't reintroduce point-to-point trip messages — put trip data in `STATE`.

> **Portal mouths consume `STATE` but add nothing to the map.** A mouth (`MODE == "mouth"`) sends `STATE`
> with **no row of its own** (`nodes` never contains its name) — it only relays others' rows + the trip and
> acts on the trip locally. So it stays invisible to routing and the menu. Don't make a mouth advertise itself.

> **Removing a node needs a TOMBSTONE, not just a delete.** The map deliberately never drops a quiet node
> (quiet usually = chunk unloaded), so a one-shot "delete" is undone the moment an offline node reloads and
> re-gossips its row. `firmware.lua forget <name>` writes a durable, gossiped+persisted `tombs[name]=now()`
> (carried in `STATE.tombs`) that suppresses any older row for that name network-wide and survives reloads
> (Phase 25). It self-heals: a node that's actually alive re-gossips a row with `ts > removalTs` and
> un-tombstones itself, so `forget` can't permanently kill a live node. `firmware.lua forget` with NO name keeps
> its old meaning (drop this node's learned map and re-learn). Tombs prune after `TOMB_TTL` (30 days).

> **OTA keeps config because config is a separate file.** In this unified model `/ht_node.cfg` is
> independent of `/firmware.lua`, so an update is a whole-file replace — there are no in-firmware
> config markers to preserve. (Earlier designs spliced config between `@HT-CONFIG` markers; that
> machinery is gone — don't reintroduce it.)

## Repo layout

```
CLAUDE.md                 this file
README.md                 human overview + quickstart
src/
  ht_node.lua             THE firmware (station / junction / router); same on every node
  ht_boot.lua             bootstrap installed as `startup`: runs firmware + OTA listener
  ht_push.lua             broadcast a firmware update to every node over rednet
  installer.lua           one-line install from GitHub raw
  pastebin_install.lua    one-shot install from pastebin codes (no GitHub)
  htlog.lua               live network log viewer (versions + trips)
test/
  htsim.lua               off-game simulator: routing + chunk unload/reload + trip relay (run it!)
docs/
  unified-node.md         design + hardware + wiring + protocol reference (canonical)
push.sh                   git add/commit/push helper; prints the node update command
.luacheckrc               luacheck config with CC: Tweaked globals
```

## Conventions

- **Tunables at the very top of `ht_node.lua`** (`RPM`, `CALIBRATE_RPM`, timeouts, `BOARD_RANGE`,
  file paths, `VERSION`). Logic is below. The numeric tunables (listed in `TUNABLES`) are
  overridable per-node at boot from `/ht_tune.cfg` via `firmware.lua set <KEY> <n>` — survives OTA
  like the config. If you add a tunable that should be settable, add it to `TUNABLES`, the boot
  override block, and the `report`/README key list.
- **Debugging:** `firmware.lua report` dumps a full snapshot to `/ht_report.txt` (config, peripherals,
  persisted map, tunables, recent `/ht.log`); `htlog` tees the network trace to `/htlog.txt`. Both are
  meant to be `pastebin put` and shared. Per-node files now: `/ht_node.cfg`, `/ht_graph.dat` (map **+ the
  shared trip**), `/ht_tune.cfg`, `/ht.log`, `/ht_report.txt` (and `/firmware.lua`, `/startup`, optional
  `/ht_group`).
- **Bump `VERSION`** (e.g. `v12` -> `v13`) on every firmware change. It's shown on the monitor and
  printed/logged on boot — it's how you confirm in-game that an OTA push actually landed.
- **rednet messages** are typed tables; filter by protocol; never trust shape (`type(x)=="table"` guards).
- **Discovery, never hard-coded peripheral names.** Names like `monitor_9` or
  `Create_RotationSpeedController_4` shift as wired modems are attached; the firmware finds peripherals
  by capability. Don't add name constants.
- **Touch UI** (`drawList`/`drawKeyboard`/`refresh`): a control bar (Sort cycle `SORTS` + Find), a
  scrollable list showing each stop's hop-distance, and an on-screen keyboard for the substring filter.
  Every tappable region is recorded each draw (`rowDest`, `btnSort`, `btnFind`, `navRow`, `kbKeys`) and
  matched in the `monitor_touch` branch — keep draw and the touch handler in sync. `orderedDests(filter,
  sortIdx)` is the single source of the displayed list (distance via `pathTo`, filter = substring).
- Single-file, dependency-free. No `require`.

## How to validate (this machine)

```bash
luacheck src/                 # static analysis; if missing: brew install luacheck
lua test/htsim.lua            # MUST print "133 passed, 0 failed" (or update the count with intent)
```

A no-luacheck fallback full-parse: `lua -e "assert(loadfile('src/ht_node.lua'))"`. The firmware can't
run off-game, so before claiming it works: lint clean, `htsim` green, and reason through the event loop
and protocol by hand. The physical hand-off geometry is the one thing only in-game testing settles.

## Roadmap / open work

- [ ] **Concurrent trips.** The network is single-occupancy (one trip at a time). True concurrency
      needs block-signalling / per-segment reservation built on the shared trip state.
- [x] **Auto-update on boot.** `ht_boot.lua` fetches `ht_node.lua` from `BASE` on every boot and installs
      it if strictly newer, so one `./push.sh` propagates to every node as its chunk loads (`ht_push` stays
      as an instant path for already-loaded nodes). Heavily guarded: a download must end with the
      **`@HT-NODE-EOF` sentinel** (rejects truncation) AND compile (`load`) before it's written; a broken
      firmware self-heals. Drop `/ht_pin` to freeze a node. **INVARIANT: `ht_node.lua` must end with the
      `@HT-NODE-EOF` line — never add anything after it, or every node will reject the update as truncated.**
- [ ] **Speaker chime / per-exit indicator lamps** on departure/arrival.
- [ ] Record confirmed in-game hand-off geometry (gap, facing, lock mode) in `docs/unified-node.md`.

## When you change things

- Touch the **protocol** (message shapes/types)? Update the protocol table above, `src/ht_node.lua`,
  `docs/unified-node.md`, and — if it affects routing/trip/gossip logic — `test/htsim.lua`, together.
- Change the **trip state machine, gossip, or pathfinding**? Re-run `lua test/htsim.lua` and keep it green.
- Add a **`firmware.lua` subcommand** or config field? Update the top-of-file handling, the README
  command table, and `docs/unified-node.md`.
- Keep commits small and messaged by what changed and why (`push.sh` does add/commit/push).
