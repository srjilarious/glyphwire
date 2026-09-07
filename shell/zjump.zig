//! The data model behind the `zj` builtin -- glyphwire-shell's take on
//! `z` / zoxide / autojump directory jumping. Pure: `shell/main.zig` does
//! the filesystem IO (reading and writing `~/.config/glyphwire/z.db`,
//! resolving the real cwd, `chdir`-ing) and this module turns the file's
//! bytes into ranked entries, decides which one a query means, and turns
//! the entries back into bytes.
//!
//! ## Frecency
//!
//! Every directory the shell changes into is recorded here with a `rank`
//! (a visit weight, +1 per visit) and `last` (unix seconds of the most
//! recent visit). A query ranks candidates by *frecency*: `rank` scaled
//! by how recently the directory was last seen -- zoxide's stepped
//! multiplier (4x within the hour, 2x within the day, 0.5x within the
//! week, 0.25x older). A directory visited three times this morning
//! therefore beats one visited forty times last month.
//!
//! ## Aging
//!
//! Rather than a hard entry cap, the total `rank` across all entries is
//! bounded: once it exceeds `max_total_rank`, every entry is scaled down
//! by `aging_factor` and anything left below `drop_below` is removed. A
//! long-lived database stays small and keeps reflecting recent habits.
//!
//! ## Matching
//!
//! `zj a b c` matches an entry when every term is a case-insensitive
//! substring of the path *and* the last term is also a substring of the
//! path's final component -- so `zj dow` from anywhere lands in
//! `~/Downloads`, not `~/downloads-archive/old`. The current directory is
//! never a result (jumping to where you already are is a no-op).

const std = @import("std");

/// Once the summed `rank` of every entry passes this, `age` runs.
pub const max_total_rank: f64 = 10_000;
/// `age` multiplies every entry's `rank` by this.
pub const aging_factor: f64 = 0.9;
/// `age` drops any entry whose `rank` falls below this afterwards.
pub const drop_below: f64 = 1.0;

pub const Entry = struct {
    /// Absolute, canonical path (the shell stores the real cwd, so
    /// symlinks and `..` are already collapsed). Owned by `Db.strings`.
    path: []const u8,
    /// Visit weight: starts at 1, +1 per visit, scaled down by `age`.
    rank: f64,
    /// Unix seconds of the most recent visit.
    last: i64,
};

