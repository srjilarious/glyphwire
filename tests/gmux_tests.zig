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
