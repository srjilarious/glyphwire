// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! gw-wire-bench: JSON vs MessagePack on the messages glyphwire actually
//! sends a lot of. Two halves:
//!
//! - **Codec**: one message encoded and decoded in-process, no socket, so
//!   the encoding is the only thing that differs. "dispatch" runs the real
//!   `Dispatcher` -- decode plus the core work, which is the same for both
//!   encodings, so its gap is the decode saving in context.
//! - **End to end**: a real `Server` on a Unix socket and a real `Client`,
//!   the way zoe / gw-grep / gw-read drive one.
//!
//! Run it optimized: `zig build bench-wire -Doptimize=ReleaseFast`.

const std = @import("std");
const glyphwire = @import("glyphwire");
const codec = glyphwire.codec;
const msgpack = glyphwire.msgpack;
const protocol = glyphwire.protocol;
const dispatch = glyphwire.dispatch;
const Format = glyphwire.wire.Format;

const formats = [_]Format{ .json, .msgpack };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var out_buf: [8192]u8 = undefined;
    // stderr: every `Client.connect` writes its handshake marker to stdout.
    var out_w = std.Io.File.stderr().writer(io, &out_buf);
    const out = &out_w.interface;

    try out.writeAll("\n== Codec (in-process, per message) ==\n\n");
    try out.print("{s:<34} {s:>9} {s:>9} {s:>11} {s:>11} {s:>7}\n", .{ "", "json B", "mpack B", "json ns", "mpack ns", "speedup" });

    try benchKeyEvent(io, alloc, out);
    try benchSpanRow(io, alloc, out);
    try benchFrame(io, alloc, out);
    try benchGetCells(io, alloc, out);
    try benchMetadataBatch(io, alloc, out);
    try out.flush();

    try out.writeAll("\n== End to end (Unix socket, real Server + Client) ==\n\n");
    try out.print("{s:<34} {s:>11} {s:>11} {s:>7}\n", .{ "", "json", "mpack", "speedup" });
    try benchEndToEnd(io, alloc, out);
    try out.writeAll("\n");
    try out.flush();
}

// ─── Timing ──────────────────────────────────────────────────────────────

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

fn nsSince(io: std.Io, from: std.Io.Timestamp) u64 {
    const d = from.durationTo(now(io));
    return if (d.nanoseconds <= 0) 0 else @intCast(d.nanoseconds);
}

/// Mean ns per call of `f(ctx)` over `iters` calls, after a warm-up.
fn timeIt(io: std.Io, iters: usize, ctx: anytype, comptime f: anytype) !u64 {
    for (0..@max(iters / 10, 1)) |_| try f(ctx);
    const t0 = now(io);
    for (0..iters) |_| try f(ctx);
    return nsSince(io, t0) / iters;
}

fn row(out: *std.Io.Writer, label: []const u8, sizes: [2]usize, ns: [2]u64) !void {
    const speedup = @as(f64, @floatFromInt(ns[0])) / @as(f64, @floatFromInt(@max(ns[1], 1)));
    if (sizes[0] == 0) {
        try out.print("{s:<34} {s:>9} {s:>9} {d:>11} {d:>11} {d:>6.2}x\n", .{ label, "", "", ns[0], ns[1], speedup });
    } else {
        try out.print("{s:<34} {d:>9} {d:>9} {d:>11} {d:>11} {d:>6.2}x\n", .{ label, sizes[0], sizes[1], ns[0], ns[1], speedup });
    }
}

// ─── Fixtures ────────────────────────────────────────────────────────────

/// One syntax-coloured line as a client sends it: `write_text` with
/// per-token spans, nulls left out (`notifyCompact`).
const SpanOut = struct {
    text: []const u8,
    fg: ?protocol.Color = null,
};
const RowOut = struct {
    row: usize,
    col: usize = 0,
    spans: []const SpanOut,
    pad: bool = true,
};

const tokens = [_][]const u8{ "    ", "const", " ", "parsed", " = ", "try", " ", "codec", ".", "parseEnvelope", "(", "format", ", ", "alloc", ", ", "body", ");", "  // decoded once" };

fn spanRow(spans: *[tokens.len]SpanOut, r: usize) RowOut {
    for (tokens, spans, 0..) |t, *s, i| s.* = .{
        .text = t,
        .fg = if (i % 3 == 0) null else .{ .r = @intCast(i * 13), .g = 180, .b = @intCast(255 - i * 7) },
    };
    return .{ .row = r, .spans = spans };
}

