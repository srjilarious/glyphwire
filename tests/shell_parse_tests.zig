const std = @import("std");
const testz = @import("testz");

const parse = @import("shell_support").parse;

// Parses `line`, failing the test if the parser reported a syntax error.
// Caller must `line.deinit()`.
fn ok(alloc: std.mem.Allocator, line: []const u8) !parse.Line {
    switch (try parse.parse(alloc, line)) {
        .ok => |l| return l,
        .err => |msg| {
            defer alloc.free(msg);
            std.debug.print("unexpected parse error: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
    }
}

// Parses `line`, expecting a syntax error, and returns its message
// (caller frees).
fn expectErr(alloc: std.mem.Allocator, line: []const u8) ![]const u8 {
    switch (try parse.parse(alloc, line)) {
        .ok => |l| {
            var m = l;
            m.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |msg| return msg,
    }
}

// ─── pipelines ─────────────────────────────────────────────────────────

pub fn parsePlainPipelineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "ps aux | grep glyphwire");
    defer line.deinit();

    try testz.expectEqual(line.segments.len, 1);
    try testz.expectEqual(line.segments[0].sep, .first);
    const cmds = line.segments[0].pipeline.commands;
    try testz.expectEqual(cmds.len, 2);
    try testz.expectEqualStr("ps", cmds[0].words[0]);
    try testz.expectEqualStr("aux", cmds[0].words[1]);
    try testz.expectEqualStr("grep", cmds[1].words[0]);
    try testz.expectEqualStr("glyphwire", cmds[1].words[1]);
    try testz.expectFalse(line.isBareCommand());
}

pub fn parsePipelineWithoutSpacesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "ps aux|grep x|wc -l");
    defer line.deinit();
    const cmds = line.segments[0].pipeline.commands;
    try testz.expectEqual(cmds.len, 3);
    try testz.expectEqualStr("grep", cmds[1].words[0]);
    try testz.expectEqualStr("wc", cmds[2].words[0]);
}

pub fn parseBareCommandIsFlaggedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "ls -l -a");
    defer line.deinit();
    try testz.expectTrue(line.isBareCommand());
}

pub fn parseEmptyLineYieldsNoSegmentsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "    ");
    defer line.deinit();
    try testz.expectEqual(line.segments.len, 0);
}

// ─── && / || / ; ──────────────────────────────────────────────────────

pub fn parseAndOrChainTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "make && ./run || echo failed");
    defer line.deinit();
    try testz.expectEqual(line.segments.len, 3);
    try testz.expectEqual(line.segments[0].sep, .first);
    try testz.expectEqual(line.segments[1].sep, .and_then);
    try testz.expectEqual(line.segments[2].sep, .or_else);
    try testz.expectEqualStr("make", line.segments[0].pipeline.commands[0].words[0]);
    try testz.expectEqualStr("failed", line.segments[2].pipeline.commands[0].words[1]);
}

pub fn parseSemicolonSequenceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "cd /tmp ; ls ; pwd");
    defer line.deinit();
    try testz.expectEqual(line.segments.len, 3);
    try testz.expectEqual(line.segments[1].sep, .semi);
    try testz.expectEqual(line.segments[2].sep, .semi);
}

pub fn parseTrailingSemicolonIsAllowedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "ls ;");
    defer line.deinit();
    try testz.expectEqual(line.segments.len, 1);
    try testz.expectEqualStr("ls", line.segments[0].pipeline.commands[0].words[0]);
}

pub fn parseAndOrBindsInsidePipelineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "a | b && c | d");
    defer line.deinit();
    try testz.expectEqual(line.segments.len, 2);
    try testz.expectEqual(line.segments[0].pipeline.commands.len, 2);
    try testz.expectEqual(line.segments[1].sep, .and_then);
    try testz.expectEqual(line.segments[1].pipeline.commands.len, 2);
}

// ─── redirects ────────────────────────────────────────────────────────

pub fn parseStdoutTruncateRedirectTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "echo hi > out.txt");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.words.len, 2);
    try testz.expectEqual(cmd.redirs.len, 1);
    try testz.expectEqual(cmd.redirs[0].fd, 1);
    try testz.expectEqual(cmd.redirs[0].mode, .write);
    try testz.expectEqualStr("out.txt", cmd.redirs[0].path);
    try testz.expectFalse(line.isBareCommand());
}

pub fn parseStdoutAppendAndNoSpaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "echo hi>>log");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.words.len, 2);
    try testz.expectEqual(cmd.redirs[0].mode, .append);
    try testz.expectEqualStr("log", cmd.redirs[0].path);
}

pub fn parseStdinRedirectTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "sort < names.txt");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.redirs[0].fd, 0);
    try testz.expectEqual(cmd.redirs[0].mode, .read);
    try testz.expectEqualStr("names.txt", cmd.redirs[0].path);
}

