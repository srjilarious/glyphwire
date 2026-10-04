// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const conn_stream = @import("conn_stream.zig");

/// LSP-style framing: a `Content-Length` header, a blank line, then exactly
/// that many body bytes. Chosen so JSON bodies never need newline-escaping
/// and frames stay `nc -U` / `jq`-debuggable — see decisions.md, Transport &
/// Wire Format. That is a JSON connection's framing; a MessagePack one
/// length-prefixes instead (see `Format`). The body itself is opaque bytes
/// at this layer; its encoding is `codec.zig`'s concern.
pub const FrameError = error{
    MissingContentLength,
    InvalidContentLength,
    /// A connection opened with `0xc1` but not the rest of
    /// `msgpack_preamble`.
    BadPreamble,
};

/// How one connection's bodies are encoded and framed, fixed for its
/// lifetime. `json`: JSON-RPC bodies under `Content-Length` headers (the
/// framing above). `msgpack`: MessagePack bodies, each preceded by its
/// length as a big-endian `u32` -- see decisions in docs/protocol.md's
/// Transport section.
pub const Format = enum { json, msgpack };

/// What a MessagePack client writes once, before its first frame. A server
/// tells the two formats apart from a connection's first byte: `0xc1` is
/// the one byte MessagePack never assigns, and can't start a JSON
/// connection's `Content-Length` header either.
pub const msgpack_preamble = "\xc1GWM";

/// Writes the connection-opening bytes `format` needs: the preamble for
/// MessagePack, nothing for JSON (whose framing is self-announcing).
pub fn writePreamble(writer: *std.Io.Writer, format: Format) !void {
    if (format == .msgpack) try writer.writeAll(msgpack_preamble);
}

/// `writeFrame` for either format.
pub fn writeFrameAs(writer: *std.Io.Writer, format: Format, body: []const u8) !void {
    switch (format) {
        .json => try writeFrame(writer, body),
        .msgpack => {
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(body.len), .big);
            try writer.writeAll(&len);
            try writer.writeAll(body);
        },
    }
}

/// `framedAlloc` for either format.
pub fn framedAllocAs(alloc: std.mem.Allocator, format: Format, body: []const u8) ![]u8 {
    switch (format) {
        .json => return framedAlloc(alloc, body),
        .msgpack => {
            const out = try alloc.alloc(u8, 4 + body.len);
            std.mem.writeInt(u32, out[0..4], @intCast(body.len), .big);
            @memcpy(out[4..], body);
            return out;
        },
    }
}

/// Writes one framed message to `writer`.
pub fn writeFrame(writer: *std.Io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}

