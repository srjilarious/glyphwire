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
// duplicating its row/col/rows/cols as separate magic numbers. Tall/wide
// enough for a title, a "fill" icon row (`.natural`, one cell-height), and
// a "large" icon row (`.natural`, three cell-heights, so it overflows a
// row up and down from its anchor).
const panel_row = 8;
const panel_col = 0;
const panel_rows = 13;
const panel_cols = 46;

// Rows inside the panel the two icon strips are anchored on, and the
// column the first icon of each starts at.
const icon_col0 = panel_col + 2;
const fill_icon_row = panel_row + 4;
const large_icon_row = panel_row + 9;

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
    // from the bundled "box" tile style, holding two strips of the same
    // default icons: one drawn "fill" style (`.natural`, capped to one
    // cell-height, the way glyphwire-ls's small listings and the shell
    // prompt's `{icon:...}` draw them) and one drawn large (`.natural`,
    // capped to three cell-heights). Both need the session's cell pixel
    // size (`get_cell_metrics`); without it the strip falls back to a
    // plain one-cell `.fit` `draw_icon`.
    try client.drawBox(panel_row, panel_col, panel_rows, panel_cols, "box");
    try client.setCursor(panel_row + 1, panel_col + 2);
    try client.writeText("icons + box tiles", rgb(255, 255, 255), null);

    const icon_names = [_][]const u8{ "file/folder", "file/file", "file/audio", "file/image", "file/video", "file/archive", "file/executable", "file/drive" };
    const metrics = client.getCellMetrics() catch null;

    try client.setCursor(panel_row + 3, panel_col + 2);
    try client.writeText("fill (1 line tall):", rgb(180, 180, 180), null);
    for (icon_names, 0..) |name, i| {
        const col = icon_col0 + i * 3;
        if (metrics) |m| {
            try client.drawIconStyled(fill_icon_row, col, name, .{
                .scale = .natural,
                .h_align = .start,
                .v_align = .center,
                .max_h = m.h,
            });
        } else {
            try client.drawIcon(fill_icon_row, col, name);
        }
    }

    try client.setCursor(panel_row + 6, panel_col + 2);
    try client.writeText("large (3 lines tall):", rgb(180, 180, 180), null);
    for (icon_names, 0..) |name, i| {
        const col = icon_col0 + i * 5;
        if (metrics) |m| {
            try client.drawIconStyled(large_icon_row, col, name, .{
                .scale = .natural,
                .h_align = .start,
                .v_align = .center,
                .max_h = 3 * m.h,
            });
        } else {
            try client.drawIcon(large_icon_row, col, name);
        }
    }

    // Non-Latin "Hello World" runs: exercises the host font atlas's
    // dynamic-codepoint path (Greek and Cyrillic from the primary Noto
    // Sans Mono CJK face, Japanese kana + kanji from the same face). Any
    // codepoint no face provides would show as a tofu box.
    const intl_row = panel_row + panel_rows + 1;
    try client.setCursor(intl_row, 0);
    try client.writeText("hello world, in more scripts:", rgb(200, 200, 200), null);
    try client.setCursor(intl_row + 1, 2);
    try client.writeText("Greek:   \u{0393}\u{03B5}\u{03B9}\u{03B1} \u{03C3}\u{03BF}\u{03C5} \u{039A}\u{03CC}\u{03C3}\u{03BC}\u{03B5}", rgb(126, 200, 255), null);
    try client.setCursor(intl_row + 2, 2);
    try client.writeText("Russian: \u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043C}\u{0438}\u{0440}", rgb(255, 184, 108), null);
    try client.setCursor(intl_row + 3, 2);
    try client.writeText("Japanese: \u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{4E16}\u{754C}", rgb(80, 250, 123), null);

    // Leaves the cursor a couple of blank rows below the last text: none of
    // draw_box/draw_icon move the cursor, so without this it would still
    // sit wherever the last write_text call left it. glyphwire-shell draws
    // its next prompt one row below wherever the cursor ends up after a
    // child runs (see Prompt.submitLine), so leaving it higher up made the
    // next prompt overwrite this output.
    try client.setCursor(intl_row + 5, 0);
}
