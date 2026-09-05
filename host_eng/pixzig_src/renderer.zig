const std = @import("std");
const builtin = @import("builtin");

const stbi = @import("zstbi");
const gl = @import("zopengl").bindings;
const zmath = @import("zmath");

pub const constants = @import("./renderer/constants.zig");
pub const quad_batch = @import("./renderer/quad_batch.zig");
pub const sprite_batch = @import("./renderer/sprite_batch.zig");
pub const shape = @import("./renderer/shape.zig");
pub const stb_tt = @import("stb_truetype");

const textMod = @import("./renderer/text.zig");
const common = @import("./common.zig");
const resources = @import("./resources.zig");
const textures = @import("./renderer/textures.zig");
const shaders = @import("./renderer/shaders.zig");

const Sprite = @import("./renderer/sprites.zig").Sprite;
const Vec2I = common.Vec2I;
const Vec2U = common.Vec2U;
const RectF = common.RectF;
const Color = common.Color;
const Rotate = common.Rotate;
const Texture = textures.Texture;
const ResourceManager = resources.ResourceManager;
const Shader = shaders.Shader;
pub const FontAtlas = textMod.FontAtlas;
pub const FontFace = textMod.FontFace;
pub const Character = textMod.Character;
pub const FontMetrics = textMod.FontMetrics;
pub const measureFontFile = textMod.measureFontFile;
pub const measureFontFileIndexed = textMod.measureFontFileIndexed;
pub const findFaceIndexByName = textMod.findFaceIndexByName;

pub const QuadBatch = quad_batch.QuadBatch;
pub const StaticQuadBatch = quad_batch.StaticQuadBatch;
pub const BatchLayout = quad_batch.BatchLayout;
pub const SpriteBatchQueue = sprite_batch.SpriteBatchQueue;
pub const ShapeBatchQueue = shape.ShapeBatchQueue;
pub const TextRenderer = textMod.TextRenderer;

/// Comptime render options that allow us to compile out features we don't
/// need.  For example, if you don't need shape rendering, you can set
/// shapeRendering to false and the related code will not be included in the
///  final binary.
pub const RendererOptions = struct {
    /// Number of sprite batch queues to allocate. `begin`/`end`/`deinit`
    /// operate on all of them, but the public draw calls (`draw`,
    /// `drawSprite`, `drawTexture`, `drawFullTexture`) currently only submit
    /// to `batches[0]` — there is no API yet to route a draw call to a
    /// different batch index, so raising this above 1 has no visible effect.
    numSpriteTextures: u8 = 1,
    shapeRendering: bool = true,
    textRendering: bool = false,

    /// Quad capacity of every batch queue (sprite, overlay, shape, and the
    /// two text batches). A batch auto-flushes once this many quads are
    /// queued, so a scene that draws more than this in one `begin`/`end`
    /// simply costs extra draw calls -- correctness is unaffected. Raise it
    /// for scenes that legitimately draw tens of thousands of quads per
    /// frame (e.g. a full character grid) to keep them in one draw call.
    /// The element indices are `u32`, so values well past 1M are safe.
    maxSprites: u32 = constants.MaxSprites,
};

/// Specifies the default font for the renderer — either a TTF file path to
/// load at init time, or the id of a font already in the ResourceManager.
pub const FontSource = union(enum) {
    /// `face` is the font file path; `face_index` selects a face inside a
    /// `.ttc` collection (0 for a plain font file).
    path: struct { face: [:0]const u8, size: f32 = 20.0, face_index: i32 = 0 },
    id: []const u8,
};

/// Runtime initialization options for the renderer.
pub const RendererInitOpts = struct {
    font: ?FontSource = null,
};

