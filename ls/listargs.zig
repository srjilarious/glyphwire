// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The flags a listing was drawn with, as gw-ls arguments, for each
//! directory entry's `list_args` metadata (`entries.entryMetadataJson`).
//! The shell lists a picked directory with them, so `gw-ls -aS` output
//! leads to more `-aS` listings (`on{ chdir = { carry_args } }`).
//!
//! The flags are the resolved display, not the command line as typed:
//! `-L` or `-S` is always there, so an alias that adds `-S` to `gw-ls`
//! can't turn a large listing small on the way down, and the operands
//! never are, since the picked directory replaces them.

pub const Display = struct {
    hidden: bool,
    long: bool,
    large: bool,
    raw_bytes: bool,
};

/// The most `args` ever returns.
pub const max = 4;

/// `d` as gw-ls flags, in `buf`.
pub fn args(d: Display, buf: *[max][]const u8) []const []const u8 {
    var n: usize = 0;
    if (d.hidden) {
        buf[n] = "-a";
        n += 1;
    }
    if (d.long) {
        buf[n] = "-l";
        n += 1;
    }
    buf[n] = if (d.large) "-L" else "-S";
    n += 1;
    if (d.raw_bytes) {
        buf[n] = "--bytes";
        n += 1;
    }
    return buf[0..n];
}
