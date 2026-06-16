-- ===========================================================================
-- HT network simulator - mirrors ht_node.lua's logic and models the things
-- that actually break it: chunks load/unload, offline nodes miss broadcasts,
-- reboots wipe RAM (only files persist). The trip is SHARED state (gossiped in
-- STATE, persisted to disk, merged by a (ts,id) total order with a monotonic
-- `done` flag and a TRIP_TIMEOUT expiry) - a reloaded node recovers it from its
-- own disk or any peer's gossip. RPM/timeouts match the firmware.
-- ===========================================================================
local RPM = 128
local TRIP_TIMEOUT = 30
local RELAUNCH_HOLD = 3        -- matches the firmware tunable (launch cooldown)
local DEST_TTL = 300          -- matches the firmware: how long a remembered rider->dest lives
local TOMB_TTL = 2592000      -- matches the firmware: how long a node-removal tombstone lives
local NOW = 1000
local function dc(t) if type(t)~="table" then return t end local r={} for k,v in pairs(t) do r[k]=dc(v) end return r end
local function tripExpired(t) return (not t) or (NOW-(tonumber(t.ts) or 0))>TRIP_TIMEOUT end

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

local function makeNode(name, links, portals, bridge)
  -- The single network trip lives in SHARED state (self.trip), gossiped in STATE and persisted to disk with
  -- the map (self.files.state). Single-occupancy: newer ts supersedes; `done` monotonic; ages out at
  -- TRIP_TIMEOUT. No ROUTE/ARRIVED/TRIPREQ - a node converges on the trip from gossip or its own disk.
  local nd = { NAME=name, LINKS=links, PORTALS=portals or {}, files={}, graph={}, gen={}, trip=nil,
               gates={}, loaded=false, tripSeq=0, relaunchStop=nil, opened=false, riderDest={}, tombs={}, bridge=bridge }
  function nd:myNeighbours()
    local s,o={},{}
    for _,nb in pairs(self.LINKS) do if not s[nb] then s[nb]=true; o[#o+1]=nb end end
    for _,nb in ipairs(self.PORTALS) do if not s[nb] then s[nb]=true; o[#o+1]=nb end end  -- portal links
    return o
  end
  -- ---- shared trip helpers (mirror firmware) ----
  function nd:live() if self.trip and not self.trip.done and not tripExpired(self.trip) then return self.trip end end
  function nd:adoptTrip(t)
    if type(t)~="table" or not t.id or type(t.path)~="table" or tripExpired(t) then return false end
    -- dc(t) on assign: real rednet serializes each message, so nodes never share a trip table. The in-process
    -- bus passes refs, so without this a destination mutating done=true would silently flip it on every node.
    if not self.trip then self.trip=dc(t)
    elseif t.id==self.trip.id then
      if t.done and not self.trip.done then self.trip.done=true else return false end  -- done is sticky
    else
      local tts,cts=tonumber(t.ts) or 0, tonumber(self.trip.ts) or 0  -- order by (ts,id): a total order so
      if tts>cts or (tts==cts and t.id>self.trip.id) then self.trip=dc(t) else return false end  -- every node agrees
    end
    return true
  end
  function nd:pruneDests() for nm,d in pairs(self.riderDest) do if NOW-(tonumber(d.ts) or 0)>DEST_TTL then self.riderDest[nm]=nil end end end
  function nd:mergeDest(rn, d)  -- merge one gossiped rider->dest; newer ts wins
    if type(rn)~="string" or type(d)~="table" then return false end
    local cur=self.riderDest[rn]
    if not cur or (tonumber(d.ts) or 0)>(tonumber(cur.ts) or 0) then self.riderDest[rn]={to=d.to, ts=d.ts}; return true end
    return false
  end
  -- ---- tombstones (durable node removal; mirror firmware) ----
  function nd:mergeTomb(nm, ts)
    ts=tonumber(ts) or 0
    if type(nm)~="string" or nm==self.NAME or ts==0 then return false end  -- never tombstone ourselves
    if not self.tombs[nm] or ts>self.tombs[nm] then self.tombs[nm]=ts; return true end
    return false
  end
  function nd:pruneTombs() for nm,ts in pairs(self.tombs) do if NOW-(tonumber(ts) or 0)>TOMB_TTL then self.tombs[nm]=nil end end end
  function nd:applyTombs() for nm,ts in pairs(self.tombs) do if nm~=self.NAME and self.gen[nm] and self.gen[nm]<=ts then self.graph[nm]=nil; self.gen[nm]=nil end end end
  function nd:removeNode(nm)  -- the `firmware.lua forget <name>` path: tombstone + drop locally, then gossip the removal
    self.tombs[nm]=NOW; self.graph[nm]=nil; self.gen[nm]=nil; self:saveGraph(); self:broadcastState()
  end
  -- ---- shared state persist + gossip ----
  function nd:saveGraph() self.files.state={ graph=dc(self.graph), gen=dc(self.gen), trip=self.trip and dc(self.trip) or nil, dests=dc(self.riderDest), tombs=dc(self.tombs) } end
  function nd:loadGraph()
    local d=self.files.state
    if d and d.graph then for n,nbrs in pairs(d.graph) do
      if n~=self.NAME then self.graph[n]=dc(nbrs); self.gen[n]=(d.gen and d.gen[n]) or 0 end
    end end
    if d and type(d.trip)=="table" and not tripExpired(d.trip) then self.trip=dc(d.trip) end
    if d and type(d.dests)=="table" then for nm,dd in pairs(d.dests) do if type(dd)=="table" then self.riderDest[nm]=dc(dd) end end self:pruneDests() end
    if d and type(d.tombs)=="table" then for nm,ts in pairs(d.tombs) do if type(ts)=="number" then self.tombs[nm]=ts end end self:pruneTombs(); self:applyTombs() end
  end
  function nd:broadcastState()
    if not self.bridge then self.graph[self.NAME]=self:myNeighbours(); self.gen[self.NAME]=NOW end  -- a mouth advertises no row
    self:pruneTombs(); self:applyTombs(); self:saveGraph(); self:pruneDests()
    local nodes={} for n,nbrs in pairs(self.graph) do nodes[n]={nbrs=nbrs, ts=self.gen[n] or 0} end
    bus:broadcast(self.NAME, { type="STATE", nodes=nodes, trip=self.trip and dc(self.trip) or nil, dests=dc(self.riderDest), tombs=dc(self.tombs) })
  end
  function nd:mergeState(nodes, gtrip, gdests, gtombs)
    local mc=false
    if type(gtombs)=="table" then for nm,ts in pairs(gtombs) do if self:mergeTomb(nm,ts) then mc=true end end end  -- removals first
    if type(nodes)=="table" then for n,info in pairs(nodes) do if type(info)=="table" and type(info.nbrs)=="table" then
      local ts=info.ts or 0
      if self.tombs[n] and ts<=self.tombs[n] then  -- a row older than its removal: ignore it
      elseif not self.gen[n] or ts>self.gen[n] then
        self.graph[n]=dc(info.nbrs); self.gen[n]=ts; mc=true
        if self.tombs[n] then self.tombs[n]=nil end  -- a row newer than the tomb: node is back -> un-remove
      end
    end end end
    self:applyTombs()
    local tc = gtrip~=nil and self:adoptTrip(gtrip)
    local dch=false
    if type(gdests)=="table" then for nm,dd in pairs(gdests) do if self:mergeDest(nm,dd) then dch=true end end end
    if mc or tc or dch then self:saveGraph() end
    return mc, tc
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
  function nd:tripHint(t)   -- screen hint only (gates are detector-driven, never opened here)
    local i=self:indexIn(t.path)
    if not i then return nil end
    if i==#t.path then return "Arrived" end
    local nxt=t.path[i+1]
    if not self:controllerToward(nxt) then return "portal->"..nxt end
    if i==1 then return "Board->"..nxt end
    return "Pass->"..nxt
  end
  -- close our gate when we're NOT an active tube-hop (off-path/destination/portal/not-live); leave an
  -- origin/junction tube-hop's gate to the detector-driven pad poll.
  function nd:reconcile()
    local t=self:live()
    if not t then self.lastHint=nil; if self.opened then self:allStop(); self.opened=false end; return end
    self.lastHint=self:tripHint(t)
    local i=self:indexIn(t.path)
    if (not i) or i==#t.path or not self:controllerToward(t.path[i+1]) then
      if self.opened then self:allStop(); self.opened=false end
    elseif i>1 then self:gateToward(t.path[i+1]); self.opened=true   -- JUNCTION: fly-through (open in advance)
    end
  end
  -- ---- portal MOUTH (bridge mode): off-path relay, never a destination ----
  -- It owns one tube flinging toward bridge.near; it spins IN ADVANCE whenever the
  -- shared trip crosses this portal toward `near` (rider heading far->near), else shut.
  function nd:mouthFar() return (self.bridge.near==self.bridge.a) and self.bridge.d or self.bridge.a end
  function nd:mouthShouldSpin()
    local t=self:live(); if not t or type(t.path)~="table" then return false end
    local far,near=self:mouthFar(), self.bridge.near
    for i=1,#t.path-1 do if t.path[i]==far and t.path[i+1]==near then return true end end
    return false
  end
  function nd:mouthGate()
    if self:mouthShouldSpin() then self:gateToward(self.bridge.near); self.opened=true
    elseif self.opened then self:allStop(); self.opened=false end
  end
  function nd:startTrip(dest, rider)
    if dest==self.NAME then return "self" end
    if self:live() and (NOW-(self.trip.ts or 0))<1.5 then return end   -- debounce; re-tap still re-routes
    local path=self:pathTo(dest); if not path then return nil end
    self.tripSeq=self.tripSeq+1
    local ts=math.max(NOW, (self.trip and tonumber(self.trip.ts) or 0)+1)  -- strictly newer so adoptTrip can't reject
    if not self:adoptTrip({ id=self.NAME..":"..self.tripSeq, from=self.NAME, to=dest, path=path, rider=rider, ts=ts, done=false }) then return nil end
    self.relaunchStop=nil; self.lastHint="Board->"..dest
    if rider then self.riderDest[rider]={to=dest, ts=ts} end  -- remember where this rider is headed (durable)
    self:saveGraph(); self:broadcastState()                -- publish the new trip + dest as shared state
    self:gateToward(path[2]); self.opened=true             -- fling off our pad; the pad poll closes it when they leave
    return path
  end
  function nd:arrive()                                     -- DESTINATION: flip the shared trip to done + gossip
    if self.trip then
      self.trip.done=true
      if self.trip.rider then self.riderDest[self.trip.rider]={to=nil, ts=math.max(NOW,(tonumber(self.trip.ts) or 0)+1)} end  -- tombstone (newer than trip)
      self:saveGraph(); self:broadcastState()
    end
    self.relaunchStop=nil
    if self.opened then self:allStop(); self.opened=false end
    self:reconcile()
  end
  function nd:handle(msg)
    if type(msg)~="table" then return end
    if msg.type=="STATE" then
      local _,tc=self:mergeState(msg.nodes, msg.trip, msg.dests, msg.tombs)
      if tc then if self.bridge then self:mouthGate() else self:reconcile() end end
    elseif msg.type=="LSREQ" then self:broadcastState() end
  end
  function nd:beat() if self:live() then self:broadcastState() end end  -- re-gossip the shared trip
  function nd:boot()
    self.loaded=true; self.graph={}; self.gen={}; self.trip=nil; self.gates={}; self.riderDest={}; self.tombs={}
    self.relaunchStop=nil; self.opened=false; self.lastHint=nil
    if not self.bridge then self.graph[self.NAME]=self:myNeighbours(); self.gen[self.NAME]=NOW end  -- a mouth seeds no row
    self:loadGraph()                                       -- recover map AND trip from disk
    if self:live() then if self.bridge then self:mouthGate() else self:reconcile() end end  -- restore the gate from disk
    self:broadcastState()
    bus:broadcast(self.NAME, { type="LSREQ" })             -- ask for shared state (reply carries map + trip/done)
  end
  function nd:unload() self.loaded=false end
  function nd:tick() if self.relaunchStop and NOW>=self.relaunchStop then self.relaunchStop=nil end end  -- cooldown over
  -- DETECTOR-gated pad poll; `who` = name on our pad (nil if none). Mirrors the firmware pad-timer branch.
  function nd:padPoll(who)
    local t=self:live()
    local i=t and self:indexIn(t.path)
    local here = t and who~=nil and ((not t.rider) or who==t.rider)   -- our trip's rider is on our pad
    if not t or not i then
      if self.trip and tripExpired(self.trip) then self.trip=nil; self:saveGraph() end
      if self.opened then self:allStop(); self.opened=false end
      if who~=nil then
        bus:broadcast(self.NAME, { type="LSREQ" })                     -- 1) pull a live trip from any loaded peer
        local d=self.riderDest[who]                                    -- 2) AUTO-REBOARD from our remembered destination
        if d and d.to and d.to~=self.NAME and not self:live() and self:pathTo(d.to) then self:startTrip(d.to, who) end
      end
      return "idle"
    elseif i==#t.path then                                            -- destination
      if here then self:arrive(); return "arrived" end
      if self.opened then self:allStop(); self.opened=false end
      return "waiting"
    elseif not self:controllerToward(t.path[i+1]) then                -- portal hop: nothing to spin
      if self.opened then self:allStop(); self.opened=false end
      return "portal"
    elseif i>1 then                                                   -- JUNCTION: fly-through (open while live)
      self:gateToward(t.path[i+1]); self.opened=true
      return "open"
    else                                                              -- ORIGIN: detector-gated launch
      local cooling = self.relaunchStop and NOW<self.relaunchStop and self.relaunchStopFor==t.id
      if here and not cooling then self:gateToward(t.path[i+1]); self.opened=true; return "open"
      elseif self.opened and not here then
        self:allStop(); self.opened=false; self.relaunchStop=NOW+RELAUNCH_HOLD; self.relaunchStopFor=t.id  -- close + cooldown
        return "closed"
      end
      return self.opened and "open" or "shut"
    end
  end
  function nd:landPad(who)  -- destination-arrival helper for the phases; no arg = the trip's own rider lands
    local t=self:live()
    return self:padPoll(who or (t and t.rider) or "player")=="arrived"
  end
  return nd
