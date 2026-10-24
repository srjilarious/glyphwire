// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A collapsible tree of text rows, and the second layer component after
//! `Table` (`Layer.outlines`, addressed by the `(layer?, outline)` pair the
//! same way a table is). Where a table is a fixed block whose height only
//! its row *set* can change, an outline's height changes whenever a node
//! toggles -- so it is the one component that reflows the layer around
//! itself, through `Layer.reflowAt`.
//!
//! The node list is **flat, with a `depth` per node** -- a tree view's
//! display list rather than a recursive structure. A collapsed node hides
//! the contiguous run of nodes after it with a greater depth. That buys
//! arbitrary nesting for one wire shape, and makes a detail line (a grep
//! hit's context) just a non-collapsible node one level deeper rather than
//! a second concept with its own rules.
//!
//! Like `Table`, an outline is real server-side state that compiles into
//! ordinary cells, so it outlives the process that drew it: `gw-grep`
//! paints its results into the shell's scrollback and exits, and clicking a
//! marker still expands the hit with no client running (glyphwire-host
//! drives that directly -- see `host/outline_toggle.zig`).

const std = @import("std");
const core = @import("core.zig");
const cell_paint = @import("cell_paint.zig");

const Color = core.Color;
const Context = core.Context;
const ImageHandle = core.ImageHandle;
const Layer = core.Layer;
const MetadataHandle = core.MetadataHandle;
const codepointWidth = core.codepointWidth;
const default_style = core.default_style;
const PaintedExtent = cell_paint.PaintedExtent;
const clearExtent = cell_paint.clearExtent;
const setCellIconOver = cell_paint.setCellIconOver;
const setCellText = cell_paint.setCellText;
const setCellWide = cell_paint.setCellWide;
const tableMakeRoom = cell_paint.tableMakeRoom;

pub const OutlineHandle = u32;

pub const OutlineError = error{
    UnknownOutline,
    OutlineNodeOutOfRange,
};

/// Cells reserved for a node's ▸/▾ marker, at the node's own indent
/// column: the marker glyph plus one space. Together with the indent step
/// to its left this is the click target `toggleAt` reports (see
/// `Outline.onMarker`), which is what leaves the rest of the row free for
/// glyphwire-shell's metadata click-through -- the marker expands the
/// node, the text opens the file, the same split table header clicks
/// already have.
pub const outline_marker_cols: usize = 2;

/// One row of an outline. `runs` is `write_text`'s `spans` shape
/// (`Layer.TextRun`), so a grep hit can highlight the matched bytes and a
/// context line can carry syntax colours, without the server knowing what
/// any of it means.
pub const OutlineNode = struct {
    depth: u8 = 0,
    /// Owned, including each run's `text`.
    runs: []Layer.TextRun = &.{},
    icon: ?ImageHandle = null,
    /// Tags every cell the row paints, so a click anywhere off the marker
    /// resolves through `get_metadata` like any other tagged span.
    metadata_id: ?MetadataHandle = null,
    /// Draws a marker and hides its deeper followers when collapsed. A
    /// node with no deeper node after it can still be marked collapsible;
    /// it simply has nothing to hide.
    collapsible: bool = false,
    collapsed: bool = false,
};

/// A whole node list plus the arena it was built in: `nodes`, each
/// node's `runs`, and every run's `text` all come out of `storage`.
/// `Outline.setNodes` takes both.
///
/// An arena because the list is only ever replaced whole. A big `gw-grep`
/// run is ~100k nodes with a few runs each, so per-allocation ownership
/// meant half a million allocations to build it and as many frees to
/// replace it. The arena makes that a handful of chunk allocations and
/// one `deinit`. Building into a fresh arena and handing it over only
/// once complete also means a list that fails halfway leaves the
/// outline's current one untouched.
pub const OutlineNodes = struct {
    storage: std.heap.ArenaAllocator,
    nodes: []OutlineNode,
};

pub const OutlineStyle = struct {
    /// Cells of indent per depth level, on top of the marker gutter.
    indent: usize = 2,
    /// Always owned copies so `deinit` can free them unconditionally,
    /// the same treatment `TableStyle.box_style` gets.
    marker_collapsed: []u8,
    marker_expanded: []u8,
    /// Colour for the marker glyph; `null` takes the row's own first-run
    /// foreground, so a marker matches the text it belongs to by default.
    marker_fg: ?Color = null,
    /// Stripes every other *visible* row. Computed over visible rows, not
    /// node indices, so the striping stays alternating as nodes collapse.
    alt_row_bg: ?Color = null,

    pub fn deinit(self: OutlineStyle, alloc: std.mem.Allocator) void {
        alloc.free(self.marker_collapsed);
        alloc.free(self.marker_expanded);
    }
};

