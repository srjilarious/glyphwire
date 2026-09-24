// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `gw-view --interactive`: the image on a context of its own, sized,
//! zoomed and panned until you quit, instead of drawn once at the
//! shell's cursor and left there.
//!
//! Two layers, the shape `gw-read` established for a page (see its
//! module comment, and `glyphwire.zoom` for the geometry both share):
//!
//!   - `page_layer` -- exactly as big as the scaled image, which is
//!     bigger than the window whenever you're zoomed in. `draw_image`
//!     has no source offset, so showing the middle of a zoomed image
//!     means drawing all of it on an oversized layer and moving the
//!     window over it with `scroll_offset`. That also buys the host's
//!     wheel handling and scrollbars for nothing.
//!   - `status_layer` -- one row across the bottom: the file, its
//!     pixels, and the size it's being shown at.
//!
//! The keys are `gw-read`'s, minus everything about pages: `f`/`w`/`t`
//! fit the screen, the width or the height, `1` is one image pixel per
//! screen pixel, `+`/`-` step the zoom, `hjkl` and the arrows pan, and
//! `q` or Escape quits. A drag pans too.

const std = @import("std");
const glyphwire = @import("glyphwire");
const zoom = glyphwire.zoom;

const Color = glyphwire.Color;

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

/// Near-black, so a photograph's own edges are what the eye finds.
const bg_page = rgb(16, 17, 20);
const bg_status = rgb(30, 33, 39);
const fg_detail = rgb(120, 126, 138);
const fg_name = rgb(229, 192, 123);

/// Cells one pan keystroke moves. `gw-read` makes this configurable;
/// there's no gw-view config file to put it in yet.
const pan_step: i64 = 3;

pub const Options = struct {
    /// The file being shown, for the status row. Borrowed.
    path: []const u8,
    /// Its pixels, from `get_image_info`.
    image: zoom.Size,
    /// A loaded image handle -- `Ui` draws it but doesn't own it.
    handle: glyphwire.ImageHandle,
    mode: zoom.Mode = .fit_screen,
};

