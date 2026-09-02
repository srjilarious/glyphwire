//! Pure detection of the glyphwire handshake marker at the head of a
//! captured child's stdout -- see glyphwire-shell's
//! `Prompt.pumpChildOutput`. Dependency-free (a plain byte slice in, a
//! tri-state out) so the "glyphwire-aware child or plain program?"
//! decision can be unit-tested without a live pipe.

const std = @import("std");

/// What a glyphwire-aware child writes to its real stdout as it connects
/// (`Client.connect` -> `signalHandshake`). Its own copy rather than an
/// import so this file stays in the dependency-free `shell_support` set;
/// `pumpChildOutput` `comptime`-asserts the two spellings agree with the
/// `glyphwire` module's.
pub const marker = "\x00glyphwire-handshake-v1\x00";

/// Given `head` -- the unconsumed start of a child's stdout -- reports
/// whether the child announced itself as glyphwire-aware:
///
/// - `true`  -> `head` starts with `marker`. The caller discards the
///              first `marker.len` bytes and routes the rest of the
///              child's stdio straight through.
/// - `false` -> `head` is at least `marker.len` bytes and does not start
///              with `marker`. It's a plain program; mirror its output
///              (these bytes included) onto the grid.
/// - `null`  -> undecided: fewer than `marker.len` bytes so far, and
///              what's there is still a prefix of `marker`. Wait for
///              more. If the stream ends while still `null`, the caller
///              settles on `false` -- a real aware child always gets the
///              whole marker out in one `writeAll` + `flush`, so a
///              partial that never completes was never the marker.
pub fn aware(head: []const u8) ?bool {
    if (head.len >= marker.len) return std.mem.eql(u8, head[0..marker.len], marker);
    return if (std.mem.startsWith(u8, marker, head)) null else false;
}
