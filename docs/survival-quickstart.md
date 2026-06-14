# Survival Quickstart — two stations, one tube

The smallest real build: **Home ⟷ Outpost**, one hypertube, tap to travel. It's also your **Step 0 mechanic test** — if travel works here, the whole design is confirmed. Build the two stations **close together** first (a short tube) so iterating is fast; move/extend later.

Deployables are already generated: `deploy/home.startup.lua` and `deploy/outpost.startup.lua`.

## Prerequisites (in the pack)

Create: Hypertubes · CC: Tweaked **1.114+** (for the Redstone Relay) · Advanced Peripherals (Player Detector) · a working Create rotation source.

## Gather — per station (×2)

- 1 Advanced Computer + 1 Advanced Monitor (≥3×2)
- 1 **Ender Modem** (the wireless link)
- 1 Hypertube Entrance + tubes to the other station
- 1 Create **Clutch**
- 1 **Redstone Relay** + 1 Wired Modem
- 1 **Player Detector** (Advanced Peripherals)
- Networking Cable, a little redstone
- Shared: one steady Create rotation source (e.g. a water wheel) feeding both clutches

## Wire one station so the names match (do the same at both)

The generated config expects default names. Wire it this way and you won't edit anything:

1. **Computer** — put the **Advanced Monitor on its right**, the **Ender Modem on top**.
2. **Wired network** — a Wired Modem on a free side of the computer, Networking Cable to a Wired Modem on the **Redstone Relay** and another on the **Player Detector**. **Right-click each modem** to attach. First relay becomes `redstone_relay_0`, first detector `player_detector_0`. (Run `peripheral.getNames()` to confirm.)
3. **Gate** — Redstone Relay output side **`back`** → into the **Create Clutch**. Put the clutch in the rotation line feeding the Hypertube Entrance. Reminder: **redstone ON = clutch braked = entrance off** (the default state).
4. **Pad + entrance** — one block you stand on (the pad), with the Hypertube Entrance **aimed down the tube** toward the other station, reachable from the pad. Put the Player Detector within ~2 blocks of the pad.
5. **Lock mode** — wrench the entrance; try **Manual Lock** first (sneak to board). If through-travel/boarding feels off, try Automatic — this is the Step 0 thing to feel out.

Then run tubes from Home's entrance to Outpost's entrance, and feed both clutches from your Create source.

## Put the program on each computer

Each file is ~260 lines, so don't type it — get the file onto the computer:

**Offline (single-player) — drop it on disk:**

1. In the computer, run `id` to see its number (say `3`).
2. Exit to the world list (so the save flushes).
3. Copy `deploy/home.startup.lua` to
   `…/saves/<World>/computercraft/computer/3/startup.lua`
   (rename to `startup.lua`). Do the same with `outpost.startup.lua` on the Outpost computer's id.
4. Re-enter the world; it auto-runs (or hold **Ctrl+R** to reboot).

**If HTTP is enabled (server-friendly):** push the repo to GitHub, then in each computer
`wget <raw-url>/home.startup.lua startup.lua` and reboot. (`pastebin get <code> startup.lua` works too if you upload it.)

The computer labels itself ("home" / "outpost") on first boot.

## First run

Both monitors show the station title and the other station in the list, status **"Step onto the pad to travel."**

1. Stand on Home's pad → it greets **"Welcome, &lt;you&gt;"**.
2. Tap **Outpost** → status **"&lt;you&gt; → Outpost"**, Home's entrance spins up and pulls you in.
3. You ride the tube and drop out on Outpost's pad. Outpost briefly shows **"Arriving: &lt;you&gt;."**
4. From Outpost, tap **Home** to come back.

## If something's off (most likely first)

- **You don't get pulled in / don't move:** rotation isn't reaching the entrance. The clutch should be *unbraked* (no redstone) when launching — check `invert = true` matches your clutch, and that the Create source is actually spinning the entrance. Shorten the tube and recheck the entrance facing.
- **"Step onto the pad first" while you're standing on it:** Player Detector range — raise `BOARD_RANGE`, move the detector closer, or confirm it's `player_detector_0` (`peripheral.getNames()`). To rule the detector out entirely, set `local PAD_DETECTOR = nil` in that computer's `startup.lua`, reboot, and you can launch without it.
- **`No relay 'redstone_relay_0'`:** its Wired Modem isn't attached (right-click it) or it got another name — check `peripheral.getNames()` and update the name in the config region.
- **The two computers don't react to each other:** both need an **Ender Modem** (not a plain wireless one) on the side the config opens (`top`).
- **You overshoot or bounce back:** the destination entrance must stay OFF (it's `RELEASE` in the config). If you bounce, the far entrance is getting powered — recheck its relay wiring / `invert`.

Record the gap and lock mode that worked (in `test/mechanic-test.md`) — those numbers carry into every future node.

## When it works

Add a third station or a junction by editing the network graph and regenerating — same loop, no rewrites:

```
lua tools/build_routes.lua config/starter_2station.lua deploy --startup
```
