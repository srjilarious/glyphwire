const std = @import("std");

/// Truecolor RGBA. The "use theme default" sentinel from decisions.md's
/// color model isn't needed until a real theme system exists; add it when
/// that lands.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

/// Server-generated reference to a loaded image, per the Object Model's
/// Image section.
pub const ImageHandle = u32;

/// Server-generated reference to an opaque, client-defined metadata blob
/// (`create_metadata`) -- a cell tags itself with one via
/// `Cell.metadata_id`, e.g. `write_text`/`draw_icon`'s optional
/// `metadata_id` param, rather than embedding the blob directly, so many
/// cells can share one without copying it (a whole filename written by one
/// `write_text` call, say, all pointing at the same id).
pub const MetadataHandle = u32;

pub const MetadataError = error{UnknownMetadata};

/// An opaque, server-stored-but-not-interpreted blob -- `json` because the
/// convention is a JSON string (so command-line tools and a future TUI can
/// each embed whatever shape of data they want, e.g. `{"kind":"file",
/// "path":"...","command":"cd ..."}`), but the server never parses it,
/// only stores and returns it verbatim (same treatment `ImageEntry.bytes`
/// gets for PNG bytes).
pub const Metadata = struct {
    json: []u8,
};

/// A cell's image-backed background: which loaded image, and the pixel
/// offset into that image this cell should display. `draw_image` computes
/// this per cell from the draw call's anchor -- see `Layer.drawImage` --
/// rather than a sub-image ever being extracted or cached as its own
/// resource (decisions.md's Image section).
pub const ImageBg = struct {
    handle: ImageHandle,
    offset_x: u32,
    offset_y: u32,
};

/// How an icon's source image is sized against its anchor cell:
/// - `fit` (the original, still-default behavior): shrunk/grown uniformly
///   (aspect preserved) to fit exactly within the cell.
/// - `natural`: drawn at its own native pixel size, optionally capped by
///   `IconBg.max_w`/`max_h` (uniform, aspect preserved, only ever shrinking
///   -- never upscaled past native size). Bigger than the cell overflows
///   into neighboring cells' *pixels* -- a pure rendering overlay, see
///   `IconBg`'s doc comment, so it never marks/claims those cells.
/// - `stretch`: fills the cell exactly on both axes, aspect *not*
///   preserved. Used by `Layer.drawBox`'s tiles rather than `fit`: a
///   non-square cell (this project's terminal cells usually are, since
///   glyph advance and line height rarely match) leaves `fit`-and-center
///   padding on whichever axis isn't the limiting one, breaking a
///   multi-tile border into visibly gapped segments along that axis --
///   `stretch` guarantees the tile always touches every edge of its cell,
///   so adjacent tiles' border lines stay continuous regardless of the
///   cell's aspect ratio.
pub const IconScale = enum { fit, natural, stretch };

/// Where a (possibly `natural`-sized, overflowing) icon sits relative to
/// its anchor cell along one axis. `center` (the default, matching the
/// pre-overflow behavior) grows the overflow symmetrically both ways;
/// `start`/`end` instead grow it entirely to one side, keeping the edge
/// on the anchor's `start`/`end` side flush with the cell.
pub const HAlign = enum { start, center, end };
pub const VAlign = enum { start, center, end };

/// A cell's icon-backed background: which loaded icon, how it's scaled,
/// and where it's aligned relative to its anchor cell. A `natural`-scaled
/// icon bigger than one cell overflows into neighboring cells' *pixels*
/// only -- deliberately not their data: this stays a single-cell anchor
/// in the grid (unlike `ImageBg`'s per-cell offset tracking), so
/// `get_cells`/clear/scroll on a neighboring cell know nothing about the
/// overflow, and the host's render pass is responsible for drawing it on
/// top of whatever those neighboring cells render. Kept deliberately
/// simple over `draw_image`'s span-marking approach because an icon is
/// meant to always read as one complete picture, not clipped/composed
/// per cell -- see decisions.md's Icon section.
pub const IconBg = struct {
    handle: ImageHandle,
    scale: IconScale = .fit,
    h_align: HAlign = .center,
    v_align: VAlign = .center,
    /// Only consulted when `scale == .natural` -- `fit`'s box is always
    /// exactly the cell, and `stretch` always fills it exactly, so neither
    /// has anything left to cap.
    max_w: ?u32 = null,
    max_h: ?u32 = null,
    /// Normalized (0..1) sub-rectangle of the source image this cell
    /// samples, defaulting to the whole image. A plain `draw_icon` never
    /// sets these -- a single icon is always one complete picture (this
    /// struct's own doc comment). The one caller that does is
    /// `Layer.drawBox`'s `BoxMode.stretch`: it gives each cell along a
    /// multi-cell edge/fill run its own slice of one logical tile image,
    /// so the whole run (e.g. a vertical gradient) reads as that one image
    /// scaled continuously across the run rather than repeated per cell
    /// (`BoxMode.tile`'s behavior, which leaves these at the default).
    src_l: f32 = 0,
    src_t: f32 = 0,
    src_r: f32 = 1,
    src_b: f32 = 1,
};

/// A cell's background: a flat color, a reference to a loaded image tile
/// (`draw_image`/`draw_box`, clipped rather than stretched -- see
/// `ImageBg`), or a reference to a loaded icon (`draw_icon`, see
/// `IconBg`). Mutually exclusive per decisions.md.
pub const Background = union(enum) {
    color: Color,
    image: ImageBg,
    icon: IconBg,
};

pub const ImageInfo = struct {
    width: u32,
    height: u32,
};

/// A loaded image resource: the raw bytes as received (PNG only for now,
/// per decisions.md's "assume PNG" scope), plus natural pixel dimensions.
/// The headless core never decodes pixels -- `width`/`height` come from
/// parsing just the PNG IHDR chunk (`pngDimensions`), not a real decode --
/// so `get_image_info` doesn't need an image-codec dependency here, and
/// unlike an earlier idea in roadmap.md, the *client* doesn't need to
/// supply dimensions either. Full pixel decoding stays the renderer's job
/// (glyphwire-host, which already links zstbi), lazily on first
/// encountering a `.image` background it hasn't uploaded yet.
pub const ImageEntry = struct {
    bytes: []u8,
    width: u32,
    height: u32,
};

pub const ImageError = error{InvalidPng};

/// Parses just the IHDR chunk's width/height from a PNG byte stream -- not
/// a decoder. Per the PNG spec, the 8-byte signature is always followed
/// immediately by the IHDR chunk (4-byte length, 4-byte "IHDR" tag, then
/// big-endian u32 width and height), so this is a fixed-offset read, not a
/// real parse.
pub fn pngDimensions(bytes: []const u8) ImageError!ImageInfo {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], &sig)) return ImageError.InvalidPng;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return ImageError.InvalidPng;
    return .{
        .width = std.mem.readInt(u32, bytes[16..20], .big),
        .height = std.mem.readInt(u32, bytes[20..24], .big),
    };
}

pub const Style = struct {
    fg: Color,
    bg: Background,
};

pub const default_style: Style = .{
    .fg = .{ .r = 255, .g = 255, .b = 255 },
    .bg = .{ .color = .{ .r = 0, .g = 0, .b = 0 } },
};

/// Inline byte capacity for a cell's grapheme cluster. This is a plain
/// fixed buffer for the slice, not the small-string-optimized
/// inline+overflow representation decisions.md settles on long term —
/// upgrade this alongside real UAX #29 segmentation.
pub const grapheme_inline_len = 8;

pub const Cell = struct {
    grapheme_bytes: [grapheme_inline_len]u8 = [_]u8{0} ** grapheme_inline_len,
    grapheme_len: u8 = 0,
    style: Style = default_style,
    /// Sibling of `style.bg`, not part of it -- a cell can be tagged
    /// regardless of whether its background is a color/image/icon. Set (or
    /// cleared) as a whole by `write_text`/`draw_icon`'s optional
    /// `metadata_id` param, the same way those calls already overwrite
    /// `grapheme`/`style` outright rather than merging with whatever was
    /// there before.
    metadata_id: ?MetadataHandle = null,
    /// An icon drawn *over* `style.bg` and `grapheme` rather than replacing
    /// either -- unlike the ordinary `draw_icon` (`style.bg`'s `.icon`
    /// variant), which is itself one of `Background`'s mutually exclusive
    /// cases and so necessarily replaces whatever background was there.
    /// Set by `Layer.drawIconOver` (`draw_icon`'s `foreground: true`),
    /// for content that needs to sit on top of an already-drawn background
    /// -- e.g. `glyphwire-notify`'s type icon over its `"dialog"` 9-patch
    /// panel, which `draw_icon`'s normal background-replacing behavior
    /// would otherwise punch a flat hole through.
    fg_icon: ?IconBg = null,

    pub fn setGrapheme(self: *Cell, bytes: []const u8) void {
        std.debug.assert(bytes.len <= grapheme_inline_len);
        @memcpy(self.grapheme_bytes[0..bytes.len], bytes);
        self.grapheme_len = @intCast(bytes.len);
    }

    pub fn grapheme(self: *const Cell) []const u8 {
        return self.grapheme_bytes[0..self.grapheme_len];
    }
};

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

/// A layer's viewport size in cells -- what `get_property(layer, "size")`
/// reports. For the root layer this is the context's base size, i.e. the
/// answer to "how big is the window right now" (see `Context.resize`).
pub const LayerSize = struct { cols: usize, rows: usize };

