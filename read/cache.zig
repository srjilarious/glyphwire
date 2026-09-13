// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! A fixed-capacity LRU over the *server-side* image handles the reader
//! has loaded, so paging back a few pages is instant while a 300-page
//! volume never has 300 decoded pages resident.
//!
//! **Why handles and not `update_image`.** docs/api.md points a `.cbz`
//! reader at `update_image` -- reuse one handle rather than leaving a
//! dead image behind per page. That's the right advice for a reader that
//! only ever moves forward; it is exactly wrong for one with a back
//! button, because the previous page's bytes are gone the moment the next
//! one is drawn. gw-read instead loads a handle per page and calls
//! `destroy_image` on whatever falls out of this cache: the same bounded
//! footprint, but the last `capacity` pages are a keystroke away with no
//! re-upload. See docs/decisions.md's "gw-read: paging and the image
//! handle LRU".
//!
//! Pure: the cache never talks to a client. `put` hands the evicted entry
//! back and the caller is the one that calls `destroy_image`, which is
//! also what makes it testable with plain integers.

const std = @import("std");

/// One cached page: the handle the server knows it by, plus the natural
/// pixel size `get_image_info` reported. The size is cached alongside
/// because the zoom maths needs it on every resize and every zoom step,
/// and it would otherwise be a round trip each time.
pub const Entry = struct {
    page: usize,
    handle: u32,
    width: u32,
    height: u32,
};

/// Upper bound on `capacity`. The cost of a cached page is server-side
/// image bytes (a few MB for a scan), so tens are reasonable and hundreds
/// defeat the point of having a cache at all.
pub const max_capacity: usize = 64;

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Parallel to `entries`: the value of `clock` when each was last
    /// touched. A monotonic counter beats an intrusive linked list here
    /// -- `capacity` is small enough that the linear scan to find the
    /// oldest is cheaper than maintaining pointers, and it's far easier
    /// to read.
    stamps: std.ArrayList(u64) = .empty,
    clock: u64 = 0,
    capacity: usize,

    pub fn init(capacity: usize) Cache {
        return .{ .capacity = std.math.clamp(capacity, 1, max_capacity) };
    }

    pub fn deinit(self: *Cache, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.stamps.deinit(alloc);
    }

    /// The cached entry for `page`, marking it most-recently-used. Null
    /// when the page isn't resident and has to be loaded.
    pub fn get(self: *Cache, page: usize) ?Entry {
        for (self.entries.items, 0..) |e, i| {
            if (e.page != page) continue;
            self.clock += 1;
            self.stamps.items[i] = self.clock;
            return e;
        }
        return null;
    }

    /// Whether `page` is resident, without touching its recency -- what
    /// the prefetch path asks before deciding to load, since a prefetch
    /// shouldn't reorder what the reader has actually looked at.
    pub fn contains(self: *const Cache, page: usize) bool {
        for (self.entries.items) |e| {
            if (e.page == page) return true;
        }
        return false;
    }

    /// Inserts `entry` as most-recently-used, evicting the oldest if the
    /// cache is full. Returns whatever was evicted so the caller can
    /// `destroy_image` it -- ignoring the result leaks a server-side
    /// image until the connection closes.
    ///
    /// Re-inserting a page that's already resident replaces it and
    /// returns the *old* entry to be destroyed, which is what a reload
    /// after an archive change would want.
    pub fn put(self: *Cache, alloc: std.mem.Allocator, entry: Entry) !?Entry {
        self.clock += 1;

        for (self.entries.items, 0..) |e, i| {
            if (e.page != entry.page) continue;
            self.entries.items[i] = entry;
            self.stamps.items[i] = self.clock;
            return if (e.handle == entry.handle) null else e;
        }

        if (self.entries.items.len < self.capacity) {
            try self.entries.append(alloc, entry);
            errdefer _ = self.entries.pop();
            try self.stamps.append(alloc, self.clock);
            return null;
        }

        const victim = self.oldestIndex();
        const evicted = self.entries.items[victim];
        self.entries.items[victim] = entry;
        self.stamps.items[victim] = self.clock;
        return evicted;
    }

    /// Empties the cache, appending every entry to `out` so the caller
    /// can destroy them all -- used on quit and when a book is closed.
    pub fn drain(self: *Cache, alloc: std.mem.Allocator, out: *std.ArrayList(Entry)) !void {
        try out.appendSlice(alloc, self.entries.items);
        self.entries.clearRetainingCapacity();
        self.stamps.clearRetainingCapacity();
    }

    pub fn len(self: *const Cache) usize {
        return self.entries.items.len;
    }

    fn oldestIndex(self: *const Cache) usize {
        var best: usize = 0;
        for (self.stamps.items, 0..) |s, i| {
            if (s < self.stamps.items[best]) best = i;
        }
        return best;
    }
};