end

-- ---- assertions ----
local pass, fail = 0, 0
local function ok(cond, label) if cond then pass=pass+1; print("  PASS  "..label) else fail=fail+1; print("  FAIL  "..label) end end
local function anyActive() for _,nd in pairs(bus.nodes) do if nd:live()~=nil then return true end end return false end

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
ok(bus.nodes[AV].files.state~=nil, "shared state persisted to disk on Avenger")

print("== Phase 2: unload everyone but Avenger (chunks off) ==")
NOW=NOW+100
bus.nodes[HUB]:unload(); bus.nodes[TER]:unload(); bus.nodes[ALO]:unload()
ok(not bus.nodes[HUB].loaded and not bus.nodes[TER].loaded, "Hub & Terrapin are unloaded (computers off)")
ok(bus.nodes[AV]:pathTo(TER)~=nil, "Avenger STILL routes to Terrapin from persisted map (the key fix)")

print("== Phase 3: start trip with the hub & dest OFFLINE, then they load mid-route ==")
local path = bus.nodes[AV]:startTrip(TER, "Ada"); bus:pump()
ok(path and table.concat(path,">")==AV..">"..HUB..">"..TER, "trip starts, path is Avenger>Hub>Terrapin")
ok(bus.nodes[AV].gates.c1==RPM, "Avenger (origin) opened its tube toward the hub (Ada on the pad)")
ok(bus.nodes[HUB]:live()==nil, "hub heard nothing yet (it was unloaded at departure)")

