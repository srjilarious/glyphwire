// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-grep's pure halves: the `rg --json` parser and the outline node
//! builder. Driven against captured ripgrep output rather than a live
//! subprocess, so these need neither ripgrep installed nor a session --
//! the reason `grep/support.zig` exists (see `tests/ls_tests.zig` for the
//! same split).

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const rg = @import("grep_support").rg;
const nodes_mod = @import("grep_support").nodes;

/// Real `rg --json -B1 -A2 'fn init' two files` output, trimmed to the
/// fields the parser reads. Two files, three matches, context either side.
const sample =
    \\{"type":"begin","data":{"path":{"text":"src/a.zig"}}}
    \\{"type":"context","data":{"path":{"text":"src/a.zig"},"lines":{"text":"// header\n"},"line_number":9,"submatches":[]}}
    \\{"type":"match","data":{"path":{"text":"src/a.zig"},"lines":{"text":"pub fn init() void {\n"},"line_number":10,"submatches":[{"match":{"text":"fn init"},"start":4,"end":11}]}}
    \\{"type":"context","data":{"path":{"text":"src/a.zig"},"lines":{"text":"    body one\n"},"line_number":11,"submatches":[]}}
    \\{"type":"context","data":{"path":{"text":"src/a.zig"},"lines":{"text":"    body two\n"},"line_number":12,"submatches":[]}}
    \\{"type":"match","data":{"path":{"text":"src/a.zig"},"lines":{"text":"fn initTwo() void {\n"},"line_number":40,"submatches":[{"match":{"text":"fn init"},"start":0,"end":7}]}}
    \\{"type":"end","data":{"path":{"text":"src/a.zig"}}}
    \\{"type":"begin","data":{"path":{"text":"src/b.zig"}}}
    \\{"type":"match","data":{"path":{"text":"src/b.zig"},"lines":{"text":"fn init() !void {\n"},"line_number":7,"submatches":[{"match":{"text":"fn init"},"start":0,"end":7}]}}
    \\{"type":"end","data":{"path":{"text":"src/b.zig"}}}
    \\{"data":{"elapsed_total":{"human":"0.005s"}},"type":"summary"}
;

fn parseSample(alloc: std.mem.Allocator, text: []const u8) ![]rg.FileHits {
    var p = rg.Parser.init(alloc);
    defer p.deinit();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try p.feedLine(line);
    try p.finish();
    return p.take();
}

fn freeFiles(alloc: std.mem.Allocator, files: []rg.FileHits) void {
    for (files) |f| f.deinit(alloc);
    alloc.free(files);
}

pub fn grepParsesFilesMatchesAndContextTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    try testz.expectEqual(files.len, 2);
    try testz.expectEqualStr("src/a.zig", files[0].path);
    try testz.expectEqual(files[0].match_count, 2);
    // Five lines: one before-context, the match, two after, and the
    // second match far below.
    try testz.expectEqual(files[0].lines.len, 5);
    try testz.expectEqual(files[0].lines[1].number, 10);
    try testz.expectEqualStr("pub fn init() void {", files[0].lines[1].text);

    try testz.expectEqualStr("src/b.zig", files[1].path);
    try testz.expectEqual(files[1].match_count, 1);
}

pub fn grepRecordsSubmatchOffsetsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    const m = files[0].lines[1];
    try testz.expectEqual(m.submatches.len, 1);
    try testz.expectEqual(m.submatches[0].start, 4);
    try testz.expectEqual(m.submatches[0].end, 11);
    try testz.expectEqualStr("fn init", m.text[m.submatches[0].start..m.submatches[0].end]);

    // A context line carries none, which is how the node builder tells
    // the two apart.
    try testz.expectEqual(files[0].lines[0].submatches.len, 0);
}

pub fn grepSanitizeKeepsByteOffsetsStableTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // A tab becomes one space rather than expanding to a tab stop,
    // precisely so ripgrep's byte offsets still line up afterwards.
    const out = try rg.sanitize(alloc, "\tfn init()\r\n");
    defer alloc.free(out);
    try testz.expectEqualStr(" fn init()", out);
    try testz.expectEqual(out.len, 10);
}

pub fn grepMalformedLinesAreSkippedNotFatalTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const messy =
        \\{"type":"begin","data":{"path":{"text":"x.zig"}}}
        \\not json at all
        \\{"type":"somethingNew","data":{}}
        \\{"type":"match","data":{"path":{"text":"x.zig"},"lines":{"text":"hit\n"},"line_number":1,"submatches":[{"match":{"text":"h"},"start":0,"end":1}]}}
        \\{"type":"end","data":{"path":{"text":"x.zig"}}}
    ;
    const files = try parseSample(alloc, messy);
    defer freeFiles(alloc, files);

    // ripgrep is free to add event types, and one bad line shouldn't cost
    // a whole search.
    try testz.expectEqual(files.len, 1);
    try testz.expectEqual(files[0].match_count, 1);
}

pub fn grepBinaryLinesAreCountedNotDrawnTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // ripgrep sends `bytes` (base64) instead of `text` for undecodable
    // content. Drawing that would be mojibake, so it is skipped.
    const binary =
        \\{"type":"begin","data":{"path":{"text":"blob.bin"}}}
        \\{"type":"match","data":{"path":{"text":"blob.bin"},"lines":{"bytes":"AAEC"},"line_number":1,"submatches":[]}}
        \\{"type":"end","data":{"path":{"text":"blob.bin"}}}
    ;
    var p = rg.Parser.init(alloc);
    defer p.deinit();
    var it = std.mem.splitScalar(u8, binary, '\n');
    while (it.next()) |line| try p.feedLine(line);
    try p.finish();
    const files = try p.take();
    defer freeFiles(alloc, files);

    // A file with nothing usable contributes no node at all.
    try testz.expectEqual(files.len, 0);
    try testz.expectEqual(p.skipped, 1);
}

