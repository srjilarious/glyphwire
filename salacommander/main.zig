// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `salacommander` -- a two-pane file manager for glyphwire, in the line of
//! Midnight Commander and Total Commander.
//!
//! Launched from a glyphwire-aware shell it opens a full-screen context
//! with a directory listing on each side: F5 copies, F6 moves or renames,
//! F7 makes a directory, F8 deletes, Space/Insert mark, Alt+Up goes to the
//! parent directory, Alt+D edits the pane's path where it's shown, Tab
//! switches sides, and Ctrl+` opens a shell across the bottom that
//! follows the active pane's directory. Every key is an
//! action that `salacommander.conf.lua` can rebind (see `actions.zig`),
//! and what Enter opens a file with is its `open_actions` table (see
//! `openaction.zig`). It needs a glyphwire session; there is no text-mode
//! fallback.
//!
//! `salacommander [LEFT [RIGHT]]` -- both sides default to the current
//! directory.

const std = @import("std");
const glyphwire = @import("glyphwire");
const zargs = @import("zargunaught");
const sala = @import("salacommander_support");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var parser = try zargs.ArgParser.init(alloc, .{
        .name = "salacommander",
        .description = "A two-pane file manager drawn over a glyphwire connection.",
        .opts = &.{
            .{ .longName = "large", .shortName = "L", .description = "Start both panes in the large-icon view", .maxNumParams = 0 },
            .{ .longName = "small", .shortName = "S", .description = "Start both panes in the small-icon view", .maxNumParams = 0 },
            .{ .longName = "hidden", .shortName = "a", .description = "Show hidden files", .maxNumParams = 0 },
            .{ .longName = "help", .shortName = "h", .description = "Print this help and exit", .maxNumParams = 0 },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "salacommander: error parsing args: {t}\n", .{err}) catch
            "salacommander: error parsing args\n";
        return fail(io, msg);
    };
    defer args.deinit();

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
    const left: []const u8 = if (positional.len > 0) positional[0] else ".";
    const right: []const u8 = if (positional.len > 1) positional[1] else left;

    var cfg: sala.config.Config = cfg: {
        const dir = glyphwire.configDirPath(alloc, init.environ_map) catch break :cfg .{};
        defer alloc.free(dir);
        break :cfg sala.config.loadFromDir(alloc, io, dir);
    };
    if (args.hasOption("large")) cfg.view = .large;
    if (args.hasOption("small")) cfg.view = .small;
    if (args.hasOption("hidden")) cfg.show_hidden = true;

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        cfg.deinit(alloc);
        return fail(io, "salacommander: needs a glyphwire session (no GLYPHWIRE_SOCK)\n");
    };
    defer client.deinit();

    const listener = glyphwire.InputListener.connectFromEnv(io, alloc, init.environ_map, &.{
        "key",
        "text",
        "paste",
        "resize",
        "scroll_offset",
        "mouse_button",
        "context",
    }) catch {
        cfg.deinit(alloc);
        return fail(io, "salacommander: couldn't subscribe to input\n");
    };
    defer listener.deinit();

    const ui = sala.Ui.init(alloc, io, &client, listener, .{
        .left = left,
        .right = right,
        .home = init.environ_map.get("HOME"),
        .cfg = cfg,
    }) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "salacommander: can't open {s}: {t}\n", .{ left, err }) catch "salacommander: can't start\n";
        return fail(io, msg);
    };
    defer ui.deinit();
    try ui.run();
}

fn fail(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
    std.process.exit(1);
}
