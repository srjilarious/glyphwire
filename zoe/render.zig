// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's render pass: buffers (gutter, spans, selection, diagnostics,
//! soft-wrap rows), the tree, the tab strip, hover and the statusline,
//! plus `RowView` and the render plan they share. `Ui` methods moved out
//! of ui.zig and aliased back; the top-level types are re-exported from
//! ui.zig too.

const std = @import("std");
const glyphwire = @import("glyphwire");
const ls_icons = @import("applib").icons;
const editor = @import("editor.zig");
const display = @import("display.zig");
const softwrap = @import("wrap.zig");
const search = @import("search.zig");
const tree_mod = @import("tree.zig");
const homepath = @import("applib").homepath;
const syntax = @import("applib").syntax;
const tabs = @import("tabs.zig");
const tabstrip = @import("applib").tabstrip;
const lsp = @import("lsp.zig");
const selection_diff = @import("selection_diff.zig");
const diag = @import("diag.zig");
const fold = @import("fold.zig");
const hover_mod = @import("hover.zig");
const buffer_mod = @import("buffer.zig");
const lineedit = @import("applib").lineedit;

const ui = @import("ui.zig");
const Ui = ui.Ui;
const Bounds = ui.Bounds;
const Color = ui.Color;
const Group = ui.Group;
const TreeDirty = ui.TreeDirty;
const first_parse_budget_ms = ui.first_parse_budget_ms;
const hover_max_cols = ui.hover_max_cols;
const hover_max_rows = ui.hover_max_rows;
const hover_shadow_rows = ui.hover_shadow_rows;
const parse_slice_ms = ui.parse_slice_ms;
const role = ui.role;
const sign_error = ui.sign_error;
const sign_other = ui.sign_other;

/// One batch for the whole frame, so the panes go from the previous
/// state to this one in a single rendered frame rather than a band at
/// a time (decisions.md's Batch section). Each pane is redrawn only
/// when its own dirty flag is set: a keystroke on the `:` line marks
/// just the status row, leaving the buffer's syntax pass and the
/// tree's per-entry icons untouched.
pub fn render(self: *Ui) !void {
    self.syncTitle();
    var batch = self.client.batch();
    defer batch.deinit();
    const t_build = self.prof.now();
    const nested_before = self.prof.nestedNs();

    // Before the rows, so the host has scrolled to where the cursor
    // is by the time the frame it belongs to lands.
    if (self.tree_scroll_pending) |p| {
        self.tree_scroll_pending = null;
        try batch.setLayerScrollOffset(self.tree_layer, p.row, p.col);
    }

    // Read before the groups are drawn, which clears their flags: the
    // completion popup is placed against the focused buffer and has
    // to follow it when it repaints.
    const focused_buffer_dirty = self.grp.buffer_dirty;
    for (self.group_list.items) |g| {
        if (!g.buffer_dirty and !g.tabs_dirty) continue;
        try self.renderGroup(&batch, g);
    }
    if (self.tree_visible) switch (self.tree_dirty) {
        .none => {},
        .selection => try self.renderTreeSelection(&batch),
        .full => try self.renderTree(&batch),
    };
    // A keystroke in the sidebar's name field: its row and nothing
    // else, unless the whole listing was just written anyway.
    if (self.tree_visible and self.tree_edit_dirty and self.tree_dirty != .full)
        try self.renderTreeEditRow(&batch, self.treeContentCols());
    if (self.status_dirty) try self.renderStatus(&batch);
    // Last in the frame, as they are last in the compositing order. The
    // hover popup after the finder: both float, and a hover raised while
    // the finder is open is the newer of the two.
    if (self.finder.dirty) {
        const b = self.grp.buffer_bounds;
        try self.finder.render(&batch, .{ .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows });
    }
    // The palette is placed against the whole window, as VS Code's is:
    // it's about the program, not the pane.
    if (self.palette.dirty) {
        const w = self.winSize();
        try self.palette.render(&batch, .{ .cols = w.cols, .rows = w.rows });
    }
    // The extension list too: it is about zoe, not the pane.
    if (self.ext_list.dirty) {
        const w = self.winSize();
        try self.ext_list.render(&batch, .{ .cols = w.cols, .rows = w.rows });
    }
    if (self.hover_dirty) try self.renderHover(&batch);
    // Placed against the word being typed, so it follows a buffer
    // repaint (a scroll, a wrap) as well as its own changes.
    if (self.completion_dirty or (self.completion != null and focused_buffer_dirty))
        try self.renderCompletion(&batch);
    if (self.path_menu_dirty) try self.renderPathMenu(&batch);
    // With the statusline, which every input repaints, and with the
    // buffer, whose pane it is placed against.
    if (self.status_dirty or focused_buffer_dirty) try self.renderFindBar(&batch);
    if (self.tab_tip_dirty) try self.renderTabTip(&batch);
    self.prof.addNet(.paint, t_build, nested_before);

    if (self.prof.enabled()) {
        for (batch.msgs.items) |m| self.prof.bytes += m.len;
    }
    const t_send = self.prof.now();
    // Synced: returns once the server has applied the frame, so zoe
    // never has a second one in flight. Input that arrives meanwhile
    // queues on the listener and the run loop folds all of it into
    // the next frame -- which is what keeps a fast mouse drag from
    // turning into a backlog of frames the screen trails behind.
    var results = try batch.sendSynced();
    results.deinit();
    self.prof.add(.send, t_send);
    self.prof.endFrame();

    self.tree_dirty = .none;
    self.tree_edit_dirty = false;
    self.status_dirty = false;
    self.hover_dirty = false;
    self.completion_dirty = false;
    self.path_menu_dirty = false;
    self.tab_tip_dirty = false;
}

pub fn anyGroupDirty(self: *const Ui) bool {
    for (self.group_list.items) |g| {
        if (g.buffer_dirty or g.tabs_dirty) return true;
    }
    return false;
}

/// Draws one group's dirty panes into `batch`.
///
/// The render helpers all draw "the" group -- `grp`, and its shown
/// buffer `buf` -- because that is the one the keyboard edits and
/// nearly every change is to. A group without the keyboard is drawn
/// by pointing the pair at it for the duration, so the same code
/// paints every group; `render_focused` keeps the caret off it.
pub fn renderGroup(self: *Ui, batch: *glyphwire.client.Client.Batch, g: *Group) !void {
    const focused_grp = self.grp;
    const focused_buf = self.buf;
    self.grp = g;
    self.buf = g.slot();
    self.render_focused = g == focused_grp;
    defer {
        self.grp = focused_grp;
        self.buf = focused_buf;
        self.render_focused = true;
    }

    if (g.buffer_dirty) try self.renderBuffer(batch);
    if (g.tabs_dirty) {
        try self.renderTabs(batch);
        // The strip was laid out or scrolled again, and the tooltip
        // hangs from its tab.
        if (self.tab_tip_shown and self.tab_tip_group == g) self.tab_tip_dirty = true;
    }
    g.buffer_dirty = false;
    g.tabs_dirty = false;
}

/// Raises the tree pane's pending repaint to at least `level`. Never
/// lowers it: a full repaint already owed stays owed however many
/// cursor moves land on top of it before the next frame.
pub fn markTreeDirty(self: *Ui, level: TreeDirty) void {
    if (@intFromEnum(level) > @intFromEnum(self.tree_dirty)) self.tree_dirty = level;
}

/// Writes one run at `(row, col)` on a layer -- a single positioned
/// `write_text`.
pub fn writeAt(
    batch: *glyphwire.client.Client.Batch,
    layer: glyphwire.LayerHandle,
    row: usize,
    col: usize,
    text: []const u8,
    fg: Color,
    bg: Color,
) !void {
    try batch.writeText(text, .{ .layer = layer, .row = row, .col = col, .fg = fg, .bg = bg });
}

/// Redraws the buffer pane.
///
/// The pane is exactly viewport-sized (see the module note), so a
/// scroll can't be a host viewport move -- zoe owns `top_line` and
/// repaints. But repainting *every* visible row on every scroll tick
/// is `b.rows` write pairs down the socket per keystroke, which is
/// what made the pane feel heavy. So: on a pure vertical scroll of
/// less than a screen, shift the rows already on the layer with one
/// `move_content` and repaint only the band the scroll exposed. An
/// edit, a horizontal scroll, a jump of a screen or more, or a
/// bounds change (`Slot.full_redraw`) still repaints in full --
/// cases a row shift can't represent -- except that an edit whose
/// highlighting effect an incremental reparse could bound repaints
/// only the rows it touched (`renderChangedRows`).
pub fn renderBuffer(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const b = self.grp.buffer_bounds;
    if (b.cols == 0 or b.rows == 0) return;
    // A jump that lands inside a closed fold (a search match, `gd`, an
    // undo) opens it, before anything below lays the rows out.
    self.buf.ed.revealCursor();
    // A fold opening or closing moves every row below it, which no row
    // shift or caret-row repaint can express.
    if (self.buf.ed.buf.folds_gen != self.buf.prev_folds_gen) self.buf.full_redraw = true;
    self.scrollBufferToCursor();
    try self.syncBufferScrollbar(batch);
    // What every screen row shows this frame; all the row painters
    // below read it.
    try self.layoutRows();
    const row_hash = rowMapHash(self.row_map.items);

    // A fresh edit (or the first parse after choosing a language)
    // means the tree is stale. `syncHighlight` reparses -- incremental
    // when it can, whole-buffer otherwise -- and reports whether the
    // repaint can be confined to `hl_dirty_lines`.
    var localized = false;
    if (self.buf.hl) |*h| {
        if (h.languageSet() and self.buf.ed.buf.edits != self.buf.hl_edits) {
            const t_parse = self.prof.now();
            defer self.prof.add(.parse, t_parse);
            localized = self.syncHighlight(h) catch blk: {
                self.buf.full_redraw = true;
                break :blk false;
            };
            self.buf.hl_edits = self.buf.ed.buf.edits;
        }
        self.buf.ed.buf.clearEdits();
    }
    // Every row this frame paints reads its colours from the cache;
    // fill in the visible lines it is missing first, a run at a time.
    self.fillSpanCache();

    const cursor = self.buf.ed.pos();
    const scrolled = self.buf.top_line != self.buf.prev_top_line or
        self.buf.top_sub != self.buf.prev_top_sub or
        self.buf.left_col != self.buf.prev_left_col;
    const edited = self.buf.ed.buf.edits != self.buf.prev_edits;
    // Wrapped, an edit that changed how many rows a line takes moved
    // every row below it -- more than the edited lines to repaint. A
    // closed fold does the same when an edit changes how far it reaches.
    const by_rows = self.buf.ed.wrap or self.buf.ed.hasClosedFolds();
    if (by_rows and edited and row_hash != self.buf.prev_row_hash) self.buf.full_redraw = true;

    // A visual selection covers rows the caret never touches. When it
    // changed, the rows to repaint are the ones whose highlight
    // differs between the old span and the new -- one or two for a
    // drag step or a motion. That diff is in byte offsets, which an
    // edit moves, so an edit with a selection on either side of it
    // still repaints in full.
    const sel = self.buf.ed.selectionSpan();
    const sel_changed = !selEql(sel, self.buf.prev_sel);
    if (edited and (sel != null or self.buf.prev_sel != null)) self.buf.full_redraw = true;
    var repainted_full = false;
    // The scroll in screen rows, which wrapped is not the change in
    // `top_line`: measured from a common origin `rows` up so a
    // scroll either way stays unsigned. Too far to shift is a full
    // repaint.
    var prev_top = self.buf.prev_top_line;
    var top = self.buf.top_line;
    if (by_rows and scrolled and !edited and !self.buf.full_redraw) {
        if (self.wrappedScrollDelta(b.rows)) |d| {
            prev_top = b.rows;
            top = @intCast(@as(i64, @intCast(b.rows)) + d);
        } else self.buf.full_redraw = true;
    }
    if (!self.buf.full_redraw and !scrolled and !edited and !localized) {
        // Nothing but the caret moved (a bare `h`/`j`/`k`/`l`, a
        // word motion, an on-screen `:23k`): the pane is already
        // right everywhere except the rows the caret left and
        // landed on. Repaint just those -- no per-row syntax pass
        // over the whole viewport.
        try self.repaintCaretRows(batch, cursor.line);
    } else if (localized and !self.buf.full_redraw and !scrolled) {
        try self.renderChangedRows(batch, cursor.line);
    } else plan: switch (planBufferRender(.{
        .prev_top = prev_top,
        .top = top,
        .prev_left = self.buf.prev_left_col,
        .left = self.buf.left_col,
        .prev_edits = self.buf.prev_edits,
        .edits = self.buf.ed.buf.edits,
        .rows = b.rows,
        .force_full = self.buf.full_redraw,
    })) {
        .full => {
            try self.renderBufferRows(batch, 0, b.rows);
            repainted_full = true;
            break :plan;
        },
        .shift => |s| {
            // The scrolled-past rows are still valid where they land;
            // only the newly-uncovered band at one edge needs drawing.
            try batch.moveContent(self.grp.buffer_layer, null, null, s.count, s.dir);
            try self.renderBufferRows(batch, s.exposed_lo, s.exposed_hi);

            // The caret is drawn as an inverted cell over its row;
            // repaint the row it left (to clear that cell) and the row
            // it's on now, unless the exposed band already covered them.
            for (self.row_map.items, 0..) |rv, r| {
                if (rv.line != self.buf.prev_cursor_line and rv.line != cursor.line) continue;
                if (r >= s.exposed_lo and r < s.exposed_hi) continue;
                try self.renderBufferRow(batch, r);
            }
        },
    }

    // The rows the selection change covers, wherever the paths above
    // left them (a shift moved them along; the caret rows are
    // already fresh, which a second paint of costs nothing but bytes).
    if (sel_changed and !repainted_full) try self.repaintSelectionChange(batch, self.buf.prev_sel, sel, cursor.line);

    // The line-number gutter. Every text path above repainted it for
    // the rows it drew. A `move_content` scroll slides the old numbers
    // along with their lines, which leaves an `.absolute` gutter right
    // as it is -- each number still sits beside its own line, and the
    // caret's highlighted number rode along with it and was repainted
    // above. Only `.relative` numbers go stale: a scroll or a caret
    // move changes every row's distance. Repaint the whole gutter then.
    if (self.gutterWidth() > 0 and self.buf.ed.line_numbers == .relative and
        (scrolled or cursor.line != self.buf.prev_cursor_line))
    {
        var r: usize = 0;
        while (r < b.rows) : (r += 1) try self.renderGutterCell(batch, r);
    }

    // The caret is a block drawn as one inverted cell, on top of the
    // row just (re)painted. The host's own caret renderer only knows
    // about the root layer, and a client that owns its pane knows
    // better than the host where its cursor is anyway.
    //
    // Unless the host is drawing it (`caretShape`: insert mode's bar,
    // or the hollow box of an unfocused window), in which case all
    // that is left to do here is say which cell it belongs on.
    //
    // Only the group with the keyboard has a caret at all.
    if (self.render_focused) {
        if (try self.caretCell(cursor.line)) |at| {
            const row = at.row;
            const col = at.col;
            self.caret_at = .{ .row = row, .left = at.left };
            if (self.caretShape() != null) {
                try batch.setCursorOn(self.grp.buffer_layer, row, col);
            } else {
                const under = try self.cursorGrapheme();
                defer self.alloc.free(under);
                try writeAt(batch, self.grp.buffer_layer, row, col, under, role(.cursor_fg), role(.cursor_bg));
            }
        }
    }

    self.buf.prev_top_line = self.buf.top_line;
    self.buf.prev_top_sub = self.buf.top_sub;
    self.buf.prev_row_hash = row_hash;
    self.buf.prev_folds_gen = self.buf.ed.buf.folds_gen;
    self.buf.prev_left_col = self.buf.left_col;
    self.buf.prev_cursor_line = cursor.line;
    self.buf.prev_edits = self.buf.ed.buf.edits;
    self.buf.prev_sel = sel;
    self.buf.full_redraw = false;
}

