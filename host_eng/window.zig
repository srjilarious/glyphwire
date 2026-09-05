//! Window metrics for the SDL3 backend: the same `WindowState` shape
//! pixzig's `src/pixzig/window.zig` exposes, sourced from SDL instead of
//! GLFW so host code that reads `eng.window_state` is backend-agnostic.

const pixzig = @import("pixzig_core.zig");

const sdl_window = @import("platform_sdl.zig");

pub const WindowState = struct {
    /// OS window size in screen coordinates. On non-HiDPI displays this
    /// equals `framebuffer_size`. On HiDPI it is smaller because the OS
    /// uses logical coordinates for window placement and cursor reporting.
    window_size: pixzig.Vec2I,
    /// Actual framebuffer dimensions in pixels. This is what OpenGL sees
    /// and what you should use for GL viewport calls and projection
    /// matrices.
    framebuffer_size: pixzig.Vec2I,
    /// Display scale reported by `SDL_GetWindowDisplayScale` -- the OS's
    /// hint for how much to scale UI content to look correct at the
    /// display's DPI (2.0 on a typical 2x HiDPI display). Under Wayland
    /// fractional scaling this can disagree with the actual
    /// framebuffer/window ratio, so prefer `scale_factor` for coordinate
    /// math. (pixzig's GLFW backend fills this from
    /// `glfwGetWindowContentScale`; SDL reports one value for both axes.)
    content_scale: pixzig.Vec2F,
    /// Ratio of framebuffer pixels to OS window screen coordinates
    /// (`framebuffer_size / window_size`). Use this to convert cursor
    /// positions (which SDL reports in window screen coordinates) to
    /// framebuffer pixels for correct mouse-to-logical mapping on HiDPI.
    scale_factor: pixzig.Vec2F,
    /// Set by `Engine.pollEvents` when SDL reports a resize / pixel-size /
    /// display-scale change. Cleared by `Engine.refreshWindowState` after
    /// it rebuilds the viewport.
    resized: bool = false,

    /// Initialises state from the current window metrics.
    pub fn init(window: *sdl_window.Window) WindowState {
        var state: WindowState = .{
            .window_size = .{ .x = 0, .y = 0 },
            .framebuffer_size = .{ .x = 0, .y = 0 },
            .content_scale = .{ .x = 1, .y = 1 },
            .scale_factor = .{ .x = 1, .y = 1 },
        };
        state.refresh(window);
        return state;
    }

    /// Re-queries window size, pixel size and display scale from SDL and
    /// recomputes `scale_factor`.
    pub fn refresh(self: *WindowState, window: *sdl_window.Window) void {
        self.window_size = window.getSize();
        self.framebuffer_size = window.getFramebufferSize();

        const display_scale = window.getDisplayScale();
        self.content_scale = .{ .x = display_scale, .y = display_scale };

        const fb_w: f32 = @floatFromInt(self.framebuffer_size.x);
        const fb_h: f32 = @floatFromInt(self.framebuffer_size.y);
        const win_w: f32 = @floatFromInt(self.window_size.x);
        const win_h: f32 = @floatFromInt(self.window_size.y);
        self.scale_factor = .{
            .x = if (win_w > 0) fb_w / win_w else 1.0,
            .y = if (win_h > 0) fb_h / win_h else 1.0,
        };
    }

    /// Returns a `RectI` covering the entire framebuffer (origin at 0,0).
    pub fn framebufferRect(self: *const WindowState) pixzig.RectI {
        return .{ .l = 0, .t = 0, .r = self.framebuffer_size.x, .b = self.framebuffer_size.y };
    }
};
