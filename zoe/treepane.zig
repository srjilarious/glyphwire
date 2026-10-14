// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's file tree pane: its keys, scrolling, the tree search (`/` in
//! the tree, and the finder's scopes), and creating or renaming entries
//! in place. `Ui` methods moved out of ui.zig and aliased back.

const std = @import("std");
const glyphwire = @import("glyphwire");
const tree_mod = @import("tree.zig");
const fsops = @import("applib").fsops;
const lineedit = @import("applib").lineedit;

const ui = @import("ui.zig");
const Ui = ui.Ui;
const FindScope = ui.FindScope;
const TreeEdit = ui.TreeEdit;
const TreeFind = ui.TreeFind;
const tree_scroll_margin = ui.tree_scroll_margin;
const tree_trailing_rows = ui.tree_trailing_rows;

/// The tree layer's content grid, which is also exactly what
/// `renderTree` paints -- one definition, so the grid can never be
/// bigger than the rows written into it.
///
/// The listing, but never smaller than the viewport *at its current
/// scroll offset*. Sizing it to the listing alone leaves the rows
/// past the end transparent whenever the host is still scrolled down
/// into a listing that just got shorter (a collapsed directory), and
/// a transparent sidebar row shows the shell's scrollback through it.
/// `clampTreeScroll` pulls the offset back too, so in practice these
/// max out at the listing; this is the half that cannot be raced.
pub fn treeContentRows(self: *const Ui) usize {
    return @max(self.treeListedRows() + tree_trailing_rows, self.tree_scroll.row + self.tree_bounds.rows);
}

/// Rows the listing occupies: the tree's entries, plus the virtual
/// row a create's name field is drawn on.
pub fn treeListedRows(self: *const Ui) usize {
    const extra: usize = if (self.tree_edit) |te| @intFromBool(te.inserts()) else 0;
    return self.tree.len() + extra;
}

/// The entry drawn on pane row `r`: the tree's own, shifted down one
/// past a create's virtual row.
pub fn treeRowEntry(self: *const Ui, r: usize) ?tree_mod.Entry {
    if (self.tree_edit) |te| {
        if (te.inserts() and r > te.row) return self.tree.at(r - 1);
    }
    return self.tree.at(r);
}

pub fn treeContentCols(self: *const Ui) usize {
    return @max(self.tree.widestCols(), self.tree_scroll.col + self.tree_bounds.cols);
}

/// Pulls the tree's scroll offset back when the listing shrank under
/// it, so the viewport keeps showing entries rather than the blank
/// rows past the last one.
pub fn clampTreeScroll(self: *Ui) void {
    const rows = self.tree_bounds.rows;
    if (rows == 0) return;
    const max_top = (self.tree.len() + tree_trailing_rows) -| rows;
    if (self.tree_scroll.row <= max_top) return;
    self.tree_scroll.row = max_top;
    // Immediate rather than batched, unlike `scrollTreeToCursor`: the
    // caller is about to shrink the content grid around this offset,
    // and the host has to have pulled the viewport back first.
    self.tree_scroll_pending = null;
    self.client.setLayerScrollOffset(self.tree_layer, max_top, self.tree_scroll.col) catch {};
}

/// Whether the named key is one of the tree pane's own cursor
/// commands -- the set a running search is cancelled by.
///
/// This is a *closed list*, not "everything the search didn't
/// consume", and the difference is the whole point. **Every printable
/// keystroke is delivered twice**: once as a `key` notification and
/// once as `text` (it is why the Ctrl+letter chords in `handleInput`
/// can match on `k.key` at all). Cancelling on any unrecognised key
/// therefore killed the search on the `key` half of the very
/// keystroke whose `text` half was about to extend it -- typing in
/// the tree searched nothing, and the prompt reappearing on the next
/// trigger looked like a search that had simply found no match.
///
/// `escape` is deliberately absent: while a search is up
/// `findKey` has already taken it, and with no search there is
/// nothing to cancel.
pub fn endsTreeSearch(key: []const u8) bool {
    const commands = [_][]const u8{
        "down", "up", "page_down", "page_up", "home", "end", "enter",
    };
    for (commands) |c| {
        if (std.mem.eql(u8, key, c)) return true;
    }
    return false;
}

