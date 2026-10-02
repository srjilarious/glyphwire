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
const syntax = @import("applib").syntax;
const highlight_mod = @import("grep_support").highlight;

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
    var p = rg.Parser.init(alloc, null);
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
    var p = rg.Parser.init(alloc, null);
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

    // a.zig: file + hit(10) + its 4 body rows (the window *includes* the
    // hit's own line) + hit(40) + its 1 body row, which is just itself;
    // then b.zig: file + hit(7) + its 1 body row.
    try testz.expectEqual(built.nodes.len, 11);

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

/// `max_hits` keeps the first N matches across files and flags the run as
/// truncated when the next one arrives, so gw-grep can stop ripgrep and
/// say so. The kept hit's after-context still lands before the cut.
pub fn grepMaxHitsStopsAtTheCapTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var p = rg.Parser.init(alloc, 1);
    defer p.deinit();
    var it = std.mem.splitScalar(u8, sample, '\n');
    while (it.next()) |line| {
        if (p.truncated) break;
        try p.feedLine(line);
    }
    try p.finish();
    try testz.expectTrue(p.truncated);
    try testz.expectEqual(p.total_matches, 1);

    const files = try p.take();
    defer freeFiles(alloc, files);
    // Only a.zig, with the line-10 hit and its context (9, 11, 12) but not
    // the line-40 hit that tripped the cap.
    try testz.expectEqual(files.len, 1);
    try testz.expectEqual(files[0].match_count, 1);
    try testz.expectEqual(files[0].lines.len, 4);
    try testz.expectEqual(files[0].lines[3].number, 12);
}

/// Stands in for gw-grep's session-backed tagger: the handle is the line
/// number (plus 1000 for `src/b.zig`), and every call is counted.
const FakeTagger = struct {
    calls: usize = 0,

    pub fn tag(self: *FakeTagger, path: []const u8, line: u64) !glyphwire.MetadataHandle {
        self.calls += 1;
        const base: u64 = if (std.mem.eql(u8, path, "src/b.zig")) 1000 else 0;
        return @intCast(base + line);
    }
};

pub fn grepEachLineIsTaggedWithItsOwnLineOnceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    var tagger = FakeTagger{};
    var built = try nodes_mod.build(alloc, files, .{ .ctx = .{ .before = 1, .after = 2 } }, &tagger);
    defer built.deinit();

    // Layout as in `grepBuildsThreeLevelNodesTest`: a.zig file, hit 10,
    // body 9/10/11/12, hit 40, body 40, b.zig file, hit 7, body 7.
    try testz.expectTrue(built.nodes[0].metadata_id == null); // file rows open nothing
    try testz.expectEqual(built.nodes[1].metadata_id.?, 10);
    try testz.expectEqual(built.nodes[2].metadata_id.?, 9); // context opens at its own line
    try testz.expectEqual(built.nodes[3].metadata_id.?, 10); // the hit's repeat shares the hit's tag
    try testz.expectEqual(built.nodes[4].metadata_id.?, 11);
    try testz.expectEqual(built.nodes[5].metadata_id.?, 12);
    try testz.expectEqual(built.nodes[7].metadata_id.?, 40);
    try testz.expectEqual(built.nodes[10].metadata_id.?, 1007);

    // One tag per distinct (file, line): 9, 10, 11, 12, 40 and b's 7.
    try testz.expectEqual(tagger.calls, 6);
}

