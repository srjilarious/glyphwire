const std = @import("std");

/// Pipeline / redirection / `&&` `||` `;` parser for glyphwire-shell.
///
/// `wordsplit.zig` is the word-level splitter (quotes, escapes, one flat
/// token list); this module is the layer above it that understands the
/// shell operators every POSIX-ish shell shares:
///
///   * `|`               -- pipeline: stdout of the left command becomes
///                          stdin of the right.
///   * `&&` / `||`        -- run the next pipeline only if the previous
///                          one succeeded (`&&`, exit 0) or failed
///                          (`||`, exit != 0). Left-associative, equal
///                          precedence -- `a && b || c` is `(a && b) || c`.
///   * `;`                -- unconditional sequence point; a trailing `;`
///                          is allowed and ignored.
///   * `<` `>` `>>`       -- stdin from / stdout to (truncate / append) a
///                          file.
///   * `2>` `2>>` `1>` `1>>` -- the same with an explicit source fd.
///   * `2>&1` / `1>&2`    -- point one fd at another.
///   * `&>` / `&>>`       -- stdout and stderr to one file (bash shorthand
///                          for `> file 2>&1`).
///
/// Deliberately *not* handled (see docs/decisions.md, Shell): background
/// `&` and job control, heredocs `<<` / here-strings `<<<`, `|&`, process
/// substitution `<(...)`, subshells `( ... )` / groups `{ ...; }`, and
/// arbitrary fd numbers (`3>&1`). A bare `&` or a `<<` is a parse error
/// with a message naming the unsupported construct, not silently
/// mis-parsed.
///
/// Operator recognition is quote-aware in the same way `wordsplit` is: a
/// `|`, `>`, `&&` etc. inside `'...'` / `"..."` or backslash-escaped is a
/// literal word byte, never an operator. Operators do not need
/// surrounding whitespace -- `ps aux|grep x`, `echo hi>out`, `a&&b` all
/// split the way bash splits them; a digit immediately before `>` / `<`
/// with no space is taken as the source-fd designator (`2>err`), matching
/// bash, but only when the pending word is *just* that digit.
///
/// The result tree is arena-backed: `Line` owns a `std.heap.Arena`, so
/// `line.deinit()` frees every word, redirect target and slice in one
/// call. A parse error returns `.{ .err = msg }` with `msg` duped into
/// the caller's allocator (the arena is already gone) and ready to print
/// straight onto the grid.

/// How a redirect rewires one fd of a command.
pub const RedirMode = enum {
    /// `< path`  -- open `path` read-only as fd 0.
    read,
    /// `> path` / `N> path`  -- create/truncate `path` as fd `fd`.
    write,
    /// `>> path` / `N>> path`  -- create/append `path` as fd `fd`.
    append,
    /// `N>&M`  -- make fd `fd` a dup of fd `dup_fd`; no `path`.
    dup,
};

/// One redirection on a `Command`, applied left to right (bash order, so
/// `> out 2>&1` and `2>&1 > out` differ).
pub const Redir = struct {
    /// The fd being redirected: 0 for `<`, 1 for `>` / `>>` / `&>`, 2 for
    /// `2>` / `2>>`, or whatever `N` precedes a `>` / `<`.
    fd: u8,
    mode: RedirMode,
    /// `mode == .dup` only: the fd `fd` is pointed at.
    dup_fd: u8 = 0,
    /// `mode != .dup` only: the target filename, fully unquoted. `~` and
    /// glob expansion are the executor's job, not done here.
    path: []const u8 = "",
    /// True when `path` came from quotes / a backslash escape, so the
    /// executor must not treat it as a glob (same rule as a command word).
    path_quoted: bool = false,
    /// `&>` / `&>>`: after opening `path` on fd 1, also make fd 2 a dup of
    /// fd 1. Ignored unless `fd == 1 and mode != .dup`.
    also_stderr: bool = false,
};

/// One command in a pipeline: a non-empty argv plus its redirections.
pub const Command = struct {
    /// argv, fully unquoted. Always at least one element.
    words: []const []const u8,
    /// `quoted[i]` marks `words[i]` as a literal string (from quotes or a
    /// backslash escape) that must not be glob-expanded. Same length as
    /// `words`.
    quoted: []const bool,
    redirs: []const Redir,
};

