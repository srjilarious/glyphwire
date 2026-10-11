// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `applib/palette.zig`: the command palette zoe and salacommander open
//! on Ctrl+Shift+P, and the `.top` placement it adds to
//! `applib/popupframe.zig`. The labels, the ranking and the recency are
//! pure, so they're covered here; drawing is left to running the two
//! programs.

const std = @import("std");
const testz = @import("testz");
const applib = @import("applib");
const palette = applib.palette;
const popupframe = applib.popupframe;
const Chord = applib.keybind.Chord;

fn labelOf(name: []const u8) []const u8 {
    const S = struct {
        var buf: [palette.max_label_len]u8 = undefined;
    };
    return palette.labelFromName(&S.buf, name);
}

pub fn labelFromNameSplitsCamelCaseTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(labelOf("toggleTree"), "Toggle Tree");
    try testz.expectEqualStr(labelOf("save"), "Save");
    try testz.expectEqualStr(labelOf("sortByExt"), "Sort By Ext");
    // A run of capitals is one word, up to the one that starts the next.
    try testz.expectEqualStr(labelOf("openURLInTab"), "Open URL In Tab");
    try testz.expectEqualStr(labelOf("viewF2"), "View F2");
    try testz.expectEqualStr(labelOf(""), "");
}

pub fn labelFromNameStopsAtTheBufferTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [6]u8 = undefined;
    try testz.expectEqualStr(palette.labelFromName(&buf, "toggleTree"), "Toggle");
    var tiny: [7]u8 = undefined;
    // The space before a new word counts against the buffer too.
    try testz.expectEqualStr(palette.labelFromName(&tiny, "toggleTree"), "Toggle ");
}

pub fn recentKeepsTheNewestFirstTest(_: std.Io, _: std.mem.Allocator) !void {
    var r: palette.Recent = .{};
    try testz.expectTrue(r.rank(1) == null);
    r.note(1);
    r.note(2);
    r.note(3);
    try testz.expectEqual(r.rank(3).?, 0);
    try testz.expectEqual(r.rank(1).?, 2);
    // Running one again moves it to the front without duplicating it.
    r.note(1);
    try testz.expectEqual(r.len, 3);
    try testz.expectEqual(r.rank(1).?, 0);
    try testz.expectEqual(r.rank(3).?, 1);
    try testz.expectEqual(r.rank(2).?, 2);
}

pub fn recentDropsTheOldestWhenFullTest(_: std.Io, _: std.mem.Allocator) !void {
    var r: palette.Recent = .{};
    for (0..palette.Recent.capacity + 1) |i| r.note(@intCast(i));
    try testz.expectEqual(r.len, palette.Recent.capacity);
    try testz.expectTrue(r.rank(0) == null);
    try testz.expectEqual(r.rank(palette.Recent.capacity).?, 0);
    try testz.expectEqual(r.rank(1).?, palette.Recent.capacity - 1);
}

fn sampleList(alloc: std.mem.Allocator) !palette.List {
    var l = palette.List.init(alloc);
    errdefer l.deinit();
    try l.add(0, "save", null, try Chord.parse("ctrl+s"));
    try l.add(1, "toggleTree", null, try Chord.parse("ctrl+n"));
    try l.add(2, "sudoChmod", "Change Mode as Root", null);
    try l.add(3, "toggleHidden", "Toggle Hidden Files", try Chord.parse("ctrl+h"));
    return l;
}

fn selectedId(l: *const palette.List) ?u32 {
    const c = l.selected() orelse return null;
    return c.id;
}

pub fn listAddLabelsAndFormatsTheChordTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var l = try sampleList(alloc);
    defer l.deinit();
    try testz.expectEqualStr(l.commands.items[1].label, "Toggle Tree");
    try testz.expectEqualStr(l.commands.items[1].chord, "Ctrl+N");
    try testz.expectEqualStr(l.commands.items[2].label, "Change Mode as Root");
    try testz.expectEqualStr(l.commands.items[2].chord, "");
}

pub fn emptyQueryListsInTheCallersOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var l = try sampleList(alloc);
    defer l.deinit();
    try l.refilter();
    try testz.expectEqual(l.matchCount(), 4);
    for (0..4) |i| try testz.expectEqual(l.matchAt(i).?.id, @as(u32, @intCast(i)));
}

