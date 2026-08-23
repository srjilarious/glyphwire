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
const font_size: f32 = 18.0;
// Tuned for JetBrainsMono-Regular at font_size (unitsPerEm 1000, advance
// 600, ascent+|descent| 1320): advance*font_size/1000 and
// lineHeight*font_size/1000, rounded. Not measured at runtime because the
// window (and thus the framebuffer the font gets packed for) has to be
// created before a font atlas exists to measure -- see the comment on
// AppRunner.init below.
const cell_w = 12;
const cell_h = 12;
const cursor_width = 2;

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
    image_textures: std.AutoHashMap(glyphwire.ImageHandle, pixzig.Texture),
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
            .image_textures = std.AutoHashMap(glyphwire.ImageHandle, pixzig.Texture).init(alloc),
            .shell_exited = shell_exited,
        };
        return app;
    }

    pub fn deinit(self: *App) void {
        self.image_textures.deinit();
        self.alloc.destroy(self);
    }

    /// Returns the uploaded texture for `handle`, decoding and uploading it
    /// first if this is the first time this App has seen it -- see
    /// `image_textures`'s doc comment. Null if `handle` isn't in
    /// `ctx.images` (shouldn't happen: `draw_image` already validated the
    /// handle before marking a cell with it) or decoding the stored bytes
    /// fails.
    fn textureForImage(self: *App, eng: *AppRunner.Engine, handle: glyphwire.ImageHandle) ?pixzig.Texture {
        if (self.image_textures.get(handle)) |tex| return tex;

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
        const tex = (managed.get() orelse return null).val;

        self.image_textures.put(handle, tex) catch {};
        return tex;
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

        var tex = self.textureForImage(eng, img.handle) orelse return;

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
            &tex,
            pixzig.RectF.fromPosSize(pos.x, pos.y, avail_w, avail_h),
            pixzig.RectF{ .l = uv_l, .t = uv_t, .r = uv_r, .b = uv_b },
        );
    }

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

    /// Reads the root layer's cells straight out of the in-process
    /// `Context` -- no `get_property`/`get_cells` round trip, and nothing
    /// to skip-if-unchanged: a direct read is cheap enough to just do every
    /// frame. `ctx_mutex` is the same lock `Server` takes around dispatch
    /// for connected clients (e.g. glyphwire-shell's `write_text` calls),
    /// so this can't race a concurrent write.
    pub fn render(self: *App, eng: *AppRunner.Engine) void {
        eng.renderer.clear(0.0, 0.0, 0.0, 1.0);
        eng.renderer.begin(eng.projMat);

        self.server.ctx_mutex.lockUncancelable(self.server.io);
        defer self.server.ctx_mutex.unlock(self.server.io);

        const layer = &self.server.ctx.root;
        var row: usize = 0;
        while (row < layer.height) : (row += 1) {
            var col: usize = 0;
            while (col < layer.width) : (col += 1) {
                const c = layer.cell(row, col);
                const pos = pixzig.Vec2I{
                    .x = @as(i32, @intCast(col)) * cell_w,
                    .y = @as(i32, @intCast(row)) * cell_h,
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
                }

                const g = c.grapheme();
                if (g.len > 0) {
                    _ = eng.renderer.drawStringColored(g, pos, pixzig.Color.from(c.style.fg.r, c.style.fg.g, c.style.fg.b, c.style.fg.a));
                }
            }
        }

        // Cursor caret: a solid bar at the start (left edge) of the
        // cursor's cell, drawn last so it sits on top of that cell's own
        // background/glyph.
        if (layer.cursor.row < layer.height and layer.cursor.col < layer.width) {
            const cx = @as(i32, @intCast(layer.cursor.col)) * cell_w;
            const cy = @as(i32, @intCast(layer.cursor.row)) * cell_h;
            eng.renderer.drawFilledRect(
                pixzig.RectF.fromPosSize(cx, cy, cursor_width, cell_h),
                pixzig.Color.from(255, 255, 255, 255),
            );
        }

        eng.renderer.end();
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
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);

    // With no explicit command, default to glyphwire-shell's own
    // interactive prompt (its no-args mode) rather than exec'ing into a
    // specific child.
    const shell_child_argv: []const []const u8 = if (args.len >= 2) args[1..] else &.{};

    const socket_path = try socketPath(alloc, init.environ_map);

    var ctx = try glyphwire.Context.init(alloc, grid_cols, grid_rows, scrollback_rows);
    defer ctx.deinit();
    // Context.init defaults these to 12x12 already; set explicitly so they
    // stay tied to this file's own cell_w/cell_h constants rather than
    // silently relying on the default matching -- see Context's doc
    // comment on cell_px_w/cell_px_h.
    ctx.cell_px_w = cell_w;
    ctx.cell_px_h = cell_h;
    loadIconManifest(io, alloc, &ctx, &glyphwire.default_icon_manifest);
    loadIconManifest(io, alloc, &ctx, &glyphwire.default_box_manifest);

    // `.listen()` inside `bind` is synchronous -- the socket is already
    // accept-ready (kernel-queued, even before `serveForever`'s thread
    // starts calling `accept`) by the time this returns, so unlike the
    // old separate-process design, glyphwire-shell can be spawned right
    // below with no wait-for-socket-ready polling loop needed.
    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    _ = try std.Thread.spawn(.{}, serveForeverThread, .{ &srv, alloc });

    var shell_env = try init.environ_map.clone(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try shell_env.put("GLYPHWIRE_CTX", glyphwire.default_context_id);

    const shell_path = try resolveSibling(alloc, io, "glyphwire-shell");
    const shell_argv = try std.mem.concat(alloc, []const u8, &.{ &.{shell_path}, shell_child_argv });

    // Left false (no other way to quit) if the spawn itself fails --
    // an edge case not worth a fallback keybinding for.
    var shell_exited: std.atomic.Value(bool) = .init(false);
    if (std.process.spawn(io, .{ .argv = shell_argv, .environ_map = &shell_env })) |shell_child| {
        _ = try std.Thread.spawn(.{}, reapChild, .{ io, shell_child, &shell_exited });
    } else |err| {
        std.log.err("failed to spawn glyphwire-shell: {t}", .{err});
    }

    // Font atlas packing needs a GL context, which needs the window created
    // first -- so cell_w/cell_h above are tuned constants rather than a
    // runtime measurement of the loaded font, avoiding a chicken-and-egg
    // dependency between window size and font metrics.
    const appRunner = try AppRunner.init("glyphwire", alloc, .{
        .windowSize = .{ .x = grid_cols * cell_w, .y = grid_rows * cell_h },
        .resizable = false,
        .renderInitOpts = .{ .font = .{ .path = .{ .face = "assets/JetBrainsMono-Regular.ttf", .size = font_size } } },
    });
    const app = try App.init(alloc, appRunner.engine, &srv, &shell_exited);

    appRunner.run(app);
}
