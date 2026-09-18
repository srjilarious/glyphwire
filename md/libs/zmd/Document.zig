//! A structured Markdown document -- a glyphwire addition to the vendored
//! zmd fork (see README.md), for renderers that lay text out themselves
//! instead of emitting HTML.
//!
//! zmd's `Ast` tokenizes the whole input as one flat stream, which has no
//! way to express containers: a list can't nest, and there are no block
//! quotes or thematic breaks. This is a line-based block pass instead --
//! CommonMark's container model, simplified -- that recurses into block
//! quotes and list items with their prefixes stripped, and hands each
//! leaf's text to `Inline.parse` once every reference definition in the
//! document is known.
//!
//! Blocks: ATX and setext headings, paragraphs, fenced (``` and ~~~) and
//! indented code, block quotes, bullet and ordered lists (nested, with GFM
//! task items), thematic breaks, GFM tables, and reference definitions.
//! YAML front matter and HTML comments are skipped. Other raw HTML is
//! kept as paragraph text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Inline = @import("Inline.zig");

pub const Run = Inline.Run;
pub const Style = Inline.Style;
pub const Link = Inline.Link;

const Document = @This();

arena: std.heap.ArenaAllocator,
blocks: []Block,
/// Every link in the document, in reading order. `Run.link` indexes this.
links: []Link,

/// Inline content: the raw source text, and the runs parsed from it once
/// the whole document (and so every reference definition) has been read.
pub const Text = struct {
    raw: []const u8,
    runs: []Run = &.{},
};

pub const Block = union(enum) {
    heading: Heading,
    paragraph: Text,
    code: Code,
    quote: []Block,
    list: List,
    rule,
    table: Table,
};

pub const Heading = struct {
    level: u8,
    text: Text,
    /// GitHub-style anchor (`#installing-glyphwire`), unique within the
    /// document: a repeated heading gets `-1`, `-2`, ... appended.
    slug: []const u8 = "",
};

pub const Code = struct {
    /// The fence's info string's first word (`zig` in ```` ```zig ````),
    /// or empty.
    lang: []const u8,
    text: []const u8,
};

pub const List = struct {
    ordered: bool,
    /// The first item's number, for an ordered list.
    start: u64 = 1,
    /// No blank line between any two items -- rendered without gaps.
    tight: bool = true,
    items: []Item,
};

pub const Item = struct {
    blocks: []Block,
    /// A GFM task item: `- [ ]` is `false`, `- [x]` is `true`.
    task: ?bool = null,
};

pub const Align = enum { none, left, center, right };

pub const Table = struct {
    aligns: []Align,
    header: []Text,
    /// Every row has exactly `header.len` cells, padded or truncated.
    rows: [][]Text,
};

pub fn deinit(self: *Document) void {
    self.arena.deinit();
}

/// Parses `input` into a document owning all of its memory.
pub fn parse(gpa: Allocator, input: []const u8) !Document {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const lines = try splitLines(a, input);
    var p: BlockParser = .{ .arena = a };
    const body = skipFrontMatter(lines);
    const blocks = try p.parseBlocks(body);

    var links: std.ArrayList(Link) = .empty;
    var slugs: std.StringHashMapUnmanaged(usize) = .empty;
    try resolveInlines(a, blocks, &p.refs, &links, &slugs);

    return .{ .arena = arena, .blocks = blocks, .links = links.items };
}

/// Lines without their terminators, `\r\n` normalized and tabs expanded to
/// four-column stops (so indentation arithmetic is in plain spaces).
fn splitLines(a: Allocator, input: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.indexOfScalar(u8, line, '\t') != null) {
            var buf: std.ArrayList(u8) = .empty;
            for (line) |c| {
                if (c == '\t') {
                    const pad = 4 - (buf.items.len % 4);
                    try buf.appendNTimes(a, ' ', pad);
                } else try buf.append(a, c);
            }
            line = buf.items;
        }
        try out.append(a, line);
    }
    // A trailing newline leaves one empty line behind; it's not content.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

/// YAML front matter: a `---` first line closed by a later `---` or `...`.
fn skipFrontMatter(lines: []const []const u8) []const []const u8 {
    if (lines.len == 0 or !std.mem.eql(u8, std.mem.trimEnd(u8, lines[0], " "), "---")) return lines;
    for (lines[1..], 1..) |l, i| {
        const t = std.mem.trimEnd(u8, l, " ");
        if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...")) return lines[i + 1 ..];
    }
    return lines;
}

