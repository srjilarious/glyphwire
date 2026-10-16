// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The picture that follows the pointer during a drag out of the window:
//! an icon and a one-line label on a bordered card, rasterised on the CPU
//! into the premultiplied ARGB8888 bytes a `wl_shm` buffer takes.
//!
//! CPU rather than GL because the drag icon is a separate Wayland surface
//! the renderer has no context for, and it is drawn once per drag -- a
//! few thousand pixels, so a readback through a framebuffer would be more
//! machinery for nothing. The label goes through stb_truetype straight
//! from the session's font file, with no fallback chain: a glyph the
//! primary face lacks is skipped.

const std = @import("std");
const stb_tt = @import("stb_truetype");
const stbi = @import("zstbi");

const core = @import("core.zig");

pub const Style = struct {
    bg: core.Color8,
    fg: core.Color8,
    border: core.Color8,
};

pub const Options = struct {
    /// The icon as encoded PNG bytes, or null for a label-only card.
    icon_png: ?[]const u8 = null,
    label: []const u8,
    /// The session font file and collection face the label is set in.
    font_path: []const u8,
    face_index: i32 = 0,
    /// Glyph pixel height in *buffer* pixels, i.e. already multiplied by
    /// `scale`.
    font_px: f32,
    /// Buffer pixels per surface unit. The card's sides come out as
    /// multiples of it, as `wl_surface.set_buffer_scale` requires.
    scale: u32 = 1,
    /// The label is cut off past this many surface units of width.
    max_width: u32 = 360,
    style: Style,
};

/// Premultiplied ARGB8888 pixels: B, G, R, A bytes per pixel, rows
/// `width * 4` bytes apart. Free with `deinit`.
pub const Image = struct {
    width: u32,
    height: u32,
    scale: u32,
    pixels: []u8,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

pub fn render(alloc: std.mem.Allocator, opts: Options) !Image {
    const io = std.Io.Threaded.global_single_threaded.io();
    const font_data = try std.Io.Dir.cwd().readFileAlloc(io, opts.font_path, alloc, .unlimited);
    defer alloc.free(font_data);

    const offset = stb_tt.c.stbtt_GetFontOffsetForIndex(font_data.ptr, opts.face_index);
    if (offset < 0) return error.InvalidFontIndex;
    var font: stb_tt.c.stbtt_fontinfo = undefined;
    if (stb_tt.c.stbtt_InitFont(&font, font_data.ptr, offset) == 0) return error.InvalidFont;
    const font_scale = stb_tt.c.stbtt_ScaleForPixelHeight(&font, opts.font_px);

    var ascent: i32 = 0;
    var descent: i32 = 0;
    var line_gap: i32 = 0;
    stb_tt.c.stbtt_GetFontVMetrics(&font, &ascent, &descent, &line_gap);
    const ascent_px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(ascent)) * font_scale));
    const line_px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(ascent - descent)) * font_scale));

    const scale: i32 = @intCast(@max(opts.scale, 1));
    const pad = 6 * scale;
    const gap = 6 * scale;
    const icon_px: i32 = if (opts.icon_png != null) @max(line_px + 4 * scale, 16 * scale) else 0;
    const content_h = @max(icon_px, line_px);
    const max_text_w = @as(i32, @intCast(opts.max_width)) * scale - 2 * pad - icon_px - gap;
    const text_w = @min(measure(&font, font_scale, opts.label), @max(max_text_w, 0));

    const width = roundUp(pad + icon_px + (if (icon_px > 0) gap else 0) + text_w + pad, scale);
    const height = roundUp(pad + content_h + pad, scale);

    var canvas = try Canvas.init(alloc, @intCast(width), @intCast(height));
    errdefer canvas.deinit(alloc);

    canvas.fill(opts.style.border);
    canvas.fillRect(scale, scale, width - 2 * scale, height - 2 * scale, opts.style.bg);

    var x = pad;
    if (opts.icon_png) |png| {
        const icon_y = pad + @divTrunc(content_h - icon_px, 2);
        canvas.drawPng(png, x, icon_y, icon_px) catch |err| {
            std.log.warn("drag icon: couldn't decode the icon: {t}", .{err});
        };
        x += icon_px + gap;
    }
    const baseline = pad + @divTrunc(content_h - line_px, 2) + ascent_px;
    try canvas.drawText(alloc, &font, font_scale, opts.label, x, baseline, x + text_w, opts.style.fg);

    return .{ .width = @intCast(width), .height = @intCast(height), .scale = @intCast(scale), .pixels = canvas.toArgb() };
}

