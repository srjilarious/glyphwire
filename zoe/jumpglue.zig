// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's side of the `jump` action: which word starts get labels, the
//! keys that type one, and when the labels go away. The labels
//! themselves are `zoe/jump.zig`'s, and `render.zig`'s `paintJumpRow`
//! draws them. `Ui` methods moved out of ui.zig and aliased back.
//!
//! A jump is modal while it is up, like the palette: every key goes to
//! it. A letter that is no label's next, or any other key, ends it
//! without moving, and so does anything that moves the rows the labels
//! were placed against -- a scroll, a click, a resize.

const std = @import("std");
const glyphwire = @import("glyphwire");
const jump_mod = @import("jump.zig");

const ui = @import("ui.zig");
const Ui = ui.Ui;

/// Shift+Enter: labels over the focused pane's word starts. False where
/// there is no buffer cursor to move (the tree, the `:` / `/` lines, the
/// find widget), so the key goes on as if unbound. Again while a jump is
/// up takes the labels down.
pub fn startJump(self: *Ui) !bool {
    if (self.jump != null) {
        self.cancelJump();
        return true;
    }
    if (self.focus != .buffer) return false;
    switch (self.buf.ed.mode) {
        .command, .search, .find => return false,
        .normal, .insert, .visual, .visual_line, .select => {},
    }
    _ = self.closeHover();
    self.closeCompletion();

    // The rows as they are on screen: the frame that drew them may have
    // been another group's, and `row_map` is shared.
    try self.layoutRows();
    const buf = &self.buf.ed.buf;
    const opts = self.displayOpts();
    var found: std.ArrayList(jump_mod.Target) = .empty;
    defer found.deinit(self.alloc);
    for (self.row_map.items, 0..) |rv, r| {
        if (rv.pastEnd(buf.lineCount())) continue;
        const text = try buf.lineText(self.alloc, rv.line);
        defer self.alloc.free(text);
        try jump_mod.collectRow(self.alloc, &found, text, buf.lineStart(rv.line), r, rv.left, rv.cols, opts);
    }
    if (found.items.len == 0) {
        self.buf.ed.setStatus("No words to jump to", .{});
        self.status_dirty = true;
        return true;
    }

    // Nearest to the caret; the top left if it is scrolled out of view.
    var caret_row: usize = 0;
    var caret_col: usize = 0;
    if (try self.caretCell(self.buf.ed.pos().line)) |c| {
        caret_row = c.row;
        caret_col = c.col - self.gutterWidth();
    }
    self.jump = try jump_mod.Jump.init(self.alloc, found.items, caret_row, caret_col);
    self.jump_group = self.grp;
    self.buf.ed.setStatus("Jump: type a label (Esc cancels)", .{});
    markJumpDirty(self);
    return true;
}

/// Takes the labels down without moving.
pub fn cancelJump(self: *Ui) void {
    if (self.jump == null) return;
    markJumpDirty(self);
    self.jump.?.deinit(self.alloc);
    self.jump = null;
    self.jump_group = null;
    self.buf.ed.status.clearRetainingCapacity();
    self.status_dirty = true;
}

/// The pane the labels are on, repainted whole: they sit over rows the
/// row-by-row repaint has no reason to touch.
fn markJumpDirty(self: *Ui) void {
    const g = self.jump_group orelse self.grp;
    g.slot().full_redraw = true;
    g.buffer_dirty = true;
}

/// A key press while a jump is up. Letters are left for the `text` that
/// follows them (`jumpText`); Backspace takes the typed letter back, and
/// every other key ends the jump and is swallowed.
pub fn jumpKey(self: *Ui, k: glyphwire.KeyEvent) void {
    if (ui.isModifierKey(k.key)) return;
    if (k.key.len == 1 and !k.ctrl() and !k.alt()) return;
    if (std.mem.eql(u8, k.key, "backspace") and self.jump.?.back()) {
        markJumpDirty(self);
        return;
    }
    self.cancelJump();
}

/// Typed text while a jump is up: each letter narrows the labels, and
/// the last one of a label moves the cursor there.
pub fn jumpText(self: *Ui, text: []const u8) void {
    for (text) |c| {
        const j = if (self.jump) |*j| j else return;
        switch (j.key(c)) {
            .narrowed => markJumpDirty(self),
            .miss => self.cancelJump(),
            .chosen => |off| {
                self.cancelJump();
                self.pushJump();
                _ = self.buf.ed.jumpTo(off);
                self.grp.buffer_dirty = true;
                return;
            },
        }
    }
}