fn resolveInlines(
    a: Allocator,
    blocks: []Block,
    refs: *const Inline.RefMap,
    links: *std.ArrayList(Link),
    slugs: *std.StringHashMapUnmanaged(usize),
) !void {
    for (blocks) |*b| switch (b.*) {
        .heading => |*h| {
            h.text.runs = try Inline.parse(a, h.text.raw, refs, links);
            h.slug = try uniqueSlug(a, try Inline.plainText(a, h.text.runs), slugs);
        },
        .paragraph => |*t| t.runs = try Inline.parse(a, t.raw, refs, links),
        .quote => |inner| try resolveInlines(a, inner, refs, links, slugs),
        .list => |l| for (l.items) |item| try resolveInlines(a, item.blocks, refs, links, slugs),
        .table => |tbl| {
            for (tbl.header) |*cell| cell.runs = try Inline.parse(a, cell.raw, refs, links);
            for (tbl.rows) |row| for (row) |*cell| {
                cell.runs = try Inline.parse(a, cell.raw, refs, links);
            };
        },
        .code, .rule => {},
    };
}

/// GitHub's anchor rule: lowercase, drop everything but letters, digits,
/// spaces, `-` and `_` (non-ASCII bytes are kept, so CJK headings still
/// get anchors), spaces become `-`. A repeat gets `-N` appended.
pub fn slugify(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, text, " ")) |c| {
        if (c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            try out.append(a, std.ascii.toLower(c));
        } else if (c == ' ') {
            try out.append(a, '-');
        }
    }
    return out.toOwnedSlice(a);
}

fn uniqueSlug(a: Allocator, text: []const u8, seen: *std.StringHashMapUnmanaged(usize)) ![]const u8 {
    const base = try slugify(a, text);
    const gop = try seen.getOrPut(a, base);
    if (!gop.found_existing) {
        gop.value_ptr.* = 0;
        return base;
    }
    gop.value_ptr.* += 1;
    return std.fmt.allocPrint(a, "{s}-{d}", .{ base, gop.value_ptr.* });
}

// ── Block parsing ────────────────────────────────────────────────────────

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " ").len == 0;
}

const Fence = struct { char: u8, len: usize, indent: usize, info: []const u8 };

fn fenceOpen(line: []const u8) ?Fence {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len) return null;
    const c = line[ind];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (ind + n < line.len and line[ind + n] == c) n += 1;
    if (n < 3) return null;
    const info = std.mem.trim(u8, line[ind + n ..], " ");
    // A backtick fence's info string can't itself contain a backtick --
    // that's an inline code span, not a fence.
    if (c == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .char = c, .len = n, .indent = ind, .info = info };
}

fn isFenceClose(line: []const u8, f: Fence) bool {
    const ind = indentOf(line);
    if (ind > 3) return false;
    const rest = std.mem.trimEnd(u8, line[ind..], " ");
    if (rest.len < f.len) return false;
    for (rest) |c| if (c != f.char) return false;
    return true;
}

