// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The colour emoji atlas: a colour bitmap font's glyphs (`color_font.zig`)
//! decoded, scaled to the text size, and packed into an RGBA texture.
//!
//! A companion to `FontAtlas`, owned by it (`FontAtlas.color`), rather
//! than more faces in it: the text atlas is one channel of coverage that
//! the shader tints with the cell's colour, and an emoji is four channels
//! drawn as they are. Two textures, so two batches -- the host draws these
//! glyphs through its untinted sprite batches, the way it draws icons.
//! Living on `FontAtlas` is what makes a font-size change (`setFontSize`)
//! and the scaled-text clones (`cloneAtSize`) carry the emoji along.
//!
//! Glyphs are packed one at a time on first use, not by 256-codepoint
//! block like the text atlas: each one is a PNG decode and a resize, and
//! a block of emoji is a few hundred of those for the one on screen.

const std = @import("std");
const builtin = @import("builtin");
const stbi = @import("zstbi");
const gl = @import("zopengl").bindings;

const common = @import("../common.zig");
const textures = @import("./textures.zig");
const color_font = @import("./color_font.zig");
const Character = @import("./font_atlas.zig").Character;

const Vec2I = common.Vec2I;
const RectF = common.RectF;
const Texture = textures.Texture;

pub const ColorAtlas = struct {
    /// The font file. Owned when `owns_data`; a `cloneAtSize` borrows its
    /// parent's.
    data: []const u8,
    owns_data: bool,
    face_index: u32,
    font: color_font.ColorFont,
    /// Codepoint -> packed glyph.
    chars: std.AutoHashMap(u32, Character),
    /// Codepoints already tried and not packable (the font lacks them, or
    /// the PNG wouldn't decode), so they aren't retried every frame.
    failed: std.AutoHashMap(u32, void),

    /// CPU copy of the RGBA bitmap, `dim * dim * 4` bytes.
    pixels: []u8,
    dim: i32,
    pack_x: i32 = 0,
    pack_y: i32 = 0,
    shelf_h: i32 = 0,
    /// `pixels` changed since the last upload.
    dirty: bool = false,
    /// The texture grew since the last upload: every `coords` moved, so
    /// quads built against the old size must be rebuilt.
    grew_since_upload: bool = false,
    texture: Texture,

    /// The text atlas's pixel size; glyphs are scaled by
    /// `font_size / strike ppem`, the same em-to-pixel mapping the text
    /// fonts get.
    font_size: f32,
    alloc: std.mem.Allocator,

    const initial_dim: i32 = 256;
    const max_dim: i32 = 4096;
    /// Transparent gutter between glyphs, against LINEAR filter bleed.
    const padding: i32 = 1;

    /// An atlas over face `face_index` of `data`. Takes ownership of
    /// `data` when `owns_data` (freed in `deinit`, and on error here).
    /// `error.NotAColorFont` when it isn't a CBDT/CBLC font.
    pub fn init(data: []const u8, owns_data: bool, face_index: u32, font_size: f32, alloc: std.mem.Allocator) !ColorAtlas {
        errdefer if (owns_data) alloc.free(data);
        const font = try color_font.ColorFont.init(data, face_index);

        const pixels = try alloc.alloc(u8, @intCast(initial_dim * initial_dim * 4));
        errdefer alloc.free(pixels);
        @memset(pixels, 0);

        var tex: c_uint = undefined;
        gl.genTextures(1, &tex);
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

        var self: ColorAtlas = .{
            .data = data,
            .owns_data = owns_data,
            .face_index = face_index,
            .font = font,
            .chars = .init(alloc),
            .failed = .init(alloc),
            .pixels = pixels,
            .dim = initial_dim,
            .texture = .{
                .texture = tex,
                .size = .{ .x = @intCast(initial_dim), .y = @intCast(initial_dim) },
                .src = .{ .l = 0, .t = 0, .r = 1, .b = 1 },
            },
            .font_size = font_size,
            .alloc = alloc,
        };
        self.upload();
        return self;
    }

    /// A second atlas over the same font data (borrowed: `self` must
    /// outlive it) at another pixel size -- `FontAtlas.cloneAtSize`'s
    /// half for the emoji.
    pub fn cloneAtSize(self: *const ColorAtlas, font_size: f32, alloc: std.mem.Allocator) !ColorAtlas {
        return init(self.data, false, self.face_index, font_size, alloc);
    }

    pub fn deinit(self: *ColorAtlas) void {
        gl.deleteTextures(1, &self.texture.texture);
        self.chars.deinit();
        self.failed.deinit();
        self.alloc.free(self.pixels);
        if (self.owns_data) self.alloc.free(self.data);
    }

    /// Whether the font has a glyph for `cp` -- without packing it.
    pub fn has(self: *const ColorAtlas, cp: u32) bool {
        return self.font.glyphIndex(cp) != 0;
    }

    /// The packed glyph for `cp`, packing it first if need be (CPU only;
    /// `commitTexture` uploads). Null when the font can't provide it.
    pub fn getChar(self: *ColorAtlas, cp: u32) ?Character {
        if (self.chars.get(cp)) |c| return c;
        if (self.failed.contains(cp)) return null;
        self.load(cp) catch {};
        if (self.chars.get(cp)) |c| return c;
        self.failed.put(cp, {}) catch {};
        return null;
    }

    /// Repacks at a new pixel size: every glyph is dropped and repacked
    /// on its next use. The texture object is kept.
    pub fn setFontSize(self: *ColorAtlas, font_size: f32) void {
        self.font_size = font_size;
        self.chars.clearRetainingCapacity();
        self.failed.clearRetainingCapacity();
        @memset(self.pixels, 0);
        self.pack_x = 0;
        self.pack_y = 0;
        self.shelf_h = 0;
        self.dirty = true;
        self.grew_since_upload = true;
    }

    /// Uploads the bitmap if it changed, and clears the change flags.
    pub fn commitTexture(self: *ColorAtlas) void {
        if (!self.dirty) return;
        self.upload();
        self.dirty = false;
        self.grew_since_upload = false;
    }

    fn load(self: *ColorAtlas, cp: u32) !void {
        const glyph = self.font.glyphFor(cp, self.font_size) orelse return;
        var image = try stbi.Image.loadFromMemory(glyph.png, 4);
        defer image.deinit();
        if (image.width == 0 or image.height == 0) return;

        const s = self.font_size / @as(f32, @floatFromInt(glyph.ppem));
        const w: i32 = @max(1, scaled(@intCast(image.width), s));
        const h: i32 = @max(1, scaled(@intCast(image.height), s));

        const scratch = try self.alloc.alloc(u8, @intCast(w * h * 4));
        defer self.alloc.free(scratch);
        color_font.downscaleRgba(image.data, image.width, image.height, scratch, @intCast(w), @intCast(h));

        const pos = self.pack(w, h) orelse return;
        const row_bytes: usize = @intCast(w * 4);
        var y: i32 = 0;
        while (y < h) : (y += 1) {
            const dst: usize = @intCast(((pos.y + y) * self.dim + pos.x) * 4);
            const src: usize = @as(usize, @intCast(y)) * row_bytes;
            @memcpy(self.pixels[dst .. dst + row_bytes], scratch[src .. src + row_bytes]);
        }
        self.dirty = true;

        const m = glyph.metrics;
        try self.chars.put(cp, .{
            .coords = RectF.fromCoords(pos.x, pos.y, w, h, self.dim, self.dim),
            .size = .{ .x = w, .y = h },
            .bearing = .{ .x = scaled(m.bearing_x, s), .y = scaled(m.bearing_y, s) },
            .advance = scaled(m.advance, s),
            .atlas_pos = pos,
        });
    }

    fn scaled(v: i32, s: f32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * s));
    }

    /// Shelf packing, as `FontAtlas.packRect`: the current shelf, a new
    /// one, or a doubled texture. Null at `max_dim`.
    fn pack(self: *ColorAtlas, w: i32, h: i32) ?Vec2I {
        const pw = w + padding;
        const ph = h + padding;
        while (true) {
            if (self.pack_x + pw <= self.dim and self.pack_y + ph <= self.dim) {
                const slot: Vec2I = .{ .x = self.pack_x, .y = self.pack_y };
                self.pack_x += pw;
                self.shelf_h = @max(self.shelf_h, ph);
                return slot;
            }
            if (self.pack_x != 0 and pw <= self.dim and self.pack_y + self.shelf_h + ph <= self.dim) {
                self.pack_y += self.shelf_h;
                self.pack_x = 0;
                self.shelf_h = 0;
                continue;
            }
            if (!self.grow()) return null;
        }
    }

    /// Doubles the texture edge, keeping every glyph at its pixel
    /// position and re-normalizing its UVs.
    fn grow(self: *ColorAtlas) bool {
        if (self.dim >= max_dim) return false;
        const new_dim = self.dim * 2;
        const fresh = self.alloc.alloc(u8, @intCast(new_dim * new_dim * 4)) catch return false;
        @memset(fresh, 0);
        const old_row: usize = @intCast(self.dim * 4);
        var y: usize = 0;
        while (y < self.dim) : (y += 1) {
            const dst = y * @as(usize, @intCast(new_dim * 4));
            @memcpy(fresh[dst .. dst + old_row], self.pixels[y * old_row .. (y + 1) * old_row]);
        }
        self.alloc.free(self.pixels);
        self.pixels = fresh;
        self.dim = new_dim;
        var it = self.chars.valueIterator();
        while (it.next()) |c| {
            c.coords = RectF.fromCoords(c.atlas_pos.x, c.atlas_pos.y, c.size.x, c.size.y, new_dim, new_dim);
        }
        self.dirty = true;
        self.grew_since_upload = true;
        return true;
    }

    fn upload(self: *ColorAtlas) void {
        gl.bindTexture(gl.TEXTURE_2D, self.texture.texture);
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, self.dim, self.dim, 0, gl.RGBA, gl.UNSIGNED_BYTE, @ptrCast(self.pixels.ptr));
        self.texture.size = .{ .x = @intCast(self.dim), .y = @intCast(self.dim) };
    }
};
