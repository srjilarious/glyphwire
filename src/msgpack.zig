// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A small MessagePack codec: just what glyphwire's wire needs, no ext
//! types, no streaming. Two halves:
//!
//! - `Encoder` turns a Zig value into MessagePack bytes by reflection,
//!   following `std.json.Stringify`'s rules type for type (structs are
//!   string-keyed maps, enums are their tag name, optionals are the value or
//!   nil) so a message has the same shape in both encodings. A type with a
//!   `jsonStringify` method is serialized through it, so `protocol.Color`
//!   keeps a single definition of its compact form.
//! - `decode` fills a Zig type straight from bytes, following
//!   `std.json.parseFromValue`'s rules (unknown fields ignored, defaults
//!   filled, a missing field with no default is `MissingField`) -- but with
//!   no intermediate `std.json.Value` tree, which is where JSON's decode
//!   time goes.
//!
//! See docs/protocol.md's Transport section for why MessagePack.

const std = @import("std");

pub const Error = error{
    /// The bytes ended in the middle of a value.
    Truncated,
    /// A value's MessagePack type can't become the requested Zig type.
    UnexpectedType,
    /// An integer doesn't fit the requested Zig integer type.
    Overflow,
    /// A struct field with no default value wasn't in the map.
    MissingField,
    /// A string named no tag of the requested enum.
    InvalidEnumTag,
    /// A fixed-size array arrived with a different element count.
    LengthMismatch,
    /// Nesting deeper than `max_depth` -- refused rather than recursed into,
    /// since the bytes come off a socket.
    TooDeep,
    /// An ext type, or the never-used byte `0xc1`.
    Unsupported,
} || std.mem.Allocator.Error;

/// How deep `decode` / `skip` will follow nested arrays and maps.
pub const max_depth = 64;

/// A value left encoded. Decoding into `Raw` yields the exact bytes of one
/// value without interpreting them; encoding a `Raw` splices its bytes in
/// verbatim. What lets a `batch` hand its sub-messages around, and the
/// envelope hand `params` to a handler, without decoding anything twice.
pub const Raw = struct {
    bytes: []const u8,
};

/// Bytes that encode as `bin` rather than `str` -- an image payload, which
/// a `str` would claim is UTF-8. Decoding into a plain `[]const u8` accepts
/// either, so only the sending side needs this.
pub const Bin = struct {
    bytes: []const u8,
};

// ─── Encoding ────────────────────────────────────────────────────────────

pub const EncodeOptions = struct {
    /// `false` leaves a null optional struct field out of its map instead
    /// of writing nil -- `std.json.Stringify.Options`' option of the same
    /// name, with the same caveat: only safe when the receiving field
    /// defaults to null.
    emit_null_optional_fields: bool = true,
};