pub const Outline = struct {
    alloc: std.mem.Allocator,
    row: usize,
    col: usize,
    /// Cells across. A row's runs are clipped to this and padded out to
    /// it, so a re-paint never leaves a longer previous row's tail behind.
    width: usize,
    nodes: []OutlineNode = &.{},
    style: OutlineStyle,
    revision: u64 = 0,
    painted: PaintedExtent = .{},
    /// Where the outline's visible row 0 currently sits in live-viewport
    /// coordinates -- the identical role `Table.top_live` has, kept
    /// accurate by `Layer.scrollOne` / `unscrollOne` / `resize` as output
    /// and window changes move the outline. This is what lets a marker
    /// click (which arrives as a *screen* row) map back to a node however
    /// far the outline has scrolled since it was drawn.
    top_live: i64 = 0,
    /// The arena `nodes` (runs and run text included) lives in, handed
    /// over by `setNodes`; null until the first one. See `OutlineNodes`.
    storage: ?std.heap.ArenaAllocator = null,

    /// Takes ownership of `style` outright, the same "caller hands over a
    /// fully-built value" shape `Table.init` has.
    pub fn init(alloc: std.mem.Allocator, row: usize, col: usize, width: usize, style: OutlineStyle) Outline {
        return .{ .alloc = alloc, .row = row, .col = col, .width = width, .style = style };
    }

    pub fn deinit(self: *Outline) void {
        if (self.storage) |*s| s.deinit();
        self.storage = null;
        self.nodes = &.{};
        self.style.deinit(self.alloc);
    }

    /// `outline_set_nodes`: replaces every node wholesale, taking
    /// ownership of `new_nodes.storage` -- the arena every node, run and
    /// run text in `new_nodes.nodes` was allocated from. The old list goes
    /// in one arena `deinit`, not a walk freeing each run. Collapse state
    /// travels *with* the new nodes rather than being carried over from
    /// the old ones -- a client replacing the list knows what it wants
    /// shown, and matching old state onto new nodes would need an identity
    /// the flat list doesn't have.
    pub fn setNodes(self: *Outline, new_nodes: OutlineNodes) void {
        if (self.storage) |*s| s.deinit();
        self.storage = new_nodes.storage;
        self.nodes = new_nodes.nodes;
    }

    pub fn setStyle(self: *Outline, new_style: OutlineStyle) void {
        self.style.deinit(self.alloc);
        self.style = new_style;
    }

    /// Whether node `i` is currently on screen, i.e. no collapsed node
    /// above it in the list is shallower than it. Walking from the top is
    /// O(n) per query, so every caller that needs more than one answer
    /// uses `visibleIter` instead.
    pub fn nodeVisible(self: *const Outline, i: usize) bool {
        if (i >= self.nodes.len) return false;
        var it = self.visibleIter();
        while (it.next()) |v| {
            if (v.index == i) return true;
            if (v.index > i) return false;
        }
        return false;
    }

    /// The visible rows, top to bottom. A collapsed node hides every node
    /// after it until one at its own depth or shallower turns up.
    pub fn visibleIter(self: *const Outline) VisibleIter {
        return .{ .nodes = self.nodes };
    }

    pub const Visible = struct { index: usize, node: *const OutlineNode, row: usize };

    pub const VisibleIter = struct {
        nodes: []const OutlineNode,
        i: usize = 0,
        row: usize = 0,
        /// Depth of the shallowest collapsed node we are currently inside,
        /// or null at the top level. Anything deeper than this is hidden.
        hide_depth: ?u8 = null,

        pub fn next(self: *VisibleIter) ?Visible {
            while (self.i < self.nodes.len) {
                const idx = self.i;
                const n = &self.nodes[idx];
                self.i += 1;
                if (self.hide_depth) |hd| {
                    if (n.depth > hd) continue;
                    self.hide_depth = null;
                }
                if (n.collapsible and n.collapsed) self.hide_depth = n.depth;
                const r = self.row;
                self.row += 1;
                return .{ .index = idx, .node = n, .row = r };
            }
            return null;
        }
    };

    /// How many rows the outline paints as it currently stands.
    pub fn visibleRows(self: *const Outline) usize {
        var it = self.visibleIter();
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// `outline_set_collapsed`. `collapsed` null means toggle. Changes the
    /// outline's height, so unlike `Table`'s re-sort this cannot be an
    /// in-place repaint: it reflows the layer around itself first (see
    /// `Layer.reflowAt`) and then redraws every row.
    ///
    /// The split handed to `reflowAt` is the outline's **bottom** row --
    /// its old bottom when growing, its new bottom when shrinking -- so
    /// the rows opened or closed are always the outline's own tail and
    /// everything below the outline stays exactly where it is. The whole
    /// outline then repaints from its own model, so `reflowAt` never has
    /// to understand the outline's internal arrangement, only make room.
    /// `reflowAt` also re-pins `top_live` as it moves the ring, which is
    /// why nothing here adjusts it by hand.
    pub fn setNodeCollapsed(self: *Outline, layer: *Layer, ctx: *const Context, idx: usize, collapsed: ?bool) !void {
        if (idx >= self.nodes.len) return OutlineError.OutlineNodeOutOfRange;
        const node = &self.nodes[idx];
        if (!node.collapsible) return;
        const want = collapsed orelse !node.collapsed;
        if (want == node.collapsed) return;
        // A node nobody can see toggles silently: the state changes so it
        // is right when its parent opens, but nothing on screen moved.
        const on_screen = self.nodeVisible(idx);

        const before = self.visibleRows();
        node.collapsed = want;
        const after = self.visibleRows();

        if (self.revision == 0) return self.render(layer, ctx);
        if (!on_screen or before == after) {
            self.painted = try self.paintAt(layer, ctx, self.top_live);
            self.revision += 1;
            layer.touchRender();
            return;
        }

        const delta = @as(i64, @intCast(after)) - @as(i64, @intCast(before));
        const at_row = self.top_live + @as(i64, @intCast(@min(before, after))) - 1;
        try layer.reflowAt(at_row, delta);
        self.painted = try self.paintAt(layer, ctx, self.top_live);
        self.revision += 1;
        layer.touchRender();
    }

    /// `outline_set_all_collapsed`: every collapsible node at `depth`, or
    /// every one of them when `depth` is null. One reflow and one repaint
    /// instead of one per node, which is what a "collapse all" binding and
    /// `gw-grep --collapse` both want.
    pub fn setAllCollapsed(self: *Outline, layer: *Layer, ctx: *const Context, collapsed: bool, depth: ?u8) !void {
        var changed = false;
        for (self.nodes) |*n| {
            if (!n.collapsible) continue;
            if (depth) |d| if (n.depth != d) continue;
            if (n.collapsed == collapsed) continue;
            n.collapsed = collapsed;
            changed = true;
        }
        if (!changed) return;
        if (self.revision == 0) return self.render(layer, ctx);

        const before: i64 = @intCast(self.painted.rows);
        const after: i64 = @intCast(self.visibleRows());
        const delta = after - before;
        if (delta == 0) {
            self.painted = try self.paintAt(layer, ctx, self.top_live);
        } else {
            const at_row = self.top_live + @min(before, after) - 1;
            try layer.reflowAt(at_row, delta);
            self.painted = try self.paintAt(layer, ctx, self.top_live);
        }
        self.revision += 1;
        layer.touchRender();
    }

    /// Where a node sits in the outline's painted rows: its own row, and
    /// how many rows it plus its currently-visible descendants occupy.
    /// Null when the node is hidden under a collapsed ancestor.
    pub const NodeSpan = struct { row: usize, rows: usize };

    pub fn visibleSpan(self: *const Outline, idx: usize) ?NodeSpan {
        if (idx >= self.nodes.len) return null;
        const own_depth = self.nodes[idx].depth;
        var it = self.visibleIter();
        var start: ?usize = null;
        var rows: usize = 0;
        while (it.next()) |v| {
            if (start == null) {
                if (v.index != idx) continue;
                start = v.row;
                rows = 1;
                continue;
            }
            // Descendants are the contiguous deeper run after it.
            if (v.node.depth <= own_depth) break;
            rows += 1;
        }
        return .{ .row = start orelse return null, .rows = rows };
    }

    /// The scrollback view offset that would reveal `focus` -- the node
    /// just toggled, together with whatever it now shows -- or null when
    /// it is already on screen (or the layer has no scrollback to move).
    /// A null `focus` anchors on the outline's own top row instead, which
    /// is what a whole-list `setAllCollapsed` wants since it has no one
    /// node to point at.
    ///
    /// Expanding pushes the rows above the split up into scrollback (see
    /// `Layer.reflowAt`), so a node opened near the top of the window can
    /// shove itself off it -- you click a triangle and the thing you
    /// clicked leaves. Scrolling back to it is the fix, and it is the
    /// *view* that moves, not the content: `view_scroll` is display-only.
    ///
    /// **The focal node, not the outline's top.** A `gw-grep` run is one
    /// outline hundreds of rows tall; anchoring on its first row would
    /// fling the view back to the first file every time you opened a hit
    /// somewhere down the list. What has to stay put is the hit you
    /// opened.
    ///
    /// Ensure-visible rather than scroll-to-top: it returns the nearest
    /// offset that fits the node and its body in the window, so a toggle
    /// that needed no scrolling does not jolt the view for nothing. When
    /// the body is taller than the window the node's own row wins the top
    /// of it, since reading starts there.
    ///
    /// Deliberately **computed, not applied**. Moving a layer's view is a
    /// presentation decision belonging to whoever owns it, and both real
    /// callers have to route the move through the path that also
    /// broadcasts `scroll` to subscribers (`Server.reportScroll*`, or
    /// `handleOutlineSetCollapsed`'s own broadcast) -- otherwise
    /// glyphwire-shell's idea of the scroll position silently goes stale.
    pub fn desiredViewScroll(self: *const Outline, layer: *const Layer, focus: ?usize) ?usize {
        if (layer.history_len == 0) return null;

        var block_top = self.top_live;
        var block_rows: usize = 1;
        if (focus) |idx| {
            if (self.visibleSpan(idx)) |span| {
                block_top = self.top_live + @as(i64, @intCast(span.row));
                block_rows = span.rows;
            }
        }
        const block_bot = block_top + @as(i64, @intCast(block_rows)) - 1;

        // `view_scroll` of V shows live row L at screen row L + V, so the
        // block is fully on screen for V in [-block_top, h-1-block_bot].
        const height_i: i64 = @intCast(layer.height);
        const hist: i64 = @intCast(layer.history_len);
        const want_top = -block_top;
        var lo = want_top;
        var hi = height_i - 1 - block_bot;
        // Taller than the window: settle for its first row at the top.
        if (lo > hi) hi = lo;
        lo = std.math.clamp(lo, 0, hist);
        hi = std.math.clamp(hi, 0, hist);
        if (lo > hi) return null;

        const cur: i64 = @intCast(layer.view_scroll);
        if (cur >= lo and cur <= hi) return null;
        return @intCast(if (cur < lo) lo else hi);
    }

    /// The node whose marker covers **screen** cell `(screen_row,
    /// screen_col)` given the layer is scrolled back by `view_scroll`
    /// rows, or null when that cell isn't on a marker.
    ///
    /// Resolved exactly the way `Table.headerColumnAt` resolves a header
    /// click: the outline's visible row `R` lives at live row `top_live +
    /// R`, and live row `L` shows at screen row `L + view_scroll`. So a
    /// click lands however far output has pushed the outline up, or the
    /// user has scrolled the view back to reach it.
    pub fn toggleAt(self: *const Outline, screen_row: usize, screen_col: usize, view_scroll: usize) ?usize {
        const v = self.visibleAtScreenRow(screen_row, view_scroll) orelse return null;
        if (!v.node.collapsible) return null;
        if (!self.onMarker(v, screen_col)) return null;
        return v.index;
    }

    /// The keyboard counterpart of `toggleAt`, for glyphwire-shell's Enter
    /// while browsing scrollback (`activate_at`). A collapsible node
    /// toggles when the cell is on its marker, as a click does, **or**
    /// anywhere on a row with no `metadata_id` -- a `gw-grep` file row has
    /// nothing to open, so Enter anywhere on it is plainly "expand this".
    /// A tagged row off the marker is left alone so Enter still opens it.
    pub fn activateAt(self: *const Outline, screen_row: usize, screen_col: usize, view_scroll: usize) ?usize {
        const v = self.visibleAtScreenRow(screen_row, view_scroll) orelse return null;
        if (!v.node.collapsible) return null;
        if (v.node.metadata_id != null and !self.onMarker(v, screen_col)) return null;
        if (screen_col < self.col or screen_col >= self.col + self.width) return null;
        return v.index;
    }

    /// The visible node painted on **screen** row `screen_row` with the
    /// layer scrolled back by `view_scroll`, or null. See `toggleAt` for
    /// the coordinate mapping.
    fn visibleAtScreenRow(self: *const Outline, screen_row: usize, view_scroll: usize) ?Visible {
        const scroll: i64 = @intCast(view_scroll);
        const sr: i64 = @intCast(screen_row);
        var it = self.visibleIter();
        while (it.next()) |v| {
            const live = self.top_live + @as(i64, @intCast(v.row));
            if (live + scroll == sr) return v;
        }
        return null;
    }

    /// Whether `screen_col` is in `v`'s click target: its marker gutter
    /// (the glyph and the space after it) plus the one indent step to its
    /// left. A lone ▸ is a small thing to hit, and the blank either side
    /// of it is whitespace no other click wants -- the indent sits under
    /// the parent's marker column, not on anyone's text. A depth-0 node
    /// has no indent, so its target is just the gutter.
    fn onMarker(self: *const Outline, v: Visible, screen_col: usize) bool {
        const start = self.col + v.node.depth * self.style.indent;
        const left = start - @min(v.node.depth * self.style.indent, self.style.indent);
        return screen_col >= left and screen_col < start + outline_marker_cols;
    }

    /// First draw: lays the outline out at its anchor, scrolling the layer
    /// terminal-style as it runs past the bottom -- `Table.render`'s
    /// model, and right only when the outline is first put on screen.
    /// `setNodeCollapsed` uses `paintAt` afterwards.
    pub fn render(self: *Outline, layer: *Layer, ctx: *const Context) !void {
        clearExtent(layer, self.painted);

        const anchor_row = self.row;
        var cur_row = self.row;
        var scrolled: usize = 0;

        var it = self.visibleIter();
        while (it.next()) |v| {
            tableMakeRoom(layer, &cur_row, &scrolled, 1);
            self.writeNodeRow(layer, ctx, v, @intCast(cur_row));
            cur_row += 1;
        }

        const painted_top = anchor_row -| scrolled;
        const painted_bottom = @min(cur_row, layer.height);
        self.row = painted_top;
        self.top_live = @as(i64, @intCast(anchor_row)) - @as(i64, @intCast(scrolled));
        self.painted = .{
            .row = painted_top,
            .col = self.col,
            .rows = painted_bottom -| painted_top,
            .cols = self.width,
        };
        self.revision += 1;
        layer.touchRender();
    }

    /// Redraws every visible row starting at signed live-viewport row
    /// `top`, so rows land in the viewport, in retained scrollback, or
    /// straddling the two -- `Table.paintAt`'s model. Rows older than
    /// retained history are silently skipped; their cells are gone.
    fn paintAt(self: *Outline, layer: *Layer, ctx: *const Context, top: i64) !PaintedExtent {
        // Blank across the wider of the old and new footprints so a
        // narrower repaint leaves no stale tail, then draw over it.
        const blank_cols = @max(self.painted.cols, self.width);
        const rows = self.visibleRows();
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            blankSignedRun(layer, top + @as(i64, @intCast(r)), self.col, blank_cols);
        }

        var it = self.visibleIter();
        while (it.next()) |v| {
            self.writeNodeRow(layer, ctx, v, top + @as(i64, @intCast(v.row)));
        }

        const height_i: i64 = @intCast(layer.height);
        const visible_top = @max(top, 0);
        const visible_bottom = @min(top + @as(i64, @intCast(rows)), height_i);
        return .{
            .row = @intCast(@max(visible_top, 0)),
            .col = self.col,
            .rows = if (visible_bottom > visible_top) @intCast(visible_bottom - visible_top) else 0,
            .cols = self.width,
        };
    }

    /// One node's row: the indent, its marker if it has one, its icon if
    /// it has one, then its runs clipped and padded to `width`.
    fn writeNodeRow(self: *const Outline, layer: *Layer, ctx: *const Context, v: Visible, row: i64) void {
        _ = ctx;
        const bg: ?Color = if (self.style.alt_row_bg) |c| (if (v.row % 2 == 1) c else null) else null;
        const fg = if (v.node.runs.len > 0) v.node.runs[0].fg else default_style.fg;

        var col = self.col;
        const row_end = self.col + self.width;

        // Indent, then the marker gutter. A non-collapsible node pads the
        // gutter with blanks so its text still lines up under its
        // siblings' -- the marker column is structural, not decoration.
        const indent = @as(usize, v.node.depth) * self.style.indent;
        var i: usize = 0;
        while (i < indent and col < row_end) : (i += 1) {
            setCellText(layer, row, col, " ", fg, bg, v.node.metadata_id, .{});
            col += 1;
        }

        if (v.node.collapsible) {
            const glyph = if (v.node.collapsed) self.style.marker_collapsed else self.style.marker_expanded;
            const mfg = self.style.marker_fg orelse fg;
            if (col < row_end) {
                setCellText(layer, row, col, glyph, mfg, bg, v.node.metadata_id, .{});
                col += 1;
            }
            if (col < row_end) {
                setCellText(layer, row, col, " ", mfg, bg, v.node.metadata_id, .{});
                col += 1;
            }
        } else {
            var m: usize = 0;
            while (m < outline_marker_cols and col < row_end) : (m += 1) {
                setCellText(layer, row, col, " ", fg, bg, v.node.metadata_id, .{});
                col += 1;
            }
        }

        if (v.node.icon) |handle| {
            if (col < row_end) {
                setCellIconOver(layer, row, col, handle, .fit, .center, .center, null, v.node.metadata_id);
                col += 1;
                if (col < row_end) {
                    setCellText(layer, row, col, " ", fg, bg, v.node.metadata_id, .{});
                    col += 1;
                }
            }
        }

        col = writeRunSequence(layer, row, col, row_end, v.node.runs, bg, v.node.metadata_id);
        while (col < row_end) : (col += 1) {
            setCellText(layer, row, col, " ", fg, bg, v.node.metadata_id, .{});
        }
    }
};

