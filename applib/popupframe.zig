// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The chrome every applib list popup is drawn in: the Ctrl+P / F3 file
//! finder (`finderpopup.zig`) and the Ctrl+Shift+P command palette
//! (`palette.zig`). A header of one or more rows over a scrolling list,
//! framed by the `panel` nine-patch and standing off the window on the
//! host's `Shadow.dialog`.
//!
//! Three layers, created together by `Chrome.init` so they stack in order:
//!
//!     frame   one cell bigger than the popup all round; carries the
//!             nine-patch border + background and the drop shadow
//!     header  the popup's own top rows: a title bar, the query line
//!     list    the visible rows, `client` scroll mode with the row count
//!             as its `content_extent`, so the host's scrollbar is to
//!             scale and a wheel over it comes back as a `scroll_offset`
//!
//! A host without the nine-patch style gets a borderless popup: the two
//! content layers paint `Style.bg` themselves and nothing has a shadow.
//!
//! What goes *in* the header and the list is the popup's own business.
//! `Chrome` places the layers, draws the parts both popups share (the
//! query line with its caret, a right-aligned note, the empty-list
//! line), and turns a click into "outside", "on the chrome" or "on list
//! row N". The geometry and the key handling are free functions over
//! plain values (`placeRect`, `frameRect`, `applyKey`), so the tests
//! cover them without a client.

const std = @import("std");
const glyphwire = @import("glyphwire");
const lineedit = @import("lineedit.zig");

const Color = glyphwire.Color;
const Batch = glyphwire.Client.Batch;

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

/// Where in its area a popup sits.
pub const Anchor = enum {
    /// Centred both ways: the file finder.
    center,
    /// Centred across, `top_margin` rows down: the command palette, the
    /// way VS Code drops its palette from the top of the window.
    top,
};

/// Rows between the top of the area and a `.top` popup: one for the
/// frame and one of gap, so the frame doesn't sit on the area's edge.
pub const top_margin: usize = 2;

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
    /// A row's main text, and the query text.
    text_fg: Color = .role(.fg),
    /// Secondary text (a path's directory, a command's chord), the `> `
    /// prompt and the empty-list note.
    dim_fg: Color = .role(.fg_dim),
    /// The finder's directory results (ones ending in `/`, which only a
    /// finder with `include_dirs` lists). Null draws them like a file.
    dir_fg: ?Color = null,
    empty_text: []const u8 = "No matching files",
    anchor: Anchor = .center,
    /// The preferred size in cells; `placeRect` shrinks it to fit.
    max_cols: usize = 84,
    max_rows: usize = 20,
    min_cols: usize = 24,
    min_rows: usize = 4,
};

