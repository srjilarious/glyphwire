// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `core.Outline` -- the collapsible tree component. These drive the model
//! directly against a `Context`'s root layer rather than over a socket:
//! an outline compiles into ordinary cells, so asserting on the grid is
//! the same thing a client would see, and it keeps the reflow behaviour
//! (which is the interesting part) out of the socket tests' timing.

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

/// A style with owned marker glyphs, as `createOutline` requires.
fn style(alloc: std.mem.Allocator, alt_row_bg: ?glyphwire.Color) !glyphwire.OutlineStyle {
    return .{
        .marker_collapsed = try alloc.dupe(u8, "\u{25B8}"),
        .marker_expanded = try alloc.dupe(u8, "\u{25BE}"),
        .alt_row_bg = alt_row_bg,
    };
}

/// One node: `depth`, a single plain run of `text`, collapsible or not.
fn node(alloc: std.mem.Allocator, depth: u8, text: []const u8, collapsible: bool, collapsed: bool) !glyphwire.OutlineNode {
    const runs = try alloc.alloc(glyphwire.Layer.TextRun, 1);
    runs[0] = .{ .text = try alloc.dupe(u8, text), .fg = glyphwire.default_style.fg, .bg = null };
    return .{ .depth = depth, .runs = runs, .collapsible = collapsible, .collapsed = collapsed };
}

/// The classic two-level grep shape: a file node with two hits under it,
/// each hit carrying two context lines.
///
/// ```
/// file.zig        depth 0, collapsible
///   hit 10        depth 1, collapsible
///     ctx 11      depth 2
///     ctx 12      depth 2
///   hit 20        depth 1, collapsible
///     ctx 21      depth 2
/// ```
fn grepNodes(alloc: std.mem.Allocator, collapsed: bool) ![]glyphwire.OutlineNode {
    const nodes = try alloc.alloc(glyphwire.OutlineNode, 6);
    nodes[0] = try node(alloc, 0, "file.zig", true, false);
    nodes[1] = try node(alloc, 1, "hit 10", true, collapsed);
    nodes[2] = try node(alloc, 2, "ctx 11", false, false);
    nodes[3] = try node(alloc, 2, "ctx 12", false, false);
    nodes[4] = try node(alloc, 1, "hit 20", true, collapsed);
    nodes[5] = try node(alloc, 2, "ctx 21", false, false);
    return nodes;
}

/// The text of live-viewport row `row`, trailing blanks trimmed.
fn rowText(alloc: std.mem.Allocator, layer: *const glyphwire.Layer, row: i64) ![]u8 {
    const cells = if (row >= 0)
        layer.viewRow(0, @intCast(row))
    else
        layer.scrollbackRow(@intCast(-row - 1)) orelse return alloc.dupe(u8, "<gone>");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (cells) |c| try out.appendSlice(alloc, c.grapheme());
    const s = try out.toOwnedSlice(alloc);
    return alloc.realloc(s, std.mem.trimEnd(u8, s, " ").len);
}

fn expectRow(alloc: std.mem.Allocator, layer: *const glyphwire.Layer, row: i64, want: []const u8) !void {
    const got = try rowText(alloc, layer, row);
    defer alloc.free(got);
    try testz.expectEqualStr(want, got);
}

pub fn outlineHidesDeeperNodesUnderACollapsedOneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, true));
    try outline.render(&ctx.root, &ctx);

    // Both hits collapsed: their context lines are hidden, so only the
    // file row and the two hit rows paint.
    try testz.expectEqual(outline.visibleRows(), 3);
    try expectRow(alloc, &ctx.root, 0, "\u{25BE} file.zig");
    try expectRow(alloc, &ctx.root, 1, "  \u{25B8} hit 10");
    try expectRow(alloc, &ctx.root, 2, "  \u{25B8} hit 20");
    try expectRow(alloc, &ctx.root, 3, "");
}

pub fn outlineCollapsingAFileHidesItsWholeSubtreeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, false));
    try outline.render(&ctx.root, &ctx);
    try testz.expectEqual(outline.visibleRows(), 6);

    // Collapsing the depth-0 node hides everything deeper, hits included,
    // not just the rows one level down.
    try outline.setNodeCollapsed(&ctx.root, &ctx, 0, true);
    try testz.expectEqual(outline.visibleRows(), 1);
    try expectRow(alloc, &ctx.root, 0, "\u{25B8} file.zig");
    try expectRow(alloc, &ctx.root, 1, "");
}

