//! Channel multiplexing for the remote-session trunk.
//!
//! `glyphwire --ssh <dest>` spawns `gw-agent --stdio` on the far host and
//! talks to it over one duplex byte stream carried by `ssh`'s stdin/stdout
//! (the *trunk*). The agent opens a normal `GLYPHWIRE_SOCK` on the remote
//! box; every remote client (`gw-shell`, and the `gw-ls` / `gw-view` /
//! `zoe` it launches, each with its `InputListener` as a second socket)
//! dials it unchanged. The agent bridges each accepted socket to a *mux
//! channel* on the trunk; the host turns each channel back into a
//! `Server` connection.
//!
//! The mux is a dumb byte shuttle -- it carries N independent substreams
//! and knows nothing of the JSON-RPC / `Content-Length` framing riding
//! inside them (that stays a `wire.zig` / `dispatch.zig` concern, spoken
//! verbatim on each channel end-to-end, image side-channel included).
//!
//! Frame format, deliberately the same house style as `wire.zig` so the
//! trunk stays `hexdump`-legible: a header line, a blank line, then
//! exactly `len` payload bytes.
//!
//!     GW-Mux: <kind> <channel> <len>\r\n\r\n<payload>
//!
//! `open` / `close` / `hello` always carry `len` 0; only `data` has a
//! payload. `hello` is sent once by the agent right after it starts, so
//! the host can tell "agent is up and speaking mux" from "ssh printed an
//! error to stdout".

const std = @import("std");

/// Largest `data` payload in one frame. Larger writes from a channel are
/// split across consecutive `data` frames; the receiver just concatenates
/// them back into the channel's byte substream (no message reassembly --
/// it is a stream, not a datagram).
pub const max_payload: usize = 16 * 1024;

/// Ceiling on a header line's length, so a malformed / hostile trunk
/// can't make the reader buffer unboundedly while hunting for `\n`.
pub const max_header_line: usize = 128;

pub const Kind = enum { hello, open, close, data };

pub const Header = struct {
    kind: Kind,
    channel: u32,
    len: usize,
};

pub const ProtocolError = error{
    MalformedHeader,
    UnknownKind,
    PayloadTooLarge,
};

/// Writes one frame and flushes it. `payload` is ignored for every kind
/// but `.data`.
pub fn writeFrame(w: *std.Io.Writer, kind: Kind, channel: u32, payload: []const u8) std.Io.Writer.Error!void {
    const len: usize = if (kind == .data) payload.len else 0;
    try w.print("GW-Mux: {s} {d} {d}\r\n\r\n", .{ @tagName(kind), channel, len });
    if (len != 0) try w.writeAll(payload);
    try w.flush();
}

/// Reads and parses one frame header (the line plus its trailing blank
/// line). The caller then reads exactly `Header.len` payload bytes off
/// the same reader before calling this again.
pub fn readHeader(r: *std.Io.Reader) !Header {
    const line = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.StreamTooLong => return ProtocolError.MalformedHeader,
        else => |e| return e,
    };
    if (line.len > max_header_line) return ProtocolError.MalformedHeader;
    const hdr = try parseHeaderLine(line);

    // The blank line. `takeDelimiterInclusive` invalidates `line`, but
    // `hdr` is already fully parsed into scalars by now.
    const blank = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.StreamTooLong => return ProtocolError.MalformedHeader,
        else => |e| return e,
    };
    if (!std.mem.eql(u8, blank, "\r\n")) return ProtocolError.MalformedHeader;

    if (hdr.len > max_payload) return ProtocolError.PayloadTooLarge;
    return hdr;
}

