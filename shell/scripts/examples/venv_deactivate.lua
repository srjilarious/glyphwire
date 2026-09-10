-- venv_deactivate -- undo venv_activate for this shell session: strip the
-- venv's bin/ back off $PATH and clear $VIRTUAL_ENV / $PYTHONHOME.
--
-- Copy this file to  ~/.config/glyphwire/scripts/venv_deactivate.lua

local venv = sh.getenv("VIRTUAL_ENV")
if not venv then
  print("venv_deactivate: no active virtualenv")
  return 0
end

-- venv_activate always prepends exactly "<venv>/bin:", so removing that
-- prefix restores $PATH without needing a saved copy.
local path = sh.getenv("PATH") or ""
local prefix = venv .. "/bin:"
if path:sub(1, #prefix) == prefix then
  sh.setenv("PATH", path:sub(#prefix + 1))
end

sh.unsetenv("VIRTUAL_ENV")
sh.unsetenv("PYTHONHOME")
print("deactivated " .. venv)