pub fn outlineExpandingGrowsUpwardAndLeavesRowsBelowPutTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, true));
    try outline.render(&ctx.root, &ctx);

    // Something below the outline, standing in for the shell prompt that
    // follows `gw-grep` once it has exited.
    ctx.root.setProperty(.{ .cursor = .{ .row = 4, .col = 0 } });
    try ctx.root.writeText("$ prompt", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // Expand "hit 10": two context rows appear.
    try outline.setNodeCollapsed(&ctx.root, &ctx, 1, false);
    try testz.expectEqual(outline.visibleRows(), 5);

    // The outline rose by two; the prompt below it did not move at all.
    try expectRow(alloc, &ctx.root, 4, "$ prompt");
    try expectRow(alloc, &ctx.root, -2, "\u{25BE} file.zig");
    try expectRow(alloc, &ctx.root, -1, "  \u{25BE} hit 10");
    // Depth 2: four indent cells, then the two the marker gutter reserves
    // even for a leaf, so context sits two past its hit's text.
    try expectRow(alloc, &ctx.root, 0, "      ctx 11");
    try expectRow(alloc, &ctx.root, 1, "      ctx 12");
    try expectRow(alloc, &ctx.root, 2, "  \u{25B8} hit 20");
    try expectRow(alloc, &ctx.root, 3, "");
}

pub fn outlineExpandThenCollapseRestoresTheGridTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, true));
    try outline.render(&ctx.root, &ctx);
    ctx.root.setProperty(.{ .cursor = .{ .row = 4, .col = 0 } });
    try ctx.root.writeText("$ prompt", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try outline.setNodeCollapsed(&ctx.root, &ctx, 1, false);
    try outline.setNodeCollapsed(&ctx.root, &ctx, 1, true);

    try testz.expectEqual(outline.visibleRows(), 3);
    try expectRow(alloc, &ctx.root, 0, "\u{25BE} file.zig");
    try expectRow(alloc, &ctx.root, 1, "  \u{25B8} hit 10");
    try expectRow(alloc, &ctx.root, 2, "  \u{25B8} hit 20");
    try expectRow(alloc, &ctx.root, 4, "$ prompt");
    // Nothing was pushed into scrollback on balance.
    try testz.expectEqual(ctx.root.history_len, 0);
}

pub fn outlineTogglePassedNullFlipsTheNodeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, true));
    try outline.render(&ctx.root, &ctx);

    try outline.setNodeCollapsed(&ctx.root, &ctx, 1, null);
    try testz.expectEqual(outline.visibleRows(), 5);
    try outline.setNodeCollapsed(&ctx.root, &ctx, 1, null);
    try testz.expectEqual(outline.visibleRows(), 3);
}

pub fn outlineMarkerHitTestResolvesTheNodeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, true));
    try outline.render(&ctx.root, &ctx);

    // The file node's marker sits at column 0; a depth-1 hit's at column 2.
    try testz.expectEqual(outline.toggleAt(0, 0, 0).?, 0);
    try testz.expectEqual(outline.toggleAt(0, 1, 0).?, 0);
    try testz.expectEqual(outline.toggleAt(1, 2, 0).?, 1);
    try testz.expectEqual(outline.toggleAt(1, 3, 0).?, 1);

    // Past the two marker cells the row belongs to the text, so a click
    // there falls through to glyphwire-shell's metadata activation.
    try testz.expectTrue(outline.toggleAt(0, 2, 0) == null);
    try testz.expectTrue(outline.toggleAt(1, 4, 0) == null);
    // A row with no outline on it at all.
    try testz.expectTrue(outline.toggleAt(9, 0, 0) == null);
}

pub fn outlineMarkerHitTestFollowsContentUpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 6, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, true));
    try outline.render(&ctx.root, &ctx);

    // Output pushes the outline up two rows; the click still lands.
    ctx.root.setProperty(.{ .cursor = .{ .row = 5, .col = 0 } });
    try ctx.root.writeText("a\nb\nc", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(ctx.root.history_len, 2);
    try testz.expectEqual(outline.top_live, -2);

    // Scrolled back by two, the file row is on screen row 0 again.
    try testz.expectEqual(outline.toggleAt(0, 0, 2).?, 0);
}

pub fn outlineSetAllCollapsedTakesOneReflowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, false));
    try outline.render(&ctx.root, &ctx);
    try testz.expectEqual(outline.visibleRows(), 6);

    // Depth 1 only: the hits close, the file stays open.
    try outline.setAllCollapsed(&ctx.root, &ctx, true, 1);
    try testz.expectEqual(outline.visibleRows(), 3);
    try expectRow(alloc, &ctx.root, 0, "\u{25BE} file.zig");

    // Every depth: the file closes too.
    try outline.setAllCollapsed(&ctx.root, &ctx, true, null);
    try testz.expectEqual(outline.visibleRows(), 1);
    try expectRow(alloc, &ctx.root, 0, "\u{25B8} file.zig");
}

