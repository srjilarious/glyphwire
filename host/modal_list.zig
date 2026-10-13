// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! What glyphwire-host's modal list dialogs share: the context switcher
//! (`switcher.zig`) and the theme switcher (`theme_switcher.zig`). Each
//! hands the renderer a `View` while it is open, and `Renderer.drawListDialog`
//! draws it the same way: a title bar, one row per entry with the
//! selected one highlighted, a key hint footer, all inside the window
//! theme's `panel_style` nine-patch with the dialog drop shadow -- the
//! look of zoe's file finder (`applib/finderpopup.zig`).
//!
//! The keys are shared too (`readAction`): Up/Down (k/j, Tab/Shift+Tab,
//! or the opening chord again) move, Enter picks, 1..9 pick that row,
//! Escape closes.
//!
//! Pure apart from `readAction`'s duck-typed keyboard, so the geometry
//! and the theme list are covered by `tests/host_tests.zig`.

const std = @import("std");
const glyphwire = @import("glyphwire");

const theme = glyphwire.theme;

pub const Row = struct {
    text: []const u8,
    /// Dim text after `text`: "(current)".
    tag: []const u8 = "",
};

/// One frame's worth of an open dialog. Every slice is borrowed from the
/// dialog until its next `handleKeys`.
pub const View = struct {
    /// The pane the dialog is centred on.
    pane: glyphwire.PaneHandle,
    title: []const u8,
    foot: []const u8,
    rows: []const Row,
    selected: usize,
};

/// A block of window cells.
pub const Rect = struct {
    row: usize = 0,
    col: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
};

pub const Layout = struct {
    /// The nine-patch: `content` grown by one cell all round.
    frame: Rect,
    /// The title bar is its first row and the footer its last; the
    /// entries are in between.
    content: Rect,
    /// The first entry shown, and how many fit. A list longer than the
    /// pane scrolls to keep the selection in view.
    first: usize,
    visible: usize,
};

/// Text columns a row needs before the entry text: the row number and a
/// gap ("1  ").
pub const number_cols = 3;

/// Where `view` goes inside `area` (the pane): sized to its longest line,
/// centred across, a third of the way down, never outside the pane. Null
/// when the pane is too small for a frame, a title, one row and a footer.
pub fn layout(area: Rect, view: View) ?Layout {
    if (area.rows < 5 or area.cols < 12 or view.rows.len == 0) return null;

    var want: usize = @max(glyphwire.stringWidth(view.title), glyphwire.stringWidth(view.foot));
    for (view.rows) |r| {
        want = @max(want, number_cols + glyphwire.stringWidth(r.text) + glyphwire.stringWidth(r.tag));
    }
    // A cell of margin either side inside the frame, and the frame's own
    // cell either side outside it.
    const cols = @min(want + 2, area.cols - 2);
    const visible = @min(view.rows.len, area.rows - 4);
    const rows = visible + 2;

    const selected = @min(view.selected, view.rows.len - 1);
    const first = if (selected >= visible) selected - visible + 1 else 0;

    const frame: Rect = .{
        .row = area.row + (area.rows - (rows + 2)) / 3,
        .col = area.col + (area.cols - (cols + 2)) / 2,
        .rows = rows + 2,
        .cols = cols + 2,
    };
    return .{
        .frame = frame,
        .content = .{ .row = frame.row + 1, .col = frame.col + 1, .rows = rows, .cols = cols },
        .first = first,
        .visible = visible,
    };
}

/// What a frame's key presses asked an open dialog to do.
pub const Action = union(enum) {
    none,
    close,
    /// Enter: the selected row.
    commit,
    move: isize,
    /// 1..9: that row, straight away.
    pick: usize,
};

/// `kb` is the engine's keyboard (`pressed`, `shift`); `chord_hit` is
/// whether this frame pressed the dialog's own chord, which steps down
/// like Tab so holding the modifier and tapping the key walks the list.
pub fn readAction(kb: anytype, chord_hit: bool) Action {
    if (chord_hit) return .{ .move = 1 };
    if (kb.pressed(.escape)) return .close;
    if (kb.pressed(.enter) or kb.pressed(.kp_enter)) return .commit;
    if (kb.pressed(.up) or kb.pressed(.k) or (kb.pressed(.tab) and kb.shift())) return .{ .move = -1 };
    if (kb.pressed(.down) or kb.pressed(.j) or kb.pressed(.tab)) return .{ .move = 1 };
    const digits = .{
        .{ .one, .kp_1 },   .{ .two, .kp_2 },   .{ .three, .kp_3 },
        .{ .four, .kp_4 },  .{ .five, .kp_5 },  .{ .six, .kp_6 },
        .{ .seven, .kp_7 }, .{ .eight, .kp_8 }, .{ .nine, .kp_9 },
    };
    inline for (digits, 0..) |d, i| {
        if (kb.pressed(d[0]) or kb.pressed(d[1])) return .{ .pick = i };
    }
    return .none;
}

/// `selected` moved by `delta`, wrapping at both ends of a `len`-row list.
pub fn wrapMove(selected: usize, len: usize, delta: isize) usize {
    if (len == 0) return 0;
    const n: isize = @intCast(len);
    const cur: isize = @intCast(selected);
    return @intCast(@mod(cur + delta, n));
}

/// The theme switcher's list: `theme.lua`'s own themes first, in the
/// order it defined them, then every built-in it didn't shadow. A custom
/// defined twice is listed once (the last definition is the one that
/// resolves), and one whose `base` chain never reaches a built-in is
/// left out, since picking it would do nothing. The names borrow from
/// `customs` and the built-in table; only the slice is `alloc`'s.
pub fn themeNames(alloc: std.mem.Allocator, customs: []const theme.Custom) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(alloc);
    for (customs) |c| {
        if (contains(names.items, c.name)) continue;
        if (theme.resolve(c.name, customs) == null) continue;
        try names.append(alloc, c.name);
    }
    for (&theme.builtins) |*b| {
        if (contains(names.items, b.name)) continue;
        try names.append(alloc, b.name);
    }
    return names.toOwnedSlice(alloc);
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}