pub fn treeKey(self: *Ui, ev: glyphwire.KeyEvent) !void {
    // So does the name field, and it never lets a key through.
    if (self.tree_edit != null) return self.treeEditKey(ev);

    // A search owns the keyboard while it is up, the way the Ctrl+P
    // popup does: Tab steps the candidates, Backspace shortens the
    // prefix, Enter takes the row and Escape drops the search.
    if (self.find != null and try self.findKey(ev)) return;

    // Moving the cursor by hand ends a running search -- the prefix
    // stops describing where the cursor is. Gated on the command set
    // rather than on "anything findKey didn't want", which is the
    // distinction `endsTreeSearch` exists to make.
    const eq = std.mem.eql;
    const key = ev.key;
    if (endsTreeSearch(key)) self.cancelFind();

    if (eq(u8, key, "down")) self.treeMove(1);
    if (eq(u8, key, "up")) self.treeMove(-1);
    if (eq(u8, key, "page_down")) self.treeMove(@intCast(self.treePageRows()));
    if (eq(u8, key, "page_up")) self.treeMove(-@as(i64, @intCast(self.treePageRows())));
    if (eq(u8, key, "home")) self.treeGoto(0);
    if (eq(u8, key, "end")) self.treeGoto(self.tree.len() -| 1);
    if (eq(u8, key, "enter")) try self.treeActivate();
    if (eq(u8, key, "escape")) self.setFocus(.buffer);
    // salacommander's keys for the same three, alongside `a` and `r`
    // (`treeText`): F2 renames, F7 makes a directory, Shift+F4 a file.
    if (eq(u8, key, "F2")) try self.startTreeRename();
    if (eq(u8, key, "F7")) try self.startTreeCreate(.create_dir);
    if (eq(u8, key, "F4") and ev.mods.shift) try self.startTreeCreate(.create);
}

/// How far Page Up / Page Down move in the tree: `tree_page_lines`
/// from `zoe.conf.lua`, or by default a viewport less one row of
/// overlap, so the entry that was at the edge is still on screen to
/// read from.
///
/// The *default* is deliberately not the buffer pane's rule. That one
/// moves a flat `page_lines` (default 10) whatever the pane's height,
/// because a jump in a file is a jump through text and the window it
/// happens to be seen through is incidental. A jump in a listing is a
/// jump through what is on screen, so the screen sets it -- which
/// also means it stays right when the sidebar is resized, with
/// nothing to keep in sync. The two are separate keys for that
/// reason, rather than one governing both panes.
pub fn treePageRows(self: *const Ui) usize {
    if (self.hl_config) |cfg| {
        if (cfg.tree_page_lines >= 1) return cfg.tree_page_lines;
    }
    return @max(1, self.tree_bounds.rows -| 1);
}

/// Tree navigation reuses vim's own keys, so switching panes doesn't
/// switch keyboards -- which is also why type-to-find needs a trigger
/// rather than starting on any letter the way salacommander's does:
/// here the letters are already commands. `f` searches what is on
/// screen, `/` searches the whole tree. See `TreeFind`.
pub fn treeText(self: *Ui, text: []const u8) !void {
    if (self.tree_edit != null) return self.treeEditText(text);
    if (self.find != null) return self.findText(text);

    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (cp.len != 1) continue;
        switch (cp[0]) {
            'j' => self.treeMove(1),
            'k' => self.treeMove(-1),
            'g' => self.treeGoto(0),
            'G' => self.treeGoto(self.tree.len() -| 1),
            ' ', 'l' => try self.treeActivate(),
            'h' => self.treeMove(-1),
            'q' => self.setFocus(.buffer),
            'f' => try self.startFind(.visible),
            '/' => try self.startFind(.deep),
            // nvim-tree's: `a` adds (a trailing `/` makes it a
            // folder), `r` renames. Whatever else this chunk held is
            // dropped -- it arrived before the field was there.
            'a' => return self.startTreeCreate(.create),
            'r' => return self.startTreeRename(),
            else => {},
        }
    }
}