NOW=NOW+5  -- player flies toward hub; hub chunk loads
bus.nodes[HUB]:boot(); bus:pump()      -- boot asks for shared state (LSREQ); Avenger (loaded) replies STATE w/ trip
ok(bus.nodes[HUB]:live()~=nil, "hub booted mid-route and PICKED UP the trip from SHARED STATE")
ok(bus.nodes[HUB].gates.c2==RPM, "hub opens its Terrapin tube IN ADVANCE (fly-through) so the rider sails through")
ok(bus.nodes[HUB].gates.c1==0 and bus.nodes[HUB].gates.c3==0, "hub opened ONLY the Terrapin tube (no misroute)")

bus.nodes[AV]:padPoll(nil)             -- Ada has left Avenger's pad
ok(bus.nodes[AV].gates.c1==0, "Avenger closed its launch tube once Ada left (no suck-back)")
ok(bus.nodes[AV]:live()~=nil, "Avenger still holds the trip in shared state (didn't forget it)")

NOW=NOW+5  -- player flies hub->Terrapin; Terrapin chunk loads
bus.nodes[TER]:boot(); bus:pump()
ok(bus.nodes[TER]:live()~=nil, "Terrapin booted and picked up the trip from shared state")
ok(bus.nodes[TER]:tripHint(bus.nodes[TER]:live())=="Arrived", "Terrapin recognises itself as the destination")

local arrived = bus.nodes[TER]:landPad("Ada"); bus:pump()
ok(arrived, "Ada lands on Terrapin pad -> trip flipped to done + gossiped")
ok(bus.nodes[HUB]:live()==nil and bus.nodes[AV]:live()==nil, "the gossiped done cleared the trip on hub & Avenger")
ok((bus.nodes[HUB].gates.c2 or 0)==0, "hub closed its Terrapin tube after the trip")

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
ok(bus.nodes[AV]:live()~=nil and bus.nodes[HUB]:live()~=nil, "trip active on origin and junction")
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
local ghost = dc(bus.nodes[TER]:live())                  -- capture the in-flight trip (done=false) before arrival
ok(ghost~=nil, "destination is holding the in-flight trip in shared state")
bus.nodes[TER]:landPad(); bus:pump()                     -- arrival -> done=true gossiped, everyone clears
ok(not anyActive(), "all nodes cleared after the trip was marked done")
bus:broadcast("ghost", { type="STATE", nodes={}, trip=ghost }); bus:pump()  -- a stale gossip of the SAME id (done=false)
ok(not anyActive(), "stale gossip ignored - done is monotonic, trip NOT resurrected")

