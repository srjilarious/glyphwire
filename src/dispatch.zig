const std = @import("std");
const core = @import("core.zig");

/// Dispatches decoded JSON-RPC message bodies (the wire module's frame
/// payloads) against a headless `Context`. This is the message-catalog
/// subset needed to prove the vertical slice works end to end — just
/// enough of `write_text` and `get_property`/`set_property` for the
/// slice's "hello" round trip, not the fuller catalog from decisions.md
/// (still an open item there).
///
/// Per decisions.md's Protocol Shape: draw/state-change commands
/// (`write_text`, `set_property`) are notifications with no response;
/// `get_property` is a request since it needs to return a value.
/// JSON-RPC error *responses* aren't implemented yet — malformed or
/// unrecognized messages surface as Zig errors instead, since there's no
/// socket layer yet to decide how to report them to a peer.
pub const DispatchError = error{
    UnknownMethod,
    UnknownProperty,
    NotARequest,
    UnknownImage,
    UnknownIcon,
    UnknownLayer,
    InvalidIconOption,
    UnknownMetadata,
    UnknownTable,
    InvalidTableOption,
    TableRowShapeMismatch,
};

const Envelope = struct {
    method: []const u8,
    id: ?std.json.Value = null,
    params: std.json.Value = .null,
};

const ColorJson = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

/// No `row`/`col` fields: this slice's `Layer.writeText` only supports
/// cursor-implicit writes (see core.zig). Explicit positioning is decided
/// in decisions.md but not needed until a milestone past this slice.
/// `layer` (omitted, or `root_layer_handle`) means the root layer, same
/// convention as `row`/`col` defaulting to the cursor elsewhere.
const WriteTextParams = struct {
    layer: ?core.LayerHandle = null,
    text: []const u8,
    fg: ?ColorJson = null,
    bg: ?ColorJson = null,
    /// See `core.Cell.metadata_id`'s doc comment.
    metadata_id: ?core.MetadataHandle = null,
    /// `false` (default): `bg` omitted means "reset to
    /// `core.default_style.bg`" -- the original, still-default behavior.
    /// `true`: leaves each touched cell's existing background untouched
    /// instead (`bg` is ignored either way when this is set), for writing
    /// text over a background drawn some other way -- e.g. `draw_box`'s
    /// fill -- that needs to stay visible through it rather than being
    /// approximated with a matching flat color.
    transparent_bg: bool = false,
};

/// Params shared by `insert_cells`/`delete_cells` -- also cursor-implicit
/// like `write_text`, see `WriteTextParams`.
const CellCountParams = struct {
    layer: ?core.LayerHandle = null,
    count: usize,
};

/// Params shared by `set_property`/`get_property`. Not every field is
/// meaningful for every `property` value -- `row`/`col` for `"cursor"`,
/// `x`/`y` for `"position"` -- the handler picks which subset to read
/// once it knows `property`, the same "flexible bag, dispatched on a
/// string" shape `ClearParams` already uses for its own optional fields.
const PropertyParams = struct {
    layer: ?core.LayerHandle = null,
    property: []const u8,
    row: usize = 0,
    col: usize = 0,
    x: f32 = 0,
    y: f32 = 0,
};

const CursorResult = struct { row: usize, col: usize };
const RevisionResult = struct { revision: u64 };
const PositionResult = struct { x: f32, y: f32 };

const GetCellsParams = struct {
    layer: ?core.LayerHandle = null,
};

const CreateLayerParams = struct {
    width: ?usize = null,
    height: ?usize = null,
    scrollback_rows: usize = 0,
};

const CreateLayerResult = struct { handle: core.LayerHandle };

const DestroyLayerParams = struct {
    layer: core.LayerHandle,
};

const CreateMetadataParams = struct {
    json: []const u8,
};

const CreateMetadataResult = struct { handle: core.MetadataHandle };

const DestroyMetadataParams = struct {
    id: core.MetadataHandle,
};

const GetMetadataParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize,
    col: usize,
};

/// `id`/`json` are both null together (the cell isn't tagged) or `id` is
/// set with `json` still possibly null (tagged, but the id has since been
/// `destroy_metadata`'d -- see `Context.destroyMetadata`'s doc comment).
/// Reporting `id` even when `json` can't be resolved is what lets a
/// caller like a future mouse-click handler tell those two cases apart.
const GetMetadataResult = struct {
    id: ?core.MetadataHandle,
    json: ?[]const u8,
};

const CellMetricsResult = struct { cell_px_w: u32, cell_px_h: u32 };

const ImageBgJson = struct { handle: core.ImageHandle, offset_x: u32, offset_y: u32 };
const IconBgJson = struct { handle: core.ImageHandle, scale: []const u8, h_align: []const u8, v_align: []const u8, max_w: ?u32 = null, max_h: ?u32 = null };

/// One flattened cell in a `get_cells` response, row-major starting at
/// (0,0). Exactly one of `bg`/`bg_image`/`bg_icon` is non-null, per
/// `core.Background`'s tagged union — see decisions.md's Cell section.
const CellJson = struct {
    g: []const u8,
    fg: ColorJson,
    bg: ?ColorJson,
    bg_image: ?ImageBgJson = null,
    bg_icon: ?IconBgJson = null,
    /// Just the id, not the resolved JSON -- same "handle, not content"
    /// treatment `bg_image`/`bg_icon` already give image/icon handles.
    /// `get_metadata` resolves an id to its actual content.
    metadata_id: ?core.MetadataHandle = null,
};

const CellsResult = struct {
    cols: usize,
    rows: usize,
    revision: u64,
    cells: []const CellJson,
};

const PxJson = struct { x: f32, y: f32 };
const CellPosJson = struct { row: usize, col: usize };

const ReportKeyParams = struct {
    key: []const u8,
    pressed: bool,
};

const ReportMouseButtonParams = struct {
    button: []const u8,
    pressed: bool,
    px: PxJson,
    cell: CellPosJson,
};

const ReportMouseMoveParams = struct {
    px: PxJson,
    cell: CellPosJson,
};

const SubscribeParams = struct {
    events: []const []const u8,
};

