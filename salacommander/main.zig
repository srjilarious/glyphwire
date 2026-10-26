// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `salacommander` -- a two-pane file manager for glyphwire, in the line of
//! Midnight Commander and Total Commander.
//!
//! Launched from a glyphwire-aware shell it opens a full-screen context
//! with a directory listing on each side: F2 renames in place, F3
//! searches everything below the pane's directory, F4 opens the file in
//! the configured editor (zoe unless told otherwise), F5 copies,
//! F6 moves or renames, F7 makes a directory, F8 deletes, Space/Insert
//! mark, dragging files onto a folder or the other pane moves them
//! there (copies with Ctrl held), Alt+Up goes to the parent directory, Alt+D edits the pane's
//! path where it's shown, Tab switches sides, Ctrl+F3..F6 (or a click
//! on a column header) re-orders a pane, Ctrl+Shift+C copies the
//! selected paths as a shell-quoted argument list, and Ctrl+` opens a
//! shell across the bottom that follows the active pane's directory.
//! Shift+F4 edits a file that doesn't exist yet, and Super with F2, F4,
//! F5-F8 does the same as root through sudo (see `sudo.zig`).
//! Every key is an action that `salacommander.conf.lua` can rebind (see
//! `actions.zig`), and what Enter opens a file with is its `open_actions`
//! table (see `openaction.zig`). It needs a glyphwire session; there is
//! no text-mode fallback.
//!
//! `salacommander [LEFT [RIGHT]]` -- both sides reopen the tabs the last
//! run left (`session.zig`), or with none the current directory. A
//! directory given, or with none the current directory on the side last
//! active, is shown in the tab already open on it, else in a new tab.

const std = @import("std");
const glyphwire = @import("glyphwire");
const build_info = @import("build_info");
const zargs = @import("zargunaught");
const sala = @import("salacommander_support");
const interrupt = @import("applib").interrupt;
const cli = @import("applib").cli;
const themeconf = @import("themeconf");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    // Run as root by a Super+F-key operation: no window, just the one
    // operation over stdin/stdout. See `sudo.zig`.
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len > 1 and std.mem.eql(u8, argv[1], sala.sudo.helper_flag)) {
        std.process.exit(sala.sudo.helperMain(io, alloc, argv[2..]));
    }

    // Ctrl+C cancels F3's finder popup, and the embedded shell panel
    // is ours to keep alive.
    // See `applib.interrupt`.
    interrupt.keep();

    var parser = try zargs.ArgParser.init(alloc, .{
        .name = "salacommander",
        .description = "A two-pane file manager drawn over a glyphwire connection.",
        .opts = &.{
            .{ .longName = "large", .shortName = "L", .description = "Start both panes in the large-icon view", .maxNumParams = 0 },
            .{ .longName = "small", .shortName = "S", .description = "Start both panes in the small-icon view", .maxNumParams = 0 },
            .{ .longName = "hidden", .shortName = "a", .description = "Show hidden files", .maxNumParams = 0 },
            .{ .longName = "help", .shortName = "h", .description = "Print this help and exit", .maxNumParams = 0 },
            .{ .longName = "version", .shortName = "V", .description = "Print the version and exit", .maxNumParams = 0 },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch |err|
        cli.fail(io, "salacommander: error parsing args: {t}\n", .{err});
    defer args.deinit();

    if (args.hasOption("version")) glyphwire.version.printAndExit(io, .of(build_info));
    if (args.hasOption("help")) {
        var stdout = try zargs.print.Printer.stdout(alloc);
        defer stdout.deinit();
        var help = try zargs.help.HelpFormatter.init(&parser, stdout, zargs.help.DefaultTheme, alloc);
        defer help.deinit();
        help.printHelpText() catch |err| std.debug.print("salacommander: error printing help: {t}\n", .{err});
        try stdout.flush();
        return;
    }

    const positional = args.positional.items;
    const left: ?[]const u8 = if (positional.len > 0) positional[0] else null;
    const right: ?[]const u8 = if (positional.len > 1) positional[1] else null;

    var cfg: sala.config.Config = cfg: {
        const dir = glyphwire.configDirPath(alloc, init.environ_map) catch break :cfg .{};
        defer alloc.free(dir);
        break :cfg sala.config.loadFromDir(alloc, io, dir);
    };
    if (args.hasOption("large")) cfg.view = .large;
    if (args.hasOption("small")) cfg.view = .small;
    if (args.hasOption("hidden")) cfg.show_hidden = true;

    // The last run's tabs. `-L` / `-S` / `-a` beat what each tab was
    // left with, as they beat the config.
    var loaded: ?sala.session.Loaded = if (cfg.restore_session) blk: {
        const dir = (sala.session.dirPath(alloc, init.environ_map) catch null) orelse break :blk null;
        defer alloc.free(dir);
        break :blk sala.session.load(alloc, io, dir);
    } else null;
    defer if (loaded) |*l| l.deinit();
    if (loaded) |*l| for (l.session().sides) |side| for (side.tabs) |*t| {
        if (args.hasOption("large")) t.view = .large;
        if (args.hasOption("small")) t.view = .small;
        if (args.hasOption("hidden")) t.show_hidden = true;
    };

    // `salacommander.conf.lua`'s own `theme`, if it names one; otherwise
    // the window's. Borrows from `theme_arena`.
    var theme_arena: std.heap.ArenaAllocator = .init(alloc);
    defer theme_arena.deinit();
    const own_theme = themeconf.programTheme(theme_arena.allocator(), alloc, io, init.environ_map, sala.config.conf_name);

    var conn = cli.connectOrFail(io, alloc, init.environ_map, "salacommander", &.{
        "key",
        "text",
        "paste",
        "resize",
        // The pane split re-laid-out: a window resize, or the band
        // between the panes dragged.
        "layout",
        "scroll_offset",
        "mouse_button",
        // Dragging files from one pane onto a folder or the other pane.
        "mouse_move",
        "context",
        // The window theme changed and this follows it: the F3 popup's
        // frame is the one thing the host can't recolour itself.
        "theme",
        // A drag of the shell panel's top edge.
        "layer_resize",
        // Ctrl+Shift+C with no host selection -- answered with the active
        // pane's paths. See `Ui.copySelectionPaths`.
        "copy_request",
        // Losing the window drops the held modifiers the key bar shows:
        // their releases go wherever the keyboard went.
        "focus",
    });
    defer conn.deinit();

    const ui = sala.Ui.init(alloc, io, &conn.client, conn.listener, .{
        .left = left,
        .right = right,
        .session = if (loaded) |*l| l.session() else null,
        .home = init.environ_map.get("HOME"),
        .environ = init.environ_map,
        .profile = init.environ_map.get("GLYPHWIRE_SALA_PROFILE") != null,
        .cfg = cfg,
        .theme = own_theme,
    }) catch |err|
        cli.fail(io, "salacommander: can't open {s}: {t}\n", .{ left orelse ".", err });
    defer ui.deinit();
    try ui.run();
    ui.saveSession();
}
