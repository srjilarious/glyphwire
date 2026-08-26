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

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}

/// `create_table` + `table_set_rows` compiling structured data into
/// ordinary cells -- see core.zig's Table section. A 2-column, borderless,
/// unruled table with 2 body rows: header at row 0, body rows 1-2 (no
/// header separator line), both columns start-aligned so padding math
/// stays simple (right-alignment is covered by
/// `tableColumnHAlignEndRightAlignsTextTest` instead).
pub fn createTableAndSetRowsPaintsHeaderAndBodyTest(io: std.Io, alloc: std.mem.Allocator) !void {
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

    const table = try client.createTable(null, 0, 0, &.{
        .{ .name = "Name", .width = 8 },
        .{ .name = "Num", .width = 4 },
    }, .{ .borders = false, .header_separator = false });

    try client.tableSetRows(null, table, &.{
        &.{ .{ .display = "alpha" }, .{ .display = "3" } },
        &.{ .{ .display = "bravo" }, .{ .display = "9" } },
    });

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    // Header row.
    try testz.expectEqualStr("N", snapshot.cellAt(0, 0).grapheme);
    try testz.expectEqualStr("e", snapshot.cellAt(0, 3).grapheme);
    try testz.expectEqualStr("N", snapshot.cellAt(0, 9).grapheme);

    // Body row 0: "alpha" start-padded to 8, gap, "3" start-padded to 4.
    try testz.expectEqualStr("a", snapshot.cellAt(1, 0).grapheme);
    try testz.expectEqualStr("a", snapshot.cellAt(1, 4).grapheme);
    try testz.expectEqualStr(" ", snapshot.cellAt(1, 5).grapheme);
    // Column 0's own trailing pad (cols 5-7) is written by writeBodyRow;
    // col 8 is the inter-column gap, left untouched (still the blank
    // `clearExtent` left it -- see `Table.render`) on an unstriped row,
    // unlike the header row's own gap, which `writeHeaderRow` always
    // writes a literal space into.
    try testz.expectEqualStr("", snapshot.cellAt(1, 8).grapheme);
    try testz.expectEqualStr("3", snapshot.cellAt(1, 9).grapheme);
    try testz.expectEqualStr(" ", snapshot.cellAt(1, 10).grapheme);

    // Body row 1.
    try testz.expectEqualStr("b", snapshot.cellAt(2, 0).grapheme);
    try testz.expectEqualStr("9", snapshot.cellAt(2, 9).grapheme);
}

/// A `h_align: .end` column right-aligns its (padded) text within its
/// width -- a 6-wide column holding `"9"` should land that digit at the
/// column's last cell, not its first.
pub fn tableColumnHAlignEndRightAlignsTextTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
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

    const table = try client.createTable(null, 0, 0, &.{
        .{ .name = "Size", .width = 6, .h_align = .end },
    }, .{ .borders = false, .header_separator = false });

    try client.tableSetRows(null, table, &.{
        &.{.{ .display = "9" }},
    });

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    try testz.expectEqualStr(" ", snapshot.cellAt(1, 0).grapheme);
    try testz.expectEqualStr("9", snapshot.cellAt(1, 5).grapheme);
}

/// A cell's `icon` (an icon-registry name, resolved server-side)
/// reserves exactly one cell at the column's start when `row_height == 1`
/// (`.fit`-scaled into it), with the cell's `display` text starting right
/// after -- see `core.Table.writeBodyRow`'s doc comment.
pub fn tableCellIconReservesOneColumnAtDefaultRowHeightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
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

    const table = try client.createTable(null, 0, 0, &.{
        .{ .name = "", .width = 6 },
    }, .{ .borders = false, .header_separator = false });

    try client.tableSetRows(null, table, &.{
        &.{.{ .display = "x", .icon = "file" }},
    });

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    const icon_cell = snapshot.cellAt(1, 0);
    try testz.expectEqual(icon_cell.bg_icon.?.handle, file_handle);
    try testz.expectTrue(icon_cell.bg_icon.?.scale == .fit);
    try testz.expectEqualStr("x", snapshot.cellAt(1, 1).grapheme);
}