pub fn treeMove(self: *Ui, delta: i64) void {
    const n = self.tree.len();
    if (n == 0) return;
    const next = @as(i64, @intCast(self.tree.cursor)) + delta;
    self.treeGoto(@intCast(std.math.clamp(next, 0, @as(i64, @intCast(n - 1)))));
}

/// Puts the cursor on `index` and follows it with the viewport. The
/// one way the cursor moves, so the scroll and the repaint can't be
/// forgotten at a call site.
pub fn treeGoto(self: *Ui, index: usize) void {
    if (self.tree.len() == 0) return;
    self.tree.cursor = @min(index, self.tree.len() - 1);
    self.scrollTreeToCursor();
    // Nothing but the highlight moved -- see `TreeDirty`.
    self.markTreeDirty(.selection);
}

/// Ctrl+Shift+E: finds the focused group's file in the sidebar. The tree
/// is shown if it was hidden, the folders down to the file are opened,
/// and the cursor lands on it and is scrolled into view. The keyboard
/// stays where it was -- in the editor, or in the tree if it was there
/// -- so this can be a glance at where a file lives as well as a way to
/// act on it.
pub fn revealInTree(self: *Ui) !void {
    const abs = self.slotAbs(self.buf) orelse {
        self.buf.ed.setStatus("No file to reveal: the buffer has no name", .{});
        self.status_dirty = true;
        return;
    };
    // A search's candidates and an edit field's row are indices into the
    // listing the reveal is about to open folders in.
    self.cancelFind();
    self.cancelTreeEdit();
    const index = (try self.tree.revealPath(self.io, abs)) orelse {
        // Outside every root, or hidden while hidden files are.
        self.buf.ed.setStatus("\"{s}\" isn't in the file tree", .{abs});
        self.status_dirty = true;
        return;
    };
    if (!self.tree_visible) try self.setTreeVisible(true);
    // Opened folders added rows, so the whole tree repaints, not just
    // the highlight `treeGoto` marks.
    self.markTreeDirty(.full);
    self.treeGoto(index);
}

/// Keeps the tree's cursor inside the host-scrolled viewport by
/// queueing a new `scroll_offset`, since the host has no idea zoe has
/// a cursor. Queued rather than sent so it rides out in the same
/// batch as the frame it belongs to (`tree_scroll_pending`).
///
/// The cursor is kept `tree_scroll_margin` rows clear of both edges
/// rather than merely on screen -- vim's `scrolloff`, and here it is
/// load-bearing rather than a comfort: the host draws the horizontal
/// scrollbar *over* the pane's bottom row, so a cursor allowed to sit
/// on that row is a highlighted entry you cannot read. The margin is
/// capped to half the viewport so it still behaves in a short pane,
/// and the clamp at the end is what lets the end of the listing win
/// -- there the trailing blank row (`tree_trailing_rows`) is what
/// takes the scrollbar instead.
pub fn scrollTreeToCursor(self: *Ui) void {
    self.scrollTreeToRow(self.tree.cursor, self.tree.len());
}

/// `scrollTreeToCursor` for any row of a `len`-row listing -- the
/// name field's, which sits in a listing one row longer than the
/// tree while a create is being typed.
pub fn scrollTreeToRow(self: *Ui, row: usize, len: usize) void {
    const rows = self.tree_bounds.rows;
    if (rows == 0) return;
    const top = treeScrollTop(row, self.tree_scroll.row, rows, len);
    if (top == self.tree_scroll.row) return;

    self.tree_scroll.row = top;
    self.tree_scroll_pending = .{ .row = top, .col = self.tree_scroll.col };
}

