const std = @import("std");
const glyphwire = @import("glyphwire");

/// Table widget demo: connects over GLYPHWIRE_SOCK and draws three tables
/// side by side -- full border, ruled header with no border, and fully
/// bare -- to visually prove `Client.startTable`'s style options. See
/// table.zig's `Table` doc comment for the widget itself. Falls back to a
/// plain stdout message when no glyphwire session is available, same as
/// demo/main.zig.
pub fn main(init: std.process.Init) !void {
    run(init) catch return fallback(init.io);
}

fn fallback(io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll("glyphwire table-demo: no session, falling back to plain output\n");
    try w.interface.flush();
}

fn rgb(r: u8, g: u8, b: u8) glyphwire.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

const Entry = struct { name: []const u8, kind: []const u8, size: []const u8 };

const entries = [_]Entry{
    .{ .name = "main.zig", .kind = "file", .size = "4.2K" },
    .{ .name = "a_much_longer_source_file_name.zig", .kind = "file", .size = "18K" },
    .{ .name = "assets", .kind = "dir", .size = "-" },
    .{ .name = "build.zig", .kind = "file", .size = "812" },
};

fn run(init: std.process.Init) !void {
    var client = try glyphwire.Client.connectFromEnv(init.io, init.gpa, init.environ_map);
    defer client.deinit();

    try client.clear(0, 0, null, null);

    try client.setCursor(0, 0);
    try client.writeText("glyphwire table demo", rgb(0, 255, 255), null);

    var bordered = try client.startTable(.{
        .row = 2,
        .col = 0,
        .columns = &.{
            .{ .name = "Name", .width = 24 },
            .{ .name = "Kind", .width = 6 },
            .{ .name = "Size", .width = 6, .h_align = .end },
        },
        .style = .{ .alt_row_bg = rgb(30, 30, 30), .header_fg = rgb(241, 250, 140) },
    });
    for (entries) |e| {
        try bordered.row();
        try bordered.cell(e.name);
        try bordered.cell(e.kind);
        try bordered.cell(e.size);
        try bordered.endRow();
    }
    try bordered.end();

    const ruled_col = bordered.total_width + 4;
    try client.setCursor(2, ruled_col);
    try client.writeText("ruled, no border:", rgb(255, 255, 255), null);

    var ruled = try client.startTable(.{
        .row = 3,
        .col = ruled_col,
        .columns = &.{
            .{ .name = "Name", .width = 24 },
            .{ .name = "Kind", .width = 6 },
        },
        .style = .{ .borders = false, .alt_row_bg = rgb(30, 30, 30) },
    });
    for (entries) |e| {
        try ruled.row();
        try ruled.cell(e.name);
        try ruled.cell(e.kind);
        try ruled.endRow();
    }
    try ruled.end();

    const bare_col = ruled_col + ruled.total_width + 4;
    try client.setCursor(2, bare_col);
    try client.writeText("bare:", rgb(255, 255, 255), null);

    var bare = try client.startTable(.{
        .row = 3,
        .col = bare_col,
        .columns = &.{
            .{ .name = "Name", .width = 24 },
            .{ .name = "Kind", .width = 6 },
        },
        .style = .{ .borders = false, .header_separator = false },
    });
    for (entries) |e| {
        try bare.row();
        try bare.cell(e.name);
        try bare.cell(e.kind);
        try bare.endRow();
    }
    try bare.end();

    try client.setCursor(2 + entries.len + 4, 0);

    // Stay open until dismissed (any keypress) rather than returning
    // immediately -- same reasoning as view/main.zig's identical wait:
    // glyphwire-host closes its window the instant an exec'd child exits,
    // which would otherwise make the tables flash and vanish before
    // they're visible at all.
    const listener = glyphwire.InputListener.connectFromEnv(init.io, init.gpa, init.environ_map, &.{"key"}) catch return;
    defer listener.deinit();
    while (true) {
        const ev = (try listener.waitKeyEvent(.{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } })) orelse continue;
        defer init.gpa.free(ev.key);
        if (ev.pressed) return;
    }
}