/// `table_set_sort` reorders the *display* order (via `SortKey.number`,
/// not the display text -- `"9"` sorting after `"10"` lexically would be
/// the wrong answer here) without touching the underlying row data.
/// Ascending then descending on the same table, since a real client
/// toggling a column's sort would do exactly that.
pub fn tableSetSortReordersRowsByNumericSortKeyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
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

    const table = try client.createTable(null, 0, 0, &.{
        .{ .name = "Name", .width = 4 },
        .{ .name = "Num", .width = 4, .kind = .number, .sortable = true },
    }, .{ .borders = false, .header_separator = false });

    try client.tableSetRows(null, table, &.{
        &.{ .{ .display = "c" }, .{ .display = "30", .sort_key = .{ .number = 30 } } },
        &.{ .{ .display = "a" }, .{ .display = "10", .sort_key = .{ .number = 10 } } },
        &.{ .{ .display = "b" }, .{ .display = "20", .sort_key = .{ .number = 20 } } },
    });

    {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        // Unsorted: insertion order.
        try testz.expectEqualStr("c", snapshot.cellAt(1, 0).grapheme);
        try testz.expectEqualStr("a", snapshot.cellAt(2, 0).grapheme);
        try testz.expectEqualStr("b", snapshot.cellAt(3, 0).grapheme);
    }

    try client.tableSetSort(null, table, 1, .ascending);
    {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        try testz.expectEqualStr("a", snapshot.cellAt(1, 0).grapheme);
        try testz.expectEqualStr("b", snapshot.cellAt(2, 0).grapheme);
        try testz.expectEqualStr("c", snapshot.cellAt(3, 0).grapheme);
    }

    try client.tableSetSort(null, table, 1, .descending);
    {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        try testz.expectEqualStr("c", snapshot.cellAt(1, 0).grapheme);
        try testz.expectEqualStr("b", snapshot.cellAt(2, 0).grapheme);
        try testz.expectEqualStr("a", snapshot.cellAt(3, 0).grapheme);
    }
}

/// `table_set_style` replaces the whole style (e.g. toggling `alt_row_bg`
/// on) and repaints immediately -- the message a future "checkbox for
/// alternating row colors" UI would call.
pub fn tableSetStyleTogglesAltRowBgTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
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

    const table = try client.createTable(null, 0, 0, &.{
        .{ .name = "Name", .width = 4 },
    }, .{ .borders = false, .header_separator = false });

    try client.tableSetRows(null, table, &.{
        &.{.{ .display = "a" }},
        &.{.{ .display = "b" }},
    });

    {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        // No striping yet: second row's background is still default.
        try testz.expectEqual(snapshot.cellAt(2, 0).bg.?.r, 0);
    }

    try client.tableSetStyle(null, table, .{
        .borders = false,
        .header_separator = false,
        .alt_row_bg = .{ .r = 30, .g = 30, .b = 30, .a = 255 },
    });

    var snapshot = try client.getCells();
    defer snapshot.deinit();
    try testz.expectEqual(snapshot.cellAt(1, 0).bg.?.r, 0);
    try testz.expectEqual(snapshot.cellAt(2, 0).bg.?.r, 30);
}

/// `destroy_table` blanks whatever the table last painted -- a client
/// checking `get_cells` afterward should see that region back to a
/// default, untagged cell, not stale content.
pub fn destroyTableBlanksItsRegionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
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

    const table = try client.createTable(null, 0, 0, &.{
        .{ .name = "Name", .width = 4 },
    }, .{ .borders = false, .header_separator = false });
    try client.tableSetRows(null, table, &.{
        &.{.{ .display = "a" }},
    });

    {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        try testz.expectEqualStr("N", snapshot.cellAt(0, 0).grapheme);
        try testz.expectEqualStr("a", snapshot.cellAt(1, 0).grapheme);
    }

    try client.destroyTable(null, table);

    var snapshot = try client.getCells();
    defer snapshot.deinit();
    try testz.expectEqualStr("", snapshot.cellAt(0, 0).grapheme);
    try testz.expectEqualStr("", snapshot.cellAt(1, 0).grapheme);
}

/// A table pinned near a layer's bottom edge that doesn't fully fit
/// *scrolls* the layer first so its whole height ends up visible, the
/// same "make room for new output" a real terminal gives anything else
/// drawn near the bottom -- not the fixed-anchor "clip whatever falls
/// off the edge" behavior a `draw_box`/`draw_image` rectangle gets.
/// Table.render` resolves this once per render (`Layer.resolveRow`
/// against the table's *bottom* row, see that method's doc comment), not
/// once per cell the way the client-composited prototype this replaced
/// first got wrong.
///
/// 5-row layer, no scrollback (`scrollback_rows: 0`): a sentinel written
/// at row 0 before the table exists proves the scroll actually happened
/// (and, with no scrollback to catch it, was evicted) -- if the table
/// had clipped instead of scrolling per the prototype's now-obsolete
/// behavior, the sentinel would still be exactly where it was and the
/// table's second body row would be missing instead.
pub fn tableNearLayerBottomScrollsToFitInsteadOfClippingTest(io: std.Io, alloc: std.mem.Allocator) !void {
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

    try client.setCursor(0, 0);
    try client.writeText("!", .{ .r = 255, .g = 255, .b = 255 }, null);

    // Anchored at row 3 of a 5-row layer wanting 3 total lines (header +
    // 2 body rows, no separator): only 2 lines of headroom exist there
    // (rows 3-4), one short -- exactly one scroll is needed to fit the
    // whole table, landing it at rows 2-4 instead.
    const table = try client.createTable(null, 3, 0, &.{
        .{ .name = "Name", .width = 4 },
    }, .{ .borders = false, .header_separator = false });
    try client.tableSetRows(null, table, &.{
        &.{.{ .display = "a" }},
        &.{.{ .display = "b" }},
    });

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    // The sentinel was scrolled off (evicted -- no scrollback configured).
    try testz.expectEqualStr("", snapshot.cellAt(0, 0).grapheme);
    // The whole table is now visible, shifted up by exactly one row.
    try testz.expectEqualStr("N", snapshot.cellAt(2, 0).grapheme);
    try testz.expectEqualStr("a", snapshot.cellAt(3, 0).grapheme);
    try testz.expectEqualStr("b", snapshot.cellAt(4, 0).grapheme);

    const state = try client.tableGetState(null, table);
    try testz.expectEqual(state.painted.row, 2);
    try testz.expectEqual(state.painted.rows, 3);
}

