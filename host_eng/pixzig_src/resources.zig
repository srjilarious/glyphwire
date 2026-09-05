//! Vendored from pixzig's `src/pixzig/resources.zig`, with two engine
//! features glyphwire doesn't use stripped or disabled:
//!
//!   * Tilemap support (`ManagedTileMap`, `loadTileMap`, `acquireTileMap`)
//!     is removed outright. It was the only reason this file pulled in
//!     `tile/tilemap.zig` + `tile/tiled_loader.zig`, and through them the
//!     `xml` module -- none of which a terminal front end needs.
//!   * Asset hot-reload (`FileWatcher` / `HotReload` / `checkHotReload`) is
//!     commented out rather than deleted, in case it's wanted again later.
//!     glyphwire has no use for watching *engine assets* (fonts, icons, the
//!     shipped atlases don't change while it runs); if file watching comes
//!     back it should live over the user's config files and scripts in
//!     `~/.config/glyphwire/`, not over the resource manager.

const std = @import("std");
// Only the commented-out hot-reload paths below need `builtin.mode`.
// const builtin = @import("builtin");
const stbi = @import("zstbi");
const gl = @import("zopengl").bindings;
const common = @import("./common.zig");
const utils = @import("./utils.zig");
const shaders = @import("./renderer/shaders.zig");
const textures = @import("./renderer/textures.zig");
const font_atlas_mod = @import("./renderer/font_atlas.zig");
// const file_watcher_mod = @import("./file_watcher.zig");

const TextureImage = textures.TextureImage;
const Texture = textures.Texture;
const Shader = shaders.Shader;
const FontAtlas = font_atlas_mod.FontAtlas;
const CharToColor = textures.CharToColor;
const SpackFile = textures.SpackFile;
// const FileWatcher = file_watcher_mod.FileWatcher;
// const WatchId = file_watcher_mod.WatchId;

const Vec2U = common.Vec2U;
const Vec2I = common.Vec2I;
const Color8 = common.Color8;
const RectF = common.RectF;
const RectI = common.RectI;

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
/// the latest generation after a hot-reload.
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

