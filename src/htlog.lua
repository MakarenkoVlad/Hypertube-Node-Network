--[[
  HT Log — live network log viewer. (CC: Tweaked)
  ===========================================================================
  Run on ANY computer that has a modem (ender modem so it hears every node).
  It listens for the log messages each node broadcasts (boot/version, trips,
  routes, arrivals) and prints them as they happen, one colour per node.

  On start (and when you press P) it pings every node, so each one reports its
  firmware version immediately - the fastest way to spot a node still on old
  code.

    htlog            -- listen + show the live log
    Ctrl+T           -- quit
    P                -- ping: every node reprints its version
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

term.clear(); term.setCursorPos(1, 1)
print("=== HT network log ===  (P = ping versions, Ctrl+T = quit)")

local palette = { colors.yellow, colors.lime, colors.cyan, colors.orange, colors.magenta, colors.lightBlue, colors.pink, colors.white }
local byNode, pick = {}, 0
local function colourFor(node)
  if not byNode[node] then pick = pick % #palette + 1; byNode[node] = palette[pick] end
  return byNode[node]
end

local function line(node, ver, msg)
  term.setTextColor(colors.gray); write("[" .. textutils.formatTime(os.time(), true) .. "] ")
  term.setTextColor(colourFor(node)); write(node)
  if ver then term.setTextColor(colors.gray); write(" " .. ver) end
  term.setTextColor(colors.white); print("  " .. msg)
end

rednet.broadcast({ ping = true }, LOGPROTO)        -- ask everyone to report on startup

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "rednet_message" and ev[4] == LOGPROTO then
    local m = ev[3]
    if type(m) == "table" and m.node and m.msg then line(m.node, m.ver, m.msg) end
  elseif ev[1] == "key" and ev[2] == keys.p then
    term.setTextColor(colors.gray); print("-- ping --")
    rednet.broadcast({ ping = true }, LOGPROTO)
  end
end
