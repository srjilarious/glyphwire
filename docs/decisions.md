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
  defaults to "plain program writing to a terminal": it runs the child on
  a **pseudo-terminal** (B0, `src/pty.zig` — see roadmap.md) and
  forwards each chunk of the master onto the grid via a single
  `write_text` (`Prompt.ptyReaderThread`), letting `Layer.writeText`'s own
  C0 handling and SGR/CSI interpretation (see the styled-text section)
  take care of `\n`/`\r`/`\t` and escape sequences. (Before B0 the child
  was spawned with piped stdout/stderr and no stdin; the pty gets the
  child to line-buffer instead of block-buffer, makes `isatty()` true,
  and lets keystrokes flow in — see roadmap.md's B0 entry and
  `docs/investigations/libghostty-vt-fallback.md` §7a.)
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
  (`std.log.err` and similar) still land somewhere. Since B0 the child
  always runs on a pty (stdout *and* stderr merged onto the one master,
  as a real tty does) and interactive stdin works, so the earlier
  "commands that don't need real stdin only" limitation is gone. An
  unknown command is still reported the same way — `execvp` failing
  inside the forked child is signalled back to the parent over a
  close-on-exec pipe (`Pty.spawn`), which turns it into
  `error.CommandNotFound` and a red `"<cmd>: command not found"` on the
  grid.

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
  follow directly on the socket. `format` is parsed (`png`/`jpeg`/`bmp`/
  `gif`) and picks the header parser used to measure the image — see the
  Image section.
- The Zig `Client`'s request path reads the response frame with a
  deadline (`Client.read_timeout`, default 30s, via `io.operateTimeout`
  on the `net_read` op — `Stream.read` has no timeout form). Every method
  on `Client` is a synchronous send-then-wait-one-frame round trip
  against a mutex-guarded, strictly-in-order dispatcher, so a legitimate
  response is milliseconds away; a read that stalls that long means the
  peer is wedged or gone, and blocking forever there just converts a dead
  server into a hung client (or, in the test suites that drive a
  library-bound `Server` on background threads, a hung test *process*).
  Notifications and the `InputListener` event stream are unaffected — a
  subscribed client legitimately waits arbitrarily long for the next
  event.

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

### Error reporting
- **No JSON-RPC error responses yet** (roadmap Milestone 0). A request
  that errors severs the connection; a notification that errors is
  logged host-side and swallowed. That leaves a notification's sender —
  the fire-and-forget majority of the client→server catalog — with no
  way to learn its `destroy_layer` / `write_text` / `draw_*` was
  rejected.
- **Interim: a per-connection error ring, opt-in via `subscribe("error")`,
  pulled with `get_errors`.** Chosen over the alternatives:
  - *Promote each notification to a request* — a synchronous round trip
    on every draw call to serve a rare error, and a wire-shape change to
    dozens of messages. No.
  - *Push an `error` notification* — the connection that sends the
    failing notification is the synchronous `Client` (the async
    `InputListener` is a separate connection), and interleaving pushed
    frames with `Client`'s request/response reads is the thing that
    architecture avoids. A pull ring fits `Client` as-is.
  - JSON-RPC itself offers nothing here — the spec explicitly says a
    notification's sender can't be told about errors; the only lever is
    request/response.
- **Ring of 5, drop-oldest, drained by `get_errors`.** A client polls
  between batches of work; `get_errors` returns the buffered
  `{method, code, seq}` records oldest-first plus a `dropped` count (how
  many were lost to a full ring since the last call) and clears the ring.
  Small and lossy on purpose — keeping every error indefinitely for a
  client that subscribed and never drained is just a leak; `dropped` is
  the signal that you fell behind. `code` is the `DispatchError` name
  (`"LayerPermissionDenied"`, `"UnknownLayer"`, …); `seq` is a
  per-connection monotonic counter for ordering / gap detection.
- **Opt-in.** Nothing is recorded until the connection subscribes to
  `"error"`, so the default path stays allocation-free and
  behaviour-identical. Batched sub-message failures are recorded too
  (they route through the same dispatch path). When real error responses
  land, this stays as the mechanism for the fire-and-forget case.

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
  conflated with physical key press/release. *Implemented so far:* the
  `text` notification carries committed text (post-layout, post-dead-key,
  post-IME) as a UTF-8 string, subscribable separately from `key`. The
  host sends both a `key_*` event (physical key, for chords/navigation)
  and a `text` event (the character) for a printable keystroke; a
  consumer that edits text uses `text` and ignores the key. A live
  preedit/composition-string stream is still open. On the client the two
  are merged back into one arrival-ordered queue (`InputListener`'s
  `InputEvent`) so a "type then Enter" burst can't reorder across the
  two.
- Subscription is opt-in per event type (X11 event-mask precedent) so a
  client isn't firehosed with events it never asked for.
- Continuous/analog streams (mouse motion, gamepad axes) may be coalesced
  or dropped under backpressure if the client is slow to consume them.
  Discrete state-change events (press/release, layer lifecycle) are never
  dropped. *Implemented:* the `mouse_move` notification (`{px, cell}`) is
  a coalesced stream — the host reports every pixel of motion in-process
  but a broadcast only goes out on a **cell** change, and `InputListener`
  caps its queue and drops the backlog if the consumer stalls. It's a
  separate subscription (`"mouse_move"`) from `"mouse_button"` so a
  click-only client isn't firehosed.
- **The wire's key and mouse-button names come from the engine
  backend's enums, which are now SDL3's** (`host_eng/input.zig`).
  `host/input.zig` forwards each key and button by `@tagName`, so those
  field names *are* protocol, and `src/key_encode.zig` matches on the
  same strings. Two consequences of retiring the GLFW backend: `F25` and
  `world_1`/`world_2` are gone (GLFW declared them; no SDL keycode maps
  to any of them, and the SDL3 branch's placeholder
  `SDLK_EXECUTE => .F25` was an invention), and the two side mouse
  buttons are `x1`/`x2` rather than GLFW's `four`/`five` — GLFW's
  `six`..`eight`, which no platform ever reported, are gone with them.
  `left`/`right`/`middle` and every key name a terminal actually uses are
  unchanged, so nothing in glyphwire or glyphwire-shell moved. The names
  are *keycode*-derived, not scancode: on a Dvorak or AZERTY layout a key
  reports the identity on its keycap, which is what a terminal wants and
  what other terminals do.
- **IME composition is host-local and never crosses the wire.** SDL3
  hands the host the in-progress composition (`SDL_EVENT_TEXT_EDITING`)
  and the host draws it at the caret itself; only the IME's *commit*
  reaches the wire, as an ordinary `text` notification. The keys the IME
  consumes while composing (Space to convert, Enter to commit) never
  surface as `SDL_EVENT_KEY_DOWN` at all, so there is nothing to filter
  out of the key stream and no risk of Enter-to-commit also running the
  command line — verified with a Japanese IME. A live preedit *stream*
  on the wire, for a client that wants to draw its own, is still open.
- **Key and button state is dropped on window focus loss.** SDL is
  polled, so the down-sets are event-driven and latch: a key held as the
  window loses focus never sees its key-up, and would stay down forever
  in `get_input_state` (and keep synthesizing typematic repeats). The
  host clears both the current and the previous tick's state on
  `SDL_EVENT_WINDOW_FOCUS_LOST`, the previous one too so the resync
  doesn't read as a `released` edge and put a key-up on the wire for a
  key-down the subscriber never saw.
- **pty input path (B0):** while glyphwire-shell has a non-glyphwire
  child foregrounded on a pseudo-terminal, its foreground loop re-encodes
  `InputListener` events into the bytes a real terminal would send and
  writes them to the pty master. It watches the child's own output
  (`glyphwire.ModeTracker`, sniffing `ESC [ ? Ps h/l`) for the DEC
  private modes that change that encoding: application cursor keys
  (`?1`, arrows/Home/End become `ESC O x`), bracketed paste (`?2004`,
  paste wrapped in `ESC [ 200~`/`201~`), and mouse reporting
  (`?1000`/`?1002`/`?1003` gate whether button/motion events are sent,
  `?1006` picks SGR vs. the legacy `ESC [ M` byte triples). `resize`
  events are forwarded to the pty as `TIOCSWINSZ` so the child gets a
  live `SIGWINCH`. No wire change — the mode state is local to the
  shell, sniffed rather than queried. Wheel-to-pty is still open (the
  shell only sees the resolved scrollback offset, not wheel notches).

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
  (default — it acts on whichever context is visible when it connects) or
  **create_context** (explicit request, for something like a fullscreen
  editor that wants its own). `attach_context` retargets a connection
  onto an existing context after the fact — a program's second
  connection (a subscribed `InputListener` paired with its `Client`) uses
  it to join the context the first one created.
- When the program owning the currently-visible context disconnects, the
  server automatically switches visibility back to the previously-visible
  context — mirrors how alt-screen auto-restores on program exit today,
  generalized to a history instead of a single slot.
- **Built** — see "v1 built — context lifecycle" in the Layers section
  for the message set, the ownership/cull rules (mirroring layers), the
  root-context invariant, and the input-gating decision. Discovery still
  carries two env vars (`GLYPHWIRE_SOCK`, `GLYPHWIRE_CTX`), but nothing
  parses `GLYPHWIRE_CTX` yet — inherit-the-visible plus `attach_context`
  covers the current need; honouring the env var to inherit a *specific*
  context at connect time is the remaining piece.

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
  - **The grid size is debounced (`geometry.resize_settle_ms`, 120ms).**
    `syncWindowSize` used to call `reportResize` on every intermediate
    pixel size while the window was being dragged, so every subscribed
    client reflowed dozens of times per drag — visibly laggy for the
    shell's prompt and worse for a TUI whose panes and buffer all redraw
    on each `resize` / `layout`. Now a new size has to hold steady for
    `resize_settle_ms` before it is committed; in between, `render` draws
    the old grid clipped or letterboxed into the new framebuffer (the
    engine already rebuilt the projection). `App.idleTimeoutMs` folds in
    `WindowSizing.settleTimeoutMs` so the redraw-on-change loop wakes to
    flush the settled size after the OS event stream goes quiet. The
    decision (`geometry.resizeSettleStep`) is a pure function, covered by
    `tests/host_tests.zig` without a window. Font-zoom's
    `resizeWindowForCells` is unaffected: it targets the framebuffer for
    the current grid, so `syncWindowSize` sees no change to debounce.
  - **A divider drag previews, and commits once on release.** `Panes`
    used to call `moveDivider` + `reportLayout` on every mouse-move frame,
    so both panes either side (and, in zoe, the buffer inside one) redrew
    continuously through the drag. Now the drag only moves a ghost band
    (`Panes.preview`, drawn by `render.zig`); the real `moveDivider` and a
    single `reportLayout` fire on button release. The ghost does not model
    a pane hitting its minimum — the layout walk that decides that is not
    run until release — so a drag past a limit over-travels the ghost and
    the divider snaps back on release, an accepted trade for not
    reflowing mid-drag.
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
- **v1 built — multi-pane layout (`size`, `visibility`, stacking,
  `cell_position`):** four gaps that only showed up once a program wanted
  *several* layers at once rather than one popup over the shell (zoe, the
  editor — see `docs/investigations/zoe-editor.md`). Each is a small
  addition to the existing property/handle machinery rather than a new
  object:
  - **`size` is settable on a non-root layer.** A sidebar-plus-buffer TUI
    has to reflow both panes when a `resize` arrives, and the only way to
    do that before was `destroy_layer` + `create_layer`, which throws
    away the layer's handle, its tables, its metadata ids and its
    content, and forces every client-side reference to be rebuilt.
    Setting it goes through `Layer.resize`, so a pane resize is
    bottom-anchored exactly like a window resize. It also clears
    `tracks_context_size`: a client that names its own size has taken
    over the layout, and must not then be dragged around by the next
    window resize. Get-only for the **root** layer, whose size the host
    owns — that half is unchanged.
  - **`visibility`** (previously 🔶) is now built, non-root only. A
    hidden layer keeps its cells, tables and cached quad batch; the
    renderer skips it in both the sync and draw passes, so a toggled file
    tree costs nothing to bring back and doesn't lose its scroll position
    or its metadata ids. Hiding the root layer is refused for the same
    reason `destroy_layer` refuses it: it would blank the session with no
    wire path back.
  - **`raise_layer` / `lower_layer`.** Compositing order was creation
    order, which is fine for one notification popup and wrong the moment
    a completion popup created at startup has to sit over a tree created
    later. Two notifications rather than a `z_index` property: the model
    is already an ordered list (`Context.layer_order`), and X11's
    stacking-relative-to-a-sibling is the precedent glyphwire already
    borrows from for input masks. Order is read live each frame, so a
    restack invalidates no cached batch.
  - **`cell_position`.** Position stays pixel-precise as the primitive —
    the smooth-animation argument above is unchanged — but a TUI lays
    itself out in cells, and doing the conversion client-side means
    reading `get_cell_metrics`, multiplying, and then redoing it on every
    font-size change (which no notification announces). Resolving it
    server-side makes the placement *sticky*: `Context.setCellMetrics`
    re-derives the pixel position of every cell-placed layer, so
    glyphwire-host's Ctrl+`+` / Ctrl+`-` keeps a sidebar on its column
    instead of leaving it half a cell off. A pixel `position` write
    un-sticks it. This is also why the host now calls `setCellMetrics`
    rather than assigning `ctx.cell_px_w`/`cell_px_h` directly.

  A fifth candidate — routing input *to* a focused layer — was
  deliberately **not** added: input is broadcast to subscribers, and a
  multi-layer program is one process that already knows which of its own
  panes has focus. A focus concept only earns its place once two separate
  processes draw into the same context.
