// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Noticing that an open file changed on disk behind zoe's back.
//!
//! `zoe/ui.zig` stats every open buffer's file about once a second and
//! hands the result here. A file whose size or mtime moved since zoe last
//! read or wrote it is reloaded when its buffer has no unsaved edits, and
//! reported once (vim's W11) when it does -- zoe never throws away typing
//! to follow the disk. Polling rather than inotify: a stat per open file
//! per second costs nothing, works the same everywhere, and sees an
//! editor's save-by-rename without watching directories.
//!
//! Pure: the stat itself is the caller's, so the decision is testable
//! with plain values.

const std = @import("std");

/// What zoe knows about a file's on-disk version: enough to tell that it
/// changed, not what changed.
pub const Stamp = struct {
    size: u64,
    mtime_ns: i96,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns;
    }
};

pub const Action = enum { none, reload, warn };

/// How often the open files are stat'ed.
pub const poll_ms = 1000;

/// What to do about one buffer's file. `known` is the stamp zoe last
/// read or wrote (null for a buffer that never had one on disk), `warned`
/// the changed stamp already reported for a modified buffer, `current`
/// the stamp just read (null when the file is gone or unreadable), and
/// `dirty` whether the buffer has unsaved edits.
///
///  - A file that vanished is left alone: the buffer is the only copy
///    now, and `:w` brings it back.
///  - A buffer zoe never read from disk has nothing to compare against.
///  - An unchanged file is nothing to do.
///  - A changed file under a clean buffer reloads.
///  - Under a modified buffer it warns, once per change: `warned` holds
///    the stamp already reported, so the same change doesn't repeat every
///    second, but a further write to the file reports again.
pub fn decide(known: ?Stamp, warned: ?Stamp, current: ?Stamp, dirty: bool) Action {
    const now = current orelse return .none;
    const was = known orelse return .none;
    if (now.eql(was)) return .none;
    if (!dirty) return .reload;
    if (warned) |w| {
        if (w.eql(now)) return .none;
    }
    return .warn;
}
