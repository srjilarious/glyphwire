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
- **Stdout/stderr handshake for launcher-spawned commands.** A launcher
  that spawns arbitrary commands (`glyphwire-shell`'s `Prompt.runCommand`)
  can't know in advance whether a given command is glyphwire-aware, so it
  defaults to "plain program writing to a terminal": it pipes the child's
  stdout/stderr and forwards each chunk onto the grid via a single
  `write_text` (`Prompt.pumpChildOutput`/`flushCapturedStream`), letting
  `Layer.writeText`'s own C0 handling (see the styled-text section) take
  care of `\n`/`\r`/`\t` and stray escape sequences.
  A glyphwire-aware child opts out automatically: `Client.connect` writes
  `glyphwire.handshake_marker` (a leading-NUL-byte sentinel, vanishingly
  unlikely to collide with a plain program's real output) to the child's
  own stdout as part of connecting, not a separate call a caller has to
  remember — only a glyphwire-aware program ever calls `connect` in the
  first place, so the handshake is entirely an implementation detail of
  what connecting means, invisible from the call site. The launcher
  checks for the marker before mirroring anything. Once resolved, whichever
  answer applies sticks for the rest of that command's run — the
  launcher never re-checks mid-stream. The check also runs once more
  after the child's stdout hits EOF, before the final flush: an aware
  child that writes *only* the marker and then draws entirely over its
  own wire connection (`glyphwire-ls`) produces no further stdout for the
  read loop to wake on, so the marker would otherwise still be sitting
  unresolved in the buffer and get mirrored onto the grid as the literal
  text `glyphwire-handshake-v1`. This is deliberately a side
  channel on the child's own stdout, not a wire-protocol message: the
  launcher would otherwise need to correlate a spawned PID with a
  possibly-unrelated later socket connection (the `SO_PEERCRED`-based
  capability cache below was considered and deferred for the same
  reason), and the discovery env vars already establish that *this*
  specific child is the one whose stdio the launcher is holding a pipe
  to. Stdio itself is never swallowed either way, matching the "side
  channel, not a replacement for stdio" principle above: a handshaken
  child's remaining stdout/stderr are passed straight through to the
  launcher's own real stdio rather than dropped, so its own diagnostics
  (`std.log.err` and similar) still land somewhere. A known limitation:
  since the launcher must pick the piped-vs-inherited spawn behavior
  before it knows the answer, this only covers commands that don't need
  real interactive stdin (piped as `.ignore`) — not yet a problem, since
  no glyphwire-aware program reads stdin today, but worth revisiting if
  one ever does.

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
  `create_layer`) decides this per layer. Scrollback rows *are* now
  readable over the wire — `get_cells`/`get_metadata` take a `view_offset`
  (rows above the live viewport, via `Layer.viewRow`) so a client can
  inspect exactly what's on screen while the host is scrolled back (the
  path a mouse click in scrollback takes to resolve to the right cell).
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
- **v1 built — resize:** `glyphwire-host`'s window is now user-resizable
  (`resizable = true`), and its per-frame `syncWindowSize` converts the
  framebuffer size to a whole-cell grid and, on a change, calls
  `Server.reportResize` (same in-process path as `reportKey`). That
  resizes the root layer plus every `create_layer` layer flagged
  `tracks_context_size` (set true only when *both* dimensions were
  omitted at creation, so it had been mirroring the root's size — an
  explicitly-sized popup keeps its size), then broadcasts a `resize`
  notification to `"resize"` subscribers. `get_property("size")` returns
  `{cols, rows}` (get-only — the host owns the window size).
  `Layer.resize` rebuilds the ring buffer **bottom-anchored**: the
  newest row stays put; growing the height pulls scrolled-off rows back
  down out of history (blank filler at the top only once history is
  exhausted), shrinking pushes the top rows up into history rather than
  discarding them (so a later grow restores them), evicting only what
  overflows the new `height + scrollback_rows` capacity — oldest first,
  same rule `scrollOne` already uses. Width changes clip/blank-pad each
  row on the right, no reflow (matching `insert_cells`/`delete_cells`'s
  row-scoped model). Chosen over the request's literal "discard on
  shrink" because the ring buffer already models exactly this
  non-destructive live-tail behavior — a shrink is just the viewport
  window narrowing over content that's still there.
