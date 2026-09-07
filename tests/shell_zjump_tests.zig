const std = @import("std");
const testz = @import("testz");

// The pure data model behind the `zj` builtin (see shell/zjump.zig): no
// IO, so these tests build a database in memory, drive it, and assert on
// what comes back.
const zjump = @import("shell_support").zjump;

const hour = 3600;
const day = 86_400;
const week = 604_800;

// ─── recency multiplier ──────────────────────────────────────────────

pub fn recencyMultiplierStepsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(zjump.recencyMultiplier(0), 4.0);
    try testz.expectEqual(zjump.recencyMultiplier(hour - 1), 4.0);
    try testz.expectEqual(zjump.recencyMultiplier(hour + 1), 2.0);
    try testz.expectEqual(zjump.recencyMultiplier(day + 1), 0.5);
    try testz.expectEqual(zjump.recencyMultiplier(week + 1), 0.25);
    // A last-visit stamp in the future (clock skew) counts as "just now".
    try testz.expectEqual(zjump.recencyMultiplier(-50), 4.0);
}

pub fn scoreIsRankTimesRecencyTest(_: std.Io, _: std.mem.Allocator) !void {
    const e = zjump.Entry{ .path = "/x", .rank = 3, .last = 0 };
    try testz.expectEqual(zjump.score(e, day - 10), 6.0); // within the day: 3 * 2.0
    try testz.expectEqual(zjump.score(e, day + 10), 1.5); // past a day: 3 * 0.5
}

// ─── query matching ──────────────────────────────────────────────────

pub fn queryMatchesSubstringCaseInsensitiveTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(zjump.queryMatches("/home/me/Downloads", &.{"dow"}));
    try testz.expectTrue(zjump.queryMatches("/home/me/Downloads", &.{"DOWN"}));
    try testz.expectFalse(zjump.queryMatches("/home/me/Documents", &.{"dow"}));
}

pub fn queryLastTermMustHitBasenameTest(_: std.Io, _: std.mem.Allocator) !void {
    // "src" appears in the path but not the final component -> no match
    // when it's the *last* term.
    try testz.expectFalse(zjump.queryMatches("/code/src/pixzig", &.{"src"}));
    try testz.expectTrue(zjump.queryMatches("/code/src/pixzig", &.{"pix"}));
    // As a non-last term, a path (non-basename) hit is fine.
    try testz.expectTrue(zjump.queryMatches("/code/src/pixzig", &.{ "src", "pix" }));
}

pub fn queryNoTermsMatchesAnythingTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(zjump.queryMatches("/anything", &.{}));
    try testz.expectTrue(zjump.queryMatches("/anything", &.{""}));
}

// ─── parse / serialize round trip ────────────────────────────────────

pub fn parseReadsWellFormedLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const bytes =
        "3.500\t1000\t/home/me/code\n" ++
        "1.000\t2000\t/tmp/scratch\n";
    var db = try zjump.Db.parse(alloc, bytes);
    defer db.deinit();

    try testz.expectEqual(db.entries.items.len, 2);
}

pub fn parseSkipsMalformedLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const bytes =
        "notanumber\t1\t/a\n" ++ // bad rank
        "1.0\tnope\t/b\n" ++ // bad timestamp
        "-2.0\t1\t/c\n" ++ // non-positive rank
        "\n" ++ // blank
        "1.0\t1\t\n" ++ // empty path
        "2.0\t5\t/good\n";
    var db = try zjump.Db.parse(alloc, bytes);
    defer db.deinit();

    try testz.expectEqual(db.entries.items.len, 1);
    try testz.expectEqualStr("/good", db.entries.items[0].path);
}

pub fn parseSkipsControlBytesInPathTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A tab or any other control byte in the path -> the line is dropped
    // (such a directory name can't be written back unambiguously).
    var db = try zjump.Db.parse(alloc, "1.0\t1\t/has\x01ctrl\n2.0\t1\t/a\tb\n3.0\t1\t/ok\n");
    defer db.deinit();
    try testz.expectEqual(db.entries.items.len, 1);
    try testz.expectEqualStr("/ok", db.entries.items[0].path);
}

pub fn serializeRoundTripsAndSortsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();
    try db.record("/z/last", 100);
    try db.record("/a/first", 100);

    const bytes = try db.serialize(alloc);
    defer alloc.free(bytes);

    // Sorted by path, so "/a/first" comes before "/z/last".
    const a_idx = std.mem.indexOf(u8, bytes, "/a/first").?;
    const z_idx = std.mem.indexOf(u8, bytes, "/z/last").?;
    try testz.expectTrue(a_idx < z_idx);

    var db2 = try zjump.Db.parse(alloc, bytes);
    defer db2.deinit();
    try testz.expectEqual(db2.entries.items.len, 2);
}

