const std = @import("std");
const zmath = @import("zmath");

const common = @import("../common.zig");

const resources = @import("../resources.zig");
const C = @import("./constants.zig");
const quad_batch = @import("./quad_batch.zig");

const RectF = common.RectF;
const Color = common.Color;
const ManagedShader = resources.ManagedShader;

const Inner = quad_batch.QuadBatch(.{ .posDim = 2, .colorDim = 4 });

/// ShapeBatchQueue lets the user queue up multiple colored (untextured)
/// shapes to draw in one go. This is a thin wrapper over `QuadBatch`,
/// translating a destination rect + color into the 4 corner
/// positions/colors the generic batch expects, plus the multi-rect
/// composition used by `drawRect`/`drawEnclosingRect` for line-drawn
/// outlines. The batch is drawn via `flush`, which happens on render or
/// queueing more than the batch's quad capacity (`C.MaxSprites` by
/// default, or whatever `initCapacity` was given).
pub const ShapeBatchQueue = struct {
    inner: Inner,

    /// Creates the batch with the default `C.MaxSprites` quad capacity.
    /// Use `initCapacity` to size it explicitly.
    pub fn init(alloc: std.mem.Allocator, shader: *ManagedShader) !ShapeBatchQueue {
        return initCapacity(alloc, shader, C.MaxSprites);
    }

    /// Like `init`, but caps the batch at `maxQuads` queued quads before it
    /// auto-flushes. Sizes the CPU scratch buffers and GPU VBOs up front.
    pub fn initCapacity(alloc: std.mem.Allocator, shader: *ManagedShader, maxQuads: usize) !ShapeBatchQueue {
        return .{ .inner = try Inner.init(alloc, shader, maxQuads) };
    }

    /// Frees our OpenGL VBO resources and the internal buffers we use to queue up shapes.
    pub fn deinit(self: *ShapeBatchQueue) void {
        self.inner.deinit();
    }

    /// Begins a draw cycle for the shape batch, must be matched with a call to `end`
    pub fn begin(self: *ShapeBatchQueue, mvp: zmath.Mat) void {
        self.inner.begin(mvp);
    }

    /// Draws a filled rectangle with the given color.
    pub fn drawFilledRect(self: *ShapeBatchQueue, dest: RectF, color: Color) void {
        const positions: [4][2]f32 = .{
            .{ dest.l, dest.b },
            .{ dest.l, dest.t },
            .{ dest.r, dest.t },
            .{ dest.r, dest.b },
        };

        const colors: [4][4]f32 = .{
            .{ color.r, color.g, color.b, color.a },
            .{ color.r, color.g, color.b, color.a },
            .{ color.r, color.g, color.b, color.a },
            .{ color.r, color.g, color.b, color.a },
        };

        self.inner.addQuad({}, positions, {}, colors);
    }

    /// This draw a rect with the bounds being dest with it encroaching in by lineWidth
    pub fn drawRect(self: *ShapeBatchQueue, dest: RectF, color: Color, lineWidth: u8) void {
        const lF = @as(f32, @floatFromInt(lineWidth));
        // Draw top rect
        const topRect = RectF{
            .l = dest.l,
            .t = dest.t,
            .r = dest.r,
            .b = dest.t + lF,
        };
        self.drawFilledRect(topRect, color);

        // Draw the left rect
        const leftRect = RectF{
            .l = dest.l,
            .t = dest.t + lF,
            .r = dest.l + lF,
            .b = dest.b - lF,
        };
        self.drawFilledRect(leftRect, color);

        // Draw the right rect
        const rightRect = RectF{
            .l = dest.r - lF,
            .t = dest.t + lF,
            .r = dest.r,
            .b = dest.b - lF,
        };
        self.drawFilledRect(rightRect, color);

        // Draw the bottom rect
        const bottomRect = RectF{
            .l = dest.l,
            .t = dest.b - lF,
            .r = dest.r,
            .b = dest.b,
        };
        self.drawFilledRect(bottomRect, color);
    }

    /// This moves the outline of the rect to enclose the dest by lineWidth.
    pub fn drawEnclosingRect(self: *ShapeBatchQueue, dest: RectF, color: Color, lineWidth: u8) void {
        const lF = @as(f32, @floatFromInt(lineWidth));
        // Draw top rect
        const topRect = RectF{
            .l = dest.l - lF,
            .t = dest.t - lF,
            .r = dest.r + lF,
            .b = dest.t,
        };
        self.drawFilledRect(topRect, color);

        // Draw the left rect
        const leftRect = RectF{
            .l = dest.l - lF,
            .t = dest.t,
            .r = dest.l,
            .b = dest.b,
        };
        self.drawFilledRect(leftRect, color);

        // Draw the right rect.
        const rightRect = RectF{
            .l = dest.r,
            .t = dest.t,
            .r = dest.r + lF,
            .b = dest.b,
        };
        self.drawFilledRect(rightRect, color);

        // Draw the bottom rect.
        const bottomRect = RectF{
            .l = dest.l - lF,
            .t = dest.b,
            .r = dest.r + lF,
            .b = dest.b + lF,
        };
        self.drawFilledRect(bottomRect, color);
    }

    /// Finishes a draw cycle with the shape batch, executing the draw calls.
    pub fn end(self: *ShapeBatchQueue) void {
        self.inner.end();
    }

    /// Flushes queued shapes while keeping the batch open for further draws.
    pub fn flush(self: *ShapeBatchQueue) void {
        self.inner.flush();
    }
};
