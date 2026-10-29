// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The resource manager: ref-counted textures, shaders, atlases and
//! fonts, keyed by name. pixzig's tilemaps and asset hot-reload are not
//! carried.

const std = @import("std");
const stbi = @import("zstbi");
const gl = @import("zopengl").bindings;
const utils = @import("./utils.zig");
const shaders = @import("./renderer/shaders.zig");
const textures = @import("./renderer/textures.zig");
const font_atlas_mod = @import("./renderer/font_atlas.zig");

const TextureImage = textures.TextureImage;
const Texture = textures.Texture;
const Shader = shaders.Shader;
const FontAtlas = font_atlas_mod.FontAtlas;


/// A pool of refcounted, generation-tracked assets of type `T`, keyed by a
/// user-supplied `u32` id. Multiple generations of the same id may coexist:
/// adding a new version marks any older live version dirty so holders can
/// notice and re-acquire, while unreferenced older versions are reclaimed
/// immediately.
///
/// Handles returned by `add` / `acquire` are heap-allocated and remain at
/// stable addresses for their full lifetime, so callers may hold raw
/// `*Handle` pointers across `add` calls.
///
/// Each `Handle` carries a back-pointer to its parent `ManagedResource` so
/// callers only need to store one pointer. Call `handle.release()` to
/// decrement the refcount, and `handle.reacquire()` to atomically upgrade to
/// the latest generation after a reload.
pub fn ManagedResource(comptime ResourceName: []const u8, comptime T: type) type {
    return struct {
        res: std.ArrayList(?*Handle),
        alloc: std.mem.Allocator,
        freeFunc: Handle.FreeFunc,
        id: u32,
        gen: u32,

        const Self = @This();

        /// A reference-counted, generation-tracked handle to an asset of
        /// type `T`. Obtained via `ManagedResource.acquire`. Holders should
        /// call `release` when done and `reacquire` when `dirty` is true.
        pub const Handle = struct {
            id: u32,
            generation: u32,
            refCount: u32,
            dirty: bool,
            val: T,
            parent: *Self,

            pub const FreeFunc = *const fn (T) void;

            /// Upgrades to the latest generation from the parent, releasing
            /// the current handle when it has been superseded. Returns the
            /// new handle, or `self` when no newer generation exists yet.
            pub fn reacquire(self: *Handle) *Handle {
                const new = self.parent.latest() orelse return self;
                if (new == self) return self;
                new.refCount += 1;
                std.debug.assert(self.refCount > 0);
                self.refCount -= 1;
                if (self.refCount == 0 and self.dirty) {
                    self.parent.freeHandle(self);
                }
                return new;
            }

            pub fn release(self: *Handle) void {
                self.parent.release(self);
            }
        };

        pub fn init(alloc: std.mem.Allocator, id: u32, freeFunc: Handle.FreeFunc) Self {
            return .{
                .res = .empty,
                .alloc = alloc,
                .freeFunc = freeFunc,
                .id = id,
                .gen = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.res.items) |hOpt| {
                if (hOpt) |h| {
                    if (h.refCount != 0) {
                        std.log.err("{s}:{}: refCount = {} on deinit", .{ ResourceName, h.id, h.refCount });
                    }
                    self.freeFunc(h.val);
                    self.alloc.destroy(h);
                }
            }
            self.res.deinit(self.alloc);
        }

        /// Add a new version of the managed resource. Existing versions
        /// are either marked dirty (if still referenced) or freed
        /// immediately (if no one holds them).
        pub fn add(self: *Self, obj: T) !void {
            // Free unreferenced old versions first. Safe even if the insert
            // below fails (refCount == 0 means no caller holds these), and
            // creates null slots that insertHandle can reuse without allocating.
            for (self.res.items, 0..) |hOpt, i| {
                if (hOpt) |h| {
                    if (h.refCount == 0) {
                        self.freeFunc(h.val);
                        self.alloc.destroy(h);
                        self.res.items[i] = null;
                    }
                }
            }

            const handle = try self.alloc.create(Handle);
            errdefer self.alloc.destroy(handle);
            handle.* = .{
                .id = self.id,
                .generation = self.gen + 1,
                .refCount = 0,
                .dirty = false,
                .val = obj,
                .parent = self,
            };

            try self.insertHandle(handle);

            // Only mark still-referenced handles dirty after insertion succeeds.
            // If insertHandle had failed, marking them dirty would leave callers
            // with handles that get freed on release even though no new version exists.
            self.gen += 1;
            for (self.res.items) |hOpt| {
                if (hOpt) |h| {
                    if (h != handle) h.dirty = true;
                }
            }
        }

        /// Increment the refCount on the latest live handle for the resource.
        /// Returns null if nothing is registered under `id`.
        pub fn acquire(self: *Self) ?*Handle {
            const latestHandle = self.latest() orelse return null;
            latestHandle.refCount += 1;
            return latestHandle;
        }

        /// Decrement the refCount. A dirty handle dropping to refCount == 0
        /// is freed and its slot reclaimed. Clean handles at refCount == 0
        /// are retained so subsequent `acquire` calls still hit.
        pub fn release(self: *Self, handle: *Handle) void {
            std.debug.assert(handle.refCount > 0);
            handle.refCount -= 1;
            if (handle.refCount == 0 and handle.dirty) {
                self.freeHandle(handle);
            }
        }

        /// Latest live handle for the resource without bumping refCount.
        /// Useful for peeking; prefer `acquire` for anything that outlives
        /// one frame.
        pub fn get(self: *Self) ?*Handle {
            return self.latest();
        }

        fn latest(self: *Self) ?*Handle {
            var latestHandle: ?*Handle = null;
            for (self.res.items) |hOpt| {
                if (hOpt) |h| {
                    if (latestHandle == null or h.generation > latestHandle.?.generation) {
                        latestHandle = h;
                    }
                }
            }
            return latestHandle;
        }

        fn insertHandle(self: *Self, handle: *Handle) !void {
            for (self.res.items) |*slot| {
                if (slot.* == null) {
                    slot.* = handle;
                    return;
                }
            }
            try self.res.append(self.alloc, handle);
        }

        fn freeHandle(self: *Self, handle: *Handle) void {
            for (self.res.items, 0..) |hOpt, i| {
                if (hOpt) |h| {
                    if (h == handle) {
                        self.freeFunc(h.val);
                        self.alloc.destroy(h);
                        self.res.items[i] = null;
                        return;
                    }
                }
            }
            unreachable; // handle wasn't owned by this manager
        }
    };
}

