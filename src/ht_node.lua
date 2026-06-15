--[[
  HT Node — ONE firmware for every node. Self-organizing, multi-hop, cross-dim.
  ===========================================================================
  Install the SAME file on every computer. No per-node generated config.

  What it does on its own:
    * discovers its peripherals by capability (ender modem, monitor, player
      detector, and every Create Rotational Speed Controller);
    * first boot only: a quick on-screen SETUP — name the node, and for each
      tube you type which node it reaches. You can also add PORTAL links
      (walk-through, e.g. Overworld<->Nether) which have no controller;
    * shares its links over rednet (gossiped link-state); every node learns the
      whole graph and computes shortest paths itself;
    * routes any node to any node, switching at junctions; across a portal it
      tells you to walk through and the node on the far side resumes the trip
      (ender modems carry the shared trip across dimensions).

  Config lives in /ht_node.cfg (per node). CODE updates arrive via ht_boot/ht_push
  and never touch that file. Re-run setup any time with:  firmware.lua setup
--]]

local RPM           = 128
local CALIBRATE_RPM = 20     -- `firmware.lua spin <n>` ID speed (entrances need >=16 RPM to open)
local TRIP_TIMEOUT  = 30     -- seconds after a trip STARTS that it auto-clears (anchored to trip.ts)
local TRIP_BEAT     = 2      -- s: re-broadcast the active trip so a node that just loaded catches it
local RELAUNCH_HOLD = 3      -- s a junction/origin keeps its exit spinning after launching the rider
local LS_INTERVAL  = 5       -- seconds between link-state broadcasts (steady state)
local GRAPHFILE    = "/ht_graph.dat"  -- durable copy of the network map (survives reboot / chunk unload)
local PROTO        = "hypertube"
local CFG          = "/ht_node.cfg"
local BOARD_RANGE  = 2       -- pad detection: horizontal reach (blocks)
local BOARD_HEIGHT = 3       -- pad detection: vertical reach (blocks) - taller so a rider who lands
                             -- a block high/low is still seen (needs detector's getPlayersInCubic)
local args = { ... }
local VERSION  = "v18"       -- bump on every change; shown on the monitor + printed/logged on boot
local LOGPROTO = "ht_log"    -- live network log channel (the htlog viewer listens here)
local LOGFILE  = "/ht.log"   -- rolling local log on each node (view with: firmware.lua log)
local TUNEFILE = "/ht_tune.cfg"   -- per-node tuning overrides (survives OTA; set via: firmware.lua set)
local REPORTFILE = "/ht_report.txt"

-- Tunables you can adjust in-game without editing/redeploying code. `firmware.lua set
-- <KEY> <number>` writes /ht_tune.cfg; loaded here at boot so it survives firmware updates.
local TUNABLES = { "RPM", "CALIBRATE_RPM", "TRIP_TIMEOUT", "TRIP_BEAT", "RELAUNCH_HOLD", "LS_INTERVAL", "BOARD_RANGE", "BOARD_HEIGHT" }
-- Safe ranges. Out-of-range values are REJECTED by `set` and CLAMPED at boot, so neither a typo
-- nor a hand-edited /ht_tune.cfg can wedge a node (RPM<16 never opens a tube, TRIP_TIMEOUT=0 cancels
-- every trip, LS_INTERVAL/TRIP_BEAT=0 saturate the event loop, etc.).
local TUNE_MIN = { RPM = 16, CALIBRATE_RPM = 1,   TRIP_TIMEOUT = 5,   TRIP_BEAT = 1,  RELAUNCH_HOLD = 1,  LS_INTERVAL = 1,   BOARD_RANGE = 1,  BOARD_HEIGHT = 1 }
local TUNE_MAX = { RPM = 256, CALIBRATE_RPM = 256, TRIP_TIMEOUT = 600, TRIP_BEAT = 60, RELAUNCH_HOLD = 60, LS_INTERVAL = 300, BOARD_RANGE = 32, BOARD_HEIGHT = 64 }
local function clampTune(key, v)              -- numeric + clamped to the key's safe range, else nil
  v = tonumber(v)
  if not v or not TUNE_MIN[key] then return nil end
  return math.max(TUNE_MIN[key], math.min(TUNE_MAX[key], v))
end
local tune = {}
do
  if fs.exists(TUNEFILE) then
    local f = fs.open(TUNEFILE, "r")
    if f then local t = textutils.unserialize(f.readAll() or ""); f.close(); if type(t) == "table" then tune = t end end
  end
  RPM           = clampTune("RPM", tune.RPM)                     or RPM
  CALIBRATE_RPM = clampTune("CALIBRATE_RPM", tune.CALIBRATE_RPM) or CALIBRATE_RPM
  TRIP_TIMEOUT  = clampTune("TRIP_TIMEOUT", tune.TRIP_TIMEOUT)   or TRIP_TIMEOUT
  TRIP_BEAT     = clampTune("TRIP_BEAT", tune.TRIP_BEAT)         or TRIP_BEAT
  RELAUNCH_HOLD = clampTune("RELAUNCH_HOLD", tune.RELAUNCH_HOLD) or RELAUNCH_HOLD
  LS_INTERVAL   = clampTune("LS_INTERVAL", tune.LS_INTERVAL)     or LS_INTERVAL
  BOARD_RANGE   = clampTune("BOARD_RANGE", tune.BOARD_RANGE)     or BOARD_RANGE
  BOARD_HEIGHT  = clampTune("BOARD_HEIGHT", tune.BOARD_HEIGHT)   or BOARD_HEIGHT
end

local function now() return os.epoch("utc") end
local function trim(s) return s and (s:gsub("^%s+", ""):gsub("%s+$", "")) or s end

-- ---- peripheral discovery (by capability) --------------------------------
local function findAll(test)
  local list = {}
  for _, n in ipairs(peripheral.getNames()) do
    local ok, p = pcall(peripheral.wrap, n)
    if ok and p and test(n, p) then list[#list + 1] = { wrap = p, name = n } end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local ctrls  = findAll(function(_, p) return p.setTargetSpeed ~= nil end)
local detAll = findAll(function(_, p) return p.getPlayersInRange ~= nil end)
local monAll = findAll(function(_, p) return p.setTextScale ~= nil end)
local detector = detAll[1] and detAll[1].wrap or nil

-- Pick the monitor this node draws to: the one PINNED in config (firmware.lua monitor),
-- else the largest found. A station can legitimately have several monitors, so we let the
-- operator choose which screen is theirs instead of always guessing "largest" (which can
-- flip between deploys / leave the screen you're looking at stale). Assigned after cfg loads.
local mon, monName
local function pickMonitor(prefName)
  local bestW, best
  for _, m in ipairs(monAll) do
    if prefName and m.name == prefName then return m end
    local ok, w, h = pcall(m.wrap.getSize)
    if ok and (not bestW or w * h > bestW) then bestW = w * h; best = m end
  end
  return best
end

-- Two+ DETECTORS almost always means several nodes share ONE wired network (each node has a
-- single boarding pad). Multiple monitors is fine - pin one with `firmware.lua monitor`.
local sharedWarn = (#detAll > 1)

local function openModem()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "modem") then
      local p = peripheral.wrap(n)
      if p and p.isWireless and p.isWireless() then rednet.open(n); return true end
    end
  end
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "modem") then rednet.open(n); return true end
  end
  return false
end

-- Safe broadcast: NEVER let a missing/closed modem crash the node. A node with no
-- modem still boots, draws its screen, and runs locally - it just can't network.
local function bcast(msg)
  if rednet.isOpen() then pcall(rednet.broadcast, msg, PROTO) end
end

-- ---- config (name + links) ----------------------------------------------
local function loadCfg()
  if fs.exists(CFG) then
    local f = fs.open(CFG, "r"); local d = textutils.unserialize(f.readAll() or ""); f.close()
    if type(d) == "table" then return d end
  end
end
local function saveCfg(c)
  pcall(function() local f = fs.open(CFG, "w"); f.write(textutils.serialize(c)); f.close() end)
end

-- Roll-call: ask every node to announce, collect the names that answer within
-- `secs`. Nodes answer LSREQ with a STATE message (the whole map); the node
-- names are the keys of m.nodes. Returns a set {name=true,...} and whether a
-- modem was open to ask with.
local function probeNetwork(secs)
  local known = {}
  if not rednet.isOpen() then return known, false end
  pcall(rednet.broadcast, { type = "LSREQ" }, PROTO)
  local timer = os.startTimer(secs or 2.5)
  while true do
    local e = { os.pullEvent() }
    if e[1] == "rednet_message" and e[4] == PROTO then
      local m = e[3]
      if type(m) == "table" then
        if m.type == "STATE" and type(m.nodes) == "table" then
          for n in pairs(m.nodes) do known[n] = true end
        elseif m.type == "LS" and m.name then          -- legacy single-node announce
          known[m.name] = true
        end
      end
    elseif e[1] == "timer" and e[2] == timer then
      break
    end
  end
  return known, true
end

-- interactive first-time setup (uses the computer terminal)
local function runSetup()
  -- Setup must own the keyboard. Stop every tube (so nothing spins/launches) and
  -- blank the monitor with a notice, so the live menu can't sit there eating keys.
  for _, c in ipairs(ctrls) do pcall(c.wrap.setTargetSpeed, 0) end
  if mon then
    pcall(function()
      mon.setBackgroundColor(colors.black); mon.clear()
      mon.setTextColor(colors.yellow);    mon.setCursorPos(2, 2); mon.write("Setting up...")
      mon.setTextColor(colors.lightGray); mon.setCursorPos(2, 4); mon.write("Type on the computer.")
    end)
  end
  -- flush any queued key/char/touch events so the prompts don't auto-skip
  os.queueEvent("ht_drain"); repeat until select(1, os.pullEvent()) == "ht_drain"
  term.clear(); term.setCursorPos(1, 1)
  print("=== HT Node setup ===")
  if sharedWarn then
    print("[warn] >1 monitor/detector seen - this computer may share a")
    print("       wired network with another node. See: firmware.lua diag")
  end

  -- See who is already on the network: lets us verify names and show spellings.
  print("Scanning network...")
  local known, netOk = probeNetwork(2.5)
  local names = {}; for n in pairs(known) do names[#names + 1] = n end; table.sort(names)
  local canCheck = netOk and #names > 0
  if not netOk then            print("(no modem - names can't be verified)")
  elseif #names == 0 then      print("Online now: (none yet - skipping checks)")
  else                         print("Online now: " .. table.concat(names, ", ")) end

  -- Read a neighbour name on its OWN line (always fully visible). When other
  -- nodes are online, verify it's really one of them and let you retype a typo.
  -- Enter alone = skip / done.
  local function askNode(label)
    while true do
      print(""); print(label); write("> ")
      local v = trim(read())
      if not v or v == "" then return nil end
      if not canCheck or known[v] then
        if canCheck then print("  ok - '" .. v .. "' is online.") end
        return v
      end
      print("  ! no node named '" .. v .. "' is online.")
      print("    online: " .. table.concat(names, ", "))
      write("  use it anyway? (y/N): ")
      local yn = read()
      if yn == "y" or yn == "Y" then return v end
    end
  end

  print("")
  print("Name this node (hub, mine, nether_hub):")
  write("> ")
  local name = trim(read())
  while not name or name == "" do write("> "); name = trim(read()) end
  if canCheck and known[name] then
    print("  ! '" .. name .. "' is already on the network - names must be")
    print("    unique (continue only if you're replacing that node).")
  end

  local links = {}     -- controllerPeripheralName -> neighbour node name (tube)
  if #ctrls == 0 then
    print("")
    print("(No controllers found - this node has no tubes of its own.)")
  else
    print("")
    print(("This node has %d tube(s). For each, type the node"):format(#ctrls))
    print("it reaches. Enter alone skips a tube.")
    print("(ID a tube: Ctrl+T, then  firmware.lua spin 1)")
    os.queueEvent("ht_drain"); repeat until select(1, os.pullEvent()) == "ht_drain"
    for i = 1, #ctrls do
      local nb = askNode("Tube " .. i .. " goes to which node?")
      if nb then links[ctrls[i].name] = nb end
    end
  end

  local portals = {}   -- neighbour node names reached by walking through a portal
  while true do
    local p = askNode("Portal (walk-through) to which node? (Enter=none)")
    if not p then break end
    portals[#portals + 1] = p
  end

  local c = { name = name, links = links, portals = portals, monitor = (loadCfg() or {}).monitor }
  saveCfg(c)
  print("Saved. This node is '" .. name .. "'.")
  return c
end

local cfg = loadCfg()
do local m = pickMonitor(cfg and cfg.monitor); mon = m and m.wrap; monName = m and m.name end
local netUp = openModem()
if args[1] == "log" then          -- print this node's local log and exit
  if fs.exists(LOGFILE) then local f = fs.open(LOGFILE, "r"); print(f.readAll()); f.close()
  else print("(no log yet)") end
  return
end
if args[1] == "diag" then         -- print what this node sees; warn on a shared wired network
  print(("HT node diag - firmware %s"):format(VERSION))
  print("name : " .. (cfg and cfg.name or "(unconfigured)"))
  print("peripherals:")
  for _, n in ipairs(peripheral.getNames()) do
    print(("  %-26s %s"):format(n, peripheral.getType(n) or "?"))
  end
  print(("controllers=%d  monitors=%d  detectors=%d  modem=%s"):format(#ctrls, #monAll, #detAll, tostring(netUp)))
  print(("drawing to: %s %s"):format(tostring(monName or "NONE"), (cfg and cfg.monitor) and "[pinned]" or "[largest]"))
  if #monAll > 1 then print("[note] " .. #monAll .. " monitors - if the wrong screen updates, run: firmware.lua monitor") end
  if sharedWarn then
    print("[warn] more than one DETECTOR visible - several nodes likely share")
    print("       one wired network. Each node must be on its OWN isolated wired")
    print("       network; the ender modem is the only cross-node link.")
  end
  return
end
if args[1] == "monitor" then      -- pick WHICH monitor this node draws to (when it has several)
  if #monAll == 0 then print("No monitor attached to this computer."); return end
  if #monAll == 1 then print("Only one monitor (" .. monAll[1].name .. ") - nothing to pick."); return end
  for i, m in ipairs(monAll) do   -- label each physical screen so you can tell which is which
    pcall(function()
      m.wrap.setTextScale(1); m.wrap.setBackgroundColor(colors.black); m.wrap.clear()
      m.wrap.setTextColor(colors.yellow); m.wrap.setCursorPos(2, 2); m.wrap.write("MONITOR " .. i)
      m.wrap.setTextColor(colors.lightGray); m.wrap.setCursorPos(2, 3); m.wrap.write(m.name)
    end)
  end
  print("Each monitor now shows a number. Which one is THIS")
  print("station's screen? Enter 1.." .. #monAll .. " (Enter = cancel):")
  write("> ")
  local pick = tonumber(read())
  if not pick or not monAll[pick] then print("Cancelled."); return end
  local c = loadCfg() or {}
  c.monitor = monAll[pick].name
  saveCfg(c)
  print("Pinned " .. monAll[pick].name .. ". Rebooting..."); sleep(1); os.reboot()
end
if args[1] == "reset" then        -- wipe name + calibration + learned map + tuning, then reboot
  for _, p in ipairs({ CFG, GRAPHFILE, TUNEFILE }) do if fs.exists(p) then fs.delete(p) end end
  print("Config + tuning cleared - rebooting into fresh setup...")
  sleep(1); os.reboot()
end
if args[1] == "forget" then       -- drop only the learned map (re-learn topology); keep name + links
  if fs.exists(GRAPHFILE) then fs.delete(GRAPHFILE) end
  print("Map cleared - rebooting..."); sleep(1); os.reboot()
end
if args[1] == "set" then          -- tweak a tunable in-game (persists in /ht_tune.cfg, survives OTA)
  local key, val = args[2], tonumber(args[3])
  if not key or not TUNE_MIN[key] or not val then
    print("usage: firmware.lua set <KEY> <number>")
    print("keys: " .. table.concat(TUNABLES, " "))
    return
  end
  if val < TUNE_MIN[key] or val > TUNE_MAX[key] then   -- reject out-of-range so a typo can't wedge the node
    print(("%s must be %s..%s (got %s)"):format(key, TUNE_MIN[key], TUNE_MAX[key], val)); return
  end
  tune[key] = val
  local f = fs.open(TUNEFILE, "w"); if f then f.write(textutils.serialize(tune)); f.close() end
  print(key .. " = " .. val .. " saved. Rebooting to apply..."); sleep(1); os.reboot()
end
if args[1] == "report" then       -- write a full diagnostic snapshot to a file you can send for debugging
  local L = {}
  local function add(s) L[#L + 1] = s or "" end
  add("=== HT NODE REPORT (firmware " .. VERSION .. ") ===")
  add("time(epoch ms): " .. now())
  add(("computer id=%s label=%s"):format(tostring(os.getComputerID()), tostring(os.getComputerLabel())))
  add("")
  add("[config " .. CFG .. "]")
  add("name: " .. (cfg and cfg.name or "(UNCONFIGURED)"))
  add("tubes (controller -> neighbour):")
  if cfg and type(cfg.links) == "table" and next(cfg.links) then
    for c, nb in pairs(cfg.links) do add(("  %-30s -> %s"):format(c, nb)) end
  else add("  (none)") end
  add("portals (walk-through): " .. ((cfg and cfg.portals and #cfg.portals > 0) and table.concat(cfg.portals, ", ") or "(none)"))
  add("")
  add("[tuning]  (current effective values)")
  add(("  RPM=%s CALIBRATE_RPM=%s TRIP_TIMEOUT=%s TRIP_BEAT=%s"):format(RPM, CALIBRATE_RPM, TRIP_TIMEOUT, TRIP_BEAT))
  add(("  RELAUNCH_HOLD=%s LS_INTERVAL=%s BOARD_RANGE=%s BOARD_HEIGHT=%s"):format(RELAUNCH_HOLD, LS_INTERVAL, BOARD_RANGE, BOARD_HEIGHT))
  local ov = {}; for k, v in pairs(tune) do ov[#ov + 1] = k .. "=" .. tostring(v) end
  add("  overrides (" .. TUNEFILE .. "): " .. (#ov > 0 and table.concat(ov, " ") or "none"))
  add("")
  add("[peripherals]")
  for _, n in ipairs(peripheral.getNames()) do add(("  %-28s %s"):format(n, peripheral.getType(n) or "?")) end
  local msz = "n/a"; if mon then local ok, w, h = pcall(mon.getSize); if ok then msz = w .. "x" .. h end end
  add(("counts: controllers=%d monitors=%d detectors=%d modem(open)=%s"):format(#ctrls, #monAll, #detAll, tostring(netUp)))
  add(("drawing to monitor: %s (%s) %s"):format(tostring(monName or "NONE"), msz, (cfg and cfg.monitor) and "[pinned]" or "[largest]"))
  if #monAll > 1 then add("  NOTE: " .. #monAll .. " monitors present - pin yours with: firmware.lua monitor") end
  add("shared-network warning: " .. (sharedWarn and "YES (>1 detector - several nodes likely share one wired network; isolate them)" or "no"))
  add("")
  add("[network map " .. GRAPHFILE .. "]  (node -> neighbours ; age)")
  local gf = fs.exists(GRAPHFILE) and fs.open(GRAPHFILE, "r") or nil
  if gf then
    local d = textutils.unserialize(gf.readAll() or ""); gf.close()
    if type(d) == "table" and type(d.graph) == "table" then
      local names = {}; for nm in pairs(d.graph) do names[#names + 1] = nm end; table.sort(names)
      for _, nm in ipairs(names) do
        local age = (type(d.gen) == "table" and d.gen[nm]) and (math.floor((now() - d.gen[nm]) / 1000) .. "s") or "?"
        add(("  %-22s -> %s   (age %s)"):format(nm, table.concat(d.graph[nm] or {}, ", "), age))
      end
    else add("  (unreadable)") end
  else add("  (no map yet - this node hasn't learned the network)") end
  add("")
  add("[recent log " .. LOGFILE .. "]  (last 40 lines)")
  local lf = fs.exists(LOGFILE) and fs.open(LOGFILE, "r") or nil
  if lf then
    local allText = lf.readAll() or ""; lf.close()
    local lines = {}; for ln in (allText .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = ln end
    for i = math.max(1, #lines - 40), #lines do if lines[i] ~= "" then add("  " .. lines[i]) end end
  else add("  (no log yet)") end
  local outf = fs.open(REPORTFILE, "w")
  if not outf then print("Could not write " .. REPORTFILE); return end
  outf.write(table.concat(L, "\n") .. "\n"); outf.close()
  print("Wrote " .. REPORTFILE .. " (" .. #L .. " lines).")
  print("Send it to me:  pastebin put " .. REPORTFILE)
  print("  then paste the URL. (Or read it locally: edit " .. REPORTFILE .. ")")
  return
end
if args[1] == "spin" then         -- identify tubes: spin all (or one) in turn, then exit
  local n = tonumber(args[2])
  if n and not ctrls[n] then
    print("usage: firmware.lua spin [1.." .. #ctrls .. "]   (no number = all)"); return
  end
  print("Spinning " .. (n and ("tube " .. n) or (#ctrls .. " tubes")) .. ". STEP OFF THE PAD - 5s...")
  for s = 5, 1, -1 do io.write(s .. " "); sleep(1) end
  print("")
  for i = 1, #ctrls do
    if not n or n == i then
      print("Tube " .. i .. " spinning...")
      pcall(ctrls[i].wrap.setTargetSpeed, CALIBRATE_RPM); sleep(4); pcall(ctrls[i].wrap.setTargetSpeed, 0); sleep(1)
    end
  end
  print("Done. Now run: firmware.lua setup")
  return
end
if args[1] == "setup" then        -- explicit setup mode: run it (typeable) and exit
  runSetup(); return
end
if not cfg or not cfg.name then   -- launched directly without the bootstrap
  cfg = runSetup()
end

local NAME    = cfg.name
local LINKS   = cfg.links or {}       -- controllerName -> neighbour
local PORTALS = cfg.portals or {}     -- list of portal neighbours

-- log to the computer screen, a local file, and the live network log channel
local function log(msg)
  print(NAME .. ": " .. msg)
  pcall(function() local f = fs.open(LOGFILE, "a"); if f then f.writeLine(now() .. " " .. msg); f.close() end end)
  if rednet.isOpen() then pcall(rednet.broadcast, { node = NAME, ver = VERSION, msg = msg }, LOGPROTO) end
end

-- my neighbour set (tube + portal)
local function myNeighbours()
  local seen, out = {}, {}
  for _, nb in pairs(LINKS) do if not seen[nb] then seen[nb] = true; out[#out + 1] = nb end end
  for _, nb in ipairs(PORTALS) do if not seen[nb] then seen[nb] = true; out[#out + 1] = nb end end
  return out
end

-- ---- shared network map (gossiped link-state) ----------------------------
-- Every node keeps the WHOLE map (node -> {neighbours}); `gen` holds when each
-- node last refreshed itself. Nodes gossip the entire map, so ONE reply hands a
-- newcomer the complete network at once. The timestamps make merges safe (a
-- node's own fresh news always beats a stale gossiped copy).
local graph = { [NAME] = myNeighbours() }    -- node -> { neighbour, ... }
local gen   = { [NAME] = now() }             -- node -> last-refresh epoch (ms)

local function setNameLabel() if os.getComputerLabel() ~= NAME then os.setComputerLabel(NAME) end end

-- Durable topology. Persist the whole map so this node can route even when other
-- nodes are unloaded (their computers are off). We do NOT forget a quiet node -
-- quiet almost always means "chunk unloaded", not "removed" (use `forget` to drop
-- the map deliberately). Timestamps still keep live merges correct (fresher wins).
local function saveGraph()
  pcall(function()
    local f = fs.open(GRAPHFILE, "w")
    if f then f.write(textutils.serialize({ graph = graph, gen = gen })); f.close() end
  end)
end
local function loadGraph()
  if not fs.exists(GRAPHFILE) then return end
  pcall(function()
    local f = fs.open(GRAPHFILE, "r"); local d = textutils.unserialize(f.readAll() or ""); f.close()
    if type(d) == "table" and type(d.graph) == "table" then
      for n, nbrs in pairs(d.graph) do
        if n ~= NAME and type(nbrs) == "table" then        -- our own row stays authoritative
          graph[n] = nbrs; gen[n] = (type(d.gen) == "table" and d.gen[n]) or 0
        end
      end
    end
  end)
end
loadGraph()   -- begin from the last-known topology, so routing works before anyone announces

-- refresh our own row, then gossip the ENTIRE known map
local function broadcastState()
  graph[NAME] = myNeighbours(); gen[NAME] = now()
  saveGraph()
  local nodes = {}
  for n, nbrs in pairs(graph) do nodes[n] = { nbrs = nbrs, ts = gen[n] or 0 } end
  bcast({ type = "STATE", nodes = nodes })
end

-- merge a gossiped map; per node, keep the newer timestamp. true if anything changed.
local function mergeState(nodes)
  if type(nodes) ~= "table" then return false end
  local changed = false
  for n, info in pairs(nodes) do
    if type(info) == "table" and type(info.nbrs) == "table" then
      local ts = tonumber(info.ts) or 0
      if not gen[n] or ts > gen[n] then graph[n] = info.nbrs; gen[n] = ts; changed = true end
    end
  end
  if changed then saveGraph() end
  return changed
end

-- shortest path NAME..dest over the (undirected) graph; nil if unreachable
local function pathTo(dest)
  if dest == NAME then return { NAME } end
  local prev, q, head = { [NAME] = NAME }, { NAME }, 1
  while head <= #q do
    local cur = q[head]; head = head + 1
    for _, nb in ipairs(graph[cur] or {}) do
      if not prev[nb] then
        prev[nb] = cur
        if nb == dest then
          local path, c = { dest }, dest
          while c ~= NAME do c = prev[c]; table.insert(path, 1, c) end
          return path
        end
        q[#q + 1] = nb
      end
    end
  end
end

-- every node this node can route to, with its hop-distance (path length - 1)
local function reachable()
  local seen, cand = {}, {}
  local function add(n) if not seen[n] then seen[n] = true; cand[#cand + 1] = n end end
  for node, nbrs in pairs(graph) do        -- include nodes that announced...
    add(node)
    for _, nb in ipairs(nbrs) do add(nb) end  -- ...and any node named as a neighbour
  end
  local out = {}
  for _, node in ipairs(cand) do
    if node ~= NAME then
      local p = pathTo(node)
      if p then out[#out + 1] = { name = node, dist = #p - 1 } end
    end
  end
  return out
end

-- apply the current filter (case-insensitive substring) + sort mode to reachable()
local SORTS = { "Dist +", "Dist -", "A-Z" }     -- cycled by the Sort button; 1 = nearest first
local function orderedDests(filter, sortIdx)
  local list = reachable()
  if filter and filter ~= "" then
    local q = filter:lower()
    local kept = {}
    for _, d in ipairs(list) do if d.name:lower():find(q, 1, true) then kept[#kept + 1] = d end end
    list = kept
  end
  local mode = SORTS[sortIdx] or SORTS[1]
  table.sort(list, function(a, b)
    if mode == "A-Z" then return a.name < b.name end
    if a.dist ~= b.dist then                        -- distance modes; ties broken alphabetically
      if mode == "Dist -" then return a.dist > b.dist end
      return a.dist < b.dist
    end
    return a.name < b.name
  end)
  return list
end

-- ---- gates ---------------------------------------------------------------
-- IMPORTANT: only ever drive controllers THIS node was configured to own (names
-- present in LINKS). On a shared wired network `ctrls` also lists neighbours'
-- controllers; touching those would stop a neighbour's running tube.
local function controllerToward(nb)            -- the wrapped RSC for a tube neighbour, or nil
  for _, c in ipairs(ctrls) do
    if LINKS[c.name] == nb then return c.wrap end
  end
end
local function gateToward(nb)                  -- spin only the owned tube to nb (nil = stop owned)
  for _, c in ipairs(ctrls) do
    if LINKS[c.name] then                      -- skip controllers we don't own
      pcall(c.wrap.setTargetSpeed, (nb ~= nil and LINKS[c.name] == nb) and RPM or 0)
    end
  end
end
local function allStop() gateToward(nil) end

-- ---- trip state ----------------------------------------------------------
-- `active` is the trip currently moving someone. `tripDeadline` is an ABSOLUTE
-- wall-clock time (anchored to the trip's start), so periodic re-broadcasts
-- (beats) can NEVER push it back and livelock the timeout. `done` remembers
-- recently-finished trip ids so a late beat can't resurrect a cleared trip.
local active, relaunchStop, tripDeadline = nil, nil, nil
local done = {}                               -- trip id -> epoch ms after which we forget it
local hintRef = { text = nil }                -- set by applyTrip's callers; read by refresh

local function markDone(id) if id then done[id] = now() + TRIP_TIMEOUT * 1000 end end
local function pruneDone() local t = now(); for id, exp in pairs(done) do if t > exp then done[id] = nil end end end

local function indexIn(path) for i, n in ipairs(path) do if n == NAME then return i end end end

-- set this node's gate for a trip and return a human hint for our screen
local function applyTrip(t)
  relaunchStop = nil                           -- a new trip supersedes any prior origin auto-close timer
  local i = indexIn(t.path)
  if not i then allStop(); return nil end      -- we're not on this path
  if i == #t.path then allStop(); return ("Arrived: %s"):format(t.rider or "traveller") end
  local nxt = t.path[i + 1]
  if not controllerToward(nxt) then            -- portal hop: no tube/controller here
    allStop(); return ("Walk through the portal to %s"):format(nxt)
  end
  gateToward(nxt)                              -- open the through-tube and KEEP it open: a 90-deg
                                               -- junction passes the rider, and one who stops at the
                                               -- open mouth is pulled onward too.
  if i == 1 then                               -- origin: auto-close shortly after launch so a rider
    relaunchStop = os.startTimer(RELAUNCH_HOLD) -- who bounces back can't be instantly re-grabbed
    return ("Board -> %s"):format(t.to)
  end
  return ("Pass through -> %s"):format(t.to)
end

local function setActive(t)
  active = t
  tripDeadline = (tonumber(t.ts) or now()) + TRIP_TIMEOUT * 1000   -- absolute; immune to beats
end

-- ---- player presence -----------------------------------------------------
-- names of every player currently within the pad volume (cuboid if the detector
-- supports it, so vertical reach can be taller; else a plain sphere).
local function playersOnPad()
  if not detector then return {} end
  local players
  if detector.getPlayersInCubic then
    local ok, p = pcall(detector.getPlayersInCubic, BOARD_RANGE, BOARD_HEIGHT, BOARD_RANGE)
    if ok then players = p end
  end
  if not players then
    local ok, p = pcall(detector.getPlayersInRange, math.max(BOARD_RANGE, BOARD_HEIGHT))
    if ok then players = p end
  end
  local out = {}
  if type(players) == "table" then
    for _, pl in ipairs(players) do
      local nm = (type(pl) == "table") and pl.name or pl     -- detector may return objects or names
      if nm then out[#out + 1] = nm end
    end
  end
  return out
end
-- the named player if they're on the pad; with name=nil, whoever is on the pad.
-- Arrival is confirmed against the trip's OWN rider, so a bystander standing on a
-- destination pad can't falsely complete someone else's trip.
local function onPad(name)
  for _, who in ipairs(playersOnPad()) do
    if not name or who == name then return who end
  end
  return nil
end
local function riderOnPad() return onPad(nil) end             -- whoever's here (boarding / greeting)

-- ---- UI ------------------------------------------------------------------
-- Touch UI: a control bar (Sort cycle + Find), a scrollable destination list
-- that shows each stop's hop-distance, and an on-screen keyboard for the filter.
local filter, sortIdx, kbOpen = "", 1, false
local rowDest = {}                       -- y -> destination name (tappable list rows)
local navRow, navMid, pageStep, scroll = nil, nil, 1, 0
local btnSort, btnFind = nil, nil        -- control-bar tap regions {y,x1,x2}
local kbKeys = {}                        -- on-screen keyboard regions { {y,x1,x2,k}, ... }

local function header(w)
  mon.setBackgroundColor(colors.blue); mon.setCursorPos(1, 1); mon.clearLine()
  mon.setTextColor(colors.white); mon.setCursorPos(2, 1); mon.write(NAME:sub(1, math.max(1, w - #VERSION - 2)))
  mon.setTextColor(colors.lightGray); mon.setCursorPos(math.max(2, w - #VERSION), 1); mon.write(VERSION)
end

local function drawKeyboard()
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black); mon.clear(); header(w)
  kbKeys = {}
  mon.setBackgroundColor(colors.gray); mon.setCursorPos(1, 2); mon.clearLine()
  mon.setTextColor(colors.white); mon.setCursorPos(2, 2); mon.write(("Find: %s_"):format(filter):sub(1, w - 1))
  local keys = "abcdefghijklmnopqrstuvwxyz0123456789"
  local kw, perRow, y, col = 3, math.max(1, math.floor(w / 3)), 4, 0
  for i = 1, #keys do
    if col >= perRow then col = 0; y = y + 1 end
    if y > h - 1 then break end                       -- keep row h for the control buttons
    local x1 = col * kw + 1
    mon.setBackgroundColor(colors.gray); mon.setTextColor(colors.white)
    mon.setCursorPos(x1, y); mon.write(" " .. keys:sub(i, i) .. " ")
    kbKeys[#kbKeys + 1] = { y = y, x1 = x1, x2 = x1 + kw - 1, k = keys:sub(i, i) }
    col = col + 1
  end
  local segs = { { k = "spc", l = "space" }, { k = "del", l = "del" }, { k = "clr", l = "clr" }, { k = "ok", l = "OK" } }
  local segw = math.max(1, math.floor(w / #segs))
  for i, s in ipairs(segs) do
    local x1 = (i - 1) * segw + 1
    if x1 <= w then                                   -- skip any segment that would fall off a tiny screen
      local x2 = (i == #segs) and w or math.min(w, x1 + segw - 1)
      mon.setBackgroundColor(s.k == "ok" and colors.green or colors.gray); mon.setTextColor(colors.white)
      mon.setCursorPos(x1, h); mon.write((" " .. s.l .. string.rep(" ", w)):sub(1, x2 - x1 + 1))
      kbKeys[#kbKeys + 1] = { y = h, x1 = x1, x2 = x2, k = s.k }
    end
  end
end

local function drawList(status, color)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black); mon.clear(); header(w)
  rowDest, navRow = {}, nil
  -- control bar (row 2): Sort cycle | Find
  local sx = math.floor(w / 2)
  btnSort = { y = 2, x1 = 1, x2 = sx }
  btnFind = { y = 2, x1 = sx + 1, x2 = w }
  mon.setCursorPos(1, 2); mon.setBackgroundColor(colors.cyan); mon.setTextColor(colors.black)
  mon.write((" Sort:" .. SORTS[sortIdx] .. string.rep(" ", w)):sub(1, sx))
  mon.setBackgroundColor(filter == "" and colors.lightGray or colors.orange)
  mon.write(((filter == "" and " Find" or (" Find:" .. filter)) .. string.rep(" ", w)):sub(1, w - sx))
  -- list rows: 3..(h-1), or 3..(h-2) reserving row h-1 for the scroll bar when paged.
  -- status always sits on row h. All bounds are guarded so a tiny monitor never
  -- overlaps the control/nav/status rows or draws a phantom row.
  local dests = orderedDests(filter, sortIdx)
  local top = 3
  local cap0 = math.max(0, (h - 1) - top + 1)        -- list capacity if NOT paged (status on row h)
  local paged = cap0 > 0 and #dests > cap0
  local bottom = paged and (h - 2) or (h - 1)        -- when paged, the scroll bar takes its own row h-1
  local capacity = math.max(0, bottom - top + 1)
  pageStep = math.max(1, capacity)
  scroll = (capacity > 0) and math.max(0, math.min(scroll, math.max(0, #dests - capacity))) or 0
  local y = top
  for idx = scroll + 1, math.min(#dests, scroll + capacity) do
    local d = dests[idx]
    local tag = (d.dist <= 1) and "direct" or (d.dist .. " hops")
    mon.setCursorPos(1, y); mon.setBackgroundColor(active and colors.gray or colors.green); mon.setTextColor(colors.white)
    local left = (" " .. d.name .. string.rep(" ", w)):sub(1, math.max(1, w - #tag - 1))
    mon.write((left .. tag .. " "):sub(1, w))
    rowDest[y] = d.name
    y = y + 1
  end
  if #dests == 0 and capacity > 0 then
    mon.setCursorPos(2, top); mon.setBackgroundColor(colors.black); mon.setTextColor(colors.lightGray)
    mon.write((filter ~= "" and ("No match for '" .. filter .. "'") or "No stations yet"):sub(1, math.max(1, w - 1)))
  end
  if paged then                                      -- scroll bar on its OWN row: left half = up, right = down
    navRow, navMid = h - 1, math.floor(w / 2)
    mon.setCursorPos(1, navRow)
    mon.setBackgroundColor(scroll > 0 and colors.cyan or colors.gray); mon.setTextColor(colors.white)
    mon.write((" ^ up" .. string.rep(" ", w)):sub(1, navMid))
    mon.setBackgroundColor((scroll + capacity) < #dests and colors.cyan or colors.gray)
    local rw = w - navMid
    mon.write((string.rep(" ", rw) .. "down v "):sub(-rw))
  end
  mon.setBackgroundColor(colors.black); mon.setTextColor(color or colors.lightGray)
  mon.setCursorPos(1, h); mon.write((status or "Tap a destination"):sub(1, w))
end

local function draw(status, color)
  if not mon then return end
  if kbOpen then drawKeyboard() else drawList(status, color) end
end

local function refresh()
  if kbOpen then draw(); return end                  -- the filter keyboard owns the screen while open
  if active then draw(hintRef.text or ("Net: " .. (active.rider or "?") .. " -> " .. active.to), colors.orange)
  elseif detector then
    local who = riderOnPad()
    if who then draw("Welcome, " .. who .. " - tap a destination", colors.lime)
    else draw("Step onto the pad to travel", colors.lightGray) end
  else draw() end
end

-- ---- trips ---------------------------------------------------------------
-- end the current trip and remember its id, so a late beat can't resurrect it
local function endTrip(reason)
  if active then markDone(active.id) end
  active, hintRef.text, tripDeadline, relaunchStop = nil, nil, nil, nil  -- cancel any pending auto-close
  allStop(); refresh()
  if reason then log(reason) end
end

local function startTrip(dest)
  if dest == NAME then return end
  pruneDone()
  -- debounce accidental double-taps, but DON'T hard-lock: re-tapping re-routes
  if active and (now() - (active.ts or 0)) < 1500 then return end
  local path = pathTo(dest)
  if not path then draw("No route to " .. dest, colors.red); return end
  local rider = riderOnPad()
  if detector and not rider then draw("Step onto the pad first", colors.orange); return end
  local t = { type = "ROUTE", id = NAME .. ":" .. now(), from = NAME, to = dest, path = path, rider = rider, ts = now() }
  bcast(t)                                   -- tell every hop on the path to open its gate FIRST
  log("start -> " .. dest .. " via " .. table.concat(path, ">") .. (rider and (" (" .. rider .. ")") or ""))
  setActive(t); hintRef.text = applyTrip(t); refresh()   -- launch from our pad; junctions catch & relaunch
end

local function handle(msg)
  if type(msg) ~= "table" then return end
  if msg.type == "STATE" then
    if mergeState(msg.nodes) and not active then refresh() end
  elseif msg.type == "LS" and msg.name then            -- legacy single-node announce (transition)
    graph[msg.name] = msg.neighbours or {}; gen[msg.name] = now()
    if not active then refresh() end
  elseif msg.type == "LSREQ" then
    broadcastState()
  elseif msg.type == "TRIPREQ" then
    if active then bcast(active) end    -- relay an in-progress trip to a node that just (re)loaded
  elseif msg.type == "ROUTE" and msg.path and msg.id then
    pruneDone()
    if done[msg.id] then return end     -- a trip we've already finished: ignore late/resurrecting beats
    if active and active.id == msg.id then
      active = msg                      -- same trip: keep it alive, but DON'T reset the deadline
      return                            -- (absolute deadline) and DON'T re-fire the gate (no suck-back)
    end
    setActive(msg)                      -- a trip we haven't seen: pick it up and open our gate
    hintRef.text = applyTrip(msg); refresh()
    if hintRef.text then log("route " .. (msg.to or "?") .. " : " .. hintRef.text) end
  elseif msg.type == "ARRIVED" then
    markDone(msg.id)                    -- record it done even if we weren't holding it
    if active and (msg.id == nil or active.id == msg.id) then
      endTrip("arrived at " .. (msg.at or "?") .. " - trip done")
    else
      log("arrived at " .. (msg.at or "?") .. " - trip done")
    end
  end
end

-- ---- boot ----------------------------------------------------------------
-- NOTE: trip state is deliberately RAM-only (not persisted). A node that reloads
-- boots with NO active trip and waits for a fresh ROUTE/beat; a still-loaded peer
-- relays an in-progress trip to it on TRIPREQ. This avoids re-opening a gate for a
-- trip that already finished while we were unloaded (a suck-back hazard). The
-- network MAP is persisted (GRAPHFILE); the trip is not.
setNameLabel()
allStop()
log(("boot firmware %s | tubes=%d detector=%s modem=%s monitor=%s"):format(VERSION, #ctrls, tostring(detector ~= nil), tostring(netUp), tostring(monName or false)))
if #monAll > 1 then log(("note: %d monitors - drawing to %s (pin with: firmware.lua monitor)"):format(#monAll, tostring(monName))) end
if sharedWarn then log("WARNING: >1 detector - several nodes may share one wired network (firmware.lua diag)") end
refresh()                       -- draw the screen FIRST, before any networking, so the monitor
                                -- always shows current state even if this node has no modem
if not netUp then print("[warn] no modem - this node can't see the network.") end
broadcastState()
bcast({ type = "LSREQ" })       -- ask everyone to announce
bcast({ type = "TRIPREQ" })     -- on (re)load, catch up on any trip already in progress
local lsTimer   = os.startTimer(LS_INTERVAL)
local padTimer  = os.startTimer(1)
local beatTimer = os.startTimer(TRIP_BEAT)
local warm      = 5                              -- quick extra roll-calls right after
local warmTimer = os.startTimer(0.5)             -- boot so we converge in ~1-2s, not 15s
refresh()

while true do
  local e = { os.pullEvent() }
  local ev = e[1]
  if ev == "monitor_touch" and (not monName or e[2] == monName) then  -- only OUR screen's taps
    local tx, ty = e[3], e[4]
    if kbOpen then                                   -- filter keyboard: append/edit the query
      local hit = false
      for _, k in ipairs(kbKeys) do
        if ty == k.y and tx >= k.x1 and tx <= k.x2 then
          hit = true
          if k.k == "ok" then kbOpen = false
          elseif k.k == "del" then filter = filter:sub(1, #filter - 1)
          elseif k.k == "clr" then filter = ""
          elseif k.k == "spc" then filter = filter .. " "
          else filter = filter .. k.k end
          scroll = 0; refresh(); break
        end
      end
      if not hit then kbOpen = false; refresh() end  -- tap outside any key always closes (guaranteed exit)
    elseif btnSort and ty == btnSort.y and tx >= btnSort.x1 and tx <= btnSort.x2 then
      sortIdx = sortIdx % #SORTS + 1; scroll = 0; refresh()   -- cycle Dist+ / Dist- / A-Z
    elseif btnFind and ty == btnFind.y and tx >= btnFind.x1 and tx <= btnFind.x2 then
      kbOpen = true; refresh()                                -- open the filter keyboard
    elseif rowDest[ty] then startTrip(rowDest[ty])
    elseif navRow and ty == navRow then                       -- tapped the scroll bar
      if tx <= (navMid or 0) then scroll = math.max(0, scroll - pageStep) else scroll = scroll + pageStep end
      refresh()
    end
  elseif ev == "rednet_message" then
    if e[4] == PROTO then handle(e[3])
    elseif e[4] == LOGPROTO and type(e[3]) == "table" and e[3].ping then
      log("here - firmware " .. VERSION)       -- viewer asked who's online; report version
    end
  elseif ev == "timer" then
    if e[2] == lsTimer then broadcastState(); lsTimer = os.startTimer(LS_INTERVAL)
    elseif e[2] == warmTimer then
      if warm > 0 then
        warm = warm - 1
        bcast({ type = "LSREQ" }); broadcastState()
        warmTimer = os.startTimer(0.5)
      end
    elseif e[2] == relaunchStop then
      relaunchStop = nil
      if active then allStop() end   -- close our launch exit so a bounce can't re-grab the rider
    elseif e[2] == beatTimer then
      if active then bcast(active) end   -- keep relaying so nodes loading mid-route catch it
      beatTimer = os.startTimer(TRIP_BEAT)
    elseif e[2] == padTimer then
      if active and tripDeadline and now() > tripDeadline then
        endTrip("trip timed out - clearing")                  -- absolute deadline backstop
      elseif active and active.to == NAME and onPad(active.rider) then
        bcast({ type = "ARRIVED", at = NAME, id = active.id }) -- DESTINATION sees OUR rider land: confirm
        endTrip("arrived: " .. (active.rider or "traveller"))
      elseif not active then refresh() end
      -- poll faster while we're the active destination so a quick rider isn't missed
      padTimer = os.startTimer((active and active.to == NAME) and 0.4 or 1)
    end
  end
end
