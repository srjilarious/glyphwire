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
| `GLYPHWIRE_PANE` | host / multiplexer | The pane handle this process was seated in. A client **SHOULD** pass it as `subscribe`'s `pane` (section 6.16). |
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
- `load_image` **MUST NOT** appear inside a `batch` (section 6.17).

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
| A notification failing on a connection subscribed to `"error"` | As above, plus the failure is recorded in a per-connection ring the client drains with `get_errors` (section 6.16). |
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
| `UnknownLayer` | any `layer` handle that does not exist, **and** the root handle where a non-root one is required |
| `LayerPermissionDenied` | `destroy_layer` from a non-owner |
| `UnknownContext`, `RootContextImmutable`, `ContextPermissionDenied`, `NoContextSession` | context messages |
| `UnknownPane`, `RootPaneImmutable`, `UnknownPaneSplit`, `InvalidPaneSplitChild` | pane messages |
| `NotWindowManager`, `UnknownRole` | role messages |
| `UnknownSplit`, `InvalidSplitAxis`, `InvalidSplitChild` | layer-split messages |
| `UnknownImage`, `UnknownIcon`, `InvalidIconOption`, `UnsupportedImageFormat` | image / icon messages |
| `UnknownMetadata`, `InvalidMetadataDirection` | metadata messages |
| `UnknownTable`, `InvalidTableOption`, `TableRowShapeMismatch` | table messages |
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
| `ImageHandle`, `MetadataHandle`, `TableHandle` | no root |
| remote session id | 64-bit |

Handle `0` is the root for layers, contexts and panes and is **never**
valid where a created object is required: `destroy_layer(0)`,
`raise_layer(0)` and friends report `UnknownLayer`, not a permission
error. Handles are per-context for layers, tables, splits and metadata;
per-session for contexts and panes.

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

**Ownership and culling.** The connection that creates a context is its
first owner; `adopt_context` adds more. A context is destroyed once every
owning connection has disconnected, so a full-screen program that dies
without `destroy_context` does not leave its surface stuck on screen. The
same rule governs layers (`create_layer` / `adopt_layer`).

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
- `metadata_id` — an optional metadata handle (section 4.6).
- `wide` — East Asian Width role.

**Wide characters.** A 2-cell East Asian wide character occupies a `lead`
cell holding the grapheme and a `spacer` cell whose `g` is empty. The
spacer carries the lead's background and `metadata_id`, so a background
spans the pair and a hit test on either half resolves the same. An
ordinary 1-cell character has no `wide` member. The host computes width
from Unicode East Asian Width, treating `W` and `F` as wide and `A` as
narrow.

**Colours** are `{"r":0-255,"g":0-255,"b":0-255,"a":0-255}`. `a` defaults
to 255, so `{"r":255,"g":0,"b":0}` is valid. The default style is white on
black.

**Positions.** Pixel positions are `{"x":<f32>,"y":<f32>}`; cell positions
are `{"row":<int>,"col":<int>}`, both 0-based, origin top-left.

### 4.5 Table

A server-side table widget: columns with widths, alignment and sort
behaviour; rows of cells with display text, an optional sort key, an
optional icon and an optional metadata id. The host owns layout, sorting,
borders and striping — a client sets rows and reads back where the table
painted. Sorting a 10,000-row listing costs one message, not a redraw.

### 4.6 Metadata

An opaque JSON blob registered with `create_metadata`, tagged onto cells,
and resolved back from a cell position with `get_metadata`. This is how a
client attaches meaning to a region of the grid — a filename behind a
listing entry, a diagnostic behind a span — without the host understanding
any of it. The host stores and returns the string verbatim.

### 4.7 Pane

Panes are the window manager's tiling of the window, one level above
contexts: each pane holds a *stack* of contexts, and the top of that stack
is what the pane shows. Pane messages are restricted to the connection
holding the `window_manager` role (section 6.13).

