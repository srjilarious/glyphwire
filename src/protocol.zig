const std = @import("std");
const core = @import("core.zig");

/// Pure wire data-transfer objects: the JSON shapes that cross the socket,
/// shared verbatim by the server side (`dispatch.zig` builds them,
/// `server.zig` fans some out) and the client side (`client.zig` builds
/// requests and parses responses/notifications). Keeping the one
/// definition here is what stops the two ends from drifting -- see
/// decisions.md's headless-first split; nothing in this module has
/// behavior, it's data and the odd string-name table only.
///
/// Handle types (`core.LayerHandle`, `core.ImageHandle`, ...) and the
/// `{x,y}` / `{row,col}` position pairs already have a single definition
/// in `core.zig` and serialize as the wire wants, so they're re-exported
/// rather than redeclared.

pub const PxPos = core.PxPos;
pub const CellPos = core.CellPos;

/// An RGBA color on the wire. `a` defaults to fully opaque so a client
/// can send `{r,g,b}` and omit it.
pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

/// An image background reference in a `get_cells` cell -- the handle plus
/// the sub-image offset the cell samples from (see `core.ImageBg`). Only
/// the handle crosses the wire, never the pixels.
pub const ImageBg = struct { handle: core.ImageHandle, offset_x: u32, offset_y: u32 };

/// An icon background/foreground reference in a `get_cells` cell (see
/// `core.IconBg`). `scale`/`h_align`/`v_align` are the `@tagName` strings
/// of the matching `core` enums; `max_w`/`max_h` are only meaningful when
/// `scale == "natural"`.
pub const IconBg = struct {
    handle: core.ImageHandle,
    scale: []const u8,
    h_align: []const u8,
    v_align: []const u8,
    max_w: ?u32 = null,
    max_h: ?u32 = null,
};

/// One flattened cell in a `get_cells` response, row-major starting at
/// (0,0). Exactly one of `bg`/`bg_image`/`bg_icon` is non-null, per
/// `core.Background`'s tagged union -- see decisions.md's Cell section.
/// `fg_icon` is a sibling of that union, not part of it: an icon drawn
/// *over* the background (`draw_icon`'s `foreground: true`, and every
/// table body icon -- see `core.Cell.fg_icon`), independent of which
/// `bg*` case is set.
pub const WireCell = struct {
    g: []const u8,
    fg: Color,
    bg: ?Color,
    bg_image: ?ImageBg = null,
    bg_icon: ?IconBg = null,
    fg_icon: ?IconBg = null,
    /// Just the id, not the resolved JSON -- same "handle, not content"
    /// treatment `bg_image`/`bg_icon` already give image/icon handles.
    /// `get_metadata` resolves an id to its actual content.
    metadata_id: ?core.MetadataHandle = null,
    /// East Asian Width role of the cell: `"lead"` = left half of a
    /// 2-cell wide character (holds the grapheme), `"spacer"` = its right
    /// half (renders nothing, carries the lead's bg + metadata), absent =
    /// an ordinary 1-cell character. See decisions.md, Cell content.
    wide: ?[]const u8 = null,
};

/// The `get_cells` response body: the layer's visible viewport as a
/// row-major `cells` array (`cols * rows` long) plus the layer revision
/// it was snapshotted at.
pub const CellsResult = struct {
    cols: usize,
    rows: usize,
    revision: u64,
    cells: []const WireCell,
};

/// The `get_input_state` response body: the authoritative down-sets plus
/// the last known cursor position.
pub const InputStateResult = struct {
    keys_down: []const []const u8,
    mouse_buttons_down: []const []const u8,
    cursor_px: PxPos,
    cursor_cell: CellPos,
};

// ─── Table ───────────────────────────────────────────────────────────────

/// A column as sent to `create_table`. `kind`/`h_align` are optional
/// wire strings (`null` means the `core` enum's default: `"text"` /
/// `"start"`); the client fills them in explicitly, a raw socket client
/// can omit them.
pub const TableColumn = struct {
    name: []const u8,
    /// "text" (default) or "number" -- see `core.ColumnKind`.
    kind: ?[]const u8 = null,
    sortable: bool = false,
    width: usize,
    min_width: usize = 1,
    /// "start" (default), "center", or "end".
    h_align: ?[]const u8 = null,
};

/// A table's style, shared by `create_table`'s `style`, `table_set_style`'s,
/// and the read-back `table_get_state` reports -- the wire and read-back
/// shapes are identical. Every field defaults, so a client can send a
/// partial style.
pub const TableStyle = struct {
    borders: bool = true,
    header_separator: bool = true,
    box_style: ?[]const u8 = null,
    alt_row_bg: ?Color = null,
    header_fg: ?Color = null,
    header_bg: ?Color = null,
    row_height: usize = 1,
    /// Upper bound in pixels on a body icon's rendered height (see
    /// `core.TableStyle.max_icon_px`). Omitted → the row height alone
    /// bounds it.
    max_icon_px: ?u32 = null,
};

