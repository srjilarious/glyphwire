// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! A one-row tab strip's scrolling, shared by zoe's buffer tabs and
//! salacommander's directory tabs.
//!
//! Each program lays its own tabs out (they look different: zoe's carry
//! a close box) into spans of *strip* columns, `[start, end)` from the
//! strip's left end. What is shared is how a strip wider than its pane
//! is shown:
//!
//!     ‹ b.zig │ c.zig │ d.z ›
//!
//! While the strip overflows, the pane's first and last columns hold a
//! scroll arrow each and the tabs scroll in the columns between them --
//! the `Window`. An arrow is dimmed when there's nothing further its
//! way. A click on one brings the next tab hidden that way fully into
//! view (`stepBack` / `stepForward`). A strip that fits has no arrows
//! and starts at the pane's left edge.
//!
//! The wheel needs nothing here: a strip's layer reports a content
//! extent (`Window.extent`) one row tall, so the host turns a wheel over
//! it into a sideways `scroll_offset` the program then follows.
//!
//! The span functions take any slice of structs with `start` and `end`
//! fields, so each program keeps its own `Span` type.

const std = @import("std");
const glyphwire = @import("glyphwire");

const Batch = glyphwire.client.Client.Batch;
const Color = glyphwire.Color;

/// Single-width in every font a terminal is likely to use, and light
/// enough not to read as a tab of their own.
pub const arrow_back = "‹";
pub const arrow_forward = "›";

/// The columns one arrow takes.
pub const arrow_cols: usize = 1;

/// Where the tabs show inside a `cols`-wide pane.
pub const Window = struct {
    /// Whether the arrows are drawn.
    arrows: bool,
    /// The pane column the strip's visible part starts at: past the back
    /// arrow, or 0.
    left: usize,
    /// How many strip columns are visible.
    cols: usize,

    /// The furthest the strip can scroll.
    pub fn maxScroll(self: Window, total: usize) usize {
        return total -| self.cols;
    }

    /// The content width to report as the layer's extent, so the host's
    /// own scroll range (extent less the pane) matches `maxScroll`: the
    /// arrows' columns count as content that never scrolls away.
    pub fn extent(self: Window, total: usize) usize {
        return @max(total, self.cols) + (if (self.arrows) 2 * arrow_cols else 0);
    }

    /// `scroll` kept inside the strip.
    pub fn clamp(self: Window, scroll: usize, total: usize) usize {
        return @min(scroll, self.maxScroll(total));
    }

    /// What pane column `col` shows at strip offset `scroll`.
    pub fn at(self: Window, scroll: usize, col: usize) Spot {
        if (self.arrows) {
            if (col < self.left) return .back;
            if (col >= self.left + self.cols) return .forward;
        } else if (col >= self.cols) {
            return .past;
        }
        return .{ .strip = col - self.left + scroll };
    }

    /// The pane column strip column `strip` lands on at `scroll`, or
    /// null when it's scrolled out of view.
    pub fn paneCol(self: Window, scroll: usize, strip: usize) ?usize {
        if (strip < scroll or strip >= scroll + self.cols) return null;
        return strip - scroll + self.left;
    }
};

/// What is under a pane column of the strip.
pub const Spot = union(enum) {
    back,
    forward,
    /// Past the strip's right end in a pane wider than it.
    past,
    /// A strip column: a tab, a separator, or the space past the last tab.
    strip: usize,
};

/// The window for a strip `total` columns wide in a `cols`-wide pane.
/// Arrows only once the strip overflows, and only while the pane has
/// room for a column of tabs between them.
pub fn window(total: usize, cols: usize) Window {
    if (total <= cols or cols < 2 * arrow_cols + 1) return .{ .arrows = false, .left = 0, .cols = cols };
    return .{ .arrows = true, .left = arrow_cols, .cols = cols - 2 * arrow_cols };
}

/// The scroll that brings `[start, end)` fully into view, moving as
/// little as possible from `scroll`: a tab off the right edge scrolls
/// just far enough to show its right end, one off the left edge to its
/// left end. A tab wider than the view shows its left end, where the
/// label is. A strip that fits shows its start.
pub fn scrollToShow(start: usize, end: usize, win: Window, scroll: usize, total: usize) usize {
    if (win.cols == 0 or total <= win.cols) return 0;
    var s = scroll;
    if (end > s + win.cols) s = end - win.cols;
    if (start < s) s = start;
    return win.clamp(s, total);
}

/// The back arrow: the scroll that shows the nearest tab cut off by (or
/// wholly past) the view's left edge, from its left end. `scroll` when
/// already at the start.
pub fn stepBack(spans: anytype, scroll: usize) usize {
    var i = spans.len;
    while (i > 0) {
        i -= 1;
        if (spans[i].start < scroll) return spans[i].start;
    }
    return 0;
}

/// The forward arrow: the scroll that shows the nearest tab cut off by
/// (or wholly past) the view's right edge, to its right end.
pub fn stepForward(spans: anytype, scroll: usize, win: Window, total: usize) usize {
    for (spans) |s| {
        if (s.end > scroll + win.cols) return win.clamp(s.end - win.cols, total);
    }
    return win.clamp(scroll, total);
}

/// The arrow colours: `fg` for one that would scroll, `fg_dim` for one
/// at its end.
pub const ArrowColors = struct {
    fg: Color,
    fg_dim: Color,
    bg: Color,
};

/// Draws `win`'s arrows on `row` of `layer`, a `pane_cols`-wide pane, at
/// `scroll`. Nothing when the strip fits.
pub fn drawArrows(
    batch: *Batch,
    layer: glyphwire.LayerHandle,
    row: usize,
    win: Window,
    scroll: usize,
    total: usize,
    colors: ArrowColors,
) !void {
    if (!win.arrows) return;
    const back_fg = if (scroll > 0) colors.fg else colors.fg_dim;
    const forward_fg = if (scroll < win.maxScroll(total)) colors.fg else colors.fg_dim;
    try batch.writeText(arrow_back, .{ .layer = layer, .row = row, .col = 0, .fg = back_fg, .bg = colors.bg });
    try batch.writeText(arrow_forward, .{ .layer = layer, .row = row, .col = win.left + win.cols, .fg = forward_fg, .bg = colors.bg });
}

/// What the strip last revealed the active tab for. A strip keeps the
/// scroll the user gave it (an arrow, the wheel) until one of these
/// changes; then it scrolls the active tab back into view.
pub const Follow = struct {
    active: usize = std.math.maxInt(usize),
    count: usize = 0,
    total: usize = 0,
    cols: usize = 0,

    /// True, and remembers the new state, when the active tab, the
    /// number of tabs or the strip's or pane's width changed since the
    /// last call.
    pub fn changed(self: *Follow, active: usize, count: usize, total: usize, cols: usize) bool {
        const now: Follow = .{ .active = active, .count = count, .total = total, .cols = cols };
        if (std.meta.eql(now, self.*)) return false;
        self.* = now;
        return true;
    }
};
