// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A layer's text selection and highlight set: a linear selection over the
//! cell grid, including its scrollback, plus the metadata ids drawn with
//! the selection tint. These are the operations the wire messages and
//! glyphwire-host's in-process path drive it through, and the read helpers
//! the renderer (`colRange`) and `get_selection_text` (`text`) need.
//!
//! Its state is `LayerSelection`, embedded in each layer as `Layer.sel`
//! the way `Layer.vt` holds the VT machine's. Unlike the VT machine,
//! callers outside core reach it, so the operations are methods on the
//! state (`layer.sel.text(alloc)`); each recovers its owning `Layer` with
//! `layer()` / `layerConst()` to read the cell rows it measures.

const std = @import("std");
const core = @import("core.zig");

const Layer = core.Layer;
const Cell = core.Cell;
const MetadataHandle = core.MetadataHandle;
const scaledPitch = core.scaledPitch;

/// One end of a linear text selection on a layer, in scroll-stable
/// coordinates. `above` is how many grid rows this point sits above the
/// live viewport's top row: positive counts up into retained scrollback
/// (`above == 1` is the row immediately above the viewport), zero or
/// negative is inside the live viewport (live buffer row `= -above`).
/// Deliberately not a `(view_offset, screen_row)` pair -- `above` is
/// anchored to the content, so a selection stays pinned to the same text
/// while the view is scrolled, and `LayerSelection.noteScrolled` shifts
/// both ends by one so it also stays pinned as fresh output pushes rows
/// into history. `col` is a 0-based cell column.
pub const SelectionPoint = struct { above: i64, col: usize };

/// A linear (stream, not rectangular) selection on a layer: from `anchor`
/// (where the drag / keyboard selection started) to `active` (the moving
/// end). Reading order runs from whichever end is further back in
/// scrollback (larger `above`, ties broken on smaller `col`) to the
/// other -- see `ordered`.
pub const Selection = struct {
    anchor: SelectionPoint,
    active: SelectionPoint,

    /// The two ends in reading order: `start` is the earlier point (higher
    /// on screen / further back in history), `end` the later one. `start`
    /// always has `above >= end.above`.
    pub fn ordered(self: Selection) struct { start: SelectionPoint, end: SelectionPoint } {
        const a = self.anchor;
        const b = self.active;
        const a_first = a.above > b.above or (a.above == b.above and a.col <= b.col);
        return if (a_first) .{ .start = a, .end = b } else .{ .start = b, .end = a };
    }

    /// Whether both ends coincide -- a zero-width selection, which
    /// `LayerSelection.text` renders as the empty string (the host treats
    /// that the same as "nothing selected").
    pub fn isEmpty(self: Selection) bool {
        return self.anchor.above == self.active.above and self.anchor.col == self.active.col;
    }
};

/// What a multi-click selects: a double-click a word, a triple-click a
/// line. See `LayerSelection.unitSpanAt`.
pub const SelectUnit = enum { word, line };

/// The inclusive ends of the word or line `LayerSelection.unitSpanAt`
/// found, in reading order.
pub const UnitSpan = struct { start: SelectionPoint, end: SelectionPoint };

/// How a selection reads the cells of a layer (`PropertyName.selection_flow`).
///
/// `horizontal` is the ordinary terminal stream: left to right along a
/// row, then down to the next. `vertical_rl` is vertical CJK text set in
/// columns -- top to bottom inside a column, columns right to left -- as
/// gw-read's OCR panel draws a vertical speech bubble. A host selection
/// is a pair of points either way; the flow only changes what lies
/// *between* them, and so what the tint covers and what a copy yields.
///
/// A vertical layer's columns are a fixed grid: each is `column_cols`
/// cells wide, the first starting at cell column `origin_col` (to the
/// right of a panel's border and pad), so a point's column is
/// `(col - origin_col) / column_cols`. A client sets them to match how
/// it lays the text out -- a wide character at `scaledPitch(scale)` is
/// `2 * pitch` cells. Cells left of `origin_col` belong to no column.
///
/// The tint needs no new renderer path: whatever the two ends, the
/// cells a vertical selection covers on any one row are a single
/// contiguous run (the whole columns between the ends, plus the start
/// column on rows at or below the start and the end column on rows at or
/// above the end), so `LayerSelection.colRange` still answers one range
/// per row.
pub const SelectionFlow = struct {
    mode: Mode = .horizontal,
    column_cols: usize = 2,
    origin_col: usize = 0,

    pub const Mode = enum { horizontal, vertical_rl };
};

