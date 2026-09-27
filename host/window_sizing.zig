// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const geometry = @import("geometry.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

/// Window <-> grid size reconciliation and runtime font-size zoom. Holds
/// the primary font file + collection face index so `applyFontSize` can
/// re-measure cell metrics at a new size; `font_path` is process-lifetime
/// (`arena` or a literal), same as it was passed to the renderer.
pub const WindowSizing = struct {
    app: *App,

    font_path: [:0]const u8,
    font_face_index: i32,
    /// Live default-font size in px, and the size Ctrl+0 restores.
    font_size: f32,
    initial_font_size: f32,

    /// A grid size the framebuffer now implies but that hasn't been
    /// committed yet -- held until the window has stopped changing size
    /// for `geometry.resize_settle_ms`, so a drag-resize reflows the grid
    /// (and broadcasts one `resize`) once at the end. Null when the live
    /// framebuffer already matches the committed grid. `pending_elapsed_ms`
    /// counts frame delta since the size last changed.
    pending_grid: ?geometry.GridSize = null,
    pending_elapsed_ms: f64 = 0,

    /// Font file/size passed to `App.init` -- what `applyFontSize` needs to
    /// repeat the startup `measureFontFileIndexed` at a new size.
    pub const FontRuntime = struct {
        path: [:0]const u8,
        face_index: i32,
        size: f32,
    };

    /// Picks up a window resize: converts the current framebuffer size to
    /// a whole-cell grid size (flooring any leftover fractional cell, and
    /// clamping to `min_grid_*`) and, if that differs from the grid the
    /// context currently has, pushes it through `Server.reportResize` --
    /// which resizes the root layer (and every base-size-tracking layer)
    /// bottom-anchored, then broadcasts a `resize` notification to any
    /// subscribed client (e.g. glyphwire-shell). The engine's
    /// `refreshWindowState` (called each frame by the app runner before
    /// this) has already rebuilt the viewport/projection for the new
    /// framebuffer, so `render` just draws the larger or smaller grid.
    ///
    /// The always-on scrollbar's gutter (`geometry.rightGutterPx`) plus a
    /// `content_pad_px` margin on each side of the grid are subtracted
    /// from the usable width before dividing into cells, so the last
    /// column isn't lost under the bar or the padding. The initial window
    /// (see `main`) is opened that much wider than the grid for the same
    /// reason. The gutter is unconditional -- a context that opts the bar
    /// out does not reclaim its columns, so creating or destroying such a
    /// context never resizes the grid; see `geometry.rightGutterPx`.
    ///
    /// The new size is debounced: while the window is actively being
    /// dragged the grid stays put (the render clips or letterboxes the
    /// old grid into the new framebuffer), and the `reportResize` that
    /// reflows every client fires once, `geometry.resize_settle_ms` after
    /// the last size change. `App.idleTimeoutMs` returns a bounded wait
    /// while `pending_grid` is set so the loop wakes to flush it even
    /// after the OS event stream goes quiet.
    pub fn syncWindowSize(self: *WindowSizing, eng: *Engine, delta_ms: f64) void {
        const fb = eng.window_state.framebuffer_size;
        if (geometry.cell_w <= 0 or geometry.cell_h <= 0) return;

        const target = geometry.gridForFramebuffer(.{ .w = fb.x, .h = fb.y }, self.gutterPx(), geometry.cell_w, geometry.cell_h);
        const cols = target.cols;
        const rows = target.rows;
        const committed: geometry.GridSize = .{ .cols = geometry.grid_cols, .rows = geometry.grid_rows };
        self.pending_elapsed_ms += delta_ms;

        switch (geometry.resizeSettleStep(committed, target, self.pending_grid, self.pending_elapsed_ms)) {
            .settled => self.pending_grid = null,
            .wait => {},
            .restart => {
                self.pending_grid = target;
                self.pending_elapsed_ms = 0;
            },
            .commit => {
                self.pending_grid = null;
                self.app.server.reportResize(self.app.alloc, cols, rows) catch |err| {
                    std.log.err("glyphwire-host: reportResize({d}x{d}) failed: {t}", .{ cols, rows, err });
                    return;
                };
                geometry.grid_cols = cols;
                geometry.grid_rows = rows;
            },
        }
    }

    /// The right gutter for the context currently on screen. Zero for one
    /// that opts the window scrollbar out, whose columns are then the
    /// grid's -- see `geometry.rightGutterPx` for what that costs.
    ///
    /// Read under `ctx_mutex` and never cached: it changes whenever the
    /// visible context does, and the next `syncWindowSize` is what turns
    /// that into a grid size. Cheap enough to take per frame, and the
    /// resize it may produce is debounced like any other.
    fn gutterPx(self: *WindowSizing) i32 {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        return geometry.rightGutterPx(server.ctx.window_scrollbar);
    }

    /// A bounded wait, in ms, while a resize is still settling -- null
    /// otherwise. `App.idleTimeoutMs` folds this in so the frame loop
    /// wakes to commit a settled resize even with no pending OS event.
    pub fn settleTimeoutMs(self: *const WindowSizing) ?f64 {
        if (self.pending_grid == null) return null;
        return @max(4.0, @as(f64, @floatFromInt(geometry.resize_settle_ms)) - self.pending_elapsed_ms);
    }

    /// Ctrl+- / Ctrl++ step the font size by `font_size_step` (clamped to
    /// `[min_font_size, max_font_size]`); Ctrl+0 restores the startup size.
    /// The matching keys are held back from `input.KeyInput.reportKeyEvents`
    /// while Ctrl is down so the shell never sees them.
    pub fn handleFontZoom(self: *WindowSizing, eng: *Engine) void {
        const kb = &eng.inputs.keyboard;
        if (!kb.ctrl()) return;

        const target: f32 = if (kb.pressed(.minus) or kb.pressed(.kp_subtract))
            @max(config.min_font_size, self.font_size - config.font_size_step)
        else if (kb.pressed(.equal) or kb.pressed(.kp_add))
            @min(config.max_font_size, self.font_size + config.font_size_step)
        else if (kb.pressed(.zero) or kb.pressed(.kp_0))
            self.initial_font_size
        else
            return;

        if (target == self.font_size) return;
        self.applyFontSize(eng, target);
    }

    /// Repacks the default font atlas at `size_px`, re-measures the cell
    /// metrics from the same face, and reflows the grid to however many
    /// of the new cells the window already holds: the window keeps its
    /// size and the cell count changes, not the other way round. A
    /// failure before the atlas repack leaves the previous size in place.
    ///
    /// The new grid is committed at once rather than through
    /// `syncWindowSize`'s drag debounce -- until it is, the old cell count
    /// would be drawn at the new cell size and overrun the window.
    ///
    /// The one case the window does change: a step so large that even
    /// `min_grid_cols` x `min_grid_rows` no longer fits, where the short
    /// axis grows just enough to hold the minimum (`geometry.fontStepFit`).
    pub fn applyFontSize(self: *WindowSizing, eng: *Engine, size_px: f32) void {
        const fa = eng.defaultFontAtlas() orelse {
            std.log.warn("glyphwire-host: no resizable default font atlas", .{});
            return;
        };

        // Measure first: if this fails we haven't touched the live atlas.
        const metrics = host_eng.renderer.measureFontFileIndexed(
            self.font_path,
            self.font_face_index,
            size_px,
            self.app.alloc,
        ) catch |err| {
            std.log.err("glyphwire-host: re-measuring font at {d}px failed: {t}", .{ size_px, err });
            return;
        };

        fa.setFontSize(size_px) catch |err| {
            std.log.err("glyphwire-host: font atlas resize to {d}px failed: {t}", .{ size_px, err });
            return;
        };

        self.font_size = size_px;
        geometry.cell_w = metrics.advance;
        geometry.cell_h = metrics.line_height;

        const fb = eng.window_state.framebuffer_size;
        const fit = geometry.fontStepFit(.{ .w = fb.x, .h = fb.y }, self.gutterPx(), geometry.cell_w, geometry.cell_h);
        if (fit.grow) |px| growWindowTo(eng, px);

        // Metrics and size in one call, so every context (backgrounded
        // ones and every pane's) is caught up and every client gets a
        // `resize` even when the cell count didn't move -- see
        // `Server.reportFontStep`. The metrics half also re-derives the
        // pixel position of every cell-placed layer (see
        // `core.PropertyName.cell_position`).
        self.app.server.reportFontStep(
            self.app.alloc,
            @intCast(geometry.cell_w),
            @intCast(geometry.cell_h),
            fit.grid.cols,
            fit.grid.rows,
        ) catch |err| {
            std.log.err("glyphwire-host: reportFontStep({d}x{d}) failed: {t}", .{ fit.grid.cols, fit.grid.rows, err });
        };
        geometry.grid_cols = fit.grid.cols;
        geometry.grid_rows = fit.grid.rows;
        // A half-settled drag resize was measured against the old cells.
        self.pending_grid = null;
        self.pending_elapsed_ms = 0;
    }

    /// Resizes the OS window so its framebuffer is at least `target` --
    /// only for a font step the minimum grid no longer fits. The
    /// framebuffer -> window ratio handles HiDPI; `divCeil` biases the
    /// window up so rounding never drops a cell. A tiling WM that ignores
    /// the request leaves the minimum grid clipped, the same as a window
    /// dragged too small.
    fn growWindowTo(eng: *Engine, target: geometry.PxSize) void {
        const ws = &eng.window_state;
        const fb = ws.framebuffer_size;
        if (fb.x <= 0 or fb.y <= 0 or ws.window_size.x <= 0 or ws.window_size.y <= 0) return;

        const win_w = std.math.divCeil(i32, target.w * ws.window_size.x, fb.x) catch return;
        const win_h = std.math.divCeil(i32, target.h * ws.window_size.y, fb.y) catch return;
        eng.window.setSize(win_w, win_h);
    }
};