/// `cmd | cmd | ...` -- always at least one command.
pub const Pipeline = struct {
    commands: []const Command,
};

/// How a segment connects to the pipeline before it.
pub const Sep = enum {
    /// The first segment of the line.
    first,
    /// `&&` -- run only if the previous exit status was 0.
    and_then,
    /// `||` -- run only if the previous exit status was non-zero.
    or_else,
    /// `;` -- always run.
    semi,
};

pub const Segment = struct {
    sep: Sep,
    pipeline: Pipeline,
};

/// A parsed command line: `segments` in left-to-right order. Empty (zero
/// segments) for a blank / whitespace-only line -- the caller treats that
/// as "nothing to run". Owns an arena holding every string and slice it
/// points at.
pub const Line = struct {
    arena: std.heap.ArenaAllocator,
    segments: []const Segment,

    pub fn deinit(self: *Line) void {
        self.arena.deinit();
    }

    /// True when the line is a single bare command -- one segment, one
    /// pipeline stage, no redirections. `shell/main.zig` routes this
    /// shape through its original PTY-backed `runCommand` (interactive
    /// programs, the glyphwire handshake) and everything else through the
    /// pipe-based executor.
    pub fn isBareCommand(self: *const Line) bool {
        return self.segments.len == 1 and
            self.segments[0].pipeline.commands.len == 1 and
            self.segments[0].pipeline.commands[0].redirs.len == 0;
    }
};

pub const Parsed = union(enum) {
    ok: Line,
    /// A syntax error, phrased for the grid (no trailing newline).
    err: []const u8,
};

// --- lexer -----------------------------------------------------------------

const TokKind = enum { word, pipe, and_and, or_or, semi, redir };

const Tok = struct {
    kind: TokKind,
    /// `.word`: the unquoted text. Otherwise unused.
    text: []const u8 = "",
    /// `.word`: came from quotes / an escape.
    quoted: bool = false,
    /// `.redir` fields.
    fd: u8 = 0,
    rmode: RedirMode = .read,
    dup_fd: u8 = 0,
    also_stderr: bool = false,
};

const LexError = error{ OutOfMemory, Background, Heredoc, HerestringOrDup, BadDup };

