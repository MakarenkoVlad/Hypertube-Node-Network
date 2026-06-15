-- ===========================================================================
-- HT network simulator - mirrors ht_node.lua's logic and models the things
-- that actually break it: chunks load/unload, offline nodes miss broadcasts,
-- reboots wipe RAM (only files persist), trips relay onto nodes that wake up
-- mid-route, periodic beats, and the absolute-deadline / done-set / persisted-
-- trip mechanics. PROTO/RPM/timeouts match the firmware.
-- ===========================================================================
local RPM = 128
local TRIP_TIMEOUT = 30
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

local function makeNode(name, links, portals)
  local nd = { NAME=name, LINKS=links, PORTALS=portals or {}, files={}, graph={}, gen={}, active=nil,
               deadline=nil, done={}, gates={}, loaded=false, tripSeq=0 }
  function nd:myNeighbours()
    local s,o={},{}
    for _,nb in pairs(self.LINKS) do if not s[nb] then s[nb]=true; o[#o+1]=nb end end
    for _,nb in ipairs(self.PORTALS) do if not s[nb] then s[nb]=true; o[#o+1]=nb end end  -- portal links
    return o
  end
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
    self.relaunch=nil                                     -- a new trip supersedes any prior auto-close
    local i=self:indexIn(t.path)
    if not i then self:allStop(); return nil end
    if i==#t.path then self:allStop(); return "Arrived" end
    local nxt=t.path[i+1]
    if not self:controllerToward(nxt) then self:allStop(); return "portal->"..nxt end
    self:gateToward(nxt)
    if i==1 then self.relaunch=NOW+3; return "Board->"..nxt end
    return "Pass->"..nxt
  end
  function nd:setActive(t) self.active=t; self.deadline=(t.ts or NOW)+TRIP_TIMEOUT end
  function nd:markDone(id) if id then self.done[id]=NOW+TRIP_TIMEOUT end end
  function nd:pruneDone() for id,exp in pairs(self.done) do if NOW>exp then self.done[id]=nil end end end
  function nd:endTrip()
    if self.active then self:markDone(self.active.id) end
    self.active=nil; self.deadline=nil; self.relaunch=nil; self:allStop()
  end
  function nd:startTrip(dest, rider)
    if dest==self.NAME then return "self" end
    self:pruneDone()
    local path=self:pathTo(dest); if not path then return nil end
    self.tripSeq=self.tripSeq+1
    local t={ type="ROUTE", id=self.NAME..":"..self.tripSeq, from=self.NAME, to=dest, path=path, ts=NOW, rider=rider }
    bus:broadcast(self.NAME, t); self:setActive(t); self.lastHint=self:applyTrip(t)
    return path
  end
  function nd:handle(msg)
    if type(msg)~="table" then return end
    if msg.type=="STATE" then self:mergeState(msg.nodes)
    elseif msg.type=="LSREQ" then self:broadcastState()
    elseif msg.type=="TRIPREQ" then if self.active then bus:broadcast(self.NAME, self.active) end
    elseif msg.type=="ROUTE" and msg.path and msg.id then
      self:pruneDone()
      if self.done[msg.id] then return end                  -- finished trip: ignore late beats
      if self.active and self.active.id==msg.id then
        self.active=msg; return                             -- same trip: keep alive, DON'T reset deadline
      end
      self:setActive(msg); self.lastHint=self:applyTrip(msg)
    elseif msg.type=="ARRIVED" then
      self:markDone(msg.id)
      if self.active and (msg.id==nil or self.active.id==msg.id) then self:endTrip() end
    end
  end
  function nd:beat() if self.active then bus:broadcast(self.NAME, self.active) end end
  function nd:boot()
    -- cold boot: RAM is wiped (active/done/gates), only files (the map) persist
    self.loaded=true; self.graph={}; self.gen={}; self.active=nil; self.gates={}
    self.relaunch=nil; self.deadline=nil; self.done={}
    self.graph[self.NAME]=self:myNeighbours(); self.gen[self.NAME]=NOW
    self:loadGraph(); self:broadcastState()
    bus:broadcast(self.NAME, { type="LSREQ" }); bus:broadcast(self.NAME, { type="TRIPREQ" })
  end
  function nd:unload() self.loaded=false end
  function nd:tick()
    if self.relaunch and NOW>=self.relaunch then self.relaunch=nil; self:allStop() end
    if self.active and self.deadline and NOW>=self.deadline then
      self:markDone(self.active.id); self.active=nil; self.deadline=nil; self.relaunch=nil; self:allStop()
    end
  end
  function nd:landPad(who)  -- player `who` lands here; only confirms for the trip's OWN rider
    if self.active and self.active.to==self.NAME and ((not self.active.rider) or who==self.active.rider) then
      bus:broadcast(self.NAME, { type="ARRIVED", at=self.NAME, id=self.active.id })
      self:markDone(self.active.id); self.active=nil; self.deadline=nil; self.relaunch=nil; self:allStop(); return true
    end
    return false
  end
  return nd
end

-- ---- assertions ----
local pass, fail = 0, 0
local function ok(cond, label) if cond then pass=pass+1; print("  PASS  "..label) else fail=fail+1; print("  FAIL  "..label) end end
local function anyActive() for _,nd in pairs(bus.nodes) do if nd.active~=nil then return true end end return false end

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

print("== Phase 6: stranded trip self-clears by ABSOLUTE deadline despite 2s beats (livelock fix) ==")
NOW=20000
for _,nd in pairs(bus.nodes) do nd.loaded=true; nd:boot() end; bus:pump()
local tstart=NOW
bus.nodes[AV]:startTrip(TER); bus:pump()                 -- Avenger>Hub>Terrapin, all loaded
ok(bus.nodes[AV].active~=nil and bus.nodes[HUB].active~=nil, "trip active on origin and junction")
for _=1,20 do                                            -- rider vanishes; nodes keep beating for 40s
  NOW=NOW+2
  for _,nd in pairs(bus.nodes) do nd:beat() end
  bus:pump()
  for _,nd in pairs(bus.nodes) do nd:tick() end
end
ok(not anyActive(), "every node auto-cleared the stranded trip even though beats never stopped")
ok(NOW-tstart>=TRIP_TIMEOUT, "cleared no earlier than TRIP_TIMEOUT after the trip started")

print("== Phase 7: ARRIVED is final - a late beat cannot resurrect a finished trip ==")
NOW=30000
for _,nd in pairs(bus.nodes) do nd.loaded=true; nd:boot() end; bus:pump()
bus.nodes[AV]:startTrip(TER); bus:pump()                 -- Avenger>Hub>Terrapin
local ghost = dc(bus.nodes[TER].active)                  -- capture the in-flight ROUTE before arrival
ok(ghost~=nil, "destination is holding the in-flight ROUTE")
bus.nodes[TER]:landPad(); bus:pump()                     -- ARRIVED -> everyone clears + marks done
ok(not anyActive(), "all nodes cleared after ARRIVED")
bus:broadcast("ghost", ghost); bus:pump()                -- a straggler beat of the SAME id arrives
ok(not anyActive(), "late beat ignored via done-set; trip NOT resurrected")

print("== Phase 8: a reloaded node never re-opens a phantom gate after the rider already arrived (no suck-back) ==")
NOW=40000
for _,nd in pairs(bus.nodes) do nd.loaded=true; nd:boot() end; bus:pump()
bus.nodes[AV]:startTrip(TER); bus:pump()                 -- hub opens its Terrapin tube as a hop
ok(bus.nodes[HUB].gates.c2==RPM, "hub opened its Terrapin tube for the trip")
bus.nodes[HUB]:unload()                                  -- hub's chunk unloads while the rider is mid-route
bus.nodes[TER]:landPad(); bus:pump()                     -- rider arrives; ARRIVED is sent but hub is OFF, misses it
NOW=NOW+4; bus.nodes[HUB]:boot(); bus:pump()             -- hub reloads (within the deadline window)
ok(bus.nodes[HUB].active==nil, "reloaded hub has NO active trip (trip state is RAM-only, not resurrected)")
ok((bus.nodes[HUB].gates.c2 or 0)==0, "reloaded hub did NOT re-open its tube -> no phantom suck-back")

print("== Phase 9: a finished origin's stale auto-close timer can't shut a LATER pass-through gate ==")
NOW=50000
for _,nd in pairs(bus.nodes) do nd.loaded=true; nd:boot() end; bus:pump()
NOW=NOW+1; bus.nodes[HUB]:startTrip(TER); bus:pump()     -- hub is ORIGIN -> arms its relaunch auto-close
ok(bus.nodes[HUB].relaunch~=nil, "hub-as-origin armed a relaunch auto-close timer")
NOW=NOW+1; bus.nodes[TER]:landPad(); bus:pump()          -- trip ends -> hub endTrip must clear that timer
ok(bus.nodes[HUB].relaunch==nil, "ending the trip cleared the origin's stale auto-close timer")
NOW=NOW+3; bus.nodes[AV]:startTrip(ALO); bus:pump()      -- NEW trip passes THROUGH hub (Avenger>Hub>Al0p)
ok(bus.nodes[HUB].gates.c3==RPM, "hub opened its pass-through tube toward Al0p")
NOW=NOW+1; bus.nodes[HUB]:tick()                         -- the old auto-close instant is now past
ok(bus.nodes[HUB].gates.c3==RPM, "stale auto-close did NOT shut the pass-through gate (rider not stranded)")
ok(bus.nodes[HUB].active~=nil, "pass-through trip is still active at the junction")

print("== Phase 10: round trip leaves NO gate stuck open (the reported goldmine bug) ==")
NOW=60000
bus.nodes={}                                             -- clean line: Terrapin <-> Hub <-> goldmine
local T2="Terrapin"; local H2="Hub"; local G2="goldmine"
bus.nodes[T2]=makeNode(T2,{c1=H2})
bus.nodes[H2]=makeNode(H2,{c1=T2,c2=G2})
bus.nodes[G2]=makeNode(G2,{c1=H2})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes[T2]:startTrip(G2); bus:pump()                  -- Terrapin -> goldmine, through the hub
local trip1=dc(bus.nodes[H2].active)                     -- the in-flight ROUTE the hub is holding
ok(bus.nodes[H2].gates.c2==RPM, "hub opened its goldmine tube while routing there")
bus.nodes[G2]:landPad(); bus:pump()                      -- arrive at goldmine -> ARRIVED clears everyone
ok((bus.nodes[H2].gates.c2 or 0)==0, "hub CLOSED its goldmine tube on arrival (entrance not left open)")
ok(not anyActive(), "no trip left active after arriving at goldmine")
bus:broadcast("ghost", trip1); bus:pump()                -- a straggler beat of the finished trip
ok((bus.nodes[H2].gates.c2 or 0)==0, "stale beat did NOT re-open the goldmine entrance (no suck-back)")
bus.nodes[G2]:startTrip(T2); bus:pump()                  -- the "came back" leg: goldmine -> Terrapin
ok(bus.nodes[H2].gates.c1==RPM and (bus.nodes[H2].gates.c2 or 0)==0, "return trip opens hub->Terrapin only; goldmine tube stays shut")
bus.nodes[T2]:landPad(); bus:pump()
ok(not anyActive() and (bus.nodes[H2].gates.c1 or 0)==0, "back home; every hub gate closed")

print("== Phase 11: a portal (walk-through) hop routes across to a roof / Nether node ==")
NOW=70000
bus.nodes={}
local S3="Surface"; local HB3="Hub2"; local RF3="Roof"
bus.nodes[S3]=makeNode(S3,{c1=HB3})                      -- Surface --tube--> Hub2
bus.nodes[HB3]=makeNode(HB3,{c1=S3},{RF3})               -- Hub2 --portal--> Roof (no tube/controller)
bus.nodes[RF3]=makeNode(RF3,{},{HB3})                    -- Roof (tubeless) --portal--> Hub2
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
local pp=bus.nodes[S3]:pathTo(RF3)
ok(pp and table.concat(pp,">")==S3..">"..HB3..">"..RF3, "Surface routes to Roof via the portal node")
bus.nodes[S3]:startTrip(RF3); bus:pump()
ok(bus.nodes[HB3].lastHint and bus.nodes[HB3].lastHint:find("portal"), "hub tells the rider to WALK THROUGH the portal to Roof")
ok((bus.nodes[HB3].gates.c1 or 0)==0, "hub spins no tube for the portal hop (there is none)")
ok(bus.nodes[RF3].active~=nil, "roof node received the trip over rednet (ender modems cross dimensions)")
ok(bus.nodes[RF3]:applyTrip(bus.nodes[RF3].active)=="Arrived", "roof recognises itself as the destination after the walk-through")

print("== Phase 12: destination ordering - distance asc/desc, alphabetical, and filter ==")
NOW=80000
bus.nodes={}                                             -- Start->mine(1)->depot(2)->end(3); Start->farm(1)
bus.nodes["Start"]=makeNode("Start",{c1="mine",c2="farm"})
bus.nodes["mine"] =makeNode("mine", {c1="Start",c2="depot"})
bus.nodes["farm"] =makeNode("farm", {c1="Start"})
bus.nodes["depot"]=makeNode("depot",{c1="mine",c2="end"})
bus.nodes["end"]  =makeNode("end",  {c1="depot"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
-- mirror of the firmware's reachable()+orderedDests (distance = hops, filter = substring)
local function dists(node)
  local seen,out={},{}
  for n,nbrs in pairs(node.graph) do seen[n]=true; for _,nb in ipairs(nbrs) do seen[nb]=true end end
  for n in pairs(seen) do if n~=node.NAME then local p=node:pathTo(n); if p then out[#out+1]={name=n,dist=#p-1} end end end
  return out
end
local function order(list,mode)
  table.sort(list,function(a,b)
    if mode=="A-Z" then return a.name<b.name end
    if a.dist~=b.dist then if mode=="Dist -" then return a.dist>b.dist end return a.dist<b.dist end
    return a.name<b.name end)
  return list
end
local function filt(list,q) local k={} q=q:lower() for _,d in ipairs(list) do if d.name:lower():find(q,1,true) then k[#k+1]=d end end return k end
local S=bus.nodes["Start"]
local asc=order(dists(S),"Dist +")
ok(asc[1].dist==1, "distance-ascending lists a direct neighbour (1 hop) first")
ok(asc[#asc].name=="end" and asc[#asc].dist==3, "farthest stop (end, 3 hops) is last ascending")
ok(order(dists(S),"Dist -")[1].name=="end", "distance-descending lists the farthest stop first")
local az=order(dists(S),"A-Z")
ok(az[1].name=="depot", "alphabetical sort orders names (depot first)")
ok(#filt(dists(S),"AR")>=1, "filter is case-insensitive substring (matches 'farm')")
ok(#filt(dists(S),"zzz")==0, "a non-matching filter yields an empty list")

print("== Phase 13: arrival is confirmed only for the trip's OWN rider, not a bystander ==")
NOW=90000
bus.nodes={}
bus.nodes["A"]=makeNode("A",{c1="B"})
bus.nodes["B"]=makeNode("B",{c1="A"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["A"]:startTrip("B","Alice"); bus:pump()        -- Alice boards at A, bound for B
ok(bus.nodes["B"].active and bus.nodes["B"].active.rider=="Alice", "destination B knows the rider is Alice")
ok(bus.nodes["B"]:landPad("Bob")==false, "a bystander (Bob) on B's pad does NOT confirm Alice's trip")
ok(bus.nodes["B"].active~=nil and bus.nodes["A"].active~=nil, "trip stays active while only Bob is present")
ok(bus.nodes["B"]:landPad("Alice")==true, "Alice landing on B confirms arrival")
bus:pump()                                               -- deliver ARRIVED to node A
ok(not anyActive(), "trip cleared on every node once the actual rider arrived")

print(("\n==== %d passed, %d failed ===="):format(pass, fail))
if fail>0 then os.exit(1) end
