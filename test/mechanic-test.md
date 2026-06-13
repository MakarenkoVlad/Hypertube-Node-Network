# Step 0 — In-game mechanic test (do this before building the network)

The whole system assumes a few Create: Hypertubes behaviours that aren't documented and must be confirmed in-game. Run these in a **flat creative world**. ~10–15 minutes. Record results at the bottom; nothing else should be built until this passes.

## Setup

Power source: a creative motor (or any Create rotation). Use the **wrench** to set entrance lock modes as noted. Gate entrances either with a **Create Clutch** (`redstone ON = braked/off`) or, if supported, a direct redstone-disable on the entrance.

## Test 1 — Hand-off (chaining)

Build: `Entrance A → short tube → small gap → Entrance B → tube → exit`. Both powered, **both facing the same direction of travel**.

- [ ] Ride into A. Are you caught by B across the gap and carried out the far end?
- [ ] Find the **largest gap** (blocks) that still catches you: ____
- [ ] Note the facing/orientation that worked.

## Test 2 — Release (arrival)

Same build; now **cut power to B** (clutch redstone ON, or redstone-disable).

- [ ] Ride into A. Do you **drop out at the gap** instead of continuing?
- [ ] Does re-powering B make it forward you again, reliably?

## Test 3 — Switch / redirect (junctions)

Build one **arrival point** with **two departure entrances** aimed down two different tubes (A and B). Power only one at a time.

- [ ] With only A powered, does an arriving traveller get redirected onto tube A?
- [ ] Switch to only B powered — do they go down B instead?
- [ ] Does it work when the branch leaves at an **angle** (not straight ahead)? Note the geometry that works.

## Test 4 — Lock mode & boarding

- [ ] Which wrench mode (Automatic / Manual) still lets an **in-flight** traveller be caught by the next entrance? ____
- [ ] In that mode, does a player **standing on the pad** get pulled in when the exit powers (good for auto-boarding), or do they need to sneak (Manual)? ____

## Test 5 — Redstone gating method

- [ ] Does the **Create Clutch** reliably start/stop the entrance? 
- [ ] Can the entrance be **disabled by redstone directly** (no clutch)? If yes, set `invert = false` in the firmware and skip clutches.

## Results

```
Date:
CC: Tweaked version:        (need 1.114+ for redstone_relay)
Create: Hypertubes version:
Largest working gap:        blocks
Working facing/geometry:
Switch/redirect works?      yes / no   (angle limits: )
Lock mode for through-traffic:
Boarding: auto-pull / sneak
Gate method: clutch / direct redstone   ->  invert = true / false
Notes:
```

If Tests 1–3 pass, the network described in `docs/implementation.md` works as designed. If any fails, stop and note exactly what happened — the design may need a different boarding/junction geometry.
