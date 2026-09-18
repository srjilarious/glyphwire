// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");

// gwmd is an executable, but its parser (the vendored zmd fork), layout
// and link handling are gathered into the `md_support` module (see
// build.zig) so they can be exercised here without a window.
const md = @import("md_support");
const Doc = md.Document;
const Run = md.zmd.Inline.Run;
const layout = md.layout;
const nav = md.nav;

fn parse(alloc: std.mem.Allocator, src: []const u8) !Doc {
    return Doc.parse(alloc, src);
}

fn paragraphRuns(doc: *const Doc, i: usize) []const Run {
    return doc.blocks[i].paragraph.runs;
}

// ─── Inline parsing ─────────────────────────────────────────────────────

pub fn inlineStylesSplitIntoRunsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "a **b** _c_ `d` ~~e~~\n");
    defer doc.deinit();
    const runs = paragraphRuns(&doc, 0);
    try testz.expectEqual(runs.len, 8);
    try testz.expectEqualStr("b", runs[1].text);
    try testz.expectTrue(runs[1].style.bold);
    try testz.expectEqualStr("c", runs[3].text);
    try testz.expectTrue(runs[3].style.italic);
    try testz.expectEqualStr("d", runs[5].text);
    try testz.expectTrue(runs[5].style.code);
    try testz.expectEqualStr("e", runs[7].text);
    try testz.expectTrue(runs[7].style.strike);
}

/// `_` inside a word is literal, and a `*` with spaces both sides can't
/// open or close -- the two cases zmd's own inline pass gets wrong.
pub fn intrawordUnderscoreAndSpacedStarStayLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "snake_case_name and a * b * c\n");
    defer doc.deinit();
    const runs = paragraphRuns(&doc, 0);
    try testz.expectEqual(runs.len, 1);
    try testz.expectEqualStr("snake_case_name and a * b * c", runs[0].text);
}

pub fn nestedEmphasisPairsOuterDelimitersTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "*a **b** c*\n");
    defer doc.deinit();
    const runs = paragraphRuns(&doc, 0);
    try testz.expectEqual(runs.len, 3);
    try testz.expectTrue(runs[0].style.italic and !runs[0].style.bold);
    try testz.expectTrue(runs[1].style.italic and runs[1].style.bold);
    try testz.expectEqualStr("b", runs[1].text);
    try testz.expectTrue(runs[2].style.italic and !runs[2].style.bold);
}

/// A link inside bold keeps the bold, and every run of one link shares
/// one link index.
pub fn linkInsideBoldKeepsStyleAndIndexTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "**x [a *b*](t.md) y**\n");
    defer doc.deinit();
    const runs = paragraphRuns(&doc, 0);
    try testz.expectEqual(doc.links.len, 1);
    try testz.expectEqualStr("t.md", doc.links[0].href);
    var linked: usize = 0;
    for (runs) |r| {
        try testz.expectTrue(r.style.bold);
        if (r.link) |li| {
            try testz.expectEqual(li, 0);
            linked += 1;
        }
    }
    try testz.expectEqual(linked, 2);
}

/// `[![alt](a.png)](url)`: the image survives as an image, and carries
/// the surrounding link.
pub fn imageInsideLinkIsALinkedImageTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "[![alt text](a.png)](http://y.com)\n");
    defer doc.deinit();
    const runs = paragraphRuns(&doc, 0);
    try testz.expectEqual(runs.len, 1);
    try testz.expectEqual(runs[0].kind, .image);
    try testz.expectEqualStr("a.png", runs[0].src);
    try testz.expectEqualStr("alt text", runs[0].text);
    try testz.expectEqual(runs[0].link.?, 0);
    try testz.expectEqualStr("http://y.com", doc.links[0].href);
}

pub fn autolinksAndBareUrlsBecomeLinksTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "see <http://a.com> and https://b.com/x_(y). and <me@c.org>\n");
    defer doc.deinit();
    try testz.expectEqual(doc.links.len, 3);
    try testz.expectEqualStr("http://a.com", doc.links[0].href);
    // The sentence's full stop isn't part of the URL; balanced parens are.
    try testz.expectEqualStr("https://b.com/x_(y)", doc.links[1].href);
    try testz.expectEqualStr("mailto:me@c.org", doc.links[2].href);
}

