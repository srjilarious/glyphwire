// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The host's immediate-mode overlays: everything drawn over the cached
//! layer batches through the engine's `Renderer` rather than out of
//! `render.zig`'s static batches. The caret and IME preedit, layer and
//! pane dividers, scrollbars and resize edges, the modal list dialog and
//! the profiler HUD. `render.Renderer.render` decides when each one is
//! drawn; these only draw. Split out of `render.zig` (review D3).

const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const geometry = @import("geometry.zig");
const dividers = @import("dividers.zig");
const pane_focus = @import("pane_focus.zig");
const shadow_mod = @import("shadow.zig");
const scroll = @import("scroll.zig");
const selection = @import("selection.zig");
const preedit_mod = @import("preedit.zig");
const modal_list = @import("modal_list.zig");
const render = @import("render.zig");

const Engine = app_mod.Engine;
const CursorShape = config.CursorShape;
const Renderer = render.Renderer;

// Width in px of the `.line` caret, and thickness in px of the
// `.underline` bar and the `.box` outline.
const cursor_width = 2;
const cursor_underline_px = 2;
const cursor_box_line_px = 2;

/// IME composition overlay: a dark plate behind the in-progress text so
/// the grid content it covers doesn't show through, and an underline
/// marking it as uncommitted -- the convention every terminal and text
/// field uses for preedit. See `drawPreedit`.
const preedit_bg = host_eng.Color.from(40, 44, 60, 255);
const preedit_fg = host_eng.Color.from(235, 235, 240, 255);
const preedit_underline_px = 2;

// Profiler HUD overlay (Ctrl+Alt+Shift+P). A translucent plate top-right
// with one text line per timed phase / counter -- see `drawProfilerHud`.
const hud_bg = host_eng.Color.from(12, 14, 20, 232);
const hud_head = host_eng.Color.from(255, 220, 120, 255);
const hud_fg = host_eng.Color.from(210, 215, 225, 255);

// The divider band between two split children is the context theme's
// `divider` role, and the band between two whole *panes* -- one program's
// surface against another's -- the window theme's brighter `pane_divider`:
// the seam between programs is the more significant boundary and should
// read that way.

/// The ghost band shown while a divider is being dragged, before the
/// drag ends and the layout actually moves (see `panes.Panes`).
const divider_preview_color = host_eng.Color.from(120, 120, 140, 255);

/// A pane scrollbar's track and thumb. The track is nearly transparent --
/// it sits over content rather than in a reserved gutter, so it should
/// register as a hint until the thumb is grabbed.
const pane_track_color = host_eng.Color.from(40, 40, 46, 140);
const pane_thumb_color = host_eng.Color.from(120, 120, 130, 220);

/// A floating layer's `resize_edge` band, over the outer pixels of
/// its own edge row or column (`geometry.resizeEdgeBand`). Drawn with the layer,
/// like its scrollbars, so a popup over the layer covers it too --
/// matching `Panes.edgeAt`, which won't grab an edge it can't see.
pub fn drawResizeEdge(eng: *Engine, layer: *const glyphwire.Layer, origin: geometry.Origin, color: host_eng.Color) void {
    if (layer.resize_edge == .none) return;
    const r = geometry.resizeEdgeBand(geometry.layerRectIn(origin, layer.pos, layer.viewportCols(), layer.viewportRows()), layer.resize_edge);
    eng.renderer.begin(eng.projMat);
    defer eng.renderer.end();
    eng.renderer.drawFilledRect(
        host_eng.RectF{ .l = r.x, .t = r.y, .r = r.x + r.w, .b = r.y + r.h },
        color,
    );
}

