# Roadmap: Next Steps

`docs/slice_plan.md` is done and removed — all 7 of its milestones landed
(headless core through the automated end-to-end proof), plus Milestone 8
(a real pixzig-windowed renderer) has since landed too, and that renderer
has since been split and reworked further (see Current state). This doc
picks up from there: the next slices of protocol/core work, in rough
dependency order. `docs/api.md` has the full aspirational message catalog
with status markers; this doc is about *sequencing* the still-🔶/⬜ parts
of it. `docs/decisions.md` stays the place for *why*.

## Current state

- One `Context`, one root `Layer`, ring-buffer scrollback
  (`scrollback_rows` a creation parameter).
- `write_text` (implicit cursor + fg/bg color only), `insert_cells` /
  `delete_cells` (ECMA-48's ICH/DCH — shift or remove cells at the
  cursor within its row, for a line editor that doesn't want to
  retransmit a whole line on every interior edit), `get_cells` (full
  row-major snapshot), `get_property` / `set_property` (`cursor` only) —
  all implicitly targeting the root layer, since there's no other layer
  to address yet. `insert_cells`/`delete_cells` are row-scoped only —
  see Open questions.
- Real Unix socket server (`src/server.zig`): one thread per connection
  (not "one connection served to completion at a time" as an earlier
  draft of this doc said — concurrency landed once input events needed
  one process reporting input while others stay connected to receive
  it), `Context`-mutex-guarded dispatch, notification fan-out to
  subscribed connections.
