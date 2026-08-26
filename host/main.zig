const std = @import("std");
const glyphwire = @import("glyphwire");
const pixzig = @import("pixzig");

pub const panic = pixzig.system.panic;
pub const std_options = pixzig.system.std_options;

/// glyphwire-host: the pixzig-windowed glyphwire renderer (Milestone 8 --
/// see docs/slice_plan.md). Owns the `Context` and `Server` in-process --
/// it's the graphical front end, not just another client of a separately
/// spawned server -- and reads/writes the grid directly (see `App.render`,
/// `Server.reportKey`/`reportMouseButton`/`reportMouseMove`), with no wire
/// round trip for its own state. glyphwire-shell is still a separate
/// process (no pixzig dependency, so it can't own an in-process `Context`
/// itself) and only ever sees the grid through the socket, exactly like
/// any other client would -- `Server.serveForever` runs on a background
/// thread the whole time so that connection keeps working normally.
const grid_cols = 120;
const grid_rows = 50;
const scrollback_rows = 1000;
const font_path = "assets/JetBrainsMono-Regular.ttf";
const font_size: f32 = 18.0;
const cursor_width = 2;

// Cell size in pixels, set from the loaded font's own metrics at startup
// -- see `main`. `var` (not `const`) because `pixzig.renderer.measureFontFile`
// has to run before the window exists (see the comment there), so these
// can't be comptime/const like the rest of this block.
var cell_w: i32 = undefined;
var cell_h: i32 = undefined;

// Typematic repeat timing for arrow keys -- how long a key must be held
// before it starts repeating, and how often it repeats after that. Typical
// OS keyboard-repeat values; tune here if they feel off.
const arrow_repeat_delay_ms: f64 = 500;
const arrow_repeat_interval_ms: f64 = 40;

const EngOptions: pixzig.PixzigEngineOptions = .{
    .rendererOpts = .{ .textRendering = true },
};
const AppRunner = pixzig.PixzigAppRunner(App, EngOptions);

/// Tracks how long one arrow key has been continuously held, to drive its
/// typematic repeat -- pixzig's `Keyboard` only edge-detects `pressed`/
/// `released`, no built-in hold-duration, so `App` has to track this
/// itself.
const ArrowRepeatState = struct {
    held_ms: f64 = 0,
    next_repeat_ms: f64 = arrow_repeat_delay_ms,

    fn reset(self: *ArrowRepeatState) void {
        self.held_ms = 0;
        self.next_repeat_ms = arrow_repeat_delay_ms;
    }

    /// Call once per tick while the key is physically down (not on the
    /// initial press -- that edge already moves the cursor once, handled
    /// separately). Returns true once held_ms crosses the next scheduled
    /// repeat threshold.
    fn tick(self: *ArrowRepeatState, delta_ms: f64) bool {
        self.held_ms += delta_ms;
        if (self.held_ms < self.next_repeat_ms) return false;
        self.next_repeat_ms += arrow_repeat_interval_ms;
        return true;
    }
};

