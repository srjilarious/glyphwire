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

No context-management message exists yet. A connecting program gets its
context purely through discovery (`GLYPHWIRE_CTX` env var, inherited)
today; the server auto-creates exactly one context at startup.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| *(inherit)* | — | *(implicit via `GLYPHWIRE_CTX`)* | — | ✅ |
| `create_context` | request | `width?, height?` | context handle | 🔶 |
| *(activate a background context)* | — | — | — | ⬜ open item: who's allowed to activate a context that isn't currently visible isn't decided |

## Layer

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `create_layer` | request | `width?, height?, scrollback_rows` | layer handle | ✅ always parented to the root layer (no `parent`/`context` params — there's only one context per decisions.md's current scope, and deeper nesting isn't exercised yet); `width`/`height` default to the root layer's own size |
| `destroy_layer` | notification | `layer` | — | ✅ frees the layer and drops it from compositing; the root layer (handle 0, i.e. an omitted `layer` elsewhere) can't be destroyed this way — an unknown or root handle both just report `UnknownLayer` |
| `get_property` | request | `layer?, property` | property value | ✅ (`cursor`, `revision`, `position`, `size`, `scroll`) |
| `set_property` | notification | `layer?, property, value` | — | ✅ (`cursor`, `position`) |
| `get_cells` | request | `layer?, view_offset?` | full row-major cell snapshot (`cols, rows, revision, cells`) | ✅ each cell also reports `fg_icon?` (an icon composited *over* the background — `draw_icon`'s `foreground: true`, and every table body icon; same shape as `bg_icon`) and `metadata_id?` (see Metadata below) alongside `bg`/`bg_image`/`bg_icon` — just the id/handle, not the resolved JSON, same "handle, not content" treatment `bg_image`/`bg_icon` give image/icon handles. `view_offset` (default 0 = the live viewport) reads that many rows of scrollback above the live viewport, so a client can snapshot exactly what's on screen while the host is scrolled back |
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
| `size` | `{cols, rows}` — this is what answers "get window size" for the root layer, since a Context's base size **is** its root layer's default size. Get-only: a client reads it (or subscribes to `resize`, below) but can't set it — the host owns the window size | ✅ |
| `position` | `{x, y}`, pixel-precise, relative to the layer's parent (the root layer for every `create_layer`-made layer today) | ✅ |
| `clip` | clip rect | 🔶 |
| `scroll` | `{offset, max}` — how far the on-screen view is scrolled back into this layer's cell-grid scrollback ring (`offset` rows above the live tail, out of `max` = `history_len` retained). Get-only through `get_property`; move it with `scroll_view` (above), which also broadcasts a `scroll` notification. `offset == 0` is the live tail | ✅ |
| `visibility` | shown/hidden | 🔶 |

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

## Text & Styling

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `write_text` | notification | `layer?, text, fg?, bg?, metadata_id?, transparent_bg?` | — | ✅ implicit cursor positioning + fg/bg color only; explicit `row`/`col` and style attributes beyond fg/bg (bold, italic, underline, strikethrough, dim) are decided in decisions.md but not yet wired into `Layer.writeText`. `fg`/`bg` omitted means `core.default_style`'s. `metadata_id?` (see Metadata below) tags every cell the text touches with the same id — omitted (or any cell a later plain `write_text` overwrites) means untagged. `transparent_bg` (default `false`): leaves each touched cell's existing background untouched instead of resetting it to `default_style.bg` — `bg` is ignored when this is set. For text written over a background drawn some other way (e.g. `draw_box`'s fill) that needs to stay visible through it — see decisions.md's Style section |
| `insert_cells` | notification | `layer?, count` (cursor-implicit like `write_text`) | — | ✅ ECMA-48's ICH: shifts cells at and after the cursor right within its row, discarding any past the row's right edge; row-scoped only, see roadmap.md's open questions |
| `delete_cells` | notification | `layer?, count` (cursor-implicit like `write_text`) | — | ✅ ECMA-48's DCH: removes cells at and after the cursor, shifting the row's remainder left and blanking the tail |
| `clear` | notification | `layer?, row?, col?, rows?, cols?` (all default: `row`/`col` to 0, `rows`/`cols` to "the rest of the layer from here") | — | ✅ resets a region back to blank (empty grapheme, default style, no image background); an all-defaulted `clear()` wipes the whole layer |

## Image

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `load_image` | request (binary side-channel: JSON header + raw bytes) | `format, bytes` | image handle | ✅ `format` is accepted but unchecked — PNG is the only format the core parses (`pngDimensions`); bytes are stored verbatim either way |
| `get_image_info` | request | `handle` | natural pixel dimensions (from the PNG IHDR chunk, not a real decode) | ✅ |
| `draw_image` | notification | `layer?, handle, row?, col?, row_span, col_span` | — | ✅ clips to the given span rather than stretching to fill it; see decisions.md. `row`/`col` default to the layer's cursor when omitted, same convention as `write_text` |
| `get_cell_metrics` | request | — | `{cell_px_w, cell_px_h}` | ✅ lets a client compute `row_span`/`col_span` from an image's natural size without hardcoding the session's cell pixel metrics |
| `draw_icon` | notification | `layer?, row?, col?, name, scale?, h_align?, v_align?, max_w?, max_h?, metadata_id?, foreground?` | — | ✅ `metadata_id?` (see Metadata below) tags the anchor cell, same as `write_text`'s. resolves `name` against `Context.icons` (seeded at `glyphwire-host` startup from `core.default_icon_manifest`) and draws it anchored at exactly one cell. `scale`: `"fit"` (the default, aspect-preserved to exactly fill the cell), `"natural"` (the image's own pixel size, optionally shrunk — aspect preserved, never upscaled — to stay within `max_w`/`max_h` pixels if given; can still overflow past the anchor cell), or `"stretch"` (fills the cell exactly on both axes, aspect *not* preserved — what `draw_box`'s tiles use). `h_align`/`v_align` (`"start"`/`"center"`/`"end"`, default `"center"`) place the result within/around the cell for `"fit"`/`"natural"` (no-ops for `"stretch"`, which always fills exactly) — see decisions.md's Icon section, including why `"natural"` overflow is a rendering-only effect with no data-model footprint on the cells it visually spills into. `foreground` (default `false`): draws into `Cell.fg_icon` instead of `style.bg`, compositing over whatever background is already on that cell (e.g. a `draw_box` fill) instead of replacing it — see decisions.md's Icon section. Theming and a wire-exposed catalog listing are still open. `row`/`col` default to the cursor when omitted |
| `draw_box` | notification | `layer?, row?, col?, rows, cols, style, mode?` | — | ✅ resolves `style`'s 9 corner/edge/fill pieces (`"{style}-tl"`, ... — same `icons` catalog as `draw_icon`, see `core.default_box_manifest`/`core.default_dialog_manifest`) and composes them across the given rectangle per `mode` (`core.Layer.BoxMode`, default `"tile"`). `"tile"`: one tile per cell, each independently stretched (`draw_icon`'s `scale: "stretch"`) to fill its cell exactly so the border stays continuous regardless of the cell's aspect ratio — the original behavior. `"stretch"`: corners are still one tile each, but each edge/fill role's single source image is treated as one continuous picture spanning its whole run (`t`/`b` across every interior column, `l`/`r` across every interior row, `fill` across the whole interior rectangle), so e.g. a vertical gradient blends smoothly across however many cells the box spans instead of repeating per cell — see roadmap.md's `BoxMode.stretch` entry. `row`/`col` default to the cursor when omitted |

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
| `create_table` | request | `layer?, row?, col?, columns: [{name, kind?, sortable?, width, min_width?, h_align?}], style?` | table handle | ✅ `row`/`col` default to the layer's cursor, same convention `draw_box`/`draw_icon` use. `columns[].kind` is `"text"` (default) or `"number"` (which `SortKey` variant that column's cells are expected to sort on); `h_align` is `"start"` (default)/`"center"`/`"end"`. No rows yet — nothing is painted until `table_set_rows` |
| `destroy_table` | notification | `layer?, table` | — | ✅ blanks whatever the table last painted, then frees it and drops it from its layer's `table_order` |
| `table_set_rows` | notification | `layer?, table, rows: [[{display, sort_key?, icon?, fg?, metadata_id?}]]` | — | ✅ replaces every row wholesale, re-sorts per the table's current sort state, and repaints. `sort_key` is a bare JSON number or string (see decisions.md), defaulting to a copy of `display` when omitted. `icon` is an icon-registry name, resolved the same way `draw_icon`'s `name` is (errors `UnknownIcon` immediately on an unrecognized one) — drawn alongside that cell's `display` text, not in a separate column, and composited *over* the row's background (it lands in the cell's `fg_icon`, so an `alt_row_bg` stripe stays unbroken behind it and a `row_height > 1` `.natural`-scaled icon's overflow paints over the neighboring rows' backgrounds). A row's cell count must match the table's column count, or this errors `TableRowShapeMismatch` |
| `table_set_sort` | notification | `layer?, table, column?, direction?` | — | ✅ `column: null` or `direction: "none"` (the default) both mean "back to insertion order"; otherwise `"ascending"`/`"descending"` on that column's `SortKey`. Repaints immediately — the message a future header-click handler would call |
| `table_set_style` | notification | `layer?, table, style` | — | ✅ replaces the table's whole style (`borders`, `header_separator`, `box_style`, `alt_row_bg`, `header_fg`, `header_bg`, `row_height`) and repaints — e.g. the message a future "checkbox for alternating row colors" UI would call |
| `table_get_state` | request | `layer?, table` | `{columns, row_count, sort_column, sort_direction, style, painted: {row, col, rows, cols}, revision}` | ✅ structured config, not rendered cells — those are already readable through the owning layer's `get_cells` (a table paints into ordinary cells). For a future client that needs to know e.g. which columns are sortable before deciding what a header click should do. `painted` is the table's actual on-screen footprint (`core.Table.painted`) — `painted.row + painted.rows` is the first row below the whole table, border included if bordered, for a caller that wants to place its own next content there instead of overwriting the table (e.g. `glyphwire-ls -l`'s next shell prompt) |

Interactivity (a header click toggling sort, a checkbox toggling
`alt_row_bg`) isn't wired up yet — the mutation messages above exist for
a future client (almost certainly `glyphwire-shell`, following the same
`get_metadata`-driven click-resolution pattern `activateSelectionAt`
already uses) to call once that lands. See decisions.md's Table section.

## Animation

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `animate` | request | `{node, property}, target_value, duration, easing, mode (once/loop)` | animation handle | 🔶 |
| `animation_complete` | notification, server→client | `animation_handle` | — | 🔶 |

## Input

Two independent, separately-subscribable streams (raw events and mapped
actions) per decisions.md's Input model. Raw key/mouse-button events are
implemented end to end (an input-capturing process reports what it sees;
subscribers get it re-broadcast); `resize` and `scroll` are implemented
(the host reports its own window-size / scrollback-view changes
in-process, subscribers get the new value re-broadcast); mouse move as a
live stream, wheel-delta scroll, gamepad, IME, and action maps are all
still open.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `subscribe` | request | `events: []str` (e.g. `["key", "mouse_button", "scroll"]`) | acked subscription list | ✅ |
| `report_key` | notification, client→server | `key, pressed` | — | ✅ from whatever process captures input (`glyphwire-host`); see also `Server.reportKey`/`reportKeyRepeat` for a caller reporting in-process rather than over the wire |
| `report_mouse_button` | notification, client→server | `button, pressed, px, cell, view_offset?` | — | ✅ `view_offset` (default 0) is the root layer's scrollback view offset at click time, carried into the `mouse_button` broadcast so a subscriber can resolve `cell` against the right scrolled-back row (see `get_metadata`) |
| `report_mouse_move` | notification, client→server | `px, cell` | — | ✅ updates `get_input_state`'s cursor fields only, no broadcast — see below |
| `get_input_state` | request | — | `keys_down, mouse_buttons_down, cursor_px, cursor_cell` | ✅ one-time snapshot; `InputListener` is the live-updating equivalent, fed by the notifications below |
| `key_down` / `key_up` | notification, server→client | `key` | — | ✅ also re-sent (still `key_down`) on typematic repeat for a held key — no separate "this was a repeat" signal on the wire |
| `mouse_button` | notification, server→client | `button, pressed, px, cell, view_offset` | — | ✅ `view_offset` is the scrollback rows shown when the click happened (0 at the live tail) — feed it straight into `get_metadata`'s `view_offset` |
| `mouse_move` | notification, server→client | position | — | 🔶 no live push stream yet — `report_mouse_move` only updates state, doesn't broadcast |
| `mouse_scroll` | notification, server→client | delta | — | 🔶 wheel-delta stream; separate from `scroll` below, which reports the resolved scrollback view offset, not raw wheel ticks |
| `gamepad_*` | notification, server→client | — | — | 🔶 |
| `resize` | notification, server→client | new `{cols, rows}` | — | ✅ sent when `glyphwire-host`'s (now user-resizable) window changes size, after the root layer and every base-size-tracking layer have been resized (see Property names' `size` above for the bottom-anchored content behavior). Reported in-process by the host via `Server.reportResize`, same path as `reportKey`; subscribe with `"resize"`. `InputListener` (`pollResizeEvent`/`waitResizeEvent`/`size`) is the client-side consumer |
| `scroll` | notification, server→client | `{offset, max}` | — | ✅ sent whenever the root layer's scrollback view offset moves — the host's mouse wheel / scrollbar (`Server.reportScroll`) or another client's `scroll_view` (e.g. glyphwire-shell's browse cursor). Subscribe with `"scroll"`; `InputListener` (`pollScrollEvent`/`waitScrollEvent`/`scroll`) is the client-side consumer. See Property names' `scroll` above |
| *(text/IME composition)* | — | — | — | ⬜ own state machine, not detailed yet — kept distinct from raw key events |
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
