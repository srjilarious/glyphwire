<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# salacommander

A two-pane file manager in the Norton Commander and Midnight Commander
tradition: two directory listings side by side, the function keys along
the bottom, and every operation working from the active pane to the
other one. On glyphwire it also has file-type icons, tabs, real
scrollbars, drag and drop (including out of the window into other
programs), and root operations behind a password dialog.

This page covers `salacommander` 0.12.1.

![salacommander with the repository on the left and docs/ on the right](../images/salacommander.png)

## Starting it

| Command | What it opens |
|---|---|
| `salacommander` | The last session's tabs, or the current directory |
| `salacommander ~/src ~/Downloads` | Those directories, left and right |
| `salacommander -L` / `-S` | Both panes in the large or small icon view |
| `salacommander -a` | With hidden files shown |

Quitting saves every tab with its directory, cursor, view, sort and
history, and the next start reopens them. A directory you name on the
command line is then shown in the tab already open on it, or a new one.

## The screen

Each pane is a tab strip (shown once a pane has two tabs), its path, a
listing with name, size and modified columns, and a status line with the
item count and total size. Across the bottom, the **key bar** shows what
each F-key does. Hold Shift, Ctrl or Super and it changes to show what
the keys do *with* that modifier, so the bar is the reference for every
function key.

The **active pane** is the one with the cursor. Copy, move and similar
operations act on its marked entries (or the one under the cursor) and
use the other pane's directory as the destination.

## Moving around

| Key | Action |
|---|---|
| Up / Down, PageUp / PageDown, Home / End | Move the cursor |
| Typing letters | Jump to the first entry starting with what you type |
| Enter | Open a directory, or run the file's open action |
| Alt+Up | Up to the parent directory |
| Alt+Left / Alt+Right | Back / forward through the directories this pane has shown |
| Alt+Down | Pick from that history |
| Alt+D | Edit the path in place |
| Tab | Switch to the other pane |
| Alt+O | Show this directory in the other pane too |
| Ctrl+U | Swap the panes, tabs and all |
| Ctrl+T, Ctrl+W | New tab on this directory, close the tab |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |

## Marking and file operations

Space or Insert marks entries; Ctrl+A (or keypad +) marks all and Ctrl+D
(or keypad −) clears. Then:

| Key | Action |
|---|---|
| F1 | File menu: change permissions (twelve toggles kept in step with the octal value) or owner and group, recursively if asked |
| F2 | Rename in place |
| F3 | Find files below this directory (fuzzy) |
| F4 | Edit the file in zoe; Shift+F4 a new file |
| F5 | Copy to the other pane |
| F6 | Move to the other pane |
| F7 | New directory |
| F8, Delete | To the desktop trash |
| Shift+F8, Shift+Delete | Delete for good |
| Ctrl+F3..Ctrl+F6 | Sort by name, extension, size, time |
| Ctrl+1 / Ctrl+2, Ctrl+V | Small / large icon view, toggle |
| Ctrl+H | Show hidden files |
| Ctrl+R | Reread both panes |
| F10, Ctrl+Q | Quit |

**As root.** The same function keys with **Super** held do the operation
through sudo: Super+F5 copies as root, Super+F8 deletes, Super+F4 edits
with `sudoedit`. A masked password dialog asks once, and the password is
never passed down a pipe.

**With the mouse.** Click to move the cursor, double-click to open, drag
the divider to resize the panes. Drag files onto a folder or the other
pane to move them, Ctrl+drag to copy, and on Wayland Alt+drag carries a
file (or the marked set) out into another program.

Launches never block the file manager: a file opened in zoe or gwmd
comes up over it, and salacommander comes back (and rereads both panes)
when it exits.

## Finding every command: the palette

**Ctrl+Shift+P** lists every action by name with its key. Together with
the key bar, that covers everything salacommander can do.

## The shell panel

**Ctrl+\`** drops a `gw-shell` over the window. It follows the active
pane: change directory or switch sides and the panel's shell is already
there by its next prompt. Ctrl+\` again hides it with its history and
half-typed line intact; `exit` in it closes it.

## salacommander.conf.lua

Template: [`salacommander/salacommander.conf.template.lua`](../../salacommander/salacommander.conf.template.lua).

```lua
config = {
    view = "large",              -- or "small"
    show_hidden = false,
    restore_session = true,      -- reopen last run's tabs
    page_lines = 6,

    -- What Enter runs, by extension. {sel} is the file's path.
    -- Anything without an entry goes to xdg-open.
    open_actions = {
        pdf  = "zathura",        -- path appended
        md   = "gwmd {sel}",
        png  = false,            -- back to xdg-open
    },

    -- What F4 runs; it must be a glyphwire program (vim has no screen here).
    editor = "zoe",

    shell_position = "bottom",   -- "top", "left", "right", "float"

    -- Rebind actions by name; false unbinds a chord.
    keys = {
        ["ctrl+up"] = "upToParentDir",
        ["delete"] = false,
    },

    -- If your desktop takes Super, move the root actions in the F1 menu.
    menu_keys = {
        ["alt+shift+m"] = "sudoChmod", ["super+m"] = false,
    },

    theme = "nord",              -- salacommander's own theme
}
```

The template lists every action name with its default chord
(`cursorUp`, `historyBack`, `swapPanes`, `sudoCopy`, `sortBySize`, ...).
Default open actions already send `.md` to gwmd, `.cbz` / `.cbr` to
gw-read and images to gw-view.

## Not there yet

- `editor` and every open action run without a terminal of their own, so
  they must be glyphwire programs (zoe, gwmd, gw-view) or desktop apps; a
  terminal editor such as vim or nano gets no screen.
- Open actions are single commands split on spaces: no pipes, quoting or
  globs.
- With two salacommanders open, the last one to quit decides the saved
  session.
- Some desktops (KWin among them) grab Super chords; rebind the root
  actions in `keys` and `menu_keys` if Super+F-keys never arrive.