- Input is wired end to end: `report_key` / `report_mouse_button` /
  `report_mouse_move` (client→server), `key_down` / `key_up` /
  `mouse_button` (server→subscribed clients), `subscribe`,
  `get_input_state`. Held-key typematic repeat exists for arrow keys
  (`Server.reportKeyRepeat` re-broadcasts `key_down` on a timer without
  touching the down-set, so it doesn't get deduped away). `resize` is
  wired too: the host window is resizable, `Server.reportResize` resizes
  the root layer bottom-anchored and broadcasts `{cols, rows}` to
  `"resize"` subscribers, `get_property("size")` reads it back.
  `mouse_move` is a coalesced server→client stream now (broadcast on a
  cell change, subscribe with `"mouse_move"`); `mouse_scroll` wheel
  deltas, gamepad, and IME are all still open — see Further out.
- **Architecture reshaped since Milestone 8:** `glyphwire-host` (the
  pixzig-windowed renderer, formerly `glyphwire-shell`) now owns the
  `Context` and `Server` *in-process* directly — no wire round trip for
  its own reads or writes, `Server.serveForever` just runs on a
  background thread — and spawns `glyphwire-shell` as a genuinely
  separate child process. `glyphwire-shell` has no pixzig dependency at
  all: it's a pure wire client (`Client` + `InputListener`) implementing
  an interactive line-editing prompt (real cursor-offset tracking,
  interior insert/delete via `insert_cells`/`delete_cells`, ctrl+a/e/u,
  ctrl+arrow word jumps, plain arrow movement). `InputListener` consumes
  key events by blocking on a semaphore rather than polling on a timer.
  `glyphwire-host` also draws a 2px cursor caret and moves the grid
  cursor on arrow keys, independent of the shell's own line editor.
- **`glyphwire-shell` launches programs.** Enter now spawns the submitted
  line as a child process (`Prompt.runCommand`) instead of just echoing
  it: `argv[0]` resolves against `zig-out/bin/` first (a dev-mode
  convenience mirroring `host/main.zig`'s sibling-binary resolution),
  falling back to `$PATH`. The shell spawns it, waits, and resyncs its own
  cursor from `get_property(cursor)` before drawing the next prompt rather
  than assuming a fixed row offset. Whether the child is glyphwire-
  compatible (inherits `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX` and draws to the
  grid itself over its own connection) or a plain program writing to a
  terminal is no longer assumed either way — see the stdout/stderr
  capture bullet below.
- **`glyphwire-ls`** (`ls/main.zig`) is the first program built to be
  launched this way: `lsz`'s directory-scanning core re-targeted to write
  through `Client` instead of ANSI escapes (one entry per row,
  directory/symlink coloring, hidden-file filtering), falling back to a
  plain stdout listing when no session is available, same as every other
  client.
- **A notification-ordering race, fixed in the shared client.** A child
  that writes and exits (like `glyphwire-ls`) could disconnect before the
  server had actually *dispatched* its last few `write_text`/
  `set_property` notifications — process exit only proves the child
  finished *sending*, not that the server caught up — so `glyphwire-shell`
  reading state on its own connection right after `child.wait()` could
  occasionally see stale output (the next prompt drawn before a longer
  listing had actually finished landing). `Client.deinit()` now issues one
  final blocking request before closing the socket, which can't return
  until every prior notification on that connection has been applied —
  fixed once, in the library, for every `Client`-based program, not
  something each client has to remember. See Open questions for the case
  this doesn't cover.
- **Capturing stdout/stderr from plain, non-glyphwire-aware commands.**
  `Prompt.runCommand` now pipes every spawned command's stdout/stderr
  instead of inheriting them, and `Prompt.pumpChildOutput` mirrors them
  onto the grid via `write_text` (terminal-style, with its own `\n`
  handling since `write_text` has none) by default — the assumption for
  any spawned command is "plain program writing to a terminal" until
  proven otherwise. A glyphwire-aware command opts out automatically:
  `Client.connect` writes `glyphwire.handshake_marker` to the process's
  own stdout as part of connecting, no separate call needed since only a
  glyphwire-aware program ever calls `connect` in the first place.
  `pumpChildOutput` checks for the marker before mirroring anything,
  switching to passing the rest of that command's stdio straight through
  to `glyphwire-shell`'s own real stdio instead (still working, just not
  mirrored — see decisions.md's Discovery & connection section). Every
  current glyphwire-aware program (`demo`, `table-demo`, `notify`, `view`,
  `ls`, `client`, and `glyphwire-shell`'s own prompt connection) gets it
  for free just by calling `connect`/`connectFromEnv`. Stdin is
  deliberately left disconnected (`.ignore`) — this only covers commands
  that produce output, not ones that read input interactively.
- 34 tests green as of this writing (one long-standing flaky mouse-button
  race in `inputListenerReceivesReportedInputTest`, unrelated to any of
  the above, not yet fixed).

## A latent robustness gap, partially closed

`Dispatcher.handle`'s errors (unknown method, unknown property, bad
JSON) still propagate as plain Zig errors, not JSON-RPC error
*responses* — there's no `{"error": {"code", "message"}}` wire shape
yet, for `get_property` today or anything else, so a failed *request*
still severs the connection (the client's `request()` call would
otherwise hang forever waiting for a response that will never come).

Notifications are better off now: they have nowhere to report an error
anyway (per JSON-RPC, that stays a server-side log line, not a wire
message) — decisions.md said so from early on, but `serveConnection`
didn't actually behave that way until Phase 3.8 fixed it
(`dispatch.isNotification` + a log-and-continue path), after a failed
`draw_icon` notification turned out to take the whole connection down
same as a failed request would.

The other half of what this section originally flagged — one malformed
message from any client taking down the *whole* server, all connections
and contexts together — is fixed, though as a side effect of unrelated
work rather than a dedicated fix: `Server.serveForever` now spawns a
thread per accepted connection (`serveConnectionThread`), and each one
catches and logs its own `serveConnection` error instead of propagating
it, so a bad connection closes and gets reaped without touching anyone
else. That landed for concurrent input broadcast (one process reporting
input while others stay connected to receive it), not robustness, but it
happens to satisfy what Milestone 0 asked for on that front.

**Milestone 0 (narrowed).** Add real JSON-RPC error responses for
request methods — `get_property` today; `delete_layer` below will need
one for permission-denied.

## Phase 1: Multiple layers (`create_layer`)

**Goal:** a context can hold more than the root layer, addressed by
handle — the concrete thing that unblocks the "45×3 popup in the top
corner" case.

- `Context` gains a layer registry (handle → `Layer`) instead of a bare
  `root: Layer` field. The root layer keeps a fixed, well-known handle
  (mirroring how `default_context_id` already stands in for the missing
  `create_context`) and doubles as the context's **default layer**.
- **Not a breaking change:** `write_text`, `insert_cells`,
  `delete_cells`, `get_property`, and `set_property` gain an *optional*
  `layer` handle parameter — omitting it targets the context's default
  layer, exactly today's behavior. This is the same "baseline tier needs
  no negotiation" instinct decisions.md already applies elsewhere: a
  simple program that only ever wants root doesn't need to learn layers
  exist. `demo/main.zig` and everything else already sending these
  messages keeps working unchanged; only code that wants a second layer
  passes `layer` explicitly.
- `create_layer(context, parent?, position?, width?, height?,
  scrollback_rows?)` → request, returns a server-generated handle.
  `position` (pixel offset in the parent, per decisions.md's Layer
  section) needs to land here too — a popup layer is meaningless without
  somewhere to put it, even before real tree-nesting depth is supported.
- **Out of scope for this phase:** nesting deeper than "parented to
  root" (decisions.md allows it, nothing needs it yet), clip rects,
  z-order beyond creation order (⬜ open — decisions.md doesn't define a
  z-index concept; the renderer needs *some* compositing order as soon
  as a second layer exists, even if it's just "draw in creation order").
- **Coordination point:** the render loop in `host/main.zig` (moved here
  from `shell/main.zig` since Milestone 8 — see Current state) currently
  iterates `ctx.root` directly, both for cells and for the cursor caret;
  it needs to iterate the layer registry once this lands. Sequence this
  with whoever's driving that file.

## Phase 2: Layer lifecycle (`delete_layer`, ownership)

**Goal:** `delete_layer(layer)` — but only the connection that created
it may delete it, per your requirement. This is decisions.md's open
"Multi-process layer ownership" item, now partially resolved: per-layer,
not per-region.

- **Open question — how is "the same process/connection" identified?**
  Two options:
  - *Per-connection identity* (a counter the server assigns at `accept`
    time): simple, portable, and matches how contexts already treat a
    disconnect/reconnect as a fresh identity (auto-restore-on-disconnect
    precedent in decisions.md). A reconnecting client owns nothing from
    its previous connection.
  - *Per-process identity* via `SO_PEERCRED` (kernel-verified PID):
    decisions.md already floats this mechanism for capability caching.
    Survives reconnects, but Linux-only and a process opening multiple
    connections would need those connections treated as one owner.
  - Leaning toward per-connection — simpler, and "the process that
    created it" in your example is naturally satisfied since a program
    keeps a single long-lived connection open for its lifetime anyway.
- `Dispatcher` needs to know which connection it's handling — right now
  `Dispatcher.init(ctx)` + `handle(alloc, body)` has no connection
  context at all. Whatever identity model wins, it threads through here.
- `create_layer`'s response records the creating connection as owner;
  `delete_layer` checks it and returns a permission-denied error
  response (needs Milestone 0's error-response support) rather than
  silently no-op'ing or crashing the connection.
- **Out of scope:** transferring ownership, multiple owners, admin
  override — none of it asked for yet.

## Phase 3: Images (`load_image`, `get_image_info`, `draw_image`) — done

**Goal:** the `Cell.style.bg = .image` arm — already modeled in
`core.zig` since Milestone 1 — becomes reachable. Landed with one
decision revised from what this section originally said (**clip, not
stretch** — see decisions.md's Image section) and the open question below
resolved a third way, better than either option originally listed.

- Wire framing extension landed: `wire.zig`'s `FrameDecoder.takeRaw` /
  `readRaw` consume a declared raw byte count directly, draining any
  already-buffered leftover first, then reading more off the socket —
  the binary side-channel (`{bytes: N, format: "png"}` header immediately
  followed by `N` raw bytes) `load_image` needs. `server.zig`'s
  `serveConnection` special-cases `load_image` (via `dispatch.peekLoadImage`)
  ahead of the normal per-frame dispatch loop, since the payload isn't a
  normal frame.
- **Resolved — where decoding happens:** neither of the two shapes this
  section originally listed. The headless core parses just the PNG
  IHDR chunk's width/height (`core.pngDimensions`, ~15 lines, no image
  codec dependency) instead of a real decode, so `get_image_info` needs
  neither zstbi in core nor client-supplied dimensions. Full pixel
  decoding is still renderer-only (`glyphwire-host`'s `App.textureForImage`,
  lazily on first encountering a handle it hasn't uploaded), exactly as
  this section originally leaned.
- `draw_image(handle, row, col, row_span, col_span)` (`Layer.drawImage`)
  marks each covered cell with `{handle, offset_x, offset_y}` — the pixel
  offset into the source image that cell should show, computed from the
  cell's position relative to the draw call's anchor — rather than
  `Cell.style.bg = .{ .image = handle }` alone; see decisions.md for why
  (clip semantics need a per-cell offset, not just a handle). Needs
  `Context.cell_px_w`/`cell_px_h` (new fields, default 12×12 matching
  `glyphwire-host`'s current tuning) to do that math headlessly.
- Renderer-side work landed: `glyphwire-host`'s `App.drawImageCell`
  resolves `.image` handles to an uploaded texture and draws exactly the
  sub-rect that fits (never stretched, clipped at both the image's own
  edge and the cell edge).
- **New, not in the original plan:** `get_cell_metrics` request (returns
  `cell_px_w`/`cell_px_h`) — a client needs the session's cell pixel size
  to compute `row_span`/`col_span` from an image's natural dimensions
  (decisions.md: aspect-ratio-aware placement is the client's job), and
  nothing already on the wire exposed that.
- **`glyphwire-view`** (`view/main.zig`) is the first client exercising
  this: loads a PNG file given on argv, computes the span from
  `get_image_info` + `get_cell_metrics`, and calls `draw_image`.
- **Out of scope, unchanged:** video.

## Phase 3.5: Icons (`draw_icon`) — done

**Goal:** a way to show one of a bundled set of small images in a single
cell by name, rather than every caller having to `load_image` its own
copy of common icons like "folder" or "audio file" — decisions.md's Icon
section, previously flagged post-v1.

- `Context` gained a second registry (`icons: std.StringHashMap(ImageHandle)`)
  alongside `images`, plus `registerIcon`/`iconHandle`. `draw_icon(row,
  col, name)` resolves through it and reuses `Layer.drawImage` with a 1x1
  span — no new core drawing mechanics.
- `core.default_icon_manifest` is a pure-data name → asset-path table (12
  entries); `glyphwire-host`'s `loadDefaultIcons` (real file I/O, kept out
  of core per headless-first) reads each file and registers it at
  startup, logging and skipping any that fail rather than blocking boot.
- Icons are colorful PNGs from the KDE Oxygen theme (LGPLv3), sourced at
  32x32 and downscaled to the session's 12x12 cell size so `draw_icon`
  doesn't clip them — see `assets/icons/oxygen/README.txt` for attribution
  and the full file list. Picked over a flatter monochrome set
  deliberately, to actually show off drawing real artwork into a cell.
- **Out of scope:** theming (a context-local catalog overriding the
  global one) and a wire-exposed way to list/query the catalog's
  contents — both still open, see decisions.md.

## Phase 3.6: Box drawing (`draw_box`) — done

**Goal:** build boxes/panels on screen out of corner/edge/fill tiles —
the background-tile registry idea from the original planning
conversation, resolved in favor of a tile-based 9-slice approach over a
vector shape+border primitive (that alternative stays unbuilt).

- `Layer.drawBox(tiles: BoxTiles, row, col, rows, cols)` places one of 9
  tiles per cell by role (corner/edge/fill, decided by whether a cell is
  on the box's top/bottom row and/or left/right column), always at that
  tile's own pixel origin — unlike `drawImage`'s offset-from-anchor math,
  each cell is independently "this tile, from the start," which is what
  makes an edge or fill actually *tile* across multiple cells instead of
  only covering the first one or two before running out of source pixels.
  Both `drawImage` and `drawBox` now funnel through a shared
  `setCellImage` primitive.
- `draw_box(row, col, rows, cols, style)` (dispatch.zig) resolves the 9
  pieces by name (`"{style}-tl"`, `"{style}-t"`, ... `"{style}-fill"`)
  against the *same* `icons` catalog `draw_icon` already uses — no new
  registry. A future second style is just more manifest entries under a
  different prefix, no protocol change.
- The bundled `"box"` style (`core.default_box_manifest`, 9 files in
  `assets/icons/box/`) is generated, not sourced from an icon theme:
  simple single-line corners/edges rendered directly to 12x12 (supersampled
  then downscaled for antialiasing) with Pillow, sidestepping any
  licensing question for what's just straight lines meeting at a corner.
  The fill tile is fully transparent, so a box's interior shows through to
  whatever background color/content is already there.

## Fixed since Phase 3.6

- **A dangling-pointer bug made images/icons/box tiles render for a
  moment then vanish, sometimes crashing `glyphwire-host`.**
  `eng.renderer.draw()` (pixzig's sprite batch) stores the `*const
  Texture` pointer it's given and only dereferences it later, at
  `flush()`/`end()` — not immediately. `App.textureForImage` was caching
  a `Texture` by value and handing the batch the address of a local stack
  copy, which went dangling the instant the drawing function returned.
  Fixed by caching the `*ManagedTexture` pool instead and returning a
  pointer into its heap-allocated `Handle`, which pixzig documents as
  staying at a stable address for its full lifetime.
- **`glyphwire-view` draws and exits immediately — no keypress wait.**
  Launched from `glyphwire-shell`'s prompt (the common case, e.g.
  clicking a `.png` in an `ls` listing) the image stays on the grid and
  the prompt returns at once. Launched directly as `glyphwire-host`'s
  exec'd child (`glyphwire-host glyphwire-view <path>`, where this
  process *is* what would have been the shell — `reapChild`/`shell_exited`
  treats any exec'd child's exit as "done"), the window closes right
  after the image is drawn. Every `draw_image`/`set_property` request has
  already round-tripped by the time `main` returns, so the pixels are
  committed server-side and any renderer paints them next frame; there is
  nothing left to wait for. (An earlier revision blocked on a keypress
  "like a real image viewer" — dropped, the wait was noise everywhere
  except the exec'd-child case, and even there it just delayed an
  inevitable close.)

## Phase 3.7: `clear`

**Goal:** a way to reset cells back to blank without a client redrawing
over everything with spaces — needed once `draw_image`/`draw_icon`/
`draw_box` mean a region can have *content* (not just stale text) left
over from a previous draw.

- `clear(row?, col?, rows?, cols?)` (`Layer.clear`) resets a region to
  the same zero-value blank cell `Layer.init` starts with — empty
  grapheme, default style, no image background. `rows`/`cols` default to
  "the rest of the layer from `row`/`col`" (themselves defaulting to 0),
  so a bare `clear()` wipes everything — one call covers both "clear a
  region before redrawing it" and "clear the whole screen" (ctrl+l).
  `demo/main.zig` calls the all-defaulted form once up front (it writes to
  several disjoint areas — the styled-text runs, the box/icon panel — so
  clearing just the panel's own region wasn't enough to keep a re-run from
  leaving stale content elsewhere), then explicitly moves the cursor a
  couple of rows below the panel when it's done, since none of
  `draw_box`/`draw_icon` move the cursor themselves and leaving it inside
  the panel made `glyphwire-shell`'s next prompt land on top of the icons.
- `glyphwire-shell`'s prompt now binds ctrl+l to clear the screen and
  redraw the current line (prefix + whatever's already typed) at the top,
  same as a real shell — `Prompt.clearScreen`, sharing a
  `writePromptPrefix` helper with `showPrompt` rather than duplicating
  the cwd-prefix logic.

## Phase 3.8: Icons in `glyphwire-ls`

**Goal:** the first real use of `draw_icon` by an actual tool, not just
the demo — a leading icon per listed entry, chosen from a coarse
extension → icon-registry-name table (`ls/main.zig`'s `extension_icons`):
directories get `"folder"`, recognized extensions map to `"image"`/
`"audio"`/`"video"`/`"archive"`/`"executable"`/`"media-optical"`, anything
else falls back to `"file"`. Not a real mime-type lookup (no such
dependency pulled in) — extension sniffing covers the same buckets for
what a directory listing actually needs.

**Found and fixed along the way — notification errors used to sever the
whole connection.** `glyphwire-ls` run against a bare `Context` with no
icon registry loaded (exactly what the existing e2e test does; only
`glyphwire-host` loads `default_icon_manifest`) made every `draw_icon`
call fail server-side, and that dispatch error propagated all the way up
through `Server.serveConnection`, closing the connection entirely —
`glyphwire-ls`'s next write then failed too, so a single unresolvable
icon name took down the whole listing. This contradicted what
decisions.md already said should happen ("Notifications with no id still
have nowhere to report an error anyway... that stays a server-side log
line, not a wire message") — the code just didn't actually do that yet.
Fixed generally, not just for `draw_icon`: `serveConnection` now checks
whether a failed message was a notification (`dispatch.isNotification`)
and logs-and-continues if so, only propagating (severing the connection)
for a failed *request*, where there's no error-response mechanism yet to
answer it with instead — see Milestone 0, still open.

## Fixed since Phase 3.8: icons silently stopped appearing after enough rows

**Symptom:** running `glyphwire-ls` a few times in the same session, icons
would render for a while and then just stop showing up on later rows,
with no error anywhere — text kept appearing correctly throughout.

**Root cause:** `glyphwire-ls`'s `writeGrid` tracked its own local `row`
counter across the whole listing, incrementing it by 1 per entry. Once
enough entries had been written (cumulatively, across possibly several
`ls` runs) to reach the bottom of the grid, the *server* would scroll the
viewport the next time `write_text` advanced the cursor past the edge
(`putAtCursor` already handled this) — but `draw_icon`'s explicit `row`
had no equivalent handling: `Layer.drawImage`'s old span-clamping just
silently drew nothing once `row >= height`. `ls`'s local counter had no
way to know the scroll had happened, so every `draw_icon` call after that
point named a row that no longer meant anything, while the corresponding
`write_text` (cursor-based, self-correcting) kept landing fine.

**Fix, two parts:**
- `Layer.resolveRow(row)` — scrolls the viewport (capped at `capacity()`
  iterations, so a wild client-supplied row can't spin the server
  forever) until `row` refers to an in-bounds row, same as `putAtCursor`
  already did for the cursor advancing past the edge. Wired into
  `set_property(cursor)` and into `drawImage`/`drawBox`/`drawIcon`'s own
  anchor row, so *every* absolute-row API behaves consistently whether it
  came from typing past the bottom or a client naming a row directly.
- `glyphwire-ls`'s `writeGrid` no longer tracks a local row counter at
  all — it calls `get_property(cursor)` fresh before each entry and uses
  that. One extra request per entry, but it means the row `draw_icon` and
  `write_text` both use for an entry is always whatever the server
  actually just resolved, never a locally-computed guess that can drift.

**Also landed while fixing this:** `Background` gained a third variant,
`icon: ImageHandle`, instead of icons reusing `ImageBg` (handle + pixel
offset). An icon always shows the whole source image scaled into the
whole cell — no offset or per-cell pixel math needed at all — so
`Layer.drawIcon(handle, row, col)` is now just "resolve the row, stamp
the handle," simpler than routing through `drawImage`'s clip-oriented
per-cell offset logic. `glyphwire-host`'s renderer picks this variant
apart with its own draw path (`drawIconCell`): aspect-correct scale to
fit the cell, centered, rather than `drawImageCell`'s clip-not-stretch —
see decisions.md's Icon section for why the two draw operations
deliberately disagree on this. The default icon set went back to its
native 32x32 (no longer needs pre-shrinking to a specific cell size now
that it scales) — see `assets/icons/oxygen/README.txt`.

**Known follow-up, fixed below:** the bundled `"box"` tile set
(`assets/icons/box/`) is still 12x12 and still clip-based (`draw_image`'s
rule, unchanged) — `glyphwire-host`'s cell size has since been retuned
away from 12x12 (see `host/main.zig`'s `cell_w`/`cell_h`), so box borders
may now clip slightly rather than filling the cell exactly. See "Box
tiles move to scale-to-fit" below.

## `draw_image`/`draw_icon`/`draw_box` now default to the cursor

`row`/`col` are optional on all three, defaulting to the layer's current
cursor when omitted — the same convention decisions.md already documented
for `write_text` (and, unlike `write_text`, only wired in there loosely
before now) but had never actually been extended to the draw-a-thing
family. `Dispatcher.resolveAnchor` is the shared resolution point.
`glyphwire-ls`'s icon draw uses this now (`drawIcon(null, null, ...)`
instead of repeating the row it already knows the cursor is sitting at)
— doesn't reduce its per-entry request count (it still needs the row
value itself, to position the name one column over and to advance to the
next row), but removes a redundant explicit position that was always
just restating where the cursor already was.

## Tilde expansion in command arguments, and `glyphwire-ls`'s zargunaught port

`Prompt.runCommand` (shell/main.zig) now expands a leading `~`/`~/...` in
*every* argument before spawning, the same way `doCd` already did for
`cd`'s target — most spawned programs don't do their own tilde expansion
(that's normally the shell's job), so `cat ~/notes.txt` used to hand the
child a literal `~` it had no way to resolve.

`glyphwire-ls`'s arg parsing was ported from lsz's `zargunaught`-based
pattern (`zargs.ArgParser` + `hasOption`/`positional`) instead of a
hand-rolled loop, gaining `--help` for free alongside the existing
`-a`/`--hidden`. New: `-l`/`--long`, adding size and modified time columns
— `std.Io.Dir.statFile`'s cross-platform `Stat`, not lsz's raw
`fstatat`/`getpwuid`/`getgrgid` C bindings, so no full permission-bit/
owner/group columns (matches this file's existing "deliberately narrower
than lsz" scope).

**A real, intermittent test bug found and fixed along the way.** The new
e2e test for tilde expansion (`shellExpandsTildeInCommandArgsTest`) hung
the test binary outright the first few times, for two separate reasons:
a fixed `acceptOne` thread count that didn't account for `glyphwire-ls`
making its own connection once the typed command spawned it (fixed by
switching to `serveForever`, matching how `glyphwire-host` itself runs,
instead of hand-counting connections), and a `typeText` test helper that
didn't handle the space character, panicking on `unreachable` in a way
that testz's per-test output capture never surfaced (diagnosed with a
standalone repro built outside the test harness, since testz buffers a
hung test's output and never flushes it). Once actually visible, the
remaining flakiness was genuine timing, not a logic bug: spawning a
second real process (`ls`) on top of the shell needs more headroom under
load than `waitForCell`'s original ~2s budget — bumped to ~10s.

## Box tiles move to scale-to-fit, and a 32x32 edge-hugging redraw

Resolves the "Known follow-up" left open in Phase 3.6: the bundled
`"box"` tile set was 12x12 and clip-based, drawn against a cell size that
has since moved, so borders no longer filled the cell exactly.

- `Layer.BoxTiles` changed from 9 `{handle, width, height}` structs (fed
  into the same clip-based `setCellImage` primitive `drawImage` uses) to 9
  plain `ImageHandle`s, stamped via `Background.icon` — the same
  scale-to-fit variant `draw_icon` already uses. `draw_box`
  (dispatch.zig) no longer needs `imageInfo()` at all now that there's no
  per-cell pixel offset to compute; resolving each of the 9 names against
  the `icons` catalog is the whole job.
- The bundled tiles were regenerated at 32x32 (matching the icon set) with
  the border lines redrawn hugging the outer edge of each tile rather than
  centered within it — see decisions.md's Box section for why: it's what
  makes a box usable as a background/panel frame with the interior cell
  still available for content, instead of the border eating a margin.
- `core_tests.zig` and `dispatch_tests.zig`'s box assertions moved from
  `.style.bg.image.handle` to `.style.bg.icon` to match.

## Fixed while stress-testing the above: two real races in the test suite

Running the full suite repeatedly (not just once) to confirm the box
change surfaced two pre-existing, intermittent bugs unrelated to it —
neither reproduced reliably on a single run, which is exactly why they'd
gone unnoticed.

- **`Server.serveForever`-spawned connection threads could outlive the
  `Server` that owned them, segfaulting inside `unregisterConnection`.**
  `serveForever` spawns one thread per accepted connection and discards
  the handle (`_ = try std.Thread.spawn(...)`), correct for
  `glyphwire-host`'s real usage where the `Server` lives for the whole
  process — but in an e2e test, `Server` is a local variable on the test
  function's stack. Killing/closing every client a test spawned doesn't
  guarantee the *server-side* thread handling that connection has finished
  unwinding through `unregisterConnection` by the time the test function
  returns and `srv.deinit()` frees `self.connections` out from under it —
  a race, not a hang, so it only crashed intermittently (roughly 1 in 4-8
  full-suite runs), and `coredumpctl`'s backtrace was needed to actually
  see `mem.findScalar`, called from `unregisterConnection`, segfaulting on
  reused stack memory. Fixed by having `Server` track every
  `serveForever`-spawned thread (`connection_threads`) and join all of
  them at the start of `deinit`, before freeing anything they touch — safe
  for `glyphwire-host` (which never calls `deinit`) and correct for tests
  (which, by construction, close every connection before reaching
  `deinit`, so the join can't hang).
- **`inputListenerReceivesReportedInputTest` (client_tests.zig) asserted
  a mouse-button broadcast landed after only polling for a *different*,
  earlier key-down broadcast to land.** `reportKey` and
  `reportMouseButton` are two separate async notifications; waiting for
  the first gave no guarantee the second had also arrived, so the
  assertion occasionally ran too early. Fixed by polling for both
  conditions together instead of just the first.

## `draw_box`'s `BoxMode.stretch`, and `glyphwire-notify`'s `"dialog"` style

Phase 3.6's `draw_box` only ever repeated each of the 9 tiles once per
cell (`BoxMode.tile`, now named that in hindsight) — fine for a border
that's meant to repeat, but a *gradient* tile repeated per cell bands
instead of blending, since every cell shows the same full image again
from the top. Built to give `glyphwire-notify` an actual reason to exist
beyond a plain single-color box: a Final-Fantasy-style dialog panel (light
blue fading to dark blue, white border) that has to look like one
continuous picture no matter how tall or wide the notification ends up
being.

- `core.Layer.BoxMode` (`tile` | `stretch`) is a new required param on
  `Layer.drawBox`, threaded through from `draw_box`'s new optional `mode`
  wire field (`"tile"`/`"stretch"`, default `"tile"` — same
  `InvalidIconOption` error `scale`/`h_align`/`v_align` already get for a
  bad value). `.tile` is bit-for-bit the old behavior.
- `.stretch` still resolves the same 9 `"{style}-*"` tiles (no protocol
  change to `style` itself) but treats each edge/fill role's *one* source
  image as a single logical picture spanning its whole run: `t`/`b` across
  every interior column, `l`/`r` across every interior row, `fill` across
  the whole interior rectangle. A cell partway along a run gets that
  fraction of the image, stretched to fill just that cell — four new
  fields on `core.IconBg` (`src_l/src_t/src_r/src_b`, normalized 0..1,
  defaulting to the whole image) carry the slice, and
  `host/main.zig`'s `drawIconCell` was one line away from supporting it:
  the UV rect it already passed to `eng.renderer.draw` was hardcoded to
  `{0,0,1,1}`, now it's `icon.src_l/src_t/src_r/src_b`. Corners never
  slice (always exactly one cell), so this never divides by an
  empty interior — see `Layer.drawBox`'s doc comment for why that's safe
  without an explicit guard.
- `Client.drawBoxStyled`/`drawBoxOnStyled` (opts struct with `mode`) are
  new, additive methods alongside the existing `drawBox`/`drawBoxOn` —
  same reason every other `*Styled`/`*On` split exists: Zig has no default
  parameter values, and `drawBox`/`drawBoxOn`'s existing call sites
  (`demo/main.zig`, tests) shouldn't have to pass a mode they don't care
  about.
- Bundled a second box style, `"dialog"` (`core.default_dialog_manifest`,
  `assets/icons/dialog/*.png`), procedurally generated (no art pipeline
  in this repo) rather than hand-drawn: flat corners/left/right edges in
  their end's color, and `t`/`b`/`fill` each holding the *full*
  left-to-right gradient so `.stretch` can slice whatever fraction of it a
  given column needs. Gradient runs left-to-right rather than top-to-
  bottom because `glyphwire-notify`'s box is wide and short (3 rows, one
  interior row) — a vertical gradient only had one row of cells to spread
  across and read as barely more than a flat band; horizontal is the axis
  that actually spans most of the notification.
- `glyphwire-notify` now takes an optional leading type keyword
  (`info`/`warn`/`error`/`warning`/`err`, case-insensitive, default
  `info` when omitted or when there'd be no message left over —
  `glyphwire-notify error` with nothing else is treated as the message
  "error", not a typeless notification) and draws a matching icon
  (`core.default_notify_icon_manifest`, `"notify-info"`/`"notify-warn"`/
  `"notify-error"`), `.natural`-scaled and vertically centered up to 2
  cell-heights tall (`glyphwire-ls`'s own icon treatment), to the left of
  the text. Needed `Client.drawIconOn`/`drawIconOnStyled` (`draw_icon` on
  a non-root layer) as new additive methods too — nothing previously
  needed to draw an icon anywhere but root.

**Found while actually looking at the result:** both the type icon and the
message text were blanking the gradient behind them instead of sitting on
top of it.

- **The icon.** `draw_icon` sets `Cell.style.bg`, one of `Background`'s
  mutually exclusive cases (color/image/icon) — so drawing the type icon
  at a cell the `"dialog"` fill had just painted didn't overlay it, it
  *replaced* it outright, leaving a flat icon-shaped hole (transparent
  PNG background showing through to whatever's behind the layer) instead
  of the gradient the icon was supposed to sit on top of. Fixed with a new
  `Cell.fg_icon` field and `draw_icon`'s `foreground: true` (see
  decisions.md's Icon section and `Layer.drawIconOver`) — a second,
  independent icon slot the host's render pass draws after that cell's
  background *and* grapheme, so it composites over both instead of
  competing with either. `glyphwire-notify`'s type icon now sets it.
- **The text.** `write_text` always replaces a cell's whole `style`
  outright — deliberately, per `Cell.metadata_id`'s doc comment, the same
  way `draw_icon` used to — so leaving `bg` omitted didn't mean "keep
  the gradient," it meant "reset to `default_style.bg`" (opaque black),
  punching a black bar through the panel under the message. First pass
  papered over this with an explicit `bg` approximating the `"dialog"`
  gradient's midpoint color — a real but unsatisfying approximation, and
  wrong the moment the panel's colors or the text row's height changed.
  Fixed properly instead: `write_text`'s new `transparent_bg: true` (see
  decisions.md's Wire operation: styled text runs section) leaves each
  touched cell's existing background alone entirely, the text-side
  counterpart of `draw_icon`'s `foreground: true` above. Required
  splitting `Layer.writeText`/`writeTextTagged`'s single `style: Style`
  param into `fg: Color` + `bg: ?Background`, since `null` needed a place
  to mean "don't touch it" — `Cell.style` itself is unchanged (still
  always a concrete, resolved `Style`); only the write call gained the
  option to leave half of it alone. `glyphwire-notify`'s message now uses
  `Client.writeTextOnTransparent` and shows the actual gradient through
  the text, not an approximation of it.

## `glyphwire-ls` grid columns, size colors, perms padding, multi-operand + file operands

A batch of `glyphwire-ls` improvements, all client-local (no wire
protocol change — `docs/api.md` and `docs/decisions.md` untouched). The
pure helpers now live under the `ls_support` module: `ls/support.zig`
re-exports `ls/gridlayout.zig` (column-packing math) and `ls/format.zig`
(size / permission-bit / timestamp formatting), so `tests/ls_tests.zig`
can exercise them directly — same split `shell/support.zig` has.

- **The plain (non `-l`) listing packs into columns.** It used to write
  one entry per row; the original doc comment even called out "no
  terminal-width grid packing (doesn't mean anything over a fixed-size
  cell grid)" — which stopped being true once `get_property("size")`
  exposed the layer width. New pure module `ls/gridlayout.zig` (under the
  `ls_support` module, same cross-directory-`@import` dodge
  `shell_support` uses so `tests/ls_tests.zig` can reach it): given the
  entry count, the longest entry's display width, and the layer width, it
  picks how many entry columns fit and returns a `Grid` (columns, rows
  per column, cell stride between blocks, name-area width). `writeGrid`
  fills the grid **column-major** (down the first column, then the next,
  like `ls -C`), one physical "band" of `block_rows` cells at a time,
  re-reading the cursor per band so a mid-listing scroll doesn't desync
  the row — same reason the old code re-read it per entry. Works in both
  icon modes: `block_rows` is 1 for `-S`'s single-cell icons, 2 for the
  default `.natural`-scaled icons that overflow into the next row. A
  listing whose longest name leaves no room for a second column comes out
  single-column and, in that case only, names are left un-truncated (long
  symlink targets included); a multi-column grid clips each name to its
  column with a trailing `…`, the same shape `core.writeCellRun` already
  uses server-side.
- **`-l` Size column is colored by magnitude** (`sizeColor`): sub-KB
  stays the dim detail-gray, KB-range green, MB-range amber, GB-and-up
  red — so a big file stands out without reading digits. One color per
  cell (a table cell has a single fg), picked from the raw byte count,
  not the formatted string.
- **`-l` Perms column widened 10 → 11.** The perm string is exactly 10
  chars and left-aligned, so the extra cell is a trailing blank; Perms is
  the last column, so it reads as a right margin on every row (the
  `alt_row_bg` stripe included).
- **Multiple operands, and file (not just directory) operands.**
  `classifyAndList` splits the command-line operands (default `["."]`)
  into the coreutils render layout: one headerless block for every
  non-directory operand (collected together, name-sorted), then one block
  per directory operand, each under an `<operand>:` header — headers only
  appear when there's more than one block, so a lone `ls` / `ls somedir`
  is unchanged. Blocks are separated by a blank row. A file operand is
  stat'd without following symlinks (a symlink operand shows as
  `name -> target`, not expanded), and `FileEntry` grew an `abs_path`
  field so a block that mixes directories still tags each entry's
  metadata with its own real path (`writeGrid`/`writeLongTable` dropped
  their single `abs_dir_path` param).
- **`-l` total line.** Each `-l` block gets a coreutils-style `total`
  line above it. coreutils counts 512-byte disk blocks; no cross-platform
  block count is available (`std.Io.File.Stat` is byte size only), so
  this sums the entries' byte sizes and formats them like the Size
  column (`--bytes` included).
- **`-h` / `--bytes` size format.** `--bytes` prints raw integer byte
  counts instead of KB/MB/GB (and widens the `-l` Size column to fit);
  `-h` / `--human` is the explicit opposite and wins if both are passed.
  The human form stays the default, so plain `glyphwire-ls -l` is
  unchanged.

Not done (candidate next steps): sort flags (by mtime / size / reversed —
note `-S` is already taken for "small format", so a size sort needs a
different letter or a `--sort=` option), `-d` (list the directory entry
itself, not its contents), and recursive `-R`.

## `batch` messages, and `glyphwire-ls`'s two-frame listing

A `batch` message carries an ordered list of other messages, applied
server-side in one pass under the single lock hold the server already
takes per message — see decisions.md's Batch section for the *why* and
api.md's Batch section for the wire shape. The motivating problem was
`glyphwire-ls`: its listing arrives as dozens of separate draw
notifications interleaved with per-entry `create_metadata` round trips,
and glyphwire-host renders frames throughout, so the listing visibly
paints itself a band at a time and scrolls as it goes.

- **Wrapper method, not a JSON-RPC top-level array.** `{method: "batch",
  params: {messages: [{method, params, id?}, ...]}}`. `dispatch.zig`'s
  `handle` split into a parse step + a `dispatchEnvelope` step so each
  sub-message routes through the identical catalog; one new handler, no
  parser change, stays `jq`-inspectable.
- **Notification form** (no outer `id`): fire-and-forget, no reply.
  **Request form** (outer `id`): reply is `{responses: [<full JSON-RPC
  response object>, ...]}`, one per sub-message that carried an `id` and
  produced a result, tagged with that sub-message's batch-local id.
- **Best-effort, not transactional** — a failing / parse-broken /
  batch-invalid sub-message is logged and skipped, the rest still runs
  (same treatment a standalone notification's dispatch error already
  gets; core has no rollback). `batch` and `load_image` can't be nested;
  other broadcast-producing messages are accepted but their broadcast is
  dropped.
- **Client helper:** `Client.batch()` returns a `Client.Batch` builder
  (`notify` / `request` generic adders plus typed conveniences —
  `writeText`, `setCursor`, `drawIconStyled`, `tagMetadata`,
  `createMetadata`); `send` returns `BatchResults`, keyed by the `Slot`
  each request adder returned. Every adder serializes immediately, so
  caller buffers are reusable straight after.
- **`glyphwire-ls` now:** `writeGrid` sends the whole listing as two
  batches — one request creating every entry's metadata tag, then one
  notification with every draw call — and tracks the draw row locally
  (`@min(draw_row + block_rows, rows - 1)`, mirroring `Layer.resolveRow`'s
  scroll-and-clamp) instead of a per-band `get_property("cursor")` round
  trip. `writeLongTable` batches just its per-entry `create_metadata`
  calls; its drawing was already a single `table_set_rows`.

Not done (candidate next steps): intra-batch handle references (a
sub-message referencing an earlier sub-message's returned handle), which
would let `glyphwire-ls` drop even the metadata round trip and send the
entire listing in one notification frame; and letting `scroll_view` /
input messages in a batch actually deliver their broadcasts.

## Fixed: backgrounded rows lost their content while scrolling a large listing

**Symptom:** scrolling a full-window `glyphwire-ls` icon table, the rows
that have a background color would lose their text/icons — but only some
of them, split at roughly a fixed height on screen (backgrounded rows
above the split blank, below it fine, or the reverse), and the same cell
would flip between showing and hiding as the view scrolled up and down.

**Root cause:** host-side paint order, entirely in `App.renderLayer`. It
walked the whole grid once, interleaving `drawFilledRect` (color
backgrounds), `drawStringColored` (text), and the icon draws into a single
`begin`/`end`. That relied on pixzig submitting a pass's batches in a
fixed order (sprites, shapes, overlays, text) — but a pixzig batch also
**auto-flushes when it fills past its quad capacity** (1000 by default). A
big grid pushes the shape batch (one quad per backgrounded cell) past 1000
partway down, so those early background rects get drawn immediately;
meanwhile the text batch keeps filling and only flushes at `end()`, on top
of them — except where the text batch *also* overflowed first, leaving the
last backgrounds to flush over already-drawn glyphs. Which rows landed on
which side of the overflow moved with the scroll position, hence the
flicker.

**Fix (host only):** `renderLayer` now draws each category in its own
`begin`/`end`, fully flushed before the next: color backgrounds → image
backgrounds → icons (`draw_icon` backgrounds + every foreground/table
icon, `.natural` overflow still deferred to the end of that pass) → text
→ cursor caret. The passes run per `Layer`, so a popup with an opaque
background still fully covers the layer beneath it. Capacity overflow
within a category now only costs an extra draw call, never a misorder.
`glyphwire-host`'s renderer is also configured with `maxSprites = 30_000`
(new `pixzig.RendererOptions` field — pixzig's batch element indices were
widened `u16` → `u32` to allow it) so a whole large grid of solid
backgrounds still fits one draw call per category. No wire protocol
change; `api.md` untouched.

## All codepoints in the host font atlas (dynamic glyphs + fallback)

`glyphwire-host` used to draw text through pixzig's fixed ASCII-only font
atlas: `FontAtlas` packed codepoints 32-126 once at startup, and
`TextRenderer.drawString*` walked the byte slice looking each byte up as a
`u8` — so a Greek/Cyrillic/CJK filename from `ls` decoded to nothing. The
grid model was already fine (`core.Cell` stores an 8-byte UTF-8 grapheme
cluster; `Layer.writeText` splits on codepoints; metadata stores the raw
path bytes), so this was purely a rasterization + render-loop gap.

Fixed entirely on the pixzig side, consumed here:

- **`FontAtlas` is now a growing, on-demand atlas.** It keeps the font
  bytes + a `stb_truetype` handle, a CPU copy of a single square
  grayscale texture (starts 1024², **doubles on overflow** up to 8192²,
  Ghostty-style), a shelf packer, and a `codepoint → Character` cache.
  Glyphs load **eagerly per 256-codepoint block**: the first time any
  codepoint in a block is drawn, the whole block is rasterized and the
  texture re-uploaded. A grow copies existing rows into the wider buffer
  at the same pixel offsets (no re-raster) and re-normalizes every UV;
  `TextRenderer` flushes any queued quads before committing a grown
  texture so in-flight glyphs aren't sampled against the wrong size.
- **Fallback faces + tofu.** `FontAtlas.faces` is an ordered list —
  primary first, `addFallbackFace*` appends. A codepoint the primary
  lacks is filled from the first fallback that has it; a codepoint **no**
  face has renders the atlas's `.notdef` box (rasterized from the primary
  face's glyph 0 at init, so tofu is always in the base glyph set).
  `pixzig.renderer.findFaceIndexByName` + `initFromTtfFileIndexed` /
  `measureFontFileIndexed` / `RendererInitOpts.font.path.face_index` add
  `.ttc` collection support.
- **`TextRenderer` decodes UTF-8 codepoints**, not bytes, in every
  draw/measure path; malformed bytes render as U+FFFD.

Host wiring: the primary font is now `assets/NotoSansCJK-Regular.ttc`
(face "Noto Sans Mono CJK JP", found by name at startup), which covers
Latin + Greek + Cyrillic + CJK from one monospaced face;
`assets/JetBrainsMono-Regular.ttf` is registered as a fallback via
`renderer.addDefaultFontFallback` mostly to keep the fallback path
exercised (user-selectable fonts are coming). `demo/main.zig` writes
"hello world" in Greek, Russian and Japanese.

**East Asian wide characters** (follow-up in the same branch, after the
first render showed CJK glyphs overlapping): CJK/kana/Hangul are
full-width and were being packed into one grid cell each, so every glyph
overran its neighbour. Now `core.codepointWidth` (a compact hand-baked
Unicode 16.0.0 East Asian Width `W`/`F` range table, `A` = narrow)
drives a 2-cell model — `Cell.wide` = `narrow`/`wide_lead`/`wide_spacer`,
`writeText` places the grapheme in the lead + a blank spacer and advances
the cursor by 2 (wrapping a wide glyph off the right edge), and
`writeCellRun` (server-side table cells) does the same. `get_cells` gains
a `wide` field (`"lead"`/`"spacer"`) — **this is a wire change**, so
`api.md` + `decisions.md` are updated (the wide-char item there moves
from Open to Built). `glyphwire-ls` lays its columns out with the same
width model (`gridlayout.displayWidth` / width-aware `truncateToCols`).
The host renderer needs no change: a wide glyph's bitmap is naturally
~2 cells wide and the spacer draws nothing. `mono CJK` fonts give Latin a
0.5 em advance and CJK a 1.0 em advance, which is exactly this 1:2 cell
ratio.

The bundled `.ttc` is ~19 MB — a JIS-X-0208 subset would cut that to a
few MB at the cost of tofu for rare kanji; deferred. Grapheme
segmentation (UAX #29) is still open — width is measured per base
codepoint, so ZWJ emoji / combining clusters aren't handled as one unit.

## JPEG / BMP / GIF alongside PNG in `load_image`

`glyphwire-view` was PNG-only; the request was JPEG support and it grew to
all four "simple header" formats. `load_image`'s `format` field, which
used to be sent-but-ignored, is now parsed server-side
(`core.ImageFormat.fromName`, accepting `"jpg"` for `jpeg`) and picks the
header parser that measures the image: `core.imageDimensions` dispatches
to `pngDimensions` (unchanged), new `jpegDimensions` (walks marker
segments to the first SOFn and reads its 16-bit height/width), new
`bmpDimensions` (BITMAPCOREHEADER u16 or BITMAPINFOHEADER+ i32 w/h, abs
value for a top-down negative height), and new `gifDimensions` (logical
screen descriptor). All are fixed-offset header reads, ~15-40 lines each,
**no codec dependency in the headless core** — pixel decoding stays
glyphwire-host's stb_image, which already auto-detects every one of these.
`ImageEntry` gained a `format` field; `Context.loadImage` takes the format
now. An unknown `format`, or bytes that don't match the declared one,
fails the `load_image` request (`dispatch.DispatchError.UnsupportedImageFormat`
from `peekLoadImage`, or the format-specific `ImageError` from the parser —
same connection-severing path a malformed PNG already took). **This is a
wire change** (the `format` field is now load-bearing), so `api.md` +
`decisions.md` are updated. `glyphwire-view` picks the format by sniffing
the file's magic bytes (`core.detectImageFormat`), not its extension, and
its usage / doc comments now say "image" not "PNG".

Follow-up in the same branch, both client-local (no wire change):

- **`glyphwire-shell`'s click-to-view opens JPEG/BMP/GIF too, not just
  PNG.** `activateSelectionAt` matched the literal `"image/png"`; it now
  runs `glyphwire-view` for any mimetype `core.ImageFormat.fromMimetype`
  recognizes (new helper — PNG/JPEG/BMP/GIF, deliberately not the
  `image/svg+xml` / `image/webp` entries `glyphwire-ls` also tags, since
  the viewer can't render those). `glyphwire-ls` needed no change — its
  `extension_mimetypes` table already tagged `.jpg`/`.jpeg`/`.gif`/`.bmp`.
- **The clicked path is single-quoted into the synthesized command line**
  (`wordsplit.quoteArg`, new — the inverse of `splitArgs`, emitting an
  embedded `'` as `'\''`). `activateSelectionAt` builds a string that goes
  back through `dispatchLine`'s split, so a name with a space or a shell
  metacharacter previously tokenized wrong; now `cd`/`glyphwire-view` on a
  clicked `my holiday pics/beach 2.jpg` works.

14 new tests total: 9 `core` (the four parsers + `detectImageFormat` +
`fromMimetype` + declared-format-mismatch + format-stored), 1 `dispatch`
(unknown format rejected), 4 `shell` (`quoteArg` round trips); 269 pass.

## Configurable prompt

`shell.conf`'s `prompt{ ... }` defines the prompt, in either of two
shapes: plain template strings (`left` / `right` / `exit` / `dur`), or
**powerline segment lists** (`left_segments` / `right_segments` +
`sep` / `head` / `tail` / `lines` / ...). All client-local (no wire
change) — `decisions.md`'s Shell section has the "Prompt templating"
subsection (incl. a "Powerline segments" part); `api.md` is untouched.

- **`shell/prompt_template.zig`** (new, in `shell_support`, pure) parses a
  template into an ordered op list (`text` / `icon`). Tokens `{cwd}`
  (`$HOME`→`~`), `{cwd_full}`, `{user}`, `{host}`, `{time}`, `{env:NAME}`,
  `{icon:NAME}`; `{{` / `}}` literal braces; `\n` `\t` `\\` unescaped; an
  unknown `{token}` left verbatim. `{exit}` / `{dur}` are **conditional
  sections**: `{exit}` renders the `exit` sub-template only on a non-zero
  last exit status, `{dur}` renders the `dur` sub-template only when the
  last command ran `>= dur_min_ms` (default 2000). Inside those,
  `{exit_code}` and `{duration}` (humanized: `450ms` / `1.5s` / `2m5s`)
  are the values; a `max_depth` guard stops a self-referential section.
  Also `parseColor` (`#rgb` / `#rrggbb`).
- **`shell/config.zig`** — `prompt{ ... }` binding (one table arg, keys
  optional, calls merge) → `config.PromptConfig`. The plain string keys
  plus the powerline keys: `left_segments` / `right_segments` (arrays of
  `{ text|[1], fg, bg, when }`), `sep` / `sep_right` / `head` / `tail` /
  `right_head` glyphs, `lines`, `input`, `time_format`. All the prompt
  strings/segments live in a `ShellConfig.prompt_arena` — `luaPrompt`'s
  validation raises Lua errors (a `longjmp` past Zig `defer`), so
  wholesale arena cleanup in `deinit` is the only leak-safe option.
- **`shell/main.zig`**: `writePromptPrefix` picks `writeDefaultPrefix`
  (unchanged `<cwd> > `), `writeTemplatedPrefix` (string form), or
  `writePowerlinePrefix` (segments). `Prompt` now keeps the parsed
  `ShellConfig` alive for the session (`prompt_config`) rather than
  copying fields out. Powerline drawing: `renderChain` renders visible
  segments into one arena, `drawChain` lays a bg strip + composites text
  transparent + `draw_icon foreground`, separators coloured
  `fg = left bg` / `bg = right bg`. `{time}` via a libc
  `time`/`localtime_r`/`strftime` extern block.
- **Line editor → repaint model.** Every edit mutates the local `buffer`
  and calls the new `renderInputLine`, which repaints the whole box
  `[line_start_col, input_max_col)` from a horizontally-scrolled
  (`input_scroll`) window and places the cursor — replacing the
  `insert_cells` / `delete_cells` shifting. This bounds the input against
  a locked right prompt and scrolls a long line inside its zone.
  `submitLine` re-echoes the full command unbounded first so scrollback
  is complete. A single-line powerline right chain is redrawn per
  keystroke + on the idle timeout (so `{time}` ticks); a 2-line prompt
  puts segments on row 1 and input on the last row, untouched by typing.
- **`src/pty.zig`**: `Pty` decodes the `waitpid` status into
  `exit_code` (exit code, or `128 + signal`); `reaped` / `wait` take
  `*Pty`. `runCommand` records `last_status` / `last_dur_ms` /
  `have_status` for the next prompt (external commands only; timing via
  `std.Io.Clock` — no `std.time.Timer` in this std).
- **Assets:** `assets/icons/distro/{arch,tux,debian,fedora,ubuntu}.png`
  (simple geometric renderings, not official artwork) → `distro-*` in
  `core.default_icon_manifest`. `assets/PowerlineSymbols-subset.ttf` (a
  ~20 KB `pyftsubset` of a Nerd Font to U+E0A0–E0D7), registered as an
  extra always-on host fallback face in `host/main.zig`.
- **Tests:** `tests/prompt_template_tests.zig` (group `prompt`, ~40
  cases incl. `{time}` / `{env}` / `parseColor`) + `shell_config_tests`
  for the `prompt{}` binding and the segment lists.
- **Deferred — the Lua-function prompt.** `shell.conf` sets a callback
  that receives the same data items and batches its own draw commands, so
  a prompt can shell out for git state, k8s context, a `zig version`
  pill, etc. Recorded in `docs/ideas.md`; the string + segment forms are
  the first slices, and `prompt_template`'s `Op` list / `Data` snapshot
  are already the right shape to hand to a callback.

## Caret / scroll fixes: pin on mouse scroll, `scrolloff`, backspace repeat, right cap

Four reported rough edges, all client-local (no wire change — `api.md`
untouched; `decisions.md` Layers + Shell sections updated):

- **Caret pinned on a mouse scroll (`glyphwire-host`).** A wheel /
  scrollbar scroll used to leave the caret glued to the live prompt's
  screen cell while the content scrolled under it. It's now pinned
  (`App.caret_pin`) to the buffer cell it was on when the scroll began,
  rides the content, and clips off-screen once that cell leaves the
  viewport. Any key/text releases the pin and snaps the view back to the
  live tail (`clearCaretPinForKey`); a client moving the cursor releases
  it without a view change (`reconcileCaretPin`). Keyboard browse in the
  shell never pins (it scrolls via `scroll_view`, not the host's own
  wheel path), so its caret keeps following the browse cursor as before.
- **`scrolloff` for shell scrollback browsing.** `browseUp` / `browseDown`
  keep a configurable margin (`shell.conf` `prompt{ scrolloff = N }`,
  default 8) between the browse cursor and the top / bottom of the
  window, scrolling the window at the margin instead of only when the
  cursor is jammed against the edge. Down still can't move past the
  prompt row.
- **Typematic repeat for Backspace / Delete / Ctrl+U (`glyphwire-host`).**
  `App.key_repeat` (was `arrow_repeat`) now also drives these editing
  keys — held Backspace in the shell repeats. Arrows' Ctrl+left/right
  word motion already repeated; character keys repeat via the `text`
  stream. Enter/Tab stay single-shot.
- **Right powerline chain gets a left cap.** `right_head` falls back to
  `head` when unset (mirrors `sep_right` → `sep`), drawn in the first
  *visible* right segment's bg (an `error` segment's colour, or the
  time's). The right-chain redraw also moved to a single `batch` frame
  (chain + trailing caret restore) so the idle-tick redraw no longer
  blips the caret out to the right and back on a 2-line prompt.
- **The shell handles window resize.** It subscribes to `"resize"` and
  `Prompt.handleResize` re-lays-out the prompt: updates `grid_cols` /
  `grid_rows`, shifts the prompt top by the (bottom-anchored) height
  delta, redraws the prefix + input box. Fixes the right chain sticking
  to the old column and the off-grid `set_property` creep after a shrink.
- **Blink is host-only, confirmed.** `cursor_blink` lives entirely in
  `host/main.zig` (`tickBlink` / `caretVisible` toggle one render pass);
  no wire message, no grid-model mutation, nothing in `src/` or `shell/`.
- **Tests:** `tests/shell_tests.zig` `browseUp`/`browseDown` scrolloff
  math; `tests/host_tests.zig` (new group `host`) for the caret-pin
  screen-row / clip logic; `tests/shell_config_tests.zig` for the
  `scrolloff` key.

## `conf.lua` gains initial grid size + scrollback, plus template configs

Host-local, no wire change (`api.md` untouched; `decisions.md` "Font config"
section got a grid/scrollback bullet).

- **`assets/conf.lua` keys.** `config.grid_cols` (120), `config.grid_rows`
  (50) and `config.scrollback_rows` (1000) join the existing font / caret
  keys. `loadConfig` reads them with a new `luaUintField` helper
  (non-negative, integral), clamps `grid_*` up to `min_grid_*` and
  `scrollback_rows` down to `scrollback_rows_max` (100000), each with a
  warning if it clamped. `HostConfig` gained a `grid: GridConfig` with
  `?usize` fields — null means "conf.lua didn't set it".
- **CLI still wins.** `loadConfig` moved above the arg loop in `main` and
  seeds `grid_cols` / `grid_rows` from the file; the existing `--grid-cols`
  / `--grid-rows` flags then overwrite. `scrollback_rows` is now a
  module-level `var` (was `const`) so config can change it before
  `Context.init`.
- **Template configs.** `host/conf.lua.template` and
  `shell/shell.conf.template` — every option at its default, every line
  commented out, with the syntax rules and token reference inline. They're
  the copy-and-uncomment reference; `assets/shell.conf.example` stays as
  the shorter worked example. `assets/conf.lua` also gained the three new
  keys, commented out.
- **No tests.** `loadConfig` links pixzig (for `ScriptEngine`) and isn't
  reachable from `tests_exe`; there's still no `host` test group. Verified
  by `zig build` + the full suite; the actual window-open size needs a
  `zig build host` eyeball.

## More bundled icons: prompt status glyphs + file-type buckets

No wire change (icons resolve server-side by name; `draw_icon` already
takes a name). `api.md` untouched; `decisions.md` Icon section gained the
file-type-bucket + `status-` namespace notes and the Shell / Powerline
section a pointer to the two status icons.

- **`status-error` / `status-slow`.** A new `core.default_status_icon_manifest`
  (loaded by `host/main.zig` alongside the box/dialog/notify manifests),
  `assets/icons/status/{error,slow}.png` — KDE Oxygen `edit-delete` (a
  bare red cross) and `chronometer` (a stopwatch), normalized to 8-bit
  RGBA. Meant for `{icon:status-error}` in a `when = "error"` powerline
  segment and `{icon:status-slow}` in a `when = "slow"` one. `status-`
  prefix for the same reason `notify-` has one.
- **File-type buckets.** `default_icon_manifest` gained `pdf`, `document`,
  `spreadsheet`, `presentation`, `text`, `code`, `web`, `package` (Oxygen
  mimetype art, `assets/icons/oxygen/`). `glyphwire-ls`'s extension →
  icon table moved to a pure `ls/icons.zig` (in `ls_support`, so
  `tests/ls_tests.zig` can reach it) and grew mappings for those buckets;
  `.sh` / `.bash` / `.zsh` / `.fish` moved from `executable` to `code`.
  `extension_mimetypes` gained the matching office-format + `.deb` /
  `.rpm` entries.
- **Template configs.** `shell/shell.conf.template` and
  `assets/shell.conf.example`'s powerline example now use
  `{icon:status-error}` / `{icon:status-slow}` and are seeded from a real
  two-line powerline config.
- **Tests.** 5 `ls` cases for `lsicons.iconForExtension`, 1 `core` case
  asserting every bundled manifest entry is well-formed, uniquely named,
  and includes the new names. **347 pass.** The icons rendering under a
  real host still needs a `zig build host` eyeball.

## `glyphwire-host` config moves to `~/.config/glyphwire/host.conf`

No wire change. `api.md` untouched; `decisions.md` "Font config" section
updated, README's "Font configuration" section rewritten.

- **New location.** `glyphwire-host` used to read `assets/conf.lua`
  relative to its working directory (the repo root in dev mode) — the
  repo's own checked-in file, so a user couldn't keep a real config
  without editing tracked source. It now runs
  `~/.config/glyphwire/host.conf`, resolving the directory by the exact
  same rule as the shell's `shell.conf`: `$GLYPHWIRE_CONFIG_DIR`
  verbatim, else `$XDG_CONFIG_HOME/glyphwire`, else
  `$HOME/.config/glyphwire`.
- **`configDirPath` in `host/main.zig`.** A byte-for-byte copy of the
  shell's `configDirPath` (a Zig module can't be shared across the
  `shell/` and `host/` directories). Returns `error.NoConfigHome` when
  none of the three env vars are set; `loadConfig` treats that (and a
  missing file) as "run on the built-in `*_default` constants", silently.
  A file that fails to read/parse still warns.
- **Format unchanged.** Same global `config` table, same keys (`font_*`,
  `cursor_*`, `grid_*`, `scrollback_rows`), same clamps and warnings. The
  `--grid-cols` / `--grid-rows` flags still win (loaded before the arg
  loop, as before). Relative `font_face` / `font_fallback` paths still
  resolve against the host's working directory, not `host.conf`'s
  directory.
- **Template renamed.** `host/conf.lua.template` → `host/host.conf.template`,
  header rewritten to list the three candidate paths like
  `shell/shell.conf.template` does. `assets/conf.lua` is no longer read
  and can be deleted (left in place for now).
- **No tests.** Same as the prior host-config milestones: `loadConfig`
  links pixzig and isn't reachable from `tests_exe`. Verified by
  `zig build` + the full suite (**347 pass**); the actual file pickup
  needs a `zig build host` eyeball.

## Icon catalog: directory scan + one atlas texture

No wire change (icon names resolve server-side; the change is which names
the bundled set registers under). `api.md`'s `draw_icon` / `draw_box`
rows and `decisions.md`'s Icon + Box sections updated.

- **The `assets/icons/` tree is the manifest now.** `glyphwire-host`'s
  `loadIconsFromDir` recursively walks `assets/icons/` at startup and
  registers every `.png` under its path there minus the extension
  (`core.iconName`). The five hand-maintained `core.default_*_manifest`
  arrays are gone; `glyphwire.iconName` is the only survivor. Names moved
  to the path form: `folder` → `oxygen/folder`, `distro-arch` →
  `distro/arch`, `notify-info` → `notify/info`, `status-error` →
  `status/error`, and `draw_box`'s tiles from `box-tl` → `box/tl`
  (`borderTileHandle` joins with `/` now). All bundled configs/templates
  (`shell.conf.example`, `shell.conf.template`), `ls/icons.zig`,
  `ls/main.zig`, `notify/main.zig`, `demo/main.zig` and the asset
  READMEs updated to the new names.
- **User icon overrides.** After the bundled scan, `loadIconsFromDir`
  runs again on `~/.config/glyphwire/icons/` (the `host.conf` config dir,
  `warn_if_absent = false`). `registerIcon` overwrites by name, so a file
  at a bundled relative path (`icons/oxygen/folder.png`) replaces that
  icon in the atlas and a new path (`icons/mine/logo.png` → `mine/logo`)
  adds one; a replacement logs one info line, a missing directory is
  silent. `host.conf.template` documents it.
- **One atlas texture.** `App.buildIconAtlas` (runs in `App.init`, after
  the GL context exists) decodes every registered icon, shelf-packs them
  into a 1024-wide `glyphwire-icon-atlas` texture (tallest-first, 1px
  transparent gutter, height rounded to the next power of two), and fills
  `App.icon_uv: handle → normalized sub-rect`. `drawIconCell` samples
  that one texture for every icon, mapping `IconBg.src_*` through the
  icon's atlas rect; it falls back to a per-handle `image_textures`
  upload for a handle the atlas didn't get (decode failure, or a
  `load_image` handle passed to `draw_icon`). `load_image` user images
  stay on their own textures. A build failure is non-fatal (`icon_atlas`
  stays null, every icon takes the fallback path).
- **Why:** pixzig's sprite batch flushes on a texture bind change, so a
  screen full of distinct icon textures — an `ls` icon grid, a
  `draw_box` border — was one flush per icon. One bound texture collapses
  that, and is the prerequisite for the **StaticBatch host render path**
  (below): the grid's icons can't live in a batch that's only rebuilt on
  a content change until they all share a texture.
- **Tests:** `core_tests.zig`'s bundled-manifest walk replaced by
  `iconNameDerivesFromPathTest` (path → name, `.png`-only,
  case-insensitive extension). `dispatch_tests.zig`'s
  `registerTestBoxStyle` and `ls_tests.zig`'s `iconForExtension`
  expectations updated to the `/`-joined / `oxygen/`-prefixed names.
  `prompt_template_tests.zig` / `shell_config_tests.zig` token strings
  updated to `distro/arch`. No host test group exists — the atlas
  packing and rendering need a `zig build host` eyeball.
- **Next (not this change):** a **StaticBatch host render path**. Right
  now `App.render` rebuilds every quad and swaps the buffer every frame.
  With icons on one texture and text on the font atlas, the host could
  build a `StaticBatch` per layer once and re-upload only when the grid's
  revision changes or a paint is forced (cursor blink, resize), leaving
  idle frames as a bare re-present. See `decisions.md`'s Icon section.

## Selectable file-type icon theme + configurable icon sizes

No wire change beyond one optional `TableStyle` field. `decisions.md`'s
Icon + Table sections, `api.md`'s `create_table` / `table_set_style` /
`table_set_rows` / `table_get_state` rows, `README.md` and
`host.conf.template` updated.

- **`file/*` is a themed name.** The coarse folder/file/mimetype icons
  moved from `assets/icons/oxygen/` to `assets/icons/filetype/<theme>/` —
  `oxygen` (48x48 via `scripts/fetch-oxygen.sh`), `material` and `papirus`
  (both via `scripts/fetch-icon-themes.sh`, which follows the relative
  symlinks Papirus stores colour variants / mime aliases as). The
  generic `assets/icons/` walk skips `filetype/`; `host/main.zig`'s
  `loadFiletypeTheme` loads the one `host.conf`'s `icon_theme` selects,
  under both `file/<name>` and the alias `oxygen/<name>`. Unknown / empty
  theme → warn, fall back to `oxygen`. `ls/icons.zig` and the sample
  configs now use `file/*`; the alias keeps a user's existing
  `{icon:oxygen/…}` working.
- **`ls.conf`.** New `~/.config/glyphwire/ls.conf` (`ls/config.zig`, a Lua
  `config` table via the vendored Lua lib now linked into `ls`) with
  `large_icon_px` (32) / `small_icon_px` (16). `writeGrid` /
  `writeLongTable` use them for the `.natural` cap and derive the band /
  row height from `ceil(px / cell_h)` instead of a fixed 2-vs-1.
- **`TableStyle.max_icon_px`.** Plumbed client → protocol → dispatch →
  `core.TableStyle`; `writeBodyRow` caps a body icon to
  `min(row_height * cell_px_h, max_icon_px)`. `glyphwire-ls` sets it so a
  tall `-l -L` row's icon matches the grid's size. `null` (any other
  table) keeps the old row-height-only cap.
- **`configDirPath` shared.** The identical copy in `host/main.zig` and
  `shell/main.zig` moved to `src/config_dir.zig`
  (`glyphwire.configDirPath`); `ls` uses it too.
- **Tests:** `ls_tests.zig` gains `ls.conf` parse cases and its
  `iconForExtension` expectations move to `file/*`; `table_tests.zig`
  gains `tableStyleMaxIconPxCapsBodyIconTest`; the `writeGrid` band-height
  change shifts a couple of row numbers in the `e2e` browse test. No host
  test group — the theme swap needs a `zig build host` eyeball.

## Prompt command vars, and Home/End line-editing keys

Two client-local shell changes (no wire change — `api.md` untouched;
`decisions.md` Shell section's "Prompt templating" + line-editor bullets
updated, `shell/shell.conf.template` documents both):

- **`prompt{ commands = { name = "cmd" } }` — on-demand command vars.** A
  map of var name → `/bin/sh -c` command line (a bare string, or a table
  with `when` / `timeout_ms`). `{name}` in any prompt template string or
  powerline segment expands to the command's trimmed stdout. The
  declarative slice of the deferred "Lua-function prompt": enough for
  git branch / dirty / ahead-behind, k8s context, a `zig version` pill,
  without a new Lua surface.
  - **Lazy, and memoised for the life of one prompt.** A command runs
    only if a template actually references its `{name}` this draw, at
    most once — `Prompt.cmd_var_cache`, cleared by `resetCmdVars` at the
    top of `writePromptPrefix`. The idle right-chain refresh and a
    multi-line redraw reuse the cached values; the next prompt re-runs
    them. So a `git` call is once per prompt, not once per 500 ms tick.
  - **`when` gates the run and takes a `{var}` expression.** A command
    var's optional `when` is a template expression; the command runs
    only when it renders truthy (`prompt_template.whenTruthy` —
    non-empty, not `0`/`false`; leading `!` negates). Segments gained the
    same form: `PromptSegment.when_expr`, set by `shell/config.zig` when
    the Lua `when` value contains a `{` (the `always|error|slow`
    keywords are unchanged). One cheap `is_repo` probe can then gate
    every `git` command so none run outside a repo. Truthiness is
    output-based, not exit-code — `{name}` means "its output" everywhere.
  - **Synchronous with a 400 ms default cap** (`timeout_ms` overrides);
    on timeout the child is killed and `{name}` renders empty. Async
    background repaint considered and deferred — bounded stall, once per
    prompt.
  - **`prompt_template` stays pure.** New `Data.vars` hook
    (`VarResolver` = opaque ctx + `resolve(ctx, name) ?[]const u8`),
    consulted only for a token no built-in field claimed; `null` keeps
    "unknown token stays verbatim". `shell/main.zig`'s `resolveCmdVar` is
    the impl, with a name-stack cycle/depth guard for a `when` that
    references its own var. `prompt_template.whenTruthy` is the shared
    truthiness rule.
- **Home / End = ctrl+a / ctrl+e.** Added to `runPrompt`'s key handling
  as plain aliases (no `ctrl` required), in every state — the ctrl
  chords already snapped browse mode back to the live line via
  `moveCursorTo`, and Home/End inherit that.
- **Tests:** `tests/prompt_template_tests.zig` — the `Data.vars` resolver
  hook (fill / null-keeps-literal / empty value / built-in field wins /
  inside an `exit` section) and `whenTruthy`; `tests/shell_config_tests.zig`
  — `commands` string + table forms, `run` key, multi-entry, merge-across-
  calls, bad-entry / negative-timeout rejection, and a segment
  `when = "{var}"` kept as `when_expr`. 374 pass.

## Layer selection + copy / paste

**Done.** Text selection in a layer, Ctrl+Shift+C / Ctrl+Shift+V, and
Ctrl+Shift+C with nothing selected copying the current prompt. Wire
change — `docs/api.md` gained a Selection & Clipboard section and three
server→client notifications; `docs/decisions.md` a Selection & clipboard
subsection.

- **`core.Layer.selection` (`?Selection`)** — two `SelectionPoint`
  (`{above: i64, col}`) ends. `above` = rows above the live viewport top,
  content-anchored: `scrollOne` bumps both ends by one (pin to content as
  output scrolls), an end past retained history drops the whole
  selection, `resize` drops it. `setSelection` / `updateSelectionActive`
  / `clearSelection` mutate it; `selectionColRange(above)` (renderer, per
  row) and `selectionText(alloc)` (extraction: interior rows whole,
  first/last clipped to start/end col, trailing blanks trimmed,
  `wide_spacer` skipped, rows joined `\n`, `""` for a zero-width
  selection) read it.
- **`core.Context.clipboard` (`std.ArrayList(u8)`) + `clipboard_serial`**
  — one session buffer. `setClipboard` replaces + bumps the serial;
  `clipboardText` borrows it.
- **Wire:** `set_selection` / `update_selection` / `clear_selection`
  (notifications, broadcast `selection`), `get_selection` /
  `get_selection_text` (requests), `set_clipboard` (notification) /
  `get_clipboard` (request). `Subscriptions` gained `selection` and
  `clipboard` (the latter covers `copy_request` + `paste`).
  `rpc.selectionNotification` / `copyRequestNotification` /
  `pasteNotification`. `Server` in-process helpers: `setSelection` /
  `clearSelection` / `selectionText` / `setClipboard` / `requestCopy` /
  `broadcastPaste` / `clipboardSerial` / `clipboardText`.
- **`src/client.zig`:** `setSelection` / `updateSelection` /
  `clearSelection` / `getSelection` / `getSelectionText` / `setClipboard`
  / `getClipboard`. `InputEvent` gained `.paste` (owned text, inserted
  literally by the shell without submitting) and `.copy_request` (the
  shell answers with `set_clipboard prompt.buffer.items`), both on the
  same ordered queue as `key`/`text`. `InputListener.handleNotification`
  parses `paste` / `copy_request`.
- **`shell/main.zig`:** subscribes `"clipboard"`; the runPrompt loop
  handles `.paste` (insert like `.text`, newlines kept) and
  `.copy_request` (reply `client.setClipboard(prompt.buffer.items)`); the
  pty-passthrough loop feeds `.paste` straight to the child.
- **`host/main.zig`:** `handleSelectionKeys` (Ctrl+Shift+C/V/Space, plus
  select-mode arrows / Home / End / Escape / Enter), `handleMouseSelection`
  (left drag → selection, plain click → synthetic press+release so the
  shell's `activateSelectionAt` still fires), `syncClipboardToOs` (push
  `ctx.clipboard` to the OS on serial change, main-thread GLFW),
  `selectionSwallows` (holds the shortcut/motion keys back from
  `reportKeyEvents`), a translucent highlight drawn in `renderLayer`'s
  `color_bg` pass. `select_mode` short-circuits the shell-bound
  `handleRepeatKeys`; a held arrow instead repeats through
  `App.select_repeat` (its own `KeyRepeatState`s, same
  delay/interval), extending the selection at the typematic cadence.
- **Not visually verified** — the highlight, keyboard select mode, mouse
  drag, and OS-clipboard round trip need a `zig build host` eyeball
  (flagged to the user; per `feedback_no_screenshots` don't screenshot).
- **Tests:** `core_tests.zig` +8 (`selectionText` span / order / empty,
  `selectionColRange` clipping, scroll-pin + eviction, resize clear,
  clipboard buffer), `dispatch_tests.zig` +4 (`set_selection` →
  `get_selection_text`, `clear_selection` inactive broadcast,
  `set_clipboard` → `get_clipboard`, subscribe accepts the new events),
  `rpc_tests.zig` +2 (`selection` / `copy_request` / `paste` shapes),
  `client_tests.zig` +1 (selection + clipboard round trip over a
  socket). 388 pass.

## `ls` metadata as data + `open_actions` table + multi-select marks

**Done.** `glyphwire-ls` now tags entries with `kind` / `path`
(+ `mimetype` for files) and no embedded command; the shell resolves what
to run through a `shell.conf` `open_actions` table over built-in
defaults, and can mark several entries to open at once. Wire change —
`docs/api.md` gained a Highlights section and four requests;
`docs/decisions.md` a Highlights subsection in Selection & clipboard plus
`open_actions` bullets in the Shell section.

- **`core.Layer.highlighted_ids` (`std.ArrayList(MetadataHandle)`)** — a
  set of metadata ids, not cell ranges. The host renderer tints any cell
  whose `metadata_id` is in the set (per-cell, in the `color_bg` pass),
  so highlights follow their content through scrollback and survive a
  `resize` with no row math — no `scrollOne`/`resize` handling, unlike the
  selection. `isHighlighted` / `toggleHighlightId` / `setHighlightIds` /
  `clearHighlightIds`. Wire: `toggle_highlight` (names a *cell*; the host
  resolves the id and flips it), `set_highlight` (`ids`), `clear_highlight`,
  `get_highlight` — all **requests** answering with `HighlightState`
  (`{entries: [{id, json}]}`, each id's stored blob bundled in). No
  `get_cells` scan on the client — that was the first cut and was dropped
  as slow and the wrong shape (see the feedback memory / decisions.md).
- **`ls/main.zig`**: `entryMetadataJson` replaces `mimetypeForEntry` —
  `{kind, path}` always (`kind` ∈ file/directory/symlink/other), plus a
  real `mimetype` only for `kind == "file"`.
- **`shell/openaction.zig`** (NEW, pure, in `shell_support`): `resolve`
  (exact mimetype → `group/*` → kind keyword, user table over defaults,
  more-specific wins across forms) + `expand` (`{sel}` = one quoted path,
  errors on >1; `{selections}` = one or more, space-joined). Defaults:
  `directory` → `cd {sel}`, PNG/JPEG/GIF/BMP → `glyphwire-view
  {selections}`.
- **`shell/config.zig`**: `open_actions{ ["key"] = "cmd" | {"cmd", ...} }`
  binding (`luaOpenActions`), collected into `ShellConfig.open_actions`
  (arena-backed, accumulates across calls). `OpenActionDef` is
  `openaction.Action` verbatim. `commands` is a list so a future
  action-picker menu isn't designed out; only `commands[0]` runs today.
- **`shell/main.zig`**: a plain left click always runs the clicked
  entry's own action (`activateSelectionAt` → `openActionLine`, one
  `get_metadata` — a targeted lookup, not a grid scan), regardless of
  what's marked. **Ctrl+click** (or Space while browsing) toggles the
  mark; `toggleHighlightAt` sends `toggle_highlight` and rebuilds
  `Prompt.marks` (`{kind, path, mimetype}`) from the response via
  `applyHighlight`. Browse-Enter with marks runs `runMarkedAction` (the
  keyboard multi-open path); Escape → `resetMarks`; `submitLine` drops
  the marks (a `resize` doesn't). `copy_request` with marks copies the
  newline-joined paths.
- **`InputListener` now posts `input_sem` on a `mouse_button`
  notification too**, so a shell parked in `waitInputEvent` between
  keystrokes wakes on a click and handles it on the next loop turn
  instead of after the 500 ms fallback heartbeat (`waitInputEvent`
  returns null — the loop already treats that as an idle tick and drains
  the mouse queue at the top). The click's own work is a single
  `toggle_highlight` request over the local socket; the visible tint is
  the host rendering `layer.highlighted_ids` on its next frame.
- **Tests:** `openaction_tests.zig` (NEW, group `openaction`, 15:
  resolve precedence / user-over-default / last-match / group-slash-guard,
  expand quoting / join / `NeedsSingle` / passthrough), `core_tests.zig`
  +3 (`toggleHighlightId`/`isHighlighted`, `setHighlightIds`/`clear`,
  survives-resize), `dispatch_tests.zig` +2 (`toggle_highlight` flips the
  id and returns the blob, `set`/`clear` replace the id set),
  `shell_config_tests.zig` +5 (`open_actions` string / list / accumulate /
  bad-value / empty-list). 429 pass.

## Multi-select copy is space-separated, and pasted newlines flatten

**Done.** Follow-up to the multi-select marks above. Copying a set of
marked `ls` entries (Ctrl+Shift+C, host selection empty) now puts them on
the clipboard as one **space-separated** line, each path quoted only when
it needs it, so the text pastes straight back after a command name
(`ls `, `cp … `) as a working argument list — the earlier newline-joined
form made `ls` choke on the first paste. The line editor is still
single-line: pasted text has its `\n` / `\r` runs flattened to single
spaces on the way in, and the word-splitter now treats a bare newline as
a token separator too, as a backstop. No wire change — client-local, so
`docs/decisions.md`'s Selection & clipboard + Shell sections were updated,
`docs/api.md` untouched. A real multi-line prompt editor is still a future
change (deliberately deferred).

- **`wordsplit.splitArgs`**: `' ', '\t'` separator case → `' ', '\t',
  '\n', '\r'`. A multi-line paste that still reaches `dispatchLine` splits
  one argument per line instead of fusing into one unusable token.
- **`wordsplit.quoteArgIfNeeded`** (NEW): returns the string as a bare
  owned dupe when every byte is a "plain word" char (`A-Za-z0-9` plus
  `@%+=:,./_-`, the `shlex.quote` unreserved set), otherwise falls back to
  `quoteArg`. The empty string quotes to `''`.
- **`lineedit.flattenNewlines`** (NEW): every maximal `\n` / `\r` run in a
  slice → one space, as an owned copy (newline-free input still comes back
  as a fresh allocation, so callers free unconditionally). Called from the
  shell's `.paste` handler before `insertText`; the pty-passthrough
  `.paste` path is left verbatim so a foregrounded program still gets the
  newlines.
- **`shell/main.zig`**: `markedPathsText` joins with `' '` and runs each
  path through `quoteArgIfNeeded` (was `'\n'` + raw). The `.paste` arm in
  the prompt loop flattens before inserting.
- **Tests:** `shell_tests.zig` +5 — `splitTreatsNewlinesAsSeparators`
  (newline / CRLF / blank-line list → per-line tokens),
  `quoteArgIfNeededLeavesPlainPathBare` + `quoteArgIfNeededQuotesWhenItHasTo`
  (round-trips through `split`), `flattenNewlinesCollapsesRunsToSingleSpace`
  + `flattenNewlinesLeavesNewlineFreeTextAlone`. 438 pass.

## Shared pty module, live resize, and pty input modes (VT phase 1)

**Done.** First phase of making a non-glyphwire full-screen program more
usable under the B0 dumb pty. `shell/pty.zig` + `shell/keyencode.zig`
moved to `src/pty.zig` + `src/key_encode.zig`, re-exported from
`glyphwire.zig` (`pty` / `key_encode` / `Pty` / `ModeTracker`); the pty
half is Linux-only with an `error.Unsupported` stub elsewhere, matching
`file_watcher.zig`'s degrade-off-Linux shape. The foreground pty loop in
`glyphwire-shell` now:

- forwards `resize` events to the pty as `TIOCSWINSZ`, so a foregrounded
  child gets a live `SIGWINCH` (was wired but never fed events);
- sniffs the child's own output for DEC private modes
  (`glyphwire.ModeTracker`, an `ESC [ ? Ps h/l` scanner whose state
  survives a chunk boundary) and encodes input to match: application
  cursor keys (`?1` → `ESC O x`), bracketed paste (`?2004` → wrap in
  `ESC [ 200~`/`201~`), mouse reporting (`?1000`/`?1002`/`?1003` gate
  button/motion events, `?1006` picks SGR vs. legacy `ESC [ M`);
- polls faster (16ms vs. 120ms) while a mouse mode is on so pointer
  motion isn't a frame behind.

**Wire change:** `report_mouse_move` now also broadcasts a `mouse_move`
notification (`{px, cell}`), but only on a **cell** change — the host
already reports every pixel in-process, and an xterm mouse report is
cell-granular. New `"mouse_move"` subscription (separate from
`"mouse_button"`); `InputListener` gains `pollMouseMoveEvent` /
`waitMouseMoveEvent` with a bounded, backlog-dropping queue.
`Server.reportMouseMove` gained an allocator param.

- **`src/key_encode.zig`**: `toPtyBytes` gained a `CursorKeyMode` param;
  new `encodeMouse(enc, button, action, col, row, mods, buf)` +
  `MouseButton` / `MouseAction` / `MouseEncoding` / `mouseButtonFromName`.
- **`src/pty.zig`**: new `ModeTracker` (pure, platform-independent).
- **Not done (phase 2):** the `core.Layer` screen model — alt-screen
  buffer, DECTCEM, scroll region + SU/SD, IL/DL/ICH/DCH/ECH, DECSC/DECRC
  — and the pty reply path for DSR/DA/DECRQM/OSC queries. Wheel-to-pty is
  also still open (the shell only sees the resolved scrollback offset).
- **Tests:** `shell_tests.zig` +6 (application-cursor keys, `encodeMouse`
  SGR + legacy forms, `ModeTracker` set/reset / multi-param / split
  feeds), `dispatch_tests.zig` +2 (`mouse_move` broadcasts only on a
  cell change, `"mouse_move"` subscription). 446 pass.

## Further out (sequencing noted, not detailed yet)

- **Explicit `write_text` positioning.** `demo/main.zig` and
  `ls/main.zig` both currently work around the missing `row`/`col` params
  by calling `set_property("cursor", ...)` before every write. Decided in
  decisions.md, cheap to add once Phase 1's per-layer params are in
  anyway.
- **Style attributes beyond fg/bg** (bold, italic, underline,
  strikethrough, dim) — needs both a `Style` bitflag field and renderer
  support. The Phase A VT fallback (below) folds SGR bold/dim/inverse
  into the resolved colour at write time, but italic/underline/
  strikethrough are parsed and dropped until this lands.
- **VT100/PTY-capable fallback via libghostty** — investigated in
  `docs/investigations/libghostty-vt-fallback.md`. Two sizes:
  - **Phase A — done** (this branch): `Layer`'s escape *stripper* is now
    an SGR + limited-CSI *interpreter* (`core.SgrPen`, `Layer.execCsi`).
    Colour only — 16/bright/256/truecolor fg+bg, `0`/`1`/`2`/`7` folded
    into the concrete cell colour at write time; `A/B/C/D/G/d/H/f/J/K`
    cursor/erase finals; everything else still recognized-and-discarded.
    No `Style`/wire/renderer change. Hand-rolled, not libghostty (see the
    doc and decisions.md for why).
  - **Phase B splits into tiers** (see the investigation doc §7a):
    - **B0 — dumb PTY passthrough — done** (this branch;
      `src/pty.zig` + `src/key_encode.zig`, `runCommand` rewritten;
      no wire or host change). `runCommand` runs each spawned command on
      a pty (`openpty`/`fork`/`setsid`/`TIOCSCTTY`/`execvp` via libc, an
      exec-status pipe for `error.CommandNotFound`). A reader thread
      mirrors the master to `write_text` (handshake sniff unchanged;
      stdout+stderr merged); the foreground loop encodes `InputListener`
      keys (`keyencode.toPtyBytes`) to the master. Buys unbuffered
      output, working stdin, `isatty` colour/progress, and Ctrl-C as a
      real SIGINT — no new escape-sequence work. Initial `TIOCSWINSZ`
      only; live resize is wired (`Pty.resize`) but not yet fed events.
    - **B1 — pagers / line TUIs** (~+200 LOC in `core.zig`): alternate
      screen, scroll region, insert/delete line, save/restore cursor.
      Makes `less` / `git log` / `man` / `nano` usable.
    - **B2 — full-screen (`vim`/`htop`/`tmux`)**: wants a real VT model —
      `libghostty-vt`'s Terminal C API once tagged (unreleased), or
      vendoring ghostty's Zig `terminal` module.
- **Capability negotiation (`initialize`/`initialized`).** Should land
  before or alongside Phase 3 — decisions.md explicitly calls out image
  formats as something the server *advertises*, which needs the
  handshake to exist.
- **Input events, remaining pieces.** Key and mouse-button events are
  done (`subscribe`, `report_key`/`report_mouse_button` in,
  `key_down`/`key_up`/`mouse_button` out, `get_input_state`, plus
  typematic repeat for arrows — see Current state). `resize` is also
  done: `glyphwire-host`'s window is now `resizable = true`, its
  per-frame `syncWindowSize` reports size changes via
  `Server.reportResize`, the root layer (and every base-size-tracking
  layer) is resized bottom-anchored, and a `resize` notification
  (`{cols, rows}`) is broadcast to `"resize"` subscribers;
  `get_property("size")` and `InputListener.pollResizeEvent`/`size` are
  the read paths. Still open: `mouse_move` as a live push stream (today
  `report_mouse_move` only updates state for `get_input_state`'s cursor
  fields, no broadcast — see `handleReportMouseMove`'s own doc comment),
  `mouse_scroll`, gamepad, IME/text composition (kept separate from raw
  key events, still its own undesigned state machine), and action maps.
- **Command history in `glyphwire-shell`'s prompt.** Up/down arrow
  currently only move `glyphwire-host`'s raw grid cursor (generic
  terminal-style addressing); there's no readline-style "browse previous
  lines" in the shell itself yet. Would need `Prompt` to keep a small
  ring of submitted lines and swap `buffer`/`cursor` to one of them on
  up/down, similar in spirit to how `submitLine` already stashes the
  just-submitted line to scrollback.

## Open questions to settle before writing code

1. Per-connection vs. per-process (`SO_PEERCRED`) layer ownership (Phase 2).
2. ~~Image decoding in the headless core vs. client-supplied dimensions
   plus renderer-only decoding (Phase 3).~~ Resolved: neither — the
   headless core parses just the PNG IHDR chunk instead of decoding, see
   Phase 3 above.
3. Layer z-order / compositing order once a second layer exists (Phase 1).
4. Should `insert_cells`/`delete_cells` ever operate across multiple
   physical rows for a display-wrapped logical line, or stay strictly
   row-scoped (today's shape, and all either message needs while
   `glyphwire-shell`'s prompt lines fit on one row)? Revisit once
   anything needs a line editor for text that actually wraps.
5. `glyphwire-shell`'s ctrl+arrow word-boundary detection
   (`Prompt.wordLeft`/`wordRight`) is whitespace-only right now — a
   deliberate stopgap, same spirit as `Layer.writeText`'s "naive
   codepoint splitting, not real UAX #29 grapheme segmentation" caveat.
   Worth real Unicode word-boundary handling eventually, or is
   whitespace-only fine indefinitely for a line editor that's just
   entering commands?
6. The notification-ordering fix in `Client.deinit()` (see Current state)
   only protects programs built on this Zig `Client` type. decisions.md's
   Discovery & Connection section explicitly doesn't require a client
   library — a hand-rolled client in another language that writes and
   disconnects without an equivalent final round trip could still race
   `glyphwire-shell` the same way. Worth a wire-level answer (an explicit
   `disconnect`/flush acknowledgment?) once a non-Zig client actually
   exists to motivate the shape, or is documenting the convention enough
   for v1?
