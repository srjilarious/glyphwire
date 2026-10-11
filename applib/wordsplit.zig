// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

/// Quote- and escape-aware splitter for glyphwire-shell prompt lines.
///
/// Deliberately minimal (see shell/main.zig's top doc comment on the
/// shell's scope): it recognizes
///
///   * whitespace -- space, tab, newline (`\n`) or carriage return
///     (`\r`) -- as a token separator; a run of it counts once, and
///     leading/trailing whitespace is ignored. A newline is no different
///     from a space here, so a multi-line paste (a copied file list, say)
///     splits into one argument per line rather than one unusable giant
///     argument;
///   * single quotes  `'...'`  -- everything between them is literal,
///     backslash and `$` included; an embedded `'` cannot be escaped
///     (same as every POSIX shell);
///   * double quotes  `"..."`  -- literal except for `$` expansion (see
///     below) and the four backslash escapes bash honours there: `\"`,
///     `\\`, `\$` and `` \` ``. Any other backslash is kept verbatim, so
///     `"a\nb"` is the four bytes `a\nb`, as in bash;
///   * a backslash outside any quotes escapes the next byte (so
///     `my\ file` is one token `my file`); a trailing backslash at end of
///     line is kept literally;
///   * a backslash immediately followed by a newline, outside single
///     quotes, is a line continuation: both bytes vanish, so a pasted
///     `curl -X POST \` / `  -d '{}' url` block is one command and
///     `ab\<newline>cd` one word `abcd`, exactly as in bash.
///
/// With an `Expansion` that carries an environment (the shell always
/// passes one for a typed line), two expansions happen during the split,
/// because only the splitter still knows which bytes were quoted:
///
///   * `$NAME`, `${NAME}` and `$?` -- unquoted or inside `"..."`, never
///     inside `'...'` or after a backslash. An unset name is empty. A `$`
///     not followed by one of those shapes (`$`, `$5`, `$(`) is literal.
///     The value is *not* re-split on whitespace (zsh / fish behaviour,
///     not bash's): `ls $DIR` is one argument even when `$DIR` holds a
///     space, which is what nearly everyone means. A word made only of
///     unquoted expansions that all came out empty disappears entirely
///     (`ls $UNSET` runs `ls` with no argument), the same as bash; quote
///     it (`"$UNSET"`) to keep an empty argument.
///   * a leading unquoted `~` alone or followed by `/` becomes `$HOME`,
///     as does one right after the `=` of a `NAME=` word. `'~/x'`, `"~"`
///     and `\~` stay literal.
///
/// Expanded text does not set `Arg.quoted`, so an unquoted `$DIR/*.txt`
/// still globs, like bash; inside double quotes the word is quoted anyway.
///
/// An unterminated quote runs to end of line rather than erroring -- the
/// interactive prompt never submits one (Enter continues the line instead,
/// see `needsContinuation`), and a script line that has one gets bash's
/// "everything to the end" reading.
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

/// What `$NAME` / `${NAME}` / `$?` and a leading `~` expand against while
/// a line is split. The zero value expands nothing -- `$` and `~` stay
/// literal -- for text that is not a command line being run (a test, an
/// alias definition being stored).
pub const Expansion = struct {
    /// Variable lookups and `$HOME` for `~`. Null disables both.
    env: ?*const std.process.Environ.Map = null,
    /// What `$?` becomes. Null leaves `$?` literal.
    last_status: ?u8 = null,
};

/// Where `readWord` stops: at whitespace only (`splitArgs`), or also at
/// the bytes `shell/parse.zig` treats as operators.
pub const Stop = enum { blanks, blanks_and_operators };