/// One context's layer-split bands. Drawn per context inside
/// `drawOneContext` rather than with the pane bands in the chrome
/// pass, so a floating layer covers them -- the same move
/// `drawLayerScrollbars` made, for the same reason.
///
/// `App.panes` holds every band for every on-screen context, already
/// translated into window cells (`Panes.syncLocked`), so this filters
/// the cache down to the context being composited and draws those
/// where they are. The cache is refreshed each frame by the mouse
/// handler, which runs before any of this.
///
/// The style is the host's `pane_divider` with the context's own
/// `set_divider_style` laid over it; the colour is always the
/// context theme's dimmer `divider` role, so the seam between
/// programs still reads as the bigger boundary.
pub fn drawLayerDividers(self: *Renderer, eng: *Engine, ctx_handle: glyphwire.ContextHandle, ctx: *const glyphwire.Context) void {
    // `render` holds `ctx_mutex` around this whole pass, which is what
    // `syncLocked` wants. Refreshing here rather than relying on the
    // mouse handler keeps the bands right in a session that has never
    // seen a pointer.
    self.app.panes.syncLocked();
    const color = themeColor(&ctx.theme, .divider);
    const style = ctx.divider_style.resolve(self.pane_divider);
    const glyphs: ?*const dividers.Glyphs = switch (style) {
        .block => null,
        .glyphs => |*g| g,
    };

    const alloc = self.app.alloc;
    self.layer_divider_lines.clearRetainingCapacity();
    var drawing = false;
    defer if (drawing) eng.renderer.end();
    for (self.app.panes.bands.items) |d| {
        switch (d.level) {
            .pane, .edge => continue,
            .layer => |h| if (h != ctx_handle) continue,
        }
        if (!drawing) {
            drawing = true;
            eng.renderer.begin(eng.projMat);
        }
        // A glyph covers only part of its cell, so a glyph band gets
        // the context's background under it, as a pane band gets the
        // window's.
        const r = geometry.cellRectPx(d.rect);
        eng.renderer.drawFilledRect(
            host_eng.RectF{ .l = r.x, .t = r.y, .r = r.x + r.w, .b = r.y + r.h },
            if (glyphs == null) color else themeColor(&ctx.theme, .bg),
        );
        if (glyphs != null) {
            self.layer_divider_lines.append(alloc, .{ .rect = d.rect, .vertical = d.axis == .row }) catch return;
        }
    }
    const g = glyphs orelse return;
    if (self.layer_divider_lines.items.len == 0) return;
    dividers.layout(alloc, self.layer_divider_lines.items, g, &self.layer_divider_cells) catch return;
    for (self.layer_divider_cells.items) |c| _ = drawCellText(eng, c.glyph, c.col, c.row, 1, color);
}

/// Paints whichever modal list dialog is open (`host/modal_list.zig`:
/// the context switcher or the theme switcher), centred on the pane
/// it was opened from. Looks like zoe's file finder: the window
/// theme's `panel_style` nine-patch one cell out round the content,
/// standing off the screen on `Shadow.dialog`, a title bar in the
/// finder header colours, and the selected row in the list cursor's.
/// Cell-aligned like `drawPreedit`, so its text sits on the same grid
/// as the content around it.
///
/// Immediate mode, so the draw order is the engine's per-`end`
/// order: textured quads (shadow, then frame), then flat fills (title
/// bar, selection), then text.
pub fn drawListDialog(self: *Renderer, eng: *Engine) void {
    const view = self.app.switcher.view() orelse self.app.theme_switcher.view() orelse return;

    const server = self.app.server;
    const session_lock = server.lockSession();
    defer session_lock.unlock();

    const pane = server.session.panePtr(view.pane) orelse return;
    const area: modal_list.Rect = .{ .row = pane.rect.row, .col = pane.rect.col, .rows = pane.rect.rows, .cols = pane.rect.cols };
    const lay = modal_list.layout(area, view) orelse return;

    // The window theme's, not the pane program's: the dialog is the
    // host's, and the theme switcher's preview should show on it.
    const th = &server.session.theme;
    const header_bg = themeColor(th, .finder_header_bg);
    const header_fg = themeColor(th, .finder_header_fg);
    const sel_bg = themeColor(th, .list_cursor_bg);
    const sel_fg = themeColor(th, .list_cursor_fg);
    const text_fg = themeColor(th, .popup_fg);
    const dim_fg = themeColor(th, .fg_dim);

    eng.renderer.begin(eng.projMat);
    defer eng.renderer.end();

    const frame = geometry.cellRectPx(.{ .row = lay.frame.row, .col = lay.frame.col, .rows = lay.frame.rows, .cols = lay.frame.cols });
    const fx: i32 = @intFromFloat(frame.x);
    const fy: i32 = @intFromFloat(frame.y);
    const fw: i32 = @intFromFloat(frame.w);
    const fh: i32 = @intFromFloat(frame.h);
    drawShadowImmediate(self, eng, glyphwire.Shadow.dialog, fx, fy, fw, fh);
    if (!drawNinePatchImmediate(self, eng, th.panelStyle(), fx, fy, fw, fh)) {
        // No such nine-patch: a flat panel in the popup colour.
        eng.renderer.drawFilledRect(host_eng.RectF{ .l = frame.x, .t = frame.y, .r = frame.x + frame.w, .b = frame.y + frame.h }, themeColor(th, .popup_bg));
    }

    const c = lay.content;
    const inner = c.cols -| 2;
    fillCells(eng, .{ .row = c.row, .col = c.col, .rows = 1, .cols = c.cols }, header_bg);
    _ = drawCellText(eng, view.title, c.col + 1, c.row, inner, header_fg);

    for (view.rows[lay.first .. lay.first + lay.visible], lay.first..) |row, i| {
        const r = c.row + 1 + (i - lay.first);
        const selected = i == view.selected;
        if (selected) fillCells(eng, .{ .row = r, .col = c.col, .rows = 1, .cols = c.cols }, sel_bg);
        if (modal_list.label(i)) |key| {
            _ = drawCellText(eng, &.{key}, c.col + 1, r, inner, if (selected) sel_fg else dim_fg);
        }
        const text_cols = inner -| modal_list.label_cols;
        const used = drawCellText(eng, row.text, c.col + 1 + modal_list.label_cols, r, text_cols, if (selected) sel_fg else text_fg);
        _ = drawCellText(eng, row.tag, c.col + 1 + modal_list.label_cols + used, r, text_cols -| used, if (selected) sel_fg else dim_fg);
    }
    _ = drawCellText(eng, view.foot, c.col + 1, c.row + c.rows - 1, inner, dim_fg);
}