// ─── record / aging ──────────────────────────────────────────────────

pub fn recordBumpsRankAndTimestampTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();

    try db.record("/p", 10);
    try db.record("/p", 20);
    try db.record("/p", 15); // older stamp: keeps the newer one

    try testz.expectEqual(db.entries.items.len, 1);
    try testz.expectEqual(db.entries.items[0].rank, 3.0);
    try testz.expectEqual(db.entries.items[0].last, 20);
}

pub fn recordIgnoresNewlineInPathTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();
    try db.record("/bad\npath", 1);
    try testz.expectEqual(db.entries.items.len, 0);
}

pub fn agingScalesDownAndEvictsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();

    // One heavy entry and one faint one; push the total over the cap and
    // the faint one should be evicted while the heavy one is just scaled.
    db.entries.append(alloc, .{ .path = try db.strings.allocator().dupe(u8, "/heavy"), .rank = zjump.max_total_rank, .last = 0 }) catch unreachable;
    db.entries.append(alloc, .{ .path = try db.strings.allocator().dupe(u8, "/faint"), .rank = 1.05, .last = 0 }) catch unreachable;

    try db.record("/heavy", 0); // total now > max_total_rank -> age()

    var found_heavy = false;
    var found_faint = false;
    for (db.entries.items) |e| {
        if (std.mem.eql(u8, e.path, "/heavy")) found_heavy = true;
        if (std.mem.eql(u8, e.path, "/faint")) found_faint = true;
    }
    try testz.expectTrue(found_heavy);
    try testz.expectFalse(found_faint); // 1.05 * 0.9 = 0.945 < drop_below
}

// ─── bestMatch ───────────────────────────────────────────────────────

pub fn bestMatchPicksHigherFrecencyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();

    const now: i64 = 1_000_000;
    // Rarely visited but very recent: 3 * 4.0 = 12.
    db.entries.append(alloc, .{ .path = try db.strings.allocator().dupe(u8, "/a/proj"), .rank = 3, .last = now - 60 }) catch unreachable;
    // Visited a lot, but over a month ago: 20 * 0.25 = 5.
    db.entries.append(alloc, .{ .path = try db.strings.allocator().dupe(u8, "/b/proj"), .rank = 20, .last = now - 40 * day }) catch unreachable;

    const hit = db.bestMatch(&.{"proj"}, now, .{}).?;
    try testz.expectEqualStr("/a/proj", hit);
}

pub fn bestMatchExcludesCurrentDirTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();
    try db.record("/here", 100);
    try db.record("/there", 100);

    const hit = db.bestMatch(&.{"ere"}, 100, .{ .cwd = "/here" });
    // "/here" is where we are; "/there" also matches "ere".
    try testz.expectEqualStr("/there", hit.?);
}

pub fn bestMatchHonoursExcludeDirsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();
    try db.record("/tmp/build", 100);
    try db.record("/home/me/build", 50);

    const hit = db.bestMatch(&.{"build"}, 100, .{ .exclude = &.{"/tmp"} });
    try testz.expectEqualStr("/home/me/build", hit.?);
}

pub fn bestMatchExcludeIsPathBoundaryAwareTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(zjump.isExcluded("/tmp/x", &.{"/tmp"}));
    try testz.expectTrue(zjump.isExcluded("/tmp", &.{"/tmp"}));
    try testz.expectTrue(zjump.isExcluded("/tmp/x", &.{"/tmp/"}));
    // Not a path-component boundary: "/tmpfoo" is not under "/tmp".
    try testz.expectFalse(zjump.isExcluded("/tmpfoo/x", &.{"/tmp"}));
}

var probe_hidden: []const u8 = "";
fn missOnHidden(_: ?*anyopaque, path: []const u8) bool {
    return !std.mem.eql(u8, path, probe_hidden);
}

pub fn bestMatchFiltersNonExistentViaProbeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();
    try db.record("/gone/proj", 100); // highest rank
    try db.record("/still/proj", 1);

    probe_hidden = "/gone/proj";
    const hit = db.bestMatch(&.{"proj"}, 100, .{ .exists = missOnHidden });
    try testz.expectEqualStr("/still/proj", hit.?);
}

pub fn bestMatchNoMatchReturnsNullTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();
    try db.record("/home/me/code", 100);
    try testz.expectEqual(db.bestMatch(&.{"nonsense"}, 100, .{}), null);
}

pub fn removeDropsEntryTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var db = zjump.Db.init(alloc);
    defer db.deinit();
    try db.record("/a", 1);
    try db.record("/b", 1);
    db.remove("/a");
    try testz.expectEqual(db.entries.items.len, 1);
    try testz.expectEqualStr("/b", db.entries.items[0].path);
    db.remove("/nonexistent"); // no-op, no crash
    try testz.expectEqual(db.entries.items.len, 1);
}
