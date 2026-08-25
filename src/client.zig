const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");

/// Pixel-space cursor position (framebuffer pixels, as glyphwire-host
/// reports it).
pub const PxPos = struct { x: f32, y: f32 };

/// Cell-grid cursor position, derived from `PxPos` and the cell pixel
/// size -- see decisions.md's Cell/Layer sections. Whoever reports it
/// (glyphwire-host, which owns the font/cell metrics) computes this, not
/// the headless server -- see core.zig's `InputState` doc comment.
pub const CellPos = struct { row: usize, col: usize };

/// A glyphwire client: wraps connecting to `GLYPHWIRE_SOCK`, JSON-RPC
/// framing, and request/response correlation, so a program doesn't have to
/// hand-build JSON strings to speak the protocol (as the early test clients
/// did). One request in flight at a time -- every method here is a
/// synchronous send-then-wait-for-one-frame call, which is all any client
/// in this codebase needs so far.
///
/// Meant to grow a C ABI wrapper later (see docs) so non-Zig programs can
/// link against it too; kept as a plain struct with explicit alloc/io
/// rather than anything Zig-idiom-specific (comptime options, allocator-free
/// slices, etc.) to keep that translation straightforward when it happens.
pub const Client = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    stream: std.Io.net.Stream,
    decoder: wire.FrameDecoder = .{},
    next_id: i64 = 1,

    pub const ConnectError = std.Io.net.UnixAddress.InitError || std.Io.net.UnixAddress.ConnectError;
    pub const NoSessionError = error{NoSession};

    pub fn connect(io: std.Io, alloc: std.mem.Allocator, socket_path: []const u8) ConnectError!Client {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);
        return .{ .io = io, .alloc = alloc, .stream = stream };
    }

    /// Discovery per decisions.md: connects using `GLYPHWIRE_SOCK` from
    /// `environ_map`, or returns `error.NoSession` if it isn't set. Callers
    /// that want to degrade gracefully (per "never partially assume the
    /// grid is present") should treat any error from this the same way.
    pub fn connectFromEnv(
        io: std.Io,
        alloc: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
    ) (ConnectError || NoSessionError)!Client {
        const socket_path = environ_map.get("GLYPHWIRE_SOCK") orelse return error.NoSession;
        return connect(io, alloc, socket_path);
    }

    pub fn deinit(self: *Client) void {
        self.decoder.deinit(self.alloc);
        self.stream.close(self.io);
    }

    /// `write_text(text, fg?, bg?)` -- a notification, no response. `fg`/
    /// `bg` null means "use the server's default style" (see
    /// `core.default_style`), matching the wire params' optionality.
    pub fn writeText(self: *Client, text: []const u8, fg: ?core.Color, bg: ?core.Color) !void {
        try self.notify("write_text", .{
            .text = text,
            .fg = colorToJson(fg),
            .bg = colorToJson(bg),
        });
    }

    /// `set_property(layer, "cursor", {row, col})` -- a notification.
    pub fn setCursor(self: *Client, row: usize, col: usize) !void {
        try self.notify("set_property", .{ .property = "cursor", .row = row, .col = col });
    }

    /// `get_property(layer, "cursor")` -- a request.
    pub fn getCursor(self: *Client) !core.Cursor {
        var parsed = try self.request(struct { row: usize, col: usize }, "get_property", .{ .property = "cursor" });
        defer parsed.deinit();
        return .{ .row = parsed.value.result.row, .col = parsed.value.result.col };
    }

    /// `get_property(layer, "revision")` -- a request. Cheap: use this to
    /// decide whether `getCells` is worth calling again, rather than
    /// fetching the full grid every frame regardless of whether it changed.
    pub fn getRevision(self: *Client) !u64 {
        var parsed = try self.request(struct { revision: u64 }, "get_property", .{ .property = "revision" });
        defer parsed.deinit();
        return parsed.value.result.revision;
    }

    /// `get_cells` -- a request returning a full row-major snapshot of the
    /// root layer's visible viewport. Owns its own parsed JSON arena;
    /// caller must call `.deinit()` on the result.
    pub fn getCells(self: *Client) !CellsSnapshot {
        const parsed = try self.request(CellsResultJson, "get_cells", .{});
        return .{ .parsed = parsed };
    }

    /// `report_key(key, pressed)` -- a notification. `key` is expected to
    /// be a stable, portable name (glyphwire-host uses `@tagName` of
    /// pixzig's GLFW key enum, e.g. "a", "left_shift", "escape"); this
    /// type doesn't enforce a closed set.
    pub fn reportKey(self: *Client, key: []const u8, pressed: bool) !void {
        try self.notify("report_key", .{ .key = key, .pressed = pressed });
    }

    /// `report_mouse_button(button, pressed, px, cell)` -- a notification.
    pub fn reportMouseButton(self: *Client, button: []const u8, pressed: bool, px: PxPos, cell: CellPos) !void {
        try self.notify("report_mouse_button", .{
            .button = button,
            .pressed = pressed,
            .px = px,
            .cell = cell,
        });
    }

    /// `report_mouse_move(px, cell)` -- a notification. Doesn't trigger a
    /// broadcast server-side (no live move-event stream yet), just keeps
    /// `get_input_state`'s cursor position current.
    pub fn reportMouseMove(self: *Client, px: PxPos, cell: CellPos) !void {
        try self.notify("report_mouse_move", .{ .px = px, .cell = cell });
    }

    /// `subscribe(events)` -- a request; per decisions.md's Input model,
    /// synchronous so the caller has a clear point after which it's
    /// guaranteed to start receiving notifications for `events` (e.g.
    /// `"key"`, `"mouse_button"`) on this connection. See `InputListener`
    /// for a ready-made subscribed connection with a background reader.
    pub fn subscribe(self: *Client, events: []const []const u8) !void {
        var parsed = try self.request(struct { subscribed: [][]const u8 }, "subscribe", .{ .events = events });
        defer parsed.deinit();
    }

    /// `get_input_state` -- a request returning which keys/mouse buttons
    /// are currently down and the last known cursor position. A one-time
    /// bootstrap query; `InputListener` is the live-updating counterpart.
    /// Owns its own parsed JSON arena; caller must call `.deinit()`.
    pub fn getInputState(self: *Client) !InputStateSnapshot {
        const parsed = try self.request(InputStateResultJson, "get_input_state", .{});
        return .{ .parsed = parsed };
    }

    fn colorToJson(c: ?core.Color) ?ColorJson {
        const v = c orelse return null;
        return .{ .r = v.r, .g = v.g, .b = v.b, .a = v.a };
    }

    fn notify(self: *Client, method: []const u8, params: anytype) !void {
        const Msg = struct {
            jsonrpc: []const u8 = "2.0",
            method: []const u8,
            params: @TypeOf(params),
        };
        try self.send(Msg{ .method = method, .params = params });
    }

    fn request(self: *Client, comptime ResultT: type, method: []const u8, params: anytype) !std.json.Parsed(ResponseOf(ResultT)) {
        const id = self.next_id;
        self.next_id += 1;

        const Msg = struct {
            jsonrpc: []const u8 = "2.0",
            id: i64,
            method: []const u8,
            params: @TypeOf(params),
        };
        try self.send(Msg{ .id = id, .method = method, .params = params });

        const resp_body = try self.readFrame();
        defer self.alloc.free(resp_body);

        // alloc_always: resp_body is freed right after this returns, so
        // string fields (including RenderCell.grapheme, read well after
        // this call for a getCells response) must be copied into the
        // Parsed(T)'s own arena rather than referencing resp_body -- the
        // default (alloc_if_needed) would leave them dangling.
        return try std.json.parseFromSlice(ResponseOf(ResultT), self.alloc, resp_body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    fn send(self: *Client, msg: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.alloc, msg, .{});
        defer self.alloc.free(body);

        var write_buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        try wire.writeFrame(&w.interface, body);
        try w.interface.flush();
    }

    /// Reads and returns exactly one complete frame's body (caller frees
    /// with `self.alloc`), blocking on the socket until one arrives.
    fn readFrame(self: *Client) ![]u8 {
        while (true) {
            if (try self.decoder.next(self.alloc)) |body| return body;

            var read_buf: [4096]u8 = undefined;
            var data: [1][]u8 = .{&read_buf};
            const n = try self.stream.read(self.io, &data);
            if (n == 0) return error.ConnectionClosed;
            try self.decoder.feed(self.alloc, read_buf[0..n]);
        }
    }
};

