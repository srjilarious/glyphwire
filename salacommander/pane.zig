// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! One side of the commander: a directory listing with a cursor, a scroll
//! position and a set of marked entries. No drawing happens here --
//! `ui.zig` reads a `Pane` and paints it -- so everything about moving
//! around, marking and navigating can be tested against a real temporary
//! directory without a window.
//!
//! Rows are the listing as shown: a `..` row first (except at `/`), then
//! directories, then everything else, each group name-sorted the way
//! `gw-ls` sorts. `cursor` and `top` index rows, not `entries`; the `..`
//! row has no entry and can't be marked.
//!
//! Marks follow Total Commander: Space toggles the mark on the cursor row,
//! Insert toggles it and steps down. An operation acts on the marked
//! entries, or on the cursor's entry when nothing is marked
//! (`selection`).

const std = @import("std");
const ls = @import("ls_support");

const lsentries = ls.entries;
pub const FileEntry = lsentries.FileEntry;
pub const EntryKind = lsentries.EntryKind;

pub const ViewMode = enum {
    /// One row per entry, a one-row icon.
    small,
    /// Two rows per entry: a tall icon, the name on the first row and
    /// permissions/owner on the second.
    large,

    pub fn rowHeight(self: ViewMode) usize {
        return switch (self) {
            .small => 1,
            .large => 2,
        };
    }
};

pub const Options = struct {
    show_hidden: bool = false,
    view: ViewMode = .small,
};

/// What activating the cursor row did.
pub const EnterResult = union(enum) {
    /// Nothing to do (an empty listing).
    none,
    /// The pane now shows another directory.
    changed_dir,
    /// The cursor is on a file; its absolute path, borrowed from the pane.
    file: []const u8,
};

