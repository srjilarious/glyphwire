const std = @import("std");
const glyphwire = @import("glyphwire");
const pixzig = @import("pixzig");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const scroll = @import("scroll.zig");
const selection = @import("selection.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

// Width in px of the `.line` caret, and thickness in px of the
// `.underline` bar and the `.box` outline.
const cursor_width = 2;
const cursor_underline_px = 2;
const cursor_box_line_px = 2;

/// One `.natural`-scale icon whose draw is deferred past the rest of
/// `renderLayer`'s grid -- see `drawIconCell`'s doc comment. `foreground`
/// is carried through to `drawIconCell` so a deferred `Cell.fg_icon` still
/// lands in the overlay batch (on top of row backgrounds), not the plain
/// sprite batch.
pub const DeferredIcon = struct {
    icon: glyphwire.IconBg,
    pos: pixzig.Vec2I,
    foreground: bool,
};

/// Which category of a cell's contents one `renderLayer` pass draws.
/// The passes run in this declared order, each inside its own flushed
/// `begin`/`end` -- see `renderLayer`.
const Pass = enum { color_bg, image_bg, icons, text };

/// All of the host's drawing: layer compositing, the icon atlas, image /
/// icon cells, the caret, the scrollbar, and the `--screenshot` readback.
/// Owns the GPU-texture caches; every method assumes it runs on the main
/// (render) thread.
pub const Renderer = struct {
    app: *App,

    /// Uploaded lazily, on first encountering a cell whose background
    /// references a given image handle -- see decisions.md's Image
    /// section ("the renderer... decodes when it first encounters a
    /// `.image` background it hasn't uploaded yet"). The headless core
    /// never decodes pixels; it only stores the raw bytes `load_image`
    /// received (`Context.images`) plus IHDR-parsed dimensions.
    ///
    /// Stores the `*ManagedTexture` pool, not a `Texture` value: the
    /// sprite batch (`eng.renderer.draw`) stores the `*const Texture`
    /// pointer it's given and only dereferences it later, at `flush()`/
    /// `end()` -- not immediately. A pointer to a local stack copy (this
    /// used to cache `pixzig.Texture` by value and pass `&tex`) goes
    /// dangling the moment the drawing function returns, so the batch
    /// reads stack garbage once it actually flushes. `ManagedTexture`'s
    /// heap-allocated `Handle` is documented as staying at a stable
    /// address for its full lifetime, so `&managed.get().?.val` stays
    /// valid through the whole frame.
    image_textures: std.AutoHashMap(glyphwire.ImageHandle, *pixzig.ManagedTexture),
    /// Every bundled icon (`Context.icons`, seeded from the `assets/icons/`
    /// scan -- see `icons.loadIconsFromDir`) decoded once at startup and
    /// packed into a single texture, so a screen full of icons -- a
    /// `draw_box` border, an `ls` icon grid, a powerline prompt -- draws
    /// from one bound texture instead of rebinding per icon. Null only if
    /// `buildIconAtlas` failed (each `draw_icon` then falls back to a
    /// per-handle `image_textures` upload). `icon_uv` maps an icon's image
    /// handle to its normalized sub-rect inside `icon_atlas`;
    /// `load_image` handles (user images, `glyphwire-view`) are never in
    /// here and keep their own `image_textures` entry.
    icon_atlas: ?*pixzig.ManagedTexture = null,
    icon_uv: std.AutoHashMap(glyphwire.ImageHandle, pixzig.RectF),
    /// Scratch buffer for the `.natural`-icon overflow handled at the end
    /// of `renderLayer`'s icons pass -- see `DeferredIcon`. Cleared (not
    /// freed) at the start of that pass and reused across frames/layers.
    deferred_icons: std.ArrayList(DeferredIcon) = .empty,

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
            image: pixzig.stbi.Image,
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
            var image = pixzig.stbi.Image.loadFromMemory(entry.bytes, 4) catch |err| {
                std.log.warn("glyphwire-host: icon handle {d} failed to decode for the atlas: {t}", .{ handle, err });
                continue;
            };
            // An icon that can't fit the sheet at all skips the atlas and
            // takes `drawIconCell`'s per-handle fallback instead. The
            // bundled art is 32x32, so this only guards against an
            // oversized file dropped into `assets/icons/` later.
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
    /// has seen it -- see `image_textures`'s doc comment. Null if `handle`
    /// isn't in `ctx.images` (shouldn't happen: `draw_image` already
    /// validated the handle before marking a cell with it), decoding the
    /// stored bytes fails, or (defensively) the managed pool somehow has
    /// no live generation right after we just added one.
    fn textureForImage(self: *Renderer, eng: *Engine, handle: glyphwire.ImageHandle) ?*pixzig.Texture {
        const managed = self.image_textures.get(handle) orelse blk: {
            const entry = self.app.server.ctx.images.get(handle) orelse return null;
            var image = pixzig.stbi.Image.loadFromMemory(entry.bytes, 4) catch |err| {
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

    /// Draws one cell's portion of an image background: the sub-rect of
    /// the source texture starting at `img.offset_x/y`, sized to whatever
    /// actually fits both the cell and the image's remaining pixels --
    /// never stretched, and clipped rather than overflowing into a
    /// neighboring cell when the image's edge falls mid-cell (decisions.md's
    /// Image section). `img.offset_x/y` are always inside the image's
    /// bounds -- `Layer.drawImage` only marks a cell at all when that
    /// holds -- but this re-checks defensively rather than trusting that
    /// invariant blindly at render time.
    fn drawImageCell(self: *Renderer, eng: *Engine, img: glyphwire.ImageBg, pos: pixzig.Vec2I) void {
        const entry = self.app.server.ctx.images.get(img.handle) orelse return;
        if (img.offset_x >= entry.width or img.offset_y >= entry.height) return;

        const tex = self.textureForImage(eng, img.handle) orelse return;

        const avail_w: i32 = @min(geometry.cell_w, @as(i32, @intCast(entry.width - img.offset_x)));
        const avail_h: i32 = @min(geometry.cell_h, @as(i32, @intCast(entry.height - img.offset_y)));
        if (avail_w <= 0 or avail_h <= 0) return;

        const img_w_f: f32 = @floatFromInt(entry.width);
        const img_h_f: f32 = @floatFromInt(entry.height);
        const uv_l = @as(f32, @floatFromInt(img.offset_x)) / img_w_f;
        const uv_t = @as(f32, @floatFromInt(img.offset_y)) / img_h_f;
        const uv_r = @as(f32, @floatFromInt(img.offset_x + @as(u32, @intCast(avail_w)))) / img_w_f;
        const uv_b = @as(f32, @floatFromInt(img.offset_y + @as(u32, @intCast(avail_h)))) / img_h_f;

        eng.renderer.draw(
            tex,
            pixzig.RectF.fromPosSize(pos.x, pos.y, avail_w, avail_h),
            pixzig.RectF{ .l = uv_l, .t = uv_t, .r = uv_r, .b = uv_b },
        );
    }

    /// Draws an icon anchored at `pos` (its cell's top-left corner):
    /// `icon.scale == .fit` shows the *whole* source image, scaled
    /// uniformly (never stretched non-uniformly) to fit within the cell
    /// -- the original, still-default behavior, per decisions.md's Icon
    /// section, deliberately different from `drawImageCell`'s clip-not-
    /// stretch rule. `.natural` instead draws it at its own native pixel
    /// size (shrunk, aspect preserved, if it exceeds `icon.max_w`/
    /// `icon.max_h`), which may still be bigger than the cell -- see
    /// `glyphwire.IconBg`'s doc comment on why that overflow is a pure
    /// rendering effect with no data-model footprint on whatever cells it
    /// visually spills into (this function draws into exactly the rect
    /// it's given; the caller -- `renderLayer` -- decides whether that
    /// means drawing immediately in grid order, for `.fit`/`.stretch`,
    /// which never overflow, or deferring past the rest of the grid so the
    /// overflow paints over already-drawn neighbors, for `.natural`).
    /// `.stretch` fills the cell exactly on both axes (see `IconScale`'s
    /// doc comment) -- `icon.h_align`/`icon.v_align` are no-ops for it
    /// (there's no leftover space to align within), but still apply to
    /// `.fit`/`.natural` to place the (possibly smaller, possibly bigger)
    /// result within the cell's bounds.
    ///
    /// `foreground` picks the batch this icon's quad goes into. Both cases
    /// draw in `renderLayer`'s single icons pass, which is fully flushed
    /// after the color- and image-background passes and before the text
    /// pass (see `renderLayer`'s comment), so an icon is never hidden by a
    /// row background and never hides a glyph. Within that one pass,
    /// though, pixzig still submits the plain sprite batch before the
    /// overlay batch, so `foreground == true` (every `Cell.fg_icon`, per
    /// that field's doc comment) lands on top of a `foreground == false`
    /// `style.bg` `.icon` drawn into the same cell; the `.icon` background
    /// otherwise replaces that cell's fill outright (no rect is drawn for
    /// it), so it has nothing of its own to sit above.
    fn drawIconCell(self: *Renderer, eng: *Engine, icon: glyphwire.IconBg, pos: pixzig.Vec2I, foreground: bool) void {
        const entry = self.app.server.ctx.images.get(icon.handle) orelse return;
        if (entry.width == 0 or entry.height == 0) return;

        // Prefer the shared icon atlas: `atlas_uv` is this icon's
        // sub-rect in it (null for a handle the atlas didn't get -- a
        // decode failure, or a `load_image` handle passed to `draw_icon`,
        // which then uses its own per-handle texture). Drawing every icon
        // from one bound texture is the whole point (see `icon_atlas`).
        var tex: *pixzig.Texture = undefined;
        var atlas_uv: ?pixzig.RectF = null;
        if (self.icon_atlas) |atlas| {
            if (self.icon_uv.get(icon.handle)) |uv| {
                const live = atlas.get() orelse return;
                tex = &live.val;
                atlas_uv = uv;
            }
        }
        if (atlas_uv == null) {
            tex = self.textureForImage(eng, icon.handle) orelse return;
        }

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

        const pos_x_f: f32 = @floatFromInt(pos.x);
        const pos_y_f: f32 = @floatFromInt(pos.y);
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

        const dest = pixzig.RectF{ .l = dest_x, .t = dest_y, .r = dest_x + dest_w, .b = dest_y + dest_h };
        // `icon.src_*` is a fraction of the icon (always 0..1 for a plain
        // `draw_icon`, a sub-rect only for a box tile). Map it through the
        // atlas sub-rect when drawing from the atlas; use it directly on a
        // fallback per-handle texture.
        const src = if (atlas_uv) |a| pixzig.RectF{
            .l = a.l + icon.src_l * (a.r - a.l),
            .t = a.t + icon.src_t * (a.b - a.t),
            .r = a.l + icon.src_r * (a.r - a.l),
            .b = a.t + icon.src_b * (a.b - a.t),
        } else pixzig.RectF{ .l = icon.src_l, .t = icon.src_t, .r = icon.src_r, .b = icon.src_b };
        if (foreground) {
            eng.renderer.drawOverlayTexture(tex, dest, src);
        } else {
            eng.renderer.draw(tex, dest, src);
        }
    }

    /// Draws `icon` at `pos` now, or -- when `icon.scale == .natural`,
    /// which can overflow past the cell into cells not yet reached --
    /// defers it onto `deferred_icons` for `renderLayer` to draw after the
    /// grid. `.fit`/`.stretch` never overflow, so they draw in place.
    fn queueOrDrawIcon(self: *Renderer, eng: *Engine, icon: glyphwire.IconBg, pos: pixzig.Vec2I, foreground: bool) void {
        if (icon.scale == .natural) {
            self.deferred_icons.append(self.app.alloc, .{ .icon = icon, .pos = pos, .foreground = foreground }) catch {};
        } else {
            self.drawIconCell(eng, icon, pos, foreground);
        }
    }

    /// Reads every layer's cells straight out of the in-process `Context`
    /// -- no `get_property`/`get_cells` round trip, and nothing to
    /// skip-if-unchanged: a direct read is cheap enough to just do every
    /// frame. `ctx_mutex` is the same lock `Server` takes around dispatch
    /// for connected clients (e.g. glyphwire-shell's `write_text` calls),
    /// so this can't race a concurrent write.
    ///
    /// Composites the root layer first, then every `create_layer`-made
    /// layer in `ctx.layer_order` (creation order -- a later-created
    /// layer draws on top of an earlier one and of root, see that field's
    /// doc comment), each offset by its own `pos`. Only the root layer's
    /// cursor gets a caret: root is the layer keystrokes actually land on
    /// (glyphwire-shell's prompt), where a notification-style layer's own
    /// `cursor` is just bookkeeping `write_text` needs to know where to
    /// place its next character, not something a user is looking at.
    ///
    /// Each layer is drawn in full (all of `renderLayer`'s passes) before
    /// the next one starts, so a popup with an opaque background still
    /// fully covers the layer beneath it. The scrollbar is a final pass on
    /// top of every layer.
    pub fn render(self: *Renderer, eng: *Engine) void {
        eng.renderer.clear(0.0, 0.0, 0.0, 1.0);

        {
            const server = self.app.server;
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);

            // Pin the root view to the live tail while a full-screen
            // program owns the screen (`rootOwned`): `less -X` / `bat` /
            // git's pager draw on the primary screen, so a stale
            // `view_scroll` would show old scrollback through their
            // display and make their status line appear to crawl.
            const root_view: usize = if (scroll.rootOwned(&server.ctx.root)) 0 else server.ctx.root.view_scroll;
            self.renderLayer(eng, &server.ctx.root, geometry.content_pad_px, 0, true, root_view);
            for (server.ctx.layer_order.items) |handle| {
                const layer = server.ctx.layers.getPtr(handle) orelse continue;
                self.renderLayer(
                    eng,
                    layer,
                    @as(i32, @intFromFloat(@round(layer.pos.x))) + geometry.content_pad_px,
                    @intFromFloat(@round(layer.pos.y)),
                    false,
                    0,
                );
            }
        }

        // Scrollbar: its own begin/end, after every layer's passes have
        // flushed, so its GL draws sit over everything -- text and all
        // layers included.
        eng.renderer.begin(eng.projMat);
        self.renderScrollbar(eng);
        eng.renderer.end();

        // `--screenshot`: everything for this frame is drawn and flushed
        // but the buffers haven't been swapped yet, so GL_BACK holds
        // exactly what's about to be shown -- the right moment to read it
        // back. `update` quits the next frame.
        if (self.app.screenshot.path) |path| {
            if (!self.app.screenshot.done and self.app.screenshot.elapsed_ms >= self.app.screenshot.delay_ms) {
                self.captureContentArea(eng, path);
                self.app.screenshot.done = true;
            }
        }
    }

    /// Reads back just the composited grid region -- the left/right
    /// `content_pad_px` margins and the scrollbar excluded -- straight
    /// from the GL framebuffer and writes it to `path` as a PNG. Called
    /// from the end of `render` (see there) once `--screenshot`'s delay
    /// has elapsed. Best-effort: any failure is logged and the host
    /// carries on, still quitting the next frame so an automated capture
    /// run always terminates.
    fn captureContentArea(self: *Renderer, eng: *Engine, path: []const u8) void {
        const gl = pixzig.gl;
        const fb = eng.window_state.framebuffer_size;
        // The grid starts one margin in from the left; it fills the full
        // window height. Clamp to the live framebuffer in case a resize
        // made it smaller than the initial `grid_cols * cell_w`.
        const x0: i32 = geometry.content_pad_px;
        const w: i32 = @min(@as(i32, @intCast(geometry.grid_cols)) * geometry.cell_w, fb.x - geometry.scrollbar_width_px - 2 * geometry.content_pad_px);

        // Crop the height to the rows actually written (root cursor row
        // plus one trailing blank line), so a mostly-empty grid doesn't
        // produce a screenshot that's mostly black. Floored so a very
        // short result still has some breathing room.
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
        // glReadPixels' origin is the framebuffer's bottom-left, but the
        // grid is drawn from the top down, so read the *top* `h` rows:
        // start `h` pixels up from the bottom.
        gl.readPixels(x0, fb.y - h, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);

        // GL returns rows bottom-to-top; flip so the PNG reads top-to-bottom
        // (same swap `pixzig`'s own `captureScreenshot` does).
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

        const img = pixzig.stbi.Image{
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

    /// Draws the always-on scrollbar over the right edge: a dark track the
    /// full window height with a lighter thumb whose size and position
    /// reflect the root layer's scrollback (`history_len`) and current
    /// view offset (`view_scroll`) -- see `geometry.scrollbarGeom`. Called
    /// in its own render pass (see `render`) so it composites over every
    /// layer, text included; `scroll.Scroll.handleScrollbar` owns the
    /// interaction. Takes its own short `ctx_mutex` snapshot rather than
    /// relying on `render`'s lock, which is released by the time this
    /// second pass runs.
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
        // While a full-screen program owns the screen there's no
        // scrollback to indicate -- draw just the inert track gutter so
        // the content width doesn't jump, no thumb.
        if (owned) {
            eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(fb.x - geometry.scrollbar_width_px, 0, geometry.scrollbar_width_px, fb.y),
                pixzig.Color.from(28, 28, 32, 255),
            );
            return;
        }
        const geom = geometry.scrollbarGeom(fb.x, fb.y, history_len, height, view_scroll);

        eng.renderer.drawFilledRect(
            pixzig.RectF.fromPosSize(@as(i32, @intFromFloat(geom.left)), 0, geometry.scrollbar_width_px, fb.y),
            pixzig.Color.from(28, 28, 32, 255),
        );
        eng.renderer.drawFilledRect(
            pixzig.RectF{
                .l = geom.left + 2,
                .t = geom.thumb_top,
                .r = geom.left + @as(f32, @floatFromInt(geometry.scrollbar_width_px)) - 2,
                .b = geom.thumb_top + geom.thumb_h,
            },
            pixzig.Color.from(120, 120, 130, 255),
        );
    }

    /// Draws one layer's visible viewport with its top-left cell at
    /// `(origin_x, origin_y)` in screen pixels -- shared by `render` for
    /// the root layer (origin `(0, 0)`) and every other layer (origin its
    /// own `pos`, rounded to the nearest pixel). `view_offset` is the
    /// scrollback view offset to render (see `glyphwire.Layer.view_scroll`)
    /// -- always 0 for non-root layers, which don't expose scrollback
    /// viewing.
    fn renderLayer(self: *Renderer, eng: *Engine, layer: *const glyphwire.Layer, origin_x: i32, origin_y: i32, draw_cursor: bool, view_offset: usize) void {
        // Draw the layer one category at a time, each category in its own
        // `begin`/`end` so it is fully flushed to the framebuffer before
        // the next category starts. Two things break a single interleaved
        // pass: pixzig submits a pass's batches in a fixed order (sprites,
        // shapes, overlays, text) rather than call order, AND it
        // auto-flushes any batch that fills past its quad capacity
        // mid-pass. A large grid -- a full-window `ls` icon table -- can
        // cross that capacity partway down, so some rows' color
        // backgrounds get flushed on top of text that was already drawn,
        // making the content of every backgrounded row above (or below)
        // that point vanish, differently at each scroll position.
        // Separate flushed passes fix the paint order no matter how many
        // quads a category needs; overflow then only costs an extra draw
        // call within one category.
        //
        // Order, back to front: color backgrounds, image backgrounds,
        // icons (`draw_icon` backgrounds and every foreground/table icon),
        // then text on top, then the cursor caret above all of it.
        for ([_]Pass{ .color_bg, .image_bg, .icons, .text }) |pass| {
            if (pass == .icons) self.deferred_icons.clearRetainingCapacity();

            eng.renderer.begin(eng.projMat);

            const any_highlight = layer.highlighted_ids.items.len > 0;

            var row: usize = 0;
            while (row < layer.height) : (row += 1) {
                const row_cells = layer.viewRow(view_offset, row);
                var col: usize = 0;
                while (col < layer.width) : (col += 1) {
                    const pos = pixzig.Vec2I{
                        .x = origin_x + @as(i32, @intCast(col)) * geometry.cell_w,
                        .y = origin_y + @as(i32, @intCast(row)) * geometry.cell_h,
                    };
                    self.drawCell(eng, &row_cells[col], pos, pass);

                    // Highlight tint: any cell whose `metadata_id` is in the
                    // layer's highlighted-id set (glyphwire-shell's ls
                    // multi-select marks). Drawn in the color-background
                    // pass so the text pass paints over it and stays
                    // readable, and per cell rather than as a span so it
                    // follows the tagged content with no row math.
                    if (pass == .color_bg and any_highlight and
                        layer.isHighlighted(row_cells[col].metadata_id))
                    {
                        eng.renderer.drawFilledRect(
                            pixzig.RectF.fromPosSize(pos.x, pos.y, geometry.cell_w, geometry.cell_h),
                            selection.selection_highlight_color,
                        );
                    }
                }
            }

            // `.natural`-scale icons overflow past their own cell, so the
            // icons pass collects them and draws them after the grid, when
            // an overflow paints over neighbors regardless of draw order.
            // `d.foreground` keeps each in the sprite vs overlay batch its
            // in-cell counterpart would have used.
            if (pass == .icons) {
                for (self.deferred_icons.items) |d| {
                    self.drawIconCell(eng, d.icon, d.pos, d.foreground);
                }
            }

            // Selection tint: drawn in the color-background pass so the
            // text pass paints over it and stays readable. One filled
            // rect per selected row span (see `Layer.selectionColRange`);
            // `above = view_offset - row` is the scroll-stable row key.
            if (pass == .color_bg and layer.selection != null) {
                var srow: usize = 0;
                while (srow < layer.height) : (srow += 1) {
                    const above: i64 = @as(i64, @intCast(view_offset)) - @as(i64, @intCast(srow));
                    const range = layer.selectionColRange(above) orelse continue;
                    const x0 = origin_x + @as(i32, @intCast(range.start)) * geometry.cell_w;
                    const rect_w = @as(i32, @intCast(range.end - range.start)) * geometry.cell_w;
                    const y0 = origin_y + @as(i32, @intCast(srow)) * geometry.cell_h;
                    eng.renderer.drawFilledRect(
                        pixzig.RectF.fromPosSize(x0, y0, rect_w, geometry.cell_h),
                        selection.selection_highlight_color,
                    );
                }
            }


            eng.renderer.end();
        }

        // Cursor caret, in its own flushed pass so it sits on top of the
        // text just drawn (a filled rect in the text pass would be
        // submitted before the text batch and hidden by it). Shape and
        // blink come from `host.conf` (see `config.CursorConfig`).
        //
        // Normally the caret sits at the layer's live grid cursor -- which
        // glyphwire-shell's keyboard browse deliberately walks onto a
        // scrolled-back row, so the caret follows it there. But a
        // *mouse*-driven scroll pins the caret (`caret.Caret.pin`) to the
        // buffer cell it was on when the scroll began: it rides the
        // content as the view moves and clips off-screen once that cell
        // leaves the viewport, rather than staying glued to the live
        // prompt's cell.
        if (draw_cursor and self.app.caret.visible()) {
            var crow: usize = layer.cursor.row;
            var ccol: usize = layer.cursor.col;
            var on_grid = true;
            if (self.app.caret.pin) |pin| {
                const sr = @as(isize, @intCast(pin.row)) +
                    @as(isize, @intCast(view_offset)) -
                    @as(isize, @intCast(pin.base_scroll));
                if (sr < 0 or sr >= @as(isize, @intCast(layer.height))) {
                    on_grid = false;
                } else {
                    crow = @intCast(sr);
                    ccol = pin.col;
                }
            }
            if (on_grid and crow < layer.height and ccol < layer.width) {
                eng.renderer.begin(eng.projMat);
                self.drawCaret(eng, layer, origin_x, origin_y, crow, ccol, view_offset);
                eng.renderer.end();
            }
        }
    }

    /// Paints the caret for `layer` at grid cell `(crow, ccol)` (already
    /// resolved by the caller -- the live cursor, or a `caret.Caret.pin`ned
    /// cell). `block`, `box`, and `underline` cover the whole cell -- two
    /// cells when it sits on the lead of a wide (CJK) character -- while
    /// `line` stays a thin bar at the cell's left edge regardless. Assumes
    /// an open renderer pass (see the caller).
    fn drawCaret(self: *const Renderer, eng: *Engine, layer: *const glyphwire.Layer, origin_x: i32, origin_y: i32, crow: usize, ccol: usize, view_offset: usize) void {
        const white = pixzig.Color.from(255, 255, 255, 255);
        const cx = origin_x + @as(i32, @intCast(ccol)) * geometry.cell_w;
        const cy = origin_y + @as(i32, @intCast(crow)) * geometry.cell_h;

        const on_wide_lead = layer.viewRow(view_offset, crow)[ccol].wide == .wide_lead;
        const cell_span: i32 = if (on_wide_lead) geometry.cell_w * 2 else geometry.cell_w;

        switch (self.app.caret.shape) {
            .line => eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(cx, cy, cursor_width, geometry.cell_h),
                white,
            ),
            .block => eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(cx, cy, cell_span, geometry.cell_h),
                white,
            ),
            .box => eng.renderer.drawRect(
                pixzig.RectF.fromPosSize(cx, cy, cell_span, geometry.cell_h),
                white,
                cursor_box_line_px,
            ),
            .underline => eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(cx, cy + geometry.cell_h - cursor_underline_px, cell_span, cursor_underline_px),
                white,
            ),
        }
    }

    /// Draws the part of cell `c` (top-left corner at `pos`) that belongs
    /// to render pass `pass`. Called once per cell per pass by
    /// `renderLayer`; see that function for why the passes are separated.
    fn drawCell(self: *Renderer, eng: *Engine, c: *const glyphwire.Cell, pos: pixzig.Vec2I, pass: Pass) void {
        switch (pass) {
            .color_bg => switch (c.style.bg) {
                .color => |bg| {
                    if (bg.r != 0 or bg.g != 0 or bg.b != 0) {
                        eng.renderer.drawFilledRect(
                            pixzig.RectF.fromPosSize(pos.x, pos.y, geometry.cell_w, geometry.cell_h),
                            pixzig.Color.from(bg.r, bg.g, bg.b, bg.a),
                        );
                    }
                },
                else => {},
            },
            .image_bg => switch (c.style.bg) {
                .image => |img| self.drawImageCell(eng, img, pos),
                else => {},
            },
            .icons => {
                switch (c.style.bg) {
                    .icon => |icon| self.queueOrDrawIcon(eng, icon, pos, false),
                    else => {},
                }
                // `fg_icon` (`draw_icon`'s `foreground: true`, and every
                // table body icon -- see `core.Cell.fg_icon`) sits over a
                // same-cell `.icon` background; `drawIconCell`'s
                // `foreground` routes it to the overlay batch for that.
                if (c.fg_icon) |icon| self.queueOrDrawIcon(eng, icon, pos, true);
            },
            .text => {
                const g = c.grapheme();
                if (g.len > 0) {
                    _ = eng.renderer.drawStringColored(g, pos, pixzig.Color.from(c.style.fg.r, c.style.fg.g, c.style.fg.b, c.style.fg.a));
                }
            },
        }
    }
};