fn parseHeaderLine(line_in: []const u8) !Header {
    var line = line_in;
    if (std.mem.endsWith(u8, line, "\r\n")) {
        line = line[0 .. line.len - 2];
    } else if (std.mem.endsWith(u8, line, "\n")) {
        line = line[0 .. line.len - 1];
    }

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const tag = it.next() orelse return ProtocolError.MalformedHeader;
    if (!std.mem.eql(u8, tag, "GW-Mux:")) return ProtocolError.MalformedHeader;

    const kind_str = it.next() orelse return ProtocolError.MalformedHeader;
    const channel_str = it.next() orelse return ProtocolError.MalformedHeader;
    const len_str = it.next() orelse return ProtocolError.MalformedHeader;
    if (it.next() != null) return ProtocolError.MalformedHeader;

    const kind = std.meta.stringToEnum(Kind, kind_str) orelse return ProtocolError.UnknownKind;
    const channel = std.fmt.parseInt(u32, channel_str, 10) catch return ProtocolError.MalformedHeader;
    const len = std.fmt.parseInt(usize, len_str, 10) catch return ProtocolError.MalformedHeader;

    return .{ .kind = kind, .channel = channel, .len = len };
}

/// One end of the trunk: a reader, a writer, and a mutex so the several
/// channel threads on this side can each emit `data` frames without
/// interleaving byte-wise. The reader is single-consumer (the demux loop)
/// and needs no lock.
pub const Trunk = struct {
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    write_mutex: std.Io.Mutex = .init,

    pub fn send(self: *Trunk, kind: Kind, channel: u32, payload: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        try writeFrame(self.writer, kind, channel, payload);
    }

    /// Splits `bytes` into `max_payload`-sized `data` frames. A zero-length
    /// `bytes` writes nothing (an empty write is not an EOF signal -- that
    /// is `close`).
    pub fn sendData(self: *Trunk, channel: u32, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const end = @min(bytes.len, off + max_payload);
            try self.send(.data, channel, bytes[off..end]);
            off = end;
        }
    }

    pub fn recvHeader(self: *Trunk) !Header {
        return readHeader(self.reader);
    }
};

/// The host-side view of one channel: a blocking byte queue fed by the
/// demux loop (`feed` / `closePeer`) and drained by the `Server`
/// connection thread through `ConnStream` (`read`). Writes from that
/// thread go straight back out as `data` frames (`writeAll`).
pub const Channel = struct {
    id: u32,
    trunk: *Trunk,
    io: std.Io,
    alloc: std.mem.Allocator,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    inbound: std.ArrayList(u8) = .empty,
    /// The remote end closed its socket, or the trunk died. Once set and
    /// `inbound` is drained, `read` reports EOF.
    peer_closed: bool = false,

    pub fn deinit(self: *Channel) void {
        self.inbound.deinit(self.alloc);
    }

    /// Demux loop: payload bytes arrived on the trunk for this channel.
    pub fn feed(self: *Channel, bytes: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.inbound.appendSlice(self.alloc, bytes);
        self.cond.signal(self.io);
    }

    /// Demux loop: the remote peer closed, or the trunk is gone. Wakes any
    /// `read` parked waiting for bytes.
    pub fn closePeer(self: *Channel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.peer_closed = true;
        self.cond.broadcast(self.io);
    }

    /// `ConnStream.read`: block until there are bytes to hand back or the
    /// peer has closed. Returns 0 only at a genuine end of stream, matching
    /// `std.Io.net.Stream.read`'s convention.
    pub fn read(self: *Channel, dst: []u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.inbound.items.len == 0 and !self.peer_closed) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        const n = @min(dst.len, self.inbound.items.len);
        if (n == 0) return 0;
        @memcpy(dst[0..n], self.inbound.items[0..n]);
        const rem = self.inbound.items.len - n;
        std.mem.copyForwards(u8, self.inbound.items[0..rem], self.inbound.items[n..]);
        self.inbound.shrinkRetainingCapacity(rem);
        return n;
    }

    /// `ConnStream.writeAll`: ship these bytes to the remote peer.
    pub fn writeAll(self: *Channel, bytes: []const u8) !void {
        try self.trunk.sendData(self.id, bytes);
    }

    /// `ConnStream.close`: the `Server` connection thread has returned;
    /// tell the remote peer so it can drop the matching socket. Best
    /// effort -- a dead trunk is already being torn down elsewhere.
    pub fn closeLocal(self: *Channel) void {
        self.trunk.send(.close, self.id, "") catch {};
    }
};
