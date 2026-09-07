//! `zoe` -- a modal editor for glyphwire.
//!
//! Launched from a glyphwire-aware shell it connects to the display
//! server and runs the real UI (`ui.zig`): a file tree beside the buffer
//! with a statusline under both, laid out by a host-side split tree.
//! Launched from anywhere else -- no `GLYPHWIRE_SOCK` -- it falls back to
//! the headless driver, which replays a vim-notation key script against
//! the editor core and prints the result. That fallback is how the core
//! is exercised by hand and in CI, where there is no window.

const std = @import("std");
const glyphwire = @import("glyphwire");
const zoe = @import("zoe_support");

const usage =
    \\usage: zoe [--keys <script>] [--quiet] [file]
    \\
    \\  --keys <script>  Headless: replay a vim-notation key script against
    \\                   the buffer, e.g. 'ihello<esc>dd' or ':w<cr>'.
    \\  --quiet          Headless: don't print the buffer afterwards.
    \\
    \\With GLYPHWIRE_SOCK set and no --keys, zoe opens its editor UI on the
    \\glyphwire display server. Ctrl+W switches panes, Ctrl+N toggles the
    \\file tree. See docs/investigations/zoe-editor.md.
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    // Arena, not `alloc`: process-lifetime, freed automatically on exit --
    // see `server/main.zig`'s identical `args` allocation.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var script: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var quiet = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--keys")) {
            i += 1;
            if (i >= args.len) return fail(io, "zoe: --keys needs a script\n");
            script = args[i];
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return write(io, usage);
        } else if (arg.len > 0 and arg[0] == '-') {
            return fail(io, "zoe: unknown option\n");
        } else {
            path = arg;
        }
    }

    // A missing file is a new buffer, not an error -- `zoe newfile.txt`
    // is how you create one.
    const text: []u8 = if (path) |p|
        std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try alloc.dupe(u8, ""),
            else => return fail(io, "zoe: cannot read file\n"),
        }
    else
        try alloc.dupe(u8, "");
    defer alloc.free(text);

    var ed = try zoe.Editor.initFromText(alloc, text, path);
    defer ed.deinit();

    // `--keys` always means the headless driver, even under a display
    // server: it's how the core is tested, and a script racing a live UI
    // would be neither.
    if (script == null) {
        if (try runUi(alloc, io, &ed, init.environ_map)) return;
    }

    if (script) |s| {
        switch (try zoe.keys.feed(&ed, s)) {
            // `:cd` / `:pwd` need a live client and a real cwd to act
            // on; the headless driver just reports what parsed.
            .none, .quit, .chdir, .pwd => {},
            .write, .write_quit, .edit => |target| try headlessSave(io, &ed, target),
        }
    }

    if (!quiet) {
        const out = try ed.buf.text(alloc);
        defer alloc.free(out);
        try write(io, out);
        if (out.len > 0 and out[out.len - 1] != '\n') try write(io, "\n");
    }

    if (ed.status.items.len > 0) {
        try write(io, ed.status.items);
        try write(io, "\n");
    }
}

/// Connects and runs the UI. False when there's no display server to
/// connect to, which is the caller's cue to fall back to headless.
fn runUi(
    alloc: std.mem.Allocator,
    io: std.Io,
    ed: *zoe.Editor,
    environ: *const std.process.Environ.Map,
) !bool {
    var client = glyphwire.Client.connectFromEnv(io, alloc, environ) catch return false;
    defer client.deinit();

    // Two connections: one for requests and drawing, one subscribed for
    // notifications. `layout` and `scroll_offset` are what the split tree
    // and the tree pane's scrollbars report back on.
    const listener = glyphwire.InputListener.connectFromEnv(io, alloc, environ, &.{
        "key",
        "text",
        "clipboard",
        "resize",
        "scroll",
        "layout",
        "mouse_button",
        "context",
    }) catch return false;
    defer listener.deinit();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const ui = try zoe.Ui.init(alloc, io, &client, listener, ed, cwd, environ);
    defer ui.deinit();

    try ui.run();
    return true;
}

/// The headless `:w` -- the UI has its own, since it also refreshes the
/// statusline.
fn headlessSave(io: std.Io, ed: *zoe.Editor, target: ?[]const u8) !void {
    const dest = target orelse ed.path orelse {
        ed.setStatus("E32: No file name", .{});
        return;
    };
    const bytes = try ed.buf.text(ed.alloc);
    defer ed.alloc.free(bytes);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes }) catch {
        ed.setStatus("E212: Can't open file for writing: {s}", .{dest});
        return;
    };
    if (target) |t| try ed.setPath(t);
    ed.markSaved();
    ed.setStatus("\"{s}\" {d}L written", .{ dest, ed.buf.lineCount() });
}

fn write(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn fail(io: std.Io, msg: []const u8) !void {
    try write(io, msg);
    return error.InvalidArguments;
}
