// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `applib/listcursor.zig`: a list's pick and scroll.

const std = @import("std");
const testz = @import("testz");
const listcursor = @import("applib").listcursor;
const ListCursor = listcursor.ListCursor;

pub fn wrapWrapsBothWaysTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(listcursor.wrap(0, 5, -1), 4);
    try testz.expectEqual(listcursor.wrap(4, 5, 1), 0);
    try testz.expectEqual(listcursor.wrap(2, 5, 1), 3);
    try testz.expectEqual(listcursor.wrap(1, 5, -7), 4);
    try testz.expectEqual(listcursor.wrap(0, 0, 1), 0);
}

pub fn stepClampsAtTheEndsTest(_: std.Io, _: std.mem.Allocator) !void {
    var c: ListCursor = .{};
    c.step(-1, 5, .clamp);
    try testz.expectEqual(c.selected, 0);
    c.step(3, 5, .clamp);
    try testz.expectEqual(c.selected, 3);
    c.step(10, 5, .clamp);
    try testz.expectEqual(c.selected, 4);
    // An empty list puts the pick back on row 0.
    c.step(1, 0, .clamp);
    try testz.expectEqual(c.selected, 0);
}

pub fn stepWrapsTest(_: std.Io, _: std.mem.Allocator) !void {
    var c: ListCursor = .{};
    c.step(-1, 5, .wrap);
    try testz.expectEqual(c.selected, 4);
    c.step(1, 5, .wrap);
    try testz.expectEqual(c.selected, 0);
}

pub fn followScrollsJustEnoughTest(_: std.Io, _: std.mem.Allocator) !void {
    var c: ListCursor = .{ .selected = 7 };
    c.follow(3);
    try testz.expectEqual(c.top, 5);
    c.selected = 2;
    c.follow(3);
    try testz.expectEqual(c.top, 2);
    // Nothing drawn yet: `top` stays put.
    c.selected = 9;
    c.follow(0);
    try testz.expectEqual(c.top, 2);
}

/// `followClamped` also keeps blank rows off the bottom when the list
/// shrank under the window.
pub fn followClampedPullsTopOffTheEndTest(_: std.Io, _: std.mem.Allocator) !void {
    var c: ListCursor = .{ .selected = 1, .top = 6 };
    c.followClamped(4, 8);
    try testz.expectEqual(c.top, 1);
    c = .{ .selected = 7, .top = 6 };
    c.followClamped(4, 8);
    try testz.expectEqual(c.top, 4);
    c.followClamped(4, 0);
    try testz.expectEqual(c.top, 0);
}

/// A wheel scroll moves the window, not the pick; `pullOnScreen` is the
/// variant where the pick rides along.
pub fn scrollToLeavesThePickTest(_: std.Io, _: std.mem.Allocator) !void {
    var c: ListCursor = .{ .selected = 0 };
    c.scrollTo(30, 5, 20);
    try testz.expectEqual(c.top, 15);
    try testz.expectEqual(c.selected, 0);
    c.pullOnScreen(5);
    try testz.expectEqual(c.selected, 15);
    c.selected = 19;
    c.scrollTo(2, 5, 20);
    c.pullOnScreen(5);
    try testz.expectEqual(c.selected, 6);
}

pub fn setAndClampStayInTheListTest(_: std.Io, _: std.mem.Allocator) !void {
    var c: ListCursor = .{};
    c.set(9, 4);
    try testz.expectEqual(c.selected, 3);
    c.clamp(2);
    try testz.expectEqual(c.selected, 1);
    c.clamp(0);
    try testz.expectEqual(c.selected, 0);
}
