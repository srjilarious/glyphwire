// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! `--screenshot`: reads the composited frame back from GL and writes the
//! grid region to a PNG. `render.Renderer.render` calls it once the
//! capture delay has passed, after the frame is drawn and before the HUD.
//! Split out of `render.zig` (review D3).

const std = @import("std");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const render = @import("render.zig");

const Engine = app_mod.Engine;
const Renderer = render.Renderer;

/// Reads back just the composited grid region -- the left/right
/// `content_pad_px` margins and the scrollbar excluded -- from the GL
/// framebuffer and writes it to `path` as a PNG. Best-effort.
pub fn captureContentArea(self: *Renderer, eng: *Engine, path: []const u8) void {
    const gl = host_eng.gl;
    const fb = eng.window_state.framebuffer_size;
    const x0: i32 = geometry.content_pad_px;

    var used_rows: usize = geometry.min_grid_rows;
    var gutter: i32 = 0;
    {
        const server = self.app.server;
        const session_lock = server.lockSession();
        defer session_lock.unlock();
        // Whatever the grid was sized against -- a context that opts
        // the bar out has no gutter to crop off, unless a pane tree
        // is keeping it reserved.
        gutter = geometry.rightGutterPx(server.ctx.window_scrollbar, server.session.pane_tree.root != null);
        // Cropping to the cursor row keeps a one-line shell session's
        // screenshot from being mostly blank, which is what the README
        // assets want. It only makes sense for a single pane, though:
        // with a pane tree installed, one pane's cursor says nothing
        // about how far down the window has content, so capture the
        // whole grid.
        //
        // The same goes for a full-screen program (zoe, gwmd,
        // salacommander) that has put its own context on screen: the
        // shell's cursor is hidden behind it, so crop nothing.
        if (server.session.pane_tree.root != null or showsOtherContext(self)) {
            used_rows = geometry.grid_rows;
        } else {
            used_rows = @max(geometry.min_grid_rows, server.ctx.root.cursor.row + 2);
        }
    }
    const w: i32 = @min(@as(i32, @intCast(geometry.grid_cols)) * geometry.cell_w, fb.x - gutter - 2 * geometry.content_pad_px);
    used_rows = @min(used_rows, geometry.grid_rows);
    const h: i32 = @min(@as(i32, @intCast(used_rows)) * geometry.cell_h, fb.y);
    if (w <= 0 or h <= 0) {
        std.log.warn("glyphwire-host: screenshot region is empty ({d}x{d}), skipping", .{ w, h });
        return;
    }

    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    const row_bytes = uw * 4;

    const pixels = self.app.alloc.alloc(u8, uh * row_bytes) catch |err| {
        std.log.err("glyphwire-host: screenshot buffer alloc failed: {t}", .{err});
        return;
    };
    defer self.app.alloc.free(pixels);

    gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
    // glReadPixels' origin is the framebuffer's bottom-left; read the
    // top `h` rows.
    gl.readPixels(x0, fb.y - h, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);

    // GL returns rows bottom-to-top; flip so the PNG reads top-to-bottom.
    const tmp = self.app.alloc.alloc(u8, row_bytes) catch return;
    defer self.app.alloc.free(tmp);
    var top: usize = 0;
    var bot: usize = uh - 1;
    while (top < bot) : ({
        top += 1;
        bot -= 1;
    }) {
        @memcpy(tmp, pixels[top * row_bytes ..][0..row_bytes]);
        @memcpy(pixels[top * row_bytes ..][0..row_bytes], pixels[bot * row_bytes ..][0..row_bytes]);
        @memcpy(pixels[bot * row_bytes ..][0..row_bytes], tmp);
    }

    const img = host_eng.stbi.Image{
        .data = pixels,
        .width = @intCast(uw),
        .height = @intCast(uh),
        .num_components = 4,
        .bytes_per_component = 1,
        .bytes_per_row = @intCast(row_bytes),
        .is_hdr = false,
    };
    const path_z = std.mem.concatWithSentinel(self.app.alloc, u8, &.{path}, 0) catch return;
    defer self.app.alloc.free(path_z);
    img.writeToFile(path_z, .png) catch |err| {
        std.log.err("glyphwire-host: screenshot write to '{s}' failed: {t}", .{ path, err });
        return;
    };
    std.log.info("glyphwire-host: wrote screenshot {s} ({d}x{d})", .{ path, uw, uh });
}

/// Whether some mapped pane has a program's context stacked over its
/// base (shell) context. `server.ctx` can't answer this: it follows
/// focus, so it *is* the full-screen program's context by then.
/// Caller holds `ctx_mutex`.
pub fn showsOtherContext(self: *Renderer) bool {
    var it = self.app.server.session.panes.valueIterator();
    while (it.next()) |pane| {
        if (pane.mapped and pane.stack.items.len > 1) return true;
    }
    return false;
}
