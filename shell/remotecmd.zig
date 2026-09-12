//! Pure argument parsing for glyphwire-shell's `gwssh` builtin -- the
//! command that drops the pane it is typed in into a remote session (see
//! `dispatch.RemoteStarter` and `host/remote.zig`).
//!
//! The grammar deliberately mirrors `glyphwire --ssh`, so the two ways into
//! a remote session read the same:
//!
//!     gwssh [--remote-command <cmd>] <dest> [-- <ssh args>...]
//!
//! `dest` is anything `ssh` accepts (`user@host`, a `~/.ssh/config` alias).
//! `--remote-command` overrides the far-side agent for one connection;
//! `$GLYPHWIRE_REMOTE_COMMAND` is the standing form of the same thing, for
//! a box -- or a work tree -- whose `gw-agent` is not on the minimal
//! `PATH` a non-login `ssh -T` session gets.
//!
//! Everything after `--` is handed to `ssh` verbatim, which is why no
//! attempt is made to understand `ssh`'s own options: they are `ssh`'s
//! business, and guessing which of them take a value is how a parser like
//! this goes wrong.
//!
//! No IO and no glyphwire import -- string math, unit-tested in
//! `tests/shell_remote_tests.zig`.

const std = @import("std");

pub const Spec = struct {
    dest: []const u8,
    /// Arguments inserted before `dest` on the `ssh` command line. Borrowed
    /// from the caller's `args`.
    ssh_args: []const []const u8 = &.{},
    /// The agent command run on the far side; null means the host's
    /// default (`gw-agent`).
    remote_command: ?[]const u8 = null,
};

pub const ParseError = error{
    /// No destination before the `--`, or no arguments at all.
    MissingDest,
    /// `--remote-command` with nothing after it.
    MissingValue,
    /// A leading `-...` that isn't one of ours. Rejected rather than
    /// passed through: `ssh` options belong after `--`, and silently
    /// treating `-p` as a destination would connect somewhere surprising.
    UnknownOption,
    /// More than one bare word before the `--`.
    TooManyDests,
};

pub fn parse(args: []const []const u8) ParseError!Spec {
    var spec: Spec = .{ .dest = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            spec.ssh_args = args[i + 1 ..];
            break;
        }
        if (std.mem.eql(u8, a, "--remote-command")) {
            if (i + 1 >= args.len) return error.MissingValue;
            i += 1;
            spec.remote_command = args[i];
            continue;
        }
        if (a.len > 1 and a[0] == '-') return error.UnknownOption;
        if (spec.dest.len != 0) return error.TooManyDests;
        spec.dest = a;
    }
    if (spec.dest.len == 0) return error.MissingDest;
    return spec;
}

/// A one-line message for `err`, for the shell to put on the grid.
pub fn errorText(err: ParseError) []const u8 {
    return switch (err) {
        error.MissingDest => "gwssh: usage: gwssh [--remote-command <cmd>] <dest> [-- <ssh args>...]",
        error.MissingValue => "gwssh: --remote-command needs a command",
        error.UnknownOption => "gwssh: unknown option (ssh's own options go after `--`)",
        error.TooManyDests => "gwssh: only one destination (ssh's own options go after `--`)",
    };
}
