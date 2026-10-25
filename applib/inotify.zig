// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! "Something changed in these directories": an inotify instance whose
//! thread wakes a program's run loop (zoe's `file_watch = "inotify"`,
//! see `zoe/diskwatch.zig`; gwmd's reload of the open file).
//!
//! It only says *that* something changed, never what. A thread blocks on
//! the inotify fd, and any event at all sets `changed` and wakes the run
//! loop (`InputListener.wake`), which then stats whatever it cares about.
//! So there is no event decoding to get wrong: the kernel's job is to end
//! the wait early, and the stats decide.
//!
//! Directories are watched, not files: a file replaced by a rename (how
//! most editors save) is a new inode a file watch would lose, and a
//! directory watch also sees a deletion and a creation. The caller
//! re-syncs the set each turn of its loop with `begin` / `want` /
//! `sweep` -- a mark and sweep over a map, so a turn that changes nothing
//! allocates nothing. A directory that doesn't exist can't be watched;
//! a file that later appears in it is noticed when something else wakes
//! the check.
//!
//! The thread only reads the fd and flips an atomic. Adding and removing
//! watches is the main thread's, which the kernel allows on the same fd
//! from any thread.

const std = @import("std");
const builtin = @import("builtin");
const glyphwire = @import("glyphwire");
const linux = std.os.linux;

/// What a watched directory reports: content written, metadata touched,
/// entries created, deleted or renamed, and the directory itself going.
/// Opens and reads are left out, which matters: the caller stats and reads
/// these directories itself, and must not wake itself doing so.
const mask: u32 = linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE |
    linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.DELETE |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR;

pub const Watcher = struct {
    alloc: std.mem.Allocator,
    /// The inotify instance, non-blocking so the thread can drain it.
    fd: i32,
    /// An eventfd `stop` writes to, so the thread's `poll` returns.
    stop_fd: i32,
    thread: std.Thread,
    /// Woken on the first event after `takeChanged` cleared the flag.
    /// Null in tests, which read the flag instead.
    listener: ?*glyphwire.InputListener,
    /// Set by the thread on any event; cleared by `takeChanged`.
    changed: std.atomic.Value(bool) = .init(false),
    /// Watched directory -> its watch. Keys owned, NUL-terminated for the
    /// syscall.
    dirs: std.StringHashMapUnmanaged(Watch) = .empty,

    const Watch = struct {
        wd: i32,
        /// Wanted this sync (`want` since the last `begin`).
        seen: bool,
    };

    /// Starts the instance and its thread. `error.Unsupported` off Linux.
    pub fn start(alloc: std.mem.Allocator, listener: ?*glyphwire.InputListener) !*Watcher {
        if (builtin.os.tag != .linux) return error.Unsupported;

        const fd_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(fd_rc) != .SUCCESS) return error.InotifyInitFailed;
        const fd: i32 = @intCast(fd_rc);
        errdefer _ = linux.close(fd);

        const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC);
        if (linux.errno(efd_rc) != .SUCCESS) return error.EventFdFailed;
        const stop_fd: i32 = @intCast(efd_rc);
        errdefer _ = linux.close(stop_fd);

        const self = try alloc.create(Watcher);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .fd = fd,
            .stop_fd = stop_fd,
            .thread = undefined,
            .listener = listener,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops the thread and frees everything, the watches included.
    pub fn stop(self: *Watcher) void {
        const one: u64 = 1;
        _ = linux.write(self.stop_fd, std.mem.asBytes(&one), @sizeOf(u64));
        self.thread.join();
        // Closing the instance drops every watch with it.
        _ = linux.close(self.fd);
        _ = linux.close(self.stop_fd);
        var it = self.dirs.keyIterator();
        while (it.next()) |k| self.freeKey(k.*);
        self.dirs.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Whether anything changed since the last call, clearing it. The
    /// thread only wakes the loop when it sets a cleared flag, so a
    /// caller that leaves it set (a check already pending) gets no more
    /// wakes until it takes it -- what keeps a directory under constant
    /// writes from spinning the loop.
    pub fn takeChanged(self: *Watcher) bool {
        return self.changed.swap(false, .acq_rel);
    }

    /// Starts a sync: every watch is unwanted until `want` says otherwise.
    pub fn begin(self: *Watcher) void {
        var it = self.dirs.valueIterator();
        while (it.next()) |w| w.seen = false;
    }

    /// Wants `dir` watched, adding the watch if it is new. A directory
    /// that can't be watched (gone, unreadable) is skipped.
    pub fn want(self: *Watcher, dir: []const u8) !void {
        if (self.dirs.getPtr(dir)) |w| {
            w.seen = true;
            return;
        }
        const key = try self.alloc.dupeSentinel(u8, dir, 0);
        errdefer self.alloc.free(key);
        const rc = linux.inotify_add_watch(self.fd, key.ptr, mask);
        if (linux.errno(rc) != .SUCCESS) {
            self.alloc.free(key);
            return;
        }
        const wd: i32 = @intCast(rc);
        errdefer if (!self.wdInUse(wd)) {
            _ = linux.inotify_rm_watch(self.fd, wd);
        };
        try self.dirs.put(self.alloc, key, .{ .wd = wd, .seen = true });
    }

    /// Ends a sync: drops every watch `want` didn't ask for since `begin`.
    pub fn sweep(self: *Watcher) !void {
        var drop: std.ArrayList([]const u8) = .empty;
        defer drop.deinit(self.alloc);
        var it = self.dirs.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.seen) try drop.append(self.alloc, e.key_ptr.*);
        }
        for (drop.items) |key| {
            const w = self.dirs.fetchRemove(key).?;
            // Two spellings of one directory (a symlink) share a watch
            // descriptor: keep it while another key still uses it.
            if (!self.wdInUse(w.value.wd)) _ = linux.inotify_rm_watch(self.fd, w.value.wd);
            self.freeKey(w.key);
        }
    }

    fn wdInUse(self: *const Watcher, wd: i32) bool {
        var it = self.dirs.valueIterator();
        while (it.next()) |w| {
            if (w.wd == wd) return true;
        }
        return false;
    }

    /// Frees a key, which was allocated with its NUL.
    fn freeKey(self: *Watcher, key: []const u8) void {
        self.alloc.free(key.ptr[0 .. key.len + 1]);
    }

    fn run(self: *Watcher) void {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            var fds = [_]linux.pollfd{
                .{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const rc = linux.poll(&fds, fds.len, -1);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            if (fds[1].revents != 0) return;
            if (fds[0].revents == 0) continue;

            // Drain: the events themselves don't matter, only that there
            // were some (see the module comment).
            var any = false;
            while (true) {
                const n = linux.read(self.fd, &buf, buf.len);
                switch (linux.errno(n)) {
                    .SUCCESS => {
                        if (n == 0) break;
                        any = true;
                    },
                    .INTR => continue,
                    else => break,
                }
            }
            if (any and !self.changed.swap(true, .acq_rel)) {
                if (self.listener) |l| l.wake();
            }
        }
    }
};