pub const Pane = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Absolute, normalized. Owned.
    path: []u8,
    entries: []FileEntry = &.{},
    /// Parallel to `entries`.
    marked: []bool = &.{},
    cursor: usize = 0,
    top: usize = 0,
    view: ViewMode = .small,
    show_hidden: bool = false,

    /// Opens `path` (absolute or relative to the cwd). Fails if it can't
    /// be listed.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, path: []const u8, opts: Options) !Pane {
        var self: Pane = .{
            .alloc = alloc,
            .io = io,
            .path = try alloc.dupe(u8, ""),
            .view = opts.view,
            .show_hidden = opts.show_hidden,
        };
        errdefer self.deinit();
        try self.load(path);
        return self;
    }

    pub fn deinit(self: *Pane) void {
        self.freeListing();
        self.alloc.free(self.path);
    }

    fn freeListing(self: *Pane) void {
        lsentries.freeEntries(self.alloc, self.entries);
        self.alloc.free(self.marked);
        self.entries = &.{};
        self.marked = &.{};
    }

    // ── Rows ────────────────────────────────────────────────────────────

    pub fn hasParentRow(self: *const Pane) bool {
        return !std.mem.eql(u8, self.path, "/");
    }

    fn firstEntryRow(self: *const Pane) usize {
        return @intFromBool(self.hasParentRow());
    }

    pub fn rowCount(self: *const Pane) usize {
        return self.entries.len + self.firstEntryRow();
    }

    pub fn isParentRow(self: *const Pane, row: usize) bool {
        return self.hasParentRow() and row == 0;
    }

    /// The entry shown on `row`, or null for the `..` row or past the end.
    pub fn entryAt(self: *const Pane, row: usize) ?*const FileEntry {
        const first = self.firstEntryRow();
        if (row < first) return null;
        const i = row - first;
        if (i >= self.entries.len) return null;
        return &self.entries[i];
    }

    pub fn isMarked(self: *const Pane, row: usize) bool {
        const first = self.firstEntryRow();
        if (row < first) return false;
        const i = row - first;
        return i < self.marked.len and self.marked[i];
    }

    pub fn current(self: *const Pane) ?*const FileEntry {
        return self.entryAt(self.cursor);
    }

    /// The row showing an entry named `name`, if there is one.
    pub fn rowOf(self: *const Pane, name: []const u8) ?usize {
        for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return i + self.firstEntryRow();
        }
        return null;
    }

    /// The first row whose name starts with `prefix`, for type-to-find.
    /// ASCII case is ignored -- typing `r` should land on `README` --
    /// while anything above ASCII compares byte for byte, which is what
    /// prefix-matching an unnormalized filename can honestly promise.
    /// The `..` row never matches: it has no name to type.
    pub fn rowStartingWith(self: *const Pane, prefix: []const u8) ?usize {
        if (prefix.len == 0) return null;
        for (self.entries, 0..) |e, i| {
            if (e.name.len < prefix.len) continue;
            if (std.ascii.eqlIgnoreCase(e.name[0..prefix.len], prefix)) return i + self.firstEntryRow();
        }
        return null;
    }

    // ── Loading ─────────────────────────────────────────────────────────

    /// Replaces the listing with `path`'s. On failure the pane is left as
    /// it was, so a directory that can't be opened doesn't blank the side.
    /// The cursor goes to the top and all marks are dropped.
    pub fn load(self: *Pane, path: []const u8) !void {
        const abs = try lsentries.resolveAbsolutePath(self.io, self.alloc, path);
        errdefer self.alloc.free(abs);
        const entries = try self.readSorted(abs);
        errdefer lsentries.freeEntries(self.alloc, entries);
        const marked = try self.alloc.alloc(bool, entries.len);
        @memset(marked, false);

        self.freeListing();
        self.alloc.free(self.path);
        self.path = abs;
        self.entries = entries;
        self.marked = marked;
        self.cursor = 0;
        self.top = 0;
    }

    /// Re-reads the current directory, keeping the cursor on the entry it
    /// was on (or as near that row as the new listing allows) and the
    /// marks on entries that still exist.
    pub fn reload(self: *Pane) !void {
        const entries = try self.readSorted(self.path);
        errdefer lsentries.freeEntries(self.alloc, entries);
        const marked = try self.alloc.alloc(bool, entries.len);
        errdefer self.alloc.free(marked);

        for (entries, marked) |e, *m| {
            m.* = if (self.rowOf(e.name)) |row| self.isMarked(row) else false;
        }
        const old_name: ?[]u8 = if (self.current()) |e| try self.alloc.dupe(u8, e.name) else null;
        defer if (old_name) |n| self.alloc.free(n);
        const old_cursor = self.cursor;

        self.freeListing();
        self.entries = entries;
        self.marked = marked;
        self.cursor = if (old_name) |n| self.rowOf(n) orelse old_cursor else old_cursor;
        self.clampCursor();
    }

    fn readSorted(self: *Pane, path: []const u8) ![]FileEntry {
        const entries = try lsentries.listDir(self.io, self.alloc, path, .{
            .show_hidden = self.show_hidden,
            .stat = true,
        });
        sortDirsFirst(entries);
        return entries;
    }

    pub fn setShowHidden(self: *Pane, show: bool) !void {
        if (self.show_hidden == show) return;
        self.show_hidden = show;
        try self.reload();
    }

    // ── Cursor ──────────────────────────────────────────────────────────

    fn clampCursor(self: *Pane) void {
        const n = self.rowCount();
        self.cursor = if (n == 0) 0 else @min(self.cursor, n - 1);
    }

    pub fn setCursor(self: *Pane, row: usize) void {
        self.cursor = row;
        self.clampCursor();
    }

    pub fn moveCursor(self: *Pane, delta: i64) void {
        if (delta < 0) {
            self.cursor -|= @intCast(-delta);
        } else {
            self.cursor +|= @intCast(delta);
        }
        self.clampCursor();
    }

    pub fn cursorHome(self: *Pane) void {
        self.cursor = 0;
    }

    pub fn cursorEnd(self: *Pane) void {
        self.cursor = self.rowCount() -| 1;
    }

    /// Scrolls just far enough that the cursor is within the `visible`
    /// rows starting at `top`, and keeps `top` from leaving blank rows at
    /// the bottom when the listing is long enough to fill them.
    pub fn scrollIntoView(self: *Pane, visible: usize) void {
        const v = @max(visible, 1);
        if (self.cursor < self.top) self.top = self.cursor;
        if (self.cursor >= self.top + v) self.top = self.cursor + 1 - v;
        self.top = @min(self.top, self.rowCount() -| v);
    }

    /// Scrolls to `top` (a wheel or scrollbar drag) and drags the cursor
    /// along so it stays on screen.
    pub fn scrollTo(self: *Pane, top: usize, visible: usize) void {
        const v = @max(visible, 1);
        self.top = @min(top, self.rowCount() -| v);
        if (self.cursor < self.top) self.cursor = self.top;
        if (self.cursor >= self.top + v) self.cursor = self.top + v - 1;
        self.clampCursor();
    }

    // ── Marks ───────────────────────────────────────────────────────────

    pub fn toggleMark(self: *Pane, row: usize) void {
        const first = self.firstEntryRow();
        if (row < first) return;
        const i = row - first;
        if (i < self.marked.len) self.marked[i] = !self.marked[i];
    }

    pub fn markAll(self: *Pane) void {
        @memset(self.marked, true);
    }

    pub fn unmarkAll(self: *Pane) void {
        @memset(self.marked, false);
    }

    pub fn invertMarks(self: *Pane) void {
        for (self.marked) |*m| m.* = !m.*;
    }

    pub fn markedCount(self: *const Pane) usize {
        var n: usize = 0;
        for (self.marked) |m| n += @intFromBool(m);
        return n;
    }

    /// Total size of the marked entries. Directories count as their own
    /// inode size, not their contents -- summing a tree is a later feature.
    pub fn markedBytes(self: *const Pane) u64 {
        var total: u64 = 0;
        for (self.entries, self.marked) |e, m| {
            if (m) total +|= e.size;
        }
        return total;
    }

    /// Total size of everything listed, for the footer. Directories are
    /// left out: their own inode size says nothing about what they hold,
    /// and walking the tree would stall the pane on every directory
    /// change. Hidden entries count only when they're shown, since this
    /// is the size of the listing, not of the directory on disk.
    pub fn totalBytes(self: *const Pane) u64 {
        var total: u64 = 0;
        for (self.entries) |e| {
            if ((e.link_target_kind orelse e.kind) == .directory) continue;
            total +|= e.size;
        }
        return total;
    }

    /// What an operation should act on: the marked entries, or else the
    /// cursor's entry. Empty when nothing is marked and the cursor is on
    /// `..`. The paths are borrowed from the pane; the caller frees only
    /// the returned slice.
    pub fn selection(self: *const Pane, alloc: std.mem.Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(alloc);
        for (self.entries, self.marked) |e, m| {
            if (m) try out.append(alloc, e.abs_path);
        }
        if (out.items.len == 0) {
            if (self.current()) |e| try out.append(alloc, e.abs_path);
        }
        return out.toOwnedSlice(alloc);
    }

    // ── Navigation ──────────────────────────────────────────────────────

    /// Activates the cursor row: `..` goes up, a directory (or a link to
    /// one) is entered, a file is handed back for the caller to open.
    pub fn enter(self: *Pane) !EnterResult {
        if (self.isParentRow(self.cursor)) {
            _ = try self.upToParentDir();
            return .changed_dir;
        }
        const e = self.current() orelse return .none;
        if ((e.link_target_kind orelse e.kind) == .directory) {
            const target = try self.alloc.dupe(u8, e.abs_path);
            defer self.alloc.free(target);
            try self.load(target);
            return .changed_dir;
        }
        return .{ .file = e.abs_path };
    }

    /// Goes to the parent directory with the cursor on the directory just
    /// left, the way every two-pane commander does. False at `/`.
    pub fn upToParentDir(self: *Pane) !bool {
        if (!self.hasParentRow()) return false;
        const left = try self.alloc.dupe(u8, std.fs.path.basename(self.path));
        defer self.alloc.free(left);
        const parent = try self.alloc.dupe(u8, std.fs.path.dirname(self.path) orelse "/");
        defer self.alloc.free(parent);
        try self.load(parent);
        if (self.rowOf(left)) |row| self.cursor = row;
        return true;
    }
};

/// Directories (and links to them) first, then everything else; each
/// group in `gw-ls`'s name order.
pub fn sortDirsFirst(entries: []FileEntry) void {
    std.mem.sort(FileEntry, entries, {}, struct {
        fn isDir(e: FileEntry) bool {
            return (e.link_target_kind orelse e.kind) == .directory;
        }
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            const ad = isDir(a);
            const bd = isDir(b);
            if (ad != bd) return ad;
            return lsentries.nameLessThan(a.name, b.name);
        }
    }.lessThan);
}
