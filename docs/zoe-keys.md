<!-- SPDX-License-Identifier: CC-BY-4.0 -->
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
    global = { ["alt+h"] = false, ["ctrl+shift+h"] = "toggleHidden" },
    insert = { ["ctrl+d"] = "deleteWordForward" },
} }
```

Modifiers match exactly (`shift+tab` is not `tab`). `false` in a mode
table also hides the global binding in that mode.

A Lua extension's commands are bound the same way, by command name
(`["ctrl+t"] = "taskToggle"`), and an extension may bind its own
defaults, which `keys` overrides. See [zoe-extensions.md](zoe-extensions.md).

Not rebindable: unmodified letters in normal and visual mode (vim's
grammar of counts, operators and prefixes, in `zoe/editor.zig`), Escape,
the `:` / `/` line's editing keys, the find widget's own keys, the file
tree's keys, the key after Ctrl+W, and the completion popup's keys.

## Actions and their default keys

### Window (every mode, and the file tree)

| Action | Default | What it does |
|---|---|---|
| `save` | Ctrl+S | `:w`, leaving the mode and selection alone |
| `findFile` | Ctrl+P | Fuzzy file finder |
| `commandPalette` | Ctrl+Shift+P | Command palette: every action below that isn't a motion or a typing key, and every `:` command, by name, with its `:` form and its chord in the current mode (`Close Tab  :bd  Ctrl+F4`). Typing `bd` or `:bd` finds it too. A `:` command that takes an argument (`:addfolder`, `:wsopen`, `:theme`) puts the `:` line up for it; the rest run. Recently run ones list first |
| `listExtensions` | (unbound; `:extensions`) | Every extension zoe could load, built in or in `~/.config/glyphwire/zoe/extensions/`, and whether it loaded. Enter on one with a user file opens it |
| `selectTheme` | (unbound; `:themes`) | Every theme `:theme` can switch to (built-ins, `theme.lua`'s, `zoe.conf.lua`'s), filtered by typing like the palette; `light` or `dark` finds those. The highlighted one is applied as the cursor moves, Enter keeps it for this run (`:wssave` records it), Escape or a click outside puts back the one from before |
| `toggleTree` | Ctrl+B, Ctrl+N | Show / hide the file tree. Ctrl+B is VS Code's chord; under gmux it is the prefix, so use Ctrl+N or gmux's Ctrl+B Ctrl+B |
| `revealInTree` | Ctrl+Shift+E | Find the focused group's file in the tree: shows the tree if hidden, opens the folders down to it and puts the cursor on it. The keyboard stays where it was |
| `toggleHidden` | Alt+H | Dotfiles and `.gitignore`d paths in the tree; dotfiles only in the finder and `/` search. Was Ctrl+H, which is now replace |
| `toggleShell` | Ctrl+\` | Shell panel (`gw-shell`) |
| `nextTab` / `prevTab` | Ctrl+Tab / Ctrl+Shift+Tab | Walk the tab strip |
| `closeTab` | Ctrl+F4, Ctrl+W x | Close the shown tab (`:bd`); refused on a modified buffer |
| `closeTabsLeft` / `closeTabsRight` / `closeOtherTabs` | (unbound) | Close the tabs left of the shown one, right of it, or all but it (`:tabcloseleft`, `:tabcloseright`, `:tabonly`); modified tabs stay open and are counted on the statusline |
| `newBuffer` | Ctrl+Shift+N | A new `[No Name]` scratch tab beside the shown one (`:enew`) |
| `windowPrefix` | Ctrl+W | Then `v` / `s` split, `q` / `c` close the group, `x` close the tab, `w` (or Ctrl+W) next group, `z` zoom the group, `h` `j` `k` `l` / arrows focus, Shift+`H` `J` `K` `L` / Shift+arrows move the tab |
| `focusLeft` `focusRight` `focusUp` `focusDown` | Ctrl+Left / Right / Up / Down, Ctrl+L / K / J | Focus the group (or tree) that way |
| `moveTabLeft` `moveTabRight` `moveTabUp` `moveTabDown` | (unbound; Ctrl+W Shift+H / L / K / J) | Move the shown tab to the group that way, splitting a new group off on that side if there is none. A group left without tabs closes |
| `zoomGroup` | (unbound; Ctrl+W z) | The focused group fills the editor area, the other groups hidden (the sidebar stays); again to restore (`:zoom`). Splitting, closing or moving to another group unzooms first |
| `jumpBack` / `jumpForward` | Ctrl+O / Ctrl+I | Jumplist (the way back from `gd`) |
| `jump` | Shift+Enter | Two-letter labels over every word start on the focused pane's visible rows, the nearest to the cursor first (home row letters). Typing a label's first letter hides the labels it doesn't start and leaves the second letter of the rest; the second moves the cursor there. Backspace takes the first letter back; Escape, any other key, a click or a scroll cancels. Extends a selection, and records a jumplist entry |
| `cut` | Ctrl+Shift+X | Selection (or line) to the clipboard, removed |
| `paste` | (unbound; the host's Ctrl+Shift+V) | Clipboard after the cursor, or over a selection |
| `complete` | Ctrl+Space (insert) | Ask the language servers for completions |

Host chords also apply: Ctrl+Shift+C copy and Ctrl+Shift+V paste, Ctrl+- /
Ctrl+= font size, Super+F10 theme switcher, Super+F12 job switcher.

### Moving and selecting (every mode)

| Action | Default |
|---|---|
| `left` `right` `up` `down` | Arrows |
| `lineStart` / `lineEnd` | Home / End |
| `pageUp` / `pageDown` | PageUp / PageDown (also Ctrl+U / Ctrl+D in normal and visual) |
| `subwordLeft` / `subwordRight` | Ctrl+Left / Ctrl+Right (insert) |
| `wordLeft` / `wordRight` | Alt+Left / Alt+Right |
| `fileStart` / `fileEnd` | Ctrl+Home / Ctrl+End (insert) |
| `selectLeft` `selectRight` `selectUp` `selectDown` | Shift+arrows |
| `selectLineStart` / `selectLineEnd` | Shift+Home / Shift+End |
| `selectSubwordLeft` / `selectSubwordRight` | Ctrl+Shift+Left / Right |
| `selectWordLeft` / `selectWordRight` | Shift+Alt+Left / Right |
| `selectFileStart` / `selectFileEnd` | Ctrl+Shift+Home / End |

The `subword…` actions stop at word parts, as VS Code's word-part
motions do: a lower-to-upper change (`foo|Bar`), the last capital of an
acronym (`HTTP|Server`), a letter-digit change (`v|2|Thing`) and after an
underscore (`foo_|bar`), as well as everywhere the `word…` ones stop
(vim's `b` / `w`). To have Ctrl+arrows go by whole words again, bind
`wordLeft` / `wordRight` (and `deleteWordBack` / `deleteWordForward`) in
`keys.insert`.

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
| `fold` / `unfold` | Ctrl+Shift+[ / Ctrl+Shift+] | Close the innermost open fold around the cursor (again: the one around that) / open the closed fold on the cursor's line. `zc` / `zo` |
| `toggleFold` | (unbound; `za`) | Open the fold on the cursor's line if closed, else close the one the cursor is in |
| `foldAll` / `unfoldAll` | (unbound; `zM` / `zR`) | Every fold closed / open. VS Code's Ctrl+K Ctrl+0 / Ctrl+J aren't the defaults because Ctrl+K is focus-up |
| `find` / `replace` | Ctrl+F / Ctrl+H | The find widget, without / with its replace row (see Find and replace below) |
| `toggleWordWrap` | Alt+Z | Soft wrap on or off in every buffer, `:set wrap` / `:set nowrap` |

Each edit is one undo step, including in insert mode, where it is separate
from the typing around it. The fold actions change no text.

Ctrl+/ uses the language's line-comment marker: `//` for Zig and C, `#`
for Python, TOML and Bash, `--` for Lua, none for JSON and Markdown.
`zoe.conf.lua`'s `languages` entries take a `comment` to add or change
one.