pub const PropertyName = enum {
    cursor,
    /// Bumped once per `writeText` call; a cheap poll a renderer client can
    /// use to decide whether it's worth fetching the (much larger) full
    /// cell grid again this frame. Get-only: `Layer.setProperty` traps if
    /// asked to set it.
    revision,
    /// Pixel-precise position relative to the layer's parent (the root
    /// layer for every layer `create_layer` makes today -- see
    /// decisions.md's Layer section on why position stays pixel-precise
    /// rather than cell-snapped: smooth animation, e.g. sliding a
    /// notification layer on/off screen, needs sub-cell steps).
    position,
    /// Viewport size in cells (`{cols, rows}`). Get-only: a client reads
    /// it (and, if subscribed, gets a `resize` notification when it
    /// changes) but can't set it -- the host owns the window size, see
    /// `Context.resize`.
    size,
};

pub const PropertyValue = union(PropertyName) {
    cursor: Cursor,
    revision: u64,
    position: PxPos,
    size: LayerSize,
};

pub const PropertyError = error{UnknownProperty};

/// A server-generated handle for a layer created via `create_layer`.
/// `root_layer_handle` (0) always refers to the context's root layer,
/// which always exists and isn't itself stored in `Context.layers` --
/// every other handle (1, 2, ...) is a `Context.layers` entry.
pub const LayerHandle = u32;
pub const root_layer_handle: LayerHandle = 0;

pub const LayerError = error{UnknownLayer};

