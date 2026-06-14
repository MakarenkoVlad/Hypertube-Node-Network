# CLAUDE.md — Hypertube Network

Operating manual for Claude Code working in this repo. Read this fully before changing anything.

## What this project is

A **wireless, computer-routed hypertube transport system for Minecraft** (NeoForge **1.21.1**). Players tap a destination on an in-game touchscreen and the network routes them there, including across **junctions that switch a traveller onto one of several tubes**.

It runs **inside Minecraft**, not on this machine. The code targets the **CC: Tweaked** mod (ComputerCraft) and drives the **Create: Hypertubes** mod. You can read, refactor, lint, and document the Lua here, but you **cannot run or integration-test it** — that only happens on an in-game computer. Treat static analysis + careful reasoning as the verification bar.

## Hard constraints (do not violate)

- **Minecraft 1.21.1 / NeoForge.** CC: Tweaked runs natively on NeoForge here (no Sinytra Connector needed for CC itself).
- **CC: Tweaked Lua runtime** = Lua **5.2** (Cobalt) with some 5.3 features. **No** LuaJIT, **no** `require` of external libraries, **no** Lua 5.4-only syntax. Programs are **single self-contained files** deployed to a computer (usually as `startup`).
- **Available globals** are CC's APIs only: `os`, `peripheral`, `rednet`, `redstone`, `term`, `colors`, `fs`, `parallel`, `textutils`, `settings`, `read`, `sleep`, etc. File I/O in-game is the `fs` API, not standard `io`. See `.luacheckrc` for the allowed global set.
- **CC: Tweaked 1.114+** is required in-game for the `redstone_relay` peripheral the firmware uses.
- **Mod limitation:** Create: Hypertubes has **no junction/splitter block**. Routing is achieved entirely by powering/​unpowering entrances (the "relay/cannon" primitive). Do not write code that assumes a native junction or in-tube switching exists.

## ⚠️ Unverified assumption — keep this in mind

The physical mechanic has **not been confirmed in-game yet** (see `test/mechanic-test.md`, "Step 0"). Specifically: that an unpowered entrance lets a passing traveller drop out, and that a powered entrance catches/redirects an arriving traveller (the switch). The mod's Hypertube *cannon* strongly implies this works, but until Step 0 is checked, **do not present the system as proven** and don't optimize away the timeout/lock safety nets.

## Architecture (so changes stay coherent)

- **One firmware, three roles.** `src/hypertube_node.lua` runs on every computer. A node is a **station** (has a monitor; board/arrive here), a **junction** (headless; switches tubes), or both.
- **Routing = exits + tables.** Each node config has `EXITS` (named entrances it can power) and `ROUTES` (destination id → exit name, or `"RELEASE"` if the destination is this node). The whole routing brain is: `for dest, power EXITS[ROUTES[dest]]; RELEASE/nil powers nothing`.
- **A junction is just a node with ≥2 exits** whose ROUTES point different destinations at different exits. There is no separate junction program.
- **Wireless coordination via rednet** (protocol string `"hypertube"`), Ender modems for unlimited/cross-dimension range. Messages are plain tables with a `type` field:
  - `ROUTE{ dest, trip }` — set the network for a trip.
  - `ARRIVED{ at, trip }` — clear the network after delivery.
- **Single-occupancy** by design: gate states are network-wide, so one trip at a time; terminals show "Line busy" until `ARRIVED` or `TRIP_TIMEOUT`.

The authoritative explanation is `docs/implementation.md` — keep it in sync with the code.

## Repo layout

