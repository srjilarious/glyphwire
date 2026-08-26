const std = @import("std");
const core = @import("core.zig");
const client_mod = @import("client.zig");

const Client = client_mod.Client;

/// One column's shape: display name (used as the header cell's text),
/// a formatting hint for later sort/format work (not enforced yet, `cell`
/// takes plain text regardless of `kind`), and sizing. `width` is the
/// column's target content width in cells; `min_width` is a floor `start`
/// clamps `width` to, so a caller can shrink columns to fit available
/// space later without a column collapsing to nothing.
pub const ColumnDef = struct {
    name: []const u8,
    kind: enum { text, number } = .text,
    width: usize,
    min_width: usize = 1,
    h_align: core.HAlign = .start,
};

/// Rendering knobs for `start` -- the parts of a table's look that aren't
/// per-column. `borders`/`box_style` reuse the same 9-tile catalog
/// `draw_box` already resolves against (see `core.default_box_manifest`),
/// so a table's frame is made of the same pieces as everything else that
/// draws a box; `alt_row_bg` stripes every other body row (not the header)
/// starting with the second row, `null` disables striping entirely.
///
/// `header_separator` is independent of `borders` -- a table can have
/// either, both, or neither: the horizontal rule under the header is drawn
/// with the same tiles as the outer frame's edges, but doesn't need the
/// frame itself to make sense on its own (a "borderless, striped, ruled
/// header" table is a normal, common table look).
pub const TableStyle = struct {
    borders: bool = true,
    header_separator: bool = true,
    box_style: []const u8 = "box",
    alt_row_bg: ?core.Color = null,
    header_fg: ?core.Color = null,
    header_bg: ?core.Color = null,
};

pub const StartOptions = struct {
    /// Anchor position; both default to the layer's current cursor when
    /// omitted, same convention `draw_box`/`draw_icon` already use.
    row: ?usize = null,
    col: ?usize = null,
    columns: []const ColumnDef,
    style: TableStyle = .{},
};

