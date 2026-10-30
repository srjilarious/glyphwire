<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# gmux

gmux splits the window into panes, each running its own program, the way
tmux does. The difference is in how: tmux sits between every program and
the terminal and re-draws their output through one stream, while gmux
never touches a program's input or output at all. It claims the window
manager role, asks the glyphwire host for panes and arranges them. The
host draws the dividers and gives each pane a real terminal of exactly
its size, so a program in a pane (zoe, gw-view, plain vim) draws exactly
as it would full-window, images included.

This page covers `gmux` 0.12.0.

## Starting it

Run `gmux` from the shell. Its first pane starts a fresh shell in the
same directory.

To have every window start in gmux, set it as the host's default
program in `host.conf.lua`:

```lua
config = { default_program = "gmux" }
```

The window then opens straight into gmux, with its own `gw-shell` in the
first pane: the same prompt you would have had without it, but with
splitting and pane management ready from the first keystroke. Closing
the last pane (or Ctrl+B q) closes the window. See
[The window](glyphwire.md#starting-in-gmux-or-anything-else).

## The prefix key

Every gmux command is the prefix, **Ctrl+B**, then a key:

| After Ctrl+B | Action |
|---|---|
| `%` | Split the focused pane, new pane to the right |
| `"` | Split it, new pane below |
| Arrows | Move focus that way |
| `x` | Close the focused pane |
| `z` | Zoom it to fill the window, and back |
| `H` / `L` | Shrink / grow it along a row |
| `K` / `J` | Shrink / grow it along a column |
| `}` / `{` | Rotate every pane one slot forward / back |
| `P` | The command palette |
| `m` | Layout mode |
| `q` | Quit gmux |
| Ctrl+B | Send one Ctrl+B to the program in the pane |

A new pane starts in the directory of the shell in the pane it was split
from. Dividers can be dragged with the mouse, and keep their ratios as
panes split and close. The host highlights the dividers around the
focused pane (a slow pulse by default; `pane_focus_highlight` in
`host.conf.lua`).

Programs that want Ctrl+B themselves still get it with Ctrl+B Ctrl+B.
zoe's tree toggle has Ctrl+N as a second key for exactly this reason.

## Finding every command: the palette

**Ctrl+B P** opens the palette: every gmux command, searchable by name,
with the keys that run it. Type to filter, Enter to run, Escape to
close. It is drawn on a pane of gmux's own, raised over the window only
while it is open.

## Layout mode

**Ctrl+B m** picks panes up and puts them down with the mouse:

- Drag a pane onto **another pane's edge** to move it there.
- Onto **another pane's middle** to swap the two.
- Onto **a window edge** for a full-height column or full-width row.

The drop target is highlighted and the pane you are carrying darkened
while you drag. Panes in the row or column a pane lands in (or leaves)
are evened out, and every other ratio is kept. Escape or Enter finishes.

## Each pane

Each pane keeps its own scrollback, scrolled with the wheel over that
pane. Selection, copy and paste are the window's (Ctrl+Shift+C / V), and
the context switcher (Super+F12) lists the programs the focused pane
holds.

## gmux.conf.lua

Template: [`gmux/gmux.conf.template.lua`](../../gmux/gmux.conf.template.lua).
A working example: [`assets/gmux.conf.example.lua`](../../assets/gmux.conf.example.lua).

```lua
config = {
    -- Ctrl+A, screen style, instead of Ctrl+B.
    prefix_key = "a",

    -- What a new pane runs. Any shell works: a pane is a real terminal.
    shell = "/bin/bash",

    scrollback_rows = 5000,

    -- Rebind the keys after the prefix, by command name; false removes one.
    keys = {
        ["-"] = "splitBelow",
        ["|"] = "splitRight",
        ["%"] = false,
    },
}
```

The command names for `keys` are `focusLeft`, `focusRight`, `focusUp`,
`focusDown`, `splitBelow`, `splitRight`, `killPane`, `zoom`,
`resizeLeft`, `resizeRight`, `resizeUp`, `resizeDown`, `rotateForward`,
`rotateBackward`, `quit`, `commandPalette`, `layoutMode` and `sendPrefix`.
A punctuation character or uppercase letter means that character as your
keyboard layout types it; anything else is a chord (`"left"`,
`"ctrl+x"`).

How the dividers look (single, heavy, double or solid lines) and the
focused-pane highlight are the host's to draw, so they are set in
`host.conf.lua`: `pane_divider_style`, `pane_divider_chars` and
`pane_focus_highlight`.

## Not there yet

- The starting pane layout is not configurable: gmux always starts with
  one pane.
- The scrollback's style is not configurable.
- gmux has no detach and reattach; its panes live as long as the window.
