const std = @import("std");
const gl = @import("zopengl").bindings;
const zmath = @import("zmath");

const common = @import("../common.zig");
const resources = @import("../resources.zig");
const shaders = @import("./shaders.zig");
const font_atlas = @import("./font_atlas.zig");
const quad_batch = @import("./quad_batch.zig");
const C = @import("./constants.zig");

const Vec2I = common.Vec2I;
const RectF = common.RectF;
const Color = common.Color;
const Shader = shaders.Shader;
const ResourceManager = resources.ResourceManager;
const SpriteBatchQueue = @import("./sprite_batch.zig").SpriteBatchQueue;

/// Dedicated batch for tinted text: same position/texcoord layout as
/// `SpriteBatchQueue`, plus a per-vertex color stream so each glyph draw can
/// carry its own fg color. Kept separate from `SpriteBatchQueue` (used
/// everywhere else in the engine) so that shared type is untouched.
const ColorBatch = quad_batch.QuadBatch(.{ .posDim = 2, .texDim = 2, .colorDim = 4 });

pub const FontAtlas = font_atlas.FontAtlas;
pub const FontFace = font_atlas.FontFace;
pub const Character = font_atlas.Character;
pub const stb_tt = font_atlas.stb_tt;
pub const FontMetrics = font_atlas.FontMetrics;
pub const measureFontFile = font_atlas.measureFontFile;
pub const measureFontFileIndexed = font_atlas.measureFontFileIndexed;
pub const findFaceIndexByName = font_atlas.findFaceIndexByName;

fn scaleInt(value: i32, scale: f32) i32 {
    return @as(i32, @intFromFloat(@as(f32, @floatFromInt(value)) * scale));
}

/// Iterates the UTF-8 codepoints of a byte slice, yielding U+FFFD for any
/// malformed sequence so a bad byte still advances the pen by one glyph
/// rather than derailing the whole string.
const CodepointIter = struct {
    text: []const u8,
    i: usize = 0,

    fn next(self: *CodepointIter) ?u21 {
        if (self.i >= self.text.len) return null;
        const seq_len = std.unicode.utf8ByteSequenceLength(self.text[self.i]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + seq_len > self.text.len) {
            self.i = self.text.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.text[self.i .. self.i + seq_len]) catch {
            self.i += seq_len;
            return 0xFFFD;
        };
        self.i += seq_len;
        return cp;
    }
};

