// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The history behind Up and Down on the `:` and `/` lines -- one
//! `History` each, the way vim keeps its `:` and search histories apart.
//!
//! Browsing is vim's, prefix-filtered: whatever is on the line when Up is
//! first pressed is the filter, and Up/Down only stop on entries that
//! start with it. Down past the newest match puts that typed text back.
//! Any edit ends the browse, so the next Up filters on the line as it
//! stands then.
//!
//! The entries are shared by every buffer (`zoe/ui.zig` owns both and
//! points each `Editor` at them) and persisted through `applib/history`'s
//! file format, to `zoe_history` and `zoe_search_history` in the config
//! directory. Lines submitted since the last write are kept apart in
//! `pending` so the write can be `history.mergeSerialize` -- several zoe
//! windows then add to the file rather than each overwriting the others.
//!
//! Pure -- no IO; the UI reads and writes the files.

const std = @import("std");
const history = @import("applib").history;

pub const History = struct {
    alloc: std.mem.Allocator,
    /// Oldest first. Owned.
    entries: std.ArrayList([]u8) = .empty,
    /// Lines recorded since the file was last written, oldest first.
    /// Borrowed from `entries`'s strings, so they are only freed there --
    /// and `record` never drops an entry while one is pending.
    pending: std.ArrayList([]const u8) = .empty,
    /// The entry Up/Down is sitting on, or null when not browsing.
    pos: ?usize = null,
    /// What was on the line when browsing began: the filter, and what
    /// Down past the newest match restores. Owned.
    typed: std.ArrayList(u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) History {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.alloc.free(e);
        self.entries.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        self.typed.deinit(self.alloc);
    }

    /// Fills a fresh history from a history file's bytes. Startup only:
    /// called before anything is recorded.
    pub fn load(self: *History, bytes: []const u8) !void {
        std.debug.assert(self.entries.items.len == 0);
        const parsed = try history.parse(self.alloc, bytes);
        defer history.freeEntries(self.alloc, parsed);
        for (parsed) |p| {
            const owned = try self.alloc.dupe(u8, p);
            errdefer self.alloc.free(owned);
            try self.entries.append(self.alloc, owned);
        }
    }

    fn isPending(self: *const History, e: []const u8) bool {
        for (self.pending.items) |p| {
            if (p.ptr == e.ptr) return true;
        }
        return false;
    }

    /// Adds a submitted line, under `history.shouldRecord`'s rule: never a
    /// blank line, never the same line twice in a row. Ends any browse.
    pub fn record(self: *History, line: []const u8) !void {
        self.endBrowse();
        const prev: ?[]const u8 = if (self.entries.items.len > 0) self.entries.items[self.entries.items.len - 1] else null;
        if (!history.shouldRecord(prev, line)) return;
        const owned = try self.alloc.dupe(u8, line);
        errdefer self.alloc.free(owned);
        try self.entries.append(self.alloc, owned);
        errdefer _ = self.entries.pop();
        try self.pending.append(self.alloc, owned);
        // In memory the cap is applied lazily, and never to a pending
        // entry: the file write trims it again anyway.
        while (self.entries.items.len > history.max_entries and !self.isPending(self.entries.items[0])) {
            self.alloc.free(self.entries.orderedRemove(0));
        }
    }

    /// The file's new contents: `disk` (the file as it is now, re-read)
    /// with this session's pending lines merged on. Call `markWritten`
    /// once the bytes are on disk. Caller owns the result.
    pub fn serializeOnto(self: *const History, disk: []const u8) ![]u8 {
        return history.mergeSerialize(self.alloc, disk, self.pending.items);
    }

    pub fn markWritten(self: *History) void {
        self.pending.clearRetainingCapacity();
    }

    pub fn hasPending(self: *const History) bool {
        return self.pending.items.len > 0;
    }

    /// Up: the next older entry starting with the filter, or null when
    /// there is none (the line should then stay as it is). `current` is
    /// the line now; it becomes the filter if this starts a browse.
    pub fn older(self: *History, current: []const u8) !?[]const u8 {
        if (self.pos == null) {
            self.typed.clearRetainingCapacity();
            try self.typed.appendSlice(self.alloc, current);
        }
        var i = self.pos orelse self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (!std.mem.startsWith(u8, e, self.typed.items)) continue;
            // An entry identical to what is showing is skipped, so one Up
            // always changes the line when it can.
            if (self.pos == null and std.mem.eql(u8, e, current)) continue;
            self.pos = i;
            return e;
        }
        return null;
    }

    /// Down: the next newer matching entry, or -- past the newest -- the
    /// line as it was typed, which ends the browse. Null when not
    /// browsing (nothing to do).
    pub fn newer(self: *History) ?[]const u8 {
        const from = self.pos orelse return null;
        var i = from + 1;
        while (i < self.entries.items.len) : (i += 1) {
            const e = self.entries.items[i];
            if (!std.mem.startsWith(u8, e, self.typed.items)) continue;
            self.pos = i;
            return e;
        }
        self.pos = null;
        return self.typed.items;
    }

    /// Stops browsing: the line is the user's again, and the next Up
    /// takes whatever is on it as its filter.
    pub fn endBrowse(self: *History) void {
        self.pos = null;
    }
};
