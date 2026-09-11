# glyphwire-shell script builtins

The `.lua` files here are example *script builtins* -- drop the ones you
want into `~/.config/glyphwire/scripts/` and they become commands:

```
cp *.lua ~/.config/glyphwire/scripts/
```

| script | what it does |
|---|---|
| `up.lua` | `up [N]` -- `cd` this shell N directories toward the root (default 1). |
| `venv_activate.lua` / `venv_deactivate.lua` | activate / deactivate a Python virtualenv for the session (see below). |
| `drop.lua` / `yoink.lua` | `rsync` files to / from a "dropbox" directory on a remote host. Set the target with `sh.setenv("GW_DROPBOX", "myhost:dropbox/")` in `shell.conf`. |
| `provision_remote.lua` | `provision_remote <user@host> [ssh options...]` -- build and copy the remote-side glyphwire programs to a real server for `glyphwire --ssh` (see below). |

## How script builtins work

glyphwire-shell keeps one Lua state for the whole session. `shell.conf`
runs in it, and so does every *script builtin*. A builtin is:

- a `defcmd(name, fn)` registration in `shell.conf`, or
- a file `~/.config/glyphwire/scripts/<name>.lua`, looked up by basename
  and re-read on every call (so editing it takes effect immediately).

Dispatch precedence: **core builtins** (`cd`, `exit`, `alias`, `unalias`)
> **aliases** > **script builtins** > **`$PATH`**. A `cd.lua` can't
shadow the real `cd`; a `ls.lua` does shadow `/usr/bin/ls`.

## What a script sees

| | |
|---|---|
| `arg` | `arg[0]` is the command name, `arg[1..]` the positional arguments. The same values also arrive as `...`. |
| return value | a number is the exit status (`$?`); anything else is `0`. |
| `print`, `io.write` | go to the terminal. |
| `os.exit` | disabled -- it would kill the shell; calling it raises a catchable error. |
| `require` | finds modules under `~/.config/glyphwire/scripts/lib/`. |
| `os.execute`, `io.popen` | work, but run a real subprocess outside the grid. |

### The `sh` table

| call | effect |
|---|---|
| `sh.setenv(name, value)` | set a variable for this shell **and every command it launches afterwards** |
| `sh.unsetenv(name)` | remove one |
| `sh.getenv(name)` | the shell's live value (script-set values included), or `nil` |
| `sh.cwd()` | absolute working directory |
| `sh.realpath(path)` | canonical absolute path, or `nil` if it doesn't resolve on disk |
| `sh.chdir(path)` | change this shell's working directory; `true`/`false` |
| `sh.exec(line)` | run `line` (pipes, `&&`/`\|\|`/`;`, quoting -- the same parser a typed command gets) with output streamed straight to the grid; returns just the exit status |
| `sh.run(line, stdin?)` | like `sh.exec`, but captures output instead of drawing it: returns `{code, ok, out, err}`. `stdin`, if given, feeds the first stage |

Everything else a script needs -- path joining, reading a file, string
work -- is in Lua's standard library.

A runaway script is stopped by **Ctrl-C**, or a **30s wall-clock
ceiling** if no key is coming.

## The venv example

```
cp venv_activate.lua venv_deactivate.lua ~/.config/glyphwire/scripts/
```

Then:

```
venv_activate .venv
python -m pip install ...
venv_deactivate
```

`venv_activate` sets `$VIRTUAL_ENV` and puts `<venv>/bin` first on
`$PATH`, so `python` / `pip` resolve inside the venv. A prompt segment
keyed on `{env:VIRTUAL_ENV}` shows it with no extra wiring, e.g.:

```lua
prompt {
  right_segments = {
    { " {env:VIRTUAL_ENV} ", when = "{env:VIRTUAL_ENV}", fg = "#fff", bg = "#3a6ea5" },
  },
}
```

## The provision_remote example

```
cp provision_remote.lua ~/.config/glyphwire/scripts/
```

From a glyphwire-shell session sitting in a glyphwire checkout:

```
provision_remote myuser@myhost
```

This runs `zig build install-local` and streams the result (`bin/` +
`share/glyphwire/`) to `~/.local/share/glyphwire` on the remote over
`tar | ssh` -- no scp, so a port/identity flag given after the
destination (`provision_remote myuser@myhost -p 2222`) only has to be
spelled the ssh way. It then drops `shell.conf` / `zoe.conf` from this
repo's templates onto the remote *only if it doesn't already have one*.
Binaries are always overwritten; run it again any time you want the
remote caught up with a local rebuild.

It needs passwordless ssh (key or agent) to the target already working --
see the script's header comment for why. The command it prints at the
end is what to hand `glyphwire --ssh` (see docs/decisions.md's "Remote
sessions" section, and `docker/remote-test/` for trying the same flow
against a disposable local container instead of a real server).
