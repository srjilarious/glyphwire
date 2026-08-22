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
};

pub const PropertyValue = union(PropertyName) {
    cursor: Cursor,
};

pub const PropertyError = error{UnknownProperty};

pub const Layer = struct {
    alloc: std.mem.Allocator,
    width: usize,
    height: usize,
    /// Row-major cell grid: rows[row][col].
    rows: [][]Cell,
    cursor: Cursor = .{},

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize) !Layer {
        const rows = try alloc.alloc([]Cell, height);
        errdefer alloc.free(rows);

        var built: usize = 0;
        errdefer for (rows[0..built]) |row| alloc.free(row);

        for (rows) |*row| {
            row.* = try alloc.alloc(Cell, width);
            for (row.*) |*c| c.* = .{};
            built += 1;
        }

        return .{ .alloc = alloc, .width = width, .height = height, .rows = rows };
    }

    pub fn deinit(self: *Layer) void {
        for (self.rows) |row| self.alloc.free(row);
        self.alloc.free(self.rows);
    }

    pub fn cell(self: *const Layer, row: usize, col: usize) *Cell {
        return &self.rows[row][col];
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
    }

    fn putAtCursor(self: *Layer, bytes: []const u8, style: Style) void {
        if (self.cursor.col >= self.width) {
            self.cursor.col = 0;
            self.cursor.row += 1;
        }
        // No scrollback in this slice: writes past the last row are dropped.
        if (self.cursor.row >= self.height) return;

        var c = self.cell(self.cursor.row, self.cursor.col);
        c.setGrapheme(bytes);
        c.style = style;
        self.cursor.col += 1;
    }

    pub fn getProperty(self: *const Layer, name: PropertyName) PropertyValue {
        return switch (name) {
            .cursor => .{ .cursor = self.cursor },
        };
    }

    pub fn setProperty(self: *Layer, value: PropertyValue) void {
        switch (value) {
            .cursor => |c| self.cursor = c,
        }
    }
};

pub const Context = struct {
    alloc: std.mem.Allocator,
    root: Layer,

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize) !Context {
        return .{ .alloc = alloc, .root = try Layer.init(alloc, width, height) };
    }

    pub fn deinit(self: *Context) void {
        self.root.deinit();
    }
};
