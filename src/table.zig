// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A table is structured, server-owned data (columns, rows of typed cells,
//! sort state, style) that *compiles* into ordinary cells on its owning
//! layer whenever it changes -- not a live per-frame render path of its
//! own. This is the whole reason adding tables needed no changes to
//! glyphwire-host's render loop at all: that loop already draws whatever's
//! sitting in a layer's cell buffer, regardless of what put it there
//! (`write_text`, `draw_icon`, or now `Table.render`). It's also why a
//! table survives the process that created it (e.g. `glyphwire-ls -l`)
//! exiting, and why re-sorting later is just re-deriving row order from
//! the same stored typed values and repainting -- no client needs to be
//! running for either.
//!
//! A table is a component of the layer it's drawn on (`Layer.tables`),
//! not a parallel object tree the way `Layer` itself is under `Context` --
//! see decisions.md's Table section.

const std = @import("std");
const core = @import("core.zig");
const cell_paint = @import("cell_paint.zig");

const Color = core.Color;
const Context = core.Context;
const HAlign = core.HAlign;
const ImageHandle = core.ImageHandle;
const ImageInfo = core.ImageInfo;
const Layer = core.Layer;
const MetadataHandle = core.MetadataHandle;
const WrapIterator = core.WrapIterator;
const codepointWidth = core.codepointWidth;
const default_style = core.default_style;
const stringWidth = core.stringWidth;
const wrapLineCount = core.wrapLineCount;
const PaintedExtent = cell_paint.PaintedExtent;
const clearExtent = cell_paint.clearExtent;
const setCellIcon = cell_paint.setCellIcon;
const setCellIconOver = cell_paint.setCellIconOver;
const setCellText = cell_paint.setCellText;
const setCellWide = cell_paint.setCellWide;
const tableMakeRoom = cell_paint.tableMakeRoom;

/// Server-generated handle for a table created via `create_table`.
/// Allocated from `Context.next_table_handle`, a single counter shared
/// across every layer -- same numbering convention `LayerHandle`/
/// `ImageHandle`/`MetadataHandle` already use -- even though the `Table`
/// value itself is stored on whichever `Layer` it was created on, not on
/// `Context` directly.
pub const TableHandle = u32;

pub const TableError = error{
    UnknownTable,
    /// `table_set_rows`: a row's cell count didn't match the table's
    /// column count.
    TableRowShapeMismatch,
};

/// How a column's cells compare when sorted -- `.text` compares
/// `SortKey.text` lexically, `.number` compares `SortKey.number`
/// numerically. Decided over sorting on display text alone specifically
/// so e.g. a Size column sorts `900 B` before `1.2 KB` correctly instead
/// of lexically ("1" before "9").
pub const ColumnKind = enum { text, number };

/// What a body cell does with text wider than its column: `.ellipsis`
/// (the default) keeps one line and ends it in "…"; `.wrap` word-wraps it
/// (`WrapIterator`) onto as many lines as it needs, making its row taller.
/// Headers always ellipsize.
pub const TableOverflow = enum { ellipsis, wrap };

pub const SortDirection = enum { none, ascending, descending };

/// The glyph drawn after the active sort column's header name -- a small
/// filled triangle pointing the way its rows are ordered. The "small
/// triangle" codepoints (U+25B4 / U+25BE), deliberately not the full-size
/// U+25B2 / U+25BC, which render oversized next to text. `.none` yields
/// an empty string: an unsorted table, and a column that is merely
/// `sortable` but not the current sort, show nothing extra (decided in
/// the sort feature's clarifying questions -- no persistent "click me"
/// affordance). One display cell wide; `Table.headerColWidth` reserves it
/// plus one leading space (`sort_arrow_cells`).
pub fn sortArrowGlyph(dir: SortDirection) []const u8 {
    return switch (dir) {
        .none => "",
        .ascending => "\u{25B4}", // ▴
        .descending => "\u{25BE}", // ▾
    };
}

/// Display cells the sort arrow plus its separating space occupy in a
/// header cell -- what `Table.headerColWidth` adds on top of the column
/// name's own width for the active sort column.
const sort_arrow_cells: usize = 2;

/// Orders two byte strings ignoring ASCII case (`'A'`..`'Z'` compare
/// equal to `'a'`..`'z'`), falling back to a raw-byte comparison when the
/// case-folded forms are equal so the result is a total, deterministic
/// order -- `std.mem.sort` isn't stable, so `"Foo"` and `"foo"` need a
/// fixed relative order rather than whatever the sort happens to leave.
/// Used by `Table.sortedIndices` for a `case_insensitive` text column.
fn asciiFoldOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const la = std.ascii.toLower(a[i]);
        const lb = std.ascii.toLower(b[i]);
        if (la != lb) return std.math.order(la, lb);
    }
    if (a.len != b.len) return std.math.order(a.len, b.len);
    return std.mem.order(u8, a, b);
}

