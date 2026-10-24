// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Drag and drop inside the window: files dragged from one pane onto a
//! folder (in either pane) or onto the other pane's listing, moved there
//! or -- with Ctrl held at the drop -- copied.
//!
//! This is the windowless half: what a drag carries and where a pointer
//! position would drop it. `ui.zig` tracks the button and the pointer,
//! draws the card and the highlight, and runs the operation. The host is
//! never told a drag is happening; the highlight is `set_drop_target`,
//! which is presentation only. Alt+drag is the other drag, out of the
//! window, and the host's (`Ui.startDrag`).

const std = @import("std");
const pane_mod = @import("pane.zig");
const fileops = @import("applib").fileops;

const Pane = pane_mod.Pane;

/// How far the pointer travels with the button down before a press turns
/// into a drag -- the same slop the host gives its own Alt+drag, so a
/// shaky click still lands as a click.
pub const threshold_px = 6;

/// What's under the pointer, as far as dropping goes: a pane, and the
/// listing row there if it's over one. Null `row` is the rest of the
/// pane -- its title, headers, footer, or the empty space under a short
/// listing.
pub const Hit = struct {
    pane: usize,
    row: ?usize = null,
};

/// Where a drop would land.
pub const Target = struct {
    pane: usize,
    /// The folder row dropped on (`..` included), or null for the pane's
    /// own directory -- the highlight goes on that row, or over the
    /// pane's whole listing.
    row: ?usize,
    /// The directory the sources land in. Borrowed from the pane, so
    /// good until it reloads.
    dest: []const u8,
};

/// Where dropping `sources` (dragged out of pane `src_pane`) at `hit`
/// would put them, or null when it wouldn't do anything useful:
///
///   - a folder row, or `..`, is that folder, in either pane;
///   - anywhere else in the *other* pane is that pane's directory;
///   - anywhere else in the pane the drag started in is nothing -- the
///     files are already there;
///   - so is a destination that is the sources' own directory (the other
///     pane showing the same place), and a folder that is one of the
///     sources or under one: a directory can't go inside itself.
pub fn resolve(panes: *const [2]Pane, src_pane: usize, sources: []const []const u8, hit: Hit) ?Target {
    const p = &panes[hit.pane];
    const target: Target = folder: {
        if (hit.row) |row| {
            if (p.isParentRow(row)) {
                break :folder .{ .pane = hit.pane, .row = row, .dest = std.fs.path.dirname(p.path) orelse "/" };
            }
            if (p.entryAt(row)) |e| {
                if ((e.link_target_kind orelse e.kind) == .directory) {
                    break :folder .{ .pane = hit.pane, .row = row, .dest = e.abs_path };
                }
            }
        }
        if (hit.pane == src_pane) return null;
        break :folder .{ .pane = hit.pane, .row = null, .dest = p.path };
    };

    if (std.mem.eql(u8, target.dest, panes[src_pane].path)) return null;
    for (sources) |s| {
        if (fileops.isWithin(target.dest, s)) return null;
    }
    return target;
}

/// What a drag starting on `row` carries: the pane's whole marked set
/// when the row is marked, else that row alone -- the rule Alt+drag
/// follows too. Empty for the `..` row. The paths are borrowed from the
/// pane; the caller frees only the slice.
pub fn carried(alloc: std.mem.Allocator, p: *const Pane, row: usize) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    const entry = p.entryAt(row) orelse return out.toOwnedSlice(alloc);
    if (p.isMarked(row)) {
        for (p.entries, p.marked) |e, m| {
            if (m) try out.append(alloc, e.abs_path);
        }
    } else {
        try out.append(alloc, entry.abs_path);
    }
    return out.toOwnedSlice(alloc);
}

/// True once the pointer has moved `threshold_px` from where the button
/// went down, on either axis.
pub fn pastThreshold(from_x: f32, from_y: f32, x: f32, y: f32) bool {
    return @abs(x - from_x) >= threshold_px or @abs(y - from_y) >= threshold_px;
}