print("== Phase 8: a junction that reloads AFTER its rider arrived is told 'done' by a peer (no stale-trip suck-back) ==")
NOW=40000
for _,nd in pairs(bus.nodes) do nd.loaded=true; nd:boot() end; bus:pump()
bus.nodes[AV]:startTrip(TER,"Rae"); bus:pump()           -- Rae rides Avenger>Hub>Terrapin; hub is a junction
bus.nodes[HUB]:padPoll("Rae")                            -- Rae reaches the hub pad
ok(bus.nodes[HUB].gates.c2==RPM, "hub opened its Terrapin tube for the trip (Rae on its pad)")
ok(bus.nodes[HUB].files.state.trip~=nil, "hub persisted the trip (shared state) while mid-route")
bus.nodes[HUB]:unload()                                  -- hub's chunk unloads while the rider is mid-route
bus.nodes[TER]:landPad("Rae"); bus:pump()                -- Rae arrives at Terrapin; done=true gossiped but hub is OFF
NOW=NOW+4; bus.nodes[HUB]:boot(); bus:pump()             -- hub reloads, restores trip from disk, asks for shared state;
                                                         -- Terrapin's reply carries the SAME trip flagged done
ok(bus.nodes[HUB]:live()==nil, "reloaded hub learned the trip finished from shared state -> not live (no stale hold)")
ok(bus.nodes[HUB].files.state.trip.done==true, "it recorded the trip as done (the monotonic finished-marker)")
ok((bus.nodes[HUB].gates.c2 or 0)==0, "hub never re-opened its tube -> no suck-back even if Rae walks back later")

print("== Phase 9: a finished trip's launch cooldown can't strand a LATER pass-through (trip-specific) ==")
NOW=50000
for _,nd in pairs(bus.nodes) do nd.loaded=true; nd:boot() end; bus:pump()
NOW=NOW+1; bus.nodes[HUB]:startTrip(TER,"Ki"); bus:pump() -- HUB is ORIGIN of trip1
ok(bus.nodes[HUB].gates.c2==RPM, "hub-as-origin launched trip1 toward Terrapin")
bus.nodes[HUB]:padPoll(nil)                              -- Ki leaves the hub -> close + arm a trip1-specific cooldown
ok(bus.nodes[HUB].relaunchStop~=nil, "hub armed a launch cooldown after Ki left")
NOW=NOW+1; bus.nodes[TER]:landPad("Ki"); bus:pump()      -- trip1 ends (done gossiped to the hub)
ok(bus.nodes[HUB]:live()==nil, "trip1 finished -> not live at the hub")
NOW=NOW+1; bus.nodes[AV]:startTrip(ALO,"Lo"); bus:pump() -- NEW trip2 passes THROUGH hub (Avenger>Hub>Al0p)
bus.nodes[HUB]:padPoll("Lo")                             -- Lo reaches the hub; trip1's cooldown is still ticking
ok(bus.nodes[HUB].gates.c3==RPM, "the stale trip1 cooldown did NOT block trip2's gate (rider not stranded)")
ok(bus.nodes[HUB]:live()~=nil and (bus.nodes[HUB].gates.c2 or 0)==0, "hub opened ONLY trip2's Al0p tube")

print("== Phase 10: round trip leaves NO gate stuck open (the reported goldmine bug) ==")
NOW=60000
bus.nodes={}                                             -- clean line: Terrapin <-> Hub <-> goldmine
local T2="Terrapin"; local H2="Hub"; local G2="goldmine"
bus.nodes[T2]=makeNode(T2,{c1=H2})
bus.nodes[H2]=makeNode(H2,{c1=T2,c2=G2})
bus.nodes[G2]=makeNode(G2,{c1=H2})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes[T2]:startTrip(G2,"Wim"); bus:pump()            -- Terrapin -> goldmine, through the hub
local trip1=dc(bus.nodes[H2]:live())                     -- the in-flight trip the hub is holding (done=false)
bus.nodes[H2]:padPoll("Wim")                             -- Wim reaches the hub
ok(bus.nodes[H2].gates.c2==RPM, "hub opened its goldmine tube while routing Wim there")
bus.nodes[G2]:landPad("Wim"); bus:pump()                 -- arrive at goldmine -> done gossiped, clears everyone
ok((bus.nodes[H2].gates.c2 or 0)==0, "hub CLOSED its goldmine tube on arrival (entrance not left open)")
ok(not anyActive(), "no trip left active after arriving at goldmine")
bus:broadcast("ghost", { type="STATE", nodes={}, trip=trip1 }); bus:pump()  -- a stale gossip of the finished trip (done=false)
bus.nodes[H2]:padPoll("Wim")                             -- ...even with Wim back on the hub pad
ok((bus.nodes[H2].gates.c2 or 0)==0, "stale gossip + rider present did NOT re-open the goldmine tube (done is monotonic)")
bus.nodes[G2]:startTrip(T2,"Wim"); bus:pump()            -- the "came back" leg: goldmine -> Terrapin
bus.nodes[H2]:padPoll("Wim")                             -- Wim reaches the hub on the return
ok(bus.nodes[H2].gates.c1==RPM and (bus.nodes[H2].gates.c2 or 0)==0, "return trip opens hub->Terrapin only; goldmine tube stays shut")
bus.nodes[T2]:landPad("Wim"); bus:pump()
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
ok(bus.nodes[RF3]:live()~=nil, "roof node received the trip over rednet (ender modems cross dimensions)")
ok(bus.nodes[RF3]:tripHint(bus.nodes[RF3]:live())=="Arrived", "roof recognises itself as the destination after the walk-through")

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
ok(bus.nodes["B"]:live() and bus.nodes["B"]:live().rider=="Alice", "destination B knows the rider is Alice")
ok(bus.nodes["B"]:landPad("Bob")==false, "a bystander (Bob) on B's pad does NOT confirm Alice's trip")
ok(bus.nodes["B"]:live()~=nil and bus.nodes["A"]:live()~=nil, "trip stays active while only Bob is present")
ok(bus.nodes["B"]:landPad("Alice")==true, "Alice landing on B confirms arrival")
bus:pump()                                               -- deliver ARRIVED to node A
ok(not anyActive(), "trip cleared on every node once the actual rider arrived")

