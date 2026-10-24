<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# The bundled applications

Every program here is an ordinary glyphwire client: it finds the session
through `GLYPHWIRE_SOCK` and speaks the protocol in
[`protocol.md`](protocol.md) like any third-party program would. None of
them reaches into the host's internals. The README has the one-line
summary of each; this page has the detail.

Versions are each program's line in `program_versions` at the top of
`build.zig`, and every program prints its own with `--version`.

## gw-shell

The shell `glyphwire` spawns.

- **Language.** Pipelines, bash-style quoting and `$VAR` expansion, and
  commands that span several lines (an open quote or a trailing `\`
  continues onto the next). Lua config and scripting in `shell.conf.lua`.
- **History.** Fish-style autosuggestions as you type, which skip entries
  naming paths that are gone. Ctrl+R opens `gw-hist` over the history,
  seeded with whatever is already typed; Alt+C opens it on frecent
  directories (Tab flips between the two), and Alt+Up goes up a
  directory.
- **Completion.** Tab completes `$PATH` commands, and arguments through
  fish's completions or Lua `defcomplete` functions, falling back to file
  names when neither has an answer. Tab takes a showing hint whole, or a
  path hint a segment at a time.
- **Prompt.** Powerline segments, configurable from Lua.
- **Remote.** `gwssh` opens a remote session in a pane, the far side run by
  `gw-agent`.
- **Embedding.** `--embed` runs the same prompt inside another client's
  layer (zoe's and salacommander's Ctrl+` panel), and `--context` on a
  context the host made for it (the context switcher's new shell).
- **Jobs.** `exit` leaves background programs with a screen of their own
  running. Super+Delete stops a foreground program that ignores Ctrl+C:
  SIGTERM to its process group, then SIGKILL after three seconds
  (`keys{ kill_job }`). A program that exits while something it started
  still holds its terminal or pipes no longer keeps the prompt waiting.

## zoe

A modal text editor: vim's grammar with VS Code's keys alongside it.

### Layout

- File tree, tab strips and buffers in a host-side split tree.
  `:vsplit` / `:split` (or Ctrl+W v / s) split the editor into groups side
  by side or stacked, each with its own tab strip, resized by dragging the
  divider between them.
- Resting the pointer on a tab shows the file's full path. A strip with
  more tabs than fit scrolls sideways with the wheel or the `‹` / `›`
  arrows at its ends, and Ctrl+Shift+E finds the current file in the tree.
- The tree manages files in place, nvim-tree style: `a` new, `r` rename,
  `d` to the trash (`D` for good) after a `y`/`n`, `c` / `x` / `p` copy,
  cut and paste, Ctrl+Shift+C the entry's path.
- Ctrl+` drops a `gw-shell` into a panel over the bottom of the window for
  builds and tests. Drag its top edge to resize it; clicking the tree or a
  buffer takes the keyboard back with the panel still up.
- `zoe <file>` typed in that panel opens the file in the same zoe, the way
  `code` does from VS Code's terminal, and `zoe <dir>` adds the folder to
  the sidebar. `--wait` returns only once the tab is closed, for
  `EDITOR='zoe --wait'`; `--new` starts a separate zoe. A bare `zoe`, a
  workspace or several folders always start a new one.
- **Workspaces.** Several directories, a `.zoe-workspace` or a VS Code
  `.code-workspace` open as one session with a sidebar section per folder.
  `:wssave` / `:wsopen` keep the folders, split tree, tabs, focus and
  theme.

### Finding things

- Ctrl+P fuzzy-finds files over the working directory.
- In the tree, `f` jumps by name prefix and `/` searches the whole tree,
  opening whatever folders that takes.
- Dotfiles and `.gitignore`d paths stay out of the tree and every search
  until Alt+H. In a search it reveals dotfiles only, so `.zig-cache/` and
  `.venv/` stay out; git worktrees inside the folder are searched anyway.
- In a buffer, `/` and `?` search incrementally (literal, smartcase), with
  `n` / `N` / `*` / `#` to step and `:noh` to clear.
- Ctrl+F / Ctrl+H open a VS Code style find and replace box (match count,
  case / whole word / in-selection toggles, replace one or all).
  `:s/pat/rep/g` substitutes over a range (`%`, `5,$`, `.,+3`, `'<,'>`).

### Editing

- `u` / Ctrl+R undo and redo a whole command or insert session at a time.
  Undoing back to the last save clears the modified mark.
- Visual `>` / `<` keep the selection so a block can be indented again;
  Tab / Shift+Tab do the same, and `gv` reselects the last range.
- Alt+Up/Down move lines past their neighbour, Shift+Alt+Up/Down copy
  them.
- VS Code keys alongside the vim ones: Ctrl+S, Ctrl+Z / Ctrl+Shift+Z,
  Ctrl+/ for line comments, Shift+arrows to select.
- Ctrl+Left/Right (and Ctrl+Backspace/Delete) move by word part, stopping
  at camelCase, acronym, digit and underscore boundaries; Alt+Left/Right
  move by whole word.
- Shift+Enter labels every visible word with two letters; typing a label
  jumps there. Alt+Z toggles word wrap.
- Enter, `o` and `O` keep the indent (a level deeper after an opening
  bracket), and brackets and quotes close themselves.
- Indented blocks fold with `za` / `zc` / `zo` / `zM` / `zR`,
  Ctrl+Shift+[ and ], or a click on the fold column.
- **Backups and hot exit.** Modified buffers are copied to
  `$XDG_STATE_HOME/glyphwire/zoe/backups` a second behind your typing, so
  `:q` quits with unsaved changes and reopening brings them back as one
  undoable step.

### Language support

- Incremental tree-sitter highlighting, with embedded languages.
- Language servers: diagnostics (curly underline, gutter sign, message in
  the statusline), `K` hover with highlighted code, `gd` goto-definition
  with Ctrl+O / Ctrl+I back, and completion that opens as you type.
  `]d` / `[d` step through diagnostics and `:lsp` lists attached servers.
- `zls`, `basedpyright` and `ruff server` are configured out of the box and
  start only when their binary is on `$PATH`. Two servers on one file keep
  their diagnostics apart.

### Customising

- Every chord is a named action `zoe.conf.lua` can rebind;
  [zoe-keys.md](zoe-keys.md) lists them all.
- Lua extensions add commands to the palette and the key tables
  ([zoe-extensions.md](zoe-extensions.md)). The bundled `task_journal`
  keeps a todo list and dated journal in Markdown, compatible with the
  Task Journal VS Code extension. A new entry carries forward the last
  one's unfinished tasks and its tracking section, and a monthly backlog
  does the same from the month before.
- Draws in the window's theme, or its own, switched live with `:theme` or picked from `:themes`.

## gmux

A terminal multiplexer that is a pure window manager: it draws nothing and
never touches a program's I/O. It claims the window-manager role, asks the
server for panes and places them.

- Keys follow `Ctrl-B`: `"` / `%` split, arrows move focus, `x` closes,
  `z` zooms, `H` / `J` / `K` / `L` resize, `q` quits, and `Ctrl-B` again
  sends one `Ctrl-B` through.
- Dividers are host-drawn and draggable, and keep their ratios when panes
  split or close. The host highlights the dividers around the focused
  pane, solid or slowly pulsing (`pane_focus_highlight` in
  `host.conf.lua`).
- The first pane starts where gmux was started, and a split starts in
  the directory of the shell in the pane it was split from.
- `default_program = "gmux"` in `host.conf.lua` opens every window in
  gmux instead of the shell.

## salacommander

A two-pane file manager in the Norton / Midnight Commander tradition.

- File-type icons, modal dialogs on their own layer, host scrollbars, and
  only the visible rows sent.
- F3 searches below the pane with zoe's fuzzy finder; F4 opens a file in
  zoe, Shift+F4 a new one. Launches don't block the file manager.
- F8 moves to the freedesktop.org trash, Shift+F8 deletes outright.
- F1 changes permissions (twelve toggles kept in step with the octal
  value) or owner and group, recursively if asked.
- Super on the same function keys does it as root through sudo, with a
  masked password dialog and `sudoedit` for editing.
- Drag files onto a folder or the other pane to move them, Ctrl+drag to
  copy. On Wayland, Alt+drag carries a file or the marked set into another
  program.
- Alt+Left/Right walk the directories a pane has shown; Alt+Down lists
  them.
- Tabs per pane (Ctrl+T, Ctrl+Tab, Ctrl+W), a Ctrl+` shell panel that
  follows the active pane, and a key bar that shows what each F-key does
  under the held modifier. Every key is a rebindable action.
- Quitting remembers every tab and its history; the next launch reopens
  them (`restore_session = false` turns it off).

## gwmd

A Markdown reader. Scaled headings from re-rasterized font atlases, GFM
tables as native server-side tables, inline images, fenced code blocks, and
links that Tab steps through and Enter follows. The document is one tall layer the host
scrolls. Drag, double- or triple-click to select and Ctrl+Shift+C to copy:
a wrapped paragraph copies as one line, without the margin, rules or
quote bars. Double-clicking the filename in the statusline copies the
file's absolute path.

## gw-read

A comic and manga reader. Pages are bitmaps with zoom and pan. Mokuro OCR
text overlays, Yomitan dictionary lookup (through the gw-yomi library), AI
bubble translation and Anki card mining.

## gw-ls

An `ls` replacement. An icon grid, or `-l` for a long listing in a
server-side table that stays sortable by clicking a header after `gw-ls`
has exited. On Wayland any entry, even from scrollback, can be Alt+dragged
into another program.

## gw-grep

A ripgrep front end that draws its hits as a collapsible outline in the
shell's scrollback, syntax-highlighted with zoe's grammars, then exits.
The outline is server-side state, so clicking a ▸ still expands a hit
after the process is gone.

## gw-hist

Ctrl+R fuzzy history search for `gw-shell` (and `--dirs` for frecent
directories), in a context of its own with a host-drawn scrollbar and every
redraw sent as one `batch` frame.

## gw-view

An image viewer: draws an image into the grid inline, or `--interactive`
for a context of its own with zoom and pan.

## gw-agent

The remote half of `glyphwire --ssh <dest>` and `gwssh`. It opens a normal
`GLYPHWIRE_SOCK` on the far machine and multiplexes every client that
dials it onto one ssh trunk back to the local host. The agent never parses
the protocol; it shuttles bytes, so remote `zoe` or `gw-view` draw exactly
as local ones do, images included.

## Developer tools

- `glyphwire-probe` drives and inspects a live session from the command
  line (`zig build probe`).
- `glyphwire-demo` shows truecolor runs, swatches, an icon panel and
  multi-script text.
- `glyphwire-table-demo` exercises the table widget.
- `glyphwire-notify` slides a nine-patch notification box in over whatever
  is on screen, on a layer of its own.
