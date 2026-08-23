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
const WriteTextParams = struct {
    text: []const u8,
    fg: ?ColorJson = null,
    bg: ?ColorJson = null,
};

/// Params shared by `insert_cells`/`delete_cells` -- also cursor-implicit
/// like `write_text`, see `WriteTextParams`.
const CellCountParams = struct {
    count: usize,
};

const CursorPropertyParams = struct {
    property: []const u8,
    row: usize = 0,
    col: usize = 0,
};

const GetPropertyParams = struct {
    property: []const u8,
};

const CursorResult = struct { row: usize, col: usize };
const RevisionResult = struct { revision: u64 };

const CellMetricsResult = struct { cell_px_w: u32, cell_px_h: u32 };

const ImageBgJson = struct { handle: core.ImageHandle, offset_x: u32, offset_y: u32 };

/// One flattened cell in a `get_cells` response, row-major starting at
/// (0,0). Exactly one of `bg`/`bg_image` is non-null, per `core.Background`'s
/// tagged union — see decisions.md's Cell section.
const CellJson = struct {
    g: []const u8,
    fg: ColorJson,
    bg: ?ColorJson,
    bg_image: ?ImageBgJson = null,
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

const DrawImageParams = struct {
    handle: core.ImageHandle,
    row: usize,
    col: usize,
    row_span: usize,
    col_span: usize,
};

const DrawIconParams = struct {
    row: usize,
    col: usize,
    name: []const u8,
};

const DrawBoxParams = struct {
    row: usize,
    col: usize,
    rows: usize,
    cols: usize,
    style: []const u8,
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
            return .{ .response = try self.handleGetCells(alloc, id) };
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
        } else if (std.mem.eql(u8, envelope.method, "draw_box")) {
            try self.handleDrawBox(alloc, envelope.params);
            return .{};
        } else if (std.mem.eql(u8, envelope.method, "get_cell_metrics")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return .{ .response = try self.handleGetCellMetrics(alloc, id) };
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

    fn handleWriteText(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(WriteTextParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const style: core.Style = .{
            .fg = if (p.fg) |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a } else core.default_style.fg,
            .bg = if (p.bg) |c| .{ .color = .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a } } else core.default_style.bg,
        };
        try self.ctx.root.writeText(p.text, style);
    }

    fn handleInsertCells(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(CellCountParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.root.insertCells(parsed.value.count);
    }

    fn handleDeleteCells(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(CellCountParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.root.deleteCells(parsed.value.count);
    }

    fn handleSetProperty(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(CursorPropertyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        if (!std.mem.eql(u8, p.property, "cursor")) return DispatchError.UnknownProperty;
        self.ctx.root.setProperty(.{ .cursor = .{ .row = p.row, .col = p.col } });
    }

    fn handleGetProperty(
        self: *Dispatcher,
        alloc: std.mem.Allocator,
        id: std.json.Value,
        params_value: std.json.Value,
    ) ![]u8 {
        const parsed = try std.json.parseFromValue(GetPropertyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        if (std.mem.eql(u8, p.property, "cursor")) {
            const cursor = self.ctx.root.getProperty(.cursor).cursor;
            const Response = struct {
                jsonrpc: []const u8 = "2.0",
                id: std.json.Value,
                result: CursorResult,
            };
            const response: Response = .{ .id = id, .result = .{ .row = cursor.row, .col = cursor.col } };
            return try std.json.Stringify.valueAlloc(alloc, response, .{});
        } else if (std.mem.eql(u8, p.property, "revision")) {
            const revision = self.ctx.root.getProperty(.revision).revision;
            const Response = struct {
                jsonrpc: []const u8 = "2.0",
                id: std.json.Value,
                result: RevisionResult,
            };
            const response: Response = .{ .id = id, .result = .{ .revision = revision } };
            return try std.json.Stringify.valueAlloc(alloc, response, .{});
        }
        return DispatchError.UnknownProperty;
    }

    /// Returns a full row-major snapshot of the root layer's visible
    /// viewport, plus its current revision -- the read-back path
    /// decisions.md flagged as not yet exposed over the wire. No params:
    /// v1 has exactly one layer (the root), so there's nothing to select.
    fn handleGetCells(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value) ![]u8 {
        const layer = &self.ctx.root;
        const cells = try alloc.alloc(CellJson, layer.width * layer.height);
        defer alloc.free(cells);

        var row: usize = 0;
        while (row < layer.height) : (row += 1) {
            var col: usize = 0;
            while (col < layer.width) : (col += 1) {
                const cell = layer.cell(row, col);
                const bg: ?ColorJson = switch (cell.style.bg) {
                    .color => |bgc| .{ .r = bgc.r, .g = bgc.g, .b = bgc.b, .a = bgc.a },
                    .image => null,
                };
                const bg_image: ?ImageBgJson = switch (cell.style.bg) {
                    .color => null,
                    .image => |img| .{ .handle = img.handle, .offset_x = img.offset_x, .offset_y = img.offset_y },
                };
                cells[row * layer.width + col] = .{
                    .g = cell.grapheme(),
                    .fg = .{ .r = cell.style.fg.r, .g = cell.style.fg.g, .b = cell.style.fg.b, .a = cell.style.fg.a },
                    .bg = bg,
                    .bg_image = bg_image,
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

    fn handleDrawImage(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawImageParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const info = self.ctx.imageInfo(p.handle) orelse return DispatchError.UnknownImage;
        self.ctx.root.drawImage(
            p.handle,
            p.row,
            p.col,
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
    /// Reuses `Layer.drawImage` with a 1x1 span rather than a separate
    /// core mechanism, same as `handleDrawImage`.
    fn handleDrawIcon(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawIconParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const icon_handle = self.ctx.iconHandle(p.name) orelse return DispatchError.UnknownIcon;
        const info = self.ctx.imageInfo(icon_handle) orelse return DispatchError.UnknownImage;
        self.ctx.root.drawImage(
            icon_handle,
            p.row,
            p.col,
            1,
            1,
            info.width,
            info.height,
            self.ctx.cell_px_w,
            self.ctx.cell_px_h,
        );
    }

    /// `draw_box`: resolves `style`'s 9 pieces against the icon catalog
    /// (`"{style}-tl"`, `"{style}-t"`, ... `"{style}-br"`/`"{style}-fill"`
    /// — see `core.default_box_manifest`) and draws them via
    /// `Layer.drawBox`. Errors (missing name, or a registered name that
    /// somehow isn't in `ctx.images`) abort before drawing anything,
    /// rather than leaving a box half-drawn with some pieces missing.
    fn handleDrawBox(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawBoxParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const piece_names = [_][]const u8{ "tl", "t", "tr", "l", "fill", "r", "bl", "b", "br" };
        var pieces: [piece_names.len]core.Layer.BoxTile = undefined;

        var name_buf: [64]u8 = undefined;
        for (piece_names, 0..) |piece, i| {
            const name = try std.fmt.bufPrint(&name_buf, "{s}-{s}", .{ p.style, piece });
            const piece_handle = self.ctx.iconHandle(name) orelse return DispatchError.UnknownIcon;
            const info = self.ctx.imageInfo(piece_handle) orelse return DispatchError.UnknownImage;
            pieces[i] = .{ .handle = piece_handle, .width = info.width, .height = info.height };
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
        self.ctx.root.drawBox(tiles, p.row, p.col, p.rows, p.cols);
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
};