/// Writes `runs` back to back from `col`, stopping at `end_col`, and
/// returns the first column past what it wrote. Each run keeps its own
/// foreground; `row_bg` (the striping) wins over a run's own background
/// only where the run doesn't set one, so a highlighted match span still
/// shows through a striped row. A run's `metadata_id` falls back to the
/// node's, so a whole row resolves to one span unless a run says otherwise.
///
/// Truncation is by **display cells** (`codepointWidth`), and a wide
/// glyph that won't fit the tail stops the run rather than half-drawing.
/// Long rows are cut, never wrapped: a grep hit's row stands for one
/// source line, and a minified 2000-column line wrapping to 30 rows would
/// bury the rest of the results.
fn writeRunSequence(
    layer: *Layer,
    row: i64,
    col: usize,
    end_col: usize,
    runs: []const Layer.TextRun,
    row_bg: ?Color,
    metadata_id: ?MetadataHandle,
) usize {
    var c = col;
    if (layer.rowAtSigned(row) == null) return c;
    const limit = @min(end_col, layer.width);
    for (runs) |run| {
        if (c >= limit) break;
        const run_bg: ?Color = if (run.bg) |b| switch (b) {
            .color => |x| x,
            // An image/icon background is not something a run can paint
            // through a text cell, so the row's striping stands.
            else => row_bg,
        } else row_bg;
        const id = run.metadata_id orelse metadata_id;
        const view = std.unicode.Utf8View.init(run.text) catch continue;
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp_bytes| {
            if (c >= limit) break;
            const w = codepointWidth(std.unicode.utf8Decode(cp_bytes) catch 0xFFFD);
            if (w == 2) {
                if (c + 1 >= limit) break;
                setCellWide(layer, row, c, cp_bytes, run.fg, run_bg, id, .{});
                c += 2;
            } else {
                setCellText(layer, row, c, cp_bytes, run.fg, run_bg, id, .{});
                c += 1;
            }
        }
    }
    return c;
}

/// Blanks `cols` cells from `col` on signed live-viewport row `row`,
/// skipping a row that isn't retained. `Layer.clear` only speaks unsigned
/// viewport rows, so `Outline.paintAt` needs this to reach the parts of
/// itself that have scrolled back.
fn blankSignedRun(layer: *Layer, row: i64, col: usize, cols: usize) void {
    const cells = layer.rowAtSigned(row) orelse return;
    const end = @min(col + cols, cells.len);
    var c = col;
    while (c < end) : (c += 1) cells[c] = .{};
}
