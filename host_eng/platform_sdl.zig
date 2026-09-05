const std = @import("std");
const sdl = @import("sdl3");
const pixzig = @import("pixzig_core.zig");

pub const Window = struct {
    allocator: std.mem.Allocator,
    handle: *sdl.SDL_Window,
    gl_context: sdl.SDL_GLContext,
    close_requested: bool = false,
    clipboard_buf: std.ArrayList(u8) = .empty,

    pub fn create(allocator: std.mem.Allocator, title: [:0]const u8, options: pixzig.PixzigEngineInitOptions) !*Window {
        var flags: sdl.SDL_WindowFlags = sdl.SDL_WINDOW_OPENGL | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        if (options.resizable) flags |= sdl.SDL_WINDOW_RESIZABLE;
        if (options.fullscreen) flags |= sdl.SDL_WINDOW_FULLSCREEN;

        const handle = sdl.SDL_CreateWindow(title.ptr, options.windowSize.x, options.windowSize.y, flags) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlCreateWindowFailed;
        };
        errdefer sdl.SDL_DestroyWindow(handle);

        _ = sdl.SDL_SetWindowMinimumSize(handle, 400, 400);

        const gl_context = sdl.SDL_GL_CreateContext(handle) orelse {
            std.log.err("SDL_GL_CreateContext failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlCreateContextFailed;
        };
        errdefer _ = sdl.SDL_GL_DestroyContext(gl_context);

        const window = try allocator.create(Window);
        window.* = .{
            .allocator = allocator,
            .handle = handle,
            .gl_context = gl_context,
        };
        return window;
    }

    pub fn destroy(self: *Window) void {
        self.clipboard_buf.deinit(self.allocator);
        _ = sdl.SDL_StopTextInput(self.handle);
        _ = sdl.SDL_GL_DestroyContext(self.gl_context);
        sdl.SDL_DestroyWindow(self.handle);
        self.allocator.destroy(self);
    }

    pub fn swapBuffers(self: *Window) void {
        _ = sdl.SDL_GL_SwapWindow(self.handle);
    }

    pub fn shouldClose(self: *const Window) bool {
        return self.close_requested;
    }

    pub fn setSize(self: *Window, width: i32, height: i32) void {
        _ = sdl.SDL_SetWindowSize(self.handle, width, height);
    }

    pub fn getSize(self: *Window) pixzig.Vec2I {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = sdl.SDL_GetWindowSize(self.handle, &w, &h);
        return .{ .x = @intCast(w), .y = @intCast(h) };
    }

    pub fn getFramebufferSize(self: *Window) pixzig.Vec2I {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(self.handle, &w, &h);
        return .{ .x = @intCast(w), .y = @intCast(h) };
    }

    pub fn getDisplayScale(self: *Window) f32 {
        const scale = sdl.SDL_GetWindowDisplayScale(self.handle);
        return if (scale > 0) scale else 1.0;
    }

    pub fn setClipboardString(self: *Window, text: [:0]const u8) void {
        _ = self;
        if (!sdl.SDL_SetClipboardText(text.ptr)) {
            std.log.warn("SDL_SetClipboardText failed: {s}", .{sdl.SDL_GetError()});
        }
    }

    pub fn getClipboardString(self: *Window) ?[]const u8 {
        const text = sdl.SDL_GetClipboardText() orelse return null;
        defer sdl.SDL_free(text);

        const slice = std.mem.span(text);
        self.clipboard_buf.clearRetainingCapacity();
        self.clipboard_buf.appendSlice(self.allocator, slice) catch return null;
        return self.clipboard_buf.items;
    }

    pub fn setTextInputArea(self: *Window, x: i32, y: i32, width: i32, height: i32, cursor: i32) void {
        var rect = sdl.SDL_Rect{ .x = x, .y = y, .w = width, .h = height };
        if (!sdl.SDL_SetTextInputArea(self.handle, &rect, cursor)) {
            std.log.warn("SDL_SetTextInputArea failed: {s}", .{sdl.SDL_GetError()});
        }
    }
};