pub fn parseStderrRedirectWithFdDesignatorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "cc main.c 2> errors.log");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.words.len, 2);
    try testz.expectEqual(cmd.redirs[0].fd, 2);
    try testz.expectEqual(cmd.redirs[0].mode, .write);
    try testz.expectEqualStr("errors.log", cmd.redirs[0].path);
}

pub fn parseDigitArgIsNotAnFdDesignatorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A space between the digit and `>` means the digit is a real arg.
    var line = try ok(alloc, "echo 2 > out");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.words.len, 2);
    try testz.expectEqualStr("2", cmd.words[1]);
    try testz.expectEqual(cmd.redirs[0].fd, 1);
}

pub fn parseDupRedirectTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "cmd 2>&1");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.redirs.len, 1);
    try testz.expectEqual(cmd.redirs[0].fd, 2);
    try testz.expectEqual(cmd.redirs[0].mode, .dup);
    try testz.expectEqual(cmd.redirs[0].dup_fd, 1);
}

pub fn parseBothStreamsRedirectTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "make &> build.log");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.redirs.len, 1);
    try testz.expectEqual(cmd.redirs[0].fd, 1);
    try testz.expectEqual(cmd.redirs[0].mode, .write);
    try testz.expectTrue(cmd.redirs[0].also_stderr);
    try testz.expectEqualStr("build.log", cmd.redirs[0].path);
}

pub fn parseRedirectThenPipeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "cc main.c 2>&1 | less");
    defer line.deinit();
    const cmds = line.segments[0].pipeline.commands;
    try testz.expectEqual(cmds.len, 2);
    try testz.expectEqual(cmds[0].redirs[0].mode, .dup);
    try testz.expectEqualStr("less", cmds[1].words[0]);
}

pub fn parseMultipleRedirectsKeepOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "cmd > out 2>&1");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.redirs.len, 2);
    try testz.expectEqual(cmd.redirs[0].mode, .write);
    try testz.expectEqualStr("out", cmd.redirs[0].path);
    try testz.expectEqual(cmd.redirs[1].mode, .dup);
}

// ─── quoting keeps operators literal ──────────────────────────────────

pub fn parseQuotedPipeIsLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "echo 'a | b'");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(line.segments[0].pipeline.commands.len, 1);
    try testz.expectEqual(cmd.words.len, 2);
    try testz.expectEqualStr("a | b", cmd.words[1]);
    try testz.expectTrue(cmd.quoted[1]);
}

pub fn parseEscapedRedirectIsLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "echo a\\>b");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqual(cmd.redirs.len, 0);
    try testz.expectEqualStr("a>b", cmd.words[1]);
}

pub fn parseQuotedTargetIsMarkedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var line = try ok(alloc, "echo hi > \"my file.txt\"");
    defer line.deinit();
    const cmd = line.segments[0].pipeline.commands[0];
    try testz.expectEqualStr("my file.txt", cmd.redirs[0].path);
    try testz.expectTrue(cmd.redirs[0].path_quoted);
}

// ─── errors ──────────────────────────────────────────────────────────

pub fn parseBackgroundIsRejectedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const msg = try expectErr(alloc, "sleep 10 &");
    defer alloc.free(msg);
    try testz.expectTrue(std.mem.indexOf(u8, msg, "background") != null);
}

pub fn parseHeredocIsRejectedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const msg = try expectErr(alloc, "cat << EOF");
    defer alloc.free(msg);
    try testz.expectTrue(std.mem.indexOf(u8, msg, "heredoc") != null);
}

pub fn parseEmptyStageIsRejectedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const msg = try expectErr(alloc, "ls |");
    defer alloc.free(msg);
    try testz.expectTrue(std.mem.indexOf(u8, msg, "syntax error") != null);
}

pub fn parseLeadingPipeIsRejectedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const msg = try expectErr(alloc, "| grep x");
    defer alloc.free(msg);
    try testz.expectTrue(std.mem.indexOf(u8, msg, "syntax error") != null);
}

pub fn parseDanglingAndIsRejectedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const msg = try expectErr(alloc, "make &&");
    defer alloc.free(msg);
    try testz.expectTrue(std.mem.indexOf(u8, msg, "&&") != null);
}

pub fn parseRedirectWithoutTargetIsRejectedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const msg = try expectErr(alloc, "echo hi >");
    defer alloc.free(msg);
    try testz.expectTrue(std.mem.indexOf(u8, msg, "target") != null);
}

pub fn parseRedirectWithoutCommandIsRejectedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const msg = try expectErr(alloc, "> out.txt");
    defer alloc.free(msg);
    try testz.expectTrue(std.mem.indexOf(u8, msg, "no command") != null);
}
