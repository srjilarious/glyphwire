// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-shell's persistent state: loading, writing and flushing the
//! command history and the zjump directory database. `Prompt` methods
//! moved out of main.zig and aliased back.

const std = @import("std");
const history = @import("applib").history;
const zjump = @import("applib").zjump;

const main = @import("main.zig");
const Prompt = main.Prompt;

/// Loads `~/.config/glyphwire/history` into `self.history` so Up-arrow
/// recall picks up where the last session left off, then records the
/// file path in `self.history_path` and rewrites the file once
/// (trimmed to the last `history.max_entries`, consecutive duplicates
/// dropped) so it stays bounded. Creates the config directory if it's
/// missing. Any IO failure just leaves `history_path` null -- the
/// session runs with in-memory-only history rather than failing.
///
/// `self.history` is a startup *snapshot*: lines another shell adds to
/// the file afterwards don't appear in this session's recall. That's
/// deliberate -- what must not happen is this session writing its
/// snapshot back over them, which is why flushes append
/// `history_pending` to a re-read file instead (`writeHistoryFile`).
///
/// Setting `$GLYPHWIRE_NO_HISTORY` (to any non-empty value) skips all
/// of this: no file is read or written and `history_path` stays null,
/// so recall works within the session but nothing is persisted. The
/// e2e tests set it so driving the real shell binary doesn't touch
/// the developer's own history file.
pub fn loadHistory(self: *Prompt, config_dir: []const u8) !void {
    const alloc = self.client.alloc;
    const io = self.client.io;

    if (self.environ_map.get("GLYPHWIRE_NO_HISTORY")) |v| {
        if (v.len > 0) return;
    }

    std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
        std.log.warn("history: could not create {s}: {t}", .{ config_dir, err });
        return;
    };

    const path = try std.fs.path.join(alloc, &.{ config_dir, "history" });
    errdefer alloc.free(path);

    if (std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20))) |bytes| {
        defer alloc.free(bytes);
        const entries = try history.parse(alloc, bytes);
        defer history.freeEntries(alloc, entries);
        for (entries) |e| try self.history.append(alloc, try alloc.dupe(u8, e));
    } else |err| switch (err) {
        error.FileNotFound => {}, // first run -- nothing to load
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.log.warn("history: could not read {s}: {t}", .{ path, err });
            alloc.free(path);
            return;
        },
    }

    self.history_path = path;
    // Rewrite once now so a file that was over the cap / had
    // consecutive dupes is trimmed on disk even for a session that
    // never adds a line.
    self.writeHistoryFile();
}

/// Loads `~/.config/glyphwire/z.db` for the `zj` builtin. A missing
/// file just yields an empty in-memory database, so `zj` still
/// records visits this session; the file is created on the first
/// flush. `$GLYPHWIRE_NO_HISTORY` opts out completely (no read, no
/// path stored, no write), the same lever the e2e tests use to keep
/// off the developer's real files. Any IO or parse failure leaves a
/// memory-only database with no path.
pub fn loadZjump(self: *Prompt, config_dir: []const u8) !void {
    const alloc = self.client.alloc;
    const io = self.client.io;

    if (self.environ_map.get("GLYPHWIRE_NO_HISTORY")) |v| {
        if (v.len > 0) {
            // Memory-only: no journal either, since nothing will ever
            // replay it onto a file.
            self.zdb = zjump.Db.init(alloc);
            return;
        }
    }

    const path = try std.fs.path.join(alloc, &.{ config_dir, "z.db" });
    errdefer alloc.free(path);

    var db: zjump.Db = undefined;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20))) |bytes| {
        defer alloc.free(bytes);
        db = try zjump.Db.parse(alloc, bytes);
    } else |err| switch (err) {
        error.FileNotFound => db = zjump.Db.init(alloc),
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.log.warn("zj: could not read {s}: {t}", .{ path, err });
            db = zjump.Db.init(alloc);
        },
    }

    self.zdb = db;
    self.zdb_path = path;
    self.zdb_journal = zjump.Journal.init(alloc);
}

