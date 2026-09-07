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
// The grid's initial size in cells; the window opens at this many cells
// times the measured cell pixel size. After that the window is
// user-resizable and `grid_cols`/`grid_rows` track its live size (see
// `App.syncWindowSize`) -- `var`, not `const`, for that reason.
const initial_grid_cols = 120;
const initial_grid_rows = 50;
var grid_cols: usize = initial_grid_cols;
var grid_rows: usize = initial_grid_rows;
// Floor the live grid size at something a shell prompt stays usable in,
// so dragging the window very small clips the render rather than
// collapsing the root layer to a degenerate size.
const min_grid_cols = 16;
const min_grid_rows = 4;
const scrollback_rows = 1000;

// Font defaults. `assets/conf.lua` (a global `config` table with
// `font_face` / `font_face_name` / `font_fallback` / `font_size` -- any
// subset) overrides these at startup; see `loadConfig`. The primary is
// Noto Sans Mono CJK: one monospaced face covering Latin, Greek, Cyrillic
// and CJK, so `ls` of files with Greek/Russian/Japanese names renders
// without tofu. It's a `.ttc` collection, so `font_face_name` picks the
// Japanese monospaced face out of it (a plain `.ttf` ignores the name and
// uses face 0). The fallback face is tried for any codepoint the primary
// lacks before the atlas falls back to its `.notdef` (tofu) box.
const font_path_default = "assets/NotoSansCJK-Regular.ttc";
const font_face_name_default = "Mono CJK JP";
const font_fallback_default = "assets/JetBrainsMono-Regular.ttf";
const font_size_default: f32 = 20.0;
const conf_lua_path = "assets/conf.lua";

// Always-registered extra fallback: a tiny pyftsubset of a Nerd Font to
// the Powerline range (U+E0A0-E0D7), for a configured powerline shell
// prompt's separator / cap glyphs.
const powerline_symbols_font = "assets/PowerlineSymbols-subset.ttf";

// Runtime font-size (Ctrl+- / Ctrl++ / Ctrl+0) policy. The engine applies
// whatever size it is handed; the clamp range and step are the host's.
const min_font_size: f32 = 8.0;
const max_font_size: f32 = 72.0;
const font_size_step: f32 = 2.0;

/// Font settings resolved at startup from `conf_lua_path` layered over the
/// `*_default` constants above. String fields point at `arena`-allocated
/// (process-lifetime) memory, or the default string literals.
const FontConfig = struct {
    face: [:0]const u8 = font_path_default,
    face_name: []const u8 = font_face_name_default,
    fallback: [:0]const u8 = font_fallback_default,
    size: f32 = font_size_default,
};

// Width in px of the `.line` caret, and thickness in px of the
// `.underline` bar and the `.box` outline.
const cursor_width = 2;
const cursor_underline_px = 2;
const cursor_box_line_px = 2;

/// The four caret shapes `assets/conf.lua`'s `cursor_shape` can select.
/// `line` (a vertical bar at the cell's left edge) is the default and the
/// original behavior; the rest fill, outline, or underline the cell.
const CursorShape = enum { line, block, box, underline };

const cursor_shape_default: CursorShape = .line;
const cursor_blink_default: bool = true;
// Half-period: the caret is shown for this long, then hidden for this
// long. ~530ms matches the historical xterm default. Clamped to a sane
// range when read from config.
const cursor_blink_ms_default: f64 = 530;
const cursor_blink_ms_min: f64 = 100;
const cursor_blink_ms_max: f64 = 5000;

/// Caret appearance, resolved at startup from `conf_lua_path` (see
/// `loadConfig`). Host-local, like `FontConfig` -- the caret is a property
/// of the rendering front end, not the shared grid model.
const CursorConfig = struct {
    shape: CursorShape = cursor_shape_default,
    blink: bool = cursor_blink_default,
    blink_ms: f64 = cursor_blink_ms_default,
};

/// Everything `loadConfig` resolves from `assets/conf.lua`.
const HostConfig = struct {
    font: FontConfig = .{},
    cursor: CursorConfig = .{},
};