/// A streaming table widget built entirely out of existing wire primitives
/// (`write_text`, `draw_icon`, `set_property("cursor")`) -- there is no
/// `table` message on the wire, this is client-side composition only. Rows
/// are drawn as they're submitted rather than buffered and measured, which
/// is why column widths are given up front (`ColumnDef.width`) instead of
/// auto-sized from content -- a table doesn't know its last row until
/// `end` is called.
///
/// Usage: `start` draws the header (and top border, if enabled), then each
/// body row is `row` (opens it, applies striping) followed by one `cell`
/// per column in order, `endRow` (closes it), repeated; `end` draws the
/// bottom border. Calling `cell` more times than there are columns, or
/// outside an open `row`/`endRow` pair, is a caller bug (`error.TooManyCells`/
/// `error.NoActiveRow`) -- unlike a dangling metadata id elsewhere in this
/// codebase, there's no sensible way to degrade a table shaped wrong.
///
/// Borders are an outer frame plus one separator line under the header --
/// deliberately not a full interior grid. The bundled box tile set (see
/// `core.default_box_manifest`) only has corner/edge/fill pieces, no
/// T-junction or cross tiles, so a vertical line between columns would
/// have nowhere clean to meet the header separator or the top/bottom
/// border. A one-cell gap between columns (always present, border or not)
/// does the visual separation job instead.
pub const Table = struct {
    client: *Client,
    columns: []const ColumnDef,
    style: TableStyle,
    borders: bool,
    /// Absolute column of the left border tile (== `content_start_col`
    /// when `borders` is false, since there's no border column to offset
    /// past).
    left_col: usize,
    /// Absolute column where the first column's content starts.
    content_start_col: usize,
    /// Sum of every column's (clamped) width plus one gap cell between
    /// each pair of columns -- the interior span `row`'s striping fill
    /// covers, and what `content_start_col` plus this reaches just past
    /// the right border (or the table's right edge, borderless).
    content_width: usize,
    /// `content_width` plus 2 border columns (0 when `borders` is false).
    total_width: usize,
    /// Absolute row the next thing drawn (header, a border line, or the
    /// next body row) lands on.
    cur_row: usize,
    /// 0-based count of body rows opened so far via `row` -- drives
    /// alternating striping (odd rows) and is otherwise unused.
    row_index: usize = 0,
    /// Index into `columns` the next `cell` call fills.
    cur_col_idx: usize = 0,
    in_row: bool = false,

    /// Draws the top border (if enabled), the header row, and the header
    /// separator line (if enabled), and returns a `Table` positioned to
    /// accept `row`/`cell`/`endRow` calls for the body. See `Table`'s doc
    /// comment for the overall shape.
    pub fn start(client: *Client, opts: StartOptions) !Table {
        if (opts.columns.len == 0) return error.NoColumns;

        var top_row = opts.row;
        var left_col = opts.col;
        if (top_row == null or left_col == null) {
            const cur = try client.getCursor();
            if (top_row == null) top_row = cur.row;
            if (left_col == null) left_col = cur.col;
        }

        var content_width: usize = 0;
        for (opts.columns, 0..) |column, i| {
            if (i > 0) content_width += 1; // inter-column gap
            content_width += @max(column.width, column.min_width);
        }

        var self = Table{
            .client = client,
            .columns = opts.columns,
            .style = opts.style,
            .borders = opts.style.borders,
            .left_col = left_col.?,
            .content_start_col = left_col.? + (if (opts.style.borders) @as(usize, 1) else 0),
            .content_width = content_width,
            .total_width = content_width + (if (opts.style.borders) @as(usize, 2) else 0),
            .cur_row = top_row.?,
        };

        if (self.borders) {
            try self.resolveCurRow();
            try self.drawBorderEdge(self.cur_row, .top);
            self.cur_row += 1;
        }

        try self.resolveCurRow();
        try self.writeHeaderRow(self.cur_row);
        if (self.borders) try self.drawSideBorders(self.cur_row);
        self.cur_row += 1;

        if (opts.style.header_separator) {
            try self.resolveCurRow();
            try self.drawSeparatorRow(self.cur_row);
            self.cur_row += 1;
        }

        return self;
    }

    /// Resolves `self.cur_row` against the layer's actual current state
    /// (scrolling it, and every cell already drawn along with it, if
    /// `self.cur_row` is at or past the bottom) via one `set_property`/
    /// `get_property(cursor)` round trip, then updates `self.cur_row` to
    /// match. Must run exactly once per logical row, before the first
    /// draw call that targets it -- `Layer.resolveRow` (core.zig) scrolls
    /// *relative to whatever's currently at the top* every time it's
    /// called with an out-of-bounds row, so calling it repeatedly with the
    /// same nominal row number -- which every multi-cell row here would
    /// otherwise do, once per cell/border tile -- compounds into runaway
    /// extra scrolling instead of landing everything on one physical row.
    /// This is the same reason `glyphwire-ls`'s `writeGrid` re-reads
    /// `get_property(cursor)` fresh before each entry rather than tracking
    /// a local row counter (see its doc comment) -- generalized here to
    /// every row-drawing entry point in this file (`start`'s border/header/
    /// separator rows, `row`'s body row, `end`'s bottom border).
    fn resolveCurRow(self: *Table) !void {
        try self.client.setCursor(self.cur_row, self.content_start_col);
        const cur = try self.client.getCursor();
        self.cur_row = cur.row;
    }

    /// Opens a new body row: resolves `self.cur_row` (see `resolveCurRow`),
    /// draws its side border tiles (if enabled), and, on a striped row
    /// (odd `row_index`, when `style.alt_row_bg` is set), pre-fills the
    /// whole interior width with that background so the gap cells between
    /// columns pick up the stripe too, not just the text cells `cell`
    /// writes afterward.
    pub fn row(self: *Table) !void {
        if (self.in_row) return error.RowAlreadyOpen;

        try self.resolveCurRow();

        if (self.borders) try self.drawSideBorders(self.cur_row);

        if (self.style.alt_row_bg) |bg| {
            if (self.row_index % 2 == 1) {
                const alloc = self.client.alloc;
                const fill = try alloc.alloc(u8, self.content_width);
                defer alloc.free(fill);
                @memset(fill, ' ');
                // `resolveCurRow` already parked the cursor at
                // `(self.cur_row, self.content_start_col)` -- no need to
                // set it again.
                try self.client.writeText(fill, null, bg);
            }
        }

        self.in_row = true;
        self.cur_col_idx = 0;
    }

    /// Writes one cell's text into the current row's next column, in
    /// order -- truncated with a trailing "…" and aligned per that
    /// column's `h_align` if it's longer than the column's width, padded
    /// with spaces otherwise. Must be called between `row` and `endRow`.
    pub fn cell(self: *Table, text: []const u8) !void {
        return self.cellStyled(text, .{});
    }

    /// `fg`/`metadata_id` for `cellStyled` -- see `Client.DrawIconOpts` for
    /// the same "a separate `*Styled` method/opts struct rather than extra
    /// params on the plain one" pattern, used here for the same reason
    /// (Zig has no default parameter values).
    pub const CellStyleOpts = struct {
        fg: ?core.Color = null,
        /// See `core.Cell.metadata_id`'s doc comment. Tags every cell this
        /// call writes to, same as `Client.writeTextTagged`.
        metadata_id: ?core.MetadataHandle = null,
    };

    /// Like `cell`, but with an explicit foreground color and/or metadata
    /// tag -- for a column whose per-row color carries meaning independent
    /// of striping (e.g. glyphwire-ls's directory/symlink/file name
    /// coloring), or that needs the same click-to-activate metadata
    /// tagging `glyphwire-ls`'s plain (non-table) listing already gives
    /// every cell an entry's row touches.
    pub fn cellStyled(self: *Table, text: []const u8, opts: CellStyleOpts) !void {
        if (!self.in_row) return error.NoActiveRow;
        if (self.cur_col_idx >= self.columns.len) return error.TooManyCells;

        const column = self.columns[self.cur_col_idx];
        const width = @max(column.width, column.min_width);
        const col = self.columnStartCol(self.cur_col_idx);

        const alloc = self.client.alloc;
        const formatted = try formatCell(alloc, text, width, column.h_align);
        defer alloc.free(formatted);

        const bg = if (self.row_index % 2 == 1) self.style.alt_row_bg else null;
        try self.client.setCursor(self.cur_row, col);
        if (opts.metadata_id) |mid| {
            try self.client.writeTextTagged(formatted, opts.fg, bg, mid);
        } else {
            try self.client.writeText(formatted, opts.fg, bg);
        }

        self.cur_col_idx += 1;
    }

    pub const IconCellOpts = struct {
        metadata_id: ?core.MetadataHandle = null,
    };

    /// Draws `name` (an icon-registry name, see `core.default_icon_manifest`)
    /// into the current row's next column, `.fit`-scaled to exactly that
    /// one cell. Unlike `glyphwire-ls`'s own icon rendering outside a
    /// table (`.natural` sized and capped, deliberately overflowing past
    /// its anchor cell for legibility -- see `core.IconScale`'s doc
    /// comment), a table's fixed-width grid model has no room for an icon
    /// to spill into a neighboring cell it doesn't own, so this stays
    /// inside its own cell like every other column does.
    ///
    /// A striped row's background (`row`'s pre-fill, see its doc comment)
    /// doesn't show through an icon cell: `Cell.style.bg` is a tagged
    /// union (flat color vs. image/icon reference, see decisions.md's Cell
    /// section), so drawing the icon here overwrites that one cell's color
    /// back to none, same as `draw_icon` would anywhere else.
    pub fn iconCell(self: *Table, name: []const u8) !void {
        return self.iconCellStyled(name, .{});
    }

    pub fn iconCellStyled(self: *Table, name: []const u8, opts: IconCellOpts) !void {
        if (!self.in_row) return error.NoActiveRow;
        if (self.cur_col_idx >= self.columns.len) return error.TooManyCells;

        const col = self.columnStartCol(self.cur_col_idx);
        try self.client.drawIconStyled(self.cur_row, col, name, .{ .metadata_id = opts.metadata_id });

        self.cur_col_idx += 1;
    }

    /// Closes the current body row -- fewer `cell` calls than columns just
    /// leaves the remaining columns as whatever `row`'s striping fill (or
    /// the blank default) already left there, not an error, since a
    /// sparse row is a normal thing for a caller to want.
    pub fn endRow(self: *Table) !void {
        if (!self.in_row) return error.NoActiveRow;
        self.in_row = false;
        self.row_index += 1;
        self.cur_row += 1;
    }

    /// Draws the bottom border, if enabled. Doesn't touch the cursor
    /// afterward -- same "a draw call doesn't relocate the cursor"
    /// convention `draw_box`/`draw_icon`/`draw_image` already follow (see
    /// decisions.md's Text Writing & Styling section); a caller that wants
    /// to write something below the table positions explicitly.
    pub fn end(self: *Table) !void {
        if (self.in_row) return error.RowStillOpen;
        if (self.borders) {
            try self.resolveCurRow();
            try self.drawBorderEdge(self.cur_row, .bottom);
        }
    }

    fn columnStartCol(self: *const Table, index: usize) usize {
        var col = self.content_start_col;
        var i: usize = 0;
        while (i < index) : (i += 1) {
            col += @max(self.columns[i].width, self.columns[i].min_width) + 1;
        }
        return col;
    }

    fn writeHeaderRow(self: *Table, row_idx: usize) !void {
        const alloc = self.client.alloc;
        var col = self.content_start_col;
        for (self.columns, 0..) |column, i| {
            if (i > 0) {
                try self.client.setCursor(row_idx, col);
                try self.client.writeText(" ", self.style.header_fg, self.style.header_bg);
                col += 1;
            }
            const width = @max(column.width, column.min_width);
            const formatted = try formatCell(alloc, column.name, width, column.h_align);
            defer alloc.free(formatted);
            try self.client.setCursor(row_idx, col);
            try self.client.writeText(formatted, self.style.header_fg, self.style.header_bg);
            col += width;
        }
    }

    /// Draws one border tile stretched to fill its cell exactly, same as
    /// `draw_box` does for its own 9 pieces (see decisions.md's Box
    /// section) -- plain `drawIcon` defaults to `scale: "fit"`, which
    /// letterboxes a non-square tile within its cell instead of filling
    /// it, leaving a visible gap along whichever axis the cell is
    /// tighter on. A table's border tiles need the same treatment
    /// `draw_box` already gives them, so this goes through
    /// `drawIconStyled` instead.
    fn drawBorderTile(self: *Table, row_idx: usize, col: usize, name: []const u8) !void {
        try self.client.drawIconStyled(row_idx, col, name, .{ .scale = .stretch });
    }

    fn drawSideBorders(self: *Table, row_idx: usize) !void {
        var buf: [32]u8 = undefined;
        try self.drawBorderTile(row_idx, self.left_col, try piece(&buf, self.style.box_style, "l"));
        try self.drawBorderTile(row_idx, self.left_col + self.total_width - 1, try piece(&buf, self.style.box_style, "r"));
    }

    /// The header/body divider line: "t" tiles across the full content
    /// width, plus "l"/"r" endpoints when `borders` is on (matching the
    /// side border tiles every other row in the frame gets) -- but usable
    /// on its own, spanning just the content width with no endpoints, on a
    /// borderless table that still wants a header rule (`header_separator`
    /// is independent of `borders`, see `TableStyle`'s doc comment).
    fn drawSeparatorRow(self: *Table, row_idx: usize) !void {
        var buf: [32]u8 = undefined;
        if (self.borders) {
            try self.drawBorderTile(row_idx, self.left_col, try piece(&buf, self.style.box_style, "l"));
        }
        var col = self.content_start_col;
        const content_end = self.content_start_col + self.content_width;
        while (col < content_end) : (col += 1) {
            try self.drawBorderTile(row_idx, col, try piece(&buf, self.style.box_style, "t"));
        }
        if (self.borders) {
            try self.drawBorderTile(row_idx, self.left_col + self.total_width - 1, try piece(&buf, self.style.box_style, "r"));
        }
    }

    fn drawBorderEdge(self: *Table, row_idx: usize, edge: enum { top, bottom }) !void {
        var buf: [32]u8 = undefined;
        const corner_l = if (edge == .top) "tl" else "bl";
        const mid = if (edge == .top) "t" else "b";
        const corner_r = if (edge == .top) "tr" else "br";

        try self.drawBorderTile(row_idx, self.left_col, try piece(&buf, self.style.box_style, corner_l));
        var col = self.left_col + 1;
        while (col < self.left_col + self.total_width - 1) : (col += 1) {
            try self.drawBorderTile(row_idx, col, try piece(&buf, self.style.box_style, mid));
        }
        try self.drawBorderTile(row_idx, self.left_col + self.total_width - 1, try piece(&buf, self.style.box_style, corner_r));
    }
};

