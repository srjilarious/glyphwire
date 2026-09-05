const std = @import("std");
const gl = @import("zopengl").bindings;
const zmath = @import("zmath");

const textures = @import("./textures.zig");
const resources = @import("../resources.zig");

const Texture = textures.Texture;
const ManagedShader = resources.ManagedShader;
const ShaderHandle = resources.ShaderHandle;

/// Comptime shape of a `QuadBatch`'s vertex data: how many floats make up a
/// position, and whether (and how wide) a texcoord and/or color stream ride
/// along with it. `texDim`/`colorDim` of 0 means that stream isn't used at
/// all -- no CPU buffer, no VBO, no vertex attribute for it.
pub const BatchLayout = struct {
    /// Floats per position: 2 for 2d quads, 3 for world-space 3d quads.
    posDim: comptime_int,

    /// Floats per texcoord: 0 (no texture) or 2 (u, v).
    texDim: comptime_int = 0,

    /// Floats per vertex color: 0 (none), 1 (alpha), 3 (rgb), or 4 (rgba).
    colorDim: comptime_int = 0,
};

/// A batch queue for drawing single-texture quads sharing one shader. Buffers
/// vertices (and, depending on `layout`, texcoords and/or per-vertex colors)
/// on the CPU and flushes them to the GPU in one draw call via `flush`,
/// which happens automatically when the texture changes, the batch is full,
/// or `end` is called.
///
/// This holds only the generic vertex-data plumbing: buffer setup, shader
/// attribute/uniform locations, and the flush-on-texture-change bookkeeping
/// shared by every quad renderer in pixzig. Renderer-specific concerns (rect
/// rotation, GL_DEPTH_TEST toggling, line-drawn rect outlines, ...) belong in
/// a thin wrapper type built on top of this, not here.
pub fn QuadBatch(comptime layout: BatchLayout) type {
    const hasTex = layout.texDim > 0;
    const hasColor = layout.colorDim > 0;

    return struct {
        const Self = @This();

        /// Refcounted shader handle. Refreshed in `begin` when dirty.
        shader: *ShaderHandle,
        vao: u32 = 0,
        vboVertices: u32 = 0,
        vboTexCoords: u32 = 0, // unused when !hasTex
        vboColorCoords: u32 = 0, // unused when !hasColor
        vboIndices: u32 = 0,

        vertices: []f32 = &.{},
        texCoords: []f32 = &.{}, // stays empty when !hasTex
        colorCoords: []f32 = &.{}, // stays empty when !hasColor
        // u32 (not u16) element indices: a batch of `maxQuads` quads has
        // `4 * maxQuads` vertices, and the largest vertex index must fit
        // the type. u16 caps a batch at ~16k quads before the index
        // `@intCast` below overflows; u32 lifts that to well past any
        // sane `maxQuads`. Drawn with `gl.UNSIGNED_INT` to match.
        indices: []u32 = &.{},

        allocator: std.mem.Allocator,
        maxQuads: usize,

        attrCoord: c_uint = 0,
        attrTexCoord: c_uint = 0,
        attrColor: c_uint = 0,
        uniformMVP: c_int = 0,

        currVert: usize = 0,
        currTex: usize = 0,
        currColor: usize = 0,
        currIdx: usize = 0,
        currNumQuads: usize = 0,

        mvpArr: [16]f32 = .{0} ** 16,
        texture: if (hasTex) ?*const Texture else void = if (hasTex) null else {},
        begun: bool = false,

        /// Initializes the batch, allocating CPU scratch buffers and GPU
        /// objects for up to `maxQuads` quads at once.
        pub fn init(alloc: std.mem.Allocator, shader: *ManagedShader, maxQuads: usize) !Self {
            const handle = shader.acquire() orelse return error.NoShaderInPool;
            errdefer handle.release();

            var batch = Self{
                .allocator = alloc,
                .shader = handle,
                .maxQuads = maxQuads,
            };

            batch.vertices = try alloc.alloc(f32, 4 * layout.posDim * maxQuads);
            errdefer alloc.free(batch.vertices);

            if (comptime hasTex) {
                batch.texCoords = try alloc.alloc(f32, 4 * layout.texDim * maxQuads);
            }
            errdefer if (comptime hasTex) alloc.free(batch.texCoords);

            if (comptime hasColor) {
                batch.colorCoords = try alloc.alloc(f32, 4 * layout.colorDim * maxQuads);
            }
            errdefer if (comptime hasColor) alloc.free(batch.colorCoords);

            batch.indices = try alloc.alloc(u32, 6 * maxQuads);
            errdefer alloc.free(batch.indices);

            gl.genVertexArrays(1, &batch.vao);
            errdefer gl.deleteVertexArrays(1, &batch.vao);
            gl.bindVertexArray(batch.vao);

            gl.genBuffers(1, &batch.vboVertices);
            errdefer gl.deleteBuffers(1, &batch.vboVertices);
            gl.bindBuffer(gl.ARRAY_BUFFER, batch.vboVertices);
            gl.bufferData(gl.ARRAY_BUFFER, @intCast(batch.vertices.len * @sizeOf(f32)), null, gl.DYNAMIC_DRAW);

            if (comptime hasTex) {
                gl.genBuffers(1, &batch.vboTexCoords);
                errdefer gl.deleteBuffers(1, &batch.vboTexCoords);
                gl.bindBuffer(gl.ARRAY_BUFFER, batch.vboTexCoords);
                gl.bufferData(gl.ARRAY_BUFFER, @intCast(batch.texCoords.len * @sizeOf(f32)), null, gl.DYNAMIC_DRAW);
            }

            if (comptime hasColor) {
                gl.genBuffers(1, &batch.vboColorCoords);
                errdefer gl.deleteBuffers(1, &batch.vboColorCoords);
                gl.bindBuffer(gl.ARRAY_BUFFER, batch.vboColorCoords);
                gl.bufferData(gl.ARRAY_BUFFER, @intCast(batch.colorCoords.len * @sizeOf(f32)), null, gl.DYNAMIC_DRAW);
            }

            gl.genBuffers(1, &batch.vboIndices);
            errdefer gl.deleteBuffers(1, &batch.vboIndices);
            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, batch.vboIndices);
            gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(batch.indices.len * @sizeOf(u32)), null, gl.DYNAMIC_DRAW);

            gl.enable(gl.BLEND);
            gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
            gl.enable(gl.TEXTURE_2D);

            batch.cacheShaderLocations();

            return batch;
        }

        /// Cleans up the OpenGL objects associated with the batch and frees
        /// the CPU-side scratch buffers.
        pub fn deinit(self: *Self) void {
            self.shader.release();
            gl.deleteBuffers(1, &self.vboVertices);
            if (comptime hasTex) gl.deleteBuffers(1, &self.vboTexCoords);
            if (comptime hasColor) gl.deleteBuffers(1, &self.vboColorCoords);
            gl.deleteBuffers(1, &self.vboIndices);
            gl.deleteVertexArrays(1, &self.vao);
            self.allocator.free(self.vertices);
            if (comptime hasTex) self.allocator.free(self.texCoords);
            if (comptime hasColor) self.allocator.free(self.colorCoords);
            self.allocator.free(self.indices);
        }

        fn cacheShaderLocations(self: *Self) void {
            self.attrCoord = @intCast(gl.getAttribLocation(self.shader.val.program, "coord3d"));
            if (comptime hasTex) self.attrTexCoord = @intCast(gl.getAttribLocation(self.shader.val.program, "texcoord"));
            if (comptime hasColor) self.attrColor = @intCast(gl.getAttribLocation(self.shader.val.program, "color"));
            self.uniformMVP = @intCast(gl.getUniformLocation(self.shader.val.program, "projectionMatrix"));
        }

        fn refreshShader(self: *Self) void {
            if (!self.shader.dirty) return;
            self.shader = self.shader.reacquire();
            self.cacheShaderLocations();
        }

        /// Swap to a different shader entirely (e.g. the text renderer
        /// toggling between alpha and RGB pixel shaders). Releases the
        /// current handle, acquires from `newShader`, and re-caches
        /// uniform/attribute locations.
        pub fn swapShader(self: *Self, newShader: *ManagedShader) !void {
            const new_handle = newShader.acquire() orelse return error.NoShaderInPool;
            self.shader.release();
            self.shader = new_handle;
            self.cacheShaderLocations();
        }

        /// Begins a new batch, setting the matrix used to transform
        /// positions (a plain projection matrix for 2d, or a full
        /// view*projection matrix for 3d).
        pub fn begin(self: *Self, mvp: zmath.Mat) void {
            if (self.begun) {
                self.end();
            }
            self.refreshShader();
            self.begun = true;
            self.mvpArr = zmath.matToArr(mvp);
        }

        /// Enqueues a quad given its 4 vertex positions (and, depending on
        /// `layout`, texcoords/colors), in the winding order used throughout
        /// pixzig: corner 0 is (l,b), 1 is (l,t), 2 is (r,t), 3 is (r,b).
        /// Auto-flushes the batch first if `texture` differs from the
        /// currently queued texture, or the batch is full.
        pub fn addQuad(
            self: *Self,
            texture: if (hasTex) *const Texture else void,
            positions: [4][layout.posDim]f32,
            texCoords: if (hasTex) [4][layout.texDim]f32 else void,
            colors: if (hasColor) [4][layout.colorDim]f32 else void,
        ) void {
            std.debug.assert(self.begun);

            if (comptime hasTex) {
                if (self.texture == null) {
                    self.texture = texture;
                }
                if (self.texture.?.texture != texture.texture) {
                    self.flush();
                    self.texture = texture;
                }
            }

            if (self.currNumQuads >= self.maxQuads) {
                self.flush();
                if (comptime hasTex) self.texture = texture;
            }

            const vBase = self.currVert;
            inline for (0..4) |i| {
                inline for (0..layout.posDim) |c| {
                    self.vertices[vBase + i * layout.posDim + c] = positions[i][c];
                }
            }
            self.currVert += 4 * layout.posDim;

            if (comptime hasTex) {
                const tBase = self.currTex;
                inline for (0..4) |i| {
                    inline for (0..layout.texDim) |c| {
                        self.texCoords[tBase + i * layout.texDim + c] = texCoords[i][c];
                    }
                }
                self.currTex += 4 * layout.texDim;
            }

            if (comptime hasColor) {
                const cBase = self.currColor;
                inline for (0..4) |i| {
                    inline for (0..layout.colorDim) |c| {
                        self.colorCoords[cBase + i * layout.colorDim + c] = colors[i][c];
                    }
                }
                self.currColor += 4 * layout.colorDim;
            }

            const baseVertIdx: u32 = @intCast(vBase / layout.posDim);
            const idx = self.indices[self.currIdx .. self.currIdx + 6];
            idx[0] = baseVertIdx + 0;
            idx[1] = baseVertIdx + 1;
            idx[2] = baseVertIdx + 2;
            idx[3] = baseVertIdx + 2;
            idx[4] = baseVertIdx + 3;
            idx[5] = baseVertIdx + 0;
            self.currIdx += 6;

            self.currNumQuads += 1;
        }

        /// Ends the current batch and flushes any queued quads.
        pub fn end(self: *Self) void {
            self.flush();
            self.begun = false;
        }

        /// Draws the current contents of the queue to the screen. Assumes
        /// `begin` has already been called. Flushes queued quads while
        /// keeping the batch open for further draws.
        pub fn flush(self: *Self) void {
            std.debug.assert(self.begun);
            if (self.currNumQuads == 0) return;

            gl.useProgram(self.shader.val.program);
            gl.uniformMatrix4fv(self.uniformMVP, 1, gl.FALSE, @ptrCast(&self.mvpArr[0]));

            if (comptime hasTex) {
                gl.activeTexture(gl.TEXTURE0);
                gl.bindTexture(gl.TEXTURE_2D, self.texture.?.texture);
                gl.uniform1i(gl.getUniformLocation(self.shader.val.program, "tex"), 0);
            }

            gl.bindVertexArray(self.vao);
            gl.enableVertexAttribArray(self.attrCoord);
            gl.bindBuffer(gl.ARRAY_BUFFER, self.vboVertices);
            gl.bufferData(gl.ARRAY_BUFFER, @intCast(layout.posDim * 4 * @sizeOf(f32) * self.currNumQuads), &self.vertices[0], gl.STATIC_DRAW);
            gl.vertexAttribPointer(self.attrCoord, layout.posDim, gl.FLOAT, gl.FALSE, 0, null);

            if (comptime hasTex) {
                gl.enableVertexAttribArray(self.attrTexCoord);
                gl.bindBuffer(gl.ARRAY_BUFFER, self.vboTexCoords);
                gl.bufferData(gl.ARRAY_BUFFER, @intCast(layout.texDim * 4 * @sizeOf(f32) * self.currNumQuads), &self.texCoords[0], gl.STATIC_DRAW);
                gl.vertexAttribPointer(self.attrTexCoord, layout.texDim, gl.FLOAT, gl.FALSE, 0, null);
            }

            if (comptime hasColor) {
                gl.enableVertexAttribArray(self.attrColor);
                gl.bindBuffer(gl.ARRAY_BUFFER, self.vboColorCoords);
                gl.bufferData(gl.ARRAY_BUFFER, @intCast(layout.colorDim * 4 * @sizeOf(f32) * self.currNumQuads), &self.colorCoords[0], gl.STATIC_DRAW);
                gl.vertexAttribPointer(self.attrColor, layout.colorDim, gl.FLOAT, gl.FALSE, 0, null);
            }

            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.vboIndices);
            gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(6 * @sizeOf(u32) * self.currNumQuads), &self.indices[0], gl.STATIC_DRAW);

            gl.drawElements(gl.TRIANGLES, @intCast(6 * self.currNumQuads), gl.UNSIGNED_INT, null);

            gl.disableVertexAttribArray(self.attrCoord);
            if (comptime hasTex) gl.disableVertexAttribArray(self.attrTexCoord);
            if (comptime hasColor) gl.disableVertexAttribArray(self.attrColor);

            gl.bindBuffer(gl.ARRAY_BUFFER, 0);

            self.currVert = 0;
            self.currTex = 0;
            self.currColor = 0;
            self.currIdx = 0;
            self.currNumQuads = 0;
            if (comptime hasTex) self.texture = null;
        }
    };
}