/// Where the caret goes in the buffer pane: its screen row, its pane
/// column, and the display column its row starts at -- or null when
/// the caret's line is scrolled out of view (or, unwrapped, its
/// column is). Wrapped, a caret past the last character of a line
/// that fills its last row exactly is held on that row's last cell
/// rather than dropped.
pub fn caretCell(self: *Ui, line: usize) !?struct { row: usize, col: usize, left: usize } {
    const dcol = try self.cursorDisplayCol();
    const cols = self.textCols();
    for (self.row_map.items, 0..) |rv, r| {
        if (rv.line != line) continue;
        if (dcol < rv.left) continue;
        if (dcol >= rv.left + rv.cols and !rv.last) continue;
        var rel = dcol - rv.left;
        if (rel >= cols) {
            if (!self.buf.ed.wrap or cols == 0) return null;
            rel = cols - 1;
        }
        return .{ .row = r, .col = self.gutterWidth() + rel, .left = rv.left };
    }
    return null;
}

/// Repaints the on-screen rows whose selection highlight differs
/// between `old` and `new`, skipping the caret's row (repainted
/// already). Two spans of the same kind differ only where their ends
/// moved, so only the lines around those two byte ranges change; a
/// selection appearing, disappearing or switching between charwise and
/// linewise changes every line either one covers.
pub fn repaintSelectionChange(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    old: ?editor.Editor.SelSpan,
    new: ?editor.Editor.SelSpan,
    cursor_line: usize,
) !void {
    var ranges: [2]selection_diff.ByteRange = undefined;
    const n = selection_diff.changedRanges(old, new, &ranges);
    const buf = &self.buf.ed.buf;
    for (ranges[0..n]) |range| {
        // A byte either side: whether a line's highlight runs to the
        // pane edge depends on the span reaching its newline, which
        // is the byte just before the next line's start.
        const first = buf.lineAt(range.start -| 1);
        const last = buf.lineAt(range.end);
        for (self.row_map.items, 0..) |rv, r| {
            if (rv.line < first or rv.line > last) continue;
            if (rv.line == cursor_line or rv.line == self.buf.prev_cursor_line) continue;
            try self.renderBufferRow(batch, r);
        }
    }
}

/// Repaints the buffer rows the caret just left and just landed on.
/// Used when nothing else about the pane changed, so every other row
/// is already correct; `renderBuffer`'s caret pass draws the block
/// cursor on top afterwards.
pub fn repaintCaretRows(self: *Ui, batch: *glyphwire.client.Client.Batch, cursor_line: usize) !void {
    for (self.row_map.items, 0..) |rv, r| {
        if (rv.line == self.buf.prev_cursor_line or rv.line == cursor_line)
            try self.renderBufferRow(batch, r);
    }
}

/// Brings the highlighter's tree back in sync with the buffer after
/// an edit. Returns true when it managed an incremental reparse and
/// filled `hl_dirty_lines` with a bounded set of buffer lines that
/// -- together with the edited lines -- covers every highlighting
/// change, so the caller can repaint just those rows. Returns false
/// (and sets `Slot.full_redraw`) when the whole visible pane must
/// be repainted: no retained tree, the edit journal overflowed, the
/// line count changed, the injection layout shifted, or the change
/// is simply too broad to localise.
pub fn syncHighlight(self: *Ui, h: *syntax.Highlighter) !bool {
    const buf = &self.buf.ed.buf;
    self.hl_dirty_lines.clearRetainingCapacity();

    // A whole-buffer parse: the first one, or one an edit journal can't
    // be replayed onto -- including a prefix tree from a staged parse
    // still running, which an edit restarts. Staged, so a big file
    // draws its first screen highlighted without waiting for the rest
    // (see `beginParse`); `run` finishes it between events.
    if (!h.ready() or h.parsing() or buf.edits_overflowed or buf.pending_edits.items.len == 0) {
        const text = try buf.text(self.alloc);
        defer self.alloc.free(text);
        _ = try h.beginParse(text, self.parsePrefixEnd(), self.parseBudget(first_parse_budget_ms));
        self.buf.full_redraw = true;
        return false;
    }

    // Replay the journal onto the retained tree. An edit that spans
    // more than one line changes the line count, which shifts every
    // row below it -- the partial-repaint path can't express that, so
    // reparse incrementally (still the win) but repaint in full.
    var line_count_stable = true;
    for (buf.pending_edits.items) |e| {
        h.applyEdit(e.toSyntax());
        // The cached lines follow the edit the same way the tree does.
        self.buf.spans.applyEdit(self.alloc, e.start_point.line, e.old_end_point.line, e.new_end_point.line) catch
            self.buf.spans.reset(self.alloc);
        if (e.start_point.line != e.old_end_point.line or
            e.start_point.line != e.new_end_point.line) line_count_stable = false;
    }

    // Read straight out of the gap buffer: no copy per keystroke. The
    // highlighter keeps reading it (predicates, injection parses)
    // until the next edit is replayed onto it, here.
    self.hl_changed.clearRetainingCapacity();
    const localized = h.reparseIncremental(buf.textSource(), &self.hl_changed) catch {
        self.buf.full_redraw = true;
        return false;
    };
    // Lines whose colours may have moved without their text changing
    // lose their cached spans, on screen or not -- a scroll down to
    // them later must not paint the old colours.
    for (self.hl_changed.items) |cr| {
        const lo = buf.lineAt(cr.start);
        const hi = buf.lineAt(if (cr.end > cr.start) cr.end - 1 else cr.start);
        self.buf.spans.invalidate(self.alloc, lo, hi);
    }
    if (!localized or !line_count_stable) {
        self.buf.full_redraw = true;
        return false;
    }

    // Union: every directly-edited line, plus every line overlapping
    // a range tree-sitter flagged as structurally changed.
    for (buf.pending_edits.items) |e| {
        try self.addDirtyLine(e.start_point.line);
    }
    for (self.hl_changed.items) |cr| {
        const lo = buf.lineAt(cr.start);
        const hi = buf.lineAt(if (cr.end > cr.start) cr.end - 1 else cr.start);
        if (hi -| lo > self.grp.buffer_bounds.rows) {
            self.buf.full_redraw = true;
            return false;
        }
        var line = lo;
        while (line <= hi) : (line += 1) try self.addDirtyLine(line);
        if (self.hl_dirty_lines.items.len > self.grp.buffer_bounds.rows) {
            self.buf.full_redraw = true;
            return false;
        }
    }
    return true;
}

/// Where a staged parse's provisional prefix ends: the end of the line
/// one whole screen below the bottom of the pane, so a first scroll
/// stays coloured and a construct the cut splits (an unterminated
/// block comment) mis-colours rows nobody is looking at.
pub fn parsePrefixEnd(self: *const Ui) usize {
    const buf = &self.buf.ed.buf;
    const last = self.buf.top_line + 2 * @as(usize, self.grp.buffer_bounds.rows);
    return buf.lineEnd(@min(last, buf.lineCount() -| 1));
}

pub fn parseBudget(self: *const Ui, ms: i64) syntax.ParseBudget {
    return .{ .time = .{ .io = self.io, .ms = ms } };
}

/// Any buffer, shown or not, with a staged parse still running.
pub fn highlightPending(self: *const Ui) bool {
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| {
            if (slot.hl) |*h| if (h.parsing()) return true;
        }
    }
    return false;
}

/// Gives every buffer's parked parse one more slice. One that
/// finishes on a group's shown buffer repaints that pane: rows past
/// the prefix were drawn plain, and rows near the cut may change
/// colour. A background buffer that finishes just has its full tree
/// ready for when it is next shown (`setActive` repaints then anyway).
pub fn stepHighlight(self: *Ui) void {
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| {
            const h = if (slot.hl) |*x| x else continue;
            if (!h.parsing()) continue;
            const progress = h.continueParse(self.parseBudget(parse_slice_ms)) catch .done;
            if (progress == .done and slot == g.slot()) {
                slot.full_redraw = true;
                g.buffer_dirty = true;
            }
        }
    }
}

/// Adds `line` to `hl_dirty_lines` if it isn't already there. The set
/// stays small (bounded by the pane height), so a linear scan is fine.
pub fn addDirtyLine(self: *Ui, line: usize) !void {
    for (self.hl_dirty_lines.items) |existing| {
        if (existing == line) return;
    }
    try self.hl_dirty_lines.append(self.alloc, line);
}

/// Repaints only the on-screen rows an incremental reparse marked
/// dirty, plus the caret's old and new rows, leaving every other row
/// as it was. `renderBuffer`'s caret pass runs afterwards.
pub fn renderChangedRows(self: *Ui, batch: *glyphwire.client.Client.Batch, cursor_line: usize) !void {
    for (self.row_map.items, 0..) |rv, r| {
        if (self.dirtyLineListed(rv.line) or rv.line == self.buf.prev_cursor_line or rv.line == cursor_line) {
            try self.renderBufferRow(batch, r);
            // Whether the line above can fold depends on this one's
            // indent, so its fold marker may have just changed too.
            if (r > 0 and self.foldWidth() > 0) try self.renderGutterCell(batch, r - 1);
        }
    }
}

pub fn dirtyLineListed(self: *const Ui, line: usize) bool {
    for (self.hl_dirty_lines.items) |existing| {
        if (existing == line) return true;
    }
    return false;
}

/// Repaints buffer-pane screen rows `[from, to)` from the buffer's
/// current contents -- plain text, or vim's `~` past the end, without
/// the caret.
pub fn renderBufferRows(self: *Ui, batch: *glyphwire.client.Client.Batch, from: usize, to: usize) !void {
    var r = from;
    while (r < to) : (r += 1) try self.renderBufferRow(batch, r);
}

