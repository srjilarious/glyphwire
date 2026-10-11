// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const wordsplit = @import("applib").wordsplit;

/// `NAME=VALUE` environment-variable assignments for glyphwire-shell.
///
/// Two callers:
///   * the `export` builtin, whose already-word-split arguments are each
///     a `NAME=VALUE` (set) or a bare `NAME` (mark-for-export) token;
///   * `dispatchLineText`, which peels the leading run of `NAME=VALUE`
///     words off a raw command line -- a bare run (`FOO=bar`) sets the
///     session environment, a run followed by a command
///     (`FOO=bar cmd args`) sets those names just for that line, exactly
///     as bash / fish do.
///
/// `scanLeading` does the peeling; `validName` is the piece the `export`
/// builtin reuses from `shell/main.zig`.
///
/// Deliberately simple:
///   * A name is `[A-Za-z_][A-Za-z0-9_]*`, written plainly (no quoting
///     inside it, as in bash). A word whose left side isn't a valid name
///     is not an assignment -- scanning stops and the caller runs the
///     word as an ordinary command.
///   * The value is read by `wordsplit.readWord`, the splitter every
///     command word goes through, so it gets the same quoting and the
///     same `$NAME` / `${NAME}` / leading-`~` expansion: `A='$x'` is the
///     literal `$x`, `A="$x"` and `A=$x` expand. `$NAME` of an unset
///     variable is empty, like bash.
/// One parsed `NAME=VALUE`. Both fields are heap-owned by the allocator
/// passed to `scanLeading`; free a whole `Leading` with `freeLeading`.
pub const Assignment = struct {
    name: []const u8,
    /// Unquoted and expanded.
    value: []const u8,
};

pub const Leading = struct {
    /// The peeled assignment run in written order. Empty when the line
    /// does not start with an assignment.
    assignments: []Assignment,
    /// Everything after the peeled run, leading blanks trimmed. A
    /// sub-slice of the `line` passed to `scanLeading` (not owned).
    /// Empty when the entire line was assignments.
    rest: []const u8,
};

pub fn freeLeading(alloc: std.mem.Allocator, leading: Leading) void {
    for (leading.assignments) |a| {
        alloc.free(a.name);
        alloc.free(a.value);
    }
    alloc.free(leading.assignments);
}

/// True when `name` is a POSIX-ish identifier: a leading letter or `_`,
/// then letters / digits / `_`. Also the exact set `std.process.Environ`
/// accepts for `put` (no `=`, no NUL).
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |ch, idx| {
        if (ch == '_' or std.ascii.isAlphabetic(ch)) continue;
        if (idx > 0 and std.ascii.isDigit(ch)) continue;
        return false;
    }
    return true;
}

/// Peels the leading `NAME=VALUE` run off `line`. Word boundaries follow
/// the same quote / escape rules as `applib/wordsplit.zig`; scanning stops
/// at the first word that is not a clean `NAME=VALUE`, or at an unquoted
/// shell operator (`| & ; < > ( )`), whichever comes first. Each peeled
/// value is `expandValue`'d against `env`.
pub fn scanLeading(
    alloc: std.mem.Allocator,
    line: []const u8,
    env: *const std.process.Environ.Map,
) std.mem.Allocator.Error!Leading {
    var list: std.ArrayList(Assignment) = .empty;
    errdefer {
        for (list.items) |a| {
            alloc.free(a.name);
            alloc.free(a.value);
        }
        list.deinit(alloc);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // The first non-blank byte: where `rest` reverts to if the whole
    // leading run turns out not to be assignments.
    const first_word = wordsplit.skipBlanks(line, 0);
    var i = first_word;

    while (i < line.len) {
        // An operator interrupting an already-started assignment run
        // (`A=1 | x`, `A=1; ls`, `A=1 && b`, `A=1>f`) abandons assignment
        // handling for the whole line and lets the parser deal with it
        // (`A=1` becomes an ordinary, not-found command, as in a shell
        // with no assignment support); the per-pipeline-stage scoping
        // bash gives these isn't worth reproducing here.
        if (wordsplit.isOperatorByte(line[i]) and list.items.len > 0) {
            for (list.items) |a| {
                alloc.free(a.name);
                alloc.free(a.value);
            }
            list.clearRetainingCapacity();
            return .{ .assignments = try list.toOwnedSlice(alloc), .rest = trimBlanks(line[first_word..]) };
        }

        const word_start = i;
        const name_end = wordsplit.nameEnd(line, i);
        if (name_end == i or name_end >= line.len or line[name_end] != '=') break;

        buf.clearRetainingCapacity();
        const w = try wordsplit.readWord(alloc, &buf, line, name_end + 1, .blanks_and_operators, .{ .env = env });

        // A first word ending right at an operator (`FOO=bar|x`) keeps
        // `FOO=bar` with the command, matching how odd that input is in
        // bash.
        if (w.end < line.len and wordsplit.isOperatorByte(line[w.end])) {
            if (list.items.len == 0) {
                return .{ .assignments = try list.toOwnedSlice(alloc), .rest = trimBlanks(line[word_start..]) };
            }
            i = w.end;
            continue; // the check at the top abandons the run
        }

        const name_owned = try alloc.dupe(u8, line[word_start..name_end]);
        errdefer alloc.free(name_owned);
        const value_owned = try alloc.dupe(u8, buf.items);
        try list.append(alloc, .{ .name = name_owned, .value = value_owned });
        i = wordsplit.skipBlanks(line, w.end);
    }

    // Everything from the first word that didn't peel (or the end).
    return .{ .assignments = try list.toOwnedSlice(alloc), .rest = trimBlanks(line[i..]) };
}

fn trimBlanks(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
