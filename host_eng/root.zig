const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const core = @import("core.zig");

const input_mod = @import("input.zig");
const platform_mod = @import("platform_sdl.zig");
const window_mod = @import("window.zig");

pub const gl = core.gl;
pub const zopengl = core.zopengl;
pub const zmath = core.zmath;
pub const stbi = core.stbi;
pub const renderer = core.renderer;
pub const shaders = core.shaders;
pub const resources = core.resources;
pub const system = core.system;
pub const ziglua = core.ziglua;

pub const Texture = core.Texture;
pub const ManagedTexture = core.ManagedTexture;
pub const ManagedShader = core.ManagedShader;
pub const Vec2I = core.Vec2I;
pub const Vec2F = core.Vec2F;
pub const RectI = core.RectI;
pub const RectF = core.RectF;
pub const Color = core.Color;
pub const Color8 = core.Color8;
pub const Viewport = core.Viewport;
pub const ScalePolicy = core.ScalePolicy;
pub const WindowState = window_mod.WindowState;
pub const InputOptions = core.InputOptions;
pub const EngineOptions = core.EngineOptions;
pub const EngineInitOptions = core.EngineInitOptions;

/// Input types and the platform window handle. `Key` / `MouseButton` are
/// this backend's own enums and `Window` wraps an `SDL_Window`. Callers
/// name keys as `host_eng.input.Key.escape`, mouse buttons as
/// `host_eng.input.MouseButton`.
pub const input = struct {
    pub const Window = platform_mod.Window;
    pub const Key = input_mod.Key;
    pub const MouseButton = input_mod.MouseButton;
    pub const Keyboard = input_mod.Keyboard;
    pub const Mouse = input_mod.Mouse;
    pub const InputManager = input_mod.InputManager;
};

const ResourceManager = core.resources.ResourceManager;

fn glProcAddress(proc_name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const ptr = sdl.SDL_GL_GetProcAddress(proc_name);
    return @ptrCast(ptr);
}

