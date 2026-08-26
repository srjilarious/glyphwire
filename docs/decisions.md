# glyphwire — Design Decisions & Open Items

glyphwire is a 2D-grid terminal replacement. A duplex protocol over a local
socket connects independent sub-programs to a server (the shell/renderer,
built on an existing Zig 2D game engine), replacing VT100/ANSI escape
sequences with structured messages: text with real styling, images, a layer
system with clipping and animated scroll, and input (keyboard, mouse,
gamepad, resize) delivered as either raw events or engine-style mapped
actions. Sub-programs need no client library — any language that can open a
socket and read/write bytes can speak the protocol.

This document is a running log. "Decided" means we're building on it.
"Open" means it's flagged but not settled — don't treat anything there as
final.

## Decided

### Naming
- Project name: **glyphwire**. Checked for prior art before settling (see
  below); explicitly open to renaming later if something better turns up —
  nothing about the design depends on the name.
- Names checked and rejected due to meaningful collision: `trapi` (collides
  with the established bioinformatics "Translator Reasoner API" spec),
  `grapi` (multiple active projects, incl. Kopano/LibreGraph groupware
  APIs), `grui` (an existing graphics-visualization library and a Sencha
  grid-UI product — same-domain collision), `gridwire` (multiple real
  companies), `weavr` (a funded fintech company). `graphwire` was mostly
  clean (one unrelated GraphQL proxy project) and stays a fallback if
  glyphwire needs to change. `tessera` and `palimpsest` were reused a lot
  but in unrelated domains — lower real-world confusion risk than the
  above, kept as backups.

### Discovery & connection
- A glyphwire-aware shell launches child processes and sets a discovery
  environment variable (e.g. `GLYPHWIRE_SOCK=/run/user/.../glyphwire-<id>.sock`)
  before exec'ing them. Env vars inherit automatically down the whole
  process tree, so only the direct launcher needs to set it — no
  repropagation needed for grandchild processes.
- A program checks: is the env var set, and does connecting to that socket
  succeed? If either check fails, it prints its fallback message to stdout
  and degrades (plain output / exit), never partially assuming the grid is
  present.
- Precedent: this mirrors systemd's `NOTIFY_SOCKET` pattern (`sd_notify`) —
  programs speak the wire protocol directly without linking a client
  library, the same way many programs reimplement the few lines
  `sd_notify` needs rather than linking `libsystemd`.
- The grid socket is an out-of-band side channel, not a replacement for
  stdio. Normal stdin/stdout/stderr and pipes (`cmd1 | cmd2`) keep working
  untouched for every program, grid-aware or not.

### Transport & wire format
- Primary transport: a Unix domain socket. An inherited-fd variant (à la
  systemd socket activation / `LISTEN_FDS`) was considered as a
  lower-effort alternative for very simple clients, but isn't required for
  v1.
- Wire format: JSON-RPC 2.0-shaped messages (requests with an `id`,
  responses, and `id`-less notifications), framed like LSP with a
  `Content-Length` header so JSON bodies never need newline-escaping.
- Chosen over Protobuf/Cap'n Proto deliberately: schema/codegen tooling
  reintroduces a "linking-like" burden (every language needs the schema
  file and a working codegen step just to talk to us) and defeats
  hand-debuggability (`nc -U` / `jq` inspection while iterating). Revisit
  only if profiling shows JSON parsing is an actual bottleneck — unlikely
  for this workload.
- Binary payloads (image bytes) are not base64-embedded in JSON. A JSON
  header frame declares `{bytes: N, format: "png", ...}`, then N raw bytes
  follow directly on the socket.

### Protocol shape
- Fully duplex on one connection. Input (key/mouse/gamepad/resize) flows
  server→client as notifications; draw/layer/animation commands flow
  client→server, mostly as notifications. Request/response is reserved for
  calls that need a returned value or handle (`create_layer`, `load_image`,
  `animate`, ...).
- A baseline feature tier (plain cell-grid text + color) is guaranteed by
  protocol version alone, with **zero negotiation required**. A
  baseline-only client (e.g. `ls`) can start writing draw commands
  immediately after `connect()`, without waiting on the server's capability
  response. This is the primary fix for "make simple output-only programs
  feel instant" — see the deferred capability-cache idea below, which
  turned out to be solving a smaller problem than this does.

### Capability negotiation
- LSP-style `initialize` / `initialized` handshake: both sides exchange
  nested capability objects before any feature-gated message is sent.
  Never send a message the peer didn't declare support for.
- Negotiation is asymmetric: the server (engine) mostly *advertises* what
  exists this session (max layers, image formats, easings, color depth);
  the client mostly *subscribes* to what it wants delivered (which input
  event types, raw vs. mapped actions, etc.) — closer to X11's per-client
  event-mask model than to a peer-to-peer exchange.

