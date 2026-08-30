const std = @import("std");
const testz = @import("testz");

// glyphwire-ls is an executable (no importable module), but its pure
// helpers are gathered into the `ls_support` module (see build.zig)
// precisely so they can be exercised here.
const gridlayout = @import("ls_support").gridlayout;
const lsfmt = @import("ls_support").format;
const lsicons = @import("ls_support").icons;

const small_opts: gridlayout.Options = .{ .icon_cols = 2, .block_rows = 1 };

// ─── gridlayout.compute ─────────────────────────────────────────────────

pub fn computeNarrowLayerIsSingleColumnTest(_: std.Io, _: std.mem.Allocator) !void {
    // block_cols = 2 + clamp(12,8,40) + 2 = 16; a 20-wide layer holds one.
    const grid = gridlayout.compute(10, 12, 20, small_opts);
    try testz.expectEqual(grid.cols, 1);
    try testz.expectEqual(grid.rows, 10);
    try testz.expectEqual(grid.block_cols, 16);
    try testz.expectEqual(grid.name_cols, 12);
}

pub fn computeWideLayerPacksAndTightensColumnsTest(_: std.Io, _: std.mem.Allocator) !void {
    // block_cols = 2 + 8 + 2 = 12; (100+2)/12 = 8 columns would fit, but
    // 10 entries over 8 columns is really 2 rows, and 10 over 2 rows is
    // 5 columns -- no empty trailing column, same shape `ls -C` gives.
    const grid = gridlayout.compute(10, 8, 100, small_opts);
    try testz.expectEqual(grid.block_cols, 12);
    try testz.expectEqual(grid.rows, 2);
    try testz.expectEqual(grid.cols, 5);
}

pub fn computeTightensAwayEmptyTrailingColumnTest(_: std.Io, _: std.mem.Allocator) !void {
    // (50+2)/12 = 4 columns fit, but 5 entries over 4 columns is 2 rows,
    // and 5 over 2 rows is 3 columns.
    const grid = gridlayout.compute(5, 8, 50, small_opts);
    try testz.expectEqual(grid.rows, 2);
    try testz.expectEqual(grid.cols, 3);
}

pub fn computeColumnMajorSlotMappingTest(_: std.Io, _: std.mem.Allocator) !void {
    const grid = gridlayout.compute(10, 8, 100, small_opts); // 5 cols x 2 rows
    // Entries run down the first column, then the second, ...
    try testz.expectEqual(grid.slot(0).row, 0);
    try testz.expectEqual(grid.slot(0).col, 0);
    try testz.expectEqual(grid.slot(1).row, 1);
    try testz.expectEqual(grid.slot(1).col, 0);
    try testz.expectEqual(grid.slot(2).row, 0);
    try testz.expectEqual(grid.slot(2).col, 1);
    try testz.expectEqual(grid.slot(9).row, 1);
    try testz.expectEqual(grid.slot(9).col, 4);
}

pub fn computeClampsNameWidthToMaxTest(_: std.Io, _: std.mem.Allocator) !void {
    const grid = gridlayout.compute(3, 100, 400, .{ .icon_cols = 1, .block_rows = 1 });
    try testz.expectEqual(grid.name_cols, 40);
}

pub fn computeClampsNameWidthToMinTest(_: std.Io, _: std.mem.Allocator) !void {
    const grid = gridlayout.compute(3, 2, 400, .{ .icon_cols = 1, .block_rows = 1 });
    try testz.expectEqual(grid.name_cols, 8);
}

pub fn computeCarriesLargeBlockRowsTest(_: std.Io, _: std.mem.Allocator) !void {
    const grid = gridlayout.compute(4, 10, 200, .{ .icon_cols = 4, .block_rows = 2 });
    try testz.expectEqual(grid.block_rows, 2);
}

pub fn computeNeverExceedsEntryCountColumnsTest(_: std.Io, _: std.mem.Allocator) !void {
    // A very wide layer with only 3 short entries: 3 columns, 1 row, no
    // phantom columns past the entries that exist.
    const grid = gridlayout.compute(3, 4, 1000, small_opts);
    try testz.expectEqual(grid.cols, 3);
    try testz.expectEqual(grid.rows, 1);
}

// ─── gridlayout.truncateToCols ──────────────────────────────────────────

pub fn truncateLeavesShortTextUntouchedTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    const out = gridlayout.truncateToCols(&buf, "short.txt", 20);
    try testz.expectEqualStr(out, "short.txt");
}

pub fn truncateCutsWithEllipsisTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    const out = gridlayout.truncateToCols(&buf, "abcdefghij", 5);
    try testz.expectEqualStr(out, "abcd\u{2026}");
    // Exactly `max_cols` codepoints wide (4 kept + the ellipsis).
    try testz.expectEqual(std.unicode.utf8CountCodepoints(out) catch 0, 5);
}

pub fn truncateZeroWidthIsEmptyTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    const out = gridlayout.truncateToCols(&buf, "anything", 0);
    try testz.expectEqual(out.len, 0);
}

pub fn truncateCountsCodepointsNotBytesTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    // 6 codepoints, each 2 bytes ("é" = U+00E9). Fits in 6, not in 5.
    const six = "éééééé";
    try testz.expectEqualStr(gridlayout.truncateToCols(&buf, six, 6), six);
    const out = gridlayout.truncateToCols(&buf, six, 5);
    try testz.expectEqual(std.unicode.utf8CountCodepoints(out) catch 0, 5);
    try testz.expectEqualStr(out, "éééé\u{2026}");
}

pub fn displayWidthCountsWideCodepointsAsTwoTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(gridlayout.displayWidth("abc"), @as(usize, 3));
    // "日本語" -- three wide CJK codepoints.
    try testz.expectEqual(gridlayout.displayWidth("\u{65E5}\u{672C}\u{8A9E}"), @as(usize, 6));
    // Mixed: "a世b" -> 1 + 2 + 1.
    try testz.expectEqual(gridlayout.displayWidth("a\u{4E16}b"), @as(usize, 4));
}

pub fn truncateCountsWideCodepointsAsTwoCellsTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    // "日本語ドキュメント" = 9 wide codepoints = 18 cells.
    const name = "\u{65E5}\u{672C}\u{8A9E}\u{30C9}\u{30AD}\u{30E5}\u{30E1}\u{30F3}\u{30C8}";
    // Fits when the budget is its full display width.
    try testz.expectEqualStr(gridlayout.truncateToCols(&buf, name, gridlayout.displayWidth(name)), name);
    // Budget 7: room for 3 wide chars (6 cells) + the 1-cell ellipsis.
    const out = gridlayout.truncateToCols(&buf, name, 7);
    try testz.expectEqualStr(out, "\u{65E5}\u{672C}\u{8A9E}\u{2026}");
    try testz.expectEqual(gridlayout.displayWidth(out), @as(usize, 7));
    // Budget 6: a wide char would overshoot 6-1=5, so only 2 fit (4 cells)
    // before the ellipsis -- a wide glyph is never split.
    const out6 = gridlayout.truncateToCols(&buf, name, 6);
    try testz.expectEqualStr(out6, "\u{65E5}\u{672C}\u{2026}");
}

// ─── lsfmt.formatSize ───────────────────────────────────────────────────

pub fn formatSizeRawIsExactByteCountTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [24]u8 = undefined;
    try testz.expectEqualStr(lsfmt.formatSize(&buf, 0, true), "0");
    try testz.expectEqualStr(lsfmt.formatSize(&buf, 1536, true), "1536");
    try testz.expectEqualStr(lsfmt.formatSize(&buf, 18446744073709551615, true), "18446744073709551615");
}

pub fn formatSizeHumanBucketsTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [24]u8 = undefined;
    try testz.expectEqualStr(lsfmt.formatSize(&buf, 512, false), " 512 B ");
    try testz.expectEqualStr(lsfmt.formatSize(&buf, 1536, false), "  1.5 KB");
    try testz.expectEqualStr(lsfmt.formatSize(&buf, 5 * 1024 * 1024, false), "  5.0 MB");
    try testz.expectEqualStr(lsfmt.formatSize(&buf, 3 * 1024 * 1024 * 1024, false), "  3.0 GB");
}

// ─── lsfmt.formatOwnerGroup ────────────────────────────────────────────

pub fn formatOwnerGroupJoinsWithColonTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    try testz.expectEqualStr(lsfmt.formatOwnerGroup(&buf, "jeffdw", "jeffdw"), "jeffdw:jeffdw");
    try testz.expectEqualStr(lsfmt.formatOwnerGroup(&buf, "root", "wheel"), "root:wheel");
    // A caller with no name for an id passes the decimal id through as-is.
    try testz.expectEqualStr(lsfmt.formatOwnerGroup(&buf, "1000", "1000"), "1000:1000");
}

pub fn formatOwnerGroupOverflowIsEmptyTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [4]u8 = undefined;
    // Too small to hold "a:bbbb" -- bufPrint fails, empty slice returned,
    // same shape formatSize/formatTimestamp use on overflow.
    try testz.expectEqual(lsfmt.formatOwnerGroup(&buf, "a", "bbbb").len, 0);
}

// ─── lsfmt.formatPermBits ──────────────────────────────────────────────

pub fn formatPermBitsRegularFileTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [10]u8 = undefined;
    // S_IFREG (type nibble 8) | 0o644
    try testz.expectEqualStr(lsfmt.formatPermBits(&buf, (8 << 12) | 0o644), "-rw-r--r--");
}

pub fn formatPermBitsDirectoryAndSymlinkTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [10]u8 = undefined;
    // S_IFDIR (type nibble 4) | 0o755
    try testz.expectEqualStr(lsfmt.formatPermBits(&buf, (4 << 12) | 0o755), "drwxr-xr-x");
    // S_IFLNK (type nibble 10) | 0o777
    try testz.expectEqualStr(lsfmt.formatPermBits(&buf, (10 << 12) | 0o777), "lrwxrwxrwx");
}

// ─── lsfmt.permTypeChar / formatPermTriad (the `-l` table's split cells) ─

