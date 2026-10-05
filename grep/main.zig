// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const glyphwire = @import("glyphwire");
const zargs = @import("zargunaught");

const rg = @import("rg.zig");
const nodes_mod = @import("nodes.zig");

/// gw-grep: a ripgrep front-end that draws its results as a collapsible
/// `Outline` and then exits.
///
/// Shaped like `glyphwire-ls`, not like a full-screen TUI: no context, no
/// layer of its own, no `InputListener`. It writes into the shell's
/// current layer at the cursor and leaves, and the results stay in the
/// scrollback — where clicking a ▸ still expands the hit, because an
/// outline is real server-side state that glyphwire-host can toggle with
/// nothing running (see `host/outline_toggle.zig`). It is the showcase
/// for that property, the same way `gw-ls -l` is for click-to-sort.
///
/// Because the process is gone by the time you expand anything, every
/// hit's context has to be sent up front. ripgrep has no function-scoped
/// context (only `-A`/`-B`/`-C`), so a window of lines is what a hit can
/// show; `-B 3 -A 10` is the default. The hit's own line sits among that
/// window with its line number in the match colour, so the block reads as
/// a contiguous piece of the file rather than one with a hole in it.
///
/// Without a session it falls back to plain stdout, like `gw-ls` does.
const usage =
    \\gw-grep - search with ripgrep, browse the hits as a collapsible outline
    \\
    \\Usage: gw-grep [options] <pattern> [path...]
    \\
    \\Options:
    \\  -i, --ignore-case      Case-insensitive search
    \\  -w, --word             Match whole words only
    \\  -F, --fixed-strings    Treat the pattern as a literal, not a regex
    \\      --hidden           Search hidden files and directories
    \\  -A, --after <n>        Context lines shown after a hit (default 10)
    \\  -B, --before <n>       Context lines shown before a hit (default 3)
    \\  -C, --context <n>      Shorthand for the same value before and after
    \\      --expand           Start with every hit expanded
    \\      --collapse         Start with every file collapsed
    \\  -h, --help             Show this help
    \\
;

const default_before: u32 = 3;
const default_after: u32 = 10;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var parser = try zargs.ArgParser.init(alloc, .{
        .name = "gw-grep",
        .banner = "Search with ripgrep, browse the hits as a collapsible outline",
        .opts = &.{
            .{ .longName = "help", .shortName = "h", .description = "Show this help" },
            .{ .longName = "ignore-case", .shortName = "i", .description = "Case-insensitive search" },
            .{ .longName = "word", .shortName = "w", .description = "Match whole words only" },
            .{ .longName = "fixed-strings", .shortName = "F", .description = "Literal pattern, not a regex" },
            .{ .longName = "hidden", .description = "Search hidden files and directories" },
            .{ .longName = "after", .shortName = "A", .description = "Context lines after a hit", .maxNumParams = 1 },
            .{ .longName = "before", .shortName = "B", .description = "Context lines before a hit", .maxNumParams = 1 },
            .{ .longName = "context", .shortName = "C", .description = "Context lines either side", .maxNumParams = 1 },
            .{ .longName = "expand", .description = "Start with every hit expanded" },
            .{ .longName = "collapse", .description = "Start with every file collapsed" },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch {
        return fail(io, usage);
    };
    defer args.deinit();

    if (args.hasOption("help") or args.positional.items.len == 0) {
        return fail(io, usage);
    }

    const both = optU32(args, "context");
    const before = optU32(args, "before") orelse both orelse default_before;
    const after = optU32(args, "after") orelse both orelse default_after;
    const pattern = args.positional.items[0];
    const paths = args.positional.items[1..];

    // ── Run ripgrep ─────────────────────────────────────────────────
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "rg");
    try argv.append(alloc, "--json");
    if (args.hasOption("ignore-case")) try argv.append(alloc, "-i");
    if (args.hasOption("word")) try argv.append(alloc, "-w");
    if (args.hasOption("fixed-strings")) try argv.append(alloc, "-F");
    if (args.hasOption("hidden")) try argv.append(alloc, "--hidden");
    const before_text = try std.fmt.allocPrint(alloc, "{d}", .{before});
    defer alloc.free(before_text);
    const after_text = try std.fmt.allocPrint(alloc, "{d}", .{after});
    defer alloc.free(after_text);
    try argv.append(alloc, "-B");
    try argv.append(alloc, before_text);
    try argv.append(alloc, "-A");
    try argv.append(alloc, after_text);
    try argv.append(alloc, "--");
    try argv.append(alloc, pattern);
    for (paths) |p| try argv.append(alloc, p);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        return fail(io, "gw-grep: could not run `rg` - is ripgrep installed and on your PATH?\n");
    };

    var p = rg.Parser.init(alloc);
    defer p.deinit();

    {
        var buf: [64 * 1024]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buf);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch break;
            try p.feedLine(line);
        }
    }
    try p.finish();

    const term = child.wait(io) catch {
        return fail(io, "gw-grep: `rg` did not finish cleanly\n");
    };
    switch (term) {
        // 1 is ripgrep's "no matches", which is not an error here. 127 is
        // a failed execve in the forked child -- the same "not really
        // installed" signal `read/archive.zig` keys on.
        .exited => |code| if (code == 127) {
            return fail(io, "gw-grep: could not run `rg` - is ripgrep installed and on your PATH?\n");
        } else if (code > 1) {
            return fail(io, "gw-grep: `rg` reported an error\n");
        },
        else => return fail(io, "gw-grep: `rg` was killed\n"),
    }

    const files = try p.take();
    defer {
        for (files) |f| f.deinit(alloc);
        alloc.free(files);
    }

    if (files.len == 0) {
        return fail(io, "gw-grep: no matches\n");
    }

    const opts: nodes_mod.Options = .{
        .ctx = .{ .before = before, .after = after },
        .hits_collapsed = !args.hasOption("expand"),
        .files_collapsed = args.hasOption("collapse"),
    };

    if (glyphwire.Client.connectFromEnv(io, alloc, init.environ_map)) |connected| {
        var client = connected;
        defer client.deinit();
        try draw(&client, io, alloc, files, opts);
    } else |_| {
        try writePlain(io, alloc, files);
    }
}

