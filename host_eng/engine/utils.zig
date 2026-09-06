//! Utility/helper functions and structures that don't fit into other categories.
const std = @import("std");

/// A structure for tracking frames per second (FPS) in a game. It keeps track
///  of the elapsed time, the number of frames rendered, and calculates the
/// FPS based on the elapsed time.
pub const FpsCounter = struct {
    mElapsed: f64,
    mFrames: u32,
    mTotalFrames: u64,
    mFps: u32,

    /// Initializes the FPS counter with default values. The elapsed time is
    /// set to 0, the frame count is set to 0, and the FPS is set to 0.
    pub fn init() FpsCounter {
        return .{ .mFps = 0, .mElapsed = 0, .mFrames = 0, .mTotalFrames = 0 };
    }

    /// Updates the FPS counter with the elapsed time since the last update.
    /// It adds the elapsed time to the total elapsed time and increments the
    /// frame count. If the total elapsed time exceeds 1000 milliseconds (1
    /// second), it calculates the FPS by taking the number of frames rendered
    /// in that time period, resets the frame count, and subtracts 1000
    /// milliseconds from the total elapsed time. It returns true if the FPS
    /// was updated (i.e., if a second has passed), and false otherwise.
    pub fn update(self: *FpsCounter, elapsed: f64) bool {
        self.mElapsed += elapsed;
        if (self.mElapsed > 1000.0) {
            self.mFps = self.mFrames;
            self.mFrames = 0;
            self.mElapsed -= 1000.0;
            return true;
        }

        return false;
    }

    /// Increments the total frame count by 1. This should be called every
    /// time a frame is rendered, regardless of whether the FPS was updated
    /// or not.
    pub fn renderTick(self: *FpsCounter) void {
        self.mFrames += 1;
    }

    /// Returns the current FPS value, which is the number of frames rendered
    /// in the last second. This value is updated every time the update
    /// function is called and the elapsed time exceeds 1000 milliseconds.
    pub fn fps(self: *FpsCounter) u32 {
        return self.mFps;
    }

    pub fn totalFrames(self: *FpsCounter) u32 {
        return self.mTotalFrames;
    }
};

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

/// Converts a null-terminated C string to a Zig slice. The caller is
/// responsible for ensuring that the C string is valid and null-terminated.
pub fn cStrToSlice(c_str: [*:0]const u8) []const u8 {
    const length = std.mem.len(c_str);
    return c_str[0..length];
}

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
