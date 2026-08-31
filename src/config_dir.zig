//! Where glyphwire's per-user config files live -- `host.conf`,
//! `shell.conf`, `ls.conf`, and the optional `icons/` override tree. Every
//! binary resolves the same directory the same way, so this is the one
//! copy they all call (`glyphwire.configDirPath`) rather than three that
//! have to be kept "byte-for-byte in step" by hand.

const std = @import("std");

/// Owned path to glyphwire's config directory:
///   1. `$GLYPHWIRE_CONFIG_DIR` verbatim, when set and non-empty (the
///      override the e2e tests use to keep the real one out of the way);
///   2. else `$XDG_CONFIG_HOME/glyphwire`;
///   3. else `$HOME/.config/glyphwire`.
/// `error.NoConfigHome` when none of those are set -- the caller then just
/// runs on built-in defaults, same as a missing config file. Caller owns
/// the returned slice.
pub fn configDirPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]u8 {
    if (environ_map.get("GLYPHWIRE_CONFIG_DIR")) |dir| {
        if (dir.len > 0) return alloc.dupe(u8, dir);
    }
    if (environ_map.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "glyphwire" });
    }
    const home = environ_map.get("HOME") orelse return error.NoConfigHome;
    if (home.len == 0) return error.NoConfigHome;
    return std.fs.path.join(alloc, &.{ home, ".config", "glyphwire" });
}
