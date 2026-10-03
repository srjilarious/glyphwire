// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! tree-sitter syntax highlighting shared by zoe and gw-grep: a registry
//! that `dlopen`s language parsers at runtime, and a `Highlighter` that
//! keeps a parse tree for a piece of source text and turns it into
//! per-line colour spans.
//!
//! **No grammar is compiled into any program.** A "language" is a
//! directory on the grammar search path holding a `parser.so` -- a
//! standalone tree-sitter parser shared library exporting
//! `tree_sitter_<name>` -- and a `highlights.scm` query. Adding a
//! language is dropping such a directory next to the others. The
//! programs link only libtree-sitter itself (the parse runtime and the
//! query engine) -- the grammars are data.
//!
//! **Highlighting is derived state, not editor state.** The highlighter
//! takes plain bytes and knows nothing about zoe's `Buffer`. zoe's
//! `Buffer` keeps a small journal of the byte/point ranges it mutated,
//! which zoe converts to `Edit`s and replays onto the retained parse
//! tree before each reparse, so an edit is an incremental `Tree.edit` +
//! reparse against the old tree, not a whole-buffer parse. A full parse
//! is still the fallback (first parse, language switch, a journal that
//! overflowed). gw-grep only ever does the full parse, once per file.
//!
//! **A full parse is staged.** `beginParse` gives it a small time budget
//! through tree-sitter's progress callback; a file that doesn't finish
//! in time gets a throwaway parse of just its first screens so they draw
//! coloured, while the real parse stays parked in `parser` and
//! `continueParse` resumes it in slices between UI events. No threads.
//!
//! **Injected languages.** After the primary parse, `injections.scm` (if
//! the grammar dir ships one) is run to find embedded regions -- a
//! fenced code block in Markdown, the `(inline)` span inside a Markdown
//! paragraph -- and each region is parsed with its own grammar over just
//! its byte ranges (`Parser.setIncludedRanges`). The child trees are
//! flat in `Highlighter.injections`, ordered shallowest-first, and
//! `lineSpans` paints them over the top of the primary layer so a deeper
//! layer's colour wins the bytes it covers. Injection recurses up to
//! `max_injection_depth` (Markdown block -> markdown_inline -> html).
//! Child trees survive an incremental reparse: the edit is applied to
//! them too, the injection query re-runs only over what changed, and only
//! a region an edit landed in is reparsed (against its own old tree). A
//! big Markdown file has a child tree per paragraph; rebuilding them all
//! per keystroke was most of what typing in one cost.
//!
//! **The text is read, not copied.** Parses and predicate checks read
//! through a `TextSource`, so zoe hands over its gap buffer as-is.
//! Only a whole-buffer parse takes a snapshot, because a staged one
//! reads it across many UI turns.
//!
//! **Spans come a run of lines at a time.** `linesSpans` runs one query
//! per layer over a whole run of lines; a query descends from the root
//! to reach its range, and in a big file that descent is most of what
//! a one-line query costs.
//!
//! Deliberate limitations:
//!   - No `locals.scm` (so no scope-aware local/parameter distinction).
//!   - Every content region of a given injected language is parsed on
//!     its own; there is no `injection.combined` handling.
//!   - Query predicates `#eq?` / `#not-eq?` / `#any-of?` / `#not-any-of?`
//!     are evaluated; a pattern carrying any other test predicate
//!     (`#match?`, `#lua-match?`, ...) is disabled wholesale rather than
//!     applied unconditionally, so we under-highlight instead of mis-
//!     highlighting.

const std = @import("std");
const ts = @import("tree_sitter");
const glyphwire = @import("glyphwire");
const Color = glyphwire.Color;

/// How many times injection recursion nests before it stops: a Markdown
/// block injecting `markdown_inline`, which itself injects `html`, is
/// depth 2. Past this a deeply self-injecting grammar just stops adding
/// layers.
pub const max_injection_depth: u8 = 3;

/// A half-open buffer byte range. `reparseIncremental` returns these for
/// the lines whose highlighting may have moved, so `ui.zig` can repaint
/// just those rows instead of the whole pane.
pub const ByteRange = struct { start: usize, end: usize };

/// A zero-based line and byte column, as tree-sitter counts them.
pub const Point = struct { line: usize = 0, col: usize = 0 };

/// One applied mutation, in the shape tree-sitter's `TSInputEdit` wants:
/// byte offsets and points for the edit's start, its old end and its new
/// end. zoe builds these from its `Buffer`'s edit journal and hands them
/// to `applyEdit`.
pub const Edit = struct {
    start_byte: usize,
    old_end_byte: usize,
    new_end_byte: usize,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};

fn pointOf(p: Point) ts.Point {
    return .{ .row = @intCast(p.line), .column = @intCast(p.col) };
}

/// How long one slice of a staged parse (`beginParse` / `continueParse`)
/// may run before it gives control back to the event loop. The parser
/// polls this through tree-sitter's progress callback, a few hundred
/// parse operations apart, so a slice overshoots by at most that much.
pub const ParseBudget = union(enum) {
    /// Wall time on `io`'s awake clock, counted from the start of the
    /// slice. What `ui.zig` uses.
    time: struct { io: std.Io, ms: i64 },
    /// Stop at the parser's `n`th progress check, whatever the clock
    /// says. Deterministic, which is what the tests need; `0` cancels at
    /// the very first check.
    checks: u32,
};

/// What a staged parse step left behind.
pub const ParseProgress = enum {
    /// The whole buffer is parsed; `tree` covers all of it.
    done,
    /// The budget ran out first. `tree` (if any) is the provisional
    /// prefix parse, and `continueParse` picks the full one up again.
    pending,
};

// Declared here rather than through the binding's `parseWithOptions`:
// zig-tree-sitter types the progress callback as taking `TSParseState`
// by value, but libtree-sitter calls it with a *pointer* to one, so the
// binding's callback would read its payload out of the wrong register.
const TsParseOptions = extern struct {
    payload: ?*anyopaque = null,
    progress_callback: *const fn (state: *ts.Parser.State) callconv(.c) bool,
};
extern fn ts_parser_parse_with_options(
    self: *ts.Parser,
    old_tree: ?*const ts.Tree,
    input: ts.Input,
    options: TsParseOptions,
) ?*ts.Tree;

/// One running slice of a `ParseBudget` -- the progress callback's
/// payload. `fired` records that it was the budget that stopped the
/// parse, as opposed to the parse failing.
const ParseSlice = struct {
    budget: ParseBudget,
    deadline: std.Io.Timestamp = .zero,
    checks_left: u32 = 0,
    fired: bool = false,

    fn start(budget: ParseBudget) ParseSlice {
        return switch (budget) {
            .time => |t| .{
                .budget = budget,
                .deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromMilliseconds(t.ms)),
            },
            .checks => |n| .{ .budget = budget, .checks_left = n },
        };
    }

    fn expired(self: *ParseSlice) bool {
        switch (self.budget) {
            .time => |t| return std.Io.Clock.awake.now(t.io).compare(.gte, self.deadline),
            .checks => {
                if (self.checks_left == 0) return true;
                self.checks_left -= 1;
                return false;
            },
        }
    }

    /// Parses `src` with `parser` under this slice's budget, resuming
    /// whatever parse `parser` has parked. Null when stopped (see
    /// `fired`) or failed.
    fn parse(self: *ParseSlice, parser: *ts.Parser, src: *const TextSource) ?*ts.Tree {
        const input = src.input();
        const opts: TsParseOptions = .{ .payload = self, .progress_callback = budgetExpired };
        return ts_parser_parse_with_options(parser, null, input, opts);
    }
};

fn budgetExpired(state: *ts.Parser.State) callconv(.c) bool {
    const slice: *ParseSlice = @ptrCast(@alignCast(state.payload.?));
    if (slice.expired()) slice.fired = true;
    return slice.fired;
}

/// The oldest grammar ABI libtree-sitter here can parse. A `parser.so`
/// generated by a newer tree-sitter CLI than the runtime is rejected
/// with a clear message rather than crashing mid-parse.
pub const min_abi_version = ts.MIN_COMPATIBLE_LANGUAGE_VERSION;
pub const max_abi_version = ts.LANGUAGE_VERSION;

/// A run of one colour within a line, as byte offsets relative to the
/// line's first byte (its newline excluded). Non-overlapping and sorted
/// by `start`; a gap between spans means "the default text colour".
pub const Span = struct {
    start: usize,
    end: usize,
    color: Color,
};

/// Longest single line we bother to highlight. Past this the per-line
/// paint buffer is the dominant cost and a line that long is almost
/// always minified or generated anyway -- it renders in the plain
/// colour.
const max_highlight_line: usize = 1 << 15;

// ── Theme ───────────────────────────────────────────────────────────────