A program inside a pane cannot tell it is in one. Its `resize` carries its
pane's size, not the window's, and no message it can send reveals pane
geometry. Only `pane_layout`, which only a window manager subscribes to,
exposes where panes sit.

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
| `create_context` | request | `width?`, `height?`, `scrollback_rows?` = 0, `window_scrollbar?` = true | `{context}` |
| `destroy_context` | notification | `context` | — |
| `activate_context` | notification | `context` | — |
| `attach_context` | notification | `context` | — |
| `adopt_context` | notification | `context` | — |
| `set_window_scrollbar` | notification | `visible` | — |
| `set_caret_layer` | notification | `layer?` | — |

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

`attach_context` retargets the issuing connection onto an existing
context; ownership is untouched. This is how a paired input listener joins
the context its drawing connection created.

`set_caret_layer` points the host's blinking caret at a created layer
instead of the root layer's cursor; `null` restores the root. The host
positions the caret through that layer's bounds, viewport and scroll
offset, and hides it when the layer is scrolled out of view. Destroying
the tracked layer clears the setting.

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
| `write_text` | notification | `layer?`, `row?`, `col?`, `text` \| `spans`, `fg?`, `bg?`, `metadata_id?`, `transparent_bg?` = false, `scale?`, `max_cols?`, `pad?` = false | — |
| `insert_cells` | notification | `layer?`, `count` | — |
| `delete_cells` | notification | `layer?`, `count` | — |
| `move_content` | notification | `layer?`, `top?`, `bot?`, `count?` = 1, `direction?` | — |
| `clear` | notification | `layer?`, `row?` = 0, `col?` = 0, `rows?`, `cols?`, `bg?` | — |
| `get_cells` | request | `layer?`, `view_offset?` = 0 | `{cols, rows, revision, cells}` |
| `scroll_view` | request | `layer?`, `offset?`, `delta?` | `{offset, max}` |

`write_text` writes at `row`/`col` and advances the cursor; each omitted
axis keeps the cursor's current value. `max_cols` clips the run to that
many display columns from its start (never splitting a wide character,
never wrapping), and `pad` fills the rest of that span with blank `bg`
cells. `fg`/`bg` omitted means the server default style.

`spans` replaces `text` with an array of `{text, fg?, bg?, metadata_id?,
transparent_bg?, scale?}` written back to back; each omitted field takes
the message's value, and `max_cols`/`pad` apply to the write as a whole.
Sending both `text` and `spans`, or neither, reports `InvalidSpans`.

A `scale` of `"x1_5"` or `"x2"` advances two cells per display column,
filling the cells after each enlarged glyph with blanks in the run's
background and `metadata_id`. `transparent_bg` leaves whatever
background is already in the cell — an image, an icon, a panel gradient —
instead of resetting it. `metadata_id` tags every cell written.

`write_text` also mirrors a useful subset of ANSI/VT escape sequences found
in the text, so output from a program that does not know about glyphwire
still shows colour. This is **colour only**: SGR 30-37 / 90-97 / 38;2;r;g;b
and their background forms, plus `bold` (maps a basic foreground to its
bright variant), `dim` and `inverse`. There are no attribute bitflags on
the wire. A sequence that is a *query* (`CSI 6n`, device attributes,
DECRQM) produces a `terminal_reply` notification (section 7) rather than a
grid change.

`clear` with `bg` leaves the region blank but opaque in that colour.

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
| `get_image_info` | request | `handle` | `{width, height}` |
| `draw_image` | notification | `layer?`, `handle`, `row?`, `col?`, `row_span`, `col_span`, `scale?` = 1.0 | — |

`format` is `"png"`, `"jpeg"` (`"jpg"` accepted), `"bmp"` or `"gif"`;
anything else reports `UnsupportedImageFormat`. `bytes` is the payload
length, delivered per section 2.3.

`draw_image` sets each cell in the `row_span` × `col_span` rectangle to
sample its own region of the image, so the picture spans the rectangle
rather than repeating per cell.

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

### 6.7 Boxes