- **v1 built — content vs. viewport, per-layer scrolling, and a split
  tree.** The multi-pane properties above put panes *somewhere*; these
  answer the two questions that come straight after — what does a pane
  show when its content is bigger than it, and who decides where the
  panes go.
  - **A layer's cell grid is its *content*; what the host draws is its
    *viewport*.** `viewport` (`{cols, rows}`, zero meaning "all of it")
    and `scroll_offset` (`{row, col}`, the window's top-left within the
    content) split what used to be one thing. A file tree is then a
    90×500 layer shown through a 30×40 viewport rather than a 30×40 layer
    the client rewrites on every scroll tick — which matters because the
    alternative puts a wire round trip in the middle of a mouse wheel.
    The host clamps `scroll_offset` to `size - viewport`, so a client
    cannot park the viewport off the end of its own content, and a
    `resize` or a viewport change re-clamps rather than stranding it.
  - **This is deliberately *not* the same axis as `scroll`.** The
    existing `scroll`/`scroll_view` pair is the terminal-style scrollback
    ring: how far back into retained history the live viewport is
    looking, anchored at the live tail. `scroll_offset` is a window over
    the content grid, anchored at the top. They compose (`scroll` picks
    which rows are live, `scroll_offset` the window over them), and a
    pane created with `scrollback_rows: 0` — every pane in a TUI — only
    ever uses the second. Collapsing them into one property was
    considered and rejected: the two have different origins and different
    maxima, and re-anchoring the root layer's scrollback would have
    rewritten glyphwire-shell's browse cursor for no gain.
  - **Scrollbars are per-layer and opt-in per axis.** `scrollbars`
    (`{vertical, horizontal}`) makes the host draw bars inside a layer's
    own bounds, driving `scroll_offset` from wheel, thumb drag and track
    page. Opt-in because a statusline or a popup can easily have content
    wider than its pane and should not sprout a bar; and a bar is skipped
    anyway on an axis with no slack, so a wheel over a pane with nothing
    to scroll falls through to the shell's scrollback underneath instead
    of being silently swallowed. Horizontal is real, not decorative: a
    tree with long filenames is exactly the case that motivated it.
    - **The thumb is sized from the effective content, not the real
      grid.** `paneScrollbars` builds the thumb length from
      `viewport + max_row` (or `_col`) — the reach the `ScrollbarState`
      already reports, which folds in a self-scrolling pane's virtual
      `content_extent`. An earlier cut passed the layer's raw cell grid
      as the content size, so a `content_extent` pane (real grid ==
      viewport) always drew a full-height thumb that looked like there
      was nothing to scroll.
  - **The window's right-edge bar is opt-out per context.**
    `Context.window_scrollbar` (default on; `create_context`'s
    `window_scrollbar` field, or the `set_window_scrollbar` notification
    at runtime) is whether glyphwire-host paints its always-on
    scrollback bar. The shell and every terminal-style client keep it; a
    pure-TUI context like zoe — whose root has no scrollback and whose
    panes carry their own `scrollbars` — turns it off, since the bar
    would otherwise sit there permanently full and inert. **The gutter is
    reclaimed when the bar is hidden:** `syncWindowSize` (px → cells) and
    `resizeWindowForCells` (cells → px) read `geometry.rightGutterPx`,
    which is zero for a bar-less visible context, so the grid reflows
    wider to fill the ~12px the bar would have taken instead of leaving a
    dead strip. Grid sizing stays session-global, so a context switch
    between a bar and a bar-less context does trigger one `reportResize`
    — but it rides the existing debounce (`resize_settle_ms`), the same
    path a window drag takes, and a full-screen program appearing or
    leaving already reflows the surface.
  - **`content_extent` gives a self-scrolling pane a real scrollbar.**
    A pane whose real cell grid is only viewport-sized — a TUI editor's
    buffer, which redraws its visible rows on every scroll because a full
    grid for a large file would be hundreds of megabytes — has no slack
    for the host to draw a bar from, and a wheel over it would fall
    through to the shell's scrollback. `content_extent` (`{cols, rows}`,
    `{0,0}` to clear) is the client telling the host how big the whole
    content really is. The host then draws the bar proportionally and,
    on a wheel or thumb drag, moves a *virtual* offset and broadcasts the
    ordinary `scroll_offset` notification; the client obeys it and
    redraws. No new notification and no new "scroll request" verb: the
    host already broadcasts `scroll_offset` for its own wheel/scrollbar
    over a host-scrolled pane, and a self-scrolling pane wants exactly the
    same event with exactly the same meaning ("the view moved, redraw").
    The real grid's `scroll_off` never moves — `content_off` is a
    parallel field the scrollbar/`maxScroll`/`scroll_offset` maths select
    when `content_extent` is set. Considered and rejected: a dedicated
    `content_offset` property and a `scroll_request` notification — both
    duplicate `scroll_offset` for no gain, and the client already knows
    which of its panes is self-scrolling by handle.
  - **The split tree lives server-side.** `create_split` /
    `set_split_children` / `set_root_split` / `move_divider`: a client
    describes the arrangement once and the host computes every pane's
    bounds, re-computes them on a window resize, and owns the divider
    drag. The alternative — the client computing bounds and pushing
    `cell_position` + `viewport` per pane — was the initial plan and was
    rejected on two counts: a drag would round-trip every mouse-move
    through the client to move a divider that is pure geometry, and every
    TUI would re-implement the same pane maths slightly differently.
    Making it a real object also gives the host somewhere to hit-test,
    which a pile of independently positioned layers doesn't have.
  - **Two sizing modes, because one isn't enough.** A child is `weight`
    (a share of what's left) or `fixed` (exact cells along the axis).
    Pure ratios can't express a one-row statusline without the client
    recomputing a fraction on every resize; pure fixed sizes can't
    express "the buffer takes the rest". Fixed children are measured
    first and the last weighted child absorbs the rounding remainder, so
    children plus dividers always fill the split exactly rather than
    leaving a stray blank column. A drag preserves whichever mode each
    neighbour declared — a fixed pane gets a new cell count, a weighted
    pair keeps its *combined* weight and re-splits it — so resizing two
    panes never disturbs the rest of the tree.
  - **A split can opt out of resize entirely.** `create_split`'s
    `resizable` (default true) — false means the split reserves **no**
    `divider_cells` gap between its children, emits no `DividerRect` for
    the host to draw or hit-test, and `move_divider` on it is a no-op.
    The motivating case is an editor's outer column split: the buffer
    area over a one-row command line, where the command line is `fixed: 1`
    anyway and a full-width drag handle above it is a wasted row that
    also *looks* draggable when it isn't. zoe's inner tree|buffer split
    stays resizable; only the outer one opts out.
  - **The root layer is never a split child.** It's a context's own
    scrollback, drawn at a fixed origin; a split tree's panes cover it.
    Within one context this gives an in-place alt-screen (a full-screen
    program's panes over the shell's scrollback); `create_context` (below)
    is for a program that wants its *own* whole surface instead.
  - **`layout` is one notification for the whole tree**, not one per
    pane, so a client redraws once against a consistent set of bounds.
    It carries only what moved, and a re-layout that changes nothing is
    silent — which is what makes the layout walk safe for the host to
    re-run purely to recover divider geometry. `Context.layout_gen` is
    the cache key the host uses to avoid even that most frames.
  - **`move_content` shifts a band of a pane's grid in place.** A pane
    that owns its own scroll position (`scrollback_rows: 0`, content grid
    exactly viewport-sized — a TUI editor's buffer, where a full cell
    grid for a large file would be hundreds of megabytes) still has to
    *repaint* to scroll, and repainting every visible row on every scroll
    tick is `rows` `write_text` pairs down the socket per keystroke —
    which is what made zoe's buffer pane feel heavy. `move_content` is
    the wire face of `Layer.scrollRange`, the primitive that already
    backs CSI SU/SD and IL/DL: the client shifts the rows it still has
    with one message and repaints only the band the scroll exposed. It is
    a notification (best-effort, no clamp report) and batchable, so the
    shift and the follow-up partial redraw land in one frame. Not a
    `scroll_offset` move: that property drives a host viewport over a
    larger content grid, which is exactly what this kind of pane doesn't
    have.
- **v1 built — layer ownership & lifecycle:** every `create_layer` over a
  socket connection records that connection as the layer's first
  **owner**. `adopt_layer` adds more owners (one process handing ongoing
  responsibility for a layer to another). When a connection closes — a
  clean exit, `kill`, or a crash: the kernel closes the socket either way
  — the server drops it from every layer's owner set and destroys any
  layer left with no owners (`Context.removeConnectionOwnership`, run in
  the connection's teardown under `ctx_mutex`). This is what keeps a
  program that dies without calling `destroy_layer` from leaving its
  content stuck on the host. The common case is unaffected: the shell
  keeps one long-lived connection open for its whole session, so a layer
  it created stays until it explicitly destroys it, and `glyphwire-ls` /
  `glyphwire-view` write into the root layer rather than creating their
  own. **Decisions:** *identity is per-connection*, a plain counter
  assigned at `accept` (`core.ConnId` / `Server.next_conn_id`), not a
  `SO_PEERCRED` PID — a program keeps a single connection open for its
  lifetime so "the process that created it" is naturally satisfied, and a
  reconnecting client owning nothing from its previous connection matches
  the auto-restore-on-disconnect precedent above. *Liveness is the socket
  itself* — no PID poller / `/proc` watcher; socket close is delivered by
  the kernel on process death, so it already covers crash, `kill -9`, and
  clean exit, with no polling interval or PID-reuse hazard. *Culling is
  unconditional* — there's no `persist` opt-out on `create_layer`; a
  layer meant to outlive its creator's connection is `adopt_layer`'d by
  another live connection instead. *`destroy_layer` is ownership-checked*
  — a non-owner connection's call returns `LayerPermissionDenied`.
  Because `destroy_layer` is a notification with no response channel,
  server.zig turns that into a logged warning and leaves the layer
  intact; a real JSON-RPC error *response* still needs the unbuilt
  error-response path (roadmap Milestone 0). *Out of scope:*
  `release_layer` / disowning without disconnecting (a process releases
  by closing its connection), ownership transfer as a distinct operation
  (adopt + let the original drop covers it), admin override.
- **v1 built — context lifecycle (`create_context` and friends):** the
  server holds one `core.Session` — a registry of `Context`s plus a
  **visibility stack**, only the top of which glyphwire-host renders.
  This is the alt-screen model generalised from one alternate buffer to
  N persistent contexts (see the Object Model's Context section); the
  motivating client is `zoe`, which wants its own whole surface rather
  than panes stacked over the shell's scrollback.
  - **The root context** (handle `0`, `core.root_context_handle`) is the
    one the server starts with. It's never culled, can't be destroyed,
    and is permanently the bottom of the visibility stack — there is
    always something to fall back to, exactly `root_layer_handle`'s role
    one level down.
  - **A connection inherits the visible context** at `accept`, and every
    `layer?`-scoped message resolves against its *current* context —
    per-connection ambient state (`Dispatcher.active_ctx`), not a
    `context?` param bolted onto thirty messages. `create_context`
    retargets the issuing connection onto the new context;
    `attach_context` retargets it onto an existing one (the primitive a
    paired `InputListener` uses to join the context its `Client` made,
    and the same mechanism a future `GLYPHWIRE_CTX`-honouring connection
    would use at startup — that env var is written by the host/shell but
    not yet parsed).
  - **`create_context` shows the new context immediately** and makes the
    caller its first owner. **`activate_context`** moves an existing
    context to the top of the stack *without* changing which context the
    caller draws on — so a client backgrounds itself by activating the
    root context and restores itself by activating its own handle again.
  - **Ownership & culling mirror layers exactly.** `create_context`
    records the connection as owner, `adopt_context` adds more, and when
    a connection closes every context it solely owned is destroyed
    (`Session.reapConnection`, run in the same teardown as the layer
    cull, under `ctx_mutex`) — taking every layer, split and table in it
    with it. A visible context going this way pops visibility to
    whatever was under it: the classic alt-screen auto-restore on a
    program's exit, now a real history rather than a single slot.
    `destroy_context` is ownership-checked (`ContextPermissionDenied`
    for a non-owner, logged-and-dropped like `destroy_layer`;
    `RootContextImmutable` for handle 0).
  - **Who may create / activate:** anyone. This was the open item; the
    answer for a single-user local session is that there's no privilege
    boundary to enforce — a connection can create a context, activate
    any context, and attach to any context. Ownership gates *destruction*
    only.
  - **Raw input follows visibility.** `key` / `text` / `mouse_button` /
    `mouse_move` reach only the connection whose current context is the
    visible one, so a backgrounded full-screen editor stops eating the
    keystrokes meant for the shell. Every other server→client event
    (`resize`, `layout`, `scroll`, `selection`, the new `context`
    notification) still fans out to all subscribers, so a backgrounded
    client can keep its panes current for when it's shown again.
  - **Assets aren't copied per context.** A `create_context` context's
    `icons`/`images` fall back to the root context's catalog
    (`Context.asset_fallback`), so `draw_icon` names the host registered
    at startup resolve without every context re-loading the bundled
    bytes.
  - **The host learns of a switch in-process** via a change-counter
    (`Session.visible_gen`, polled each frame) — on a bump it drops its
    per-layer render-batch cache, since the newly-visible context's
    layers reuse the same handle numbers. Other clients get the wire
    `context` notification.
- **Not built — still open:** non-root layer parenting, `clip` property,
  a raw wheel-delta `mouse_scroll` event stream (distinct from `scroll`,
  which reports the resolved offset), `GLYPHWIRE_CTX`-based discovery
  (the env var exists but inherit-the-visible + `attach_context` covers
  the need for now).
- **v1 built — font config + runtime zoom:** `glyphwire-host` runs
  `~/.config/glyphwire/host.conf` at startup (global `config` table:
  `font_face`, `font_face_name`, `font_fallback`, `font_size`; any subset,
  missing file = all defaults). The config directory is resolved by the
  same rule as the shell's `shell.conf` — `$GLYPHWIRE_CONFIG_DIR`
  verbatim, else `$XDG_CONFIG_HOME/glyphwire`, else `$HOME/.config/glyphwire`
  — via a `configDirPath` in `host/main.zig` kept byte-for-byte in step
  with the shell's own copy. Was previously read from `assets/conf.lua`
  relative to the working directory; moved so a user's real config isn't
  the repo's checked-in file. Kept host-local rather than a wire concern —
  the font is a property of the rendering front end, not the shared grid
  model, and the shell already has its own separate Lua config
  (`~/.config/glyphwire/shell.conf`), so no new dependency for it. At
  runtime `Ctrl+-` / `Ctrl++` / `Ctrl+0` repack the engine's default font
  atlas in place (`FontAtlas.setFontSize`) and
  the host re-measures `cell_w`/`cell_h`, updates `ctx.cell_px_*`, and
  calls `window.setSize` to keep the same `grid_cols`x`grid_rows` — the
  inverse of `syncWindowSize`'s cell math, so it round-trips with no
  `reportResize`. Clamp (8..72) and 2px step live in the host, not the
  engine, which applies whatever size it is handed. Known gaps: a
  connected client isn't notified of a cell-metric change (only new
  `get_cell_metrics` queries see it), and a tiling WM that pins the
  window makes the grid reflow instead of the window resizing.
- **v1 built — caret shape + blink (host-local):** `host.conf`'s
  `config` table also carries `cursor_shape` (`line` \| `block` \| `box` \|
  `underline`; default `line`, the original left-edge bar), `cursor_blink`
  (default true), and `cursor_blink_ms` (half-period, default 530, clamped
  100..5000). Kept host-local for the same reason as the font: the caret is
  a property of the rendering front end, not the shared grid model, and no
  wire message reports or sets it. The blink phase resets to solid whenever
  the grid cursor moves or `view_scroll` changes, so the caret is solid
  the instant the user does anything and only blinks once things settle
  (`App.tickBlink`). block/box/underline span both cells when the caret
  sits on a `wide_lead`.
- **v1 built — initial grid size + scrollback config (host-local):**
  `host.conf`'s `config` table also carries `grid_cols` (default
  120), `grid_rows` (default 50) and `scrollback_rows` (default 1000, the
  root layer's history-ring depth passed to `Context.init`). `grid_cols` /
  `grid_rows` are clamped up to `min_grid_*` (16 / 4); `scrollback_rows` is
  clamped down to 100000. Host-local for the same reason as the font and
  caret: the window's opening size and how much scrollback the host keeps
  are properties of the rendering front end, and the shell already reports
  its own view of the grid over the wire (`get_property("size")`, the
  `resize` notification) once it changes. The existing `--grid-cols` /
  `--grid-rows` flags still win over the file — `loadConfig` runs before
  the arg loop and seeds the same `grid_cols` / `grid_rows` the flags then
  overwrite. `scrollback_rows` has no flag.
- **Fixed — caret drawn while scrolled back, then pinned on mouse scroll
  (host-local):** the caret used to be suppressed whenever
  `view_scroll != 0`, which hid it during glyphwire-shell's keyboard
  browse (Up-arrow past the top of the window) and made a scrolled-back
  `ls` listing un-navigable by keyboard. It is now drawn at its grid cell
  regardless of the scroll offset — keyboard browse moves that same grid
  cursor onto the visible scrolled-back row, so the caret follows. A
  *mouse* scroll (wheel or scrollbar) is different: it doesn't move the
  grid cursor, so instead of leaving the caret glued to the live prompt's
  screen cell, the host now **pins** it (`App.caret_pin`) to the buffer
  cell it was on when the scroll began. It rides the content up/down as
  the view scrolls and clips off-screen once that cell leaves the
  viewport — "the caret stays where it is in the layer". The pin is
  captured in `handleScroll`/`handleScrollbar` (client `scroll_view`
  scrolls — i.e. shell keyboard browse — never set it), and released
  either by any forwarded key/text event (which also snaps the view back
  to the live tail, so a keypress brings the cursor back into view) or by
  the client itself moving the cursor / scrolling back to the pin point
  (`reconcileCaretPin`, no view change — the client is driving).
- **Typematic key repeat extended (host-local):** the engine's
  `Keyboard` only edge-detects, so `glyphwire-host` already synthesized held-key
  repeat for the four arrows (`App.key_repeat`, `Server.reportKeyRepeat`
  → another `key_down`). That set now also covers **Backspace**,
  **Delete** and **Ctrl+U** — the editing keys glyphwire-shell's line
  editor acts on that ride the key stream rather than the `text` stream
  (where character-key repeats already arrive as fresh text events).
  Ctrl+left/right word motion already repeated through the arrow path;
  Enter and Tab stay single-shot. No wire change — a repeat is just an
  extra `key_down`, same as before.

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
- **Four container formats: PNG, JPEG, BMP, GIF.** Superseded the original
  "assume PNG" scope. `load_image`'s `format` field is now *parsed* (it
  used to be sent-but-unchecked) and selects which fixed-offset header
  parser measures the image — `core.imageDimensions` dispatches to
  `pngDimensions` (IHDR) / `jpegDimensions` (first SOFn segment) /
  `bmpDimensions` (DIB header) / `gifDimensions` (logical screen
  descriptor). Each is a header read of a few dozen lines, **not** a
  decoder — the headless core still never touches pixels, and no image
  codec dependency was added to it. An unknown `format`, or bytes that
  don't match the one declared, fails the `load_image` request (same
  connection-severing path a malformed PNG already took). The renderer
  side needed nothing: glyphwire-host's stb_image already auto-detects all
  four from the same bytes. **The client picks `format` by sniffing the
  file's own magic bytes** (`core.detectImageFormat`), not its extension —
  a wrong hint would fail server-side, and a headless `glyphwire-view foo`
  with no extension still works.
