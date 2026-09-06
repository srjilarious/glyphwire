const std = @import("std");
const zmath = @import("zmath");

const common = @import("../common.zig");

const textures = @import("./textures.zig");
const resources = @import("../resources.zig");
const Sprite = @import("./sprites.zig").Sprite;
const C = @import("./constants.zig");
const quad_batch = @import("./quad_batch.zig");

const RectF = common.RectF;
const Rotate = common.Rotate;
const Texture = textures.Texture;
const ManagedShader = resources.ManagedShader;

const Inner = quad_batch.QuadBatch(.{ .posDim = 2, .texDim = 2 });

/// SpriteBatchQueue lets the user queue up multiple sprites to draw in one go.
/// This is a thin wrapper over `QuadBatch`, translating a destination rect
/// plus optional 90deg rotation/flip into the 4 corner positions/texcoords
/// the generic batch expects. The batch is drawn via `flush`, which happens
/// on render, switching the current texture, or queueing more than the
/// batch's quad capacity (`C.MaxSprites` by default, or whatever
/// `initCapacity` was given).
pub const SpriteBatchQueue = struct {
    inner: Inner,

    /// Initializes the SpriteBatchQueue with the default `C.MaxSprites`
    /// quad capacity. Use `initCapacity` to size it explicitly.
    pub fn init(alloc: std.mem.Allocator, shader: *ManagedShader) !SpriteBatchQueue {
        return initCapacity(alloc, shader, C.MaxSprites);
    }

    /// Like `init`, but caps the batch at `maxQuads` queued quads before it
    /// auto-flushes. Sizes the CPU scratch buffers and GPU VBOs up front.
    pub fn initCapacity(alloc: std.mem.Allocator, shader: *ManagedShader, maxQuads: usize) !SpriteBatchQueue {
        return .{ .inner = try Inner.init(alloc, shader, maxQuads) };
    }

    /// Cleans up the OpenGL objects associated with the SpriteBatchQueue and frees the buffer memory.
    pub fn deinit(self: *SpriteBatchQueue) void {
        self.inner.deinit();
    }

    /// Swap to a different shader entirely (e.g. text renderer toggling
    /// between alpha and RGB pixel shaders). Releases the current handle,
    /// acquires from `newShader`, and re-caches uniform/attribute locations.
    pub fn swapShader(self: *SpriteBatchQueue, newShader: *ManagedShader) !void {
        try self.inner.swapShader(newShader);
    }

    /// Begins a new render frame, setting the Model-View-Projection matrix to use.
    pub fn begin(self: *SpriteBatchQueue, mvp: zmath.Mat) void {
        self.inner.begin(mvp);
    }

    // Enqueues drawing a `Sprite`
    pub fn drawSprite(self: *SpriteBatchQueue, sprite: *const Sprite) void {
        self.draw(&sprite.texture.val, sprite.dest, sprite.src_coords, sprite.rotate);
    }

    /// Enqueues drawing a portion of a texture to the screen, with optional 90deg rotation or flips.
    pub fn draw(self: *SpriteBatchQueue, texture: *const Texture, dest: RectF, srcCoords: RectF, rot: Rotate) void {
        const positions: [4][2]f32 = .{
            .{ dest.l, dest.b },
            .{ dest.l, dest.t },
            .{ dest.r, dest.t },
            .{ dest.r, dest.b },
        };

        const texCoords: [4][2]f32 = switch (rot) {
            .none => .{
                .{ srcCoords.l, srcCoords.b },
                .{ srcCoords.l, srcCoords.t },
                .{ srcCoords.r, srcCoords.t },
                .{ srcCoords.r, srcCoords.b },
            },
            .rot90 => .{
                .{ srcCoords.l, srcCoords.t },
                .{ srcCoords.r, srcCoords.t },
                .{ srcCoords.r, srcCoords.b },
                .{ srcCoords.l, srcCoords.b },
            },
            .rot180 => .{
                .{ srcCoords.r, srcCoords.t },
                .{ srcCoords.r, srcCoords.b },
                .{ srcCoords.l, srcCoords.b },
                .{ srcCoords.l, srcCoords.t },
            },
            .rot270 => .{
                .{ srcCoords.r, srcCoords.b },
                .{ srcCoords.l, srcCoords.b },
                .{ srcCoords.l, srcCoords.t },
                .{ srcCoords.r, srcCoords.t },
            },
            .flipHorz => .{
                .{ srcCoords.r, srcCoords.b },
                .{ srcCoords.r, srcCoords.t },
                .{ srcCoords.l, srcCoords.t },
                .{ srcCoords.l, srcCoords.b },
            },
            .flipVert => .{
                .{ srcCoords.l, srcCoords.t },
                .{ srcCoords.l, srcCoords.b },
                .{ srcCoords.r, srcCoords.b },
                .{ srcCoords.r, srcCoords.t },
            },
        };

        self.inner.addQuad(texture, positions, texCoords, {});
    }

    // Ends the current batch and flushes any sprites to the screen.
    pub fn end(self: *SpriteBatchQueue) void {
        self.inner.end();
    }

    /// Draws the current contents of the queue to the screen.
    /// This assumes we have called `begin` beforehand.
    /// Flushes queued sprites while keeping the batch open for further draws.
    pub fn flush(self: *SpriteBatchQueue) void {
        self.inner.flush();
    }
};
