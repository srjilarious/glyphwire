// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The command palette, VS Code's Ctrl+Shift+P: every named action a
//! program has (its `keybind` `Action` enum), searchable by name and run
//! from the list. zoe and salacommander both open it on Ctrl+Shift+P.
//!
//! A `> ` query line over the matching commands, each row the command's
//! label with the chord that runs it right-aligned, in the same framed
//! chrome as the file finder (`popupframe.zig`). It drops from the top of
//! its area rather than sitting in the middle, and is only as tall as
//! the list needs.
//!
//! **What stays with the caller.** Which actions are listed and what
//! they're called: the caller builds a `List` (`add` per action, usually
//! a loop over the enum filtered by the program's own `inPalette`) and
//! hands it to `open`. A command carries its action as a plain `u32` id
//! (`@intFromEnum`), so nothing here is generic over the enum;
//! `selectedAs` turns it back. Running a pick is the caller's too --
//! `key` and `click` report `.accept` and leave the palette open, so the
//! caller reads the selection, `close`s, then runs it as if its chord
//! had been pressed.
//!
//! **Ranking.** A query matches a command's label or its action name,
//! whichever fits tighter (`applib.fuzzy`, the finder's matcher), so
//! `tgt` finds "Toggle Tree" and `sudochmod` finds "Change Mode as Root".
//! Ties, and the whole list before anything is typed, go to the commands
//! run most recently through the palette, then the caller's own order.
//! That memory (`Recent`) lives on the `Popup`, for the session.
//!
//! Everything but drawing is pure, so `tests/palette_tests.zig` covers
//! the labels, the ranking and the recency without a client.

const std = @import("std");
const glyphwire = @import("glyphwire");
const keybind = @import("keybind");
const fuzzy = @import("fuzzy.zig");
const lineedit = @import("lineedit.zig");
const popupframe = @import("popupframe.zig");
const ListCursor = @import("listcursor").ListCursor;

const Color = glyphwire.Color;
const Batch = glyphwire.Client.Batch;

pub const Rect = popupframe.Rect;
pub const Style = popupframe.Style;
pub const Outcome = popupframe.Outcome;

/// Rows the palette spends above its list: just the query line, with the
/// match count at its right end.
pub const header_rows: usize = 1;

/// The palette's shape over `Style`'s colour defaults: top-anchored,
/// narrower and shorter than the finder.
pub const default_style: Style = .{
    .anchor = .top,
    .empty_text = "No matching commands",
    .max_cols = 72,
    .max_rows = 16,
    .min_rows = 2,
};

/// The longest label `labelFromName` writes.
pub const max_label_len = 64;

/// A camelCase action name as words, each capitalised: `toggleTree` is
/// "Toggle Tree", `sortByExt` "Sort By Ext". A run of capitals stays one
/// word up to the last of them, which starts the next when a lower-case
/// letter follows (`openURLInTab` is "Open URL In Tab"). Cut at `buf`'s
/// length; the result borrows `buf`.
pub fn labelFromName(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name, 0..) |c, i| {
        const starts_word = i > 0 and std.ascii.isUpper(c) and
            (std.ascii.isLower(name[i - 1]) or std.ascii.isDigit(name[i - 1]) or
                (i + 1 < name.len and std.ascii.isUpper(name[i - 1]) and std.ascii.isLower(name[i + 1])));
        if (starts_word) {
            if (n == buf.len) break;
            buf[n] = ' ';
            n += 1;
        }
        if (n == buf.len) break;
        buf[n] = if (i == 0) std.ascii.toUpper(c) else c;
        n += 1;
    }
    return buf[0..n];
}

