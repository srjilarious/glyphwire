//! `zoe` -- a modal editor for glyphwire.
//!
//! **The UI is not wired up yet.** This slice is the headless core (see
//! `docs/investigations/zoe-editor.md` for the plan and what comes next),
//! so `main` is a driver for it rather than an editor you can sit in: it
//! loads a file, replays a vim-notation key script against the real
//! `feedText`/`feedKey` input path, and prints the resulting buffer. That
//! makes the core exercisable by hand -- and `:w` actually writes -- while
//! the layer/rendering half is still being built.

const std = @import("std");
const zoe = @import("zoe_support");

const usage =
    \\usage: zoe [--keys <script>] [--quiet] [file]
    \\
    \\  --keys <script>  Replay a vim-notation key script against the buffer,
    \\                   e.g. 'ihello<esc>dd' or '3jA world<esc>:w<cr>'.
    \\  --quiet          Don't print the buffer afterwards.
    \\
    \\The interactive glyphwire UI is not built yet; this drives the editor
    \\core headlessly. See docs/investigations/zoe-editor.md.
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);

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

    if (script) |s| {
        const outcome = try zoe.keys.feed(&ed, s);
        switch (outcome) {
            .none, .quit => {},
            .write, .write_quit => |target| try save(io, &ed, target),
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

/// Carries out an `Outcome.write` -- the editor core never touches the
/// filesystem itself, so this is the whole of `:w`.
fn save(io: std.Io, ed: *zoe.Editor, target: ?[]const u8) !void {
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
