// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's completion popup: asking the language server, filtering as you
//! type, the popup's keys, accepting a candidate, and drawing the list.
//! `Ui` methods moved out of ui.zig and aliased back.

const std = @import("std");
const glyphwire = @import("glyphwire");
const display = @import("display.zig");
const lsp = @import("lsp.zig");
const complete = @import("complete.zig");

const ui = @import("ui.zig");
const Ui = ui.Ui;
const complete_auto_delay_ms = ui.complete_auto_delay_ms;
const complete_kind_cols = ui.complete_kind_cols;
const complete_max_cols = ui.complete_max_cols;
const complete_max_rows = ui.complete_max_rows;
const role = ui.role;

/// Asks for completions at the cursor. `trigger` is the trigger
/// character just typed, or null for an identifier being typed or an
/// explicit Ctrl+Space; `explicit` is the last, which is the only one
/// that says so on the statusline when nothing can answer.
pub fn requestCompletion(self: *Ui, trigger: ?[]const u8, explicit: bool) void {
    self.completion_due = null;
    const pool = if (self.lsp_pool) |*p| p else {
        if (explicit) {
            self.buf.ed.setStatus("LSP: not enabled", .{});
            self.status_dirty = true;
        }
        return;
    };
    if (self.buf.ed.mode != .insert) return;
    const path = self.buf.ed.path orelse return;
    const grammar = self.lspGrammarFor(path) orelse return;
    const abs = self.slotAbs(self.buf) orelse return;
    const uri = lsp.pathToUri(self.alloc, abs) catch return;
    defer self.alloc.free(uri);

    // The server must see what was just typed, or it completes the word
    // as it was before the last few keys.
    self.lspFlushChange();

    const cursor = self.buf.ed.pos();
    const line_text = self.buf.ed.buf.lineText(self.alloc, cursor.line) catch return;
    defer self.alloc.free(line_text);
    const ws = complete.wordStart(line_text, cursor.col);
    // A delayed identifier request whose word has gone by the time it
    // fires (the space after it was typed in the pause).
    if (trigger == null and !explicit and ws == cursor.col and self.completion == null) return;

    var it = pool.forLanguage(grammar);
    while (it.next()) |s| {
        if (!s.ready()) continue;
        const id = s.completionRequest(uri, .{
            .line = @intCast(cursor.line),
            .character = lsp.byteToCharacter(line_text, cursor.col, s.encoding),
        }, trigger) catch continue orelse continue;
        self.completion_request = id;
        self.completion_req_start = self.buf.ed.buf.lineStart(cursor.line) + ws;
        self.completion_req_line = cursor.line;
        return;
    }
    if (explicit) {
        self.buf.ed.setStatus("LSP: no server here can complete", .{});
        self.status_dirty = true;
    }
}

/// A completion reply: open (or replace) the popup, filtered by whatever
/// has been typed since the request went out. Takes ownership of
/// `items` whatever happens to them.
pub fn applyCompletion(
    self: *Ui,
    request_id: i64,
    server: []const u8,
    items: []lsp.CompletionItem,
    incomplete: bool,
) void {
    var owned: ?[]lsp.CompletionItem = items;
    defer if (owned) |o| lsp.freeCompletionItems(self.alloc, o);

    if (self.completion_request != request_id) return;
    self.completion_request = null;
    if (self.buf.ed.mode != .insert or self.focus != .buffer) return;

    // Still on the word it was asked about? A reply for a line the
    // cursor has left, or a word backspaced away, is stale.
    const cursor = self.buf.ed.pos();
    const start = self.completion_req_start;
    if (cursor.line != self.completion_req_line or self.buf.ed.cursor < start) return;

    if (items.len == 0) {
        if (!incomplete) self.completion_empty_at = start;
        self.closeCompletion();
        return;
    }

    // Edit ranges are in the server's encoding, and describe the line as
    // it was when the server read it -- convert now, the way diagnostics
    // are, so from here on a range's `character` is a byte column.
    if (self.lsp_pool) |*pool| {
        const enc = pool.encodingOf(server);
        const line_text = self.buf.ed.buf.lineText(self.alloc, cursor.line) catch return;
        defer self.alloc.free(line_text);
        for (items) |*item| {
            if (item.edit_range) |*r| {
                if (r.start.line != cursor.line) {
                    item.edit_range = null;
                    continue;
                }
                r.start.character = @intCast(lsp.characterToByte(line_text, r.start.character, enc));
            }
        }
    }

    self.closeCompletion();
    owned = null;
    self.completion = complete.Menu.init(self.alloc, items, start, cursor.line, incomplete);
    self.refilterCompletion();
}

