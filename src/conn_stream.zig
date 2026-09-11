//! `ConnStream` -- the byte-stream a `Server` connection reads and writes,
//! independent of where the peer actually is.
//!
//! Local clients arrive as `.net` (a real `std.Io.net.Stream` off the
//! Unix socket). A remote client, riding a `gw-agent` trunk, arrives as
//! `.channel` (one `mux.Channel`, fed by the host's demux loop). The
//! `Server`'s per-connection dispatch loop is written against this type
//! and never has to care which it is; `wire.readRaw`'s image side-channel
//! read goes through it too.

const std = @import("std");
const mux = @import("mux.zig");

pub const ConnStream = union(enum) {
    net: std.Io.net.Stream,
    channel: *mux.Channel,

    /// Reads up to `dst.len` bytes. Returns 0 only at end of stream, the
    /// same convention as `std.Io.net.Stream.read`.
    pub fn read(self: *ConnStream, io: std.Io, dst: []u8) !usize {
        switch (self.*) {
            .net => |s| {
                var data: [1][]u8 = .{dst};
                return s.read(io, &data);
            },
            .channel => |ch| return ch.read(dst),
        }
    }

    /// Writes every byte of `bytes`. `bytes` may exceed any internal
    /// buffer; it is drained in pieces as needed.
    pub fn writeAll(self: *ConnStream, io: std.Io, bytes: []const u8) !void {
        switch (self.*) {
            .net => |s| {
                var buf: [4096]u8 = undefined;
                var w = s.writer(io, &buf);
                try w.interface.writeAll(bytes);
                try w.interface.flush();
            },
            .channel => |ch| try ch.writeAll(bytes),
        }
    }

    pub fn close(self: *ConnStream, io: std.Io) void {
        switch (self.*) {
            .net => |s| s.close(io),
            .channel => |ch| ch.closeLocal(),
        }
    }
};
