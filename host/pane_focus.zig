// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The focused pane's highlight: the pane-divider cells that border the
//! focused pane, drawn in a colour of their own instead of the theme's
//! `pane_divider`. `host.conf.lua`'s `pane_focus_highlight` picks how:
//!
//! - `"none"`: no highlight, the dividers as they always were.
//! - `"solid"`: `pane_focus_color` held steady.
//! - `"pulse"` (the default): eased from `pane_focus_color` to
//!   `pane_focus_pulse_color` over `pane_focus_pulse_seconds`, and back
//!   over the same again.
//!
//! The host draws it, not the window manager: the dividers are the
//! host's, and so is focus (`Session.focused_pane`), so gmux needs no
//! part in it and every manager gets it the same.
//!
//! Only cells a pane divider already occupies are recoloured: a pane at
//! the window's edge has no divider on that side and gets nothing there,
//! and a lone pane has no highlight at all.
//!
//! Pure apart from the clock `tick` is handed: `render.zig` asks for the
//! colour and the cells, so the geometry and the easing have unit tests.

const std = @import("std");
const glyphwire = @import("glyphwire");

const theme = glyphwire.theme;
const CellRect = glyphwire.CellRect;

pub const Mode = enum { none, solid, pulse };

pub const Config = struct {
    mode: Mode = .pulse,
    /// The highlight, and the colour a pulse starts and ends on. A slot,
    /// a role, or `#rrggbb`, resolved against the window theme each
    /// frame so a theme switch carries it along.
    color: theme.RoleValue = .{ .role = .pane_focus },
    /// The colour a pulse eases to and back from.
    pulse_color: theme.RoleValue = .{ .role = .pane_focus_pulse },
    /// Milliseconds for one leg of a pulse, `color` to `pulse_color`.
    pulse_ms: f64 = pulse_ms_default,
};

pub const pulse_ms_default: f64 = 3000;
/// Below this a "pulse" is a flicker.
pub const pulse_ms_min: f64 = 100;
pub const pulse_ms_max: f64 = 60_000;

/// How often a pulse redraws. The colour only changes a channel step at
/// a time, and `FrameSig` skips a frame whose colour didn't move, so
/// this bounds the work rather than setting it.
pub const pulse_frame_ms: f64 = 33;

/// The highlight's state: its config and the pulse's clock.
pub const PaneFocus = struct {
    cfg: Config = .{},
    /// Milliseconds into the current pulse, kept below one whole period
    /// (two legs) so it never loses precision.
    elapsed_ms: f64 = 0,
    /// The pane the clock was last running for: a focus change restarts
    /// the pulse, so the newly focused pane lights up in `color` at once.
    pane: ?glyphwire.PaneHandle = null,
    /// Whether the window has the keyboard. An unfocused window holds
    /// the highlight at `color` and stops waking for it, as the caret
    /// stops blinking.
    window_focused: bool = true,

    /// Advances the pulse by `delta_ms`, restarting it if focus moved to
    /// another pane or the window lost the keyboard.
    pub fn tick(self: *PaneFocus, focused: glyphwire.PaneHandle, window_focused: bool, delta_ms: f64) void {
        self.window_focused = window_focused;
        if (self.pane != focused or !window_focused) {
            self.pane = focused;
            self.elapsed_ms = 0;
            return;
        }
        if (self.cfg.mode != .pulse) return;
        self.elapsed_ms = @mod(self.elapsed_ms + delta_ms, self.cfg.pulse_ms * 2);
    }

    /// The highlight's colour this frame against `th`, or null for
    /// `"none"`.
    pub fn color(self: *const PaneFocus, th: *const theme.Theme) ?glyphwire.Color {
        return switch (self.cfg.mode) {
            .none => null,
            .solid => th.valueColor(self.cfg.color),
            .pulse => theme.mix(
                th.valueColor(self.cfg.color),
                th.valueColor(self.cfg.pulse_color),
                pulseMix(self.elapsed_ms, self.cfg.pulse_ms),
            ),
        };
    }

    /// How long the host loop may sleep before the pulse needs a frame:
    /// null when nothing is pulsing (`"none"`, `"solid"`, an unfocused
    /// window, or no pane divider on screen to colour).
    pub fn idleTimeoutMs(self: *const PaneFocus, has_pane_dividers: bool) ?f64 {
        if (self.cfg.mode != .pulse or !self.window_focused or !has_pane_dividers) return null;
        return pulse_frame_ms;
    }
};

/// How far toward `pulse_color` a pulse is at `elapsed_ms`: 0 at the
/// start, 1 one leg (`pulse_ms`) later, 0 again after another. A half
/// cosine rather than a straight line, so it lingers at each colour and
/// turns around smoothly instead of bouncing off it.
pub fn pulseMix(elapsed_ms: f64, pulse_ms: f64) f32 {
    const leg = @max(pulse_ms, 1);
    const into = @mod(elapsed_ms, leg * 2);
    // 0 -> 1 over the first leg, 1 -> 0 over the second.
    const linear = if (into < leg) into / leg else 2 - into / leg;
    return @floatCast((1 - @cos(std.math.pi * linear)) / 2);
}

/// Whether the divider cell at `row`/`col` borders `pane`: it lies in
/// the one-cell ring around the pane's rect, corners included, so the
/// junctions where its dividers meet light up with them. A divider cell
/// is never inside a pane, so "in the rect grown by one" is the test.
pub fn touches(row: usize, col: usize, pane: CellRect) bool {
    const r = grown(pane);
    return row >= r.row and row < r.row + r.rows and col >= r.col and col < r.col + r.cols;
}

/// The part of `band` that borders `pane` (see `touches`), or null for a
/// band that doesn't. For the `block` divider style, which fills bands
/// rather than drawing cells.
pub fn clip(band: CellRect, pane: CellRect) ?CellRect {
    const r = grown(pane);
    const top = @max(band.row, r.row);
    const left = @max(band.col, r.col);
    const bottom = @min(band.row + band.rows, r.row + r.rows);
    const right = @min(band.col + band.cols, r.col + r.cols);
    if (top >= bottom or left >= right) return null;
    return .{ .row = top, .col = left, .rows = bottom - top, .cols = right - left };
}

/// `pane` grown by one cell on every side, stopping at the window's
/// top-left (there is no row or column -1 to grow into).
fn grown(pane: CellRect) CellRect {
    const row = pane.row -| 1;
    const col = pane.col -| 1;
    return .{
        .row = row,
        .col = col,
        .rows = pane.row + pane.rows + 1 - row,
        .cols = pane.col + pane.cols + 1 - col,
    };
}
