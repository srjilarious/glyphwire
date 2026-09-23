// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gwmd's client half: a dedicated context holding the rendered page on
//! one tall layer, plus a one-row statusline.
//!
//! The page layer is the whole document at once -- as many rows as the
//! layout needs, with the window as its viewport -- in the default `host`
//! scroll mode (the one gw-read's page and zoe's tree pane use). Scrolling
//! is then just moving the viewport: arrows, PgUp/PgDn and Home/End send
//! `set_layer_scroll_offset`, and the wheel and scrollbar are the host's
//! own, reported back as `scroll_offset`. Nothing is redrawn to scroll.
//!
//! Every link occurrence gets a metadata blob (`{"kind":"link","href":...}`)
//! tagged on every cell it covers -- text, a table cell, or each row of a
//! linked image. A click resolves through `get_metadata`, Tab/Shift+Tab
//! move a highlight (`set_highlight`) through them in reading order and
//! Enter follows the highlighted one. What following means is `nav.zig`'s
//! call: a `#section` scrolls, a local Markdown file replaces the page
//! (with Backspace/Alt+Left and Alt+Right as back and forward), and
//! everything else goes to `xdg-open`.

const std = @import("std");
const glyphwire = @import("glyphwire");
const zmd = @import("zmd");
const layout_mod = @import("layout.zig");
const nav = @import("nav.zig");

const Layout = layout_mod.Layout;
const Tone = layout_mod.Tone;
const Color = glyphwire.Color;

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b };
}

const bg_page = rgb(24, 26, 31);
const bg_code = rgb(34, 38, 46);
const bg_inline_code = rgb(44, 49, 58);
const bg_status = rgb(40, 44, 52);
const bg_table_alt = rgb(30, 33, 39);
const fg_body = rgb(205, 209, 216);
const fg_bold = rgb(240, 241, 245);
const fg_italic = rgb(190, 205, 230);
const fg_strike = rgb(120, 124, 134);
const fg_link = rgb(88, 166, 255);
const fg_code = rgb(229, 192, 123);
const fg_code_block = rgb(171, 178, 191);
const fg_quote = rgb(140, 150, 162);
const fg_marker = rgb(229, 192, 123);
const fg_rule = rgb(70, 76, 88);
const fg_muted = rgb(110, 118, 129);
const fg_status = rgb(171, 178, 191);
const fg_h1 = rgb(97, 175, 239);
const fg_h2 = rgb(198, 120, 221);
const fg_h3 = rgb(86, 182, 194);
const fg_h4 = rgb(229, 192, 123);
const fg_h5 = rgb(152, 195, 121);
const fg_h6 = rgb(150, 156, 168);

fn toneColor(t: Tone) Color {
    return switch (t) {
        .body => fg_body,
        .h1 => fg_h1,
        .h2 => fg_h2,
        .h3 => fg_h3,
        .h4 => fg_h4,
        .h5 => fg_h5,
        .h6 => fg_h6,
        .quote => fg_quote,
        .code => fg_code_block,
        .marker => fg_marker,
        .rule => fg_rule,
        .muted => fg_muted,
    };
}

/// A span's foreground: a link's colour wins, then inline style, then the
/// block's tone. Headings keep their colour through bold/italic.
fn spanColor(s: layout_mod.Span) Color {
    if (s.link != null) return fg_link;
    if (s.style.code and s.tone != .code) return fg_code;
    switch (s.tone) {
        .body, .quote => {},
        else => return toneColor(s.tone),
    }
    if (s.style.strike) return fg_strike;
    if (s.style.bold) return fg_bold;
    if (s.style.italic) return fg_italic;
    return toneColor(s.tone);
}

const status_rows = 1;

/// One loaded image: the server handle and its pixel size. `handle` is
/// null for a source that couldn't be loaded, so a missing file is only
/// tried once per page.
const Image = struct {
    handle: ?glyphwire.ImageHandle,
    w: u32 = 0,
    h: u32 = 0,
};

