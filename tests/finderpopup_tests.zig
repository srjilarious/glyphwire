// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `applib/finderpopup.zig`: the popup zoe's Ctrl+P and salacommander's F3
//! share. Its geometry and key handling are free functions over plain
//! values, so they're covered here without a client; drawing is left to
//! running the two programs.

const std = @import("std");
const testz = @import("testz");
const applib = @import("applib");
const popup = applib.finderpopup;
const Finder = applib.finder.Finder;
const Rect = popup.Rect;

fn finderOf(alloc: std.mem.Allocator, paths: []const []const u8) !Finder {
    var f: Finder = .{ .alloc = alloc, .root = try alloc.dupe(u8, "/repo") };
    errdefer f.deinit();
    for (paths) |p| try f.addPath(p);
    f.sortPaths();
    try f.refilter();
    return f;
}

pub fn placeRectCentresAtThePreferredSizeTest(_: std.Io, _: std.mem.Allocator) !void {
    const style: popup.Style = .{ .max_cols = 84, .max_rows = 20 };
    // Plenty of room: the preferred size, centred in the area.
    const r = popup.placeRect(.{ .row = 2, .col = 10, .cols = 200, .rows = 60 }, style);
    try testz.expectEqual(r.cols, 84);
    try testz.expectEqual(r.rows, 20);
    try testz.expectEqual(r.row, 2 + (60 - 20) / 2);
    try testz.expectEqual(r.col, 10 + (200 - 84) / 2);
}

pub fn placeRectShrinksButKeepsAMarginTest(_: std.Io, _: std.mem.Allocator) !void {
    const style: popup.Style = .{ .max_cols = 84, .max_rows = 20 };
    // Narrower than the preferred size: two cells either side, one row
    // above and below, so the frame still has cells to sit in.
    const r = popup.placeRect(.{ .cols = 50, .rows = 12 }, style);
    try testz.expectEqual(r.cols, 46);
    try testz.expectEqual(r.rows, 10);
    const fr = popup.frameRect(r).?;
    try testz.expectEqual(fr.row, 0);
    try testz.expectEqual(fr.col, 1);
    try testz.expectEqual(fr.cols, 48);
    try testz.expectEqual(fr.rows, 12);
}

pub fn placeRectNeverOutgrowsATinyAreaTest(_: std.Io, _: std.mem.Allocator) !void {
    // Below the minimum: the popup is the area, and there's no cell left
    // for a frame at the window's top-left edge.
    const r = popup.placeRect(.{ .cols = 10, .rows = 3 }, .{});
    try testz.expectEqual(r.cols, 10);
    try testz.expectEqual(r.rows, 3);
    try testz.expectTrue(popup.frameRect(r) == null);
}

pub fn rectContainsIsHalfOpenTest(_: std.Io, _: std.mem.Allocator) !void {
    const r: Rect = .{ .row = 2, .col = 3, .cols = 4, .rows = 2 };
    try testz.expectTrue(r.contains(.{ .row = 2, .col = 3 }));
    try testz.expectTrue(r.contains(.{ .row = 3, .col = 6 }));
    try testz.expectFalse(r.contains(.{ .row = 4, .col = 3 }));
    try testz.expectFalse(r.contains(.{ .row = 2, .col = 7 }));
    try testz.expectFalse(r.contains(.{ .row = 1, .col = 3 }));
}

pub fn applyKeyMovesAndClampsTheHighlightTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var f = try finderOf(alloc, &.{ "a.zig", "b.zig", "c.zig", "d.zig", "e.zig" });
    defer f.deinit();

    try testz.expectEqual(try popup.applyKey(&f, "down", .{}, 3), .changed);
    try testz.expectEqual(f.cursor, 1);
    try testz.expectEqual(try popup.applyKey(&f, "n", .{ .ctrl = true }, 3), .changed);
    try testz.expectEqual(f.cursor, 2);
    // A page is the list's own height, and clamps at the end rather than
    // wrapping back to the top: the list is ranked.
    _ = try popup.applyKey(&f, "page_down", .{}, 3);
    try testz.expectEqual(f.cursor, 4);
    try testz.expectEqual(f.top, 2);
    _ = try popup.applyKey(&f, "p", .{ .ctrl = true }, 3);
    try testz.expectEqual(f.cursor, 3);
}

pub fn applyKeyAnswersEnterAndEscapeWithoutTouchingTheQueryTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var f = try finderOf(alloc, &.{ "a.zig", "b.zig" });
    defer f.deinit();
    try testz.expectEqual(try popup.applyKey(&f, "enter", .{}, 5), .accept);
    try testz.expectEqual(try popup.applyKey(&f, "kp_enter", .{}, 5), .accept);
    try testz.expectEqual(try popup.applyKey(&f, "escape", .{}, 5), .cancel);
    try testz.expectEqual(try popup.applyKey(&f, "c", .{ .ctrl = true }, 5), .cancel);
    try testz.expectEqualStr(f.query.text(), "");
}

pub fn applyKeyEditsTheQueryAndRefiltersTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var f = try finderOf(alloc, &.{ "src/core.zig", "zoe/ui.zig", "README.md" });
    defer f.deinit();
    // Typed text arrives separately (`Popup.text`); editing keys come
    // here and narrow the list the moment they change the query.
    try testz.expectTrue(try f.query.insert(alloc, "zoeuix"));
    try f.refilter();
    try testz.expectEqual(f.matchCount(), 0);
    try testz.expectEqual(try popup.applyKey(&f, "backspace", .{}, 5), .changed);
    try testz.expectEqualStr(f.query.text(), "zoeui");
    try testz.expectEqual(f.matchCount(), 1);
    try testz.expectEqualStr(f.selected().?, "zoe/ui.zig");
}
