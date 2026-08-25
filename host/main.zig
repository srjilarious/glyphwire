const std = @import("std");
const glyphwire = @import("glyphwire");
const pixzig = @import("pixzig");

pub const panic = pixzig.system.panic;
pub const std_options = pixzig.system.std_options;

/// glyphwire-host: the pixzig-windowed glyphwire renderer (Milestone 8 --
/// see docs/slice_plan.md). Starts glyphwire-server, spawns glyphwire-shell
/// as its child with discovery already set up, and renders the grid every
/// frame by polling the server over the socket like any other client --
/// see src/client.zig. Deliberately does *not* touch the Context directly
/// (that was an earlier, since-reverted design): the graphics portion of
/// pixzig and the shell/launcher are separate processes, related only
/// through the wire protocol, so either can be swapped or driven
/// independently.
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
    client: glyphwire.Client,
    last_revision: u64 = 0,
    snapshot: ?glyphwire.CellsSnapshot = null,

    pub fn init(alloc: std.mem.Allocator, eng: *AppRunner.Engine, io: std.Io, socket_path: []const u8) !*App {
        _ = eng;
        var client = try glyphwire.Client.connect(io, alloc, socket_path);
        errdefer client.deinit();

        const app = try alloc.create(App);
        app.* = .{ .alloc = alloc, .client = client };
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.snapshot) |*s| s.deinit();
        self.client.deinit();
        self.alloc.destroy(self);
    }

    pub fn update(self: *App, eng: *AppRunner.Engine, deltaTimeMs: f64) bool {
        _ = deltaTimeMs;
        if (eng.inputs.keyboard.pressed(.escape)) return false;

        // Cheap poll every frame; only pull the (much larger) full grid
        // when something actually changed since the last fetch.
        const revision = self.client.getRevision() catch |err| {
            std.log.err("get_property(revision) failed: {t}", .{err});
            return true;
        };
        if (self.snapshot == null or revision != self.last_revision) {
            const new_snapshot = self.client.getCells() catch |err| {
                std.log.err("get_cells failed: {t}", .{err});
                return true;
            };
            if (self.snapshot) |*s| s.deinit();
            self.snapshot = new_snapshot;
            self.last_revision = revision;
        }

        return true;
    }

    pub fn render(self: *App, eng: *AppRunner.Engine) void {
        eng.renderer.clear(0.0, 0.0, 0.0, 1.0);
        eng.renderer.begin(eng.projMat);

        if (self.snapshot) |*snap| {
            var row: usize = 0;
            while (row < snap.rows()) : (row += 1) {
                var col: usize = 0;
                while (col < snap.cols()) : (col += 1) {
                    const rc = snap.cellAt(row, col);
                    const pos = pixzig.Vec2I{
                        .x = @as(i32, @intCast(col)) * cell_w,
                        .y = @as(i32, @intCast(row)) * cell_h,
                    };

                    if (rc.bg) |bg| {
                        if (bg.r != 0 or bg.g != 0 or bg.b != 0) {
                            eng.renderer.drawFilledRect(
                                pixzig.RectF.fromPosSize(pos.x, pos.y, cell_w, cell_h),
                                pixzig.Color.from(bg.r, bg.g, bg.b, bg.a),
                            );
                        }
                    }

                    if (rc.grapheme.len > 0) {
                        _ = eng.renderer.drawStringColored(rc.grapheme, pos, pixzig.Color.from(rc.fg.r, rc.fg.g, rc.fg.b, rc.fg.a));
                    }
                }
            }
        }

        eng.renderer.end();
    }
};

fn reapChild(io: std.Io, child_in: std.process.Child) void {
    var child = child_in;
    _ = child.wait(io) catch {};
}

fn socketPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(alloc, "{s}/glyphwire-{d}.sock", .{ dir, pid });
}

fn waitForSocketReady(io: std.Io, socket_path: []const u8) !void {
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (addr.connect(io)) |stream| {
            var s = stream;
            s.close(io);
            return;
        } else |_| {
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
    return error.ServerNeverCameUp;
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

    // With no explicit command, default to the styled-text demo client.
    // Resolved to an absolute path since shell/main.zig requires an
    // explicit command and zig-out/bin isn't on $PATH in dev mode.
    const shell_child_argv: []const []const u8 = if (args.len >= 2)
        args[1..]
    else
        &.{try resolveSibling(alloc, io, "glyphwire-demo")};

    const socket_path = try socketPath(alloc, init.environ_map);

    const server_path = try resolveSibling(alloc, io, "glyphwire-server");
    var server_child = try std.process.spawn(io, .{
        .argv = &.{
            server_path,
            socket_path,
            std.fmt.comptimePrint("{d}", .{grid_cols}),
            std.fmt.comptimePrint("{d}", .{grid_rows}),
        },
    });
    _ = try std.Thread.spawn(.{}, reapChild, .{ io, server_child });
    _ = &server_child;

    try waitForSocketReady(io, socket_path);

    var shell_env = try init.environ_map.clone(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try shell_env.put("GLYPHWIRE_CTX", glyphwire.default_context_id);

    const shell_path = try resolveSibling(alloc, io, "glyphwire-shell");
    const shell_argv = try std.mem.concat(alloc, []const u8, &.{ &.{shell_path}, shell_child_argv });

    if (std.process.spawn(io, .{ .argv = shell_argv, .environ_map = &shell_env })) |shell_child| {
        _ = try std.Thread.spawn(.{}, reapChild, .{ io, shell_child });
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
    const app = try App.init(alloc, appRunner.engine, io, socket_path);

    appRunner.run(app);
}
