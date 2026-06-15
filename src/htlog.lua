--[[
  HT Log — live network log + firmware-version census. (CC: Tweaked)
  ===========================================================================
  Run on ANY computer with a modem (ender modem so it hears every node). It
  prints the log lines each node broadcasts (boot/version, trips, routes,
  arrivals), one colour per node, and tracks each node's firmware version.

    htlog              -- listen + show the live log
    htlog versions     -- one-shot: ping, print a version census, exit
    P                  -- ping: every node reprints its version
    V                  -- version census: which nodes are on which firmware
    Ctrl+T             -- quit

  Use V right after an OTA push (ht_push) to confirm every node updated. NOTE:
  a node whose chunk is unloaded is OFF and won't answer - load the chunks (be
  near them / travel the line) before trusting the census as complete.

  The whole session is also written to /htlog.txt. To send it for debugging:
  reproduce the issue with htlog running, then  `pastebin put /htlog.txt`  and
  share the URL. Each node also has `firmware.lua report` (a full per-node dump).
--]]

local LOGPROTO = "ht_log"

local opened = false
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.hasType(n, "modem") then rednet.open(n); opened = true end
end
if not opened then
  printError("No modem on this computer - attach one (ender modem reaches all nodes).")
  return
end

local SAVEFILE = "/htlog.txt"         -- the whole session is also written here, to send for debugging
local function save(s) pcall(function() local f = fs.open(SAVEFILE, "a"); if f then f.writeLine(s); f.close() end end) end

local palette = { colors.yellow, colors.lime, colors.cyan, colors.orange, colors.magenta, colors.lightBlue, colors.pink, colors.white }
local byNode, pick = {}, 0
local ver = {}                       -- node -> last reported firmware version string
local function colourFor(node)
  if not byNode[node] then pick = pick % #palette + 1; byNode[node] = palette[pick] end
  return byNode[node]
end
local function vnum(v) return tonumber((v or ""):match("%d+")) or 0 end   -- "v14" -> 14 (orders v9 < v14)

local function line(node, v, msg)
  if v then ver[node] = v end
  local stamp = "[" .. textutils.formatTime(os.time(), true) .. "] "
  term.setTextColor(colors.gray); write(stamp)
  term.setTextColor(colourFor(node)); write(node)
  if v then term.setTextColor(colors.gray); write(" " .. v) end
  term.setTextColor(colors.white); print("  " .. msg)
  save(stamp .. node .. (v and (" " .. v) or "") .. "  " .. msg)          -- tee to /htlog.txt
end

local function census()
  term.setTextColor(colors.white); print("-- version census --"); save("-- version census --")
  local names = {}; for n in pairs(ver) do names[#names + 1] = n end; table.sort(names)
  if #names == 0 then
    term.setTextColor(colors.gray); print("  (no node has reported yet - press P, and make sure chunks are loaded)")
    save("  (no node reported)"); term.setTextColor(colors.white); return
  end
  local newest = 0; for _, n in ipairs(names) do newest = math.max(newest, vnum(ver[n])) end
  for _, n in ipairs(names) do
    local stale = vnum(ver[n]) < newest
    term.setTextColor(colourFor(n)); write(("  %-22s"):format(n))
    term.setTextColor(stale and colors.red or colors.green); print(ver[n] .. (stale and "  <- OLD, re-push/visit" or "  ok"))
    save(("  %-22s%s%s"):format(n, ver[n], stale and "  <- OLD" or "  ok"))
  end
  term.setTextColor(colors.gray); print(("  newest seen: v%d across %d loaded node(s)"):format(newest, #names))
  save(("  newest seen: v%d across %d node(s)"):format(newest, #names))
  term.setTextColor(colors.white)
end

term.clear(); term.setCursorPos(1, 1)
local oneShot = ({ ... })[1] == "versions"
pcall(function() local f = fs.open(SAVEFILE, "w"); if f then f.writeLine("=== HT network log session ==="); f.close() end end)  -- fresh capture
print("=== HT network log ===  (P = ping, V = census, Ctrl+T = quit)")
print("logging to " .. SAVEFILE .. " - send it with:  pastebin put " .. SAVEFILE)
rednet.broadcast({ ping = true }, LOGPROTO)          -- ask everyone to report on startup
local censusTimer = os.startTimer(oneShot and 2 or 0) -- one-shot: wait, gather, then census + exit

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "rednet_message" and ev[4] == LOGPROTO then
    local m = ev[3]
    if type(m) == "table" and m.node and m.msg then
      if m.ver then ver[m.node] = m.ver end
      if not oneShot then line(m.node, m.ver, m.msg) end
    end
  elseif ev[1] == "key" and ev[2] == keys.p then
    term.setTextColor(colors.gray); print("-- ping --"); rednet.broadcast({ ping = true }, LOGPROTO)
  elseif ev[1] == "key" and ev[2] == keys.v then
    rednet.broadcast({ ping = true }, LOGPROTO); censusTimer = os.startTimer(1.5)
  elseif ev[1] == "timer" and ev[2] == censusTimer then
    census()
    if oneShot then return end
  end
end
