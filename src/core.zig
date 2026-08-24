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

/// A cell's background: a flat color, a reference to a loaded image tile
/// (`draw_image`/`draw_box`, clipped rather than stretched -- see
/// `ImageBg`), or a reference to a loaded icon (`draw_icon`, scaled to
/// fit the cell aspect-correct -- see decisions.md's Icon section). Icons
/// get their own variant rather than reusing `ImageBg` with a zero
/// offset: unlike a clipped image, an icon always shows the *whole*
/// source image scaled into the *whole* cell, so there's no offset (or
/// image dimensions, or cell metrics) to track at all -- resolving a name
/// to a handle and drawing it is the entire job. Mutually exclusive per
/// decisions.md.
pub const Background = union(enum) {
    color: Color,
    image: ImageBg,
    icon: ImageHandle,
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
};

pub const PropertyValue = union(PropertyName) {
    cursor: Cursor,
    revision: u64,
    position: PxPos,
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

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, scrollback_rows: usize) !Layer {
        const total_rows = height + scrollback_rows;
        const buf = try alloc.alloc(Cell, width * total_rows);
        for (buf) |*c| c.* = .{};

        return .{
            .alloc = alloc,
            .width = width,
            .height = height,
            .scrollback_rows = scrollback_rows,
            .buf = buf,
        };
    }

    pub fn deinit(self: *Layer) void {
        self.alloc.free(self.buf);
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

    /// Appends `text` as grapheme clusters starting at the layer's cursor,
    /// advancing and wrapping it at the layer edge. Naive UTF-8 codepoint
    /// splitting for now, not real grapheme segmentation (UAX #29) — see
    /// decisions.md; swapping in the real thing later shouldn't change this
    /// shape.
    pub fn writeText(self: *Layer, text: []const u8, style: Style) !void {
        const view = try std.unicode.Utf8View.init(text);
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp_bytes| {
            self.putAtCursor(cp_bytes, style);
        }
        self.revision += 1;
    }

    fn putAtCursor(self: *Layer, bytes: []const u8, style: Style) void {
        if (self.cursor.col >= self.width) {
            self.cursor.col = 0;
            self.cursor.row += 1;
        }
        self.cursor.row = self.resolveRow(self.cursor.row);

        var c = self.cell(self.cursor.row, self.cursor.col);
        c.setGrapheme(bytes);
        c.style = style;
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

    /// Marks exactly one cell as backed by `handle`, resolved server-side
    /// by name against the icon catalog (`Context.iconHandle`) --
    /// dispatch.zig's job, not this method's. Unlike `drawImage`, there's
    /// no offset/dimension tracking at all: an icon always shows the
    /// whole source image scaled (aspect-correct) into the whole cell, so
    /// the renderer just needs the handle -- see `Background`'s doc
    /// comment for why icons get their own variant instead of reusing
    /// `ImageBg`.
    pub fn drawIcon(self: *Layer, handle: ImageHandle, row: usize, col: usize) void {
        const resolved_row = self.resolveRow(row);
        if (col >= self.width) return;
        self.cell(resolved_row, col).style.bg = .{ .icon = handle };
        self.revision += 1;
    }

    /// The 9 resolved tiles a `draw_box` call needs -- corners, edges, and
    /// a fill, per decisions.md's Icon section / roadmap.md's Phase 3.6.
    /// Just handles, same as `draw_icon`: each tile is drawn with the
    /// `.icon` Background variant (whole source image, scaled aspect-
    /// correct into the whole cell -- see `drawIcon`'s doc comment), not
    /// `.image`'s clip-and-offset scheme, so there's no per-tile
    /// width/height to carry here either. Resolving these (by
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

    /// Draws a `rows x cols` box anchored at `(row, col)` (clamped to the
    /// layer's own bounds) using `tiles`: each cell gets exactly one tile,
    /// chosen by whether it's on the box's top/bottom row and/or
    /// left/right column, drawn the same scale-to-fit way `drawIcon` draws
    /// a single cell. The bundled tile art is drawn with its border line
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

        var r = anchor_row;
        while (r < row_end) : (r += 1) {
            const is_top = r == anchor_row;
            const is_bottom = r == last_row;

            var c = col;
            while (c < col_end) : (c += 1) {
                const is_left = c == col;
                const is_right = c == last_col;

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

                self.cell(r, c).style.bg = .{ .icon = tile };
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
        };
    }

    pub fn setProperty(self: *Layer, value: PropertyValue) void {
        switch (value) {
            .cursor => |c| self.cursor = .{ .row = self.resolveRow(c.row), .col = c.col },
            .revision => unreachable, // get-only; see PropertyName.revision
            .position => |p| self.pos = p,
        }
    }
};

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
    /// The session's fixed cell pixel metrics -- decisions.md's "one
    /// monospace font + size per session" -- needed to translate a
    /// `draw_image` span into per-cell pixel offsets (see
    /// `Layer.drawImage`). Defaults match glyphwire-host's current
    /// JetBrainsMono tuning (`host/main.zig`'s `cell_w`/`cell_h`); a host
    /// with different metrics should overwrite these right after `init`.
    cell_px_w: u32 = 12,
    cell_px_h: u32 = 12,

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, scrollback_rows: usize) !Context {
        return .{
            .alloc = alloc,
            .root = try Layer.init(alloc, width, height, scrollback_rows),
            .layers = std.AutoHashMap(LayerHandle, Layer).init(alloc),
            .input = InputState.init(alloc),
            .images = std.AutoHashMap(ImageHandle, ImageEntry).init(alloc),
            .icons = std.StringHashMap(ImageHandle).init(alloc),
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
    }

    /// `create_layer`: allocates a fresh layer parented to the root,
    /// defaulting to the context's base size (the root layer's own
    /// width/height) when `width`/`height` is omitted -- decisions.md's
    /// Layer section. Returns its handle.
    pub fn createLayer(self: *Context, width: ?usize, height: ?usize, scrollback_rows: usize) !LayerHandle {
        var layer = try Layer.init(self.alloc, width orelse self.root.width, height orelse self.root.height, scrollback_rows);
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