// // ---------------------------------------------------------------------------
// // Hot-reload support (active in debug builds only)
// // ---------------------------------------------------------------------------
//
// /// State needed to reload a specific resource from disk. All string fields
// /// are owned by the enclosing `HotReload` instance.
// const ReloadInfo = union(enum) {
//     texture: struct { name: []const u8, path: []const u8 },
//     atlas: struct { base_name: []const u8 },
//     /// Atlas where the resource name differs from the file base name.
//     atlas_named: struct { name: []const u8, base_path: []const u8 },
//     font_ttf: struct { name: []const u8, path: []const u8, face_index: i32 = 0, font_size: f32 },
//     tilemap: struct { name: []const u8, path: []const u8 },
//
//     /// Deep-copy all owned strings into `alloc`. The original slices are
//     /// not freed; the caller decides when to release them.
//     fn dupe(self: ReloadInfo, alloc: std.mem.Allocator) !ReloadInfo {
//         return switch (self) {
//             .texture => |t| .{ .texture = .{
//                 .name = try alloc.dupe(u8, t.name),
//                 .path = try alloc.dupe(u8, t.path),
//             } },
//             .atlas => |a| .{ .atlas = .{
//                 .base_name = try alloc.dupe(u8, a.base_name),
//             } },
//             .atlas_named => |a| .{ .atlas_named = .{
//                 .name = try alloc.dupe(u8, a.name),
//                 .base_path = try alloc.dupe(u8, a.base_path),
//             } },
//             .font_ttf => |f| .{ .font_ttf = .{
//                 .name = try alloc.dupe(u8, f.name),
//                 .path = try alloc.dupe(u8, f.path),
//                 .face_index = f.face_index,
//                 .font_size = f.font_size,
//             } },
//             .tilemap => |t| .{ .tilemap = .{
//                 .name = try alloc.dupe(u8, t.name),
//                 .path = try alloc.dupe(u8, t.path),
//             } },
//         };
//     }
//
//     fn deinit(self: ReloadInfo, alloc: std.mem.Allocator) void {
//         switch (self) {
//             .texture => |t| {
//                 alloc.free(t.name);
//                 alloc.free(t.path);
//             },
//             .atlas => |a| alloc.free(a.base_name),
//             .atlas_named => |a| {
//                 alloc.free(a.name);
//                 alloc.free(a.base_path);
//             },
//             .font_ttf => |f| {
//                 alloc.free(f.name);
//                 alloc.free(f.path);
//             },
//             .tilemap => |t| {
//                 alloc.free(t.name);
//                 alloc.free(t.path);
//             },
//         }
//     }
// };
//
// /// Groups the `FileWatcher` with its per-file reload info tables.
// const HotReload = struct {
//     watcher: FileWatcher,
//     watches: std.AutoHashMap(WatchId, ReloadInfo),
//     path_to_id: std.StringHashMap(WatchId),
//     alloc: std.mem.Allocator,
//
//     fn init(alloc: std.mem.Allocator) !HotReload {
//         return .{
//             .watcher = try FileWatcher.init(alloc),
//             .watches = std.AutoHashMap(WatchId, ReloadInfo).init(alloc),
//             .path_to_id = std.StringHashMap(WatchId).init(alloc),
//             .alloc = alloc,
//         };
//     }
//
//     fn deinit(self: *HotReload) void {
//         var vit = self.watches.valueIterator();
//         while (vit.next()) |info| info.deinit(self.alloc);
//         self.watches.deinit();
//
//         var kit = self.path_to_id.keyIterator();
//         while (kit.next()) |key| self.alloc.free(key.*);
//         self.path_to_id.deinit();
//
//         self.watcher.deinit();
//     }
//
//     /// Register `file_path` as a watched file. `info` slices are borrowed —
//     /// this function deep-copies everything it needs to keep. Duplicate
//     /// registrations for the same path are silently ignored (the first one
//     /// wins), so calling a public load function during hot-reload is safe.
//     fn registerWatch(self: *HotReload, file_path: []const u8, info: ReloadInfo) !void {
//         if (self.path_to_id.contains(file_path)) return;
//
//         const id = try self.watcher.watch(file_path);
//
//         const owned_fp = try self.alloc.dupe(u8, file_path);
//         errdefer self.alloc.free(owned_fp);
//
//         const owned_info = try info.dupe(self.alloc);
//         errdefer owned_info.deinit(self.alloc);
//
//         try self.path_to_id.put(owned_fp, id);
//         errdefer _ = self.path_to_id.remove(owned_fp);
//
//         try self.watches.put(id, owned_info);
//     }
// };

// ---------------------------------------------------------------------------
// ResourceManager
// ---------------------------------------------------------------------------

