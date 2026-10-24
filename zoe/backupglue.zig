// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's side of the unsaved-change backups: when a buffer's backup is
//! written, put back and thrown away, and the "hot exit" that lets `:q`
//! leave modified buffers behind. The file format and where the files go
//! are `zoe/backup.zig`'s. `Ui` methods moved out of ui.zig and aliased
//! back.
//!
//! The rule is one line: **a modified buffer has a backup no more than
//! `backup.delay_ms` behind it, and a clean one has none.** `syncBackups`
//! enforces it -- on the timer `armBackup` sets, on the way out, and
//! before `:wsopen` swaps the buffers away -- and `:w` deletes the backup
//! the moment the file is written. `:q!` and closing a modified tab with
//! `!` are the two ways to throw unsaved edits away on purpose, so they
//! delete the backup too. Anything else that frees a slot (`:q`, the
//! window closing, `:wsopen`) leaves its backup on disk: that is the
//! backup's whole job.
//!
//! Two kinds of slot are left alone. One with a `pending_backup` is
//! waiting on the user to say what happens to a backup that no longer
//! matches its file (`recoverKey`), and one that is `backup_foreign` is
//! another running zoe's.

const std = @import("std");
const glyphwire = @import("glyphwire");
const backup = @import("backup.zig");

const ui = @import("ui.zig");
const Ui = ui.Ui;
const Slot = ui.Slot;

/// Room for a scope key: a workspace file's path, or every folder's.
const scope_max = 4096;
/// The most folders a scope key is built from; more is a workspace
/// unlike any zoe has been used on, and the key just stops there.
const scope_folders_max = 64;
/// A backup is its buffer plus a header of a few short lines.
const read_limit = ui.max_file_bytes + 2 * std.fs.max_path_bytes;

/// Resolves the backup directory, after the config: none with
/// `backups = false`, which also leaves `:q` refusing modified buffers.
pub fn startBackups(self: *Ui) void {
    const on = if (self.hl_config) |c| c.backups else true;
    if (!on) return;
    self.backup_dir = backup.dirPath(self.alloc, self.environ) catch null;
}

fn selfPid() i32 {
    return std.os.linux.getpid();
}

/// This session's scope key (`backup.scopeKey`), in `buf`.
fn scopeOf(self: *Ui, buf: []u8) []const u8 {
    var folders: [scope_folders_max][]const u8 = undefined;
    const n = @min(self.tree.roots.items.len, folders.len);
    for (self.tree.roots.items[0..n], 0..) |r, i| folders[i] = r.path;
    return backup.scopeKey(buf, self.ws_file, folders[0..n]);
}

/// A fresh untitled id. Only has to differ from the other untitled
/// backups in the directory, so the time, the pid and the slot's
/// address hashed together are plenty.
fn newId(self: *Ui, slot: *const Slot) u64 {
    var h = std.hash.Wyhash.init(0);
    const now = std.Io.Clock.real.now(self.io).nanoseconds;
    h.update(std.mem.asBytes(&now));
    const pid = selfPid();
    h.update(std.mem.asBytes(&pid));
    const addr = @intFromPtr(slot);
    h.update(std.mem.asBytes(&addr));
    return h.final();
}

/// The name `slot`'s backup belongs under now, in `buf`. Null for a
/// buffer whose path can't be made absolute.
fn nameFor(self: *Ui, slot: *Slot, buf: *[backup.name_len]u8) ?[]const u8 {
    if (slot.ed.path != null) {
        const abs = self.slotAbs(slot) orelse return null;
        return backup.fileName(buf, abs);
    }
    if (slot.doc.backup_id == null) slot.doc.backup_id = newId(self, slot);
    var scope_buf: [scope_max]u8 = undefined;
    return backup.untitledName(buf, scopeOf(self, &scope_buf), slot.doc.backup_id.?);
}

fn skipped(slot: *const Slot) bool {
    return slot.doc.pending_backup != null or slot.doc.backup_foreign;
}

