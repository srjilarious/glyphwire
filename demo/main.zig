// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

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

/// Frames a `rows x cols` cell rect with the bundled `box/*` border tiles
/// (the ones table borders use), one stretched tile per border cell. The
/// panel sits in the root layer's scrollback, so it has to be cells that
/// scroll with the text: a `create_nine_patch` panel is a layer object
/// and would stay put while the shell output moved past it.
fn drawTileFrame(client: *glyphwire.Client, row: usize, col: usize, rows: usize, cols: usize) !void {
    const last_row = row + rows - 1;
    const last_col = col + cols - 1;
    var r = row;
    while (r <= last_row) : (r += 1) {
        var c = col;
        while (c <= last_col) : (c += 1) {
            const top = r == row;
            const bottom = r == last_row;
            const left = c == col;
            const right = c == last_col;
            const piece: []const u8 = if (top and left) "box/tl" else if (top and right) "box/tr" else if (bottom and left) "box/bl" else if (bottom and right) "box/br" else if (top) "box/t" else if (bottom) "box/b" else if (left) "box/l" else if (right) "box/r" else continue;
            try client.drawIconStyled(r, c, piece, .{ .scale = .stretch });
        }
    }
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

    .{ .row = 2, .col = 0, .text = "colored text over glyphwire", .fg = rgb(255, 255, 255), .bg = rgb(40, 40, 90) },

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

    // Images/icons/box-drawing showcase (Phase 3/3.5/3.6) -- a panel framed
    // with the bundled "box" border tiles (`drawTileFrame`), holding two strips of the same
    // default icons: one drawn "fill" style (`.natural`, capped to one
    // cell-height, the way glyphwire-ls's small listings and the shell
    // prompt's `{icon:...}` draw them) and one drawn large (`.natural`,
    // capped to three cell-heights). Both need the session's cell pixel
    // size (`get_cell_metrics`); without it the strip falls back to a
    // plain one-cell `.fit` `draw_icon`.
    try drawTileFrame(&client, panel_row, panel_col, panel_rows, panel_cols);
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

    // Underline styles: the five `write_text` takes, then the two cases that
    // are the reason the attribute exists at all -- a coloured underline
    // under text of a different colour (a diagnostic squiggle over syntax
    // highlighting), and the same thing arriving as an escape sequence in a
    // mirrored program's output.
    const ul_row = intl_row + 5;
    try client.setCursor(ul_row, 0);
    try client.writeText("underline styles:", rgb(200, 200, 200), null);
    const styles = [_]glyphwire.Underline{ .single, .double, .curly, .dotted, .dashed };
    for (styles, 0..) |style, i| {
        try client.writeTextOpts(@tagName(style), .{
            .row = ul_row + 1 + i,
            .col = 2,
            .fg = rgb(220, 220, 228),
            .underline = style,
        });
    }

    // The diagnostic case: the squiggle is red, the code under it is not.
    // `underline_color` is what keeps those two independent.
    try client.writeSpans(&.{
        .{ .text = "const " },
        .{
            .text = "oops",
            .underline = .curly,
            .underline_color = rgb(232, 92, 92),
        },
        .{ .text = " = 1;   " },
        .{
            .text = "warning",
            .underline = .curly,
            .underline_color = rgb(226, 176, 74),
        },
    }, .{
        .row = ul_row + 1 + styles.len,
        .col = 2,
        .fg = rgb(126, 200, 255),
    });

    // And through SGR, the way a compiler's own output would carry it:
    // `4:3` is curly, `58;2;r;g;b` its colour. Note `4:3` and not `4;3` --
    // the latter is an underline followed by an italic.
    try client.writeTextOpts(
        "\x1b[4:3;58;2;232;92;92mvia SGR escape\x1b[0m",
        .{ .row = ul_row + 2 + styles.len, .col = 2, .fg = rgb(220, 220, 228) },
    );

    // Leaves the cursor a couple of blank rows below the last text:
    // draw_icon doesn't move the cursor, so without this it would still
    // sit wherever the last write_text call left it. glyphwire-shell draws
    // its next prompt one row below wherever the cursor ends up after a
    // child runs (see Prompt.submitLine), so leaving it higher up made the
    // next prompt overwrite this output.
    try client.setCursor(ul_row + 4 + styles.len, 0);
}
