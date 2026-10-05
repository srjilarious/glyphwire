# zoe key reference

Every key and command zoe understands, then the gaps that remain and what
the modal scheme and a VSCode-style (Ctrl/Alt chord) scheme each cost.

## How keys are dispatched

Chords and named keys (arrows, Home, Tab, Backspace, F-keys) are **named
actions** (`zoe/actions.zig`) looked up in four tables: the editor mode's
own (`normal`, `visual`, `insert`), then `global`. `zoe.conf.lua`'s
`keys` rebinds any of them by action name, or takes one away with
`false`:

```lua
config = { keys = {
    global = { ["ctrl+h"] = false, ["alt+h"] = "toggleHidden" },
    insert = { ["ctrl+d"] = "deleteWordForward" },
} }
```

Modifiers match exactly (`shift+tab` is not `tab`). `false` in a mode
table also hides the global binding in that mode.

Not rebindable: unmodified letters in normal and visual mode (vim's
grammar of counts, operators and prefixes, in `zoe/editor.zig`), Escape,
the `:` / `/` line's editing keys, the file tree's keys, the key after
Ctrl+W, and the completion popup's keys.

## Actions and their default keys

### Window (every mode, and the file tree)

| Action | Default | What it does |
|---|---|---|
| `save` | Ctrl+S | `:w`, leaving the mode and selection alone |
| `findFile` | Ctrl+P | Fuzzy file finder |
| `toggleTree` | Ctrl+N | Show / hide the file tree |
| `toggleHidden` | Ctrl+H | Dotfiles and `.gitignore`d paths, in the tree and finder |
| `toggleShell` | Ctrl+\` | Shell panel (`gw-shell`) |
| `nextTab` / `prevTab` | Ctrl+Tab / Ctrl+Shift+Tab | Walk the tab strip |
| `windowPrefix` | Ctrl+W | Then `v` / `s` split, `q` / `c` close, `w` (or Ctrl+W) next group, `h` `j` `k` `l` / arrows focus, Shift+`H` `J` `K` `L` / Shift+arrows move the tab |
| `focusLeft` `focusRight` `focusUp` `focusDown` | Ctrl+Left / Right / Up / Down, Ctrl+L / K / J | Focus the group (or tree) that way |
| `moveTabLeft` `moveTabRight` `moveTabUp` `moveTabDown` | (unbound; Ctrl+W Shift+H / L / K / J) | Move the shown tab to the group that way, splitting a new group off on that side if there is none. A group left without tabs closes |
| `jumpBack` / `jumpForward` | Ctrl+O / Ctrl+I | Jumplist (the way back from `gd`) |
| `cut` | Ctrl+Shift+X | Selection (or line) to the clipboard, removed |
| `paste` | Ctrl+Shift+P | Clipboard after the cursor, or over a selection |
| `complete` | Ctrl+Space (insert) | Ask the language servers for completions |

Host chords also apply: Ctrl+Shift+C copy and Ctrl+Shift+V paste, Ctrl+- /
Ctrl+= font size, Super+F10 theme switcher, Super+F12 job switcher.

### Moving and selecting (every mode)

| Action | Default |
|---|---|
| `left` `right` `up` `down` | Arrows |
| `lineStart` / `lineEnd` | Home / End |
| `pageUp` / `pageDown` | PageUp / PageDown (also Ctrl+U / Ctrl+D in normal and visual) |
| `wordLeft` / `wordRight` | Ctrl+Left / Ctrl+Right (insert) |
| `fileStart` / `fileEnd` | Ctrl+Home / Ctrl+End (insert) |
| `selectLeft` `selectRight` `selectUp` `selectDown` | Shift+arrows |
| `selectLineStart` / `selectLineEnd` | Shift+Home / Shift+End |
| `selectWordLeft` / `selectWordRight` | Ctrl+Shift+Left / Right |
| `selectFileStart` / `selectFileEnd` | Ctrl+Shift+Home / End |

The `select…` actions start a selection if there isn't one:

- **From normal mode** they enter ordinary visual mode, inclusive of the
  cursor cell, and an unshifted arrow keeps extending it, as in vim.
- **From insert mode** they enter **select mode** (`SELECT` in the
  status line, bar caret): the selection is `[anchor, caret)`, typing or
  pasting replaces it, Backspace / Delete remove it, Tab / Shift+Tab
  indent it, an unshifted Left / Right drops it at its start / end (other
  motions drop it and move), and Escape goes to normal mode.

### Editing (every mode)

| Action | Default | What it does |
|---|---|---|
| `undo` | Ctrl+Z | `u`. Insert mode stays in insert mode |
| `redo` | Ctrl+Shift+Z, Ctrl+Y (and Ctrl+R in normal / visual) | Ctrl+R |
| `indent` / `dedent` | Tab / Shift+Tab (normal, visual); Shift+Tab (insert) | `>>` / `<<`, or the selection, which stays selected |
| `moveLinesUp` / `moveLinesDown` | Alt+Up / Alt+Down | Move the line or selected lines (count = distance) |
| `copyLinesUp` / `copyLinesDown` | Shift+Alt+Up / Shift+Alt+Down | Copy them above / below (count = copies) |
| `toggleComment` | Ctrl+/ | Line comments on or off, at the block's smallest indent |

Each is one undo step, including in insert mode, where it is separate from
the typing around it.

Ctrl+/ uses the language's line-comment marker: `//` for Zig and C, `#`
for Python, TOML and Bash, `--` for Lua, none for JSON and Markdown.
`zoe.conf.lua`'s `languages` entries take a `comment` to add or change
one.

