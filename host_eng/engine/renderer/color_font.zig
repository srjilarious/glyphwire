// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Reading colour bitmap glyphs out of a CBDT/CBLC font -- Google's PNG
//! emoji format, which Noto Color Emoji and most Linux emoji fonts use.
//!
//! stb_truetype can't help here: it draws outlines (`glyf` / `CFF `), and
//! a CBDT font has none, so `stbtt_InitFont` refuses it outright. What
//! such a font has instead is three tables this file reads directly:
//!
//!  - `cmap`: codepoint -> glyph id (formats 12 and 4).
//!  - `CBLC`: per strike (one bitmap size), glyph id -> where its data is
//!    in `CBDT` (index formats 1-5).
//!  - `CBDT`: per glyph, a PNG plus its metrics (image formats 17-19).
//!
//! Decoding the PNG is the caller's (`color_atlas.zig`, through zstbi), so
//! everything here is pure byte reading and is unit-tested against a
//! subset of Noto Color Emoji in `tests/data`. `downscaleRgba` is here for
//! the same reason: the atlas's resize, kept testable without a GPU.
//!
//! Malformed data reads as "no glyph" rather than an error: a bounds check
//! fails, and the codepoint falls through to the text fonts or the tofu
//! box, exactly as a codepoint the font never had.

const std = @import("std");