/// Narrows the open popup to what is now typed after its word start,
/// closing it when nothing matches.
pub fn refilterCompletion(self: *Ui) void {
    const m = if (self.completion) |*x| x else return;
    const typed = self.buf.ed.buf.read(self.alloc, m.word_start, self.buf.ed.cursor) catch {
        self.closeCompletion();
        return;
    };
    defer self.alloc.free(typed);
    m.refilter(typed) catch {
        self.closeCompletion();
        return;
    };
    if (m.count() == 0) {
        if (!m.incomplete) self.completion_empty_at = m.word_start;
        self.closeCompletion();
        return;
    }
    self.completion_dirty = true;
}

pub fn closeCompletion(self: *Ui) void {
    if (self.completion) |*m| {
        m.deinit();
        self.completion = null;
        self.completion_dirty = true;
    }
}

/// Whether `text` ends in a completion trigger character for any server
/// on the current buffer.
pub fn isCompletionTrigger(self: *Ui, text: []const u8) bool {
    const pool = if (self.lsp_pool) |*p| p else return false;
    const path = self.buf.ed.path orelse return false;
    const grammar = self.lspGrammarFor(path) orelse return false;
    var it = pool.forLanguage(grammar);
    while (it.next()) |s| if (s.ready() and s.isCompletionTrigger(text)) return true;
    return false;
}

/// After an insert-mode edit: open, narrow or close the popup.
///
/// `typed` is the text just typed, or null for a deletion. A trigger
/// character asks at once; an identifier being typed asks after
/// `complete_auto_delay_ms` of quiet; with the popup already up, typing
/// only narrows it (and asks again only if the server said its list was
/// incomplete). A deletion never opens the popup, only narrows or
/// closes it.
pub fn afterInsertEdit(self: *Ui, typed: ?[]const u8) void {
    if (self.lsp_pool == null) return;
    if (self.buf.ed.mode != .insert or self.focus != .buffer) {
        self.closeCompletion();
        return;
    }
    const cursor = self.buf.ed.pos();
    const line_text = self.buf.ed.buf.lineText(self.alloc, cursor.line) catch return;
    defer self.alloc.free(line_text);
    const ws_col = complete.wordStart(line_text, cursor.col);
    const ws = self.buf.ed.buf.lineStart(cursor.line) + ws_col;
    const at_word = ws < self.buf.ed.cursor;
    // The word an empty answer was for is gone; a new one gets asked.
    if (!at_word) self.completion_empty_at = null;

    if (typed) |t| if (self.isCompletionTrigger(t)) {
        self.closeCompletion();
        self.requestCompletion(t, false);
        return;
    };

    if (self.completion) |m| {
        // Left the word: typed a space or punctuation, or deleted past
        // its start.
        if (m.line != cursor.line or m.word_start != ws) {
            self.closeCompletion();
        } else {
            const incomplete = m.incomplete;
            self.refilterCompletion();
            if (incomplete) self.armCompletion();
            return;
        }
    }

    if (typed == null or !at_word) return;
    // `123` is a number being typed, not a name to complete.
    if (std.ascii.isDigit(line_text[ws_col])) return;
    if (self.completion_empty_at == ws) return;
    // Already asked about this word; the reply will be filtered by what
    // has been typed since.
    if (self.completion_request != null and self.completion_req_start == ws) return;
    self.armCompletion();
}

