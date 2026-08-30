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

/// A cell's `icon` (an icon-registry name, resolved server-side) at
/// `row_height == 1` is drawn `.natural`-scaled, left-aligned and capped
/// to one cell-height (so it fills the row's single line without spilling
/// onto its neighbours), reserving the leading columns its rendered width
/// needs before the cell's `display` text -- see `core.Table.writeBodyRow`'s
/// doc comment. With this session's 12x12 cell metrics and a 12px-wide
/// icon that's 2 columns. The icon lands in `fg_icon`, not `bg_icon`:
/// table body icons always composite over the row's background rather than
/// replacing it (see `core.setCellIconOver`).
pub fn tableCellIconFillsLineAtDefaultRowHeightTest(io: std.Io, alloc: std.mem.Allocator) !void {
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
    try testz.expectTrue(icon_cell.bg_icon == null);
    try testz.expectEqual(icon_cell.fg_icon.?.handle, file_handle);
    try testz.expectTrue(icon_cell.fg_icon.?.scale == .natural);
    try testz.expectTrue(icon_cell.fg_icon.?.h_align == .start);
    try testz.expectTrue(icon_cell.fg_icon.?.v_align == .center);
    try testz.expectEqual(icon_cell.fg_icon.?.max_h.?, 12); // 1 row * 12px cell height
    try testz.expectEqualStr("x", snapshot.cellAt(1, 2).grapheme);
}

/// Without the session's cell pixel metrics (`ctx.cell_px_w`/`_h` zeroed
/// -- a host that never set them), a `row_height == 1` body icon falls
/// back to the original one-cell `.fit`, reserving exactly one column
/// before the `display` text -- see `core.Table.writeBodyRow`'s doc
/// comment.
pub fn tableCellIconFallsBackToFitWithoutCellMetricsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();
    ctx.cell_px_w = 0;
    ctx.cell_px_h = 0;

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
    try testz.expectEqual(icon_cell.fg_icon.?.handle, file_handle);
    try testz.expectTrue(icon_cell.fg_icon.?.scale == .fit);
    try testz.expectEqualStr("x", snapshot.cellAt(1, 1).grapheme);
}

