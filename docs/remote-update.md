# Remote updates — change firmware on every node from one place

The network routes any node to any node (`hypertube_node.lua` + `tools/build_routes.lua`). This doc is about the other half you asked for: **pushing new firmware to all nodes without visiting them**, while each node keeps its own config.

## The split: code is shared, config is per-node

- **Config** (this node's id, station names, which controller drives which exit, routes/paths) lives between the `@HT-CONFIG-START` / `@HT-CONFIG-END` markers in the node's firmware. You set it once per node (generated from the network graph).
- **Code** (everything else) is identical on every node. Updates replace the code **around** the markers and leave the config **inside** them untouched.

Two small programs make it work:

- `src/ht_boot.lua` — the bootstrap. Runs as `startup` on every node: it launches the firmware and listens on rednet for updates. On a push it keeps the local config, swaps the code, and reboots. If the firmware ever errors it stays alive so you can push a fix.
- `src/ht_push.lua` — the admin command. Broadcasts a new firmware file to all nodes (or a group).

## One-time install per node (the only visit)

For each node, once:

1. Wire it (computer + ender modem + its controllers/monitor/detector) and build its firmware from the graph:

   ```
   lua tools/build_routes.lua config/<your-network>.lua deploy --startup
   ```

   That writes `deploy/<node>.startup.lua` — the firmware with this node's config spliced in.

2. On the node's computer, install **two** files:
   - the bootstrap as `startup`     → `pastebin get <ht_boot code> startup`
   - its firmware as `firmware.lua`  → `pastebin get <node code> firmware.lua`
   - (optional) tag a group: `edit ht_group` → one word, e.g. `junction`.

3. Reboot. The bootstrap runs `firmware.lua` and listens for updates.

## Updating every node — no visits

When you improve `src/hypertube_node.lua`:

1. Get the new firmware file onto any computer that has an ender modem (the hub works) — e.g. `pastebin get <new code> firmware.lua`.
2. Run:

   ```
   ht_push firmware.lua          -- update every node
   ht_push firmware.lua junction -- only nodes tagged "junction"
   ```

Each matching node keeps its config, writes the new code, and reboots. Done — the whole network is on the new version.

> `ht_push` refuses to send a file that lacks the `@HT-CONFIG` markers, so you can't accidentally wipe every node's config.

## Changing a node's config

Config is per-node, so to change one node's settings (or after editing the graph and regenerating), re-install just that node's `firmware.lua` (paste it, reboot). Code pushes never touch config; config changes are per-node. (A future `ht_push --config <node>` could push a single node's config block too — ask if you want it.)

## Notes

- **Security:** anyone on the same rednet could broadcast an update. On a shared server, add a shared-secret check to the message if that matters — easy to bolt on.
- **Recovery:** because the bootstrap keeps the OTA listener alive even if the firmware crashes, a bad push is never fatal — push a corrected firmware and the node reboots into it.
- **Modems:** every node needs an **ender modem** for both routing and OTA.