pub const ColorFont = struct {
    /// The whole font file. Borrowed.
    data: []const u8,
    cmap: Cmap,
    cblc: []const u8,
    cbdt: []const u8,

    /// Parses face `face_index` of `data` (0 for a plain font file).
    /// `error.NotAColorFont` when it has no CBDT/CBLC pair or no usable
    /// Unicode `cmap`.
    pub fn init(data: []const u8, face_index: u32) !ColorFont {
        const dir = try TableDir.init(data, face_index);
        const cmap_table = dir.find("cmap") orelse return error.NotAColorFont;
        const cblc = dir.find("CBLC") orelse return error.NotAColorFont;
        const cbdt = dir.find("CBDT") orelse return error.NotAColorFont;
        const cmap = Cmap.init(cmap_table) orelse return error.NotAColorFont;
        return .{ .data = data, .cmap = cmap, .cblc = cblc, .cbdt = cbdt };
    }

    /// The glyph id for `cp`, or 0 (`.notdef`) when the font lacks it.
    pub fn glyphIndex(self: *const ColorFont, cp: u32) u32 {
        return self.cmap.lookup(cp);
    }

    /// The PNG for `cp` from the strike best suited to `target_ppem`
    /// pixels (`pickStrike`), or null when the font has no bitmap for it.
    pub fn glyphFor(self: *const ColorFont, cp: u32, target_ppem: f32) ?Glyph {
        const gid = self.glyphIndex(cp);
        if (gid == 0) return null;
        const strike = self.pickStrike(target_ppem) orelse return null;
        return self.glyphInStrike(strike, gid);
    }

    /// The strike to draw from: the smallest whose ppem is at least
    /// `target_ppem`, so the bitmap is only ever scaled down, or else the
    /// biggest there is. Noto Color Emoji has a single 109 ppem strike.
    pub fn pickStrike(self: *const ColorFont, target_ppem: f32) ?Strike {
        const num = readInt(u32, self.cblc, 4) orelse return null;
        var best: ?Strike = null;
        var i: u32 = 0;
        while (i < num) : (i += 1) {
            const s = Strike.read(self.cblc, 8 + i * 48) orelse continue;
            const b = best orelse {
                best = s;
                continue;
            };
            const s_fits = @as(f32, @floatFromInt(s.ppem)) >= target_ppem;
            const b_fits = @as(f32, @floatFromInt(b.ppem)) >= target_ppem;
            if (s_fits and (!b_fits or s.ppem < b.ppem)) best = s;
            if (!s_fits and !b_fits and s.ppem > b.ppem) best = s;
        }
        return best;
    }

    fn glyphInStrike(self: *const ColorFont, strike: Strike, gid: u32) ?Glyph {
        var i: u32 = 0;
        while (i < strike.num_subtables) : (i += 1) {
            const entry = strike.array_offset + i * 8;
            const first = readInt(u16, self.cblc, entry) orelse return null;
            const last = readInt(u16, self.cblc, entry + 2) orelse return null;
            if (gid < first or gid > last) continue;
            const extra = readInt(u32, self.cblc, entry + 4) orelse return null;
            return self.glyphInSubtable(strike.array_offset + extra, first, gid, strike.ppem);
        }
        return null;
    }

    /// One `IndexSubTable`: where glyph `gid` (at or after the subtable's
    /// `first`) lives in `CBDT`, then the glyph record itself.
    fn glyphInSubtable(self: *const ColorFont, at: u32, first: u32, gid: u32, ppem: u8) ?Glyph {
        const index_format = readInt(u16, self.cblc, at) orelse return null;
        const image_format = readInt(u16, self.cblc, at + 2) orelse return null;
        const image_offset = readInt(u32, self.cblc, at + 4) orelse return null;
        const body = at + 8;
        const n = gid - first;

        var start: u32 = 0;
        var len: u32 = 0;
        // Formats 2 and 5 give every glyph the same size and metrics,
        // stored once here; image format 19 relies on them.
        var shared: ?Metrics = null;
        switch (index_format) {
            1 => {
                const a = readInt(u32, self.cblc, body + n * 4) orelse return null;
                const b = readInt(u32, self.cblc, body + n * 4 + 4) orelse return null;
                start = a;
                len = b -| a;
            },
            3 => {
                const a = readInt(u16, self.cblc, body + n * 2) orelse return null;
                const b = readInt(u16, self.cblc, body + n * 2 + 2) orelse return null;
                start = a;
                len = b -| a;
            },
            2 => {
                len = readInt(u32, self.cblc, body) orelse return null;
                shared = Metrics.readBig(self.cblc, body + 4) orelse return null;
                start = n * len;
            },
            4 => {
                const count = readInt(u32, self.cblc, body) orelse return null;
                var k: u32 = 0;
                while (k < count) : (k += 1) {
                    const pair = body + 4 + k * 4;
                    const id = readInt(u16, self.cblc, pair) orelse return null;
                    if (id != gid) continue;
                    const a = readInt(u16, self.cblc, pair + 2) orelse return null;
                    const b = readInt(u16, self.cblc, pair + 6) orelse return null;
                    start = a;
                    len = b -| a;
                    break;
                } else return null;
            },
            5 => {
                len = readInt(u32, self.cblc, body) orelse return null;
                shared = Metrics.readBig(self.cblc, body + 4) orelse return null;
                const count = readInt(u32, self.cblc, body + 12) orelse return null;
                var k: u32 = 0;
                while (k < count) : (k += 1) {
                    const id = readInt(u16, self.cblc, body + 16 + k * 2) orelse return null;
                    if (id == gid) break;
                } else return null;
                start = k * len;
            },
            else => return null,
        }
        if (len == 0) return null;
        return self.readGlyph(image_format, image_offset + start, len, shared, ppem);
    }

    /// A `CBDT` glyph record: metrics (unless the index carried them),
    /// then the PNG's length and bytes.
    fn readGlyph(self: *const ColorFont, format: u16, at: u32, len: u32, shared: ?Metrics, ppem: u8) ?Glyph {
        const record = slice(self.cbdt, at, len) orelse return null;
        const metrics: Metrics, const png_at: u32 = switch (format) {
            17 => .{ Metrics.readSmall(record, 0) orelse return null, 5 },
            18 => .{ Metrics.readBig(record, 0) orelse return null, 8 },
            19 => .{ shared orelse return null, 0 },
            else => return null,
        };
        const png_len = readInt(u32, record, png_at) orelse return null;
        const png = slice(record, png_at + 4, png_len) orelse return null;
        return .{ .png = png, .metrics = metrics, .ppem = ppem };
    }
};

/// One glyph's bitmap: a PNG (borrowed from the font data) and where it
/// sits, in the strike's pixels.
pub const Glyph = struct {
    png: []const u8,
    metrics: Metrics,
    /// The strike's pixels per em: what the metrics are measured against.
    ppem: u8,
};

/// A bitmap glyph's metrics, in strike pixels. Horizontal only: glyphwire
/// lays text out left to right.
pub const Metrics = struct {
    width: u8,
    height: u8,
    bearing_x: i8,
    /// From the baseline up to the bitmap's top.
    bearing_y: i8,
    advance: u8,

    /// `SmallGlyphMetrics`: height, width, bearingX, bearingY, advance.
    fn readSmall(b: []const u8, at: u32) ?Metrics {
        const m = slice(b, at, 5) orelse return null;
        return .{
            .height = m[0],
            .width = m[1],
            .bearing_x = @bitCast(m[2]),
            .bearing_y = @bitCast(m[3]),
            .advance = m[4],
        };
    }

    /// `BigGlyphMetrics`: the small set's horizontal half, then a
    /// vertical half this ignores.
    fn readBig(b: []const u8, at: u32) ?Metrics {
        _ = slice(b, at, 8) orelse return null;
        return readSmall(b, at);
    }
};

