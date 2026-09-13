// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Where you left off: a small JSON file mapping a book's path to the
//! page, zoom mode and reading direction it was last closed at, so
//! reopening a volume resumes instead of starting over.
//!
//! Lives next to the shell's history at `~/.config/glyphwire/read.state.json`
//! -- `configDirPath` is the one directory every glyphwire binary already
//! agrees on, and adding a second (`$XDG_STATE_HOME`) convention for one
//! file isn't worth the divergence.
//!
//! `parse` / `serialize` are pure so `tests/read_tests.zig` can round-trip
//! them; `load` / `save` are the thin IO wrappers around them. A missing,
//! unreadable or malformed file is an empty store, never an error: losing
//! your place is a nuisance, not a reason to refuse to open a book.

const std = @import("std");

pub const file_name = "read.state.json";

/// One book's remembered position. `mode` and `direction` are stored as
/// their enum names rather than as integers so the file survives a
/// reordering of either enum.
pub const Bookmark = struct {
    page: usize = 0,
    mode: []const u8 = "fit_screen",
    direction: []const u8 = "rtl",
};

/// The whole file: book path -> bookmark. Backed by an arena because the
/// parsed JSON's strings and the ones a caller `record`s have to outlive
/// the parse, and there are at most a few hundred of them.
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringArrayHashMapUnmanaged(Bookmark) = .empty,

    /// Books kept in the file. Older entries past this are dropped on
    /// save, oldest-recorded first, so a state file read every launch
    /// doesn't grow without bound.
    pub const max_entries: usize = 500;

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{ .arena = .init(alloc) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    pub fn get(self: *const Store, path: []const u8) ?Bookmark {
        return self.entries.get(path);
    }

    /// Records (or replaces) a book's position. Re-recording moves the
    /// entry to the end, which is what makes the trim on save drop the
    /// least recently *read* book rather than the least recently added.
    pub fn record(self: *Store, path: []const u8, mark: Bookmark) !void {
        const alloc = self.arena.allocator();
        if (self.entries.orderedRemove(path)) {
            // Removed so the re-insert lands at the end; the old key's
            // memory stays in the arena, which is fine for a store that
            // is rebuilt from disk each run.
        }
        try self.entries.put(alloc, try alloc.dupe(u8, path), .{
            .page = mark.page,
            .mode = try alloc.dupe(u8, mark.mode),
            .direction = try alloc.dupe(u8, mark.direction),
        });
    }
};

/// Parses the state file's contents. Anything that isn't a JSON object of
/// objects yields an empty store rather than an error -- see the module
/// comment.
pub fn parse(alloc: std.mem.Allocator, json: []const u8) Store {
    var store: Store = .init(alloc);
    const a = store.arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return store;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return store,
    };

    var it = root.iterator();
    while (it.next()) |kv| {
        const obj = switch (kv.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };
        const page: usize = switch (obj.get("page") orelse std.json.Value{ .integer = 0 }) {
            .integer => |n| if (n < 0) 0 else @intCast(n),
            else => 0,
        };
        const mode = stringField(obj, "mode") orelse "fit_screen";
        const direction = stringField(obj, "direction") orelse "rtl";

        const key = a.dupe(u8, kv.key_ptr.*) catch continue;
        store.entries.put(a, key, .{
            .page = page,
            .mode = a.dupe(u8, mode) catch continue,
            .direction = a.dupe(u8, direction) catch continue,
        }) catch continue;
    }
    return store;
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Renders the store back to JSON, newest `Store.max_entries` kept. The
/// caller owns the result.
pub fn serialize(alloc: std.mem.Allocator, store: *const Store) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    const total = store.entries.count();
    const first = total -| Store.max_entries;

    try w.writeAll("{\n");
    var written: usize = 0;
    for (store.entries.keys()[first..], store.entries.values()[first..]) |key, mark| {
        if (written > 0) try w.writeAll(",\n");
        written += 1;
        try w.writeAll("  ");
        try std.json.Stringify.encodeJsonString(key, .{}, w);
        try w.print(": {{ \"page\": {d}, \"mode\": ", .{mark.page});
        try std.json.Stringify.encodeJsonString(mark.mode, .{}, w);
        try w.writeAll(", \"direction\": ");
        try std.json.Stringify.encodeJsonString(mark.direction, .{}, w);
        try w.writeAll(" }");
    }
    try w.writeAll("\n}\n");
    return out.toOwnedSlice();
}

/// Reads the state file, or an empty store when there isn't one.
pub fn load(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) Store {
    const path = std.fs.path.join(alloc, &.{ dir, file_name }) catch return .init(alloc);
    defer alloc.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024)) catch
        return .init(alloc);
    defer alloc.free(bytes);

    return parse(alloc, bytes);
}

/// Writes the state file, creating the config directory if it isn't there
/// yet. Best effort: a failure here is reported to the caller but the
/// reader treats it as "your place wasn't saved", not a fatal error.
pub fn save(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, store: *const Store) !void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    const path = try std.fs.path.join(alloc, &.{ dir, file_name });
    defer alloc.free(path);

    const json = try serialize(alloc, store);
    defer alloc.free(json);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}
