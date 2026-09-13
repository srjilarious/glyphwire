// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The OCR text a `mokuro` run leaves beside a manga volume: for every
//! page, the speech bubbles it found and the Japanese it read out of each
//! one.
//!
//! mokuro writes one `<volume>.mokuro` file -- a JSON object with a
//! `pages` array, one entry per image, each holding the image's pixel
//! dimensions and a list of `blocks`. A block is one bubble: a `box`
//! `[x1, y1, x2, y2]` in **image pixels**, a `vertical` flag, and the
//! `lines` of text as the OCR split them.
//!
//! Everything here is pure -- JSON and numbers in, structs and numbers
//! out -- so `tests/read_tests.zig` can pin the parse, the reading order,
//! the hit test and the wrap down without a display server or a book on
//! disk. `archive.zig` finds the file, `ui.zig` draws what comes out.
//!
//! **What this module deliberately does not do.** It never rejects a
//! volume. A page with a malformed block loses that block; a block with
//! no readable box or no lines is dropped; a `pages` array that isn't
//! there at all yields a volume with no pages, which the caller reports
//! as "no OCR for this book". Losing a bubble is a nuisance, refusing to
//! open the book over it is not a trade anyone wants -- the same rule
//! `state.zig` follows for a corrupt resume file.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// One bubble's bounding box, in the page image's own pixels. `x2`/`y2`
/// are exclusive, the way mokuro writes them.
pub const Box = struct {
    x1: i64 = 0,
    y1: i64 = 0,
    x2: i64 = 0,
    y2: i64 = 0,

    pub fn width(self: Box) i64 {
        return self.x2 - self.x1;
    }

    pub fn height(self: Box) i64 {
        return self.y2 - self.y1;
    }

    /// Pixel area, floored at zero so an inverted box (which a bad OCR
    /// run can emit) sorts last rather than winning every hit test with a
    /// negative "smallest" area.
    pub fn area(self: Box) i64 {
        const w = self.width();
        const h = self.height();
        if (w <= 0 or h <= 0) return 0;
        return w * h;
    }

    pub fn contains(self: Box, x: i64, y: i64) bool {
        return x >= self.x1 and x < self.x2 and y >= self.y1 and y < self.y2;
    }
};

/// One speech bubble: where it is, which way it reads, and what it says.
pub const Block = struct {
    box: Box = .{},
    /// True for the vertical columns Japanese normally sets in. Only used
    /// for the dialog's label today -- the text is rendered horizontally
    /// either way, since a terminal grid has no vertical writing mode.
    vertical: bool = true,
    /// The OCR's own line split, in the order mokuro emitted it. For a
    /// vertical block that is right-to-left *columns*, not sentence
    /// lines, which is why `joinLines` exists.
    lines: []const []const u8 = &.{},
};

/// One page's OCR. `img_path` is mokuro's name for the image, which is
/// matched against the archive's page names by `Volume.pageFor`.
pub const Page = struct {
    img_path: []const u8 = "",
    /// The pixel dimensions mokuro ran against. Every `Box` is in this
    /// space; `ui.zig` scales a click into it and the boxes back out.
    img_width: u32 = 0,
    img_height: u32 = 0,
    blocks: []const Block = &.{},
};

/// A parsed `.mokuro` file. Arena-backed: every string and slice below
/// points into it, and `deinit` frees the lot in one go.
pub const Volume = struct {
    arena: std.heap.ArenaAllocator,
    /// Volume title, as mokuro recorded it. Empty when the file didn't
    /// say -- the statusline falls back to the book's own name.
    title: []const u8 = "",
    pages: []Page = &.{},

    pub fn deinit(self: *Volume) void {
        self.arena.deinit();
    }

    /// The OCR for the archive page called `name`, or null when this
    /// volume has none for it.
    ///
    /// Three attempts, narrowing: the whole path as written, then the
    /// basename, then the basename with its extension dropped. An archive
    /// entry is `Vol1/images/003.jpg` while mokuro's `img_path` is often
    /// just `003.jpg` (and occasionally `003.png` for the same page, when
    /// the volume was converted after being OCR'd) -- so a bare-name and
    /// a stem match are both needed, and both are still exact matches on
    /// what they compare, never a prefix or a fuzzy one.
    pub fn pageFor(self: *const Volume, name: []const u8) ?*const Page {
        for (self.pages) |*p| {
            if (std.mem.eql(u8, p.img_path, name)) return p;
        }
        const base = basename(name);
        for (self.pages) |*p| {
            if (std.mem.eql(u8, basename(p.img_path), base)) return p;
        }
        const stem = dropExtension(base);
        if (stem.len == 0) return null;
        for (self.pages) |*p| {
            if (std.mem.eql(u8, dropExtension(basename(p.img_path)), stem)) return p;
        }
        return null;
    }

    /// How many of this volume's pages carry at least one block. Reported
    /// on the statusline so a volume whose `img_path`s don't line up with
    /// the archive's names is visible as "0 matched" rather than as a
    /// reader that silently never finds any text.
    pub fn pagesWithText(self: *const Volume) usize {
        var n: usize = 0;
        for (self.pages) |p| {
            if (p.blocks.len > 0) n += 1;
        }
        return n;
    }
};

