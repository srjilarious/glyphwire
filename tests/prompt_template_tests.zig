const std = @import("std");
const testz = @import("testz");

// The prompt template engine is pure, so it lives in `shell_support` (see
// build.zig) and is exercised here directly -- no running shell, no Lua.
const pt = @import("shell_support").prompt_template;

// ─── helpers ──────────────────────────────────────────────────────────

/// Renders `template` against `data` and flattens the op list to a string:
/// text runs verbatim, an icon op as `[icon:NAME]`. Owned by `alloc`.
fn flatten(alloc: std.mem.Allocator, template: []const u8, data: pt.Data) ![]u8 {
    var r = try pt.render(alloc, template, data);
    defer r.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (r.ops) |op| switch (op) {
        .text => |t| try out.appendSlice(alloc, t),
        .icon => |name| {
            try out.appendSlice(alloc, "[icon:");
            try out.appendSlice(alloc, name);
            try out.append(alloc, ']');
        },
    };
    return out.toOwnedSlice(alloc);
}

// ─── literals & escapes ──────────────────────────────────────────────

pub fn literalTextPassesThroughTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "hello > ", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("hello > ", s);
}

pub fn backslashEscapesAreUnescapedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a\\nb\\tc\\\\d", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("a\nb\tc\\d", s);
}

pub fn unknownBackslashKeepsBothBytesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a\\qb", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("a\\qb", s);
}

pub fn doubledBracesAreLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "{{cwd}}", .{ .cwd = "/x" });
    defer alloc.free(s);
    try testz.expectEqualStr("{cwd}", s);
}

pub fn unterminatedBraceIsLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a { b", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("a { b", s);
}

pub fn unknownTokenIsLeftVerbatimTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "x {bogus} y", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("x {bogus} y", s);
}

// ─── field substitution ──────────────────────────────────────────────

pub fn fieldsSubstituteTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "{user}@{host}:{cwd}$ ", .{
        .user = "jeff",
        .host = "box",
        .cwd = "~/code",
        .cwd_full = "/home/jeff/code",
    });
    defer alloc.free(s);
    try testz.expectEqualStr("jeff@box:~/code$ ", s);
}

pub fn cwdFullIsAbsoluteTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "{cwd_full}", .{ .cwd = "~/code", .cwd_full = "/home/jeff/code" });
    defer alloc.free(s);
    try testz.expectEqualStr("/home/jeff/code", s);
}

pub fn missingFieldRendersEmptyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "[{host}]", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("[]", s);
}

pub fn adjacentTextIsOneOpTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = try pt.render(alloc, "{user} {cwd} ", .{ .user = "a", .cwd = "b" });
    defer r.deinit();
    try testz.expectEqual(r.ops.len, 1);
    try testz.expectEqualStr("a b ", r.ops[0].text);
}

// ─── icons ────────────────────────────────────────────────────────────

pub fn iconBecomesItsOwnOpTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = try pt.render(alloc, "{icon:distro/arch} {cwd}", .{ .cwd = "~" });
    defer r.deinit();
    try testz.expectEqual(r.ops.len, 2);
    try testz.expectEqualStr("distro/arch", r.ops[0].icon);
    try testz.expectEqualStr(" ~", r.ops[1].text);
}

pub fn iconWithEmptyNameIsLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "{icon:}", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("{icon:}", s);
}

// ─── {exit} / {exit_code} ────────────────────────────────────────────

pub fn exitIsEmptyOnSuccessTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a{exit}b", .{
        .have_status = true,
        .last_status = 0,
        .exit_section = " [{exit_code}]",
    });
    defer alloc.free(s);
    try testz.expectEqualStr("ab", s);
}

pub fn exitIsEmptyBeforeAnyCommandTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a{exit}b", .{
        .have_status = false,
        .last_status = 3,
        .exit_section = " [{exit_code}]",
    });
    defer alloc.free(s);
    try testz.expectEqualStr("ab", s);
}

pub fn exitRendersSectionOnNonZeroTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a{exit}b", .{
        .have_status = true,
        .last_status = 2,
        .exit_section = " [{exit_code}]",
    });
    defer alloc.free(s);
    try testz.expectEqualStr("a [2]b", s);
}

pub fn exitSectionCanCarryAnIconTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = try pt.render(alloc, "{exit}", .{
        .have_status = true,
        .last_status = 1,
        .exit_section = "{icon:distro/arch} {exit_code}",
    });
    defer r.deinit();
    try testz.expectEqual(r.ops.len, 2);
    try testz.expectEqualStr("distro/arch", r.ops[0].icon);
    try testz.expectEqualStr(" 1", r.ops[1].text);
}

pub fn exitWithNoSectionIsEmptyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a{exit}b", .{ .have_status = true, .last_status = 5 });
    defer alloc.free(s);
    try testz.expectEqualStr("ab", s);
}

pub fn exitSectionSelfReferenceDoesNotLoopTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // The section references its own trigger token -- the depth guard has
    // to stop this rather than recurse forever.
    const s = try flatten(alloc, "{exit}", .{
        .have_status = true,
        .last_status = 1,
        .exit_section = "x{exit}",
    });
    defer alloc.free(s);
    // Bounded expansion: a few "x" then it stops.
    try testz.expectTrue(s.len >= 1 and s.len <= 8);
    for (s) |ch| try testz.expectEqual(ch, 'x');
}