/// Formats `{prefix}-{suffix}` (e.g. `"box-tl"`) into `buf` -- the same
/// icon-name convention `dispatch.zig`'s `draw_box` handler already uses
/// against `core.default_icon_manifest`, rebuilt here since a table draws
/// its border one tile at a time (`draw_icon`) rather than through one
/// `draw_box` call, to support drawing an unknown-in-advance number of
/// body rows one at a time as `row`/`endRow` are called.
fn piece(buf: []u8, prefix: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ prefix, suffix });
}

/// Counts `text`'s codepoints, matching `Layer.writeText`'s own
/// "naive UTF-8 codepoint splitting, not real grapheme segmentation"
/// cell-width assumption (core.zig) -- a cell here is a codepoint, not a
/// byte, so this must agree with that or truncation/padding would be off
/// by however many multi-byte characters a cell's text contains.
fn cellWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Returns the byte-slice prefix of `text` containing exactly `width`
/// codepoints (or all of `text`, if it has fewer). Invalid UTF-8 falls
/// back to a byte-count slice -- same fallback `cellWidth` uses, so the
/// two stay consistent with each other even in that degenerate case.
fn truncateToWidth(text: []const u8, width: usize) []const u8 {
    const view = std.unicode.Utf8View.init(text) catch return text[0..@min(width, text.len)];
    var iter = view.iterator();
    var count: usize = 0;
    var end: usize = 0;
    while (count < width) {
        const cp = iter.nextCodepointSlice() orelse break;
        end += cp.len;
        count += 1;
    }
    return text[0..end];
}

/// Renders `text` into exactly `width` cells: truncated (keeping
/// `width - 1` codepoints plus a trailing "…") and left/center/right
/// aligned per `h_align` if longer than `width`, space-padded otherwise.
/// Returns an owned slice the caller frees.
fn formatCell(alloc: std.mem.Allocator, text: []const u8, width: usize, h_align: core.HAlign) ![]u8 {
    if (width == 0) return alloc.alloc(u8, 0);

    const text_width = cellWidth(text);
    var display: []const u8 = text;
    var display_width = text_width;
    var owned: ?[]u8 = null;
    defer if (owned) |o| alloc.free(o);

    if (text_width > width) {
        const truncated = truncateToWidth(text, width - 1);
        owned = try std.fmt.allocPrint(alloc, "{s}\u{2026}", .{truncated});
        display = owned.?;
        display_width = width;
    }

    const pad = width - display_width;
    const lead = switch (h_align) {
        .start => 0,
        .end => pad,
        .center => pad / 2,
    };
    const trail = pad - lead;

    const buf = try alloc.alloc(u8, lead + display.len + trail);
    @memset(buf[0..lead], ' ');
    @memcpy(buf[lead..][0..display.len], display);
    @memset(buf[lead + display.len ..], ' ');
    return buf;
}
