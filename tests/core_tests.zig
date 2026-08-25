const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

pub fn writeTextAdvancesCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("e", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 3).grapheme());
    try testz.expectEqualStr("o", layer.cell(0, 4).grapheme());

    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 5);
}

pub fn writeTextAppliesStyleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    const style: glyphwire.Style = .{
        .fg = .{ .r = 10, .g = 20, .b = 30 },
        .bg = .{ .color = .{ .r = 1, .g = 2, .b = 3 } },
    };
    try layer.writeText("h", style);

    const c = layer.cell(0, 0);
    try testz.expectEqual(c.style.fg.r, 10);
    try testz.expectEqual(c.style.fg.g, 20);
    try testz.expectEqual(c.style.fg.b, 30);
    switch (c.style.bg) {
        .color => |bg| {
            try testz.expectEqual(bg.r, 1);
            try testz.expectEqual(bg.g, 2);
            try testz.expectEqual(bg.b, 3);
        },
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn writeTextWrapsAtLayerEdgeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("e", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("l", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("o", layer.cell(1, 1).grapheme());

    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 2);
}

pub fn getSetCursorPropertyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style);

    const before = layer.getProperty(.cursor);
    try testz.expectEqual(before.cursor.row, 0);
    try testz.expectEqual(before.cursor.col, 5);

    layer.setProperty(.{ .cursor = .{ .row = 3, .col = 7 } });

    const after = layer.getProperty(.cursor);
    try testz.expectEqual(after.cursor.row, 3);
    try testz.expectEqual(after.cursor.col, 7);
}

/// The regression: an explicit set_property(cursor) naming a row at or
/// past the bottom used to just take that row literally (no scrolling),
/// unlike write_text's cursor advancing past the edge (which scrolls via
/// putAtCursor). That mismatch is what let glyphwire-ls's icons silently
/// stop landing once enough rows had scrolled -- see Layer.resolveRow.
pub fn setCursorPastBottomScrollsLikeWritingPastItWouldTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 3, 10);
    defer layer.deinit();

    try layer.writeText("a", glyphwire.default_style);
    try testz.expectEqual(layer.cursor.row, 0);

    // Row 3 is one past the last valid row (0..2) -- should scroll once
    // and land on the new bottom row (2), the same place writing a 4th
    // line's worth of text would land.
    layer.setProperty(.{ .cursor = .{ .row = 3, .col = 0 } });

    try testz.expectEqual(layer.cursor.row, 2);
    try testz.expectEqual(layer.cursor.col, 0);
    // The scroll actually happened (not just clamped in place): row 0's
    // "a" is now history, not the live top row.
    try testz.expectEqual(layer.history_len, 1);
}

/// A row far past the bottom still resolves sanely (scrolls until it
/// fits, landing on the last row) rather than hanging -- the loop in
/// resolveRow is capped at `capacity()` iterations specifically so this
/// can't spin forever for a hostile/buggy client-supplied row.
pub fn setCursorFarPastBottomStillTerminatesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 3, 5);
    defer layer.deinit();

    layer.setProperty(.{ .cursor = .{ .row = 1_000_000, .col = 1 } });

    try testz.expectEqual(layer.cursor.row, 2);
    try testz.expectEqual(layer.cursor.col, 1);
}

pub fn contextCreatesRootLayerAtSizeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    try testz.expectEqual(ctx.root.width, 80);
    try testz.expectEqual(ctx.root.height, 24);
    try testz.expectEqual(ctx.root.cursor.row, 0);
    try testz.expectEqual(ctx.root.cursor.col, 0);
}

