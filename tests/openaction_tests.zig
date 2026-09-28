// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");

const openaction = @import("shell_support").openaction;
const Entry = openaction.Entry;
const Action = openaction.Action;

fn expectCommand(action: ?Action, expected: []const u8) !void {
    try testz.expectTrue(action != null);
    try testz.expectEqualStr(action.?.commands[0], expected);
}

// ─── resolve: built-in defaults ────────────────────────────────────────

pub fn resolveDefaultDirectoryTest(_: std.Io, _: std.mem.Allocator) !void {
    const a = openaction.resolve(&.{}, .{ .kind = "directory", .path = "/x" });
    try expectCommand(a, "cd {sel}");
}

pub fn resolveDefaultImagePngTest(_: std.Io, _: std.mem.Allocator) !void {
    const a = openaction.resolve(&.{}, .{ .kind = "file", .path = "/p.png", .mimetype = "image/png" });
    try expectCommand(a, "gw-view {selections}");
}

pub fn resolveUnknownFileYieldsNothingTest(_: std.Io, _: std.mem.Allocator) !void {
    const a = openaction.resolve(&.{}, .{ .kind = "file", .path = "/p.xyz", .mimetype = "application/octet-stream" });
    try testz.expectTrue(a == null);
}

pub fn resolveSymlinkYieldsNothingByDefaultTest(_: std.Io, _: std.mem.Allocator) !void {
    const a = openaction.resolve(&.{}, .{ .kind = "symlink", .path = "/l" });
    try testz.expectTrue(a == null);
}

// ─── resolve: user table over defaults ─────────────────────────────────

pub fn resolveUserEntryOverridesDefaultKeyTest(_: std.Io, _: std.mem.Allocator) !void {
    const user = [_]Action{.{ .key = "directory", .commands = &.{"ranger {sel}"} }};
    const a = openaction.resolve(&user, .{ .kind = "directory", .path = "/x" });
    try expectCommand(a, "ranger {sel}");
}

pub fn resolveMatchIsSpecificityFirstThenUserOverDefaultTest(_: std.Io, _: std.mem.Allocator) !void {
    // A user "image/*" covers image types with no more-specific rule
    // (webp has no built-in exact), but the built-in exact "image/png"
    // still wins for a png -- exact beats group, source is the tie-break
    // within a tier.
    const user = [_]Action{.{ .key = "image/*", .commands = &.{"feh {selections}"} }};

    const webp = openaction.resolve(&user, .{ .kind = "file", .path = "/p.webp", .mimetype = "image/webp" });
    try expectCommand(webp, "feh {selections}");

    const png = openaction.resolve(&user, .{ .kind = "file", .path = "/p.png", .mimetype = "image/png" });
    try expectCommand(png, "gw-view {selections}");
}

pub fn resolveExactBeatsGroupWithinUserTableTest(_: std.Io, _: std.mem.Allocator) !void {
    const user = [_]Action{
        .{ .key = "image/*", .commands = &.{"group"} },
        .{ .key = "image/png", .commands = &.{"exact"} },
    };
    const a = openaction.resolve(&user, .{ .kind = "file", .path = "/p.png", .mimetype = "image/png" });
    try expectCommand(a, "exact");
}

pub fn resolveLastMatchingUserEntryWinsTest(_: std.Io, _: std.mem.Allocator) !void {
    const user = [_]Action{
        .{ .key = "image/png", .commands = &.{"first"} },
        .{ .key = "image/png", .commands = &.{"second"} },
    };
    const a = openaction.resolve(&user, .{ .kind = "file", .path = "/p.png", .mimetype = "image/png" });
    try expectCommand(a, "second");
}

pub fn resolveFallsBackToKindKeyTest(_: std.Io, _: std.mem.Allocator) !void {
    // No exact / group match for application/pdf, so the "file" kind key wins.
    const user = [_]Action{.{ .key = "file", .commands = &.{"$EDITOR {sel}"} }};
    const a = openaction.resolve(&user, .{ .kind = "file", .path = "/n.pdf", .mimetype = "application/pdf" });
    try expectCommand(a, "$EDITOR {sel}");
}

pub fn resolveDefaultTextOpensZoeAtLineTest(_: std.Io, _: std.mem.Allocator) !void {
    const a = openaction.resolve(&.{}, .{ .kind = "file", .path = "/n.txt", .mimetype = "text/plain" });
    try expectCommand(a, "zoe +{line} {sel}");
}

pub fn resolveDefaultTextBeatsUserKindKeyTest(_: std.Io, _: std.mem.Allocator) !void {
    // A group match outranks a kind match, even a user one -- the same
    // rule that lets the built-in image/png beat a user image/*.
    const user = [_]Action{.{ .key = "file", .commands = &.{"xdg-open {sel}"} }};
    const a = openaction.resolve(&user, .{ .kind = "file", .path = "/n.txt", .mimetype = "text/plain" });
    try expectCommand(a, "zoe +{line} {sel}");
}

pub fn resolveGroupDoesNotMatchAcrossSlashTest(_: std.Io, _: std.mem.Allocator) !void {
    // "image/*" must not match "imagex/thing" -- the compare keeps the slash.
    const user = [_]Action{.{ .key = "image/*", .commands = &.{"feh"} }};
    const a = openaction.resolve(&user, .{ .kind = "file", .path = "/x", .mimetype = "imagex/thing" });
    try testz.expectTrue(a == null);
}

// ─── expand ───────────────────────────────────────────────────────────

pub fn expandSelQuotesSinglePathTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try openaction.expand(alloc, "cd {sel}", &.{"/tmp/my dir"}, null);
    defer alloc.free(out);
    try testz.expectEqualStr(out, "cd '/tmp/my dir'");
}

pub fn expandSelectionsJoinsQuotedPathsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try openaction.expand(alloc, "gw-view {selections}", &.{ "/a.png", "/b c.png" }, null);
    defer alloc.free(out);
    try testz.expectEqualStr(out, "gw-view '/a.png' '/b c.png'");
}

pub fn expandSelectionsAcceptsASinglePathTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try openaction.expand(alloc, "v {selections}", &.{"/only"}, null);
    defer alloc.free(out);
    try testz.expectEqualStr(out, "v '/only'");
}

pub fn expandSelWithMultipleIsAnErrorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try testz.expectError(openaction.expand(alloc, "cd {sel}", &.{ "/a", "/b" }, null), error.NeedsSingle);
}

pub fn expandTemplateWithoutTokensIsCopiedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try openaction.expand(alloc, "sync-now", &.{ "/a", "/b" }, null);
    defer alloc.free(out);
    try testz.expectEqualStr(out, "sync-now");
}

pub fn expandLineFillsLineNumberTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try openaction.expand(alloc, "zoe +{line} {sel}", &.{"/src/a b.zig"}, 42);
    defer alloc.free(out);
    try testz.expectEqualStr(out, "zoe +42 '/src/a b.zig'");
}

pub fn expandLineDefaultsToOneTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try openaction.expand(alloc, "code -g {sel}:{line}", &.{"/n.txt"}, null);
    defer alloc.free(out);
    try testz.expectEqualStr(out, "code -g '/n.txt':1");
}

pub fn expandQuotesEmbeddedApostropheTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try openaction.expand(alloc, "cd {sel}", &.{"/it's here"}, null);
    defer alloc.free(out);
    try testz.expectEqualStr(out, "cd '/it'\\''s here'");
}
