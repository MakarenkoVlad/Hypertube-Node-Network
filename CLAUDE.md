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
- **Config in `/ht_node.cfg`** — `{ name, links = { controllerName -> neighbourNodeName }, portals }`.
  Written by on-screen `runSetup` on first boot; never touched by code updates.
- **Gossiped link-state.** Each node holds the WHOLE topology: `graph` (node -> neighbours) + `gen`
  (per-node last-refresh epoch). Nodes broadcast their entire known map (`STATE`); one reply hands a
  newcomer the full network. Timestamps make merges safe (fresher wins). The map is **persisted to
  `/ht_graph.dat`** so a node can route even while other nodes' chunks are unloaded.
- **Routing** is BFS shortest path over the undirected graph (`pathTo`). A trip is a `ROUTE` message
  carrying the full `path`; each node on the path opens **only** the tube toward the next hop
  (`applyTrip` -> `gateToward`), and the destination releases.
- **A junction is just a node with several tubes.** No separate junction program.

### Chunk-tolerance is the hard requirement

A CC computer **stops completely when its chunk unloads** and **cold-boots (RAM wiped, files persist)
when it reloads**. So you cannot assume any other node is running. The design copes by:

- persisting the map to disk (route without peers online);
- on boot, broadcasting `TRIPREQ` so a still-loaded peer relays any in-progress trip to the node that
  just woke up (a junction that loads as the rider approaches catches the trip);
- re-broadcasting the active trip every `TRIP_BEAT` seconds;
- firing each node's gate **once per trip id** (the `same` guard in `handle`) so the beat/relay can't
  re-grab a rider (suck-back); the origin auto-closes its launch tube after `RELAUNCH_HOLD`.

This is the property `test/htsim.lua` exists to protect — it models unload/reload and a trip relayed
onto nodes that boot mid-route. **Run it after any change to routing, the trip state machine, or the
gossip/merge logic.**

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
| `STATE{ nodes }` | `broadcastState` (boot, heartbeat, on `LSREQ`) | full gossiped map; `nodes[name] = { nbrs, ts }`. |
| `LSREQ{}` | boot, warm-up, `probeNetwork` | "everyone announce" — each node replies with `STATE`. |
| `TRIPREQ{}` | boot | "is a trip in progress for me?" — a holder replies with the `ROUTE`. |
| `ROUTE{ id,from,to,path,rider,ts }` | `startTrip`, beat, relay | start/relay a trip; each hop opens its next-hop tube once per `id`. |
| `ARRIVED{ at,id }` | destination on pad-land | end the trip; every node clears. |
| `HT_UPDATE{ code,group }` (`ht_ota`) | `ht_push` | OTA firmware push; `ht_boot` swaps `/firmware.lua` and reboots. |
| `{ ping }` / `{ node,ver,msg }` (`ht_log`) | `htlog` / every node's `log` | version ping / live log line. |

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
  meant to be `pastebin put` and shared. Per-node files now: `/ht_node.cfg`, `/ht_graph.dat`,
  `/ht_tune.cfg`, `/ht.log`, `/ht_report.txt` (and `/firmware.lua`, `/startup`, optional `/ht_group`).
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
lua test/htsim.lua            # MUST print "59 passed, 0 failed" (or update the count with intent)
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
