const std = @import("std");
const glyphwire = @import("glyphwire");

/// Styled-text demo client: connects over GLYPHWIRE_SOCK and writes several
/// runs with different fg/bg colors, to exercise (and visually prove) the
/// color-rendering path end to end -- see glyphwire/docs/slice_plan.md,
/// Milestone 8. Falls back to a plain stdout message when no glyphwire
/// session is available, same as client/main.zig.
pub fn main(init: std.process.Init) !void {
    const socket_path = init.environ_map.get("GLYPHWIRE_SOCK") orelse return fallback(init.io);

    run(init.io, socket_path) catch return fallback(init.io);
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
    fg: [3]u8,
    bg: ?[3]u8 = null,
};

const runs = [_]Run{
    .{ .row = 0, .col = 0, .text = "glyphwire", .fg = .{ 0, 255, 255 } },
    .{ .row = 0, .col = 10, .text = "styled text demo", .fg = .{ 255, 255, 255 } },

    .{ .row = 2, .col = 0, .text = "colored text over pixzig", .fg = .{ 255, 255, 255 }, .bg = .{ 40, 40, 90 } },

    .{ .row = 4, .col = 0, .text = "RED", .fg = .{ 255, 85, 85 } },
    .{ .row = 4, .col = 4, .text = "GREEN", .fg = .{ 80, 250, 123 } },
    .{ .row = 4, .col = 10, .text = "YELLOW", .fg = .{ 241, 250, 140 } },
    .{ .row = 4, .col = 17, .text = "BLUE", .fg = .{ 98, 114, 164 } },
    .{ .row = 4, .col = 22, .text = "MAGENTA", .fg = .{ 255, 121, 198 } },

    .{ .row = 6, .col = 0, .text = "  ", .fg = .{ 0, 0, 0 }, .bg = .{ 255, 85, 85 } },
    .{ .row = 6, .col = 2, .text = "  ", .fg = .{ 0, 0, 0 }, .bg = .{ 80, 250, 123 } },
    .{ .row = 6, .col = 4, .text = "  ", .fg = .{ 0, 0, 0 }, .bg = .{ 241, 250, 140 } },
    .{ .row = 6, .col = 6, .text = "  ", .fg = .{ 0, 0, 0 }, .bg = .{ 98, 114, 164 } },
    .{ .row = 6, .col = 8, .text = "  ", .fg = .{ 0, 0, 0 }, .bg = .{ 255, 121, 198 } },
    .{ .row = 6, .col = 11, .text = "bg color swatches", .fg = .{ 200, 200, 200 } },
};

fn run(io: std.Io, socket_path: []const u8) !void {
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);

    var msg_buf: [512]u8 = undefined;
    for (runs) |r| {
        const set_cursor = try std.fmt.bufPrint(&msg_buf,
            \\{{"jsonrpc":"2.0","method":"set_property","params":{{"property":"cursor","row":{d},"col":{d}}}}}
        , .{ r.row, r.col });
        try glyphwire.wire.writeFrame(&w.interface, set_cursor);

        const write_text = if (r.bg) |bg|
            try std.fmt.bufPrint(&msg_buf,
                \\{{"jsonrpc":"2.0","method":"write_text","params":{{"text":"{s}","fg":{{"r":{d},"g":{d},"b":{d}}},"bg":{{"r":{d},"g":{d},"b":{d}}}}}}}
            , .{ r.text, r.fg[0], r.fg[1], r.fg[2], bg[0], bg[1], bg[2] })
        else
            try std.fmt.bufPrint(&msg_buf,
                \\{{"jsonrpc":"2.0","method":"write_text","params":{{"text":"{s}","fg":{{"r":{d},"g":{d},"b":{d}}}}}}}
            , .{ r.text, r.fg[0], r.fg[1], r.fg[2] });
        try glyphwire.wire.writeFrame(&w.interface, write_text);
    }
    try w.interface.flush();
}
