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
local TRIP_TIMEOUT  = 30     -- seconds before a stale trip auto-clears
local LS_INTERVAL  = 5       -- seconds between link-state broadcasts (steady state)
local PROTO        = "hypertube"
local CFG          = "/ht_node.cfg"
local BOARD_RANGE  = 2
local args = { ... }

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
if args[1] == "reset" then        -- wipe this node's saved name + calibration, then reboot
  if fs.exists(CFG) then fs.delete(CFG) end
  print("Config cleared - rebooting into fresh setup...")
  sleep(1); os.reboot()
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

-- my neighbour set (tube + portal)
local function myNeighbours()
  local seen, out = {}, {}
  for _, nb in pairs(LINKS) do if not seen[nb] then seen[nb] = true; out[#out + 1] = nb end end
  for _, nb in ipairs(PORTALS) do if not seen[nb] then seen[nb] = true; out[#out + 1] = nb end end
  return out
end

-- ---- network graph (link-state) ------------------------------------------
local graph = { [NAME] = myNeighbours() }   -- node -> { neighbour, ... }

local function setNameLabel() if os.getComputerLabel() ~= NAME then os.setComputerLabel(NAME) end end

local function broadcastLS()
  rednet.broadcast({ type = "LS", name = NAME, neighbours = myNeighbours() }, PROTO)
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
local function armTimeout() tripTimer = os.startTimer(TRIP_TIMEOUT) end

local function indexIn(path) for i, n in ipairs(path) do if n == NAME then return i end end end

-- set this node's gate for a trip and return a human hint for our screen
local function applyTrip(t)
  local i = indexIn(t.path)
  if not i then allStop(); return nil end
  if i == #t.path then allStop(); return ("Arrived: %s"):format(t.rider or "traveller") end
  local nxt = t.path[i + 1]
  gateToward(nxt)                              -- spins nothing if nxt is a portal hop
  if controllerToward(nxt) then
    if i == 1 then return ("Board -> %s"):format(t.to) end
    return ("Pass through -> %s"):format(t.to)
  else
    return ("Walk through the portal to %s"):format(nxt)   -- portal hop
  end
end

-- ---- player presence -----------------------------------------------------
local function riderOnPad()
  if not detector then return nil end
  local ok, players = pcall(detector.getPlayersInRange, BOARD_RANGE)
  if ok and type(players) == "table" then
    local p = players[1]
    if type(p) == "table" then return p.name end
    return p
  end
end

-- ---- UI ------------------------------------------------------------------
local rowDest, hint = {}, nil
local function draw(status, color)
  if not mon then return end
  rowDest = {}
  mon.setBackgroundColor(colors.black); mon.clear()
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.blue); mon.setCursorPos(1, 1); mon.clearLine()
  mon.setTextColor(colors.white); mon.setCursorPos(2, 1); mon.write(NAME)
  local y = 3
  for _, node in ipairs(reachable()) do
    mon.setCursorPos(2, y)
    mon.setBackgroundColor(active and colors.gray or colors.green)
    mon.setTextColor(colors.white)
    local label = " " .. node
    mon.write(label .. string.rep(" ", math.max(0, w - 2 - #label)))
    rowDest[y] = node; rowDest[y + 1] = node
    y = y + 2
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
  if active then refresh(); return end
  if dest == NAME then return end
  local path = pathTo(dest)
  if not path then draw("No route to " .. dest, colors.red); return end
  local rider = riderOnPad()
  if detector and not rider then draw("Step onto the pad first", colors.orange); return end
  local now = os.epoch("utc")
  local t = { type = "ROUTE", id = now, from = NAME, to = dest, path = path, rider = rider, ts = now }
  rednet.broadcast(t, PROTO)
  active = t; hint = applyTrip(t); armTimeout(); refresh()
end

local function handle(msg)
  if type(msg) ~= "table" then return end
  if msg.type == "LS" and msg.name then
    graph[msg.name] = msg.neighbours or {}
    if not active then refresh() end
  elseif msg.type == "LSREQ" then
    broadcastLS()
  elseif msg.type == "ROUTE" and msg.path then
    if active and active.id ~= msg.id then return end   -- single trip at a time
    active = msg; hint = applyTrip(msg); armTimeout(); refresh()
  elseif msg.type == "ARRIVED" then
    clearTrip()
  end
end

-- ---- boot ----------------------------------------------------------------
setNameLabel()
allStop()
if not netUp then print("[warn] no modem - this node can't see the network.") end
broadcastLS()
rednet.broadcast({ type = "LSREQ" }, PROTO)     -- ask everyone to announce
local lsTimer   = os.startTimer(LS_INTERVAL)
local padTimer  = os.startTimer(1)
local warm      = 5                              -- quick extra roll-calls right after
local warmTimer = os.startTimer(0.5)             -- boot so we converge in ~1-2s, not 15s
refresh()

while true do
  local e = { os.pullEvent() }
  local ev = e[1]
  if ev == "monitor_touch" then
    local d = rowDest[e[4]]
    if d then startTrip(d) end
  elseif ev == "rednet_message" then
    if e[4] == PROTO then handle(e[3]) end
  elseif ev == "timer" then
    if e[2] == lsTimer then broadcastLS(); lsTimer = os.startTimer(LS_INTERVAL)
    elseif e[2] == warmTimer then
      if warm > 0 then
        warm = warm - 1
        rednet.broadcast({ type = "LSREQ" }, PROTO); broadcastLS()
        warmTimer = os.startTimer(0.5)
      end
    elseif e[2] == tripTimer then clearTrip()
    elseif e[2] == padTimer then
      -- destination arrival clears the trip; otherwise just refresh the greeting
      if active and active.to == NAME and riderOnPad() then
        rednet.broadcast({ type = "ARRIVED", at = NAME, id = active.id }, PROTO)
        clearTrip()
      elseif not active then refresh() end
      padTimer = os.startTimer(1)
    end
  end
end
