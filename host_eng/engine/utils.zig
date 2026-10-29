// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Utility/helper functions and structures that don't fit into other categories.
const std = @import("std");

/// A structure for tracking a delay in terms of frames. You can specify a
/// maximum number of frames to wait, and then call update with the number
/// of frames that have passed. When the current frame count exceeds the
/// maximum, it resets and returns true.
pub const Delay = struct {
    curr: usize = 0,
    max: usize,

    /// Updates the delay by adding the given number to the current value.
    /// If the current value exceeds the maximum, it resets the current value
    /// to 0 and returns true. Otherwise, it returns false.
    pub fn update(self: *Delay, num: usize) bool {
        self.curr += num;
        if (self.curr > self.max) {
            self.curr = 0;
            return true;
        }

        return false;
    }
};

/// A structure for tracking a delay so you can wait some amount of time
/// before triggering something in your game update loop.
pub const DelayF = struct {
    curr: f64 = 0,
    max: f64,

    /// Updates the delay by adding the given number to the current value.
    /// If the current value exceeds the maximum, it resets the current value
    /// to 0 and returns true. Otherwise, it returns false.
    pub fn update(self: *DelayF, num: f64) bool {
        self.curr += num;
        if (self.curr > self.max) {
            self.curr = 0;
            return true;
        }

        return false;
    }
};

/// Removes the starting path and end extension from the given path
pub fn baseNameFromPath(path: []const u8) []const u8 {
    const rootName = blk: {
        const lastIndex = std.mem.lastIndexOf(u8, path, "/");
        if (lastIndex != null) {
            break :blk path[lastIndex.? + 1 ..];
        } else {
            break :blk path;
        }
    };

    const name = blk: {
        const lastIndex = std.mem.lastIndexOf(u8, rootName, ".");
        if (lastIndex != null) {
            break :blk rootName[0..lastIndex.?];
        } else {
            break :blk rootName;
        }
    };

    return name;
}

/// Adds the extension to the path, caller is responsible for freeing.
pub fn addExtension(alloc: std.mem.Allocator, path: []const u8, ext: []const u8) ![]const u8 {
    return try std.mem.concat(alloc, u8, &[_][]const u8{ path, ext });
}