const SubscribeResult = struct {
    subscribed: []const []const u8,
};

const ImageInfoParams = struct { handle: core.ImageHandle };
const ImageInfoResult = struct { width: u32, height: u32 };
const LoadImageResult = struct { handle: core.ImageHandle };

/// `row`/`col` are optional, same as `write_text`'s documented (if not
/// yet wired in there) convention: omitted means "at the layer's
/// cursor" -- see `handleDrawImage`/`resolveAnchor`.
const DrawImageParams = struct {
    layer: ?core.LayerHandle = null,
    handle: core.ImageHandle,
    row: ?usize = null,
    col: ?usize = null,
    row_span: usize,
    col_span: usize,
};

const TagMetadataParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize,
    col: usize,
    /// Unlike `write_text`/`draw_icon`'s optional `metadata_id`, required
    /// here -- there'd be no point to a `tag_metadata` call that tags
    /// with nothing; a client wanting to *clear* a cell's tag can send
    /// `write_text`/`draw_icon` with `metadata_id` omitted instead, same
    /// as it already would to change what's drawn there anyway.
    metadata_id: core.MetadataHandle,
};

const DrawIconParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    name: []const u8,
    /// "fit" (default), "natural", or "stretch" -- see `core.IconScale`.
    scale: ?[]const u8 = null,
    /// "start"/"center" (default)/"end" -- see `core.HAlign`/`core.VAlign`.
    h_align: ?[]const u8 = null,
    v_align: ?[]const u8 = null,
    /// Only consulted when `scale == "natural"` -- see `core.IconBg`.
    max_w: ?u32 = null,
    max_h: ?u32 = null,
    /// See `core.Cell.metadata_id`'s doc comment.
    metadata_id: ?core.MetadataHandle = null,
    /// `false` (default): draws into `Cell.style.bg`, replacing whatever
    /// background was there, same as always. `true`: draws into
    /// `Cell.fg_icon` instead -- see that field's doc comment -- so it
    /// composites over an existing background (e.g. a `draw_box` fill)
    /// rather than replacing it.
    foreground: bool = false,
};

/// Parses `draw_icon`'s `scale`/`h_align`/`v_align` wire strings against
/// their `core` enums. `null` (the field omitted) means `default`.
fn parseIconOption(comptime E: type, value: ?[]const u8, default: E) !E {
    const s = value orelse return default;
    return std.meta.stringToEnum(E, s) orelse DispatchError.InvalidIconOption;
}

const DrawBoxParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    rows: usize,
    cols: usize,
    style: []const u8,
    /// "tile" (default) or "stretch" -- see `core.Layer.BoxMode`.
    mode: ?[]const u8 = null,
};

// ─── Table ───────────────────────────────────────────────────────────────
//
// See core.zig's Table section for the object model. Every message here
// (`create_table`/`destroy_table`/`table_set_rows`/`table_set_sort`/
// `table_set_style`/`table_get_state`) takes a required `table` handle
// (except `create_table`, which returns one) alongside the usual optional
// `layer` -- a table's handle alone doesn't say which layer it's on
// (unlike a layer handle, which is globally meaningful), since it's
// stored in that layer's own `tables` map.

fn colorFromJson(c: ColorJson) core.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

fn colorToJson(c: core.Color) ColorJson {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// Parses a table-related wire string against enum `E` -- same shape
/// `parseIconOption` already has for `draw_icon`'s `scale`/`h_align`/
/// `v_align`, split out under its own error (`InvalidTableOption` rather
/// than `InvalidIconOption`) since a bad `column.kind`/`h_align` or
/// `table_set_sort`'s `direction` isn't an icon problem.
fn parseTableOption(comptime E: type, value: ?[]const u8, default: E) !E {
    const s = value orelse return default;
    return std.meta.stringToEnum(E, s) orelse DispatchError.InvalidTableOption;
}

const ColumnJson = struct {
    name: []const u8,
    /// "text" (default) or "number" -- see `core.ColumnKind`.
    kind: ?[]const u8 = null,
    sortable: bool = false,
    width: usize,
    min_width: usize = 1,
    /// "start" (default), "center", or "end".
    h_align: ?[]const u8 = null,
};

/// Shared by `create_table`'s `style` and `table_set_style`'s -- and
/// reused as the output shape `table_get_state`'s `style` field reports
/// back, since the wire and read-back shapes are identical.
const TableStyleJson = struct {
    borders: bool = true,
    header_separator: bool = true,
    box_style: ?[]const u8 = null,
    alt_row_bg: ?ColorJson = null,
    header_fg: ?ColorJson = null,
    header_bg: ?ColorJson = null,
    row_height: usize = 1,
};

const CreateTableParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    columns: []const ColumnJson,
    style: TableStyleJson = .{},
};

const CreateTableResult = struct { handle: core.TableHandle };

const DestroyTableParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
};

/// One row's cell, as sent to `table_set_rows`. `sort_key` (see
/// `core.SortKey`'s doc comment) is left as a raw `std.json.Value` rather
/// than a typed field, since it's naturally either a JSON number or a
/// JSON string depending on the column -- no wrapper object needed to
/// disambiguate; a number parses as `.number`, a string as `.text`,
/// anything else (or the field omitted) falls back to a copy of
/// `display`, same as a column with no explicit sort key at all.
const TableCellJson = struct {
    display: []const u8,
    sort_key: ?std.json.Value = null,
    /// An icon-registry name, resolved the same way `draw_icon`'s `name`
    /// already is (`Context.iconHandle`) -- see `buildTableCell`.
    icon: ?[]const u8 = null,
    fg: ?ColorJson = null,
    metadata_id: ?core.MetadataHandle = null,
};

const TableSetRowsParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    rows: []const []const TableCellJson,
};

const TableSetSortParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    column: ?usize = null,
    /// "none" (default), "ascending", or "descending".
    direction: ?[]const u8 = null,
};

const TableSetStyleParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    style: TableStyleJson,
};

const TableGetStateParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
};

const ColumnStateJson = struct {
    name: []const u8,
    kind: []const u8,
    sortable: bool,
    width: usize,
    min_width: usize,
    h_align: []const u8,
};

