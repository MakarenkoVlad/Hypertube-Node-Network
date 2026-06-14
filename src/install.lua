--[[
  Hypertube Network — Installer (run this ON a fresh in-game computer)
  CC: Tweaked + Create: Hypertubes  |  NeoForge 1.21.1
  ===========================================================================
  Turns the per-node deploy bundle (firmware + generated config) into a ready
  `startup` on this computer, in one command — no hand-editing the config block.

  It gets the files from EITHER:
    * a deploy DISK  — a floppy holding the firmware and config (default), or
    * a URL          — raw repo / pastebin-hosted files (`--url <base>`).
  Then it splices this node's config into the firmware (between the @HT-CONFIG
  markers), writes `/startup`, labels the computer, and offers to reboot.

  Build the bundle off-game first:
      lua tools/build_routes.lua config/network.example.lua            # config blocks
      lua tools/build_routes.lua config/network.example.lua --startup  # + ready startups
  Put on the disk (any of these layouts works):
      hypertube_node.lua  +  nodes/<node>.lua            (installer splices)
      config/generated/<node>.lua  (and optional <node>.startup.lua bundles)

  Usage (run on the computer):
      install                 pick this node from a menu (disk)
      install <node>          install a named node
      install --src /disk     use a specific directory as the bundle
      install --url <base>    fetch firmware+config over HTTP from <base>
--]]

local args = { ... }

-- Optional: hard-code a default HTTP base (raw repo URL) so `install <node>`
-- works with no disk. Leave "" to use a disk / --src by default.
local DEFAULT_URL = ""

local START_MARK, END_MARK = "@HT-CONFIG-START", "@HT-CONFIG-END"
local FIRMWARE_NAME = "hypertube_node.lua"
local FW_SUBDIRS   = { "", "src", "hypertube", "hypertube/src" }
local LIST_SUBDIRS = { "nodes", "config/generated", "hypertube/nodes", "hypertube/config/generated" }
local CFG_SUBDIRS  = { "nodes", "config/generated", "hypertube/nodes", "hypertube/config/generated", "" }

local USAGE = "install [<node>] [--src <dir>] [--url <base>]"

-- ---- small fs/http/string helpers ----------------------------------------
local function join(a, b)
  if a == "" then return b elseif b == "" then return a end
  return (a:gsub("/+$", "")) .. "/" .. b
end

local function readAll(path)
  local h = fs.open(path, "r"); if not h then return nil end
  local data = h.readAll(); h.close(); return data
end

local function writeAll(path, data)
  local h = fs.open(path, "w")
  if not h then error("cannot write " .. path, 0) end
  h.write(data); h.close()
end

local function httpGet(url)
  if not http then error("HTTP is disabled on this computer — use a disk, or enable http in the CC config", 0) end
  local h = http.get(url); if not h then return nil end
  local data = h.readAll(); h.close(); return data
end

local function splitLines(s)
  local t = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = line end
  return t
end

local function findUnder(base, subdirs, filename)
  for _, sub in ipairs(subdirs) do
    local p = join(join(base, sub), filename)
    if fs.exists(p) and not fs.isDir(p) then return p end
  end
  return nil
end