/// The atlas stores named, refcounted views over GL textures. A Texture
/// value itself owns no GL state, so reclaiming a stale view is free.
pub const ManagedTexture = ManagedResource("Texture", Texture);

/// A TextureImage owns the GL texture handle. Reclaiming a stale
/// TextureImage deletes the GL handle.
pub const ManagedTextureImage = ManagedResource("TextureImage", TextureImage);

/// A Shader owns its GL program + vertex/fragment shaders. The managed resource
/// stores shaders by value; pointer stability comes from the heap-allocated
/// `Handle` inside the managed resource.
pub const ManagedShader = ManagedResource("Shader", Shader);

/// A FontAtlas owns a GL texture + a char-to-glyph hashmap. Stored by value
/// inside the managed resource.
pub const ManagedFont = ManagedResource("Font", FontAtlas);

pub const TextureHandle = ManagedTexture.Handle;
pub const TextureImageHandle = ManagedTextureImage.Handle;
pub const ShaderHandle = ManagedShader.Handle;
pub const FontAtlasHandle = ManagedFont.Handle;

fn freeTextureNoop(_: Texture) void {}

fn freeTextureImage(t: TextureImage) void {
    gl.deleteTextures(1, &t.texture);
}

fn freeShader(s: Shader) void {
    var copy = s;
    copy.deinit();
}

