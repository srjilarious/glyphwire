// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Which bytes' selection highlight changed between two frames.
//!
//! A drag step or a visual-mode motion moves one end of the selection by
//! a little, so repainting the whole buffer pane for it -- what zoe did --
//! sends every row again for a change that touches one or two. This
//! works out the byte ranges whose selected-ness differs between the old
//! span and the new one; `ui.zig` turns them into rows.

const std = @import("std");
const editor = @import("editor.zig");

pub const SelSpan = editor.Editor.SelSpan;

/// A half-open byte range.
pub const ByteRange = struct { start: usize, end: usize };

/// Fills `out` with up to two byte ranges covering every byte selected in
/// exactly one of `old` and `new`, and returns how many it used.
///
///   - Neither selection: nothing changed.
///   - One side only (a selection appearing or going away): all of it.
///   - Charwise on one side, linewise on the other: the highlight's
///     extent past the text differs on every line, so the union of both.
///   - Same kind: each end that moved, as the range between its old and
///     new position. Two ranges at most -- one per end.
pub fn changedRanges(old: ?SelSpan, new: ?SelSpan, out: *[2]ByteRange) usize {
    const a = old orelse {
        const b = new orelse return 0;
        out[0] = .{ .start = b.lo, .end = b.hi };
        return 1;
    };
    const b = new orelse {
        out[0] = .{ .start = a.lo, .end = a.hi };
        return 1;
    };
    if (a.linewise != b.linewise) {
        out[0] = .{ .start = @min(a.lo, b.lo), .end = @max(a.hi, b.hi) };
        return 1;
    }
    var n: usize = 0;
    if (a.lo != b.lo) {
        out[n] = .{ .start = @min(a.lo, b.lo), .end = @max(a.lo, b.lo) };
        n += 1;
    }
    if (a.hi != b.hi) {
        out[n] = .{ .start = @min(a.hi, b.hi), .end = @max(a.hi, b.hi) };
        n += 1;
    }
    return n;
}
