// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const msgpack = glyphwire.msgpack;
const codec = glyphwire.codec;
const protocol = glyphwire.protocol;

fn encode(alloc: std.mem.Allocator, v: anytype) ![]u8 {
    return msgpack.encodeAlloc(alloc, v, .{});
}

fn expectBytes(actual: []const u8, expected: []const u8) !void {
    try testz.expectTrue(std.mem.eql(u8, actual, expected));
}

pub fn integersUseTheShortestEncodingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const cases = [_]struct { v: i64, bytes: []const u8 }{
        .{ .v = 0, .bytes = &.{0x00} },
        .{ .v = 127, .bytes = &.{0x7f} },
        .{ .v = 128, .bytes = &.{ 0xcc, 0x80 } },
        .{ .v = 256, .bytes = &.{ 0xcd, 0x01, 0x00 } },
        .{ .v = 70000, .bytes = &.{ 0xce, 0x00, 0x01, 0x11, 0x70 } },
        .{ .v = -1, .bytes = &.{0xff} },
        .{ .v = -32, .bytes = &.{0xe0} },
        .{ .v = -33, .bytes = &.{ 0xd0, 0xdf } },
        .{ .v = -200, .bytes = &.{ 0xd1, 0xff, 0x38 } },
    };
    for (cases) |c| {
        const out = try encode(alloc, c.v);
        defer alloc.free(out);
        try expectBytes(out, c.bytes);
        try testz.expectEqual(try msgpack.decodeLeaky(i64, alloc, out, .{}), c.v);
    }
}

pub fn largeUnsignedRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const v: u64 = std.math.maxInt(u64);
    const out = try encode(alloc, v);
    defer alloc.free(out);
    try testz.expectEqual(out[0], 0xcf);
    try testz.expectEqual(try msgpack.decodeLeaky(u64, alloc, out, .{}), v);
}

pub fn integerTooBigForTargetIsOverflowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const out = try encode(alloc, @as(u32, 300));
    defer alloc.free(out);
    try testz.expectError(msgpack.decodeLeaky(u8, alloc, out, .{}), error.Overflow);
    try testz.expectError(msgpack.decodeLeaky(u8, alloc, &.{0xff}, .{}), error.Overflow);
}

pub fn stringHeadersStepUpWithLengthTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const short = try encode(alloc, @as([]const u8, "hi"));
    defer alloc.free(short);
    try expectBytes(short, &.{ 0xa2, 'h', 'i' });

    const mid_text: [40]u8 = @splat('x');
    const mid = try encode(alloc, @as([]const u8, &mid_text));
    defer alloc.free(mid);
    try expectBytes(mid[0..2], &.{ 0xd9, 40 });

    const long_text: [300]u8 = @splat('y');
    const long = try encode(alloc, @as([]const u8, &long_text));
    defer alloc.free(long);
    try expectBytes(long[0..3], &.{ 0xda, 0x01, 0x2c });
    try testz.expectEqualStr(try msgpack.decodeLeaky([]const u8, alloc, long, .{}), &long_text);
}

pub fn binDecodesIntoAByteSliceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const out = try encode(alloc, msgpack.Bin{ .bytes = &.{ 0x89, 'P', 'N', 'G' } });
    defer alloc.free(out);
    try expectBytes(out, &.{ 0xc4, 4, 0x89, 'P', 'N', 'G' });
    try expectBytes(try msgpack.decodeLeaky([]const u8, alloc, out, .{}), &.{ 0x89, 'P', 'N', 'G' });
}

const Params = struct {
    text: []const u8,
    row: ?usize = null,
    pad: bool = false,
    scale: Scale = .x1,
    spans: ?[]const Span = null,

    const Scale = enum { x1, x2 };
    const Span = struct { text: []const u8, bold: bool = false };
};

pub fn structRoundTripsWithDefaultsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const spans = [_]Params.Span{ .{ .text = "a" }, .{ .text = "b", .bold = true } };
    const out = try encode(alloc, Params{ .text = "hey", .row = 4, .scale = .x2, .spans = &spans });
    defer alloc.free(out);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const p = try msgpack.decodeLeaky(Params, arena.allocator(), out, .{});
    try testz.expectEqualStr(p.text, "hey");
    try testz.expectEqual(p.row.?, 4);
    try testz.expectFalse(p.pad);
    try testz.expectTrue(p.scale == .x2);
    try testz.expectEqual(p.spans.?.len, 2);
    try testz.expectTrue(p.spans.?[1].bold);
}

