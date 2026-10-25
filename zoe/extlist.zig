// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The extension list, `:extensions` or "List Extensions" in the
//! palette: every extension zoe could load -- the built-in ones and the
//! `.lua` files in the user's extension directory -- and what became of
//! each at startup.
//!
//! One row per extension: its name, where it comes from (built in, a
//! user file, or a user file standing in for a built-in one) and its
//! status. A failed one gets a second, dimmed row with the error. The
//! header names the directory user files are read from, so a file left
//! somewhere else is easy to spot.
//!
//! The popup is the finder's chrome (`applib/popupframe.zig`) without a
//! query line: there is nothing to filter in a list this short. Up/Down
//! and the page keys move, Escape closes, and Enter (or a click) on a
//! row with a user file reports `.accept` so the caller can open it.
//!
//! `build` is pure, so `tests/zoe_ext_tests.zig` covers the merging of
//! the three sources without a directory or a client.

const std = @import("std");
const glyphwire = @import("glyphwire");
const popupframe = @import("applib").popupframe;
const ext = @import("ext.zig");

const Color = glyphwire.Color;
const Batch = glyphwire.Client.Batch;
const TextOpts = glyphwire.Client.TextOpts;

pub const Rect = popupframe.Rect;
pub const Style = popupframe.Style;
pub const Outcome = popupframe.Outcome;

/// The header's one row: the title and the user directory.
pub const header_rows: usize = 1;

/// Centred like a dialog, wide enough for an error message.
pub const default_style: Style = .{
    .anchor = .center,
    .empty_text = "No extensions",
    .max_cols = 96,
    .max_rows = 16,
    .min_rows = 2,
};

/// Where an extension's source is.
pub const Origin = enum {
    built_in,
    user,
    /// A user file with a built-in one's name, which it replaces.
    user_over_built_in,
    /// Named in `config.extensions` but found nowhere.
    none,

    pub fn label(self: Origin) []const u8 {
        return switch (self) {
            .built_in => "built in",
            .user => "user file",
            .user_over_built_in => "user file, over built in",
            .none => "",
        };
    }
};

pub const Status = enum {
    loaded,
    /// Found but not in `config.extensions`.
    not_enabled,
    /// `name = false`.
    off,
    failed,
    not_found,
};

pub const Entry = struct {
    /// Owned.
    name: []const u8,
    origin: Origin,
    status: Status,
    /// Commands it registered, for `.loaded` (and `.failed`, which may
    /// have got some in before the error).
    commands: u32 = 0,
    /// The error, owned; null unless `.failed`.
    err: ?[]const u8 = null,
    /// The user file, absolute and owned; null without one.
    path: ?[]const u8 = null,

    /// Rows it takes: a failed one carries its error on a second.
    pub fn rows(self: *const Entry) usize {
        return if (self.status == .failed) 2 else 1;
    }

    /// The status column's text, into `buf`.
    pub fn statusText(self: *const Entry, buf: []u8) []const u8 {
        return switch (self.status) {
            .loaded => std.fmt.bufPrint(buf, "loaded, {d} command{s}", .{ self.commands, if (self.commands == 1) "" else "s" }) catch "loaded",
            .not_enabled => "not enabled",
            .off => "turned off",
            .failed => "failed",
            .not_found => "not found",
        };
    }
};

pub const List = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// The user extension directory as shown (`~` for `$HOME`), owned;
    /// null with no config directory.
    user_dir: ?[]const u8 = null,
    /// The highlighted entry.
    selected: usize = 0,
    /// The display row (not entry) at the top of the list.
    top: usize = 0,

    pub fn deinit(self: *List) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.name);
            if (e.err) |m| self.alloc.free(m);
            if (e.path) |p| self.alloc.free(p);
        }
        self.entries.deinit(self.alloc);
        if (self.user_dir) |d| self.alloc.free(d);
    }

    /// Display rows in all.
    pub fn rowCount(self: *const List) usize {
        var n: usize = 0;
        for (self.entries.items) |*e| n += e.rows();
        return n;
    }

    /// The display row entry `index` starts on.
    pub fn firstRow(self: *const List, index: usize) usize {
        var n: usize = 0;
        for (self.entries.items[0..index]) |*e| n += e.rows();
        return n;
    }

    /// The entry display row `row` belongs to (either of a failed
    /// one's two), or null past the end.
    pub fn entryAtRow(self: *const List, row: usize) ?usize {
        var start: usize = 0;
        for (self.entries.items, 0..) |*e, i| {
            if (row < start + e.rows()) return i;
            start += e.rows();
        }
        return null;
    }

    pub fn selectedEntry(self: *const List) ?*const Entry {
        if (self.selected >= self.entries.items.len) return null;
        return &self.entries.items[self.selected];
    }

    /// Moves the highlight `delta` entries, clamped at both ends.
    pub fn moveCursor(self: *List, delta: isize) void {
        const n = self.entries.items.len;
        if (n == 0) return;
        const target = @as(isize, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(target, 0, @as(isize, @intCast(n - 1))));
    }

    /// Keeps all of the highlighted entry's rows in a list `rows` tall.
    pub fn follow(self: *List, rows: usize) void {
        const e = self.selectedEntry() orelse return;
        const first = self.firstRow(self.selected);
        const last = first + e.rows();
        if (first < self.top) self.top = first;
        if (last > self.top + rows) self.top = last -| rows;
        self.clampScroll(rows);
    }

    pub fn clampScroll(self: *List, rows: usize) void {
        self.top = @min(self.top, self.rowCount() -| rows);
    }
};

