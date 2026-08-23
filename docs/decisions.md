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
  `Context.icons` and draws it into exactly one cell (unlike `draw_image`,
  no span — an icon is scoped to a single cell for now).
- **v1 built:** a single flat, global catalog (`Context.registerIcon`/
  `iconHandle`), seeded at `glyphwire-host` startup from
  `core.default_icon_manifest` — 12 colorful 32x32 PNGs from the KDE
  Oxygen icon theme (LGPLv3, see `assets/icons/oxygen/README.txt`),
  covering common categories (folder, file, audio, image, video, archive,
  executable, drive, unknown). Chosen over a flatter/more minimal icon set
  specifically to show off what drawing real multi-tone artwork into a
  cell looks like, not just a monochrome glyph.
- **Not built — still open:** theming (a context-local catalog overriding
  the global one, so swapping a theme changes what a name resolves to
  without any client needing to know or reload anything) and a way to
  query the catalog's contents over the wire (a client currently just has
  to know the names from `default_icon_manifest`).

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