/// `/`-separated basename. Archive entry names always use `/`, including
/// the ones that came from a directory walk on this platform.
fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn dropExtension(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    if (dot == 0) return name;
    return name[0..dot];
}

/// Parses a `.mokuro` file's contents. See the module comment for the
/// error policy: this never fails on bad *content*, only on running out
/// of memory.
pub fn parse(alloc: std.mem.Allocator, json: []const u8) std.mem.Allocator.Error!Volume {
    var vol: Volume = .{ .arena = .init(alloc) };
    errdefer vol.arena.deinit();
    const a = vol.arena.allocator();

    // Parsed into the arena and *not* freed: every string handed out
    // below is a slice of the parse tree, so the tree has to outlive the
    // volume. `std.json`'s own arena would be a second one to carry
    // around for no gain.
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return vol;

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return vol,
    };
    if (stringField(root, "title")) |t| vol.title = t;

    const raw_pages = switch (root.get("pages") orelse return vol) {
        .array => |arr| arr,
        else => return vol,
    };

    var pages: std.ArrayList(Page) = .empty;
    for (raw_pages.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        var page: Page = .{};
        if (stringField(obj, "img_path")) |p| page.img_path = p;
        page.img_width = @intCast(@max(intField(obj, "img_width") orelse 0, 0));
        page.img_height = @intCast(@max(intField(obj, "img_height") orelse 0, 0));
        page.blocks = try parseBlocks(a, obj);
        try pages.append(a, page);
    }
    vol.pages = try pages.toOwnedSlice(a);
    return vol;
}

fn parseBlocks(a: std.mem.Allocator, page_obj: std.json.ObjectMap) std.mem.Allocator.Error![]const Block {
    const raw = switch (page_obj.get("blocks") orelse return &.{}) {
        .array => |arr| arr,
        else => return &.{},
    };

    var blocks: std.ArrayList(Block) = .empty;
    for (raw.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const box = parseBox(obj) orelse continue;
        const lines = try parseLines(a, obj);
        // A bubble with no readable text is nothing to show and nothing
        // to click; dropping it here keeps every index in `blocks`
        // meaningful to the UI.
        if (lines.len == 0) continue;
        try blocks.append(a, .{
            .box = box,
            .vertical = boolField(obj, "vertical") orelse true,
            .lines = lines,
        });
    }
    return blocks.toOwnedSlice(a);
}

/// `"box": [x1, y1, x2, y2]`. Anything shorter, or holding a non-number,
/// is not a box. The corners are normalised so `x1 <= x2` regardless of
/// which way round they were written.
fn parseBox(obj: std.json.ObjectMap) ?Box {
    const arr = switch (obj.get("box") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len < 4) return null;
    var v: [4]i64 = undefined;
    for (arr.items[0..4], 0..) |item, i| {
        v[i] = switch (item) {
            .integer => |n| n,
            .float => |f| @intFromFloat(@round(f)),
            else => return null,
        };
    }
    return .{
        .x1 = @min(v[0], v[2]),
        .y1 = @min(v[1], v[3]),
        .x2 = @max(v[0], v[2]),
        .y2 = @max(v[1], v[3]),
    };
}

