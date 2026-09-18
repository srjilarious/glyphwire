// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `gw-read` -- a comic/manga reader for glyphwire.
//!
//! Launched from a glyphwire-aware shell it opens a full-screen context
//! and runs the real UI (`ui.zig`): one page filling the window, paged
//! right-to-left by default, with zoom and pan. Launched from anywhere
//! else -- no `GLYPHWIRE_SOCK` -- it falls back to listing the pages it
//! found and exiting, which is how the archive layer is exercised by hand
//! and in CI, where there is no window. `--list` forces that path even
//! under a display server.
//!
//! Today it reads `.cbz` / `.cbr` / `.cb7` and plain directories of
//! images (see archive.zig). `.epub` and `.pdf` are the intended next
//! formats, and mokuro OCR overlays with yomitan-style lookup the
//! intended next feature -- both are why the page source sits behind
//! `archive.Archive` rather than being inlined into the UI.

const std = @import("std");
const glyphwire = @import("glyphwire");
const zargs = @import("zargunaught");
const read = @import("read_support");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var parser = try zargs.ArgParser.init(alloc, .{
        .name = "gw-read",
        .description = "Reads a comic archive (.cbz, .cbr, .cb7) or a directory of images over a glyphwire connection.",
        .opts = &.{
            .{
                .longName = "page",
                .shortName = "p",
                .description = "Open at this page number (1-based), overriding the remembered position",
                .minNumParams = 1,
                .maxNumParams = 1,
            },
            .{
                .longName = "mode",
                .shortName = "m",
                .description = "Sizing mode: fit (default), fit-width, fit-height, natural",
                .minNumParams = 1,
                .maxNumParams = 1,
            },
            .{
                .longName = "direction",
                .shortName = "d",
                .description = "Page-turn direction: rtl (default, manga) or ltr",
                .minNumParams = 1,
                .maxNumParams = 1,
            },
            .{
                .longName = "list",
                .shortName = "l",
                .description = "Print the pages found and exit, without opening a window",
                // `maxNumParams = 0` is what stops zargunaught from
                // swallowing the following positional as this flag's
                // argument -- same as glyphwire-ls's bare flags.
                .maxNumParams = 0,
            },
            .{ .longName = "help", .shortName = "h", .description = "Print this help and exit", .maxNumParams = 0 },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gw-read: error parsing args: {t}\n", .{err}) catch
            "gw-read: error parsing args\n";
        return fail(io, msg);
    };
    defer args.deinit();

    if (args.hasOption("help")) {
        var stdout = try zargs.print.Printer.stdout(alloc);
        defer stdout.deinit();
        var help = try zargs.help.HelpFormatter.init(&parser, stdout, zargs.help.DefaultTheme, alloc);
        defer help.deinit();
        help.printHelpText() catch |err| std.debug.print("gw-read: error printing help: {t}\n", .{err});
        try stdout.flush();
        return;
    }

    if (args.positional.items.len < 1) {
        return fail(io, "usage: gw-read [--page N] [--mode fit|fit-width|fit-height|natural] [--direction rtl|ltr] <book>\n");
    }
    const path = args.positional.items[0];

    // The config first: everything below reads defaults out of it.
    var conf = conf: {
        const dir = glyphwire.configDirPath(alloc, init.environ_map) catch break :conf read.ReadConfig{};
        defer alloc.free(dir);
        break :conf read.config.loadFromDir(alloc, io, dir);
    };
    // Owns the strings it duped out of read.conf.lua (the dictionary path,
    // the AI settings). `Ui` holds a by-value copy that only reads them,
    // so this one deinit is the only free.
    defer conf.deinit(alloc);

    const book = read.archive.open(alloc, io, path) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gw-read: {s}: {s}\n", .{ path, describe(err) }) catch
            "gw-read: could not open that book\n";
        return fail(io, msg);
    };
    defer book.deinit();

    // Overrides from the command line beat both the config and the
    // remembered position; each is resolved before the connection so a
    // bad value fails fast rather than after a window has flashed up.
    var mode = conf.mode;
    if (args.optionVal("mode")) |v| {
        mode = read.config.parseMode(v) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "gw-read: unknown --mode '{s}'\n", .{v}) catch
                "gw-read: unknown --mode\n";
            return fail(io, msg);
        };
    }
    var direction = conf.direction;
    if (args.optionVal("direction")) |v| {
        direction = read.Direction.parse(v) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "gw-read: unknown --direction '{s}' (want rtl or ltr)\n", .{v}) catch
                "gw-read: unknown --direction\n";
            return fail(io, msg);
        };
    }
    var explicit_page: ?usize = null;
    if (args.optionVal("page")) |v| {
        const n = std.fmt.parseInt(usize, v, 10) catch 0;
        if (n == 0 or n > book.count()) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "gw-read: --page {s} is outside 1..{d}\n", .{ v, book.count() }) catch
                "gw-read: --page out of range\n";
            return fail(io, msg);
        }
        explicit_page = n - 1;
    }

    if (args.hasOption("list")) return list(alloc, io, book, conf.ocr);

    // The remembered position, unless the command line named one.
    const config_dir: ?[]u8 = glyphwire.configDirPath(alloc, init.environ_map) catch null;
    defer if (config_dir) |d| alloc.free(d);

    var store: ?read.state.Store = null;
    defer if (store) |*s| s.deinit();

    var start_page: usize = explicit_page orelse 0;
    if (conf.remember_position and explicit_page == null) {
        if (config_dir) |dir| {
            store = read.state.load(alloc, io, dir);
            if (store.?.get(book.path)) |mark| {
                start_page = @min(mark.page, book.count() -| 1);
                // A remembered mode/direction is the *book's*, so it beats
                // the config's default but not an explicit flag.
                if (args.optionVal("mode") == null) {
                    if (read.config.parseMode(mark.mode)) |m| mode = m;
                }
                if (args.optionVal("direction") == null) {
                    if (read.Direction.parse(mark.direction)) |d| direction = d;
                }
            }
        }
    }

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        // No display server: say what's in the book and leave, the same
        // shape zoe's headless fallback has.
        return list(alloc, io, book, conf.ocr);
    };
    defer client.deinit();

    // Two connections: one for requests and drawing, one subscribed for
    // notifications. `scroll_offset` is what the wheel and the page
    // layer's scrollbars report the pan back on.
    const listener = glyphwire.InputListener.connectFromEnv(io, alloc, init.environ_map, &.{
        "key",
        "text",
        "resize",
        "scroll_offset",
        "mouse_button",
        "mouse_move",
        "context",
    }) catch return list(alloc, io, book, conf.ocr);
    defer listener.deinit();

    const ui = try read.Ui.init(alloc, &client, listener, book, conf, .{
        .page = start_page,
        .mode = mode,
        .direction = direction,
        .config_dir = config_dir,
        // Read here, where the environment is, rather than threading the
        // whole environ map into the UI. Only ever sent to the endpoint.
        .ai_api_key = if (conf.ai_lookup and conf.aiApiKeyEnv().len > 0) init.environ_map.get(conf.aiApiKeyEnv()) else null,
    });
    defer ui.deinit();

    try ui.run();

    // Save where we got to. Best effort by design: a state file that
    // can't be written costs you your place, nothing more.
    if (conf.remember_position) {
        if (config_dir) |dir| {
            if (store == null) store = read.state.load(alloc, io, dir);
            store.?.record(book.path, ui.bookmark()) catch {};
            read.state.save(alloc, io, dir, &store.?) catch |err|
                std.log.warn("gw-read: couldn't save reading position ({t})", .{err});
        }
    }
}

