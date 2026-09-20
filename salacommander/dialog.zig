// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The modal dialogs salacommander asks its questions in -- "Copy 3 files
//! to: [/home/me/dest]", "Delete 3 files?", "Target exists: Overwrite /
//! Skip / All / None / Cancel" -- as plain state: a title, a message, an
//! optional one-line text field and a row of buttons, one of them
//! focused. `ui.zig` draws a `Dialog` and feeds it keys, text and clicks;
//! whatever the dialog answers comes back as the `Button` pressed. Keeping
//! it windowless is what lets the key handling be tested directly.

const std = @import("std");
const glyphwire = @import("glyphwire");

pub const Button = enum {
    ok,
    cancel,
    yes,
    no,
    overwrite,
    skip,
    overwrite_all,
    skip_all,
    @"continue",
    abort,

    pub fn label(self: Button) []const u8 {
        return switch (self) {
            .ok => "OK",
            .cancel => "Cancel",
            .yes => "Yes",
            .no => "No",
            .overwrite => "Overwrite",
            .skip => "Skip",
            .overwrite_all => "All",
            .skip_all => "None",
            .@"continue" => "Continue",
            .abort => "Abort",
        };
    }

    /// The letter that presses the button in a dialog without a text
    /// field (where letters are typing instead). Underlined when drawn.
    pub fn hotkey(self: Button) u8 {
        return std.ascii.toLower(self.label()[0]);
    }

    /// Whether Escape means this button: the way out of a dialog.
    pub fn isEscape(self: Button) bool {
        return switch (self) {
            .cancel, .no, .abort => true,
            else => false,
        };
    }
};

pub const ok_cancel = [_]Button{ .ok, .cancel };
pub const yes_no = [_]Button{ .yes, .no };
pub const conflict_buttons = [_]Button{ .overwrite, .skip, .overwrite_all, .skip_all, .cancel };
pub const error_buttons = [_]Button{ .@"continue", .abort };
pub const ok_only = [_]Button{.ok};

/// The one-line text field a dialog (and the Alt+D path row) is typed
/// into -- glyphwire's shared `LineEdit`, so a dialog's field has the
/// same Home/Ctrl+A, End/Ctrl+E, word jumps and Ctrl+Backspace the
/// shell prompt does. `.drop` (the default `ControlPolicy`) because a
/// pasted newline in a destination path is a mistake, not a separator.
pub const LineEdit = glyphwire.LineEdit;

pub const Dialog = struct {
    /// Owned.
    title: []u8,
    /// Owned. May hold `\n` to split it over several lines.
    message: []u8,
    input: ?LineEdit = null,
    buttons: []const Button,
    focus: usize = 0,
    /// Drawn in the warning colour (delete confirmations, errors).
    danger: bool = false,

    pub const Options = struct {
        /// Starts a text field holding this.
        input: ?[]const u8 = null,
        danger: bool = false,
        /// Which button starts focused.
        focus: usize = 0,
    };

    pub fn init(alloc: std.mem.Allocator, title: []const u8, message: []const u8, buttons: []const Button, opts: Options) !Dialog {
        const t = try alloc.dupe(u8, title);
        errdefer alloc.free(t);
        const m = try alloc.dupe(u8, message);
        errdefer alloc.free(m);
        return .{
            .title = t,
            .message = m,
            .input = if (opts.input) |initial| try LineEdit.init(alloc, initial) else null,
            .buttons = buttons,
            .focus = @min(opts.focus, buttons.len -| 1),
            .danger = opts.danger,
        };
    }

    pub fn deinit(self: *Dialog, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.message);
        if (self.input) |*i| i.deinit(alloc);
    }

    /// The text field's contents, or "" without one.
    pub fn inputText(self: *const Dialog) []const u8 {
        return if (self.input) |*i| i.text() else "";
    }

    /// A key press. Returns the button it pressed, if any. `key` is a
    /// glyphwire key name.
    pub fn handleKey(self: *Dialog, key: []const u8, mods: glyphwire.Mods) ?Button {
        const eq = std.mem.eql;
        // Enter and Escape are the dialog's before they are the field's:
        // they answer it rather than edit the text, which is why they are
        // tested here instead of being read off `LineEdit.handleKey`'s
        // `.submit` / `.cancel`.
        if (eq(u8, key, "enter") or eq(u8, key, "kp_enter")) return self.buttons[self.focus];
        if (eq(u8, key, "escape")) return self.escapeButton();
        if (eq(u8, key, "tab")) {
            self.cycleFocus(mods.shift);
            return null;
        }

        if (self.input) |*in| {
            _ = in.handleKey(key, mods);
            // Letters are typing (they arrive again as `text`), not
            // button hotkeys.
            return null;
        }

        if (eq(u8, key, "left")) {
            self.cycleFocus(true);
            return null;
        }
        if (eq(u8, key, "right")) {
            self.cycleFocus(false);
            return null;
        }
        if (key.len == 1 and !mods.ctrl) {
            const c = std.ascii.toLower(key[0]);
            for (self.buttons) |b| {
                if (b.hotkey() == c) return b;
            }
        }
        return null;
    }

    /// Committed text: typed into the field, if there is one.
    pub fn handleText(self: *Dialog, alloc: std.mem.Allocator, s: []const u8) !void {
        if (self.input) |*in| _ = try in.insert(alloc, s);
    }

    fn cycleFocus(self: *Dialog, backwards: bool) void {
        const n = self.buttons.len;
        if (n == 0) return;
        self.focus = if (backwards) (self.focus + n - 1) % n else (self.focus + 1) % n;
    }

    fn escapeButton(self: *const Dialog) Button {
        for (self.buttons) |b| {
            if (b.isEscape()) return b;
        }
        return self.buttons[self.buttons.len - 1];
    }
};