pub const Ui = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,

    context: glyphwire.ContextHandle,
    page_layer: glyphwire.LayerHandle,
    status_layer: glyphwire.LayerHandle,

    win: struct { cols: usize, rows: usize },
    cell: zoom.Size,

    path: []const u8,
    handle: glyphwire.ImageHandle,
    image: zoom.Size,

    mode: zoom.Mode,
    /// The `.free` scale, kept tracking what's on screen while a fit mode
    /// is on so the first `+` continues from the size you're looking at.
    free_scale: f32 = 1.0,
    limits: zoom.Limits = .{},
    /// The page layer's `scroll_offset`, in cells.
    pan: struct { row: usize = 0, col: usize = 0 } = .{},
    layout: zoom.Layout = .{ .scale = 1, .cols = 1, .rows = 1, .col = 0, .row = 0, .max_pan_col = 0, .max_pan_row = 0 },

    /// A button held over the image: where it went down, and the pan it
    /// started from.
    drag: ?struct { cell: glyphwire.CellPos, pan_row: usize, pan_col: usize } = null,

    page_dirty: bool = true,
    status_dirty: bool = true,
    quit: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        opts: Options,
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        const context = try client.createContext(null, null, 0, false);
        errdefer client.destroyContext(context) catch {};
        try listener.attachContext(context);
        // Nothing here takes typed text at a caret.
        try client.setCaretVisible(false);

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        const page_layer = try client.createLayer(size.cols, size.rows, 0);
        const status_layer = try client.createLayer(size.cols, 1, 0);
        try client.setLayerBackground(glyphwire.root_layer_handle, bg_page);
        try client.setLayerBackground(page_layer, bg_page);
        try client.setLayerBackground(status_layer, bg_status);
        try client.setLayerCellPosition(status_layer, size.rows -| 1, 0);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .client = client,
            .listener = listener,
            .context = context,
            .page_layer = page_layer,
            .status_layer = status_layer,
            .win = .{ .cols = size.cols, .rows = size.rows },
            .cell = .{ .w = metrics.w, .h = metrics.h },
            .path = opts.path,
            .handle = opts.handle,
            .image = opts.image,
            .mode = opts.mode,
        };
        return self;
    }

    pub fn deinit(self: *Ui) void {
        self.client.destroyContext(self.context) catch {};
        self.alloc.destroy(self);
    }

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            try self.flush();
            const first = try self.listener.next(.none) orelse continue;
            try self.handleEvent(first);
            while (!self.quit) {
                const ev = self.listener.pollNext() orelse break;
                try self.handleEvent(ev);
            }
        }
    }

    fn handleEvent(self: *Ui, ev: glyphwire.Event) !void {
        defer ev.deinit(self.alloc);
        switch (ev) {
            .resize => |r| {
                self.win = .{ .cols = r.cols, .rows = r.rows };
                // A font-size step arrives as a resize and changes the
                // cell metrics with it.
                if (self.client.getCellMetrics()) |m| {
                    self.cell = .{ .w = m.w, .h = m.h };
                } else |_| {}
                try self.client.setLayerSize(self.status_layer, r.cols, 1);
                try self.client.setLayerCellPosition(self.status_layer, r.rows -| 1, 0);
                self.page_dirty = true;
                self.status_dirty = true;
            },
            .scroll_offset => |so| if (so.layer == self.page_layer) {
                // The wheel or a scrollbar drag: the host has already
                // moved the viewport and is saying where it landed.
                self.pan = .{ .row = so.row, .col = so.col };
                self.status_dirty = true;
            },
            .mouse_button => |m| try self.handleMouseButton(m),
            .mouse_move => |m| try self.handleMouseMove(m),
            .key => |k| if (k.pressed) try self.handleKey(k),
            .text => |t| try self.handleText(t.text),
            .shutdown => self.quit = true,
            else => {},
        }
    }

    fn handleKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const key = k.key;
        const eq = std.mem.eql;
        if (eq(u8, key, "q") or eq(u8, key, "escape")) {
            self.quit = true;
            return;
        }

        if (eq(u8, key, "h") or eq(u8, key, "left")) return self.panBy(0, -pan_step);
        if (eq(u8, key, "l") or eq(u8, key, "right")) return self.panBy(0, pan_step);
        if (eq(u8, key, "k") or eq(u8, key, "up")) return self.panBy(-pan_step, 0);
        if (eq(u8, key, "j") or eq(u8, key, "down")) return self.panBy(pan_step, 0);
        // A screenful at a time, the way a viewer's PgUp/PgDn should read.
        const screenful: i64 = @intCast(self.win.rows -| 2);
        if (eq(u8, key, "page_down") or eq(u8, key, "space")) return self.panBy(screenful, 0);
        if (eq(u8, key, "page_up")) return self.panBy(-screenful, 0);
        if (eq(u8, key, "home")) return self.setPan(0, 0);
        if (eq(u8, key, "end")) return self.setPan(self.layout.max_pan_row, self.pan.col);

        if (eq(u8, key, "f")) return self.setMode(.fit_screen);
        if (eq(u8, key, "w")) return self.setMode(.fit_width);
        if (eq(u8, key, "t")) return self.setMode(.fit_height);
        if (eq(u8, key, "one")) return self.setMode(.natural);
    }

    fn handleText(self: *Ui, text: []const u8) !void {
        const eq = std.mem.eql;
        // `=` as well as `+`, as in gw-read: the unshifted key is just as
        // good a "zoom in" and saves the reach.
        if (eq(u8, text, "+") or eq(u8, text, "=")) return self.zoomBy(.in);
        if (eq(u8, text, "-")) return self.zoomBy(.out);
    }

    fn handleMouseButton(self: *Ui, m: glyphwire.MouseButtonEvent) !void {
        if (!std.mem.eql(u8, m.button, "left")) return;
        if (!m.pressed) {
            self.drag = null;
            return;
        }
        self.drag = .{ .cell = m.cell, .pan_row = self.pan.row, .pan_col = self.pan.col };
    }

    fn handleMouseMove(self: *Ui, ev: glyphwire.MouseMoveEvent) !void {
        const started = self.drag orelse return;
        // Cell-granular, because the pan offset is; the host coalesces
        // motion to cell changes anyway.
        const d_col = @as(i64, @intCast(started.cell.col)) - @as(i64, @intCast(ev.cell.col));
        const d_row = @as(i64, @intCast(started.cell.row)) - @as(i64, @intCast(ev.cell.row));
        if (d_col == 0 and d_row == 0) return;
        // Drag *the image*: pulling the pointer left moves the image
        // left, so the window moves right.
        self.setPan(
            zoom.clampPan(@as(i64, @intCast(started.pan_row)) + d_row, self.layout.max_pan_row),
            zoom.clampPan(@as(i64, @intCast(started.pan_col)) + d_col, self.layout.max_pan_col),
        );
    }

    // ── Sizing and panning ──────────────────────────────────────────────

    fn setMode(self: *Ui, mode: zoom.Mode) void {
        if (self.mode == mode) return;
        self.mode = mode;
        // A named size starts from the top-left corner; a `+`/`-` step
        // deliberately doesn't, so magnifying doesn't also jump you
        // across the image you were looking at.
        self.pan = .{};
        self.page_dirty = true;
    }

    fn zoomBy(self: *Ui, dir: enum { in, out }) void {
        self.free_scale = zoom.step(self.free_scale, switch (dir) {
            .in => .in,
            .out => .out,
        }, self.limits);
        self.mode = .free;
        self.page_dirty = true;
    }

    fn panBy(self: *Ui, d_row: i64, d_col: i64) void {
        self.setPan(
            zoom.clampPan(@as(i64, @intCast(self.pan.row)) + d_row, self.layout.max_pan_row),
            zoom.clampPan(@as(i64, @intCast(self.pan.col)) + d_col, self.layout.max_pan_col),
        );
    }

    fn setPan(self: *Ui, row: usize, col: usize) void {
        if (row == self.pan.row and col == self.pan.col) return;
        self.pan = .{ .row = row, .col = col };
        // Straight to the wire: the image hasn't changed, only which part
        // of it the window is over.
        self.client.setLayerScrollOffset(self.page_layer, row, col) catch {};
        self.status_dirty = true;
    }

    // ── Rendering ───────────────────────────────────────────────────────

    fn flush(self: *Ui) !void {
        if (self.page_dirty) try self.renderPage();
        if (self.status_dirty) try self.renderStatus();
    }

    /// The image area, in cells: the window less the status row.
    fn pageView(self: *const Ui) zoom.View {
        return .{ .cols = self.win.cols, .rows = self.win.rows -| 1 };
    }

    fn renderPage(self: *Ui) !void {
        self.page_dirty = false;
        const view = self.pageView();
        self.layout = zoom.layout(self.mode, self.free_scale, self.image, view, self.cell, self.limits);
        if (self.mode != .free) self.free_scale = self.layout.scale;
        self.pan = .{
            .row = @min(self.pan.row, self.layout.max_pan_row),
            .col = @min(self.pan.col, self.layout.max_pan_col),
        };

        const c = self.client;
        try c.setLayerSize(self.page_layer, self.layout.cols, self.layout.rows);
        // The window is this layer's window onto its own, larger grid --
        // the layer stays in the default `host` scroll mode, so a grid
        // bigger than the viewport is all the host needs to route the
        // wheel and draw the bars.
        try c.setLayerViewport(self.page_layer, @min(self.layout.cols, view.cols), @min(self.layout.rows, view.rows));
        try c.setLayerScrollbars(self.page_layer, self.layout.max_pan_row > 0, self.layout.max_pan_col > 0);
        try c.setLayerCellPosition(self.page_layer, self.layout.row, self.layout.col);
        // Wipe first: a smaller image would otherwise leave the last
        // size's right-hand columns behind.
        try c.clearOn(self.page_layer, 0, 0, null, null);
        try c.drawImageOn(self.page_layer, self.handle, 0, 0, self.layout.rows, self.layout.cols, self.layout.scale, .{});
        try c.setLayerScrollOffset(self.page_layer, self.pan.row, self.pan.col);
        self.status_dirty = true;
    }

    fn renderStatus(self: *Ui) !void {
        self.status_dirty = false;
        const layer = self.status_layer;
        var b = self.client.batch();
        defer b.deinit();
        try b.clearArea(.{ .layer = layer, .bg = bg_status });

        const name = std.fs.path.basename(self.path);
        try b.writeTextOpts(name, .{ .layer = layer, .row = 0, .col = 1, .fg = fg_name, .bg = bg_status, .max_cols = self.win.cols -| 2 });

        var buf: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{d}x{d}  {s} {d}%  q quit  f/w/t/1 size  +/- zoom", .{
            self.image.w,
            self.image.h,
            self.mode.label(),
            @as(u32, @intFromFloat(@round(self.layout.scale * 100))),
        }) catch "";
        const detail_w = glyphwire.stringWidth(detail);
        if (detail_w > 0 and self.win.cols >= detail_w + glyphwire.stringWidth(name) + 4) {
            try b.writeTextOpts(detail, .{ .layer = layer, .row = 0, .col = self.win.cols - 1 - detail_w, .fg = fg_detail, .bg = bg_status });
        }
        var sent = try b.send();
        sent.deinit();
    }
};