/// Returns `"Content-Length: <n>\r\n\r\n" ++ body` as one owned slice
/// (caller frees with `alloc`). For a transport that only takes a whole
/// buffer -- a `mux.Channel`, which frames each write onto the trunk --
/// rather than a streaming `std.Io.Writer`.
pub fn framedAlloc(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// Incrementally reassembles frames from bytes fed in arbitrary-sized
/// chunks. A real socket can split a frame's header and body across
/// separate reads, or deliver several frames in one read — `feed` accepts
/// whatever arrived, and `next` drains as many complete frames as are
/// buffered so far.
pub const FrameDecoder = struct {
    buf: std.ArrayList(u8) = .empty,
    /// The framing `next` reassembles. A client knows its own; a server
    /// sets `detect` and lets the first bytes decide (see
    /// `msgpack_preamble`), after which this holds the answer.
    format: Format = .json,
    /// Decide `format` from the connection's opening bytes on the first
    /// `next`, consuming the MessagePack preamble if that's what they are.
    detect: bool = false,

    pub fn deinit(self: *FrameDecoder, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    pub fn feed(self: *FrameDecoder, alloc: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(alloc, bytes);
    }

    /// Returns the next complete frame's body (caller owns the returned
    /// slice and must free it with `alloc`), or null if not enough bytes
    /// have been fed yet to complete one.
    pub fn next(self: *FrameDecoder, alloc: std.mem.Allocator) !?[]u8 {
        if (self.detect) {
            const buf = self.buf.items;
            if (buf.len == 0) return null;
            if (buf[0] == msgpack_preamble[0]) {
                if (buf.len < msgpack_preamble.len) return null;
                if (!std.mem.eql(u8, buf[0..msgpack_preamble.len], msgpack_preamble)) return FrameError.BadPreamble;
                self.consume(msgpack_preamble.len);
                self.format = .msgpack;
            } else {
                self.format = .json;
            }
            self.detect = false;
        }
        if (self.format == .msgpack) return self.nextLengthPrefixed(alloc);

        const header_end = std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") orelse return null;
        const content_length = try parseContentLength(self.buf.items[0..header_end]);

        const body_start = header_end + 4;
        const body_end = body_start + content_length;
        if (self.buf.items.len < body_end) return null;

        const body = try alloc.dupe(u8, self.buf.items[body_start..body_end]);
        self.consume(body_end);
        return body;
    }

    fn nextLengthPrefixed(self: *FrameDecoder, alloc: std.mem.Allocator) !?[]u8 {
        if (self.buf.items.len < 4) return null;
        const len = std.mem.readInt(u32, self.buf.items[0..4], .big);
        const end = 4 + @as(usize, len);
        if (self.buf.items.len < end) return null;
        const body = try alloc.dupe(u8, self.buf.items[4..end]);
        self.consume(end);
        return body;
    }

    /// Drops the first `n` buffered bytes.
    fn consume(self: *FrameDecoder, n: usize) void {
        const remaining_len = self.buf.items.len - n;
        std.mem.copyForwards(u8, self.buf.items[0..remaining_len], self.buf.items[n..]);
        self.buf.shrinkRetainingCapacity(remaining_len);
    }

    /// Consumes exactly `n` raw bytes from the front of the buffer, not
    /// frame-parsed -- the binary side-channel's payload, following a JSON
    /// header frame that declared the count (`{bytes: N, ...}`, see
    /// decisions.md's Transport & Wire Format). Returns null (buffer
    /// untouched) if fewer than `n` bytes are currently buffered; caller
    /// should `feed` more and retry, mirroring how `next()` is used. Bytes
    /// past `n` are left in the buffer for whatever comes next (the
    /// following normal frame, or more of this payload on a later call).
    pub fn takeRaw(self: *FrameDecoder, alloc: std.mem.Allocator, n: usize) !?[]u8 {
        if (self.buf.items.len < n) return null;

        const raw = try alloc.dupe(u8, self.buf.items[0..n]);
        self.consume(n);
        return raw;
    }
};

/// Reads exactly `n` raw bytes directly off `stream`, not frame-parsed --
/// the binary side-channel's payload following a JSON header frame that
/// declared the count. Drains `decoder`'s already-buffered leftover bytes
/// first (a single socket read can pull in bytes past the header frame's
/// boundary), then reads more directly off the stream as needed. Takes a
/// `ConnStream` so it serves a local socket peer and a muxed remote peer
/// (a `gw-agent` trunk channel) the same way -- server.zig reads a
/// `load_image` request's payload through it.
pub fn readRaw(io: std.Io, stream: *conn_stream.ConnStream, decoder: *FrameDecoder, alloc: std.mem.Allocator, n: usize) ![]u8 {
    while (true) {
        if (try decoder.takeRaw(alloc, n)) |raw| return raw;

        var read_buf: [4096]u8 = undefined;
        const read_n = try stream.read(io, &read_buf);
        if (read_n == 0) return error.ConnectionClosed;
        try decoder.feed(alloc, read_buf[0..read_n]);
    }
}

fn parseContentLength(header: []const u8) !usize {
    const prefix = "content-length:";
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (line.len <= prefix.len) continue;
        var lower_buf: [prefix.len]u8 = undefined;
        const lower_prefix = std.ascii.lowerString(&lower_buf, line[0..prefix.len]);
        if (!std.mem.eql(u8, lower_prefix, prefix)) continue;

        const value = std.mem.trim(u8, line[prefix.len..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch return FrameError.InvalidContentLength;
    }
    return FrameError.MissingContentLength;
}