pub fn unknownFieldsAreSkippedAndMissingOnesDefaultTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // `{text: "t", extra: {nested: [1, 2]}}` -- `extra` isn't a field.
    const out = try encode(alloc, .{ .text = @as([]const u8, "t"), .extra = .{ .nested = .{ 1, 2 } } });
    defer alloc.free(out);
    const p = try msgpack.decodeLeaky(Params, alloc, out, .{});
    try testz.expectEqualStr(p.text, "t");
    try testz.expectTrue(p.row == null);
    try testz.expectTrue(p.scale == .x1);
}

pub fn missingRequiredFieldErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const out = try encode(alloc, .{ .row = @as(usize, 1) });
    defer alloc.free(out);
    try testz.expectError(msgpack.decodeLeaky(Params, alloc, out, .{}), error.MissingField);
}

pub fn omittingNullsLeavesFieldsOutTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const v = struct { a: ?u8 = null, b: u8 = 1 }{};
    const full = try msgpack.encodeAlloc(alloc, v, .{});
    defer alloc.free(full);
    const compact = try msgpack.encodeAlloc(alloc, v, .{ .emit_null_optional_fields = false });
    defer alloc.free(compact);
    try testz.expectEqual(full[0], 0x82);
    try testz.expectEqual(compact[0], 0x81);
}

pub fn colorGoesThroughItsJsonStringifyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // A reference colour serializes as just `role` (plus `a`) -- the
    // compact form `Color.jsonStringify` writes, reached through the shim.
    const out = try encode(alloc, protocol.Color{ .role = "keyword", .a = 128 });
    defer alloc.free(out);
    try testz.expectEqual(out[0], 0x82);
    const c = try msgpack.decodeLeaky(protocol.Color, alloc, out, .{});
    try testz.expectEqualStr(c.role.?, "keyword");
    try testz.expectEqual(c.a, 128);
    try testz.expectEqual(c.r, 0);
}

pub fn nestedJsonStringifyContainersCountCorrectlyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // Colours inside an array inside a struct: each shim container's
    // header is inserted after its body, so the outer ones must still
    // land in the right place.
    const colors = [_]protocol.Color{ .{ .r = 1 }, .{ .slot = 3 }, .{ .g = 2 } };
    const out = try encode(alloc, .{ .slots = @as([]const protocol.Color, &colors), .n = @as(u8, 3) });
    defer alloc.free(out);
    const T = struct { slots: []const protocol.Color, n: u8 };
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const v = try msgpack.decodeLeaky(T, arena.allocator(), out, .{});
    try testz.expectEqual(v.n, 3);
    try testz.expectEqual(v.slots.len, 3);
    try testz.expectEqual(v.slots[0].r, 1);
    try testz.expectEqual(v.slots[1].slot.?, 3);
    try testz.expectEqual(v.slots[2].g, 2);
}

pub fn jsonValueRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":7,"list":[true,null,1.5,"s"],"neg":-3}
    , .{});
    const out = try msgpack.encodeAlloc(a, v, .{});
    const back = try msgpack.decodeLeaky(std.json.Value, a, out, .{});
    try testz.expectEqual(back.object.get("id").?.integer, 7);
    try testz.expectEqual(back.object.get("neg").?.integer, -3);
    const list = back.object.get("list").?.array.items;
    try testz.expectTrue(list[0].bool);
    try testz.expectTrue(list[1] == .null);
    try testz.expectTrue(list[2].float == 1.5);
    try testz.expectEqualStr(list[3].string, "s");
}

pub fn rawKeepsAValueEncodedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const inner = try encode(alloc, .{ .x = @as(u8, 1) });
    defer alloc.free(inner);
    const out = try encode(alloc, .{ .wrapped = msgpack.Raw{ .bytes = inner }, .y = @as(u8, 2) });
    defer alloc.free(out);
    const T = struct { wrapped: msgpack.Raw, y: u8 };
    const v = try msgpack.decodeLeaky(T, alloc, out, .{});
    try expectBytes(v.wrapped.bytes, inner);
    try testz.expectEqual(v.y, 2);
}

pub fn jsonArrayHashMapDecodesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const out = try msgpack.encodeAlloc(arena.allocator(), .{ .keyword = protocol.Color{ .r = 9 } }, .{});
    const m = try msgpack.decodeLeaky(std.json.ArrayHashMap(protocol.Color), arena.allocator(), out, .{});
    try testz.expectEqual(m.map.get("keyword").?.r, 9);
}