pub fn grepHitRowSplitsTheMatchIntoItsOwnRunTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    var built = try nodes_mod.build(alloc, files, .{ .ctx = .{ .before = 1, .after = 2 } }, null);
    defer built.deinit();

    // "pub fn init() void {" with the match at bytes 4..11 becomes
    // number / "pub " / "fn init" / "() void {" -- the split that lets
    // the matched bytes carry their own background. With no syntax spans
    // every byte keeps the plain text colour.
    const colors = nodes_mod.Colors{};
    const hit = built.nodes[1];
    try testz.expectEqual(hit.runs.len, 4);
    try testz.expectEqualStr("pub ", hit.runs[1].text);
    try testz.expectEqualStr("fn init", hit.runs[2].text);
    try testz.expectEqualStr("() void {", hit.runs[3].text);
    try testz.expectEqual(hit.runs[2].fg.?.r, colors.text.r);
    try testz.expectEqual(hit.runs[2].bg.?.r, colors.match_bg.r);
    try testz.expectEqual(hit.runs[1].fg.?.r, colors.text.r);
    try testz.expectTrue(hit.runs[1].bg == null);

    // The line-40 match, which starts at byte 0, so it has no leading
    // run before the highlight. It follows the first hit's four body
    // rows, at index 6.
    const hit2 = built.nodes[6];
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
    var storage = std.heap.ArenaAllocator.init(alloc);
    const a = storage.allocator();
    const core_nodes = try a.alloc(glyphwire.OutlineNode, built.nodes.len);
    for (built.nodes, 0..) |n, i| {
        const runs = try a.alloc(glyphwire.Layer.TextRun, n.runs.len);
        for (n.runs, 0..) |r, ri| {
            runs[ri] = .{
                .text = try a.dupe(u8, r.text),
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
    outline.setNodes(.{ .storage = storage, .nodes = core_nodes });
    try outline.render(&ctx.root, &ctx);

    // Files open, hits closed: two files and three hits = 5 rows.
    try testz.expectEqual(outline.visibleRows(), 5);
    try testz.expectEqualStr("\u{25BE}", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("s", ctx.root.cell(0, 2).grapheme());
    try testz.expectEqualStr("\u{25B8}", ctx.root.cell(1, 2).grapheme());

    // Expanding the first hit reveals its four body rows -- three context
    // lines plus the hit's own line sitting among them.
    try outline.setNodeCollapsed(&ctx.root, &ctx, 1, false);
    try testz.expectEqual(outline.visibleRows(), 9);
}

pub fn grepHitLineIsRepeatedInItsBodyWithALitNumberTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const files = try parseSample(alloc, sample);
    defer freeFiles(alloc, files);

    var built = try nodes_mod.build(alloc, files, .{ .ctx = .{ .before = 1, .after = 2 } }, null);
    defer built.deinit();

    const colors = nodes_mod.Colors{};

    // Body rows 2..5 are lines 9, 10, 11, 12 -- the hit at line 10 sits
    // among its own context rather than leaving a hole where it belongs.
    try testz.expectEqualStr(" 9  ", built.nodes[2].runs[0].text);
    try testz.expectEqualStr("10  ", built.nodes[3].runs[0].text);
    try testz.expectEqualStr("11  ", built.nodes[4].runs[0].text);
    try testz.expectEqualStr("12  ", built.nodes[5].runs[0].text);

    // Only the hit's own row has its line number in the match colour;
    // that is what marks which line you searched for.
    try testz.expectEqual(built.nodes[3].runs[0].fg.?.r, colors.match.r);
    try testz.expectEqual(built.nodes[3].runs[0].fg.?.g, colors.match.g);
    try testz.expectEqual(built.nodes[2].runs[0].fg.?.r, colors.line_number.r);
    try testz.expectEqual(built.nodes[4].runs[0].fg.?.r, colors.line_number.r);

    // And the repeated line still splits on its match, so the matched
    // bytes stay highlighted inside the body too, at full strength.
    try testz.expectEqual(built.nodes[3].runs.len, 4);
    try testz.expectEqualStr("fn init", built.nodes[3].runs[2].text);
    try testz.expectEqual(built.nodes[3].runs[2].bg.?.r, colors.match_bg.r);
    try testz.expectEqual(built.nodes[3].runs[1].fg.?.r, colors.text.r);

    // A plain context row is one run of text in the dimmed colour.
    try testz.expectEqual(built.nodes[2].runs.len, 2);
    try testz.expectEqual(built.nodes[2].runs[1].fg.?.r, colors.dim(colors.text).r);
}

pub fn grepSyntaxSpansColourRunsAndKeepTheMatchBackgroundTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const kw: glyphwire.Color = .{ .r = 200, .g = 100, .b = 220 };
    const fnc: glyphwire.Color = .{ .r = 90, .g = 170, .b = 240 };

    // "pub fn init() {" -- `pub`/`fn` keywords, `init` a function name,
    // and the match covering "fn init", straddling two syntax colours.
    var sub = [_]rg.Range{.{ .start = 4, .end = 11 }};
    var lines = [_]rg.Line{.{ .number = 1, .text = @constCast("pub fn init() {"), .submatches = &sub }};
    var files = [_]rg.FileHits{.{ .path = @constCast("a.zig"), .lines = &lines, .match_count = 1 }};
    const line_spans = [_]syntax.Span{
        .{ .start = 0, .end = 3, .color = kw },
        .{ .start = 4, .end = 6, .color = kw },
        .{ .start = 7, .end = 11, .color = fnc },
    };
    const per_line = [_][]const syntax.Span{&line_spans};
    const per_file = [_][]const []const syntax.Span{&per_line};

    var built = try nodes_mod.build(alloc, &files, .{
        .ctx = .{ .before = 0, .after = 0 },
        .spans = &per_file,
    }, null);
    defer built.deinit();

    const colors = nodes_mod.Colors{};
    // number / "pub" kw / " " plain / "fn" kw+bg / " " plain+bg /
    // "init" fn+bg / "() {" plain.
    const hit = built.nodes[1];
    try testz.expectEqual(hit.runs.len, 7);
    try testz.expectEqualStr("pub", hit.runs[1].text);
    try testz.expectEqual(hit.runs[1].fg.?.r, kw.r);
    try testz.expectTrue(hit.runs[1].bg == null);
    try testz.expectEqualStr("fn", hit.runs[3].text);
    try testz.expectEqual(hit.runs[3].fg.?.r, kw.r);
    try testz.expectEqual(hit.runs[3].bg.?.r, colors.match_bg.r);
    try testz.expectEqualStr(" ", hit.runs[4].text);
    try testz.expectEqual(hit.runs[4].fg.?.r, colors.text.r);
    try testz.expectEqual(hit.runs[4].bg.?.r, colors.match_bg.r);
    try testz.expectEqualStr("init", hit.runs[5].text);
    try testz.expectEqual(hit.runs[5].fg.?.b, fnc.b);
    try testz.expectEqualStr("() {", hit.runs[6].text);
    try testz.expectTrue(hit.runs[6].bg == null);

    // The same line inside its own body is the hit, so full strength.
    try testz.expectEqual(built.nodes[2].runs[1].fg.?.r, kw.r);
}

pub fn grepContextRowsDimTheirSyntaxColoursTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const kw: glyphwire.Color = .{ .r = 200, .g = 100, .b = 220 };

    // A hit on line 1 with line 2 as its after-context; line 2 also holds
    // a match of its own, which should get the dimmed background.
    var sub1 = [_]rg.Range{.{ .start = 0, .end = 2 }};
    var sub2 = [_]rg.Range{.{ .start = 4, .end = 6 }};
    var lines = [_]rg.Line{
        .{ .number = 1, .text = @constCast("fn a() {}"), .submatches = &sub1 },
        .{ .number = 2, .text = @constCast("pub fn b() {}"), .submatches = &sub2 },
    };
    var files = [_]rg.FileHits{.{ .path = @constCast("a.zig"), .lines = &lines, .match_count = 2 }};
    const spans1 = [_]syntax.Span{.{ .start = 0, .end = 2, .color = kw }};
    const spans2 = [_]syntax.Span{
        .{ .start = 0, .end = 3, .color = kw },
        .{ .start = 4, .end = 6, .color = kw },
    };
    const per_line = [_][]const syntax.Span{ &spans1, &spans2 };
    const per_file = [_][]const []const syntax.Span{&per_line};

    var built = try nodes_mod.build(alloc, &files, .{
        .ctx = .{ .before = 0, .after = 1 },
        .spans = &per_file,
    }, null);
    defer built.deinit();

    const colors = nodes_mod.Colors{};
    // nodes: file, hit 1, [line 1, line 2], hit 2, [line 2]
    const ctx_row = built.nodes[3];
    try testz.expectEqualStr("pub", ctx_row.runs[1].text);
    try testz.expectEqual(ctx_row.runs[1].fg.?.r, colors.dim(kw).r);
    try testz.expectEqual(ctx_row.runs[1].fg.?.g, colors.dim(kw).g);
    try testz.expectTrue(ctx_row.runs[1].bg == null);
    try testz.expectEqualStr("fn", ctx_row.runs[3].text);
    try testz.expectEqual(ctx_row.runs[3].bg.?.r, colors.dim(colors.match_bg).r);
    try testz.expectEqual(ctx_row.runs[2].fg.?.r, colors.dim(colors.text).r);

    // Dimming actually moves a colour, and towards the dark target.
    try testz.expectTrue(colors.dim(kw).r < kw.r);
}

