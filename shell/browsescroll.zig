//! Pure scrolloff math for glyphwire-shell's Up/Down scrollback browsing
//! (`Prompt.browseUp` / `browseDown`). No IO -- given the current browse
//! state and the window geometry it returns where the browse cursor and
//! the host's scrollback view offset should end up, keeping a vim-style
//! margin between the cursor and the edge of the window. The caller
//! applies the result with `set_property(cursor)` / `scroll_view`.

const std = @import("std");

pub const State = struct {
    /// The browse cursor's row within the visible window (0 = top row).
    bp_row: usize,
    /// Rows the host view is currently scrolled back into history.
    view_scroll: usize,
};

pub const Result = struct {
    bp_row: usize,
    view_scroll: usize,
    /// `down` only: the move ran into the prompt row -- the caller should
    /// end browsing and land on the real prompt cursor.
    ended: bool = false,
};

/// The scrolloff margin actually used: the configured/default `want`,
/// clamped so at least half the rows between the top of the grid and the
/// prompt row are left for the cursor to travel through.
pub fn clampScrolloff(want: usize, line_start_row: usize) usize {
    return @min(want, line_start_row / 2);
}

/// Walk the browse cursor `count` rows up. While the cursor is more than
/// `margin` rows below the top it just moves; once it reaches the margin
/// the window scrolls back instead (up to `view_max`), holding the cursor
/// at the margin; once the scrollback is exhausted the cursor is allowed
/// to finish climbing to row 0. `entering` means this press is the one
/// that enters browse mode: the caller has already moved the cursor one
/// row up off the prompt line, so the first of `count` is spent -- unless
/// the prompt was on row 0 (`bp_row == 0`, nothing above it), where the
/// whole `count` is still available and a first Up scrolls straight away.
pub fn up(s: State, count: usize, margin: usize, view_max: usize, entering: bool) Result {
    var bp = s.bp_row;
    var vs = s.view_scroll;
    var remaining = count;
    if (entering and bp > 0) remaining -|= 1;

    while (remaining > 0) {
        if (bp > margin) {
            const step = @min(remaining, bp - margin);
            bp -= step;
            remaining -= step;
        } else if (vs < view_max) {
            const step = @min(remaining, view_max - vs);
            vs += step;
            remaining -= step;
        } else {
            if (bp == 0) break;
            const step = @min(remaining, bp);
            bp -= step;
            remaining -= step;
        }
    }
    return .{ .bp_row = bp, .view_scroll = vs };
}

/// Pick a `{view_scroll, bp_row}` that puts content row `above` (in the
/// scroll-stable coordinate `core.SelectionPoint.above` documents:
/// positive counts up into retained scrollback, zero or negative is a
/// live-viewport row) on screen, keeping `margin` rows of context above
/// it when the scrollback allows. `view_max` is how far back the view can
/// scroll (`history_len`); `bottom_row` is the last browsable screen row
/// (the one just above the prompt). Used by the shell's Ctrl+PgUp/PgDn
/// metadata-span jump, which lands on an arbitrary row rather than
/// stepping one at a time like `up`/`down` do.
pub fn locate(above: i64, margin: usize, view_max: usize, bottom_row: usize) Result {
    // Feasible view offsets: `bp_row = view_scroll - above` must stay in
    // `[0, bottom_row]`, and `view_scroll` in `[0, view_max]`.
    const lo = @max(@as(i64, 0), above);
    const hi = @min(@as(i64, @intCast(view_max)), above + @as(i64, @intCast(bottom_row)));

    var vs: i64 = above + @as(i64, @intCast(margin));
    if (vs < lo) vs = lo;
    if (vs > hi) vs = hi;
    if (vs < 0) vs = 0; // `hi < lo` only if `above` isn't actually retained.

    const r = vs - above;
    return .{
        .bp_row = @intCast(if (r < 0) 0 else r),
        .view_scroll = @intCast(vs),
    };
}

/// Walk the browse cursor `count` rows down toward the prompt. `bottom` is
/// the last browsable row (the one just above the prompt line). Symmetric
/// with `up`: the cursor moves down freely until it's `margin` rows from
/// `bottom` (`hold_row`); from there, while the view is still scrolled
/// back, each further "down" un-scrolls the window toward the live tail
/// and holds the cursor at `hold_row`; once the view is at the tail the
/// cursor moves the rest of the way down, and a step past `bottom` sets
/// `ended` (the caller ends browsing on the prompt row).
pub fn down(s: State, count: usize, margin: usize, bottom: usize) Result {
    var bp = s.bp_row;
    var vs = s.view_scroll;
    var remaining = count;
    const hold_row = bottom -| margin;

    while (remaining > 0) {
        if (bp < hold_row) {
            const step = @min(remaining, hold_row - bp);
            bp += step;
            remaining -= step;
        } else if (vs > 0) {
            const step = @min(remaining, vs);
            vs -= step;
            remaining -= step;
        } else {
            if (bp + 1 > bottom) return .{ .bp_row = bp, .view_scroll = vs, .ended = true };
            const step = @min(remaining, bottom - bp);
            bp += step;
            remaining -= step;
        }
    }
    return .{ .bp_row = bp, .view_scroll = vs };
}
