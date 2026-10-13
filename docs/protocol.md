<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# The glyphwire protocol

**Version 0.5.0 — pre-1.0 draft.**
Copyright (c) 2026 Jeff DeWall. Licensed
[CC-BY-4.0](../LICENSES/CC-BY-4.0.txt).

This is the normative specification of the wire protocol spoken between a
glyphwire **host** (a display server owning a window and a cell grid) and
its **clients** (any program that can open a Unix socket). It is
self-contained: an implementation of either end can be written from this
document without reading the Zig.

Related documents, which this one does not replace:

- [`decisions.md`](decisions.md) — *why* each shape was chosen.
- [`api.md`](api.md) — the message catalog annotated with per-message
  implementation status and behavioural detail.
- [`roadmap.md`](roadmap.md) — the running implementation log.

Where this document and the reference implementation disagree, the
reference implementation is the fact and this document has a bug. Report
it.

## 1. Conformance

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHOULD**,
**SHOULD NOT**, **MAY**, and **OPTIONAL** are to be interpreted as
described in RFC 2119.

Two conformance classes:

- A **host** accepts connections on a socket, owns the object model in
  section 4, and implements the client→server messages in section 6.
- A **client** connects to a host and speaks the same messages. A client
  **MAY** implement any subset; there is no handshake and no required
  message.

A host **MUST** ignore unknown members of a `params` object rather than
rejecting the message. This is the sole forward-compatibility mechanism in
0.x (section 10).

### 1.1 Status of this version

The protocol is pre-1.0 and **not yet stable**. Two areas are known to be
underspecified and are called out where they arise:

- **Error responses do not exist on the wire** (section 3.4). A failed
  request severs the connection.
- **There is no version negotiation** (section 10).

## 2. Transport

### 2.1 Socket and discovery

A host **MUST** listen on a Unix domain stream socket. Discovery follows
systemd's `NOTIFY_SOCKET` pattern: the host, or a shell it spawned, sets
environment variables before `exec`, and a program that finds them
connects.

| Variable | Set by | Meaning |
|---|---|---|
| `GLYPHWIRE_SOCK` | host | Absolute path of the listening socket. **Its presence is the whole discovery protocol.** |
| `GLYPHWIRE_CTX` | host / shell | Opaque session id. Reserved; no current message consumes it. |
| `GLYPHWIRE_PANE` | host / multiplexer | The pane handle this process was seated in. A client **SHOULD** pass it as `subscribe`'s `pane` (section 6.18). |
| `GLYPHWIRE_LAYER` | an embedded shell | The layer this process should draw on: the surface an omitted `layer` resolves to. A client **SHOULD** send it as `attach_layer` immediately after connecting. Unset means the context's root layer. |
| `GLYPHWIRE_REMOTE` | `gw-agent` | Set inside a remote session. |
| `GLYPHWIRE_CONFIG_DIR` | user | Overrides the config directory. Not part of the wire protocol. |

A program that does not find `GLYPHWIRE_SOCK` **MUST** fall back to plain
stdout rather than failing. A program **MUST NOT** partially assume the
grid is present: either it connected, or it is writing to a pipe.

No client library is required. Anything that can open a socket and
read/write bytes can speak this protocol.

### 2.2 Framing

Every message is framed LSP-style: a `Content-Length` header, a blank
line, then exactly that many bytes of body.

```
Content-Length: 62\r\n
\r\n
{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
```

Normative rules:

- The header block ends at the first `\r\n\r\n`. The body is the next
  `Content-Length` bytes exactly.
- `Content-Length` is a decimal byte count of the body, not of characters.
- The header name **MUST** be matched case-insensitively. Surrounding
  spaces and tabs in the value **MUST** be trimmed.
- Other headers **MAY** be present and **MUST** be ignored.
- A header block with no `Content-Length` is a framing error; the reader
  **MUST NOT** attempt to resynchronise, because it cannot know where the
  body ends.
- A reader **MUST** tolerate a frame split across reads and several frames
  arriving in one read.

This framing was chosen so JSON bodies never need newline-escaping and so
a session stays debuggable with `nc -U` and `jq`.

### 2.3 The binary side channel

One message carries bytes that are not JSON: `load_image` (section 6.5).
Its JSON frame declares a byte count, and exactly that many raw bytes
follow **immediately on the socket, outside any frame**.

```
Content-Length: 85\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"load_image","params":{"format":"png","bytes":8192}}
<8192 raw bytes, no header, no framing>
```

Rules:

- `load_image` **MUST** be sent as a request (it **MUST** carry an `id`).
  A notification-form `load_image` is a protocol error.
- The host **MUST** consume exactly `bytes` bytes before resuming frame
  parsing. Bytes past that count belong to the next frame.
- A client **MUST NOT** interleave any other message between the header
  frame and the payload on the same connection.
- `load_image` **MUST NOT** appear inside a `batch` (section 6.19).

This is the only place raw bytes cross the wire. Image pixels are never
base64'd into JSON.

## 3. The message layer

### 3.1 Envelope

