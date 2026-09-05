const std = @import("std");
const common = @import("../common.zig");
const textures = @import("./textures.zig");
const resources = @import("../resources.zig");

const Vec2I = common.Vec2I;
const Vec2F = common.Vec2F;
const RectF = common.RectF;
const Rotate = common.Rotate;

const Texture = textures.Texture;
const ResourceManager = resources.ResourceManager;
const ManagedTexture = resources.ManagedTexture;
const TextureHandle = resources.TextureHandle;

pub const Sprite = struct {
    /// Owning handle to a managed texture, transferred in by `create`. Call
    /// `deinit()` when the sprite is no longer needed to release it.
    texture: *TextureHandle,
    src_coords: RectF,
    dest: RectF,
    size: Vec2F,
    flip: Flip,
    rotate: Rotate,

    /// Takes ownership of `tex` (an already-acquired handle). The sprite
    /// releases it in `deinit()`; the caller must not release it separately.
    pub fn create(tex: *TextureHandle, size: Vec2F) Sprite {
        return Sprite{
            .texture = tex,
            .src_coords = tex.val.src,
            .dest = RectF.fromPosSize(0, 0, @as(i32, @intFromFloat(size.x)), @as(i32, @intFromFloat(size.y))),
            .size = size,
            .flip = .none,
            .rotate = .none,
        };
    }

    /// Releases the sprite's texture handle. Call exactly once, when the
    /// sprite is no longer needed.
    pub fn deinit(self: *Sprite) void {
        self.texture.release();
    }

    pub fn setPos(self: *Sprite, x: i32, y: i32) void {
        self.dest = RectF.fromPosSize(x, y, @as(i32, @intFromFloat(self.size.x)), @as(i32, @intFromFloat(self.size.y)));
    }
};

/// A enum for flipping sprites.
pub const Flip = enum {
    none,
    horz,
    vert,
    both,
};

pub const Frame = struct {
    tex: *TextureHandle,
    frameTimeMs: f64,
    flip: Flip,

    pub fn apply(self: *Frame, spr: *Sprite, extraFlip: Flip) void {
        const src = self.tex.val.src;
        const flip = blk: {
            switch (self.flip) {
                .none => break :blk extraFlip,
                .horz => {
                    switch (extraFlip) {
                        .none => break :blk .horz,
                        .horz => break :blk .none,
                        .vert => break :blk .both,
                        .both => break :blk .vert,
                    }
                },
                .vert => {
                    switch (extraFlip) {
                        .none => break :blk .vert,
                        .horz => break :blk .both,
                        .vert => break :blk .none,
                        .both => break :blk .horz,
                    }
                },
                .both => {
                    switch (extraFlip) {
                        .none => break :blk .both,
                        .horz => break :blk .vert,
                        .vert => break :blk .horz,
                        .both => break :blk .none,
                    }
                },
            }
        };

        switch (flip) {
            .none => spr.src_coords = src,
            .horz => {
                spr.src_coords = .{ .l = src.r, .t = src.t, .r = src.l, .b = src.b };
            },
            .vert => {
                spr.src_coords = .{ .l = src.l, .t = src.b, .r = src.r, .b = src.t };
            },
            .both => {
                spr.src_coords = .{ .l = src.r, .t = src.b, .r = src.l, .b = src.t };
            },
        }
    }
};

pub const AnimPlayMode = enum { loop, once };

pub const SpriteRenderOffset = enum { none, sequence, horzCenterBottomAligned };

pub const ActorState = struct {
    name: []const u8,
    nextState: ?[]const u8 = null,
    sequence: *const FrameSequence,
    flip: Flip = .none,
};

pub const FrameSequence = struct {
    frames: std.ArrayList(Frame),
    alloc: std.mem.Allocator,
    mode: AnimPlayMode,
    /// When true, `deinit` releases each frame's texture handle. Set for
    /// sequences loaded from JSON where this struct acquired the handles.
    ownsHandles: bool = false,

    pub fn initEmpty(alloc: std.mem.Allocator) !FrameSequence {
        const frames: std.ArrayList(Frame) = .empty;

        return .{
            .frames = frames,
            .alloc = alloc,
            .mode = .loop,
        };
    }

    pub fn init(alloc: std.mem.Allocator, framesArr: []const Frame) !FrameSequence {
        var frames: std.ArrayList(Frame) = .empty;
        errdefer frames.deinit(alloc);
        for (framesArr) |fr| {
            try frames.append(alloc, fr);
        }

        return .{
            .frames = frames,
            .alloc = alloc,
            .mode = .loop,
        };
    }

    pub fn deinit(self: *FrameSequence) void {
        if (self.ownsHandles) {
            for (self.frames.items) |frame| {
                frame.tex.release();
            }
        }
        self.frames.deinit(self.alloc);
    }
};