pub fn referenceLinksResolveFromLaterDefinitionsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "[one][Ref] and [ref][] and [ref]\n\n[ref]: http://r.example \"Title\"\n");
    defer doc.deinit();
    // The definition itself renders nothing.
    try testz.expectEqual(doc.blocks.len, 1);
    try testz.expectEqual(doc.links.len, 3);
    for (doc.links) |l| try testz.expectEqualStr("http://r.example", l.href);
    try testz.expectEqualStr("Title", doc.links[0].title);
}

pub fn escapesAndCodeSpanBackticksTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "\\*not em\\* and `` a`b ``\n");
    defer doc.deinit();
    const runs = paragraphRuns(&doc, 0);
    try testz.expectEqualStr("*not em* and ", runs[0].text);
    try testz.expectEqualStr("a`b", runs[1].text);
    try testz.expectTrue(runs[1].style.code);
}

pub fn twoTrailingSpacesMakeAHardBreakTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "one  \ntwo\nthree\n");
    defer doc.deinit();
    const runs = paragraphRuns(&doc, 0);
    try testz.expectEqual(runs.len, 3);
    try testz.expectEqualStr("one", runs[0].text);
    try testz.expectEqual(runs[1].kind, .line_break);
    // A plain newline is a soft break: a space.
    try testz.expectEqualStr("two three", runs[2].text);
}

// ─── Block parsing ──────────────────────────────────────────────────────

pub fn headingsAtxAndSetextWithUniqueSlugsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "# Hello, World! #\n\nSub\n---\n\n## Hello, World!\n");
    defer doc.deinit();
    try testz.expectEqual(doc.blocks.len, 3);
    const h1 = doc.blocks[0].heading;
    try testz.expectEqual(h1.level, 1);
    try testz.expectEqualStr("hello-world", h1.slug);
    try testz.expectEqual(doc.blocks[1].heading.level, 2);
    try testz.expectEqualStr("sub", doc.blocks[1].heading.slug);
    try testz.expectEqualStr("hello-world-1", doc.blocks[2].heading.slug);
}

pub fn nestedListsTasksAndOrderedStartTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "- a\n  - a1\n  - a2\n- [x] done\n\n3. three\n4. four\n");
    defer doc.deinit();
    try testz.expectEqual(doc.blocks.len, 2);
    const bullets = doc.blocks[0].list;
    try testz.expectFalse(bullets.ordered);
    try testz.expectEqual(bullets.items.len, 2);
    // Item "a": its paragraph, then the nested list.
    try testz.expectEqual(bullets.items[0].blocks.len, 2);
    try testz.expectEqual(bullets.items[0].blocks[1].list.items.len, 2);
    try testz.expectEqual(bullets.items[1].task.?, true);

    const ordered = doc.blocks[1].list;
    try testz.expectTrue(ordered.ordered);
    try testz.expectEqual(ordered.start, 3);
    // "4. four" is a sibling item, not a lazy continuation of "three".
    try testz.expectEqual(ordered.items.len, 2);
    try testz.expectTrue(ordered.tight);
}

pub fn blockQuoteWithLazyContinuationTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "> quoted\nlazy\n> - item\n\nafter\n");
    defer doc.deinit();
    try testz.expectEqual(doc.blocks.len, 2);
    const q = doc.blocks[0].quote;
    try testz.expectEqual(q.len, 2);
    try testz.expectEqualStr("quoted lazy", q[0].paragraph.runs[0].text);
    try testz.expectEqual(q[1].list.items.len, 1);
}

pub fn fencedCodeKeepsContentAndLanguageTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "```zig title\n  const x = *y;\n# not a heading\n```\n\n    indented\n");
    defer doc.deinit();
    try testz.expectEqual(doc.blocks.len, 2);
    try testz.expectEqualStr("zig", doc.blocks[0].code.lang);
    try testz.expectEqualStr("  const x = *y;\n# not a heading", doc.blocks[0].code.text);
    try testz.expectEqualStr("indented", doc.blocks[1].code.text);
}

pub fn tableCellsAlignmentAndEscapedPipesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "| A | B | C |\n|:--|--:|:-:|\n| `x\\|y` | 2 |\n");
    defer doc.deinit();
    const t = doc.blocks[0].table;
    try testz.expectEqual(t.header.len, 3);
    try testz.expectEqual(t.aligns[0], .left);
    try testz.expectEqual(t.aligns[1], .right);
    try testz.expectEqual(t.aligns[2], .center);
    try testz.expectEqual(t.rows.len, 1);
    // Short rows are padded out to the header's width.
    try testz.expectEqual(t.rows[0].len, 3);
    try testz.expectEqualStr("x|y", t.rows[0][0].runs[0].text);
    try testz.expectEqual(t.rows[0][2].runs.len, 0);
}

pub fn rulesFrontMatterAndCommentsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "---\ntitle: x\n---\ntext\n\n* * *\n\n<!-- hidden\nstill hidden -->\nend\n");
    defer doc.deinit();
    try testz.expectEqual(doc.blocks.len, 3);
    try testz.expectEqualStr("text", doc.blocks[0].paragraph.runs[0].text);
    try testz.expectTrue(doc.blocks[1] == .rule);
    try testz.expectEqualStr("end", doc.blocks[2].paragraph.runs[0].text);
}

// ─── Layout ─────────────────────────────────────────────────────────────

fn dumpOf(alloc: std.mem.Allocator, src: []const u8, width: usize) ![]u8 {
    var doc = try parse(alloc, src);
    defer doc.deinit();
    var lay = try layout.layout(alloc, &doc, .{ .width = width });
    defer lay.deinit();
    return lay.renderText(alloc);
}

pub fn paragraphWrapsAtWordBoundariesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Width 22 leaves a 20-column text column with a 1-column margin.
    const out = try dumpOf(alloc, "one two three four five six\n", 22);
    defer alloc.free(out);
    try testz.expectEqualStr("\n one two three four\n five six\n\n", out);
}

/// "**bold**," is one word across two runs: it wraps as a unit.
pub fn wordSpanningRunsWrapsAsOneTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try dumpOf(alloc, "aaaa bbbbbbbbb **cc**, d\n", 18);
    defer alloc.free(out);
    try testz.expectEqualStr("\n aaaa bbbbbbbbb\n cc, d\n\n", out);
}

/// h1 is drawn 3x: three cells per character, three rows tall, then a
/// rule; h2 is 2x.
pub fn headingScaleSetsPitchAndRowsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "# Hi\n\n## Yo\n\n#### Four\n");
    defer doc.deinit();
    var lay = try layout.layout(alloc, &doc, .{ .width = 22 });
    defer lay.deinit();

    const h1 = lay.ops[0].text;
    try testz.expectEqual(h1.row, 1);
    try testz.expectEqual(h1.spans[0].scale, .x3);
    try testz.expectEqual(h1.spans[0].tone, .h1);
    // Rule under h1 on row 1 + 3.
    try testz.expectEqual(lay.ops[1].text.row, 4);
    // Blank row, then h2 at 2x.
    try testz.expectEqual(lay.ops[2].text.row, 6);
    try testz.expectEqual(lay.ops[2].text.spans[0].scale, .x2);
    try testz.expectEqual(lay.ops[3].text.row, 8);
    // h4 is normal size.
    try testz.expectEqual(lay.ops[4].text.spans[0].scale, .x1);
    try testz.expectEqual(lay.anchorRow("hi").?, 1);
    try testz.expectEqual(lay.anchorRow("four").?, 10);
}

/// A 3x heading wraps at a third of the width.
pub fn scaledHeadingWrapsByPitchTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "# abc def\n");
    defer doc.deinit();
    // 20-column text column: "abc" is 9 cells, "abc def" 21 -- too wide.
    var lay = try layout.layout(alloc, &doc, .{ .width = 22 });
    defer lay.deinit();
    try testz.expectEqualStr("abc", lay.ops[0].text.spans[0].text);
    try testz.expectEqualStr("def", lay.ops[1].text.spans[0].text);
    try testz.expectEqual(lay.ops[1].text.row, 4);
}

pub fn listMarkersIndentNestedItemsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = try dumpOf(alloc, "- a\n  - b\n\n9. x\n10. y\n", 40);
    defer alloc.free(out);
    // Ordered numbers right-align so the text column lines up.
    try testz.expectEqualStr("\n • a\n   ◦ b\n\n  9. x\n 10. y\n\n", out);
}

pub fn tableColumnsShrinkToFitTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "| Name | Description |\n|---|---|\n| a | a much longer description here |\n");
    defer doc.deinit();
    var lay = try layout.layout(alloc, &doc, .{ .width = 32 });
    defer lay.deinit();
    const t = lay.ops[0].table;
    // 30 columns of text less 3 border/separator cells.
    try testz.expectEqual(t.columns[0].width + t.columns[1].width, 27);
    try testz.expectEqual(t.columns[0].width, 4);
    // Header, separator, one row, two borders.
    try testz.expectEqual(lay.rows, 1 + 5 + 1);
}

