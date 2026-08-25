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

/// One flattened cell in a `get_cells` response, row-major starting at
/// (0,0). `bg` is null for the (currently unbuilt) image-background case —
/// see decisions.md's Cell section.
const CellJson = struct {
    g: []const u8,
    fg: ColorJson,
    bg: ?ColorJson,
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
        }
        return DispatchError.UnknownMethod;
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
                cells[row * layer.width + col] = .{
                    .g = cell.grapheme(),
                    .fg = .{ .r = cell.style.fg.r, .g = cell.style.fg.g, .b = cell.style.fg.b, .a = cell.style.fg.a },
                    .bg = bg,
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
};
