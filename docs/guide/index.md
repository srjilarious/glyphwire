<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Using glyphwire

These guides walk through each program in the glyphwire suite: what it is
for, what you see on screen, how to drive it, where to find every command
and what its config file lets you change. They are written for someone
sitting in front of a glyphwire window, not for someone writing a client;
the [protocol spec](../protocol.md) and [API reference](../api.md) cover
that side.

![gw-shell with the example powerline prompt, a gw-ls listing and a failed command](../images/shell.png)

## The guides

| Guide | What it covers |
|---|---|
| [The window](glyphwire.md) | `glyphwire` itself: contexts and the context switcher, themes, selection and the clipboard, fonts, `host.conf.lua` and `theme.lua` |
| [gw-shell](gw-shell.md) | The shell every window starts in: history, completion, the prompt, aliases and Lua scripts |
| [zoe](zoe.md) | The editor: modes, the command palette, splits, workspaces, language servers, key bindings, extensions |
| [gmux](gmux.md) | The multiplexer: the prefix key, splitting and moving panes, the palette and layout mode |
| [salacommander](salacommander.md) | The two-pane file manager: function keys, tabs, root operations, open actions |
| [gwmd](gwmd.md) | The Markdown reader |
| [gw-read](gw-read.md) | The comic and manga reader: sizing, OCR text, dictionary lookup, Anki cards |
| [Small tools](tools.md) | `gw-ls`, `gw-grep`, `gw-hist`, `gw-view` and `gw-agent` |

[`docs/apps.md`](../apps.md) is the terse feature list for every program,
and [`zoe-keys.md`](../zoe-keys.md) the complete zoe key reference.

## Things every program shares

A few conventions hold across the whole suite, so they are described once
here.

### Finding the commands

Most programs have a way to list everything they can do without leaving
them:

| Program | How to see every command |
|---|---|
| zoe | Ctrl+Shift+P, the command palette (every action and every `:` command, with its key) |
| salacommander | Ctrl+Shift+P, the command palette; the key bar along the bottom shows what each F-key does under the modifiers you are holding |
| gmux | Ctrl+B P, the command palette |
| gw-read | `?`, the help overlay |
| gw-shell | Tab completes command names, and after a command lists its arguments, with descriptions where fish or a Lua completer has them |
| Every program | `--help` on the command line |

### Config files

Every config file is a Lua script named `<program>.conf.lua`, read from
the first of these that exists:

1. `$GLYPHWIRE_CONFIG_DIR`
2. `$XDG_CONFIG_HOME/glyphwire`
3. `~/.config/glyphwire` (the usual place)

Each file assigns one global table, `config` (gw-shell's is the exception:
it calls functions such as `alias()` and `prompt{}` instead). Every key is
optional. An unknown key is ignored, a key of the wrong type is logged and
its default kept, and a syntax error keeps whatever parsed before it, so a
typo never stops a program from starting.

Each program ships a **template** listing every key at its default with
every line commented out. Copying a template verbatim changes nothing;
uncomment only what you want to change. The templates live next to each
program's source (`zoe/zoe.conf.template.lua` and so on), and
`assets/*.conf.example.lua` are working setups to copy from. Each guide
names its template.

### Key names in configs

Every config that rebinds keys uses the same chord syntax:

- `mod+mod+key`, case-insensitive. Modifiers are `ctrl`, `alt`, `shift`
  and `super`.
- Keys are glyphwire key names: `left`, `page_down`, `backspace`, `tab`,
  `enter`, `F5`, `grave_accent`, `kp_add`, letters and `one`..`nine`.
  Aliases: `esc`, `del`, `pgup`, `pgdn`, `ins`, `bs`.
- Modifiers match exactly: `shift+tab` is not `tab`.
- Setting a chord to `false` takes the binding away.

Each program's own rules (which keys are not rebindable, how modes are
looked up) are in its guide.

### Themes

Programs don't paint fixed colours; they paint *roles* such as `keyword`,
`dir` or `table_header_bg`, which the window's theme resolves every time
it draws. So a theme switch recolours everything on screen, live.
`theme.lua` picks the window's theme, Super+F10 previews and switches it
for the session, and zoe, salacommander, gw-read and gw-shell can each
take a theme of their own in their config. See
[The window](glyphwire.md#themes).

### Outside a glyphwire window

Every program checks `GLYPHWIRE_SOCK` at startup. Run in an ordinary
terminal, the ones that make sense there fall back to plain output:
`gw-ls` prints names, `gw-grep` prints `file:line:` hits, `gwmd --dump`
prints the rendered text and `gw-read --list` the pages. The interactive
ones (zoe, gmux, salacommander, gw-hist) say they need a glyphwire
session.