pub fn grepWindowGivesEachHitItsOwnContextTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    // Match at line 10 with -B1 -A2: the context line at 9 and the two at
    // 11/12, but not the far-off match at line 40.
    const w = rg.windowFor(files[0], 1, .{ .before = 1, .after = 2 });
    try testz.expectEqual(w.start, 0);
    try testz.expectEqual(w.end, 4);

    // The match at line 40 has nothing reported near it.
    const w2 = rg.windowFor(files[0], 4, .{ .before = 1, .after = 2 });
    try testz.expectEqual(w2.start, 4);
    try testz.expectEqual(w2.end, 5);
}

pub fn grepBuildsThreeLevelNodesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    var built = try nodes_mod.build(alloc, files, .{ .ctx = .{ .before = 1, .after = 2 } }, null);
    defer built.deinit();

    // a.zig: file + hit(10) + its 3 context rows + hit(40), which has no
    // reported lines near it; then b.zig: file + hit(7).
    try testz.expectEqual(built.nodes.len, 8);

    try testz.expectEqual(built.nodes[0].depth, 0);
    try testz.expectTrue(built.nodes[0].collapsible);
    try testz.expectTrue(!built.nodes[0].collapsed); // files open by default
    try testz.expectEqualStr("src/a.zig", built.nodes[0].runs[0].text);
    try testz.expectEqualStr("  (2)", built.nodes[0].runs[1].text);

    try testz.expectEqual(built.nodes[1].depth, 1);
    try testz.expectTrue(built.nodes[1].collapsible);
    try testz.expectTrue(built.nodes[1].collapsed); // hits closed by default

    // Its context rows are leaves.
    try testz.expectEqual(built.nodes[2].depth, 2);
    try testz.expectTrue(!built.nodes[2].collapsible);
}

pub fn grepHitRowSplitsTheMatchIntoItsOwnRunTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    var built = try nodes_mod.build(alloc, files, .{ .ctx = .{ .before = 1, .after = 2 } }, null);
    defer built.deinit();

    // "pub fn init() void {" with the match at bytes 4..11 becomes
    // number / "pub " / "fn init" / "() void {" -- the split that lets
    // the matched bytes carry their own colour.
    const hit = built.nodes[1];
    try testz.expectEqual(hit.runs.len, 4);
    try testz.expectEqualStr("pub ", hit.runs[1].text);
    try testz.expectEqualStr("fn init", hit.runs[2].text);
    try testz.expectEqualStr("() void {", hit.runs[3].text);
    try testz.expectEqual(hit.runs[2].fg.?.r, 255);
    try testz.expectEqual(hit.runs[1].fg.?.r, 210);

    // The line-40 match, which starts at byte 0, so it has no leading
    // run before the highlight. It follows the first hit's three context
    // rows, at index 5.
    const hit2 = built.nodes[5];
    try testz.expectEqualStr("fn init", hit2.runs[1].text);
}

pub fn grepCollapseAndExpandOptionsSetInitialStateTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    {
        var built = try nodes_mod.build(alloc, files, .{
            .ctx = .{ .before = 1, .after = 2 },
            .hits_collapsed = false,
        }, null);
        defer built.deinit();
        try testz.expectTrue(!built.nodes[1].collapsed);
    }
    {
        var built = try nodes_mod.build(alloc, files, .{
            .ctx = .{ .before = 1, .after = 2 },
            .files_collapsed = true,
        }, null);
        defer built.deinit();
        try testz.expectTrue(built.nodes[0].collapsed);
    }
}

pub fn grepBuiltNodesDriveARealOutlineTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // The end of the chain: ripgrep output -> nodes -> painted cells.
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);
    var built = try nodes_mod.build(alloc, files, .{ .ctx = .{ .before = 1, .after = 2 } }, null);
    defer built.deinit();

    var ctx = try glyphwire.Context.init(alloc, 60, 20, 40);
    defer ctx.deinit();

    const style: glyphwire.OutlineStyle = .{
        .marker_collapsed = try alloc.dupe(u8, "\u{25B8}"),
        .marker_expanded = try alloc.dupe(u8, "\u{25BE}"),
    };
    const h = try ctx.createOutline(null, 0, 0, 60, style);
    const outline = ctx.root.outlines.getPtr(h).?;

    // Convert the client-side node inputs to core nodes the same way the
    // dispatcher would, minus the JSON hop.
    const core_nodes = try alloc.alloc(glyphwire.OutlineNode, built.nodes.len);
    for (built.nodes, 0..) |n, i| {
        const runs = try alloc.alloc(glyphwire.Layer.TextRun, n.runs.len);
        for (n.runs, 0..) |r, ri| {
            runs[ri] = .{
                .text = try alloc.dupe(u8, r.text),
                .fg = r.fg orelse glyphwire.default_style.fg,
                .bg = null,
            };
        }
        core_nodes[i] = .{
            .depth = n.depth,
            .runs = runs,
            .collapsible = n.collapsible,
            .collapsed = n.collapsed,
        };
    }
    outline.setNodes(core_nodes);
    try outline.render(&ctx.root, &ctx);

    // Files open, hits closed: two files and three hits = 5 rows.
    try testz.expectEqual(outline.visibleRows(), 5);
    try testz.expectEqualStr("\u{25BE}", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("s", ctx.root.cell(0, 2).grapheme());
    try testz.expectEqualStr("\u{25B8}", ctx.root.cell(1, 2).grapheme());

    // Expanding the first hit reveals its three context rows.
    try outline.setNodeCollapsed(&ctx.root, &ctx, 1, false);
    try testz.expectEqual(outline.visibleRows(), 8);
}
