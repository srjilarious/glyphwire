// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! F1 and what it leads to: the file operations menu, the chmod dialog
//! and the chown dialog. Windowless state like `dialog.zig`'s; `ui.zig`
//! draws them and runs them modally.
//!
//! The menu is a keymap (`actions.menu_defaults`, `menu_keys`): each
//! unmodified chord is a line, and a pick made with modifiers held is
//! that chord's key looked up again with them, so `super+m` (or Super
//! held over Enter or a click on "Change mode") is chmod as root. The
//! lines read what a pick would do right now, so they change as the
//! modifiers go down and up.

const std = @import("std");
const glyphwire = @import("glyphwire");
const actions = @import("actions.zig");
const attrs = @import("attrs.zig");
const form_mod = @import("form.zig");

const Action = actions.Action;
const Form = form_mod.Form;
const Event = form_mod.Event;

// ── F1 menu ─────────────────────────────────────────────────────────────

pub const Menu = struct {
    keymap: *const actions.Keymap,
    entries_buf: [16]Action = undefined,
    entries: []Action = &.{},
    focus: usize = 0,

    pub const Pick = union(enum) { run: Action, cancel };

    pub fn init(keymap: *const actions.Keymap) Menu {
        return .{ .keymap = keymap };
    }

    /// Call once the menu is at its final address: `entries` points into
    /// it.
    pub fn load(self: *Menu) void {
        self.entries = actions.menuEntries(self.keymap, &self.entries_buf);
    }

    /// What picking line `i` runs with `held` down.
    pub fn shown(self: *const Menu, i: usize, held: glyphwire.Mods) Action {
        return actions.menuPick(self.keymap, self.entries[i], held);
    }

    /// Whether a pick right now would run something as root.
    pub fn asRoot(self: *const Menu, held: glyphwire.Mods) bool {
        if (self.entries.len == 0) return false;
        return actions.isRoot(self.shown(self.focus, held));
    }

    pub fn handleKey(self: *Menu, key: []const u8, mods: glyphwire.Mods) ?Pick {
        const eq = std.mem.eql;
        if (eq(u8, key, "escape")) return .cancel;
        if (self.entries.len == 0) return null;
        if (eq(u8, key, "up")) {
            self.focus = (self.focus + self.entries.len - 1) % self.entries.len;
            return null;
        }
        if (eq(u8, key, "down")) {
            self.focus = (self.focus + 1) % self.entries.len;
            return null;
        }
        if (eq(u8, key, "enter") or eq(u8, key, "kp_enter")) return .{ .run = self.shown(self.focus, mods) };
        if (self.keymap.lookup(key, mods)) |a| return .{ .run = a };
        return null;
    }

    /// A click on line `i`, with the modifiers the click carried.
    pub fn click(self: *Menu, i: usize, mods: glyphwire.Mods) ?Pick {
        if (i >= self.entries.len) return null;
        self.focus = i;
        return .{ .run = self.shown(i, mods) };
    }
};

// ── Shared parts ────────────────────────────────────────────────────────

/// Both dialogs are this wide: the filter's radio buttons need it.
pub const form_width = 54;

pub const Answer = enum { set, cancel };

/// The recursive checkbox and the filter's radio buttons, at `row` and
/// the one below it.
const Scope = struct {
    recursive: usize,
    radios: [3]usize,

    fn add(f: *Form, alloc: std.mem.Allocator, row: usize) !Scope {
        var s: Scope = undefined;
        s.recursive = try f.addCheck(alloc, row, 2, "Recursive (into directories)", false);
        var col: usize = 2;
        for (std.enums.values(attrs.Filter), 0..) |choice, i| {
            s.radios[i] = try f.addRadio(alloc, row + 1, col, 1, choice.label(), choice == .all);
            col += 4 + choice.label().len + 2;
        }
        return s;
    }

    fn filter(self: Scope, f: *const Form) attrs.Filter {
        for (self.radios, 0..) |r, i| {
            if (f.isOn(r)) return std.enums.values(attrs.Filter)[i];
        }
        return .all;
    }
};

/// "sudo " in front for a change run as root, as the other sudo dialogs
/// have it (`ui.titleFor`).
fn titleText(buf: []u8, title: []const u8, as_root: bool) []const u8 {
    if (!as_root) return title;
    return std.fmt.bufPrint(buf, "sudo {s}", .{title}) catch title;
}

