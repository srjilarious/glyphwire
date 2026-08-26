const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

/// A minimal byte stream `pngDimensions` accepts -- see client_tests.zig's
/// identical fixture.
fn fakePngBytes(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, bytes[8..12], 13, .big);
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

/// Loads a distinct fake image per piece, in `pieces` order, and registers
/// each as `"{style}-{piece}"` directly on `ctx` -- mirrors
/// dispatch_tests.zig's `registerTestBoxStyle`, but goes through a real
/// `Client.loadImage` call (over the same socket the table itself draws
/// through) since this file drives everything through `Client`, not the
/// `Dispatcher` directly. Handles come back 1..9 in `pieces` order, since
/// this is the only connection loading images on a fresh `Context` --
/// callers rely on that fixed numbering instead of re-deriving it.
const pieces = [_][]const u8{ "tl", "t", "tr", "l", "fill", "r", "bl", "b", "br" };

fn registerTestBoxStyle(client: *glyphwire.Client, ctx: *glyphwire.Context, style: []const u8) !void {
    for (pieces) |piece| {
        const png = fakePngBytes(12, 12);
        const handle = try client.loadImage("png", &png);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}-{s}", .{ style, piece });
        try ctx.registerIcon(name, handle);
    }
}

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}

/// End-to-end proof of `Client.startTable`'s streaming shape: a 2-column
/// (widths 8 and 4), bordered, striped table with two body rows, checked
/// cell-by-cell against `getCells`. Layout: column 0 is `[1, 9)`, a gap at
/// col 9, column 1 is `[10, 14)`, border tiles at cols 0 and 14 -- 15 cells
/// wide (`table.total_width`) in total.
pub fn startTableDrawsBorderedStripedTableTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 30, 10, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-table-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    try registerTestBoxStyle(&client, &ctx, "box");
    // Handles per registerTestBoxStyle's fixed 1..9 numbering, in `pieces`
    // order: tl=1, t=2, tr=3, l=4, fill=5, r=6, bl=7, b=8, br=9.

    var table = try client.startTable(.{
        .row = 0,
        .col = 0,
        .columns = &.{
            .{ .name = "Name", .width = 8 },
            .{ .name = "Size", .width = 4, .h_align = .end },
        },
        .style = .{ .alt_row_bg = .{ .r = 20, .g = 20, .b = 20 } },
    });
    try testz.expectEqual(table.total_width, 15);

    try table.row();
    try table.cell("main.zig");
    try table.cell("42");
    try table.endRow();

    try table.row();
    try table.cell("a_very_long_filename.zig");
    try table.cell("7");
    try table.endRow();

    try table.end();

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    // Row 0: top border.
    try testz.expectEqual(snapshot.cellAt(0, 0).bg_icon.?.handle, 1); // tl
    try testz.expectEqual(snapshot.cellAt(0, 7).bg_icon.?.handle, 2); // t
    try testz.expectEqual(snapshot.cellAt(0, 14).bg_icon.?.handle, 3); // tr

    // Row 1: header text, left-aligned in column 0's 8 cells, side border tiles present.
    try testz.expectEqualStr("N", snapshot.cellAt(1, 1).grapheme);
    try testz.expectEqualStr("a", snapshot.cellAt(1, 2).grapheme);
    try testz.expectEqualStr(" ", snapshot.cellAt(1, 5).grapheme); // trailing pad
    try testz.expectEqual(snapshot.cellAt(1, 0).bg_icon.?.handle, 4); // l
    try testz.expectEqual(snapshot.cellAt(1, 14).bg_icon.?.handle, 6); // r

    // Row 2: header separator -- horizontal "t" tiles across the interior only.
    try testz.expectEqual(snapshot.cellAt(2, 5).bg_icon.?.handle, 2); // t

    // Row 3: first body row -- "main.zig" fills column 0 exactly (8 chars,
    // 8-wide), "42" right-aligned into column 1's 4 cells (cols 10-13).
    try testz.expectEqualStr("m", snapshot.cellAt(3, 1).grapheme);
    try testz.expectEqualStr("g", snapshot.cellAt(3, 8).grapheme);
    try testz.expectEqualStr("4", snapshot.cellAt(3, 12).grapheme);
    try testz.expectEqualStr("2", snapshot.cellAt(3, 13).grapheme);

    // Row 4: second body row (row_index == 1) is striped, and its long
    // filename is truncated with a trailing ellipsis to fit column 0's 8 cells.
    try testz.expectEqualStr("a", snapshot.cellAt(4, 1).grapheme);
    try testz.expectEqualStr("\u{2026}", snapshot.cellAt(4, 8).grapheme);
    try testz.expectEqual(snapshot.cellAt(4, 1).bg.?.r, 20);
    try testz.expectEqual(snapshot.cellAt(4, 9).bg.?.r, 20); // gap cell between columns is striped too

    // Row 5: bottom border.
    try testz.expectEqual(snapshot.cellAt(5, 0).bg_icon.?.handle, 7); // bl
    try testz.expectEqual(snapshot.cellAt(5, 7).bg_icon.?.handle, 8); // b
    try testz.expectEqual(snapshot.cellAt(5, 14).bg_icon.?.handle, 9); // br
}

