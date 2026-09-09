const std = @import("std");
const builtin = @import("builtin");
const stbi = @import("zstbi");
const gl = @import("zopengl").bindings;
pub const stb_tt = @import("stb_truetype");

const common = @import("../common.zig");
const textures = @import("./textures.zig");

const Vec2I = common.Vec2I;
const Vec2U = common.Vec2U;
const RectF = common.RectF;
const Texture = textures.Texture;

pub const Character = struct {
    /// Normalized UV rect of the glyph inside the atlas texture. Recomputed
    /// whenever the atlas texture grows (see `FontAtlas.grow`).
    coords: RectF,
    /// Glyph bitmap size in pixels.
    size: Vec2I,
    /// Offset from the pen origin to the glyph's top-left: `x` rightwards,
    /// `y` upwards from the baseline.
    bearing: Vec2I,
    /// Horizontal pen advance in pixels.
    advance: i32,
    /// Top-left pixel position of the glyph inside the atlas. Stable across
    /// grows (a grow copies existing rows into a wider buffer without
    /// moving them), so it is the source of truth `coords` is rebuilt from.
    atlas_pos: Vec2I = .{ .x = 0, .y = 0 },
};

/// Font metrics scaled to a target pixel size, without packing any glyphs
/// into a texture -- unlike `initFromTtf*`, this needs no GL context, so it
/// can run before a window/renderer exists (e.g. to size a window from the
/// font it's about to load).
pub const FontMetrics = struct {
    /// Horizontal advance of a representative glyph ('M'). For a monospace
    /// font this is every glyph's advance, i.e. the terminal cell width.
    advance: i32,
    /// ascent - descent + line_gap: the font's recommended line-to-line
    /// spacing, i.e. the terminal cell height.
    line_height: i32,
    /// Ascent alone, for baseline placement.
    ascent: i32,
};

fn measureFontData(fontData: []const u8, faceIndex: i32, fontSize: f32) !FontMetrics {
    const offset = stb_tt.c.stbtt_GetFontOffsetForIndex(fontData.ptr, faceIndex);
    if (offset < 0) return error.InvalidFontIndex;

    var font_info: stb_tt.c.stbtt_fontinfo = undefined;
    if (stb_tt.c.stbtt_InitFont(&font_info, fontData.ptr, offset) == 0) return error.InvalidFont;

    var ascent: i32 = undefined;
    var descent: i32 = undefined;
    var line_gap: i32 = undefined;
    stb_tt.c.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);

    var advance: i32 = undefined;
    var lsb: i32 = undefined;
    stb_tt.c.stbtt_GetCodepointHMetrics(&font_info, 'M', &advance, &lsb);

    const scale = stb_tt.c.stbtt_ScaleForPixelHeight(&font_info, fontSize);
    const scaled = struct {
        fn of(value: i32, s: f32) i32 {
            return @intFromFloat(@round(s * @as(f32, @floatFromInt(value))));
        }
    }.of;

    return .{
        .advance = scaled(advance, scale),
        .line_height = scaled(ascent - descent + line_gap, scale),
        .ascent = scaled(ascent, scale),
    };
}

/// Reads `fontPath` and returns the `FontMetrics` of collection face
/// `faceIndex` at `fontSize`. Use 0 for a plain font file. No GL context
/// required -- safe to call before window/renderer creation.
pub fn measureFontFileIndexed(fontPath: []const u8, faceIndex: i32, fontSize: f32, alloc: std.mem.Allocator) !FontMetrics {
    const io = std.Io.Threaded.global_single_threaded.io();
    const fontData = try std.Io.Dir.cwd().readFileAlloc(io, fontPath, alloc, .unlimited);
    defer alloc.free(fontData);

    return measureFontData(fontData, faceIndex, fontSize);
}

/// Reads `fontPath` and returns its `FontMetrics` at `fontSize`. No GL
/// context required -- safe to call before window/renderer creation.
pub fn measureFontFile(fontPath: []const u8, fontSize: f32, alloc: std.mem.Allocator) !FontMetrics {
    return measureFontFileIndexed(fontPath, 0, fontSize, alloc);
}

