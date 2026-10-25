// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const hit = @import("hit.zig");
const scroll_mod = @import("scroll.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;
const DragSource = host_eng.drag_out.DragSource;

/// How far, in framebuffer pixels, the pointer has to travel with the
/// button down before a press becomes a drag. Below it the press is
/// still a click.
const drag_slop_px: f32 = 6;

/// Where the card drawn under the pointer sits relative to it, in surface
/// units: below and right, clear of the cursor.
const icon_offset = 12;

/// Alt+drag out of the window: a file in an `ls` listing or a
/// salacommander pane dropped onto Kate, Audacious, a file manager.
///
/// Two ways in, one drag:
///
/// - **A tagged span.** An Alt+left press on a cell whose metadata carries
///   a drag payload (`create_metadata`'s `drag`) is the host's own: the
///   press and its release never reach a client. This is what makes an
///   `ls` listing draggable long after `ls` has exited -- the payload
///   lives in the context with the cells, the same way `table_sort.zig`
///   and `outline_toggle.zig` keep tables and outlines working. Pressing
///   on a highlighted (gw-shell-marked) entry drags every highlighted one.
/// - **`start_drag`.** A live client that knows more than one cell can
///   say -- salacommander dragging its whole marked set -- gets the press
///   as usual and asks for the drag itself. The press stays the client's;
///   the host only borrows the held button.
///
/// Either way the press is armed first and the OS drag begins once the
/// pointer moves past `drag_slop_px` with the button still down, so an
/// Alt+click is not mistaken for a drag. The OS side is
/// `host_eng.drag_out.DragSource`, Wayland only; without it (X11, or a
/// compositor without drag actions) nothing here does anything and
/// Alt+clicks reach clients as before.
pub const DragOut = struct {
    app: *App,
    source: ?*DragSource = null,

    /// A press waiting to become a drag, and the payload it will carry
    /// (owned, freed with the app's allocator).
    armed: ?Armed = null,
    /// Where the newest left press landed, which is where a `start_drag`
    /// request's travel is measured from: the request arrives a round
    /// trip after the press it is about.
    press_px: host_eng.Vec2F = .{ .x = 0, .y = 0 },
    /// Set when this took a press, so its release is taken too.
    swallow_release: bool = false,
    /// Whether a drag was in flight last frame, to catch it ending.
    was_dragging: bool = false,

    const Armed = struct {
        payload: glyphwire.DragPayload,
        from_px: host_eng.Vec2F,
    };

    pub fn init(self: *DragOut, eng: *Engine) void {
        self.source = DragSource.create(self.app.alloc, eng.window);
    }

    pub fn deinit(self: *DragOut) void {
        self.disarm();
        if (self.source) |s| s.destroy();
        self.source = null;
    }

    /// Runs the Wayland listeners and cleans up after a drag that just
    /// ended. Once a frame, before any mouse handling.
    pub fn pump(self: *DragOut, eng: *Engine) void {
        // A client's request is taken every frame, whether or not it can
        // be honoured, so a stale one never fires on some later press.
        var request = self.takeRequest();
        const source = self.source orelse {
            if (request) |*r| r.deinit(self.app.alloc);
            return;
        };
        source.dispatch();
        if (request) |*r| {
            // Only while the press it answers is still held; one arriving
            // after the release was a click.
            if (eng.inputs.mouse_enabled and eng.inputs.mouse.down(.left) and self.armed == null) {
                self.armed = .{ .payload = r.*, .from_px = self.press_px };
            } else {
                r.deinit(self.app.alloc);
            }
        }

        const dragging = source.dragging();
        if (self.was_dragging and !dragging) {
            // The compositor's pointer leave at drag start is what releases
            // the button SDL-side. Should one not arrive, the button is
            // still down here, and every later press would be deduped
            // into nothing -- so let it up now that the drag is over.
            if (eng.inputs.mouse.down(.left)) eng.inputs.mouse.set(.left, false);
        }
        self.was_dragging = dragging;
    }

    /// While a drop target holds the drag, its request for the data
    /// wakes nothing SDL reports, so the loop has to come round on its
    /// own to answer it.
    pub fn idleTimeoutMs(self: *const DragOut) ?f64 {
        const source = self.source orelse return null;
        return if (source.dragging()) 16 else null;
    }

    /// Returns true when this frame's left button belongs to a drag: a
    /// press on a draggable span, or the release that ends one.
    pub fn handleMouse(self: *DragOut, eng: *Engine) bool {
        const m = &eng.inputs.mouse;
        const pos = m.pos();
        if (m.pressed(.left)) self.press_px = pos;
        if (self.source == null or !eng.inputs.mouse_enabled) return false;

        if (m.released(.left)) {
            // Released before it travelled: it was a click after all.
            self.disarm();
            if (self.swallow_release) {
                self.swallow_release = false;
                return true;
            }
            return false;
        }

        if (m.pressed(.left) and eng.inputs.keyboard.alt() and self.armed == null) {
            if (self.payloadUnder(pos)) |payload| {
                self.armed = .{ .payload = payload, .from_px = pos };
                self.swallow_release = true;
                return true;
            }
        }

        if (self.armed) |a| {
            if (m.down(.left) and travelled(a.from_px, pos)) self.begin(eng);
        }
        return self.swallow_release;
    }

    fn travelled(from: host_eng.Vec2F, to: host_eng.Vec2F) bool {
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        return dx * dx + dy * dy >= drag_slop_px * drag_slop_px;
    }

    fn disarm(self: *DragOut) void {
        if (self.armed) |*a| a.payload.deinit(self.app.alloc);
        self.armed = null;
    }

    fn takeRequest(self: *DragOut) ?glyphwire.DragPayload {
        const server = self.app.server;
        const session_lock = server.lockSession();
        defer session_lock.unlock();
        return server.ctx.takeDragRequest();
    }

    /// The drag payload on the cell under `pos`, copied (with every other
    /// highlighted entry's when this one is highlighted), or null when it
    /// carries none. Moves focus to the pane under the pointer first, the
    /// way any click would, so the lookup is in that pane's context.
    fn payloadUnder(self: *DragOut, pos: host_eng.Vec2F) ?glyphwire.DragPayload {
        const server = self.app.server;
        _ = server.focusPaneAt(self.app.alloc, geometry.cellFromPixel(pos.x, pos.y)) catch |err| {
            std.log.err("focusPaneAt failed: {t}", .{err});
        };

        const session_lock = server.lockSession();
        defer session_lock.unlock();
        const ctx = server.ctx;
        const target = hit.layerUnder(ctx, pos.x, pos.y) orelse return null;
        const layer = target.layer;
        // A full-screen program's own content is on the grid, not tagged
        // listing output.
        if (target.is_root and scroll_mod.rootOwned(layer)) return null;
        if (target.row >= layer.height or target.col >= layer.width) return null;

        const cell = layer.viewRow(layer.view_scroll, target.row)[target.col];
        const id = cell.metadata_id orelse return null;
        // A marked entry drags the whole marked set along with it.
        return ctx.dragForPress(self.app.alloc, layer, id) catch |err| {
            std.log.err("drag payload copy failed: {t}", .{err});
            return null;
        };
    }

    /// Hands the armed payload to the OS drag, with its card.
    fn begin(self: *DragOut, eng: *Engine) void {
        var armed = self.armed orelse return;
        self.armed = null;
        defer armed.payload.deinit(self.app.alloc);
        const source = self.source orelse return;

        var image = self.renderCard(eng, &armed.payload);
        defer if (image) |*img| img.deinit(self.app.alloc);

        source.start(.{
            .uris = armed.payload.uris,
            .icon = if (image) |img| .{ .width = img.width, .height = img.height, .scale = img.scale, .pixels = img.pixels } else null,
            .icon_offset_x = icon_offset,
            .icon_offset_y = icon_offset,
        }) catch |err| {
            std.log.warn("drag out failed to start: {t}", .{err});
        };
    }

    /// The card under the pointer: the payload's icon and label in the
    /// session font, coloured like a list cursor. Null (a bare drag)
    /// when it can't be drawn.
    fn renderCard(self: *DragOut, eng: *Engine, payload: *const glyphwire.DragPayload) ?host_eng.drag_out.image.Image {
        const alloc = self.app.alloc;
        const server = self.app.server;

        // Copied out under the lock; drawing happens after it's released.
        var icon_png: ?[]u8 = null;
        defer if (icon_png) |b| alloc.free(b);
        const style = blk: {
            const session_lock = server.lockSession();
            defer session_lock.unlock();
            const ctx = server.ctx;
            if (payload.icon) |name| {
                if (ctx.iconHandle(name)) |h| {
                    if (ctx.imageEntry(h)) |entry| {
                        if (entry.format == .png) icon_png = alloc.dupe(u8, entry.bytes) catch null;
                    }
                }
            }
            const th = &ctx.theme.theme;
            break :blk host_eng.drag_out.image.Style{
                .bg = color8(th.roleColor(.list_cursor_bg)),
                .fg = color8(th.roleColor(.list_cursor_fg)),
                .border = color8(th.roleColor(.pane_divider)),
            };
        };

        // Integer buffer scale nearest the window's, with the font sized
        // so the label comes out as tall on screen as the grid's text.
        const fb_scale = @max(eng.window_state.scale_factor.x, 0.5);
        const buf_scale: u32 = @intFromFloat(@max(1, @round(fb_scale)));
        const font_px = self.app.window_sizing.font_size * @as(f32, @floatFromInt(buf_scale)) / fb_scale;

        const label = payload.label orelse payload.uris[0];
        return host_eng.drag_out.image.render(alloc, .{
            .icon_png = icon_png,
            .label = label,
            .font_path = self.app.window_sizing.font_path,
            .face_index = self.app.window_sizing.font_face_index,
            .font_px = font_px,
            .scale = buf_scale,
            .style = style,
        }) catch |err| {
            std.log.warn("drag card failed, dragging without one: {t}", .{err});
            return null;
        };
    }

    fn color8(c: glyphwire.Color) host_eng.Color8 {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }
};