pub fn fillCells(eng: *Engine, rect: glyphwire.CellRect, color: host_eng.Color) void {
    const px = geometry.cellRectPx(rect);
    eng.renderer.drawFilledRect(host_eng.RectF{ .l = px.x, .t = px.y, .r = px.x + px.w, .b = px.y + px.h }, color);
}

/// `emitShadow` for an immediate-mode overlay: the same cached
/// texture and split, queued on the renderer's sprite batch.
pub fn drawShadowImmediate(self: *Renderer, eng: *Engine, sh: glyphwire.Shadow, x0: i32, y0: i32, w: i32, h: i32) void {
    const out = shadow_mod.outset(sh);
    const dw = w + 2 * out;
    const dh = h + 2 * out;
    if (dw <= 0 or dh <= 0) return;
    const tex = self.shadowTexture(eng, sh) orelse return;
    const g = shadow_mod.geometry(sh);
    const left = x0 + sh.x - out;
    const top = y0 + sh.y - out;
    const side: f32 = @floatFromInt(g.side);
    for (glyphwire.ninePatchQuads(g.style(), @intCast(dw), @intCast(dh))) |q| {
        if (q.dst_w == 0 or q.dst_h == 0 or q.src_w == 0 or q.src_h == 0) continue;
        eng.renderer.draw(tex, host_eng.RectF.fromPosSize(
            left + @as(i32, @intCast(q.dst_x)),
            top + @as(i32, @intCast(q.dst_y)),
            @intCast(q.dst_w),
            @intCast(q.dst_h),
        ), .{
            .l = @as(f32, @floatFromInt(q.src_x)) / side,
            .t = @as(f32, @floatFromInt(q.src_y)) / side,
            .r = @as(f32, @floatFromInt(q.src_x + q.src_w)) / side,
            .b = @as(f32, @floatFromInt(q.src_y + q.src_h)) / side,
        });
    }
}

/// `emitNinePatch` for an immediate-mode overlay: the root context's
/// nine-patch style `name` over the `w x h` pixel rect at `(x0, y0)`.
/// False when there is no such style (or its image won't load), so
/// the caller can draw something flat instead. Call under `ctx_mutex`.
pub fn drawNinePatchImmediate(self: *Renderer, eng: *Engine, name: []const u8, x0: i32, y0: i32, w: i32, h: i32) bool {
    if (w <= 0 or h <= 0) return false;
    const root = self.app.server.session.rootContext();
    const style = root.ninePatchStyle(name) orelse return false;
    const entry = self.imageEntryIn(glyphwire.root_context_handle, style.image) orelse return false;
    const tex = self.textureForImage(eng, glyphwire.root_context_handle, style.image) orelse return false;
    const tex_w: f32 = @floatFromInt(entry.width);
    const tex_h: f32 = @floatFromInt(entry.height);
    for (glyphwire.ninePatchQuads(style, @intCast(w), @intCast(h))) |q| {
        if (q.dst_w == 0 or q.dst_h == 0 or q.src_w == 0 or q.src_h == 0) continue;
        eng.renderer.draw(tex, host_eng.RectF.fromPosSize(
            x0 + @as(i32, @intCast(q.dst_x)),
            y0 + @as(i32, @intCast(q.dst_y)),
            @intCast(q.dst_w),
            @intCast(q.dst_h),
        ), .{
            .l = @as(f32, @floatFromInt(q.src_x)) / tex_w,
            .t = @as(f32, @floatFromInt(q.src_y)) / tex_h,
            .r = @as(f32, @floatFromInt(q.src_x + q.src_w)) / tex_w,
            .b = @as(f32, @floatFromInt(q.src_y + q.src_h)) / tex_h,
        });
    }
    return true;
}