/// Cells the line-number gutter takes in the buffer pane right now --
/// zero unless `:set`/`zoe.conf.lua` turned it on. Widens by a column each
/// time the line count crosses a power of ten; an edit that changes
/// the count already forces a full pane repaint, so it is always safe
/// to read fresh.
pub fn gutterWidth(self: *const Ui) usize {
    return self.signWidth() + self.foldWidth() + gutterWidthFor(self.buf.ed.line_numbers, self.buf.ed.buf.lineCount());
}

/// Cells the fold column takes, between the sign column and the line
/// numbers (vim's `foldcolumn` sits there too): one while
/// `fold_column` is on.
pub fn foldWidth(self: *const Ui) usize {
    return if (self.buf.ed.fold_column) 1 else 0;
}

/// Cells reserved for the diagnostic sign column, left of the line
/// numbers: one when a language server is attached, none otherwise.
///
/// Fixed for the session (`signs`), not "one when there is something to
/// show". A column that appeared with the first diagnostic would reflow
/// every line of the pane sideways while the user was reading it, and
/// vanish again when the file went clean.
pub fn signWidth(self: *const Ui) usize {
    return if (self.signs) 1 else 0;
}

/// Buffer-text width: the pane less the gutter. Saturates to zero if
/// the pane is narrower than the gutter (a degenerate split).
pub fn textCols(self: *const Ui) usize {
    return self.grp.buffer_bounds.cols -| self.gutterWidth();
}

/// Paints just the line-number cell for buffer screen row `r`, in
/// `fg_text` on the caret's line and `fg_dim` elsewhere. A no-op when
/// the gutter is off. Every buffer-text path calls this for the rows
/// it repaints; `renderBuffer` calls it for the rest when a scroll or
/// a `.relative` caret move changed numbers it did not otherwise touch.
pub fn renderGutterCell(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize) !void {
    const width = self.gutterWidth();
    if (width == 0) return;
    const rv = self.row_map.items[r];
    const line = rv.line;
    const cursor_line = self.buf.ed.pos().line;
    // A wrapped line's continuation rows get a blank gutter, the
    // same as the rows past the end: one number per line.
    const past_end = line >= self.buf.ed.buf.lineCount() or rv.sub > 0;

    // The sign first, in its own cell: the worst severity starting on
    // this line, or a blank. Painted even on a clean line, because this
    // is also what takes yesterday's mark off. Both glyphs are
    // East Asian "ambiguous" width, which the host draws one cell
    // wide, so the number's span starts right after it.
    const signs = self.signWidth();
    var sign: []const u8 = " ";
    var sign_fg = role(.fg_dim);
    if (signs > 0 and !past_end) {
        if (self.diagSeverityForLine(line)) |sev| {
            sign = if (sev == .err) sign_error else sign_other;
            sign_fg = self.diagColor(sev);
        }
    }

    // The fold marker: ▸ on a closed fold, a dim ▾ on a line that can
    // fold, blank elsewhere. Same width rule as the signs.
    const folds = self.foldWidth();
    var marker: []const u8 = " ";
    var marker_fg = role(.fg_dim);
    if (folds > 0 and !past_end) {
        if (fold.isClosed(self.buf.ed.buf.closed_folds.items, line)) {
            marker = fold_closed_marker;
            marker_fg = role(.fg);
        } else if (fold.isFoldStart(&self.buf.ed.buf, line, self.buf.ed.tab_width)) {
            marker = fold_open_marker;
        }
    }

    // Relative numbers count the lines on screen, so a closed fold is
    // one -- `5j` lands where the gutter says 5.
    const distance = if (self.buf.ed.hasClosedFolds())
        fold.visibleDistance(self.buf.ed.hiddenLines(), line, cursor_line)
    else if (line > cursor_line) line - cursor_line else cursor_line - line;
    var buf: [32]u8 = undefined;
    const cell = gutterCellText(
        &buf,
        self.buf.ed.line_numbers,
        width - signs - folds,
        line,
        distance,
        past_end,
    );
    const fg = if (!past_end and line == cursor_line) role(.fg) else role(.fg_dim);

    // Sign, marker and number as one write: the gutter is repainted for
    // every row a frame draws, and a write's fixed fields cost more than
    // the handful of cells it carries.
    var spans: [3]glyphwire.client.Client.Span = undefined;
    var n: usize = 0;
    if (signs > 0) {
        spans[n] = .{ .text = sign, .fg = sign_fg };
        n += 1;
    }
    if (folds > 0) {
        spans[n] = .{ .text = marker, .fg = marker_fg };
        n += 1;
    }
    spans[n] = .{ .text = cell, .fg = fg };
    n += 1;
    try batch.writeSpans(spans[0..n], .{
        .layer = self.grp.buffer_layer,
        .row = r,
        .col = 0,
        .bg = role(.bg),
    });
}

/// The fold column's markers. Both are East Asian "ambiguous" width,
/// drawn one cell wide like the diagnostic signs.
pub const fold_open_marker = "\u{25be}"; // ▾
pub const fold_closed_marker = "\u{25b8}"; // ▸

/// The worst diagnostic severity starting on buffer `line` of the active
/// buffer, or null. Runs once per visible row per frame, so it does no
/// allocation -- the path resolution is the only cost, and it is skipped
/// entirely when nothing has published anything.
pub fn diagSeverityForLine(self: *Ui, line: usize) ?lsp.Severity {
    if (self.lsp_pool == null) return null;
    const abs = self.slotAbs(self.buf) orelse return null;
    return self.diags.worstOnLine(abs, @intCast(line));
}

pub fn renderBufferRow(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize) !void {
    const rv = self.row_map.items[r];
    const line = rv.line;
    const gutter = self.gutterWidth();
    const cols = self.textCols();

    try self.renderGutterCell(batch, r);

    if (line >= self.buf.ed.buf.lineCount()) {
        // vim's marker for "past the end of the buffer", the rest of
        // the row padded by the host.
        try batch.writeText("~", .{
            .layer = self.grp.buffer_layer,
            .row = r,
            .col = gutter,
            .fg = role(.fg_dim),
            .bg = role(.bg),
            .max_cols = cols,
            .pad = true,
        });
        return;
    }

    const text = try self.buf.ed.buf.lineText(self.alloc, line);
    defer self.alloc.free(text);

    // Highlighted rows are painted a colour run at a time; on any
    // failure (or with no grammar) the same painter runs with no
    // spans at all, which is exactly a plain row in `fg_text`.
    var painted = false;
    if (self.buf.hl) |*h| {
        if (h.ready() and self.renderRowSpans(batch, r, rv, text)) painted = true;
    }
    if (!painted) try self.rowSpansImpl(batch, r, rv, text, &.{});

    // Overpaint, in order: search matches, then the selection on top
    // of them. Both are second writes over the text just laid down
    // rather than threaded through every colour run, and the
    // selection wins because it is the thing you are about to act on.
    try self.paintMatchRow(batch, r, rv, text);
    try self.paintSelectionRow(batch, r, rv, text);
    // Diagnostics last, and through `set_underline` rather than a write:
    // the two overpaints above are full cell writes that would clear a
    // squiggle laid down before them, and the underline is a channel of
    // its own so it doesn't have to fight either of them for the cell.
    // Every path that repaints a row comes through here, so a mark is
    // re-applied whenever the row under it is redrawn.
    try self.paintDiagnosticRow(batch, r, rv, text);
    if (rv.last) try self.paintFoldTail(batch, r, rv, text);
}

/// After the text of a closed fold's line, a dim `⋯ N lines` saying how
/// much it hides, clipped to the pane.
pub fn paintFoldTail(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize, rv: RowView, text: []const u8) !void {
    if (!fold.isClosed(self.buf.ed.buf.closed_folds.items, rv.line)) return;
    const hidden = self.buf.ed.rowLast(rv.line) - rv.line;
    if (hidden == 0) return;
    const end_col = display.width(text, self.displayOpts());
    const cols = self.textCols();
    const at = (end_col -| rv.left) + 1;
    if (end_col < rv.left or at >= cols) return;
    var buf: [48]u8 = undefined;
    const tail = std.fmt.bufPrint(&buf, "\u{22ef} {d} line{s}", .{ hidden, if (hidden == 1) "" else "s" }) catch return;
    try batch.writeText(tail, .{
        .layer = self.grp.buffer_layer,
        .row = r,
        .col = self.gutterWidth() + at,
        .fg = role(.fg_dim),
        .bg = role(.bg),
        .max_cols = cols - at,
    });
}

/// Draws every diagnostic starting on the row's buffer line as a
/// coloured underline over its range, clipped to the columns the row
/// shows.
///
/// A zero-width range -- which is how servers often report "the error is
/// *here*" -- is widened to one cell, because a squiggle under nothing is
/// nothing. Worst severity last, so where two diagnostics overlap the
/// more serious colour is the one left on the cells.
pub fn paintDiagnosticRow(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    r: usize,
    rv: RowView,
    text: []const u8,
) !void {
    if (self.lsp_pool == null) return;
    const abs = self.slotAbs(self.buf) orelse return;
    const line = rv.line;
    const cols = rv.cols;
    if (cols == 0) return;

    var row: std.ArrayList(diag.Entry) = .empty;
    defer row.deinit(self.alloc);
    self.diags.onLine(abs, @intCast(line), &row, self.alloc) catch return;
    if (row.items.len == 0) return;

    const opts = self.displayOpts();
    // `onLine` gives worst first; paint in reverse so the worst is the
    // one that ends up on any cell two of them share.
    var i = row.items.len;
    while (i > 0) {
        i -= 1;
        const e = row.items[i];
        const lo_b = @min(@as(usize, e.range.start.character), text.len);
        // A range that runs past this line's end (a multi-line
        // diagnostic) is clipped to it: the rows below have their own
        // marks, or deliberately none. See `diag.Store.onLine`.
        const hi_b = if (e.range.end.line > e.range.start.line)
            text.len
        else
            @min(@as(usize, e.range.end.character), text.len);

        const start_dc = display.colOfByte(text, lo_b, opts);
        var end_dc = display.colOfByte(text, @max(hi_b, lo_b), opts);
        if (end_dc <= start_dc) end_dc = start_dc + 1;
        if (end_dc <= rv.left or start_dc >= rv.left + cols) continue;

        const vis_lo = @max(start_dc, rv.left);
        const vis_hi = @min(end_dc, rv.left + cols);
        if (vis_hi <= vis_lo) continue;

        try batch.setUnderline(.{
            .layer = self.grp.buffer_layer,
            .row = r,
            .col = self.gutterWidth() + (vis_lo - rv.left),
            .rows = 1,
            .cols = vis_hi - vis_lo,
            .underline = .curly,
            .underline_color = self.diagColor(e.severity),
        });
    }
}

/// Where the hover popup goes: under the cursor when there is room
/// below it, above it otherwise -- so it never covers the identifier it
/// is describing. Clamped inside the buffer pane like `finderRect`.
/// `want_rows` counts the frame's two rows.
pub fn hoverRect(self: *const Ui, want_rows: usize) Bounds {
    const b = self.grp.buffer_bounds;
    const cols = @min(hover_max_cols, b.cols);
    const rows = @min(@min(want_rows, hover_max_rows + 2), b.rows);

    // The caret's screen row as last drawn -- not `line - top_line`
    // once lines wrap.
    const cursor_row = b.row + self.caret_at.row;
    // Below if it fits, else above; if neither fits (a two-row pane),
    // below and clipped by the clamp. Above leaves a row for the
    // shadow when there is one to spare, so it doesn't darken the very
    // line being described.
    const below = cursor_row + 1 + rows <= b.row + b.rows;
    const row = if (below)
        cursor_row + 1
    else if (cursor_row >= b.row + rows + hover_shadow_rows)
        cursor_row - rows - hover_shadow_rows
    else if (cursor_row >= b.row + rows)
        cursor_row - rows
    else
        b.row;

    // Left-aligned with the cursor's column, pulled back inside the
    // pane's right edge rather than hanging off it.
    const cursor_col = b.col + self.gutterWidth();
    const col = @min(cursor_col, b.col + (b.cols -| cols));
    return .{ .row = row, .col = col, .cols = cols, .rows = rows };
}

