// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Where zoe keeps the diagnostics its language servers publish, and the
//! queries the editor makes of them: what is on this row (the row painter,
//! once per visible row per frame), what is worst on this row (the sign
//! column), what is under the cursor (the statusline), and what is next
//! (`]d` / `[d`).
//!
//! **Keyed by `(path, server)`, replaced as a whole.** A server republishes
//! its entire set for a file every time -- a fixed problem is expressed by
//! its *absence* from the new list, not by a retraction -- so a publish
//! replaces that server's set and leaves every other server's alone. That is
//! also what lets basedpyright and ruff both report on one Python file
//! without either one erasing the other's findings.
//!
//! **Sorted, and that's the index.** Entries for a file are kept ordered by
//! (line, start character), so the row query is a binary search plus a walk
//! over one row's worth rather than a scan of the file's diagnostics, and
//! `]d` / `[d` are a step along the same order. There is no separate
//! line -> entries map to keep in sync; sorting once per publish is cheaper
//! than maintaining one, since a publish is the only thing that changes the
//! set.

const std = @import("std");
const lsp = @import("lsp.zig");

/// Which way `Store.step` walks. Named rather than an anonymous enum on the
/// parameter so a caller can hold one in a variable.
pub const Direction = enum { next, prev };

/// One stored diagnostic: the protocol's, plus which server it came from.
/// Everything it points at is owned by the `Store`.
pub const Entry = struct {
    range: lsp.Range,
    severity: lsp.Severity,
    message: []const u8,
    source: []const u8,
    code: ?[]const u8,
    /// The configured server name (`Set.server`), borrowed from the `Set`
    /// and valid as long as the store holds it.
    server: []const u8,

    fn deinit(self: *const Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.message);
        alloc.free(self.source);
        if (self.code) |c| alloc.free(c);
    }

    /// Sort key: up the file, then across the line. Two diagnostics at the
    /// same place order by severity so the worst is found first, which is
    /// what the sign column and the statusline both want.
    fn before(_: void, a: Entry, b: Entry) bool {
        if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
        if (a.range.start.character != b.range.start.character)
            return a.range.start.character < b.range.start.character;
        return @intFromEnum(a.severity) < @intFromEnum(b.severity);
    }
};

