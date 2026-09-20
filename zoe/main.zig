// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

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
    \\usage: zoe [--keys <script>] [--quiet] [file|directory]
    \\
    \\  --keys <script>  Headless: replay a vim-notation key script against
    \\                   the buffer, e.g. 'ihello<esc>dd' or ':w<cr>'.
    \\  --quiet          Headless: don't print the buffer afterwards.
    \\
    \\A directory argument changes into it (as `:cd` would) and starts on
    \\the file tree with an empty buffer; anything else is a file to open.
    \\
    \\With GLYPHWIRE_SOCK set and no --keys, zoe opens its editor UI on the
    \\glyphwire display server. Ctrl+W switches panes and Ctrl+H / Ctrl+L
    \\(or Ctrl+Left / Ctrl+Right) focus the pane that way; Ctrl+N toggles
    \\the file tree; Ctrl+Tab / Ctrl+Shift+Tab walk the open buffers (also
    \\:bn / :bp, closed with :bd or a tab's ×).
    \\See docs/investigations/zoe-editor.md.
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

    // A directory argument is a place to work, not a file to open, so it
    // is resolved here rather than deeper in: change into it, and from
    // then on it is simply the working directory -- the file tree roots
    // on it, a relative `:w` lands in it, `:pwd` agrees. Same as `:cd`,
    // just spelled on the command line. Everything else (including a
    // name that doesn't exist yet) is a file.
    var target: zoe.Target = .none;
    if (path) |p| {
        if (isDirectory(io, p)) {
            std.process.setCurrentPath(io, p) catch return fail(io, "zoe: cannot change directory\n");
            target = .directory;
        } else {
            target = .{ .file = p };
        }
    }

    // `--keys` always means the headless driver, even under a display
    // server: it's how the core is tested, and a script racing a live UI
    // would be neither. The UI opens the target itself: it owns every
    // buffer in its tab strip, and the first one is no different.
    if (script == null) {
        if (try runUi(alloc, io, target, init.environ_map)) return;
    }

    // A missing file is a new buffer, not an error -- `zoe newfile.txt`
    // is how you create one. A directory target has already been changed
    // into and leaves nothing to read.
    const file_path: ?[]const u8 = switch (target) {
        .file => |p| p,
        .none, .directory => null,
    };
    const text: []u8 = if (file_path) |p|
        std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try alloc.dupe(u8, ""),
            else => return fail(io, "zoe: cannot read file\n"),
        }
    else
        try alloc.dupe(u8, "");
    defer alloc.free(text);

    var ed = try zoe.Editor.initFromText(alloc, text, file_path);
    defer ed.deinit();

    if (script) |s| {
        switch (try zoe.keys.feed(&ed, s)) {
            // `:bn` / `:bp` / `:bd` need the UI's buffer list, `:cd` /
            // `:pwd` a live client and a real cwd, the clipboard ones a
            // live host. The headless driver just reports what parsed.
            .none, .quit, .chdir, .pwd, .set_clipboard, .paste, .buffer_step, .buffer_close => {},
            .write, .write_quit, .edit => |dest| try headlessSave(io, &ed, dest),
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

/// Whether `path` names a directory, following symlinks -- a link to one
/// is one for this purpose. Anything unreadable answers false and is
/// treated as a file, which is also what gives `zoe newfile.txt` its
/// new buffer.
fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Connects and runs the UI. False when there's no display server to
/// connect to, which is the caller's cue to fall back to headless.
fn runUi(
    alloc: std.mem.Allocator,
    io: std.Io,
    target: zoe.Target,
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
        "mouse_move",
        "context",
    }) catch return false;
    defer listener.deinit();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const ui = try zoe.Ui.init(alloc, io, &client, listener, target, cwd, environ);
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
