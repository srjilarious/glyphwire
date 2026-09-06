const std = @import("std");
const core = @import("core.zig");
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

/// `text` -- committed text input (`text` is a UTF-8 string of one or
/// more codepoints). Separate from `key_down`; see `protocol.TextParams`.
pub fn textNotification(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    return notification(alloc, "text", protocol.TextParams{ .text = text });
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

/// `mouse_move` -- the pointer moved to a new cell (`px`/`cell`). See
/// `protocol.MouseMoveParams`; broadcast by `Server.reportMouseMove` /
/// `handleReportMouseMove` only on a cell change.
pub fn mouseMoveNotification(alloc: std.mem.Allocator, px: protocol.PxPos, cell: protocol.CellPos) ![]u8 {
    return notification(alloc, "mouse_move", protocol.MouseMoveParams{ .px = px, .cell = cell });
}

/// `scroll` -- the root layer's scrollback view moved to `offset` (of
/// `max` retained rows).
pub fn scrollNotification(alloc: std.mem.Allocator, offset: usize, max: usize) ![]u8 {
    return notification(alloc, "scroll", protocol.ScrollParams{ .offset = offset, .max = max });
}

/// `scroll_offset` -- a layer's viewport moved over its content grid.
/// See `protocol.ScrollOffsetParams`; delivered to `"scroll"`
/// subscribers, same as the root layer's `scroll`.
pub fn scrollOffsetNotification(
    alloc: std.mem.Allocator,
    layer: core.LayerHandle,
    row: usize,
    col: usize,
    max_row: usize,
    max_col: usize,
) ![]u8 {
    return notification(alloc, "scroll_offset", protocol.ScrollOffsetParams{
        .layer = layer,
        .row = row,
        .col = col,
        .max_row = max_row,
        .max_col = max_col,
    });
}

/// `layout` -- the panes whose bounds changed after a split re-layout.
pub fn layoutNotification(alloc: std.mem.Allocator, layers: []const protocol.LayoutBounds) ![]u8 {
    return notification(alloc, "layout", protocol.LayoutParams{ .layers = layers });
}

/// `terminal_reply` -- `bytes` are a terminal query answer a `write_text`
/// produced (see `core.Layer.takeReply`), for a `"terminal"` subscriber
/// to write to the pty master.
pub fn terminalReplyNotification(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return notification(alloc, "terminal_reply", protocol.TerminalReplyParams{ .bytes = bytes });
}

/// `resize` -- the host window is now `cols` x `rows` cells.
pub fn resizeNotification(alloc: std.mem.Allocator, cols: usize, rows: usize) ![]u8 {
    return notification(alloc, "resize", protocol.ResizeParams{ .cols = cols, .rows = rows });
}

/// `context` -- the visible context changed to `context` (its handle),
/// whose root layer is `cols` x `rows`. Sent by `create_context` /
/// `activate_context` / `destroy_context` and by the disconnect-cull
/// auto-restore.
pub fn contextNotification(alloc: std.mem.Allocator, context: core.ContextHandle, cols: usize, rows: usize) ![]u8 {
    return notification(alloc, "context", protocol.ContextParams{ .context = context, .cols = cols, .rows = rows });
}

/// `selection` -- a layer's selection changed (from `set_selection` /
/// `update_selection` / `clear_selection`, or the host's in-process
/// path). `sel` null means the selection was cleared.
pub fn selectionNotification(alloc: std.mem.Allocator, sel: ?core.Selection) ![]u8 {
    const body: protocol.SelectionState = if (sel) |s| .{
        .active = true,
        .anchor = .{ .above = s.anchor.above, .col = s.anchor.col },
        .active_end = .{ .above = s.active.above, .col = s.active.col },
    } else .{ .active = false };
    return notification(alloc, "selection", body);
}

/// `copy_request` -- the user pressed the copy shortcut with nothing
/// selected; a subscriber that owns editable text (glyphwire-shell)
/// should answer with `set_clipboard`. No params.
pub fn copyRequestNotification(alloc: std.mem.Allocator) ![]u8 {
    return notification(alloc, "copy_request", struct {}{});
}

/// `paste` -- committed clipboard text to insert, distinct from the
/// `text` typing stream so a client can treat it differently (e.g. not
/// auto-executing a multi-line paste).
pub fn pasteNotification(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    return notification(alloc, "paste", protocol.ClipboardTextParams{ .text = text });
}