pub fn scrollingRetainsScrolledOffRowsAsHistoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // width=3, height=2, scrollback=2 (capacity=4 rows). Writing 10
    // characters wraps across 4 logical rows, forcing the viewport to
    // scroll twice.
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 2);
    defer layer.deinit();

    try layer.writeText("abcdefghij", glyphwire.default_style);

    // Viewport now shows the last two rows written.
    try testz.expectEqualStr("g", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("h", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("i", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("j", layer.cell(1, 0).grapheme());
    try testz.expectEqual(layer.cell(1, 1).grapheme().len, 0);
    try testz.expectEqual(layer.cell(1, 2).grapheme().len, 0);
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 1);

    // The two rows that scrolled off are retained, most recent first.
    const most_recent = layer.scrollbackRow(0).?;
    try testz.expectEqualStr("d", most_recent[0].grapheme());
    try testz.expectEqualStr("e", most_recent[1].grapheme());
    try testz.expectEqualStr("f", most_recent[2].grapheme());

    const older = layer.scrollbackRow(1).?;
    try testz.expectEqualStr("a", older[0].grapheme());
    try testz.expectEqualStr("b", older[1].grapheme());
    try testz.expectEqualStr("c", older[2].grapheme());

    try testz.expectTrue(layer.scrollbackRow(2) == null);
}

pub fn inputStateTracksKeyAndMouseButtonDownSetsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var input = glyphwire.InputState.init(alloc);
    defer input.deinit();

    try testz.expectTrue(!input.isKeyDown("a"));

    try testz.expectTrue(try input.setKey("a", true));
    try testz.expectTrue(input.isKeyDown("a"));
    // Redundant press-while-down reports no change.
    try testz.expectTrue(!try input.setKey("a", true));

    try testz.expectTrue(try input.setKey("a", false));
    try testz.expectTrue(!input.isKeyDown("a"));
    // Redundant release-while-up reports no change.
    try testz.expectTrue(!try input.setKey("a", false));

    try testz.expectTrue(!input.isMouseButtonDown("left"));
    try testz.expectTrue(try input.setMouseButton("left", true));
    try testz.expectTrue(input.isMouseButtonDown("left"));
}

pub fn scrollingWithNoScrollbackKeepsNoHistoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // A layer with scrollback_rows=0 (e.g. a small popup notification)
    // still scrolls its viewport, it just never retains history.
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 0);
    defer layer.deinit();

    try layer.writeText("abcdefghij", glyphwire.default_style);

    try testz.expectEqualStr("g", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("j", layer.cell(1, 0).grapheme());
    try testz.expectTrue(layer.scrollbackRow(0) == null);
}

pub fn insertCellsShiftsRowRightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style);
    layer.setProperty(.{ .cursor = .{ .row = 0, .col = 1 } });

    layer.insertCells(1);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqual(layer.cell(0, 1).grapheme().len, 0);
    try testz.expectEqualStr("e", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 3).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 4).grapheme());
    try testz.expectEqualStr("o", layer.cell(0, 5).grapheme());
    try testz.expectEqual(layer.cell(0, 6).grapheme().len, 0);

    // insertCells doesn't move the cursor -- matches ECMA-48's ICH.
    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 1);
}

pub fn insertCellsDiscardsCellsPastRowEdgeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 2, 0);
    defer layer.deinit();

    try layer.writeText("abcde", glyphwire.default_style);
    layer.setProperty(.{ .cursor = .{ .row = 0, .col = 0 } });

    layer.insertCells(2);

    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    try testz.expectEqual(layer.cell(0, 1).grapheme().len, 0);
    try testz.expectEqualStr("a", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("b", layer.cell(0, 3).grapheme());
    try testz.expectEqualStr("c", layer.cell(0, 4).grapheme());
    // "d" and "e" were shifted past the row's right edge and discarded.
}

pub fn deleteCellsShiftsRowLeftAndBlanksTailTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style);
    layer.setProperty(.{ .cursor = .{ .row = 0, .col = 1 } });

    layer.deleteCells(1);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("o", layer.cell(0, 3).grapheme());
    try testz.expectEqual(layer.cell(0, 4).grapheme().len, 0);

    // deleteCells doesn't move the cursor -- matches ECMA-48's DCH.
    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 1);
}

pub fn insertAndDeleteCellsAreNoOpsPastRowEdgeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 2, 0);
    defer layer.deinit();

    try layer.writeText("abcde", glyphwire.default_style);
    const revision_before = layer.revision;
    // Cursor is now at (0, 5) -- one past the row's last column.

    layer.insertCells(1);
    layer.deleteCells(1);
    layer.insertCells(0);
    layer.deleteCells(0);

    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("e", layer.cell(0, 4).grapheme());
    try testz.expectEqual(layer.revision, revision_before);
}

/// A minimal byte stream `pngDimensions` accepts: the 8-byte PNG signature
/// followed by exactly an IHDR chunk header (4-byte length, "IHDR", then
/// big-endian width/height) -- 24 bytes total, nothing past what
/// `pngDimensions` actually reads. Not a real, decodable PNG (no further
/// chunks, no CRC) -- fine, since the headless core never decodes pixels.
fn fakePngBytes(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, bytes[8..12], 13, .big); // IHDR chunk length, unchecked
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

pub fn pngDimensionsParsesIhdrTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    const bytes = fakePngBytes(64, 32);
    const info = try glyphwire.pngDimensions(&bytes);
    try testz.expectEqual(info.width, 64);
    try testz.expectEqual(info.height, 32);
}

pub fn pngDimensionsRejectsBadSignatureTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    var bytes = fakePngBytes(64, 32);
    bytes[0] = 0; // corrupt the signature
    try testz.expectError(glyphwire.pngDimensions(&bytes), glyphwire.ImageError.InvalidPng);
}

pub fn contextLoadImageParsesDimensionsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const bytes = fakePngBytes(48, 24);
    const handle = try ctx.loadImage(&bytes);

    const info = ctx.imageInfo(handle).?;
    try testz.expectEqual(info.width, 48);
    try testz.expectEqual(info.height, 24);
    try testz.expectTrue(ctx.imageInfo(handle + 1) == null);
}

pub fn layerDrawImageMarksCoveredCellsWithOffsetsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // A 2x2-cell span at 12px cells covers a 24x24px image exactly.
    layer.drawImage(1, 1, 1, 2, 2, 24, 24, 12, 12);

    const c00 = layer.cell(1, 1).style.bg;
    const c01 = layer.cell(1, 2).style.bg;
    const c10 = layer.cell(2, 1).style.bg;
    const c11 = layer.cell(2, 2).style.bg;

    try testz.expectEqual(c00.image.handle, 1);
    try testz.expectEqual(c00.image.offset_x, 0);
    try testz.expectEqual(c00.image.offset_y, 0);
    try testz.expectEqual(c01.image.offset_x, 12);
    try testz.expectEqual(c01.image.offset_y, 0);
    try testz.expectEqual(c10.image.offset_x, 0);
    try testz.expectEqual(c10.image.offset_y, 12);
    try testz.expectEqual(c11.image.offset_x, 12);
    try testz.expectEqual(c11.image.offset_y, 12);

    // Untouched cells outside the span keep the default color background.
    switch (layer.cell(0, 0).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawImageLeavesCellsBeyondImageBoundsUntouchedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // Pre-mark a cell with a distinct color so an untouched cell is
    // distinguishable from the layer's blank default.
    layer.cell(0, 3).style.bg = .{ .color = .{ .r = 9, .g = 9, .b = 9 } };

    // A 12x12px image (one cell) drawn into a 2x2-cell span: only the
    // top-left cell is actually covered -- the other three cells the
    // image doesn't reach should be left as they were.
    layer.drawImage(1, 0, 2, 2, 2, 12, 12, 12, 12);

    try testz.expectEqual(layer.cell(0, 2).style.bg.image.handle, 1);
    switch (layer.cell(0, 3).style.bg) {
        .color => |c| try testz.expectEqual(c.r, 9),
        .image, .icon => return error.TestUnexpectedResult,
    }
    switch (layer.cell(1, 2).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawIconMarksExactlyOneCellTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{});

    try testz.expectEqual(layer.cell(1, 2).style.bg.icon.handle, 7);
    switch (layer.cell(1, 3).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawIconDefaultsToFitAndCenterTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{});

    const icon = layer.cell(1, 2).style.bg.icon;
    try testz.expectEqual(icon.scale, .fit);
    try testz.expectEqual(icon.h_align, .center);
    try testz.expectEqual(icon.v_align, .center);
}

pub fn layerDrawIconAppliesScaleAndAlignOptsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{ .scale = .natural, .h_align = .start, .v_align = .end });

    const icon = layer.cell(1, 2).style.bg.icon;
    try testz.expectEqual(icon.handle, 7);
    try testz.expectEqual(icon.scale, .natural);
    try testz.expectEqual(icon.h_align, .start);
    try testz.expectEqual(icon.v_align, .end);
}

pub fn layerDrawIconAppliesMaxWidthAndHeightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{ .scale = .natural, .max_w = 40, .max_h = 60 });

    const icon = layer.cell(1, 2).style.bg.icon;
    try testz.expectEqual(icon.max_w, 40);
    try testz.expectEqual(icon.max_h, 60);
}

pub fn layerDrawIconTaggedSetsMetadataIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{ .metadata_id = 42 });

    try testz.expectEqual(layer.cell(1, 2).metadata_id.?, 42);
    // A sibling of style.bg, not part of the icon variant itself.
    try testz.expectEqual(layer.cell(1, 2).style.bg.icon.handle, 7);
}

