// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! What a program says it is: `--version` on the command line, and the
//! host's answer to `get_version` on the wire.
//!
//! The values come from the `build_info` module build.zig gives each
//! program (`addBuildInfo`): its executable name, its own version from
//! `program_versions`, the suite version from build.zig.zon, and `git
//! describe` of the tree it was built from. They live in each program,
//! not here, because each program's are different; this module only
//! formats them, so every program's `--version` reads the same.

const std = @import("std");

/// A program's identity: `build_info` as a value, so the server can hold
/// the host's (`core.Session.host_info`) without knowing its type.
pub const Info = struct {
    program: []const u8 = "",
    version: []const u8 = "",
    suite_version: []const u8 = "",
    git: []const u8 = "",

    /// `info` is a `build_info` module.
    pub fn of(comptime info: type) Info {
        return .{ .program = info.program, .version = info.version, .suite_version = info.suite_version, .git = info.git };
    }

    /// `zoe 0.8.0 (glyphwire 0.8.0, 1e34abf)`. Borrows `buf`.
    pub fn line(self: Info, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s} {s} (glyphwire {s}, {s})", .{ self.program, self.version, self.suite_version, self.git }) catch self.version;
    }
};

/// Whether `arg` asks for the version: `--version` or `-V`. Programs that
/// hand-roll their arguments test their first one with this; the
/// zargunaught ones declare the same pair as an option.
pub fn isFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
}

/// Prints `info`'s `line` to stdout and exits 0: the whole of `--version`.
pub fn printAndExit(io: std.Io, info: Info) noreturn {
    var line_buf: [256]u8 = undefined;
    var buf: [300]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print("{s}\n", .{info.line(&line_buf)}) catch {};
    w.interface.flush() catch {};
    std.process.exit(0);
}