/// One layer's selection state. Only ever lives embedded in a `Layer`, as
/// `Layer.sel` -- `layer()` depends on that.
pub const LayerSelection = struct {
    /// The layer's current text selection, or null when nothing is
    /// selected -- see `Selection`. Set/moved/cleared by the
    /// `set_selection` / `update_selection` / `clear_selection` wire
    /// messages (and glyphwire-host's in-process equivalents), read by the
    /// renderer (`colRange`) and `get_selection_text` (`text`).
    /// `Layer.scrollOne` keeps both ends pinned to their content as output
    /// scrolls (`noteScrolled`); `Layer.resize` drops it (the ring buffer
    /// is rebuilt from scratch).
    range: ?Selection = null,
    /// Metadata ids whose cells are drawn with the selection's translucent
    /// tint -- set/cleared by the `toggle_highlight` / `set_highlight` /
    /// `clear_highlight` messages. Stored as *ids*, not cell ranges: the
    /// renderer tints any cell whose `metadata_id` is in this set, so a
    /// highlight follows its content through scrollback and survives a
    /// `resize` for free, and an id whose cells have all scrolled out of
    /// retained history simply matches nothing (harmless -- ids are never
    /// reused). glyphwire-shell drives this for its `ls` multi-select
    /// marks. Owned -- freed in `Layer.deinit`.
    highlighted_ids: std.ArrayList(MetadataHandle) = .empty,
    /// Which way a selection on this layer reads. See `SelectionFlow`.
    flow: SelectionFlow = .{},

    /// The `Layer` this state is embedded in.
    fn layer(self: *LayerSelection) *Layer {
        return @alignCast(@fieldParentPtr("sel", self));
    }

    /// `layer` for the read-only operations.
    fn layerConst(self: *const LayerSelection) *const Layer {
        return @alignCast(@fieldParentPtr("sel", self));
    }

    /// Starts (or replaces) the selection: `anchor` is the fixed end,
    /// `active` the moving one.
    pub fn set(self: *LayerSelection, anchor: SelectionPoint, active: SelectionPoint) void {
        self.range = .{ .anchor = anchor, .active = active };
        self.layer().touchRender();
    }

    /// Moves the selection's active (moving) end -- a no-op when nothing
    /// is selected, so a stray drag/extend after a `clear` does nothing.
    pub fn updateActive(self: *LayerSelection, active: SelectionPoint) void {
        if (self.range) |*s| {
            s.active = active;
            self.layer().touchRender();
        }
    }

    pub fn clear(self: *LayerSelection) void {
        self.range = null;
        self.layer().touchRender();
    }

    /// Keeps the selection pinned to its content when the viewport has
    /// just advanced one row (`Layer.scrollOne`): every row moves one
    /// step further above the live viewport's top (see `SelectionPoint`).
    /// Drops it once an end scrolls off the top of retained history
    /// (`history_len`, already counting the new row) -- the text it
    /// referred to is gone. Highlights need nothing here: they're keyed by
    /// metadata id, so they follow their content on their own.
    pub fn noteScrolled(self: *LayerSelection, history_len: usize) void {
        if (self.range) |*s| {
            s.anchor.above += 1;
            s.active.above += 1;
            const max_above = @max(s.anchor.above, s.active.above);
            if (max_above > @as(i64, @intCast(history_len))) self.range = null;
        }
    }

    /// Drops a selection with an end in scrollback (`Layer.clearHistory`).
    /// One entirely inside the live viewport survives.
    pub fn dropHistory(self: *LayerSelection) void {
        if (self.range) |s| {
            if (s.anchor.above > 0 or s.active.above > 0) self.range = null;
        }
    }

    /// The span a double-click (`.word`) or triple-click (`.line`) at `p`
    /// selects, as the two inclusive ends a `set` takes. A line is the
    /// whole row; `selectedSpan` already trims it to its text. A word is
    /// the run of cells around `p` in the same `WordClass`, so a path or
    /// URL comes out whole while a quote or bracket next to it does not.
    /// Only `p`'s own row is searched: a word soft-wrapped onto the next
    /// row stops at the edge. A row that is no longer retained, or a `p`
    /// off its end, gives back `p` alone.
    pub fn unitSpanAt(self: *const LayerSelection, p: SelectionPoint, unit: SelectUnit) UnitSpan {
        const l = self.layerConst();
        const at = self.glyphRowPoint(p);
        if (unit == .line) {
            return .{
                .start = .{ .above = at.above, .col = 0 },
                .end = .{ .above = at.above, .col = l.width -| 1 },
            };
        }
        const cells = l.rowForAbove(at.above) orelse return .{ .start = at, .end = at };
        if (at.col >= cells.len) return .{ .start = at, .end = at };
        // A wide or scaled glyph's spacer and fill belong to the glyph,
        // so classify the cell that actually holds it.
        const head = if (multiCellGlyphAt(cells, at.col)) |g| g.start else at.col;
        const class = wordClassOf(cells[head]);
        if (class == .delimiter) return .{ .start = .{ .above = at.above, .col = head }, .end = .{ .above = at.above, .col = head } };

        var lo = head;
        while (lo > 0 and sameWordClass(cells, lo - 1, class)) lo -= 1;
        var hi = head;
        while (hi + 1 < cells.len and sameWordClass(cells, hi + 1, class)) hi += 1;
        return .{ .start = .{ .above = at.above, .col = lo }, .end = .{ .above = at.above, .col = hi } };
    }

    /// Whether `id` is currently highlighted -- the per-cell test the
    /// renderer runs against `Cell.metadata_id`. `null` (an untagged cell)
    /// is never highlighted.
    pub fn isHighlighted(self: *const LayerSelection, id: ?MetadataHandle) bool {
        const want = id orelse return false;
        for (self.highlighted_ids.items) |h| {
            if (h == want) return true;
        }
        return false;
    }

    /// Adds `id` to the highlight set if absent, removes it if present
    /// (`toggle_highlight`).
    pub fn toggleHighlight(self: *LayerSelection, id: MetadataHandle) !void {
        for (self.highlighted_ids.items, 0..) |h, i| {
            if (h == id) {
                _ = self.highlighted_ids.swapRemove(i);
                self.layer().touchRender();
                return;
            }
        }
        try self.highlighted_ids.append(self.layer().alloc, id);
        self.layer().touchRender();
    }

    /// Replaces the whole highlight set with `ids` (`set_highlight`). An
    /// empty slice clears it, same as `clearHighlights`.
    pub fn setHighlights(self: *LayerSelection, ids: []const MetadataHandle) !void {
        self.highlighted_ids.clearRetainingCapacity();
        try self.highlighted_ids.appendSlice(self.layer().alloc, ids);
        self.layer().touchRender();
    }

    /// Drops every highlighted id (`clear_highlight`).
    pub fn clearHighlights(self: *LayerSelection) void {
        self.highlighted_ids.clearRetainingCapacity();
        self.layer().touchRender();
    }

    /// `p` moved up onto its scaled glyph's own row when it sits in the
    /// rows that glyph draws down into (see `underScaledRows`); any other
    /// point unchanged. The column needs no fixing: the blanks under a
    /// glyph line up with its footprint on the glyph row.
    fn glyphRowPoint(self: *const LayerSelection, p: SelectionPoint) SelectionPoint {
        const cells = self.layerConst().rowForAbove(p.above) orelse return p;
        return .{ .above = p.above + underScaledRows(cells, p.col), .col = p.col };
    }

    /// The selection's ends in reading order after `glyphRowPoint` --
    /// what every span below is measured against. The stored points stay
    /// raw (a drag lands wherever the pointer is); only what they *cover*
    /// is resolved to glyph rows.
    fn bounds(self: *const LayerSelection, sel: Selection) struct { start: SelectionPoint, end: SelectionPoint } {
        const s: Selection = .{ .anchor = self.glyphRowPoint(sel.anchor), .active = self.glyphRowPoint(sel.active) };
        if (self.flow.mode == .vertical_rl) {
            // Columns run right to left, so the earlier end is the one
            // in the column further right, then the higher of two in
            // the same column.
            const ka = self.flowColumn(s.anchor.col);
            const kb = self.flowColumn(s.active.col);
            const a_first = ka > kb or (ka == kb and s.anchor.above >= s.active.above);
            return if (a_first) .{ .start = s.anchor, .end = s.active } else .{ .start = s.active, .end = s.anchor };
        }
        const o = s.ordered();
        return .{ .start = o.start, .end = o.end };
    }

    /// The vertical column (`SelectionFlow`) cell column `col` falls in,
    /// counted from `origin_col`; -1 left of it.
    fn flowColumn(self: *const LayerSelection, col: usize) i64 {
        const f = self.flow;
        if (col < f.origin_col) return -1;
        return @intCast((col - f.origin_col) / f.column_cols);
    }

    /// Cell columns `[lo, hi)` of vertical columns `first_k` down to
    /// `last_k` (`first_k >= last_k`), clipped to the layer; null when
    /// that is empty.
    fn flowColumnSpan(self: *const LayerSelection, first_k: i64, last_k: i64) ?struct { lo: usize, hi: usize } {
        if (first_k < last_k or first_k < 0) return null;
        const f = self.flow;
        const lo_k: usize = @intCast(@max(last_k, 0));
        const lo = f.origin_col + lo_k * f.column_cols;
        const hi = @min(f.origin_col + (@as(usize, @intCast(first_k)) + 1) * f.column_cols, self.layerConst().width);
        if (lo >= hi) return null;
        return .{ .lo = lo, .hi = hi };
    }

    /// For the renderer: the `[start, end)` column range selected on the
    /// row `above` rows above the live viewport's top (see
    /// `SelectionPoint`), or null if that row is outside the selection or
    /// has nothing selectable in it. Linear model -- the first and last
    /// row are clipped to the selection's start/end column, and each row
    /// is trimmed to its text (`selectedSpan`). A row a scaled glyph
    /// draws down into reports its glyph row's range, so the tint covers
    /// the whole enlarged line.
    pub fn colRange(self: *const LayerSelection, above: i64) ?struct { start: usize, end: usize } {
        const sel = self.range orelse return null;
        if (sel.isEmpty()) return null;
        const b = self.bounds(sel);
        const glyph_above = if (self.layerConst().rowForAbove(above)) |cells| above + underScaledRows(cells, null) else above;
        // A vertical selection's middle columns run the full height, so
        // any row can hold some of it; `selectedSpan` decides.
        if (self.flow.mode == .horizontal and (glyph_above > b.start.above or glyph_above < b.end.above)) return null;
        const span = self.selectedSpan(glyph_above, b.start, b.end) orelse return null;
        return .{ .start = span.lo, .end = span.hi };
    }

    /// The selected `[lo, hi)` columns of glyph row `above`, shared by
    /// the tint and the copied text so the two always agree. Starts from
    /// the raw linear span (clipped at `start`/`end` on the first and
    /// last row, the whole width between), then:
    ///   - snaps both ends to whole glyphs (`snapGlyphSpan`),
    ///   - drops leading unselectable cells (`Cell.selectable`, a panel's
    ///     border and pad),
    ///   - drops trailing blanks and unselectable cells, so a row's tint
    ///     ends at its last character rather than the layer's edge,
    ///   - and snaps the end again, since the trim can cut into the blank
    ///     fill to the right of a scaled glyph.
    /// Null when nothing is left. A row no longer retained keeps the raw
    /// span -- there are no cells to trim against.
    ///
    /// A `vertical_rl` layer (`SelectionFlow`) starts instead from the
    /// whole columns the selection covers on this row -- every column
    /// strictly between the ends, the start column on rows at or below
    /// the start, the end column on rows at or above the end -- and trims
    /// blanks off *both* sides, since a short last column leaves blanks
    /// on the left of a row rather than the right.
    fn selectedSpan(self: *const LayerSelection, above: i64, start: SelectionPoint, end: SelectionPoint) ?struct { lo: usize, hi: usize } {
        const l = self.layerConst();
        const vertical = self.flow.mode == .vertical_rl;
        var lo: usize = 0;
        var hi: usize = 0;
        if (vertical) {
            const ks = self.flowColumn(start.col);
            const ke = self.flowColumn(end.col);
            const first_k = if (above <= start.above) ks else ks - 1;
            const last_k = if (above >= end.above) ke else ke + 1;
            const cols = self.flowColumnSpan(first_k, last_k) orelse return null;
            lo = cols.lo;
            hi = cols.hi;
        } else {
            lo = if (above == start.above) @min(start.col, l.width) else 0;
            hi = if (above == end.above) end.col + 1 else l.width;
            if (hi > l.width) hi = l.width;
            if (lo >= hi) return null;
        }
        const cells = l.rowForAbove(above) orelse return .{ .lo = lo, .hi = hi };

        var span = snapGlyphSpan(cells, lo, hi);
        lo = span.lo;
        hi = span.hi;
        while (lo < hi and (!cells[lo].selectable or (vertical and isBlankCell(cells[lo])))) lo += 1;
        while (hi > lo and (!cells[hi - 1].selectable or isBlankCell(cells[hi - 1]))) hi -= 1;
        if (lo >= hi) return null;
        span = snapGlyphSpan(cells, lo, hi);
        return .{ .lo = span.lo, .hi = span.hi };
    }

    /// The selected text, or null when nothing is selected (a zero-width
    /// selection returns `""`). Each row is its `selectedSpan` -- the
    /// same cells the tint covers -- and rows join with `\n`. A blank cell
    /// inside the span becomes a space; a wide or scaled glyph's spacer
    /// and fill are skipped, as is any unselectable cell. The rows a
    /// scaled glyph draws down into, and rows with no selectable cell at
    /// all (a panel's top or bottom border), contribute no line. A row no
    /// longer retained in scrollback contributes an empty line. Caller
    /// owns the result.
    ///
    /// A `vertical_rl` layer reads in its own order instead
    /// (`verticalText`). Either way a cell written with a `copy_text`
    /// copies that rather than its glyph.
    pub fn text(self: *const LayerSelection, alloc: std.mem.Allocator) !?[]u8 {
        const l = self.layerConst();
        const sel = self.range orelse return null;
        if (sel.isEmpty()) return try alloc.dupe(u8, "");
        const b = self.bounds(sel);
        if (self.flow.mode == .vertical_rl) return try self.verticalText(alloc, b.start, b.end);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        var first_line = true;
        var above = b.start.above;
        while (above >= b.end.above) : (above -= 1) {
            const row_cells = l.rowForAbove(above);
            if (row_cells) |cells| {
                if (underScaledRows(cells, null) != 0) continue;
                if (!anySelectable(cells)) continue;
            }
            if (!first_line) try out.append(alloc, '\n');
            first_line = false;

            const cells = row_cells orelse continue;
            const span = self.selectedSpan(above, b.start, b.end) orelse continue;
            var col = span.lo;
            while (col < span.hi) {
                const c = cells[col];
                if (!c.selectable or c.wide == .wide_spacer) {
                    col += 1;
                    continue;
                }
                const g = l.copyTextOf(&c);
                if (g.len == 0) try out.append(alloc, ' ') else try out.appendSlice(alloc, g);
                col += glyphFootprint(c);
            }
        }

        return try out.toOwnedSlice(alloc);
    }

    /// `text` for a `vertical_rl` layer: column by column from the
    /// start's column leftwards, each read top to bottom (from the start's
    /// row in the first column, to the end's row in the last), columns
    /// joined with `\n` the way a horizontal copy joins rows. Blanks,
    /// spacers, unselectable cells and the rows a scaled glyph draws down
    /// into contribute nothing, so a short column or a panel's border
    /// never shows up as stray spaces.
    fn verticalText(self: *const LayerSelection, alloc: std.mem.Allocator, start: SelectionPoint, end: SelectionPoint) ![]u8 {
        const l = self.layerConst();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        const ks = self.flowColumn(start.col);
        const ke = @max(self.flowColumn(end.col), 0);
        const top: i64 = @intCast(l.history_len);
        const bottom: i64 = -@as(i64, @intCast(l.height)) + 1;

        var wrote_any = false;
        var k = ks;
        while (k >= ke) : (k -= 1) {
            const cols = self.flowColumnSpan(k, k) orelse continue;
            const row_hi = if (k == ks) start.above else top;
            const row_lo = if (k == ke) end.above else bottom;
            const mark = out.items.len;
            if (wrote_any) try out.append(alloc, '\n');
            const body = out.items.len;

            var above = row_hi;
            while (above >= row_lo) : (above -= 1) {
                const cells = l.rowForAbove(above) orelse continue;
                if (underScaledRows(cells, null) != 0) continue;
                var col = cols.lo;
                while (col < cols.hi) {
                    const c = cells[col];
                    if (!c.selectable or c.wide == .wide_spacer or isBlankCell(c)) {
                        col += 1;
                        continue;
                    }
                    try out.appendSlice(alloc, l.copyTextOf(&c));
                    col += glyphFootprint(c);
                }
            }
            // A column with nothing in it (a border, or past the text)
            // takes its separator back with it.
            if (out.items.len == body) out.shrinkRetainingCapacity(mark) else wrote_any = true;
        }
        return try out.toOwnedSlice(alloc);
    }
};

