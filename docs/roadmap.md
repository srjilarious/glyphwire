# Roadmap: Next Steps

`docs/slice_plan.md` is done and removed — all 7 of its milestones landed
(headless core through the automated end-to-end proof), plus Milestone 8
(a real pixzig-windowed renderer, `shell/main.zig`) has since landed too.
This doc picks up from there: the next slices of
protocol/core work, in rough dependency order. `docs/api.md` has the full
aspirational message catalog with status markers; this doc is about
*sequencing* the still-🔶/⬜ parts of it. `docs/decisions.md` stays the
place for *why*.

## Current state

- One `Context`, one root `Layer`, ring-buffer scrollback
  (`scrollback_rows` a creation parameter).
- `write_text` (implicit cursor + fg/bg color only), `get_property` /
  `set_property` (`cursor` only) — all implicitly targeting the root
  layer, since there's no other layer to address yet.
- Real Unix socket server (`src/server.zig`), one connection served to
  completion at a time.
- `glyphwire-shell`: a pixzig-windowed renderer that owns the `Context`
  and `Server` directly, renders the grid every frame, and spawns a
  child program with `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX` set. Landed as
  Milestone 8 (commit `16a0a6c`); all 17 tests green as of this writing —
  an earlier draft of this doc caught `demoClientWritesStyledTextOverRealSocketTest`
  red mid-edit, since resolved.

## A latent robustness gap worth fixing before building more on top of it

`Dispatcher.handle`'s errors (unknown method, unknown property, bad
JSON) currently propagate all the way up through `Server.serveConnection`
→ `acceptOne` → `serveForever`. In the standalone `glyphwire-server`
binary and in `glyphwire-shell`'s background-thread server loop alike,
one malformed message from *any* client currently takes down the whole
server for every connection and context — `serveForever`'s `while (true)
try self.acceptOne(alloc);` doesn't isolate a bad connection from the
rest. This was fine for the slice (one trusted test client), but every
phase below adds more request types a client can get wrong.

**Milestone 0.** Give `serveConnection` its own error boundary (a bad
frame or dispatch error closes *that* connection, logs, and lets
`serveForever` keep accepting) and add real JSON-RPC error *responses*
(`{"error": {"code", "message"}}`) for request methods (`get_property`
today; `delete_layer` below needs one for permission-denied). Notifications
with no `id` still have nowhere to report an error — per JSON-RPC, that
stays a server-side log line, not a wire message.

## Phase 1: Multiple layers (`create_layer`)

**Goal:** a context can hold more than the root layer, addressed by
handle — the concrete thing that unblocks the "45×3 popup in the top
corner" case.

- `Context` gains a layer registry (handle → `Layer`) instead of a bare
  `root: Layer` field. The root layer keeps a fixed, well-known handle
  (mirroring how `default_context_id` already stands in for the missing
  `create_context`) and doubles as the context's **default layer**.
- **Not a breaking change:** `write_text`, `get_property`, and
  `set_property` gain an *optional* `layer` handle parameter — omitting
  it targets the context's default layer, exactly today's behavior.
  This is the same "baseline tier needs no negotiation" instinct
  decisions.md already applies elsewhere: a simple program that only
  ever wants root doesn't need to learn layers exist. `demo/main.zig`
  and everything else already sending these messages keeps working
  unchanged; only code that wants a second layer passes `layer`
  explicitly.
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
- **Coordination point:** the render loop in `shell/main.zig` currently
  iterates `ctx.root` directly; it needs to iterate the layer registry
  once this lands. Sequence this with whoever's driving that file.

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
  dependency today (only `glyphwire-shell` links pixzig, which pulls in
  zstbi). Two shapes:
  - Headless core decodes just enough to answer `get_image_info` (needs
    zstbi or similar as a core dependency, a real headless-first
    compromise).
  - Client supplies `width`/`height` on `load_image` instead of the
    server deriving them; the core stores raw bytes + a handle and never
    decodes anything; only the renderer (which already has zstbi)
    decodes when it first encounters a `.image` background it hasn't
    uploaded yet.
  - Leaning toward the second — it keeps decisions.md's headless-first
    line intact and matches how `glyphwire-shell`'s render loop already
    has a natural "first time I see this handle, load it" hook.
- `draw_image(layer, handle, row, col, row_span, col_span)` just sets
  `Cell.style.bg = .{ .image = handle }` on the target span — no new
  core mechanics needed beyond what Phase 1's per-layer `write_text`
  already requires.
- Renderer-side work (`shell/main.zig`): resolve `.image` handles to an
  actual texture instead of today's "fall back to plain black."
- **Out of scope:** icon-by-name (post-v1 per decisions.md), video,
  aspect-ratio-aware placement (decisions.md already puts that on the
  client, not the server).

## Further out (sequencing noted, not detailed yet)

- **Explicit `write_text` positioning.** `demo/main.zig` currently
  works around the missing `row`/`col` params by calling
  `set_property("cursor", ...)` before every write. Decided in
  decisions.md, cheap to add once Phase 1's per-layer params are in
  anyway.
- **Style attributes beyond fg/bg** (bold, italic, underline,
  strikethrough, dim) — needs both a `Style` bitflag field and renderer
  support.
- **Capability negotiation (`initialize`/`initialized`).** Should land
  before or alongside Phase 3 — decisions.md explicitly calls out image
  formats as something the server *advertises*, which needs the
  handshake to exist.
- **Input events** (key/mouse/gamepad/resize, `subscribe`, action maps).
  The renderer already owns `eng.inputs`; nothing forwards it over the
  wire yet. Biggest remaining chunk — two independent subscribable
  streams, backpressure/coalescing for continuous events, IME kept
  separate from raw key events.

## Open questions to settle before writing code

1. Per-connection vs. per-process (`SO_PEERCRED`) layer ownership (Phase 2).
2. Image decoding in the headless core vs. client-supplied dimensions
   plus renderer-only decoding (Phase 3).
3. Layer z-order / compositing order once a second layer exists (Phase 1).
