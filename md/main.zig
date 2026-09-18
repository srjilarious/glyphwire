// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `gwmd` -- a Markdown reader for glyphwire.
//!
//! Launched from a glyphwire-aware shell it opens a full-screen context
//! and renders the file with the host's own text, tables and images:
//! headings drawn at 3x/2x/1.5x, GFM tables as native glyphwire tables,
//! local images inline, and clickable links (see `ui.zig`). Launched from
//! anywhere else -- no `GLYPHWIRE_SOCK` -- or with `--dump`, it prints the
//! same layout as plain text and exits, which is how the parser and the
//! layout are exercised without a window.
//!
//! `gwmd notes.md#setup` opens scrolled to that heading; `gwmd docs/`
//! opens the directory's README.

const std = @import("std");
const glyphwire = @import("glyphwire");
const zargs = @import("zargunaught");
const md = @import("md_support");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var parser = try zargs.ArgParser.init(alloc, .{
        .name = "gwmd",
        .description = "Renders a Markdown file over a glyphwire connection.",
        .opts = &.{
            .{
                .longName = "dump",
                .shortName = "d",
                .description = "Print the rendered layout as plain text and exit, without opening a window",
                .maxNumParams = 0,
            },
            .{
                .longName = "width",
                .shortName = "w",
                .description = "Width in columns for --dump (default 80)",
                .minNumParams = 1,
                .maxNumParams = 1,
            },
            .{
                .longName = "max-width",
                .shortName = "m",
                .description = "Widest the text column may get, however wide the window (default 100)",
                .minNumParams = 1,
                .maxNumParams = 1,
            },
            .{ .longName = "help", .shortName = "h", .description = "Print this help and exit", .maxNumParams = 0 },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gwmd: error parsing args: {t}\n", .{err}) catch
            "gwmd: error parsing args\n";
        return fail(io, msg);
    };
    defer args.deinit();

    if (args.hasOption("help")) {
        var stdout = try zargs.print.Printer.stdout(alloc);
        defer stdout.deinit();
        var help = try zargs.help.HelpFormatter.init(&parser, stdout, zargs.help.DefaultTheme, alloc);
        defer help.deinit();
        help.printHelpText() catch |err| std.debug.print("gwmd: error printing help: {t}\n", .{err});
        try stdout.flush();
        return;
    }

    if (args.positional.items.len < 1) {
        return fail(io, "usage: gwmd [--dump] [--width N] [--max-width N] <file.md>[#heading]\n");
    }
    const arg = args.positional.items[0];

    const max_width = try numberOpt(io, &args, "max-width", 100);
    const dump_width = try numberOpt(io, &args, "width", 80);

    // `file.md#section`: split off the anchor, unless a file with the `#`
    // really is in its name.
    var path: []const u8 = arg;
    var fragment: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, arg, '#')) |h| {
        if (std.Io.Dir.cwd().statFile(io, arg, .{})) |_| {} else |_| {
            path = arg[0..h];
            fragment = arg[h + 1 ..];
        }
    }

    if (args.hasOption("dump")) return dump(alloc, io, path, dump_width, max_width);

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        return dump(alloc, io, path, dump_width, max_width);
    };
    defer client.deinit();

    const listener = glyphwire.InputListener.connectFromEnv(io, alloc, init.environ_map, &.{
        "key",
        "resize",
        "scroll_offset",
        "mouse_button",
        "mouse_move",
        "context",
    }) catch return dump(alloc, io, path, dump_width, max_width);
    defer listener.deinit();

    const ui = try md.Ui.init(alloc, io, &client, listener, max_width);
    defer ui.deinit();

    try ui.open(path, fragment);
    if (ui.page == null) {
        // Nothing to show: say why on the terminal rather than leaving an
        // empty window up.
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gwmd: {s}\n", .{ui.message orelse "could not open file"}) catch "gwmd: could not open file\n";
        ui.deinit();
        return fail(io, msg);
    }
    try ui.run();
}

fn numberOpt(io: std.Io, args: anytype, name: []const u8, default: usize) !usize {
    const v = args.optionVal(name) orelse return default;
    return std.fmt.parseInt(usize, v, 10) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gwmd: --{s} wants a number, got '{s}'\n", .{ name, v }) catch
            "gwmd: bad number\n";
        try fail(io, msg);
        unreachable;
    };
}

/// The headless path: the layout, as text, on stdout. Local images are
/// measured from their file headers so they're placed as they would be
/// on screen (at an assumed 8x16 cell).
fn dump(alloc: std.mem.Allocator, io: std.Io, path: []const u8, width: usize, max_width: usize) !void {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gwmd: {s}: {t}\n", .{ path, err }) catch "gwmd: could not read file\n";
        return fail(io, msg);
    };
    defer alloc.free(source);

    var doc = try md.Document.parse(alloc, source);
    defer doc.deinit();

    const Sizes = struct {
        io: std.Io,
        alloc: std.mem.Allocator,
        dir: []const u8,

        fn sizeOf(ctx: *const anyopaque, src: []const u8) ?md.layout.ImageSize {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (md.layout.isRemote(src)) return null;
            const rel = md.nav.percentDecode(self.alloc, src) catch return null;
            defer self.alloc.free(rel);
            const full = md.nav.resolve(self.alloc, self.dir, rel) catch return null;
            defer self.alloc.free(full);
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, full, self.alloc, .limited(64 * 1024 * 1024)) catch return null;
            defer self.alloc.free(bytes);
            const format = glyphwire.detectImageFormat(bytes) orelse return null;
            const info = glyphwire.imageDimensions(format, bytes) catch return null;
            return .{ .w = info.width, .h = info.height };
        }
    };
    const sizes: Sizes = .{ .io = io, .alloc = alloc, .dir = std.fs.path.dirname(path) orelse "." };

    var lay = try md.layout.layout(alloc, &doc, .{
        .width = width,
        .max_width = max_width,
        .images = .{ .ctx = &sizes, .sizeOf = Sizes.sizeOf },
    });
    defer lay.deinit();

    const text = try lay.renderText(alloc);
    defer alloc.free(text);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn fail(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
    std.process.exit(1);
}
