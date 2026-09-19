// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The Anki card's context image: the crop box's maths, in page-image
//! pixels, and the decode -> crop -> downscale -> JPEG that turns the
//! chosen box into card media.
//!
//! **Pixels, not cells.** The box is kept in the page image's own pixel
//! space, the space the JPEG is cut from, and only *drawn* at cell
//! granularity (ui.zig's `renderCrop`). A box kept in cells would change
//! size every time the zoom did, and would lose precision at a fit
//! scale where one cell covers a dozen image pixels.
//!
//! **Encoding is local.** The page bytes gw-read already reads from the
//! archive are decoded again here rather than fetched back from
//! glyphwire-host: the host never hands decoded pixels to clients, and
//! a re-decode of one page per card costs a few tens of milliseconds.
//! The decoder is stb_image, via `libs/stb/image_io.c`.
//!
//! Split into `read_support` so the box maths and the encoder can be
//! tested without a client.

const std = @import("std");

pub const Size = struct { w: i64, h: i64 };

/// A crop box in page-image pixels. `w`/`h` are always at least
/// `min_side` once it has been through any function here.
pub const Rect = struct {
    x: i64,
    y: i64,
    w: i64,
    h: i64,

    pub fn right(self: Rect) i64 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) i64 {
        return self.y + self.h;
    }
    pub fn contains(self: Rect, x: i64, y: i64) bool {
        return x >= self.x and x < self.right() and y >= self.y and y < self.bottom();
    }
};

/// Smallest box side, in image pixels. Small enough to frame one face,
/// big enough that a stray click can't collapse the box to nothing.
pub const min_side: i64 = 24;

/// What a pointer drag does to the box: move it whole, or pull one edge
/// or corner.
pub const Handle = enum {
    move,
    n,
    s,
    e,
    w,
    ne,
    nw,
    se,
    sw,

    fn pullsLeft(self: Handle) bool {
        return self == .w or self == .nw or self == .sw;
    }
    fn pullsRight(self: Handle) bool {
        return self == .e or self == .ne or self == .se;
    }
    fn pullsTop(self: Handle) bool {
        return self == .n or self == .ne or self == .nw;
    }
    fn pullsBottom(self: Handle) bool {
        return self == .s or self == .se or self == .sw;
    }
};

/// The box a card starts with: the speech bubble grown by its own longer
/// side in every direction, which on a typical page takes in the
/// speaker's face and the panel around it -- the "what was going on"
/// that makes the card worth having. Never smaller than a third of the
/// page's width or a fifth of its height, so a one-word bubble still
/// gets some scene, and clamped onto the page.
pub fn initial(bubble: Rect, bounds: Size) Rect {
    const margin = @max(bubble.w, bubble.h);
    var r: Rect = .{
        .x = bubble.x - margin,
        .y = bubble.y - margin,
        .w = bubble.w + 2 * margin,
        .h = bubble.h + 2 * margin,
    };
    const min_w = @divTrunc(bounds.w, 3);
    const min_h = @divTrunc(bounds.h, 5);
    if (r.w < min_w) {
        r.x -= @divTrunc(min_w - r.w, 2);
        r.w = min_w;
    }
    if (r.h < min_h) {
        r.y -= @divTrunc(min_h - r.h, 2);
        r.h = min_h;
    }
    return clamp(r, bounds);
}

/// `r` made to fit on the page: sized down to the page if bigger, up to
/// `min_side` if smaller, then slid (not shrunk) back inside it.
pub fn clamp(r: Rect, bounds: Size) Rect {
    const max_w = @max(bounds.w, 1);
    const max_h = @max(bounds.h, 1);
    const w = std.math.clamp(r.w, @min(min_side, max_w), max_w);
    const h = std.math.clamp(r.h, @min(min_side, max_h), max_h);
    return .{
        .x = std.math.clamp(r.x, 0, max_w - w),
        .y = std.math.clamp(r.y, 0, max_h - h),
        .w = w,
        .h = h,
    };
}