/// Maps a tree-sitter highlight capture name to a foreground colour: a
/// reference to the theme role of the same name (`keyword`, `string`,
/// ...), which the host resolves -- so a theme switch recolours code
/// without a re-highlight.
///
/// Capture names are dotted and hierarchical (`string.special.key`); a
/// name with no colour of its own falls back to its prefix
/// (`string.special.key` -> `string.special` -> `string`). `null` for a
/// group means "don't colour it" -- the text keeps the pane's default.
pub const Theme = struct {
    colors: std.EnumArray(Group, ?Color),

    pub const Group = enum {
        comment,
        keyword,
        string,
        string_escape,
        string_special,
        escape,
        number,
        boolean,
        character,
        constant,
        constant_builtin,
        function,
        function_builtin,
        type,
        type_builtin,
        constructor,
        operator,
        property,
        variable,
        variable_builtin,
        variable_parameter,
        module,
        label,
        attribute,
        tag,
        punctuation,
        punctuation_special,
        text_title,
        text_literal,
        text_uri,
        text_reference,
    };

    /// The dotted capture names grammars actually emit, mapped to a
    /// group. `colorFor` walks a name down to its prefixes against this.
    const name_to_group = std.StaticStringMap(Group).initComptime(.{
        .{ "comment", .comment },
        .{ "keyword", .keyword },
        .{ "string", .string },
        .{ "string.escape", .string_escape },
        .{ "string.special", .string_special },
        .{ "escape", .escape },
        .{ "number", .number },
        .{ "float", .number },
        .{ "boolean", .boolean },
        .{ "character", .character },
        .{ "constant", .constant },
        .{ "constant.builtin", .constant_builtin },
        .{ "function", .function },
        .{ "function.builtin", .function_builtin },
        .{ "constructor", .constructor },
        .{ "type", .type },
        .{ "type.builtin", .type_builtin },
        .{ "operator", .operator },
        .{ "property", .property },
        .{ "field", .property },
        .{ "variable", .variable },
        .{ "variable.builtin", .variable_builtin },
        .{ "variable.parameter", .variable_parameter },
        .{ "variable.member", .property },
        .{ "parameter", .variable_parameter },
        .{ "module", .module },
        .{ "namespace", .module },
        .{ "import", .keyword },
        .{ "label", .label },
        .{ "attribute", .attribute },
        .{ "tag", .tag },
        .{ "punctuation", .punctuation },
        .{ "punctuation.special", .punctuation_special },
        .{ "text.title", .text_title },
        .{ "title", .text_title },
        .{ "text.literal", .text_literal },
        .{ "text.uri", .text_uri },
        .{ "text.reference", .text_reference },
    });

    /// Every group as its role, except the two a theme leaves as plain
    /// text by default -- `variable` and `punctuation` -- which stay
    /// uncoloured (no span at all) unless `t` gives them a colour of
    /// their own: colouring every identifier and bracket is noise, and a
    /// span per identifier is a lot of spans.
    pub fn fromTheme(t: *const glyphwire.theme.Theme) Theme {
        var out = Theme{ .colors = std.EnumArray(Group, ?Color).initFill(null) };
        inline for (comptime std.enums.values(Group)) |g| {
            const r = @field(glyphwire.theme.Role, @tagName(g));
            const plain = switch (t.roles.get(r)) {
                .role => |to| to == .fg,
                else => false,
            };
            out.colors.set(g, if (plain) null else Color.role(r));
        }
        return out;
    }

    /// `fromTheme` over the `default` theme.
    pub fn initDefault() Theme {
        const t = glyphwire.theme.initDefault();
        return fromTheme(&t);
    }

    /// Override one group by its (undotted) name, e.g. `set("keyword",
    /// ...)`. An unknown name is ignored. Used by the Lua config.
    pub fn setByName(self: *Theme, name: []const u8, color: Color) bool {
        const g = name_to_group.get(name) orelse return false;
        self.colors.set(g, color);
        return true;
    }

    /// The colour for a capture name, or `null` for "leave it alone".
    pub fn colorFor(self: *const Theme, capture: []const u8) ?Color {
        var name = capture;
        while (true) {
            if (name_to_group.get(name)) |g| return self.colors.get(g);
            const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
            name = name[0..dot];
        }
    }
};

// ── Grammar registry ────────────────────────────────────────────────────

/// One `dlopen`ed grammar. The library and language pointer live for the
/// process -- tree-sitter language pointers must outlive every tree and
/// query built from them, and a program only ever loads a grammar once, so it
/// is never closed.
pub const LoadedGrammar = struct {
    lib: std.DynLib,
    language: *const ts.Language,
    /// `highlights.scm` source, null-terminated, owned by the registry.
    highlights: [:0]u8,
    /// `injections.scm` source if the grammar dir had one, else null.
    /// Null-terminated, owned by the registry.
    injections: ?[:0]u8 = null,

    fn freeSources(self: *LoadedGrammar, alloc: std.mem.Allocator) void {
        alloc.free(self.highlights);
        if (self.injections) |inj| alloc.free(inj);
    }
};

/// Extension-to-grammar mapping, from the built-in defaults plus the Lua
/// config. `extensions` entries include the leading dot.
pub const LangDef = struct {
    name: []const u8,
    extensions: []const []const u8,
    /// The marker a line comment starts with (`//`, `#`), for zoe's
    /// Ctrl+/. Null for a language without one (JSON, Markdown), and for a
    /// config entry that doesn't say -- `lineCommentFor` then falls back
    /// to whatever another entry of the same name gives.
    line_comment: ?[]const u8 = null,
};

/// The grammars `build.zig` compiles and installs. A config can add
/// more or remap these.
pub const default_langs = [_]LangDef{
    .{ .name = "zig", .extensions = &.{ ".zig", ".zon" }, .line_comment = "//" },
    .{ .name = "json", .extensions = &.{ ".json", ".jsonc" } },
    .{ .name = "c", .extensions = &.{ ".c", ".h" }, .line_comment = "//" },
    .{ .name = "python", .extensions = &.{ ".py", ".pyi" }, .line_comment = "#" },
    .{ .name = "toml", .extensions = &.{".toml"}, .line_comment = "#" },
    .{ .name = "markdown", .extensions = &.{ ".md", ".markdown" } },
    // glyphwire's own configs are `X.conf.lua`, so `.lua` already covers
    // them and `.conf` is left to whoever actually owns it.
    .{ .name = "lua", .extensions = &.{".lua"}, .line_comment = "--" },
    .{ .name = "bash", .extensions = &.{ ".sh", ".bash", ".zsh" }, .line_comment = "#" },
};

/// The line-comment marker for `path`: the language its extension maps to
/// in `langs` (first match wins, as for highlighting), then the first
/// entry of that name that gives a marker -- so a config entry that only
/// re-claims extensions for `c` still comments with `//`. Null when no
/// language claims the file or the language has no line comment.
pub fn lineCommentFor(langs: []const LangDef, path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return null;
    var name: ?[]const u8 = null;
    outer: for (langs) |l| {
        for (l.extensions) |e| {
            if (std.ascii.eqlIgnoreCase(e, ext)) {
                name = l.name;
                break :outer;
            }
        }
    }
    const lang = name orelse return null;
    for (langs) |l| {
        if (std.mem.eql(u8, l.name, lang)) {
            if (l.line_comment) |m| return m;
        }
    }
    return null;
}

/// The grammar directories to search, highest priority first:
///   1. `extra` (from `config.grammar_dirs`),
///   2. `$GLYPHWIRE_ZOE_GRAMMAR_DIR` (`:`-separated -- what `zig build`
///      points at the just-installed grammars),
///   3. `$XDG_CONFIG_HOME/glyphwire/zoe/grammars` (or `~/.config/...`),
///   4. `$XDG_DATA_HOME/glyphwire/grammars` (or `~/.local/share/...`),
///   5. `<exe dir>/../share/glyphwire/grammars` (an installed tree).
///
/// Every element is owned by `alloc`; free each, then the slice. Missing
/// env vars just drop their entry.
pub fn searchDirs(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    extra: []const []const u8,
) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dirs.items) |d| alloc.free(d);
        dirs.deinit(alloc);
    }

    for (extra) |d| try dirs.append(alloc, try alloc.dupe(u8, d));

    if (environ.get("GLYPHWIRE_ZOE_GRAMMAR_DIR")) |v| {
        var it = std.mem.tokenizeScalar(u8, v, ':');
        while (it.next()) |part| try dirs.append(alloc, try alloc.dupe(u8, part));
    }

    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) try dirs.append(alloc, try std.fs.path.join(alloc, &.{ xdg, "glyphwire", "zoe", "grammars" }));
    } else if (environ.get("HOME")) |home| {
        try dirs.append(alloc, try std.fs.path.join(alloc, &.{ home, ".config", "glyphwire", "zoe", "grammars" }));
    }

    if (environ.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) try dirs.append(alloc, try std.fs.path.join(alloc, &.{ xdg, "glyphwire", "grammars" }));
    } else if (environ.get("HOME")) |home| {
        try dirs.append(alloc, try std.fs.path.join(alloc, &.{ home, ".local", "share", "glyphwire", "grammars" }));
    }

    if (std.process.executableDirPathAlloc(io, alloc)) |exe_dir| {
        defer alloc.free(exe_dir);
        try dirs.append(alloc, try std.fs.path.join(alloc, &.{ exe_dir, "..", "share", "glyphwire", "grammars" }));
    } else |_| {}

    return dirs.toOwnedSlice(alloc);
}