/// Appends MessagePack to a growable buffer. Owning the buffer (rather than
/// writing to a `std.Io.Writer`) is what lets the `jsonStringify` shim fix
/// up a container's length after the fact -- a JSON writer can stream
/// `{...}` without knowing how many fields follow, MessagePack can't.
pub const Encoder = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    options: EncodeOptions = .{},

    pub fn init(alloc: std.mem.Allocator, options: EncodeOptions) Encoder {
        return .{ .alloc = alloc, .options = options };
    }

    pub fn deinit(self: *Encoder) void {
        self.buf.deinit(self.alloc);
    }

    pub fn written(self: *const Encoder) []const u8 {
        return self.buf.items;
    }

    pub fn toOwnedSlice(self: *Encoder) ![]u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }

    fn put(self: *Encoder, bytes: []const u8) !void {
        try self.buf.appendSlice(self.alloc, bytes);
    }

    fn putByte(self: *Encoder, b: u8) !void {
        try self.buf.append(self.alloc, b);
    }

    fn putBig(self: *Encoder, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .big);
        try self.put(&b);
    }

    pub fn writeNil(self: *Encoder) !void {
        try self.putByte(0xc0);
    }

    pub fn writeBool(self: *Encoder, v: bool) !void {
        try self.putByte(if (v) 0xc3 else 0xc2);
    }

    /// The shortest encoding of `v`, signed or not.
    pub fn writeInt(self: *Encoder, v: anytype) !void {
        if (@TypeOf(v) == comptime_int) return self.writeInt(@as(std.math.IntFittingRange(v, v), v));
        const info = @typeInfo(@TypeOf(v)).int;
        if (info.bits > 64) @compileError("msgpack integers are at most 64 bits");
        if (v >= 0) {
            const u: u64 = @intCast(v);
            if (u <= 0x7f) return self.putByte(@intCast(u));
            if (u <= 0xff) return self.put(&.{ 0xcc, @intCast(u) });
            if (u <= 0xffff) {
                try self.putByte(0xcd);
                return self.putBig(u16, @intCast(u));
            }
            if (u <= 0xffff_ffff) {
                try self.putByte(0xce);
                return self.putBig(u32, @intCast(u));
            }
            try self.putByte(0xcf);
            return self.putBig(u64, u);
        }
        const s: i64 = @intCast(v);
        if (s >= -32) return self.putByte(@bitCast(@as(i8, @intCast(s))));
        if (s >= std.math.minInt(i8)) return self.put(&.{ 0xd0, @bitCast(@as(i8, @intCast(s))) });
        if (s >= std.math.minInt(i16)) {
            try self.putByte(0xd1);
            return self.putBig(i16, @intCast(s));
        }
        if (s >= std.math.minInt(i32)) {
            try self.putByte(0xd2);
            return self.putBig(i32, @intCast(s));
        }
        try self.putByte(0xd3);
        try self.putBig(i64, s);
    }

    pub fn writeF32(self: *Encoder, v: f32) !void {
        try self.putByte(0xca);
        try self.putBig(u32, @bitCast(v));
    }

    pub fn writeF64(self: *Encoder, v: f64) !void {
        try self.putByte(0xcb);
        try self.putBig(u64, @bitCast(v));
    }

    pub fn writeStr(self: *Encoder, s: []const u8) !void {
        try self.writeLenHeader(s.len, 0xa0, 31, 0xd9, 0xda, 0xdb);
        try self.put(s);
    }

    /// Raw bytes as `bin` -- image payloads, which a `str` would claim are
    /// UTF-8.
    pub fn writeBin(self: *Encoder, b: []const u8) !void {
        try self.writeBinHeader(b.len);
        try self.put(b);
    }

    /// Just the header of a `len`-byte `bin`, for a caller that writes the
    /// bytes themselves somewhere else -- `Client` streams an image
    /// straight to the socket behind it rather than copying it in here.
    pub fn writeBinHeader(self: *Encoder, len: usize) !void {
        if (len <= 0xff) {
            try self.put(&.{ 0xc4, @intCast(len) });
        } else if (len <= 0xffff) {
            try self.putByte(0xc5);
            try self.putBig(u16, @intCast(len));
        } else {
            try self.putByte(0xc6);
            try self.putBig(u32, @intCast(len));
        }
    }

    pub fn writeArrayLen(self: *Encoder, n: usize) !void {
        try self.writeLenHeader(n, 0x90, 15, null, 0xdc, 0xdd);
    }

    pub fn writeMapLen(self: *Encoder, n: usize) !void {
        try self.writeLenHeader(n, 0x80, 15, null, 0xde, 0xdf);
    }

    /// Splices already-encoded MessagePack in verbatim.
    pub fn writeRaw(self: *Encoder, bytes: []const u8) !void {
        try self.put(bytes);
    }

    fn writeLenHeader(self: *Encoder, n: usize, fix: u8, fix_max: usize, b8: ?u8, b16: u8, b32: u8) !void {
        if (n <= fix_max) return self.putByte(fix | @as(u8, @intCast(n)));
        if (b8) |tag| if (n <= 0xff) return self.put(&.{ tag, @intCast(n) });
        if (n <= 0xffff) {
            try self.putByte(b16);
            return self.putBig(u16, @intCast(n));
        }
        try self.putByte(b32);
        try self.putBig(u32, @intCast(n));
    }

    /// Encodes `v` by reflection. See the module comment for the mapping;
    /// it is `std.json.Stringify.write`'s, case for case.
    pub fn write(self: *Encoder, v: anytype) Error!void {
        const T = @TypeOf(v);
        // Before the `jsonStringify` checks: `std.json.Value` has one, and
        // it calls `print`, which the shim has no MessagePack meaning for.
        if (T == std.json.Value) return self.writeJsonValue(v);
        switch (@typeInfo(T)) {
            .int => return self.writeInt(v),
            .comptime_int => return self.writeInt(@as(std.math.IntFittingRange(v, v), v)),
            .float => |f| return if (f.bits <= 32) self.writeF32(v) else self.writeF64(@floatCast(v)),
            .comptime_float => return self.writeF64(v),
            .bool => return self.writeBool(v),
            .null => return self.writeNil(),
            .optional => return if (v) |payload| self.write(payload) else self.writeNil(),
            .@"enum" => |info| {
                if (comptime std.meta.hasFn(T, "jsonStringify")) return self.writeViaJson(v);
                if (info.mode == .nonexhaustive) {
                    inline for (info.field_names) |name| {
                        if (v == @field(T, name)) break;
                    } else return self.writeInt(@backingInt(v));
                }
                return self.writeStr(@tagName(v));
            },
            .enum_literal => return self.writeStr(@tagName(v)),
            .error_set => return self.writeStr(@errorName(v)),
            .@"union" => |info| {
                if (comptime std.meta.hasFn(T, "jsonStringify")) return self.writeViaJson(v);
                const Tag = info.tag_type orelse @compileError("untagged union '" ++ @typeName(T) ++ "'");
                try self.writeMapLen(1);
                inline for (info.field_names, info.field_types) |name, FT| {
                    if (v == @field(Tag, name)) {
                        try self.writeStr(name);
                        if (FT == void) return self.writeMapLen(0);
                        return self.write(@field(v, name));
                    }
                }
                unreachable;
            },
            .@"struct" => |S| {
                if (T == Raw) return self.writeRaw(v.bytes);
                if (T == Bin) return self.writeBin(v.bytes);
                if (comptime std.meta.hasFn(T, "jsonStringify")) return self.writeViaJson(v);
                if (S.is_tuple) {
                    try self.writeArrayLen(S.field_names.len);
                    inline for (S.field_names) |name| try self.write(@field(v, name));
                    return;
                }
                var n: usize = 0;
                inline for (S.field_names, S.field_types) |name, FT| {
                    if (FT != void and self.emitsField(FT, @field(v, name))) n += 1;
                }
                try self.writeMapLen(n);
                inline for (S.field_names, S.field_types) |name, FT| {
                    if (FT != void and self.emitsField(FT, @field(v, name))) {
                        try self.writeStr(name);
                        try self.write(@field(v, name));
                    }
                }
            },
            .pointer => |p| switch (p.size) {
                .one => switch (@typeInfo(p.child)) {
                    .array => return self.write(@as([]const std.meta.Elem(p.child), v)),
                    else => return self.write(v.*),
                },
                .slice, .many => {
                    if (p.size == .many and p.sentinel() == null)
                        @compileError("unable to encode '" ++ @typeName(T) ++ "' without a sentinel");
                    const slice = if (p.size == .many) std.mem.span(v) else v;
                    if (p.child == u8) return self.writeStr(slice);
                    try self.writeArrayLen(slice.len);
                    for (slice) |x| try self.write(x);
                },
                else => @compileError("unable to encode '" ++ @typeName(T) ++ "'"),
            },
            .array => return self.write(&v),
            .vector => |vec| {
                const arr: [vec.len]vec.child = v;
                return self.write(&arr);
            },
            .void => return self.writeMapLen(0),
            else => @compileError("unable to encode '" ++ @typeName(T) ++ "'"),
        }
    }

    fn emitsField(self: *const Encoder, comptime FT: type, value: FT) bool {
        if (@typeInfo(FT) != .optional) return true;
        return self.options.emit_null_optional_fields or value != null;
    }

    pub fn writeJsonValue(self: *Encoder, v: std.json.Value) Error!void {
        switch (v) {
            .null => try self.writeNil(),
            .bool => |b| try self.writeBool(b),
            .integer => |i| try self.writeInt(i),
            .float => |f| try self.writeF64(f),
            .number_string => |s| {
                if (std.fmt.parseInt(i64, s, 10)) |i| {
                    try self.writeInt(i);
                } else |_| if (std.fmt.parseFloat(f64, s)) |f| {
                    try self.writeF64(f);
                } else |_| try self.writeStr(s);
            },
            .string => |s| try self.writeStr(s),
            .array => |a| {
                try self.writeArrayLen(a.items.len);
                for (a.items) |x| try self.writeJsonValue(x);
            },
            .object => |o| {
                try self.writeMapLen(o.count());
                var it = o.iterator();
                while (it.next()) |kv| {
                    try self.writeStr(kv.key_ptr.*);
                    try self.writeJsonValue(kv.value_ptr.*);
                }
            },
        }
    }

    fn writeViaJson(self: *Encoder, v: anytype) Error!void {
        var shim: JsonShim = .{ .enc = self };
        try v.jsonStringify(&shim);
    }
};