### Typing (insert mode)

| Action | Default |
|---|---|
| `newline` | Enter, Shift+Enter |
| `insertTab` | Tab (honours `expandtab`; indents a select-mode selection) |
| `backspace` / `deleteForward` | Backspace (and Shift+Backspace) / Delete |
| `deleteWordBack` | Ctrl+Backspace (stops at the line's start; at it, joins lines) |
| `deleteWordForward` | Ctrl+Delete (stops at the line's end; at it, joins lines) |

Enter does **not** auto-indent yet.

With the completion popup up: Up / Down or Ctrl+N / Ctrl+P move, PageUp /
PageDown page, Tab or Enter accept, Escape closes.

## vim keys (normal and visual mode, not rebindable)

### Normal mode

| Keys | Action |
|---|---|
| `h` `j` `k` `l` | Move. Counts work (`5j`). With `wrap` on, a bare `j` / `k` (and Up / Down) moves one screen row; a count still moves by line |
| `w` `W` `b` `B` `e` `E` | Word motions (small / big word) |
| `0` `^` `$` | Line start / first non-blank / line end |
| `gg` `G` `{n}G` `{n}gg` | First / last / line *n* |
| `i` `a` `I` `A` `o` `O` | Enter insert mode |
| `v` `V` | Charwise / linewise visual |
| `gv` | Reselect the last visual range |
| `x` `X` `D` `C` `s` | Delete char / char before / to end of line, change to end, substitute |
| `d{motion}` `y{motion}` | Delete / yank over `w` `e` `b` `h` `l` `0` `^` `$` `j` `k` `G` `gg`, or the line (`dd`, `yy`) |
| `>{motion}` `<{motion}` | Indent / dedent over `>`/`<` (the line), `j` `k` `G` `gg` |
| `r{char}` | Replace character(s) |
| `J` | Join lines |
| `~` | Toggle case |
| `u` | Undo (a whole command or insert session per step) |
| `p` `P` | Paste the system clipboard after / before |
| `/` `?` `n` `N` `*` `#` | Incremental literal search (smartcase), step, search word under cursor |
| `:` | Command line |
| `K` | LSP hover |
| `gd` | LSP go to definition |
| `]d` `[d` | Next / previous diagnostic |

Yanks and deletes always go to the system clipboard (one register, no
`"a`-style named registers).

### Visual mode (`v` / `V`)

All normal-mode motions move the free end. Then:

| Keys | Action |
|---|---|
| `o` | Jump to the other end |
| `y` | Yank |
| `d` `x` | Delete |
| `c` `s` | Change |
| `>` `<` | Indent / dedent, selection kept (count = levels) |
| `p` `P` | Replace the selection with the clipboard |
| `/` `?` `n` `N` `*` `#` | Search, extending the selection |
| `:` | Command line (no `'<,'>` range support) |
| `v` / `V` | Switch kind, or leave if already that kind |

### Command line (`:`)

Line editing: Home / Ctrl+A, End / Ctrl+E, Ctrl+Left / Right (by path
segment), Ctrl+Backspace, Ctrl+U, Ctrl+K, Backspace on an empty line leaves.

History: Up / Down walk earlier `:` lines, only those starting with what
is already typed (vim's rule); Down past the newest puts the typed text
back. `/` and `?` keep a history of their own. Both are shared by every
tab and persist across sessions in `zoe_history` and `zoe_search_history`
in the config directory (`GLYPHWIRE_NO_HISTORY=1` keeps them in memory).

Filenames: Tab on the path of `:e`, `:w`, `:wq`/`:x`, `:sp`, `:vs`, or
`:wssave` / `:wsopen`, or `:cd` / `:addfolder` / `:rmfolder` (directories
only) completes it. One match is filled in, a
directory with its `/`; several fill in what they share and open a list
over the line, where Tab / Shift+Tab / Up / Down pick, Enter takes the
pick into the line (a directory then lists its own entries) and Escape
closes the list. Dotfiles are offered once the name starts with `.`.
`~` means `$HOME` in every path argument.

| Command | Action |
|---|---|
| `:{n}` `:$` `:.` `:+n` `:-n` `:{n}{motion}` | Jump to a line / run a motion |
| `:w [path]` | Write (with a path: save as) |
| `:q` `:q!` `:wq` `:x` `:wq!` `:x!` | Quit / write and quit |
| `:e path` | Open in a new tab (or focus it) |
| `:e` `:e!` | Reload from disk (`!` discards changes) |
| `:bn` `:bp` | Next / previous tab |
| `:bd` `:bd!` | Close the tab |
| `:vs [path]` `:sp [path]` `:clo` | Split / close a group |
| `:cd [dir]` `:pwd` | Working directory (in a workspace, `:cd` leaves the sidebar's folders alone) |
| `:addfolder dir` | Add a folder to the sidebar's workspace |
| `:rmfolder [dir]` | Take a folder out of the workspace (bare: the one the tree cursor is in) |
| `:wssave [file]` | Save the workspace to a `.zoe-workspace` (bare: the one opened from or last saved to) |
| `:wsopen file` `:wsopen! file` | Open a saved workspace, closing every tab (`!` discards changes) |
| `:noh` | Clear the search highlight |
| `:set lineno=off\|absolute\|relative` | Line numbers |
| `:set tabwidth=N`, `expandtab=on\|off`, `whitespace=on\|off` | Indent and whitespace display |
| `:set wrap=on\|off` (or `:set wrap` / `:set nowrap`) | Soft-wrap long lines at word breaks |
| `:theme [name]` (`:colo`) | Switch colour theme |
| `:lsp`, `:lsp restart` | Language server status / restart |
| `:diag` | List diagnostics |

Files changed outside zoe are noticed within about a second. A buffer with
no unsaved edits reloads in place, keeping its cursor and scroll; one with
edits is left alone and the status line shows `W11` once per change, so
`:e!` (take the disk's) or `:w` (keep yours) is a deliberate choice.

### File tree pane

`j` `k` / Up Down, PageUp / PageDown, `g` `G` / Home End, Enter / Space /
`l` open, `h` up one row, `f` jump by name prefix, `/` deep search, `q` or
Escape back to the buffer.

| Key | Action |
|---|---|
| `a` / Shift+F4 | New file in the folder under the cursor (or the cursor file's folder). End the name with `/` for a folder; `sub/new.zig` makes `sub` too. A new file opens in a tab. |
| F7 | New folder there |
| `r` / F2 | Rename in place, caret before the extension |

The name is typed into the row itself; Enter commits, Escape (or leaving
the tree) abandons it. A name that already exists keeps the field open
with the reason on the status line. Renaming a file or folder retargets
any open tab inside it.

The tree follows the disk: a file or folder created, deleted or renamed
in the root or any open folder shows up within about a second, keeping
open folders and the cursor's entry.

### Workspaces

`zoe dir1 dir2 ...`, `zoe project.zoe-workspace` or
`zoe project.code-workspace` opens several folders at once, the way VS
Code's multi-root workspaces do. Each folder gets a header row in the tree
(Enter collapses it, like any folder) with its contents beneath; with a
single folder the tree has no header, as before. zoe starts in the first
folder.

- **`.zoe-workspace` files** are zoe's own. `:wssave [file]` writes one:
  the folders, the editor groups (how they are split and in what
  proportions), each group's open files and shown tab, which group has
  the keyboard, and the theme if `:theme <name>` or `zoe.conf.lua` chose
  one. A theme that follows the window's is left out, so the file opens
  in whatever zoe would normally pick. Paths are relative to the file when
  they are in its folder, under it or in a sibling folder, else absolute.
  A bare `:wssave` writes back to the file zoe was opened from (or last
  saved to). `:wsopen file` swaps the running session over to a saved
  one: folders, groups, tabs and theme. It closes every open tab, so it
  refuses over unsaved changes unless given as `:wsopen!`. A saved file
  that has since gone is skipped rather than reopened empty.
- **`.code-workspace` files** (VS Code's) are read, never written: only
  the `folders` list (`path`, relative to the file, and optional `name`)
  is used. Comments and trailing commas are fine; `settings` and the
  rest, and remote `uri` folders, are ignored. `:wssave` to a new
  `.zoe-workspace` keeps such a session.
- `:addfolder` / `:rmfolder` change the folders for this session; a
  `:wssave` afterwards is what keeps them.
- Ctrl+P and the tree's `/` search cover every folder; Ctrl+P prefixes
  each result with its folder's name, so typing the name narrows to it.
- The shell panel (Ctrl+`) opens in the folder that holds the current
  file, falling back to the first folder.
- Language servers start in the first folder with every folder in
  `workspaceFolders`, and hear about `:addfolder` / `:rmfolder`.
- A folder's header can't be renamed from the tree.

### Mouse

Click to place the cursor and focus a group; drag to select (enters
visual mode); double-click selects a word (vim's `iw` run: identifier,
punctuation or blanks) and triple-click a line (`V`), and dragging on
from either grows the selection a word or line at a time; wheel and scrollbar thumb scroll any group; Shift+wheel
scrolls a tab strip; click a tab to switch, its `×` to close; drag a tab
onto another group's strip (dropped in front of the tab under the pointer)
or pane (added at the end) to move it there, or along its own strip to
reorder it, with a bar marking the gap it would land in on a strip and a
tint over a pane it would move to; hover a tab for its full path; drag a divider to resize
groups or the shell panel.

## Gaps

### Missing for a vim user

- **Text objects**: `iw` `aw` `i(` `i"` `ip` and friends. No `ciw`, `di(`, `yap`.
- **`c` as an operator**: only `C`, `s` and visual `c` exist, so no `cw`/`cc`.
- **`.` repeat.**
- **In-line find**: `f` `F` `t` `T` `;` `,`.
- **`%`** bracket match, **`{` `}`** paragraph motions, **`H` `M` `L`**, **`zz` `zt` `zb`**.
- **Marks** (`m` / `'`), **macros** (`q` / `@`), **named registers** (`"a`).
- **`:s` substitute** and `'<,'>` ranges.
- **`gu` / `gU`** case operators, **`>` / `<`** over word or paragraph motions.
- **Auto-indent** on Enter / `o` / `O`.

### Missing for a VSCode user

- **Ctrl+A** select all.
- **Ctrl+C / Ctrl+X / Ctrl+V** unshifted (glyphwire's host owns Ctrl+Shift+C/V
  as its terminal-style copy and paste). Rebindable now for X and V; C is
  the host's.
- **Ctrl+F / Ctrl+H** find and replace (Ctrl+H is hidden files by default).
- **Ctrl+G** go to line, **F12** definition.
- **Ctrl+Shift+K** delete line, **Ctrl+Enter / Ctrl+Shift+Enter** insert line below / above.
- **Ctrl+D** add next occurrence / multi-cursor (Ctrl+D is half-page down in normal mode).
- **Command palette** (Ctrl+Shift+P is paste here).
- **Auto-indent and bracket pairing.**

Closed since the first version of this list: Shift+arrow selection, Ctrl+Z
/ Ctrl+Y, Ctrl+Backspace / Ctrl+Delete, Ctrl+/, Ctrl+S, Shift+Alt+Up/Down,
and rebindable keys.

## Modal versus Ctrl/Alt-heavy

### What the modal side gives you

- **Composition.** `d`, `y`, `>` times a motion is *N + M* things to learn
  for *N × M* commands. A chord scheme needs a separate chord per pair, and
  in practice only ships the common ones.
- **Counts** for free: `3dd`, `5j`, `3<s-a-down>`.
- **Home row.** Movement and editing never leave it; no wrist on a
  modifier for every motion.
- **Free keyspace.** Normal mode has the whole keyboard unmodified, so
  window chords (Ctrl+W, Ctrl+N, Ctrl+P) never compete with editing ones.
  zoe already relies on this: Ctrl+H, Ctrl+L, Ctrl+D, Ctrl+U, Ctrl+Shift+P
  all mean something non-VSCode.

### What the chord side gives you

- **No mode errors.** Typing `jjk` into the wrong mode can't happen; the
  cursor shape stops being something you have to read.
- **Selection is visible before you act**, and acts like every other app
  on the desktop (Shift+Arrow, mouse, clipboard).
- **Discoverable** via a palette and menus; nothing to remember for rare
  commands.
- **Fits glyphwire's other programs**: salacommander, gw-shell's line
  editor and every popup are chord-driven already.

### Costs specific to zoe

- **Keyspace collisions.** The VSCode set wants Ctrl+H (replace), Ctrl+L
  (select line), Ctrl+D (next occurrence), Ctrl+P (finder, the same),
  Ctrl+Shift+P (palette), Ctrl+N (new file), Ctrl+W (close tab), Ctrl+Tab
  (the same). With `keys` these are now a config choice rather than a
  code change, but the defaults still favour vim.
- **Ctrl+C / Ctrl+V** belong to the host (Ctrl+Shift+C/V, and Ctrl+C is
  the terminal's interrupt in gw-shell). Taking the unshifted forms in zoe
  is possible but makes zoe the odd one out in the window.
- **Multi-cursor** is the feature that makes chord editing competitive
  with vim's operators, and zoe's editor core is single-cursor
  (`Editor.cursor: usize`). Without it a chord-only zoe is weaker than
  both VSCode and vim.

### Where this leaves the middle path

Most of what VSCode does better is insert-mode ergonomics, and most of
what vim does better is normal-mode composition. Insert mode is now a
reasonable editor of its own (Shift+arrow selection, word delete, Ctrl+Z,
Ctrl+/, line move and copy), so living in insert mode and dropping to
normal for composed commands is workable. What would round it out:

1. **Auto-indent** on Enter, `o` and `O`.
2. **The biggest vim gaps** (text objects, `c` operator, `.`, `f`/`t`) so
   normal mode is worth dropping into.
3. **More shared chords**: Ctrl+A, Ctrl+G go to line, F12 / Shift+F12,
   F2 rename, Ctrl+Shift+K delete line, find / replace.
4. **A command palette** on a free chord (F1, or Ctrl+Shift+O), listing
   the named actions, which also documents them.
5. **An optional "start in insert mode" setting**, which would make zoe
   chord-first out of the box.

Multi-cursor and Ctrl+D-style occurrence selection are the large item and
can wait until the above shows whether chord-first editing sticks.
