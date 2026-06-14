--[[
  Auto-Hub — self-configuring, interactive hypertube hub. (CC: Tweaked + Create)
  ===========================================================================
  Finds its own peripherals by what they can DO — no hardcoded sides or names:
    * tubes    = anything with setTargetSpeed     (Create Rotational Speed Controller)
    * monitor  = anything with setTextScale       (Advanced Monitor)
    * detector = anything with getPlayersInRange  (Player Detector, optional)

  It never crashes on a missing/moved part: it PROMPTS you on the computer's own
  screen to attach it and press Enter to rescan. If several monitors are present
  it asks which screen to use and remembers the choice in /hub.cfg.

  Each tube is a button. Stand on the pad, tap a tube: that controller spins up;
  the instant you leave the pad (passed through) it stops.

  COMMANDS (type at the prompt):
    startup          run normally
    startup pick     choose a different monitor
    startup name     label the tube buttons

  Deploy: pastebin get <code> startup  ->  reboot.
--]]

local RPM         = 32     -- launch RPM (<= 256)
local RUN_SECONDS = 20     -- safety cap; normally stops the moment you leave the pad
local CFG         = "/hub.cfg"

local args = { ... }

-- ---- discovery (by capability) -------------------------------------------
local function findAll(test)
  local list = {}
  for _, n in ipairs(peripheral.getNames()) do
    local ok, p = pcall(peripheral.wrap, n)
    if ok and p and test(n, p) then list[#list + 1] = { wrap = p, name = n } end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local isMonitor  = function(_, p) return p.setTextScale ~= nil end
local isTube     = function(_, p) return p.setTargetSpeed ~= nil end
local isDetector = function(_, p) return p.getPlayersInRange ~= nil end

-- ---- remembered config ---------------------------------------------------
local function loadCfg()
  if fs.exists(CFG) then
    local f = fs.open(CFG, "r"); local raw = f.readAll(); f.close()
    local d = textutils.unserialize(raw or "")
    if type(d) == "table" then return d end
  end
  return {}
end
local function saveCfg(t)
  pcall(function()
    local f = fs.open(CFG, "w"); f.write(textutils.serialize(t)); f.close()
  end)
end

-- ---- interactive pickers (prompt only when needed) -----------------------
local function pickMonitor(cfg)
  -- reuse the remembered screen if it's still present
  if cfg.monitor and peripheral.isPresent(cfg.monitor)
     and peripheral.hasType(cfg.monitor, "monitor") then
    return peripheral.wrap(cfg.monitor), cfg.monitor
  end
  while true do
    local mons = findAll(isMonitor)
    if #mons == 0 then
      print("No monitor found. Attach an Advanced Monitor (or its wired modem),")
      write("then press Enter to rescan... "); read()
    elseif #mons == 1 then
      cfg.monitor = mons[1].name; saveCfg(cfg)
      return mons[1].wrap, mons[1].name
    else
      print("Which screen should the hub use?")
      for i, m in ipairs(mons) do
        local ok, w, h = pcall(m.wrap.getSize)
        print(("  %d) %s  (%sx%s)"):format(i, m.name, ok and w or "?", ok and h or "?"))
      end
      write("Number: ")
      local n = tonumber(read())
      if n and mons[n] then
        cfg.monitor = mons[n].name; saveCfg(cfg)
        return mons[n].wrap, mons[n].name
      end
    end
  end
end

local function getTubes()
  while true do
    local t = findAll(isTube)
    if #t > 0 then return t end
    print("No speed controllers found. Attach each RSC's wired modem")
    write("(right-click until the ring is red), then press Enter to rescan... "); read()
  end
end

-- ---- boot / setup --------------------------------------------------------
term.clear(); term.setCursorPos(1, 1)
print("=== Hypertube Auto-Hub ===")
local cfg = loadCfg()
if args[1] == "pick" then cfg.monitor = nil end   -- force re-choose

local tubes = getTubes()

if args[1] == "name" then                          -- label tubes, then exit
  cfg.names = cfg.names or {}
  print(("Label %d tubes (Enter keeps current):"):format(#tubes))
  for i = 1, #tubes do
    write(("Tube %d [%s]: "):format(i, cfg.names[i] or "-"))
    local s = read()
    if s and s ~= "" then cfg.names[i] = s end
  end
  saveCfg(cfg); print("Saved. Run 'startup' to launch."); return
end

local mon, monName = pickMonitor(cfg)
local det = findAll(isDetector)[1]
local detector = det and det.wrap or nil
local NAMES = cfg.names or {}
mon.setTextScale(1)
print(("Monitor: %s | Tubes: %d | Detector: %s"):format(monName, #tubes, detector and "yes" or "no"))

-- ---- helpers -------------------------------------------------------------
local function tubeName(i) return NAMES[i] or ("Tube " .. i) end

local function someoneOnPad()
  if not detector then return true end
  local ok, players = pcall(detector.getPlayersInRange, 2)
  return ok and type(players) == "table" and players[1] ~= nil
end

local function allStop()
  for _, t in ipairs(tubes) do pcall(t.wrap.setTargetSpeed, 0) end
end

-- ---- UI ------------------------------------------------------------------
local rowFor = {}
local function draw(status, color)
  rowFor = {}
  mon.setBackgroundColor(colors.black); mon.clear()
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.blue); mon.setCursorPos(1, 1); mon.clearLine()
  mon.setTextColor(colors.white); mon.setCursorPos(2, 1); mon.write("HYPERTUBE HUB")
  local y = 3
  for i = 1, #tubes do
    mon.setBackgroundColor(colors.green); mon.setTextColor(colors.white)
    mon.setCursorPos(2, y)
    local label = " " .. tubeName(i)
    mon.write(label .. string.rep(" ", math.max(0, w - 2 - #label)))
    rowFor[y] = i; rowFor[y + 1] = i
    y = y + 2
  end
  mon.setBackgroundColor(colors.black); mon.setTextColor(color or colors.lightGray)
  mon.setCursorPos(1, h); mon.write((status or "Tap a tube"):sub(1, w))
end

-- ---- run -----------------------------------------------------------------
allStop()
local idle = "Stand on the pad, tap a tube"
draw(idle)

local active, fallback, poll = nil, nil, nil
local function reset(msg) active = nil; allStop(); draw(msg or idle) end

while true do
  local ev = { os.pullEvent() }
  local e = ev[1]
  if e == "monitor_touch" and ev[2] == monName then   -- only our chosen screen
    local i = rowFor[ev[4]]
    if i and not active then
      if not someoneOnPad() then
        draw("Step onto the pad first", colors.orange)
      else
        allStop()
        tubes[i].wrap.setTargetSpeed(RPM)              -- spin only the chosen tube
        active = i
        fallback = os.startTimer(RUN_SECONDS)
        poll = os.startTimer(0.4)
        draw("Departing: " .. tubeName(i), colors.lime)
      end
    end
  elseif e == "timer" and active then
    if ev[2] == poll then
      if someoneOnPad() then
        poll = os.startTimer(0.4)                       -- still boarding; keep spinning
      else
        reset("Sent " .. tubeName(active))              -- passed through -> stop
      end
    elseif ev[2] == fallback then
      reset()                                            -- safety stop
    end
  end
end