/// Stands in for `std.json.Stringify` when a type's `jsonStringify` is
/// called on the MessagePack path. Covers the calls those methods make --
/// `beginObject`/`objectField`/`write`/`endObject` and the array pair.
/// A container's element count isn't known until it ends, so each `begin*`
/// remembers where its header belongs and `end*` inserts it there.
const JsonShim = struct {
    enc: *Encoder,
    stack: [max_depth]Frame = undefined,
    depth: usize = 0,

    const Frame = struct { pos: usize, count: usize, map: bool };

    fn countChild(self: *JsonShim) void {
        if (self.depth > 0 and !self.stack[self.depth - 1].map) self.stack[self.depth - 1].count += 1;
    }

    fn begin(self: *JsonShim, map: bool) Error!void {
        if (self.depth == max_depth) return error.TooDeep;
        self.countChild();
        self.stack[self.depth] = .{ .pos = self.enc.buf.items.len, .count = 0, .map = map };
        self.depth += 1;
    }

    fn end(self: *JsonShim) Error!void {
        self.depth -= 1;
        const f = self.stack[self.depth];
        // Encode the header on the side, then move it into place.
        var hdr: Encoder = .init(self.enc.alloc, .{});
        defer hdr.deinit();
        if (f.map) try hdr.writeMapLen(f.count) else try hdr.writeArrayLen(f.count);
        try self.enc.buf.insertSlice(self.enc.alloc, f.pos, hdr.written());
    }

    pub fn beginObject(self: *JsonShim) Error!void {
        try self.begin(true);
    }

    pub fn endObject(self: *JsonShim) Error!void {
        try self.end();
    }

    pub fn beginArray(self: *JsonShim) Error!void {
        try self.begin(false);
    }

    pub fn endArray(self: *JsonShim) Error!void {
        try self.end();
    }

    pub fn objectField(self: *JsonShim, key: []const u8) Error!void {
        self.stack[self.depth - 1].count += 1;
        try self.enc.writeStr(key);
    }

    pub fn write(self: *JsonShim, v: anytype) Error!void {
        self.countChild();
        try self.enc.write(v);
    }
};

