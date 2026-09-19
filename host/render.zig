// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const scroll = @import("scroll.zig");
const selection = @import("selection.zig");
const preedit_mod = @import("preedit.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

// Width in px of the `.line` caret, and thickness in px of the
// `.underline` bar and the `.box` outline.
const cursor_width = 2;
const cursor_underline_px = 2;
const cursor_box_line_px = 2;

/// IME composition overlay: a dark plate behind the in-progress text so
/// the grid content it covers doesn't show through, and an underline
/// marking it as uncommitted -- the convention every terminal and text
/// field uses for preedit. See `drawPreedit`.
const preedit_bg = host_eng.Color.from(40, 44, 60, 255);
const preedit_fg = host_eng.Color.from(235, 235, 240, 255);
const preedit_underline_px = 2;

// Profiler HUD overlay (Ctrl+Shift+P). A translucent plate top-right
// with one text line per timed phase / counter -- see `drawProfilerHud`.
const hud_bg = host_eng.Color.from(12, 14, 20, 232);
const hud_head = host_eng.Color.from(255, 220, 120, 255);
const hud_fg = host_eng.Color.from(210, 215, 225, 255);

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
// (see `drawRootCaret`).

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

    color_bg: ShapeBatch,
    icon_bg: SpriteBatch,
    icon_fg: SpriteBatch,
    text: GlyphBatch,
    /// `Layer.rects`' quads -- drawn last (see `drawLayerBatches`) so an
    /// overlay rect sits on top of everything else the layer paints,
    /// text included.
    rects: ShapeBatch,
    images: std.ArrayList(TexBatch) = .empty,
    icon_fallback: std.ArrayList(TexBatch) = .empty,
    /// `text_scale != .x1` glyphs -- see `ScaledTextBatch`.
    scaled_text: std.ArrayList(ScaledTextBatch) = .empty,

    fn init(
        alloc: std.mem.Allocator,
        shape_shader: *host_eng.ManagedShader,
        sprite_shader: *host_eng.ManagedShader,
        glyph_shader: *host_eng.ManagedShader,
    ) !LayerBatches {
        var color_bg = try ShapeBatch.init(alloc, shape_shader);
        errdefer color_bg.deinit();
        var icon_bg = try SpriteBatch.init(alloc, sprite_shader);
        errdefer icon_bg.deinit();
        var icon_fg = try SpriteBatch.init(alloc, sprite_shader);
        errdefer icon_fg.deinit();
        var text = try GlyphBatch.init(alloc, glyph_shader);
        errdefer text.deinit();
        const rects = try ShapeBatch.init(alloc, shape_shader);
        return .{ .color_bg = color_bg, .icon_bg = icon_bg, .icon_fg = icon_fg, .text = text, .rects = rects };
    }

    fn deinit(self: *LayerBatches, alloc: std.mem.Allocator) void {
        self.color_bg.deinit();
        self.icon_bg.deinit();
        self.icon_fg.deinit();
        self.text.deinit();
        self.rects.deinit();
        for (self.images.items) |*t| t.batch.deinit();
        self.images.deinit(alloc);
        for (self.icon_fallback.items) |*t| t.batch.deinit();
        self.icon_fallback.deinit(alloc);
        for (self.scaled_text.items) |*t| t.batch.deinit();
        self.scaled_text.deinit(alloc);
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

/// The divider band between two split children. Deliberately lighter than
/// the window scrollbar's track: a divider reads as a seam between panes,
/// not as chrome hanging off the edge of the window.
const divider_color = host_eng.Color.from(58, 58, 66, 255);

/// The band between two whole *panes* -- one program's surface against
/// another's. Brighter than `divider_color`, which separates two parts of
/// a single program's own layout: the seam between programs is the more
/// significant boundary and should read that way.
const pane_divider_color = host_eng.Color.from(84, 84, 96, 255);

/// The ghost band shown while a divider is being dragged, before the
/// drag ends and the layout actually moves (see `panes.Panes`).
const divider_preview_color = host_eng.Color.from(120, 120, 140, 255);

/// A pane scrollbar's track and thumb. The track is nearly transparent --
/// it sits over content rather than in a reserved gutter, so it should
/// register as a hint until the thumb is grabbed.
const pane_track_color = host_eng.Color.from(40, 40, 46, 140);
const pane_thumb_color = host_eng.Color.from(120, 120, 130, 220);

/// All of the host's drawing: per-layer static quad batches, the icon
/// atlas, image / icon cells, the caret, the scrollbar, and the
/// `--screenshot` readback. Owns the GPU-texture caches and the batch
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

    pub fn deinit(self: *Renderer) void {
        const alloc = self.app.alloc;
        self.deferred_icons.deinit(alloc);
        self.deferred_scaled_text.deinit(alloc);
        if (self.scaled_atlas_1_5x) |*a| a.deinit();
        if (self.scaled_atlas_2x) |*a| a.deinit();
        if (self.scaled_atlas_3x) |*a| a.deinit();
        self.image_textures.deinit();
        self.icon_uv.deinit();
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
    fn textureForImage(self: *Renderer, eng: *Engine, context: glyphwire.ContextHandle, handle: glyphwire.ImageHandle) ?*host_eng.Texture {
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
    fn imageEntryIn(self: *Renderer, context: glyphwire.ContextHandle, handle: glyphwire.ImageHandle) ?glyphwire.ImageEntry {
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
        self.syncOneLayer(eng, fa, .{ .context = ctx_handle, .layer = glyphwire.root_layer_handle }, &ctx.root, origin, root_view);

        for (ctx.layer_order.items) |handle| {
            const layer = ctx.layers.getPtr(handle) orelse continue;
            // A hidden layer keeps its cached batch (it is not stale, just
            // unseen), so showing it again costs no rebuild.
            if (!layer.visible) continue;
            const layer_origin: geometry.Origin = .{
                .x = @as(i32, @intFromFloat(@round(layer.pos.x))) + origin.x,
                .y = @as(i32, @intFromFloat(@round(layer.pos.y))) + origin.y,
            };
            self.syncOneLayer(eng, fa, .{ .context = ctx_handle, .layer = handle }, layer, layer_origin, 0);
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
            lb.built_opacity != layer.opacity;
        if (!need) return;

        self.app.profiler.add(.layers_rebuilt, 1);
        self.rebuildLayer(eng, fa, lb, layer, origin.x, origin.y, view_offset, layer.opacity);
        lb.built = true;
        lb.built_gen = gen;
        lb.built_view_offset = view_offset;
        lb.built_cell_w = geometry.cell_w;
        lb.built_cell_h = geometry.cell_h;
        lb.built_text_epoch = self.text_epoch;
        lb.built_origin = origin;
        lb.built_opacity = layer.opacity;
    }

    fn rebuildLayer(
        self: *Renderer,
        eng: *Engine,
        fa: ?*host_eng.renderer.FontAtlas,
        lb: *LayerBatches,
        layer: *const glyphwire.Layer,
        origin_x: i32,
        origin_y: i32,
        view_offset: usize,
        /// `Layer.opacity`, folded into every colour this build emits.
        alpha: f32,
    ) void {
        // Per-texture batch lists are rebuilt from scratch (a layer rarely
        // has more than one image / non-atlas icon; this only runs on an
        // actual change).
        for (lb.images.items) |*t| t.batch.deinit();
        lb.images.clearRetainingCapacity();
        for (lb.icon_fallback.items) |*t| t.batch.deinit();
        lb.icon_fallback.clearRetainingCapacity();
        for (lb.scaled_text.items) |*t| t.batch.deinit();
        lb.scaled_text.clearRetainingCapacity();

        lb.color_bg.beginBuild({});
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

        // Phase 1: pack every glyph this layer shows into the atlas, then
        // upload once. A grow re-normalizes every glyph UV, so bump
        // `text_epoch` -- `syncBatches`'s loop then rebuilds the rest.
        // The layer's *viewport* -- the window of its content grid that is
        // actually drawn (see `core.PropertyName.viewport`). For every
        // layer without one this is the whole grid at offset zero, which
        // is why the loops below read the same as they always did.
        const vp_cols = layer.viewportCols();
        const vp_rows = layer.viewportRows();
        const off = layer.scroll_off;

        if (fa) |f| {
            var row: usize = 0;
            while (row < vp_rows) : (row += 1) {
                const cells = layer.viewRow(view_offset, off.row + row);
                for (cells[off.col .. off.col + vp_cols]) |*c| {
                    const g = c.grapheme();
                    if (g.len == 0) continue;
                    if (c.text_scale == .x1) {
                        f.loadBlocksForText(g);
                    } else if (self.atlasForScale(f, c.text_scale)) |sa| {
                        // A different, dedicated atlas (`atlasForScale`)
                        // -- see `DeferredScaledGlyph`'s doc comment.
                        sa.loadBlocksForText(g);
                    }
                }
            }
            const grew = f.grew_since_upload;
            f.commitTexture();
            if (grew) self.text_epoch +%= 1;
            if (self.scaled_atlas_1_5x) |*a| {
                const grew_s = a.grew_since_upload;
                a.commitTexture();
                if (grew_s) self.text_epoch +%= 1;
            }
            if (self.scaled_atlas_2x) |*a| {
                const grew_s = a.grew_since_upload;
                a.commitTexture();
                if (grew_s) self.text_epoch +%= 1;
            }
            if (self.scaled_atlas_3x) |*a| {
                const grew_s = a.grew_since_upload;
                a.commitTexture();
                if (grew_s) self.text_epoch +%= 1;
            }
        }

        self.deferred_icons.clearRetainingCapacity();
        self.deferred_scaled_text.clearRetainingCapacity();
        const any_highlight = layer.highlighted_ids.items.len > 0;

        // `background` (see `core.PropertyName.background`): one rect
        // under the whole viewport, emitted first so every cell's own
        // background and glyph composite over it.
        if (layer.background) |bg| {
            if (bg.a != 0) {
                addRect(
                    &lb.color_bg,
                    host_eng.RectF.fromPosSize(
                        origin_x,
                        origin_y,
                        @as(i32, @intCast(vp_cols)) * geometry.cell_w,
                        @as(i32, @intCast(vp_rows)) * geometry.cell_h,
                    ),
                    fade(host_eng.Color.from(bg.r, bg.g, bg.b, bg.a), alpha),
                );
            }
        }

        var row: usize = 0;
        while (row < vp_rows) : (row += 1) {
            const cells = layer.viewRow(view_offset, off.row + row);
            var col: usize = 0;
            while (col < vp_cols) : (col += 1) {
                const c = &cells[off.col + col];
                const px = origin_x + @as(i32, @intCast(col)) * geometry.cell_w;
                const py = origin_y + @as(i32, @intCast(row)) * geometry.cell_h;

                switch (c.style.bg) {
                    .color => |bg| {
                        // Alpha alone decides transparency: the default
                        // background is alpha 0, and an explicit black
                        // paints (see `core.default_style`).
                        if (bg.a != 0) {
                            addRect(
                                &lb.color_bg,
                                host_eng.RectF.fromPosSize(px, py, geometry.cell_w, geometry.cell_h),
                                fade(host_eng.Color.from(bg.r, bg.g, bg.b, bg.a), alpha),
                            );
                        }
                    },
                    .image => |img| self.emitImageCell(eng, lb, img, px, py),
                    .icon => |icon| self.emitIcon(eng, lb, icon, px, py, false, has_icon_atlas),
                }
                // `fg_icon` (`draw_icon`'s `foreground: true`, and every
                // table body icon) sits over a same-cell `.icon`
                // background -- routed to the `icon_fg` batch, drawn after
                // `icon_bg`.
                if (c.fg_icon) |icon| self.emitIcon(eng, lb, icon, px, py, true, has_icon_atlas);

                // Highlight tint: any cell whose `metadata_id` is in the
                // layer's highlighted-id set. Into `color_bg` so the text
                // pass paints over it and stays readable.
                if (any_highlight and layer.isHighlighted(c.metadata_id)) {
                    addRect(
                        &lb.color_bg,
                        host_eng.RectF.fromPosSize(px, py, geometry.cell_w, geometry.cell_h),
                        fade(selection.selection_highlight_color, alpha),
                    );
                }

                if (fa) |f| {
                    const g = c.grapheme();
                    if (g.len > 0) {
                        const color = fade(host_eng.Color.from(c.style.fg.r, c.style.fg.g, c.style.fg.b, c.style.fg.a), alpha);
                        if (c.text_scale == .x1) {
                            emitGlyphs(&lb.text, f, g, px, py, color);
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
            }
        }

        // `.natural`-scale icons overflow past their own cell, so they are
        // emitted after the grid -- when an overflow paints over
        // neighbours regardless of order.
        for (self.deferred_icons.items) |d| {
            self.emitIconCell(eng, lb, d.icon, d.pos.x, d.pos.y, d.foreground, has_icon_atlas);
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
                const batch = self.scaledTextBatchFor(lb, d.scale, &sa.texture) orelse continue;
                emitGlyphs(batch, sa, d.grapheme(), d.pos.x, d.pos.y, d.color);
            }
        }

        // Selection tint: one rect per selected row span
        // (`Layer.selectionColRange`), `above = view_offset - row` the
        // scroll-stable row key. Into `color_bg`, same reason as the
        // highlight tint.
        if (layer.selection != null) {
            var srow: usize = 0;
            while (srow < vp_rows) : (srow += 1) {
                // The selection is keyed on *content* rows, so the
                // viewport's own scroll offset has to go back in before
                // asking, and come back out of the drawn column span.
                const above: i64 = @as(i64, @intCast(view_offset)) - @as(i64, @intCast(off.row + srow));
                const range = layer.selectionColRange(above) orelse continue;
                const start = @max(range.start, off.col);
                const end = @min(range.end, off.col + vp_cols);
                if (end <= start) continue;
                const x0 = origin_x + @as(i32, @intCast(start - off.col)) * geometry.cell_w;
                const rect_w = @as(i32, @intCast(end - start)) * geometry.cell_w;
                const y0 = origin_y + @as(i32, @intCast(srow)) * geometry.cell_h;
                addRect(
                    &lb.color_bg,
                    host_eng.RectF.fromPosSize(x0, y0, rect_w, geometry.cell_h),
                    fade(selection.selection_highlight_color, alpha),
                );
            }
        }

        // Overlay rects (`create_rect`): pixel-space boxes in the layer's
        // own content coordinate frame, translated to screen pixels by
        // subtracting the same cell-based scroll offset every other pass
        // above reads off `off`. Built into their own `rects` batch,
        // composited last (see `drawLayerBatches`) so a rect sits on top
        // of everything else the layer paints, text included.
        if (layer.rects.count() > 0) {
            const scroll_px_x = @as(i32, @intCast(off.col)) * geometry.cell_w;
            const scroll_px_y = @as(i32, @intCast(off.row)) * geometry.cell_h;
            var rect_it = layer.rects.valueIterator();
            while (rect_it.next()) |r| {
                const rx = origin_x + @as(i32, @intCast(r.x)) - scroll_px_x;
                const ry = origin_y + @as(i32, @intCast(r.y)) - scroll_px_y;
                const rw: i32 = @intCast(r.w);
                const rh: i32 = @intCast(r.h);
                const col = fade(host_eng.Color.from(r.color.r, r.color.g, r.color.b, r.color.a), alpha);
                if (r.filled) {
                    addRect(&lb.rects, host_eng.RectF.fromPosSize(rx, ry, rw, rh), col);
                } else {
                    // Four non-overlapping strips (top, bottom, then the
                    // left/right strips filling exactly the band between
                    // them) rather than four full-height/width bars, so a
                    // translucent `color` doesn't double up at the corners.
                    const lw_u32: u32 = @min(r.line_width, @max(@min(r.w, r.h) / 2, 1));
                    const lw: i32 = @intCast(lw_u32);
                    addRect(&lb.rects, host_eng.RectF.fromPosSize(rx, ry, rw, lw), col);
                    addRect(&lb.rects, host_eng.RectF.fromPosSize(rx, ry + rh - lw, rw, lw), col);
                    addRect(&lb.rects, host_eng.RectF.fromPosSize(rx, ry + lw, lw, rh - 2 * lw), col);
                    addRect(&lb.rects, host_eng.RectF.fromPosSize(rx + rw - lw, ry + lw, lw, rh - 2 * lw), col);
                }
            }
        }

        lb.color_bg.endBuild();
        lb.rects.endBuild();
        if (has_icon_atlas) {
            lb.icon_bg.endBuild();
            lb.icon_fg.endBuild();
        }
        if (fa_tex != null) lb.text.endBuild();
        for (lb.images.items) |*t| t.batch.endBuild();
        for (lb.icon_fallback.items) |*t| t.batch.endBuild();
        for (lb.scaled_text.items) |*t| t.batch.endBuild();
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

        // `icon.src_*` is a fraction of the icon (0..1 for a plain
        // `draw_icon`, a sub-rect only for a box tile). Map it through the
        // atlas sub-rect when drawing from the atlas; use it directly on a
        // fallback per-handle texture.
        if (atlas_uv) |a| {
            const src = host_eng.RectF{
                .l = a.l + icon.src_l * (a.r - a.l),
                .t = a.t + icon.src_t * (a.b - a.t),
                .r = a.l + icon.src_r * (a.r - a.l),
                .b = a.t + icon.src_b * (a.b - a.t),
            };
            addSprite(if (foreground) &lb.icon_fg else &lb.icon_bg, dest, src);
        } else {
            const tex = self.textureForImage(eng, lb.context, icon.handle) orelse return;
            const batch = self.texBatchFor(&lb.icon_fallback, icon.handle, tex) orelse return;
            addSprite(batch, dest, host_eng.RectF{ .l = icon.src_l, .t = icon.src_t, .r = icon.src_r, .b = icon.src_b });
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
            const cd = atlas.getChar(@intCast(cp)) orelse continue;
            if (cd.size.x > 0 and cd.size.y > 0) {
                const dest = host_eng.RectF.fromPosSize(curr_x + cd.bearing.x, pos_y - cd.bearing.y, cd.size.x, cd.size.y);
                addGlyph(batch, dest, cd.coords, color);
            }
            curr_x += cd.advance;
        }
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

    fn drawLayerBatches(self: *Renderer, eng: *Engine, key: BatchKey) void {
        const lb = self.layer_batches.get(key) orelse return;
        if (!lb.built) return;
        const mvp = eng.projMat;
        // The layer's opacity: already baked into the coloured batches'
        // vertex alpha, and applied to the textured ones here -- they have
        // no colour channel, so the shader's `tint` uniform carries it.
        const a = lb.built_opacity;
        // Back to front: colour fills + tints, image cells, icon
        // backgrounds, foreground/overlay icons, non-atlas icons, text,
        // overlay rects (`create_rect`) last so they sit on top of
        // everything else the layer paints.
        self.drawBatch(&lb.color_bg, mvp);
        for (lb.images.items) |*t| self.drawBatchTinted(&t.batch, mvp, a);
        self.drawBatchTinted(&lb.icon_bg, mvp, a);
        self.drawBatchTinted(&lb.icon_fg, mvp, a);
        for (lb.icon_fallback.items) |*t| self.drawBatchTinted(&t.batch, mvp, a);
        self.drawBatch(&lb.text, mvp);
        // Already-`fade`d per-vertex, same as `lb.text` -- plain, not
        // tinted.
        for (lb.scaled_text.items) |*t| self.drawBatch(&t.batch, mvp);
        self.drawBatch(&lb.rects, mvp);
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
        eng.renderer.clear(0.0, 0.0, 0.0, 1.0);

        {
            const server = self.app.server;
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);

            const sb_t0: ?std.Io.Timestamp = if (self.app.profiler.active()) self.app.profiler.now() else null;
            self.syncBatches(eng);
            if (sb_t0) |s| self.app.profiler.recordSince(.sync_batches, s);

            // One pass per mapped pane. Panes never overlap, so the order
            // between them doesn't matter; the order *within* a pane does,
            // and is unchanged (root layer, caret, then `layer_order`).
            const focused_ctx = server.session.focused_context.load(.monotonic);
            var it = server.session.panes.valueIterator();
            while (it.next()) |pane| {
                if (!pane.mapped) continue;
                const ctx_handle = pane.top();
                const ctx = server.session.contextPtr(ctx_handle) orelse continue;
                self.drawOneContext(eng, ctx_handle, ctx, ctx_handle == focused_ctx);
            }
        }

        // Chrome: its own begin/end so these GL draws sit over every
        // layer, text included. Divider bands, then the window scrollbar.
        // A layer's own scrollbars are not chrome -- they are drawn with
        // the layer (`drawLayerScrollbars`), so a later layer covers them.
        // Bands sit in their own cells between split layers, never inside
        // a viewport, so the bars drawn earlier can't be painted over.
        eng.renderer.begin(eng.projMat);
        self.renderDividers(eng);
        self.renderScrollbar(eng);
        eng.renderer.end();

        // `--screenshot`: everything for this frame is drawn but not yet
        // swapped, so GL_BACK holds exactly what's about to be shown. The
        // HUD is drawn *after* the capture so it never lands in a
        // scripted screenshot.
        if (self.app.screenshot.path) |path| {
            if (!self.app.screenshot.done and self.app.screenshot.elapsed_ms >= self.app.screenshot.delay_ms) {
                self.captureContentArea(eng, path);
                self.app.screenshot.done = true;
            }
        }

        self.drawProfilerHud(eng);
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
    ) void {
        const origin = geometry.contextOrigin(ctx);
        // Pin the root view to the live tail while a full-screen program
        // owns the screen (`rootOwned`).
        const root_view: usize = if (scroll.rootOwned(&ctx.root)) 0 else ctx.root.view_scroll;

        self.drawLayerBatches(eng, .{ .context = ctx_handle, .layer = glyphwire.root_layer_handle });

        // The caret follows `ctx.caret_layer` when a client set one --
        // otherwise the root cursor. Drawn here, on top of root's content
        // and below any popup layer; the pane version is drawn again after
        // its own layer batches below so it sits over that pane's content.
        const focus_caret: ?*const glyphwire.Layer = blk: {
            const h = ctx.caret_layer orelse break :blk null;
            const l = ctx.layers.getPtr(h) orelse break :blk null;
            break :blk if (l.visible) l else null;
        };
        if (focused and ctx.caret_visible and focus_caret == null)
            self.drawRootCaret(eng, &ctx.root, origin.x, origin.y, root_view);
        // IME composition, over both: it covers the cells the caret is
        // about to write into, so it has to sit above the caret too.
        if (focused) self.drawPreedit(eng, &ctx.root, origin.x, origin.y, root_view);

        for (ctx.layer_order.items) |handle| {
            const layer = ctx.layers.getPtr(handle) orelse continue;
            if (!layer.visible) continue;
            self.drawLayerBatches(eng, .{ .context = ctx_handle, .layer = handle });
            // Right after the layer's own content, not in the chrome pass:
            // a popup created later has to cover the bars of whatever it
            // floats over, the same as it covers that layer's cells.
            drawLayerScrollbars(eng, layer, origin);
            if (focused and ctx.caret_visible and focus_caret == layer) self.drawFocusedCaret(eng, layer, origin);
        }
    }

    /// Paints the profiler overlay in the top-right corner while the HUD
    /// is toggled on (Ctrl+Shift+P; only possible when `host.conf.lua` set
    /// `profile`). Immediate-mode like the caret. Lines are formatted
    /// first so the panel can be sized to the widest one (and clamped to
    /// the window) -- monospace, so column count is exact. All numbers
    /// are the profiler's windowed values, not lifetime.
    fn drawProfilerHud(self: *Renderer, eng: *Engine) void {
        if (!self.app.profiler.hud_visible) return;
        const snap = self.app.profiler.snapshot();

        const cap = 2 + glyphwire.profile_max_phases + glyphwire.profile_max_counters;
        var text: [cap][80]u8 = undefined;
        var len: [cap]usize = undefined;
        var head: [cap]bool = undefined;
        var n: usize = 0;

        const put = struct {
            fn f(buf: []u8, comptime fmt: []const u8, args: anytype) usize {
                const s = std.fmt.bufPrint(buf, fmt, args) catch return 0;
                return s.len;
            }
        }.f;

        const mode: []const u8 = if (self.app.profiler.force_redraw) "   [FORCED REDRAW]" else "";
        len[n] = put(&text[n], "PROFILER   fps {d:.1}   skip/s {d:.0}{s}", .{ snap.fps, snap.skips_per_sec, mode });
        head[n] = true;
        n += 1;
        len[n] = put(&text[n], "phase           avg     p95     max", .{});
        head[n] = true;
        n += 1;
        for (snap.phaseSlice()) |ph| {
            len[n] = put(&text[n], "  {s:<12}{d:>7.2} {d:>7.2} {d:>7.2}", .{ ph.name, ph.avg_ms, ph.p95_ms, ph.max_ms });
            head[n] = false;
            n += 1;
        }
        len[n] = put(&text[n], "counter       per frame", .{});
        head[n] = true;
        n += 1;
        for (snap.counterSlice()) |c| {
            len[n] = put(&text[n], "  {s:<14}{d:>9.1}", .{ c.name, c.per_frame });
            head[n] = false;
            n += 1;
        }

        var max_cols: i32 = 0;
        for (len[0..n]) |l| max_cols = @max(max_cols, @as(i32, @intCast(l)));

        const pad: i32 = 6;
        const line_h: i32 = geometry.cell_h;
        const char_w: i32 = geometry.cell_w;
        const fb = eng.window_state.framebuffer_size;
        const panel_w = @min(max_cols * char_w + pad * 2, @max(char_w, fb.x - pad * 2));
        const panel_h = @as(i32, @intCast(n)) * line_h + pad * 2;
        const x0: i32 = @max(pad, fb.x - panel_w - pad);
        const y0: i32 = pad;

        eng.renderer.begin(eng.projMat);
        defer eng.renderer.end();
        eng.renderer.drawFilledRect(host_eng.RectF.fromPosSize(x0, y0, panel_w, panel_h), hud_bg);
        for (0..n) |i| {
            _ = eng.renderer.drawStringColored(
                text[i][0..len[i]],
                .{ .x = x0 + pad, .y = y0 + pad + @as(i32, @intCast(i)) * line_h },
                if (head[i]) hud_head else hud_fg,
            );
        }
    }

    /// The caret for the root layer, drawn immediately (never batched) and
    /// only while visible -- it blinks on its own clock (see `Caret`).
    /// Normally at the live grid cursor; a mouse-driven scroll pins it
    /// (`caret.Caret.pin`) to the buffer cell it was on when the scroll
    /// began, clipping off-screen once that cell leaves the viewport.
    fn drawRootCaret(self: *Renderer, eng: *Engine, root: *const glyphwire.Layer, origin_x: i32, origin_y: i32, view_offset: usize) void {
        if (!self.app.caret.visible()) return;
        const cell = self.app.caret.screenCell(root, view_offset) orelse return;

        eng.renderer.begin(eng.projMat);
        self.drawCaret(eng, root, origin_x, origin_y, cell.row, cell.col, view_offset);
        eng.renderer.end();
    }

    /// The caret for a `caret_layer` pane (see `core.Context.caret_layer`):
    /// `gmux` points it at the focused pane, whose cursor is driven by
    /// that pane's PTY. Positioned through the pane's own bounds
    /// (`layer.pos`, set by the split layout), viewport and scroll
    /// offset -- the same transform `syncOneLayer` uses for the pane's
    /// content. Hidden while the pane has DECTCEM cursor-hide set, while
    /// it is scrolled back into its own history (`view_scroll != 0`), or
    /// while the cursor sits outside the visible viewport. Shares the
    /// blink clock with the root caret.
    fn drawFocusedCaret(self: *Renderer, eng: *Engine, layer: *const glyphwire.Layer, origin: geometry.Origin) void {
        if (!layer.cursor_visible) return;
        if (!self.app.caret.blinkOn()) return;
        if (layer.view_scroll != 0) return;

        const off = layer.scroll_off;
        if (layer.cursor.row < off.row or layer.cursor.col < off.col) return;
        const crow = layer.cursor.row - off.row;
        const ccol = layer.cursor.col - off.col;
        if (crow >= layer.viewportRows() or ccol >= layer.viewportCols()) return;

        const ox = @as(i32, @intFromFloat(@round(layer.pos.x))) + origin.x;
        const oy = @as(i32, @intFromFloat(@round(layer.pos.y))) + origin.y;

        eng.renderer.begin(eng.projMat);
        self.drawCaret(eng, layer, ox, oy, crow, ccol, 0);
        eng.renderer.end();
    }

    /// Paints the IME's in-progress composition over the grid, starting at
    /// the caret cell and running right along the row. Uncommitted text
    /// never reaches the `text` event stream (that only carries what the
    /// IME has committed), so without this the user types Japanese into an
    /// apparently dead terminal and only sees the result on commit.
    ///
    /// Drawn cell-aligned using glyphwire's own East Asian Width rules
    /// rather than the font's advances, so it sits on the same column grid
    /// as the content underneath. Clipped at the row's right edge -- a
    /// composition longer than the remaining columns just stops; it is
    /// transient overlay text, not grid content, and wrapping it would
    /// have to reflow around content it is about to replace anyway.
    ///

    fn drawPreedit(self: *Renderer, eng: *Engine, root: *const glyphwire.Layer, origin_x: i32, origin_y: i32, view_offset: usize) void {

        const text = self.app.preedit.text(eng);
        if (text.len == 0) return;
        const cell = self.app.caret.screenCell(root, view_offset) orelse return;

        const cols_left = root.width - cell.col;
        const span_cols = @min(preedit_mod.Preedit.cellWidth(text), cols_left);
        if (span_cols == 0) return;

        const x0 = origin_x + @as(i32, @intCast(cell.col)) * geometry.cell_w;
        const y0 = origin_y + @as(i32, @intCast(cell.row)) * geometry.cell_h;
        const span_px = @as(i32, @intCast(span_cols)) * geometry.cell_w;

        eng.renderer.begin(eng.projMat);
        defer eng.renderer.end();

        eng.renderer.drawFilledRect(
            host_eng.RectF.fromPosSize(x0, y0, span_px, geometry.cell_h),
            preedit_bg,
        );

        // One `drawStringColored` per codepoint so each lands on its own
        // cell boundary, and so the renderer's `syncAtlasForText` packs
        // any CJK glyph that isn't in the atlas yet before drawing it.
        const cursor_byte = self.app.preedit.cursorByte(eng);
        var cursor_col: ?usize = null;
        var col = cell.col;
        var byte: usize = 0;
        var it = (std.unicode.Utf8View.initUnchecked(text)).iterator();
        while (it.nextCodepointSlice()) |cp_bytes| {
            if (cursor_byte) |cb| {
                if (cursor_col == null and byte >= cb) cursor_col = col;
            }
            const cp = std.unicode.utf8Decode(cp_bytes) catch continue;
            const w: usize = @max(1, glyphwire.codepointWidth(cp));
            if (col + w > root.width) break;
            _ = eng.renderer.drawStringColored(cp_bytes, .{
                .x = origin_x + @as(i32, @intCast(col)) * geometry.cell_w,
                .y = y0,
            }, preedit_fg);
            col += w;
            byte += cp_bytes.len;
        }
        // Cursor at the very end of the composition: the loop never saw a
        // codepoint at or past it, so it lands on the column after the last.
        if (cursor_byte != null and cursor_col == null) cursor_col = col;

        eng.renderer.drawFilledRect(
            host_eng.RectF.fromPosSize(x0, y0 + geometry.cell_h - preedit_underline_px, span_px, preedit_underline_px),
            preedit_fg,
        );

        // The IME's own caret inside the composition -- where the next
        // keystroke lands, which is not necessarily the end (arrow keys
        // move within a composition before it commits).
        if (cursor_col) |cc| {
            if (cc <= root.width) {
                eng.renderer.drawFilledRect(
                    host_eng.RectF.fromPosSize(
                        origin_x + @as(i32, @intCast(cc)) * geometry.cell_w,
                        y0,
                        cursor_width,
                        geometry.cell_h,
                    ),
                    preedit_fg,
                );
            }
        }
    }

    /// Paints the caret for `layer` at grid cell `(crow, ccol)` (already
    /// resolved by the caller). `block`/`box`/`underline` cover the whole
    /// cell -- two cells on the lead of a wide (CJK) character -- while
    /// `line` stays a thin bar at the left edge. Assumes an open renderer
    /// pass.
    fn drawCaret(self: *const Renderer, eng: *Engine, layer: *const glyphwire.Layer, origin_x: i32, origin_y: i32, crow: usize, ccol: usize, view_offset: usize) void {
        const white = host_eng.Color.from(255, 255, 255, 255);
        const cx = origin_x + @as(i32, @intCast(ccol)) * geometry.cell_w;
        const cy = origin_y + @as(i32, @intCast(crow)) * geometry.cell_h;

        const on_wide_lead = layer.viewRow(view_offset, crow)[ccol].wide == .wide_lead;
        const cell_span: i32 = if (on_wide_lead) geometry.cell_w * 2 else geometry.cell_w;

        switch (self.app.caret.shape) {
            .line => eng.renderer.drawFilledRect(
                host_eng.RectF.fromPosSize(cx, cy, cursor_width, geometry.cell_h),
                white,
            ),
            .block => eng.renderer.drawFilledRect(
                host_eng.RectF.fromPosSize(cx, cy, cell_span, geometry.cell_h),
                white,
            ),
            .box => eng.renderer.drawRect(
                host_eng.RectF.fromPosSize(cx, cy, cell_span, geometry.cell_h),
                white,
                cursor_box_line_px,
            ),
            .underline => eng.renderer.drawFilledRect(
                host_eng.RectF.fromPosSize(cx, cy + geometry.cell_h - cursor_underline_px, cell_span, cursor_underline_px),
                white,
            ),
        }
    }

    /// Reads back just the composited grid region -- the left/right
    /// `content_pad_px` margins and the scrollbar excluded -- from the GL
    /// framebuffer and writes it to `path` as a PNG. Best-effort.
    fn captureContentArea(self: *Renderer, eng: *Engine, path: []const u8) void {
        const gl = host_eng.gl;
        const fb = eng.window_state.framebuffer_size;
        const x0: i32 = geometry.content_pad_px;

        var used_rows: usize = geometry.min_grid_rows;
        const gutter: i32 = geometry.rightGutterPx();
        {
            const server = self.app.server;
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            // Cropping to the cursor row keeps a one-line shell session's
            // screenshot from being mostly blank, which is what the README
            // assets want. It only makes sense for a single pane, though:
            // with a pane tree installed, one pane's cursor says nothing
            // about how far down the window has content, so capture the
            // whole grid.
            //
            // The same goes for a full-screen program (zoe, gwmd,
            // salacommander) that has put its own context on screen: the
            // shell's cursor is hidden behind it, so crop nothing.
            if (server.session.root_pane_split != null or self.showsOtherContext()) {
                used_rows = geometry.grid_rows;
            } else {
                used_rows = @max(geometry.min_grid_rows, server.ctx.root.cursor.row + 2);
            }
        }
        const w: i32 = @min(@as(i32, @intCast(geometry.grid_cols)) * geometry.cell_w, fb.x - gutter - 2 * geometry.content_pad_px);
        used_rows = @min(used_rows, geometry.grid_rows);
        const h: i32 = @min(@as(i32, @intCast(used_rows)) * geometry.cell_h, fb.y);
        if (w <= 0 or h <= 0) {
            std.log.warn("glyphwire-host: screenshot region is empty ({d}x{d}), skipping", .{ w, h });
            return;
        }

        const uw: usize = @intCast(w);
        const uh: usize = @intCast(h);
        const row_bytes = uw * 4;

        const pixels = self.app.alloc.alloc(u8, uh * row_bytes) catch |err| {
            std.log.err("glyphwire-host: screenshot buffer alloc failed: {t}", .{err});
            return;
        };
        defer self.app.alloc.free(pixels);

        gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
        // glReadPixels' origin is the framebuffer's bottom-left; read the
        // top `h` rows.
        gl.readPixels(x0, fb.y - h, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);

        // GL returns rows bottom-to-top; flip so the PNG reads top-to-bottom.
        const tmp = self.app.alloc.alloc(u8, row_bytes) catch return;
        defer self.app.alloc.free(tmp);
        var top: usize = 0;
        var bot: usize = uh - 1;
        while (top < bot) : ({
            top += 1;
            bot -= 1;
        }) {
            @memcpy(tmp, pixels[top * row_bytes ..][0..row_bytes]);
            @memcpy(pixels[top * row_bytes ..][0..row_bytes], pixels[bot * row_bytes ..][0..row_bytes]);
            @memcpy(pixels[bot * row_bytes ..][0..row_bytes], tmp);
        }

        const img = host_eng.stbi.Image{
            .data = pixels,
            .width = @intCast(uw),
            .height = @intCast(uh),
            .num_components = 4,
            .bytes_per_component = 1,
            .bytes_per_row = @intCast(row_bytes),
            .is_hdr = false,
        };
        const path_z = std.mem.concatWithSentinel(self.app.alloc, u8, &.{path}, 0) catch return;
        defer self.app.alloc.free(path_z);
        img.writeToFile(path_z, .png) catch |err| {
            std.log.err("glyphwire-host: screenshot write to '{s}' failed: {t}", .{ path, err });
            return;
        };
        std.log.info("glyphwire-host: wrote screenshot {s} ({d}x{d})", .{ path, uw, uh });
    }

    /// Whether some mapped pane has a program's context stacked over its
    /// base (shell) context. `server.ctx` can't answer this: it follows
    /// focus, so it *is* the full-screen program's context by then.
    /// Caller holds `ctx_mutex`.
    fn showsOtherContext(self: *Renderer) bool {
        var it = self.app.server.session.panes.valueIterator();
        while (it.next()) |pane| {
            if (pane.mapped and pane.stack.items.len > 1) return true;
        }
        return false;
    }

    /// The bands between split children, drawn as a flat separator. Their
    /// geometry comes from `App.panes`' cache, which the mouse handler
    /// already refreshes each frame -- see `panes.Panes.syncLocked`.
    fn renderDividers(self: *Renderer, eng: *Engine) void {
        const server = self.app.server;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            self.app.panes.syncLocked();
        }
        for (self.app.panes.bands.items) |d| {
            const r = geometry.cellRectPx(d.rect);
            eng.renderer.drawFilledRect(
                host_eng.RectF{ .l = r.x, .t = r.y, .r = r.x + r.w, .b = r.y + r.h },
                // Pane bands separate whole programs, so they read a shade
                // brighter than the bands inside one program's own layout.
                switch (d.level) {
                    .pane => pane_divider_color,
                    .layer => divider_color,
                },
            );
        }
        // The drag ghost, over the top: the real dividers above are still
        // at their pre-drag positions until the drag ends.
        if (self.app.panes.preview) |p| {
            eng.renderer.drawFilledRect(
                host_eng.RectF{ .l = p.x, .t = p.y, .r = p.x + p.w, .b = p.y + p.h },
                divider_preview_color,
            );
        }
    }

    /// One visible layer's own scrollbars, drawn inside its viewport
    /// bounds -- distinct from `renderScrollbar`, which is the window's
    /// bar for the root layer's scrollback. Opt-in per axis
    /// (`core.PropertyName.scrollbars`) and skipped entirely on an axis
    /// with nothing to scroll, so this is a no-op for every session that
    /// isn't running a TUI. Called from `drawOneContext` straight after
    /// the layer's batches (under `ctx_mutex`), so it composites in layer
    /// order: gw-read's page bars used to show through the OCR dialog
    /// floating over them when this was a final pass over everything.
    fn drawLayerScrollbars(eng: *Engine, layer: *const glyphwire.Layer, origin: geometry.Origin) void {
        const state = layer.scrollbarState();
        if (!state.vertical and !state.horizontal) return;

        const rect = geometry.layerRectIn(origin, layer.pos, layer.viewportCols(), layer.viewportRows());
        const bars = geometry.paneScrollbars(
            rect,
            state,
            layer.viewportCols(),
            layer.viewportRows(),
        );
        if (bars.vertical == null and bars.horizontal == null) return;
        eng.renderer.begin(eng.projMat);
        defer eng.renderer.end();
        if (bars.vertical) |v| drawBar(eng, v);
        if (bars.horizontal) |h| drawBar(eng, h);
    }

    fn drawBar(eng: *Engine, bar: geometry.PaneScrollbarGeom) void {
        eng.renderer.drawFilledRect(
            host_eng.RectF{
                .l = bar.track.x,
                .t = bar.track.y,
                .r = bar.track.x + bar.track.w,
                .b = bar.track.y + bar.track.h,
            },
            pane_track_color,
        );
        eng.renderer.drawFilledRect(
            host_eng.RectF{
                .l = bar.thumb.x + 1,
                .t = bar.thumb.y + 1,
                .r = bar.thumb.x + bar.thumb.w - 1,
                .b = bar.thumb.y + bar.thumb.h - 1,
            },
            pane_thumb_color,
        );
    }

    /// The always-on scrollbar over the right edge: a dark track with a
    /// lighter thumb reflecting the root layer's scrollback and view
    /// offset (`geometry.scrollbarGeom`). Its own render pass (see
    /// `render`) so it composites over every layer; `Scroll.handleScrollbar`
    /// owns the interaction.
    fn renderScrollbar(self: *Renderer, eng: *Engine) void {
        const fb = eng.window_state.framebuffer_size;
        const server = self.app.server;
        var history_len: usize = undefined;
        var height: usize = undefined;
        var view_scroll: usize = undefined;
        var owned: bool = undefined;
        var enabled: bool = undefined;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            history_len = server.ctx.root.history_len;
            height = server.ctx.root.height;
            view_scroll = server.ctx.root.view_scroll;
            owned = scroll.rootOwned(&server.ctx.root);
            enabled = server.ctx.window_scrollbar;
        }
        // A pure-TUI context opts the bar out entirely -- see
        // `core.Context.window_scrollbar`. The reserved gutter stays
        // (grid sizing is session-global, the flag is per-context), it
        // just isn't painted.
        if (!enabled) return;
        if (owned) {
            eng.renderer.drawFilledRect(
                host_eng.RectF.fromPosSize(fb.x - geometry.scrollbar_width_px, 0, geometry.scrollbar_width_px, fb.y),
                host_eng.Color.from(28, 28, 32, 255),
            );
            return;
        }
        const geom = geometry.scrollbarGeom(fb.x, fb.y, history_len, height, view_scroll);

        eng.renderer.drawFilledRect(
            host_eng.RectF.fromPosSize(@as(i32, @intFromFloat(geom.left)), 0, geometry.scrollbar_width_px, fb.y),
            host_eng.Color.from(28, 28, 32, 255),
        );
        eng.renderer.drawFilledRect(
            host_eng.RectF{
                .l = geom.left + 2,
                .t = geom.thumb_top,
                .r = geom.left + @as(f32, @floatFromInt(geometry.scrollbar_width_px)) - 2,
                .b = geom.thumb_top + geom.thumb_h,
            },
            host_eng.Color.from(120, 120, 130, 255),
        );
    }
};