/// Draws the hover popup, or hides its layer when there is none.
///
/// The reply arrives as markdown and is drawn as three kinds of row (see
/// `zoe/hover.zig`): fenced code in its grammar's colours on a darker
/// band, prose with the markdown punctuation taken off, and a `---` rule
/// as a line across. Headings, lists and emphasis are not styled -- that
/// is the `md/` renderer's job, and a bigger one than it looks, since it
/// draws into a layer of its own.
///
/// The panel is the `hover_panel_style` nine-patch over the whole layer:
/// its rounded border sits in the outer ring of cells, which nothing
/// writes to, and prose rows are transparent so its fill shows. The
/// layer's host-drawn shadow (set once in `init`) stands it off an
/// editor background of nearly its own colour. A `---` rule runs the
/// full width, so it meets the border on both sides.
pub fn renderHover(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const h = if (self.hover) |*open| open else return self.hideHover(batch);

    // Wrapped to the popup's width first, so the height is the height of
    // what will actually be drawn rather than of the source text. Four
    // columns go to the frame and a one-cell margin inside it each side.
    const wrap_cols = @min(hover_max_cols, self.grp.buffer_bounds.cols) -| 4;
    if (wrap_cols == 0) return self.hideHover(batch);
    var rows: std.ArrayList(HoverRow) = .empty;
    defer rows.deinit(self.alloc);
    try wrapHover(self.alloc, &h.doc, wrap_cols, &rows);

    const r = self.hoverRect(rows.items.len + 2);
    self.hover_rect = r;
    if (r.cols < 4 or r.rows < 3) return self.hideHover(batch);
    if (h.scroll >= rows.items.len) h.scroll = rows.items.len -| 1;

    try batch.setLayerSize(self.hover_layer, r.cols, r.rows);
    try batch.setLayerCellPosition(self.hover_layer, r.row, r.col);
    if (self.hover_panel_patch) |np| try batch.updateNinePatch(self.hover_layer, np, .{ .rows = r.rows, .cols = r.cols });
    // A resize keeps whatever the old cells held, so the frame ring
    // (which is otherwise never written) is blanked every time.
    try batch.clearArea(.{ .layer = self.hover_layer });

    // A rule's run: `cols` wide, so it crosses the frame cells and
    // meets the nine-patch's border at both edges.
    var hline: std.ArrayList(u8) = .empty;
    defer hline.deinit(self.alloc);
    for (0..r.cols) |_| try hline.appendSlice(self.alloc, "\u{2500}");

    var runs: std.ArrayList(glyphwire.client.Client.Span) = .empty;
    defer runs.deinit(self.alloc);
    const inner_rows = r.rows - 2;
    for (0..inner_rows) |i| {
        const row = i + 1;
        const idx = h.scroll + i;
        const hr: ?HoverRow = if (idx < rows.items.len) rows.items[idx] else null;
        const kind: hover_mod.Kind = if (hr) |x| h.doc.lines[x.line].kind else .prose;

        if (kind == .rule) {
            try batch.writeText(hline.items, .{
                .layer = self.hover_layer,
                .row = row,
                .col = 0,
                .fg = role(.popup_border),
                .max_cols = r.cols,
                .selectable = false,
            });
            continue;
        }

        // Prose is transparent, so the panel is its background.
        const bg: ?Color = if (kind == .code) role(.popup_code_bg) else null;
        runs.clearRetainingCapacity();
        // The inner margin, in the row's own background so a code band
        // runs from frame to frame.
        try runs.append(self.alloc, .{ .text = " " });
        if (hr) |x| {
            const line = h.doc.lines[x.line];
            if (x.indent > 0) try runs.append(self.alloc, .{ .text = spaces[0..@min(x.indent, spaces.len)] });
            try colorRuns(self.alloc, line.text, h.spans[x.line], x.start, x.end, role(.popup_fg), &runs);
        }
        // One padded write inside the frame: `pad` fills the rest,
        // right margin included, so a code band runs edge to edge
        // whatever the text length.
        try batch.writeSpans(runs.items, .{
            .layer = self.hover_layer,
            .row = row,
            .col = 1,
            .fg = role(.popup_fg),
            .bg = bg,
            .max_cols = r.cols - 2,
            .pad = true,
        });
    }
    try batch.setLayerVisible(self.hover_layer, true);
}

pub fn hideHover(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    try batch.setLayerVisible(self.hover_layer, false);
}

/// Draws the tab tooltip, or hides its layer: the hovered buffer's
/// absolute path with `$HOME` as `~`, on the hover popup's panel,
/// hanging from the tab (`tabs.tipRect`). A path wider than the window
/// loses its head rather than its file name (`tabs.clipHead`).
pub fn renderTabTip(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const hide = !self.tab_tip_shown or self.tab_tip_index == null;
    const index = self.tab_tip_index orelse 0;
    const g = self.tab_tip_group orelse return batch.setLayerVisible(self.tab_tip_layer, false);
    // The buffer list or the strip may have changed under a tooltip
    // that is still up.
    if (hide or index >= g.buffers.items.len or index >= g.tab_spans.items.len)
        return batch.setLayerVisible(self.tab_tip_layer, false);
    const slot = g.buffers.items[index];
    const abs = self.slotAbs(slot) orelse return batch.setLayerVisible(self.tab_tip_layer, false);

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = homepath.collapseHome(abs, self.environ.get("HOME"), &home_buf);

    // The window's full width: the statusline spans it.
    const area: tabs.TipArea = .{
        .strip_row = g.tabs_bounds.row,
        .strip_col = g.tabs_bounds.col + g.tab_win.left,
        .scroll = g.tab_scroll,
        .area_col = self.status_bounds.col,
        .area_cols = self.status_bounds.cols,
    };
    const r = tabs.tipRect(g.tab_spans.items[index], glyphwire.stringWidth(path), area) orelse
        return batch.setLayerVisible(self.tab_tip_layer, false);
    const clipped = tabs.clipHead(path, r.cols - tabs.tip_chrome_cols);

    try batch.setLayerSize(self.tab_tip_layer, r.cols, tabs.tip_rows);
    try batch.setLayerCellPosition(self.tab_tip_layer, r.row, r.col);
    if (self.tab_tip_patch) |np| try batch.updateNinePatch(self.tab_tip_layer, np, .{ .rows = tabs.tip_rows, .cols = r.cols });
    // A resize keeps whatever the old cells held, so the corner cells
    // (which are otherwise never written) are blanked every time.
    try batch.clearArea(.{ .layer = self.tab_tip_layer });
    // Transparent, so the panel is the text's background. Between the
    // two corner cells, and padded so a shorter path than last time
    // leaves nothing behind.
    const spans = [_]glyphwire.client.Client.Span{
        .{ .text = if (clipped.ellipsis) tabs.tip_ellipsis else "" },
        .{ .text = clipped.tail },
    };
    try batch.writeSpans(&spans, .{
        .layer = self.tab_tip_layer,
        .row = 0,
        .col = 1,
        .fg = role(.popup_fg),
        .max_cols = r.cols - tabs.tip_chrome_cols,
        .pad = true,
    });
    try batch.setLayerVisible(self.tab_tip_layer, true);
}

/// Closes the popup. Returns whether there was one, so a key can be
/// swallowed by the closing (Escape) or fall through (anything else).
pub fn closeHover(self: *Ui) bool {
    if (self.hover) |*h| {
        h.deinit();
        self.hover = null;
        self.hover_dirty = true;
        return true;
    }
    return false;
}

/// Paints every search match on buffer `line` -- `bg_match`, or
/// `bg_match_current` for the one the cursor is on. A no-op when
/// there is no pattern to highlight (`:noh`, or no search yet).
///
/// Matches are found per row, at draw time, rather than collected
/// once into a list: a row is a few dozen bytes, the scan is a
/// `memchr`-shaped loop over it, and a stored list would have to be
/// invalidated by every edit.
pub fn paintMatchRow(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    r: usize,
    rv: RowView,
    text: []const u8,
) !void {
    const pat = self.buf.ed.highlightPattern() orelse return;
    const line = rv.line;
    const opts = self.buf.ed.highlightOpts();
    // The find widget's Alt+L: only the matches it would find.
    const scope = self.buf.ed.highlightScope();
    const ls = self.buf.ed.buf.lineStart(line);
    const line_end = self.buf.ed.buf.lineEnd(line);

    var at = ls;
    while (search.firstIn(&self.buf.ed.buf, pat, opts, at, line_end)) |hit| {
        at = hit + 1;
        if (scope) |s| {
            if (hit < s.lo or hit + pat.len > s.hi) continue;
        }
        // A match running off the end of its line is clipped to it:
        // the rest belongs to the row below, which paints its own.
        const hi = @min(hit + pat.len, line_end);
        const current = self.buf.ed.search_match == hit;
        try self.paintRowSpan(
            batch,
            r,
            rv,
            text,
            hit - ls,
            hi - ls,
            if (current) role(.match_current_bg) else role(.match_bg),
        );
    }
}

/// Repaints the byte range `[lo_b, hi_b)` of a row's `text` in `bg`,
/// keeping the characters themselves. Clipped to the columns the row
/// shows; a no-op when none of it is on screen. Shared by the
/// selection and the search highlight, which differ only in colour
/// and in how they pick the range.
pub fn paintRowSpan(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    r: usize,
    rv: RowView,
    text: []const u8,
    lo_b: usize,
    hi_b: usize,
    bg: Color,
) !void {
    const cols = rv.cols;
    if (cols == 0 or hi_b <= lo_b) return;

    const opts = self.displayOpts();
    const start_dc = display.colOfByte(text, @min(lo_b, text.len), opts);
    const end_dc = display.colOfByte(text, @min(hi_b, text.len), opts);
    if (end_dc <= rv.left or start_dc >= rv.left + cols) return;

    const vis_lo = @max(start_dc, rv.left);
    const vis_hi = @min(end_dc, rv.left + cols);
    if (vis_hi <= vis_lo) return;

    var overlay: std.ArrayList(u8) = .empty;
    defer overlay.deinit(self.alloc);
    try display.appendCols(self.alloc, &overlay, text, vis_lo, vis_hi - vis_lo, opts);

    try writeAt(
        batch,
        self.grp.buffer_layer,
        r,
        self.gutterWidth() + vis_lo - rv.left,
        overlay.items,
        role(.fg),
        bg,
    );
}

/// If the row's buffer line overlaps the visual selection, repaints
/// its selected columns with `bg_selected` (keeping the default text
/// colour). A charwise selection highlights the covered characters,
/// and one cell past the text for a selected newline; a linewise one
/// runs to the pane's right edge, like vim -- and so does one that
/// carries on into the next row of a wrapped line, across the blank a
/// word break left. A no-op when nothing is selected or the selected
/// part is scrolled out of view.
pub fn paintSelectionRow(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    r: usize,
    rv: RowView,
    text: []const u8,
) !void {
    const span = self.buf.ed.selectionSpan() orelse return;
    const line = rv.line;
    const ls = self.buf.ed.buf.lineStart(line);
    const has_newline = line + 1 < self.buf.ed.buf.lineCount();
    const cover = selection_diff.lineCover(span, ls, text.len, has_newline) orelse return;

    const gutter = self.gutterWidth();
    const cols = self.textCols();
    if (cols == 0) return;

    const opts = self.displayOpts();
    // The row's own columns end at `row_end`; past it is the blank
    // tail of the pane, which the highlight only fills when it runs
    // on beyond the row (the newline's cell, or into the next row).
    const row_end = rv.left + rv.cols;
    const start_dc = display.colOfByte(text, cover.lo, opts);
    var end_dc = if (cover.to_edge)
        rv.left + cols
    else
        display.colOfByte(text, cover.hi, opts) + @intFromBool(cover.newline);
    if (end_dc > row_end and !rv.last) end_dc = rv.left + cols;
    // A selection starting on a later row of this line.
    if (start_dc >= row_end and !(rv.last and (cover.to_edge or cover.newline))) return;
    if (end_dc <= rv.left) return;

    const vis_lo = @max(start_dc, rv.left);
    const vis_hi = @min(end_dc, rv.left + cols);
    if (vis_hi <= vis_lo) return;

    // The characters under the highlight, then spaces out to the
    // selection's end (a linewise selection past the text, the
    // newline slot of a charwise one, or a wrapped row's tail) --
    // never the next row's characters.
    var overlay: std.ArrayList(u8) = .empty;
    defer overlay.deinit(self.alloc);
    const chars_hi = @max(@min(vis_hi, row_end), vis_lo);
    try display.appendCols(self.alloc, &overlay, text, vis_lo, chars_hi - vis_lo, opts);
    try overlay.appendNTimes(self.alloc, ' ', vis_hi - chars_hi);

    try writeAt(batch, self.grp.buffer_layer, r, gutter + vis_lo - rv.left, overlay.items, role(.fg), role(.selection_bg));
}

/// Paints buffer row `r` (showing `rv` of its line, whole text `text`)
/// as tree-sitter colour runs clipped to the row's columns.
/// Returns false if the highlighter couldn't produce spans, so the
/// caller can fall back to a plain write.
pub fn renderRowSpans(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    r: usize,
    rv: RowView,
    text: []const u8,
) bool {
    const line = rv.line;
    const spans = self.buf.spans.get(line) orelse blk: {
        // `fillSpanCache` covers every visible line, so this is only
        // a row it couldn't fill (an allocation failure): query it on
        // its own rather than paint it plain.
        const h = &self.buf.hl.?;
        const t_spans = self.prof.now();
        h.lineSpans(self.buf.ed.buf.lineStart(line), self.buf.ed.buf.lineEnd(line), &self.hl_scratch) catch return false;
        self.prof.add(.spans, t_spans);
        self.prof.span_lines += 1;
        break :blk self.hl_scratch.items;
    };
    self.rowSpansImpl(batch, r, rv, text, spans) catch return false;
    return true;
}