/// `start` after a drag of (`dx`, `dy`) image pixels on `handle`. A
/// move slides the box and stops it at the page edge; an edge pull stops
/// at the page edge and at `min_side` from the opposite edge, so a pull
/// past the other side pins rather than flips the box.
pub fn dragged(start: Rect, handle: Handle, dx: i64, dy: i64, bounds: Size) Rect {
    if (handle == .move) {
        return clamp(.{ .x = start.x + dx, .y = start.y + dy, .w = start.w, .h = start.h }, bounds);
    }
    var left = start.x;
    var top = start.y;
    var right_edge = start.right();
    var bottom_edge = start.bottom();
    if (handle.pullsLeft()) left = std.math.clamp(start.x + dx, 0, right_edge - min_side);
    if (handle.pullsRight()) right_edge = std.math.clamp(start.right() + dx, left + min_side, bounds.w);
    if (handle.pullsTop()) top = std.math.clamp(start.y + dy, 0, bottom_edge - min_side);
    if (handle.pullsBottom()) bottom_edge = std.math.clamp(start.bottom() + dy, top + min_side, bounds.h);
    return clamp(.{ .x = left, .y = top, .w = right_edge - left, .h = bottom_edge - top }, bounds);
}

/// `r` grown (`factor` > 1) or shrunk about its centre, then clamped.
/// The keyboard's resize, for when a drag is fiddly.
pub fn scaled(r: Rect, factor: f32, bounds: Size) Rect {
    const w: i64 = @intFromFloat(@round(@as(f32, @floatFromInt(r.w)) * factor));
    const h: i64 = @intFromFloat(@round(@as(f32, @floatFromInt(r.h)) * factor));
    const cx = r.x + @divTrunc(r.w, 2);
    const cy = r.y + @divTrunc(r.h, 2);
    return clamp(.{ .x = cx - @divTrunc(w, 2), .y = cy - @divTrunc(h, 2), .w = w, .h = h }, bounds);
}

/// Which handle a press at image pixel (`x`, `y`) grabs. Within `tol_x`
/// / `tol_y` of an edge (one cell's worth, from the caller) is that edge,
/// of two edges their corner; elsewhere inside is a move. A press
/// outside the box grabs its nearest corner, so the box can be pulled
/// out to wherever the pointer went down.
pub fn handleAt(r: Rect, x: i64, y: i64, tol_x: i64, tol_y: i64) Handle {
    const in_x = x >= r.x - tol_x and x <= r.right() + tol_x;
    const in_y = y >= r.y - tol_y and y <= r.bottom() + tol_y;
    if (!in_x or !in_y) return nearestCorner(r, x, y);

    const near_l = @abs(x - r.x) <= tol_x;
    const near_r = @abs(x - r.right()) <= tol_x;
    const near_t = @abs(y - r.y) <= tol_y;
    const near_b = @abs(y - r.bottom()) <= tol_y;
    // A box narrower than two tolerances is near both sides at once; the
    // side the press is closer to wins.
    const left = near_l and (!near_r or @abs(x - r.x) <= @abs(x - r.right()));
    const right_side = near_r and !left;
    const top = near_t and (!near_b or @abs(y - r.y) <= @abs(y - r.bottom()));
    const bottom_side = near_b and !top;

    if (top and left) return .nw;
    if (top and right_side) return .ne;
    if (bottom_side and left) return .sw;
    if (bottom_side and right_side) return .se;
    if (top) return .n;
    if (bottom_side) return .s;
    if (left) return .w;
    if (right_side) return .e;
    return .move;
}

/// The corner of `r` closest to (`x`, `y`) -- Alt+drag's grab, which
/// resizes from anywhere without having to find the edge.
pub fn nearestCorner(r: Rect, x: i64, y: i64) Handle {
    const west = x * 2 < r.x + r.right();
    const north = y * 2 < r.y + r.bottom();
    if (north) return if (west) .nw else .ne;
    return if (west) .sw else .se;
}

/// The size `r` is encoded at: its own, scaled down (never up) to fit
/// inside `max_w` x `max_h` with its aspect kept. A zero limit means no
/// limit on that axis.
pub fn outputSize(r: Rect, max_w: u32, max_h: u32) struct { w: u32, h: u32 } {
    const w: f64 = @floatFromInt(r.w);
    const h: f64 = @floatFromInt(r.h);
    var k: f64 = 1.0;
    if (max_w > 0) k = @min(k, @as(f64, @floatFromInt(max_w)) / w);
    if (max_h > 0) k = @min(k, @as(f64, @floatFromInt(max_h)) / h);
    return .{
        .w = @max(@as(u32, @intFromFloat(@round(w * k))), 1),
        .h = @max(@as(u32, @intFromFloat(@round(h * k))), 1),
    };
}

