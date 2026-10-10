// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Noticing that an open file changed on disk behind zoe's back.
//!
//! `zoe/ui.zig` stats every open buffer's file and hands the result here.
//! A file whose size or mtime moved since zoe last read or wrote it is
//! reloaded when its buffer has no unsaved edits, and reported once
//! (vim's W11) when it does -- zoe never throws away typing to follow the
//! disk. A file that is gone marks its tab (`gone`) and leaves the
//! buffer alone.
//!
//! *When* it stats is the `file_watch` setting (`Mode`), and only that:
//! the stat and these rules are the same whichever wakes them. Polling
//! is the default -- a stat per open file per second costs nothing,
//! works the same everywhere, and sees an editor's save-by-rename without
//! watching directories. inotify (`zoe/inotify.zig`) answers within
//! `settle_ms` instead of up to a second, and does nothing at all while
//! nothing changes.
//!
//! Pure: the stat itself is the caller's, so the decision is testable
//! with plain values.

const std = @import("std");

/// What wakes the disk check: `config.file_watch`.
pub const Mode = enum {
    /// Every `poll_ms`.
    poll,
    /// When the kernel reports a change in a directory holding an open
    /// file or an expanded tree folder, `settle_ms` after it. Linux only;
    /// elsewhere, or when inotify can't start, zoe falls back to `poll`.
    inotify,
    /// Never: outside changes go unnoticed until `:e`.
    off,
};

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

/// How often the open files are stat'ed under `.poll`.
pub const poll_ms = 1000;

/// How long after an inotify event the check runs. A save-by-rename or
/// a `git checkout` is a burst of events; waiting this long lets the
/// burst finish so the check sees where it ended, not a file caught
/// mid-rename (which would flash the deleted mark).
pub const settle_ms = 50;

/// Whether a buffer's file has been deleted (or moved away): zoe had it
/// on disk (`known`) and it no longer stats (`current`). A buffer never
/// written is not "gone", it was never there.
pub fn gone(known: ?Stamp, current: ?Stamp) bool {
    return known != null and current == null;
}

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