/// Owns all loaded game assets: textures, shaders, atlases and fonts.
/// Each resource type is stored in a `ManagedResource` pool that supports multiple
/// generations and ref-counting.  Callers interact via handles (`*TextureHandle`, etc.)
/// obtained from `acquire*` methods; call `handle.release()` when done.
///
/// Hot-reload is compiled out in this vendored copy -- see the file header.
pub const ResourceManager = struct {
    textures: std.StringHashMap(*ManagedTextureImage),
    shaders: std.StringHashMap(*ManagedShader),
    atlas: std.StringHashMap(*ManagedTexture),
    /// Tracks which frame names each atlas registered so stale frames can be
    /// removed when the atlas JSON changes during hot-reload.
    atlas_manifests: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
    fonts: std.StringHashMap(*ManagedFont),
    alloc: std.mem.Allocator,
    /// Monotonic id assigned to each new ManagedResource the manager owns.
    /// Lookups inside a managed resource use generations; this id distinguishes
    /// each managed resource.
    gid: u32,
    // /// File-change watcher used in debug builds for hot-reload. Always null
    // /// in release builds (never initialised). The field type is always
    // /// `?HotReload` so the struct layout is uniform across build modes.
    // hot_reload: ?HotReload,

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
            // .hot_reload = null,
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

        // if (self.hot_reload) |*hr| hr.deinit();
    }

    // // -----------------------------------------------------------------------
    // // Hot-reload: internal helpers
    // // -----------------------------------------------------------------------
    //
    // /// Lazily initialise the HotReload state on first use. No-op in release
    // /// builds. Logs an error and leaves `hot_reload` null if initialisation
    // /// fails (watcher remains disabled for the session).
    // fn ensureHotReload(self: *Self) void {
    //     if (comptime builtin.mode != .Debug) return;
    //     if (self.hot_reload != null) return;
    //     self.hot_reload = HotReload.init(self.alloc) catch |err| {
    //         std.log.err("Failed to init file watcher for hot reload: {}", .{err});
    //         return;
    //     };
    // }
    //
    // fn reloadResource(self: *Self, info: ReloadInfo) !void {
    //     switch (info) {
    //         .texture => |t| _ = try self.loadTextureImpl(t.name, t.path),
    //         .atlas => |a| _ = try self.loadAtlasImpl(a.base_name),
    //         .atlas_named => |a| _ = try self.loadAtlasNamedImpl(a.name, a.base_path),
    //         .font_ttf => |f| {
    //             const fa = try FontAtlas.initFromTtfFileIndexed(f.path, f.face_index, f.font_size, self.alloc);
    //             const managed = try self.getOrCreateFont(f.name);
    //             try managed.add(fa);
    //         },
    //         .tilemap => |t| {
    //             std.log.info("Hot reload: reloading tilemap '{s}' from '{s}'", .{ t.name, t.path });
    //             const map = try TiledMapXmlLoader.initFromFile(t.path, self.alloc);
    //             const managed = try self.getOrCreateTileMap(t.name);
    //             try managed.add(map);
    //             std.log.info("Hot reload: tilemap '{s}' reloaded, {} live handles marked dirty", .{
    //                 t.name,
    //                 blk: {
    //                     var n: usize = 0;
    //                     for (managed.res.items) |h| if (h != null and h.?.dirty) { n += 1; };
    //                     break :blk n;
    //                 },
    //             });
    //         },
    //     }
    // }
    //
    // /// Poll the file watcher and reload any resources whose source files have
    // /// changed since the last call. This is a no-op in release builds.
    // /// Called automatically by `PixzigAppRunner` each frame.
    // pub fn checkHotReload(self: *Self) void {
    //     if (comptime builtin.mode != .Debug) return;
    //     const hr = if (self.hot_reload) |*h| h else return;
    //
    //     var changed: std.ArrayList(WatchId) = .empty;
    //     defer changed.deinit(self.alloc);
    //
    //     hr.watcher.poll(self.alloc, &changed) catch |err| {
    //         std.log.err("File watcher poll error: {}", .{err});
    //         return;
    //     };
    //
    //     if (changed.items.len > 0) {
    //         std.log.info("File watcher: {} file change(s) detected", .{changed.items.len});
    //     }
    //     for (changed.items) |id| {
    //         if (hr.watches.get(id)) |info| {
    //             const type_name = switch (info) {
    //                 .texture => "texture",
    //                 .atlas => "atlas",
    //                 .atlas_named => "atlas",
    //                 .font_ttf => "font",
    //                 .tilemap => "tilemap",
    //             };
    //             std.log.info("Hot reloading {s} (watch id {})", .{ type_name, id });
    //             self.reloadResource(info) catch |err| {
    //                 std.log.warn("Hot reload failed for watch id {}: {}", .{ id, err });
    //             };
    //         } else {
    //             std.log.warn("File watcher fired for unknown watch id {}", .{id});
    //         }
    //     }
    // }

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

    /// Creates a texture from a character buffer, where each character is mapped
    /// to a color. This is useful for creating textures from ASCII art or other
    /// character-based representations.  This can be helpful for making games with
    /// simple retro textures embedded in the source itself.
    ///
    /// An example:
    /// ```zig
    /// const blockChars =
    ///     \\=------=
    ///     \\-..####-
    ///     \\-.####=-
    ///     \\-#####=-
    ///     \\-#####=-
    ///     \\-#####=-
    ///     \\-##===@-
    ///     \\=------=
    ///     ;
    ///
    ///     const tex = try eng.resources.createTextureImageFromChars("test", 8, 8, blockChars, &[_]CharToColor{
    ///         .{ .char = '#', .color = Color8.from(40, 255, 40, 255) },
    ///         .{ .char = '-', .color = Color8.from(100, 100, 200, 255) },
    ///         .{ .char = '=', .color = Color8.from(100, 100, 100, 255) },
    ///         .{ .char = '.', .color = Color8.from(240, 240, 240, 255) },
    ///         .{ .char = '@', .color = Color8.from(30, 155, 30, 255) },
    ///         .{ .char = ' ', .color = Color8.from(0, 0, 0, 0) },
    ///     });
    /// ```
    pub fn createTextureImageFromChars(
        self: *Self,
        name: []const u8,
        width: usize,
        height: usize,
        chars: []const u8,
        mapping: []const CharToColor,
    ) !*ManagedTexture {
        // Generate the color buffer, mapping chars to their given colors.
        var buffer: []u8 = try self.alloc.alloc(u8, width * height * 4);
        defer self.alloc.free(buffer);

        // Manually track the index since we need to skip newlines.
        var chrIdx: usize = 0;
        var h: usize = 0;
        var w: usize = 0;

        while (chrIdx < chars.len) {
            const curr_ch = chars[chrIdx];
            chrIdx += 1;

            // Skip over newlines from raw literals
            if (curr_ch == '\n' or curr_ch == '\r') continue;

            var color: Color8 = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
            for (0..mapping.len) |idx| {
                if (mapping[idx].char == curr_ch) {
                    color = mapping[idx].color;
                }
            }

            const col_idx: usize = (h * width + w) * 4;
            buffer[col_idx] = color.r;
            buffer[col_idx + 1] = color.g;
            buffer[col_idx + 2] = color.b;
            buffer[col_idx + 3] = color.a;

            // Update pixel buffer locations.
            w += 1;
            if (w >= width) {
                w = 0;
                h += 1;
            }
        }

        return try self.loadTextureFromBuffer(name, width, height, buffer);
    }

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

    /// Internal: loads a texture from a file without registering a hot-reload
    /// watch. Called from `loadTexture` (which adds the watch) and from
    /// `loadAtlasImpl` (which registers atlas-level watches instead).
    fn loadTextureImpl(
        self: *Self,
        name: []const u8,
        file_path: []const u8,
    ) !*ManagedTexture {
        std.log.info("Loading image '{s}' from '{s}'\n", .{ name, file_path });
        const nt_file_path = try self.alloc.dupeZ(u8, file_path);
        defer self.alloc.free(nt_file_path);

        var image = try stbi.Image.loadFromFile(nt_file_path, 4);
        defer image.deinit();

        std.log.info("Loaded image '{s}', width={}, height={}\n", .{ name, image.width, image.height });

        return try self.loadTextureFromBuffer(name, image.width, image.height, image.data);
    }

    /// Loads a texture from a file path. The name is the base name of the
    /// file, without the extension, so "player" would match "player.png".
    /// The texture is stored in the atlas with the base name, so it can be
    /// accessed with `getTexture` using that name.  The file type is
    /// determined from the file extension, and should be a type supported
    /// by the `stbi` library, such as png or jpg.
    ///
    /// In debug builds, the file is automatically watched and the texture
    /// is reloaded (with any live handles marked dirty) when the file changes.
    pub fn loadTexture(
        self: *Self,
        name: []const u8,
        file_path: []const u8,
    ) !*ManagedTexture {
        const result = try self.loadTextureImpl(name, file_path);

        // if (comptime builtin.mode == .Debug) {
        //     self.ensureHotReload();
        //     if (self.hot_reload) |*hr| {
        //         hr.registerWatch(file_path, .{
        //             .texture = .{ .name = name, .path = file_path },
        //         }) catch |err| {
        //             std.log.warn("Could not register texture watch for '{s}': {}", .{ file_path, err });
        //         };
        //     }
        // }

        return result;
    }

    // -----------------------------------------------------------------------
    // Atlas loading
    // -----------------------------------------------------------------------

    /// Internal: loads a texture atlas without registering hot-reload watches.
    /// `name` is the resource key; `base_path` is the file path base (without
    /// extension). When both are equal this is an ordinary loadAtlas call.
    fn loadAtlasNamedImpl(self: *Self, name: []const u8, base_path: []const u8) !usize {
        // Read and validate the JSON before touching the base texture: if the
        // atlas fails to load, the previous texture (if any, from an earlier
        // load of this same name) must be left untouched and still valid.
        const jsonName = try utils.addExtension(self.alloc, base_path, ".json");
        defer self.alloc.free(jsonName);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file_contents = try std.Io.Dir.cwd().readFileAlloc(io, jsonName, self.alloc, .unlimited);
        defer self.alloc.free(file_contents);

        const parsed = try std.json.parseFromSlice(SpackFile, self.alloc, file_contents, .{});
        defer parsed.deinit();

        const spack = parsed.value;

        // Reject frame names that collide with a texture/frame owned by a
        // different atlas (or a plain loaded texture). Frames already owned
        // by this same atlas from a prior load are an expected reload, not a
        // collision.
        const prev_frames: ?[]const []const u8 = if (self.atlas_manifests.get(name)) |pm| pm.items else null;
        for (spack.frames) |frame| {
            if (self.atlas.contains(frame.name) and !ownedByFrameList(prev_frames, frame.name)) {
                std.log.err("AssetManifest: atlas '{s}' frame '{s}' collides with an existing texture owned elsewhere", .{ name, frame.name });
                return error.AtlasFrameNameCollision;
            }
        }

        const imageName = try utils.addExtension(self.alloc, base_path, ".png");
        defer self.alloc.free(imageName);
        _ = try self.loadTextureImpl(name, imageName);

        const texImageManaged = self.textures.get(utils.baseNameFromPath(name)) orelse return error.NoTextureWithThatName;
        const texImage = texImageManaged.get() orelse return error.NoTextureWithThatName;
        const sz: Vec2I = texImage.val.size.asVec2I();

        var new_manifest: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (new_manifest.items) |n| self.alloc.free(n);
            new_manifest.deinit(self.alloc);
        }

        var num: usize = 0;
        for (spack.frames) |frame| {
            const managed = try self.getOrCreateAtlasTexture(frame.name);
            try managed.add(.{
                .texture = texImage.val.texture,
                .size = frame.sizePx,
                .src = RectF.fromCoords(
                    frame.pos.l,
                    frame.pos.t,
                    frame.pos.width(),
                    frame.pos.height(),
                    sz.x,
                    sz.y,
                ),
            });

            const name_owned = try self.alloc.dupe(u8, frame.name);
            errdefer self.alloc.free(name_owned);
            try new_manifest.append(self.alloc, name_owned);

            num += 1;
        }

        // Remove atlas entries for frames absent from the new JSON.
        if (self.atlas_manifests.getPtr(name)) |old_manifest| {
            outer: for (old_manifest.items) |old_name| {
                for (new_manifest.items) |new_name| {
                    if (std.mem.eql(u8, old_name, new_name)) continue :outer;
                }
                if (self.atlas.fetchRemove(old_name)) |kv| {
                    kv.value.deinit();
                    self.alloc.destroy(kv.value);
                    self.alloc.free(kv.key);
                }
            }
            for (old_manifest.items) |n| self.alloc.free(n);
            old_manifest.deinit(self.alloc);
            old_manifest.* = new_manifest;
        } else {
            const key_owned = try self.alloc.dupe(u8, name);
            errdefer self.alloc.free(key_owned);
            try self.atlas_manifests.put(key_owned, new_manifest);
        }

        return num;
    }

    fn loadAtlasImpl(self: *Self, baseName: []const u8) !usize {
        return self.loadAtlasNamedImpl(baseName, baseName);
    }

    fn ownedByFrameList(frames: ?[]const []const u8, frame_name: []const u8) bool {
        const list = frames orelse return false;
        for (list) |n| {
            if (std.mem.eql(u8, n, frame_name)) return true;
        }
        return false;
    }

    /// Loads a texture atlas from a base name. This looks for a .png and
    /// .json file with the given base name, and loads the texture and
    /// subtextures specified in the json file. The json file should be in the
    /// format of a `SpackFile`, which is the format used by our internal
    /// `TexturePacker` tool.
    ///
    /// The subtextures are stored in the atlas with their names from the json
    /// file, so they can be accessed with `getTexture` using those names.
    ///
    /// In debug builds, both the .png and .json files are watched; any change
    /// to either triggers a full atlas reload.
    pub fn loadAtlas(self: *Self, baseName: []const u8) !usize {
        const num = try self.loadAtlasImpl(baseName);

        // if (comptime builtin.mode == .Debug) {
        //     self.ensureHotReload();
        //     if (self.hot_reload) |*hr| {
        //         const imageName = try utils.addExtension(self.alloc, baseName, ".png");
        //         defer self.alloc.free(imageName);
        //         const jsonName = try utils.addExtension(self.alloc, baseName, ".json");
        //         defer self.alloc.free(jsonName);
        //
        //         hr.registerWatch(imageName, .{ .atlas = .{ .base_name = baseName } }) catch |err| {
        //             std.log.warn("Could not register atlas PNG watch for '{s}': {}", .{ imageName, err });
        //         };
        //         hr.registerWatch(jsonName, .{ .atlas = .{ .base_name = baseName } }) catch |err| {
        //             std.log.warn("Could not register atlas JSON watch for '{s}': {}", .{ jsonName, err });
        //         };
        //     }
        // }

        return num;
    }

    /// Like `loadAtlas` but stores the resource under `name` instead of the
    /// base name of `base_path`. Use this when the manifest asset id should
    /// differ from the file name on disk (e.g. id="main_sprites", path="pac-tiles").
    /// After loading, `acquireTexture(name)` returns a handle to the full atlas
    /// image; individual frames remain accessible by their frame names.
    pub fn loadAtlasNamed(self: *Self, name: []const u8, base_path: []const u8) !usize {
        const num = try self.loadAtlasNamedImpl(name, base_path);

        // if (comptime builtin.mode == .Debug) {
        //     self.ensureHotReload();
        //     if (self.hot_reload) |*hr| {
        //         const imageName = try utils.addExtension(self.alloc, base_path, ".png");
        //         defer self.alloc.free(imageName);
        //         const jsonName = try utils.addExtension(self.alloc, base_path, ".json");
        //         defer self.alloc.free(jsonName);
        //
        //         hr.registerWatch(imageName, .{ .atlas_named = .{ .name = name, .base_path = base_path } }) catch |err| {
        //             std.log.warn("Could not register atlas PNG watch for '{s}': {}", .{ imageName, err });
        //         };
        //         hr.registerWatch(jsonName, .{ .atlas_named = .{ .name = name, .base_path = base_path } }) catch |err| {
        //             std.log.warn("Could not register atlas JSON watch for '{s}': {}", .{ jsonName, err });
        //         };
        //     }
        // }

        return num;
    }

    /// Adds a named subtexture from a region of an existing managed texture.
    /// Coordinates are in UV space: (0,0) is top-left, (1,1) is bottom-right.
    pub fn addSubTexture(
        self: *Self,
        tex: *ManagedTexture,
        name: []const u8,
        coords: RectF,
    ) !*ManagedTexture {
        const current = tex.get() orelse return error.NoTextureInPool;
        const managed = try self.getOrCreateAtlasTexture(name);
        try managed.add(current.val.sub(coords));
        return managed;
    }

    /// Returns the `ManagedTexture` for `name`. Use `acquire` on the result
    /// to get a refcounted handle, or `get` to peek at the latest value.
    pub fn getTexture(self: *Self, name: []const u8) !*ManagedTexture {
        return self.atlas.get(name) orelse return error.NoTextureWithThatName;
    }

    /// Acquires a refcounted handle to a texture by name. The handle stays
    /// alive until released via `handle.release()`. The owning managed resource
    /// marks the handle dirty when the texture is reloaded so the caller can
    /// call `handle.reacquire()` to upgrade.
    pub fn acquireTexture(self: *Self, name: []const u8) !*TextureHandle {
        const managed = self.atlas.get(name) orelse return error.NoTextureWithThatName;
        return managed.acquire() orelse return error.NoTextureWithThatName;
    }

    /// Acquires a refcounted handle to a shader by name. See `acquireTexture`
    /// for lifecycle notes.
    pub fn acquireShader(self: *Self, name: []const u8) !*ShaderHandle {
        const managed = self.shaders.get(name) orelse return error.NoShaderWithThatName;
        return managed.acquire() orelse return error.NoShaderWithThatName;
    }

    // -----------------------------------------------------------------------
    // Font loading
    // -----------------------------------------------------------------------

    /// Loads a TTF font from disk and registers it under `name`. A second
    /// call with the same name marks the prior generation dirty and adds a
    /// fresh one (auto-reload semantics matching other load* methods).
    ///
    /// In debug builds, the file is watched and the font is reloaded (with
    /// live handles marked dirty) when the file changes.
    pub fn loadFontFromTtfFile(
        self: *Self,
        name: []const u8,
        fontPath: []const u8,
        fontSize: f32,
    ) !void {
        return self.loadFontFromTtfFileIndexed(name, fontPath, 0, fontSize);
    }

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

        // if (comptime builtin.mode == .Debug) {
        //     self.ensureHotReload();
        //     if (self.hot_reload) |*hr| {
        //         hr.registerWatch(fontPath, .{
        //             .font_ttf = .{ .name = name, .path = fontPath, .face_index = faceIndex, .font_size = fontSize },
        //         }) catch |err| {
        //             std.log.warn("Could not register font watch for '{s}': {}", .{ fontPath, err });
        //         };
        //     }
        // }
    }

    /// Loads a TTF font embedded at comptime into the binary and registers
    /// it under `name`.
    pub fn loadFontFromTtfEmbedded(
        self: *Self,
        name: []const u8,
        comptime fontPath: []const u8,
        fontSize: f32,
    ) !void {
        const fa = try FontAtlas.initFromTtfEmbedded(fontPath, fontSize, self.alloc);
        const managed = try self.getOrCreateFont(name);
        try managed.add(fa);
    }

    /// Loads a fixed-cell bitmap font and registers it under `name`.
    pub fn loadFontFromBitmap(
        self: *Self,
        name: []const u8,
        fontImagePath: []const u8,
        charWidth: i32,
        charHeight: i32,
        charsPerRow: i32,
        chars: []const u8,
    ) !void {
        const fa = try FontAtlas.initFromBitmap(fontImagePath, charWidth, charHeight, charsPerRow, chars, self.alloc);
        const managed = try self.getOrCreateFont(name);
        try managed.add(fa);
    }

    /// Acquires a refcounted handle to a font atlas by name.
    pub fn acquireFontAtlas(self: *Self, name: []const u8) !*FontAtlasHandle {
        const managed = self.fonts.get(name) orelse return error.NoFontWithThatName;
        return managed.acquire() orelse return error.NoFontWithThatName;
    }

    /// Appends a fallback face to an already-loaded TTF font. Codepoints the
    /// primary face (and any earlier fallback) lacks are then filled from
    /// this face. `faceIndex` selects a face inside a `.ttc` collection; use
    /// 0 for a plain font file.
    ///
    /// Note: a hot-reload of the primary font file rebuilds the atlas from
    /// that file alone and drops fallbacks; re-add them after a reload if it
    /// matters for the build.
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