/// One loaded font file (the primary face or a fallback). Owns its byte
/// buffer and a stb_truetype handle scaled to the atlas pixel size.
pub const FontFace = struct {
    data: []u8,
    owns_data: bool,
    info: stb_tt.c.stbtt_fontinfo,
    /// stb pixel-height scale for the atlas's `font_size`.
    scale: f32,

    /// `data` must outlive the face unless `owns_data` is true (then the
    /// face frees it in `deinit`). `face_index` selects a face inside a
    /// TrueType/OpenType collection (`.ttc`); use 0 for a plain font file.
    pub fn init(data: []u8, owns_data: bool, face_index: i32, font_size: f32) !FontFace {
        const offset = stb_tt.c.stbtt_GetFontOffsetForIndex(data.ptr, face_index);
        if (offset < 0) return error.InvalidFontIndex;

        var info: stb_tt.c.stbtt_fontinfo = undefined;
        if (stb_tt.c.stbtt_InitFont(&info, data.ptr, offset) == 0) return error.InvalidFont;

        return .{
            .data = data,
            .owns_data = owns_data,
            .info = info,
            .scale = stb_tt.c.stbtt_ScaleForPixelHeight(&info, font_size),
        };
    }

    pub fn deinit(self: *FontFace, alloc: std.mem.Allocator) void {
        if (self.owns_data) alloc.free(self.data);
    }

    /// stb glyph index for `cp`, or 0 when this face has no glyph for it.
    pub fn glyphIndex(self: *FontFace, cp: u32) i32 {
        return stb_tt.c.stbtt_FindGlyphIndex(&self.info, @intCast(cp));
    }
};

/// Scans a font/collection file's faces and returns the index of the first
/// whose name (any name-table entry) contains `needle` (case-sensitive), or
/// null. Lets a caller pick e.g. "Mono CJK JP" out of a Noto `.ttc`.
pub fn findFaceIndexByName(data: []const u8, needle: []const u8) ?i32 {
    const count = stb_tt.c.stbtt_GetNumberOfFonts(data.ptr);
    if (count <= 0) return null;

    var idx: i32 = 0;
    while (idx < count) : (idx += 1) {
        const offset = stb_tt.c.stbtt_GetFontOffsetForIndex(data.ptr, idx);
        if (offset < 0) continue;
        var info: stb_tt.c.stbtt_fontinfo = undefined;
        if (stb_tt.c.stbtt_InitFont(&info, data.ptr, offset) == 0) continue;

        // name IDs 1 (family) and 4 (full name) on the common platform/encoding tuples
        for ([_]c_int{ 1, 4, 6 }) |name_id| {
            var len: c_int = 0;
            const ptr = stb_tt.c.stbtt_GetFontNameString(
                &info,
                &len,
                stb_tt.c.STBTT_PLATFORM_ID_MICROSOFT,
                stb_tt.c.STBTT_MS_EID_UNICODE_BMP,
                stb_tt.c.STBTT_MS_LANG_ENGLISH,
                name_id,
            );
            if (ptr == null or len <= 0) continue;
            // Microsoft platform strings are UTF-16BE: compare ASCII-folded.
            if (utf16BeContainsAscii(ptr[0..@intCast(len)], needle)) return idx;
        }
    }
    return null;
}

fn utf16BeContainsAscii(utf16be: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    // Collapse the UTF-16BE name to its low bytes (fine for ASCII names).
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var i: usize = 1;
    while (i < utf16be.len and n < buf.len) : (i += 2) {
        buf[n] = utf16be[i];
        n += 1;
    }
    return std.mem.indexOf(u8, buf[0..n], needle) != null;
}

