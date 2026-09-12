# Architectural review: panes should be contexts, not layers

Status: review of `worktree-gmux` (10 commits over `dev` at `5ec395e`).
Conclusion: the gmux v1 model is built at the wrong level of the object
model and cannot be finished as designed. This documents why, and what
the context-pane model needs in order to replace it.

## 1. What the object model is today

Three levels, only one of which has geometry.

**`Session`** (`src/core.zig:5120`) is a *stack*, not a tree. It holds
every `Context` plus `visible_stack`, and exactly one context is
rendered: the top. Its only spatial concept is z-order in time. It
generalises alt-screen from one alternate buffer to N persistent ones,
which is what it was designed for and all it does.

**`Context`** (`src/core.zig:4183`) is a complete surface: a root layer
with its own scrollback ring and VT state, N composited `create_layer`
layers, a split tree over those layers, its own clipboard, its own
`caret_layer`, its own `window_scrollbar` flag, and ownership/culling
against the connections that created it. It is, in every respect that
matters, "a terminal".

**`Layer`** (`src/core.zig:1040`) is a cell grid: a ring buffer, a
position, a viewport, a scroll offset, and (with `pty_mode`) a resident
escape-sequence machine.

The split tree (`src/core.zig:4073` onward) lives *inside* a context and
its children are **layers**. So the system has exactly one place where
rectangles get divided, and it sits one level below where a multiplexer
needs it.

## 2. Why panes-as-layers cannot be finished

Each of these is checkable against the code, not a matter of taste.

### (a) A pane cannot host a full-screen program