const TableStateResult = struct {
    columns: []const ColumnStateJson,
    row_count: usize,
    sort_column: ?usize,
    sort_direction: []const u8,
    style: TableStyleJson,
    revision: u64,
};

/// `rows`/`cols` are optional: omitted means "the rest of the layer from
/// `row`/`col`", so a bare `clear()` (every field defaulted) wipes the
/// whole layer -- see `handleClear`.
const ClearParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize = 0,
    col: usize = 0,
    rows: ?usize = null,
    cols: ?usize = null,
};

/// The `load_image` request's JSON header, peeked out of a frame body
/// before the binary side-channel payload it declares (`bytes` raw bytes,
/// following directly on the wire) can be read — see `peekLoadImage` and
/// wire.zig's `readRaw`. `id` is copied by value straight out of the
/// envelope's arena: safe only because `Client` always sends integer
/// request ids (never a string, which would need its own copy) — see
/// `Client.request`'s `next_id: i64`.
pub const LoadImageHeader = struct {
    id: std.json.Value,
    bytes: usize,
};

const InputStateResult = struct {
    keys_down: []const []const u8,
    mouse_buttons_down: []const []const u8,
    cursor_px: PxJson,
    cursor_cell: CellPosJson,
};

/// Which input event categories a connection has opted into (see
/// decisions.md's Input model: subscription is opt-in per event type,
/// X11 event-mask precedent). Set via the `subscribe` request; consulted
/// by server.zig when fanning out a `Broadcast` from `HandleResult` to
/// other connections.
pub const Subscriptions = struct {
    key: bool = false,
    mouse_button: bool = false,

    pub fn has(self: Subscriptions, event: []const u8) bool {
        if (std.mem.eql(u8, event, "key")) return self.key;
        if (std.mem.eql(u8, event, "mouse_button")) return self.mouse_button;
        return false;
    }

    fn setFromEvents(events: []const []const u8) Subscriptions {
        var s: Subscriptions = .{};
        for (events) |e| {
            if (std.mem.eql(u8, e, "key")) s.key = true;
            if (std.mem.eql(u8, e, "mouse_button")) s.mouse_button = true;
        }
        return s;
    }
};

/// An owned notification body (caller frees with the same allocator
/// passed to `handle`) to fan out to every *other* connection subscribed
/// to `event`. `handle`'s caller (server.zig) owns actually doing that
/// fan-out; `Dispatcher` itself has no knowledge of other connections, to
/// keep it headless-testable -- see decisions.md's headless-first
/// architecture note.
pub const Broadcast = struct {
    event: []const u8,
    body: []u8,
};

pub const HandleResult = struct {
    /// Owned response body for a request, freed by the caller. Null for a
    /// notification (no response) or when nothing changed worth
    /// broadcasting.
    response: ?[]u8 = null,
    broadcast: ?Broadcast = null,
};

/// Peeks at a decoded frame body to see whether it's a `load_image`
/// request — if so, the caller must read `bytes` raw bytes directly off
/// the wire next, before normal frame processing can continue (the binary
/// side-channel: a JSON header frame declares a byte count, then that many
/// raw bytes follow directly on the wire, not wrapped in `Content-Length`
/// framing — see decisions.md's Transport & Wire Format). Returns null for
/// every other message, which the caller should route to `handle` as
/// usual. Module-level (not a `Dispatcher` method) since it needs no
/// `Context` access — it's pure parsing, done before dispatch.
pub fn peekLoadImage(alloc: std.mem.Allocator, body: []const u8) !?LoadImageHeader {
    const parsed = try std.json.parseFromSlice(Envelope, alloc, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.method, "load_image")) return null;
    const id = parsed.value.id orelse return DispatchError.NotARequest;

    const Params = struct { bytes: usize };
    const p = try std.json.parseFromValue(Params, alloc, parsed.value.params, .{
        .ignore_unknown_fields = true,
    });
    defer p.deinit();

    return .{ .id = id, .bytes = p.value.bytes };
}