/// A layer's cell grid is a fixed-capacity ring buffer of
/// `height + scrollback_rows` physical rows, one contiguous allocation.
/// The visible viewport is always the most recently written `height`
/// rows; writing past the bottom row scrolls (the old top row becomes
/// history, evicting the oldest history row once scrollback is full) —
/// the same "live tail" behavior a real terminal has. `scrollback_rows`
/// is a per-layer creation parameter (0 for a layer with no need for
/// history, e.g. a small popup notification) rather than a fixed default,
/// since layers range from a terminal-sized root layer down to something
/// like a 45x3 notification.
pub const Layer = struct {
    alloc: std.mem.Allocator,
    width: usize,
    height: usize,
    scrollback_rows: usize,
    /// Ring buffer storage: `capacity()` rows of `width` cells each.
    buf: []Cell,
    /// Physical row index (row units, not cell units) of the viewport's
    /// top row.
    viewport_start: usize = 0,
    /// How many rows above the viewport currently hold real history, vs.
    /// never-written blank space. Saturates at `scrollback_rows`.
    history_len: usize = 0,
    cursor: Cursor = .{},
    /// See `PropertyName.revision`.
    revision: u64 = 0,
    /// See `PropertyName.position`. Zero for the root layer (there's no
    /// wire path that moves it) and for a freshly created layer until its
    /// creator calls `set_property(layer, "position", ...)`.
    pos: PxPos = .{},
    /// Tables painted onto this layer (`create_table`), keyed by handle --
    /// decisions.md's Table section: a table is a component of a layer,
    /// not a parallel object tree like `Context.layers` is. A table's
    /// handle is still allocated from `Context.next_table_handle` (a
    /// single counter shared across every layer), but the `Table` value
    /// itself lives here, on whichever layer it was created on.
    tables: std.AutoHashMap(TableHandle, Table),
    /// Creation order of `tables`' entries, for repaint/compositing order
    /// -- same reasoning `Context.layer_order` already has for
    /// `Context.layers` (`AutoHashMap` iteration order is unspecified).
    /// Not consulted by rendering yet (a table paints its own cells once,
    /// at mutation time, not per frame -- see `Table.render`), but kept
    /// for a future "which table's border wins where two overlap" rule.
    table_order: std.ArrayList(TableHandle) = .empty,
    /// Whether this layer's size should follow the context's base size on
    /// a window resize -- true for the root layer and for any
    /// `create_layer` layer made without an explicit `width`/`height` (so
    /// it was already mirroring root's dimensions). A layer created at an
    /// explicit size (e.g. a 45x3 notification popup) keeps that size.
    /// See `Context.resize`.
    tracks_context_size: bool = false,

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, scrollback_rows: usize) !Layer {
        const total_rows = height + scrollback_rows;
        const buf = try alloc.alloc(Cell, width * total_rows);
        for (buf) |*c| c.* = .{};

        return .{
            .alloc = alloc,
            .width = width,
            .height = height,
            .tables = std.AutoHashMap(TableHandle, Table).init(alloc),
            .scrollback_rows = scrollback_rows,
            .buf = buf,
        };
    }

    pub fn deinit(self: *Layer) void {
        self.alloc.free(self.buf);
        var table_it = self.tables.valueIterator();
        while (table_it.next()) |t| t.deinit();
        self.tables.deinit();
        self.table_order.deinit(self.alloc);
    }

    pub fn capacity(self: *const Layer) usize {
        return self.height + self.scrollback_rows;
    }

    fn physicalRow(self: *const Layer, viewport_row: usize) usize {
        return (self.viewport_start + viewport_row) % self.capacity();
    }

    fn rowSlice(self: *const Layer, physical_row: usize) []Cell {
        const start = physical_row * self.width;
        return self.buf[start .. start + self.width];
    }

    pub fn cell(self: *const Layer, row: usize, col: usize) *Cell {
        return &self.rowSlice(self.physicalRow(row))[col];
    }

    /// Returns the row `rows_above_viewport` above the current viewport
    /// (0 = the row immediately above viewport row 0), or null if that
    /// much history hasn't been retained (either scrolled past
    /// `scrollback_rows` already, or never scrolled that far yet).
    pub fn scrollbackRow(self: *const Layer, rows_above_viewport: usize) ?[]const Cell {
        if (rows_above_viewport >= self.history_len) return null;
        const cap = self.capacity();
        const physical = (self.viewport_start + cap - 1 - rows_above_viewport) % cap;
        return self.rowSlice(physical);
    }

    /// Row of cells to display at viewport row `row` (0..height) when the
    /// on-screen view has been scrolled back by `offset` rows of history --
    /// `offset` 0 is the live viewport (same content `cell()` reads),
    /// `offset` `history_len` shows the oldest retained history at the top.
    /// This is display-only: it never touches `viewport_start` or
    /// `history_len` the way `scrollOne` does, so scrolling the view back
    /// to look at output doesn't disturb where new writes land.
    ///
    /// `offset` is clamped to `history_len` internally so a caller-tracked
    /// scroll position doesn't have to be re-clamped on every call (and
    /// can't read past what's actually retained even if it's stale).
    pub fn viewRow(self: *const Layer, offset: usize, row: usize) []const Cell {
        const clamped_offset = @min(offset, self.history_len);
        if (row < clamped_offset) {
            return self.scrollbackRow(clamped_offset - 1 - row).?;
        }
        return self.rowSlice(self.physicalRow(row - clamped_offset));
    }

    /// Scrolls the viewport down by one row: the current top row becomes
    /// history (evicting the oldest history row once `scrollback_rows`
    /// is full), and a fresh blank row appears at the bottom.
    fn scrollOne(self: *Layer) void {
        self.history_len = @min(self.history_len + 1, self.scrollback_rows);
        self.viewport_start = (self.viewport_start + 1) % self.capacity();
        for (self.rowSlice(self.physicalRow(self.height - 1))) |*c| c.* = .{};
    }

    /// Resolves an absolute row a caller named (an explicit
    /// `set_property(cursor)`, or `drawImage`/`drawBox`/`drawIcon`'s
    /// anchor row) against the current viewport, scrolling first if it's
    /// at or past the bottom -- the same rule `putAtCursor` already
    /// applies when text advances past the edge. Without this, a client
    /// tracking "the next row" itself (rather than reading the cursor
    /// back) drifts out of sync the moment a scroll happens: text written
    /// through the cursor self-corrects (via `putAtCursor`), but an
    /// explicit row handed to `draw_image`/`draw_icon` didn't -- it just
    /// silently landed past `self.height` and got clamped to nothing,
    /// which is exactly what made glyphwire-ls's icons quietly stop
    /// appearing after enough rows had scrolled by.
    ///
    /// A single explicit row can only ever be at most one row past the
    /// bottom in the intended use (mirroring one write's worth of
    /// advance), but this loops rather than assuming that, so a
    /// caller-supplied row far past the edge still resolves sanely
    /// instead of under-scrolling. Capped at `capacity()` iterations so a
    /// wildly out-of-range value (a hostile or buggy client) can't spin
    /// the server scrolling an unbounded number of times.
    fn resolveRow(self: *Layer, row: usize) usize {
        if (row < self.height) return row;
        const overshoot = @min(row - self.height + 1, self.capacity());
        var i: usize = 0;
        while (i < overshoot) : (i += 1) self.scrollOne();
        return self.height - 1;
    }

    /// Resizes the viewport to `new_width` x `new_height`, keeping
    /// `scrollback_rows` unchanged and anchoring content to the bottom
    /// (newest) row -- the model the host wants when its window is
    /// resized (`Context.resize` / `Server.reportResize`):
    ///
    /// - **Grow height:** rows that had scrolled off the top come back
    ///   down out of history into the now-taller viewport; blank filler
    ///   rows appear at the top only once history is exhausted.
    /// - **Shrink height:** the top rows are pushed up into history
    ///   rather than discarded, so a later grow brings them back. Only
    ///   rows that overflow the new `height + scrollback_rows` capacity
    ///   are evicted, oldest first -- the same eviction `scrollOne` does.
    /// - **Width:** each row is clipped (shrink) or blank-padded on the
    ///   right (grow). No reflow, matching `insertCells`/`deleteCells`'s
    ///   row-scoped model.
    ///
    /// The cursor is clamped back into the new bounds. A no-op if the
    /// size is unchanged. Rebuilds the ring buffer from scratch; the only
    /// failure mode is the new allocation itself.
    pub fn resize(self: *Layer, new_width: usize, new_height: usize) !void {
        std.debug.assert(new_width > 0 and new_height > 0);
        if (new_width == self.width and new_height == self.height) return;

        const old_cap = self.capacity();
        // Meaningful rows in oldest -> newest logical order: `history_len`
        // history rows followed by `height` viewport rows. `oldest_phys`
        // is the physical index of the first (oldest) one; logical row
        // `l` is physical `(oldest_phys + l) % old_cap`.
        const meaningful = self.history_len + self.height;
        const oldest_phys = (self.viewport_start + old_cap - self.history_len) % old_cap;

        const new_cap = new_height + self.scrollback_rows;
        const new_buf = try self.alloc.alloc(Cell, new_width * new_cap);
        for (new_buf) |*c| c.* = .{};

        // Keep the newest `keep` logical rows; anything older overflows
        // the new capacity and is dropped. The new buffer is laid out
        // un-wrapped -- history in physical rows [0, scrollback_rows),
        // viewport in [scrollback_rows, scrollback_rows + new_height) --
        // so the new `viewport_start` is just `scrollback_rows`.
        const keep = @min(meaningful, new_cap);
        const copy_w = @min(self.width, new_width);
        var kept: usize = 0;
        while (kept < keep) : (kept += 1) {
            const l = meaningful - keep + kept; // logical row, oldest kept first
            const src_phys = (oldest_phys + l) % old_cap;
            // Newest kept row (l == meaningful-1) lands on the last
            // viewport row; earlier rows fill upward from there.
            const dst_phys = self.scrollback_rows + new_height - keep + kept;
            const src_row = self.buf[src_phys * self.width ..][0..copy_w];
            const dst_row = new_buf[dst_phys * new_width ..][0..copy_w];
            @memcpy(dst_row, src_row);
        }

        self.alloc.free(self.buf);
        self.buf = new_buf;
        self.width = new_width;
        self.height = new_height;
        self.viewport_start = self.scrollback_rows;
        self.history_len = if (keep > new_height) keep - new_height else 0;

        if (self.cursor.row >= new_height) self.cursor.row = new_height - 1;
        if (self.cursor.col >= new_width) self.cursor.col = new_width - 1;
    }

    /// Appends `text` as grapheme clusters starting at the layer's cursor,
    /// advancing and wrapping it at the layer edge. Naive UTF-8 codepoint
    /// splitting for now, not real grapheme segmentation (UAX #29) — see
    /// decisions.md; swapping in the real thing later shouldn't change this
    /// shape. `bg` is `null` for "leave whatever background is already on
    /// each cell touched" (`write_text`'s `transparent_bg: true`) rather
    /// than resetting it to `default_style.bg` -- see that field's doc
    /// comment on `WriteTextParams` for why this needed splitting `fg`/`bg`
    /// out of a single `Style` value instead of just making `Style.bg`
    /// itself optional (`Cell.style` still always holds a concrete,
    /// resolved `Style` -- only the *write* can decline to touch it).
    pub fn writeText(self: *Layer, text: []const u8, fg: Color, bg: ?Background) !void {
        return self.writeTextTagged(text, fg, bg, null);
    }

    /// Same as `writeText`, but every cell the text touches also gets
    /// tagged with `metadata_id` (see `Cell.metadata_id`'s doc comment) --
    /// a separate method rather than a new required param on `writeText`
    /// itself since Zig has no default parameter values, matching this
    /// codebase's existing convention for additive options (`drawIcon`'s
    /// `IconDrawOpts`).
    pub fn writeTextTagged(self: *Layer, text: []const u8, fg: Color, bg: ?Background, metadata_id: ?MetadataHandle) !void {
        const view = try std.unicode.Utf8View.init(text);
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp_bytes| {
            self.putAtCursor(cp_bytes, fg, bg, metadata_id);
        }
        self.revision += 1;
    }

    fn putAtCursor(self: *Layer, bytes: []const u8, fg: Color, bg: ?Background, metadata_id: ?MetadataHandle) void {
        if (self.cursor.col >= self.width) {
            self.cursor.col = 0;
            self.cursor.row += 1;
        }
        self.cursor.row = self.resolveRow(self.cursor.row);

        var c = self.cell(self.cursor.row, self.cursor.col);
        c.setGrapheme(bytes);
        c.style.fg = fg;
        if (bg) |b| c.style.bg = b;
        c.metadata_id = metadata_id;
        self.cursor.col += 1;
    }

    /// Shifts cells at and after the cursor's column rightward by `count`
    /// within the cursor's row, opening `count` blank cells at the cursor
    /// -- ECMA-48's ICH (Insert Character), the primitive a line editor
    /// needs to insert into already-drawn text without retransmitting
    /// everything after the insertion point. Cells shifted past the row's
    /// right edge are discarded, matching ICH. Doesn't move the cursor or
    /// touch other rows -- a caller editing a display-wrapped logical line
    /// would need to call this per physical row itself. `count` is
    /// clamped to the cells remaining in the row; a cursor already at or
    /// past the row's right edge is a no-op.
    pub fn insertCells(self: *Layer, count: usize) void {
        if (count == 0 or self.cursor.col >= self.width) return;
        const row = self.rowSlice(self.physicalRow(self.cursor.row));
        const col = self.cursor.col;
        const n = @min(count, self.width - col);
        const tail_len = self.width - col - n;
        std.mem.copyBackwards(Cell, row[col + n ..][0..tail_len], row[col..][0..tail_len]);
        for (row[col..][0..n]) |*c| c.* = .{};
        self.revision += 1;
    }

    /// Removes `count` cells at and after the cursor's column, shifting
    /// the row's remainder leftward and filling `count` blank cells at
    /// the row's tail -- ECMA-48's DCH (Delete Character), the mirror of
    /// `insertCells`. Doesn't move the cursor. `count` is clamped to the
    /// cells remaining in the row; a cursor already at or past the row's
    /// right edge is a no-op.
    pub fn deleteCells(self: *Layer, count: usize) void {
        if (count == 0 or self.cursor.col >= self.width) return;
        const row = self.rowSlice(self.physicalRow(self.cursor.row));
        const col = self.cursor.col;
        const n = @min(count, self.width - col);
        const tail_len = self.width - col - n;
        std.mem.copyForwards(Cell, row[col..][0..tail_len], row[col + n ..][0..tail_len]);
        for (row[col + tail_len ..][0..n]) |*c| c.* = .{};
        self.revision += 1;
    }

    /// Marks cells in `[row, row+row_span) x [col, col+col_span)` (clamped
    /// to the layer's own bounds) as backed by `handle`'s pixels, anchored
    /// at `(row, col)` with **no stretching** -- see decisions.md's Image
    /// section. Each covered cell gets the pixel offset into the source
    /// image it should display, computed from its position relative to the
    /// anchor; `img_w`/`img_h` are the image's natural pixel dimensions
    /// (from `pngDimensions`), `cell_px_w`/`cell_px_h` the session's fixed
    /// cell pixel metrics (`Context.cell_px_w`/`cell_px_h`).
    ///
    /// A cell the image doesn't actually reach -- its computed offset
    /// falls at or past the image's own edge, i.e. the image is smaller
    /// than the requested span -- is left untouched rather than blanked,
    /// so drawing a small image over existing content only overwrites what
    /// the image actually covers. Cells the image *does* reach always get
    /// marked, even where the image only partially fills them at the
    /// image's bottom/right edge -- the renderer clips those, not this.
    pub fn drawImage(
        self: *Layer,
        handle: ImageHandle,
        row: usize,
        col: usize,
        row_span: usize,
        col_span: usize,
        img_w: u32,
        img_h: u32,
        cell_px_w: u32,
        cell_px_h: u32,
    ) void {
        const anchor_row = self.resolveRow(row);
        const row_end = @min(anchor_row + row_span, self.height);
        const col_end = @min(col + col_span, self.width);

        var r = anchor_row;
        while (r < row_end) : (r += 1) {
            const offset_y = @as(u32, @intCast(r - anchor_row)) * cell_px_h;
            if (offset_y >= img_h) continue;

            var c = col;
            while (c < col_end) : (c += 1) {
                const offset_x = @as(u32, @intCast(c - col)) * cell_px_w;
                if (offset_x >= img_w) continue;

                self.setCellImage(r, c, handle, offset_x, offset_y);
            }
        }
        self.revision += 1;
    }

    fn setCellImage(self: *Layer, row: usize, col: usize, handle: ImageHandle, offset_x: u32, offset_y: u32) void {
        self.cell(row, col).style.bg = .{ .image = .{ .handle = handle, .offset_x = offset_x, .offset_y = offset_y } };
    }

    /// `scale`/`h_align`/`v_align` default to the original fit-and-center
    /// behavior -- see `IconBg`'s doc comment.
    pub const IconDrawOpts = struct {
        scale: IconScale = .fit,
        h_align: HAlign = .center,
        v_align: VAlign = .center,
        max_w: ?u32 = null,
        max_h: ?u32 = null,
        /// See `Cell.metadata_id`'s doc comment.
        metadata_id: ?MetadataHandle = null,
    };

    /// Marks exactly one cell as backed by `handle`, resolved server-side
    /// by name against the icon catalog (`Context.iconHandle`) --
    /// dispatch.zig's job, not this method's. Still just one anchor cell
    /// even when `opts.scale == .natural` overflows beyond it -- see
    /// `IconBg`'s doc comment for why the overflow isn't tracked here.
    pub fn drawIcon(self: *Layer, handle: ImageHandle, row: usize, col: usize, opts: IconDrawOpts) void {
        const resolved_row = self.resolveRow(row);
        if (col >= self.width) return;
        const c = self.cell(resolved_row, col);
        c.style.bg = .{ .icon = .{
            .handle = handle,
            .scale = opts.scale,
            .h_align = opts.h_align,
            .v_align = opts.v_align,
            .max_w = opts.max_w,
            .max_h = opts.max_h,
        } };
        c.metadata_id = opts.metadata_id;
        self.revision += 1;
    }

    /// Same as `drawIcon`, but sets `Cell.fg_icon` instead of `style.bg`
    /// -- see that field's doc comment. Leaves `style.bg` (and whatever
    /// background is already there, e.g. a `drawBox` fill) untouched, so
    /// the host's render pass draws this icon over it rather than instead
    /// of it.
    pub fn drawIconOver(self: *Layer, handle: ImageHandle, row: usize, col: usize, opts: IconDrawOpts) void {
        const resolved_row = self.resolveRow(row);
        if (col >= self.width) return;
        const c = self.cell(resolved_row, col);
        c.fg_icon = .{
            .handle = handle,
            .scale = opts.scale,
            .h_align = opts.h_align,
            .v_align = opts.v_align,
            .max_w = opts.max_w,
            .max_h = opts.max_h,
        };
        c.metadata_id = opts.metadata_id;
        self.revision += 1;
    }

    /// `tag_metadata`: sets exactly one cell's `metadata_id`, touching
    /// nothing else -- unlike `writeTextTagged`/`drawIcon`, which tag as a
    /// side effect of also drawing something. For a client that needs to
    /// tag a cell without changing what's drawn there, e.g. `glyphwire-ls`
    /// tagging the extra cells a `.natural`-scaled icon visually overflows
    /// into (see `IconScale`'s doc comment on that overflow having no
    /// automatic data-model footprint -- this is how a client opts into
    /// giving it one anyway, deliberately, cell by cell).
    pub fn tagMetadata(self: *Layer, row: usize, col: usize, metadata_id: ?MetadataHandle) void {
        const resolved_row = self.resolveRow(row);
        if (col >= self.width) return;
        self.cell(resolved_row, col).metadata_id = metadata_id;
        self.revision += 1;
    }

    /// The 9 resolved tiles a `draw_box` call needs -- corners, edges, and
    /// a fill, per decisions.md's Icon section / roadmap.md's Phase 3.6.
    /// Just handles, same as `draw_icon`: each tile is drawn with the
    /// `.icon` Background variant (`scale: .stretch` -- see `IconScale`'s
    /// doc comment for why tiles stretch to fill their cell exactly rather
    /// than `drawIcon`'s default aspect-preserved `fit`), not `.image`'s
    /// clip-and-offset scheme, so there's no per-tile width/height to
    /// carry here either. Resolving these (by
    /// `"{style}-tl"` etc. against the icon catalog) is dispatch.zig's
    /// job; `Layer.drawBox` just consumes the result, so it's testable
    /// headlessly without going through name resolution.
    pub const BoxTiles = struct {
        tl: ImageHandle,
        t: ImageHandle,
        tr: ImageHandle,
        l: ImageHandle,
        fill: ImageHandle,
        r: ImageHandle,
        bl: ImageHandle,
        b: ImageHandle,
        br: ImageHandle,
    };

    /// How `drawBox` composes its 9 tiles across a rectangle bigger than
    /// 3x3 cells:
    /// - `tile` (the original, still-default behavior): every cell gets
    ///   one full copy of its role's tile, independently stretched to fill
    ///   just that cell -- fine for a border/fill that's meant to repeat,
    ///   but a repeated slice of a gradient image bands rather than fades.
    /// - `stretch`: corners are still one full tile each (they're always
    ///   exactly one cell), but each edge/fill role's *single* source
    ///   image is treated as one continuous picture spanning the whole
    ///   run it appears in -- `t`/`b` across every interior column,
    ///   `l`/`r` across every interior row, `fill` across the whole
    ///   interior rectangle -- so a cell partway along the run gets that
    ///   fraction of the image (`IconBg.src_l/src_t/src_r/src_b`)
    ///   stretched to fill it, reassembling into one smooth image (e.g. a
    ///   top-to-bottom gradient) across however many cells the box turns
    ///   out to span.
    pub const BoxMode = enum { tile, stretch };

    /// Draws a `rows x cols` box anchored at `(row, col)` (clamped to the
    /// layer's own bounds) using `tiles`: each cell gets exactly one tile,
    /// chosen by whether it's on the box's top/bottom row and/or
    /// left/right column, stretched to fill that cell exactly (`IconScale`'s
    /// `.stretch`). The bundled tile art is drawn with its border line
    /// hugging the tile's own outer edge rather than centered, so a
    /// caller can still put a character in a border cell (`write_text`
    /// only touches `Cell.grapheme`/`fg`, independent of `bg`) without it
    /// colliding with the line -- see decisions.md's Icon section on why
    /// `draw_box` gets this treatment now, same as icons. A 1x1 or
    /// 1xN/Nx1 box collapses reasonably: the top/left role is checked
    /// before bottom/right, so a single-row or single-column box shows
    /// corners/top/left tiles rather than picking arbitrarily.
    pub fn drawBox(
        self: *Layer,
        tiles: BoxTiles,
        mode: BoxMode,
        row: usize,
        col: usize,
        rows: usize,
        cols: usize,
    ) void {
        if (rows == 0 or cols == 0) return;

        const anchor_row = self.resolveRow(row);
        const row_end = @min(anchor_row + rows, self.height);
        const col_end = @min(col + cols, self.width);
        const last_row = anchor_row + rows - 1;
        const last_col = col + cols - 1;

        // Interior span sizes, for `.stretch`'s per-cell fractions below --
        // only ever consulted by a branch reached when there's at least
        // one interior row/col on that axis (see the branches' comments),
        // so this never divides by 0 despite looking unguarded.
        const interior_h: f32 = @floatFromInt(last_col -| col -| 1);
        const interior_v: f32 = @floatFromInt(last_row -| anchor_row -| 1);

        var r = anchor_row;
        while (r < row_end) : (r += 1) {
            const is_top = r == anchor_row;
            const is_bottom = r == last_row;
            const v_index: f32 = @floatFromInt(r - anchor_row -| 1);

            var c = col;
            while (c < col_end) : (c += 1) {
                const is_left = c == col;
                const is_right = c == last_col;
                const h_index: f32 = @floatFromInt(c - col -| 1);
                const is_corner = (is_top or is_bottom) and (is_left or is_right);

                const tile = if (is_top and is_left)
                    tiles.tl
                else if (is_top and is_right)
                    tiles.tr
                else if (is_bottom and is_left)
                    tiles.bl
                else if (is_bottom and is_right)
                    tiles.br
                else if (is_top)
                    tiles.t
                else if (is_bottom)
                    tiles.b
                else if (is_left)
                    tiles.l
                else if (is_right)
                    tiles.r
                else
                    tiles.fill;

                // A corner is always exactly one cell, so it never gets
                // sliced regardless of mode. `t`/`b` (reached only when
                // not a corner, i.e. `interior_h >= 1`) slice horizontally;
                // `l`/`r` (only reached when `interior_v >= 1`) slice
                // vertically; `fill` (only reached when both are `>= 1`)
                // slices both.
                const src: [4]f32 = if (mode == .tile or is_corner)
                    .{ 0, 0, 1, 1 }
                else if (is_top or is_bottom)
                    .{ h_index / interior_h, 0, (h_index + 1) / interior_h, 1 }
                else if (is_left or is_right)
                    .{ 0, v_index / interior_v, 1, (v_index + 1) / interior_v }
                else
                    .{ h_index / interior_h, v_index / interior_v, (h_index + 1) / interior_h, (v_index + 1) / interior_v };

                self.cell(r, c).style.bg = .{ .icon = .{
                    .handle = tile,
                    .scale = .stretch,
                    .src_l = src[0],
                    .src_t = src[1],
                    .src_r = src[2],
                    .src_b = src[3],
                } };
            }
        }
        self.revision += 1;
    }

    /// Resets cells in `[row, row+rows) x [col, col+cols)` (clamped to the
    /// layer's own bounds) back to a blank cell -- empty grapheme, default
    /// style, no image background -- the same zero value `Layer.init`
    /// leaves every cell in. A no-op if the region is empty (`rows`/`cols`
    /// 0) or `row`/`col` is already past the layer's edge. Doesn't touch
    /// the cursor -- a caller wanting "clear and home the cursor" (a real
    /// terminal's `clear`/ctrl+l) does that itself via `set_property`.
    pub fn clear(self: *Layer, row: usize, col: usize, rows: usize, cols: usize) void {
        if (row >= self.height or col >= self.width or rows == 0 or cols == 0) return;

        const row_end = @min(row + rows, self.height);
        const col_end = @min(col + cols, self.width);

        var r = row;
        while (r < row_end) : (r += 1) {
            for (self.rowSlice(self.physicalRow(r))[col..col_end]) |*cell_ptr| cell_ptr.* = .{};
        }
        self.revision += 1;
    }

    pub fn getProperty(self: *const Layer, name: PropertyName) PropertyValue {
        return switch (name) {
            .cursor => .{ .cursor = self.cursor },
            .revision => .{ .revision = self.revision },
            .position => .{ .position = self.pos },
            .size => .{ .size = .{ .cols = self.width, .rows = self.height } },
        };
    }

    pub fn setProperty(self: *Layer, value: PropertyValue) void {
        switch (value) {
            .cursor => |c| self.cursor = .{ .row = self.resolveRow(c.row), .col = c.col },
            .revision => unreachable, // get-only; see PropertyName.revision
            .position => |p| self.pos = p,
            .size => unreachable, // get-only; window size is host-driven, see Context.resize
        }
    }
};

