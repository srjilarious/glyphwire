// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The file operations behind F5/F6/F7/F8: copy, move, make directory and
//! delete, run synchronously over absolute paths.
//!
//! No UI lives here. Whatever needs a person -- "the target exists,
//! overwrite it?", "this one failed, carry on?", "how far along are we?"
//! -- goes out through `Hooks`, so the same `Operation` runs under the
//! modal dialogs in `ui.zig`, under a test that answers every question
//! from a script, or (later) on a worker thread that forwards the
//! questions to the UI.
//!
//! Destination rules follow Midnight Commander: when `dest` is an existing
//! directory every source lands inside it under its own name; otherwise a
//! single source is copied/moved *to* `dest` (which is how F6 renames), and
//! several sources with a non-directory `dest` is an error.

const std = @import("std");

pub const Kind = enum {
    copy,
    move,
    delete,

    /// The verb for dialogs and progress lines: "Copy", "Move", "Delete".
    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .copy => "Copy",
            .move => "Move",
            .delete => "Delete",
        };
    }
};

/// What to do about a destination that already exists.
pub const Conflict = enum {
    overwrite,
    skip,
    /// Overwrite this one and every later conflict without asking.
    overwrite_all,
    /// Skip this one and every later conflict without asking.
    skip_all,
    /// Stop the whole operation here.
    cancel,
};

pub const Hooks = struct {
    ctx: *anyopaque,
    /// `dest` exists and `src` would replace it.
    onConflict: *const fn (ctx: *anyopaque, src: []const u8, dest: []const u8) Conflict,
    /// About to start top-level source `index` of `total`.
    onProgress: *const fn (ctx: *anyopaque, kind: Kind, index: usize, total: usize, path: []const u8) void,
    /// `path` failed with `err`. Return true to carry on with the rest,
    /// false to stop.
    onError: *const fn (ctx: *anyopaque, path: []const u8, err: anyerror) bool,
};

/// Hooks that never ask: conflicts are skipped, errors are skipped and
/// counted, progress goes nowhere. For tests and for callers that want a
/// best-effort run.
pub const quiet_hooks: Hooks = .{
    .ctx = @ptrCast(@constCast(&quiet_ctx)),
    .onConflict = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) Conflict {
            return .skip;
        }
    }.f,
    .onProgress = struct {
        fn f(_: *anyopaque, _: Kind, _: usize, _: usize, _: []const u8) void {}
    }.f,
    .onError = struct {
        fn f(_: *anyopaque, _: []const u8, _: anyerror) bool {
            return true;
        }
    }.f,
};
const quiet_ctx: u8 = 0;

pub const Result = struct {
    /// Files, links and directories copied, moved or deleted -- counted per
    /// item actually written or removed, not per top-level source.
    done: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    cancelled: bool = false,
    /// The first error seen, for a one-line summary.
    first_error: ?anyerror = null,
};

pub const Error = error{
    /// Several sources, and `dest` isn't a directory to put them in.
    DestNotDirectory,
    /// A directory copied or moved into itself or one of its own
    /// subdirectories.
    DestInsideSource,
};

pub const Operation = struct {
    kind: Kind,
    /// Absolute paths. Borrowed.
    sources: []const []const u8,
    /// Absolute path; ignored for `.delete`. Borrowed.
    dest: []const u8 = "",

    pub fn run(self: Operation, io: std.Io, alloc: std.mem.Allocator, hooks: Hooks) Result {
        var runner: Runner = .{ .io = io, .alloc = alloc, .hooks = hooks };
        runner.runAll(self);
        return runner.result;
    }
};

/// Creates `path` (absolute) and any missing parents, the way MC's F7
/// accepts `a/b/c`. An existing directory is `error.PathAlreadyExists`,
/// so the dialog can say so rather than silently doing nothing.
pub fn makeDir(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.statFile(io, path, .{ .follow_symlinks = false })) |_| {
        return error.PathAlreadyExists;
    } else |_| {}
    try cwd.createDirPath(io, path);
}

