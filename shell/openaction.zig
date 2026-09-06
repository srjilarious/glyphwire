//! Deciding what command runs when an `ls` entry is activated -- the
//! policy glyphwire-ls deliberately leaves out of its metadata blob.
//!
//! An entry carries a `kind` ("file" / "directory" / "symlink" / "other")
//! and, for regular files only, a real `mimetype`. `shell.conf`'s
//! `open_actions{}` table (parsed by `shell/config.zig`) maps a lookup
//! key to a command template; those entries are checked ahead of the
//! built-in `default_actions` below. `resolve` tries three key forms, in
//! this order of specificity:
//!
//!   1. the full mimetype     ("image/png")   -- regular files only
//!   2. the mimetype group    ("image/*")     -- regular files only
//!   3. the kind keyword      ("directory")
//!
//! and returns the first `Action` that matches. The three forms are tried
//! most-specific first; within one form a user `open_actions` entry beats
//! a default, and a later user entry beats an earlier one for the same
//! key. So a user rule overrides the default for the *same* key, while a
//! broad user `image/*` still yields to the built-in `image/png` for a
//! PNG (exact beats group). `expand` then fills the chosen template's
//! placeholders:
//!
//!   {sel}         exactly one shell-quoted path (errors on 0 or >1)
//!   {selections}  one or more shell-quoted paths, space-joined
//!
//! A template with neither placeholder is returned unchanged -- the
//! command just ignores the selection.

const std = @import("std");
const wordsplit = @import("wordsplit.zig");

/// The metadata a single activated entry contributes -- the fields
/// glyphwire-ls's `entryMetadataJson` writes. `mimetype` is null for
/// anything that isn't a regular file.
pub const Entry = struct {
    kind: []const u8,
    path: []const u8,
    mimetype: ?[]const u8 = null,
};

/// One `open_actions` mapping. `commands` is a list so a later feature --
/// a context menu offering several actions for one type -- is not
/// designed out; today `resolve`'s caller runs `commands[0]`.
pub const Action = struct {
    key: []const u8,
    commands: []const []const u8,
};

/// Shipped defaults, overridable per key by a `shell.conf` `open_actions`
/// entry. Kept intentionally small: auto-`cd` into a directory, and hand
/// an image to gw-view (only the formats it actually decodes --
/// PNG / JPEG / GIF / BMP, not svg or webp).
pub const default_actions = [_]Action{
    .{ .key = "directory", .commands = &.{"cd {sel}"} },
    .{ .key = "image/png", .commands = &.{"gw-view {selections}"} },
    .{ .key = "image/jpeg", .commands = &.{"gw-view {selections}"} },
    .{ .key = "image/gif", .commands = &.{"gw-view {selections}"} },
    .{ .key = "image/bmp", .commands = &.{"gw-view {selections}"} },
};

fn matchExact(key: []const u8, entry: Entry) bool {
    const mime = entry.mimetype orelse return false;
    return std.mem.eql(u8, key, mime);
}

fn matchGroup(key: []const u8, entry: Entry) bool {
    const mime = entry.mimetype orelse return false;
    if (!std.mem.endsWith(u8, key, "/*")) return false;
    // "image/*" matches "image/png" -- compare including the slash so
    // "image/*" doesn't also match "imagexy/...".
    return std.mem.startsWith(u8, mime, key[0 .. key.len - 1]);
}

fn matchKind(key: []const u8, entry: Entry) bool {
    return std.mem.eql(u8, key, entry.kind);
}

/// Last user entry matching `pred` wins; a user match beats any default.
fn pick(user: []const Action, entry: Entry, pred: *const fn ([]const u8, Entry) bool) ?Action {
    var found: ?Action = null;
    for (user) |a| {
        if (pred(a.key, entry)) found = a;
    }
    if (found) |a| return a;
    for (default_actions) |a| {
        if (pred(a.key, entry)) return a;
    }
    return null;
}

/// The command template(s) for `entry`, or null when nothing -- user
/// table or defaults -- matches (the caller then does nothing, per the
/// "don't guess" policy).
pub fn resolve(user: []const Action, entry: Entry) ?Action {
    return pick(user, entry, matchExact) orelse
        pick(user, entry, matchGroup) orelse
        pick(user, entry, matchKind);
}

pub const ExpandError = error{ NeedsSingle, OutOfMemory };

const sel_token = "{sel}";
const selections_token = "{selections}";

/// Fills `{sel}` / `{selections}` in `template` with the shell-quoted
/// `paths`. `{sel}` requires `paths.len == 1` (else `error.NeedsSingle`);
/// `{selections}` accepts any non-empty count, joined with a single
/// space. Returns an owned string; free it with `alloc`.
pub fn expand(alloc: std.mem.Allocator, template: []const u8, paths: []const []const u8) ExpandError![]u8 {
    std.debug.assert(paths.len >= 1);

    const wants_single = std.mem.indexOf(u8, template, sel_token) != null;
    if (wants_single and paths.len != 1) return error.NeedsSingle;

    // Quote every path once; both tokens draw from these.
    const quoted = try alloc.alloc([]u8, paths.len);
    var filled: usize = 0;
    defer {
        for (quoted[0..filled]) |q| alloc.free(q);
        alloc.free(quoted);
    }
    for (paths) |p| {
        quoted[filled] = try wordsplit.quoteArg(alloc, p);
        filled += 1;
    }

    const joined = try std.mem.join(alloc, " ", quoted);
    defer alloc.free(joined);

    // `{selections}` first: it contains `{sel}` as a prefix, so replacing
    // `{sel}` earlier would corrupt it.
    const step1 = try replaceOwned(alloc, template, selections_token, joined);
    defer alloc.free(step1);
    return try replaceOwned(alloc, step1, sel_token, quoted[0]);
}

/// Every non-overlapping occurrence of `needle` in `haystack` replaced by
/// `repl`. Owned result; `needle` must be non-empty.
fn replaceOwned(alloc: std.mem.Allocator, haystack: []const u8, needle: []const u8, repl: []const u8) error{OutOfMemory}![]u8 {
    std.debug.assert(needle.len > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.startsWith(u8, haystack[i..], needle)) {
            try out.appendSlice(alloc, repl);
            i += needle.len;
        } else {
            try out.append(alloc, haystack[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}
