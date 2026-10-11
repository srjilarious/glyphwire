// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! A dialog laid out as widgets at fixed cells: text, one-line fields,
//! checkboxes, radio buttons and buttons. `dialog.zig`'s `Dialog` is one
//! message and a row of buttons; the chmod and chown dialogs need a grid
//! of toggles and more than one field, so they're built from this.
//!
//! Like `Dialog` it is plain state: `ui.zig` draws it (`Ui.renderForm`)
//! and feeds it keys, text and clicks, and each comes back as an `Event`
//! -- a widget changed, or a button was pressed -- for the dialog built
//! on it (`attrdialog.zig`) to act on.
//!
//! Tab and Shift+Tab walk every widget that takes focus, in the order
//! they were added; the arrow keys move to the nearest one that way, so
//! a grid of checkboxes is walked like a grid. Space flips a checkbox,
//! picks a radio button or presses a button. Enter presses the focused
//! button, or the first one when focus is elsewhere; Escape the way out.

const std = @import("std");
const glyphwire = @import("glyphwire");
const dialog = @import("dialog.zig");

pub const Button = dialog.Button;
pub const LineEdit = dialog.LineEdit;
pub const set_cancel_buttons = dialog.set_cancel;

pub const Widget = struct {
    /// Where it's drawn, in dialog cells (row 0 is the title).
    row: usize,
    col: usize,
    kind: Kind,

    pub const Kind = union(enum) {
        text: []const u8,
        field: Field,
        check: Toggle,
        /// On together with no other radio of the same `group`.
        radio: Toggle,
        button: Button,
    };

    pub const Field = struct { edit: LineEdit, width: usize };

    pub const Toggle = struct {
        /// Drawn after the box; may be empty for a box alone.
        label: []const u8,
        on: bool = false,
        group: u8 = 0,
    };

    pub fn focusable(self: *const Widget) bool {
        return self.kind != .text;
    }

    /// Cells wide on screen, for hit-testing a click.
    pub fn width(self: *const Widget) usize {
        return switch (self.kind) {
            .text => |t| glyphwire.stringWidth(t),
            .field => |f| f.width,
            .check, .radio => |t| if (t.label.len == 0) 3 else 4 + glyphwire.stringWidth(t.label),
            .button => |b| b.label().len + 4,
        };
    }
};

pub const Event = union(enum) {
    none,
    /// The widget at this index changed: a field's text, a checkbox, or
    /// a radio button (now on).
    changed: usize,
    button: Button,
};

