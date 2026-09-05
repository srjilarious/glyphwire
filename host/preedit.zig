const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const scroll = @import("scroll.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

/// The IME composition ("preedit") overlay: the text the user is part-way
/// through composing, which the input method has not committed yet.
///
/// Two halves, both of which the engine backend has to support for any of
/// this to do anything:
///
///   * `syncInputArea` tells the OS where the caret is, so the IME can put
///     its candidate window next to it instead of at the window's origin.
///   * `text` hands `render.zig` the in-progress composition to draw at
///     the caret. Without it, typing Japanese shows *nothing* until the
///     commit lands, because uncommitted text never reaches the `text`
///     event stream that `input.reportTextInput` forwards.
///
/// glyphwire-host (GLFW) supports neither, so both compile away to nothing
/// there -- see `supported`. Nothing is forwarded to glyphwire-shell from
/// here: a composition is host-local until the IME commits it, at which
/// point it arrives as ordinary text on the existing stream.
pub const Preedit = struct {
    app: *App,

    /// Last text-input area handed to the OS, in framebuffer pixels, so a
    /// caret that hasn't moved doesn't re-issue the call every frame.
    last_area: ?Area = null,

    const Area = struct { x: i32, y: i32, w: i32, h: i32 };

    /// Whether the linked engine backend can do any of this. The SDL3
    /// backend (`host_eng`) exposes `Keyboard.preedit` and
    /// `Window.setTextInputArea`; upstream pixzig's GLFW backend exposes
    /// neither, and GLFW has no IME plumbing to build it on.
    pub const supported = @hasDecl(app_mod.Window, "setTextInputArea");

    /// The composition in progress, or an empty slice when there is none.
    /// Borrowed from the engine's keyboard state; valid until the next
    /// event poll.
    pub fn text(self: *const Preedit, eng: *Engine) []const u8 {
        _ = self;
        if (comptime !supported) return "";
        return eng.inputs.keyboard.preedit();
    }

    /// Byte offset of the IME's caret within `text()`, or null when the
    /// IME didn't report one. `drawPreedit` marks it with a bar so the
    /// user can see where in the composition they are.
    pub fn cursorByte(self: *const Preedit, eng: *Engine) ?usize {
        _ = self;
        if (comptime !supported) return null;
        return eng.inputs.keyboard.preeditCursorByte();
    }

    /// Points the OS text-input area at the caret cell so the IME's
    /// candidate window follows it. SDL wants window coordinates, not
    /// framebuffer pixels, so the rect is divided back down by the
    /// HiDPI scale factor on the way out.
    ///
    /// Called every frame from `App.update`; the `last_area` compare keeps
    /// it to one SDL call per actual caret move.
    pub fn syncInputArea(self: *Preedit, eng: *Engine) void {
        if (comptime !supported) return;
        if (geometry.cell_w <= 0 or geometry.cell_h <= 0) return;

        const cell = blk: {
            const server = self.app.server;
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            const root = &server.ctx.root;
            const view: usize = if (scroll.rootOwned(root)) 0 else root.view_scroll;
            break :blk self.app.caret.screenCell(root, view);
        } orelse return;

        const area: Area = .{
            .x = geometry.content_pad_px + @as(i32, @intCast(cell.col)) * geometry.cell_w,
            .y = @as(i32, @intCast(cell.row)) * geometry.cell_h,
            .w = geometry.cell_w,
            .h = geometry.cell_h,
        };
        if (self.last_area) |prev| {
            if (std.meta.eql(prev, area)) return;
        }
        self.last_area = area;

        const sf = eng.window_state.scale_factor;
        const win_x: i32 = @intFromFloat(@as(f32, @floatFromInt(area.x)) / @max(sf.x, 0.001));
        const win_y: i32 = @intFromFloat(@as(f32, @floatFromInt(area.y)) / @max(sf.y, 0.001));
        const win_w: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(area.w)) / @max(sf.x, 0.001))));
        const win_h: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(area.h)) / @max(sf.y, 0.001))));
        // Trailing 0: the IME's own caret sits at the start of the area,
        // which is the caret cell itself.
        eng.window.setTextInputArea(win_x, win_y, win_w, win_h, 0);
    }

    /// Cell width of `composition` using glyphwire's East Asian Width
    /// rules -- the same widths the grid itself uses, so the overlay lines
    /// up with the columns underneath it.
    pub fn cellWidth(composition: []const u8) usize {
        return glyphwire.stringWidth(composition);
    }
};
