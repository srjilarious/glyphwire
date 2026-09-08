const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");

pub const PxPos = core.PxPos;
pub const CellPos = core.CellPos;

/// Byte sequence `Client.connect` writes to the process's own real stdout
/// the moment it successfully connects, to tell a launcher that captures
/// its stdout/stderr by default (`glyphwire-shell`'s `Prompt.runCommand`,
/// which otherwise assumes any spawned command is a plain,
/// non-glyphwire-aware program echoing to a terminal) that this process
/// is drawing to the grid itself over its own wire connection instead --
/// see `connect`'s doc comment and docs/decisions.md's Discovery &
/// connection section. A leading NUL byte makes it vanishingly unlikely a
/// plain program's real output would ever start with this exact sequence.
pub const handshake_marker = "\x00glyphwire-handshake-v1\x00";

/// Writes `handshake_marker` to the real process stdout and flushes it
/// immediately -- see its doc comment. Private: `Client.connect` is the
/// only caller, since folding the handshake into connecting itself is the
/// whole point (see `connect`'s doc comment).
fn signalHandshake(io: std.Io) !void {
    var buf: [handshake_marker.len]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(handshake_marker);
    try w.interface.flush();
}

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
    /// Ceiling on how long a single `readFrame` (i.e. any `request`) will
    /// block waiting for the server's response frame before giving up with
    /// `error.Timeout`. Every method on this type is a synchronous
    /// send-then-wait-for-one-frame round trip against a mutex-guarded,
    /// strictly-in-order dispatcher, so a legitimate response is always a
    /// few milliseconds away -- a read that stalls for this long means the
    /// peer is wedged or gone, and blocking forever there just turns a
    /// dead server into a hung client (or, in the test suites that drive a
    /// library-bound `Server`, a hung test process). 30s is far past any
    /// real round trip while still bounded; a test that wants to *assert*
    /// the timeout fires can shorten this field after `connect`.
    read_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(30_000), .clock = .awake } },

    pub const ConnectError = std.Io.net.UnixAddress.InitError || std.Io.net.UnixAddress.ConnectError;
    pub const NoSessionError = error{NoSession};

    /// Connects and signals the handshake (`handshake_marker`, see its doc
    /// comment) in the same step -- only a glyphwire-aware program ever
    /// calls `connect` in the first place, so there's no case where a
    /// caller would want one without the other; folding it in here means
    /// every current and future caller gets it automatically instead of
    /// having to remember a separate call. Also the natural place to grow
    /// an options-carrying variant later (e.g. requesting a dedicated
    /// fullscreen layer at connect time) without every call site needing
    /// to change again. Handshake failures are swallowed rather than
    /// propagated: a hiccup writing to stdout shouldn't take down the
    /// actual wire connection this call exists to establish.
    pub fn connect(io: std.Io, alloc: std.mem.Allocator, socket_path: []const u8) ConnectError!Client {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);
        signalHandshake(io) catch {};
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

    /// Same as `writeText`, but every cell the text touches is also
    /// tagged with `metadata_id` (`create_metadata`'s return value) -- see
    /// `core.Cell.metadata_id`'s doc comment. A separate method rather
    /// than a new required param on `writeText` since Zig has no default
    /// parameter values.
    pub fn writeTextTagged(self: *Client, text: []const u8, fg: ?core.Color, bg: ?core.Color, metadata_id: core.MetadataHandle) !void {
        try self.notify("write_text", .{
            .text = text,
            .fg = colorToJson(fg),
            .bg = colorToJson(bg),
            .metadata_id = metadata_id,
        });
    }

    /// `write_text(text, fg?, transparent_bg: true)` -- like `writeText`,
    /// but leaves whatever background is already on each cell touched
    /// untouched instead of resetting it to `core.default_style.bg` -- for
    /// writing text over a background drawn some other way (e.g.
    /// `drawBoxStyled`'s fill) that needs to stay visible through it,
    /// rather than approximating it with a matching flat color. A separate
    /// method rather than a third `?bool` param on `writeText` since Zig
    /// has no default parameter values.
    pub fn writeTextTransparent(self: *Client, text: []const u8, fg: ?core.Color) !void {
        try self.notify("write_text", .{
            .text = text,
            .fg = colorToJson(fg),
            .transparent_bg = true,
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

    /// `move_content(layer, count, direction)` -- a notification. Shifts
    /// `count` rows of `layer`'s content grid (the whole grid, or the
    /// inclusive `[top, bot]` band) vertically in place, the wire face of
    /// CSI SU/SD: a client-scrolled pane scrolls by moving the rows it
    /// still has and redrawing only the newly-exposed band rather than
    /// retransmitting every visible row. Usually issued from inside a
    /// `batch` right before that partial redraw -- see `Batch.moveContent`.
    pub fn moveContentOn(
        self: *Client,
        layer: core.LayerHandle,
        top: ?usize,
        bot: ?usize,
        count: usize,
        direction: core.Layer.ScrollDir,
    ) !void {
        try self.notify("move_content", .{
            .layer = layer,
            .top = top,
            .bot = bot,
            .count = count,
            .direction = @tagName(direction),
        });
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

    /// `get_property(layer, "size")` -- a request returning the layer's
    /// viewport size in cells. For the root layer this is the current
    /// window size; `InputListener` subscribed to `"resize"` is the
    /// live-updating counterpart for a client that wants to react to
    /// window resizes rather than poll.
    pub fn getSize(self: *Client) !core.LayerSize {
        var parsed = try self.request(struct { cols: usize, rows: usize }, "get_property", .{ .property = "size" });
        defer parsed.deinit();
        return .{ .cols = parsed.value.result.cols, .rows = parsed.value.result.rows };
    }

    /// `get_cells(layer?)` -- a request returning a full row-major
    /// snapshot of the given layer's (default: root's) visible viewport.
    /// Owns its own parsed JSON arena; caller must call `.deinit()` on
    /// the result. `.{ .layer = null }`, not a bare `.{}`: an empty
    /// anonymous struct serializes as a JSON *array* (Zig's tuple
    /// encoding), not `{}` -- fine for a method the server never parses
    /// params for, but `get_cells` now does (`GetCellsParams`), so it
    /// needs a real single-field object on the wire.
    pub fn getCells(self: *Client) !CellsSnapshot {
        const parsed = try self.request(protocol.CellsResult, "get_cells", .{ .layer = @as(?core.LayerHandle, null) });
        return .{ .parsed = parsed };
    }

    /// `get_cells(layer)` for a specific (non-root) layer -- see
    /// `getCells` for the root-layer version.
    pub fn getCellsOn(self: *Client, layer: core.LayerHandle) !CellsSnapshot {
        const parsed = try self.request(protocol.CellsResult, "get_cells", .{ .layer = layer });
        return .{ .parsed = parsed };
    }

    /// `get_cells(layer?, view_offset)` -- the root layer's grid as it
    /// appears scrolled back by `view_offset` rows of history (see
    /// `core.Layer.viewRow`). `view_offset == 0` is identical to
    /// `getCells`.
    pub fn getCellsView(self: *Client, view_offset: usize) !CellsSnapshot {
        const parsed = try self.request(protocol.CellsResult, "get_cells", .{ .layer = @as(?core.LayerHandle, null), .view_offset = view_offset });
        return .{ .parsed = parsed };
    }

    /// `get_property(layer, "scroll")` -- a request returning the root
    /// layer's scrollback view state (`{offset, max}`): `offset` rows of
    /// history currently showing above the live viewport, out of `max`
    /// retained. `scrollView` is how a client moves it; `InputListener`
    /// subscribed to `"scroll"` is the live-updating counterpart.
    pub fn getScroll(self: *Client) !core.LayerScroll {
        var parsed = try self.request(struct { offset: usize, max: usize }, "get_property", .{ .property = "scroll" });
        defer parsed.deinit();
        return .{ .offset = parsed.value.result.offset, .max = parsed.value.result.max };
    }

    /// `scroll_view(layer?, offset?, delta?)` -- a request that moves the
    /// root layer's scrollback view offset (see `core.Layer.scrollView`)
    /// and returns the resulting `{offset, max}`. `offset` is an absolute
    /// target in rows; `delta` is added after; the result is clamped to
    /// `0..max`. Passing neither is a pure query. The server also
    /// broadcasts a `scroll` notification to other `"scroll"` subscribers.
    pub fn scrollView(self: *Client, offset: ?usize, delta: ?i64) !core.LayerScroll {
        var parsed = try self.request(struct { offset: usize, max: usize }, "scroll_view", .{ .offset = offset, .delta = delta });
        defer parsed.deinit();
        return .{ .offset = parsed.value.result.offset, .max = parsed.value.result.max };
    }

    /// `report_key(key, pressed)` -- a notification. `key` is expected to
    /// be a stable, portable name (glyphwire-host uses `@tagName` of its
    /// engine's `Key` enum, e.g. "a", "left_shift", "escape"); this type
    /// doesn't enforce a closed set.
    pub fn reportKey(self: *Client, key: []const u8, pressed: bool) !void {
        try self.notify("report_key", .{ .key = key, .pressed = pressed });
    }

    /// `report_text(text)` -- a notification. `text` is committed text
    /// input as a UTF-8 string of one or more codepoints (already resolved
    /// through the OS keyboard layout / dead keys / IME). Separate from
    /// `reportKey`: see `protocol.TextParams`. The server fans it out to
    /// `"text"` subscribers only; it doesn't update any input down-set.
    pub fn reportText(self: *Client, text: []const u8) !void {
        try self.notify("report_text", .{ .text = text });
    }

    /// `report_mouse_button(button, pressed, px, cell, view_offset)` -- a
    /// notification. `view_offset` is the root layer's scrollback view
    /// offset at click time (see `core.Layer.view_scroll`); pass 0 from a
    /// reporter that isn't tracking scrollback.
    pub fn reportMouseButton(self: *Client, button: []const u8, pressed: bool, px: PxPos, cell: CellPos, view_offset: usize) !void {
        try self.notify("report_mouse_button", .{
            .button = button,
            .pressed = pressed,
            .px = px,
            .cell = cell,
            .view_offset = view_offset,
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
    /// see decisions.md's Transport & Wire Format. `format` is now parsed
    /// server-side (`"png"`, `"jpeg"`/`"jpg"`, `"bmp"`, `"gif"`) to pick
    /// the header parser that measures the image; an unknown value or bytes
    /// that don't match the declared format fail the request. Returns a
    /// server-generated handle for `get_image_info`/`drawImage`.
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

    /// `draw_image(handle, row?, col?, row_span, col_span, scale)` -- a
    /// notification. Places the image anchored at `(row, col)` (defaulting
    /// to the layer's cursor when either is omitted, same as `write_text`'s
    /// documented convention), clipped to the given span rather than
    /// stretched to fill it — see decisions.md's Image section. `scale` is
    /// the uniform factor the image is drawn at: `1.0` is its natural pixel
    /// size (the original behavior); `< 1.0` shrinks it (glyphwire-view
    /// passes `target_width_px / image_width_px` for `--size fit-width`).
    /// Aspect-ratio-aware placement (choosing `row_span`/`col_span` to
    /// match the image's *scaled* shape) is the caller's job; `getImageInfo`
    /// plus `getCellMetrics` and `getSize` give it what it needs to compute
    /// that.
    pub fn drawImage(self: *Client, handle: core.ImageHandle, row: ?usize, col: ?usize, row_span: usize, col_span: usize, scale: f32) !void {
        try self.notify("draw_image", .{
            .handle = handle,
            .row = row,
            .col = col,
            .row_span = row_span,
            .col_span = col_span,
            .scale = scale,
        });
    }

    /// `draw_icon(row?, col?, name)` -- a notification. Draws a bundled,
    /// named icon (decisions.md's Icon section; the default set is the
    /// `assets/icons/` tree, each icon named by its path there minus the
    /// `.png`) into exactly one cell, anchored at the
    /// layer's cursor when `row`/`col` is omitted -- unlike `drawImage`, no
    /// span: an icon is scoped to a single cell for now.
    pub fn drawIcon(self: *Client, row: ?usize, col: ?usize, name: []const u8) !void {
        try self.notify("draw_icon", .{ .row = row, .col = col, .name = name });
    }

    /// `scale`/`h_align`/`v_align`/`max_w`/`max_h` for `drawIconStyled` --
    /// see `core.IconBg`'s doc comment. Defaults match `drawIcon`'s
    /// behavior. `max_w`/`max_h` only apply when `scale == .natural`.
    pub const DrawIconOpts = struct {
        scale: core.IconScale = .fit,
        h_align: core.HAlign = .center,
        v_align: core.VAlign = .center,
        max_w: ?u32 = null,
        max_h: ?u32 = null,
        /// See `core.Cell.metadata_id`'s doc comment.
        metadata_id: ?core.MetadataHandle = null,
        /// `true` draws into `core.Cell.fg_icon` instead of `style.bg` --
        /// see that field's doc comment. For content meant to sit over an
        /// already-drawn background (e.g. a `drawBoxStyled` fill) rather
        /// than replace it.
        foreground: bool = false,
    };

    /// `draw_icon(row?, col?, name, scale?, h_align?, v_align?, max_w?,
    /// max_h?, metadata_id?)` -- like `drawIcon`, but lets the icon be
    /// drawn at its own native pixel size (`opts.scale = .natural`,
    /// optionally capped by `opts.max_w`/`opts.max_h`) or stretched to
    /// exactly fill the cell (`.stretch`) instead of shrunk to fit the
    /// anchor cell, aligned relative to the anchor cell per
    /// `opts.h_align`/`opts.v_align`, and optionally tagged with
    /// `opts.metadata_id`. A separate method rather than extra params on
    /// `drawIcon` itself since Zig has no default parameter values.
    pub fn drawIconStyled(self: *Client, row: ?usize, col: ?usize, name: []const u8, opts: DrawIconOpts) !void {
        try self.notify("draw_icon", .{
            .row = row,
            .col = col,
            .name = name,
            .scale = @tagName(opts.scale),
            .h_align = @tagName(opts.h_align),
            .v_align = @tagName(opts.v_align),
            .max_w = opts.max_w,
            .max_h = opts.max_h,
            .metadata_id = opts.metadata_id,
            .foreground = opts.foreground,
        });
    }

    /// `draw_icon(layer, row?, col?, name)` on a non-root layer -- see
    /// `drawIcon` for the root-layer version.
    pub fn drawIconOn(self: *Client, layer: core.LayerHandle, row: ?usize, col: ?usize, name: []const u8) !void {
        try self.notify("draw_icon", .{ .layer = layer, .row = row, .col = col, .name = name });
    }

    /// `draw_icon(layer, row?, col?, name, scale?, h_align?, v_align?,
    /// max_w?, max_h?, metadata_id?)` on a non-root layer -- see
    /// `drawIconStyled` for the root-layer version.
    pub fn drawIconOnStyled(self: *Client, layer: core.LayerHandle, row: ?usize, col: ?usize, name: []const u8, opts: DrawIconOpts) !void {
        try self.notify("draw_icon", .{
            .layer = layer,
            .row = row,
            .col = col,
            .name = name,
            .scale = @tagName(opts.scale),
            .h_align = @tagName(opts.h_align),
            .v_align = @tagName(opts.v_align),
            .max_w = opts.max_w,
            .max_h = opts.max_h,
            .metadata_id = opts.metadata_id,
            .foreground = opts.foreground,
        });
    }

    /// `tag_metadata(layer?, row, col, metadata_id)` -- a notification.
    /// Sets exactly one cell's metadata tag without touching its
    /// background/text -- unlike `writeTextTagged`/`drawIconStyled`,
    /// which tag as a side effect of drawing something. For a client that
    /// needs a cell tagged without changing what's drawn there, e.g.
    /// tagging the extra cells a `.natural`-scaled icon visually
    /// overflows into (see `core.IconScale`'s doc comment on why that
    /// overflow has no automatic data-model footprint on its own).
    pub fn tagMetadata(self: *Client, layer: ?core.LayerHandle, row: usize, col: usize, metadata_id: core.MetadataHandle) !void {
        try self.notify("tag_metadata", .{ .layer = layer, .row = row, .col = col, .metadata_id = metadata_id });
    }

    /// `draw_box(row?, col?, rows, cols, style)` -- a notification. Draws a
    /// `rows x cols` box using `style`'s 9 registered corner/edge/fill
    /// tiles (`"{style}/tl"`, ... -- the bundled `assets/icons/box/`
    /// subtree is the `"box"` style), one tile per cell, tiled rather
    /// than stretched, anchored at the layer's cursor when `row`/`col` is
    /// omitted.
    pub fn drawBox(self: *Client, row: ?usize, col: ?usize, rows: usize, cols: usize, style: []const u8) !void {
        try self.notify("draw_box", .{ .row = row, .col = col, .rows = rows, .cols = cols, .style = style });
    }

    /// `mode` for `drawBoxStyled`/`drawBoxOnStyled` -- see
    /// `core.Layer.BoxMode`. Defaults match `drawBox`'s behavior.
    pub const DrawBoxOpts = struct {
        mode: core.Layer.BoxMode = .tile,
    };

    /// `draw_box(row?, col?, rows, cols, style, mode)` -- like `drawBox`,
    /// but lets the 9 pieces be composed with `opts.mode = .stretch`
    /// (each edge/fill role's single tile stretched continuously across
    /// however many cells it spans, rather than repeated per cell) instead
    /// of the default `.tile`. A separate method rather than an extra
    /// param on `drawBox` itself since Zig has no default parameter
    /// values.
    pub fn drawBoxStyled(self: *Client, row: ?usize, col: ?usize, rows: usize, cols: usize, style: []const u8, opts: DrawBoxOpts) !void {
        try self.notify("draw_box", .{
            .row = row,
            .col = col,
            .rows = rows,
            .cols = cols,
            .style = style,
            .mode = @tagName(opts.mode),
        });
    }

    /// `clear(row?, col?, rows?, cols?)` -- a notification. Resets cells in
    /// the given region back to blank/default style. `rows`/`cols` null
    /// means "the rest of the layer from `row`/`col`", so
    /// `clear(0, 0, null, null)` wipes the whole layer.
    pub fn clear(self: *Client, row: usize, col: usize, rows: ?usize, cols: ?usize) !void {
        try self.notify("clear", .{ .row = row, .col = col, .rows = rows, .cols = cols });
    }

    /// `create_layer(width?, height?, scrollback_rows)` -- a request.
    /// Allocates a fresh layer parented to the root, defaulting to the
    /// context's base size when `width`/`height` is omitted -- see
    /// decisions.md's Layer section. Returns its handle, for the
    /// `*On`/`*Layer` methods below.
    pub fn createLayer(self: *Client, width: ?usize, height: ?usize, scrollback_rows: usize) !core.LayerHandle {
        var parsed = try self.request(struct { handle: core.LayerHandle }, "create_layer", .{
            .width = width,
            .height = height,
            .scrollback_rows = scrollback_rows,
        });
        defer parsed.deinit();
        return parsed.value.result.handle;
    }

    /// `destroy_layer(layer)` -- a notification. Frees a layer created by
    /// `createLayer` and drops it from compositing; there's nothing more
    /// to do afterward, including no need to `clear` it first. The server
    /// honors this only from a connection that owns the layer (created it,
    /// or `adoptLayer`'d it); a non-owner's call is logged and ignored.
    /// You don't have to call this on a clean exit either -- the server
    /// culls a layer once every connection that owned it has disconnected.
    pub fn destroyLayer(self: *Client, layer: core.LayerHandle) !void {
        try self.notify("destroy_layer", .{ .layer = layer });
    }

    /// `adopt_layer(layer)` -- a notification. Adds this connection to
    /// `layer`'s set of owners, so the layer outlives its original
    /// creator disconnecting for as long as this connection stays up, and
    /// this connection may itself `destroyLayer` it. Use it when one
    /// process hands ongoing responsibility for a layer to another.
    pub fn adoptLayer(self: *Client, layer: core.LayerHandle) !void {
        try self.notify("adopt_layer", .{ .layer = layer });
    }

    /// `create_context(width?, height?, scrollback_rows)` -- a request.
    /// Allocates a fresh, independent full-window context (its own root
    /// layer, split tree, layers -- see decisions.md's Object Model and
    /// `core.Session`) and shows it immediately: an alt-screen-style
    /// model for a full-screen program that doesn't want to just layer
    /// panes over the shell's scrollback. `width`/`height` default to the
    /// visible context's current size. From here on every `layer?`-scoped
    /// call on *this* `Client` targets the new context. This connection
    /// owns it, so it's torn down (with everything in it) if the
    /// connection closes without `destroyContext`. Returns its handle,
    /// for `activateContext`.
    ///
    /// `window_scrollbar` false suppresses glyphwire-host's always-on
    /// right-edge scrollbar for this context -- what a pure-TUI client
    /// (zoe) wants, since its root has no scrollback and its panes carry
    /// their own bars. `setWindowScrollbar` toggles it later.
    pub fn createContext(
        self: *Client,
        width: ?usize,
        height: ?usize,
        scrollback_rows: usize,
        window_scrollbar: bool,
    ) !core.ContextHandle {
        var parsed = try self.request(struct { context: core.ContextHandle }, "create_context", .{
            .width = width,
            .height = height,
            .scrollback_rows = scrollback_rows,
            .window_scrollbar = window_scrollbar,
        });
        defer parsed.deinit();
        return parsed.value.result.context;
    }

    /// `set_window_scrollbar(visible)` -- a notification. Toggles the
    /// always-on window scrollbar for this connection's active context
    /// after the fact (see `createContext`'s `window_scrollbar`).
    pub fn setWindowScrollbar(self: *Client, visible: bool) !void {
        try self.notify("set_window_scrollbar", .{ .visible = visible });
    }

    /// `destroy_context(context)` -- a notification. Frees a context
    /// created by `createContext` and everything in it, and (if it was
    /// visible) drops visibility back to whatever context was under it --
    /// the alt-screen auto-restore. Honored only from a connection that
    /// owns the context. Like `destroyLayer`, you don't have to call this
    /// on a clean exit: the server culls the context once every owning
    /// connection has disconnected.
    pub fn destroyContext(self: *Client, context: core.ContextHandle) !void {
        try self.notify("destroy_context", .{ .context = context });
    }

    /// `activate_context(context)` -- a notification. Makes `context` the
    /// one on screen *without* changing which context this `Client`
    /// draws on. A program backgrounds itself by activating
    /// `glyphwire.root_context_handle` and restores itself by activating
    /// its own handle again.
    pub fn activateContext(self: *Client, context: core.ContextHandle) !void {
        try self.notify("activate_context", .{ .context = context });
    }

    /// `adopt_context(context)` -- a notification. The context-level
    /// mirror of `adoptLayer`: adds this connection to `context`'s owner
    /// set so it outlives its creator disconnecting.
    pub fn adoptContext(self: *Client, context: core.ContextHandle) !void {
        try self.notify("adopt_context", .{ .context = context });
    }

    /// `attach_context(context)` -- a notification. Retargets this
    /// connection onto an existing context without creating or owning it
    /// -- every later `layer?`-scoped call resolves against it. `create_context`
    /// already does this for the context it makes; use `attachContext`
    /// for a second connection that needs to act on the same context (a
    /// paired `InputListener` -- see `InputListener.attachContext`).
    pub fn attachContext(self: *Client, context: core.ContextHandle) !void {
        try self.notify("attach_context", .{ .context = context });
    }

    /// `set_property(layer, "cursor", {row, col})` on a non-root layer --
    /// see `setCursor` for the root-layer version. `write_text` is always
    /// cursor-implicit (no `row`/`col` params of its own), so placing text
    /// on a layer other than root goes through this first.
    pub fn setCursorOn(self: *Client, layer: core.LayerHandle, row: usize, col: usize) !void {
        try self.notify("set_property", .{ .layer = layer, .property = "cursor", .row = row, .col = col });
    }

    /// `set_property(layer, "position", {x, y})` -- a notification. Moves
    /// `layer` to a pixel-precise position relative to the root (see
    /// `PropertyName.position`'s doc comment) -- e.g. sliding a
    /// notification layer across the screen one small step at a time.
    pub fn setLayerPosition(self: *Client, layer: core.LayerHandle, x: f32, y: f32) !void {
        try self.notify("set_property", .{ .layer = layer, .property = "position", .x = x, .y = y });
    }

    /// `set_property(layer, "cell_position", {row, col})` -- a
    /// notification. The same placement as `setLayerPosition` but in grid
    /// cells, and *sticky*: the server re-derives the pixel position when
    /// the cell metrics change, so a layer placed this way stays on its
    /// column across a font-size change. See
    /// `core.PropertyName.cell_position`.
    pub fn setLayerCellPosition(self: *Client, layer: core.LayerHandle, row: usize, col: usize) !void {
        try self.notify("set_property", .{ .layer = layer, .property = "cell_position", .row = row, .col = col });
    }

    /// `get_property(layer?, "cell_position")` -- the cell a layer's
    /// top-left corner sits on.
    pub fn getLayerCellPosition(self: *Client, layer: ?core.LayerHandle) !CellPos {
        var parsed = try self.request(struct { row: usize, col: usize }, "get_property", .{ .layer = layer, .property = "cell_position" });
        defer parsed.deinit();
        return .{ .row = parsed.value.result.row, .col = parsed.value.result.col };
    }

    /// `set_property(layer, "size", {cols, rows})` -- a notification.
    /// Resizes a `createLayer` layer's cell grid, bottom-anchored like
    /// every other resize (see `core.Layer.resize`). This is how a
    /// multi-pane TUI reflows its panes on a `resize` notification
    /// without destroying and rebuilding them. Rejected for the root
    /// layer, whose size the host owns.
    pub fn setLayerSize(self: *Client, layer: core.LayerHandle, cols: usize, rows: usize) !void {
        try self.notify("set_property", .{ .layer = layer, .property = "size", .cols = cols, .rows = rows });
    }

    /// `get_property(layer, "size")` on a non-root layer -- see `getSize`
    /// for the root-layer (i.e. window-size) version.
    pub fn getLayerSize(self: *Client, layer: core.LayerHandle) !core.LayerSize {
        var parsed = try self.request(struct { cols: usize, rows: usize }, "get_property", .{ .layer = layer, .property = "size" });
        defer parsed.deinit();
        return .{ .cols = parsed.value.result.cols, .rows = parsed.value.result.rows };
    }

    /// `set_property(layer, "visibility", {visible})` -- a notification.
    /// Hides or shows a layer without destroying it: its cells, tables
    /// and metadata ids all survive, glyphwire-host just stops
    /// compositing it. Rejected for the root layer.
    pub fn setLayerVisible(self: *Client, layer: core.LayerHandle, visible: bool) !void {
        try self.notify("set_property", .{ .layer = layer, .property = "visibility", .visible = visible });
    }

    /// `get_property(layer?, "visibility")`.
    pub fn getLayerVisible(self: *Client, layer: ?core.LayerHandle) !bool {
        var parsed = try self.request(struct { visible: bool }, "get_property", .{ .layer = layer, .property = "visibility" });
        defer parsed.deinit();
        return parsed.value.result.visible;
    }

    /// `set_property(layer, "viewport", {cols, rows})` -- a notification.
    /// How much of the layer's content grid the host draws; zero on an
    /// axis means all of it. This is what makes a pane a *window onto*
    /// its content rather than the whole of it -- see
    /// `core.PropertyName.viewport`. A layer inside a split tree has this
    /// set for it by the layout.
    pub fn setLayerViewport(self: *Client, layer: core.LayerHandle, cols: usize, rows: usize) !void {
        try self.notify("set_property", .{ .layer = layer, .property = "viewport", .cols = cols, .rows = rows });
    }

    /// `get_property(layer?, "viewport")`.
    pub fn getLayerViewport(self: *Client, layer: ?core.LayerHandle) !core.Viewport {
        var parsed = try self.request(struct { cols: usize, rows: usize }, "get_property", .{ .layer = layer, .property = "viewport" });
        defer parsed.deinit();
        return .{ .cols = parsed.value.result.cols, .rows = parsed.value.result.rows };
    }

    /// `set_property(layer, "scroll_offset", {row, col})` -- a
    /// notification. Where the viewport sits in the content grid, clamped
    /// server-side to what the content actually has.
    pub fn setLayerScrollOffset(self: *Client, layer: core.LayerHandle, row: usize, col: usize) !void {
        try self.notify("set_property", .{ .layer = layer, .property = "scroll_offset", .row = row, .col = col });
    }

    /// `get_property(layer?, "scroll_offset")` -- the offset plus each
    /// axis's maximum, so a caller can tell how much slack is left
    /// without a second request.
    pub fn getLayerScrollOffset(self: *Client, layer: ?core.LayerHandle) !ScrollOffsetState {
        var parsed = try self.request(ScrollOffsetState, "get_property", .{ .layer = layer, .property = "scroll_offset" });
        defer parsed.deinit();
        return parsed.value.result;
    }

    /// `set_property(layer, "content_extent", {cols, rows})` -- a
    /// notification. Declares the size of the whole content a
    /// self-scrolling pane redraws (a TUI editor's buffer), so the host
    /// can draw a proportional scrollbar and turn a wheel / drag over the
    /// pane into a `scroll_offset` the client obeys. `{0, 0}` clears it.
    /// See `core.PropertyName.content_extent`.
    pub fn setLayerContentExtent(self: *Client, layer: core.LayerHandle, cols: usize, rows: usize) !void {
        try self.notify("set_property", .{ .layer = layer, .property = "content_extent", .cols = cols, .rows = rows });
    }

    /// `set_property(layer, "scrollbars", {vertical, horizontal})` -- a
    /// notification. Opt in per axis; the host draws the bars inside the
    /// layer's own bounds and drives `scroll_offset` from them.
    pub fn setLayerScrollbars(self: *Client, layer: core.LayerHandle, vertical: bool, horizontal: bool) !void {
        try self.notify("set_property", .{
            .layer = layer,
            .property = "scrollbars",
            .vertical = vertical,
            .horizontal = horizontal,
        });
    }

    /// `get_property(layer?, "scrollbars")` -- the flags plus the current
    /// offset and maximum on each axis.
    pub fn getLayerScrollbars(self: *Client, layer: ?core.LayerHandle) !core.ScrollbarState {
        var parsed = try self.request(core.ScrollbarState, "get_property", .{ .layer = layer, .property = "scrollbars" });
        defer parsed.deinit();
        return parsed.value.result;
    }

    /// `create_split(axis, resizable)` -- a request. An empty pane
    /// container; give it children with `setSplitChildren` and make it
    /// the layout with `setRootSplit`. `resizable` false (see
    /// `core.Split.resizable`) leaves no gap between the children, draws
    /// no grab band, and ignores `moveDivider` -- for a structural split
    /// like buffer-area-over-command-line.
    pub fn createSplit(self: *Client, axis: core.SplitAxis, resizable: bool) !core.SplitHandle {
        var parsed = try self.request(struct { handle: core.SplitHandle }, "create_split", .{
            .axis = @tagName(axis),
            .resizable = resizable,
        });
        defer parsed.deinit();
        return parsed.value.result.handle;
    }

    /// `destroy_split(split)` -- a notification. Frees the container; its
    /// children (layers and nested splits) survive.
    pub fn destroySplit(self: *Client, split: core.SplitHandle) !void {
        try self.notify("destroy_split", .{ .split = split });
    }

    /// `set_split_children(split, children)` -- a notification. Replaces
    /// the child list wholesale. Each entry names a layer *or* a nested
    /// split, and is sized either by `weight` (a share of what's left) or
    /// `fixed` (that many cells along the split's axis).
    pub fn setSplitChildren(self: *Client, split: core.SplitHandle, children: []const SplitChildInput) !void {
        try self.notify("set_split_children", .{ .split = split, .children = children });
    }

    /// `set_root_split(split?)` -- a notification. Which split fills the
    /// window; null tears the layout down without destroying anything.
    pub fn setRootSplit(self: *Client, split: ?core.SplitHandle) !void {
        try self.notify("set_root_split", .{ .split = split });
    }

    /// `move_divider(split, index, delta)` -- a notification. Drags the
    /// band after child `index` by `delta` cells. glyphwire-host sends
    /// this for a mouse drag; a client sends it for a keyboard "grow this
    /// pane" binding.
    pub fn moveDivider(self: *Client, split: core.SplitHandle, index: usize, delta: i64) !void {
        try self.notify("move_divider", .{ .split = split, .index = index, .delta = delta });
    }

    /// `raise_layer(layer, above?)` -- a notification. Moves `layer` up
    /// the compositing order: directly above `above`, or to the very top
    /// when it's null. Creation order is only the *initial* stacking, so
    /// this is what puts a completion popup created early back over a
    /// sidebar created later.
    pub fn raiseLayer(self: *Client, layer: core.LayerHandle, above: ?core.LayerHandle) !void {
        try self.notify("raise_layer", .{ .layer = layer, .above = above });
    }

    /// `lower_layer(layer, below?)` -- the mirror of `raiseLayer`.
    pub fn lowerLayer(self: *Client, layer: core.LayerHandle, below: ?core.LayerHandle) !void {
        try self.notify("lower_layer", .{ .layer = layer, .below = below });
    }

    /// `write_text(layer, text, fg?, bg?)` on a non-root layer -- see
    /// `writeText` for the root-layer version.
    pub fn writeTextOn(self: *Client, layer: core.LayerHandle, text: []const u8, fg: ?core.Color, bg: ?core.Color) !void {
        try self.notify("write_text", .{
            .layer = layer,
            .text = text,
            .fg = colorToJson(fg),
            .bg = colorToJson(bg),
        });
    }

    /// `write_text(layer, text, fg?, transparent_bg: true)` on a non-root
    /// layer -- see `writeTextTransparent` for the root-layer version.
    pub fn writeTextOnTransparent(self: *Client, layer: core.LayerHandle, text: []const u8, fg: ?core.Color) !void {
        try self.notify("write_text", .{
            .layer = layer,
            .text = text,
            .fg = colorToJson(fg),
            .transparent_bg = true,
        });
    }

    /// `draw_box(layer, row?, col?, rows, cols, style)` on a non-root
    /// layer -- see `drawBox` for the root-layer version.
    pub fn drawBoxOn(self: *Client, layer: core.LayerHandle, row: ?usize, col: ?usize, rows: usize, cols: usize, style: []const u8) !void {
        try self.notify("draw_box", .{ .layer = layer, .row = row, .col = col, .rows = rows, .cols = cols, .style = style });
    }

    /// `draw_box(layer, row?, col?, rows, cols, style, mode)` on a
    /// non-root layer -- see `drawBoxStyled` for the root-layer version.
    pub fn drawBoxOnStyled(self: *Client, layer: core.LayerHandle, row: ?usize, col: ?usize, rows: usize, cols: usize, style: []const u8, opts: DrawBoxOpts) !void {
        try self.notify("draw_box", .{
            .layer = layer,
            .row = row,
            .col = col,
            .rows = rows,
            .cols = cols,
            .style = style,
            .mode = @tagName(opts.mode),
        });
    }

    /// `get_cell_metrics` -- a request returning the session's fixed cell
    /// pixel size, for a client computing `draw_image`'s span from an
    /// image's natural pixel dimensions.
    pub fn getCellMetrics(self: *Client) !struct { w: u32, h: u32 } {
        var parsed = try self.request(struct { cell_px_w: u32, cell_px_h: u32 }, "get_cell_metrics", .{});
        defer parsed.deinit();
        return .{ .w = parsed.value.result.cell_px_w, .h = parsed.value.result.cell_px_h };
    }

    // ─── Table ───────────────────────────────────────────────────────────
    //
    // Unlike every draw call above, a table is real server-side state
    // (`core.Table`, a component of the layer it's drawn on) that persists
    // after this client disconnects -- see decisions.md's Table section.
    // These methods are thin, ergonomic wrappers around the
    // `create_table`/`table_set_rows`/`table_set_sort`/`table_set_style`/
    // `destroy_table`/`table_get_state` wire messages: a caller (e.g.
    // glyphwire-ls's `-l`) builds `TableColumnInput`/`TableCellInput`
    // values with plain borrowed slices, no allocation or ownership
    // bookkeeping of its own -- these methods handle serializing them into
    // one request/notification and, for `tableSetRows`, freeing the small
    // temporary array built to shape that request.

    /// A column's shape for `createTable` -- see `core.TableColumn`'s doc
    /// comment for what each field means server-side. `name`/`width` are
    /// the only two fields the whole table.zig prototype's callers ever
    /// needed to think about; everything else defaults to the plain,
    /// unsorted, left-aligned original behavior.
    pub const TableColumnInput = struct {
        name: []const u8,
        kind: core.ColumnKind = .text,
        sortable: bool = false,
        /// Fold ASCII case when sorting a `.text` column -- see
        /// `core.TableColumn.case_insensitive`.
        case_insensitive: bool = false,
        width: usize,
        min_width: usize = 1,
        h_align: core.HAlign = .start,
    };

    pub const TableStyleInput = struct {
        borders: bool = true,
        header_separator: bool = true,
        box_style: []const u8 = "box",
        alt_row_bg: ?core.Color = null,
        header_fg: ?core.Color = null,
        header_bg: ?core.Color = null,
        row_height: usize = 1,
        /// Upper bound in pixels on a body icon's rendered height -- see
        /// `core.TableStyle.max_icon_px`.
        max_icon_px: ?u32 = null,
    };

    /// A cell's sort value -- see `core.SortKey`'s doc comment on why a
    /// column needs one distinct from its display text (a Size column
    /// displays `"1.2 KB"` but should sort on the raw byte count).
    /// Omitted (`TableCellInput.sort_key: null`) falls back to a copy of
    /// `display` server-side.
    pub const SortKeyInput = union(enum) {
        text: []const u8,
        number: f64,
    };

    pub const TableCellInput = struct {
        display: []const u8,
        sort_key: ?SortKeyInput = null,
        /// An icon-registry name (`draw_icon`'s `name` convention) --
        /// resolved server-side, same "fail loud on an unknown name"
        /// treatment `draw_icon` already gets.
        icon: ?[]const u8 = null,
        fg: ?core.Color = null,
        metadata_id: ?core.MetadataHandle = null,
    };

    /// `create_table(layer?, row?, col?, columns, style?)` -- a request.
    /// `row`/`col` default to the layer's current cursor, same convention
    /// `drawBoxStyled`/`drawIconStyled` already use. Returns a fresh
    /// handle for `tableSetRows`/`tableSetSort`/`tableSetStyle`/
    /// `destroyTable`/`tableGetState` -- the table has no rows yet, so
    /// nothing is painted until `tableSetRows`.
    pub fn createTable(
        self: *Client,
        layer: ?core.LayerHandle,
        row: ?usize,
        col: ?usize,
        columns: []const TableColumnInput,
        style: TableStyleInput,
    ) !core.TableHandle {
        const wire_columns = try self.alloc.alloc(protocol.TableColumn, columns.len);
        defer self.alloc.free(wire_columns);
        for (columns, 0..) |c, i| {
            wire_columns[i] = .{
                .name = c.name,
                .kind = @tagName(c.kind),
                .sortable = c.sortable,
                .case_insensitive = c.case_insensitive,
                .width = c.width,
                .min_width = c.min_width,
                .h_align = @tagName(c.h_align),
            };
        }

        var parsed = try self.request(struct { handle: core.TableHandle }, "create_table", .{
            .layer = layer,
            .row = row,
            .col = col,
            .columns = wire_columns,
            .style = tableStyleToJson(style),
        });
        defer parsed.deinit();
        return parsed.value.result.handle;
    }

    /// `destroy_table(layer?, table)` -- a notification. Blanks whatever
    /// the table last painted and frees it server-side.
    pub fn destroyTable(self: *Client, layer: ?core.LayerHandle, table: core.TableHandle) !void {
        try self.notify("destroy_table", .{ .layer = layer, .table = table });
    }

    fn sortKeyToJson(key: ?SortKeyInput) ?std.json.Value {
        const k = key orelse return null;
        return switch (k) {
            .text => |t| .{ .string = t },
            .number => |n| .{ .float = n },
        };
    }

    /// `table_set_rows(layer?, table, rows)` -- a notification. Replaces
    /// every row wholesale, re-sorts per the table's current sort state,
    /// and repaints -- see `core.Table.render`. `rows` is a plain matrix
    /// of borrowed values (`[row][col]`); this only needs a small
    /// temporary array to reshape it into wire JSON, freed before
    /// returning.
    pub fn tableSetRows(self: *Client, layer: ?core.LayerHandle, table: core.TableHandle, rows: []const []const TableCellInput) !void {
        const wire_rows = try self.alloc.alloc([]protocol.TableCell, rows.len);
        defer {
            for (wire_rows) |r| self.alloc.free(r);
            self.alloc.free(wire_rows);
        }
        for (rows, 0..) |row, ri| {
            const wire_row = try self.alloc.alloc(protocol.TableCell, row.len);
            wire_rows[ri] = wire_row;
            for (row, 0..) |c, ci| {
                wire_row[ci] = .{
                    .display = c.display,
                    .sort_key = sortKeyToJson(c.sort_key),
                    .icon = c.icon,
                    .fg = colorToJson(c.fg),
                    .metadata_id = c.metadata_id,
                };
            }
        }
        try self.notify("table_set_rows", .{ .layer = layer, .table = table, .rows = wire_rows });
    }

    /// `table_set_sort(layer?, table, column?, direction?)` -- a
    /// notification. `column: null` or `direction: .none` both mean "back
    /// to insertion order". Repaints immediately -- this is the message a
    /// future sort-aware `glyphwire-shell` click handler would call.
    pub fn tableSetSort(self: *Client, layer: ?core.LayerHandle, table: core.TableHandle, column: ?usize, direction: core.SortDirection) !void {
        try self.notify("table_set_sort", .{
            .layer = layer,
            .table = table,
            .column = column,
            .direction = @tagName(direction),
        });
    }

    /// `table_set_style(layer?, table, style)` -- a notification. Replaces
    /// the table's whole style (e.g. toggling `alt_row_bg` on/off) and
    /// repaints.
    pub fn tableSetStyle(self: *Client, layer: ?core.LayerHandle, table: core.TableHandle, style: TableStyleInput) !void {
        try self.notify("table_set_style", .{ .layer = layer, .table = table, .style = tableStyleToJson(style) });
    }

    /// Where a table last painted, relative to its own layer -- see
    /// `core.Table.painted`'s doc comment. `row + rows` is the first row
    /// below the whole table (border and all, if bordered), for a caller
    /// that wants to place its own next content there instead of
    /// overwriting the table -- e.g. `glyphwire-ls -l`'s next shell
    /// prompt.
    pub const TablePainted = struct {
        row: usize,
        col: usize,
        rows: usize,
        cols: usize,
    };

    pub const TableState = struct {
        row_count: usize,
        sort_column: ?usize,
        sort_direction: []const u8,
        row_height: usize,
        painted: TablePainted,
        revision: u64,
    };

    /// `table_get_state(layer?, table)` -- a request. Reads back a
    /// table's row count, sort state, `row_height`, painted extent, and
    /// revision -- not its rendered cells, already readable through the
    /// owning layer's normal `getCells` (a table paints into ordinary
    /// cells).
    pub fn tableGetState(self: *Client, layer: ?core.LayerHandle, table: core.TableHandle) !TableState {
        var parsed = try self.request(protocol.TableStateResult, "table_get_state", .{ .layer = layer, .table = table });
        defer parsed.deinit();
        const r = parsed.value.result;
        return .{
            .row_count = r.row_count,
            .sort_column = r.sort_column,
            .sort_direction = r.sort_direction,
            .row_height = r.style.row_height,
            .painted = .{ .row = r.painted.row, .col = r.painted.col, .rows = r.painted.rows, .cols = r.painted.cols },
            .revision = r.revision,
        };
    }

    /// `create_metadata(json)` -- a request. Stores `json` verbatim (the
    /// server never parses it, only stores/returns it -- see decisions.md's
    /// Metadata section) and returns a fresh handle that
    /// `writeTextTagged`/`drawIconStyled`'s `metadata_id`, `getMetadata`,
    /// or `destroyMetadata` can reference.
    pub fn createMetadata(self: *Client, json: []const u8) !core.MetadataHandle {
        var parsed = try self.request(struct { handle: core.MetadataHandle }, "create_metadata", .{ .json = json });
        defer parsed.deinit();
        return parsed.value.result.handle;
    }

    /// `destroy_metadata(id)` -- a notification. Frees `id`'s stored JSON;
    /// any cell still tagged with it afterward is left with a dangling
    /// reference -- `getMetadata` resolves that gracefully (reports the
    /// id, `json: null`) rather than erroring. There's no reference
    /// counting yet, so this is the caller's responsibility to get right.
    pub fn destroyMetadata(self: *Client, id: core.MetadataHandle) !void {
        try self.notify("destroy_metadata", .{ .id = id });
    }

    /// `get_metadata(layer?, row, col)` -- a request. Resolves `(row, col)`
    /// to a cell (root layer when `layer` is omitted) and returns its
    /// `metadata_id` plus that id's stored JSON -- the pair a mouse-click
    /// handler needs to both resolve "what's tagged here" and know the id
    /// for a later `destroyMetadata` or comparison. `json`, if non-null,
    /// is a fresh copy the caller owns (free with this Client's
    /// allocator) -- unlike `CellsSnapshot`, there's no borrowed-data
    /// wrapper to keep alive for a single scalar lookup like this.
    /// `view_offset` resolves `(row, col)` against that many rows of
    /// scrollback above the live viewport (see `core.Layer.viewRow`) --
    /// pass 0 for the live viewport, or the `view_offset` from a
    /// `mouse_button` event so a click made while scrolled back lands on
    /// the row actually under the pointer.
    pub fn getMetadata(self: *Client, layer: ?core.LayerHandle, row: usize, col: usize, view_offset: usize) !struct { id: ?core.MetadataHandle, json: ?[]u8 } {
        var parsed = try self.request(struct { id: ?core.MetadataHandle, json: ?[]const u8 }, "get_metadata", .{ .layer = layer, .row = row, .col = col, .view_offset = view_offset });
        defer parsed.deinit();
        const json = if (parsed.value.result.json) |j| try self.alloc.dupe(u8, j) else null;
        return .{ .id = parsed.value.result.id, .json = json };
    }

    /// `get_input_state` -- a request returning which keys/mouse buttons
    /// are currently down and the last known cursor position. A one-time
    /// bootstrap query; `InputListener` is the live-updating counterpart.
    /// Owns its own parsed JSON arena; caller must call `.deinit()`.
    pub fn getInputState(self: *Client) !InputStateSnapshot {
        const parsed = try self.request(protocol.InputStateResult, "get_input_state", .{});
        return .{ .parsed = parsed };
    }

    // ── Selection & clipboard ──────────────────────────────────────────

    /// `set_selection(layer?, anchor, active)` -- a notification. Starts
    /// or replaces the layer's selection (root when `layer` is omitted).
    /// Points are `{above, col}` in the scroll-stable coordinate
    /// `core.SelectionPoint` documents.
    pub fn setSelection(self: *Client, layer: ?core.LayerHandle, anchor: core.SelectionPoint, active: core.SelectionPoint) !void {
        try self.notify("set_selection", .{
            .layer = layer,
            .anchor = .{ .above = anchor.above, .col = anchor.col },
            .active = .{ .above = active.above, .col = active.col },
        });
    }

    /// `update_selection(layer?, active)` -- a notification. Moves only
    /// the active (dragging) end; a no-op if nothing is selected.
    pub fn updateSelection(self: *Client, layer: ?core.LayerHandle, active: core.SelectionPoint) !void {
        try self.notify("update_selection", .{
            .layer = layer,
            .active = .{ .above = active.above, .col = active.col },
        });
    }

    /// `clear_selection(layer?)` -- a notification.
    pub fn clearSelection(self: *Client, layer: ?core.LayerHandle) !void {
        try self.notify("clear_selection", .{ .layer = layer });
    }

    /// `get_selection(layer?)` -- a request. `active` false means nothing
    /// is selected (`anchor`/`active_end` null then).
    pub fn getSelection(self: *Client, layer: ?core.LayerHandle) !protocol.SelectionState {
        var parsed = try self.request(protocol.SelectionState, "get_selection", .{ .layer = layer });
        defer parsed.deinit();
        const r = parsed.value.result;
        return .{
            .active = r.active,
            .anchor = if (r.anchor) |a| .{ .above = a.above, .col = a.col } else null,
            .active_end = if (r.active_end) |a| .{ .above = a.above, .col = a.col } else null,
        };
    }

    /// `get_selection_text(layer?)` -- a request. Returns the selected
    /// text (empty string when nothing is selected); caller owns it, free
    /// with this Client's allocator.
    pub fn getSelectionText(self: *Client, layer: ?core.LayerHandle) ![]u8 {
        var parsed = try self.request(struct { text: []const u8 }, "get_selection_text", .{ .layer = layer });
        defer parsed.deinit();
        return try self.alloc.dupe(u8, parsed.value.result.text);
    }

    /// `toggle_highlight(layer?, row, col, view_offset?)` -- a request.
    /// Resolves `(row, col)` to a cell (in the view scrolled back by
    /// `view_offset`), flips that cell's `metadata_id` in the layer's
    /// highlight set, and returns the resulting `HighlightState`. A cell
    /// with no tag leaves the set unchanged. Caller owns the snapshot --
    /// call `.deinit()`.
    pub fn toggleHighlight(self: *Client, layer: ?core.LayerHandle, row: usize, col: usize, view_offset: usize) !HighlightSnapshot {
        return .{ .parsed = try self.request(protocol.HighlightState, "toggle_highlight", .{
            .layer = layer,
            .row = row,
            .col = col,
            .view_offset = view_offset,
        }) };
    }

    /// `set_highlight(layer?, ids)` -- a request. Replaces the layer's
    /// whole highlighted-id set with `ids` (empty clears it) and returns
    /// the resulting `HighlightState`. Caller owns the snapshot.
    pub fn setHighlight(self: *Client, layer: ?core.LayerHandle, ids: []const core.MetadataHandle) !HighlightSnapshot {
        return .{ .parsed = try self.request(protocol.HighlightState, "set_highlight", .{ .layer = layer, .ids = ids }) };
    }

    /// `clear_highlight(layer?)` -- a request. Drops every highlighted id
    /// and returns the (now empty) `HighlightState`. Caller owns the
    /// snapshot.
    pub fn clearHighlight(self: *Client, layer: ?core.LayerHandle) !HighlightSnapshot {
        return .{ .parsed = try self.request(protocol.HighlightState, "clear_highlight", .{ .layer = layer }) };
    }

    /// `get_highlight(layer?)` -- a request. The layer's current
    /// `HighlightState`, unchanged. Caller owns the snapshot.
    pub fn getHighlight(self: *Client, layer: ?core.LayerHandle) !HighlightSnapshot {
        return .{ .parsed = try self.request(protocol.HighlightState, "get_highlight", .{ .layer = layer }) };
    }

    /// `set_clipboard(text)` -- a notification. Replaces the session
    /// clipboard buffer; glyphwire-host mirrors it to the OS clipboard.
    pub fn setClipboard(self: *Client, text: []const u8) !void {
        try self.notify("set_clipboard", .{ .text = text });
    }

    /// `get_clipboard()` -- a request. Returns the session clipboard
    /// buffer (see `core.Context.clipboard` for its freshness caveat on
    /// glyphwire-host); caller owns the result.
    pub fn getClipboard(self: *Client) ![]u8 {
        var parsed = try self.request(struct { text: []const u8 }, "get_clipboard", .{});
        defer parsed.deinit();
        return try self.alloc.dupe(u8, parsed.value.result.text);
    }

    /// `get_errors()` -- a request. Returns, and drains, this connection's
    /// ring of recent failed notifications (see `ErrorReport`). Only
    /// meaningful after `subscribe(&.{"error"})` on this same connection --
    /// otherwise the server records nothing and this always comes back
    /// empty. A notification (`writeText`, `destroyLayer`, ...) that the
    /// server rejects is otherwise silent; poll this between batches of
    /// work to notice one, and check `dropped` to see if the ring
    /// overflowed since the last call.
    pub fn getErrors(self: *Client) !ErrorReport {
        return .{ .parsed = try self.request(protocol.ErrorsResult, "get_errors", .{}) };
    }

    fn colorToJson(c: ?core.Color) ?protocol.Color {
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
        try self.frameAndFlush(body);
    }

    /// Frames one already-serialized JSON-RPC body and flushes it to the
    /// socket. Split out of `send` so `Batch.send` can hand over a body it
    /// assembled itself (splicing pre-validated sub-message objects into
    /// one `batch` message) rather than round-tripping through
    /// `Stringify.valueAlloc` again.
    fn frameAndFlush(self: *Client, body: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        try wire.writeFrame(&w.interface, body);
        try w.interface.flush();
    }

    /// Starts a `batch`: a set of sub-messages sent in one frame and
    /// applied server-side under a single lock hold, so nothing renders a
    /// half-updated grid partway through -- see decisions.md's Batch
    /// section, and `Batch` below for the builder API. The returned
    /// `Batch` borrows this `Client` (for the socket and `next_id`);
    /// add sub-messages, call `send` once, then `Batch.deinit`.
    pub fn batch(self: *Client) Batch {
        return .{
            .client = self,
            .arena = std.heap.ArenaAllocator.init(self.alloc),
            .msgs = .empty,
        };
    }

    /// Accumulates sub-messages for one `batch` frame. Notification
    /// adders (`notify` and the typed conveniences) append fire-and-forget
    /// sub-messages; request adders (`request`, `createMetadata`) append a
    /// sub-message carrying a batch-local id and hand back a `Slot` to
    /// pull that sub-message's result out of `send`'s `BatchResults`.
    ///
    /// Every adder serializes its sub-message immediately into the
    /// `Batch`'s own arena, so a caller may reuse the buffers backing
    /// `text`/`json`/etc. the moment the adder returns -- the bytes are
    /// already copied into the pending JSON. `send` splices the pending
    /// sub-message objects into one `batch` message; if any request
    /// adders were used it then reads and parses the one response frame,
    /// otherwise it sends notification-form and returns immediately.
    pub const Batch = struct {
        client: *Client,
        arena: std.heap.ArenaAllocator,
        msgs: std.ArrayList([]const u8),
        n_requests: u32 = 0,

        /// A handle to one request sub-message's eventual result -- see
        /// `BatchResults.get`/`metadataHandle`. `id` is the sub-message's
        /// batch-local id (1-based, in add order among request adders).
        pub const Slot = struct { id: u32 };

        pub fn deinit(self: *Batch) void {
            self.arena.deinit();
        }

        fn append(self: *Batch, sub_id: ?u32, method: []const u8, params: anytype) !void {
            const a = self.arena.allocator();
            const s = if (sub_id) |sid|
                try std.json.Stringify.valueAlloc(a, .{ .method = method, .params = params, .id = sid }, .{})
            else
                try std.json.Stringify.valueAlloc(a, .{ .method = method, .params = params }, .{});
            try self.msgs.append(a, s);
        }

        /// Appends a notification sub-message (no result). `method`/
        /// `params` are the same pair `Client`'s own notification methods
        /// build -- this is the generic escape hatch for anything without
        /// a typed convenience below.
        pub fn notify(self: *Batch, method: []const u8, params: anytype) !void {
            try self.append(null, method, params);
        }

        /// Appends a request sub-message and returns its `Slot`. `method`/
        /// `params` mirror `Client.request`'s. The result comes back in
        /// `send`'s `BatchResults`, keyed by the returned slot.
        pub fn request(self: *Batch, method: []const u8, params: anytype) !Slot {
            self.n_requests += 1;
            const sub_id = self.n_requests;
            try self.append(sub_id, method, params);
            return .{ .id = sub_id };
        }

        /// Batched `set_property(cursor)` -- see `Client.setCursor`.
        pub fn setCursor(self: *Batch, row: usize, col: usize) !void {
            try self.notify("set_property", .{ .property = "cursor", .row = row, .col = col });
        }

        /// Batched `clear` -- see `Client.clear`. `rows`/`cols` null means
        /// "the rest of the layer from `row`/`col`".
        pub fn clear(self: *Batch, row: usize, col: usize, rows: ?usize, cols: ?usize) !void {
            try self.notify("clear", .{ .row = row, .col = col, .rows = rows, .cols = cols });
        }

        /// Batched `write_text` -- see `Client.writeText`.
        pub fn writeText(self: *Batch, text: []const u8, fg: ?core.Color, bg: ?core.Color) !void {
            try self.notify("write_text", .{ .text = text, .fg = Client.colorToJson(fg), .bg = Client.colorToJson(bg) });
        }

        /// Batched `write_text` with a metadata tag -- see
        /// `Client.writeTextTagged`.
        pub fn writeTextTagged(self: *Batch, text: []const u8, fg: ?core.Color, bg: ?core.Color, metadata_id: core.MetadataHandle) !void {
            try self.notify("write_text", .{ .text = text, .fg = Client.colorToJson(fg), .bg = Client.colorToJson(bg), .metadata_id = metadata_id });
        }

        /// Batched `write_text(text, fg?, transparent_bg: true)` -- see
        /// `Client.writeTextTransparent`.
        pub fn writeTextTransparent(self: *Batch, text: []const u8, fg: ?core.Color) !void {
            try self.notify("write_text", .{ .text = text, .fg = Client.colorToJson(fg), .transparent_bg = true });
        }

        /// Batched `tag_metadata` -- see `Client.tagMetadata`.
        pub fn tagMetadata(self: *Batch, layer: ?core.LayerHandle, row: usize, col: usize, metadata_id: core.MetadataHandle) !void {
            try self.notify("tag_metadata", .{ .layer = layer, .row = row, .col = col, .metadata_id = metadata_id });
        }

        /// Batched `move_content` -- see `Client.moveContentOn`. `null`
        /// `top`/`bot` means the whole content grid.
        pub fn moveContent(
            self: *Batch,
            layer: ?core.LayerHandle,
            top: ?usize,
            bot: ?usize,
            count: usize,
            direction: core.Layer.ScrollDir,
        ) !void {
            try self.notify("move_content", .{
                .layer = layer,
                .top = top,
                .bot = bot,
                .count = count,
                .direction = @tagName(direction),
            });
        }

        /// Batched `draw_icon` with options -- see `Client.drawIconStyled`.
        pub fn drawIconStyled(self: *Batch, row: ?usize, col: ?usize, name: []const u8, opts: DrawIconOpts) !void {
            try self.notify("draw_icon", .{
                .row = row,
                .col = col,
                .name = name,
                .scale = @tagName(opts.scale),
                .h_align = @tagName(opts.h_align),
                .v_align = @tagName(opts.v_align),
                .max_w = opts.max_w,
                .max_h = opts.max_h,
                .metadata_id = opts.metadata_id,
                .foreground = opts.foreground,
            });
        }

        /// Batched `create_metadata` -- see `Client.createMetadata`.
        /// Resolve the returned slot with `BatchResults.metadataHandle`.
        pub fn createMetadata(self: *Batch, json: []const u8) !Slot {
            return self.request("create_metadata", .{ .json = json });
        }

        /// Sends the batch. With no request adders used, sends
        /// notification-form (no `id`, no reply) and returns an empty
        /// `BatchResults`. Otherwise sends request-form using the
        /// `Client`'s `next_id` for the outer id, then reads and parses
        /// the single response frame. Caller frees with
        /// `BatchResults.deinit`.
        pub fn send(self: *Batch) !BatchResults {
            const a = self.arena.allocator();
            var bw = std.Io.Writer.Allocating.init(a);
            const has_requests = self.n_requests > 0;

            try bw.writer.writeAll("{\"jsonrpc\":\"2.0\",");
            if (has_requests) {
                const outer_id = self.client.next_id;
                self.client.next_id += 1;
                try bw.writer.print("\"id\":{d},", .{outer_id});
            }
            try bw.writer.writeAll("\"method\":\"batch\",\"params\":{\"messages\":[");
            for (self.msgs.items, 0..) |m, i| {
                if (i != 0) try bw.writer.writeAll(",");
                try bw.writer.writeAll(m);
            }
            try bw.writer.writeAll("]}}");

            try self.client.frameAndFlush(bw.written());

            if (!has_requests) return .{ .parsed = null, .arena = std.heap.ArenaAllocator.init(self.client.alloc) };

            const resp_body = try self.client.readFrame();
            defer self.client.alloc.free(resp_body);
            const parsed = try std.json.parseFromSlice(BatchResponseEnvelope, self.client.alloc, resp_body, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            return .{ .parsed = parsed, .arena = std.heap.ArenaAllocator.init(self.client.alloc) };
        }
    };

    /// Reads and returns exactly one complete frame's body (caller frees
    /// with `self.alloc`), blocking on the socket until one arrives or
    /// `read_timeout` elapses (`error.Timeout`) -- see that field. Routed
    /// through `io.operateTimeout` rather than `stream.read` so the
    /// deadline actually bounds the syscall; `stream.read` has no timeout
    /// form.
    fn readFrame(self: *Client) ![]u8 {
        while (true) {
            if (try self.decoder.next(self.alloc)) |body| return body;

            var read_buf: [4096]u8 = undefined;
            var data: [1][]u8 = .{&read_buf};
            const n = try (try self.io.operateTimeout(.{ .net_read = .{
                .socket_handle = self.stream.socket.handle,
                .data = &data,
            } }, self.read_timeout)).net_read;
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

/// The outer shape of a request-form `batch` response:
/// `{result: {responses: [<response object>, ...]}}`. Each element is a
/// whole JSON-RPC response object carrying a sub-message's batch-local
/// `id`; `BatchResults` scans them by id. Left loosely typed
/// (`std.json.Value` per element) since the element result types are
/// heterogeneous and only re-parsed on demand by `BatchResults.get`.
const BatchResponseEnvelope = struct {
    result: struct {
        responses: []const std.json.Value = &.{},
    } = .{},
};

/// The result side of `Client.Batch.send`. `deinit` frees it. For a
/// notification-form batch (no request adders) it's empty and every
/// lookup returns `error.BatchResultMissing`.
pub const BatchResults = struct {
    parsed: ?std.json.Parsed(BatchResponseEnvelope),
    /// Backs the on-demand re-parse in `get` -- kept separate from
    /// `parsed`'s own arena so this type owns a definite allocator even
    /// in the notification-form (`parsed == null`) case.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *BatchResults) void {
        if (self.parsed) |*p| p.deinit();
        self.arena.deinit();
    }

    fn element(self: *const BatchResults, slot: Client.Batch.Slot) ?std.json.Value {
        const p = self.parsed orelse return null;
        for (p.value.result.responses) |resp| {
            const obj = switch (resp) {
                .object => |o| o,
                else => continue,
            };
            const id_value = obj.get("id") orelse continue;
            const id_int: i64 = switch (id_value) {
                .integer => |n| n,
                else => continue,
            };
            if (id_int == @as(i64, slot.id)) return resp;
        }
        return null;
    }

    /// Re-parses the response element for `slot` as `{result: T}` and
    /// returns the `result`. `T` follows `std.json` parsing rules; a
    /// scalar or owned-by-arena value is safe to use until `deinit`.
    /// Errors `BatchResultMissing` if the slot produced no response (it
    /// failed server-side, or the batch was notification-form).
    pub fn get(self: *BatchResults, comptime T: type, slot: Client.Batch.Slot) !T {
        const resp = self.element(slot) orelse return error.BatchResultMissing;
        const Wrapped = struct { result: T };
        const w = try std.json.parseFromValueLeaky(Wrapped, self.arena.allocator(), resp, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        return w.result;
    }

    /// Convenience for the common `create_metadata` slot: returns just
    /// the `MetadataHandle`.
    pub fn metadataHandle(self: *BatchResults, slot: Client.Batch.Slot) !core.MetadataHandle {
        const r = try self.get(struct { handle: core.MetadataHandle }, slot);
        return r.handle;
    }
};

/// The wire shapes this file builds requests from and parses responses
/// into all live in `protocol.zig`, shared verbatim with `dispatch.zig`
/// so the two ends can't drift. `tableStyleToJson` is the one bit of
/// client-only glue left here: it flattens the ergonomic
/// `Client.TableStyleInput` (real `core.Color` / enum fields) down to the
/// wire `protocol.TableStyle`.
fn tableStyleToJson(s: Client.TableStyleInput) protocol.TableStyle {
    return .{
        .borders = s.borders,
        .header_separator = s.header_separator,
        .box_style = s.box_style,
        .alt_row_bg = Client.colorToJson(s.alt_row_bg),
        .header_fg = Client.colorToJson(s.header_fg),
        .header_bg = Client.colorToJson(s.header_bg),
        .row_height = s.row_height,
        .max_icon_px = s.max_icon_px,
    };
}

/// A cell in renderer-friendly form: `core.Color`/`core.ImageBg` fields
/// instead of raw JSON. Exactly one of `bg`/`bg_image`/`bg_icon` is
/// non-null, mirroring `core.Background`'s tagged union. `fg_icon` (an
/// icon composited over the background -- `draw_icon`'s `foreground: true`
/// and every table body icon) and `metadata_id` are siblings of that
/// union, not part of it -- see `core.Cell`'s doc comment.
pub const RenderCell = struct {
    grapheme: []const u8,
    fg: core.Color,
    bg: ?core.Color,
    bg_image: ?core.ImageBg = null,
    bg_icon: ?core.IconBg = null,
    fg_icon: ?core.IconBg = null,
    metadata_id: ?core.MetadataHandle = null,
    /// `.wide_lead` = left half of a 2-cell wide character (holds the
    /// grapheme), `.wide_spacer` = its blank right half, `.narrow` = an
    /// ordinary 1-cell character.
    wide: core.CellWidth = .narrow,
};

/// Owns the parsed JSON backing a `getCells` response; `deinit` frees it.
/// `cellAt` is a cheap view into that backing data, not a copy -- don't
/// hold onto a `RenderCell` past the snapshot's `deinit()`.
pub const CellsSnapshot = struct {
    parsed: std.json.Parsed(ResponseOf(protocol.CellsResult)),

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
            .bg_icon = if (c.bg_icon) |icon| .{
                .handle = icon.handle,
                .scale = std.meta.stringToEnum(core.IconScale, icon.scale) orelse .fit,
                .h_align = std.meta.stringToEnum(core.HAlign, icon.h_align) orelse .center,
                .v_align = std.meta.stringToEnum(core.VAlign, icon.v_align) orelse .center,
                .max_w = icon.max_w,
                .max_h = icon.max_h,
            } else null,
            .fg_icon = if (c.fg_icon) |icon| .{
                .handle = icon.handle,
                .scale = std.meta.stringToEnum(core.IconScale, icon.scale) orelse .fit,
                .h_align = std.meta.stringToEnum(core.HAlign, icon.h_align) orelse .center,
                .v_align = std.meta.stringToEnum(core.VAlign, icon.v_align) orelse .center,
                .max_w = icon.max_w,
                .max_h = icon.max_h,
            } else null,
            .metadata_id = c.metadata_id,
            .wide = blk: {
                const w = c.wide orelse break :blk .narrow;
                if (std.mem.eql(u8, w, "lead")) break :blk .wide_lead;
                if (std.mem.eql(u8, w, "spacer")) break :blk .wide_spacer;
                break :blk .narrow;
            },
        };
    }
};

/// Owns the parsed JSON backing a `get_errors` response. `entries()` and
/// each entry's strings borrow that arena, so keep the report alive while
/// reading it; `deinit` frees it. See `Client.getErrors`.
pub const ErrorReport = struct {
    parsed: std.json.Parsed(ResponseOf(protocol.ErrorsResult)),

    pub fn deinit(self: *ErrorReport) void {
        self.parsed.deinit();
    }

    /// The buffered failed-notification records, oldest first.
    pub fn entries(self: *const ErrorReport) []const protocol.DispatchErrorEntry {
        return self.parsed.value.result.errors;
    }

    /// How many records were lost to a full ring since the previous
    /// `get_errors` on this connection.
    pub fn dropped(self: *const ErrorReport) u64 {
        return self.parsed.value.result.dropped;
    }
};

/// Owns the parsed JSON backing a `toggle_highlight` / `set_highlight` /
/// `clear_highlight` / `get_highlight` response. `entries()` borrows that
/// arena, so keep the snapshot alive while reading it; `deinit` frees it.
pub const HighlightSnapshot = struct {
    parsed: std.json.Parsed(ResponseOf(protocol.HighlightState)),

    pub fn deinit(self: *HighlightSnapshot) void {
        self.parsed.deinit();
    }

    /// Every currently highlighted metadata id on the layer, each with its
    /// stored JSON blob (`json` null for a dangling id).
    pub fn entries(self: *const HighlightSnapshot) []const protocol.HighlightEntry {
        return self.parsed.value.result.entries;
    }
};

/// Owns the parsed JSON backing a `getInputState` response; `deinit`
/// frees it. A one-time snapshot -- see `InputListener` for a
/// live-updating equivalent.
pub const InputStateSnapshot = struct {
    parsed: std.json.Parsed(ResponseOf(protocol.InputStateResult)),

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
/// `key_up`/`text`/`mouse_button`/`resize`/`scroll` notifications and
/// updates local, mutex-guarded caches and queues -- so
/// `isKeyDown`/`isMouseButtonDown`/`cursorPixel`/`cursorCell` are instant
/// local reads, and `pollInputEvent`/`waitInputEvent` (key + text, one
/// order) drain without a round trip per call.
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
/// enter", exactly once). `key` is owned; free it with the same allocator
/// passed to `InputListener.connect`.
pub const KeyEvent = struct { key: []const u8, pressed: bool };
/// One queued `text` notification: committed text input (`text` is a
/// UTF-8 string of one or more codepoints). `text` is owned -- free it
/// with the same allocator passed to `InputListener.connect`. Distinct
/// from `KeyEvent`: this is what the user typed, not which physical key
/// moved -- the only correct source for a non-US layout, an AltGr combo
/// or CJK IME composition.
pub const TextEvent = struct { text: []const u8 };
/// A key or text event, in the one order they arrived off the wire.
/// `key` and `text` share a timeline -- the host sends `key_down enter`
/// and the `text` for what preceded it on the same connection -- so a
/// line editor has to consume them from a single ordered queue
/// (`pollInputEvent` / `waitInputEvent`), not two, or "type then Enter"
/// races. Each variant owns its string, freed like the standalone
/// events above.
pub const InputEvent = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    /// One `paste` notification: committed clipboard text to insert
    /// (`text` owned, freed like `text`). Kept on the same ordered queue
    /// as `key`/`text` so it lands in the line at the caret position it
    /// was pasted at. Distinct from `text` so a consumer can treat it
    /// differently -- glyphwire-shell inserts it literally, newlines and
    /// all, without submitting.
    paste: TextEvent,
    /// One `copy_request` notification: the user pressed the copy
    /// shortcut with nothing selected. No payload -- the consumer answers
    /// by calling `Client.setClipboard` with whatever it wants copied
    /// (glyphwire-shell: the current prompt line).
    copy_request,
    /// One `shutdown` notification: the host window is closing. No owned
    /// memory. glyphwire-shell treats it like a typed `exit` -- flush
    /// persistent state, then return from its prompt loop.
    shutdown: ShutdownEvent,

    /// Frees the owned string for whichever variant this is.
    pub fn deinit(self: InputEvent, alloc: std.mem.Allocator) void {
        switch (self) {
            .key => |k| alloc.free(k.key),
            .text => |t| alloc.free(t.text),
            .paste => |t| alloc.free(t.text),
            .copy_request => {},
            .shutdown => {},
        }
    }
};
pub const MouseButtonEvent = struct {
    button: []const u8,
    pressed: bool,
    px: PxPos,
    cell: CellPos,
    /// Root layer's scrollback view offset at click time (see
    /// `core.Layer.view_scroll`) -- feed this straight into
    /// `Client.getMetadata`'s `view_offset` so a click made while the host
    /// is scrolled back resolves to the row actually under the pointer.
    view_offset: usize = 0,

    /// Frees the owned `.button` string, like `InputEvent.deinit`. Every
    /// drained event owns its own copy (the listener dupes it per
    /// notification), so a consumer that pops without freeing leaks one
    /// string per press *and* release.
    pub fn deinit(self: MouseButtonEvent, alloc: std.mem.Allocator) void {
        alloc.free(self.button);
    }
};
/// One `mouse_move` notification: the pointer's new pixel + cell
/// position. No owned memory -- handed back by value like `ResizeEvent`.
/// Only arrives on a cell change (the server coalesces per-pixel motion).
pub const MouseMoveEvent = struct { px: PxPos, cell: CellPos };
/// One `resize` notification: the window's new size in cells. No owned
/// memory (unlike `KeyEvent.key`), so `pollResizeEvent` hands it back by
/// value with nothing for the caller to free.
pub const ResizeEvent = struct { cols: usize, rows: usize };

/// One `shutdown` notification: the host window is closing. `grace_ms` is
/// roughly how long the host waits for this process to exit before it
/// tears down anyway. No owned memory. Delivered on the same ordered
/// queue as key/text (`InputEvent.shutdown`) so a consumer sees it in
/// line with the input it has already queued.
pub const ShutdownEvent = struct { grace_ms: u32 };

/// `get_property(layer, "scroll_offset")`'s result -- where the viewport
/// sits and how far it can go on each axis.
pub const ScrollOffsetState = struct {
    row: usize,
    col: usize,
    max_row: usize,
    max_col: usize,
};

/// One `set_split_children` entry, in the shape the wire wants: exactly
/// one of `layer`/`split`, and at most one of `weight`/`fixed`. The
/// constructors below are the ergonomic way to build them.
pub const SplitChildInput = struct {
    layer: ?core.LayerHandle = null,
    split: ?core.SplitHandle = null,
    weight: ?f32 = null,
    fixed: ?usize = null,

    /// A layer taking a share of whatever the fixed siblings leave.
    pub fn layerWeighted(handle: core.LayerHandle, weight: f32) SplitChildInput {
        return .{ .layer = handle, .weight = weight };
    }

    /// A layer with an exact extent along the split's axis -- a one-row
    /// statusline, a fixed-width gutter.
    pub fn layerFixed(handle: core.LayerHandle, cells: usize) SplitChildInput {
        return .{ .layer = handle, .fixed = cells };
    }

    /// A nested split taking a share.
    pub fn splitWeighted(handle: core.SplitHandle, weight: f32) SplitChildInput {
        return .{ .split = handle, .weight = weight };
    }

    /// A nested split with an exact extent.
    pub fn splitFixed(handle: core.SplitHandle, cells: usize) SplitChildInput {
        return .{ .split = handle, .fixed = cells };
    }
};

/// A `scroll_offset` notification: a layer's viewport moved over its
/// content grid (the host's wheel or scrollbar, or another client's
/// `set_property`). Carries the handle, unlike `ScrollEvent`, which is
/// always the root layer's scrollback.
pub const ScrollOffsetEvent = struct {
    layer: core.LayerHandle,
    row: usize,
    col: usize,
    max_row: usize,
    max_col: usize,
};

/// One pane's bounds from a `layout` notification.
pub const LayoutBounds = struct {
    layer: core.LayerHandle,
    row: usize,
    col: usize,
    cols: usize,
    rows: usize,
};

/// A `layout` notification: every pane whose bounds changed after the
/// split tree was re-laid-out. Owns `layers`; `pollLayoutEvent` hands
/// ownership to the caller, which must call `deinit`.
pub const LayoutEvent = struct {
    layers: []LayoutBounds,

    pub fn deinit(self: LayoutEvent, alloc: std.mem.Allocator) void {
        alloc.free(self.layers);
    }

    /// This event's bounds for `layer`, or null if it wasn't in it.
    pub fn boundsFor(self: LayoutEvent, layer: core.LayerHandle) ?LayoutBounds {
        for (self.layers) |b| {
            if (b.layer == layer) return b;
        }
        return null;
    }
};
/// One `scroll` notification: the root layer's scrollback view offset
/// (`offset` rows shown above the live viewport, out of `max` retained).
/// No owned memory -- handed back by value like `ResizeEvent`.
pub const ScrollEvent = struct { offset: usize, max: usize };

/// One `context` notification: the now-visible context's handle and the
/// size of its root layer. A client that manages its own context
/// compares `context` against its own handle to tell "I'm on screen"
/// from "I've been backgrounded (or culled)". No owned memory.
pub const ContextEvent = struct { context: core.ContextHandle, cols: usize, rows: usize };

pub const InputListener = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    stream: std.Io.net.Stream,
    listen_thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    state: core.InputState,
    /// Key and text events in a single arrival-ordered queue (see
    /// `InputEvent`) -- they share one timeline on the wire, so keeping
    /// two queues would let "type then Enter" reorder. `input_sem` is
    /// posted once per append so `waitInputEvent` can block instead of
    /// polling; it isn't kept in exact sync with the queue length
    /// (`pollInputEvent` drains without touching it) -- a stale permit
    /// just wakes one `waitInputEvent` to an empty queue, no worse than a
    /// spurious poll.
    input_events: std.ArrayList(InputEvent) = .empty,
    input_sem: std.Io.Semaphore = .{},
    /// Edge events (button-down and button-up, like `key_events`), not
    /// just the level state `isMouseButtonDown`/`cursorCell` already
    /// tracked -- a click handler (e.g. glyphwire-shell's auto-cd) needs
    /// to know *when* a press happened, not just whether the button is
    /// currently down.
    mouse_events: std.ArrayList(MouseButtonEvent) = .empty,
    mouse_sem: std.Io.Semaphore = .{},
    /// Queued `mouse_move` notifications, same drain-on-poll shape. Motion
    /// is high-rate even after the server's per-cell coalescing, so the
    /// queue is capped: a consumer that stops draining (the prompt loop,
    /// which doesn't care about motion) makes it drop the backlog rather
    /// than grow without bound. The pty foreground loop is the real
    /// consumer.
    mouse_move_events: std.ArrayList(MouseMoveEvent) = .empty,
    mouse_move_sem: std.Io.Semaphore = .{},
    /// Queued `terminal_reply` notifications: owned byte slices (a
    /// `CSI 6n` / DA / DECRQM answer a mirrored `write_text` produced).
    /// glyphwire-shell drains these and writes them to the pty master.
    /// Freed by the consumer (`pollTerminalReply`) or in `deinit`.
    terminal_reply_events: std.ArrayList([]u8) = .empty,
    terminal_reply_sem: std.Io.Semaphore = .{},
    /// Queued `resize` notifications (see `ResizeEvent`), same
    /// drain-on-poll shape as `key_events`/`mouse_events`. `last_size`
    /// caches the most recent one for `size()`'s instant read; it stays
    /// null until the first `resize` arrives (a client that needs the
    /// size before then should ask `Client.getSize` once).
    resize_events: std.ArrayList(ResizeEvent) = .empty,
    resize_sem: std.Io.Semaphore = .{},
    last_size: ?ResizeEvent = null,
    /// Queued `scroll` notifications (see `ScrollEvent`), same
    /// drain-on-poll shape as `resize_events`. `last_scroll` caches the
    /// most recent one for `scroll()`'s instant read; null until the
    /// first `scroll` arrives.
    scroll_events: std.ArrayList(ScrollEvent) = .empty,
    scroll_sem: std.Io.Semaphore = .{},
    last_scroll: ?ScrollEvent = null,
    /// Queued `scroll_offset` notifications -- a *layer's* viewport
    /// moving over its content, as opposed to `scroll_events`' root
    /// scrollback. Same drain-on-poll shape; no owned memory.
    scroll_offset_events: std.ArrayList(ScrollOffsetEvent) = .empty,
    scroll_offset_sem: std.Io.Semaphore = .{},
    /// Queued `layout` notifications. Each owns its `layers` slice, so an
    /// undrained queue is freed in `deinit` and a drained one transfers
    /// ownership to the caller (`pollLayoutEvent`).
    layout_events: std.ArrayList(LayoutEvent) = .empty,
    layout_sem: std.Io.Semaphore = .{},
    /// Queued `context` notifications (see `ContextEvent`), same
    /// drain-on-poll shape as `resize_events`. `last_context` caches the
    /// most recent for `visibleContext()`'s instant read; null until the
    /// first `context` arrives. Only produced while subscribed to
    /// `"context"`.
    context_events: std.ArrayList(ContextEvent) = .empty,
    context_sem: std.Io.Semaphore = .{},
    last_context: ?ContextEvent = null,

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
        for (self.input_events.items) |ev| ev.deinit(self.alloc);
        self.input_events.deinit(self.alloc);
        for (self.mouse_events.items) |ev| self.alloc.free(ev.button);
        self.mouse_events.deinit(self.alloc);
        self.mouse_move_events.deinit(self.alloc);
        for (self.terminal_reply_events.items) |b| self.alloc.free(b);
        self.terminal_reply_events.deinit(self.alloc);
        self.resize_events.deinit(self.alloc);
        self.scroll_offset_events.deinit(self.alloc);
        for (self.layout_events.items) |ev| ev.deinit(self.alloc);
        self.layout_events.deinit(self.alloc);
        self.scroll_events.deinit(self.alloc);
        self.context_events.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn isKeyDown(self: *InputListener, key: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.isKeyDown(key);
    }

    /// Pops the oldest queued input event (key or text), if any
    /// (non-blocking). Caller must free the variant's owned string --
    /// `InputEvent.deinit`, or free `.key.key` / `.text.text` directly --
    /// with the same allocator passed to `connect`.
    pub fn pollInputEvent(self: *InputListener) ?InputEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.input_events.items.len == 0) return null;
        return self.input_events.orderedRemove(0);
    }

    /// Blocks until an input event is queued or `timeout` elapses (`null`
    /// on timeout), instead of `pollInputEvent`'s non-blocking check -- for
    /// a consumer loop that wants to react immediately rather than
    /// re-polling on a fixed interval.
    pub fn waitInputEvent(self: *InputListener, timeout: std.Io.Timeout) !?InputEvent {
        self.input_sem.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => |e| return e,
        };
        return self.pollInputEvent();
    }

    pub fn isMouseButtonDown(self: *InputListener, button: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.isMouseButtonDown(button);
    }

    /// Pops the oldest queued mouse button event, if any -- see
    /// `pollKeyEvent`, the same non-blocking-drain shape. Caller must free
    /// the event with `MouseButtonEvent.deinit` (or free `.button`
    /// directly) using the same allocator passed to `connect`.
    pub fn pollMouseButtonEvent(self: *InputListener) ?MouseButtonEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.mouse_events.items.len == 0) return null;
        return self.mouse_events.orderedRemove(0);
    }

    /// Blocks until a mouse button event is queued or `timeout` elapses --
    /// see `waitKeyEvent`.
    pub fn waitMouseButtonEvent(self: *InputListener, timeout: std.Io.Timeout) !?MouseButtonEvent {
        self.mouse_sem.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => |e| return e,
        };
        return self.pollMouseButtonEvent();
    }

    /// Pops the oldest queued `mouse_move` event, if any (non-blocking) --
    /// see `pollMouseButtonEvent`, the same drain shape. Nothing to free.
    /// Only produced while subscribed to `"mouse_move"`.
    pub fn pollMouseMoveEvent(self: *InputListener) ?MouseMoveEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.mouse_move_events.items.len == 0) return null;
        return self.mouse_move_events.orderedRemove(0);
    }

    /// Blocks until a `mouse_move` event is queued or `timeout` elapses --
    /// see `waitMouseButtonEvent`.
    pub fn waitMouseMoveEvent(self: *InputListener, timeout: std.Io.Timeout) !?MouseMoveEvent {
        self.mouse_move_sem.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => |e| return e,
        };
        return self.pollMouseMoveEvent();
    }

    /// Pops the oldest queued `terminal_reply` (non-blocking). The caller
    /// owns the returned slice and frees it with the `connect` allocator.
    /// Only produced while subscribed to `"terminal"`.
    pub fn pollTerminalReply(self: *InputListener) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.terminal_reply_events.items.len == 0) return null;
        return self.terminal_reply_events.orderedRemove(0);
    }

    /// Pops the oldest queued `resize` event, if any (non-blocking) --
    /// see `pollKeyEvent`, the same drain shape. Nothing to free.
    /// Next queued `scroll_offset` event, or null -- see
    /// `pollResizeEvent` for the drain shape. Nothing to free.
    pub fn pollScrollOffsetEvent(self: *InputListener) ?ScrollOffsetEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.scroll_offset_events.items.len == 0) return null;
        return self.scroll_offset_events.orderedRemove(0);
    }

    /// Next queued `layout` event, or null. **The caller owns the result**
    /// and must `deinit` it -- unlike the other pollers, this one carries
    /// a slice.
    pub fn pollLayoutEvent(self: *InputListener) ?LayoutEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.layout_events.items.len == 0) return null;
        return self.layout_events.orderedRemove(0);
    }

    pub fn pollResizeEvent(self: *InputListener) ?ResizeEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.resize_events.items.len == 0) return null;
        return self.resize_events.orderedRemove(0);
    }

    /// Blocks until a `resize` event is queued or `timeout` elapses -- see
    /// `waitKeyEvent`.
    pub fn waitResizeEvent(self: *InputListener, timeout: std.Io.Timeout) !?ResizeEvent {
        self.resize_sem.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => |e| return e,
        };
        return self.pollResizeEvent();
    }

    /// The most recently pushed window size, or null if no `resize`
    /// notification has arrived on this listener yet -- a live-cache read
    /// (like `isKeyDown`), independent of whether `pollResizeEvent` has
    /// drained the event queue.
    pub fn size(self: *InputListener) ?ResizeEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.last_size;
    }

    /// Pops the oldest queued `scroll` event, if any (non-blocking) --
    /// see `pollResizeEvent`, the same drain shape. Nothing to free.
    pub fn pollScrollEvent(self: *InputListener) ?ScrollEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.scroll_events.items.len == 0) return null;
        return self.scroll_events.orderedRemove(0);
    }

    /// Blocks until a `scroll` event is queued or `timeout` elapses -- see
    /// `waitKeyEvent`.
    pub fn waitScrollEvent(self: *InputListener, timeout: std.Io.Timeout) !?ScrollEvent {
        self.scroll_sem.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => |e| return e,
        };
        return self.pollScrollEvent();
    }

    /// The most recently pushed scrollback view offset, or null if no
    /// `scroll` notification has arrived yet -- a live-cache read (like
    /// `size`), independent of whether `pollScrollEvent` has drained the
    /// queue.
    pub fn scroll(self: *InputListener) ?ScrollEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.last_scroll;
    }

    /// Pops the oldest queued `context` event, if any (non-blocking) --
    /// see `pollResizeEvent`, the same drain shape. Nothing to free.
    pub fn pollContextEvent(self: *InputListener) ?ContextEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.context_events.items.len == 0) return null;
        return self.context_events.orderedRemove(0);
    }

    /// Blocks until a `context` event is queued or `timeout` elapses --
    /// see `waitResizeEvent`.
    pub fn waitContextEvent(self: *InputListener, timeout: std.Io.Timeout) !?ContextEvent {
        self.context_sem.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => |e| return e,
        };
        return self.pollContextEvent();
    }

    /// The most recently pushed visible-context event, or null if none
    /// has arrived yet -- a live-cache read (like `size`), independent of
    /// whether `pollContextEvent` has drained the queue.
    pub fn visibleContext(self: *InputListener) ?ContextEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.last_context;
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

    /// Sends `attach_context(context)` on this listener's own connection
    /// so the raw input streams it's subscribed to (`key`/`text`/
    /// `mouse_*`) follow that context's visibility -- once its `Client`
    /// has `createContext`'d, its paired listener calls this with the
    /// same handle, and then a backgrounded context's listener stops
    /// receiving keystrokes meant for whatever is now on screen.
    /// Fire-and-forget (a notification, no ack); safe to call while the
    /// reader thread is running (nothing else writes this connection).
    pub fn attachContext(self: *InputListener, context: core.ContextHandle) !void {
        const Msg = struct {
            jsonrpc: []const u8 = "2.0",
            method: []const u8 = "attach_context",
            params: struct { context: core.ContextHandle },
        };
        const body = try std.json.Stringify.valueAlloc(self.alloc, Msg{ .params = .{ .context = context } }, .{});
        defer self.alloc.free(body);

        var write_buf: [256]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        try wire.writeFrame(&w.interface, body);
        try w.interface.flush();
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
            const P = protocol.KeyParams;
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
            try self.input_events.append(self.alloc, .{ .key = .{ .key = owned_key, .pressed = pressed } });
            self.input_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "text")) {
            const P = protocol.TextParams;
            const p = try std.json.parseFromValue(P, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const owned_text = try self.alloc.dupe(u8, p.value.text);
            errdefer self.alloc.free(owned_text);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.input_events.append(self.alloc, .{ .text = .{ .text = owned_text } });
            self.input_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "mouse_button")) {
            const P = protocol.MouseButtonParams;
            const p = try std.json.parseFromValue(P, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const owned_button = try self.alloc.dupe(u8, p.value.button);
            errdefer self.alloc.free(owned_button);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state.cursor_px = .{ .x = p.value.px.x, .y = p.value.px.y };
            self.state.cursor_cell = .{ .row = p.value.cell.row, .col = p.value.cell.col };
            _ = try self.state.setMouseButton(p.value.button, p.value.pressed);
            try self.mouse_events.append(self.alloc, .{ .button = owned_button, .pressed = p.value.pressed, .px = p.value.px, .cell = p.value.cell, .view_offset = p.value.view_offset });
            self.mouse_sem.post(self.io);
            // Also wake `waitInputEvent`: a consumer loop that blocks on
            // it between keystrokes (glyphwire-shell) drains the mouse
            // queue at the top of every iteration, so a spurious wake here
            // is all it takes to handle a click immediately instead of
            // after the loop's fallback timeout. `waitInputEvent` returns
            // null (the input queue is untouched), which that loop already
            // treats as an idle tick.
            self.input_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "mouse_move")) {
            const P = protocol.MouseMoveParams;
            const p = try std.json.parseFromValue(P, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state.cursor_px = .{ .x = p.value.px.x, .y = p.value.px.y };
            self.state.cursor_cell = .{ .row = p.value.cell.row, .col = p.value.cell.col };
            // Drop the backlog if nothing's draining (see the field doc):
            // only the newest position matters for the pty consumer, and a
            // consumer that fell 512+ cells behind isn't tracking a
            // gesture any more.
            if (self.mouse_move_events.items.len >= 512) self.mouse_move_events.clearRetainingCapacity();
            try self.mouse_move_events.append(self.alloc, .{ .px = p.value.px, .cell = p.value.cell });
            self.mouse_move_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "terminal_reply")) {
            const p = try std.json.parseFromValue(protocol.TerminalReplyParams, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const owned = try self.alloc.dupe(u8, p.value.bytes);
            errdefer self.alloc.free(owned);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.terminal_reply_events.append(self.alloc, owned);
            self.terminal_reply_sem.post(self.io);
            // Wake a consumer parked in `waitInputEvent` (the pty
            // foreground loop) so a startup `CSI 6n` / DA probe is
            // answered right away, not after the loop's fallback timeout.
            self.input_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "scroll")) {
            const P = protocol.ScrollParams;
            const p = try std.json.parseFromValue(P, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const ev: ScrollEvent = .{ .offset = p.value.offset, .max = p.value.max };
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.last_scroll = ev;
            try self.scroll_events.append(self.alloc, ev);
            self.scroll_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "scroll_offset")) {
            const p = try std.json.parseFromValue(protocol.ScrollOffsetParams, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const ev: ScrollOffsetEvent = .{
                .layer = p.value.layer,
                .row = p.value.row,
                .col = p.value.col,
                .max_row = p.value.max_row,
                .max_col = p.value.max_col,
            };
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.scroll_offset_events.append(self.alloc, ev);
            self.scroll_offset_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "layout")) {
            const p = try std.json.parseFromValue(protocol.LayoutParams, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            // The parsed slice lives in `p`'s arena, so it's copied out
            // before that's freed -- the event outlives this frame.
            const owned = try self.alloc.alloc(LayoutBounds, p.value.layers.len);
            errdefer self.alloc.free(owned);
            for (p.value.layers, 0..) |b, i| {
                owned[i] = .{ .layer = b.layer, .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows };
            }

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.layout_events.append(self.alloc, .{ .layers = owned });
            self.layout_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "resize")) {
            const P = protocol.ResizeParams;
            const p = try std.json.parseFromValue(P, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const ev: ResizeEvent = .{ .cols = p.value.cols, .rows = p.value.rows };
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.last_size = ev;
            try self.resize_events.append(self.alloc, ev);
            self.resize_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "shutdown")) {
            const p = try std.json.parseFromValue(protocol.ShutdownParams, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.input_events.append(self.alloc, .{ .shutdown = .{ .grace_ms = p.value.grace_ms } });
            self.input_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "context")) {
            const p = try std.json.parseFromValue(protocol.ContextParams, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const ev: ContextEvent = .{ .context = p.value.context, .cols = p.value.cols, .rows = p.value.rows };
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.last_context = ev;
            try self.context_events.append(self.alloc, ev);
            self.context_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "paste")) {
            const p = try std.json.parseFromValue(protocol.ClipboardTextParams, self.alloc, parsed.value.params, .{
                .ignore_unknown_fields = true,
            });
            defer p.deinit();

            const owned_text = try self.alloc.dupe(u8, p.value.text);
            errdefer self.alloc.free(owned_text);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.input_events.append(self.alloc, .{ .paste = .{ .text = owned_text } });
            self.input_sem.post(self.io);
        } else if (std.mem.eql(u8, parsed.value.method, "copy_request")) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.input_events.append(self.alloc, .copy_request);
            self.input_sem.post(self.io);
        }
    }
};