pub fn layerTagMetadataSetsIdWithoutTouchingBgOrGraphemeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{ .metadata_id = 42 });
    layer.tagMetadata(1, 3, 42);

    // The neighboring cell got tagged with the same id as the icon's
    // anchor, but its background/grapheme are untouched -- still whatever
    // the layer's default is, not a copy of the icon.
    try testz.expectEqual(layer.cell(1, 3).metadata_id.?, 42);
    switch (layer.cell(1, 3).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
    try testz.expectEqual(layer.cell(1, 3).grapheme().len, 0);
}

pub fn layerTagMetadataOverwritesExistingTagTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    try layer.writeTextTagged("a", glyphwire.default_style, 1);
    layer.tagMetadata(0, 0, 2);

    try testz.expectEqual(layer.cell(0, 0).metadata_id.?, 2);
    // The grapheme write_text put there is still untouched.
    try testz.expectEqualStr(layer.cell(0, 0).grapheme(), "a");
}

pub fn layerWriteTextTaggedMarksEveryCellTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeTextTagged("abc", glyphwire.default_style, 7);

    try testz.expectEqual(layer.cell(0, 0).metadata_id.?, 7);
    try testz.expectEqual(layer.cell(0, 1).metadata_id.?, 7);
    try testz.expectEqual(layer.cell(0, 2).metadata_id.?, 7);
    // Untouched by this call: no tag.
    try testz.expectTrue(layer.cell(0, 3).metadata_id == null);
}

pub fn layerWriteTextLeavesMetadataUntaggedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeText("abc", glyphwire.default_style);

    try testz.expectTrue(layer.cell(0, 0).metadata_id == null);
}

/// The same regression as setCursorPastBottomScrollsLikeWritingPastItWouldTest,
/// but for draw_icon's own anchor row directly (not via set_property) --
/// glyphwire-ls calls drawIcon with an explicit row before it ever calls
/// setCursor for that entry, so drawIcon itself has to resolve a
/// past-the-bottom row the same way, not just rely on setCursor doing it
/// afterward.
pub fn layerDrawIconPastBottomScrollsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 3, 10);
    defer layer.deinit();

    layer.drawIcon(1, 2, 0, .{}); // valid, the last row (height=3, rows 0..2)
    layer.drawIcon(2, 3, 0, .{}); // one past the bottom -- scrolls once, lands on row 2

    try testz.expectEqual(layer.history_len, 1);
    // The scroll shifted the first icon up into row 1 rather than losing
    // it, and the second landed on the freshly-scrolled-to row 2.
    try testz.expectEqual(layer.cell(1, 0).style.bg.icon.handle, 1);
    try testz.expectEqual(layer.cell(2, 0).style.bg.icon.handle, 2);
}

pub fn layerDrawIconColPastEdgeIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    const revision_before = layer.revision;

    layer.drawIcon(1, 0, 10, .{});

    try testz.expectEqual(layer.revision, revision_before);
}

pub fn contextRegisterIconThenLookUpByNameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const png = fakePngBytes(32, 32);
    const handle = try ctx.loadImage(&png);
    try ctx.registerIcon("folder", handle);

    try testz.expectEqual(ctx.iconHandle("folder").?, handle);
    try testz.expectTrue(ctx.iconHandle("not-registered") == null);
}

pub fn contextRegisterIconTwiceUnderSameNameOverwritesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const png_a = fakePngBytes(16, 16);
    const handle_a = try ctx.loadImage(&png_a);
    try ctx.registerIcon("icon", handle_a);

    const png_b = fakePngBytes(32, 32);
    const handle_b = try ctx.loadImage(&png_b);
    try ctx.registerIcon("icon", handle_b);

    try testz.expectEqual(ctx.iconHandle("icon").?, handle_b);
}

pub fn contextCreateMetadataThenLookUpByIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const id = try ctx.createMetadata("{\"path\":\"/tmp/afile.txt\"}");

    try testz.expectEqualStr(ctx.metadataJson(id).?, "{\"path\":\"/tmp/afile.txt\"}");
}