pub fn linkPositionsAndTabOrderFollowReadingOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "[a](x) and [b](y)\n\n| L |\n|---|\n| [c](z) |\n");
    defer doc.deinit();
    var lay = try layout.layout(alloc, &doc, .{ .width = 40 });
    defer lay.deinit();
    try testz.expectEqual(lay.link_pos[0].?.row, 1);
    try testz.expectEqual(lay.link_pos[1].?.col, lay.link_pos[0].?.col + 6);
    // The table cell's link: top border, header, separator, then the row.
    try testz.expectEqual(lay.link_pos[2].?.row, 3 + 3);
    const order = try lay.tabOrder(alloc);
    defer alloc.free(order);
    try testz.expectEqual(order.len, 3);
    try testz.expectEqual(order[2], 2);
}

const FakeImages = struct {
    fn sizeOf(_: *const anyopaque, src: []const u8) ?layout.ImageSize {
        if (std.mem.eql(u8, src, "wide.png")) return .{ .w = 800, .h = 160 };
        return null;
    }
};

/// A local image shrinks to the text column's width; one that can't be
/// shown becomes a placeholder, and a remote one links to itself.
pub fn imagesScaleToColumnOrFallBackToPlaceholderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "![w](wide.png)\n\n![r](https://x.example/p.png)\n");
    defer doc.deinit();
    var lay = try layout.layout(alloc, &doc, .{
        .width = 52,
        .cell_w = 8,
        .cell_h = 16,
        .images = .{ .ctx = &doc, .sizeOf = FakeImages.sizeOf },
    });
    defer lay.deinit();
    const im = lay.ops[0].image;
    // 50 columns * 8px = 400px wide: half size, so 80px tall = 5 rows.
    try testz.expectEqual(im.cols, 50);
    try testz.expectEqual(im.rows, 5);
    try testz.expectTrue(im.scale == 0.5);

    const placeholder = lay.ops[1].text;
    try testz.expectEqualStr("[image: r]", placeholder.spans[0].text);
    const li = placeholder.spans[0].link.?;
    try testz.expectEqualStr("https://x.example/p.png", lay.links[li].href);
}

pub fn collectImagesDedupesInReadingOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "![a](1.png)\n\n- ![b](2.png)\n\n> ![c](1.png)\n");
    defer doc.deinit();
    const srcs = try layout.collectImages(alloc, &doc);
    defer alloc.free(srcs);
    try testz.expectEqual(srcs.len, 2);
    try testz.expectEqualStr("1.png", srcs[0]);
    try testz.expectEqualStr("2.png", srcs[1]);
}

// ─── Link targets ───────────────────────────────────────────────────────

pub fn classifySortsAnchorsUrlsAndPathsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try testz.expectEqualStr("setup", (try nav.classify(alloc, "#setup")).anchor);
    try testz.expectEqualStr("https://x.com/a#b", (try nav.classify(alloc, "https://x.com/a#b")).external);
    try testz.expectEqualStr("mailto:a@b.c", (try nav.classify(alloc, "mailto:a@b.c")).external);

    const local = (try nav.classify(alloc, "docs/My%20Notes.md#part-two")).local;
    defer alloc.free(local.path);
    try testz.expectEqualStr("docs/My Notes.md", local.path);
    try testz.expectEqualStr("part-two", local.fragment);

    // A path with only a fragment is an in-page anchor.
    try testz.expectEqualStr("x", (try nav.classify(alloc, "#x")).anchor);
}

pub fn markdownPathsAreRecognizedByExtensionTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(nav.isMarkdownPath("a/b.md"));
    try testz.expectTrue(nav.isMarkdownPath("README.MARKDOWN"));
    try testz.expectFalse(nav.isMarkdownPath("pic.png"));
    try testz.expectFalse(nav.isMarkdownPath("paper.pdf"));
}

pub fn resolveIsRelativeToThePagesDirectoryTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const r = try nav.resolve(alloc, "/home/u/docs", "../other/x.md");
    defer alloc.free(r);
    try testz.expectEqualStr("/home/u/other/x.md", r);
    const abs = try nav.resolve(alloc, "/home/u/docs", "/etc/x.md");
    defer alloc.free(abs);
    try testz.expectEqualStr("/etc/x.md", abs);
}
