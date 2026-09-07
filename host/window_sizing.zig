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
    /// The always-on scrollbar (`scrollbar_width_px`) plus a
    /// `content_pad_px` margin on each side of the grid are subtracted
    /// from the usable width before dividing into cells, so the last
    /// column isn't lost under the bar or the padding. The initial window
    /// (see `main`) is opened that much wider than the grid for the same
    /// reason.
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
        const cols: usize = @intCast(@max(@divTrunc(fb.x - 2 * geometry.content_pad_px - geometry.scrollbar_width_px, geometry.cell_w), geometry.min_grid_cols));
        const rows: usize = @intCast(@max(@divTrunc(fb.y, geometry.cell_h), geometry.min_grid_rows));

        const target: geometry.GridSize = .{ .cols = cols, .rows = rows };
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
    /// metrics from the same face, updates `cell_w`/`cell_h` and the
    /// RPC-visible `ctx.cell_px_*`, and resizes the window so the current
    /// `grid_cols` x `grid_rows` still fits. Any step failing leaves the
    /// previous size in place.
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

        // Keep the metrics clients query via `get_cell_metrics` (e.g.
        // glyphwire-shell sizing an image) in step. `ctx_mutex`-guarded
        // like every other host write to `ctx`. Already-connected clients
        // are not proactively notified of a cell-size change.
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        // `setCellMetrics`, not a pair of field writes: it also re-derives
        // the pixel position of every cell-placed layer against the new
        // metrics (see `core.PropertyName.cell_position`). Applied to
        // every context -- a font-size step is session-wide, so a
        // backgrounded context is caught up too.
        server.session.setCellMetricsAll(@intCast(geometry.cell_w), @intCast(geometry.cell_h));
        server.ctx_mutex.unlock(server.io);

        self.resizeWindowForCells(eng);
    }

    /// Resizes the OS window so a framebuffer of exactly
    /// `grid_cols` x `grid_rows` cells (plus the scrollbar and side
    /// padding) fits -- the inverse of `syncWindowSize`'s cell math, so it
    /// round-trips back to the same cell counts next frame with no
    /// `reportResize`. The framebuffer -> window ratio handles HiDPI;
    /// `divCeil` biases the window up so rounding never drops a cell. A
    /// tiling WM that ignores the request just leaves `syncWindowSize` to
    /// reflow the grid to whatever size it forces instead.
    pub fn resizeWindowForCells(self: *WindowSizing, eng: *Engine) void {
        _ = self;
        const ws = &eng.window_state;
        const fb = ws.framebuffer_size;
        if (fb.x <= 0 or fb.y <= 0 or ws.window_size.x <= 0 or ws.window_size.y <= 0) return;

        const target_fb_w = @as(i32, @intCast(geometry.grid_cols)) * geometry.cell_w + 2 * geometry.content_pad_px + geometry.scrollbar_width_px;
        const target_fb_h = @as(i32, @intCast(geometry.grid_rows)) * geometry.cell_h;

        const win_w = std.math.divCeil(i32, target_fb_w * ws.window_size.x, fb.x) catch return;
        const win_h = std.math.divCeil(i32, target_fb_h * ws.window_size.y, fb.y) catch return;
        eng.window.setSize(win_w, win_h);
    }
};