// ── chmod ───────────────────────────────────────────────────────────────

/// Twelve toggles in a grid (owner/group/others by read/write/exec, then
/// setuid/setgid/sticky) and the octal value they make, kept in step
/// both ways: a toggle rewrites the field, and a field that reads as
/// octal sets the toggles.
pub const ModeForm = struct {
    form: Form,
    bits: [12]usize,
    octal: usize,
    /// Only with a directory selected: for files alone the filter can't
    /// change anything.
    scope: ?Scope,
    mode: u12,

    pub fn init(alloc: std.mem.Allocator, what: []const u8, mode: u12, has_dir: bool, as_root: bool) !ModeForm {
        var tbuf: [64]u8 = undefined;
        var f = try Form.init(alloc, titleText(&tbuf, "Change mode", as_root));
        errdefer f.deinit(alloc);
        f.danger = as_root;
        f.w = form_width;

        _ = try f.addText(alloc, 2, 2, what);
        const cols = [3]usize{ 15, 22, 29 };
        _ = try f.addText(alloc, 4, cols[0] - 1, "Read");
        _ = try f.addText(alloc, 4, cols[1] - 1, "Write");
        _ = try f.addText(alloc, 4, cols[2] - 1, "Exec");
        var self: ModeForm = .{ .form = undefined, .bits = undefined, .octal = 0, .scope = null, .mode = mode };
        const rows = [3][]const u8{ "Owner", "Group", "Others" };
        for (rows, 0..) |name, r| {
            _ = try f.addText(alloc, 5 + r, 2, name);
            for (cols, 0..) |c, k| {
                const i = r * 3 + k;
                self.bits[i] = try f.addCheck(alloc, 5 + r, c, "", mode & attrs.mode_bits[i] != 0);
            }
        }
        _ = try f.addText(alloc, 9, 2, "Special");
        const special = [3][]const u8{ "setuid", "setgid", "sticky" };
        for (special, 0..) |name, k| {
            self.bits[9 + k] = try f.addCheck(alloc, 9, 14 + k * 13, name, mode & attrs.mode_bits[9 + k] != 0);
        }
        _ = try f.addText(alloc, 11, 2, "Octal");
        var obuf: [4]u8 = undefined;
        self.octal = try f.addField(alloc, 11, 14, 6, attrs.formatOctal(&obuf, mode));

        var row: usize = 13;
        if (has_dir) {
            self.scope = try Scope.add(&f, alloc, row);
            row += 3;
        }
        f.error_row = row;
        try f.addButtons(alloc, row + 1, &form_mod.set_cancel_buttons);
        f.h = row + 3;
        f.focus = self.octal;
        _ = f.field(self.octal).end();
        self.form = f;
        return self;
    }

    pub fn deinit(self: *ModeForm, alloc: std.mem.Allocator) void {
        self.form.deinit(alloc);
    }

    pub fn recursive(self: *const ModeForm) bool {
        const s = self.scope orelse return false;
        return self.form.isOn(s.recursive);
    }

    pub fn filter(self: *const ModeForm) attrs.Filter {
        const s = self.scope orelse return .all;
        return s.filter(&self.form);
    }

    pub fn handleKey(self: *ModeForm, alloc: std.mem.Allocator, key: []const u8, mods: glyphwire.Mods) !?Answer {
        return self.react(alloc, self.form.handleKey(key, mods));
    }

    pub fn handleText(self: *ModeForm, alloc: std.mem.Allocator, s: []const u8) !?Answer {
        return self.react(alloc, try self.form.handleText(alloc, s));
    }

    pub fn click(self: *ModeForm, alloc: std.mem.Allocator, row: usize, col: usize) !?Answer {
        return self.react(alloc, self.form.click(row, col));
    }

    fn react(self: *ModeForm, alloc: std.mem.Allocator, ev: Event) !?Answer {
        switch (ev) {
            .none => return null,
            .button => |b| {
                if (b != .set) return .cancel;
                if (attrs.parseOctal(self.form.field(self.octal).text()) == null) {
                    self.form.err = bad_octal;
                    return null;
                }
                return .set;
            },
            .changed => |i| {
                if (i == self.octal) {
                    const v = attrs.parseOctal(self.form.field(i).text()) orelse {
                        self.form.err = bad_octal;
                        return null;
                    };
                    self.form.err = null;
                    self.mode = v;
                    for (self.bits, attrs.mode_bits) |w, bit| self.form.setOn(w, v & bit != 0);
                    return null;
                }
                for (self.bits, attrs.mode_bits) |w, bit| {
                    if (w != i) continue;
                    if (self.form.isOn(w)) self.mode |= bit else self.mode &= ~bit;
                    var obuf: [4]u8 = undefined;
                    try self.form.field(self.octal).setText(alloc, attrs.formatOctal(&obuf, self.mode));
                    self.form.err = null;
                }
                return null;
            },
        }
    }

    const bad_octal = "Octal mode is 1 to 4 digits, 0 to 7";
};