/// Writes `slot`'s backup now. A buffer whose name moved since the last
/// write -- `:w <other>` gave it a path, `:addfolder` changed an untitled
/// one's scope -- has the old file deleted once the new one is down.
/// False when nothing could be written.
pub fn writeBackup(self: *Ui, slot: *Slot) bool {
    const dir = self.backup_dir orelse return false;
    var name_buf: [backup.name_len]u8 = undefined;
    const name = nameFor(self, slot, &name_buf) orelse return false;
    const text = slot.ed.buf.text(self.alloc) catch return false;
    defer self.alloc.free(text);

    var scope_buf: [scope_max]u8 = undefined;
    const untitled = slot.ed.path == null;
    const bytes = backup.serialize(self.alloc, .{
        .pid = selfPid(),
        .disk = slot.doc.disk,
        .path = if (untitled) null else self.slotAbs(slot),
        .scope = if (untitled) scopeOf(self, &scope_buf) else null,
    }, text) catch return false;
    defer self.alloc.free(bytes);
    backup.writeFile(self.io, dir, name, bytes) catch return false;

    if (slot.doc.backup_name) |old| {
        if (!std.mem.eql(u8, old, name)) backup.deleteFile(self.alloc, self.io, dir, old);
        self.alloc.free(old);
        slot.doc.backup_name = null;
    }
    slot.doc.backup_name = self.alloc.dupe(u8, name) catch null;
    slot.doc.backup_edits = slot.ed.buf.edits;
    return true;
}

/// Deletes `slot`'s backup: its edits were written (`:w`) or thrown
/// away (`:q!`, a forced close). One still waiting on the user stays.
pub fn dropBackup(self: *Ui, slot: *Slot) void {
    if (slot.doc.pending_backup != null) return;
    const name = slot.doc.backup_name orelse return;
    if (self.backup_dir) |dir| backup.deleteFile(self.alloc, self.io, dir, name);
    self.alloc.free(name);
    slot.doc.backup_name = null;
}

/// Whether `slot`'s backup is out of step with it: a modified buffer
/// with no backup, or one written before its latest edit, or a clean
/// buffer with a backup still on disk.
fn behind(slot: *const Slot) bool {
    if (skipped(slot)) return false;
    if (slot.ed.buf.dirty) return slot.doc.backup_name == null or slot.doc.backup_edits != slot.ed.buf.edits;
    return slot.doc.backup_name != null;
}

/// Brings every slot's backup in line with its buffer. False when a
/// modified buffer's couldn't be written, which the first time is put in
/// the statusline -- not every retry after it.
pub fn syncBackups(self: *Ui) bool {
    if (self.backup_dir == null) return true;
    var ok = true;
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| {
            if (skipped(slot)) continue;
            if (!slot.ed.buf.dirty) {
                dropBackup(self, slot);
                continue;
            }
            // Up to date, unless it now belongs under another name.
            if (!behind(slot)) {
                var name_buf: [backup.name_len]u8 = undefined;
                const name = nameFor(self, slot, &name_buf) orelse continue;
                if (std.mem.eql(u8, name, slot.doc.backup_name.?)) continue;
            }
            if (!writeBackup(self, slot)) ok = false;
        }
    }
    if (!ok and !self.backup_failed) {
        self.buf.ed.setStatus("E: can't write unsaved-change backups to {s}", .{self.backup_dir.?});
        self.status_dirty = true;
    }
    self.backup_failed = !ok;
    return ok;
}

/// Starts the clock on the next `syncBackups` once some buffer has
/// drifted from its backup. Already running, it is left to run out --
/// see `backup.delay_ms` for why this is no debounce.
pub fn armBackup(self: *Ui) void {
    if (self.backup_dir == null or self.timers.armed(.backup)) return;
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| {
            if (!behind(slot)) continue;
            self.timers.armIn(self.io, .backup, backup.delay_ms);
            return;
        }
    }
}

/// Whether `:q` (and `:wq`, `:wsopen`) may leave modified buffers
/// behind. With backups on, once every one of them is safely written;
/// a buffer another zoe holds the backup for has nowhere to go, and is
/// refused the way every modified buffer is with backups off.
pub fn hotExitReady(self: *Ui) bool {
    if (self.backup_dir == null) return !self.refuseQuitForDirtyBuffer();
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| {
            if (!slot.doc.backup_foreign or !slot.ed.buf.dirty) continue;
            self.buf.ed.setStatus(
                "E162: No write since last change for buffer \"{s}\" (another zoe has its backup)",
                .{slot.ed.path orelse "[No Name]"},
            );
            self.status_dirty = true;
            return false;
        }
    }
    if (syncBackups(self)) return true;
    self.buf.ed.setStatus("E: can't back up unsaved changes; :w them, or :q! to throw them away", .{});
    self.status_dirty = true;
    return false;
}

/// `:q!` and `:wsopen!`: every open buffer's unsaved edits are being
/// thrown away, so are their backups.
pub fn discardBackups(self: *Ui) void {
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| dropBackup(self, slot);
    }
}

// ── Putting a backup back ───────────────────────────────────────────────