// ─── Table ───────────────────────────────────────────────────────────────
//
// A table is structured, server-owned data (columns, rows of typed cells,
// sort state, style) that *compiles* into ordinary cells on its owning
// layer whenever it changes -- not a live per-frame render path of its
// own. This is the whole reason adding tables needed no changes to
// glyphwire-host's render loop at all: that loop already draws whatever's
// sitting in a layer's cell buffer, regardless of what put it there
// (`write_text`, `draw_icon`, or now `Table.render`). It's also why a
// table survives the process that created it (e.g. `glyphwire-ls -l`)
// exiting, and why re-sorting later is just re-deriving row order from
// the same stored typed values and repainting -- no client needs to be
// running for either.
//
// A table is a component of the layer it's drawn on (`Layer.tables`),
// not a parallel object tree the way `Layer` itself is under `Context` --
// see decisions.md's Table section.

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

pub const SortDirection = enum { none, ascending, descending };

/// One column's shape -- display name (the header cell's text),
/// sortability, and sizing. `width` is the column's content width in
/// cells; `min_width` is a floor, same as the client-composited table
/// prototype's `ColumnDef` (`src/table.zig`, which this supersedes as
/// the source of table layout -- see decisions.md's Table section).
pub const TableColumn = struct {
    name: []u8,
    kind: ColumnKind = .text,
    sortable: bool = false,
    width: usize,
    min_width: usize = 1,
    h_align: HAlign = .start,

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

    pub fn deinit(self: TableStyle, alloc: std.mem.Allocator) void {
        alloc.free(self.box_style);
    }
};

