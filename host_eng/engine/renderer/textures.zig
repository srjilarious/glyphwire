// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

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