// ── Cell helpers ────────────────────────────────────────────────────────
//
// Pure tests over one row's cells, shared by the word, tint and copy
// paths above.

/// What a host double-click groups cells by. A word is a run of
/// non-blank cells that aren't delimiters; blanks group with blanks;
/// a delimiter is always a word of its own.
const WordClass = enum { blank, word, delimiter };

/// Characters that end a double-click word in terminal output: the
/// quotes and brackets that wrap a path or URL, plus the separators
/// that trail one in a list. `/ . - : ~` and friends are deliberately
/// word characters, so `src/core.zig:42` selects as one.
const word_delimiters = "\"'`()[]{}<>|,;";

fn wordClassOf(c: Cell) WordClass {
    if (!c.selectable) return .delimiter;
    const g = c.grapheme();
    if (g.len == 0 or std.mem.eql(u8, g, " ") or std.mem.eql(u8, g, "\t")) return .blank;
    if (g.len == 1 and std.mem.indexOfScalar(u8, word_delimiters, g[0]) != null) return .delimiter;
    return .word;
}

/// Whether the cell at `col` extends a run of `class`. A wide or
/// scaled glyph's spacer and fill cells take their glyph's class, so
/// a run steps over them rather than stopping at their empty grapheme.
fn sameWordClass(cells: []const Cell, col: usize, class: WordClass) bool {
    const head = if (multiCellGlyphAt(cells, col)) |g| g.start else col;
    return wordClassOf(cells[head]) == class;
}

