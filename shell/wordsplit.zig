const std = @import("std");

/// Quote- and escape-aware splitter for glyphwire-shell prompt lines.
///
/// Deliberately minimal (see shell/main.zig's top doc comment on the
/// shell's scope): it recognizes
///
///   * single quotes  `'...'`  -- everything between them is literal,
///     backslash included; an embedded `'` cannot be escaped (same as
///     every POSIX shell);
///   * double quotes  `"..."`  -- also literal here, since this shell has
///     no `$`/backtick/`!` expansion for a backslash to protect against;
///     `\"` and `\\` are the only two escapes honoured inside them, every
///     other backslash is kept verbatim (matching bash);
///   * a backslash outside any quotes escapes the next byte (so
///     `my\ file` is one token `my file`); a trailing backslash at end of
///     line is kept literally.
///
/// An unterminated quote runs to end of line rather than erroring -- an
/// interactive line editor with no continuation prompt has nothing better
/// to do, and it matches what bash produces after printing its "unexpected
/// EOF" complaint.
///
/// Adjacent quoted and unquoted runs with no whitespace between them join
/// into a single token, e.g. `alias ll='ls -l'` splits to `alias` and
/// `ll=ls -l`, and `''` yields one empty token -- both the same as bash.
///
/// One split-out token.
pub const Arg = struct {
    /// The token text, with all quoting/escaping already removed.
    text: []const u8,
    /// True if any byte of the token came from inside `'...'` / `"..."`
    /// or was backslash-escaped. Such a token is a literal string and
    /// must never be treated as a glob pattern, matching bash: `echo
    /// '*'`, `echo "*"` and `echo \*` all print a literal `*`.
    quoted: bool,
};

/// Full splitter: returns owned `Arg`s (text + a "was quoted" flag).
/// Free with `freeArgs`. Empty / whitespace-only input yields a
/// zero-length slice. `split` is the text-only convenience wrapper.
pub fn splitArgs(alloc: std.mem.Allocator, line: []const u8) ![]Arg {
    var args: std.ArrayList(Arg) = .empty;
    errdefer {
        for (args.items) |a| alloc.free(a.text);
        args.deinit(alloc);
    }

    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(alloc);
    // Distinct from `cur.items.len != 0`: an explicit empty token (`''`)
    // has to survive too.
    var in_token = false;
    var cur_quoted = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            ' ', '\t' => {
                if (in_token) {
                    try args.append(alloc, .{ .text = try alloc.dupe(u8, cur.items), .quoted = cur_quoted });
                    cur.clearRetainingCapacity();
                    in_token = false;
                    cur_quoted = false;
                }
            },
            '\'' => {
                in_token = true;
                cur_quoted = true;
                i += 1;
                while (i < line.len and line[i] != '\'') : (i += 1) {
                    try cur.append(alloc, line[i]);
                }
                // `i` now sits on the closing quote (or line.len); the
                // outer loop's `i += 1` steps past it.
            },
            '"' => {
                in_token = true;
                cur_quoted = true;
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '\\' and i + 1 < line.len and
                        (line[i + 1] == '"' or line[i + 1] == '\\'))
                    {
                        i += 1;
                    }
                    try cur.append(alloc, line[i]);
                }
            },
            '\\' => {
                in_token = true;
                if (i + 1 < line.len) {
                    i += 1;
                    cur_quoted = true;
                    try cur.append(alloc, line[i]);
                } else {
                    try cur.append(alloc, '\\');
                }
            },
            else => {
                in_token = true;
                try cur.append(alloc, line[i]);
            },
        }
    }
    if (in_token) try args.append(alloc, .{ .text = try alloc.dupe(u8, cur.items), .quoted = cur_quoted });

    return args.toOwnedSlice(alloc);
}

pub fn freeArgs(alloc: std.mem.Allocator, args: []const Arg) void {
    for (args) |a| alloc.free(a.text);
    alloc.free(args);
}

/// Text-only splitter: quoting/escaping removed, "was quoted" flag
/// dropped. Returns an owned slice of owned token strings; free with
/// `freeTokens`.
pub fn split(alloc: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    const args = try splitArgs(alloc, line);
    defer alloc.free(args); // each `.text` is moved into `out`, not freed here
    errdefer for (args) |a| alloc.free(a.text);

    const out = try alloc.alloc([]const u8, args.len);
    for (args, 0..) |a, idx| out[idx] = a.text;
    return out;
}

pub fn freeTokens(alloc: std.mem.Allocator, tokens: []const []const u8) void {
    for (tokens) |t| alloc.free(t);
    alloc.free(tokens);
}

/// One `name=value` binding parsed out of an `alias` builtin line.
pub const AliasDef = struct { name: []const u8, value: []const u8 };

/// Parses an `alias NAME=VALUE` invocation straight from the raw prompt
/// line (the caller has already confirmed the first word is `alias`).
///
/// Rest-of-line value semantics, chosen deliberately over bash's
/// per-argument `name=value` splitting (see the shell feature discussion):
/// `NAME` is everything from the first non-space after `alias` up to the
/// first `=`, and `VALUE` is the entire remainder of the line. A single
/// matching pair of wrapping quotes around the trimmed value is stripped,
/// so `alias ll='ls -l'` and `alias ll=ls -l` both bind `ll` to the
/// two-word body `ls -l`. Surrounding (unquoted) whitespace on the value
/// is trimmed; quote it (`alias x=' ls '`) to keep it.
///
/// Returns null for a bare `alias` with no `NAME=` part -- the caller
/// treats that as "list all aliases".
pub fn parseAliasDef(line: []const u8) ?AliasDef {
    var s = std.mem.trimStart(u8, line, " \t");
    std.debug.assert(std.mem.startsWith(u8, s, "alias"));
    s = s["alias".len..];
    s = std.mem.trimStart(u8, s, " \t");
    if (s.len == 0) return null;

    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return null;
    const name = std.mem.trim(u8, s[0..eq], " \t");
    if (name.len == 0) return null;

    var value = std.mem.trim(u8, s[eq + 1 ..], " \t");
    if (value.len >= 2 and (value[0] == '\'' or value[0] == '"') and value[value.len - 1] == value[0]) {
        value = value[1 .. value.len - 1];
    }
    return .{ .name = name, .value = value };
}
