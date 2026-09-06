const std = @import("std");
const glyphwire = @import("glyphwire");

/// glyphwire-probe: a small command-line client for driving and
/// inspecting a running glyphwire session by hand -- the thing that was
/// missing during the zoe editor work, where every debugging session
/// meant hand-rolling a fresh Python JSON-RPC framer in the scratchpad.
/// Built on `Client` directly (not a reimplementation of the wire
/// protocol) so it can't drift from what the real clients speak.
///
/// One subcommand per invocation, or a `script` file of them for a
/// reproducible sequence -- see `usage` below for the exact grammar. Both
/// paths go through `runLine`, so `glyphwire-probe key escape tap` and a
/// `key escape tap` line in a script file are the same code.
const usage =
    \\usage: glyphwire-probe <command> [args...]
    \\       glyphwire-probe script <file>
    \\
    \\commands:
    \\  cells <layer>                  dump a layer's grid as text rows
    \\  prop <layer> <name>            get_property, prints the raw response
    \\  text <str>                     report_text -- simulates typed input
    \\  key <name> [tap|down|up]       report_key -- simulates a named key (default: tap)
    \\  request <method> [json]        raw request, prints the raw response
    \\  notify <method> [json]         raw notify, no response expected
    \\  sleep <ms>                     pause -- mostly useful inside a script
    \\  script <file>                  run one of the above per line (# comments, blank lines ok)
    \\
    \\Needs GLYPHWIRE_SOCK set (run it from inside glyphwire-shell, or
    \\export the socket path a glyphwire-shell/-host printed).
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2 or eq(args[1], "-h") or eq(args[1], "--help")) return write(io, usage);

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        return fail(io, "glyphwire-probe: no session -- set GLYPHWIRE_SOCK\n");
    };
    defer client.deinit();

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (eq(args[1], "script")) {
        if (args.len < 3) return fail(io, "glyphwire-probe: script needs a file\n");
        return runScript(&client, alloc, io, out, args[2]);
    }

    // Everything else: rejoin argv[1..] into one line and hand it to the
    // same per-line runner a script file uses -- one JSON arg quoted as a
    // single shell word round-trips through this untouched.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    for (args[1..], 0..) |a, i| {
        if (i > 0) try line.append(alloc, ' ');
        try line.appendSlice(alloc, a);
    }
    try runLine(&client, alloc, io, out, line.items);
}

fn runScript(client: *glyphwire.Client, alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try runLine(client, alloc, io, out, line);
    }
}

/// Dispatches one already-assembled command line -- shared by the direct
/// CLI invocation (argv rejoined) and `script` (one file line each).
fn runLine(client: *glyphwire.Client, alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, line: []const u8) !void {
    const head = splitFirst(line);
    const cmd = head.word;
    const rest = head.rest;

    if (eq(cmd, "text")) {
        try client.reportText(rest);
    } else if (eq(cmd, "key")) {
        const k = splitFirst(rest);
        const mode = if (k.rest.len > 0) k.rest else "tap";
        if (eq(mode, "down")) {
            try client.reportKey(k.word, true);
        } else if (eq(mode, "up")) {
            try client.reportKey(k.word, false);
        } else {
            try client.reportKey(k.word, true);
            try client.reportKey(k.word, false);
        }
    } else if (eq(cmd, "cells")) {
        const layer = try std.fmt.parseInt(u32, std.mem.trim(u8, rest, " "), 10);
        try dumpCells(client, out, layer);
    } else if (eq(cmd, "prop")) {
        const p = splitFirst(rest);
        const layer = try std.fmt.parseInt(u32, p.word, 10);
        const name = std.mem.trim(u8, p.rest, " ");
        const params_json = try std.fmt.allocPrint(alloc, "{{\"layer\":{d},\"property\":\"{s}\"}}", .{ layer, name });
        defer alloc.free(params_json);
        try rawRequest(client, alloc, out, "get_property", params_json);
    } else if (eq(cmd, "request")) {
        const r = splitFirst(rest);
        try rawRequest(client, alloc, out, r.word, if (r.rest.len > 0) r.rest else "null");
    } else if (eq(cmd, "notify")) {
        const r = splitFirst(rest);
        try rawNotify(client, alloc, r.word, if (r.rest.len > 0) r.rest else "null");
    } else if (eq(cmd, "sleep")) {
        const ms = try std.fmt.parseInt(u32, std.mem.trim(u8, rest, " "), 10);
        try std.Io.sleep(io, .fromMilliseconds(ms), .awake);
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "glyphwire-probe: unknown command '{s}'\n", .{cmd}) catch "glyphwire-probe: unknown command\n";
        return fail(io, msg);
    }
}

fn dumpCells(client: *glyphwire.Client, out: *std.Io.Writer, layer: u32) !void {
    var snap = try client.getCellsOn(@intCast(layer));
    defer snap.deinit();
    var row: usize = 0;
    while (row < snap.rows()) : (row += 1) {
        var col: usize = 0;
        while (col < snap.cols()) : (col += 1) {
            const g = snap.cellAt(row, col).grapheme;
            try out.writeAll(if (g.len == 0) " " else g);
        }
        try out.writeAll("\n");
    }
}

/// Splices `params_json` straight into the envelope rather than parsing
/// and re-stringifying it -- it's already valid JSON from the caller, and
/// this way `glyphwire-probe` never has its own opinion about the shape
/// of any given method's params, present or future.
fn rawRequest(client: *glyphwire.Client, alloc: std.mem.Allocator, out: *std.Io.Writer, method: []const u8, params_json: []const u8) !void {
    if (std.mem.indexOfScalar(u8, method, '"') != null) return error.BadMethodName;
    const id = client.next_id;
    client.next_id += 1;
    const body = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json });
    defer alloc.free(body);
    try frameAndFlush(client, body);

    const resp = try readOneFrame(client);
    defer alloc.free(resp);
    try out.writeAll(resp);
    try out.writeAll("\n");
}

fn rawNotify(client: *glyphwire.Client, alloc: std.mem.Allocator, method: []const u8, params_json: []const u8) !void {
    if (std.mem.indexOfScalar(u8, method, '"') != null) return error.BadMethodName;
    const body = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
    defer alloc.free(body);
    try frameAndFlush(client, body);
}

fn frameAndFlush(client: *glyphwire.Client, body: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var w = client.stream.writer(client.io, &write_buf);
    try glyphwire.wire.writeFrame(&w.interface, body);
    try w.interface.flush();
}

fn readOneFrame(client: *glyphwire.Client) ![]u8 {
    while (true) {
        if (try client.decoder.next(client.alloc)) |body| return body;
        var read_buf: [4096]u8 = undefined;
        var data: [1][]u8 = .{&read_buf};
        const n = try client.stream.read(client.io, &data);
        if (n == 0) return error.ConnectionClosed;
        try client.decoder.feed(client.alloc, read_buf[0..n]);
    }
}

const SplitResult = struct { word: []const u8, rest: []const u8 };

fn splitFirst(s: []const u8) SplitResult {
    const trimmed = std.mem.trimStart(u8, s, " \t");
    const sp = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return .{ .word = trimmed, .rest = "" };
    return .{ .word = trimmed[0..sp], .rest = trimmed[sp + 1 ..] };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn write(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn fail(io: std.Io, msg: []const u8) !void {
    try write(io, msg);
    return error.InvalidArguments;
}
