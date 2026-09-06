const std = @import("std");

/// An integer 2d vector structure
pub const Vec2I = struct {
    x: i32,
    y: i32,

    /// Convert to a Vec2F
    pub fn asVec2F(self: *const Vec2I) Vec2F {
        return .{
            .x = @floatFromInt(self.x),
            .y = @floatFromInt(self.y),
        };
    }

    /// Convert to a Vec2U
    pub fn asVec2U(self: *const Vec2I) Vec2U {
        return .{
            .x = @intCast(self.x),
            .y = @intCast(self.y),
        };
    }
};

/// An unsigned int 2d vector
pub const Vec2U = struct {
    x: u32,
    y: u32,

    /// Converts to a Vec2I
    pub fn asVec2I(self: *const Vec2U) Vec2I {
        return .{
            .x = @intCast(self.x),
            .y = @intCast(self.y),
        };
    }
};

/// A float 2d vector
pub const Vec2F = struct {
    x: f32,
    y: f32,

    /// Converts to a Vec2I, truncating the floats
    pub fn asVec2I(self: *const Vec2F) Vec2I {
        return .{
            .x = @intFromFloat(self.x),
            .y = @intFromFloat(self.y),
        };
    }
};

/// A float 3d vector
pub const Vec3F = struct {
    x: f32,
    y: f32,
    z: f32,
};

/// A floating point rectangle structure stored as left, top, right, bottom.
/// This is used for texture coordinates and rendering rectangles in
/// particular.  We assume a raster coordinate system where the top-left is
/// (0,0) and the bottom-right is the screen width, height.
pub const RectF = struct {
    /// The left edge of the rectangle
    l: f32,

    /// The top edge of the rectangle
    t: f32,

    /// The right edge of the rectangle
    r: f32,

    /// The bottom edge of the rectangle
    b: f32,

    /// Returns the width of the rectangle (r - l)
    pub fn width(self: *const RectF) f32 {
        return self.r - self.l;
    }

    /// Returns the height of the rectangle (b - t)
    pub fn height(self: *const RectF) f32 {
        return self.b - self.t;
    }

    /// Creates a RectF from the coordinates of the top-left corner (x, y),
    /// the width and height (w, h), and the total size of the texture
    /// (szW, szH), converting to texture coordinates.
    pub fn fromCoords(x: i32, y: i32, w: i32, h: i32, szW: i32, szH: i32) RectF {
        const xF = @as(f32, @floatFromInt(x));
        const yF = @as(f32, @floatFromInt(y));
        const wF = @as(f32, @floatFromInt(w));
        const hF = @as(f32, @floatFromInt(h));
        const szWF = @as(f32, @floatFromInt(szW));
        const szHF = @as(f32, @floatFromInt(szH));
        return .{
            .l = xF / szWF,
            .r = (xF + wF) / szWF,
            .t = yF / szHF,
            .b = (yF + hF) / szHF,
        };
    }

    /// Creates a RectF from the coordinates of the top-left corner (x, y) and
    /// the width and height (w, h), as absolute coords.
    pub fn fromPosSize(x: i32, y: i32, w: i32, h: i32) RectF {
        const xF = @as(f32, @floatFromInt(x));
        const yF = @as(f32, @floatFromInt(y));
        const wF = @as(f32, @floatFromInt(w));
        const hF = @as(f32, @floatFromInt(h));
        return .{
            .l = xF,
            .r = xF + wF,
            .t = yF,
            .b = yF + hF,
        };
    }

    /// Shrinks the rectangle from all sides by the given amount. This is
    /// useful for drawing outlines where you want the outline to be
    /// inside the rectangle.
    pub fn shrinkFrom(self: *const RectF, amount: f32) RectF {
        return .{
            .l = self.l + amount,
            .r = self.r - amount,
            .t = self.t + amount,
            .b = self.b - amount,
        };
    }

    /// Ensures that the rectangle is at least w wide and h tall, expanding the
    /// right and bottom edges as necessary.
    pub fn ensureSize(self: *RectF, w: i32, h: i32) void {
        const wF = @as(f32, @floatFromInt(w));
        const hF = @as(f32, @floatFromInt(h));
        self.r = self.l + wF;
        self.b = self.t + hF;
    }

    /// Converts the width and height of the rectangle to a Vec2U
    pub fn size2U(self: *const RectF) Vec2U {
        const w: usize = @intFromFloat(self.width());
        const h: usize = @intFromFloat(self.height());
        return .{ .x = w, .y = h };
    }

    /// Converts the left and top coordinates of the rectangle to a Vec2I
    pub fn pos2I(self: *const RectF) Vec2I {
        const x: i32 = @intFromFloat(self.l);
        const y: i32 = @intFromFloat(self.t);
        return .{ .x = x, .y = y };
    }

    /// Converts the left and top coordinates of the rectangle to a Vec2F
    pub fn pos2F(self: *const RectF) Vec2F {
        return .{ .x = self.l, .y = self.t };
    }

    /// Returns the center point of the rectangle as a Vec2F
    pub fn centerF(self: *const RectF) Vec2F {
        return .{
            .x = (self.l + self.r) * 0.5,
            .y = (self.t + self.b) * 0.5,
        };
    }

    /// Sets the position of the rectangle to (x, y) while keeping the width
    /// and height the same.
    pub fn setPos(self: *RectF, x: f32, y: f32) void {
        const w = self.width();
        const h = self.height();
        self.l = x;
        self.t = y;
        self.r = x + w;
        self.b = y + h;
    }

    /// Checks if this rectangle intersects with another rectangle. Returns
    /// true if they intersect and false otherwise.
    pub fn intersects(self: *const RectF, other: *const RectF) bool {
        return self.l < other.r and
            self.r > other.l and
            self.t < other.b and
            self.b > other.t;
    }
};

