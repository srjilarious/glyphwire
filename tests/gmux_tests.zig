// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gmux's own layer over the split tree. The tree itself is covered in
//! splittree_tests.zig.

const std = @import("std");
const testz = @import("testz");
const gmux = @import("gmux_support");

const layout = gmux.layout;

fn expectChildRefPane(ref: layout.ChildRef, want: layout.PaneId) !void {
    switch (ref) {
        .pane => |id| try testz.expectEqual(id, want),
        .split => try testz.fail(),
    }
}

fn expectChildRefSplit(ref: layout.ChildRef, want: u32) !void {
    switch (ref) {
        .split => |id| try testz.expectEqual(id, want),
        .pane => try testz.fail(),
    }
}

/// What `set_pane_split_children` is sent: a pane child by its pane id, a
/// split child by its wire handle.
pub fn childRefsReadsCurrentChildrenTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    const split = try tree.split(1, 2, .row, 42, .after);
    _ = try tree.split(2, 3, .column, 43, .after);

    const refs = layout.childRefs(split);
    try expectChildRefPane(refs[0], 1);
    try expectChildRefSplit(refs[1], 43);
}

/// The punctuation and uppercase commands are typed characters; `x` is a
/// key name (which `Ui.textAction` also reads off typed text).
pub fn keymapDefaultsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const actions = gmux.actions;
    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookupText("%").?, actions.Action.splitRight);
    try testz.expectEqual(km.lookupText("\"").?, actions.Action.splitBelow);
    try testz.expectEqual(km.lookupText("H").?, actions.Action.resizeLeft);
    try testz.expectEqual(km.lookup("x", .{}).?, actions.Action.killPane);
    try testz.expectEqual(km.lookup("left", .{}).?, actions.Action.focusLeft);
    try testz.expectTrue(actions.Action.zoom.keepsZoom());
    try testz.expectTrue(!actions.Action.splitRight.keepsZoom());
    try testz.expectTrue(actions.Action.sendPrefix.keepsZoom());
    try testz.expectEqual(km.lookupText("}").?, actions.Action.rotateForward);
    try testz.expectEqual(km.lookupText("{").?, actions.Action.rotateBackward);
    try testz.expectTrue(actions.Action.rotateForward.keepsZoom());
}

/// The prefix pressed twice sends it on, whatever letter the prefix is --
/// and, bound before the config's `keys`, it can still be rebound there.
pub fn sendPrefixFollowsThePrefixKeyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const actions = gmux.actions;
    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try km.bind(alloc, actions.sendPrefixChord('a'), .sendPrefix);
    try testz.expectEqual(km.lookup("a", .{ .ctrl = true }).?, actions.Action.sendPrefix);
    try testz.expectEqual(km.lookup("b", .{ .ctrl = true }), null);
    try testz.expectEqual(km.lookup("a", .{}), null);
}

/// Ctrl+B P and Ctrl+B m; the palette never lists itself, and opening it
/// leaves a zoom alone while layout mode, which moves panes, undoes it.
pub fn paletteAndLayoutModeKeysTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const actions = gmux.actions;
    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookupText("P").?, actions.Action.commandPalette);
    try testz.expectEqual(km.lookup("m", .{}).?, actions.Action.layoutMode);
    try testz.expectFalse(actions.inPalette(.commandPalette));
    try testz.expectTrue(actions.inPalette(.layoutMode));
    try testz.expectTrue(actions.Action.commandPalette.keepsZoom());
    try testz.expectFalse(actions.Action.layoutMode.keepsZoom());
}

// ── Layout mode (arrange.zig) ───────────────────────────────────────────

const arrange = gmux.arrange;
const Bounds = std.AutoHashMap(layout.PaneId, arrange.Rect);

fn expectEdge(z: arrange.Zone, want: arrange.Edge) !void {
    switch (z) {
        .edge => |e| try testz.expectEqual(e, want),
        .center => try testz.fail(),
    }
}

/// The middle half on both axes swaps; anywhere else is the nearest edge,
/// measured as a fraction of the pane so a wide pane still has sides.
pub fn zoneInPicksTheNearestEdgeTest(_: std.Io, _: std.mem.Allocator) !void {
    const r: arrange.Rect = .{ .row = 10, .col = 20, .cols = 40, .rows = 8 };
    try testz.expectTrue(arrange.zoneIn(r, 14, 40) == .center);
    try expectEdge(arrange.zoneIn(r, 14, 21), .left);
    try expectEdge(arrange.zoneIn(r, 14, 58), .right);
    try expectEdge(arrange.zoneIn(r, 10, 40), .top);
    try expectEdge(arrange.zoneIn(r, 17, 40), .bottom);
}

pub fn dropAtTakesWindowEdgesAndSkipsTheDraggedPaneTest(_: std.Io, _: std.mem.Allocator) !void {
    const win: arrange.Rect = .{ .cols = 80, .rows = 24 };
    const panes = [_]arrange.PaneRect{
        .{ .pane = 1, .rect = .{ .cols = 40, .rows = 24 } },
        .{ .pane = 2, .rect = .{ .col = 41, .cols = 39, .rows = 24 } },
    };
    try testz.expectTrue(arrange.dropAt(&panes, win, 1, 12, 0).?.eql(.{ .window = .left }));
    try testz.expectTrue(arrange.dropAt(&panes, win, 1, 23, 50).?.eql(.{ .window = .bottom }));
    try testz.expectTrue(arrange.dropAt(&panes, win, 1, 12, 10) == null);
    try testz.expectTrue(arrange.dropAt(&panes, win, 1, 12, 40) == null); // the divider
    try testz.expectTrue(arrange.dropAt(&panes, win, 1, 12, 60).?.eql(.{ .pane = .{ .pane = 2, .zone = .center } }));
    // One pane has nowhere to go.
    try testz.expectTrue(arrange.dropAt(panes[0..1], win, 1, 12, 0) == null);
}