fn parseLines(a: std.mem.Allocator, obj: std.json.ObjectMap) std.mem.Allocator.Error![]const []const u8 {
    const arr = switch (obj.get("lines") orelse return &.{}) {
        .array => |v| v,
        else => return &.{},
    };
    var lines: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        const s = switch (item) {
            .string => |v| v,
            else => continue,
        };
        if (s.len == 0) continue;
        try lines.append(a, s);
    }
    return lines.toOwnedSlice(a);
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (obj.get(name) orelse return null) {
        .integer => |n| n,
        .float => |f| @intFromFloat(@round(f)),
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, name: []const u8) ?bool {
    return switch (obj.get(name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

// ── Reading order ───────────────────────────────────────────────────────

/// Which way the page's bubbles are read across. Mirrors
/// `config.Direction` without depending on it, so this module stays free
/// of the config's Lua machinery.
pub const Order = enum { rtl, ltr };

/// Fills `out` with `page`'s block indices in reading order and returns
/// the prefix that was written (`@min(out.len, blocks.len)`). `bands` is
/// scratch, one entry per block, and must be at least as long as `out`.
///
/// **The heuristic.** Bubbles are laid out in panels, not in rows, and
/// nothing in a `.mokuro` file says which panel a bubble belongs to. What
/// does hold on nearly every page is that you read *across* first and
/// *down* second: for manga, the top-right bubble, then leftward, then
/// the next band down. So the blocks are grouped into horizontal bands
/// and sorted across within each -- right to left for `rtl`, left to
/// right for `ltr`.
///
/// **The bands come from a sweep, not from a grid.** The obvious
/// implementation quantises each `y1` to a sixteenth of the page and
/// calls that the band, but then two bubbles 50px apart land in different
/// bands whenever the boundary happens to fall between them, and the
/// order flips for no reason the reader can see. Instead the blocks are
/// swept top-down and a new band starts only where the gap from the
/// band's *first* top edge exceeds `bandTolerance` -- so nearby tops group
/// however they are placed, and measuring from the band's start rather
/// than from the previous block stops a ladder of small steps from
/// chaining the whole page into one band.
///
/// It is still a heuristic and it will get a busy splash page wrong. That
/// is fine: `Tab` walking the bubbles in *roughly* the right order beats
/// no order at all, and clicking the bubble you want always works.
pub fn readingOrder(page: *const Page, order: Order, out: []usize, bands: []u32) []usize {
    const n = @min(@min(out.len, bands.len), page.blocks.len);
    for (0..n) |i| out[i] = i;
    if (n == 0) return out[0..0];

    // Sweep top-down first. `TopCtx` is a total order (top edge, then
    // index), so the band assignment below is deterministic.
    std.mem.sort(usize, out[0..n], page, TopCtx.lessThan);

    const tol = bandTolerance(page);
    var band: u32 = 0;
    var band_start: i64 = page.blocks[out[0]].box.y1;
    for (out[0..n]) |idx| {
        const y1 = page.blocks[idx].box.y1;
        if (y1 - band_start > tol) {
            band += 1;
            band_start = y1;
        }
        bands[idx] = band;
    }

    const ctx: SortCtx = .{ .page = page, .order = order, .bands = bands };
    std.mem.sort(usize, out[0..n], ctx, SortCtx.lessThan);
    return out[0..n];
}

/// How coarse the banding is: two bubbles whose top edges are within a
/// sixteenth of the page height of each other are read across, not down.
pub const band_fraction: i64 = 16;

/// The vertical gap that starts a new band. Derived from the page height
/// when the sidecar recorded one, else from how far down the page the
/// blocks themselves reach -- a sidecar with no dimensions still needs
/// *some* scale, and the blocks are the only other evidence there is.
fn bandTolerance(page: *const Page) i64 {
    var h: i64 = @intCast(page.img_height);
    if (h <= 0) {
        for (page.blocks) |b| h = @max(h, b.box.y2);
    }
    return @max(@divTrunc(h, band_fraction), 1);
}

const TopCtx = struct {
    fn lessThan(page: *const Page, a: usize, b: usize) bool {
        const ya = page.blocks[a].box.y1;
        const yb = page.blocks[b].box.y1;
        if (ya != yb) return ya < yb;
        return a < b;
    }
};

const SortCtx = struct {
    page: *const Page,
    order: Order,
    bands: []const u32,

    fn lessThan(self: SortCtx, a: usize, b: usize) bool {
        if (self.bands[a] != self.bands[b]) return self.bands[a] < self.bands[b];

        const ba = self.page.blocks[a].box;
        const bb = self.page.blocks[b].box;
        // Across the band. For `rtl` the *right* edge is the one that
        // orders bubbles the way the eye moves, so a wide bubble that
        // starts far left but ends further right still comes first.
        if (self.order == .rtl) {
            if (ba.x2 != bb.x2) return ba.x2 > bb.x2;
        } else {
            if (ba.x1 != bb.x1) return ba.x1 < bb.x1;
        }
        // Same band, same edge: fall back to the top edge and then to the
        // file order, so the sort is total and stable across runs.
        if (ba.y1 != bb.y1) return ba.y1 < bb.y1;
        return a < b;
    }
};

// ── Hit testing ─────────────────────────────────────────────────────────

/// The block whose box contains image pixel `(x, y)`, or null.
///
/// Boxes nest -- mokuro will happily report a small bubble inside the
/// bounds of a big one -- so the **smallest** containing box wins. That
/// is the one whose text you were pointing at; picking the first or the
/// topmost would make an inner bubble unclickable.
pub fn blockAt(page: *const Page, x: i64, y: i64) ?usize {
    var best: ?usize = null;
    var best_area: i64 = std.math.maxInt(i64);
    for (page.blocks, 0..) |b, i| {
        if (!b.box.contains(x, y)) continue;
        const a = b.box.area();
        if (a < best_area) {
            best_area = a;
            best = i;
        }
    }
    return best;
}

// ── Text shaping ────────────────────────────────────────────────────────

/// One block's `lines` joined back into running text. The caller owns the
/// result.
///
/// mokuro's line split follows the *bubble*, not the sentence: a vertical
/// bubble four columns wide gives four `lines` that each cut a sentence
/// mid-word. Joining them and re-wrapping to the dialog reads as prose,
/// which is the whole point of showing the text separately from the page.
///
/// **The separator rule.** Japanese runs together with nothing between
/// columns, so the default join is empty. A space goes in only when the
/// characters either side of the seam are both plain ASCII -- the case of
/// a bubble mokuro read as English (sound effects, a sign), where the
/// line break really was a word break and dropping it would fuse two
/// words. Anything with a CJK character on either side joins bare.
pub fn joinLines(alloc: std.mem.Allocator, lines: []const []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (lines) |line| {
        if (line.len == 0) continue;
        if (out.items.len > 0 and needsSpace(out.items[out.items.len - 1], line[0])) {
            try out.append(alloc, ' ');
        }
        try out.appendSlice(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

/// Both bytes ASCII and neither already a space: the only seam that gets
/// one. A multi-byte UTF-8 lead or continuation byte is >= 0x80, so this
/// is also the "neither side is CJK" test.
fn needsSpace(prev: u8, next: u8) bool {
    if (prev >= 0x80 or next >= 0x80) return false;
    return !std.ascii.isWhitespace(prev) and !std.ascii.isWhitespace(next);
}

/// Display width of `text` in cells -- wide (CJK/kana) codepoints count
/// two, matching how `write_text` advances the cursor.
pub fn displayWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return text.len;
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += len;
            w += 1;
            continue;
        };
        w += glyphwire.codepointWidth(cp);
        i += len;
    }
    return w;
}

/// Wraps `text` to `cols` display columns, returning the rows. The rows
/// are slices *into* `text`, so they live exactly as long as it does; the
/// slice holding them is the caller's to free.
///
/// Wrapping is per codepoint, not per word: Japanese has no spaces to
/// break at, so a word-wrap would put a whole bubble on one overflowing
/// line. An ASCII bubble does still break at a space when one is
/// available inside the row, so English in a sound effect doesn't get
/// chopped mid-word.
pub fn wrap(alloc: std.mem.Allocator, text: []const u8, cols: usize) std.mem.Allocator.Error![]const []const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(alloc);
    if (cols == 0 or text.len == 0) {
        if (text.len > 0) try rows.append(alloc, text);
        return rows.toOwnedSlice(alloc);
    }

    var start: usize = 0;
    var i: usize = 0;
    var w: usize = 0;
    // Byte offset of the last space seen in the row being built, so an
    // ASCII row can back up to it rather than breaking mid-word.
    var last_space: ?usize = null;

    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        const cw: usize = blk: {
            const cp = std.unicode.utf8Decode(text[i..end]) catch break :blk 1;
            break :blk glyphwire.codepointWidth(cp);
        };

        if (w + cw > cols and i > start) {
            // The character that overflowed is itself a space: the row
            // already ends on a word boundary, so break right here rather
            // than backing up to an earlier space and losing a whole word
            // off the end of a row that fitted exactly.
            const brk = if (text[i] == ' ')
                i
            else if (last_space) |sp|
                // Back up to the last space -- unless it is the row's own
                // first byte, which would emit an empty row.
                (if (sp > start) sp else i)
            else
                i;
            try rows.append(alloc, text[start..brk]);
            // A space that was broken *at* is consumed, not carried into
            // the next row as a leading blank.
            start = if (brk < text.len and text[brk] == ' ') brk + 1 else brk;
            i = start;
            w = 0;
            last_space = null;
            continue;
        }

        if (text[i] == ' ') last_space = i;
        w += cw;
        i = end;
    }
    if (start < text.len) try rows.append(alloc, text[start..]);
    return rows.toOwnedSlice(alloc);
}