/// How many already-cached lines `fillSpanCache` will re-query to keep
/// two missing lines in one run. Re-querying a few lines costs less
/// than a second query's descent from the root.
pub const span_run_gap: usize = 8;

/// Computes the spans of every visible line the cache is missing, one
/// `linesSpans` query per run of nearby missing lines, so the rows
/// this frame paints all read from the cache. A scroll by a line
/// misses one line; a scroll back over rows seen before, a caret move
/// or a selection repaint misses none.
pub fn fillSpanCache(self: *Ui) void {
    const h = if (self.buf.hl) |*x| x else return;
    if (!h.ready()) return;
    const buf = &self.buf.ed.buf;
    self.buf.spans.sync(self.alloc, h.generation, buf.lineCount()) catch return;

    // One past the last line on screen -- fewer than the pane's rows
    // when lines wrap.
    const map = self.row_map.items;
    const last_shown = if (map.len > 0) map[map.len - 1].line else self.buf.top_line;
    const end = @min(last_shown + 1, buf.lineCount());
    var line = self.buf.top_line;
    while (line < end) {
        if (self.buf.spans.get(line) != null) {
            line += 1;
            continue;
        }
        var last_missing = line;
        var next = line + 1;
        while (next < end and next - last_missing <= span_run_gap) : (next += 1) {
            if (self.buf.spans.get(next) == null) last_missing = next;
        }
        self.fillSpanRun(h, line, last_missing + 1) catch return;
        line = last_missing + 1;
    }
}

/// Queries buffer lines `[lo, hi)` in one `linesSpans` call and caches
/// each line's spans.
pub fn fillSpanRun(self: *Ui, h: *syntax.Highlighter, lo: usize, hi: usize) !void {
    const t_spans = self.prof.now();
    defer self.prof.add(.spans, t_spans);
    const buf = &self.buf.ed.buf;
    self.hl_lines.clearRetainingCapacity();
    for (lo..hi) |l| try self.hl_lines.append(self.alloc, .{ .start = buf.lineStart(l), .end = buf.lineEnd(l) });
    try h.linesSpans(self.hl_lines.items, &self.hl_scratch, &self.hl_bounds);
    const bounds = self.hl_bounds.items;
    for (lo..hi, 0..) |l, i| try self.buf.spans.put(self.alloc, l, self.hl_scratch.items[bounds[i]..bounds[i + 1]]);
    self.prof.span_lines += @intCast(hi - lo);
}

/// Paints one buffer row as colour runs, walking the line's *display*
/// cells (`zoe/display.zig`) rather than its bytes: a tab covers the
/// columns out to its stop, and with `:set whitespace=on` a space is
/// a dot and a tab an arrow, both in the whitespace colour but a run
/// of their own. `spans` empty is a legitimate call
/// -- it paints the whole row in `fg_text`, which is the no-grammar
/// path.
pub fn rowSpansImpl(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    r: usize,
    rv: RowView,
    text: []const u8,
    spans: []const syntax.Span,
) !void {
    if (self.textCols() == 0) return;
    // The row's own columns; the host pads the rest of the pane.
    const cols = rv.cols;
    const left = rv.left;
    // Text starts after the line-number gutter (zero when it is off).
    const gutter = self.gutterWidth();

    // The row's visible text, and where each colour starts in it. A
    // contiguous stretch of cells goes out as one `write_text` with a
    // span per colour, padded by the host to the pane's edge; only a
    // gap in the display cells (which `display.Cells` doesn't produce
    // in practice) splits it into two writes.
    var row_buf: std.ArrayList(u8) = .empty;
    defer row_buf.deinit(self.alloc);
    var ranges: std.ArrayList(RowRange) = .empty;
    defer ranges.deinit(self.alloc);
    var group_dc = left;
    var run_color: ?Color = null;
    var have_run = false;
    // The next column still to be filled, and so also where the run
    // being built ends -- which is how a gap is spotted.
    var dc = left;

    var it = display.Cells{ .text = text, .opts = self.displayOpts() };
    while (it.next()) |cell| {
        // `@max(width, 1)` keeps a zero-width combining mark sitting
        // exactly on the left edge rather than dropping it.
        if (cell.col + @max(cell.width, 1) <= left) continue;
        if (cell.col >= left + cols) break;

        const lo = @max(cell.col, left);
        const hi = @min(cell.col + cell.width, left + cols);
        // A character straddling either edge of the viewport is
        // painted blank rather than half-drawn -- including a tab the
        // horizontal scroll opened in the middle of, whose arrow is
        // off to the left.
        const clipped = cell.col < left or cell.col + cell.width > left + cols;
        // Nothing visible of its own: a clipped glyph, or a tab with
        // markers off. Colour is irrelevant to a run of blanks, and
        // saying so keeps it from splitting a run in two.
        const blanks = clipped or cell.glyph_cols == 0;

        const color: ?Color = if (blanks)
            null
        else if (cell.marker)
            role(.whitespace)
        else
            spanColorAt(spans, cell.src);

        if (!have_run or lo != dc) {
            if (have_run) try self.flushRowGroup(batch, r, left, group_dc, row_buf.items, ranges.items, false);
            row_buf.clearRetainingCapacity();
            ranges.clearRetainingCapacity();
            try ranges.append(self.alloc, .{ .start = 0, .color = color });
            run_color = color;
            group_dc = lo;
            have_run = true;
            dc = lo;
        } else if (!colorOptEql(color, run_color)) {
            try ranges.append(self.alloc, .{ .start = row_buf.items.len, .color = color });
            run_color = color;
        }

        if (blanks) {
            if (hi > dc) try row_buf.appendNTimes(self.alloc, ' ', hi - dc);
            dc = hi;
        } else {
            try row_buf.appendSlice(self.alloc, cell.bytes);
            // The columns past the glyph -- a tab's run after its
            // arrow. Unwritten cells would be transparent, not blank.
            try row_buf.appendNTimes(self.alloc, ' ', cell.width - cell.glyph_cols);
            dc += cell.width;
        }
    }

    if (have_run) {
        // The last stretch carries the pad for the rest of the row.
        try self.flushRowGroup(batch, r, left, group_dc, row_buf.items, ranges.items, true);
    } else {
        // An empty line, or one scrolled entirely off to the left.
        try self.writeSpaces(batch, r, gutter, self.textCols());
    }
}

/// Where one colour starts within a row's text; it runs to the next
/// range's start.
pub const RowRange = struct { start: usize, color: ?Color };

/// Writes one contiguous stretch of a buffer row whose first column is
/// display column `left`, starting at display column `start_dc`, as a
/// single `write_text` with one span per colour range. `pad_row` has
/// the host fill the rest of the pane's row in the buffer colour.
pub fn flushRowGroup(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    r: usize,
    left: usize,
    start_dc: usize,
    bytes: []const u8,
    ranges: []const RowRange,
    pad_row: bool,
) !void {
    if (start_dc < left) return;
    const row_spans = try self.alloc.alloc(glyphwire.client.Client.Span, ranges.len);
    defer self.alloc.free(row_spans);
    for (ranges, row_spans, 0..) |rg, *sp, i| {
        const stop = if (i + 1 < ranges.len) ranges[i + 1].start else bytes.len;
        sp.* = .{ .text = bytes[rg.start..stop], .fg = rg.color orelse role(.fg) };
    }
    try batch.writeSpans(row_spans, .{
        .layer = self.grp.buffer_layer,
        .row = r,
        .col = self.gutterWidth() + start_dc - left,
        .bg = role(.bg),
        .max_cols = if (pad_row) left + self.textCols() - start_dc else null,
        .pad = pad_row,
    });
}

/// Blanks `n` cells of buffer row `r` to the pane colour -- a fill,
/// not a run of spaces.
pub fn writeSpaces(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize, col: usize, n: usize) !void {
    if (n == 0) return;
    try batch.clearArea(.{ .layer = self.grp.buffer_layer, .row = r, .col = col, .rows = 1, .cols = n, .bg = role(.bg) });
}

/// The active buffer's lines as `layoutRowMap` reads them.
pub const BufLines = struct {
    buf: *const buffer_mod.Buffer,
    pub fn count(self: BufLines) usize {
        return self.buf.lineCount();
    }
    pub fn text(self: BufLines, alloc: std.mem.Allocator, line: usize) ![]u8 {
        return self.buf.lineText(alloc, line);
    }
};

/// Rebuilds `row_map` for `grp`/`buf` as they stand -- their scroll
/// position, pane size and `wrap` setting.
pub fn layoutRows(self: *Ui) !void {
    try layoutRowMap(
        self.alloc,
        &self.row_map,
        BufLines{ .buf = &self.buf.ed.buf },
        self.buf.top_line,
        self.buf.top_sub,
        self.buf.left_col,
        self.grp.buffer_bounds.rows,
        self.textCols(),
        self.buf.ed.wrap,
        self.displayOpts(),
        self.buf.ed.hiddenLines(),
    );
}

/// A screen row of a wrapped buffer: row `sub` of buffer `line`.
pub const RowPos = struct { line: usize, sub: usize };

/// Screen rows buffer `line` takes: none inside a closed fold, one
/// unwrapped, and however many it wraps into at the pane's text width.
/// A line past the end (or one that can't be read) counts as one.
pub fn lineRows(self: *Ui, line: usize) usize {
    if (line >= self.buf.ed.buf.lineCount()) return 1;
    if (fold.isHidden(self.buf.ed.hiddenLines(), line)) return 0;
    if (!self.buf.ed.wrap) return 1;
    const text = self.buf.ed.buf.lineText(self.alloc, line) catch return 1;
    defer self.alloc.free(text);
    return softwrap.rowCount(text, self.displayOpts(), self.textCols());
}

/// The wrapped screen row the caret sits on.
pub fn cursorRowPos(self: *Ui) RowPos {
    const line = self.buf.ed.pos().line;
    if (!self.buf.ed.wrap) return .{ .line = line, .sub = 0 };
    const text = self.buf.ed.buf.lineText(self.alloc, line) catch return .{ .line = line, .sub = 0 };
    defer self.alloc.free(text);
    const col = self.cursorDisplayCol() catch return .{ .line = line, .sub = 0 };
    return .{ .line = line, .sub = softwrap.rowOfCol(text, self.displayOpts(), self.textCols(), col).index };
}

/// Screen rows from `from` down to `to` (`from` at or above it),
/// counting stopped at `cap` -- callers only care whether it fits.
pub fn rowsBetween(self: *Ui, from: RowPos, to: RowPos, cap: usize) usize {
    if (from.line == to.line) return @min(to.sub -| from.sub, cap);
    var n = self.lineRows(from.line) -| from.sub;
    var line = from.line + 1;
    const hidden = self.buf.ed.hiddenLines();
    while (line < to.line and n < cap) : (line += 1) {
        // A closed fold's lines are no rows; step over the whole run.
        if (fold.rangeOf(hidden, line)) |r| {
            line = r.last;
            continue;
        }
        n += self.lineRows(line);
    }
    return @min(n + to.sub, cap);
}

/// The screen row `n` rows above `at`, stopping at the buffer's top.
/// Lines inside a closed fold take no rows and are stepped over.
pub fn rowsBack(self: *Ui, at: RowPos, n: usize) RowPos {
    var pos = at;
    var left = n;
    while (left > 0) {
        if (pos.sub >= left) {
            pos.sub -= left;
            break;
        }
        left -= pos.sub + 1;
        while (true) {
            if (pos.line == 0) return .{ .line = 0, .sub = 0 };
            pos.line -= 1;
            const rows = self.lineRows(pos.line);
            if (rows > 0) {
                pos.sub = rows - 1;
                break;
            }
        }
    }
    return pos;
}

pub fn rowPosBefore(a: RowPos, b: RowPos) bool {
    return a.line < b.line or (a.line == b.line and a.sub < b.sub);
}

/// Keeps the caret inside the buffer pane, both axes.
pub fn scrollBufferToCursor(self: *Ui) void {
    const b = self.grp.buffer_bounds;
    if (b.rows == 0 or b.cols == 0) return;
    if (self.buf.ed.wrap) return self.scrollWrappedToCursor();
    self.buf.top_sub = 0;
    if (self.buf.ed.hasClosedFolds()) {
        // A closed fold is one row however many lines it holds, so the
        // view is measured in rows, the way the wrapped one is.
        self.scrollRowsToCursor();
    } else {
        const pos = self.buf.ed.pos();
        if (pos.line < self.buf.top_line) self.buf.top_line = pos.line;
        if (pos.line >= self.buf.top_line + b.rows) self.buf.top_line = pos.line - b.rows + 1;
    }

    const col = self.cursorDisplayCol() catch return;
    const cols = self.textCols();
    if (col < self.buf.left_col) self.buf.left_col = col;
    if (cols > 0 and col >= self.buf.left_col + cols) self.buf.left_col = col - cols + 1;
}

