// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The popup drawn around a `finder.Finder`: zoe's Ctrl+P and
//! salacommander's F3 are the same widget, and this is it. A title bar
//! with the match count, a `> ` query line, and the ranked list under
//! them, framed by the `panel` nine-patch and standing off the window on
//! the host's `Shadow.dialog`.
//!
//! Three layers, created together by `init` so they stack in order:
//!
//!     frame   one cell bigger than the popup all round; carries the
//!             nine-patch border + background and the drop shadow
//!     header  the title bar and query line
//!     list    the visible rows of matches, `client` scroll mode with the
//!             match count as its `content_extent`, so the host's
//!             scrollbar is to scale and a wheel over it comes back as a
//!             `scroll_offset`
//!
//! A host without the nine-patch style gets a borderless popup: the two
//! content layers paint `Style.bg` themselves and nothing has a shadow.
//!
//! **What stays with the caller.** Which files to list (the `Finder` is
//! built by the caller and handed over on `open`), what the title says,
//! and what picking a result means -- zoe opens the file, salacommander
//! points a pane at it. `key` and `click` report `.accept` and leave the
//! popup open, so the caller can read `selected()` before `close`. The
//! popup is modal: the caller routes every key, typed text and click to
//! it while `isOpen()`, and redraws it (`render`) whenever `dirty`.
//!
//! The geometry and the key handling are free functions over plain
//! values (`placeRect`, `frameRect`, `applyKey`), so
//! `tests/finderpopup_tests.zig` covers them without a client.

const std = @import("std");
const glyphwire = @import("glyphwire");
const finder_mod = @import("finder.zig");
const lineedit = @import("lineedit.zig");

pub const Finder = finder_mod.Finder;
const Color = glyphwire.Color;
const Batch = glyphwire.Client.Batch;

/// Rows the popup spends on its header: the title bar and the query line.
pub const header_rows: usize = 2;

/// A block of cells, in the coordinates of the context the popup is in.
pub const Rect = struct {
    row: usize = 0,
    col: usize = 0,
    cols: usize = 0,
    rows: usize = 0,

    pub fn contains(self: Rect, cell: glyphwire.CellPos) bool {
        return cell.row >= self.row and cell.row < self.row + self.rows and
            cell.col >= self.col and cell.col < self.col + self.cols;
    }
};

/// Colours and size limits. The colours default to the theme's finder
/// and popup roles, which the host resolves.
pub const Style = struct {
    /// The nine-patch style name for the frame.
    frame_style: []const u8 = "panel",
    /// The flat background when the host has no `frame_style`, and the
    /// ink of the character under the drawn query caret.
    bg: Color = .role(.popup_bg),
    header_bg: Color = .role(.finder_header_bg),
    header_fg: Color = .role(.finder_header_fg),
    selected_bg: Color = .role(.finder_selected_bg),
    selected_fg: Color = .role(.finder_selected_fg),
    /// A result's name, and the query text.
    text_fg: Color = .role(.fg),
    /// A result's directory part, the `> ` prompt and the empty-list note.
    dim_fg: Color = .role(.fg_dim),
    /// A directory result's name (one ending in `/`, which only a finder
    /// with `include_dirs` lists). Null draws it like a file.
    dir_fg: ?Color = null,
    empty_text: []const u8 = "No matching files",
    /// The preferred size in cells; `placeRect` shrinks it to fit.
    max_cols: usize = 84,
    max_rows: usize = 20,
    min_cols: usize = 24,
    min_rows: usize = 4,
};


/// Where the popup goes inside `area`: centred, at its preferred size or
/// as much of it as fits, and never below the minimum unless the area
/// itself is smaller -- in which case the popup is the area, which at
/// least stays readable. Recomputed per frame by `render`, so a resize or
/// a moved pane carries the popup with it and nothing has to track it.
pub fn placeRect(area: Rect, style: Style) Rect {
    const cols = @min(@max(style.min_cols, @min(style.max_cols, area.cols -| 4)), area.cols);
    const rows = @min(@max(style.min_rows, @min(style.max_rows, area.rows -| 2)), area.rows);
    return .{
        .row = area.row + (area.rows -| rows) / 2,
        .col = area.col + (area.cols -| cols) / 2,
        .cols = cols,
        .rows = rows,
    };
}

/// The frame around the popup rect `r`: one cell out on every side, or
/// null when `r` touches the top or left edge and there's no cell for it
/// (only when the area is too small for the popup's preferred size, since
/// `placeRect` otherwise leaves a margin).
pub fn frameRect(r: Rect) ?Rect {
    if (r.row == 0 or r.col == 0) return null;
    return .{ .row = r.row - 1, .col = r.col - 1, .rows = r.rows + 2, .cols = r.cols + 2 };
}

