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

## Phase 3: Images (`load_image`, `get_image_info`, `draw_image`)

**Goal:** the `Cell.style.bg = .image` arm — already modeled in
`core.zig` since Milestone 1 — becomes reachable.

- Wire framing extension: `wire.zig` only does JSON-body
  `Content-Length` framing today. The binary side-channel (JSON header
  `{bytes: N, format: "png", ...}` immediately followed by `N` raw
  bytes, decided in decisions.md) is new wire-level work — `FrameDecoder`
  needs a mode where it consumes a declared byte count directly instead
  of looking for the next `Content-Length` header.
- **Open question — where does decoding happen?** decisions.md says
  `get_image_info` returns "natural pixel dimensions," implying the
  server decodes the image to know that. But decisions.md's
  headless-first principle says core state shouldn't depend on
  rendering, and `glyphwire`'s core module has no image-decode
  dependency today (only `glyphwire-host` links pixzig, which pulls in
  zstbi — `glyphwire-shell` deliberately doesn't, see Current state).
  Two shapes:
  - Headless core decodes just enough to answer `get_image_info` (needs
    zstbi or similar as a core dependency, a real headless-first
    compromise).
  - Client supplies `width`/`height` on `load_image` instead of the
    server deriving them; the core stores raw bytes + a handle and never
    decodes anything; only the renderer (which already has zstbi)
    decodes when it first encounters a `.image` background it hasn't
    uploaded yet.
  - Leaning toward the second — it keeps decisions.md's headless-first
    line intact and matches how `glyphwire-host`'s render loop already
    has a natural "first time I see this handle, load it" hook.
- `draw_image(layer, handle, row, col, row_span, col_span)` just sets
  `Cell.style.bg = .{ .image = handle }` on the target span — no new
  core mechanics needed beyond what Phase 1's per-layer `write_text`
  already requires.
- Renderer-side work (`host/main.zig`): resolve `.image` handles to an
  actual texture instead of today's "fall back to plain black."
- **Out of scope:** icon-by-name (post-v1 per decisions.md), video,
  aspect-ratio-aware placement (decisions.md already puts that on the
  client, not the server).

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
2. Image decoding in the headless core vs. client-supplied dimensions
   plus renderer-only decoding (Phase 3).
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
