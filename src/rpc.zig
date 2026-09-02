const std = @import("std");
const protocol = @import("protocol.zig");

/// Tiny JSON-RPC envelope builders shared by the socket path
/// (`dispatch.zig`) and the in-process path (`server.zig`). Not a
/// framework -- each returns one owned, framed-body-ready slice the
/// caller frees with the same `alloc`. The message catalog still lives at
/// the call sites (they pick the method name and hand over a typed result
/// / params value); this only removes the `const Response = struct { ... }`
/// / `Stringify.valueAlloc` boilerplate that was repeated per handler.

/// `{"jsonrpc":"2.0","id":<id>,"result":<result>}` for a request reply.
pub fn response(alloc: std.mem.Allocator, id: std.json.Value, result: anytype) ![]u8 {
    const Envelope = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: @TypeOf(result),
    };
    return std.json.Stringify.valueAlloc(alloc, Envelope{ .id = id, .result = result }, .{});
}

/// `{"jsonrpc":"2.0","method":<method>,"params":<params>}` for a
/// notification (no `id`, no response expected).
pub fn notification(alloc: std.mem.Allocator, method: []const u8, params: anytype) ![]u8 {
    const Envelope = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: @TypeOf(params),
    };
    return std.json.Stringify.valueAlloc(alloc, Envelope{ .method = method, .params = params }, .{});
}

// ─── Input event notification builders ───────────────────────────────────
//
// One definition each for the four server->client input notifications, so
// the socket handlers in `dispatch.zig` and the in-process reporters in
// `server.zig` can't drift on method name or param shape. Parsed back on
// the client by `InputListener.handleNotification` against the same
// `protocol.*Params` types.

/// `key_down` (pressed) or `key_up` (released) for `key`.
pub fn keyNotification(alloc: std.mem.Allocator, key: []const u8, pressed: bool) ![]u8 {
    return notification(alloc, if (pressed) "key_down" else "key_up", protocol.KeyParams{ .key = key });
}

/// `key_down` for an already-held `key` -- a typematic repeat. Same shape
/// as a fresh press; nothing downstream needs to tell them apart (see
/// `Server.reportKeyRepeat`).
pub fn keyRepeatNotification(alloc: std.mem.Allocator, key: []const u8) ![]u8 {
    return notification(alloc, "key_down", protocol.KeyParams{ .key = key });
}

/// `mouse_button` press/release at `px`/`cell`, carrying the click-time
/// scrollback `view_offset`.
pub fn mouseButtonNotification(
    alloc: std.mem.Allocator,
    button: []const u8,
    pressed: bool,
    px: protocol.PxPos,
    cell: protocol.CellPos,
    view_offset: usize,
) ![]u8 {
    return notification(alloc, "mouse_button", protocol.MouseButtonParams{
        .button = button,
        .pressed = pressed,
        .px = px,
        .cell = cell,
        .view_offset = view_offset,
    });
}

/// `scroll` -- the root layer's scrollback view moved to `offset` (of
/// `max` retained rows).
pub fn scrollNotification(alloc: std.mem.Allocator, offset: usize, max: usize) ![]u8 {
    return notification(alloc, "scroll", protocol.ScrollParams{ .offset = offset, .max = max });
}

/// `resize` -- the host window is now `cols` x `rows` cells.
pub fn resizeNotification(alloc: std.mem.Allocator, cols: usize, rows: usize) ![]u8 {
    return notification(alloc, "resize", protocol.ResizeParams{ .cols = cols, .rows = rows });
}