/// Splits `line` into word / operator tokens. Mirrors `wordsplit`'s
/// quote and escape handling byte for byte; the only addition is that an
/// unquoted operator lexeme ends the current word and becomes its own
/// token.
fn lex(arena: std.mem.Allocator, line: []const u8) LexError![]const Tok {
    var toks: std.ArrayList(Tok) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_word = false;
    var cur_quoted = false;

    // Flushes the pending word (if any) as a token.
    const flush = struct {
        fn f(
            a: std.mem.Allocator,
            ts: *std.ArrayList(Tok),
            c: *std.ArrayList(u8),
            iw: *bool,
            q: *bool,
        ) !void {
            if (!iw.*) return;
            try ts.append(a, .{ .kind = .word, .text = try a.dupe(u8, c.items), .quoted = q.* });
            c.clearRetainingCapacity();
            iw.* = false;
            q.* = false;
        }
    }.f;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        switch (ch) {
            ' ', '\t', '\n', '\r' => {
                try flush(arena, &toks, &cur, &in_word, &cur_quoted);
            },
            '\'' => {
                in_word = true;
                cur_quoted = true;
                i += 1;
                while (i < line.len and line[i] != '\'') : (i += 1) {
                    try cur.append(arena, line[i]);
                }
            },
            '"' => {
                in_word = true;
                cur_quoted = true;
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '\\' and i + 1 < line.len and
                        (line[i + 1] == '"' or line[i + 1] == '\\'))
                    {
                        i += 1;
                    }
                    try cur.append(arena, line[i]);
                }
            },
            '\\' => {
                in_word = true;
                if (i + 1 < line.len) {
                    i += 1;
                    cur_quoted = true;
                    try cur.append(arena, line[i]);
                } else {
                    try cur.append(arena, '\\');
                }
            },
            '|' => {
                try flush(arena, &toks, &cur, &in_word, &cur_quoted);
                if (i + 1 < line.len and line[i + 1] == '|') {
                    try toks.append(arena, .{ .kind = .or_or });
                    i += 1;
                } else {
                    try toks.append(arena, .{ .kind = .pipe });
                }
            },
            ';' => {
                try flush(arena, &toks, &cur, &in_word, &cur_quoted);
                try toks.append(arena, .{ .kind = .semi });
            },
            '&' => {
                if (i + 1 < line.len and line[i + 1] == '&') {
                    try flush(arena, &toks, &cur, &in_word, &cur_quoted);
                    try toks.append(arena, .{ .kind = .and_and });
                    i += 1;
                } else if (i + 1 < line.len and line[i + 1] == '>') {
                    // `&>` / `&>>` -- stdout+stderr to one file.
                    try flush(arena, &toks, &cur, &in_word, &cur_quoted);
                    var mode: RedirMode = .write;
                    i += 1; // now on '>'
                    if (i + 1 < line.len and line[i + 1] == '>') {
                        mode = .append;
                        i += 1;
                    }
                    try toks.append(arena, .{
                        .kind = .redir,
                        .fd = 1,
                        .rmode = mode,
                        .also_stderr = true,
                    });
                } else {
                    return error.Background;
                }
            },
            '<' => {
                if (i + 1 < line.len and line[i + 1] == '<') return error.Heredoc;
                if (i + 1 < line.len and line[i + 1] == '&') return error.HerestringOrDup;
                try flush(arena, &toks, &cur, &in_word, &cur_quoted);
                try toks.append(arena, .{ .kind = .redir, .fd = 0, .rmode = .read });
            },
            '>' => {
                // A pending word that is exactly one digit and unquoted is
                // the source-fd designator (`2>err`); consume it instead
                // of flushing it as a word.
                var fd: u8 = 1;
                if (in_word and !cur_quoted and cur.items.len == 1 and
                    cur.items[0] >= '0' and cur.items[0] <= '9')
                {
                    fd = cur.items[0] - '0';
                    cur.clearRetainingCapacity();
                    in_word = false;
                } else {
                    try flush(arena, &toks, &cur, &in_word, &cur_quoted);
                }

                if (i + 1 < line.len and line[i + 1] == '&') {
                    // `N>&M` -- dup.
                    i += 1; // on '&'
                    if (i + 1 >= line.len or line[i + 1] < '0' or line[i + 1] > '9')
                        return error.BadDup;
                    i += 1; // on the digit
                    try toks.append(arena, .{
                        .kind = .redir,
                        .fd = fd,
                        .rmode = .dup,
                        .dup_fd = line[i] - '0',
                    });
                } else if (i + 1 < line.len and line[i + 1] == '>') {
                    i += 1;
                    try toks.append(arena, .{ .kind = .redir, .fd = fd, .rmode = .append });
                } else {
                    try toks.append(arena, .{ .kind = .redir, .fd = fd, .rmode = .write });
                }
            },
            else => {
                in_word = true;
                try cur.append(arena, ch);
            },
        }
    }
    try flush(arena, &toks, &cur, &in_word, &cur_quoted);

    return toks.toOwnedSlice(arena);
}

// --- parser --------------------------------------------------------------

