// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's `:` command line glue: filename completion and its path menu
//! (on `pathmenu.zig`), and loading and flushing the per-mode command
//! histories (on `cmdhistory.zig`). `Ui` methods moved out of ui.zig and
//! aliased back.

const std = @import("std");
const glyphwire = @import("glyphwire");
const display = @import("display.zig");
const homepath = @import("applib").homepath;
const cmdhistory = @import("cmdhistory.zig");
const pathmenu = @import("pathmenu.zig");
const pathcomplete = @import("applib").pathcomplete;
const lineedit = @import("applib").lineedit;

const ui = @import("ui.zig");
const Ui = ui.Ui;
const complete_max_cols = ui.complete_max_cols;
const complete_max_rows = ui.complete_max_rows;
const role = ui.role;

/// The `:` line's keys that are completion's rather than the line's:
/// Tab always, and with the popup up the keys that drive it. Returns
/// whether the key was taken. See `zoe/pathmenu.zig`.
pub fn cmdlineKey(self: *Ui, k: glyphwire.KeyEvent) !bool {
    const eq = std.mem.eql;
    const key = k.key;
    if (self.path_menu) |*m| {
        const rows = self.pathMenuRows();
        if ((eq(u8, key, "tab") and !k.mods.shift) or eq(u8, key, "down")) {
            m.move(1, rows);
            self.path_menu_dirty = true;
            return true;
        }
        if ((eq(u8, key, "tab") and k.mods.shift) or eq(u8, key, "up")) {
            m.move(-1, rows);
            self.path_menu_dirty = true;
            return true;
        }
        // Enter takes the pick into the line; it never runs the
        // command, so a pick can still be edited or Tab'd further.
        if (eq(u8, key, "enter")) {
            try self.acceptPathPick();
            return true;
        }
        // Escape closes the popup and leaves the `:` line as it is.
        if (eq(u8, key, "escape")) {
            self.closePathMenu();
            return true;
        }
        return false;
    }
    if (eq(u8, key, "tab") and !k.mods.ctrl and !k.mods.alt) {
        try self.completePath();
        return true;
    }
    return false;
}

/// Tab on the `:` line with no popup up. One match is filled in
/// outright; several fill in their common prefix and open the popup.
/// Nothing happens off a path argument or with no match.
pub fn completePath(self: *Ui) !void {
    const cmd = &self.buf.ed.cmdline;
    const t = pathmenu.target(cmd.text(), cmd.caret) orelse return;
    const matches = try self.scanPathMatches(t);
    if (matches.len == 0) {
        pathcomplete.freeMatches(self.alloc, matches);
        return;
    }
    if (matches.len == 1) {
        defer pathcomplete.freeMatches(self.alloc, matches);
        const ins = try pathmenu.insertion(self.alloc, matches[0]);
        defer self.alloc.free(ins);
        try self.replaceCmdline(t.seg_start, cmd.caret, ins);
        return;
    }

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.alloc);
    for (matches) |m| try names.append(self.alloc, m.name);
    const lcp = pathcomplete.commonPrefixLen(names.items);
    if (lcp > t.prefix.len) {
        // `matches` is owned by the popup from here, so copy the
        // prefix out before the line edit could move anything.
        const shared = try self.alloc.dupe(u8, matches[0].name[0..lcp]);
        defer self.alloc.free(shared);
        try self.replaceCmdline(t.seg_start, cmd.caret, shared);
    }
    self.closePathMenu();
    self.path_menu = pathmenu.Menu.init(self.alloc, matches, t.seg_start);
    self.path_menu_dirty = true;
}

/// Enter in the popup: the pick replaces the segment. A directory
/// goes straight on to listing its own entries, the way picking a
/// folder in a file dialog opens it.
pub fn acceptPathPick(self: *Ui) !void {
    const m = self.path_menu orelse return;
    const pick = m.current() orelse return self.closePathMenu();
    const ins = try pathmenu.insertion(self.alloc, pick);
    defer self.alloc.free(ins);
    const is_dir = pick.is_dir;
    const start = m.seg_start;
    self.closePathMenu();
    try self.replaceCmdline(start, self.buf.ed.cmdline.caret, ins);
    if (is_dir) try self.completePath();
    self.status_dirty = true;
}