/// Paints the profiler overlay in the top-right corner while the HUD
/// is toggled on (Ctrl+Alt+Shift+P; only possible when
/// `host.conf.lua` set `profile`). Immediate-mode like the caret.
/// Lines are formatted first so the panel can be sized to the widest
/// one (and clamped to the window) -- monospace, so column count is
/// exact. All numbers
/// are the profiler's windowed values, not lifetime.
pub fn drawProfilerHud(self: *Renderer, eng: *Engine) void {
    if (!self.app.profiler.hud_visible) return;
    const snap = self.app.profiler.snapshot();

    const cap = 2 + glyphwire.profile_max_phases + glyphwire.profile_max_counters;
    var text: [cap][80]u8 = undefined;
    var len: [cap]usize = undefined;
    var head: [cap]bool = undefined;
    var n: usize = 0;

    const put = struct {
        fn f(buf: []u8, comptime fmt: []const u8, args: anytype) usize {
            const s = std.fmt.bufPrint(buf, fmt, args) catch return 0;
            return s.len;
        }
    }.f;

    const mode: []const u8 = if (self.app.profiler.force_redraw) "   [FORCED REDRAW]" else "";
    len[n] = put(&text[n], "PROFILER   fps {d:.1}   skip/s {d:.0}{s}", .{ snap.fps, snap.skips_per_sec, mode });
    head[n] = true;
    n += 1;
    len[n] = put(&text[n], "phase           avg     p95     max", .{});
    head[n] = true;
    n += 1;
    for (snap.phaseSlice()) |ph| {
        len[n] = put(&text[n], "  {s:<12}{d:>7.2} {d:>7.2} {d:>7.2}", .{ ph.name, ph.avg_ms, ph.p95_ms, ph.max_ms });
        head[n] = false;
        n += 1;
    }
    len[n] = put(&text[n], "counter       per frame", .{});
    head[n] = true;
    n += 1;
    for (snap.counterSlice()) |c| {
        len[n] = put(&text[n], "  {s:<14}{d:>9.1}", .{ c.name, c.per_frame });
        head[n] = false;
        n += 1;
    }

    var max_cols: i32 = 0;
    for (len[0..n]) |l| max_cols = @max(max_cols, @as(i32, @intCast(l)));

    const pad: i32 = 6;
    const line_h: i32 = geometry.cell_h;
    const char_w: i32 = geometry.cell_w;
    const fb = eng.window_state.framebuffer_size;
    const panel_w = @min(max_cols * char_w + pad * 2, @max(char_w, fb.x - pad * 2));
    const panel_h = @as(i32, @intCast(n)) * line_h + pad * 2;
    const x0: i32 = @max(pad, fb.x - panel_w - pad);
    const y0: i32 = pad;

    eng.renderer.begin(eng.projMat);
    defer eng.renderer.end();
    eng.renderer.drawFilledRect(host_eng.RectF.fromPosSize(x0, y0, panel_w, panel_h), hud_bg);
    for (0..n) |i| {
        _ = eng.renderer.drawStringColored(
            text[i][0..len[i]],
            .{ .x = x0 + pad, .y = y0 + pad + @as(i32, @intCast(i)) * line_h },
            if (head[i]) hud_head else hud_fg,
        );
    }
}

/// The caret for the root layer, drawn immediately (never batched) and
/// only while visible -- it blinks on its own clock (see `Caret`).
/// Normally at the live grid cursor; a mouse-driven scroll pins it
/// (`caret.Caret.pin`) to the buffer cell it was on when the scroll
/// began, clipping off-screen once that cell leaves the viewport.
pub fn drawRootCaret(self: *Renderer, eng: *Engine, root: *const glyphwire.Layer, origin_x: i32, origin_y: i32, view_offset: usize, shape: CursorShape, color: host_eng.Color) void {
    if (!self.app.caret.visible()) return;
    const cell = self.app.caret.screenCell(root, view_offset) orelse return;

    eng.renderer.begin(eng.projMat);
    drawCaret(eng, root, origin_x, origin_y, cell.row, cell.col, view_offset, shape, color);
    eng.renderer.end();
}

