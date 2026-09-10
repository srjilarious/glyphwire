//! The buffer tab strip's geometry.
//!
//! One row above the buffer pane listing every open buffer, with a close
//! box on each tab. Everything here is pure -- it turns a list of labels
//! into column ranges and answers "which tab is under this column" --
//! so the strip's layout, its horizontal scrolling and its hit testing
//! are all unit-testable without a display server. `zoe/ui.zig` does the
//! drawing and owns the buffer list itself.
//!
//! A tab is laid out as
//!
//!     ` label × `           and, when the buffer is modified,
//!     ` label + × `
//!
//! with a `│` separator between neighbours. The strip is measured in
//! *strip* columns, which are pane columns plus the scroll offset: a
//! strip wider than the pane scrolls sideways rather than shrinking its
//! tabs, so a tab's label never turns into an ellipsis.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// The close box. One cell, and a plain `×` (U+00D7) rather than a
/// heavier dingbat -- it is in every font a terminal is likely to use,
/// and it is single-width everywhere.
pub const close_glyph = "×";
/// Drawn between neighbouring tabs, not after the last one.
pub const separator = "│";
/// `+` in the tab, matching the statusline's `[+]`.
pub const dirty_mark = "+";

pub const Tab = struct {
    /// What the tab shows -- a path's basename, or `[No Name]`.
    label: []const u8,
    /// Whether the buffer has unsaved changes.
    dirty: bool,
};

/// Where one tab landed, in strip columns.
pub const Span = struct {
    /// `[start, end)` -- the whole tab, separator excluded.
    start: usize,
    end: usize,
    /// The single column the close box occupies.
    close: usize,
};

/// What a click at some strip column landed on.
pub const Hit = struct {
    index: usize,
    /// True when the click was on the close box rather than the tab body.
    close: bool,
};

/// The cells one tab occupies: a space either side of the label, the
/// close box and its own leading space, plus ` +` when modified.
pub fn tabWidth(label: []const u8, dirty: bool) usize {
    return 1 + glyphwire.stringWidth(label) + (if (dirty) @as(usize, 2) else 0) + 1 + 1 + 1;
}

/// Lays `tabs` out left to right into `out` (cleared first) and returns
/// the strip's total width, separators included.
pub fn layout(
    alloc: std.mem.Allocator,
    tabs: []const Tab,
    out: *std.ArrayList(Span),
) !usize {
    out.clearRetainingCapacity();
    var col: usize = 0;
    for (tabs, 0..) |t, i| {
        const w = tabWidth(t.label, t.dirty);
        try out.append(alloc, .{
            .start = col,
            .end = col + w,
            // The close box sits one space in from the tab's right edge.
            .close = col + w - 2,
        });
        col += w;
        if (i + 1 < tabs.len) col += glyphwire.stringWidth(separator);
    }
    return col;
}

/// The scroll offset that brings `span` fully into a `cols`-wide pane,
/// moving as little as possible from `scroll`: a tab off the right edge
/// scrolls just far enough to show its close box, one off the left edge
/// scrolls to its leading space. A strip that fits shows its start.
pub fn scrollToShow(span: Span, cols: usize, scroll: usize, total: usize) usize {
    if (cols == 0 or total <= cols) return 0;
    var s = scroll;
    // Right edge first: a tab wider than the pane then still has its
    // left edge visible, which is where the label is.
    if (span.end > s + cols) s = span.end - cols;
    if (span.start < s) s = span.start;
    return @min(s, total - cols);
}

/// The tab under strip column `col`, or null for the gap between tabs
/// and the empty space past the last one.
pub fn hit(spans: []const Span, col: usize) ?Hit {
    for (spans, 0..) |s, i| {
        if (col < s.start or col >= s.end) continue;
        return .{ .index = i, .close = col == s.close };
    }
    return null;
}

/// The label for a buffer path -- its basename, since the statusline
/// already carries the full path. Buffers whose basenames collide are
/// shown identically; the statusline disambiguates them.
pub fn labelFor(path: ?[]const u8) []const u8 {
    const p = path orelse return "[No Name]";
    const base = std.fs.path.basename(p);
    return if (base.len == 0) p else base;
}
