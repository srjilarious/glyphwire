const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const pixzig = @import("pixzig_core.zig");

const input_mod = @import("input.zig");
const platform_mod = @import("platform_sdl.zig");
const window_mod = @import("window.zig");

pub const gl = pixzig.gl;
pub const zopengl = pixzig.zopengl;
pub const zmath = pixzig.zmath;
pub const stbi = pixzig.stbi;
pub const renderer = pixzig.renderer;
pub const shaders = pixzig.shaders;
pub const resources = pixzig.resources;
pub const system = pixzig.system;
pub const ziglua = pixzig.ziglua;

pub const Texture = pixzig.Texture;
pub const ManagedTexture = pixzig.ManagedTexture;
pub const ManagedShader = pixzig.ManagedShader;
pub const Vec2I = pixzig.Vec2I;
pub const Vec2F = pixzig.Vec2F;
pub const RectI = pixzig.RectI;
pub const RectF = pixzig.RectF;
pub const Color = pixzig.Color;
pub const Color8 = pixzig.Color8;
pub const Viewport = pixzig.Viewport;
pub const ScalePolicy = pixzig.ScalePolicy;
pub const WindowState = window_mod.WindowState;
pub const InputOptions = pixzig.InputOptions;
pub const PixzigEngineOptions = pixzig.PixzigEngineOptions;
pub const PixzigEngineInitOptions = pixzig.PixzigEngineInitOptions;

/// Input types and the platform window handle. Named `input` (not `glfw`)
/// because there is no GLFW here: `Key` / `MouseButton` are this backend's
/// own enums and `Window` wraps an `SDL_Window`. Callers name keys as
/// `pixzig.input.Key.escape`, mouse buttons as `pixzig.input.MouseButton`.
pub const input = struct {
    pub const Window = platform_mod.Window;
    pub const Key = input_mod.Key;
    pub const MouseButton = input_mod.MouseButton;
};

const ResourceManager = pixzig.resources.ResourceManager;

fn sdlError(err: anyerror) anyerror {
    std.log.err("SDL3: {s}", .{sdl.SDL_GetError()});
    return err;
}

fn glProcAddress(proc_name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const ptr = sdl.SDL_GL_GetProcAddress(proc_name);
    return @ptrCast(ptr);
}

pub fn PixzigAppRunner(comptime AppData: type, comptime engOpts: PixzigEngineOptions) type {
    return struct {
        pub const Engine = PixzigEngine(engOpts);

        engine: *Engine,
        alloc: std.mem.Allocator,
        lag: f64 = 0,
        currTime: f64 = 0,

        const UpdateStepMs = 1000.0 / engOpts.updateStepHz;
        const Self = @This();

        pub fn init(
            title: [:0]const u8,
            alloc: std.mem.Allocator,
            engInitOpts: PixzigEngineInitOptions,
        ) !*Self {
            const runner = try alloc.create(Self);
            errdefer alloc.destroy(runner);
            runner.* = .{
                .engine = try Engine.init(title, alloc, engInitOpts),
                .alloc = alloc,
                .currTime = @as(f64, @floatFromInt(sdl.SDL_GetTicksNS())) / 1_000_000.0,
            };
            return runner;
        }

        pub fn deinit(self: *Self) void {
            self.engine.deinit();
            self.alloc.destroy(self);
        }

        pub fn gameLoopCore(self: *Self, app: *AppData) bool {
            const new_time = @as(f64, @floatFromInt(sdl.SDL_GetTicksNS())) / 1_000_000.0;
            const delta = new_time - self.currTime;
            self.currTime = new_time;
            self.lag += delta;

            self.engine.pollEvents();
            self.engine.refreshWindowState();

            while (self.lag > UpdateStepMs) {
                self.lag -= UpdateStepMs;
                self.engine.inputs.update(self.engine.window, self.engine.window_state.scale_factor, &self.engine.viewport);
                const keep_running = app.update(self.engine, UpdateStepMs);
                self.engine.inputs.finishTick();
                if (!keep_running) return false;
            }

            app.render(self.engine);
            self.engine.window.swapBuffers();
            return true;
        }

        pub fn gameLoop(self: *Self, app: *AppData) void {
            while (!self.engine.window.shouldClose()) {
                if (!self.gameLoopCore(app)) return;
            }
        }

        pub fn run(self: *Self, app: *AppData) void {
            std.log.info("Starting SDL3 main loop...", .{});
            self.gameLoop(app);
            app.deinit();
            self.deinit();
        }
    };
}

