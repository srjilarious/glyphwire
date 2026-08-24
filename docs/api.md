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

## Image

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `load_image` | request (binary side-channel: JSON header + raw bytes) | `format, bytes` | image handle | 🔶 |
| `get_image_info` | request | `handle` | natural pixel dimensions | 🔶 |
| `draw_image` | notification | `layer, handle, row, col, row_span, col_span` | — | 🔶 |
| *(icon-by-name)* | — | — | — | ⬜ post-v1, not designed in detail — see decisions.md's Icon section |

## Animation

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `animate` | request | `{node, property}, target_value, duration, easing, mode (once/loop)` | animation handle | 🔶 |
| `animation_complete` | notification, server→client | `animation_handle` | — | 🔶 |

## Input

Two independent, separately-subscribable streams (raw events and mapped
actions) per decisions.md's Input model — nothing here is implemented
yet.

| Message | Kind | Params | Result | Status |
|---|---|---|---|---|
| `subscribe` | ⬜ request or notification, not decided | event type list (raw, action, or both) | — | 🔶 mechanism decided (opt-in, X11 event-mask precedent), exact message shape ⬜ |
| `key_down` / `key_up` | notification, server→client | keycode, modifiers | — | 🔶 |
| `mouse_move` / `mouse_button` / `mouse_scroll` | notification, server→client | position, button/delta | — | 🔶 |
| `gamepad_*` | notification, server→client | — | — | 🔶 |
| `resize` | notification, server→client | new `{cols, rows}` | — | 🔶 |
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