/// A rendering interface that provides methods for drawing sprites, shapes
/// and writing text.
pub fn Renderer(opts: RendererOptions) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        impl: *Impl,

        const Impl = struct {
            batches: [opts.numSpriteTextures]SpriteBatchQueue,
            overlays: SpriteBatchQueue,

            shapes: ShapeBatchQueue = undefined,
            text: TextRenderer = undefined,
        };

        const DefaultFontName = "__pixzig_default_font";

        pub fn init(alloc: std.mem.Allocator, resMgr: *ResourceManager, initOpts: RendererInitOpts) !Self {
            var rend = try alloc.create(Impl);
            errdefer alloc.destroy(rend);

            // Tracks exactly which fields of `rend` are live so a later
            // failure unwinds only what actually got initialized, in
            // reverse construction order.
            var batchesInit: usize = 0;
            var overlaysInit = false;
            var shapesInit = false;
            var textInit = false;
            errdefer {
                if (textInit) rend.text.deinit();
                if (shapesInit) rend.shapes.deinit();
                if (overlaysInit) rend.overlays.deinit();
                for (0..batchesInit) |idx| rend.batches[idx].deinit();
            }

            std.log.info("Initializing shaders.", .{});
            const texShader = try resMgr.loadShader(shaders.TextureShader, &shaders.TexVertexShader, &shaders.TexPixelShader);

            std.log.info("Setting up {} sprite batch queues.", .{opts.numSpriteTextures});
            for (0..opts.numSpriteTextures) |idx| {
                rend.batches[idx] = try SpriteBatchQueue.initCapacity(alloc, texShader, opts.maxSprites);
                batchesInit += 1;
            }
            rend.overlays = try SpriteBatchQueue.initCapacity(alloc, texShader, opts.maxSprites);
            overlaysInit = true;

            if (opts.shapeRendering) {
                std.log.info("Setting up shaders for shape renderering.", .{});
                const colorShader = try resMgr.loadShader(shaders.ColorShader, &shaders.ColorVertexShader, &shaders.ColorPixelShader);
                rend.shapes = try ShapeBatchQueue.initCapacity(alloc, colorShader, opts.maxSprites);
                shapesInit = true;
            }

            if (opts.textRendering) {
                std.log.info("Setting up text renderering.\n", .{});

                if (builtin.os.tag == .emscripten) {
                    _ = try resMgr.loadShader(shaders.FontShader, &shaders.TexVertexShader, &shaders.TextPixelShader_Web);
                    _ = try resMgr.loadShader(shaders.TextColorShader, &shaders.TextColorVertexShader, &shaders.TextColorPixelShader_Web);
                } else {
                    _ = try resMgr.loadShader(shaders.FontShader, &shaders.TexVertexShader, &shaders.TextPixelShader_Desktop);
                    _ = try resMgr.loadShader(shaders.TextColorShader, &shaders.TextColorVertexShader, &shaders.TextColorPixelShader_Desktop);
                }

                rend.text = try TextRenderer.initCapacity(alloc, resMgr, opts.maxSprites);
                textInit = true;

                if (initOpts.font) |src| {
                    switch (src) {
                        .path => |p| {
                            try resMgr.loadFontFromTtfFileIndexed(DefaultFontName, p.face, p.face_index, p.size);
                            const font = resMgr.fonts.get(DefaultFontName).?;
                            try rend.text.setFont(font);
                        },
                        .id => |id| {
                            const font = resMgr.fonts.get(id) orelse return error.NoFontWithThatName;
                            try rend.text.setFont(font);
                        },
                    }
                } else {
                    if (builtin.mode == .Debug) {
                        std.log.warn("No default font provided. Text rendering will not work until a FontAtlas is set.", .{});
                    }
                }
            }

            // set texture options
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
            gl.enable(gl.BLEND);
            gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

            return .{ .alloc = alloc, .impl = rend };
        }

        pub fn deinit(self: *Self) void {
            for (0..self.impl.batches.len) |idx| {
                self.impl.batches[idx].deinit();
            }
            self.impl.overlays.deinit();
            if (opts.shapeRendering) {
                self.impl.shapes.deinit();
            }

            if (opts.textRendering) {
                self.impl.text.deinit();
            }

            self.alloc.destroy(self.impl);
        }

        /// Set the renderer's default font to an already-loaded font in `resMgr`.
        /// Useful when the font is loaded post-init (e.g. via a manifest boot group).
        pub fn setDefaultFont(self: *Self, resMgr: *ResourceManager, id: []const u8) !void {
            std.debug.assert(opts.textRendering);
            const font = resMgr.fonts.get(id) orelse return error.NoFontWithThatName;
            try self.impl.text.setFont(font);
        }

        /// Appends a fallback face to the renderer's default font (the one
        /// loaded from `RendererInitOpts.font`). Codepoints the primary face
        /// lacks are then drawn from this face; anything no face provides
        /// falls back to the atlas's `.notdef` box. `faceIndex` selects a
        /// face inside a `.ttc`; use 0 for a plain font file.
        pub fn addDefaultFontFallback(self: *Self, resMgr: *ResourceManager, fontPath: []const u8, faceIndex: i32) !void {
            _ = self;
            std.debug.assert(opts.textRendering);
            try resMgr.addFontFallback(DefaultFontName, fontPath, faceIndex);
        }

        /// The renderer's live default font atlas -- the one from
        /// `RendererInitOpts.font`, plus any faces added via
        /// `addDefaultFontFallback`. Null when text rendering is compiled
        /// out or no default font has been set.
        ///
        /// Returned by pointer so callers can drive the atlas directly, e.g.
        /// `atlas.setFontSize(pt)` to repack it at a new pixel size. Such a
        /// change is picked up by the next `drawString` with no re-`setFont`;
        /// make it outside a `begin`/`end` pair. Any size clamping/stepping
        /// is the caller's to apply.
        pub fn defaultFontAtlas(self: *Self) ?*FontAtlas {
            if (comptime !opts.textRendering) return null;
            const handle = self.impl.text.font orelse return null;
            return &handle.val;
        }

        /// Starts a frame: opens all sprite batches (plus shape/text batches
        /// if enabled) with the given model-view-projection matrix. Pair
        /// with `end()`; draw calls between them are buffered, not submitted
        /// immediately.
        pub fn begin(self: *Self, mvp: zmath.Mat) void {
            for (0..self.impl.batches.len) |idx| {
                self.impl.batches[idx].begin(mvp);
            }
            self.impl.overlays.begin(mvp);

            if (opts.shapeRendering) {
                self.impl.shapes.begin(mvp);
            }

            if (opts.textRendering) {
                self.impl.text.begin(mvp);
            }
        }

        /// Flushes every open batch queue (sprites, overlays, shapes, text),
        /// issuing the actual GL draw calls buffered since `begin()`.
        pub fn end(self: *Self) void {
            for (0..self.impl.batches.len) |idx| {
                self.impl.batches[idx].end();
            }

            if (opts.shapeRendering) {
                self.impl.shapes.end();
            }

            self.impl.overlays.end();

            if (opts.textRendering) {
                self.impl.text.end();
            }
        }

        pub fn clear(self: *const Self, r: f32, g: f32, b: f32, a: f32) void {
            _ = self;
            gl.clearColor(r, g, b, a);
            gl.clear(gl.COLOR_BUFFER_BIT);
        }

        /// Draws a texture region. Always submits to `batches[0]`, regardless
        /// of `RendererOptions.numSpriteTextures`; see the field doc there.
        pub fn draw(self: *Self, texture: *Texture, dest: RectF, srcCoords: RectF) void {
            // TODO: Handle multiple batches
            self.impl.batches[0].draw(texture, dest, srcCoords, .none);
        }

        /// Draws a `Sprite`. Always submits to `batches[0]`; see `draw()`.
        pub fn drawSprite(self: *Self, sprite: *const Sprite) void {
            // TODO: Handle batches
            self.impl.batches[0].drawSprite(sprite);
        }

        /// Equivalent to `draw()`. Always submits to `batches[0]`.
        pub fn drawTexture(self: *Self, texture: *Texture, dest: RectF, srcCoords: RectF) void {
            self.impl.batches[0].draw(texture, dest, srcCoords, .none);
        }

        /// Draws a texture after shape batches, useful for image content in UI panels.
        pub fn drawOverlayTexture(self: *Self, texture: *Texture, dest: RectF, srcCoords: RectF) void {
            self.impl.overlays.draw(texture, dest, srcCoords, .none);
        }

        /// Draws the whole texture at `pos`, scaled uniformly by `scale`.
        /// Always submits to `batches[0]`; see `draw()`.
        pub fn drawFullTexture(self: *Self, texture: *Texture, pos: Vec2I, scale: f32) void {
            const tsx = @as(f32, @floatFromInt(texture.size.x)) * scale;
            const tsy = @as(f32, @floatFromInt(texture.size.y)) * scale;
            self.impl.batches[0].draw(texture, RectF.fromPosSize(pos.x, pos.y, @intFromFloat(tsx), @intFromFloat(tsy)), texture.src, .none);
        }

        /// Requires `RendererOptions.shapeRendering == true`. Only checked
        /// with `std.debug.assert`, so calling this when shape rendering is
        /// compiled out is undefined behavior in release builds (`shapes` is
        /// `undefined`), not a caught error.
        pub fn drawFilledRect(self: *Self, dest: RectF, color: Color) void {
            std.debug.assert(opts.shapeRendering);
            self.impl.shapes.drawFilledRect(dest, color);
        }

        /// Requires `RendererOptions.shapeRendering == true`; see `drawFilledRect()`.
        pub fn drawRect(self: *Self, dest: RectF, color: Color, lineWidth: u8) void {
            std.debug.assert(opts.shapeRendering);
            self.impl.shapes.drawRect(dest, color, lineWidth);
        }

        // This moves the outline of the rect to enclose the dest by lineWidth.
        /// Requires `RendererOptions.shapeRendering == true`; see `drawFilledRect()`.
        pub fn drawEnclosingRect(self: *Self, dest: RectF, color: Color, lineWidth: u8) void {
            std.debug.assert(opts.shapeRendering);
            self.impl.shapes.drawEnclosingRect(dest, color, lineWidth);
        }

        /// Requires `RendererOptions.textRendering == true`. Only checked
        /// with `std.debug.assert`; see `drawFilledRect()` for the release-build
        /// caveat. Also traps if no default font has been set (see `setDefaultFont`).
        pub fn drawString(self: *Self, text: []const u8, pos: Vec2I) Vec2I {
            std.debug.assert(opts.textRendering);
            return self.impl.text.drawString(text, pos);
        }

        /// Requires `RendererOptions.textRendering == true`; see `drawString()`.
        pub fn drawScaledString(self: *Self, text: []const u8, pos: Vec2I, scale: f32) Vec2I {
            std.debug.assert(opts.textRendering);
            return self.impl.text.drawScaledString(text, pos, scale);
        }

        /// Like `drawString`, but tints every glyph by `color` instead of
        /// rendering plain white. Requires `RendererOptions.textRendering == true`.
        pub fn drawStringColored(self: *Self, text: []const u8, pos: Vec2I, color: Color) Vec2I {
            std.debug.assert(opts.textRendering);
            return self.impl.text.drawStringColored(text, pos, color);
        }

        /// Measures `text` without drawing it. Requires `RendererOptions.textRendering == true`.
        pub fn measureString(self: *Self, text: []const u8) Vec2I {
            std.debug.assert(opts.textRendering);
            return self.impl.text.measureString(text);
        }
    };
}
