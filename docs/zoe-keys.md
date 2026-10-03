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
| `windowPrefix` | Ctrl+W | Then `v` / `s` split, `q` / `c` close, `w` (or Ctrl+W) next group, `h` `j` `k` `l` / arrows focus |
| `focusLeft` `focusRight` `focusUp` `focusDown` | Ctrl+Left / Right / Up / Down, Ctrl+L / K / J | Focus the group (or tree) that way |
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
| `h` `j` `k` `l` | Move. Counts work (`5j`) |
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
| `:cd [dir]` `:pwd` | Working directory |
| `:noh` | Clear the search highlight |
| `:set lineno=off\|absolute\|relative` | Line numbers |
| `:set tabwidth=N`, `expandtab=on\|off`, `whitespace=on\|off` | Indent and whitespace display |
| `:theme [name]` (`:colo`) | Switch colour theme |
| `:lsp`, `:lsp restart` | Language server status / restart |
| `:diag` | List diagnostics |

### File tree pane

`j` `k` / Up Down, PageUp / PageDown, `g` `G` / Home End, Enter / Space /
`l` open, `h` up one row, `f` jump by name prefix, `/` deep search, `q` or
Escape back to the buffer.

### Mouse

Click to place the cursor and focus a group; drag to select (enters
visual mode); wheel and scrollbar thumb scroll any group; Shift+wheel
scrolls a tab strip; click a tab to switch, its `×` to close; hover a tab
for its full path; drag a divider to resize groups or the shell panel.

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
