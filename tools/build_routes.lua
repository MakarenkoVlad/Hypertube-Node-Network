#!/usr/bin/env lua
--[[
  build_routes.lua — auto-generate per-node EXITS + ROUTES from one network graph.
  ===========================================================================
  Describe the whole network ONCE as a graph (see config/network.example.lua),
  then run this to emit each computer's config block. It computes every node's
  ROUTES by shortest path over the graph, so you never hand-write a routing
  table again. A junction stays "just a node with 2+ exits": the generator
  simply discovers that different destinations leave by different exits.

  This is an OFF-GAME build step — run it with the `lua` on your dev machine,
  NOT on an in-game computer. It is the only file here that is not CC: Tweaked
  firmware, so it uses standard Lua io/os. The blocks it emits are the SAME
  EXITS/ROUTES runtime format src/hypertube_node.lua already consumes, so any
  hand-written config keeps working unchanged.

  Usage:
    lua tools/build_routes.lua <network.lua> [outdir]
      <network.lua>  the graph description (a file that `return`s a table)
      [outdir]       where to write <node>.lua files  (default: config/generated)
                     pass "-" to print the blocks to stdout instead

  Examples:
    lua tools/build_routes.lua config/network.example.lua
    lua tools/build_routes.lua config/network.example.lua -

  Output: one <node>.lua per computer, each holding the STATION / STATIONS /
  EXITS / ROUTES / MODEM / MONITOR / DETECT block to paste into the top of
  src/hypertube_node.lua on that node. A routing matrix is printed for review.
--]]

local args = { ... }

local USAGE = [[usage: lua tools/build_routes.lua <network.lua> [outdir | -] [options]
  <network.lua>       network graph (a file that `return`s { stations, nodes })
  [outdir]            where to write <node>.lua config blocks (default: config/generated)
  -                   print config blocks to stdout instead of writing files
options:
  --startup           also emit ready-to-run <node>.startup.lua (firmware + config spliced)
  --firmware <path>   firmware template for --startup (default: src/hypertube_node.lua)]]

local START_MARK, END_MARK = "@HT-CONFIG-START", "@HT-CONFIG-END"

-- ---- tiny helpers --------------------------------------------------------
local function die(fmt, ...)
  io.stderr:write("build_routes: " .. string.format(fmt, ...) .. "\n")
  os.exit(1)
end

local function warn(fmt, ...)
  io.stderr:write("build_routes: warning: " .. string.format(fmt, ...) .. "\n")
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

local function q(s) return string.format("%q", s) end

-- a Lua table key: bare identifier when possible, else ["quoted"]
local function key(k)
  if type(k) == "string" and k:match("^[%a_][%w_]*$") then return k end
  return "[" .. q(k) .. "]"
end

-- ---- load + validate the network -----------------------------------------
local function loadNetwork(path)
  local chunk, err = loadfile(path)
  if not chunk then die("cannot load %s: %s", path, err) end
  local ok, net = pcall(chunk)
  if not ok then die("error running %s: %s", path, tostring(net)) end
  if type(net) ~= "table" then
    die("%s must `return { stations = {...}, nodes = {...} }`", path)
  end
  return net
end

local function validate(net, path)
  if type(net.stations) ~= "table" or #net.stations == 0 then
    die("%s: `stations` must be a non-empty list of { id =, name = }", path)
  end
  if type(net.nodes) ~= "table" then
    die("%s: `nodes` must be a table of node-id -> { exits = {...} }", path)
  end

  local seen = {}
  for i, s in ipairs(net.stations) do
    if type(s) ~= "table" or type(s.id) ~= "string" then
      die("stations[%d] needs a string `id`", i)
    end
    if seen[s.id] then die("duplicate station id '%s'", s.id) end
    seen[s.id] = true
    if not net.nodes[s.id] then
      die("station '%s' has no matching node in `nodes` (every station is a computer)", s.id)
    end
  end

  for id, node in pairs(net.nodes) do
    if type(node) ~= "table" then die("node '%s' must be a table", id) end
    node.exits = node.exits or {}
    if type(node.exits) ~= "table" then die("node '%s': `exits` must be a table", id) end
    local n = 0
    for ename, e in pairs(node.exits) do
      n = n + 1
      if type(e) ~= "table" then die("node '%s' exit '%s' must be a table", id, ename) end
      if type(e.to) ~= "string" then
        die("node '%s' exit '%s' needs `to = <neighbour node id>`", id, ename)
      end
      if not net.nodes[e.to] then
        die("node '%s' exit '%s' points at undefined node '%s'", id, ename, e.to)
      end
      if e.to == id then
        warn("node '%s' exit '%s' loops back to itself — it will never be a shortest hop", id, ename)
      end
      if e.controller == nil and (e.relay == nil or e.side == nil) then
        warn("node '%s' exit '%s' has no gate — set `controller` (RSC) or `relay`+`side`", id, ename)
      end
    end
    if n == 0 then
      warn("node '%s' has no exits — it can release arrivals but cannot forward anyone", id)
    end
  end