pub fn exitCodeTokenWorksOutsideSectionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "code {exit_code}", .{ .last_status = 7 });
    defer alloc.free(s);
    try testz.expectEqualStr("code 7", s);
}

// ─── {dur} / {duration} ──────────────────────────────────────────────

pub fn durIsEmptyBelowThresholdTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a{dur}b", .{
        .last_dur_ms = 500,
        .dur_min_ms = 2000,
        .dur_section = " {duration}",
    });
    defer alloc.free(s);
    try testz.expectEqualStr("ab", s);
}

pub fn durRendersSectionAtOrAboveThresholdTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a{dur}b", .{
        .last_dur_ms = 2500,
        .dur_min_ms = 2000,
        .dur_section = " took {duration}",
    });
    defer alloc.free(s);
    try testz.expectEqualStr("a took 2.5sb", s);
}

pub fn durMinZeroNeverShowsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a{dur}b", .{
        .last_dur_ms = 10_000,
        .dur_min_ms = 0,
        .dur_section = " {duration}",
    });
    defer alloc.free(s);
    try testz.expectEqualStr("ab", s);
}

pub fn durWithNoSectionIsEmptyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "a{dur}b", .{ .last_dur_ms = 9999, .dur_min_ms = 1000 });
    defer alloc.free(s);
    try testz.expectEqualStr("ab", s);
}

// ─── formatDuration ──────────────────────────────────────────────────

pub fn formatDurationCoversEachRangeTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [24]u8 = undefined;
    try testz.expectEqualStr("0ms", pt.formatDuration(&buf, 0));
    try testz.expectEqualStr("999ms", pt.formatDuration(&buf, 999));
    try testz.expectEqualStr("1.0s", pt.formatDuration(&buf, 1000));
    try testz.expectEqualStr("1.5s", pt.formatDuration(&buf, 1500));
    try testz.expectEqualStr("59.9s", pt.formatDuration(&buf, 59_900));
    try testz.expectEqualStr("1m0s", pt.formatDuration(&buf, 60_000));
    try testz.expectEqualStr("2m5s", pt.formatDuration(&buf, 125_000));
    try testz.expectEqualStr("1h0m", pt.formatDuration(&buf, 3_600_000));
    try testz.expectEqualStr("1h1m", pt.formatDuration(&buf, 3_660_000));
}

// ─── opsWidth ────────────────────────────────────────────────────────

pub fn opsWidthCountsTextAndIconsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = try pt.render(alloc, "ab{icon:x}cd", .{});
    defer r.deinit();
    try testz.expectEqual(pt.opsWidth(r.ops, 1), 5);
    // A wider (natural-sized) icon reserves more columns.
    try testz.expectEqual(pt.opsWidth(r.ops, 3), 7);
}

pub fn opsWidthCountsOnlyTheFinalLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = try pt.render(alloc, "abc\\ncd{icon:x}", .{});
    defer r.deinit();
    try testz.expectEqual(pt.opsWidth(r.ops, 1), 3);
}

pub fn opsWidthCountsUtf8CodepointsNotBytesTest(_: std.Io, _: std.mem.Allocator) !void {
    // "é" is two UTF-8 bytes, one column here.
    const ops = [_]pt.Op{.{ .text = "é!" }};
    try testz.expectEqual(pt.opsWidth(&ops, 1), 2);
}

// ─── {time} / {env:VAR} ──────────────────────────────────────────────

pub fn timeTokenInterpolatesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "[{time}]", .{ .time = "17:05" });
    defer alloc.free(s);
    try testz.expectEqualStr("[17:05]", s);
}

pub fn envTokenReadsTheMapTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var m = std.process.Environ.Map.init(alloc);
    defer m.deinit();
    try m.put("KUBE_CTX", "prod");

    const s = try flatten(alloc, "ctx={env:KUBE_CTX} end", .{ .environ = &m });
    defer alloc.free(s);
    try testz.expectEqualStr("ctx=prod end", s);
}

pub fn envTokenMissingKeyRendersEmptyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var m = std.process.Environ.Map.init(alloc);
    defer m.deinit();

    const s = try flatten(alloc, "[{env:NOPE}]", .{ .environ = &m });
    defer alloc.free(s);
    try testz.expectEqualStr("[]", s);
}

pub fn envTokenWithNoMapRendersEmptyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "[{env:PATH}]", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("[]", s);
}

pub fn envTokenEmptyNameIsLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const s = try flatten(alloc, "{env:}", .{});
    defer alloc.free(s);
    try testz.expectEqualStr("{env:}", s);
}

// ─── parseColor ──────────────────────────────────────────────────────

pub fn parseColorHandlesShortAndLongHexTest(_: std.Io, _: std.mem.Allocator) !void {
    const white = pt.parseColor("#fff").?;
    try testz.expectEqual(white.r, 255);
    try testz.expectEqual(white.g, 255);
    try testz.expectEqual(white.b, 255);

    const c = pt.parseColor("#1e88e5").?;
    try testz.expectEqual(c.r, 30);
    try testz.expectEqual(c.g, 136);
    try testz.expectEqual(c.b, 229);

    // `#` is optional.
    const nohash = pt.parseColor("000000").?;
    try testz.expectEqual(nohash.r, 0);
}

pub fn parseColorRejectsMalformedTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(pt.parseColor(""), null);
    try testz.expectEqual(pt.parseColor("#12"), null);
    try testz.expectEqual(pt.parseColor("#12345"), null);
    try testz.expectEqual(pt.parseColor("#gggggg"), null);
}