pub const Registry = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Grammar directories, highest priority first. Owned.
    search_dirs: []const []const u8,
    /// Extension mapping, highest priority first (first match wins).
    /// Owned; strings borrowed from whatever built it (config arena or
    /// `default_langs`).
    langs: []const LangDef,
    /// name -> loaded grammar. Keys owned; values are boxed so the
    /// pointer `get` hands back stays valid across a later `get` that
    /// resizes the map.
    loaded: std.StringHashMapUnmanaged(*LoadedGrammar) = .empty,
    /// Names we tried and couldn't load, so a miss is logged once, not
    /// every keystroke. Keys owned.
    failed: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        search_dirs: []const []const u8,
        langs: []const LangDef,
    ) Registry {
        return .{ .alloc = alloc, .io = io, .search_dirs = search_dirs, .langs = langs };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.loaded.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.freeSources(self.alloc);
            // e.value_ptr.*.lib is intentionally not closed (see LoadedGrammar).
            self.alloc.destroy(e.value_ptr.*);
            self.alloc.free(e.key_ptr.*);
        }
        self.loaded.deinit(self.alloc);

        var fit = self.failed.keyIterator();
        while (fit.next()) |k| self.alloc.free(k.*);
        self.failed.deinit(self.alloc);
    }

    /// The grammar name for a file path, matched on its extension
    /// (case-insensitively). `null` when nothing maps.
    pub fn nameForPath(self: *const Registry, path: []const u8) ?[]const u8 {
        const ext = std.fs.path.extension(path);
        if (ext.len == 0) return null;
        for (self.langs) |l| {
            for (l.extensions) |e| {
                if (std.ascii.eqlIgnoreCase(e, ext)) return l.name;
            }
        }
        return null;
    }

    /// Spellings an `injections.scm` may use for a language that our
    /// grammar directories know under another name.
    const lang_aliases = std.StaticStringMap([]const u8).initComptime(.{
        .{ "markdown.inline", "markdown_inline" },
        .{ "md", "markdown" },
        .{ "py", "python" },
        .{ "py3", "python" },
        // What a Markdown code fence is actually labelled, nine times in
        // ten, when it holds shell.
        .{ "sh", "bash" },
        .{ "shell", "bash" },
        .{ "zsh", "bash" },
    });

    /// The grammar-directory name for a possibly-aliased language name.
    pub fn resolveAlias(name: []const u8) []const u8 {
        return lang_aliases.get(name) orelse name;
    }

    /// The loaded grammar for `name`, `dlopen`ing it on first use.
    /// `null` (logged once) when no directory on the search path has a
    /// usable `parser.so` + `highlights.scm` for it. `name` is resolved
    /// through `resolveAlias` first, so an injection query naming
    /// `markdown.inline` finds the `markdown_inline` directory.
    pub fn get(self: *Registry, raw_name: []const u8) ?*LoadedGrammar {
        const name = resolveAlias(raw_name);
        if (self.loaded.get(name)) |g| return g;
        if (self.failed.contains(name)) return null;

        if (self.load(name)) |g| {
            var loaded = g;
            const box = self.alloc.create(LoadedGrammar) catch {
                loaded.freeSources(self.alloc);
                loaded.lib.close();
                return null;
            };
            box.* = loaded;
            const key = self.alloc.dupe(u8, name) catch {
                box.freeSources(self.alloc);
                box.lib.close();
                self.alloc.destroy(box);
                return null;
            };
            self.loaded.put(self.alloc, key, box) catch {
                self.alloc.free(key);
                box.freeSources(self.alloc);
                box.lib.close();
                self.alloc.destroy(box);
                return null;
            };
            return box;
        } else |err| {
            std.log.warn("syntax: no usable '{s}' grammar on the search path ({t})", .{ name, err });
            const key = self.alloc.dupe(u8, name) catch return null;
            self.failed.put(self.alloc, key, {}) catch self.alloc.free(key);
            return null;
        }
    }

    const LoadError = error{ NotFound, BadAbi, OutOfMemory };

    fn load(self: *Registry, name: []const u8) LoadError!LoadedGrammar {
        const so_names = [_][]const u8{
            "parser.so",
            // `build.zig` installs the artifact under its own name.
            std.fmt.allocPrint(self.alloc, "libtree-sitter-{s}.so", .{name}) catch return error.OutOfMemory,
            std.fmt.allocPrint(self.alloc, "{s}.so", .{name}) catch return error.OutOfMemory,
        };
        defer self.alloc.free(so_names[1]);
        defer self.alloc.free(so_names[2]);

        const sym = symbolName(self.alloc, name) catch return error.OutOfMemory;
        defer self.alloc.free(sym);
        const LangFn = *const fn () callconv(.c) *const ts.Language;

        for (self.search_dirs) |dir| {
            for (so_names) |so| {
                const so_path = std.fs.path.join(self.alloc, &.{ dir, name, so }) catch return error.OutOfMemory;
                defer self.alloc.free(so_path);

                var lib = std.DynLib.open(so_path) catch continue;

                const lang_fn = lib.lookup(LangFn, sym) orelse {
                    lib.close();
                    continue;
                };
                const language = lang_fn();

                const abi = language.abiVersion();
                if (abi < ts.MIN_COMPATIBLE_LANGUAGE_VERSION or abi > ts.LANGUAGE_VERSION) {
                    std.log.warn(
                        "syntax: '{s}' grammar ABI {d} unsupported (need {d}..{d}); rebuild it",
                        .{ name, abi, ts.MIN_COMPATIBLE_LANGUAGE_VERSION, ts.LANGUAGE_VERSION },
                    );
                    lib.close();
                    return error.BadAbi;
                }

                const q_path = std.fs.path.join(self.alloc, &.{ dir, name, "highlights.scm" }) catch {
                    lib.close();
                    return error.OutOfMemory;
                };
                defer self.alloc.free(q_path);
                const scm = std.Io.Dir.cwd().readFileAllocOptions(
                    self.io,
                    q_path,
                    self.alloc,
                    .limited(4 * 1024 * 1024),
                    .of(u8),
                    0,
                ) catch {
                    lib.close();
                    continue;
                };

                // `injections.scm` is optional -- a grammar with no
                // embedded languages simply doesn't ship one.
                const inj = self.readOptionalQuery(dir, name, "injections.scm");

                return .{ .lib = lib, .language = language, .highlights = scm, .injections = inj };
            }
        }
        return error.NotFound;
    }

    /// Reads `<dir>/<name>/<file>` as a null-terminated string, or null
    /// if it isn't there / can't be read. Used for the optional query
    /// files (`injections.scm`); a missing one is not an error.
    fn readOptionalQuery(self: *Registry, dir: []const u8, name: []const u8, file: []const u8) ?[:0]u8 {
        const path = std.fs.path.join(self.alloc, &.{ dir, name, file }) catch return null;
        defer self.alloc.free(path);
        return std.Io.Dir.cwd().readFileAllocOptions(
            self.io,
            path,
            self.alloc,
            .limited(4 * 1024 * 1024),
            .of(u8),
            0,
        ) catch null;
    }

    /// `tree_sitter_<name>`, with `-` turned into `_` the way the
    /// tree-sitter CLI does when it generates the entry point.
    fn symbolName(alloc: std.mem.Allocator, name: []const u8) ![:0]u8 {
        const sym = try std.fmt.allocPrintSentinel(alloc, "tree_sitter_{s}", .{name}, 0);
        for (sym) |*c| {
            if (c.* == '-') c.* = '_';
        }
        return sym;
    }
};

// ── Highlighter ─────────────────────────────────────────────────────────

const Predicate = struct {
    const Kind = enum { eq, not_eq, any_of, not_any_of };
    const Arg = union(enum) { capture: u32, text: []const u8 };

    kind: Kind,
    /// The capture the predicate constrains (its first `@arg`).
    capture: u32,
    args: []const Arg,
};

/// Everything needed to highlight one language, compiled once and reused
/// across every injected region of that language and every reparse until
/// `clearLanguage`. The primary language keeps its equivalents as
/// individual `Highlighter` fields; this is only for injected ones.
const CompiledLang = struct {
    /// Borrowed from the `compiled` map key.
    name: []const u8,
    /// Owned. Its language is set; injected regions parse through it one
    /// at a time (`setIncludedRanges` then `parseString`).
    parser: *ts.Parser,
    /// Owned. `highlights.scm`.
    query: *ts.Query,
    /// Owned. `injections.scm` compiled, for nested injection; null when
    /// the grammar ships none.
    inj_query: ?*ts.Query = null,
    /// Owned. capture id -> colour, resolved against the theme.
    capture_colors: []?Color = &.{},
    /// Owned. pattern index -> predicates (see `Highlighter.pattern_preds`).
    pattern_preds: []const []const Predicate = &.{},

    fn deinit(self: *CompiledLang, alloc: std.mem.Allocator) void {
        self.parser.destroy();
        self.query.destroy();
        if (self.inj_query) |q| q.destroy();
        alloc.free(self.capture_colors);
        freePreds(alloc, self.pattern_preds);
    }
};

/// One resolved embedded region: a child grammar's parse tree over a set
/// of byte ranges of the same text as the primary tree. Kept across
/// incremental reparses: `applyEdit` edits the tree and shifts `ranges`
/// along with the primary tree, and `refreshInjections` reparses it
/// (incrementally) only when an edit landed inside it. `compiled`
/// outlives it.
const Injection = struct {
    /// Borrowed from the `compiled` map.
    compiled: *CompiledLang,
    /// Owned.
    tree: *ts.Tree,
    /// Owned. The included ranges this tree was parsed over, in buffer
    /// coordinates -- `linesSpans` uses them to skip layers off the
    /// lines being painted, and `refreshInjections` matches them against
    /// the regions a reparse finds.
    ranges: []ts.Range,
    /// 1 for a region the primary grammar injected, 2 for one injected
    /// by such a region, and so on. Painting goes shallowest first.
    depth: u8,
    /// Unique among `Highlighter.injections`; `parent` names the
    /// injection whose tree this region was found in, 0 for the primary
    /// tree. How a reparsed region's descendants are found and dropped.
    id: u32,
    parent: u32,
    /// An edit since the last reparse changed bytes inside `ranges`, so
    /// the tree needs reparsing before it is trusted again.
    touched: bool = false,
    /// An edit straddled one of `ranges`' boundaries: the shifted ranges
    /// no longer describe anything, so the region can't be matched.
    broken: bool = false,

    fn destroy(self: *Injection, alloc: std.mem.Allocator) void {
        self.tree.destroy();
        alloc.free(self.ranges);
    }
};

/// One embedded region found by an injection query, before it is parsed:
/// its language resolved, and its ranges (owned).
const InjPair = struct { compiled: *CompiledLang, ranges: []ts.Range };