pub fn startTableWithoutBordersStartsContentAtColumnZeroTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-table-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    var table = try client.startTable(.{
        .row = 0,
        .col = 0,
        .columns = &.{
            .{ .name = "A", .width = 3 },
            .{ .name = "B", .width = 3 },
        },
        .style = .{ .borders = false, .header_separator = false },
    });

    try table.row();
    try table.cell("x");
    try table.cell("y");
    try table.endRow();
    try table.end();

    // No border columns at all: content_width == total_width, and the
    // header starts at column 0, not column 1.
    try testz.expectEqual(table.total_width, table.content_width);
    try testz.expectEqual(table.content_start_col, 0);

    var snapshot = try client.getCells();
    defer snapshot.deinit();
    try testz.expectEqualStr("A", snapshot.cellAt(0, 0).grapheme);
    try testz.expectEqualStr("x", snapshot.cellAt(1, 0).grapheme);
}

/// `header_separator` is independent of `borders`: a borderless table can
/// still draw the header/body rule (no side "l"/"r" endpoints, since there
/// are no border columns to anchor them to -- just "t" tiles across the
/// full content width), and stripe body rows same as a bordered one.
pub fn startTableWithHeaderSeparatorButNoBordersDrawsRuleAcrossContentWidthTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 6, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-table-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    try registerTestBoxStyle(&client, &ctx, "box");
    // t=2, per registerTestBoxStyle's fixed pieces-order numbering.

    var table = try client.startTable(.{
        .row = 0,
        .col = 0,
        .columns = &.{
            .{ .name = "A", .width = 3 },
            .{ .name = "B", .width = 3 },
        },
        .style = .{ .borders = false, .alt_row_bg = .{ .r = 20, .g = 20, .b = 20 } },
    });

    try table.row();
    try table.cell("x");
    try table.cell("y");
    try table.endRow();
    try table.row();
    try table.cell("z");
    try table.cell("w");
    try table.endRow();
    try table.end();

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    // Row 0: header. Row 1: the rule, spanning content_width == 7
    // (3 + 1 gap + 3), no border tiles anywhere in it.
    try testz.expectEqualStr("A", snapshot.cellAt(0, 0).grapheme);
    try testz.expectEqual(snapshot.cellAt(1, 0).bg_icon.?.handle, 2); // t
    try testz.expectEqual(snapshot.cellAt(1, 6).bg_icon.?.handle, 2); // t, last content column
    try testz.expectTrue(snapshot.cellAt(1, 0).bg_icon.?.scale == .stretch);

    // Row 2: first body row, unstriped. Row 3: second body row (row_index
    // == 1), striped -- same alternating rule a bordered table uses.
    try testz.expectEqualStr("z", snapshot.cellAt(3, 0).grapheme);
    try testz.expectEqual(snapshot.cellAt(3, 0).bg.?.r, 20);
}