/// Where `src` lands when copied or moved to `dest`, per the MC rules in
/// the module doc. Caller owns the result.
pub fn targetPath(io: std.Io, alloc: std.mem.Allocator, src: []const u8, dest: []const u8, source_count: usize) ![]u8 {
    if (isDirectory(io, dest)) return std.fs.path.join(alloc, &.{ dest, std.fs.path.basename(src) });
    if (source_count > 1) return error.DestNotDirectory;
    return alloc.dupe(u8, dest);
}

/// True when `child` is `parent` itself or somewhere beneath it. Both are
/// absolute and normalized; the check is on whole path components, so
/// `/a/bc` is not inside `/a/b`.
pub fn isWithin(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len > 0 and parent[parent.len - 1] == '/') return true;
    return child[parent.len] == '/';
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

const Policy = enum { ask, overwrite_all, skip_all };

const Runner = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    hooks: Hooks,
    result: Result = .{},
    policy: Policy = .ask,

    const Stop = error{Cancelled};

    fn runAll(self: *Runner, op: Operation) void {
        for (op.sources, 0..) |src, i| {
            self.hooks.onProgress(self.hooks.ctx, op.kind, i, op.sources.len, src);
            const outcome = switch (op.kind) {
                .delete => self.deleteOne(src),
                .copy, .move => self.transferOne(op, src),
            };
            outcome catch {
                self.result.cancelled = true;
                return;
            };
        }
    }

    /// Records a failure and asks whether to go on. `Stop` means no.
    fn fail(self: *Runner, path: []const u8, err: anyerror) Stop!void {
        self.result.failed += 1;
        if (self.result.first_error == null) self.result.first_error = err;
        if (!self.hooks.onError(self.hooks.ctx, path, err)) return error.Cancelled;
    }

    fn deleteOne(self: *Runner, path: []const u8) Stop!void {
        std.Io.Dir.cwd().deleteTree(self.io, path) catch |err| return self.fail(path, err);
        self.result.done += 1;
    }

    fn transferOne(self: *Runner, op: Operation, src: []const u8) Stop!void {
        const dest = targetPath(self.io, self.alloc, src, op.dest, op.sources.len) catch |err| return self.fail(src, err);
        defer self.alloc.free(dest);

        if (std.mem.eql(u8, src, dest)) return self.fail(src, error.PathAlreadyExists);
        if (isDirectory(self.io, src) and isWithin(dest, src)) return self.fail(src, Error.DestInsideSource);

        switch (op.kind) {
            .copy => try self.copyTree(src, dest),
            .move => try self.moveTree(src, dest),
            .delete => unreachable,
        }
    }

    /// Asks (or applies a standing answer) whether `dest` may be replaced.
    /// True means go ahead.
    fn resolveConflict(self: *Runner, src: []const u8, dest: []const u8) Stop!bool {
        switch (self.policy) {
            .overwrite_all => return true,
            .skip_all => {
                self.result.skipped += 1;
                return false;
            },
            .ask => {},
        }
        switch (self.hooks.onConflict(self.hooks.ctx, src, dest)) {
            .overwrite => return true,
            .overwrite_all => {
                self.policy = .overwrite_all;
                return true;
            },
            .skip => {
                self.result.skipped += 1;
                return false;
            },
            .skip_all => {
                self.policy = .skip_all;
                self.result.skipped += 1;
                return false;
            },
            .cancel => return error.Cancelled,
        }
    }

    /// Copies `src` to `dest`, recursing into directories. A directory
    /// that already exists at `dest` is merged into rather than treated as
    /// a conflict; files and links inside it conflict one by one.
    fn copyTree(self: *Runner, src: []const u8, dest: []const u8) Stop!void {
        const cwd = std.Io.Dir.cwd();
        const st = cwd.statFile(self.io, src, .{ .follow_symlinks = false }) catch |err| return self.fail(src, err);
        switch (st.kind) {
            .directory => {
                if (!isDirectory(self.io, dest)) {
                    if (exists(self.io, dest)) {
                        if (!try self.resolveConflict(src, dest)) return;
                        cwd.deleteTree(self.io, dest) catch |err| return self.fail(dest, err);
                    }
                    cwd.createDir(self.io, dest, st.permissions) catch |err| return self.fail(dest, err);
                    self.result.done += 1;
                }
                var dir = cwd.openDir(self.io, src, .{ .iterate = true }) catch |err| return self.fail(src, err);
                defer dir.close(self.io);
                var it = dir.iterate();
                while (it.next(self.io) catch |err| return self.fail(src, err)) |entry| {
                    const child_src = std.fs.path.join(self.alloc, &.{ src, entry.name }) catch |err| return self.fail(src, err);
                    defer self.alloc.free(child_src);
                    const child_dest = std.fs.path.join(self.alloc, &.{ dest, entry.name }) catch |err| return self.fail(src, err);
                    defer self.alloc.free(child_dest);
                    try self.copyTree(child_src, child_dest);
                }
            },
            .sym_link => {
                if (exists(self.io, dest)) {
                    if (!try self.resolveConflict(src, dest)) return;
                    cwd.deleteTree(self.io, dest) catch |err| return self.fail(dest, err);
                }
                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const len = cwd.readLink(self.io, src, &buf) catch |err| return self.fail(src, err);
                cwd.symLink(self.io, buf[0..len], dest, .{}) catch |err| return self.fail(dest, err);
                self.result.done += 1;
            },
            else => {
                if (exists(self.io, dest)) {
                    if (!try self.resolveConflict(src, dest)) return;
                    // A directory in the way isn't replaced by `copyFile`.
                    if (isDirectory(self.io, dest)) cwd.deleteTree(self.io, dest) catch |err| return self.fail(dest, err);
                }
                cwd.copyFile(src, cwd, dest, self.io, .{}) catch |err| return self.fail(src, err);
                self.result.done += 1;
            },
        }
    }

    /// Moves `src` to `dest`: a rename when it can be one, else a copy
    /// followed by deleting the source -- but only when the copy finished
    /// with nothing skipped or failed, so a partial move never loses the
    /// files it didn't get to.
    fn moveTree(self: *Runner, src: []const u8, dest: []const u8) Stop!void {
        const cwd = std.Io.Dir.cwd();
        const src_is_dir = isDirectory(self.io, src);
        const dest_exists = exists(self.io, dest);

        // A directory onto an existing directory merges, which rename
        // can't do; everything else may try a rename first.
        if (!(src_is_dir and dest_exists and isDirectory(self.io, dest))) {
            if (dest_exists) {
                if (!try self.resolveConflict(src, dest)) return;
                if (isDirectory(self.io, dest) != src_is_dir) {
                    cwd.deleteTree(self.io, dest) catch |err| return self.fail(dest, err);
                }
            }
            if (std.Io.Dir.rename(cwd, src, cwd, dest, self.io)) {
                self.result.done += 1;
                return;
            } else |err| switch (err) {
                // Another filesystem, or a directory whose target couldn't
                // simply be replaced: fall back to copy + delete.
                error.CrossDevice, error.DirNotEmpty, error.IsDir, error.NotDir => {},
                else => return self.fail(src, err),
            }
        }

        const before = self.result;
        // The conflict (if any) was answered above; don't ask twice.
        const saved = self.policy;
        if (dest_exists and !src_is_dir) self.policy = .overwrite_all;
        const copied = self.copyTree(src, dest);
        self.policy = saved;
        try copied;
        if (self.result.skipped != before.skipped or self.result.failed != before.failed) return;
        cwd.deleteTree(self.io, src) catch |err| return self.fail(src, err);
    }
};
