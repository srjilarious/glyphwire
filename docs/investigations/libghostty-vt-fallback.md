# Investigation: a VT100/PTY-capable fallback via libghostty

Status: **Phase A built** (this branch — hand-rolled, not libghostty; see
§7 and the "Update" note below). **Phase B: investigation only.** This
document records the shape of the problem, what `libghostty` can and
can't do for us today, three candidate paths, and a recommended phasing
for running ANSI-emitting programs and old-school full-screen TUIs (vim,
less, htop, `ncurses` apps) under glyphwire.

Decisions here are provisional. Phase A's "why" now also lives in
`decisions.md` (In Progress: Text Writing & Styling → the "Phase A VT
fallback" decision); Phase B remains unbuilt.

---

## Update — Phase A landed (colour interpreter, hand-rolled)

After this investigation, the decision was to **not** take on a
libghostty dependency for Phase A (the `build.zig.zon` route pulls the
whole ghostty monorepo, pinned to a Zig version glyphwire is past; a
vendored source snippet is a hand-synced fork). Instead, `Layer`'s
existing `EscState` machine was grown from a *stripper* into a small
*interpreter*:

- `core.SgrPen` — SGR colour state (16/bright/256/truecolor fg+bg via
  both `;` and `:` forms; `0` reset; `1` bold → basic fg promoted to
  bright; `2` dim → fg darkened; `7`/`27` inverse → fg/bg swapped).
  Italic/underline/blink/strikethrough parsed and ignored.
- `Layer.execCsi` — `A`/`B`/`C`/`D`/`G`/`d`/`H`/`f` cursor moves, `J`/`K`
  erase. Every other CSI final and all `ESC ]`/`P`/`X`/`^`/`_ …` still
  recognized-and-discarded.
- Everything folds into the concrete `Cell.style` colours at write time:
  **no `Style` field added, no wire message changed, no `glyphwire-host`
  change.** The one wire-visible shift: `write_text` with `fg` omitted
  now inherits the layer's SGR pen (then `default_style.fg`). The pen
  persists across calls only on the mirrored-stdout path (`fg` null); an
  explicit `fg` resets it so a leaked colour can't reach the next prompt.
- Tests in `tests/core_tests.zig` (SGR colour/256/truecolor/bold/dim/
  inverse/pen-persistence, `ESC [ K`/`J`, cursor moves, private-sequence
  discard).

The rest of this document is the original investigation. Where §2, §6
(Path a) and §9 below describe Phase A as using the installed
`libghostty-vt` SGR parser and adding a `Style` attribute field, read
them against this Update — the shipped implementation is hand-rolled and
colour-only with no `Style`/wire change. The Phase B material is
unaffected and still governs.

---

## 1. The question

glyphwire deliberately has **no VT100/ANSI layer**. The protocol replaces
escape sequences with structured messages, and `glyphwire-shell` assumes
every spawned program is "a plain program writing to a terminal": it
pipes the child's stdout/stderr and mirrors each chunk onto the grid with
`write_text` (`Prompt.pumpChildOutput` / `flushCapturedStream`), letting
`Layer.writeText`'s C0 handling deal with `\n`/`\r`/`\t`. Anything more
structured than that, `Layer`'s tiny `EscState` machine **recognizes and
throws away** (`core.zig`'s `consumeControl` / `stepEscape`): a stray
`ESC[31m` from `grep --color` is discarded, not honoured, so the output
renders in the default colour.

Two capabilities are missing, and they are different sizes:

1. **Honour the escape sequences a plain CLI program emits** — SGR colour
   from `ls --color` / `grep --color` / `gcc` diagnostics, `\r`-driven
   progress bars (already work), simple `ESC[K` / `ESC[<n>D` cursor
   nudging. No PTY, no stdin, no alternate screen. This is the 80% case
   and it is *small*.

2. **Run a full-screen interactive TUI** — vim, `less`, `htop`, `tmux`,
   `fzf`. This needs a real PTY (the program calls `tcgetattr` /
   `isatty`, expects raw mode, cursor addressing, the alternate screen
   buffer, `SIGWINCH`), a bidirectional data path (keystrokes flow *in*),
   and a full terminal state model (scrollback, line wrap, reflow on
   resize). This is *large* and touches the shell's input model, the
   Context/alt-screen design, and process control.

"Incorporate libghostty" is really a question about #2, but #1 is
reachable much sooner and with a fraction of the risk.

---

## 2. TL;DR recommendation

**Phase A (small, do first, no new dependency beyond what's installed):**
Turn `Layer`'s escape *stripper* into a minimal escape *interpreter* for
the mirrored-output path — SGR colour + attributes, and a handful of
in-line CSI cursor ops (`CUU/CUD/CUF/CUB`, `EL`, `ED`). Use the
**already-installed** `libghostty-vt` **SGR parser** (`ghostty_sgr_*`) for
the fiddly SGR grammar (colon vs. semicolon sub-params, 256/truecolor/X11
forms) and hand-roll the rest against `Layer`'s existing primitives
(`writeText`, `insert_cells`/`delete_cells`, `clear`, cursor moves). Adds
the `Style` attribute bitflags (bold/italic/underline/dim/inverse) that
`decisions.md` already lists as planned. Contained to `core.Layer` +
`glyphwire-shell` + one additive `write_text` field. Fully headless-
testable.

**Phase B (large, deliberate, later):** the full-screen-TUI fallback. A
PTY path **inside `glyphwire-shell`** (per the design answer for this
investigation): the shell opens a pty for a non-glyphwire-aware
interactive program, drives a full VT model with the pty output, diffs
the resulting cell grid each frame and **transpiles it to the existing
wire messages** (`write_text` / `set_property("cursor")` / `clear` — no
new "terminal surface" wire concept), and forwards `InputListener`
keystrokes back into the pty. The VT model should be
**`libghostty-vt`'s Terminal C API** once it ships in a tagged release;
**vendoring ghostty's Zig `terminal` module** is the fallback if that
wait is too long. The glyphwire-facing architecture is identical either
way — only the thing filling the grid model changes.

Rationale for the split: Phase A delivers the common case now at low
risk and is not wasted work when Phase B lands (the interpreter and the
`Style` flags are needed regardless). Phase B's dependency question
(C API vs. vendored Zig module) does not have a good answer *today* —
see §4 — so committing to it now would be premature.

---

## 3. Where glyphwire is today (the constraint surface)

Relevant existing machinery a fallback has to fit against:

- **`glyphwire-shell` spawn path** (`shell/main.zig` `runCommand` /
  `pumpChildOutput`): `stdin = .ignore`, `stdout`/`stderr` piped, output
  mirrored via `write_text`. `runCommand`'s own doc comment already flags
  the gap: *"this only covers commands that don't need real interactive
  stdin (piped as `.ignore`)"*. A PTY path is exactly the
  "needs interactive stdin, not glyphwire-aware" quadrant that the
  handshake design (`decisions.md`, Discovery & connection) currently
  declares out of scope.

- **The handshake** (`glyphwire.handshake_marker`): distinguishes a
  glyphwire-aware child (draws over its own wire connection) from a plain
  one (mirrored). A PTY-hosted program is unambiguously "plain" — it will
  never write the marker — so the fallback slots in on the
  already-resolved `aware == false` branch, just with a pty instead of a
  pipe and a VT model instead of `flushCapturedStream`.

- **`Layer`'s escape stripper** (`core.zig`, `EscState` =
  `ground|esc|csi|string`): recognizes `ESC [ ... final` and
  `ESC ]|P|X|^|_ ... BEL/ST` well enough to find the end and discard
  them. Reset to `.ground` at the end of every `writeText` call —
  deliberately gives up on a sequence split across two chunks rather than
  letting an unterminated one swallow later output. Phase A grows this
  state machine; Phase B replaces it entirely on the pty path (a real VT
  model owns that parsing).

- **`write_text` styling** (`api.md`, Text & Styling): `fg` / `bg`
  truecolor only. Bold/italic/underline/strikethrough/dim are *decided*
  in `decisions.md` but **not wired** into `Layer.writeText` or the
  `Style` struct. `roadmap.md`'s "Further out" lists "Style attributes
  beyond fg/bg — needs both a `Style` bitflag field and renderer
  support." Any SGR interpretation makes these meaningful, so Phase A
  has to land them.

- **The Context model already generalizes the alt-screen**
  (`decisions.md`, Object Model -> Context): *"This generalizes the
  classic terminal alt-screen buffer (`smcup`/`rmcup`) from a single
  alternate buffer to N independent, persistent contexts."* A
  full-screen program in Phase B should get its **own context** (via
  `create_context`, currently designed-not-built) so dismissing it
  auto-restores the shell's prompt + scrollback — the mechanism is
  already specified, it just isn't implemented and nothing has needed it
  yet. Phase B is the thing that needs it.

- **No `initialize`/`initialized` capability handshake yet**
  (`roadmap.md`, Further out). Not a blocker for either phase, but Phase
  B's "this context is a hosted terminal, N rows x M cols, honour
  resize" is the kind of thing that would eventually be negotiated
  there.

- **Input** (`api.md`, Input): `report_key` / `key_down`/`key_up` in,
  `InputListener` on the client side with a blocking `waitKeyEvent`.
  Phase B's stdin path consumes exactly this stream and re-encodes it to
  pty bytes. `resize` is already wired end to end (`Server.reportResize`,
  `get_property("size")`, `InputListener.pollResizeEvent`) — Phase B
  hooks the resize event to `TIOCSWINSZ` + the VT model's own resize.

---

## 4. What `libghostty` actually offers (reality check)

There are two very different answers depending on whether you look at
what's *released* or what's on `main`.

### 4a. Released: `libghostty-vt` 0.1.0 (installed on this machine)

`ghostty 1.3.1-2` ships `/usr/lib/libghostty-vt.so.0.1.0` with a
pkg-config file (`/usr/share/pkgconfig/libghostty-vt.pc`) and headers
under `/usr/include/ghostty/vt/`. The header set is:

| Header | What it gives |
|---|---|
| `vt/sgr.h` | **SGR parser.** `ghostty_sgr_new/free/reset`, `ghostty_sgr_set_params(params[], separators[], len)`, `ghostty_sgr_next(&attr)` -> tagged union (`BOLD`, `ITALIC`, `FAINT`, `UNDERLINE` + style, `INVERSE`, `STRIKETHROUGH`, `FG_8`/`BG_8`/`FG_256`/`BG_256`/`DIRECT_COLOR_FG`/`DIRECT_COLOR_BG`, bright variants, underline colour, ...). Handles `;` and `:` separators mixed, 8/16/256/X11/RGB colour forms. |
| `vt/osc.h` | **OSC parser.** Byte-at-a-time `ghostty_osc_next`, `ghostty_osc_end(terminator)` -> command with typed data. Recognizes window title, pwd report, clipboard, hyperlink, desktop notification, ConEmu progress, kitty colour, ... |
| `vt/key.h` + `vt/key/encoder.h` | **Key encoder** — key event -> terminal bytes (Kitty keyboard protocol). Directly useful for Phase B's stdin path. |
| `vt/paste.h` | `ghostty_paste_is_safe(data, len)` — bracketed-paste safety check. |
| `vt/color.h` | `GhosttyColorRgb`, `GhosttyColorPaletteIndex` shared types. |
| `vt/allocator.h` | Allocator vtable — **Zig-allocator-shaped**, so a Zig caller passes its own `std.mem.Allocator` through cheaply. `NULL` = libc malloc/free. |
| `vt/result.h` | `GHOSTTY_SUCCESS` / `OUT_OF_MEMORY` / `INVALID_VALUE`. |

**There is no Terminal, Screen, or Parser-state-machine type in the
released headers.** `vt.h`'s prose advertises "maintaining terminal state
such as styles, cursor position, screen, scrollback" and "line wrapping,
reflow on resize" — but none of that is *exposed in the 0.1.0 C API*.
What ships is: parsers for the two hardest-to-hand-roll grammars (SGR,
OSC) plus input encoding.

For **Phase A**, that's actually the right amount: the SGR parser is the
part you don't want to write, and CSI cursor motion (`ESC[<n>A`,
`ESC[<n>;<m>H`, `ESC[K`, `ESC[2J`) is a dozen lines of integer parsing
against primitives `Layer` already has.

### 4b. Unreleased: `libghostty-vt` on `main` / `tip` docs

Upstream has been extending the C API substantially (ghostty
discussions [#11348][d11348], PRs #11676 and #11814, ~Feb–Mar 2026). The
`tip` documentation ([libghostty.tip.ghostty.org][tipdocs]) now lists:

- **Terminal API** — "complete terminal emulator state and rendering";
  feed bytes, read back size / cursor position + visibility / alt-screen
  flag / kitty-keyboard flags, row+cell+style access, grapheme
  extraction, `ghostty_terminal_plain_string` serialization, terminal
  dump.
- **Render State API** — incremental render-state updates for a custom
  renderer (exactly the "diff the grid each frame" shape Phase B wants).
- **Terminal Snapshot API** — encode / incrementally restore terminal
  state (cf. the "reconnectable terminal" exploration,
  [#12176][d12176]).
- **Mouse Encoding**, **Focus Encoding**, **Formatter**, **Unicode
  Utilities**, **Byte-stream I/O**.

Every one of these still carries: *"the API is not yet stable. Breaking
changes are expected."* There is **no tagged release** that includes the
Terminal API as of this writing, and the stabilization effort is
self-described as alpha.

**PTY handling is explicitly out of scope for `libghostty-vt`.** Host
concerns — `openpty`, raw mode, `TIOCGWINSZ`/`TIOCSWINSZ` — were
rejected from the VT library and earmarked for a separate
**`libghostty-pty`** library that **does not exist yet**. So regardless
of which VT model Phase B uses, **glyphwire opens and manages the pty
itself.**

### 4c. Vendoring ghostty's Zig `terminal` module directly

Ghostty's `src/terminal/` (the `Terminal`, `Screen`, `Page`,
`PageList` types) is a mature, full VT implementation — it's what
ghostty itself runs on. It is *not* published to any Zig package
registry ([ziglang/zig#16672][zig16672] is still open), but ghostty can
be added as a git/tarball dependency in `build.zig.zon` and its build.zig
exposes modules to Zig consumers.

Costs of this route:
- Large dependency graph (`uucode` and friends), pinned to a ghostty
  commit, and coupled to whatever Zig version that commit wants — a
  standing maintenance tax every time either moves. glyphwire currently
  tracks `zig 0.17.0-dev`; ghostty tracks its own.
- No API stability promise whatsoever (it's an internal module).
- But: no C ABI marshalling, no waiting on upstream to tag anything,
  and the allocator story is native.

---

## 5. The PTY problem (glyphwire owns this either way)

Zig 0.17-dev stdlib has no `forkpty`/`openpty` wrapper. The shell would
need, on Linux (the only supported platform — cf. `file_watcher.zig`'s
inotify/no-op split):

1. `posix_openpt(O_RDWR | O_NOCTTY)` -> master fd; `grantpt`, `unlockpt`,
   `ptsname_r` -> slave path. (libc calls via `@cImport` or thin
   `extern` decls; a few dozen lines.)
2. Spawn the child with the slave fd as stdin/stdout/stderr, in a new
   session: `setsid()`, `ioctl(slave, TIOCSCTTY, 0)` — or `login_tty`.
   `std.process` can't express "make this a controlling tty", so this is
   a hand-rolled fork/exec or a `posix_spawn` with a file-actions +
   `POSIX_SPAWN_SETSID` setup.
3. Set the initial window size on the slave: `ioctl(master, TIOCSWINSZ,
   &winsize{ ws_row, ws_col, 0, 0 })` from `get_property("size")`.
4. Read loop on the master fd -> VT model. Write loop: `InputListener`
   key events -> encoded bytes -> master fd.
5. On a `resize` event: `TIOCSWINSZ` again + VT-model resize; the kernel
   sends `SIGWINCH` to the child.
6. On child exit / master EOF: tear down, restore the previous context.

None of this is exotic — it's what every terminal multiplexer does — but
it is real systems code with no stdlib cover, and it's the part
`libghostty` has said it won't do for us (until `libghostty-pty`
materializes).

---

## 6. Three paths

### Path (a) — shipped parsers only; grow the stripper into an interpreter

**What:** On the mirrored-output path, stop discarding SGR and simple CSI.
Feed CSI `m` parameters to `ghostty_sgr_*`, map the resulting attributes
onto `Cell.style` (needs the new bitflags), and handle `ESC[<n>{A,B,C,D}`,
`ESC[<r>;<c>H`/`f`, `ESC[K` (0/1/2), `ESC[<n>J` (0/1/2), `ESC[<n>{P,@}`
(-> `delete_cells`/`insert_cells`, already present) directly. Optionally
consume OSC 0/2 (window title) via `ghostty_osc_*` and drop the rest.

**Buys:** `ls --color`, `grep --color`, `git` colour, compiler
diagnostics, `dmesg --color`, spinners and progress bars that repaint a
line with `\r` + `ESC[K`. Basically every non-full-screen CLI program.

**Cost:** Small and bounded. `libghostty-vt` linked for real (it's
already on the system; `build.zig.zon` gets a system-library link or a
vendored build). New `Style` fields + renderer support in
`glyphwire-host` for bold/italic/underline/dim/inverse. One additive
`write_text` param (`attrs`) or a widened `style` object. All headless-
testable in `core_tests.zig`. No stdin, no pty, no protocol-breaking
change.

**Does NOT buy:** anything full-screen. No alt-screen, no cursor-key
mode, no mouse reporting, no `less`/`vim`/`htop`.

**Risk:** low. Worst case the interpreter mishandles an exotic sequence
and we're back to where discarding left us (default styling) — strictly
not worse than today.

### Path (b) — vendor ghostty's Zig `terminal` module for Phase B now

**What:** Add ghostty as a `build.zig.zon` dependency, import its
`terminal` module, build the pty path in `glyphwire-shell` around
`terminal.Terminal`: `t.write(pty_bytes)`, then walk `t.screen` each
frame, diff against the last transpiled grid, emit `write_text` /
`set_property("cursor")` / `clear` for the delta.

**Buys:** full-screen TUIs, now, with a battle-tested VT core (reflow,
wide chars, graphemes, scrollback all handled).

**Cost:** the heaviest dependency in the tree, pinned to a ghostty commit
+ its Zig version, against an explicitly-internal API with zero stability
promise. Every ghostty or Zig bump is a potential breakage to chase.
`build.zig` / `build.zig.zon` churn; CI build time up.

**Risk:** medium-high *maintenance* risk, low *capability* risk.

### Path (c) — wait for `libghostty-vt`'s Terminal C API to tag a release

**What:** same Phase B architecture as (b), but the VT model is the C
Terminal API (`ghostty_terminal_*`), linked the way `libghostty-vt`
0.1.0 already links. Pass glyphwire's allocator through the
Zig-shaped `GhosttyAllocator` vtable. Use `ghostty_key_encoder_*` for the
stdin path for free.

**Buys:** full-screen TUIs against a **stable C ABI**, decoupled from
glyphwire's Zig version, with a much smaller surface than vendoring the
whole engine. Upstream carries the maintenance of the VT core.

**Cost:** **not available today.** No tagged release includes the
Terminal API; the C API stabilization is alpha. Also still no
`libghostty-pty`, so §5 is on us regardless. C-struct marshalling for
per-cell reads (mitigated by the Render State API, which is designed for
exactly this).

**Risk:** schedule risk only — the capability is clearly coming, the
question is when. Nothing to build against yet.

---

## 7. Recommended phasing

1. **Phase A now** — Path (a). Grow the interpreter, land the `Style`
   bitflags, link the installed `libghostty-vt` for its SGR (and
   optionally OSC) parser. Self-contained, immediately useful, not thrown
   away later.

2. **Hold Phase B** until `libghostty-vt` tags a release with the
   Terminal API (Path c). Track [#11348][d11348] / the `libghostty-pty`
   split. When it lands, build the pty path in `glyphwire-shell` against
   the C Terminal API.

3. **Escalation valve:** if Phase B becomes wanted before the C API is
   released, do Path (b) (vendored Zig `terminal` module) as a
   deliberate, time-boxed spike — the glyphwire-side design (pty in
   shell, screen-diff -> existing wire messages, stdin from
   `InputListener`, own context per full-screen program) is identical, so
   swapping the VT model later is contained.

The through-line: **the transpile-to-existing-wire-messages boundary
(the answer chosen for this investigation) means the VT model is an
implementation detail of `glyphwire-shell`.** Neither `glyphwire-host`
nor the wire protocol needs to know a terminal emulator exists. That's
what keeps the dependency decision reversible.

---

## 8. Architecture sketch for Phase B (for reference, not commitment)

```
                 glyphwire-shell
                 +-------------------------------------------+
  pty master fd  |  read -> VT model  ----+                  |
  <===========>  |  (Terminal C API or    |  diff vs. last   |
                 |   vendored zig term)   v  transpiled grid  |
                 |                    screen grid --> write_text / set_property
                 |                                    / clear  ---------------+
                 |  InputListener key events                                  |
                 |   -> key encoder -> pty master fd                          |
                 +----------------------------------------------+-------------+
                                                               v
  child (vim, less, htop) -- owns pty slave --            glyphwire-host
                                                          (unchanged; just
                                                           renders cells)
```

- **Own context:** on launching a full-screen program, `create_context`
  (needs building — designed in `decisions.md`) sized to the current
  `get_property("size")`. On child exit, the server's existing
  "auto-restore previously-visible context on disconnect" behaviour
  brings the shell's prompt + scrollback back untouched.
- **Diffing:** keep the last transpiled `[]Cell` grid; each frame,
  compare row-by-row and emit the minimal `write_text` runs +
  `set_property("cursor")`. A `batch` message (already exists) wraps one
  frame's worth of deltas so the grid updates atomically — the exact
  problem `batch` was built for.
- **Alt-screen inside the program** (vim's own `smcup`) is absorbed by
  the VT model; glyphwire only ever sees the resulting cell grid, so no
  special handling — the "context per program" is about the shell<->program
  boundary, not sequences within the program.
- **Resize:** `InputListener.pollResizeEvent` -> `TIOCSWINSZ` on the
  master + VT-model resize; next frame's diff carries the reflowed
  content.
- **Scrollback:** the VT model has its own; expose it by mapping the
  program's context onto a `Layer` with `scrollback_rows` set, and let
  the existing `scroll_view` path drive it. (Open: whether to transpile
  scrollback rows eagerly or on scroll.)

---

## 9. Wire protocol impact

- **Phase A:** one additive change — text attributes on `write_text`
  (`attrs` bitset, or widen the style object). `api.md` Text & Styling +
  `decisions.md` Style "Open items" (which already anticipates this).
  Everything else reuses existing messages.
- **Phase B:** **no new drawing messages** — that's the point of the
  transpile boundary. It does need `create_context` /
  `destroy_context` finally built (designed, not built) and probably an
  `initialize` capability exchange to mark a context as a hosted
  terminal. Both are already on the roadmap independently.

---

## 10. Testing

- **Phase A:** pure `core_tests.zig` cases — feed byte strings with SGR /
  CSI into `Layer.writeText`, assert `Cell.style` + cursor + cleared
  regions. The `libghostty-vt` SGR parser is deterministic and
  allocator-injectable, so no I/O. A small table of real-world captures
  (`ls --color` output, a `git diff`, a compiler error) as golden
  fixtures.
- **Phase B:** an `e2e_tests.zig`-style test that spawns a tiny known TUI
  (a 20-line `ncurses` or even a hand-rolled `ESC[` script) under the pty
  path and asserts the transpiled `get_cells` snapshot. The VT model
  carries its own upstream test suite, so glyphwire tests only the
  transpile + pty glue. Flaky-class (real process, timing) — same
  caveat the existing `e2e` / `client` groups carry.

---

## 11. Rough effort

| Piece | Size |
|---|---|
| Phase A: `Style` bitflags in `core` + `glyphwire-host` renderer | S–M |
| Phase A: SGR interpret (via `ghostty_sgr_*`) + CSI cursor/erase ops | M |
| Phase A: `build.zig` link `libghostty-vt`, `core_tests` | S |
| Phase B: pty open/session/winsize glue (no stdlib cover) | M |
| Phase B: VT model integration (C API *or* vendored zig module) | M–L |
| Phase B: screen-diff -> wire transpile + `batch` framing | M |
| Phase B: stdin (`InputListener` -> key encoder -> pty) | M |
| Phase B: `create_context` / restore-on-exit (also needed elsewhere) | M |

Phase A is a single focused branch. Phase B is several.

---

## 12. Open questions

1. Phase A: `write_text` `attrs` as a bitset param vs. promoting `style`
   to an object with named fields. The latter is more room to grow
   (underline colour/style, later) but a bigger `api.md` change.
2. Phase A: honour OSC 0/2 window title (-> a host window-title path,
   which doesn't exist) or discard OSC entirely for now?
3. Phase B: eager vs. lazy scrollback transpile.
4. Phase B dependency: is the maintenance tax of vendoring ghostty's Zig
   module (Path b) acceptable as a stopgap, or hold firmly for the C API
   (Path c)?
5. Phase B: does a hosted-terminal context want the `initialize`
   capability exchange built first, or can it ship with an ad-hoc
   context flag?
6. Cross-platform: `file_watcher.zig` degrades to a no-op off Linux. A
   pty path would too — acceptable, or a reason to gate the feature
   behind a build option?

---

## 13. References

- Installed headers: `/usr/include/ghostty/vt/*.h` (`libghostty-vt`
  0.1.0, from `ghostty 1.3.1-2`); pkg-config `libghostty-vt.pc`.
- [ghostty#11348 — Add Parser and Terminal C API to libghostty-vt][d11348]
- [libghostty tip docs][tipdocs] — API groups on `main` (Terminal,
  Render State, Snapshot, Mouse/Focus encoding).
- [ghostty#12176 — Reconnectable Terminal using libghostty][d12176] —
  prior art for a detached VT-server model.
- [ziglang/zig#16672 — Get Ghostty on the Zig Package Manager][zig16672]
- [Mitchell Hashimoto — "Libghostty Is Coming"][libghostty-post]
- glyphwire: `shell/main.zig` (`runCommand`/`pumpChildOutput`),
  `src/core.zig` (`EscState`, `Layer.writeText`/`consumeControl`/
  `stepEscape`), `docs/decisions.md` (Discovery & connection, Object
  Model -> Context, Style), `docs/api.md` (Text & Styling, Input).

[d11348]: https://github.com/ghostty-org/ghostty/discussions/11348
[tipdocs]: https://libghostty.tip.ghostty.org/
[d12176]: https://github.com/ghostty-org/ghostty/discussions/12176
[zig16672]: https://github.com/ziglang/zig/issues/16672
[libghostty-post]: https://mitchellh.com/writing/libghostty-is-coming