end

-- ---- links: declare a connection ONCE, get both directions ---------------
-- A `links` entry becomes an exit at A toward B AND an exit at B toward A, so a
-- tube is never half-wired. Each end's gate is either a Create speed controller
-- ({a,b}_controller + optional {a,b}_rpm) or a redstone relay ({a,b}_relay,
-- {a,b}_side, invert). Adding a station = its node + one link per tube.
local function expandLinks(net)
  if net.links == nil then return end
  if type(net.links) ~= "table" then die("`links` must be a list of { a=, b=, ... }") end
  net.nodes = net.nodes or {}
  for i, lk in ipairs(net.links) do
    if type(lk.a) ~= "string" or type(lk.b) ~= "string" then
      die("links[%d] needs string `a` and `b` node ids", i)
    end
    local a, b = lk.a, lk.b
    net.nodes[a] = net.nodes[a] or {}; net.nodes[a].exits = net.nodes[a].exits or {}
    net.nodes[b] = net.nodes[b] or {}; net.nodes[b].exits = net.nodes[b].exits or {}
    local function inv(over) if over ~= nil then return over end
      if lk.invert ~= nil then return lk.invert end return true end
    -- one end's gate: controller-style (Create RSC) if a controller is given, else relay
    local function gate(to, ctrl, rpm, rel, side, ovr)
      if ctrl then return { to = to, controller = ctrl, rpm = rpm or lk.rpm or 32 } end
      return { to = to, relay = rel, side = side, invert = inv(ovr) }
    end
    local an, bn = "to_" .. b, "to_" .. a
    if not net.nodes[a].exits[an] then
      net.nodes[a].exits[an] = gate(b, lk.a_controller, lk.a_rpm, lk.a_relay, lk.a_side, lk.a_invert)
    end
    if not net.nodes[b].exits[bn] then
      net.nodes[b].exits[bn] = gate(a, lk.b_controller, lk.b_rpm, lk.b_relay, lk.b_side, lk.b_invert)
    end
  end
end