pub const App = struct {
    alloc: std.mem.Allocator,
    server: *glyphwire.server.Server,
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
    /// Scratch buffer for `renderLayer`'s deferred-overflow pass -- see
    /// `DeferredIcon`. Cleared (not freed) at the start of each
    /// `renderLayer` call and reused across frames/layers.
    deferred_icons: std.ArrayList(DeferredIcon) = .empty,
    /// Set by `reapChild` once glyphwire-shell's process actually exits
    /// (normally from its `exit` builtin, but this covers a crash or
    /// external kill just as well) -- the one thing that ends the host,
    /// deliberately not `escape` the way a typical pixzig example/game
    /// would: an accidental Escape shouldn't kill an interactive shell
    /// session out from under whatever's running in it.
    shell_exited: *std.atomic.Value(bool),
    last_mouse_px: pixzig.Vec2F = .{ .x = -1, .y = -1 },
    arrow_repeat: struct {
        up: ArrowRepeatState = .{},
        down: ArrowRepeatState = .{},
        left: ArrowRepeatState = .{},
        right: ArrowRepeatState = .{},
    } = .{},

    pub fn init(alloc: std.mem.Allocator, eng: *AppRunner.Engine, server: *glyphwire.server.Server, shell_exited: *std.atomic.Value(bool)) !*App {
        _ = eng;
        const app = try alloc.create(App);
        app.* = .{
            .alloc = alloc,
            .server = server,
            .image_textures = std.AutoHashMap(glyphwire.ImageHandle, *pixzig.ManagedTexture).init(alloc),
            .shell_exited = shell_exited,
        };
        return app;
    }

    pub fn deinit(self: *App) void {
        self.deferred_icons.deinit(self.alloc);
        self.image_textures.deinit();
        self.alloc.destroy(self);
    }

    /// Returns a stable pointer to the uploaded texture for `handle`,
    /// decoding and uploading it first if this is the first time this App
    /// has seen it -- see `image_textures`'s doc comment. Null if `handle`
    /// isn't in `ctx.images` (shouldn't happen: `draw_image` already
    /// validated the handle before marking a cell with it), decoding the
    /// stored bytes fails, or (defensively) the managed pool somehow has
    /// no live generation right after we just added one.
    fn textureForImage(self: *App, eng: *AppRunner.Engine, handle: glyphwire.ImageHandle) ?*pixzig.Texture {
        const managed = self.image_textures.get(handle) orelse blk: {
            const entry = self.server.ctx.images.get(handle) orelse return null;
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
    fn drawImageCell(self: *App, eng: *AppRunner.Engine, img: glyphwire.ImageBg, pos: pixzig.Vec2I) void {
        const entry = self.server.ctx.images.get(img.handle) orelse return;
        if (img.offset_x >= entry.width or img.offset_y >= entry.height) return;

        const tex = self.textureForImage(eng, img.handle) orelse return;

        const avail_w: i32 = @min(cell_w, @as(i32, @intCast(entry.width - img.offset_x)));
        const avail_h: i32 = @min(cell_h, @as(i32, @intCast(entry.height - img.offset_y)));
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
    /// which never overflow, or deferring to a second pass so the
    /// overflow paints over already-drawn neighbors, for `.natural`).
    /// `.stretch` fills the cell exactly on both axes (see `IconScale`'s
    /// doc comment) -- `icon.h_align`/`icon.v_align` are no-ops for it
    /// (there's no leftover space to align within), but still apply to
    /// `.fit`/`.natural` to place the (possibly smaller, possibly bigger)
    /// result within the cell's bounds.
    fn drawIconCell(self: *App, eng: *AppRunner.Engine, icon: glyphwire.IconBg, pos: pixzig.Vec2I) void {
        const entry = self.server.ctx.images.get(icon.handle) orelse return;
        const tex = self.textureForImage(eng, icon.handle) orelse return;
        if (entry.width == 0 or entry.height == 0) return;

        const cell_w_f: f32 = @floatFromInt(cell_w);
        const cell_h_f: f32 = @floatFromInt(cell_h);
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

        eng.renderer.draw(
            tex,
            pixzig.RectF{ .l = dest_x, .t = dest_y, .r = dest_x + dest_w, .b = dest_y + dest_h },
            pixzig.RectF{ .l = icon.src_l, .t = icon.src_t, .r = icon.src_r, .b = icon.src_b },
        );
    }

    /// One `.natural`-scale icon whose draw is deferred past the rest of
    /// `renderLayer`'s grid -- see `drawIconCell`'s doc comment.
    const DeferredIcon = struct {
        icon: glyphwire.IconBg,
        pos: pixzig.Vec2I,
    };

    pub fn update(self: *App, eng: *AppRunner.Engine, deltaTimeMs: f64) bool {
        if (self.shell_exited.load(.monotonic)) return false;

        self.reportKeyEvents(eng);
        self.reportMouseEvents(eng);
        self.handleArrowKeys(eng, deltaTimeMs);

        return true;
    }

    /// Moves the grid cursor for each arrow key, clamped to the grid --
    /// generic terminal-style cursor addressing, independent of
    /// glyphwire-shell's line editor (which repositions the cursor itself
    /// on every character it writes, so it isn't thrown off by wherever an
    /// arrow key last left the cursor). The initial press already reached
    /// `ctx.input`'s down-set and got broadcast via `reportKeyEvents`
    /// above; held-down repeats move the cursor again here and separately
    /// re-broadcast via `reportKeyRepeat`, since `reportKey`/`setKey`
    /// would see no state change on a key that's already down and drop it.
    fn handleArrowKeys(self: *App, eng: *AppRunner.Engine, delta_ms: f64) void {
        self.handleArrowKey(eng, .up, "up", &self.arrow_repeat.up, 0, -1, delta_ms);
        self.handleArrowKey(eng, .down, "down", &self.arrow_repeat.down, 0, 1, delta_ms);
        self.handleArrowKey(eng, .left, "left", &self.arrow_repeat.left, -1, 0, delta_ms);
        self.handleArrowKey(eng, .right, "right", &self.arrow_repeat.right, 1, 0, delta_ms);
    }

    fn handleArrowKey(
        self: *App,
        eng: *AppRunner.Engine,
        key: pixzig.glfw.Key,
        name: []const u8,
        state: *ArrowRepeatState,
        dcol: i32,
        drow: i32,
        delta_ms: f64,
    ) void {
        if (eng.inputs.keyboard.pressed(key)) {
            state.reset();
            self.moveCursor(dcol, drow);
        } else if (eng.inputs.keyboard.down(key)) {
            if (state.tick(delta_ms)) {
                self.moveCursor(dcol, drow);
                self.server.reportKeyRepeat(self.alloc, name) catch |err| {
                    std.log.err("reportKeyRepeat({s}) failed: {t}", .{ name, err });
                };
            }
        } else {
            state.reset();
        }
    }

    /// Moves `ctx.root`'s cursor by one cell, clamped to the grid.
    /// `ctx_mutex`-guarded like `render`'s read, since this runs on the
    /// same thread as everything else in `update`/`render` but still
    /// shares `ctx` with connected clients' dispatch threads (e.g.
    /// glyphwire-shell's own `set_property cursor` calls).
    fn moveCursor(self: *App, dcol: i32, drow: i32) void {
        self.server.ctx_mutex.lockUncancelable(self.server.io);
        defer self.server.ctx_mutex.unlock(self.server.io);

        const layer = &self.server.ctx.root;
        const col: i32 = @as(i32, @intCast(layer.cursor.col)) + dcol;
        const row: i32 = @as(i32, @intCast(layer.cursor.row)) + drow;
        layer.cursor.col = @intCast(std.math.clamp(col, 0, @as(i32, @intCast(layer.width - 1))));
        layer.cursor.row = @intCast(std.math.clamp(row, 0, @as(i32, @intCast(layer.height - 1))));
    }

    /// Reports every key that changed down/up state this frame -- see
    /// `Keyboard.pressed`/`.released`'s edge-detection doc comments in
    /// pixzig -- directly against the in-process `Server` (see
    /// `Server.reportKey`), not over a socket connection to itself.
    fn reportKeyEvents(self: *App, eng: *AppRunner.Engine) void {
        const fields = @typeInfo(pixzig.glfw.Key).@"enum".fields;
        inline for (fields) |field| {
            const key = @field(pixzig.glfw.Key, field.name);
            if (eng.inputs.keyboard.pressed(key)) {
                self.server.reportKey(self.alloc, field.name, true) catch |err| {
                    std.log.err("reportKey({s}, true) failed: {t}", .{ field.name, err });
                };
            } else if (eng.inputs.keyboard.released(key)) {
                self.server.reportKey(self.alloc, field.name, false) catch |err| {
                    std.log.err("reportKey({s}, false) failed: {t}", .{ field.name, err });
                };
            }
        }
    }

    fn reportMouseEvents(self: *App, eng: *AppRunner.Engine) void {
        if (!eng.inputs.mouse_enabled) return;
        const pos = eng.inputs.mouse.pos();
        const cell = cellFromPixel(pos.x, pos.y);

        if (pos.x != self.last_mouse_px.x or pos.y != self.last_mouse_px.y) {
            self.last_mouse_px = pos;
            self.server.reportMouseMove(.{ .x = pos.x, .y = pos.y }, cell);
        }

        const fields = @typeInfo(pixzig.glfw.MouseButton).@"enum".fields;
        inline for (fields) |field| {
            const btn = @field(pixzig.glfw.MouseButton, field.name);
            if (eng.inputs.mouse.pressed(btn)) {
                self.server.reportMouseButton(self.alloc, field.name, true, .{ .x = pos.x, .y = pos.y }, cell) catch |err| {
                    std.log.err("reportMouseButton({s}, true) failed: {t}", .{ field.name, err });
                };
            } else if (eng.inputs.mouse.released(btn)) {
                self.server.reportMouseButton(self.alloc, field.name, false, .{ .x = pos.x, .y = pos.y }, cell) catch |err| {
                    std.log.err("reportMouseButton({s}, false) failed: {t}", .{ field.name, err });
                };
            }
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
    pub fn render(self: *App, eng: *AppRunner.Engine) void {
        eng.renderer.clear(0.0, 0.0, 0.0, 1.0);
        eng.renderer.begin(eng.projMat);

        self.server.ctx_mutex.lockUncancelable(self.server.io);
        defer self.server.ctx_mutex.unlock(self.server.io);

        self.renderLayer(eng, &self.server.ctx.root, 0, 0, true);
        for (self.server.ctx.layer_order.items) |handle| {
            const layer = self.server.ctx.layers.getPtr(handle) orelse continue;
            self.renderLayer(
                eng,
                layer,
                @intFromFloat(@round(layer.pos.x)),
                @intFromFloat(@round(layer.pos.y)),
                false,
            );
        }

        eng.renderer.end();
    }

    /// Draws one layer's visible viewport with its top-left cell at
    /// `(origin_x, origin_y)` in screen pixels -- shared by `render` for
    /// the root layer (origin `(0, 0)`) and every other layer (origin its
    /// own `pos`, rounded to the nearest pixel).
    fn renderLayer(self: *App, eng: *AppRunner.Engine, layer: *const glyphwire.Layer, origin_x: i32, origin_y: i32, draw_cursor: bool) void {
        self.deferred_icons.clearRetainingCapacity();

        var row: usize = 0;
        while (row < layer.height) : (row += 1) {
            var col: usize = 0;
            while (col < layer.width) : (col += 1) {
                const c = layer.cell(row, col);
                const pos = pixzig.Vec2I{
                    .x = origin_x + @as(i32, @intCast(col)) * cell_w,
                    .y = origin_y + @as(i32, @intCast(row)) * cell_h,
                };

                switch (c.style.bg) {
                    .color => |bg| {
                        if (bg.r != 0 or bg.g != 0 or bg.b != 0) {
                            eng.renderer.drawFilledRect(
                                pixzig.RectF.fromPosSize(pos.x, pos.y, cell_w, cell_h),
                                pixzig.Color.from(bg.r, bg.g, bg.b, bg.a),
                            );
                        }
                    },
                    .image => |img| self.drawImageCell(eng, img, pos),
                    .icon => |icon| {
                        // `.fit` never exceeds its cell, so it's safe (and
                        // simplest) to draw immediately in grid order;
                        // `.natural` can overflow into cells this loop
                        // hasn't reached yet, so it's deferred past the
                        // whole grid -- see `drawIconCell`'s doc comment.
                        if (icon.scale == .natural) {
                            self.deferred_icons.append(self.alloc, .{ .icon = icon, .pos = pos }) catch {};
                        } else {
                            self.drawIconCell(eng, icon, pos);
                        }
                    },
                }

                const g = c.grapheme();
                if (g.len > 0) {
                    _ = eng.renderer.drawStringColored(g, pos, pixzig.Color.from(c.style.fg.r, c.style.fg.g, c.style.fg.b, c.style.fg.a));
                }

                // `fg_icon` (`draw_icon`'s `foreground: true` -- see
                // `core.Cell.fg_icon`'s doc comment) draws over whatever
                // this cell's own background/glyph just drew, same
                // tile/natural-defer split as `style.bg`'s `.icon` above.
                if (c.fg_icon) |icon| {
                    if (icon.scale == .natural) {
                        self.deferred_icons.append(self.alloc, .{ .icon = icon, .pos = pos }) catch {};
                    } else {
                        self.drawIconCell(eng, icon, pos);
                    }
                }
            }
        }

        // `.natural`-scale icons deferred above: drawn now, after the
        // whole grid, so an icon's overflow always paints over every
        // cell's own background/glyph regardless of row/col draw order --
        // see `drawIconCell`'s doc comment.
        for (self.deferred_icons.items) |d| {
            self.drawIconCell(eng, d.icon, d.pos);
        }

        // Cursor caret: a solid bar at the start (left edge) of the
        // cursor's cell, drawn last so it sits on top of that cell's own
        // background/glyph (and any deferred icon overflow just drawn
        // above).
        if (draw_cursor and layer.cursor.row < layer.height and layer.cursor.col < layer.width) {
            const cx = origin_x + @as(i32, @intCast(layer.cursor.col)) * cell_w;
            const cy = origin_y + @as(i32, @intCast(layer.cursor.row)) * cell_h;
            eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(cx, cy, cursor_width, cell_h),
                pixzig.Color.from(255, 255, 255, 255),
            );
        }
    }
};

/// Converts a pixel position (window-local, matching what
/// `eng.inputs.mouse.pos()` reports since host doesn't set a scaled
/// `logicalSize`) to a grid cell position, clamped to the grid bounds.
fn cellFromPixel(x: f32, y: f32) glyphwire.CellPos {
    const col_f = x / @as(f32, @floatFromInt(cell_w));
    const row_f = y / @as(f32, @floatFromInt(cell_h));
    const max_col: f32 = @floatFromInt(grid_cols - 1);
    const max_row: f32 = @floatFromInt(grid_rows - 1);
    const col: usize = @intFromFloat(std.math.clamp(col_f, 0, max_col));
    const row: usize = @intFromFloat(std.math.clamp(row_f, 0, max_row));
    return .{ .row = row, .col = col };
}

/// Waits for glyphwire-shell to exit, then flags `shell_exited` so
/// `App.update` ends the window loop -- the shell process actually
/// terminating (via its `exit` builtin, a crash, or an external kill) is
/// what quits the host now, not a keypress. Not joined by `main`, same as
/// `serveForeverThread`: nothing needs its result once the run loop below
/// is what keeps the process alive.
fn reapChild(io: std.Io, child_in: std.process.Child, shell_exited: *std.atomic.Value(bool)) void {
    var child = child_in;
    _ = child.wait(io) catch {};
    shell_exited.store(true, .monotonic);
}

/// Runs `Server.serveForever` for the lifetime of the process, on its own
/// thread -- not joined, same as the reaped child processes below: it
/// keeps serving glyphwire-shell (and any other socket client) for as long
/// as the process runs, and there's nothing to hand its result to once the
/// window/render loop below is what actually keeps the process alive.
fn serveForeverThread(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.serveForever(alloc) catch |err| {
        std.log.err("glyphwire server stopped: {t}", .{err});
    };
}

/// Reads each entry in `manifest` (either `glyphwire.default_icon_manifest`
/// or `glyphwire.default_box_manifest` -- both register into the same flat
/// `icons` catalog, see decisions.md's Icon section) and loads its PNG
/// file into `ctx` -- the real file I/O `core.zig` deliberately doesn't do
/// itself (headless-first). Logs and skips any entry whose file is
/// missing or fails to load rather than failing the whole host, so one
/// broken/missing asset doesn't block startup.
fn loadIconManifest(io: std.Io, alloc: std.mem.Allocator, ctx: *glyphwire.Context, manifest: []const glyphwire.IconManifestEntry) void {
    for (manifest) |entry| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, entry.path, alloc, .limited(16 * 1024 * 1024)) catch |err| {
            std.log.warn("glyphwire-host: couldn't read icon '{s}' ({s}): {t}", .{ entry.name, entry.path, err });
            continue;
        };
        defer alloc.free(bytes);

        const handle = ctx.loadImage(bytes) catch |err| {
            std.log.warn("glyphwire-host: couldn't load icon '{s}': {t}", .{ entry.name, err });
            continue;
        };
        ctx.registerIcon(entry.name, handle) catch |err| {
            std.log.warn("glyphwire-host: couldn't register icon '{s}': {t}", .{ entry.name, err });
        };
    }
}

fn socketPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(alloc, "{s}/glyphwire-{d}.sock", .{ dir, pid });
}

/// Resolves a sibling binary built alongside this one (zig-out/bin/<name>)
/// by absolute path. They're not on $PATH in dev mode, so a bare argv[0]
/// (relying on std.process.spawn's PATH search) would fail to resolve --
/// see shell/main.zig's demo-path comment for the same issue.
fn resolveSibling(alloc: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fmt.allocPrint(alloc, "{s}/zig-out/bin/{s}", .{ cwd_buf[0..cwd_len], name });
}

pub fn main(init: std.process.Init) !void {
    std.log.info("glyphwire host starting", .{});
    const alloc = init.gpa;
    // Process-lifetime setup values (args, paths, the shell's argv/environ)
    // that are never freed -- deliberately, they're needed until the
    // process exits below -- so they're allocated from `init.arena`
    // (reclaimed automatically on exit) rather than `alloc`, whose
    // DebugAllocator would otherwise flag every one of them as a leak.
    // Mirrors `server/main.zig`'s `args` allocation.
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    // With no explicit command, default to glyphwire-shell's own
    // interactive prompt (its no-args mode) rather than exec'ing into a
    // specific child.
    const shell_child_argv: []const []const u8 = if (args.len >= 2) args[1..] else &.{};

    const socket_path = try socketPath(arena, init.environ_map);

    // Measuring metrics needs only the font's own bytes (stb_truetype's
    // InitFont/GetFontVMetrics/GetCodepointHMetrics), not a GL context, so
    // this can run before the window exists -- unlike packing the font into
    // an atlas texture, which does need one (see AppRunner.init below).
    // That means the window can be sized correctly for whatever font is
    // configured instead of a size tuned by hand for one specific font.
    const metrics = try pixzig.renderer.measureFontFile(font_path, font_size, alloc);
    cell_w = metrics.advance;
    cell_h = metrics.line_height;

    var ctx = try glyphwire.Context.init(alloc, grid_cols, grid_rows, scrollback_rows);
    defer ctx.deinit();
    // Context.init defaults these to 12x12 already; set explicitly so they
    // stay tied to this file's own cell_w/cell_h (now measured from
    // `font_path` above) rather than silently relying on the default
    // matching -- see Context's doc comment on cell_px_w/cell_px_h.
    ctx.cell_px_w = @intCast(cell_w);
    ctx.cell_px_h = @intCast(cell_h);
    loadIconManifest(io, alloc, &ctx, &glyphwire.default_icon_manifest);
    loadIconManifest(io, alloc, &ctx, &glyphwire.default_box_manifest);
    loadIconManifest(io, alloc, &ctx, &glyphwire.default_dialog_manifest);
    loadIconManifest(io, alloc, &ctx, &glyphwire.default_notify_icon_manifest);

    // `.listen()` inside `bind` is synchronous -- the socket is already
    // accept-ready (kernel-queued, even before `serveForever`'s thread
    // starts calling `accept`) by the time this returns, so unlike the
    // old separate-process design, glyphwire-shell can be spawned right
    // below with no wait-for-socket-ready polling loop needed.
    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    _ = try std.Thread.spawn(.{}, serveForeverThread, .{ &srv, alloc });

    var shell_env = try init.environ_map.clone(arena);
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try shell_env.put("GLYPHWIRE_CTX", glyphwire.default_context_id);

    const shell_path = try resolveSibling(arena, io, "glyphwire-shell");
    const shell_argv = try std.mem.concat(arena, []const u8, &.{ &.{shell_path}, shell_child_argv });

    // Left false (no other way to quit) if the spawn itself fails --
    // an edge case not worth a fallback keybinding for.
    var shell_exited: std.atomic.Value(bool) = .init(false);
    if (std.process.spawn(io, .{ .argv = shell_argv, .environ_map = &shell_env })) |shell_child| {
        _ = try std.Thread.spawn(.{}, reapChild, .{ io, shell_child, &shell_exited });
    } else |err| {
        std.log.err("failed to spawn glyphwire-shell: {t}", .{err});
    }

    // Font atlas packing (unlike the metrics measured above) does need a GL
    // context, so it still happens here, after the window is created.
    const appRunner = try AppRunner.init("glyphwire", alloc, .{
        .windowSize = .{ .x = grid_cols * cell_w, .y = grid_rows * cell_h },
        .resizable = false,
        .renderInitOpts = .{ .font = .{ .path = .{ .face = font_path, .size = font_size } } },
    });
    const app = try App.init(alloc, appRunner.engine, &srv, &shell_exited);

    appRunner.run(app);

    // `appRunner.run` only returns once the window closes, but
    // `serveForever`'s thread and any live per-connection threads (e.g.
    // the glyphwire-shell child, which is normally still connected) are
    // never joined -- see their own doc comments. Falling through to the
    // `ctx.deinit()`/`srv.deinit()` defers above would free `ctx` and the
    // listener out from under whichever of those threads is still
    // running, racing a live dispatch against `ctx` (unsynchronized: that
    // free doesn't take `srv.ctx_mutex`) and leaking each open
    // connection's still-alive `FrameDecoder` buffer. Exiting immediately
    // sidesteps all of that and lets the OS reclaim everything at once,
    // the same as how `server/main.zig` is only ever stopped externally.
    std.process.exit(0);
}
