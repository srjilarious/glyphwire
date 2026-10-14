// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Each side's tabs: several directories kept open in one pane, Ctrl+T to
//! add one, Ctrl+Tab / Ctrl+Shift+Tab to walk them and Ctrl+W (or a middle
//! click on the strip) to close one. Session-only, like the panes' history.
//!
//! The shown tab is not stored here. `Ui.panes[i]` stays the pane on
//! screen, so everything that already works on `&self.panes[i]` keeps
//! working, and a `TabSet` holds only the *hidden* tabs and where the shown
//! one sits among them. The order is
//!
//!     others[0..active] ++ [shown] ++ others[active..]
//!
//! and a switch moves values between `shown` and `others` -- a `Pane` is
//! plain data, already moved by value for Ctrl+U. Generic so the order
//! bookkeeping can be tested with integers.
//!
//! The strip itself is one row over the pane's title, drawn only while a
//! side has two or more tabs: a single-tab pane looks exactly as it did
//! before tabs existed. Laid out as
//!
//!     ` label │ label │ label `
//!
//! with no close box, so tabs stay narrow. A strip wider than the pane
//! scrolls between two arrows, with the wheel or a click on an arrow,
//! the same way zoe's does (`applib.tabstrip`).

const std = @import("std");
const glyphwire = @import("glyphwire");

pub fn TabSet(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Every tab but the shown one, in strip order.
        others: std.ArrayList(T) = .empty,
        /// The shown tab's position in the strip.
        active: usize = 0,

        /// Frees the list only; the caller deinits the values in it first.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.others.deinit(alloc);
        }

        pub fn count(self: *const Self) usize {
            return self.others.items.len + 1;
        }

        /// Tab `k` in strip order, which is `shown` itself at `active`.
        pub fn at(self: *Self, shown: *T, k: usize) *T {
            if (k == self.active) return shown;
            return &self.others.items[if (k < self.active) k else k - 1];
        }

        /// Puts `fresh` on screen as a new tab right after the shown one,
        /// which is kept. Ctrl+T.
        pub fn open(self: *Self, alloc: std.mem.Allocator, shown: *T, fresh: T) !void {
            try self.others.insert(alloc, self.active, shown.*);
            shown.* = fresh;
            self.active += 1;
        }

        /// Shows tab `k`, parking the one on screen in its place. False
        /// when `k` is already shown or isn't a tab. Can't fail: the
        /// parked tab takes the slot the incoming one leaves.
        pub fn switchTo(self: *Self, shown: *T, k: usize) bool {
            if (k == self.active or k >= self.count()) return false;
            const incoming = self.others.orderedRemove(if (k < self.active) k else k - 1);
            // `others` now holds every tab but the two trading places.
            // Once `k` is shown, the parked tab's index among the hidden
            // ones is its strip slot, less one when `k` is left of it.
            // Never allocates: the remove just freed the room.
            self.others.insertAssumeCapacity(if (k < self.active) self.active - 1 else self.active, shown.*);
            shown.* = incoming;
            self.active = k;
            return true;
        }

        /// The tab after (or before) the shown one, wrapping, so two tabs
        /// flip with one chord. False with only one tab.
        pub fn step(self: *Self, shown: *T, forward: bool) bool {
            const n = self.count();
            if (n < 2) return false;
            return self.switchTo(shown, if (forward) (self.active + 1) % n else (self.active + n - 1) % n);
        }

        /// Takes tab `k` out of the set and returns it for the caller to
        /// deinit. Null for the last tab, which never closes -- a side
        /// always shows a directory -- and for a `k` past the end. Closing
        /// the shown tab shows its right neighbour, or its left one when
        /// it was last, the way a browser does.
        pub fn close(self: *Self, shown: *T, k: usize) ?T {
            if (self.count() < 2 or k >= self.count()) return null;
            if (k != self.active) {
                const j = if (k < self.active) k else k - 1;
                if (k < self.active) self.active -= 1;
                return self.others.orderedRemove(j);
            }
            const gone = shown.*;
            if (self.active < self.others.items.len) {
                shown.* = self.others.orderedRemove(self.active);
            } else {
                shown.* = self.others.pop().?;
                self.active -= 1;
            }
            return gone;
        }
    };
}

// ── The strip ────────────────────────────────────────────────────────

pub const separator = "│";

/// Where one tab landed, in strip columns: `[start, end)`, separator
/// excluded.
pub const Span = struct { start: usize, end: usize };

/// What a tab shows: the directory's own name, or `/` for the root.
pub fn labelFor(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (base.len == 0) "/" else base;
}

/// A tab's width: its label with a space either side.
pub fn tabWidth(label: []const u8) usize {
    return glyphwire.stringWidth(label) + 2;
}

/// Lays `labels` out left to right into `out` and returns the strip's
/// total width, separators included.
pub fn layout(labels: []const []const u8, out: []Span) usize {
    var col: usize = 0;
    for (labels, 0..) |l, i| {
        const w = tabWidth(l);
        out[i] = .{ .start = col, .end = col + w };
        col += w;
        if (i + 1 < labels.len) col += glyphwire.stringWidth(separator);
    }
    return col;
}

/// The tab under strip column `col`, or null for a separator or the
/// space past the last tab.
pub fn hit(spans: []const Span, col: usize) ?usize {
    for (spans, 0..) |s, i| {
        if (col >= s.start and col < s.end) return i;
    }
    return null;
}