/// Peeks at a decoded frame body to determine whether it's a notification
/// (no `id`) rather than a request. Used by server.zig to decide whether a
/// `Dispatcher.handle` error should just be logged or propagated: a
/// notification has no response channel to report an error on anyway (per
/// JSON-RPC, that's a server-side log line, not a wire message -- see
/// decisions.md's latent-robustness-gap note), so severing the whole
/// connection over e.g. one `draw_icon` naming an unregistered icon would
/// be a disproportionate failure mode. A request needs *some* response;
/// until real JSON-RPC error responses land (roadmap.md's Milestone 0),
/// severing the connection is the least-bad fallback there rather than
/// leaving the client's request hanging forever with no reply.
pub fn isNotification(alloc: std.mem.Allocator, body: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(Envelope, alloc, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value.id == null;
}

pub const Dispatcher = struct {
    ctx: *core.Context,
    /// This connection's current subscriptions; see `Subscriptions`. Not
    /// persisted anywhere else -- server.zig mirrors it onto its own
    /// per-connection record after each `handle` call so the fan-out
    /// logic can consult it without this type knowing about connections.
    subscriptions: Subscriptions = .{},

    pub fn init(ctx: *core.Context) Dispatcher {
        return .{ .ctx = ctx };
    }

    /// Handles one decoded frame body. See `HandleResult`.
    pub fn handle(self: *Dispatcher, alloc: std.mem.Allocator, body: []const u8) !HandleResult {
        const parsed = try std.json.parseFromSlice(Envelope, alloc, body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const envelope = parsed.value;

        if (std.mem.eql(u8, envelope.method, "write_text")) {
            try self.handleWriteText(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "insert_cells")) {
            try self.handleInsertCells(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "delete_cells")) {
            try self.handleDeleteCells(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "set_property")) {
            try self.handleSetProperty(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "get_property")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleGetProperty(alloc, id, envelope.params) };
        } else if (std.mem.eql(u8, envelope.method, "get_cells")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleGetCells(alloc, id, envelope.params) };
        } else if (std.mem.eql(u8, envelope.method, "create_layer")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleCreateLayer(alloc, id, envelope.params) };
        } else if (std.mem.eql(u8, envelope.method, "destroy_layer")) {
            try self.handleDestroyLayer(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "report_key")) {
            return try self.handleReportKey(alloc, envelope.params);
        } else if (std.mem.eql(u8, envelope.method, "report_mouse_button")) {
            return try self.handleReportMouseButton(alloc, envelope.params);
        } else if (std.mem.eql(u8, envelope.method, "report_mouse_move")) {
            try self.handleReportMouseMove(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "subscribe")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleSubscribe(alloc, id, envelope.params) };
        } else if (std.mem.eql(u8, envelope.method, "get_input_state")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleGetInputState(alloc, id) };
        } else if (std.mem.eql(u8, envelope.method, "get_image_info")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleGetImageInfo(alloc, id, envelope.params) };
        } else if (std.mem.eql(u8, envelope.method, "draw_image")) {
            try self.handleDrawImage(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "draw_icon")) {
            try self.handleDrawIcon(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "tag_metadata")) {
            try self.handleTagMetadata(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "draw_box")) {
            try self.handleDrawBox(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "clear")) {
            try self.handleClear(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "get_cell_metrics")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleGetCellMetrics(alloc, id) };
        } else if (std.mem.eql(u8, envelope.method, "create_metadata")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleCreateMetadata(alloc, id, envelope.params) };
        } else if (std.mem.eql(u8, envelope.method, "destroy_metadata")) {
            try self.handleDestroyMetadata(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "get_metadata")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleGetMetadata(alloc, id, envelope.params) };
        } else if (std.mem.eql(u8, envelope.method, "create_table")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleCreateTable(alloc, id, envelope.params) };
        } else if (std.mem.eql(u8, envelope.method, "destroy_table")) {
            try self.handleDestroyTable(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "table_set_rows")) {
            try self.handleTableSetRows(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "table_set_sort")) {
            try self.handleTableSetSort(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "table_set_style")) {
            try self.handleTableSetStyle(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "table_get_state")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleTableGetState(alloc, id, envelope.params) };
        }
        return DispatchError.UnknownMethod;
    }

    /// Handles the `load_image` request's JSON header once its binary
    /// payload has already been read off the wire by the caller (see
    /// server.zig's `serveConnection`, which special-cases this method
    /// instead of routing it through `handle` — the payload isn't a normal
    /// frame `handle` can see). Stores `raw_bytes` and returns the response
    /// frame for `hdr.id`.
    pub fn handleLoadImage(self: *Dispatcher, alloc: std.mem.Allocator, hdr: LoadImageHeader, raw_bytes: []const u8) ![]u8 {
        const image_handle = try self.ctx.loadImage(raw_bytes);
        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: LoadImageResult,
        };
        const response: Response = .{ .id = hdr.id, .result = .{ .handle = image_handle } };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    /// Resolves a wire-level `layer` field (omitted means the root layer,
    /// same convention `resolveAnchor` already uses for `row`/`col`) to
    /// its `Layer` -- shared by every layer-scoped handler below.
    fn resolveLayer(self: *Dispatcher, layer: ?core.LayerHandle) !*core.Layer {
        return self.ctx.layerPtr(layer) orelse DispatchError.UnknownLayer;
    }

    /// Validates an optional `metadata_id` param against `Context.metadata`
    /// before it's stored on a cell (`write_text`/`draw_icon`), the same
    /// "fail loud on a bad handle at the point of use" treatment
    /// `UnknownImage`/`UnknownIcon`/`UnknownLayer` already get -- catches a
    /// typo'd or already-`destroy_metadata`'d id immediately rather than
    /// silently tagging a cell with a dangling reference. `null` (the
    /// field omitted) passes through untouched.
    fn resolveMetadata(self: *Dispatcher, id: ?core.MetadataHandle) !?core.MetadataHandle {
        if (id) |m| {
            if (self.ctx.metadataJson(m) == null) return DispatchError.UnknownMetadata;
        }
        return id;
    }

    fn handleWriteText(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(WriteTextParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const fg: core.Color = if (p.fg) |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a } else core.default_style.fg;
        const bg: ?core.Background = if (p.transparent_bg)
            null
        else if (p.bg) |c|
            .{ .color = .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a } }
        else
            core.default_style.bg;
        const metadata_id = try self.resolveMetadata(p.metadata_id);
        try layer.writeTextTagged(p.text, fg, bg, metadata_id);
    }

    fn handleInsertCells(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(CellCountParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        layer.insertCells(parsed.value.count);
    }

    fn handleDeleteCells(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(CellCountParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        layer.deleteCells(parsed.value.count);
    }

    fn handleSetProperty(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(PropertyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        if (std.mem.eql(u8, p.property, "cursor")) {
            layer.setProperty(.{ .cursor = .{ .row = p.row, .col = p.col } });
        } else if (std.mem.eql(u8, p.property, "position")) {
            layer.setProperty(.{ .position = .{ .x = p.x, .y = p.y } });
        } else {
            return DispatchError.UnknownProperty;
        }
    }

    fn handleGetProperty(
        self: *Dispatcher,
        alloc: std.mem.Allocator,
        id: std.json.Value,
        params_value: std.json.Value,
    ) ![]u8 {
        const parsed = try std.json.parseFromValue(PropertyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        if (std.mem.eql(u8, p.property, "cursor")) {
            const cursor = layer.getProperty(.cursor).cursor;
            const Response = struct {
                jsonrpc: []const u8 = "2.0",
                id: std.json.Value,
                result: CursorResult,
            };
            const response: Response = .{ .id = id, .result = .{ .row = cursor.row, .col = cursor.col } };
            return try std.json.Stringify.valueAlloc(alloc, response, .{});
        } else if (std.mem.eql(u8, p.property, "revision")) {
            const revision = layer.getProperty(.revision).revision;
            const Response = struct {
                jsonrpc: []const u8 = "2.0",
                id: std.json.Value,
                result: RevisionResult,
            };
            const response: Response = .{ .id = id, .result = .{ .revision = revision } };
            return try std.json.Stringify.valueAlloc(alloc, response, .{});
        } else if (std.mem.eql(u8, p.property, "position")) {
            const pos = layer.getProperty(.position).position;
            const Response = struct {
                jsonrpc: []const u8 = "2.0",
                id: std.json.Value,
                result: PositionResult,
            };
            const response: Response = .{ .id = id, .result = .{ .x = pos.x, .y = pos.y } };
            return try std.json.Stringify.valueAlloc(alloc, response, .{});
        }
        return DispatchError.UnknownProperty;
    }

    /// `create_layer`: allocates a fresh layer parented to the root (see
    /// `Context.createLayer`) and returns its handle.
    fn handleCreateLayer(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(CreateLayerParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const layer_handle = try self.ctx.createLayer(p.width, p.height, p.scrollback_rows);
        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: CreateLayerResult,
        };
        const response: Response = .{ .id = id, .result = .{ .handle = layer_handle } };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    /// `destroy_layer`: frees a layer and drops it from compositing (see
    /// `Context.destroyLayer`). Errors (an unknown handle, or the root's)
    /// surface as `DispatchError.UnknownLayer` via `core.LayerError`'s own
    /// single member.
    fn handleDestroyLayer(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DestroyLayerParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.destroyLayer(parsed.value.layer) catch return DispatchError.UnknownLayer;
    }

    /// `create_metadata`: stores `json` verbatim (see `Context.createMetadata`
    /// -- the server never parses it, just stores/returns it) and returns a
    /// fresh handle a later `write_text`/`draw_icon`/`destroy_metadata` can
    /// reference.
    fn handleCreateMetadata(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(CreateMetadataParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const metadata_handle = try self.ctx.createMetadata(parsed.value.json);
        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: CreateMetadataResult,
        };
        const response: Response = .{ .id = id, .result = .{ .handle = metadata_handle } };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    /// `destroy_metadata`: frees `id`'s stored JSON (see
    /// `Context.destroyMetadata`'s doc comment on why a cell still tagged
    /// with `id` afterward isn't this call's problem -- there's no
    /// reference counting yet). Errors on an unknown id, same treatment
    /// `destroy_layer` gives an unknown layer handle.
    fn handleDestroyMetadata(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DestroyMetadataParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.destroyMetadata(parsed.value.id) catch return DispatchError.UnknownMetadata;
    }

    /// `get_metadata`: resolves `(row, col)` on `layer` (root when omitted)
    /// to a cell and reports its `metadata_id` plus that id's stored JSON
    /// -- see `GetMetadataResult`'s doc comment for how those two can
    /// diverge (a dangling id). Unlike `draw_icon`/`draw_image`, `row`/
    /// `col` are required rather than cursor-defaulted: this is a targeted
    /// lookup (e.g. resolving whatever cell a mouse click landed on), not
    /// a draw at "wherever the cursor currently is".
    fn handleGetMetadata(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(GetMetadataParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const metadata_id = if (p.row < layer.height and p.col < layer.width)
            layer.cell(p.row, p.col).metadata_id
        else
            null;
        const json = if (metadata_id) |m| self.ctx.metadataJson(m) else null;

        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: GetMetadataResult,
        };
        const response: Response = .{ .id = id, .result = .{ .id = metadata_id, .json = json } };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    /// Returns a full row-major snapshot of the given layer's (default:
    /// root's) visible viewport, plus its current revision -- the
    /// read-back path decisions.md flagged as not yet exposed over the
    /// wire.
    fn handleGetCells(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(GetCellsParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        const cells = try alloc.alloc(CellJson, layer.width * layer.height);
        defer alloc.free(cells);

        var row: usize = 0;
        while (row < layer.height) : (row += 1) {
            var col: usize = 0;
            while (col < layer.width) : (col += 1) {
                const cell = layer.cell(row, col);
                const bg: ?ColorJson = switch (cell.style.bg) {
                    .color => |bgc| .{ .r = bgc.r, .g = bgc.g, .b = bgc.b, .a = bgc.a },
                    .image, .icon => null,
                };
                const bg_image: ?ImageBgJson = switch (cell.style.bg) {
                    .image => |img| .{ .handle = img.handle, .offset_x = img.offset_x, .offset_y = img.offset_y },
                    .color, .icon => null,
                };
                const bg_icon: ?IconBgJson = switch (cell.style.bg) {
                    .icon => |icon| .{
                        .handle = icon.handle,
                        .scale = @tagName(icon.scale),
                        .h_align = @tagName(icon.h_align),
                        .v_align = @tagName(icon.v_align),
                        .max_w = icon.max_w,
                        .max_h = icon.max_h,
                    },
                    .color, .image => null,
                };
                cells[row * layer.width + col] = .{
                    .g = cell.grapheme(),
                    .fg = .{ .r = cell.style.fg.r, .g = cell.style.fg.g, .b = cell.style.fg.b, .a = cell.style.fg.a },
                    .bg = bg,
                    .bg_image = bg_image,
                    .bg_icon = bg_icon,
                    .metadata_id = cell.metadata_id,
                };
            }
        }

        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: CellsResult,
        };
        const response: Response = .{
            .id = id,
            .result = .{ .cols = layer.width, .rows = layer.height, .revision = layer.revision, .cells = cells },
        };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    /// A notification from an input-capturing client (glyphwire-host, in
    /// practice -- nothing here restricts it to a particular sender, see
    /// decisions.md's stance on there being no auth model yet). Updates
    /// the authoritative down-set and, if the key's state actually
    /// changed, returns a `key_down`/`key_up` broadcast for other
    /// connections subscribed to `"key"`.
    fn handleReportKey(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(ReportKeyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const changed = try self.ctx.input.setKey(p.key, p.pressed);
        if (!changed) return .{};

        const Notification = struct {
            jsonrpc: []const u8 = "2.0",
            method: []const u8,
            params: struct { key: []const u8 },
        };
        const notification: Notification = .{
            .method = if (p.pressed) "key_down" else "key_up",
            .params = .{ .key = p.key },
        };
        const notif_body = try std.json.Stringify.valueAlloc(alloc, notification, .{});
        return .{ .broadcast = .{ .event = "key", .body = notif_body } };
    }

    fn handleReportMouseButton(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(ReportMouseButtonParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        self.ctx.input.cursor_px = .{ .x = p.px.x, .y = p.px.y };
        self.ctx.input.cursor_cell = .{ .row = p.cell.row, .col = p.cell.col };
        const changed = try self.ctx.input.setMouseButton(p.button, p.pressed);
        if (!changed) return .{};

        const Notification = struct {
            jsonrpc: []const u8 = "2.0",
            method: []const u8 = "mouse_button",
            params: struct { button: []const u8, pressed: bool, px: PxJson, cell: CellPosJson },
        };
        const notification: Notification = .{
            .params = .{ .button = p.button, .pressed = p.pressed, .px = p.px, .cell = p.cell },
        };
        const notif_body = try std.json.Stringify.valueAlloc(alloc, notification, .{});
        return .{ .broadcast = .{ .event = "mouse_button", .body = notif_body } };
    }

    /// Updates the authoritative cursor position only -- no broadcast.
    /// A live `mouse_move` notification stream isn't built yet (not asked
    /// for); this just keeps `get_input_state`'s cursor fields current.
    fn handleReportMouseMove(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(ReportMouseMoveParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        self.ctx.input.cursor_px = .{ .x = p.px.x, .y = p.px.y };
        self.ctx.input.cursor_cell = .{ .row = p.cell.row, .col = p.cell.col };
    }

    fn handleSubscribe(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(SubscribeParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.subscriptions = Subscriptions.setFromEvents(parsed.value.events);

        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: SubscribeResult,
        };
        const response: Response = .{ .id = id, .result = .{ .subscribed = parsed.value.events } };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    fn handleGetInputState(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value) ![]u8 {
        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(alloc);
        var kit = self.ctx.input.keys_down.keyIterator();
        while (kit.next()) |k| try keys.append(alloc, k.*);

        var buttons = std.ArrayList([]const u8).empty;
        defer buttons.deinit(alloc);
        var bit = self.ctx.input.mouse_buttons_down.keyIterator();
        while (bit.next()) |k| try buttons.append(alloc, k.*);

        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: InputStateResult,
        };
        const response: Response = .{
            .id = id,
            .result = .{
                .keys_down = keys.items,
                .mouse_buttons_down = buttons.items,
                .cursor_px = .{ .x = self.ctx.input.cursor_px.x, .y = self.ctx.input.cursor_px.y },
                .cursor_cell = .{ .row = self.ctx.input.cursor_cell.row, .col = self.ctx.input.cursor_cell.col },
            },
        };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    fn handleGetImageInfo(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(ImageInfoParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const info = self.ctx.imageInfo(parsed.value.handle) orelse return DispatchError.UnknownImage;
        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: ImageInfoResult,
        };
        const response: Response = .{ .id = id, .result = .{ .width = info.width, .height = info.height } };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    /// Resolves an optional `row`/`col` pair against `layer`'s current
    /// cursor -- shared by `draw_image`/`draw_icon`/`draw_box`, matching
    /// `write_text`'s documented (if not yet wired in there) convention:
    /// omitted means "at the cursor," same as it would for text. Doesn't
    /// itself scroll or otherwise validate -- `Layer.resolveRow` (called
    /// downstream by `drawImage`/`drawIcon`/`drawBox` themselves) still
    /// handles a resulting row that's out of bounds.
    fn resolveAnchor(layer: *const core.Layer, row: ?usize, col: ?usize) struct { row: usize, col: usize } {
        return .{ .row = row orelse layer.cursor.row, .col = col orelse layer.cursor.col };
    }

    fn handleDrawImage(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawImageParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const info = self.ctx.imageInfo(p.handle) orelse return DispatchError.UnknownImage;
        const anchor = resolveAnchor(layer, p.row, p.col);
        layer.drawImage(
            p.handle,
            anchor.row,
            anchor.col,
            p.row_span,
            p.col_span,
            info.width,
            info.height,
            self.ctx.cell_px_w,
            self.ctx.cell_px_h,
        );
    }

    /// `draw_icon`: resolves `name` against the icon catalog
    /// (`Context.iconHandle`, populated from `default_icon_manifest` by
    /// `glyphwire-host`) and draws it into exactly one cell -- an icon is
    /// scoped to a single cell for now, per decisions.md's Icon section.
    /// `Layer.drawIcon` just needs the handle -- no dimensions/cell
    /// metrics to look up, unlike `handleDrawImage`, since an icon always
    /// scales the whole source image into the whole cell.
    fn handleDrawIcon(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawIconParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const icon_handle = self.ctx.iconHandle(p.name) orelse return DispatchError.UnknownIcon;
        const anchor = resolveAnchor(layer, p.row, p.col);
        const metadata_id = try self.resolveMetadata(p.metadata_id);
        const opts: core.Layer.IconDrawOpts = .{
            .scale = try parseIconOption(core.IconScale, p.scale, .fit),
            .h_align = try parseIconOption(core.HAlign, p.h_align, .center),
            .v_align = try parseIconOption(core.VAlign, p.v_align, .center),
            .max_w = p.max_w,
            .max_h = p.max_h,
            .metadata_id = metadata_id,
        };
        if (p.foreground) {
            layer.drawIconOver(icon_handle, anchor.row, anchor.col, opts);
        } else {
            layer.drawIcon(icon_handle, anchor.row, anchor.col, opts);
        }
    }

    /// `tag_metadata`: sets exactly one cell's `metadata_id`, nothing else
    /// -- see `Layer.tagMetadata`'s doc comment. `metadata_id` is
    /// validated the same way `write_text`/`draw_icon`'s is
    /// (`resolveMetadata`), erroring `UnknownMetadata` on a bad handle.
    fn handleTagMetadata(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(TagMetadataParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const metadata_id = try self.resolveMetadata(p.metadata_id);
        layer.tagMetadata(p.row, p.col, metadata_id);
    }

    /// `draw_box`: resolves `style`'s 9 pieces against the icon catalog
    /// (`"{style}-tl"`, `"{style}-t"`, ... `"{style}-br"`/`"{style}-fill"`
    /// — see `core.default_box_manifest`) and draws them via
    /// `Layer.drawBox`. Errors (missing name, or a registered name that
    /// somehow isn't in `ctx.images`) abort before drawing anything,
    /// rather than leaving a box half-drawn with some pieces missing.
    /// `mode` ("tile"/"stretch", default "tile") selects `core.Layer.BoxMode`
    /// -- reuses the same `InvalidIconOption` error `scale`/`h_align`/
    /// `v_align` already get for a bad value.
    fn handleDrawBox(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawBoxParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const piece_names = [_][]const u8{ "tl", "t", "tr", "l", "fill", "r", "bl", "b", "br" };
        var pieces: [piece_names.len]core.ImageHandle = undefined;

        var name_buf: [64]u8 = undefined;
        for (piece_names, 0..) |piece, i| {
            const name = try std.fmt.bufPrint(&name_buf, "{s}-{s}", .{ p.style, piece });
            pieces[i] = self.ctx.iconHandle(name) orelse return DispatchError.UnknownIcon;
        }

        const tiles: core.Layer.BoxTiles = .{
            .tl = pieces[0],
            .t = pieces[1],
            .tr = pieces[2],
            .l = pieces[3],
            .fill = pieces[4],
            .r = pieces[5],
            .bl = pieces[6],
            .b = pieces[7],
            .br = pieces[8],
        };
        const mode = try parseIconOption(core.Layer.BoxMode, p.mode, .tile);
        const anchor = resolveAnchor(layer, p.row, p.col);
        layer.drawBox(tiles, mode, anchor.row, anchor.col, p.rows, p.cols);
    }

    /// `clear`: resets a region of the given layer's (default: root's)
    /// cells to blank. `rows`/`cols` default to "the rest of the layer
    /// from `row`/`col`" (clamped to 0 if `row`/`col` is already past the
    /// edge), so an all-defaulted `clear()` wipes everything.
    fn handleClear(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(ClearParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const layer = try self.resolveLayer(p.layer);
        const rows = p.rows orelse (if (p.row < layer.height) layer.height - p.row else 0);
        const cols = p.cols orelse (if (p.col < layer.width) layer.width - p.col else 0);
        layer.clear(p.row, p.col, rows, cols);
    }

    /// A client-side convenience for aspect-ratio-aware placement
    /// (decisions.md: "the client's job, not the server's") — lets a
    /// client compute how many cells an image needs without hardcoding the
    /// session's cell pixel metrics, which otherwise live only in
    /// `Context.cell_px_w`/`cell_px_h` and glyphwire-host's matching
    /// constants.
    fn handleGetCellMetrics(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value) ![]u8 {
        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: CellMetricsResult,
        };
        const response: Response = .{
            .id = id,
            .result = .{ .cell_px_w = self.ctx.cell_px_w, .cell_px_h = self.ctx.cell_px_h },
        };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    /// Builds an owned `core.TableStyle` from wire JSON -- `box_style`
    /// always ends up an owned copy (defaulted to a duped `"box"` when
    /// omitted) so `TableStyle.deinit` can always safely free it. Shared
    /// by `handleCreateTable` and `handleTableSetStyle`.
    fn resolveTableStyle(alloc: std.mem.Allocator, s: TableStyleJson) !core.TableStyle {
        const box_style = try alloc.dupe(u8, s.box_style orelse "box");
        return .{
            .borders = s.borders,
            .header_separator = s.header_separator,
            .box_style = box_style,
            .alt_row_bg = if (s.alt_row_bg) |c| colorFromJson(c) else null,
            .header_fg = if (s.header_fg) |c| colorFromJson(c) else null,
            .header_bg = if (s.header_bg) |c| colorFromJson(c) else null,
            .row_height = @max(s.row_height, 1),
        };
    }

    /// `create_table`: builds the table's columns and style, then
    /// `Context.createTable` stores it on the resolved layer (root when
    /// omitted) at the resolved anchor (cursor-defaulted, same convention
    /// `draw_box`/`draw_icon` already use). No rows yet -- nothing to
    /// paint until `table_set_rows`.
    fn handleCreateTable(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(CreateTableParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const anchor = resolveAnchor(layer, p.row, p.col);

        const talloc = self.ctx.alloc;
        const columns = try talloc.alloc(core.TableColumn, p.columns.len);
        var built: usize = 0;
        errdefer {
            for (columns[0..built]) |c| c.deinit(talloc);
            talloc.free(columns);
        }
        for (p.columns, 0..) |cj, i| {
            columns[i] = .{
                .name = try talloc.dupe(u8, cj.name),
                .kind = try parseTableOption(core.ColumnKind, cj.kind, .text),
                .sortable = cj.sortable,
                .width = cj.width,
                .min_width = cj.min_width,
                .h_align = try parseTableOption(core.HAlign, cj.h_align, .start),
            };
            built = i + 1;
        }

        const style = try resolveTableStyle(talloc, p.style);
        const table_handle = try self.ctx.createTable(p.layer, anchor.row, anchor.col, columns, style);

        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: CreateTableResult,
        };
        const response: Response = .{ .id = id, .result = .{ .handle = table_handle } };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }

    /// `destroy_table`: blanks the table's painted region and frees it
    /// (`Context.destroyTable`).
    fn handleDestroyTable(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DestroyTableParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        self.ctx.destroyTable(p.layer, p.table) catch |err| switch (err) {
            error.UnknownLayer => return DispatchError.UnknownLayer,
            error.UnknownTable => return DispatchError.UnknownTable,
            else => return err,
        };
    }

    /// One `table_set_rows` cell: dupes `display`, resolves `sort_key`
    /// (a raw JSON number/string -- see `TableCellJson`'s doc comment,
    /// falling back to a copy of `display` for anything else or when
    /// omitted), resolves `icon`'s name against the icon catalog (erroring
    /// `UnknownIcon` immediately, same "fail loud at the point of use"
    /// treatment `draw_icon`'s `name` already gets), and validates
    /// `metadata_id` the same way `write_text`/`draw_icon`'s already is.
    fn buildTableCell(self: *Dispatcher, alloc: std.mem.Allocator, cj: TableCellJson) !core.TableCell {
        const display = try alloc.dupe(u8, cj.display);
        errdefer alloc.free(display);

        const sort_key: core.SortKey = if (cj.sort_key) |v| switch (v) {
            .integer => |n| .{ .number = @floatFromInt(n) },
            .float => |n| .{ .number = n },
            .string => |s| .{ .text = try alloc.dupe(u8, s) },
            else => .{ .text = try alloc.dupe(u8, cj.display) },
        } else .{ .text = try alloc.dupe(u8, cj.display) };
        errdefer sort_key.deinit(alloc);

        const icon_handle: ?core.ImageHandle = if (cj.icon) |name|
            self.ctx.iconHandle(name) orelse return DispatchError.UnknownIcon
        else
            null;

        const metadata_id = try self.resolveMetadata(cj.metadata_id);

        return .{
            .display = display,
            .sort_key = sort_key,
            .icon = icon_handle,
            .fg = if (cj.fg) |c| colorFromJson(c) else null,
            .metadata_id = metadata_id,
        };
    }

    fn buildTableRow(self: *Dispatcher, alloc: std.mem.Allocator, row_json: []const TableCellJson) !core.TableRow {
        const cells = try alloc.alloc(core.TableCell, row_json.len);
        var built: usize = 0;
        errdefer {
            for (cells[0..built]) |c| c.deinit(alloc);
            alloc.free(cells);
        }
        for (row_json, 0..) |cj, ci| {
            cells[ci] = try self.buildTableCell(alloc, cj);
            built = ci + 1;
        }
        return .{ .cells = cells };
    }

    /// Builds every row `table_set_rows` sent, fully independent of
    /// `core.Table.setRows` (which takes ownership of the result and
    /// handles a shape mismatch itself) -- kept as its own self-contained
    /// `errdefer` scope so a failure partway through building doesn't
    /// leave a dangling `errdefer` active around the later `setRows` call
    /// in `handleTableSetRows`, which already frees `rows` itself on its
    /// own error path.
    fn buildTableRows(self: *Dispatcher, alloc: std.mem.Allocator, rows_json: []const []const TableCellJson) ![]core.TableRow {
        const rows = try alloc.alloc(core.TableRow, rows_json.len);
        var built: usize = 0;
        errdefer {
            for (rows[0..built]) |r| r.deinit(alloc);
            alloc.free(rows);
        }
        for (rows_json, 0..) |row_json, ri| {
            rows[ri] = try self.buildTableRow(alloc, row_json);
            built = ri + 1;
        }
        return rows;
    }

    /// `table_set_rows`: replaces every row, re-sorts per the table's
    /// current sort state, and repaints (`Table.render`) -- see
    /// core.zig's Table section on why this needs no host/main.zig
    /// changes to actually show up.
    fn handleTableSetRows(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(TableSetRowsParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const table = layer.tables.getPtr(p.table) orelse return DispatchError.UnknownTable;

        const rows = try self.buildTableRows(self.ctx.alloc, p.rows);
        table.setRows(rows) catch |err| switch (err) {
            error.TableRowShapeMismatch => return DispatchError.TableRowShapeMismatch,
        };
        try table.render(layer, self.ctx);
    }

    /// `table_set_sort`: `column`/`direction` both defaulted (`null`/
    /// `"none"`) mean "back to insertion order" -- see
    /// `core.Table.sortedIndices`. Repaints immediately, same as
    /// `table_set_rows` -- this is the message a future sort-aware
    /// `glyphwire-shell` click handler would call.
    fn handleTableSetSort(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(TableSetSortParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const table = layer.tables.getPtr(p.table) orelse return DispatchError.UnknownTable;

        const dir = try parseTableOption(core.SortDirection, p.direction, .none);
        table.setSort(p.column, dir);
        try table.render(layer, self.ctx);
    }

    /// `table_set_style`: replaces the table's whole style (e.g. toggling
    /// `alt_row_bg` on/off) and repaints.
    fn handleTableSetStyle(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(TableSetStyleParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const table = layer.tables.getPtr(p.table) orelse return DispatchError.UnknownTable;

        const style = try resolveTableStyle(self.ctx.alloc, p.style);
        table.setStyle(style);
        try table.render(layer, self.ctx);
    }

    /// `table_get_state`: reads back a table's structured config (columns,
    /// sort, style, row count, revision) -- not its rendered cells, which
    /// are already readable through the owning layer's normal `get_cells`
    /// (a table paints into ordinary cells, see core.zig's Table
    /// section), so there's no separate "get rendered table" message.
    /// For a future client that needs to know e.g. which columns are
    /// sortable before deciding what a header click should do.
    fn handleTableGetState(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(TableGetStateParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const table = layer.tables.getPtr(p.table) orelse return DispatchError.UnknownTable;

        const columns = try alloc.alloc(ColumnStateJson, table.columns.len);
        for (table.columns, 0..) |c, i| {
            columns[i] = .{
                .name = c.name,
                .kind = @tagName(c.kind),
                .sortable = c.sortable,
                .width = c.width,
                .min_width = c.min_width,
                .h_align = @tagName(c.h_align),
            };
        }

        const Response = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: TableStateResult,
        };
        const response: Response = .{
            .id = id,
            .result = .{
                .columns = columns,
                .row_count = table.rows.len,
                .sort_column = table.sort_column,
                .sort_direction = @tagName(table.sort_dir),
                .style = .{
                    .borders = table.style.borders,
                    .header_separator = table.style.header_separator,
                    .box_style = table.style.box_style,
                    .alt_row_bg = if (table.style.alt_row_bg) |c| colorToJson(c) else null,
                    .header_fg = if (table.style.header_fg) |c| colorToJson(c) else null,
                    .header_bg = if (table.style.header_bg) |c| colorToJson(c) else null,
                    .row_height = table.style.row_height,
                },
                .revision = table.revision,
            },
        };
        return try std.json.Stringify.valueAlloc(alloc, response, .{});
    }
};