// ── chown ───────────────────────────────────────────────────────────────

/// Two fields, owner and group, by name or id. Empty leaves that one as
/// it is. Names are looked up when Set is pressed, so a typo is said in
/// the dialog instead of failing on every file.
pub const OwnerForm = struct {
    form: Form,
    user: usize,
    group: usize,
    scope: ?Scope,
    /// Set once `handleKey` & co. answer `.set`.
    owner: attrs.Owner = .{},
    err_buf: [96]u8 = undefined,

    pub fn init(alloc: std.mem.Allocator, what: []const u8, user: []const u8, group: []const u8, has_dir: bool, as_root: bool) !OwnerForm {
        var tbuf: [64]u8 = undefined;
        var f = try Form.init(alloc, titleText(&tbuf, "Change owner/group", as_root));
        errdefer f.deinit(alloc);
        f.danger = as_root;
        f.w = form_width;

        _ = try f.addText(alloc, 2, 2, what);
        _ = try f.addText(alloc, 4, 2, "Owner");
        const u = try f.addField(alloc, 4, 10, 32, user);
        _ = try f.addText(alloc, 6, 2, "Group");
        const g = try f.addField(alloc, 6, 10, 32, group);
        _ = try f.addText(alloc, 7, 10, "Names or numeric ids; empty leaves it as is");

        var row: usize = 9;
        var scope: ?Scope = null;
        if (has_dir) {
            scope = try Scope.add(&f, alloc, row);
            row += 3;
        }
        f.error_row = row;
        try f.addButtons(alloc, row + 1, &form_mod.set_cancel_buttons);
        f.h = row + 3;
        f.focus = u;
        _ = f.field(u).end();
        return .{ .form = f, .user = u, .group = g, .scope = scope };
    }

    pub fn deinit(self: *OwnerForm, alloc: std.mem.Allocator) void {
        self.form.deinit(alloc);
    }

    pub fn recursive(self: *const OwnerForm) bool {
        const s = self.scope orelse return false;
        return self.form.isOn(s.recursive);
    }

    pub fn filter(self: *const OwnerForm) attrs.Filter {
        const s = self.scope orelse return .all;
        return s.filter(&self.form);
    }

    pub fn handleKey(self: *OwnerForm, _: std.mem.Allocator, key: []const u8, mods: glyphwire.Mods) !?Answer {
        return self.react(self.form.handleKey(key, mods));
    }

    pub fn handleText(self: *OwnerForm, alloc: std.mem.Allocator, s: []const u8) !?Answer {
        return self.react(try self.form.handleText(alloc, s));
    }

    pub fn click(self: *OwnerForm, _: std.mem.Allocator, row: usize, col: usize) !?Answer {
        return self.react(self.form.click(row, col));
    }

    fn react(self: *OwnerForm, ev: Event) ?Answer {
        switch (ev) {
            .none => return null,
            .changed => {
                self.form.err = null;
                return null;
            },
            .button => |b| {
                if (b != .set) return .cancel;
                const user_text = self.form.field(self.user).text();
                const group_text = self.form.field(self.group).text();
                const uid = attrs.parseUser(user_text) catch {
                    self.form.err = std.fmt.bufPrint(&self.err_buf, "No user named \"{s}\"", .{trimmed(user_text)}) catch "No such user";
                    return null;
                };
                const gid = attrs.parseGroup(group_text) catch {
                    self.form.err = std.fmt.bufPrint(&self.err_buf, "No group named \"{s}\"", .{trimmed(group_text)}) catch "No such group";
                    return null;
                };
                if (uid == null and gid == null) {
                    self.form.err = "Nothing to change: both fields are empty";
                    return null;
                }
                self.owner = .{ .uid = uid, .gid = gid };
                return .set;
            },
        }
    }
};

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " ");
}