/// The `write_text` params a server reads that row back into -- the
/// fields of `dispatch.zig`'s own `WriteTextParams` that the row uses.
const SpanIn = struct {
    text: []const u8,
    fg: ?protocol.Color = null,
    bg: ?protocol.Color = null,
    metadata_id: ?u32 = null,
    scale: ?[]const u8 = null,
};
const RowIn = struct {
    layer: ?u32 = null,
    row: ?usize = null,
    col: ?usize = null,
    text: ?[]const u8 = null,
    spans: ?[]const SpanIn = null,
    pad: bool = false,
    fg: ?protocol.Color = null,
    bg: ?protocol.Color = null,
};

fn decodeRow(alloc: std.mem.Allocator, format: Format, body: []const u8) !void {
    const env = try codec.parseEnvelope(format, alloc, body);
    defer env.deinit();
    const p = try codec.parseParams(RowIn, alloc, env.value.params);
    defer p.deinit();
    std.mem.doNotOptimizeAway(p.value.spans.?.len);
}

/// A `batch` body: sub-messages encoded one at a time and spliced into the
/// outer message, as `Client.Batch` does.
fn encodeFrame(arena: std.mem.Allocator, format: Format, rows: usize) ![]const u8 {
    var spans: [tokens.len]SpanOut = undefined;
    var subs: std.ArrayList([]const u8) = .empty;
    for (0..rows) |r| {
        try subs.append(arena, try codec.encodeAlloc(format, arena, .{ .method = @as([]const u8, "write_text"), .params = spanRow(&spans, r) }, .{ .omit_nulls = true }));
    }
    try subs.append(arena, try codec.encodeAlloc(format, arena, .{ .method = @as([]const u8, "sync"), .params = .{ .layer = @as(?u32, null) }, .id = @as(u32, 1) }, .{}));
    switch (format) {
        .json => {
            var w: std.Io.Writer.Allocating = .init(arena);
            try w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"batch\",\"params\":{\"messages\":[");
            for (subs.items, 0..) |m, i| {
                if (i != 0) try w.writer.writeAll(",");
                try w.writer.writeAll(m);
            }
            try w.writer.writeAll("]}}");
            return w.written();
        },
        .msgpack => {
            var enc: msgpack.Encoder = .init(arena, .{});
            try enc.writeMapLen(3);
            try enc.writeStr("id");
            try enc.writeInt(1);
            try enc.writeStr("method");
            try enc.writeStr("batch");
            try enc.writeStr("params");
            try enc.writeMapLen(1);
            try enc.writeStr("messages");
            try enc.writeArrayLen(subs.items.len);
            for (subs.items) |m| try enc.writeRaw(m);
            return enc.written();
        },
    }
}

// ─── Codec scenarios ─────────────────────────────────────────────────────

fn benchKeyEvent(io: std.Io, alloc: std.mem.Allocator, out: *std.Io.Writer) !void {
    // Server side: every pushed event is built once as JSON; a MessagePack
    // subscriber's copy is a transcode of it (`Connection.send`).
    const mods: glyphwire.Mods = .{ .ctrl = true };
    var sizes: [2]usize = undefined;
    var enc_ns: [2]u64 = undefined;
    var dec_ns: [2]u64 = undefined;
    for (formats, 0..) |format, i| {
        const Enc = struct {
            alloc: std.mem.Allocator,
            format: Format,
            mods: glyphwire.Mods,
            fn run(s: @This()) !void {
                const json = try glyphwire.rpc.keyNotification(s.alloc, "Right", true, s.mods);
                defer s.alloc.free(json);
                if (s.format == .msgpack) {
                    const m = try codec.jsonToMsgpack(s.alloc, json);
                    s.alloc.free(m);
                }
            }
        };
        enc_ns[i] = try timeIt(io, 50_000, Enc{ .alloc = alloc, .format = format, .mods = mods }, Enc.run);

        const json = try glyphwire.rpc.keyNotification(alloc, "Right", true, mods);
        defer alloc.free(json);
        const body = if (format == .json) try alloc.dupe(u8, json) else try codec.jsonToMsgpack(alloc, json);
        defer alloc.free(body);
        sizes[i] = body.len;

        const Dec = struct {
            alloc: std.mem.Allocator,
            format: Format,
            body: []const u8,
            fn run(s: @This()) !void {
                const env = try codec.parseEnvelope(s.format, s.alloc, s.body);
                defer env.deinit();
                const p = try codec.parseParams(protocol.KeyParams, s.alloc, env.value.params);
                defer p.deinit();
                std.mem.doNotOptimizeAway(p.value.key.len);
            }
        };
        dec_ns[i] = try timeIt(io, 50_000, Dec{ .alloc = alloc, .format = format, .body = body }, Dec.run);
    }
    try row(out, "key_down  server encode (+xcode)", sizes, enc_ns);
    try row(out, "key_down  client decode", .{ 0, 0 }, dec_ns);
}