/// A pre-built, static batch of quads sharing a single texture: build it
/// once (or whenever the source data changes) via
/// `beginBuild`/`addQuad`/`endBuild`, then call `draw()` every frame for a
/// single draw call with no per-frame re-upload. Use this instead of
/// `QuadBatch` for geometry that doesn't change often, e.g. a level's
/// wall/floor/ceiling quads. Callers needing multiple textures should keep
/// one `StaticQuadBatch` per texture and draw each in turn.
///
/// Kept as a separate type from `QuadBatch` rather than a "static mode" flag
/// on it: attribute bindings are baked into the VAO at `endBuild()` time
/// (requiring `rebindVaoAttribs()` on shader hot-reload) and there's no
/// per-frame flush/re-upload cycle, so the two have different enough
/// lifecycles that sharing one type would mean threading a mode flag through
/// most of its methods.
pub fn StaticQuadBatch(comptime layout: BatchLayout) type {
    const hasTex = layout.texDim > 0;
    const hasColor = layout.colorDim > 0;

    return struct {
        const Self = @This();

        shader: *ShaderHandle,
        vao: u32 = 0,
        vboVertices: u32 = 0,
        vboTexCoords: u32 = 0, // unused when !hasTex
        vboColorCoords: u32 = 0, // unused when !hasColor
        vboIndices: u32 = 0,
        allocator: std.mem.Allocator,

        attrCoord: c_uint = 0,
        attrTexCoord: c_uint = 0,
        attrColor: c_uint = 0,
        uniformMVP: c_int = 0,

        // CPU-side scratch, only populated between beginBuild() and endBuild().
        vertices: std.ArrayList(f32) = .empty,
        texCoords: std.ArrayList(f32) = .empty, // unused when !hasTex
        colorCoords: std.ArrayList(f32) = .empty, // unused when !hasColor
        // u32 element indices, matching `QuadBatch` -- drawn with
        // `gl.UNSIGNED_INT` so a static mesh can hold more than ~16k quads.
        indices: std.ArrayList(u32) = .empty,

        numIndices: usize = 0,
        texture: if (hasTex) ?*const Texture else void = if (hasTex) null else {},
        building: bool = false,

        /// Initializes the batch, creating its GL objects. No quad data is
        /// uploaded yet; call beginBuild/addQuad/endBuild before drawing.
        pub fn init(alloc: std.mem.Allocator, shader: *ManagedShader) !Self {
            const handle = shader.acquire() orelse return error.NoShaderInPool;
            errdefer handle.release();

            var batch = Self{
                .allocator = alloc,
                .shader = handle,
            };

            gl.genVertexArrays(1, &batch.vao);
            errdefer gl.deleteVertexArrays(1, &batch.vao);
            gl.genBuffers(1, &batch.vboVertices);
            errdefer gl.deleteBuffers(1, &batch.vboVertices);

            if (comptime hasTex) {
                gl.genBuffers(1, &batch.vboTexCoords);
                errdefer gl.deleteBuffers(1, &batch.vboTexCoords);
            }

            if (comptime hasColor) {
                gl.genBuffers(1, &batch.vboColorCoords);
                errdefer gl.deleteBuffers(1, &batch.vboColorCoords);
            }

            gl.genBuffers(1, &batch.vboIndices);
            errdefer gl.deleteBuffers(1, &batch.vboIndices);

            batch.cacheShaderLocations();

            return batch;
        }

        /// Cleans up the OpenGL objects and any CPU-side scratch buffers.
        pub fn deinit(self: *Self) void {
            self.shader.release();
            gl.deleteBuffers(1, &self.vboVertices);
            if (comptime hasTex) gl.deleteBuffers(1, &self.vboTexCoords);
            if (comptime hasColor) gl.deleteBuffers(1, &self.vboColorCoords);
            gl.deleteBuffers(1, &self.vboIndices);
            gl.deleteVertexArrays(1, &self.vao);
            self.vertices.deinit(self.allocator);
            if (comptime hasTex) self.texCoords.deinit(self.allocator);
            if (comptime hasColor) self.colorCoords.deinit(self.allocator);
            self.indices.deinit(self.allocator);
        }

        fn cacheShaderLocations(self: *Self) void {
            self.attrCoord = @intCast(gl.getAttribLocation(self.shader.val.program, "coord3d"));
            if (comptime hasTex) self.attrTexCoord = @intCast(gl.getAttribLocation(self.shader.val.program, "texcoord"));
            if (comptime hasColor) self.attrColor = @intCast(gl.getAttribLocation(self.shader.val.program, "color"));
            self.uniformMVP = @intCast(gl.getUniformLocation(self.shader.val.program, "projectionMatrix"));
        }

        /// Re-points the already-uploaded VBOs at the current shader's
        /// attribute locations without re-uploading any data. Needed because
        /// endBuild() bakes attribute locations into the VAO, and a shader
        /// hot-reload can hand back a new program where those locations moved.
        fn rebindVaoAttribs(self: *Self) void {
            if (self.numIndices == 0) return;

            gl.bindVertexArray(self.vao);

            gl.enableVertexAttribArray(self.attrCoord);
            gl.bindBuffer(gl.ARRAY_BUFFER, self.vboVertices);
            gl.vertexAttribPointer(self.attrCoord, layout.posDim, gl.FLOAT, gl.FALSE, 0, null);

            if (comptime hasTex) {
                gl.enableVertexAttribArray(self.attrTexCoord);
                gl.bindBuffer(gl.ARRAY_BUFFER, self.vboTexCoords);
                gl.vertexAttribPointer(self.attrTexCoord, layout.texDim, gl.FLOAT, gl.FALSE, 0, null);
            }

            if (comptime hasColor) {
                gl.enableVertexAttribArray(self.attrColor);
                gl.bindBuffer(gl.ARRAY_BUFFER, self.vboColorCoords);
                gl.vertexAttribPointer(self.attrColor, layout.colorDim, gl.FLOAT, gl.FALSE, 0, null);
            }

            gl.bindVertexArray(0);
            gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        }

        fn refreshShader(self: *Self) void {
            if (!self.shader.dirty) return;
            self.shader = self.shader.reacquire();
            self.cacheShaderLocations();
            self.rebindVaoAttribs();
        }

        /// Starts (re)building the batch's quad list from scratch. Every
        /// quad added before the matching endBuild() shares `texture`. Safe
        /// to call again later (e.g. after the underlying map data changes)
        /// to fully rebuild the batch; the previous GPU contents keep
        /// drawing correctly until endBuild() uploads the new ones.
        pub fn beginBuild(self: *Self, texture: if (hasTex) *const Texture else void) void {
            std.debug.assert(!self.building);
            self.building = true;
            if (comptime hasTex) self.texture = texture;
            self.vertices.clearRetainingCapacity();
            if (comptime hasTex) self.texCoords.clearRetainingCapacity();
            if (comptime hasColor) self.colorCoords.clearRetainingCapacity();
            self.indices.clearRetainingCapacity();
        }

        /// Adds a quad's 4 vertex positions (and, depending on `layout`,
        /// texcoords/colors) to the batch, in the same winding order as
        /// `QuadBatch.addQuad`: corner 0 is (l,b), 1 is (l,t), 2 is (r,t), 3
        /// is (r,b).
        pub fn addQuad(
            self: *Self,
            positions: [4][layout.posDim]f32,
            texCoords: if (hasTex) [4][layout.texDim]f32 else void,
            colors: if (hasColor) [4][layout.colorDim]f32 else void,
        ) !void {
            std.debug.assert(self.building);

            const baseVert: u32 = @intCast(self.vertices.items.len / layout.posDim);

            var vbuf: [4 * layout.posDim]f32 = undefined;
            inline for (0..4) |i| {
                inline for (0..layout.posDim) |c| {
                    vbuf[i * layout.posDim + c] = positions[i][c];
                }
            }
            try self.vertices.appendSlice(self.allocator, &vbuf);

            if (comptime hasTex) {
                var tbuf: [4 * layout.texDim]f32 = undefined;
                inline for (0..4) |i| {
                    inline for (0..layout.texDim) |c| {
                        tbuf[i * layout.texDim + c] = texCoords[i][c];
                    }
                }
                try self.texCoords.appendSlice(self.allocator, &tbuf);
            }

            if (comptime hasColor) {
                var cbuf: [4 * layout.colorDim]f32 = undefined;
                inline for (0..4) |i| {
                    inline for (0..layout.colorDim) |c| {
                        cbuf[i * layout.colorDim + c] = colors[i][c];
                    }
                }
                try self.colorCoords.appendSlice(self.allocator, &cbuf);
            }

            try self.indices.appendSlice(self.allocator, &.{
                baseVert + 0, baseVert + 1, baseVert + 2,
                baseVert + 2, baseVert + 3, baseVert + 0,
            });
        }

        /// Uploads the accumulated quad data to the GPU. After this call the
        /// batch can be drawn any number of times via draw() until the next
        /// beginBuild/endBuild cycle.
        pub fn endBuild(self: *Self) void {
            std.debug.assert(self.building);
            self.building = false;
            self.numIndices = self.indices.items.len;

            if (self.numIndices == 0) return;

            gl.bindVertexArray(self.vao);

            gl.enableVertexAttribArray(self.attrCoord);
            gl.bindBuffer(gl.ARRAY_BUFFER, self.vboVertices);
            gl.bufferData(gl.ARRAY_BUFFER, @intCast(self.vertices.items.len * @sizeOf(f32)), &self.vertices.items[0], gl.STATIC_DRAW);
            gl.vertexAttribPointer(self.attrCoord, layout.posDim, gl.FLOAT, gl.FALSE, 0, null);

            if (comptime hasTex) {
                gl.enableVertexAttribArray(self.attrTexCoord);
                gl.bindBuffer(gl.ARRAY_BUFFER, self.vboTexCoords);
                gl.bufferData(gl.ARRAY_BUFFER, @intCast(self.texCoords.items.len * @sizeOf(f32)), &self.texCoords.items[0], gl.STATIC_DRAW);
                gl.vertexAttribPointer(self.attrTexCoord, layout.texDim, gl.FLOAT, gl.FALSE, 0, null);
            }

            if (comptime hasColor) {
                gl.enableVertexAttribArray(self.attrColor);
                gl.bindBuffer(gl.ARRAY_BUFFER, self.vboColorCoords);
                gl.bufferData(gl.ARRAY_BUFFER, @intCast(self.colorCoords.items.len * @sizeOf(f32)), &self.colorCoords.items[0], gl.STATIC_DRAW);
                gl.vertexAttribPointer(self.attrColor, layout.colorDim, gl.FLOAT, gl.FALSE, 0, null);
            }

            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.vboIndices);
            gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(self.indices.items.len * @sizeOf(u32)), &self.indices.items[0], gl.STATIC_DRAW);

            gl.bindVertexArray(0);
            gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        }

        /// True when the batch has no quads to draw (either never built, or
        /// built with zero quads).
        pub fn isEmpty(self: *const Self) bool {
            return self.numIndices == 0;
        }

        /// Draws the batch's current GPU contents with the given
        /// transform. Assumes the caller has already checked `isEmpty()`
        /// when it needs to skip renderer-specific state (e.g. depth-test
        /// toggling) around an empty draw.
        pub fn draw(self: *Self, mvp: zmath.Mat) void {
            self.refreshShader();
            if (self.numIndices == 0) return;

            const mvpArr = zmath.matToArr(mvp);

            gl.useProgram(self.shader.val.program);
            gl.uniformMatrix4fv(self.uniformMVP, 1, gl.FALSE, @ptrCast(&mvpArr[0]));

            if (comptime hasTex) {
                gl.activeTexture(gl.TEXTURE0);
                gl.bindTexture(gl.TEXTURE_2D, self.texture.?.texture);
                gl.uniform1i(gl.getUniformLocation(self.shader.val.program, "tex"), 0);
            }

            gl.bindVertexArray(self.vao);
            gl.drawElements(gl.TRIANGLES, @intCast(self.numIndices), gl.UNSIGNED_INT, null);
            gl.bindVertexArray(0);
        }
    };
}