### Input model
- Two independent, separately-subscribable streams: raw input events
  (key down/up with modifiers + keycodes, mouse, gamepad, resize) and
  mapped action events (via a client-registered action map, mirroring the
  engine's existing action-map system). A client can subscribe to either
  or both.
- Text/IME composition input is kept distinct from raw key events — it's
  its own state machine (CJK input composition in particular), not
  conflated with physical key press/release.
- Subscription is opt-in per event type (X11 event-mask precedent) so a
  client isn't firehosed with events it never asked for.
- Continuous/analog streams (mouse motion, gamepad axes) may be coalesced
  or dropped under backpressure if the client is slow to consume them.
  Discrete state-change events (press/release, layer lifecycle) are never
  dropped.

### Object Model

Everything else — layers, animation, input, text — hangs off a small set
of object types. Worth nailing this down explicitly, since the message
catalog is just operations on these objects, not a separate design
surface.

**Context**
- A Context is the top-level container a connecting program is handed. It
  owns a tree of layers (one of which is its root layer) and has its own
  base width/height in cells, matching the shell window size. A layer
  created without explicit dimensions defaults to the context's base size.
- The server can hold multiple contexts at once; only one is
  visible/rendered at a time. This generalizes the classic terminal
  alt-screen buffer (`smcup`/`rmcup`) from a single alternate buffer to N
  independent, persistent contexts — switching away doesn't destroy a
  context. A shell's prompt and scrollback are still there, untouched,
  when a fullscreen program's context is dismissed and the shell's
  context becomes visible again.
- A connecting program gets a context one of two ways: **inherit**
  (default — a small program just uses its parent's context) or
  **create_context** (explicit request, for something like a fullscreen
  editor that wants its own).
- When the program owning the currently-visible context disconnects, the
  server automatically switches visibility back to the previously-visible
  context — mirrors how alt-screen auto-restores on program exit today,
  generalized to a history instead of a single slot.
- Discovery carries two things, not one: socket path **and** context id,
  as two separate env vars (`GLYPHWIRE_SOCK`, `GLYPHWIRE_CTX`) rather than
  packed into a single string. This lets a program inherit a *specific*
  context explicitly rather than guessing "whatever's currently visible,"
  which matters once multiple contexts can coexist.

**Layer**
- Belongs to a context, positioned in a tree (parent-relative); most
  layers are parented directly to the context's root layer in the common
  case, but the tree/nesting machinery isn't limited to that.
- Sizing reconciles the cell-grid and pixel models like this: a layer's
  authoritative size is its cell dimensions (cols × rows) for v1's
  cell-grid-only tier, and its pixel size is *derived* from that using the
  session's fixed monospace metrics. Position and scroll offset stay
  pixel-precise (as before) for smooth animation, independent of the cell
  grid. If a pixel-precise rich-text tier arrives post-v1, a layer may be
  sized directly in pixels instead — not designed yet.
- `create_layer` returns a server-generated handle, defaulting to the
  context's base width/height when no explicit size is given.
- Storage: a fixed-capacity ring buffer of `height + scrollback_rows`
  physical rows (one contiguous allocation), where the visible viewport
  is always the most recently written `height` rows. Writing past the
  bottom row scrolls — the old top row becomes history (evicting the
  oldest history row once `scrollback_rows` is full) — rather than
  dropping content, the same "live tail" behavior a real terminal has.
- `scrollback_rows` is a per-layer *creation* parameter, not a fixed
  engine default: a terminal-sized root layer might ask for hundreds or
  thousands of rows of history, while a small transient layer (e.g. a
  45×3 popup notification) can reasonably ask for 0. Whatever creates a
  context/layer (the shell, eventually via `create_context`/
  `create_layer`) decides this per layer. Reading scrollback rows back
  isn't exposed over the wire yet — no message needs it yet, since the
  message catalog so far only covers `write_text` and
  `get_property`/`set_property("cursor")`.
- **v1 built:** `create_layer`/`destroy_layer`, every layer parented
  directly to the (single, implicit) context's root layer — deeper
  nesting is designed above but nothing creates or needs a non-root
  parent yet, so `create_layer` takes no `parent`/`context` params.
  `write_text`/`insert_cells`/`delete_cells`/`clear`/`draw_image`/
  `draw_icon`/`draw_box`/`get_cells`/`get_property`/`set_property` all
  take an optional `layer` (root when omitted, per the root-layer-
  implicit convention already established for `row`/`col`).
  `set_property`/`get_property("position")` moves/reads a layer's
  pixel-precise position — `glyphwire-notify` (see notify/main.zig) is
  the first client to use it, sliding a notification layer on/off
  screen a step at a time.
- **Not built — still open:** `create_context`, non-root parenting,
  `size`/`clip`/`scroll`/`visibility` properties.

**Cell**
- As decided under Text & Styling below: a grapheme cluster plus inline
  style (fg/bg truecolor + attribute flags).
- New: a cell's background is either a flat color or a reference to a
  loaded image/icon tile — a tagged union, mutually exclusive, not both at
  once. This is a different kind of indirection than the style-id table
  rejected earlier: an image/icon reference is inherently a resource
  handle (something that had to be loaded/registered first), not a
  hot-path optimization concern, so it doesn't conflict with keeping style
  itself inline.
- New: an optional `metadata_id`, a sibling of `style.bg` rather than part
  of that union — a cell can be tagged regardless of what its background
  is. See the Metadata section below.

**Image**
- A loaded resource (via the binary side-channel framing decided earlier:
  JSON header + raw bytes), referenced by a server-generated handle.
- `draw_image(layer, handle, row, col, row_span, col_span)` places the
  image at its natural pixel size, anchored at the span's top-left cell —
  **no stretching**. If the image is larger than the span's pixel bounds,
  it's clipped; if smaller, only the cells actually covered by image
  pixels are marked as image-backed. Superseded from an earlier "naive
  fit, stretch to fill" decision — stretching reads badly for the actual
  v1 use cases (viewing an image, TUI background art), and isn't worth
  keeping as the default just to avoid clipping. Stretching may return as
  an opt-in mode later; not needed now.
- Per-cell storage stays a resource reference, not a stored sub-image: a
  cell within the span holds `{handle, offset}` (the pixel offset into the
  source image that cell should display), computed from the cell's
  position relative to the draw call's anchor. The host resolves `handle +
  offset` against the actual texture at render time — no per-cell tile is
  ever extracted or cached as its own resource.
- Aspect-ratio-aware placement is the **client's** job, not the server's —
  a client that cares queries the image's natural pixel dimensions
  (`get_image_info`) plus the session's fixed cell pixel metrics, and
  computes an appropriate span itself before calling `draw_image`.
- Noted for later, not designed now: video is expected to reuse this same
  span-based placement model, just with a streaming/updating source
  instead of a static bitmap.

**Icon**
- A named reference to an image, resolved server-side rather than by raw
  handle — `draw_icon(row, col, name)` looks the name up against
  `Context.icons` and draws it anchored at exactly one cell (unlike
  `draw_image`, no span — an icon is scoped to a single anchor cell).
- **Scaled, not clipped by default — deliberately different from
  `draw_image`/`draw_box`.** An icon's default `scale: "fit"` shows the
  *whole* source image, scaled uniformly (never stretched non-uniformly)
  to fit the cell. The reasoning cuts the other way from `draw_image`'s
  clip-not-stretch rule: an icon is a small complete picture meant to
  read correctly regardless of exactly how its native pixel size relates
  to the cell's, where a clip would just as often lop off part of it.
  `draw_image`/`draw_box` keep clipping — those are either arbitrary
  content (clipping is the more honest default) or tiles already built to
  fit the cell exactly.
- **`scale: "natural"` + `h_align`/`v_align` — overflow, deliberately a
  pure rendering effect.** `"natural"` draws the icon at its own pixel
  size instead of shrinking it, which can be bigger than the cell;
  `h_align`/`v_align` (`"start"`/`"center"`/`"end"`, default `"center"`)
  place it within/around the anchor cell, so e.g. `h_align: "end"` grows
  the overflow entirely leftward from a right-flush edge. This is
  deliberately *not* `draw_image`'s span-marking approach: overflow only
  ever touches one cell's data (`Background.icon`, still just
  `{handle, scale, h_align, v_align, max_w, max_h}`, no offset or per-cell
  dimension bookkeeping — same reasoning as the plain-handle days), so
  `get_cells`/clear/scroll on a neighboring cell know nothing about it.
  The host's render pass draws it in a deferred second pass after the
  whole grid so it always paints over whatever a covered neighbor cell
  drew, regardless of row/col order — see `host/main.zig`'s
  `DeferredIcon`. The tradeoff: clearing/redrawing a neighbor cell doesn't
  erase the overflow painted over it; only clearing/moving the icon's own
  anchor cell does. Chosen over claiming covered cells specifically to
  keep `draw_icon` simple — reopening per-cell offset tracking for icons
  was the exact complexity the original plain-handle design avoided.
- **`max_w`/`max_h` cap `"natural"`'s size.** Uniform, aspect-preserved,
  only ever shrinking (never upscaling past native size) — e.g.
  `max_h: 36` on a 32x32 icon is a no-op (already smaller), but on a
  64x64 icon shrinks it to 36x36. Ignored for `"fit"` (its box is always
  exactly the cell, nothing left to cap) and `"stretch"` (always fills
  the cell exactly). Added for `glyphwire-ls`'s per-entry icons
  (`ls/main.zig`'s `writeGrid`): `"fit"` at this project's actual cell
  sizes (glyph advance and line height, rarely square) shrinks a 32x32
  icon down to a handful of pixels, unrecognizable — `"natural"` capped
  to roughly two cell-heights instead reads as an actual picture, with
  the overflow effect (a quarter above the entry's row, half on it, a
  quarter below, via `v_align: "center"`) as a deliberate side effect
  rather than an accident.
- **v1 built:** a single flat, global catalog (`Context.registerIcon`/
  `iconHandle`), seeded at `glyphwire-host` startup from
  `core.default_icon_manifest` — 12 colorful icons from the KDE Oxygen
  icon theme (LGPLv3, see `assets/icons/oxygen/README.txt`), kept at
  Oxygen's native 32x32 (scale-to-fit means there's no need to pre-shrink
  them to any particular cell size). Chosen over a flatter/more minimal
  icon set specifically to show off what drawing real multi-tone artwork
  into a cell looks like, not just a monochrome glyph.
- **Not built — still open:** theming (a context-local catalog overriding
  the global one, so swapping a theme changes what a name resolves to
  without any client needing to know or reload anything) and a way to
  query the catalog's contents over the wire (a client currently just has
  to know the names from `default_icon_manifest`).
- **`foreground: true` composites over the background instead of
  replacing it.** An ordinary `draw_icon` sets `Cell.style.bg`'s `.icon`
  variant — one of `Background`'s mutually exclusive cases, so it
  necessarily replaces whatever background (color/image/icon) was already
  on that cell, the same "overwrite outright" behavior `write_text`
  already has. That's the right default (an icon usually *is* the cell's
  content), but breaks down the moment something else already drew a
  meaningful background there on purpose — e.g. `glyphwire-notify`'s type
  icon over its `"dialog"` panel, where a plain `draw_icon` would punch a
  flat, icon-shaped hole through the gradient instead of sitting on top of
  it. `foreground: true` draws into a new, separate `Cell.fg_icon` field
  instead, left untouched by everything else that writes `style.bg` —
  the host's render pass draws it after that cell's background *and*
  grapheme, so it's always on top, with the same tile-vs-defer split
  `style.bg`'s `.icon` case already uses for `.natural`'s overflow.

**Box**
- `draw_box` shares `Background.icon` with `draw_icon` (each of the 9
  tiles is an `IconBg`, stamped into its cell), not `draw_image`'s
  clip-based `ImageBg` — **superseded from the original clip-based tile
  design.** The bundled tile set was originally 12x12 and clip-based to
  match the cell size at the time; once the host's cell size moved
  (`host/main.zig`'s `cell_w`/`cell_h`), the tiles started clipping
  against the edge rather than filling the cell exactly. Scale-to-fit
  (regenerated at 32x32, same as the icon set) makes the tile set
  independent of whatever cell size a given host happens to run at, the
  same reasoning that already applies to icons.
- **Superseded again: tiles use `scale: "stretch"`, not `"fit"`.**
  `"fit"` (aspect-preserved) only fills whichever axis is the tighter
  constraint; on a non-square cell (this project's actual cells almost
  always are, since a monospace font's glyph advance and line height
  rarely match) it leaves `"center"`-aligned padding on the other axis.
  For a single icon that's a minor cosmetic gap; for a `draw_box` border,
  stacking tiles whose art only fills the vertical-center third (say) of
  each cell breaks a continuous line into dashed segments. `"stretch"`
  fills the cell exactly on both axes (aspect not preserved), so a tile's
  border line always touches every edge of its own cell and the whole
  border reads as one continuous line/box regardless of the cell's aspect
  ratio.
- **Edge-hugging border, not centered.** A box's border lines are drawn
  against the outer boundary of each tile's cell rather than centered
  within it, so a bordered region reads as "a border around this area"
  with the interior cell still usable for content (e.g. text) rather than
  the border eating a visible margin on all sides. This is what makes a
  box usable as a tight background/panel frame, not just a standalone
  decorative box.
- **`BoxMode.stretch`: one image spans a whole run, not one copy per
  cell.** The tiling above (now `BoxMode.tile`, still the default) always
  draws one full copy of a role's tile into each cell it appears in —
  right for a border meant to repeat, wrong for e.g. a gradient fill,
  which just bands (light-dark-light-dark...) instead of blending.
  `"stretch"` keeps the same 9-name resolution but treats each edge/fill
  role's *one* source image as a single logical picture spanning its
  whole run (`t`/`b` horizontally across the interior, `l`/`r` vertically,
  `fill` across both), giving each cell along that run the matching
  fraction of the image (`IconBg.src_l/src_t/src_r/src_b`) stretched to
  fill it — reassembling into one continuous image no matter how many
  cells the box ends up spanning. Corners are excluded (always exactly
  one cell, so never sliced) rather than special-cased away from a
  division that would otherwise be by zero. Motivated by
  `glyphwire-notify`'s `"dialog"` style, a Final-Fantasy-esque gradient
  panel that has to look right at any notification width/height, not just
  the one size a hand-tiled asset happened to be tuned for.

**Metadata**
- Motivating use case: tagging a cell (or a whole run of them, e.g. every
  character of a filename `write_text` wrote) with data a client can act
  on later — a command to run when the cell is "selected" (`cd ...`,
  eventually with a whitelist of commands the host auto-runs vs. pastes
  into the shell for the user to confirm), or file info (path, filetype)
  a context menu (view/edit/copy path/...) could offer. Both are future
  work — this section is only the storage primitive they'd build on:
  tagging a cell, and reading the tag back.
- **Handle-and-table, like images/icons — not embedded per-cell.**
  `create_metadata(json) -> id` stores the blob once; a cell only ever
  holds the id (`Cell.metadata_id: ?MetadataHandle`), so a whole
  `write_text` run (every cell it touches) or several unrelated cells can
  share one without copying it. Same reasoning `ImageBg`/`IconBg` already
  use for images/icons.
- **Opaque JSON, not fixed server-known fields.** The server stores
  `json` verbatim and never parses it — same treatment `ImageEntry.bytes`
  gets for PNG bytes. The two motivating use cases above want different
  shapes (a command string vs. path/filetype/...), and more are expected
  later (a hover tooltip, other context-menu entries) — a fixed field set
  would mean growing the server's own schema every time a client invents
  a new kind of tag. Client-defined JSON means the server's job stays
  "store an opaque blob," identical in spirit to how it already doesn't
  interpret `write_text`'s content either. The convention (not enforced
  by the server) is a JSON object so multiple command-line tools and a
  future TUI can each embed whatever fields they care about, e.g.
  `{"kind":"file","path":"/home/x/afile.txt","command":null}` or
  `{"kind":"dir","path":"/home/x/bdir","command":"cd /home/x/bdir"}`.
- **`destroy_metadata` exists now; garbage collection doesn't yet.** A
  metadata-heavy client (e.g. `glyphwire-ls`, tagging every entry of
  every listing) will create ids far more often than `load_image` ever
  loads images, so unlike images (which have no delete path at all),
  explicit cleanup matters from the start. But there's no reference
  counting — destroying an id a cell still points at just leaves that
  cell dangling (see below) — full garbage collection (freeing ids no
  cell references any more, including on scrollback eviction and possibly
  other scenarios) is deliberately deferred: it needs the GC to actually
  exist first, and until then a client that destroys thoughtfully is
  enough to keep this useful.
- **A dangling id is a normal read result, not an error.** `get_metadata`
  reports `{id, json: null}` rather than erroring when `id` is set on a
  cell but has since been destroyed — expected, not exceptional, given
  destruction is explicit and cell-level reference tracking doesn't
  exist. This lets a caller (e.g. a future hover handler) tell "nothing
  tagged here" (`id: null`) apart from "tagged, but the data's gone"
  (`id` set, `json: null`).
- **Validated at write time, though.** `write_text`/`draw_icon`'s
  `metadata_id` param errors `UnknownMetadata` immediately if the id
  doesn't exist (typo, or already destroyed) — same "fail loud on a bad
  handle at the point of use" treatment `UnknownImage`/`UnknownIcon`/
  `UnknownLayer` already get. This is a different moment than the
  dangling-read case above: catching a bad id when a client is *about to
  reference it* is a cheap, immediate sanity check; a cell that was
  validly tagged and only became dangling *afterward* (because something
  else destroyed that id later) is the expected steady-state the read
  path has to handle gracefully regardless.
- **`get_cells` reports `metadata_id` per cell; `get_metadata(layer?, row,
  col)` resolves one to its content.** Same split `bg_image`/`bg_icon`
  already have: a full-grid snapshot is cheap to extend with just the id
  (a client doing a bulk render can tell which cells are tagged without
  probing each one), while resolving the actual JSON is a separate,
  targeted request — the pair a future mouse-click handler needs
  (`get_metadata` to resolve whatever cell the click landed on, reporting
  both the id and its content in one round trip). `row`/`col` are
  required there, not cursor-defaulted like `draw_icon`/`draw_image`'s
  `row?`/`col?` — a lookup always has a definite target (the clicked
  cell), unlike a draw that can reasonably mean "wherever the cursor is".
- **`tag_metadata(layer?, row, col, metadata_id)` — a tag with no draw.**
  `write_text`/`draw_icon`'s `metadata_id` param only ever tags as a side
  effect of drawing something; there was no way to tag a cell without
  also changing its background/grapheme. Needed once `glyphwire-ls`
  started drawing `.natural`-scaled icons that overflow past their anchor
  cell (see the Icon section's `max_w`/`max_h`): the overflow is
  deliberately a pure rendering effect with no automatic data-model
  footprint on the cells it visually spills into (draw_icon still only
  ever tags its one anchor cell), so a client that wants those cells
  tagged too — so browsing/hovering resolves correctly anywhere the icon
  actually renders, not just its leftmost column — has to say so
  explicitly, cell by cell. `tag_metadata` is that explicit opt-in: it
  touches only `Cell.metadata_id`, nothing else, and takes a required (not
  optional) `metadata_id` — there'd be no point calling it to tag with
  nothing.

### Events
- No separate wire-level "event" mechanism — events are just notifications
  (method name + payload), same as everything else. The actual design work
  is subscription/routing semantics (does an event bubble up the layer
  tree, per-layer vs. global subscription), which is an engine/API
  decision, not a protocol-framing one.

### Animation
- Server-driven tweens, not client-pushed per-frame updates: the client
  sends an `animate` request targeting a generic `{node, property}`
  descriptor, gets back a handle, and the **server** advances it every
  engine tick, emitting an `animation_complete` notification when done.
  This avoids every client needing its own 60Hz update loop over IPC.
- `property` targets a small set of generic lerp-able types (float, vec2,
  color) rather than being special-cased per named property, so future
  animatable properties ride for free.
- v1 scope: linear easing only, `once`/`loop` playback modes, targets
  include scroll offset and color.

### Action maps
- A client can register a named action map (action name → physical input
  bindings), mirroring the engine's existing action-map system. The server
  emits mapped `action` events *alongside*, not instead of, raw input
  events — a client picks which stream(s) it wants via subscription.

### Shell
- glyphwire needs its own shell to launch child processes, since it's the
  natural place to set the discovery env var before exec. No further
  mechanism needed beyond that — see Discovery & Connection above.

### Server architecture
- **Headless-first.** Core state — the layer tree, positions, clip rects,
  scroll offsets, cell contents, animation state — is a pure, inspectable
  state machine with no dependency on rendering or windowing, so it can run
  without a display and be covered by a real unit test suite. Rendering
  (via the Zig 2D engine) and socket I/O are layers on top of that headless
  core, not entangled with it. This shapes the Text & Styling data-model
  choices below, which favor directly-assertable structures over anything
  requiring resolution/indirection to inspect.

### Deferred: capability caching
- Considered: a server-side cache (never client-side — the client must
  stay unaware caching exists at all) keyed by the connecting binary's
  path + mtime (+ size), populated via `SO_PEERCRED` + `/proc/<pid>/exe`
  on Linux so it needs zero protocol cooperation from the client. Must be
  fail-open: any mismatch or staleness just triggers a normal full
  handshake, never a wrong answer.
- Explicitly **not v1**, and possibly not needed at all — a local Unix
  socket round trip is likely sub-millisecond, dwarfed by several
  milliseconds of fork/exec + dynamic-linker cost, so the baseline
  no-negotiation tier (above) may already solve the actual "make `ls` feel
  instant" problem. Measure before building this.

## Open Items

- **Message catalog.** Now enumerated in `docs/api.md`, but most of it is
  still 🔶 planned/⬜ open rather than built — `subscribe` and
  `bind_actions` in particular don't have a decided request-vs-notification
  shape yet.
- **Multi-process layer ownership.** Single foreground owner per grid
  (classic shell model) vs. multiple concurrent processes owning separate
  regions (tmux-pane-like, negotiated over the protocol) — explicitly
  scoped out of v1, needs confirming it stays deferred rather than
  creeping in.
- **Resource/handle ID scheme.** Server-generated vs. client-supplied IDs
  for layers, animations, images — leaning server-generated, not final.
- **Color interpolation space for animation.** Leaning toward a perceptual
  space (e.g. Oklab) over raw sRGB for better-looking color tweens — cheap
  to decide now, costly to change later once programs are visually tuned
  around it. Not finalized.
- **Whether the capability cache gets built at all**, pending real
  measurements of baseline handshake latency vs. fork/exec cost.
- **Non-Linux portability** of the `SO_PEERCRED` trick (BSD/macOS have
  `LOCAL_PEERCRED`; not yet researched in depth) — only matters if the
  cache above ends up justified.
- **Image protocol specifics** — formats supported, chunking/streaming for
  large images, placement semantics. Only the binary side-channel framing
  is decided; the rest isn't fleshed out.
- **Layer content as its own axis, separate from geometry** — today a
  layer's content is implicitly "a cell grid"; nothing forces that. Worth
  keeping layer geometry (position/size/clip/scroll, already generic via
  `get_property`/`set_property`) conceptually separate from what fills the
  layer, so a future "external surface" content kind (a client-shared
  buffer for something like a full-screen animated GL layer) doesn't need
  a breaking change to Layer itself — only cell-grid content is built now.
  Not designed, just flagged so the fork stays cheap later.
- **Client-shared buffers for surface-backed layers** — a full-screen
  animated GL layer or similar would need the client's pixel content
  composited without going through per-frame JSON+binary IPC. Unix domain
  sockets support fd-passing (`SCM_RIGHTS`), which is how Wayland
  compositors do zero-copy client→compositor buffer sharing (DMA-BUF)
  instead of copying pixels through the socket — noted as an option this
  transport already leaves open, not something to build or design now.
- **Session/socket lifecycle** — multiple concurrent servers, reconnection
  behavior after a server crash or restart, persisted vs. ephemeral socket
  paths. Not discussed yet.
- **Context creation/activation policy** — `create_context` and
  auto-restore-on-disconnect are decided (see Object Model), but who's
  allowed to create or activate a context, and what happens if a
  background context's owner tries to act on a context that isn't
  currently visible, isn't worked out yet.

## In Progress: Text Writing & Styling

See reasoning and tentative decisions below — captured here as the
starting point for implementation, not yet battle-tested against a real
port of an existing program.

### Two tiers, v1 covers only the first

Real terminal content overwhelmingly thinks in a fixed-width character
grid, and porting existing tools (`ls`, shells, line-oriented output) is
far easier if glyphwire offers that as a first-class, easy-to-target API.
But layers are pixel-addressable render targets (see Layers, above), so
there's no architectural reason text has to be grid-locked — a richer
"styled text run positioned in pixels, arbitrary font/size" tier is
worth reserving room for later (real prose rendering, GUI-like widgets).

**Decision: v1 implements only the cell-grid tier.** The pixel-precise
rich-text tier is explicitly deferred, not designed against yet.

### Cell content: grapheme clusters, not codepoints

A cell can't just hold one Unicode codepoint — combining marks (`e` +
combining acute), multi-codepoint emoji (ZWJ sequences), and Korean
syllable blocks all need to render as one visual unit per cell. Storing a
single codepoint per cell would need a hacky side table for anything
beyond that.

**Decision:** each cell holds an extended grapheme cluster, using a
small-string-optimized representation — inline bytes for the common case
(usually 1–4 UTF-8 bytes), overflowing to a side table only for rare, long
clusters. This is the same strategy modern terminal emulators (Alacritty,
Kitty) already use for "extended" cell content — worth reusing their
approach rather than inventing one.

**Decision:** wide characters (CJK, many emoji) follow the existing
Unicode East Asian Width convention: the glyph occupies the "primary"
cell, and the cell to its right is marked as a continuation that isn't
rendered directly. No need to invent a different convention here.

**Open:** grapheme cluster segmentation needs an implementation of Unicode
text segmentation (UAX #29), and wide-character width needs East Asian
Width + emoji-width tables. Both should be sourced from an existing
library/dataset rather than hand-rolled if a usable Zig option exists —
needs research, not yet chosen.

### Style: inline per cell, not an indirection table

Real terminals typically store full style (fg, bg, attributes) inline per
cell — simple, but heavier on memory and makes bulk restyling relatively
expensive. A style-id indirection (cells store a small int, a side table
maps id → full style, like a palette) is more memory-efficient for large
uniformly-styled regions and makes bulk restyle cheap, but adds a
resolution step everywhere the state is read — including in tests.

**Decision, tentative:** inline-per-cell style for v1 (fg RGBA, bg RGBA,
an attribute bitflag byte or two — roughly 10–12 bytes/cell), prioritizing
the headless-first requirement: a flat array of plain structs is something
a unit test can snapshot and assert against directly (`cell(3,5).fg ==
red`), with no indirection to resolve. Style interning is left as a later
optimization, only worth it if memory profiling on large grids actually
justifies it.

**Decision:** colors are truecolor RGB(A), not a 16/256-color palette —
the palette model was itself a VT100-era limitation being escaped. An
optional "use theme default" sentinel per color channel is kept so a
client can say "default foreground" and let the server's active theme
resolve it, rather than every client hardcoding RGB and losing
theme-ability (mirrors ANSI's default-color reset, minus the palette
limitation).

**Open:** exact `Style` struct layout (RGBA8 vs. RGB + separate alpha
byte, the attribute bitflag list). Attributes discussed so far: bold,
italic, underline, strikethrough, dim/faint. Underline *style* and
*color* (curly underline for spellcheck-style markers, colored underline
for diagnostics) noted as a nice modern-terminal feature but a stretch
goal, not v1. Blink intentionally excluded unless a specific need shows
up.

### Wire operation: styled text runs, not per-cell messages or inline markup

A message per cell would be far too chatty for something like `ls`
printing hundreds of filenames. The natural unit is a **run**: a UTF-8
string plus one style, applied starting at a position.

**Decision:** `write_text(layer, row, col, text, style)` — `text` is a
plain UTF-8 string (the server segments it into grapheme clusters and
places them starting at `row, col`); `style` applies uniformly across the
whole run. For output that mixes styles mid-line (e.g. syntax
highlighting), the client sends multiple `write_text` calls, one per run —
deliberately **not** an inline style-markup syntax embedded in the text
argument, since that would just reinvent ANSI escape codes inside the new
protocol.

**Decision:** support both explicit and implicit positioning. Every
`write_text` can specify `row, col` directly (needed for TUI-style
programs redrawing specific regions), and the server also tracks a
per-layer "cursor" that advances after a write and wraps at the layer
edge — a convenience so simple sequential-print programs (most of what's
being ported first) don't need to track their own position, matching how
real terminals behave today.

**Decision:** cell-grid operations are always addressed in `row, col`,
never pixels. The server picks one monospace font + size per
grid/session (configurable), fixing a cell's pixel size, and translates
row/col to pixel position internally. Pixel addressing stays exclusive to
the layer-transform tier (position, scroll, animation) established
earlier — clients never need to think in pixels just to write text. This
keeps the two tiers cleanly separated.

**Confirmed:** when `row` and `col` are both omitted from `write_text`, it
always appends at the layer's cursor and advances it — the same behavior
a plain stdout-writing program already expects, so porting a
straightforward `print`-style tool needs no positioning logic at all.

**Extended to `draw_image`/`draw_icon`/`draw_box`:** the same
omit-means-cursor convention now applies to every absolute-position draw
call, not just `write_text` — `row`/`col` default to the layer's current
cursor when left out. Unlike `write_text`, none of the three *advance*
the cursor afterward (a drawn image/icon/box isn't "text that was just
typed," so there's no obvious single cursor position to land on
afterward the way there is after writing N characters) — a caller
chaining a draw with more content on the same row still positions
explicitly for what comes next.

**Decision:** `write_text` always replaces a cell's whole style outright
(fg *and* bg together, per-cell — same "overwrite outright" behavior
`draw_icon` used to have before `foreground: true`, see the Icon section)
— matching how a real terminal's plain `print` resets a cell's background
rather than layering text onto whatever was drawn there before, and
simpler than merging styles cell by cell. Omitting `bg` means "reset to
`core.default_style.bg`," not "leave it alone." **`transparent_bg: true`
is the explicit opt-out**, added once `glyphwire-notify`'s message needed
to sit on top of its `"dialog"` panel's gradient (`draw_box`'s
`BoxMode.stretch`): it leaves each touched cell's existing background
untouched instead, so text can be written over a background drawn some
other way without erasing it — deliberately a new, additive flag rather
than redefining what an omitted `bg` means, since the reset-on-omit
behavior is relied on elsewhere (e.g. `glyphwire-shell`'s prompt,
`glyphwire-ls`'s columns) and shouldn't silently change underneath them.
`Layer.writeText`/`writeTextTagged` reflect this at the `core` level too:
`bg` is `?Background`, split out from `fg: Color` rather than bundled
into one `Style` value, precisely so `null` can mean "don't touch it" —
`Cell.style` itself still always holds a concrete, resolved `Style`; only
the *write* can decline to touch its `bg` half.

**Decision:** cursor position, layer position, clip rect, size, and
scroll offset are all exposed through one generic mechanism —
`get_property(layer, name)` / `set_property(layer, name, value)` — rather
than a bespoke get/set pair per property (`get_cursor`/`set_cursor`,
etc.). This reuses the same `{node, property}` descriptor `animate`
already targets, so nothing new has to be invented to make a property
animatable versus just settable, and the message catalog doesn't grow one
message pair per property.

### Open items from this section

- Grapheme segmentation (UAX #29) and East Asian Width / emoji-width
  table sourcing — needs a concrete library/data choice.
- Final `Style` struct layout and full attribute bitflag list, now
  including the cell background tagged union (color vs. image/icon
  reference — see Object Model above).
- Full property name list/enum for `get_property`/`set_property`
  (`cursor`, `position`, `size`, `clip`, `scroll`, `visibility`, ...) —
  not finalized.
- Underline style/color — confirm as post-v1.
- Style interning — confirmed deferred, revisit only if memory profiling
  on real large-grid usage justifies it.
