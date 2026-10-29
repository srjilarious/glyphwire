// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const geometry = @import("geometry.zig");
const dividers = @import("dividers.zig");
const shadow_mod = @import("shadow.zig");
const scroll = @import("scroll.zig");
const selection = @import("selection.zig");
const emoji = @import("emoji.zig");
const overlays = @import("overlays.zig");
const capture = @import("capture.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;
const CursorShape = config.CursorShape;

// ── Static quad batches ───────────────────────────────────────────────
//
// Each layer's composited output is cached as a small set of
// `host_eng.renderer.StaticQuadBatch`es (`LayerBatches`) built once and
// re-drawn every frame with no per-frame vertex upload -- see
// `syncBatches`. A batch binds exactly one texture, so the categories
// split by texture: `color_bg` (no texture: cell colour fills, the
// selection tint and the highlight tint), `icon_bg`/`icon_fg` (the shared
// icon atlas), `text` (the glyph atlas), plus one batch per distinct
// image handle (`images`) and one per non-atlas icon handle
// (`icon_fallback`). The caret is deliberately *not* batched -- it blinks
// on its own clock and is a single immediate-mode draw only while shown
// (see `overlays.drawRootCaret`).

/// Shape batch: colour fills, no texture. `ColorShader`.
const ShapeBatch = host_eng.renderer.StaticQuadBatch(.{ .posDim = 2, .colorDim = 4 });
/// Textured, untinted: image and icon cells. `TextureShader`.
const SpriteBatch = host_eng.renderer.StaticQuadBatch(.{ .posDim = 2, .texDim = 2 });
/// Textured + per-vertex colour: glyph quads against the font atlas.
/// `TextColorShader`, matching the engine's own `TextRenderer` colour batch.
const GlyphBatch = host_eng.renderer.StaticQuadBatch(.{ .posDim = 2, .texDim = 2, .colorDim = 4 });

/// One image / non-atlas-icon handle's quads, bound to that handle's
/// texture. `key` is the `glyphwire.ImageHandle`.
const TexBatch = struct {
    key: u64,
    batch: SpriteBatch,
};

/// One scaled-text batch, bound to whichever crisp per-size atlas
/// (`Renderer.atlasForScale`) `scale` names -- `text_scale != .x1` glyphs
/// can't share `LayerBatches.text`'s single texture bind (the default
/// atlas's), so each scale in use on a layer gets its own batch, the same
/// "one bound texture per batch" reason `TexBatch` exists for images.
const ScaledTextBatch = struct {
    scale: glyphwire.TextScale,
    batch: GlyphBatch,
};

/// One uploaded image texture plus the `core.ImageEntry.generation` the
/// upload was made from. The bytes behind a handle are mutable now
/// (`update_image`), so the handle alone no longer identifies what is on
/// the GPU -- see `Renderer.reconcileImageTextures`.
pub const CachedImage = struct {
    managed: *host_eng.ManagedTexture,
    generation: u32,
};

/// Identifies one cached image texture. Image handles are allocated per
/// context and start at 1 in each, exactly like layer handles, so the
/// context handle is part of the identity for exactly the reason
/// `BatchKey` carries one -- see `Renderer.image_textures`.
pub const ImageKey = struct {
    context: glyphwire.ContextHandle,
    handle: glyphwire.ImageHandle,
};

/// Identifies one cached drop-shadow texture: everything about a
/// `core.Shadow` that changes its pixels. `x`/`y`/`spread` only move or
/// size the drawn quads, so they aren't part of it.
pub const ShadowKey = struct {
    blur: u32,
    radius: u32,
    color: [4]u8,
};

/// Identifies one cached layer batch. Layer handles are per-context, so
/// the context handle is part of the identity -- see
/// `Renderer.layer_batches`.
pub const BatchKey = struct {
    context: glyphwire.ContextHandle,
    layer: glyphwire.LayerHandle,
};

/// The cached quad batches for one layer, plus the state its last build
/// was keyed on. `syncOneLayer` rebuilds when any of the keyed values
/// differ from the layer's current ones.
pub const LayerBatches = struct {
    /// The context this layer belongs to -- the `BatchKey.context` half of
    /// the key it is stored under. Kept on the struct because the emit
    /// helpers already take a `*LayerBatches` and need the context to
    /// resolve image/icon handles in the right place (`ImageKey`).
    context: glyphwire.ContextHandle = 0,
    /// False until the first successful `rebuildLayer`.
    built: bool = false,
    /// `Layer.renderGeneration()` at the last build.
    built_gen: u64 = 0,
    /// Scrollback view offset the batch was built for (only ever non-zero
    /// for the root layer).
    built_view_offset: usize = 0,
    /// Cell pixel size at the last build -- a font-zoom changes these and
    /// every vertex position with them.
    built_cell_w: i32 = 0,
    built_cell_h: i32 = 0,
    /// `Renderer.text_epoch` at the last build -- a glyph-atlas grow moves
    /// every glyph UV, so a mismatch forces a text rebuild.
    built_text_epoch: u64 = 0,
    /// The pane origin this batch's quads were emitted at. Every vertex is
    /// in absolute window pixels, so a pane that moved invalidates the
    /// batch even though the layer's own content is untouched.
    built_origin: geometry.Origin = .{ .x = std.math.minInt(i32), .y = std.math.minInt(i32) },
    /// `Layer.opacity` at the last build (see `core.PropertyName.opacity`).
    /// The coloured batches bake it into their vertex alpha, so a change
    /// forces a rebuild; the textured ones have no colour channel and are
    /// modulated at draw time instead, which is why the factor is kept
    /// here rather than only consumed during the build.
    built_opacity: f32 = 1.0,
    /// The context's `theme_gen` this was built under: every colour in
    /// the batch was resolved against that theme.
    built_theme_gen: u64 = 0,

    /// The layer's drop shadow (`core.Shadow`), bound to its cached
    /// texture (`Renderer.shadowTexture`). At most one entry; a list only
    /// so it can share `TexBatch`'s lifecycle with the other textured
    /// batches. Drawn first -- under everything the layer itself paints.
    shadow: std.ArrayList(TexBatch) = .empty,
    /// The layer's own `background` property -- its own batch so the
    /// nine-patches can sit between it and the cells' backgrounds (see
    /// `drawLayerBatches`).
    base: ShapeBatch,
    color_bg: ShapeBatch,
    icon_bg: SpriteBatch,
    icon_fg: SpriteBatch,
    text: GlyphBatch,
    /// `Cell.style.underline`'s rects -- its own batch, drawn *after*
    /// `text` (see `drawLayerBatches`), because an underline has to stay
    /// visible under a descender: a `g` or `y` in `color_bg` order would
    /// paint over the line and break it wherever the text dips.
    underline: ShapeBatch,
    /// `Layer.rects`' quads -- drawn last (see `drawLayerBatches`) so an
    /// overlay rect sits on top of everything else the layer paints,
    /// text included.
    rects: ShapeBatch,
    images: std.ArrayList(TexBatch) = .empty,
    /// `Layer.nine_patches`' quads, one batch per `.9.png` texture.
    nine_patches: std.ArrayList(TexBatch) = .empty,
    icon_fallback: std.ArrayList(TexBatch) = .empty,
    /// `text_scale != .x1` glyphs -- see `ScaledTextBatch`.
    scaled_text: std.ArrayList(ScaledTextBatch) = .empty,
    /// Colour emoji (`FontAtlas.color`), untinted like the icons. One
    /// batch per text scale in use, keyed by `@intFromEnum(TextScale)`:
    /// each scale's atlas has its own colour texture. Created on a
    /// layer's first emoji, so a layer without one has none.
    emoji: std.ArrayList(TexBatch) = .empty,

    fn init(
        alloc: std.mem.Allocator,
        shape_shader: *host_eng.ManagedShader,
        sprite_shader: *host_eng.ManagedShader,
        glyph_shader: *host_eng.ManagedShader,
    ) !LayerBatches {
        var base = try ShapeBatch.init(alloc, shape_shader);
        errdefer base.deinit();
        var color_bg = try ShapeBatch.init(alloc, shape_shader);
        errdefer color_bg.deinit();
        var icon_bg = try SpriteBatch.init(alloc, sprite_shader);
        errdefer icon_bg.deinit();
        var icon_fg = try SpriteBatch.init(alloc, sprite_shader);
        errdefer icon_fg.deinit();
        var text = try GlyphBatch.init(alloc, glyph_shader);
        errdefer text.deinit();
        var underline = try ShapeBatch.init(alloc, shape_shader);
        errdefer underline.deinit();
        const rects = try ShapeBatch.init(alloc, shape_shader);
        return .{
            .base = base,
            .color_bg = color_bg,
            .icon_bg = icon_bg,
            .icon_fg = icon_fg,
            .text = text,
            .underline = underline,
            .rects = rects,
        };
    }

    fn deinit(self: *LayerBatches, alloc: std.mem.Allocator) void {
        self.base.deinit();
        self.color_bg.deinit();
        self.icon_bg.deinit();
        self.icon_fg.deinit();
        self.text.deinit();
        self.underline.deinit();
        self.rects.deinit();
        for (self.images.items) |*t| t.batch.deinit();
        self.images.deinit(alloc);
        for (self.nine_patches.items) |*t| t.batch.deinit();
        self.nine_patches.deinit(alloc);
        for (self.shadow.items) |*t| t.batch.deinit();
        self.shadow.deinit(alloc);
        for (self.icon_fallback.items) |*t| t.batch.deinit();
        self.icon_fallback.deinit(alloc);
        for (self.scaled_text.items) |*t| t.batch.deinit();
        self.scaled_text.deinit(alloc);
        for (self.emoji.items) |*t| t.batch.deinit();
        self.emoji.deinit(alloc);
    }
};

/// Positions/texcoords for one quad in the engine's winding order (corner 0 =
/// (l,b), 1 = (l,t), 2 = (r,t), 3 = (r,b)) -- the same order `addQuad`
/// and `TextRenderer.drawStringColored` use.
fn quad4(l: f32, t: f32, r: f32, b: f32) [4][2]f32 {
    return .{ .{ l, b }, .{ l, t }, .{ r, t }, .{ r, b } };
}

/// `c` with its alpha scaled by a layer's opacity. Baked into the vertex
/// colours at build time for the coloured batches -- the textured ones
/// take the same factor as a shader tint at draw time (`drawBatchTinted`).
fn fade(c: host_eng.Color, alpha: f32) host_eng.Color {
    if (alpha >= 1.0) return c;
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a * alpha };
}

fn colour4(c: host_eng.Color) [4][4]f32 {
    const v: [4]f32 = .{ c.r, c.g, c.b, c.a };
    return .{ v, v, v, v };
}

fn addRect(b: *ShapeBatch, dest: host_eng.RectF, c: host_eng.Color) void {
    b.addQuad(quad4(dest.l, dest.t, dest.r, dest.b), {}, colour4(c)) catch {};
}

/// Emits `Cell.style.strike`'s line for the glyph cell at `(px, py)`: a
/// rect through the text, `cols` cells wide. For an x1 cell that is its
/// own width (two for a wide character); for a scaled glyph it is the
/// whole footprint, at the middle of the enlarged glyph rather than of the
/// cell, which is why core marks only the glyph's own cell (see
/// `core.Style.strike`). Sized from the cell like `emitUnderline`'s line,
/// and scaled with the glyph so a 3x heading's strike isn't a hairline.
fn emitStrike(b: *ShapeBatch, scale: f32, cols: usize, px: i32, py: i32, color: host_eng.Color) void {
    const cw = geometry.cell_w;
    const ch = geometry.cell_h;
    if (cw <= 0 or ch <= 0) return;
    const glyph_h: i32 = @intFromFloat(@as(f32, @floatFromInt(ch)) * scale);
    const t: i32 = @max(1, @divTrunc(glyph_h, 14));
    // A little below the middle: the strike crosses lowercase letters at
    // half their x-height, and the baseline sits low in the cell.
    const y = py + @divTrunc(glyph_h * 11, 20) - @divTrunc(t, 2);
    addRect(b, host_eng.RectF.fromPosSize(px, y, cw * @as(i32, @intCast(cols)), t), color);
}

