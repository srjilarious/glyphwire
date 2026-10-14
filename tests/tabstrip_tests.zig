// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `applib/tabstrip.zig`, the scroll arrows and window zoe's buffer tabs
//! and salacommander's directory tabs share.

const std = @import("std");
const testz = @import("testz");
const tabstrip = @import("applib").tabstrip;

const Span = struct { start: usize, end: usize };

/// Four 9-column tabs with a separator between each: 0..9, 10..19,
/// 20..29, 30..39. 39 columns in all.
const four = [_]Span{
    .{ .start = 0, .end = 9 },
    .{ .start = 10, .end = 19 },
    .{ .start = 20, .end = 29 },
    .{ .start = 30, .end = 39 },
};
const four_total: usize = 39;

pub fn windowHasArrowsOnlyWhenTheStripOverflowsTest(_: std.Io, _: std.mem.Allocator) !void {
    // Fits: the whole pane, no arrows, and nothing to scroll.
    const fits = tabstrip.window(four_total, 40);
    try testz.expectFalse(fits.arrows);
    try testz.expectEqual(fits.left, 0);
    try testz.expectEqual(fits.cols, 40);
    try testz.expectEqual(fits.maxScroll(four_total), 0);
    try testz.expectEqual(fits.extent(four_total), 40);

    // Overflows: a column each end goes to an arrow.
    const over = tabstrip.window(four_total, 20);
    try testz.expectTrue(over.arrows);
    try testz.expectEqual(over.left, 1);
    try testz.expectEqual(over.cols, 18);
    try testz.expectEqual(over.maxScroll(four_total), 21);
    // The host's range (extent less the pane) is the strip's.
    try testz.expectEqual(over.extent(four_total) - 20, over.maxScroll(four_total));

    // Too narrow for arrows and a column of tabs: no arrows.
    try testz.expectFalse(tabstrip.window(four_total, 2).arrows);
}

pub fn windowMapsPaneColumnsTest(_: std.Io, _: std.mem.Allocator) !void {
    const win = tabstrip.window(four_total, 20);
    try testz.expectTrue(win.at(5, 0) == .back);
    try testz.expectTrue(win.at(5, 19) == .forward);
    try testz.expectEqual(win.at(5, 1).strip, 5);
    try testz.expectEqual(win.at(5, 18).strip, 22);
    // And back.
    try testz.expectEqual(win.paneCol(5, 5), 1);
    try testz.expectEqual(win.paneCol(5, 22), 18);
    try testz.expectEqual(win.paneCol(5, 4), null);
    try testz.expectEqual(win.paneCol(5, 23), null);

    // No arrows: columns past the strip's end are `past`.
    const fits = tabstrip.window(10, 12);
    try testz.expectEqual(fits.at(0, 0).strip, 0);
    try testz.expectTrue(fits.at(0, 12) == .past);
}

pub fn scrollToShowMovesAsLittleAsPossibleTest(_: std.Io, _: std.mem.Allocator) !void {
    const win = tabstrip.window(80, 22); // 20 columns of tabs
    // A strip that fits never scrolls.
    try testz.expectEqual(tabstrip.scrollToShow(30, 42, tabstrip.window(50, 60), 0, 50), 0);
    // Off the right edge: just far enough to show the whole tab.
    try testz.expectEqual(tabstrip.scrollToShow(30, 42, win, 0, 80), 22);
    // Off the left edge: back to its left end.
    try testz.expectEqual(tabstrip.scrollToShow(30, 42, win, 35, 80), 30);
    // Already in view: left where it was.
    try testz.expectEqual(tabstrip.scrollToShow(30, 42, win, 25, 80), 25);
    // Never past the end of the strip.
    try testz.expectEqual(tabstrip.scrollToShow(78, 80, win, 0, 80), 60);
    // Wider than the view: its left end, where the label is.
    try testz.expectEqual(tabstrip.scrollToShow(10, 40, win, 0, 80), 10);
}

pub fn arrowsStepOneTabTest(_: std.Io, _: std.mem.Allocator) !void {
    const win = tabstrip.window(four_total, 20); // 18 visible
    // At the start, forward shows the second tab's right end in full.
    try testz.expectEqual(tabstrip.stepForward(&four, 0, win, four_total), 19 - 18);
    // Then the third, then the fourth, which is the end.
    try testz.expectEqual(tabstrip.stepForward(&four, 1, win, four_total), 29 - 18);
    try testz.expectEqual(tabstrip.stepForward(&four, 11, win, four_total), 21);
    try testz.expectEqual(tabstrip.stepForward(&four, 21, win, four_total), 21);

    // Back from the end shows the nearest tab cut off on the left from
    // its left end, and so on down to 0.
    try testz.expectEqual(tabstrip.stepBack(&four, 21), 20);
    try testz.expectEqual(tabstrip.stepBack(&four, 20), 10);
    try testz.expectEqual(tabstrip.stepBack(&four, 10), 0);
    try testz.expectEqual(tabstrip.stepBack(&four, 0), 0);
}

pub fn followFiresOnlyOnChangeTest(_: std.Io, _: std.mem.Allocator) !void {
    var f: tabstrip.Follow = .{};
    try testz.expectTrue(f.changed(0, 4, 39, 20));
    // Nothing moved: the user's scroll is kept.
    try testz.expectFalse(f.changed(0, 4, 39, 20));
    // Another tab shown, a tab opened, a label grown, the pane resized.
    try testz.expectTrue(f.changed(1, 4, 39, 20));
    try testz.expectTrue(f.changed(1, 5, 49, 20));
    try testz.expectTrue(f.changed(1, 5, 51, 20));
    try testz.expectTrue(f.changed(1, 5, 51, 30));
}