/// A table body icon composites *over* its row's background: an
/// `alt_row_bg` stripe stays intact behind the icon cell (the icon is in
/// `fg_icon`, so `fillRowBg`'s color fill on that same cell survives),
/// and the same holds for a `.natural`-scaled "large format" icon that
/// overflows past its anchor cell. Regression guard for icons punching a
/// flat hole through the row striping -- see `core.Table.writeBodyRow`.
pub fn tableBodyIconCompositesOverAltRowBgTest(io: std.Io, alloc: std.mem.Allocator) !void {
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

    const png = fakePngBytes(32, 32);
    const file_handle = try client.loadImage("png", &png);
    try ctx.registerIcon("file", file_handle);

    const table = try client.createTable(null, 0, 0, &.{
        .{ .name = "Name", .width = 10, .sortable = true },
    }, .{ .borders = false, .header_separator = false, .alt_row_bg = .{ .r = 30, .g = 30, .b = 30, .a = 255 } });

    try client.tableSetRows(null, table, &.{
        &.{.{ .display = "a", .icon = "file" }},
        &.{.{ .display = "b", .icon = "file" }},
    });

    {
        var snapshot = try client.getCells();
        defer snapshot.deinit();

        // Grid row 2 is the second data row (`display_i == 1`) -- the
        // striped one. Its icon anchor cell keeps the stripe color *and*
        // carries the icon on top.
        const striped_icon_cell = snapshot.cellAt(2, 0);
        try testz.expectEqual(striped_icon_cell.bg.?.r, 30);
        try testz.expectEqual(striped_icon_cell.fg_icon.?.handle, file_handle);
        try testz.expectTrue(striped_icon_cell.bg_icon == null);
    }

    // Same holds for a "large format" (`row_height > 1`) row, whose icon
    // is `.natural`-scaled and overflows past its anchor cell -- the
    // overflow paints over neighboring rows' backgrounds because it's a
    // deferred `fg_icon`, and the anchor cell still keeps its stripe.
    const large = try client.createTable(null, 10, 0, &.{
        .{ .name = "Name", .width = 12, .sortable = true },
    }, .{ .borders = false, .header_separator = false, .row_height = 3, .alt_row_bg = .{ .r = 30, .g = 30, .b = 30, .a = 255 } });
    try client.tableSetRows(null, large, &.{
        &.{.{ .display = "a", .icon = "file" }},
        &.{.{ .display = "b", .icon = "file" }},
    });

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    // Header at grid row 10, first data-row block rows 11-13, second
    // (striped) block rows 14-16; the icon sits on the block's middle
    // line (row 15).
    const large_icon_cell = snapshot.cellAt(15, 0);
    try testz.expectEqual(large_icon_cell.bg.?.r, 30);
    try testz.expectEqual(large_icon_cell.fg_icon.?.handle, file_handle);
    try testz.expectTrue(large_icon_cell.fg_icon.?.scale == .natural);
    try testz.expectTrue(large_icon_cell.bg_icon == null);
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

/// A table taller than the whole layer (more rows, at a given
/// `row_height`, than the viewport has -- easy to hit with
/// `glyphwire-ls -l -L`'s 3-line rows on an ordinarily-sized directory
/// listing and a modest window) must not crash. `Table.render` draws
/// top-down, scrolling the layer a piece at a time (`tableMakeRoom`);
/// once total scrolling hits the layer's capacity the excess rows just
/// clip. The painted extent's `row` ends up 0 (the table's top scrolled
/// into history), which is what this test pins. `tableOversizedShowsTail`
/// covers *which* rows stay visible and that only real content, never
/// blank filler, reaches scrollback.
pub fn tableTallerThanLayerDoesNotCrashTest(io: std.Io, alloc: std.mem.Allocator) !void {
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

    // 1 (header) + 10 rows * row_height 3 == 31 lines, needed in a
    // 10-row layer -- can never fit no matter how much this scrolls.
    const table = try client.createTable(null, 0, 0, &.{
        .{ .name = "Name", .width = 4 },
    }, .{ .borders = false, .header_separator = false, .row_height = 3 });

    var rows: [10][1]glyphwire.Client.TableCellInput = undefined;
    var row_slices: [10][]const glyphwire.Client.TableCellInput = undefined;
    for (&rows, 0..) |*row, i| {
        row[0] = .{ .display = "x" };
        row_slices[i] = row;
    }
    try client.tableSetRows(null, table, &row_slices);

    const state = try client.tableGetState(null, table);
    try testz.expectEqual(state.painted.row, 0);
}

/// A table taller than the viewport renders like ordinary terminal
/// output: top-down from its anchor, scrolling the layer one row at a
/// time as it fills past the bottom, so the live tail ends up on screen
/// and the header + earliest rows go into scrollback -- intact, never
/// replaced by blank filler (the "preceding blank lines" `glyphwire-ls
/// -l` used to leave in a small window). 6-row viewport, an 11-line table
/// (header + 10 body rows) anchored at row 2 after a sentinel row: the
/// visible tail is "e".."j" on rows 0-5, the sentinel and the header both
/// sit in history at their real offsets.
pub fn tableOversizedShowsTailTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 6, 20);
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

    // A sentinel on row 0, standing in for the shell's prompt / `total`
    // line -- it should scroll into history intact, not get buried.
    try client.setCursor(0, 0);
    try client.writeText("S", .{ .r = 255, .g = 255, .b = 255 }, null);

    // header + 10 body rows * row_height 1 == 11 lines in a 6-row
    // viewport, anchored at row 2.
    const table = try client.createTable(null, 2, 0, &.{
        .{ .name = "Name", .width = 4 },
    }, .{ .borders = false, .header_separator = false });

    var rows: [10][1]glyphwire.Client.TableCellInput = undefined;
    var row_slices: [10][]const glyphwire.Client.TableCellInput = undefined;
    const names = "abcdefghij";
    for (&rows, 0..) |*row, i| {
        row[0] = .{ .display = names[i .. i + 1] };
        row_slices[i] = row;
    }
    try client.tableSetRows(null, table, &row_slices);

    const state = try client.tableGetState(null, table);
    // Anchor scrolled entirely into history; footprint fills the viewport.
    try testz.expectEqual(state.painted.row, 0);
    try testz.expectEqual(state.painted.rows, 6);

    var snapshot = try client.getCells();
    defer snapshot.deinit();
    // The live tail "e".."j" fills rows 0-5 -- no blank row anywhere.
    try testz.expectEqualStr("e", snapshot.cellAt(0, 0).grapheme);
    try testz.expectEqualStr("j", snapshot.cellAt(5, 0).grapheme);

    // Rendering from row 2 then scrolling 7 rows (11 lines - (6 - 2)
    // on-screen) puts the header 5 rows above the viewport and the
    // sentinel 7 -- both still holding their real content, not blanked.
    var hist5 = try client.getCellsView(5);
    defer hist5.deinit();
    try testz.expectEqualStr("N", hist5.cellAt(0, 0).grapheme); // "Name" header
    var hist7 = try client.getCellsView(7);
    defer hist7.deinit();
    try testz.expectEqualStr("S", hist7.cellAt(0, 0).grapheme);
}