/// Emits one cell's worth of `Cell.style.underline` as filled rects into
/// `b`, at cell origin `(px, py)` in absolute window pixels.
///
/// Every dimension is derived from the current cell size rather than fixed,
/// because the font is resizable at runtime (Ctrl+/-) and a hard-coded 2px
/// line that reads right at 18px rows is a hairline at 40px ones.
///
/// **`px` is absolute, and that matters.** The repeating styles take their
/// phase from it, so a dotted or curly underline running across several
/// cells reads as one continuous line instead of restarting its pattern in
/// every cell -- which is the difference between a squiggle under a word
/// and a row of identical little marks.
fn emitUnderline(
    b: *ShapeBatch,
    style: glyphwire.Underline,
    px: i32,
    py: i32,
    color: host_eng.Color,
) void {
    const cw = geometry.cell_w;
    const ch = geometry.cell_h;
    if (cw <= 0 or ch <= 0) return;

    // Line weight, and the clearance kept below it so the line doesn't
    // touch the glyphs of the row underneath. Both at least a pixel: a
    // line rounded away to nothing is worse than one slightly too thick.
    const t: i32 = @max(1, @divTrunc(ch, 14));
    const clearance: i32 = @max(1, @divTrunc(ch, 12));
    const base = py + ch - t - clearance;

    switch (style) {
        // Handled by the caller, which doesn't call this for `.none`.
        .none => {},
        .single => addRect(b, host_eng.RectF.fromPosSize(px, base, cw, t), color),
        .double => {
            // The second line goes *above* the first: below would eat the
            // clearance and collide with the next row's ascenders.
            addRect(b, host_eng.RectF.fromPosSize(px, base, cw, t), color);
            addRect(b, host_eng.RectF.fromPosSize(px, base - 2 * t, cw, t), color);
        },
        .dotted, .dashed => {
            // One on/off cycle: a dot is square-ish, a dash a third of a
            // cell, and each is followed by a gap of its own length.
            const on: i32 = if (style == .dotted) t else @max(2, @divTrunc(cw, 3));
            const period = on * 2;
            var x = px;
            while (x < px + cw) : (x += 1) {
                if (@mod(x, period) >= on) continue;
                // One pixel column at a time, so a dash clipped by the
                // cell edge continues correctly in the next cell rather
                // than starting over.
                addRect(b, host_eng.RectF.fromPosSize(x, base, 1, t), color);
            }
        },
        .curly => {
            // A triangle wave, one full period per cell, drawn as a column
            // of 1px-wide rects. A triangle rather than a real sine: at
            // these sizes (a 2-3px amplitude) the two are indistinguishable
            // and this needs no floating point or table.
            const amp: i32 = @max(1, @divTrunc(ch, 18));
            const period: i32 = @max(4, cw);
            const half = @divTrunc(period, 2);
            var x = px;
            while (x < px + cw) : (x += 1) {
                const phase = @mod(x, period);
                // Up across the first half, back down across the second.
                const off: i32 = if (phase < half)
                    -amp + @divTrunc(2 * amp * phase, half)
                else
                    amp - @divTrunc(2 * amp * (phase - half), period - half);
                addRect(b, host_eng.RectF.fromPosSize(x, base + off, 1, t), color);
            }
        },
    }
}

fn addSprite(b: *SpriteBatch, dest: host_eng.RectF, src: host_eng.RectF) void {
    b.addQuad(quad4(dest.l, dest.t, dest.r, dest.b), quad4(src.l, src.t, src.r, src.b), {}) catch {};
}

fn addGlyph(b: *GlyphBatch, dest: host_eng.RectF, src: host_eng.RectF, c: host_eng.Color) void {
    b.addQuad(quad4(dest.l, dest.t, dest.r, dest.b), quad4(src.l, src.t, src.r, src.b), colour4(c)) catch {};
}

/// One `.natural`-scale icon whose draw is deferred past the rest of the
/// grid so its overflow paints over already-emitted neighbours -- see
/// `emitIcon` / `Layer.drawIconOver`. `foreground` routes it to the
/// overlay (`icon_fg`) batch, same as its in-cell counterpart.
pub const DeferredIcon = struct {
    icon: glyphwire.IconBg,
    pos: host_eng.Vec2I,
    foreground: bool,
};

/// One `Cell.text_scale != .x1` glyph, deferred past the rest of the grid
/// for the same reason `DeferredIcon` is: the enlarged glyph overflows
/// past its own cell, and that overflow should paint over already-emitted
/// neighbours rather than under them. See `TextScale`'s doc comment --
/// this is a pure rendering effect, the cells it overflows into are
/// otherwise ordinary. `grapheme_bytes`/`grapheme_len` copy the cell's
/// inline grapheme storage since the source `Cell` isn't guaranteed to
/// outlive the deferred pass (a scrolled/rewritten layer between the main
/// loop and the deferred one, in principle -- matching `DeferredIcon`
/// copying its `IconBg` by value rather than holding a `*Cell`).
///
/// `scale` names which atlas to draw from (`Renderer.atlasForScale`) --
/// not a float pixel multiplier. A scaled glyph is rasterized at its own
/// true size in a dedicated atlas (`host_eng.renderer.FontAtlas.cloneAtSize`)
/// rather than stretching the normal-size glyph's texture region, which
/// read as blurry and lost hinting -- see decisions.md's Text scale
/// section.
pub const DeferredScaledGlyph = struct {
    grapheme_bytes: [glyphwire.grapheme_inline_len]u8,
    grapheme_len: u8,
    pos: host_eng.Vec2I,
    color: host_eng.Color,
    scale: glyphwire.TextScale,

    fn grapheme(self: *const DeferredScaledGlyph) []const u8 {
        return self.grapheme_bytes[0..self.grapheme_len];
    }
};