```
CLAUDE.md                     this file
README.md                     human overview + quickstart + Claude Code kickoff prompt
src/
  hypertube_node.lua          MAIN firmware: station / junction / terminal (routing tables)
  single_room_selector.lua    v1 standalone: one room, one entrance per destination (reference / hub building block)
tools/
  build_routes.lua            BUILD STEP (off-game Lua): one network graph -> per-node EXITS/ROUTES by shortest path
docs/
  implementation.md           full build + protocol doc (canonical design reference)
  single-room-guide.md        build guide for the v1 selector
config/
  network.example.lua         network graph = single source of truth for the route builder
  stations.example.lua        worked multi-node network incl. a switching junction (hand-written runtime-format reference)
  generated/                  build artifact: per-node configs emitted by build_routes.lua (git-ignored)
test/
  mechanic-test.md            Step 0 in-game verification checklist (BLOCKS real builds)
.luacheckrc                   luacheck config with CC: Tweaked globals
```

## Conventions

- **Config block at the very top** of each program (`STATION`, `STATIONS`, `EXITS`, `ROUTES`, peripherals). Everything below is logic. Users edit only the config.
- **Gate abstraction:** `setGate(g, enable)` where `g.invert` flips for Create-Clutch (`redstone ON = brake`) vs redstone-lockable entrances. Never write raw `setOutput` in logic — go through `setGate`.
- **rednet messages** are tables with a `type`; always filter incoming by `protocol == PROTO`.
- **Validate config at boot** (e.g. ROUTES must reference defined EXITS) with a clear `error()` — fail loud, in-game debugging is painful.
- **No blocking sleeps in the event loop.** Use `os.pullEvent` + `os.startTimer`. The single `while true` event loop dispatches `monitor_touch`, `rednet_message`, `timer`, `redstone`.
- Keep programs **single-file** and dependency-free.

## How to validate (this machine)

```bash
luacheck src/ tools/                                   # static analysis (.luacheckrc)
lua tools/build_routes.lua config/network.example.lua -  # build step actually RUNS off-game
```

The **firmware** (`src/`) can't run here — CC: Tweaked is in-game only. The **build step** (`tools/`) is plain Lua and *does* run on this machine, so exercising it on a graph is a real test: it should reproduce `config/stations.example.lua`'s routes from `config/network.example.lua`. Before claiming firmware works: lint clean, reason through the event loop and routing math by hand, update the docs. For anything touching the physical mechanic, defer to Step 0.

If `luacheck` isn't installed: `brew install luacheck` (it bundles a compatible Lua) or `luarocks install luacheck`. Note **luacheck does not run on Lua 5.5 yet** (a `const` change breaks it) — use the Homebrew formula's bundled `lua@5.4`. A full-parse fallback is `python3 -c "from luaparser import ast,builder; ast.parse(open('src/hypertube_node.lua').read())"`.

## Roadmap / open work

- [ ] **Resolve Step 0** and record results in `test/mechanic-test.md`; relax safety nets only if justified.
- [x] **Auto-generated ROUTES:** `tools/build_routes.lua` turns one network graph (`config/network.example.lua`) into per-node EXITS/ROUTES by shortest path. Runtime format unchanged; see `docs/implementation.md` §9.
- [ ] **Concurrent trips / block-signalling** so the network isn't single-occupancy.
- [ ] **Installer:** one-line `pastebin get` / `wget` or floppy-disk deploy that writes `startup` + drops in per-node config.
- [ ] **Shared directory distribution:** push the `STATIONS` list to all terminals (rednet or disk) so it isn't copied by hand.
- [ ] **Niceties:** speaker "departing" chime, lamp indicators per exit, an admin "reset network" broadcast.

## When you change things

- Touch the **protocol** (message shapes/types)? Update `src/hypertube_node.lua`, `docs/implementation.md` §7, and `config/stations.example.lua` together.
- Add a **config field**? Update the top-of-file block, the example config, and the install section of the docs.
- Add a **config field the builder should emit**? Update `tools/build_routes.lua`'s `emitNode`, `config/network.example.lua`, and `docs/implementation.md` §9 together — the generated block must stay a drop-in for the firmware's CONFIG section.
- Keep commits small and message them by what changed and why. Don't mark Step 0 work "done" without recorded in-game results.
