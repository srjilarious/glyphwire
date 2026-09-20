<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Wire API Reference

The concrete enumeration of glyphwire's message catalog — named as an
open item in decisions.md ("Message catalog... named in concept but not
enumerated concretely yet"). This doc is the reference; decisions.md
stays the place for *why* each shape was chosen. See decisions.md's
Transport & Wire Format and Protocol Shape sections for framing basics
(`Content-Length` + JSON-RPC 2.0 request/response/notification) before
reading this.

## Status legend

- ✅ **Implemented** — built and tested (see `src/dispatch.zig`).
- 🔶 **Planned** — shape decided in decisions.md, not yet built.
- ⬜ **Open** — direction, params, or even existence not yet decided;
  listed here as a placeholder so the catalog's gaps are visible, not as
  a spec.

## Context

A **context** is an independent, full-window surface — its own root
layer, split tree, layers, tables (see decisions.md's Object Model and
`core.Session`). The server holds one `Session`: a registry of contexts
plus a **visibility stack**, only the top of which glyphwire-host
renders. This generalises the classic terminal alt-screen
(`smcup`/`rmcup`) from one alternate buffer to N persistent contexts —
switching away never destroys one, so a shell's prompt and scrollback
are untouched under a full-screen editor and reappear when it exits.

The **root context** (handle `0`, `core.root_context_handle`) is the one
the server starts with — the shell's. It's never culled, can't be
destroyed, and sits permanently at the bottom of the visibility stack.

A connection **inherits** whichever context is visible when it's
accepted, and every `layer?`-scoped message it sends resolves against
its *current* context. `create_context` and `attach_context` change
which context that is (per-connection ambient state, not a param on
every message). `GLYPHWIRE_CTX` is set by the host/shell but nothing
parses it yet — inherit-the-visible + `attach_context` is the discovery
path for now.

Within that context, an omitted `layer` means the connection's
**surface**: the root layer, unless it sent `attach_layer` (below). That
is how a program launched inside someone else's panel — `gw-ls` run from
the shell in salacommander's Ctrl+` panel — draws *in the panel* rather
than on the root layer underneath it, with no layer-aware code of its
own. Every client library sends it at connect time from
`GLYPHWIRE_LAYER`, exactly as it sends `attach_pane` from
`GLYPHWIRE_PANE`. A connection that never attaches one is unaffected:
omitted still means root.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| *(inherit)* | — | — | — | ✅ a new connection acts on whatever context is visible at accept time |
| `create_context` | request | `width?, height?, scrollback_rows?, window_scrollbar?` | `{context}` (handle) | ✅ allocates a fresh context (its root layer defaults to the visible context's size), **shows it immediately**, and retargets the issuing connection onto it — later `layer?`-scoped messages from this connection now draw on the new context, not the shell's. The connection becomes its first **owner**: the context (and everything in it) is culled once every owning connection disconnects, so a full-screen program that dies without `destroy_context` doesn't leave its surface stuck on screen. Icons/images resolve through the root context's catalog, so `draw_icon` names the host registered still work. `window_scrollbar` (default `true`) is whether glyphwire-host draws its always-on right-edge scrollbar for this context — a pure-TUI client whose panes carry their own `scrollbars` passes `false` so the window doesn't show a permanently full, inert bar. The gutter the bar would occupy stays reserved — the flag decides only whether the bar is *painted*, never the grid size, so creating or destroying such a context emits no `resize` and can't reflow the other contexts in the session. Toggle it later with `set_window_scrollbar` |
| `destroy_context` | notification | `context` | — | ✅ frees a context and every layer/split/table/image in it; if it was visible, visibility pops to whatever context was under it (the alt-screen auto-restore). **Ownership-checked** like `destroy_layer`: honored only from a connection that owns the context (created it, or `adopt_context`'d it) — a non-owner's call reports `ContextPermissionDenied` and nothing is touched. The root context reports `RootContextImmutable`; an unknown handle `UnknownContext`. An in-process caller bypasses the check |
| `activate_context` | notification | `context` | — | ✅ makes `context` the visible one **without** changing which context the issuing connection draws on — a client backgrounds itself by activating the root context (handle `0`) and restores itself by activating its own handle again. Moves the handle to the top of the visibility stack (it's there once, wherever it was). `UnknownContext` for an unknown handle; a no-op if it's already visible |
| `attach_context` | notification | `context` | — | ✅ retargets the issuing connection onto an *existing* context (`create_context` does this for a new one) — every later `layer?`-scoped message resolves against it, and, for a subscribed connection, the raw input streams it receives now follow that context's visibility. The primitive a paired `InputListener` uses to join the context its `Client` created. Ownership is untouched (attaching isn't adopting). `UnknownContext` for an unknown handle |
| `attach_layer` | notification | `layer?` | — | ✅ declares the issuing connection's **surface**: the layer every later message that omits `layer` resolves to, in place of the context's root. `null` (or the root handle) restores root. Needs no role — like `attach_pane`, saying where you live is not a privilege — and is untouched by ownership: attaching is not adopting, and the layer's creator is still the one who may destroy it. Changing context (`create_context` / `attach_context`) clears it, since a layer handle only means anything inside the context that owns it, and a surface whose layer is destroyed falls back to root rather than failing every later message. `UnknownLayer` for a handle this context doesn't have. What `gw-shell --embed` passes its children as `GLYPHWIRE_LAYER`, so an unmodified client draws into the panel it was launched from |
| `adopt_context` | notification | `context` | — | ✅ adds the issuing connection to `context`'s owner set, so it outlives its original creator disconnecting as long as this connection stays up (and this connection may then `destroy_context` it). The context-level mirror of `adopt_layer`. `UnknownContext` for an unknown or root handle |
| `set_window_scrollbar` | notification | `visible` | — | ✅ turns glyphwire-host's always-on right-edge scrollbar on or off for the issuing connection's active context — the runtime counterpart of `create_context`'s `window_scrollbar`. Changes nothing else; the host picks it up on its next repaint |
| `set_caret_layer` | notification | `layer?` | — | ✅ points glyphwire-host's blinking caret at a `create_layer` layer for the issuing connection's active context, instead of the root layer's live cursor (`core.Context.caret_layer`). `null` restores the root cursor. The host positions the caret through that layer's pane bounds, viewport and scroll offset, honours the layer's own DECTCEM cursor-hide, and hides it while the pane is scrolled back into its own history or the cursor is outside the visible viewport. An unknown or root handle reports `UnknownLayer` and leaves the setting unchanged; destroying the tracked layer clears it. For a multi-pane client (`gmux`) whose focused pane is a non-root layer fed by that pane's PTY — re-sent on every focus change |
| `set_caret_visible` | notification | `visible` | — | ✅ shows or hides glyphwire-host's caret for the issuing connection's active context (`core.Context.caret_visible`, default `true`), whichever layer it tracks (root cursor or `set_caret_layer`'s). For a program with no text insertion point — `gw-read` and `gwmd` send `false` right after `create_context`. Deliberately separate from a layer's DECTCEM cursor-hide (`ESC [ ? 25 l`): that flag belongs to whatever PTY program is writing the layer and `ESC [ ! p` resets it, while this one only changes on this message. Either one hides the caret. Batchable |

Raw input events (`key`, `text`, `mouse_button`, `mouse_move`) are
delivered **only to connections whose current context is the visible
one** — a backgrounded full-screen editor stops receiving keystrokes
meant for the shell that's now on screen, and vice versa. Every other
server→client event (`resize`, `shutdown`, `layout`, `scroll`,
`selection`, `context`, …) still fans out to all subscribers regardless, so a
backgrounded client can keep its panes current for when it's shown
again.

## Layer

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `create_layer` | request | `width?, height?, scrollback_rows` | layer handle | ✅ always parented to the root layer (no `parent`/`context` params — there's only one context per decisions.md's current scope, and deeper nesting isn't exercised yet); `width`/`height` default to the root layer's own size. The connection that issues this becomes the layer's first **owner** — see decisions.md's Layer ownership & lifecycle: the layer is culled once every owning connection has disconnected, so a program that dies without `destroy_layer` doesn't leave its content stuck on the host |
| `destroy_layer` | notification | `layer` | — | ✅ frees the layer and drops it from compositing; the root layer (handle 0, i.e. an omitted `layer` elsewhere) can't be destroyed this way — an unknown or root handle both just report `UnknownLayer`. **Ownership-checked:** honored only from a connection that owns the layer (created it, or `adopt_layer`'d it); a non-owner's call reports `LayerPermissionDenied` and the layer is untouched. An in-process caller (glyphwire-host, headless `server/main.zig`) owns nothing and bypasses the check |
| `adopt_layer` | notification | `layer` | — | ✅ adds the issuing connection to `layer`'s owner set, so the layer outlives its original creator disconnecting as long as this connection stays up, and this connection may then `destroy_layer` it. Errors `UnknownLayer` for an unknown or root handle; a no-op for an in-process caller. For handing ongoing responsibility for a layer from one process to another |
| `get_property` | request | `layer?, property` | property value | ✅ (`cursor`, `revision`, `position`, `cell_position`, `size`, `viewport`, `scroll`, `scroll_offset`, `scrollbars`, `content_extent`, `scroll_mode`, `background`, `visibility`, `opacity`, `pty_mode`, `profile`) |
| `set_property` | notification | `layer?, property, value` | — | ✅ (`cursor`, `position`, `cell_position`, `size`, `viewport`, `scroll_offset`, `scrollbars`, `content_extent`, `scroll_mode`, `background`, `visibility`, `opacity`, `pty_mode`) — a write to a get-only property, or to `size`/`visibility`/`opacity` on the root layer, reports `ReadOnlyProperty`; `content_extent` on a `scroll_mode: "host"` layer reports `WrongScrollMode` |
| `raise_layer` | notification | `layer, above?` | — | ✅ moves `layer` up the compositing order: directly above `above`, or to the very top when omitted. Creation order is only the *initial* stacking, so this is what puts a completion popup created early back over a sidebar created later. The root layer is never in the order (it is always the bottom of the stack), so naming it as either handle reports `UnknownLayer`, same as `destroy_layer`. Raising a layer above itself is a no-op, not an error; a rejected restack leaves the order exactly as it was |
| `lower_layer` | notification | `layer, below?` | — | ✅ the mirror of `raise_layer` — directly below `below`, or all the way to the bottom when omitted |
| `get_cells` | request | `layer?, view_offset?` | full row-major cell snapshot (`cols, rows, revision, cells`) | ✅ each cell also reports `fg_icon?` (an icon composited *over* the background — `draw_icon`'s `foreground: true`, and every table body icon; same shape as `bg_icon`), `metadata_id?` (see Metadata below), `focus` (whether the cell is its metadata span's focus cell — see `tag_metadata` / `find_metadata`), and `wide?` alongside `bg`/`bg_image`/`bg_icon` — just the id/handle, not the resolved JSON, same "handle, not content" treatment `bg_image`/`bg_icon` give image/icon handles. `wide` is `"lead"` on the left cell of a 2-cell East Asian wide character (it holds the grapheme in `g`), `"spacer"` on its blank right neighbour (empty `g`, but it carries the lead's `bg`/`metadata_id` so a background spans the pair and a hit-test on either half resolves the same), and absent for an ordinary 1-cell character. The server computes width from Unicode East Asian Width (`W`/`F` wide, `A` treated as narrow) — `write_text` itself is unchanged. `view_offset` (default 0 = the live viewport) reads that many rows of scrollback above the live viewport, so a client can snapshot exactly what's on screen while the host is scrolled back |
| `scroll_view` | request | `layer?, offset?, delta?` | `{offset, max}` | ✅ moves the layer's scrollback view offset (`offset` absolute rows, then `+delta`), clamped to `0..max` (`= history_len`); returns the result. Passing neither `offset` nor `delta` is a pure query. Also broadcasts a `scroll` notification (see Input) to other subscribers. This is how a client scrolls the host's view — glyphwire-shell's browse cursor drives it when it walks past the top of the window; the host's own mouse wheel / scrollbar move the same state in-process |

Every message above whose params include `layer?` defaults to the root
layer when omitted, same convention `row?`/`col?` already use for "at the
cursor" — see decisions.md's Layer section. `write_text`/`insert_cells`/
`delete_cells`/`clear`/`draw_image`/`draw_icon`/`draw_box` (below) all
accept the same optional `layer` param too.

**Property names** (the `property` argument to `get_property`/`set_property` —
one generic mechanism per decisions.md rather than a bespoke get/set pair
per property):

| Property | Meaning | Status |
|---|---|---|
| `cursor` | `{row, col}` | ✅ |
| `revision` | `{revision}` — get-only, bumped once per `write_text` call | ✅ |
| `size` | `{cols, rows}` — this is what answers "get window size" for the **root** layer, since a Context's base size **is** its root layer's default size; get-only there (a client reads it, or subscribes to `resize` below, but the host owns the window size). **Settable on a `create_layer` layer**: a TUI that splits the window into a sidebar and a buffer pane has to reflow both when a `resize` arrives, and destroying and recreating the layers would throw away their handles, tables and content. The resize is bottom-anchored like every other (see below), a zero `cols`/`rows` is clamped to 1 rather than rejected, and setting it also stops the layer tracking the context's base size — a client that picks its own size has taken over the layout | ✅ |
| `position` | `{x, y}`, pixel-precise, relative to the layer's parent (the root layer for every `create_layer`-made layer today) | ✅ |
| `cell_position` | `{row, col}` — the same placement as `position` but in whole grid cells, resolved server-side against the session's cell metrics. A TUI lays itself out on the cell grid, and unlike a client that reads `get_cell_metrics` and multiplies once, a layer placed this way is *sticky*: the server re-derives its pixel position when the cell size changes (a Ctrl+`+` / Ctrl+`-` font step), so a sidebar keeps its column instead of drifting half a cell off. Setting `position` in pixels un-sticks it again — pixel placement is the primitive, this is the convenience on top. The getter always has an answer: the cell that was set for a cell-placed layer, else the cell the layer's top-left corner lands in | ✅ |
| `viewport` | `{cols, rows}` — how much of the layer's **content grid** the host draws. Zero on an axis means the whole grid on that axis, which is the default and what every layer did before viewports existed, so the concept costs nothing until a client asks for it. This is what makes a pane distinct from its content: a file tree with 500 entries and a longest name of 90 columns is a 90×500 layer (`size`) shown through a 30×40 viewport, and the host scrolls the window over it — no wire round trip in the middle of a mouse wheel. Clamped to the content, so there is no scrolling into blank space. A layer inside a split tree has this set for it by the layout | ✅ |
| `scroll_offset` | `{row, col}` — where the `viewport` sits within the content grid, clamped server-side to `size - viewport` on each axis (or `content_extent - viewport` on a self-scrolling pane, see below). Get also returns `max_row`/`max_col`. This is the layer's scroll position, and the host moves it directly on a wheel tick or a scrollbar drag (broadcasting `scroll_offset`, below) rather than asking the client to. Distinct from `scroll`, which is the terminal-style *scrollback ring* view: the two compose, `scroll` picking which rows are live and `scroll_offset` the window over them. A layer created with `scrollback_rows: 0` — every pane in a TUI — only ever uses this one | ✅ |
| `scrollbars` | `{vertical, horizontal}` — which bars the host draws inside this layer's own bounds, opt-in per axis. Get returns the two flags plus `row`/`col` and `max_row`/`max_col`, i.e. everything needed to draw or interpret a bar; the four derived fields are ignored on a set. Opt-in rather than automatic because a statusline or a popup can easily have content wider than its pane and should still not sprout a bar. A bar is also skipped on an axis with nothing to scroll. The thumb's length is the visible fraction of the **effective** content — `viewport + max_row` (or `_col`), so a self-scrolling pane's virtual `content_extent` drives it, not the viewport-sized real grid. A layer's bars composite **with the layer**, straight after its own cells, so a layer later in `layer_order` covers them the way it covers that layer's content (they used to be a final pass over everything, which drew gw-read's page bars over the OCR dialog floating above it). Distinct from the window's own right-edge scrollbar, which is the root layer's scrollback and is opt-out per context (`create_context` / `set_window_scrollbar`) | ✅ |
| `scroll_mode` | `{mode}` — `"host"` (default) or `"client"`: which of the two **viewport** scroll models the layer uses. **host**: the content grid holds the whole content and the host slides `viewport` over it; `scroll_offset` moves the real window; `content_extent` is refused with `WrongScrollMode`. **client**: the program redraws its visible rows itself and reports the whole size as `content_extent`; `scroll_offset` is a virtual position the host only reports back, and the real grid never moves. Switching resets both offsets and drops any `content_extent`. Both are distinct from the root layer's terminal **scrollback** (`scroll` / `scroll_view` / `view_offset`), a ring of rows that scrolled off the top. The model used to be implied by whether `content_extent` was set, which silently froze a host-scrolled picture (gw-read's pan) the moment a client set one; an unknown mode reports `InvalidScrollMode` | ✅ |
| `background` | `{color?}` — the colour every transparent cell of the layer composites as, painted by the host under the whole viewport; omit `color` to clear it (the default: unwritten cells show what is behind the layer). What makes a panel, a status bar or the rows past the end of a list opaque without writing spaces into them | ✅ |
| `content_extent` | `{cols, rows}` — a **virtual** content size for a pane that scrolls *itself* (`scroll_mode: "client"` only): a TUI editor's buffer, whose real cell grid is only viewport-sized (a full grid for a large file would be hundreds of megabytes) so it redraws its visible rows on every scroll rather than letting the host slide a viewport over a big grid. Setting this tells the host how big the whole content really is, so it draws a proportional scrollbar and turns a wheel tick or thumb drag over the pane into a `scroll_offset` broadcast the client then obeys and redraws against — on such a layer `scroll_offset` moves this virtual position, and the real (viewport-sized) grid never moves. `{0, 0}` clears it (the layer stays client-scrolled, over its real grid). Get reports the effective content size: the virtual one if set, else the real `size`. `zoe`'s buffer pane sets it from the file's line count | ✅ |
| `pty_mode` | `{enabled}` (bool, default `false`) — whether this layer **keeps** its escape-sequence machine, alternate-charset designation and SGR colour "pen" across `write_text` calls instead of resetting them at each call boundary (the default, see `write_text` below). A pane fed one PTY child's byte stream wants it on: a `CSI` sequence a `read()` split across two chunks then finishes parsing on the next `write_text` instead of drawing its tail as literal text, and an `ESC [ 31 m` stays in effect until the program resets it. Off by default because the shell's prompt path interleaves its own writes with a mirrored program's on the same layer, where the call-scoped reset is what stops an interrupted colour or half-open OSC from poisoning the prompt. Setting it — to **either** value — also clears that transient state, so a client re-sends `pty_mode` after a foreground program exits as a clean re-arm. `gmux` sets it on every pane; `glyphwire-shell` sets it on the root layer around a foreground command | ✅ |
| `clip` | clip rect | 🔶 |
| `scroll` | `{offset, max}` — how far the on-screen view is scrolled back into this layer's cell-grid scrollback ring (`offset` rows above the live tail, out of `max` = `history_len` retained). Get-only through `get_property`; move it with `scroll_view` (above), which also broadcasts a `scroll` notification. `offset == 0` is the live tail | ✅ |
| `visibility` | `{visible}` — whether glyphwire-host composites this layer at all. A hidden layer keeps every cell, table and metadata id it had; the renderer just skips it (and keeps its cached quad batch, so showing it again costs no rebuild). That's what a toggled sidebar wants — `destroy_layer` plus a rebuild loses the tree's scroll position and its metadata ids for nothing. Non-root only: hiding the root layer would blank the session with no wire path back, the same reason `destroy_layer` refuses it, so root reports `ReadOnlyProperty` | ✅ |
| `opacity` | `{value}` — how opaque glyphwire-host composites this layer, `0.0`..`1.0`, default `1.0`. The factor multiplies the alpha of everything the layer contributes: background fills, text, icons and image cells alike, so the whole layer fades as one and what is behind it shows through. Distinct from `visibility`, which is the all-or-nothing form — a hidden layer contributes no quads at all, while a layer at `0.5` still occupies its bounds and still takes the mouse; that is the difference between "get this panel out of the way" and "let me see through it" (`gw-read`'s OCR dialog uses both, on `\` and on a held `z`). Out-of-range values are clamped rather than rejected, and a `NaN` is taken as `1.0`, so a client computing a fade cannot accidentally lose its layer. Non-root only, the same reason `visibility` is: a root faded to `0` would blank the session with no wire path back, so root reports `ReadOnlyProperty`. **Renderer note:** the factor is baked into the cached vertex colours of the coloured batches at build time (a change bumps the layer's render generation, which invalidates them) and applied to the textured ones through the texture shader's `tint` uniform, which has no per-vertex colour channel to bake into | ✅ |
| `profile` | `{active, fps, skips_per_sec, phases: [{name, avg_ms, p95_ms, max_ms}], counters: [{name, per_frame}]}` — **get-only, host-wide** (carries no `layer`; an omitted `layer` is fine). glyphwire-host's frame-timing profiler, refreshed each loop iteration while `host.conf.lua`'s `profile` is on. `active` is `false` and every other field zero when the host isn't profiling. Every number is averaged over the last `profile_window_ms` (default 1s) and republished — an FPS-counter-style bucket, not a lifetime average. `phases` are `frame` (whole-iteration wall period), `wait` (event-loop block), `update`, `redraw_check`, `sync_batches`, `draw`, `present`; `counters` (`per_frame` = windowed mean per composited frame) are `layers_rebuilt`, `draw_calls`, `quads`. Meant for `glyphwire-probe`; the host also has an on-screen HUD (Ctrl+Shift+P) and an optional periodic `std.log` summary | ✅ |

Live size changes arrive separately as a `resize` event (see Input
below) rather than requiring the client to poll `get_property(layer,
"size")` — polling still works, but a glyphwire-aware program that cares
about resizes should subscribe instead. The `scroll` offset has the same
poll-vs-subscribe split: a `scroll` notification fires whenever it moves
(from `scroll_view` or the host's wheel/scrollbar).

When the host window is resized, the root layer (and every
`create_layer` layer made with no explicit size, which had been
mirroring the root's dimensions) is resized with it. Content is
**anchored to the bottom row**: growing the height pulls previously
scrolled-off rows back down out of scrollback into the taller viewport
(blank filler at the top only once scrollback is exhausted); shrinking
pushes the top rows up into scrollback rather than discarding them, so a
later grow restores them — only rows overflowing the layer's
`height + scrollback_rows` capacity are evicted, oldest first. Width
changes clip or blank-pad each row on the right with no reflow. A layer
created at an explicit size (a notification popup, etc.) keeps its size.

The **cursor moves with the content**, by the same height delta, and is
then clamped into the new viewport — it is not merely clamped in place.
So a client that reads `get_cursor` after a resize (glyphwire-shell, to
decide where its next prompt goes) finds it on the row it was on before,
not on whatever retained output has since slid under that row index.

## Splits

A split tree is the host's answer to "where do the panes go". A client
describes the arrangement once; the host computes every layer's bounds
from it, keeps them correct across a window resize, and owns the divider
drag — so a TUI doesn't re-implement pane maths, and two of them behave
the same way. See decisions.md's Layer section for why this is
server-side.

The tree lays out over the whole context. The **root layer is never a
split child**: it's the shell's scrollback, drawn underneath at a fixed
origin, and a full-screen program's panes simply cover it — the
alt-screen story without needing `create_context`.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `create_split` | request | `axis` (`"row"` — children left to right, vertical dividers; `"column"` — top to bottom, horizontal dividers), `resizable?` | split handle | ✅ an unknown axis reports `InvalidSplitAxis`. A fresh split draws and lays out nothing until it has children *and* is reached from `set_root_split`. `resizable` (default `true`) is whether the user may drag this split's dividers — `false` reserves **no** gap between the children (the row/column returns to content), draws no grab band, and makes `move_divider` a no-op, which is what a structural split like an editor's buffer-area-over-command-line wants |
| `destroy_split` | notification | `split` | — | ✅ frees the container; its children (layers and nested splits) are **not** destroyed — a layer outlives the pane it sat in. Destroying the root split clears the root, dropping the layout back to hand-positioned layers |
| `set_split_children` | notification | `split, children: [{layer? \| split?, weight? \| fixed?}]` | — | ✅ replaces the child list wholesale (one message rather than insert/remove/reorder: a client rebuilding an arrangement always knows the whole new list). Each entry names exactly one of `layer`/`split` — both or neither reports `InvalidSplitChild` — and at most one of `weight` (a share of what's left) or `fixed` (exactly that many cells along the split's axis), defaulting to `weight: 1`. **`fixed` children are measured first and `weight` children share the remainder**, which is what lets a one-row statusline sit beside a pane that takes "the rest" without the client recomputing a fraction on every resize. The last weighted child absorbs the rounding remainder so the children plus dividers fill the split exactly |
| `set_root_split` | notification | `split?` | — | ✅ which split fills the context; null tears the layout down without destroying anything. Triggers a re-layout, and so the first `layout` notification |
| `move_divider` | notification | `split, index, delta` | — | ✅ drags the band after child `index` by `delta` cells along the axis, growing one neighbour and shrinking the other. What glyphwire-host sends for a mouse drag; a client can send it too (a keyboard "grow this pane" binding). A `fixed` neighbour keeps its cells and just gets more or fewer; a `weight` pair keeps its **combined** weight and re-splits it by the new ratio, so the rest of the tree is undisturbed. Clamped so neither neighbour is squeezed below one cell — a pane at zero could never be grabbed back. A no-op on a `resizable: false` split |

Every one of these re-lays-out the tree and broadcasts a `layout`
notification (see Input) naming each pane whose bounds actually moved; a
re-layout that changes nothing is silent. A window resize does the same,
after its own `resize` notification.

`divider_cells` (the gap between two children, 1 by default) is a
`Context` field the host owns; there is no message for it yet.

## Panes

A **pane** is a rectangle of the window with its own stack of contexts.
Where a split tree arranges *layers* inside one program's context, the
pane tree arranges whole programs: each pane holds a context stack of its
own, so a full-screen program inside a pane covers the pane rather than
the window.

**From the program inside it, a pane is indistinguishable from the whole
host.** `get_property "size"` returns the pane's cells. `resize` reports
the pane's cells. `create_context` covers the pane and pops back to what
was underneath when dismissed. Input arrives only while the pane is
focused. Mouse coordinates are relative to the pane. Nothing in this
section is visible to a program that isn't a window manager, and nothing
a program can ask reveals where its pane sits or that other panes exist —
which is why every existing client runs inside a pane unmodified.

Everything below `request_role` requires the **window-manager role**, so a
program that merely runs inside a pane can never reshape the window
around itself.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `request_role` | request | `role` (`"window_manager"`), `token?` | `{granted, token?}` | ✅ answers `granted: false` rather than failing when another program holds it, so a second multiplexer can say so cleanly instead of dying on a wire error. An unknown role reports `UnknownRole`. The returned `token` is what this program's *other* connection presents to `join_role` — a manager is two connections (a `Client` that issues these calls and an `InputListener` that receives window commands) and both need the role |
| `join_role` | notification | `role`, `token` | — | ✅ joins a role this program's other connection already holds. A notification because the joining connection is a subscribed listener with a reader thread running, so it has nowhere to read a response — the same reason `attach_context` is one. A wrong token simply grants nothing |
| `attach_pane` | notification | `pane` | — | ✅ binds this connection to a pane, and to whatever context is on screen there. Needs **no** role: declaring where you live is not a privilege. Sent automatically at connect time from `GLYPHWIRE_PANE`, so a program seated in a pane needs no pane-aware code of its own. A subscribing connection folds this into `subscribe`'s `pane` instead (see Input) |
| `create_pane` | request | `scrollback_rows?` | `{pane, context}` | ✅ a pane plus the base context it displays. The pane is **not on screen** until it is placed in the tree, which keeps creation and placement separately undoable. Its base context can never be destroyed while the pane lives |
| `destroy_pane` | notification | `pane` | — | ✅ stops the program in the pane, then frees the pane and every context in it. The program is stopped first, so it can't draw onto a context about to be freed under it. The root pane reports `RootPaneImmutable` |
| `focus_pane` | notification | `pane` | — | ✅ which pane raw input goes to. An unmapped pane (one not currently placed in the tree) reports `UnknownPane` rather than swallowing every keystroke into something invisible |
| `create_pane_split` | request | `axis`, `resizable?` | split handle | ✅ the window-level mirror of `create_split`, same semantics |
| `destroy_pane_split` | notification | `split` | — | ✅ frees the container; its children are not touched |
| `set_pane_split_children` | notification | `split, children: [{pane? \| split?, weight? \| fixed?}]` | — | ✅ same contract as `set_split_children`, with panes as the leaf kind. Naming both or neither reports `InvalidPaneSplitChild` |
| `set_root_pane_split` | notification | `split?` | — | ✅ which split fills the window; null tears the layout down, leaving the root pane as the whole window again. A pane the tree no longer reaches goes **unmapped**: it keeps its contexts and its programs alive but is not composited and takes no input, which is what makes zoom a consequence of the layout rather than a special case |
| `move_pane_divider` | notification | `split, index, delta` | — | ✅ the window-level `move_divider`, same sizing-mode rules |
| `spawn_in_pane` | request | `pane, argv, cols?, rows?` | `{pid}` | ✅ starts a program seated in the pane. The **host** does the fork, the PTY, the environment that lets the child find its pane, and the reaping — a manager that forked its own children would have to reconstruct all of that and would be the only thing able to reap them. `argv[0]`, when a bare name, prefers this build's own sibling binary over `PATH`. `cols`/`rows` default to the pane's size. Reports `SpawnUnsupported` on a server with no window (the headless one), `SpawnFailed` on an empty argv or a failed exec |
| `set_window_prefix` | notification | `key?`, `ctrl?`, `alt?`, `shift?` | — | ✅ the chord after which **one** keystroke is delivered to the manager instead of to the focused pane. Null `key` clears it. Enforced by the session, not by the manager: a manager that had to observe every keystroke to recognise its own prefix would, by construction, already have let the program have it. The modifiers are matched against the session's own window-global view of the keyboard, not against the `get_input_state` down-set, so a chord keeps working across a focus change with a modifier held. The prefix and the key after it never reach any program, and a key release is withheld alongside the press it belongs to |

`pane_layout` (see Input) is the only message that reveals pane geometry.

### Remote sessions in a pane

`start_remote` is the one pane-related message that needs **no**
window-manager role, and the one that takes no `pane` parameter. Both for
the same reason: the caller is a program already seated in the pane it
wants to hand over, so the pane it may hand over is exactly the one it is
already in, and naming someone else's is what it must not be able to do.

The caller is **not replaced**. Its connection stays bound to the pane and
it has the pane back the moment the session ends — `gw-shell`'s `gwssh`
builtin sits behind the session the way it sits behind `ssh` in an
ordinary terminal. Both shells are attached to the same pane, so both are
handed every keystroke while it has focus; the local one drains and drops
them, exactly as it does for a glyphwire-aware pty child.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `start_remote` | request | `dest`, `ssh_args?`, `remote_command?` | `{session}` | ✅ brings up an `ssh` trunk to `dest` whose remote clients draw into **this connection's own** pane. The **host** spawns `ssh`, surfaces its auth prompts on the grid, and turns the trunk's channels back into server connections, for the same reason `spawn_in_pane` is the host's job. Returns as soon as the session is on its thread — it does **not** wait for `ssh` to come up, because that waits on a human typing a passphrase into a prompt this very server has to keep dispatching for. A session that fails to start reports itself through `remote_exit` with a non-zero status. `ssh_args` are inserted before `dest` on the `ssh` command line; `remote_command` overrides the far-side agent (`gw-agent`). Reports `RemoteUnsupported` on a server with no window (the headless one), `RemoteStartFailed` on an empty `dest` |
| `stop_remote` | notification | `session` | — | ✅ ends a session `start_remote` returned. An unknown id is **not** an error: a caller cancelling one races the `remote_exit` notification by nature. `destroy_pane` ends every session seated in that pane too, since a remote session outlives the pane's own program |
| `remote_exit` | notification, server→client | `{session, status, started}` | — | ✅ the session ended, with `ssh`'s wait status (`128 + signal` for a signalled death). `started` is false when it never came up at all — no such host, auth refused, no `gw-agent` on the far side — which `status` alone cannot say, because `ssh` passes the remote command's exit code through and a failure is indistinguishable from a remote shell exiting with the same number. Subscribe with `"remote"`; `InputListener.pollRemoteExitEvent` is the consumer. **Broadcast**, not addressed to the connection that asked: a program's drawing `Client` and its `InputListener` are two different connections, and it is the listener that waits, so the session id is what pairs them up |

## Pane errors

| Error | Meaning |
|---|---|
| `NotWindowManager` | a pane-tree message from a connection without the role |
| `UnknownRole` | `request_role` named a role this server doesn't have |
| `UnknownPane` | an unknown pane, or one not currently placed in the tree |
| `RootPaneImmutable` | `destroy_pane` named the root pane, which has no lifecycle |
| `ImageIsIcon` | `destroy_image` / `update_image` named a handle registered in the icon catalog, which is session-wide infrastructure no client owns |
| `UnknownPaneSplit` | an unknown pane-split handle |
| `InvalidPaneSplitChild` | a child naming both a pane and a split, or neither |
| `SpawnUnsupported` | `spawn_in_pane` on a server with no spawner registered |
| `SpawnFailed` | empty `argv`, or the fork/exec failed |
| `RemoteUnsupported` | `start_remote` / `stop_remote` on a server with no remote starter registered |
| `RemoteStartFailed` | empty `dest`, or the session could not be put on its thread |

## Text & Styling

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `write_text` | notification | `layer?, row?, col?, text \| spans, fg?, bg?, metadata_id?, transparent_bg?, scale?, max_cols?, pad?, selectable?` | — | ✅ **`spans`** (instead of `text`; exactly one of the two, else `InvalidSpans`) is an array of `{text, fg?, bg?, metadata_id?, transparent_bg?, scale?}` written back to back as one write — a syntax-coloured row or a status line with a highlighted word in one message rather than one per colour. A span's omitted fields inherit the message's; `max_cols`/`pad` cover the whole write and the pad takes the message's `bg`; one SGR pen and escape machine run across all spans as if they were one string; every span is validated before anything is drawn. Writes at `row?`/`col?` — each omitted axis keeps the cursor's value, the same rule `draw_icon` uses, so a positioned run is one message rather than a cursor `set_property` plus a write — and advances the cursor. `max_cols` clips the run to that many **display columns** from where it starts (clamped to the layer's right edge; the host's East Asian Width table decides, so a client never measures text): a grapheme that would cross the limit is dropped with everything after it, a wide character that only half fits leaves a blank cell, and a clipped run never wraps. `pad` (with `max_cols`) fills the rest of the span with blank cells in `bg` and leaves the cursor at its end, so a full-width bar or list row is one write whatever its text. `selectable` (default `true`; whole-write, like `pad`) set `false` keeps every cell the write touches, its padding included, out of any selection's tint and copied text: for a panel's border and pad, so a selection over the panel covers only the text inside it (see Selection and clipboard). `scale` (default `"x1"`, or `"x1_5"`/`"x2"`/`"x3"`) draws each glyph at 1.5x/2x/3x its normal pixel size from the cell that holds it, and **advances the cursor by the scaled width** — two cells per display column for 1.5x and 2x, three for 3x (`glyphwire.scaledPitch`) — filling the cells it steps over, **and the same span on the `scaledPitch - 1` rows below** that the glyph draws down over, with blanks in the run's `bg` and `metadata_id`, so consecutive scaled characters don't overlap, a heading's background (e.g. inline code) and link highlight cover the whole glyph, and every cell under it hit-tests as the run. The rows below are clipped at the layer's bottom edge (never scrolled into) and the cursor stays on the glyph's own row; they are overwritten, not merged, so a caller still reserves them and writes the next line after them. A scaled glyph that won't fit before the right edge wraps whole; under `max_cols` the part that fits is blanked (the rows below are left alone). Not exposed on `get_cells`. `fg`/`bg` omitted means `core.default_style`'s — whose background is **transparent** (alpha 0). Alpha alone decides transparency: an explicit `bg` (wire `a` defaults to 255) paints, black included. Style attributes beyond fg/bg (bold, italic, underline, strikethrough, dim) as first-class `Style` fields are still decided-not-wired — see decisions.md; SGR `bold`/`dim`/`inverse` below are folded into the resolved fg/bg colour instead. `metadata_id?` (see Metadata below) tags every cell the text touches with the same id — omitted (or any cell a later plain `write_text` overwrites) means untagged. `transparent_bg` (default `false`): leaves each touched cell's existing background untouched instead of resetting it to `default_style.bg` — `bg` is ignored when this is set. For text written over a background drawn some other way (e.g. `draw_box`'s fill) that needs to stay visible through it — see decisions.md's Style section. **C0 control bytes** in `text` move the cursor rather than being drawn: `\n`/`\v`/`\f` act as newline (carriage return + line feed, so `"a\nb"` puts `b` at column 0 of the next row), `\r` returns to column 0, `\t` advances to the next 8-column tab stop (clamped to the last column, no wrap), `\b` steps back one column (non-destructive, a no-op at column 0); every other C0 byte and DEL is silently dropped. **`ESC` sequences (Phase A VT fallback — see decisions.md and `docs/investigations/libghostty-vt-fallback.md`):** `ESC [ … m` (SGR) is **interpreted** — 16/bright/256/truecolor fg+bg (`;` and `:` sub-parameter forms), `0` reset, `1` bold (promotes a basic fg to its bright variant), `2` dim (darkens the fg), `7`/`27` inverse (swaps fg/bg); italic/underline/blink/strikethrough are parsed and ignored. A set of `ESC [ …` cursor/erase/screen finals is interpreted too — `A`/`B`/`C`/`D` (cursor up/down/right/left), `G` (column), `d` (row), `H`/`f` (row;col), `J` (erase in display), `K` (erase in line); and, from the **B1 screen model** (see decisions.md): `r` (DECSTBM scroll region), `S`/`T` (scroll up/down), `L`/`M` (insert/delete line), `@`/`P`/`X` (insert/delete/erase char), `s`/`u` and `ESC 7`/`ESC 8` (save/restore cursor), `ESC M` (reverse index), `ESC [ ! p` (DECSTR soft reset — region to full, caret shown, no cursor move / no clear), `ESC [ ? 1049 h/l` / `?47` / `?1047` (alternate screen — a separate `width*height` buffer with no scrollback; the primary buffer and its scrollback are untouched), `ESC [ ? 25 h/l` (DECTCEM cursor show/hide — sets a flag the host caret renderer honours). **VT100 alternate charset (ACS line drawing):** `ESC ( <c>` / `ESC ) <c>` designate G0/G1 as the special graphics/line-drawing set (`c == '0'`) or ASCII (anything else, `'B'` in practice), and `SO`/`SI` (0x0E/0x0F) pick which of G0/G1 is active; while the active set is line drawing, a printable byte `` ` ``..`~` maps to its Unicode box-drawing/symbol glyph (the standard VT220/terminfo `acsc` table) instead of printing literally — this is how `smacs`/`rmacs` (xterm-style, redesignates G0 directly) and screen/tmux-style (SO/SI over a G1 designated once) both draw panel borders. Charset state is call-scoped like the SGR pen (see below). `ESC [ 6 n` / `5 n` / `c` / `> c` and DECRQM (`ESC [ ? Ps $ p`) are **answered**: the reply bytes ride a `terminal_reply` notification (see Input) for a `"terminal"` subscriber to write to the pty master, since a query can't be answered from the grid itself. Every **other** `ESC [ …` final and every `ESC ]`/`P`/`X`/`^`/`_ … BEL`/`ST` (OSC etc.) sequence is still **recognized and discarded**. **Nothing carries across `write_text` calls** — a half-parsed sequence is abandoned, and the SGR colour "pen" and alternate-charset state are reset, at the call boundary — so an unterminated `ESC ] …` can't swallow later writes, an un-reset `ESC [ 31 m` can't tint the next prompt or listing, and an un-closed `smacs` can't turn the next prompt into box-drawing glyphs. A colour is honoured only within the chunk that set it. **A layer with the `pty_mode` property set opts out of this** — its machine, charset and pen persist across calls (terminal semantics for a layer carrying one PTY child's stream); see `pty_mode` under Property names. **East Asian wide characters** (CJK, kana, Hangul, …) occupy two cells: the grapheme lands in the left cell, the right cell becomes a blank spacer (see `get_cells`' `wide`), and the cursor advances by 2; a wide character that would straddle the layer's right edge wraps to the next row first |
| `insert_cells` | notification | `layer?, count` (cursor-implicit like `write_text`) | — | ✅ ECMA-48's ICH: shifts cells at and after the cursor right within its row, discarding any past the row's right edge; row-scoped only, see roadmap.md's open questions |
| `delete_cells` | notification | `layer?, count` (cursor-implicit like `write_text`) | — | ✅ ECMA-48's DCH: removes cells at and after the cursor, shifting the row's remainder left and blanking the tail |
| `move_content` | notification | `layer?, top?, bot?, count?, direction?` | — | ✅ shifts `count` rows (default 1) of the layer's content grid vertically in place — the same primitive as CSI SU/SD, exposed so a client-scrolled pane can scroll without retransmitting every visible row. `top`/`bot` are an inclusive content-grid row range (default: the whole grid); `count` is clamped to the span; `direction` is `"up"` (default — content toward `top`, blank rows appear at `bot`) or `"down"`. Cells keep their styling, icons and metadata ids. An out-of-range range or a zero `count` is a silent no-op. Batchable, and meant to be batched right before the partial redraw of the newly-exposed band. `zoe`'s buffer pane uses it for every sub-screen scroll |
| `clear` | notification | `layer?, row?, col?, rows?, cols?, bg?` (all default: `row`/`col` to 0, `rows`/`cols` to "the rest of the layer from here") | — | ✅ resets a region back to blank (empty grapheme, default style, no image background); an all-defaulted `clear()` wipes the whole layer. With `bg`, the blanked cells take that background instead of staying transparent — the "paint a solid rectangle" primitive (a panel, a letterbox, the rest of a row). Batchable, e.g. wipe a region then redraw over it in one frame — the shell's prompt redraw does this on resize |

## Image

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `load_image` | request (binary side-channel: JSON header + raw bytes) | `format, bytes` | image handle | ✅ `format` is parsed — `"png"`, `"jpeg"` (also `"jpg"`), `"bmp"`, `"gif"` — and selects the header parser that measures the image (`core.imageDimensions`); an unknown format, or bytes that don't match the declared one, fails the request. Bytes are stored verbatim; pixel decoding stays renderer-only (glyphwire-host's stb_image auto-detects all four) |
| `update_image` | request (binary side-channel: JSON header + raw bytes) | `handle, format, bytes` | the same image handle back | ✅ replaces the bytes behind an existing handle instead of allocating a new one — for a client that redraws the same slot repeatedly (a `.cbz` page reader, a refreshing plot), where `load_image` per step would leave one dead image behind each time. Rides the same side-channel framing `load_image` does, and `format` is parsed and the payload measured identically; a payload that doesn't match its declared format fails the request and leaves the **old** image intact. The replacement may have different natural dimensions than the image it replaces: cells already drawn from this handle keep the per-cell sampling offsets `draw_image` computed from the *old* size, so a caller that changes the size is expected to `draw_image` again with a span sized for the new dimensions — see decisions.md's Image lifecycle section for why the server doesn't auto-repaint. Errors `UnknownImage` for a handle that isn't loaded (or is missing entirely), `ImageIsIcon` for a catalog handle |
| `get_image_info` | request | `handle` | natural pixel dimensions (read from the format's header — PNG IHDR / JPEG SOF / BMP DIB header / GIF screen descriptor — not a real decode) | ✅ |
| `destroy_image` | notification | `handle` | — | ✅ frees a loaded image's bytes and drops its handle. Cells still backed by it are deliberately **left alone** and simply render nothing from then on — the same "report the dangling reference rather than chase it" treatment `get_metadata` gives a destroyed `metadata_id`; clear the region first if a blank matters. Errors `UnknownImage` for an unknown handle and `ImageIsIcon` for one registered in the icon catalog (icons are session-wide infrastructure shared through `asset_fallback`, and `get_cells` exposes their handles, so a client can't be allowed to release one). Mostly unnecessary for a short-lived program — an image loaded over a connection is reclaimed automatically once that connection is gone and the image has scrolled out of the scrollback (see **Image reclamation** below); this is for a long-running client that wants its memory back at a moment of its choosing. Batchable, unlike `load_image`/`update_image`, since it carries no side-channel payload |
| `draw_image` | notification | `layer?, handle, row?, col?, row_span, col_span, scale?, src_x?, src_y?, src_w?, src_h?` | — | ✅ clips to the given span rather than stretching to fill it; see decisions.md. `row`/`col` default to the layer's cursor when omitted, same convention as `write_text`. `scale` (default `1.0`) is the uniform, aspect-preserving factor the image is drawn at: `1.0` is natural pixel size (the original behavior), `< 1.0` shrinks it — `glyphwire-view` sends `target_width_px / image_width_px` so the image fits the layer's width, and still sizes `row_span`/`col_span` itself from the scaled dimensions (aspect-ratio-aware placement stays the client's job). Each covered cell then samples `cell_px / scale` source pixels; a non-positive `scale` is treated as `1.0`. `src_x`/`src_y`/`src_w`/`src_h` (all pixels, all default `0`) restrict sampling to a sub-rectangle of the source image instead of the whole thing — general sprite-sheet/sub-image support, e.g. one frame of a strip; `src_w`/`src_h` of `0` means "to the image's own right/bottom edge from `(src_x, src_y)`", so omitting all four is the original whole-image behavior. Clamped to the image's own bounds first, and clips at the source rect's own edge rather than the whole image's, so a sprite drawn from the middle of a sheet doesn't bleed into a neighbour at its partial edge cell; a rect that starts past the image's own edge draws nothing. Exposed back through `get_cells` on every image-backed cell (`bg_image.scale`, `bg_image.src_right`/`src_bottom` — the resolved clip bound, both defaulting to `maxInt` when no source rect was used) |
| `get_cell_metrics` | request | — | `{cell_px_w, cell_px_h}` | ✅ lets a client compute `row_span`/`col_span` from an image's natural size without hardcoding the session's cell pixel metrics |
| `draw_icon` | notification | `layer?, row?, col?, name, scale?, h_align?, v_align?, max_w?, max_h?, metadata_id?, foreground?` | — | ✅ `metadata_id?` (see Metadata below) tags the anchor cell, same as `write_text`'s. resolves `name` against `Context.icons` (seeded at `glyphwire-host` startup by a recursive scan of `assets/icons/` — a name is the file's path under that directory without the `.png` extension, e.g. `oxygen/folder`, `distro/arch`, `status/error`) and draws it anchored at exactly one cell. `scale`: `"fit"` (the default, aspect-preserved to exactly fill the cell), `"natural"` (the image's own pixel size, optionally shrunk — aspect preserved, never upscaled — to stay within `max_w`/`max_h` pixels if given; can still overflow past the anchor cell), or `"stretch"` (fills the cell exactly on both axes, aspect *not* preserved — what `draw_box`'s tiles use). `h_align`/`v_align` (`"start"`/`"center"`/`"end"`, default `"center"`) place the result within/around the cell for `"fit"`/`"natural"` (no-ops for `"stretch"`, which always fills exactly) — see decisions.md's Icon section, including why `"natural"` overflow is a rendering-only effect with no data-model footprint on the cells it visually spills into. `foreground` (default `false`): draws into `Cell.fg_icon` instead of `style.bg`, compositing over whatever background is already on that cell (e.g. a `draw_box` fill) instead of replacing it — see decisions.md's Icon section. Theming and a wire-exposed catalog listing are still open. `row`/`col` default to the cursor when omitted |
| `draw_box` | notification | `layer?, row?, col?, rows, cols, style, mode?` | — | ✅ resolves `style`'s 9 corner/edge/fill pieces (`"{style}/tl"`, ... — same `icons` catalog as `draw_icon`, from the bundled `assets/icons/box/` and `assets/icons/dialog/` subtrees) and composes them across the given rectangle per `mode` (`core.Layer.BoxMode`, default `"tile"`). `"tile"`: one tile per cell, each independently stretched (`draw_icon`'s `scale: "stretch"`) to fill its cell exactly so the border stays continuous regardless of the cell's aspect ratio — the original behavior. `"stretch"`: corners are still one tile each, but each edge/fill role's single source image is treated as one continuous picture spanning its whole run (`t`/`b` across every interior column, `l`/`r` across every interior row, `fill` across the whole interior rectangle), so e.g. a vertical gradient blends smoothly across however many cells the box spans instead of repeating per cell — see roadmap.md's `BoxMode.stretch` entry. `row`/`col` default to the cursor when omitted |


### Image reclamation

A client does **not** have to call `destroy_image` to avoid growing the
session's memory. An image loaded over a connection is reclaimed
automatically once both of these are true:

1. **Its loading connection is gone.** While the connection that sent
   `load_image` is still open the image is pinned, even if nothing has
   been drawn with it yet — a client that loads and then waits before
   drawing is the normal case, not a leak. An image loaded in-process
   (the bundled icon catalog) is pinned for the life of the session.
2. **No cell anywhere in the session still references it.** That means
   every layer of every context, live viewport *and* retained scrollback —
   an image the user can scroll back to is still on screen as far as this
   is concerned. Only rows evicted past the layer's `scrollback_rows`
   actually release anything.

This is what keeps a shell from growing without bound as images are shown
in it: `glyphwire-view` loads a picture, draws it and exits, and the bytes
are freed once that picture has scrolled off the end of the scrollback
ring.

The sweep is mark-and-sweep over the cell grid, run when the session's
stored image bytes cross a budget (64 MiB) on the `load_image` /
`update_image` that pushed it over — so the client filling the scrollback
pays for the cleanup, and a session that never accumulates images never
sweeps. Nothing about it is observable on the wire beyond handles
eventually ceasing to resolve, and a handle can only stop resolving after
the connection that owned it has closed, so no live client can be
surprised by one of its own handles disappearing.

`destroy_image` is still there for a long-running client that wants its
memory back at a specific moment rather than whenever the budget trips —
and for one that keeps a single connection open across many images, where
the pin in (1) never lapses. A client that shows a *sequence* of images in
one place (a `.cbz` reader) should prefer `update_image`, which reuses the
handle and so never accumulates anything to reclaim.

## Metadata

An opaque, client-defined JSON string a cell can be tagged with — a
handle-and-table resource like images, not embedded per-cell, so many
cells can share one without copying it. See decisions.md's Metadata
section for the full reasoning (why JSON and not fixed fields, why
`destroy_metadata` exists but garbage collection doesn't yet, why a
dangling id isn't an error).

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `create_metadata` | request | `json` | metadata handle | ✅ stores `json` verbatim — the server never parses it, only stores/returns it |
| `destroy_metadata` | notification | `id` | — | ✅ frees `id`'s stored JSON; errors `UnknownMetadata` on an unknown id, same treatment `destroy_layer` gives an unknown layer handle. No reference counting — a cell still tagged with `id` afterward is left dangling, see `get_metadata` |
| `get_metadata` | request | `layer?, row, col, view_offset?` | `{id, json}`, both nullable | ✅ resolves `(row, col)` to a cell and reports its `metadata_id` plus that id's stored JSON. `row`/`col` are required (unlike `draw_icon`/`draw_image`'s cursor-defaulted `row?`/`col?`) — this is a targeted lookup (e.g. resolving whatever cell a mouse click landed on), not a draw at "wherever the cursor is". `view_offset` (default 0) resolves against that many rows of scrollback above the live viewport, so a click made while the host is scrolled back — the `view_offset` comes through on the `mouse_button` event — lands on the row actually under the pointer. `id` non-null with `json` null means a dangling tag (the id was `destroy_metadata`'d after the cell was tagged) — reported rather than treated as an error, so a caller can tell "untagged" apart from "tagged but the data's gone" |
| `tag_metadata` | notification | `layer?, row, col, metadata_id, focus?` | — | ✅ sets exactly one cell's `metadata_id`, touching nothing else about it — unlike `write_text`/`draw_icon` below, which tag as a side effect of also drawing something. For a client that needs a cell tagged without changing what's drawn there, e.g. `glyphwire-ls` tagging the extra cells a `.natural`-scaled icon visually overflows into so browsing resolves correctly anywhere the icon actually renders, not just its anchor cell. `metadata_id` is required (there'd be no point tagging with nothing) and validated the same as `write_text`/`draw_icon`'s. `focus` (default `false`) additionally marks the cell as its span's *focus* cell — where `find_metadata` lands instead of the span's first visible character; see that row. Any write that sets a cell's `metadata_id` (`write_text`, `draw_icon`, a table repaint) clears the mark, so it is set last, by whoever knows which cell should carry it |
| `find_metadata` | request | `layer?, above?, col?, direction?` | `{found, above?, col?, id?}` | ✅ from content cell `(above, col)`, reports the first visible character of the metadata-id span adjacent in `direction` — `"next"` (default) walks forward in reading order (down / toward the live tail), `"prev"` backward (up into scrollback); anything else errors `InvalidMetadataDirection`. `above` is the scroll-stable coordinate `set_selection`'s points use (positive counts up into retained scrollback, zero or negative is a live-viewport row), so a caller needn't track `view_offset` separately. The span the start cell already belongs to is stepped over — its metadata id, *including* any untagged cells embedded in that id's run (e.g. the inter-column gaps of a `gw-ls -l` row) — as are untagged cells between spans; the landing cell is the next span's **focus cell** if it declared one (`tag_metadata`'s `focus`, or a `focus` table column — see `create_table`), else its first cell carrying a non-blank grapheme, so a leading icon or padding cell tagged with the span's id is skipped (a span with neither falls back to its first cell). The focus cell is what puts the cursor on the first character of the *filename* in a `gw-ls -l` row, whose single span starts back at the permissions column. `found` is false (other fields unset) when there's no further span that way within retained content. The walk runs server-side so a client never round-trips the grid with `get_cells` to scan for spans — `glyphwire-shell`'s Ctrl+PgUp / Ctrl+PgDn scrollback-span navigation is the caller |

`write_text`/`draw_icon` (above) both take an optional `metadata_id` —
tagging is a side effect of drawing, not its own separate call (`tag_metadata`
above is the one exception, for tagging without drawing). A bad id
(unknown or already-destroyed) errors `UnknownMetadata` immediately,
same "fail loud on a bad handle at the point of use" treatment
`UnknownImage`/`UnknownIcon`/`UnknownLayer` already get elsewhere.

## Table

Real server-side state (`core.Table`), not client-composited cells — see
decisions.md's Table section for the full reasoning, including why this
superseded an earlier client-only prototype. A table is a component of
whichever layer it's drawn on (`layer?` defaults to root, same convention
as every other layer-scoped message), addressed afterward by the `table`
handle `create_table` returns. `table_set_rows`/`table_set_sort`/
`table_set_style` each repaint immediately (`Table.render`, compiling the
table's current data into ordinary cells on its layer) — there is no
separate "table changed" notification a reader needs to poll for; the
owning layer's `get_cells`/`revision` already covers that, same as any
other draw call.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `create_table` | request | `layer?, row?, col?, columns: [{name, kind?, sortable?, case_insensitive?, focus?, width, min_width?, h_align?, overflow?}], style?` | table handle | ✅ `row`/`col` default to the layer's cursor, same convention `draw_box`/`draw_icon` use. `columns[].kind` is `"text"` (default) or `"number"` (which `SortKey` variant that column's cells are expected to sort on); `h_align` is `"start"` (default)/`"center"`/`"end"`. `overflow` is `"ellipsis"` (default: one line, cut off with `…`) or `"wrap"`: a body cell wider than the column word-wraps onto more lines (`core.WrapIterator`: break at spaces, hard-break an over-long word at a codepoint so a wide character never splits, `\n` forces a break) and its row grows to `max(row_height, row_height / 2 + lines)`, since a wrapped cell's first line is the band's middle line where every other cell's text sits. Icons stay capped to the `row_height` band. Wraps at the nominal `width` (less any icon), not the sort-arrow-widened `headerColWidth`, so a re-sort can't change the table's height under `repaint`'s in-place redraw. Each wrapped line carries the cell's `metadata_id`; only the first gets `focus`. Headers always ellipsize. A client laying out content below a table can size it with the same `glyphwire.wrapLineCount` (gwmd does) or read `table_get_state`'s `painted`. `case_insensitive` (default `false`, `.text` columns only): fold ASCII case when this column is sorted, with a raw-byte tie-break so case-folded-equal keys stay in a fixed order — `glyphwire-ls` sets it on the Name column. `focus` (default `false`): mark this column's body cell as its row's metadata focus cell, so `find_metadata` — and so `glyphwire-shell`'s Ctrl+PgUp/PgDn — lands on the first character of *this* column's value rather than the row's leftmost one. A whole `gw-ls -l` row shares one metadata id, so `glyphwire-ls` sets it on the Name column too; at most one column should carry it (if several do, the leftmost wins). `style` is the same shape `table_set_style` takes (`max_icon_px` included). No rows yet — nothing is painted until `table_set_rows` |
| `destroy_table` | notification | `layer?, table` | — | ✅ blanks whatever the table last painted, then frees it and drops it from its layer's `table_order` |
| `table_set_rows` | notification | `layer?, table, rows: [[{display, sort_key?, icon?, fg?, metadata_id?}]]` | — | ✅ replaces every row wholesale, re-sorts per the table's current sort state, and repaints. `sort_key` is a bare JSON number or string (see decisions.md), defaulting to a copy of `display` when omitted. `icon` is an icon-registry name, resolved the same way `draw_icon`'s `name` is (errors `UnknownIcon` immediately on an unrecognized one) — drawn alongside that cell's `display` text, not in a separate column, and composited *over* the row's background (it lands in the cell's `fg_icon`, so an `alt_row_bg` stripe stays unbroken behind it and a `row_height > 1` `.natural`-scaled icon's overflow paints over the neighboring rows' backgrounds). The icon is drawn `draw_icon`'s `scale: "natural"` capped to `row_height` cell-heights (and further to `style.max_icon_px` if that's set and smaller), so even a default `row_height` of 1 fills the row's line rather than shrinking to `"fit"` one cell; it falls back to a one-cell `"fit"` only when the session's cell pixel metrics are unavailable. A row's cell count must match the table's column count, or this errors `TableRowShapeMismatch` |
| `table_set_sort` | notification | `layer?, table, column?, direction?` | — | ✅ `column: null` or `direction: "none"` (the default) both mean "back to insertion order"; otherwise `"ascending"`/`"descending"` on that column's `SortKey`. Repaints **in place** (`core.Table.repaint`) — the row set is unchanged, so it redraws the table at its current position without scrolling the layer a second time. It writes every row wherever that row currently sits — live viewport, retained scrollback, or straddling the two — so a re-sorted table stays consistent when it scrolls back into view and the header keeps its arrow whether or not the header is still on screen; only rows older than retained history are lost. The active sort column's header draws a direction arrow after its name (`"Name ▴"` / `"Name ▾"`) and widens by two cells so the arrow never clips the name; a merely `sortable` column that isn't the current sort shows nothing extra. This is also the mutation glyphwire-host runs itself on a header click (see Table interactivity below) |
| `table_set_style` | notification | `layer?, table, style` | — | ✅ replaces the table's whole style (`borders`, `header_separator`, `box_style`, `alt_row_bg`, `header_fg`, `header_bg`, `row_height`, `max_icon_px`) and repaints — e.g. the message a future "checkbox for alternating row colors" UI would call. `max_icon_px` (optional) is an upper bound in pixels on a body icon's rendered height: a body icon is normally capped to `row_height` cell-heights, and this caps it further, so a tall `-l -L` row still renders a modest icon regardless of the source art's resolution |
| `table_get_state` | request | `layer?, table` | `{columns, row_count, sort_column, sort_direction, style, painted: {row, col, rows, cols}, revision}` | ✅ structured config, not rendered cells — those are already readable through the owning layer's `get_cells` (a table paints into ordinary cells). Each `columns[]` entry reports `name, kind, sortable, case_insensitive, focus, width, min_width, h_align, overflow`. For a future client that needs to know e.g. which columns are sortable before deciding what a header click should do. `painted` is the table's actual on-screen footprint (`core.Table.painted`) — `painted.row + painted.rows` is the first row below the whole table, border included if bordered, for a caller that wants to place its own next content there instead of overwriting the table (e.g. `glyphwire-ls -l`'s next shell prompt). A table taller than the viewport renders top-down and scrolls the layer as it goes (terminal-style), so its footprint fills the visible area (`painted.row` 0, `painted.row + painted.rows` == layer height) with the header + earliest rows now in scrollback — a caller placing follow-on content should see there's no on-screen row past the table and make room itself (e.g. `glyphwire-ls -l` emits a newline for the gap before the next prompt) rather than pass an absolute row past the bottom |

### Table interactivity

**Header-click sorting is live, driven by glyphwire-host directly.** A
left click on a `sortable` column's header cell cycles that column's sort
through the same three states `table_set_sort` exposes — ascending →
descending → back to insertion order — and repaints the table in place;
the host consumes the click so it isn't also delivered to glyphwire-shell
as a grid click. No wire message is involved: a table is real
server-side state (`core.Table`), so `Table.cycleSortOnColumn` +
`Table.repaint` is all it takes, and (unlike the `get_metadata`-driven
click resolution `glyphwire-shell`'s `activateSelectionAt` uses) it works
with no client running — which is what `glyphwire-ls -l` needs, since it
exits the moment the table is drawn. The click resolves through the
table's pinned `top_live` (which `Layer.scrollOne` and `Layer.resize`
keep accurate as output and window changes move the table) plus the
layer's scrollback offset, so it works wherever the header is actually on
screen — including after output has scrolled the table, a window resize
has shifted it, or the user has scrolled the view back to reach the
header. The re-sort itself rewrites every row of the table wherever it
sits, viewport or scrollback, so scrolling back shows it consistently
sorted. Scope of the first cut: tables on the **visible context's
root layer** (where `glyphwire-ls -l` puts them). See decisions.md's
Table section.

Other table interactivity (a checkbox toggling `alt_row_bg`, say) still
isn't wired — `table_set_style` exists for a future client to call.

## Rect

A first-class overlay primitive: a plain coloured box (filled or
outlined), positioned in pixel space on a layer rather than the cell
grid. A component of the layer it's drawn on, like Table — see
decisions.md's Rect section for the rationale (driven by gw-read's mokuro
highlight boxes). gw-read now draws its OCR region marks and its Anki crop
box (four translucent filled rects shading the page around an outline) as
rects on the page layer itself, so they pan with `scroll_offset` for free.
All three messages are batchable; `Client.Batch.createRect` returns a slot
resolved with `BatchResults.rectHandle`, so a page's worth of rects costs
one round trip.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `create_rect` | request | `layer?, x, y, w, h, color: {r,g,b,a?}, line_width?, filled?` | rect handle | ✅ `x`/`y`/`w`/`h` are pixels in the layer's own content coordinate frame — the same frame `draw_image`'s per-cell offsets sample within one cell, generalized to the whole layer — so a rect pans for free when the layer's `scroll_offset` moves, exactly like image cells and text do. `line_width` (default `1`) only matters when `filled` (default `false`) is `false` — the outline's stroke thickness in pixels, drawn as four non-overlapping strips so a translucent `color` doesn't double up at the corners. Renders immediately; nothing further to configure. Errors `UnknownLayer` for an unresolvable `layer` |
| `update_rect` | notification | `layer?, rect, x?, y?, w?, h?, color?, line_width?, filled?` | — | ✅ merges only the fields actually sent — an omitted field keeps its current value, unlike `create_rect`'s fields (all required, no "unchanged" concept applies there). Moving a rect only needs `x`/`y`. Errors `UnknownLayer`/`UnknownRect` |
| `destroy_rect` | notification | `layer?, rect` | — | ✅ removes the rect; it stops painting immediately. Errors `UnknownLayer`/`UnknownRect`. Batchable |

No ownership check on any of the three — a rect is layer-scoped passive
presentation data, same treatment `create_table`/`destroy_table` get.
Composited as its own quad batch, drawn last in the layer's draw order
(after text) so an overlay rect sits visibly on top of everything else
the layer paints — unlike the selection/highlight tints, which are drawn
*under* text so the text pass stays readable over them. There is no
`get_rect`/`rect_get_state` yet; nothing has needed to read a rect back.

## Selection & Clipboard

Real server-side state, like Table — a linear (stream, not rectangular)
text selection lives on a `Layer` (`core.Layer.selection`), and one
session clipboard buffer lives on the `Context`. See decisions.md's
Selection & clipboard section for the reasoning (why selection is server
state, why endpoints are content-anchored, why the clipboard is a buffer
glyphwire-host mirrors to the OS, and the `copy_request` handshake).

A **selection point** is `{above, col}`: `above` is how many grid rows
the point sits above the live viewport's top row — positive counts up
into retained scrollback (`above == 1` is the row just above the
viewport), zero or negative is a live viewport row (`-above`). It is
deliberately not a screen position: `above` is anchored to the content,
so a selection stays pinned to its text while the view scrolls, and the
server shifts both ends as fresh output pushes rows into scrollback. An
end scrolling off the top of retained history, or a `resize`, drops the
selection.

**Wide characters are never split.** A point is a raw cell and may sit on
either half of a 2-cell East Asian character (a drag doesn't know where
glyphs fall, and neither does a client computing columns itself). What
the selection *covers* snaps outward instead: a start on a spacer moves
back onto its lead, an end on a lead takes in its spacer. The renderer's
tint (`Layer.selectionColRange`) and `get_selection_text` share the same
snap, so they always agree on whole characters. The stored points and
the `selection` notification report the raw cells as set.

**Scaled text selects by glyph row.** A `write_text` `scale` glyph draws
down over the `scaledPitch - 1` rows below its own, and those rows carry
no text. A point on one of them (a drag's pointer is on the lower half of
an enlarged line about as often as the upper) resolves to the glyph row
above it, so dragging onto the lower half of a line selects that line
rather than starting a phantom one, and a start or end inside a scaled
glyph's blank fill snaps to the whole glyph, the same way a wide
character's spacer does. The tint then covers every row the selected
glyphs draw into, and `get_selection_text` skips the fill and the rows
below.

**Each row stops at its text.** A row's tint and copied text run from
the row's first selectable cell to its last non-blank one, not out to the
layer's edge: a selection wrapping onto the next line shows as two pieces
that end where the words do, and a blank row inside the selection tints
nothing. Cells written with `write_text`'s `selectable: false` (a panel's
border and pad) are never tinted or copied, and a row made only of them
contributes no line to the copied text.

**Any layer can hold one, and glyphwire-host's own drag now finds them.**
Every message below takes a `layer?`, and always has; what changed is the
host side. A left-drag hit-tests the topmost visible `create_layer` layer
under the pointer and selects *that* layer's text, falling through to the
root grid only when the drag started over bare root — so a popup, a
sidebar or a reader's text panel is selectable without the client running
its own drag loop. A `create_layer` layer has no scrollback ring, so its
points are simply the negated content row (the viewport row plus the
layer's own `scroll_offset`); the edge auto-scroll during a drag stays a
root-only gesture, and a drag off the edge of a popup pins to its last
cell instead. Ctrl+Shift+C copies whichever layer actually holds a
selection, not root's — including one a *client* set with
`set_selection`, which is how `gw-read`'s OCR dialog is copyable even
though its context is client-owned and the host leaves that drag to the
client. Keyboard selection mode (Ctrl+Shift+Space) is still root-only:
it starts at the root cursor and walks the root grid.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `set_selection` | notification | `layer?, anchor: {above, col}, active: {above, col}` | — | ✅ starts or replaces the layer's selection (root when `layer` omitted). Broadcasts `selection` |
| `update_selection` | notification | `layer?, active: {above, col}` | — | ✅ moves only the active (dragging) end; a no-op if nothing is selected. Broadcasts `selection` |
| `clear_selection` | notification | `layer?` | — | ✅ broadcasts `selection` (inactive) |
| `get_selection` | request | `layer?` | `{active, anchor?: {above, col}, active_end?: {above, col}}` | ✅ `active` false ⇒ nothing selected, the two point fields absent |
| `get_selection_text` | request | `layer?` | `{text}` | ✅ the selected text: interior rows taken whole, first/last row clipped to the start/end column, each row's trailing blanks trimmed, rows joined with `\n`, a wide character's spacer half and a scaled glyph's fill (and the rows it draws down into) skipped, `selectable: false` cells left out and rows made only of them dropped. `""` when nothing (or a zero-width selection) is selected |
| `set_clipboard` | notification | `text` | — | ✅ replaces the session clipboard buffer (`core.Context.clipboard`) and bumps its serial. glyphwire-host mirrors the buffer to the OS clipboard on its next frame |
| `get_clipboard` | request | *(none)* | `{text}` | ✅ the session clipboard buffer. On glyphwire-host this reflects OS-clipboard changes another app made only once the host has synced (its next copy/paste) — see decisions.md |

## Highlights

A tinted **set of metadata ids** on a `Layer` (`core.Layer.highlighted_ids`),
separate from the selection: many at once, and the copy path never touches
them. glyphwire-shell uses it to mark `ls` entries for a multi-open. It's
stored as ids, not cell ranges — the renderer tints any cell whose
`metadata_id` is in the set, so a highlight follows its content through
scrollback and survives a `resize` for free, and an id whose cells have
all scrolled out of retained history simply matches nothing (ids are
never reused, so a stale id is harmless). glyphwire-host renders the tint
with the same translucent overlay as the selection.

The client never scans the grid: `toggle_highlight` names a **cell**, the
server resolves it to that cell's `metadata_id` (honouring `view_offset`
like `get_metadata`) and flips it. Every highlight message answers with a
`HighlightState` — `{entries: [{id, json}, ...]}` — carrying every
currently highlighted id together with that id's stored metadata blob
(`json` null for a dangling id), so a client gets what it needs to act on
each entry without a round trip per id.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `toggle_highlight` | request | `layer?, row, col, view_offset?` | `HighlightState` | ✅ resolves `(row, col)` to a cell's `metadata_id` and flips it in the layer's set (root when `layer` omitted). A cell with no tag leaves the set unchanged |
| `set_highlight` | request | `layer?, ids: [u32, ...]` | `HighlightState` | ✅ replaces the whole highlighted-id set. An empty `ids` clears it |
| `clear_highlight` | request | `layer?` | `HighlightState` | ✅ drops every highlighted id |
| `get_highlight` | request | `layer?` | `HighlightState` | ✅ the layer's current highlighted-id set, unchanged |

## Batch

One `batch` message carries an ordered list of other messages, applied
server-side in a single pass (under the one lock hold the server already
takes per message) so nothing renders a half-updated grid partway
through — the fix for `glyphwire-ls`'s listing visibly painting itself a
band at a time. See decisions.md's Batch section for the reasoning.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `batch` | notification *or* request | `messages: [{method, params, id?}, ...]` | request form only: `{responses: [<response object>, ...]}` | ✅ |

- **Notification form** (no outer `id`): every sub-message is applied in
  order; no response. A sub-message carrying an `id` still runs, but its
  response is dropped (with a server log line) — use the request form to
  get results back.
- **Request form** (outer `id` present): `responses` has one entry per
  sub-message that carried an `id` *and* whose handler produced a result,
  in sub-message order. Each entry is a complete JSON-RPC response object
  (`{jsonrpc, id, result}`) tagged with that sub-message's own
  batch-local `id` — correlate by matching ids. An id absent from
  `responses` means that sub-message was a notification, or it failed.
- **Sub-message `id`s are batch-local** — the caller's own numbering,
  scoped to this `messages` array, unrelated to the outer request `id` or
  any other frame's `id`.
- **Best-effort, not atomic.** A sub-message that fails to parse, names a
  batch-invalid method, or errors in its handler is logged and skipped;
  the rest of the batch still runs. "Atomic" means only "one render", not
  all-or-nothing — there is no rollback (core has no transaction
  support), matching how a standalone notification's dispatch error is
  already just logged rather than severing the connection.
- **Disallowed sub-methods:** `batch` (no nesting) and
  `load_image`/`update_image` (their binary side-channel payload can't be
  framed inside the array) — all skipped with a log line. `destroy_image`
  *is* allowed: it carries no payload, so a client can clear a region and
  release the image it held in one frame. Input / subscription messages (`report_*`,
  `subscribe`, `scroll_view`, …) are accepted but their server→client
  broadcast is suppressed, so a batch is really for draw / layer / table
  / metadata commands.

## Error reporting

A notification that fails in its handler is otherwise invisible to its
sender — there's no response, and (unlike a failed request) the
connection isn't severed; the server just logs it. A connection that
wants to know can **subscribe to `"error"`** and pull the failures it
caused with `get_errors`. No JSON-RPC error *responses* exist yet
(roadmap Milestone 0) — this is the interim visibility path. See
decisions.md's Error reporting section.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `subscribe` with `"error"` in `events` | request | — | — | ✅ turns on per-connection error capture: from here on, any notification this connection sends that errors in its handler (standalone or inside a `batch`) is recorded in a ring of the last **5**. Not a broadcast stream — nothing is pushed |
| `get_errors` | request | *(none)* | `{errors: [{method, code, seq}], dropped}` | ✅ returns the ring oldest-first, then **drains** it. `method` is the failed notification's method, `code` the `DispatchError` name (e.g. `"LayerPermissionDenied"`, `"UnknownLayer"`), `seq` a per-connection monotonic counter. `dropped` is how many records were lost to a full ring since the last `get_errors`. Empty with `dropped: 0` for a connection that never subscribed to `"error"` |

## Animation

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `animate` | request | `{node, property}, target_value, duration, easing, mode (once/loop)` | animation handle | 🔶 |
| `animation_complete` | notification, server→client | `animation_handle` | — | 🔶 |

## Input

Two independent, separately-subscribable streams (raw events and mapped
actions) per decisions.md's Input model. Raw key/mouse-button events are
implemented end to end (an input-capturing process reports what it sees;
subscribers get it re-broadcast); `resize`, `scroll` and `mouse_move` are
implemented (the host reports its own window-size / scrollback-view /
pointer changes in-process, subscribers get the new value re-broadcast);
wheel-delta scroll, gamepad, IME, and action maps are all still open.

**Client side: one ordered queue.** `InputListener` queues every
notification it receives — keys, text, mouse, resize, scroll,
`scroll_offset`, layout, pane events, context, terminal replies — as one
`glyphwire.Event` tagged union in arrival order, behind one semaphore.
`listener.next(timeout)` blocks until *any* of them arrives, so a program
needs no poll interval, and a resize that arrived after a keystroke is
handled after it. `ev.deinit(alloc)` frees whatever the variant owns.
`KeyEvent.ctrl()`/`shift()`/`alt()`/`super()` read the event's `mods`. The
older per-stream `pollX`/`waitX` methods remain as filters over the same
queue, and the `size()`/`scroll()`/`visibleContext()` caches are unchanged.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `subscribe` | request | `events: []str` (e.g. `["key", "text", "mouse_button", "scroll"]`), `pane?` | acked subscription list | ✅ `pane` binds this connection to a pane at the same time, exactly as `attach_pane` would. Folded in rather than sent separately because `subscribe` is what arms the broadcast fan-out: a connection subscribed but not yet bound would, until the binding landed, be gated against the wrong pane and could receive another program's keystrokes. One message makes that window impossible rather than merely small. An unknown pane is ignored rather than failing the subscribe |
| `report_key` | notification, client→server | `key, pressed` | — | ✅ from whatever process captures input (`glyphwire-host`); see also `Server.reportKey`/`reportKeyRepeat` for a caller reporting in-process rather than over the wire. Deduped against the session's window-wide down-set (a press while already down, or a release while up, is not broadcast), which is why that set is not per-context: a release that arrives after focus moved to another program's context still clears the press it pairs with |
| `report_text` | notification, client→server | `text` (UTF-8 string, ≥1 codepoint) | — | ✅ committed text input, already resolved through the OS keyboard layout / dead keys / IME — the only correct source for a non-US layout, an AltGr combo or CJK. Fanned straight out as `text`; touches no down-set. In-process path: `Server.reportText`. Empty string is dropped |
| `report_mouse_button` | notification, client→server | `button, pressed, px, cell, view_offset?` | — | ✅ `view_offset` (default 0) is the root layer's scrollback view offset at click time, carried into the `mouse_button` broadcast so a subscriber can resolve `cell` against the right scrolled-back row (see `get_metadata`) |
| `report_mouse_move` | notification, client→server | `px, cell` | — | ✅ updates `get_input_state`'s cursor fields every call; also fans out a `mouse_move` broadcast, but only when `cell` changed (per-pixel motion within one cell is dropped). In-process path: `Server.reportMouseMove` |
| `get_input_state` | request | — | `keys_down, mouse_buttons_down, cursor_px, cursor_cell` | ✅ one-time snapshot; `InputListener` is the live-updating equivalent, fed by the notifications below. `keys_down` / `mouse_buttons_down` are the real keyboard and mouse, the same whichever context the caller is on; `cursor_px` / `cursor_cell` are the last pointer position reported against the caller's own context |
| `key_down` / `key_up` | notification, server→client | `key, mods` | — | ✅ `mods` is `{ctrl, alt, shift, super}`, left and right folded, **as held when the host routed this event** (from the session's window-global modifier state; a modifier's own press already counts itself). Use it for chords instead of asking `isKeyDown` when the event is consumed: a client that falls behind a quick Ctrl+W would otherwise read Ctrl as already released and handle a plain `w`. Also re-sent (still `key_down`) on typematic repeat for a held key — no separate "this was a repeat" signal on the wire. glyphwire-host synthesizes the repeat (the OS's own never reaches it as a fresh event): **named keys** repeat unmodified — arrows, `page_up`/`page_down`, `home`/`end`, `backspace`, `delete`, `tab`, `enter`, `escape`, `F1`–`F24` — while a **text key** repeats only as a Ctrl/Alt chord (`Ctrl+U`), since a held letter already repeats down the `text` stream. Timing comes from `set_key_repeat` (below) |
| `set_key_repeat` | notification, client→server | `delay_ms?, interval_ms?` | — | ✅ the typematic repeat cadence glyphwire-host runs at while the issuing connection's active context is **focused**: `delay_ms` is the hold before the first repeat, `interval_ms` the gap between repeats after it (`core.Context.key_repeat`). Equal values mean no initial hold — the first repeat lands one interval after the press, which is what an editor wants (zoe sets it) and what a shell, where a repeat can re-run a command, does not. Governs **both** streams: the `key_down` repeats of named keys and the `text` repeats of held printable keys. **Every arrival also cancels the repeat in flight**: whatever is held stops repeating until it is pressed again, and a focus change does the same. A program only retimes when the meaning of its keys has changed, and the key still held across that change was pressed under the old meaning — zoe's `i` types, so without this the keystroke that switched to insert mode goes on typing itself into the buffer it just opened. So a client whose keys mean different things in different modes should send this on **every** mode change, not only when the numbers differ (zoe does; both its cadences default to 300/30). Both fields absent clears the override and returns the context to the host's default (`host.conf.lua`'s `key_repeat_delay_ms` / `key_repeat_interval_ms`); one alone keeps the other from the current override, or from the protocol defaults (500 / 40 ms) if there is none. The host clamps `delay_ms` to 0..5000 and `interval_ms` to 10..2000. Applies from the next press, never mid-hold. Client API: `Client.setKeyRepeat` |
| `text` | notification, server→client | `text` | — | ✅ committed text (see `report_text`). Subscribe with `"text"`. On the client, `InputListener` merges this with `key_down`/`key_up` into one arrival-ordered queue (`pollInputEvent`/`waitInputEvent` → `InputEvent{key,text}`) so "type then Enter" can't reorder. A **held** printable key repeats on this stream at the session's own cadence, not the desktop's: glyphwire-host swallows the OS's text auto-repeat and re-sends the committed text on the same clock that drives `key_down` repeats, so one held key can't run at two rates (see `set_key_repeat`). Text with no key press of its own behind it — an IME commit above all — never repeats, and its OS repeats are passed through untouched rather than dropped |
| `mouse_button` | notification, server→client | `button, pressed, px, cell, view_offset, mods` | — | ✅ `mods` as on `key_down`. `view_offset` is the scrollback rows shown when the click happened (0 at the live tail) — feed it straight into `get_metadata`'s `view_offset` |
| `mouse_move` | notification, server→client | `{px, cell, mods}` | — | ✅ `mods` as on `key_down`. Sent on a pointer **cell** change (the host coalesces per-pixel motion, which is also the granularity an xterm mouse report needs). Subscribe with `"mouse_move"` — opt-in on its own so a click-only client doesn't get the motion firehose; `InputListener` is the client-side consumer: consecutive moves coalesce into the newest, and past 512 queued moves the oldest is dropped if nothing drains them. glyphwire-shell subscribes session-wide but only consumes it while a pty child has `?1002`/`?1003` motion reporting on |
| `mouse_scroll` | notification, server→client | delta | — | 🔶 wheel-delta stream; separate from `scroll` below, which reports the resolved scrollback view offset, not raw wheel ticks |
| `gamepad_*` | notification, server→client | — | — | 🔶 |
| `resize` | notification, server→client | new `{cols, rows}` | — | ✅ sent when `glyphwire-host`'s (now user-resizable) window changes size, after the root layer and every base-size-tracking layer have been resized (see Property names' `size` above for the bottom-anchored content behavior). Reported in-process by the host via `Server.reportResize`, same path as `reportKey`; subscribe with `"resize"`. `InputListener` (`pollResizeEvent`/`waitResizeEvent`/`size`) is the client-side consumer |
| `shutdown` | notification, server→client | `{grace_ms}` | — | ✅ sent once when the host window is closing, so a client can flush persistent state and exit cleanly instead of being cut off when the socket closes. `grace_ms` is roughly how long the host waits for this connection's process to exit before it tears down anyway (`Server.reportShutdown`, called from `host/main.zig` after the render loop ends — the `serveForever` thread is still up so the notification still lands). Subscribe with `"shutdown"`; on the client it arrives on the same ordered queue as `key`/`text` (`InputEvent.shutdown`). glyphwire-shell subscribes and treats it exactly like a typed `exit` (flush history + the `zj` database, then return from its prompt loop) |
| `scroll` | notification, server→client | `{layer?, offset, max}` | — | ✅ sent whenever a layer's scrollback view offset moves. `layer` omitted (or `null`) is the root layer — the host's mouse wheel / scrollbar (`Server.reportScroll`) or another client's `scroll_view` with no `layer` (e.g. glyphwire-shell's browse cursor); a handle is a non-root layer's own ring — a `scroll_view` naming a layer, or the host's mouse wheel over a `gmux`-style pane that has `scrollback_rows` but no `scroll_offset` slack (`Server.reportLayerScroll`). Subscribe with `"scroll"`; `InputListener` (`pollScrollEvent`/`waitScrollEvent`/`scroll`, `ScrollEvent.layer`) is the client-side consumer — a root-only subscriber filters on `layer == null`. See Property names' `scroll` above |
| `scroll_offset` | notification, server→client | `{layer, row, col, max_row, max_col}` | — | ✅ a **layer's** viewport moved over its content grid — the host's wheel over that pane or a drag on its scrollbar. On a self-scrolling pane (one with a `content_extent`) this is the host asking the client to move: the virtual offset advanced and the client should redraw its visible rows against the new position. Carries the handle, unlike `scroll`, which is always the root layer's scrollback; carries the maxima so a subscriber can redraw without a follow-up request. Sent only when the offset actually moved, so a wheel spun against the end of the content is silent. Rides the `"scroll"` subscription (a client that wants to know the view moved wants both kinds); `InputListener.pollScrollOffsetEvent` is the client-side consumer |
| `layout` | notification, server→client | `{layers: [{layer, row, col, cols, rows}]}` | — | ✅ every pane whose bounds changed after the split tree was re-laid-out — a window resize, a divider drag, or any of the Splits messages above. One notification for the whole tree rather than one per pane, so a client redraws once against a consistent set of bounds instead of N times against partially-updated ones. Subscribe with `"layout"` — its own flag rather than folding into `resize`, since a client with no panes shouldn't have to parse per-layer bounds. `InputListener.pollLayoutEvent` is the consumer, and **the caller owns the returned event** (it carries a slice) |
| `pane_layout` | notification, server→client | `{panes: [{pane, row, col, cols, rows}]}` | — | ✅ every **pane** whose window rect changed. The window-level counterpart of `layout`, and the only message in the protocol that reveals pane geometry — a window manager subscribes to it and nothing else has a reason to. Subscribe with `"panes"`. `InputListener.pollPaneLayoutEvent` is the consumer, and the caller owns the returned event |
| `pane_exit` | notification, server→client | `{pane, status}` | — | ✅ the program `spawn_in_pane` started in `pane` has finished. The pane itself is untouched: it belongs to the manager, not to the program, so closing it is the manager's decision. Subscribe with `"panes"`; `InputListener.pollPaneExitEvent` is the consumer |
| `window_key_down` / `window_key_up` | notification, server→client | `{key}` | — | ✅ a named key that followed the registered window prefix (an arrow, Enter, an `F`-key — or a printable key with Ctrl/Alt held, which commits no text), so it is a window command rather than input for any program. **Addressed to the manager, never broadcast** — a window command has exactly one recipient by definition. Subscribe with `"window_keys"`. Delivered as `InputEvent.window_key`, a variant distinct from `key` so a manager cannot confuse a command for its own with input meant for a pane |
| `window_text` | notification, server→client | `{text}` | — | ✅ committed text that followed the window prefix. How **every printable** prefix command arrives: while the prefix is armed, a printable key's own press is withheld and the prefix stays armed, so the command is the layout-/IME-resolved text (`"`, not `shift`+`apostrophe`) rather than a key name. A bare modifier press never consumes the armed prefix either. Delivered as `InputEvent.window_text` |
| `context` | notification, server→client | `{context, cols, rows}` | — | ✅ the visible context changed — `create_context` / `activate_context` / `destroy_context`, or the disconnect-cull auto-restore. `context` is the now-visible context's handle, `cols`/`rows` its root layer's size. A client that manages its own context compares `context` against its own handle to tell "I'm on screen" from "I've been backgrounded (or culled)". Subscribe with `"context"`; `InputListener` (`pollContextEvent`/`waitContextEvent`/`visibleContext`) is the client-side consumer |
| `selection` | notification, server→client | `{active, anchor?: {above, col}, active_end?: {above, col}}` | — | ✅ sent whenever a layer's selection changes (any of `set_selection`/`update_selection`/`clear_selection`, or glyphwire-host's in-process path). Subscribe with `"selection"`. See the Selection & Clipboard section |
| `copy_request` | notification, server→client | *(none)* | — | ✅ the copy shortcut (Ctrl+Shift+C) was pressed with nothing selected — a subscriber that owns editable text (glyphwire-shell) answers with `set_clipboard`. Subscribe with `"clipboard"` |
| `paste` | notification, server→client | `{text}` | — | ✅ committed clipboard text to insert (Ctrl+Shift+V). Distinct from `text` so a client can treat it differently — glyphwire-shell inserts it literally, newlines included, without submitting. Subscribe with `"clipboard"`; on the client it arrives on the same ordered queue as `key`/`text` (`InputEvent{paste}`), and `copy_request` as `InputEvent.copy_request` |
| `terminal_reply` | notification, server→client | `{bytes}` | — | ✅ the bytes a `write_text` produced in answer to a terminal query (`CSI 6n` cursor position, `CSI c` / `CSI > c` device attributes, DECRQM) in the text it mirrored — see `write_text`'s ESC-sequence note above and decisions.md's B1 screen model. Subscribe with `"terminal"`; `InputListener.pollTerminalReply` is the client-side consumer. glyphwire-shell subscribes while a pty child is foregrounded and writes the bytes to the pty master |
| *(IME preedit / composition)* | — | — | — | ⬜ only *committed* text crosses the wire today (`text`, above). glyphwire-host **does** draw the live composition, but host-locally: SDL3's `SDL_EVENT_TEXT_EDITING` feeds `host/preedit.zig`, which renders it at the caret and points the OS text-input area there so the IME's candidate window follows. Keys the IME consumes while composing never reach the key stream. A preedit/composition *notification* for other clients to draw their own is still open |
| `action` | notification, server→client | action name, phase | — | 🔶 sent alongside raw events, never instead of |

## Action maps

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `bind_actions` | request or notification, ⬜ not decided | `{action_name: bindings}` map | — | 🔶 |

## Capability negotiation

Only required before sending a feature-gated message (images, animation,
input subscriptions, action maps). The baseline tier — `write_text`,
`get_property`/`set_property` — needs none of this, which is the whole
point of the "no negotiation for the common case" decision.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `initialize` | request | client capabilities (subscriptions wanted) | server capabilities (max layers, image formats, easings, color depth) | 🔶 |
| `initialized` | notification | — | — | 🔶 |

## Remote transport (`glyphwire --ssh`, `gwssh`)

Not a message catalog change — the client-facing wire is identical. When
the host runs `--ssh <dest>`, or a shell in a pane asks for `start_remote`,
a `gw-agent` on the far side carries every remote client's socket bytes
over one `ssh` trunk, tagged by channel. The trunk framing (its own layer,
below the `Content-Length` frames it carries) is:

```
GW-Mux: <kind> <channel> <len>\r\n\r\n<payload>
```

- `kind`: `hello` (agent→host, once), `open` / `close` (channel
  lifecycle, ids allocated by the agent), `data` (≤ 16384 payload bytes;
  a larger write spans consecutive `data` frames).
- `channel`: `u32`, decimal.
- `len`: payload byte count, decimal; always `0` for `hello` / `open` /
  `close`.

Each channel's payload is one client connection's ordinary byte stream
(`Content-Length` frames + the `load_image` side-channel), spoken
verbatim end to end. See `src/mux.zig` and decisions.md's "Remote
sessions" section.

The agent is invoked as `gw-agent --stdio [--pane N] [--ctx N]
[--name <dest>]`. All three are copied straight into the remote shell's
environment (`GLYPHWIRE_PANE`, `GLYPHWIRE_CTX`, `GLYPHWIRE_REMOTE`) and
never interpreted there — a pane handle is the *host's* number. That is
the whole seating handshake: the remote shell binds itself to the right
rectangle through exactly the `attach_pane` a locally spawned child
sends, and the agent still parses no protocol. Omitting them (what
`glyphwire --ssh` sends) means the window's own root pane and default
context. `GLYPHWIRE_REMOTE` is also what a remote shell's prompt reads for
`{remote}` / `{remote_dest}`.

The agent has to be findable **on the remote box's `PATH`**, and a
non-login `ssh -T` session has a minimal one — a work tree's
`zig-out/bin` is not on it. Override the command per connection with
`gwssh --remote-command <path>`, or once with `$GLYPHWIRE_REMOTE_COMMAND`
in the shell that runs `gwssh`. When it is missing, `ssh` passes the
remote shell's 127 through and `gw-shell` says so in the pane rather than
leaving it in the host's log.

## Not planned for v1

- Capability caching (server-side, keyed by connecting binary path — see
  decisions.md's Deferred section). No message surface anyway; it would
  be transparent to clients if built.