// ── Encoding ───────────────────────────────────────────────────────────

extern fn gwr_image_decode(data: [*]const u8, len: c_int, w: *c_int, h: *c_int) ?[*]u8;
extern fn gwr_image_free(pixels: [*]u8) void;
extern fn gwr_jpeg_encode(
    write: *const fn (ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void,
    ctx: ?*anyopaque,
    w: c_int,
    h: c_int,
    pixels: [*]const u8,
    quality: c_int,
) c_int;

pub const Encoded = struct {
    jpeg: []u8,
    width: u32,
    height: u32,
};

pub const EncodeOptions = struct {
    max_w: u32 = 800,
    max_h: u32 = 800,
    /// 1..100, stb_image_write's scale.
    quality: u8 = 85,
};

/// Cuts `r` out of `page` (encoded PNG/JPEG/BMP/GIF bytes), shrinks it to
/// `opts`' limits and returns it as a JPEG. `r` is clamped to the decoded
/// image first, so a box computed against slightly different dimensions
/// (a mokuro sidecar made from a re-encoded scan) still cuts cleanly.
pub fn encodeJpeg(alloc: std.mem.Allocator, page: []const u8, r: Rect, opts: EncodeOptions) !Encoded {
    var iw: c_int = 0;
    var ih: c_int = 0;
    const pixels = gwr_image_decode(page.ptr, @intCast(page.len), &iw, &ih) orelse return error.ImageDecodeFailed;
    defer gwr_image_free(pixels);
    const bounds: Size = .{ .w = iw, .h = ih };
    const box = clamp(r, bounds);

    const out_size = outputSize(box, opts.max_w, opts.max_h);
    const rgb = try alloc.alloc(u8, @as(usize, out_size.w) * out_size.h * 3);
    defer alloc.free(rgb);
    downscale(pixels[0..@as(usize, @intCast(iw * ih * 3))], @intCast(iw), box, rgb, out_size.w, out_size.h);

    var sink: Sink = .{ .alloc = alloc };
    errdefer sink.buf.deinit(alloc);
    const ok = gwr_jpeg_encode(Sink.write, &sink, @intCast(out_size.w), @intCast(out_size.h), rgb.ptr, std.math.clamp(opts.quality, 1, 100));
    if (ok == 0 or sink.failed) return error.JpegEncodeFailed;
    return .{ .jpeg = try sink.buf.toOwnedSlice(alloc), .width = out_size.w, .height = out_size.h };
}

/// Box-filter resample of `box` in the RGB image `src` (`src_w` wide)
/// into `dst` (`dw` x `dh`): each output pixel is the mean of the source
/// pixels under it. Only ever shrinks, which is where a box filter is at
/// its best and anything fancier wouldn't show on a card.
fn downscale(src: []const u8, src_w: usize, box: Rect, dst: []u8, dw: u32, dh: u32) void {
    const bx: usize = @intCast(box.x);
    const by: usize = @intCast(box.y);
    const bw: usize = @intCast(box.w);
    const bh: usize = @intCast(box.h);
    for (0..dh) |oy| {
        const sy0 = by + oy * bh / dh;
        const sy1 = @max(by + (oy + 1) * bh / dh, sy0 + 1);
        for (0..dw) |ox| {
            const sx0 = bx + ox * bw / dw;
            const sx1 = @max(bx + (ox + 1) * bw / dw, sx0 + 1);
            var sum = [3]u64{ 0, 0, 0 };
            for (sy0..sy1) |sy| {
                for (sx0..sx1) |sx| {
                    const p = (sy * src_w + sx) * 3;
                    sum[0] += src[p];
                    sum[1] += src[p + 1];
                    sum[2] += src[p + 2];
                }
            }
            const n: u64 = @intCast((sy1 - sy0) * (sx1 - sx0));
            const d = (oy * dw + ox) * 3;
            for (0..3) |c| dst[d + c] = @intCast(sum[c] / n);
        }
    }
}

/// stb_image_write's output callback, collecting into a growable buffer.
/// An allocation failure can't be returned through C, so it is recorded
/// and checked once the encoder finishes.
const Sink = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn write(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        if (self.failed or size <= 0) return;
        const bytes: [*]const u8 = @ptrCast(data.?);
        self.buf.appendSlice(self.alloc, bytes[0..@intCast(size)]) catch {
            self.failed = true;
        };
    }
};