pub fn AppRunner(comptime AppData: type, comptime engOpts: EngineOptions) type {
    return struct {
        pub const Engine = EngineType(engOpts);

        engine: *Engine,
        alloc: std.mem.Allocator,
        lag: f64 = 0,
        currTime: f64 = 0,
        /// `redrawOnDemand` only: cleared once the first frame has been
        /// drawn. The idle wait at the top of `gameLoopCore` is skipped
        /// until then so startup always paints one frame without waiting
        /// on an OS event.
        drew_once: bool = false,

        const UpdateStepMs = 1000.0 / engOpts.updateStepHz;
        const Self = @This();

        pub fn init(
            title: [:0]const u8,
            alloc: std.mem.Allocator,
            engInitOpts: EngineInitOptions,
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

        /// Upper bound on the simulated time a single iteration will try to
        /// catch up on, in `redrawOnDemand` mode. Without it, a loop that
        /// blocked for seconds waiting on an event would then run hundreds
        /// of fixed update steps in one burst.
        const MaxCatchupMs = 100.0;

        pub fn gameLoopCore(self: *Self, app: *AppData) bool {
            // Optional frame-timing hooks: an `AppData` that declares them
            // (glyphwire-host does -- see `host/profiler.zig`) gets the
            // per-iteration boundary plus the `waitEvents` / `swapBuffers`
            // durations the loop is the only place that can measure. Any
            // other app compiles these out entirely.
            const prof = comptime @hasDecl(AppData, "profileFrameStart");
            if (comptime prof) app.profileFrameStart();

            if (comptime engOpts.redrawOnDemand) {
                if (self.drew_once) {
                    // Idle until an OS event arrives, `Engine.wakeEventLoop`
                    // is called from another thread, or the app's own
                    // timeout elapses (a blinking caret, a pending
                    // screenshot).
                    if (comptime prof) {
                        if (app.profileActive()) {
                            const t0 = app.profileNow();
                            self.engine.waitEvents(app.idleTimeoutMs());
                            app.profileWait(t0);
                        } else {
                            self.engine.waitEvents(app.idleTimeoutMs());
                        }
                    } else {
                        self.engine.waitEvents(app.idleTimeoutMs());
                    }
                }
            }

            const new_time = @as(f64, @floatFromInt(sdl.SDL_GetTicksNS())) / 1_000_000.0;
            var delta = new_time - self.currTime;
            self.currTime = new_time;
            if (comptime engOpts.redrawOnDemand) {
                if (delta > MaxCatchupMs) delta = MaxCatchupMs;
            }
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

            if (comptime engOpts.redrawOnDemand) {
                if (self.drew_once and !app.needsRedraw(self.engine)) return true;
            }
            app.render(self.engine);
            if (comptime prof) {
                if (app.profileActive()) {
                    const t0 = app.profileNow();
                    self.engine.window.swapBuffers();
                    app.profileSwap(t0);
                } else {
                    self.engine.window.swapBuffers();
                }
            } else {
                self.engine.window.swapBuffers();
            }
            self.drew_once = true;
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

/// Builds the engine type for a given set of compile-time options.
/// `AppRunner` instantiates one and re-exports it as `AppRunner.Engine`,
/// which is how host code normally names it.
pub fn EngineType(comptime engOpts: EngineOptions) type {
    return struct {
        window: *platform_mod.Window,
        options: EngineInitOptions,
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

        pub fn init(title: [:0]const u8, allocator: std.mem.Allocator, options: EngineInitOptions) !*Self {
            if (comptime engOpts.audioOpts.enabled) @compileError("host_eng does not carry an audio engine");
            if (comptime engOpts.manifestOpts != null) @compileError("host_eng does not carry an asset manifest");
            if (comptime engOpts.inputOpts.numGamepads > 0) @compileError("host_eng does not carry gamepad support");

            if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) return platform_mod.sdlError(error.SdlInitFailed);
            errdefer sdl.SDL_Quit();

            const gl_major: c_int, const gl_minor: c_int = if (builtin.target.os.tag == .emscripten)
                .{ 2, 0 }
            else
                .{ 4, 5 };

            if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, gl_major)) return platform_mod.sdlError(error.SdlGlAttributeFailed);
            if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, gl_minor)) return platform_mod.sdlError(error.SdlGlAttributeFailed);
            if (builtin.target.os.tag == .emscripten) {
                // WebGL comes through SDL's GLES profile; the core and
                // forward-compatible flags the desktop path sets are not
                // valid there, and asking for 2.0 *core* is a contradiction
                // SDL would have had to refuse.
                if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_ES)) return platform_mod.sdlError(error.SdlGlAttributeFailed);
            } else {
                if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE)) return platform_mod.sdlError(error.SdlGlAttributeFailed);
                if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_FLAGS, sdl.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG)) return platform_mod.sdlError(error.SdlGlAttributeFailed);
            }
            if (!sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 1)) return platform_mod.sdlError(error.SdlGlAttributeFailed);

            const window = try platform_mod.Window.create(allocator, title, options, engOpts.inputOpts.textInput);
            errdefer window.destroy();

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
            eng.inputs.seedMousePos();

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
                    // An event-driven key bitset latches where per-frame
                    // polling self-healed, so anything held when the window
                    // loses focus would otherwise stay down forever.
                    sdl.SDL_EVENT_WINDOW_FOCUS_LOST => self.inputs.clear(),
                    // `wakeEventLoop`'s nudge from another thread: its only
                    // job was to break the wait above so the loop re-checks
                    // its redraw state -- nothing to handle here.
                    sdl.SDL_EVENT_USER => {},
                    else => self.inputs.handleEvent(event),
                }
            }
        }

        /// Blocks until the next OS event, a `wakeEventLoop` nudge, or
        /// `timeout_ms` elapses (null = no timeout). Used by
        /// `gameLoopCore` only when `engOpts.redrawOnDemand` is set; the
        /// event it unblocks on is left on the queue for `pollEvents` to
        /// drain normally.
        pub fn waitEvents(self: *Self, timeout_ms: ?f64) void {
            _ = self;
            if (timeout_ms) |ms| {
                const clamped: i32 = @intFromFloat(@max(1.0, @min(ms, @as(f64, std.math.maxInt(i32)))));
                _ = sdl.SDL_WaitEventTimeout(null, clamped);
            } else {
                _ = sdl.SDL_WaitEvent(null);
            }
        }

        /// Pushes an empty user event so a loop parked in `waitEvents`
        /// wakes and re-evaluates. Safe to call from any thread (SDL's
        /// event queue is internally locked) -- the server's wake callback
        /// (see `host/main.zig`) routes through here from a connection
        /// thread.
        pub fn wakeEventLoop(self: *Self) void {
            _ = self;
            var event: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
            event.type = sdl.SDL_EVENT_USER;
            _ = sdl.SDL_PushEvent(&event);
        }

        /// Sets the window icon from an encoded image (PNG or anything
        /// else stbi decodes). There is no default icon: host_eng ships no
        /// assets of its own, so a host that wants one calls this with its
        /// own image.
        pub fn setIcon(self: *Self, icon_data: *std.Io.Reader) !void {
            const encoded = try icon_data.readAlloc(self.allocator, icon_data.end);
            defer self.allocator.free(encoded);

            var image = try stbi.Image.loadFromMemory(encoded, 4);
            defer image.deinit();

            self.window.setIcon(&image);
        }

        pub fn enableVSync(self: *Self, enabled: bool) void {
            _ = self;
            if (!sdl.SDL_GL_SetSwapInterval(if (enabled) 1 else 0)) {
                std.log.warn("SDL_GL_SetSwapInterval failed: {s}", .{sdl.SDL_GetError()});
            }
        }

        /// Shows or hides the system cursor. Global in SDL3 rather than
        /// per-window; nothing here depends on the difference, since the
        /// engine only ever owns one window.
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