/// Where the reader was, for Back and Forward.
const Visit = struct {
    path: []u8,
    scroll: usize,
};

/// Everything about the open file. Replaced wholesale on navigation.
const Page = struct {
    /// Absolute path of the file.
    path: []u8,
    source: []u8,
    doc: zmd.Document,
    /// Keyed by the source as written in the document (owned by `doc`).
    images: std.StringHashMapUnmanaged(Image) = .empty,

    fn dir(self: *const Page) []const u8 {
        return std.fs.path.dirname(self.path) orelse "/";
    }

    fn displayName(self: *const Page) []const u8 {
        return std.fs.path.basename(self.path);
    }
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
    cell: struct { w: u32, h: u32 },
    max_width: usize,

    page: ?Page = null,
    lay: ?Layout = null,
    /// One metadata handle per `lay.links` entry.
    metas: std.ArrayList(glyphwire.MetadataHandle) = .empty,
    tables: std.ArrayList(glyphwire.TableHandle) = .empty,
    /// `lay.tabOrder()`: link indices in reading order.
    tab_order: []usize = &.{},
    /// Position in `tab_order` of the highlighted link.
    focus: ?usize = null,
    /// The link under the pointer, for the statusline.
    hover: ?usize = null,

    scroll: usize = 0,
    back: std.ArrayList(Visit) = .empty,
    forward: std.ArrayList(Visit) = .empty,

    /// A transient statusline message; cleared on the next keystroke.
    message: ?[]u8 = null,
    status_dirty: bool = true,
    quit: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        max_width: usize,
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        // A dedicated context, shown immediately; no window scrollbar,
        // since the page layer draws its own.
        const context = try client.createContext(null, null, 0, false);
        errdefer client.destroyContext(context) catch {};
        try listener.attachContext(context);
        // A reader: nothing takes typed text, so no caret.
        try client.setCaretVisible(false);

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        const page_layer = try client.createLayer(size.cols, size.rows, 0);
        // Created after the page, so it composites on top.
        const status_layer = try client.createLayer(size.cols, status_rows, 0);

        try client.setLayerBackground(glyphwire.root_layer_handle, bg_page);
        try client.setLayerBackground(page_layer, bg_page);
        try client.setLayerBackground(status_layer, bg_status);

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
            .max_width = max_width,
        };
        return self;
    }

    pub fn deinit(self: *Ui) void {
        const alloc = self.alloc;
        self.closePage();
        self.metas.deinit(alloc);
        self.tables.deinit(alloc);
        for (self.back.items) |v| alloc.free(v.path);
        for (self.forward.items) |v| alloc.free(v.path);
        self.back.deinit(alloc);
        self.forward.deinit(alloc);
        if (self.message) |m| alloc.free(m);
        self.client.destroyContext(self.context) catch {};
        alloc.destroy(self);
    }

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            if (self.status_dirty) try self.renderStatus();
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
                // A font-size step changes the cell metrics too, and
                // arrives as one resize.
                if (self.client.getCellMetrics()) |m| {
                    self.cell = .{ .w = m.w, .h = m.h };
                } else |_| {}
                const old_rows = if (self.lay) |l| l.rows else 1;
                const old_scroll = self.scroll;
                try self.relayout();
                // Keep roughly the same part of the document in view --
                // the text reflows, so a row number means nothing.
                const new_rows = if (self.lay) |l| l.rows else 1;
                self.scrollTo(old_scroll * new_rows / @max(old_rows, 1));
            },
            .scroll_offset => |so| {
                // The wheel or the scrollbar: the host already moved the
                // viewport, so just follow it.
                if (so.layer == self.page_layer) {
                    self.scroll = so.row;
                    self.status_dirty = true;
                }
            },
            .mouse_move => |m| self.handleMouseMove(m),
            .mouse_button => |m| try self.handleMouseButton(m),
            .key => |k| if (k.pressed) try self.handleKey(k),
            .shutdown => self.quit = true,
            else => {},
        }
    }

    // ── Pages ───────────────────────────────────────────────────────────

    /// Opens `path` as the current page, scrolled to `fragment`'s heading
    /// if it names one. `path` is borrowed. On failure the current page
    /// stays and the statusline says why.
    pub fn open(self: *Ui, path: []const u8, fragment: []const u8) !void {
        const page = (try self.readPage(path)) orelse return;
        self.closePage();
        self.page = page;
        try self.loadImages();
        try self.relayout();
        self.scrollTo(self.anchorRow(fragment) orelse 0);
    }

    /// Reads and parses `path` into a `Page`, or sets the statusline and
    /// returns null when there's nothing there to read.
    fn readPage(self: *Ui, path: []const u8) !?Page {
        const abs = try self.absolutePath(path);
        defer self.alloc.free(abs);

        // A directory means its README, the way a forge shows one.
        const file = (try self.pickFile(abs)) orelse {
            try self.setMessage("{s}: no such file", .{path});
            return null;
        };
        errdefer self.alloc.free(file);

        const source = std.Io.Dir.cwd().readFileAlloc(self.io, file, self.alloc, .limited(64 * 1024 * 1024)) catch |err| {
            try self.setMessage("{s}: {t}", .{ path, err });
            self.alloc.free(file);
            return null;
        };
        errdefer self.alloc.free(source);
        const doc = try zmd.Document.parse(self.alloc, source);
        return .{ .path = file, .source = source, .doc = doc };
    }

    fn absolutePath(self: *Ui, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(self.alloc, &.{path});
        const cwd = try std.process.currentPathAlloc(self.io, self.alloc);
        defer self.alloc.free(cwd);
        return std.fs.path.resolve(self.alloc, &.{ cwd, path });
    }

    /// `abs` if it's a file; its README if it's a directory; null if
    /// neither exists. Caller owns the result.
    fn pickFile(self: *Ui, abs: []const u8) !?[]u8 {
        const stat = std.Io.Dir.cwd().statFile(self.io, abs, .{}) catch |err| switch (err) {
            error.IsDir => return self.readmeIn(abs),
            else => return null,
        };
        if (stat.kind == .directory) return self.readmeIn(abs);
        return try self.alloc.dupe(u8, abs);
    }

    fn readmeIn(self: *Ui, dir: []const u8) !?[]u8 {
        for ([_][]const u8{ "README.md", "readme.md", "Readme.md", "index.md" }) |name| {
            const candidate = try std.fs.path.join(self.alloc, &.{ dir, name });
            if (std.Io.Dir.cwd().statFile(self.io, candidate, .{})) |_| return candidate else |_| {}
            self.alloc.free(candidate);
        }
        return null;
    }

    /// Drops the page and everything it put on the server.
    fn closePage(self: *Ui) void {
        self.clearRendered();
        if (self.lay) |*l| l.deinit();
        self.lay = null;
        if (self.page) |*p| {
            var it = p.images.valueIterator();
            while (it.next()) |img| {
                if (img.handle) |h| self.client.destroyImage(h) catch {};
            }
            p.images.deinit(self.alloc);
            p.doc.deinit();
            self.alloc.free(p.source);
            self.alloc.free(p.path);
        }
        self.page = null;
    }

    /// Loads every local image the page shows, once, before the layout
    /// needs their sizes. A remote or unreadable one is remembered as a
    /// failure and gets a placeholder line instead.
    fn loadImages(self: *Ui) !void {
        const p = &(self.page orelse return);
        const srcs = try layout_mod.collectImages(self.alloc, &p.doc);
        defer self.alloc.free(srcs);
        for (srcs) |src| {
            try p.images.put(self.alloc, src, self.loadImage(p, src));
        }
    }

    fn loadImage(self: *Ui, p: *const Page, src: []const u8) Image {
        const target = nav.classify(self.alloc, src) catch return .{ .handle = null };
        const rel = switch (target) {
            .local => |l| l.path,
            else => return .{ .handle = null },
        };
        defer self.alloc.free(rel);
        const path = nav.resolve(self.alloc, p.dir(), rel) catch return .{ .handle = null };
        defer self.alloc.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(64 * 1024 * 1024)) catch return .{ .handle = null };
        defer self.alloc.free(bytes);
        const format = glyphwire.detectImageFormat(bytes) orelse return .{ .handle = null };
        const handle = self.client.loadImage(format.name(), bytes) catch return .{ .handle = null };
        const info = self.client.getImageInfo(handle) catch {
            self.client.destroyImage(handle) catch {};
            return .{ .handle = null };
        };
        return .{ .handle = handle, .w = info.width, .h = info.height };
    }

    fn imageSize(ctx: *const anyopaque, src: []const u8) ?layout_mod.ImageSize {
        const p: *const Page = @ptrCast(@alignCast(ctx));
        const img = p.images.get(src) orelse return null;
        if (img.handle == null) return null;
        return .{ .w = img.w, .h = img.h };
    }

    fn anchorRow(self: *const Ui, fragment: []const u8) ?usize {
        if (fragment.len == 0) return null;
        const l = &(self.lay orelse return null);
        // Heading rows start with the top padding already in them; back
        // off one so the heading isn't flush against the window edge.
        if (l.anchorRow(fragment)) |r| return r -| 1;
        // Anchors are lowercase; a hand-written link may not be.
        var buf: [256]u8 = undefined;
        if (fragment.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, fragment);
        if (l.anchorRow(lower)) |r| return r -| 1;
        return null;
    }

    // ── Rendering ───────────────────────────────────────────────────────

    fn viewRows(self: *const Ui) usize {
        return @max(self.win.rows -| status_rows, 1);
    }

    /// Lays the page out for the current window and redraws all of it.
    fn relayout(self: *Ui) !void {
        const p = &(self.page orelse return);
        self.clearRendered();
        if (self.lay) |*l| l.deinit();
        self.lay = null;

        self.lay = try layout_mod.layout(self.alloc, &p.doc, .{
            .width = self.win.cols,
            .max_width = self.max_width,
            .cell_w = self.cell.w,
            .cell_h = self.cell.h,
            .max_image_rows = @max(self.viewRows() -| 2, 4),
            .images = .{ .ctx = p, .sizeOf = imageSize },
        });
        self.tab_order = try self.lay.?.tabOrder(self.alloc);
        try self.render();
        self.status_dirty = true;
    }

    /// Frees what the last render created server-side: tables, metadata.
    fn clearRendered(self: *Ui) void {
        for (self.tables.items) |t| self.client.destroyTable(self.page_layer, t) catch {};
        self.tables.clearRetainingCapacity();
        for (self.metas.items) |m| self.client.destroyMetadata(m) catch {};
        self.metas.clearRetainingCapacity();
        if (self.tab_order.len > 0) self.alloc.free(self.tab_order);
        self.tab_order = &.{};
        if (self.focus != null) {
            var h = self.client.clearHighlight(self.page_layer) catch null;
            if (h) |*snap| snap.deinit();
        }
        self.focus = null;
        self.hover = null;
    }

    fn render(self: *Ui) !void {
        const l = &(self.lay orelse return);
        const p = &(self.page orelse return);
        const c = self.client;
        const view = self.viewRows();
        const rows = @max(l.rows, view);

        try c.setLayerSize(self.page_layer, self.win.cols, rows);
        try c.setLayerViewport(self.page_layer, self.win.cols, view);
        try c.setLayerScrollbars(self.page_layer, l.rows > view, false);
        try c.setLayerCellPosition(self.page_layer, 0, 0);
        try c.setLayerSize(self.status_layer, self.win.cols, status_rows);
        try c.setLayerCellPosition(self.status_layer, view, 0);

        // Pass 1: one metadata blob per link, in one round trip.
        {
            var mb = c.batch();
            defer mb.deinit();
            const slots = try self.alloc.alloc(glyphwire.Client.Batch.Slot, l.links.len);
            defer self.alloc.free(slots);
            for (l.links, slots) |link, *slot| {
                const json = try std.json.Stringify.valueAlloc(self.alloc, .{ .kind = "link", .href = link.href }, .{});
                defer self.alloc.free(json);
                slot.* = try mb.createMetadata(json);
            }
            if (l.links.len > 0) {
                var results = try mb.send();
                defer results.deinit();
                try self.metas.ensureTotalCapacity(self.alloc, l.links.len);
                for (slots) |slot| self.metas.appendAssumeCapacity(try results.metadataHandle(slot));
            }
        }

        // Pass 2: every draw in one batch, so the page never shows half
        // drawn.
        var b = c.batch();
        defer b.deinit();
        try b.clearOn(self.page_layer, 0, 0, null, null);
        var spans: std.ArrayList(glyphwire.Client.Span) = .empty;
        defer spans.deinit(self.alloc);
        for (l.ops) |op| switch (op) {
            .fill => |f| try b.clearArea(.{ .layer = self.page_layer, .row = f.row, .col = f.col, .rows = f.rows, .cols = f.cols, .bg = bg_code }),
            .text => |t| {
                spans.clearRetainingCapacity();
                for (t.spans) |s| {
                    const inline_code = s.style.code and s.tone != .code;
                    try spans.append(self.alloc, .{
                        .text = s.text,
                        .fg = spanColor(s),
                        .bg = if (inline_code) bg_inline_code else null,
                        .transparent_bg = !inline_code,
                        .metadata_id = if (s.link) |li| self.metas.items[li] else null,
                        .scale = s.scale,
                    });
                }
                try b.writeSpans(spans.items, .{ .layer = self.page_layer, .row = t.row, .col = t.col, .transparent_bg = true });
            },
            .image => |im| {
                const img = p.images.get(im.src) orelse continue;
                const handle = img.handle orelse continue;
                try b.drawImageOn(self.page_layer, handle, im.row, im.col, im.rows, im.cols, im.scale, .{});
                // A linked image: tag every cell it covers, leaving the
                // picture (the cells' background) in place.
                if (im.link) |li| {
                    const blank = try self.alloc.alloc(u8, im.cols);
                    defer self.alloc.free(blank);
                    @memset(blank, ' ');
                    for (0..im.rows) |r| {
                        try b.writeTextOpts(blank, .{
                            .layer = self.page_layer,
                            .row = im.row + r,
                            .col = im.col,
                            .transparent_bg = true,
                            .metadata_id = self.metas.items[li],
                        });
                    }
                }
            },
            .table => {},
        };
        try b.setLayerScrollOffset(self.page_layer, self.scroll, 0);
        var sent = try b.send();
        sent.deinit();

        // Tables last: each is a request (it hands back a handle).
        for (l.ops) |op| switch (op) {
            .table => |t| try self.drawTable(t),
            else => {},
        };
    }

    fn drawTable(self: *Ui, t: layout_mod.TableOp) !void {
        const c = self.client;
        const cols = try self.alloc.alloc(glyphwire.Client.TableColumnInput, t.columns.len);
        defer self.alloc.free(cols);
        for (t.columns, cols) |src, *dst| dst.* = .{ .name = src.name, .width = src.width, .h_align = src.h_align, .overflow = src.overflow };

        const handle = try c.createTable(self.page_layer, t.row, t.col, cols, .{
            .alt_row_bg = bg_table_alt,
            .header_fg = fg_h4,
        });
        try self.tables.append(self.alloc, handle);

        const rows = try self.alloc.alloc([]glyphwire.Client.TableCellInput, t.rows.len);
        defer {
            for (rows) |r| self.alloc.free(r);
            self.alloc.free(rows);
        }
        for (t.rows, rows) |src, *dst| {
            dst.* = try self.alloc.alloc(glyphwire.Client.TableCellInput, src.len);
            for (src, dst.*) |cell, *out| out.* = .{
                .display = cell.text,
                .fg = if (cell.link != null) fg_link else if (cell.tone == .code) fg_code else fg_body,
                .metadata_id = if (cell.link) |li| self.metas.items[li] else null,
            };
        }
        try c.tableSetRows(self.page_layer, handle, rows);
    }

    fn renderStatus(self: *Ui) !void {
        self.status_dirty = false;
        const cols = self.win.cols;
        var left_buf: [512]u8 = undefined;
        var right_buf: [64]u8 = undefined;

        const name = if (self.page) |*p| p.displayName() else "gwmd";
        const left: []const u8 = if (self.message) |m|
            std.fmt.bufPrint(&left_buf, " {s}", .{m}) catch " …"
        else if (self.shownLink()) |li|
            std.fmt.bufPrint(&left_buf, " {s}  →  {s}", .{ name, self.lay.?.links[li].href }) catch " …"
        else
            std.fmt.bufPrint(&left_buf, " {s}", .{name}) catch " …";

        const right: []const u8 = blk: {
            const l = self.lay orelse break :blk "";
            const view = self.viewRows();
            if (l.rows <= view) break :blk "All ";
            const max = l.rows - view;
            if (self.scroll == 0) break :blk "Top ";
            if (self.scroll >= max) break :blk "Bot ";
            break :blk std.fmt.bufPrint(&right_buf, "{d}% ", .{self.scroll * 100 / max}) catch "";
        };

        const right_w = glyphwire.stringWidth(right);
        const left_max = cols -| right_w;
        var b = self.client.batch();
        defer b.deinit();
        try b.writeTextOpts(left, .{
            .layer = self.status_layer,
            .row = 0,
            .col = 0,
            .fg = if (self.message != null) fg_code else fg_status,
            .bg = bg_status,
            .max_cols = left_max,
            .pad = true,
        });
        try b.writeTextOpts(right, .{ .layer = self.status_layer, .row = 0, .col = left_max, .fg = fg_muted, .bg = bg_status });
        var sent = try b.send();
        sent.deinit();
    }

    /// The link the statusline describes: the one under the pointer, or
    /// else the Tab-highlighted one.
    fn shownLink(self: *const Ui) ?usize {
        if (self.hover) |h| return h;
        if (self.focus) |f| return self.tab_order[f];
        return null;
    }

    // ── Scrolling ───────────────────────────────────────────────────────

    fn maxScroll(self: *const Ui) usize {
        const l = self.lay orelse return 0;
        return l.rows -| self.viewRows();
    }

    fn scrollTo(self: *Ui, row: usize) void {
        self.scroll = @min(row, self.maxScroll());
        self.client.setLayerScrollOffset(self.page_layer, self.scroll, 0) catch {};
        self.status_dirty = true;
    }

    fn scrollBy(self: *Ui, delta: i64) void {
        const target: usize = if (delta < 0) self.scroll -| @as(usize, @intCast(-delta)) else self.scroll + @as(usize, @intCast(delta));
        self.scrollTo(target);
    }

    /// One screenful, less a row of overlap so the last line read stays
    /// in view.
    fn pageStep(self: *const Ui) i64 {
        return @intCast(@max(self.viewRows() -| 1, 1));
    }

    // ── Input ───────────────────────────────────────────────────────────

    fn handleKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const key = k.key;
        const eq = std.mem.eql;
        self.clearMessage();

        if (eq(u8, key, "q")) {
            self.quit = true;
            return;
        }
        if (eq(u8, key, "escape")) {
            // Escape drops a Tab highlight before it quits.
            if (self.focus != null) return self.setFocus(null);
            self.quit = true;
            return;
        }

        if (k.alt() and eq(u8, key, "left")) return self.goBack();
        if (k.alt() and eq(u8, key, "right")) return self.goForward();
        if (eq(u8, key, "backspace")) return self.goBack();

        if (eq(u8, key, "up") or eq(u8, key, "k")) return self.scrollBy(-1);
        if (eq(u8, key, "down") or eq(u8, key, "j")) return self.scrollBy(1);
        if (eq(u8, key, "page_up") or eq(u8, key, "b")) return self.scrollBy(-self.pageStep());
        if (eq(u8, key, "page_down") or eq(u8, key, "space")) return self.scrollBy(self.pageStep());
        if (eq(u8, key, "home")) return self.scrollTo(0);
        if (eq(u8, key, "end")) return self.scrollTo(self.maxScroll());
        if (eq(u8, key, "g")) return if (k.shift()) self.scrollTo(self.maxScroll()) else self.scrollTo(0);

        if (eq(u8, key, "tab")) return self.stepFocus(if (k.shift()) -1 else 1);
        if (eq(u8, key, "enter") or eq(u8, key, "kp_enter")) {
            if (self.focus) |f| try self.follow(self.tab_order[f]);
            return;
        }
        if (eq(u8, key, "r")) return self.reload();
    }

    /// Moves the Tab highlight `delta` links along reading order. The
    /// first Tab starts from whatever is on screen rather than the top of
    /// the document, so it lands somewhere visible.
    fn stepFocus(self: *Ui, delta: i64) !void {
        const n = self.tab_order.len;
        if (n == 0) {
            try self.setMessage("no links on this page", .{});
            return;
        }
        const next: usize = if (self.focus) |f|
            @intCast(@mod(@as(i64, @intCast(f)) + delta, @as(i64, @intCast(n))))
        else blk: {
            const l = &self.lay.?;
            if (delta > 0) {
                for (self.tab_order, 0..) |li, i| {
                    if (l.link_pos[li].?.row >= self.scroll) break :blk i;
                }
                break :blk 0;
            }
            const bottom = self.scroll + self.viewRows();
            var i = n;
            while (i > 0) {
                i -= 1;
                if (l.link_pos[self.tab_order[i]].?.row < bottom) break :blk i;
            }
            break :blk n - 1;
        };
        self.setFocus(next);
    }

    fn setFocus(self: *Ui, at: ?usize) void {
        self.focus = at;
        self.status_dirty = true;
        if (at) |f| {
            const li = self.tab_order[f];
            var h = self.client.setHighlight(self.page_layer, &.{self.metas.items[li]}) catch null;
            if (h) |*snap| snap.deinit();
            // Bring it on screen, with a little context above.
            const row = self.lay.?.link_pos[li].?.row;
            const view = self.viewRows();
            if (row < self.scroll or row >= self.scroll + view) self.scrollTo(row -| view / 3);
        } else {
            var h = self.client.clearHighlight(self.page_layer) catch null;
            if (h) |*snap| snap.deinit();
        }
    }

    /// The page-layer cell under window cell `cell`, or null when it's
    /// over the statusline.
    fn pageCell(self: *const Ui, cell: glyphwire.CellPos) ?glyphwire.CellPos {
        if (cell.row >= self.viewRows()) return null;
        return .{ .row = cell.row + self.scroll, .col = cell.col };
    }

    fn linkAt(self: *Ui, cell: glyphwire.CellPos) ?usize {
        const pc = self.pageCell(cell) orelse return null;
        const hit = self.client.getMetadata(self.page_layer, pc.row, pc.col, 0) catch return null;
        if (hit.json) |j| self.alloc.free(j);
        const id = hit.id orelse return null;
        for (self.metas.items, 0..) |m, i| {
            if (m == id) return i;
        }
        return null;
    }

    fn handleMouseMove(self: *Ui, ev: glyphwire.MouseMoveEvent) void {
        const li = self.linkAt(ev.cell);
        if (li != self.hover) {
            self.hover = li;
            self.status_dirty = true;
        }
    }

    fn handleMouseButton(self: *Ui, ev: glyphwire.MouseButtonEvent) !void {
        if (!ev.pressed or !std.mem.eql(u8, ev.button, "left")) return;
        const li = self.linkAt(ev.cell) orelse return;
        try self.follow(li);
    }

    // ── Following links ─────────────────────────────────────────────────

    fn follow(self: *Ui, li: usize) !void {
        const l = &(self.lay orelse return);
        const href = l.links[li].href;
        const target = try nav.classify(self.alloc, href);
        switch (target) {
            .anchor => |slug| {
                const row = self.anchorRow(slug) orelse {
                    try self.setMessage("no heading #{s} on this page", .{slug});
                    return;
                };
                try self.pushVisit(&self.back);
                self.clearVisits(&self.forward);
                self.setFocus(null);
                self.scrollTo(row);
            },
            .external => |url| try self.openExternal(url),
            .local => |loc| {
                defer self.alloc.free(loc.path);
                const p = &(self.page orelse return);
                const abs = try nav.resolve(self.alloc, p.dir(), loc.path);
                defer self.alloc.free(abs);
                if (!nav.isMarkdownPath(abs) and !self.isDirectory(abs)) return self.openExternal(abs);
                // Copied: `open` replaces the page, and with it the layout
                // `loc.fragment` points into.
                const fragment = try self.alloc.dupe(u8, loc.fragment);
                defer self.alloc.free(fragment);
                try self.pushVisit(&self.back);
                self.clearVisits(&self.forward);
                try self.open(abs, fragment);
            },
        }
    }

    fn isDirectory(self: *Ui, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| return err == error.IsDir;
        return stat.kind == .directory;
    }

    /// Hands `target` to the desktop's opener. `setsid -f` detaches it
    /// straight away: some `xdg-open` backends block until the browser
    /// exits, and the reader shouldn't wait for that.
    fn openExternal(self: *Ui, target: []const u8) !void {
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "setsid", "-f", "xdg-open", target },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            try self.setMessage("couldn't run xdg-open ({t})", .{err});
            return;
        };
        _ = child.wait(self.io) catch {};
        try self.setMessage("opening {s}", .{target});
    }

    fn pushVisit(self: *Ui, list: *std.ArrayList(Visit)) !void {
        const p = &(self.page orelse return);
        try list.append(self.alloc, .{ .path = try self.alloc.dupe(u8, p.path), .scroll = self.scroll });
    }

    fn clearVisits(self: *Ui, list: *std.ArrayList(Visit)) void {
        for (list.items) |v| self.alloc.free(v.path);
        list.clearRetainingCapacity();
    }

    fn goBack(self: *Ui) !void {
        const v = self.back.pop() orelse {
            try self.setMessage("nothing to go back to", .{});
            return;
        };
        defer self.alloc.free(v.path);
        try self.pushVisit(&self.forward);
        try self.revisit(v);
    }

    fn goForward(self: *Ui) !void {
        const v = self.forward.pop() orelse return;
        defer self.alloc.free(v.path);
        try self.pushVisit(&self.back);
        try self.revisit(v);
    }

    /// Returns to a remembered visit: the same file only scrolls (an
    /// in-page `#anchor` jump), another file is reopened.
    fn revisit(self: *Ui, v: Visit) !void {
        const same = if (self.page) |*p| std.mem.eql(u8, p.path, v.path) else false;
        if (!same) try self.open(v.path, "");
        self.setFocus(null);
        self.scrollTo(v.scroll);
    }

    /// Re-reads the file from disk, keeping the scroll position.
    fn reload(self: *Ui) !void {
        const p = &(self.page orelse return);
        const path = try self.alloc.dupe(u8, p.path);
        defer self.alloc.free(path);
        const keep = self.scroll;
        try self.open(path, "");
        self.scrollTo(keep);
    }

    fn setMessage(self: *Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.message) |m| self.alloc.free(m);
        self.message = try std.fmt.allocPrint(self.alloc, fmt, args);
        self.status_dirty = true;
    }

    fn clearMessage(self: *Ui) void {
        if (self.message) |m| {
            self.alloc.free(m);
            self.message = null;
            self.status_dirty = true;
        }
    }
};