fn benchSpanRow(io: std.Io, alloc: std.mem.Allocator, out: *std.Io.Writer) !void {
    var sizes: [2]usize = undefined;
    var enc_ns: [2]u64 = undefined;
    var dec_ns: [2]u64 = undefined;
    var disp_ns: [2]u64 = undefined;
    for (formats, 0..) |format, i| {
        var spans: [tokens.len]SpanOut = undefined;
        const params = spanRow(&spans, 3);

        const Enc = struct {
            alloc: std.mem.Allocator,
            format: Format,
            params: RowOut,
            fn run(s: @This()) !void {
                const b = try codec.notification(s.format, s.alloc, "write_text", s.params, .{ .omit_nulls = true });
                s.alloc.free(b);
            }
        };
        enc_ns[i] = try timeIt(io, 50_000, Enc{ .alloc = alloc, .format = format, .params = params }, Enc.run);

        const body = try codec.notification(format, alloc, "write_text", params, .{ .omit_nulls = true });
        defer alloc.free(body);
        sizes[i] = body.len;

        const Dec = struct {
            alloc: std.mem.Allocator,
            format: Format,
            body: []const u8,
            fn run(s: @This()) !void {
                try decodeRow(s.alloc, s.format, s.body);
            }
        };
        dec_ns[i] = try timeIt(io, 50_000, Dec{ .alloc = alloc, .format = format, .body = body }, Dec.run);

        var ctx = try glyphwire.Context.init(alloc, 120, 40, 0);
        defer ctx.deinit();
        var d = dispatch.Dispatcher.init(&ctx);
        d.format = format;
        const Disp = struct {
            alloc: std.mem.Allocator,
            d: *dispatch.Dispatcher,
            body: []const u8,
            fn run(s: @This()) !void {
                _ = try s.d.handle(s.alloc, s.body);
            }
        };
        disp_ns[i] = try timeIt(io, 50_000, Disp{ .alloc = alloc, .d = &d, .body = body }, Disp.run);
    }
    try row(out, "write_text 18 spans  encode", sizes, enc_ns);
    try row(out, "write_text 18 spans  decode", .{ 0, 0 }, dec_ns);
    try row(out, "write_text 18 spans  dispatch", .{ 0, 0 }, disp_ns);
}

fn benchFrame(io: std.Io, alloc: std.mem.Allocator, out: *std.Io.Writer) !void {
    const rows = 60;
    var sizes: [2]usize = undefined;
    var enc_ns: [2]u64 = undefined;
    var disp_ns: [2]u64 = undefined;
    for (formats, 0..) |format, i| {
        const Enc = struct {
            alloc: std.mem.Allocator,
            format: Format,
            fn run(s: @This()) !void {
                var arena: std.heap.ArenaAllocator = .init(s.alloc);
                defer arena.deinit();
                std.mem.doNotOptimizeAway((try encodeFrame(arena.allocator(), s.format, rows)).len);
            }
        };
        enc_ns[i] = try timeIt(io, 2_000, Enc{ .alloc = alloc, .format = format }, Enc.run);

        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const body = try encodeFrame(arena.allocator(), format, rows);
        sizes[i] = body.len;

        var ctx = try glyphwire.Context.init(alloc, 120, rows, 0);
        defer ctx.deinit();
        var d = dispatch.Dispatcher.init(&ctx);
        d.format = format;
        const Disp = struct {
            alloc: std.mem.Allocator,
            d: *dispatch.Dispatcher,
            body: []const u8,
            fn run(s: @This()) !void {
                const r = try s.d.handle(s.alloc, s.body);
                if (r.response) |b| s.alloc.free(b);
            }
        };
        disp_ns[i] = try timeIt(io, 2_000, Disp{ .alloc = alloc, .d = &d, .body = body }, Disp.run);
    }
    try row(out, "zoe frame (60 rows + sync) encode", sizes, enc_ns);
    try row(out, "zoe frame (60 rows + sync) dispatch", .{ 0, 0 }, disp_ns);
}