/// The list from its three sources: the built-in names, the `.lua`
/// files found in `user_dir` (by name, without the extension), and what
/// the runtime made of `config.extensions` (empty when it never ran).
/// Sorted by name. `user_dir` is the directory as read, `shown_dir` as
/// the header puts it.
pub fn build(
    alloc: std.mem.Allocator,
    built_in: []const []const u8,
    user_files: []const []const u8,
    user_dir: ?[]const u8,
    shown_dir: ?[]const u8,
    enabled: []const ext.Enabled,
) !List {
    var list: List = .{ .alloc = alloc };
    errdefer list.deinit();
    if (shown_dir) |d| list.user_dir = try alloc.dupe(u8, d);

    // Every name once, from wherever it turned up.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for ([_][]const []const u8{ built_in, user_files }) |source| {
        for (source) |n| try appendNew(alloc, &names, n);
    }
    for (enabled) |e| try appendNew(alloc, &names, e.name);
    ext.sortNames(names.items);

    for (names.items) |name| {
        const is_built_in = contains(built_in, name);
        const is_user = contains(user_files, name);
        const origin: Origin = if (is_user and is_built_in)
            .user_over_built_in
        else if (is_user)
            .user
        else if (is_built_in)
            .built_in
        else
            .none;

        var entry: Entry = .{ .name = undefined, .origin = origin, .status = .not_enabled };
        for (enabled) |e| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            entry.status = switch (e.state) {
                .loaded => .loaded,
                .failed => .failed,
                .not_found => .not_found,
                .off => .off,
            };
            entry.commands = e.commands;
            break;
        }

        entry.name = try alloc.dupe(u8, name);
        errdefer alloc.free(entry.name);
        if (entry.status == .failed) {
            const e = findEnabled(enabled, name).?;
            entry.err = try shortError(alloc, e.err orelse "");
        }
        errdefer if (entry.err) |m| alloc.free(m);
        if (is_user) {
            if (user_dir) |dir| entry.path = try std.fmt.allocPrint(alloc, "{s}/{s}.lua", .{ dir, name });
        }
        errdefer if (entry.path) |p| alloc.free(p);
        try list.entries.append(alloc, entry);
    }
    return list;
}

/// A load error without the chunk name Lua puts in front of it: the row
/// above already names the extension, and Lua cuts a long path down to
/// its last 60 bytes anyway. `<chunk>.lua:3: boom` is `line 3: boom`;
/// anything else (an `error(msg, 0)`) is kept as it is. Owned.
pub fn shortError(alloc: std.mem.Allocator, err: []const u8) ![]u8 {
    const marker = ".lua:";
    const at = std.mem.indexOf(u8, err, marker) orelse return alloc.dupe(u8, err);
    const rest = err[at + marker.len ..];
    const digits = for (rest, 0..) |c, i| {
        if (!std.ascii.isDigit(c)) break i;
    } else rest.len;
    if (digits == 0 or !std.mem.startsWith(u8, rest[digits..], ": ")) return alloc.dupe(u8, err);
    return std.fmt.allocPrint(alloc, "line {s}: {s}", .{ rest[0..digits], rest[digits + 2 ..] });
}