/// `v` as one owned MessagePack slice (caller frees with `alloc`).
pub fn encodeAlloc(alloc: std.mem.Allocator, v: anytype, options: EncodeOptions) Error![]u8 {
    var enc: Encoder = .init(alloc, options);
    errdefer enc.deinit();
    try enc.write(v);
    return enc.toOwnedSlice();
}

// ─── Decoding ────────────────────────────────────────────────────────────

pub const DecodeOptions = struct {
    /// Copy strings into the result's arena rather than slicing the input.
    /// The default borrows: right for a server handler, which is done with
    /// its params before the frame body is freed. A caller that keeps the
    /// result past the input's lifetime (`Client.request`) sets this.
    copy_strings: bool = false,
};

/// One lexical item: a scalar, or the header of a container whose `len`
/// elements (pairs, for a map) follow.
pub const Token = union(enum) {
    nil,
    bool: bool,
    uint: u64,
    int: i64,
    float: f64,
    str: []const u8,
    bin: []const u8,
    array: usize,
    map: usize,
};

/// A cursor over one MessagePack buffer.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.bytes.len;
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.bytes.len - self.pos < n) return error.Truncated;
        const s = self.bytes[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    fn big(self: *Reader, comptime T: type) Error!T {
        const s = try self.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .big);
    }

    fn bytesOf(self: *Reader, n: usize) Error![]const u8 {
        return self.take(n);
    }

    /// A container's element count, checked against what's left: each
    /// element is at least one byte, so a header claiming more than that is
    /// a lie, and believing it would size an allocation off the wire.
    fn count(self: *Reader, n: usize, per: usize) Error!usize {
        if (n > (self.bytes.len - self.pos) / per) return error.Truncated;
        return n;
    }

    pub fn next(self: *Reader) Error!Token {
        const b = (try self.take(1))[0];
        return switch (b) {
            0x00...0x7f => .{ .uint = b },
            0x80...0x8f => .{ .map = try self.count(b & 0x0f, 2) },
            0x90...0x9f => .{ .array = try self.count(b & 0x0f, 1) },
            0xa0...0xbf => .{ .str = try self.bytesOf(b & 0x1f) },
            0xc0 => .nil,
            0xc2 => .{ .bool = false },
            0xc3 => .{ .bool = true },
            0xc4 => .{ .bin = try self.bytesOf(try self.big(u8)) },
            0xc5 => .{ .bin = try self.bytesOf(try self.big(u16)) },
            0xc6 => .{ .bin = try self.bytesOf(try self.big(u32)) },
            0xca => .{ .float = @as(f32, @bitCast(try self.big(u32))) },
            0xcb => .{ .float = @bitCast(try self.big(u64)) },
            0xcc => .{ .uint = try self.big(u8) },
            0xcd => .{ .uint = try self.big(u16) },
            0xce => .{ .uint = try self.big(u32) },
            0xcf => .{ .uint = try self.big(u64) },
            0xd0 => .{ .int = try self.big(i8) },
            0xd1 => .{ .int = try self.big(i16) },
            0xd2 => .{ .int = try self.big(i32) },
            0xd3 => .{ .int = try self.big(i64) },
            0xd9 => .{ .str = try self.bytesOf(try self.big(u8)) },
            0xda => .{ .str = try self.bytesOf(try self.big(u16)) },
            0xdb => .{ .str = try self.bytesOf(try self.big(u32)) },
            0xdc => .{ .array = try self.count(try self.big(u16), 1) },
            0xdd => .{ .array = try self.count(try self.big(u32), 1) },
            0xde => .{ .map = try self.count(try self.big(u16), 2) },
            0xdf => .{ .map = try self.count(try self.big(u32), 2) },
            0xe0...0xff => .{ .int = @as(i8, @bitCast(b)) },
            // 0xc1 (never used) and the ext family.
            else => error.Unsupported,
        };
    }

    /// Steps over one whole value, however deeply nested.
    pub fn skip(self: *Reader) Error!void {
        // A count of values still owed, rather than recursion: a map of
        // `n` pairs owes `2n` more, an array of `n` owes `n`.
        var owed: usize = 1;
        while (owed > 0) : (owed -= 1) {
            switch (try self.next()) {
                .array => |n| owed += n,
                .map => |n| owed += 2 * n,
                else => {},
            }
        }
    }

    /// The encoded bytes of the next value, which is stepped over.
    pub fn raw(self: *Reader) Error![]const u8 {
        const start = self.pos;
        try self.skip();
        return self.bytes[start..self.pos];
    }

    fn enter(self: *Reader) Error!void {
        if (self.depth == max_depth) return error.TooDeep;
        self.depth += 1;
    }

    fn leave(self: *Reader) void {
        self.depth -= 1;
    }
};