/// Where the tree's viewport has to sit for a cursor at `cursor`,
/// given the current offset `top`, a `rows`-tall pane and a `len`
/// entry listing. Pure, so `tests/zoe_tests.zig` can pin the margin
/// arithmetic -- which is all off-by-ones, and the cost of getting
/// one wrong is an entry highlighted underneath the scrollbar.
pub fn treeScrollTop(cursor: usize, top: usize, rows: usize, len: usize) usize {
    const margin = @min(tree_scroll_margin, (rows -| 1) / 2);
    var out = top;
    if (cursor < out + margin) out = cursor -| margin;
    if (cursor + margin >= out + rows) out = (cursor + margin + 1) -| rows;
    // Never past the end of the content: the last entries have
    // nothing below them to scroll into, and the margin gives way to
    // the trailing blank row, which is what takes the scrollbar there.
    return @min(out, (len + tree_trailing_rows) -| rows);
}

/// Enter/Space on a directory expands it, on a file opens it.
pub fn treeActivate(self: *Ui) !void {
    const entry = self.tree.at(self.tree.cursor) orelse return;
    if (entry.is_dir) {
        try self.tree.toggle(self.io, self.tree.cursor);
        // A collapse can leave the host scrolled past the end of the
        // shortened listing; pull it back before the grid is resized
        // around it.
        self.clampTreeScroll();
        try self.syncContentSizes();
        // A collapse can leave the cursor inside the bottom margin of
        // a listing that just got shorter -- `clampTreeScroll` only
        // pulls the viewport back off the end, it knows nothing about
        // the cursor. Queued after the grid resize, so it rides out
        // with the repaint below.
        self.scrollTreeToCursor();
        // The listing itself changed shape.
        self.markTreeDirty(.full);
        return;
    }
    try self.openFile(entry.path);
    self.setFocus(.buffer);
}

/// Opens a search in `scope` (see `FindScope`). A `.deep` one walks
/// the whole tree first, which is the only expensive thing either
/// scope does and is why it happens once, here, rather than per
/// keystroke.
pub fn startFind(self: *Ui, scope: FindScope) !void {
    self.cancelFind();
    var find: TreeFind = .{ .scope = scope, .anchor = self.tree.cursor };
    errdefer find.deinit(self.alloc);
    if (scope == .deep) {
        const roots = try self.tree.rootPaths(self.alloc);
        defer self.alloc.free(roots);
        find.deep = try tree_mod.deepListRoots(self.alloc, self.io, roots, self.tree.visible);
    }
    self.find = find;
    self.status_dirty = true;
}

/// `a` / Shift+F4 (`.create`) and F7 (`.create_dir`): opens the name
/// field for a new entry in the directory under the cursor -- the row
/// itself when it is a directory, else the one it is in -- expanding
/// that directory so the new row has a place among its children.
pub fn startTreeCreate(self: *Ui, kind: TreeEdit.Kind) !void {
    self.cancelFind();
    self.cancelTreeEdit();
    const dir = try self.alloc.dupe(u8, self.tree.dirFor(self.tree.cursor));
    errdefer self.alloc.free(dir);
    const old_name = try self.alloc.dupe(u8, "");
    errdefer self.alloc.free(old_name);

    var row: usize = 0;
    var depth: usize = 0;
    if (try self.tree.openDirRow(self.io, dir)) |index| {
        row = index + 1;
        depth = self.tree.entries.items[index].depth + 1;
        self.tree.cursor = index;
    }
    self.tree_edit = .{ .kind = kind, .dir = dir, .old_name = old_name, .row = row, .depth = depth };
    self.showTreeEdit();
}