pub fn PixzigEngine(comptime engOpts: PixzigEngineOptions) type {
    return struct {
        window: *platform_mod.Window,
        options: PixzigEngineInitOptions,
        scaleFactor: f32,
        allocator: std.mem.Allocator,
        projMat: zmath.Mat,
        window_state: WindowState,
        viewport: Viewport,
        resources: ResourceManager,
        inputs: input_mod.InputManager,
        renderer: Renderer = undefined,
        audio: void = {},
        manifest: void = {},

        const Self = @This();
        pub const Renderer = renderer.Renderer(engOpts.rendererOpts);

        pub fn init(title: [:0]const u8, allocator: std.mem.Allocator, options: PixzigEngineInitOptions) !*Self {
            if (comptime engOpts.audioOpts.enabled) @compileError("host_eng SDL facade does not carry pixzig audio");
            if (comptime engOpts.manifestOpts != null) @compileError("host_eng SDL facade does not carry pixzig manifests");

            if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) return sdlError(error.SdlInitFailed);
            errdefer sdl.SDL_Quit();

            const gl_major: c_int = if (builtin.target.os.tag == .emscripten) 2 else 4;
            const gl_minor: c_int = if (builtin.target.os.tag == .emscripten) 0 else 5;

            if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, gl_major)) return sdlError(error.SdlGlAttributeFailed);
            if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, gl_minor)) return sdlError(error.SdlGlAttributeFailed);
            if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE)) return sdlError(error.SdlGlAttributeFailed);
            if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_FLAGS, sdl.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG)) return sdlError(error.SdlGlAttributeFailed);
            if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 1)) return sdlError(error.SdlGlAttributeFailed);

            const window = try platform_mod.Window.create(allocator, title, options);
            errdefer window.destroy();
            if (!sdl.SDL_GL_MakeCurrent(window.handle, window.gl_context)) return sdlError(error.SdlMakeCurrentFailed);
            if (!sdl.SDL_StartTextInput(window.handle)) return sdlError(error.SdlTextInputFailed);

            std.log.info("Loading OpenGL profile.", .{});
            if (builtin.target.os.tag == .emscripten) {
                try zopengl.loadEsProfile(glProcAddress, @intCast(gl_major), @intCast(gl_minor));
                try zopengl.loadEsExtension(glProcAddress, .OES_vertex_array_object);
            } else {
                try zopengl.loadCoreProfile(glProcAddress, @intCast(gl_major), @intCast(gl_minor));
            }

            const gl_version = gl.getString(gl.VERSION);
            const glsl_version = gl.getString(gl.SHADING_LANGUAGE_VERSION);
            std.log.info("GL Version: {s}", .{gl_version});
            std.log.info("GLSL Version: {s}", .{glsl_version});

            const ws = WindowState.init(window);
            const logical_size = options.logicalSize orelse ws.framebuffer_size;
            const vp = Viewport.init(logical_size, ws.framebuffer_size, options.scalePolicy);
            vp.apply();

            const fb_w: f32 = @floatFromInt(ws.framebuffer_size.x);
            const fb_h: f32 = @floatFromInt(ws.framebuffer_size.y);
            const proj_mat = if (options.logicalSize == null)
                zmath.mul(
                    zmath.scaling(engOpts.gameScale, engOpts.gameScale, 1.0),
                    zmath.orthographicOffCenterLhGl(0, fb_w, 0, fb_h, -0.1, 1000),
                )
            else
                vp.projection();

            stbi.init(allocator);
            errdefer stbi.deinit();

            const eng = try allocator.create(Self);
            eng.* = .{
                .window = window,
                .options = options,
                .scaleFactor = @max(ws.scale_factor.x, ws.scale_factor.y),
                .allocator = allocator,
                .projMat = proj_mat,
                .window_state = ws,
                .viewport = vp,
                .resources = ResourceManager.init(allocator),
                .inputs = input_mod.InputManager.init(engOpts.inputOpts),
                .audio = {},
                .manifest = {},
            };
            errdefer {
                eng.resources.deinit();
                allocator.destroy(eng);
            }

            eng.renderer = try Renderer.init(allocator, &eng.resources, options.renderInitOpts);
            errdefer eng.renderer.deinit();
            eng.enableVSync(engOpts.vsyncEnabled);

            return eng;
        }

        pub fn deinit(self: *Self) void {
            self.renderer.deinit();
            self.resources.deinit();
            stbi.deinit();
            self.window.destroy();
            sdl.SDL_Quit();
            self.allocator.destroy(self);
        }

        pub fn pollEvents(self: *Self) void {
            var event: sdl.SDL_Event = undefined;
            while (sdl.SDL_PollEvent(&event)) {
                switch (event.type) {
                    sdl.SDL_EVENT_QUIT => self.window.close_requested = true,
                    sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.window.close_requested = true,
                    sdl.SDL_EVENT_WINDOW_RESIZED,
                    sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
                    sdl.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
                    => self.window_state.resized = true,
                    else => self.inputs.handleEvent(event),
                }
            }
        }

        pub fn setIcon(self: *Self, icon_data: *std.Io.Reader) !void {
            _ = self;
            _ = icon_data;
        }

        pub fn enableVSync(self: *Self, enabled: bool) void {
            _ = self;
            if (!sdl.SDL_GL_SetSwapInterval(if (enabled) 1 else 0)) {
                std.log.warn("SDL_GL_SetSwapInterval failed: {s}", .{sdl.SDL_GetError()});
            }
        }

        pub fn showCursor(self: *Self, visible: bool) void {
            _ = self;
            _ = if (visible) sdl.SDL_ShowCursor() else sdl.SDL_HideCursor();
        }

        pub fn defaultFontAtlas(self: *Self) ?*renderer.FontAtlas {
            return self.renderer.defaultFontAtlas();
        }

        pub fn refreshWindowState(self: *Self) void {
            if (!self.window_state.resized) return;
            self.window_state.resized = false;
            self.window_state.refresh(self.window);

            if (self.options.logicalSize == null) {
                self.viewport.logical_size = self.window_state.framebuffer_size;
            }
            const fbsz = self.window_state.framebuffer_size;
            self.viewport.updateFramebufferSize(fbsz);

            gl.disable(gl.SCISSOR_TEST);
            self.renderer.clear(0, 0, 0, 1);
            self.viewport.apply();

            self.scaleFactor = @max(self.window_state.scale_factor.x, self.window_state.scale_factor.y);
            if (self.options.logicalSize == null) {
                const fw: f32 = @floatFromInt(self.window_state.framebuffer_size.x);
                const fh: f32 = @floatFromInt(self.window_state.framebuffer_size.y);
                self.projMat = zmath.mul(
                    zmath.scaling(engOpts.gameScale, engOpts.gameScale, 1.0),
                    zmath.orthographicOffCenterLhGl(0, fw, 0, fh, -0.1, 1000),
                );
            } else {
                self.projMat = self.viewport.projection();
            }
        }

        pub fn projection(self: *const Self) zmath.Mat {
            return self.viewport.projection();
        }

        pub fn screenProjection(self: *const Self) zmath.Mat {
            const fw: f32 = @floatFromInt(self.window_state.framebuffer_size.x);
            const fh: f32 = @floatFromInt(self.window_state.framebuffer_size.y);
            return zmath.orthographicOffCenterLhGl(0, fw, 0, fh, -0.1, 1000);
        }

        pub fn windowToFramebuffer(self: *const Self, pos: Vec2F) Vec2F {
            return .{
                .x = pos.x * self.window_state.scale_factor.x,
                .y = pos.y * self.window_state.scale_factor.y,
            };
        }

        pub fn windowToLogical(self: *const Self, pos: Vec2F) ?Vec2F {
            return self.viewport.framebufferToLogical(self.windowToFramebuffer(pos));
        }
    };
}