/// The text a parse tree indexes, wherever it lives.
///
/// tree-sitter reads its input in chunks through a callback, so the text
/// doesn't have to be one slice: zoe hands over its gap buffer as two
/// runs and nothing is copied per keystroke. gw-grep, the hover popup and
/// the tests pass plain bytes.
pub const TextSource = union(enum) {
    /// One contiguous slice.
    bytes: []const u8,
    /// A store that hands out the text a contiguous run at a time.
    reader: Reader,

    pub const Reader = struct {
        ctx: *const anyopaque,
        len: usize,
        /// The bytes from `off` up to the store's next seam or its end.
        /// Called only for `off < len`, and must then return at least one
        /// byte.
        chunk_fn: *const fn (ctx: *const anyopaque, off: usize) []const u8,
    };

    pub fn len(self: TextSource) usize {
        return switch (self) {
            .bytes => |b| b.len,
            .reader => |r| r.len,
        };
    }

    /// The contiguous bytes from `off` on, as many as the store has in
    /// one piece; empty at or past the end.
    pub fn chunk(self: TextSource, off: usize) []const u8 {
        if (off >= self.len()) return &.{};
        return switch (self) {
            .bytes => |b| b[off..],
            .reader => |r| r.chunk_fn(r.ctx, off),
        };
    }

    /// Bytes `[start, end)` as one slice: borrowed from the store when
    /// they sit in one chunk, otherwise copied into `scratch` (cleared
    /// first). Null when the range is out of bounds.
    pub fn slice(
        self: TextSource,
        alloc: std.mem.Allocator,
        start: usize,
        end: usize,
        scratch: *std.ArrayList(u8),
    ) !?[]const u8 {
        if (start > end or end > self.len()) return null;
        const first = self.chunk(start);
        if (end - start <= first.len) return first[0 .. end - start];
        scratch.clearRetainingCapacity();
        var off = start;
        while (off < end) {
            const c = self.chunk(off);
            if (c.len == 0) return null;
            const n = @min(c.len, end - off);
            try scratch.appendSlice(alloc, c[0..n]);
            off += n;
        }
        return scratch.items;
    }

    /// A `ts.Input` reading through `self`, which must stay put for as
    /// long as the parse it is handed to runs.
    fn input(self: *const TextSource) ts.Input {
        return .{ .payload = @constCast(self), .read = readSource };
    }
};

/// `ts.Input.read` over a `TextSource`: one chunk per call, nothing past
/// the end.
fn readSource(payload: ?*anyopaque, byte_index: u32, _: ts.Point, bytes_read: *u32) callconv(.c) [*c]const u8 {
    const src: *const TextSource = @ptrCast(@alignCast(payload.?));
    const c = src.chunk(byte_index);
    if (c.len == 0) {
        bytes_read.* = 0;
        return "";
    }
    bytes_read.* = @intCast(@min(c.len, std.math.maxInt(u32)));
    return c.ptr;
}

/// One buffer line for `Highlighter.linesSpans`: byte offsets of its
/// first byte and of its newline (or the text's end).
pub const LineRange = struct { start: usize, end: usize };

