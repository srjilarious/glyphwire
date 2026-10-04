// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! How divider bands are drawn: box-drawing lines by default, with the
//! right junction glyph wherever two dividers meet, or the older solid
//! `block` band. `host.conf.lua`'s `pane_divider_style` picks a preset and
//! `pane_divider_chars` overrides single glyphs (see
//! `config_load.loadConfig`). That style covers the bands between panes
//! and, unless a program sent `set_divider_style` for its own context, the
//! bands inside each program's split tree too.
//!
//! Pure: no renderer, no session. `render.zig` hands in the band rects and
//! draws the `Cell`s that come back, so the junction rule has unit tests.

const std = @import("std");
const glyphwire = @import("glyphwire");

// The glyph sets and presets live in the core library, so a program
// can name them in `set_divider_style` (see `glyphwire.divider_style`).
const divider_style = glyphwire.divider_style;
pub const Glyphs = divider_style.Glyphs;
pub const single = divider_style.single;
pub const heavy = divider_style.heavy;
pub const double = divider_style.double;
pub const Style = divider_style.Style;
pub const default_style = divider_style.default_style;
pub const preset = divider_style.preset;

/// One divider band, in window cells. `vertical` is a band between
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
