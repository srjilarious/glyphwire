const std = @import("std");

/// The `$PWD`-style logical working directory glyphwire-shell shows in its
/// prompt and exports to spawned children, kept the way bash/fish keep
/// theirs: purely as a string, never round-tripped through the real
/// filesystem. `cd`ing into a symlinked directory (`~/download ->
/// /mnt/shares/downloads`) then shows `~/download`, not the physical
/// target -- the kernel resolves the symlink when the shell actually
/// `chdir`s there, but the *displayed* path keeps whatever name was typed.
///
/// `resolve` is `Prompt.chdir`'s one piece of non-trivial logic, pulled
/// out here (no IO, no allocator-owned state beyond the one return value)
/// so it can be tested without a real filesystem.

/// The new logical path after `cd`ing from `base` (the current `$PWD`) to
/// `target`. An absolute `target` replaces `base` outright; a relative one
/// is joined onto it. Either way the join is lexical only -- `.`/`..`
/// components collapse against the string, exactly like `std.fs.path`
/// join/resolve and POSIX's own `cd` algorithm, never by consulting the
/// filesystem -- so `cd ..` from inside a symlinked directory returns to
/// the symlink's *own* parent, not the parent of whatever it points at.
/// Caller owns the result.
pub fn resolve(alloc: std.mem.Allocator, base: []const u8, target: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(target)) return std.fs.path.resolve(alloc, &.{target});
    return std.fs.path.resolve(alloc, &.{ base, target });
}
