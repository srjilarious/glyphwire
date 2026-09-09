-- up [N] -- change this glyphwire shell N parent directories upward.
--
-- Install as ~/.config/glyphwire/scripts/up.lua, then run:
--   up 3

local n_arg = arg[1]
local n = 1

if n_arg and n_arg ~= "" then
  if not n_arg:match("^%d+$") then
    print("usage: up [N]")
    return 1
  end
  n = tonumber(n_arg)
end

if n > 1024 then
  print("up: N is too large")
  return 1
end

local target
if n == 0 then
  target = "."
else
  local parts = {}
  for i = 1, n do
    parts[i] = ".."
  end
  target = table.concat(parts, "/")
end

if not sh.chdir(target) then
  print("up: could not chdir: " .. target)
  return 1
end

return 0