`create_context` pushes onto the session stack and republishes
visibility (`core.zig:5216`, `core.zig:5206`); the host renders
`server.ctx`, which is always `session.visibleContext()`
(`server.zig:278`, and ~30 reads in `host/render.zig`). So when anything
inside a gmux pane opens its own context (`zoe`, `gw-view`, an
alt-screen program, the shell's own full-screen modes), it does not fill
*the pane*. It replaces *the window*, and gmux's context disappears
underneath it.

There is no pane-scoped alt-screen available, because alt-screen is a
session-level concept and a pane is not a session-level object. This one
alone is fatal: a multiplexer whose panes cannot run full-screen
programs is not a multiplexer.

### (b) A connection cannot say which context it belongs to

`Dispatcher.initForConnection` (`dispatch.zig:873`) inherits
`session.visibleContext()`. `GLYPHWIRE_CTX` is written in three places
(`host/main.zig:367`, `agent/main.zig:115`, `shell/main.zig:275`) and
parsed in none. Placement is therefore decided by whatever happened to
be visible at the instant of `connect()`.

That is not a race that can be closed, only narrowed. A `Client` and its
`InputListener` are two separate connections that inherit
independently. Two panes spawning concurrently, or any `create_context`
landing between them, splits a single program across two contexts. The
last three commits on this branch (`f9be878` to `d7f89f4` to `5ec395e`)
are three successive attempts at one symptom of this.

### (c) Input routing had to be reinvented for layers

Contexts already have addressing: `active_ctx` per connection, and a
visibility gate in `broadcast` (`server.zig:399-412`). Layers have
none. So the branch added `Dispatcher.input_layer`, `set_input_layer`,
`forward_key`, `forward_text`, `Connection.input_layer`,
`Server.deliverToInputLayer`, and a `subscribe` parameter, to build for
layers what contexts get for free.

It is also strictly weaker than what it imitates.
`deliverToInputLayer` (`server.zig:427`) has no visibility gate at all,
and says so in its own doc comment: a backgrounded gmux still forwards
keystrokes into its panes. Fixing that means adding a context-visibility
check to a layer-addressed path, at which point the layer addressing is
doing no work.

### (d) One layer, two writers

A gmux pane layer is written by gmux draining the PTY
(`ui.zig:232`, `writeTextOn`) *and* by the embedded `gw-shell` drawing
through `Client.default_layer`. Both channels are live at the same time
and nothing arbitrates between them. That is the "text laying on top of
each other" symptom, directly.

The PTY channel exists for non-aware children, the protocol channel for
aware ones, but the pane has no way to know which one is currently in
charge, and a `gw-shell` in the pane flips between the two every time it
launches a child.

### (e) Sizing is session-wide

`reportResize` calls `Session.resizeAll` (`server.zig:651`,
`core.zig:5331`), which gives *every* context the full window size. A
context cannot be pane-sized today. That is exactly the property the
proposed model needs.

### (f) Session singletons have no pane scope

Selection (`host/selection.zig`), the window scrollbar, the divider
cache (`host/panes.zig`), `Server.ctx`, and the visibility stack are all
"the one visible context". None of them have a notion of "which pane".

### (g) Remote sessions do not compose

`host/remote.zig` is a single `Remote` per process, and every mux
channel becomes a connection to the same `Server`, inheriting the same
visible context (`remote.zig:230`). There is no way to say "this
trunk's clients live in that pane". `docs/ideas.md:52` already wants
more than one.

## 3. The proposed model, stated precisely

Promote geometry one level up, and let a pane hold a context *stack*
rather than a single context.

- **`Session` gains a split tree whose leaves are panes.** Same shape as
  `core.Split`, different target union: `{ pane, split }`. The window is
  laid out from its root.
- **A pane owns a visibility stack of contexts.** This is the load-bearing
  detail. If a pane held exactly one context, defect (a) would come
  straight back: a full-screen program in a pane still needs somewhere
  to put its own context. With a per-pane stack, `create_context` covers
  the pane and pops back to the shell's context on exit, which is
  alt-screen semantics restored at the right scale.
- **`Context` gains an origin and a size independent of the window.** It
  stops being "the window" and becomes "the contents of a pane". Its
  *internal* split tree over layers keeps working exactly as it does now,
  so zoe's sidebar/buffer/command-line arrangement is untouched.
- **gmux becomes a context manager**, not a layer painter: it asks the
  server to divide the window into panes and to seat a program in each.

Naming: two levels of "split" with different child types will be
confusing in the code and in `api.md`. Worth separating the vocabulary
up front (`frame`/`pane` at the window level versus `split`/`layer`
inside a context, or `window_split` versus `layer_split`).

## 4. What has to change

### Core (`src/core.zig`)

- `Session`: add `panes`, `pane_splits`, `root_pane_split`. Replace the
  single `visible_stack` with a per-pane stack. `visible_handle` /
  `visible_gen` become per-pane, plus a session-level layout generation
  counter for the pane tree.
- Pane layout maths: near-duplicate of `layoutSplit` /
  `moveDivider`. Making the existing one generic over its target union
  would be the clever option; duplicating roughly 80 lines is the
  explicit one and is easier to read at both levels.
- `Context`: add an origin, stop assuming window dimensions.
  `resizeAll` becomes "lay out the pane tree, then resize each pane's
  context stack to its pane's rect."

### Protocol (`src/dispatch.zig`, `docs/api.md`)

- **Connect-time addressing.** A connection must be able to name the
  context or pane it belongs to, at `subscribe` time, atomically, in the
  way `input_layer` was folded into `subscribe` in `5ec395e`. Honouring
  `GLYPHWIRE_CTX` is the minimum; a `GLYPHWIRE_PANE` naming a pane is
  better, because then a spawned program lands correctly by construction
  regardless of what else is visible.
- New messages mirroring the layer-split catalog:
  `create_pane_split`, `set_pane_split_children`, `set_root_pane_split`,
  `destroy_pane_split`, `move_pane_divider`, `create_pane`,
  `destroy_pane`, plus a `pane_layout` event. The shapes are already
  proven at the layer level, and `gmux/layout.zig`'s minimal-edit
  discipline transfers unchanged.
- **A manager role.** Worth doing, and cheap: a connection requests
  `window_manager` (via `subscribe` or a dedicated call) and the server
  grants it to at most one connection at a time; without it, the pane
  split calls error. Beyond the obvious safety argument, it makes "who
  owns the window layout" a question with a runtime answer, and it gives
  a natural place to hang "the manager exited, collapse back to one
  pane".

### Server (`src/server.zig`)

- `Server.ctx` as a single `*Context` is the assumption to remove. It
  becomes per-pane lookup, and the host iterates panes.
- `broadcast`'s visibility gate becomes a **focus** gate: raw input goes
  to the connection whose context is visible in the *focused* pane.
  `input_layer`, `forward_key`, `forward_text` and
  `deliverToInputLayer` can then be deleted outright.
- `reportKey` / `reportText` / `reportMouse*` route by focused pane;
  mouse events additionally need pane-relative cell coordinates.

### Host (`host/`)

- `render.zig`: each `server.ctx` read becomes a loop over panes, and
  `geometry.layerRect` takes a pane origin instead of the global
  `content_pad_px` (`geometry.zig:66`, `:175`). Mechanical, but roughly
  40 sites.
- `panes.zig`: the divider cache and drag logic is genuinely reusable at
  the window level; it needs a sibling instance, not a rewrite.
- `scroll.zig`, `selection.zig`, `caret.zig`: pane-scoped. Selection is
  the subtle one; disallowing cross-pane selection in v1 is the sane
  call.
- `window_sizing.zig`: resize drives the pane tree first, then each
  pane's contexts.

### gmux

- `gmux/layout.zig` survives nearly unchanged. It is a pure binary tree
  carrying `wire_id`s, and only the names of the wire calls it drives
  change. That is a real asset to keep.
- `gmux/pane.zig`, the PTY drain loop, `writeTextOn`, the `pty_mode`
  wiring and the `input_layer` handshake all go away for
  glyphwire-aware programs, which draw themselves into their own pane's
  context.
- A plain `bash` still needs a PTY and a VT interpreter. That does not
  disappear, it moves. Either gmux keeps a PTY path that writes into the
  pane context's *root layer* (a legitimate single-writer arrangement,
  unlike today), or the server grows a pty-backed context. Keeping it in
  gmux and making it explicit is simpler, with one rule that kills
  defect (d): **a pane is either program-drawn or PTY-drawn, decided at
  spawn, never both.**