print("== Phase 14: a junction that reloads ALONE (no peer) recovers the trip from disk + catches its rider ==")
-- The field bug: Right Island Hub kept rebooting (chunk cycling). With the trip in SHARED state, the Hub
-- recovers it from its OWN disk - no live peer needed - and opens onward when its rider drops onto its pad.
NOW=100000
bus.nodes={}
bus.nodes["Spawn"]   =makeNode("Spawn",   {c1="Terrapin"})
bus.nodes["Terrapin"]=makeNode("Terrapin",{c1="Spawn",c2="Hub"})
bus.nodes["Hub"]     =makeNode("Hub",     {c1="Terrapin",c2="Al0p",c3="Other"})  -- the junction
bus.nodes["Al0p"]    =makeNode("Al0p",    {c1="Hub"})
bus.nodes["Other"]   =makeNode("Other",   {c1="Hub"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["Spawn"]:startTrip("Al0p","Isuenon"); bus:pump()
ok(bus.nodes["Hub"]:live() and table.concat(bus.nodes["Hub"]:live().path,">")=="Spawn>Terrapin>Hub>Al0p",
   "trip routes Spawn>Terrapin>Hub>Al0p")
ok(bus.nodes["Hub"].files.state.trip~=nil, "Hub persisted the in-flight trip (shared state) to disk")
for n,nd in pairs(bus.nodes) do if n~="Hub" then nd:unload() end end  -- every peer goes offline...
bus.nodes["Hub"]:unload()                                            -- ...and the Hub cycles its chunk
NOW=NOW+3; bus.nodes["Hub"]:boot(); bus:pump()                       -- reloads ALONE: no peer answers LSREQ
ok(bus.nodes["Hub"]:live()~=nil, "Hub recovered the trip from its OWN DISK despite no peer reachable")
ok(bus.nodes["Hub"].gates.c2==RPM, "Hub re-opens its Al0p tube IN ADVANCE (fly-through) from its own disk -> rider sails through, not stranded")

print("== Phase 15: a finished trip stays DONE in shared state, so a later reload opens no gate (no resurrection) ==")
NOW=110000
bus.nodes={}
bus.nodes["Spawn"]=makeNode("Spawn",{c1="Hub"})
bus.nodes["Hub"]  =makeNode("Hub",  {c1="Spawn",c2="Dest"})
bus.nodes["Dest"] =makeNode("Dest", {c1="Hub"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["Spawn"]:startTrip("Dest","Zed"); bus:pump()
bus.nodes["Hub"]:padPoll("Zed")                          -- Zed reaches the hub
ok(bus.nodes["Hub"]:live()~=nil and bus.nodes["Hub"].gates.c2==RPM, "Hub is mid-route with its Dest tube open")
bus.nodes["Dest"]:landPad("Zed"); bus:pump()             -- arrival -> done=true gossiped to every node
ok(bus.nodes["Hub"]:live()==nil, "the gossiped done cleared the live trip at the Hub")
ok(bus.nodes["Hub"].files.state.trip.done==true, "the Hub's persisted trip is flagged done (kept as the finished-marker)")
ok((bus.nodes["Hub"].gates.c2 or 0)==0, "Hub closed its Dest tube on the done")
NOW=NOW+1; bus.nodes["Hub"]:boot(); bus:pump()           -- a later, unrelated reload
ok(bus.nodes["Hub"]:live()==nil, "the reload restores the trip as DONE -> not live (no resurrection)")
bus.nodes["Hub"]:padPoll("Zed")                          -- even Zed back on the pad
ok((bus.nodes["Hub"].gates.c2 or 0)==0, "opens no gate even with a rider present (the trip is done)")

print("== Phase 16: integrated pad poll - junction fly-through (open in advance), destination arrival, expiry ==")
NOW=120000
bus.nodes={}
bus.nodes["O"]=makeNode("O",{c1="J"})
bus.nodes["J"]=makeNode("J",{c1="O",c2="D",c3="X"})      -- junction with a decoy tube X
bus.nodes["D"]=makeNode("D",{c1="J"})
bus.nodes["X"]=makeNode("X",{c1="J"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["O"]:startTrip("D","Liv"); bus:pump()          -- O>J>D ; J is the junction
local J=bus.nodes["J"]
ok(J:live() and J:live().to=="D", "junction holds the live trip")
ok(J.gates.c2==RPM, "junction opened the D tube IN ADVANCE on gossip (fly-through) so a moving rider sails through")
ok((J.gates.c3 or 0)==0, "the decoy tube X stays shut (only the on-path tube opens)")
ok(J:padPoll(nil)=="open" and J.gates.c2==RPM, "junction stays open while the trip is live (no rider needed)")
ok(bus.nodes["D"]:padPoll(nil)=="waiting", "destination with nobody present just waits")
ok(bus.nodes["D"]:padPoll("Liv")=="arrived", "destination confirms only when ITS rider lands")
bus:pump()                                               -- the done gossips out
ok(J:live()==nil and (J.gates.c2 or 0)==0, "the gossiped done clears the junction's live trip and closes its tube")
NOW=130000
bus.nodes["O"]:startTrip("D","Mo"); bus:pump()           -- a fresh trip, then strand it
NOW=bus.nodes["J"]:live().ts+TRIP_TIMEOUT+1              -- jump past its absolute (ts-anchored) deadline
ok(bus.nodes["J"]:padPoll(nil)=="idle" and bus.nodes["J"]:live()==nil, "past TRIP_TIMEOUT the trip is no longer live (expiry)")

print("== Phase 17: an ORIGIN that reloads between board and launch still re-launches its rider (CRITICAL fix) ==")
NOW=140000
bus.nodes={}
bus.nodes["O"]=makeNode("O",{c1="D"})
bus.nodes["D"]=makeNode("D",{c1="O"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["O"]:startTrip("D","Nia"); bus:pump()          -- Nia boards; O opens its launch tube
ok(bus.nodes["O"].gates.c1==RPM, "origin opened its launch tube on board")
bus.nodes["O"]:unload(); bus.nodes["O"]:boot(); bus:pump() -- O reboots (e.g. auto-update) before Nia launched
ok(bus.nodes["O"]:live()~=nil, "origin recovered the trip from disk after the reboot")
ok((bus.nodes["O"].gates.c1 or 0)==0, "its launch tube is shut right after boot (RAM-wiped gate)")
bus.nodes["O"]:padPoll("Nia")                            -- Nia is still standing on the origin pad
ok(bus.nodes["O"].gates.c1==RPM, "origin RE-OPENS the launch tube for Nia -> not stranded on the pad")

print("== Phase 18: a destination that misses its rider leaves the trip live; the junction holds open but it's BOUNDED ==")
NOW=150000
bus.nodes={}
bus.nodes["A"]=makeNode("A",{c1="J"})
bus.nodes["J"]=makeNode("J",{c1="A",c2="Z"})
bus.nodes["Z"]=makeNode("Z",{c1="J"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["A"]:startTrip("Z","Pat"); bus:pump()          -- Pat rides A>J>Z; Z is the destination
bus.nodes["Z"]:unload()                                  -- Z's chunk is off as Pat is flung to it -> arrival missed
ok(bus.nodes["J"]:live()~=nil and bus.nodes["J"].gates.c2==RPM, "the trip stays live and J holds its tube open (fly-through)")
-- ACCEPTED RESIDUAL: with fly-through, a phantom-live trip holds the junction tube open until it ages out.
-- It is BOUNDED by the absolute deadline and self-clears - no permanent stuck-open gate.
NOW=bus.nodes["J"]:live().ts+TRIP_TIMEOUT+1              -- jump past the absolute deadline
ok(bus.nodes["J"]:padPoll(nil)=="idle" and bus.nodes["J"]:live()==nil and (bus.nodes["J"].gates.c2 or 0)==0,
   "the phantom trip ages out at TRIP_TIMEOUT and the junction closes (bounded, self-clearing)")

print("== Phase 19: a newer trip that supersedes while a junction gate is OPEN re-points the gate (MAJOR fix) ==")
NOW=160000
bus.nodes={}
bus.nodes["S"]=makeNode("S",{c1="J"})
bus.nodes["J"]=makeNode("J",{c1="S",c2="X",c3="Y"})     -- junction: c2->X, c3->Y
bus.nodes["X"]=makeNode("X",{c1="J"})
bus.nodes["Y"]=makeNode("Y",{c1="J"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["S"]:startTrip("X","Al"); bus:pump()           -- trip A: S>J>X
bus.nodes["J"]:padPoll("Al")                             -- Al reaches J -> J opens toward X
ok(bus.nodes["J"].gates.c2==RPM and (bus.nodes["J"].gates.c3 or 0)==0, "J opened toward X for trip A")
NOW=NOW+2; bus.nodes["S"]:startTrip("Y","Bo"); bus:pump() -- a strictly-newer trip B: S>J>Y supersedes A via gossip
ok(bus.nodes["J"]:live().to=="Y", "the newer trip B (to Y) superseded A at J while J's X tube is still open")
bus.nodes["J"]:padPoll("Bo")                             -- Bo arrives at J while opened is still true toward X
ok(bus.nodes["J"].gates.c3==RPM and (bus.nodes["J"].gates.c2 or 0)==0, "J RE-POINTED to Y and closed X (no misroute/strand)")

print("== Phase 20: after the launch cooldown expires, a rider still on the pad is re-launched (anti-bounce recovery) ==")
NOW=170000
bus.nodes={}
bus.nodes["O"]=makeNode("O",{c1="D"})
bus.nodes["D"]=makeNode("D",{c1="O"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["O"]:startTrip("D","Ren"); bus:pump()          -- O opens its launch tube (opened)
bus.nodes["O"]:padPoll(nil)                              -- Ren leaves -> close + arm cooldown
ok((bus.nodes["O"].gates.c1 or 0)==0 and bus.nodes["O"].relaunchStop~=nil, "launch tube closed + cooldown armed after Ren left")
ok(bus.nodes["O"]:padPoll("Ren")=="shut" and (bus.nodes["O"].gates.c1 or 0)==0, "during the cooldown, Ren bouncing back is NOT instantly re-grabbed")
NOW=bus.nodes["O"].relaunchStop+1; bus.nodes["O"]:tick() -- cooldown expires
ok(bus.nodes["O"]:padPoll("Ren")=="open" and bus.nodes["O"].gates.c1==RPM, "after the cooldown, Ren still on the pad is re-launched")

print("== Phase 21: the user's real 5-hop route Avenger>Hub>Terrapin>China>Pupigo delivers to Pupigo ==")
NOW=180000
bus.nodes={}
bus.nodes["Avenger"] =makeNode("Avenger", {c1="Hub"})
bus.nodes["Hub"]     =makeNode("Hub",     {c1="Avenger",c2="Terrapin",c3="Al0p",c4="G0ldMin3"})
bus.nodes["Terrapin"]=makeNode("Terrapin",{c1="Hub",c2="China",c3="Spawn"})
bus.nodes["China"]   =makeNode("China",   {c1="Terrapin",c2="Pupigo"})
bus.nodes["Pupigo"]  =makeNode("Pupigo",  {c1="China"})
bus.nodes["Al0p"]=makeNode("Al0p",{c1="Hub"}); bus.nodes["G0ldMin3"]=makeNode("G0ldMin3",{c1="Hub"}); bus.nodes["Spawn"]=makeNode("Spawn",{c1="Terrapin"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump(); bus:pump()   -- let the map fully converge
local p=bus.nodes["Avenger"]:startTrip("Pupigo","Vlad"); bus:pump()
ok(p and table.concat(p,">")=="Avenger>Hub>Terrapin>China>Pupigo", "route is Avenger>Hub>Terrapin>China>Pupigo")
-- every mid-route junction fly-throughs toward the next hop the moment it adopts the gossiped trip:
ok(bus.nodes["Hub"].gates.c2==RPM, "Hub opened toward Terrapin")
ok(bus.nodes["Terrapin"].gates.c2==RPM, "Terrapin opened toward China")
ok(bus.nodes["China"].gates.c2==RPM and (bus.nodes["China"].gates.c1 or 0)==0, "China opened toward Pupigo (NOT back to Terrapin)")
ok(bus.nodes["Pupigo"]:landPad("Vlad")==true, "Vlad lands on Pupigo -> arrival confirmed")
bus:pump()
ok(not anyActive(), "trip cleared end-to-end (delivered to Pupigo, not China)")

print("== Phase 22: a rider waiting at a trip-less junction pulls the trip from a loaded peer (re-LSREQ recovery) ==")
NOW=190000
bus.nodes={}
bus.nodes["O"]=makeNode("O",{c1="J"})
bus.nodes["J"]=makeNode("J",{c1="O",c2="D"})
bus.nodes["D"]=makeNode("D",{c1="J"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["O"]:startTrip("D","Sam"); bus:pump()
bus.nodes["J"].trip=nil; bus.nodes["J"].gates={}; bus.nodes["J"].opened=false  -- J loaded late: no trip, tube shut; O still holds it
ok(bus.nodes["J"]:live()==nil and (bus.nodes["J"].gates.c2 or 0)==0, "J has no trip and its tube is shut")
bus.nodes["J"]:padPoll("Sam"); bus:pump()                -- Sam stands on J's pad -> J re-asks; O replies with the trip
ok(bus.nodes["J"]:live()~=nil, "J pulled the trip from a loaded peer after the rider showed up")
ok(bus.nodes["J"].gates.c2==RPM, "...and opened toward D so Sam is flung onward (not stranded)")

print("== Phase 23: a hub that REMEMBERS a rider's destination auto-reboards them, with NO live trip and NO peer ==")
NOW=200000
bus.nodes={}
bus.nodes["O"]=makeNode("O",{c1="J"})
bus.nodes["J"]=makeNode("J",{c1="O",c2="D"})
bus.nodes["D"]=makeNode("D",{c1="J"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
bus.nodes["O"]:startTrip("D","Mira"); bus:pump()         -- O publishes the trip AND riderDest[Mira]=D; J hears it once
ok(bus.nodes["J"].riderDest["Mira"] and bus.nodes["J"].riderDest["Mira"].to=="D", "J learned Mira's destination from the gossip")
bus.nodes["J"].trip=nil; bus.nodes["J"].gates={}; bus.nodes["J"].opened=false  -- J's live trip is gone (it cycled)
for n,nd in pairs(bus.nodes) do if n~="J" then nd:unload() end end             -- and EVERY other node unloads (no peer)
ok(bus.nodes["J"]:live()==nil and (bus.nodes["J"].gates.c2 or 0)==0, "J has no live trip and its tube is shut, completely alone")
bus.nodes["J"]:padPoll("Mira")                          -- Mira drops onto J's pad; J re-launches her from MEMORY
ok(bus.nodes["J"]:live()~=nil and bus.nodes["J"]:live().to=="D", "J AUTO-REBOARDED Mira toward D from its remembered destination")
ok(bus.nodes["J"].gates.c2==RPM, "...and opened toward D -> Mira flung onward, no peer needed at that moment")
-- arrival tombstones the dest so a later step onto a hub doesn't re-launch her:
bus.nodes["J"]:padPoll(nil)                             -- Mira leaves J
for _,nd in pairs(bus.nodes) do nd.loaded=true end
bus.nodes["D"].trip=dc(bus.nodes["J"]:live()); bus.nodes["D"]:arrive(); bus:pump()  -- she reaches D
ok(bus.nodes["J"].riderDest["Mira"] and bus.nodes["J"].riderDest["Mira"].to==nil, "on arrival, J's remembered dest for Mira is tombstoned (won't re-launch her)")

print("== Phase 24: nameless portal MOUTHS bridge A<->D - configured only with real stations, never a destination ==")
-- physical line:  A --tube-- Bm(mouth) --portal-- Cm(mouth) --tube-- D --tube-- Z
-- A and D just point a NORMAL tube at each other (the one network edge); the two mouths
-- are off-path relays, each told only the two real stations it bridges + which side it flings to.
NOW=210000
bus.nodes={}
bus.nodes["A"]=makeNode("A",{c1="D"})
bus.nodes["D"]=makeNode("D",{c1="A",c2="Z"})
bus.nodes["Z"]=makeNode("Z",{c1="D"})
bus.nodes["Bm"]=makeNode("Bm",{m1="A"},nil,{a="A",d="D",near="A"})  -- overworld mouth: THIS side A, FAR side D, flings toward A
bus.nodes["Cm"]=makeNode("Cm",{m1="D"},nil,{a="D",d="A",near="D"})  -- nether mouth:    THIS side D, FAR side A, flings toward D
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump(); bus:pump()
ok(bus.nodes["A"]:pathTo("D") and table.concat(bus.nodes["A"]:pathTo("D"),">")=="A>D", "A routes to D as ONE edge (mouths are off-path)")
local function listed(node,nm) for _,d in ipairs(dists(node)) do if d.name==nm then return true end end return false end
ok(not listed(bus.nodes["A"],"Bm") and not listed(bus.nodes["A"],"Cm"), "neither mouth appears as a destination on A (nameless/hidden)")
-- OUTBOUND A->D: the nether mouth (Cm) spins toward D in advance; the overworld mouth (Bm) stays shut
bus.nodes["A"]:startTrip("D","Wade"); bus:pump()
ok(bus.nodes["A"].gates.c1==RPM, "A (origin) flings the rider toward D / the portal")
ok(bus.nodes["Cm"].gates.m1==RPM, "nether mouth opens its D tube IN ADVANCE (rider crossing A->D)")
ok((bus.nodes["Bm"].gates.m1 or 0)==0, "overworld mouth stays SHUT outbound (won't re-grab the rider back toward A)")
ok(bus.nodes["D"]:landPad("Wade")==true, "rider lands on D -> arrival confirmed")
bus:pump()
ok(not anyActive(), "outbound trip cleared end-to-end")
ok((bus.nodes["Cm"].gates.m1 or 0)==0, "nether mouth closed once the trip finished (no stuck-open tube)")
-- RETURN D->A: mirror image - overworld mouth spins toward A, nether mouth stays shut
NOW=NOW+10
bus.nodes["D"]:startTrip("A","Wade"); bus:pump()
ok(bus.nodes["Bm"].gates.m1==RPM, "overworld mouth opens its A tube IN ADVANCE (rider crossing D->A)")
ok((bus.nodes["Cm"].gates.m1 or 0)==0, "nether mouth stays SHUT on the return (no re-grab toward D)")
ok(bus.nodes["A"]:landPad("Wade")==true, "rider lands back on A -> arrival confirmed")
bus:pump(); ok(not anyActive(), "return trip cleared")
-- MULTI-HOP A->Z THROUGH the portal: A->D edge then D->Z; Cm flings across the portal, D junctions onward to Z
NOW=NOW+10
ok(bus.nodes["A"]:pathTo("Z") and table.concat(bus.nodes["A"]:pathTo("Z"),">")=="A>D>Z", "A->Z routes A>D>Z across the portal")
bus.nodes["A"]:startTrip("Z","Mae"); bus:pump()
ok(bus.nodes["Cm"].gates.m1==RPM, "nether mouth flings across the portal toward D on the multi-hop trip")
ok(bus.nodes["D"].gates.c2==RPM and (bus.nodes["D"].gates.c1 or 0)==0, "D (junction) opens onward to Z, not back to A")
ok(bus.nodes["Z"]:landPad("Mae")==true, "rider delivered to Z through portal + junction")
bus:pump(); ok(not anyActive(), "multi-hop portal trip cleared end-to-end")
-- a MOUTH that reloads mid-crossing recovers the live trip from its OWN disk and re-opens (reboot-survivable)
NOW=NOW+10
bus.nodes["A"]:startTrip("D","Rin"); bus:pump()
ok(bus.nodes["Cm"].gates.m1==RPM, "nether mouth open for a fresh outbound crossing")
for _,nd in pairs(bus.nodes) do nd:unload() end                      -- the mouth cycles its chunk while everyone else is off too
NOW=NOW+2; bus.nodes["Cm"]:boot(); bus:pump()                        -- reloads ALONE: no peer answers
ok(bus.nodes["Cm"]:live()~=nil, "reloaded mouth recovered the live crossing from its OWN disk (no peer)")
ok(bus.nodes["Cm"].gates.m1==RPM, "...and re-opened its tube so the crossing rider isn't stranded")

print("== Phase 25: a TOMBSTONE removes a renamed/dead node network-wide and survives reload (programmatic cleanup) ==")
NOW=220000
bus.nodes={}
bus.nodes["A"]=makeNode("A",{c1="Hub"})
bus.nodes["Hub"]=makeNode("Hub",{c1="A",c2="B"})
bus.nodes["B"]=makeNode("B",{c1="Hub"})
for _,nd in pairs(bus.nodes) do nd:boot() end; bus:pump()
-- everyone has learned a stale ghost row for "[OP]" (an old portal pc that no longer exists under that name)
for _,nd in pairs(bus.nodes) do nd.graph["[OP]"]={"Hub"}; nd.gen["[OP]"]=NOW-50; nd:saveGraph() end
local function hasNode(nd,nm) return nd.graph[nm]~=nil end
ok(hasNode(bus.nodes["A"],"[OP]") and hasNode(bus.nodes["B"],"[OP]"), "every node has the stale ghost [OP] in its map")
-- run `forget [OP]` on ONE node; the removal gossips
NOW=NOW+1; bus.nodes["A"]:removeNode("[OP]"); bus:pump()
ok(not hasNode(bus.nodes["A"],"[OP]"), "the node that ran forget dropped [OP]")
ok(not hasNode(bus.nodes["Hub"],"[OP]") and not hasNode(bus.nodes["B"],"[OP]"), "the tombstone gossiped: every loaded node dropped [OP]")
-- the hard case: a node OFFLINE during the removal reloads with the ghost still on its own disk
NOW=NOW+1
bus.nodes["C"]=makeNode("C",{c1="Hub"})
bus.nodes["C"].files.state={ graph={ C={"Hub"}, ["[OP]"]={"Hub"} }, gen={ C=NOW-100, ["[OP]"]=NOW-100 } }
bus.nodes["C"]:boot(); bus:pump()
ok(not hasNode(bus.nodes["C"],"[OP]"), "an offline node reloading with the ghost learns the tombstone and drops it (no resurrection)")
ok(not hasNode(bus.nodes["A"],"[OP]"), "...and C re-gossiping its stale row did NOT bring [OP] back elsewhere")
-- the tombstone is durable across a reload (kept on disk)
NOW=NOW+1; bus.nodes["Hub"]:boot(); bus:pump()
ok(bus.nodes["Hub"].tombs["[OP]"]~=nil and not hasNode(bus.nodes["Hub"],"[OP]"), "the tombstone persists across a reload")
-- SAFETY: forgetting a node that is actually ALIVE - it un-tombstones itself with a fresher row
NOW=NOW+1; bus.nodes["A"]:removeNode("B"); bus:pump()
ok(not hasNode(bus.nodes["Hub"],"B"), "removing a still-alive node B momentarily drops it")
NOW=NOW+1; bus.nodes["B"]:broadcastState(); bus:pump()
ok(hasNode(bus.nodes["Hub"],"B") and bus.nodes["Hub"].tombs["B"]==nil, "live node B re-gossips a fresher row -> un-tombstoned everywhere (forget can't kill a live node)")

print("== Phase 26: firmware auto-propagation is forward-only (never downgrade, never re-push a current peer) ==")
local function verNum(v) return tonumber(tostring(v):match("v(%d+)")) or 0 end
local function shouldPush(myVer, peerVer) return verNum(peerVer) < verNum(myVer) end  -- mirror of firmware propagateTo gate
ok(shouldPush("v34","v28")==true, "a v34 node pushes to a v28 peer (older -> update)")
ok(shouldPush("v34","v33")==true, "a v34 node pushes to a v33 peer (one behind)")
ok(shouldPush("v34","v34")==false, "a v34 node does NOT push to another v34 peer (no same-version reboot storm)")
ok(shouldPush("v33","v34")==false, "a v33 node does NOT push to a v34 peer (forward-only -> no downgrade/ping-pong)")
ok(verNum("v9")<verNum("v33"), "version compare is NUMERIC (v9 < v33, not lexical)")
ok(verNum("garbage")==0 and shouldPush("v34","garbage")==true, "an unparseable peer version reads as 0 -> gets updated")

print(("\n==== %d passed, %d failed ===="):format(pass, fail))
if fail>0 then os.exit(1) end