/// How many rows below its scaled glyph's own row the row `cells`
/// sits (`Cell.under_scaled`), or 0 for an ordinary row. The cell at
/// `col` decides when it's under a glyph; otherwise any cell in the
/// row does, so a point past the end of a scaled line's lower half --
/// a blank the glyphs never reached -- still belongs to that line.
fn underScaledRows(cells: []const Cell, col: ?usize) i64 {
    if (col) |c| {
        if (c < cells.len and cells[c].under_scaled != 0) return cells[c].under_scaled;
    }
    for (cells) |c| {
        if (c.under_scaled != 0) return c.under_scaled;
    }
    return 0;
}

/// A narrow, unscaled cell showing nothing -- what trailing-blank
/// trimming drops. A wide character's spacer isn't blank: it's half
/// of the character to its left.
fn isBlankCell(c: Cell) bool {
    if (c.wide != .narrow or c.text_scale != .x1) return false;
    const g = c.grapheme();
    return g.len == 0 or std.mem.eql(u8, g, " ");
}

/// Cells glyph cell `c` covers on its own row: its display width
/// times its scale's pitch (`Layer.putRunGlyph`'s footprint).
fn glyphFootprint(c: Cell) usize {
    const w: usize = if (c.wide == .wide_lead) 2 else 1;
    return w * scaledPitch(c.text_scale);
}