pub fn outlineTogglingAHiddenNodeMovesNothingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, true));
    try outline.render(&ctx.root, &ctx);
    try outline.setNodeCollapsed(&ctx.root, &ctx, 0, true);
    try testz.expectEqual(outline.visibleRows(), 1);

    // "hit 10" is hidden under the collapsed file. Expanding it changes
    // the stored state but nothing on screen, so no reflow happens.
    try outline.setNodeCollapsed(&ctx.root, &ctx, 1, false);
    try testz.expectEqual(outline.visibleRows(), 1);
    try testz.expectEqual(ctx.root.history_len, 0);

    // ...and it is already open when the file is expanded again.
    try outline.setNodeCollapsed(&ctx.root, &ctx, 0, false);
    try testz.expectEqual(outline.visibleRows(), 5);
}

pub fn outlineDestroyBlanksWhatItPaintedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    outline.setNodes(try grepNodes(alloc, true));
    try outline.render(&ctx.root, &ctx);
    try expectRow(alloc, &ctx.root, 0, "\u{25BE} file.zig");

    try ctx.destroyOutline(null, h);
    try expectRow(alloc, &ctx.root, 0, "");
    try expectRow(alloc, &ctx.root, 1, "");
    try testz.expectTrue(ctx.destroyOutline(null, h) == error.UnknownOutline);
}

pub fn outlineNodeRunsKeepTheirOwnColoursTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 40, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;

    // A grep hit's row: line number dim, the matched bytes highlighted,
    // the rest plain -- the reason nodes carry runs rather than one string.
    const runs = try alloc.alloc(glyphwire.Layer.TextRun, 3);
    runs[0] = .{ .text = try alloc.dupe(u8, "12 "), .fg = .{ .r = 90, .g = 90, .b = 90 }, .bg = null };
    runs[1] = .{ .text = try alloc.dupe(u8, "init"), .fg = .{ .r = 255, .g = 200, .b = 0 }, .bg = null };
    runs[2] = .{ .text = try alloc.dupe(u8, "()"), .fg = .{ .r = 200, .g = 200, .b = 200 }, .bg = null };
    const nodes = try alloc.alloc(glyphwire.OutlineNode, 1);
    nodes[0] = .{ .depth = 0, .runs = runs, .collapsible = false };
    outline.setNodes(nodes);
    try outline.render(&ctx.root, &ctx);

    // Two blank marker cells, then the runs back to back.
    try expectRow(alloc, &ctx.root, 0, "  12 init()");
    try testz.expectEqual(ctx.root.cell(0, 2).style.fg.r, 90);
    try testz.expectEqual(ctx.root.cell(0, 5).style.fg.r, 255);
    try testz.expectEqual(ctx.root.cell(0, 5).style.fg.g, 200);
    try testz.expectEqual(ctx.root.cell(0, 9).style.fg.r, 200);
}

pub fn outlineRowIsClippedNotWrappedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 12, 20);
    defer ctx.deinit();

    const h = try ctx.createOutline(null, 0, 0, 20, try style(alloc, null));
    const outline = ctx.root.outlines.getPtr(h).?;
    const nodes = try alloc.alloc(glyphwire.OutlineNode, 2);
    nodes[0] = try node(alloc, 0, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false, false);
    nodes[1] = try node(alloc, 0, "second", false, false);
    outline.setNodes(nodes);
    try outline.render(&ctx.root, &ctx);

    // One source line is one row: a long line is cut at the outline's
    // width rather than pushing the rest of the results down the screen.
    try testz.expectEqual(outline.visibleRows(), 2);
    try expectRow(alloc, &ctx.root, 0, "  aaaaaaaaaaaaaaaaaa");
    try expectRow(alloc, &ctx.root, 1, "  second");
}

// ─── Over the wire ─────────────────────────────────────────────────────
//
// The model tests above drive `core.Outline` directly. These go through a
// real socket, so they also cover the dispatch handlers, the client SDK
// and the JSON shapes -- the same harness `table_tests.zig` uses.

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}

/// The wire form of `grepNodes`: a file node with two hits, each hit
/// carrying two context lines.
const wire_nodes = [_]glyphwire.Client.OutlineNodeInput{
    .{ .depth = 0, .runs = &.{.{ .text = "file.zig" }}, .collapsible = true },
    .{ .depth = 1, .runs = &.{.{ .text = "hit 10" }}, .collapsible = true, .collapsed = true },
    .{ .depth = 2, .runs = &.{.{ .text = "ctx 11" }} },
    .{ .depth = 2, .runs = &.{.{ .text = "ctx 12" }} },
    .{ .depth = 1, .runs = &.{.{ .text = "hit 20" }}, .collapsible = true, .collapsed = true },
    .{ .depth = 2, .runs = &.{.{ .text = "ctx 21" }} },
};