/// Where a table last painted -- used to blank that whole region before
/// repainting a possibly-smaller one (fewer rows, a narrower style, ...)
/// so a shrinking table doesn't leave stale cells behind past its new
/// content's edge.
const TablePaintedExtent = struct {
    row: usize = 0,
    col: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
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
    painted: TablePaintedExtent = .{},

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

    /// `table_set_style`: takes ownership of `new_style` the same way
    /// `init` takes its `style` param, freeing the previous one first.
    pub fn setStyle(self: *Table, new_style: TableStyle) void {
        self.style.deinit(self.alloc);
        self.style = new_style;
    }

    /// Row indices in current display order: identity order (`0, 1, 2,
    /// ...`) when unsorted or `sort_column` is out of range, otherwise
    /// sorted on that column's `SortKey` (`.text` lexically, `.number`
    /// numerically -- comparing a `.text` key against a `.number` one,
    /// which shouldn't happen since a column's cells are all built the
    /// same way by whatever sent `table_set_rows`, treats them as equal
    /// rather than erroring). Caller-owned, freed by the caller.
    pub fn sortedIndices(self: *const Table, alloc: std.mem.Allocator) ![]usize {
        const indices = try alloc.alloc(usize, self.rows.len);
        for (indices, 0..) |*idx, i| idx.* = i;

        const col = self.sort_column orelse return indices;
        if (self.sort_dir == .none or col >= self.columns.len) return indices;

        const SortCtx = struct {
            rows: []const TableRow,
            col: usize,
            ascending: bool,

            fn order(ctx: @This(), a: usize, b: usize) std.math.Order {
                const ka = ctx.rows[a].cells[ctx.col].sort_key;
                const kb = ctx.rows[b].cells[ctx.col].sort_key;
                return switch (ka) {
                    .text => |ta| switch (kb) {
                        .text => |tb| std.mem.order(u8, ta, tb),
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
    /// Scrolls the layer first if the table's full height wouldn't
    /// otherwise fit below `self.row` -- a table drawn as a command's
    /// output (`glyphwire-ls -l`, printed wherever the shell's prompt
    /// happened to leave the cursor, not necessarily near the top of the
    /// screen) needs the same "make room for new output" behavior a real
    /// terminal gives any other command, or most of it silently never
    /// becomes visible at all. Resolved via `Layer.resolveRow` against
    /// the table's *bottom* row (`self.row + total_height - 1`), then
    /// walked back to get the new top -- exactly once per `render` call,
    /// not once per cell/tile the way the client-composited prototype
    /// this replaced first got wrong (see its own historical bug: `resolveRow`
    /// scrolls *relative to whatever's currently at the top* on every
    /// out-of-bounds call, so resolving the same block's rows
    /// independently, one cell at a time, compounds into runaway extra
    /// scrolling). One resolution up front avoids that entirely.
    ///
    /// Writes every cell directly (`layer.cell(r, c)`) after that,
    /// **not** through `Layer.writeText`/`drawIcon`'s cursor-implicit
    /// helpers -- this method already did the one scroll resolution a
    /// table needs itself, so nothing past this point should trigger
    /// another. Horizontal overflow still just clips (`self.col` never
    /// moves) -- there's no horizontal-scroll concept for a cell grid,
    /// same as `drawBox`/`drawImage` clamping their own rectangles to the
    /// layer's width.
    pub fn render(self: *Table, layer: *Layer, ctx: *const Context) !void {
        clearExtent(layer, self.painted);

        var content_width: usize = 0;
        for (self.columns, 0..) |column, i| {
            if (i > 0) content_width += 1;
            content_width += @max(column.width, column.min_width);
        }
        const border_pad: usize = if (self.style.borders) 1 else 0;
        const row_height = @max(self.style.row_height, 1);
        const separator_lines: usize = if (self.style.header_separator) 1 else 0;
        const total_height = border_pad + 1 + separator_lines + self.rows.len * row_height + border_pad;
        if (total_height > 0) {
            const bottom = self.row + total_height - 1;
            const resolved_bottom = layer.resolveRow(bottom);
            // Saturating, not plain, subtraction: `resolveRow` only ever
            // scrolls up to `layer.capacity()` times (its own overshoot
            // cap), so `resolved_bottom` can land smaller than
            // `total_height - 1` when the table's own height exceeds the
            // whole layer (more rows than the viewport, or than there's
            // scrollback to hold) -- a plain `-` there panics on the
            // underflow. Saturating to 0 in that case just anchors the
            // table at the very top, same "show as much as will ever
            // fit" degradation `resolveRow` itself already accepts by
            // capping its own scroll count.
            self.row = resolved_bottom -| (total_height - 1);
        }

        const content_start_col = self.col + border_pad;
        var cur_row = self.row;

        if (self.style.borders) {
            self.drawBorderEdge(layer, ctx, cur_row, content_width, .top);
            cur_row += 1;
        }

        self.writeHeaderRow(layer, cur_row, content_start_col);
        if (self.style.borders) self.drawSideBorders(layer, ctx, cur_row, content_width);
        cur_row += 1;

        if (self.style.header_separator) {
            self.drawSeparatorRow(layer, ctx, cur_row, content_start_col, content_width);
            cur_row += 1;
        }

        const indices = try self.sortedIndices(self.alloc);
        defer self.alloc.free(indices);

        for (indices, 0..) |row_idx, display_i| {
            const row_bg = if (self.style.alt_row_bg != null and display_i % 2 == 1) self.style.alt_row_bg else null;
            if (row_bg) |bg| fillRowBg(layer, cur_row, content_start_col, content_width, row_height, bg);
            if (self.style.borders) {
                var line: usize = 0;
                while (line < row_height) : (line += 1) self.drawSideBorders(layer, ctx, cur_row + line, content_width);
            }
            self.writeBodyRow(layer, ctx, self.rows[row_idx], cur_row, content_start_col, row_height, row_bg);
            cur_row += row_height;
        }

        if (self.style.borders) {
            self.drawBorderEdge(layer, ctx, cur_row, content_width, .bottom);
            cur_row += 1;
        }

        self.painted = .{
            .row = self.row,
            .col = self.col,
            .rows = cur_row - self.row,
            .cols = content_width + 2 * border_pad,
        };
        self.revision += 1;
    }

    fn writeHeaderRow(self: *const Table, layer: *Layer, row: usize, content_start_col: usize) void {
        var col = content_start_col;
        for (self.columns, 0..) |column, i| {
            if (i > 0) {
                writeCellRun(layer, row, col, "", 1, .start, self.style.header_fg orelse default_style.fg, self.style.header_bg, null);
                col += 1;
            }
            const width = @max(column.width, column.min_width);
            writeCellRun(layer, row, col, column.name, width, column.h_align, self.style.header_fg orelse default_style.fg, self.style.header_bg, null);
            col += width;
        }
    }

    /// One column's icon (if any) plus display text, on the row block's
    /// middle line (`top_row + row_height / 2` -- `row_height == 1`
    /// lands on the block's only line). An icon reserves enough leading
    /// columns that the text after it doesn't collide: exactly 1 cell at
    /// `row_height == 1` (`.fit`-scaled to fill it), or -- for a
    /// `row_height > 1` "large format" row -- enough columns to fit the
    /// icon's own natural pixel width (`ctx.imageInfo`, read from the
    /// actually-loaded image rather than a hardcoded constant, unlike
    /// the client-composited prototype's fixed `icon_native_px`),
    /// `.natural`-scaled and capped to `row_height` cell-heights tall,
    /// same as `writeGrid`'s icons in glyphwire-ls's non-table listing.
    ///
    /// The icon goes into `Cell.fg_icon` (`setCellIconOver`), not
    /// `style.bg` -- it composites *over* the row's background rather than
    /// replacing it, so an `alt_row_bg` stripe stays unbroken behind the
    /// icon cell and a `.natural`-scaled icon that overflows into
    /// neighboring rows/columns paints over their backgrounds too. See
    /// `setCellIconOver`'s doc comment.
    fn writeBodyRow(self: *const Table, layer: *Layer, ctx: *const Context, row: TableRow, top_row: usize, content_start_col: usize, row_height: usize, row_bg: ?Color) void {
        const mid_row = top_row + row_height / 2;
        var col = content_start_col;
        for (self.columns, 0..) |column, i| {
            const width = @max(column.width, column.min_width);
            const cell = row.cells[i];
            var icon_reserve: usize = 0;

            if (cell.icon) |icon_handle| {
                if (row_height > 1) {
                    const info = ctx.imageInfo(icon_handle) orelse ImageInfo{ .width = 0, .height = 0 };
                    const max_h: u32 = @intCast(row_height * ctx.cell_px_h);
                    const render_px = @min(info.width, max_h);
                    icon_reserve = if (ctx.cell_px_w > 0) (render_px + ctx.cell_px_w - 1) / ctx.cell_px_w + 1 else 1;
                    setCellIconOver(layer, mid_row, col, icon_handle, .natural, .start, .center, max_h, cell.metadata_id);
                } else {
                    icon_reserve = 1;
                    setCellIconOver(layer, mid_row, col, icon_handle, .fit, .center, .center, null, cell.metadata_id);
                }
            }

            const text_col = col + icon_reserve;
            const text_width = width -| icon_reserve;
            const fg = cell.fg orelse default_style.fg;
            writeCellRun(layer, mid_row, text_col, cell.display, text_width, column.h_align, fg, row_bg, cell.metadata_id);

            col += width + 1;
        }
    }

    fn drawBorderEdge(self: *const Table, layer: *Layer, ctx: *const Context, row: usize, content_width: usize, edge: enum { top, bottom }) void {
        const corner_l = if (edge == .top) "tl" else "bl";
        const mid = if (edge == .top) "t" else "b";
        const corner_r = if (edge == .top) "tr" else "br";
        const total_width = content_width + 2;

        drawBorderTile(layer, ctx, row, self.col, self.style.box_style, corner_l);
        var c = self.col + 1;
        while (c < self.col + total_width - 1) : (c += 1) drawBorderTile(layer, ctx, row, c, self.style.box_style, mid);
        drawBorderTile(layer, ctx, row, self.col + total_width - 1, self.style.box_style, corner_r);
    }

    fn drawSideBorders(self: *const Table, layer: *Layer, ctx: *const Context, row: usize, content_width: usize) void {
        drawBorderTile(layer, ctx, row, self.col, self.style.box_style, "l");
        drawBorderTile(layer, ctx, row, self.col + content_width + 1, self.style.box_style, "r");
    }

    fn drawSeparatorRow(self: *const Table, layer: *Layer, ctx: *const Context, row: usize, content_start_col: usize, content_width: usize) void {
        if (self.style.borders) drawBorderTile(layer, ctx, row, self.col, self.style.box_style, "l");
        var c = content_start_col;
        while (c < content_start_col + content_width) : (c += 1) drawBorderTile(layer, ctx, row, c, self.style.box_style, "t");
        if (self.style.borders) drawBorderTile(layer, ctx, row, self.col + content_width + 1, self.style.box_style, "r");
    }
};

fn clearExtent(layer: *Layer, extent: TablePaintedExtent) void {
    if (extent.rows == 0 or extent.cols == 0) return;
    layer.clear(extent.row, extent.col, extent.rows, extent.cols);
}

fn setCellText(layer: *Layer, row: usize, col: usize, grapheme: []const u8, fg: Color, bg: ?Color, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or col >= layer.width) return;
    const c = layer.cell(row, col);
    c.setGrapheme(grapheme);
    c.style.fg = fg;
    c.style.bg = if (bg) |b| .{ .color = b } else default_style.bg;
    c.metadata_id = metadata_id;
}

fn setCellIcon(layer: *Layer, row: usize, col: usize, handle: ImageHandle, scale: IconScale, h_align: HAlign, v_align: VAlign, max_h: ?u32, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or col >= layer.width) return;
    const c = layer.cell(row, col);
    c.style.bg = .{ .icon = .{ .handle = handle, .scale = scale, .h_align = h_align, .v_align = v_align, .max_h = max_h } };
    c.metadata_id = metadata_id;
}

/// Like `setCellIcon`, but writes the icon into `Cell.fg_icon` instead of
/// `style.bg` -- see that field's doc comment. Leaves whatever background
/// the cell already carries (a `fillRowBg` `alt_row_bg` stripe, or the
/// default) in place, so `glyphwire-host`'s render pass composites the
/// icon *over* it rather than replacing it. Table body icons always take
/// this path: an icon should sit above its row's background, and a
/// `.natural`-scaled one that overflows past its anchor cell has to paint
/// over the neighboring rows'/columns' backgrounds too -- the host defers
/// `.natural` `fg_icon`s past the whole grid for exactly that, the same
/// way it already does for `style.bg`'s `.icon` overflow.
fn setCellIconOver(layer: *Layer, row: usize, col: usize, handle: ImageHandle, scale: IconScale, h_align: HAlign, v_align: VAlign, max_h: ?u32, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or col >= layer.width) return;
    const c = layer.cell(row, col);
    c.fg_icon = .{ .handle = handle, .scale = scale, .h_align = h_align, .v_align = v_align, .max_h = max_h };
    c.metadata_id = metadata_id;
}

fn fillRowBg(layer: *Layer, top_row: usize, content_start_col: usize, content_width: usize, row_height: usize, bg: Color) void {
    var line: usize = 0;
    while (line < row_height) : (line += 1) {
        const r = top_row + line;
        if (r >= layer.height) break;
        var c = content_start_col;
        const end = @min(content_start_col + content_width, layer.width);
        while (c < end) : (c += 1) setCellText(layer, r, c, "", default_style.fg, bg, null);
    }
}

fn borderTileHandle(ctx: *const Context, box_style: []const u8, piece: []const u8, name_buf: []u8) ?ImageHandle {
    const name = std.fmt.bufPrint(name_buf, "{s}-{s}", .{ box_style, piece }) catch return null;
    return ctx.iconHandle(name);
}

fn drawBorderTile(layer: *Layer, ctx: *const Context, row: usize, col: usize, box_style: []const u8, piece: []const u8) void {
    var buf: [64]u8 = undefined;
    const handle = borderTileHandle(ctx, box_style, piece, &buf) orelse return;
    setCellIcon(layer, row, col, handle, .stretch, .center, .center, null, null);
}

/// Writes `text`'s codepoints into `layer` starting at `(row, col)`,
/// truncated (with a trailing "…", keeping the first `width - 1`
/// codepoints) if longer than `width` cells, or left/center/right-padded
/// with spaces (per `h_align`) if shorter -- same shape the
/// client-composited table prototype's `formatCell` had, just writing
/// straight into cells instead of building an intermediate string first.
/// Clipped to the layer's own bounds and to `width` cells -- a column
/// that runs off the layer's right edge just loses its tail, matching
/// `Table.render`'s "clip, don't scroll" doc comment. A no-op if `width`
/// is 0 (e.g. an icon already claimed the column's whole reserved width).
fn writeCellRun(layer: *Layer, row: usize, col: usize, text: []const u8, width: usize, h_align: HAlign, fg: Color, bg: ?Color, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or width == 0 or col >= layer.width) return;
    const end_col = @min(col + width, layer.width);

    const text_width = std.unicode.utf8CountCodepoints(text) catch text.len;
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
    n = 0;
    while (n < keep and c < end_col) : (n += 1) {
        const cp = it.nextCodepointSlice() orelse break;
        setCellText(layer, row, c, cp, fg, bg, metadata_id);
        c += 1;
    }

    if (truncate and c < end_col) {
        setCellText(layer, row, c, "\u{2026}", fg, bg, metadata_id);
        c += 1;
    }

    while (c < end_col) : (c += 1) setCellText(layer, row, c, " ", fg, bg, metadata_id);
}

/// Pixel-space cursor position (framebuffer pixels, as glyphwire-host
/// reports it).
pub const PxPos = struct { x: f32 = 0, y: f32 = 0 };

/// Cell-grid cursor position, derived from `PxPos` and the cell pixel
/// size -- see decisions.md's Cell/Layer sections. Whoever reports it
/// (glyphwire-host, which owns the font/cell metrics) computes this, not
/// the headless server -- see `InputState`'s doc comment.
pub const CellPos = struct { row: usize = 0, col: usize = 0 };

/// Authoritative input state for a session: which keys/mouse buttons are
/// currently down, and the last known cursor position. Belongs on
/// `Context` rather than `Layer` since it's session-wide, not tied to any
/// one layer's cell content -- see decisions.md's Object Model.
///
/// Pure logic, no I/O, headless-testable like everything else in this
/// file: the actual GLFW capture happens in glyphwire-host, which reports
/// changes here as `report_key`/`report_mouse_button`/`report_mouse_move`
/// notifications (see dispatch.zig, or `Server`'s in-process equivalents
/// for a caller that owns the `Context` directly) rather than this type
/// knowing anything about how input was captured.
///
/// Key/button names are whatever string the reporter used (glyphwire-host
/// uses `@tagName` of pixzig's GLFW-backed key/button enums, e.g. "a",
/// "left_shift", "left") -- not a closed set enforced here.
pub const InputState = struct {
    alloc: std.mem.Allocator,
    keys_down: std.StringHashMap(void),
    mouse_buttons_down: std.StringHashMap(void),
    cursor_px: PxPos = .{},
    cursor_cell: CellPos = .{},

    pub fn init(alloc: std.mem.Allocator) InputState {
        return .{
            .alloc = alloc,
            .keys_down = std.StringHashMap(void).init(alloc),
            .mouse_buttons_down = std.StringHashMap(void).init(alloc),
        };
    }

    pub fn deinit(self: *InputState) void {
        freeStringSet(self.alloc, &self.keys_down);
        freeStringSet(self.alloc, &self.mouse_buttons_down);
    }

    fn freeStringSet(alloc: std.mem.Allocator, set: *std.StringHashMap(void)) void {
        var it = set.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        set.deinit();
    }

    /// Records a key press/release. Returns true if this actually changed
    /// the down-set (false for a redundant press-while-down or
    /// release-while-up report), so callers can skip broadcasting a
    /// no-op change.
    pub fn setKey(self: *InputState, key: []const u8, down: bool) !bool {
        return setInSet(self.alloc, &self.keys_down, key, down);
    }

    pub fn setMouseButton(self: *InputState, button: []const u8, down: bool) !bool {
        return setInSet(self.alloc, &self.mouse_buttons_down, button, down);
    }

    fn setInSet(alloc: std.mem.Allocator, set: *std.StringHashMap(void), name: []const u8, down: bool) !bool {
        if (down) {
            if (set.contains(name)) return false;
            const owned = try alloc.dupe(u8, name);
            errdefer alloc.free(owned);
            try set.put(owned, {});
            return true;
        } else {
            if (set.fetchRemove(name)) |kv| {
                alloc.free(kv.key);
                return true;
            }
            return false;
        }
    }

    pub fn isKeyDown(self: *const InputState, key: []const u8) bool {
        return self.keys_down.contains(key);
    }

    pub fn isMouseButtonDown(self: *const InputState, button: []const u8) bool {
        return self.mouse_buttons_down.contains(button);
    }
};

/// Fixed id for the single auto-created context this slice's server ever
/// has. There's no `create_context` yet (decisions.md, Object Model), so
/// server and clients just agree on this sentinel out of band rather than
/// negotiating it over the wire.
pub const default_context_id = "0";

/// A bundled default icon, resolved server-side by name -- the v1 slice of
/// decisions.md's post-v1 Icon section ("a themable, named reference to an
/// image"). Just the flat name -> asset-path table; theming (a
/// context-local catalog overriding this global one) isn't built -- see
/// that section's remaining open scope. `path` is relative to the process
/// cwd, same convention as `host/main.zig`'s font asset path; loading them
/// (real file I/O) is `glyphwire-host`'s job, not core's -- see
/// `main.zig`'s `loadDefaultIcons`.
pub const IconManifestEntry = struct { name: []const u8, path: []const u8 };

pub const default_icon_manifest = [_]IconManifestEntry{
    .{ .name = "folder", .path = "assets/icons/oxygen/folder.png" },
    .{ .name = "folder-open", .path = "assets/icons/oxygen/folder-open.png" },
    .{ .name = "home", .path = "assets/icons/oxygen/home.png" },
    .{ .name = "file", .path = "assets/icons/oxygen/file.png" },
    .{ .name = "audio", .path = "assets/icons/oxygen/audio.png" },
    .{ .name = "image", .path = "assets/icons/oxygen/image.png" },
    .{ .name = "video", .path = "assets/icons/oxygen/video.png" },
    .{ .name = "archive", .path = "assets/icons/oxygen/archive.png" },
    .{ .name = "executable", .path = "assets/icons/oxygen/executable.png" },
    .{ .name = "unknown", .path = "assets/icons/oxygen/unknown.png" },
    .{ .name = "drive", .path = "assets/icons/oxygen/drive.png" },
    .{ .name = "media-optical", .path = "assets/icons/oxygen/media-optical.png" },
};

/// The default box-drawing tile set, registered into the same `icons`
/// catalog as `default_icon_manifest` (there's only one flat catalog --
/// see decisions.md's Icon section) under a `"box-"`-prefixed name per
/// piece. `draw_box`'s `style` param is this prefix, so a future
/// additional style (e.g. a double-line or rounded variant) is just more
/// manifest entries under a different prefix -- no protocol change.
pub const default_box_manifest = [_]IconManifestEntry{
    .{ .name = "box-tl", .path = "assets/icons/box/tl.png" },
    .{ .name = "box-t", .path = "assets/icons/box/t.png" },
    .{ .name = "box-tr", .path = "assets/icons/box/tr.png" },
    .{ .name = "box-l", .path = "assets/icons/box/l.png" },
    .{ .name = "box-fill", .path = "assets/icons/box/fill.png" },
    .{ .name = "box-r", .path = "assets/icons/box/r.png" },
    .{ .name = "box-bl", .path = "assets/icons/box/bl.png" },
    .{ .name = "box-b", .path = "assets/icons/box/b.png" },
    .{ .name = "box-br", .path = "assets/icons/box/br.png" },
};

/// A second bundled box style, `"dialog"`, meant for `draw_box`'s
/// `BoxMode.stretch` -- a light-blue-to-dark-blue vertical gradient with a
/// white border, e.g. `glyphwire-notify`'s popup. Registered the same way
/// as `default_box_manifest` (its own `"dialog-"`-prefixed pieces in the
/// same flat `icons` catalog), just a different prefix.
pub const default_dialog_manifest = [_]IconManifestEntry{
    .{ .name = "dialog-tl", .path = "assets/icons/dialog/tl.png" },
    .{ .name = "dialog-t", .path = "assets/icons/dialog/t.png" },
    .{ .name = "dialog-tr", .path = "assets/icons/dialog/tr.png" },
    .{ .name = "dialog-l", .path = "assets/icons/dialog/l.png" },
    .{ .name = "dialog-fill", .path = "assets/icons/dialog/fill.png" },
    .{ .name = "dialog-r", .path = "assets/icons/dialog/r.png" },
    .{ .name = "dialog-bl", .path = "assets/icons/dialog/bl.png" },
    .{ .name = "dialog-b", .path = "assets/icons/dialog/b.png" },
    .{ .name = "dialog-br", .path = "assets/icons/dialog/br.png" },
};

/// `glyphwire-notify`'s per-type icons (`draw_icon`, drawn over the
/// `"dialog"` background), namespaced under `"notify-"` so they don't
/// collide with unrelated future icons named e.g. "info" or "error".
pub const default_notify_icon_manifest = [_]IconManifestEntry{
    .{ .name = "notify-info", .path = "assets/icons/notify/info.png" },
    .{ .name = "notify-warn", .path = "assets/icons/notify/warn.png" },
    .{ .name = "notify-error", .path = "assets/icons/notify/error.png" },
};

pub const Context = struct {
    alloc: std.mem.Allocator,
    root: Layer,
    /// Layers created via `create_layer`, keyed by handle -- the root
    /// layer isn't in here (it's always addressed as `root_layer_handle`
    /// and always exists; see that constant's doc comment). Every layer
    /// here is parented to the root: decisions.md's Layer tree allows
    /// deeper nesting, but nothing creates or needs a non-root parent yet,
    /// so that generality isn't built.
    layers: std.AutoHashMap(LayerHandle, Layer),
    /// Creation order of `layers`' entries, for compositing -- a later-
    /// created layer draws on top of an earlier one, and the root layer is
    /// always underneath all of them. Kept separate from `layers` itself
    /// since `AutoHashMap` iteration order is unspecified, not something
    /// a renderer should draw in.
    layer_order: std.ArrayList(LayerHandle) = .empty,
    next_layer_handle: LayerHandle = 1,
    input: InputState,
    images: std.AutoHashMap(ImageHandle, ImageEntry),
    next_image_handle: ImageHandle = 1,
    /// Name -> image handle, for `draw_icon` (decisions.md's Icon
    /// section). Populated from `default_icon_manifest` by whoever loads
    /// the icon files (`glyphwire-host`) -- empty until then, same as
    /// `images` before any `load_image` call.
    icons: std.StringHashMap(ImageHandle),
    metadata: std.AutoHashMap(MetadataHandle, Metadata),
    next_metadata_handle: MetadataHandle = 1,
    /// The session's fixed cell pixel metrics -- decisions.md's "one
    /// monospace font + size per session" -- needed to translate a
    /// `draw_image` span into per-cell pixel offsets (see
    /// `Layer.drawImage`). Defaults match glyphwire-host's current
    /// JetBrainsMono tuning (`host/main.zig`'s `cell_w`/`cell_h`); a host
    /// with different metrics should overwrite these right after `init`.
    cell_px_w: u32 = 12,
    cell_px_h: u32 = 12,
    /// Shared across every layer's `tables` map -- see `TableHandle`'s
    /// doc comment.
    next_table_handle: TableHandle = 1,

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, scrollback_rows: usize) !Context {
        return .{
            .alloc = alloc,
            .root = try Layer.init(alloc, width, height, scrollback_rows),
            .layers = std.AutoHashMap(LayerHandle, Layer).init(alloc),
            .input = InputState.init(alloc),
            .images = std.AutoHashMap(ImageHandle, ImageEntry).init(alloc),
            .icons = std.StringHashMap(ImageHandle).init(alloc),
            .metadata = std.AutoHashMap(MetadataHandle, Metadata).init(alloc),
        };
    }

    pub fn deinit(self: *Context) void {
        self.root.deinit();
        var layer_it = self.layers.valueIterator();
        while (layer_it.next()) |l| l.deinit();
        self.layers.deinit();
        self.layer_order.deinit(self.alloc);
        self.input.deinit();
        var it = self.images.valueIterator();
        while (it.next()) |entry| self.alloc.free(entry.bytes);
        self.images.deinit();
        var icon_it = self.icons.keyIterator();
        while (icon_it.next()) |k| self.alloc.free(k.*);
        self.icons.deinit();
        var metadata_it = self.metadata.valueIterator();
        while (metadata_it.next()) |m| self.alloc.free(m.json);
        self.metadata.deinit();
    }

    /// `create_metadata`: stores `json` verbatim (duped -- the caller's
    /// copy, e.g. a just-parsed request buffer, isn't guaranteed to
    /// outlive this) and returns a fresh handle. No cleanup happens here
    /// or anywhere else yet -- `destroy_metadata` is explicit-only for
    /// now, and a real garbage collector (scrollback eviction and
    /// possibly other scenarios freeing ids no cell references any more)
    /// is future work, not needed for this to be useful today.
    pub fn createMetadata(self: *Context, json: []const u8) !MetadataHandle {
        const owned = try self.alloc.dupe(u8, json);
        errdefer self.alloc.free(owned);

        const handle = self.next_metadata_handle;
        self.next_metadata_handle += 1;
        try self.metadata.put(handle, .{ .json = owned });
        return handle;
    }

    /// `destroy_metadata`: frees `id`'s stored JSON. Errors on an unknown
    /// id, same as `destroyLayer` -- there's no reference counting, so a
    /// cell can still be tagged with `id` afterward; `getMetadataAt`
    /// resolves that gracefully (reports the id, `metadata: null`) rather
    /// than erroring, since a dangling tag is an expected, not
    /// exceptional, state once destruction is explicit.
    pub fn destroyMetadata(self: *Context, id: MetadataHandle) MetadataError!void {
        const removed = self.metadata.fetchRemove(id) orelse return MetadataError.UnknownMetadata;
        self.alloc.free(removed.value.json);
    }

    /// `id`'s stored JSON, or null if it was never created or has since
    /// been destroyed (see `destroyMetadata`'s doc comment on why that's
    /// not an error here).
    pub fn metadataJson(self: *const Context, id: MetadataHandle) ?[]const u8 {
        return if (self.metadata.get(id)) |m| m.json else null;
    }

    /// `create_layer`: allocates a fresh layer parented to the root,
    /// defaulting to the context's base size (the root layer's own
    /// width/height) when `width`/`height` is omitted -- decisions.md's
    /// Layer section. Returns its handle. A layer created with *both*
    /// dimensions omitted tracks the context's base size on a later
    /// window resize (`Layer.tracks_context_size` / `Context.resize`);
    /// one created with an explicit size keeps that size.
    pub fn createLayer(self: *Context, width: ?usize, height: ?usize, scrollback_rows: usize) !LayerHandle {
        var layer = try Layer.init(self.alloc, width orelse self.root.width, height orelse self.root.height, scrollback_rows);
        layer.tracks_context_size = (width == null and height == null);
        errdefer layer.deinit();

        const handle = self.next_layer_handle;
        try self.layer_order.append(self.alloc, handle);
        errdefer _ = self.layer_order.pop();

        try self.layers.put(handle, layer);
        self.next_layer_handle += 1;
        return handle;
    }

    /// `destroy_layer`: frees a previously created layer and drops it from
    /// the compositing order. The root layer isn't in `layers` at all
    /// (see `root_layer_handle`'s doc comment), so a handle of 0 reports
    /// `UnknownLayer` here the same as any other bogus handle -- there's
    /// no wire path that destroys the root.
    pub fn destroyLayer(self: *Context, handle: LayerHandle) LayerError!void {
        var removed = self.layers.fetchRemove(handle) orelse return LayerError.UnknownLayer;
        removed.value.deinit();
        for (self.layer_order.items, 0..) |h, i| {
            if (h == handle) {
                _ = self.layer_order.orderedRemove(i);
                break;
            }
        }
    }

    /// Changes the context's base size -- the width/height a
    /// `create_layer` with no explicit dimensions inherits, and what
    /// `get_property(root, "size")` reports. Resizes the root layer plus
    /// every `create_layer` layer that was tracking the base size
    /// (`Layer.tracks_context_size`); layers created at an explicit size
    /// (notification popups, etc.) are left alone. Content in each
    /// resized layer is anchored to its bottom row -- see `Layer.resize`.
    ///
    /// Driven by the host when its window is resized
    /// (`Server.reportResize`); there is no wire message a client can use
    /// to set this. A no-op if the base size is unchanged. On an
    /// allocation failure partway through, the root may have resized
    /// while some tracking layers have not -- acceptable for an OOM path,
    /// which the host treats as fatal anyway.
    pub fn resize(self: *Context, width: usize, height: usize) !void {
        if (width == self.root.width and height == self.root.height) return;
        try self.root.resize(width, height);
        var it = self.layers.valueIterator();
        while (it.next()) |layer| {
            if (layer.tracks_context_size) try layer.resize(width, height);
        }
    }

    /// Resolves a wire-level layer handle to its `Layer` -- `null` (an
    /// omitted `layer` param) and `root_layer_handle` both mean the root
    /// layer, matching how omitted `row`/`col` already means "at the
    /// cursor" elsewhere in the wire API. Null for an unknown non-root
    /// handle (a destroyed or never-created layer).
    pub fn layerPtr(self: *Context, handle: ?LayerHandle) ?*Layer {
        const h = handle orelse root_layer_handle;
        if (h == root_layer_handle) return &self.root;
        return self.layers.getPtr(h);
    }

    /// `create_table`: builds a `Table` (taking ownership of `columns`/
    /// `style`, see `Table.init`) and stores it on the resolved layer's
    /// `tables` map, allocating a fresh handle from `next_table_handle`.
    /// Doesn't paint anything yet -- a freshly created table has no rows,
    /// so there's nothing to render until `table_set_rows`. `row`/`col`
    /// are the resolved anchor (cursor-defaulted by the caller,
    /// `handleCreateTable`, same convention `resolveAnchor` already gives
    /// `draw_icon`/`draw_box`), not optional here.
    pub fn createTable(self: *Context, layer_handle: ?LayerHandle, row: usize, col: usize, columns: []TableColumn, style: TableStyle) !TableHandle {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;

        const handle = self.next_table_handle;
        try layer.tables.put(handle, Table.init(self.alloc, row, col, columns, style));
        errdefer _ = layer.tables.remove(handle);
        try layer.table_order.append(self.alloc, handle);
        self.next_table_handle += 1;
        return handle;
    }

    /// `destroy_table`: blanks whatever the table last painted (see
    /// `Table.painted`), frees it, and drops it from its layer's
    /// compositing order. Errors on an unknown layer or table handle,
    /// same treatment `destroyLayer` gives an unknown layer handle.
    pub fn destroyTable(self: *Context, layer_handle: ?LayerHandle, handle: TableHandle) !void {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;
        var removed = layer.tables.fetchRemove(handle) orelse return TableError.UnknownTable;
        clearExtent(layer, removed.value.painted);
        removed.value.deinit();
        for (layer.table_order.items, 0..) |h, i| {
            if (h == handle) {
                _ = layer.table_order.orderedRemove(i);
                break;
            }
        }
    }

    /// Registers `handle` under `name` in the icon catalog, for `draw_icon`
    /// to resolve later. `name` is duped -- the caller (`loadDefaultIcons`)
    /// doesn't need to keep its own copy alive. Overwrites any existing
    /// registration under the same name (its old key is freed) rather than
    /// erroring, so re-running icon loading is idempotent.
    pub fn registerIcon(self: *Context, name: []const u8, handle: ImageHandle) !void {
        if (self.icons.fetchRemove(name)) |kv| self.alloc.free(kv.key);
        const owned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned);
        try self.icons.put(owned, handle);
    }

    /// `draw_icon`'s name -> handle lookup. Null for an unregistered name.
    pub fn iconHandle(self: *const Context, name: []const u8) ?ImageHandle {
        return self.icons.get(name);
    }

    /// `load_image`: stores `bytes` verbatim (PNG only for now) and parses
    /// just its IHDR dimensions -- see `ImageEntry`'s doc comment. Returns
    /// a fresh server-generated handle.
    pub fn loadImage(self: *Context, bytes: []const u8) !ImageHandle {
        const info = try pngDimensions(bytes);
        const owned = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(owned);

        const handle = self.next_image_handle;
        self.next_image_handle += 1;
        try self.images.put(handle, .{ .bytes = owned, .width = info.width, .height = info.height });
        return handle;
    }

    /// `get_image_info`: natural pixel dimensions, or null for an unknown
    /// handle.
    pub fn imageInfo(self: *const Context, handle: ImageHandle) ?ImageInfo {
        const entry = self.images.get(handle) orelse return null;
        return .{ .width = entry.width, .height = entry.height };
    }
};