fn ResponseOf(comptime ResultT: type) type {
    return struct {
        id: i64 = 0,
        result: ResultT = undefined,
    };
}

const ColorJson = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

const CellJson = struct {
    g: []const u8,
    fg: ColorJson,
    bg: ?ColorJson,
};

const CellsResultJson = struct {
    cols: usize,
    rows: usize,
    revision: u64,
    cells: []const CellJson,
};

const InputStateResultJson = struct {
    keys_down: []const []const u8,
    mouse_buttons_down: []const []const u8,
    cursor_px: PxPos,
    cursor_cell: CellPos,
};

/// A cell in renderer-friendly form: `core.Color` fields instead of raw
/// JSON, `bg` null for "no background color" (the image-background case,
/// unbuilt server-side -- see `dispatch.zig`'s `CellJson`).
pub const RenderCell = struct {
    grapheme: []const u8,
    fg: core.Color,
    bg: ?core.Color,
};

/// Owns the parsed JSON backing a `getCells` response; `deinit` frees it.
/// `cellAt` is a cheap view into that backing data, not a copy -- don't
/// hold onto a `RenderCell` past the snapshot's `deinit()`.
pub const CellsSnapshot = struct {
    parsed: std.json.Parsed(ResponseOf(CellsResultJson)),

    pub fn deinit(self: *CellsSnapshot) void {
        self.parsed.deinit();
    }

    pub fn cols(self: *const CellsSnapshot) usize {
        return self.parsed.value.result.cols;
    }

    pub fn rows(self: *const CellsSnapshot) usize {
        return self.parsed.value.result.rows;
    }

    pub fn revision(self: *const CellsSnapshot) u64 {
        return self.parsed.value.result.revision;
    }

    pub fn cellAt(self: *const CellsSnapshot, row: usize, col: usize) RenderCell {
        const c = self.parsed.value.result.cells[row * self.cols() + col];
        return .{
            .grapheme = c.g,
            .fg = .{ .r = c.fg.r, .g = c.fg.g, .b = c.fg.b, .a = c.fg.a },
            .bg = if (c.bg) |bg| .{ .r = bg.r, .g = bg.g, .b = bg.b, .a = bg.a } else null,
        };
    }
};