- **v1 built — scrollback view + scrollbar:** the root layer carries a
  display-only `view_scroll` (rows scrolled back into the cell-grid
  history; `viewRow` applies it at read time, writes are unaffected).
  One piece of state, three drivers: `glyphwire-host`'s mouse wheel and
  its always-on right-edge scrollbar (`Server.reportScroll`, in-process),
  and any client via the `scroll_view` request — `glyphwire-shell`'s
  browse cursor calls it when Up walks past the top of the window, so a
  listing longer than the window scrolls into view ("scroll the window
  along"). `get_property("scroll")` reads `{offset, max}`; a `scroll`
  notification (subscribe `"scroll"`) fires on every move so other
  clients stay in sync (glyphwire-shell snaps back to the live tail when
  the user starts typing). `scrollOne` bumps `view_scroll` in step with
  incoming output so the rows being read stay put until history eviction
  forces a drift. The scrollbar was chosen always-visible (a persistent
  position indicator) with track-clicks paging one screenful.
- **Not built — still open:** `create_context`, non-root parenting,
  `clip`/`visibility` properties, a raw wheel-delta `mouse_scroll` event
  stream (distinct from `scroll`, which reports the resolved offset).

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
- **A `row_span` reaching past the layer's bottom scrolls to make room,
  one row at a time, instead of clipping.** `Layer.drawImage` used to
  resolve only its anchor row against `Layer.resolveRow` and then clamp
  `row_end` to `self.height`, so an image anchored close enough to the
  bottom that its full `row_span` didn't fit just lost its lower rows
  silently — it read as the image clipping to whatever viewport happened
  to be current, rather than interleaving into the flow the way `row_span`
  lines of text would (each wrapping/scrolling as it's written). Fixed by
  walking the image's rows one at a time, advancing the display row
  in-place and calling `Layer.scrollOne` exactly when the next row would
  land past `self.height` — the same relative-advance shape
  `Layer.putAtCursor` already uses across a multi-character write, not an
  independent-absolute-`resolveRow`-per-row shape (which would
  double-scroll — see the next bullet for exactly that failure mode
  showing up one layer up the stack). Column clipping at `self.width` is
  unchanged — columns still don't scroll.
- **glyphwire-view's post-`draw_image` cursor move clamps to the layer's
  row count, to avoid double-counting scrolls `draw_image` already did.**
  view/main.zig's get-cursor/draw/set-cursor shape (draw at the cursor,
  then `set_property(cursor, cur.row + rows, 0)` so whatever runs next
  continues below the image) computed that target row against the
  *pre-draw* viewport. Once `draw_image` itself scrolls partway through a
  tall image (the fix just above), `cur.row` no longer means what it did
  when read — every scroll `draw_image` performed shifted its meaning up
  by one along with everything else — but the un-adjusted sum was still
  handed to `set_property(cursor, ...)`, which re-derives its own
  overshoot from scratch against the *current*, already-scrolled viewport
  (`Layer.resolveRow`'s contract, per its own doc comment, assumes each
  caller's row is already expressed relative to "right now," not to
  whatever the viewport was several scrolls ago). The result: for any
  image tall enough to scroll, the follow-up cursor move scrolled *again*
  by roughly however many rows the image itself already scrolled — visible
  as a run of extra blank rows between the image and the next prompt,
  worse for taller images. Fixed by clamping the target to the layer's own
  row count (`@min(cur.row + rows, grid_rows)`, `grid_rows` read via
  `get_cells` the same way `glyphwire-notify` already reads `grid_cols`) —
  when the image fit without scrolling this is a no-op (the sum was
  already ≤ `grid_rows`); when it didn't, it caps the request at exactly
  one row past the layer's last row, asking for exactly the one further
  scroll actually needed to open a fresh line below the image instead of
  redoing the scrolling `draw_image` already finished. `glyphwire-shell`
  used to hit the same stale-absolute-row shape in its plain-command
  output path (`writeCapturedText`) and capped it the same way; that path
  is gone now that `Layer.writeText` handles `\n` itself (see the
  styled-text section), but `core_tests.zig`'s
  `manyLinesPastBottomCursorCappedAtHeight...Test` still pins the
  underlying `set_property(cursor)` + `resolveRow` behavior.

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
- **`fg_icon` renders through the overlay batch, not the sprite batch.**
  `pixzig.Renderer` buffers each frame's draw calls into per-kind
  batches and flushes them in a fixed order at `end()` — sprites, then
  shapes (`drawFilledRect`), then overlays, then text — so painter's
  order between a sprite and a `drawFilledRect` is *not* the call order:
  a plain sprite always ends up under every fill that frame. A color
  background (`style.bg`'s `.color` case, e.g. a table's `alt_row_bg`
  stripe) is such a fill, so a `fg_icon` drawn as an ordinary sprite is
  hidden by it completely — which is exactly what happened to
  `glyphwire-ls -l`'s row icons once they moved to `fg_icon`. The host
  draws `fg_icon`s (immediate *and* deferred-for-`.natural`) via
  `drawOverlayTexture`, whose batch flushes after shapes, so the icon's
  alpha blends over the fill and the background color still shows
  through the icon's transparent pixels. `style.bg`'s `.icon` case stays
  on the plain sprite batch: it replaces the background outright, so
  nothing is fill-drawn for that cell to cover it.

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
  targeted request. The snapshot also carries `fg_icon` per cell (same
  shape as `bg_icon`) — an icon composited over the background rather
  than replacing it (`draw_icon`'s `foreground: true`, every table body
  icon), so a client reconstructing the screen from `get_cells` alone
  doesn't silently drop it — the pair a future mouse-click handler needs
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

### Table
- **Superseded: real server-side state, not client-composited cells.** A
  first prototype (`src/table.zig`, `Client.startTable`) built a table
  entirely out of existing primitives (`write_text`/`draw_icon`/
  `set_property("cursor")`) with no wire message of its own — simple, but
  meant a table was only ever whatever cells it happened to have written;
  the moment the producing process exited (`glyphwire-ls -l`, in
  particular), there was nothing left holding "this is a table" as a
  concept — no re-sorting, no toggling a display option, nothing but the
  frozen cells already on screen. Replaced with a real object
  (`core.Table`) and a message set (`create_table`/`destroy_table`/
  `table_set_rows`/`table_set_sort`/`table_set_style`/`table_get_state`)
  so the structured data — columns, typed cell values, sort state, style
  — lives server-side and survives the client that sent it.
- **A component of the layer it's drawn on, not a parallel object tree.**
  Unlike `Layer` (owned by `Context`, in its own `layers`/`layer_order`),
  a `Table` is owned by whichever `Layer` it was created on
  (`Layer.tables`, keyed by handle, plus `Layer.table_order` for
  compositing order among a layer's own tables) — simpler than a second
  tree, and a table has no need for the deeper nesting/nesting-independent
  positioning a layer does. Its handle (`TableHandle`) is still allocated
  from a single `Context`-wide counter, same numbering convention every
  other handle kind already uses, even though the value itself lives on
  the layer. Resizing a table after creation (more columns, a wider one)
  isn't built yet, but the object model doesn't foreclose it.
- **Compiles into ordinary cells; no host/rendering changes needed at
  all.** `Table.render` — called once per mutation
  (`table_set_rows`/`table_set_sort`/`table_set_style`), never per frame —
  writes the table's current (sorted) view directly into its owning
  layer's cells, the same `Cell` values `write_text`/`draw_icon` already
  produce. `glyphwire-host`'s render loop already draws whatever's in a
  layer's cell buffer regardless of what put it there, so this needed
  zero changes there — the entire feature landed without touching
  `host/main.zig`. This is also why a table survives its producing
  process exiting: the painted cells are just layer state, same as
  anything else drawn on it.
- **Typed cell values, not display text, for sorting.** A `TableCell` in
  a `table_set_rows` row carries both `display` (what's drawn) and a
  `SortKey` (`.text` or `.number`) it's compared on — distinct fields, so
  a Size column can display `"1.2 KB"` but sort correctly on the raw byte
  count instead of comparing that formatted string lexically (`"1"` before
  `"9"`, wrong). A cell with no explicit `sort_key` defaults to a copy of
  `display`, so sorting never needs a "nothing to compare" fallback.
  `sort_key` on the wire is a bare JSON number or string (not a wrapper
  object) — its own type already disambiguates which `SortKey` variant it
  means.
- **Scrolls the layer (once) to fit vertically, but writes cells
  directly rather than through the cursor-based helpers otherwise.**
  First tried "clip instead of scroll," on the reasoning that a table
  pinned at a fixed anchor is like `draw_box`/`draw_image`, which clamp
  their own rectangles to the layer's bounds rather than triggering a
  scroll — wrong in practice: a table is usually a *command's output*
  (`glyphwire-ls -l`, printed wherever the shell's prompt happened to
  leave the cursor, not necessarily near the top of the screen), and
  most of it silently never becoming visible at all (because nothing
  made room the way typing more text would) reads as "the table doesn't
  render," not "the table clipped." `Table.render` now resolves its
  anchor against `Layer.resolveRow` exactly once per render call —
  against the table's *bottom* row, then walked back to get the new
  top — before writing anything, so the whole table always ends up
  visible if it can be (scrolling earlier content, including whatever
  isn't this table, out of view exactly like new terminal output would).
  Once that one resolution lands, every actual cell write still goes
  through `layer.cell(r, c)` directly, not `Layer.writeText`/`drawIcon`'s
  cursor-implicit helpers, and horizontal overflow still just clips
  (there's no horizontal-scroll concept for a cell grid) — this is also
  why the resolution has to happen exactly once, up front, rather than
  emerging from many small per-cell writes: `Layer.resolveRow` scrolls
  *relative to whatever's currently at the top* on every out-of-bounds
  call, so resolving the same block's rows independently, one cell at a
  time, is exactly the compounding-scroll bug the `row_height > 1`
  variant of the client-composited prototype this replaced hit first.
- **No icon-only column — an icon lives on any cell, alongside its
  text.** The client-composited prototype needed a dedicated
  zero-content icon column (`.fit`-scaled into its own cell) plus a
  separate `tag_metadata` pass for a `.natural`-scaled icon's overflow.
  `TableCell.icon` (a resolved image handle, looked up by name against
  the icon catalog at `table_set_rows` time, same "fail loud on an
  unknown name" treatment `draw_icon`'s `name` already gets) draws
  alongside that same cell's `display` text instead — e.g.
  `glyphwire-ls`'s Name column carries both a per-entry icon and the
  filename in one cell, one column, not two.
- **A body icon composites over the row background, not into it.** A
  table body icon goes into the cell's `Cell.fg_icon` (via
  `setCellIconOver`), the same "draw over whatever background is already
  there" slot `draw_icon`'s `foreground: true` uses — not `style.bg`'s
  `.icon` case, which would *replace* the background. `style.bg` is one
  mutually exclusive `Background`, so an icon written there on a striped
  row (`alt_row_bg`, filled first by `fillRowBg`) punched a flat,
  icon-shaped hole straight through the stripe; and a `row_height > 1`
  `.natural`-scaled icon that overflows past its anchor cell (see the
  Icon section's `max_w`/`max_h`) would be drawn *under* the next row's
  background, since the host paints backgrounds in grid order but defers
  `.natural` icons — `style.bg` *and* `fg_icon` — past the whole grid.
  Routing the icon through `fg_icon` fixes both: the stripe stays
  unbroken behind the icon cell, and the deferred overflow lands on top
  of every row's background regardless of draw order.
- **`row_height` carried forward from the prototype, minus its bug.**
  `TableStyle.row_height` (cells per body row, `1` the default) is the
  "large format" option added mid-development of the client-composited
  version — kept here since the underlying need (a bigger, legible,
  `.natural`-scaled icon per row) didn't go away, just without the
  scrolling bug noted above. A `row_height > 1` row's icon is capped to
  `row_height` cell-heights tall, sized from the icon's *actual* loaded
  pixel width (`Context.imageInfo`) rather than a hardcoded constant the
  prototype used.
- **Interactivity (sort-on-click, a style toggle) is deliberately
  server-data-only for now, not server-autonomous.** The server doesn't
  hit-test mouse clicks against a table's header itself — that stays
  consistent with how every other click-driven behavior in this codebase
  already works (`glyphwire-shell`'s `activateSelectionAt`: a client
  subscribes to `mouse_button`, resolves the clicked cell via
  `get_metadata`, and decides what to do). What's built now is the
  *mutation* API a click handler would eventually call
  (`table_set_sort`/`table_set_style`) and the data model it acts on;
  wiring an actual header-click-to-sort/checkbox-toggle handler into
  `glyphwire-shell` (almost certainly via a `metadata_id` on header cells
  identifying them as sort/style triggers, mirroring how
  `glyphwire-ls`'s own cells already carry click-actionable metadata) is
  deliberately left as a follow-up.
- **`table_get_state` reports structure, not rendered cells.** Row count,
  sort state, style, and revision — not the cells themselves, which are
  already readable through the owning layer's ordinary `get_cells` (a
  table paints into ordinary cells, per above). For a future client that
  needs to know e.g. which columns are sortable before deciding what a
  header click should do.

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

#### Prompt word-splitting, quoting, aliases
- The prompt used to split lines on bare whitespace (`std.mem.tokenizeAny`).
  It now runs through `shell/wordsplit.zig`'s `split`, which is quote- and
  escape-aware: `'...'` (fully literal), `"..."` (also literal here — the
  shell has no `$`/backtick/`!` expansion, so only `\"` and `\\` are
  special inside it), and backslash-escaping of the next byte outside
  quotes. This is the minimum needed for filenames with spaces (`cat 'my
  file.txt'`) and is the shared front end for alias bodies and (later)
  glob tokens.
- **`alias` / `unalias` are builtins**, session-only — there's no config
  file yet (a Lua-backed startup config is the planned next step), so
  nothing survives `exit`. `alias NAME=VALUE` uses **rest-of-line value
  semantics**: everything after the first `=` is the body, with one
  wrapping quote pair stripped. So `alias ll=ls -l` and `alias ll='ls
  -l'` are equivalent. This was chosen over bash's per-argument
  `name=value` splitting (which would let `alias a=1 b=2` define two at
  once) because rest-of-line needs no quoting for the common
  `alias g=git status` case; quoting is still there when you need a
  literal leading/trailing space (`alias x=' ls '`).
- Alias expansion happens only on the **first word** of a line, before
  builtin/command dispatch, so an alias can resolve to a builtin
  (`alias h=cd ~`) or another alias. Chains are followed, but a name is
  never expanded twice on one line — `alias ls='ls --color'` resolves
  once and stops, matching bash — with a hard depth cap as a backstop.
- `alias` itself is detected off the **raw** line, ahead of
  word-splitting, because its value isn't word-split the way the rest of
  a line is. Every other builtin (`cd`, `exit`, `unalias`) is dispatched
  from the post-split, post-alias-expansion argv.

#### Tab completion
- **Filenames only, bash-style two-press behaviour.** Tab completes the
  word under the cursor against the directory named by its leading
  `dir/` part (cwd if none; `~`/`~/` expanded). One match: filled in,
  with `/` appended for a directory and a space for anything else.
  Several matches with a longer shared prefix: the word is extended to
  that prefix (first Tab). Several matches with nothing more in common:
  the candidate list is printed below the prompt, but only on the
  *second* consecutive Tab (`Prompt.completion_armed`, cleared by any
  other key) — the same "bell once, then list" rule bash uses, chosen
  over fish's always-list because printing to the grid and redrawing the
  prompt is the heavier operation here.
- Dot-files are only offered when the typed prefix itself begins with a
  dot. Directory-ness comes from the readdir entry `kind`, so a symlink
  to a directory is treated as a plain file (gets a space, not `/`) —
  acceptable for now, revisit if it bites.
- Quoting inside the completed word is **not** interpreted
  (`complete.wordRange` is pure string math): a Tab inside `'...'` sees
  the quote as an ordinary character. Command-name completion from
  `$PATH` and richer, config-driven completions (the planned Lua config
  is the natural home for those) are explicitly out of scope for now.
- Split for testability: `shell/complete.zig` holds the pure helpers
  (word boundary, `dir/`+prefix split, longest common prefix); the
  directory scan and the grid edits stay in `Prompt.doComplete` /
  `listCompletions`.

#### `*` glob expansion
- **Single-segment only, for now.** A token containing `*`, `?`, or a
  well-formed `[...]` class has its *final* path segment matched against
  the entries of the directory its literal `dir/` prefix names (cwd if
  none; `~`/`~/` expanded). The sorted matches replace the token, each
  keeping the original `dir/` prefix — so `ls src/*.zig` works, but a
  wildcard in an earlier segment (`ls */*.zig`) is left literal.
  Recursive multi-segment globbing is a deliberate later step.
- **No match → literal token**, bash's default (nullglob off). `rm
  build/*.o` with nothing to match runs `rm` with a literal `build/*.o`.
- Expansion runs **after** alias expansion, as the last step before
  dispatch. A **quoted or backslash-escaped** wildcard is never expanded
  — `echo '*'`, `echo "*"`, `echo \*` all print a literal `*`. That's
  why `shell/wordsplit.zig` now carries a per-token `quoted` flag
  (`Arg`) through alias expansion into `Prompt.expandGlobs`; tokens
  introduced by an alias body are glob-eligible, so `alias l='ls *'`
  still expands in the caller's directory like bash.
- Dot-files are only matched when the pattern's final segment starts
  with a literal `.` (`Prompt.expandGlobs` enforces this; the matcher in
  `shell/glob.zig` is otherwise plain `*`/`?`/`[...]` string matching
  with `!`/`^` negation and `a-z` ranges).

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

**Decision:** `write_text` interprets the C0 control bytes that describe
plain cursor motion, and *strips* (without interpreting) VT100/ANSI
escape sequences — but nothing more. `\n`/`\v`/`\f` act as newline
(carriage return + line feed, matching a cooked terminal, so `"a\nb"`
puts `b` at column 0 of the next row instead of staircasing under the end
of `a`); `\r` returns to column 0; `\t` advances to the next 8-column tab
stop, clamped to the last column rather than wrapping; `\b` steps back
one column non-destructively (a no-op at column 0); every other C0 byte
and DEL is silently dropped. A stray `ESC [ … ` (CSI) or `ESC ]`/`P`/`X`/
`^`/`_ … ` (string) sequence is recognized only well enough to know where
it ends, then discarded. The stripper state is **not carried between
`write_text` calls**: a sequence still open when a call's text runs out
is abandoned — `Layer.esc_state` is reset to `.ground` before the call
returns — and its tail then draws as ordinary text in the next call.
This gives up cleanly stripping a sequence a pipe happened to split
across two chunks (rare — a plain program emits each escape in one
`write`), in exchange for the guarantee that a lone trailing `ESC`, a
truncated `ESC [ …`, or an unterminated `ESC ] …` (OSC) can **never**
silently swallow everything written afterward, `glyphwire-shell`'s own
prompt included. (The first cut kept the state on the `Layer` so a split
sequence dropped as one unit; that let an unterminated OSC in a `cat`'d
file wedge the root layer — no more output, no prompt — so the trade was
reversed.) This is the *baseline* terminal
behavior a `print`-style program already assumes, not an escape-code
interpreter: glyphwire replaces the VT100 model rather than reimplementing
it (see this file's opening), and a `write_text` caller that wants
styled or positioned output uses `fg`/`bg` and the cursor/`row`/`col`
mechanisms above. Full escape *interpretation* — should a program ever
genuinely need it — is a separate, deliberate layer to add later, and the
object model is expected to absorb it without disturbing this shape.
Before this, `glyphwire-shell` split piped child output on `\n` itself
(`writeCapturedText`, plus a `grid_rows` scroll-counter cap for a bug
that arose from doing so); moving the handling into `core` let that go
back to a single `write_text` of each raw chunk.

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
