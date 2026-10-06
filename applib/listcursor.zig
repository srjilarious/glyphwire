// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The selection and scroll position of a list on screen: which row is
//! picked, which row is at the top of the window, and the arithmetic that
//! keeps the two consistent as the pick moves, the list changes length,
//! or the user scrolls. zoe's completion and path menus, gw-shell's Tab
//! picker, gw-hist, the fuzzy finder, salacommander's panes and the
//! host's modal list dialogs all run on it.
//!
//! Pure, and its own build module (re-exported as `applib.listcursor`)
//! so glyphwire-host can use it without linking the rest of `applib`.

const std = @import("std");

/// What a move does at the ends of the list.
pub const Ends = enum {
    /// Off the bottom comes back at the top, and the reverse: a short
    /// menu cycled with Tab.
    wrap,
    /// Stops at the first / last row: a ranked list, where running off
    /// the top back to the worst match is never what was meant.
    clamp,
};

pub const ListCursor = struct {
    /// The picked row.
    selected: usize = 0,
    /// The row at the top of the window.
    top: usize = 0,

    /// Back to the first row, scrolled to the top.
    pub fn reset(self: *ListCursor) void {
        self.* = .{};
    }

    /// Moves the pick `delta` rows through a list `len` long. An empty
    /// list leaves it on row 0.
    pub fn step(self: *ListCursor, delta: isize, len: usize, ends: Ends) void {
        if (len == 0) {
            self.selected = 0;
            return;
        }
        switch (ends) {
            .wrap => self.selected = wrap(self.selected, len, delta),
            .clamp => {
                if (delta < 0) {
                    self.selected -|= @abs(delta);
                } else {
                    self.selected +|= @intCast(delta);
                }
                self.clamp(len);
            },
        }
    }

    /// Puts the pick on `row`, clamped into the list.
    pub fn set(self: *ListCursor, row: usize, len: usize) void {
        self.selected = row;
        self.clamp(len);
    }

    /// Pulls the pick back inside a list `len` long: the list shrank under
    /// it.
    pub fn clamp(self: *ListCursor, len: usize) void {
        self.selected = @min(self.selected, len -| 1);
    }

    /// Scrolls just enough that the pick is within the `rows` rows from
    /// `top`. Zero rows (nothing drawn yet) leaves `top` alone.
    pub fn follow(self: *ListCursor, rows: usize) void {
        if (rows == 0) return;
        if (self.selected < self.top) self.top = self.selected;
        if (self.selected >= self.top + rows) self.top = self.selected + 1 - rows;
    }

    /// `follow`, then `clampTop`: also keeps a list that is long enough
    /// to fill the window from leaving blank rows at the bottom. Zero
    /// rows or an empty list scrolls to the top.
    pub fn followClamped(self: *ListCursor, rows: usize, len: usize) void {
        if (rows == 0 or len == 0) {
            self.top = 0;
            return;
        }
        self.follow(rows);
        self.clampTop(rows, len);
    }

    /// Pulls `top` back so the window's `rows` don't run past the end of
    /// the list: the window got taller, or the list got shorter. Doesn't
    /// drag the window onto the pick -- doing that every frame would undo
    /// a wheel scroll the moment it was drawn.
    pub fn clampTop(self: *ListCursor, rows: usize, len: usize) void {
        self.top = @min(self.top, len -| rows);
    }

    /// Follows a host-side scroll (the wheel, a scrollbar drag) to `top`
    /// without moving the pick: scrolling past a row and picking it are
    /// two gestures.
    pub fn scrollTo(self: *ListCursor, top: usize, rows: usize, len: usize) void {
        self.top = top;
        self.clampTop(rows, len);
    }

    /// The other half of a scroll where the pick rides along: moves the
    /// pick onto the nearest row of the window it fell out of.
    pub fn pullOnScreen(self: *ListCursor, rows: usize) void {
        if (rows == 0) return;
        if (self.selected < self.top) self.selected = self.top;
        if (self.selected >= self.top + rows) self.selected = self.top + rows - 1;
    }
};

/// `selected` moved by `delta`, wrapping at both ends of a `len`-row
/// list. 0 for an empty list.
pub fn wrap(selected: usize, len: usize, delta: isize) usize {
    if (len == 0) return 0;
    const n: isize = @intCast(len);
    const cur: isize = @intCast(selected);
    // `@mod` takes the divisor's sign, so a negative step wraps too.
    return @intCast(@mod(cur + delta, n));
}