/// What a key or click came to.
pub const Outcome = enum {
    /// Nothing for the caller to do (the popup may have redrawn itself).
    handled,
    /// The popup closed itself: Escape, Ctrl+C, or a click outside it.
    closed,
    /// Enter, or a click on a result: the caller reads `selected()` and
    /// decides what that means, then closes the popup.
    accept,
};

/// What `applyKey` did to the finder, for a caller to turn into an
/// `Outcome` and a redraw.
pub const KeyEffect = enum { none, cancel, accept, changed };

/// A keystroke against an open finder whose list shows `rows` rows.
/// Escape / Ctrl+C cancel, Enter accepts, Up/Down (and Ctrl+P/Ctrl+N --
/// Ctrl+K is the field's kill-to-end, so not the vim-ish pair) and the
/// page keys move the highlight, and everything else is the query
/// field's. Takes every key it's given: the popup is modal, and a stray
/// chord reaching the program behind it is worse than nothing happening.
pub fn applyKey(f: *Finder, key: []const u8, mods: glyphwire.Mods, rows: usize) !KeyEffect {
    const eq = std.mem.eql;
    const page = @max(rows, 1);

    if (eq(u8, key, "escape") or (mods.ctrl and eq(u8, key, "c"))) return .cancel;
    if (eq(u8, key, "enter") or eq(u8, key, "kp_enter")) return .accept;

    const step: ?isize = if (eq(u8, key, "up") or (mods.ctrl and eq(u8, key, "p")))
        -1
    else if (eq(u8, key, "down") or (mods.ctrl and eq(u8, key, "n")))
        1
    else if (eq(u8, key, "page_up"))
        -@as(isize, @intCast(page))
    else if (eq(u8, key, "page_down"))
        @as(isize, @intCast(page))
    else
        null;
    if (step) |d| {
        f.moveCursor(d);
        f.follow(page);
        return .changed;
    }

    return switch (f.query.handleKey(key, mods)) {
        .edited => blk: {
            try f.refilter();
            f.follow(page);
            break :blk .changed;
        },
        .moved => .changed,
        .ignored, .submit, .cancel => .none,
    };
}