/// Owns the parsed JSON backing a `getInputState` response; `deinit`
/// frees it. A one-time snapshot -- see `InputListener` for a
/// live-updating equivalent.
pub const InputStateSnapshot = struct {
    parsed: std.json.Parsed(ResponseOf(InputStateResultJson)),

    pub fn deinit(self: *InputStateSnapshot) void {
        self.parsed.deinit();
    }

    pub fn keysDown(self: *const InputStateSnapshot) []const []const u8 {
        return self.parsed.value.result.keys_down;
    }

    pub fn mouseButtonsDown(self: *const InputStateSnapshot) []const []const u8 {
        return self.parsed.value.result.mouse_buttons_down;
    }

    pub fn isKeyDown(self: *const InputStateSnapshot, key: []const u8) bool {
        for (self.keysDown()) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    pub fn isMouseButtonDown(self: *const InputStateSnapshot, button: []const u8) bool {
        for (self.mouseButtonsDown()) |b| {
            if (std.mem.eql(u8, b, button)) return true;
        }
        return false;
    }

    pub fn cursorPixel(self: *const InputStateSnapshot) PxPos {
        return self.parsed.value.result.cursor_px;
    }

    pub fn cursorCell(self: *const InputStateSnapshot) CellPos {
        return self.parsed.value.result.cursor_cell;
    }
};

/// A dedicated, subscribed connection: sends `subscribe(events)` once,
/// then a background thread continuously reads pushed `key_down`/
/// `key_up`/`mouse_button` notifications and updates a local,
/// mutex-guarded cache -- so `isKeyDown`/`isMouseButtonDown`/
/// `cursorPixel`/`cursorCell` are instant local reads, not a round trip
/// per call.
///
/// Deliberately a separate connection from `Client`: interleaving
/// unsolicited push notifications with synchronous request/response
/// traffic on one connection would need demuxing this codebase doesn't
/// build yet (see `Client`'s doc comment -- one request in flight at a
/// time, assuming the next frame off the wire is always that request's
/// response). A program that both polls (e.g. `getCells`) and listens
/// for input -- glyphwire-host -- holds one of each.
/// One queued, discrete key press/release, in arrival order -- unlike
/// `InputState`'s down-set (a live cache, good for "is X held right
/// now"), this is what a line editor needs ("the user just pressed
/// enter", exactly once). `key` is owned; pop it via `pollKeyEvent` and
/// free it with the same allocator passed to `InputListener.connect`.
pub const KeyEvent = struct { key: []const u8, pressed: bool };

pub const InputListener = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    stream: std.Io.net.Stream,
    listen_thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    state: core.InputState,
    key_events: std.ArrayList(KeyEvent) = .empty,

    /// Connects, subscribes to `events`, and waits for the subscribe ack
    /// before spawning the background reader -- so by the time this
    /// returns, the subscription is guaranteed to be in effect and the
    /// only frames the reader thread will ever see on this connection are
    /// genuine pushed notifications. Heap-allocated (returns a pointer)
    /// since the background thread outlives this call's stack frame.
    pub fn connect(
        io: std.Io,
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        events: []const []const u8,
    ) !*InputListener {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);

        const self = try alloc.create(InputListener);
        errdefer alloc.destroy(self);
        self.* = .{ .io = io, .alloc = alloc, .stream = stream, .listen_thread = undefined, .state = core.InputState.init(alloc) };
        errdefer self.state.deinit();

        try self.sendSubscribeAndWaitForAck(events);

        // Joined by deinit, unlike most background threads in this
        // codebase: `state`/`mutex` must outlive the last access this
        // thread makes to them, so deinit needs to know the thread has
        // actually stopped before it frees `self`.
        self.listen_thread = try std.Thread.spawn(.{}, listenThread, .{self});

        return self;
    }

    /// Discovery per decisions.md, same as `Client.connectFromEnv`.
    pub fn connectFromEnv(
        io: std.Io,
        alloc: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        events: []const []const u8,
    ) !*InputListener {
        const socket_path = environ_map.get("GLYPHWIRE_SOCK") orelse return error.NoSession;
        return connect(io, alloc, socket_path, events);
    }

    /// Shuts the connection down (unblocking the reader thread's current
    /// or next read with an error/EOF -- unlike a bare `close`, this is
    /// well-defined to do from a thread other than the one blocked in the
    /// read, per POSIX shutdown(2)), waits for that thread to actually
    /// exit, then closes the socket and frees the listener.
    pub fn deinit(self: *InputListener) void {
        self.stream.shutdown(self.io, .both) catch {};
        self.listen_thread.join();
        self.stream.close(self.io);
        self.state.deinit();
        for (self.key_events.items) |ev| self.alloc.free(ev.key);
        self.key_events.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn isKeyDown(self: *InputListener, key: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.isKeyDown(key);
    }

    /// Pops the oldest queued key event, if any (non-blocking -- callers
    /// wanting to block should poll this in a short sleep loop, same as
    /// this file's own tests do). Caller must free `.key` with the same
    /// allocator passed to `connect`.
    pub fn pollKeyEvent(self: *InputListener) ?KeyEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.key_events.items.len == 0) return null;
        return self.key_events.orderedRemove(0);
    }

    pub fn isMouseButtonDown(self: *InputListener, button: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.isMouseButtonDown(button);
    }

    pub fn cursorPixel(self: *InputListener) PxPos {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .x = self.state.cursor_px.x, .y = self.state.cursor_px.y };
    }

    pub fn cursorCell(self: *InputListener) CellPos {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .row = self.state.cursor_cell.row, .col = self.state.cursor_cell.col };
    }

    fn sendSubscribeAndWaitForAck(self: *InputListener, events: []const []const u8) !void {
        const Msg = struct {
            jsonrpc: []const u8 = "2.0",
            id: i64 = 1,
            method: []const u8 = "subscribe",
            params: struct { events: []const []const u8 },
        };
        const body = try std.json.Stringify.valueAlloc(self.alloc, Msg{ .params = .{ .events = events } }, .{});
        defer self.alloc.free(body);

        var write_buf: [1024]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        try wire.writeFrame(&w.interface, body);
        try w.interface.flush();

        var decoder: wire.FrameDecoder = .{};
        defer decoder.deinit(self.alloc);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            var data: [1][]u8 = .{&read_buf};
            const n = try self.stream.read(self.io, &data);
            if (n == 0) return error.ConnectionClosed;
            try decoder.feed(self.alloc, read_buf[0..n]);
            if (try decoder.next(self.alloc)) |ack| {
                self.alloc.free(ack);
                return;
            }
        }
    }

    fn listenThread(self: *InputListener) void {
        self.listenLoop() catch |err| {
            std.log.err("glyphwire InputListener stopped: {t}", .{err});
        };
    }

    fn listenLoop(self: *InputListener) !void {
        var decoder: wire.FrameDecoder = .{};
        defer decoder.deinit(self.alloc);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            var data: [1][]u8 = .{&read_buf};
            const n = try self.stream.read(self.io, &data);
            if (n == 0) return;
            try decoder.feed(self.alloc, read_buf[0..n]);

            while (try decoder.next(self.alloc)) |body| {
                defer self.alloc.free(body);
                self.handleNotification(body) catch |err| {
                    std.log.err("glyphwire InputListener: bad notification: {t}", .{err});
                };
            }
        }
    }

    fn handleNotification(self: *InputListener, body: []const u8) !void {
        const Envelope = struct { method: []const u8, params: std.json.Value = .null };
        const parsed = try std.json.parseFromSlice(Envelope, self.alloc, body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.method, "key_down") or std.mem.eql(u8, parsed.value.method, "key_up")) {
            const P = struct { key: []const u8 };
            const p = try std.json.parseFromValue(P, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const pressed = std.mem.eql(u8, parsed.value.method, "key_down");
            const owned_key = try self.alloc.dupe(u8, p.value.key);
            errdefer self.alloc.free(owned_key);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            _ = try self.state.setKey(p.value.key, pressed);
            try self.key_events.append(self.alloc, .{ .key = owned_key, .pressed = pressed });
        } else if (std.mem.eql(u8, parsed.value.method, "mouse_button")) {
            const P = struct { button: []const u8, pressed: bool, px: PxPos, cell: CellPos };
            const p = try std.json.parseFromValue(P, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state.cursor_px = .{ .x = p.value.px.x, .y = p.value.px.y };
            self.state.cursor_cell = .{ .row = p.value.cell.row, .col = p.value.cell.col };
            _ = try self.state.setMouseButton(p.value.button, p.value.pressed);
        }
    }
};
