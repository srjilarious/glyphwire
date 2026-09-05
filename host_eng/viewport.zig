//! Logical-resolution viewport math, vendored verbatim in behaviour
//! from pixzig's `src/pixzig/window.zig` (its `Camera2D` and
//! `WindowState` are not carried here -- `WindowState` lives in
//! `window.zig` next door, rebuilt on SDL).

const gl = @import("zopengl").bindings;
const zmath = @import("zmath");
const common = @import("pixzig_src/common.zig");

const Vec2I = common.Vec2I;
const Vec2F = common.Vec2F;
const RectI = common.RectI;

/// How the logical area is mapped onto the framebuffer when the two
/// differ in size. Vendored from pixzig's `src/pixzig/window.zig`.
pub const ScalePolicy = union(enum) {
    /// Fills the framebuffer, ignoring aspect ratio.
    stretch,
    /// Scales uniformly so the logical area fits entirely, letterboxing or
    /// pillarboxing the remainder.
    fit,
    /// Scales uniformly so the logical area covers the framebuffer,
    /// cropping the overflow.
    fill,
    /// Like `fit` but scale is rounded down to the nearest integer; avoids
    /// sub-pixel blurring.
    integer_fit,
    /// Like `fill` but scale is rounded up to the nearest integer.
    integer_fill,
    /// A caller-supplied constant scale factor.
    fixed: f32,
};

pub const Viewport = struct {
    logical_size: Vec2I,
    framebuffer_size: Vec2I,
    viewport_px: RectI,
    scale: Vec2F,
    policy: ScalePolicy,

    /// Computes the initial viewport rectangle from `logical_size`,
    /// `framebuffer_size`, and `policy`.
    pub fn init(logical_size: Vec2I, framebuffer_size: Vec2I, policy: ScalePolicy) Viewport {
        var vp = Viewport{
            .logical_size = logical_size,
            .framebuffer_size = framebuffer_size,
            .viewport_px = .{ .l = 0, .t = 0, .r = 0, .b = 0 },
            .scale = .{ .x = 1.0, .y = 1.0 },
            .policy = policy,
        };
        vp.compute();
        return vp;
    }

    /// Updates the framebuffer size and recomputes the viewport rectangle.
    /// Call this when the window resize event has been picked up (see
    /// `Engine.refreshWindowState`).
    pub fn updateFramebufferSize(self: *Viewport, new_fb_size: Vec2I) void {
        self.framebuffer_size = new_fb_size;
        self.compute();
    }

    /// Calls `gl.viewport` with the computed rectangle. `viewport_px` is in
    /// raster coordinates, so this converts to GL's bottom-left convention
    /// first.
    pub fn apply(self: *const Viewport) void {
        const gl_y: i32 = self.framebuffer_size.y - self.viewport_px.b;
        gl.viewport(self.viewport_px.l, gl_y, self.viewport_px.width(), self.viewport_px.height());
        gl.scissor(self.viewport_px.l, gl_y, self.viewport_px.width(), self.viewport_px.height());
        gl.enable(gl.SCISSOR_TEST);
    }

    /// Orthographic projection for the logical coordinate space. Uses
    /// raster convention: (0,0) is top-left, x grows right, y grows down.
    /// zmath signature: `orthographicOffCenterLhGl(left, right, top, bottom, near, far)`.
    pub fn projection(self: *const Viewport) zmath.Mat {
        const lw: f32 = @floatFromInt(self.logical_size.x);
        const lh: f32 = @floatFromInt(self.logical_size.y);
        return zmath.orthographicOffCenterLhGl(0, lw, 0, lh, -0.1, 1000);
    }

    /// Maps a framebuffer-pixel position into logical coordinates, or null
    /// when it falls outside the viewport rectangle (the letterbox /
    /// pillarbox bars).
    pub fn framebufferToLogical(self: *const Viewport, pos: Vec2F) ?Vec2F {
        const l: f32 = @floatFromInt(self.viewport_px.l);
        const t: f32 = @floatFromInt(self.viewport_px.t);
        const r: f32 = @floatFromInt(self.viewport_px.r);
        const b: f32 = @floatFromInt(self.viewport_px.b);
        if (pos.x < l or pos.y < t or pos.x >= r or pos.y >= b) return null;
        return .{
            .x = (pos.x - l) / self.scale.x,
            .y = (pos.y - t) / self.scale.y,
        };
    }

    fn compute(self: *Viewport) void {
        const fb_w: f32 = @floatFromInt(@max(self.framebuffer_size.x, 1));
        const fb_h: f32 = @floatFromInt(@max(self.framebuffer_size.y, 1));
        const log_w: f32 = @floatFromInt(@max(self.logical_size.x, 1));
        const log_h: f32 = @floatFromInt(@max(self.logical_size.y, 1));
        var sx = fb_w / log_w;
        var sy = fb_h / log_h;

        switch (self.policy) {
            .stretch => {},
            .fit => {
                const s = @min(sx, sy);
                sx = s;
                sy = s;
            },
            .fill => {
                const s = @max(sx, sy);
                sx = s;
                sy = s;
            },
            .integer_fit => {
                const s = @max(1.0, @floor(@min(sx, sy)));
                sx = s;
                sy = s;
            },
            .integer_fill => {
                const s = @max(1.0, @ceil(@max(sx, sy)));
                sx = s;
                sy = s;
            },
            .fixed => |s| {
                sx = s;
                sy = s;
            },
        }

        const vp_w: i32 = @intFromFloat(@round(log_w * sx));
        const vp_h: i32 = @intFromFloat(@round(log_h * sy));
        const x = @divTrunc(self.framebuffer_size.x - vp_w, 2);
        const y = @divTrunc(self.framebuffer_size.y - vp_h, 2);

        self.scale = .{ .x = sx, .y = sy };
        self.viewport_px = .{ .l = x, .t = y, .r = x + vp_w, .b = y + vp_h };
    }
};
