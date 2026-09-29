// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Turning `rg.FileHits` into the `Outline` node list.
//!
//! Three levels, which is what the flat-list-plus-depth model makes cheap:
//!
//! ```
//! ▾ src/core.zig                  (12)        depth 0, the file
//!   ▾ 890  pub fn init() !Layer {             depth 1, one hit
//!       888   }                              depth 2, its context
//!       889
//!       890   pub fn init() !Layer {         the hit itself, number lit
//!       891       const self = ...
//! ```
//!
//! The hit's own line is repeated **inside** its context block, with its
//! line number in the match colour. Without it the block has a hole
//! exactly where the interesting line should be, and the surrounding
//! lines stop reading as a contiguous piece of the file; the lit number
//! is what says which of them you searched for.
//!
//! Every row is syntax-highlighted when `Options.spans` carries colours
//! for it (see `highlight.zig`). A hit's rows draw at full strength and
//! its context rows in a dimmed copy of the same colours, so the hit
//! reads as the focus without the context losing its structure. The
//! matched bytes keep their syntax colour and get a background instead,
//! which is what lets a highlighted keyword that was also the match
//! still read as both.
//!
//! Every node's content is built up front rather than filled in when it
//! expands, because the whole point is that `gw-grep` exits and the
//! results stay expandable in the shell's scrollback -- a process that
//! has gone cannot answer a later request for context.

const std = @import("std");
const glyphwire = @import("glyphwire");

const syntax = @import("applib").syntax;

const rg = @import("rg.zig");

const NodeInput = glyphwire.Client.OutlineNodeInput;
const RunInput = glyphwire.Client.OutlineRunInput;

pub const Colors = struct {
    path: glyphwire.Color = .{ .r = 130, .g = 180, .b = 255 },
    count: glyphwire.Color = .{ .r = 110, .g = 110, .b = 120 },
    line_number: glyphwire.Color = .{ .r = 120, .g = 120, .b = 130 },
    /// Source text with no syntax colour of its own (no grammar, or a
    /// byte no capture covers).
    text: glyphwire.Color = .{ .r = 210, .g = 210, .b = 215 },
    /// The hit's line number where it repeats inside its own context, the
    /// "this is the one" marker.
    match: glyphwire.Color = .{ .r = 255, .g = 190, .b = 60 },
    /// Behind the matched bytes. A background rather than a foreground so
    /// the syntax colour underneath survives.
    match_bg: glyphwire.Color = .{ .r = 92, .g = 72, .b = 24 },
    /// Context rows blend every colour they use (syntax, text, match
    /// background) this far towards `dim_toward`: 0 is no dimming, 1 is
    /// all the way. Aimed at a dark terminal background.
    dim_toward: glyphwire.Color = .{ .r = 28, .g = 28, .b = 32 },
    dim_amount: f32 = 0.35,

    /// `c` as a context row draws it.
    pub fn dim(self: Colors, c: glyphwire.Color) glyphwire.Color {
        return .{
            .r = blend(c.r, self.dim_toward.r, self.dim_amount),
            .g = blend(c.g, self.dim_toward.g, self.dim_amount),
            .b = blend(c.b, self.dim_toward.b, self.dim_amount),
            .a = c.a,
        };
    }

    fn blend(from: u8, to: u8, t: f32) u8 {
        const f: f32 = @floatFromInt(from);
        const g: f32 = @floatFromInt(to);
        return @intFromFloat(@round(f + (g - f) * std.math.clamp(t, 0, 1)));
    }
};

/// Syntax spans laid out like `highlight.Highlights.files`: indexed by
/// file (matching the `files` given to `build`), then by line within it.
pub const FileSpans = []const []const []const syntax.Span;

pub const Options = struct {
    ctx: rg.Context,
    colors: Colors = .{},
    /// Whether hits start closed. Files are always open: a listing of
    /// nothing but filenames shows no code at all, which is not what a
    /// grep is for.
    hits_collapsed: bool = true,
    /// Everything closed, files included.
    files_collapsed: bool = false,
    /// Syntax colours for the lines, or null to draw them all plain.
    spans: ?FileSpans = null,
};

/// Owns everything the node list points at. The wire types hold borrowed
/// slices, so the strings have to outlive the `outline_set_nodes` call --
/// this is what keeps them alive and frees them in one go.
pub const Built = struct {
    nodes: []NodeInput,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Built) void {
        self.arena.deinit();
    }
};

