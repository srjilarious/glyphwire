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
//! Every node's content is built up front rather than filled in when it
//! expands, because the whole point is that `gw-grep` exits and the
//! results stay expandable in the shell's scrollback -- a process that
//! has gone cannot answer a later request for context.

const std = @import("std");
const glyphwire = @import("glyphwire");

const rg = @import("rg.zig");

const NodeInput = glyphwire.Client.OutlineNodeInput;
const RunInput = glyphwire.Client.OutlineRunInput;

pub const Colors = struct {
    path: glyphwire.Color = .{ .r = 130, .g = 180, .b = 255 },
    count: glyphwire.Color = .{ .r = 110, .g = 110, .b = 120 },
    line_number: glyphwire.Color = .{ .r = 120, .g = 120, .b = 130 },
    text: glyphwire.Color = .{ .r = 210, .g = 210, .b = 215 },
    /// The matched bytes. The one thing on the row that should catch the
    /// eye, so it is the only saturated colour in a hit's line.
    match: glyphwire.Color = .{ .r = 255, .g = 190, .b = 60 },
    context: glyphwire.Color = .{ .r = 150, .g = 150, .b = 158 },
};

pub const Options = struct {
    ctx: rg.Context,
    colors: Colors = .{},
    /// Whether hits start closed. Files are always open: a listing of
    /// nothing but filenames shows no code at all, which is not what a
    /// grep is for.
    hits_collapsed: bool = true,
    /// Everything closed, files included.
    files_collapsed: bool = false,
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
/// `tag(path, line)` method returning the metadata handle a hit's row
/// should carry (so a click on the row's text opens the file). Taken as
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

    for (files) |file| {
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

        for (file.lines, 0..) |line, i| {
            if (line.submatches.len == 0) continue;

            const id: ?glyphwire.MetadataHandle = if (@TypeOf(tagger) == @TypeOf(null))
                null
            else
                try tagger.tag(file.path, line.number);

            try nodes.append(alloc, .{
                .depth = 1,
                .runs = try lineRuns(alloc, line, num_width, opts.colors, opts.colors.line_number, opts.colors.text),
                .metadata_id = id,
                .collapsible = true,
                .collapsed = opts.hits_collapsed,
            });

            const window = rg.windowFor(file, i, opts.ctx);
            for (window.start..window.end) |w| {
                const cl = file.lines[w];
                const is_hit = w == i;
                try nodes.append(alloc, .{
                    .depth = 2,
                    .runs = try lineRuns(
                        alloc,
                        cl,
                        num_width,
                        opts.colors,
                        if (is_hit) opts.colors.match else opts.colors.line_number,
                        if (is_hit) opts.colors.text else opts.colors.context,
                    ),
                    .metadata_id = id,
                });
            }
        }
    }

    return .{ .nodes = try nodes.toOwnedSlice(alloc), .arena = arena };
}

/// One source line as a row: right-aligned line number in `number_fg`,
/// then the text split so each matched range gets its own run in the
/// match colour and everything between it stays `base_fg`. This is what
/// `spans` on a node buys -- the match stands out without the server
/// knowing what a match is.
///
/// The three callers differ only in those two colours:
///
/// - a hit's own label: plain number, `text` base
/// - that hit repeated inside its body: **number in the match colour**,
///   `text` base -- the "this is the one" marker
/// - a context line: plain number, dimmer `context` base. It still
///   splits on submatches, so a second hit that happens to fall inside
///   this hit's window is visibly another hit rather than a plain line.
fn lineRuns(
    alloc: std.mem.Allocator,
    line: rg.Line,
    num_width: usize,
    colors: Colors,
    number_fg: glyphwire.Color,
    base_fg: glyphwire.Color,
) ![]RunInput {
    var runs: std.ArrayList(RunInput) = .empty;
    try runs.append(alloc, .{
        .text = try std.fmt.allocPrint(alloc, "{d: >[1]}  ", .{ line.number, num_width }),
        .fg = number_fg,
    });

    var cursor: usize = 0;
    for (line.submatches) |m| {
        if (m.start > cursor) {
            try runs.append(alloc, .{
                .text = try alloc.dupe(u8, line.text[cursor..m.start]),
                .fg = base_fg,
            });
        }
        try runs.append(alloc, .{
            .text = try alloc.dupe(u8, line.text[m.start..m.end]),
            .fg = colors.match,
        });
        cursor = m.end;
    }
    if (cursor < line.text.len) {
        try runs.append(alloc, .{
            .text = try alloc.dupe(u8, line.text[cursor..]),
            .fg = base_fg,
        });
    }
    return runs.toOwnedSlice(alloc);
}

fn digits(n: u64) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}
