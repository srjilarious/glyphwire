// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! What a shell waiting on a job makes of its pane's context stack
//! (`list_contexts`) after a visibility change. Pure, so the rules are
//! covered by `tests/shell_tests.zig`; `jobs.noteVisibleContext` does the
//! round trip and applies the answer.

const glyphwire = @import("glyphwire");

const ContextEntry = glyphwire.protocol.ContextEntry;
const ContextHandle = glyphwire.ContextHandle;

pub const Reading = union(enum) {
    /// Nothing to act on: keep waiting.
    none,
    /// Something other than this shell is on top and the job has no
    /// screen yet: this is it, for `fg` to bring back later.
    claim: ContextHandle,
    /// This shell is back on top with the job's screen still behind it:
    /// the job was put in the background.
    backgrounded,
};

/// `entries` is the pane's stack top first, `current` this shell's own
/// context, `job_context` the job's screen if it has claimed one.
///
/// A context flagged `shell` is never claimed. It is another shell's
/// screen (the pane's base, or one the host's context switcher spawned),
/// so it coming up on top means the user switched shells, not that the
/// job opened a screen of its own. Claiming it would make switching back
/// to this shell look like the job being backgrounded.
pub fn read(entries: []const ContextEntry, current: ContextHandle, job_context: ?ContextHandle) Reading {
    if (entries.len == 0) return .none;
    const top = entries[0];
    if (top.context != current) {
        if (job_context == null and !top.shell) return .{ .claim = top.context };
        return .none;
    }
    // Back on top, but only a switch away if the job's screen is still
    // in the stack behind this one. A program on its way out destroys
    // its context before it is reaped, which also puts this shell back
    // on top; that is an exit in progress, and the caller keeps waiting
    // for the reap instead of announcing a background job.
    const ctx = job_context orelse return .none;
    for (entries[1..]) |entry| {
        if (entry.context == ctx) return .backgrounded;
    }
    return .none;
}
