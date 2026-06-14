# Shipping the network

"Shipping" a ComputerCraft project = put the code somewhere the in-game computers can fetch it, make installing a node a one-liner, and let updates flow over the air after that. You only ever do step 1–2 once.

## 1. Pick where the code lives

You need a URL each computer can `http.get`. Two easy options:

- **GitHub (recommended).** Push this repo to a **public** GitHub repo. Every file then has a stable raw URL:
  `https://raw.githubusercontent.com/<user>/<repo>/main/<path>`. Free, updatable in place, and others can install it too.
- **Pastebin.** Fine for one-off files, but every file is a separate code and editing needs an account — clunky for the whole set. Use it only if GitHub raw is blocked.

> The server must allow the HTTP API to that host. You've already used pastebin, so HTTP is on; if `raw.githubusercontent.com` is blocked by the server's allowlist, fall back to pastebin or ask the admin to allow it.

### Finalize git, then push (on your machine)

The in-sandbox `.git` was left wedged earlier, so start it clean:

```bash
cd .../economy/hypertube-network
rm -rf .git __deltest__ deploy/_*.lua
git init && git add -A && git commit -m "Hypertube network"
git remote add origin https://github.com/<user>/<repo>.git
git push -u origin main
```

## 2. Generate the per-node firmware and publish it

Each node's firmware = the shared code + that node's config. Generate them from your network graph and commit them so the installer can fetch them:

```bash
lua tools/build_routes.lua config/<your-network>.lua deploy --startup
git add deploy/*.startup.lua && git commit -m "node firmware" && git push
```

Then edit **`BASE`** at the top of `src/installer.lua` to your raw URL and push that too.

## 3. Install each node — one line

On every node's computer (the only visit it needs):

```
wget run <BASE>/installer.lua <node-id> [group]
```

e.g. `wget run https://raw.githubusercontent.com/me/hypertube/main/installer.lua hub`

It fetches the **bootstrap → `startup`** and that node's **firmware → `firmware.lua`**, tags the group if given, and reboots. (No `wget`? `pastebin run <code> hub` works the same if you host the installer on pastebin.)

Manual equivalent, if you'd rather not use the installer:

```
wget <BASE>/src/ht_boot.lua startup
wget <BASE>/deploy/<node-id>.startup.lua firmware.lua
reboot
```

## 4. Update everything — no visits

Change `src/hypertube_node.lua`, push it to the host, then from any node with an ender modem:

```
wget <BASE>/src/hypertube_node.lua firmware.lua   # get the new template locally
ht_push firmware.lua                              # broadcast to all nodes
```

Every node keeps its own config and reboots into the new code (`docs/remote-update.md`).

## Shipping checklist

- [ ] Step 0 mechanic verified in-game.
- [ ] Network graph written; `build_routes.lua` runs clean (no audit warnings).
- [ ] Repo pushed to a public host; `BASE` set in `installer.lua`.
- [ ] `deploy/<node>.startup.lua` committed for every node.
- [ ] One node installed and a multi-hop trip (A→B→C) tested.
- [ ] One `ht_push` tested end-to-end before rolling out to all nodes.
