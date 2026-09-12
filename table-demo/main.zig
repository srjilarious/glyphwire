const std = @import("std");
const glyphwire = @import("glyphwire");

/// Table widget demo: connects over GLYPHWIRE_SOCK and creates three
/// tables side by side -- full border, ruled header with no border, and
/// fully bare -- to visually prove `Client.createTable`'s style options.
/// Unlike the original client-composited prototype this replaced, each
/// table here is real server-side state (`core.Table`, decisions.md's
/// Table section): once `tableSetRows` sends the rows, the table stays
/// visible (and could be re-sorted via `tableSetSort`) even after this
/// process exits -- there's nothing left for it to keep alive. Falls
/// back to a plain stdout message when no glyphwire session is
/// available, same as demo/main.zig.
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

/// Builds the `[row][col]` cell matrix `tableSetRows` wants from
/// `entries`, for a table with `cols` columns -- the 2-column tables
/// below just leave `size` unused by passing `cols = 2`.
fn buildRows(alloc: std.mem.Allocator, cols: usize) ![][]glyphwire.Client.TableCellInput {
    const rows = try alloc.alloc([]glyphwire.Client.TableCellInput, entries.len);
    for (entries, 0..) |e, i| {
        const row = try alloc.alloc(glyphwire.Client.TableCellInput, cols);
        row[0] = .{ .display = e.name };
        row[1] = .{ .display = e.kind };
        if (cols > 2) row[2] = .{ .display = e.size };
        rows[i] = row;
    }
    return rows;
}

fn run(init: std.process.Init) !void {
    const alloc = init.gpa;
    var client = try glyphwire.Client.connectFromEnv(init.io, alloc, init.environ_map);
    defer client.deinit();

    try client.clear(0, 0, null, null);

    try client.setCursor(0, 0);
    try client.writeText("glyphwire table demo", rgb(0, 255, 255), null);

    const bordered_rows = try buildRows(alloc, 3);
    const bordered = try client.createTable(null, 2, 0, &.{
        .{ .name = "Name", .width = 24 },
        .{ .name = "Kind", .width = 6 },
        .{ .name = "Size", .width = 6, .h_align = .end },
    }, .{ .alt_row_bg = rgb(30, 30, 30), .header_fg = rgb(241, 250, 140) });
    try client.tableSetRows(null, bordered, bordered_rows);
    // Bordered content width (name 24 + gap 1 + kind 6 + gap 1 + size 6)
    // plus 2 border columns -- hardcoded here (a demo, not a layout
    // engine) rather than asking the server to report it back.
    const ruled_col = 40 + 4;

    try client.setCursor(2, ruled_col);
    try client.writeText("ruled, no border:", rgb(255, 255, 255), null);

    const ruled_rows = try buildRows(alloc, 2);
    const ruled = try client.createTable(null, 3, ruled_col, &.{
        .{ .name = "Name", .width = 24 },
        .{ .name = "Kind", .width = 6 },
    }, .{ .borders = false, .alt_row_bg = rgb(30, 30, 30) });
    try client.tableSetRows(null, ruled, ruled_rows);
    const bare_col = ruled_col + 31 + 4;

    try client.setCursor(2, bare_col);
    try client.writeText("bare:", rgb(255, 255, 255), null);

    const bare_rows = try buildRows(alloc, 2);
    const bare = try client.createTable(null, 3, bare_col, &.{
        .{ .name = "Name", .width = 24 },
        .{ .name = "Kind", .width = 6 },
    }, .{ .borders = false, .header_separator = false });
    try client.tableSetRows(null, bare, bare_rows);

    try client.setCursor(2 + entries.len + 4, 0);

    // Stay open until dismissed (any keypress) rather than returning
    // immediately -- same reasoning as view/main.zig's identical wait:
    // glyphwire-host closes its window the instant an exec'd child exits,
    // which would otherwise make the tables flash and vanish before
    // they're visible at all. Unlike the prototype this replaced, the
    // tables would actually survive that exit now -- this wait is purely
    // so a person running the demo interactively gets to look at them.
    const listener = glyphwire.InputListener.connectFromEnv(init.io, alloc, init.environ_map, &.{"key"}) catch return;
    defer listener.deinit();
    while (true) {
        const input_ev = (try listener.waitInputEvent(.{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } })) orelse continue;
        defer input_ev.deinit(alloc);
        switch (input_ev) {
            .key => |k| if (k.pressed) return,
            .text, .paste => {},
            .copy_request => {},
            .shutdown => return,
            // A window manager's own commands (see `InputEvent.window_key`).
            // Never delivered here: this program is not one.
            .window_key, .window_text => {},
        }
    }
}
