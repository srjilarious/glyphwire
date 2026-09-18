// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure placement math for where glyphwire-shell puts things once a line
//! is submitted -- see `Prompt.submitLine`. Dependency-free (a cursor
//! position in, a row out) so the rules can be unit-tested without a live
//! connection.

const std = @import("std");

/// The first fresh row at or after the cursor: the row itself when the
/// cursor is at column 0 (already fresh -- the last write ended in a
/// newline, or nothing was written at all), otherwise the row below, so
/// nothing lands on top of a partial line.
///
/// `submitLine` uses this to decide where a command's output starts,
/// directly under the re-echoed command line (however many rows it
/// wrapped onto).
pub fn next(row: usize, col: usize) usize {
    return if (col == 0) row else row + 1;
}

/// The row the next prompt starts on once a command has finished, given
/// where the server's cursor ended up: one blank row below the end of
/// whatever the command left behind.
///
/// The gap is uniform. It used to fall out of an unconditional `row + 1`,
/// which gave a blank row after output that ended in a newline but none
/// after output that didn't (a "command not found" report, say), and --
/// since a full-screen program that draws in its own context leaves the
/// cursor exactly where `submitLine` put it -- a blank row after zoe only
/// by coincidence.
pub fn afterCommand(row: usize, col: usize) usize {
    return next(row, col) + 1;
}