/// `scrollBufferToCursor` with `wrap` on: there is nothing to scroll
/// sideways, and the view moves in screen rows, so a long line can sit
/// part-way off the top of the pane.
pub fn scrollWrappedToCursor(self: *Ui) void {
    self.buf.left_col = 0;
    self.scrollRowsToCursor();
}

/// The vertical half of keeping the caret in view, counted in screen
/// rows rather than lines: what wrapping and closed folds both need.
pub fn scrollRowsToCursor(self: *Ui) void {
    const rows = self.grp.buffer_bounds.rows;
    // An edit or a narrower pane can leave the top row past its
    // line's last one, and a fold closing can hide the top line.
    if (self.buf.top_line >= self.buf.ed.buf.lineCount()) {
        self.buf.top_line = self.buf.ed.buf.lineCount() - 1;
        self.buf.top_sub = 0;
    }
    const shown = fold.visibleAtOrAbove(self.buf.ed.hiddenLines(), self.buf.top_line);
    if (shown != self.buf.top_line) {
        self.buf.top_line = shown;
        self.buf.top_sub = 0;
    }
    self.buf.top_sub = @min(self.buf.top_sub, self.lineRows(self.buf.top_line) - 1);

    const at = self.cursorRowPos();
    const top: RowPos = .{ .line = self.buf.top_line, .sub = self.buf.top_sub };
    var new_top = top;
    if (rowPosBefore(at, top)) {
        new_top = at;
    } else if (self.rowsBetween(top, at, rows) >= rows) {
        new_top = self.rowsBack(at, rows - 1);
    }
    self.buf.top_line = new_top.line;
    self.buf.top_sub = new_top.sub;
}

/// Signed screen rows the wrapped view moved since the layer was last
/// drawn (positive: scrolled down), or null for a screen or more --
/// too far for a `move_content` to be worth it. Measured over the
/// current text, which is only right when nothing was edited since;
/// an edit takes the full-repaint path before this is asked.
pub fn wrappedScrollDelta(self: *Ui, rows: usize) ?i64 {
    const prev: RowPos = .{ .line = self.buf.prev_top_line, .sub = self.buf.prev_top_sub };
    const now: RowPos = .{ .line = self.buf.top_line, .sub = self.buf.top_sub };
    if (prev.line >= self.buf.ed.buf.lineCount()) return null;
    const down = rowPosBefore(prev, now);
    const n = if (down) self.rowsBetween(prev, now, rows) else self.rowsBetween(now, prev, rows);
    if (n >= rows) return null;
    return if (down) @intCast(n) else -@as(i64, @intCast(n));
}

/// Applies a host-driven scroll of group `g`'s buffer pane (wheel or
/// thumb drag): moves the view and drags the cursor back onto it,
/// keeping its column. Records the new position as already pushed so
/// the next `syncBufferScrollbar` doesn't bounce it back to the host.
/// Any group, not only the focused one -- the wheel follows the
/// pointer, not the keyboard.
pub fn scrollGroupTo(self: *Ui, g: *Group, row: usize, col: usize) void {
    const b = g.buffer_bounds;
    if (b.rows == 0) return;
    const slot = g.slot();
    // A row inside a closed fold isn't on screen. Scrolling down past
    // one lands below it rather than back on its first line, or the
    // wheel could never get past a fold longer than one notch.
    const hidden = slot.ed.hiddenLines();
    slot.top_line = if (fold.rangeOf(hidden, row)) |r|
        (if (row > slot.top_line and r.last + 1 < slot.ed.buf.lineCount()) r.last + 1 else r.first - 1)
    else
        row;
    // The host scrolls in buffer lines (the bar's extent is the line
    // count), so a wrapped view lands on a line's first row.
    slot.top_sub = 0;
    slot.left_col = if (slot.ed.wrap) 0 else col;

    const cur = slot.ed.pos();
    const last = slot.ed.buf.lineCount() -| 1;
    // From `top_line`, not `row`: the row asked for may have been a
    // hidden one, and a cursor dragged into a closed fold would open it.
    const clamped_line = std.math.clamp(cur.line, slot.top_line, @min(self.lastWholeLine(g), last));
    if (clamped_line != cur.line) {
        slot.ed.cursor = slot.ed.buf.offsetOf(.{ .line = clamped_line, .col = cur.col });
    }
    // What the host's bar holds now is `row`, not `top_line`. When a
    // closed fold moved the view off `row`, the difference makes
    // `syncBufferScrollbar` push `top_line` back, so the next wheel
    // step starts from the line on screen rather than from inside the
    // fold -- otherwise the wheel walks the hidden lines a notch at a
    // time while the view sits still.
    slot.pushed_bar = .{ slot.ed.buf.lineCount(), b.cols, row, slot.left_col };
    // The view moved and the cursor may have been dragged with it;
    // the status row shows both.
    g.buffer_dirty = true;
    self.status_dirty = true;
}

/// The last buffer line group `g`'s pane shows in full from its
/// current scroll position -- `top_line + rows - 1` unwrapped. Wrapped,
/// a line whose rows run off the bottom doesn't count, or a cursor
/// clamped onto it would scroll the view straight back. Never above
/// `top_line`, even when that one line is taller than the pane.
pub fn lastWholeLine(self: *Ui, g: *Group) usize {
    const slot = g.slot();
    if (!slot.ed.wrap and !slot.ed.hasClosedFolds()) return slot.top_line + g.buffer_bounds.rows -| 1;
    const focused_grp = self.grp;
    const focused_buf = self.buf;
    self.grp = g;
    self.buf = slot;
    defer {
        self.grp = focused_grp;
        self.buf = focused_buf;
    }
    self.layoutRows() catch return slot.top_line;
    var last = slot.top_line;
    for (self.row_map.items) |rv| {
        if (rv.last and rv.line > last) last = rv.line;
    }
    return last;
}

/// Keeps the buffer layer's host-drawn scrollbar in step with zoe's
/// own scroll state: the content extent is the line count (the width
/// is just the pane's, so no horizontal bar), and the offset is
/// `top_line`/`left_col`. Only sent when something changed, so a
/// still buffer is silent. A wheel or thumb drag over the pane comes
/// back the other way as a `scroll_offset` notification (see
/// `handleEvent`). Batched with the frame, so the bar never moves
/// ahead of the rows it describes.
pub fn syncBufferScrollbar(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const b = self.grp.buffer_bounds;
    const now: [4]usize = .{ self.buf.ed.buf.lineCount(), b.cols, self.buf.top_line, self.buf.left_col };
    if (std.mem.eql(usize, &now, &self.buf.pushed_bar)) return;

    if (now[0] != self.buf.pushed_bar[0] or now[1] != self.buf.pushed_bar[1]) {
        try batch.setLayerContentExtent(self.grp.buffer_layer, now[1], now[0]);
    }
    try batch.setLayerScrollOffset(self.grp.buffer_layer, self.buf.top_line, self.buf.left_col);
    self.buf.pushed_bar = now;
}

/// How the buffer pane lays a line out, from the active buffer's own
/// settings. One accessor so every column calculation in this file --
/// painting, the caret, the selection, a mouse click -- agrees.
pub fn displayOpts(self: *const Ui) display.Opts {
    return .{
        .tab_width = self.buf.ed.tab_width,
        .show_whitespace = self.buf.ed.show_whitespace,
    };
}

/// The caret's column in *display* cells, which is not its byte
/// column once a line holds anything multi-byte, double-width, or a
/// tab.
pub fn cursorDisplayCol(self: *Ui) !usize {
    const pos = self.buf.ed.pos();
    const start = self.buf.ed.buf.lineStart(pos.line);
    const text = try self.buf.ed.buf.gap.read(self.alloc, start, start + pos.col);
    defer self.alloc.free(text);
    return display.width(text, self.displayOpts());
}

/// The grapheme the caret sits on, or a space at end of line. A tab
/// reads as a space: the caret is one inverted cell and sits on the
/// first of the several the tab covers, the way vim draws it.
pub fn cursorGrapheme(self: *Ui) ![]u8 {
    const c = self.buf.ed.cursor;
    if (c >= self.buf.ed.buf.len() or self.buf.ed.buf.byteAt(c) == '\n' or
        self.buf.ed.buf.byteAt(c) == '\t')
    {
        return self.alloc.dupe(u8, " ");
    }
    const seq = std.unicode.utf8ByteSequenceLength(self.buf.ed.buf.byteAt(c)) catch 1;
    return self.buf.ed.buf.gap.read(self.alloc, c, c + seq);
}

pub fn renderTree(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const b = self.tree_bounds;
    if (b.cols == 0 or b.rows == 0) return;

    // The whole listing is written, not just the visible slice: the
    // content grid *is* the tree, and the host scrolls a viewport over
    // it. This runs on an expand or collapse, never on a scroll.
    const content_cols = self.treeContentCols();
    const content_rows = self.treeContentRows();

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(self.alloc);

    // The name field stands in for the highlight while it is up: it is
    // where the keyboard is.
    const editing = self.tree_edit != null;
    var r: usize = 0;
    while (r < content_rows) : (r += 1) {
        if (self.tree_edit) |te| {
            if (r == te.row) {
                try self.renderTreeEditRow(batch, content_cols);
                continue;
            }
        }
        const entry = self.treeRowEntry(r);
        const bg = if (!editing and r == self.tree.cursor) treeCursorBg(self.focus == .tree) else role(.sidebar_bg);

        line.clearRetainingCapacity();
        if (entry) |e| {
            try line.appendNTimes(self.alloc, ' ', e.depth * tree_mod.indent_cols + tree_mod.icon_cols);
            try line.appendSlice(self.alloc, e.name);
            // The host pads the row to the full content width.
            try batch.writeText(line.items, .{
                .layer = self.tree_layer,
                .row = r,
                .col = 0,
                // A row that is only here because Ctrl+H is on is
                // drawn dim, so "show hidden" reads as a listing with
                // extra, lesser entries rather than as a listing that
                // mysteriously doubled in length.
                // A workspace folder's header stands out from the
                // directories under it, the way VS Code's does.
                .fg = if (e.is_root)
                    role(.fg_strong)
                else if (e.hidden)
                    (if (e.is_dir) role(.hidden_dir) else role(.hidden))
                else
                    (if (e.is_dir) role(.dir) else role(.fg)),
                .bg = bg,
                .max_cols = content_cols,
                .pad = true,
            });

            // The icon composites *over* the row's background rather
            // than replacing it, so a selected row stays highlighted
            // underneath it. Sized exactly like `glyphwire-ls`'s
            // small-table icons: natural, capped in *height* to one
            // row and free to overflow its column in width (a plain
            // `"fit"` shrinks a 32px source to the ~8px a cell is wide
            // and is unreadable). Only `max_h` -- adding `max_w` would
            // shrink it back to the narrow cell width. Falls back to
            // `.fit` if the cell metrics somehow didn't load.
            const natural = self.cell_px_h > 0;
            try batch.drawIconOnStyled(self.tree_layer, r, e.depth * tree_mod.indent_cols, iconFor(e), .{
                .scale = if (natural) .natural else .fit,
                .h_align = .start,
                .v_align = .center,
                .max_h = if (natural) self.cell_px_h else null,
                .foreground = true,
            });
        } else {
            try batch.clearArea(.{ .layer = self.tree_layer, .row = r, .rows = 1, .cols = content_cols, .bg = role(.sidebar_bg) });
        }
    }

    self.tree_painted = .{ .row = self.tree.cursor, .focused = self.focus == .tree, .shown = !editing };
}

/// The tree cursor's row: the selection colour while the tree has the
/// keyboard, and the dim unfocused-list cursor while it doesn't, so the
/// entry `revealInTree` (or the last visit) left it on still reads as
/// the selected one from the editor.
fn treeCursorBg(focused: bool) Color {
    return if (focused) role(.selection_bg) else role(.list_cursor_inactive_bg);
}

