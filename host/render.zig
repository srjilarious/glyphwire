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

/// The cached quad batches for one layer, plus the state its last build
/// was keyed on. `syncOneLayer` rebuilds when any of the keyed values
/// differ from the layer's current ones.
pub const LayerBatches = struct {
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

    color_bg: ShapeBatch,
    icon_bg: SpriteBatch,
    icon_fg: SpriteBatch,
    text: GlyphBatch,
    images: std.ArrayList(TexBatch) = .empty,
    icon_fallback: std.ArrayList(TexBatch) = .empty,

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
        const text = try GlyphBatch.init(alloc, glyph_shader);
        return .{ .color_bg = color_bg, .icon_bg = icon_bg, .icon_fg = icon_fg, .text = text };
    }

    fn deinit(self: *LayerBatches, alloc: std.mem.Allocator) void {
        self.color_bg.deinit();
        self.icon_bg.deinit();
        self.icon_fg.deinit();
        self.text.deinit();
        for (self.images.items) |*t| t.batch.deinit();
        self.images.deinit(alloc);
        for (self.icon_fallback.items) |*t| t.batch.deinit();
        self.icon_fallback.deinit(alloc);
    }
};

/// Positions/texcoords for one quad in the engine's winding order (corner 0 =
/// (l,b), 1 = (l,t), 2 = (r,t), 3 = (r,b)) -- the same order `addQuad`
/// and `TextRenderer.drawStringColored` use.
fn quad4(l: f32, t: f32, r: f32, b: f32) [4][2]f32 {
    return .{ .{ l, b }, .{ l, t }, .{ r, t }, .{ r, b } };
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

/// The divider band between two split children. Deliberately lighter than
/// the window scrollbar's track: a divider reads as a seam between panes,
/// not as chrome hanging off the edge of the window.
const divider_color = host_eng.Color.from(58, 58, 66, 255);

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
    /// Stores the `*ManagedTexture` pool, not a `Texture` value:
    /// `ManagedTexture`'s heap-allocated `Handle` stays at a stable
    /// address for its full lifetime, so `&managed.get().?.val` stays
    /// valid across the frames a `StaticQuadBatch` holds it.
    image_textures: std.AutoHashMap(glyphwire.ImageHandle, *host_eng.ManagedTexture),
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

    /// One `LayerBatches` per live layer, keyed by handle
    /// (`glyphwire.root_layer_handle` for the root). Created on first
    /// sight, rebuilt on change, freed when the layer is destroyed (see
    /// `syncBatches`) or in `deinit`.
    layer_batches: std.AutoHashMapUnmanaged(glyphwire.LayerHandle, *LayerBatches) = .empty,
    /// The three `ManagedShader`s the batches bind, fetched once on the
    /// first `syncBatches` (the window / GL context is up by then).
    shape_shader: ?*host_eng.ManagedShader = null,
    sprite_shader: ?*host_eng.ManagedShader = null,
    glyph_shader: ?*host_eng.ManagedShader = null,
    /// Bumped whenever a text rebuild grew the glyph atlas (every glyph's
    /// UV moved). Each `LayerBatches` records the epoch it built at; a
    /// mismatch forces a rebuild of that layer's text.
    text_epoch: u64 = 0,

    pub fn deinit(self: *Renderer) void {
        const alloc = self.app.alloc;
        self.deferred_icons.deinit(alloc);
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
            var it = self.app.server.ctx.icons.valueIterator();
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
            const entry = self.app.server.ctx.images.get(handle) orelse continue;
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

    /// Returns a stable pointer to the uploaded texture for `handle`,
    /// decoding and uploading it first if this is the first time this App
    /// has seen it -- see `image_textures`'s doc comment.
    fn textureForImage(self: *Renderer, eng: *Engine, handle: glyphwire.ImageHandle) ?*host_eng.Texture {
        const managed = self.image_textures.get(handle) orelse blk: {
            const entry = self.app.server.ctx.images.get(handle) orelse return null;
            var image = host_eng.stbi.Image.loadFromMemory(entry.bytes, 4) catch |err| {
                std.log.err("glyphwire-host: failed to decode image handle {d}: {t}", .{ handle, err });
                return null;
            };
            defer image.deinit();

            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "glyphwire-image-{d}", .{handle}) catch unreachable;
            const managed = eng.resources.loadTextureFromBuffer(name, image.width, image.height, image.data) catch |err| {
                std.log.err("glyphwire-host: failed to upload image handle {d}: {t}", .{ handle, err });
                return null;
            };
            self.image_textures.put(handle, managed) catch {};
            break :blk managed;
        };

        const live = managed.get() orelse {
            std.log.warn("glyphwire-host: image handle {d} has no live generation", .{handle});
            return null;
        };
        return &live.val;
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

        // Reap batches whose layer no longer exists.
        {
            var stale: [16]glyphwire.LayerHandle = undefined;
            var n: usize = 0;
            var it = self.layer_batches.keyIterator();
            while (it.next()) |k| {
                if (k.* == glyphwire.root_layer_handle) continue;
                if (server.ctx.layers.get(k.*) == null and n < stale.len) {
                    stale[n] = k.*;
                    n += 1;
                }
            }
            for (stale[0..n]) |h| {
                if (self.layer_batches.fetchRemove(h)) |kv| {
                    kv.value.deinit(self.app.alloc);
                    self.app.alloc.destroy(kv.value);
                }
            }
        }

        var pass: usize = 0;
        while (pass < 6) : (pass += 1) {
            const epoch_before = self.text_epoch;

            const root_view: usize = if (scroll.rootOwned(&server.ctx.root)) 0 else server.ctx.root.view_scroll;
            self.syncOneLayer(eng, fa, glyphwire.root_layer_handle, &server.ctx.root, geometry.content_pad_px, 0, root_view);

            for (server.ctx.layer_order.items) |handle| {
                const layer = server.ctx.layers.getPtr(handle) orelse continue;
                // A hidden layer keeps its cached batch (it is not stale,
                // just unseen), so showing it again costs no rebuild.
                if (!layer.visible) continue;
                const ox = @as(i32, @intFromFloat(@round(layer.pos.x))) + geometry.content_pad_px;
                const oy: i32 = @intFromFloat(@round(layer.pos.y));
                self.syncOneLayer(eng, fa, handle, layer, ox, oy, 0);
            }

            if (self.text_epoch == epoch_before) break;
        }
    }

    fn syncOneLayer(
        self: *Renderer,
        eng: *Engine,
        fa: ?*host_eng.renderer.FontAtlas,
        handle: glyphwire.LayerHandle,
        layer: *const glyphwire.Layer,
        origin_x: i32,
        origin_y: i32,
        view_offset: usize,
    ) void {
        const alloc = self.app.alloc;
        const gop = self.layer_batches.getOrPut(alloc, handle) catch return;
        if (!gop.found_existing) {
            const lb = alloc.create(LayerBatches) catch {
                _ = self.layer_batches.remove(handle);
                return;
            };
            lb.* = LayerBatches.init(alloc, self.shape_shader.?, self.sprite_shader.?, self.glyph_shader.?) catch {
                alloc.destroy(lb);
                _ = self.layer_batches.remove(handle);
                return;
            };
            gop.value_ptr.* = lb;
        }
        const lb = gop.value_ptr.*;

        const gen = layer.renderGeneration();
        const need = !lb.built or
            lb.built_gen != gen or
            lb.built_view_offset != view_offset or
            lb.built_cell_w != geometry.cell_w or
            lb.built_cell_h != geometry.cell_h or
            lb.built_text_epoch != self.text_epoch;
        if (!need) return;

        self.rebuildLayer(eng, fa, lb, layer, origin_x, origin_y, view_offset);
        lb.built = true;
        lb.built_gen = gen;
        lb.built_view_offset = view_offset;
        lb.built_cell_w = geometry.cell_w;
        lb.built_cell_h = geometry.cell_h;
        lb.built_text_epoch = self.text_epoch;
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
    ) void {
        // Per-texture batch lists are rebuilt from scratch (a layer rarely
        // has more than one image / non-atlas icon; this only runs on an
        // actual change).
        for (lb.images.items) |*t| t.batch.deinit();
        lb.images.clearRetainingCapacity();
        for (lb.icon_fallback.items) |*t| t.batch.deinit();
        lb.icon_fallback.clearRetainingCapacity();

        lb.color_bg.beginBuild({});

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
                    if (g.len > 0) f.loadBlocksForText(g);
                }
            }
            const grew = f.grew_since_upload;
            f.commitTexture();
            if (grew) self.text_epoch +%= 1;
        }

        self.deferred_icons.clearRetainingCapacity();
        const any_highlight = layer.highlighted_ids.items.len > 0;

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
                        if (bg.r != 0 or bg.g != 0 or bg.b != 0) {
                            addRect(
                                &lb.color_bg,
                                host_eng.RectF.fromPosSize(px, py, geometry.cell_w, geometry.cell_h),
                                host_eng.Color.from(bg.r, bg.g, bg.b, bg.a),
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
                        selection.selection_highlight_color,
                    );
                }

                if (fa) |f| {
                    const g = c.grapheme();
                    if (g.len > 0) {
                        emitGlyphs(&lb.text, f, g, px, py, host_eng.Color.from(c.style.fg.r, c.style.fg.g, c.style.fg.b, c.style.fg.a));
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
                    selection.selection_highlight_color,
                );
            }
        }

        lb.color_bg.endBuild();
        if (has_icon_atlas) {
            lb.icon_bg.endBuild();
            lb.icon_fg.endBuild();
        }
        if (fa_tex != null) lb.text.endBuild();
        for (lb.images.items) |*t| t.batch.endBuild();
        for (lb.icon_fallback.items) |*t| t.batch.endBuild();
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

    /// One cell's portion of an image background -- the sub-rect of the
    /// source texture starting at `img.offset_x/y`, sized to whatever fits
    /// both the cell and the image's remaining pixels, never stretched
    /// (decisions.md's Image section). Emitted into that image handle's
    /// own `images` batch.
    fn emitImageCell(self: *Renderer, eng: *Engine, lb: *LayerBatches, img: glyphwire.ImageBg, px: i32, py: i32) void {
        const entry = self.app.server.ctx.images.get(img.handle) orelse return;
        if (img.offset_x >= entry.width or img.offset_y >= entry.height) return;

        const tex = self.textureForImage(eng, img.handle) orelse return;

        const avail_w: i32 = @min(geometry.cell_w, @as(i32, @intCast(entry.width - img.offset_x)));
        const avail_h: i32 = @min(geometry.cell_h, @as(i32, @intCast(entry.height - img.offset_y)));
        if (avail_w <= 0 or avail_h <= 0) return;

        const img_w_f: f32 = @floatFromInt(entry.width);
        const img_h_f: f32 = @floatFromInt(entry.height);
        const src = host_eng.RectF{
            .l = @as(f32, @floatFromInt(img.offset_x)) / img_w_f,
            .t = @as(f32, @floatFromInt(img.offset_y)) / img_h_f,
            .r = @as(f32, @floatFromInt(img.offset_x + @as(u32, @intCast(avail_w)))) / img_w_f,
            .b = @as(f32, @floatFromInt(img.offset_y + @as(u32, @intCast(avail_h)))) / img_h_f,
        };

        const batch = self.texBatchFor(&lb.images, img.handle, tex) orelse return;
        addSprite(batch, host_eng.RectF.fromPosSize(px, py, avail_w, avail_h), src);
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
        const entry = self.app.server.ctx.images.get(icon.handle) orelse return;
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
            const tex = self.textureForImage(eng, icon.handle) orelse return;
            const batch = self.texBatchFor(&lb.icon_fallback, icon.handle, tex) orelse return;
            addSprite(batch, dest, host_eng.RectF{ .l = icon.src_l, .t = icon.src_t, .r = icon.src_r, .b = icon.src_b });
        }
    }

    /// Emits `text`'s glyph quads starting at cell top-left `(px, py)`,
    /// mirroring `host_eng.renderer.TextRenderer.drawStringColored`: baseline
    /// at `py + atlas.ascent`, each glyph placed by its bearing and
    /// advanced by its `advance`, UVs straight from the atlas.
    fn emitGlyphs(batch: *GlyphBatch, fa: *host_eng.renderer.FontAtlas, text: []const u8, px: i32, py: i32, color: host_eng.Color) void {
        const pos_y = py + fa.ascent;
        var curr_x = px;
        var it = (std.unicode.Utf8View.initUnchecked(text)).iterator();
        while (it.nextCodepoint()) |cp| {
            const cd = fa.getChar(@intCast(cp)) orelse continue;
            if (cd.size.x > 0 and cd.size.y > 0) {
                const dest = host_eng.RectF.fromPosSize(curr_x + cd.bearing.x, pos_y - cd.bearing.y, cd.size.x, cd.size.y);
                addGlyph(batch, dest, cd.coords, color);
            }
            curr_x += cd.advance;
        }
    }

    fn drawLayerBatches(self: *Renderer, eng: *Engine, handle: glyphwire.LayerHandle) void {
        const lb = self.layer_batches.get(handle) orelse return;
        if (!lb.built) return;
        const mvp = eng.projMat;
        // Back to front: colour fills + tints, image cells, icon
        // backgrounds, foreground/overlay icons, non-atlas icons, text.
        if (!lb.color_bg.isEmpty()) lb.color_bg.draw(mvp);
        for (lb.images.items) |*t| {
            if (!t.batch.isEmpty()) t.batch.draw(mvp);
        }
        if (!lb.icon_bg.isEmpty()) lb.icon_bg.draw(mvp);
        if (!lb.icon_fg.isEmpty()) lb.icon_fg.draw(mvp);
        for (lb.icon_fallback.items) |*t| {
            if (!t.batch.isEmpty()) t.batch.draw(mvp);
        }
        if (!lb.text.isEmpty()) lb.text.draw(mvp);
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

            self.syncBatches(eng);

            // Pin the root view to the live tail while a full-screen
            // program owns the screen (`rootOwned`).
            const root_view: usize = if (scroll.rootOwned(&server.ctx.root)) 0 else server.ctx.root.view_scroll;

            self.drawLayerBatches(eng, glyphwire.root_layer_handle);
            // Root caret: on top of root's content, below any popup layer
            // -- matches the old per-layer caret draw order.
            self.drawRootCaret(eng, &server.ctx.root, geometry.content_pad_px, 0, root_view);
            // IME composition, over both: it covers the cells the caret is
            // about to write into, so it has to sit above the caret too.
            self.drawPreedit(eng, &server.ctx.root, geometry.content_pad_px, 0, root_view);

            for (server.ctx.layer_order.items) |handle| {
                const layer = server.ctx.layers.getPtr(handle) orelse continue;
                if (!layer.visible) continue;
                self.drawLayerBatches(eng, handle);
            }
        }

        // Chrome: its own begin/end so these GL draws sit over every
        // layer, text included. Divider bands first, then the panes' own
        // scrollbars (which sit inside a pane and so must not be painted
        // over by its neighbour's divider), then the window scrollbar.
        eng.renderer.begin(eng.projMat);
        self.renderDividers(eng);
        self.renderPaneScrollbars(eng);
        self.renderScrollbar(eng);
        eng.renderer.end();

        // `--screenshot`: everything for this frame is drawn but not yet
        // swapped, so GL_BACK holds exactly what's about to be shown.
        if (self.app.screenshot.path) |path| {
            if (!self.app.screenshot.done and self.app.screenshot.elapsed_ms >= self.app.screenshot.delay_ms) {
                self.captureContentArea(eng, path);
                self.app.screenshot.done = true;
            }
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
        const w: i32 = @min(@as(i32, @intCast(geometry.grid_cols)) * geometry.cell_w, fb.x - geometry.scrollbar_width_px - 2 * geometry.content_pad_px);

        var used_rows: usize = geometry.min_grid_rows;
        {
            const server = self.app.server;
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            used_rows = @max(geometry.min_grid_rows, server.ctx.root.cursor.row + 2);
        }
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
        const path_z = self.app.alloc.dupeZ(u8, path) catch return;
        defer self.app.alloc.free(path_z);
        img.writeToFile(path_z, .png) catch |err| {
            std.log.err("glyphwire-host: screenshot write to '{s}' failed: {t}", .{ path, err });
            return;
        };
        std.log.info("glyphwire-host: wrote screenshot {s} ({d}x{d})", .{ path, uw, uh });
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
        for (self.app.panes.dividers.items) |d| {
            const r = geometry.cellRectPx(d.rect);
            eng.renderer.drawFilledRect(
                host_eng.RectF{ .l = r.x, .t = r.y, .r = r.x + r.w, .b = r.y + r.h },
                divider_color,
            );
        }
    }

    /// Each visible layer's own scrollbars, drawn inside its viewport
    /// bounds -- distinct from `renderScrollbar`, which is the window's
    /// bar for the root layer's scrollback. Opt-in per axis
    /// (`core.PropertyName.scrollbars`) and skipped entirely on an axis
    /// with nothing to scroll, so this is a no-op for every session that
    /// isn't running a TUI.
    fn renderPaneScrollbars(self: *Renderer, eng: *Engine) void {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        for (server.ctx.layer_order.items) |handle| {
            const layer = server.ctx.layers.getPtr(handle) orelse continue;
            if (!layer.visible) continue;
            const state = layer.scrollbarState();
            if (!state.vertical and !state.horizontal) continue;

            const rect = geometry.layerRect(layer.pos, layer.viewportCols(), layer.viewportRows());
            const bars = geometry.paneScrollbars(
                rect,
                state,
                layer.viewportCols(),
                layer.viewportRows(),
                layer.width,
                layer.height,
            );
            if (bars.vertical) |v| drawBar(eng, v);
            if (bars.horizontal) |h| drawBar(eng, h);
        }
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
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            history_len = server.ctx.root.history_len;
            height = server.ctx.root.height;
            view_scroll = server.ctx.root.view_scroll;
            owned = scroll.rootOwned(&server.ctx.root);
        }
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