/// `table_get_state`'s `painted` extent reports the table's *actual*
/// on-screen footprint, not just its row count -- a caller placing its
/// own next content below the table (`glyphwire-ls -l`'s next shell
/// prompt; see ls/main.zig's `writeLongTable`) needs `painted.row +
/// painted.rows`, not something it recomputed itself from row count
/// alone, which would drift the moment `Table.render`'s layout changes.
/// Two tables here: bordered/separated at `row_height == 1` (top border
/// + header + separator + 2 body rows + bottom border == 6 lines) and
/// borderless/unseparated at `row_height == 3` (header + 2 body rows of
/// 3 lines each == 7 lines) -- both the "small" and "large format" shapes
/// `glyphwire-ls -l`/`-l -L` actually produce.
pub fn tableGetStateReportsPaintedExtentTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 30, 20, 0);
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

    const bordered = try client.createTable(null, 0, 0, &.{
        .{ .name = "Name", .width = 4 },
    }, .{ .borders = true, .header_separator = true });
    try client.tableSetRows(null, bordered, &.{
        &.{.{ .display = "a" }},
        &.{.{ .display = "b" }},
    });
    const bordered_state = try client.tableGetState(null, bordered);
    try testz.expectEqual(bordered_state.painted.row, 0);
    try testz.expectEqual(bordered_state.painted.rows, 6);

    const large = try client.createTable(null, 10, 0, &.{
        .{ .name = "Name", .width = 4 },
    }, .{ .borders = false, .header_separator = false, .row_height = 3 });
    try client.tableSetRows(null, large, &.{
        &.{.{ .display = "a" }},
        &.{.{ .display = "b" }},
    });
    const large_state = try client.tableGetState(null, large);
    try testz.expectEqual(large_state.painted.row, 10);
    try testz.expectEqual(large_state.painted.rows, 7);
}

fn serveForeverThread(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.serveForever(alloc) catch |err| {
        std.log.err("test server stopped: {t}", .{err});
    };
}

/// `create_table` with `row`/`col` omitted anchors at the layer's
/// *current* cursor, same convention `draw_box`/`draw_icon` already use
/// (`resolveAnchor` in dispatch.zig) -- exercised here across two
/// separate connections, not just one, since that's the shape
/// `glyphwire-shell` + `glyphwire-ls` actually have: the shell positions
/// the cursor (`Prompt.submitLine`, before spawning `ls` as a grandchild)
/// on *its* connection, then `ls` calls `create_table` on a *different*
/// connection. Both still share the same root `Layer.cursor` server-side
/// (cursor isn't connection-scoped), so this should behave identically to
/// the single-connection case -- this test is the proof that it actually
/// does, not just that the single-connection path works.
pub fn createTableOnAnotherConnectionDefaultsToFirstConnectionsCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 30, 20, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-cursor-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    _ = try std.Thread.spawn(.{}, serveForeverThread, .{ &srv, alloc });

    // Connection A: the "shell" -- positions the cursor, same as
    // `Prompt.submitLine` does before spawning a command.
    var shell_conn = try glyphwire.Client.connect(io, alloc, socket_path);
    defer shell_conn.deinit();
    try shell_conn.setCursor(5, 3);

    // Connection B: the "ls" -- a separate connection, deliberately not
    // reusing shell_conn, so this can't accidentally pass by relying on
    // some connection-local cursor cache that wouldn't exist in the real
    // shell/ls split.
    var ls_conn = try glyphwire.Client.connect(io, alloc, socket_path);
    defer ls_conn.deinit();

    const table = try ls_conn.createTable(null, null, null, &.{
        .{ .name = "Name", .width = 4 },
    }, .{ .borders = false, .header_separator = false });
    try ls_conn.tableSetRows(null, table, &.{
        &.{.{ .display = "a" }},
    });

    const state = try ls_conn.tableGetState(null, table);
    try testz.expectEqual(state.painted.row, 5);
    try testz.expectEqual(state.painted.col, 3);
}
