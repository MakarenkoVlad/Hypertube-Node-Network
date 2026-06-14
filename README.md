# Hypertube Network

A wireless, computer-routed **hypertube transport system for Minecraft** (NeoForge 1.21.1) built with **Create: Hypertubes** + **CC: Tweaked**. Tap a destination on an in-game touchscreen and the network carries you there — any station to any station, including across **junctions that switch you onto one of several tubes**.

> Runs inside Minecraft on ComputerCraft computers. This repo holds the Lua firmware, the build/design docs, and example configs. It is developed with Claude Code — see `CLAUDE.md`.

## What's here

| Path | What |
|---|---|
| `src/hypertube_node.lua` | The firmware. One file on every computer; acts as station, junction, or both. |
| `src/install.lua` | In-game installer: splices a node's config into the firmware → `startup` (from a disk or HTTP). |
| `src/single_room_selector.lua` | v1: a single room with one entrance per destination. Reference / hub building block. |
| `tools/build_routes.lua` | Build step (off-game): turn one network graph into each node's EXITS/ROUTES by shortest path. |
| `docs/implementation.md` | Full design, build, wiring, and protocol reference. |
| `docs/single-room-guide.md` | Build guide for the v1 selector. |
| `config/network.example.lua` | The network graph — single source of truth for the route builder. |
| `config/stations.example.lua` | The same network hand-written in runtime format (reference; the builder reproduces it). |
| `test/mechanic-test.md` | **Step 0** — the in-game check you must pass before building big. |
| `CLAUDE.md` | Operating manual for Claude Code. |

## How it works (30 seconds)

No native junction block exists in Create: Hypertubes, so everything is built from one primitive — a **computer-toggled entrance**. Powered, it catches and forwards a passing traveller; unpowered, the traveller drops out (arrived). Each node has named **EXITS** and a **ROUTES** table (`destination → exit`, or `"RELEASE"` for "you're here"). A junction is just a node with two-plus exits that points different destinations at different tubes. Nodes coordinate over `rednet` with Ender modems (unlimited, cross-dimension range).

## Quickstart

1. **Do Step 0 first** (`test/mechanic-test.md`). The whole system assumes the entrance hand-off / release / switch behaviour; confirm it in a creative world before building.
2. Build a node per `docs/implementation.md` §6 (entrances + Create clutches + redstone relays + computer + Ender modem + monitor).
3. Describe your network once in `config/network.example.lua`, then `lua tools/build_routes.lua config/network.example.lua --startup` to generate each node's config block and a ready-to-run startup.
4. Deploy each node with `src/install.lua` (from a floppy or HTTP) — it writes `startup`, labels the computer, and reboots. Or by hand: paste the firmware and the node's config block between the `@HT-CONFIG` markers.
5. Tap a destination. The network routes you there.

## Develop with Claude Code

`CLAUDE.md` is loaded automatically. Lint with `luacheck src/ tools/`. The firmware can't run off-game (CC: Tweaked is in-game only), but the route builder is plain Lua and does run here: `lua tools/build_routes.lua config/network.example.lua -`.

First prompt to paste into Claude Code:

```
Read CLAUDE.md and docs/implementation.md. Then implement the "Niceties"
roadmap item: an admin "reset network" rednet broadcast that clears every
node's gates and line state, plus optional per-exit indicator lamps driven
through setGate. Keep the protocol in sync (src/hypertube_node.lua, docs §7,
config/stations.example.lua), run `luacheck src/ tools/`, and do not assume
the Step 0 mechanic is verified.
```

## Status

Design + firmware complete and lint-clean. Routing tables are **auto-generated** from a single network graph and deployed with a **one-command installer** (`tools/build_routes.lua` + `src/install.lua`). **Physical mechanic unverified in-game** (Step 0 pending). Single-occupancy (one trip at a time) by design; concurrency is on the roadmap in `CLAUDE.md`.