/// An unfocused pane's root caret: a steady hollow box at its grid
/// cursor. Not `drawRootCaret`, whose blink clock and scroll pin
/// belong to the focused context. Hidden by DECTCEM like any caret.
pub fn drawIdleRootCaret(eng: *Engine, root: *const glyphwire.Layer, origin_x: i32, origin_y: i32, view_offset: usize, color: host_eng.Color) void {
    if (!root.vt.cursor_visible) return;
    if (root.cursor.row >= root.height or root.cursor.col >= root.width) return;
    eng.renderer.begin(eng.projMat);
    drawCaret(eng, root, origin_x, origin_y, root.cursor.row, root.cursor.col, view_offset, .box, color);
    eng.renderer.end();
}

/// The caret for a `caret_layer` pane (see `core.Context.caret_layer`):
/// `gmux` points it at the focused pane, whose cursor is driven by
/// that pane's PTY. Positioned through the pane's own bounds
/// (`layer.pos`, set by the split layout), viewport and scroll
/// offset -- the same transform `syncOneLayer` uses for the pane's
/// content. Hidden while the pane has DECTCEM cursor-hide set, while
/// it is scrolled back into its own history (`view_scroll != 0`), or
/// while the cursor sits outside the visible viewport. Shares the
/// blink clock with the root caret.
/// `blink` is false for an unfocused pane's caret, which holds still.
pub fn drawFocusedCaret(self: *Renderer, eng: *Engine, layer: *const glyphwire.Layer, origin: geometry.Origin, shape: CursorShape, color: host_eng.Color, blink: bool) void {
    if (!layer.vt.cursor_visible) return;
    if (blink and !self.app.caret.blinkOn()) return;
    if (layer.view_scroll != 0) return;

    const off = layer.scroll_off;
    if (layer.cursor.row < off.row or layer.cursor.col < off.col) return;
    const crow = layer.cursor.row - off.row;
    const ccol = layer.cursor.col - off.col;
    if (crow >= layer.viewportRows() or ccol >= layer.viewportCols()) return;

    const ox = @as(i32, @intFromFloat(@round(layer.pos.x))) + origin.x;
    const oy = @as(i32, @intFromFloat(@round(layer.pos.y))) + origin.y;

    eng.renderer.begin(eng.projMat);
    drawCaret(eng, layer, ox, oy, crow, ccol, 0, shape, color);
    eng.renderer.end();
}

/// Paints the IME's in-progress composition over the grid, starting at
/// the caret cell and running right along the row. Uncommitted text
/// never reaches the `text` event stream (that only carries what the
/// IME has committed), so without this the user types Japanese into an
/// apparently dead terminal and only sees the result on commit.
///
/// Drawn cell-aligned using glyphwire's own East Asian Width rules
/// rather than the font's advances, so it sits on the same column grid
/// as the content underneath. Clipped at the row's right edge -- a
/// composition longer than the remaining columns just stops; it is
/// transient overlay text, not grid content, and wrapping it would
/// have to reflow around content it is about to replace anyway.
pub fn drawPreedit(self: *Renderer, eng: *Engine, root: *const glyphwire.Layer, origin_x: i32, origin_y: i32, view_offset: usize) void {

    const text = self.app.preedit.text(eng);
    if (text.len == 0) return;
    const cell = self.app.caret.screenCell(root, view_offset) orelse return;

    const cols_left = root.width - cell.col;
    const span_cols = @min(preedit_mod.Preedit.cellWidth(text), cols_left);
    if (span_cols == 0) return;

    const x0 = origin_x + @as(i32, @intCast(cell.col)) * geometry.cell_w;
    const y0 = origin_y + @as(i32, @intCast(cell.row)) * geometry.cell_h;
    const span_px = @as(i32, @intCast(span_cols)) * geometry.cell_w;

    eng.renderer.begin(eng.projMat);
    defer eng.renderer.end();

    eng.renderer.drawFilledRect(
        host_eng.RectF.fromPosSize(x0, y0, span_px, geometry.cell_h),
        preedit_bg,
    );

    // One `drawStringColored` per codepoint so each lands on its own
    // cell boundary, and so the renderer's `syncAtlasForText` packs
    // any CJK glyph that isn't in the atlas yet before drawing it.
    const cursor_byte = self.app.preedit.cursorByte(eng);
    var cursor_col: ?usize = null;
    var col = cell.col;
    var byte: usize = 0;
    var it = (std.unicode.Utf8View.initUnchecked(text)).iterator();
    while (it.nextCodepointSlice()) |cp_bytes| {
        if (cursor_byte) |cb| {
            if (cursor_col == null and byte >= cb) cursor_col = col;
        }
        const cp = std.unicode.utf8Decode(cp_bytes) catch continue;
        const w: usize = @max(1, glyphwire.codepointWidth(cp));
        if (col + w > root.width) break;
        _ = eng.renderer.drawStringColored(cp_bytes, .{
            .x = origin_x + @as(i32, @intCast(col)) * geometry.cell_w,
            .y = y0,
        }, preedit_fg);
        col += w;
        byte += cp_bytes.len;
    }
    // Cursor at the very end of the composition: the loop never saw a
    // codepoint at or past it, so it lands on the column after the last.
    if (cursor_byte != null and cursor_col == null) cursor_col = col;

    eng.renderer.drawFilledRect(
        host_eng.RectF.fromPosSize(x0, y0 + geometry.cell_h - preedit_underline_px, span_px, preedit_underline_px),
        preedit_fg,
    );

    // The IME's own caret inside the composition -- where the next
    // keystroke lands, which is not necessarily the end (arrow keys
    // move within a composition before it commits).
    if (cursor_col) |cc| {
        if (cc <= root.width) {
            eng.renderer.drawFilledRect(
                host_eng.RectF.fromPosSize(
                    origin_x + @as(i32, @intCast(cc)) * geometry.cell_w,
                    y0,
                    cursor_width,
                    geometry.cell_h,
                ),
                preedit_fg,
            );
        }
    }
}