-- ---- audit: catch half-wired or disconnected networks --------------------
local function audit(net, fwd)
  local has = {}
  for a, edges in pairs(fwd) do
    for _, e in ipairs(edges) do has[a .. ">" .. e.to] = true end
  end
  for a, edges in pairs(fwd) do
    for _, e in ipairs(edges) do
      if not has[e.to .. ">" .. a] then
        warn("one-way tube: '%s' -> '%s' has no return exit (a real tube is two-way)", a, e.to)
      end
    end
  end
  if net.stations[1] then
    local start = net.stations[1].id
    local seen, queue, head = { [start] = true }, { start }, 1
    while head <= #queue do
      local cur = queue[head]; head = head + 1
      for _, e in ipairs(fwd[cur] or {}) do
        if not seen[e.to] then seen[e.to] = true; queue[#queue + 1] = e.to end
      end
    end
    for _, s in ipairs(net.stations) do
      if not seen[s.id] then
        warn("station '%s' is not reachable from '%s' — check the connections", s.id, start)
      end
    end
  end
end

-- ---- graph + shortest-path routing ---------------------------------------
-- forward edges per node, sorted by exit name for determinism
local function forwardEdges(net)
  local fwd = {}
  for id, node in pairs(net.nodes) do
    local edges = {}
    for _, ename in ipairs(sortedKeys(node.exits)) do
      edges[#edges + 1] = { exit = ename, to = node.exits[ename].to }
    end
    fwd[id] = edges
  end
  return fwd
end

-- BFS over REVERSED edges from `dest`: dist[node] = min hops node -> dest.
local function distancesTo(dest, fwd)
  local dist = { [dest] = 0 }
  local queue = { dest }
  local head = 1
  while head <= #queue do
    local cur = queue[head]; head = head + 1
    local d = dist[cur]
    for n, edges in pairs(fwd) do          -- find every predecessor n with n -> cur
      if dist[n] == nil then
        for _, e in ipairs(edges) do
          if e.to == cur then
            dist[n] = d + 1
            queue[#queue + 1] = n
            break
          end
        end
      end
    end
  end
  return dist
end

-- the exit of `n` that starts a shortest path to a destination with these
-- distances; ties broken by exit name (alphabetical) for stable output.
local function nextHop(n, dist, fwd)
  if dist[n] == nil then return nil end
  local best
  for _, e in ipairs(fwd[n] or {}) do
    local dm = dist[e.to]
    if dm ~= nil and dm + 1 == dist[n] then
      if best == nil or e.exit < best then best = e.exit end
    end
  end
  return best
end

local function computeRoutes(net, fwd)
  local stationIds = {}
  for _, s in ipairs(net.stations) do stationIds[#stationIds + 1] = s.id end

  local distTo = {}
  for _, d in ipairs(stationIds) do distTo[d] = distancesTo(d, fwd) end

  local routes, paths, unreachable = {}, {}, {}
  for _, nodeId in ipairs(sortedKeys(net.nodes)) do
    local r, p = {}, {}
    for _, dest in ipairs(stationIds) do
      if dest == nodeId then
        r[dest] = "RELEASE"                 -- a station releases travellers bound for itself
      else
        local hop = nextHop(nodeId, distTo[dest], fwd)
        if hop then
          r[dest] = hop
          -- walk the shortest path nodeId..dest (for off-path gate confinement)
          local route, cur, guard = { nodeId }, nodeId, 0
          while cur ~= dest and guard < 1024 do
            guard = guard + 1
            local h = nextHop(cur, distTo[dest], fwd)
            if not h then break end
            local nb = net.nodes[cur].exits[h].to
            route[#route + 1] = nb
            cur = nb
          end
          if cur == dest then p[dest] = route end
        else
          unreachable[#unreachable + 1] = { node = nodeId, dest = dest }
        end
      end
    end
    routes[nodeId] = r
    paths[nodeId] = p
  end
  return routes, stationIds, unreachable, paths
end

-- ---- emit the per-node config block --------------------------------------
local function emitStations(stations)
  local idw, nmw = 0, 0
  for _, s in ipairs(stations) do
    idw = math.max(idw, #(q(s.id) .. ","))
    nmw = math.max(nmw, #q(s.name))
  end
  local out = { "local STATIONS = {" }
  for _, s in ipairs(stations) do
    out[#out + 1] = string.format("  { id = %-" .. idw .. "s name = %-" .. nmw .. "s },",
      q(s.id) .. ",", q(s.name))
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n")
end

local function emitExits(exits)
  local names = sortedKeys(exits)
  if #names == 0 then return "local EXITS = {}" end
  local rk, kw = {}, 0
  for _, name in ipairs(names) do rk[name] = key(name); kw = math.max(kw, #rk[name]) end
  local out = { "local EXITS = {" }
  for _, name in ipairs(names) do
    local e = exits[name]
    local fields
    if e.controller ~= nil then
      fields = string.format("controller = %s, rpm = %s", q(e.controller), tostring(e.rpm or 32))
    else
      fields = string.format("relay = %s, side = %s, invert = %s",
        e.relay ~= nil and q(e.relay) or "nil",
        e.side ~= nil and q(e.side) or "nil",
        tostring(e.invert and true or false))
    end
    out[#out + 1] = string.format("  %-" .. kw .. "s = { %s },", rk[name], fields)
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n")
end

local function emitRoutes(routeMap)
  local dests = sortedKeys(routeMap)
  local rk, kw = {}, 0
  for _, d in ipairs(dests) do rk[d] = key(d); kw = math.max(kw, #rk[d]) end
  local out = { "local ROUTES = {" }
  for _, d in ipairs(dests) do
    local v = routeMap[d]
    local comment = (v == "RELEASE") and "   -- arrive here" or ""
    out[#out + 1] = string.format("  %-" .. kw .. "s = %s,%s", rk[d], q(v), comment)
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n")
end

local function emitPaths(pathMap)
  local dests = sortedKeys(pathMap)
  if #dests == 0 then return "local PATHS = {}" end
  local rk, kw = {}, 0
  for _, d in ipairs(dests) do rk[d] = key(d); kw = math.max(kw, #rk[d]) end
  local out = { "local PATHS = {" }
  for _, d in ipairs(dests) do
    local ids = {}
    for _, nid in ipairs(pathMap[d]) do ids[#ids + 1] = q(nid) end
    out[#out + 1] = string.format("  %-" .. kw .. "s = { %s },", rk[d], table.concat(ids, ", "))
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n")
end

local function emitNode(net, nodeId, routeMap, pathMap)
  local node = net.nodes[nodeId]
  local block = { "local STATION = " .. q(nodeId), "" }
  -- STATIONS is emitted for EVERY node: the firmware references it unconditionally
  -- (nameById), and a generated block replaces the whole config region, so it must
  -- be self-contained. Terminals show it on screen; a headless junction just carries
  -- the directory harmlessly.
  block[#block + 1] = emitStations(net.stations)
  block[#block + 1] = ""
  block[#block + 1] = emitExits(node.exits)
  block[#block + 1] = ""
  block[#block + 1] = emitRoutes(routeMap)
  block[#block + 1] = ""
  block[#block + 1] = emitPaths(pathMap or {})
  block[#block + 1] = ""
  block[#block + 1] = "local MODEM   = " .. q(node.modem or "top")
  block[#block + 1] = "local MONITOR = " .. (node.monitor ~= nil and q(node.monitor) or "nil")
  block[#block + 1] = "local DETECT  = " .. (node.detect ~= nil and q(node.detect) or "nil")
  block[#block + 1] = "local PAD_DETECTOR = " .. (node.pad_detector ~= nil and q(node.pad_detector) or "nil")
  block[#block + 1] = "local BOARD_RANGE  = " .. tostring(node.board_range or 2)
  return table.concat(block, "\n") .. "\n"
end

local function fileHeader(nodeId, srcPath)
  return table.concat({
    "-- ===========================================================================",
    "-- AUTO-GENERATED — config for node '" .. nodeId .. "'",
    "-- Source graph: " .. srcPath .. "   (regenerate with tools/build_routes.lua)",
    "-- Don't hand-edit — change the graph, rebuild, and redeploy (src/install.lua).",
    "-- ===========================================================================",
    "",
  }, "\n")
end

-- ---- firmware splicing (for --startup) -----------------------------------
local function splitLines(s)
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  return lines
end

local function readFile(path)
  local f, err = io.open(path, "r")
  if not f then die("cannot read %s: %s", path, tostring(err)) end
  local data = f:read("*a"); f:close()
  return data
end

-- replace everything between the firmware's @HT-CONFIG markers with `block`,
-- keeping the marker lines themselves. Identical algorithm to src/install.lua.
local function splice(firmware, block, label)
  local lines = splitLines(firmware)
  local s, e
  for i, line in ipairs(lines) do
    if not s and line:find(START_MARK, 1, true) then s = i end
    if not e and line:find(END_MARK, 1, true) then e = i end
  end
  if not s or not e or s >= e then
    die("%s has no usable %s / %s markers (need start before end)",
      label or "firmware", START_MARK, END_MARK)
  end
  local out = {}
  for i = 1, s do out[#out + 1] = lines[i] end             -- up to & incl. START marker
  for _, bl in ipairs(splitLines(block)) do out[#out + 1] = bl end
  for i = e, #lines do out[#out + 1] = lines[i] end         -- END marker onward
  return table.concat(out, "\n")
end

-- ---- routing matrix (human review) ---------------------------------------
local function printMatrix(net, routes, stationIds, out)
  local nodeIds = sortedKeys(net.nodes)
  local labelw = #"NODE"
  for _, n in ipairs(nodeIds) do labelw = math.max(labelw, #n) end
  local colw = {}
  for _, d in ipairs(stationIds) do
    colw[d] = #d
    for _, n in ipairs(nodeIds) do colw[d] = math.max(colw[d], #(routes[n][d] or "-")) end
  end

  local function row(label, cells)
    local parts = { string.format("%-" .. labelw .. "s", label) }
    for _, d in ipairs(stationIds) do
      parts[#parts + 1] = string.format("%-" .. colw[d] .. "s", cells[d] or "-")
    end
    return table.concat(parts, "  ")
  end

  local head = {}
  for _, d in ipairs(stationIds) do head[d] = d end
  out:write("\nRouting matrix  (cell = exit toward that destination; RELEASE = arrive; - = no route)\n\n")
  out:write(row("NODE", head) .. "\n")
  for _, n in ipairs(nodeIds) do out:write(row(n, routes[n]) .. "\n") end
  out:write("\n")
end

-- ---- main ----------------------------------------------------------------
-- positional: <network.lua> [outdir|-];  flags: --startup, --firmware <path>
local netPath, outdir, wantStartup, firmwarePath
do
  local positionals, i = {}, 1
  while i <= #args do
    local a = args[i]
    if a == "-h" or a == "--help" then print(USAGE); os.exit(0)
    elseif a == "--startup" then wantStartup = true
    elseif a == "--firmware" then i = i + 1; firmwarePath = args[i]
    elseif a:sub(1, 2) == "--" then die("unknown option '%s'\n%s", a, USAGE)
    else positionals[#positionals + 1] = a end
    i = i + 1
  end
  netPath = positionals[1]
  outdir = positionals[2] or "config/generated"
end
if netPath == nil then io.stderr:write(USAGE .. "\n"); os.exit(1) end
firmwarePath = firmwarePath or "src/hypertube_node.lua"
if wantStartup and outdir == "-" then
  die("--startup writes files; pass a real outdir, not '-'")
end

local net = loadNetwork(netPath)
expandLinks(net)                       -- turn `links` into reciprocal exits first
validate(net, netPath)
local fwd = forwardEdges(net)
audit(net, fwd)                        -- warn on one-way tubes / unreachable stations
local routes, stationIds, unreachable, paths = computeRoutes(net, fwd)

for _, u in ipairs(unreachable) do
  warn("node '%s' has no route to station '%s' — the graph isn't connected that way", u.node, u.dest)
end

local firmware = wantStartup and readFile(firmwarePath) or nil
local nodeIds = sortedKeys(net.nodes)

if outdir == "-" then
  for _, n in ipairs(nodeIds) do
    io.write("\n-- ##################### node: " .. n .. " #####################\n\n")
    io.write(emitNode(net, n, routes[n], paths[n]))
  end
  printMatrix(net, routes, stationIds, io.stderr)   -- keep stdout pure config
else
  os.execute('mkdir -p "' .. outdir .. '"')         -- off-game dev tool: POSIX mkdir is fine
  local function write(path, content)
    local f, err = io.open(path, "w")
    if not f then die("cannot write %s: %s", path, tostring(err)) end
    f:write(content); f:close()
  end
  for _, n in ipairs(nodeIds) do
    local block = fileHeader(n, netPath) .. emitNode(net, n, routes[n], paths[n])
    write(outdir .. "/" .. n .. ".lua", block)
    if wantStartup then
      -- splice the SAME block install.lua reads from <node>.lua, so both agree
      write(outdir .. "/" .. n .. ".startup.lua", splice(firmware, block, firmwarePath))
    end
  end
  io.write(string.format("Wrote %d node config(s)%s to %s/\n",
    #nodeIds, wantStartup and " + startup files" or "", outdir))
  printMatrix(net, routes, stationIds, io.stdout)
end
