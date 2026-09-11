const std = @import("std");
const conn_stream = @import("conn_stream.zig");

/// LSP-style framing: a `Content-Length` header, a blank line, then exactly
/// that many body bytes. Chosen so JSON bodies never need newline-escaping
/// and frames stay `nc -U` / `jq`-debuggable — see decisions.md, Transport &
/// Wire Format. The body itself is opaque bytes at this layer; the JSON-RPC
/// message shape is a concern of the dispatch layer built on top of this.
pub const FrameError = error{
    MissingContentLength,
    InvalidContentLength,
};

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
        const header_end = std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") orelse return null;
        const content_length = try parseContentLength(self.buf.items[0..header_end]);

        const body_start = header_end + 4;
        const body_end = body_start + content_length;
        if (self.buf.items.len < body_end) return null;

        const body = try alloc.dupe(u8, self.buf.items[body_start..body_end]);
        errdefer alloc.free(body);

        const remaining_len = self.buf.items.len - body_end;
        std.mem.copyForwards(u8, self.buf.items[0..remaining_len], self.buf.items[body_end..]);
        self.buf.shrinkRetainingCapacity(remaining_len);

        return body;
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
        errdefer alloc.free(raw);

        const remaining_len = self.buf.items.len - n;
        std.mem.copyForwards(u8, self.buf.items[0..remaining_len], self.buf.items[n..]);
        self.buf.shrinkRetainingCapacity(remaining_len);

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
