// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Syntax colours for the lines gw-grep shows, from the same tree-sitter
//! grammars zoe uses (`applib.syntax`).
//!
//! ripgrep only hands back the hit and context lines, and a window of
//! lines parsed on its own gets its edges wrong -- a context line inside
//! a block comment or multi-line string that opened above the window
//! would colour as code. So each file with a hit is read back from disk
//! and parsed **whole**, once, and only then are the shown lines' spans
//! taken from that tree. `--max` bounds how many files that can be.
//!
//! Anything that stops a file being highlighted -- no grammar for its
//! extension, a file too big or gone, a parse that fails -- leaves its
//! lines with no spans, and they draw in the plain colours they always
//! did. A line whose bytes on disk no longer match what ripgrep reported
//! (the file changed in between) is left plain too, rather than
//! painting colours from one version of the file over the text of
//! another.

const std = @import("std");
const syntax = @import("applib").syntax;

const rg = @import("rg.zig");

/// Past this a file is left plain. Reading and parsing a file that size
/// for a handful of lines out of it is slower than the grep was, and it
/// is almost always generated or minified anyway.
pub const max_file_bytes: usize = 4 * 1024 * 1024;

/// Spans for every line of every file, indexed like the `files` that
/// `compute` was given and then like each file's `lines`. An empty slice
/// is "no colours for this line". Owns all of it.
pub const Highlights = struct {
    files: []const []const []const syntax.Span,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Highlights) void {
        self.arena.deinit();
    }
};

/// Works out the spans for every line in `files`. `registry` resolves a
/// path's extension to a grammar; files of the same language share one
/// `Highlighter`, so each language's query is compiled once per run
/// rather than once per file.
pub fn compute(
    gpa: std.mem.Allocator,
    io: std.Io,
    registry: *syntax.Registry,
    theme: syntax.Theme,
    files: []const rg.FileHits,
) !Highlights {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Language name -> its highlighter, or null for a language whose
    // grammar would not load, so it is only tried once.
    var highlighters: std.StringHashMapUnmanaged(?*syntax.Highlighter) = .empty;
    defer {
        var it = highlighters.valueIterator();
        while (it.next()) |v| if (v.*) |h| {
            h.deinit();
            gpa.destroy(h);
        };
        highlighters.deinit(gpa);
    }

    var scratch: std.ArrayList(syntax.Span) = .empty;
    defer scratch.deinit(gpa);

    const out = try alloc.alloc([]const []const syntax.Span, files.len);
    for (files, 0..) |file, fi| {
        const lines = try alloc.alloc([]const syntax.Span, file.lines.len);
        @memset(lines, &.{});
        out[fi] = lines;

        const hl = try highlighterFor(gpa, registry, theme, &highlighters, file.path) orelse continue;

        const src = std.Io.Dir.cwd().readFileAlloc(io, file.path, gpa, .limited(max_file_bytes)) catch continue;
        defer gpa.free(src);
        hl.reparse(src) catch continue;

        // `file.lines` is in file order, so one forward walk finds every
        // line's start.
        var line_no: u64 = 1;
        var offset: usize = 0;
        for (file.lines, 0..) |line, li| {
            while (line_no < line.number) : (line_no += 1) {
                const nl = std.mem.indexOfScalarPos(u8, src, offset, '\n') orelse break;
                offset = nl + 1;
            }
            if (line_no != line.number) break; // the file got shorter
            var end = std.mem.indexOfScalarPos(u8, src, offset, '\n') orelse src.len;
            if (end > offset and src[end - 1] == '\r') end -= 1;
            if (!sameLine(src[offset..end], line.text)) continue;

            hl.lineSpans(offset, end, &scratch) catch continue;
            lines[li] = try alloc.dupe(syntax.Span, scratch.items);
        }
    }

    return .{ .files = out, .arena = arena };
}

/// The highlighter for `path`'s language, making it on first use. Null
/// when the extension has no grammar or it would not load.
fn highlighterFor(
    gpa: std.mem.Allocator,
    registry: *syntax.Registry,
    theme: syntax.Theme,
    cache: *std.StringHashMapUnmanaged(?*syntax.Highlighter),
    path: []const u8,
) !?*syntax.Highlighter {
    const name = registry.nameForPath(path) orelse return null;
    if (cache.get(name)) |h| return h;

    // `name` is borrowed from the registry's language list, which outlives
    // the cache, so it can key the map as-is.
    const made = try makeHighlighter(gpa, registry, theme, name);
    try cache.put(gpa, name, made);
    return made;
}

fn makeHighlighter(
    gpa: std.mem.Allocator,
    registry: *syntax.Registry,
    theme: syntax.Theme,
    name: []const u8,
) !?*syntax.Highlighter {
    const grammar = registry.get(name) orelse return null;
    const h = try gpa.create(syntax.Highlighter);
    errdefer gpa.destroy(h);
    h.* = try syntax.Highlighter.init(gpa, theme);
    h.configureInjections(registry, true);
    h.setLanguage(name, grammar) catch {
        h.deinit();
        gpa.destroy(h);
        return null;
    };
    return h;
}

/// Whether `on_disk` is the line ripgrep reported as `shown`, which went
/// through `rg.sanitize` (one byte in, one byte out: tabs and other
/// control bytes became spaces).
fn sameLine(on_disk: []const u8, shown: []const u8) bool {
    if (on_disk.len != shown.len) return false;
    for (on_disk, shown) |d, s| {
        const want: u8 = if (d < 0x20 or d == 0x7f) ' ' else d;
        if (want != s) return false;
    }
    return true;
}
