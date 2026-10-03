# zoe key reference

Every key and command zoe understands today, then the gaps in that set and
what moving to a VSCode-style (Ctrl/Alt chord) scheme with some vim parts
would cost or buy.

Keys are not configurable yet (`zoe.conf.lua` says so). Dispatch lives in
two places: `zoe/ui.zig` takes the window-level chords first (they work in
every mode), then `zoe/editor.zig` handles the rest per mode, with
`feedKey` for named keys and `feedText` for printable ones.

## Reference

### Everywhere (taken by `ui.zig` before the editor sees the key)

| Key | Action |
|---|---|
| Ctrl+S | Save the active buffer (`:w`). Mode and selection are left alone |
| Ctrl+P | Fuzzy file finder |
| Ctrl+N | Show / hide the file tree |
| Ctrl+H | Show / hide dotfiles and `.gitignore`d paths (tree and finder) |
| Ctrl+\` | Shell panel (`gw-shell`) |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Ctrl+W then `v` / `s` | Split the editor group vertically / horizontally |
| Ctrl+W then `q` / `c` | Close the group |
| Ctrl+W then `w` (or Ctrl+W) | Next group, then the tree |
| Ctrl+W then `h` `j` `k` `l` / arrows | Focus the group that way |
| Ctrl+Left / Right / Up / Down, Ctrl+L / J / K | Focus the group (or tree) that way. Insert mode keeps Ctrl+Left/Right for word jumps |
| Ctrl+O / Ctrl+I | Jumplist back / forward (the way back from `gd`) |
| Ctrl+Shift+X | Cut the selection to the system clipboard |
| Ctrl+Shift+P | Paste the system clipboard |
| Ctrl+Shift+C | Copy (host chord; zoe answers the `copy_request`) |
| Ctrl+Shift+V | Paste (host chord, arrives as a `paste` event) |
| Escape | Dismisses the hover popup first, then acts as Escape |

Host-level chords that also apply: Ctrl+- / Ctrl+= font size, Super+F10
theme switcher, Super+F12 job switcher.

### Normal mode

| Keys | Action |
|---|---|
| `h` `j` `k` `l`, arrows | Move. Counts work (`5j`) |
| `w` `W` `b` `B` `e` `E` | Word motions (small / big word) |
| `0` `^` `$`, Home / End | Line start / first non-blank / line end |
| `gg` `G` `{n}G` `{n}gg` | First / last / line *n* |
| PageUp / PageDown, Ctrl+U / Ctrl+D | Page up / down |
| `i` `a` `I` `A` `o` `O` | Enter insert mode |
| `v` `V` | Charwise / linewise visual |
| `gv` | Reselect the last visual range |
| `x` `X` `D` `C` `s` | Delete char / char before / to end of line, change to end, substitute |
| `d{motion}` `y{motion}` | Delete / yank over `w` `e` `b` `h` `l` `0` `^` `$` `j` `k` `G` `gg`, or the line (`dd`, `yy`) |
| `>{motion}` `<{motion}` | Indent / dedent over `>`/`<` (the line), `j` `k` `G` `gg` |
| Tab / Shift+Tab | `>>` / `<<` on the cursor line |
| `r{char}` | Replace character(s) |
| `J` | Join lines |
| `~` | Toggle case |
| `u` / Ctrl+R | Undo / redo (a whole command or insert session per step) |
| `p` `P` | Paste the system clipboard after / before |
| `/` `?` `n` `N` `*` `#` | Incremental literal search (smartcase), step, search word under cursor |
| `:` | Command line |
| `K` | LSP hover |
| `gd` | LSP go to definition |
| `]d` `[d` | Next / previous diagnostic |
| Alt+Up / Alt+Down | Move the line up / down (count = distance) |
| Shift+Alt+Up / Shift+Alt+Down | Copy the line above / below (count = copies) |

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
| `>` `<`, Tab / Shift+Tab | Indent / dedent, selection kept (count = levels) |
| `p` `P` | Replace the selection with the clipboard |
| `/` `?` `n` `N` `*` `#` | Search, extending the selection |
| `:` | Command line (no `'<,'>` range support) |
| `v` / `V` | Switch kind, or leave if already that kind |
| Alt+Up / Alt+Down | Move the selected lines |
| Shift+Alt+Up / Shift+Alt+Down | Copy the selected lines above / below |

