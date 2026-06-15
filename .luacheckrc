-- luacheck config for CC: Tweaked (ComputerCraft) programs.
-- These programs run on Lua 5.2 (Cobalt) inside Minecraft and use CC's global APIs.

std = "lua53"
max_line_length = false
codes = true

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

-- The off-game simulator is plain Lua (standard library only). It mirrors
-- ht_node.lua's logic and runs on this machine via `lua test/htsim.lua`.
files["test/*.lua"] = {
  std = "lua53",
}
