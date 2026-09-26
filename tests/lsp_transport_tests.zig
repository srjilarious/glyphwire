// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The LSP transport driven against bytes: no process, no window, no
//! installed language server. `lsp.Server.feedBytes` is the seam (see its
//! doc comment), and `lsp.Waker` is what stands in for the display server.
//!
//! The reply bodies below are the real ones `zls` 0.17.0-dev sends, trimmed
//! to the fields the editor reads -- including the `window/logMessage`
//! notifications it sends *before* the `initialize` response, which is
//! exactly the case a client that assumes the first frame is its answer gets
//! wrong.

const std = @import("std");
const testz = @import("testz");
const zoe = @import("zoe_support");
const lsp = zoe.lsp;

/// Counts wakes, so a test can assert the editor would have been poked.
const Counter = struct {
    hits: usize = 0,

    fn bump(ctx: ?*anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        self.hits += 1;
    }

    fn waker(self: *Counter) lsp.Waker {
        return .{ .ctx = self, .func = &bump };
    }
};

/// One framed message, as it would arrive off a server's stdout.
fn frame(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

pub fn onPathFindsRealBinariesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("PATH", "/nonexistent-dir:/usr/bin");
    try testz.expectTrue(lsp.onPath(io, "sh", &env));
    try testz.expectFalse(lsp.onPath(io, "definitely-not-here-at-all", &env));
    // A name with a separator is a path, checked directly rather than looked
    // up in PATH.
    try testz.expectTrue(lsp.onPath(io, "/usr/bin/sh", &env));
    try testz.expectFalse(lsp.onPath(io, "/usr/bin/definitely-not-here", &env));
    // No PATH at all is "nothing is installed", not a crash.
    var empty: std.process.Environ.Map = .init(alloc);
    defer empty.deinit();
    try testz.expectFalse(lsp.onPath(io, "sh", &empty));
}

pub fn lspHandshakeCompletesFromRealZlsBytesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var counter: Counter = .{};
    var pool = try lsp.Pool.init(alloc, io, counter.waker(), "/tmp/root");
    defer pool.deinit();

    const server = try pool.addForTest(.{
        .name = "zls",
        .languages = &.{"zig"},
        .cmd = &.{"zls"},
    });

    // A server is not usable until the handshake lands: before it, documents
    // queue and requests are refused.
    try testz.expectTrue(server.starting());
    try testz.expectFalse(server.ready());

    // zls talks before it answers: several `window/logMessage` notifications
    // arrive ahead of the `initialize` reply. A client that treated the first
    // frame as its response would never finish the handshake.
    const logs = try frame(alloc,
        \\{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"Starting ZLS"}}
    );
    defer alloc.free(logs);
    try server.feedBytes(logs);
    try testz.expectEqual(try pool.nextEvent(), null);
    try testz.expectTrue(server.starting());

    const reply = try frame(alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-8","hoverProvider":true,"definitionProvider":true,"referencesProvider":true}}}
    );
    defer alloc.free(reply);
    try server.feedBytes(reply);
    // Draining is what applies it: the handshake is finished on the UI
    // thread, not in the reader.
    try testz.expectEqual(try pool.nextEvent(), null);

    try testz.expectTrue(server.ready());
    try testz.expectEqual(server.encoding, .utf8);
    try testz.expectTrue(server.caps.hover);
    try testz.expectTrue(server.caps.definition);
    // Two chunks fed, two wakes -- the editor would have come round the loop
    // both times.
    try testz.expectEqual(counter.hits, 2);
}

pub fn lspHandshakeSplitAcrossReadsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var counter: Counter = .{};
    var pool = try lsp.Pool.init(alloc, io, counter.waker(), "/tmp/root");
    defer pool.deinit();
    const server = try pool.addForTest(.{ .name = "zls", .languages = &.{"zig"}, .cmd = &.{"zls"} });

    const reply = try frame(alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","hoverProvider":{"workDoneProgress":false},"definitionProvider":false}}}
    );
    defer alloc.free(reply);

    // A real socket splits a frame's header from its body, and this one lands
    // one byte at a time.
    for (reply) |b| try server.feedBytes(&.{b});
    try testz.expectEqual(try pool.nextEvent(), null);

    try testz.expectTrue(server.ready());
    // utf-16 is the protocol default and what basedpyright negotiates.
    try testz.expectEqual(server.encoding, .utf16);
    // A capability given as an options object means yes...
    try testz.expectTrue(server.caps.hover);
    // ...and an explicit false means no, so the editor asks someone else.
    try testz.expectFalse(server.caps.definition);
}

pub fn lspDiagnosticsArriveAsEventsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var counter: Counter = .{};
    var pool = try lsp.Pool.init(alloc, io, counter.waker(), "/tmp/root");
    defer pool.deinit();
    const server = try pool.addForTest(.{ .name = "zls", .languages = &.{"zig"}, .cmd = &.{"zls"} });

    const body =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/root/a%20b.zig","diagnostics":[{"range":{"start":{"line":0,"character":21},"end":{"line":0,"character":25}},"severity":1,"code":"undeclared_identifier","source":"zls","message":"use of undeclared identifier 'oops'"},{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":4}},"severity":2,"message":"unused"}]}}
    ;
    const f = try frame(alloc, body);
    defer alloc.free(f);
    try server.feedBytes(f);

    const ev = (try pool.nextEvent()).?;
    defer ev.deinit(alloc);
    try testz.expectTrue(ev == .diagnostics);
    const d = ev.diagnostics;
    // The uri is decoded back to a path, percent-escapes included.
    try testz.expectEqualStr("/tmp/root/a b.zig", d.path);
    try testz.expectEqualStr("zls", d.server);
    try testz.expectEqual(d.items.len, 2);
    try testz.expectEqual(d.items[0].severity, .err);
    try testz.expectEqual(d.items[0].range.start.character, 21);
    try testz.expectEqualStr("use of undeclared identifier 'oops'", d.items[0].message);
    try testz.expectEqualStr("undeclared_identifier", d.items[0].code.?);
    // A diagnostic with no `source` is attributed to the server that sent it,
    // which is what keeps two servers on one file distinguishable.
    try testz.expectEqual(d.items[1].severity, .warning);
    try testz.expectEqualStr("zls", d.items[1].source);
    try testz.expectEqual(d.items[1].code, null);

    // Nothing else was queued.
    try testz.expectEqual(try pool.nextEvent(), null);
}

pub fn lspStaleAndUnknownRepliesAreDroppedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var counter: Counter = .{};
    var pool = try lsp.Pool.init(alloc, io, counter.waker(), "/tmp/root");
    defer pool.deinit();
    const server = try pool.addForTest(.{ .name = "zls", .languages = &.{"zig"}, .cmd = &.{"zls"} });

    // A reply to an id nothing is waiting on -- a request already answered,
    // or a server inventing one.
    const bogus = try frame(alloc,
        \\{"jsonrpc":"2.0","id":9999,"result":{"contents":{"value":"ghost"}}}
    );
    defer alloc.free(bogus);
    try server.feedBytes(bogus);
    try testz.expectEqual(try pool.nextEvent(), null);

    // An error response is a real answer, and produces no event rather than a
    // popup full of nothing.
    const err_reply = try frame(alloc,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}
    );
    defer alloc.free(err_reply);
    try server.feedBytes(err_reply);
    try testz.expectEqual(try pool.nextEvent(), null);
    // It consumed the in-flight entry, so nothing is left waiting on a
    // request that already failed -- but an `initialize` that *errored* is a
    // server that never became usable, and it stays `starting` rather than
    // being quietly promoted.
    try testz.expectFalse(server.ready());
    try testz.expectTrue(server.starting());

    // Garbage that isn't JSON at all is skipped, not fatal.
    const junk = try frame(alloc, "not json {{{");
    defer alloc.free(junk);
    try server.feedBytes(junk);
    try testz.expectEqual(try pool.nextEvent(), null);
}

pub fn lspServerDeathIsReportedOnceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var counter: Counter = .{};
    var pool = try lsp.Pool.init(alloc, io, counter.waker(), "/tmp/root");
    defer pool.deinit();
    const server = try pool.addForTest(.{ .name = "zls", .languages = &.{"zig"}, .cmd = &.{"zls"} });

    // Diagnostics, then the stream closing: both must be seen, and in order.
    const f = try frame(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/root/a.zig","diagnostics":[]}}
    );
    defer alloc.free(f);
    try server.feedBytes(f);
    server.markStdoutClosedForTest();

    const first = (try pool.nextEvent()).?;
    defer first.deinit(alloc);
    try testz.expectTrue(first == .diagnostics);

    const second = (try pool.nextEvent()).?;
    defer second.deinit(alloc);
    try testz.expectTrue(second == .died);
    try testz.expectEqualStr("zls", second.died.server);

    // Once, not every drain -- otherwise the statusline would repeat it for
    // the rest of the session.
    try testz.expectEqual(try pool.nextEvent(), null);
}