### Remote

- `Remote` becomes one per trunk, held in a map, each associated with the
  pane it was launched into; every channel connection gets that trunk's
  pane as its default. That is the whole remote-side change, and it
  delivers `ideas.md:52` as a side effect.
- The trunk is deliberately *not* a context boundary: a remote
  `gw-shell` can still `create_context` for alt-screen inside its pane.

## 5. Sequencing

Ordered so each step is independently useful and independently testable.

1. **Connect-time context/pane addressing.** Small, self-contained,
   removes the entire race class in (b), and is correct regardless of
   what happens to the rest of this plan.
2. **Context origin + size independent of the window.** No new messages.
   Provable by rendering the existing shell context into a half-window
   rect.
3. **Session pane tree, layout, and multi-context host render.** The big
   one. Still no client-facing messages: hard-code a two-pane split in
   the host to prove it.
4. **Pane-split protocol and the manager role.**
5. **gmux ported onto it**; delete `input_layer` and the `forward_*`
   family.
6. **Per-trunk remote panes.**

## 6. Disposition of the current branch

Recommendation: do not land it as the gmux design, and do not discard it
either. It splits cleanly.

**Keep (correct on their own terms, still needed):**

- `3435404` `pty_mode` layer property. Needed wherever a PTY feeds a
  grid, at any level.
- `f76faea` `set_caret_layer`. Still how a context points the caret at a
  non-root layer.
- `126890c` per-layer scrollback wheel routing.
- The `src/pty.zig` half of `a373a05`: the `exited` flag making
  `reaped`/`wait` idempotent. A real ECHILD bug fix, unrelated to
  architecture.
- `f2878dd` shell foreground pty adopting `pty_mode`.
- `gmux/layout.zig` as a file.

**Drop or rework:**

- `f9be878`, `d7f89f4`, `5ec395e`: the whole `input_layer` /
  `forward_key` / `forward_text` apparatus. It exists only to compensate
  for panes not being contexts.
- `bb048d9`'s gw-shell `set_input_layer` wiring.
- `00446ee`'s panes-as-layers core in `gmux/ui.zig` and `gmux/pane.zig`.

Landing the keepers as a small branch onto `dev` and restarting gmux on
the context-pane model is cleaner than rebasing a 10-commit branch into
something structurally different.

## 7. Open questions

1. **Pane holds a stack of contexts, or exactly one?** Recommendation: a
   stack, for the alt-screen reason in section 3.
2. **Who spawns processes: gmux, or the server via a `spawn_in_pane`
   op?** Server-side spawning is what would eventually enable
   detach/reattach and makes "the host owns the setup" literal;
   gmux-side keeps process management out of the server. Leaning
   gmux-side for now.
3. **Are a manager's pane weights advisory?** "The host owns the context
   setup, so it can force the sizes" suggests the host may override.
   Needs deciding before the protocol shape is fixed.
4. **Naming for the two split levels.**
5. **Non-glyphwire programs: gmux-owned PTY, or a server-side pty-backed
   context?**
