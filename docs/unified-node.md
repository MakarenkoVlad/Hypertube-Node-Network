# One firmware for every node (`ht_node.lua`)

The self-organizing path: instead of generating a config per node, you install the **same** program on every computer and it works the rest out itself. This is the recommended way to run and ship the network.

## What each node does on its own

1. **Discovers its peripherals** by capability — the ender modem, the monitor, the Player Detector, and every Create Rotational Speed Controller. No names to type.
2. **First boot only — a 1-minute setup** on the computer screen:
   - you name the node (e.g. `hub`, `mine`, `nether_hub`);
   - for each tube it **spins the controller** so you can see which one, then you type the node that tube reaches;
   - optionally you add **portal links** — a neighbour you reach by walking through a Nether portal (no tube).
   - This is saved to `/ht_node.cfg`. Re-run any time with `firmware.lua setup`.
3. **Shares its links over rednet** (link-state). Every node hears every other node's links and builds the whole map, so each one can compute shortest paths itself — add a node and the others learn it automatically.
4. **Routes any node to any node**, switching at junctions. It's the same single-trip-at-a-time shared state as before, just with the graph discovered instead of generated.

## Nether / other dimensions

**Ender modems are cross-dimension**, so the rednet link-state and live trips already span the Overworld, Nether, and End. A hypertube can't physically cross a portal, so a cross-dimension hop is a **portal link**: the route brings you to the portal node, the screen says *"Walk through the portal to <node>,"* and the node on the far side — which already has the trip from the shared broadcast — resumes it when its detector sees you arrive. Verified in routing tests (e.g. `a → b → n1 → n2` crosses a portal at `b`).

## Install — identical on every node

One line per computer (see `docs/shipping.md` for hosting):

```
wget run <BASE>/installer.lua            # any node
wget run <BASE>/installer.lua junction   # optional update-group tag
```

It lays down the bootstrap (`startup`) and the one firmware (`firmware.lua`), then reboots into setup. Same command everywhere — no per-node id.

## Update — over the air

Improve `src/ht_node.lua`, push it to your host, then from any node:

```
wget <BASE>/src/ht_node.lua firmware.lua
ht_push firmware.lua
```

Every node replaces its firmware and reboots; its `/ht_node.cfg` (name + calibration) is untouched. So **code is one file pushed everywhere; config is per-node and set once on-screen.**

## Two models, your choice

- **`ht_node.lua` (this doc)** — self-organizing, identical everywhere, on-screen setup. Best for "one installable thing" and for growing the network freely.
- **`hypertube_node.lua` + `build_routes.lua`** — central network graph generates each node's config (names/wiring controlled from one file, spliced into firmware). Best when you want the topology defined and reviewed in one place.

Both ride the same ender-modem rednet and the same OTA bootstrap.