/// `r` / F2: opens the name field over the entry under the cursor,
/// filled with its name and the caret before a file's extension --
/// salacommander's F2 rule (`fsops.renameCaret`). Ctrl+U from there
/// leaves just the extension to type in front of.
pub fn startTreeRename(self: *Ui) !void {
    self.cancelFind();
    self.cancelTreeEdit();
    const e = self.tree.at(self.tree.cursor) orelse return;
    // A workspace folder's header is the folder itself, not a name in
    // some parent zoe is showing; `:rmfolder` is what takes it out of
    // the sidebar.
    if (e.is_root) {
        self.buf.ed.setStatus("E: \"{s}\" is a workspace folder; rename it outside zoe", .{e.name});
        self.status_dirty = true;
        return;
    }
    const dir = try self.alloc.dupe(u8, std.fs.path.dirname(e.path) orelse self.tree.roots.items[e.root].path);
    errdefer self.alloc.free(dir);
    const old_name = try self.alloc.dupe(u8, e.name);
    errdefer self.alloc.free(old_name);
    var field = try lineedit.LineEdit.init(self.alloc, e.name);
    errdefer field.deinit(self.alloc);
    _ = field.moveTo(fsops.renameCaret(e.name, e.is_dir));
    self.tree_edit = .{
        .kind = .rename,
        .field = field,
        .dir = dir,
        .old_name = old_name,
        .row = self.tree.cursor,
        .depth = e.depth,
    };
    self.showTreeEdit();
}

/// Puts a just-opened field on screen: the keyboard in the tree, the
/// grid one row longer for a create, the field's row scrolled into
/// view, and the listing repainted around it. Can't fail: the field
/// already owns its strings, so the callers' cleanup is behind them.
pub fn showTreeEdit(self: *Ui) void {
    const te = &self.tree_edit.?;
    self.setFocus(.tree);
    self.syncContentSizes() catch {};
    self.scrollTreeToRow(te.row, self.treeListedRows());
    self.markTreeDirty(.full);
    self.status_dirty = true;
}

/// Closes the name field without doing anything. Safe to call when
/// there is none.
pub fn cancelTreeEdit(self: *Ui) void {
    var te = self.tree_edit orelse return;
    te.deinit(self.alloc);
    self.tree_edit = null;
    self.clampTreeScroll();
    self.syncContentSizes() catch {};
    self.markTreeDirty(.full);
    self.status_dirty = true;
}

/// A named key while the field is up. It owns the keyboard: whatever
/// the field doesn't use is swallowed rather than moving a cursor the
/// field is drawn relative to.
pub fn treeEditKey(self: *Ui, ev: glyphwire.KeyEvent) !void {
    const te = &self.tree_edit.?;
    switch (te.field.handleKey(ev.key, ev.mods)) {
        .submit => try self.commitTreeEdit(),
        .cancel => self.cancelTreeEdit(),
        .edited => {
            te.err = null;
            self.tree_edit_dirty = true;
            self.status_dirty = true;
        },
        .moved => self.tree_edit_dirty = true,
        .ignored => {},
    }
}

/// Typed text while the field is up.
pub fn treeEditText(self: *Ui, text: []const u8) !void {
    const te = &self.tree_edit.?;
    if (!try te.field.insert(self.alloc, text)) return;
    te.err = null;
    self.tree_edit_dirty = true;
    self.status_dirty = true;
}

