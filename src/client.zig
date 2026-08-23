const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");

pub const PxPos = core.PxPos;
pub const CellPos = core.CellPos;

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

    /// Closes the connection. First drains it: `write_text`/`set_property`
    /// and friends are notifications, so the server may still be
    /// processing ones already sent when a short-lived client (e.g.
    /// `glyphwire-ls`) reaches the end of its run -- a plain socket close
    /// says nothing about whether the *server* has caught up, only that
    /// this client is done *sending*. A caller like glyphwire-shell that
    /// waits for the child process to exit and then queries state on its
    /// *own* connection (see `Prompt.submitLine`) would otherwise race
    /// the server's dispatch of this connection's last few notifications,
    /// intermittently reading stale state. One final request-response
    /// round trip forces that: this connection's dispatch is strictly
    /// in-order and mutex-guarded, so the response can't arrive until
    /// every prior notification has been applied, and any later lock
    /// acquisition by another connection's dispatch thread is guaranteed
    /// (standard mutex acquire/release semantics) to observe them.
    pub fn deinit(self: *Client) void {
        _ = self.getRevision() catch {};
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

    /// `insert_cells(count)` -- a notification. ECMA-48's ICH: shifts
    /// cells at and after the cursor rightward by `count` within its row,
    /// opening `count` blank cells at the cursor without moving it -- the
    /// primitive a line editor needs to insert into already-drawn text
    /// without retransmitting everything after the insertion point.
    pub fn insertCells(self: *Client, count: usize) !void {
        try self.notify("insert_cells", .{ .count = count });
    }

    /// `delete_cells(count)` -- a notification. ECMA-48's DCH: removes
    /// `count` cells at and after the cursor, shifting the row's
    /// remainder left and blanking `count` cells at the row's tail.
    pub fn deleteCells(self: *Client, count: usize) !void {
        try self.notify("delete_cells", .{ .count = count });
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

    /// `load_image(format, bytes)` -- a request using the binary
    /// side-channel: the JSON header frame declares `bytes.len`, then
    /// `bytes` follows directly on the wire (not another framed message) —
    /// see decisions.md's Transport & Wire Format. Only `"png"` is
    /// meaningful today (decisions.md's "assume PNG" scope), but `format`
    /// is still sent so the wire shape doesn't need to change when that
    /// widens. Returns a server-generated handle for `get_image_info`/
    /// `drawImage`.
    pub fn loadImage(self: *Client, format: []const u8, bytes: []const u8) !core.ImageHandle {
        const id = self.next_id;
        self.next_id += 1;

        const Msg = struct {
            jsonrpc: []const u8 = "2.0",
            id: i64,
            method: []const u8 = "load_image",
            params: struct { format: []const u8, bytes: usize },
        };
        try self.send(Msg{ .id = id, .params = .{ .format = format, .bytes = bytes.len } });

        var write_buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();

        const resp_body = try self.readFrame();
        defer self.alloc.free(resp_body);
        const parsed = try std.json.parseFromSlice(ResponseOf(struct { handle: core.ImageHandle }), self.alloc, resp_body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return parsed.value.result.handle;
    }

    /// `get_image_info(handle)` -- a request returning the image's natural
    /// pixel dimensions.
    pub fn getImageInfo(self: *Client, handle: core.ImageHandle) !core.ImageInfo {
        var parsed = try self.request(struct { width: u32, height: u32 }, "get_image_info", .{ .handle = handle });
        defer parsed.deinit();
        return .{ .width = parsed.value.result.width, .height = parsed.value.result.height };
    }

    /// `draw_image(handle, row, col, row_span, col_span)` -- a
    /// notification. Places the image at its natural pixel size, anchored
    /// at `(row, col)`, clipped to the given span rather than stretched to
    /// fill it — see decisions.md's Image section. Aspect-ratio-aware
    /// placement (choosing `row_span`/`col_span` to match the image's
    /// shape) is the caller's job; `getImageInfo` plus `getCellMetrics`
    /// give it what it needs to compute that.
    pub fn drawImage(self: *Client, handle: core.ImageHandle, row: usize, col: usize, row_span: usize, col_span: usize) !void {
        try self.notify("draw_image", .{
            .handle = handle,
            .row = row,
            .col = col,
            .row_span = row_span,
            .col_span = col_span,
        });
    }

    /// `draw_icon(row, col, name)` -- a notification. Draws a bundled,
    /// named icon (decisions.md's Icon section; the default set comes from
    /// `core.default_icon_manifest`) into exactly one cell -- unlike
    /// `drawImage`, no span: an icon is scoped to a single cell for now.
    pub fn drawIcon(self: *Client, row: usize, col: usize, name: []const u8) !void {
        try self.notify("draw_icon", .{ .row = row, .col = col, .name = name });
    }

    /// `draw_box(row, col, rows, cols, style)` -- a notification. Draws a
    /// `rows x cols` box using `style`'s 9 registered corner/edge/fill
    /// tiles (`"{style}-tl"`, ... -- see `core.default_box_manifest` for
    /// the bundled `"box"` style's pieces), one tile per cell, tiled
    /// rather than stretched.
    pub fn drawBox(self: *Client, row: usize, col: usize, rows: usize, cols: usize, style: []const u8) !void {
        try self.notify("draw_box", .{ .row = row, .col = col, .rows = rows, .cols = cols, .style = style });
    }

    /// `clear(row?, col?, rows?, cols?)` -- a notification. Resets cells in
    /// the given region back to blank/default style. `rows`/`cols` null
    /// means "the rest of the layer from `row`/`col`", so
    /// `clear(0, 0, null, null)` wipes the whole layer.
    pub fn clear(self: *Client, row: usize, col: usize, rows: ?usize, cols: ?usize) !void {
        try self.notify("clear", .{ .row = row, .col = col, .rows = rows, .cols = cols });
    }

    /// `get_cell_metrics` -- a request returning the session's fixed cell
    /// pixel size, for a client computing `draw_image`'s span from an
    /// image's natural pixel dimensions.
    pub fn getCellMetrics(self: *Client) !struct { w: u32, h: u32 } {
        var parsed = try self.request(struct { cell_px_w: u32, cell_px_h: u32 }, "get_cell_metrics", .{});
        defer parsed.deinit();
        return .{ .w = parsed.value.result.cell_px_w, .h = parsed.value.result.cell_px_h };
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

const ImageBgJson = struct { handle: core.ImageHandle, offset_x: u32, offset_y: u32 };

const CellJson = struct {
    g: []const u8,
    fg: ColorJson,
    bg: ?ColorJson,
    bg_image: ?ImageBgJson = null,
    bg_icon: ?core.ImageHandle = null,
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

/// A cell in renderer-friendly form: `core.Color`/`core.ImageBg` fields
/// instead of raw JSON. Exactly one of `bg`/`bg_image`/`bg_icon` is
/// non-null, mirroring `core.Background`'s tagged union.
pub const RenderCell = struct {
    grapheme: []const u8,
    fg: core.Color,
    bg: ?core.Color,
    bg_image: ?core.ImageBg = null,
    bg_icon: ?core.ImageHandle = null,
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
            .bg_image = if (c.bg_image) |img| .{ .handle = img.handle, .offset_x = img.offset_x, .offset_y = img.offset_y } else null,
            .bg_icon = c.bg_icon,
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
    /// Posted once per key event appended to `key_events`, so `waitKeyEvent`
    /// can block until one arrives instead of polling on a timer. Not kept
    /// in exact sync with `key_events.len` (`pollKeyEvent` drains the queue
    /// without touching this) -- a stale permit just means a caller of
    /// `waitKeyEvent` wakes once to an empty queue, no worse than a spurious
    /// poll.
    key_sem: std.Io.Semaphore = .{},

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

    /// Blocks until a key event is queued or `timeout` elapses (`null` on
    /// timeout), instead of `pollKeyEvent`'s non-blocking check -- for a
    /// consumer loop that wants to react immediately rather than re-polling
    /// on a fixed interval.
    pub fn waitKeyEvent(self: *InputListener, timeout: std.Io.Timeout) !?KeyEvent {
        self.key_sem.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => |e| return e,
        };
        return self.pollKeyEvent();
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
            self.key_sem.post(self.io);
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
