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

/// `iconCellStyled`/`cellStyled` -- added for glyphwire-ls's `-l` table
/// (icon + colored name column, both tagged for click-to-activate) -- draw
/// into their own column in order same as plain `cell`/`iconCell`, apply
/// the given fg (`cellStyled`) instead of the default, and tag every cell
/// they touch with `metadata_id` when given, same as `Client.writeTextTagged`.
pub fn iconCellAndCellStyledApplyColorAndMetadataTagTest(io: std.Io, alloc: std.mem.Allocator) !void {
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

    const png = fakePngBytes(12, 12);
    const folder_handle = try client.loadImage("png", &png);
    try ctx.registerIcon("folder", folder_handle);

    const metadata_id = try client.createMetadata("{\"kind\":\"dir\"}");

    var table = try client.startTable(.{
        .row = 0,
        .col = 0,
        .columns = &.{
            .{ .name = "", .width = 1 },
            .{ .name = "Name", .width = 6 },
        },
        .style = .{ .borders = false, .header_separator = false },
    });

    try table.row();
    try table.iconCellStyled("folder", .{ .metadata_id = metadata_id });
    try table.cellStyled("src", .{ .fg = .{ .r = 98, .g = 114, .b = 164, .a = 255 }, .metadata_id = metadata_id });
    try table.endRow();
    try table.end();

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    // Row 0 is the header (its icon column's name is "", but the header
    // row itself is always drawn regardless of `header_separator` -- only
    // the divider *line* is skipped -- so the body row `row`/`iconCellStyled`/
    // `cellStyled` wrote is row 1, not row 0.
    const icon_cell = snapshot.cellAt(1, 0);
    try testz.expectEqual(icon_cell.bg_icon.?.handle, folder_handle);
    try testz.expectTrue(icon_cell.bg_icon.?.scale == .fit);
    try testz.expectEqual(icon_cell.metadata_id.?, metadata_id);

    const name_cell = snapshot.cellAt(1, 2);
    try testz.expectEqualStr("s", name_cell.grapheme);
    try testz.expectEqual(name_cell.fg.r, 98);
    try testz.expectEqual(name_cell.fg.b, 164);
    try testz.expectEqual(name_cell.metadata_id.?, metadata_id);
}

/// A table anchored at/past a small layer's bottom row must scroll
/// *once* per body row, not once per cell/tile it draws for that row --
/// `Layer.resolveRow` (core.zig) scrolls relative to whatever's currently
/// at the top every time it's called with an out-of-bounds row, so
/// `row`/`cell`/`endRow` calling it with the same nominal row number more
/// than once per logical row (one for the icon, one per text cell) would
/// otherwise compound into runaway extra scrolling, scattering one row's
/// cells across several different physical rows instead of landing them
/// on the same one. Regression test for exactly that bug, fixed by
/// `Table.resolveCurRow`.
pub fn startTableScrollsExactlyOncePerRowNearLayerBottomTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 200);
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

    const png = fakePngBytes(12, 12);
    const file_handle = try client.loadImage("png", &png);
    try ctx.registerIcon("file", file_handle);

    // Row 8 of a 10-row layer: only 2 rows of headroom before every body
    // row after the first needs a scroll.
    try client.setCursor(8, 0);

    var table = try client.startTable(.{
        .columns = &.{
            .{ .name = "", .width = 1 },
            .{ .name = "Name", .width = 10 },
            .{ .name = "Size", .width = 5, .h_align = .end },
        },
        .style = .{ .borders = false, .header_separator = false },
    });

    var name_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const name = std.fmt.bufPrint(&name_buf, "entry{d}", .{i}) catch "entry";
        try table.row();
        try table.iconCell("file");
        try table.cell(name);
        try table.cell("1K");
        try table.endRow();
    }
    try table.end();

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    // 13 lines total (1 header + 12 entries) into a viewport with 2 rows
    // of headroom (started at row 8 of 10): the last 10 lines fill the
    // viewport exactly, so entry2..entry11 are visible, one per row, each
    // with its icon, name, and (right-aligned in a 5-wide column starting
    // at col 13, so "1K" lands at cols 16-17) size all landing together on
    // the same physical row -- not scattered across several, which is
    // what this test guards against.
    var expected: usize = 2;
    var row: usize = 0;
    while (row < 10) : ({
        row += 1;
        expected += 1;
    }) {
        var expected_buf: [16]u8 = undefined;
        const expected_name = try std.fmt.bufPrint(&expected_buf, "entry{d}", .{expected});

        try testz.expectEqual(snapshot.cellAt(row, 0).bg_icon.?.handle, file_handle);
        try testz.expectEqualStr(expected_name[0..1], snapshot.cellAt(row, 2).grapheme);
        try testz.expectEqualStr("1", snapshot.cellAt(row, 16).grapheme);
        try testz.expectEqualStr("K", snapshot.cellAt(row, 17).grapheme);
    }
}
