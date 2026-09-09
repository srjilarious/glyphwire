-- yoink <file>... -- rsync files back down from the "dropbox" directory
-- on a remote host into the current directory. The paired `drop` sends
-- them up.
--
-- Install as ~/.config/glyphwire/scripts/yoink.lua
--
-- Set the remote in your shell.conf (or environment):
--   sh.setenv("GW_DROPBOX", "myhost:dropbox/")
-- Each argument is appended to it, so `yoink notes.txt` fetches
-- myhost:dropbox/notes.txt.

local remote = sh.getenv("GW_DROPBOX")
if not remote or remote == "" then
  print("yoink: set GW_DROPBOX to a remote rsync target, e.g. myhost:dropbox/")
  return 1
end

local function quote(s)
  return "'" .. tostring(s):gsub("'", [["'"']]) .. "'"
end

if not arg[1] then
  print("usage: yoink <file>...")
  return 1
end

local status = 0
for i = 1, #arg do
  local src = remote .. arg[i]
  local code = sh.exec(table.concat({
    "rsync",
    "-avP",
    "--partial-dir=.rsync-partial",
    "--",
    quote(src),
    quote("."),
  }, " "))

  if code ~= 0 then
    status = code
  end
end

return status