-- replace everything between the firmware's @HT-CONFIG markers with `block`,
-- keeping the marker lines. Identical algorithm to tools/build_routes.lua.
local function splice(firmware, block)
  local lines = splitLines(firmware)
  local s, e
  for i, line in ipairs(lines) do
    if not s and line:find(START_MARK, 1, true) then s = i end
    if not e and line:find(END_MARK, 1, true) then e = i end
  end
  if not s or not e or s >= e then
    error("firmware is missing the " .. START_MARK .. " / " .. END_MARK .. " markers", 0)
  end
  local out = {}
  for i = 1, s do out[#out + 1] = lines[i] end
  for _, bl in ipairs(splitLines(block)) do out[#out + 1] = bl end
  for i = e, #lines do out[#out + 1] = lines[i] end
  return table.concat(out, "\n")
end

-- ---- where to get the bundle ---------------------------------------------
local function findDiskBase()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local d = peripheral.wrap(name)
      local ok, mount = pcall(function() return d.getMountPath() end)
      if ok and mount and findUnder("/" .. mount, FW_SUBDIRS, FIRMWARE_NAME) then
        return "/" .. mount
      end
    end
  end
  return nil
end

local function listNodes(base)
  local seen, ids = {}, {}
  for _, sub in ipairs(LIST_SUBDIRS) do
    local dir = join(base, sub)
    if fs.exists(dir) and fs.isDir(dir) then
      for _, fn in ipairs(fs.list(dir)) do
        local id = fn:match("^(.-)%.startup%.lua$") or fn:match("^(.-)%.lua$")
        if id and fn ~= FIRMWARE_NAME and not seen[id] then
          seen[id] = true; ids[#ids + 1] = id
        end
      end
    end
  end
  table.sort(ids)
  return ids
end

-- a "source" exposes: startupBundle(node), firmware(), config(node), list()
local function dirSource(base)
  local hasFw = findUnder(base, FW_SUBDIRS, FIRMWARE_NAME) ~= nil
  local ids = listNodes(base)
  if not hasFw and #ids == 0 then return nil end
  return {
    startupBundle = function(node)
      local p = findUnder(base, CFG_SUBDIRS, node .. ".startup.lua")
      return p and readAll(p) or nil
    end,
    firmware = function()
      local p = findUnder(base, FW_SUBDIRS, FIRMWARE_NAME)
      return p and readAll(p) or error("firmware " .. FIRMWARE_NAME .. " not found under " .. base, 0)
    end,
    config = function(node)
      local p = findUnder(base, CFG_SUBDIRS, node .. ".lua")
      return p and readAll(p) or nil
    end,
    list = function() return ids end,
  }
end

local function urlSource(base)
  base = base:gsub("/+$", "")
  return {
    startupBundle = function(node)
      return httpGet(base .. "/config/generated/" .. node .. ".startup.lua")
          or httpGet(base .. "/nodes/" .. node .. ".startup.lua")
    end,
    firmware = function()
      return httpGet(base .. "/src/" .. FIRMWARE_NAME)
          or httpGet(base .. "/" .. FIRMWARE_NAME)
          or error("could not download firmware from " .. base, 0)
    end,
    config = function(node)
      return httpGet(base .. "/config/generated/" .. node .. ".lua")
          or httpGet(base .. "/nodes/" .. node .. ".lua")
    end,
    list = function() return nil end,    -- can't enumerate over plain HTTP
  }
end

-- ---- main ----------------------------------------------------------------
local function parseArgs(a)
  local opt = { positional = {} }
  local i = 1
  while i <= #a do
    local x = a[i]
    if x == "--url" then i = i + 1; opt.url = a[i]
    elseif x == "--src" then i = i + 1; opt.src = a[i]
    elseif x == "-h" or x == "--help" then opt.help = true
    else opt.positional[#opt.positional + 1] = x end
    i = i + 1
  end
  return opt
end

local function chooseNode(opt, src)
  if opt.positional[1] then return opt.positional[1] end
  local label = os.getComputerLabel()
  if label and label ~= "" then return label end
  local ids = src.list()
  if ids and #ids > 0 then
    print("Which node is this computer?")
    for i, id in ipairs(ids) do print(("  %d) %s"):format(i, id)) end
    write("Number or name: ")
    local ans = read()
    return (tonumber(ans) and ids[tonumber(ans)]) or ans
  end
  write("Node id to install: ")
  return read()
end

local function main()
  local opt = parseArgs(args)
  if opt.help then print(USAGE); return end

  local src
  if opt.url or DEFAULT_URL ~= "" then
    src = urlSource(opt.url or DEFAULT_URL)
  else
    src = dirSource(opt.src or findDiskBase() or ".")
    if not src then
      error("no deploy bundle found — insert the disk, or pass --src <dir> / --url <base>", 0)
    end
  end

  local node = chooseNode(opt, src)
  if not node or node == "" then error("no node id given", 0) end

  -- prefer a pre-built startup bundle; otherwise splice firmware + config
  local startup = src.startupBundle(node)
  if not startup then
    local block = src.config(node)
    if not block then error("no config or startup for node '" .. node .. "' in this bundle", 0) end
    startup = splice(src.firmware(), block)
  end

  if fs.exists("/startup") then
    write("/startup already exists — overwrite? (y/N) ")
    if read():lower() ~= "y" then print("Aborted; nothing written."); return end
  end

  writeAll("/startup", startup)
  os.setComputerLabel(node)
  print("Installed node '" .. node .. "' -> /startup  (label set to '" .. node .. "').")
  write("Reboot now? (Y/n) ")
  local ans = read()
  if ans == "" or ans:lower() == "y" then os.reboot() end
end

local ok, err = pcall(main)
if not ok then printError(tostring(err)) end