pub const FontAtlas = struct {
    /// Codepoint -> packed glyph. A codepoint no face provides is simply
    /// absent; `getChar` returns `notdef` for it.
    chars: std.AutoHashMap(u32, Character),
    /// 256-codepoint blocks already rasterized (key = codepoint >> 8). A
    /// block is packed in full the first time any codepoint in it is used.
    loaded_blocks: std.AutoHashMap(u32, void),
    /// Ordered faces: index 0 is the primary, the rest are fallbacks tried
    /// in order for codepoints the primary lacks. Empty for a bitmap font.
    faces: std.ArrayListUnmanaged(FontFace),
    /// The "tofu" box drawn for any codepoint no face provides. Always
    /// present for a TTF atlas (part of the base glyph set).
    notdef: Character,

    /// CPU-side copy of the single-channel atlas bitmap. Kept so the whole
    /// texture can be re-uploaded after new glyphs are packed, and so a
    /// grow can copy existing rows into the wider buffer without
    /// re-rasterizing. Empty for a bitmap font.
    pixels: []u8,
    /// Current square edge length of `pixels` / the GL texture, in pixels.
    dim: i32,
    /// Shelf packer cursor: next free x on the current shelf, that shelf's
    /// top y, and the tallest cell placed on the current shelf so far.
    pack_x: i32,
    pack_y: i32,
    shelf_h: i32,
    /// `pixels` has changed since the last GL upload.
    dirty: bool,
    /// The atlas texture grew since the last upload -- every glyph's
    /// `coords` was re-normalized, so a caller with quads already queued
    /// against the old texture must flush them before `commitTexture`.
    grew_since_upload: bool,

    texture: Texture,
    /// Running max glyph height over everything packed so far. Used by the
    /// imgui/console layers as a line-height estimate; it grows as taller
    /// blocks load, so do NOT use it for baseline placement -- see `ascent`.
    maxY: i32,
    /// Distance in pixels from a line's top (the `pos.y` the text renderer
    /// is handed) down to the baseline: the primary face's scaled vmetrics
    /// ascent. A fixed font metric, not a running max over packed glyphs,
    /// so loading a tall on-demand block (CJK, Nerd Font) never shifts
    /// where already-drawn ASCII text sits. Equals `maxY` for a bitmap
    /// font atlas, which has no scalable face to measure.
    ascent: i32,
    isAlpha: bool,

    font_size: f32,
    alloc: std.mem.Allocator,

    const initial_dim: i32 = 1024;
    const max_dim: i32 = 8192;
    /// Transparent gutter kept between packed glyphs so the LINEAR filter
    /// can't bleed a neighbouring glyph in at a cell edge.
    const glyph_padding: i32 = 1;

    pub fn getChar(self: *FontAtlas, char: u32) ?Character {
        if (self.chars.get(char)) |c| return c;
        if (self.faces.items.len == 0) return self.notdefOrNull();
        self.ensureBlock(char >> 8) catch {};
        return self.chars.get(char) orelse self.notdefOrNull();
    }

    fn notdefOrNull(self: *FontAtlas) ?Character {
        // A TTF atlas always has a real notdef; a bitmap font may not.
        return if (self.notdef.advance != 0 or self.notdef.size.x != 0) self.notdef else null;
    }

    // -----------------------------------------------------------------------
    // On-demand block loading
    // -----------------------------------------------------------------------

    /// Ensures every 256-codepoint block touched by `text` is packed into
    /// the CPU atlas. Pure CPU work: no GL calls, no texture upload. Call
    /// `commitTexture` afterwards (or use `ensureBlocksForText`).
    pub fn loadBlocksForText(self: *FontAtlas, text: []const u8) void {
        if (self.faces.items.len == 0) return;

        var i: usize = 0;
        while (i < text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1;
                continue;
            };
            if (i + seq_len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
                i += seq_len;
                continue;
            };
            i += seq_len;
            self.ensureBlock(cp >> 8) catch {};
        }
    }

    /// Uploads `pixels` to the GL texture if it changed since the last
    /// upload, then clears the dirty/grew flags.
    pub fn commitTexture(self: *FontAtlas) void {
        if (!self.dirty) return;
        self.uploadTexture();
        self.dirty = false;
        self.grew_since_upload = false;
    }

    /// Loads every block `text` needs and uploads the texture. Returns true
    /// if the atlas texture grew (all `coords` changed). Prefer the
    /// `loadBlocksForText` + `commitTexture` split when quads may already be
    /// queued against the current texture.
    pub fn ensureBlocksForText(self: *FontAtlas, text: []const u8) bool {
        self.loadBlocksForText(text);
        const grew = self.grew_since_upload;
        self.commitTexture();
        return grew;
    }

    fn ensureBlock(self: *FontAtlas, block: u32) !void {
        if (self.loaded_blocks.contains(block)) return;

        const base: u32 = block << 8;
        var off: u32 = 0;
        while (off < 256) : (off += 1) {
            const cp = base + off;
            if (self.chars.contains(cp)) continue;
            try self.loadGlyph(cp);
        }
        try self.loaded_blocks.put(block, {});
    }

    fn loadGlyph(self: *FontAtlas, cp: u32) !void {
        var face: ?*FontFace = null;
        for (self.faces.items) |*f| {
            if (f.glyphIndex(cp) != 0) {
                face = f;
                break;
            }
        }
        const f = face orelse return; // no face has it -> stays absent -> notdef

        var advance: c_int = 0;
        var lsb: c_int = 0;
        stb_tt.c.stbtt_GetCodepointHMetrics(&f.info, @intCast(cp), &advance, &lsb);
        const adv_px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(advance)) * f.scale));

        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stb_tt.c.stbtt_GetCodepointBitmapBox(&f.info, @intCast(cp), f.scale, f.scale, &x0, &y0, &x1, &y1);
        const gw: i32 = @intCast(x1 - x0);
        const gh: i32 = @intCast(y1 - y0);

        if (gw <= 0 or gh <= 0) {
            // Whitespace / zero-area glyph: record the advance, no bitmap.
            try self.chars.put(cp, .{
                .coords = .{ .l = 0, .t = 0, .r = 0, .b = 0 },
                .size = .{ .x = 0, .y = 0 },
                .bearing = .{ .x = 0, .y = 0 },
                .advance = adv_px,
            });
            return;
        }

        const pos = self.packRect(gw, gh) orelse return; // atlas maxed out -> notdef
        self.rasterCodepoint(f, cp, pos, gw, gh);

        try self.chars.put(cp, .{
            .coords = RectF.fromCoords(pos.x, pos.y, gw, gh, self.dim, self.dim),
            .size = .{ .x = gw, .y = gh },
            .bearing = .{ .x = @intCast(x0), .y = @intCast(-y0) },
            .advance = adv_px,
            .atlas_pos = pos,
        });
        self.maxY = @max(self.maxY, @as(i32, @intCast(-y0)));
    }

    fn rasterCodepoint(self: *FontAtlas, f: *FontFace, cp: u32, pos: Vec2I, gw: i32, gh: i32) void {
        const dst_off: usize = @intCast(pos.y * self.dim + pos.x);
        stb_tt.c.stbtt_MakeCodepointBitmap(
            &f.info,
            self.pixels.ptr + dst_off,
            gw,
            gh,
            self.dim, // destination row stride
            f.scale,
            f.scale,
            @intCast(cp),
        );
        self.dirty = true;
    }

    // -----------------------------------------------------------------------
    // Shelf packer
    // -----------------------------------------------------------------------

    /// Reserves a `w`x`h` slot (plus a `glyph_padding` gutter) on the
    /// current shelf, wrapping to a new shelf or growing the atlas as
    /// needed. Returns the top-left pixel of the slot, or null if the atlas
    /// is already at `max_dim` and still can't fit it.
    fn packRect(self: *FontAtlas, w: i32, h: i32) ?Vec2I {
        const pw = w + glyph_padding;
        const ph = h + glyph_padding;

        while (true) {
            if (self.pack_x + pw <= self.dim and self.pack_y + ph <= self.dim) {
                const slot = Vec2I{ .x = self.pack_x, .y = self.pack_y };
                self.pack_x += pw;
                if (ph > self.shelf_h) self.shelf_h = ph;
                return slot;
            }

            // Wrap to a fresh shelf if we're not already at one.
            if (self.pack_x != 0 and pw <= self.dim and self.pack_y + self.shelf_h + ph <= self.dim) {
                self.pack_y += self.shelf_h;
                self.pack_x = 0;
                self.shelf_h = 0;
                continue;
            }

            if (!self.grow()) return null;
        }
    }

    /// Doubles the atlas edge, copies the existing bitmap into the wider
    /// buffer at the same pixel offsets, and re-normalizes every glyph's
    /// UVs. Existing `atlas_pos` values stay valid. Returns false at
    /// `max_dim`. Normally driven automatically by `packRect`; exposed for
    /// callers that want to pre-size the atlas (and for tests).
    pub fn grow(self: *FontAtlas) bool {
        if (self.dim >= max_dim) return false;

        const new_dim = self.dim * 2;
        const new_pixels = self.alloc.alloc(u8, @intCast(new_dim * new_dim)) catch return false;
        @memset(new_pixels, 0);

        var y: i32 = 0;
        while (y < self.dim) : (y += 1) {
            const src_start: usize = @intCast(y * self.dim);
            const dst_start: usize = @intCast(y * new_dim);
            const row_len: usize = @intCast(self.dim);
            @memcpy(new_pixels[dst_start .. dst_start + row_len], self.pixels[src_start .. src_start + row_len]);
        }

        self.alloc.free(self.pixels);
        self.pixels = new_pixels;
        self.dim = new_dim;

        var it = self.chars.valueIterator();
        while (it.next()) |ch| {
            ch.coords = RectF.fromCoords(ch.atlas_pos.x, ch.atlas_pos.y, ch.size.x, ch.size.y, new_dim, new_dim);
        }
        self.notdef.coords = RectF.fromCoords(
            self.notdef.atlas_pos.x,
            self.notdef.atlas_pos.y,
            self.notdef.size.x,
            self.notdef.size.y,
            new_dim,
            new_dim,
        );

        self.dirty = true;
        self.grew_since_upload = true;
        return true;
    }

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    fn initFromOwnedData(data: []u8, face_index: i32, fontSize: f32, alloc: std.mem.Allocator) !FontAtlas {
        var faces: std.ArrayListUnmanaged(FontFace) = .empty;
        errdefer faces.deinit(alloc);

        const first = try FontFace.init(data, true, face_index, fontSize);
        try faces.append(alloc, first);

        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        stb_tt.c.stbtt_GetFontVMetrics(&faces.items[0].info, &ascent, &descent, &line_gap);
        const scaled_ascent: i32 = @intFromFloat(@round(faces.items[0].scale * @as(f32, @floatFromInt(ascent))));

        const pixels = try alloc.alloc(u8, @intCast(initial_dim * initial_dim));
        errdefer alloc.free(pixels);
        @memset(pixels, 0);

        var char_tex: c_uint = undefined;
        gl.genTextures(1, &char_tex);
        errdefer gl.deleteTextures(1, &char_tex);
        gl.bindTexture(gl.TEXTURE_2D, char_tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

        var self = FontAtlas{
            .chars = std.AutoHashMap(u32, Character).init(alloc),
            .loaded_blocks = std.AutoHashMap(u32, void).init(alloc),
            .faces = faces,
            .notdef = .{
                .coords = .{ .l = 0, .t = 0, .r = 0, .b = 0 },
                .size = .{ .x = 0, .y = 0 },
                .bearing = .{ .x = 0, .y = 0 },
                .advance = 0,
            },
            .pixels = pixels,
            .dim = initial_dim,
            .pack_x = 0,
            .pack_y = 0,
            .shelf_h = 0,
            .dirty = false,
            .grew_since_upload = false,
            .texture = .{
                .texture = char_tex,
                .size = .{ .x = @intCast(initial_dim), .y = @intCast(initial_dim) },
                .src = .{ .l = 0, .t = 0, .r = 1, .b = 1 },
            },
            .maxY = 0,
            .ascent = scaled_ascent,
            .isAlpha = true,
            .font_size = fontSize,
            .alloc = alloc,
        };
        errdefer {
            self.chars.deinit();
            self.loaded_blocks.deinit();
        }

        self.buildNotdef();
        try self.ensureBlock(0); // ASCII + Latin-1 supplement, the common path

        if (self.maxY == 0) self.maxY = scaled_ascent;

        self.uploadTexture();
        self.dirty = false;
        self.grew_since_upload = false;
        return self;
    }

    fn initFromTtf(fontData: []const u8, fontSize: f32, alloc: std.mem.Allocator) !FontAtlas {
        const owned = try alloc.dupe(u8, fontData);
        errdefer alloc.free(owned);
        return initFromOwnedData(owned, 0, fontSize, alloc);
    }

    /// Loads a TTF/OTF (or a `.ttc` collection face) from disk. `face_index`
    /// is 0 for a plain font file.
    pub fn initFromTtfFileIndexed(fontPath: []const u8, faceIndex: i32, fontSize: f32, alloc: std.mem.Allocator) !FontAtlas {
        const io = std.Io.Threaded.global_single_threaded.io();
        const owned = try std.Io.Dir.cwd().readFileAlloc(io, fontPath, alloc, .unlimited);
        errdefer alloc.free(owned);
        return initFromOwnedData(owned, faceIndex, fontSize, alloc);
    }

    /// Loads a TTF font from a file path (for non-WASM).
    pub fn initFromTtfFile(fontPath: []const u8, fontSize: f32, alloc: std.mem.Allocator) !FontAtlas {
        return initFromTtfFileIndexed(fontPath, 0, fontSize, alloc);
    }

    /// Loads a TTF font embedded at comptime into the binary (WASM-friendly).
    pub fn initFromTtfEmbedded(comptime fontPath: []const u8, fontSize: f32, alloc: std.mem.Allocator) !FontAtlas {
        const fontData = @embedFile(fontPath);
        return initFromTtf(fontData, fontSize, alloc);
    }

    /// Appends a fallback face from raw font bytes. Codepoints the primary
    /// (and any earlier fallback) lacks are then filled from this face on
    /// their next use. Already-packed glyphs are kept; only previously
    /// missing codepoints get re-tried.
    pub fn addFallbackFaceFromData(self: *FontAtlas, fontData: []const u8, faceIndex: i32) !void {
        const owned = try self.alloc.dupe(u8, fontData);
        errdefer self.alloc.free(owned);
        const face = try FontFace.init(owned, true, faceIndex, self.font_size);
        try self.faces.append(self.alloc, face);
        // Drop the block memo so blocks re-scan; `ensureBlock` skips
        // codepoints already in `chars`, so only the gaps get filled.
        self.loaded_blocks.clearRetainingCapacity();
    }

    /// Appends a fallback face read from a font/collection file. `faceIndex`
    /// selects a face inside a `.ttc`; use 0 for a plain font file.
    pub fn addFallbackFaceFromFile(self: *FontAtlas, fontPath: []const u8, faceIndex: i32, alloc: std.mem.Allocator) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const data = try std.Io.Dir.cwd().readFileAlloc(io, fontPath, alloc, .unlimited);
        defer alloc.free(data);
        try self.addFallbackFaceFromData(data, faceIndex);
    }

    /// Repacks the atlas at a new pixel size, in place. Every face (the
    /// primary and any fallbacks) is rescaled, all packed glyphs are
    /// dropped, the CPU bitmap is reset to the initial square (undoing any
    /// earlier `grow`), and the base glyph set is re-rasterized at the new
    /// size. The GL texture object is kept, so a batch already holding
    /// `&atlas.texture` stays valid -- but call this outside a renderer
    /// `begin`/`end` pair so no quads are queued against the old contents.
    ///
    /// Returns `error.NotAScalableFont` for a bitmap-font atlas (it has no
    /// TrueType faces to rescale). On an allocation failure partway through
    /// the repack, `font_size` is already updated and the base set may be
    /// only partly packed; `getChar` finishes it lazily on next use.
    pub fn setFontSize(self: *FontAtlas, size_px: f32) !void {
        if (self.faces.items.len == 0) return error.NotAScalableFont;

        for (self.faces.items) |*f| {
            f.scale = stb_tt.c.stbtt_ScaleForPixelHeight(&f.info, size_px);
        }
        self.font_size = size_px;

        // Re-measure the baseline for the new pixel size before any glyph
        // is packed -- it comes from the face's vmetrics, not from glyphs.
        {
            var asc: c_int = 0;
            var desc: c_int = 0;
            var lgap: c_int = 0;
            stb_tt.c.stbtt_GetFontVMetrics(&self.faces.items[0].info, &asc, &desc, &lgap);
            self.ascent = @intFromFloat(@round(self.faces.items[0].scale * @as(f32, @floatFromInt(asc))));
        }

        // Drop every packed glyph and rewind the shelf packer.
        self.chars.clearRetainingCapacity();
        self.loaded_blocks.clearRetainingCapacity();

        // Undo any earlier grow so the repack starts from the base square.
        if (self.dim != initial_dim) {
            const fresh = try self.alloc.alloc(u8, @intCast(initial_dim * initial_dim));
            self.alloc.free(self.pixels);
            self.pixels = fresh;
            self.dim = initial_dim;
        }
        @memset(self.pixels, 0);

        self.pack_x = 0;
        self.pack_y = 0;
        self.shelf_h = 0;
        self.maxY = 0;
        self.notdef = .{
            .coords = .{ .l = 0, .t = 0, .r = 0, .b = 0 },
            .size = .{ .x = 0, .y = 0 },
            .bearing = .{ .x = 0, .y = 0 },
            .advance = 0,
        };

        self.buildNotdef();
        try self.ensureBlock(0); // ASCII + Latin-1 supplement, the common path

        if (self.maxY == 0) self.maxY = self.ascent;

        self.uploadTexture();
        self.dirty = false;
        self.grew_since_upload = false;
    }

    /// Rasterizes the primary face's `.notdef` (glyph index 0) into the
    /// atlas as `self.notdef`. Falls back to a synthesized hollow box if
    /// the font's own `.notdef` has no outline.
    fn buildNotdef(self: *FontAtlas) void {
        const f = &self.faces.items[0];

        var advance: c_int = 0;
        var lsb: c_int = 0;
        stb_tt.c.stbtt_GetGlyphHMetrics(&f.info, 0, &advance, &lsb);
        const adv_px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(advance)) * f.scale));

        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stb_tt.c.stbtt_GetGlyphBitmapBox(&f.info, 0, f.scale, f.scale, &x0, &y0, &x1, &y1);
        const gw: i32 = @intCast(x1 - x0);
        const gh: i32 = @intCast(y1 - y0);

        if (gw > 0 and gh > 0) {
            if (self.packRect(gw, gh)) |pos| {
                const dst_off: usize = @intCast(pos.y * self.dim + pos.x);
                stb_tt.c.stbtt_MakeGlyphBitmap(&f.info, self.pixels.ptr + dst_off, gw, gh, self.dim, f.scale, f.scale, 0);
                self.dirty = true;
                self.notdef = .{
                    .coords = RectF.fromCoords(pos.x, pos.y, gw, gh, self.dim, self.dim),
                    .size = .{ .x = gw, .y = gh },
                    .bearing = .{ .x = @intCast(x0), .y = @intCast(-y0) },
                    .advance = if (adv_px > 0) adv_px else gw,
                    .atlas_pos = pos,
                };
                self.maxY = @max(self.maxY, @as(i32, @intCast(-y0)));
                return;
            }
        }

        self.synthesizeNotdef(adv_px);
    }

    /// Draws a hollow rectangle into the atlas for use as `notdef` when the
    /// font has no `.notdef` outline of its own.
    fn synthesizeNotdef(self: *FontAtlas, adv_hint: i32) void {
        const h: i32 = @max(4, @as(i32, @intFromFloat(self.font_size * 0.62)));
        const w: i32 = @max(3, if (adv_hint > 0) adv_hint - 2 else @divTrunc(h * 3, 5));
        const pos = self.packRect(w, h) orelse {
            self.notdef = .{
                .coords = .{ .l = 0, .t = 0, .r = 0, .b = 0 },
                .size = .{ .x = 0, .y = 0 },
                .bearing = .{ .x = 0, .y = 0 },
                .advance = if (adv_hint > 0) adv_hint else w,
            };
            return;
        };

        var yy: i32 = 0;
        while (yy < h) : (yy += 1) {
            var xx: i32 = 0;
            while (xx < w) : (xx += 1) {
                const border = xx == 0 or xx == w - 1 or yy == 0 or yy == h - 1;
                if (!border) continue;
                const idx: usize = @intCast((pos.y + yy) * self.dim + (pos.x + xx));
                self.pixels[idx] = 0xFF;
            }
        }
        self.dirty = true;
        self.notdef = .{
            .coords = RectF.fromCoords(pos.x, pos.y, w, h, self.dim, self.dim),
            .size = .{ .x = w, .y = h },
            .bearing = .{ .x = 1, .y = h },
            .advance = if (adv_hint > 0) adv_hint else w + 2,
            .atlas_pos = pos,
        };
        self.maxY = @max(self.maxY, h);
    }

    fn uploadTexture(self: *FontAtlas) void {
        const format = if (builtin.os.tag == .emscripten) gl.ALPHA else gl.RED;
        gl.bindTexture(gl.TEXTURE_2D, self.texture.texture);
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.texImage2D(
            gl.TEXTURE_2D,
            0,
            format,
            @intCast(self.dim),
            @intCast(self.dim),
            0,
            format,
            gl.UNSIGNED_BYTE,
            @ptrCast(self.pixels.ptr),
        );
        self.texture.size = .{ .x = @intCast(self.dim), .y = @intCast(self.dim) };
        self.texture.src = .{ .l = 0, .t = 0, .r = 1, .b = 1 };
    }

    pub fn initFromBitmap(
        fontImagePath: []const u8,
        charWidth: i32,
        charHeight: i32,
        charsPerRow: i32,
        chars: []const u8,
        alloc: std.mem.Allocator,
    ) !FontAtlas {
        const fipz = try std.mem.concatWithSentinel(alloc, u8, &.{fontImagePath}, 0);
        defer alloc.free(fipz);

        var image = try stbi.Image.loadFromFile(fipz, 0);
        defer image.deinit();
        if (image.width == 0 or image.height == 0) {
            return error.ImageLoadFailed;
        }

        // Generate OpenGL texture
        var charTex: c_uint = undefined;
        gl.genTextures(1, &charTex);
        errdefer gl.deleteTextures(1, &charTex);

        gl.bindTexture(gl.TEXTURE_2D, charTex);

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(image.width), @intCast(image.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, image.data.ptr);

        // Set texture parameters for crisp text rendering
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        var charsMap = std.AutoHashMap(u32, Character).init(alloc);
        errdefer charsMap.deinit();
        var maxY: i32 = 0;

        for (0..chars.len) |i| {
            const char_code = chars[i];
            const chW = @as(u32, @intCast(charWidth));
            const chH = @as(u32, @intCast(charHeight));

            const col = i % @as(u32, @intCast(charsPerRow));
            const row = i / @as(u32, @intCast(charsPerRow));

            const x0 = col * chW;
            const y0 = row * chH;

            // Skip characters that would be out of bounds
            if (x0 + chW > image.width or y0 + chH > image.height) {
                continue;
            }

            const coords = RectF.fromCoords(
                @intCast(x0),
                @intCast(y0),
                @intCast(charWidth),
                @intCast(charHeight),
                @intCast(image.width),
                @intCast(image.height),
            );

            try charsMap.put(char_code, Character{
                .coords = coords,
                .size = .{ .x = @intCast(charWidth), .y = @intCast(charHeight) },
                .bearing = .{ .x = 0, .y = @intCast(charHeight) }, // Assume top-left origin
                .advance = charWidth, // Fixed width
            });
            maxY = @max(maxY, @as(i32, @intCast(charHeight)));
        }

        return .{
            .chars = charsMap,
            .loaded_blocks = std.AutoHashMap(u32, void).init(alloc),
            .faces = .empty,
            // No faces -> no real notdef; advance 0 + size 0 makes
            // `getChar` return null for a missing codepoint, exactly as the
            // bitmap-font path did before it went through `notdefOrNull`.
            .notdef = .{
                .coords = .{ .l = 0, .t = 0, .r = 0, .b = 0 },
                .size = .{ .x = 0, .y = 0 },
                .bearing = .{ .x = 0, .y = 0 },
                .advance = 0,
            },
            .pixels = &[_]u8{},
            .dim = 0,
            .pack_x = 0,
            .pack_y = 0,
            .shelf_h = 0,
            .dirty = false,
            .grew_since_upload = false,
            .texture = Texture{
                .texture = charTex,
                .size = Vec2U{ .x = @as(u32, image.width), .y = @as(u32, image.height) },
                .src = RectF{ .l = 0, .t = 0, .r = 1, .b = 1 },
            },
            .maxY = maxY,
            // No scalable face to measure; the bitmap path top-aligns the
            // tallest cell exactly as before, so the baseline is `maxY`.
            .ascent = maxY,
            .isAlpha = false,
            .font_size = 0,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *FontAtlas) void {
        gl.deleteTextures(1, &self.texture.texture);
        self.chars.deinit();
        self.loaded_blocks.deinit();
        for (self.faces.items) |*f| f.deinit(self.alloc);
        self.faces.deinit(self.alloc);
        if (self.pixels.len > 0) self.alloc.free(self.pixels);
    }
};