/// After the `:` line changed under an open popup (typing, Backspace,
/// a caret move): re-list against what the caret is now on, closing
/// the popup once there is nothing to list or the line is gone.
pub fn syncPathMenu(self: *Ui) !void {
    if (self.path_menu == null) return;
    if (self.focus != .buffer or self.buf.ed.mode != .command) return self.closePathMenu();
    const cmd = &self.buf.ed.cmdline;
    const t = pathmenu.target(cmd.text(), cmd.caret) orelse return self.closePathMenu();
    const matches = try self.scanPathMatches(t);
    if (matches.len == 0) {
        pathcomplete.freeMatches(self.alloc, matches);
        return self.closePathMenu();
    }
    self.closePathMenu();
    self.path_menu = pathmenu.Menu.init(self.alloc, matches, t.seg_start);
    self.path_menu_dirty = true;
}

pub fn closePathMenu(self: *Ui) void {
    if (self.path_menu) |*m| {
        m.deinit();
        self.path_menu = null;
        self.path_menu_dirty = true;
    }
}

/// The entries `t` can complete to, read from its directory with `~`
/// expanded. Caller owns the result (`pathcomplete.freeMatches`).
pub fn scanPathMatches(self: *Ui, t: pathmenu.Target) ![]pathcomplete.Match {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = homepath.expandHome(t.dir, self.environ.get("HOME"), &home_buf);
    const all = try pathcomplete.scanDir(self.alloc, self.io, dir, t.prefix);
    return if (t.dirs_only) pathmenu.keepDirs(self.alloc, all) else all;
}

/// Replaces bytes `[start, end)` of the `:` line with `text`, leaving
/// the caret just after it.
pub fn replaceCmdline(self: *Ui, start: usize, end: usize, text: []const u8) !void {
    const cmd = &self.buf.ed.cmdline;
    const line = cmd.text();
    const joined = try std.mem.concat(self.alloc, u8, &.{ line[0..start], text, line[end..] });
    defer self.alloc.free(joined);
    try cmd.setText(self.alloc, joined);
    _ = cmd.moveTo(start + text.len);
    self.status_dirty = true;
}

/// Rows the popup shows: as many matches as fit above the statusline,
/// up to the completion popup's limit.
pub fn pathMenuRows(self: *const Ui) usize {
    const m = self.path_menu orelse return 0;
    return @min(@min(m.count(), complete_max_rows), self.status_bounds.row);
}

/// Draws the filename popup, or hides it: one name per row, a
/// directory with its `/`, standing on the statusline with its names
/// lined up over the segment they would replace.
pub fn renderPathMenu(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const m = if (self.path_menu) |*x| x else {
        try batch.setLayerVisible(self.path_menu_layer, false);
        return;
    };
    const sb = self.status_bounds;
    const rows = self.pathMenuRows();
    if (rows == 0 or sb.cols < 8) {
        try batch.setLayerVisible(self.path_menu_layer, false);
        return;
    }
    m.list.follow(rows);

    var want: usize = 12;
    for (0..rows) |r| {
        const it = m.visible(r) orelse break;
        want = @max(want, 1 + display.width(it.name, .{}) + 2);
    }
    const cols = @min(@min(want, complete_max_cols), sb.cols);

    // The names start one cell in, so that cell sits under the `:`
    // line's segment start (itself one past the `:`).
    const seg_col = sb.col + 1 + lineedit.displayCol(self.buf.ed.cmdline.text(), m.seg_start);
    const col = @max(sb.col, @min(seg_col -| 1, sb.col + (sb.cols - cols)));
    try batch.setLayerSize(self.path_menu_layer, cols, rows);
    try batch.setLayerCellPosition(self.path_menu_layer, sb.row - rows, col);

    for (0..rows) |r| {
        const it = m.visible(r) orelse break;
        const selected = m.list.top + r == m.list.selected;
        try batch.writeSpans(&.{
            .{ .text = " " },
            .{ .text = it.name, .fg = role(if (it.is_dir) .popup_kind else .popup_label) },
            .{ .text = if (it.is_dir) "/" else "", .fg = role(.popup_kind) },
        }, .{
            .layer = self.path_menu_layer,
            .row = r,
            .col = 0,
            .fg = role(.popup_label),
            .bg = role(if (selected) .popup_selected_bg else .popup_bg),
            .max_cols = cols,
            .pad = true,
            .selectable = false,
        });
    }
    try batch.setLayerVisible(self.path_menu_layer, true);
}