fn benchGetCells(io: std.Io, alloc: std.mem.Allocator, out: *std.Io.Writer) !void {
    var sizes: [2]usize = undefined;
    var enc_ns: [2]u64 = undefined;
    var dec_ns: [2]u64 = undefined;
    for (formats, 0..) |format, i| {
        var ctx = try glyphwire.Context.init(alloc, 120, 40, 0);
        defer ctx.deinit();
        var d = dispatch.Dispatcher.init(&ctx);
        d.format = format;
        // Fill the grid with coloured text so every cell has content.
        var spans: [tokens.len]SpanOut = undefined;
        for (0..40) |r| {
            const b = try codec.notification(format, alloc, "write_text", spanRow(&spans, r), .{ .omit_nulls = true });
            defer alloc.free(b);
            _ = try d.handle(alloc, b);
        }
        const req = try codec.request(format, alloc, 1, "get_cells", .{ .layer = @as(?u32, null) }, .{});
        defer alloc.free(req);

        const Enc = struct {
            alloc: std.mem.Allocator,
            d: *dispatch.Dispatcher,
            req: []const u8,
            fn run(s: @This()) !void {
                const r = try s.d.handle(s.alloc, s.req);
                s.alloc.free(r.response.?);
            }
        };
        enc_ns[i] = try timeIt(io, 300, Enc{ .alloc = alloc, .d = &d, .req = req }, Enc.run);

        const resp = (try d.handle(alloc, req)).response.?;
        defer alloc.free(resp);
        sizes[i] = resp.len;

        const Dec = struct {
            alloc: std.mem.Allocator,
            format: Format,
            body: []const u8,
            fn run(s: @This()) !void {
                const p = try codec.parseResult(protocol.CellsResult, s.format, s.alloc, s.body);
                defer p.deinit();
                std.mem.doNotOptimizeAway(p.value.result.cells.len);
            }
        };
        dec_ns[i] = try timeIt(io, 300, Dec{ .alloc = alloc, .format = format, .body = resp }, Dec.run);
    }
    try row(out, "get_cells 120x40  server (+walk)", sizes, enc_ns);
    try row(out, "get_cells 120x40  client decode", .{ 0, 0 }, dec_ns);
}

fn benchMetadataBatch(io: std.Io, alloc: std.mem.Allocator, out: *std.Io.Writer) !void {
    // gw-grep's pattern: one batch of 1000 `create_metadata` requests.
    const n = 1000;
    var sizes: [2]usize = undefined;
    var disp_ns: [2]u64 = undefined;
    for (formats, 0..) |format, i| {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var subs: std.ArrayList([]const u8) = .empty;
        for (0..n) |k| {
            const json = try std.fmt.allocPrint(a, "{{\"path\":\"src/file{d}.zig\",\"line\":{d}}}", .{ k, k * 3 });
            try subs.append(a, try codec.encodeAlloc(format, a, .{ .method = @as([]const u8, "create_metadata"), .params = .{ .json = json }, .id = @as(u32, @intCast(k + 1)) }, .{}));
        }
        var body: []const u8 = undefined;
        switch (format) {
            .json => {
                var w: std.Io.Writer.Allocating = .init(a);
                try w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"batch\",\"params\":{\"messages\":[");
                for (subs.items, 0..) |m, k| {
                    if (k != 0) try w.writer.writeAll(",");
                    try w.writer.writeAll(m);
                }
                try w.writer.writeAll("]}}");
                body = w.written();
            },
            .msgpack => {
                var enc: msgpack.Encoder = .init(a, .{});
                try enc.writeMapLen(3);
                try enc.writeStr("id");
                try enc.writeInt(1);
                try enc.writeStr("method");
                try enc.writeStr("batch");
                try enc.writeStr("params");
                try enc.writeMapLen(1);
                try enc.writeStr("messages");
                try enc.writeArrayLen(subs.items.len);
                for (subs.items) |m| try enc.writeRaw(m);
                body = enc.written();
            },
        }
        sizes[i] = body.len;

        const Disp = struct {
            alloc: std.mem.Allocator,
            format: Format,
            body: []const u8,
            fn run(s: @This()) !void {
                var ctx = try glyphwire.Context.init(s.alloc, 80, 24, 0);
                defer ctx.deinit();
                var d = dispatch.Dispatcher.init(&ctx);
                d.format = s.format;
                const r = try d.handle(s.alloc, s.body);
                s.alloc.free(r.response.?);
            }
        };
        disp_ns[i] = try timeIt(io, 50, Disp{ .alloc = alloc, .format = format, .body = body }, Disp.run);
    }
    try row(out, "1000x create_metadata batch", sizes, disp_ns);
}