pub const TextRenderer = struct {
    spriteBatch: SpriteBatchQueue,
    /// Separate batch (own shader, own VAO/VBOs) for `drawStringColored`;
    /// see `ColorBatch`'s doc comment for why it isn't folded into
    /// `spriteBatch`.
    colorBatch: ColorBatch,
    /// Pool refs (not pre-acquired handles) so setFont can swap the active
    /// shader on the underlying batch via swapShader. The batch itself owns
    /// whichever handle is currently in use.
    alphaShader: *resources.ManagedShader,
    texShader: *resources.ManagedShader,
    alloc: std.mem.Allocator,
    /// Active font handle. Released in deinit. The parent back-pointer is
    /// used to reacquire after a hot-reload without re-doing the name lookup.
    font: ?*resources.FontAtlasHandle,

    /// Initializes the text renderer with the default `C.MaxSprites` glyph
    /// capacity per batch. Use `initCapacity` to size it explicitly.
    pub fn init(alloc: std.mem.Allocator, resMgr: *ResourceManager) !TextRenderer {
        return initCapacity(alloc, resMgr, C.MaxSprites);
    }

    /// Like `init`, but each of the two glyph batches (plain and tinted)
    /// holds up to `maxQuads` glyphs before it auto-flushes.
    pub fn initCapacity(alloc: std.mem.Allocator, resMgr: *ResourceManager, maxQuads: usize) !TextRenderer {
        const texShader = try resMgr.getShader(shaders.TextureShader);
        const alphaShader = try resMgr.getShader(shaders.FontShader);
        const colorShader = try resMgr.getShader(shaders.TextColorShader);
        var spriteBatch = try SpriteBatchQueue.initCapacity(alloc, texShader, maxQuads);
        errdefer spriteBatch.deinit();
        var colorBatch = try ColorBatch.init(alloc, colorShader, maxQuads);
        errdefer colorBatch.deinit();

        return TextRenderer{
            .alloc = alloc,
            .spriteBatch = spriteBatch,
            .colorBatch = colorBatch,
            .alphaShader = alphaShader,
            .texShader = texShader,
            .font = null,
        };
    }

    pub fn deinit(self: *TextRenderer) void {
        if (self.font) |h| h.release();
        self.spriteBatch.deinit();
        self.colorBatch.deinit();
    }

    fn refreshAtlas(self: *TextRenderer) void {
        const handle = self.font orelse return;
        if (!handle.dirty) return;
        self.font = handle.reacquire();
    }

    pub fn begin(self: *TextRenderer, mvp: zmath.Mat) void {
        self.spriteBatch.begin(mvp);
        self.colorBatch.begin(mvp);
    }

    pub fn end(self: *TextRenderer) void {
        self.spriteBatch.end();
        self.colorBatch.end();
    }

    /// Flushes queued text while keeping the renderer open for further draws.
    pub fn flush(self: *TextRenderer) void {
        self.spriteBatch.flush();
        self.colorBatch.flush();
    }

    /// Makes sure every glyph `text` needs is packed into the active font
    /// atlas and uploaded before the caller queues quads for it. If packing
    /// grew the atlas texture, every glyph's UVs changed, so any quads
    /// already queued this frame are flushed against the still-current
    /// texture before the grown one is uploaded.
    fn syncAtlasForText(self: *TextRenderer, text: []const u8) void {
        const fa = &self.font.?.val;
        fa.loadBlocksForText(text);
        if (fa.grew_since_upload) {
            self.spriteBatch.flush();
            self.colorBatch.flush();
        }
        fa.commitTexture();
    }

    /// Adopt a new font for rendering. Releases any previously held handle,
    /// acquires ownership of a new handle, and swaps the underlying batch's
    /// shader to the alpha-channel program when the atlas was packed as
    /// alpha, or the regular texture program otherwise.
    pub fn setFont(
        self: *TextRenderer,
        font: *resources.ManagedFont,
    ) !void {
        if (self.font) |h| h.release();
        self.font = font.acquire();

        const shader = if (self.font.?.val.isAlpha) self.alphaShader else self.texShader;
        try self.spriteBatch.swapShader(shader);
    }

    pub fn drawString(self: *TextRenderer, text: []const u8, pos: Vec2I) Vec2I {
        var currX: i32 = pos.x;

        var drawSize: Vec2I = .{ .x = 0, .y = 0 };

        if (self.font == null) {
            std.log.err("TextRenderer: No Font set. Cannot draw text.", .{});
            return drawSize;
        }

        self.syncAtlasForText(text);

        const posY = pos.y + self.font.?.val.ascent;
        var it = CodepointIter{ .text = text };
        while (it.next()) |cp| {
            const charData = self.font.?.val.getChar(cp) orelse continue;

            // Only draw if character has visual representation
            if (charData.size.x > 0 and charData.size.y > 0) {
                self.spriteBatch.draw(&self.font.?.val.texture, RectF.fromPosSize(currX + charData.bearing.x, posY - charData.bearing.y, charData.size.x, charData.size.y), charData.coords, .none);
            }

            currX += @intCast(charData.advance);
            drawSize.x += @intCast(charData.advance);
            drawSize.y = @max(drawSize.y, charData.size.y);
        }

        return drawSize;
    }

    /// Like `drawString`, but tints every glyph by `color` instead of
    /// rendering plain white. Uses a separate shader/batch (see
    /// `ColorBatch`), so it expects an alpha-mask (TTF-packed) font atlas --
    /// a bitmap font's RGBA texture would only have its red channel sampled.
    pub fn drawStringColored(self: *TextRenderer, text: []const u8, pos: Vec2I, color: Color) Vec2I {
        var currX: i32 = pos.x;

        var drawSize: Vec2I = .{ .x = 0, .y = 0 };

        if (self.font == null) {
            std.log.err("TextRenderer: No Font set. Cannot draw text.", .{});
            return drawSize;
        }

        const colors: [4][4]f32 = .{
            .{ color.r, color.g, color.b, color.a },
            .{ color.r, color.g, color.b, color.a },
            .{ color.r, color.g, color.b, color.a },
            .{ color.r, color.g, color.b, color.a },
        };

        self.syncAtlasForText(text);

        const posY = pos.y + self.font.?.val.ascent;
        var it = CodepointIter{ .text = text };
        while (it.next()) |cp| {
            const charData = self.font.?.val.getChar(cp) orelse continue;

            if (charData.size.x > 0 and charData.size.y > 0) {
                const dest = RectF.fromPosSize(currX + charData.bearing.x, posY - charData.bearing.y, charData.size.x, charData.size.y);
                const src = charData.coords;

                const positions: [4][2]f32 = .{
                    .{ dest.l, dest.b },
                    .{ dest.l, dest.t },
                    .{ dest.r, dest.t },
                    .{ dest.r, dest.b },
                };
                const texCoords: [4][2]f32 = .{
                    .{ src.l, src.b },
                    .{ src.l, src.t },
                    .{ src.r, src.t },
                    .{ src.r, src.b },
                };

                self.colorBatch.addQuad(&self.font.?.val.texture, positions, texCoords, colors);
            }

            currX += @intCast(charData.advance);
            drawSize.x += @intCast(charData.advance);
            drawSize.y = @max(drawSize.y, charData.size.y);
        }

        return drawSize;
    }

    pub fn drawScaledString(self: *TextRenderer, text: []const u8, pos: Vec2I, scale: f32) Vec2I {
        var currX: i32 = pos.x;

        var drawSize: Vec2I = .{ .x = 0, .y = 0 };

        if (self.font == null) {
            std.log.err("TextRenderer: No Font set. Cannot draw text.", .{});
            return drawSize;
        }

        self.syncAtlasForText(text);

        const posY = pos.y + scaleInt(self.font.?.val.ascent, scale);
        var it = CodepointIter{ .text = text };
        while (it.next()) |cp| {
            const charData = self.font.?.val.getChar(cp) orelse continue;

            // Only draw if character has visual representation
            if (charData.size.x > 0 and charData.size.y > 0) {
                self.spriteBatch.draw(
                    &self.font.?.val.texture,
                    RectF.fromPosSize(
                        currX + scaleInt(charData.bearing.x, scale),
                        posY - scaleInt(charData.bearing.y, scale),
                        scaleInt(charData.size.x, scale),
                        scaleInt(charData.size.y, scale),
                    ),
                    charData.coords,
                    .none,
                );
            }

            const advanceScale = scaleInt(charData.advance, scale);
            currX += advanceScale;
            drawSize.x += advanceScale;
            drawSize.y = @max(drawSize.y, scaleInt(charData.size.y, scale));
        }

        return drawSize;
    }

    // Like drawString but clips character quads to `clip` in screen space.
    // Partially-visible edge characters have their source UV rect trimmed to
    // match so no bleed from adjacent font glyphs appears.
    pub fn drawClippedString(self: *TextRenderer, text: []const u8, pos: Vec2I, clip: RectF) Vec2I {
        var currX: i32 = pos.x;
        var drawSize: Vec2I = .{ .x = 0, .y = 0 };

        if (self.font == null) {
            std.log.err("TextRenderer: No Font set. Cannot draw text.", .{});
            return drawSize;
        }

        self.syncAtlasForText(text);

        const posY = pos.y + self.font.?.val.ascent;
        var it = CodepointIter{ .text = text };
        while (it.next()) |cp| {
            const charData = self.font.?.val.getChar(cp) orelse continue;

            if (charData.size.x > 0 and charData.size.y > 0) {
                var dest = RectF.fromPosSize(
                    currX + charData.bearing.x,
                    posY - charData.bearing.y,
                    charData.size.x,
                    charData.size.y,
                );
                var src = charData.coords;

                // Entirely left of clip — advance cursor but don't draw.
                if (dest.r <= clip.l) {
                    currX += @intCast(charData.advance);
                    drawSize.x += @intCast(charData.advance);
                    continue;
                }
                // Entirely right of clip — nothing further will be visible.
                if (dest.l >= clip.r) break;

                const uv_per_px = (src.r - src.l) / dest.width();

                if (dest.l < clip.l) {
                    src.l += (clip.l - dest.l) * uv_per_px;
                    dest.l = clip.l;
                }
                if (dest.r > clip.r) {
                    src.r -= (dest.r - clip.r) * uv_per_px;
                    dest.r = clip.r;
                }

                self.spriteBatch.draw(&self.font.?.val.texture, dest, src, .none);
            }

            currX += @intCast(charData.advance);
            drawSize.x += @intCast(charData.advance);
            drawSize.y = @max(drawSize.y, charData.size.y);
        }

        return drawSize;
    }

    // Helper function to measure text without drawing
    pub fn measureString(self: *TextRenderer, text: []const u8) Vec2I {
        var width: i32 = 0;
        var height: i32 = 0;

        // Pack any not-yet-loaded blocks so their advances are known. No
        // quads are queued here, so a grow needs no batch flush.
        _ = self.font.?.val.ensureBlocksForText(text);

        var it = CodepointIter{ .text = text };
        while (it.next()) |cp| {
            const charData = self.font.?.val.getChar(cp) orelse continue;
            width += @intCast(charData.advance);
            height = @max(height, charData.size.y);
        }

        return Vec2I{ .x = width, .y = height };
    }
};