/// Enter in the field. A name that can't be used (exists already, has
/// a `..`, or a `/` in a rename) keeps the field open with the reason
/// on the statusline; anything else closes it, re-reads the tree and
/// puts the cursor on the result. A new file also opens in a tab, with
/// the keyboard there -- making one is a prelude to typing in it.
pub fn commitTreeEdit(self: *Ui) !void {
    const te = &self.tree_edit.?;
    const name = te.field.text();
    // An empty field, or a rename left as it was, is a change of mind.
    if (name.len == 0 or (te.kind == .rename and std.mem.eql(u8, name, te.old_name))) {
        return self.cancelTreeEdit();
    }

    switch (te.kind) {
        .rename => {
            fsops.renameInDir(self.io, self.alloc, te.dir, te.old_name, name) catch |err| {
                te.err = treeEditError(err);
                self.status_dirty = true;
                return;
            };
            const old_abs = try std.fs.path.join(self.alloc, &.{ te.dir, te.old_name });
            defer self.alloc.free(old_abs);
            const new_abs = try std.fs.path.join(self.alloc, &.{ te.dir, name });
            defer self.alloc.free(new_abs);
            self.retargetBuffers(old_abs, new_abs);
            self.cancelTreeEdit();
            try self.refreshTree(new_abs);
        },
        .create, .create_dir => {
            fsops.checkNewPath(name) catch |err| {
                te.err = treeEditError(err);
                self.status_dirty = true;
                return;
            };
            const as_dir = te.kind == .create_dir or std.mem.endsWith(u8, name, "/");
            const abs = try std.fs.path.join(self.alloc, &.{ te.dir, std.mem.trimEnd(u8, name, "/") });
            defer self.alloc.free(abs);
            const made = if (as_dir) fsops.makeDir(self.io, abs) else fsops.makeFile(self.io, abs);
            made catch |err| {
                te.err = treeEditError(err);
                self.status_dirty = true;
                return;
            };
            self.cancelTreeEdit();
            try self.refreshTree(abs);
            if (!as_dir) {
                try self.openFile(abs);
                self.setFocus(.buffer);
            }
        },
    }
}

/// The statusline text for a create or rename that didn't take.
pub fn treeEditError(err: anyerror) []const u8 {
    return switch (err) {
        error.PathAlreadyExists => "E: that name already exists",
        error.InvalidName => "E: not a usable name (no `/` in a rename, no `.` or `..` parts)",
        error.EmptyName => "E: the name is empty",
        error.AccessDenied, error.PermissionDenied => "E: permission denied",
        error.FileNotFound => "E: it is no longer there",
        else => "E: the filesystem refused it",
    };
}

/// After a rename on disk: every open buffer on the renamed file, or
/// anywhere under a renamed directory, follows it to the new path --
/// otherwise its next `:w` would quietly recreate the old name. The
/// language servers are told the old document closed; the buffer
/// reopens under its new name on the next sync, the same as `:w
/// <newname>` does it.
pub fn retargetBuffers(self: *Ui, old_abs: []const u8, new_abs: []const u8) void {
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| {
            const abs = self.slotAbs(slot) orelse continue;
            const rest: []const u8 = if (std.mem.eql(u8, abs, old_abs))
                ""
            else if (std.mem.startsWith(u8, abs, old_abs) and abs.len > old_abs.len and abs[old_abs.len] == '/')
                abs[old_abs.len..]
            else
                continue;
            const moved = std.mem.concat(self.alloc, u8, &.{ new_abs, rest }) catch continue;
            defer self.alloc.free(moved);

            self.lspDidClose(slot);
            slot.ed.setPath(moved) catch continue;
            self.invalidateAbs(slot);
            slot.lsp_opened = false;
            slot.ed.line_comment = self.lineCommentFor(slot.ed.path);
            slot.ed.colon_block = self.colonBlockFor(slot.ed.path);
            self.selectHighlightLanguage(slot, slot.ed.path);
            g.tabs_dirty = true;
        }
    }
    self.status_dirty = true;
}

pub fn cancelFind(self: *Ui) void {
    if (self.find) |*f| {
        f.deinit(self.alloc);
        self.find = null;
        self.status_dirty = true;
    }
}

