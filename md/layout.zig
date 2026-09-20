// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gwmd's layout: a parsed `zmd.Document` turned into draw operations at
//! fixed cell positions on one tall layer.
//!
//! Pure -- no client, no IO. Everything the host would otherwise measure
//! is handed in: the layer width, the cell's pixel size (for images) and
//! a lookup for each image's pixel dimensions. That keeps word wrap,
//! heading scale, list/quote nesting and table sizing testable with
//! nothing but an allocator, and `renderText` turns a layout back into
//! plain text for the headless `--dump` path and for tests.
//!
//! Headings use `write_text`'s `scale`: h1 is 3x, h2 2x, h3 1.5x, and
//! h4-h6 stay normal size but take their own colour. A scaled glyph
//! advances `glyphwire.scaledPitch` cells per display column and draws
//! downward over the rows below its own, so a scaled line reserves that
//! many rows and wraps at a width divided by that pitch.

const std = @import("std");
const glyphwire = @import("glyphwire");
const zmd = @import("zmd");

const Doc = zmd.Document;
const Run = zmd.Inline.Run;
pub const Style = zmd.Inline.Style;
pub const Link = zmd.Inline.Link;

/// What a span *is*, for the UI's colour table -- the layout never picks
/// colours itself.
pub const Tone = enum { body, h1, h2, h3, h4, h5, h6, quote, code, marker, rule, muted };

pub const Span = struct {
    text: []const u8,
    style: Style = .{},
    tone: Tone = .body,
    link: ?usize = null,
    scale: glyphwire.TextScale = .x1,
};

pub const TextOp = struct { row: usize, col: usize, spans: []Span };

/// A solid background band -- a code block's panel.
pub const FillOp = struct { row: usize, col: usize, rows: usize, cols: usize, tone: Tone };

pub const ImageOp = struct {
    row: usize,
    col: usize,
    rows: usize,
    cols: usize,
    scale: f32,
    /// The source exactly as the document wrote it; the UI keys its
    /// loaded image handles on this.
    src: []const u8,
    /// Set for an image inside a link: the whole picture is clickable.
    link: ?usize,
};

pub const TableCell = struct {
    text: []const u8,
    tone: Tone = .body,
    /// The first link in the cell, if any -- a native table cell carries
    /// one metadata id, so a cell is clickable as a whole.
    link: ?usize = null,
};

pub const TableColumn = struct {
    name: []const u8,
    width: usize,
    h_align: glyphwire.HAlign = .start,
    /// `.wrap` when the table had to be shrunk to fit and this column
    /// ended up narrower than its widest cell -- see `Builder.table`.
    overflow: glyphwire.TableOverflow = .ellipsis,
};

pub const TableOp = struct {
    row: usize,
    col: usize,
    columns: []TableColumn,
    rows: [][]TableCell,
};

/// How many screen rows one body row takes: 1, or as many lines as its
/// tallest `.wrap` cell breaks into. The same rule the server's
/// `core.Table` paints by (a gwmd table has no icons and a `row_height`
/// of 1), since both wrap with `glyphwire.WrapIterator`.
pub fn tableRowHeight(columns: []const TableColumn, cells: []const TableCell) usize {
    var h: usize = 1;
    for (columns, cells) |c, cell| {
        if (c.overflow == .wrap) h = @max(h, glyphwire.wrapLineCount(cell.text, c.width));
    }
    return h;
}

pub const Op = union(enum) {
    text: TextOp,
    fill: FillOp,
    image: ImageOp,
    table: TableOp,
};

pub const Pos = struct { row: usize, col: usize };

pub const ImageSize = struct { w: u32, h: u32 };

/// Resolves an image source to its pixel size, or null when it can't be
/// shown (remote, missing, undecodable) -- the layout then prints a
/// placeholder instead.
pub const ImageLookup = struct {
    ctx: *const anyopaque,
    sizeOf: *const fn (ctx: *const anyopaque, src: []const u8) ?ImageSize,
};

pub const Options = struct {
    /// The layer's width in cells.
    width: usize,
    /// Text never runs wider than this, however wide the window; the
    /// column is centred in whatever is left.
    max_width: usize = 100,
    cell_w: u32 = 8,
    cell_h: u32 = 16,
    /// An image is scaled down to fit this many rows, so a tall picture
    /// still fits on one screen.
    max_image_rows: usize = 40,
    images: ?ImageLookup = null,
};

pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    ops: []Op,
    /// Rows the whole document occupies.
    rows: usize,
    /// The document's links, plus one for each remote image placeholder
    /// (clicking one opens the picture in a browser).
    links: []Link,
    /// Where each of `links` first appears, or null for a link that
    /// isn't drawn anywhere.
    link_pos: []?Pos,
    /// Heading slug -> the row it starts on.
    anchors: std.StringHashMapUnmanaged(usize),

    pub fn deinit(self: *Layout) void {
        self.arena.deinit();
    }

    pub fn anchorRow(self: *const Layout, slug: []const u8) ?usize {
        return self.anchors.get(slug);
    }

    /// Link indices in reading order (top to bottom, left to right) --
    /// Tab's cycle. Links that aren't drawn are left out. Caller owns
    /// the slice.
    pub fn tabOrder(self: *const Layout, alloc: std.mem.Allocator) ![]usize {
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(alloc);
        for (self.link_pos, 0..) |p, i| {
            if (p != null) try out.append(alloc, i);
        }
        const S = struct {
            fn lt(pos: []?Pos, a: usize, b: usize) bool {
                const pa = pos[a].?;
                const pb = pos[b].?;
                return pa.row < pb.row or (pa.row == pb.row and pa.col < pb.col);
            }
        };
        std.mem.sort(usize, out.items, self.link_pos, S.lt);
        return out.toOwnedSlice(alloc);
    }

    /// The layout as plain text, one line per row -- scaled glyphs padded
    /// out to their pitch, images as a bracketed box, tables with ASCII
    /// rules. What `gwmd --dump` prints, and what tests compare against.
    pub fn renderText(self: *const Layout, alloc: std.mem.Allocator) ![]u8 {
        var pieces: std.ArrayList(TextPiece) = .empty;
        defer pieces.deinit(alloc);
        var scratch: std.heap.ArenaAllocator = .init(alloc);
        defer scratch.deinit();
        const a = scratch.allocator();

        for (self.ops) |op| switch (op) {
            .text => |t| {
                var col = t.col;
                for (t.spans) |s| {
                    const pitch = glyphwire.scaledPitch(s.scale);
                    var buf: std.ArrayList(u8) = .empty;
                    var it = (std.unicode.Utf8View.init(s.text) catch continue).iterator();
                    while (it.nextCodepointSlice()) |cp| {
                        try buf.appendSlice(a, cp);
                        const w = glyphwire.stringWidth(cp);
                        try buf.appendNTimes(a, ' ', w * (pitch - 1));
                    }
                    try pieces.append(alloc, .{ .row = t.row, .col = col, .text = buf.items });
                    col += glyphwire.stringWidth(s.text) * pitch;
                }
            },
            .fill => {},
            .image => |im| {
                const label = try std.fmt.allocPrint(a, "[image {s} {d}x{d}]", .{ im.src, im.cols, im.rows });
                try pieces.append(alloc, .{ .row = im.row, .col = im.col, .text = label });
            },
            .table => |tb| {
                var r = tb.row;
                try pieces.append(alloc, .{ .row = r, .col = tb.col, .text = try tableRule(a, tb.columns) });
                r += 1;
                var header: std.ArrayList([]const u8) = .empty;
                for (tb.columns) |c| try header.append(a, c.name);
                try pieces.append(alloc, .{ .row = r, .col = tb.col, .text = try tableRow(a, tb.columns, header.items) });
                r += 1;
                try pieces.append(alloc, .{ .row = r, .col = tb.col, .text = try tableRule(a, tb.columns) });
                r += 1;
                for (tb.rows) |row| {
                    // One iterator per `.wrap` cell, stepped a line per
                    // screen row; an unwrapped cell shows on the first.
                    const wraps = try a.alloc(glyphwire.WrapIterator, row.len);
                    for (wraps, row, tb.columns) |*w, c, col| w.* = .init(c.text, col.width);
                    const h = tableRowHeight(tb.columns, row);
                    const cells = try a.alloc([]const u8, row.len);
                    for (0..h) |line| {
                        for (cells, row, tb.columns, wraps) |*out, c, col, *w| out.* = switch (col.overflow) {
                            .ellipsis => if (line == 0) c.text else "",
                            .wrap => w.next() orelse "",
                        };
                        try pieces.append(alloc, .{ .row = r, .col = tb.col, .text = try tableRow(a, tb.columns, cells) });
                        r += 1;
                    }
                }
                try pieces.append(alloc, .{ .row = r, .col = tb.col, .text = try tableRule(a, tb.columns) });
            },
        };

        std.mem.sort(TextPiece, pieces.items, {}, TextPiece.lt);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var row: usize = 0;
        var line_w: usize = 0;
        for (pieces.items) |p| {
            while (row < p.row) : (row += 1) {
                try trimLineEnd(alloc, &out);
                try out.append(alloc, '\n');
                line_w = 0;
            }
            if (p.col > line_w) {
                try out.appendNTimes(alloc, ' ', p.col - line_w);
                line_w = p.col;
            }
            try out.appendSlice(alloc, p.text);
            line_w += glyphwire.stringWidth(p.text);
        }
        while (row < self.rows) : (row += 1) {
            try trimLineEnd(alloc, &out);
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }
};

