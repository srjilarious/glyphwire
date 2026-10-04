// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! One API over the two body encodings a connection can speak (see
//! `wire.Format`). Everything that builds or reads a message goes through
//! here, so a handler, a `Client` method or a test never cares which
//! encoding its peer chose.
//!
//! The envelope is the same in both: `method`, `params`, and an `id` on a
//! request or its response. JSON adds `"jsonrpc":"2.0"` as JSON-RPC
//! requires; MessagePack leaves it out (it carries no information).

const std = @import("std");
const wire = @import("wire.zig");
const msgpack = @import("msgpack.zig");

pub const Format = wire.Format;

/// A message's `params`, still in the encoding it arrived in. Handlers take
/// one of these and turn it into their own params struct with
/// `parseParams` -- the MessagePack side straight from bytes, with no
/// intermediate tree.
pub const Params = union(Format) {
    json: std.json.Value,
    /// One encoded MessagePack value. Absent params arrive as nil.
    msgpack: []const u8,
};

/// `params` as a `T`. Unknown fields are ignored and missing ones take
/// their defaults, in both encodings. Strings in the result may point into
/// the message body, so the result must not outlive it.
pub fn parseParams(comptime T: type, alloc: std.mem.Allocator, params: Params) !std.json.Parsed(T) {
    return switch (params) {
        .json => |v| try std.json.parseFromValue(T, alloc, v, .{ .ignore_unknown_fields = true }),
        .msgpack => |bytes| try msgpack.decode(T, alloc, bytes, .{}),
    };
}

/// A decoded message envelope. `id` is null for a notification.
pub const Envelope = struct {
    method: []const u8,
    id: ?std.json.Value = null,
    params: Params,
};

const JsonEnvelope = struct {
    method: []const u8,
    id: ?std.json.Value = null,
    params: std.json.Value = .null,
};

const MsgpackEnvelope = struct {
    method: []const u8,
    id: ?std.json.Value = null,
    params: msgpack.Raw = nil_params,
};

const nil_params: msgpack.Raw = .{ .bytes = &.{0xc0} };

/// Decodes `body`'s envelope, leaving `params` encoded. Borrows from `body`
/// (method name, string ids), so free the result first.
pub fn parseEnvelope(format: Format, alloc: std.mem.Allocator, body: []const u8) !std.json.Parsed(Envelope) {
    switch (format) {
        .json => {
            const p = try std.json.parseFromSlice(JsonEnvelope, alloc, body, .{ .ignore_unknown_fields = true });
            return .{ .arena = p.arena, .value = .{
                .method = p.value.method,
                .id = p.value.id,
                .params = .{ .json = p.value.params },
            } };
        },
        .msgpack => {
            const p = try msgpack.decode(MsgpackEnvelope, alloc, body, .{});
            return .{ .arena = p.arena, .value = .{
                .method = p.value.method,
                .id = p.value.id,
                .params = .{ .msgpack = p.value.params.bytes },
            } };
        },
    }
}

/// `parseEnvelope` for an envelope already pulled out of a larger message
/// -- a `batch` sub-message, which arrives as a `std.json.Value` on JSON and
/// as encoded bytes on MessagePack.
pub fn parseEnvelopeFrom(alloc: std.mem.Allocator, sub: SubMessage) !std.json.Parsed(Envelope) {
    switch (sub) {
        .json => |v| {
            const p = try std.json.parseFromValue(JsonEnvelope, alloc, v, .{ .ignore_unknown_fields = true });
            return .{ .arena = p.arena, .value = .{
                .method = p.value.method,
                .id = p.value.id,
                .params = .{ .json = p.value.params },
            } };
        },
        .msgpack => |bytes| return parseEnvelope(.msgpack, alloc, bytes),
    }
}

/// One element of a `batch`'s `messages`.
pub const SubMessage = Params;

/// A `batch`'s sub-messages, each left encoded for `parseEnvelopeFrom`.
pub fn parseBatchMessages(alloc: std.mem.Allocator, params: Params) !std.json.Parsed([]const SubMessage) {
    switch (params) {
        .json => |v| {
            const p = try std.json.parseFromValue(struct { messages: []const std.json.Value }, alloc, v, .{ .ignore_unknown_fields = true });
            const out = try p.arena.allocator().alloc(SubMessage, p.value.messages.len);
            for (p.value.messages, out) |m, *o| o.* = .{ .json = m };
            return .{ .arena = p.arena, .value = out };
        },
        .msgpack => |bytes| {
            const p = try msgpack.decode(struct { messages: []const msgpack.Raw }, alloc, bytes, .{});
            const out = try p.arena.allocator().alloc(SubMessage, p.value.messages.len);
            for (p.value.messages, out) |m, *o| o.* = .{ .msgpack = m.bytes };
            return .{ .arena = p.arena, .value = out };
        },
    }
}

// ─── Encoding ────────────────────────────────────────────────────────────