fn roundUp(v: i32, step: i32) i32 {
    return @divTrunc(v + step - 1, step) * step;
}

/// The label's advance width in pixels, kerning included.
fn measure(font: *const stb_tt.c.stbtt_fontinfo, font_scale: f32, text: []const u8) i32 {
    var width: f32 = 0;
    var prev: ?u21 = null;
    var it = (std.unicode.Utf8View.init(text) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        if (prev) |p| width += font_scale * @as(f32, @floatFromInt(stb_tt.c.stbtt_GetCodepointKernAdvance(font, p, cp)));
        var advance: i32 = 0;
        var lsb: i32 = 0;
        stb_tt.c.stbtt_GetCodepointHMetrics(font, cp, &advance, &lsb);
        width += font_scale * @as(f32, @floatFromInt(advance));
        prev = cp;
    }
    return @intFromFloat(@ceil(width));
}

/// Premultiplied RGBA, composited with "over" and converted to the wire's
/// byte order once at the end.
const Canvas = struct {
    w: i32,
    h: i32,
    px: []u8,

    fn init(alloc: std.mem.Allocator, w: u32, h: u32) !Canvas {
        const px = try alloc.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        return .{ .w = @intCast(w), .h = @intCast(h), .px = px };
    }

    fn deinit(self: *Canvas, alloc: std.mem.Allocator) void {
        alloc.free(self.px);
    }

    fn fill(self: *Canvas, c: core.Color8) void {
        self.fillRect(0, 0, self.w, self.h, c);
    }

    fn fillRect(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, c: core.Color8) void {
        var y = @max(y0, 0);
        while (y < @min(y0 + h, self.h)) : (y += 1) {
            var x = @max(x0, 0);
            while (x < @min(x0 + w, self.w)) : (x += 1) self.put(x, y, premul(c.r, c.g, c.b, c.a));
        }
    }

    /// Sets a pixel outright (no blending) -- the card's fills.
    fn put(self: *Canvas, x: i32, y: i32, rgba: [4]u8) void {
        const i: usize = @intCast((y * self.w + x) * 4);
        @memcpy(self.px[i..][0..4], &rgba);
    }

    /// Composites one premultiplied pixel over what's there.
    fn blend(self: *Canvas, x: i32, y: i32, src: [4]u8) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const i: usize = @intCast((y * self.w + x) * 4);
        const dst = self.px[i..][0..4];
        const inv: u32 = 255 - src[3];
        for (0..4) |k| dst[k] = @intCast(@min(255, @as(u32, src[k]) + (@as(u32, dst[k]) * inv + 127) / 255));
    }

    /// Decodes `png` and draws it into a `size` square at (`x0`, `y0`),
    /// box-filtered down (or nearest-neighbour up) to fit.
    fn drawPng(self: *Canvas, png: []const u8, x0: i32, y0: i32, size: i32) !void {
        var img = try stbi.Image.loadFromMemory(png, 4);
        defer img.deinit();
        if (img.width == 0 or img.height == 0 or size <= 0) return;

        // Fit inside the square, keeping the aspect ratio.
        const sw: f32 = @floatFromInt(img.width);
        const sh: f32 = @floatFromInt(img.height);
        const fit = @as(f32, @floatFromInt(size)) / @max(sw, sh);
        const dw: i32 = @max(1, @as(i32, @intFromFloat(@round(sw * fit))));
        const dh: i32 = @max(1, @as(i32, @intFromFloat(@round(sh * fit))));
        const ox = x0 + @divTrunc(size - dw, 2);
        const oy = y0 + @divTrunc(size - dh, 2);

        var dy: i32 = 0;
        while (dy < dh) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < dw) : (dx += 1) {
                self.blend(ox + dx, oy + dy, sampleBox(&img, dx, dy, dw, dh));
            }
        }
    }

    /// Draws `text` with its baseline at `baseline`, from `x0`, cutting off
    /// at `x_max`.
    fn drawText(self: *Canvas, alloc: std.mem.Allocator, font: *const stb_tt.c.stbtt_fontinfo, font_scale: f32, text: []const u8, x0: i32, baseline: i32, x_max: i32, c: core.Color8) !void {
        var pen: f32 = @floatFromInt(x0);
        var prev: ?u21 = null;
        var glyph: std.ArrayList(u8) = .empty;
        defer glyph.deinit(alloc);
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            if (prev) |p| pen += font_scale * @as(f32, @floatFromInt(stb_tt.c.stbtt_GetCodepointKernAdvance(font, p, cp)));
            prev = cp;
            var advance: i32 = 0;
            var lsb: i32 = 0;
            stb_tt.c.stbtt_GetCodepointHMetrics(font, cp, &advance, &lsb);
            const next = pen + font_scale * @as(f32, @floatFromInt(advance));
            if (@as(i32, @intFromFloat(@ceil(next))) > x_max) break;

            var bx0: i32 = 0;
            var by0: i32 = 0;
            var bx1: i32 = 0;
            var by1: i32 = 0;
            stb_tt.c.stbtt_GetCodepointBitmapBox(font, cp, font_scale, font_scale, &bx0, &by0, &bx1, &by1);
            const gw = bx1 - bx0;
            const gh = by1 - by0;
            if (gw > 0 and gh > 0) {
                try glyph.resize(alloc, @intCast(gw * gh));
                stb_tt.c.stbtt_MakeCodepointBitmap(font, glyph.items.ptr, gw, gh, gw, font_scale, font_scale, cp);
                const gx = @as(i32, @intFromFloat(@round(pen))) + bx0;
                const gy = baseline + by0;
                var y: i32 = 0;
                while (y < gh) : (y += 1) {
                    var x: i32 = 0;
                    while (x < gw) : (x += 1) {
                        const cov: u32 = glyph.items[@intCast(y * gw + x)];
                        if (cov == 0) continue;
                        const a: u32 = (cov * c.a + 127) / 255;
                        self.blend(gx + x, gy + y, premul(c.r, c.g, c.b, @intCast(a)));
                    }
                }
            }
            pen = next;
        }
    }

    /// Hands the pixels over in ARGB8888 order (B, G, R, A in memory).
    fn toArgb(self: *Canvas) []u8 {
        var i: usize = 0;
        while (i < self.px.len) : (i += 4) std.mem.swap(u8, &self.px[i], &self.px[i + 2]);
        return self.px;
    }
};