/// The headless path: what was found, in reading order.
///
/// Also where a mokuro sidecar is *verified*. There is no other way to
/// check that a volume's OCR was found and lines up with its pages
/// without a window in front of you -- and "lines up" is the part that
/// actually goes wrong, since a sidecar dropped in beside the wrong
/// volume opens perfectly and then never shows a word.
fn list(alloc: std.mem.Allocator, io: std.Io, book: *read.Archive, want_ocr: bool) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    try out.print("{s}  ({s}, {d} pages", .{ book.path, book.format.label(), book.count() });
    if (book.skipped > 0) try out.print(", {d} skipped -- unsupported image format", .{book.skipped});
    try out.writeAll(")\n");

    var ocr: ?read.mokuro.Volume = null;
    defer if (ocr) |*v| v.deinit();
    if (want_ocr and book.hasMokuro()) {
        if (book.readMokuro(alloc)) |maybe| {
            if (maybe) |bytes| {
                defer alloc.free(bytes);
                ocr = read.mokuro.parse(alloc, bytes) catch null;
            }
        } else |err| {
            try out.print("  mokuro: found, but unreadable ({t})\n", .{err});
        }
    }

    if (ocr) |*v| {
        var matched: usize = 0;
        var blocks: usize = 0;
        for (book.pages.items) |p| {
            const op = v.pageFor(p.name) orelse continue;
            if (op.blocks.len == 0) continue;
            matched += 1;
            blocks += op.blocks.len;
        }
        try out.print("  mokuro: {d} of {d} sidecar pages carry text; {d} book pages matched, {d} blocks\n", .{
            v.pagesWithText(),
            v.pages.len,
            matched,
            blocks,
        });
        if (matched == 0)
            try out.writeAll("  mokuro: WARNING -- no book page matched; is this the right volume's sidecar?\n");
    }

    for (book.pages.items, 1..) |p, n| {
        try out.print("{d:>5}  {s}", .{ n, p.name });
        if (ocr) |*v| {
            if (v.pageFor(p.name)) |op| {
                if (op.blocks.len > 0) try out.print("   [{d} ocr]", .{op.blocks.len});
            }
        }
        try out.writeAll("\n");
    }
    try out.flush();
}

/// A one-line explanation for the errors `archive.open` can report --
/// `{t}` on the raw error gives `NoExtractorAvailable`, which doesn't
/// tell anyone what to install.
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownArchiveFormat => "not a comic archive (expected .cbz/.cbr/.cb7 or a directory of images)",
        error.NoExtractorAvailable => "RAR/7z books need one of bsdtar, unrar or 7z on PATH",
        error.ExtractFailed => "the archive could not be unpacked (corrupt, or password-protected)",
        error.NoPages => "no pages in a format glyphwire can decode (PNG, JPEG, BMP, GIF)",
        error.FileNotFound => "no such file or directory",
        else => "could not be opened",
    };
}

fn fail(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
    std.process.exit(1);
}