pub fn armCompletion(self: *Ui) void {
    if (self.completion_due != null) return;
    self.completion_due = std.Io.Clock.Timestamp.fromNow(self.io, .{
        .raw = .fromMilliseconds(complete_auto_delay_ms),
        .clock = .awake,
    });
}

pub fn completionDue(self: *Ui) bool {
    const due = self.completion_due orelse return false;
    return due.raw.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= 0;
}

/// Closes the popup when what it was for has gone: insert mode left, the
/// sidebar or the finder took the keyboard, or the cursor moved off the
/// word (a click, an arrow). Run once a turn, so no path that moves the
/// cursor has to remember the popup exists.
pub fn syncCompletion(self: *Ui) void {
    const in_insert = self.buf.ed.mode == .insert and self.focus == .buffer and
        !self.finder.isOpen() and !self.shell.isFocused();
    if (!in_insert) {
        self.completion_due = null;
        self.completion_request = null;
        self.completion_empty_at = null;
        self.closeCompletion();
        return;
    }
    const m = if (self.completion) |*x| x else return;
    const cursor = self.buf.ed.pos();
    if (cursor.line != m.line or self.buf.ed.cursor < m.word_start) self.closeCompletion();
}

/// Inserts the selected completion over the word it completes: the
/// server's edit range when it sent one on this line, else the word
/// before the cursor.
pub fn acceptCompletion(self: *Ui) !void {
    const m = if (self.completion) |*x| x else return;
    const item = m.current() orelse {
        self.closeCompletion();
        return;
    };
    var start = m.word_start;
    if (item.edit_range) |r| {
        start = @min(self.buf.ed.buf.lineStart(m.line) + r.start.character, self.buf.ed.cursor);
    }
    try self.buf.ed.replaceBeforeCursor(start, item.insert);
    // Whatever comes next starts a new word; don't let this one's empty
    // answer (or its request) hold that up.
    self.completion_empty_at = null;
    self.closeCompletion();
    self.buf.full_redraw = true;
    self.grp.buffer_dirty = true;
    self.status_dirty = true;
    self.grp.tabs_dirty = true;
}

/// A key while the popup is up. Returns true when the popup took it.
///
/// Up/Down and Ctrl+N/Ctrl+P move (taken before the global Ctrl+N and
/// Ctrl+P chords, which only apply with the popup closed), Tab and Enter
/// accept, Escape closes only the popup so a second one leaves insert
/// mode. Left/Right/Home/End close it and then move as usual.
pub fn completionKey(self: *Ui, k: glyphwire.KeyEvent) !bool {
    const eq = std.mem.eql;
    const m = if (self.completion) |*x| x else return false;
    const rows = @min(m.count(), complete_max_rows);
    const ctrl = k.ctrl();
    // Alt+Up/Down moves the line, not the popup's cursor; the popup
    // closes like it does for any other cursor move.
    if (k.alt() and (eq(u8, k.key, "up") or eq(u8, k.key, "down"))) {
        self.closeCompletion();
        return false;
    }
    if (eq(u8, k.key, "down") or (ctrl and eq(u8, k.key, "n"))) {
        m.move(1, rows);
    } else if (eq(u8, k.key, "up") or (ctrl and eq(u8, k.key, "p"))) {
        m.move(-1, rows);
    } else if (eq(u8, k.key, "page_down")) {
        m.move(@intCast(rows), rows);
    } else if (eq(u8, k.key, "page_up")) {
        m.move(-@as(i64, @intCast(rows)), rows);
    } else if (!ctrl and (eq(u8, k.key, "tab") or eq(u8, k.key, "enter") or eq(u8, k.key, "kp_enter"))) {
        try self.acceptCompletion();
        return true;
    } else if (eq(u8, k.key, "escape")) {
        self.closeCompletion();
        return true;
    } else {
        if (eq(u8, k.key, "left") or eq(u8, k.key, "right") or
            eq(u8, k.key, "home") or eq(u8, k.key, "end"))
        {
            self.closeCompletion();
        }
        return false;
    }
    self.completion_dirty = true;
    return true;
}

