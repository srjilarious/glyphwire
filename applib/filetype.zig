// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! What zoe will open. Today that is one question -- "is this text?" --
//! and one answer for everything else: an error in the statusline.
//!
//! zoe is a text editor, and loading a PNG into a gap buffer produces a
//! screenful of replacement characters, a parse the highlighter can make
//! nothing of, and a buffer `:w` would happily write back mangled. So
//! `openFile` asks here first and refuses rather than pretending.
//!
//! Refusing is deliberately the *whole* of it for now: an image belongs
//! in a preview pane and a binary in a hex view, and both are their own
//! piece of work. This is the seam they will hang off when they land --
//! the answer grows from "text or not" into "which viewer", and the
//! callers in `ui.zig` are already the places that decide.
//!
//! salacommander's F4 asks the same question before starting the editor,
//! so a file zoe would refuse is refused in the file manager instead of
//! in an editor that opened only to say no.

const std = @import("std");

/// How much of a file is looked at. The head is enough -- every format
/// that isn't text puts something non-textual in its first few bytes,
/// and reading further to be sure would mean reading the whole file
/// before deciding not to open it.
pub const sniff_bytes: usize = 8 * 1024;

/// Whether `head` (the first `sniff_bytes` of a file, or all of it when
/// it is shorter) looks like something other than text.
///
/// The test is a NUL byte, which is what git, grep and less all use in
/// one form or another. It catches images, executables and archives
/// without rejecting the things a stricter test would: a latin-1 source
/// file, a file with CRLF line endings, one with a stray control
/// character in it. An empty file is text -- that is a new file, not a
/// binary one.
pub fn looksBinary(head: []const u8) bool {
    const n = @min(head.len, sniff_bytes);
    return std.mem.indexOfScalar(u8, head[0..n], 0) != null;
}

/// `looksBinary` over the file at `path`, reading only its head -- for a
/// caller that decides before loading anything (salacommander's F4),
/// where zoe already has the whole file in hand.
pub fn fileLooksBinary(io: std.Io, path: []const u8) !bool {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [sniff_bytes]u8 = undefined;
    var r = file.reader(io, &.{});
    const n = r.interface.readSliceShort(&buf) catch return error.ReadFailed;
    return looksBinary(buf[0..n]);
}