fn atxLevel(line: []const u8) ?struct { level: u8, text: []const u8 } {
    const ind = indentOf(line);
    if (ind > 3) return null;
    var n: usize = 0;
    while (ind + n < line.len and line[ind + n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    const after = ind + n;
    if (after < line.len and line[after] != ' ') return null;
    var text = std.mem.trim(u8, line[after..], " ");
    // An optional closing run of `#`s, if it's separated by a space.
    const trimmed = std.mem.trimEnd(u8, text, "#");
    if (trimmed.len == 0) {
        text = "";
    } else if (trimmed.len < text.len and trimmed[trimmed.len - 1] == ' ') {
        text = std.mem.trimEnd(u8, trimmed, " ");
    }
    return .{ .level = @intCast(n), .text = text };
}

fn isRule(line: []const u8) bool {
    const ind = indentOf(line);
    if (ind > 3) return false;
    const rest = line[ind..];
    if (rest.len == 0) return false;
    const c = rest[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (rest) |ch| {
        if (ch == c) {
            count += 1;
        } else if (ch != ' ') return false;
    }
    return count >= 3;
}

/// `===` (level 1) or `---` (level 2) under a paragraph.
fn setextLevel(line: []const u8) ?u8 {
    const ind = indentOf(line);
    if (ind > 3) return null;
    const rest = std.mem.trimEnd(u8, line[ind..], " ");
    if (rest.len == 0) return null;
    const c = rest[0];
    if (c != '=' and c != '-') return null;
    for (rest) |ch| if (ch != c) return null;
    return if (c == '=') 1 else 2;
}

fn quoteContent(line: []const u8) ?[]const u8 {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len or line[ind] != '>') return null;
    var rest = line[ind + 1 ..];
    if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    return rest;
}

const Marker = struct {
    ordered: bool,
    /// The bullet character, or the ordered delimiter (`.` / `)`) --
    /// a change of either starts a new list.
    char: u8,
    number: u64 = 0,
    /// Column the item's content starts at: every continuation line must
    /// be indented at least this far to belong to the item.
    content_col: usize,
    empty: bool,
};

fn listMarker(line: []const u8) ?Marker {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len) return null;
    var end: usize = undefined;
    var m: Marker = undefined;
    const c = line[ind];
    if (c == '-' or c == '*' or c == '+') {
        end = ind + 1;
        m = .{ .ordered = false, .char = c, .content_col = 0, .empty = false };
    } else if (std.ascii.isDigit(c)) {
        var j = ind;
        while (j < line.len and j - ind < 9 and std.ascii.isDigit(line[j])) j += 1;
        if (j >= line.len or (line[j] != '.' and line[j] != ')')) return null;
        const num = std.fmt.parseInt(u64, line[ind..j], 10) catch return null;
        m = .{ .ordered = true, .char = line[j], .number = num, .content_col = 0, .empty = false };
        end = j + 1;
    } else return null;

    if (end < line.len and line[end] != ' ') return null;
    if (end >= line.len or isBlank(line[end..])) {
        m.content_col = end + 1;
        m.empty = true;
        return m;
    }
    var spaces: usize = 0;
    while (end + spaces < line.len and line[end + spaces] == ' ') spaces += 1;
    // Five or more spaces means the content is indented code; the item's
    // own content column is then just one space past the marker.
    m.content_col = if (spaces > 4) end + 1 else end + spaces;
    return m;
}

/// A GFM table row's cells: split on `|` outside code spans and escapes,
/// leading/trailing pipes dropped, each trimmed.
fn splitRow(a: Allocator, line: []const u8) ![][]const u8 {
    var s = std.mem.trim(u8, line, " ");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|' and (s.len < 2 or s[s.len - 2] != '\\')) s = s[0 .. s.len - 1];
    var cells: std.ArrayList([]const u8) = .empty;
    var cell: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_code: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and s[i + 1] == '|') {
            // `\|` is a literal pipe even inside a code span.
            try cell.append(a, '|');
            i += 1;
            continue;
        }
        if (c == '`') {
            var n: usize = 0;
            while (i + n < s.len and s[i + n] == '`') n += 1;
            if (in_code == 0) in_code = n else if (in_code == n) in_code = 0;
            try cell.appendSlice(a, s[i .. i + n]);
            i += n - 1;
            continue;
        }
        if (c == '|' and in_code == 0) {
            try cells.append(a, std.mem.trim(u8, cell.items, " "));
            cell = .empty;
            continue;
        }
        try cell.append(a, c);
    }
    try cells.append(a, std.mem.trim(u8, cell.items, " "));
    return cells.items;
}

fn separatorAligns(a: Allocator, line: []const u8) !?[]Align {
    if (std.mem.indexOfScalar(u8, line, '-') == null) return null;
    const trimmed = std.mem.trim(u8, line, " ");
    if (std.mem.indexOfScalar(u8, trimmed, '|') == null and trimmed.len > 0 and trimmed[0] != ':') {
        // A bare `---` is a rule or setext underline, not a one-column table.
        return null;
    }
    const cells = try splitRow(a, line);
    const aligns = try a.alloc(Align, cells.len);
    for (cells, aligns) |cell, *al| {
        if (cell.len == 0) return null;
        const left = cell[0] == ':';
        const right = cell[cell.len - 1] == ':';
        const dashes = cell[@intFromBool(left) .. cell.len - @intFromBool(right)];
        if (dashes.len == 0) return null;
        for (dashes) |c| if (c != '-') return null;
        al.* = if (left and right) .center else if (left) .left else if (right) .right else .none;
    }
    return aligns;
}