/// The name field's row: the icon the entry has (or will have), the
/// typed name and the caret, on the highlight. The cheap repaint for a
/// keystroke in the field -- the rest of the listing hasn't moved.
pub fn renderTreeEditRow(self: *Ui, batch: *glyphwire.client.Client.Batch, content_cols: usize) !void {
    const te = &(self.tree_edit orelse return);
    const text = te.field.text();
    const indent = te.depth * tree_mod.indent_cols;
    const start = indent + tree_mod.icon_cols;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(self.alloc);
    try line.appendNTimes(self.alloc, ' ', start);
    try line.appendSlice(self.alloc, text);
    try batch.writeText(line.items, .{
        .layer = self.tree_layer,
        .row = te.row,
        .col = 0,
        .fg = role(.fg),
        .bg = role(.selection_bg),
        .max_cols = content_cols,
        .pad = true,
    });

    // The caret, inverted the way the `:` line draws its own.
    const caret_col = start + te.field.caretCol();
    if (caret_col < content_cols) {
        const under = if (te.field.caret < text.len)
            text[te.field.caret..lineedit.nextBoundary(text, te.field.caret)]
        else
            " ";
        try batch.writeText(under, .{
            .layer = self.tree_layer,
            .row = te.row,
            .col = caret_col,
            .fg = role(.selection_bg),
            .bg = role(.fg),
        });
    }

    // A rename keeps the entry's icon; a create shows what the typed
    // name will make, so a trailing `/` turns it into a folder.
    const icon: []const u8 = switch (te.kind) {
        .rename => if (self.tree.at(te.row)) |e| iconFor(e) else "file/folder",
        .create_dir => "file/folder",
        .create => if (std.mem.endsWith(u8, text, "/"))
            "file/folder"
        else
            ls_icons.iconForFileName(text) orelse ls_icons.iconForExtension(text),
    };
    const natural = self.cell_px_h > 0;
    try batch.drawIconOnStyled(self.tree_layer, te.row, indent, icon, .{
        .scale = if (natural) .natural else .fit,
        .h_align = .start,
        .v_align = .center,
        .max_h = if (natural) self.cell_px_h else null,
        .foreground = true,
    });
}

/// The cheap half of the tree repaint: the highlight moved, and
/// nothing else did.
///
/// The listing is already on the layer in full -- `renderTree` writes
/// every row, not just the visible ones -- so moving the cursor is
/// two `set_bg`s: the row that was highlighted back to the pane
/// colour, the row that now is to the selection colour. `set_bg`
/// repaints backgrounds only, so the names and the per-entry icons
/// (drawn `foreground: true`) survive untouched, which is the whole
/// reason it exists -- see docs/api.md.
pub fn renderTreeSelection(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    if (self.tree_bounds.cols == 0 or self.tree_bounds.rows == 0) return;
    // The field's start and end repaint in full; there is no
    // highlight to move while it is up.
    if (self.tree_edit != null) return;
    const focused = self.focus == .tree;
    const cols = self.treeContentCols();
    const was = self.tree_painted;
    if (was.shown and was.focused == focused and was.row == self.tree.cursor) return;

    if (was.shown and was.row != self.tree.cursor) {
        try batch.setBg(.{ .layer = self.tree_layer, .row = was.row, .rows = 1, .cols = cols, .bg = role(.sidebar_bg) });
    }
    try batch.setBg(.{ .layer = self.tree_layer, .row = self.tree.cursor, .rows = 1, .cols = cols, .bg = treeCursorBg(focused) });
    self.tree_painted = .{ .row = self.tree.cursor, .focused = focused, .shown = true };
}

pub fn iconFor(e: tree_mod.Entry) []const u8 {
    if (e.is_dir) {
        return ls_icons.iconForDirName(e.name) orelse
            (if (e.expanded) "file/folder-open" else "file/folder");
    }
    return ls_icons.iconForFileName(e.name) orelse ls_icons.iconForExtension(e.name);
}

/// Redraws the tab strip.
///
/// The strip is laid out in *strip* columns (`zoe/tabs.zig`), scrolled
/// so the active tab is fully on screen, then written one run per tab
/// -- clipped to the pane, since a tab at either edge may be half off
/// it. The row is painted with the bar's background first, so a tab
/// that just closed leaves no cells of its own behind.
pub fn renderTabs(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const b = self.grp.tabs_bounds;
    if (b.cols == 0 or b.rows == 0) return;

    var labels: std.ArrayList(tabs.Tab) = .empty;
    defer labels.deinit(self.alloc);
    for (self.grp.buffers.items) |slot| {
        try labels.append(self.alloc, .{
            .label = tabs.labelFor(slot.ed.path),
            .dirty = slot.ed.buf.dirty,
            .gone = slot.gone,
        });
    }

    const g = self.grp;
    g.tab_total = try tabs.layout(self.alloc, labels.items, &g.tab_spans);
    g.tab_win = tabstrip.window(g.tab_total, b.cols);
    // The shown tab is scrolled into view when it, or the strip, has
    // changed; otherwise the strip keeps the scroll an arrow or the
    // wheel gave it.
    const follow = g.tab_follow.changed(g.active, g.tab_spans.items.len, g.tab_total, b.cols);
    if (follow and g.active < g.tab_spans.items.len) {
        const span = g.tab_spans.items[g.active];
        g.tab_scroll = tabstrip.scrollToShow(span.start, span.end, g.tab_win, g.tab_scroll, g.tab_total);
    } else {
        g.tab_scroll = g.tab_win.clamp(g.tab_scroll, g.tab_total);
    }
    try self.syncTabScrollbar(batch);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.alloc);

    try batch.clearArea(.{ .layer = self.grp.tabs_layer, .row = 0, .rows = 1, .bg = role(.tab_bar_bg) });

    for (self.grp.tab_spans.items, labels.items, 0..) |span, tab, i| {
        const active = i == self.grp.active;
        const bg = if (active) role(.bg) else role(.tab_bg);
        // The deleted mark is a run of its own, in the error colour.
        var col = span.start;
        if (tab.gone) {
            text.clearRetainingCapacity();
            try text.append(self.alloc, ' ');
            try text.appendSlice(self.alloc, tabs.gone_mark);
            try self.writeStripRun(batch, col, text.items, self.diagColor(.err), bg);
            col += glyphwire.stringWidth(text.items);
        }
        text.clearRetainingCapacity();
        try text.append(self.alloc, ' ');
        try text.appendSlice(self.alloc, tab.label);
        if (tab.dirty) {
            try text.append(self.alloc, ' ');
            try text.appendSlice(self.alloc, tabs.dirty_mark);
        }
        try text.append(self.alloc, ' ');
        try text.appendSlice(self.alloc, tabs.close_glyph);
        try text.append(self.alloc, ' ');

        // A group's shown tab joins its pane (`bg_buffer`); only the
        // focused group's is lit, so with several groups up the strip
        // says which one the keyboard is in.
        try self.writeStripRun(
            batch,
            col,
            text.items,
            if (active and self.render_focused) role(.fg) else role(.fg_dim),
            bg,
        );
        if (i + 1 < self.grp.tab_spans.items.len) {
            try self.writeStripRun(batch, span.end, tabs.separator, role(.fg_dim), role(.tab_bar_bg));
        }
    }
    try tabstrip.drawArrows(batch, g.tabs_layer, 0, g.tab_win, g.tab_scroll, g.tab_total, .{
        .fg = role(.fg),
        .fg_dim = role(.fg_dim),
        .bg = role(.tab_bar_bg),
    });
}

/// Writes one run of the tab strip, positioned in strip columns and
/// clipped to the visible window. A run entirely off the pane writes
/// nothing; one straddling an edge is sliced at a display column, so
/// a double-width character is never cut in half.
pub fn writeStripRun(
    self: *Ui,
    batch: *glyphwire.client.Client.Batch,
    start: usize,
    text: []const u8,
    fg: Color,
    bg: Color,
) !void {
    const width = glyphwire.stringWidth(text);
    const win = self.grp.tab_win;
    const view_lo = self.grp.tab_scroll;
    const view_hi = self.grp.tab_scroll + win.cols;
    const lo = @max(start, view_lo);
    const hi = @min(start + width, view_hi);
    if (lo >= hi) return;

    // Tab labels hold no tabs and take no space markers, so the
    // default `Opts` is the plain codepoint-width walk this wants.
    const from = display.byteAtCol(text, lo - start, .{});
    const to = display.byteAtCol(text, hi - start, .{});
    try writeAt(batch, self.grp.tabs_layer, 0, win.left + lo - view_lo, text[from..to], fg, bg);
}

/// Keeps the tabs layer's virtual extent and offset in step with the
/// strip, the same arrangement the buffer pane has: the layer's grid
/// is only pane-wide, and reporting the strip's real width is what
/// lets the host turn a shift+wheel or a drag over it into the
/// `scroll_offset` `handleEvent` follows. Silent when nothing moved.
pub fn syncTabScrollbar(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const now: [2]usize = .{ self.grp.tab_win.extent(self.grp.tab_total), self.grp.tab_scroll };
    if (std.mem.eql(usize, &now, &self.grp.pushed_tab_bar)) return;

    if (now[0] != self.grp.pushed_tab_bar[0]) {
        try batch.setLayerContentExtent(self.grp.tabs_layer, now[0], 1);
    }
    try batch.setLayerScrollOffset(self.grp.tabs_layer, 0, self.grp.tab_scroll);
    self.grp.pushed_tab_bar = now;
}

/// The diagnostic the statusline should show, if any: whatever covers the
/// cursor, else the worst on its line (see `diag.Store.atCursor` for why
/// the fallback is there).
pub fn cursorDiagnostic(self: *Ui) ?diag.Entry {
    if (self.lsp_pool == null) return null;
    const abs = self.slotAbs(self.buf) orelse return null;
    const pos = self.buf.ed.pos();
    return self.diags.atCursor(abs, @intCast(pos.line), @intCast(pos.col));
}

pub fn renderStatus(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
    const b = self.status_bounds;
    if (b.cols == 0) return;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(self.alloc);
    var fg = role(.status_fg);

    // A tree search takes the row ahead of everything else: it is the
    // only thing on screen that says what was typed, since the prefix
    // itself is never drawn in the pane. The `/` prompt keeps the key
    // that started it, so the scope the search is running in stays
    // readable while it runs.
    // The sidebar's name field says what Enter will do, or why the
    // last one didn't.
    if (self.tree_edit) |te| {
        if (te.err) |msg| {
            fg = role(.message_error);
            try line.print(self.alloc, " {s}", .{msg});
        } else {
            var home_buf: [std.fs.max_path_bytes]u8 = undefined;
            const where = homepath.collapseHome(te.dir, self.environ.get("HOME"), &home_buf);
            switch (te.kind) {
                .create => try line.print(self.alloc, " New file in {s}  (end with / for a folder; Enter creates, Esc cancels)", .{where}),
                .create_dir => try line.print(self.alloc, " New folder in {s}  (Enter creates, Esc cancels)", .{where}),
                .rename => try line.print(self.alloc, " Rename {s}  (Enter renames, Esc cancels)", .{te.old_name}),
            }
        }
    } else if (self.find) |f| {
        const prompt: []const u8 = if (f.scope == .deep) "/" else "find: ";
        const n = f.hits.items.len;
        if (n == 0) {
            if (f.query.items.len > 0) fg = role(.message_error);
            try line.print(self.alloc, " {s}{s}  (no match)", .{ prompt, f.query.items });
        } else {
            try line.print(self.alloc, " {s}{s}  [{d}/{d}]", .{ prompt, f.query.items, f.pick + 1, n });
        }
        if (f.deep) |d| {
            if (d.truncated) try line.appendSlice(self.alloc, "  (partial)");
        }
    } else if (self.buf.ed.mode == .command) {
        try line.append(self.alloc, ':');
        try line.appendSlice(self.alloc, self.buf.ed.cmdline.text());
    } else if (self.buf.ed.mode == .search) {
        // `/foo` or `?foo`, in the error colour once the pattern
        // stops matching -- the same signal the tree's `/` gives.
        if (self.buf.ed.search_failed) fg = role(.message_error);
        try line.append(self.alloc, self.buf.ed.searchPrompt());
        try line.appendSlice(self.alloc, self.buf.ed.cmdline.text());
    } else if (self.buf.ed.status.items.len > 0) {
        if (std.mem.startsWith(u8, self.buf.ed.status.items, "E")) fg = role(.message_error);
        try line.appendSlice(self.alloc, self.buf.ed.status.items);
    } else {
        const pos = self.buf.ed.pos();
        try line.print(self.alloc, " {s}  {s}{s}", .{
            modeName(self.buf.ed.mode),
            self.buf.ed.path orelse "[No Name]",
            if (self.buf.ed.buf.dirty) " [+]" else "",
        });
        // Which tab this is, once there is more than one. The strip
        // above shows the names; this is the count.
        if (self.grp.buffers.items.len > 1) {
            try line.print(self.alloc, "  [{d}/{d}]", .{ self.grp.active + 1, self.grp.buffers.items.len });
        }
        // The diagnostic under the cursor, with the tool that reported
        // it -- which matters, because two servers publish for the same
        // Python file and "unused import" and "is not defined" come from
        // different places. Truncated by the write's `max_cols`; the
        // position on the right is the thing worth keeping whole.
        if (self.cursorDiagnostic()) |d| {
            try line.print(self.alloc, "  {s}: {s}", .{ d.source, d.message });
        }
        // The position is right-aligned, so the mode and filename on
        // the left don't shift it around as they change length.
        var right: [48]u8 = undefined;
        const tail = std.fmt.bufPrint(&right, "{d}:{d} ", .{ pos.line + 1, pos.col + 1 }) catch "";
        const used = glyphwire.stringWidth(line.items) + glyphwire.stringWidth(tail);
        if (used < b.cols) try line.appendNTimes(self.alloc, ' ', b.cols - used);
        try line.appendSlice(self.alloc, tail);
    }

    // The mode word (right after the leading space, in the normal
    // status form) gets its own colour as a span of the same write.
    const mode_word = modeName(self.buf.ed.mode);
    // Only the plain status form starts with the mode word; the tree's
    // search and name field take the row with text of their own.
    const show_mode = self.buf.ed.mode != .command and self.buf.ed.mode != .search and
        self.buf.ed.status.items.len == 0 and self.find == null and self.tree_edit == null;
    const opts: glyphwire.client.Client.TextOpts = .{
        .layer = self.status_layer,
        .row = 0,
        .col = 0,
        .fg = fg,
        .bg = role(.status_bg),
        .max_cols = b.cols,
        .pad = true,
    };
    if (show_mode) {
        const mode_end = 1 + mode_word.len;
        try batch.writeSpans(&.{
            .{ .text = line.items[0..1] },
            .{ .text = line.items[1..mode_end], .fg = role(.mode) },
            .{ .text = line.items[mode_end..] },
        }, opts);
    } else {
        try batch.writeText(line.items, opts);
    }

    // The `:` and `/` lines' caret, as the same inverted block the
    // buffer pane draws. Only needed now that the command line is a
    // real field: while it was append-only the caret was always at
    // the end, and the statusline's own trailing blank read as one.
    if (self.buf.ed.mode == .command or self.buf.ed.mode == .search) {
        const cmd = &self.buf.ed.cmdline;
        const col = 1 + cmd.caretCol(); // past the leading `:` or `/`
        if (col < b.cols) {
            const under = if (cmd.caret < cmd.text().len)
                cmd.text()[cmd.caret..lineedit.nextBoundary(cmd.text(), cmd.caret)]
            else
                " ";
            try batch.writeText(under, .{
                .layer = self.status_layer,
                .row = 0,
                .col = col,
                .fg = role(.status_bg),
                .bg = fg,
            });
        }
    }
}