/// The glyph whose footprint covers column `col` of `cells` when that
/// glyph spans more than one cell -- a wide character or a scaled one
/// -- as its first column and width, or null for a cell that is its
/// own glyph. Walks left from `col` over the spacer and blank fill a
/// wide or scaled glyph leaves to its right, stopping at the first
/// real character.
fn multiCellGlyphAt(cells: []const Cell, col: usize) ?struct { start: usize, len: usize } {
    const max_footprint = 2 * scaledPitch(.x3);
    var k: usize = 0;
    while (k < max_footprint and k <= col) : (k += 1) {
        const at = col - k;
        const c = cells[at];
        if (c.wide == .wide_lead or c.text_scale != .x1) {
            const len = glyphFootprint(c);
            if (at + len > col and len > 1) return .{ .start = at, .len = len };
            return null;
        }
        if (c.wide == .wide_spacer or isBlankCell(c)) continue;
        return null;
    }
    return null;
}

/// Widens the selected column span `[lo, hi)` of row `cells` so it
/// never splits a glyph: a start inside a wide or scaled glyph's
/// footprint moves back to the glyph's own cell, an end inside one
/// runs to the footprint's last cell. The selection itself stays in
/// raw cells (a drag or a client's `set_selection` can land on any of
/// them); only what it *covers* snaps, so the tint and the copied
/// text always agree on whole characters.
fn snapGlyphSpan(cells: []const Cell, lo: usize, hi: usize) struct { lo: usize, hi: usize } {
    var out_lo = lo;
    var out_hi = hi;
    if (out_lo < cells.len) {
        if (multiCellGlyphAt(cells, out_lo)) |g| out_lo = g.start;
    }
    if (out_hi > 0 and out_hi <= cells.len) {
        if (multiCellGlyphAt(cells, out_hi - 1)) |g| out_hi = @max(out_hi, @min(g.start + g.len, cells.len));
    }
    return .{ .lo = out_lo, .hi = out_hi };
}

fn anySelectable(cells: []const Cell) bool {
    for (cells) |c| {
        if (c.selectable) return true;
    }
    return false;
}
