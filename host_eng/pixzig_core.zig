pub const stbi = @import("zstbi");
pub const zopengl = @import("zopengl");
pub const gl = zopengl.bindings;
pub const zmath = @import("zmath");
pub const ziglua = @import("ziglua");

pub const common = @import("pixzig_src/common.zig");
pub const renderer = @import("pixzig_src/renderer.zig");
pub const shaders = @import("pixzig_src/renderer/shaders.zig");
pub const textures = @import("pixzig_src/renderer/textures.zig");
pub const resources = @import("pixzig_src/resources.zig");
pub const system = @import("pixzig_src/system.zig");

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
    numGamepads: u8 = 0,
};

pub const PixzigEngineOptions = struct {
    defaultIcon: bool = true,
    vsyncEnabled: bool = true,
    gameScale: f32 = 1.0,
    updateStepHz: f64 = 120.0,
    rendererOpts: renderer.RendererOptions = .{},
    audioOpts: struct { enabled: bool = false } = .{},
    inputOpts: InputOptions = .{},
    manifestOpts: ?type = null,
};

pub const PixzigEngineInitOptions = struct {
    fullscreen: bool = false,
    windowSize: Vec2I = .{ .x = 800, .y = 480 },
    resizable: bool = true,
    logicalSize: ?Vec2I = null,
    scalePolicy: ScalePolicy = .fit,
    renderInitOpts: renderer.RendererInitOpts = .{},
};