/// Paints the caret for `layer` at grid cell `(crow, ccol)` (already
/// resolved by the caller). `block`/`box`/`underline` cover the whole
/// cell -- two cells on the lead of a wide (CJK) character -- while
/// `line` stays a thin bar at the left edge. Assumes an open renderer
/// pass.
/// The caret is the theme's `cursor_bg`: a fixed white would vanish
/// on a light theme.
pub fn caretColor(th: *const glyphwire.theme.Stored) host_eng.Color {
    const c = th.theme.roleColor(.cursor_bg);
    return host_eng.Color.from(c.r, c.g, c.b, 255);
}

/// `th`'s colour for role `r`, for the host's own chrome.
pub fn themeColor(th: *const glyphwire.theme.Stored, r: glyphwire.theme.Role) host_eng.Color {
    const c = th.theme.roleColor(r);
    return host_eng.Color.from(c.r, c.g, c.b, c.a);
}

pub fn drawCaret(eng: *Engine, layer: *const glyphwire.Layer, origin_x: i32, origin_y: i32, crow: usize, ccol: usize, view_offset: usize, shape: CursorShape, color: host_eng.Color) void {
    const cx = origin_x + @as(i32, @intCast(ccol)) * geometry.cell_w;
    const cy = origin_y + @as(i32, @intCast(crow)) * geometry.cell_h;

    const on_wide_lead = layer.viewRow(view_offset, crow)[ccol].wide == .wide_lead;
    const cell_span: i32 = if (on_wide_lead) geometry.cell_w * 2 else geometry.cell_w;

    switch (shape) {
        .line => eng.renderer.drawFilledRect(
            host_eng.RectF.fromPosSize(cx, cy, cursor_width, geometry.cell_h),
            color,
        ),
        .block => eng.renderer.drawFilledRect(
            host_eng.RectF.fromPosSize(cx, cy, cell_span, geometry.cell_h),
            color,
        ),
        .box => eng.renderer.drawRect(
            host_eng.RectF.fromPosSize(cx, cy, cell_span, geometry.cell_h),
            color,
            cursor_box_line_px,
        ),
        .underline => eng.renderer.drawFilledRect(
            host_eng.RectF.fromPosSize(cx, cy + geometry.cell_h - cursor_underline_px, cell_span, cursor_underline_px),
            color,
        ),
    }
}

