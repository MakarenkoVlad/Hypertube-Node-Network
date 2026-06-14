# Survival — 4 stations with a junction at B

The next step up from the two-station line: a star with a real switch in the middle.

```
                 Station C
                     |
     Station A ===== B =====        B forks: up to C, down to D
                     |
                 Station D
```

Edges: **A–B, B–C, B–D**. So **B is both a station and a 3-way junction** — travelling A→C or A→D passes *through* B, which switches you onto the right tube. Everything else (per-station wiring, deploy method, first-run basics) is the same as `survival-quickstart.md`; this doc only covers what's different: **B**.

Deployables are generated: `deploy/a.startup.lua`, `b.startup.lua`, `c.startup.lua`, `d.startup.lua`.

## Build order (don't do it all at once)

1. Build **A** and **B** and the A–B tube. Get A↔B travelling first (it's the same as the two-station line). 
2. Then add the **B–C** tube and Station C. Test A→C and B→C.
3. Then add the **B–D** tube and Station D. Test A→D, C→D.

This way the only genuinely new thing — the junction redirect at B — is the *last* variable you introduce, on top of a line you already trust.

## Stations A, C, D (the leaves)

Each is a plain one-exit station: pad, one entrance aimed down its tube to B, one Create clutch, one Redstone Relay (`redstone_relay_0`), a Player Detector (`player_detector_0`), monitor on the **right**, Ender Modem on **top**. Follow the wiring in `survival-quickstart.md` verbatim.

## Station B (the junction) — the only new build

B is a **central hub pad** with **three entrances facing it**, one aimed down each tube (to A, to C, to D). Whoever lands on the hub — whether they boarded *at* B or arrived *through* B from another tube — gets grabbed by whichever exit the computer has powered.

- **Three entrances** around one pad, each aimed outward to its tube (toward A, toward C, toward D). This is the "2–3 entrances facing the block you stand on" layout.
- **Three clutches + three Redstone Relays.** Wire and attach their wired modems **in this order** so the names match the config:
  - `redstone_relay_0` → clutch on the **A**-facing entrance
  - `redstone_relay_1` → clutch on the **C**-facing entrance
  - `redstone_relay_2` → clutch on the **D**-facing entrance
  - (Or attach in any order, run `peripheral.getNames()`, and edit B's `EXITS` so `toA/toC/toD` point at the right relay.)
- **One** computer + Advanced Monitor + Ender Modem + Player Detector at the hub, same as any station.
- The computer powers exactly **one** exit per trip: arriving from A bound for C, B powers only the C entrance, which catches you off the hub and sends you to C. Bound for D, it powers only D. If B is your destination, it powers nothing and you stay on the hub = arrived.

> The redirect — an entrance grabbing someone off the hub and sending them down a *different* tube — is Step 0's test 3. Keep B's hub tight (small gap between the arrival point and the exit entrances) and confirm each direction one at a time.

## Deploy

Same as before, four computers. On each, run `id`, exit to the title screen, and drop the matching file as `startup.lua` into `…/saves/<World>/computercraft/computer/<id>/`. The computers label themselves `a`, `b`, `c`, `d` on boot.

## First runs

- **A → B:** board at A, tap Station B, arrive on B's hub.
- **A → C:** board at A, tap Station C. You ride to B, B powers its C-entrance and forwards you, you drop at C. (B's screen flashes "Line in use → Station C".)
- **A → D / C → D:** same, B switches to the D tube.
- **B → anywhere:** stand on B's hub, tap a destination, the matching entrance grabs you.

Remember it's still **one trip at a time** across the whole network — if someone's mid-trip, other terminals show "Line busy."

## Junction-specific troubleshooting

- **A→C drops you at B instead of continuing:** B isn't powering the C exit. Check that B's `redstone_relay_1` exists and is wired to the C clutch, `invert = true` matches the clutch, and B's `ROUTES` has `c = "toC"`. If the gate *is* powering but you still fall out, it's the redirect geometry — tighten B's hub gap (Step 0 test 3).
- **A→C sends you to D (wrong branch):** the relay order at B is swapped. Run `peripheral.getNames()` at B and make `toC`/`toD` in `EXITS` point at the correct relays.
- **You bounce back toward A at B:** the A-entrance is still powered when it shouldn't be — only the destination's exit should be on. Recheck B's relay wiring / `invert`.
- Everything else (no pull-in, "step onto the pad", relay-not-found, modems not talking) → the troubleshooting list in `survival-quickstart.md`.
