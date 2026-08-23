const std = @import("std");
const glyphwire = @import("glyphwire");

/// Styled-text demo client: connects over GLYPHWIRE_SOCK and writes several
/// runs with different fg/bg colors, to exercise (and visually prove) the
/// color-rendering path end to end -- see glyphwire/docs/slice_plan.md,
/// Milestone 8. Falls back to a plain stdout message when no glyphwire
/// session is available, same as client/main.zig. Built on src/client.zig
/// rather than hand-rolled JSON, both to dogfood that library and because
/// bufPrint-ing JSON by hand doesn't escape special characters in text.
pub fn main(init: std.process.Init) !void {
    run(init) catch return fallback(init.io);
}

fn fallback(io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll("glyphwire demo: no session, falling back to plain output\n");
    try w.interface.flush();
}

const Run = struct {
    row: usize,
    col: usize,
    text: []const u8,
    fg: glyphwire.Color,
    bg: ?glyphwire.Color = null,
};

fn rgb(r: u8, g: u8, b: u8) glyphwire.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

const runs = [_]Run{
    .{ .row = 0, .col = 0, .text = "glyphwire", .fg = rgb(0, 255, 255) },
    .{ .row = 0, .col = 10, .text = "styled text demo", .fg = rgb(255, 255, 255) },

    .{ .row = 2, .col = 0, .text = "colored text over pixzig", .fg = rgb(255, 255, 255), .bg = rgb(40, 40, 90) },

    .{ .row = 4, .col = 0, .text = "RED", .fg = rgb(255, 85, 85) },
    .{ .row = 4, .col = 4, .text = "GREEN", .fg = rgb(80, 250, 123) },
    .{ .row = 4, .col = 10, .text = "YELLOW", .fg = rgb(241, 250, 140) },
    .{ .row = 4, .col = 17, .text = "BLUE", .fg = rgb(98, 114, 164) },
    .{ .row = 4, .col = 22, .text = "MAGENTA", .fg = rgb(255, 121, 198) },

    .{ .row = 6, .col = 0, .text = "  ", .fg = rgb(0, 0, 0), .bg = rgb(255, 85, 85) },
    .{ .row = 6, .col = 2, .text = "  ", .fg = rgb(0, 0, 0), .bg = rgb(80, 250, 123) },
    .{ .row = 6, .col = 4, .text = "  ", .fg = rgb(0, 0, 0), .bg = rgb(241, 250, 140) },
    .{ .row = 6, .col = 6, .text = "  ", .fg = rgb(0, 0, 0), .bg = rgb(98, 114, 164) },
    .{ .row = 6, .col = 8, .text = "  ", .fg = rgb(0, 0, 0), .bg = rgb(255, 121, 198) },
    .{ .row = 6, .col = 11, .text = "bg color swatches", .fg = rgb(200, 200, 200) },
};

fn run(init: std.process.Init) !void {
    var client = try glyphwire.Client.connectFromEnv(init.io, init.gpa, init.environ_map);
    defer client.deinit();

    for (runs) |r| {
        try client.setCursor(r.row, r.col);
        try client.writeText(r.text, r.fg, r.bg);
    }

    // Images/icons/box-drawing showcase (Phase 3/3.5/3.6) -- a panel built
    // from the bundled "box" tile style, with a row of default icons
    // inside it.
    try client.drawBox(8, 0, 5, 30, "box");
    try client.setCursor(9, 2);
    try client.writeText("icons + box tiles", rgb(255, 255, 255), null);

    const icon_names = [_][]const u8{ "folder", "file", "audio", "image", "video", "archive", "executable", "drive" };
    for (icon_names, 0..) |name, i| {
        try client.drawIcon(11, 2 + i * 2, name);
    }
}