const TextPiece = struct {
    row: usize,
    col: usize,
    text: []const u8,
    fn lt(_: void, a: TextPiece, b: TextPiece) bool {
        return a.row < b.row or (a.row == b.row and a.col < b.col);
    }
};

fn trimLineEnd(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    _ = alloc;
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
}

fn tableRule(a: std.mem.Allocator, cols: []const TableColumn) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.append(a, '+');
    for (cols) |c| {
        try s.appendNTimes(a, '-', c.width);
        try s.append(a, '+');
    }
    return s.items;
}

fn tableRow(a: std.mem.Allocator, cols: []const TableColumn, cells: []const []const u8) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.append(a, '|');
    for (cols, cells) |c, text| {
        const clipped = clipToWidth(text, c.width);
        try s.appendSlice(a, clipped);
        try s.appendNTimes(a, ' ', c.width - glyphwire.stringWidth(clipped));
        try s.append(a, '|');
    }
    return s.items;
}

/// The longest prefix of `text` at most `max` display columns wide.
fn clipToWidth(text: []const u8, max: usize) []const u8 {
    var w: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return text).iterator();
    var end: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        const cw = glyphwire.stringWidth(cp);
        if (w + cw > max) break;
        w += cw;
        end += cp.len;
    }
    return text[0..end];
}

/// Lays out `doc` for a layer `opts.width` cells wide.
pub fn layout(gpa: std.mem.Allocator, doc: *const Doc, opts: Options) !Layout {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: Builder = .{ .a = a, .opts = opts };
    try b.links.appendSlice(a, doc.links);
    try b.link_pos.appendNTimes(a, null, doc.links.len);

    const content = @max(@min(opts.width -| 2, opts.max_width), 10);
    const margin = if (opts.width > content) (opts.width - content) / 2 else 0;

    // A row of breathing space above the first block.
    b.row = 1;
    try b.blocks(doc.blocks, margin, content, .{}, false);
    b.row += 1;

    return .{
        .arena = arena,
        .ops = b.ops.items,
        .rows = b.row,
        .links = b.links.items,
        .link_pos = b.link_pos.items,
        .anchors = b.anchors,
    };
}

const Ctx = struct {
    tone: Tone = .body,
    list_depth: usize = 0,
};