pub const FrameSequenceFile = struct {
    sequences: []FileFrameSequence,
    states: []FileActorState,
};

pub const FileFrameSequence = struct {
    mode: AnimPlayMode,
    name: []const u8,
    frames: []FileFrame,
};

pub const FileFrame = struct {
    name: []const u8,
    ms: f64,
    flip: ?Flip,
};

pub const FileActorState = struct {
    name: []const u8,
    nextStateName: ?[]const u8 = null,

    frameSeqName: []const u8,
    flip: Flip,
};

pub const FrameSequenceManager = struct {
    // We expand from the file frame which uses the name of a texture
    // and fill in the coords for the image.
    sequences: std.StringHashMap(*FrameSequence),
    actorStates: std.StringHashMap(*ActorState),

    alloc: std.mem.Allocator,

    const Self = FrameSequenceManager;

    pub fn init(alloc: std.mem.Allocator) !Self {
        return .{
            .sequences = std.StringHashMap(*FrameSequence).init(alloc),
            .actorStates = std.StringHashMap(*ActorState).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up frame sequences.
        var iterator = self.sequences.iterator();
        while (iterator.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit();
            self.alloc.destroy(kv.value_ptr.*);
        }
        self.sequences.deinit();

        // Clean up actor states.
        var stateIt = self.actorStates.iterator();
        while (stateIt.next()) |kv| {
            self.alloc.free(kv.value_ptr.*.name);
            if (kv.value_ptr.*.nextState) |nextState| {
                self.alloc.free(nextState);
            }

            // kv.value_ptr.deinit();
            self.alloc.destroy(kv.value_ptr.*);
        }
        self.actorStates.deinit();
    }

    pub fn loadSequenceFile(self: *Self, filename: []const u8, texMgr: *ResourceManager) !void {
        // Load file contents
        const io = std.Io.Threaded.global_single_threaded.io();
        const file_contents = try std.Io.Dir.cwd().readFileAlloc(io, filename, self.alloc, .unlimited);
        defer self.alloc.free(file_contents);

        // Load sequence
        try self.loadSequence(file_contents, texMgr);
    }

    pub fn loadSequence(self: *Self, json_contents: []const u8, texMgr: *ResourceManager) !void {
        const parsed = try std.json.parseFromSlice(FrameSequenceFile, self.alloc, json_contents, .{});
        defer parsed.deinit();

        // First load the frame sequences, since actor states need those for looking up.
        for (parsed.value.sequences) |fileSeq| {
            var seq = try FrameSequence.initEmpty(self.alloc);
            seq.ownsHandles = true;
            // addSeq takes a shallow-copy of seq; on failure it just destroys the
            // allocation, so we remain responsible for freeing the frames backing array.
            errdefer seq.deinit();
            for (fileSeq.frames) |fileFrame| {
                try seq.frames.append(self.alloc, .{
                    .tex = try texMgr.acquireTexture(fileFrame.name),
                    .frameTimeMs = fileFrame.ms,
                    .flip = fileFrame.flip orelse .none,
                });
            }
            try self.addSeq(fileSeq.name, seq);
        }

        // Next load the actor states
        for (parsed.value.states) |fileState| {
            try self.addState(.{
                .name = fileState.name,
                .nextState = fileState.nextStateName,
                .sequence = self.sequences.get(fileState.frameSeqName).?,
                .flip = fileState.flip,
            });
        }
    }

    pub fn addSeq(self: *Self, name: []const u8, seq: FrameSequence) !void {
        const new = try self.alloc.create(FrameSequence);
        new.* = seq;
        errdefer self.alloc.destroy(new);

        if (self.sequences.getPtr(name)) |oldPtr| {
            oldPtr.*.deinit();
            self.alloc.destroy(oldPtr.*);
            oldPtr.* = new;
            return;
        }

        const nameCopy = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(nameCopy);
        try self.sequences.put(nameCopy, new);
    }

    pub fn addState(self: *Self, state: ActorState) !void {
        const nextStateDupe: ?[]const u8 = if (state.nextState) |ns|
            try self.alloc.dupe(u8, ns)
        else
            null;
        errdefer if (nextStateDupe) |ns| self.alloc.free(ns);

        const new = try self.alloc.create(ActorState);
        errdefer self.alloc.destroy(new);
        new.* = state;
        new.nextState = nextStateDupe;

        if (self.actorStates.getPtr(state.name)) |oldPtr| {
            // deinit frees value.name (not the key), and they share the same
            // bytes, so reuse the old name allocation to keep the key valid.
            new.name = oldPtr.*.name;
            if (oldPtr.*.nextState) |ns| self.alloc.free(ns);
            self.alloc.destroy(oldPtr.*);
            oldPtr.* = new;
            return;
        }

        const nameDupe = try self.alloc.dupe(u8, state.name);
        errdefer self.alloc.free(nameDupe);
        new.name = nameDupe;
        try self.actorStates.put(nameDupe, new);
    }

    pub fn getSeq(self: *Self, name: []const u8) ?*const FrameSequence {
        return self.sequences.get(name);
    }

    pub fn getState(self: *Self, name: []const u8) ?*const ActorState {
        return self.actorStates.get(name);
    }
};

pub const AddStateOpts = struct {
    name: ?[]const u8 = null,
};

pub const Actor = struct {
    states: std.StringHashMap(*ActorState),
    alloc: std.mem.Allocator,
    currState: ?*ActorState,
    currFrame: i32,
    currFrameTimeMs: f64,
    actorSize: Vec2I,
    dirtyState: bool,

    pub fn init(alloc: std.mem.Allocator) !Actor {
        return .{ .states = std.StringHashMap(*ActorState).init(alloc), .alloc = alloc, .currState = null, .currFrame = 0, .currFrameTimeMs = 0, .actorSize = Vec2I{ .x = 0, .y = 0 }, .dirtyState = false };
    }

    pub fn deinit(self: *Actor) void {
        self.currState = null;
        var iterator = self.states.iterator();
        while (iterator.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            if (kv.value_ptr.*.nextState) |ns| self.alloc.free(ns);
            self.alloc.destroy(kv.value_ptr.*);
        }
        self.states.deinit();
    }

    pub fn addState(self: *Actor, state: *const ActorState, opts: AddStateOpts) !*Actor {
        const nameToUse = opts.name orelse state.name;

        const nextStateCopy: ?[]const u8 = if (state.nextState) |ns|
            try self.alloc.dupe(u8, ns)
        else
            null;
        errdefer if (nextStateCopy) |ns| self.alloc.free(ns);

        const val = try self.alloc.create(ActorState);
        errdefer self.alloc.destroy(val);
        val.* = state.*;
        val.nextState = nextStateCopy;

        if (self.states.getPtr(nameToUse)) |oldPtr| {
            // deinit frees the key (which == val.name), so reuse the old key
            // bytes as val.name to keep the key valid after we free the old entry.
            val.name = oldPtr.*.name;
            if (oldPtr.*.nextState) |ns| self.alloc.free(ns);
            if (self.currState == oldPtr.*) self.currState = val;
            self.alloc.destroy(oldPtr.*);
            oldPtr.* = val;
            return self;
        }

        const nameCopy = try self.alloc.dupe(u8, nameToUse);
        errdefer self.alloc.free(nameCopy);
        val.name = nameCopy;
        try self.states.put(nameCopy, val);
        if (self.currState == null) {
            self.currState = val;
        }

        return self;
    }

    pub fn setState(self: *Actor, name: []const u8) void {
        // Don't reset the state if we're already on it.
        if (self.currState != null and std.mem.eql(u8, self.currState.?.name, name)) return;

        if (self.states.getPtr(name)) |state| {
            self.currState = state.*;
            self.currFrame = 0;
            self.currFrameTimeMs = 0;
        }
    }

    pub fn update(self: *Actor, deltaMs: f64, spr: *Sprite) void {
        if (self.currState == null) return;

        const currSeq = self.currState.?.sequence;
        const currFrame = &currSeq.frames.items[@intCast(self.currFrame)];
        self.currFrameTimeMs += deltaMs;
        if (self.currFrameTimeMs > currFrame.frameTimeMs) {
            self.currFrameTimeMs -= currFrame.frameTimeMs;
            self.currFrame += 1;
            if (self.currFrame >= currSeq.frames.items.len) {
                // TODO: Add in once behavior
                self.currFrame = 0;
            }

            currSeq.frames.items[@intCast(self.currFrame)].apply(spr, self.currState.?.flip);
        }
    }

    pub fn curr(self: *Actor) ?*Frame {
        if (self.currState == null) return null;

        const currSeq = self.currState.?.sequence;
        return &currSeq.frames.items[@intCast(self.currFrame)];
    }
};
