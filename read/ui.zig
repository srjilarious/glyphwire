// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-read's glyphwire client: a full-screen reader for one book.
//!
//! **Layout.** Three free-floating layers in a dedicated context, placed
//! by `set_property(cell_position)` rather than by a split tree. zoe uses
//! splits because its panes tile; this doesn't, because a fitted page has
//! to be *centred* in whatever space is left over, and a split tree only
//! knows how to fill.
//!
//!   - `page_layer` -- exactly as big as the scaled page (zoom.zig), which
//!     is bigger than the window whenever you're zoomed in. The window is
//!     its viewport, and panning is `set_property(scroll_offset)`. That's
//!     also what makes the host route the wheel and draw the scrollbars
//!     for free: `scrollablePaneAt` matches any layer with slack.
//!   - `status_layer` -- one row across the bottom.
//!   - `help_layer` -- the `?` overlay, hidden until asked for.
//!
//! **Page turning is direction-aware.** Manga reads right-to-left, so by
//! default Left is *forward*. `Direction` (config.zig) flips that, `d`
//! toggles it at runtime, and the choice is remembered per book.
//!
//! **The arrow keys do two jobs.** When the page overflows an axis they
//! pan it; when it doesn't there's nothing to pan, so the horizontal pair
//! turns the page instead. That's the rule every comic reader uses and it
//! is never ambiguous, because "does this axis overflow" is exactly what
//! `Layout.max_pan_*` reports. `hjkl` always pans and `space` /
//! `backspace` always turn, for anyone who wants the unambiguous form.

const std = @import("std");
const glyphwire = @import("glyphwire");

const archive_mod = @import("archive.zig");
const cache_mod = @import("cache.zig");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const zoom = @import("zoom.zig");

const Direction = config_mod.Direction;

/// Rows the statusline occupies at the bottom of the window. The page
/// gets everything above it.
const status_rows: usize = 1;

/// Colors. Deliberately few: a reader is a picture on a background, and
/// anything else competing for attention is noise.
const bg_page = glyphwire.Color{ .r = 12, .g = 12, .b = 14 };
const bg_status = glyphwire.Color{ .r = 28, .g = 28, .b = 34 };
const fg_status = glyphwire.Color{ .r = 190, .g = 190, .b = 200 };
const fg_dim = glyphwire.Color{ .r = 120, .g = 120, .b = 132 };
const fg_warn = glyphwire.Color{ .r = 230, .g = 170, .b = 90 };

