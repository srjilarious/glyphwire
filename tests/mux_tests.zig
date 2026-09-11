const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const mux = glyphwire.mux;

fn frameBytes(alloc: std.mem.Allocator, kind: mux.Kind, channel: u32, payload: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    try mux.writeFrame(&aw.writer, kind, channel, payload);
    return aw.toOwnedSlice();
}

pub fn headerRoundTripDataTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const bytes = try frameBytes(alloc, .data, 7, "hello world");
    defer alloc.free(bytes);

    var r = std.Io.Reader.fixed(bytes);
    const hdr = try mux.readHeader(&r);
    try testz.expectEqual(mux.Kind.data, hdr.kind);
    try testz.expectEqual(@as(u32, 7), hdr.channel);
    try testz.expectEqual(@as(usize, 11), hdr.len);

    var payload: [11]u8 = undefined;
    try r.readSliceAll(&payload);
    try testz.expectEqualStr("hello world", &payload);
}

pub fn headerRoundTripControlKindsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    for ([_]mux.Kind{ .hello, .open, .close }) |kind| {
        const bytes = try frameBytes(alloc, kind, 3, "ignored");
        defer alloc.free(bytes);
        var r = std.Io.Reader.fixed(bytes);
        const hdr = try mux.readHeader(&r);
        try testz.expectEqual(kind, hdr.kind);
        try testz.expectEqual(@as(u32, 3), hdr.channel);
        // Control frames never carry a payload, whatever was passed in.
        try testz.expectEqual(@as(usize, 0), hdr.len);
    }
}

pub fn twoFramesBackToBackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try mux.writeFrame(&aw.writer, .open, 1, "");
    try mux.writeFrame(&aw.writer, .data, 1, "abc");

    var r = std.Io.Reader.fixed(aw.writer.buffered());

    const h1 = try mux.readHeader(&r);
    try testz.expectEqual(mux.Kind.open, h1.kind);

    const h2 = try mux.readHeader(&r);
    try testz.expectEqual(mux.Kind.data, h2.kind);
    var payload: [3]u8 = undefined;
    try r.readSliceAll(&payload);
    try testz.expectEqualStr("abc", &payload);
}

pub fn malformedHeaderRejectedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    const cases = [_][]const u8{
        "GW-Mux: data 1\r\n\r\n", // missing len field
        "GW-Mux: bogus 1 0\r\n\r\n", // unknown kind
        "NOT-Mux: data 1 0\r\n\r\n", // wrong tag
        "GW-Mux: data x 0\r\n\r\n", // non-numeric channel
    };
    for (cases) |c| {
        var r = std.Io.Reader.fixed(c);
        if (mux.readHeader(&r)) |_| {
            try testz.fail();
        } else |_| {}
    }
}

pub fn payloadTooLargeRejectedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "GW-Mux: data 1 {d}\r\n\r\n", .{mux.max_payload + 1}) catch unreachable;
    var r = std.Io.Reader.fixed(line);
    if (mux.readHeader(&r)) |_| {
        try testz.fail();
    } else |_| {}
}

pub fn trunkSendDataChunksLargeWriteTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var empty = std.Io.Reader.fixed("");
    var trunk: mux.Trunk = .{ .io = io, .reader = &empty, .writer = &aw.writer };

    const big = try alloc.alloc(u8, mux.max_payload * 2 + 100);
    defer alloc.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);

    try trunk.sendData(4, big);

    // Reassemble: every frame must be a `data` frame on channel 4, and
    // the concatenated payloads must equal `big`.
    var r = std.Io.Reader.fixed(aw.writer.buffered());
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var frames: usize = 0;
    while (true) {
        const hdr = mux.readHeader(&r) catch break;
        try testz.expectEqual(mux.Kind.data, hdr.kind);
        try testz.expectEqual(@as(u32, 4), hdr.channel);
        try testz.expectTrue(hdr.len <= mux.max_payload);
        const slice = try r.readAlloc(alloc, hdr.len);
        defer alloc.free(slice);
        try got.appendSlice(alloc, slice);
        frames += 1;
    }
    try testz.expectEqual(@as(usize, 3), frames);
    try testz.expectEqualStr(big, got.items);
}

pub fn channelFeedThenReadTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var empty = std.Io.Reader.fixed("");
    var trunk: mux.Trunk = .{ .io = io, .reader = &empty, .writer = &aw.writer };

    var ch: mux.Channel = .{ .id = 2, .trunk = &trunk, .io = io, .alloc = alloc };
    defer ch.deinit();

    try ch.feed("hello");
    try ch.feed(" world");

    var buf: [4]u8 = undefined;
    try testz.expectEqual(@as(usize, 4), ch.read(&buf));
    try testz.expectEqualStr("hell", &buf);

    var buf2: [64]u8 = undefined;
    try testz.expectEqual(@as(usize, 7), ch.read(&buf2));
    try testz.expectEqualStr("o world", buf2[0..7]);
}

pub fn channelClosePeerReportsEofTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var empty = std.Io.Reader.fixed("");
    var trunk: mux.Trunk = .{ .io = io, .reader = &empty, .writer = &aw.writer };

    var ch: mux.Channel = .{ .id = 9, .trunk = &trunk, .io = io, .alloc = alloc };
    defer ch.deinit();

    try ch.feed("tail");
    ch.closePeer();

    // Buffered bytes still drain first...
    var buf: [64]u8 = undefined;
    try testz.expectEqual(@as(usize, 4), ch.read(&buf));
    // ...then EOF.
    try testz.expectEqual(@as(usize, 0), ch.read(&buf));
}

pub fn channelWriteAllFramesOntoTrunkTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var empty = std.Io.Reader.fixed("");
    var trunk: mux.Trunk = .{ .io = io, .reader = &empty, .writer = &aw.writer };

    var ch: mux.Channel = .{ .id = 5, .trunk = &trunk, .io = io, .alloc = alloc };
    defer ch.deinit();

    try ch.writeAll("payload");

    var r = std.Io.Reader.fixed(aw.writer.buffered());
    const hdr = try mux.readHeader(&r);
    try testz.expectEqual(mux.Kind.data, hdr.kind);
    try testz.expectEqual(@as(u32, 5), hdr.channel);
    var payload: [7]u8 = undefined;
    try r.readSliceAll(&payload);
    try testz.expectEqualStr("payload", &payload);
}