pub const Popup = struct {
    alloc: std.mem.Allocator,
    client: *glyphwire.Client,
    style: Style,
    frame_layer: glyphwire.LayerHandle,
    header_layer: glyphwire.LayerHandle,
    list_layer: glyphwire.LayerHandle,
    /// Null when the host has no `style.frame_style`.
    frame_patch: ?glyphwire.NinePatchHandle,
    /// The name `frame_patch` was made from, copied: callers pass a
    /// `frame_style` borrowed from their `theme.Stored`, which a theme
    /// change overwrites before `setStyle` gets to compare against it.
    frame_name_buf: [glyphwire.theme.Stored.max_name_len]u8 = undefined,
    frame_name_len: usize = 0,

    /// Non-null exactly while the popup is open.
    finder: ?Finder = null,
    /// What the title bar says, owned.
    title: []u8 = &.{},
    /// Where the content (header + list) was last drawn, for `click`.
    rect: Rect = .{},
    list_rows: usize = 0,
    /// Needs a `render`. Set by everything that changes what's shown; a
    /// caller also sets it on a resize or anything that moves the area.
    dirty: bool = false,

    /// Creates the popup's layers, hidden. Call it where the popup should
    /// stack: layers composite in creation order, so after everything it
    /// floats over.
    pub fn init(alloc: std.mem.Allocator, client: *glyphwire.Client, style: Style) !Popup {
        // The frame first, so it sits under the two content layers.
        const frame_layer = try client.createLayer(style.min_cols + 2, style.min_rows + 2, 0);
        const frame_patch: ?glyphwire.NinePatchHandle = client.createNinePatch(
            frame_layer,
            0,
            0,
            style.min_rows + 2,
            style.min_cols + 2,
            style.frame_style,
        ) catch |err| blk: {
            std.log.warn("finder popup: no '{s}' nine-patch ({t}); drawing it flat", .{ style.frame_style, err });
            break :blk null;
        };
        const header_layer = try client.createLayer(style.min_cols, header_rows, 0);
        const list_layer = try client.createLayer(style.min_cols, 1, 0);

        for ([_]glyphwire.LayerHandle{ frame_layer, header_layer, list_layer }) |l| {
            try client.setLayerVisible(l, false);
        }
        if (frame_patch != null) {
            // The shadow goes on the frame, the popup's outline; a
            // borderless fallback popup gets none.
            try client.setLayerShadow(frame_layer, glyphwire.Shadow.dialog);
        } else {
            try client.setLayerBackground(header_layer, style.bg);
            try client.setLayerBackground(list_layer, style.bg);
        }
        try client.setLayerScrollMode(list_layer, .client);
        try client.setLayerScrollbars(list_layer, true, false);

        var popup: Popup = .{
            .alloc = alloc,
            .client = client,
            .style = style,
            .frame_layer = frame_layer,
            .header_layer = header_layer,
            .list_layer = list_layer,
            .frame_patch = frame_patch,
        };
        popup.rememberFrameName(style.frame_style);
        return popup;
    }

    fn rememberFrameName(self: *Popup, name: []const u8) void {
        self.frame_name_len = @min(name.len, self.frame_name_buf.len);
        @memcpy(self.frame_name_buf[0..self.frame_name_len], name[0..self.frame_name_len]);
    }

    /// Restyles the popup in place (zoe's `:theme`). A different
    /// `frame_style` swaps the nine-patch: destroyed and re-created rather
    /// than `update_nine_patch`ed, because an unknown style is only
    /// reported to a request, and the popup then falls back to drawing
    /// flat exactly as `init` does. Repaints on the next `render`.
    pub fn setStyle(self: *Popup, style: Style) !void {
        const frame_changed = !std.mem.eql(u8, style.frame_style, self.frame_name_buf[0..self.frame_name_len]);
        self.style = style;
        self.dirty = true;
        if (frame_changed) {
            self.rememberFrameName(style.frame_style);
            if (self.frame_patch) |p| try self.client.destroyNinePatch(self.frame_layer, p);
            self.frame_patch = self.client.createNinePatch(
                self.frame_layer,
                0,
                0,
                style.min_rows + 2,
                style.min_cols + 2,
                style.frame_style,
            ) catch |err| blk: {
                std.log.warn("finder popup: no '{s}' nine-patch ({t}); drawing it flat", .{ style.frame_style, err });
                break :blk null;
            };
            try self.client.setLayerShadow(self.frame_layer, if (self.frame_patch != null) glyphwire.Shadow.dialog else null);
        }
        const flat_bg: ?Color = if (self.frame_patch == null) style.bg else null;
        try self.client.setLayerBackground(self.header_layer, flat_bg);
        try self.client.setLayerBackground(self.list_layer, flat_bg);
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
        for ([_]glyphwire.LayerHandle{ self.frame_layer, self.header_layer, self.list_layer }) |l| {
            self.client.setLayerVisible(l, false) catch {};
        }
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
        switch (try applyKey(f, k.key, k.mods, self.list_rows)) {
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
            f.follow(@max(self.list_rows, 1));
            self.dirty = true;
        }
    }

    /// A left press: a result row picks it, the title or query line does
    /// nothing, and anywhere outside the popup (its frame counts as
    /// inside) closes it. The caller swallows the click either way.
    pub fn click(self: *Popup, cell: glyphwire.CellPos) Outcome {
        const f = if (self.finder) |*open_f| open_f else return .handled;
        const r = self.rect;
        const outline = if (self.frame_patch != null) frameRect(r) orelse r else r;
        if (!outline.contains(cell)) {
            self.close();
            return .closed;
        }
        const list_row0 = r.row + header_rows;
        if (cell.row < list_row0 or !r.contains(cell)) return .handled;
        const row = f.top + (cell.row - list_row0);
        if (row >= f.matchCount()) return .handled;
        f.cursor = row;
        return .accept;
    }

    /// A `scroll_offset` event. True when it was the popup's list (a
    /// wheel or thumb drag), which scrolls without moving the highlight
    /// -- scrolling past a row and picking it are two gestures.
    pub fn scrolled(self: *Popup, so: glyphwire.ScrollOffsetEvent) bool {
        if (so.layer != self.list_layer) return false;
        if (self.finder) |*f| {
            f.scrollTo(so.row, self.list_rows);
            self.dirty = true;
        }
        return true;
    }

    /// Places and draws the popup centred in `area`, into `b`.
    pub fn render(self: *Popup, b: *Batch, area: Rect) !void {
        self.dirty = false;
        const f = if (self.finder) |*open_f| open_f else return;
        const r = placeRect(area, self.style);
        self.rect = r;

        // No room for the header and one result: draw nothing rather than
        // something unreadable. The popup stays open, so a bigger window
        // brings it back.
        if (r.cols == 0 or r.rows <= header_rows) {
            self.list_rows = 0;
            try b.setLayerVisible(self.frame_layer, false);
            try b.setLayerVisible(self.header_layer, false);
            try b.setLayerVisible(self.list_layer, false);
            return;
        }

        const list_rows = r.rows - header_rows;
        self.list_rows = list_rows;
        // Clamped, not followed: whatever moved the cursor already dragged
        // the view onto it, and doing that here would undo a wheel scroll
        // on the frame that drew it.
        f.clampScroll(list_rows);

        try b.setLayerSize(self.header_layer, r.cols, header_rows);
        try b.setLayerCellPosition(self.header_layer, r.row, r.col);
        try b.setLayerSize(self.list_layer, r.cols, list_rows);
        try b.setLayerCellPosition(self.list_layer, r.row + header_rows, r.col);

        const frame = if (self.frame_patch != null) frameRect(r) else null;
        if (frame) |fr| {
            try b.setLayerSize(self.frame_layer, fr.cols, fr.rows);
            try b.setLayerCellPosition(self.frame_layer, fr.row, fr.col);
            try b.updateNinePatch(self.frame_layer, self.frame_patch.?, .{ .rows = fr.rows, .cols = fr.cols });
        }

        try self.renderHeader(b, f, r.cols);
        try self.renderList(b, f, r.cols, list_rows);

        try b.setLayerContentExtent(self.list_layer, r.cols, f.matchCount());
        try b.setLayerScrollOffset(self.list_layer, f.top, 0);

        try b.setLayerVisible(self.frame_layer, frame != null);
        try b.setLayerVisible(self.header_layer, true);
        try b.setLayerVisible(self.list_layer, true);
    }

    /// The title bar -- the caller's title, cut to fit, and the count
    /// right-aligned so it never shifts as you type -- and the query line.
    fn renderHeader(self: *Popup, b: *Batch, f: *const Finder, cols: usize) !void {
        const s = self.style;
        var right: [48]u8 = undefined;
        const tail = std.fmt.bufPrint(&right, "{s}{d}/{d} ", .{
            if (f.truncated) "partial " else "",
            if (f.matchCount() == 0) 0 else f.cursor + 1,
            f.matchCount(),
        }) catch "";
        const tail_w = @min(glyphwire.stringWidth(tail), cols);
        // The title is padded up to where the count starts, so a long one
        // is cut there rather than running under it.
        if (cols > tail_w) {
            try b.writeSpans(&.{
                .{ .text = " " },
                .{ .text = self.title },
            }, .{ .layer = self.header_layer, .row = 0, .col = 0, .fg = s.header_fg, .bg = s.header_bg, .max_cols = cols - tail_w, .pad = true });
        }
        try b.writeTextOpts(tail, .{ .layer = self.header_layer, .row = 0, .col = cols - tail_w, .fg = s.header_fg, .bg = s.header_bg, .max_cols = tail_w });

        // The query behind a `> ` prompt, with a drawn caret: a layer's
        // cursor property is its next write position, not a visual one.
        // No `bg` from here on: the panel behind the popup is its
        // background (or the layer's own, in the flat fallback).
        const prompt = "> ";
        try b.writeTextOpts(prompt, .{ .layer = self.header_layer, .row = 1, .col = 0, .fg = s.dim_fg });
        try b.writeTextOpts(f.query.text(), .{ .layer = self.header_layer, .row = 1, .col = prompt.len, .fg = s.text_fg, .max_cols = cols -| prompt.len, .pad = true });
        const caret_col = prompt.len + f.query.caretCol();
        if (caret_col < cols) {
            const q = f.query.text();
            const under = if (f.query.caret < q.len) q[f.query.caret..lineedit.nextBoundary(q, f.query.caret)] else " ";
            try b.writeTextOpts(under, .{ .layer = self.header_layer, .row = 1, .col = caret_col, .fg = s.bg, .bg = s.text_fg });
        }
    }

    /// The visible slice of the results, one path per row: the directory
    /// part dimmed, the name bright -- what you're looking for is nearly
    /// always the name, and the directories tell two of them apart.
    fn renderList(self: *Popup, b: *Batch, f: *const Finder, cols: usize, rows: usize) !void {
        const s = self.style;
        try b.clearArea(.{ .layer = self.list_layer });
        if (f.matchCount() == 0) {
            var buf: [96]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "  {s}", .{s.empty_text}) catch s.empty_text;
            try b.writeTextOpts(note, .{ .layer = self.list_layer, .row = 0, .col = 0, .fg = s.dim_fg, .max_cols = cols });
            return;
        }
        for (0..rows) |i| {
            const path = f.matchAt(f.top + i) orelse break;
            const is_selected = f.top + i == f.cursor;
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
            }, .{ .layer = self.list_layer, .row = i, .col = 0, .fg = name_fg, .bg = bg, .max_cols = cols, .pad = true });
        }
    }
};
