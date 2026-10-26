// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Where salacommander was left: each side's tabs, which one is shown,
//! and every tab's directory, cursor, view, sort and history (Back /
//! Forward's trail and Alt+Down's recent list), so the next launch opens
//! as the last one closed.
//!
//! Written on quit to `$XDG_STATE_HOME/glyphwire/salacommander/session.json`
//! (else `~/.local/state/...`), atomically, and read back at startup.
//! One file per user: with two salacommanders open, the last to quit is
//! the one remembered. `restore_session = false` in the config turns
//! both the reading and the writing off.
//!
//! A directory gone since is a tab dropped, not an error; a side left
//! with none opens where salacommander would have opened without a
//! session. A missing or malformed file is no session at all. Each
//! command-line directory, or with none the current directory on the
//! side that last had the keyboard, is then shown in its side's tab
//! already open there, else in a new tab after the restored shown one
//! (`Restored.focusOrOpen`), so the restored tabs stay as they were.
//!
//! `parse` / `serialize` and `capture` are pure, so
//! `tests/salacommander_tests.zig` round-trips them without a window.

const std = @import("std");
const pane_mod = @import("pane.zig");
const dirhistory = @import("dirhistory.zig");
const tabs_mod = @import("tabs.zig");
const homepath = @import("applib").homepath;

const Pane = pane_mod.Pane;

pub const file_name = "session.json";
pub const version: u32 = 1;

/// The file's size cap: a hundred tabs with full trails is well under.
const max_bytes = 4 * 1024 * 1024;

pub const Spot = struct {
    path: []const u8,
    cursor: ?[]const u8 = null,
};

pub const Tab = struct {
    path: []const u8,
    /// The entry the cursor was on.
    cursor: ?[]const u8 = null,
    view: pane_mod.ViewMode = .small,
    show_hidden: bool = false,
    sort: pane_mod.SortKey = .name,
    sort_dir: pane_mod.SortDir = .ascending,
    /// `DirHistory.trail` and `pos`.
    trail: []const Spot = &.{},
    pos: usize = 0,
    /// `DirHistory.recent`, newest first.
    recent: []const []const u8 = &.{},
};

pub const Side = struct {
    tabs: []Tab = &.{},
    /// The shown tab's index in `tabs`.
    active: usize = 0,
};

pub const Session = struct {
    version: u32 = version,
    /// The side with the keyboard.
    active: usize = 0,
    sides: []Side = &.{},
};

/// A parsed session and the memory it lives in.
pub const Loaded = struct {
    parsed: std.json.Parsed(Session),

    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
    }

    pub fn session(self: *Loaded) *Session {
        return &self.parsed.value;
    }
};

/// Parses a session file. Null for anything that isn't one this version
/// understands -- see the module doc.
pub fn parse(alloc: std.mem.Allocator, json: []const u8) ?Loaded {
    const parsed = std.json.parseFromSlice(Session, alloc, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    if (parsed.value.version != version or parsed.value.sides.len != 2) {
        parsed.deinit();
        return null;
    }
    return .{ .parsed = parsed };
}

/// The file's contents for `s`. Owned.
pub fn serialize(alloc: std.mem.Allocator, s: Session) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, s, .{ .whitespace = .indent_1 });
}

/// What `pane` would be restored from. Borrows the pane's strings; the
/// slices are allocated in `arena`.
pub fn captureTab(arena: std.mem.Allocator, pane: *const Pane) !Tab {
    const h = &pane.history;
    const trail = try arena.alloc(Spot, h.trail.items.len);
    for (h.trail.items, trail) |s, *out| out.* = .{ .path = s.path, .cursor = s.cursor };
    const cur = pane.current();
    return .{
        .path = pane.path,
        .cursor = if (cur) |e| e.name else null,
        .view = pane.view,
        .show_hidden = pane.show_hidden,
        .sort = pane.sort.key,
        .sort_dir = pane.sort.dir,
        .trail = trail,
        .pos = h.pos,
        .recent = h.recent.items,
    };
}

/// Both sides as they are now, with `active` the side with the keyboard.
/// Borrows from the panes; everything else is allocated in `arena`.
pub fn capture(
    arena: std.mem.Allocator,
    shown: *[2]Pane,
    sets: *[2]tabs_mod.TabSet(Pane),
    active: usize,
) !Session {
    const sides = try arena.alloc(Side, 2);
    for (sides, 0..) |*side, i| {
        const n = sets[i].count();
        const list = try arena.alloc(Tab, n);
        for (list, 0..) |*t, k| t.* = try captureTab(arena, sets[i].at(&shown[i], k));
        side.* = .{ .tabs = list, .active = sets[i].active };
    }
    return .{ .active = active, .sides = sides };
}

/// Opens `t` as a pane: its directory, view, hidden-file setting and
/// sort, its history put back, the cursor on its entry. Fails as
/// `Pane.init` does when the directory can't be listed.
pub fn openTab(alloc: std.mem.Allocator, io: std.Io, t: *const Tab) !Pane {
    var p = try Pane.init(alloc, io, t.path, .{ .show_hidden = t.show_hidden, .view = t.view });
    errdefer p.deinit();
    p.setSort(.{ .key = t.sort, .dir = t.sort_dir });
    try restoreHistory(&p.history, t);
    // The pane may have resolved the path differently (a link, a `..`):
    // it is where the trail stands now either way.
    try p.history.visit(p.path);
    if (t.cursor) |name| {
        if (p.rowOf(name)) |row| p.list.selected = row;
    }
    return p;
}