// Blank margin, in pixels, kept on both sides of the composited layers:
// one strip against the window's left border, and one between the grid's
// right edge and the always-on scrollbar. Every layer's screen origin is
// shifted right by this, `cellFromPixel` subtracts it back out, and both
// the initial window width and `syncWindowSize`'s cell math reserve
// `2 * content_pad_px` (plus the scrollbar) so no column is lost to it.
const content_pad_px: i32 = 2;

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
    // `maxSprites`: a full-window character grid draws far more than the
    // 1000-quad default per category (background rects, glyphs, icons). The
    // per-category flushed passes in `App.renderLayer` keep the paint order
    // correct regardless, but sizing every batch queue to hold a whole
    // large grid keeps each category to a single draw call. 30k covers a
    // ~240x125 cell grid of solid backgrounds; pixzig's `u32` batch indices
    // make it safe.
    .rendererOpts = .{ .textRendering = true, .maxSprites = 30_000 },
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
    /// Scratch buffer for the `.natural`-icon overflow handled at the end
    /// of `renderLayer`'s icons pass -- see `DeferredIcon`. Cleared (not
    /// freed) at the start of that pass and reused across frames/layers.
    deferred_icons: std.ArrayList(DeferredIcon) = .empty,
    /// Set by `reapChild` once glyphwire-shell's process actually exits
    /// (normally from its `exit` builtin, but this covers a crash or
    /// external kill just as well) -- the one thing that ends the host,
    /// deliberately not `escape` the way a typical pixzig example/game
    /// would: an accidental Escape shouldn't kill an interactive shell
    /// session out from under whatever's running in it.
    shell_exited: *std.atomic.Value(bool),
    last_mouse_px: pixzig.Vec2F = .{ .x = -1, .y = -1 },
    /// True while the left button is held on the scrollbar thumb after
    /// grabbing it -- see `handleScrollbar`. `scrollbar_grab_dy` is the
    /// pixel offset between the pointer and the thumb's top edge at grab
    /// time, so the thumb tracks the pointer without jumping.
    scrollbar_drag: bool = false,
    scrollbar_grab_dy: f32 = 0,
    arrow_repeat: struct {
        up: ArrowRepeatState = .{},
        down: ArrowRepeatState = .{},
        left: ArrowRepeatState = .{},
        right: ArrowRepeatState = .{},
    } = .{},
    /// Last-forwarded down/up state of each modifier, indexed
    /// `[ctrl, alt, shift, super]` -- see `reportModifier`. glyphwire-host
    /// forwards each modifier once, under its `left_*` name, from pixzig's
    /// logical modifier state rather than per physical key, so an OS-level
    /// remap like CapsLock->Control (which pixzig's `keyboard.ctrl()`
    /// reports but which never arrives as a physical modifier-key press)
    /// still reaches glyphwire-shell's Ctrl-combo handling.
    mod_forwarded: [4]bool = .{ false, false, false, false },
    /// Set from `--screenshot <path>`: once `screenshot_elapsed_ms` passes
    /// `screenshot_delay_ms`, `render` writes the composited grid region to
    /// this path (see `captureContentArea`) and `update` quits the next
    /// frame. Null for a normal run. Used by
    /// `scripts/regen-readme-assets.sh` together with the shell's
    /// `GLYPHWIRE_SHELL_SCRIPT` (see shell/main.zig) to produce the README
    /// screenshots without any keystroke injection.
    screenshot_path: ?[]const u8 = null,
    screenshot_delay_ms: f64 = 2500,
    screenshot_elapsed_ms: f64 = 0,
    screenshot_done: bool = false,

    /// Primary font file + collection face index, kept so `applyFontSize`
    /// can re-measure cell metrics at a new size. `font_path` is
    /// process-lifetime (`arena` or a literal), same as it was passed to
    /// the renderer.
    font_path: [:0]const u8,
    font_face_index: i32,
    /// Live default-font size in px, and the size Ctrl+0 restores.
    font_size: f32,
    initial_font_size: f32,

    /// Caret appearance from `assets/conf.lua` (see `CursorConfig`).
    cursor_shape: CursorShape,
    cursor_blink: bool,
    cursor_blink_ms: f64,
    /// Milliseconds since the caret's blink phase last reset. Advanced by
    /// `deltaTimeMs` every `update`, zeroed whenever the caret moves or the
    /// window scrolls (see `tickBlink`) so the caret is solid the instant
    /// the user does anything and only blinks once things settle.
    blink_elapsed_ms: f64 = 0,
    /// The `(row, col, view_scroll)` the blink phase was last reset for --
    /// compared each `update` to detect caret movement / scrolling.
    blink_ref: struct { row: usize = 0, col: usize = 0, scroll: usize = 0 } = .{},

    /// Font file/size passed to `App.init` -- what `applyFontSize` needs to
    /// repeat the startup `measureFontFileIndexed` at a new size.
    pub const FontRuntime = struct {
        path: [:0]const u8,
        face_index: i32,
        size: f32,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        eng: *AppRunner.Engine,
        server: *glyphwire.server.Server,
        shell_exited: *std.atomic.Value(bool),
        screenshot_path: ?[]const u8,
        screenshot_delay_ms: f64,
        font: FontRuntime,
        cursor: CursorConfig,
    ) !*App {
        _ = eng;
        const app = try alloc.create(App);
        app.* = .{
            .alloc = alloc,
            .server = server,
            .image_textures = std.AutoHashMap(glyphwire.ImageHandle, *pixzig.ManagedTexture).init(alloc),
            .shell_exited = shell_exited,
            .screenshot_path = screenshot_path,
            .screenshot_delay_ms = screenshot_delay_ms,
            .font_path = font.path,
            .font_face_index = font.face_index,
            .font_size = font.size,
            .initial_font_size = font.size,
            .cursor_shape = cursor.shape,
            .cursor_blink = cursor.blink,
            .cursor_blink_ms = cursor.blink_ms,
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
    fn drawIconCell(self: *App, eng: *AppRunner.Engine, icon: glyphwire.IconBg, pos: pixzig.Vec2I, foreground: bool) void {
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

        const dest = pixzig.RectF{ .l = dest_x, .t = dest_y, .r = dest_x + dest_w, .b = dest_y + dest_h };
        const src = pixzig.RectF{ .l = icon.src_l, .t = icon.src_t, .r = icon.src_r, .b = icon.src_b };
        if (foreground) {
            eng.renderer.drawOverlayTexture(tex, dest, src);
        } else {
            eng.renderer.draw(tex, dest, src);
        }
    }

    /// One `.natural`-scale icon whose draw is deferred past the rest of
    /// `renderLayer`'s grid -- see `drawIconCell`'s doc comment.
    /// `foreground` is carried through to `drawIconCell` so a deferred
    /// `Cell.fg_icon` still lands in the overlay batch (on top of row
    /// backgrounds), not the plain sprite batch.
    const DeferredIcon = struct {
        icon: glyphwire.IconBg,
        pos: pixzig.Vec2I,
        foreground: bool,
    };

    pub fn update(self: *App, eng: *AppRunner.Engine, deltaTimeMs: f64) bool {
        if (self.shell_exited.load(.monotonic)) return false;
        // A `--screenshot` run quits the frame after `render` has taken
        // the capture, so an automated run terminates on its own.
        if (self.screenshot_done) return false;
        if (self.screenshot_path != null) self.screenshot_elapsed_ms += deltaTimeMs;

        self.syncWindowSize(eng);
        // After syncWindowSize so a font change (which alters cell_w/cell_h
        // and then resizes the window) is only reconciled against the
        // framebuffer on the *next* frame, once both have settled.
        self.handleFontZoom(eng);
        self.reportKeyEvents(eng);
        self.reportTextInput(eng);
        // The scrollbar gets first refusal on the left button: a press or
        // drag that belongs to it is consumed here so `reportMouseEvents`
        // doesn't also forward it to the grid as a click.
        const scrollbar_took_left = self.handleScrollbar(eng);
        self.reportMouseEvents(eng, scrollbar_took_left);
        self.handleArrowKeys(eng, deltaTimeMs);
        self.handleScroll(eng);

        self.tickBlink(deltaTimeMs);

        return true;
    }

    /// Advances the caret's blink phase and resets it whenever the caret
    /// has moved or the window has scrolled since the last tick -- so the
    /// caret shows solid the moment anything happens and resumes blinking
    /// only once it settles. A no-op past the phase advance when
    /// `cursor_blink` is off. Called at the end of `update`, after every
    /// caret-moving path (key forwarding, arrow repeat, scroll) has run.
    fn tickBlink(self: *App, delta_ms: f64) void {
        const now: @TypeOf(self.blink_ref) = blk: {
            self.server.ctx_mutex.lockUncancelable(self.server.io);
            defer self.server.ctx_mutex.unlock(self.server.io);
            const root = &self.server.ctx.root;
            break :blk .{ .row = root.cursor.row, .col = root.cursor.col, .scroll = root.view_scroll };
        };
        if (now.row != self.blink_ref.row or now.col != self.blink_ref.col or now.scroll != self.blink_ref.scroll) {
            self.blink_ref = now;
            self.blink_elapsed_ms = 0;
            return;
        }
        self.blink_elapsed_ms += delta_ms;
    }

    /// Whether the caret should be painted this frame: always, unless
    /// blinking is enabled and the phase clock is in its "off" half.
    fn caretVisible(self: *const App) bool {
        if (!self.cursor_blink) return true;
        const period = self.cursor_blink_ms * 2;
        return @mod(self.blink_elapsed_ms, period) < self.cursor_blink_ms;
    }

    /// How many grid rows one full wheel "tick" (`scroll().y` of magnitude
    /// 1) scrolls the view by -- picked to feel like a normal terminal
    /// scrollback, not tied to any particular OS's wheel step size.
    const scroll_rows_per_tick: f32 = 3.0;

    /// Scrolls the root layer's view back into its scrollback on wheel-up,
    /// forward toward the live tail on wheel-down -- the missing piece
    /// that made `cat`ing anything longer than the window blast straight
    /// past with no way to look back at it (the ring buffer already
    /// retained the history via `Context.createLayer`'s `scrollback_rows`;
    /// nothing ever read it for display). Goes through
    /// `Server.reportScroll`, which owns the clamp to `history_len` and
    /// broadcasts a `scroll` notification so glyphwire-shell stays in sync
    /// -- the wheel, the scrollbar, and glyphwire-shell's browse cursor
    /// all move the same `root.view_scroll` field, which `render` reads
    /// directly each frame.
    fn handleScroll(self: *App, eng: *AppRunner.Engine) void {
        if (!eng.inputs.mouse_enabled) return;
        const dy = eng.inputs.mouse.scroll().y;
        if (dy == 0) return;

        const delta: i64 = @intFromFloat(@round(dy * scroll_rows_per_tick));
        self.server.reportScroll(self.alloc, null, delta) catch |err| {
            std.log.err("glyphwire-host: reportScroll(wheel) failed: {t}", .{err});
        };
    }

    // Scrollbar geometry, in pixels. Always drawn on the window's right
    // edge (per the design decision -- a persistent scroll indicator, not
    // an auto-hiding one). The thumb never shrinks below `scrollbar_min_thumb_px`
    // so it stays grabbable even with a very deep scrollback.
    const scrollbar_width_px: i32 = 12;
    const scrollbar_min_thumb_px: f32 = 24;

    const ScrollbarGeom = struct {
        /// Left edge of the bar in window pixels.
        left: f32,
        track_h: f32,
        thumb_top: f32,
        thumb_h: f32,
    };

    /// Pure geometry: where the scrollbar track and thumb sit for a given
    /// framebuffer size and scroll state. The thumb's *height* is the
    /// visible fraction (`height / (history_len + height)`) of the track;
    /// its *position* runs from flush-bottom at `view_scroll == 0` (live
    /// tail) to flush-top at `view_scroll == history_len` (oldest retained
    /// row).
    fn scrollbarGeom(fb_w: i32, fb_h: i32, history_len: usize, height: usize, view_scroll: usize) ScrollbarGeom {
        const track_h: f32 = @floatFromInt(fb_h);
        const total: f32 = @floatFromInt(history_len + height);
        const view_h: f32 = @floatFromInt(height);

        var thumb_h: f32 = if (total > 0) track_h * (view_h / total) else track_h;
        thumb_h = std.math.clamp(thumb_h, @min(scrollbar_min_thumb_px, track_h), track_h);

        const rows_above_top: f32 = @floatFromInt(history_len - view_scroll);
        const top_frac: f32 = if (total > 0) rows_above_top / total else 0;
        var thumb_top = track_h * top_frac;
        const max_top = @max(track_h - thumb_h, 0);
        thumb_top = std.math.clamp(thumb_top, 0, max_top);

        return .{
            .left = @floatFromInt(fb_w - scrollbar_width_px),
            .track_h = track_h,
            .thumb_top = thumb_top,
            .thumb_h = thumb_h,
        };
    }

    /// Handles the scrollbar's own mouse interaction, before the grid sees
    /// the click. Returns true when the left button this frame belongs to
    /// the scrollbar (a press that landed on the bar, or an in-progress
    /// thumb drag, or the release ending one) -- the caller then tells
    /// `reportMouseEvents` to drop the left button so it isn't also
    /// delivered to glyphwire-shell as a grid click.
    ///
    /// - Press on the thumb: start dragging it (records the grab offset).
    /// - Press on the track above/below the thumb: page the view one
    ///   screenful toward the click.
    /// - Drag: map the pointer to a row offset and push it through
    ///   `Server.reportScroll`.
    fn handleScrollbar(self: *App, eng: *AppRunner.Engine) bool {
        if (!eng.inputs.mouse_enabled) return false;

        const pos = eng.inputs.mouse.pos();
        const fb = eng.window_state.framebuffer_size;

        var history_len: usize = undefined;
        var height: usize = undefined;
        var view_scroll: usize = undefined;
        {
            self.server.ctx_mutex.lockUncancelable(self.server.io);
            defer self.server.ctx_mutex.unlock(self.server.io);
            history_len = self.server.ctx.root.history_len;
            height = self.server.ctx.root.height;
            view_scroll = self.server.ctx.root.view_scroll;
        }
        const geom = scrollbarGeom(fb.x, fb.y, history_len, height, view_scroll);
        const on_bar = pos.x >= geom.left;

        if (eng.inputs.mouse.pressed(.left)) {
            if (!on_bar) return false;
            if (pos.y >= geom.thumb_top and pos.y <= geom.thumb_top + geom.thumb_h) {
                self.scrollbar_drag = true;
                self.scrollbar_grab_dy = pos.y - geom.thumb_top;
            } else {
                // One screenful per track click, toward the pointer.
                const page: i64 = @intCast(@max(height, 2) - 1);
                const delta: i64 = if (pos.y < geom.thumb_top) page else -page;
                self.server.reportScroll(self.alloc, null, delta) catch {};
            }
            return true;
        }

        if (self.scrollbar_drag) {
            if (eng.inputs.mouse.down(.left)) {
                const total: f32 = @floatFromInt(history_len + height);
                const max_top = @max(geom.track_h - geom.thumb_h, 0);
                const thumb_top = std.math.clamp(pos.y - self.scrollbar_grab_dy, 0, max_top);
                const top_frac: f32 = if (geom.track_h > 0) thumb_top / geom.track_h else 0;
                const rows_above_top: i64 = @intFromFloat(@round(top_frac * total));
                const target: i64 = std.math.clamp(
                    @as(i64, @intCast(history_len)) - rows_above_top,
                    0,
                    @as(i64, @intCast(history_len)),
                );
                self.server.reportScroll(self.alloc, @intCast(target), null) catch {};
                return true;
            }
            // Button released -- end the drag and swallow this release.
            self.scrollbar_drag = false;
            return true;
        }

        return false;
    }

    /// Picks up a window resize: converts the current framebuffer size to
    /// a whole-cell grid size (flooring any leftover fractional cell, and
    /// clamping to `min_grid_*`) and, if that differs from the grid the
    /// context currently has, pushes it through `Server.reportResize` --
    /// which resizes the root layer (and every base-size-tracking layer)
    /// bottom-anchored, then broadcasts a `resize` notification to any
    /// subscribed client (e.g. glyphwire-shell). `pixzig`'s
    /// `refreshWindowState` (called each frame by the app runner before
    /// this) has already rebuilt the viewport/projection for the new
    /// framebuffer, so `render` just draws the larger or smaller grid.
    ///
    /// The always-on scrollbar (`scrollbar_width_px`) plus a
    /// `content_pad_px` margin on each side of the grid are subtracted
    /// from the usable width before dividing into cells, so the last
    /// column isn't lost under the bar or the padding. The initial window
    /// (see `main`) is opened that much wider than the grid for the same
    /// reason.
    fn syncWindowSize(self: *App, eng: *AppRunner.Engine) void {
        const fb = eng.window_state.framebuffer_size;
        if (cell_w <= 0 or cell_h <= 0) return;
        const cols: usize = @intCast(@max(@divTrunc(fb.x - 2 * content_pad_px - scrollbar_width_px, cell_w), min_grid_cols));
        const rows: usize = @intCast(@max(@divTrunc(fb.y, cell_h), min_grid_rows));
        if (cols == grid_cols and rows == grid_rows) return;

        self.server.reportResize(self.alloc, cols, rows) catch |err| {
            std.log.err("glyphwire-host: reportResize({d}x{d}) failed: {t}", .{ cols, rows, err });
            return;
        };
        grid_cols = cols;
        grid_rows = rows;
    }

    /// Ctrl+- / Ctrl++ step the font size by `font_size_step` (clamped to
    /// `[min_font_size, max_font_size]`); Ctrl+0 restores the startup size.
    /// The matching keys are held back from `reportKeyEvents` while Ctrl is
    /// down so the shell never sees them.
    fn handleFontZoom(self: *App, eng: *AppRunner.Engine) void {
        const kb = &eng.inputs.keyboard;
        if (!kb.ctrl()) return;

        const target: f32 = if (kb.pressed(.minus) or kb.pressed(.kp_subtract))
            @max(min_font_size, self.font_size - font_size_step)
        else if (kb.pressed(.equal) or kb.pressed(.kp_add))
            @min(max_font_size, self.font_size + font_size_step)
        else if (kb.pressed(.zero) or kb.pressed(.kp_0))
            self.initial_font_size
        else
            return;

        if (target == self.font_size) return;
        self.applyFontSize(eng, target);
    }

    /// Repacks the default font atlas at `size_px`, re-measures the cell
    /// metrics from the same face, updates `cell_w`/`cell_h` and the
    /// RPC-visible `ctx.cell_px_*`, and resizes the window so the current
    /// `grid_cols` x `grid_rows` still fits. Any step failing leaves the
    /// previous size in place.
    fn applyFontSize(self: *App, eng: *AppRunner.Engine, size_px: f32) void {
        const fa = eng.defaultFontAtlas() orelse {
            std.log.warn("glyphwire-host: no resizable default font atlas", .{});
            return;
        };

        // Measure first: if this fails we haven't touched the live atlas.
        const metrics = pixzig.renderer.measureFontFileIndexed(
            self.font_path,
            self.font_face_index,
            size_px,
            self.alloc,
        ) catch |err| {
            std.log.err("glyphwire-host: re-measuring font at {d}px failed: {t}", .{ size_px, err });
            return;
        };

        fa.setFontSize(size_px) catch |err| {
            std.log.err("glyphwire-host: font atlas resize to {d}px failed: {t}", .{ size_px, err });
            return;
        };

        self.font_size = size_px;
        cell_w = metrics.advance;
        cell_h = metrics.line_height;

        // Keep the metrics clients query via `get_cell_metrics` (e.g.
        // glyphwire-shell sizing an image) in step. `ctx_mutex`-guarded
        // like every other host write to `ctx`. Already-connected clients
        // are not proactively notified of a cell-size change.
        self.server.ctx_mutex.lockUncancelable(self.server.io);
        self.server.ctx.cell_px_w = @intCast(cell_w);
        self.server.ctx.cell_px_h = @intCast(cell_h);
        self.server.ctx_mutex.unlock(self.server.io);

        self.resizeWindowForCells(eng);
    }

    /// Resizes the OS window so a framebuffer of exactly
    /// `grid_cols` x `grid_rows` cells (plus the scrollbar and side
    /// padding) fits -- the inverse of `syncWindowSize`'s cell math, so it
    /// round-trips back to the same cell counts next frame with no
    /// `reportResize`. The framebuffer -> window ratio handles HiDPI;
    /// `divCeil` biases the window up so rounding never drops a cell. A
    /// tiling WM that ignores the request just leaves `syncWindowSize` to
    /// reflow the grid to whatever size it forces instead.
    fn resizeWindowForCells(self: *App, eng: *AppRunner.Engine) void {
        _ = self;
        const ws = &eng.window_state;
        const fb = ws.framebuffer_size;
        if (fb.x <= 0 or fb.y <= 0 or ws.window_size.x <= 0 or ws.window_size.y <= 0) return;

        const target_fb_w = @as(i32, @intCast(grid_cols)) * cell_w + 2 * content_pad_px + scrollbar_width_px;
        const target_fb_h = @as(i32, @intCast(grid_rows)) * cell_h;

        const win_w = std.math.divCeil(i32, target_fb_w * ws.window_size.x, fb.x) catch return;
        const win_h = std.math.divCeil(i32, target_fb_h * ws.window_size.y, fb.y) catch return;
        eng.window.setSize(win_w, win_h);
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
    ///
    /// The eight physical modifier keys (`left_control`, `right_alt`, ...)
    /// are not forwarded by name from this loop. Each modifier is instead
    /// forwarded once, under its `left_*` name, from pixzig's logical
    /// modifier state (`keyboard.ctrl()` / `.alt()` / `.shift()` /
    /// `.super()`) via `reportModifier`. That state already folds the left
    /// and right physical keys together, and also picks up OS-level
    /// modifier remaps -- e.g. CapsLock acting as Control -- which never
    /// arrive as a physical modifier-key press. Consequence: a held right
    /// modifier shows up in `get_input_state` as `left_control` etc., not
    /// `right_control`; nothing in glyphwire distinguishes the two.
    fn reportKeyEvents(self: *App, eng: *AppRunner.Engine) void {
        const kb = &eng.inputs.keyboard;

        self.reportModifier(0, "left_control", kb.ctrl());
        self.reportModifier(1, "left_alt", kb.alt());
        self.reportModifier(2, "left_shift", kb.shift());
        self.reportModifier(3, "left_super", kb.super());

        const ctrl_held = kb.ctrl();
        const fields = @typeInfo(pixzig.glfw.Key).@"enum".fields;
        inline for (fields) |field| {
            const key = @field(pixzig.glfw.Key, field.name);
            const skip = switch (key) {
                // Forwarded by reportModifier above, not per physical key.
                .left_control, .right_control, .left_alt, .right_alt, .left_shift, .right_shift, .left_super, .right_super => true,
                // Ctrl + these are `handleFontZoom`'s shortcuts; swallow
                // them here so the shell/grid never sees the keystroke.
                .minus, .equal, .zero, .kp_subtract, .kp_add, .kp_0 => ctrl_held,
                else => false,
            };
            if (skip) {
                // Consumed elsewhere; don't forward it.
            } else if (kb.pressed(key)) {
                self.server.reportKey(self.alloc, field.name, true) catch |err| {
                    std.log.err("reportKey({s}, true) failed: {t}", .{ field.name, err });
                };
            } else if (kb.released(key)) {
                self.server.reportKey(self.alloc, field.name, false) catch |err| {
                    std.log.err("reportKey({s}, false) failed: {t}", .{ field.name, err });
                };
            }
        }
    }

    /// Forwards one modifier's down/up state under `name`, edge-detected
    /// against `mod_forwarded[idx]` so the in-process `Server` only sees a
    /// notification when it actually changes. `active` comes from pixzig's
    /// logical modifier query (see `reportKeyEvents`).
    fn reportModifier(self: *App, idx: usize, name: []const u8, active: bool) void {
        if (active == self.mod_forwarded[idx]) return;
        self.mod_forwarded[idx] = active;
        self.server.reportKey(self.alloc, name, active) catch |err| {
            std.log.err("reportKey({s}, {}) failed: {t}", .{ name, active, err });
        };
    }

    /// Forwards the text the user actually typed this frame as a `text`
    /// notification -- pixzig's `keyboard.text()` drains GLFW's char
    /// callback, so this is already resolved through the OS keyboard
    /// layout, dead keys and IME composition (a QWERTZ 'z', an AZERTY
    /// AltGr '@', a committed CJK grapheme). This is a separate stream
    /// from `reportKeyEvents`: a key event still fires for the same
    /// keystroke, carrying the physical key name for chords/navigation,
    /// but the character comes from here. glyphwire-shell's prompt inserts
    /// from `text` events and ignores the key event for plain typing, so
    /// there's no double-insertion.
    ///
    /// The 256-byte buffer bounds one frame's worth of committed text;
    /// pixzig caps its own per-frame codepoint buffer well below that.
    fn reportTextInput(self: *App, eng: *AppRunner.Engine) void {
        var buf: [256]u8 = undefined;
        const n = eng.inputs.keyboard.text(&buf);
        if (n == 0) return;
        self.server.reportText(self.alloc, buf[0..n]) catch |err| {
            std.log.err("reportText failed: {t}", .{err});
        };
    }

    /// `skip_left` drops the left button for this frame -- set when
    /// `handleScrollbar` already consumed it (a scrollbar press, drag, or
    /// release), so the same click isn't also delivered to glyphwire-shell
    /// as a grid click. Mouse *move* reporting is unaffected.
    ///
    /// The `view_offset` passed alongside each button is the root layer's
    /// current scrollback view offset, so a click made while scrolled back
    /// carries enough context for glyphwire-shell to resolve it against
    /// the row actually under the pointer (see `Client.getMetadata`).
    fn reportMouseEvents(self: *App, eng: *AppRunner.Engine, skip_left: bool) void {
        if (!eng.inputs.mouse_enabled) return;
        const pos = eng.inputs.mouse.pos();
        const cell = cellFromPixel(pos.x, pos.y);

        if (pos.x != self.last_mouse_px.x or pos.y != self.last_mouse_px.y) {
            self.last_mouse_px = pos;
            self.server.reportMouseMove(.{ .x = pos.x, .y = pos.y }, cell);
        }

        const view_offset = blk: {
            self.server.ctx_mutex.lockUncancelable(self.server.io);
            defer self.server.ctx_mutex.unlock(self.server.io);
            break :blk self.server.ctx.root.view_scroll;
        };

        const fields = @typeInfo(pixzig.glfw.MouseButton).@"enum".fields;
        inline for (fields) |field| {
            const btn = @field(pixzig.glfw.MouseButton, field.name);
            const is_left = btn == .left;
            if (!(skip_left and is_left)) {
                if (eng.inputs.mouse.pressed(btn)) {
                    self.server.reportMouseButton(self.alloc, field.name, true, .{ .x = pos.x, .y = pos.y }, cell, view_offset) catch |err| {
                        std.log.err("reportMouseButton({s}, true) failed: {t}", .{ field.name, err });
                    };
                } else if (eng.inputs.mouse.released(btn)) {
                    self.server.reportMouseButton(self.alloc, field.name, false, .{ .x = pos.x, .y = pos.y }, cell, view_offset) catch |err| {
                        std.log.err("reportMouseButton({s}, false) failed: {t}", .{ field.name, err });
                    };
                }
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
    ///
    /// Each layer is drawn in full (all of `renderLayer`'s passes) before
    /// the next one starts, so a popup with an opaque background still
    /// fully covers the layer beneath it. The scrollbar is a final pass on
    /// top of every layer.
    pub fn render(self: *App, eng: *AppRunner.Engine) void {
        eng.renderer.clear(0.0, 0.0, 0.0, 1.0);

        {
            self.server.ctx_mutex.lockUncancelable(self.server.io);
            defer self.server.ctx_mutex.unlock(self.server.io);

            self.renderLayer(eng, &self.server.ctx.root, content_pad_px, 0, true, self.server.ctx.root.view_scroll);
            for (self.server.ctx.layer_order.items) |handle| {
                const layer = self.server.ctx.layers.getPtr(handle) orelse continue;
                self.renderLayer(
                    eng,
                    layer,
                    @as(i32, @intFromFloat(@round(layer.pos.x))) + content_pad_px,
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
        if (self.screenshot_path) |path| {
            if (!self.screenshot_done and self.screenshot_elapsed_ms >= self.screenshot_delay_ms) {
                self.captureContentArea(eng, path);
                self.screenshot_done = true;
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
    fn captureContentArea(self: *App, eng: *AppRunner.Engine, path: []const u8) void {
        const gl = pixzig.gl;
        const fb = eng.window_state.framebuffer_size;
        // The grid starts one margin in from the left; it fills the full
        // window height. Clamp to the live framebuffer in case a resize
        // made it smaller than the initial `grid_cols * cell_w`.
        const x0: i32 = content_pad_px;
        const w: i32 = @min(@as(i32, @intCast(grid_cols)) * cell_w, fb.x - App.scrollbar_width_px - 2 * content_pad_px);

        // Crop the height to the rows actually written (root cursor row
        // plus one trailing blank line), so a mostly-empty grid doesn't
        // produce a screenshot that's mostly black. Floored so a very
        // short result still has some breathing room.
        var used_rows: usize = min_grid_rows;
        {
            self.server.ctx_mutex.lockUncancelable(self.server.io);
            defer self.server.ctx_mutex.unlock(self.server.io);
            used_rows = @max(min_grid_rows, self.server.ctx.root.cursor.row + 2);
        }
        used_rows = @min(used_rows, grid_rows);
        const h: i32 = @min(@as(i32, @intCast(used_rows)) * cell_h, fb.y);
        if (w <= 0 or h <= 0) {
            std.log.warn("glyphwire-host: screenshot region is empty ({d}x{d}), skipping", .{ w, h });
            return;
        }

        const uw: usize = @intCast(w);
        const uh: usize = @intCast(h);
        const row_bytes = uw * 4;

        const pixels = self.alloc.alloc(u8, uh * row_bytes) catch |err| {
            std.log.err("glyphwire-host: screenshot buffer alloc failed: {t}", .{err});
            return;
        };
        defer self.alloc.free(pixels);

        gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
        // glReadPixels' origin is the framebuffer's bottom-left, but the
        // grid is drawn from the top down, so read the *top* `h` rows:
        // start `h` pixels up from the bottom.
        gl.readPixels(x0, fb.y - h, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);

        // GL returns rows bottom-to-top; flip so the PNG reads top-to-bottom
        // (same swap `pixzig`'s own `captureScreenshot` does).
        const tmp = self.alloc.alloc(u8, row_bytes) catch return;
        defer self.alloc.free(tmp);
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
        const path_z = self.alloc.dupeZ(u8, path) catch return;
        defer self.alloc.free(path_z);
        img.writeToFile(path_z, .png) catch |err| {
            std.log.err("glyphwire-host: screenshot write to '{s}' failed: {t}", .{ path, err });
            return;
        };
        std.log.info("glyphwire-host: wrote screenshot {s} ({d}x{d})", .{ path, uw, uh });
    }

    /// Draws the always-on scrollbar over the right edge: a dark track the
    /// full window height with a lighter thumb whose size and position
    /// reflect the root layer's scrollback (`history_len`) and current
    /// view offset (`view_scroll`) -- see `scrollbarGeom`. Called in its
    /// own render pass (see `render`) so it composites over every layer,
    /// text included; `handleScrollbar` owns the interaction. Takes its
    /// own short `ctx_mutex` snapshot rather than relying on `render`'s
    /// lock, which is released by the time this second pass runs.
    fn renderScrollbar(self: *App, eng: *AppRunner.Engine) void {
        const fb = eng.window_state.framebuffer_size;
        var history_len: usize = undefined;
        var height: usize = undefined;
        var view_scroll: usize = undefined;
        {
            self.server.ctx_mutex.lockUncancelable(self.server.io);
            defer self.server.ctx_mutex.unlock(self.server.io);
            history_len = self.server.ctx.root.history_len;
            height = self.server.ctx.root.height;
            view_scroll = self.server.ctx.root.view_scroll;
        }
        const geom = scrollbarGeom(fb.x, fb.y, history_len, height, view_scroll);

        eng.renderer.drawFilledRect(
            pixzig.RectF.fromPosSize(@as(i32, @intFromFloat(geom.left)), 0, scrollbar_width_px, fb.y),
            pixzig.Color.from(28, 28, 32, 255),
        );
        eng.renderer.drawFilledRect(
            pixzig.RectF{
                .l = geom.left + 2,
                .t = geom.thumb_top,
                .r = geom.left + @as(f32, @floatFromInt(scrollbar_width_px)) - 2,
                .b = geom.thumb_top + geom.thumb_h,
            },
            pixzig.Color.from(120, 120, 130, 255),
        );
    }

    /// Which category of a cell's contents one `renderLayer` pass draws.
    /// The passes run in this declared order, each inside its own flushed
    /// `begin`/`end` -- see `renderLayer`.
    const Pass = enum { color_bg, image_bg, icons, text };

    /// Draws one layer's visible viewport with its top-left cell at
    /// `(origin_x, origin_y)` in screen pixels -- shared by `render` for
    /// the root layer (origin `(0, 0)`) and every other layer (origin its
    /// own `pos`, rounded to the nearest pixel). `view_offset` is the
    /// scrollback view offset to render (see `glyphwire.Layer.view_scroll`)
    /// -- always 0 for non-root layers, which don't expose scrollback
    /// viewing.
    fn renderLayer(self: *App, eng: *AppRunner.Engine, layer: *const glyphwire.Layer, origin_x: i32, origin_y: i32, draw_cursor: bool, view_offset: usize) void {
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

            var row: usize = 0;
            while (row < layer.height) : (row += 1) {
                const row_cells = layer.viewRow(view_offset, row);
                var col: usize = 0;
                while (col < layer.width) : (col += 1) {
                    const pos = pixzig.Vec2I{
                        .x = origin_x + @as(i32, @intCast(col)) * cell_w,
                        .y = origin_y + @as(i32, @intCast(row)) * cell_h,
                    };
                    self.drawCell(eng, &row_cells[col], pos, pass);
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

            eng.renderer.end();
        }

        // Cursor caret, in its own flushed pass so it sits on top of the
        // text just drawn (a filled rect in the text pass would be
        // submitted before the text batch and hidden by it). Shape and
        // blink come from `assets/conf.lua` (see `CursorConfig`). Drawn
        // whatever the scrollback offset -- glyphwire-shell's keyboard
        // browse moves this same grid cursor onto a visible scrolled-back
        // row, and the caret has to follow it there (a pure wheel scroll
        // just leaves the caret at the live prompt's grid cell).
        if (draw_cursor and self.caretVisible() and layer.cursor.row < layer.height and layer.cursor.col < layer.width) {
            eng.renderer.begin(eng.projMat);
            self.drawCaret(eng, layer, origin_x, origin_y, view_offset);
            eng.renderer.end();
        }
    }

    /// Paints the caret for `layer` at its current grid cursor. `block`,
    /// `box`, and `underline` cover the whole cell -- two cells when the
    /// cursor sits on the lead of a wide (CJK) character -- while `line`
    /// stays a thin bar at the cell's left edge regardless. Assumes an
    /// open renderer pass (see the caller).
    fn drawCaret(self: *const App, eng: *AppRunner.Engine, layer: *const glyphwire.Layer, origin_x: i32, origin_y: i32, view_offset: usize) void {
        const white = pixzig.Color.from(255, 255, 255, 255);
        const cx = origin_x + @as(i32, @intCast(layer.cursor.col)) * cell_w;
        const cy = origin_y + @as(i32, @intCast(layer.cursor.row)) * cell_h;

        const on_wide_lead = layer.viewRow(view_offset, layer.cursor.row)[layer.cursor.col].wide == .wide_lead;
        const cell_span: i32 = if (on_wide_lead) cell_w * 2 else cell_w;

        switch (self.cursor_shape) {
            .line => eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(cx, cy, cursor_width, cell_h),
                white,
            ),
            .block => eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(cx, cy, cell_span, cell_h),
                white,
            ),
            .box => eng.renderer.drawRect(
                pixzig.RectF.fromPosSize(cx, cy, cell_span, cell_h),
                white,
                cursor_box_line_px,
            ),
            .underline => eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(cx, cy + cell_h - cursor_underline_px, cell_span, cursor_underline_px),
                white,
            ),
        }
    }

    /// Draws the part of cell `c` (top-left corner at `pos`) that belongs
    /// to render pass `pass`. Called once per cell per pass by
    /// `renderLayer`; see that function for why the passes are separated.
    fn drawCell(self: *App, eng: *AppRunner.Engine, c: *const glyphwire.Cell, pos: pixzig.Vec2I, pass: Pass) void {
        switch (pass) {
            .color_bg => switch (c.style.bg) {
                .color => |bg| {
                    if (bg.r != 0 or bg.g != 0 or bg.b != 0) {
                        eng.renderer.drawFilledRect(
                            pixzig.RectF.fromPosSize(pos.x, pos.y, cell_w, cell_h),
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

    /// Draws `icon` at `pos` now, or -- when `icon.scale == .natural`,
    /// which can overflow past the cell into cells not yet reached --
    /// defers it onto `deferred_icons` for `renderLayer` to draw after the
    /// grid. `.fit`/`.stretch` never overflow, so they draw in place.
    fn queueOrDrawIcon(self: *App, eng: *AppRunner.Engine, icon: glyphwire.IconBg, pos: pixzig.Vec2I, foreground: bool) void {
        if (icon.scale == .natural) {
            self.deferred_icons.append(self.alloc, .{ .icon = icon, .pos = pos, .foreground = foreground }) catch {};
        } else {
            self.drawIconCell(eng, icon, pos, foreground);
        }
    }
};

/// Converts a pixel position (window-local, matching what
/// `eng.inputs.mouse.pos()` reports since host doesn't set a scaled
/// `logicalSize`) to a grid cell position, clamped to the grid bounds.
/// Subtracts `content_pad_px` first, since the layers are composited
/// shifted right by that much (see `render`); a click in the thin left
/// margin just clamps to column 0.
fn cellFromPixel(x: f32, y: f32) glyphwire.CellPos {
    const col_f = (x - @as(f32, @floatFromInt(content_pad_px))) / @as(f32, @floatFromInt(cell_w));
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

        const handle = ctx.loadImage(.png, bytes) catch |err| {
            std.log.warn("glyphwire-host: couldn't load icon '{s}': {t}", .{ entry.name, err });
            continue;
        };
        ctx.registerIcon(entry.name, handle) catch |err| {
            std.log.warn("glyphwire-host: couldn't register icon '{s}': {t}", .{ entry.name, err });
        };
    }
}

/// Reads a string field named `key` from the `config` table on the Lua
/// stack top and returns a process-lifetime (`arena`) copy of it, or null
/// when the field is absent or not a string. The table stays on the stack;
/// only the field value pushed here is popped.
fn luaStrField(lua: *pixzig.ziglua.Lua, arena: std.mem.Allocator, key: [:0]const u8) ?[:0]const u8 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isString(-1)) return null;
    const s = lua.toString(-1) catch return null;
    return arena.dupeZ(u8, s) catch null;
}

/// Like `luaStrField`, for a numeric field.
fn luaNumField(lua: *pixzig.ziglua.Lua, key: [:0]const u8) ?f32 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isNumber(-1)) return null;
    const n = lua.toNumber(-1) catch return null;
    return @floatCast(n);
}

/// Like `luaStrField`, for a boolean field. Absent or non-boolean -> null.
fn luaBoolField(lua: *pixzig.ziglua.Lua, key: [:0]const u8) ?bool {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isBoolean(-1)) return null;
    return lua.toBoolean(-1);
}

/// Maps `config.cursor_shape`'s string to a `CursorShape`, or null for an
/// unrecognized value (the caller warns and keeps the default).
fn cursorShapeFromStr(s: []const u8) ?CursorShape {
    return std.meta.stringToEnum(CursorShape, s);
}

/// Resolves everything `assets/conf.lua` controls for this run: starts
/// from the `*_default` constants and overlays whatever the global
/// `config` table sets -- font fields (`font_face`, `font_face_name`,
/// `font_fallback`, `font_size`) and caret fields (`cursor_shape`,
/// `cursor_blink`, `cursor_blink_ms`), any subset. A missing file is the
/// normal case and is silent; a file that fails to read/parse, or a
/// `config` that isn't a table, logs a warning and the defaults stand.
/// `font_size` is clamped to `[min_font_size, max_font_size]` and
/// `cursor_blink_ms` to `[cursor_blink_ms_min, cursor_blink_ms_max]`.
/// `gpa` is used only for transient work (the source buffer, the Lua
/// state); returned strings are `arena`-allocated so they outlive this call.
fn loadConfig(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) HostConfig {
    var cfg: HostConfig = .{};

    const src = std.Io.Dir.cwd().readFileAlloc(io, conf_lua_path, gpa, .limited(256 * 1024)) catch |err| {
        if (err != error.FileNotFound)
            std.log.warn("glyphwire-host: couldn't read {s} ({t}); using defaults", .{ conf_lua_path, err });
        return cfg;
    };
    defer gpa.free(src);
    const src_z = gpa.dupeZ(u8, src) catch return cfg;
    defer gpa.free(src_z);

    var eng = pixzig.scripting.ScriptEngine.init(gpa) catch |err| {
        std.log.warn("glyphwire-host: Lua init failed ({t}); using defaults", .{err});
        return cfg;
    };
    defer eng.deinit();

    eng.run(src_z) catch |err| {
        std.log.warn("glyphwire-host: {s} failed to run ({t}); using defaults", .{ conf_lua_path, err });
        return cfg;
    };

    const lua = eng.lua;
    _ = lua.getGlobal("config") catch return cfg;
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        std.log.warn("glyphwire-host: {s} defines no `config` table; using defaults", .{conf_lua_path});
        return cfg;
    }

    if (luaStrField(lua, arena, "font_face")) |v| cfg.font.face = v;
    if (luaStrField(lua, arena, "font_face_name")) |v| cfg.font.face_name = v;
    if (luaStrField(lua, arena, "font_fallback")) |v| cfg.font.fallback = v;
    if (luaNumField(lua, "font_size")) |v| cfg.font.size = v;

    const clamped = std.math.clamp(cfg.font.size, min_font_size, max_font_size);
    if (clamped != cfg.font.size) {
        std.log.warn("glyphwire-host: conf.lua font_size {d} out of range; clamped to {d}", .{ cfg.font.size, clamped });
        cfg.font.size = clamped;
    }

    if (luaStrField(lua, arena, "cursor_shape")) |v| {
        if (cursorShapeFromStr(v)) |shape| {
            cfg.cursor.shape = shape;
        } else {
            std.log.warn("glyphwire-host: conf.lua cursor_shape '{s}' unknown; keeping '{t}'", .{ v, cfg.cursor.shape });
        }
    }
    if (luaBoolField(lua, "cursor_blink")) |v| cfg.cursor.blink = v;
    if (luaNumField(lua, "cursor_blink_ms")) |v| {
        cfg.cursor.blink_ms = std.math.clamp(@as(f64, v), cursor_blink_ms_min, cursor_blink_ms_max);
        if (cfg.cursor.blink_ms != v)
            std.log.warn("glyphwire-host: conf.lua cursor_blink_ms {d} out of range; clamped to {d}", .{ v, cfg.cursor.blink_ms });
    }

    return cfg;
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

    // Host-only options are pulled out here; everything else is forwarded
    // to glyphwire-shell (an empty forward list = the shell's own
    // interactive prompt, its no-args mode, rather than exec'ing a child).
    //   --screenshot <path>          write the grid region to <path> (PNG) then quit
    //   --screenshot-delay-ms <n>    wait n ms before capturing (default 2500)
    //   --grid-cols <n> / --grid-rows <n>   open at a non-default grid size
    //                                (handy for a screenshot whose output is
    //                                taller/wider than the default 120x50)
    var screenshot_path: ?[]const u8 = null;
    var screenshot_delay_ms: f64 = 2500;
    var forwarded: std.ArrayList([]const u8) = .empty;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--screenshot") and i + 1 < args.len) {
                i += 1;
                screenshot_path = args[i];
            } else if (std.mem.eql(u8, a, "--screenshot-delay-ms") and i + 1 < args.len) {
                i += 1;
                screenshot_delay_ms = std.fmt.parseFloat(f64, args[i]) catch screenshot_delay_ms;
            } else if (std.mem.eql(u8, a, "--grid-cols") and i + 1 < args.len) {
                i += 1;
                grid_cols = @max(min_grid_cols, std.fmt.parseInt(usize, args[i], 10) catch grid_cols);
            } else if (std.mem.eql(u8, a, "--grid-rows") and i + 1 < args.len) {
                i += 1;
                grid_rows = @max(min_grid_rows, std.fmt.parseInt(usize, args[i], 10) catch grid_rows);
            } else {
                try forwarded.append(arena, a);
            }
        }
    }
    const shell_child_argv: []const []const u8 = forwarded.items;

    const socket_path = try socketPath(arena, init.environ_map);

    // Font face/size/fallback and caret shape/blink: `assets/conf.lua` if
    // present, else the `*_default` constants at the top of this file.
    const host_cfg = loadConfig(arena, alloc, io);
    const font_cfg = host_cfg.font;

    // The primary font may be a `.ttc` collection; find the index of the
    // named face inside it so both the metrics measured here and the atlas
    // packed later (in AppRunner.init) use the same face. A plain `.ttf`
    // has no named faces, so this falls through to face 0.
    const font_face_index: i32 = blk: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, font_cfg.face, alloc, .limited(64 * 1024 * 1024)) catch |err| {
            std.log.err("failed to read font '{s}': {t}", .{ font_cfg.face, err });
            return err;
        };
        defer alloc.free(bytes);
        break :blk pixzig.renderer.findFaceIndexByName(bytes, font_cfg.face_name) orelse 0;
    };

    // Measuring metrics needs only the font's own bytes (stb_truetype's
    // InitFont/GetFontVMetrics/GetCodepointHMetrics), not a GL context, so
    // this can run before the window exists -- unlike packing the font into
    // an atlas texture, which does need one (see AppRunner.init below).
    // That means the window can be sized correctly for whatever font is
    // configured instead of a size tuned by hand for one specific font.
    const metrics = try pixzig.renderer.measureFontFileIndexed(font_cfg.face, font_face_index, font_cfg.size, alloc);
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
        .windowSize = .{
            // Open wide enough for all `grid_cols` cells *plus* the
            // always-on scrollbar and a `content_pad_px` margin on each
            // side of the grid (see `syncWindowSize`, which subtracts the
            // same back out when converting a resize to cells).
            .x = @as(i32, @intCast(grid_cols)) * cell_w + 2 * content_pad_px + App.scrollbar_width_px,
            .y = @as(i32, @intCast(grid_rows)) * cell_h,
        },
        .resizable = true,
        .renderInitOpts = .{ .font = .{ .path = .{ .face = font_cfg.face, .size = font_cfg.size, .face_index = font_face_index } } },
    });

    // Register the fallback face: codepoints the primary lacks are drawn
    // from it, and anything neither face has renders as the atlas's tofu
    // box. Non-fatal -- text still works from the primary alone.
    appRunner.engine.renderer.addDefaultFontFallback(&appRunner.engine.resources, font_cfg.fallback, 0) catch |err| {
        std.log.warn("could not add fallback font '{s}': {t}", .{ font_cfg.fallback, err });
    };

    // And a bundled Powerline-symbols subset (U+E0A0-E0D7) as a further
    // fallback, so a configured powerline shell prompt's separator /
    // rounded-cap glyphs render even though neither the CJK primary nor a
    // plain-Latin fallback covers that Private Use range.
    appRunner.engine.renderer.addDefaultFontFallback(&appRunner.engine.resources, powerline_symbols_font, 0) catch |err| {
        std.log.warn("could not add powerline symbols font '{s}': {t}", .{ powerline_symbols_font, err });
    };

    const app = try App.init(alloc, appRunner.engine, &srv, &shell_exited, screenshot_path, screenshot_delay_ms, .{
        .path = font_cfg.face,
        .face_index = font_face_index,
        .size = font_cfg.size,
    }, host_cfg.cursor);

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