pub const Form = struct {
    /// Holds the title and every label.
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    widgets: std.ArrayList(Widget) = .empty,
    focus: usize = 0,
    /// Size in cells, the title row included. Set by the builder.
    w: usize = 40,
    h: usize = 10,
    /// Drawn in the warning colour: the change runs as root.
    danger: bool = false,
    /// A line of complaint (an octal value that isn't one, a user that
    /// doesn't exist), drawn on `error_row`. Borrowed or in `arena`.
    err: ?[]const u8 = null,
    error_row: usize = 0,

    pub fn init(alloc: std.mem.Allocator, title: []const u8) !Form {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        // Before the arena is copied into the result, or the copy misses
        // the block this allocates.
        const owned = try arena.allocator().dupe(u8, title);
        return .{ .arena = arena, .title = owned };
    }

    pub fn deinit(self: *Form, alloc: std.mem.Allocator) void {
        for (self.widgets.items) |*w| {
            if (w.kind == .field) w.kind.field.edit.deinit(alloc);
        }
        self.widgets.deinit(alloc);
        self.arena.deinit();
    }

    /// Adds a widget, its labels copied into the form. Returns its index.
    pub fn add(self: *Form, alloc: std.mem.Allocator, widget: Widget) !usize {
        var w = widget;
        const a = self.arena.allocator();
        switch (w.kind) {
            .text => |t| w.kind.text = try a.dupe(u8, t),
            .check => |*t| t.label = try a.dupe(u8, t.label),
            .radio => |*t| t.label = try a.dupe(u8, t.label),
            .field, .button => {},
        }
        try self.widgets.append(alloc, w);
        return self.widgets.items.len - 1;
    }

    pub fn addText(self: *Form, alloc: std.mem.Allocator, row: usize, col: usize, text: []const u8) !usize {
        return self.add(alloc, .{ .row = row, .col = col, .kind = .{ .text = text } });
    }

    pub fn addField(self: *Form, alloc: std.mem.Allocator, row: usize, col: usize, width: usize, initial: []const u8) !usize {
        var edit = try LineEdit.init(alloc, initial);
        errdefer edit.deinit(alloc);
        return self.add(alloc, .{ .row = row, .col = col, .kind = .{ .field = .{ .edit = edit, .width = width } } });
    }

    pub fn addCheck(self: *Form, alloc: std.mem.Allocator, row: usize, col: usize, label: []const u8, on: bool) !usize {
        return self.add(alloc, .{ .row = row, .col = col, .kind = .{ .check = .{ .label = label, .on = on } } });
    }

    pub fn addRadio(self: *Form, alloc: std.mem.Allocator, row: usize, col: usize, group: u8, label: []const u8, on: bool) !usize {
        return self.add(alloc, .{ .row = row, .col = col, .kind = .{ .radio = .{ .label = label, .on = on, .group = group } } });
    }

    /// A row of buttons centred on `row`.
    pub fn addButtons(self: *Form, alloc: std.mem.Allocator, row: usize, buttons: []const Button) !void {
        var total: usize = 0;
        for (buttons) |b| total += b.label().len + 4 + 1;
        var col = (self.w -| total) / 2;
        for (buttons) |b| {
            _ = try self.add(alloc, .{ .row = row, .col = col, .kind = .{ .button = b } });
            col += b.label().len + 4 + 1;
        }
    }

    pub fn field(self: *Form, i: usize) *LineEdit {
        return &self.widgets.items[i].kind.field.edit;
    }

    pub fn isOn(self: *const Form, i: usize) bool {
        return switch (self.widgets.items[i].kind) {
            .check, .radio => |t| t.on,
            else => false,
        };
    }

    pub fn setOn(self: *Form, i: usize, on: bool) void {
        switch (self.widgets.items[i].kind) {
            .check, .radio => |*t| t.on = on,
            else => {},
        }
    }

    /// A key press. `key` is a glyphwire key name.
    pub fn handleKey(self: *Form, key: []const u8, mods: glyphwire.Mods) Event {
        const eq = std.mem.eql;
        if (eq(u8, key, "enter") or eq(u8, key, "kp_enter")) {
            if (self.focusedKind()) |k| if (k == .button) return .{ .button = k.button };
            return .{ .button = self.firstButton() orelse return .none };
        }
        if (eq(u8, key, "escape")) return .{ .button = self.escapeButton() orelse return .none };
        if (eq(u8, key, "tab")) {
            self.cycleFocus(mods.shift);
            return .none;
        }
        if (eq(u8, key, "up")) return self.moveFocus(.up);
        if (eq(u8, key, "down")) return self.moveFocus(.down);

        if (self.widgets.items.len == 0) return .none;
        const i = self.focus;
        switch (self.widgets.items[i].kind) {
            .field => |*f| {
                // Editing and caret keys are the field's (typed
                // characters come again as `text`). Left at its start or
                // right at its end moves nothing, so they fall through
                // and leave the field instead.
                switch (f.edit.handleKey(key, mods)) {
                    .edited => return .{ .changed = i },
                    .moved, .submit, .cancel => return .none,
                    .ignored => {},
                }
            },
            else => {},
        }
        if (eq(u8, key, "left")) return self.moveFocus(.left);
        if (eq(u8, key, "right")) return self.moveFocus(.right);
        if (eq(u8, key, "space")) return self.activate(i);
        return .none;
    }

    /// Committed text, typed into the focused field if that's what has
    /// focus.
    pub fn handleText(self: *Form, alloc: std.mem.Allocator, s: []const u8) !Event {
        if (self.widgets.items.len == 0) return .none;
        const i = self.focus;
        switch (self.widgets.items[i].kind) {
            .field => |*f| {
                _ = try f.edit.insert(alloc, s);
                return .{ .changed = i };
            },
            else => return .none,
        }
    }

    /// A left click at `row`/`col` in dialog cells: focus what's there
    /// and act on it as Space would.
    pub fn click(self: *Form, row: usize, col: usize) Event {
        for (self.widgets.items, 0..) |*w, i| {
            if (!w.focusable() or w.row != row) continue;
            if (col < w.col or col >= w.col + w.width()) continue;
            self.focus = i;
            switch (w.kind) {
                .field => |*f| {
                    _ = f.edit.moveTo(@import("applib").lineedit.offsetAtCol(f.edit.text(), 0, col - w.col));
                    return .none;
                },
                else => return self.activate(i),
            }
        }
        return .none;
    }

    /// Focus the first widget that takes it.
    pub fn focusFirst(self: *Form) void {
        for (self.widgets.items, 0..) |*w, i| {
            if (w.focusable()) {
                self.focus = i;
                return;
            }
        }
    }

    fn activate(self: *Form, i: usize) Event {
        const w = &self.widgets.items[i];
        switch (w.kind) {
            .check => |*t| {
                t.on = !t.on;
                return .{ .changed = i };
            },
            .radio => |*t| {
                const group = t.group;
                for (self.widgets.items) |*other| {
                    if (other.kind == .radio and other.kind.radio.group == group) other.kind.radio.on = false;
                }
                w.kind.radio.on = true;
                return .{ .changed = i };
            },
            .button => |b| return .{ .button = b },
            .text, .field => return .none,
        }
    }

    fn focusedKind(self: *const Form) ?Widget.Kind {
        if (self.focus >= self.widgets.items.len) return null;
        return self.widgets.items[self.focus].kind;
    }

    fn firstButton(self: *const Form) ?Button {
        for (self.widgets.items) |w| {
            if (w.kind == .button) return w.kind.button;
        }
        return null;
    }

    fn escapeButton(self: *const Form) ?Button {
        for (self.widgets.items) |w| {
            if (w.kind == .button and w.kind.button.isEscape()) return w.kind.button;
        }
        return null;
    }

    fn cycleFocus(self: *Form, backwards: bool) void {
        const n = self.widgets.items.len;
        if (n == 0) return;
        var i = self.focus;
        for (0..n) |_| {
            i = if (backwards) (i + n - 1) % n else (i + 1) % n;
            if (self.widgets.items[i].focusable()) {
                self.focus = i;
                return;
            }
        }
    }

    const Direction = enum { up, down, left, right };

    /// Focus the nearest focusable widget that way: for up and down the
    /// closest row first, then the closest column; left and right stay
    /// on the row.
    fn moveFocus(self: *Form, dir: Direction) Event {
        if (self.focus >= self.widgets.items.len) return .none;
        const cur = self.widgets.items[self.focus];
        var best: ?usize = null;
        var best_score: usize = std.math.maxInt(usize);
        for (self.widgets.items, 0..) |*w, i| {
            if (i == self.focus or !w.focusable()) continue;
            const score: usize = switch (dir) {
                .down => if (w.row > cur.row) (w.row - cur.row) * 1000 + absDiff(w.col, cur.col) else continue,
                .up => if (w.row < cur.row) (cur.row - w.row) * 1000 + absDiff(w.col, cur.col) else continue,
                .right => if (w.row == cur.row and w.col > cur.col) w.col - cur.col else continue,
                .left => if (w.row == cur.row and w.col < cur.col) cur.col - w.col else continue,
            };
            if (score < best_score) {
                best = i;
                best_score = score;
            }
        }
        if (best) |b| self.focus = b;
        return .none;
    }
};

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}
