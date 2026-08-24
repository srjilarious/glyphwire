const std = @import("std");
const glyphwire = @import("glyphwire");
const pixzig = @import("pixzig");

pub const panic = pixzig.system.panic;
pub const std_options = pixzig.system.std_options;

/// glyphwire-shell: the pixzig-windowed glyphwire renderer (Milestone 8 --
/// see docs/slice_plan.md). Owns a `Context` directly and renders it every
/// frame, rather than going through the wire protocol -- see
/// docs/decisions.md, which flags reading a layer's cells back over the
/// socket as an unbuilt open item. Running the socket `Server` in the same
/// process on a background thread means other client programs (spawned
/// below, or launched independently against the same GLYPHWIRE_SOCK) still
/// connect exactly as before; only this process's own render loop gets a
/// shortcut straight to the shared `Context`.
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

const EngOptions: pixzig.PixzigEngineOptions = .{
    .rendererOpts = .{ .textRendering = true },
};
const AppRunner = pixzig.PixzigAppRunner(App, EngOptions);

pub const App = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    ctx: glyphwire.Context,
    mutex: std.Io.Mutex,
    server: glyphwire.server.Server,

    pub fn init(
        alloc: std.mem.Allocator,
        eng: *AppRunner.Engine,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        child_argv: []const []const u8,
    ) !*App {
        _ = eng;
        const app = try alloc.create(App);
        errdefer alloc.destroy(app);

        app.alloc = alloc;
        app.io = io;
        app.mutex = .init;
        app.ctx = try glyphwire.Context.init(alloc, grid_cols, grid_rows, scrollback_rows);
        errdefer app.ctx.deinit();

        const socket_path = try socketPath(alloc, environ_map);

        app.server = try glyphwire.server.Server.bind(io, &app.ctx, socket_path);
        app.server.mutex = &app.mutex;
        errdefer app.server.deinit();

        // Not joined: the process exiting (window closed) reaps this thread,
        // same as any other daemon-style background loop in this codebase.
        _ = try std.Thread.spawn(.{}, serveForever, .{ &app.server, alloc });

        // std.process.spawn builds the child's environment from a snapshot
        // taken once at process startup, not the live environment -- a
        // libc setenv() call here (as the pre-window launcher used, back
        // when it execvp'd into the child) would silently have no effect on
        // what the child actually sees. Build the child's env explicitly
        // instead: a clone of ours, plus the two discovery vars.
        var child_env = try environ_map.clone(alloc);
        defer child_env.deinit();
        try child_env.put("GLYPHWIRE_SOCK", socket_path);
        try child_env.put("GLYPHWIRE_CTX", glyphwire.default_context_id);

        if (std.process.spawn(io, .{ .argv = child_argv, .environ_map = &child_env })) |child| {
            // Not waited on synchronously (the shell keeps rendering); a
            // detached reaper thread just prevents the child lingering as a
            // zombie once it exits.
            _ = std.Thread.spawn(.{}, reapChild, .{ io, child }) catch {};
        } else |err| {
            std.log.err("failed to spawn child {s}: {t}", .{ child_argv[0], err });
        }

        return app;
    }

    pub fn deinit(self: *App) void {
        self.ctx.deinit();
        self.alloc.destroy(self);
    }

    pub fn update(self: *App, eng: *AppRunner.Engine, deltaTimeMs: f64) bool {
        _ = self;
        _ = deltaTimeMs;
        if (eng.inputs.keyboard.pressed(.escape)) return false;
        return true;
    }

    pub fn render(self: *App, eng: *AppRunner.Engine) void {
        eng.renderer.clear(0.0, 0.0, 0.0, 1.0);
        eng.renderer.begin(eng.projMat);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var row: usize = 0;
        while (row < grid_rows) : (row += 1) {
            var col: usize = 0;
            while (col < grid_cols) : (col += 1) {
                const cell = self.ctx.root.cell(row, col);
                const pos = pixzig.Vec2I{
                    .x = @as(i32, @intCast(col)) * cell_w,
                    .y = @as(i32, @intCast(row)) * cell_h,
                };

                const bg = switch (cell.style.bg) {
                    .color => |bg_color| bg_color,
                    // No image support yet (post-v1 in decisions.md);
                    // fall back to plain black, matching the clear color.
                    .image => glyphwire.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                };
                if (bg.r != 0 or bg.g != 0 or bg.b != 0) {
                    eng.renderer.drawFilledRect(
                        pixzig.RectF.fromPosSize(pos.x, pos.y, cell_w, cell_h),
                        pixzig.Color.from(bg.r, bg.g, bg.b, bg.a),
                    );
                }

                if (cell.grapheme_len > 0) {
                    const fg = cell.style.fg;
                    _ = eng.renderer.drawStringColored(cell.grapheme(), pos, pixzig.Color.from(fg.r, fg.g, fg.b, fg.a));
                }
            }
        }

        eng.renderer.end();
    }
};

fn serveForever(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.serveForever(alloc) catch |err| {
        std.log.err("glyphwire server error: {t}", .{err});
    };
}

fn reapChild(io: std.Io, child_in: std.process.Child) void {
    var child = child_in;
    _ = child.wait(io) catch {};
}

fn socketPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(alloc, "{s}/glyphwire-{d}.sock", .{ dir, pid });
}

pub fn main(init: std.process.Init) !void {
    std.log.info("glyphwire shell starting", .{});
    const alloc = init.gpa;
    const args = try init.minimal.args.toSlice(alloc);

    // With no explicit command, default to the styled-text demo client. It
    // lives in zig-out/bin alongside this binary, not on $PATH, so resolve
    // it relative to cwd (dev-mode convention: cwd is the repo root) rather
    // than relying on PATH search finding a bare "glyphwire-demo".
    const child_argv: []const []const u8 = if (args.len >= 2) args[1..] else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(init.io, &cwd_buf);
        const demo_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-demo", .{cwd_buf[0..cwd_len]});
        break :blk &.{demo_path};
    };

    // Font atlas packing needs a GL context, which needs the window created
    // first -- so cell_w/cell_h above are tuned constants rather than a
    // runtime measurement of the loaded font, avoiding a chicken-and-egg
    // dependency between window size and font metrics.
    const appRunner = try AppRunner.init("glyphwire", alloc, .{
        .windowSize = .{ .x = grid_cols * cell_w, .y = grid_rows * cell_h },
        .resizable = false,
        .renderInitOpts = .{ .font = .{ .path = .{ .face = "assets/JetBrainsMono-Regular.ttf", .size = font_size } } },
    });
    const app = try App.init(alloc, appRunner.engine, init.io, init.environ_map, child_argv);

    appRunner.run(app);
}