/// The last few commands run from the palette, newest first, by id.
pub const Recent = struct {
    pub const capacity = 16;

    ids: [capacity]u32 = undefined,
    len: usize = 0,

    /// `id` was just run: to the front, out of wherever it was before.
    /// The oldest falls off the end when it's full.
    pub fn note(self: *Recent, id: u32) void {
        var end = self.len;
        if (self.rank(id)) |at| {
            end = at;
        } else if (self.len < capacity) {
            self.len += 1;
        } else {
            end = capacity - 1;
        }
        std.mem.copyBackwards(u32, self.ids[1 .. end + 1], self.ids[0..end]);
        self.ids[0] = id;
    }

    /// How recently `id` was run: 0 for the newest. Null when it wasn't.
    pub fn rank(self: *const Recent, id: u32) ?usize {
        return std.mem.indexOfScalar(u32, self.ids[0..self.len], id);
    }
};

/// One line of the palette.
pub const Command = struct {
    /// The caller's action, `@intFromEnum`'d.
    id: u32,
    /// The action's config name (`toggleTree`), owned. Matched alongside
    /// the label, so the name a config file uses finds it too.
    name: []u8,
    /// What the row says, owned.
    label: []u8,
    /// The chord that runs it, formatted (`Ctrl+Shift+P`), owned. Empty
    /// when nothing binds it.
    chord: []u8,
};

/// A command that matched the query, and how well.
pub const Match = struct {
    index: usize,
    score: usize,
    /// `Recent.rank`, or `maxInt` for one never run.
    recent: usize,
};

/// The palette's model: every command, the query, and the ranked subset
/// that answers it. Built by the caller, owned by the `Popup` once open.
pub const List = struct {
    alloc: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    matches: std.ArrayList(Match) = .empty,
    query: lineedit.LineEdit = .empty,
    list: ListCursor = .{},
    /// The popup's recency, copied in by `Popup.open`.
    recent: Recent = .{},

    pub fn init(alloc: std.mem.Allocator) List {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *List) void {
        for (self.commands.items) |c| {
            self.alloc.free(c.name);
            self.alloc.free(c.label);
            self.alloc.free(c.chord);
        }
        self.commands.deinit(self.alloc);
        self.matches.deinit(self.alloc);
        self.query.deinit(self.alloc);
    }

    /// Lists action `id` under `label`, or under its `name` made into
    /// words (`labelFromName`) when `label` is null. `chord` is what runs
    /// it now, shown at the row's right end.
    pub fn add(self: *List, id: u32, name: []const u8, label: ?[]const u8, chord: ?keybind.Chord) !void {
        var label_buf: [max_label_len]u8 = undefined;
        var chord_buf: [64]u8 = undefined;
        const shown = label orelse labelFromName(&label_buf, name);
        const chord_text = if (chord) |c| c.format(&chord_buf) else "";

        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const owned_label = try self.alloc.dupe(u8, shown);
        errdefer self.alloc.free(owned_label);
        const owned_chord = try self.alloc.dupe(u8, chord_text);
        errdefer self.alloc.free(owned_chord);
        try self.commands.append(self.alloc, .{ .id = id, .name = owned_name, .label = owned_label, .chord = owned_chord });
    }

    /// Rebuilds `matches` for the current query and puts the cursor back
    /// on the best one: tightest match, then most recently run, then the
    /// order `add` was called in. With an empty query every command
    /// scores the same, so that's the recent ones first and then the
    /// caller's order.
    pub fn refilter(self: *List) !void {
        const q = self.query.text();
        self.matches.clearRetainingCapacity();
        for (self.commands.items, 0..) |c, i| {
            const s = bestScore(c, q) orelse continue;
            const recent = self.recent.rank(c.id) orelse std.math.maxInt(usize);
            try self.matches.append(self.alloc, .{ .index = i, .score = s, .recent = recent });
        }
        std.mem.sort(Match, self.matches.items, {}, lessThanMatch);
        self.list.reset();
    }

    /// The label or the name, whichever matches tighter; null if neither.
    fn bestScore(c: Command, q: []const u8) ?usize {
        const by_label = fuzzy.score(c.label, q);
        const by_name = fuzzy.score(c.name, q);
        if (by_label) |l| return if (by_name) |n| @min(l, n) else l;
        return by_name;
    }

    fn lessThanMatch(_: void, a: Match, b: Match) bool {
        if (a.score != b.score) return a.score < b.score;
        if (a.recent != b.recent) return a.recent < b.recent;
        return a.index < b.index;
    }

    pub fn matchCount(self: *const List) usize {
        return self.matches.items.len;
    }

    /// The command on match row `row`, if there is one.
    pub fn matchAt(self: *const List, row: usize) ?*const Command {
        if (row >= self.matches.items.len) return null;
        return &self.commands.items[self.matches.items[row].index];
    }

    /// The highlighted command.
    pub fn selected(self: *const List) ?*const Command {
        return self.matchAt(self.list.selected);
    }

    /// Moves the cursor `delta` rows, clamped at both ends: the list is
    /// ranked, so wrapping to the worst match is never what was meant.
    pub fn moveCursor(self: *List, delta: isize) void {
        self.list.step(delta, self.matches.items.len, .clamp);
    }

    /// Keeps `top` covering the cursor for a list `rows` tall.
    pub fn follow(self: *List, rows: usize) void {
        self.list.followClamped(rows, self.matches.items.len);
    }

    /// Follows a host-side scroll without moving the cursor.
    pub fn scrollTo(self: *List, row: usize, rows: usize) void {
        self.list.scrollTo(row, rows, self.matches.items.len);
    }

    pub fn clampScroll(self: *List, rows: usize) void {
        self.list.clampTop(rows, self.matches.items.len);
    }
};

