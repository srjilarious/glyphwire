// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure helpers for glyphwire-shell's persistent command history
//! (`~/.config/glyphwire/history`). No IO: `shell/main.zig` reads and
//! writes the file, this module only turns bytes into entries and back.
//!
//! The persisted history mirrors the shape `Prompt.submitLine` keeps the
//! in-memory list in: blank lines are never recorded, a line identical to
//! the one right before it is dropped (bash `ignoredups`), and only the
//! most recent `max_entries` are kept -- enforced every time the file is
//! rewritten (once at startup, then after each submitted line).

const std = @import("std");

/// Upper bound on entries kept in the history file. `parse` trims older
/// entries past this on load; `serialize` trims again on write, so the
/// file can only briefly exceed it within a single session.
pub const max_entries: usize = 5000;

/// Splits the raw file bytes into individual command lines, oldest first.
/// Blank lines are skipped, consecutive duplicates collapse to one, and
/// only the last `max_entries` survive. Every returned slice is an owned
/// dup and so is the outer slice -- the caller frees each entry and the
/// slice (see `freeEntries`).
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |it| alloc.free(it);
        list.deinit(alloc);
    }

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (list.items.len > 0 and std.mem.eql(u8, list.items[list.items.len - 1], line)) continue;
        try list.append(alloc, try alloc.dupe(u8, line));
    }

    if (list.items.len > max_entries) {
        const drop = list.items.len - max_entries;
        for (list.items[0..drop]) |old| alloc.free(old);
        std.mem.copyForwards([]const u8, list.items, list.items[drop..]);
        list.shrinkRetainingCapacity(max_entries);
    }

    return list.toOwnedSlice(alloc);
}

/// Frees a slice returned by `parse`.
pub fn freeEntries(alloc: std.mem.Allocator, entries: [][]const u8) void {
    for (entries) |e| alloc.free(e);
    alloc.free(entries);
}

/// Whether `line` should be appended to the history given `prev`, the
/// current newest entry (null if the history is empty). The same rule
/// `parse` applies: non-blank and not identical to the entry before it.
pub fn shouldRecord(prev: ?[]const u8, line: []const u8) bool {
    if (line.len == 0) return false;
    if (prev) |p| return !std.mem.eql(u8, p, line);
    return true;
}

/// Renders `entries` back to file bytes: one entry per line, each
/// terminated by `\n`, keeping only the last `max_entries`. Caller owns
/// the result.
pub fn serialize(alloc: std.mem.Allocator, entries: []const []const u8) ![]u8 {
    const start = if (entries.len > max_entries) entries.len - max_entries else 0;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (entries[start..]) |e| {
        try out.appendSlice(alloc, e);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Merges `pending` -- the lines this session has submitted since its
/// last flush, oldest first -- onto `disk_bytes`, the file's *current*
/// contents re-read at flush time, and renders the result back to file
/// bytes.
///
/// This is what keeps several shells in one `gmux` session from
/// clobbering each other. The old flush rendered the whole in-memory
/// history, which includes the snapshot taken when *this* shell started:
/// writing that back silently reverted every line any other shell had
/// added since. Re-reading first and appending only this session's new
/// lines means the last writer adds to the file instead of replacing it.
///
/// Interleaving is by flush, not by timestamp -- the history format
/// carries no times, so a session's lines land as a contiguous block
/// wherever it happens to flush. Two shells' commands therefore end up
/// grouped rather than strictly chronological, which is the right
/// trade for recall (a shell's own recent lines stay together) and the
/// only option the file format allows.
///
/// `shouldRecord`'s consecutive-duplicate rule is applied across the
/// join too, so a line already sitting at the end of the file isn't
/// duplicated by a session that also ran it. Caller owns the result.
pub fn mergeSerialize(alloc: std.mem.Allocator, disk_bytes: []const u8, pending: []const []const u8) ![]u8 {
    const disk = try parse(alloc, disk_bytes);
    defer freeEntries(alloc, disk);

    var merged: std.ArrayList([]const u8) = .empty;
    defer merged.deinit(alloc);
    try merged.appendSlice(alloc, disk);
    for (pending) |line| {
        const prev: ?[]const u8 = if (merged.items.len > 0) merged.items[merged.items.len - 1] else null;
        if (!shouldRecord(prev, line)) continue;
        try merged.append(alloc, line);
    }

    return serialize(alloc, merged.items);
}