- `draw_image(layer, handle, row, col, row_span, col_span)` places the
  image at its natural pixel size, anchored at the span's top-left cell —
  **no stretching**. If the image is larger than the span's pixel bounds,
  it's clipped; if smaller, only the cells actually covered by image
  pixels are marked as image-backed. Superseded from an earlier "naive
  fit, stretch to fill" decision — stretching reads badly for the actual
  v1 use cases (viewing an image, TUI background art), and isn't worth
  keeping as the default just to avoid clipping. Stretching (aspect *not*
  preserved) may still return as an opt-in mode later; not needed now.
- **`draw_image` takes an optional `scale` (default `1.0`) — a uniform,
  aspect-preserving shrink, distinct from the stretch-to-fill idea
  above.** `glyphwire-view` now fits an image to the width of the layer
  it lands on by default: it reads the layer's cell width
  (`get_property("size")`), turns it into a pixel width via the fixed cell
  metrics, and sends `scale = target_width_px / image_width_px` (never
  `> 1` — an image already no wider than the layer is left at natural
  size), still computing `row_span`/`col_span` itself from the scaled
  dimensions. `--size full` sends no scale and keeps the natural-size
  placement. The wire carries the resolved factor, not a "fit" *intent*,
  so it does not reflow on a later window resize — the client would have
  to redraw; a server-tracked fit intent is a possible later refinement,
  not built now. It stays consistent with "aspect-ratio-aware placement is
  the client's job" (next bullet): the client still owns the span math,
  `scale` just lets the render stage shrink what would otherwise be
  clipped.