/// One side opened from a `Side`: the tab to show and the rest, in the
/// shape `Ui` keeps them.
pub const Restored = struct {
    shown: Pane,
    set: tabs_mod.TabSet(Pane) = .{},

    pub fn deinit(self: *Restored, alloc: std.mem.Allocator) void {
        self.shown.deinit();
        for (self.set.others.items) |*p| p.deinit();
        self.set.deinit(alloc);
    }

    /// Shows the tab already open on `dir`, or opens `dir` as a new tab
    /// right after the shown one, as Ctrl+T would. What a launch does
    /// with the directory it was started in or given, so restoring a
    /// session never buries where the user asked to be. Tabs are matched
    /// by `Pane.path`'s absolute form; a new tab takes `opts`, a found
    /// one keeps its own view and history.
    pub fn focusOrOpen(self: *Restored, alloc: std.mem.Allocator, io: std.Io, dir: []const u8, opts: pane_mod.Options) !void {
        const abs = try homepath.absolute(io, alloc, dir);
        defer alloc.free(abs);
        for (0..self.set.count()) |k| {
            if (std.mem.eql(u8, self.set.at(&self.shown, k).path, abs)) {
                _ = self.set.switchTo(&self.shown, k);
                return;
            }
        }
        var p = try Pane.init(alloc, io, abs, opts);
        errdefer p.deinit();
        try self.set.open(alloc, &self.shown, p);
    }
};

/// Opens every tab of `side` whose directory can still be listed, the
/// shown one shown again -- or, if it is the one gone, its right
/// neighbour, as closing it would have. Null when none opens.
pub fn openSide(alloc: std.mem.Allocator, io: std.Io, side: *const Side) !?Restored {
    var opened: std.ArrayList(Pane) = .empty;
    defer opened.deinit(alloc);
    errdefer for (opened.items) |*p| p.deinit();
    var active: usize = 0;
    for (side.tabs, 0..) |*t, k| {
        if (k == side.active) active = opened.items.len;
        var p = openTab(alloc, io, t) catch continue;
        opened.append(alloc, p) catch |err| {
            p.deinit();
            return err;
        };
    }
    if (opened.items.len == 0) return null;
    active = @min(active, opened.items.len - 1);

    var r: Restored = .{ .shown = opened.orderedRemove(active) };
    errdefer r.shown.deinit();
    r.set.others = .fromOwnedSlice(try opened.toOwnedSlice(alloc));
    r.set.active = active;
    return r;
}

/// Replaces `h`'s trail and recent list with `t`'s, capped as
/// `DirHistory` caps them. A `pos` past the end lands on the last spot.
pub fn restoreHistory(h: *dirhistory.DirHistory, t: *const Tab) !void {
    var fresh: dirhistory.DirHistory = .init(h.alloc);
    errdefer fresh.deinit();
    const trail = t.trail[t.trail.len -| dirhistory.max_trail ..];
    const dropped = t.trail.len - trail.len;
    for (trail) |s| {
        const path = try fresh.alloc.dupe(u8, s.path);
        errdefer fresh.alloc.free(path);
        const cursor = if (s.cursor) |c| try fresh.alloc.dupe(u8, c) else null;
        errdefer if (cursor) |c| fresh.alloc.free(c);
        try fresh.trail.append(fresh.alloc, .{ .path = path, .cursor = cursor });
    }
    fresh.pos = @min(t.pos -| dropped, fresh.trail.items.len -| 1);
    for (t.recent[0..@min(t.recent.len, dirhistory.max_recent)]) |r| {
        const path = try fresh.alloc.dupe(u8, r);
        errdefer fresh.alloc.free(path);
        try fresh.recent.append(fresh.alloc, path);
    }
    h.deinit();
    h.* = fresh;
}

/// `$XDG_STATE_HOME/glyphwire/salacommander`, else
/// `$HOME/.local/state/glyphwire/salacommander`. Owned; null with
/// neither set.
pub fn dirPath(alloc: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    if (environ.get("XDG_STATE_HOME")) |xdg| {
        if (xdg.len > 0) return try std.fs.path.join(alloc, &.{ xdg, "glyphwire", "salacommander" });
    }
    const home = environ.get("HOME") orelse return null;
    return try std.fs.path.join(alloc, &.{ home, ".local", "state", "glyphwire", "salacommander" });
}

/// Reads the session in `dir`, or null when there is none to use.
pub fn load(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) ?Loaded {
    const path = std.fs.path.join(alloc, &.{ dir, file_name }) catch return null;
    defer alloc.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_bytes)) catch return null;
    defer alloc.free(bytes);
    return parse(alloc, bytes);
}

/// Writes `s` to `dir`, atomically, creating `dir` (`0700`) first: the
/// paths in it are nobody else's business.
pub fn save(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, s: Session) !void {
    const json = try serialize(alloc, s);
    defer alloc.free(json);
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, dir, .fromMode(0o700));
    var d = try cwd.openDir(io, dir, .{});
    defer d.close(io);
    var af = try d.createFileAtomic(io, file_name, .{ .permissions = .fromMode(0o600), .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, json);
    try af.replace(io);
}
