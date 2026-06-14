-- luacheck config for CC: Tweaked (ComputerCraft) programs.
-- These programs run on Lua 5.2 (Cobalt) inside Minecraft and use CC's global APIs.

std = "lua53"
max_line_length = false
codes = true

-- Generated per-node blocks are config FRAGMENTS to paste into the firmware's
-- CONFIG section, not standalone programs — their locals are "unused" in
-- isolation. They're a build artifact (git-ignored); don't lint them.
exclude_files = { "config/generated" }

-- CC: Tweaked global APIs (read-only from our code's perspective)
read_globals = {
  "os", "term", "peripheral", "redstone", "rs", "fs", "shell", "http",
  "textutils", "colors", "colours", "keys", "vector", "paintutils", "window",
  "multishell", "settings", "parallel", "rednet", "gps", "disk", "commands",
  "turtle", "pocket", "io", "read", "sleep", "write", "printError", "_HOST",
  "_CC_DEFAULT_SETTINGS",
}

-- Each program is a single startup file with a long-lived event loop; allow it.
files["src/*.lua"] = {
  ignore = {
    "542",  -- empty if branch (occasional guard clauses)
  },
}

-- Off-game build tooling: plain Lua (standard io/os), NOT CC firmware. It reads
-- its CLI args via `...`, so no extra globals are needed beyond the lua53 std.
files["tools/*.lua"] = {
  std = "lua53",
}