- Per-cell storage stays a resource reference, not a stored sub-image: a
  cell within the span holds `{handle, offset, scale}` (the *source*-pixel
  offset into the image that cell should display, plus the draw's scale
  factor), computed from the cell's position relative to the draw call's
  anchor. At `scale < 1` a cell's offset steps by `cell_px / scale` source
  pixels instead of `cell_px`, since the fixed cell grid has to span a
  rendered image that's now smaller; the host resolves `handle + offset`
  against the actual texture at render time and draws that slice back down
  at `scale` — no per-cell tile is ever extracted or cached as its own
  resource.
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
  rather than an accident. The same treatment capped to *one*
  cell-height (no overflow — it just fills the entry's own line) is what
  `glyphwire-ls`'s small (`-S`) listings — both the plain grid and the
  `-l` table's default-height rows — and the shell prompt's `{icon:...}`
  now draw instead of `"fit"`; a one-cell `"fit"` is only the fallback
  when `get_cell_metrics` is unavailable.
- **v1 built:** a single flat, global catalog (`Context.registerIcon`/
  `iconHandle`), seeded at `glyphwire-host` startup by a **recursive scan
  of `assets/icons/`** (`host/main.zig`'s `loadIconsFromDir`). An icon's
  catalog name is its path under that directory with the `.png` extension
  removed (`core.iconName`) — so the bundled subtrees give
  `oxygen/folder`, `dev/zig`, `distro/arch`, `notify/info`,
  `status/error`, `box/tl`, `dialog/fill`. There is no hand-maintained manifest any more
  (the old `core.default_*_manifest` arrays are gone): the file layout
  under `assets/icons/` *is* the manifest, and dropping a `.png` into a
  subdirectory adds an icon. `glyphwire-host` then scans a second,
  optional tree — `~/.config/glyphwire/icons/` (the same config dir as
  `host.conf`, `configDirPath`) — the same way; because `registerIcon`
  overwrites by name, a user file at a bundled relative path
  (`icons/file/folder.png`) replaces that bundled icon and a new
  relative path just adds one. A missing user directory is silent.
- **The coarse file-type buckets are a *selectable theme*, named
  `file/*`.** The folder / file / mimetype icons `glyphwire-ls` falls
  back to (`file/folder`, `file/pdf`, `file/image`, … — ~20 canonical
  names in `ls/icons.zig`) don't live at a fixed path any more. Each
  bundled set is a flat directory under `assets/icons/filetype/<theme>/`
  — `oxygen` (the default, KDE Oxygen, LGPL-3.0), `material` (VS Code
  Material Icon Theme, MIT), `papirus` (GPL-3.0, fetched by
  `scripts/fetch-icon-themes.sh`) — and `host.conf`'s `icon_theme` picks
  one. The generic `assets/icons/` walk skips `filetype/` entirely;
  `host/main.zig`'s `loadFiletypeTheme` then loads just the chosen set,
  registering each icon under the canonical `file/<name>` **and** the
  back-compat alias `oxygen/<name>` (so existing configs / demos that
  still say `oxygen/folder` keep resolving). An unknown or empty theme
  warns and falls back to `oxygen`. Everything else (`dev/`, `distro/`,
  `box/`, `dialog/`, `status/`, `notify/`) is theme-independent and loads
  as before. Oxygen was chosen as the default over a flatter set
  specifically to show off real multi-tone artwork in a cell, not just a
  monochrome glyph; it's now bundled at Oxygen's native **48x48** (via
  `scripts/fetch-oxygen.sh`, from the pasnox mirror that dereferences
  KDE's symlinks) so every set matches the 48px `dev/*` logos and
  scale-to-fit does the rest.
- **`dev/` and `distro/` are the Devicon set.** For a recognised source
  file or project directory, `glyphwire-ls` prefers a real
  language/tool logo — `dev/zig`, `dev/elixir`, `dev/go`, `dev/vscode`,
  `dev/git` (a `.vscode` / `.claude` / `.git` directory picks up the
  matching one) — over the coarse `file/*` bucket. Those, and the
  `distro/*` prompt logos, are the [Devicon](https://github.com/devicons/devicon)
  set ("-original" brand-coloured variants), rasterized from SVG to 48x48
  RGBA PNG by `scripts/fetch-devicons.sh` (MIT, see
  `assets/icons/dev/README.txt`). `dev/claude` and `dev/claudecode` are
  not in Devicon and come from [LobeHub's icons](https://github.com/lobehub/lobe-icons)
  instead. A few Devicon "-original" logos are a solid near-black glyph
  (rust, deno, github, markdown, latex, crystal); since `glyphwire-ls`
  draws on a near-black row background, that script repaints their opaque
  pixels light (alpha preserved).
- **Packed into one atlas texture at host startup.** After the scan,
  `glyphwire-host` decodes every registered icon and shelf-packs them
  (1px transparent gutter, NEAREST filtering) into a single
  `glyphwire-icon-atlas` texture; `App.icon_uv` maps each icon's image
  handle to its normalized sub-rect. Every icon draw — a `draw_box`
  border, an `ls` icon grid, a powerline prompt — then samples that one
  texture instead of rebinding the GL texture per icon (the sprite
  batch flushes on a texture change, so a screen of distinct icon
  textures was a flush per icon). `load_image` user images
  (`glyphwire-view`) are *not* in the atlas — they keep their own
  per-handle textures. A decode/pack failure is non-fatal: `icon_atlas`
  stays null and each `draw_icon` falls back to a lazily-uploaded
  per-handle texture. This is also the groundwork for a future
  StaticBatch host render path (roadmap.md) — one bound texture is what
  lets the whole grid's icons live in a batch that's only rebuilt on a
  content change.
- **`status/` folder for prompt status glyphs.** `status/error` (a red
  cross) and `status/slow` (a stopwatch), from `assets/icons/status/`,
  are meant for `{icon:status/error}` in a `when = "error"` powerline
  segment and `{icon:status/slow}` in a `when = "slow"` one (see the
  Shell section). Kept in their own folder, apart from `notify/` (whose
  icons carry dialog-background styling for `glyphwire-notify`) — the
  path prefix keeps a bare `error` free for some future unrelated icon,
  the same job the old `status-`/`notify-` name prefixes did.
- **Icon render size is `ls.conf`-configurable, capped consistently.**
  `glyphwire-ls`'s `writeGrid` and `writeLongTable` used to hardcode the
  `.natural` cap (one/two cell-heights, then a fixed 32px). Now
  `~/.config/glyphwire/ls.conf` (`ls/config.zig`, a Lua `config` table
  like `host.conf`) sets `large_icon_px` (default 32, for `-L`) and
  `small_icon_px` (default 16); the grid band / table row height follows
  (`ceil(px / cell_h)`), and the `-l` table passes the size through as
  `TableStyle.max_icon_px` so `core.Table.writeBodyRow` caps a tall row's
  icon the same way the grid does — a 48px `dev/*` logo then renders the
  same on-screen size as a `file/*` bucket icon everywhere. `ls.conf` is
  Lua (not a flat key=value file) so a future `colors = { … }` override
  table fits without a format change. `ls` links the vendored Lua lib for
  this, same as `glyphwire-shell` does for `shell.conf`.
- **Partly built — theming.** The file-type slice is done (`file/*` +
  `host.conf` `icon_theme`, above). Still open: a fully context-local
  catalog (a per-`Context` override so one connection can theme
  independently of another, live) and a way to query the catalog's
  contents over the wire (a client currently just has to know the names,
  i.e. the `assets/icons/` tree).
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
  the engine's `Renderer` buffers each frame's draw calls into per-kind
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
- **Draws top-down and scrolls the layer as it goes, exactly like
  ordinary terminal output, but writes cells directly rather than through
  the cursor-based helpers.** First tried "clip instead of scroll," on the
  reasoning that a table pinned at a fixed anchor is like
  `draw_box`/`draw_image`, which clamp their own rectangles to the layer's
  bounds rather than triggering a scroll — wrong in practice: a table is
  usually a *command's output* (`glyphwire-ls -l`, printed wherever the
  shell's prompt happened to leave the cursor), and most of it silently
  never becoming visible reads as "the table doesn't render." `Table.render`
  now walks its pieces from `self.row` downward and, before each one,
  scrolls the layer just enough for that piece to clear the bottom edge
  (`tableMakeRoom`) — the same "make room for the next line" a terminal
  does. A table taller than the window scrolls its header and earliest
  rows up into scrollback, intact (they were drawn before the scroll), the
  live tail filling the viewport, no blank filler anywhere. The scroll is
  resolved once per *piece*, never per cell: a per-cell resolution scrolls
  relative to whatever's on top every call, which is the compounding-scroll
  bug the `row_height > 1` client-composited prototype hit first. Total
  scrolling is capped at the layer's capacity, so a table longer than
  viewport + scrollback drops its newest rows rather than spinning. Every
  cell write still goes through `layer.cell(r, c)` directly, and
  horizontal overflow still just clips (no horizontal-scroll concept for a
  cell grid). `table_get_state`'s `painted` extent is the on-screen
  footprint after the scrolling (`row` 0 once the top scrolled into
  history), which fills the viewport for an oversized table — so
  `glyphwire-ls`'s `writeLongTable`, seeing no spare row below the table,
  lands the cursor on the last line and emits one newline for the
  blank-line gap before the next prompt, matching the fits-in-window case.
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
- **`glyphwire-ls -l` mirrors exa's column layout with lsd-style
  coloring, and stretches the last column to fill the layer.** Column
  order is the permission bits, Size, User, Group, Time, then icon +
  Name — name last, exa-style, not first. There's no flex/stretch
  concept in the `create_table` wire shape (fixed `width` per column,
  horizontal overflow just clips), so the client stretches Name itself:
  it reads `get_property("size")` for the layer width and sizes Name to
  whatever's left after the fixed columns and their separators, so
  `sum(widths) + (n-1)` lands exactly on the layer's right edge. Name is
  clamped up to a small floor (`min_name_width`, plus the large-mode icon
  reserve) when the layer is too narrow to spare it — the table then
  clips the longest names with `…`, like a terminal `ls` in a cramped
  window.
  - **The permission string is four separately-colored cells**, not one.
    A table cell carries a single foreground colour for its whole text
    (no per-character styling — see the "No icon-only column" bullet's
    sibling reasoning), so lsd's per-bit `r`/`w`/`x` colouring isn't
    possible in a single `-rwxr-xr-x` cell. Instead: a 1-wide type-char
    cell (hued like the entry's own name) then three 3-wide `rwx` triad
    cells, each coloured as a unit by how much access it grants
    (green / gold / red / dim). The table forces a 1-col gap between
    cells, so this renders as `d rwx r-x r-x`. The individual bits inside
    a triad still share one colour — a limitation, but most of lsd's
    signal survives.
  - **User and Group are separate name columns**, each sized to the
    widest name the listing holds (clamped 5..16). User is a brighter
    pale yellow, Group a dimmer wash of it — lsd distinguishes them with
    bold, which a cell can't do. Time is a muted steel blue. Palette is
    VSCode Dark+ tokens, to sit with the existing name colours. The plain
    stdout fallback keeps a single uncoloured `owner:group` field.
  - **uid/gid** come from a raw `statx(2)` — Zig's reduced std dropped
    the libc-independent Linux `stat` wrappers and `std.Io.File.Stat`
    omits uid/gid — resolved to names via libc `getpwuid`/`getgrgid`
    (`glyphwire-ls` already links libc), decimal-id fallback when a
    lookup misses. The earlier "no owner/group, would need libc" note is
    superseded.
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
  scrolling bug noted above. A row's icon is drawn `.natural`-scaled and
  capped to `row_height` cell-heights tall, sized from the icon's
  *actual* loaded pixel width (`Context.imageInfo`) rather than a
  hardcoded constant the prototype used.
- **A `row_height == 1` icon fills its line too, it isn't shrunk to
  `.fit` one cell.** At a real session's cell size a `.fit`-scaled 32×32
  icon comes out a few pixels tall — unreadable. So the default-height
  row uses the same rendering the taller rows do: `.natural`, left-
  aligned, capped to one cell-height (`1 × cell_px_h`), so it fills the
  row's single line without spilling onto its neighbours, and reserves
  the leading columns its rendered width needs (~2) before the text.
  This is the same "fill the line" treatment `glyphwire-ls`'s small
  (`-S`) grid listing and the shell prompt's `{icon:...}` already use.
  The old one-cell `.fit` stays only as the fallback when the session's
  cell pixel metrics are unavailable (`Context.cell_px_w`/`_h` zeroed).
- **Header-click sorting: glyphwire-host drives it directly, no wire
  round trip, no running client.** The original plan here was to leave
  sort-on-click to a client subscribing to `mouse_button` and resolving
  the cell via `get_metadata`, the way `glyphwire-shell`'s
  `activateSelectionAt` works. That doesn't fit the actual use: the table
  the user wants to sort was drawn by `glyphwire-ls -l`, which has
  already exited — there is no client. A table is real server-side state
  (`core.Table`), so the host does the whole thing itself:
  `host/table_sort.zig` hit-tests the click against each table's header
  row (`Table.headerColumnAt`, which lays columns out through the same
  `headerColWidth` the renderer uses), and on a `sortable` column runs
  `Table.cycleSortOnColumn` + `Table.repaint` under `ctx_mutex`. The click
  is consumed so glyphwire-shell doesn't also get it as a grid click.
  This is a deliberate departure from "the server never hit-tests" — the
  server core still doesn't; the host does, and the host is in-process
  with the server anyway (it already reads `core` state directly every
  frame to render). Scope of the first cut (asked): tables on the
  visible context's **root layer**. A checkbox-style toggle for
  `alt_row_bg` etc. is still just a `table_set_style` a future client
  would call.
- **The hit-test survives scrolling: `Table.top_live` is content-pinned,
  like a selection.** The header click arrives as a *screen* row, but the
  table was drawn wherever the shell's cursor happened to be and output
  has scrolled it since. `Table.top_live` (logical row 0's position in
  live-viewport coordinates, negative once the header is in scrollback)
  is set by `render` and then decremented by `Layer.scrollOne` for every
  table on the layer — exactly the content-pinning `scrollOne` already
  does for `Layer.selection`. `headerColumnAt` adds the layer's
  `view_scroll` back in, so a click resolves whether output pushed the
  table up or the user scrolled the view back to reach the header. The
  earlier cut keyed off a stale `Table.row` and both mis-fired (a body
  row of a scrolled table read as the header) and, via a re-`render`,
  scrolled the layer a second time until only the table's last rows were
  left — the bug that motivated all of this.
- **A re-sort `repaint`s in place; it does not re-`render`.** `render`
  draws the table fresh at the cursor and scrolls the layer
  terminal-style as it overflows — correct exactly once, when the table
  is first emitted as command output. A re-sort keeps the same rows and
  the same footprint, so `Table.repaint` redraws that footprint at the
  table's current `top_live`, clipping to the viewport instead of
  scrolling. Consequence for a table taller than the viewport: the
  on-screen part re-sorts, rows already in scrollback keep their prior
  order (the ring's history isn't rewritable) — including a header
  scrolled off, so its arrow only shows once the table is fully back on
  screen. Acceptable: the common case (a listing that fits) is exact,
  and the alternative (rewriting history rows) is a much bigger change to
  the ring's API for a corner case.
- **The 3-state click cycle, and the arrow expands the column rather than
  clipping the name (asked).** A click steps ascending → descending →
  unsorted (back to insertion order); clicking a different sortable
  column jumps straight to it ascending. "Unsorted" stays reachable so a
  table with no default sort can be returned to its natural order. The
  active sort column's header draws its name plus a filled-triangle
  arrow (`"Name ▲"` / `"▼"`), and `Table.headerColWidth` widens that one
  column by `sort_arrow_cells` (2) so the arrow never eats into the name;
  body cells under it get the same extra width (trailing padding, or for
  an `.end`-aligned column the value stays flush under the arrow). A
  column that is merely `sortable` but not the current sort shows nothing
  extra — no persistent "click me" affordance (asked).
- **`glyphwire-ls -l` sets no default sort (asked, revised).** An earlier
  round of this feature had `-l` open sorted by Name ascending (so the
  Name header carried its arrow from the start). The user revised that:
  the listing opens in `sortEntries` order (which is by name anyway) with
  **no** arrow on any header until the user clicks one. So `-l` emits no
  `table_set_sort` — it just marks Size / User / Group / Time / Name
  `sortable` and gives the Name cells a `sort_key` of the bare filename
  (not the `"name -> target"` display text) so a click-sort on Name
  matches `sortEntries` exactly. The permission columns aren't sortable.
- **`table_get_state` reports structure, not rendered cells.** Row count,
  sort state, style, and revision — not the cells themselves, which are
  already readable through the owning layer's ordinary `get_cells` (a
  table paints into ordinary cells, per above). For a future client that
  needs to know e.g. which columns are sortable before deciding what a
  header click should do.

### Selection & clipboard
- **Selection is real server-side state on a `Layer`, not a client-side
  overlay.** `core.Layer.selection` (`?Selection`, two `SelectionPoint`
  ends) is set/moved/cleared over the wire (`set_selection` /
  `update_selection` / `clear_selection`), queried two ways
  (`get_selection` for the endpoints, `get_selection_text` for the
  extracted text), and read directly by glyphwire-host's renderer for the
  highlight. Same reasoning tables got promoted from a client prototype to
  `core.Table`: more than one participant needs it (the host renders it,
  the shell answers copy, a future client could drive it), and the
  extraction logic — trailing-blank trimming, wide-cell spacer skipping,
  scrollback row lookup — belongs next to the cell grid, not copied into
  each client.
- **Endpoints are content-anchored (`above` = rows above the live
  viewport top), not a `(view_offset, screen_row)` pair.** A screen
  position drifts the instant the view scrolls or output arrives; `above`
  doesn't, and `Layer.scrollOne` bumps both ends by one so a selection
  stays pinned to its text as fresh output pushes rows into scrollback.
  An end that scrolls off the top of retained history drops the whole
  selection (the text it referred to is gone); `resize` drops it too (the
  ring buffer is rebuilt). This mirrors glyphwire-host's existing
  `caret_pin` trick, lifted into the data model so every reader shares it.
- **Linear (stream) selection only, no rectangular mode.** Interior rows
  select their whole width; the first and last row clip to the start/end
  column. A rectangular/column mode would thread a flag through every
  selection message and double the extraction and render cases for a rare
  need — deferred.
- **`selection` broadcast, subscribe `"selection"`.** Every mutation fans
  out the new `SelectionState` to other subscribers, same poll-vs-
  subscribe split `scroll`/`resize` already have. glyphwire-host doesn't
  need it (it reads `layer.selection` straight out of the in-process
  `Context` each frame) but a separate renderer or a selection-aware
  client would.
- **The clipboard is one session buffer on `Context` (`clipboard` +
  `clipboard_serial`), mirrored to the OS by glyphwire-host.** The
  headless server (`server/main.zig`, tests) has nothing behind
  `set_clipboard` / `get_clipboard` but that buffer. glyphwire-host treats
  it as the source of truth: it pushes to the OS clipboard whenever
  `clipboard_serial` changes (a client's `set_clipboard`, or its own
  selection copy) and refreshes it from the OS on paste. SDL clipboard
  calls are main-thread-only, so the wire path can't touch the OS directly
  — going through the buffer + a once-per-frame `syncClipboardToOs` keeps
  every SDL call on the render thread. Consequence: a wire `get_clipboard`
  only sees OS-clipboard changes another app made once the host has synced
  (on its next copy/paste) — acceptable for the interplay this feature is
  about, not a general OS-clipboard mirror.
- **Ctrl+Shift+C with nothing selected → `copy_request`, and the shell
  answers with `set_clipboard`.** The host owns the selection and the
  clipboard but has no idea what "the current prompt" is — that's the
  shell's line buffer. So when the copy shortcut fires with no selection
  (or a zero-width one), the host broadcasts `copy_request` to
  `"clipboard"` subscribers; glyphwire-shell replies with `set_clipboard`
  carrying `prompt.buffer.items`. A real selection is copied entirely
  host-side with no round trip.
- **Paste is its own `paste` notification, not the `text` typing
  stream.** Distinct so a client can treat it differently — glyphwire-
  shell inserts pasted text into the live line *without* submitting (the
  user presses Enter themselves), where a multi-line `text` run would look
  like separate typed commands. Because the shell's line editor is
  single-line, it first flattens every run of `\n` / `\r` in the pasted
  text to one space (`lineedit.flattenNewlines`): a multi-select copy of
  file paths, or any block pasted from another window, then lands as one
  editable line of space-separated words instead of a buffer with embedded
  newlines the editor can't render. A proper multi-line editor is a
  future change; until then the word-splitter also treats `\n` / `\r` as
  ordinary token separators (same as space / tab) so a stray newline that
  still reaches `dispatchLine` splits arguments rather than fusing them
  into one. The pty-passthrough path keeps paste verbatim — a foregrounded
  program gets the newlines. Other clients that only care about typing can
  ignore `paste`. Both ride the `"clipboard"` subscription alongside
  `copy_request`.
- **Ctrl+Shift+Space toggles a keyboard selection mode in the host.**
  While active the host swallows the arrows / Home / End / Escape / Enter
  before `reportKeyEvents` forwards them and uses them to move the
  selection's active end (scrolling the view when it walks past an edge);
  a mouse drag supersedes it. Mouse drag-selection: the host holds the
  left button back from the shell for the duration of a drag and only
  forwards a synthetic press+release for a plain click (no movement), so
  glyphwire-shell's existing click-to-activate is untouched.
- **Highlights are a separate `Layer` concept from the selection, and are
  stored as metadata ids, not cell ranges** (`core.Layer.highlighted_ids`,
  toggled/replaced/cleared by `toggle_highlight` / `set_highlight` /
  `clear_highlight`, all requests answering with a `HighlightState`). The
  selection is one contiguous range in one slot and feeds the copy path;
  a highlight set is many entries, need not be contiguous, and the copy
  path ignores it — overloading `selection` for both would mean a mode
  flag on every selection message and a merged extraction. Keying on the
  metadata id rather than `{above, col, len}` means the renderer just
  tints any cell whose `metadata_id` is in the set: the highlight follows
  its content through scrollback with zero row math, survives a `resize`
  untouched, and an id whose cells are all evicted matches nothing (ids
  never repeat, so a stale entry is harmless) — no `scrollOne` pinning or
  `resize` clearing needed, unlike the selection. `toggle_highlight`
  takes a *cell* and the server resolves the id, so a client never reads
  the grid back to find "what's tagged here". The response bundles each
  id's stored JSON blob so a client can act on every entry without a
  `get_metadata` per id. Rendered by the host with the selection's
  translucent overlay; no broadcast/subscription (the only consumer is
  the in-process host renderer, and the sender gets the state in the
  reply). glyphwire-shell drives this for its `ls` multi-select marks —
  see the Shell section.

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
- **`glyphwire-ls` metadata carries `kind` + `path` (+ `mimetype` for a
  regular file), never a command.** The blob a listed entry's cells are
  tagged with is `{kind, path}` plus, for `kind == "file"`, a real
  extension-derived `mimetype` (`entryMetadataJson` in `ls/main.zig`).
  `kind` is one of `"file"` / `"directory"` / `"symlink"` / `"other"`; a
  directory or symlink gets no `mimetype`. Deciding what to *do* on
  activation is the reader's policy, not baked into the listing — so a
  user can teach the shell new types without `glyphwire-ls` changing.
- **The shell resolves activation through a `shell.conf` `open_actions`
  table over built-in defaults.** `shell/openaction.zig` maps a key —
  a mimetype (`image/png`), a mimetype group (`image/*`) or a `kind`
  keyword (`directory`) — to a command template, trying the three key
  forms most-specific-first (exact mimetype, then group, then kind).
  Within one form a user `open_actions` entry beats a default and a later
  user entry beats an earlier one; across forms specificity wins, so a
  broad user `image/*` still yields to the built-in `image/png`. The
  shipped defaults are just `cd {sel}` for a directory and
  `glyphwire-view {selections}` for the four image types the viewer
  actually decodes (PNG/JPEG/GIF/BMP). Nothing matches ⇒ nothing happens
  (the "don't guess" policy).
- **`{sel}` / `{selections}` are the template placeholders**, expanding to
  the shell-quoted path(s) (`wordsplit.quoteArg`, the inverse of the
  splitter — an embedded `'` becomes `'\''`) — the synthesized line goes
  back through the same `dispatchLine` split a typed line does, so without
  quoting a name with a space or metacharacter would tokenize wrong or
  inject. `{sel}` requires exactly one entry (a multi-select given a
  `{sel}`-only action surfaces an error and runs nothing); `{selections}`
  takes one or more, space-joined. A template with neither runs as-is.
- **Multi-select marks are a highlighted-metadata-id set the host owns,
  not something the shell computes.** Ctrl+click (or Space while browsing)
  sends `toggle_highlight(row, col, view_offset)`; the host resolves the
  cell to its `metadata_id`, flips it in `layer.highlighted_ids`, and
  answers with a `HighlightState` — every highlighted id plus its stored
  JSON blob. The shell rebuilds `Prompt.marks` (parsed `kind`/`path`/
  `mimetype`) from that response; it never scans the grid. A plain click /
  browse-Enter with marks runs the resolved action once over every marked
  path; Escape clears them; running any command drops them (a `resize`
  does *not* — the highlight is keyed by id, not rows). With marks
  present, `copy_request` (Ctrl+Shift+C, host selection empty) answers
  with the marked paths as one **space-separated** line instead of the
  input line — each path passed through `wordsplit.quoteArgIfNeeded`
  (bare when it's a plain word, single-quoted when it holds a space or a
  shell metacharacter), so the clipboard text pastes straight back after a
  command name as a valid argument list. (Newline-joining was the first
  cut; it broke the moment the list was pasted after `ls`.) The
  earlier design had the shell scan a `get_cells` snapshot for the run of
  cells sharing an entry's id — dropped because a client round-tripping
  the whole grid to re-derive what the host already knows is both slow
  (noticeably so) and the wrong shape. Highlights being a separate `Layer`
  concept from the selection is what lets a set of non-contiguous marks
  and the copy path not fight over the one `selection` slot — see the
  Selection & clipboard section.
- **`alias` / `unalias` are builtins.** The `alias` table is seeded at
  startup from `shell.conf` (see below) and then mutated for the rest of
  the session by the builtins; a binding made or removed with the builtin
  is not written back, so it doesn't survive `exit`. `alias NAME=VALUE`
  uses **rest-of-line value semantics**: everything after the first `=`
  is the body, with one
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

#### Pipelines, redirects, `&&` / `||` / `;`
- **A second parser layer above `wordsplit`.** `shell/parse.zig` takes
  the raw line and produces a small tree — `Line` → `Segment`s (linked by
  `&&` / `||` / `;`) → `Pipeline` (`|`-separated `Command`s) → `Command`
  (argv words + redirects). It reuses `wordsplit`'s quote/escape rules
  byte for byte; the only addition is that an *unquoted* operator lexeme
  ends the current word. Operators don't need surrounding whitespace
  (`ps aux|grep x`, `echo hi>out`, `a&&b`), and a lone digit immediately
  before `>` / `<` is the source-fd designator (`2>err`), both matching
  bash. The tree is arena-backed, so `line.deinit()` is one free; a
  syntax error comes back as a ready-to-print message, not a Zig error.
- **v1 operator set:** `|`, `<`, `>`, `>>`, `2>`, `2>>`, `1>`, `1>>`,
  `2>&1` / `1>&2`, `&>` / `&>>`, `&&`, `||`, `;` (trailing `;` allowed).
  Deliberately rejected with a message naming the construct: background
  `&` / job control, heredocs `<<`, here-strings `<<<`, `|&`, process
  substitution `<(...)`, subshells `( )` / groups `{ }`, arbitrary fd
  numbers (`3>&1`).
- **Two executors, split on shape.** A *bare* command — one stage, no
  redirects — keeps the original `runCommand` path: a real PTY
  (`pty.zig`), so `vim` / `less` / `htop` stay interactive, the glyphwire
  handshake still works, and `{dur}` timing is unchanged. Anything with a
  `|`, a redirect, or `&&` / `||` / `;` goes through `pipeexec.zig`:
  ordinary `pipe(2)`s between stages, one process group, stdout of the
  last stage + a shared stderr pipe drained onto the grid, stage 0's
  stdin fed from forwarded keystrokes (Ctrl-C → group SIGINT, Ctrl-D
  closes it). Piped stages see `!isatty()` and lose auto-colour, exactly
  as in bash. A pipeline stage does **not** get handshake detection — a
  glyphwire-aware program only draws its own output when run bare.
- **Builtins run as a whole `&&` / `||` / `;` link but not as a `|`
  stage.** `cd /tmp && ls` works; `history | grep foo` is an error
  (`<name>: not supported inside a pipeline`). Keeping the pipe executor
  to just external processes is the simplification; a builtin needs its
  output on the grid, which a mid-pipeline stage can't have.
- **Exit status = last stage's status** (no `pipefail`); `&&` / `||`
  short-circuit on it and it feeds `{exit}` / `{dur}` for the whole line.
  A redirect target gets `~` expansion and a single glob match; a
  multi-match glob target is an "ambiguous redirect" error, matching
  bash. Redirects on a builtin are parsed but not applied. A `2>&1` and
  a `>` are evaluated left to right (`> out 2>&1` differs from
  `2>&1 > out`), like bash.
- **Alias bodies stay word-lists.** A `|` inside an alias value is passed
  through literally (it was already, pre-pipelines) rather than
  re-parsed as a pipeline — noted as a known limitation, not a goal.

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
  `$PATH` is still out of scope (a `$PATH` scan on every Tab), and so are
  richer, config-driven completions (the planned Lua config is the
  natural home for those).
- **Command position also completes names, not just files.** When the
  word under the cursor is `argv[0]` (the first token on the line, no
  `dir/` part), Tab merges three more name sources into the candidate
  list: the live `alias` bindings, the core builtins
  (`core_builtin_names` -- `alias`/`cd`/`exit`/`unalias`), and the script
  builtins (`ScriptEngine.collectCommandNames` -- every `defcmd`
  registration plus each `~/.config/glyphwire/scripts/*.lua` basename,
  `lib/` excluded). They are plain candidates: sorted in with the
  filesystem matches, no marker, deduped by name so a script and a
  like-named file in the cwd list once. Argument positions are unchanged
  (filenames only). `collectCommandNames` may hand back the same name
  twice (a `defcmd` that also has a file); `appendCommandNameCandidates`
  dedups.
- Split for testability: `shell/complete.zig` holds the pure helpers
  (word boundary, `dir/`+prefix split, longest common prefix);
  `ScriptEngine.collectCommandNames` is unit-tested against a real Lua
  state and a temp scripts dir; the directory scan and the grid edits
  stay in `Prompt.doComplete` / `appendCommandNameCandidates` /
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

#### Startup config: `~/.config/glyphwire/shell.conf`
- **The config is a Lua script**, run once at prompt startup. The Lua
  library is vendored in-tree (`libs/ziglua`, Lua 5.3) so
  glyphwire-shell can embed an interpreter without depending on the
  engine (SDL3/OpenGL) — only `glyphwire-host` links `host_eng`.
- **Directory:** `$GLYPHWIRE_CONFIG_DIR` verbatim when set, else
  `$XDG_CONFIG_HOME/glyphwire`, else `$HOME/.config/glyphwire`. A missing
  file is not an error — the shell just starts with nothing configured.
  `$GLYPHWIRE_CONFIG_DIR` is the override the e2e tests use so driving
  the real shell binary can't read a developer's actual `shell.conf`.
- **The conf declares data, it doesn't touch the live prompt.** Running
  it produces a `config.ShellConfig` struct (`shell/config.zig`); the Lua
  bindings append into that, and `Prompt.loadStartupConfig` folds the
  result into the prompt afterwards. This keeps the apply step in one
  place and makes the parser unit-testable without a running shell. New
  bindings add a field to `ShellConfig` and a collector in `config.load`.
- **First binding: `alias(name, value)`.** Both arguments are strings
  (numbers coerce, like stock Lua; other types raise). Each call is
  appended to `ShellConfig.aliases` in order; `loadStartupConfig` replays
  them into the same `AliasTable` the `alias` builtin uses, so a repeated
  name is last-write-wins and a conf alias can later be overridden or
  `unalias`ed in the session. The standard Lua libraries are open, so a
  conf can use loops / `..` / `pairs` to build its alias list.
- **Errors don't abort startup.** A Lua syntax or runtime error is
  written to the grid in red; whatever the interpreter accepted before
  the failing line is still applied (Lua stops at the error point).

#### Prompt templating: `prompt{ ... }`
- **`shell.conf` can define the prompt as a template string** —
  `prompt{ left = ..., right = ..., exit = ..., dur = ..., dur_min_ms =
  N }`, one table argument, every key optional, multiple calls merging key
  by key (last write wins). String keys must be strings (a number
  coerces, like `alias`); `dur_min_ms` must be a non-negative number. The
  parser is `shell/config.zig`'s `luaPrompt` collecting into
  `config.PromptConfig`; `Prompt.loadStartupConfig` copies the result onto
  the prompt. Unset everywhere → the built-in `<cwd> > ` prompt is
  unchanged (`writeDefaultPrefix`). This was chosen over an env var
  (`$GLYPHWIRE_PROMPT_*`) because the shell already has exactly one config
  surface and a second one to keep in sync isn't worth it.
- **The template engine (`shell/prompt_template.zig`) is pure** — no libc,
  no IO, no glyphwire import; it turns a template plus a `Data` snapshot
  into an ordered op list (`text` run / `icon` placement), unit-tested in
  `tests/prompt_template_tests.zig`. `Prompt.emitOps` walks that list,
  `write_text`ing text and `draw_icon`ing icons; since `draw_icon` doesn't
  move the server cursor it advances one column by hand after each icon,
  and re-reads the cursor after each text run so an embedded `\n` (server
  CR+LF) is handled without local bookkeeping.
- **Token syntax:** `{name}` interpolates; `{{` / `}}` are literal braces;
  `\n` `\t` `\\` are unescaped; an unrecognized `{name}` is left
  **verbatim** so a typo shows rather than vanishing. Fields: `{cwd}`
  (working dir, `$HOME` collapsed to `~`), `{cwd_full}` (absolute),
  `{user}` (`$USER`), `{host}` (from `$HOSTNAME` / `/etc/hostname`,
  resolved once per session), `{time}` (local time via a libc `strftime`
  in `shell/main.zig`, format from `time_format`), `{env:NAME}` (an
  environment variable), `{icon:NAME}` (a bundled icon by catalog name —
  its path under `assets/icons/` minus the `.png`, e.g. `distro/arch`).
- **A prompt `{icon:...}` is drawn at natural size, not fit-in-one-cell.**
  `Prompt.resolveIconMetrics` reads `get_cell_metrics` once and draws the
  icon `scale: natural`, `v_align: center`, capped to **one cell-height**
  (`max_h`) so it fills the prompt row without spilling onto the row above
  or below, and reserves `ceil(cell_h / cell_w)` columns for it (~2 for a
  square icon in a roughly 1:2 cell). `fit` — the default `draw_icon`
  behavior — letterboxes a square icon into a tall-narrow cell with
  visible vertical padding, which read as wrong in a prompt. If
  `get_cell_metrics` is unavailable the old one-cell `fit` is kept.
  `prompt_template.opsWidth` takes the column count as a parameter so the
  layout math (segment widths, right-alignment) matches what's drawn. The
  same one-cell-height `natural` rendering is what `glyphwire-ls`'s small
  (`-S`) listings and the `-l` table's default-height rows draw their
  per-entry icons with — see the Icon section's `max_w`/`max_h` bullet.
- **`{exit}` and `{dur}` are conditional sections, not raw values** — the
  request's "show an error code / an icon only on a non-zero exit" and
  "don't show a duration under 2–3s". `{exit}` expands to the `exit`
  sub-template, but only when the last **external** command exited
  non-zero (empty on success, and before any command has run). `{dur}`
  expands to the `dur` sub-template, but only when the last external
  command's wall time was `>= dur_min_ms` (default 2000). Inside those
  sub-templates, `{exit_code}` is the numeric status and `{duration}` is
  the humanized time (`450ms` / `1.5s` / `2m5s` / `1h1m`); an `exit`
  section can also carry an `{icon:...}`. A section that references its
  own trigger token is stopped by a depth guard (`max_depth = 4`).
- **Only `runCommand` updates the exit/duration state** (`Prompt`'s
  `last_status` / `last_dur_ms` / `have_status`, and `Pty.exit_code`,
  decoded from `waitpid` in `src/pty.zig`). The `cd` / `alias` /
  `unalias` builtins leave it as the last real program's — the tokens are
  about "the last program", and a builtin has no meaningful exit code
  here. The monotonic timing uses `std.Io.Clock` (`.awake`); this reduced
  std has no `std.time.Timer`.
- **Plain form — `prompt.right` is drawn first, right-aligned on the
  prompt row, then `prompt.left` from column 0.** Single-line; a long
  input line overwrites the right side (accepted, like starship's
  transient right prompt). Skipped if its width doesn't fit the grid.

##### Powerline segments (`left_segments` / `right_segments`)
- **A structured list beat inline `{seg:fg,bg}` tokens** — per-segment
  attributes and `when`-conditions read badly stuffed into one string,
  and the list form matches how starship/powerline configs actually look.
  Each entry is `{ text (or [1]), fg = "#rgb", bg = "#rgb", when }`;
  `text` is itself a template, so every token above works inside a
  segment. `when` is `always` (default) / `error` (non-zero exit) /
  `slow` (last command `>= dur_min_ms`); a segment whose text renders
  empty is dropped, and no separator is drawn for a dropped segment. Two
  bundled icons pair with those conditions: `{icon:status/error}` (a red
  cross) for a `when = "error"` segment and `{icon:status/slow}` (a
  stopwatch) for a `when = "slow"` one — see the Icon section's
  `status/` folder note.
- **No new wire op — it's coloured cells + a Nerd Font glyph.** The
  "lighter alternative to background tiles": `drawChain` lays each
  segment's background as a run of spaces (`write_text` with `bg`), then
  composites the text over it with `write_text` transparent (fg only, so
  the strip shows through) and icons via `draw_icon foreground` (into
  `Cell.fg_icon`). Separators are one `write_text` of `sep` with
  `fg = left segment bg`, `bg = right segment bg` — the standard powerline
  trick; right-side chains swap fg/bg so a left-pointing glyph reads
  right. `head` / `tail` / `right_head` caps are drawn in the adjacent
  segment's bg over the terminal background — for the right chain that's
  the *first visible* segment's bg, so the cap picks up an `error`
  segment's colour when one is showing and the time's colour otherwise.
  **`right_head` falls back to `head` when unset**, mirroring
  `sep_right` → `sep`, so one `head = "\u{E0B6}"` caps both chains.
- **The glyphs come from a bundled fallback face.** No single font has
  both full CJK (the host primary) and the Powerline Extra range, so
  `assets/PowerlineSymbols-subset.ttf` (a ~20 KB `pyftsubset` of a Nerd
  Font to U+E0A0–E0D7) is registered as an *additional* host fallback
  after the configured one — the atlas fallback chain already handles
  "codepoint the primary lacks". Plain JetBrains Mono already covers the
  basic arrows (U+E0A0–E0B3); the subset adds the rounded/angled caps.
- **`lines >= 2` puts the segments on the first row and the input line
  (prefixed with `input`, default `"> "`) on the last** — which is how a
  right-side clock stays put: it's on a row the line editor never
  touches. On a single-line prompt the right chain is instead redrawn
  after every keystroke (and on the idle timeout, so `{time}` ticks),
  and the input box's right edge (`input_max_col`) is clamped short of
  it.
- **The right-chain redraw goes out as one `batch` frame** (`drawRightChain`
  → `drawChain` with a `ChainSink` pointing at a `Client.Batch`, plus a
  trailing `set_property(cursor)` back to the input caret). Previously
  each `set_property`/`write_text` was its own frame, so the host could
  render a frame with the caret parked out on the right where the chain
  draws before it was moved back — a visible "cursor blip to the right"
  every idle tick on a 2-line prompt. Batching makes the whole redraw
  plus caret restore land in a single render. The batched path in
  `emitOps` advances the column by `displayWidth` instead of a
  `get_cursor` round trip (segment text has no `\n`), consistent with the
  `opsWidth` layout math.
- **The line editor moved to a repaint model.** It used to shift cells
  with `insert_cells` / `delete_cells` (ECMA-48 ICH/DCH); now every edit
  mutates the local `buffer` and calls `renderInputLine`, which repaints
  the whole box `[line_start_col, input_max_col)` from a
  horizontally-scrolled (`input_scroll`) window of the buffer and places
  the cursor. This is what lets the editor respect a right-side prompt's
  bounds and scroll a long line inside its zone instead of wrapping.
  `submitLine` re-echoes the full command unbounded (past the box / right
  prompt, wrapping) before running it, so scrollback shows all of it.
  The `insert_cells` / `delete_cells` wire ops are now unused by the
  shell but stay in the protocol.
- **`renderInputLine`'s box repaint + caret placement go out as one
  `batch` frame** (`setCursor` to the left edge, `write_text` the row,
  `setCursor` back to the caret). Otherwise the host renders an
  in-between frame with the caret parked at the box's left edge — a
  visible caret "jump" on a history recall / line swap. Same trick the
  right chain (`drawRightChain`) already uses; the dynamic right chain
  stays its own trailing batch. The batch-appending half is split into
  `appendInputLine(*Client.Batch)` so `handleResize` can fold it into
  the same frame as its clear + prefix redraw.
- **The whole prompt prefix draws as one `batch` frame.**
  `writePromptPrefix` and its three writers (`writeDefaultPrefix`,
  `writeTemplatedPrefix`, `writePowerlinePrefix`) used to emit each
  `set_property` / `write_text` / `draw_icon` straight to the client, so
  a powerline prompt visibly built up segment by segment. Now each writer
  routes every draw through a `Client.Batch` — its own (sent before it
  returns) when `sink` is null, or the caller's when passed one — so the
  prompt appears all at once. One `get_cursor` up front still locates
  where the last command's output ended; the post-draw cursor is then
  computed locally (`cursorAfter`, wrapping at `grid_cols`) rather than
  read back, since the not-yet-sent batch wouldn't be reflected in a
  `get_cursor` reply. The templated/powerline right chains already
  assumed no `\n` in segment/template text (the `emitOps` batched path),
  and that assumption now covers the left side too.
- **A resize clears the full width of every prompt row before redrawing,
  in the same frame.** `handleResize` opens one `Client.Batch`, appends a
  `clear(top, 0, prompt_lines, null)` (full width, `prompt_lines` is
  config-derived so it still describes the pre-resize prompt), then the
  prefix redraw and the input-box repaint, and sends once. Growing the
  window widens the grid and moves the right chain's target column
  rightward, leaving the previously-drawn right chain stranded in the
  middle where nothing redraws over it; a shrink can likewise leave a
  stale segment row above the new input line. Clearing the prompt's row
  span — and only that span, so reflowed command output above it is
  untouched — wipes both.
- **glyphwire-host no longer caret-previews vertical arrows.** The host
  nudges `ctx.root.cursor` on a held arrow key to hide round-trip
  latency, but Up/Down at the prompt now mean history recall / break
  into scrollback, not "move the raw cursor a row" — a local nudge just
  flashes the caret off the prompt line (and *stuck* off it when the
  shell has nothing to redraw, e.g. Up at the oldest history entry).
  Horizontal arrows keep the preview (they do track the live input
  caret). See host/input.zig `handleRepeatKeys`.
- **Home / End alias ctrl+a / ctrl+e on the live line** (jump to column
  0 / end of input; via `moveCursorTo` → `setCursorAt` they also end any
  browse and snap the view to the live tail). **While browsing scrollback
  they act on the browsed row instead** — `browseHome` goes to column 0,
  `browseEnd` goes just past the last non-blank cell of that row (a blank
  row → column 0), both staying in browse mode. ctrl+a / ctrl+e keep the
  snap-back-to-prompt meaning in every state. `browseEnd` costs one
  `get_cells` snapshot of the current view to find where the row's text
  ends — there's no lighter per-row text query on the wire, and End is
  pressed rarely enough that it doesn't matter.
- **A multi-line prompt near the bottom scrolls up-front, once.** After a
  command's output has scrolled the layer the cursor can be within
  `prompt_lines` of the last row. `writePowerlinePrefix` used to just
  `set_property(cursor, {row: start + lines - 1})` — which the server
  turns into that many scrolls mid-draw — and then recorded that
  pre-scroll target as `line_start_row`, leaving it one past the last
  valid row so every later `renderInputLine` / idle right-chain refresh
  `set_property`'d off the bottom and scrolled again (the prompt "crept
  down" ~1 row every 500 ms). Now it computes the overshoot, writes that
  many newlines at the bottom row to scroll deliberately, and draws
  everything relative to the resulting on-grid top row. `renderInputLine`
  / `placeInputCursor` / `drawRightChain` also clamp their row to
  `grid_rows - 1` as a backstop, and `renderInputLine` guards a
  zero/underflowed box width.
- **The shell re-lays-out the prompt on a window resize.** It now
  subscribes to `"resize"`. Without this the right chain stayed at the
  old column (`grid_cols - w` with a stale `grid_cols`) and, worse, the
  `grid_rows - 1` clamps above used a stale `grid_rows`, so after a
  shrink the prompt rows were past the real bottom and the idle refresh
  `set_property`'d off-grid every 500 ms — the same creep. The redraw is
  **debounced**: `Prompt.noteResize` records the latest size and a
  timestamp; `applyPendingResize` re-lays-out only once the size has been
  quiet for `resize_settle_ms` (~140 ms), or immediately on the next
  keystroke. A resize *drag* emits an event per frame and redrawing on
  each looked messy; resize notifications also don't wake
  `waitInputEvent`, so while one is pending the loop polls on a short
  `resize_poll_ms` timeout and suppresses the idle right-chain refresh.
  `handleResize` itself: `Layer.resize` is bottom-anchored, so the
  recorded prompt top is shifted by the height delta and the prefix
  redrawn from there (`writePowerlinePrefix`'s scroll-up-front handles an
  overflow). Mid-drag reflow can still look briefly odd — a real reflow
  model is a later item (`docs/ideas.md`).
- **On-demand command vars — `prompt{ commands = { name = "cmd" } }`.**
  The declarative slice of "let the prompt shell out for git state": a
  map of var name → `/bin/sh -c` command line (a bare string, or a table
  adding `when` / `timeout_ms`). `{name}` in any template string or
  segment expands to the command's **trimmed stdout**. Chosen over the
  deferred Lua-callback form for the common case because it needs no new
  Lua surface and stays declarative like the rest of `prompt{}`; the
  callback form is still the escape hatch for logic a shell one-liner
  can't express.
  - **Lazy + memoised per prompt.** A command runs only when a template
    actually hits its `{name}` this draw, at most once — `Prompt`'s
    `cmd_var_cache` (cleared by `resetCmdVars` at the top of
    `writePromptPrefix`) means the idle right-chain refresh and a
    multi-line redraw reuse the same values, and the next prompt re-runs
    them. So a `git` call costs once per prompt, not once per 500 ms tick.
  - **`when` gates the run, and `{name}` works inside a `when`.** A
    command var's `when` is a `{var}` template expression; the command
    runs only if it renders truthy (`prompt_template.whenTruthy` —
    non-empty, not `0`/`false`; a leading `!` negates). A segment's
    `when` grew the same expression form (`PromptSegment.when_expr`, set
    when the Lua value contains a `{`; the `always|error|slow` keywords
    are unchanged). This is what lets `git` commands be guarded by one
    cheap `is_repo = "git rev-parse --is-inside-work-tree"` probe so they
    never run outside a repo. Truthiness is **output-based, not exit
    code** — one consistent meaning for `{name}` everywhere, and with
    `sh -c` a probe just has to print something or nothing.
  - **Synchronous, short timeout.** The command runs on the prompt-draw
    thread with a 400 ms default cap (`timeout_ms` overrides); on the
    timeout the child is killed and `{name}` renders empty, dropping a
    now-empty segment like any other. An async/background repaint was
    considered and deferred — the stall is bounded and rare, and the
    caching keeps it to once per prompt.
  - **`prompt_template` stays pure.** The engine gained a `Data.vars`
    hook (`VarResolver`: an opaque ctx + a `resolve(ctx, name) ?[]const
    u8` fn pointer) consulted only for a token no built-in field
    claimed; `null` keeps the "unknown token stays verbatim" behaviour.
    `shell/main.zig`'s `resolveCmdVar` is the implementation (with the
    cycle/depth guard for a `when` that references its own var); the
    module itself still takes no IO/exec/glyphwire dependency.
- **Deferred:** a `prompt` *function* form — `shell.conf` sets a Lua
  callback that receives the same data items and emits its own draw
  commands, for prompt logic a `commands` one-liner can't express.
  Recorded in `docs/ideas.md` / roadmap.md; the string + segment +
  command-var forms here are the first slices, and `prompt_template`'s
  `Op` list / `Data` snapshot are already the right shape to hand to a
  callback.

#### Persistent command history: `~/.config/glyphwire/history`
- **Plain text, one command per line, oldest first** — same directory
  resolution as `shell.conf`. Loaded into `Prompt.history` at startup so
  Up-arrow recall resumes the previous session.
- **Written after every recorded line, not on exit.** An interactive
  session here is almost always *killed* (the host reaps the process;
  `exit` is the only clean path), so buffering until exit would lose the
  session. The file is small and commands are human-paced, so each
  recorded line triggers a full rewrite of the file from `Prompt.history`
  rather than an append + periodic compaction.
- **Recording rule (`history.shouldRecord`):** non-blank, and not
  identical to the entry right before it (bash `ignoredups`). This is now
  also applied to the *in-memory* history, so recall no longer walks
  through a run of the same command. The file is capped to the last
  `history.max_entries` (5000) on every load and every write.
- Pure parse/serialize/dedup/cap helpers live in `shell/history.zig`
  (unit-tested); the file read/write and directory creation stay in
  `Prompt.loadHistory` / `persistHistory`. An IO failure just leaves
  history in-memory-only for the session rather than failing the shell.
- **`$GLYPHWIRE_NO_HISTORY`** (any non-empty value) skips the file
  entirely: nothing is read or written, though in-session recall still
  works. The e2e tests set it so driving the real `glyphwire-shell`
  binary doesn't append test commands to the developer's history.

#### Scrollback browsing (Ctrl+Up) and `scrolloff`
- **Plain Up/Down recall command history at the prompt** (readline-style,
  `historyUp`/`historyDown` walking `Prompt.history` with the typed line
  stashed as scratch). They only browse scrollback once already *in*
  browse mode.
- **Ctrl+Up breaks into scrollback browse mode** (a one-row step off the
  input line into a browse cursor, `browse_pos`). Then the arrow keys
  move the cursor one row/column, **Ctrl+Up/Ctrl+Down jump
  `scrollback_jump` rows and Ctrl+Left/Ctrl+Right jump `scrollback_jump`
  columns** (none of the ctrl+arrows snap back to the prompt while
  browsing, unlike on the live line where ctrl+Left/Right is a word
  jump), Home/End act on the browsed row (`browseHome`/`browseEnd`),
  Enter/click acts on whatever `glyphwire-ls` tagged there, and Escape
  returns to the prompt. Ctrl+Down at the prompt does nothing (there's
  nothing below the input line). This is a swap from the earlier binding
  where plain Up/Down browsed and Ctrl+Up recalled history — deliberate
  entry into a navigation mode reads better than arrows silently meaning
  two different things depending on whether the line is empty.
- **Typing while browsing** returns to the prompt and inserts the
  character by default (`insertText` → `setCursorAt` clears `browse_pos`
  and the scroll view); `prompt{ scrollback_type_exits = false }` makes
  browse a strict navigation mode that only Escape ends. A paste follows
  the same rule.
- **`browseUp`/`browseDown` keep a vim-style scrolloff margin.** Instead
  of only scrolling the host window once the browse cursor is jammed
  against row 0 (going up) or the prompt row (going down), they start
  scrolling the window (`scroll_view` "scroll the window along") once the
  cursor is within `scrolloff` rows of that edge, holding the cursor at
  the margin — until the scrollback is exhausted, when the cursor is let
  the rest of the way to the edge. Down still can't move onto or past the
  prompt row (it ends browsing there).
- **`scrolloff` is a `shell.conf` `prompt{}` key**, default `8`. It lives
  in `prompt{}` because that's the one table binding the shell config
  has; it's clamped at use to half the rows between the top and the
  prompt so there's always room for the cursor to travel.
  `scrollback_jump` (default `5`, must be ≥ 1) and
  `scrollback_type_exits` (default `true`) live in the same table.
- The host side of "a keypress brings the cursor back into view" is the
  caret-pin release in `glyphwire-host` (see Layers → the caret bullet):
  a mouse scroll pins the caret to its buffer cell, and the next
  key/text snaps the view back to the live tail.

#### Persistent Lua scripting: script builtins & the `sh` table
- **One Lua state for the whole session.** `shell/config.zig`'s `load`
  still spins up a throwaway interpreter for a one-shot `shell.conf`
  parse (that's what the unit tests drive), but the live shell keeps a
  session-long state in `shell/script_engine.zig` and runs `shell.conf`
  through *that*. So a `function` the conf defines, or a `defcmd(name,
  fn)` it calls, stays callable as a builtin for the rest of the session.
  This was chosen over adding a second config surface or a bespoke
  per-command mechanism because other language runtimes are meant to hang
  off the same extension point later, and the Lua surface can stay as
  small as we want it.
- **A builtin is a `defcmd` registration or a file
  `<config_dir>/scripts/<name>.lua`.** The file is looked up by basename
  and recompiled on every call, so editing it takes effect with no
  restart — worth more than the microseconds in a config directory.
- **Script names are a dispatch-layer lookup, never Lua globals.**
  `defcmd` stores the function in a table kept only in the Lua registry;
  a file is `loadString`d on demand. Nothing a script does to `_G` can
  shadow or leak it, and a builtin named `string` or `os` is harmless.
- **Precedence: core builtins (`cd`/`exit`/`alias`/`unalias`) > aliases >
  script builtins > `$PATH`.** Aliases are already expanded by the time
  dispatch reaches the builtin check, so the order there is just: core,
  then `runScriptBuiltin`, then `runCommand`. A `cd.lua` can't break the
  shell; a `ls.lua` deliberately does shadow `/usr/bin/ls`, matching
  bash's function-over-command rule.
- **The `sh` table is the only new host surface.** `sh.setenv` /
  `sh.unsetenv` change this process's libc environment (so children
  spawned afterwards inherit it — `pty.zig`'s `execvp` reads the live
  environ, same reason `prependZigOutBinToPath` uses `setenv`) *and* a
  `std.process.Environ.Map` the prompt owns (`Prompt.env`, seeded from
  the startup snapshot), which is what `{env:NAME}` renders from — so a
  venv-activate script's `$VIRTUAL_ENV` shows up on the next prompt draw
  with no prompt cooperation. `sh.getenv` reads that live map;
  `sh.cwd` / `sh.realpath` are the two path helpers Lua's stdlib lacks.
  Everything else (path joining, file reads) is left to stock Lua.
- **`sh.run` / `sh.exec` make Lua a shell scripting language.** Both take
  a *command-line string* and run it through the exact same
  `shell/parse.zig` + `runPipeline` the interactive prompt uses, so
  `sh.run("ps aux | grep glyphwire")` and `sh.exec("make && ./run")`
  read like shell and `|` / redirects / `&&` / `||` / `;` all just work.
  `sh.run(line [, stdin])` captures — it returns
  `{ code, ok = code==0, out, err }` (`stdin`, if given, feeds the first
  stage; a `2>&1` in the string merges stderr into `out`). `sh.exec(line)`
  is the passthrough form: output streams to the grid like a typed line,
  and it returns just the status. Chosen over a structured
  `sh.pipe({{...}})` API because the string form composes cleanly and a
  `.lua` script stays legible; a builtin stage inside such a string still
  writes to the grid rather than into `out` (the same
  builtin-in-a-pipeline limitation).
- **The stdlib is open, with three edits.** `print` and `io.write` are
  re-pointed at the grid; `os.exit` is replaced with a function that
  raises a catchable error (a script must not be able to kill the
  shell). `os.execute` / `io.popen` are left working — they run a real
  subprocess outside the grid mirroring, an accepted limitation.
  `require` gets `<config_dir>/scripts/lib/` prepended to `package.path`.
- **A runaway script is bounded.** `runCommand` installs an
  instruction-count hook (`lua_sethook`) for the duration of the call;
  the hook polls `HostHooks.poll_interrupt` (which drains the input feed
  looking for Ctrl-C) and enforces a 30s wall-clock ceiling, raising a
  Lua error either way — exactly how Lua's own CLI handles SIGINT. A
  script blocked in a C call (a slow `io.popen`) isn't executing
  bytecode, so the hook can't fire; that case is left as a known
  limitation, same as bash.
- **Errors never escape.** Every call into the persistent state goes
  through `protectedCall` / `doString`; a script error is written to the
  grid as `name: message` and reported as exit status 1, and the state
  stays usable. A builtin's numeric `return` is its `$?` (so `{exit}`
  works); `runScriptBuiltin` reports `last_dur_ms = 0`.
- **`sh.chdir(path)` changes the shell's directory from a script**, going
  through the same `Prompt.chdir` an interactive `cd` uses (so the jump
  is recorded in the `zj` database too). Returns a boolean rather than
  raising, so a script can branch on a bad path. Added because `sh.exec`
  can't do it — `sh.exec("cd ...")` goes straight to `runPipeline`, which
  never consults builtin dispatch, so `cd` there would try to exec a
  binary.

#### `zj` directory jumping
- **`zj QUERY` is a `z`/zoxide-style jump built in, not a shipped Lua
  script.** It needs to change the shell's own cwd, which a script could
  only do through the new `sh.chdir` hook; a core builtin is simpler and
  keeps the ranking logic in a pure, unit-tested Zig module
  (`shell/zjump.zig`), matching how `history.zig` / `glob.zig` are
  structured. Named `zj` rather than `z` to stay clear of a one-letter
  name a user is likely to have aliased.
- **Every `cd` records the new directory; `zj` ranks by frecency.** The
  database (`~/.config/glyphwire/z.db`, a `<rank>\t<last>\t<path>` TSV) is
  keyed by the *real* cwd (`getcwd` after the change, so symlinks and
  `..` are already collapsed). Ranking is zoxide's formula: a per-path
  visit weight scaled by a stepped recency multiplier (4× within the
  hour, 2× the day, 0.5× the week, 0.25× older), so a directory hit three
  times this morning beats one hit forty times last month. Bounded not by
  an entry cap but by aging: once the summed weight passes 10000 every
  entry is scaled ×0.9 and the sub-1.0 ones are dropped.
- **Matching is case-insensitive substring, last term also matching the
  basename.** `zj a b` requires every term as a substring of the path and
  the last term as a substring of the final component — so `zj dow` lands
  in `~/Downloads` from anywhere, not in `~/downloads-archive/old`. Full
  fuzzy/subsequence scoring was deliberately skipped as more than the
  feature needs. The current directory is never a result; `$HOME` and `/`
  are never *recorded* (a keystroke away without help); `exclude_dirs`
  from `zj{}` in `shell.conf` drops a subtree from both. A single
  argument that is itself an existing directory falls back to plain `cd`
  (so `zj ../sibling` still works), and bare `zj` goes `$HOME`. A jump
  target that has since vanished is pruned from the database and
  reported. An interactive picker for ambiguous queries is deferred.

#### Persistent state is flushed lazily, not on every change
- **History and the `zj` database are kept in memory and written on a
  gate**, replacing history's old "rewrite the file after every line".
  That eager write existed because an interactive session was normally
  *killed*, not exited — which no longer holds now that the host sends a
  `shutdown` notification (see below) the shell flushes on. The gate
  (`shell/flushgate.zig`) forces a write after 25 un-flushed changes or
  120s, whichever first, bounding what a `SIGKILL`/crash can lose; a
  clean exit and the `shutdown` path both force an unconditional flush.
- **The host tells clients it's closing (`shutdown` notification) instead
  of just dropping the socket.** On window close `host/main.zig` — after
  the render loop has ended but while the `serveForever` thread is still
  up — broadcasts `shutdown{grace_ms}` and then waits up to `grace_ms`
  (1.5s) for the shell's process to exit before tearing down. The shell
  subscribes and treats it as a typed `exit`. A wire notification rather
  than shell-only cleanup so any client (a future editor with unsaved
  buffers) can hook the same signal; it rides the same
  `InputListener` ordered queue as `key`/`text` so it can't jump ahead of
  input the user already typed.

### Batch messages
- **`batch` wraps an ordered list of other messages in one frame**,
  applied server-side in a single pass under the one `ctx_mutex` hold the
  server already takes per message. The motivating problem: `glyphwire-ls`
  emits a listing as dozens of separate `set_property`/`draw_icon`/
  `write_text` notifications interleaved with per-entry `create_metadata`
  round trips, and glyphwire-host renders frames the whole time — so the
  listing visibly paints itself a band at a time and scrolls as it goes.
  Sent as one batch, the grid goes from its prior state straight to the
  finished listing in a single frame.
- **A wrapper method, not a JSON-RPC 2.0 top-level array.** The spec's
  batch form is a bare `[...]` at the frame-body root; a `batch` method
  with `{messages: [...]}` was chosen instead so the whole decode/dispatch
  path keeps assuming one object envelope per frame (one new handler, no
  parser change) and a batch stays `nc -U` / `jq`-inspectable as an
  ordinary message. `dispatch.zig`'s `handle` split into a parse step and
  a `dispatchEnvelope` step so each sub-message routes through the exact
  same catalog as a standalone frame — a batched `write_text` and a
  standalone one hit precisely the same handler.
- **Both notification and request forms.** No outer `id`: fire-and-forget,
  no response (a sub-request's result is dropped with a log line). Outer
  `id` present: the response carries `{responses: [...]}`, one full
  JSON-RPC response object per sub-message that had an `id` and produced a
  result, in order, each tagged with that sub-message's batch-local id for
  correlation. This is what lets `glyphwire-ls` collapse its N per-entry
  `create_metadata` round trips into one batch request, then send every
  draw call as one batch notification — a whole listing in two frames
  instead of ~2N.
- **Best-effort, not transactional.** A sub-message that fails to parse,
  names a batch-invalid method, or errors in its handler is logged and
  skipped; the rest still applies. There is no rollback — core has no
  transaction support, and this matches how server.zig already treats a
  standalone notification's dispatch error (log, don't sever). "Atomic"
  here means only "one render", not all-or-nothing.
- **`batch` and `load_image` can't be nested in a batch** — no recursive
  batches, and `load_image`'s binary side-channel payload can't be framed
  inside the `messages` array. Other broadcast-producing messages
  (`report_key`, `scroll_view`, …) are accepted but their broadcast is
  suppressed: a batch is meant for draw/layer/table/metadata commands,
  not input.
- **`glyphwire-ls` uses it.** `writeGrid` sends two batches (metadata
  requests, then all draws) and tracks the draw row locally instead of a
  per-band `get_property("cursor")` round trip — the local
  `@min(draw_row + block_rows, rows - 1)` mirrors `Layer.resolveRow`'s
  scroll-and-clamp, so the batched sequence lands identically to the old
  call-per-band one. `writeLongTable` batches just its per-entry
  `create_metadata` calls (its drawing was already one `table_set_rows`).

### Server architecture
- **Headless-first.** Core state — the layer tree, positions, clip rects,
  scroll offsets, cell contents, animation state — is a pure, inspectable
  state machine with no dependency on rendering or windowing, so it can run
  without a display and be covered by a real unit test suite. Rendering
  (via the Zig 2D engine) and socket I/O are layers on top of that headless
  core, not entangled with it. This shapes the Text & Styling data-model
  choices below, which favor directly-assertable structures over anything
  requiring resolution/indirection to inspect.
- **Wire DTOs live in one module.** `src/protocol.zig` holds the pure JSON
  shapes that cross the socket (colors, cells, table state, input state,
  the input-notification param objects) with no behavior attached. Both
  the server side (`dispatch.zig`) and the client side (`client.zig`)
  import it, so the two ends can't drift on a field name or type -- the
  previous arrangement kept a parallel copy of each shape in both files.
  `src/rpc.zig` is a thin companion: `response`/`notification` envelope
  builders plus one builder per input notification (`key_down`/`key_up`,
  `text`, `mouse_button`, `scroll`, `resize`), shared by `dispatch.zig`'s
  socket handlers and `server.zig`'s in-process reporters. Neither module knows
  about connections or core state; adding a message still means editing
  the handler and (if the shape is shared) `protocol.zig`, so the message
  catalog stays visible rather than hidden behind a framework.

### Redraw on change
- **The host draws only when something changed.** A terminal is static
  most of the time, so `glyphwire-host` blocks in the event loop when idle
  and repaints only on a real change — a grid mutation, a resize, a font
  zoom, a scroll, a caret blink, an IME composition. This is
  `host_eng`'s `EngineOptions.redrawOnDemand` (off by default — a game
  repaints every frame; the host opts in). Builds on the per-layer static
  quad batches, which already made "did this layer change" a cheap
  `render_gen` comparison.
- **The server signals change through an injected callback, not by
  calling SDL.** `Server.setWakeCallback(ctx, fn)` — fired after every
  frame a socket connection dispatches, because that work runs on the
  connection's own thread and can't nudge the render loop directly. The
  host registers a callback that pushes an `SDL_EVENT_USER`; the headless
  server and any alternate front end simply never register one, and the
  server core has no windowing dependency. Rejected: the server calling
  `SDL_PushEvent` itself (couples the core to a windowing library),
  and a fully polled loop with a short timeout (wakes 60×/s doing
  nothing).
- **Change detection is a per-frame snapshot compare, not dirty flags.**
  `App.needsRedraw` builds a value fingerprint each frame under
  `ctx_mutex` — a wrapping sum of every layer's `render_gen`, a rolling
  hash of `layer_order` + per-layer visibility (`raise_layer` /
  `lower_layer` / show / hide don't move `render_gen`), the root view
  offset, plus host-local bits (framebuffer size, cell size, caret
  cell/visibility/shape, an FNV hash of the IME preedit, a
  screenshot-pending flag) — and compares it to the last drawn frame's.
  The `Context`-derived half is `host/redraw.zig` (`contextSig`), pure and
  unit-tested. Rejected: a `dirty` bool set at every mutation site plus a
  `Context` hook for the server thread — more call sites touched, easy to
  miss one, and the snapshot is already cheap.
- **A blinking caret still forces a redraw.** The caret blinks on its own
  clock, so `App.idleTimeoutMs` returns a bounded wait (~`blink_ms`) while
  `cursor_blink` is on, and the phase flip shows up in the fingerprint.
  Pausing the blink on focus loss (hold it solid, stop waking entirely)
  is a noted future refinement, not v1.

### Profiler
- **The profiler is a first-class runtime toggle, not a build flag.**
  `host.conf`'s `profile` enables a small frame-timing subsystem
  (`src/profiler.zig`, generic over a caller-supplied span/counter enum;
  `host/profiler.zig` instantiates it for the host loop). Every
  measurement call is written as an unconditional early-return guarded by
  a runtime bool, so a normal build carries the calls but pays nothing
  measurable — matching the redraw-on-demand goal of a near-zero idle
  cost. Rejected a `-Dprofile` build option: profiling a slowdown you
  can't reproduce on demand shouldn't need a dedicated binary, and the
  HUD wants a live in-session toggle (Ctrl+Shift+P) regardless.
- **Every number is a windowed average, not a lifetime one.** Stats
  accumulate over `profile_window_ms` (default 1s) and republish at the
  boundary, then the accumulators reset — the FPS-counter pattern
  (`host_eng`'s own `FpsCounter`), generalised to per-phase avg/p95/max
  and per-counter per-frame means. A first cut kept a fixed-size rolling
  sample ring instead; its time span was frame-count-based and so
  unintuitive (very long under redraw-on-demand idle, where samples
  arrive at ~10Hz), and a slow startup frame dragged the average for
  minutes. Set `profile_window_ms` equal to `profile_log_ms` to make
  each logged line an average over exactly that interval.
- **Three surfaces, one snapshot.** The same `core.ProfileSnapshot`
  (plain data: per-phase `avg`/`p95`/`max` ms + per-frame counter means)
  feeds an on-screen HUD, an optional periodic `std.log` table
  (`profile_log_ms`), and the wire — `get_property "profile"`. Dropped a
  lifetime running total per counter: over a whole session it only ever
  grows and told you nothing the per-frame mean doesn't.
  The wire path is a read-through: glyphwire-host writes the snapshot
  onto `core.Session.profile` each iteration under the `ctx_mutex` the
  dispatch handler already reads it under, so no new server hook or
  callback (unlike `setWakeCallback`) — the session never interprets it.
  This keeps `glyphwire-probe` able to sample a running host with no
  window interaction.
- **The phases are the redraw-on-demand pipeline.** `frame` (whole
  iteration wall period), `wait` (the `SDL_WaitEvent` block), `update`,
  `redraw_check` (`needsRedraw`), `sync_batches` (per-layer batch
  rebuild), `draw`, `present` (`swapBuffers`, incl. any vsync block).
  `wait` and `present` are the only two the app can't time itself, so
  `host_eng`'s `gameLoopCore` measures them and calls back through two
  `@hasDecl`-guarded optional `AppData` hooks — a non-profiling engine
  consumer compiles them out entirely, and `host_eng` gains no config
  surface. Counters (`layers_rebuilt`, `draw_calls`, `quads`) cover just
  the batched compositing, which is what static batching is about;
  immediate-mode caret/preedit/chrome draws are not counted.
- **The HUD forces continuous redraw while shown.** It displays live
  numbers, so `needsRedraw` returns true unconditionally and
  `idleTimeoutMs` drops to ~100ms while the HUD is visible -- a
  deliberate ~10Hz repaint that the profiler's own frame counters then
  report. It is off by default and drawn after any `--screenshot`
  capture so it never lands in a scripted screenshot.
- **A separate "forced redraw" toggle restores the pre-optimisation
  loop.** Ctrl+Shift+R (or `host.conf`'s `profile_force_redraw`) makes
  `needsRedraw` always true *and* `idleTimeoutMs` return 0, so the loop
  runs at the display's frame rate the way it did before
  redraw-on-demand -- for measuring steady-state `draw` / `present` /
  `sync_batches` cost and A/B-ing it against the idle path. Kept
  distinct from the HUD toggle: the HUD's ~10Hz cap is deliberate,
  forced redraw is uncapped. `skips_per_sec` reads 0 while it is on,
  which is the confirmation alongside the HUD's `[FORCED REDRAW]` tag.
- **glyphwire-shell reuses the same module, env-gated.**
  `GLYPHWIRE_SHELL_PROFILE=<ms>` turns on a two-span profiler
  (`prompt_render`, `right_chain`) that dumps a `std.log` table on that
  cadence — no HUD, no wire surface, since the shell is a client. Aimed
  at the "prompt redraw feels slow" work.

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
- **Multi-process layer ownership.** *Partially resolved* — see the Layer
  section's "layer ownership & lifecycle" bullet: per-connection ownership
  of individual layers (`create_layer` / `adopt_layer` / cull-on-
  disconnect) is built. Still deferred: a single foreground owner per
  *grid* (classic shell model) vs. multiple concurrent processes owning
  separate *regions* (tmux-pane-like, negotiated) — the region model is
  still scoped out of v1.
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
- **Context creation/activation policy** — *resolved and built* (see
  "v1 built — context lifecycle" in the Layers section). `create_context`
  / `destroy_context` / `activate_context` / `attach_context` /
  `adopt_context` exist; any connection may create, activate or attach
  (no privilege boundary in a single-user local session), ownership
  gates destruction only, and a connection acting on a background
  context it's attached to works fine — draws land there, only the raw
  input streams are gated to the visible context.

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

**Built:** `Cell.wide` is a `CellWidth` enum (`narrow` / `wide_lead` /
`wide_spacer`). `writeText` places a width-2 grapheme in a `wide_lead`
cell plus a blank `wide_spacer` to its right (which copies the lead's
resolved style and `metadata_id`, so a background spans the pair and a
hit-test on either half resolves the same), advances the cursor by 2, and
wraps a wide grapheme that would straddle the right edge to the next row.
`insertCells`/`deleteCells` run `sanitizeWidePairs` afterward to downgrade
any pair a shift left inconsistent. `get_cells` exposes the state as
`wide: "lead" | "spacer"` (absent = narrow); `write_text` is unchanged
(the server computes width). Width comes from `core.codepointWidth`, a
binary search over a compact sorted table of the Unicode 16.0.0 East
Asian Width `W`/`F` ranges baked into `core.zig` — **Ambiguous (`A`) is
treated as narrow** (the wcwidth / non-CJK-locale default). `glyphwire-ls`
lays its columns out with the same width model (`gridlayout.displayWidth`
/ `truncateToCols`, which never split a wide codepoint).

**Built — glyphwire-shell's line editor is width-aware too:** `Prompt`
keeps its cursor as a byte offset into the line buffer, but every place
that turned that offset into a grid column, or a byte count into a
`insert_cells`/`delete_cells` count, went through `core.stringWidth` (now
re-exported as `glyphwire.stringWidth`) instead — via the pure
`shell/lineedit.zig` helpers (`prevBoundary`/`nextBoundary` step whole
codepoints, `displayCol`/`cellWidth` sum display width). Before this, a
line with CJK text (reachable via Tab-completing a CJK filename) put the
caret column three-per-char instead of two, so arrow keys appeared not to
move it, and backspace/kill/completion freed the wrong cell count.
`lineedit` is a `shell_support` module so `tests/shell_tests.zig` can
cover it.

**Open:** grapheme cluster segmentation still needs Unicode text
segmentation (UAX #29) — width is currently taken from a cluster's base
codepoint, so multi-codepoint ZWJ emoji and combining sequences aren't
measured as one unit. The width table is regenerated by hand from a
newer Unicode's `EastAsianWidth.txt` rather than pulled from a library.

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

**Decision (revised — Phase A VT fallback):** the "strip, don't
interpret" line above is now partly walked back. `Layer.writeText`
*interprets* the escape sequences a plain, non-glyphwire-aware program
most commonly emits, so `gcc`/`clang` diagnostics, `git` output, and
`pip`/`npm`/`cargo` progress bars render in something close to their
intended form instead of losing all colour. This is deliberately the
*small* half of a two-phase plan — see
`docs/investigations/libghostty-vt-fallback.md`; the *large* half
(a real PTY + full VT model for `vim`/`less`/`htop`) is still unbuilt.

- **SGR (`ESC [ … m`) is interpreted, colour only.** 16-colour,
  bright, xterm-256, and truecolor foreground/background (both the `;`
  and the `:` sub-parameter forms), plus `0` reset. `1` bold promotes a
  *basic* (30-37) foreground to its bright (90-97) variant — the common
  "bold is bright" terminal behaviour and the entire extent of bold
  support; `2` dim darkens the resolved foreground; `7`/`27` inverse
  swaps foreground and background. Italic, underline, blink, and
  strikethrough are *parsed and ignored* — they need real `Style`
  attribute bitflags and font/renderer work (still the separate
  "style attributes beyond fg/bg" roadmap item), and none of the Phase A
  target programs depend on them for legibility.
- **No new data-model or wire surface at all.** Everything resolves to
  the concrete `Cell.style.fg`/`.bg` colours the renderer and `get_cells`
  already handle — `bold`→bright, `dim`→darker, `inverse`→swapped are
  folded in *at write time*. `Style` grew no fields; `write_text`'s
  params, `glyphwire-host`, and `protocol.zig` were all untouched.
  `fg`/`bg` omitted still means `default_style`'s, exactly as before.
- **A small set of `ESC [ …` cursor/erase finals is interpreted:**
  `A`/`B`/`C`/`D` (cursor up/down/right/left), `G` (column), `d` (row),
  `H`/`f` (row;col), `J` (erase in display), `K` (erase in line) — enough
  for a `\r` + `ESC [ K` progress-bar repaint and simple repositioning.
  Downward/absolute-row moves resolve through `Layer.resolveRow`
  (scrolling like a line feed); upward moves clamp without scrolling.
  Every *other* CSI final, and every `ESC ]`/`P`/`X`/`^`/`_ …` (OSC and
  friends), is still recognized-and-discarded exactly as before —
  including `ESC [ ? … ` private-use sequences, which are matched so
  their parameter bytes are never misread as a numeric list.
- **The colour "pen" is call-local — nothing carries across `write_text`
  calls.** `Layer.pen` (an `SgrPen`) is reset at the *start* of every
  `writeText`, so an SGR colour is honoured only for the rest of the
  chunk that set it. Cross-call persistence was tried (keyed on `fg`
  being omitted) and reverted: every `glyphwire-shell` prompt and echo
  write passes the default `fg`, so a colour a mirrored program left
  un-reset — a `cat`'d file full of raw escapes, a program killed
  mid-output — poisoned the prompt and everything drawn after it. The
  trade is that an SGR colour a pipe splits from the text it colours
  (rare) loses the tail, the same trade the half-parsed-sequence reset
  already makes. `ESC [ 0 m` also resets it, mid-chunk.
- **Why not libghostty here.** libghostty-vt's released 0.1.0 C API
  exposes only parsers (SGR/OSC/key), not a terminal state machine, and
  is not distributed as a standalone package — pulling it via
  `build.zig.zon` means vendoring the whole ghostty monorepo (30+ deps,
  pinned to a Zig version glyphwire is already ahead of). For Phase A's
  narrow scope, extending the hand-rolled `EscState` machine that was
  already here is less code than adapting and hand-syncing a vendored
  ghostty source snippet, and matches glyphwire's "replace VT, don't
  embed a VT library" stance. Real libghostty is reserved for Phase B,
  where the terminal *state machine* — the genuinely hard part — is what
  it would buy. See the investigation doc for the full rationale.

**Decision (VT phase 2 — B1 screen model):** `Layer.writeText`'s
interpreter grew from "colour + a few cursor/erase finals" into a
line-oriented screen model, still hand-rolled in `core.Layer`, still no
VT library. It is what makes `less` / `git log` / `man` / `nano` / `fzf`
and simple full-screen TUIs usable under the B0 pty; real
`nvim`/`htop`/`tmux` remain B2 (a full VT model). New behaviour, all on
`core.Layer`:

- **Alternate screen** (`CSI ? 1049 h/l`, and `?47`/`?1047` treated
  alike): a lazily-allocated `width*height` cell buffer with **no
  scrollback ring**. Entering stashes the primary cursor and homes;
  exiting restores it. The primary buffer — and its scrollback — is
  never touched, so `?1049l` brings the shell's prompt and history back
  exactly as they were. `on_alt` routes `cell`/`viewRow`/the scrollers
  at the accessor level, so the alt screen needs no parallel code path
  and the host renders `ctx.root` unchanged.
- **Scroll region** (`CSI r`, DECSTBM): a `[top, bot]` band. While it's
  narrower than the full screen (or on the alt screen), a line feed at
  the bottom margin, `SU`/`SD` (`CSI S`/`T`), `IL`/`DL` (`CSI L`/`M`)
  and `RI` (`ESC M`) shuffle rows **within the band with no
  scrollback** — a pushed-past-the-margin row is gone. The default
  full-screen region keeps the classic ring-buffer scroll-into-
  scrollback on a line feed past the bottom, so nothing changes for
  normal output.
- **Cursor moves now clamp, never scroll.** `CSI B`/`d`/`H`/`f` used to
  route a target row past the bottom through `resolveRow` (which
  scrolls) — fine for Phase A's colour + progress-bar output, but a
  full-screen program that positions to its last line (`less`'s status
  line) scrolled the whole primary layer one row per keypress, so the
  status line climbed instead of staying pegged. Only a line feed /
  `IND` (`ESC D`) / `NEL` (`ESC E`) / `RI` (`ESC M`) / explicit scroll
  command scrolls now — `IND`/`NEL` are new (they were dropped before).
- **`ICH`/`DCH`/`ECH`** (`CSI @`/`P`/`X`) reuse the existing
  `insertCells`/`deleteCells` primitives (`X` is a plain `clear`).
  **`DECSC`/`DECRC`** (`ESC 7`/`ESC 8`, and ANSI.SYS `CSI s`/`CSI u`)
  save/restore the cursor. **`DECTCEM`** (`CSI ? 25 h/l`) sets
  `Layer.cursor_visible`, which glyphwire-host's caret renderer now
  honours.
- **Terminal query replies.** `CSI 6n` (cursor position), `CSI 5n`,
  `CSI c` / `CSI > c` (device attributes) and DECRQM (`CSI ? Ps $ p`,
  for the modes the screen model tracks) are answered — the reply bytes
  can't be written from `core.Layer` (a pure grid, no output channel),
  so `writeText` stashes them and the dispatcher drains them
  (`Layer.takeReply`) into a new **`terminal_reply`** server→client
  notification. glyphwire-shell subscribes to `"terminal"` while a pty
  child is foregrounded and writes them to the pty master. This is the
  one wire addition; the CSI finals themselves are all inside
  `write_text`.
- **After a foregrounded pty child exits**, glyphwire-shell writes
  `ESC [ ? 1049 l  ESC [ ! p` to its own connection — leave the alt
  screen, then **DECSTR** (soft reset: scroll region back to full, caret
  shown, saved cursor and SGR pen cleared; the cursor is *not* moved and
  nothing is cleared). Without the region reset a `less -X` / `bat` /
  git-pager session — which sets a bottom-margin scroll region on the
  **primary** screen and never enters the alt screen — leaves
  `regionActive()` stuck true forever.
- **While a full-screen program owns the root layer**, glyphwire-host
  stops driving the scrollback view *and* stops nudging `ctx.root.cursor`
  on arrow presses (its caret-preview for the shell's own prompt): the
  program's output is the sole authority on the cursor, so a program
  that redraws relative to it — `less`'s `:` prompt at BOF is
  `\r \x1b[K :`, no absolute address — no longer lands a row higher per
  keypress. The mouse wheel is redirected to arrow-key events for the
  program (xterm's `alternateScroll`, so a wheel over `less`/`bat` pages
  it), the scrollbar is inert, `render` pins the view to the live tail,
  and any scrolled-back view is snapped to 0 the moment the program
  takes over. Keys are still forwarded — only the local caret/scroll
  side effects are suppressed. The trigger is `on_alt` *or* a
  scroll region set *or* **DECCKM** (`CSI ? 1 h`, application cursor
  keys — `Layer.app_cursor_keys`, tracked purely so the host can read
  it). `less -FRX` (git's default pager) and `bat` set neither the alt
  screen nor a scroll region, but every full-screen TUI — `less`, `vim`,
  `htop`, `nano`, `fzf` — sets DECCKM, and `ls`/`cat`/`grep` don't, so
  it's the reliable "a program is driving the screen" signal. Without
  this, `less -X`'s status line (on the primary screen, not the alt
  screen) and content appeared to crawl as the user scrolled the host
  view.

**Decision (VT100 alternate charset / ACS line drawing):** `htop`'s panel
borders rendered as stray ASCII letters (`l`, `q`, `k`, `j`, ...) instead
of box-drawing glyphs — ncurses draws them via the VT100 "special
graphics and line drawing" charset, which glyphwire's escape machine
didn't recognize at all: `ESC ( <c>` fell through to the generic
short-escape case and the charset-final byte itself leaked onto the grid
as a literal character (see the old comment this replaced). Added,
entirely in `core.zig`, no wire/host change:

- `ESC ( <c>` / `ESC ) <c>` designate G0/G1 (`Layer.g0_line_drawing` /
  `g1_line_drawing`) as line drawing (`c == '0'`) or ASCII (anything
  else, `'B'` in practice). `SO`/`SI` (0x0E/0x0F) pick which of G0/G1 is
  active (`Layer.shift_out`) — previously dropped as inert C0 bytes.
- While the active set is line drawing, `writeText` maps a printable byte
  in `` ` ``..`~` through `acsGraphic`'s table (the standard VT220/
  `console_codes(4)`/terminfo `acsc` mapping) to its Unicode glyph instead
  of printing it literally.
- Covers both idioms real terminfo entries use: xterm-style `smacs`/
  `rmacs` (`\E(0`/`\E(B`, redesignates G0 directly, no SO/SI) and
  screen/tmux-style (`\E)0` once, then `^N`/`^O` around each run).
- Charset state resets to ASCII/G0 at the end of every `writeText` call,
  matching `esc_state`/`pen`'s existing call-scoped reset (same
  rationale: a `smacs` left un-closed by a chunk boundary must not poison
  glyphwire-shell's own prompt).
- **Tests:** `core_tests.zig` +3 (xterm-style, screen-style, no
  cross-call bleed). 462 pass.
- **Not covered:** the rest of B2 (tab stops, origin/autowrap modes,
  keypad application mode, real bold/underline/italic styling) — this
  was a narrowly targeted fix for the specific htop symptom, not a step
  toward a full VT model.

**Decision (function keys in `key_encode.toPtyBytes`):** `F1`-`F12`
never reached a pty child at all — `toPtyBytes`'s `named` table had no
entry for them, so htop's `F10` (quit) was silently swallowed. Added the
classic xterm/VT220 mapping every terminfo entry's `kf1`..`kf12`
capability expects: `F1`-`F4` as SS3 (`ESC O P`..`ESC O S`, unaffected by
DECCKM — that only retimes the arrows/Home/End), `F5`-`F12` as `CSI n ~`
(`15`, `17`-`21`, `23`-`24`, skipping `16`/`22` for the same historical
VT220 reasons xterm does). Named `"F1"`..`"F12"` (uppercase) to match
the engine `Key` enum's field name, which `host/input.zig`'s
`reportKeyEvents` forwards verbatim over the wire — every other named key
in the table happens to be lowercase because that's what the enum calls
it, not because of a case convention glyphwire imposes. (Written against
zglfw's enum originally; `host_eng/input.zig` kept the same spellings
through the SDL3 port for exactly this reason.) `F13` and up, and a modifier held
alongside a function key (xterm's modifier-suffixed forms), stay out of
scope, same as kitty/modifyOtherKeys generally. **Tests:**
`shell_tests.zig` +1. 463 pass.

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

- East Asian Width is **built** (see Cell content above): a hand-baked
  compact `W`/`F` range table in `core.zig`, `A` treated as narrow.
  Still open: grapheme segmentation (UAX #29) — width is per base
  codepoint, so ZWJ/combining clusters aren't measured as one unit — and
  whether to ever pull the width data from a library instead of
  regenerating the table by hand.
- Final `Style` struct layout and full attribute bitflag list, now
  including the cell background tagged union (color vs. image/icon
  reference — see Object Model above). The Phase A VT fallback wants this
  too: SGR italic / underline / strikethrough are currently parsed and
  dropped for lack of a `Style` bitfield and renderer support.
- Full property name list/enum for `get_property`/`set_property`
  (`cursor`, `position`, `size`, `clip`, `scroll`, `visibility`, ...) —
  not finalized.
- Underline style/color — confirm as post-v1.
- Style interning — confirmed deferred, revisit only if memory profiling
  on real large-grid usage justifies it.

### zoe syntax highlighting

**Decision: tree-sitter, loaded as data at runtime — not a plugin ABI.**
The ask was "extensible without recompiling, so new languages can be
added later; are shared-lib plugins with a standard event/API surface the
right shape?" For syntax highlighting the answer is that tree-sitter
already *is* that system, and it needs no ABI of zoe's own:

- A grammar is a standalone C shared library exporting one function,
  `tree_sitter_<name>() -> *const TSLanguage`. zoe `dlopen`s it, hands
  the result to `ts_parser_set_language`, and never links it. This is how
  Neovim, Helix, Zed and emacs-treesit load languages.
- Highlight rules are a plain-text S-expression query (`highlights.scm`),
  read and compiled at runtime — not code.

So a "language plugin" is a directory (`parser.so` + `highlights.scm`)
plus one line of extension mapping. Later capabilities (folds,
indentation, text objects, incremental selection) are *more query files*
against the same tree, not a new mechanism. A generic native-plugin
event/callback ABI was explicitly deferred: it means a frozen C ABI,
versioning, and a plugin crash taking down the editor, and zoe already
embeds Lua (`ls.conf`/`shell.conf`) if scripted extension is wanted
later. See roadmap.md for the module breakdown.

**Native `.so` grammars, not WASM, for v1.** WASM grammars are one
portable artifact with centralised versioning, but pull wasmtime (a large
C/Rust dependency) into zoe and parse slower. Native `.so` costs
per-platform builds and ABI-version skew between zoe's vendored
libtree-sitter and a grammar generated by a newer tree-sitter CLI —
handled by checking `ts_language_abi_version()` and refusing with a clear
message rather than crashing. The loader is shaped so a WASM backend can
be added later without touching callers.

**Incremental reparse, edit ranges journalled on `Buffer`.** tree-sitter
is built for incremental reparse (`ts_tree_edit` + the old tree). `Buffer`
now keeps a small journal (`Buffer.Edit`: start/old-end/new-end as byte
offsets *and* row/column points, `track_edits` gated so it costs nothing
when highlighting is off) that `ui.zig` replays onto the retained tree
before reparsing against it. A whole-buffer `parseString` remains the
fallback: the first parse, a language switch, or a journal that overflowed
its 512-entry cap. The repaint is narrowed to match: `getChangedRanges`
between the old and new trees, unioned with the directly-edited lines,
gives the set of rows to redraw — so typing inside a function no longer
retransmits the whole visible pane. A change to the line count, or an
injection layout that shifted, still repaints the pane in full (the parse
stays incremental — that is the win).

**Injected languages.** After the primary parse, `injections.scm` (when
the grammar dir ships one) is run over the tree to find embedded regions:
a fenced code block in Markdown, the `(inline)` span of every Markdown
paragraph, an HTML block. Each region is parsed with its own grammar over
just its byte ranges (`Parser.setIncludedRanges`), and `lineSpans` paints
the child layers over the primary one so a deeper layer's colour wins the
bytes it covers. `@injection.language` captures and `#set!
injection.language "x"` directives are both honoured; a small alias table
maps the spellings queries use (`markdown.inline`, `py`) to grammar-dir
names. Injection recurses to `max_injection_depth` (3) so Markdown block →
`markdown_inline` → `html` works. Child trees are rebuilt from scratch on
each reparse rather than kept incremental — they are small. Deliberately
skipped for now: `injection.combined` (every content region of a language
is parsed on its own) and `locals.scm`.

**Config is Lua, like the other clients.** `~/.config/glyphwire/zoe.conf`
assigns a `config` table (`theme`, `languages`, `grammar_dirs`,
`injections`), matching `ls.conf` / `host.conf`, rather than a separate
declarative manifest format. Absent file = seven bundled grammars (zig,
json, c, python, toml, markdown block + `markdown_inline`), a built-in
dark theme, and injection on. `config.injections = false` is the escape
hatch.

**Predicates we can't evaluate disable their pattern.** `#eq?` /
`#any-of?` (and negations) are evaluated; `#match?` / `#lua-match?` need a
regex engine zoe doesn't have, so a pattern carrying one is dropped
entirely — under-highlighting (a name that isn't specially coloured)
rather than mis-highlighting (every identifier painted as a constant).