### Typing (insert mode)

| Action | Default |
|---|---|
| `newline` | Enter (Shift+Enter is `jump`) |
| `insertTab` | Tab (honours `expandtab`; indents a select-mode selection) |
| `backspace` / `deleteForward` | Backspace (and Shift+Backspace) / Delete |
| `deleteSubwordBack` | Ctrl+Backspace: back a word part (stops at the line's start; at it, joins lines) |
| `deleteSubwordForward` | Ctrl+Delete: ahead a word part (stops at the line's end; at it, joins lines) |
| `deleteWordBack` / `deleteWordForward` | (unbound) The same by whole word |

### Auto-indent and auto-close

Both read the line, not a grammar, so every language gets the same
rules. `:set autoindent=off` / `:set autoclose=off` (or `auto_indent` /
`auto_close` in `zoe.conf.lua`) turn them off.

- **Enter**, `o` and `O` start the new line at the current line's
  indent. After a line ending in `(`, `[` or `{` (or `:` in Python) it is
  one level deeper (a tab, or `tabwidth` spaces with `expandtab`), and
  `O` above a line starting with a closing bracket is too.
- **Enter between a pair** (`{|}`) puts the closer on its own line at the
  outer indent and the caret on an indented line between.
- Blanks either side of the break are dropped, so Enter never leaves
  trailing whitespace, and Enter on a line holding only its indent leaves
  that line empty.
- **Escape** straight after Enter / `o` / `O`, with nothing typed, takes
  the indent back off.
- A **closing bracket** typed on a line with only blanks before it lines
  up with the line its opener is on.
- Typing `(`, `[`, `{`, `"`, `'` or `` ` `` also types its **partner**
  after the caret, but only before a blank, the line's end or one of
  `` ;:.,=}])> ``. A quote isn't paired straight after a letter or digit
  (`don't`), or where the line already has an odd number of them (you
  are closing a string).
- Typing the partner zoe put there **steps over** it; one you typed
  yourself is never stepped over. **Backspace** between a fresh pair
  deletes both.
- An opener typed over a **select-mode selection** (Shift+arrows in
  insert mode) goes round it, and the selection stays on the text inside.

Paste never auto-indents or pairs anything.

With the completion popup up: Up / Down or Ctrl+N / Ctrl+P move, PageUp /
PageDown page, Tab or Enter accept, Escape closes.

### Find and replace (Ctrl+F / Ctrl+H)

VS Code's find widget, in a box over the buffer's top-right corner, from
any mode. Finding is the `/` line's: literal text, smartcase, the cursor
on the nearest match as you type, every match highlighted, and "3 of 12"
beside the field. Ctrl+F opens it with the find field, Ctrl+H with the
replace row too; pressed again while it is open they move to that field.

The find field starts with the last search pattern, selected so typing
replaces it. Opened over a selection on one line, it starts with the
selected text instead; over a selection of several lines, it finds and
replaces only inside that selection (In Selection, on).

| Key | Action |
|---|---|
| Enter / Shift+Enter, F3 / Shift+F3 | Next / previous match (wraps) |
| Enter (replace field) | Replace the current match and go to the next |
| Ctrl+Alt+Enter | Replace every match, one undo step |
| Tab / Shift+Tab | The other field, with the replace row showing |
| Alt+C | Match case exactly (off: smartcase) |
| Alt+W | Whole words only |
| Alt+L | In Selection on / off (only when opened over one) |
| Up / Down | Search history (find field) |
| Escape | Close, leaving the cursor on the match |

The toggles, the arrows, `×`, and the replace row's `⇄` (replace one) and
`All` respond to a click too; a click in the buffer closes the widget.
The replacement is literal text: `&` and backslashes are just characters
here, unlike `:s`. Closing it keeps the pattern and toggles as the search
`n` / `N` repeat, so the highlight stays until `:noh`. The replace text
and the toggles are remembered for the next time it opens.

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
| `za` `zo` `zc` | Toggle / open / close a fold (see Folding below) |
| `zR` `zM` | Open / close every fold |
| `zj` `zk` | Next / previous line that starts a fold (count works) |

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
| `:` | Command line, started with `'<,'>` (the selected lines) |
| `v` / `V` | Switch kind, or leave if already that kind |

### Command line (`:`)

Every command below is in the Ctrl+Shift+P palette too, under a name
("Add Folder to Workspace" is `:addfolder`).

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
| `:[range]s/pat/rep/[flags]` | Substitute (see below) |
| `:[range]s` | Repeat the last substitution on `range`, without its flags |
| `:{a},{b}` `:'<,'>` | Jump to the range's last line |
| `:w [path]` | Write (with a path: save as) |
| `:q` `:q!` `:wq` `:x` `:wq!` `:x!` | Quit / write and quit (`:q` keeps unsaved changes in their backups; `:q!` throws them away) |
| `:e path` | Open in a new tab (or focus it) |
| `:e` `:e!` | Reload from disk (`!` discards changes) |
| `:bn` `:bp` | Next / previous tab |
| `:bd` `:bd!` | Close the tab |
| `:tabcloseleft` `:tabcloseright` `:tabonly` (`:tabo`) | Close the tabs left / right of the shown one, or all the others; with `!` modified ones too |
| `:enew` | New `[No Name]` scratch tab |
| `:vs [path]` `:sp [path]` `:clo` | Split / close a group |
| `:cd [dir]` `:pwd` | Working directory (in a workspace, `:cd` leaves the sidebar's folders alone) |
| `:addfolder dir` | Add a folder to the sidebar's workspace |
| `:rmfolder [dir]` | Take a folder out of the workspace (bare: the one the tree cursor is in) |
| `:wssave [file]` | Save the workspace to a `.zoe-workspace` (bare: the one opened from or last saved to; also done on `:q`, `:wq` and window close) |
| `:wsopen file` `:wsopen! file` | Open a saved workspace, closing every tab (`!` discards changes) |
| `:noh` | Clear the search highlight |
| `:set lineno=off\|absolute\|relative` | Line numbers |
| `:set tabwidth=N`, `expandtab=on\|off`, `whitespace=on\|off` | Indent and whitespace display |
| `:set wrap=on\|off` (or `:set wrap` / `:set nowrap`) | Soft-wrap long lines at word breaks |
| `:set autoindent=on\|off`, `autoclose=on\|off` | Auto-indent; closing brackets and quotes |
| `:set foldcolumn=on\|off` | The fold markers' gutter column |
| `:theme [name]` (`:colo`) | Switch colour theme |
| `:themes` | Pick a theme from a list, previewing each |
| `:shell [bottom\|top\|left\|right\|float]` | Move the Ctrl+` shell panel (bare: report where it is) |
| `:lsp`, `:lsp restart` | Language server status / restart |
| `:diag` | List diagnostics |
| `:extensions` | List the extensions and whether each loaded |
| `:recover` | Open every unsaved-change backup no tab has |

**`:s`.** With no range it works on the cursor's line. A range is two
addresses joined by `,`, or `%` for the whole file. An address is a line
number, `.` (the cursor's line), `$` (the last), or `'<` / `'>` (the
first and last line of the last visual selection), each optionally
followed by `+n` / `-n`; `+n` alone is relative to `.`. A backwards range
is turned round. Patterns are literal, like `/` (no regex): `\/` (or `\`
before whatever delimiter you used) is the delimiter, `\\` a backslash,
`\n` a line break (so `:%s/\n/ /` joins lines) and `\t` a tab; anything
else is matched as typed. An empty pattern (`:s//x/`) is the last
search's. In the replacement `&` is the matched text, `\&` a literal `&`,
`\r` or `\n` a line break and `\t` a tab. Flags: `g` every match on a
line, `i` ignore case, `I` match case (default smartcase). The whole
command is one undo step, the cursor ends on the last line changed, the
status line says how many substitutions on how many lines, and the
pattern becomes the one `n` repeats.

Files changed outside zoe are noticed within about a second. A buffer with
no unsaved edits reloads in place, keeping its cursor and scroll; one with
edits is left alone and the status line shows `W11` once per change, so
`:e!` (take the disk's) or `:w` (keep yours) is a deliberate choice. A
file deleted (or moved away) puts a red ✘ in front of its tab's name and leaves
the buffer as it was; `:w` writes it back and clears the mark.
`file_watch` in `zoe.conf.lua` picks what notices: `"poll"` (the default,
a stat a second), `"inotify"` (Linux, within about 50 ms, idle otherwise)
or `"off"`.

**Unsaved changes are backed up.** About a second after an edit, a copy of
every modified buffer is written under `$XDG_STATE_HOME/glyphwire/zoe/backups`
(else `~/.local/state/...`), never next to the file, so nothing shows up in
the folder, `git status` or the tree. `:w` deletes the copy. That makes `:q`
VS Code's "hot exit": it quits with unsaved changes instead of refusing,
and so do closing the window and a crash (minus the last second). Opening
the file again puts the changes back as one undo step, so `u` is the file
as it is on disk. If the file changed on disk since the backup was taken,
zoe asks first: `r` recovers the backup, `d` deletes it, `s` opens it in a
split as an untitled buffer next to the file. Untitled buffers come back
with their workspace (or the folders zoe was started on). `:q!`, `:bd!`
and `:wsopen!` throw the changes away along with their backups. `:recover`
opens every backup that no tab has, whatever folder it came from. A file
another running zoe has unsaved changes to is left to that zoe and gets
no backup here. `backups = false` in `zoe.conf.lua` turns all of this
off, and `:q` refuses unsaved changes again.

Ctrl+P and the tree's `/` search skip dotfiles and `.gitignore`d paths.
Alt+H brings the dotfiles back but not the ignored paths, so `.zig-cache/`
and `.venv/` never bury a search. Git worktrees that live inside the
folder (say under an ignored `.claude/worktrees/`) are searched anyway,
under their own `.gitignore`; `unignore = { "vendor/lib" }` in
`zoe.conf.lua` does the same for any other path.

### Folding

A line folds when the next non-blank line is indented further (VS Code's
"indentation" folding). The fold runs to the end of that deeper block:
blank lines inside it are included, blank lines after it aren't, and the
line that closes the block (a `}` back at the outer indent) stays
visible. That needs no grammar, so every file folds the same way.

- The **fold column**, between the diagnostic signs and the line
  numbers, shows a dim ▾ beside every line that can fold and ▸ beside a
  closed one. Click either to toggle it. `:set foldcolumn=off` (or
  `fold_column = false`) hides it.
- A closed fold shows its first line followed by a dim `⋯ N lines`.
- `j` / `k`, the arrows, PageUp / PageDown and `:Nj` step over a closed
  fold as one line, and relative line numbers count it as one.
- `dd`, `yy`, `>>` and `<<` on a closed fold act on the whole fold; so do
  `dj` / `dk` and friends when they reach one, and `V` with one at its
  bottom end. `o` opens the new line below the fold.
- Anything else that puts the cursor inside a closed fold (a search
  match, `gd`, `]d`, `:123`, an undo) opens it.
- `zc` on a closed fold closes the one around it, so repeating it folds
  outward. `zM` closes nested folds too, so opening an outer one shows the
  inner ones still folded.
- Closed folds follow their lines as text is added or removed above
  them, and go away when their first line is deleted. They aren't saved
  in a workspace, and `:e` or a reload from disk opens them all.

### File tree pane

`j` `k` / Up Down, PageUp / PageDown, `g` `G` / Home End, Enter / Space /
`l` open, `h` up one row, `f` jump by name prefix, `/` deep search, `q` or
Escape back to the buffer.

| Key | Action |
|---|---|
| `a` / Shift+F4 | New file in the folder under the cursor (or the cursor file's folder). End the name with `/` for a folder; `sub/new.zig` makes `sub` too. A new file opens in a tab. |
| F7 | New folder there |
| `r` / F2 | Rename in place, caret before the extension |
| `d` / F8 | Move to the desktop trash, after a `y`/`n` on the status line. If the filesystem has no trash, it asks again to delete for good. |
| `D` / Shift+F8 | Delete for good (folders and all), after a `y`/`n` |
| `c` | Copy the entry to the sidebar's clipboard |
| `x` / Ctrl+Shift+X | Cut it (drawn dim until it is pasted) |
| `p` / Ctrl+Shift+V | Paste into the folder under the cursor (or the cursor file's folder). A copy stays on the clipboard for more pastes; a cut is used up. |
| Ctrl+Shift+C | Copy the entry's absolute path to the system clipboard |

The name is typed into the row itself; Enter commits, Escape (or leaving
the tree) abandons it. A name that already exists keeps the field open
with the reason on the status line. Renaming a file or folder retargets
any open tab inside it, and so does moving one with `x` and `p`.

A paste never replaces anything. When the name is taken (always, for a
copy into the folder it came from) the name field opens in a new row with
a free `name (1).ext` in it: Enter takes it, or type another. Only `y`
answers yes to a delete; any other key, or leaving the tree, is no.

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
- **Auto-save on exit**: with a `.zoe-workspace` in hand (opened from,
  `:wsopen`ed or `:wssave`d), `:q`, `:wq` / `:x` and closing the window
  write it back, the same as a bare `:wssave`. `:q!` leaves it alone. If
  the write fails, `:q` stays put with the error; `:q!` still quits.
  `workspace_autosave = false` in `zoe.conf.lua` turns this off.
- **`.code-workspace` files** (VS Code's) are read, never written: only
  the `folders` list (`path`, relative to the file, and optional `name`)
  is used. Comments and trailing commas are fine; `settings` and the
  rest, and remote `uri` folders, are ignored. `:wssave` to a new
  `.zoe-workspace` keeps such a session.
- `:addfolder` / `:rmfolder` change the folders for this session; a
  `:wssave` (or the auto-save on exit) is what keeps them.
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
from either grows the selection a word or line at a time; wheel and scrollbar thumb scroll any group (Alt+wheel by a page, or the host's `alt_wheel_lines`); the wheel
(plain or Shift) over a tab strip scrolls it sideways, and a strip too wide for its group shows a `‹` / `›` at
each end that scrolls it one tab per click; click a tab to switch, its `×` (or a middle click anywhere on it) to close, a right click to copy its file's absolute path (a click on the statusline's filename copies the shown one's); drag a tab
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
- **Regex** in `/` and `:s` (both are literal), `:s`'s `c` flag, `;` and
  `/pat/` range addresses, `:g`.
- **`gu` / `gU`** case operators, **`>` / `<`** over word or paragraph motions.
- **Manual folds** (`zf`), and `zA` / `zO` / `zC`.

### Missing for a VSCode user

- **Ctrl+A** select all.
- **Ctrl+C / Ctrl+X / Ctrl+V** unshifted (glyphwire's host owns Ctrl+Shift+C/V
  as its terminal-style copy and paste). Rebindable now for X and V; C is
  the host's.
- **Ctrl+Shift+H / Ctrl+Shift+F** replace and find across files.
- **Ctrl+G** go to line, **F12** definition.
- **Ctrl+Shift+K** delete line, **Ctrl+Enter / Ctrl+Shift+Enter** insert line below / above.
- **Ctrl+D** add next occurrence / multi-cursor (Ctrl+D is half-page down in normal mode).

Closed since the first version of this list: Shift+arrow selection, Ctrl+Z
/ Ctrl+Y, Ctrl+Backspace / Ctrl+Delete, Ctrl+/, Ctrl+S, Shift+Alt+Up/Down,
rebindable keys, the Ctrl+Shift+P command palette, auto-indent, bracket
pairing, folding, and Ctrl+F / Ctrl+H find and replace.

## Modal versus Ctrl/Alt-heavy

### What the modal side gives you

- **Composition.** `d`, `y`, `>` times a motion is *N + M* things to learn
  for *N × M* commands. A chord scheme needs a separate chord per pair, and
  in practice only ships the common ones.
- **Counts** for free: `3dd`, `5j`, `3<s-a-down>`.
- **Home row.** Movement and editing never leave it; no wrist on a
  modifier for every motion.
- **Free keyspace.** Normal mode has the whole keyboard unmodified, so
  window chords (Ctrl+W, Ctrl+B, Ctrl+P) never compete with editing ones.
  zoe already relies on this: Ctrl+L, Ctrl+D, Ctrl+U all mean something
  non-VSCode.

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

- **Keyspace collisions.** The VSCode set wants Ctrl+L (select line), Ctrl+D (next occurrence), Ctrl+P (finder, the same),
  Ctrl+N (new file), Ctrl+W (close tab), Ctrl+Tab
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

1. **The biggest vim gaps** (text objects, `c` operator, `.`, `f`/`t`) so
   normal mode is worth dropping into.
2. **More shared chords**: Ctrl+A, Ctrl+G go to line, F12 / Shift+F12,
   F2 rename, Ctrl+Shift+K delete line, find / replace.
3. **An optional "start in insert mode" setting**, which would make zoe
   chord-first out of the box.

Multi-cursor and Ctrl+D-style occurrence selection are the large item and
can wait until the above shows whether chord-first editing sticks.