/// `bytes` decoded as a `T`, packaged like `std.json.parseFromSlice`'s
/// result so a call site can take either. Trailing bytes after the one
/// value are an error.
pub fn decode(comptime T: type, alloc: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) Error!std.json.Parsed(T) {
    var parsed: std.json.Parsed(T) = .{ .arena = try alloc.create(std.heap.ArenaAllocator), .value = undefined };
    errdefer alloc.destroy(parsed.arena);
    parsed.arena.* = .init(alloc);
    errdefer parsed.arena.deinit();
    parsed.value = try decodeLeaky(T, parsed.arena.allocator(), bytes, options);
    return parsed;
}

/// `decode` without the packaging: everything allocated comes from
/// `arena`, which the caller frees wholesale.
pub fn decodeLeaky(comptime T: type, arena: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) Error!T {
    var r: Reader = .init(bytes);
    const v = try decodeFrom(T, arena, &r, options);
    if (!r.atEnd()) return error.UnexpectedType;
    return v;
}

/// Decodes the next value off `r` as a `T`. See the module comment for the
/// mapping (it is `std.json.parseFromValue`'s).
pub fn decodeFrom(comptime T: type, arena: std.mem.Allocator, r: *Reader, options: DecodeOptions) Error!T {
    if (T == Raw) return .{ .bytes = try r.raw() };
    if (T == std.json.Value) return decodeJsonValue(arena, r, options);
    if (comptime JsonMapValue(T)) |V| return decodeJsonMap(T, V, arena, r, options);

    switch (@typeInfo(T)) {
        .optional => |o| {
            if (r.pos < r.bytes.len and r.bytes[r.pos] == 0xc0) {
                r.pos += 1;
                return null;
            }
            return try decodeFrom(o.child, arena, r, options);
        },
        .@"struct" => |S| if (!S.is_tuple) return decodeStruct(T, arena, r, options),
        .@"union" => return decodeUnion(T, arena, r, options),
        else => {},
    }

    const start = r.pos;
    const tok = try r.next();
    switch (@typeInfo(T)) {
        .bool => return switch (tok) {
            .bool => |b| b,
            else => error.UnexpectedType,
        },
        .int => return switch (tok) {
            .uint => |u| std.math.cast(T, u) orelse error.Overflow,
            .int => |i| std.math.cast(T, i) orelse error.Overflow,
            .float => |f| floatToInt(T, f),
            else => error.UnexpectedType,
        },
        .float => return switch (tok) {
            .float => |f| @floatCast(f),
            .uint => |u| @floatFromInt(u),
            .int => |i| @floatFromInt(i),
            else => error.UnexpectedType,
        },
        .@"enum" => return switch (tok) {
            .str => |s| std.meta.stringToEnum(T, s) orelse error.InvalidEnumTag,
            .uint => |u| std.enums.fromInt(T, std.math.cast(@typeInfo(T).@"enum".tag_type, u) orelse return error.InvalidEnumTag) orelse error.InvalidEnumTag,
            .int => |i| std.enums.fromInt(T, std.math.cast(@typeInfo(T).@"enum".tag_type, i) orelse return error.InvalidEnumTag) orelse error.InvalidEnumTag,
            else => error.UnexpectedType,
        },
        .@"struct" => |S| {
            // Tuples only; plain structs returned above.
            const n = switch (tok) {
                .array => |n| n,
                else => return error.UnexpectedType,
            };
            if (n != S.field_names.len) return error.LengthMismatch;
            try r.enter();
            defer r.leave();
            var out: T = undefined;
            inline for (0..S.field_names.len) |i| out[i] = try decodeFrom(S.field_types[i], arena, r, options);
            return out;
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    const s = switch (tok) {
                        .str, .bin => |s| s,
                        else => return error.UnexpectedType,
                    };
                    if (p.sentinel()) |sent| return try arena.dupeSentinel(u8, s, sent);
                    return if (options.copy_strings) try arena.dupe(u8, s) else s;
                }
                const n = switch (tok) {
                    .array => |n| n,
                    else => return error.UnexpectedType,
                };
                try r.enter();
                defer r.leave();
                const out = try arena.alloc(p.child, n);
                for (out) |*x| x.* = try decodeFrom(p.child, arena, r, options);
                return out;
            },
            .one => {
                // Undo the token read: the pointee decodes the whole value.
                r.pos = start;
                const out = try arena.create(p.child);
                out.* = try decodeFrom(p.child, arena, r, options);
                return out;
            },
            else => @compileError("unable to decode into '" ++ @typeName(T) ++ "'"),
        },
        .array => |a| {
            if (a.child == u8) switch (tok) {
                .str, .bin => |s| {
                    if (s.len != a.len) return error.LengthMismatch;
                    var out: T = undefined;
                    @memcpy(out[0..], s);
                    return out;
                },
                else => {},
            };
            const n = switch (tok) {
                .array => |n| n,
                else => return error.UnexpectedType,
            };
            if (n != a.len) return error.LengthMismatch;
            try r.enter();
            defer r.leave();
            var out: T = undefined;
            for (&out) |*x| x.* = try decodeFrom(a.child, arena, r, options);
            return out;
        },
        .void => {
            r.pos = start;
            try r.skip();
            return {};
        },
        else => @compileError("unable to decode into '" ++ @typeName(T) ++ "'"),
    }
}

