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
/// Image section. Unused until Image support lands; kept here so Cell's
/// background shape doesn't need to change when it does.
pub const ImageHandle = u32;

/// A cell's background: a flat color, or (post-slice) a reference to a
/// loaded image/icon tile. Mutually exclusive per decisions.md.
pub const Background = union(enum) {
    color: Color,
    image: ImageHandle,
};

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
};

pub const PropertyValue = union(PropertyName) {
    cursor: Cursor,
    revision: u64,
};

pub const PropertyError = error{UnknownProperty};

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
        if (self.cursor.row >= self.height) {
            self.scrollOne();
            self.cursor.row = self.height - 1;
        }

        var c = self.cell(self.cursor.row, self.cursor.col);
        c.setGrapheme(bytes);
        c.style = style;
        self.cursor.col += 1;
    }

    pub fn getProperty(self: *const Layer, name: PropertyName) PropertyValue {
        return switch (name) {
            .cursor => .{ .cursor = self.cursor },
            .revision => .{ .revision = self.revision },
        };
    }

    pub fn setProperty(self: *Layer, value: PropertyValue) void {
        switch (value) {
            .cursor => |c| self.cursor = c,
            .revision => unreachable, // get-only; see PropertyName.revision
        }
    }
};

/// Fixed id for the single auto-created context this slice's server ever
/// has. There's no `create_context` yet (decisions.md, Object Model), so
/// server and clients just agree on this sentinel out of band rather than
/// negotiating it over the wire.
pub const default_context_id = "0";

pub const Context = struct {
    alloc: std.mem.Allocator,
    root: Layer,

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, scrollback_rows: usize) !Context {
        return .{ .alloc = alloc, .root = try Layer.init(alloc, width, height, scrollback_rows) };
    }

    pub fn deinit(self: *Context) void {
        self.root.deinit();
    }
};