const Builder = struct {
    a: std.mem.Allocator,
    opts: Options,
    ops: std.ArrayList(Op) = .empty,
    row: usize = 0,
    links: std.ArrayList(Link) = .empty,
    link_pos: std.ArrayList(?Pos) = .empty,
    anchors: std.StringHashMapUnmanaged(usize) = .empty,

    fn blocks(self: *Builder, bs: []const Doc.Block, col: usize, width: usize, ctx: Ctx, tight: bool) error{OutOfMemory}!void {
        for (bs, 0..) |blk, i| {
            // One blank row between blocks, none inside a tight list item.
            if (i > 0 and !tight) self.row += 1;
            try self.block(blk, col, width, ctx);
        }
    }

    fn block(self: *Builder, blk: Doc.Block, col: usize, width: usize, ctx: Ctx) !void {
        switch (blk) {
            .heading => |h| try self.heading(h, col, width),
            .paragraph => |t| try self.flow(t.runs, col, width, ctx.tone, .x1),
            .code => |c| try self.codeBlock(c, col, width),
            .quote => |inner| try self.quote(inner, col, width, ctx),
            .list => |l| try self.list(l, col, width, ctx),
            .rule => try self.text(self.row, col, &.{.{ .text = try repeat(self.a, "─", width), .tone = .rule }}),
            .table => |t| try self.table(t, col, width),
        }
        switch (blk) {
            .rule => self.row += 1,
            else => {},
        }
    }

    fn heading(self: *Builder, h: Doc.Heading, col: usize, width: usize) !void {
        const scale: glyphwire.TextScale = switch (h.level) {
            1 => .x3,
            2 => .x2,
            3 => .x1_5,
            else => .x1,
        };
        const tone: Tone = switch (h.level) {
            1 => .h1,
            2 => .h2,
            3 => .h3,
            4 => .h4,
            5 => .h5,
            else => .h6,
        };
        // A heading repeated later in the document keeps the first row
        // for its bare slug -- `uniqueSlug` already made them distinct.
        try self.anchors.put(self.a, h.slug, self.row);
        try self.flow(h.text.runs, col, width, tone, scale);
        if (h.level <= 2) {
            try self.text(self.row, col, &.{.{ .text = try repeat(self.a, "─", width), .tone = .rule }});
            self.row += 1;
        }
    }

    fn codeBlock(self: *Builder, c: Doc.Code, col: usize, width: usize) !void {
        const inner = width -| 2;
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, c.text, '\n');
        while (it.next()) |l| {
            var rest = l;
            // Hard-wrap: code is never reflowed, but nothing may be lost
            // off the right edge either.
            while (glyphwire.stringWidth(rest) > inner) {
                const head = clipToWidth(rest, inner);
                if (head.len == 0) break;
                try lines.append(self.a, head);
                rest = rest[head.len..];
            }
            try lines.append(self.a, rest);
        }
        // A padding row above and below; the language sits in the top one.
        const rows = lines.items.len + 2;
        try self.ops.append(self.a, .{ .fill = .{ .row = self.row, .col = col, .rows = rows, .cols = width, .tone = .code } });
        if (c.lang.len > 0 and glyphwire.stringWidth(c.lang) + 2 <= width) {
            const lc = col + width - glyphwire.stringWidth(c.lang) - 1;
            try self.text(self.row, lc, &.{.{ .text = c.lang, .tone = .muted }});
        }
        for (lines.items, 0..) |l, i| {
            if (l.len == 0) continue;
            try self.text(self.row + 1 + i, col + 1, &.{.{ .text = l, .tone = .code }});
        }
        self.row += rows;
    }

    fn quote(self: *Builder, inner: []const Doc.Block, col: usize, width: usize, ctx: Ctx) !void {
        const top = self.row;
        var inner_ctx = ctx;
        inner_ctx.tone = .quote;
        try self.blocks(inner, col + 2, width -| 2, inner_ctx, false);
        var r = top;
        while (r < self.row) : (r += 1) {
            try self.text(r, col, &.{.{ .text = "▎", .tone = .quote }});
        }
    }

    fn list(self: *Builder, l: Doc.List, col: usize, width: usize, ctx: Ctx) !void {
        const bullets = [_][]const u8{ "•", "◦", "▪" };
        // Ordered markers share one width, sized for the largest number,
        // so the items' text lines up.
        const last = l.start + l.items.len -| 1;
        const num_w = std.fmt.count("{d}", .{last}) + 2;
        var inner_ctx = ctx;
        inner_ctx.list_depth += 1;

        for (l.items, 0..) |item, i| {
            if (i > 0 and !l.tight) self.row += 1;
            var marker: []const u8 = undefined;
            var mw: usize = undefined;
            var tone: Tone = .marker;
            if (item.task) |done| {
                marker = if (done) "[x]" else "[ ]";
                mw = 4;
                if (done) tone = .muted;
            } else if (l.ordered) {
                marker = try std.fmt.allocPrint(self.a, "{d}.", .{l.start + i});
                mw = num_w;
            } else {
                marker = bullets[ctx.list_depth % bullets.len];
                mw = 2;
            }
            const top = self.row;
            try self.blocks(item.blocks, col + mw, width -| mw, inner_ctx, l.tight);
            // An empty item still takes its marker's row.
            if (self.row == top) self.row += 1;
            // Right-align ordered numbers against the text column.
            const mcol = if (l.ordered and item.task == null) col + mw - 1 - glyphwire.stringWidth(marker) else col;
            try self.text(top, mcol, &.{.{ .text = marker, .tone = tone }});
        }
    }

    fn table(self: *Builder, t: Doc.Table, col: usize, width: usize) !void {
        const n = t.header.len;
        const columns = try self.a.alloc(TableColumn, n);
        for (columns, t.header, t.aligns) |*c, h, al| {
            const name = try zmd.Inline.plainText(self.a, h.runs);
            c.* = .{
                .name = name,
                .width = @max(glyphwire.stringWidth(name), 3),
                .h_align = switch (al) {
                    .center => .center,
                    .right => .end,
                    else => .start,
                },
            };
        }
        const rows = try self.a.alloc([]TableCell, t.rows.len);
        for (t.rows, rows) |src, *dst| {
            dst.* = try self.a.alloc(TableCell, n);
            for (src, dst.*, columns) |cell, *out, *c| {
                out.* = try self.tableCell(cell.runs);
                c.width = @max(c.width, glyphwire.stringWidth(out.text));
            }
        }

        // Borders plus one separator between each pair of columns; shrink
        // the widest column until the table fits, a column at a time.
        const overhead = n + 1;
        const avail = width -| overhead;
        while (true) {
            var total: usize = 0;
            var widest: usize = 0;
            for (columns, 0..) |c, i| {
                total += c.width;
                if (c.width > columns[widest].width) widest = i;
            }
            if (total <= avail or columns[widest].width <= 3) break;
            columns[widest].width -= 1;
        }

        // A column the shrink left narrower than one of its cells wraps
        // rather than cutting the cell off with "…" (a header still
        // ellipsizes). One that kept its full width stays on one line.
        for (columns, 0..) |*c, i| {
            for (rows) |row| {
                if (glyphwire.stringWidth(row[i].text) > c.width) c.overflow = .wrap;
            }
        }

        const top = self.row;
        try self.ops.append(self.a, .{ .table = .{ .row = top, .col = col, .columns = columns, .rows = rows } });

        // Record link positions on each cell's first line. Body rows
        // start at `top + 3` (top border, header, separator), each as
        // tall as `tableRowHeight` says.
        var r = top + 3;
        for (rows) |row| {
            var c = col + 1;
            for (row, columns) |cell, column| {
                if (cell.link) |li| self.notePos(li, r, c);
                c += column.width + 1;
            }
            r += tableRowHeight(columns, row);
        }
        self.row = r + 1;
    }

    fn tableCell(self: *Builder, runs: []const Run) !TableCell {
        var cell: TableCell = .{ .text = try zmd.Inline.plainText(self.a, runs) };
        var all_code = runs.len > 0;
        for (runs) |r| {
            if (cell.link == null and r.link != null) cell.link = r.link;
            if (!r.style.code) all_code = false;
        }
        if (all_code) cell.tone = .code;
        return cell;
    }

    // ── Inline flow ─────────────────────────────────────────────────────

    const Piece = struct {
        text: []const u8,
        style: Style,
        link: ?usize,
        space: bool,
    };

    /// Word-wraps `runs` into lines starting at `col`, `width` cells
    /// wide. Images interrupt the flow and take rows of their own; a hard
    /// break ends the line. Each line is `scaledPitch(scale)` rows tall.
    fn flow(self: *Builder, runs: []const Run, col: usize, width: usize, tone: Tone, scale: glyphwire.TextScale) !void {
        const pitch = glyphwire.scaledPitch(scale);
        var line: std.ArrayList(Piece) = .empty;
        var line_w: usize = 0;
        var word: std.ArrayList(Piece) = .empty;
        var word_w: usize = 0;

        const W = struct {
            fn cells(s: []const u8, p: usize) usize {
                return glyphwire.stringWidth(s) * p;
            }
        };

        for (runs) |r| {
            switch (r.kind) {
                .line_break => {
                    try self.placeWord(&line, &line_w, &word, &word_w, col, width, tone, scale);
                    try self.emitLine(&line, &line_w, col, tone, scale);
                    continue;
                },
                .image => {
                    try self.placeWord(&line, &line_w, &word, &word_w, col, width, tone, scale);
                    if (line.items.len > 0) try self.emitLine(&line, &line_w, col, tone, scale);
                    try self.image(r, col, width);
                    continue;
                },
                .text => {},
            }
            // Split the run into words and single spaces; a word may span
            // several runs ("**bold**," is one word), so pieces collect in
            // `word` until a space ends it.
            var i: usize = 0;
            while (i < r.text.len) {
                if (r.text[i] == ' ') {
                    try self.placeWord(&line, &line_w, &word, &word_w, col, width, tone, scale);
                    if (line.items.len > 0) {
                        try line.append(self.a, .{ .text = " ", .style = r.style, .link = r.link, .space = true });
                        line_w += pitch;
                    }
                    i += 1;
                    continue;
                }
                const end = std.mem.indexOfScalarPos(u8, r.text, i, ' ') orelse r.text.len;
                const piece = r.text[i..end];
                try word.append(self.a, .{ .text = piece, .style = r.style, .link = r.link, .space = false });
                word_w += W.cells(piece, pitch);
                i = end;
            }
        }
        try self.placeWord(&line, &line_w, &word, &word_w, col, width, tone, scale);
        if (line.items.len > 0) try self.emitLine(&line, &line_w, col, tone, scale);
    }

    /// Moves the pending word onto the line, wrapping first if it doesn't
    /// fit, and hard-splitting it if it's wider than a whole line.
    fn placeWord(
        self: *Builder,
        line: *std.ArrayList(Piece),
        line_w: *usize,
        word: *std.ArrayList(Piece),
        word_w: *usize,
        col: usize,
        width: usize,
        tone: Tone,
        scale: glyphwire.TextScale,
    ) !void {
        if (word.items.len == 0) return;
        defer {
            word.clearRetainingCapacity();
            word_w.* = 0;
        }
        const pitch = glyphwire.scaledPitch(scale);
        if (line_w.* + word_w.* > width and line.items.len > 0) {
            try self.emitLine(line, line_w, col, tone, scale);
        }
        if (word_w.* <= width) {
            try line.appendSlice(self.a, word.items);
            line_w.* += word_w.*;
            return;
        }
        // Wider than a line on its own (a long URL, a 3x word): break it
        // wherever the edge falls.
        for (word.items) |p| {
            var rest = p.text;
            while (rest.len > 0) {
                const room = (width -| line_w.*) / pitch;
                var head = clipToWidth(rest, room);
                if (head.len == 0) {
                    if (line.items.len > 0) {
                        try self.emitLine(line, line_w, col, tone, scale);
                        continue;
                    }
                    // Not even one character fits: take one anyway.
                    const one = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
                    head = rest[0..@min(one, rest.len)];
                }
                try line.append(self.a, .{ .text = head, .style = p.style, .link = p.link, .space = false });
                line_w.* += glyphwire.stringWidth(head) * pitch;
                rest = rest[head.len..];
            }
        }
    }

    fn emitLine(self: *Builder, line: *std.ArrayList(Piece), line_w: *usize, col: usize, tone: Tone, scale: glyphwire.TextScale) !void {
        defer {
            line.clearRetainingCapacity();
            line_w.* = 0;
        }
        // Trailing spaces would only paint a link's colour past its end.
        while (line.items.len > 0 and line.items[line.items.len - 1].space) _ = line.pop();

        var spans: std.ArrayList(Span) = .empty;
        var c = col;
        for (line.items) |p| {
            const w = glyphwire.stringWidth(p.text) * glyphwire.scaledPitch(scale);
            if (spans.items.len > 0) {
                const last = &spans.items[spans.items.len - 1];
                if (@as(u8, @bitCast(last.style)) == @as(u8, @bitCast(p.style)) and last.link == p.link) {
                    last.text = try std.mem.concat(self.a, u8, &.{ last.text, p.text });
                    c += w;
                    continue;
                }
            }
            if (p.link) |li| self.notePos(li, self.row, c);
            try spans.append(self.a, .{ .text = p.text, .style = p.style, .tone = tone, .link = p.link, .scale = scale });
            c += w;
        }
        if (spans.items.len > 0) try self.ops.append(self.a, .{ .text = .{ .row = self.row, .col = col, .spans = spans.items } });
        self.row += glyphwire.scaledPitch(scale);
    }

    fn image(self: *Builder, r: Run, col: usize, width: usize) error{OutOfMemory}!void {
        const size: ?ImageSize = if (self.opts.images) |im| im.sizeOf(im.ctx, r.src) else null;
        if (size) |sz| {
            if (sz.w > 0 and sz.h > 0) {
                const cw: f32 = @floatFromInt(@max(self.opts.cell_w, 1));
                const ch: f32 = @floatFromInt(@max(self.opts.cell_h, 1));
                const w: f32 = @floatFromInt(sz.w);
                const h: f32 = @floatFromInt(sz.h);
                // Never upscale; shrink to the text column's width and to
                // `max_image_rows`, whichever bites first.
                var scale: f32 = 1.0;
                scale = @min(scale, @as(f32, @floatFromInt(width)) * cw / w);
                scale = @min(scale, @as(f32, @floatFromInt(self.opts.max_image_rows)) * ch / h);
                const cols: usize = @max(@as(usize, @intFromFloat(@ceil(w * scale / cw))), 1);
                const rows: usize = @max(@as(usize, @intFromFloat(@ceil(h * scale / ch))), 1);
                try self.ops.append(self.a, .{ .image = .{
                    .row = self.row,
                    .col = col,
                    .rows = rows,
                    .cols = @min(cols, width),
                    .scale = scale,
                    .src = r.src,
                    .link = r.link,
                } });
                if (r.link) |li| self.notePos(li, self.row, col);
                self.row += rows;
                return;
            }
        }
        // Not showable: a placeholder line naming it. A remote image
        // links to itself so a click still gets you the picture.
        var link = r.link;
        if (link == null and isRemote(r.src)) {
            try self.links.append(self.a, .{ .href = r.src });
            try self.link_pos.append(self.a, null);
            link = self.links.items.len - 1;
        }
        const label = try std.fmt.allocPrint(self.a, "[image: {s}]", .{if (r.text.len > 0) r.text else r.src});
        try self.flow(&.{.{ .text = label, .link = link }}, col, width, .muted, .x1);
    }

    fn text(self: *Builder, row: usize, col: usize, spans: []const Span) !void {
        try self.ops.append(self.a, .{ .text = .{ .row = row, .col = col, .spans = try self.a.dupe(Span, spans) } });
    }

    fn notePos(self: *Builder, link: usize, row: usize, col: usize) void {
        if (link < self.link_pos.items.len and self.link_pos.items[link] == null)
            self.link_pos.items[link] = .{ .row = row, .col = col };
    }
};