fn freeFontAtlas(fa: FontAtlas) void {
    var copy = fa;
    copy.deinit();
}

// ---------------------------------------------------------------------------
// ResourceManager
// ---------------------------------------------------------------------------

/// Owns all loaded game assets: textures, shaders, atlases and fonts.
/// Each resource type is stored in a `ManagedResource` pool that supports multiple
/// generations and ref-counting.  Callers interact via handles (`*TextureHandle`, etc.)
/// obtained from `acquire*` methods; call `handle.release()` when done.
pub const ResourceManager = struct {
    textures: std.StringHashMap(*ManagedTextureImage),
    shaders: std.StringHashMap(*ManagedShader),
    atlas: std.StringHashMap(*ManagedTexture),
    /// Tracks which frame names each atlas registered so stale frames can be
    /// removed when an atlas is reloaded with a changed JSON.
    atlas_manifests: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
    fonts: std.StringHashMap(*ManagedFont),
    alloc: std.mem.Allocator,
    /// Monotonic id assigned to each new ManagedResource the manager owns.
    /// Lookups inside a managed resource use generations; this id distinguishes
    /// each managed resource.
    gid: u32,

    const Self = @This();

    /// Initializes the resource manager.
    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .textures = std.StringHashMap(*ManagedTextureImage).init(alloc),
            .shaders = std.StringHashMap(*ManagedShader).init(alloc),
            .atlas = std.StringHashMap(*ManagedTexture).init(alloc),
            .atlas_manifests = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(alloc),
            .fonts = std.StringHashMap(*ManagedFont).init(alloc),
            .alloc = alloc,
            .gid = 0,
        };
    }

    /// Frees all managed resources and their backing OpenGL objects.
    /// All handles must be released before calling this.
    pub fn deinit(self: *Self) void {
        var tit = self.textures.iterator();
        while (tit.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.textures.deinit();

        var it = self.atlas.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.atlas.deinit();

        var amit = self.atlas_manifests.iterator();
        while (amit.next()) |entry| {
            for (entry.value_ptr.items) |name| self.alloc.free(name);
            entry.value_ptr.deinit(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }
        self.atlas_manifests.deinit();

        var sit = self.shaders.iterator();
        while (sit.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.shaders.deinit();

        var fit = self.fonts.iterator();
        while (fit.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.fonts.deinit();
    }

    // -----------------------------------------------------------------------
    // Internal managed resource helpers
    // -----------------------------------------------------------------------

    fn getOrCreateAtlasTexture(self: *Self, name: []const u8) !*ManagedTexture {
        if (self.atlas.get(name)) |existing| return existing;

        const keyOwned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(keyOwned);

        const managed = try self.alloc.create(ManagedTexture);
        errdefer self.alloc.destroy(managed);

        managed.* = ManagedTexture.init(self.alloc, self.gid, freeTextureNoop);
        self.gid += 1;

        try self.atlas.put(keyOwned, managed);
        return managed;
    }

    fn getOrCreateTextureImage(self: *Self, name: []const u8) !*ManagedTextureImage {
        if (self.textures.get(name)) |existing| return existing;

        const keyOwned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(keyOwned);

        const managed = try self.alloc.create(ManagedTextureImage);
        errdefer self.alloc.destroy(managed);

        managed.* = ManagedTextureImage.init(self.alloc, self.gid, freeTextureImage);
        self.gid += 1;

        try self.textures.put(keyOwned, managed);
        return managed;
    }

    fn getOrCreateShader(self: *Self, name: []const u8) !*ManagedShader {
        if (self.shaders.get(name)) |existing| return existing;

        const keyOwned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(keyOwned);

        const managed = try self.alloc.create(ManagedShader);
        errdefer self.alloc.destroy(managed);

        managed.* = ManagedShader.init(self.alloc, self.gid, freeShader);
        self.gid += 1;

        try self.shaders.put(keyOwned, managed);
        return managed;
    }

    fn getOrCreateFont(self: *Self, name: []const u8) !*ManagedFont {
        if (self.fonts.get(name)) |existing| return existing;

        const keyOwned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(keyOwned);

        const managed = try self.alloc.create(ManagedFont);
        errdefer self.alloc.destroy(managed);

        managed.* = ManagedFont.init(self.alloc, self.gid, freeFontAtlas);
        self.gid += 1;

        try self.fonts.put(keyOwned, managed);
        return managed;
    }

    // -----------------------------------------------------------------------
    // Texture loading
    // -----------------------------------------------------------------------

    /// Loads an RGBA texture from a raw buffer. The buffer should be in RGBA
    /// format, with 4 bytes per pixel. The name is the name that the texture
    /// will be stored with in the resource manager, and is used to access the
    /// texture later with `getTexture`. The width and height are the dimensions
    /// of the texture and must match the buffer size.
    pub fn loadTextureFromBuffer(
        self: *Self,
        name: []const u8,
        width: usize,
        height: usize,
        buffer: []u8,
    ) !*ManagedTexture {
        const baseName = utils.baseNameFromPath(name);

        var texture: c_uint = undefined;
        gl.genTextures(1, &texture);
        var gl_texture_owned = false;
        errdefer if (!gl_texture_owned) gl.deleteTextures(1, &texture);

        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        const format = gl.RGBA;
        gl.texImage2D(gl.TEXTURE_2D, 0, format, @intCast(width), @intCast(height), 0, format, gl.UNSIGNED_BYTE, @ptrCast(buffer));

        const imageManaged = try self.getOrCreateTextureImage(baseName);
        try imageManaged.add(.{
            .texture = texture,
            .size = .{ .x = @intCast(width), .y = @intCast(height) },
        });
        gl_texture_owned = true;

        const managed = try self.getOrCreateAtlasTexture(baseName);
        try managed.add(.{
            .texture = texture,
            .size = .{ .x = @intCast(width), .y = @intCast(height) },
            .src = .{ .t = 0, .l = 0, .b = 1, .r = 1 },
        });

        return managed;
    }

    /// Loads a texture from a file path. The name is the base name of the
    /// file, without the extension, so "player" would match "player.png".
    /// The texture is stored in the atlas with the base name, so it can be
    /// accessed with `getTexture` using that name.  The file type is
    /// determined from the file extension, and should be a type supported
    /// by the `stbi` library, such as png or jpg. Loading the same name
    /// again marks any live handles dirty.
    pub fn loadTexture(
        self: *Self,
        name: []const u8,
        file_path: []const u8,
    ) !*ManagedTexture {
        std.log.info("Loading image '{s}' from '{s}'\n", .{ name, file_path });
        const nt_file_path = try std.mem.concatWithSentinel(self.alloc, u8, &.{file_path}, 0);
        defer self.alloc.free(nt_file_path);

        var image = try stbi.Image.loadFromFile(nt_file_path, 4);
        defer image.deinit();

        std.log.info("Loaded image '{s}', width={}, height={}\n", .{ name, image.width, image.height });

        return try self.loadTextureFromBuffer(name, image.width, image.height, image.data);
    }

    // -----------------------------------------------------------------------
    // Atlas loading
    // -----------------------------------------------------------------------

    fn ownedByFrameList(frames: ?[]const []const u8, frame_name: []const u8) bool {
        const list = frames orelse return false;
        for (list) |n| {
            if (std.mem.eql(u8, n, frame_name)) return true;
        }
        return false;
    }

    /// Evicts a texture loaded under `name`, deleting its GL texture and
    /// dropping both the `TextureImage` entry that owns it and the
    /// `Texture` view registered alongside it (`loadTextureFromBuffer`
    /// registers in both maps). Returns whether anything was there.
    ///
    /// For a caller that loads textures whose *number* grows with what the
    /// user does rather than with the program's fixed asset set --
    /// glyphwire-host uploads one per image a client sends, so without
    /// this the GPU side keeps growing after the CPU-side bytes have been
    /// reclaimed. An ordinary game never needs it: its textures live for
    /// the process.
    ///
    /// The caller must have dropped every pointer into this texture
    /// first (a `*Texture` from `ManagedTexture.get()`, anything cached
    /// in a batch): those are not refcounted, so nothing here can detect
    /// them. A still-held refcounted `Handle` is reported as a leak by
    /// `ManagedResource.deinit` and the texture is freed anyway.
    pub fn releaseTexture(self: *Self, name: []const u8) bool {
        const baseName = utils.baseNameFromPath(name);
        var found = false;
        // The atlas view first: its free func is a no-op (the GL texture
        // belongs to the `TextureImage` below), so this only drops the
        // bookkeeping.
        if (self.atlas.fetchRemove(baseName)) |entry| {
            entry.value.deinit();
            self.alloc.destroy(entry.value);
            self.alloc.free(entry.key);
            found = true;
        }
        if (self.textures.fetchRemove(baseName)) |entry| {
            entry.value.deinit();
            self.alloc.destroy(entry.value);
            self.alloc.free(entry.key);
            found = true;
        }
        return found;
    }

    /// Acquires a refcounted handle to a texture by name. The handle stays
    /// alive until released via `handle.release()`. The owning managed resource
    /// marks the handle dirty when the texture is reloaded so the caller can
    /// call `handle.reacquire()` to upgrade.
    pub fn acquireTexture(self: *Self, name: []const u8) !*TextureHandle {
        const managed = self.atlas.get(name) orelse return error.NoTextureWithThatName;
        return managed.acquire() orelse return error.NoTextureWithThatName;
    }

    // -----------------------------------------------------------------------
    // Font loading
    // -----------------------------------------------------------------------

    /// Like `loadFontFromTtfFile`, but `faceIndex` selects a face inside a
    /// TrueType/OpenType collection (`.ttc`). Use 0 for a plain font file.
    pub fn loadFontFromTtfFileIndexed(
        self: *Self,
        name: []const u8,
        fontPath: []const u8,
        faceIndex: i32,
        fontSize: f32,
    ) !void {
        const fa = try FontAtlas.initFromTtfFileIndexed(fontPath, faceIndex, fontSize, self.alloc);
        const managed = try self.getOrCreateFont(name);
        try managed.add(fa);
    }

    /// Appends a fallback face to an already-loaded TTF font. Codepoints the
    /// primary face (and any earlier fallback) lacks are then filled from
    /// this face. `faceIndex` selects a face inside a `.ttc` collection; use
    /// 0 for a plain font file. Reloading the primary font under the same
    /// name rebuilds the atlas from that file alone and drops fallbacks.
    pub fn addFontFallback(self: *Self, name: []const u8, fontPath: []const u8, faceIndex: i32) !void {
        const managed = self.fonts.get(name) orelse return error.NoFontWithThatName;
        const handle = managed.get() orelse return error.NoFontWithThatName;
        try handle.val.addFallbackFaceFromFile(fontPath, faceIndex, self.alloc);
    }

    // -----------------------------------------------------------------------
    // Shader loading
    // -----------------------------------------------------------------------

    /// Returns the `ManagedShader` for `name`. Use `acquire` on the result
    /// to get a refcounted handle.
    pub fn getShader(self: *Self, name: []const u8) !*ManagedShader {
        return self.shaders.get(name) orelse return error.NoShaderWithThatName;
    }

    /// Loads a shader from vertex and fragment shader source code, and stores
    /// it in the resource manager with the given name. Calling with an
    /// existing name compiles a fresh shader and marks the prior version
    /// dirty, so live holders can call `handle.reacquire()` to pick up the
    /// new program.
    pub fn loadShader(
        self: *Self,
        name: []const u8,
        vs: shaders.ShaderCodePtr,
        fs: shaders.ShaderCodePtr,
    ) !*ManagedShader {
        const managed = try self.getOrCreateShader(name);
        try managed.add(try Shader.init(vs, fs));
        return managed;
    }
};
