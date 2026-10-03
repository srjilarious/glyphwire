// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! How the bands between *panes* are drawn: box-drawing lines by default,
//! with the right junction glyph wherever two dividers meet, or the older
//! solid `block` band. `host.conf.lua`'s `pane_divider_style` picks a
//! preset and `pane_divider_chars` overrides single glyphs (see
//! `config_load.loadConfig`).
//!
//! Pure: no renderer, no session. `render.zig` hands in the band rects and
//! draws the `Cell`s that come back, so the junction rule has unit tests.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// One glyph per shape a divider cell can take. A junction is named for
/// the arm it adds to a straight line: `t_right` is `├` (a vertical line
/// with an arm to the right).
pub const Glyphs = struct {
    h: []const u8,
    v: []const u8,
    cross: []const u8,
    t_down: []const u8,
    t_up: []const u8,
    t_left: []const u8,
    t_right: []const u8,
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
};

pub const single: Glyphs = .{ .h = "─", .v = "│", .cross = "┼", .t_down = "┬", .t_up = "┴", .t_left = "┤", .t_right = "├", .tl = "┌", .tr = "┐", .bl = "└", .br = "┘" };
pub const heavy: Glyphs = .{ .h = "━", .v = "┃", .cross = "╋", .t_down = "┳", .t_up = "┻", .t_left = "┫", .t_right = "┣", .tl = "┏", .tr = "┓", .bl = "┗", .br = "┛" };
pub const double: Glyphs = .{ .h = "═", .v = "║", .cross = "╬", .t_down = "╦", .t_up = "╩", .t_left = "╣", .t_right = "╠", .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝" };

pub const Style = union(enum) {
    /// A solid band in the theme's `pane_divider` colour.
    block,
    glyphs: Glyphs,
};

pub const default_style: Style = .{ .glyphs = single };

/// `pane_divider_style`'s preset names, or null for an unknown one.
pub fn preset(name: []const u8) ?Style {
    if (std.mem.eql(u8, name, "single")) return .{ .glyphs = single };
    if (std.mem.eql(u8, name, "heavy")) return .{ .glyphs = heavy };
    if (std.mem.eql(u8, name, "double")) return .{ .glyphs = double };
    if (std.mem.eql(u8, name, "block")) return .block;
    return null;
}

/// One pane divider band, in window cells. `vertical` is a band between
/// side-by-side panes (a `.row` split).
pub const Line = struct {
    rect: glyphwire.CellRect,
    vertical: bool,
};

pub const Cell = struct {
    row: usize,
    col: usize,
    glyph: []const u8,
};

/// Every cell of every band in `lines`, each with its glyph. A cell joins
/// a neighbouring divider cell in a direction when either of them runs
/// along that direction -- so a vertical line picks up an arm toward a
/// horizontal one touching its side (`├`), but two side-by-side vertical
/// lines (a band wider than one cell) don't join each other.
pub fn layout(
    alloc: std.mem.Allocator,
    lines: []const Line,
    glyphs: *const Glyphs,
    out: *std.ArrayList(Cell),
) !void {
    out.clearRetainingCapacity();
    var map: std.AutoHashMapUnmanaged(u64, bool) = .empty;
    defer map.deinit(alloc);
    for (lines) |l| {
        for (0..l.rect.rows) |dr| for (0..l.rect.cols) |dc| {
            try map.put(alloc, key(l.rect.row + dr, l.rect.col + dc), l.vertical);
        };
    }

    var it = map.iterator();
    while (it.next()) |e| {
        const row: usize = @intCast(e.key_ptr.* >> 32);
        const col: usize = @intCast(e.key_ptr.* & 0xffff_ffff);
        const vertical = e.value_ptr.*;
        const up = row > 0 and joins(&map, row - 1, col, vertical, true);
        const down = joins(&map, row + 1, col, vertical, true);
        const left = col > 0 and joins(&map, row, col - 1, vertical, false);
        const right = joins(&map, row, col + 1, vertical, false);
        try out.append(alloc, .{ .row = row, .col = col, .glyph = pick(glyphs, vertical, up, down, left, right) });
    }
}

fn key(row: usize, col: usize) u64 {
    return (@as(u64, @intCast(row)) << 32) | @as(u64, @intCast(col));
}

/// Whether the cell at `row`/`col` is a divider this one joins, looking
/// along the vertical axis (`along_vertical`) or the horizontal one.
fn joins(map: *const std.AutoHashMapUnmanaged(u64, bool), row: usize, col: usize, self_vertical: bool, along_vertical: bool) bool {
    const other_vertical = map.get(key(row, col)) orelse return false;
    return self_vertical == along_vertical or other_vertical == along_vertical;
}

/// The glyph for a cell's set of arms.
pub fn pick(g: *const Glyphs, vertical: bool, up: bool, down: bool, left: bool, right: bool) []const u8 {
    if (up and down and left and right) return g.cross;
    if (up and down and right) return g.t_right;
    if (up and down and left) return g.t_left;
    if (left and right and down) return g.t_down;
    if (left and right and up) return g.t_up;
    if (down and right and !up and !left) return g.tl;
    if (down and left and !up and !right) return g.tr;
    if (up and right and !down and !left) return g.bl;
    if (up and left and !down and !right) return g.br;
    return if (vertical) g.v else g.h;
}
