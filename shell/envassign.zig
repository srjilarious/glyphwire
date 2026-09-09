const std = @import("std");

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
/// `scanLeading` does the peeling; `validName` and `expandValue` are the
/// shared pieces the `export` builtin reuses from `shell/main.zig`.
///
/// Deliberately simple (see docs/decisions.md, Shell):
///   * A name is `[A-Za-z_][A-Za-z0-9_]*`. A word with an `=` whose left
///     side isn't a valid name is not an assignment -- scanning stops and
///     the caller runs the word as an ordinary command.
///   * Value expansion covers `$NAME`, `${NAME}` and a leading `~`, and
///     is *not* quote-context aware: the shell's word splitter has
///     already collapsed `'...'` / `"..."` / `\` by the time a value
///     reaches `expandValue`, so a `$NAME` that was written inside single
///     quotes still expands. There is no way to pass a literal `$`.
///     Accepted for v1.
///   * `$NAME` of an unset variable expands to the empty string, like
///     bash. A `$` that isn't followed by a well-formed name (or
///     `{name}`) is copied through literally.
///   * A leading `~` expands to `$HOME` only when it is `~` alone or
///     `~/...`; `~user` is left alone.

/// One parsed `NAME=VALUE`. Both fields are heap-owned by the allocator
/// passed to `scanLeading`; free a whole `Leading` with `freeLeading`.
pub const Assignment = struct {
    name: []const u8,
    /// Already run through `expandValue`.
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

/// Expands `$NAME`, `${NAME}` and a leading `~` in `value`, looking names
/// up in `env`. Returns an owned string (possibly empty). See the module
/// doc comment for the exact rules.
pub fn expandValue(
    alloc: std.mem.Allocator,
    value: []const u8,
    env: *const std.process.Environ.Map,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;

    // Leading `~` / `~/...` -> $HOME. Only at the very start, and only
    // when HOME is set (otherwise the `~` is left literal, like `cd`).
    if (value.len > 0 and value[0] == '~' and (value.len == 1 or value[1] == '/')) {
        if (env.get("HOME")) |home| {
            try out.appendSlice(alloc, home);
            i = 1;
        }
    }

    while (i < value.len) {
        const ch = value[i];
        if (ch != '$') {
            try out.append(alloc, ch);
            i += 1;
            continue;
        }

        // `${NAME}`
        if (i + 1 < value.len and value[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, value, i + 2, '}')) |close| {
                const name = value[i + 2 .. close];
                if (validName(name)) {
                    if (env.get(name)) |v| try out.appendSlice(alloc, v);
                    i = close + 1;
                    continue;
                }
            }
            // Malformed -- emit the `$` literally and carry on.
            try out.append(alloc, '$');
            i += 1;
            continue;
        }

        // `$NAME` -- the run of name characters after `$`, the first of
        // which must be a name-start character.
        var j = i + 1;
        while (j < value.len and (value[j] == '_' or std.ascii.isAlphanumeric(value[j]))) : (j += 1) {}
        if (j > i + 1 and (value[i + 1] == '_' or std.ascii.isAlphabetic(value[i + 1]))) {
            const name = value[i + 1 .. j];
            if (env.get(name)) |v| try out.appendSlice(alloc, v);
            i = j;
            continue;
        }

        // A lone `$`, or `$` followed by a digit / punctuation: literal.
        try out.append(alloc, '$');
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

/// Peels the leading `NAME=VALUE` run off `line`. Word boundaries follow
/// the same quote / escape rules as `shell/wordsplit.zig`; scanning stops
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

    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    // The first non-blank byte: where `rest` reverts to if the whole
    // leading run turns out not to be assignments.
    const first_word: usize = i;
    // Where `rest` starts if nothing more peels -- advanced past each
    // accepted assignment and its trailing blanks.
    var rest_start: usize = i;

    while (i < line.len) {
        const word_start = i;
        buf.clearRetainingCapacity();
        var hit_operator = false;

        // Collect one word.
        collect: while (i < line.len) {
            const ch = line[i];
            switch (ch) {
                ' ', '\t' => break :collect,
                '|', '&', ';', '<', '>', '(', ')' => {
                    hit_operator = true;
                    break :collect;
                },
                '\'' => {
                    i += 1;
                    while (i < line.len and line[i] != '\'') : (i += 1) try buf.append(alloc, line[i]);
                    if (i < line.len) i += 1; // closing quote
                },
                '"' => {
                    i += 1;
                    while (i < line.len and line[i] != '"') : (i += 1) {
                        if (line[i] == '\\' and i + 1 < line.len and
                            (line[i + 1] == '"' or line[i + 1] == '\\'))
                        {
                            i += 1;
                        }
                        try buf.append(alloc, line[i]);
                    }
                    if (i < line.len) i += 1; // closing quote
                },
                '\\' => {
                    i += 1;
                    if (i < line.len) {
                        try buf.append(alloc, line[i]);
                        i += 1;
                    } else {
                        try buf.append(alloc, '\\');
                    }
                },
                else => {
                    try buf.append(alloc, ch);
                    i += 1;
                },
            }
        }

        // An operator interrupting an already-started assignment run
        // (`A=1 | x`, `A=1; ls`, `A=1 && b`) -- abandon assignment
        // handling for the whole line and let the parser deal with it
        // (`A=1` becomes an ordinary, not-found command, as in a shell
        // with no assignment support). The per-pipeline-stage scoping
        // bash gives these isn't worth reproducing here.
        if (hit_operator and list.items.len > 0) {
            for (list.items) |a| {
                alloc.free(a.name);
                alloc.free(a.value);
            }
            list.clearRetainingCapacity();
            return .{
                .assignments = try list.toOwnedSlice(alloc),
                .rest = std.mem.trim(u8, line[first_word..], " \t"),
            };
        }

        // Only a word that ended at a clean boundary (whitespace or
        // end-of-line) is eligible: `FOO=bar|x` keeps `FOO=bar` with the
        // command, matching how odd that input is in bash.
        const eq = if (!hit_operator) std.mem.indexOfScalar(u8, buf.items, '=') else null;
        if (eq) |e| {
            const name = buf.items[0..e];
            if (validName(name)) {
                const name_owned = try alloc.dupe(u8, name);
                errdefer alloc.free(name_owned);
                const value_owned = try expandValue(alloc, buf.items[e + 1 ..], env);
                try list.append(alloc, .{ .name = name_owned, .value = value_owned });
                while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
                rest_start = i;
                continue;
            }
        }

        // Not an assignment: the command begins at this word.
        return .{
            .assignments = try list.toOwnedSlice(alloc),
            .rest = std.mem.trim(u8, line[word_start..], " \t"),
        };
    }

    return .{
        .assignments = try list.toOwnedSlice(alloc),
        .rest = std.mem.trim(u8, line[rest_start..], " \t"),
    };
}