/// A parsed `z.db`. Entry path bytes live in `strings` (an arena, since
/// they are only ever added or dropped wholesale); the `entries` list
/// itself uses the caller's allocator.
pub const Db = struct {
    alloc: std.mem.Allocator,
    strings: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(alloc: std.mem.Allocator) Db {
        return .{ .alloc = alloc, .strings = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Db) void {
        self.entries.deinit(self.alloc);
        self.strings.deinit();
    }

    /// Parses the file. Each line is `<rank>\t<last>\t<path>`, with `rank`
    /// and `last` first so the line splits cleanly on the first two tabs.
    /// Malformed lines are skipped rather than rejecting the whole file:
    /// missing fields, unparseable numbers, a non-positive or non-finite
    /// rank, or any control byte (tab and newline included -- a directory
    /// name with either is not supported and `record` refuses it) in the
    /// path. A later duplicate path wins.
    pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Db {
        var db = Db.init(alloc);
        errdefer db.deinit();

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;

            var fields = std.mem.splitScalar(u8, line, '\t');
            const rank_s = fields.next() orelse continue;
            const last_s = fields.next() orelse continue;
            const path = fields.rest();
            if (path.len == 0 or hasControlByte(path)) continue;

            const rank = std.fmt.parseFloat(f64, std.mem.trim(u8, rank_s, " ")) catch continue;
            const last = std.fmt.parseInt(i64, std.mem.trim(u8, last_s, " "), 10) catch continue;
            if (!std.math.isFinite(rank) or rank <= 0) continue;

            try db.upsert(path, rank, last);
        }
        return db;
    }

    /// Sets `path`'s entry to exactly `rank` / `last` (used by `parse`).
    fn upsert(self: *Db, path: []const u8, rank: f64, last: i64) !void {
        if (self.find(path)) |e| {
            e.rank = rank;
            e.last = last;
            return;
        }
        const owned = try self.strings.allocator().dupe(u8, path);
        try self.entries.append(self.alloc, .{ .path = owned, .rank = rank, .last = last });
    }

    fn find(self: *Db, path: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    /// Record a visit to `path` at `now` (unix seconds): +1 to its rank,
    /// or a fresh weight-1 entry. Runs `age` afterwards. A path with a
    /// control byte in it (tab or newline especially) is ignored -- it
    /// could not be written back and read again unambiguously.
    pub fn record(self: *Db, path: []const u8, now: i64) !void {
        if (hasControlByte(path)) return;
        if (self.find(path)) |e| {
            e.rank += 1;
            if (now > e.last) e.last = now;
        } else {
            const owned = try self.strings.allocator().dupe(u8, path);
            try self.entries.append(self.alloc, .{ .path = owned, .rank = 1, .last = now });
        }
        self.age();
    }

    /// Drop `path`'s entry if present -- `shell/main.zig` calls this when
    /// a jump target turns out not to exist on disk any more.
    pub fn remove(self: *Db, path: []const u8) void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, path)) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    /// Scale every rank down and evict the faint ones, but only once the
    /// database as a whole has grown past `max_total_rank`.
    fn age(self: *Db) void {
        var total: f64 = 0;
        for (self.entries.items) |e| total += e.rank;
        if (total <= max_total_rank) return;

        var i: usize = 0;
        while (i < self.entries.items.len) {
            self.entries.items[i].rank *= aging_factor;
            if (self.entries.items[i].rank < drop_below) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// The best directory for `terms`, or null if nothing matches. Ranked
    /// by `score`; ties broken toward the more recently visited.
    pub fn bestMatch(self: *const Db, terms: []const []const u8, now: i64, opts: MatchOpts) ?[]const u8 {
        var best: ?Entry = null;
        for (self.entries.items) |e| {
            if (!queryMatches(e.path, terms)) continue;
            if (opts.cwd) |cwd| if (std.mem.eql(u8, cwd, e.path)) continue;
            if (isExcluded(e.path, opts.exclude)) continue;
            if (opts.exists) |exists| if (!exists(opts.exists_ctx, e.path)) continue;

            if (best) |b| {
                const bs = score(b, now);
                const es = score(e, now);
                if (es > bs or (es == bs and e.last > b.last)) best = e;
            } else {
                best = e;
            }
        }
        return if (best) |b| b.path else null;
    }

    /// Renders the database back to file bytes, one `<rank>\t<last>\t<path>`
    /// line per entry, sorted by path so the file diffs cleanly. Caller
    /// owns the result.
    pub fn serialize(self: *const Db, alloc: std.mem.Allocator) ![]u8 {
        const sorted = try alloc.dupe(Entry, self.entries.items);
        defer alloc.free(sorted);
        std.mem.sort(Entry, sorted, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var num: [64]u8 = undefined;
        for (sorted) |e| {
            const head = try std.fmt.bufPrint(&num, "{d:.3}\t{d}\t", .{ e.rank, e.last });
            try out.appendSlice(alloc, head);
            try out.appendSlice(alloc, e.path);
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }
};

/// How `bestMatch` filters candidates beyond the term match itself.
pub const MatchOpts = struct {
    /// The directory the shell is currently in -- never returned as a
    /// match. Absolute/canonical, compared byte for byte with `path`.
    cwd: ?[]const u8 = null,
    /// Directories (absolute, tilde already expanded by the caller) to
    /// exclude, along with everything under them.
    exclude: []const []const u8 = &.{},
    /// Optional "does this still exist as a directory?" probe. A miss is
    /// filtered out (and `shell/main.zig` prunes it on the next flush).
    exists: ?*const fn (ctx: ?*anyopaque, path: []const u8) bool = null,
    exists_ctx: ?*anyopaque = null,
};

/// Frecency: visit weight scaled by a recency multiplier.
pub fn score(e: Entry, now: i64) f64 {
    return e.rank * recencyMultiplier(now - e.last);
}

/// zoxide's stepped recency curve. A negative age (clock skew, a
/// last-visit stamp in the future) is treated as "just now".
pub fn recencyMultiplier(age_sec: i64) f64 {
    if (age_sec < 3600) return 4.0; // within the hour
    if (age_sec < 86_400) return 2.0; // within the day
    if (age_sec < 604_800) return 0.5; // within the week
    return 0.25; // older
}

/// Whether `path` satisfies every term: each term a case-insensitive
/// substring of the whole path, and the last (non-empty) term also a
/// substring of the path's final component. No terms matches anything.
pub fn queryMatches(path: []const u8, terms: []const []const u8) bool {
    var last: ?[]const u8 = null;
    for (terms) |t| {
        if (t.len == 0) continue;
        if (asciiIndexOfIgnoreCase(path, t) == null) return false;
        last = t;
    }
    const lt = last orelse return true;
    return asciiIndexOfIgnoreCase(std.fs.path.basename(path), lt) != null;
}

/// True when `path` equals, or sits underneath, any entry in `list`
/// (each an absolute directory). Used by `bestMatch` and, in
/// `shell/main.zig`, to keep excluded directories out of the database in
/// the first place.
pub fn isExcluded(path: []const u8, list: []const []const u8) bool {
    for (list) |ex| {
        if (ex.len == 0) continue;
        if (std.mem.eql(u8, path, ex)) return true;
        if (path.len > ex.len and std.mem.startsWith(u8, path, ex)) {
            // `ex` may or may not carry a trailing slash; accept both so
            // "/tmp" excludes "/tmp/x" but not "/tmpfoo".
            const boundary = if (ex[ex.len - 1] == '/') ex.len - 1 else ex.len;
            if (path[boundary] == '/') return true;
        }
    }
    return false;
}

fn hasControlByte(s: []const u8) bool {
    for (s) |c| if (c < 0x20) return true;
    return false;
}

/// Case-insensitive (ASCII) substring search. `needle` empty matches at 0.
pub fn asciiIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return i;
    }
    return null;
}