pub const Ui = struct {
    alloc: std.mem.Allocator,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,

    book: *archive_mod.Archive,
    conf: config_mod.ReadConfig,
    cache: cache_mod.Cache,

    context: glyphwire.ContextHandle,
    page_layer: glyphwire.LayerHandle,
    status_layer: glyphwire.LayerHandle,
    help_layer: glyphwire.LayerHandle,

    /// Window size in cells, from `resize`, and the session's cell
    /// metrics. Both are re-read on every resize: a Ctrl+`+` font step
    /// changes the metrics *and* reflows the grid, so one notification
    /// covers both.
    win: struct { cols: usize, rows: usize },
    cell: zoom.Size,

    page: usize = 0,
    mode: zoom.Mode,
    direction: Direction,
    /// The `.free` mode's factor. Seeded from whatever the last fit
    /// resolved to so the first `+` zooms in from what's on screen rather
    /// than jumping to 1:1 first.
    free_scale: f32 = 1.0,
    /// Pan offset in cells, i.e. the page layer's `scroll_offset`.
    pan: struct { row: usize = 0, col: usize = 0 } = .{},
    /// The layout the current frame drew, so key handlers can ask "does
    /// this axis overflow" without recomputing it.
    layout: zoom.Layout = .{ .scale = 1, .cols = 1, .rows = 1, .col = 0, .row = 0, .max_pan_col = 0, .max_pan_row = 0 },

    /// Set by `goToPage` and consumed by `renderPage`: the pan can only
    /// be put at the new page's reading edge once its overflow is known,
    /// which is after its dimensions have been fetched.
    pan_to_reading_edge: bool = false,

    /// A left-button drag over the page: where it started, in cells, and
    /// the pan offset it started from. Null when no button is down.
    drag: ?struct { cell: glyphwire.CellPos, pan_row: usize, pan_col: usize, moved: bool } = null,

    /// The `g` prefix (as in `gg`) and the `:` goto-page prompt. Only one
    /// can be pending at a time, which is why they share a field.
    pending: union(enum) { none, goto_prefix, goto_prompt: std.ArrayList(u8) } = .none,

    help_visible: bool = false,
    quit: bool = false,
    page_dirty: bool = true,
    status_dirty: bool = true,
    /// The root-layer fill behind everything. Only redrawn on a resize --
    /// nothing else can uncover it.
    backdrop_dirty: bool = true,
    /// A transient message shown in place of the page name -- a failed
    /// load, an out-of-range jump. Owned, cleared on the next keystroke.
    message: ?[]u8 = null,

    pub fn init(
        alloc: std.mem.Allocator,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        book: *archive_mod.Archive,
        conf: config_mod.ReadConfig,
        start: struct { page: usize, mode: zoom.Mode, direction: Direction },
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        // A dedicated context, shown immediately -- from here on every
        // layer call on `client` targets it, not the shell's. No window
        // scrollbar: the reader's root holds no scrollback, and the page
        // layer draws its own bars when it has something to scroll.
        const context = try client.createContext(null, null, 0, false);
        errdefer client.destroyContext(context) catch {};
        try listener.attachContext(context);

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        // Provisional sizes: `applyLayout` resizes the page layer on the
        // first frame, and every resize after.
        const page_layer = try client.createLayer(size.cols, size.rows, 0);
        const status_layer = try client.createLayer(size.cols, status_rows, 0);
        const help_layer = try client.createLayer(help_cols, help_rows, 0);

        try client.setLayerVisible(help_layer, false);

        self.* = .{
            .alloc = alloc,
            .client = client,
            .listener = listener,
            .book = book,
            .conf = conf,
            .cache = .init(conf.cache_pages),
            .context = context,
            .page_layer = page_layer,
            .status_layer = status_layer,
            .help_layer = help_layer,
            .win = .{ .cols = size.cols, .rows = size.rows },
            .cell = .{ .w = metrics.w, .h = metrics.h },
            .page = @min(start.page, book.count() -| 1),
            .mode = start.mode,
            .direction = start.direction,
        };

        return self;
    }

    pub fn deinit(self: *Ui) void {
        // A local copy, not `self.alloc`: `self` is destroyed at the end
        // of this function, and a `defer` that reaches back through it
        // would be reading freed memory by the time it runs.
        const alloc = self.alloc;

        // Hand every cached page's bytes back before the connection goes:
        // the server reclaims them anyway once this connection closes,
        // but a reader launched inside a long-lived shell session has
        // scrollback that could pin them until it scrolls away.
        var drained: std.ArrayList(cache_mod.Entry) = .empty;
        defer drained.deinit(alloc);
        self.cache.drain(alloc, &drained) catch {};
        for (drained.items) |e| self.client.destroyImage(e.handle) catch {};
        self.cache.deinit(alloc);

        if (self.message) |m| alloc.free(m);
        switch (self.pending) {
            .goto_prompt => |*buf| buf.deinit(alloc),
            else => {},
        }
        self.client.destroyContext(self.context) catch {};
        alloc.destroy(self);
    }

    /// Where the reader currently is, for the resume state file.
    pub fn bookmark(self: *const Ui) state_mod.Bookmark {
        return .{
            .page = self.page,
            .mode = @tagName(self.mode),
            .direction = self.direction.name(),
        };
    }

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            try self.drainEvents();
            if (self.backdrop_dirty) {
                self.backdrop_dirty = false;
                try self.renderBackdrop();
            }
            if (self.page_dirty) try self.renderPage();
            if (self.status_dirty) try self.renderStatus();
            if (self.quit) break;

            // Block rather than spin; the timeout is only so the other
            // queues (resize, mouse, scroll) get looked at. The waiting
            // form *consumes* what it waited for, so it's handled here --
            // `drainEvents` will never see it.
            if (self.listener.waitInputEvent(.{
                .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake },
            }) catch null) |ev| {
                defer ev.deinit(self.alloc);
                try self.handleInput(ev);
            }
        }
    }

    fn drainEvents(self: *Ui) !void {
        while (self.listener.pollResizeEvent()) |ev| {
            self.win = .{ .cols = ev.cols, .rows = ev.rows };
            // A font-size step reflows the grid *and* changes the cell
            // metrics, and arrives as one resize -- so re-read them here
            // rather than only at startup.
            if (self.client.getCellMetrics()) |m| {
                self.cell = .{ .w = m.w, .h = m.h };
            } else |_| {}
            self.backdrop_dirty = true;
            self.page_dirty = true;
            self.status_dirty = true;
        }
        while (self.listener.pollScrollOffsetEvent()) |ev| {
            // The wheel or a scrollbar thumb over the page: the host has
            // already moved the viewport and is telling us where it
            // landed. Follow it rather than pushing our own value back.
            if (ev.layer == self.page_layer) {
                self.pan = .{ .row = ev.row, .col = ev.col };
                self.status_dirty = true;
            }
        }
        while (self.listener.pollMouseMoveEvent()) |ev| {
            try self.handleMouseMove(ev);
        }
        while (self.listener.pollMouseButtonEvent()) |ev| {
            defer ev.deinit(self.alloc);
            try self.handleMouseButton(ev);
        }
        while (self.listener.pollInputEvent()) |ev| {
            defer ev.deinit(self.alloc);
            try self.handleInput(ev);
        }
    }

    // ── Paging ──────────────────────────────────────────────────────────

    /// Moves `delta` pages in *reading* order (positive is forward, which
    /// is leftward in `rtl`). Clamps at both ends rather than wrapping --
    /// a reader that jumps from the last page back to the cover on one
    /// extra keypress has lost your place.
    fn stepPage(self: *Ui, delta: i64) void {
        const last = self.book.count() -| 1;
        const target: usize = if (delta < 0)
            self.page -| @as(usize, @intCast(-delta))
        else
            @min(self.page + @as(usize, @intCast(delta)), last);
        self.goToPage(target);
    }

    fn goToPage(self: *Ui, page: usize) void {
        const clamped = @min(page, self.book.count() -| 1);
        if (clamped == self.page) {
            self.status_dirty = true;
            return;
        }
        self.page = clamped;
        // A new page starts at its top-left in reading order: the top
        // *right* corner for manga, which is where the first panel is.
        self.pan = .{ .row = 0, .col = 0 };
        self.pan_to_reading_edge = true;
        self.page_dirty = true;
        self.status_dirty = true;
    }

    /// Ensures page `index` is loaded server-side and returns its cache
    /// entry. The bytes are read from the archive, handed to
    /// `load_image`, and freed again immediately -- the server owns the
    /// only copy from then on, and the LRU owns the handle.
    fn ensureLoaded(self: *Ui, index: usize) !cache_mod.Entry {
        if (self.cache.get(index)) |e| return e;

        const bytes = try self.book.readPage(self.alloc, index);
        defer self.alloc.free(bytes);

        const format = glyphwire.detectImageFormat(bytes) orelse return error.UnsupportedImageFormat;
        const handle = try self.client.loadImage(format.name(), bytes);
        errdefer self.client.destroyImage(handle) catch {};
        const info = try self.client.getImageInfo(handle);

        const entry: cache_mod.Entry = .{
            .page = index,
            .handle = handle,
            .width = info.width,
            .height = info.height,
        };
        if (try self.cache.put(self.alloc, entry)) |evicted| {
            self.client.destroyImage(evicted.handle) catch {};
        }
        return entry;
    }

    /// Loads the next `conf.prefetch` pages in reading order if they
    /// aren't resident, so the page turn itself doesn't wait on a read.
    /// Failures are silent: a prefetch that can't load is only a missed
    /// optimisation, and the real load will report the error properly.
    fn prefetch(self: *Ui) void {
        var i: usize = 1;
        while (i <= self.conf.prefetch) : (i += 1) {
            const next = self.page + i;
            if (next >= self.book.count()) return;
            if (self.cache.contains(next)) continue;
            _ = self.ensureLoaded(next) catch return;
        }
    }

    // ── Rendering ───────────────────────────────────────────────────────

    /// The window area the page gets: everything above the statusline.
    fn pageView(self: *const Ui) zoom.View {
        return .{ .cols = self.win.cols, .rows = self.win.rows -| status_rows };
    }

    /// Fills the context's root layer with the page background.
    ///
    /// A fitted page is *smaller* than the window on at least one axis,
    /// and the page layer is exactly the page's size -- so without this
    /// the letterbox around it is transparent and the shell's scrollback
    /// shows through, which is the same trap zoe's sidebar fell into.
    /// `clear` resets to the default style rather than a chosen colour,
    /// so the fill is rows of spaces; one batch keeps it to a single
    /// round trip per resize rather than one per row.
    fn renderBackdrop(self: *Ui) !void {
        if (self.win.cols == 0 or self.win.rows == 0) return;

        const blanks = try self.alloc.alloc(u8, self.win.cols);
        defer self.alloc.free(blanks);
        @memset(blanks, ' ');

        var b = self.client.batch();
        defer b.deinit();
        var row: usize = 0;
        while (row < self.win.rows) : (row += 1) {
            try b.setCursor(row, 0);
            try b.writeText(blanks, null, bg_page);
        }
        var results = try b.send();
        results.deinit();
    }

    fn renderPage(self: *Ui) !void {
        self.page_dirty = false;

        const entry = self.ensureLoaded(self.page) catch |err| {
            try self.setMessage("page {d} failed to load ({t})", .{ self.page + 1, err });
            self.status_dirty = true;
            return;
        };

        const view = self.pageView();
        self.layout = zoom.layout(
            self.mode,
            self.free_scale,
            .{ .w = entry.width, .h = entry.height },
            .{ .cols = view.cols, .rows = view.rows },
            self.cell,
            self.conf.limits(),
        );
        // Keep `free_scale` tracking whatever is on screen, so switching
        // to `.free` with `+` continues from the current size.
        if (self.mode != .free) self.free_scale = self.layout.scale;

        if (self.pan_to_reading_edge) {
            self.pan_to_reading_edge = false;
            // Manga starts at the page's right edge; a left-to-right book
            // at its left. Vertically both start at the top.
            self.pan.col = switch (self.direction) {
                .rtl => self.layout.max_pan_col,
                .ltr => 0,
            };
            self.pan.row = 0;
        }
        self.clampPan();

        const c = self.client;
        try c.setLayerSize(self.page_layer, self.layout.cols, self.layout.rows);
        // The window is the layer's window onto its own, larger grid --
        // the host-scrolled model, the one zoe's *tree* pane uses.
        //
        // Deliberately **no `content_extent`**. That property switches a
        // layer into the client-scrolled model zoe's *buffer* pane uses:
        // the host then moves a virtual `content_off` and broadcasts a
        // `scroll_offset` for the client to repaint against, and the real
        // `scroll_off` the renderer reads never moves -- the scrollbar
        // slides and the picture sits still. It isn't needed for the
        // scrollbars either: `maxScroll` falls back to the real grid, so
        // a grid bigger than the viewport already reports slack, which is
        // what turns the bars and the wheel on.
        try c.setLayerViewport(self.page_layer, @min(self.layout.cols, view.cols), @min(self.layout.rows, view.rows));
        try c.setLayerScrollbars(self.page_layer, self.layout.max_pan_row > 0, self.layout.max_pan_col > 0);
        try c.setLayerCellPosition(self.page_layer, self.layout.row, self.layout.col);

        // Wipe first: a page narrower than the last one would otherwise
        // leave the previous page's right-hand columns behind.
        try c.clearOn(self.page_layer, 0, 0, null, null);
        try c.drawImageOn(
            self.page_layer,
            entry.handle,
            0,
            0,
            self.layout.rows,
            self.layout.cols,
            self.layout.scale,
        );
        try c.setLayerScrollOffset(self.page_layer, self.pan.row, self.pan.col);

        self.prefetch();
        self.status_dirty = true;
    }

    fn renderStatus(self: *Ui) !void {
        self.status_dirty = false;
        const c = self.client;

        try c.setLayerSize(self.status_layer, self.win.cols, status_rows);
        try c.setLayerCellPosition(self.status_layer, self.win.rows -| status_rows, 0);

        // Lay the band down first, then write the three groups over it.
        // `clear` resets a cell to the *default* style, not to a chosen
        // colour, so without this the gaps between the groups would be
        // transparent and the backdrop would show through -- a status
        // bar in three islands rather than one strip.
        var blanks_buf: [512]u8 = undefined;
        const band_len = @min(self.win.cols, blanks_buf.len);
        @memset(blanks_buf[0..band_len], ' ');
        try c.setCursorOn(self.status_layer, 0, 0);
        try c.writeTextOn(self.status_layer, blanks_buf[0..band_len], fg_status, bg_status);
        try c.setCursorOn(self.status_layer, 0, 0);

        var buf: [512]u8 = undefined;

        // Left: where you are in the book, and which way it pages.
        const left = std.fmt.bufPrint(&buf, " {d}/{d} {s} ", .{
            self.page + 1,
            self.book.count(),
            self.direction.label(),
        }) catch " ";
        try c.writeTextOn(self.status_layer, left, fg_status, bg_status);

        // Middle: the goto prompt while it's open, else the page's own
        // name, else whatever went wrong.
        switch (self.pending) {
            .goto_prompt => |prompt| {
                const text = std.fmt.bufPrint(&buf, ":{s}_ ", .{prompt.items}) catch ":";
                try c.writeTextOn(self.status_layer, text, fg_warn, bg_status);
            },
            else => if (self.message) |m| {
                try c.writeTextOn(self.status_layer, m, fg_warn, bg_status);
            } else {
                const name = self.book.pages.items[@min(self.page, self.book.count() -| 1)].name;
                try c.writeTextOn(self.status_layer, name, fg_dim, bg_status);
            },
        }

        // Right: the sizing mode and, when it isn't a plain fit, the
        // factor -- "fit" alone says everything, "1:1 100%" does not.
        const right = std.fmt.bufPrint(&buf, "  {s} {d:.0}%  ? help ", .{
            self.mode.label(),
            self.layout.scale * 100,
        }) catch "";
        const at: usize = self.win.cols -| right.len;
        try c.setCursorOn(self.status_layer, 0, at);
        try c.writeTextOn(self.status_layer, right, fg_status, bg_status);

        if (self.help_visible) try self.renderHelp();
    }

    /// Wide enough for the longest line below plus the box's two border
    /// columns and the one-column inset the text is drawn at -- a line
    /// that doesn't fit wraps onto the next one and eats it. `help_rows`
    /// is derived rather than written down for the same reason.
    const help_cols: usize = 52;
    const help_rows: usize = help_lines.len + 2;

    const help_lines = [_][]const u8{
        "  gw-read",
        "",
        "  space / page_down    next page",
        "  backspace / page_up  previous page",
        "  left / right         turn, or pan when zoomed",
        "  h j k l              pan",
        "  ] / [                jump 5 pages",
        "  g g / G              first / last page",
        "  :  <digits> enter    go to page",
        "",
        "  f / w / t / 1        fit / width / height / 1:1",
        "  + / -                zoom in / out",
        "  d                    flip reading direction",
        "",
        "  ? toggle this   q quit",
    };

    fn renderHelp(self: *Ui) !void {
        const c = self.client;
        try c.setLayerCellPosition(
            self.help_layer,
            (self.win.rows -| help_rows) / 2,
            (self.win.cols -| help_cols) / 2,
        );
        try c.clearOn(self.help_layer, 0, 0, null, null);
        try c.drawBoxOn(self.help_layer, 0, 0, help_rows, help_cols, "dialog");
        for (help_lines, 0..) |line, i| {
            try c.setCursorOn(self.help_layer, i + 1, 1);
            try c.writeTextOn(self.help_layer, line, fg_status, null);
        }
    }

    fn clampPan(self: *Ui) void {
        self.pan.row = @min(self.pan.row, self.layout.max_pan_row);
        self.pan.col = @min(self.pan.col, self.layout.max_pan_col);
    }

    fn setMessage(self: *Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.message) |m| self.alloc.free(m);
        self.message = std.fmt.allocPrint(self.alloc, fmt, args) catch null;
    }

    fn clearMessage(self: *Ui) void {
        if (self.message) |m| {
            self.alloc.free(m);
            self.message = null;
            self.status_dirty = true;
        }
    }

    // ── Input ───────────────────────────────────────────────────────────

    fn handleInput(self: *Ui, ev: glyphwire.InputEvent) !void {
        switch (ev) {
            // Every physical keystroke is a press *and* a release; acting
            // on both would turn two pages per tap.
            .key => |k| if (k.pressed) try self.handleKey(k.key),
            .text => |t| try self.handleText(t.text),
            .shutdown => self.quit = true,
            else => {},
        }
    }

    fn handleKey(self: *Ui, key: []const u8) !void {
        const eq = std.mem.eql;
        self.clearMessage();

        // The goto prompt swallows everything but its own control keys,
        // so a digit typed into it doesn't also page the book.
        if (self.pending == .goto_prompt) {
            if (eq(u8, key, "enter") or eq(u8, key, "kp_enter")) return self.commitGoto();
            if (eq(u8, key, "escape")) return self.cancelGoto();
            if (eq(u8, key, "backspace")) {
                var prompt = &self.pending.goto_prompt;
                if (prompt.items.len > 0) _ = prompt.pop();
                self.status_dirty = true;
                return;
            }
            return;
        }

        // `gg` -- the second `g` arrives as its own keystroke, so the
        // first one only arms the prefix.
        if (self.pending == .goto_prefix) {
            self.pending = .none;
            if (eq(u8, key, "g")) {
                self.goToPage(0);
                return;
            }
            // Anything else cancels the prefix and is handled normally.
        }

        const shift = self.listener.isKeyDown("left_shift") or self.listener.isKeyDown("right_shift");

        // ── quit / overlay ──
        if (eq(u8, key, "q") or eq(u8, key, "escape")) {
            if (self.help_visible) {
                try self.setHelp(false);
                return;
            }
            self.quit = true;
            return;
        }
        // ── unambiguous page turns ──
        if (eq(u8, key, "space") or eq(u8, key, "page_down")) return self.stepPage(1);
        if (eq(u8, key, "backspace") or eq(u8, key, "page_up")) return self.stepPage(-1);
        if (eq(u8, key, "home")) return self.goToPage(0);
        if (eq(u8, key, "end")) return self.goToPage(self.book.count() -| 1);
        if (eq(u8, key, "g")) {
            if (shift) return self.goToPage(self.book.count() -| 1); // G
            self.pending = .goto_prefix;
            return;
        }
        // ── pan (always) ──
        if (eq(u8, key, "h")) return self.panBy(0, -@as(i64, @intCast(self.conf.pan_step)));
        if (eq(u8, key, "l")) return self.panBy(0, @intCast(self.conf.pan_step));
        if (eq(u8, key, "k")) return self.panBy(-@as(i64, @intCast(self.conf.pan_step)), 0);
        if (eq(u8, key, "j")) return self.panBy(@intCast(self.conf.pan_step), 0);

        // ── arrows: pan the axis if it overflows, else turn the page ──
        if (eq(u8, key, "left")) {
            if (self.layout.max_pan_col > 0) return self.panBy(0, -@as(i64, @intCast(self.conf.pan_step)));
            return self.turn(.left);
        }
        if (eq(u8, key, "right")) {
            if (self.layout.max_pan_col > 0) return self.panBy(0, @intCast(self.conf.pan_step));
            return self.turn(.right);
        }
        if (eq(u8, key, "up")) {
            if (self.layout.max_pan_row > 0) return self.panBy(-@as(i64, @intCast(self.conf.pan_step)), 0);
            return self.stepPage(-1);
        }
        if (eq(u8, key, "down")) {
            if (self.layout.max_pan_row > 0) return self.panBy(@intCast(self.conf.pan_step), 0);
            return self.stepPage(1);
        }

        // ── sizing ──
        if (eq(u8, key, "f")) return self.setMode(.fit_screen);
        if (eq(u8, key, "w")) return self.setMode(.fit_width);
        if (eq(u8, key, "t")) return self.setMode(.fit_height);
        if (eq(u8, key, "one")) return self.setMode(.natural);

        // ── direction ──
        if (eq(u8, key, "d")) return self.flipDirection();
    }

    /// Committed text input. Two jobs:
    ///
    /// 1. The digits of the goto prompt.
    /// 2. Every **punctuation** command -- `:` `?` `+` `-` `[` `]`.
    ///
    /// Punctuation deliberately does *not* go through `handleKey`. A key
    /// event names the physical key, so `:` would have to be spelled
    /// "shift held and the `semicolon` key", which is only true on a US
    /// layout -- on a German one that key is `ö` and the colon is
    /// somewhere else entirely. `text` is the host's char-callback
    /// output, already resolved through the OS layout and any IME, so
    /// matching the character itself is both simpler and correct
    /// everywhere. Letters and named keys stay on `handleKey`, where the
    /// physical position *is* what's wanted (vim-style, same as zoe).
    fn handleText(self: *Ui, text: []const u8) !void {
        if (self.pending == .goto_prompt) {
            var prompt = &self.pending.goto_prompt;
            for (text) |ch| {
                if (!std.ascii.isDigit(ch)) continue;
                // A page number longer than this isn't a page number.
                if (prompt.items.len >= 9) break;
                try prompt.append(self.alloc, ch);
            }
            self.status_dirty = true;
            return;
        }

        const eq = std.mem.eql;
        if (eq(u8, text, ":")) return self.startGoto();
        if (eq(u8, text, "?")) return self.setHelp(!self.help_visible);
        // `=` as well as `+`: the unshifted key is just as good a "zoom
        // in" and saves the reach.
        if (eq(u8, text, "+") or eq(u8, text, "=")) return self.zoomBy(.in);
        if (eq(u8, text, "-")) return self.zoomBy(.out);
        if (eq(u8, text, "]")) return self.stepPage(@intCast(self.conf.jump_pages));
        if (eq(u8, text, "[")) return self.stepPage(-@as(i64, @intCast(self.conf.jump_pages)));
    }

    /// A page turn expressed as a screen direction, resolved against the
    /// reading direction: in `rtl`, leftward is forward.
    fn turn(self: *Ui, side: enum { left, right }) void {
        const forward = switch (self.direction) {
            .rtl => side == .left,
            .ltr => side == .right,
        };
        self.stepPage(if (forward) 1 else -1);
    }

    fn panBy(self: *Ui, d_row: i64, d_col: i64) void {
        const row = zoom.clampPan(@as(i64, @intCast(self.pan.row)) + d_row, self.layout.max_pan_row);
        const col = zoom.clampPan(@as(i64, @intCast(self.pan.col)) + d_col, self.layout.max_pan_col);
        if (row == self.pan.row and col == self.pan.col) return;
        self.pan = .{ .row = row, .col = col };
        self.client.setLayerScrollOffset(self.page_layer, row, col) catch {};
        self.status_dirty = true;
    }

    fn setMode(self: *Ui, mode: zoom.Mode) void {
        if (self.mode == mode) return;
        self.mode = mode;
        // Land at the page's reading edge, same as a page turn: switching
        // a manga page to fit-width should show its top *right*, which is
        // where the first panel is. A `+`/`-` zoom deliberately doesn't do
        // this -- stepping the magnification shouldn't also jump you
        // across the page you were looking at.
        self.pan = .{};
        self.pan_to_reading_edge = true;
        self.page_dirty = true;
    }

    fn zoomBy(self: *Ui, dir: enum { in, out }) void {
        // The first zoom step from a fit mode continues from the size
        // currently on screen (`free_scale` tracks it in `renderPage`).
        self.free_scale = zoom.step(self.free_scale, switch (dir) {
            .in => .in,
            .out => .out,
        }, self.conf.limits());
        self.mode = .free;
        self.page_dirty = true;
    }

    fn flipDirection(self: *Ui) void {
        self.direction = switch (self.direction) {
            .rtl => .ltr,
            .ltr => .rtl,
        };
        self.status_dirty = true;
    }

    fn setHelp(self: *Ui, visible: bool) !void {
        self.help_visible = visible;
        try self.client.setLayerVisible(self.help_layer, visible);
        if (visible) try self.renderHelp();
        self.status_dirty = true;
    }

    fn startGoto(self: *Ui) void {
        self.pending = .{ .goto_prompt = .empty };
        self.status_dirty = true;
    }

    fn cancelGoto(self: *Ui) void {
        self.pending.goto_prompt.deinit(self.alloc);
        self.pending = .none;
        self.status_dirty = true;
    }

    fn commitGoto(self: *Ui) void {
        // Everything the message needs is read out *before* the prompt's
        // buffer is freed. `handleText` caps the entry at 9 digits, so
        // this can't truncate anything the user actually typed.
        var typed: [9]u8 = undefined;
        const entered = self.pending.goto_prompt.items;
        const len = @min(entered.len, typed.len);
        @memcpy(typed[0..len], entered[0..len]);
        const n = std.fmt.parseInt(usize, typed[0..len], 10) catch 0;

        self.pending.goto_prompt.deinit(self.alloc);
        self.pending = .none;

        if (n == 0 or n > self.book.count()) {
            self.setMessage("no page {s}", .{typed[0..len]}) catch {};
            self.status_dirty = true;
            return;
        }
        // Pages are 1-based everywhere the reader shows them.
        self.goToPage(n - 1);
    }

    // ── Mouse ───────────────────────────────────────────────────────────

    fn handleMouseButton(self: *Ui, ev: glyphwire.MouseButtonEvent) !void {
        if (!std.mem.eql(u8, ev.button, "left")) return;

        if (ev.pressed) {
            self.drag = .{
                .cell = ev.cell,
                .pan_row = self.pan.row,
                .pan_col = self.pan.col,
                .moved = false,
            };
            return;
        }

        const started = self.drag orelse return;
        self.drag = null;
        // A release that never moved is a click, not a drag: click the
        // near half of the window to go back, the far half to go on --
        // the gesture every comic reader has, and direction-aware for the
        // same reason the arrow keys are.
        if (started.moved) return;
        self.clearMessage();
        self.turn(if (ev.cell.col * 2 < self.win.cols) .left else .right);
    }

    fn handleMouseMove(self: *Ui, ev: glyphwire.MouseMoveEvent) !void {
        var started = self.drag orelse return;
        // Cell-granular, because that's what the pan offset is. The host
        // coalesces motion to cell changes anyway, so there's no finer
        // signal to act on here.
        const d_col = @as(i64, @intCast(started.cell.col)) - @as(i64, @intCast(ev.cell.col));
        const d_row = @as(i64, @intCast(started.cell.row)) - @as(i64, @intCast(ev.cell.row));
        if (d_col == 0 and d_row == 0) return;

        started.moved = true;
        self.drag = started;

        // Drag *the page*, not the viewport: pulling the pointer left
        // moves the page left, which means the window moves right.
        const row = zoom.clampPan(@as(i64, @intCast(started.pan_row)) + d_row, self.layout.max_pan_row);
        const col = zoom.clampPan(@as(i64, @intCast(started.pan_col)) + d_col, self.layout.max_pan_col);
        if (row == self.pan.row and col == self.pan.col) return;
        self.pan = .{ .row = row, .col = col };
        self.client.setLayerScrollOffset(self.page_layer, row, col) catch {};
    }
};