pub const EncodeOptions = struct {
    /// Leave null optional fields out rather than writing them as null.
    /// Only for params whose receiving struct defaults every optional to
    /// null -- see `Client.notifyCompact`.
    omit_nulls: bool = false,
};

/// `v` encoded as `format`, as one owned slice.
pub fn encodeAlloc(format: Format, alloc: std.mem.Allocator, v: anytype, options: EncodeOptions) ![]u8 {
    return switch (format) {
        .json => try std.json.Stringify.valueAlloc(alloc, v, .{ .emit_null_optional_fields = !options.omit_nulls }),
        .msgpack => try msgpack.encodeAlloc(alloc, v, .{ .emit_null_optional_fields = !options.omit_nulls }),
    };
}

/// A notification body: `{method, params}`.
pub fn notification(format: Format, alloc: std.mem.Allocator, method: []const u8, params: anytype, options: EncodeOptions) ![]u8 {
    return switch (format) {
        .json => encodeAlloc(.json, alloc, struct {
            jsonrpc: []const u8 = "2.0",
            method: []const u8,
            params: @TypeOf(params),
        }{ .method = method, .params = params }, options),
        .msgpack => encodeAlloc(.msgpack, alloc, struct {
            method: []const u8,
            params: @TypeOf(params),
        }{ .method = method, .params = params }, options),
    };
}

/// A request body: `{id, method, params}`.
pub fn request(format: Format, alloc: std.mem.Allocator, id: i64, method: []const u8, params: anytype, options: EncodeOptions) ![]u8 {
    return switch (format) {
        .json => encodeAlloc(.json, alloc, struct {
            jsonrpc: []const u8 = "2.0",
            id: i64,
            method: []const u8,
            params: @TypeOf(params),
        }{ .id = id, .method = method, .params = params }, options),
        .msgpack => encodeAlloc(.msgpack, alloc, struct {
            id: i64,
            method: []const u8,
            params: @TypeOf(params),
        }{ .id = id, .method = method, .params = params }, options),
    };
}

/// A response body: `{id, result}`.
pub fn response(format: Format, alloc: std.mem.Allocator, id: std.json.Value, result: anytype) ![]u8 {
    return switch (format) {
        .json => encodeAlloc(.json, alloc, struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: @TypeOf(result),
        }{ .id = id, .result = result }, .{}),
        .msgpack => encodeAlloc(.msgpack, alloc, struct {
            id: std.json.Value,
            result: @TypeOf(result),
        }{ .id = id, .result = result }, .{}),
    };
}

/// A `batch` response, `{id, result: {responses: [...]}}`, built by
/// splicing each sub-response's already-encoded body in as-is -- no
/// sub-response is decoded and re-encoded to be wrapped.
pub fn batchResponse(format: Format, alloc: std.mem.Allocator, id: std.json.Value, responses: []const []const u8) ![]u8 {
    switch (format) {
        .json => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            const w = &out.writer;
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
            try std.json.Stringify.value(id, .{}, w);
            try w.writeAll(",\"result\":{\"responses\":[");
            for (responses, 0..) |r, i| {
                if (i != 0) try w.writeAll(",");
                try w.writeAll(r);
            }
            try w.writeAll("]}}");
            return out.toOwnedSlice();
        },
        .msgpack => {
            var enc: msgpack.Encoder = .init(alloc, .{});
            errdefer enc.deinit();
            try enc.writeMapLen(2);
            try enc.writeStr("id");
            try enc.writeJsonValue(id);
            try enc.writeStr("result");
            try enc.writeMapLen(1);
            try enc.writeStr("responses");
            try enc.writeArrayLen(responses.len);
            for (responses) |r| try enc.writeRaw(r);
            return enc.toOwnedSlice();
        },
    }
}

/// `{result: T}` out of a response body. Strings are copied, so the
/// result outlives `body`.
pub fn parseResult(comptime T: type, format: Format, alloc: std.mem.Allocator, body: []const u8) !std.json.Parsed(Result(T)) {
    return switch (format) {
        .json => try std.json.parseFromSlice(Result(T), alloc, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }),
        .msgpack => try msgpack.decode(Result(T), alloc, body, .{ .copy_strings = true }),
    };
}

pub fn Result(comptime T: type) type {
    return struct {
        id: i64 = 0,
        result: T = undefined,
    };
}

/// Re-encodes a JSON body as MessagePack, dropping the envelope's
/// `jsonrpc` member. For server-pushed notifications: those are built once
/// as JSON (`rpc.zig`) and fanned out to every subscriber, and only a
/// MessagePack subscriber pays for the conversion.
pub fn jsonToMsgpack(alloc: std.mem.Allocator, json_body: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json_body, .{});
    if (v == .object) _ = v.object.orderedRemove("jsonrpc");
    var enc: msgpack.Encoder = .init(alloc, .{});
    errdefer enc.deinit();
    try enc.writeJsonValue(v);
    return enc.toOwnedSlice();
}
