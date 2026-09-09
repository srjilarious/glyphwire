const std = @import("std");
const testz = @import("testz");

const envassign = @import("shell_support").envassign;

// Builds a throwaway environment from `pairs` (`.{ .{ "K", "V" }, ... }`).
fn envOf(alloc: std.mem.Allocator, comptime pairs: anytype) !std.process.Environ.Map {
    var m = std.process.Environ.Map.init(alloc);
    inline for (pairs) |p| try m.put(p[0], p[1]);
    return m;
}

// ─── validName ─────────────────────────────────────────────────────────

pub fn validNameAcceptsIdentifiersTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(envassign.validName("FOO"));
    try testz.expectTrue(envassign.validName("_foo"));
    try testz.expectTrue(envassign.validName("Foo_Bar99"));
    try testz.expectTrue(envassign.validName("a"));
}

pub fn validNameRejectsNonIdentifiersTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectFalse(envassign.validName(""));
    try testz.expectFalse(envassign.validName("9foo"));
    try testz.expectFalse(envassign.validName("foo-bar"));
    try testz.expectFalse(envassign.validName("foo.bar"));
    try testz.expectFalse(envassign.validName("foo bar"));
    try testz.expectFalse(envassign.validName("FOO=BAR"));
}

// ─── expandValue ───────────────────────────────────────────────────────

pub fn expandValuePlainPassthroughTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const out = try envassign.expandValue(alloc, "just text", &env);
    defer alloc.free(out);
    try testz.expectEqualStr("just text", out);
}

pub fn expandValueDollarNameTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{ .{ "HOME", "/home/j" }, .{ "PATH", "/bin:/usr/bin" } });
    defer env.deinit();
    const out = try envassign.expandValue(alloc, "$PATH:/opt/bin", &env);
    defer alloc.free(out);
    try testz.expectEqualStr("/bin:/usr/bin:/opt/bin", out);
}

pub fn expandValueBracedNameTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{.{ "X", "abc" }});
    defer env.deinit();
    const out = try envassign.expandValue(alloc, "${X}def${X}", &env);
    defer alloc.free(out);
    try testz.expectEqualStr("abcdefabc", out);
}

pub fn expandValueUnsetNameIsEmptyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const out = try envassign.expandValue(alloc, "a${NOPE}b$ALSO_NOPE!", &env);
    defer alloc.free(out);
    try testz.expectEqualStr("ab!", out);
}

pub fn expandValueLiteralDollarTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    // `$` before a digit, a lone trailing `$`, and an unterminated `${`
    // are all copied through untouched.
    const out = try envassign.expandValue(alloc, "$1 costs 5$ ${oops", &env);
    defer alloc.free(out);
    try testz.expectEqualStr("$1 costs 5$ ${oops", out);
}

pub fn expandValueLeadingTildeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{.{ "HOME", "/home/j" }});
    defer env.deinit();

    const a = try envassign.expandValue(alloc, "~/bin", &env);
    defer alloc.free(a);
    try testz.expectEqualStr("/home/j/bin", a);

    const b = try envassign.expandValue(alloc, "~", &env);
    defer alloc.free(b);
    try testz.expectEqualStr("/home/j", b);

    // A `~` that isn't at the start, or isn't followed by `/`, is literal.
    const c = try envassign.expandValue(alloc, "x~/y", &env);
    defer alloc.free(c);
    try testz.expectEqualStr("x~/y", c);

    const d = try envassign.expandValue(alloc, "~user/x", &env);
    defer alloc.free(d);
    try testz.expectEqualStr("~user/x", d);
}

// ─── scanLeading ───────────────────────────────────────────────────────

pub fn scanLeadingNoAssignmentTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const r = try envassign.scanLeading(alloc, "ls -l /tmp", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 0), r.assignments.len);
    try testz.expectEqualStr("ls -l /tmp", r.rest);
}

pub fn scanLeadingBareRunSetsSessionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const r = try envassign.scanLeading(alloc, "FOO=bar", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 1), r.assignments.len);
    try testz.expectEqualStr("FOO", r.assignments[0].name);
    try testz.expectEqualStr("bar", r.assignments[0].value);
    try testz.expectEqualStr("", r.rest);
}

pub fn scanLeadingPrefixBeforeCommandTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const r = try envassign.scanLeading(alloc, "A=1  B=2   make -j4", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 2), r.assignments.len);
    try testz.expectEqualStr("A", r.assignments[0].name);
    try testz.expectEqualStr("1", r.assignments[0].value);
    try testz.expectEqualStr("B", r.assignments[1].name);
    try testz.expectEqualStr("2", r.assignments[1].value);
    try testz.expectEqualStr("make -j4", r.rest);
}

pub fn scanLeadingExpandsValueTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{ .{ "PATH", "/bin" }, .{ "HOME", "/h" } });
    defer env.deinit();
    const r = try envassign.scanLeading(alloc, "PATH=$PATH:/opt CFG=~/c prog", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 2), r.assignments.len);
    try testz.expectEqualStr("/bin:/opt", r.assignments[0].value);
    try testz.expectEqualStr("/h/c", r.assignments[1].value);
    try testz.expectEqualStr("prog", r.rest);
}

pub fn scanLeadingQuotedValueTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const r = try envassign.scanLeading(alloc, "MSG=\"a b c\" echo hi", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 1), r.assignments.len);
    try testz.expectEqualStr("a b c", r.assignments[0].value);
    try testz.expectEqualStr("echo hi", r.rest);
}

pub fn scanLeadingEmptyValueTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const r = try envassign.scanLeading(alloc, "EMPTY= cmd", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 1), r.assignments.len);
    try testz.expectEqualStr("EMPTY", r.assignments[0].name);
    try testz.expectEqualStr("", r.assignments[0].value);
    try testz.expectEqualStr("cmd", r.rest);
}

pub fn scanLeadingStopsAtInvalidNameTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    // `1FOO=x` is not a valid name -> nothing peeled, whole line is rest.
    const r = try envassign.scanLeading(alloc, "1FOO=x cmd", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 0), r.assignments.len);
    try testz.expectEqualStr("1FOO=x cmd", r.rest);
}

pub fn scanLeadingStopsAtFirstNonAssignmentTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    // The command word comes before a later `x=y`, which stays an argument.
    const r = try envassign.scanLeading(alloc, "A=1 run x=y", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 1), r.assignments.len);
    try testz.expectEqualStr("run x=y", r.rest);
}

pub fn scanLeadingAbandonsRunAtOperatorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    // An operator interrupting the assignment run -> the whole line goes
    // back to the parser untouched.
    for ([_][]const u8{ "A=1 | cat", "A=1; ls", "A=1 && b", "A=1>f" }) |line| {
        const r = try envassign.scanLeading(alloc, line, &env);
        defer envassign.freeLeading(alloc, r);
        try testz.expectEqual(@as(usize, 0), r.assignments.len);
        try testz.expectEqualStr(line, r.rest);
    }
}

pub fn scanLeadingLeadingBlanksTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const r = try envassign.scanLeading(alloc, "   FOO=bar cmd", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 1), r.assignments.len);
    try testz.expectEqualStr("cmd", r.rest);
}

pub fn scanLeadingBlankLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = try envOf(alloc, .{});
    defer env.deinit();
    const r = try envassign.scanLeading(alloc, "    ", &env);
    defer envassign.freeLeading(alloc, r);
    try testz.expectEqual(@as(usize, 0), r.assignments.len);
    try testz.expectEqualStr("", r.rest);
}
