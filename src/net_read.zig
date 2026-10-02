// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! `readSome` -- the one place glyphwire reads a `std.Io.net.Stream`.
//!
//! Zig 0.17.0's `std.Io.net.Stream.read` does not compile: it destructures
//! the `net_read` result as a tuple (`const rc, _ = ...`), but that result
//! is the `Stream.ReadResult` struct. `readWithControl` returns the struct
//! as-is, so this goes through it with an empty control buffer and hands
//! back `data_len`. Once upstream fixes `read`, this can call it directly.

const std = @import("std");

/// Reads into `data`, returning the number of payload bytes received.
/// Returns 0 only at end of stream, the same convention as
/// `std.Io.net.Stream.read`.
pub fn readSome(stream: std.Io.net.Stream, io: std.Io, data: [][]u8) std.Io.net.Stream.Reader.Error!usize {
    const result = try stream.readWithControl(io, data, &.{});
    return result.data_len;
}