pub fn contextDestroyMetadataFreesItAndErrorsOnUnknownIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const id = try ctx.createMetadata("{}");
    try ctx.destroyMetadata(id);

    // Dangling read: not an error, just gone -- see destroyMetadata's doc
    // comment.
    try testz.expectTrue(ctx.metadataJson(id) == null);

    // Destroying again (or an id that was never created) is an error --
    // same treatment destroyLayer gives an unknown layer handle.
    try testz.expectError(ctx.destroyMetadata(id), glyphwire.MetadataError.UnknownMetadata);
}

fn testBoxTiles() glyphwire.Layer.BoxTiles {
    // Distinct handles per piece so a test can tell which piece landed
    // where purely from the handle number -- drawBox draws each with the
    // .icon Background variant (scale-to-fit, same as draw_icon), which
    // is just a handle, not a real loaded image lookup.
    return .{
        .tl = 1,
        .t = 2,
        .tr = 3,
        .l = 4,
        .fill = 5,
        .r = 6,
        .bl = 7,
        .b = 8,
        .br = 9,
    };
}

pub fn layerDrawBoxPlacesEachPieceByRoleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 10, 0);
    defer layer.deinit();

    // A 4x5 box anchored at (1, 1): rows 1..4, cols 1..5.
    layer.drawBox(testBoxTiles(), 1, 1, 4, 5);

    try testz.expectEqual(layer.cell(1, 1).style.bg.icon.handle, 1); // tl
    try testz.expectEqual(layer.cell(1, 3).style.bg.icon.handle, 2); // t (interior top col)
    try testz.expectEqual(layer.cell(1, 5).style.bg.icon.handle, 3); // tr
    try testz.expectEqual(layer.cell(2, 1).style.bg.icon.handle, 4); // l
    try testz.expectEqual(layer.cell(2, 3).style.bg.icon.handle, 5); // fill
    try testz.expectEqual(layer.cell(2, 5).style.bg.icon.handle, 6); // r
    try testz.expectEqual(layer.cell(4, 1).style.bg.icon.handle, 7); // bl
    try testz.expectEqual(layer.cell(4, 3).style.bg.icon.handle, 8); // b
    try testz.expectEqual(layer.cell(4, 5).style.bg.icon.handle, 9); // br

    // Every tile stretches to fill its cell exactly, not the aspect-
    // preserved `.fit` a bare `drawIcon` call defaults to -- see
    // `IconScale`'s doc comment on why tiles need this to stay gap-free.
    try testz.expectEqual(layer.cell(1, 1).style.bg.icon.scale, .stretch);
    try testz.expectEqual(layer.cell(2, 3).style.bg.icon.scale, .stretch);

    // Outside the box entirely: untouched.
    switch (layer.cell(0, 0).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawBoxClipsToLayerBoundsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // A box requesting more rows/cols than the layer has past its anchor
    // shouldn't panic or write out of bounds.
    layer.drawBox(testBoxTiles(), 3, 3, 10, 10);

    try testz.expectEqual(layer.cell(3, 3).style.bg.icon.handle, 1); // tl, still placed
    try testz.expectEqual(layer.cell(4, 4).style.bg.icon.handle, 5); // clamped corner lands as fill, not br
}

pub fn layerDrawBoxZeroSizeIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    const revision_before = layer.revision;

    layer.drawBox(testBoxTiles(), 0, 0, 0, 5);
    layer.drawBox(testBoxTiles(), 0, 0, 5, 0);

    try testz.expectEqual(layer.revision, revision_before);
    switch (layer.cell(0, 0).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerClearResetsRegionToBlankTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    try layer.writeText("hello", glyphwire.default_style);
    layer.drawBox(testBoxTiles(), 1, 1, 3, 3);

    layer.clear(0, 0, 1, 5);

    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    // Untouched region keeps its content.
    try testz.expectEqual(layer.cell(1, 1).style.bg.icon.handle, 1);
}

pub fn layerClearWholeLayerViaFullSpanTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    try layer.writeText("hello", glyphwire.default_style);
    layer.drawBox(testBoxTiles(), 2, 2, 3, 3);

    layer.clear(0, 0, layer.height, layer.width);

    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    switch (layer.cell(2, 2).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerClearOutOfBoundsAnchorIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    const revision_before = layer.revision;

    layer.clear(10, 0, 3, 3);
    layer.clear(0, 10, 3, 3);
    layer.clear(0, 0, 0, 3);
    layer.clear(0, 0, 3, 0);

    try testz.expectEqual(layer.revision, revision_before);
}
