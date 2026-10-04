// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Tab completion of a filename on the `:` line, and the popup that
//! lists the candidates.
//!
//! Tab on a path argument (`:e`, `:w`, `:sp`, `:vs`, `:cd`, ...) completes
//! the last path segment before the caret against its directory, read by
//! `applib/pathcomplete`'s `scanDir` -- the same rule gw-shell's Tab uses,
//! dotfiles only once the segment starts with `.`. One match is filled
//! in outright (a directory with its `/`, ready for the next Tab); more
//! than one fill in what they share and open the popup over the `:` line,
//! where Tab / Shift+Tab / Up / Down pick, Enter takes the pick into the
//! line (it does not run the command) and Escape closes the popup only.
//!
//! The argument is the *rest of the line*, not a space-delimited word:
//! zoe's `:e` takes everything after the command as one path, spaces and
//! all, so completion has to agree with it about where the path starts.
//!
//! Pure, apart from what the caller hands in -- `zoe/ui.zig` does the
//! scan and the drawing; this decides what to scan and keeps the list.

const std = @import("std");
const pathcomplete = @import("applib").pathcomplete;

/// The commands whose argument is a path, and whether only directories
/// make sense for it.
const path_commands = [_]struct { name: []const u8, dirs_only: bool }{
    .{ .name = "e", .dirs_only = false },
    .{ .name = "edit", .dirs_only = false },
    .{ .name = "e!", .dirs_only = false },
    .{ .name = "edit!", .dirs_only = false },
    .{ .name = "w", .dirs_only = false },
    .{ .name = "write", .dirs_only = false },
    .{ .name = "wq", .dirs_only = false },
    .{ .name = "wq!", .dirs_only = false },
    .{ .name = "x", .dirs_only = false },
    .{ .name = "x!", .dirs_only = false },
    .{ .name = "sp", .dirs_only = false },
    .{ .name = "split", .dirs_only = false },
    .{ .name = "vs", .dirs_only = false },
    .{ .name = "vsp", .dirs_only = false },
    .{ .name = "vsplit", .dirs_only = false },
    .{ .name = "cd", .dirs_only = true },
    .{ .name = "chdir", .dirs_only = true },
};

/// Where the path being completed sits on the `:` line.
pub const Target = struct {
    /// Byte offset of the start of the last path segment -- the text a
    /// pick replaces, up to the caret.
    seg_start: usize,
    /// The directory part as typed (`src/`, `~/code/`, empty for the
    /// working directory), with `~` still unexpanded.
    dir: []const u8,
    /// The typed start of the last segment, what entries must begin with.
    prefix: []const u8,
    /// `:cd` -- only directories are candidates.
    dirs_only: bool,
};

/// What Tab at byte `caret` of `line` (the `:` line's text, without the
/// colon) should complete, or null when the caret is not in a path
/// argument: the command isn't one that takes a path, or the caret is
/// still on the command name.
pub fn target(line: []const u8, caret: usize) ?Target {
    std.debug.assert(caret <= line.len);
    // Leading blanks before the command are allowed, as runCommand trims.
    const name_start = std.mem.indexOfNone(u8, line, " \t") orelse return null;
    const name_end = std.mem.indexOfAnyPos(u8, line, name_start, " \t") orelse return null;
    if (caret <= name_end) return null;

    const name = line[name_start..name_end];
    const dirs_only = for (path_commands) |c| {
        if (std.mem.eql(u8, c.name, name)) break c.dirs_only;
    } else return null;

    // The argument starts at its first non-blank; a caret still in the
    // blanks completes from an empty argument right there.
    const arg_start = @min(caret, std.mem.indexOfNonePos(u8, line, name_end, " \t") orelse line.len);
    const word = line[arg_start..caret];
    const dp = pathcomplete.dirPrefix(word);
    return .{
        .seg_start = arg_start + dp.dir.len,
        .dir = dp.dir,
        .prefix = dp.prefix,
        .dirs_only = dirs_only,
    };
}

/// The directories among `matches`, for a `:cd`. Consumes `matches` (the
/// files' names are freed with it) and returns a new slice the caller
/// frees with `pathcomplete.freeMatches`.
pub fn keepDirs(alloc: std.mem.Allocator, matches: []pathcomplete.Match) ![]pathcomplete.Match {
    var dirs: std.ArrayList(pathcomplete.Match) = .empty;
    errdefer dirs.deinit(alloc);
    for (matches) |m| {
        if (m.is_dir) try dirs.append(alloc, m);
    }
    const out = try dirs.toOwnedSlice(alloc);
    for (matches) |m| {
        if (!m.is_dir) alloc.free(m.name);
    }
    alloc.free(matches);
    return out;
}

/// The text a pick puts in place of the segment: the name, plus `/` for a
/// directory so the next Tab goes straight into it. Caller owns it.
pub fn insertion(alloc: std.mem.Allocator, m: pathcomplete.Match) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ m.name, if (m.is_dir) "/" else "" });
}

/// The open popup: the candidates and which one is picked.
pub const Menu = struct {
    alloc: std.mem.Allocator,
    /// Sorted by name. Owned.
    matches: []pathcomplete.Match,
    /// Where on the `:` line the segment being completed starts.
    seg_start: usize,
    selected: usize = 0,
    /// The first match shown, for a list longer than the popup.
    top: usize = 0,

    /// Takes ownership of `matches`.
    pub fn init(alloc: std.mem.Allocator, matches: []pathcomplete.Match, seg_start: usize) Menu {
        return .{ .alloc = alloc, .matches = matches, .seg_start = seg_start };
    }

    pub fn deinit(self: *Menu) void {
        pathcomplete.freeMatches(self.alloc, self.matches);
    }

    pub fn count(self: *const Menu) usize {
        return self.matches.len;
    }

    pub fn current(self: *const Menu) ?pathcomplete.Match {
        if (self.selected >= self.matches.len) return null;
        return self.matches[self.selected];
    }

    /// The match `row` places down from the top of the visible window.
    pub fn visible(self: *const Menu, row: usize) ?pathcomplete.Match {
        const idx = self.top + row;
        if (idx >= self.matches.len) return null;
        return self.matches[idx];
    }

    /// Moves the pick, wrapping at both ends, and keeps it within `rows`.
    pub fn move(self: *Menu, delta: i64, rows: usize) void {
        const n = self.matches.len;
        if (n == 0) return;
        const cur: i64 = @intCast(self.selected);
        self.selected = @intCast(@mod(cur + delta, @as(i64, @intCast(n))));
        self.follow(rows);
    }

    /// Scrolls just enough that the pick is on screen.
    pub fn follow(self: *Menu, rows: usize) void {
        if (rows == 0) return;
        if (self.selected < self.top) self.top = self.selected;
        if (self.selected >= self.top + rows) self.top = self.selected + 1 - rows;
    }
};
