# Hypertube Network

A wireless, computer-routed **hypertube transport system for Minecraft** (NeoForge 1.21.1) built with **Create: Hypertubes** + **CC: Tweaked**. Tap a destination on an in-game touchscreen and the network carries you there — any station to any station, including across **junctions that switch you onto one of several tubes**.

> Runs inside Minecraft on ComputerCraft computers. This repo holds the Lua firmware, the build/design docs, and example configs. It is developed with Claude Code — see `CLAUDE.md`.

## What's here

| Path | What |
|---|---|
| `src/hypertube_node.lua` | The firmware. One file on every computer; acts as station, junction, or both. |
| `src/single_room_selector.lua` | v1: a single room with one entrance per destination. Reference / hub building block. |
| `docs/implementation.md` | Full design, build, wiring, and protocol reference. |
| `docs/single-room-guide.md` | Build guide for the v1 selector. |
| `config/stations.example.lua` | A worked multi-node network including a switching junction. |
| `test/mechanic-test.md` | **Step 0** — the in-game check you must pass before building big. |
| `CLAUDE.md` | Operating manual for Claude Code. |

## How it works (30 seconds)

No native junction block exists in Create: Hypertubes, so everything is built from one primitive — a **computer-toggled entrance**. Powered, it catches and forwards a passing traveller; unpowered, the traveller drops out (arrived). Each node has named **EXITS** and a **ROUTES** table (`destination → exit`, or `"RELEASE"` for "you're here"). A junction is just a node with two-plus exits that points different destinations at different tubes. Nodes coordinate over `rednet` with Ender modems (unlimited, cross-dimension range).

## Quickstart

1. **Do Step 0 first** (`test/mechanic-test.md`). The whole system assumes the entrance hand-off / release / switch behaviour; confirm it in a creative world before building.
2. Build a node per `docs/implementation.md` §6 (entrances + Create clutches + redstone relays + computer + Ender modem + monitor).
3. On each computer: `edit startup`, paste `src/hypertube_node.lua`, set the config block (`STATION`, `EXITS`, `ROUTES`, peripheral names), reboot.
4. Tap a destination. The network routes you there.

## Develop with Claude Code

`CLAUDE.md` is loaded automatically. Lint with `luacheck src/` (no runtime tests — CC: Tweaked can't run off-game).

First prompt to paste into Claude Code:

```
Read CLAUDE.md and docs/implementation.md. Then implement the
"auto-generated ROUTES" roadmap item: let me describe the network as a
graph once (nodes, tubes, which exit points where) and compute each
node's ROUTES (shortest path) instead of hand-writing them. Keep the
existing EXITS/ROUTES runtime format so current configs still work,
add it as a build step that emits per-node config, run `luacheck src/`,
and keep docs/implementation.md in sync. Do not assume the Step 0
mechanic is verified.
```

## Status

Design + firmware complete and lint-clean. **Physical mechanic unverified in-game** (Step 0 pending). Single-occupancy (one trip at a time) by design; concurrency is on the roadmap in `CLAUDE.md`.