/// An integer rectangle structure stored as left, top, right, bottom. This is
/// used for collision detection and other integer-based rectangle operations.
pub const RectI = struct {
    /// The left edge of the rectangle
    l: i32,

    /// The top edge of the rectangle
    t: i32,

    /// The right edge of the rectangle
    r: i32,

    /// The bottom edge of the rectangle
    b: i32,

    /// Creates a RectI from the coordinates of the top-left corner (l, t) and
    /// the width and height (w, h).
    pub fn init(l: i32, t: i32, w: i32, h: i32) RectI {
        return RectI{
            .l = l,
            .t = t,
            .r = l + w,
            .b = t + h,
        };
    }

    /// Returns the width of the rectangle (r - l)
    pub fn width(self: *const RectI) i32 {
        return self.r - self.l;
    }

    /// Returns the height of the rectangle (b - t)
    pub fn height(self: *const RectI) i32 {
        return self.b - self.t;
    }

    /// Gets the size of the rectangle as a Vec2U.
    pub fn size2U(self: *const RectI) Vec2U {
        const w: usize = @intCast(self.width());
        const h: usize = @intCast(self.height());
        return .{ .x = w, .y = h };
    }

    /// Checks if the other rectangle intersects with this rectangle. Returns
    /// true if they intersect and false otherwise.
    pub fn intersects(self: *const RectI, other: *const RectI) bool {
        return self.l < other.r and
            self.r > other.l and
            self.t < other.b and
            self.b > other.t;
    }
};

/// A simple color struct with r, g, b, a components as floats from 0 to 1.
pub const Color = struct {
    /// Red component of the color, from 0 to 1
    r: f32,

    /// Green component of the color, from 0 to 1
    g: f32,

    /// Blue component of the color, from 0 to 1
    b: f32,

    /// Alpha component of the color, from 0 to 1
    a: f32,

    /// Creates a Color from 8-bit integer components (0-255)
    pub fn from(_r: u8, _g: u8, _b: u8, _a: u8) Color {
        const r = @as(f32, @floatFromInt(_r)) / 255;
        const g = @as(f32, @floatFromInt(_g)) / 255;
        const b = @as(f32, @floatFromInt(_b)) / 255;
        const a = @as(f32, @floatFromInt(_a)) / 255;
        return Color{
            .r = r,
            .g = g,
            .b = b,
            .a = a,
        };
    }
};

/// A color struct with r, g, b, a components as 8-bit integers from 0 to 255.
/// This is useful for pixel buffers and other places where we want to store
/// colors in a compact format.
pub const Color8 = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// Creates a Color8 from 8-bit integer components (0-255)
    pub fn from(r: u8, g: u8, b: u8, a: u8) Color8 {
        return .{
            .r = r,
            .g = g,
            .b = b,
            .a = a,
        };
    }
};

/// An enum representing the possible rotations and flips for rendering sprites.
pub const Rotate = enum {
    /// No rotation or flip
    none,

    /// Rotate 90 degrees clockwise
    rot90,

    /// Rotate 180 degrees
    rot180,

    /// Rotate 270 degrees clockwise (or 90 degrees counterclockwise)
    rot270,

    /// Flip horizontally
    flipHorz,

    /// Flip vertically
    flipVert,
};
