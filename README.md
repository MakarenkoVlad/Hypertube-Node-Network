# Hypertube Network

A wireless, self-organizing **hypertube transport network for Minecraft** (NeoForge 1.21.1),
built with **Create: Hypertubes** + **CC: Tweaked** + **Advanced Peripherals**. Stand on a pad,
tap a destination on the touchscreen, and the network routes you there — any station to any
station, including across **junctions that switch you onto one of several tubes** and across
**Nether/End portals**.

> Runs inside Minecraft on ComputerCraft computers. This repo holds the Lua firmware, an
> off-game simulator, and the design doc. Developed with Claude Code — see [`CLAUDE.md`](CLAUDE.md).

## The model: one firmware, every node identical

You install the **same** program (`src/ht_node.lua`) on every computer. There is no per-node
generated code. Each node:

- **discovers its own peripherals** by capability — the Ender modem, the monitor, the Player
  Detector, and every Create Rotational Speed Controller (one per tube);
- runs a **one-time on-screen setup** (name the node; for each tube, type which node it reaches);
  saved to `/ht_node.cfg`;
- **gossips the topology** over rednet so every node learns the whole map and computes shortest
  paths itself — add a station and the rest discover it automatically;
- **routes any node to any node**, opening only the tube toward the next hop at each junction.

Config is per-node and set once. **Code is one file, pushed to every node over the air.**

## What's here

| Path | What |
|---|---|
| `src/ht_node.lua` | **The firmware.** Same file on every node — station, junction, or both. |
| `src/ht_boot.lua` | Bootstrap installed as `startup`: runs the firmware + listens for OTA updates. |
| `src/ht_push.lua` | Broadcasts a new firmware to every node over rednet (no node visits). |
| `src/installer.lua` | One-line installer from GitHub (`wget run …/installer.lua`). |
| `src/pastebin_install.lua` | Same one-shot install, via pastebin codes (no GitHub needed). |
| `src/htlog.lua` | Live network log viewer — see every node's trips and firmware version. |
| `test/htsim.lua` | Off-game simulator: mirrors the firmware logic, models chunk unload/reload. |
| `docs/unified-node.md` | Full design, wiring, hardware, and rednet protocol reference. |

## Build a node

Per station (each on its **own isolated wired-modem network** — never cable two nodes together):

- **Advanced Computer** (gold) + **Advanced Monitor** for the touch menu.
- **Ender Modem** on the computer — this is the only link between nodes (wireless, cross-dimension).
- **Player Detector** (Advanced Peripherals) at the boarding pad.
- One **Create Rotational Speed Controller** per tube entrance, on the computer's wired network.
  The firmware spins a controller to **≥16 RPM** to open its entrance, 0 to close it.

A **hub/junction** is just a node with several tubes: one computer drives several controllers and
opens whichever tube leads toward your destination.

> **Geometry matters (physical, not code):** a tube ejects you straight out. Junction hand-offs
> are reliable when the next entrance catches you at ~90°; two entrances pointed head-on fight
> each other. See `docs/unified-node.md`.

## Install, deploy, update

**Install (same line on every node)** — edit `BASE` in `src/installer.lua` to your repo, then:

```
wget run https://raw.githubusercontent.com/MakarenkoVlad/Hypertube-Node-Network/main/src/installer.lua
```

It writes `startup` + `firmware.lua` and reboots into setup. (Pastebin alternative:
fill the codes in `src/pastebin_install.lua`, then `pastebin run <code>`.)

**First boot — setup** (type on the computer, not the monitor):
name the node, then for each tube type the node it reaches. To ID which tube is which,
`firmware.lua spin` first. Names must match exactly on both ends of a tube.

**Seed the map (once):** from each station, take a single trip to its direct neighbour. That
direct hop works with no map and teaches the station the whole network, which it saves to disk —
after that, multi-hop routing is reliable even when other nodes are unloaded.

