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

pub const Dispatcher = struct {
    ctx: *core.Context,

    pub fn init(ctx: *core.Context) Dispatcher {
        return .{ .ctx = ctx };
    }

    /// Handles one decoded frame body. Returns an owned JSON response body
    /// (caller frees with `alloc`) for a request, or null for a
    /// notification, which has no response.
    pub fn handle(self: *Dispatcher, alloc: std.mem.Allocator, body: []const u8) !?[]u8 {
        const parsed = try std.json.parseFromSlice(Envelope, alloc, body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const envelope = parsed.value;

        if (std.mem.eql(u8, envelope.method, "write_text")) {
            try self.handleWriteText(alloc, envelope.params);
            return null;
        } else if (std.mem.eql(u8, envelope.method, "set_property")) {
            try self.handleSetProperty(alloc, envelope.params);
            return null;
        } else if (std.mem.eql(u8, envelope.method, "get_property")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return try self.handleGetProperty(alloc, id, envelope.params);
        } else if (std.mem.eql(u8, envelope.method, "get_cells")) {
            const id = envelope.id orelse return DispatchError.NotARequest;
            return try self.handleGetCells(alloc, id);
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
};
