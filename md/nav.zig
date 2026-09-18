// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! What following a link means in gwmd. Pure: the decision is made here
//! and carried out in `ui.zig`.
//!
//! - `#section` jumps within the page.
//! - Anything with a URL scheme (`https:`, `mailto:`, ...) goes to the
//!   desktop's opener -- a browser, a mail client.
//! - A relative or absolute path to a Markdown file (or to a directory,
//!   which means its README) opens in gwmd, at `#section` if one is given.
//! - A path to anything else -- an image, a PDF -- goes to the opener.

const std = @import("std");

pub const Target = union(enum) {
    /// A slug in the current page.
    anchor: []const u8,
    /// Hand to `xdg-open` as-is.
    external: []const u8,
    /// A local path, still relative to the linking page's directory, with
    /// its percent-encoding undone; `fragment` is the part after `#`.
    local: struct { path: []const u8, fragment: []const u8 },
};

/// Classifies `href`. Owned memory (a decoded path) comes from `alloc`.
pub fn classify(alloc: std.mem.Allocator, href: []const u8) !Target {
    if (href.len > 0 and href[0] == '#') return .{ .anchor = href[1..] };
    if (hasScheme(href)) {
        // `file:` links are local files by another name.
        if (std.mem.startsWith(u8, href, "file://")) return classify(alloc, href["file://".len..]);
        return .{ .external = href };
    }
    const hash = std.mem.indexOfScalar(u8, href, '#');
    const path_part = if (hash) |h| href[0..h] else href;
    const fragment = if (hash) |h| href[h + 1 ..] else "";
    if (path_part.len == 0) return .{ .anchor = fragment };
    return .{ .local = .{ .path = try percentDecode(alloc, path_part), .fragment = fragment } };
}

/// `scheme:` per RFC 3986 -- a letter, then letters, digits, `+`, `-`,
/// `.`, then a colon. A Windows drive letter (`C:`) would match; this is
/// a Linux tool, so it doesn't come up.
pub fn hasScheme(href: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, href, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(href[0])) return false;
    for (href[0..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    // A slash before the colon means it's a path that happens to contain
    // one (`docs/a:b.md`), which the loop above already rules out.
    return true;
}

/// True for the extensions gwmd renders itself.
pub fn isMarkdownPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    const known = [_][]const u8{ ".md", ".markdown", ".mdown", ".mkd", ".mkdn" };
    for (known) |k| {
        if (std.ascii.eqlIgnoreCase(ext, k)) return true;
    }
    return false;
}

/// `%20` and friends back to bytes. A malformed escape is kept literally.
pub fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(alloc, s[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(alloc, s[i]);
                continue;
            };
            try out.append(alloc, hi * 16 + lo);
            i += 2;
            continue;
        }
        try out.append(alloc, s[i]);
    }
    return out.toOwnedSlice(alloc);
}

/// `rel` resolved against `base_dir` (the linking page's directory), or
/// `rel` itself when it's already absolute. Caller owns the result.
pub fn resolve(alloc: std.mem.Allocator, base_dir: []const u8, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return std.fs.path.resolve(alloc, &.{rel});
    return std.fs.path.resolve(alloc, &.{ base_dir, rel });
}