pub const Highlighter = struct {
    alloc: std.mem.Allocator,
    theme: Theme,
    parser: *ts.Parser,
    cursor: *ts.QueryCursor,
    /// A second cursor, used only while resolving injections, so nested
    /// resolution can re-`exec` without disturbing an outer walk.
    inj_cursor: *ts.QueryCursor,

    /// The grammar name currently set, borrowed from the registry's key.
    lang_name: ?[]const u8 = null,
    query: ?*ts.Query = null,
    tree: ?*ts.Tree = null,
    /// The text `tree` (and every injection tree) indexes -- what `#eq?` /
    /// `#any-of?` read a captured node's text from. After a whole-buffer
    /// parse of bytes this is `.bytes = source`; after
    /// `reparseIncremental` it is whatever the caller passed, borrowed.
    text: TextSource = .{ .bytes = &.{} },
    /// An owned snapshot of the text, kept only for the parses that need
    /// one: the bytes API (`reparse`, `beginParse`) and a staged parse,
    /// whose slices read it across many UI turns while the caller's own
    /// text may change. Empty once `reparseIncremental` has moved `text`
    /// onto the caller's store.
    source: []u8 = &.{},
    /// A whole-buffer parse of `source` was cut short by its budget and
    /// `parser` holds its state; `continueParse` resumes it. Anything else
    /// that parses with `parser` must `cancelParse` first, or tree-sitter
    /// would resume the old parse against the new input.
    parse_pending: bool = false,
    /// Bumped whenever the trees change in a way `reparseIncremental`'s
    /// changed ranges don't describe: a whole-buffer parse (or the end of
    /// a staged one), a language switch. A caller caching spans compares
    /// it to know when to throw the whole cache away.
    generation: u64 = 0,

    /// capture id -> resolved colour (or null = don't colour). Rebuilt
    /// by `setLanguage`. Owned.
    capture_colors: []?Color = &.{},
    /// pattern index -> the predicates to check before applying its
    /// captures. A disabled pattern gets an empty slice. Owned (each
    /// inner `args` slice too).
    pattern_preds: []const []const Predicate = &.{},

    /// The registry to resolve injected grammars through, and whether to
    /// attempt injection at all. Set once via `configureInjections`,
    /// before `setLanguage`; both survive a language switch.
    registry: ?*Registry = null,
    injections_enabled: bool = true,
    /// The primary language's `injections.scm` compiled, or null (no
    /// grammar file, injection disabled, or a bad query). Owned.
    inj_query: ?*ts.Query = null,
    /// Resolved embedded regions, sorted by `depth` so painting them in
    /// order lets a deeper layer win. Owned.
    injections: std.ArrayList(Injection) = .empty,
    /// The next `Injection.id` to hand out. 0 is the primary tree.
    next_inj_id: u32 = 1,
    /// canonical language name -> its compiled artifacts, shared across
    /// injections and reparses. Keys owned; values boxed and owned.
    compiled: std.StringHashMapUnmanaged(*CompiledLang) = .empty,
    /// Injected languages we tried and couldn't compile, so a miss is
    /// silent after the first. Keys owned.
    compiled_failed: std.StringHashMapUnmanaged(void) = .empty,
    /// Where the edits applied since the last reparse put new text, in
    /// current coordinates. The injection pass re-queries these as well
    /// as tree-sitter's changed ranges: an edit inside an injected region
    /// changes the region's bytes without necessarily changing the
    /// primary tree's structure.
    edit_ranges: std.ArrayList(ByteRange) = .empty,

    /// Paint scratch: one entry per byte of the run being painted,
    /// holding the winning colour so far. Reused across calls.
    paint: std.ArrayList(?Color) = .empty,
    raw: std.ArrayList(RawSpan) = .empty,
    /// `lineSpans`' one-line bounds, and the two capture-text buffers a
    /// predicate comparing two captures needs when both straddle a seam
    /// in `text`.
    line_bounds: std.ArrayList(usize) = .empty,
    pred_a: std.ArrayList(u8) = .empty,
    pred_b: std.ArrayList(u8) = .empty,

    const RawSpan = struct { start: usize, end: usize, specificity: u32, color: Color };

    pub fn init(alloc: std.mem.Allocator, theme: Theme) !Highlighter {
        const parser = ts.Parser.create();
        errdefer parser.destroy();
        const cursor = ts.QueryCursor.create();
        errdefer cursor.destroy();
        const inj_cursor = ts.QueryCursor.create();
        return .{
            .alloc = alloc,
            .theme = theme,
            .parser = parser,
            .cursor = cursor,
            .inj_cursor = inj_cursor,
        };
    }

    pub fn deinit(self: *Highlighter) void {
        self.clearLanguage();
        self.cursor.destroy();
        self.inj_cursor.destroy();
        self.parser.destroy();
        self.injections.deinit(self.alloc);
        self.compiled.deinit(self.alloc);
        self.compiled_failed.deinit(self.alloc);
        self.edit_ranges.deinit(self.alloc);
        self.paint.deinit(self.alloc);
        self.raw.deinit(self.alloc);
        self.line_bounds.deinit(self.alloc);
        self.pred_a.deinit(self.alloc);
        self.pred_b.deinit(self.alloc);
        self.* = undefined;
    }

    /// Give the highlighter the registry it resolves injected grammars
    /// through, and whether injection is on. Call before `setLanguage`.
    /// With no registry (or `enabled` false) injection is simply not
    /// attempted and only `highlights.scm` of the primary grammar runs.
    pub fn configureInjections(self: *Highlighter, registry: ?*Registry, enabled: bool) void {
        self.registry = registry;
        self.injections_enabled = enabled;
    }

    /// Recolour with `theme`: re-resolves the capture colours of the
    /// primary grammar and every compiled injected one, keeping the parse
    /// trees, and bumps `generation` so a caller's span cache drops the
    /// spans coloured with the old theme. On allocation failure the old
    /// colours stay for that grammar.
    pub fn setTheme(self: *Highlighter, theme: Theme) void {
        self.theme = theme;
        self.generation +%= 1;
        if (self.query) |q| {
            if (resolveCaptureColors(self.alloc, &self.theme, q)) |colors| {
                self.alloc.free(self.capture_colors);
                self.capture_colors = colors;
            } else |_| {}
        }
        var it = self.compiled.valueIterator();
        while (it.next()) |cl| {
            const colors = resolveCaptureColors(self.alloc, &self.theme, cl.*.query) catch continue;
            self.alloc.free(cl.*.capture_colors);
            cl.*.capture_colors = colors;
        }
    }

    /// A language has been chosen (its query compiled).
    pub fn languageSet(self: *const Highlighter) bool {
        return self.query != null;
    }

    /// A language is chosen *and* the current buffer has been parsed --
    /// `lineSpans` will do something.
    pub fn ready(self: *const Highlighter) bool {
        return self.query != null and self.tree != null;
    }

    pub fn clearLanguage(self: *Highlighter) void {
        self.cancelParse();
        self.clearInjections();
        self.edit_ranges.clearRetainingCapacity();
        self.generation +%= 1;

        var cit = self.compiled.iterator();
        while (cit.next()) |e| {
            e.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(e.value_ptr.*);
            self.alloc.free(e.key_ptr.*);
        }
        self.compiled.clearRetainingCapacity();

        var fit = self.compiled_failed.keyIterator();
        while (fit.next()) |k| self.alloc.free(k.*);
        self.compiled_failed.clearRetainingCapacity();

        if (self.inj_query) |q| {
            q.destroy();
            self.inj_query = null;
        }
        if (self.tree) |t| {
            t.destroy();
            self.tree = null;
        }
        if (self.query) |q| {
            q.destroy();
            self.query = null;
        }
        self.parser.setLanguage(null) catch {};
        self.setOwnedSource(&.{});
        self.alloc.free(self.capture_colors);
        self.capture_colors = &.{};
        freePreds(self.alloc, self.pattern_preds);
        self.pattern_preds = &.{};
        self.lang_name = null;
    }

    /// Drop every resolved injection tree. The compiled-language cache
    /// (`compiled`) is kept -- only the trees and their range slices go.
    fn clearInjections(self: *Highlighter) void {
        for (self.injections.items) |*inj| inj.destroy(self.alloc);
        self.injections.clearRetainingCapacity();
    }

    /// Replaces the owned snapshot with `src` (owned, may be empty) and
    /// points `text` at it.
    fn setOwnedSource(self: *Highlighter, src: []u8) void {
        self.alloc.free(self.source);
        self.source = src;
        self.text = .{ .bytes = src };
    }

    /// Switch to `grammar` (which outlives the Highlighter -- the
    /// registry owns it). Compiles `highlights.scm` (and, if injection is
    /// on and the grammar ships one, `injections.scm`) and resolves the
    /// highlight captures against the theme. On any failure the
    /// Highlighter is left with no language and the caller falls back to
    /// plain text.
    pub fn setLanguage(self: *Highlighter, name: []const u8, grammar: *const LoadedGrammar) !void {
        self.clearLanguage();

        self.parser.setLanguage(grammar.language) catch |e| {
            std.log.warn("syntax: parser rejected '{s}' grammar ({t})", .{ name, e });
            return error.IncompatibleGrammar;
        };

        var err_off: u32 = 0;
        const q = ts.Query.create(grammar.language, grammar.highlights, &err_off) catch |e| {
            std.log.warn("syntax: '{s}' highlights.scm rejected ({t}) at byte {d}", .{ name, e, err_off });
            self.parser.setLanguage(null) catch {};
            return error.BadQuery;
        };
        errdefer {
            q.destroy();
            self.parser.setLanguage(null) catch {};
        }

        // Build the fallible pieces first, then publish them together --
        // a failure here leaves `self` with no language, not a half-set one.
        const colors = try resolveCaptureColors(self.alloc, &self.theme, q);
        errdefer self.alloc.free(colors);
        const preds = try buildPredicates(self.alloc, q);
        errdefer freePreds(self.alloc, preds);

        self.query = q;
        self.lang_name = name;
        self.capture_colors = colors;
        self.pattern_preds = preds;

        if (self.injections_enabled and self.registry != null) {
            if (grammar.injections) |src| {
                var ie: u32 = 0;
                self.inj_query = ts.Query.create(grammar.language, src, &ie) catch |e| blk: {
                    std.log.warn("syntax: '{s}' injections.scm rejected ({t}) at byte {d}", .{ name, e, ie });
                    break :blk null;
                };
            }
        }
    }

    /// Reparse all of `text` from scratch (no tree reuse) and rebuild
    /// every injection. The fallback path: first parse, language switch,
    /// or an edit journal that overflowed. `text` is copied; the caller
    /// keeps its own.
    pub fn reparse(self: *Highlighter, text: []const u8) !void {
        if (self.query == null) return;
        self.cancelParse();
        self.setOwnedSource(try self.alloc.dupe(u8, text));
        try self.parseWhole();
    }

    /// Whole-buffer parse of `self.text` with no tree reuse, then every
    /// injection found fresh.
    fn parseWhole(self: *Highlighter) !void {
        const new_tree = self.parser.parse(self.text.input(), null) orelse return error.ParseFailed;
        if (self.tree) |t| t.destroy();
        self.tree = new_tree;
        self.wholeTreeReplaced();
    }

    /// The bookkeeping after `tree` was replaced by a parse that didn't
    /// reuse the old one: injections found again from scratch, and
    /// `generation` bumped so span caches know nothing old carries over.
    fn wholeTreeReplaced(self: *Highlighter) void {
        self.generation +%= 1;
        self.edit_ranges.clearRetainingCapacity();
        self.clearInjections();
        self.resolveInjections() catch {};
    }

    /// Starts a whole-buffer parse from scratch that gives up after
    /// `budget`, so a large file doesn't hold the first frame hostage.
    ///
    /// If the full parse finishes inside the budget -- any file of
    /// ordinary size -- this is just `reparse` and returns `.done`.
    /// Otherwise the full parse is parked in `parser`, and the first
    /// `prefix_end` bytes (the caller passes the end of the line just
    /// past what it is about to draw) are parsed on their own by a
    /// throwaway parser, so those lines highlight now. The rest of the
    /// buffer has no nodes in that tree and paints plain until
    /// `continueParse` reports `.done`.
    ///
    /// A prefix cut mid-construct (inside a block comment, say) can
    /// colour its last lines differently from the full parse; the caller
    /// repaints once the full tree lands, and cutting a screen or so past
    /// what is visible keeps that out of sight.
    pub fn beginParse(self: *Highlighter, text: []const u8, prefix_end: usize, budget: ParseBudget) !ParseProgress {
        if (self.query == null) return .done;
        self.cancelParse();

        // The parked parse reads this snapshot across many UI turns, so
        // it is the one parse that must not read the caller's live text.
        self.setOwnedSource(try self.alloc.dupe(u8, text));
        if (self.tree) |t| t.destroy();
        self.tree = null;
        self.clearInjections();
        self.edit_ranges.clearRetainingCapacity();
        self.generation +%= 1;
        self.parse_pending = true;

        if (try self.stepFullParse(budget) == .done) return .done;

        // The budget ran out. Show the prefix while the full parse waits.
        // It gets a slice of its own: a prefix always starts at byte 0,
        // so one that reaches far down a big file (an edit made while
        // scrolled deep into it) could cost nearly the full parse, and
        // then it is better to paint plain and let the slices finish.
        const cut = @min(prefix_end, self.source.len);
        const prefix = ts.Parser.create();
        defer prefix.destroy();
        prefix.setLanguage(self.parser.getLanguage()) catch return .pending;
        var slice = ParseSlice.start(budget);
        const prefix_src: TextSource = .{ .bytes = self.source[0..cut] };
        self.tree = slice.parse(prefix, &prefix_src);
        if (self.tree != null) self.resolveInjections() catch {};
        return .pending;
    }

    /// Runs the parked full parse for another `budget`. `.done` once the
    /// whole buffer's tree (and its injections) has replaced the prefix
    /// one; a no-op `.done` when nothing is pending.
    pub fn continueParse(self: *Highlighter, budget: ParseBudget) !ParseProgress {
        if (!self.parse_pending) return .done;
        return self.stepFullParse(budget);
    }

    /// A staged parse is still running; `continueParse` has work to do.
    pub fn parsing(self: *const Highlighter) bool {
        return self.parse_pending;
    }

    /// Drops a parked full parse, so the next parse starts from the top
    /// instead of resuming it. The prefix tree (if any) stays as it is.
    pub fn cancelParse(self: *Highlighter) void {
        if (!self.parse_pending) return;
        self.parser.reset();
        self.parse_pending = false;
    }

    fn stepFullParse(self: *Highlighter, budget: ParseBudget) !ParseProgress {
        var slice = ParseSlice.start(budget);
        const src: TextSource = .{ .bytes = self.source };
        const new_tree = slice.parse(self.parser, &src) orelse {
            // Stopped by the budget: `parser` keeps its place for the
            // next slice. Anything else (an external scanner error) would
            // fail the same way every slice, so give up on it and keep
            // whatever tree is showing.
            if (slice.fired) return .pending;
            self.cancelParse();
            return error.ParseFailed;
        };

        self.parse_pending = false;
        if (self.tree) |t| t.destroy();
        self.tree = new_tree;
        self.text = .{ .bytes = self.source };
        self.wholeTreeReplaced();
        return .done;
    }

    /// Replay one buffer mutation onto the retained trees -- the primary
    /// one and every injection's -- so the next `reparseIncremental` can
    /// reuse them. No-op until there is a tree.
    pub fn applyEdit(self: *Highlighter, e: Edit) void {
        const t = self.tree orelse return;
        const input_edit: ts.InputEdit = .{
            .start_byte = @intCast(e.start_byte),
            .old_end_byte = @intCast(e.old_end_byte),
            .new_end_byte = @intCast(e.new_end_byte),
            .start_point = pointOf(e.start_point),
            .old_end_point = pointOf(e.old_end_point),
            .new_end_point = pointOf(e.new_end_point),
        };
        t.edit(input_edit);

        // An injection tree is in buffer coordinates too, so the same
        // edit applies to it; its ranges move with the text. One wholly
        // before the edit is left alone -- nothing in it moved.
        for (self.injections.items) |*inj| {
            const last = inj.ranges[inj.ranges.len - 1];
            if (last.end_byte < e.start_byte) continue;
            inj.tree.edit(input_edit);
            switch (shiftRanges(inj.ranges, e)) {
                .untouched => {},
                .touched => inj.touched = true,
                .broken => inj.broken = true,
            }
        }

        // Earlier edits' new text moves with this one; then this edit's.
        for (self.edit_ranges.items) |*r| r.* = shiftByteRange(r.*, e);
        self.edit_ranges.append(self.alloc, .{ .start = e.start_byte, .end = e.new_end_byte }) catch {};
    }

    /// Reparse against the retained trees (already brought in sync by
    /// `applyEdit`), reading the text through `src`. From here on `src`
    /// is the text the trees index -- borrowed: the caller keeps it alive
    /// and unchanged until its next `applyEdit`. Appends to `changed` the
    /// byte ranges whose highlighting may have moved: where the primary
    /// tree's structure changed, where an injected region was reparsed,
    /// appeared or went away.
    ///
    /// Returns false when the caller should repaint everything instead --
    /// there was no tree to reuse, or a staged parse was still running,
    /// and the whole buffer was parsed again (`generation` moved); true
    /// when `changed`, unioned with the caller's own edited lines, is a
    /// complete account of what must be redrawn.
    pub fn reparseIncremental(
        self: *Highlighter,
        src: TextSource,
        changed: *std.ArrayList(ByteRange),
    ) !bool {
        if (self.query == null) return false;
        // The retained tree is a provisional prefix, not a tree of the
        // pre-edit buffer: nothing incremental can be built on it.
        if (self.parse_pending or self.tree == null) {
            self.cancelParse();
            self.setOwnedSource(&.{});
            self.text = src;
            try self.parseWhole();
            return false;
        }
        const old = self.tree.?;

        const new_tree = self.parser.parse(src.input(), old) orelse return error.ParseFailed;
        // A copy, not `src`: `text` is what injection parses read through
        // from now on, and it must outlive this call.
        self.text = src;
        // The snapshot from the last whole-buffer parse is no longer what
        // anything indexes.
        if (self.source.len > 0) {
            self.alloc.free(self.source);
            self.source = &.{};
        }

        const ranges: []const ts.Range = old.getChangedRanges(self.alloc, new_tree) catch &.{};
        defer if (ranges.len > 0) self.alloc.free(ranges);
        for (ranges) |r| try changed.append(self.alloc, .{ .start = r.start_byte, .end = r.end_byte });

        old.destroy();
        self.tree = new_tree;

        // Where injected regions could have changed: everywhere the
        // primary tree's structure did, plus every edit's new text.
        var regions: std.ArrayList(ByteRange) = .empty;
        defer regions.deinit(self.alloc);
        try regions.appendSlice(self.alloc, changed.items);
        try regions.appendSlice(self.alloc, self.edit_ranges.items);
        self.edit_ranges.clearRetainingCapacity();
        self.refreshInjections(&regions, changed) catch {
            // Half-refreshed injections can't be trusted; find them all
            // again and have the caller repaint.
            self.generation +%= 1;
            self.clearInjections();
            self.resolveInjections() catch {};
            return false;
        };
        return true;
    }

    // ── Injection resolution ───────────────────────────────────────────

    /// (Re)build `injections` from the primary tree's `injections.scm`,
    /// from scratch. `injections` must be empty.
    fn resolveInjections(self: *Highlighter) !void {
        if (!self.injections_enabled) return;
        if (self.registry == null) return;
        const iq = self.inj_query orelse return;
        const tree = self.tree orelse return;
        try self.collectInjections(iq, tree, 1, 0, null);
        self.sortInjections();
    }

    /// Runs `iq` over `tree` (just `range` of it, when given) and puts
    /// every embedded region whose language resolves into `pairs`.
    /// A region captured twice (two overlapping query ranges) is kept once.
    fn queryRegions(
        self: *Highlighter,
        iq: *ts.Query,
        tree: *ts.Tree,
        range: ?ByteRange,
        pairs: *std.ArrayList(InjPair),
    ) !void {
        const content_cap = queryCaptureId(iq, "injection.content") orelse return;
        const lang_cap = queryCaptureId(iq, "injection.language");

        if (range) |r| {
            self.inj_cursor.setByteRange(@intCast(r.start), @intCast(r.end)) catch {};
        } else {
            self.inj_cursor.setByteRange(0, std.math.maxInt(u32)) catch {};
        }
        self.inj_cursor.exec(iq, tree.rootNode());
        while (self.inj_cursor.nextMatch()) |m| {
            var compiled: ?*CompiledLang = null;
            if (staticInjectionLang(iq, m.pattern_index)) |name| compiled = self.getCompiled(name) catch null;
            if (lang_cap) |lc| {
                for (m.captures) |cap| {
                    if (cap.index != lc) continue;
                    const raw = (self.text.slice(self.alloc, cap.node.startByte(), cap.node.endByte(), &self.pred_a) catch null) orelse continue;
                    const name = std.mem.trim(u8, raw, " \t\r\n");
                    if (name.len == 0) continue;
                    compiled = self.getCompiled(name) catch null;
                }
            }
            const lang = compiled orelse continue;

            var ranges: std.ArrayList(ts.Range) = .empty;
            defer ranges.deinit(self.alloc);
            for (m.captures) |cap| {
                if (cap.index != content_cap) continue;
                const r = cap.node.range();
                if (r.end_byte > r.start_byte) try ranges.append(self.alloc, r);
            }
            if (ranges.items.len == 0) continue;

            var dup = false;
            for (pairs.items) |p| {
                if (p.compiled == lang and rangesEqual(p.ranges, ranges.items)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            const owned = try ranges.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(owned);
            try pairs.append(self.alloc, .{ .compiled = lang, .ranges = owned });
        }
    }

    /// Finds every embedded region in `tree` (all of it, or the `range`
    /// slice) and parses each from scratch with its own grammar, at
    /// `depth` under injection `parent`; then recurses into each new
    /// region's own injections.
    fn collectInjections(
        self: *Highlighter,
        iq: *ts.Query,
        tree: *ts.Tree,
        depth: u8,
        parent: u32,
        range: ?ByteRange,
    ) !void {
        if (depth > max_injection_depth) return;

        // Drain the cursor into a list first, so the recursion below can
        // re-`exec` the same cursor freely.
        var pairs: std.ArrayList(InjPair) = .empty;
        defer {
            for (pairs.items) |p| self.alloc.free(p.ranges);
            pairs.deinit(self.alloc);
        }
        try self.queryRegions(iq, tree, range, &pairs);

        for (pairs.items) |*p| {
            const id = (try self.addInjection(p, depth, parent, null)) orelse continue;
            const added = self.injections.items[self.injections.items.len - 1];
            if (p.compiled.inj_query) |ciq| try self.collectInjections(ciq, added.tree, depth + 1, id, null);
        }
    }

    /// Parses the region `p` describes -- incrementally against `old`
    /// when given (an edited tree of the same region, still the caller's)
    /// -- and appends it to `injections`, taking ownership of `p.ranges`
    /// (left empty). Its id, or null when the parse failed.
    fn addInjection(self: *Highlighter, p: *InjPair, depth: u8, parent: u32, old: ?*ts.Tree) !?u32 {
        const child = p.compiled;
        child.parser.setIncludedRanges(p.ranges) catch return null;
        const parsed = child.parser.parse(self.text.input(), old);
        child.parser.setIncludedRanges(null) catch {};
        const ct = parsed orelse return null;
        errdefer ct.destroy();

        const id = self.next_inj_id;
        self.next_inj_id +%= 1;
        if (self.next_inj_id == 0) self.next_inj_id = 1;
        try self.injections.append(self.alloc, .{
            .compiled = child,
            .tree = ct,
            .ranges = p.ranges,
            .depth = depth,
            .id = id,
            .parent = parent,
        });
        p.ranges = &.{};
        return id;
    }

    /// Brings `injections` up to date after an incremental reparse,
    /// touching only what `regions` (the primary tree's changed ranges
    /// plus the edits' new text) can have affected.
    ///
    /// An injection that doesn't meet any region and no edit touched is
    /// kept as it is, tree and descendants -- for a big Markdown file that
    /// is every paragraph but the one being typed in. The primary
    /// injection query then runs over just the regions; each region it
    /// finds is matched against the old injections there (same language,
    /// same ranges): a match no edit touched is kept, a touched one is
    /// reparsed against its own edited tree, and anything unmatched is
    /// parsed fresh. Old injections there that matched nothing are gone.
    /// Every region that was reparsed, added or dropped lands in
    /// `changed`.
    fn refreshInjections(
        self: *Highlighter,
        regions: *std.ArrayList(ByteRange),
        changed: *std.ArrayList(ByteRange),
    ) !void {
        if (!self.injections_enabled or self.registry == null) return;
        const iq = self.inj_query orelse return;
        const tree = self.tree orelse return;
        normalizeRanges(regions, self.text.len());

        var old = self.injections;
        self.injections = .empty;
        // Whatever of `old` this doesn't hand back to `injections` is
        // destroyed: a dropped region, or one an error abandoned.
        const taken = try self.alloc.alloc(bool, old.items.len);
        defer self.alloc.free(taken);
        @memset(taken, false);
        defer {
            for (old.items, taken) |*inj, t| {
                if (!t) inj.destroy(self.alloc);
            }
            old.deinit(self.alloc);
        }

        // The depth-1 regions that may have changed: touched by an edit,
        // or meeting a changed region. Each one's own extent joins the
        // regions to query, so a region that still exists is found again
        // even where it no longer meets an edit (a paragraph split in
        // two shrinks the first half away from the new blank line). That
        // can make a neighbour meet the regions too, so repeat until no
        // more join.
        const suspect = try self.alloc.alloc(bool, old.items.len);
        defer self.alloc.free(suspect);
        @memset(suspect, false);
        var grew = true;
        while (grew) {
            grew = false;
            for (old.items, 0..) |inj, i| {
                if (inj.parent != 0 or suspect[i]) continue;
                if (inj.touched or inj.broken or rangesMeet(inj.ranges, regions.items)) {
                    suspect[i] = true;
                    try regions.append(self.alloc, rangesSpan(inj.ranges));
                    grew = true;
                }
            }
            normalizeRanges(regions, self.text.len());
        }

        // The rest meet nothing the query will look at: they keep their
        // trees and whole subtrees.
        var suspects: std.ArrayList(usize) = .empty;
        defer suspects.deinit(self.alloc);
        for (old.items, 0..) |inj, i| {
            if (inj.parent != 0) continue;
            if (suspect[i]) {
                try suspects.append(self.alloc, i);
            } else {
                try self.keepSubtree(&old, taken, i);
            }
        }

        var pairs: std.ArrayList(InjPair) = .empty;
        defer {
            for (pairs.items) |p| self.alloc.free(p.ranges);
            pairs.deinit(self.alloc);
        }
        for (regions.items) |r| try self.queryRegions(iq, tree, r, &pairs);

        for (pairs.items) |*p| {
            const match: ?usize = for (suspects.items) |i| {
                const o = &old.items[i];
                if (taken[i] or o.broken) continue;
                if (o.compiled == p.compiled and rangesEqual(o.ranges, p.ranges)) break i;
            } else null;

            if (match) |i| {
                if (!old.items[i].touched) {
                    // Found again, unchanged: as it was.
                    try self.keepSubtree(&old, taken, i);
                    continue;
                }
                // Same region, edited inside: reparse against its own
                // tree, and find its own injections again from scratch.
                taken[i] = true;
                const before = old.items[i].tree;
                defer before.destroy();
                self.alloc.free(old.items[i].ranges);
                const id = (try self.addInjection(p, 1, 0, before)) orelse continue;
                const added = self.injections.items[self.injections.items.len - 1];
                const moved = before.getChangedRanges(self.alloc, added.tree) catch &.{};
                defer if (moved.len > 0) self.alloc.free(moved);
                for (moved) |m| try changed.append(self.alloc, .{ .start = m.start_byte, .end = m.end_byte });
                // Typed text inside the region can recolour it without
                // changing its structure; the caller covers the edited
                // lines themselves.
                if (added.compiled.inj_query) |ciq| try self.collectInjections(ciq, added.tree, 2, id, null);
                continue;
            }

            // A region that wasn't there before.
            try changed.append(self.alloc, rangesSpan(p.ranges));
            const id = (try self.addInjection(p, 1, 0, null)) orelse continue;
            const added = self.injections.items[self.injections.items.len - 1];
            if (added.compiled.inj_query) |ciq| try self.collectInjections(ciq, added.tree, 2, id, null);
        }

        // Suspects nothing matched are gone; their colours with them.
        for (suspects.items) |i| {
            if (!taken[i]) try changed.append(self.alloc, rangesSpan(old.items[i].ranges));
        }
        self.sortInjections();
    }

    /// Moves `old.items[i]` and every injection descended from it into
    /// `injections`, marking each taken.
    fn keepSubtree(self: *Highlighter, old: *std.ArrayList(Injection), taken: []bool, i: usize) !void {
        const inj = &old.items[i];
        inj.touched = false;
        try self.injections.append(self.alloc, inj.*);
        taken[i] = true;
        for (old.items, 0..) |o, j| {
            if (!taken[j] and o.parent == inj.id) try self.keepSubtree(old, taken, j);
        }
    }

    /// Shallowest first, so painting in list order lets a deeper layer's
    /// colour win the bytes it covers.
    fn sortInjections(self: *Highlighter) void {
        std.sort.block(Injection, self.injections.items, {}, struct {
            fn lt(_: void, a: Injection, b: Injection) bool {
                return a.depth < b.depth;
            }
        }.lt);
    }

    /// The compiled artifacts for an injected language, compiling and
    /// caching them on first use. `null` (remembered) when the grammar
    /// isn't on the search path or its query won't compile.
    fn getCompiled(self: *Highlighter, name: []const u8) !?*CompiledLang {
        const reg = self.registry orelse return null;
        const canon = Registry.resolveAlias(name);
        if (self.compiled.get(canon)) |c| return c;
        if (self.compiled_failed.contains(canon)) return null;

        const grammar = reg.get(canon) orelse {
            self.markCompiledFailed(canon);
            return null;
        };
        const c = self.compileLang(grammar) catch {
            self.markCompiledFailed(canon);
            return null;
        };
        const key = self.alloc.dupe(u8, canon) catch {
            c.deinit(self.alloc);
            self.alloc.destroy(c);
            return null;
        };
        self.compiled.put(self.alloc, key, c) catch {
            self.alloc.free(key);
            c.deinit(self.alloc);
            self.alloc.destroy(c);
            return null;
        };
        c.name = key;
        return c;
    }

    fn compileLang(self: *Highlighter, grammar: *const LoadedGrammar) !*CompiledLang {
        const parser = ts.Parser.create();
        errdefer parser.destroy();
        parser.setLanguage(grammar.language) catch return error.IncompatibleGrammar;

        var eoff: u32 = 0;
        const q = try ts.Query.create(grammar.language, grammar.highlights, &eoff);
        errdefer q.destroy();

        const iq: ?*ts.Query = if (grammar.injections) |src| blk: {
            var e2: u32 = 0;
            break :blk ts.Query.create(grammar.language, src, &e2) catch null;
        } else null;
        errdefer if (iq) |x| x.destroy();

        const colors = try resolveCaptureColors(self.alloc, &self.theme, q);
        errdefer self.alloc.free(colors);
        const preds = try buildPredicates(self.alloc, q);
        errdefer freePreds(self.alloc, preds);

        const box = try self.alloc.create(CompiledLang);
        box.* = .{
            .name = &.{},
            .parser = parser,
            .query = q,
            .inj_query = iq,
            .capture_colors = colors,
            .pattern_preds = preds,
        };
        return box;
    }

    fn markCompiledFailed(self: *Highlighter, name: []const u8) void {
        if (self.compiled_failed.contains(name)) return;
        const key = self.alloc.dupe(u8, name) catch return;
        self.compiled_failed.put(self.alloc, key, {}) catch self.alloc.free(key);
    }

    // ── Painting ───────────────────────────────────────────────────────

    /// Fill `out` (cleared first) with the colour spans covering buffer
    /// byte range `[line_start, line_end)`, as offsets relative to
    /// `line_start`. One line's worth of `linesSpans`.
    pub fn lineSpans(self: *Highlighter, line_start: usize, line_end: usize, out: *std.ArrayList(Span)) !void {
        const one = [_]LineRange{.{ .start = line_start, .end = line_end }};
        try self.linesSpans(&one, out, &self.line_bounds);
    }

    /// The colour spans of each of `lines` -- consecutive buffer lines, in
    /// order -- with one query per layer for the whole run rather than one
    /// per line: a query walks down from the root to reach its range, and
    /// in a big file that descent, not the matching, is most of what a
    /// one-line query costs.
    ///
    /// `spans` gets every line's spans back to back, each relative to its
    /// own line's start; `bounds` gets `lines.len + 1` indexes into it, so
    /// line `i`'s spans are `spans[bounds[i]..bounds[i + 1]]`. Both are
    /// cleared first. A line longer than `max_highlight_line` gets none
    /// and splits the run around it.
    pub fn linesSpans(
        self: *Highlighter,
        lines: []const LineRange,
        spans: *std.ArrayList(Span),
        bounds: *std.ArrayList(usize),
    ) !void {
        spans.clearRetainingCapacity();
        bounds.clearRetainingCapacity();
        try bounds.append(self.alloc, 0);

        var i: usize = 0;
        while (i < lines.len) {
            if (lines[i].end -| lines[i].start > max_highlight_line or !self.ready()) {
                try bounds.append(self.alloc, spans.items.len);
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < lines.len and lines[j].end -| lines[j].start <= max_highlight_line) j += 1;
            try self.paintRun(lines[i..j], spans, bounds);
            i = j;
        }
    }

    /// `linesSpans` for one run of lines no longer than
    /// `max_highlight_line`: paint every layer over the run's bytes, then
    /// cut the result into per-line spans.
    fn paintRun(self: *Highlighter, run: []const LineRange, spans: *std.ArrayList(Span), bounds: *std.ArrayList(usize)) !void {
        const run_start = run[0].start;
        const run_end = @max(run[run.len - 1].end, run_start);
        try self.paint.resize(self.alloc, run_end - run_start);
        @memset(self.paint.items, null);

        if (run_end > run_start) {
            try self.paintLayer(self.query.?, self.tree.?, self.capture_colors, self.pattern_preds, run_start, run_end);
            for (self.injections.items) |*inj| {
                if (!rangesTouchLine(inj.ranges, run_start, run_end)) continue;
                try self.paintLayer(
                    inj.compiled.query,
                    inj.tree,
                    inj.compiled.capture_colors,
                    inj.compiled.pattern_preds,
                    run_start,
                    run_end,
                );
            }
        }

        for (run) |line| {
            const lo = line.start - run_start;
            const hi = @max(line.end, line.start) - run_start;
            const painted = self.paint.items[lo..hi];
            var k: usize = 0;
            while (k < painted.len) {
                const c = painted[k];
                var m = k + 1;
                while (m < painted.len and colorEql(painted[m], c)) m += 1;
                if (c) |col| try spans.append(self.alloc, .{ .start = k, .end = m, .color = col });
                k = m;
            }
            try bounds.append(self.alloc, spans.items.len);
        }
    }

    /// Runs one layer's query clipped to `[range_start, range_end)` and
    /// blends its captures into `self.paint` (already sized to the range,
    /// index 0 = `range_start`).
    fn paintLayer(
        self: *Highlighter,
        q: *ts.Query,
        tree: *ts.Tree,
        colors: []const ?Color,
        preds: []const []const Predicate,
        range_start: usize,
        range_end: usize,
    ) !void {
        self.raw.clearRetainingCapacity();
        self.cursor.setByteRange(@intCast(range_start), @intCast(range_end)) catch {};
        self.cursor.exec(q, tree.rootNode());

        while (self.cursor.nextMatch()) |m| {
            if (!self.predicatesOk(preds, m)) continue;
            for (m.captures) |cap| {
                if (cap.index >= colors.len) continue;
                const color = colors[cap.index] orelse continue;
                const s: usize = cap.node.startByte();
                const e: usize = cap.node.endByte();
                if (e <= range_start or s >= range_end) continue;
                const cs = if (s > range_start) s - range_start else 0;
                const ce = (if (e < range_end) e else range_end) - range_start;
                if (ce <= cs) continue;
                try self.raw.append(self.alloc, .{
                    .start = cs,
                    .end = ce,
                    .specificity = @intCast(e - s),
                    .color = color,
                });
            }
        }
        if (self.raw.items.len == 0) return;

        // Paint less-specific (wider) captures first so a nested, more-
        // specific capture wins the bytes it covers. A stable sort keeps
        // "a later match wins on a tie", matching tree-sitter's own
        // last-wins convention. Block sort rather than insertion: a run of
        // a whole screen collects hundreds of captures.
        std.sort.block(RawSpan, self.raw.items, {}, lessSpecificFirst);
        for (self.raw.items) |r| {
            @memset(self.paint.items[r.start..r.end], r.color);
        }
    }

    /// Whether match `m` passes its pattern's `#eq?` family predicates,
    /// reading captured text from `text`.
    fn predicatesOk(self: *Highlighter, preds: []const []const Predicate, m: ts.Query.Match) bool {
        if (m.pattern_index >= preds.len) return true;
        for (preds[m.pattern_index]) |pr| {
            const lhs = self.captureText(m, pr.capture, &self.pred_a) orelse return false;
            switch (pr.kind) {
                .eq, .not_eq => {
                    if (pr.args.len == 0) continue;
                    const rhs = switch (pr.args[0]) {
                        .capture => |c| self.captureText(m, c, &self.pred_b) orelse return false,
                        .text => |t| t,
                    };
                    const equal = std.mem.eql(u8, lhs, rhs);
                    if ((pr.kind == .eq) != equal) return false;
                },
                .any_of, .not_any_of => {
                    var found = false;
                    for (pr.args) |a| {
                        const s = switch (a) {
                            .capture => |c| self.captureText(m, c, &self.pred_b) orelse continue,
                            .text => |t| t,
                        };
                        if (std.mem.eql(u8, lhs, s)) {
                            found = true;
                            break;
                        }
                    }
                    if ((pr.kind == .any_of) != found) return false;
                },
            }
        }
        return true;
    }

    /// The text of `capture_id` in `m`, borrowed from `text` or copied
    /// into `scratch` when it straddles a seam there.
    fn captureText(self: *Highlighter, m: ts.Query.Match, capture_id: u32, scratch: *std.ArrayList(u8)) ?[]const u8 {
        for (m.captures) |cap| {
            if (cap.index != capture_id) continue;
            return self.text.slice(self.alloc, cap.node.startByte(), cap.node.endByte(), scratch) catch null;
        }
        return null;
    }
};

/// What an edit did to an injected region's ranges (`shiftRanges`).
const RangeShift = enum { untouched, touched, broken };

/// Moves `ranges` (in place) to where `e` put their text. An edit wholly
/// before a range shifts it; one wholly inside (boundaries included, so
/// typing at either end of a region extends it) grows or shrinks its end
/// and marks the region touched; one straddling a boundary breaks it.
/// Only the byte offsets move -- a refreshed region takes fresh ranges,
/// points and all, from the query that finds it again.
fn shiftRanges(ranges: []ts.Range, e: Edit) RangeShift {
    var result: RangeShift = .untouched;
    for (ranges) |*r| {
        const s: usize = r.start_byte;
        const end: usize = r.end_byte;
        if (e.old_end_byte < s or (e.old_end_byte == s and e.start_byte < s)) {
            r.start_byte = @intCast(s - e.old_end_byte + e.new_end_byte);
            r.end_byte = @intCast(end - e.old_end_byte + e.new_end_byte);
        } else if (e.start_byte > end) {
            // Wholly after: nothing moves.
        } else if (e.start_byte >= s and e.old_end_byte <= end) {
            r.end_byte = @intCast(end - e.old_end_byte + e.new_end_byte);
            if (result == .untouched) result = .touched;
        } else {
            result = .broken;
        }
    }
    return result;
}

/// `r` after edit `e`: shifted when wholly after the edit, widened to
/// cover the edit's new text when they overlap.
fn shiftByteRange(r: ByteRange, e: Edit) ByteRange {
    if (r.start >= e.old_end_byte) {
        return .{ .start = r.start - e.old_end_byte + e.new_end_byte, .end = r.end - e.old_end_byte + e.new_end_byte };
    }
    if (r.end <= e.start_byte) return r;
    const end = if (r.end >= e.old_end_byte) r.end - e.old_end_byte + e.new_end_byte else e.new_end_byte;
    return .{ .start = @min(r.start, e.start_byte), .end = @max(end, e.new_end_byte) };
}

/// Sorts `ranges` and merges the ones that overlap or touch, after
/// widening each empty one (a deletion) to the bytes either side of it
/// so a query over it still finds the region it sat in. Clamped to
/// `len`.
fn normalizeRanges(ranges: *std.ArrayList(ByteRange), len: usize) void {
    for (ranges.items) |*r| {
        if (r.end <= r.start) r.* = .{ .start = r.start -| 1, .end = r.start + 1 };
        r.end = @min(r.end, len);
        r.start = @min(r.start, r.end);
    }
    std.sort.block(ByteRange, ranges.items, {}, struct {
        fn lt(_: void, a: ByteRange, b: ByteRange) bool {
            return a.start < b.start;
        }
    }.lt);
    var out: usize = 0;
    for (ranges.items) |r| {
        if (out > 0 and r.start <= ranges.items[out - 1].end) {
            ranges.items[out - 1].end = @max(ranges.items[out - 1].end, r.end);
        } else {
            ranges.items[out] = r;
            out += 1;
        }
    }
    ranges.shrinkRetainingCapacity(out);
}

/// Whether any of `a` meets any of `regions`, boundaries included.
fn rangesMeet(a: []const ts.Range, regions: []const ByteRange) bool {
    for (a) |r| {
        for (regions) |g| {
            if (r.start_byte <= g.end and g.start <= r.end_byte) return true;
        }
    }
    return false;
}

fn rangesEqual(a: []const ts.Range, b: []const ts.Range) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start_byte != y.start_byte or x.end_byte != y.end_byte) return false;
    }
    return true;
}

