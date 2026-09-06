//! The namespace shim: one place for `root.zig`, `input.zig`,
//! `window.zig` and `platform_sdl.zig` to reach the backend-independent
//! engine pieces under `engine/` and the third-party modules, without
//! each of them spelling out relative paths.

pub const stbi = @import("zstbi");
pub const zopengl = @import("zopengl");
pub const gl = zopengl.bindings;
pub const zmath = @import("zmath");
pub const ziglua = @import("ziglua");

pub const common = @import("engine/common.zig");
pub const renderer = @import("engine/renderer.zig");
pub const shaders = @import("engine/renderer/shaders.zig");
pub const textures = @import("engine/renderer/textures.zig");
pub const resources = @import("engine/resources.zig");
pub const system = @import("engine/system.zig");

pub const Texture = textures.Texture;
pub const TextureImage = textures.TextureImage;
pub const ManagedTexture = resources.ManagedTexture;
pub const ManagedShader = resources.ManagedShader;
pub const ManagedFont = resources.ManagedFont;

pub const Vec2I = common.Vec2I;
pub const Vec2F = common.Vec2F;
pub const RectI = common.RectI;
pub const RectF = common.RectF;
pub const Color = common.Color;
pub const Color8 = common.Color8;

pub const Viewport = @import("viewport.zig").Viewport;
pub const ScalePolicy = @import("viewport.zig").ScalePolicy;

pub const InputOptions = struct {
    mouse: bool = true,
    /// Rejected at compile time when non-zero: host_eng carries no gamepad
    /// support. Kept in the struct so a caller that sets it gets a clear
    /// error rather than silent nothing.
    numGamepads: u8 = 0,
    /// Whether to arm the OS text-input machinery on the window. This is
    /// what makes `Keyboard.text()` produce anything and what enables IME
    /// composition (`Keyboard.preedit()`), so it defaults on -- a terminal
    /// front end has no use for a window that can't be typed into.
    textInput: bool = true,
};

pub const EngineOptions = struct {
    vsyncEnabled: bool = true,
    gameScale: f32 = 1.0,
    updateStepHz: f64 = 120.0,
    rendererOpts: renderer.RendererOptions = .{},
    audioOpts: struct { enabled: bool = false } = .{},
    inputOpts: InputOptions = .{},
    manifestOpts: ?type = null,
    /// Draw only when something changed instead of every iteration. With
    /// this on, the loop blocks in `SDL_WaitEvent(Timeout)` when idle and
    /// calls `AppData.render` + `swapBuffers` only when `AppData.needsRedraw`
    /// says a repaint is due; `AppData` must also expose
    /// `idleTimeoutMs() ?f64` (how long the loop may block before waking to
    /// re-check state a background thread might have changed -- null to
    /// block until an OS event or an `Engine.wakeEventLoop` call). Off by
    /// default: a game repaints continuously. glyphwire-host turns it on --
    /// a terminal is static most of the time. See decisions.md's "Redraw
    /// on change".
    redrawOnDemand: bool = false,
};

pub const EngineInitOptions = struct {
    fullscreen: bool = false,
    windowSize: Vec2I = .{ .x = 800, .y = 480 },
    resizable: bool = true,
    logicalSize: ?Vec2I = null,
    scalePolicy: ScalePolicy = .fit,
    renderInitOpts: renderer.RendererInitOpts = .{},
};
