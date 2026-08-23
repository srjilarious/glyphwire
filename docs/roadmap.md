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
  touching the down-set, so it doesn't get deduped away). `mouse_move`
  streaming, `mouse_scroll`, gamepad, resize, and IME are all still open
  — see Further out.
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
  falling back to `$PATH`. The child is assumed glyphwire-compatible — it
  inherits `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX` and draws to the grid itself
  over its own connection — the shell just spawns it, waits, and resyncs
  its own cursor from `get_property(cursor)` before drawing the next
  prompt rather than assuming a fixed row offset. Capturing stdout/stderr
  from a plain, non-glyphwire-aware program is still open — see Further
  out.
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
- 34 tests green as of this writing (one long-standing flaky mouse-button
  race in `inputListenerReceivesReportedInputTest`, unrelated to any of
  the above, not yet fixed).

## A latent robustness gap, partially closed

`Dispatcher.handle`'s errors (unknown method, unknown property, bad
JSON) still propagate as plain Zig errors, not JSON-RPC error
*responses* — there's no `{"error": {"code", "message"}}` wire shape
yet, for `get_property` today or anything else. Notifications with no
`id` still have nowhere to report an error anyway — per JSON-RPC, that
stays a server-side log line, not a wire message.

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
- **`glyphwire-view` looked broken because the whole host window closed
  the instant it finished drawing.** Launched as `glyphwire-host
  glyphwire-view <path>`, this process *is* what `glyphwire-shell` execs
  into — `glyphwire-host`'s `reapChild`/`shell_exited` treats any exec'd
  child's exit as "done" and closes the window. `glyphwire-view` used to
  draw and return immediately; now it subscribes to `key` and blocks
  until any keypress before exiting, like a real image viewer.

## Phase 3.7: `clear`

**Goal:** a way to reset cells back to blank without a client redrawing
over everything with spaces — needed once `draw_image`/`draw_icon`/
`draw_box` mean a region can have *content* (not just stale text) left
over from a previous draw.

- `clear(row?, col?, rows?, cols?)` (`Layer.clear`) resets a region to
  the same zero-value blank cell `Layer.init` starts with — empty
  grapheme, default style, no image background. `rows`/`cols` default to
  "the rest of the layer from `row`/`col`" (themselves defaulting to 0),
  so a bare `clear()` wipes everything — one call covers both "clear this
  one region before redrawing it" (see `demo/main.zig`, before its
  box/icon panel) and "clear the whole screen" (ctrl+l).
- `glyphwire-shell`'s prompt now binds ctrl+l to clear the screen and
  redraw the current line (prefix + whatever's already typed) at the top,
  same as a real shell — `Prompt.clearScreen`, sharing a
  `writePromptPrefix` helper with `showPrompt` rather than duplicating
  the cwd-prefix logic.

## Further out (sequencing noted, not detailed yet)

- **Explicit `write_text` positioning.** `demo/main.zig` and
  `ls/main.zig` both currently work around the missing `row`/`col` params
  by calling `set_property("cursor", ...)` before every write. Decided in
  decisions.md, cheap to add once Phase 1's per-layer params are in
  anyway.
- **Style attributes beyond fg/bg** (bold, italic, underline,
  strikethrough, dim) — needs both a `Style` bitflag field and renderer
  support.
- **Capability negotiation (`initialize`/`initialized`).** Should land
  before or alongside Phase 3 — decisions.md explicitly calls out image
  formats as something the server *advertises*, which needs the
  handshake to exist.
- **Input events, remaining pieces.** Key and mouse-button events are
  done (`subscribe`, `report_key`/`report_mouse_button` in,
  `key_down`/`key_up`/`mouse_button` out, `get_input_state`, plus
  typematic repeat for arrows — see Current state). Still open:
  `mouse_move` as a live push stream (today `report_mouse_move` only
  updates state for `get_input_state`'s cursor fields, no broadcast —
  see `handleReportMouseMove`'s own doc comment), `mouse_scroll`,
  gamepad, `resize` (moot right now since `glyphwire-host`'s window is
  `resizable = false`, but the message should still exist for whenever
  that changes), IME/text composition (kept separate from raw key
  events, still its own undesigned state machine), and action maps.
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