/// Draws the completion popup, or hides it. Each row is the item's kind,
/// its label, and its detail (a type or signature) dimmed after it; the
/// label column lines up with the word being typed, so the text you are
/// finishing sits directly above the text that would finish it.
pub fn renderCompletion(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const m = if (self.completion) |*x| x else {
        try batch.setLayerVisible(self.completion_layer, false);
        return;
    };
    const b = self.grp.buffer_bounds;
    const rows = @min(@min(m.count(), complete_max_rows), b.rows);
    if (rows == 0 or b.cols < complete_kind_cols + 8) {
        try batch.setLayerVisible(self.completion_layer, false);
        return;
    }
    m.list.follow(rows);

    // As wide as the widest visible row wants, within the limits.
    var want: usize = 20;
    for (0..rows) |r| {
        const it = m.visible(r) orelse break;
        var w = 1 + complete_kind_cols + display.width(it.label, .{}) + 1;
        if (it.detail) |d| w += 2 + display.width(d, .{});
        want = @max(want, w);
    }
    const cols = @min(@min(want, complete_max_cols), b.cols);

    // Under the cursor's row if it fits, else above it.
    const cursor_row = b.row + self.caret_at.row;
    const row = if (cursor_row + 1 + rows <= b.row + b.rows)
        cursor_row + 1
    else if (cursor_row >= b.row + rows)
        cursor_row - rows
    else
        b.row;

    // The label column under the word's first character.
    const line_start = self.buf.ed.buf.lineStart(m.line);
    const before = try self.buf.ed.buf.read(self.alloc, line_start, @max(line_start, m.word_start));
    defer self.alloc.free(before);
    // Relative to the caret row's first column: the horizontal scroll
    // unwrapped, the row's start in the line wrapped.
    const word_col = display.width(before, self.displayOpts()) -| self.caret_at.left;
    const label_col = b.col + self.gutterWidth() + word_col;
    const want_col = label_col -| (1 + complete_kind_cols);
    const col = @max(b.col, @min(want_col, b.col + (b.cols -| cols)));

    try batch.setLayerSize(self.completion_layer, cols, rows);
    try batch.setLayerCellPosition(self.completion_layer, row, col);

    var kind_buf: [complete_kind_cols]u8 = undefined;
    for (0..rows) |r| {
        const it = m.visible(r) orelse break;
        const selected = m.list.top + r == m.list.selected;
        const bg = if (selected) role(.popup_selected_bg) else role(.popup_bg);

        const kind = complete.kindLabel(it.kind);
        const kn = @min(kind.len, complete_kind_cols);
        @memcpy(kind_buf[0..kn], kind[0..kn]);
        @memset(kind_buf[kn..], ' ');

        var runs: [5]glyphwire.client.Client.Span = undefined;
        var n: usize = 0;
        runs[n] = .{ .text = " " };
        n += 1;
        runs[n] = .{ .text = &kind_buf, .fg = role(.popup_kind) };
        n += 1;
        runs[n] = .{ .text = it.label, .fg = role(.popup_label) };
        n += 1;
        if (it.detail) |d| {
            runs[n] = .{ .text = "  " };
            n += 1;
            runs[n] = .{ .text = d, .fg = role(.popup_detail) };
            n += 1;
        }
        try batch.writeSpans(runs[0..n], .{
            .layer = self.completion_layer,
            .row = r,
            .col = 0,
            .fg = role(.popup_label),
            .bg = bg,
            .max_cols = cols,
            .pad = true,
            .selectable = false,
        });
    }
    try batch.setLayerVisible(self.completion_layer, true);
}