fn floatToInt(comptime T: type, f: f64) Error!T {
    if (@round(f) != f) return error.UnexpectedType;
    if (f < @as(f64, @floatFromInt(std.math.minInt(T))) or f > @as(f64, @floatFromInt(std.math.maxInt(T)))) return error.Overflow;
    return @intFromFloat(f);
}

/// Field name -> field index for `T`, built once per type at compile time.
fn FieldIndex(comptime T: type) type {
    const names = @typeInfo(T).@"struct".field_names;
    return struct {
        const map = blk: {
            var kvs: [names.len]struct { []const u8, usize } = undefined;
            for (names, 0..) |name, i| kvs[i] = .{ name, i };
            break :blk std.StaticStringMap(usize).initComptime(kvs);
        };
    };
}

fn decodeStruct(comptime T: type, arena: std.mem.Allocator, r: *Reader, options: DecodeOptions) Error!T {
    const S = @typeInfo(T).@"struct";
    const n = switch (try r.next()) {
        .map => |n| n,
        else => return error.UnexpectedType,
    };
    try r.enter();
    defer r.leave();

    var out: T = undefined;
    var seen: [S.field_names.len]bool = @splat(false);
    for (0..n) |_| {
        const key = switch (try r.next()) {
            .str => |s| s,
            else => return error.UnexpectedType,
        };
        const idx = FieldIndex(T).map.get(key) orelse {
            try r.skip();
            continue;
        };
        inline for (S.field_names, S.field_types, 0..) |name, FT, i| {
            if (i == idx) {
                @field(out, name) = try decodeFrom(FT, arena, r, options);
                seen[i] = true;
            }
        }
    }
    inline for (S.field_names, S.field_types, S.field_attrs, 0..) |name, FT, attrs, i| {
        if (!seen[i]) {
            if (attrs.defaultValue(FT)) |default| {
                @field(out, name) = default;
            } else return error.MissingField;
        }
    }
    return out;
}