/// Reads `zoe_history` and `zoe_search_history` from the config
/// directory. Anything going wrong leaves that history empty and
/// unpersisted rather than failing startup; `GLYPHWIRE_NO_HISTORY`
/// (what the tests set, as for gw-shell) turns persistence off.
pub fn loadHistories(self: *Ui) void {
    if (self.environ.get("GLYPHWIRE_NO_HISTORY")) |v| {
        if (v.len > 0) return;
    }
    const dir = glyphwire.configDirPath(self.alloc, self.environ) catch return;
    defer self.alloc.free(dir);
    self.cmd_history_file = self.loadHistory(&self.cmd_history, dir, "zoe_history");
    self.search_history_file = self.loadHistory(&self.search_history, dir, "zoe_search_history");
}

/// Loads one history file into `hist`, returning its path (owned) for
/// later writes, or null when it can't be used. A missing file is a
/// first run: empty, but still written to.
pub fn loadHistory(self: *Ui, hist: *cmdhistory.History, dir: []const u8, name: []const u8) ?[]u8 {
    const path = std.fs.path.join(self.alloc, &.{ dir, name }) catch return null;
    if (std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(8 << 20))) |bytes| {
        defer self.alloc.free(bytes);
        hist.load(bytes) catch |err| {
            std.log.warn("zoe: could not load {s}: {t}", .{ path, err });
            self.alloc.free(path);
            return null;
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.log.warn("zoe: could not read {s}: {t}", .{ path, err });
            self.alloc.free(path);
            return null;
        },
    }
    return path;
}

/// Writes whichever history has lines the file hasn't seen. Run after
/// every key, so it is a no-op almost always; a submitted `:` or `/`
/// line is on disk before the next keystroke, which is what lets
/// another zoe window's Up find it.
pub fn flushHistories(self: *Ui) void {
    self.flushHistory(&self.cmd_history, self.cmd_history_file);
    self.flushHistory(&self.search_history, self.search_history_file);
}

/// Re-reads the file and merges this session's pending lines onto it
/// (`history.mergeSerialize`), so two zoes add to the file instead of
/// the last one to write reverting the other's.
pub fn flushHistory(self: *Ui, hist: *cmdhistory.History, file: ?[]const u8) void {
    if (!hist.hasPending()) return;
    // Unpersisted, the pending list is only ever cleared here.
    const path = file orelse return hist.markWritten();
    const cwd = std.Io.Dir.cwd();
    const disk = cwd.readFileAlloc(self.io, path, self.alloc, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => self.alloc.dupe(u8, "") catch return,
        else => {
            std.log.warn("zoe: could not read {s}: {t}", .{ path, err });
            return;
        },
    };
    defer self.alloc.free(disk);
    const bytes = hist.serializeOnto(disk) catch return;
    defer self.alloc.free(bytes);
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(self.io, d) catch {};
    cwd.writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch |err| {
        std.log.warn("zoe: could not write {s}: {t}", .{ path, err });
        return;
    };
    hist.markWritten();
}