fn premul(r: u8, g: u8, b: u8, a: u8) [4]u8 {
    const m = struct {
        fn of(v: u8, alpha: u8) u8 {
            return @intCast((@as(u32, v) * alpha + 127) / 255);
        }
    }.of;
    return .{ m(r, a), m(g, a), m(b, a), a };
}

/// The average of the source pixels destination pixel (`dx`, `dy`) covers
/// when the image is drawn `dw` x `dh`, premultiplied.
fn sampleBox(img: *const stbi.Image, dx: i32, dy: i32, dw: i32, dh: i32) [4]u8 {
    const sw: i32 = @intCast(img.width);
    const sh: i32 = @intCast(img.height);
    const x0 = @divTrunc(dx * sw, dw);
    const y0 = @divTrunc(dy * sh, dh);
    const x1 = @max(x0 + 1, @divTrunc((dx + 1) * sw, dw));
    const y1 = @max(y0 + 1, @divTrunc((dy + 1) * sh, dh));
    var sum = [4]u32{ 0, 0, 0, 0 };
    var n: u32 = 0;
    var y = y0;
    while (y < @min(y1, sh)) : (y += 1) {
        var x = x0;
        while (x < @min(x1, sw)) : (x += 1) {
            const i: usize = @intCast((y * sw + x) * 4);
            const p = premul(img.data[i], img.data[i + 1], img.data[i + 2], img.data[i + 3]);
            for (0..4) |k| sum[k] += p[k];
            n += 1;
        }
    }
    if (n == 0) return .{ 0, 0, 0, 0 };
    return .{ @intCast(sum[0] / n), @intCast(sum[1] / n), @intCast(sum[2] / n), @intCast(sum[3] / n) };
}