/// All of the host's drawing: per-layer static quad batches, the icon
/// atlas, image / icon cells, and the frame order. The immediate overlays
/// drawn over the batches (caret, preedit, dividers, scrollbars, the list
/// dialog, the HUD) are in `overlays.zig`, and the `--screenshot`
/// readback in `capture.zig`. Owns the GPU-texture caches and the batch
/// cache; every method assumes it runs on the main (render) thread.
pub const Renderer = struct {
    app: *App,

    /// Uploaded lazily, on first encountering a cell whose background
    /// references a given image handle -- see decisions.md's Image
    /// section. The headless core never decodes pixels; it only stores the
    /// raw bytes `load_image` received (`Context.images`) plus IHDR-parsed
    /// dimensions.
    ///
    /// Keyed by **context and** handle (`ImageKey`). Image handles are
    /// per-context and start at 1 in each, so a handle-only key serves one
    /// context's texture to another's identically-numbered image -- which
    /// is what made a second `gw-read` show the first one's pages, since a
    /// freshly loaded image is always `generation` 0 and the staleness
    /// check below could not tell the two apart.
    ///
    /// Stores the `*ManagedTexture` pool, not a `Texture` value:
    /// `ManagedTexture`'s heap-allocated `Handle` stays at a stable
    /// address for its full lifetime, so `&managed.get().?.val` stays
    /// valid across the frames a `StaticQuadBatch` holds it.
    image_textures: std.AutoHashMap(ImageKey, CachedImage),
    /// Every bundled icon (`Context.icons`, seeded from the `assets/icons/`
    /// scan -- see `icons.loadIconsFromDir`) decoded once at startup and
    /// packed into a single texture, so a screen full of icons draws from
    /// one bound texture. Null only if `buildIconAtlas` failed (each icon
    /// then falls back to a per-handle `image_textures` upload, routed to
    /// `LayerBatches.icon_fallback`). `icon_uv` maps an icon's image
    /// handle to its normalized sub-rect inside `icon_atlas`.
    icon_atlas: ?*host_eng.ManagedTexture = null,
    icon_uv: std.AutoHashMap(glyphwire.ImageHandle, host_eng.RectF),
    /// Drop-shadow textures by look -- see `shadowTexture`.
    shadow_textures: std.AutoHashMap(ShadowKey, *host_eng.ManagedTexture),
    /// Scratch for the `.natural`-icon overflow handled at the end of
    /// `rebuildLayer` -- see `DeferredIcon`. Cleared (not freed) at the
    /// start of each rebuild and reused across rebuilds/layers.
    deferred_icons: std.ArrayList(DeferredIcon) = .empty,
    /// Scratch for `.text_scale != .x1` glyphs, same reuse/clearing
    /// convention as `deferred_icons`.
    deferred_scaled_text: std.ArrayList(DeferredScaledGlyph) = .empty,

    /// Crisp, dedicated atlases for `write_text`'s `scale` -- see
    /// `atlasForScale` and decisions.md's Text scale section. Lazily
    /// (re)built by cloning the default atlas (`FontAtlas.cloneAtSize`)
    /// the first time a session actually uses `.x1_5`/`.x2`/`.x3`, so a session
    /// that never does never allocates any. Null again whenever the
    /// default atlas's own `font_size` changes underneath them (a
    /// Ctrl+/- resize) -- see `invalidateScaledAtlasesIfStale`.
    scaled_atlas_1_5x: ?host_eng.renderer.FontAtlas = null,
    scaled_atlas_2x: ?host_eng.renderer.FontAtlas = null,
    scaled_atlas_3x: ?host_eng.renderer.FontAtlas = null,
    /// The default atlas's `font_size` the two atlases above were last
    /// (re)built against. Starts at a value no real font size will ever
    /// equal, so the first `syncBatches` with a live default atlas always
    /// runs the staleness check once (a no-op: both are already null).
    scaled_atlas_base_size: f32 = -1,

    /// One `LayerBatches` per live layer, keyed by **context and** layer
    /// handle. The context half is load-bearing: layer handles are
    /// allocated per context and start at 1 in each, so with more than one
    /// pane on screen at once several contexts have a layer 1, and a
    /// handle-only key would composite one pane's batch into another's
    /// rectangle. Created on first sight, rebuilt on change, freed when
    /// the layer or its context goes away (see `syncBatches`) or in
    /// `deinit`.
    layer_batches: std.AutoHashMapUnmanaged(BatchKey, *LayerBatches) = .empty,
    /// The three `ManagedShader`s the batches bind, fetched once on the
    /// first `syncBatches` (the window / GL context is up by then).
    shape_shader: ?*host_eng.ManagedShader = null,
    sprite_shader: ?*host_eng.ManagedShader = null,
    glyph_shader: ?*host_eng.ManagedShader = null,
    /// Bumped whenever a text rebuild grew the glyph atlas (every glyph's
    /// UV moved). Each `LayerBatches` records the epoch it built at; a
    /// mismatch forces a rebuild of that layer's text.
    text_epoch: u64 = 0,
    /// The session's visibility change-counter (`Server.visibleContextGen`)
    /// as of the last `syncBatches`. When it moves, what's on screen
    /// changed; stale batches are reaped against the live context set
    /// rather than dropping the whole cache, since with panes a visibility
    /// change in one pane leaves every other pane's batches perfectly
    /// good.
    last_visible_gen: u64 = 0,
    /// The pane-tree layout counter (`Server.paneLayoutGen`) as of the last
    /// `syncBatches`. A pane that moved needs its layers' quads re-emitted
    /// at the new origin even though nothing about the layers themselves
    /// changed, so this forces a rebuild of the affected contexts.
    last_pane_layout_gen: u64 = 0,
    /// `imageGenSum()` as of the last `syncBatches`. Moves when a
    /// `destroy_image` / `update_image` / scrollback sweep changed what an
    /// image handle resolves to -- none of which touches a single cell, so
    /// no layer's `render_gen` would report it -- or when a context came
    /// or went. See `reconcileImageTextures`.
    last_image_gen: u64 = 0,

    /// How the bands between panes are drawn (`host.conf.lua`'s
    /// `pane_divider_style` / `pane_divider_chars`), and the bands inside
    /// a program's split tree unless it sent `set_divider_style`. Set by
    /// `main`.
    pane_divider: dividers.Style = dividers.default_style,
    /// How opaque a `set_drop_target` wash of a pane or cell block is
    /// (`host.conf.lua`'s `drop_target_opacity`). Set by `main`. The
    /// insertion bar ignores it: a two-pixel line has to be solid to be
    /// seen at all.
    drop_target_opacity: f32 = 0.25,
    /// The glyph for every pane-divider cell, worked out once per pane
    /// layout (`divider_cells_gen`) rather than every frame: the junction
    /// rule looks at each cell's neighbours.
    divider_cells: std.ArrayList(dividers.Cell) = .empty,
    divider_lines: std.ArrayList(dividers.Line) = .empty,
    divider_cells_gen: ?u64 = null,
    /// Scratch for one context's layer bands in a glyph style (see
    /// `drawLayerDividers`). Not cached across frames: the glyphs can
    /// point into the context's own `divider_style`, which only lives
    /// while `ctx_mutex` is held.
    layer_divider_cells: std.ArrayList(dividers.Cell) = .empty,
    layer_divider_lines: std.ArrayList(dividers.Line) = .empty,

    pub fn deinit(self: *Renderer) void {
        const alloc = self.app.alloc;
        self.divider_cells.deinit(alloc);
        self.divider_lines.deinit(alloc);
        self.layer_divider_cells.deinit(alloc);
        self.layer_divider_lines.deinit(alloc);
        self.deferred_icons.deinit(alloc);
        self.deferred_scaled_text.deinit(alloc);
        if (self.scaled_atlas_1_5x) |*a| a.deinit();
        if (self.scaled_atlas_2x) |*a| a.deinit();
        if (self.scaled_atlas_3x) |*a| a.deinit();
        self.image_textures.deinit();
        self.icon_uv.deinit();
        self.shadow_textures.deinit();
        var it = self.layer_batches.valueIterator();
        while (it.next()) |lb| {
            lb.*.deinit(alloc);
            alloc.destroy(lb.*);
        }
        self.layer_batches.deinit(alloc);
    }

    /// Atlas layout constants. Icons are small (Oxygen art is 32x32, the
    /// box tiles smaller) so a fixed 1024-wide sheet with shelf packing
    /// holds the whole bundled set in a few rows; `buildIconAtlas` grows
    /// the height (to the next power of two) to fit and gives up past
    /// `icon_atlas_max_px`. `icon_atlas_pad` is a 1px transparent gutter
    /// between packed icons so neighbours can't bleed in when a UV rect is
    /// sampled at a fractional scale.
    const icon_atlas_width: usize = 1024;
    const icon_atlas_max_px: usize = 8192;
    const icon_atlas_pad: usize = 1;

    /// Decodes every icon registered in `ctx.icons` and shelf-packs them
    /// into a single RGBA texture (`icon_atlas`), recording each one's
    /// normalized sub-rect in `icon_uv`. See `icon_atlas`'s doc comment
    /// for why this exists (one bound texture for all icon draws).
    pub fn buildIconAtlas(self: *Renderer, eng: *Engine) !void {
        const alloc = self.app.alloc;

        // Distinct image handles referenced by the icon catalog. Several
        // names can point at one handle in principle; pack each handle
        // once.
        var handles: std.ArrayList(glyphwire.ImageHandle) = .empty;
        defer handles.deinit(alloc);
        {
            var seen = std.AutoHashMap(glyphwire.ImageHandle, void).init(alloc);
            defer seen.deinit();
            // Icons live only on the root context (host startup populates
            // it); a `create_context` context resolves the same handles
            // through `Context.asset_fallback`, so the atlas is always
            // built from the root's catalog regardless of what's visible.
            var it = self.app.server.session.rootContext().icons.valueIterator();
            while (it.next()) |h| {
                if ((try seen.getOrPut(h.*)).found_existing) continue;
                try handles.append(alloc, h.*);
            }
        }
        if (handles.items.len == 0) return;

        // One decoded icon awaiting its blit into the atlas buffer.
        const Packed = struct {
            handle: glyphwire.ImageHandle,
            image: host_eng.stbi.Image,
            x: usize = 0,
            y: usize = 0,
        };
        var items = try alloc.alloc(Packed, handles.items.len);
        var decoded: usize = 0;
        defer {
            for (items[0..decoded]) |*it| it.image.deinit();
            alloc.free(items);
        }
        for (handles.items) |handle| {
            const entry = self.app.server.session.rootContext().images.get(handle) orelse continue;
            var image = host_eng.stbi.Image.loadFromMemory(entry.bytes, 4) catch |err| {
                std.log.warn("glyphwire-host: icon handle {d} failed to decode for the atlas: {t}", .{ handle, err });
                continue;
            };
            // An icon that can't fit the sheet at all skips the atlas and
            // takes the per-handle fallback instead. The bundled art is
            // 32x32, so this only guards against an oversized file dropped
            // into `assets/icons/` later.
            if (image.width + 2 * icon_atlas_pad > icon_atlas_width or
                image.height + 2 * icon_atlas_pad > icon_atlas_max_px)
            {
                std.log.warn("glyphwire-host: icon handle {d} is {d}x{d}, too large for the atlas; using its own texture", .{ handle, image.width, image.height });
                image.deinit();
                continue;
            }
            items[decoded] = .{ .handle = handle, .image = image };
            decoded += 1;
        }
        const packed_items = items[0..decoded];
        if (packed_items.len == 0) return;

        // Tallest first so a shelf's wasted vertical space stays small.
        std.mem.sort(Packed, packed_items, {}, struct {
            fn lessThan(_: void, a: Packed, b: Packed) bool {
                return a.image.height > b.image.height;
            }
        }.lessThan);

        // Shelf packing: place left to right along the current shelf,
        // wrap to a new shelf (below the tallest icon on this one) when
        // the next icon would cross the sheet's right edge.
        var shelf_x: usize = icon_atlas_pad;
        var shelf_y: usize = icon_atlas_pad;
        var shelf_h: usize = 0;
        for (packed_items) |*it| {
            const w = it.image.width;
            const h = it.image.height;
            if (shelf_x + w + icon_atlas_pad > icon_atlas_width and shelf_x > icon_atlas_pad) {
                shelf_y += shelf_h + icon_atlas_pad;
                shelf_x = icon_atlas_pad;
                shelf_h = 0;
            }
            it.x = shelf_x;
            it.y = shelf_y;
            shelf_x += w + icon_atlas_pad;
            if (h > shelf_h) shelf_h = h;
        }

        const needed_h = shelf_y + shelf_h + icon_atlas_pad;
        var atlas_h: usize = 1;
        while (atlas_h < needed_h) atlas_h *= 2;
        if (atlas_h > icon_atlas_max_px) return error.IconAtlasTooLarge;

        var buf = try alloc.alloc(u8, icon_atlas_width * atlas_h * 4);
        defer alloc.free(buf);
        @memset(buf, 0);

        for (packed_items) |*it| {
            const w = it.image.width;
            const h = it.image.height;
            const src = it.image.data;
            var yy: usize = 0;
            while (yy < h) : (yy += 1) {
                const dst_off = ((it.y + yy) * icon_atlas_width + it.x) * 4;
                const src_off = yy * w * 4;
                @memcpy(buf[dst_off .. dst_off + w * 4], src[src_off .. src_off + w * 4]);
            }
        }

        const atlas = try eng.resources.loadTextureFromBuffer("glyphwire-icon-atlas", icon_atlas_width, atlas_h, buf);
        self.icon_atlas = atlas;

        const aw: f32 = @floatFromInt(icon_atlas_width);
        const ah: f32 = @floatFromInt(atlas_h);
        for (packed_items) |*it| {
            const l: f32 = @floatFromInt(it.x);
            const t: f32 = @floatFromInt(it.y);
            const r: f32 = @floatFromInt(it.x + it.image.width);
            const b: f32 = @floatFromInt(it.y + it.image.height);
            try self.icon_uv.put(it.handle, .{ .l = l / aw, .t = t / ah, .r = r / aw, .b = b / ah });
        }

        std.log.info("glyphwire-host: packed {d} icons into a {d}x{d} atlas", .{ packed_items.len, icon_atlas_width, atlas_h });
    }

    /// Returns a stable pointer to the uploaded texture for `handle` in
    /// `context`, decoding and uploading it first if this is the first
    /// time this App has seen it -- see `image_textures`'s doc comment.
    ///
    /// The entry is resolved against the *owning* context rather than the
    /// focused one: a layer being rebuilt is not necessarily in the pane
    /// that has focus, and asking the focused context for another
    /// context's handle either misses or -- worse -- hits a different
    /// image that happens to share the number.
    pub fn textureForImage(self: *Renderer, eng: *Engine, context: glyphwire.ContextHandle, handle: glyphwire.ImageHandle) ?*host_eng.Texture {
        const key: ImageKey = .{ .context = context, .handle = handle };
        const cached = self.image_textures.get(key) orelse blk: {
            const entry = self.imageEntryIn(context, handle) orelse return null;
            var image = host_eng.stbi.Image.loadFromMemory(entry.bytes, 4) catch |err| {
                std.log.err("glyphwire-host: failed to decode image handle {d}: {t}", .{ handle, err });
                return null;
            };
            defer image.deinit();

            var name_buf: [48]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, imageTextureNameFmt, .{ context, handle }) catch unreachable;
            const managed = eng.resources.loadTextureFromBuffer(name, image.width, image.height, image.data) catch |err| {
                std.log.err("glyphwire-host: failed to upload image handle {d}: {t}", .{ handle, err });
                return null;
            };
            const cached: CachedImage = .{ .managed = managed, .generation = entry.generation };
            self.image_textures.put(key, cached) catch {};
            break :blk cached;
        };

        const live = cached.managed.get() orelse {
            std.log.warn("glyphwire-host: image handle {d} has no live generation", .{handle});
            return null;
        };
        return &live.val;
    }

    /// The `eng.resources` name an image texture is registered under --
    /// shared by the upload above and the eviction below, which have to
    /// agree on it. Carries the context for the same reason `ImageKey`
    /// does: two contexts both have an image 1.
    const imageTextureNameFmt = "glyphwire-image-{d}-{d}";

    /// A single number that moves whenever any context's image table
    /// could have changed: the wrapping sum of every live context's
    /// `image_gen`, plus how many contexts there are.
    ///
    /// Watching only the *root* context (which is what this used to do)
    /// misses every image lifecycle event in a pane -- an `update_image`
    /// in a non-root context would leave the old texture on screen
    /// forever, and a `destroy_image` there would never free it. The
    /// context count is in the sum because destroying a context whose
    /// `image_gen` is still 0 -- one that loaded pages and never replaced
    /// or destroyed any, i.e. the common case for a reader that just
    /// exited -- would otherwise leave the total unchanged and leak every
    /// texture it had uploaded.
    ///
    /// Contexts are few, so this is a handful of adds per frame; the
    /// reconcile it gates is the part worth avoiding.
    fn imageGenSum(self: *Renderer) u64 {
        var sum: u64 = self.app.server.session.contexts.count();
        var it = self.app.server.session.contexts.valueIterator();
        while (it.next()) |ctx| sum +%= ctx.*.image_gen;
        return sum;
    }

    /// Drops cached GPU textures for images that were destroyed, swept,
    /// or replaced (`update_image`) since the last frame, and for every
    /// image belonging to a context that has gone away. Runs only when
    /// `imageGenSum` has moved -- see `last_image_gen`.
    ///
    /// **Every layer batch is dropped first.** A built batch holds a
    /// `*Texture` pointing into a `ManagedTexture`'s current generation,
    /// and those pointers are not refcounted: evicting (or re-uploading
    /// over) a texture while a batch still references it would leave that
    /// batch drawing freed memory. Dropping the batches is cheap next to
    /// getting this wrong, and only happens on an actual image lifecycle
    /// event, never per frame.
    fn reconcileImageTextures(self: *Renderer, eng: *Engine) void {
        const alloc = self.app.alloc;

        // Collected before removal: a hash map can't be mutated through a
        // live iterator.
        var stale: std.ArrayList(ImageKey) = .empty;
        defer stale.deinit(alloc);

        var it = self.image_textures.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const live = self.imageEntryIn(key.context, key.handle);
            // The context is gone, the image is gone from it, or the same
            // handle now holds different bytes (`update_image`).
            const is_stale = if (live) |e| e.generation != entry.value_ptr.generation else true;
            if (is_stale) stale.append(alloc, key) catch {};
        }
        if (stale.items.len == 0) return;

        self.dropAllBatches();

        for (stale.items) |key| {
            _ = self.image_textures.remove(key);
            var name_buf: [48]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, imageTextureNameFmt, .{ key.context, key.handle }) catch unreachable;
            _ = eng.resources.releaseTexture(name);
        }
    }

    /// Resolves an image handle inside one named context, following that
    /// context's `asset_fallback` so an icon handle from the session-wide
    /// catalog still resolves.
    ///
    /// Deliberately scoped to the one context: an earlier version scanned
    /// *every* context and took the first hit, which it had to, because
    /// the texture cache was keyed by handle alone. That is exactly what
    /// let a destroyed context's image 1 answer for a live context's
    /// image 1. Now that the cache key carries the context, the lookup
    /// can be precise -- and a context that has gone away correctly
    /// reports "gone" instead of matching a stranger.
    pub fn imageEntryIn(self: *Renderer, context: glyphwire.ContextHandle, handle: glyphwire.ImageHandle) ?glyphwire.ImageEntry {
        const ctx = self.app.server.session.contexts.get(context) orelse return null;
        return ctx.imageEntry(handle);
    }

    /// Frees every cached layer batch. The blanket version of
    /// `reapStaleBatches`, for when the thing that went stale isn't a
    /// layer but something the batches merely point at.
    fn dropAllBatches(self: *Renderer) void {
        const alloc = self.app.alloc;
        var it = self.layer_batches.valueIterator();
        while (it.next()) |b| {
            b.*.deinit(alloc);
            alloc.destroy(b.*);
        }
        self.layer_batches.clearRetainingCapacity();
    }

    // ── Per-frame batch sync + draw ──────────────────────────────────

    fn ensureShaders(self: *Renderer, eng: *Engine) bool {
        if (self.shape_shader != null) return true;
        self.shape_shader = eng.resources.getShader(host_eng.shaders.ColorShader) catch return false;
        self.sprite_shader = eng.resources.getShader(host_eng.shaders.TextureShader) catch return false;
        self.glyph_shader = eng.resources.getShader(host_eng.shaders.TextColorShader) catch return false;
        return true;
    }

    /// Reconciles the per-layer batch cache with the current `Context`:
    /// drops batches for destroyed layers, then rebuilds any layer whose
    /// `render_gen` / view offset / cell size / text epoch has moved since
    /// its batch was last built. Called from `render` with `ctx_mutex`
    /// held. A text rebuild can grow the glyph atlas (invalidating every
    /// layer's glyph UVs); the loop re-runs in that case so the rest
    /// rebuild at the new epoch within the same frame -- bounded, the
    /// atlas only doubles a handful of times before its 8192px cap.
    fn syncBatches(self: *Renderer, eng: *Engine) void {
        if (!self.ensureShaders(eng)) return;
        const server = self.app.server;
        const fa = eng.defaultFontAtlas();
        if (fa) |f| self.invalidateScaledAtlasesIfStale(f);

        // Reap batches whose layer -- or whose whole context -- no longer
        // exists. Keying by context means a visibility change in one pane
        // no longer invalidates anything in another, so this is a reap
        // rather than the blanket cache drop it used to be.
        const vgen = server.visibleContextGen();
        const pgen = server.paneLayoutGen();
        if (vgen != self.last_visible_gen or pgen != self.last_pane_layout_gen) {
            self.last_visible_gen = vgen;
            self.last_pane_layout_gen = pgen;
            self.reapStaleBatches();
        }

        // Before any batch is (re)built, so a rebuilt batch never picks up
        // a texture this pass is about to evict.
        const igen = self.imageGenSum();
        if (igen != self.last_image_gen) {
            self.last_image_gen = igen;
            self.reconcileImageTextures(eng);
        }

        var pass: usize = 0;
        while (pass < 6) : (pass += 1) {
            const epoch_before = self.text_epoch;

            var it = server.session.panes.valueIterator();
            while (it.next()) |pane| {
                if (!pane.mapped) continue;
                const ctx_handle = pane.top();
                const ctx = server.session.contextPtr(ctx_handle) orelse continue;
                self.syncOneContext(eng, fa, ctx_handle, ctx);
            }

            if (self.text_epoch == epoch_before) break;
        }
    }

    /// Builds every batch for one pane's on-screen context: its root layer
    /// first, then each `create_layer` layer at its context-relative
    /// position shifted by the pane's origin.
    fn syncOneContext(
        self: *Renderer,
        eng: *Engine,
        fa: ?*host_eng.renderer.FontAtlas,
        ctx_handle: glyphwire.ContextHandle,
        ctx: *glyphwire.Context,
    ) void {
        const origin = geometry.contextOrigin(ctx);
        const root_view: usize = if (scroll.rootOwned(&ctx.root)) 0 else ctx.root.view_scroll;
        self.syncOneLayer(eng, fa, .{ .context = ctx_handle, .layer = glyphwire.root_layer_handle }, &ctx.root, origin, root_view, ctx);

        for (ctx.layer_order.items) |handle| {
            const layer = ctx.layers.getPtr(handle) orelse continue;
            // A hidden layer keeps its cached batch (it is not stale, just
            // unseen), so showing it again costs no rebuild.
            if (!layer.visible) continue;
            const layer_origin: geometry.Origin = .{
                .x = @as(i32, @intFromFloat(@round(layer.pos.x))) + origin.x,
                .y = @as(i32, @intFromFloat(@round(layer.pos.y))) + origin.y,
            };
            // Its own scrollback view, not zero: a layer with a ring can
            // be scrolled back into it (the wheel and its bar both do
            // that -- see `Layer.scrollbarState`), and drawing it from
            // the live tail regardless is a bar that moves over content
            // that doesn't. The root layer two lines up has always been
            // drawn this way; this is the same thing per layer.
            self.syncOneLayer(eng, fa, .{ .context = ctx_handle, .layer = handle }, layer, layer_origin, layer.view_scroll, ctx);
        }
    }

    /// Frees cached batches whose context or layer is gone. Bounded per
    /// call: whatever it misses is caught next time the generation moves,
    /// and a leaked batch costs memory, never a wrong pixel (a batch is
    /// only ever drawn from a live walk of live contexts).
    fn reapStaleBatches(self: *Renderer) void {
        const server = self.app.server;
        var stale: [32]BatchKey = undefined;
        var n: usize = 0;
        var it = self.layer_batches.keyIterator();
        while (it.next()) |k| {
            if (n >= stale.len) break;
            const ctx = server.session.contextPtr(k.context) orelse {
                stale[n] = k.*;
                n += 1;
                continue;
            };
            if (k.layer == glyphwire.root_layer_handle) continue;
            if (ctx.layers.get(k.layer) == null) {
                stale[n] = k.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| {
            if (self.layer_batches.fetchRemove(k)) |kv| {
                kv.value.deinit(self.app.alloc);
                self.app.alloc.destroy(kv.value);
            }
        }
    }

    fn syncOneLayer(
        self: *Renderer,
        eng: *Engine,
        fa: ?*host_eng.renderer.FontAtlas,
        key: BatchKey,
        layer: *const glyphwire.Layer,
        origin: geometry.Origin,
        view_offset: usize,
        /// The layer's context, for the theme its colours resolve against.
        ctx: *const glyphwire.Context,
    ) void {
        const alloc = self.app.alloc;
        const gop = self.layer_batches.getOrPut(alloc, key) catch return;
        if (!gop.found_existing) {
            const lb = alloc.create(LayerBatches) catch {
                _ = self.layer_batches.remove(key);
                return;
            };
            lb.* = LayerBatches.init(alloc, self.shape_shader.?, self.sprite_shader.?, self.glyph_shader.?) catch {
                alloc.destroy(lb);
                _ = self.layer_batches.remove(key);
                return;
            };
            lb.context = key.context;
            gop.value_ptr.* = lb;
        }
        const lb = gop.value_ptr.*;

        const gen = layer.renderGeneration();
        const need = !lb.built or
            lb.built_gen != gen or
            lb.built_view_offset != view_offset or
            lb.built_cell_w != geometry.cell_w or
            lb.built_cell_h != geometry.cell_h or
            lb.built_text_epoch != self.text_epoch or
            lb.built_origin.x != origin.x or
            lb.built_origin.y != origin.y or
            lb.built_opacity != layer.opacity or
            lb.built_theme_gen != ctx.theme_gen;
        if (!need) return;

        self.app.profiler.add(.layers_rebuilt, 1);
        self.rebuildLayer(eng, fa, lb, layer, &ctx.theme, origin.x, origin.y, view_offset, layer.opacity);
        lb.built = true;
        lb.built_gen = gen;
        lb.built_view_offset = view_offset;
        lb.built_cell_w = geometry.cell_w;
        lb.built_cell_h = geometry.cell_h;
        lb.built_text_epoch = self.text_epoch;
        lb.built_origin = origin;
        lb.built_opacity = layer.opacity;
        lb.built_theme_gen = ctx.theme_gen;
    }

    /// What one `rebuildLayer` pass reads, handed to each of its parts:
    /// the layer, the batches being built, and where and how it lands.
    const LayerBuild = struct {
        eng: *Engine,
        lb: *LayerBatches,
        layer: *const glyphwire.Layer,
        /// What every `Color` reference in the layer resolves against.
        th: *const glyphwire.theme.Stored,
        origin_x: i32,
        origin_y: i32,
        view_offset: usize,
        /// `Layer.opacity`, folded into every colour this build emits.
        alpha: f32,
        /// The layer's *viewport* -- the window of its content grid that is
        /// actually drawn (see `core.PropertyName.viewport`). For every
        /// layer without one this is the whole grid at offset zero.
        vp_cols: usize,
        vp_rows: usize,
        off: glyphwire.CellPos,
        has_icon_atlas: bool,
    };

    /// Rebuilds every batch of one layer, back to front: the drop shadow
    /// and background, then each cell (background, decorations, glyph),
    /// the deferred overflow (natural-size icons, scaled text), the
    /// selection tint, nine-patches, overlay rects and the drop target.
    fn rebuildLayer(
        self: *Renderer,
        eng: *Engine,
        fa: ?*host_eng.renderer.FontAtlas,
        lb: *LayerBatches,
        layer: *const glyphwire.Layer,
        th: *const glyphwire.theme.Stored,
        origin_x: i32,
        origin_y: i32,
        view_offset: usize,
        alpha: f32,
    ) void {
        // Per-texture batch lists are rebuilt from scratch (a layer rarely
        // has more than one image / non-atlas icon; this only runs on an
        // actual change).
        for (lb.images.items) |*t| t.batch.deinit();
        lb.images.clearRetainingCapacity();
        for (lb.nine_patches.items) |*t| t.batch.deinit();
        lb.nine_patches.clearRetainingCapacity();
        for (lb.shadow.items) |*t| t.batch.deinit();
        lb.shadow.clearRetainingCapacity();
        for (lb.icon_fallback.items) |*t| t.batch.deinit();
        lb.icon_fallback.clearRetainingCapacity();
        for (lb.scaled_text.items) |*t| t.batch.deinit();
        lb.scaled_text.clearRetainingCapacity();
        for (lb.emoji.items) |*t| t.batch.deinit();
        lb.emoji.clearRetainingCapacity();

        lb.base.beginBuild({});
        lb.color_bg.beginBuild({});
        lb.underline.beginBuild({});
        lb.rects.beginBuild({});

        const atlas_tex: ?*const host_eng.Texture = if (self.icon_atlas) |a|
            (if (a.get()) |live| &live.val else null)
        else
            null;
        const has_icon_atlas = atlas_tex != null;
        if (atlas_tex) |t| {
            lb.icon_bg.beginBuild(t);
            lb.icon_fg.beginBuild(t);
        }

        const fa_tex: ?*const host_eng.Texture = if (fa) |f| &f.texture else null;
        if (fa_tex) |t| lb.text.beginBuild(t);

        const b: LayerBuild = .{
            .eng = eng,
            .lb = lb,
            .layer = layer,
            .th = th,
            .origin_x = origin_x,
            .origin_y = origin_y,
            .view_offset = view_offset,
            .alpha = alpha,
            .vp_cols = layer.viewportCols(),
            .vp_rows = layer.viewportRows(),
            .off = layer.scroll_off,
            .has_icon_atlas = has_icon_atlas,
        };

        if (fa) |f| self.packLayerGlyphs(&b, f);

        self.deferred_icons.clearRetainingCapacity();
        self.deferred_scaled_text.clearRetainingCapacity();
        const any_highlight = layer.sel.highlighted_ids.items.len > 0;

        self.emitLayerBackdrop(&b);

        var row: usize = 0;
        while (row < b.vp_rows) : (row += 1) {
            const cells = layer.viewRow(view_offset, b.off.row + row);
            var col: usize = 0;
            while (col < b.vp_cols) : (col += 1) {
                const c = &cells[b.off.col + col];
                const px = origin_x + @as(i32, @intCast(col)) * geometry.cell_w;
                const py = origin_y + @as(i32, @intCast(row)) * geometry.cell_h;
                self.emitCellBackground(&b, c, px, py, any_highlight);
                emitCellDecorations(&b, c, px, py);
                if (fa) |f| self.emitCellGlyph(&b, f, c, px, py);
            }
        }

        self.emitDeferred(&b, fa);
        emitSelection(&b);

        // Nine-patches (`create_nine_patch`): each cell rect goes to
        // pixels at the live cell size, then `ninePatchQuads` splits it --
        // corners at native size, edges/center stretched -- and each piece
        // samples its slice of the `.9.png`.
        if (layer.nine_patches.count() > 0) {
            var np_it = layer.nine_patches.valueIterator();
            while (np_it.next()) |np| self.emitNinePatch(eng, lb, np.*, origin_x, origin_y, b.off.row, b.off.col);
        }

        emitOverlayRects(&b);
        self.emitDropTarget(&b);

        lb.base.endBuild();
        lb.color_bg.endBuild();
        lb.underline.endBuild();
        lb.rects.endBuild();
        if (has_icon_atlas) {
            lb.icon_bg.endBuild();
            lb.icon_fg.endBuild();
        }
        if (fa_tex != null) lb.text.endBuild();
        for (lb.images.items) |*t| t.batch.endBuild();
        for (lb.nine_patches.items) |*t| t.batch.endBuild();
        for (lb.shadow.items) |*t| t.batch.endBuild();
        for (lb.icon_fallback.items) |*t| t.batch.endBuild();
        for (lb.scaled_text.items) |*t| t.batch.endBuild();
        for (lb.emoji.items) |*t| t.batch.endBuild();
    }

    /// Packs every glyph the layer shows into its atlas (the default one,
    /// or a scaled one for `text_scale` cells), then uploads once. A grow
    /// re-normalizes every glyph UV, so it bumps `text_epoch` --
    /// `syncBatches`'s loop then rebuilds the rest.
    fn packLayerGlyphs(self: *Renderer, b: *const LayerBuild, f: *host_eng.renderer.FontAtlas) void {
        var row: usize = 0;
        while (row < b.vp_rows) : (row += 1) {
            const cells = b.layer.viewRow(b.view_offset, b.off.row + row);
            for (cells[b.off.col .. b.off.col + b.vp_cols]) |*c| {
                const g = c.grapheme();
                if (g.len == 0) continue;
                if (c.text_scale == .x1) {
                    loadCellGlyphs(f, g);
                } else if (self.atlasForScale(f, c.text_scale)) |sa| {
                    // A different, dedicated atlas (`atlasForScale`)
                    // -- see `DeferredScaledGlyph`'s doc comment.
                    loadCellGlyphs(sa, g);
                }
            }
        }
        if (commitAtlas(f)) self.text_epoch +%= 1;
        if (self.scaled_atlas_1_5x) |*a| {
            if (commitAtlas(a)) self.text_epoch +%= 1;
        }
        if (self.scaled_atlas_2x) |*a| {
            if (commitAtlas(a)) self.text_epoch +%= 1;
        }
        if (self.scaled_atlas_3x) |*a| {
            if (commitAtlas(a)) self.text_epoch +%= 1;
        }
    }

    /// The drop shadow and the layer's own background: under everything
    /// else the layer paints.
    fn emitLayerBackdrop(self: *Renderer, b: *const LayerBuild) void {
        // `shadow` (see `core.Shadow`): drawn around the viewport's
        // pixel rect, before -- so under -- everything else here.
        if (b.layer.shadow) |sh_ref| {
            var sh = sh_ref;
            sh.color = b.th.resolve(sh.color);
            self.emitShadow(b.eng, b.lb, sh, b.origin_x, b.origin_y, @as(i32, @intCast(b.vp_cols)) * geometry.cell_w, @as(i32, @intCast(b.vp_rows)) * geometry.cell_h);
        }

        // `background` (see `core.PropertyName.background`): one rect
        // under the whole viewport, in its own `base` batch so the
        // nine-patches and every cell's own background and glyph
        // composite over it.
        if (b.layer.background) |bg_ref| {
            const bg = b.th.resolve(bg_ref);
            if (bg.a != 0) {
                addRect(
                    &b.lb.base,
                    host_eng.RectF.fromPosSize(
                        b.origin_x,
                        b.origin_y,
                        @as(i32, @intCast(b.vp_cols)) * geometry.cell_w,
                        @as(i32, @intCast(b.vp_rows)) * geometry.cell_h,
                    ),
                    fade(host_eng.Color.from(bg.r, bg.g, bg.b, bg.a), b.alpha),
                );
            }
        }
    }

    /// One cell's background (a colour fill, an image or an icon), its
    /// foreground icon, and the highlight tint over it.
    fn emitCellBackground(self: *Renderer, b: *const LayerBuild, c: *const glyphwire.Cell, px: i32, py: i32, any_highlight: bool) void {
        switch (c.style.bg) {
            .color => |bg_ref| {
                const bg = b.th.resolve(bg_ref);
                // Alpha alone decides transparency: the default
                // background is alpha 0, and an explicit black
                // paints (see `core.default_style`).
                if (bg.a != 0) {
                    addRect(
                        &b.lb.color_bg,
                        host_eng.RectF.fromPosSize(px, py, geometry.cell_w, geometry.cell_h),
                        fade(host_eng.Color.from(bg.r, bg.g, bg.b, bg.a), b.alpha),
                    );
                }
            },
            .image => |img| self.emitImageCell(b.eng, b.lb, img, px, py),
            .icon => |icon| self.emitIcon(b.eng, b.lb, icon, px, py, false, b.has_icon_atlas),
        }
        // `fg_icon` (`draw_icon`'s `foreground: true`, and every
        // table body icon) sits over a same-cell `.icon`
        // background -- routed to the `icon_fg` batch, drawn after
        // `icon_bg`.
        if (c.fg_icon) |icon| self.emitIcon(b.eng, b.lb, icon, px, py, true, b.has_icon_atlas);

        // Highlight tint: any cell whose `metadata_id` is in the
        // layer's highlighted-id set. Into `color_bg` so the text
        // pass paints over it and stays readable.
        if (any_highlight and b.layer.sel.isHighlighted(c.metadata_id)) {
            addRect(
                &b.lb.color_bg,
                host_eng.RectF.fromPosSize(px, py, geometry.cell_w, geometry.cell_h),
                fade(selection.selection_highlight_color, b.alpha),
            );
        }
    }

    /// One cell's underline and strikethrough.
    fn emitCellDecorations(b: *const LayerBuild, c: *const glyphwire.Cell, px: i32, py: i32) void {
        // Before the glyph, but into a batch drawn after it: an
        // underline belongs to the cell whether or not anything is
        // written in it, so a run of blanks in an underlined span
        // (a diagnostic covering trailing whitespace, a scaled
        // glyph's fill columns) still draws its part of the line.
        if (c.style.underline.style != .none) {
            const ul = c.style.underline;
            const src = b.th.resolve(ul.color orelse c.style.fg);
            emitUnderline(
                &b.lb.underline,
                ul.style,
                px,
                py,
                fade(host_eng.Color.from(src.r, src.g, src.b, src.a), b.alpha),
            );
        }
        // A wide character's spacer copies its lead's style, but
        // the lead already drew the line across both halves.
        if (c.style.strike and c.wide != .wide_spacer) {
            const src = b.th.resolve(c.style.fg);
            const per_col: usize = if (c.wide == .wide_lead) 2 else 1;
            emitStrike(
                &b.lb.underline,
                textScaleFactor(c.text_scale),
                per_col * glyphwire.scaledPitch(c.text_scale),
                px,
                py,
                fade(host_eng.Color.from(src.r, src.g, src.b, src.a), b.alpha),
            );
        }
    }

    /// One cell's glyph: an emoji, a glyph from the default atlas, or a
    /// scaled glyph deferred to `emitDeferred`.
    fn emitCellGlyph(self: *Renderer, b: *const LayerBuild, f: *host_eng.renderer.FontAtlas, c: *const glyphwire.Cell, px: i32, py: i32) void {
        const g = c.grapheme();
        if (g.len > 0) {
            const fg = b.th.resolve(c.style.fg);
            const color = fade(host_eng.Color.from(fg.r, fg.g, fg.b, fg.a), b.alpha);
            if (c.text_scale == .x1) {
                if (!self.emitEmoji(b.lb, f, .x1, g, px, py)) emitGlyphs(&b.lb.text, f, g, px, py, color);
            } else {
                var dg: DeferredScaledGlyph = .{
                    .grapheme_bytes = undefined,
                    .grapheme_len = @intCast(g.len),
                    .pos = .{ .x = px, .y = py },
                    .color = color,
                    .scale = c.text_scale,
                };
                @memcpy(dg.grapheme_bytes[0..g.len], g);
                self.deferred_scaled_text.append(self.app.alloc, dg) catch {};
            }
        }
    }

    /// What overflows its own cell, after the grid so it paints over the
    /// neighbours: natural-size icons, then scaled text.
    fn emitDeferred(self: *Renderer, b: *const LayerBuild, fa: ?*host_eng.renderer.FontAtlas) void {
        // `.natural`-scale icons overflow past their own cell, so they are
        // emitted after the grid -- when an overflow paints over
        // neighbours regardless of order.
        for (self.deferred_icons.items) |d| {
            self.emitIconCell(b.eng, b.lb, d.icon, d.pos.x, d.pos.y, d.foreground, b.has_icon_atlas);
        }

        // `text_scale != .x1` glyphs overflow past their own cell the same
        // way -- deferred so that overflow paints over already-emitted
        // neighbours regardless of grid order. See `DeferredScaledGlyph`.
        // Each drawn from its own dedicated, already-loaded atlas
        // (`atlasForScale`) into its own batch (`scaledTextBatchFor`),
        // since it isn't bound to `lb.text`'s (the default atlas's)
        // texture.
        if (fa) |f| {
            for (self.deferred_scaled_text.items) |d| {
                const sa = self.atlasForScale(f, d.scale) orelse continue;
                if (self.emitEmoji(b.lb, sa, d.scale, d.grapheme(), d.pos.x, d.pos.y)) continue;
                const batch = self.scaledTextBatchFor(b.lb, d.scale, &sa.texture) orelse continue;
                emitGlyphs(batch, sa, d.grapheme(), d.pos.x, d.pos.y, d.color);
            }
        }
    }

    fn emitSelection(b: *const LayerBuild) void {
        // Selection tint: one rect per selected row span
        // (`LayerSelection.colRange`), `above = view_offset - row` the
        // scroll-stable row key. Into `color_bg`, same reason as the
        // highlight tint.
        if (b.layer.sel.range != null) {
            var srow: usize = 0;
            while (srow < b.vp_rows) : (srow += 1) {
                // The selection is keyed on *content* rows, so the
                // viewport's own scroll offset has to go back in before
                // asking, and come back out of the drawn column span.
                const above: i64 = @as(i64, @intCast(b.view_offset)) - @as(i64, @intCast(b.off.row + srow));
                const range = b.layer.sel.colRange(above) orelse continue;
                const start = @max(range.start, b.off.col);
                const end = @min(range.end, b.off.col + b.vp_cols);
                if (end <= start) continue;
                const x0 = b.origin_x + @as(i32, @intCast(start - b.off.col)) * geometry.cell_w;
                const rect_w = @as(i32, @intCast(end - start)) * geometry.cell_w;
                const y0 = b.origin_y + @as(i32, @intCast(srow)) * geometry.cell_h;
                addRect(
                    &b.lb.color_bg,
                    host_eng.RectF.fromPosSize(x0, y0, rect_w, geometry.cell_h),
                    fade(selection.selection_highlight_color, b.alpha),
                );
            }
        }
    }

    fn emitOverlayRects(b: *const LayerBuild) void {
        // Overlay rects (`create_rect`): pixel-space boxes in the layer's
        // own content coordinate frame, translated to screen pixels by
        // subtracting the same cell-based scroll offset every other pass
        // above reads off `off`. Built into their own `rects` batch,
        // composited last (see `drawLayerBatches`) so a rect sits on top
        // of everything else the layer paints, text included.
        if (b.layer.rects.count() > 0) {
            const scroll_px_x = @as(i32, @intCast(b.off.col)) * geometry.cell_w;
            const scroll_px_y = @as(i32, @intCast(b.off.row)) * geometry.cell_h;
            var rect_it = b.layer.rects.valueIterator();
            while (rect_it.next()) |r| {
                const rx = b.origin_x + @as(i32, @intCast(r.x)) - scroll_px_x;
                const ry = b.origin_y + @as(i32, @intCast(r.y)) - scroll_px_y;
                const rw: i32 = @intCast(r.w);
                const rh: i32 = @intCast(r.h);
                const rc = b.th.resolve(r.color);
                const col = fade(host_eng.Color.from(rc.r, rc.g, rc.b, rc.a), b.alpha);
                if (r.filled) {
                    addRect(&b.lb.rects, host_eng.RectF.fromPosSize(rx, ry, rw, rh), col);
                } else {
                    // Four non-overlapping strips (top, bottom, then the
                    // left/right strips filling exactly the band between
                    // them) rather than four full-height/width bars, so a
                    // translucent `color` doesn't double up at the corners.
                    const lw_u32: u32 = @min(r.line_width, @max(@min(r.w, r.h) / 2, 1));
                    const lw: i32 = @intCast(lw_u32);
                    addRect(&b.lb.rects, host_eng.RectF.fromPosSize(rx, ry, rw, lw), col);
                    addRect(&b.lb.rects, host_eng.RectF.fromPosSize(rx, ry + rh - lw, rw, lw), col);
                    addRect(&b.lb.rects, host_eng.RectF.fromPosSize(rx, ry + lw, lw, rh - 2 * lw), col);
                    addRect(&b.lb.rects, host_eng.RectF.fromPosSize(rx + rw - lw, ry + lw, lw, rh - 2 * lw), col);
                }
            }
        }
    }

    fn emitDropTarget(self: *Renderer, b: *const LayerBuild) void {
        // The drop-target highlight (`set_drop_target`), after the overlay
        // rects so it sits over everything the layer paints. Content cells
        // go to screen pixels through the same scroll offset as above.
        if (b.layer.drop_target) |dt| {
            const rc = b.th.resolve(glyphwire.Color.role(.drop_target));
            const cw = geometry.cell_w;
            const ch = geometry.cell_h;
            const scroll_col: i32 = @intCast(b.off.col);
            const scroll_row: i32 = @intCast(b.off.row);
            switch (dt) {
                .layer, .cells => {
                    const wash = fade(host_eng.Color.from(rc.r, rc.g, rc.b, rc.a), b.alpha * self.drop_target_opacity);
                    const r: host_eng.RectF = switch (dt) {
                        .layer => .fromPosSize(b.origin_x, b.origin_y, @as(i32, @intCast(b.vp_cols)) * cw, @as(i32, @intCast(b.vp_rows)) * ch),
                        .cells => |c| .fromPosSize(
                            b.origin_x + (@as(i32, @intCast(c.col)) - scroll_col) * cw,
                            b.origin_y + (@as(i32, @intCast(c.row)) - scroll_row) * ch,
                            @as(i32, @intCast(c.cols)) * cw,
                            @as(i32, @intCast(c.rows)) * ch,
                        ),
                        .insert => unreachable,
                    };
                    addRect(&b.lb.rects, r, wash);
                },
                .insert => |ins| {
                    // A quarter of a cell, at least two pixels, centred on
                    // the column boundary -- but never left of the layer,
                    // where a bar at column 0 would be half cut off.
                    const bar_w: i32 = @max(2, @divTrunc(cw, 4));
                    const edge = b.origin_x + (@as(i32, @intCast(ins.col)) - scroll_col) * cw;
                    const x = @max(b.origin_x, edge - @divTrunc(bar_w, 2));
                    const solid = fade(host_eng.Color.from(rc.r, rc.g, rc.b, rc.a), b.alpha);
                    addRect(&b.lb.rects, host_eng.RectF.fromPosSize(
                        x,
                        b.origin_y + (@as(i32, @intCast(ins.row)) - scroll_row) * ch,
                        bar_w,
                        @as(i32, @intCast(ins.rows)) * ch,
                    ), solid);
                },
            }
        }
    }

    /// Emits a layer's drop shadow around its `w x h` pixel rect at
    /// `(x0, y0)`: the cached texture for this blur/radius/colour, split
    /// like a nine-patch (`shadow_mod.geometry`) over the rect moved by
    /// `x`/`y` and grown by `blur + spread` on every side.
    fn emitShadow(self: *Renderer, eng: *Engine, lb: *LayerBatches, sh: glyphwire.Shadow, x0: i32, y0: i32, w: i32, h: i32) void {
        const out = shadow_mod.outset(sh);
        const dw = w + 2 * out;
        const dh = h + 2 * out;
        if (dw <= 0 or dh <= 0) return;
        const tex = self.shadowTexture(eng, sh) orelse return;
        const batch = self.texBatchFor(&lb.shadow, 0, tex) orelse return;

        const g = shadow_mod.geometry(sh);
        const left = x0 + sh.x - out;
        const top = y0 + sh.y - out;
        const side: f32 = @floatFromInt(g.side);
        for (glyphwire.ninePatchQuads(g.style(), @intCast(dw), @intCast(dh))) |q| {
            if (q.dst_w == 0 or q.dst_h == 0 or q.src_w == 0 or q.src_h == 0) continue;
            const dest = host_eng.RectF.fromPosSize(
                left + @as(i32, @intCast(q.dst_x)),
                top + @as(i32, @intCast(q.dst_y)),
                @intCast(q.dst_w),
                @intCast(q.dst_h),
            );
            const src = host_eng.RectF{
                .l = @as(f32, @floatFromInt(q.src_x)) / side,
                .t = @as(f32, @floatFromInt(q.src_y)) / side,
                .r = @as(f32, @floatFromInt(q.src_x + q.src_w)) / side,
                .b = @as(f32, @floatFromInt(q.src_y + q.src_h)) / side,
            };
            addSprite(batch, dest, src);
        }
    }

    /// The uploaded texture for a shadow's look, building it on first
    /// use. Keyed on everything that changes the pixels (`ShadowKey`) --
    /// not on the layer's size, which the nine-patch split absorbs -- and
    /// kept for the session: a program uses a handful of looks, so the
    /// cache stays a few small textures and is never evicted.
    pub fn shadowTexture(self: *Renderer, eng: *Engine, sh: glyphwire.Shadow) ?*host_eng.Texture {
        const key: ShadowKey = .{ .blur = sh.blur, .radius = sh.radius, .color = .{ sh.color.r, sh.color.g, sh.color.b, sh.color.a } };
        const managed = self.shadow_textures.get(key) orelse blk: {
            const pixels = shadow_mod.build(self.app.alloc, sh) catch |err| {
                std.log.err("glyphwire-host: failed to build a shadow texture: {t}", .{err});
                return null;
            };
            defer self.app.alloc.free(pixels);
            const side = shadow_mod.geometry(sh).side;
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "glyphwire-shadow-{d}-{d}-{d}-{d}-{d}-{d}", .{ sh.blur, sh.radius, sh.color.r, sh.color.g, sh.color.b, sh.color.a }) catch unreachable;
            const m = eng.resources.loadTextureFromBuffer(name, side, side, pixels) catch |err| {
                std.log.err("glyphwire-host: failed to upload a shadow texture: {t}", .{err});
                return null;
            };
            self.shadow_textures.put(key, m) catch {};
            break :blk m;
        };
        const live = managed.get() orelse return null;
        return &live.val;
    }

    /// Emits one nine-patch's quads into its texture's `nine_patches`
    /// batch. `off_row`/`off_col` are the layer's scroll offset in cells,
    /// subtracted the same way the rect pass does so a panel pans with the
    /// content. The texture still carries the 1px guide border, so every
    /// UV normalizes by the full image size (`ninePatchQuads`' `src` is in
    /// those coordinates already).
    fn emitNinePatch(self: *Renderer, eng: *Engine, lb: *LayerBatches, np: glyphwire.NinePatch, origin_x: i32, origin_y: i32, off_row: usize, off_col: usize) void {
        if (np.rows == 0 or np.cols == 0) return;
        const entry = self.imageEntryIn(lb.context, np.style.image) orelse return;
        const tex = self.textureForImage(eng, lb.context, np.style.image) orelse return;
        const batch = self.texBatchFor(&lb.nine_patches, np.style.image, tex) orelse return;

        const x0 = origin_x + (@as(i32, @intCast(np.col)) - @as(i32, @intCast(off_col))) * geometry.cell_w;
        const y0 = origin_y + (@as(i32, @intCast(np.row)) - @as(i32, @intCast(off_row))) * geometry.cell_h;
        const w: u32 = @intCast(@as(i32, @intCast(np.cols)) * geometry.cell_w);
        const h: u32 = @intCast(@as(i32, @intCast(np.rows)) * geometry.cell_h);

        const tex_w: f32 = @floatFromInt(entry.width);
        const tex_h: f32 = @floatFromInt(entry.height);
        for (glyphwire.ninePatchQuads(np.style, w, h)) |q| {
            if (q.dst_w == 0 or q.dst_h == 0 or q.src_w == 0 or q.src_h == 0) continue;
            const dest = host_eng.RectF.fromPosSize(
                x0 + @as(i32, @intCast(q.dst_x)),
                y0 + @as(i32, @intCast(q.dst_y)),
                @intCast(q.dst_w),
                @intCast(q.dst_h),
            );
            const src = host_eng.RectF{
                .l = @as(f32, @floatFromInt(q.src_x)) / tex_w,
                .t = @as(f32, @floatFromInt(q.src_y)) / tex_h,
                .r = @as(f32, @floatFromInt(q.src_x + q.src_w)) / tex_w,
                .b = @as(f32, @floatFromInt(q.src_y + q.src_h)) / tex_h,
            };
            addSprite(batch, dest, src);
        }
    }

    /// Finds (or lazily creates + `beginBuild`s) the per-handle sprite
    /// batch for `key` in `list`, bound to `tex`. Null on an allocation
    /// failure.
    fn texBatchFor(self: *Renderer, list: *std.ArrayList(TexBatch), key: u64, tex: *const host_eng.Texture) ?*SpriteBatch {
        for (list.items) |*t| {
            if (t.key == key) return &t.batch;
        }
        const nb = SpriteBatch.init(self.app.alloc, self.sprite_shader.?) catch return null;
        list.append(self.app.alloc, .{ .key = key, .batch = nb }) catch {
            var m = nb;
            m.deinit();
            return null;
        };
        const bp = &list.items[list.items.len - 1].batch;
        bp.beginBuild(tex);
        return bp;
    }

    /// `texBatchFor`, but for a layer's `scaled_text` list -- keyed by
    /// `TextScale` (at most 3 entries, `.x1_5`/`.x2`/`.x3`) instead of a handle,
    /// and building a `GlyphBatch` (with a colour channel) instead of a
    /// plain `SpriteBatch`. `rebuildLayer` empties `lb.scaled_text` at the
    /// start of every rebuild, so "found existing" only ever means
    /// "already created earlier in *this* rebuild".
    fn scaledTextBatchFor(self: *Renderer, lb: *LayerBatches, scale: glyphwire.TextScale, tex: *const host_eng.Texture) ?*GlyphBatch {
        for (lb.scaled_text.items) |*t| {
            if (t.scale == scale) return &t.batch;
        }
        const nb = GlyphBatch.init(self.app.alloc, self.glyph_shader.?) catch return null;
        lb.scaled_text.append(self.app.alloc, .{ .scale = scale, .batch = nb }) catch {
            var m = nb;
            m.deinit();
            return null;
        };
        const bp = &lb.scaled_text.items[lb.scaled_text.items.len - 1].batch;
        bp.beginBuild(tex);
        return bp;
    }

    /// One cell's portion of an image background -- the sub-rect of the
    /// source texture starting at `img.offset_x/y`, sized to whatever fits
    /// both the cell and the image's remaining pixels, never stretched
    /// beyond the aspect-preserving `img.scale` the draw asked for
    /// (decisions.md's Image section). Emitted into that image handle's
    /// own `images` batch.
    ///
    /// At `img.scale == 1` the cell samples one cell's worth of source
    /// pixels and draws them 1:1 (the original behavior). At `scale < 1`
    /// it samples `cell_px / scale` source pixels -- proportionally more,
    /// since the fixed cell grid has to cover a rendered image that's now
    /// smaller -- and draws that slice back down at `scale`, so an
    /// interior cell still fills exactly `cell_px` on screen and the
    /// image's right/bottom edge cell is the only partial one.
    ///
    /// `img.src_right`/`src_bottom` clip that "remaining pixels" bound to
    /// `draw_image`'s optional source rect on top of the image's own real
    /// edge, so a sprite drawn from the middle of a sheet clips cleanly at
    /// its own edge instead of bleeding into a neighbouring sprite.
    fn emitImageCell(self: *Renderer, eng: *Engine, lb: *LayerBatches, img: glyphwire.ImageBg, px: i32, py: i32) void {
        const entry = self.imageEntryIn(lb.context, img.handle) orelse return;
        const eff_right = @min(entry.width, img.src_right);
        const eff_bottom = @min(entry.height, img.src_bottom);
        if (img.offset_x >= eff_right or img.offset_y >= eff_bottom) return;

        const tex = self.textureForImage(eng, lb.context, img.handle) orelse return;

        const s: f32 = if (img.scale > 0) img.scale else 1.0;
        const cell_w_f: f32 = @floatFromInt(geometry.cell_w);
        const cell_h_f: f32 = @floatFromInt(geometry.cell_h);
        const rem_w_f: f32 = @floatFromInt(eff_right - img.offset_x);
        const rem_h_f: f32 = @floatFromInt(eff_bottom - img.offset_y);

        // Source pixels this cell reaches into, capped at the image's edge.
        const src_w_px: f32 = @min(cell_w_f / s, rem_w_f);
        const src_h_px: f32 = @min(cell_h_f / s, rem_h_f);
        if (src_w_px <= 0 or src_h_px <= 0) return;

        // On-screen size: a full cell for interior cells, less only where
        // the image ran out before the cell did.
        const dest_w: f32 = src_w_px * s;
        const dest_h: f32 = src_h_px * s;

        const img_w_f: f32 = @floatFromInt(entry.width);
        const img_h_f: f32 = @floatFromInt(entry.height);
        const src = host_eng.RectF{
            .l = @as(f32, @floatFromInt(img.offset_x)) / img_w_f,
            .t = @as(f32, @floatFromInt(img.offset_y)) / img_h_f,
            .r = (@as(f32, @floatFromInt(img.offset_x)) + src_w_px) / img_w_f,
            .b = (@as(f32, @floatFromInt(img.offset_y)) + src_h_px) / img_h_f,
        };

        const px_f: f32 = @floatFromInt(px);
        const py_f: f32 = @floatFromInt(py);
        const dest = host_eng.RectF{ .l = px_f, .t = py_f, .r = px_f + dest_w, .b = py_f + dest_h };

        const batch = self.texBatchFor(&lb.images, img.handle, tex) orelse return;
        addSprite(batch, dest, src);
    }

    /// `.natural`-scale icons can overflow into cells not yet emitted, so
    /// they are deferred to after the grid (see `rebuildLayer`);
    /// `.fit`/`.stretch` never overflow and are emitted in place.
    fn emitIcon(self: *Renderer, eng: *Engine, lb: *LayerBatches, icon: glyphwire.IconBg, px: i32, py: i32, foreground: bool, has_icon_atlas: bool) void {
        if (icon.scale == .natural) {
            self.deferred_icons.append(self.app.alloc, .{ .icon = icon, .pos = .{ .x = px, .y = py }, .foreground = foreground }) catch {};
        } else {
            self.emitIconCell(eng, lb, icon, px, py, foreground, has_icon_atlas);
        }
    }

    /// Emits one icon's quad -- from the shared atlas into
    /// `icon_bg`/`icon_fg` when the handle is packed there, otherwise from
    /// the handle's own texture into an `icon_fallback` batch. Scaling /
    /// alignment / `src_*` mapping match the old `drawIconCell`.
    fn emitIconCell(self: *Renderer, eng: *Engine, lb: *LayerBatches, icon: glyphwire.IconBg, px: i32, py: i32, foreground: bool, has_icon_atlas: bool) void {
        const entry = self.app.server.ctx.imageEntry(icon.handle) orelse return;
        if (entry.width == 0 or entry.height == 0) return;

        const atlas_uv: ?host_eng.RectF = if (has_icon_atlas) self.icon_uv.get(icon.handle) else null;

        const cell_w_f: f32 = @floatFromInt(geometry.cell_w);
        const cell_h_f: f32 = @floatFromInt(geometry.cell_h);
        const img_w_f: f32 = @floatFromInt(entry.width);
        const img_h_f: f32 = @floatFromInt(entry.height);

        const dest_w, const dest_h = switch (icon.scale) {
            .fit => blk: {
                const scale = @min(cell_w_f / img_w_f, cell_h_f / img_h_f);
                break :blk .{ img_w_f * scale, img_h_f * scale };
            },
            .stretch => .{ cell_w_f, cell_h_f },
            .natural => blk: {
                var scale: f32 = 1.0;
                if (icon.max_w) |mw| scale = @min(scale, @as(f32, @floatFromInt(mw)) / img_w_f);
                if (icon.max_h) |mh| scale = @min(scale, @as(f32, @floatFromInt(mh)) / img_h_f);
                break :blk .{ img_w_f * scale, img_h_f * scale };
            },
        };

        const pos_x_f: f32 = @floatFromInt(px);
        const pos_y_f: f32 = @floatFromInt(py);
        const dest_x = pos_x_f + switch (icon.h_align) {
            .start => 0,
            .center => (cell_w_f - dest_w) / 2,
            .end => cell_w_f - dest_w,
        };
        const dest_y = pos_y_f + switch (icon.v_align) {
            .start => 0,
            .center => (cell_h_f - dest_h) / 2,
            .end => cell_h_f - dest_h,
        };
        const dest = host_eng.RectF{ .l = dest_x, .t = dest_y, .r = dest_x + dest_w, .b = dest_y + dest_h };

        // The whole icon: its atlas sub-rect, or all of a fallback
        // per-handle texture.
        if (atlas_uv) |a| {
            addSprite(if (foreground) &lb.icon_fg else &lb.icon_bg, dest, a);
        } else {
            const tex = self.textureForImage(eng, lb.context, icon.handle) orelse return;
            const batch = self.texBatchFor(&lb.icon_fallback, icon.handle, tex) orelse return;
            addSprite(batch, dest, host_eng.RectF{ .l = 0, .t = 0, .r = 1, .b = 1 });
        }
    }

    /// Emits `text`'s glyph quads starting at cell top-left `(px, py)`,
    /// mirroring `host_eng.renderer.TextRenderer.drawStringColored`:
    /// baseline at `py + atlas.ascent`, each glyph placed by its bearing
    /// and advanced by its `advance`, UVs straight from `atlas`. Always
    /// 1:1 against whatever `atlas` was rasterized at -- a `text_scale`d
    /// cell draws from a bigger dedicated atlas (`atlasForScale`) rather
    /// than stretching this one's glyphs, so there is no separate scale
    /// factor here. See `TextScale`'s doc comment and decisions.md's Text
    /// scale section.
    fn emitGlyphs(batch: *GlyphBatch, atlas: *host_eng.renderer.FontAtlas, text: []const u8, px: i32, py: i32, color: host_eng.Color) void {
        const pos_y = py + atlas.ascent;
        var curr_x = px;
        var it = (std.unicode.Utf8View.initUnchecked(text)).iterator();
        while (it.nextCodepoint()) |cp| {
            // A presentation choice, not a glyph: a text font without one
            // would draw its tofu box.
            if (emoji.isVariationSelector(cp)) continue;
            const cd = atlas.getChar(@intCast(cp)) orelse continue;
            if (cd.size.x > 0 and cd.size.y > 0) {
                const dest = host_eng.RectF.fromPosSize(curr_x + cd.bearing.x, pos_y - cd.bearing.y, cd.size.x, cd.size.y);
                addGlyph(batch, dest, cd.coords, color);
            }
            curr_x += cd.advance;
        }
    }

    /// The codepoint to draw from `atlas`'s colour emoji font for a cell
    /// holding grapheme `g`, or null to draw it as text. The grapheme's
    /// first codepoint decides, with the one after it as its variation
    /// selector (`emoji.prefersColor`); a colour glyph also stands in for
    /// a codepoint no text font has, rather than the tofu box.
    fn colorGlyphFor(atlas: *host_eng.renderer.FontAtlas, g: []const u8) ?u21 {
        const color = &(atlas.color orelse return null);
        var it = (std.unicode.Utf8View.initUnchecked(g)).iterator();
        const cp = it.nextCodepoint() orelse return null;
        if (!color.has(cp)) return null;
        if (emoji.prefersColor(cp, it.nextCodepoint())) return cp;
        return if (atlas.hasGlyph(cp)) null else cp;
    }

    /// Phase 1's packing for one cell: its colour glyph when it is drawn
    /// as one (`colorGlyphFor`), else -- or when the colour glyph can't be
    /// packed -- the text blocks it touches.
    fn loadCellGlyphs(atlas: *host_eng.renderer.FontAtlas, g: []const u8) void {
        if (colorGlyphFor(atlas, g)) |cp| {
            if (atlas.color.?.getChar(cp) != null) return;
        }
        atlas.loadBlocksForText(g);
    }

    /// Uploads what phase 1 packed into `atlas` and its colour companion.
    /// True when either texture grew, which moves every UV into it.
    fn commitAtlas(atlas: *host_eng.renderer.FontAtlas) bool {
        var grew = atlas.grew_since_upload;
        atlas.commitTexture();
        if (atlas.color) |*c| {
            grew = grew or c.grew_since_upload;
            c.commitTexture();
        }
        return grew;
    }

    /// Draws grapheme `g` as a colour emoji at cell `(px, py)` when it is
    /// one (`colorGlyphFor`), into the layer's emoji batch for `scale`.
    /// False leaves the cell to `emitGlyphs`.
    ///
    /// Only the first codepoint is drawn: a ZWJ family, a flag or a skin
    /// tone shows its base emoji, since the ligature glyphs for whole
    /// sequences need GSUB shaping. The glyph is fitted, aspect kept and
    /// never enlarged, into the cells the grapheme spans (`scale` times
    /// over for scaled text) and centred there, rather than placed by its
    /// bitmap bearings: a strike's metrics are for a proportional line,
    /// and a cell grid wants every emoji in the same box.
    fn emitEmoji(
        self: *Renderer,
        lb: *LayerBatches,
        atlas: *host_eng.renderer.FontAtlas,
        scale: glyphwire.TextScale,
        g: []const u8,
        px: i32,
        py: i32,
    ) bool {
        const cp = colorGlyphFor(atlas, g) orelse return false;
        const color = &atlas.color.?;
        const cd = color.getChar(cp) orelse return false;
        if (cd.size.x <= 0 or cd.size.y <= 0) return false;
        const batch = self.texBatchFor(&lb.emoji, @intFromEnum(scale), &color.texture) orelse return true;

        const factor = textScaleFactor(scale);
        const cols: f32 = @floatFromInt(std.math.clamp(glyphwire.stringWidth(g), 1, 2));
        const box_w = cols * @as(f32, @floatFromInt(geometry.cell_w)) * factor;
        const box_h = @as(f32, @floatFromInt(geometry.cell_h)) * factor;
        const w: f32 = @floatFromInt(cd.size.x);
        const h: f32 = @floatFromInt(cd.size.y);
        const fit = @min(1.0, @min(box_w / w, box_h / h));
        const dw = w * fit;
        const dh = h * fit;
        const x = @as(f32, @floatFromInt(px)) + (box_w - dw) / 2;
        const y = @as(f32, @floatFromInt(py)) + (box_h - dh) / 2;
        addSprite(batch, .{ .l = x, .t = y, .r = x + dw, .b = y + dh }, cd.coords);
        return true;
    }

    /// `Cell.text_scale`'s pixel multiplier against the default atlas's
    /// own `font_size` -- `1.5`/`2.0`/`3.0` for `.x1_5`/`.x2`/`.x3`, matching the
    /// "1.5x"/"2x"/"3x" naming exactly (see `TextScale`'s doc comment). Only
    /// used to pick the target size for `atlasForScale`'s clone -- glyphs
    /// themselves are drawn 1:1 out of whichever atlas that resolves to,
    /// see `emitGlyphs`.
    fn textScaleFactor(scale: glyphwire.TextScale) f32 {
        return switch (scale) {
            .x1 => 1.0,
            .x1_5 => 1.5,
            .x2 => 2.0,
            .x3 => 3.0,
        };
    }

    /// Drops every scaled-text atlas when the default atlas's
    /// `font_size` has moved since they were last built (a Ctrl+/-
    /// resize) -- `atlasForScale` lazily rebuilds whichever one(s) a
    /// layer's rebuild actually needs next, so a session that never uses
    /// `.x1_5`/`.x2`/`.x3` never pays for any of them. Bumps `text_epoch` so every
    /// layer with previously-baked scaled-glyph UVs (now pointing at a
    /// just-destroyed texture) rebuilds this frame -- the same contract
    /// a plain atlas grow already has.
    fn invalidateScaledAtlasesIfStale(self: *Renderer, default: *host_eng.renderer.FontAtlas) void {
        if (self.scaled_atlas_base_size == default.font_size) return;
        if (self.scaled_atlas_1_5x) |*a| a.deinit();
        if (self.scaled_atlas_2x) |*a| a.deinit();
        if (self.scaled_atlas_3x) |*a| a.deinit();
        self.scaled_atlas_1_5x = null;
        self.scaled_atlas_2x = null;
        self.scaled_atlas_3x = null;
        self.scaled_atlas_base_size = default.font_size;
        self.text_epoch +%= 1;
    }

    /// The atlas to draw a `scale`d glyph from: `default` itself for
    /// `.x1`, or a lazily-built crisp clone at that pixel size otherwise
    /// (`host_eng.renderer.FontAtlas.cloneAtSize`) -- see decisions.md's
    /// Text scale section for why this beats stretching `default`'s own
    /// glyphs. Null only if the clone itself fails (a bitmap-font default
    /// atlas rejects `cloneAtSize` the same way it rejects `setFontSize`)
    /// -- callers skip the glyph entirely rather than falling back to a
    /// blurry stretch, the same way a missing default atlas already
    /// skips *all* text.
    fn atlasForScale(self: *Renderer, default: *host_eng.renderer.FontAtlas, scale: glyphwire.TextScale) ?*host_eng.renderer.FontAtlas {
        const slot = switch (scale) {
            .x1 => return default,
            .x1_5 => &self.scaled_atlas_1_5x,
            .x2 => &self.scaled_atlas_2x,
            .x3 => &self.scaled_atlas_3x,
        };
        if (slot.* == null) {
            slot.* = default.cloneAtSize(default.font_size * textScaleFactor(scale), self.app.alloc) catch return null;
        }
        return &slot.*.?;
    }

    fn drawLayerBatches(self: *Renderer, eng: *Engine, key: BatchKey, clip: LayerClip) void {
        const lb = self.layer_batches.get(key) orelse return;
        if (!lb.built) return;
        const mvp = eng.projMat;
        // The layer's opacity: already baked into the coloured batches'
        // vertex alpha, and applied to the textured ones here -- they have
        // no colour channel, so the shader's `tint` uniform carries it.
        const a = lb.built_opacity;
        // Back to front: the drop shadow, the layer background, nine-patch panels (under
        // every cell background, so a selected or highlighted row inside
        // a dialog still shows), colour fills + tints, image cells, icon
        // backgrounds, foreground/overlay icons, non-atlas icons, text,
        // overlay rects (`create_rect`) last so they sit on top of
        // everything else the layer paints.
        // The shadow falls outside the layer by design, so only the pane
        // bounds it; everything after stays inside the layer's own rect.
        clipTo(eng, clip.pane);
        for (lb.shadow.items) |*t| self.drawBatchTinted(&t.batch, mvp, a);
        clipTo(eng, clip.layer);
        self.drawBatch(&lb.base, mvp);
        for (lb.nine_patches.items) |*t| self.drawBatchTinted(&t.batch, mvp, a);
        self.drawBatch(&lb.color_bg, mvp);
        for (lb.images.items) |*t| self.drawBatchTinted(&t.batch, mvp, a);
        self.drawBatchTinted(&lb.icon_bg, mvp, a);
        self.drawBatchTinted(&lb.icon_fg, mvp, a);
        for (lb.icon_fallback.items) |*t| self.drawBatchTinted(&t.batch, mvp, a);
        self.drawBatch(&lb.text, mvp);
        // Already-`fade`d per-vertex, same as `lb.text` -- plain, not
        // tinted.
        for (lb.scaled_text.items) |*t| self.drawBatch(&t.batch, mvp);
        // No colour channel to fade, so the opacity goes in as the tint,
        // as for the icons.
        for (lb.emoji.items) |*t| self.drawBatchTinted(&t.batch, mvp, a);
        // Underlines over the glyphs they belong to -- see the field's doc
        // comment -- but under `create_rect`'s overlay rects, which are
        // the layer's topmost thing by contract.
        self.drawBatch(&lb.underline, mvp);
        self.drawBatch(&lb.rects, mvp);
        clipTo(eng, clip.pane);
    }

    /// Where one layer's batches may land (`drawLayerBatches`): its
    /// pane's rect, and its own viewport rect inside that.
    const LayerClip = struct {
        pane: geometry.RectPx,
        layer: geometry.RectPx,
    };

    /// The GL scissor narrowed to `r`, in window pixels.
    fn clipTo(eng: *Engine, r: geometry.RectPx) void {
        eng.viewport.clipTo(r.x, r.y, r.x + r.w, r.y + r.h);
    }

    /// Draws one static batch, skipping it when empty, and -- while
    /// profiling -- tallying it as one draw call plus its quad count.
    /// Only the batched per-layer compositing is counted; the immediate
    /// caret / preedit / chrome passes are not.
    fn drawBatch(self: *Renderer, batch: anytype, mvp: anytype) void {
        if (batch.isEmpty()) return;
        self.app.profiler.add(.draw_calls, 1);
        self.app.profiler.add(.quads, batch.quadCount());
        batch.draw(mvp);
    }

    /// `drawBatch` for a textured batch, with the layer's opacity as the
    /// shader tint. `alpha` 1.0 is the plain draw -- `drawTinted` sets the
    /// uniform to opaque white, which the shader multiplies away.
    fn drawBatchTinted(self: *Renderer, batch: anytype, mvp: anytype, alpha: f32) void {
        if (batch.isEmpty()) return;
        self.app.profiler.add(.draw_calls, 1);
        self.app.profiler.add(.quads, batch.quadCount());
        batch.drawTinted(mvp, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = alpha });
    }

    /// Reads every layer's cells straight out of the in-process `Context`
    /// under `ctx_mutex` (the same lock `Server` takes around dispatch),
    /// (re)builds any layer whose cached batch is stale (`syncBatches`),
    /// then composites: the root layer first, its caret next, then every
    /// `create_layer` layer in `ctx.layer_order` (creation order -- later
    /// draws on top). The scrollbar is a final pass over everything.
    pub fn render(self: *Renderer, eng: *Engine) void {
        // The window theme's background, under every pane: a program
        // that paints no background of its own (a shell) shows it.
        const bg = blk: {
            const server = self.app.server;
            const session_lock = server.lockSession();
            defer session_lock.unlock();
            break :blk server.session.theme.theme.roleColor(.bg);
        };
        eng.renderer.clear(
            @as(f32, @floatFromInt(bg.r)) / 255.0,
            @as(f32, @floatFromInt(bg.g)) / 255.0,
            @as(f32, @floatFromInt(bg.b)) / 255.0,
            1.0,
        );

        {
            const server = self.app.server;
            const session_lock = server.lockSession();
            defer session_lock.unlock();

            const sb_t0: ?std.Io.Timestamp = if (self.app.profiler.active()) self.app.profiler.now() else null;
            self.syncBatches(eng);
            if (sb_t0) |s| self.app.profiler.recordSince(.sync_batches, s);

            // One pass per mapped pane. Panes never overlap, so the order
            // between them doesn't matter; the order *within* a pane does,
            // and is unchanged (root layer, caret, then `layer_order`).
            const focused_ctx = server.session.focused_context.load(.monotonic);
            var it = server.session.panes.iterator();
            while (it.next()) |e| {
                const pane = e.value_ptr;
                if (!pane.mapped) continue;
                // The raised overlay goes last, over the chrome too.
                if (server.session.isOverlayPane(e.key_ptr.*)) continue;
                const ctx_handle = pane.top();
                const ctx = server.session.contextPtr(ctx_handle) orelse continue;
                self.drawOneContext(eng, ctx_handle, ctx, ctx_handle == focused_ctx, geometry.cellRectPx(pane.rect));
            }
            eng.viewport.unclip();
        }

        // Chrome: its own begin/end so these GL draws sit over every
        // layer, text included. Divider bands, then the window scrollbar.
        // A layer's own scrollbars are not chrome -- they are drawn with
        // the layer (`drawLayerScrollbars`), so a later layer covers them.
        // Bands sit in their own cells between split layers, never inside
        // a viewport, so the bars drawn earlier can't be painted over.
        eng.renderer.begin(eng.projMat);
        overlays.renderDividers(self, eng);
        overlays.renderScrollbar(self, eng);
        eng.renderer.end();

        // The manager's raised overlay (`Session.overlay_pane`): over
        // every pane and band, under the host's own modal. Its context has
        // no background of its own, so the panes show through everywhere
        // but the layers it draws.
        {
            const server = self.app.server;
            const session_lock = server.lockSession();
            defer session_lock.unlock();
            if (server.session.overlay_pane) |h| if (server.session.panePtr(h)) |pane| if (pane.mapped) {
                const ctx_handle = pane.top();
                if (server.session.contextPtr(ctx_handle)) |ctx| {
                    const focused_ctx = server.session.focused_context.load(.monotonic);
                    self.drawOneContext(eng, ctx_handle, ctx, ctx_handle == focused_ctx, geometry.cellRectPx(pane.rect));
                    eng.viewport.unclip();
                }
            };
        }

        // Over everything a program drew, dividers and scrollbar included:
        // it is a modal the host owns.
        overlays.drawListDialog(self, eng);

        // `--screenshot`: everything for this frame is drawn but not yet
        // swapped, so GL_BACK holds exactly what's about to be shown. The
        // HUD is drawn *after* the capture so it never lands in a
        // scripted screenshot.
        if (self.app.screenshot.path) |path| {
            if (!self.app.screenshot.done and self.app.screenshot.elapsed_ms >= self.app.screenshot.delay_ms) {
                capture.captureContentArea(self, eng, path);
                self.app.screenshot.done = true;
            }
        }

        overlays.drawProfilerHud(self, eng);
    }

    /// Composites one pane's on-screen context. `focused` gates the caret:
    /// only the pane taking input shows one, which is also how the user can
    /// see which pane that is.
    fn drawOneContext(
        self: *Renderer,
        eng: *Engine,
        ctx_handle: glyphwire.ContextHandle,
        ctx: *glyphwire.Context,
        focused: bool,
        /// The pane's rect in window pixels. Nothing this context draws
        /// lands outside it, and nothing a layer draws lands outside the
        /// layer either: a glyph or icon taller than its cell (gw-ls's
        /// icons in zoe's shell panel) is cut at the edge rather than
        /// spilling over its neighbour.
        pane_px: geometry.RectPx,
    ) void {
        const origin = geometry.contextOrigin(ctx);
        // Pin the root view to the live tail while a full-screen program
        // owns the screen (`rootOwned`).
        const root_view: usize = if (scroll.rootOwned(&ctx.root)) 0 else ctx.root.view_scroll;

        clipTo(eng, pane_px);
        self.drawLayerBatches(eng, .{ .context = ctx_handle, .layer = glyphwire.root_layer_handle }, .{
            .pane = pane_px,
            .layer = geometry.intersect(pane_px, geometry.layerRectIn(origin, ctx.root.pos, ctx.root.viewportCols(), ctx.root.viewportRows())),
        });
        // This context's own split bands, before any of its layers: the
        // split layers sit either side of a band and never over one, so
        // nothing is lost by drawing them first -- and a layer that
        // *floats* (a popup, the Ctrl+` shell panel) then covers them the
        // way it covers everything else it is laid over. Drawn in the
        // chrome pass, zoe's tree divider ran straight down the panel.
        overlays.drawLayerDividers(self, eng, ctx_handle, ctx);

        // The caret follows `ctx.caret_layer` when a client set one --
        // otherwise the root cursor. Drawn here, on top of root's content
        // and below any popup layer; the pane version is drawn again after
        // its own layer batches below so it sits over that pane's content.
        const focus_caret: ?*const glyphwire.Layer = blk: {
            const h = ctx.caret_layer orelse break :blk null;
            const l = ctx.layers.getPtr(h) orelse break :blk null;
            break :blk if (l.visible) l else null;
        };
        // Every pane shows its caret: the focused one as configured and
        // blinking, the rest as a steady hollow box -- where you'd be
        // typing if you went back, the way an unfocused window shows it.
        const shape: CursorShape = if (focused) self.app.caret.shapeFor(ctx.caret_shape) else .box;
        if (ctx.caret_visible and focus_caret == null) {
            if (focused)
                overlays.drawRootCaret(self, eng, &ctx.root, origin.x, origin.y, root_view, shape, overlays.caretColor(&ctx.theme))
            else
                overlays.drawIdleRootCaret(eng, &ctx.root, origin.x, origin.y, root_view, overlays.caretColor(&ctx.theme));
        }
        // IME composition, over both: it covers the cells the caret is
        // about to write into, so it has to sit above the caret too.
        if (focused) overlays.drawPreedit(self, eng, &ctx.root, origin.x, origin.y, root_view);

        for (ctx.layer_order.items) |handle| {
            const layer = ctx.layers.getPtr(handle) orelse continue;
            if (!layer.visible) continue;
            self.drawLayerBatches(eng, .{ .context = ctx_handle, .layer = handle }, .{
                .pane = pane_px,
                .layer = geometry.intersect(pane_px, geometry.layerRectIn(origin, layer.pos, layer.viewportCols(), layer.viewportRows())),
            });
            // Right after the layer's own content, not in the chrome pass:
            // a popup created later has to cover the bars of whatever it
            // floats over, the same as it covers that layer's cells.
            overlays.drawLayerScrollbars(eng, layer, origin);
            overlays.drawResizeEdge(eng, layer, origin, overlays.themeColor(&ctx.theme, .pane_divider));
            if (ctx.caret_visible and focus_caret == layer) overlays.drawFocusedCaret(self, eng, layer, origin, shape, overlays.caretColor(&ctx.theme), focused);
        }
    }
};
