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

// The box/icon panel's region -- named so the final cursor placement (see
// `run`) can stay in sync with wherever the panel actually is instead of
// duplicating its row/col/rows/cols as separate magic numbers.
const panel_row = 8;
const panel_col = 0;
const panel_rows = 5;
const panel_cols = 30;

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

    // Clears the whole grid up front, not just the panel's own region:
    // this demo writes to several disjoint areas (the `runs` text above
    // the panel, the panel itself), and a re-run against an
    // already-drawn-on grid (e.g. running it twice from the shell prompt)
    // would otherwise leave stale content peeking out from under/around
    // whatever's redrawn this time.
    try client.clear(0, 0, null, null);

    for (runs) |r| {
        try client.setCursor(r.row, r.col);
        try client.writeText(r.text, r.fg, r.bg);
    }

    // Images/icons/box-drawing showcase (Phase 3/3.5/3.6) -- a panel built
    // from the bundled "box" tile style, with a row of default icons
    // inside it.
    try client.drawBox(panel_row, panel_col, panel_rows, panel_cols, "box");
    try client.setCursor(panel_row + 1, panel_col + 2);
    try client.writeText("icons + box tiles", rgb(255, 255, 255), null);

    const icon_names = [_][]const u8{ "folder", "file", "audio", "image", "video", "archive", "executable", "drive" };
    for (icon_names, 0..) |name, i| {
        try client.drawIcon(panel_row + 3, panel_col + 2 + i * 2, name);
    }

    // Leaves the cursor a couple of blank rows below the panel: none of
    // draw_box/draw_icon move the cursor, so without this it would still
    // sit wherever the last write_text call ("icons + box tiles") left
    // it -- inside the panel. glyphwire-shell draws its next prompt one
    // row below wherever the cursor ends up after a child runs (see
    // Prompt.submitLine), so leaving it inside the panel made the next
    // prompt overwrite the icon row.
    try client.setCursor(panel_row + panel_rows + 2, 0);
}