/// Called on every slot opened over a file (`newSlot`), once its text
/// and disk stamp are in: puts that file's backup back, if it has one.
/// A backup taken against the file as it is now is restored as one undo
/// step over it; one taken against a different version waits on the
/// user (`recoverKey`).
pub fn restoreBackup(self: *Ui, slot: *Slot) void {
    const dir = self.backup_dir orelse return;
    const abs = self.slotAbs(slot) orelse return;
    var name_buf: [backup.name_len]u8 = undefined;
    const name = backup.fileName(&name_buf, abs);
    const bytes = backup.readFile(self.alloc, self.io, dir, name, read_limit) orelse return;
    defer self.alloc.free(bytes);
    const parsed = backup.parse(bytes) orelse return;
    // Another path with the same hash: not this file's backup.
    if (!std.mem.eql(u8, parsed.header.path orelse return, abs)) return;

    const shown = slot.ed.path.?;
    if (backup.ownerAlive(self.io, parsed.header.pid, selfPid())) {
        slot.doc.backup_foreign = true;
        slot.ed.setStatus("\"{s}\": another zoe (pid {d}) has unsaved changes to it", .{ shown, parsed.header.pid });
        return;
    }
    slot.doc.backup_name = self.alloc.dupe(u8, name) catch return;
    switch (backup.decide(parsed.header.disk, slot.doc.disk)) {
        .restore => {
            slot.ed.replaceAllText(parsed.text) catch return;
            // Rewritten at the next sync, so the file names this zoe as
            // its owner rather than the one that wrote it.
            slot.doc.backup_edits = slot.ed.buf.edits -% 1;
            if (slot.ed.buf.dirty) {
                slot.ed.setStatus("\"{s}\" {d}L, unsaved changes restored (u undoes)", .{ shown, slot.ed.buf.lineCount() });
            }
        },
        .ask => {
            slot.doc.pending_backup = self.alloc.dupe(u8, parsed.text) catch return;
            askRecover(slot);
        },
    }
}

/// The question a `pending_backup` puts in the statusline.
pub fn askRecover(slot: *Slot) void {
    slot.ed.setStatus(
        "\"{s}\" changed since its backup: r recover the backup, d discard it, s open it in a split",
        .{slot.ed.path orelse "[No Name]"},
    );
}

/// Whether keys go to `recoverKey`: the focused buffer is waiting on
/// what to do with its backup.
pub fn recoverPending(self: *const Ui) bool {
    return self.focus == .buffer and self.buf.doc.pending_backup != null;
}

/// The answer to `askRecover`. `r` puts the backup's text in the buffer
/// (one undo step over the file on disk), `d` deletes it, and `s` opens
/// it as an untitled buffer in a split beside the file -- the backup
/// then belongs to that buffer. Any other key asks again: nothing else
/// happens to this buffer until it is answered.
pub fn recoverKey(self: *Ui, k: glyphwire.KeyEvent) !void {
    const slot = self.buf;
    self.status_dirty = true;
    // The same key comes again as `text`, which must not reach the
    // editor once the question is gone.
    if (!k.ctrl() and k.key.len == 1) self.swallow_text = .any;
    const answer: u8 = if (k.ctrl() or k.alt() or k.key.len != 1) 0 else k.key[0];
    switch (answer) {
        'r' => {
            const text = slot.doc.pending_backup.?;
            defer self.alloc.free(text);
            slot.doc.pending_backup = null;
            slot.ed.replaceAllText(text) catch {};
            slot.doc.backup_edits = slot.ed.buf.edits -% 1;
            slot.ed.setStatus("\"{s}\" unsaved changes recovered (u undoes)", .{slot.ed.path orelse "[No Name]"});
        },
        'd' => {
            self.alloc.free(slot.doc.pending_backup.?);
            slot.doc.pending_backup = null;
            dropBackup(self, slot);
            slot.ed.setStatus("backup discarded", .{});
        },
        's' => {
            const fresh = try self.newSlot(null);
            errdefer fresh.deinit(self.alloc);
            try fresh.ed.replaceAllText(slot.doc.pending_backup.?);
            // Down on disk under its own name before the file's goes.
            if (!writeBackup(self, fresh)) {
                fresh.deinit(self.alloc);
                slot.ed.setStatus("E: can't write unsaved-change backups to {s}", .{self.backup_dir orelse ""});
                return;
            }
            self.alloc.free(slot.doc.pending_backup.?);
            slot.doc.pending_backup = null;
            dropBackup(self, slot);

            const g = try self.insertGroup(self.grp, .vertical, .after);
            try g.buffers.append(self.alloc, fresh);
            self.focusGroup(g);
            for (self.group_list.items) |each| each.markRedraw();
            fresh.ed.setStatus("the backup of \"{s}\"; the file as it is on disk is beside it", .{slot.ed.path orelse "[No Name]"});
        },
        else => askRecover(slot),
    }
    slot.full_redraw = true;
    self.grp.buffer_dirty = true;
    self.grp.tabs_dirty = true;
}