fn appendNew(alloc: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    if (!contains(names.items, name)) try names.append(alloc, name);
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn findEnabled(enabled: []const ext.Enabled, name: []const u8) ?*const ext.Enabled {
    for (enabled) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// The extension names `<dir>/*.lua` offers: files (or links to them)
/// whose name `ext.validExtensionName` accepts. Owned, each and the
/// slice. A missing or unreadable directory is no names.
pub fn userFiles(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return names.toOwnedSlice(alloc);
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, e.name, ".lua")) continue;
        const stem = e.name[0 .. e.name.len - ".lua".len];
        if (!ext.validExtensionName(stem)) continue;
        const owned = try alloc.dupe(u8, stem);
        names.append(alloc, owned) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
    return names.toOwnedSlice(alloc);
}

pub fn freeNames(alloc: std.mem.Allocator, names: [][]const u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

pub const Popup = struct {
    chrome: popupframe.Chrome,
    /// Non-null exactly while the list is open.
    list: ?List = null,
    /// Needs a `render`, as the palette's flag.
    dirty: bool = false,

    /// Creates the popup's layers, hidden; call it where it should stack.
    pub fn init(client: *glyphwire.Client, style: Style) !Popup {
        return .{ .chrome = try .init(client, style, header_rows) };
    }

    pub fn setStyle(self: *Popup, style: Style) !void {
        try self.chrome.setStyle(style);
        self.dirty = true;
    }

    pub fn deinit(self: *Popup) void {
        if (self.list) |*l| l.deinit();
        self.list = null;
    }

    pub fn isOpen(self: *const Popup) bool {
        return self.list != null;
    }

    /// Shows `l`, taking ownership; replaces a list already open.
    pub fn open(self: *Popup, l: List) void {
        if (self.list) |*old| old.deinit();
        self.list = l;
        self.dirty = true;
    }

    pub fn close(self: *Popup) void {
        self.deinit();
        self.dirty = false;
        self.chrome.hide();
    }

    /// The highlighted entry's user file, if it has one. Read it before
    /// `close`.
    pub fn selectedPath(self: *const Popup) ?[]const u8 {
        const l = if (self.list) |*open_l| open_l else return null;
        const e = l.selectedEntry() orelse return null;
        return e.path;
    }

    /// Escape / Ctrl+C close, Enter accepts a row with a user file, the
    /// arrows (and Ctrl+P / Ctrl+N), the page keys and Home / End move.
    /// Takes every key: the popup is modal, like the palette.
    pub fn key(self: *Popup, k: glyphwire.KeyEvent) Outcome {
        const l = if (self.list) |*open_l| open_l else return .handled;
        const eq = std.mem.eql;
        const page: isize = @intCast(@max(self.chrome.list_rows, 1));
        const many: isize = @intCast(l.entries.items.len);

        if (eq(u8, k.key, "escape") or (k.mods.ctrl and eq(u8, k.key, "c"))) {
            self.close();
            return .closed;
        }
        if (eq(u8, k.key, "enter") or eq(u8, k.key, "kp_enter")) {
            return if (self.selectedPath() != null) .accept else .handled;
        }
        const step: ?isize = if (eq(u8, k.key, "up") or (k.mods.ctrl and eq(u8, k.key, "p")))
            -1
        else if (eq(u8, k.key, "down") or (k.mods.ctrl and eq(u8, k.key, "n")))
            1
        else if (eq(u8, k.key, "page_up"))
            -page
        else if (eq(u8, k.key, "page_down"))
            page
        else if (eq(u8, k.key, "home"))
            -many
        else if (eq(u8, k.key, "end"))
            many
        else
            null;
        if (step) |d| {
            l.moveCursor(d);
            l.follow(@max(self.chrome.list_rows, 1));
            self.dirty = true;
        }
        return .handled;
    }

    /// A left press: a row selects it, and accepts it when it has a user
    /// file; outside the popup closes it.
    pub fn click(self: *Popup, cell: glyphwire.CellPos) Outcome {
        const l = if (self.list) |*open_l| open_l else return .handled;
        switch (self.chrome.hit(cell)) {
            .outside => {
                self.close();
                return .closed;
            },
            .chrome => return .handled,
            .row => |i| {
                const index = l.entryAtRow(l.top + i) orelse return .handled;
                l.selected = index;
                self.dirty = true;
                return if (self.selectedPath() != null) .accept else .handled;
            },
        }
    }

    /// A `scroll_offset` event. True when it was this list's.
    pub fn scrolled(self: *Popup, so: glyphwire.ScrollOffsetEvent) bool {
        if (!self.chrome.isList(so.layer)) return false;
        if (self.list) |*l| {
            l.top = so.row;
            l.clampScroll(self.chrome.list_rows);
            self.dirty = true;
        }
        return true;
    }

    /// Places and draws the popup in `area`, as tall as its rows.
    pub fn render(self: *Popup, b: *Batch, area: Rect) !void {
        self.dirty = false;
        const l = if (self.list) |*open_l| open_l else return;
        const want = header_rows + @max(l.rowCount(), 1);
        if (!try self.chrome.place(b, area, want)) return;
        const cols = self.chrome.rect.cols;
        const list_rows = self.chrome.list_rows;
        l.clampScroll(list_rows);

        try self.renderHeader(b, l, cols);
        try self.renderList(b, l, cols, list_rows);
        try self.chrome.setListExtent(b, l.rowCount(), l.top);
    }

    /// "Extensions" and where user files are read from, with the
    /// position in the list at the right end.
    fn renderHeader(self: *Popup, b: *Batch, l: *const List, cols: usize) !void {
        const s = self.chrome.style;
        var right: [32]u8 = undefined;
        const n = l.entries.items.len;
        const tail = std.fmt.bufPrint(&right, " {d}/{d} ", .{ if (n == 0) 0 else l.selected + 1, n }) catch "";
        const tail_w = try self.chrome.drawRight(b, 0, tail, s.dim_fg, null);
        try b.writeSpans(&.{
            .{ .text = " Extensions", .fg = s.text_fg },
            .{ .text = if (l.user_dir != null) "   user files: " else "   no config directory", .fg = s.dim_fg },
            .{ .text = l.user_dir orelse "", .fg = s.dim_fg },
        }, .{ .layer = self.chrome.header_layer, .row = 0, .col = 0, .max_cols = cols -| tail_w, .pad = true });
    }

    /// The rows: name, origin and status in columns, and a failed
    /// entry's error dimmed under it.
    fn renderList(self: *Popup, b: *Batch, l: *const List, cols: usize, rows: usize) !void {
        const s = self.chrome.style;
        if (l.entries.items.len == 0) return self.chrome.drawEmpty(b);
        try b.clear(.{ .layer = self.chrome.list_layer });

        // Column widths from the widest name and origin, the name capped
        // so a long one can't push the status off the popup.
        var name_w: usize = 0;
        var origin_w: usize = 0;
        for (l.entries.items) |*e| {
            name_w = @max(name_w, glyphwire.stringWidth(e.name));
            origin_w = @max(origin_w, e.origin.label().len);
        }
        name_w = @min(name_w, 32);

        const error_fg: Color = .role(.message_error);
        for (0..rows) |i| {
            const row = l.top + i;
            const index = l.entryAtRow(row) orelse break;
            const e = &l.entries.items[index];
            const is_selected = index == l.selected;
            const bg: ?Color = if (is_selected) s.selected_bg else null;
            const opts: TextOpts = .{ .layer = self.chrome.list_layer, .row = i, .col = 0, .bg = bg, .max_cols = cols, .pad = true };

            if (row != l.firstRow(index)) {
                try b.writeSpans(&.{
                    .{ .text = "     " },
                    .{ .text = e.err orelse "" },
                }, withFg(opts, if (is_selected) s.selected_fg else s.dim_fg));
                continue;
            }

            var status_buf: [48]u8 = undefined;
            const status = e.statusText(&status_buf);
            const status_fg: Color = if (is_selected) s.selected_fg else switch (e.status) {
                .loaded => s.text_fg,
                .failed, .not_found => error_fg,
                .not_enabled, .off => s.dim_fg,
            };
            const origin_fg = if (is_selected) s.selected_fg else s.dim_fg;
            const name_fg = if (is_selected) s.selected_fg else s.text_fg;
            var pad_buf: [64]u8 = @splat(' ');
            const name_pad = (name_w + 2) -| glyphwire.stringWidth(e.name);
            const origin_pad = (origin_w + 2) - e.origin.label().len;
            try b.writeSpans(&.{
                .{ .text = " " },
                .{ .text = e.name, .fg = name_fg },
                .{ .text = pad_buf[0..@min(name_pad, pad_buf.len)] },
                .{ .text = e.origin.label(), .fg = origin_fg },
                .{ .text = pad_buf[0..@min(origin_pad, pad_buf.len)] },
                .{ .text = status, .fg = status_fg },
            }, withFg(opts, name_fg));
        }
    }

    fn withFg(opts: TextOpts, fg: Color) TextOpts {
        var o = opts;
        o.fg = fg;
        return o;
    }
};