/// Builds the node list. `tagger` is either `null` or anything with a
/// `tag(path, line)` method returning the metadata handle a row should
/// carry (so a click on the row's text opens the file at that line).
/// Every source line gets its own tag -- a context line opens where *it*
/// is, not at its hit -- and a line shared by two hits' overlapping
/// windows is tagged once, since each tag is a round trip. Taken as
/// `anytype` rather than a function pointer so the caller can hand over
/// its client and allocator without a global -- `tests/grep_tests.zig`
/// passes `null` and gets untagged nodes.
pub fn build(
    parent_alloc: std.mem.Allocator,
    files: []const rg.FileHits,
    opts: Options,
    tagger: anytype,
) !Built {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var nodes: std.ArrayList(NodeInput) = .empty;

    for (files, 0..) |file, fi| {
        const file_spans: ?[]const []const syntax.Span = if (opts.spans) |sp| sp[fi] else null;
        const count_text = try std.fmt.allocPrint(alloc, "  ({d})", .{file.match_count});
        const file_runs = try alloc.alloc(RunInput, 2);
        file_runs[0] = .{ .text = try alloc.dupe(u8, file.path), .fg = opts.colors.path };
        file_runs[1] = .{ .text = count_text, .fg = opts.colors.count };
        try nodes.append(alloc, .{
            .depth = 0,
            .runs = file_runs,
            .collapsible = true,
            .collapsed = opts.files_collapsed,
        });

        // Widest line number in this file, so a file's hits line up with
        // each other without every file in the run sharing one width.
        var num_width: usize = 1;
        for (file.lines) |l| num_width = @max(num_width, digits(l.number));

        var line_tags: std.AutoHashMapUnmanaged(u64, glyphwire.MetadataHandle) = .empty;

        for (file.lines, 0..) |line, i| {
            if (line.submatches.len == 0) continue;

            const id = try tagFor(alloc, &line_tags, tagger, file.path, line.number);

            try nodes.append(alloc, .{
                .depth = 1,
                .runs = try lineRuns(alloc, line, spansFor(file_spans, i), num_width, opts.colors, opts.colors.line_number, .full),
                .metadata_id = id,
                .collapsible = true,
                .collapsed = opts.hits_collapsed,
            });

            const window = rg.windowFor(file, i, opts.ctx);
            for (window.start..window.end) |w| {
                const cl = file.lines[w];
                const is_hit = w == i;
                const line_id = try tagFor(alloc, &line_tags, tagger, file.path, cl.number);
                try nodes.append(alloc, .{
                    .depth = 2,
                    .runs = try lineRuns(
                        alloc,
                        cl,
                        spansFor(file_spans, w),
                        num_width,
                        opts.colors,
                        if (is_hit) opts.colors.match else opts.colors.line_number,
                        if (is_hit) .full else .dimmed,
                    ),
                    .metadata_id = line_id,
                });
            }
        }
    }

    return .{ .nodes = try nodes.toOwnedSlice(alloc), .arena = arena };
}

/// The metadata handle for `path`'s line `number`, reusing one already
/// made for this file (`cache`), or null with no tagger.
fn tagFor(
    alloc: std.mem.Allocator,
    cache: *std.AutoHashMapUnmanaged(u64, glyphwire.MetadataHandle),
    tagger: anytype,
    path: []const u8,
    number: u64,
) !?glyphwire.MetadataHandle {
    if (@TypeOf(tagger) == @TypeOf(null)) return null;
    const got = try cache.getOrPut(alloc, number);
    if (!got.found_existing) got.value_ptr.* = try tagger.tag(path, number);
    return got.value_ptr.*;
}

/// One source line as a row: right-aligned line number in `number_fg`,
/// then the text cut into runs wherever its style changes. A byte's
/// foreground is its syntax colour from `spans` (`colors.text` where no
/// span covers it), and a matched byte also gets `colors.match_bg`
/// behind it. This is what runs on a node buy -- the match stands out
/// without the server knowing what a match is.
///
/// The three callers differ only in the number colour and `strength`:
///
/// - a hit's own label: plain number, full strength
/// - that hit repeated inside its body: **number in the match colour**,
///   full strength -- the "this is the one" marker
/// - a context line: plain number, every colour dimmed. It still splits
///   on submatches, so a second hit that happens to fall inside this
///   hit's window is visibly another hit (a dimmed background) rather
///   than a plain line.
fn lineRuns(
    alloc: std.mem.Allocator,
    line: rg.Line,
    spans: []const syntax.Span,
    num_width: usize,
    colors: Colors,
    number_fg: glyphwire.Color,
    strength: Strength,
) ![]RunInput {
    var runs: std.ArrayList(RunInput) = .empty;
    try runs.append(alloc, .{
        .text = try std.fmt.allocPrint(alloc, "{d: >[1]}  ", .{ line.number, num_width }),
        .fg = number_fg,
    });

    const match_bg = if (strength == .dimmed) colors.dim(colors.match_bg) else colors.match_bg;
    var styler: Styler = .{ .spans = spans, .matches = line.submatches, .default_fg = colors.text };
    var start: usize = 0;
    while (start < line.text.len) {
        const style = styler.at(start);
        var end = start + 1;
        while (end < line.text.len and style.eql(styler.at(end))) end += 1;
        try runs.append(alloc, .{
            .text = try alloc.dupe(u8, line.text[start..end]),
            .fg = if (strength == .dimmed) colors.dim(style.fg) else style.fg,
            .bg = if (style.matched) match_bg else null,
        });
        start = end;
    }
    return runs.toOwnedSlice(alloc);
}

const Strength = enum { full, dimmed };

fn spansFor(file_spans: ?[]const []const syntax.Span, line_index: usize) []const syntax.Span {
    const sp = file_spans orelse return &.{};
    return sp[line_index];
}

/// A byte's style, found by walking the sorted syntax spans and
/// submatches alongside the line. `at` must be called with non-decreasing
/// offsets, which is how `lineRuns` scans.
const Styler = struct {
    spans: []const syntax.Span,
    matches: []const rg.Range,
    default_fg: glyphwire.Color,
    span_i: usize = 0,
    match_i: usize = 0,

    const Style = struct {
        fg: glyphwire.Color,
        matched: bool,

        fn eql(a: Style, b: Style) bool {
            return a.matched == b.matched and
                a.fg.r == b.fg.r and a.fg.g == b.fg.g and a.fg.b == b.fg.b and a.fg.a == b.fg.a;
        }
    };

    fn at(self: *Styler, pos: usize) Style {
        while (self.span_i < self.spans.len and self.spans[self.span_i].end <= pos) self.span_i += 1;
        while (self.match_i < self.matches.len and self.matches[self.match_i].end <= pos) self.match_i += 1;
        const in_span = self.span_i < self.spans.len and self.spans[self.span_i].start <= pos;
        return .{
            .fg = if (in_span) self.spans[self.span_i].color else self.default_fg,
            .matched = self.match_i < self.matches.len and self.matches[self.match_i].start <= pos,
        };
    }
};

fn digits(n: u64) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}