pub fn outlineOverTheWirePaintsAndTogglesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 30, 10, 20);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-outline-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    const outline = try client.createOutline(null, 0, 0, null, .{});
    try client.outlineSetNodes(null, outline, &wire_nodes);

    {
        var snap = try client.getCells();
        defer snap.deinit();
        // Row 0 is the file node's marker; row 1 the first (collapsed) hit.
        try testz.expectEqualStr("\u{25BE}", snap.cellAt(0, 0).grapheme);
        try testz.expectEqualStr("f", snap.cellAt(0, 2).grapheme);
        try testz.expectEqualStr("\u{25B8}", snap.cellAt(1, 2).grapheme);
        try testz.expectEqualStr("h", snap.cellAt(1, 4).grapheme);
        // The second hit follows immediately: its context is hidden.
        try testz.expectEqualStr("\u{25B8}", snap.cellAt(2, 2).grapheme);
    }

    // Expanding node 1 reveals its two context rows, pushing the outline
    // up into scrollback rather than down over whatever follows it.
    try client.outlineSetCollapsed(null, outline, 1, false);

    var state = try client.outlineGetState(null, outline);
    defer state.deinit(alloc);
    try testz.expectEqual(state.node_count, 6);
    try testz.expectEqual(state.visible_rows, 5);
    try testz.expectTrue(state.nodes[2].visible);
    try testz.expectTrue(!state.nodes[5].visible);
    try testz.expectTrue(!state.nodes[1].collapsed);
    try testz.expectTrue(state.nodes[4].collapsed);
}

pub fn outlineSetAllCollapsedOverTheWireTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 30, 10, 20);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-outline-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    const outline = try client.createOutline(null, 0, 0, null, .{});
    try client.outlineSetNodes(null, outline, &wire_nodes);

    // Open everything, then close just the hits, then everything.
    try client.outlineSetAllCollapsed(null, outline, false, null);
    {
        var state = try client.outlineGetState(null, outline);
        defer state.deinit(alloc);
        try testz.expectEqual(state.visible_rows, 6);
    }
    try client.outlineSetAllCollapsed(null, outline, true, 1);
    {
        var state = try client.outlineGetState(null, outline);
        defer state.deinit(alloc);
        try testz.expectEqual(state.visible_rows, 3);
    }
    try client.outlineSetAllCollapsed(null, outline, true, null);
    {
        var state = try client.outlineGetState(null, outline);
        defer state.deinit(alloc);
        try testz.expectEqual(state.visible_rows, 1);
    }
}

pub fn outlineRunColoursSurviveTheWireTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 30, 10, 20);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-outline-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    const outline = try client.createOutline(null, 0, 0, null, .{});
    try client.outlineSetNodes(null, outline, &.{
        .{ .depth = 0, .runs = &.{
            .{ .text = "12 ", .fg = .{ .r = 90, .g = 90, .b = 90 } },
            .{ .text = "init", .fg = .{ .r = 255, .g = 200, .b = 0 } },
        } },
    });

    var snap = try client.getCells();
    defer snap.deinit();
    // Two blank marker cells, then the runs with their own colours.
    try testz.expectEqualStr("1", snap.cellAt(0, 2).grapheme);
    try testz.expectEqual(snap.cellAt(0, 2).fg.r, 90);
    try testz.expectEqualStr("i", snap.cellAt(0, 5).grapheme);
    try testz.expectEqual(snap.cellAt(0, 5).fg.r, 255);
    try testz.expectEqual(snap.cellAt(0, 5).fg.g, 200);
}

pub fn outlineUnknownHandleAndBadNodeAreReportedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 30, 10, 20);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-outline-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    try client.subscribe(&.{"error"});
    const outline = try client.createOutline(null, 0, 0, null, .{});
    try client.outlineSetNodes(null, outline, &wire_nodes);

    // Both are notifications, so they are logged into the error ring
    // rather than severing the connection -- see the protocol's error
    // model. The session stays usable afterwards.
    try client.outlineSetCollapsed(null, 9999, 0, true);
    try client.outlineSetCollapsed(null, outline, 99, true);

    var report = try client.getErrors();
    defer report.deinit();
    const entries = report.entries();
    try testz.expectEqual(entries.len, 2);
    try testz.expectEqualStr("UnknownOutline", entries[0].code);
    try testz.expectEqualStr("OutlineNodeOutOfRange", entries[1].code);
}
