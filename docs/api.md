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

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| *(inherit)* | — | — | — | ✅ a new connection acts on whatever context is visible at accept time |
| `create_context` | request | `width?, height?, scrollback_rows?` | `{context}` (handle) | ✅ allocates a fresh context (its root layer defaults to the visible context's size), **shows it immediately**, and retargets the issuing connection onto it — later `layer?`-scoped messages from this connection now draw on the new context, not the shell's. The connection becomes its first **owner**: the context (and everything in it) is culled once every owning connection disconnects, so a full-screen program that dies without `destroy_context` doesn't leave its surface stuck on screen. Icons/images resolve through the root context's catalog, so `draw_icon` names the host registered still work |
| `destroy_context` | notification | `context` | — | ✅ frees a context and every layer/split/table/image in it; if it was visible, visibility pops to whatever context was under it (the alt-screen auto-restore). **Ownership-checked** like `destroy_layer`: honored only from a connection that owns the context (created it, or `adopt_context`'d it) — a non-owner's call reports `ContextPermissionDenied` and nothing is touched. The root context reports `RootContextImmutable`; an unknown handle `UnknownContext`. An in-process caller bypasses the check |
| `activate_context` | notification | `context` | — | ✅ makes `context` the visible one **without** changing which context the issuing connection draws on — a client backgrounds itself by activating the root context (handle `0`) and restores itself by activating its own handle again. Moves the handle to the top of the visibility stack (it's there once, wherever it was). `UnknownContext` for an unknown handle; a no-op if it's already visible |
| `attach_context` | notification | `context` | — | ✅ retargets the issuing connection onto an *existing* context (`create_context` does this for a new one) — every later `layer?`-scoped message resolves against it, and, for a subscribed connection, the raw input streams it receives now follow that context's visibility. The primitive a paired `InputListener` uses to join the context its `Client` created. Ownership is untouched (attaching isn't adopting). `UnknownContext` for an unknown handle |
| `adopt_context` | notification | `context` | — | ✅ adds the issuing connection to `context`'s owner set, so it outlives its original creator disconnecting as long as this connection stays up (and this connection may then `destroy_context` it). The context-level mirror of `adopt_layer`. `UnknownContext` for an unknown or root handle |

Raw input events (`key`, `text`, `mouse_button`, `mouse_move`) are
delivered **only to connections whose current context is the visible
one** — a backgrounded full-screen editor stops receiving keystrokes
meant for the shell that's now on screen, and vice versa. Every other
server→client event (`resize`, `layout`, `scroll`, `selection`,
`context`, …) still fans out to all subscribers regardless, so a
backgrounded client can keep its panes current for when it's shown
again.

## Layer

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `create_layer` | request | `width?, height?, scrollback_rows` | layer handle | ✅ always parented to the root layer (no `parent`/`context` params — there's only one context per decisions.md's current scope, and deeper nesting isn't exercised yet); `width`/`height` default to the root layer's own size. The connection that issues this becomes the layer's first **owner** — see decisions.md's Layer ownership & lifecycle: the layer is culled once every owning connection has disconnected, so a program that dies without `destroy_layer` doesn't leave its content stuck on the host |
| `destroy_layer` | notification | `layer` | — | ✅ frees the layer and drops it from compositing; the root layer (handle 0, i.e. an omitted `layer` elsewhere) can't be destroyed this way — an unknown or root handle both just report `UnknownLayer`. **Ownership-checked:** honored only from a connection that owns the layer (created it, or `adopt_layer`'d it); a non-owner's call reports `LayerPermissionDenied` and the layer is untouched. An in-process caller (glyphwire-host, headless `server/main.zig`) owns nothing and bypasses the check |
| `adopt_layer` | notification | `layer` | — | ✅ adds the issuing connection to `layer`'s owner set, so the layer outlives its original creator disconnecting as long as this connection stays up, and this connection may then `destroy_layer` it. Errors `UnknownLayer` for an unknown or root handle; a no-op for an in-process caller. For handing ongoing responsibility for a layer from one process to another |
| `get_property` | request | `layer?, property` | property value | ✅ (`cursor`, `revision`, `position`, `cell_position`, `size`, `viewport`, `scroll`, `scroll_offset`, `scrollbars`, `visibility`) |
| `set_property` | notification | `layer?, property, value` | — | ✅ (`cursor`, `position`, `cell_position`, `size`, `viewport`, `scroll_offset`, `scrollbars`, `visibility`) — a write to a get-only property, or to `size`/`visibility` on the root layer, reports `ReadOnlyProperty` |
| `raise_layer` | notification | `layer, above?` | — | ✅ moves `layer` up the compositing order: directly above `above`, or to the very top when omitted. Creation order is only the *initial* stacking, so this is what puts a completion popup created early back over a sidebar created later. The root layer is never in the order (it is always the bottom of the stack), so naming it as either handle reports `UnknownLayer`, same as `destroy_layer`. Raising a layer above itself is a no-op, not an error; a rejected restack leaves the order exactly as it was |
| `lower_layer` | notification | `layer, below?` | — | ✅ the mirror of `raise_layer` — directly below `below`, or all the way to the bottom when omitted |
| `get_cells` | request | `layer?, view_offset?` | full row-major cell snapshot (`cols, rows, revision, cells`) | ✅ each cell also reports `fg_icon?` (an icon composited *over* the background — `draw_icon`'s `foreground: true`, and every table body icon; same shape as `bg_icon`), `metadata_id?` (see Metadata below), and `wide?` alongside `bg`/`bg_image`/`bg_icon` — just the id/handle, not the resolved JSON, same "handle, not content" treatment `bg_image`/`bg_icon` give image/icon handles. `wide` is `"lead"` on the left cell of a 2-cell East Asian wide character (it holds the grapheme in `g`), `"spacer"` on its blank right neighbour (empty `g`, but it carries the lead's `bg`/`metadata_id` so a background spans the pair and a hit-test on either half resolves the same), and absent for an ordinary 1-cell character. The server computes width from Unicode East Asian Width (`W`/`F` wide, `A` treated as narrow) — `write_text` itself is unchanged. `view_offset` (default 0 = the live viewport) reads that many rows of scrollback above the live viewport, so a client can snapshot exactly what's on screen while the host is scrolled back |
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
| `scroll_offset` | `{row, col}` — where the `viewport` sits within the content grid, clamped server-side to `size - viewport` on each axis. Get also returns `max_row`/`max_col`. This is the layer's scroll position, and the host moves it directly on a wheel tick or a scrollbar drag (broadcasting `scroll_offset`, below) rather than asking the client to. Distinct from `scroll`, which is the terminal-style *scrollback ring* view: the two compose, `scroll` picking which rows are live and `scroll_offset` the window over them. A layer created with `scrollback_rows: 0` — every pane in a TUI — only ever uses this one | ✅ |
| `scrollbars` | `{vertical, horizontal}` — which bars the host draws inside this layer's own bounds, opt-in per axis. Get returns the two flags plus `row`/`col` and `max_row`/`max_col`, i.e. everything needed to draw or interpret a bar; the four derived fields are ignored on a set. Opt-in rather than automatic because a statusline or a popup can easily have content wider than its pane and should still not sprout a bar. A bar is also skipped on an axis with nothing to scroll. Distinct from the window's own right-edge scrollbar, which is the root layer's scrollback and is unchanged | ✅ |
| `clip` | clip rect | 🔶 |
| `scroll` | `{offset, max}` — how far the on-screen view is scrolled back into this layer's cell-grid scrollback ring (`offset` rows above the live tail, out of `max` = `history_len` retained). Get-only through `get_property`; move it with `scroll_view` (above), which also broadcasts a `scroll` notification. `offset == 0` is the live tail | ✅ |
| `visibility` | `{visible}` — whether glyphwire-host composites this layer at all. A hidden layer keeps every cell, table and metadata id it had; the renderer just skips it (and keeps its cached quad batch, so showing it again costs no rebuild). That's what a toggled sidebar wants — `destroy_layer` plus a rebuild loses the tree's scroll position and its metadata ids for nothing. Non-root only: hiding the root layer would blank the session with no wire path back, the same reason `destroy_layer` refuses it, so root reports `ReadOnlyProperty` | ✅ |

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
| `create_split` | request | `axis` (`"row"` — children left to right, vertical dividers; `"column"` — top to bottom, horizontal dividers) | split handle | ✅ an unknown axis reports `InvalidSplitAxis`. A fresh split draws and lays out nothing until it has children *and* is reached from `set_root_split` |
| `destroy_split` | notification | `split` | — | ✅ frees the container; its children (layers and nested splits) are **not** destroyed — a layer outlives the pane it sat in. Destroying the root split clears the root, dropping the layout back to hand-positioned layers |
| `set_split_children` | notification | `split, children: [{layer? \| split?, weight? \| fixed?}]` | — | ✅ replaces the child list wholesale (one message rather than insert/remove/reorder: a client rebuilding an arrangement always knows the whole new list). Each entry names exactly one of `layer`/`split` — both or neither reports `InvalidSplitChild` — and at most one of `weight` (a share of what's left) or `fixed` (exactly that many cells along the split's axis), defaulting to `weight: 1`. **`fixed` children are measured first and `weight` children share the remainder**, which is what lets a one-row statusline sit beside a pane that takes "the rest" without the client recomputing a fraction on every resize. The last weighted child absorbs the rounding remainder so the children plus dividers fill the split exactly |
| `set_root_split` | notification | `split?` | — | ✅ which split fills the context; null tears the layout down without destroying anything. Triggers a re-layout, and so the first `layout` notification |
| `move_divider` | notification | `split, index, delta` | — | ✅ drags the band after child `index` by `delta` cells along the axis, growing one neighbour and shrinking the other. What glyphwire-host sends for a mouse drag; a client can send it too (a keyboard "grow this pane" binding). A `fixed` neighbour keeps its cells and just gets more or fewer; a `weight` pair keeps its **combined** weight and re-splits it by the new ratio, so the rest of the tree is undisturbed. Clamped so neither neighbour is squeezed below one cell — a pane at zero could never be grabbed back |

Every one of these re-lays-out the tree and broadcasts a `layout`
notification (see Input) naming each pane whose bounds actually moved; a
re-layout that changes nothing is silent. A window resize does the same,
after its own `resize` notification.

`divider_cells` (the gap between two children, 1 by default) is a
`Context` field the host owns; there is no message for it yet.

## Text & Styling

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `write_text` | notification | `layer?, text, fg?, bg?, metadata_id?, transparent_bg?` | — | ✅ implicit cursor positioning + fg/bg color. `fg`/`bg` omitted means `core.default_style`'s. Style attributes beyond fg/bg (bold, italic, underline, strikethrough, dim) as first-class `Style` fields are still decided-not-wired — see decisions.md; SGR `bold`/`dim`/`inverse` below are folded into the resolved fg/bg colour instead. `metadata_id?` (see Metadata below) tags every cell the text touches with the same id — omitted (or any cell a later plain `write_text` overwrites) means untagged. `transparent_bg` (default `false`): leaves each touched cell's existing background untouched instead of resetting it to `default_style.bg` — `bg` is ignored when this is set. For text written over a background drawn some other way (e.g. `draw_box`'s fill) that needs to stay visible through it — see decisions.md's Style section. **C0 control bytes** in `text` move the cursor rather than being drawn: `\n`/`\v`/`\f` act as newline (carriage return + line feed, so `"a\nb"` puts `b` at column 0 of the next row), `\r` returns to column 0, `\t` advances to the next 8-column tab stop (clamped to the last column, no wrap), `\b` steps back one column (non-destructive, a no-op at column 0); every other C0 byte and DEL is silently dropped. **`ESC` sequences (Phase A VT fallback — see decisions.md and `docs/investigations/libghostty-vt-fallback.md`):** `ESC [ … m` (SGR) is **interpreted** — 16/bright/256/truecolor fg+bg (`;` and `:` sub-parameter forms), `0` reset, `1` bold (promotes a basic fg to its bright variant), `2` dim (darkens the fg), `7`/`27` inverse (swaps fg/bg); italic/underline/blink/strikethrough are parsed and ignored. A set of `ESC [ …` cursor/erase/screen finals is interpreted too — `A`/`B`/`C`/`D` (cursor up/down/right/left), `G` (column), `d` (row), `H`/`f` (row;col), `J` (erase in display), `K` (erase in line); and, from the **B1 screen model** (see decisions.md): `r` (DECSTBM scroll region), `S`/`T` (scroll up/down), `L`/`M` (insert/delete line), `@`/`P`/`X` (insert/delete/erase char), `s`/`u` and `ESC 7`/`ESC 8` (save/restore cursor), `ESC M` (reverse index), `ESC [ ! p` (DECSTR soft reset — region to full, caret shown, no cursor move / no clear), `ESC [ ? 1049 h/l` / `?47` / `?1047` (alternate screen — a separate `width*height` buffer with no scrollback; the primary buffer and its scrollback are untouched), `ESC [ ? 25 h/l` (DECTCEM cursor show/hide — sets a flag the host caret renderer honours). **VT100 alternate charset (ACS line drawing):** `ESC ( <c>` / `ESC ) <c>` designate G0/G1 as the special graphics/line-drawing set (`c == '0'`) or ASCII (anything else, `'B'` in practice), and `SO`/`SI` (0x0E/0x0F) pick which of G0/G1 is active; while the active set is line drawing, a printable byte `` ` ``..`~` maps to its Unicode box-drawing/symbol glyph (the standard VT220/terminfo `acsc` table) instead of printing literally — this is how `smacs`/`rmacs` (xterm-style, redesignates G0 directly) and screen/tmux-style (SO/SI over a G1 designated once) both draw panel borders. Charset state is call-scoped like the SGR pen (see below). `ESC [ 6 n` / `5 n` / `c` / `> c` and DECRQM (`ESC [ ? Ps $ p`) are **answered**: the reply bytes ride a `terminal_reply` notification (see Input) for a `"terminal"` subscriber to write to the pty master, since a query can't be answered from the grid itself. Every **other** `ESC [ …` final and every `ESC ]`/`P`/`X`/`^`/`_ … BEL`/`ST` (OSC etc.) sequence is still **recognized and discarded**. **Nothing carries across `write_text` calls** — a half-parsed sequence is abandoned, and the SGR colour "pen" and alternate-charset state are reset, at the call boundary — so an unterminated `ESC ] …` can't swallow later writes, an un-reset `ESC [ 31 m` can't tint the next prompt or listing, and an un-closed `smacs` can't turn the next prompt into box-drawing glyphs. A colour is honoured only within the chunk that set it. **East Asian wide characters** (CJK, kana, Hangul, …) occupy two cells: the grapheme lands in the left cell, the right cell becomes a blank spacer (see `get_cells`' `wide`), and the cursor advances by 2; a wide character that would straddle the layer's right edge wraps to the next row first |
| `insert_cells` | notification | `layer?, count` (cursor-implicit like `write_text`) | — | ✅ ECMA-48's ICH: shifts cells at and after the cursor right within its row, discarding any past the row's right edge; row-scoped only, see roadmap.md's open questions |
| `delete_cells` | notification | `layer?, count` (cursor-implicit like `write_text`) | — | ✅ ECMA-48's DCH: removes cells at and after the cursor, shifting the row's remainder left and blanking the tail |
| `move_content` | notification | `layer?, top?, bot?, count?, direction?` | — | ✅ shifts `count` rows (default 1) of the layer's content grid vertically in place — the same primitive as CSI SU/SD, exposed so a client-scrolled pane can scroll without retransmitting every visible row. `top`/`bot` are an inclusive content-grid row range (default: the whole grid); `count` is clamped to the span; `direction` is `"up"` (default — content toward `top`, blank rows appear at `bot`) or `"down"`. Cells keep their styling, icons and metadata ids. An out-of-range range or a zero `count` is a silent no-op. Batchable, and meant to be batched right before the partial redraw of the newly-exposed band. `zoe`'s buffer pane uses it for every sub-screen scroll |
| `clear` | notification | `layer?, row?, col?, rows?, cols?` (all default: `row`/`col` to 0, `rows`/`cols` to "the rest of the layer from here") | — | ✅ resets a region back to blank (empty grapheme, default style, no image background); an all-defaulted `clear()` wipes the whole layer |

## Image

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `load_image` | request (binary side-channel: JSON header + raw bytes) | `format, bytes` | image handle | ✅ `format` is parsed — `"png"`, `"jpeg"` (also `"jpg"`), `"bmp"`, `"gif"` — and selects the header parser that measures the image (`core.imageDimensions`); an unknown format, or bytes that don't match the declared one, fails the request. Bytes are stored verbatim; pixel decoding stays renderer-only (glyphwire-host's stb_image auto-detects all four) |
| `get_image_info` | request | `handle` | natural pixel dimensions (read from the format's header — PNG IHDR / JPEG SOF / BMP DIB header / GIF screen descriptor — not a real decode) | ✅ |
| `draw_image` | notification | `layer?, handle, row?, col?, row_span, col_span, scale?` | — | ✅ clips to the given span rather than stretching to fill it; see decisions.md. `row`/`col` default to the layer's cursor when omitted, same convention as `write_text`. `scale` (default `1.0`) is the uniform, aspect-preserving factor the image is drawn at: `1.0` is natural pixel size (the original behavior), `< 1.0` shrinks it — `glyphwire-view` sends `target_width_px / image_width_px` so the image fits the layer's width, and still sizes `row_span`/`col_span` itself from the scaled dimensions (aspect-ratio-aware placement stays the client's job). Each covered cell then samples `cell_px / scale` source pixels; a non-positive `scale` is treated as `1.0`. Exposed back through `get_cells` on every image-backed cell (`bg_image.scale`) |
| `get_cell_metrics` | request | — | `{cell_px_w, cell_px_h}` | ✅ lets a client compute `row_span`/`col_span` from an image's natural size without hardcoding the session's cell pixel metrics |
| `draw_icon` | notification | `layer?, row?, col?, name, scale?, h_align?, v_align?, max_w?, max_h?, metadata_id?, foreground?` | — | ✅ `metadata_id?` (see Metadata below) tags the anchor cell, same as `write_text`'s. resolves `name` against `Context.icons` (seeded at `glyphwire-host` startup by a recursive scan of `assets/icons/` — a name is the file's path under that directory without the `.png` extension, e.g. `oxygen/folder`, `distro/arch`, `status/error`) and draws it anchored at exactly one cell. `scale`: `"fit"` (the default, aspect-preserved to exactly fill the cell), `"natural"` (the image's own pixel size, optionally shrunk — aspect preserved, never upscaled — to stay within `max_w`/`max_h` pixels if given; can still overflow past the anchor cell), or `"stretch"` (fills the cell exactly on both axes, aspect *not* preserved — what `draw_box`'s tiles use). `h_align`/`v_align` (`"start"`/`"center"`/`"end"`, default `"center"`) place the result within/around the cell for `"fit"`/`"natural"` (no-ops for `"stretch"`, which always fills exactly) — see decisions.md's Icon section, including why `"natural"` overflow is a rendering-only effect with no data-model footprint on the cells it visually spills into. `foreground` (default `false`): draws into `Cell.fg_icon` instead of `style.bg`, compositing over whatever background is already on that cell (e.g. a `draw_box` fill) instead of replacing it — see decisions.md's Icon section. Theming and a wire-exposed catalog listing are still open. `row`/`col` default to the cursor when omitted |
| `draw_box` | notification | `layer?, row?, col?, rows, cols, style, mode?` | — | ✅ resolves `style`'s 9 corner/edge/fill pieces (`"{style}/tl"`, ... — same `icons` catalog as `draw_icon`, from the bundled `assets/icons/box/` and `assets/icons/dialog/` subtrees) and composes them across the given rectangle per `mode` (`core.Layer.BoxMode`, default `"tile"`). `"tile"`: one tile per cell, each independently stretched (`draw_icon`'s `scale: "stretch"`) to fill its cell exactly so the border stays continuous regardless of the cell's aspect ratio — the original behavior. `"stretch"`: corners are still one tile each, but each edge/fill role's single source image is treated as one continuous picture spanning its whole run (`t`/`b` across every interior column, `l`/`r` across every interior row, `fill` across the whole interior rectangle), so e.g. a vertical gradient blends smoothly across however many cells the box spans instead of repeating per cell — see roadmap.md's `BoxMode.stretch` entry. `row`/`col` default to the cursor when omitted |

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
| `tag_metadata` | notification | `layer?, row, col, metadata_id` | — | ✅ sets exactly one cell's `metadata_id`, touching nothing else about it — unlike `write_text`/`draw_icon` below, which tag as a side effect of also drawing something. For a client that needs a cell tagged without changing what's drawn there, e.g. `glyphwire-ls` tagging the extra cells a `.natural`-scaled icon visually overflows into so browsing resolves correctly anywhere the icon actually renders, not just its anchor cell. `metadata_id` is required (there'd be no point tagging with nothing) and validated the same as `write_text`/`draw_icon`'s |

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
| `create_table` | request | `layer?, row?, col?, columns: [{name, kind?, sortable?, width, min_width?, h_align?}], style?` | table handle | ✅ `row`/`col` default to the layer's cursor, same convention `draw_box`/`draw_icon` use. `columns[].kind` is `"text"` (default) or `"number"` (which `SortKey` variant that column's cells are expected to sort on); `h_align` is `"start"` (default)/`"center"`/`"end"`. `style` is the same shape `table_set_style` takes (`max_icon_px` included). No rows yet — nothing is painted until `table_set_rows` |
| `destroy_table` | notification | `layer?, table` | — | ✅ blanks whatever the table last painted, then frees it and drops it from its layer's `table_order` |
| `table_set_rows` | notification | `layer?, table, rows: [[{display, sort_key?, icon?, fg?, metadata_id?}]]` | — | ✅ replaces every row wholesale, re-sorts per the table's current sort state, and repaints. `sort_key` is a bare JSON number or string (see decisions.md), defaulting to a copy of `display` when omitted. `icon` is an icon-registry name, resolved the same way `draw_icon`'s `name` is (errors `UnknownIcon` immediately on an unrecognized one) — drawn alongside that cell's `display` text, not in a separate column, and composited *over* the row's background (it lands in the cell's `fg_icon`, so an `alt_row_bg` stripe stays unbroken behind it and a `row_height > 1` `.natural`-scaled icon's overflow paints over the neighboring rows' backgrounds). The icon is drawn `draw_icon`'s `scale: "natural"` capped to `row_height` cell-heights (and further to `style.max_icon_px` if that's set and smaller), so even a default `row_height` of 1 fills the row's line rather than shrinking to `"fit"` one cell; it falls back to a one-cell `"fit"` only when the session's cell pixel metrics are unavailable. A row's cell count must match the table's column count, or this errors `TableRowShapeMismatch` |
| `table_set_sort` | notification | `layer?, table, column?, direction?` | — | ✅ `column: null` or `direction: "none"` (the default) both mean "back to insertion order"; otherwise `"ascending"`/`"descending"` on that column's `SortKey`. Repaints immediately — the message a future header-click handler would call |
| `table_set_style` | notification | `layer?, table, style` | — | ✅ replaces the table's whole style (`borders`, `header_separator`, `box_style`, `alt_row_bg`, `header_fg`, `header_bg`, `row_height`, `max_icon_px`) and repaints — e.g. the message a future "checkbox for alternating row colors" UI would call. `max_icon_px` (optional) is an upper bound in pixels on a body icon's rendered height: a body icon is normally capped to `row_height` cell-heights, and this caps it further, so a tall `-l -L` row still renders a modest icon regardless of the source art's resolution |
| `table_get_state` | request | `layer?, table` | `{columns, row_count, sort_column, sort_direction, style, painted: {row, col, rows, cols}, revision}` | ✅ structured config, not rendered cells — those are already readable through the owning layer's `get_cells` (a table paints into ordinary cells). For a future client that needs to know e.g. which columns are sortable before deciding what a header click should do. `painted` is the table's actual on-screen footprint (`core.Table.painted`) — `painted.row + painted.rows` is the first row below the whole table, border included if bordered, for a caller that wants to place its own next content there instead of overwriting the table (e.g. `glyphwire-ls -l`'s next shell prompt). A table taller than the viewport renders top-down and scrolls the layer as it goes (terminal-style), so its footprint fills the visible area (`painted.row` 0, `painted.row + painted.rows` == layer height) with the header + earliest rows now in scrollback — a caller placing follow-on content should see there's no on-screen row past the table and make room itself (e.g. `glyphwire-ls -l` emits a newline for the gap before the next prompt) rather than pass an absolute row past the bottom |

Interactivity (a header click toggling sort, a checkbox toggling
`alt_row_bg`) isn't wired up yet — the mutation messages above exist for
a future client (almost certainly `glyphwire-shell`, following the same
`get_metadata`-driven click-resolution pattern `activateSelectionAt`
already uses) to call once that lands. See decisions.md's Table section.

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

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `set_selection` | notification | `layer?, anchor: {above, col}, active: {above, col}` | — | ✅ starts or replaces the layer's selection (root when `layer` omitted). Broadcasts `selection` |
| `update_selection` | notification | `layer?, active: {above, col}` | — | ✅ moves only the active (dragging) end; a no-op if nothing is selected. Broadcasts `selection` |
| `clear_selection` | notification | `layer?` | — | ✅ broadcasts `selection` (inactive) |
| `get_selection` | request | `layer?` | `{active, anchor?: {above, col}, active_end?: {above, col}}` | ✅ `active` false ⇒ nothing selected, the two point fields absent |
| `get_selection_text` | request | `layer?` | `{text}` | ✅ the selected text: interior rows taken whole, first/last row clipped to the start/end column, each row's trailing blanks trimmed, rows joined with `\n`, a wide character's spacer half skipped. `""` when nothing (or a zero-width selection) is selected |
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
- **Disallowed sub-methods:** `batch` (no nesting) and `load_image` (its
  binary side-channel payload can't be framed inside the array) — both
  skipped with a log line. Input / subscription messages (`report_*`,
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

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `subscribe` | request | `events: []str` (e.g. `["key", "text", "mouse_button", "scroll"]`) | acked subscription list | ✅ |
| `report_key` | notification, client→server | `key, pressed` | — | ✅ from whatever process captures input (`glyphwire-host`); see also `Server.reportKey`/`reportKeyRepeat` for a caller reporting in-process rather than over the wire |
| `report_text` | notification, client→server | `text` (UTF-8 string, ≥1 codepoint) | — | ✅ committed text input, already resolved through the OS keyboard layout / dead keys / IME — the only correct source for a non-US layout, an AltGr combo or CJK. Fanned straight out as `text`; touches no down-set. In-process path: `Server.reportText`. Empty string is dropped |
| `report_mouse_button` | notification, client→server | `button, pressed, px, cell, view_offset?` | — | ✅ `view_offset` (default 0) is the root layer's scrollback view offset at click time, carried into the `mouse_button` broadcast so a subscriber can resolve `cell` against the right scrolled-back row (see `get_metadata`) |
| `report_mouse_move` | notification, client→server | `px, cell` | — | ✅ updates `get_input_state`'s cursor fields every call; also fans out a `mouse_move` broadcast, but only when `cell` changed (per-pixel motion within one cell is dropped). In-process path: `Server.reportMouseMove` |
| `get_input_state` | request | — | `keys_down, mouse_buttons_down, cursor_px, cursor_cell` | ✅ one-time snapshot; `InputListener` is the live-updating equivalent, fed by the notifications below |
| `key_down` / `key_up` | notification, server→client | `key` | — | ✅ also re-sent (still `key_down`) on typematic repeat for a held key — no separate "this was a repeat" signal on the wire |
| `text` | notification, server→client | `text` | — | ✅ committed text (see `report_text`). Subscribe with `"text"`. On the client, `InputListener` merges this with `key_down`/`key_up` into one arrival-ordered queue (`pollInputEvent`/`waitInputEvent` → `InputEvent{key,text}`) so "type then Enter" can't reorder |
| `mouse_button` | notification, server→client | `button, pressed, px, cell, view_offset` | — | ✅ `view_offset` is the scrollback rows shown when the click happened (0 at the live tail) — feed it straight into `get_metadata`'s `view_offset` |
| `mouse_move` | notification, server→client | `{px, cell}` | — | ✅ sent on a pointer **cell** change (the host coalesces per-pixel motion, which is also the granularity an xterm mouse report needs). Subscribe with `"mouse_move"` — opt-in on its own so a click-only client doesn't get the motion firehose; `InputListener` (`pollMouseMoveEvent`/`waitMouseMoveEvent`) is the client-side consumer, with a bounded queue that drops its backlog if nothing drains it. glyphwire-shell subscribes session-wide but only consumes it while a pty child has `?1002`/`?1003` motion reporting on |
| `mouse_scroll` | notification, server→client | delta | — | 🔶 wheel-delta stream; separate from `scroll` below, which reports the resolved scrollback view offset, not raw wheel ticks |
| `gamepad_*` | notification, server→client | — | — | 🔶 |
| `resize` | notification, server→client | new `{cols, rows}` | — | ✅ sent when `glyphwire-host`'s (now user-resizable) window changes size, after the root layer and every base-size-tracking layer have been resized (see Property names' `size` above for the bottom-anchored content behavior). Reported in-process by the host via `Server.reportResize`, same path as `reportKey`; subscribe with `"resize"`. `InputListener` (`pollResizeEvent`/`waitResizeEvent`/`size`) is the client-side consumer |
| `scroll` | notification, server→client | `{offset, max}` | — | ✅ sent whenever the root layer's scrollback view offset moves — the host's mouse wheel / scrollbar (`Server.reportScroll`) or another client's `scroll_view` (e.g. glyphwire-shell's browse cursor). Subscribe with `"scroll"`; `InputListener` (`pollScrollEvent`/`waitScrollEvent`/`scroll`) is the client-side consumer. See Property names' `scroll` above |
| `scroll_offset` | notification, server→client | `{layer, row, col, max_row, max_col}` | — | ✅ a **layer's** viewport moved over its content grid — the host's wheel over that pane, a drag on its scrollbar, or another client's `set_property`. Carries the handle, unlike `scroll`, which is always the root layer's scrollback; carries the maxima so a subscriber can redraw without a follow-up request. Sent only when the offset actually moved, so a wheel spun against the end of the content is silent. Rides the `"scroll"` subscription (a client that wants to know the view moved wants both kinds); `InputListener.pollScrollOffsetEvent` is the client-side consumer |
| `layout` | notification, server→client | `{layers: [{layer, row, col, cols, rows}]}` | — | ✅ every pane whose bounds changed after the split tree was re-laid-out — a window resize, a divider drag, or any of the Splits messages above. One notification for the whole tree rather than one per pane, so a client redraws once against a consistent set of bounds instead of N times against partially-updated ones. Subscribe with `"layout"` — its own flag rather than folding into `resize`, since a client with no panes shouldn't have to parse per-layer bounds. `InputListener.pollLayoutEvent` is the consumer, and **the caller owns the returned event** (it carries a slice) |
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

## Not planned for v1

- Capability caching (server-side, keyed by connecting binary path — see
  decisions.md's Deferred section). No message surface anyway; it would
  be transparent to clients if built.