pub fn emptyQueryPutsRecentCommandsFirstTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var l = try sampleList(alloc);
    defer l.deinit();
    l.recent.note(1);
    l.recent.note(3);
    try l.refilter();
    // Newest first, then everything never run in the caller's order.
    try testz.expectEqual(l.matchAt(0).?.id, 3);
    try testz.expectEqual(l.matchAt(1).?.id, 1);
    try testz.expectEqual(l.matchAt(2).?.id, 0);
    try testz.expectEqual(l.matchAt(3).?.id, 2);
}

pub fn queryMatchesTheLabelOrTheNameTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var l = try sampleList(alloc);
    defer l.deinit();
    // The name: "sudochmod" isn't a subsequence of "Change Mode as Root".
    _ = try l.query.insert(alloc, "sudochmod");
    try l.refilter();
    try testz.expectEqual(l.matchCount(), 1);
    try testz.expectEqual(selectedId(&l).?, 2);

    // The label: a space only the label has.
    l.query.clear();
    _ = try l.query.insert(alloc, "hidden files");
    try l.refilter();
    try testz.expectEqual(l.matchCount(), 1);
    try testz.expectEqual(selectedId(&l).?, 3);
}

pub fn queryRanksTighterMatchesFirstTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var l = try sampleList(alloc);
    defer l.deinit();
    _ = try l.query.insert(alloc, "tree");
    try l.refilter();
    try testz.expectEqual(l.matchCount(), 1);
    try testz.expectEqual(selectedId(&l).?, 1);

    l.query.clear();
    _ = try l.query.insert(alloc, "togg");
    try l.refilter();
    // Both toggles match "togg" equally tightly: the caller's order.
    try testz.expectEqual(l.matchCount(), 2);
    try testz.expectEqual(l.matchAt(0).?.id, 1);
    try testz.expectEqual(l.matchAt(1).?.id, 3);
    // Unless one was run recently.
    l.recent.note(3);
    try l.refilter();
    try testz.expectEqual(l.matchAt(0).?.id, 3);
}

pub fn queryThatMatchesNothingEmptiesTheListTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var l = try sampleList(alloc);
    defer l.deinit();
    _ = try l.query.insert(alloc, "zzz");
    try l.refilter();
    try testz.expectEqual(l.matchCount(), 0);
    try testz.expectTrue(l.selected() == null);
}

pub fn applyKeyMovesThroughCommandsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var l = try sampleList(alloc);
    defer l.deinit();
    try l.refilter();
    try testz.expectEqual(try popupframe.applyKey(&l, "down", .{}, 2), .changed);
    try testz.expectEqual(selectedId(&l).?, 1);
    _ = try popupframe.applyKey(&l, "page_down", .{}, 2);
    try testz.expectEqual(selectedId(&l).?, 3);
    try testz.expectEqual(l.list.top, 2);
    _ = try popupframe.applyKey(&l, "up", .{}, 2);
    try testz.expectEqual(selectedId(&l).?, 2);
    try testz.expectEqual(try popupframe.applyKey(&l, "enter", .{}, 2), .accept);
    try testz.expectEqual(try popupframe.applyKey(&l, "escape", .{}, 2), .cancel);
}

pub fn placeRectTopAnchorsBelowTheEdgeTest(_: std.Io, _: std.mem.Allocator) !void {
    const style = palette.default_style;
    const r = popupframe.placeRect(.{ .row = 1, .col = 0, .cols = 200, .rows = 60 }, style);
    try testz.expectEqual(r.row, 1 + popupframe.top_margin);
    try testz.expectEqual(r.cols, style.max_cols);
    try testz.expectEqual(r.col, (200 - style.max_cols) / 2);
    // Room for the frame above it.
    try testz.expectEqual(popupframe.frameRect(r).?.row, 2);

    // An area hardly taller than the popup: the margin gives way first.
    var short = style;
    short.max_rows = 5;
    const tight = popupframe.placeRect(.{ .cols = 100, .rows = 6 }, short);
    try testz.expectEqual(tight.rows, 4);
    try testz.expectEqual(tight.row, 2);
}