pub fn permTypeCharMapsFileTypeNibbleTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(lsfmt.permTypeChar((8 << 12) | 0o644), @as(u8, '-'));
    try testz.expectEqual(lsfmt.permTypeChar((4 << 12) | 0o755), @as(u8, 'd'));
    try testz.expectEqual(lsfmt.permTypeChar((10 << 12) | 0o777), @as(u8, 'l'));
    try testz.expectEqual(lsfmt.permTypeChar((12 << 12) | 0o755), @as(u8, 's')); // socket
    try testz.expectEqual(lsfmt.permTypeChar((0 << 12) | 0o644), @as(u8, '?')); // unknown
}

pub fn formatPermTriadPicksTheRightBitGroupTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [3]u8 = undefined;
    // 0o750: user rwx, group r-x, other ---
    const mode: u16 = (8 << 12) | 0o750;
    try testz.expectEqualStr(lsfmt.formatPermTriad(&buf, mode, .user), "rwx");
    try testz.expectEqualStr(lsfmt.formatPermTriad(&buf, mode, .group), "r-x");
    try testz.expectEqualStr(lsfmt.formatPermTriad(&buf, mode, .other), "---");
    // The three triads laid end to end reproduce `formatPermBits`' tail.
    var full: [10]u8 = undefined;
    try testz.expectEqualStr(lsfmt.formatPermBits(&full, mode)[1..], "rwxr-x---");
}

// ─── lsfmt.formatTimestamp ─────────────────────────────────────────────

pub fn formatTimestampEpochAndNegativeTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [20]u8 = undefined;
    try testz.expectEqualStr(lsfmt.formatTimestamp(&buf, 0), "1970-01-01 00:00");
    // 2021-01-01 00:00:00 UTC
    try testz.expectEqualStr(lsfmt.formatTimestamp(&buf, 1609459200), "2021-01-01 00:00");
    // Negative (pre-epoch / unset) yields an empty string.
    try testz.expectEqual(lsfmt.formatTimestamp(&buf, -1).len, 0);
}

// ─── lsicons.iconForExtension ─────────────────────────────────────────────

pub fn iconForExtensionMapsKnownBucketsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(lsicons.iconForExtension("photo.png"), "oxygen/image");
    try testz.expectEqualStr(lsicons.iconForExtension("song.flac"), "oxygen/audio");
    try testz.expectEqualStr(lsicons.iconForExtension("clip.mkv"), "oxygen/video");
    try testz.expectEqualStr(lsicons.iconForExtension("bundle.tar.gz"), "oxygen/archive");
}

pub fn iconForExtensionMapsNewFileTypeBucketsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(lsicons.iconForExtension("report.pdf"), "oxygen/pdf");
    try testz.expectEqualStr(lsicons.iconForExtension("notes.docx"), "oxygen/document");
    try testz.expectEqualStr(lsicons.iconForExtension("budget.xlsx"), "oxygen/spreadsheet");
    try testz.expectEqualStr(lsicons.iconForExtension("data.csv"), "oxygen/spreadsheet");
    try testz.expectEqualStr(lsicons.iconForExtension("deck.odp"), "oxygen/presentation");
    try testz.expectEqualStr(lsicons.iconForExtension("README.md"), "oxygen/text");
    try testz.expectEqualStr(lsicons.iconForExtension("config.toml"), "oxygen/text");
    try testz.expectEqualStr(lsicons.iconForExtension("index.html"), "oxygen/web");
    try testz.expectEqualStr(lsicons.iconForExtension("style.css"), "oxygen/web");
    try testz.expectEqualStr(lsicons.iconForExtension("main.zig"), "oxygen/code");
    try testz.expectEqualStr(lsicons.iconForExtension("build.py"), "oxygen/code");
    try testz.expectEqualStr(lsicons.iconForExtension("pkg.deb"), "oxygen/package");
    try testz.expectEqualStr(lsicons.iconForExtension("pkg.rpm"), "oxygen/package");
}

pub fn iconForExtensionIsCaseInsensitiveTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(lsicons.iconForExtension("SCAN.PDF"), "oxygen/pdf");
    try testz.expectEqualStr(lsicons.iconForExtension("Photo.JPG"), "oxygen/image");
}

pub fn iconForExtensionShellScriptsAreCodeNotExecutableTest(_: std.Io, _: std.mem.Allocator) !void {
    // .sh moved from the "executable" bucket to "code"; the real binaries
    // stay on "executable".
    try testz.expectEqualStr(lsicons.iconForExtension("deploy.sh"), "oxygen/code");
    try testz.expectEqualStr(lsicons.iconForExtension("run.bash"), "oxygen/code");
    try testz.expectEqualStr(lsicons.iconForExtension("tool.exe"), "oxygen/executable");
    try testz.expectEqualStr(lsicons.iconForExtension("blob.bin"), "oxygen/executable");
}

pub fn iconForExtensionFallsBackToFileTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(lsicons.iconForExtension("mystery.qwerty"), "oxygen/file");
    try testz.expectEqualStr(lsicons.iconForExtension("NOEXTENSION"), "oxygen/file");
    try testz.expectEqualStr(lsicons.iconForExtension(""), "oxygen/file");
}