| Method | Kind | Params | Result |
|---|---|---|---|
| `draw_box` | notification | `layer?`, `row?`, `col?`, `rows`, `cols`, `style`, `mode?` | — |

A 9-slice panel. `style` names a family in the icon catalog; the host
resolves nine pieces from it — `{style}-tl`, `-t`, `-tr`, `-l`, `-fill`,
`-r`, `-bl`, `-b`, `-br`. No separate registry.

`mode` is `"tile"` (default — each edge and fill piece repeats per cell) or
`"stretch"` (each role's source image is treated as one continuous picture
spanning its whole run, so a gradient blends across the box instead of
banding).

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

**Column** — `{name, kind?, sortable?, case_insensitive?, width, min_width?, h_align?}`.
`kind` is `"text"` (default) or `"number"`; `h_align` is `"start"`
(default), `"center"` or `"end"`. `case_insensitive` folds ASCII case when
sorting a text column.

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
where `columns` reports `kind` and `h_align` resolved to concrete strings
and `painted` is `{row, col, rows, cols}` — where the table last drew. A
client placing something below a table **SHOULD** read `painted` rather
than recomputing the layout, which would drift the moment the host's
layout changes.

### 6.10 Selection and clipboard

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
scrolling and new output.

**Selection state** is `{active, anchor?, active_end?}`; `anchor` and
`active_end` are absent when `active` is false.

`update_selection` moves only the dragging end — the drag primitive.

The three mutating messages return nothing. A client that wants to see the
result subscribes to `selection` (section 7) and reads the notification
they broadcast, or reads back with `get_selection`.

### 6.11 Highlights

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

### 6.12 Layer splits

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
bounds for every pane that moved.

### 6.13 Panes and the window-manager role

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
Pane split messages mirror section 6.12 with `pane` in place of `layer`;
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

### 6.14 Remote sessions

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

### 6.15 Input reporting

These let a client inject input as though the user produced it — used by
the host's own in-process path and by test harnesses.

| Method | Kind | Params | Result |
|---|---|---|---|
| `report_key` | notification | `key`, `pressed` | — |
| `report_text` | notification | `text` | — |
| `report_mouse_button` | notification | `button`, `pressed`, `px`, `cell`, `view_offset?` = 0 | — |
| `report_mouse_move` | notification | `px`, `cell` | — |
| `get_input_state` | request | — | `{keys_down, mouse_buttons_down, cursor_px, cursor_cell}` |

Each `report_*` fans the corresponding notification out to subscribers per
section 7.

### 6.16 Subscriptions and introspection

| Method | Kind | Params | Result |
|---|---|---|---|
| `subscribe` | request | `events`, `pane?` | `{subscribed}` |
| `get_cell_metrics` | request | — | `{cell_px_w, cell_px_h}` |
| `get_errors` | request | — | `{errors, dropped}` |

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

### 6.17 `batch`

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
| scroll | `scroll`, `scroll_offset` | `scroll`, `scroll_offset` |
| layout | `layout` | `layout` |
| selection | `selection` | `selection` |
| clipboard | `copy_request`, `paste` | `clipboard` |
| terminal | `terminal_reply` | `terminal` |
| context | `context` | `context` |
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
| `pane_layout` | `{panes: [{pane, row, col, cols, rows}]}` |
| `pane_exit` | `{pane, status}` |
| `window_key_down` / `window_key_up` | `{key, mods}` |
| `window_text` | `{text}` |
| `remote_exit` | `{session, status, started}` |
| `shutdown` | `{grace_ms}` |

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

**`mouse_button`'s `view_offset`** is the root layer's scrollback offset at
click time. Pass it back to `get_metadata` to resolve `cell` against the
row the user actually clicked.

**`mouse_move`** fires only when the pointer changes *cell*; per-pixel
motion is coalesced.

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
| `draw_box` `mode` | `tile`, `stretch` |
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
otherwise stall drawing. Section 6.13's `join_role` and section 6.1's
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