**Update every node — push once, it propagates.** Edit `src/ht_node.lua`, then `./push.sh`. That's it.
Each node **auto-updates from GitHub** — `ht_boot` checks for a newer firmware at boot *and every few
minutes while running*, installing it (and rebooting itself if it's running) when one appears. So
chunk-loaded nodes update within ~5 minutes and the rest update as their chunks load; you never visit a
node or reboot one by hand. (Downloads are integrity-checked — sentinel + compile + byte-verify — so a
dropped/garbage fetch is rejected and can't brick a node; a node that's somehow broken self-heals; drop a
`/ht_pin` file to freeze a node.) Auto-update is **forward-only** — to roll back, push a higher version
containing the old code.

Want a node updated *instantly* instead of within a few minutes? Push over rednet from any one node:
```
wget https://raw.githubusercontent.com/MakarenkoVlad/Hypertube-Node-Network/main/src/ht_node.lua firmware.lua
ht_push firmware.lua
```

**Track the rollout.** Run `htlog` and press **V** (or `htlog versions`): every loaded node prints its
firmware version, and any on an older build is flagged — load the chunks (travel the line) so they
auto-update, until the census is all-green on the newest version.

## On the touchscreen

The boarding menu has a control bar: **Sort** (tap to cycle nearest-first → farthest-first → A–Z) and
**Find** (tap to open an on-screen keyboard and filter the list by name substring). Each stop shows its
**hop-distance** (`direct` or `N hops`). When the list is long, a **▲/▼** bar scrolls it. Tap a stop to go.

## Nether / End — portal links

A hypertube can't cross a dimension, so a cross-dimension (or "to the roof") hop is a **portal link**: a
neighbour you reach by *walking through a portal* instead of riding a tube. Build a portal between the two
spots, put a node on each side, and in setup answer the **"Portal (walk-through) to which node?"** prompt
with the other node's name (on both sides). The route then carries you to the portal node, the screen says
*"Walk through the portal to X,"* and the node on the far side — which already has the trip over the
(cross-dimension) ender-modem network — resumes it. This is in the firmware today and covered by
`test/htsim.lua` (Phase 11).

## Useful commands (on a node's computer)

| Command | What |
|---|---|
| `firmware.lua setup` | Re-run setup (rename / re-map tubes). |
| `firmware.lua spin [n]` | Spin tubes one by one to identify them (step off the pad first). |
| `firmware.lua diag` | Print this node's name, version, peripherals, and **which monitor it's drawing to**. |
| `firmware.lua monitor` | When the node has several monitors, pick which screen is its menu (labels each, you choose; pinned in config). |
| `firmware.lua reset` | Wipe config + learned map, reboot into fresh setup. |
| `firmware.lua forget` | Drop only the learned map (re-learn topology); keep name + tubes. |
| `firmware.lua log` | Print this node's local event log. |
| `firmware.lua report` | Write a full diagnostic snapshot to `/ht_report.txt` (config, peripherals, map, recent log). |
| `firmware.lua set <KEY> <n>` | Tweak a tunable in-game — persists in `/ht_tune.cfg`, survives OTA, reboots to apply. |
| `htlog` (on any computer with a modem) | Live network log (also written to `/htlog.txt`). **P** = ping; **V** = version census. |
| `htlog versions` | One-shot: ping, print the version census, exit. |

## Debugging & tweaking

**Send a diagnostic.** On a misbehaving node, run `firmware.lua report` — it writes
`/ht_report.txt` (firmware version, config, every peripheral, the learned network map with ages,
current tunables, and the last 40 log lines). Upload it and share the link:

```
firmware.lua report
pastebin put /ht_report.txt        # prints a pastebin URL to paste back
```

For a whole-network trace, run `htlog` while reproducing the issue (it tees everything to
`/htlog.txt`), then `pastebin put /htlog.txt`.

**Tweak without redeploying.** Adjust a tunable in-game; it's saved to `/ht_tune.cfg` (survives OTA)
and applied on reboot:

```
firmware.lua set RPM 192           # launch speed
firmware.lua set CALIBRATE_RPM 24  # spin speed during `spin`
firmware.lua set BOARD_RANGE 3     # pad detection radius
```

Tunable keys: `RPM`, `CALIBRATE_RPM`, `TRIP_TIMEOUT`, `TRIP_BEAT`, `RELAUNCH_HOLD`, `LS_INTERVAL`,
`BOARD_RANGE`, `BOARD_HEIGHT`. Current values show in `firmware.lua report`.

## Develop with Claude Code

`CLAUDE.md` is the operating manual. The firmware can't run off-game (CC: Tweaked is in-game
only), so the verification bar is:

```
luacheck src/                 # static analysis (.luacheckrc)
lua test/htsim.lua            # simulate the distributed logic incl. chunk unload/reload
```

## Status

Unified self-organizing firmware, deployed and running in-game. Routing, the durable map, and the
**shared-state trip** — the in-flight trip is gossiped and persisted exactly like the map (merged by a
`(ts, id)` total order with a monotonic `done` flag), so a junction that reloads mid-route recovers it
from its own disk or any peer's gossip, **never needing a specific live peer** — are validated by
`test/htsim.lua` (98/98). Gates are **detector-gated** — a tube opens only while the trip's own rider is
on the pad — so a reloaded node never opens a gate speculatively (no suck-back). Single-occupancy (one
trip at a time on the network) by design.
