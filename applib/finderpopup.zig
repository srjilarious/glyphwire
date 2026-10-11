// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The popup drawn around a `finder.Finder`: zoe's Ctrl+P and
//! salacommander's F3 are the same widget, and this is it. A title bar
//! with the match count, a `> ` query line, and the ranked list under
//! them, in the framed chrome `popupframe.zig` draws (shared with the
//! command palette).
//!
//! **What stays with the caller.** Which files to list (the `Finder` is
//! built by the caller and handed over on `open`), what the title says,
//! and what picking a result means -- zoe opens the file, salacommander
//! points a pane at it. `key` and `click` report `.accept` and leave the
//! popup open, so the caller can read `selected()` before `close`. The
//! popup is modal: the caller routes every key, typed text and click to
//! it while `isOpen()`, and redraws it (`render`) whenever `dirty`.
//!
//! The geometry and the key handling are `popupframe`'s free functions,
//! re-exported here, so `tests/finderpopup_tests.zig` covers them
//! without a client.

const std = @import("std");
const glyphwire = @import("glyphwire");
const finder_mod = @import("finder.zig");
const popupframe = @import("popupframe.zig");

pub const Finder = finder_mod.Finder;
const Color = glyphwire.Color;
const Batch = glyphwire.Client.Batch;

pub const Rect = popupframe.Rect;
pub const Style = popupframe.Style;
pub const Outcome = popupframe.Outcome;
pub const KeyEffect = popupframe.KeyEffect;
pub const placeRect = popupframe.placeRect;
pub const frameRect = popupframe.frameRect;

/// Rows the popup spends on its header: the title bar and the query line.
pub const header_rows: usize = 2;

/// A keystroke against an open finder whose list shows `rows` rows. See
/// `popupframe.applyKey`.
pub fn applyKey(f: *Finder, key: []const u8, mods: glyphwire.Mods, rows: usize) !KeyEffect {
    return popupframe.applyKey(f, key, mods, rows);
}

