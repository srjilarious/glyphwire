// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! What runs when a file is activated in a pane. The shell has its own
//! answer to this question (`shell/openaction.zig`), keyed by the
//! mimetype `gw-ls` reports; a file pane has no such metadata to hand and
//! several of the types worth opening in-session can't be told apart by
//! mimetype anyway -- a `.cbz` is an `application/zip` like any other --
//! so the key here is the file's extension:
//!
//!     lowercased, no leading dot:  "md", "cbz", "png"
//!
//! `defaults` covers the glyphwire readers; `salacommander.conf.lua`'s
//! `open_actions` table overrides any of them per extension, or maps one
//! to `false` to get the desktop opener back. `resolve` returns the
//! command template for a path, or null when nothing matches -- the
//! caller then falls back to `xdg-open`, which is what every file did
//! before this table existed.
//!
//! A template is a plain command, split on spaces (there is no shell
//! here, and no quoting): the word `{sel}` becomes the activated file's
//! absolute path, and a template without one gets the path appended as
//! its last argument.

const std = @import("std");

/// One `open_actions` mapping.
pub const Action = struct {
    /// Lowercased, no leading dot.
    ext: []const u8,
    /// The command template, or null to hand the file to the desktop
    /// opener (how a config switches a built-in back off).
    command: ?[]const u8,
};

/// Shipped defaults, each overridable by a `salacommander.conf.lua`
/// `open_actions` entry for the same extension. Kept to the glyphwire
/// clients: these open in the session, next to the file manager, where
/// `xdg-open` would put them in some other window entirely.
pub const defaults = [_]Action{
    .{ .ext = "md", .command = "gwmd {sel}" },
    .{ .ext = "cbz", .command = "gw-read {sel}" },
    .{ .ext = "cbr", .command = "gw-read {sel}" },
    .{ .ext = "png", .command = "gw-view {sel}" },
    .{ .ext = "jpg", .command = "gw-view {sel}" },
    .{ .ext = "jpeg", .command = "gw-view {sel}" },
};

/// The most an expanded template may have. A template is a command line,
/// not a script; this is only here so `buildArgv` can work in the
/// caller's buffer.
pub const max_args = 16;

/// `path`'s extension as a lookup key -- lowercased, without the dot --
/// or null when it has none. Borrows `buf`, which must hold the
/// extension; a longer one is simply not a key we have an action for.
/// A leading-dot name (`.bashrc`) has no extension, the way `ls` sees it.
pub fn extensionKey(buf: []u8, path: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0 or dot + 1 == name.len) return null;
    const ext = name[dot + 1 ..];
    if (ext.len > buf.len) return null;
    for (ext, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..ext.len];
}

/// The command template for `path`: the last matching `user` entry, else
/// a default, else null (nothing claims it). A user entry mapped to
/// `false` matches and yields null, so it shadows the default.
pub fn resolve(user: []const Action, path: []const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    const ext = extensionKey(&buf, path) orelse return null;
    var found: ?Action = null;
    for (user) |a| {
        if (std.mem.eql(u8, a.ext, ext)) found = a;
    }
    if (found) |a| return a.command;
    for (defaults) |a| {
        if (std.mem.eql(u8, a.ext, ext)) return a.command;
    }
    return null;
}

pub const ArgvError = error{ TooManyArgs, EmptyCommand };

/// Splits `template` into an argv in `out`, with the word `{sel}`
/// replaced by `path`. A template that never mentions `{sel}` gets the
/// path appended, so `open_actions = { pdf = "zathura" }` does the
/// obvious thing. Only a whole word is a placeholder -- there is no
/// substitution inside `--file={sel}`, which would need quoting rules
/// this deliberately doesn't have.
pub fn buildArgv(out: *[max_args][]const u8, template: []const u8, path: []const u8) ArgvError![]const []const u8 {
    var n: usize = 0;
    var saw_sel = false;
    var it = std.mem.tokenizeScalar(u8, template, ' ');
    while (it.next()) |word| {
        if (n == max_args) return error.TooManyArgs;
        if (std.mem.eql(u8, word, "{sel}")) {
            out[n] = path;
            saw_sel = true;
        } else {
            out[n] = word;
        }
        n += 1;
    }
    if (n == 0) return error.EmptyCommand;
    if (!saw_sel) {
        if (n == max_args) return error.TooManyArgs;
        out[n] = path;
        n += 1;
    }
    return out[0..n];
}
