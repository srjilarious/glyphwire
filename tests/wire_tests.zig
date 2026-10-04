// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const wire = glyphwire.wire;

pub fn encodeDecodeRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try wire.writeFrame(&aw.writer, "hello");

    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);

    try decoder.feed(alloc, aw.writer.buffered());

    const body = try decoder.next(alloc);
    try testz.expectTrue(body != null);
    defer alloc.free(body.?);
    try testz.expectEqualStr("hello", body.?);
}

pub fn decoderReturnsNullUntilFrameCompleteTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try wire.writeFrame(&aw.writer, "hello");
    const framed = aw.writer.buffered();

    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);

    // Split the header itself across two feeds.
    try decoder.feed(alloc, framed[0..5]);
    try testz.expectTrue(try decoder.next(alloc) == null);

    try decoder.feed(alloc, framed[5..10]);
    try testz.expectTrue(try decoder.next(alloc) == null);

    // Deliver the rest of the header and part of the body.
    const body_start = std.mem.indexOf(u8, framed, "\r\n\r\n").? + 4;
    try decoder.feed(alloc, framed[10..body_start]);
    try testz.expectTrue(try decoder.next(alloc) == null);

    try decoder.feed(alloc, framed[body_start .. body_start + 2]);
    try testz.expectTrue(try decoder.next(alloc) == null);

    // Deliver the remaining body bytes; the frame should now complete.
    try decoder.feed(alloc, framed[body_start + 2 ..]);
    const body = try decoder.next(alloc);
    try testz.expectTrue(body != null);
    defer alloc.free(body.?);
    try testz.expectEqualStr("hello", body.?);
}

pub fn decoderDrainsMultipleFramesFromOneFeedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try wire.writeFrame(&aw.writer, "first");
    try wire.writeFrame(&aw.writer, "second");

    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);
    try decoder.feed(alloc, aw.writer.buffered());

    const first = try decoder.next(alloc);
    try testz.expectTrue(first != null);
    defer alloc.free(first.?);
    try testz.expectEqualStr("first", first.?);

    const second = try decoder.next(alloc);
    try testz.expectTrue(second != null);
    defer alloc.free(second.?);
    try testz.expectEqualStr("second", second.?);

    try testz.expectTrue(try decoder.next(alloc) == null);
}

pub fn decoderErrorsOnMissingContentLengthTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);

    try decoder.feed(alloc, "X-Bogus: 1\r\n\r\nhello");
    try testz.expectError(decoder.next(alloc), wire.FrameError.MissingContentLength);
}

pub fn msgpackFrameRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try wire.writeFrameAs(&aw.writer, .msgpack, "first");
    try wire.writeFrameAs(&aw.writer, .msgpack, "second");
    const framed = aw.writer.buffered();
    try testz.expectEqual(framed[3], 5); // big-endian u32 length

    var decoder: wire.FrameDecoder = .{ .format = .msgpack };
    defer decoder.deinit(alloc);
    // A byte at a time: the length prefix and the body both split.
    var bodies: std.ArrayList([]u8) = .empty;
    defer {
        for (bodies.items) |b| alloc.free(b);
        bodies.deinit(alloc);
    }
    for (framed) |b| {
        try decoder.feed(alloc, &.{b});
        while (try decoder.next(alloc)) |body| try bodies.append(alloc, body);
    }
    try testz.expectEqual(bodies.items.len, 2);
    try testz.expectEqualStr(bodies.items[0], "first");
    try testz.expectEqualStr(bodies.items[1], "second");
}

pub fn detectingDecoderPicksMsgpackFromThePreambleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try wire.writePreamble(&aw.writer, .msgpack);
    try wire.writeFrameAs(&aw.writer, .msgpack, "hi");
    const framed = aw.writer.buffered();

    var decoder: wire.FrameDecoder = .{ .detect = true };
    defer decoder.deinit(alloc);
    // Half the preamble isn't enough to decide on.
    try decoder.feed(alloc, framed[0..2]);
    try testz.expectTrue(try decoder.next(alloc) == null);
    try decoder.feed(alloc, framed[2..]);
    const body = (try decoder.next(alloc)).?;
    defer alloc.free(body);
    try testz.expectEqualStr(body, "hi");
    try testz.expectTrue(decoder.format == .msgpack);
}

pub fn detectingDecoderFallsBackToJsonTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try wire.writePreamble(&aw.writer, .json);
    try wire.writeFrameAs(&aw.writer, .json, "{}");

    var decoder: wire.FrameDecoder = .{ .detect = true };
    defer decoder.deinit(alloc);
    try decoder.feed(alloc, aw.writer.buffered());
    const body = (try decoder.next(alloc)).?;
    defer alloc.free(body);
    try testz.expectEqualStr(body, "{}");
    try testz.expectTrue(decoder.format == .json);
}

pub fn detectingDecoderRejectsABadPreambleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var decoder: wire.FrameDecoder = .{ .detect = true };
    defer decoder.deinit(alloc);
    try decoder.feed(alloc, "\xc1XYZ");
    try testz.expectError(decoder.next(alloc), wire.FrameError.BadPreamble);
}