/// One row's cell, as sent to `table_set_rows`. `sort_key` (see
/// `core.SortKey`'s doc comment) is left as a raw `std.json.Value` rather
/// than a typed field, since it's naturally either a JSON number or a
/// JSON string depending on the column -- a number parses as `.number`,
/// a string as `.text`, anything else (or the field omitted) falls back
/// to a copy of `display`.
pub const TableCell = struct {
    display: []const u8,
    sort_key: ?std.json.Value = null,
    /// An icon-registry name, resolved the same way `draw_icon`'s `name`
    /// is (`Context.iconHandle`).
    icon: ?[]const u8 = null,
    fg: ?Color = null,
    metadata_id: ?core.MetadataHandle = null,
};

/// A column as reported back by `table_get_state` -- `kind`/`h_align`
/// are resolved to their concrete `@tagName` strings here, never null.
pub const ColumnState = struct {
    name: []const u8,
    kind: []const u8,
    sortable: bool,
    width: usize,
    min_width: usize,
    h_align: []const u8,
};

/// Where a table last painted (`core.Table.painted`) -- a client that
/// wants to place something below the table (e.g. `glyphwire-ls -l`'s
/// next shell prompt) needs this rather than recomputing the layout math
/// `Table.render` already did, which would drift the moment that layout
/// changes.
pub const TablePainted = struct {
    row: usize,
    col: usize,
    rows: usize,
    cols: usize,
};

/// The `table_get_state` response body.
pub const TableStateResult = struct {
    columns: []const ColumnState,
    row_count: usize,
    sort_column: ?usize,
    sort_direction: []const u8,
    style: TableStyle,
    painted: TablePainted,
    revision: u64,
};

// ─── Notification params ─────────────────────────────────────────────────
//
// The `params` object of each server->client input notification. The
// method name (`key_down`/`key_up`, `mouse_button`, `scroll`, `resize`)
// carries the rest; see `rpc.zig` for the builders that wrap these in an
// envelope, and `client.zig`'s `InputListener` for the parse side.

/// `key_down` / `key_up` params. The pressed/released bit is the method
/// name, not a field.
pub const KeyParams = struct { key: []const u8 };

/// `text` params: a run of committed text input, already resolved through
/// the OS keyboard layout, dead keys and IME composition -- one or more
/// Unicode codepoints as a UTF-8 string. Deliberately distinct from
/// `key_down` (see decisions.md's Input model): a key event carries a
/// physical key name for chords and navigation; this carries what the
/// user actually typed, which for a non-US layout, an AltGr combo or a
/// CJK IME is not derivable from the key name.
pub const TextParams = struct { text: []const u8 };

/// `mouse_button` params. `view_offset` is the root layer's scrollback
/// view offset at click time (see `core.Layer.view_scroll`) so a
/// subscriber resolving `cell` with `get_metadata` can pass the same
/// offset and land on the row the user actually clicked.
pub const MouseButtonParams = struct {
    button: []const u8,
    pressed: bool,
    px: PxPos,
    cell: CellPos,
    view_offset: usize = 0,
};

/// `scroll` params: the root layer's scrollback view offset and the
/// retained-history maximum it's clamped to.
pub const ScrollParams = struct { offset: usize, max: usize };

/// `resize` params: the new host window size, in cells.
pub const ResizeParams = struct { cols: usize, rows: usize };

// ─── Selection & clipboard ───────────────────────────────────────────────

/// One end of a selection on the wire -- mirrors `core.SelectionPoint`.
/// `above` is rows above the live viewport's top (positive = scrollback);
/// `col` is a 0-based cell column. See `core.SelectionPoint`'s doc
/// comment for why it's content-anchored rather than a screen position.
pub const SelectionPointWire = struct { above: i64, col: usize };

/// `set_selection` params: both ends explicitly.
pub const SetSelectionParams = struct {
    layer: ?core.LayerHandle = null,
    anchor: SelectionPointWire,
    active: SelectionPointWire,
};

/// `update_selection` params: move only the active (dragging) end.
pub const UpdateSelectionParams = struct {
    layer: ?core.LayerHandle = null,
    active: SelectionPointWire,
};

/// `clear_selection` params / `get_selection` / `get_selection_text`
/// params -- just the target layer.
pub const LayerOnlyParams = struct { layer: ?core.LayerHandle = null };

/// `get_selection` result and the `selection` server->client
/// notification: `active` is false when nothing is selected, in which
/// case `anchor`/`active_end` are absent.
pub const SelectionState = struct {
    active: bool,
    anchor: ?SelectionPointWire = null,
    active_end: ?SelectionPointWire = null,
};

/// `get_selection_text` result.
pub const SelectionTextResult = struct { text: []const u8 };

/// `set_clipboard` params and the `paste` server->client notification --
/// both just carry the text.
pub const ClipboardTextParams = struct { text: []const u8 };

/// `get_clipboard` result.
pub const ClipboardResult = struct { text: []const u8 };