pub fn modeName(mode: editor.Mode) []const u8 {
    return switch (mode) {
        .normal => "NORMAL",
        .insert => "INSERT",
        .command => "COMMAND",
        .visual => "VISUAL",
        .visual_line => "V-LINE",
        .search => "SEARCH",
        .select => "SELECT",
        .find => "FIND",
    };
}

/// The scroll/edit state `planBufferRender` decides from.
/// What one screen row of the buffer pane shows: a window of display
/// columns onto one buffer line. Unwrapped every row is a whole line
/// seen from `left_col`; with `wrap` on a long line spans several rows,
/// each one a `wrap.Row` of it. The painters only ever see this, so the
/// same row code draws both.
pub const RowView = struct {
    /// The buffer line. At or past the line count means the row is below
    /// the end of the buffer (vim's `~`).
    line: usize,
    /// Which of the line's rows this is; only row 0 is numbered.
    sub: usize,
    /// The first display column of the line the row shows.
    left: usize,
    /// How many of the line's display columns the row shows. The pane is
    /// still `textCols` wide; a wrapped row that breaks early leaves the
    /// rest blank.
    cols: usize,
    /// The line's last row -- where a selection reaching the newline, or
    /// the insert-mode caret after the last character, is drawn.
    last: bool,

    pub fn pastEnd(self: RowView, line_count: usize) bool {
        return self.line >= line_count;
    }
};

/// Fills `out` with the `rows` screen rows of a pane whose first row is
/// row `top_sub` of buffer line `top_line`. `lines` hands back a line's
/// text (without its newline) and how many lines there are; it is a
/// parameter so `tests/zoe_tests.zig` can drive this without a buffer.
/// `width` is the text width; `wrap_on` false gives one row per line,
/// seen from `left`.
pub fn layoutRowMap(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(RowView),
    lines: anytype,
    top_line: usize,
    top_sub: usize,
    left: usize,
    rows: usize,
    width: usize,
    wrap_on: bool,
    opts: display.Opts,
    hidden: []const fold.Range,
) !void {
    out.clearRetainingCapacity();
    const count = lines.count();
    if (!wrap_on) {
        var line = top_line;
        while (out.items.len < rows) : (line += 1) {
            // A closed fold's lines take no rows: skip to the line after.
            if (fold.rangeOf(hidden, line)) |r| line = r.last + 1;
            try out.append(alloc, .{ .line = line, .sub = 0, .left = left, .cols = width, .last = true });
        }
        return;
    }
    var line = top_line;
    var skip = top_sub;
    while (out.items.len < rows) : (line += 1) {
        if (fold.rangeOf(hidden, line)) |r| {
            line = r.last + 1;
            skip = 0;
        }
        if (line >= count) {
            try out.append(alloc, .{ .line = line, .sub = 0, .left = 0, .cols = width, .last = true });
            continue;
        }
        const text = try lines.text(alloc, line);
        defer alloc.free(text);
        var it = softwrap.Rows.init(text, opts, width);
        var sub: usize = 0;
        var pending: ?softwrap.Row = it.next();
        while (pending) |row| : (sub += 1) {
            pending = it.next();
            if (sub < skip) continue;
            if (out.items.len >= rows) break;
            try out.append(alloc, .{
                .line = line,
                .sub = sub,
                .left = row.start_col,
                .cols = row.end_col - row.start_col,
                .last = pending == null,
            });
        }
        skip = 0;
    }
}

/// A digest of which (line, row-of-line) each screen row shows -- what
/// `Slot.prev_row_hash` compares.
pub fn rowMapHash(map: []const RowView) u64 {
    var h = std.hash.Wyhash.init(0);
    for (map) |rv| {
        h.update(std.mem.asBytes(&rv.line));
        h.update(std.mem.asBytes(&rv.sub));
    }
    return h.final();
}

pub const BufferRenderState = struct {
    /// The scroll position the buffer layer's cells currently reflect.
    prev_top: usize,
    prev_left: usize,
    /// The scroll position this frame wants.
    top: usize,
    left: usize,
    /// `Buffer.edits` last frame vs. now -- any change means an edit.
    prev_edits: u64,
    edits: u64,
    /// Visible rows in the buffer pane.
    rows: usize,
    /// A pane bounds change or a fresh buffer forces a repaint.
    force_full: bool,
};

/// What `renderBuffer` should do this frame. Split out as a pure
/// decision so `tests/zoe_tests.zig` can exercise it without a live
/// client.
pub const BufferRender = union(enum) {
    /// Repaint every visible row.
    full,
    /// Shift the rows already on the layer by `count` in `dir` with one
    /// `move_content`, then repaint screen rows `[exposed_lo, exposed_hi)`.
    shift: struct {
        count: usize,
        dir: glyphwire.Layer.ScrollDir,
        exposed_lo: usize,
        exposed_hi: usize,
    },
};

/// A row shift can express a pure vertical scroll of less than a screen
/// and nothing else. An edit (`edits` moved), a horizontal scroll, a
/// jump of a screen or more, an empty pane, or a forced repaint are all
/// `.full`.
pub fn planBufferRender(s: BufferRenderState) BufferRender {
    const d: i64 = @as(i64, @intCast(s.top)) - @as(i64, @intCast(s.prev_top));
    const shift: usize = @abs(d);
    if (s.force_full or s.edits != s.prev_edits or s.left != s.prev_left or
        s.rows == 0 or shift == 0 or shift >= s.rows)
    {
        return .full;
    }
    return .{ .shift = .{
        .count = shift,
        .dir = if (d > 0) .up else .down,
        .exposed_lo = if (d > 0) s.rows - shift else 0,
        .exposed_hi = if (d > 0) s.rows else shift,
    } };
}

/// Cells the buffer-pane line-number gutter occupies for a file of
/// `line_count` lines shown in `mode`: the widest number's digit count,
/// floored at 3, plus one separator space. Zero when the gutter is off.
pub fn gutterWidthFor(mode: editor.LineNumbers, line_count: usize) usize {
    if (mode == .off) return 0;
    var n = line_count;
    var digits: usize = 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return @max(3, digits) + 1;
}

/// The text of one gutter cell, `width` display cells wide (a
/// `gutterWidthFor` result), for buffer line `line` (0-based),
/// `distance` on-screen lines from the caret's. `past_end` -- the
/// screen row is below the last buffer line -- gives an all-blank cell,
/// like vim leaves beside its `~` markers. The number is right-aligned
/// in the leading `width - 1` cells with the last cell a blank
/// separator; in `.relative` mode the caret's own line (distance 0)
/// still shows its absolute number. Written into `buf` (which must be
/// at least `width` bytes) and returned as a slice, so this needs no
/// allocator.
pub fn gutterCellText(
    buf: []u8,
    mode: editor.LineNumbers,
    width: usize,
    line: usize,
    distance: usize,
    past_end: bool,
) []const u8 {
    if (mode == .off or width == 0) return buf[0..0];
    @memset(buf[0..width], ' ');
    if (past_end) return buf[0..width];

    const value: usize = switch (mode) {
        .off => unreachable,
        .absolute => line + 1,
        .relative => if (distance == 0) line + 1 else distance,
    };

    var num: [24]u8 = undefined;
    const shown = std.fmt.bufPrint(&num, "{d}", .{value}) catch return buf[0..width];

    // Right-align in the digit field (`width - 1`); the trailing cell
    // stays the blank the memset left. A number wider than the field
    // (a min-width gutter over a huge file) is clamped to what fits.
    const digits = width - 1;
    const n = @min(shown.len, digits);
    @memcpy(buf[digits - n ..][0..n], shown[shown.len - n ..]);
    return buf[0..width];
}

/// The colour of the span covering line-relative byte `off`, or null for
/// "no span here" (the default text colour). Spans are sorted and
/// non-overlapping, so the first hit is the answer.
pub fn selEql(a: ?editor.Editor.SelSpan, b: ?editor.Editor.SelSpan) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.lo == b.?.lo and a.?.hi == b.?.hi and a.?.linewise == b.?.linewise;
}

pub fn spanColorAt(spans: []const syntax.Span, off: usize) ?Color {
    for (spans) |s| {
        if (off < s.start) return null;
        if (off < s.end) return s.color;
    }
    return null;
}

pub fn colorOptEql(a: ?Color, b: ?Color) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

/// One drawn row of the hover popup: bytes `[start, end)` of
/// `doc.lines[line]`, shown after `indent` blank cells.
pub const HoverRow = struct {
    line: usize,
    start: usize = 0,
    end: usize = 0,
    indent: usize = 0,
};

pub const spaces: [32]u8 = @splat(' ');

/// Cuts a hover doc into rows `cols` wide. A line keeps its leading
/// indentation on its first row, and its continuation rows are indented to
/// match, so wrapped code still lines up under the line it came from.
/// Wrapping is on spaces (`WrapIterator`), code included: a long signature
/// is a list of parameters, and breaking between them reads better than
/// clipping it.
pub fn wrapHover(
    alloc: std.mem.Allocator,
    doc: *const hover_mod.Doc,
    cols: usize,
    out: *std.ArrayList(HoverRow),
) !void {
    for (doc.lines, 0..) |line, i| {
        if (line.kind == .rule or line.text.len == 0) {
            try out.append(alloc, .{ .line = i });
            continue;
        }
        var indent: usize = 0;
        while (indent < line.text.len and line.text[indent] == ' ') indent += 1;
        // Deep indentation gives up its alignment rather than the text.
        if (indent > cols / 2) indent = 0;
        const body = line.text[indent..];
        var wrap = glyphwire.WrapIterator.init(body, cols - indent);
        var first = true;
        while (wrap.next()) |piece| {
            const start = indent + (@intFromPtr(piece.ptr) - @intFromPtr(body.ptr));
            try out.append(alloc, .{
                .line = i,
                // The first row carries its own indentation in its bytes.
                .start = if (first) 0 else start,
                .end = start + piece.len,
                .indent = if (first) 0 else indent,
            });
            first = false;
        }
        // All spaces: still a row.
        if (first) try out.append(alloc, .{ .line = i });
    }
}

/// Bytes `[start, end)` of `text` as client spans, coloured by `spans`
/// (offsets into the whole of `text`, sorted, non-overlapping -- what
/// `Highlighter.lineSpans` produces) and `default_fg` in the gaps.
pub fn colorRuns(
    alloc: std.mem.Allocator,
    text: []const u8,
    spans: []const syntax.Span,
    start: usize,
    end: usize,
    default_fg: Color,
    out: *std.ArrayList(glyphwire.client.Client.Span),
) !void {
    var at = start;
    for (spans) |s| {
        if (s.end <= at) continue;
        if (s.start >= end) break;
        if (s.start > at) {
            try out.append(alloc, .{ .text = text[at..s.start], .fg = default_fg });
            at = s.start;
        }
        const stop = @min(s.end, end);
        try out.append(alloc, .{ .text = text[at..stop], .fg = s.color });
        at = stop;
    }
    if (at < end) try out.append(alloc, .{ .text = text[at..end], .fg = default_fg });
}
