// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Following the open file as it changes on disk.
//!
//! `ui.zig` watches the page's directory with `applib/inotify.zig` and,
//! `settle_ms` after it reports something, stats the file and hands the
//! result here. A file whose size or mtime moved since gwmd last read it
//! is re-read in place, keeping the scroll (the `r` key's reload). A file
//! that is gone leaves the page up, since it is still worth reading, and
//! says so once; one that comes back is read again. Where inotify can't
//! start, the same check runs every `poll_ms` instead.
//!
//! Pure: the stat is the caller's, so the decision is testable with
//! plain values.

/// What gwmd knows about the file's on-disk version: enough to tell that
/// it changed, not what changed.
pub const Stamp = struct {
    size: u64,
    mtime_ns: i96,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns;
    }
};

pub const Action = enum { none, reload, gone };

/// How long after an inotify event the check runs. An editor's
/// save-by-rename is a burst of events; waiting lets the burst finish so
/// the check reads the new file, not a moment where it is missing.
pub const settle_ms = 50;

/// How often the file is stat'ed when inotify is unavailable.
pub const poll_ms = 1000;

/// What to do about the open file. `known` is the stamp of the version on
/// screen, or null once the file has been reported gone; `current` is the
/// stamp just read, null when the file no longer stats.
pub fn decide(known: ?Stamp, current: ?Stamp) Action {
    const now = current orelse return if (known != null) .gone else .none;
    const was = known orelse return .reload;
    return if (now.eql(was)) .none else .reload;
}
