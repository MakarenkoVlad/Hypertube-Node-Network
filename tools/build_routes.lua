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

local USAGE = "usage: lua tools/build_routes.lua <network.lua> [outdir | -]"

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
      if e.relay == nil or e.side == nil then
        warn("node '%s' exit '%s' has no relay/side — generated EXITS gate wiring will be nil", id, ename)
      end
    end
    if n == 0 then
      warn("node '%s' has no exits — it can release arrivals but cannot forward anyone", id)
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

  local routes, unreachable = {}, {}
  for _, nodeId in ipairs(sortedKeys(net.nodes)) do
    local r = {}
    for _, dest in ipairs(stationIds) do
      if dest == nodeId then
        r[dest] = "RELEASE"                 -- a station releases travellers bound for itself
      else
        local hop = nextHop(nodeId, distTo[dest], fwd)
        if hop then
          r[dest] = hop
        else
          unreachable[#unreachable + 1] = { node = nodeId, dest = dest }
        end
      end
    end
    routes[nodeId] = r
  end
  return routes, stationIds, unreachable
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
    local fields = string.format("relay = %s, side = %s, invert = %s",
      e.relay ~= nil and q(e.relay) or "nil",
      e.side ~= nil and q(e.side) or "nil",
      tostring(e.invert and true or false))
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

local function emitNode(net, nodeId, routeMap)
  local node = net.nodes[nodeId]
  local block = { "local STATION = " .. q(nodeId), "" }
  if node.monitor ~= nil then                  -- a terminal needs the destination directory
    block[#block + 1] = emitStations(net.stations)
    block[#block + 1] = ""
  end
  block[#block + 1] = emitExits(node.exits)
  block[#block + 1] = ""
  block[#block + 1] = emitRoutes(routeMap)
  block[#block + 1] = ""
  block[#block + 1] = "local MODEM   = " .. q(node.modem or "top")
  block[#block + 1] = "local MONITOR = " .. (node.monitor ~= nil and q(node.monitor) or "nil")
  block[#block + 1] = "local DETECT  = " .. (node.detect ~= nil and q(node.detect) or "nil")
  return table.concat(block, "\n") .. "\n"
end

local function fileHeader(nodeId, srcPath)
  return table.concat({
    "-- ===========================================================================",
    "-- AUTO-GENERATED — node '" .. nodeId .. "'",
    "-- Source graph: " .. srcPath,
    "-- Generator:    tools/build_routes.lua",
    "-- Paste this block over the CONFIG section at the top of src/hypertube_node.lua",
    "-- on this node's computer. Do not hand-edit — change the graph and regenerate.",
    "-- ===========================================================================",
    "",
  }, "\n")
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
local netPath = args[1]
if netPath == nil then io.stderr:write(USAGE .. "\n"); os.exit(1) end
if netPath == "-h" or netPath == "--help" then print(USAGE); os.exit(0) end
local outdir = args[2] or "config/generated"

local net = loadNetwork(netPath)
validate(net, netPath)
local fwd = forwardEdges(net)
local routes, stationIds, unreachable = computeRoutes(net, fwd)

for _, u in ipairs(unreachable) do
  warn("node '%s' has no route to station '%s' — the graph isn't connected that way", u.node, u.dest)
end

local nodeIds = sortedKeys(net.nodes)
if outdir == "-" then
  for _, n in ipairs(nodeIds) do
    io.write("\n-- ##################### node: " .. n .. " #####################\n\n")
    io.write(emitNode(net, n, routes[n]))
  end
  printMatrix(net, routes, stationIds, io.stderr)   -- keep stdout pure config
else
  os.execute('mkdir -p "' .. outdir .. '"')         -- off-game dev tool: POSIX mkdir is fine
  for _, n in ipairs(nodeIds) do
    local path = outdir .. "/" .. n .. ".lua"
    local f, err = io.open(path, "w")
    if not f then die("cannot write %s: %s", path, tostring(err)) end
    f:write(fileHeader(n, netPath) .. emitNode(net, n, routes[n]))
    f:close()
  end
  io.write(string.format("Wrote %d node config(s) to %s/\n", #nodeIds, outdir))
  printMatrix(net, routes, stationIds, io.stdout)
end