/// One `BitmapSize` record of `CBLC`: a strike.
pub const Strike = struct {
    /// Offset of its `IndexSubTableArray`, from the start of `CBLC`.
    array_offset: u32,
    num_subtables: u32,
    ppem: u8,

    fn read(cblc: []const u8, at: u32) ?Strike {
        _ = slice(cblc, at, 48) orelse return null;
        return .{
            .array_offset = readInt(u32, cblc, at).?,
            .num_subtables = readInt(u32, cblc, at + 8).?,
            // After the two 12-byte line metrics and the glyph range.
            .ppem = cblc[at + 45],
        };
    }
};

/// The font's table directory -- inside a `.ttc` collection, the one for
/// face `face_index`.
const TableDir = struct {
    data: []const u8,
    at: u32,
    count: u16,

    fn init(data: []const u8, face_index: u32) !TableDir {
        var at: u32 = 0;
        const tag = slice(data, 0, 4) orelse return error.NotAColorFont;
        if (std.mem.eql(u8, tag, "ttcf")) {
            const faces = readInt(u32, data, 8) orelse return error.NotAColorFont;
            if (face_index >= faces) return error.InvalidFontIndex;
            at = readInt(u32, data, 12 + face_index * 4) orelse return error.NotAColorFont;
        }
        const count = readInt(u16, data, at + 4) orelse return error.NotAColorFont;
        return .{ .data = data, .at = at, .count = count };
    }

    fn find(self: TableDir, tag: *const [4]u8) ?[]const u8 {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            const rec = self.at + 12 + i * 16;
            const t = slice(self.data, rec, 4) orelse return null;
            if (!std.mem.eql(u8, t, tag)) continue;
            const off = readInt(u32, self.data, rec + 8) orelse return null;
            const len = readInt(u32, self.data, rec + 12) orelse return null;
            return slice(self.data, off, len);
        }
        return null;
    }
};

/// The Unicode subtable of `cmap` that `lookup` reads: a full-range
/// format 12 when the font has one (emoji live above U+FFFF), else a BMP
/// format 4.
const Cmap = struct {
    sub: []const u8,
    format: u16,

    fn init(cmap: []const u8) ?Cmap {
        const n = readInt(u16, cmap, 2) orelse return null;
        var bmp: ?Cmap = null;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const rec = 4 + i * 8;
            const platform = readInt(u16, cmap, rec) orelse return null;
            const encoding = readInt(u16, cmap, rec + 2) orelse return null;
            const off = readInt(u32, cmap, rec + 4) orelse return null;
            const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
            if (!unicode) continue;
            const format = readInt(u16, cmap, off) orelse continue;
            const sub = cmap[@min(off, cmap.len)..];
            if (format == 12) return .{ .sub = sub, .format = 12 };
            if (format == 4 and bmp == null) bmp = .{ .sub = sub, .format = 4 };
        }
        return bmp;
    }

    fn lookup(self: Cmap, cp: u32) u32 {
        return switch (self.format) {
            12 => lookup12(self.sub, cp),
            4 => lookup4(self.sub, cp),
            else => 0,
        };
    }

    /// Sequential map groups: `startCharCode`, `endCharCode`,
    /// `startGlyphID`, sorted, so a binary search.
    fn lookup12(sub: []const u8, cp: u32) u32 {
        const groups = readInt(u32, sub, 12) orelse return 0;
        var lo: u32 = 0;
        var hi: u32 = groups;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const g = 16 + mid * 12;
            const start = readInt(u32, sub, g) orelse return 0;
            const end = readInt(u32, sub, g + 4) orelse return 0;
            if (cp < start) {
                hi = mid;
            } else if (cp > end) {
                lo = mid + 1;
            } else {
                const glyph = readInt(u32, sub, g + 8) orelse return 0;
                return glyph + (cp - start);
            }
        }
        return 0;
    }

    /// Segment mapping to delta values, the BMP-only format.
    fn lookup4(sub: []const u8, cp: u32) u32 {
        if (cp > 0xFFFF) return 0;
        const seg_x2: u32 = readInt(u16, sub, 6) orelse return 0;
        const ends = 14;
        const starts = ends + seg_x2 + 2;
        const deltas = starts + seg_x2;
        const range_offsets = deltas + seg_x2;
        var s: u32 = 0;
        while (s < seg_x2) : (s += 2) {
            const end = readInt(u16, sub, ends + s) orelse return 0;
            if (cp > end) continue;
            const start = readInt(u16, sub, starts + s) orelse return 0;
            if (cp < start) return 0;
            const delta = readInt(u16, sub, deltas + s) orelse return 0;
            const range = readInt(u16, sub, range_offsets + s) orelse return 0;
            if (range == 0) return (cp +% delta) & 0xFFFF;
            // `idRangeOffset` is relative to its own position.
            const at = range_offsets + s + range + (cp - start) * 2;
            const glyph = readInt(u16, sub, at) orelse return 0;
            if (glyph == 0) return 0;
            return (glyph +% delta) & 0xFFFF;
        }
        return 0;
    }
};