/// Where `zig build` installs the grammars; the highlight test no-ops
/// without them, the same way zoe's syntax tests do.
const grammar_test_dir = "zig-out/share/glyphwire/grammars";
const highlight_test_dir = ".zig-cache/tmp/gw-grep-highlight-test";

pub fn grepHighlightParsesTheWholeFileTest(io: std.Io, alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().access(io, grammar_test_dir ++ "/c/libtree-sitter-c.so", .{}) catch return;

    try std.Io.Dir.cwd().createDirPath(io, highlight_test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, highlight_test_dir) catch {};
    const path = highlight_test_dir ++ "/a.c";
    // Line 2 sits inside a block comment that opened on line 1, which
    // only a parse of the whole file can know.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "/* start\nint not_code = 1;\n*/\nint x = 2;\n",
    });

    var sub = [_]rg.Range{.{ .start = 4, .end = 5 }};
    var lines = [_]rg.Line{
        .{ .number = 2, .text = @constCast("int not_code = 1;") },
        .{ .number = 4, .text = @constCast("int x = 2;"), .submatches = &sub },
        // Not what line 4 says on disk any more: left plain.
        .{ .number = 4, .text = @constCast("int y = 2;") },
    };
    var files = [_]rg.FileHits{.{ .path = @constCast(path), .lines = &lines, .match_count = 1 }};

    var registry = syntax.Registry.init(alloc, io, &.{grammar_test_dir}, &syntax.default_langs);
    defer registry.deinit();
    const theme = syntax.Theme.initDefault();
    var got = try highlight_mod.compute(alloc, io, &registry, theme, &files);
    defer got.deinit();

    const comment = theme.colorFor("comment").?;
    const in_comment = got.files[0][0];
    try testz.expectEqual(in_comment.len, 1);
    try testz.expectEqual(in_comment[0].start, 0);
    try testz.expectEqual(in_comment[0].end, 17);
    try testz.expectTrue(in_comment[0].color.eql(comment));

    // Real code: `int` gets the type colour, not the comment one.
    const code = got.files[0][1];
    try testz.expectTrue(code.len > 0);
    try testz.expectEqual(code[0].start, 0);
    try testz.expectTrue(code[0].color.eql(theme.colorFor("type").?));

    try testz.expectEqual(got.files[0][2].len, 0);
}