pub fn highlightIsTheShareTheDropWillTakeTest(_: std.Io, _: std.mem.Allocator) !void {
    const win: arrange.Rect = .{ .cols = 90, .rows = 24 };
    const panes = [_]arrange.PaneRect{
        .{ .pane = 1, .rect = .{ .cols = 40, .rows = 24 } },
        .{ .pane = 2, .rect = .{ .col = 41, .cols = 49, .rows = 24 } },
    };
    const half = arrange.highlight(.{ .pane = .{ .pane = 2, .zone = .{ .edge = .bottom } } }, &panes, win, 0);
    try testz.expectEqual(half.row, 12);
    try testz.expectEqual(half.rows, 12);
    try testz.expectEqual(half.col, 41);
    const whole = arrange.highlight(.{ .pane = .{ .pane = 2, .zone = .center } }, &panes, win, 0);
    try testz.expectEqual(whole.cols, 49);
    // A third column at the right edge of two.
    const strip = arrange.highlight(.{ .window = .right }, &panes, win, 2);
    try testz.expectEqual(strip.cols, 30);
    try testz.expectEqual(strip.col, 60);
}

/// The request's example: a pane left of a column of two, dropped on the
/// lower edge of the column's top pane, makes one column of three even
/// panes rather than 50/25/25.
pub fn moveIntoAColumnEvensTheColumnOutTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.split(1, 2, .row, 10, .after);
    _ = try tree.split(2, 3, .column, 11, .after);
    var bounds = Bounds.init(alloc);
    defer bounds.deinit();

    const moved = try arrange.move(&tree, 1, .{ .pane = .{ .pane = 2, .zone = .{ .edge = .bottom } } }, 12);
    try testz.expectEqual(moved.removed_handle, 10);
    try testz.expectTrue(moved.runs[1] == null);

    const root = tree.root;
    try testz.expectEqual(root.kind.split.axis, .column);
    try testz.expectTrue(moved.made.parent == root);
    try testz.expectEqual(moved.made.kind.split.first.kind.leaf, 2);
    try testz.expectEqual(moved.made.kind.split.second.kind.leaf, 1);
    const w_root = arrange.childWeights(root, &moved.runs, &bounds, 1);
    try testz.expectEqual(w_root[0], 2);
    try testz.expectEqual(w_root[1], 1);
    const w_made = arrange.childWeights(moved.made, &moved.runs, &bounds, 1);
    try testz.expectEqual(w_made[0], 1);
    try testz.expectEqual(w_made[1], 1);
}

/// Pulling one of four columns out leaves three even columns, not one
/// that swallowed its neighbour's slot.
pub fn moveEvensTheRunItLeftTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.split(1, 2, .row, 10, .after);
    _ = try tree.split(2, 3, .row, 11, .after);
    _ = try tree.split(3, 4, .row, 12, .after);
    var bounds = Bounds.init(alloc);
    defer bounds.deinit();

    const moved = try arrange.move(&tree, 4, .{ .pane = .{ .pane = 1, .zone = .{ .edge = .bottom } } }, 13);
    try testz.expectEqual(moved.removed_handle, 12);
    try testz.expectTrue(moved.runs[1].?.top == tree.root);
    const w = arrange.childWeights(tree.root, &moved.runs, &bounds, 4);
    try testz.expectEqual(w[0], 1);
    try testz.expectEqual(w[1], 2);
}

/// A window-edge drop evens the root's run, and a split nobody touched
/// keeps the ratio its panes had on screen.
pub fn moveToAWindowEdgeKeepsUntouchedRatiosTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.split(1, 2, .row, 10, .after);
    _ = try tree.split(2, 3, .column, 11, .after);
    _ = try tree.split(1, 4, .column, 12, .after);
    var bounds = Bounds.init(alloc);
    defer bounds.deinit();
    try bounds.put(1, .{ .cols = 40, .rows = 12 });
    try bounds.put(4, .{ .row = 13, .cols = 40, .rows = 11 });
    try bounds.put(2, .{ .col = 41, .cols = 39, .rows = 16 });
    try bounds.put(3, .{ .row = 17, .col = 41, .cols = 39, .rows = 7 });

    try testz.expectEqual(arrange.windowRun(&tree, 4, .row), 2);
    const moved = try arrange.move(&tree, 4, .{ .window = .left }, 13);
    try testz.expectTrue(moved.made == tree.root);
    try testz.expectEqual(tree.root.kind.split.first.kind.leaf, 4);

    var splits: std.ArrayList(*layout.Node) = .empty;
    defer splits.deinit(alloc);
    try arrange.splitNodes(alloc, tree.root, &splits);
    try testz.expectEqual(splits.items.len, 3);
    const w_root = arrange.childWeights(splits.items[0], &moved.runs, &bounds, 4);
    try testz.expectEqual(w_root[0], 1);
    try testz.expectEqual(w_root[1], 2);
    const w_inner = arrange.childWeights(splits.items[1], &moved.runs, &bounds, 4);
    try testz.expectEqual(w_inner[0], 1);
    try testz.expectEqual(w_inner[1], 1);
    const w_col = arrange.childWeights(splits.items[2], &moved.runs, &bounds, 4);
    try testz.expectEqual(w_col[0], 16);
    try testz.expectEqual(w_col[1], 7);
}