/// Re-reads the history file and writes it back with
/// `history_pending` -- this session's lines since the last flush --
/// appended, trimmed to the last `history.max_entries`. History is
/// kept in memory and this is called lazily (see
/// `flushPersistentState` / `persist_gate`), plus unconditionally on
/// a clean exit and the host `shutdown`. A no-op when there's no
/// `history_path`; an IO failure is logged, not propagated.
///
/// The re-read is what makes several shells in one `gmux` session
/// share the file: writing `self.history` back instead would carry
/// this session's startup snapshot with it and revert everything
/// another shell had added in the meantime. `history_pending` is
/// cleared only once the write succeeds, so a failed flush still has
/// its lines to try again with.
pub fn writeHistoryFile(self: *Prompt) void {
    const path = self.history_path orelse return;
    const alloc = self.client.alloc;
    const io = self.client.io;

    const on_disk: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => null, // another shell hasn't created it either
        else => {
            std.log.warn("history: could not re-read {s}: {t}", .{ path, err });
            return;
        },
    };
    defer if (on_disk) |b| alloc.free(b);

    const bytes = history.mergeSerialize(alloc, on_disk orelse "", self.history_pending.items) catch return;
    defer alloc.free(bytes);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
        std.log.warn("history: could not write {s}: {t}", .{ path, err });
        return;
    };
    self.clearHistoryPending();
}

/// Drops every line in `history_pending` -- called once a flush has
/// actually written them.
pub fn clearHistoryPending(self: *Prompt) void {
    const alloc = self.client.alloc;
    for (self.history_pending.items) |line| alloc.free(line);
    self.history_pending.clearRetainingCapacity();
}

/// Re-reads `~/.config/glyphwire/z.db`, replays `zdb_journal` -- this
/// session's visits and prunes since the last flush -- onto it, and
/// writes the merged result back. Same lazy / forced flush cadence as
/// `writeHistoryFile`, and the same reason for the re-read: several
/// shells share this file, and writing `self.zdb` straight back would
/// revert the others' visits (see `zjump.Journal`). A no-op without a
/// `zdb_path`, database or journal; IO failures are logged.
pub fn writeZdbFile(self: *Prompt) void {
    const path = self.zdb_path orelse return;
    const journal = if (self.zdb_journal) |*j| j else return;
    const alloc = self.client.alloc;
    const io = self.client.io;

    var merged: zjump.Db = blk: {
        const on_disk = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch |err| switch (err) {
            error.FileNotFound => break :blk zjump.Db.init(alloc),
            else => {
                std.log.warn("zj: could not re-read {s}: {t}", .{ path, err });
                return;
            },
        };
        defer alloc.free(on_disk);
        // A file another shell left half-written parses as "whatever
        // lines were intact" (see `Db.parse`), which is the right
        // failure mode here: this session's deltas still land.
        break :blk zjump.Db.parse(alloc, on_disk) catch zjump.Db.init(alloc);
    };
    defer merged.deinit();

    merged.applyJournal(journal) catch return;

    const bytes = merged.serialize(alloc) catch return;
    defer alloc.free(bytes);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
        std.log.warn("zj: could not write {s}: {t}", .{ path, err });
        return;
    };
    journal.clear();
}

pub const FlushMode = enum { due, force };

/// Writes history and/or `z.db`. `.force` writes both regardless of
/// the dirty flags (the clean-exit / `shutdown` path); `.due` writes
/// only what actually changed. Either way the dirty flags clear and
/// the gate's clock restarts. IO failures are swallowed (logged in
/// the write helpers), never propagated.
///
/// Both writes are read-modify-write merges against the file as it
/// stands (`writeHistoryFile` / `writeZdbFile`), so a flush is safe
/// to repeat and safe to interleave with another shell's -- a forced
/// flush with nothing pending just rewrites equivalent content.
pub fn flushPersistentState(self: *Prompt, mode: FlushMode) void {
    const force = mode == .force;
    if (self.history_dirty or force) {
        self.writeHistoryFile();
        self.history_dirty = false;
    }
    if (self.zdb_dirty or force) {
        self.writeZdbFile();
        self.zdb_dirty = false;
    }
    self.persist_gate.reset(self.nowMillis());
}

/// Flushes only when the gate says it is due (enough un-flushed
/// changes, or enough elapsed time). Called at idle ticks and after
/// each submitted line.
pub fn maybeFlushPersistentState(self: *Prompt) void {
    if (self.persist_gate.shouldFlush(self.nowMillis())) self.flushPersistentState(.due);
}