/// Where the popup goes inside `area`: centred across (and down, for
/// `.center`), at its preferred size or as much of it as fits, and never
/// below the minimum unless the area itself is smaller -- in which case
/// the popup is the area, which at least stays readable. Recomputed per
/// frame by `Chrome.place`, so a resize or a moved pane carries the
/// popup with it and nothing has to track it.
pub fn placeRect(area: Rect, style: Style) Rect {
    const cols = @min(@max(style.min_cols, @min(style.max_cols, area.cols -| 4)), area.cols);
    const rows = @min(@max(style.min_rows, @min(style.max_rows, area.rows -| 2)), area.rows);
    const row = switch (style.anchor) {
        .center => area.row + (area.rows -| rows) / 2,
        .top => area.row + @min(top_margin, area.rows -| rows),
    };
    return .{
        .row = row,
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

/// What a key or click came to, for the popup's caller.
pub const Outcome = enum {
    /// Nothing for the caller to do (the popup may have redrawn itself).
    handled,
    /// The popup closed itself: Escape, Ctrl+C, or a click outside it.
    closed,
    /// Enter, or a click on a row: the caller reads what's selected and
    /// decides what that means, then closes the popup.
    accept,
};

/// What `applyKey` did to the list, for a popup to turn into an
/// `Outcome` and a redraw.
pub const KeyEffect = enum { none, cancel, accept, changed };

/// A keystroke against an open list popup whose list shows `rows` rows.
/// `list` is the popup's model -- a `finder.Finder` or a
/// `palette.List` -- and needs a `query: LineEdit` and `moveCursor`,
/// `follow` and `refilter` methods.
///
/// Escape / Ctrl+C cancel, Enter accepts, Up/Down (and Ctrl+P/Ctrl+N --
/// Ctrl+K is the field's kill-to-end, so not the vim-ish pair) and the
/// page keys move the highlight, and everything else is the query
/// field's. Takes every key it's given: the popup is modal, and a stray
/// chord reaching the program behind it is worse than nothing happening.
pub fn applyKey(list: anytype, key: []const u8, mods: glyphwire.Mods, rows: usize) !KeyEffect {
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
        list.moveCursor(d);
        list.follow(page);
        return .changed;
    }

    return switch (list.query.handleKey(key, mods)) {
        .edited => blk: {
            try list.refilter();
            list.follow(page);
            break :blk .changed;
        },
        .moved => .changed,
        .ignored, .submit, .cancel => .none,
    };
}

/// Where a left press landed, relative to the popup.
pub const Hit = union(enum) {
    /// Off the popup and its frame: dismisses it.
    outside,
    /// On the popup but not on a list row: the header, the frame, or
    /// the list's empty space.
    chrome,
    /// On the list, this many rows below its top visible row.
    row: usize,
};

/// The layers and frame of one popup, and where it was last placed.
pub const Chrome = struct {
    client: *glyphwire.Client,
    style: Style,
    /// Rows the popup spends above its list.
    header_rows: usize,
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

    /// Where the content (header + list) was last drawn, for `hit`.
    rect: Rect = .{},
    list_rows: usize = 0,

    /// Creates the popup's layers, hidden. Call it where the popup should
    /// stack: layers composite in creation order, so after everything it
    /// floats over.
    pub fn init(client: *glyphwire.Client, style: Style, header_rows: usize) !Chrome {
        // The frame first, so it sits under the two content layers.
        const frame_layer = try client.createLayer(style.min_cols + 2, style.min_rows + 2, 0);
        const frame_patch = createFrame(client, frame_layer, style);
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

        var chrome: Chrome = .{
            .client = client,
            .style = style,
            .header_rows = header_rows,
            .frame_layer = frame_layer,
            .header_layer = header_layer,
            .list_layer = list_layer,
            .frame_patch = frame_patch,
        };
        chrome.rememberFrameName(style.frame_style);
        return chrome;
    }

    /// The frame's nine-patch, or null (logged) when the host has no
    /// such style -- the popup then draws flat.
    fn createFrame(client: *glyphwire.Client, layer: glyphwire.LayerHandle, style: Style) ?glyphwire.NinePatchHandle {
        return client.createNinePatch(layer, 0, 0, style.min_rows + 2, style.min_cols + 2, style.frame_style) catch |err| {
            std.log.warn("popup: no '{s}' nine-patch ({t}); drawing it flat", .{ style.frame_style, err });
            return null;
        };
    }

    fn rememberFrameName(self: *Chrome, name: []const u8) void {
        self.frame_name_len = @min(name.len, self.frame_name_buf.len);
        @memcpy(self.frame_name_buf[0..self.frame_name_len], name[0..self.frame_name_len]);
    }

    /// Restyles the popup in place (a theme change). A different
    /// `frame_style` swaps the nine-patch: destroyed and re-created rather
    /// than `update_nine_patch`ed, because an unknown style is only
    /// reported to a request, and the popup then falls back to drawing
    /// flat exactly as `init` does. The owner repaints it after.
    pub fn setStyle(self: *Chrome, style: Style) !void {
        const frame_changed = !std.mem.eql(u8, style.frame_style, self.frame_name_buf[0..self.frame_name_len]);
        self.style = style;
        if (frame_changed) {
            self.rememberFrameName(style.frame_style);
            if (self.frame_patch) |p| try self.client.destroyNinePatch(self.frame_layer, p);
            self.frame_patch = createFrame(self.client, self.frame_layer, style);
            try self.client.setLayerShadow(self.frame_layer, if (self.frame_patch != null) glyphwire.Shadow.dialog else null);
        }
        const flat_bg: ?Color = if (self.frame_patch == null) style.bg else null;
        try self.client.setLayerBackground(self.header_layer, flat_bg);
        try self.client.setLayerBackground(self.list_layer, flat_bg);
    }

    /// Hides all three layers at once, outside a batch: a popup closes
    /// in response to a key or a click, not during a frame.
    pub fn hide(self: *Chrome) void {
        for ([_]glyphwire.LayerHandle{ self.frame_layer, self.header_layer, self.list_layer }) |l| {
            self.client.setLayerVisible(l, false) catch {};
        }
    }

    /// Places the popup in `area` and shows it. `content_rows`, when
    /// given, is how many rows the popup actually needs (header + list),
    /// so a short list gets a short popup; null keeps the style's
    /// preferred height. False -- with everything hidden -- when there's
    /// no room for the header and one list row: drawing nothing beats
    /// drawing something unreadable, and the popup stays open, so a
    /// bigger window brings it back.
    pub fn place(self: *Chrome, b: *Batch, area: Rect, content_rows: ?usize) !bool {
        var style = self.style;
        if (content_rows) |want| {
            style.max_rows = @min(style.max_rows, want);
            style.min_rows = @min(style.min_rows, style.max_rows);
        }
        const r = placeRect(area, style);
        self.rect = r;

        if (r.cols == 0 or r.rows <= self.header_rows) {
            self.list_rows = 0;
            try b.setLayerVisible(self.frame_layer, false);
            try b.setLayerVisible(self.header_layer, false);
            try b.setLayerVisible(self.list_layer, false);
            return false;
        }

        const list_rows = r.rows - self.header_rows;
        self.list_rows = list_rows;
        try b.setLayerSize(self.header_layer, r.cols, self.header_rows);
        try b.setLayerCellPosition(self.header_layer, r.row, r.col);
        try b.setLayerSize(self.list_layer, r.cols, list_rows);
        try b.setLayerCellPosition(self.list_layer, r.row + self.header_rows, r.col);

        const frame = if (self.frame_patch != null) frameRect(r) else null;
        if (frame) |fr| {
            try b.setLayerSize(self.frame_layer, fr.cols, fr.rows);
            try b.setLayerCellPosition(self.frame_layer, fr.row, fr.col);
            try b.updateNinePatch(self.frame_layer, self.frame_patch.?, .{ .rows = fr.rows, .cols = fr.cols });
        }
        try b.setLayerVisible(self.frame_layer, frame != null);
        try b.setLayerVisible(self.header_layer, true);
        try b.setLayerVisible(self.list_layer, true);
        return true;
    }

    /// Tells the host how long the list is and which row is at its top,
    /// for the scrollbar.
    pub fn setListExtent(self: *Chrome, b: *Batch, count: usize, top: usize) !void {
        try b.setLayerContentExtent(self.list_layer, self.rect.cols, count);
        try b.setLayerScrollOffset(self.list_layer, top, 0);
    }

    /// `text` right-aligned on header row `row`, in `fg` over `bg`.
    /// Returns the cells it took, so the caller can stop what's left of
    /// the row short of it.
    pub fn drawRight(self: *Chrome, b: *Batch, row: usize, text: []const u8, fg: Color, bg: ?Color) !usize {
        const cols = self.rect.cols;
        const w = @min(glyphwire.stringWidth(text), cols);
        try b.writeText(text, .{ .layer = self.header_layer, .row = row, .col = cols - w, .fg = fg, .bg = bg, .max_cols = w });
        return w;
    }

    /// The query behind a `> ` prompt on header row `row`, `cols` wide,
    /// with a drawn caret: a layer's cursor property is its next write
    /// position, not a visual one. No `bg`: the panel behind the popup is
    /// its background (or the layer's own, in the flat fallback).
    pub fn drawQuery(self: *Chrome, b: *Batch, row: usize, query: *const lineedit.LineEdit, cols: usize) !void {
        const s = self.style;
        const prompt = "> ";
        try b.writeText(prompt, .{ .layer = self.header_layer, .row = row, .col = 0, .fg = s.dim_fg, .max_cols = cols });
        try b.writeText(query.text(), .{ .layer = self.header_layer, .row = row, .col = prompt.len, .fg = s.text_fg, .max_cols = cols -| prompt.len, .pad = true });
        const caret_col = prompt.len + query.caretCol();
        if (caret_col < cols) {
            const q = query.text();
            const under = if (query.caret < q.len) q[query.caret..lineedit.nextBoundary(q, query.caret)] else " ";
            try b.writeText(under, .{ .layer = self.header_layer, .row = row, .col = caret_col, .fg = s.bg, .bg = s.text_fg });
        }
    }

    /// Clears the list, and says `Style.empty_text` on its first row.
    pub fn drawEmpty(self: *Chrome, b: *Batch) !void {
        const s = self.style;
        try b.clear(.{ .layer = self.list_layer });
        var buf: [96]u8 = undefined;
        const note = std.fmt.bufPrint(&buf, "  {s}", .{s.empty_text}) catch s.empty_text;
        try b.writeText(note, .{ .layer = self.list_layer, .row = 0, .col = 0, .fg = s.dim_fg, .max_cols = self.rect.cols });
    }

    /// Where a left press at `cell` landed. The frame counts as inside.
    pub fn hit(self: *const Chrome, cell: glyphwire.CellPos) Hit {
        const r = self.rect;
        const outline = if (self.frame_patch != null) frameRect(r) orelse r else r;
        if (!outline.contains(cell)) return .outside;
        const list_row0 = r.row + self.header_rows;
        if (cell.row < list_row0 or !r.contains(cell)) return .chrome;
        return .{ .row = cell.row - list_row0 };
    }

    pub fn isList(self: *const Chrome, layer: glyphwire.LayerHandle) bool {
        return layer == self.list_layer;
    }
};