/// The slot whose backup is `name`, if one is open.
fn slotWithBackup(self: *const Ui, name: []const u8) ?*Slot {
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| {
            const n = slot.doc.backup_name orelse continue;
            if (std.mem.eql(u8, n, name)) return slot;
        }
    }
    return null;
}

/// Opens untitled backup `name` as a tab in the focused group, in place
/// of a lone pristine scratch tab. False when it couldn't be read, or
/// another running zoe has it open.
fn openUntitled(self: *Ui, name: []const u8) !bool {
    const dir = self.backup_dir orelse return false;
    const id = backup.untitledId(name) orelse return false;
    const bytes = backup.readFile(self.alloc, self.io, dir, name, read_limit) orelse return false;
    defer self.alloc.free(bytes);
    const parsed = backup.parse(bytes) orelse return false;
    if (backup.ownerAlive(self.io, parsed.header.pid, selfPid())) return false;

    const slot = try self.newSlot(null);
    errdefer slot.deinit(self.alloc);
    try slot.ed.replaceAllText(parsed.text);
    slot.doc.backup_id = id;
    slot.doc.backup_name = try self.alloc.dupe(u8, name);
    // Rewritten at the next sync: under this zoe's pid, and under this
    // session's scope when `:recover` brought it in from another.
    slot.doc.backup_edits = slot.ed.buf.edits -% 1;

    const g = self.grp;
    if (g.buffers.items.len == 1 and Ui.isPristineScratch(g.buffers.items[0])) {
        const scratch = g.buffers.items[0];
        g.buffers.items[0] = slot;
        scratch.deinit(self.alloc);
        self.setActive(0);
    } else {
        try g.buffers.append(self.alloc, slot);
    }
    return true;
}

/// At startup and after `:wsopen`: the untitled buffers this session's
/// scope left behind come back as tabs in the focused group.
pub fn restoreUntitled(self: *Ui) void {
    const dir = self.backup_dir orelse return;
    var scope_buf: [scope_max]u8 = undefined;
    var prefix_buf: [backup.name_len]u8 = undefined;
    const prefix = backup.untitledPrefix(&prefix_buf, scopeOf(self, &scope_buf));
    const names = backup.list(self.alloc, self.io, dir) catch return;
    defer backup.freeNames(self.alloc, names);
    std.mem.sort([]u8, names, {}, lessName);

    var restored: usize = 0;
    for (names) |name| {
        if (!std.mem.startsWith(u8, name, prefix) or slotWithBackup(self, name) != null) continue;
        if (openUntitled(self, name) catch false) restored += 1;
    }
    if (restored > 0) {
        self.buf.ed.setStatus("{d} untitled buffer{s} restored from backup", .{ restored, if (restored == 1) "" else "s" });
        self.grp.tabs_dirty = true;
        self.status_dirty = true;
    }
}

fn lessName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `:recover`: every backup no open buffer has -- a file's opens that
/// file (and so goes through `restoreBackup`), an untitled one opens as
/// a tab whatever session it was typed in. Another running zoe's are
/// left to it.
pub fn recoverAll(self: *Ui) !void {
    self.status_dirty = true;
    const dir = self.backup_dir orelse {
        self.buf.ed.setStatus("backups are off (backups = false in zoe.conf.lua)", .{});
        return;
    };
    const names = try backup.list(self.alloc, self.io, dir);
    defer backup.freeNames(self.alloc, names);
    std.mem.sort([]u8, names, {}, lessName);

    var opened: usize = 0;
    for (names) |name| {
        if (slotWithBackup(self, name) != null) continue;
        if (std.mem.startsWith(u8, name, backup.untitled_prefix)) {
            if (try openUntitled(self, name)) opened += 1;
            continue;
        }
        const bytes = backup.readFile(self.alloc, self.io, dir, name, read_limit) orelse continue;
        defer self.alloc.free(bytes);
        const parsed = backup.parse(bytes) orelse continue;
        const path = parsed.header.path orelse continue;
        if (backup.ownerAlive(self.io, parsed.header.pid, selfPid())) continue;
        if (self.findPath(path) != null) continue;
        try self.openFile(path);
        opened += 1;
    }
    if (opened == 0) {
        self.buf.ed.setStatus("No backups to recover", .{});
    } else {
        self.buf.ed.setStatus("{d} backup{s} opened", .{ opened, if (opened == 1) "" else "s" });
    }
    self.grp.tabs_dirty = true;
}