/// The operator bytes `parse.zig`'s lexer splits on outside quotes.
pub fn isOperatorByte(c: u8) bool {
    return c == '|' or c == '&' or c == ';' or c == '<' or c == '>';
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The length of the line continuation (`\` + `\n`, or `\` + `\r\n`)
/// starting at `i`, or 0 if there isn't one there.
fn continuationLen(line: []const u8, i: usize) usize {
    if (i + 1 >= line.len or line[i] != '\\') return 0;
    if (line[i + 1] == '\n') return 2;
    if (line[i + 1] == '\r' and i + 2 < line.len and line[i + 2] == '\n') return 3;
    return 0;
}

/// The offset of the first byte at or after `i` that is neither
/// whitespace nor a line continuation -- where the next word or operator
/// starts, or `line.len`.
pub fn skipBlanks(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len) {
        if (isBlank(line[i])) {
            i += 1;
            continue;
        }
        const cont = continuationLen(line, i);
        if (cont == 0) break;
        i += cont;
    }
    return i;
}

/// What `readWord` found.
pub const Word = struct {
    /// Offset just past the word: the whitespace or operator byte that
    /// ended it, or `line.len`.
    end: usize,
    /// False only for a word made entirely of unquoted expansions that
    /// came out empty (`$UNSET`), which bash drops rather than passing
    /// an empty argument.
    present: bool,
    /// Same meaning as `Arg.quoted`.
    quoted: bool,
    /// `'` or `"` when the line ran out inside that quote, else 0. Tab
    /// completion uses it to close the quote it completes inside.
    open_quote: u8,
};

/// Reads one word starting at `start` (a byte `skipBlanks` stopped on),
/// appending its unquoted, expanded text to `out`. The single
/// implementation of the quoting rules in the doc comment above;
/// `splitArgs`, `parse.zig`'s lexer, `envassign.scanLeading` and Tab
/// completion's word scan all go through it so they cannot drift apart.
pub fn readWord(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    start: usize,
    stop: Stop,
    exp: Expansion,
) std.mem.Allocator.Error!Word {
    var w: Word = .{ .end = start, .present = false, .quoted = false, .open_quote = 0 };
    var i = start;

    // Bash also expands a `~` straight after the `=` of a plainly
    // written `NAME=` word, so `export PATH=~/bin:$PATH` and
    // `CFG=~/c prog` work.
    const name_end = nameEnd(line, start);
    const assign_value: ?usize = if (name_end > start and name_end < line.len and line[name_end] == '=')
        name_end + 1
    else
        null;

    while (i < line.len) {
        const c = line[i];
        if (isBlank(c)) break;
        if (stop == .blanks_and_operators and isOperatorByte(c)) break;

        if (c == '~' and (i == start or i == assign_value) and tildeEnds(line, i + 1, stop)) {
            if (exp.env) |env| {
                if (env.get("HOME")) |home| {
                    try out.appendSlice(alloc, home);
                    w.present = true;
                    i += 1;
                    continue;
                }
            }
        }

        switch (c) {
            '\\' => {
                const cont = continuationLen(line, i);
                if (cont > 0) {
                    i += cont;
                } else if (i + 1 < line.len) {
                    try out.append(alloc, line[i + 1]);
                    w.present = true;
                    w.quoted = true;
                    i += 2;
                } else {
                    try out.append(alloc, '\\');
                    w.present = true;
                    i += 1;
                }
            },
            '\'' => {
                w.present = true;
                w.quoted = true;
                i += 1;
                while (i < line.len and line[i] != '\'') : (i += 1) try out.append(alloc, line[i]);
                if (i >= line.len) w.open_quote = '\'' else i += 1;
            },
            '"' => {
                w.present = true;
                w.quoted = true;
                i += 1;
                while (i < line.len and line[i] != '"') {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        const cont = continuationLen(line, i);
                        if (cont > 0) {
                            i += cont;
                            continue;
                        }
                        const n = line[i + 1];
                        if (n == '"' or n == '\\' or n == '$' or n == '`') {
                            try out.append(alloc, n);
                            i += 2;
                            continue;
                        }
                    }
                    if (line[i] == '$') {
                        if (try expandDollar(alloc, out, line, i, exp)) |next| {
                            i = next;
                            continue;
                        }
                    }
                    try out.append(alloc, line[i]);
                    i += 1;
                }
                if (i >= line.len) w.open_quote = '"' else i += 1;
            },
            '$' => {
                const before = out.items.len;
                if (try expandDollar(alloc, out, line, i, exp)) |next| {
                    if (out.items.len > before) w.present = true;
                    i = next;
                } else {
                    try out.append(alloc, '$');
                    w.present = true;
                    i += 1;
                }
            },
            else => {
                try out.append(alloc, c);
                w.present = true;
                i += 1;
            },
        }
    }

    w.end = i;
    return w;
}

/// Whether a `~` whose next byte is `line[i]` stands alone: `/`, the
/// end of the word, or the end of the line follows it (`~user` is not
/// supported).
fn tildeEnds(line: []const u8, i: usize, stop: Stop) bool {
    if (i >= line.len) return true;
    const c = line[i];
    return c == '/' or isBlank(c) or (stop == .blanks_and_operators and isOperatorByte(c));
}

