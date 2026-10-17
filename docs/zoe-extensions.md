<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# zoe extensions

A zoe extension is a Lua 5.3 script that adds named **commands** to the
editor. A command shows up in the command palette (Ctrl+Shift+P), and
`keys` can bind it like any built-in action. zoe ships one extension,
`task_journal`. You can write your own the same way.

## Turning one on

Extensions are opt-in. `zoe.conf.lua` names each one, with an options
table:

```lua
config = {
    extensions = {
        task_journal = { tags = { "MGMT", "BUG" } },
        -- or by name alone, for no options: extensions = { "task_journal" }
        -- `name = false` turns one off without deleting its entry.
    },
    keys = {
        normal = { ["ctrl+t"] = "taskToggle" },
    },
}
```

An extension `<name>` is loaded from
`<config dir>/zoe/extensions/<name>.lua` (usually
`~/.config/glyphwire/zoe/extensions/`) when that file exists, and
otherwise from the copy built into zoe. To change a built-in extension,
copy `zoe/extensions/<name>.lua` into that directory and edit the copy.

Each extension runs once, at startup, after the window is up. A problem
while loading it, such as a missing file, a syntax error or a bad
option, is logged. The first such problem is also shown in the
statusline. zoe starts either way.

To see what zoe found, run `:extensions` (or "List Extensions" from the
palette). It lists every built-in extension and every `.lua` file in
the user directory, plus any name `config.extensions` gives that matches
neither. Each row shows where the extension comes from (built in, a
user file, or a user file replacing a built-in one) and its status:

| Status | Meaning |
|---|---|
| loaded, N commands | It ran and registered N commands. |
| not enabled | It exists, but `config.extensions` doesn't name it. |
| turned off | `config.extensions` has `name = false`. |
| failed | It raised an error while loading. The error is on the row below. |
| not found | `config.extensions` names it, but there is no such file and no built-in one. |

The header shows the directory zoe reads user files from, so a file saved
somewhere else is easy to spot. Enter (or a click) on an extension with a
user file opens that file. Escape closes the list.

## Writing one

The file is a plain Lua chunk. Its options table arrives as `...`, and it
registers commands through the global `zoe` table:

```lua
local opts = ... or {}
local suffix = opts.suffix or "!"

zoe.command("shout", function()
    zoe.set_line(zoe.line():upper() .. suffix)
end, "Shout the Current Line")

zoe.bind("normal", "ctrl+alt+s", "shout")
```

The standard Lua libraries are all available (`io`, `os`, `string`, ...),
except `os.exit`, which would close zoe without asking about unsaved
buffers. `zoe` adds what Lua's standard library lacks.

### Commands and keys

| Function | |
|---|---|
| `zoe.command(name, fn [, label])` | Registers `fn` as command `name`. `name` is letters, digits, `_` and `.`, and must start with a letter. It may not repeat another command's name or a built-in action's. `label` is the palette's text; without one the name is split into words. |
| `zoe.bind(scope, chord, name)` | Binds `chord` to command `name` in key table `scope` (`"global"`, `"normal"`, `"visual"`, `"insert"`). This is the extension's default, and the config's `keys` override it. |

Both may only be called while the extension loads, not from inside a
command.

### The focused buffer

These act on the buffer that has the keyboard. When the file tree has it
they raise an error, except `zoe.path`, which returns nil. Line numbers
are 1-based.

| Function | |
|---|---|
| `zoe.line([n])` | Line `n`'s text (default: the cursor's line), without its newline. |
| `zoe.set_line([n,] text)` | Replaces line `n` (default: the cursor's line). `text` may not contain a line break. Only the bytes that changed are rewritten, so the cursor stays on the same character when the change is elsewhere on the line. |
| `zoe.line_count()` | The number of lines. |
| `zoe.cursor()` | The cursor's line and byte column, both 1-based. |
| `zoe.path()` | The buffer's file as an absolute path, or nil. |

Everything one command changes in a buffer is a single undo step, however
many lines it touched.

### Files and the window

| Function | |
|---|---|
| `zoe.open(path)` | Opens `path` in a tab, or switches to the tab already showing it. `~` is expanded. A file that doesn't exist opens empty, as with `:e`. The keyboard moves to the buffer. |
| `zoe.message(text)` | Shows `text` in the statusline. |
| `zoe.expand(path)` | Returns `path` with a leading `~` expanded to `$HOME`. |
| `zoe.exists(path)` | Returns true when anything exists at `path`. |
| `zoe.mkdir(path)` | Creates `path` and any missing parents. Returns `true`, or `nil, err`. |
| `zoe.list_dir(path)` | Returns a sorted list of the names in directory `path` (files and directories, without `.` and `..`), or `nil, err`. |

### Errors and limits

A command that raises an error stops, and `<command>: <message>` appears
in the statusline. The errors raised by `zoe.*` functions say which
function raised them. Use `error(msg, 0)` to keep Lua's file-and-line
prefix off your own messages.

zoe runs commands on its only thread. A command that runs past about 50
million VM instructions, which in practice means a loop that never ends,
is stopped with "ran too long and was stopped" instead of freezing the
window.

## How it fits together

- `zoe/ext.zig`: the runtime. It owns the Lua state, implements the
  `zoe` table, keeps the command registry and the extension bindings, and
  runs each call in protected mode under the instruction budget.
- `zoe/langconf.zig`: zoe's config parse. It keeps the config's source
  text, plus every `keys` entry whose name isn't a built-in action
  (`command_keys`), because those may name extension commands.
- `zoe/ui.zig`: `startExtensions` builds the runtime once the first
  buffer exists. `extCommandFor` looks up keys: a mode's own table is read
  before `global`, with extension and built-in bindings checked together.
  The palette lists commands after the actions.
- `zoe/extlist.zig`: the `:extensions` popup. The runtime records what
  came of each name in `config.extensions` (`Runtime.enabled`), and
  `extlist.build` merges that with the built-in names and the user
  directory's files.

The runtime runs `zoe.conf.lua` a second time, in its own long-lived
state, to read `config.extensions` with the options intact. zoe's own
config parse closes its Lua state as soon as it has read the plain
values.

Key precedence, from highest to lowest:

1. a `keys` entry naming a command;
2. a `keys` entry naming a built-in action, or `false`, which takes the
   chord back from an extension's binding;
3. an extension's `zoe.bind`;
4. zoe's built-in defaults.
