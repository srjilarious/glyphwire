const std = @import("std");
const testz = @import("testz");

// `gwssh`'s argument grammar is pure string math (see
// shell/remotecmd.zig), so it is exercised here without a shell, a host,
// or an `ssh`.
const remotecmd = @import("shell_support").remotecmd;

pub fn parseTakesABareDestTest(_: std.Io, _: std.mem.Allocator) !void {
    const spec = try remotecmd.parse(&.{"build-box"});
    try testz.expectEqualStr("build-box", spec.dest);
    try testz.expectEqual(spec.ssh_args.len, 0);
    try testz.expectTrue(spec.remote_command == null);
}

pub fn parseTakesAUserAtHostDestTest(_: std.Io, _: std.mem.Allocator) !void {
    const spec = try remotecmd.parse(&.{"jeff@10.0.0.4"});
    try testz.expectEqualStr("jeff@10.0.0.4", spec.dest);
}

pub fn parsePassesEverythingAfterDashDashToSshTest(_: std.Io, _: std.mem.Allocator) !void {
    const spec = try remotecmd.parse(&.{ "build-box", "--", "-p", "2222", "-o", "StrictHostKeyChecking=accept-new" });
    try testz.expectEqualStr("build-box", spec.dest);
    try testz.expectEqual(spec.ssh_args.len, 4);
    try testz.expectEqualStr("-p", spec.ssh_args[0]);
    try testz.expectEqualStr("2222", spec.ssh_args[1]);
    try testz.expectEqualStr("StrictHostKeyChecking=accept-new", spec.ssh_args[3]);
}

/// A `--` with nothing after it is not an error: it just means no extra
/// `ssh` arguments, which is what the user asked for.
pub fn parseAcceptsATrailingDashDashTest(_: std.Io, _: std.mem.Allocator) !void {
    const spec = try remotecmd.parse(&.{ "build-box", "--" });
    try testz.expectEqualStr("build-box", spec.dest);
    try testz.expectEqual(spec.ssh_args.len, 0);
}

pub fn parseTakesARemoteCommandTest(_: std.Io, _: std.mem.Allocator) !void {
    const spec = try remotecmd.parse(&.{ "--remote-command", "/opt/bin/gw-agent", "build-box" });
    try testz.expectEqualStr("build-box", spec.dest);
    try testz.expectEqualStr("/opt/bin/gw-agent", spec.remote_command.?);
}

/// The destination may come first: the options are ours, not `ssh`'s, so
/// there is no ordering rule to respect.
pub fn parseAllowsRemoteCommandAfterDestTest(_: std.Io, _: std.mem.Allocator) !void {
    const spec = try remotecmd.parse(&.{ "build-box", "--remote-command", "gw-agent2" });
    try testz.expectEqualStr("build-box", spec.dest);
    try testz.expectEqualStr("gw-agent2", spec.remote_command.?);
}

/// `--` stops option parsing, so an `ssh` option that happens to share a
/// name with one of ours is still `ssh`'s.
pub fn parseDoesNotClaimOptionsAfterDashDashTest(_: std.Io, _: std.mem.Allocator) !void {
    const spec = try remotecmd.parse(&.{ "build-box", "--", "--remote-command", "x" });
    try testz.expectTrue(spec.remote_command == null);
    try testz.expectEqual(spec.ssh_args.len, 2);
}

pub fn parseRejectsNoArgumentsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectError(remotecmd.parse(&.{}), error.MissingDest);
}

pub fn parseRejectsOnlySshArgsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectError(remotecmd.parse(&.{ "--", "-p", "22" }), error.MissingDest);
}

pub fn parseRejectsRemoteCommandWithNoValueTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectError(remotecmd.parse(&.{ "build-box", "--remote-command" }), error.MissingValue);
}

/// An `ssh` option typed before the `--` would otherwise be taken as the
/// destination and connect somewhere surprising.
pub fn parseRejectsStraySshOptionsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectError(remotecmd.parse(&.{ "-p", "2222", "build-box" }), error.UnknownOption);
}

pub fn parseRejectsTwoDestsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectError(remotecmd.parse(&.{ "build-box", "other-box" }), error.TooManyDests);
}

/// A lone `-` is a legal (if odd) hostname rather than an option, and more
/// importantly is not the `-x` shape the option check is guarding against.
pub fn parseTreatsALoneDashAsADestTest(_: std.Io, _: std.mem.Allocator) !void {
    const spec = try remotecmd.parse(&.{"-"});
    try testz.expectEqualStr("-", spec.dest);
}

pub fn errorTextIsNonEmptyForEveryErrorTest(_: std.Io, _: std.mem.Allocator) !void {
    inline for (.{ error.MissingDest, error.MissingValue, error.UnknownOption, error.TooManyDests }) |e| {
        try testz.expectTrue(remotecmd.errorText(e).len != 0);
    }
}