/// Expands the `$` at `line[i]` into `out` when it starts `$NAME`,
/// `${NAME}` or `$?` and `exp` can resolve it, returning the offset just
/// past the expanded form. Null when the `$` is literal: no environment,
/// or not one of those shapes.
fn expandDollar(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    i: usize,
    exp: Expansion,
) std.mem.Allocator.Error!?usize {
    const env = exp.env orelse return null;
    if (i + 1 >= line.len) return null;
    const n = line[i + 1];

    if (n == '?') {
        const status = exp.last_status orelse return null;
        var buf: [3]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{status}) catch unreachable;
        try out.appendSlice(alloc, s);
        return i + 2;
    }

    if (n == '{') {
        const close = std.mem.indexOfScalarPos(u8, line, i + 2, '}') orelse return null;
        const name = line[i + 2 .. close];
        if (!isName(name)) return null;
        if (env.get(name)) |v| try out.appendSlice(alloc, v);
        return close + 1;
    }

    const name_end = nameEnd(line, i + 1);
    if (name_end == i + 1) return null;
    if (env.get(line[i + 1 .. name_end])) |v| try out.appendSlice(alloc, v);
    return name_end;
}

fn isNameStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}

fn isNameByte(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

/// The end of the variable name starting at `start` (`start` itself when
/// there is no name there).
pub fn nameEnd(line: []const u8, start: usize) usize {
    if (start >= line.len or !isNameStart(line[start])) return start;
    var j = start + 1;
    while (j < line.len and isNameByte(line[j])) : (j += 1) {}
    return j;
}

fn isName(s: []const u8) bool {
    return s.len > 0 and nameEnd(s, 0) == s.len;
}

/// Full splitter with no expansion: returns owned `Arg`s (text + a "was
/// quoted" flag). Free with `freeArgs`. Empty / whitespace-only input
/// yields a zero-length slice. `split` is the text-only convenience
/// wrapper; `splitArgsWith` expands.
pub fn splitArgs(alloc: std.mem.Allocator, line: []const u8) ![]Arg {
    return splitArgsWith(alloc, line, .{});
}

/// `splitArgs` with `$NAME` / `~` expanded against `exp`.
pub fn splitArgsWith(alloc: std.mem.Allocator, line: []const u8, exp: Expansion) ![]Arg {
    var args: std.ArrayList(Arg) = .empty;
    errdefer {
        for (args.items) |a| alloc.free(a.text);
        args.deinit(alloc);
    }

    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(alloc);

    var i = skipBlanks(line, 0);
    while (i < line.len) {
        cur.clearRetainingCapacity();
        const w = try readWord(alloc, &cur, line, i, .blanks, exp);
        if (w.present) try args.append(alloc, .{ .text = try alloc.dupe(u8, cur.items), .quoted = w.quoted });
        i = skipBlanks(line, w.end);
    }

    return args.toOwnedSlice(alloc);
}

/// What is still open at the end of some text: nothing, a quote, or a
/// trailing backslash waiting for the byte it escapes.
pub const OpenState = enum { none, single, double, backslash };

/// Scans `text` with the splitter's quoting rules and reports what is
/// still open at its end. The prompt's paste policy keeps a pasted
/// newline that lands in an open state (inside a quote, or right after a
/// `\`) and flattens the rest; `needsContinuation` builds on it.
pub fn openStateAt(text: []const u8) OpenState {
    return scanOpen(text).state;
}

const OpenScan = struct {
    state: OpenState,
    /// The last unquoted, unescaped non-blank byte, if any, and the one
    /// of the same kind before it -- enough to recognise a trailing `|`,
    /// `||` or `&&`.
    last: ?u8 = null,
    prev: ?u8 = null,
};

fn scanOpen(text: []const u8) OpenScan {
    var s: OpenScan = .{ .state = .none };
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (s.state) {
            .none => switch (c) {
                '\\' => {
                    const cont = continuationLen(text, i);
                    if (cont > 0) {
                        // A finished continuation is invisible, like
                        // whitespace; the loop's `+= 1` covers its last byte.
                        i += cont - 1;
                    } else if (i + 1 >= text.len) {
                        s.state = .backslash;
                    } else {
                        // An escaped byte: significant, never an operator.
                        s.prev = s.last;
                        s.last = 0;
                        i += 1;
                    }
                },
                '\'' => {
                    s.state = .single;
                    s.prev = s.last;
                    s.last = 0;
                },
                '"' => {
                    s.state = .double;
                    s.prev = s.last;
                    s.last = 0;
                },
                else => if (!isBlank(c)) {
                    s.prev = s.last;
                    s.last = c;
                },
            },
            .single => if (c == '\'') {
                s.state = .none;
            },
            .double => switch (c) {
                '\\' => i += 1,
                '"' => s.state = .none,
                else => {},
            },
            .backslash => unreachable,
        }
    }
    return s;
}