/// Whether face `face_index` of `data` is a colour bitmap font this file
/// can read -- what decides, for a font in the fallback list, between a
/// stb_truetype outline face and the colour atlas.
pub fn isColorFont(data: []const u8, face_index: u32) bool {
    _ = ColorFont.init(data, face_index) catch return false;
    return true;
}

/// Shrinks a straight-alpha RGBA bitmap into `dst` by area averaging:
/// each destination pixel is the coverage-weighted mean of the source
/// pixels under it, which is what a downscale of several times wants
/// (emoji strikes are ~5x a cell). Colour is averaged premultiplied and
/// divided back out, so the transparent pixels around an emoji don't
/// darken its edge the way a plain per-channel filter does.
///
/// Upscaling isn't its job: with `dw > sw` or `dh > sh` each destination
/// pixel still averages the (fractional) source area under it, which
/// comes out as a nearest-ish stretch.
pub fn downscaleRgba(src: []const u8, sw: usize, sh: usize, dst: []u8, dw: usize, dh: usize) void {
    std.debug.assert(src.len >= sw * sh * 4 and dst.len >= dw * dh * 4);
    const fx = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(dw));
    const fy = @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(dh));
    for (0..dh) |dy| {
        const y0 = @as(f64, @floatFromInt(dy)) * fy;
        const y1 = y0 + fy;
        for (0..dw) |dx| {
            const x0 = @as(f64, @floatFromInt(dx)) * fx;
            const x1 = x0 + fx;
            var acc = [4]f64{ 0, 0, 0, 0 };
            var area: f64 = 0;
            var sy: usize = @intFromFloat(@floor(y0));
            while (sy < sh and @as(f64, @floatFromInt(sy)) < y1) : (sy += 1) {
                const wy = overlap(y0, y1, sy);
                var sx: usize = @intFromFloat(@floor(x0));
                while (sx < sw and @as(f64, @floatFromInt(sx)) < x1) : (sx += 1) {
                    const w = wy * overlap(x0, x1, sx);
                    const p = src[(sy * sw + sx) * 4 ..][0..4];
                    const a = @as(f64, @floatFromInt(p[3])) / 255.0;
                    acc[0] += w * a * @as(f64, @floatFromInt(p[0]));
                    acc[1] += w * a * @as(f64, @floatFromInt(p[1]));
                    acc[2] += w * a * @as(f64, @floatFromInt(p[2]));
                    acc[3] += w * a;
                    area += w;
                }
            }
            const out = dst[(dy * dw + dx) * 4 ..][0..4];
            if (area == 0 or acc[3] == 0) {
                out.* = .{ 0, 0, 0, 0 };
                continue;
            }
            for (0..3) |c| out[c] = toByte(acc[c] / acc[3]);
            out[3] = toByte(acc[3] / area * 255.0);
        }
    }
}

/// How much of source pixel `i` (covering `[i, i+1)`) lies in `[lo, hi)`.
fn overlap(lo: f64, hi: f64, i: usize) f64 {
    const a = @as(f64, @floatFromInt(i));
    return @max(0, @min(hi, a + 1) - @max(lo, a));
}

fn toByte(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
}

/// `len` bytes of `b` from `at`, or null when they run past its end.
fn slice(b: []const u8, at: u32, len: u32) ?[]const u8 {
    const end = @as(u64, at) + len;
    if (end > b.len) return null;
    return b[at..@intCast(end)];
}

/// A big-endian integer at `at`, or null past the end of `b`.
fn readInt(comptime T: type, b: []const u8, at: u32) ?T {
    const bytes = slice(b, at, @sizeOf(T)) orelse return null;
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}
