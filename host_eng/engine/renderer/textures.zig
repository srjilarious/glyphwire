// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const common = @import("../common.zig");

const Vec2U = common.Vec2U;
const RectF = common.RectF;

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
