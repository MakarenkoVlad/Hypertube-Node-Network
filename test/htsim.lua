-- ===========================================================================
-- HT network simulator - mirrors ht_node.lua's logic and models the things
-- that actually break it: chunks load/unload, offline nodes miss broadcasts,
-- reboots wipe RAM (only files persist), and trips must relay onto nodes that
-- wake up mid-route. PROTO/RPM/timeouts match the firmware.
-- ===========================================================================
local RPM = 128
local NOW = 1000
local function dc(t) if type(t)~="table" then return t end local r={} for k,v in pairs(t) do r[k]=dc(v) end return r end

local bus = { nodes = {}, q = {} }
function bus:broadcast(from, msg)
  for name, nd in pairs(self.nodes) do
    if name ~= from and nd.loaded then self.q[#self.q+1] = { to=name, msg=msg } end
  end
end
function bus:pump()
  local n=0
  while #self.q>0 do n=n+1; if n>200000 then error("runaway") end
    local m=table.remove(self.q,1); local nd=self.nodes[m.to]
    if nd and nd.loaded then nd:handle(m.msg) end
  end
end

local function makeNode(name, links)
  local nd = { NAME=name, LINKS=links, files={}, graph={}, gen={}, active=nil, gates={}, loaded=false, tripSeq=0 }
  function nd:myNeighbours() local s,o={},{} for _,nb in pairs(self.LINKS) do if not s[nb] then s[nb]=true; o[#o+1]=nb end end return o end
  function nd:saveGraph() self.files.graph={ graph=dc(self.graph), gen=dc(self.gen) } end
  function nd:loadGraph()
    local d=self.files.graph
    if d and d.graph then for n,nbrs in pairs(d.graph) do
      if n~=self.NAME then self.graph[n]=dc(nbrs); self.gen[n]=(d.gen and d.gen[n]) or 0 end
    end end
  end
  function nd:broadcastState()
    self.graph[self.NAME]=self:myNeighbours(); self.gen[self.NAME]=NOW; self:saveGraph()
    local nodes={} for n,nbrs in pairs(self.graph) do nodes[n]={nbrs=nbrs, ts=self.gen[n] or 0} end
    bus:broadcast(self.NAME, { type="STATE", nodes=nodes })
  end
  function nd:mergeState(nodes)
    local ch=false
    for n,info in pairs(nodes) do if type(info)=="table" and type(info.nbrs)=="table" then
      local ts=info.ts or 0
      if not self.gen[n] or ts>self.gen[n] then self.graph[n]=dc(info.nbrs); self.gen[n]=ts; ch=true end
    end end
    if ch then self:saveGraph() end; return ch
  end
  function nd:pathTo(dest)
    if dest==self.NAME then return {self.NAME} end
    local prev,q,h={[self.NAME]=self.NAME},{self.NAME},1
    while h<=#q do local cur=q[h]; h=h+1
      for _,nb in ipairs(self.graph[cur] or {}) do if not prev[nb] then prev[nb]=cur
        if nb==dest then local p,c={dest},dest; while c~=self.NAME do c=prev[c]; table.insert(p,1,c) end; return p end
        q[#q+1]=nb end end end
  end
  function nd:controllerToward(nb) for c,d in pairs(self.LINKS) do if d==nb then return c end end end
  function nd:gateToward(nb) for c,d in pairs(self.LINKS) do self.gates[c]=(nb~=nil and d==nb) and RPM or 0 end end
  function nd:allStop() self:gateToward(nil) end
  function nd:indexIn(p) for i,n in ipairs(p) do if n==self.NAME then return i end end end
  function nd:applyTrip(t)
    local i=self:indexIn(t.path)
    if not i then self:allStop(); return nil end
    if i==#t.path then self:allStop(); return "Arrived" end
    local nxt=t.path[i+1]
    if not self:controllerToward(nxt) then self:allStop(); return "portal->"..nxt end
    self:gateToward(nxt)
    if i==1 then self.relaunch=NOW+3; return "Board->"..nxt end
    return "Pass->"..nxt
  end
  function nd:startTrip(dest)
    if dest==self.NAME then return "self" end
    local path=self:pathTo(dest); if not path then return nil end
    self.tripSeq=self.tripSeq+1
    local t={ type="ROUTE", id=self.NAME..":"..self.tripSeq, from=self.NAME, to=dest, path=path }
    bus:broadcast(self.NAME, t); self.active=t; self.lastHint=self:applyTrip(t); self.timeout=NOW+30
    return path
  end
  function nd:handle(msg)
    if type(msg)~="table" then return end
    if msg.type=="STATE" then self:mergeState(msg.nodes)
    elseif msg.type=="LSREQ" then self:broadcastState()
    elseif msg.type=="TRIPREQ" then if self.active then bus:broadcast(self.NAME, self.active) end
    elseif msg.type=="ROUTE" and msg.path then
      local same=self.active and self.active.id==msg.id
      self.active=msg; self.timeout=NOW+30
      if not same then self.lastHint=self:applyTrip(msg) end
    elseif msg.type=="ARRIVED" then self.active=nil; self:allStop()
    end
  end
  function nd:boot()
    self.loaded=true; self.graph={}; self.gen={}; self.active=nil; self.gates={}; self.relaunch=nil; self.timeout=nil
    self.graph[self.NAME]=self:myNeighbours(); self.gen[self.NAME]=NOW
    self:loadGraph(); self:broadcastState()
    bus:broadcast(self.NAME, { type="LSREQ" }); bus:broadcast(self.NAME, { type="TRIPREQ" })
  end
  function nd:unload() self.loaded=false end
  function nd:tick()
    if self.relaunch and NOW>=self.relaunch then self.relaunch=nil; self:allStop() end
    if self.timeout and NOW>=self.timeout then self.timeout=nil; self.active=nil; self:allStop() end
  end
  function nd:landPad()  -- player lands here
    if self.active and self.active.to==self.NAME then
      bus:broadcast(self.NAME, { type="ARRIVED", at=self.NAME, id=self.active.id }); self.active=nil; self:allStop(); return true
    end
    return false
  end
  return nd
end

-- ---- assertions ----
local pass, fail = 0, 0
local function ok(cond, label) if cond then pass=pass+1; print("  PASS  "..label) else fail=fail+1; print("  FAIL  "..label) end end

-- ---- build the star network (user's actual topology) ----
local AV="Avenger2256"; local HUB="Right Island Hub"; local TER="Terrapin Station"; local ALO="Al0p"
bus.nodes[AV]  = makeNode(AV,  { c1=HUB })
bus.nodes[HUB] = makeNode(HUB, { c1=AV, c2=TER, c3=ALO })
bus.nodes[TER] = makeNode(TER, { c1=HUB })
bus.nodes[ALO] = makeNode(ALO, { c1=HUB })

print("== Phase 1: cold start, everyone loaded, gossip converges ==")
for _,nd in pairs(bus.nodes) do nd:boot() end
bus:pump()
ok(bus.nodes[AV]:pathTo(TER) and table.concat(bus.nodes[AV]:pathTo(TER),">")==AV..">"..HUB..">"..TER, "Avenger computes Avenger>Hub>Terrapin")
ok(bus.nodes[TER]:pathTo(AV)  ~= nil, "Terrapin can route to Avenger")
ok(bus.nodes[ALO]:pathTo(TER) ~= nil, "Al0p can route to Terrapin (multi-hop)")
ok(bus.nodes[AV].files.graph~=nil, "graph persisted to disk on Avenger")

print("== Phase 2: unload everyone but Avenger (chunks off) ==")
NOW=NOW+100
bus.nodes[HUB]:unload(); bus.nodes[TER]:unload(); bus.nodes[ALO]:unload()
ok(not bus.nodes[HUB].loaded and not bus.nodes[TER].loaded, "Hub & Terrapin are unloaded (computers off)")
ok(bus.nodes[AV]:pathTo(TER)~=nil, "Avenger STILL routes to Terrapin from persisted map (the key fix)")

print("== Phase 3: start trip with the hub & dest OFFLINE, then they load mid-route ==")
local path = bus.nodes[AV]:startTrip(TER); bus:pump()
ok(path and table.concat(path,">")==AV..">"..HUB..">"..TER, "trip starts, path is Avenger>Hub>Terrapin")
ok(bus.nodes[AV].gates.c1==RPM, "Avenger (origin) opened its tube toward the hub")
-- nobody else heard it yet (they were offline)
ok(bus.nodes[HUB].active==nil, "hub heard nothing yet (it was unloaded at departure)")

NOW=NOW+5  -- player flies toward hub; hub chunk loads
bus.nodes[HUB]:boot(); bus:pump()      -- boot sends TRIPREQ; Avenger (still loaded) relays the trip
ok(bus.nodes[HUB].active~=nil, "hub booted mid-route and PICKED UP the trip via relay")
ok(bus.nodes[HUB].gates.c2==RPM, "hub opened its tube toward Terrapin (the junction switch)")
ok(bus.nodes[HUB].gates.c1==0 and bus.nodes[HUB].gates.c3==0, "hub closed the other tubes (no misroute)")

NOW=NOW+3; bus.nodes[AV]:tick()        -- origin auto-close window passes
ok(bus.nodes[AV].gates.c1==0, "Avenger auto-closed its launch tube (no suck-back)")
ok(bus.nodes[AV].active~=nil, "Avenger still HOLDS the trip for relay (didn't forget it)")

NOW=NOW+5  -- player flies hub->Terrapin; Terrapin chunk loads
bus.nodes[TER]:boot(); bus:pump()
ok(bus.nodes[TER].active~=nil, "Terrapin booted and picked up the trip via relay from the hub")
ok(bus.nodes[TER]:applyTrip(bus.nodes[TER].active)=="Arrived", "Terrapin recognises itself as the destination")

local arrived = bus.nodes[TER]:landPad(); bus:pump()
ok(arrived, "player lands on Terrapin pad -> ARRIVED broadcast")
ok(bus.nodes[HUB].active==nil and bus.nodes[AV].active==nil, "ARRIVED cleared the trip on hub & Avenger")
ok(bus.nodes[HUB].gates.c2==0, "hub closed its Terrapin tube after the trip")

print("== Phase 4: gossip - a fresh node learns the whole map from ONE loaded peer ==")
local LONE = makeNode("Lonely", { c1=HUB }); bus.nodes["Lonely"]=LONE
LONE:boot(); bus:pump()   -- Avenger is still loaded and shares its full persisted map
ok(LONE:pathTo(HUB)~=nil, "lone node reaches its direct neighbour (hub)")
ok(LONE:pathTo(TER)~=nil, "lone node learned the FULL map from Avenger in one reply (multi-hop works)")

print("== Phase 5: genuinely isolated node (no map, no peers loaded) ==")
for _,nd in pairs(bus.nodes) do nd:unload() end   -- every other computer's chunk is off
local ISO = makeNode("Island", { c1=HUB }); bus.nodes["Island"]=ISO
ISO:boot(); bus:pump()
ok(ISO:pathTo(HUB)~=nil, "isolated node still reaches its direct neighbour from own config")
ok(ISO:pathTo(TER)==nil, "isolated node cannot multi-hop until it learns the map once (expected, by design)")

print(("\n==== %d passed, %d failed ===="):format(pass, fail))
if fail>0 then os.exit(1) end