/// `[label]: destination "title"` on one line.
fn refDefinition(a: Allocator, line: []const u8) !?struct { label: []const u8, link: Link } {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len or line[ind] != '[') return null;
    const close = std.mem.indexOfScalarPos(u8, line, ind + 1, ']') orelse return null;
    if (close + 1 >= line.len or line[close + 1] != ':') return null;
    const label = line[ind + 1 .. close];
    if (std.mem.trim(u8, label, " ").len == 0) return null;
    var rest = std.mem.trim(u8, line[close + 2 ..], " ");
    if (rest.len == 0) return null;
    var href: []const u8 = undefined;
    if (rest[0] == '<') {
        const gt = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        href = rest[1..gt];
        rest = std.mem.trim(u8, rest[gt + 1 ..], " ");
    } else {
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        href = rest[0..sp];
        rest = std.mem.trim(u8, rest[sp..], " ");
    }
    var title: []const u8 = "";
    if (rest.len >= 2 and (rest[0] == '"' or rest[0] == '\'' or rest[0] == '(')) {
        title = rest[1 .. rest.len - 1];
    } else if (rest.len > 0) return null;
    return .{ .label = try Inline.normalizeLabel(a, label), .link = .{ .href = href, .title = title } };
}

const BlockParser = struct {
    arena: Allocator,
    refs: Inline.RefMap = .empty,

    /// True when `line` would start some block other than a paragraph --
    /// what ends a paragraph without a blank line, and what stops a
    /// "lazy" continuation line from joining a quote or list item.
    fn startsBlock(line: []const u8) bool {
        if (fenceOpen(line) != null or atxLevel(line) != null or isRule(line) or quoteContent(line) != null) return true;
        if (listMarker(line)) |m| {
            // Only a non-empty bullet, or an ordered list starting at 1,
            // may interrupt a paragraph -- otherwise "the year\n1999. was"
            // would become a list.
            return !m.empty and (!m.ordered or m.number == 1);
        }
        const ind = indentOf(line);
        return ind <= 3 and std.mem.startsWith(u8, line[ind..], "<!--");
    }

    fn parseBlocks(self: *BlockParser, lines: []const []const u8) error{OutOfMemory}![]Block {
        const a = self.arena;
        var blocks: std.ArrayList(Block) = .empty;
        var para: std.ArrayList([]const u8) = .empty;

        var i: usize = 0;
        while (i < lines.len) {
            const line = lines[i];

            if (isBlank(line)) {
                try self.endParagraph(&blocks, &para);
                i += 1;
                continue;
            }

            // Inside a paragraph, a setext underline turns it into a
            // heading -- checked before rules and lists, since `---` is
            // all three.
            if (para.items.len > 0) {
                if (setextLevel(line)) |level| {
                    const raw = try joinParagraph(a, para.items);
                    para.clearRetainingCapacity();
                    try blocks.append(a, .{ .heading = .{ .level = level, .text = .{ .raw = raw } } });
                    i += 1;
                    continue;
                }
                // A table header row can't interrupt a paragraph, but any
                // other block start can; everything else continues it.
                if (!startsBlock(line)) {
                    try para.append(a, line);
                    i += 1;
                    continue;
                }
            }

            const ind = indentOf(line);
            if (ind >= 4 and para.items.len == 0) {
                i = try self.indentedCode(lines, i, &blocks);
                continue;
            }
            if (fenceOpen(line)) |f| {
                try self.endParagraph(&blocks, &para);
                i = try self.fencedCode(lines, i, f, &blocks);
                continue;
            }
            if (atxLevel(line)) |h| {
                try self.endParagraph(&blocks, &para);
                try blocks.append(a, .{ .heading = .{ .level = h.level, .text = .{ .raw = h.text } } });
                i += 1;
                continue;
            }
            if (isRule(line)) {
                try self.endParagraph(&blocks, &para);
                try blocks.append(a, .rule);
                i += 1;
                continue;
            }
            if (quoteContent(line) != null) {
                try self.endParagraph(&blocks, &para);
                i = try self.blockQuote(lines, i, &blocks);
                continue;
            }
            if (listMarker(line) != null) {
                try self.endParagraph(&blocks, &para);
                i = try self.list(lines, i, &blocks);
                continue;
            }
            if (ind <= 3 and std.mem.startsWith(u8, line[ind..], "<!--")) {
                try self.endParagraph(&blocks, &para);
                i = skipComment(lines, i);
                continue;
            }
            if (i + 1 < lines.len and std.mem.indexOfScalar(u8, line, '|') != null) {
                if (try separatorAligns(a, lines[i + 1])) |aligns| {
                    const header = try splitRow(a, line);
                    if (header.len == aligns.len) {
                        i = try self.table(lines, i, header, aligns, &blocks);
                        continue;
                    }
                }
            }
            if (try refDefinition(a, line)) |def| {
                // First definition of a label wins, per CommonMark.
                const gop = try self.refs.getOrPut(a, def.label);
                if (!gop.found_existing) gop.value_ptr.* = def.link;
                i += 1;
                continue;
            }

            try para.append(a, line);
            i += 1;
        }
        try self.endParagraph(&blocks, &para);
        return blocks.items;
    }

    fn endParagraph(self: *BlockParser, blocks: *std.ArrayList(Block), para: *std.ArrayList([]const u8)) !void {
        if (para.items.len == 0) return;
        const raw = try joinParagraph(self.arena, para.items);
        para.clearRetainingCapacity();
        try blocks.append(self.arena, .{ .paragraph = .{ .raw = raw } });
    }

    fn indentedCode(self: *BlockParser, lines: []const []const u8, start: usize, blocks: *std.ArrayList(Block)) !usize {
        const a = self.arena;
        var body: std.ArrayList([]const u8) = .empty;
        var i = start;
        while (i < lines.len) : (i += 1) {
            const l = lines[i];
            if (isBlank(l)) {
                try body.append(a, "");
                continue;
            }
            if (indentOf(l) < 4) break;
            try body.append(a, l[4..]);
        }
        while (body.items.len > 0 and body.items[body.items.len - 1].len == 0) _ = body.pop();
        try blocks.append(a, .{ .code = .{ .lang = "", .text = try std.mem.join(a, "\n", body.items) } });
        return i;
    }

    fn fencedCode(self: *BlockParser, lines: []const []const u8, start: usize, f: Fence, blocks: *std.ArrayList(Block)) !usize {
        const a = self.arena;
        var body: std.ArrayList([]const u8) = .empty;
        var i = start + 1;
        while (i < lines.len) : (i += 1) {
            if (isFenceClose(lines[i], f)) {
                i += 1;
                break;
            }
            // Content lines lose up to the fence's own indentation.
            const l = lines[i];
            const strip = @min(indentOf(l), f.indent);
            try body.append(a, l[strip..]);
        }
        const lang_end = std.mem.indexOfAny(u8, f.info, " {") orelse f.info.len;
        try blocks.append(a, .{ .code = .{ .lang = f.info[0..lang_end], .text = try std.mem.join(a, "\n", body.items) } });
        return i;
    }

    fn blockQuote(self: *BlockParser, lines: []const []const u8, start: usize, blocks: *std.ArrayList(Block)) !usize {
        const a = self.arena;
        var inner: std.ArrayList([]const u8) = .empty;
        var i = start;
        while (i < lines.len) : (i += 1) {
            const l = lines[i];
            if (quoteContent(l)) |content| {
                try inner.append(a, content);
                continue;
            }
            // Lazy continuation: an unprefixed line carries on the quote's
            // paragraph, as long as it doesn't start a block of its own.
            if (isBlank(l) or startsBlock(l)) break;
            if (inner.items.len == 0 or isBlank(inner.items[inner.items.len - 1])) break;
            try inner.append(a, l);
        }
        try blocks.append(a, .{ .quote = try self.parseBlocks(inner.items) });
        return i;
    }

    fn list(self: *BlockParser, lines: []const []const u8, start: usize, blocks: *std.ArrayList(Block)) !usize {
        const a = self.arena;
        const first = listMarker(lines[start]).?;
        var items: std.ArrayList(Item) = .empty;
        var tight = true;
        var i = start;

        while (i < lines.len) {
            const m = listMarker(lines[i]) orelse break;
            if (m.ordered != first.ordered or m.char != first.char) break;

            // The item's lines, re-based to its content column.
            var body: std.ArrayList([]const u8) = .empty;
            const first_line = lines[i];
            try body.append(a, if (m.empty) "" else first_line[@min(m.content_col, first_line.len)..]);
            i += 1;
            var saw_blank = false;
            while (i < lines.len) : (i += 1) {
                const l = lines[i];
                if (isBlank(l)) {
                    saw_blank = true;
                    try body.append(a, "");
                    continue;
                }
                if (indentOf(l) >= m.content_col) {
                    try body.append(a, l[m.content_col..]);
                    saw_blank = false;
                    continue;
                }
                // Lazy paragraph continuation, only straight after text --
                // and never a list marker, which is this item's sibling
                // even where it couldn't interrupt a plain paragraph.
                if (!saw_blank and !startsBlock(l) and listMarker(l) == null and body.items.len > 0 and !isBlank(body.items[body.items.len - 1])) {
                    try body.append(a, std.mem.trimStart(u8, l, " "));
                    continue;
                }
                break;
            }
            // Trailing blank lines belong between items, not to this one;
            // they make the list loose if another item follows.
            var trailing: usize = 0;
            while (body.items.len > 0 and isBlank(body.items[body.items.len - 1])) {
                _ = body.pop();
                trailing += 1;
            }
            // A blank line *inside* an item, between two of its blocks,
            // also makes the list loose.
            for (body.items) |l| {
                if (isBlank(l)) tight = false;
            }

            var task: ?bool = null;
            if (body.items.len > 0) {
                const fl = body.items[0];
                if (fl.len >= 3 and fl[0] == '[' and fl[2] == ']' and (fl.len == 3 or fl[3] == ' ')) {
                    switch (fl[1]) {
                        ' ' => task = false,
                        'x', 'X' => task = true,
                        else => {},
                    }
                    if (task != null) body.items[0] = std.mem.trimStart(u8, fl[3..], " ");
                }
            }

            try items.append(a, .{ .blocks = try self.parseBlocks(body.items), .task = task });

            if (trailing > 0 and i < lines.len) {
                if (listMarker(lines[i])) |next| {
                    if (next.ordered == first.ordered and next.char == first.char) tight = false;
                }
            }
        }

        try blocks.append(a, .{ .list = .{ .ordered = first.ordered, .start = first.number, .tight = tight, .items = items.items } });
        return i;
    }

    fn table(self: *BlockParser, lines: []const []const u8, start: usize, header_cells: [][]const u8, aligns: []Align, blocks: *std.ArrayList(Block)) !usize {
        const a = self.arena;
        const ncols = header_cells.len;
        const header = try a.alloc(Text, ncols);
        for (header_cells, header) |c, *t| t.* = .{ .raw = c };

        var rows: std.ArrayList([]Text) = .empty;
        var i = start + 2;
        while (i < lines.len) : (i += 1) {
            const l = lines[i];
            if (isBlank(l) or startsBlock(l)) break;
            const cells = try splitRow(a, l);
            const row = try a.alloc(Text, ncols);
            for (row, 0..) |*t, ci| t.* = .{ .raw = if (ci < cells.len) cells[ci] else "" };
            try rows.append(a, row);
        }
        try blocks.append(a, .{ .table = .{ .aligns = aligns, .header = header, .rows = rows.items } });
        return i;
    }
};

/// A paragraph's lines joined with `\n` (soft breaks the inline pass turns
/// into spaces, or hard breaks when a line ends in two spaces), each
/// line's leading indentation dropped and the final line's trailing
/// spaces with it.
fn joinParagraph(a: Allocator, lines: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines, 0..) |l, n| {
        if (n > 0) try out.append(a, '\n');
        try out.appendSlice(a, std.mem.trimStart(u8, l, " "));
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

fn skipComment(lines: []const []const u8, start: usize) usize {
    var i = start;
    while (i < lines.len) : (i += 1) {
        if (std.mem.indexOf(u8, lines[i], "-->") != null) return i + 1;
    }
    return i;
}