pub fn truncatedInputErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const out = try encode(alloc, Params{ .text = "hello" });
    defer alloc.free(out);
    for (0..out.len) |n| {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        if (msgpack.decodeLeaky(Params, arena.allocator(), out[0..n], .{})) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }
}

pub fn lyingContainerLengthIsRefusedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // array32 claiming four billion elements, with no bytes behind it:
    // refused before anything is allocated for it.
    const bytes = [_]u8{ 0xdd, 0xff, 0xff, 0xff, 0xff };
    try testz.expectError(msgpack.decodeLeaky([]const u8, alloc, &bytes, .{}), error.Truncated);
    try testz.expectError(msgpack.decodeLeaky([]const u32, alloc, &bytes, .{}), error.Truncated);
}

pub fn deepNestingIsRefusedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // 100 nested one-element arrays around a nil.
    var bytes: [101]u8 = undefined;
    @memset(bytes[0..100], 0x91);
    bytes[100] = 0xc0;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    try testz.expectError(msgpack.decodeLeaky(std.json.Value, arena.allocator(), &bytes, .{}), error.TooDeep);
}

pub fn neverUsedByteIsUnsupportedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    try testz.expectError(msgpack.decodeLeaky(u8, alloc, &.{0xc1}, .{}), error.Unsupported);
}

// ─── codec ───────────────────────────────────────────────────────────────

pub fn envelopeParsesTheSameFromEitherFormatTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const T = struct { text: []const u8, row: usize };
    for ([_]codec.Format{ .json, .msgpack }) |format| {
        const body = try codec.request(format, alloc, 42, "write_text", .{ .text = @as([]const u8, "hi"), .row = @as(usize, 3) }, .{});
        defer alloc.free(body);
        const env = try codec.parseEnvelope(format, alloc, body);
        defer env.deinit();
        try testz.expectEqualStr(env.value.method, "write_text");
        try testz.expectEqual(env.value.id.?.integer, 42);
        const p = try codec.parseParams(T, alloc, env.value.params);
        defer p.deinit();
        try testz.expectEqualStr(p.value.text, "hi");
        try testz.expectEqual(p.value.row, 3);
    }
}

pub fn msgpackEnvelopeHasNoJsonrpcMemberTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const body = try codec.notification(.msgpack, alloc, "sync", .{ .a = @as(u8, 1) }, .{});
    defer alloc.free(body);
    const v = try msgpack.decode(std.json.Value, alloc, body, .{});
    defer v.deinit();
    try testz.expectTrue(v.value.object.get("jsonrpc") == null);
    try testz.expectEqual(v.value.object.count(), 2);
}

pub fn jsonToMsgpackDropsJsonrpcTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const body = try codec.jsonToMsgpack(alloc,
        \\{"jsonrpc":"2.0","method":"key_down","params":{"key":"a","mods":{"ctrl":true}}}
    );
    defer alloc.free(body);
    const env = try codec.parseEnvelope(.msgpack, alloc, body);
    defer env.deinit();
    try testz.expectEqualStr(env.value.method, "key_down");
    const p = try codec.parseParams(struct { key: []const u8 }, alloc, env.value.params);
    defer p.deinit();
    try testz.expectEqualStr(p.value.key, "a");
}

pub fn jsonBatchResponseSplicesSubResponsesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const subs = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"result":{"handle":5}}
        ,
        \\{"jsonrpc":"2.0","id":2,"result":{}}
        ,
    };
    const body = try codec.batchResponse(.json, alloc, .{ .integer = 9 }, &subs);
    defer alloc.free(body);
    try testz.expectEqualStr(body,
        \\{"jsonrpc":"2.0","id":9,"result":{"responses":[{"jsonrpc":"2.0","id":1,"result":{"handle":5}},{"jsonrpc":"2.0","id":2,"result":{}}]}}
    );
}

pub fn msgpackBatchResponseSplicesSubResponsesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const a = try codec.response(.msgpack, alloc, .{ .integer = 1 }, .{ .handle = @as(u32, 5) });
    defer alloc.free(a);
    const body = try codec.batchResponse(.msgpack, alloc, .{ .integer = 9 }, &.{a});
    defer alloc.free(body);
    const T = struct { id: i64, result: struct { responses: []const codec.Result(struct { handle: u32 }) } };
    const v = try msgpack.decode(T, alloc, body, .{});
    defer v.deinit();
    try testz.expectEqual(v.value.id, 9);
    try testz.expectEqual(v.value.result.responses[0].id, 1);
    try testz.expectEqual(v.value.result.responses[0].result.handle, 5);
}