/// A named key while a search is up. Returns true when the search
/// consumed it, false to let the ordinary tree bindings have it.
pub fn findKey(self: *Ui, ev: glyphwire.KeyEvent) !bool {
    const eq = std.mem.eql;
    const f = &self.find.?;

    if (eq(u8, ev.key, "escape")) {
        // The cursor stays where the search put it, and so does any
        // folder the search opened to get there: an abandoned search
        // has still told you where the file is.
        self.cancelFind();
        return true;
    }
    if (eq(u8, ev.key, "enter")) {
        self.cancelFind();
        try self.treeActivate();
        return true;
    }
    if (eq(u8, ev.key, "tab")) {
        if (f.hits.items.len == 0) return true;
        const n = f.hits.items.len;
        f.pick = if (ev.shift()) (f.pick + n - 1) % n else (f.pick + 1) % n;
        try self.applyFind();
        return true;
    }
    if (eq(u8, ev.key, "backspace")) {
        if (f.query.items.len == 0) {
            self.cancelFind();
            return true;
        }
        f.query.shrinkRetainingCapacity(lineedit.prevBoundary(f.query.items, f.query.items.len));
        if (f.query.items.len == 0) {
            self.cancelFind();
            return true;
        }
        try self.refilterFind();
        try self.applyFind();
        return true;
    }
    return false;
}

/// Typed text while a search is up. A character that would leave no
/// candidates is dropped rather than appended, so the prefix always
/// describes where the cursor is -- salacommander's type-to-find
/// makes the same trade, and it is what stops a typo from stranding
/// the search on a query nothing matches.
pub fn findText(self: *Ui, text: []const u8) !void {
    const f = &self.find.?;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepointSlice()) |cp| {
        // Tab and Enter reach the text stream as well as the key one,
        // and they are the search's own controls -- `findKey` has
        // already acted on them, so they are not also characters to
        // match on. No file name contains one either.
        if (cp.len == 1 and (cp[0] < 0x20 or cp[0] == 0x7f)) continue;
        const before = f.query.items.len;
        try f.query.appendSlice(self.alloc, cp);
        try self.refilterFind();
        if (f.hits.items.len == 0) {
            f.query.shrinkRetainingCapacity(before);
            try self.refilterFind();
            continue;
        }
        try self.applyFind();
    }
    self.status_dirty = true;
}

/// Rebuilds the candidate list for the current query and puts the
/// pick back on the first one. Prefix-matched case-insensitively
/// against the *name*, not the path: what is being typed is a file
/// name, in both scopes.
pub fn refilterFind(self: *Ui) !void {
    const f = &self.find.?;
    f.hits.clearRetainingCapacity();
    f.pick = 0;
    if (f.query.items.len == 0) return;

    switch (f.scope) {
        // Starting the walk at the row after the anchor is what makes
        // the search read as "forward from where I was", and the wrap
        // is why it still finds everything behind it.
        .visible => {
            const n = self.tree.len();
            const from = if (n == 0) 0 else (@min(f.anchor, n - 1) + 1) % n;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const index = (from + i) % n;
                if (std.ascii.startsWithIgnoreCase(self.tree.entries.items[index].name, f.query.items)) {
                    try f.hits.append(self.alloc, index);
                }
            }
        },
        .deep => {
            const deep = &f.deep.?;
            for (deep.paths.items, 0..) |_, i| {
                if (std.ascii.startsWithIgnoreCase(deep.nameAt(i), f.query.items)) {
                    try f.hits.append(self.alloc, i);
                }
            }
        },
    }
}

/// Moves the cursor onto the picked candidate. In `.deep` scope that
/// means opening whatever folders stand between the root and the hit
/// (`Tree.reveal`), which changes the listing -- hence the full
/// repaint and the content resize.
pub fn applyFind(self: *Ui) !void {
    const f = &self.find.?;
    self.status_dirty = true;
    if (f.hits.items.len == 0) return;
    const hit = f.hits.items[f.pick];

    switch (f.scope) {
        .visible => self.treeGoto(hit),
        .deep => {
            const deep = &f.deep.?;
            const index = (try self.tree.revealIn(self.io, deep.root_of.items[hit], deep.paths.items[hit])) orelse return;
            try self.syncContentSizes();
            self.treeGoto(index);
            self.markTreeDirty(.full);
        },
    }
}