/// From the first range's start to the last one's end.
fn rangesSpan(ranges: []const ts.Range) ByteRange {
    return .{ .start = ranges[0].start_byte, .end = ranges[ranges.len - 1].end_byte };
}

/// capture id -> theme colour (or null = don't colour), as a fresh
/// owned slice.
fn resolveCaptureColors(alloc: std.mem.Allocator, theme: *const Theme, q: *const ts.Query) ![]?Color {
    const n = q.captureCount();
    const colors = try alloc.alloc(?Color, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        colors[i] = theme.colorFor(q.captureNameForId(i) orelse "");
    }
    return colors;
}

/// pattern index -> the `#eq?` / `#any-of?` family predicates guarding
/// it. A pattern carrying a predicate we can't evaluate is disabled on
/// `q` and gets an empty slice. Owned (each inner `args` slice too);
/// free with `freePreds`.
fn buildPredicates(alloc: std.mem.Allocator, q: *ts.Query) ![]const []const Predicate {
    const pn = q.patternCount();
    const out = try alloc.alloc([]const Predicate, pn);
    errdefer alloc.free(out);
    var built: usize = 0;
    errdefer for (out[0..built]) |preds| {
        for (preds) |p| alloc.free(p.args);
        alloc.free(preds);
    };

    var p: u32 = 0;
    while (p < pn) : (p += 1) {
        var list: std.ArrayList(Predicate) = .empty;
        errdefer {
            for (list.items) |it| alloc.free(it.args);
            list.deinit(alloc);
        }

        const steps = q.predicatesForPattern(p);
        var disable = false;
        var i: usize = 0;
        while (i < steps.len) {
            var j = i;
            while (j < steps.len and steps[j].type != .done) j += 1;
            const grp = steps[i..j];
            i = j + 1;
            if (grp.len == 0 or grp[0].type != .string) continue;

            const pname = q.stringValueForId(grp[0].value_id) orelse continue;
            const kind: Predicate.Kind = if (std.mem.eql(u8, pname, "eq?"))
                .eq
            else if (std.mem.eql(u8, pname, "not-eq?"))
                .not_eq
            else if (std.mem.eql(u8, pname, "any-of?"))
                .any_of
            else if (std.mem.eql(u8, pname, "not-any-of?"))
                .not_any_of
            else {
                // A `!` step is a directive (`#set!`), harmless to
                // ignore. Any other `?` test we can't evaluate, so the
                // whole pattern is dropped rather than applied blind.
                if (std.mem.endsWith(u8, pname, "?")) disable = true;
                continue;
            };

            if (grp.len < 2 or grp[1].type != .capture) continue;
            var args: std.ArrayList(Predicate.Arg) = .empty;
            errdefer args.deinit(alloc);
            for (grp[2..]) |st| switch (st.type) {
                .capture => try args.append(alloc, .{ .capture = st.value_id }),
                .string => try args.append(alloc, .{ .text = q.stringValueForId(st.value_id) orelse "" }),
                .done => {},
            };
            try list.append(alloc, .{
                .kind = kind,
                .capture = grp[1].value_id,
                .args = try args.toOwnedSlice(alloc),
            });
        }

        if (disable) {
            q.disablePattern(p);
            for (list.items) |it| alloc.free(it.args);
            list.clearRetainingCapacity();
        }
        out[p] = try list.toOwnedSlice(alloc);
        built += 1;
    }
    return out;
}