pub const Popup = struct {
    alloc: std.mem.Allocator,
    chrome: popupframe.Chrome,
    /// Non-null exactly while the palette is open.
    list: ?List = null,
    /// What has been run from the palette this session. Survives
    /// `close`; each `open` copies it into the new list.
    recent: Recent = .{},
    /// Needs a `render`. Set by everything that changes what's shown; a
    /// caller also sets it on a resize or anything that moves the area.
    dirty: bool = false,

    /// Creates the palette's layers, hidden. Call it where it should
    /// stack: layers composite in creation order.
    pub fn init(alloc: std.mem.Allocator, client: *glyphwire.Client, style: Style) !Popup {
        return .{ .alloc = alloc, .chrome = try .init(client, style, header_rows) };
    }

    /// Restyles the palette in place (a theme change).
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

    /// Shows `l`, ranked against what was run recently. Takes ownership
    /// of `l`, and replaces a list already open.
    pub fn open(self: *Popup, l: List) !void {
        if (self.list) |*old| old.deinit();
        self.list = l;
        const opened = &self.list.?;
        opened.recent = self.recent;
        try opened.refilter();
        self.dirty = true;
    }

    pub fn close(self: *Popup) void {
        self.deinit();
        self.dirty = false;
        self.chrome.hide();
    }

    /// The highlighted command's id. Read it before `close`.
    pub fn selected(self: *const Popup) ?u32 {
        const l = if (self.list) |*open_l| open_l else return null;
        const c = l.selected() orelse return null;
        return c.id;
    }

    /// `selected` as the caller's action enum.
    pub fn selectedAs(self: *const Popup, comptime Action: type) ?Action {
        const id = self.selected() orelse return null;
        return @enumFromInt(id);
    }

    /// A pick is about to run: remember it for the next `open`.
    fn noteAccepted(self: *Popup) void {
        if (self.selected()) |id| self.recent.note(id);
    }

    pub fn key(self: *Popup, k: glyphwire.KeyEvent) !Outcome {
        const l = if (self.list) |*open_l| open_l else return .handled;
        switch (try popupframe.applyKey(l, k.key, k.mods, self.chrome.list_rows)) {
            .none => return .handled,
            .changed => {
                self.dirty = true;
                return .handled;
            },
            .cancel => {
                self.close();
                return .closed;
            },
            // Enter with nothing matching has nothing to run.
            .accept => {
                if (l.selected() == null) return .handled;
                self.noteAccepted();
                return .accept;
            },
        }
    }

    /// Typed characters (and a paste): the query.
    pub fn text(self: *Popup, t: []const u8) !void {
        const l = if (self.list) |*open_l| open_l else return;
        if (try l.query.insert(self.alloc, t)) {
            try l.refilter();
            l.follow(@max(self.chrome.list_rows, 1));
            self.dirty = true;
        }
    }

    /// A left press: a command row runs it, the query line does nothing,
    /// and anywhere outside the palette closes it. The caller swallows
    /// the click either way.
    pub fn click(self: *Popup, cell: glyphwire.CellPos) Outcome {
        const l = if (self.list) |*open_l| open_l else return .handled;
        switch (self.chrome.hit(cell)) {
            .outside => {
                self.close();
                return .closed;
            },
            .chrome => return .handled,
            .row => |i| {
                const row = l.list.top + i;
                if (row >= l.matchCount()) return .handled;
                l.list.selected = row;
                self.noteAccepted();
                return .accept;
            },
        }
    }

    /// A `scroll_offset` event. True when it was the palette's list.
    pub fn scrolled(self: *Popup, so: glyphwire.ScrollOffsetEvent) bool {
        if (!self.chrome.isList(so.layer)) return false;
        if (self.list) |*l| {
            l.scrollTo(so.row, self.chrome.list_rows);
            self.dirty = true;
        }
        return true;
    }

    /// Places and draws the palette in `area`, into `b`: across the
    /// middle near the top, as tall as its list (one row for "no
    /// matching commands").
    pub fn render(self: *Popup, b: *Batch, area: Rect) !void {
        self.dirty = false;
        const l = if (self.list) |*open_l| open_l else return;
        const want = header_rows + @max(l.matchCount(), 1);
        if (!try self.chrome.place(b, area, want)) return;
        const cols = self.chrome.rect.cols;
        const list_rows = self.chrome.list_rows;
        l.clampScroll(list_rows);

        try self.renderHeader(b, l, cols);
        try self.renderList(b, l, cols, list_rows);
        try self.chrome.setListExtent(b, l.matchCount(), l.list.top);
    }

    /// The query line, with the position in the list at its right end.
    fn renderHeader(self: *Popup, b: *Batch, l: *const List, cols: usize) !void {
        const s = self.chrome.style;
        var right: [32]u8 = undefined;
        const tail = std.fmt.bufPrint(&right, " {d}/{d} ", .{
            if (l.matchCount() == 0) 0 else l.list.selected + 1,
            l.matchCount(),
        }) catch "";
        const tail_w = try self.chrome.drawRight(b, 0, tail, s.dim_fg, null);
        try self.chrome.drawQuery(b, 0, &l.query, cols -| tail_w);
    }

    /// One command per row: its label, and its chord dimmed at the right
    /// end -- the palette doubles as the way to learn the keys.
    fn renderList(self: *Popup, b: *Batch, l: *const List, cols: usize, rows: usize) !void {
        const s = self.chrome.style;
        if (l.matchCount() == 0) return self.chrome.drawEmpty(b);
        try b.clearArea(.{ .layer = self.chrome.list_layer });
        for (0..rows) |i| {
            const c = l.matchAt(l.list.top + i) orelse break;
            const is_selected = l.list.top + i == l.list.selected;
            const fg = if (is_selected) s.selected_fg else s.text_fg;
            const chord_fg = if (is_selected) s.selected_fg else s.dim_fg;
            const bg: ?Color = if (is_selected) s.selected_bg else null;
            // The chord plus a cell either side; the label stops short of
            // it, and a palette too narrow for both keeps the label.
            const chord_w = glyphwire.stringWidth(c.chord);
            const chord_cols = if (chord_w > 0 and chord_w + 4 < cols) chord_w + 2 else 0;
            try b.writeSpans(&.{
                .{ .text = " " },
                .{ .text = c.label },
            }, .{ .layer = self.chrome.list_layer, .row = i, .col = 0, .fg = fg, .bg = bg, .max_cols = cols - chord_cols, .pad = true });
            if (chord_cols > 0) {
                try b.writeSpans(&.{
                    .{ .text = " " },
                    .{ .text = c.chord },
                    .{ .text = " " },
                }, .{ .layer = self.chrome.list_layer, .row = i, .col = cols - chord_cols, .fg = chord_fg, .bg = bg, .max_cols = chord_cols });
            }
        }
    }
};
