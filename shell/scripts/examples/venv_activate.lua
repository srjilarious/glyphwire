-- venv_activate <path> -- activate a Python virtualenv for this shell
-- session and every command it launches. Mirrors what bash's
-- `bin/activate` does: point $VIRTUAL_ENV at the venv, put its bin/ first
-- on $PATH, and drop $PYTHONHOME. `venv_deactivate` reverses it.
--
-- Copy this file to  ~/.config/glyphwire/scripts/venv_activate.lua

local target = arg[1]
if not target or target == "" then
  print("usage: venv_activate <path-to-venv>")
  return 1
end

local root = sh.realpath(target)
if not root then
  print("venv_activate: no such directory: " .. target)
  return 1
end

-- pyvenv.cfg is the definitive "this is a virtualenv" marker.
local cfg = io.open(root .. "/pyvenv.cfg", "r")
if not cfg then
  print("venv_activate: not a virtualenv (no pyvenv.cfg): " .. root)
  return 1
end
cfg:close()

-- Step out of any current venv first so bin/ dirs don't stack on $PATH.
local current = sh.getenv("VIRTUAL_ENV")
if current then
  local path = sh.getenv("PATH") or ""
  local prefix = current .. "/bin:"
  if path:sub(1, #prefix) == prefix then
    sh.setenv("PATH", path:sub(#prefix + 1))
  end
end

sh.setenv("VIRTUAL_ENV", root)
sh.setenv("PATH", root .. "/bin:" .. (sh.getenv("PATH") or ""))
sh.unsetenv("PYTHONHOME")

-- A prompt segment keyed on {env:VIRTUAL_ENV} picks this up on the next
-- redraw -- no prompt cooperation needed beyond reading the variable.
print("activated " .. root)
