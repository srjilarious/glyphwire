// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Parsing `rg --json` into the outline `gw-grep` draws.
//!
//! Deliberately pure -- it takes bytes and returns a node list, with no
//! socket and no subprocess anywhere in it -- so `tests/grep_tests.zig`
//! can drive it against captured ripgrep output. `main.zig` owns the
//! spawning and the drawing.
//!
//! ripgrep emits one JSON object per line: `begin` (a file opens),
//! `match` (a line with hits, carrying `submatches` byte offsets),
//! `context` (a `-A`/`-B` line), `end`, `summary`. Lines arrive in file
//! order, so a context line is not attached to any particular match --
//! we collect every line of a file and then cut each match its own
//! window, which is why two hits close together each show the lines
//! between them.

const std = @import("std");

/// One line ripgrep reported, match or context.
pub const Line = struct {
    number: u64,
    /// Owned, newline stripped, tabs expanded.
    text: []u8,
    /// Byte ranges of the matched bytes within `text`, in order. Empty
    /// for a context line. Offsets are into ripgrep's original bytes,
    /// which `sanitize` keeps stable -- see its doc comment.
    submatches: []Range = &.{},

    pub fn deinit(self: Line, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.submatches);
    }
};

pub const Range = struct { start: usize, end: usize };

/// Everything ripgrep said about one file.
pub const FileHits = struct {
    /// Owned.
    path: []u8,
    /// Owned, in file order; match and context lines interleaved.
    lines: []Line,
    /// How many of `lines` are matches.
    match_count: usize,

    pub fn deinit(self: FileHits, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        for (self.lines) |l| l.deinit(alloc);
        alloc.free(self.lines);
    }
};

/// Replaces tabs with spaces and drops the other C0 control bytes, which
/// the grid would otherwise try to draw as literal cells.
///
/// **One byte in, one byte out**, so ripgrep's `submatches` offsets still
/// point at the same characters afterwards. That is why a tab becomes a
/// single space rather than expanding to a tab stop: getting the
/// highlight right on the matched bytes matters more than getting a
/// deeply indented line's leading whitespace to look exactly as it does
/// in the file.
pub fn sanitize(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, raw, "\r\n");
    const out = try alloc.alloc(u8, trimmed.len);
    for (trimmed, 0..) |c, i| {
        out[i] = if (c == '\t') ' ' else if (c < 0x20 or c == 0x7f) ' ' else c;
    }
    return out;
}

