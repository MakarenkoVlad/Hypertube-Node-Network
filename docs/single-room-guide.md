# Smart Hypertube Station (CC: Tweaked + Create: Hypertubes)

Tap a destination on a touchscreen → the matching tube turns on and lights up → you step in and ride. NeoForge 1.21.1.

## How it works (and the one big constraint)

Create: Hypertubes has **no in-tube junction/splitter yet** — you can't reroute one shared tube to many places. So the station uses **one hypertube entrance per destination**, all sharing one Create power source. Each entrance's rotation runs through a **Create Clutch** (a clutch *stops* rotation when it gets a redstone signal). The computer keeps every clutch braked, and when you pick a destination it un-brakes just that one and lights its lamp. You walk into the single open tube.

So the computer is the **selector + brakeman + sign**, not a router.

## Materials

Shared:

- 1× **Advanced Computer** (gold-trimmed; needed for the colour touchscreen)
- 1× **Advanced Monitor** — build it at least **3 wide × 2 tall** so the menu fits
- 1× Create rotation source with enough SU (water/wind wheel, or a creative motor)
- **Wired Modems** + **Networking Cable** to link the computer to the relays
- CC: Tweaked **1.114 or newer** (that's when the **Redstone Relay** block was added). On native NeoForge 1.21.1 that's any recent build — you don't need Sinytra Connector for CC itself.

Per destination (×N):

- 1× **Hypertube Entrance** + tubes running to that destination
- 1× **Create Clutch** (on that entrance's cogwheel line)
- 1× **Redstone Relay** (CC: Tweaked) + 1× **Wired Modem** on it
- 1× **Redstone Lamp** (the "this is your tube" indicator)

## Build steps

**1. Tubes.** Place each Hypertube Entrance and run its tubes to the destination. Power flows in from your Create source. Wrench each entrance into **Manual Lock Mode** so it only grabs you when you sneak in — no accidental yanks when walking past.

**2. Clutch each entrance.** Put a Create Clutch in the rotation line feeding each entrance, *after* the shared power source. Reminder: **redstone signal on the clutch = that tube is OFF.** Default (no program running) = all braked = all off. Good.

**3. Lamps.** Put a Redstone Lamp where you'll see it above/beside each entrance.

**4. Relays.** Next to each Clutch+Lamp pair, place a **Redstone Relay**. Wire one relay output side to the Clutch and another to the Lamp. In the program these are the `brake` and `lamp` sides (defaults: `back` → clutch, `top` → lamp — change them to whatever you actually wire).

**5. Network.** Put a **Wired Modem** on each Redstone Relay and on the computer, then connect them all with **Networking Cable**. **Right-click each modem** to attach it — the computer prints the peripheral's name, e.g. `redstone_relay_0`. Note each name and which destination it belongs to.

**6. Monitor.** Place the Advanced Monitor and set the computer directly against it (then it's the `right`/`left`/etc. side), or put a modem on the monitor too and use its network name.

## Load and configure the program

1. On the computer: `edit startup`, paste in `hypertube_station.lua`, save (Ctrl+S) and exit (Ctrl+X). Naming it `startup` makes it auto-run whenever the chunk loads.
2. Edit the **CONFIG** block at the top:
   - `MONITOR` — the monitor's side or network name.
   - `DEST` — one row per destination. Set `name`, the `relay` network name from step 5, and the `brake`/`lamp` sides you wired.
3. Reboot the computer (hold Ctrl+R) or run `hypertube_station`.

To find peripheral names any time, run `lua` then `peripheral.getNames()`.

## Test it

Tap a destination. Only that tube's lamp should light and only that entrance should start spinning; the screen shows **DEPARTING → <name>**. Sneak into the lit tube and ride. After `OPEN_SECONDS` (default 12) everything re-brakes and the menu returns. Tap again mid-countdown to cancel.

If a tube won't activate: check that **redstone = brake** (signal should be *off* for the chosen tube), confirm the relay name matches `DEST`, and verify the clutch is in the rotation path.

## Optional upgrades

- **Foolproof gates.** Add a piston/trapdoor in front of each entrance on a second relay side, opened only for the chosen tube, so you physically can't enter the wrong one.
- **Auto-reset on entry.** Put a pressure plate (or Create: Hypertubes traveller-detector attachment) at the lit entrance feeding a relay *input*; listen for the `redstone` event and call `brakeAll()` the instant someone leaves, instead of waiting out the timer.
- **Sound.** Add a **Speaker** peripheral and `speaker.playNote(...)` on departure for an audible "ding".
- **More than ~6 destinations.** No problem — each Redstone Relay has its own 6 sides and its own network name, so just add more relays and more `DEST` rows.
- **Fully-automatic launch (no walking).** Possible but heavier: since there's no junction, you'd need a Create contraption (piston/bearing platform) to slide you in front of the chosen entrance before it fires. The step-in design here is far simpler and more reliable.
- **Tighter Create integration.** **CC:C Bridge** adds peripherals to read Create speed/stress and machine state from the computer. Not needed for this build, but handy if you want the screen to show live network status.
