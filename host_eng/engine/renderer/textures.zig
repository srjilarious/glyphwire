const std = @import("std");
const stbi = @import("zstbi");
const gl = @import("zopengl").bindings;
const common = @import("../common.zig");
const utils = @import("../utils.zig");
const shaders = @import("./shaders.zig");

const Shader = shaders.Shader;
const Vec2U = common.Vec2U;
const Vec2I = common.Vec2I;
const Color8 = common.Color8;
const RectF = common.RectF;
const RectI = common.RectI;

pub const TextureImage = struct {
    // GL Texture ID once loaded.
    texture: c_uint,
    size: Vec2U,
};

pub const Texture = struct {
    texture: c_uint,
    size: Vec2U,
    src: RectF,

    pub fn sub(self: *const Texture, coords: RectF) Texture {
        const w: u32 = @intFromFloat(coords.width() * @as(f32, @floatFromInt(self.size.x)));
        const h: u32 = @intFromFloat(coords.height() * @as(f32, @floatFromInt(self.size.y)));
        return .{
            .texture = self.texture,
            .size = .{ .x = w, .y = h },
            .src = coords,
        };
    }
};

pub const CharToColor = struct {
    char: u8,
    color: Color8,
};

// A sprite pack file.
pub const SpackFile = struct { frames: []SpackFrame };

// A sprite frame as stored in an atlas json file.
pub const SpackFrame = struct {
    name: []u8,
    sizePx: Vec2U,
    pos: RectI,
};

pub fn blit(dest: []u8, destSize: Vec2U, src: []const u8, srcSize: Vec2U, offsetIntoBuffer: Vec2U) void {
    var srcIdx: usize = 0;
    const lineLen: usize = srcSize.x * 4;
    const destLineLen: usize = destSize.x * 4;
    var destIdx: usize = (offsetIntoBuffer.y * destSize.x + offsetIntoBuffer.x) * 4;

    // Copy each line of the source image into the dest.
    while (srcIdx < src.len) {
        @memcpy(dest[destIdx .. destIdx + lineLen], src[srcIdx .. srcIdx + lineLen]);
        srcIdx += lineLen;
        destIdx += destLineLen;
    }
}

pub fn drawBufferFromChars(buffer: []u8, buffSize: Vec2U, chars: []const u8, charsSize: Vec2U, offsetIntoBuffer: Vec2U, mapping: []const CharToColor) void {
    // Manually track the index since we need to skip newlines.
    var chrIdx: usize = 0;
    var h: usize = offsetIntoBuffer.y;
    var w: usize = offsetIntoBuffer.x;

    while (chrIdx < chars.len) {
        const curr_ch = chars[chrIdx];
        chrIdx += 1;

        // Skip over newlines from raw literals
        if (curr_ch == '\n' or curr_ch == '\r') continue;

        // Find the color for the char.
        var color: Color8 = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        for (0..mapping.len) |idx| {
            if (mapping[idx].char == curr_ch) {
                color = mapping[idx].color;
            }
        }

        const col_idx: usize = (h * buffSize.x + w) * 4;
        buffer[col_idx] = color.r;
        buffer[col_idx + 1] = color.g;
        buffer[col_idx + 2] = color.b;
        buffer[col_idx + 3] = color.a;

        // Update pixel buffer locations.
        w += 1;
        if (w >= (offsetIntoBuffer.x + charsSize.x)) {
            w = offsetIntoBuffer.x;
            h += 1;
        }
    }
}
