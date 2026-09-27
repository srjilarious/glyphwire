// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The pixels behind a layer's drop shadow (`core.Shadow`). The host draws
//! a shadow the way it draws a nine-patch: one small texture of a blurred
//! rounded rect, whose corners stay at their native size while the edges
//! and middle stretch over the layer (`glyphwire.ninePatchQuads`). So the
//! texture only depends on `blur`, `radius` and `color` -- never on the
//! layer's size -- and one texture serves every layer with the same look.
//!
//! Pure (no GL), so it lives in `host_support` and is tested headlessly.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// The texture's geometry for a shadow: each corner is `corner` pixels
/// square, the stretchable middle strip `middle` pixels, and `side` is the
/// full width/height including the 1px transparent ring `ninePatchQuads`
/// expects around the art (where a `.9.png` keeps its guides).
pub const Geometry = struct {
    corner: u32,
    middle: u32,
    side: u32,

    /// The art's size inside the ring.
    pub fn art(self: Geometry) u32 {
        return 2 * self.corner + self.middle;
    }

    /// The nine-patch description `ninePatchQuads` splits the texture by.
    pub fn style(self: Geometry) glyphwire.NinePatchStyle {
        return .{
            .image = 0,
            .width = self.art(),
            .height = self.art(),
            .insets = .{ .left = self.corner, .top = self.corner, .right = self.corner, .bottom = self.corner },
        };
    }
};

/// A corner has to hold the blur outside the rect, the rounding, and the
/// blur's falloff inside it. The middle is wide enough that a blur
/// reaching sideways from any pixel of it never touches a rounded corner,
/// so every texel of the strip is identical along the axis it stretches
/// on and stretching it can't smear the corners' shape into the edges.
pub fn geometry(sh: glyphwire.Shadow) Geometry {
    const corner = sh.radius + 2 * sh.blur;
    const middle = 2 * sh.blur + 3;
    return .{ .corner = corner, .middle = middle, .side = 2 * corner + middle + 2 };
}

/// How far the shadow's drawn rect reaches past the layer's own rect on
/// the left/top, before `x`/`y`: the art starts `blur` pixels outside the
/// shape, plus `spread`. The right/bottom reach is the same.
pub fn outset(sh: glyphwire.Shadow) i32 {
    return @as(i32, @intCast(sh.blur)) + sh.spread;
}

/// Builds the RGBA8 texture (`geometry(sh).side` squared) for `sh`: the
/// rounded rect -- inset `blur` pixels from the art's edge -- rasterized
/// with an antialiased edge, blurred with a Gaussian of sigma `blur / 2`,
/// and written as `color` with the coverage scaling its alpha. The ring
/// around it stays fully transparent. Caller frees.
pub fn build(alloc: std.mem.Allocator, sh: glyphwire.Shadow) ![]u8 {
    const g = geometry(sh);
    const art = g.art();
    const n: usize = @as(usize, art) * art;

    const cov = try alloc.alloc(f32, n);
    defer alloc.free(cov);

    // Signed distance to the rounded rect, per pixel centre; coverage is
    // that distance clamped over one pixel, which antialiases the edge
    // even with no blur.
    const blur_f: f32 = @floatFromInt(sh.blur);
    const radius_f: f32 = @floatFromInt(sh.radius);
    const art_f: f32 = @floatFromInt(art);
    const centre = art_f / 2;
    const half = art_f / 2 - blur_f;
    for (0..art) |y| {
        for (0..art) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const qx = @abs(px - centre) - (half - radius_f);
            const qy = @abs(py - centre) - (half - radius_f);
            const outside = std.math.hypot(@max(qx, 0), @max(qy, 0));
            const d = outside + @min(@max(qx, qy), 0) - radius_f;
            cov[y * art + x] = std.math.clamp(0.5 - d, 0, 1);
        }
    }

    if (sh.blur > 0) try gaussianBlur(alloc, cov, art, blur_f / 2, sh.blur);

    const side: usize = g.side;
    const out = try alloc.alloc(u8, side * side * 4);
    @memset(out, 0);
    const alpha_f: f32 = @floatFromInt(sh.color.a);
    for (0..art) |y| {
        for (0..art) |x| {
            const o = ((y + 1) * side + (x + 1)) * 4;
            out[o + 0] = sh.color.r;
            out[o + 1] = sh.color.g;
            out[o + 2] = sh.color.b;
            out[o + 3] = @intFromFloat(@round(alpha_f * cov[y * art + x]));
        }
    }
    return out;
}

/// Separable Gaussian blur of the `side x side` buffer in place, with the
/// kernel cut off at `reach` pixels and zero beyond the buffer's edge.
fn gaussianBlur(alloc: std.mem.Allocator, buf: []f32, side: u32, sigma: f32, reach: u32) !void {
    const kernel = try alloc.alloc(f32, 2 * reach + 1);
    defer alloc.free(kernel);
    var total: f32 = 0;
    for (kernel, 0..) |*k, i| {
        const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(reach));
        k.* = @exp(-(d * d) / (2 * sigma * sigma));
        total += k.*;
    }
    for (kernel) |*k| k.* /= total;

    const tmp = try alloc.alloc(f32, buf.len);
    defer alloc.free(tmp);
    const n: isize = side;
    const r: isize = reach;

    // Horizontal into `tmp`, then vertical back into `buf`.
    for (0..side) |y| {
        for (0..side) |x| {
            var acc: f32 = 0;
            var i: isize = -r;
            while (i <= r) : (i += 1) {
                const sx = @as(isize, @intCast(x)) + i;
                if (sx < 0 or sx >= n) continue;
                acc += buf[y * side + @as(usize, @intCast(sx))] * kernel[@intCast(i + r)];
            }
            tmp[y * side + x] = acc;
        }
    }
    for (0..side) |y| {
        for (0..side) |x| {
            var acc: f32 = 0;
            var i: isize = -r;
            while (i <= r) : (i += 1) {
                const sy = @as(isize, @intCast(y)) + i;
                if (sy < 0 or sy >= n) continue;
                acc += tmp[@as(usize, @intCast(sy)) * side + x] * kernel[@intCast(i + r)];
            }
            buf[y * side + x] = acc;
        }
    }
}
