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
| `create_layer` | request | `context, parent?, width?, height?, scrollback_rows?` | layer handle | 🔶 |
| `get_property` | request | `layer, property` | property value | ✅ (`cursor` only) |
| `set_property` | notification | `layer, property, value` | — | ✅ (`cursor` only) |
| `get_cells` | request | *(implicitly the root layer — no `layer` param yet, see Phase 1 in roadmap.md)* | full row-major cell snapshot (`cols, rows, revision, cells`) | ✅ |

**Property names** (the `property` argument to `get_property`/`set_property` —
one generic mechanism per decisions.md rather than a bespoke get/set pair
per property):

| Property | Meaning | Status |
|---|---|---|
| `cursor` | `{row, col}` | ✅ |
| `size` | `{cols, rows}` — this is what answers "get window size" for the root layer, since a Context's base size **is** its root layer's default size | 🔶 |
| `position` | pixel-precise position in the parent layer | 🔶 |
| `clip` | clip rect | 🔶 |
| `scroll` | scroll offset (pixel-precise; distinct from the cell-grid scrollback ring in core.zig) | 🔶 |
| `visibility` | shown/hidden | 🔶 |

Live size changes arrive separately as a `resize` event (see Input
below) rather than requiring the client to poll `get_property(layer,
"size")` — polling still works, but a glyphwire-aware program that cares
about resizes should subscribe instead.

## Text & Styling

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `write_text` | notification | `layer, text, style, row?, col?` | — | ✅ implicit cursor positioning + fg/bg color only; explicit `row`/`col` and style attributes beyond fg/bg (bold, italic, underline, strikethrough, dim) are decided in decisions.md but not yet wired into `Layer.writeText` |
| `insert_cells` | notification | `count` (cursor-implicit, root-layer-implicit like `write_text`) | — | ✅ ECMA-48's ICH: shifts cells at and after the cursor right within its row, discarding any past the row's right edge; row-scoped only, see roadmap.md's open questions |
| `delete_cells` | notification | `count` (cursor-implicit, root-layer-implicit like `write_text`) | — | ✅ ECMA-48's DCH: removes cells at and after the cursor, shifting the row's remainder left and blanking the tail |

## Image

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `load_image` | request (binary side-channel: JSON header + raw bytes) | `format, bytes` | image handle | ✅ `format` is accepted but unchecked — PNG is the only format the core parses (`pngDimensions`); bytes are stored verbatim either way |
| `get_image_info` | request | `handle` | natural pixel dimensions (from the PNG IHDR chunk, not a real decode) | ✅ |
| `draw_image` | notification | `handle, row, col, row_span, col_span` (implicitly the root layer, like `write_text` — see Phase 1 in roadmap.md) | — | ✅ clips to the given span rather than stretching to fill it; see decisions.md |
| `get_cell_metrics` | request | — | `{cell_px_w, cell_px_h}` | ✅ lets a client compute `row_span`/`col_span` from an image's natural size without hardcoding the session's cell pixel metrics |
| `draw_icon` | notification | `row, col, name` | — | ✅ resolves `name` against `Context.icons` (seeded at `glyphwire-host` startup from `core.default_icon_manifest`) and draws it into exactly one cell; theming and a wire-exposed catalog listing are still open — see decisions.md's Icon section |
| `draw_box` | notification | `row, col, rows, cols, style` | — | ✅ resolves `style`'s 9 corner/edge/fill pieces (`"{style}-tl"`, ... — same `icons` catalog as `draw_icon`, see `core.default_box_manifest`) and tiles them across the given rectangle, one tile per cell |

## Animation

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `animate` | request | `{node, property}, target_value, duration, easing, mode (once/loop)` | animation handle | 🔶 |
| `animation_complete` | notification, server→client | `animation_handle` | — | 🔶 |

## Input

Two independent, separately-subscribable streams (raw events and mapped
actions) per decisions.md's Input model. Raw key/mouse-button events are
implemented end to end (an input-capturing process reports what it sees;
subscribers get it re-broadcast); mouse move as a live stream, scroll,
gamepad, resize, IME, and action maps are all still open.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `subscribe` | request | `events: []str` (e.g. `["key", "mouse_button"]`) | acked subscription list | ✅ |
| `report_key` | notification, client→server | `key, pressed` | — | ✅ from whatever process captures input (`glyphwire-host`); see also `Server.reportKey`/`reportKeyRepeat` for a caller reporting in-process rather than over the wire |
| `report_mouse_button` | notification, client→server | `button, pressed, px, cell` | — | ✅ |
| `report_mouse_move` | notification, client→server | `px, cell` | — | ✅ updates `get_input_state`'s cursor fields only, no broadcast — see below |
| `get_input_state` | request | — | `keys_down, mouse_buttons_down, cursor_px, cursor_cell` | ✅ one-time snapshot; `InputListener` is the live-updating equivalent, fed by the notifications below |
| `key_down` / `key_up` | notification, server→client | `key` | — | ✅ also re-sent (still `key_down`) on typematic repeat for a held key — no separate "this was a repeat" signal on the wire |
| `mouse_button` | notification, server→client | `button, pressed, px, cell` | — | ✅ |
| `mouse_move` | notification, server→client | position | — | 🔶 no live push stream yet — `report_mouse_move` only updates state, doesn't broadcast |
| `mouse_scroll` | notification, server→client | delta | — | 🔶 |
| `gamepad_*` | notification, server→client | — | — | 🔶 |
| `resize` | notification, server→client | new `{cols, rows}` | — | 🔶 moot today since `glyphwire-host`'s window is fixed-size, but should exist for whenever that changes |
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