/// Accumulates ripgrep's event stream. Fed a line at a time so `main.zig`
/// can drain the pipe as it goes rather than buffering the whole run.
pub const Parser = struct {
    alloc: std.mem.Allocator,
    files: std.ArrayList(FileHits) = .empty,
    /// The file currently open (between `begin` and `end`).
    cur_path: ?[]u8 = null,
    cur_lines: std.ArrayList(Line) = .empty,
    cur_matches: usize = 0,
    /// Lines ripgrep reported that we could not decode as text (a binary
    /// file, or a non-UTF-8 path). Counted rather than guessed at.
    skipped: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Parser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Parser) void {
        for (self.files.items) |f| f.deinit(self.alloc);
        self.files.deinit(self.alloc);
        if (self.cur_path) |p| self.alloc.free(p);
        for (self.cur_lines.items) |l| l.deinit(self.alloc);
        self.cur_lines.deinit(self.alloc);
    }

    /// Feeds one `rg --json` line. An object we don't recognise, or one
    /// that is malformed, is skipped rather than failing the run --
    /// ripgrep is free to add event types, and one bad line shouldn't
    /// lose a whole search.
    pub fn feedLine(self: *Parser, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;

        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, trimmed, .{}) catch return;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        const kind = switch (root.get("type") orelse return) {
            .string => |s| s,
            else => return,
        };
        const data = switch (root.get("data") orelse return) {
            .object => |o| o,
            else => return,
        };

        if (std.mem.eql(u8, kind, "begin")) {
            try self.beginFile(data);
        } else if (std.mem.eql(u8, kind, "match")) {
            try self.addLine(data, true);
        } else if (std.mem.eql(u8, kind, "context")) {
            try self.addLine(data, false);
        } else if (std.mem.eql(u8, kind, "end")) {
            try self.endFile();
        }
    }

    /// Ends whatever file was still open. Call once the stream is done,
    /// before `take` -- ripgrep always sends `end`, but a killed or
    /// truncated run might not.
    pub fn finish(self: *Parser) !void {
        if (self.cur_path != null) try self.endFile();
    }

    /// Hands over the collected files; the caller frees them. The parser
    /// is empty afterwards and safe to `deinit`.
    pub fn take(self: *Parser) ![]FileHits {
        return self.files.toOwnedSlice(self.alloc);
    }

    fn beginFile(self: *Parser, data: std.json.ObjectMap) !void {
        if (self.cur_path != null) try self.endFile();
        const path = textOf(data.get("path")) orelse {
            self.skipped += 1;
            return;
        };
        self.cur_path = try self.alloc.dupe(u8, path);
        self.cur_matches = 0;
    }

    fn endFile(self: *Parser) !void {
        const path = self.cur_path orelse return;
        self.cur_path = null;
        // A file with no usable lines (binary, or every line skipped)
        // contributes nothing to the outline.
        if (self.cur_lines.items.len == 0) {
            self.alloc.free(path);
            return;
        }
        const lines = try self.cur_lines.toOwnedSlice(self.alloc);
        try self.files.append(self.alloc, .{
            .path = path,
            .lines = lines,
            .match_count = self.cur_matches,
        });
        self.cur_matches = 0;
    }

    fn addLine(self: *Parser, data: std.json.ObjectMap, is_match: bool) !void {
        if (self.cur_path == null) return;
        const raw = textOf(data.get("lines")) orelse {
            self.skipped += 1;
            return;
        };
        const number: u64 = switch (data.get("line_number") orelse return) {
            .integer => |n| if (n < 0) return else @intCast(n),
            else => return,
        };

        const text = try sanitize(self.alloc, raw);
        errdefer self.alloc.free(text);

        var ranges: []Range = &.{};
        if (is_match) {
            ranges = try self.parseSubmatches(data, text.len);
            self.cur_matches += 1;
        }
        errdefer self.alloc.free(ranges);

        try self.cur_lines.append(self.alloc, .{
            .number = number,
            .text = text,
            .submatches = ranges,
        });
    }

    /// The `submatches` byte ranges, clamped to the sanitized line so a
    /// highlight can never point past its own text.
    fn parseSubmatches(self: *Parser, data: std.json.ObjectMap, text_len: usize) ![]Range {
        const subs = switch (data.get("submatches") orelse return &.{}) {
            .array => |a| a,
            else => return &.{},
        };
        var out: std.ArrayList(Range) = .empty;
        errdefer out.deinit(self.alloc);
        for (subs.items) |item| {
            const o = switch (item) {
                .object => |x| x,
                else => continue,
            };
            const start = switch (o.get("start") orelse continue) {
                .integer => |n| if (n < 0) continue else @as(usize, @intCast(n)),
                else => continue,
            };
            const end = switch (o.get("end") orelse continue) {
                .integer => |n| if (n < 0) continue else @as(usize, @intCast(n)),
                else => continue,
            };
            if (start >= text_len or end <= start) continue;
            try out.append(self.alloc, .{ .start = start, .end = @min(end, text_len) });
        }
        return out.toOwnedSlice(self.alloc);
    }
};

/// ripgrep wraps every string as `{"text": "..."}`, or `{"bytes": "..."}`
/// (base64) when it isn't valid UTF-8. We only take the `text` form:
/// putting undecodable bytes on the grid would draw mojibake, and the
/// count of what was left out is reported instead (`Parser.skipped`).
fn textOf(v: ?std.json.Value) ?[]const u8 {
    const obj = switch (v orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("text") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The context window around a match: `before` lines up to it and `after`
/// lines past it, as `-B`/`-A` were given.
pub const Context = struct { before: u32, after: u32 };

/// Which lines of `file` belong under the match at `lines[match_idx]`:
/// the ones ripgrep actually reported inside the match's own window.
/// Returns the half-open index range into `file.lines`, match included.
pub fn windowFor(file: FileHits, match_idx: usize, ctx: Context) struct { start: usize, end: usize } {
    const centre = file.lines[match_idx].number;
    const lo = centre -| ctx.before;
    const hi = centre + ctx.after;

    var start = match_idx;
    while (start > 0 and file.lines[start - 1].number >= lo) start -= 1;
    var end = match_idx + 1;
    while (end < file.lines.len and file.lines[end].number <= hi) end += 1;
    return .{ .start = start, .end = end };
}