fn freePreds(alloc: std.mem.Allocator, preds: []const []const Predicate) void {
    for (preds) |per_pattern| {
        for (per_pattern) |p| alloc.free(p.args);
        alloc.free(per_pattern);
    }
    alloc.free(preds);
}

/// The static `#set! injection.language "x"` value for a pattern, if it
/// has one.
fn staticInjectionLang(q: *const ts.Query, pattern_index: u16) ?[]const u8 {
    const steps = q.predicatesForPattern(pattern_index);
    var i: usize = 0;
    while (i < steps.len) {
        var j = i;
        while (j < steps.len and steps[j].type != .done) j += 1;
        const grp = steps[i..j];
        i = j + 1;
        if (grp.len < 3 or grp[0].type != .string) continue;
        const pname = q.stringValueForId(grp[0].value_id) orelse continue;
        if (!std.mem.eql(u8, pname, "set!")) continue;
        if (grp[1].type != .string or grp[2].type != .string) continue;
        const key = q.stringValueForId(grp[1].value_id) orelse continue;
        if (std.mem.eql(u8, key, "injection.language"))
            return q.stringValueForId(grp[2].value_id);
    }
    return null;
}

/// The capture id for `name` in `q`, or null if it has no such capture.
fn queryCaptureId(q: *const ts.Query, name: []const u8) ?u32 {
    const n = q.captureCount();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, q.captureNameForId(i) orelse "", name)) return i;
    }
    return null;
}

fn rangesTouchLine(ranges: []const ts.Range, line_start: usize, line_end: usize) bool {
    for (ranges) |r| {
        if (r.start_byte < line_end and r.end_byte > line_start) return true;
    }
    return false;
}

fn lessSpecificFirst(_: void, a: Highlighter.RawSpan, b: Highlighter.RawSpan) bool {
    return a.specificity > b.specificity;
}

fn colorEql(a: ?Color, b: ?Color) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const x = a.?;
    const y = b.?;
    return x.eql(y);
}
