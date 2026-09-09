-- drop <file>... -- rsync files up to a "dropbox" directory on a remote
-- host. The paired `yoink` fetches them back.
--
-- Install as ~/.config/glyphwire/scripts/drop.lua
--
-- Set the remote in your shell.conf (or environment):
--   sh.setenv("GW_DROPBOX", "myhost:dropbox/")
-- It's passed straight to rsync, so "user@host:path/" all work. The
-- trailing slash matters -- it's the destination directory.

local remote = sh.getenv("GW_DROPBOX")
if not remote or remote == "" then
  print("drop: set GW_DROPBOX to a remote rsync target, e.g. myhost:dropbox/")
  return 1
end

local function quote(s)
  return "'" .. tostring(s):gsub("'", [["'"']]) .. "'"
end

if not arg[1] then
  print("usage: drop <file>...")
  return 1
end

local parts = {
  "rsync",
  "-avP",
  "--partial-dir=.rsync-partial",
  "--",
}

for i = 1, #arg do
  parts[#parts + 1] = quote(arg[i])
end

parts[#parts + 1] = quote(remote)

return sh.exec(table.concat(parts, " "))