/// True when pressing Enter on `text` should start another input line
/// instead of running it, the way bash shows its `>` prompt: a quote is
/// still open, the text ends in a backslash (an explicit continuation),
/// or the last thing typed is an unquoted `|`, `||` or `&&` that still
/// needs its right-hand side.
pub fn needsContinuation(text: []const u8) bool {
    const s = scanOpen(text);
    if (s.state != .none) return true;
    const last = s.last orelse return false;
    if (last == '|') return true;
    return last == '&' and s.prev == '&';
}

pub fn freeArgs(alloc: std.mem.Allocator, args: []const Arg) void {
    for (args) |a| alloc.free(a.text);
    alloc.free(args);
}

/// Wraps `s` in single quotes so `splitArgs` reproduces it as exactly one
/// literal token no matter what spaces or shell metacharacters it holds --
/// the inverse of the splitter, used when the shell builds a command line
/// from a value it didn't get from the user typing it (a clicked
/// `glyphwire-ls` entry's path, see `Prompt.activateSelectionAt`).
///
/// An embedded `'` is emitted as `'\''` -- close the quote, a
/// backslash-escaped literal quote, reopen -- the standard POSIX idiom.
/// This shell's splitter round-trips it because a backslash outside quotes
/// escapes the next byte and adjacent quoted/unquoted runs join into one
/// token. Caller owns the returned bytes.
pub fn quoteArg(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');

    return out.toOwnedSlice(alloc);
}

/// Bytes that can appear in a shell word with no quoting at all: the
/// unreserved set every POSIX shell (and `shlex.quote`) leaves alone.
/// Anything outside it -- whitespace, a quote, a glob or shell
/// metacharacter, a non-ASCII byte -- forces quoting.
const plain_word_extra = "@%+=:,./_-";

fn isPlainByte(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        std.mem.indexOfScalar(u8, plain_word_extra, c) != null;
}

fn isPlainWord(s: []const u8) bool {
    if (s.len == 0) return false; // the empty string must become `''`
    for (s) |c| {
        if (!isPlainByte(c)) return false;
    }
    return true;
}

/// Backslash-escapes each byte of `s` that `splitArgs` (or `parse.zig`'s
/// operator lexer, which replicates the same quote/escape rules) would
/// otherwise treat specially: whitespace, a quote character, a literal
/// backslash, a glob metacharacter, or an operator byte like `|`/`&`/`;`.
/// E.g. `My File (1).txt` -> `My\ File\ \(1\).txt`.
///
/// Non-ASCII bytes pass through untouched: none of them is special to the
/// splitter, and escaping byte by byte would put a `\` between a UTF-8
/// lead byte and its continuation bytes. The splitter would still strip
/// those back out, so the command ran, but the line editor's buffer (and
/// the history entry recorded from it) was no longer valid UTF-8 and
/// drew as nothing -- a Tab-completed `週刊少年ジャンプ.cbz` vanished from
/// the prompt.
///
/// Unlike `quoteArg`/`quoteArgIfNeeded`, this never wraps the result in
/// quotes, so it's safe to append onto a prefix the user already typed
/// unescaped -- Tab completion's job (`complete.candidateSuffix`,
/// `shell/main.zig`'s `doComplete`) is inserting only the *new* suffix of
/// a filename into the middle of a word, not replacing the whole word.
/// Caller owns the returned bytes.
pub fn escapeSpecial(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        if (c < 0x80 and !isPlainByte(c)) try out.append(alloc, '\\');
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

/// Like `quoteArg`, but only wraps `s` when it actually needs it: a path
/// made entirely of "plain word" bytes (`isPlainWord`) is returned as a
/// bare owned dupe, everything else goes through `quoteArg`. Used to build
/// clipboard text from marked `ls` paths -- an ordinary path stays
/// readable, one with a space or a metacharacter still pastes back as a
/// single token. Caller owns the returned bytes; free with `alloc` either
/// way.
pub fn quoteArgIfNeeded(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    if (isPlainWord(s)) return alloc.dupe(u8, s);
    return quoteArg(alloc, s);
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