pub const Popup = struct {
    alloc: std.mem.Allocator,
    chrome: popupframe.Chrome,

    /// Non-null exactly while the popup is open.
    finder: ?Finder = null,
    /// What the title bar says, owned.
    title: []u8 = &.{},
    /// Needs a `render`. Set by everything that changes what's shown; a
    /// caller also sets it on a resize or anything that moves the area.
    dirty: bool = false,

    /// Creates the popup's layers, hidden. Call it where the popup should
    /// stack: layers composite in creation order, so after everything it
    /// floats over.
    pub fn init(alloc: std.mem.Allocator, client: *glyphwire.Client, style: Style) !Popup {
        return .{ .alloc = alloc, .chrome = try .init(client, style, header_rows) };
    }

    /// Restyles the popup in place (a theme change). Repaints on the
    /// next `render`.
    pub fn setStyle(self: *Popup, style: Style) !void {
        try self.chrome.setStyle(style);
        self.dirty = true;
    }

    pub fn deinit(self: *Popup) void {
        if (self.finder) |*f| f.deinit();
        self.finder = null;
        self.alloc.free(self.title);
        self.title = &.{};
    }

    pub fn isOpen(self: *const Popup) bool {
        return self.finder != null;
    }

    /// Shows `f` under `title`. Takes ownership of `f`, and replaces a
    /// finder already open.
    pub fn open(self: *Popup, f: Finder, title: []const u8) !void {
        const owned = try self.alloc.dupe(u8, title);
        if (self.finder) |*old| old.deinit();
        self.alloc.free(self.title);
        self.finder = f;
        self.title = owned;
        self.dirty = true;
    }

    pub fn close(self: *Popup) void {
        self.deinit();
        self.dirty = false;
        self.chrome.hide();
    }

    /// The highlighted result, relative to `root()`. A directory ends in
    /// `/`. Borrowed from the finder, so read it before `close`.
    pub fn selected(self: *const Popup) ?[]const u8 {
        const f = if (self.finder) |*open_f| open_f else return null;
        return f.selected();
    }

    /// The highlighted result as an absolute path, the right folder's
    /// for a multi-folder finder (`Finder.selectedPath`). Caller owns it.
    pub fn selectedPath(self: *const Popup, alloc: std.mem.Allocator) !?[]u8 {
        const f = if (self.finder) |*open_f| open_f else return null;
        return f.selectedPath(alloc);
    }

    /// The directory the results are relative to.
    pub fn root(self: *const Popup) ?[]const u8 {
        const f = if (self.finder) |*open_f| open_f else return null;
        return f.root;
    }

    pub fn key(self: *Popup, k: glyphwire.KeyEvent) !Outcome {
        const f = if (self.finder) |*open_f| open_f else return .handled;
        switch (try applyKey(f, k.key, k.mods, self.chrome.list_rows)) {
            .none => return .handled,
            .changed => {
                self.dirty = true;
                return .handled;
            },
            .cancel => {
                self.close();
                return .closed;
            },
            .accept => return .accept,
        }
    }

    /// Typed characters (and a paste): the query.
    pub fn text(self: *Popup, t: []const u8) !void {
        const f = if (self.finder) |*open_f| open_f else return;
        if (try f.query.insert(self.alloc, t)) {
            try f.refilter();
            f.follow(@max(self.chrome.list_rows, 1));
            self.dirty = true;
        }
    }

    /// A left press: a result row picks it, the title or query line does
    /// nothing, and anywhere outside the popup (its frame counts as
    /// inside) closes it. The caller swallows the click either way.
    pub fn click(self: *Popup, cell: glyphwire.CellPos) Outcome {
        const f = if (self.finder) |*open_f| open_f else return .handled;
        switch (self.chrome.hit(cell)) {
            .outside => {
                self.close();
                return .closed;
            },
            .chrome => return .handled,
            .row => |i| {
                const row = f.list.top + i;
                if (row >= f.matchCount()) return .handled;
                f.list.selected = row;
                return .accept;
            },
        }
    }

    /// A `scroll_offset` event. True when it was the popup's list (a
    /// wheel or thumb drag), which scrolls without moving the highlight
    /// -- scrolling past a row and picking it are two gestures.
    pub fn scrolled(self: *Popup, so: glyphwire.ScrollOffsetEvent) bool {
        if (!self.chrome.isList(so.layer)) return false;
        if (self.finder) |*f| {
            f.scrollTo(so.row, self.chrome.list_rows);
            self.dirty = true;
        }
        return true;
    }

    /// Places and draws the popup centred in `area`, into `b`.
    pub fn render(self: *Popup, b: *Batch, area: Rect) !void {
        self.dirty = false;
        const f = if (self.finder) |*open_f| open_f else return;
        if (!try self.chrome.place(b, area, null)) return;
        const cols = self.chrome.rect.cols;
        const list_rows = self.chrome.list_rows;
        // Clamped, not followed: whatever moved the cursor already dragged
        // the view onto it, and doing that here would undo a wheel scroll
        // on the frame that drew it.
        f.clampScroll(list_rows);

        try self.renderHeader(b, f, cols);
        try self.renderList(b, f, cols, list_rows);
        try self.chrome.setListExtent(b, f.matchCount(), f.list.top);
    }

    /// The title bar -- the caller's title, cut to fit, and the count
    /// right-aligned so it never shifts as you type -- and the query line.
    fn renderHeader(self: *Popup, b: *Batch, f: *const Finder, cols: usize) !void {
        const s = self.chrome.style;
        var right: [48]u8 = undefined;
        const tail = std.fmt.bufPrint(&right, "{s}{d}/{d} ", .{
            if (f.truncated) "partial " else "",
            if (f.matchCount() == 0) 0 else f.list.selected + 1,
            f.matchCount(),
        }) catch "";
        const tail_w = try self.chrome.drawRight(b, 0, tail, s.header_fg, s.header_bg);
        // The title is padded up to where the count starts, so a long one
        // is cut there rather than running under it.
        if (cols > tail_w) {
            try b.writeSpans(&.{
                .{ .text = " " },
                .{ .text = self.title },
            }, .{ .layer = self.chrome.header_layer, .row = 0, .col = 0, .fg = s.header_fg, .bg = s.header_bg, .max_cols = cols - tail_w, .pad = true });
        }
        try self.chrome.drawQuery(b, 1, &f.query, cols);
    }

    /// The visible slice of the results, one path per row: the directory
    /// part dimmed, the name bright -- what you're looking for is nearly
    /// always the name, and the directories tell two of them apart.
    fn renderList(self: *Popup, b: *Batch, f: *const Finder, cols: usize, rows: usize) !void {
        const s = self.chrome.style;
        if (f.matchCount() == 0) return self.chrome.drawEmpty(b);
        try b.clearArea(.{ .layer = self.chrome.list_layer });
        for (0..rows) |i| {
            const path = f.matchAt(f.list.top + i) orelse break;
            const is_selected = f.list.top + i == f.list.selected;
            const is_dir = std.mem.endsWith(u8, path, "/");
            // The name is everything after the last separator that isn't
            // a directory's own trailing one.
            const body = if (is_dir) path[0 .. path.len - 1] else path;
            const split = if (std.mem.lastIndexOfScalar(u8, body, '/')) |at| at + 1 else 0;
            const dir_part_fg = if (is_selected) s.selected_fg else s.dim_fg;
            const name_fg = if (is_selected) s.selected_fg else if (is_dir) (s.dir_fg orelse s.text_fg) else s.text_fg;
            const bg: ?Color = if (is_selected) s.selected_bg else null;
            try b.writeSpans(&.{
                .{ .text = " " },
                .{ .text = path[0..split], .fg = dir_part_fg },
                .{ .text = path[split..], .fg = name_fg },
            }, .{ .layer = self.chrome.list_layer, .row = i, .col = 0, .fg = name_fg, .bg = bg, .max_cols = cols, .pad = true });
        }
    }
};