### Insert mode

| Keys | Action |
|---|---|
| Arrows, Home / End, PageUp / PageDown | Move |
| Ctrl+Left / Ctrl+Right | Word back / forward (`b` / `w`) |
| Ctrl+Home / Ctrl+End | Start / end of file |
| Enter, Tab, Backspace, Delete | Edit (Tab honours `expandtab`; Enter does **not** auto-indent) |
| Alt+Up / Alt+Down | Move the line (its own undo step) |
| Shift+Alt+Up / Shift+Alt+Down | Copy the line (its own undo step) |
| Ctrl+Space | Ask for completions |
| Escape | Back to normal mode |

With the completion popup up: Up / Down or Ctrl+N / Ctrl+P move, PageUp /
PageDown page, Tab or Enter accept, Escape closes.

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

These are the things muscle memory reaches for and finds nothing:

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

- **Shift+Arrow / Shift+Home / Shift+End / Ctrl+Shift+Arrow selection.**
- **Ctrl+Z / Ctrl+Y** undo and redo, **Ctrl+A** select all.
- **Ctrl+C / Ctrl+X / Ctrl+V** unshifted (glyphwire's host owns Ctrl+Shift+C/V
  as its terminal-style copy and paste).
- **Ctrl+Backspace / Ctrl+Delete** word delete in the buffer (the `:` line has it).
- **Ctrl+F / Ctrl+H** find and replace (Ctrl+H is taken by hidden files).
- **Ctrl+G** go to line, **F12** definition, **Ctrl+/** toggle comment.
- **Ctrl+Shift+K** delete line, **Ctrl+Enter / Ctrl+Shift+Enter** insert line below / above.
- **Ctrl+D** add next occurrence / multi-cursor (Ctrl+D is half-page down here).
- **Command palette** (Ctrl+Shift+P is paste here).
- **Auto-indent and bracket pairing.**

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
  (the same). About half of zoe's window chords would have to move,
  probably onto Alt or a leader key.
- **Ctrl+C / Ctrl+V** belong to the host (Ctrl+Shift+C/V, and Ctrl+C is
  the terminal's interrupt in gw-shell). Taking the unshifted forms in zoe
  is possible but makes zoe the odd one out in the window.
- **Multi-cursor** is the feature that makes chord editing competitive
  with vim's operators, and zoe's editor core is single-cursor
  (`Editor.cursor: usize`). Without it a chord-only zoe is weaker than
  both VSCode and vim.
- **Shift+Arrow selection** is cheap: it is visual mode entered implicitly
  and left on the next unshifted motion. `Editor.select_anchor` already
  carries it.

### A middle path

Most of what VSCode does better is *insert-mode ergonomics*, and most of
what vim does better is *normal-mode composition*, so the hybrid that
costs least keeps both and fixes the insert side:

1. **Insert mode becomes a capable editor of its own**: Shift+Arrow /
   Shift+Home / Shift+End / Ctrl+Shift+Left/Right select (into visual,
   returning to insert on the next typed key), Ctrl+Backspace / Ctrl+Delete,
   Ctrl+Z / Ctrl+Shift+Z, Ctrl+A, auto-indent. You could then live in
   insert mode and only drop to normal for the composed commands.
2. **Shared chords in every mode** where they don't collide: Ctrl+S (done),
   Alt+Up/Down and Shift+Alt+Up/Down (done), Ctrl+/ comment, Ctrl+G go to
   line, F12 / Shift+F12, F2 rename, Ctrl+Shift+K delete line.
3. **Fill the biggest vim gaps** (text objects, `c` operator, `.`, `f`/`t`)
   so normal mode is worth dropping into.
4. **Make keys rebindable** through `src/keybind.zig`, the named-action
   table salacommander already uses, so collisions like Ctrl+H and Ctrl+D
   are a config choice rather than a fork. This is also the prerequisite
   for an optional "start in insert mode" setting that would make zoe
   behave chord-first out of the box.
5. **Command palette** on a free chord (Ctrl+Shift+O, or F1), listing the
   same named actions, which also documents them.

Multi-cursor and Ctrl+D-style occurrence selection are the large item and
can wait until the above shows whether chord-first editing sticks.