/// One column's shape -- display name (the header cell's text),
/// sortability, and sizing. `width` is the column's content width in
/// cells; `min_width` is a floor, same as the client-composited table
/// prototype's `ColumnDef` (`src/table.zig`, which this supersedes as
/// the source of table layout -- see decisions.md's Table section).
pub const TableColumn = struct {
    name: []u8,
    kind: ColumnKind = .text,
    sortable: bool = false,
    /// For a `.text` column: fold ASCII case when sorting, so `"apple"`
    /// and `"Banana"` order the natural way instead of every capitalised
    /// name clumping ahead of every lowercase one. Case-folded-equal keys
    /// (`"Foo"` vs `"foo"`) then tie-break on the raw bytes so the order
    /// stays deterministic. Ignored for `.number` columns. `glyphwire-ls`
    /// sets it on its Name column.
    case_insensitive: bool = false,
    /// Mark this column's body cell as the focus cell of its row's
    /// metadata span (`Cell.meta_focus`), so Ctrl+PgUp/PgDn lands on the
    /// first character of *this* column's value rather than the row's
    /// leftmost one. A whole `glyphwire-ls -l` row shares one metadata id,
    /// so it sets this on its Name column. At most one column should have
    /// it; if several do, the leftmost wins (the walk stops at the first).
    focus: bool = false,
    width: usize,
    min_width: usize = 1,
    h_align: HAlign = .start,
    overflow: TableOverflow = .ellipsis,

    pub fn deinit(self: TableColumn, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

/// A cell's value to compare against another cell in the same column
/// when sorting -- distinct from `TableCell.display` (what's actually
/// drawn): a Size column might display `"1.2 KB"` but needs to sort on
/// the raw byte count. Every cell has one (`handleTableSetRows` defaults
/// it to a copy of `display` when the wire omits an explicit `sort_key`),
/// so sorting never needs a "what do I compare when there's nothing to
/// compare" fallback.
pub const SortKey = union(enum) {
    text: []u8,
    number: f64,

    pub fn deinit(self: SortKey, alloc: std.mem.Allocator) void {
        switch (self) {
            .text => |t| alloc.free(t),
            .number => {},
        }
    }
};

/// One cell of one row. `icon` is a resolved image handle (looked up by
/// name against the icon catalog at `table_set_rows` time -- see
/// `handleTableSetRows` -- same "fail loud on an unknown name at the
/// point of use" treatment `draw_icon`'s `name` already gets), drawn
/// alongside `display` within the column's own width rather than
/// needing a dedicated icon-only column -- e.g. glyphwire-ls's Name
/// column carries both a per-entry icon and the filename in one cell.
/// `fg` is per-cell (`null` means `default_style.fg`) since a table has
/// no notion of "kind" of its own -- glyphwire-ls's directory/symlink/
/// file coloring is caller data, same as it always was.
pub const TableCell = struct {
    display: []u8,
    sort_key: SortKey,
    icon: ?ImageHandle = null,
    fg: ?Color = null,
    metadata_id: ?MetadataHandle = null,

    pub fn deinit(self: TableCell, alloc: std.mem.Allocator) void {
        alloc.free(self.display);
        self.sort_key.deinit(alloc);
    }
};

pub const TableRow = struct {
    cells: []TableCell,

    pub fn deinit(self: TableRow, alloc: std.mem.Allocator) void {
        for (self.cells) |c| c.deinit(alloc);
        alloc.free(self.cells);
    }
};

/// Rendering knobs for a table that aren't per-column -- same shape (and
/// same box-tile-catalog reuse for borders) `src/table.zig`'s
/// `TableStyle` had client-side. `row_height` (cells per body row, `1`
/// the default) is the "large format" option added mid-development of
/// the client-composited prototype, carried forward here -- a
/// server-painted table sidesteps the scrolling bug class that
/// prototype hit near a layer's bottom edge entirely, since `Table.render`
/// never advances a cursor or triggers `Layer.resolveRow`'s scrolling at
/// all (see that method's doc comment).
pub const TableStyle = struct {
    borders: bool = true,
    header_separator: bool = true,
    /// Always an owned copy (defaulted to a duped `"box"` by whoever
    /// constructs a `TableStyle`, e.g. `handleCreateTable`/
    /// `handleTableSetStyle`, if the wire omits it) so `deinit` can
    /// always safely free it.
    box_style: []u8,
    alt_row_bg: ?Color = null,
    header_fg: ?Color = null,
    header_bg: ?Color = null,
    row_height: usize = 1,
    /// Upper bound, in pixels, on a body-cell icon's rendered height --
    /// `writeBodyRow` caps `.natural` scaling to `min(row_height *
    /// cell_px_h, max_icon_px)`. `null` means "no extra cap", the row
    /// height alone bounds it (the historical behaviour). `glyphwire-ls`
    /// sets it so a tall `-l -L` row still renders its icon at the same
    /// size the icon grid uses, regardless of the source art's resolution.
    max_icon_px: ?u32 = null,

    pub fn deinit(self: TableStyle, alloc: std.mem.Allocator) void {
        alloc.free(self.box_style);
    }
};

pub const Table = struct {
    alloc: std.mem.Allocator,
    row: usize,
    col: usize,
    columns: []TableColumn,
    rows: []TableRow = &.{},
    style: TableStyle,
    sort_column: ?usize = null,
    sort_dir: SortDirection = .none,
    revision: u64 = 0,
    painted: PaintedExtent = .{},
    /// Where the table's logical row 0 currently sits in **live-viewport**
    /// coordinates (row 0 == the live viewport's top). `render` sets it
    /// (`anchor_row - scrolled`, so it goes negative for a table that
    /// scrolled its header up into scrollback), and `Layer.scrollOne`
    /// decrements it for every table on the layer as fresh output pushes
    /// the table up -- the same content-pinning `scrollOne` already does
    /// for `Layer.sel`. This is what lets a header click (which
    /// arrives as a *screen* row) be mapped back to the table however far
    /// output or the scrollback view has moved it since it was drawn --
    /// see `headerColumnAt` / `repaint`. `render`/`repaint`/`headerColumnAt`
    /// are the only readers; nothing persists it across a `resize` (the
    /// ring is rebuilt and the owning client re-renders).
    top_live: i64 = 0,

    /// Takes ownership of `columns` and `style` outright (the caller,
    /// `handleCreateTable`, built them specifically to hand off) -- same
    /// "caller hands over a fully-built value" shape `Context.loadImage`'s
    /// `bytes` param has.
    pub fn init(alloc: std.mem.Allocator, row: usize, col: usize, columns: []TableColumn, style: TableStyle) Table {
        return .{ .alloc = alloc, .row = row, .col = col, .columns = columns, .style = style };
    }

    pub fn deinit(self: *Table) void {
        for (self.columns) |c| c.deinit(self.alloc);
        self.alloc.free(self.columns);
        self.freeRows();
        self.style.deinit(self.alloc);
    }

    fn freeRows(self: *Table) void {
        for (self.rows) |r| r.deinit(self.alloc);
        self.alloc.free(self.rows);
        self.rows = &.{};
    }

    /// `table_set_rows`: replaces every row wholesale, taking ownership
    /// of `new_rows` the same way `init` takes `columns`/`style`. Errors
    /// (freeing `new_rows` itself first) if any row's cell count doesn't
    /// match the column count -- a shape mismatch, not something to
    /// silently pad/truncate around. Doesn't touch `sort_column`/
    /// `sort_dir` -- a caller replacing a table's data while a sort is
    /// active (e.g. glyphwire-ls re-listing a directory into an existing
    /// table) keeps that sort applied to the new rows, same as a real
    /// spreadsheet would.
    pub fn setRows(self: *Table, new_rows: []TableRow) error{TableRowShapeMismatch}!void {
        for (new_rows) |r| {
            if (r.cells.len != self.columns.len) {
                for (new_rows) |rr| rr.deinit(self.alloc);
                self.alloc.free(new_rows);
                return error.TableRowShapeMismatch;
            }
        }
        self.freeRows();
        self.rows = new_rows;
    }

    /// `table_set_sort`: `column: null` or `dir: .none` both mean
    /// "unsorted, original insertion order" -- see `sortedIndices`.
    pub fn setSort(self: *Table, column: ?usize, dir: SortDirection) void {
        self.sort_column = column;
        self.sort_dir = dir;
    }

    /// The 3-state cycle a header click steps `col` through, the mutation
    /// glyphwire-host's header hit-test runs (`headerColumnAt` resolves
    /// the column, this advances its sort): a fresh column -- or a return
    /// from `.none` -- sorts ascending, ascending goes to descending, and
    /// descending clears back to insertion order (`column: null`). A
    /// no-op on an out-of-range or non-`sortable` column. Like `setSort`
    /// it doesn't repaint; the caller calls `render` after.
    pub fn cycleSortOnColumn(self: *Table, col: usize) void {
        if (col >= self.columns.len or !self.columns[col].sortable) return;
        if (self.sort_column != col or self.sort_dir == .none) {
            self.setSort(col, .ascending);
        } else switch (self.sort_dir) {
            .ascending => self.setSort(col, .descending),
            .descending, .none => self.setSort(null, .none),
        }
    }

    /// The index of the column whose header cell covers **screen** cell
    /// `(screen_row, screen_col)` given the layer is scrolled back by
    /// `view_scroll` rows, or `null` when that cell isn't on this table's
    /// header row or lands on an inter-column separator.
    ///
    /// The header's live-viewport row is `top_live + border_pad` (see
    /// `top_live` -- kept accurate as output scrolls the table), and the
    /// content at live row `L` is shown at screen row `L + view_scroll`,
    /// so the header is on screen row `top_live + border_pad +
    /// view_scroll`. That means a header click resolves correctly however
    /// far the table has scrolled and whether or not the user has
    /// scrolled the view back to reach it -- the only requirement is that
    /// the header is actually on screen. Columns are laid out through
    /// `headerColWidth`, exactly as `render`/`writeHeaderRow` do, so the
    /// click lands on the column drawn under it, arrow width included.
    /// Pairs with `cycleSortOnColumn`.
    pub fn headerColumnAt(self: *const Table, screen_row: usize, screen_col: usize, view_scroll: usize) ?usize {
        const border_pad: usize = if (self.style.borders) 1 else 0;
        const header_screen = self.top_live + @as(i64, @intCast(border_pad)) + @as(i64, @intCast(view_scroll));
        if (header_screen < 0 or @as(i64, @intCast(screen_row)) != header_screen) return null;
        var c = self.col + border_pad;
        for (self.columns, 0..) |_, i| {
            if (i > 0) {
                if (screen_col == c) return null; // inter-column separator
                c += 1;
            }
            const w = self.headerColWidth(i);
            if (screen_col >= c and screen_col < c + w) return i;
            c += w;
        }
        return null;
    }

    /// A column's header/layout width in cells: its nominal
    /// `max(width, min_width)`, widened only on the *active* sort column
    /// so its name plus the direction arrow (`" ▴"`, `sort_arrow_cells`
    /// wide) fit without truncating the name -- the column expands to fit
    /// the arrow rather than the arrow eating into the name (decided in
    /// the sort feature's clarifying questions). Every other column, and
    /// all columns while the table is unsorted, get only their nominal
    /// width, so an inactive sortable header is laid out identically to a
    /// fixed one. `render`, `paintAt`, `writeHeaderRow`, `writeBodyRow`
    /// and `headerColumnAt` all place columns through this so the header
    /// and body stay aligned and a header hit-test lands on the right
    /// column.
    fn headerColWidth(self: *const Table, i: usize) usize {
        const base = @max(self.columns[i].width, self.columns[i].min_width);
        if (self.sort_dir == .none or self.sort_column != i) return base;
        return @max(base, stringWidth(self.columns[i].name) + sort_arrow_cells);
    }

    /// `table_set_style`: takes ownership of `new_style` the same way
    /// `init` takes its `style` param, freeing the previous one first.
    pub fn setStyle(self: *Table, new_style: TableStyle) void {
        self.style.deinit(self.alloc);
        self.style = new_style;
    }

    /// Row indices in current display order: identity order (`0, 1, 2,
    /// ...`) when unsorted or `sort_column` is out of range, otherwise
    /// sorted on that column's `SortKey` -- `.number` numerically,
    /// `.text` byte-lexically or (when the column is `case_insensitive`)
    /// ASCII-case-folded with a raw-byte tie-break. Comparing a `.text`
    /// key against a `.number` one, which shouldn't happen since a
    /// column's cells are all built the same way by whatever sent
    /// `table_set_rows`, treats them as equal rather than erroring.
    /// Caller-owned, freed by the caller.
    pub fn sortedIndices(self: *const Table, alloc: std.mem.Allocator) ![]usize {
        const indices = try alloc.alloc(usize, self.rows.len);
        for (indices, 0..) |*idx, i| idx.* = i;

        const col = self.sort_column orelse return indices;
        if (self.sort_dir == .none or col >= self.columns.len) return indices;

        const SortCtx = struct {
            rows: []const TableRow,
            col: usize,
            ascending: bool,
            fold: bool,

            fn order(ctx: @This(), a: usize, b: usize) std.math.Order {
                const ka = ctx.rows[a].cells[ctx.col].sort_key;
                const kb = ctx.rows[b].cells[ctx.col].sort_key;
                return switch (ka) {
                    .text => |ta| switch (kb) {
                        .text => |tb| if (ctx.fold) asciiFoldOrder(ta, tb) else std.mem.order(u8, ta, tb),
                        .number => .eq,
                    },
                    .number => |na| switch (kb) {
                        .number => |nb| std.math.order(na, nb),
                        .text => .eq,
                    },
                };
            }

            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const ord = ctx.order(a, b);
                return if (ctx.ascending) ord == .lt else ord == .gt;
            }
        };
        std.mem.sort(usize, indices, SortCtx{
            .rows = self.rows,
            .col = col,
            .ascending = self.sort_dir == .ascending,
            .fold = self.columns[col].kind == .text and self.columns[col].case_insensitive,
        }, SortCtx.lessThan);
        return indices;
    }

    /// Repaints this table's current (sorted) view directly into `layer`'s
    /// cells at `(self.row, self.col)` -- the "compile structured data
    /// into ordinary cells" step. Runs once per mutation
    /// (`table_set_rows`/`table_set_sort`/`table_set_style`, each via
    /// their dispatch handler), not per frame -- there's no per-frame
    /// table-specific work at all, since glyphwire-host's existing render
    /// pass already draws whatever's in the cell buffer.
    ///
    /// Draws top-down from `self.row`, scrolling the layer a row at a time
    /// as it goes whenever the next piece would run past the bottom edge --
    /// exactly how ordinary terminal output behaves. A table drawn as a
    /// command's output (`glyphwire-ls -l`, printed wherever the shell's
    /// prompt happened to leave the cursor) that's taller than the window
    /// then scrolls its header and earliest rows up into scrollback, the
    /// live tail filling the viewport, with no blank filler anywhere --
    /// the table is a first-class model object for the sake of re-sorting
    /// later, not so it can freeze a header or clip its middle. The scroll
    /// is resolved once per *piece* (`tableMakeRoom`), never per cell: a
    /// per-cell resolution scrolls relative to whatever's currently on top
    /// every call, which is the compounding-scroll bug the
    /// client-composited prototype this replaced first hit. Total scrolling
    /// is capped at the layer's capacity, so a table with more rows than
    /// the viewport plus scrollback can hold degrades to dropping its
    /// newest rows rather than spinning.
    ///
    /// Writes every cell directly (`layer.cell(r, c)`) rather than through
    /// `Layer.writeText`/`drawIcon`'s cursor-implicit helpers -- the scroll
    /// bookkeeping lives here, in one place, so nothing downstream triggers
    /// another. Horizontal overflow just clips (`self.col` never moves) --
    /// there's no horizontal-scroll concept for a cell grid, same as
    /// `drawImage` clamping its own rectangle to the layer's
    /// width.
    pub fn render(self: *Table, layer: *Layer, ctx: *const Context) !void {
        clearExtent(layer, self.painted);

        var content_width: usize = 0;
        for (self.columns, 0..) |_, i| {
            if (i > 0) content_width += 1;
            content_width += self.headerColWidth(i);
        }
        const border_pad: usize = if (self.style.borders) 1 else 0;
        const row_height = @max(self.style.row_height, 1);

        const content_start_col = self.col + border_pad;
        const anchor_row = self.row;
        var cur_row = self.row;
        var scrolled: usize = 0;

        // Every write below is inside the viewport (`tableMakeRoom` scrolls
        // to keep it so), so the signed-row helpers take a plain `@intCast`.
        if (self.style.borders) {
            tableMakeRoom(layer, &cur_row, &scrolled, 1);
            self.drawBorderEdge(layer, ctx, @intCast(cur_row), content_width, .top);
            cur_row += 1;
        }

        tableMakeRoom(layer, &cur_row, &scrolled, 1);
        self.writeHeaderRow(layer, @intCast(cur_row), content_start_col);
        if (self.style.borders) self.drawSideBorders(layer, ctx, @intCast(cur_row), content_width);
        cur_row += 1;

        if (self.style.header_separator) {
            tableMakeRoom(layer, &cur_row, &scrolled, 1);
            self.drawSeparatorRow(layer, ctx, @intCast(cur_row), content_start_col, content_width);
            cur_row += 1;
        }

        const indices = try self.sortedIndices(self.alloc);
        defer self.alloc.free(indices);

        for (indices, 0..) |row_idx, display_i| {
            const rh = self.bodyRowHeight(ctx, self.rows[row_idx]);
            tableMakeRoom(layer, &cur_row, &scrolled, rh);
            const row_bg = if (self.style.alt_row_bg != null and display_i % 2 == 1) self.style.alt_row_bg else null;
            if (row_bg) |bg| fillRowBg(layer, @intCast(cur_row), content_start_col, content_width, rh, bg);
            if (self.style.borders) {
                var line: usize = 0;
                while (line < rh) : (line += 1) self.drawSideBorders(layer, ctx, @intCast(cur_row + line), content_width);
            }
            self.writeBodyRow(layer, ctx, self.rows[row_idx], @intCast(cur_row), content_start_col, row_height, row_bg);
            cur_row += rh;
        }

        if (self.style.borders) {
            tableMakeRoom(layer, &cur_row, &scrolled, 1);
            self.drawBorderEdge(layer, ctx, @intCast(cur_row), content_width, .bottom);
            cur_row += 1;
        }

        // The painted extent is the table's *on-screen* footprint after any
        // scrolling: its top is `anchor_row` shifted up by however many
        // rows scrolled by (0 once it's scrolled off into history), its
        // bottom is wherever the loop left `cur_row`, clamped to the
        // viewport. `clearExtent` blanks exactly this region next render.
        const painted_top = anchor_row -| scrolled;
        const painted_bottom = @min(cur_row, layer.height);
        self.row = painted_top;
        // Unclamped: goes negative when the header scrolled up into
        // history. `scrollOne` decrements it as more output arrives, so
        // `headerColumnAt`/`repaint` can always find the table again.
        self.top_live = @as(i64, @intCast(anchor_row)) - @as(i64, @intCast(scrolled));
        self.painted = .{
            .row = painted_top,
            .col = self.col,
            .rows = painted_bottom - painted_top,
            .cols = content_width + 2 * border_pad,
        };
        self.revision += 1;
        // The per-cell writers don't bump the layer's render generation;
        // do it here so glyphwire-host repaints even when the table fit
        // without a `clearExtent`/`scrollOne` (which do bump it).
        layer.touchRender();
    }

    /// Repaint the table's current cells in place -- what a re-sort
    /// (`table_set_sort`, or a glyphwire-host header click) and a re-style
    /// need, as opposed to `render`'s "draw fresh at the cursor, scrolling
    /// the layer terminal-style" (right only when the table is first put
    /// on screen). The row *set* is unchanged, so this never scrolls the
    /// layer: it redraws the table at its current position (`top_live`,
    /// kept accurate by `scrollOne`/`resize` as output and window changes
    /// move the table since `render`), writing every row **wherever it now
    /// lives** -- live viewport, retained scrollback, or straddling the
    /// two (`Layer.cellSigned`). So a re-sorted table stays consistently
    /// sorted when it scrolls back into view, and the header's arrow is
    /// visible whether the header is on screen or a few rows up in
    /// history. Only rows older than retained history are lost. Falls back
    /// to `render` if the table was never rendered (`revision == 0`).
    pub fn repaint(self: *Table, layer: *Layer, ctx: *const Context) !void {
        if (self.revision == 0) return self.render(layer, ctx);
        self.painted = try self.paintAt(layer, ctx, self.top_live);
        self.revision += 1;
        // The signed-cell writes in `paintAt` don't bump the layer's
        // render generation the way `Layer.clear`/`writeText` do, so mark
        // it stale here -- otherwise a header-click re-sort of an
        // on-screen table wouldn't trigger a repaint until the next
        // unrelated frame.
        layer.touchRender();
    }

    /// Draws every piece of the table -- top border, header, separator,
    /// body rows, bottom border -- top-down starting at signed
    /// live-viewport row `top` (negative once the table's top has
    /// scrolled up into history). Each row is first blanked across the
    /// wider of the table's old (`painted.cols`) and new column span so a
    /// narrower re-sort leaves no stale trailing cells, then drawn.
    /// Placement is via `Layer.cellSigned`, so a row lands in the
    /// viewport or in scrollback transparently; a row older than retained
    /// history is silently skipped (its cells are gone). Returns the
    /// table's *on-screen* footprint (clamped to the viewport) for
    /// `repaint` to stash as `painted` -- what `table_get_state` and
    /// `destroy_table` need. Shares the column layout (`headerColWidth`)
    /// and the per-piece writers with `render`; only the vertical
    /// placement rule differs (clip-and-reach-into-history here, scroll
    /// there).
    fn paintAt(self: *Table, layer: *Layer, ctx: *const Context, top: i64) !PaintedExtent {
        var content_width: usize = 0;
        for (self.columns, 0..) |_, i| {
            if (i > 0) content_width += 1;
            content_width += self.headerColWidth(i);
        }
        const border_pad: usize = if (self.style.borders) 1 else 0;
        const row_height = @max(self.style.row_height, 1);
        const content_start_col = self.col + border_pad;
        const height_i: i64 = @intCast(layer.height);
        const total_cols = content_width + 2 * border_pad;

        // Blank one signed row across the table's full column span (old or
        // new, whichever is wider) before it's redrawn.
        const clear_cols = @max(self.painted.cols, total_cols);
        const blankRow = struct {
            fn f(l: *Layer, r: i64, start: usize, cols: usize) void {
                const cells = l.rowAtSigned(r) orelse return;
                const end = @min(start + cols, cells.len);
                var c = start;
                while (c < end) : (c += 1) cells[c] = .{};
            }
        }.f;

        var cur: i64 = top;

        if (self.style.borders) {
            blankRow(layer, cur, self.col, clear_cols);
            self.drawBorderEdge(layer, ctx, cur, content_width, .top);
            cur += 1;
        }

        blankRow(layer, cur, self.col, clear_cols);
        self.writeHeaderRow(layer, cur, content_start_col);
        if (self.style.borders) self.drawSideBorders(layer, ctx, cur, content_width);
        cur += 1;

        if (self.style.header_separator) {
            blankRow(layer, cur, self.col, clear_cols);
            self.drawSeparatorRow(layer, ctx, cur, content_start_col, content_width);
            cur += 1;
        }

        const indices = try self.sortedIndices(self.alloc);
        defer self.alloc.free(indices);

        for (indices, 0..) |row_idx, display_i| {
            const rh = self.bodyRowHeight(ctx, self.rows[row_idx]);
            const rh_i: i64 = @intCast(rh);
            var line: i64 = 0;
            while (line < rh_i) : (line += 1) blankRow(layer, cur + line, self.col, clear_cols);
            const row_bg = if (self.style.alt_row_bg != null and display_i % 2 == 1) self.style.alt_row_bg else null;
            if (row_bg) |bg| fillRowBg(layer, cur, content_start_col, content_width, rh, bg);
            if (self.style.borders) {
                line = 0;
                while (line < rh_i) : (line += 1) self.drawSideBorders(layer, ctx, cur + line, content_width);
            }
            self.writeBodyRow(layer, ctx, self.rows[row_idx], cur, content_start_col, row_height, row_bg);
            cur += rh_i;
        }

        if (self.style.borders) {
            blankRow(layer, cur, self.col, clear_cols);
            self.drawBorderEdge(layer, ctx, cur, content_width, .bottom);
            cur += 1;
        }

        const vis_top = std.math.clamp(top, 0, height_i);
        const vis_bot = std.math.clamp(cur, 0, height_i);
        return .{
            .row = @intCast(vis_top),
            .col = self.col,
            .rows = @intCast(vis_bot - vis_top),
            .cols = total_cols,
        };
    }

    fn writeHeaderRow(self: *const Table, layer: *Layer, row: i64, content_start_col: usize) void {
        const fg = self.style.header_fg orelse Color.role(.table_header);
        var col = content_start_col;
        for (self.columns, 0..) |column, i| {
            if (i > 0) {
                writeCellRun(layer, row, col, "", 1, .start, fg, self.style.header_bg, null, false);
                col += 1;
            }
            const width = self.headerColWidth(i);
            if (self.sort_dir != .none and self.sort_column == i) {
                // The active sort column draws its name plus a direction
                // arrow ("Name ▴"); `headerColWidth` already widened this
                // column so the arrow fits without clipping the name. A
                // pathologically long name (>~250 bytes) that overflows
                // the format buffer just drops the arrow.
                var buf: [256]u8 = undefined;
                const label = std.fmt.bufPrint(
                    &buf,
                    "{s} {s}",
                    .{ column.name, sortArrowGlyph(self.sort_dir) },
                ) catch column.name;
                writeCellRun(layer, row, col, label, width, column.h_align, fg, self.style.header_bg, null, false);
            } else {
                writeCellRun(layer, row, col, column.name, width, column.h_align, fg, self.style.header_bg, null, false);
            }
            col += width;
        }
    }

    /// One column's icon (if any) plus display text, on the row block's
    /// middle line (`top_row + row_height / 2` -- `row_height == 1`
    /// lands on the block's only line). The icon is drawn `.natural`-scaled
    /// and capped to `row_height` cell-heights tall (so a `row_height == 1`
    /// row's icon fills that single line without spilling onto its
    /// neighbours, and a `row_height > 1` "large format" row's icon grows
    /// past its own line into the block's blank rows), then reserves enough
    /// leading columns that the text after it doesn't collide -- from the
    /// icon's own natural pixel width (`ctx.imageInfo`, read from the
    /// actually-loaded image rather than a hardcoded constant, unlike the
    /// client-composited prototype's fixed `icon_native_px`). Same "fill
    /// the line" rendering `writeGrid`'s icons in glyphwire-ls's non-table
    /// listing use. If the session's cell pixel metrics are unavailable
    /// (`ctx.cell_px_w`/`_h` zeroed) it falls back to a plain one-cell
    /// `.fit`.
    ///
    /// The icon goes into `Cell.fg_icon` (`setCellIconOver`), not
    /// `style.bg` -- it composites *over* the row's background rather than
    /// replacing it, so an `alt_row_bg` stripe stays unbroken behind the
    /// icon cell and a `.natural`-scaled icon that overflows into
    /// neighboring rows/columns paints over their backgrounds too. See
    /// `setCellIconOver`'s doc comment.
    fn writeBodyRow(self: *const Table, layer: *Layer, ctx: *const Context, row: TableRow, top_row: i64, content_start_col: usize, row_height: usize, row_bg: ?Color) void {
        const mid_row = top_row + @as(i64, @intCast(row_height / 2));
        var col = content_start_col;
        for (self.columns, 0..) |column, i| {
            // `headerColWidth`, not the nominal width, so body cells stay
            // under their header: the active sort column is wider by the
            // arrow's `sort_arrow_cells`, which becomes trailing padding
            // here (or, for an `.end`-aligned column, keeps the value
            // flush under the arrow).
            const width = self.headerColWidth(i);
            const cell = row.cells[i];
            const icon_reserve = self.iconReserve(ctx, cell);

            if (cell.icon) |icon_handle| {
                if (ctx.cell_px_w > 0 and ctx.cell_px_h > 0) {
                    setCellIconOver(layer, mid_row, col, icon_handle, .natural, .start, .center, self.iconMaxH(ctx), cell.metadata_id);
                } else {
                    setCellIconOver(layer, mid_row, col, icon_handle, .fit, .center, .center, null, cell.metadata_id);
                }
            }

            const text_col = col + icon_reserve;
            const text_width = width -| icon_reserve;
            const fg = cell.fg orelse default_style.fg;
            switch (column.overflow) {
                .ellipsis => writeCellRun(layer, mid_row, text_col, cell.display, text_width, column.h_align, fg, row_bg, cell.metadata_id, column.focus),
                .wrap => {
                    // Wrapped at the nominal width (see `wrapWidth`), each
                    // line padded out to the header's. The first line sits
                    // where an unwrapped cell's text would; the rest run
                    // down into the rows `bodyRowHeight` added.
                    var it = WrapIterator.init(cell.display, self.wrapWidth(ctx, i, cell));
                    var line: i64 = 0;
                    while (it.next()) |text| : (line += 1) {
                        writeCellRun(layer, mid_row + line, text_col, text, text_width, column.h_align, fg, row_bg, cell.metadata_id, column.focus and line == 0);
                    }
                    if (line == 0) writeCellRun(layer, mid_row, text_col, "", text_width, column.h_align, fg, row_bg, cell.metadata_id, column.focus);
                },
            }

            col += width + 1;
        }
    }

    /// How many lines body row `row` takes: `style.row_height`, or more
    /// when a `.wrap` cell needs them. A wrapped cell's first line is the
    /// band's middle line (`row_height / 2`, where every cell's text
    /// sits), so it needs `row_height / 2 + lines` rows in all.
    fn bodyRowHeight(self: *const Table, ctx: *const Context, row: TableRow) usize {
        const band = @max(self.style.row_height, 1);
        var h = band;
        for (self.columns, 0..) |column, i| {
            if (column.overflow != .wrap) continue;
            const cell = row.cells[i];
            h = @max(h, band / 2 + wrapLineCount(cell.display, self.wrapWidth(ctx, i, cell)));
        }
        return h;
    }

    /// The width a `.wrap` cell's text wraps at: the column's *nominal*
    /// width less its icon, not `headerColWidth`. Sorting on a column
    /// widens it by the arrow; if that re-wrapped its cells, a re-sort
    /// would change the table's height, and `repaint` (which redraws in
    /// place) would overrun whatever sits below the table.
    fn wrapWidth(self: *const Table, ctx: *const Context, i: usize, cell: TableCell) usize {
        return self.columns[i].width -| self.iconReserve(ctx, cell);
    }

    /// The pixel cap on a body icon's height: the style's `row_height`
    /// band, and `style.max_icon_px` (if set) further, so a tall row
    /// still renders a modest icon. Never the extra lines a wrapped cell
    /// adds -- an icon doesn't swell with its row's text.
    fn iconMaxH(self: *const Table, ctx: *const Context) u32 {
        const band = @max(self.style.row_height, 1);
        return @min(
            @as(u32, @intCast(band * ctx.cell_px_h)),
            self.style.max_icon_px orelse std.math.maxInt(u32),
        );
    }

    /// Leading cells `cell`'s icon takes before its text: its rendered
    /// pixel width rounded up to whole cells plus a one-cell gap, or a
    /// single `.fit` cell without the session's cell pixel metrics. 0 for
    /// a cell with no icon.
    fn iconReserve(self: *const Table, ctx: *const Context, cell: TableCell) usize {
        const icon_handle = cell.icon orelse return 0;
        if (ctx.cell_px_w == 0 or ctx.cell_px_h == 0) return 1;
        const info = ctx.imageInfo(icon_handle) orelse ImageInfo{ .width = 0, .height = 0 };
        const render_px = @min(info.width, self.iconMaxH(ctx));
        return (render_px + ctx.cell_px_w - 1) / ctx.cell_px_w + 1;
    }

    fn drawBorderEdge(self: *const Table, layer: *Layer, ctx: *const Context, row: i64, content_width: usize, edge: enum { top, bottom }) void {
        const corner_l = if (edge == .top) "tl" else "bl";
        const mid = if (edge == .top) "t" else "b";
        const corner_r = if (edge == .top) "tr" else "br";
        const total_width = content_width + 2;

        drawBorderTile(layer, ctx, row, self.col, self.style.box_style, corner_l);
        var c = self.col + 1;
        while (c < self.col + total_width - 1) : (c += 1) drawBorderTile(layer, ctx, row, c, self.style.box_style, mid);
        drawBorderTile(layer, ctx, row, self.col + total_width - 1, self.style.box_style, corner_r);
    }

    fn drawSideBorders(self: *const Table, layer: *Layer, ctx: *const Context, row: i64, content_width: usize) void {
        drawBorderTile(layer, ctx, row, self.col, self.style.box_style, "l");
        drawBorderTile(layer, ctx, row, self.col + content_width + 1, self.style.box_style, "r");
    }

    fn drawSeparatorRow(self: *const Table, layer: *Layer, ctx: *const Context, row: i64, content_start_col: usize, content_width: usize) void {
        if (self.style.borders) drawBorderTile(layer, ctx, row, self.col, self.style.box_style, "l");
        var c = content_start_col;
        while (c < content_start_col + content_width) : (c += 1) drawBorderTile(layer, ctx, row, c, self.style.box_style, "t");
        if (self.style.borders) drawBorderTile(layer, ctx, row, self.col + content_width + 1, self.style.box_style, "r");
    }
};

fn fillRowBg(layer: *Layer, top_row: i64, content_start_col: usize, content_width: usize, row_height: usize, bg: Color) void {
    var line: usize = 0;
    while (line < row_height) : (line += 1) {
        const r = top_row + @as(i64, @intCast(line));
        var c = content_start_col;
        const end = @min(content_start_col + content_width, layer.width);
        while (c < end) : (c += 1) setCellText(layer, r, c, "", default_style.fg, bg, null);
    }
}

fn borderTileHandle(ctx: *const Context, box_style: []const u8, piece: []const u8, name_buf: []u8) ?ImageHandle {
    // Tiles are catalog entries `"<style>/<piece>"` -- the `assets/icons/`
    // scan names an icon by its path under that directory (see
    // `iconName`), so the bundled `box` style lives in
    // `assets/icons/box/` and resolves as `box/tl`, `box/t`, and so on.
    const name = std.fmt.bufPrint(name_buf, "{s}/{s}", .{ box_style, piece }) catch return null;
    return ctx.iconHandle(name);
}

fn drawBorderTile(layer: *Layer, ctx: *const Context, row: i64, col: usize, box_style: []const u8, piece: []const u8) void {
    var buf: [64]u8 = undefined;
    const handle = borderTileHandle(ctx, box_style, piece, &buf) orelse return;
    setCellIcon(layer, row, col, handle, .stretch, .center, .center, null, null);
}

/// Writes `text` into `layer` starting at `(row, col)`, measured in
/// **display cells** (East Asian wide codepoints take 2 -- see
/// `stringWidth`): truncated with a trailing "…" if wider than `width`,
/// or left/center/right-padded with spaces (per `h_align`) if narrower --
/// same shape the client-composited table prototype's `formatCell` had,
/// just writing straight into cells. A wide codepoint is never split
/// across the column edge; if one won't fit the remaining space the run
/// stops there (and the "…" / padding fills the gap). Clipped to the
/// layer's bounds and to `width` cells -- a column running off the right
/// edge loses its tail, matching `Table.render`'s "clip, don't scroll".
/// A no-op if `width` is 0.
/// `focus` marks the first cell the *body* of the run lands in (past any
/// alignment padding) as its span's focus cell -- see `Cell.meta_focus`
/// and `TableColumn.focus`. Nothing is marked when the run has no body at
/// all (an empty `text`, or a column too narrow to fit a single glyph).
fn writeCellRun(layer: *Layer, row: i64, col: usize, text: []const u8, width: usize, h_align: HAlign, fg: Color, bg: ?Color, metadata_id: ?MetadataHandle, focus: bool) void {
    if (width == 0 or col >= layer.width) return;
    if (layer.rowAtSigned(row) == null) return; // row not in the retained buffer
    const end_col = @min(col + width, layer.width);

    const text_width = stringWidth(text);
    const truncate = text_width > width;
    const keep: usize = if (truncate) width -| 1 else text_width;
    const pad: usize = if (truncate) 0 else width - text_width;
    const lead: usize = if (truncate) 0 else switch (h_align) {
        .start => 0,
        .end => pad,
        .center => pad / 2,
    };

    var c = col;
    var n: usize = 0;
    while (n < lead and c < end_col) : (n += 1) {
        setCellText(layer, row, c, " ", fg, bg, metadata_id);
        c += 1;
    }

    const view = std.unicode.Utf8View.init(text) catch (std.unicode.Utf8View.init("") catch unreachable);
    var it = view.iterator();
    var written: usize = 0; // display cells of the body written so far
    while (written < keep and c < end_col) {
        const cp_bytes = it.nextCodepointSlice() orelse break;
        const w = codepointWidth(std.unicode.utf8Decode(cp_bytes) catch 0xFFFD);
        if (written + w > keep) break;
        const body_start = c;
        if (w == 2) {
            if (c + 1 >= end_col) break; // wide glyph won't fit the column tail
            setCellWide(layer, row, c, cp_bytes, fg, bg, metadata_id);
            c += 2;
        } else {
            setCellText(layer, row, c, cp_bytes, fg, bg, metadata_id);
            c += 1;
        }
        // The first glyph of the body, once it's actually been written --
        // `setCell*` clears `meta_focus`, so the mark has to go on after.
        if (focus and written == 0) {
            if (layer.cellSigned(row, body_start)) |bc| bc.meta_focus = true;
        }
        written += w;
    }

    if (truncate and c < end_col) {
        setCellText(layer, row, c, "\u{2026}", fg, bg, metadata_id);
        c += 1;
    }

    while (c < end_col) : (c += 1) setCellText(layer, row, c, " ", fg, bg, metadata_id);
}