/// Every image source in `doc`, in reading order, duplicates dropped --
/// what the UI loads before laying out. Borrowed from `doc`; the slice
/// itself is the caller's.
pub fn collectImages(alloc: std.mem.Allocator, doc: *const Doc) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    try collectFrom(alloc, doc.blocks, &out);
    return out.toOwnedSlice(alloc);
}

fn collectFrom(alloc: std.mem.Allocator, bs: []const Doc.Block, out: *std.ArrayList([]const u8)) !void {
    for (bs) |b| switch (b) {
        .heading => |h| try collectRuns(alloc, h.text.runs, out),
        .paragraph => |t| try collectRuns(alloc, t.runs, out),
        .quote => |inner| try collectFrom(alloc, inner, out),
        .list => |l| for (l.items) |item| try collectFrom(alloc, item.blocks, out),
        .code, .rule, .table => {},
    };
}

fn collectRuns(alloc: std.mem.Allocator, runs: []const Run, out: *std.ArrayList([]const u8)) !void {
    for (runs) |r| {
        if (r.kind != .image) continue;
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, r.src)) break;
        } else try out.append(alloc, r.src);
    }
}

pub fn isRemote(href: []const u8) bool {
    return std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://");
}

fn repeat(a: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
    const out = try a.alloc(u8, s.len * n);
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}