/// The bands between *panes*, drawn as a flat separator over
/// everything: they separate whole programs, so nothing one program
/// draws may cover them. Their geometry comes from `App.panes`' cache,
/// which the mouse handler already refreshes each frame -- see
/// `panes.Panes.syncLocked`.
///
/// A context's own layer bands are *not* drawn here. See
/// `drawLayerDividers`.
pub fn renderDividers(self: *Renderer, eng: *Engine) void {
    const server = self.app.server;
    // The window theme's: a band between panes belongs to no program.
    const color, const bg, const focus = blk: {
        const session_lock = server.lockSession();
        defer session_lock.unlock();
        self.app.panes.syncLocked();
        break :blk .{
            themeColor(&server.session.theme, .pane_divider),
            themeColor(&server.session.theme, .bg),
            focusHighlight(self),
        };
    };
    switch (self.pane_divider) {
        .block => for (self.app.panes.bands.items) |d| {
            if (d.level != .pane) continue;
            const r = geometry.cellRectPx(d.rect);
            eng.renderer.drawFilledRect(
                host_eng.RectF{ .l = r.x, .t = r.y, .r = r.x + r.w, .b = r.y + r.h },
                color,
            );
            // The stretch of this band along the focused pane, over
            // the band just drawn.
            const f = focus orelse continue;
            const part = pane_focus.clip(d.rect, f.rect) orelse continue;
            const pr = geometry.cellRectPx(part);
            eng.renderer.drawFilledRect(
                host_eng.RectF{ .l = pr.x, .t = pr.y, .r = pr.x + pr.w, .b = pr.y + pr.h },
                f.color,
            );
        },
        .glyphs => |*g| {
            syncDividerCells(self, g);
            // The band's own cells are nobody's surface, so they get
            // the window background first: the line glyph covers only
            // part of its cell.
            for (self.app.panes.bands.items) |d| {
                if (d.level != .pane) continue;
                const r = geometry.cellRectPx(d.rect);
                eng.renderer.drawFilledRect(
                    host_eng.RectF{ .l = r.x, .t = r.y, .r = r.x + r.w, .b = r.y + r.h },
                    bg,
                );
            }
            for (self.divider_cells.items) |c| {
                const lit = if (focus) |f| pane_focus.touches(c.row, c.col, f.rect) else false;
                _ = drawCellText(eng, c.glyph, c.col, c.row, 1, if (lit) focus.?.color else color);
            }
        },
    }
    // The drag ghost, over the top: the real dividers above are still
    // at their pre-drag positions until the drag ends.
    if (self.app.panes.preview) |p| {
        eng.renderer.drawFilledRect(
            host_eng.RectF{ .l = p.x, .t = p.y, .r = p.x + p.w, .b = p.y + p.h },
            divider_preview_color,
        );
    }
}

/// The focused pane's highlight: its rect and this frame's colour.
const FocusHighlight = struct {
    rect: glyphwire.CellRect,
    color: host_eng.Color,
};

/// The focused pane's rect and its highlight colour this frame, or
/// null for none: `pane_focus_highlight = "none"`, or a focused pane
/// that isn't on screen. Caller holds `ctx_mutex`.
pub fn focusHighlight(self: *Renderer) ?FocusHighlight {
    const session = &self.app.server.session;
    const c = self.app.pane_focus.color(&session.theme.theme) orelse return null;
    const focused = session.focused_pane.load(.monotonic);
    // The raised overlay covers the window; outlining all of it would
    // only frame the screen.
    if (session.isOverlayPane(focused)) return null;
    const pane = session.panePtr(focused) orelse return null;
    if (!pane.mapped) return null;
    return .{ .rect = pane.rect, .color = host_eng.Color.from(c.r, c.g, c.b, c.a) };
}

/// Rebuilds `divider_cells` when the pane bands moved since the last
/// build. A failed build (out of memory) leaves the old cells and
/// tries again next frame.
pub fn syncDividerCells(self: *Renderer, glyphs: *const dividers.Glyphs) void {
    const gen = self.app.panes.pane_gen;
    if (self.divider_cells_gen == gen) return;
    const alloc = self.app.alloc;
    self.divider_lines.clearRetainingCapacity();
    for (self.app.panes.bands.items) |d| {
        if (d.level != .pane) continue;
        self.divider_lines.append(alloc, .{ .rect = d.rect, .vertical = d.axis == .row }) catch return;
    }
    dividers.layout(alloc, self.divider_lines.items, glyphs, &self.divider_cells) catch return;
    self.divider_cells_gen = gen;
}

/// Draws `text` along window row `row` from window column `col`, one
/// codepoint per cell boundary (the grid's own East Asian Width rules,
/// as `drawPreedit` does), stopping before it would pass `max_cols`.
/// Returns the columns used. For host-drawn chrome text; call between
/// `begin`/`end`.
pub fn drawCellText(eng: *Engine, text: []const u8, col: usize, row: usize, max_cols: usize, color: host_eng.Color) usize {
    const y = @as(i32, @intCast(row)) * geometry.cell_h;
    var used: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return 0).iterator();
    while (it.nextCodepointSlice()) |cp_bytes| {
        const cp = std.unicode.utf8Decode(cp_bytes) catch continue;
        const w: usize = @max(1, glyphwire.codepointWidth(cp));
        if (used + w > max_cols) break;
        _ = eng.renderer.drawStringColored(cp_bytes, .{
            .x = geometry.content_pad_px + @as(i32, @intCast(col + used)) * geometry.cell_w,
            .y = y,
        }, color);
        used += w;
    }
    return used;
}

