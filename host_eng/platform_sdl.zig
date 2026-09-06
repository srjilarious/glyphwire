//! The SDL3 window and its OpenGL context. Nothing above this file needs
//! to know which windowing library is underneath.

const std = @import("std");
const sdl = @import("sdl3");
const stbi = @import("zstbi");
const core = @import("core.zig");

/// Logs SDL's error string alongside the Zig error being returned. SDL
/// reports failures through a thread-local string rather than a code, so
/// without this the error is just `error.SdlCreateWindowFailed` with no
/// hint as to why.
pub fn sdlError(err: anyerror) anyerror {
    std.log.err("SDL3: {s}", .{sdl.SDL_GetError()});
    return err;
}

pub const Window = struct {
    allocator: std.mem.Allocator,
    handle: *sdl.SDL_Window,
    gl_context: sdl.SDL_GLContext,
    close_requested: bool = false,
    clipboard_buf: std.ArrayList(u8) = .empty,
    /// Whether `SDL_StartTextInput` succeeded, so `destroy` knows whether
    /// there is anything to stop.
    text_input_active: bool = false,

    /// `text_input` arms SDL's text-input machinery on the window, which
    /// is what makes `SDL_EVENT_TEXT_INPUT` and the IME composition events
    /// arrive at all. See `InputOptions.textInput`.
    pub fn create(
        allocator: std.mem.Allocator,
        title: [:0]const u8,
        options: core.EngineInitOptions,
        text_input: bool,
    ) !*Window {
        var flags: sdl.SDL_WindowFlags = sdl.SDL_WINDOW_OPENGL | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        if (options.resizable) flags |= sdl.SDL_WINDOW_RESIZABLE;
        if (options.fullscreen) flags |= sdl.SDL_WINDOW_FULLSCREEN;

        const handle = sdl.SDL_CreateWindow(title.ptr, options.windowSize.x, options.windowSize.y, flags) orelse
            return sdlError(error.SdlCreateWindowFailed);
        errdefer sdl.SDL_DestroyWindow(handle);

        _ = sdl.SDL_SetWindowMinimumSize(handle, 400, 400);

        const gl_context = sdl.SDL_GL_CreateContext(handle) orelse
            return sdlError(error.SdlCreateContextFailed);
        errdefer _ = sdl.SDL_GL_DestroyContext(gl_context);

        if (!sdl.SDL_GL_MakeCurrent(handle, gl_context)) return sdlError(error.SdlMakeCurrentFailed);

        const window = try allocator.create(Window);
        window.* = .{
            .allocator = allocator,
            .handle = handle,
            .gl_context = gl_context,
        };

        if (text_input) {
            // Failing here costs typed text and IME support but leaves a
            // perfectly usable window, so warn rather than abort startup.
            if (sdl.SDL_StartTextInput(handle)) {
                window.text_input_active = true;
            } else {
                std.log.warn("SDL_StartTextInput failed, typed text will be unavailable: {s}", .{sdl.SDL_GetError()});
            }
        }

        return window;
    }

    pub fn destroy(self: *Window) void {
        self.clipboard_buf.deinit(self.allocator);
        if (self.text_input_active) _ = sdl.SDL_StopTextInput(self.handle);
        // Unbind before destroying: the context is still current here, and
        // some drivers object to having the current context pulled out
        // from under them.
        _ = sdl.SDL_GL_MakeCurrent(self.handle, null);
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

    pub fn getSize(self: *Window) core.Vec2I {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = sdl.SDL_GetWindowSize(self.handle, &w, &h);
        return .{ .x = @intCast(w), .y = @intCast(h) };
    }

    pub fn getFramebufferSize(self: *Window) core.Vec2I {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(self.handle, &w, &h);
        return .{ .x = @intCast(w), .y = @intCast(h) };
    }

    /// Sets the window icon from decoded RGBA8 pixels.
    pub fn setIcon(self: *Window, image: *const stbi.Image) void {
        const surface = sdl.SDL_CreateSurfaceFrom(
            @intCast(image.width),
            @intCast(image.height),
            sdl.SDL_PIXELFORMAT_RGBA32,
            image.data.ptr,
            @intCast(image.bytes_per_row),
        ) orelse {
            std.log.warn("SDL_CreateSurfaceFrom failed: {s}", .{sdl.SDL_GetError()});
            return;
        };
        // The surface borrows `image.data`; SDL copies what it needs out of
        // it during SetWindowIcon, so destroying it here is safe.
        defer sdl.SDL_DestroySurface(surface);

        if (!sdl.SDL_SetWindowIcon(self.handle, surface)) {
            std.log.warn("SDL_SetWindowIcon failed: {s}", .{sdl.SDL_GetError()});
        }
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
