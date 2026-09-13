// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Which entries in an archive are pages, and what order they read in.
//!
//! Comic archives are just a bag of image files with no manifest, so page
//! order is whatever sorting the filenames sensibly produces. A plain
//! byte-wise sort is wrong for the names scanners actually emit
//! (`page2.jpg` lands after `page10.jpg`), so `order` compares runs of
//! digits as numbers -- the "natural" order every other comic reader
//! uses.
//!
//! Pure: no allocator, no IO, no client. `archive.zig` applies it to a
//! real `.cbz` / directory and `tests/read_tests.zig` exercises it
//! directly.

const std = @import("std");

/// The container formats glyphwire-host's stb_image decodes, which is the
/// real constraint on what can be a page -- `load_image` parses the same
/// four names (see `glyphwire.detectImageFormat`). A `.webp` inside an
/// archive is skipped rather than failing the whole book; stb_image has
/// no WebP decoder yet (docs/ideas.md's View entry).
pub const page_extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif" };

/// True when `name` is an archive entry gw-read should treat as a page.
///
/// Rejects, in order: directory entries (a trailing `/`), anything under
/// macOS's `__MACOSX/` resource-fork tree or any other dot-directory,
/// dotfiles (`._page01.jpg` -- the AppleDouble sidecars that shadow every
/// real page in an archive zipped on a Mac), and finally anything whose
/// extension isn't one of `page_extensions`.
pub fn isPage(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[name.len - 1] == '/') return false;

    var it = std.mem.splitScalar(u8, name, '/');
    var last: []const u8 = "";
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        // A leading dot disqualifies any segment -- a hidden directory or
        // an AppleDouble sidecar. A leading `__` only disqualifies a
        // *directory* segment (`__MACOSX/`); a page legitimately named
        // `__cover.jpg` is still a page.
        if (seg[0] == '.') return false;
        if (std.mem.startsWith(u8, seg, "__") and it.peek() != null) return false;
        last = seg;
    }
    if (last.len == 0) return false;

    return hasPageExtension(last);
}

/// Case-insensitive extension match against `page_extensions`.
pub fn hasPageExtension(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    for (page_extensions) |want| {
        if (ext.len != want.len) continue;
        var same = true;
        for (ext, want) |a, b| {
            if (std.ascii.toLower(a) != b) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

/// Natural ("version") order: identical to a byte-wise compare except
/// that a run of digits on both sides compares as a number, so
/// `page2 < page10`. Ties inside a numeric run fall back to how the run
/// was padded, which puts `page01` before `page1` -- an arbitrary but
/// *stable* answer for names that differ only in zero padding.
///
/// ASCII case is folded so `Cover.jpg` sorts next to `chapter1.jpg`
/// rather than ahead of every lowercase name; a pure-case tie falls back
/// to the raw bytes so the order is still total (and the sort
/// deterministic).
pub fn order(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            const end_a = digitRun(a, i);
            const end_b = digitRun(b, j);
            switch (compareNumericRuns(a[i..end_a], b[j..end_b])) {
                .lt => return .lt,
                .gt => return .gt,
                .eq => {},
            }
            i = end_a;
            j = end_b;
            continue;
        }
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return if (la < lb) .lt else .gt;
        i += 1;
        j += 1;
    }
    if (i < a.len) return .gt;
    if (j < b.len) return .lt;
    return std.mem.order(u8, a, b);
}

/// `order` as a `std.sort` predicate.
pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return order(a, b) == .lt;
}

fn digitRun(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return i;
}

/// Compares two digit runs as numbers without parsing them into an
/// integer -- a scanner emitting a 40-digit frame counter shouldn't
/// overflow the page sort. Leading zeros are skipped for the numeric
/// comparison, then used as the tie-break (more padding sorts first, so
/// `01` precedes `1`).
fn compareNumericRuns(a: []const u8, b: []const u8) std.math.Order {
    const sig_a = a[leadingZeros(a)..];
    const sig_b = b[leadingZeros(b)..];
    if (sig_a.len != sig_b.len) return if (sig_a.len < sig_b.len) .lt else .gt;
    const digits = std.mem.order(u8, sig_a, sig_b);
    if (digits != .eq) return digits;
    if (a.len != b.len) return if (a.len > b.len) .lt else .gt;
    return .eq;
}

fn leadingZeros(s: []const u8) usize {
    var i: usize = 0;
    // Stop one short of the end so an all-zero run keeps its last digit
    // and compares as the number 0 rather than as an empty string.
    while (i + 1 < s.len and s[i] == '0') i += 1;
    return i;
}