/// Tags each hit's row with a metadata blob, so a click on the row's
/// *text* (rather than its marker, which glyphwire-host takes for the
/// toggle) resolves through glyphwire-shell's open actions the same way a
/// `gw-ls` entry does. `line` rides along for a future open-at-line;
/// `shell/openaction.zig` reads only `kind`/`path`/`mimetype` today.
const Tagger = struct {
    client: *glyphwire.Client,
    alloc: std.mem.Allocator,
    io: std.Io,

    pub fn tag(self: *const Tagger, path: []const u8, line: u64) !glyphwire.MetadataHandle {
        const abs = try absolutePath(self.io, self.alloc, path);
        defer self.alloc.free(abs);
        const json = try std.json.Stringify.valueAlloc(self.alloc, .{
            .kind = "file",
            .path = abs,
            .mimetype = "text/plain",
            .line = line,
        }, .{});
        defer self.alloc.free(json);
        return self.client.createMetadata(json);
    }
};

/// ripgrep reports paths relative to where it was run; an open action
/// needs an absolute one. Same shape as `ls/entries.zig`'s
/// `resolveAbsolutePath`, inlined rather than pulling in `ls_support`
/// for five lines.
fn absolutePath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(alloc, &.{path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(alloc, &.{ cwd_buf[0..cwd_len], path });
}

/// Paints the outline into the shell's current layer and parks the cursor
/// below it, so the next prompt lands under the results rather than over
/// them -- the same handoff `glyphwire-ls -l` does with its table.
fn draw(
    client: *glyphwire.Client,
    io: std.Io,
    alloc: std.mem.Allocator,
    files: []const rg.FileHits,
    opts: nodes_mod.Options,
) !void {
    var tagger = Tagger{ .client = client, .alloc = alloc, .io = io };
    var built = try nodes_mod.build(alloc, files, opts, &tagger);
    defer built.deinit();

    const layer = try client.getSize();
    const cursor = try client.getCursor();
    const outline = try client.createOutline(null, cursor.row, 0, layer.cols, .{});
    try client.outlineSetNodes(null, outline, built.nodes);

    var state = try client.outlineGetState(null, outline);
    defer state.deinit(alloc);

    const past = state.painted.row + state.painted.rows;
    const bottom = layer.rows -| 1;
    if (past <= bottom) {
        try client.setCursor(past, 0);
    } else {
        // The outline was taller than the window, so it scrolled the layer
        // as it drew and its footprint fills the viewport. Land on the
        // last row and emit a newline to scroll one blank in, the same
        // gap `gw-ls -l` leaves in that case.
        try client.setCursor(bottom, 0);
        try client.writeText("\n", null, null);
    }
}

/// The no-session fallback: ripgrep's own familiar `path:line:text`, with
/// no context (there is nothing to expand on a plain terminal).
fn writePlain(io: std.Io, alloc: std.mem.Allocator, files: []const rg.FileHits) !void {
    _ = alloc;
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    for (files) |file| {
        for (file.lines) |line| {
            if (line.submatches.len == 0) continue;
            try w.interface.print("{s}:{d}:{s}\n", .{ file.path, line.number, line.text });
        }
    }
    try w.interface.flush();
}

fn optU32(args: anytype, name: []const u8) ?u32 {
    const v = args.optionVal(name) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

fn fail(io: std.Io, msg: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
    std.process.exit(1);
}