Bodies are [JSON-RPC 2.0](https://www.jsonrpc.org/specification) objects.
Three forms are used:

**Request** (client→server, expects a response):

```json
{"jsonrpc": "2.0", "id": 1, "method": "create_layer", "params": {"scrollback_rows": 0}}
```

**Response** (server→client):

```json
{"jsonrpc": "2.0", "id": 1, "result": {"handle": 3}}
```

**Notification** (either direction, no response):

```json
{"jsonrpc": "2.0", "method": "write_text", "params": {"text": "hello"}}
```

Rules:

- `jsonrpc` **MUST** be the string `"2.0"`.
- `id` **MAY** be any JSON value; the host echoes it back unchanged. A
  message with no `id` is a notification.
- `params` is an object in every message that takes parameters. Positional
  (array) params are not used.
- JSON-RPC **batch arrays are not supported.** Section 6.17's `batch`
  method is a different, glyphwire-specific mechanism.
- A response **MUST** carry `result`. See 3.4 for why it never carries
  `error`.

**Whether a method is a request or a notification is fixed per method** and
is listed in section 6. This matters more than it looks:

- A **request-kind** method sent *without* an `id` fails with
  `NotARequest` — and, being a notification, fails silently.
- A **notification-kind** method sent *with* an `id` still executes, but
  the host sends **no response**. A client that waits for one hangs
  forever. There is no generic acknowledgement.

To flush pending notifications, issue a genuine request (section 3.2), not
a notification with an `id` bolted on.

### 3.2 Ordering and concurrency

- A host **MUST** process one connection's messages strictly in order.
- A host **MAY** serve many connections concurrently, and **MUST**
  serialise their effects on shared state, so no client observes a
  half-applied message from another.
- Nothing is ordered *across* connections. Two clients drawing to the same
  layer race, and that is theirs to coordinate.
- Because a request's response cannot be produced until every earlier
  notification on that connection has been applied, **a request acts as a
  flush.** A client that has sent a burst of drawing notifications and
  needs them applied — before exiting, or before reading state on another
  connection — **SHOULD** issue any request and await its response. The
  reference client uses `get_property{property:"revision"}` for this on
  close.

### 3.3 The `layer?` convention

Most content messages take an optional `layer` handle. Omitting it, or
sending `null`, means **the root layer of the connection's current
context**. Likewise `row?`/`col?` omitted means "at the layer's cursor".
Both conventions are noted per message as `layer?` and `row?`/`col?`.

### 3.4 Error model

This section describes what an implementation actually does today. It is
the least finished part of the protocol.

**There are no JSON-RPC error responses.** A host never emits an envelope
containing an `error` member. Instead:

| Situation | Host behaviour |
|---|---|
| A **request** whose handler fails | The host **MUST** close the connection. There is no reply. |
| A **notification** whose handler fails | The host **MUST** apply nothing, keep the connection open, and log. The client is not told. |
| A notification failing on a connection subscribed to `"error"` | As above, plus the failure is recorded in a per-connection ring the client drains with `get_errors` (section 6.18). |
| An unparseable frame body | Treated as a failed message of unknown kind. |

Severing on a failed request is a deliberate least-bad choice: a client
awaiting a response that will never come would otherwise hang forever.

**Client guidance.** Because a failed request is fatal to the connection, a
client **SHOULD** validate handles locally, and **SHOULD** prefer the
notification form for anything speculative. A client that wants visibility
into its own mistakes **SHOULD** `subscribe` to `"error"` and poll
`get_errors`.

**Error codes** are the names in the table below. They appear only as the
`code` string in a `get_errors` entry — never in an envelope.

| Code | Raised by |
|---|---|
| `UnknownMethod` | any unrecognised method name |
| `NotARequest` | `load_image` sent without an `id` |
| `UnknownProperty` | `get_property` / `set_property` |
| `ReadOnlyProperty` | `set_property` on a get-only property, or `size`/`visibility` on a root layer |
| `WrongScrollMode` | `content_extent` set on a layer whose `scroll_mode` is `host` |
| `InvalidScrollMode` | `scroll_mode`'s `mode` is not `"host"` or `"client"` |
| `InvalidSpans` | `write_text` has both `text` and `spans`, or neither |
| `InvalidTextScale` | `write_text`'s `scale` is not one of the enumerated values |
| `InvalidColor`, `UnknownColorRole` | a colour's `slot` is outside 0–23, or its `role` is not a role name; `set_theme` slot given as a reference |
| `UnknownTheme` | `set_theme`'s `name` is not a built-in theme |
| `UnknownLayer` | any `layer` handle that does not exist, **and** the root handle where a non-root one is required |
| `LayerPermissionDenied` | `destroy_layer` from a non-owner |
| `UnknownContext`, `RootContextImmutable`, `ContextPermissionDenied`, `NoContextSession` | context messages |
| `UnknownPane`, `RootPaneImmutable`, `UnknownPaneSplit`, `InvalidPaneSplitChild` | pane messages |
| `NotWindowManager`, `UnknownRole` | role messages |
| `UnknownSplit`, `InvalidSplitAxis`, `InvalidSplitChild` | layer-split messages |
| `UnknownImage`, `UnknownIcon`, `ImageIsIcon`, `InvalidIconOption`, `UnsupportedImageFormat` | image / icon messages |
| `UnknownMetadata`, `InvalidMetadataDirection` | metadata messages |
| `UnknownTable`, `InvalidTableOption`, `TableRowShapeMismatch` | table messages |
| `UnknownRect` | rect messages |
| `UnknownNinePatch`, `UnknownNinePatchStyle` | nine-patch messages |
| `UnknownOutline`, `OutlineNodeOutOfRange` | outline messages |
| `InvalidMoveDirection` | `move_content` |
| `SpawnUnsupported`, `SpawnFailed` | `spawn_in_pane` |
| `RemoteUnsupported`, `RemoteStartFailed` | `start_remote` |

## 4. Object model

Every message operates on this set of objects.

```
Session
├── Contexts ......... independent full-window surfaces, one visible at a time
│   └── Context
│       ├── root layer (handle 0) — always present, never destroyable
│       ├── Layers ... created surfaces: popups, panes, sidebars
│       │   ├── Cells (grid), scrollback ring, cursor, viewport
│       │   ├── Tables ..... server-side table widgets
│       │   ├── Rects, nine-patches ... pixel-space overlays and panels
│       │   ├── Splits ..... layout tree over layers
│       │   └── Selection, highlight set
│       └── Image and icon catalogs, metadata store
├── Panes ............ the window manager's tiling of the window
│   └── Pane → a stack of Contexts (top = shown)
└── visibility stack . which Context is on screen
```

### 4.1 Handles

All handles are unsigned 32-bit integers unless noted.

| Type | Root / sentinel |
|---|---|
| `LayerHandle` | `0` = the context's root layer |
| `ContextHandle` | `0` = the root context |
| `PaneHandle` | `0` = the root pane |
| `SplitHandle`, `PaneSplitHandle` | no root |
| `ImageHandle`, `MetadataHandle`, `TableHandle`, `RectHandle`, `NinePatchHandle`, `OutlineHandle` | no root |
| remote session id | 64-bit |

Handle `0` is the root for layers, contexts and panes and is **never**
valid where a created object is required: `destroy_layer(0)`,
`raise_layer(0)` and friends report `UnknownLayer`, not a permission
error. Handles are per-context for layers, tables, rects, outlines,
splits and metadata; per-session for contexts and panes.

Tables, rects and outlines are allocated from a per-context counter but
**stored on a layer**, which is why every message naming one carries both
the optional `layer` and the object's own handle.

### 4.2 Context

A context is an independent full-window surface with its own root layer,
layers, splits and tables. The session holds a registry of contexts plus a
**visibility stack**; only the top is rendered.

This generalises the classic terminal alternate screen from one alternate
buffer to N persistent surfaces. Switching away never destroys a context,
so a shell's prompt and scrollback survive underneath a full-screen editor
and reappear when it exits.

**Root context** (handle `0`) is the one the host starts with. It is never
culled, cannot be destroyed, and sits permanently at the bottom of the
stack.

**Per-connection current context.** A connection inherits whichever context
is visible at accept time. Every `layer?`-scoped message resolves against
the connection's current context. `create_context` and `attach_context`
change it; it is ambient connection state, not a parameter on every
message.

**Per-connection surface.** Within that context, an omitted `layer`
resolves to the connection's surface: the root layer, unless the
connection sent `attach_layer`. This is how a program launched inside
another client's panel draws there without knowing it is in one — the
same ambient-state shape as the current context, and the layer-level
counterpart of `attach_pane`. Changing context clears it; a surface whose
layer is destroyed falls back to root.

**Ownership and culling.** The connection that creates a context is its
first owner; `adopt_context` adds more. A context is destroyed once every
owning connection has disconnected, so a full-screen program that dies
without `destroy_context` does not leave its surface stuck on screen. The
same rule governs layers (`create_layer` / `adopt_layer`).

**Switching between programs (job control).** Because a context that is
not on top keeps running and keeps its screen, putting a full-screen
program "in the background" is nothing more than changing which context
is on top of its pane: no signal, no suspend. The host owns a switcher
for this (Super+F12 by default, `context_switcher_key` in
`host.conf.lua`) that lists the focused pane's stack and
activates the pick. A context carries an optional `title` for that list
(`create_context`'s `title`, or `set_context_title`); a client
**SHOULD** name its context after itself.

The one party that has to notice is the shell that launched the program,
because it is waiting on it. A shell learns its own context and what is
on top of its pane from `list_contexts`, and treats its own context
reaching the top again while its child still runs, *and the child's
context is still in the stack behind it*, as "the child was put in the
background": it stops waiting and returns to its prompt. A program that
exits destroys its context before its process is reaped, which also
brings the shell's context back on top; the child's context being gone
is what tells that apart from a switch. It uses
the pane stack rather than the `context` notification's handle because
under a multiplexer that notification names the *focused* context, which
changes whenever focus moves to another pane.

### 4.3 Layer

A layer is a grid of cells with a cursor, a viewport, an optional
scrollback ring, and a place in the compositing order. The root layer
(handle `0`) is always the bottom of the stack and is never in the
explicit order; `raise_layer` and `lower_layer` reorder the rest.

A created layer has a pixel-precise position relative to its parent, or a
sticky cell position (section 6.3's `cell_position`).

### 4.4 Cell

A cell holds:

- `g` — the grapheme, a UTF-8 string (possibly empty).
- `fg` — foreground colour.
- exactly one background: a colour, an image reference, or an icon
  reference.
- `fg_icon` — an optional icon composited *over* the background,
  independent of which background case is set.
- `metadata_id` — an optional metadata handle (section 4.8).
- `wide` — East Asian Width role.

**Wide characters.** A 2-cell East Asian wide character occupies a `lead`
cell holding the grapheme and a `spacer` cell whose `g` is empty. The
spacer carries the lead's background and `metadata_id`, so a background
spans the pair and a hit test on either half resolves the same. An
ordinary 1-cell character has no `wide` member. The host computes width
from Unicode East Asian Width, treating `W` and `F` as wide and `A` as
narrow.

**Colours** take one of three forms:

- `{"r":0-255,"g":0-255,"b":0-255,"a":0-255}` — a fixed colour. `a`
  defaults to 255, so `{"r":255,"g":0,"b":0}` is valid.
- `{"slot":0-23}` — a palette slot of the context's theme (section 4.10).
- `{"role":"<name>"}` — a theme role (section 4.10), e.g.
  `{"role":"keyword"}`.

A slot or role is a **reference**: the cell stores it, and the host
resolves it against the theme of the context the cell belongs to every
time it draws, so a theme change recolours what is already on screen. `a`
applies to a reference too, multiplied into the theme colour's own alpha.
An out-of-range slot is `InvalidColor`; an unknown role is
`UnknownColorRole`. The default style's foreground is `{"role":"fg"}` and
its background is transparent (alpha 0).

**Positions.** Pixel positions are `{"x":<f32>,"y":<f32>}`; cell positions
are `{"row":<int>,"col":<int>}`, both 0-based, origin top-left.

### 4.5 Table

A server-side table widget: columns with widths, alignment and sort
behaviour; rows of cells with display text, an optional sort key, an
optional icon and an optional metadata id. The host owns layout, sorting,
borders and striping — a client sets rows and reads back where the table
painted. Sorting a 10,000-row listing costs one message, not a redraw.

### 4.6 Rect

A plain coloured box, filled or outlined, and the one layer component
that is **not part of the cell grid**: its `x`/`y`/`w`/`h` are pixels in
the layer's own content coordinate frame. So a rect pans with the layer's
`scroll_offset` for free, the way image cells and text do, and a client
drawing a highlight over a picture does not have to round it to cells.

Rects composite last within their layer, after text — unlike the
selection and highlight tints, which draw under it so text stays
readable over them.

A **nine-patch** is the other non-grid component: a panel background
drawn from one `.9.png` image, placed on a cell rect. Its four corners
keep their native pixel size, its edges stretch along their long axis and
its centre stretches both ways, so rounded or alpha-feathered corners
stay crisp at any cell shape or font size. It composites directly above
the layer's `background` and **under every cell background**, so a
selected or highlighted row inside a dialog still shows. Like a rect it
lives in the layer's content frame and pans with `scroll_offset`; it does
**not** move with the root layer's scrollback ring, so it belongs on a
created layer rather than in the shell's scrolling output.

### 4.7 Outline

A collapsible tree of text rows: a flat node list where each node carries
a `depth`, and a collapsed node hides the contiguous run of deeper nodes
after it. Like a table it compiles into ordinary cells and outlives the
client that drew it, so a host can expand a node with nothing running.

Unlike every other component, an outline's height changes when a node
toggles, so it **reflows the layer around itself**: rows at and above it
shift up into scrollback, rows below it do not move. See section 6.11.

### 4.8 Metadata

An opaque JSON blob registered with `create_metadata`, tagged onto cells,
and resolved back from a cell position with `get_metadata`. This is how a
client attaches meaning to a region of the grid — a filename behind a
listing entry, a diagnostic behind a span — without the host understanding
any of it. The host stores and returns the string verbatim.

### 4.9 Pane

Panes are the window manager's tiling of the window, one level above
contexts: each pane holds a *stack* of contexts, and the top of that stack
is what the pane shows. Pane messages are restricted to the connection
holding the `window_manager` role (section 6.15).

A program inside a pane cannot tell it is in one. Its `resize` carries its
pane's size, not the window's, and no message it can send reveals pane
geometry. Only `pane_layout`, which only a window manager subscribes to,
exposes where panes sit.

### 4.10 Theme

A **theme** is two tables the host resolves colour references against.

**Slots** are 24 colours: the eight ANSI hues — `black red green yellow
blue magenta cyan white`, in ANSI order — at three levels. Slots 0–7 are
the dim level, 8–15 normal, 16–23 bright, so slot `level * 8 + hue`.
Their names are the hue for the normal level and `dim_` / `bright_`
prefixed for the other two (`red`, `dim_red`, `bright_red`). ANSI escape
output draws from them: SGR `30`–`37` / `40`–`47` are slots 8–15, `90`–`97`
/ `100`–`107` are 16–23, bold promotes a basic foreground to its bright
slot, SGR `2` (dim) moves a slot to its dim one, and `38;5;N` / `48;5;N`
for `N` 0–15 are the same slots as the basic and bright codes. Only
256-colour indices 16–255 and truecolor stay fixed.

**Roles** say what a colour is *for*. Each names a slot, a fixed colour,
or another role. The set is fixed and shared by every program (the names
below are the wire form; the numeric order in `core.theme.Role` is
append-only):

| Group | Roles |
|---|---|
| Base | `fg` (the default text), `fg_dim`, `fg_strong`, `bg`, `bg_dark`, `bg_raised`, `border`, `accent`, `link`, `selection_bg`, `cursor_bg`, `cursor_fg` |
| Status | `success`, `message`, `message_error`, `diag_error`, `diag_warning`, `diag_info`, `diag_hint` |
| Search | `match`, `match_bg`, `match_current_bg` |
| Files | `file`, `dir`, `symlink`, `exec`, `special`, `hidden`, `hidden_dir`, `marked` |
| Chrome | `sidebar_bg`, `status_bg`, `status_fg`, `mode`, `tab_bar_bg`, `tab_bg`, `shell_bg`, `whitespace`, `title_bg`, `title_fg`, `title_inactive_bg`, `title_inactive_fg`, `list_cursor_bg`, `list_cursor_inactive_bg`, `list_cursor_fg`, `list_cursor_inactive_fg`, `keybar_bg`, `keybar_key`, `keybar_label_bg`, `keybar_label`, `suggestion`, `divider`, `pane_divider` |
| Popups and dialogs | `popup_bg`, `popup_fg`, `popup_code_bg`, `popup_rule`, `popup_border`, `popup_selected_bg`, `popup_label`, `popup_kind`, `popup_detail`, `finder_header_bg`, `finder_header_fg`, `finder_selected_bg`, `finder_selected_fg`, `dialog_bg`, `dialog_fg`, `dialog_title_bg`, `dialog_title_fg`, `danger_bg`, `input_bg`, `button_bg`, `button_focus_bg` |
| Documents | `heading1`–`heading6`, `strong`, `emphasis`, `strike`, `code`, `code_bg`, `code_block`, `code_block_bg`, `quote`, `list_marker`, `rule` |
| Tables | `table_header`, `table_header_bg`, `table_alt_row_bg`, `outline_marker` |
| Syntax | the tree-sitter capture groups: `comment`, `keyword`, `string`, `string_escape`, `string_special`, `escape`, `number`, `boolean`, `character`, `constant`, `constant_builtin`, `function`, `function_builtin`, `type`, `type_builtin`, `constructor`, `operator`, `property`, `variable`, `variable_builtin`, `variable_parameter`, `module`, `label`, `attribute`, `tag`, `punctuation`, `punctuation_special`, `text_title`, `text_literal`, `text_uri`, `text_reference` |

A role without a `_bg` suffix is a foreground. A table with no
`header_fg` draws its header in `table_header`. `list_cursor_fg` is
opt-in: a list whose rows carry meaning in their own colours may keep
them on the cursor row, but a light theme's cursor fill is saturated
enough that only this reads on it. `divider` and `pane_divider` are the
host's own: the band between split layers (the context's theme) and
between panes (the window theme's).

**Whose theme.** The host has a **window theme**, read at startup from
`theme.lua` in the config directory (`config = { theme = "nord" }`, or a
theme table; see `applib/themeconf.zig`). Every context starts with a
copy of it. A context may set its **own** theme with `set_theme`
(section 6.1), and from then on a window-theme change passes it by; a
cell is always resolved against the theme of the context it is in. A
program that draws into another program's context (an inline listing in
a shell's scrollback) therefore takes that context's theme. The frame
clear under every pane is the window theme's `bg`, and the host caret
is the context theme's `cursor_bg`.

The host also owns a **theme switcher** (Super+F10 by default,
`theme_switcher_key` in `host.conf.lua`) listing every built-in and every
`theme.lua` theme. It changes the window theme for the session —
previewed as the selection moves, put back on Escape, never written to
`theme.lua` — and sends a `theme` notification (section 7.2) to every
connection whose context follows it. It and the context switcher are
drawn by the host in the window theme's `panel_style` frame.

## 5. Reading the catalog

Each entry gives the method, its kind, its params and its result.

- **Kind** is `request` (has `id`, gets a response) or `notification` (no
  `id`, no response).
- `?` marks an optional param. A default is shown where one exists.
- `layer?` follows section 3.3.
- Results are the `result` member of the response envelope.

## 6. Client → server messages

### 6.1 Context

| Method | Kind | Params | Result |
|---|---|---|---|
| `create_context` | request | `width?`, `height?`, `scrollback_rows?` = 0, `window_scrollbar?` = true, `title?` | `{context}` |
| `destroy_context` | notification | `context` | — |
| `activate_context` | notification | `context` | — |
| `attach_context` | notification | `context` | — |
| `attach_layer` | notification | `layer?` | — |
| `adopt_context` | notification | `context` | — |
| `set_context_title` | notification | `title` | — |
| `set_theme` | notification | `name?`, `theme?` | — |
| `get_theme` | request | — | `{name, dark, panel_style, own, slots, roles}` |
| `list_contexts` | request | — | `{current, contexts: [{context, title, visible}]}` |
| `set_window_scrollbar` | notification | `visible` | — |
| `set_caret_layer` | notification | `layer?` | — |
| `set_caret_visible` | notification | `visible` | — |
| `set_caret_shape` | notification | `shape?` | — |

`create_context` allocates a context, **shows it immediately**, and
retargets the issuing connection onto it. `width`/`height` default to the
visible context's root layer size. `window_scrollbar` is whether the host
draws its right-edge scrollbar for this context; a TUI whose panes carry
their own scrollbars passes `false`. The gutter stays reserved either
way — the flag only decides whether the bar is painted, so creating or
destroying such a context never resizes the grid.

`destroy_context` frees the context and everything in it. If it was
visible, visibility pops to whatever was underneath — the alternate-screen
auto-restore. Ownership-checked. The root context reports
`RootContextImmutable`.

`activate_context` makes a context visible **without** changing what the
issuing connection draws on. A client backgrounds itself by activating
context `0` and restores itself by activating its own handle.

`set_context_title` names the issuing connection's current context
(`create_context`'s `title` does the same at creation). Display only: the
host's context switcher lists it and a shell's `jobs` prints it. No
ownership needed, so a shell can name the context it inherited. Capped at
128 bytes, cut on a UTF-8 boundary.

`set_theme` gives the issuing connection's current context its own theme
(section 4.10). `name` picks a built-in. `theme` is a whole theme —
`{name?, dark?, panel_style?, slots?, roles?}` — laid over `default`:
`slots` is an array of up to 24 fixed colours (a reference is
`InvalidColor`), `roles` an object of role name to a colour in any of the
three forms of section 4.4, read as the role's value. With neither, the
context goes back to following the window theme. No ownership needed: a
program colours what it draws. An unknown `name` is `UnknownTheme`. A
client that wants a theme defined in `theme.lua` or its own config
resolves it itself and sends the result as `theme`.

`get_theme` returns the current context's theme as the host resolves it:
every slot as a fixed colour and every role as a `{slot}`, `{role}` or
fixed colour, plus `own` (whether the context set it) and `panel_style`
(the nine-patch style a popup should be framed with, since a nine-patch
can't be recoloured). A program needs it only for what it can't express
as a reference: the frame name, or a colour it blends itself.

`list_contexts` returns the issuing connection's **own pane's** stack, top
(on screen) first, each with its `title` (empty if never set) and
`visible` (true for the first only), plus `current`: the connection's own
current context. It never reveals other panes.

`attach_context` retargets the issuing connection onto an existing
context; ownership is untouched. This is how a paired input listener joins
the context its drawing connection created.

`attach_layer` declares the connection's surface within that context —
the layer an omitted `layer` field resolves to. `null`, or the root
handle, restores the root layer; an unknown handle reports
`UnknownLayer`. A client **SHOULD** send it at connect time when
`GLYPHWIRE_LAYER` is set (section 4).

`set_caret_layer` points the host's blinking caret at a created layer
instead of the root layer's cursor; `null` restores the root. The host
positions the caret through that layer's bounds, viewport and scroll
offset, and hides it when the layer is scrolled out of view. Destroying
the tracked layer clears the setting.

`set_caret_visible` shows or hides the host's caret for the issuing
connection's context, whichever layer it tracks. A program with no text
insertion point (a reader or a viewer) sends `false` once. It is separate
from a layer's DECTCEM cursor-hide, which a PTY program drives.

`set_caret_shape` picks the shape the host draws its caret in for the
issuing connection's context: `line` (a thin bar at the cell's left
edge), `block`, `box` or `underline`. `null` or an absent `shape` goes
back to the shape the host is configured with. A modal editor sends
`line` in insert mode. `block` covers the cell without redrawing the
character in it, so a client that wants an inverted block draws that
itself and hides the host caret.

**Input follows visibility.** Raw input notifications (`key_down`,
`key_up`, `text`, `mouse_button`, `mouse_move`) are delivered **only to
connections whose current context is the visible one**. Every other
server→client notification fans out to all subscribers regardless, so a
backgrounded client can keep its content current.

### 6.2 Layer lifecycle

| Method | Kind | Params | Result |
|---|---|---|---|
| `create_layer` | request | `width?`, `height?`, `scrollback_rows` | `{handle}` |
| `destroy_layer` | notification | `layer` | — |
| `adopt_layer` | notification | `layer` | — |
| `raise_layer` | notification | `layer`, `above?` | — |
| `lower_layer` | notification | `layer`, `below?` | — |

`create_layer` parents to the root layer; `width`/`height` default to the
root layer's size. The issuing connection becomes the first owner.

`raise_layer` moves a layer directly above `above`, or to the very top when
omitted; `lower_layer` mirrors it. Creation order is only the *initial*
stacking, so this is what puts a completion popup created early back over a
sidebar created later. Naming the root handle as either argument reports
`UnknownLayer`. Raising a layer above itself is a no-op, not an error, and
a rejected restack leaves the order untouched.

### 6.3 Properties

| Method | Kind | Params | Result |
|---|---|---|---|
| `get_property` | request | `layer?`, `property` | property-specific |
| `set_property` | notification | `layer?`, `property`, plus that property's fields | — |

One generic mechanism rather than a get/set pair per property. `set_property`
takes the value as **flat sibling fields**, not a nested `value` object —
`{"property":"cursor","row":3,"col":0}`.

| Property | Shape | Access |
|---|---|---|
| `cursor` | `{row, col}` | get / set |
| `revision` | `{revision}` — bumped once per `write_text` | get |
| `position` | `{x, y}` pixels, relative to parent | get / set |
| `cell_position` | `{row, col}` — sticky cell placement | get / set |
| `size` | `{cols, rows}` | get; set on non-root layers only |
| `viewport` | `{row, col, cols, rows}` | get / set |
| `scroll` | `{offset, max}` — scrollback view | get |
| `scroll_offset` | `{row, col, max_row, max_col}` — viewport over content | get / set |
| `scrollbars` | `{vertical, horizontal, row, col, max_row, max_col}` | get / set |
| `scroll_mode` | `{mode}` — `"host"` (default) or `"client"` | get / set |
| `content_extent` | `{cols, rows}` — virtual content size, `client` mode only | get / set |
| `background` | `{color?}` — fill under unwritten cells; omitted = none | get / set |
| `visibility` | `{visible}` | get; set on non-root layers only |
| `pty_mode` | `{enabled}` | get / set |
| `mouse_select` | `{enabled}` — let the host drag-select on this layer | get / set |
| `shadow` | `{shadow: {x?, y?, blur?, radius?, spread?, color?}}` — a soft drop shadow the host draws under the layer: a rounded rect of the layer's bounds moved by `x`/`y`, grown by `spread`, corner `radius`, blurred by `blur` (pixels; `blur`/`radius` clamp to 64), in `color` (default black, alpha 128). No `shadow` removes it. Not part of the layer's bounds | get / set |
| `profile` | profiler state | get |

`size` on the **root** layer is what answers "how big is my window": a
context's base size *is* its root layer's size. It is get-only there — the
host owns the window — and a client learns about changes through `resize`.
It is settable on a created layer, so a TUI can reflow a sidebar and a
buffer pane on resize without destroying handles, tables and content.
Setting it also stops the layer tracking the context's base size: a client
that picks its own size has taken over the layout. Zero is clamped to 1.

`cell_position` places a layer on the cell grid, resolved server-side.
Unlike reading `get_cell_metrics` and multiplying once, it is **sticky**:
the host re-derives the pixel position when the cell size changes, such as
a font-size step, so a sidebar keeps its column instead of drifting.
Setting `position` in pixels un-sticks it. The getter always answers: the
cell that was set, else the cell the layer's top-left corner lands in.

Writing a get-only property, or `size`/`visibility` on a root layer,
reports `ReadOnlyProperty`.

**Scroll models.** A layer has two ways to show more content than fits,
chosen explicitly with `scroll_mode`, and both are separate from the root
layer's terminal scrollback (`scroll`, `scroll_view`, `view_offset`):

- `host` (default): the content grid holds everything and `viewport` is a
  window onto it. The host moves `scroll_offset` on a wheel or scrollbar
  drag and redraws on its own.
- `client`: the grid is only the visible rows. The client declares the
  whole size with `content_extent`, and a wheel or drag produces a
  `scroll_offset` notification the client redraws against.

`content_extent` on a `host` layer reports `WrongScrollMode`; switching
modes resets the offset and drops the extent.

**`background`** paints the layer's whole viewport under its cells. A
cell's own background is transparent only when its alpha is 0 (the
default style); any explicit colour, black included, is opaque.

### 6.4 Content

| Method | Kind | Params | Result |
|---|---|---|---|
| `write_text` | notification | `layer?`, `row?`, `col?`, `text` \| `spans`, `fg?`, `bg?`, `metadata_id?`, `transparent_bg?` = false, `scale?`, `max_cols?`, `pad?` = false, `selectable?` = true | — |
| `insert_cells` | notification | `layer?`, `count` | — |
| `delete_cells` | notification | `layer?`, `count` | — |
| `move_content` | notification | `layer?`, `top?`, `bot?`, `count?` = 1, `direction?` | — |
| `clear` | notification | `layer?`, `row?` = 0, `col?` = 0, `rows?`, `cols?`, `bg?` | — |
| `set_bg` | notification | `layer?`, `row?` = 0, `col?` = 0, `rows?`, `cols?`, `bg` | — |
| `set_fg` | notification | `layer?`, `row?` = 0, `col?` = 0, `rows?`, `cols?`, `fg` | — |
| `get_cells` | request | `layer?`, `view_offset?` = 0 | `{cols, rows, revision, cells}` |
| `scroll_view` | request | `layer?`, `offset?`, `delta?` | `{offset, max}` |

`write_text` writes at `row`/`col` and advances the cursor; each omitted
axis keeps the cursor's current value. `max_cols` clips the run to that
many display columns from its start (never splitting a wide character,
never wrapping), and `pad` fills the rest of that span with blank `bg`
cells. `fg`/`bg` omitted means the server default style. `selectable:
false` keeps every cell the write touches out of any selection's tint and
copied text (a panel's border and pad).

`spans` replaces `text` with an array of `{text, fg?, bg?, metadata_id?,
transparent_bg?, scale?}` written back to back; each omitted field takes
the message's value, and `max_cols`/`pad` apply to the write as a whole.
Sending both `text` and `spans`, or neither, reports `InvalidSpans`.

A `scale` of `"x1_5"` or `"x2"` advances two cells per display column,
and `"x3"` three, filling the cells after each enlarged glyph, and the
same span on the one or two rows below that the glyph draws down over,
with blanks in the run's background and `metadata_id`. The rows below
are clipped at the layer's bottom rather than scrolling it, and the
cursor stays on the glyph's row. `transparent_bg` leaves whatever
background is already in the cell — an image, an icon, a panel gradient —
instead of resetting it. `metadata_id` tags every cell written.

`underline` draws a line at the bottom of every cell the text touches —
`"single"`, `"double"`, `"curly"`, `"dotted"` or `"dashed"` — and
`underline_color` colours it independently of the text, defaulting to the
text's own foreground. Both are per-span as well as per-message. This is
the one style attribute beyond colour that the wire carries, and it is
here because a mark that is not a colour is the only kind that can coexist
with syntax highlighting and a selection tint on the same cell: a language
server's diagnostics need exactly that. It is drawn from a rect at the
cell's baseline, which is why it is affordable where bold and italic —
which would need further font faces in the atlas — are not. The pad of a
`pad`ded write is never underlined.

`write_text` also mirrors a useful subset of ANSI/VT escape sequences found
in the text, so output from a program that does not know about glyphwire
still shows colour. This is **colour, plus underline**: SGR 30-37 / 90-97 /
38;2;r;g;b and their background forms, plus `bold` (maps a basic foreground
to its bright variant), `dim`, `inverse`, and the underline set — `4`,
`4:0`–`4:5`, `21`, `24`, with `58`/`59` for its colour. There are no other
attribute bitflags on the wire. Note that `;` and `:` are not
interchangeable here: `4:3` is a curly underline, `4;3` is an underline
followed by an italic (still ignored). A sequence that is a *query*
(`CSI 6n`, device attributes, DECRQM) produces a `terminal_reply`
notification (section 7) rather than a grid change.

`clear` with `bg` leaves the region blank but opaque in that colour.

`set_underline` takes the same region again and repaints only the
underline, for a mark that goes *over* text already on the grid. An editor
paints a row as coloured runs and then overpaints the search highlight and
the selection on it, and each of those is a full cell write that clears the
underline — so a diagnostic squiggle has to be applied after them, by
something that does not need to know what colours are underneath. `"none"`
takes a mark off.

`set_bg` takes the same region, with the same defaulting, and repaints
only each cell's background: the grapheme, foreground colour,
`metadata_id`, `selectable` flag, text scale and foreground icon are all
left as they were. `bg` is required. A cell's background is a single slot,
so one holding an image or an icon background takes the colour like any
other; a *foreground* icon (`draw_icon` with `foreground: true`) is a
separate field and survives. This exists so that a client drawing a list
with a highlighted row can move that highlight with two messages rather
than redrawing two rows of text — the difference between a few hundred
bytes and a few kilobytes per keystroke, which matters over a remote
session.

`set_fg` is the same for the text colour: the region's foreground
changes and nothing else does. `fg` is required. It is the other half of
moving a highlight whose text changes colour with it (a cursor row drawn
in `list_cursor_fg`): one `set_fg` over the row the cursor landed on, and
one per run of its own colours over the row it left.

`move_content` scrolls a row range: `direction` is `"up"` or `"down"`;
anything else reports `InvalidMoveDirection`.

`get_cells` returns the layer's visible viewport as a row-major array of
`cols * rows` cells, plus the layer `revision` it was snapshotted at.
`view_offset` reads that many rows of scrollback above the live viewport,
so a client can snapshot exactly what a scrolled-back host is showing.
Cells report image, icon and metadata references as **handles, never
resolved content** — resolve them with `get_image_info` and `get_metadata`.

> `get_cells` is a debugging and introspection facility. A client using it
> to scan the grid in normal operation is doing something the host should
> be doing for it.

`scroll_view` moves the layer's scrollback view offset — `offset` absolute,
then `+delta` — clamped to `0..max` where `max` is the retained history
length, and returns the result. Passing neither is a pure query. It also
broadcasts `scroll` to other subscribers.

### 6.5 Images

| Method | Kind | Params | Result |
|---|---|---|---|
| `load_image` | request | `format`, `bytes` **+ raw payload** | `{handle}` |
| `update_image` | request | `handle`, `format`, `bytes` **+ raw payload** | `{handle}` |
| `get_image_info` | request | `handle` | `{width, height}` |
| `draw_image` | notification | `layer?`, `handle`, `row?`, `col?`, `row_span`, `col_span`, `scale?` = 1.0 | — |
| `destroy_image` | notification | `handle` | — |

`format` is `"png"`, `"jpeg"` (`"jpg"` accepted), `"bmp"` or `"gif"`;
anything else reports `UnsupportedImageFormat`. `bytes` is the payload
length, delivered per section 2.3.

`draw_image` sets each cell in the `row_span` × `col_span` rectangle to
sample its own region of the image, so the picture spans the rectangle
rather than repeating per cell.

`update_image` replaces an existing handle's pixels in place, so cells
already drawing that handle pick up the new content without being
rewritten. Like `load_image` it carries a side-channel payload, and so
**MUST NOT** appear inside a `batch`.

`destroy_image` frees an image's bytes and drops its handle. Cells still
backed by it are deliberately left alone and render nothing from then on
— the same "report the dangling reference rather than chase it"
treatment `get_metadata` gives a destroyed `metadata_id`. A client
**SHOULD NOT** need it: an image loaded over a connection is reclaimed
once that connection is gone and the image has scrolled out of
scrollback. It reports `UnknownImage` for an unknown handle and
`ImageIsIcon` for one registered in the icon catalog, which is
session-wide infrastructure no client owns.

### 6.6 Icons

| Method | Kind | Params | Result |
|---|---|---|---|
| `draw_icon` | notification | `layer?`, `row?`, `col?`, `name`, `scale?`, `h_align?`, `v_align?`, `max_w?`, `max_h?`, `metadata_id?`, `foreground?` = false | — |

Icons are named entries in a host-side catalog, registered by the host at
startup rather than loaded over the wire. The reference host scans its
asset directory and registers every PNG by its path minus the extension —
`file/folder.png` becomes `file/folder`.

| Option | Values | Default |
|---|---|---|
| `scale` | `"fit"`, `"natural"`, `"stretch"` | `"fit"` |
| `h_align` | `"start"`, `"center"`, `"end"` | `"start"` |
| `v_align` | `"start"`, `"center"`, `"end"` | `"start"` |

`max_w`/`max_h` bound the rendered size and are meaningful only with
`scale: "natural"`. An unrecognised option string reports
`InvalidIconOption`; an unknown name reports `UnknownIcon`.

`foreground: true` composites the icon *over* the cell's background rather
than becoming it, so an icon can sit on a coloured panel.

### 6.7 Nine-patches

| Method | Kind | Params | Result |
|---|---|---|---|
| `create_nine_patch` | request | `layer?`, `row`, `col`, `rows`, `cols`, `style` | `{handle}` |
| `update_nine_patch` | notification | `layer?`, `nine_patch`, `row?`, `col?`, `rows?`, `cols?`, `style?` | — |
| `destroy_nine_patch` | notification | `layer?`, `nine_patch` | — |

A panel background over the `rows` x `cols` cell rect at `row`/`col`
(section 4.6). `style` names a registered nine-patch: the host loads
every `<name>.9.png` in its bundled `ninepatch/` asset directory and then
the user's `~/.config/glyphwire/ninepatch/` (a user file overrides a
bundled one of the same name). The bundled styles are `dialog` (a
top-to-bottom blue gradient with a rounded white border), `panel` (a dark
popup background with a muted rounded border) and `box` (a thin rounded
outline over a transparent middle).

A `.9.png` is the image surrounded by a 1px guide border, as on Android.
Opaque black pixels on the top row mark the columns that stretch, and on
the left column the rows that stretch; each must be one contiguous run.
Everything outside the runs is corner or edge and keeps its pixel size.
The right and bottom guides (Android's content padding) are ignored,
since placement is by cell rect. When the panel is smaller than its two
corners together on an axis, the corners shrink in proportion and the
middle disappears.

The host converts the cell rect to pixels at render time, so a font
resize keeps the panel on its cells with the corners still at native
size. `update_nine_patch` merges only the fields sent, like
`update_rect`. An unknown `style` reports `UnknownNinePatchStyle`, an
unknown `nine_patch` reports `UnknownNinePatch`, an unresolvable `layer`
reports `UnknownLayer`. All three are batchable, and destroying the
layer destroys its nine-patches.

### 6.8 Metadata

| Method | Kind | Params | Result |
|---|---|---|---|
| `create_metadata` | request | `json` | `{handle}` |
| `destroy_metadata` | notification | `id` | — |
| `tag_metadata` | notification | `layer?`, `row`, `col`, `metadata_id` | — |
| `get_metadata` | request | `layer?`, `row`, `col`, `view_offset?` = 0 | `{id, json}` |
| `find_metadata` | request | `layer?`, `above?` = 0, `col?` = 0, `direction?` | `{found, above, col, id}` |

`json` is stored and returned verbatim; the host never parses it.

`get_metadata` resolves a viewport cell to its tag. `view_offset` resolves
against that many rows of scrollback — pass the `view_offset` a
`mouse_button` notification carried, and you land on the row the user
actually clicked. `id` is null when the cell has no tag; `json` is null
when the id was destroyed but is still referenced.

`find_metadata` walks for the next or previous tagged cell. `direction` is
`"next"` or `"prev"`; anything else reports `InvalidMetadataDirection`.
`above` is rows above the live viewport (positive = scrollback).

### 6.9 Tables

| Method | Kind | Params | Result |
|---|---|---|---|
| `create_table` | request | `layer?`, `row?`, `col?`, `columns`, `style?` | `{handle}` |
| `destroy_table` | notification | `layer?`, `table` | — |
| `table_set_rows` | notification | `layer?`, `table`, `rows` | — |
| `table_set_sort` | notification | `layer?`, `table`, `column?`, `direction?` | — |
| `table_set_style` | notification | `layer?`, `table`, `style` | — |
| `table_get_state` | request | `layer?`, `table` | see below |

**Column** — `{name, kind?, sortable?, case_insensitive?, width, min_width?, h_align?, overflow?}`.
`kind` is `"text"` (default) or `"number"`; `h_align` is `"start"`
(default), `"center"` or `"end"`. `case_insensitive` folds ASCII case when
sorting a text column.

`overflow` decides what a body cell wider than its column does:
`"ellipsis"` (default) keeps one line ending in `…`; `"wrap"` word-wraps
it. Wrapping breaks at spaces, hard-breaks a word longer than the line at
a character boundary (a wide character never splits), and treats `\n` as
a break. A row is as tall as its tallest wrapped cell (at least
`row_height`); other cells stay on the row's first text line. Wrapping
uses the column's nominal `width`, not the extra width a sort arrow adds,
so re-sorting never changes the table's height. Headers always
ellipsize.

**Style** — every field optional:
`{borders?=true, header_separator?=true, box_style?="box", alt_row_bg?, header_fg?, header_bg?, row_height?=1, max_icon_px?}`.
`max_icon_px` bounds a body icon's rendered height in pixels; omitted, the
row height alone bounds it.

**Row cell** — `{display, sort_key?, icon?, fg?, metadata_id?}`. `rows` is
an array of arrays of these. A row whose length does not match the column
count reports `TableRowShapeMismatch`. `sort_key` is a raw JSON value: a
number sorts numerically, a string sorts as text, anything else or omitted
falls back to `display`. `icon` resolves against the same catalog
`draw_icon` uses.

`table_set_sort` sets the sort column and `direction` (`"none"`,
`"ascending"`, `"descending"`). An unrecognised option string in any table
message reports `InvalidTableOption`.

`table_get_state` returns
`{columns, row_count, sort_column, sort_direction, style, painted, revision}`,
where `columns` reports `kind`, `h_align` and `overflow` resolved to concrete strings
and `painted` is `{row, col, rows, cols}` — where the table last drew. A
client placing something below a table **SHOULD** read `painted` rather
than recomputing the layout, which would drift the moment the host's
layout changes.

### 6.10 Rects

| Method | Kind | Params | Result |
|---|---|---|---|
| `create_rect` | request | `layer?`, `x`, `y`, `w`, `h`, `color`, `line_width?` = 1, `filled?` = false | `{handle}` |
| `update_rect` | notification | `layer?`, `rect`, `x?`, `y?`, `w?`, `h?`, `color?`, `line_width?`, `filled?` | — |
| `destroy_rect` | notification | `layer?`, `rect` | — |

`x`/`y`/`w`/`h` are **pixels in the layer's own content coordinate
frame**, not cells (section 4.6), so a rect pans with `scroll_offset`.

`line_width` applies only when `filled` is false; the outline is drawn as
four non-overlapping strips, so a translucent `color` does not double up
at the corners.

`update_rect` **merges** only the fields actually sent — an omitted field
keeps its current value. This is unlike every other `*_set_*` message in
this specification, which replace wholesale; moving a rect needs only
`x`/`y`.

An unresolvable `layer` reports `UnknownLayer`, an unknown `rect`
reports `UnknownRect`. All three are batchable. There is no read-back
message, and no ownership check — a rect is layer-scoped passive
presentation data, the same treatment tables get.

### 6.11 Outlines

| Method | Kind | Params | Result |
|---|---|---|---|
| `create_outline` | request | `layer?`, `row?`, `col?`, `width?`, `style?` | `{handle}` |
| `destroy_outline` | notification | `layer?`, `outline` | — |
| `outline_set_nodes` | notification | `layer?`, `outline`, `nodes` | — |
| `outline_set_collapsed` | notification | `layer?`, `outline`, `node`, `collapsed?` | — |
| `outline_set_all_collapsed` | notification | `layer?`, `outline`, `collapsed`, `depth?` | — |
| `outline_set_style` | notification | `layer?`, `outline`, `style` | — |
| `outline_get_state` | request | `layer?`, `outline` | see below |

`row`/`col` default to the layer's cursor; `width` defaults to the rest
of the layer's width from `col`.

**Node** — `{depth?=0, runs, icon?, metadata_id?, collapsible?=false, collapsed?=false}`.
The list is flat: a node marked `collapsible` and `collapsed` hides the
contiguous run of following nodes whose `depth` is greater than its own.
`icon` resolves against the same catalog `draw_icon` uses.

**Run** — `{text, fg?, bg?, metadata_id?}`, the same shape `write_text`'s
`spans` takes. A node's `runs` are written back to back as its row. An
omitted `fg` takes the layer default, an omitted `bg` the row's own
background, an omitted `metadata_id` the node's.

**Style** — `{indent?=2, marker_collapsed?, marker_expanded?, marker_fg?, alt_row_bg?}`.
Every node reserves **two cells** for its marker at its own indent
column, whether or not it is collapsible, so sibling text lines up. A
row wider than `width` is clipped; outlines never wrap.

`outline_set_collapsed` with `collapsed` omitted **toggles**. A `node`
index past the end reports `OutlineNodeOutOfRange`; a non-collapsible
node is a silent no-op. `outline_set_all_collapsed` applies to every
collapsible node, or only those at `depth`, in one reflow.

A toggle that changes the outline's height **reflows the layer**: rows at
and above the outline shift up by the difference, the topmost passing
into scrollback, and rows below it do not move.

A toggle that leaves the **toggled node** off screen then **scrolls the
layer's view** back to it, and **MUST** report that move as a `scroll`
notification (section 7) so subscribers stay in step. This moves
`view_scroll` — the display-only scrollback offset — not the content.

The target is that node together with its currently-visible descendants,
so expanding reveals the whole block it just opened; when the block is
taller than the window its own row takes the top. It is ensure-visible:
the nearest offset that fits the block, so a toggle needing no scroll
does not move the view. `outline_set_all_collapsed` has no one node to
point at and anchors on the outline's top row instead. A layer with no
scrollback has nothing to move and is left alone. Rows pushed past
`scrollback_rows` are evicted and a later collapse cannot recover them; a
collapse with less than the needed history takes the shortfall off the
bottom instead. On the alternate screen, which has no scrollback, the
reflow is a no-op. A reflow **clears the layer's selection**, the same as
a resize.

`outline_get_state` returns
`{nodes, node_count, visible_rows, style, painted, revision}`, where each
`nodes[]` entry is `{depth, collapsible, collapsed, visible}` and
`visible` is whether that node is on screen as the list currently stands.
`painted` is `{row, col, rows, cols}`, and a client placing content below
an outline **SHOULD** read it rather than recomputing the layout.

Every outline message is batchable.

### 6.12 Selection and clipboard

| Method | Kind | Params | Result |
|---|---|---|---|
| `set_selection` | notification | `layer?`, `anchor`, `active` | — |
| `update_selection` | notification | `layer?`, `active` | — |
| `clear_selection` | notification | `layer?` | — |
| `get_selection` | request | `layer?` | selection state |
| `get_selection_text` | request | `layer?` | `{text}` |
| `set_clipboard` | notification | `text` | — |
| `get_clipboard` | request | — | `{text}` |

A **selection point** is `{above, col}`: `above` is rows above the live
viewport's top (positive = scrollback), `col` a 0-based column. Points are
content-anchored rather than screen-anchored, so a selection survives
scrolling and new output. A point may land on either half of a wide
character; what the selection *covers* (the tint and
`get_selection_text`) always widens to the whole character. A point on
the rows a scaled glyph draws down into belongs to the glyph's own row,
and the tint covers every row the selected glyphs draw into. Each row's
tint and text stop at its last non-blank cell, and cells written with
`write_text`'s `selectable: false` are never tinted or copied.

**Selection state** is `{active, anchor?, active_end?}`; `anchor` and
`active_end` are absent when `active` is false.

`update_selection` moves only the dragging end — the drag primitive.

The three mutating messages return nothing. A client that wants to see the
result subscribes to `selection` (section 7) and reads the notification
they broadcast, or reads back with `get_selection`.

### 6.13 Highlights

| Method | Kind | Params | Result |
|---|---|---|---|
| `toggle_highlight` | request | `layer?`, `row`, `col`, `view_offset?` = 0 | highlight state |
| `set_highlight` | request | `layer?`, `ids?` = [] | highlight state |
| `clear_highlight` | request | `layer?` | highlight state |
| `get_highlight` | request | `layer?` | highlight state |

Highlights are a set of **metadata ids** marked on a layer, not a set of
cells — which is what makes multi-select survive a re-sort or a redraw.
`toggle_highlight` resolves a cell to its metadata id and flips it.
`set_highlight` replaces the whole set; an empty `ids` equals
`clear_highlight`.

**Highlight state** is `{entries}`, each `{id, json?}` — the blob comes
along so a client needn't round-trip per id. `json` null means the id was
destroyed but is still in the set.

### 6.14 Layer splits

A layout tree over layers within one context.

| Method | Kind | Params | Result |
|---|---|---|---|
| `create_split` | request | `axis`, `resizable?` = true | `{handle}` |
| `destroy_split` | notification | `split` | — |
| `set_split_children` | notification | `split`, `children` | — |
| `set_root_split` | notification | `split?` | — |
| `move_divider` | notification | `split`, `index`, `delta` | — |

`axis` is `"row"` or `"column"`; anything else reports
`InvalidSplitAxis`.

A **child** is `{layer?, split?, weight?, fixed?}` and **MUST** name
exactly one of `layer` or `split`; naming both or neither reports
`InvalidSplitChild`. `fixed` is a cell count; `weight` shares the
remainder.

`set_root_split(null)` detaches the tree. When the tree is re-laid-out — a
window resize or a divider drag — subscribers to `layout` receive the new
bounds for every pane that has moved **since the last `layout` they were
sent**. A server may re-walk the tree without notifying (it does so after
any pane change), so "moved" is measured against what was last reported,
not against what was last computed.

### 6.15 Panes and the window-manager role

Pane messages require the `window_manager` role. A connection without it
gets `NotWindowManager`.

| Method | Kind | Params | Result |
|---|---|---|---|
| `request_role` | request | `role`, `token?` | `{granted, token}` |
| `join_role` | notification | `role`, `token?` | — |
| `create_pane` | request | `scrollback_rows?` = 0 | `{pane, context}` |
| `destroy_pane` | notification | `pane` | — |
| `focus_pane` | notification | `pane` | — |
| `attach_pane` | notification | `pane` | — |
| `create_pane_split` | request | `axis`, `resizable?` = true | `{split}` |
| `destroy_pane_split` | notification | `split` | — |
| `set_pane_split_children` | notification | `split`, `children` | — |
| `set_root_pane_split` | notification | `split?` | — |
| `move_pane_divider` | notification | `split`, `index`, `delta` | — |
| `spawn_in_pane` | request | `pane`, `argv`, `cols?`, `rows?` | `{pid}` |
| `set_window_prefix` | notification | `key?`, `ctrl?` = true, `alt?` = false, `shift?` = false | — |

`request_role` claims a role; `granted` is false when another connection
holds it. The returned `token` lets the holder's *other* connections
`join_role` — a multiplexer's drawing connection and its input listener are
two sockets that must count as one manager. An unknown role reports
`UnknownRole`.

`create_pane` returns both the pane and the context created inside it.
Pane split messages mirror section 6.14 with `pane` in place of `layer`;
their child shape is `{pane?, split?, weight?, fixed?}` and reports
`InvalidPaneSplitChild`.

`attach_pane` binds the issuing connection to a pane — what a program
spawned into a pane sends first, from `GLYPHWIRE_PANE`.

`spawn_in_pane` forks a program with the discovery variables set for that
pane. `argv` **MUST** be non-empty; the first element is resolved through
`PATH`. A host with no spawner — the headless server — reports
`SpawnUnsupported`; a failed fork or exec reports `SpawnFailed`. When the
program exits, `pane_exit` is delivered to `panes` subscribers.

`set_window_prefix` registers the chord that steals the *following*
keystroke for the manager. The **session**, not the manager, decides this,
because the host reports each keystroke on two streams and modifier state
belongs to the session. The key after the prefix arrives as
`window_key_down` / `window_key_up` / `window_text` (section 7), addressed
to the manager alone and never broadcast. Passing `key: null` unregisters.

### 6.16 Remote sessions

| Method | Kind | Params | Result |
|---|---|---|---|
| `start_remote` | request | `dest`, `ssh_args?` = [], `remote_command?` | `{session}` |
| `stop_remote` | notification | `session` | — |

Starts an `ssh` to `dest` running a remote agent, and multiplexes that
agent's clients onto this host over one trunk. A remote program then drives
this host's grid exactly as a local socket client does.

An empty `dest`, or an agent that never announces itself, reports
`RemoteStartFailed`. A host with no remote starter reports
`RemoteUnsupported`. Session end arrives as `remote_exit` on the `remote`
stream — note it goes to the *listener* connection, not the requester,
because a program's drawing client and its input listener are separate
connections and it is the listener that waits.

### 6.17 Input reporting

These let a client inject input as though the user produced it — used by
the host's own in-process path and by test harnesses.

| Method | Kind | Params | Result |
|---|---|---|---|
| `report_key` | notification | `key`, `pressed` | — |
| `report_text` | notification | `text` | — |
| `report_mouse_button` | notification | `button`, `pressed`, `px`, `cell`, `view_offset?` = 0 | — |
| `report_mouse_move` | notification | `px`, `cell` | — |
| `get_input_state` | request | — | `{keys_down, mouse_buttons_down, cursor_px, cursor_cell}` |
| `set_key_repeat` | notification | `delay_ms?`, `interval_ms?` | — |

Each `report_*` fans the corresponding notification out to subscribers per
section 7.

`set_key_repeat` sets the typematic cadence the host runs at while the
issuing connection's active context is focused: `delay_ms` before the
first repeat, `interval_ms` between repeats after it. It governs both
the `key_down` repeats of named keys and the `text` repeats of held
printable keys, so one held key cannot run at two rates.

**Every arrival also cancels the repeat in flight**, so whatever is held
stops repeating until pressed again; a focus change does the same. A
client whose keys mean different things in different modes **SHOULD**
send this on every mode change, not only when the numbers differ — the
key still held across the change was pressed under the old meaning.

Both fields absent clears the override; one alone keeps the other from
the current override, or from the defaults (500 / 40 ms). The host
clamps `delay_ms` to 0..5000 and `interval_ms` to 10..2000, and applies
the change from the next press, never mid-hold.

### 6.18 Subscriptions and introspection

| Method | Kind | Params | Result |
|---|---|---|---|
| `subscribe` | request | `events`, `pane?` | `{subscribed}` |
| `get_cell_metrics` | request | — | `{cell_px_w, cell_px_h}` |
| `get_errors` | request | — | `{errors, dropped}` |

The metrics change at runtime with a font-size step. The host keeps the
window's pixel size and reflows the grid instead, and announces the step
as a `resize` to every client, even one whose cell count came out the
same. A client that works in pixels re-reads `get_cell_metrics` on every
`resize`; there is no separate metrics notification.

`subscribe` **replaces** the connection's subscription set; it is not
additive. `events` is an array of stream names (section 7.1). Unknown names
are ignored. `pane` atomically binds the connection to a pane as it arms
the fan-out — an unknown pane is ignored rather than failing the
subscribe, since the pane may have been destroyed between the spawn and
the connect, and staying in the focused pane beats refusing to subscribe.

`get_errors` drains the ring described in section 3.4 and returns
`{errors: [{method, code, seq}], dropped}`. `seq` is a per-connection
monotonic counter; `dropped` counts entries lost to a full ring since the
last call.

### 6.19 `batch`

| Method | Kind | Params | Result |
|---|---|---|---|
| `batch` | request or notification | `messages` | array of sub-results |

Applies an ordered list of JSON-RPC message objects in one go, under a
single hold of the host's state lock, so nothing renders a half-updated
grid partway through. This is the mechanism for a client that redraws a
whole screen per frame.

Rules:

- `messages` is an array of complete message objects, each with its own
  `method` and `params`.
- **`batch` and `load_image` MUST NOT appear as sub-messages.** A host
  **MUST** skip and log either.
- A sub-message that fails is skipped and logged; the batch continues. It
  is recorded in the error ring like any failed notification.
- Broadcasts a sub-message would have produced are **dropped**. State
  changes still apply.
- In notification form, sub-message responses are discarded.

## 7. Server → client notifications

All are notifications; none expects a reply. A connection receives only
the streams it subscribed to.

`key_down`, `key_up`, `text`, `mouse_button`, `mouse_move` and
`copy_request` are additionally **addressed**: they reach only the
connection whose active context is the one on screen in the focused pane.
The first five are raw input, which belongs to whatever the user is
looking at. `copy_request` rides with them because it is the answer to
one keystroke and a single clipboard write — fanned out, every
`"clipboard"` subscriber would answer with `set_clipboard` and the last
one to arrive would win. Every other notification fans out to all
subscribers, so a backgrounded client can keep its content current.

### 7.1 Streams

`subscribe`'s `events` takes these names. Several names map to one
underlying stream, so a client can name the event it wants rather than the
flag.

| Stream | Delivers | Accepted names |
|---|---|---|
| key | `key_down`, `key_up` | `key` |
| text | `text` | `text` |
| mouse_button | `mouse_button` | `mouse_button` |
| mouse_move | `mouse_move` | `mouse_move` |
| resize | `resize` | `resize` |
| shutdown | `shutdown` | `shutdown` |
| focus | `focus` | `focus` |
| scroll | `scroll`, `scroll_offset` | `scroll`, `scroll_offset` |
| layout | `layout` | `layout` |
| selection | `selection` | `selection` |
| clipboard | `copy_request`, `paste` | `clipboard`, `copy_request`, `paste` |
| terminal | `terminal_reply` | `terminal` |
| context | `context` | `context` |
| theme | `theme` | `theme` |
| panes | `pane_layout`, `pane_exit` | `panes`, `pane_layout`, `pane_exit` |
| window_keys | `window_key_down`, `window_key_up`, `window_text` | `window_keys`, `window_key`, `window_text` |
| remote | `remote_exit` | `remote`, `remote_exit` |
| error | *(nothing — see below)* | `error` |

`error` is not a broadcast stream. Subscribing to it tells the host to
start recording this connection's failed notifications into a ring, which
the client drains with `get_errors`.

### 7.2 Catalog

| Notification | Params |
|---|---|
| `key_down` / `key_up` | `{key, mods}` |
| `text` | `{text}` |
| `mouse_button` | `{button, pressed, px, cell, view_offset, mods}` |
| `mouse_move` | `{px, cell, mods}` |
| `resize` | `{cols, rows}` |
| `scroll` | `{layer, offset, max}` |
| `scroll_offset` | `{layer, row, col, max_row, max_col}` |
| `layout` | `{layers: [{layer, row, col, cols, rows}]}` |
| `selection` | `{active, anchor?, active_end?}` |
| `copy_request` | `{}` |
| `paste` | `{text}` |
| `terminal_reply` | `{bytes}` |
| `context` | `{context, cols, rows}` |
| `theme` | `{name, dark, panel_style}` |
| `pane_layout` | `{panes: [{pane, row, col, cols, rows}]}` |
| `pane_exit` | `{pane, status}` |
| `window_key_down` / `window_key_up` | `{key, mods}` |
| `window_text` | `{text}` |
| `remote_exit` | `{session, status, started}` |
| `shutdown` | `{grace_ms}` |
| `focus` | `{focused}` |

**`key_down` vs `text`.** These are deliberately separate streams. A key
event carries a *physical key name*, for chords and navigation. `text`
carries what the user actually typed, already resolved through the OS
keyboard layout, dead keys and IME composition — which for a non-US
layout, an AltGr combination or a CJK IME is not derivable from the key
name. A client editing a line subscribes to both and inserts from `text`.
A typematic repeat arrives as another `key_down`; nothing distinguishes it.

**`mods`** is `{ctrl, alt, shift, super}` as held when the host generated
the event, left and right folded. Read chords from it, not from a live
key-state query made when the event is handled: by then a quick chord may
already be released.

**`mouse_button`'s `cell`** is a cell of the receiving connection's
*context*, never of one of its layers. A client drawing into a layer that
sits somewhere inside the window — a popup, an embedded panel — **MUST**
take that layer's `cell_position` off it before using it to address the
layer's grid.

**`mouse_button`'s `view_offset`** is the root layer's scrollback offset at
click time. Pass it back to `get_metadata` to resolve `cell` against the
row the user actually clicked. It is the *root* layer's, so a client whose
content is on a layer with a scrollback ring of its own uses that layer's
offset (from its `scroll` notifications) instead.

**`mouse_move`** fires only when the pointer changes *cell*; per-pixel
motion is coalesced.

**`theme`** says the window theme changed (the host's theme switcher)
and goes **only** to connections whose context follows it: one that set
its own with `set_theme` drew nothing that changed. Every colour reference
already on screen recolours without the client; the notification is for
what it resolved itself — `panel_style` (a nine-patch can't be
recoloured) and blends — which it re-reads with `get_theme`.

**`resize`** carries the receiving connection's own context size: the
window's for a client that has the window to itself, its pane's for one
inside a pane — deliberately indistinguishable.

**`scroll`**'s `layer` is null for the root layer's scrollback (the common
case) and a handle for a non-root layer's ring.

**`terminal_reply`** carries the bytes a `write_text` produced in answer to
a terminal query. A client bridging a pty writes them to the pty master.

**`remote_exit`**'s `started` distinguishes "the remote shell exited" from
"the connection never came up" — `ssh` passes the remote command's exit
code through, so `status` alone cannot say.

**`shutdown`** means the host window is closing. `grace_ms` is roughly how
long the host will wait before exiting anyway; it is advisory, and a client
with nothing to flush **MAY** ignore it.

**`focus`** says whether the host's window has the keyboard. It is about
the whole window against the rest of the desktop — not which context is
on screen (`context`) or which pane is focused within the window. Sent on
the edge only, to every subscriber whatever their context, so a
backgrounded client comes back up drawn correctly. A client **SHOULD**
assume it has focus until told otherwise. While the window is away the
host draws its own caret as a hollow box and stops blinking it; a client
that paints its own cursor **SHOULD** do something equivalent.

## 8. Vocabularies

### 8.1 Key names

Physical key names, as they appear in `key_down` / `key_up` / `report_key`.

```
unknown space apostrophe comma minus period slash
zero one two three four five six seven eight nine
semicolon equal
a b c d e f g h i j k l m n o p q r s t u v w x y z
left_bracket backslash right_bracket grave_accent
escape enter tab backspace insert delete
right left down up page_up page_down home end
caps_lock scroll_lock num_lock print_screen pause
F1 … F24
kp_0 … kp_9 kp_decimal kp_divide kp_multiply kp_subtract kp_add
kp_enter kp_equal
left_shift left_control left_alt left_super
right_shift right_control right_alt right_super
menu
```

Two things to know:

- **Function keys are capitalised** (`F1`, not `f1`) while every other name
  is lowercase. This is an inconsistency, not a typo; it is the wire
  vocabulary.
- **The reference host reports modifiers under their `left_*` name only,**
  from the logical modifier state, so an OS remap such as CapsLock→Ctrl
  arrives as `left_control`. A client **SHOULD** treat `left_*` as "this
  modifier is down" rather than as a physical side.

Names are the reference host's; another host **MAY** report others, and a
client **SHOULD** ignore a name it does not recognise.

### 8.2 Mouse buttons

`left`, `right`, `middle`, `x1`, `x2`.

### 8.3 Image formats

`png`, `jpeg` (`jpg` accepted as an alias), `bmp`, `gif`.

### 8.4 Enumerated option strings

| Where | Values |
|---|---|
| icon `scale` | `fit`, `natural`, `stretch` |
| icon / column `h_align`, icon `v_align` | `start`, `center`, `end` |
| split `axis` | `row`, `column` |
| column `kind` | `text`, `number` |
| sort `direction` | `none`, `ascending`, `descending` |
| `move_content` `direction` | `up`, `down` |
| `find_metadata` `direction` | `next`, `prev` |
| cell `wide` | `lead`, `spacer`, absent |

## 9. A minimal client

The smallest useful client, in full:

```
→ Content-Length: 94
→
→ {"jsonrpc":"2.0","method":"write_text","params":{"text":"hello\n","fg":{"r":0,"g":255,"b":0}}}

→ Content-Length: 81
→
→ {"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"revision"}}

← Content-Length: 49
←
← {"jsonrpc":"2.0","id":1,"result":{"revision":12}}
```

Connect to `$GLYPHWIRE_SOCK`, write text, then issue one request before
closing so the host is known to have applied it (section 3.2). That is a
complete, conforming client.

A client that also wants input adds:

```
→ {"jsonrpc":"2.0","id":2,"method":"subscribe","params":{"events":["key","text","resize"]}}
← {"jsonrpc":"2.0","id":2,"result":{"subscribed":["key","text","resize"]}}
← {"jsonrpc":"2.0","method":"text","params":{"text":"h"}}
← {"jsonrpc":"2.0","method":"key_down","params":{"key":"enter"}}
```

Note that a drawing client and an input listener are commonly **two
connections** to the same socket, because a blocking read for input would
otherwise stall drawing. Section 6.15's `join_role` and section 6.1's
`attach_context` exist to let two connections act as one program.

## 10. Versioning and compatibility

**There is no version negotiation.** No handshake, no capability exchange,
no version field in the envelope. A client cannot ask a host what it
supports, and a host cannot tell a client what it speaks. This is a known
gap and is expected to be filled before 1.0.

What a client can rely on today:

- **Unknown params are ignored.** A host **MUST** ignore `params` members
  it does not recognise, so a newer client's extra fields degrade to the
  older behaviour rather than failing.
- **Unknown methods fail.** There is no soft failure for a method a host
  does not implement: as a notification it is silently dropped
  (`UnknownMethod` in the error ring), as a request it severs the
  connection. A client using a method that might be absent **MUST** send it
  as a notification, or be prepared to reconnect.
- **Nothing else is guaranteed.** Message shapes, handle semantics and
  stream names **MAY** change in any 0.x release.

The practical consequence: a client that wants to probe for a feature
should `subscribe` to `"error"`, send the message as a notification, and
check `get_errors` for `UnknownMethod`.

## 11. Design rationale in brief

Fuller treatment in [`decisions.md`](decisions.md).

**Why not escape sequences.** A terminal's in-band signalling conflates
content with control: every byte of output must be scanned for control
codes, an unrecognised sequence corrupts the screen, and a program cannot
ask a question of the terminal without a parser on both ends. Structured
messages on a side channel have none of these properties.

**Why JSON-RPC over `Content-Length`.** Both halves are debuggable with
tools people already have — `nc -U`, `jq` — and neither needs
newline-escaping. The cost is bytes, and the answer to the cost is
`batch` (6.17) plus a raw side channel for the one payload that would
actually hurt (2.3).

**Why handles, not content, in read-backs.** `get_cells` reports an image
as a handle, not pixels; a metadata tag as an id, not a blob. Resolving is
a separate request the client makes only when it needs to. The alternative
makes an innocuous screen snapshot arbitrarily expensive.

**Why the host owns tables and layout.** Sorting a 10,000-row listing is
one message, not a full redraw. The general form of this: state that
changes faster than the client can redraw belongs on the server side of
the socket.

**Why ownership-based culling.** A client that crashes without cleaning up
must not leave its surface stuck on screen. Every created layer and context
is owned by the connection that made it, and dies when its last owner
disconnects. No timeouts, no heartbeats.

## 12. License

This specification is licensed under
[Creative Commons Attribution 4.0 International](../LICENSES/CC-BY-4.0.txt).

You may implement it, copy it, adapt it and redistribute it, commercially
or not, provided you give appropriate credit. **An implementation of this
specification carries no obligation beyond attribution** — the licenses on
glyphwire's own source (see [`../LICENSE.md`](../LICENSE.md)) do not reach
an independent implementation.
