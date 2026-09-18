// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure placement math for where glyphwire-shell's next prompt goes once
//! a command has finished -- see `Prompt.submitLine`. Dependency-free (a
//! cursor position in, a row out) so the rule can be unit-tested without
//! a live connection.

const std = @import("std");

/// The row the next prompt starts on, given where the server's cursor
/// ended up after the command ran.
///
/// A cursor sitting at column 0 is already on a fresh row -- either the
/// command's last write ended in a newline, or (the full-screen case) it
/// drew into its own context and never touched this layer at all, leaving
/// the cursor on the blank row `submitLine` dropped to before dispatch.
/// Either way the prompt belongs on that row, directly under the command
/// line. Only a cursor left mid-row needs to be pushed down one, so the
/// prompt doesn't land on top of a partial line of output.
///
/// This used to be an unconditional `row + 1`, from when a full-screen
/// program painted the shell's own grid and the row the cursor was left
/// on could not be trusted. With contexts, such a program never touches
/// this layer -- so the `+1` bought nothing and cost a blank row on every
/// command.
pub fn next(row: usize, col: usize) usize {
    return if (col == 0) row else row + 1;
}
