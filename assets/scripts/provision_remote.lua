-- provision_remote <user@host> [ssh options...] -- build this checkout's
-- remote-side glyphwire programs (gw-agent, gw-shell, gw-ls, gw-view,
-- zoe) and copy them to a real remote server over ssh, then drop
-- shell.conf / zoe.conf there from the bundled templates if the remote
-- doesn't already have one of its own.
--
-- Install as ~/.config/glyphwire/scripts/provision_remote.lua, then from
-- a glyphwire-shell session whose current directory is a glyphwire
-- checkout:
--
--   provision_remote myuser@myhost
--   provision_remote myuser@myhost -p 2222
--
-- Anything after the destination is forwarded to every ssh call this
-- makes -- port, identity file, whatever you'd normally pass to ssh.
--
-- Requires: this shell's cwd is a glyphwire checkout (`build.zig.zon`
-- present), `zig` on PATH, and passwordless ssh (a key already
-- authorized, or an agent) to the target. This runs ssh as a plain
-- subprocess with no password-prompt UI of its own -- unlike glyphwire
-- --ssh's in-window askpass, a password prompt here has nowhere to go. A
-- hung prompt is stopped the same way a hung typed command would be:
-- Ctrl-C.
--
-- Binaries always get overwritten (the point is "latest"); the two
-- config files are only ever created, never touched if already there.
--
-- Built with `-Dcpu=baseline` -- a plain `zig build` tunes for *this*
-- machine's exact CPU, and a remote box with an older or just different
-- CPU (very plausible: a VM whose hypervisor exposes a generic virtual
-- CPU, older server hardware, ...) can flat out crash on the first
-- instruction it doesn't recognize ("Illegal instruction", not a hang or
-- a clean error). `baseline` costs a little raw throughput -- for a
-- shell/RPC/PTY workload like this one, expect nothing you'd notice
-- interactively; the one place it could show up is decode-heavy work on
-- a large image in gw-view. Know your fleet is uniform, recent hardware
-- and want the speed back anyway? `GW_PROVISION_CPU=native
-- provision_remote ...` (or a specific `-Dcpu` value, e.g. `x86_64_v3`).
--
-- Afterwards, run the host with the printed command, e.g.:
--   glyphwire --ssh myuser@myhost --remote-command ~/.local/share/glyphwire/bin/gw-agent

local dest = arg[1]
if not dest or dest == "" then
  print("usage: provision_remote <user@host> [ssh options...]")
  return 1
end

local ssh_opts = {}
for i = 2, #arg do
  ssh_opts[#ssh_opts + 1] = arg[i]
end
local ssh_opts_str = table.concat(ssh_opts, " ")

-- Single-quotes `s` for our *own* shell's word-splitting, so it reaches
-- ssh (and, through it, the remote shell) as exactly one argument --
-- without this a `&&` or `|` inside a remote command would be parsed by
-- this shell instead of shipped over to run remotely.
local function quote(s)
  return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

-- Builds one `ssh <opts> <dest> '<remote_cmd>'` string. Returning a
-- string (not running it) lets the tar copy below embed this as the
-- write side of a local `| ssh ...` pipeline.
local function ssh_cmd(remote_cmd)
  local words = { "ssh" }
  if ssh_opts_str ~= "" then words[#words + 1] = ssh_opts_str end
  words[#words + 1] = quote(dest)
  words[#words + 1] = quote(remote_cmd)
  return table.concat(words, " ")
end

local function remote_run(remote_cmd, stdin)
  return sh.run(ssh_cmd(remote_cmd), stdin)
end

local function remote_exists(path)
  return remote_run("test -f " .. path).ok
end

-- Reads a local template and, only if the remote doesn't already have
-- one at `remote_path`, writes it there via `cat > path` fed the file's
-- content on stdin -- no scp needed, same trick the binary copy below
-- uses for `tar`.
local function push_config_if_missing(local_path, remote_path, label)
  if remote_exists(remote_path) then
    print("provision_remote: " .. label .. " already exists remotely, leaving it")
    return
  end
  local f = io.open(local_path, "rb")
  if not f then
    print("provision_remote: couldn't read " .. local_path .. " -- skipping " .. label)
    return
  end
  local content = f:read("a")
  f:close()
  if remote_run("cat > " .. remote_path, content).ok then
    print("provision_remote: installed default " .. label)
  else
    print("provision_remote: couldn't write " .. remote_path)
  end
end

if not sh.realpath("build.zig.zon") then
  print("provision_remote: run this from a glyphwire checkout (no build.zig.zon in " .. sh.cwd() .. ")")
  return 1
end

local cpu = sh.getenv("GW_PROVISION_CPU")
if not cpu or cpu == "" then cpu = "baseline" end

local dist = ".provision-dist"
print("provision_remote: zig build install-local -Dcpu=" .. cpu .. " -p " .. dist .. " ...")
local build_code = sh.exec("zig build install-local -Dcpu=" .. cpu .. " -p " .. dist)
if build_code ~= 0 then
  print("provision_remote: build failed (exit " .. build_code .. ")")
  return build_code
end

if not remote_run("mkdir -p ~/.local/share/glyphwire ~/.config/glyphwire").ok then
  print("provision_remote: couldn't create remote directories on " .. dest)
  return 1
end

print("provision_remote: copying bin/ + share/glyphwire/ to " .. dest .. ":~/.local/share/glyphwire ...")
local copy_code = sh.exec(
  "tar -C " .. dist .. " -cf - bin share | " .. ssh_cmd("tar -C ~/.local/share/glyphwire -xf -")
)
if copy_code ~= 0 then
  print("provision_remote: copy failed (exit " .. copy_code .. ")")
  return copy_code
end

push_config_if_missing("shell/shell.conf.template", "~/.config/glyphwire/shell.conf", "shell.conf")
push_config_if_missing("zoe/zoe.conf.template", "~/.config/glyphwire/zoe.conf", "zoe.conf")

print("provision_remote: done. Try:")
print("  glyphwire --ssh " .. dest .. " --remote-command ~/.local/share/glyphwire/bin/gw-agent"
  .. (ssh_opts_str ~= "" and (" -- " .. ssh_opts_str) or ""))

return 0