/// Parses `line`. Never returns a Zig error other than `OutOfMemory`; a
/// syntax problem comes back as `.{ .err = <message> }`.
pub fn parse(alloc: std.mem.Allocator, line: []const u8) error{OutOfMemory}!Parsed {
    var arena = std.heap.ArenaAllocator.init(alloc);
    const a = arena.allocator();

    const toks = lex(a, line) catch |e| {
        arena.deinit();
        const msg = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Background => "background jobs (`&`) are not supported",
            error.Heredoc => "heredocs (`<<`) are not supported",
            error.HerestringOrDup => "`<<<` / `<&` are not supported",
            error.BadDup => "malformed redirect: expected a digit after `>&`",
        };
        return .{ .err = try alloc.dupe(u8, msg) };
    };

    var segments: std.ArrayList(Segment) = .empty;

    var idx: usize = 0;
    var next_sep: Sep = .first;
    while (true) {
        // Collect the tokens of one segment: everything up to the next
        // `&&` / `||` / `;` at pipeline top level.
        const seg_start = idx;
        while (idx < toks.len and toks[idx].kind != .and_and and
            toks[idx].kind != .or_or and toks[idx].kind != .semi)
        {
            idx += 1;
        }
        const seg_toks = toks[seg_start..idx];

        const sep_here = next_sep;
        const at_end = idx >= toks.len;
        const trailing_semi = !at_end and toks[idx].kind == .semi;

        if (seg_toks.len == 0) {
            // Empty segment: fine only as a bare trailing `;` (`ls ;`),
            // an error anywhere else (`| ls`, `ls && && x`, `;;`).
            if (sep_here == .first and at_end) break; // empty line
            if (sep_here == .semi and trailing_semi) {
                // `ls ; ;` -- collapse the run, keep going.
                idx += 1;
                next_sep = .semi;
                continue;
            }
            if (sep_here == .semi and at_end) break; // trailing `;`
            arena.deinit();
            const near = if (sep_here == .and_then) "&&" else if (sep_here == .or_else) "||" else "|";
            return .{ .err = try std.fmt.allocPrint(alloc, "syntax error near `{s}`", .{near}) };
        }

        const pipeline = parsePipeline(a, seg_toks) catch |e| switch (e) {
            error.OutOfMemory => {
                arena.deinit();
                return error.OutOfMemory;
            },
            error.EmptyStage => {
                arena.deinit();
                return .{ .err = try alloc.dupe(u8, "syntax error near `|`") };
            },
            error.MissingCommand => {
                arena.deinit();
                return .{ .err = try alloc.dupe(u8, "syntax error: redirect with no command") };
            },
            error.MissingTarget => {
                arena.deinit();
                return .{ .err = try alloc.dupe(u8, "syntax error: redirect with no target file") };
            },
        };
        try segments.append(a, .{ .sep = sep_here, .pipeline = pipeline });

        if (at_end) break;
        next_sep = switch (toks[idx].kind) {
            .and_and => .and_then,
            .or_or => .or_else,
            .semi => .semi,
            else => unreachable,
        };
        idx += 1;
    }

    return .{ .ok = .{ .arena = arena, .segments = try segments.toOwnedSlice(a) } };
}

const PipeError = error{ OutOfMemory, EmptyStage, MissingCommand, MissingTarget };

fn parsePipeline(a: std.mem.Allocator, seg_toks: []const Tok) PipeError!Pipeline {
    var commands: std.ArrayList(Command) = .empty;

    var start: usize = 0;
    var k: usize = 0;
    while (k <= seg_toks.len) : (k += 1) {
        if (k < seg_toks.len and seg_toks[k].kind != .pipe) continue;
        const cmd_toks = seg_toks[start..k];
        if (cmd_toks.len == 0) return error.EmptyStage;
        try commands.append(a, try parseCommand(a, cmd_toks));
        start = k + 1;
    }

    return .{ .commands = try commands.toOwnedSlice(a) };
}

fn parseCommand(a: std.mem.Allocator, cmd_toks: []const Tok) PipeError!Command {
    var words: std.ArrayList([]const u8) = .empty;
    var quoted: std.ArrayList(bool) = .empty;
    var redirs: std.ArrayList(Redir) = .empty;

    var j: usize = 0;
    while (j < cmd_toks.len) : (j += 1) {
        const t = cmd_toks[j];
        switch (t.kind) {
            .word => {
                try words.append(a, t.text);
                try quoted.append(a, t.quoted);
            },
            .redir => {
                var r: Redir = .{
                    .fd = t.fd,
                    .mode = t.rmode,
                    .dup_fd = t.dup_fd,
                    .also_stderr = t.also_stderr,
                };
                if (t.rmode != .dup) {
                    if (j + 1 >= cmd_toks.len or cmd_toks[j + 1].kind != .word)
                        return error.MissingTarget;
                    j += 1;
                    r.path = cmd_toks[j].text;
                    r.path_quoted = cmd_toks[j].quoted;
                }
                try redirs.append(a, r);
            },
            else => unreachable, // pipeline split already removed these
        }
    }

    if (words.items.len == 0) return error.MissingCommand;

    return .{
        .words = try words.toOwnedSlice(a),
        .quoted = try quoted.toOwnedSlice(a),
        .redirs = try redirs.toOwnedSlice(a),
    };
}
