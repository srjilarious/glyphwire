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