/// One server's whole set for one file.
const Set = struct {
    /// Absolute path, owned.
    path: []const u8,
    /// The server name, owned. `Entry.server` borrows it.
    server: []const u8,
    /// Sorted by `Entry.before`.
    items: []Entry,

    fn deinit(self: *Set, alloc: std.mem.Allocator) void {
        for (self.items) |*e| e.deinit(alloc);
        alloc.free(self.items);
        alloc.free(self.path);
        alloc.free(self.server);
    }
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    sets: std.ArrayList(Set) = .empty,

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        for (self.sets.items) |*s| s.deinit(self.alloc);
        self.sets.deinit(self.alloc);
    }

    /// Replaces what `server` last said about `path`.
    ///
    /// **Copies.** `items` and everything in it still belongs to the caller
    /// afterwards, success or failure. Moving the strings in instead would
    /// save a few hundred bytes per publish and buy a partial-failure case
    /// where some of them belong to the store and the rest to the caller,
    /// with no way to tell which -- not a trade worth making on a path that
    /// runs a few times a second at most.
    ///
    /// An empty `items` is meaningful and common: it is how a server says
    /// "this file is clean now".
    pub fn publish(
        self: *Store,
        path: []const u8,
        server: []const u8,
        items: []const lsp.Diagnostic,
    ) !void {
        const path_owned = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(path_owned);
        const server_owned = try self.alloc.dupe(u8, server);
        errdefer self.alloc.free(server_owned);

        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |*e| e.deinit(self.alloc);
            entries.deinit(self.alloc);
        }
        try entries.ensureTotalCapacityPrecise(self.alloc, items.len);
        for (items) |src| {
            const message = try self.alloc.dupe(u8, src.message);
            errdefer self.alloc.free(message);
            const source = try self.alloc.dupe(u8, src.source);
            errdefer self.alloc.free(source);
            const code: ?[]const u8 = if (src.code) |c| try self.alloc.dupe(u8, c) else null;
            entries.appendAssumeCapacity(.{
                .range = src.range,
                .severity = src.severity,
                .message = message,
                .source = source,
                .code = code,
                .server = server_owned,
            });
        }
        const owned = try entries.toOwnedSlice(self.alloc);
        errdefer {
            for (owned) |*e| e.deinit(self.alloc);
            self.alloc.free(owned);
        }
        std.mem.sort(Entry, owned, {}, Entry.before);

        // Replacing in place happens past the last fallible step, so a
        // failure can never leave the store holding a half-updated set.
        if (self.find(path, server)) |i| {
            self.sets.items[i].deinit(self.alloc);
            self.sets.items[i] = .{ .path = path_owned, .server = server_owned, .items = owned };
            return;
        }
        try self.sets.append(self.alloc, .{
            .path = path_owned,
            .server = server_owned,
            .items = owned,
        });
    }

    /// Drops everything one server published, for every file -- what a
    /// crashed server's diagnostics deserve, since nothing will update them
    /// again and stale marks are worse than none.
    pub fn clearServer(self: *Store, server: []const u8) void {
        var i: usize = 0;
        while (i < self.sets.items.len) {
            if (!std.mem.eql(u8, self.sets.items[i].server, server)) {
                i += 1;
                continue;
            }
            var set = self.sets.orderedRemove(i);
            set.deinit(self.alloc);
        }
    }

    /// Drops everything about one file -- on `:bd`, so a closed buffer's
    /// marks don't come back with the next buffer to reuse its slot.
    pub fn clearPath(self: *Store, path: []const u8) void {
        var i: usize = 0;
        while (i < self.sets.items.len) {
            if (!std.mem.eql(u8, self.sets.items[i].path, path)) {
                i += 1;
                continue;
            }
            var set = self.sets.orderedRemove(i);
            set.deinit(self.alloc);
        }
    }

    fn find(self: *const Store, path: []const u8, server: []const u8) ?usize {
        for (self.sets.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.path, path) and std.mem.eql(u8, s.server, server)) return i;
        }
        return null;
    }

    /// Every diagnostic on `path` that starts on `line`, appended to `out`
    /// (not cleared first). Across every server, worst severity first within
    /// a line -- so the row painter can paint in order and the last mark
    /// drawn is the most serious one.
    ///
    /// A multi-line diagnostic is reported on its *starting* line only. The
    /// mark on a row whose text a range merely passes through would say
    /// nothing the mark at its start doesn't, and a squiggle under an entire
    /// function body is noise.
    pub fn onLine(
        self: *const Store,
        path: []const u8,
        line: u32,
        out: *std.ArrayList(Entry),
        alloc: std.mem.Allocator,
    ) !void {
        for (self.sets.items) |set| {
            if (!std.mem.eql(u8, set.path, path)) continue;
            var i = lowerBound(set.items, line);
            while (i < set.items.len and set.items[i].range.start.line == line) : (i += 1) {
                try out.append(alloc, set.items[i]);
            }
        }
    }

    /// The worst severity of anything starting on `line`, or null for a
    /// clean line. What the sign column paints, so it deliberately does not
    /// allocate: it runs once per visible row per frame.
    pub fn worstOnLine(self: *const Store, path: []const u8, line: u32) ?lsp.Severity {
        var worst: ?lsp.Severity = null;
        for (self.sets.items) |set| {
            if (!std.mem.eql(u8, set.path, path)) continue;
            var i = lowerBound(set.items, line);
            while (i < set.items.len and set.items[i].range.start.line == line) : (i += 1) {
                const s = set.items[i].severity;
                if (worst == null or @intFromEnum(s) < @intFromEnum(worst.?)) worst = s;
            }
        }
        return worst;
    }

    /// The diagnostic to show in the statusline for a cursor at
    /// `(line, character)`: the most serious one whose range contains the
    /// cursor, falling back to the most serious one starting on the line.
    ///
    /// The fallback matters more than it looks: a server often reports a
    /// zero-width range at the point of an error, which no cursor is ever
    /// strictly "inside", and a message you can only see by landing on one
    /// exact column is a message nobody reads.
    pub fn atCursor(self: *const Store, path: []const u8, line: u32, character: u32) ?Entry {
        var best: ?Entry = null;
        var best_on_line: ?Entry = null;
        for (self.sets.items) |set| {
            if (!std.mem.eql(u8, set.path, path)) continue;
            var i = lowerBound(set.items, line);
            while (i < set.items.len and set.items[i].range.start.line == line) : (i += 1) {
                const e = set.items[i];
                if (best_on_line == null or @intFromEnum(e.severity) < @intFromEnum(best_on_line.?.severity))
                    best_on_line = e;
                const covers = character >= e.range.start.character and
                    (e.range.end.line > line or character <= e.range.end.character);
                if (!covers) continue;
                if (best == null or @intFromEnum(e.severity) < @intFromEnum(best.?.severity)) best = e;
            }
        }
        return best orelse best_on_line;
    }

    /// The next diagnostic after `(line, character)` in file order, or the
    /// previous one before it. Null when there is none that way -- the
    /// caller decides whether to wrap, which `]d` does and a plain search
    /// doesn't.
    pub fn step(
        self: *const Store,
        path: []const u8,
        line: u32,
        character: u32,
        dir: Direction,
    ) ?Entry {
        var best: ?Entry = null;
        for (self.sets.items) |set| {
            if (!std.mem.eql(u8, set.path, path)) continue;
            for (set.items) |e| {
                const after = e.range.start.line > line or
                    (e.range.start.line == line and e.range.start.character > character);
                const before = e.range.start.line < line or
                    (e.range.start.line == line and e.range.start.character < character);
                switch (dir) {
                    .next => {
                        if (!after) continue;
                        if (best == null or Entry.before({}, e, best.?)) best = e;
                    },
                    .prev => {
                        if (!before) continue;
                        if (best == null or Entry.before({}, best.?, e)) best = e;
                    },
                }
            }
        }
        return best;
    }

    /// The first diagnostic in the file, for `]d` wrapping round the end.
    pub fn first(self: *const Store, path: []const u8) ?Entry {
        var best: ?Entry = null;
        for (self.sets.items) |set| {
            if (!std.mem.eql(u8, set.path, path)) continue;
            if (set.items.len == 0) continue;
            const e = set.items[0];
            if (best == null or Entry.before({}, e, best.?)) best = e;
        }
        return best;
    }

    /// The last one, for `[d` wrapping round the start.
    pub fn last(self: *const Store, path: []const u8) ?Entry {
        var best: ?Entry = null;
        for (self.sets.items) |set| {
            if (!std.mem.eql(u8, set.path, path)) continue;
            if (set.items.len == 0) continue;
            const e = set.items[set.items.len - 1];
            if (best == null or Entry.before({}, best.?, e)) best = e;
        }
        return best;
    }

    /// How many errors and warnings a file has, for the statusline's
    /// summary. Information and hints are counted with the warnings: the
    /// number is there to be glanced at, and three numbers is not a glance.
    pub fn counts(self: *const Store, path: []const u8) struct { errors: usize, warnings: usize } {
        var errors: usize = 0;
        var warnings: usize = 0;
        for (self.sets.items) |set| {
            if (!std.mem.eql(u8, set.path, path)) continue;
            for (set.items) |e| {
                if (e.severity == .err) errors += 1 else warnings += 1;
            }
        }
        return .{ .errors = errors, .warnings = warnings };
    }
};

/// The first index in `items` (sorted by `Entry.before`) whose line is >=
/// `line`.
fn lowerBound(items: []const Entry, line: u32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].range.start.line < line) lo = mid + 1 else hi = mid;
    }
    return lo;
}