/// One visible layer's own scrollbars, drawn inside its viewport
/// bounds -- distinct from `renderScrollbar`, which is the window's
/// bar for the root layer's scrollback. Opt-in per axis
/// (`core.PropertyName.scrollbars`) and skipped entirely on an axis
/// with nothing to scroll, so this is a no-op for every session that
/// isn't running a TUI. Called from `drawOneContext` straight after
/// the layer's batches (under `ctx_mutex`), so it composites in layer
/// order: as a final pass over everything, gw-read's page bars would
/// show through the OCR dialog floating over them.
pub fn drawLayerScrollbars(eng: *Engine, layer: *const glyphwire.Layer, origin: geometry.Origin) void {
    const state = layer.scrollbarState();
    if (!state.vertical and !state.horizontal) return;

    const rect = geometry.layerRectIn(origin, layer.pos, layer.viewportCols(), layer.viewportRows());
    const bars = geometry.paneScrollbars(
        rect,
        state,
        layer.viewportCols(),
        layer.viewportRows(),
    );
    if (bars.vertical == null and bars.horizontal == null) return;
    eng.renderer.begin(eng.projMat);
    defer eng.renderer.end();
    if (bars.vertical) |v| drawBar(eng, v);
    if (bars.horizontal) |h| drawBar(eng, h);
}

pub fn drawBar(eng: *Engine, bar: geometry.PaneScrollbarGeom) void {
    eng.renderer.drawFilledRect(
        host_eng.RectF{
            .l = bar.track.x,
            .t = bar.track.y,
            .r = bar.track.x + bar.track.w,
            .b = bar.track.y + bar.track.h,
        },
        pane_track_color,
    );
    eng.renderer.drawFilledRect(
        host_eng.RectF{
            .l = bar.thumb.x + 1,
            .t = bar.thumb.y + 1,
            .r = bar.thumb.x + bar.thumb.w - 1,
            .b = bar.thumb.y + bar.thumb.h - 1,
        },
        pane_thumb_color,
    );
}

/// The always-on scrollbar over the right edge: a dark track with a
/// lighter thumb reflecting the root layer's scrollback and view
/// offset (`geometry.scrollbarGeom`). Its own render pass (see
/// `render`) so it composites over every layer; `Scroll.handleScrollbar`
/// owns the interaction.
pub fn renderScrollbar(self: *Renderer, eng: *Engine) void {
    const fb = eng.window_state.framebuffer_size;
    const server = self.app.server;
    var history_len: usize = undefined;
    var height: usize = undefined;
    var view_scroll: usize = undefined;
    var owned: bool = undefined;
    var enabled: bool = undefined;
    {
        const session_lock = server.lockSession();
        defer session_lock.unlock();
        history_len = server.ctx.root.history_len;
        height = server.ctx.root.height;
        view_scroll = server.ctx.root.view_scroll;
        owned = scroll.rootOwned(&server.ctx.root);
        enabled = server.ctx.window_scrollbar;
    }
    // A pure-TUI context opts the bar out entirely -- see
    // `core.Context.window_scrollbar`. Under a pane tree its gutter
    // stays reserved and just isn't painted (see
    // `geometry.rightGutterPx`).
    if (!enabled) return;
    if (owned) {
        eng.renderer.drawFilledRect(
            host_eng.RectF.fromPosSize(fb.x - geometry.scrollbar_width_px, 0, geometry.scrollbar_width_px, fb.y),
            host_eng.Color.from(28, 28, 32, 255),
        );
        return;
    }
    const geom = geometry.scrollbarGeom(fb.x, fb.y, history_len, height, view_scroll);

    eng.renderer.drawFilledRect(
        host_eng.RectF.fromPosSize(@as(i32, @intFromFloat(geom.left)), 0, geometry.scrollbar_width_px, fb.y),
        host_eng.Color.from(28, 28, 32, 255),
    );
    eng.renderer.drawFilledRect(
        host_eng.RectF{
            .l = geom.left + 2,
            .t = geom.thumb_top,
            .r = geom.left + @as(f32, @floatFromInt(geometry.scrollbar_width_px)) - 2,
            .b = geom.thumb_top + geom.thumb_h,
        },
        host_eng.Color.from(120, 120, 130, 255),
    );
}
