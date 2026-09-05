//! Vendored from pixzig, currently unreferenced: `resources.zig`'s
//! hot-reload paths that used it are commented out (see that file's
//! header). Kept in the tree so re-enabling asset hot-reload is an
//! uncomment rather than a re-port. If glyphwire ever wants file
//! watching, the thing worth watching is the user's config files and
//! scripts under `~/.config/glyphwire/`, not the engine's own assets --
//! this type works for that too.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const WatchId = u32;

const FileEntry = struct {
    id: WatchId,
    wd: i32,
    filename: []const u8,
};

/// Watches directories via inotify on Linux and reports which registered
/// file paths have changed. On non-Linux platforms, `poll` is always a no-op
/// and `watch` succeeds but never fires.
pub const FileWatcher = struct {
    alloc: std.mem.Allocator,
    fd: i32,
    next_id: WatchId,
    entries: std.ArrayList(FileEntry),
    dir_to_wd: std.StringHashMap(i32),

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !Self {
        const fd: i32 = if (comptime builtin.os.tag == .linux) blk: {
            const rc = linux.inotify_init1(linux.IN.NONBLOCK);
            if (linux.errno(rc) != .SUCCESS) return error.InotifyInitFailed;
            break :blk @intCast(rc);
        } else -1;

        return .{
            .alloc = alloc,
            .fd = fd,
            .next_id = 0,
            .entries = .empty,
            .dir_to_wd = std.StringHashMap(i32).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |e| self.alloc.free(e.filename);
        self.entries.deinit(self.alloc);

        var it = self.dir_to_wd.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.dir_to_wd.deinit();

        if (comptime builtin.os.tag == .linux) {
            if (self.fd >= 0) _ = linux.close(self.fd);
        }
    }

    /// Register `path` for watching. Returns a `WatchId` that will appear in
    /// `poll`'s output when that file is modified. Watches the parent directory
    /// so that atomic-rename style editors (vim, etc.) are detected correctly.
    pub fn watch(self: *Self, path: []const u8) !WatchId {
        const dir = std.fs.path.dirname(path) orelse ".";
        const filename = std.fs.path.basename(path);

        const wd: i32 = if (self.dir_to_wd.get(dir)) |w| w else blk: {
            const new_wd: i32 = if (comptime builtin.os.tag == .linux) blk2: {
                const dir_z = try self.alloc.dupeZ(u8, dir);
                defer self.alloc.free(dir_z);
                const rc = linux.inotify_add_watch(
                    self.fd,
                    dir_z,
                    linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO,
                );
                if (linux.errno(rc) != .SUCCESS) return error.InotifyWatchFailed;
                break :blk2 @as(i32, @intCast(rc));
            } else 0;

            const owned_dir = try self.alloc.dupe(u8, dir);
            errdefer self.alloc.free(owned_dir);
            try self.dir_to_wd.put(owned_dir, new_wd);
            break :blk new_wd;
        };

        const id = self.next_id;
        self.next_id += 1;

        const owned_filename = try self.alloc.dupe(u8, filename);
        errdefer self.alloc.free(owned_filename);

        try self.entries.append(self.alloc, .{
            .id = id,
            .wd = wd,
            .filename = owned_filename,
        });

        std.log.debug("FileWatcher: watching dir='{s}' file='{s}' id={} wd={}", .{ dir, owned_filename, id, wd });
        return id;
    }

    /// Non-blocking poll: appends the `WatchId` of every file that changed
    /// since the last call into `changed`, using `alloc` for any needed
    /// growth. On non-Linux platforms this is a no-op. OS errors are
    /// propagated; the caller should log and continue rather than crashing.
    pub fn poll(
        self: *Self,
        alloc: std.mem.Allocator,
        changed: *std.ArrayList(WatchId),
    ) !void {
        if (comptime builtin.os.tag != .linux) return;

        const event_size = @sizeOf(linux.inotify_event);
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        while (true) {
            const n = std.posix.read(self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) return;

            var off: usize = 0;
            while (off + event_size <= n) {
                const ev: *const linux.inotify_event =
                    @ptrCast(@alignCast(buf[off..].ptr));

                if (ev.getName()) |name| {
                    std.log.debug("inotify event: mask=0x{x} wd={} name='{s}'", .{ ev.mask, ev.wd, name });
                    var matched = false;
                    for (self.entries.items) |e| {
                        if (e.wd == ev.wd and std.mem.eql(u8, e.filename, name)) {
                            try changed.append(alloc, e.id);
                            matched = true;
                        }
                    }
                    if (!matched) {
                        std.log.debug("inotify event for '{s}' did not match any watched file", .{name});
                    }
                } else {
                    std.log.debug("inotify event: mask=0x{x} wd={} (no filename)", .{ ev.mask, ev.wd });
                }

                off += event_size + ev.len;
            }
        }
    }
};
