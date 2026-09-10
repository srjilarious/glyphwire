# glyphwire-shell script builtins

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