// ─── End to end ──────────────────────────────────────────────────────────

fn serveOne(srv: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    srv.acceptOne(alloc) catch |err| std.log.err("bench server: {t}", .{err});
}

fn fakePng(alloc: std.mem.Allocator, len: usize) ![]u8 {
    const bytes = try alloc.alloc(u8, len);
    @memset(bytes, 0x5a);
    @memcpy(bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, bytes[8..12], 13, .big);
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], 1024, .big);
    std.mem.writeInt(u32, bytes[20..24], 1024, .big);
    return bytes;
}

const E2E = struct {
    frame_us: u64 = 0,
    request_us: u64 = 0,
    cells_us: u64 = 0,
    image_us: u64 = 0,
};

fn benchEndToEnd(io: std.Io, alloc: std.mem.Allocator, out: *std.Io.Writer) !void {
    var results: [2]E2E = .{ .{}, .{} };
    for (formats, 0..) |format, i| {
        var ctx = try glyphwire.Context.init(alloc, 120, 60, 0);
        defer ctx.deinit();
        const path = try std.fmt.allocPrint(alloc, "/tmp/gw-wire-bench-{d}.sock", .{std.Thread.getCurrentId()});
        defer alloc.free(path);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

        var srv = try glyphwire.server.Server.bind(io, &ctx, path);
        defer srv.deinit(alloc);
        const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
        defer thread.join();

        var client = try glyphwire.Client.connectAs(io, alloc, path, format);
        defer client.deinit();

        // zoe's frame: 60 syntax-coloured rows, sent synced.
        var spans: [tokens.len]glyphwire.Client.Span = undefined;
        for (tokens, &spans, 0..) |t, *s, k| s.* = .{
            .text = t,
            .fg = if (k % 3 == 0) null else .{ .r = @intCast(k * 13), .g = 180, .b = @intCast(255 - k * 7), .a = 255 },
        };
        const frames = 400;
        {
            const t0 = now(io);
            for (0..frames) |_| {
                var b = client.batch();
                defer b.deinit();
                for (0..60) |r| try b.writeSpans(&spans, .{ .row = r, .col = 0, .pad = true });
                var res = try b.sendSynced();
                res.deinit();
            }
            results[i].frame_us = nsSince(io, t0) / frames / 1000;
        }

        // Plain request round trips.
        {
            const n = 3000;
            const t0 = now(io);
            for (0..n) |_| _ = try client.getCursor();
            results[i].request_us = nsSince(io, t0) / n / 1000;
        }

        // Full-grid read-backs.
        {
            const n = 100;
            const t0 = now(io);
            for (0..n) |_| {
                var snap = try client.getCells();
                snap.deinit();
            }
            results[i].cells_us = nsSince(io, t0) / n / 1000;
        }

        // A 4 MiB page swapped into one image slot (gw-read's loop).
        {
            const png = try fakePng(alloc, 4 << 20);
            defer alloc.free(png);
            const handle = try client.loadImage("png", png);
            const n = 30;
            const t0 = now(io);
            for (0..n) |_| _ = try client.updateImage(handle, "png", png);
            results[i].image_us = nsSince(io, t0) / n / 1000;
        }
    }
    try e2eRow(out, "zoe frame, synced (us/frame)", results[0].frame_us, results[1].frame_us);
    try e2eRow(out, "get_property round trip (us)", results[0].request_us, results[1].request_us);
    try e2eRow(out, "get_cells 120x60 (us)", results[0].cells_us, results[1].cells_us);
    try e2eRow(out, "update_image 4 MiB (us)", results[0].image_us, results[1].image_us);
}

fn e2eRow(out: *std.Io.Writer, label: []const u8, json: u64, mp: u64) !void {
    const speedup = @as(f64, @floatFromInt(json)) / @as(f64, @floatFromInt(@max(mp, 1)));
    try out.print("{s:<34} {d:>11} {d:>11} {d:>6.2}x\n", .{ label, json, mp, speedup });
}
