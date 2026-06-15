--[[
  HT Node — ONE firmware for every node. Self-organizing, multi-hop, cross-dim.
  ===========================================================================
  Install the SAME file on every computer. No per-node generated config.

  What it does on its own:
    * discovers its peripherals by capability (ender modem, monitor, player
      detector, and every Create Rotational Speed Controller);
    * first boot only: a quick on-screen SETUP — name the node, and for each
      tube it spins the controller so you can see which one, then you type which
      node that tube reaches. You can also add PORTAL links (walk-through, e.g.
      Overworld<->Nether) which have no controller;
    * shares its links over rednet (link-state); every node thus learns the whole
      graph and computes shortest paths itself;
    * routes any node to any node, switching at junctions; across a portal it
      tells you to walk through and the node on the far side resumes the trip
      (ender modems carry the shared trip across dimensions).

  Config lives in /ht_node.cfg (per node). CODE updates arrive via ht_boot/ht_push
  and never touch that file. Re-run setup any time with:  firmware.lua setup
--]]

local RPM           = 128
local CALIBRATE_RPM = 20     -- `firmware.lua spin <n>` ID speed (entrances need >=16 RPM to open)
local TRIP_TIMEOUT  = 30     -- seconds a trip stays alive (longer: multi-hop with chunk-load delays)
local TRIP_BEAT     = 2      -- s: re-broadcast the active trip so a node that just loaded catches it
local RELAUNCH_HOLD = 3      -- s a junction keeps its exit spinning after catching the rider
local LS_INTERVAL  = 5       -- seconds between link-state broadcasts (steady state)
local GRAPHFILE    = "/ht_graph.dat"  -- durable copy of the network map (survives reboot / chunk unload)
local PROTO        = "hypertube"
local CFG          = "/ht_node.cfg"
local BOARD_RANGE  = 2       -- pad detection: horizontal reach (blocks)
local BOARD_HEIGHT = 3       -- pad detection: vertical reach (blocks) - taller so a rider who lands
                             -- a block high/low is still seen (needs detector's getPlayersInCubic)
local args = { ... }
local VERSION  = "v10"       -- bump on every change; shown on the monitor + printed/logged on boot
local LOGPROTO = "ht_log"    -- live network log channel (the htlog viewer listens here)
local LOGFILE  = "/ht.log"   -- rolling local log on each node (view with: firmware.lua log)

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

local ctrls = findAll(function(_, p) return p.setTargetSpeed ~= nil end)
local det   = findAll(function(_, p) return p.getPlayersInRange ~= nil end)[1]
local detector = det and det.wrap or nil

local mon  -- largest monitor
do
  local best = -1
  for _, m in ipairs(findAll(function(_, p) return p.setTextScale ~= nil end)) do
    local ok, w, h = pcall(m.wrap.getSize)
    if ok and w * h > best then best = w * h; mon = m.wrap end
  end
end

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
-- `secs`. Returns a set {name=true,...} and whether a modem was open to ask with.
local function probeNetwork(secs)
  local known = {}
  if not rednet.isOpen() then return known, false end
  pcall(rednet.broadcast, { type = "LSREQ" }, PROTO)
  local timer = os.startTimer(secs or 2.5)
  while true do
    local e = { os.pullEvent() }
    if e[1] == "rednet_message" and e[4] == PROTO then
      local m = e[3]
      if type(m) == "table" and m.type == "LS" and m.name then known[m.name] = true end
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
      local v = read()
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
  local name = read()
  while not name or name == "" do write("> "); name = read() end
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

  local c = { name = name, links = links, portals = portals }
  saveCfg(c)
  print("Saved. This node is '" .. name .. "'.")
  return c
end

local cfg = loadCfg()
local netUp = openModem()
if args[1] == "log" then          -- print this node's local log and exit
  if fs.exists(LOGFILE) then local f = fs.open(LOGFILE, "r"); print(f.readAll()); f.close()
  else print("(no log yet)") end
  return
end
if args[1] == "reset" then        -- wipe this node's name + calibration + learned map, then reboot
  if fs.exists(CFG) then fs.delete(CFG) end
  if fs.exists(GRAPHFILE) then fs.delete(GRAPHFILE) end
  print("Config cleared - rebooting into fresh setup...")
  sleep(1); os.reboot()
end
if args[1] == "forget" then       -- drop only the learned map (re-learn topology); keep name + links
  if fs.exists(GRAPHFILE) then fs.delete(GRAPHFILE) end
  print("Map cleared - rebooting..."); sleep(1); os.reboot()
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
  pcall(function() local f = fs.open(LOGFILE, "a"); if f then f.writeLine(os.epoch("utc") .. " " .. msg); f.close() end end)
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
-- node's own fresh news always beats a stale gossiped copy) and let everyone
-- forget a node that has gone quiet.
local graph = { [NAME] = myNeighbours() }    -- node -> { neighbour, ... }
local gen   = { [NAME] = os.epoch("utc") }   -- node -> last-refresh epoch (ms)

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
  graph[NAME] = myNeighbours(); gen[NAME] = os.epoch("utc")
  saveGraph()
  local nodes = {}
  for n, nbrs in pairs(graph) do nodes[n] = { nbrs = nbrs, ts = gen[n] or 0 } end
  rednet.broadcast({ type = "STATE", nodes = nodes }, PROTO)
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

local function reachable()      -- sorted list of node names this node can route to
  local seen, cand = {}, {}
  local function add(n) if not seen[n] then seen[n] = true; cand[#cand + 1] = n end end
  for node, nbrs in pairs(graph) do        -- include nodes that announced...
    add(node)
    for _, nb in ipairs(nbrs) do add(nb) end  -- ...and any node named as a neighbour
  end
  local out = {}
  for _, node in ipairs(cand) do
    if node ~= NAME and pathTo(node) then out[#out + 1] = node end
  end
  table.sort(out)
  return out
end

-- ---- gates ---------------------------------------------------------------
local function controllerToward(nb)            -- the wrapped RSC for a tube neighbour, or nil
  for _, c in ipairs(ctrls) do
    if LINKS[c.name] == nb then return c.wrap end
  end
end
local function gateToward(nb)                  -- spin only the tube to nb (nil = stop all)
  for _, c in ipairs(ctrls) do
    pcall(c.wrap.setTargetSpeed, (nb ~= nil and LINKS[c.name] == nb) and RPM or 0)
  end
end
local function allStop() gateToward(nil) end

-- ---- shared trip state ---------------------------------------------------
local active, tripTimer = nil, nil
local relaunchStop = nil                      -- origin auto-close timer (prevents re-catching a bounce)
local function armTimeout() tripTimer = os.startTimer(TRIP_TIMEOUT) end

local function indexIn(path) for i, n in ipairs(path) do if n == NAME then return i end end end

-- set this node's gate for a trip and return a human hint for our screen
local function applyTrip(t)
  local i = indexIn(t.path)
  if not i then allStop(); return nil end      -- we're not on this path
  if i == #t.path then allStop(); return ("Arrived: %s"):format(t.rider or "traveller") end
  local nxt = t.path[i + 1]
  if not controllerToward(nxt) then            -- portal hop: no tube/controller here
    allStop(); return ("Walk through the portal to %s"):format(nxt)
  end
  gateToward(nxt)                              -- open the through-tube and KEEP it open: a 90-deg
                                               -- junction passes the rider, and one who stops at the
                                               -- open mouth is pulled onward too. No detector needed.
  if i == 1 then                               -- origin: auto-close shortly after launch so a rider
    relaunchStop = os.startTimer(RELAUNCH_HOLD) -- who bounces back can't be instantly re-grabbed
    return ("Board -> %s"):format(t.to)
  end
  return ("Pass through -> %s"):format(t.to)
end

-- ---- player presence -----------------------------------------------------
local function firstName(players)
  if type(players) ~= "table" then return nil end
  local p = players[1]
  if type(p) == "table" then return p.name end
  return p
end
local function riderOnPad()
  if not detector then return nil end
  -- Prefer a CUBOID check so the vertical reach can be taller than the horizontal one
  -- (catches a rider who lands a block above/below the pad). Fall back to a plain range.
  if detector.getPlayersInCubic then
    local ok, players = pcall(detector.getPlayersInCubic, BOARD_RANGE, BOARD_HEIGHT, BOARD_RANGE)
    if ok then return firstName(players) end
  end
  local ok, players = pcall(detector.getPlayersInRange, math.max(BOARD_RANGE, BOARD_HEIGHT))
  if ok then return firstName(players) end
end

-- ---- UI ------------------------------------------------------------------
local rowDest, hint = {}, nil
local scroll, navRow, navMid, pageStep = 0, nil, nil, 1   -- destination list scrolling
local function draw(status, color)
  if not mon then return end
  rowDest, navRow = {}, nil
  mon.setBackgroundColor(colors.black); mon.clear()
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.blue); mon.setCursorPos(1, 1); mon.clearLine()
  mon.setTextColor(colors.white); mon.setCursorPos(2, 1); mon.write(NAME:sub(1, w - #VERSION - 2))
  mon.setTextColor(colors.lightGray); mon.setCursorPos(math.max(2, w - #VERSION), 1); mon.write(VERSION)

  local dests = reachable()
  local top, bottom = 2, h - 1                       -- list rows; status sits on row h
  local capacity = math.max(1, bottom - top + 1)
  local paged = #dests > capacity                    -- need a nav row when the list overflows
  pageStep = math.max(1, paged and (capacity - 1) or capacity)
  scroll = math.max(0, math.min(scroll, math.max(0, #dests - pageStep)))

  local y = top
  for idx = scroll + 1, math.min(#dests, scroll + pageStep) do
    local node = dests[idx]
    mon.setCursorPos(1, y)
    mon.setBackgroundColor(active and colors.gray or colors.green)
    mon.setTextColor(colors.white)
    mon.write(((" " .. node) .. string.rep(" ", w)):sub(1, w))
    rowDest[y] = node
    y = y + 1
  end
  if paged then                                      -- nav bar: tap left half = up, right half = down
    navRow, navMid = bottom, math.floor(w / 2)
    mon.setCursorPos(1, navRow)
    mon.setBackgroundColor(scroll > 0 and colors.cyan or colors.gray); mon.setTextColor(colors.white)
    mon.write((" ^ up" .. string.rep(" ", navMid)):sub(1, navMid))
    mon.setBackgroundColor((scroll + pageStep) < #dests and colors.cyan or colors.gray)
    local rw = w - navMid
    mon.write((string.rep(" ", rw) .. "down v "):sub(-rw))
  end
  mon.setBackgroundColor(colors.black); mon.setTextColor(color or colors.lightGray)
  mon.setCursorPos(1, h); mon.write((status or "Tap a destination"):sub(1, w))
end

local function refresh()
  if active then draw(hint or ("Net: " .. (active.rider or "?") .. " -> " .. active.to), colors.orange)
  elseif detector then
    local who = riderOnPad()
    if who then draw("Welcome, " .. who .. " - tap a destination", colors.lime)
    else draw("Step onto the pad to travel", colors.lightGray) end
  else draw() end
end

-- ---- trips ---------------------------------------------------------------
local function clearTrip() active, hint = nil, nil; allStop(); refresh() end

local function startTrip(dest)
  if dest == NAME then return end
  -- debounce accidental double-taps, but DON'T hard-lock: re-tapping re-routes
  if active and (os.epoch("utc") - (active.ts or 0)) < 1500 then return end
  local path = pathTo(dest)
  if not path then draw("No route to " .. dest, colors.red); return end
  local rider = riderOnPad()
  if detector and not rider then draw("Step onto the pad first", colors.orange); return end
  local now = os.epoch("utc")
  local t = { type = "ROUTE", id = now, from = NAME, to = dest, path = path, rider = rider, ts = now }
  rednet.broadcast(t, PROTO)                 -- tell every hop on the path to open its gate FIRST
  log("start -> " .. dest .. " via " .. table.concat(path, ">") .. (rider and (" (" .. rider .. ")") or ""))
  active = t; hint = applyTrip(t); armTimeout(); refresh()   -- launch from our pad; junctions
end                                                          -- catch & relaunch on their own

local function handle(msg)
  if type(msg) ~= "table" then return end
  if msg.type == "STATE" then
    if mergeState(msg.nodes) and not active then refresh() end
  elseif msg.type == "LS" and msg.name then            -- legacy single-node announce (transition)
    graph[msg.name] = msg.neighbours or {}; gen[msg.name] = os.epoch("utc")
    if not active then refresh() end
  elseif msg.type == "LSREQ" then
    broadcastState()
  elseif msg.type == "TRIPREQ" then
    if active then rednet.broadcast(active, PROTO) end    -- relay an in-progress trip to a node that just (re)loaded
  elseif msg.type == "ROUTE" and msg.path then
    -- A node that just loaded picks the trip up here. Only fire our gate the FIRST time we
    -- see a trip id; later re-broadcasts just keep it alive (so the origin gate, already
    -- auto-closed, doesn't re-open and re-grab the rider).
    local same = active and active.id == msg.id
    active = msg; armTimeout()
    if not same then
      hint = applyTrip(msg); refresh()
      if hint then log("route " .. (msg.to or "?") .. " : " .. hint) end
    end
  elseif msg.type == "ARRIVED" then
    log("arrived at " .. (msg.at or "?") .. " - trip done")
    clearTrip()
  end
end

-- ---- boot ----------------------------------------------------------------
setNameLabel()
allStop()
log(("boot firmware %s | tubes=%d detector=%s modem=%s"):format(VERSION, #ctrls, tostring(detector ~= nil), tostring(netUp)))
if not netUp then print("[warn] no modem - this node can't see the network.") end
broadcastState()
rednet.broadcast({ type = "LSREQ" }, PROTO)     -- ask everyone to announce
rednet.broadcast({ type = "TRIPREQ" }, PROTO)   -- on (re)load, catch up on any trip already in progress
local lsTimer   = os.startTimer(LS_INTERVAL)
local padTimer  = os.startTimer(1)
local beatTimer = os.startTimer(TRIP_BEAT)
local warm      = 5                              -- quick extra roll-calls right after
local warmTimer = os.startTimer(0.5)             -- boot so we converge in ~1-2s, not 15s
refresh()

while true do
  local e = { os.pullEvent() }
  local ev = e[1]
  if ev == "monitor_touch" then
    local tx, ty = e[3], e[4]
    if rowDest[ty] then startTrip(rowDest[ty])
    elseif navRow and ty == navRow then              -- tapped the scroll bar
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
        rednet.broadcast({ type = "LSREQ" }, PROTO); broadcastState()
        warmTimer = os.startTimer(0.5)
      end
    elseif e[2] == relaunchStop then
      allStop()   -- close our launch exit so a bounce can't re-grab the rider; keep the trip for relay
    elseif e[2] == beatTimer then
      if active then rednet.broadcast(active, PROTO) end   -- keep relaying so nodes loading mid-route catch it
      beatTimer = os.startTimer(TRIP_BEAT)
    elseif e[2] == tripTimer then clearTrip()
    elseif e[2] == padTimer then
      if active and active.to == NAME and riderOnPad() then
        -- we are the DESTINATION and the rider has landed: confirm arrival
        rednet.broadcast({ type = "ARRIVED", at = NAME, id = active.id }, PROTO)
        clearTrip()
      elseif not active then refresh() end
      padTimer = os.startTimer(1)
    end
  end
end