fn decodeUnion(comptime T: type, arena: std.mem.Allocator, r: *Reader, options: DecodeOptions) Error!T {
    const U = @typeInfo(T).@"union";
    if (U.tag_type == null) @compileError("unable to decode untagged union '" ++ @typeName(T) ++ "'");
    switch (try r.next()) {
        .map => |n| if (n != 1) return error.UnexpectedType,
        else => return error.UnexpectedType,
    }
    try r.enter();
    defer r.leave();
    const key = switch (try r.next()) {
        .str => |s| s,
        else => return error.UnexpectedType,
    };
    inline for (U.field_names, U.field_types) |name, FT| {
        if (std.mem.eql(u8, name, key)) {
            if (FT == void) {
                try r.skip();
                return @unionInit(T, name, {});
            }
            return @unionInit(T, name, try decodeFrom(FT, arena, r, options));
        }
    }
    return error.InvalidEnumTag;
}

/// The next value as a `std.json.Value`, for the few places that keep a
/// value loosely typed (a request `id`, a `sort_key`). `bin` becomes a
/// string: JSON has nothing closer.
fn decodeJsonValue(arena: std.mem.Allocator, r: *Reader, options: DecodeOptions) Error!std.json.Value {
    return switch (try r.next()) {
        .nil => .null,
        .bool => |b| .{ .bool = b },
        .uint => |u| if (std.math.cast(i64, u)) |i| .{ .integer = i } else .{ .float = @floatFromInt(u) },
        .int => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .str, .bin => |s| .{ .string = if (options.copy_strings) try arena.dupe(u8, s) else s },
        .array => |n| blk: {
            try r.enter();
            defer r.leave();
            var a: std.json.Array = try .initCapacity(arena, n);
            for (0..n) |_| a.appendAssumeCapacity(try decodeJsonValue(arena, r, options));
            break :blk .{ .array = a };
        },
        .map => |n| blk: {
            try r.enter();
            defer r.leave();
            var o: std.json.ObjectMap = .empty;
            try o.ensureTotalCapacity(arena, n);
            for (0..n) |_| {
                const key = switch (try r.next()) {
                    .str => |s| if (options.copy_strings) try arena.dupe(u8, s) else s,
                    else => return error.UnexpectedType,
                };
                o.putAssumeCapacity(key, try decodeJsonValue(arena, r, options));
            }
            break :blk .{ .object = o };
        },
    };
}

/// The value type of a `std.json.ArrayHashMap(V)` (a string-keyed map that
/// std.json reads through its own hooks), or null for any other type.
fn JsonMapValue(comptime T: type) ?type {
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "map")) return null;
    const V = std.meta.Elem(@TypeOf(@as(T, undefined).map.values()));
    return if (T == std.json.ArrayHashMap(V)) V else null;
}

fn decodeJsonMap(comptime T: type, comptime V: type, arena: std.mem.Allocator, r: *Reader, options: DecodeOptions) Error!T {
    const n = switch (try r.next()) {
        .map => |n| n,
        else => return error.UnexpectedType,
    };
    try r.enter();
    defer r.leave();
    var out: T = .{};
    try out.map.ensureTotalCapacity(arena, n);
    for (0..n) |_| {
        const key = switch (try r.next()) {
            .str => |s| if (options.copy_strings) try arena.dupe(u8, s) else s,
            else => return error.UnexpectedType,
        };
        out.map.putAssumeCapacity(key, try decodeFrom(V, arena, r, options));
    }
    return out;
}
