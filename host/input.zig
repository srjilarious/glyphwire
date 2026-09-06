const std = @import("std");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const key_repeat = @import("key_repeat.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;
const KeyRepeatState = key_repeat.KeyRepeatState;

/// Forwards keyboard / text / mouse events from the engine's per-frame input
/// state to the in-process `Server`, and synthesizes the typematic key
/// repeats the OS repeat doesn't reach the host as fresh events. Owns the
/// per-key hold timers and the last-forwarded modifier / mouse state.
pub const KeyInput = struct {
    app: *App,

    last_mouse_px: host_eng.Vec2F = .{ .x = -1, .y = -1 },

    /// Per-key hold timers for the keys glyphwire-host synthesizes
    /// typematic repeats for -- the four arrows (which also move the root
    /// cursor), plus Backspace, Delete and Ctrl+U, whose repeats are just
    /// re-broadcast for glyphwire-shell's line editor to act on. See
    /// `handleRepeatKeys`.
    key_repeat: struct {
        up: KeyRepeatState = .{},
        down: KeyRepeatState = .{},
        left: KeyRepeatState = .{},
        right: KeyRepeatState = .{},
        backspace: KeyRepeatState = .{},
        delete: KeyRepeatState = .{},
        ctrl_u: KeyRepeatState = .{},
    } = .{},

    /// Last-forwarded down/up state of each modifier, indexed
    /// `[ctrl, alt, shift, super]` -- see `reportModifier`. glyphwire-host
    /// forwards each modifier once, under its `left_*` name, from the
    /// engine's logical modifier state rather than per physical key, so an
    /// OS-level remap like CapsLock->Control (which `keyboard.ctrl()`
    /// reports but which never arrives as a physical modifier-key press)
    /// still reaches glyphwire-shell's Ctrl-combo handling.
    mod_forwarded: [4]bool = .{ false, false, false, false },

    /// Reports every key that changed down/up state this frame -- see
    /// `Keyboard.pressed`/`.released`'s edge-detection doc comments in
    /// `host_eng/input.zig` -- directly against the in-process `Server` (see
    /// `Server.reportKey`), not over a socket connection to itself.
    ///
    /// The eight physical modifier keys (`left_control`, `right_alt`, ...)
    /// are not forwarded by name from this loop. Each modifier is instead
    /// forwarded once, under its `left_*` name, from the engine's logical
    /// modifier state (`keyboard.ctrl()` / `.alt()` / `.shift()` /
    /// `.super()`) via `reportModifier`. That state already folds the left
    /// and right physical keys together, and also picks up OS-level
    /// modifier remaps -- e.g. CapsLock acting as Control -- which never
    /// arrive as a physical modifier-key press. Consequence: a held right
    /// modifier shows up in `get_input_state` as `left_control` etc., not
    /// `right_control`; nothing in glyphwire distinguishes the two.
    /// Returns whether a (non-skipped) key was pressed this frame -- the
    /// caller uses it to release a mouse-scroll caret pin.
    pub fn reportKeyEvents(self: *KeyInput, eng: *Engine) bool {
        const kb = &eng.inputs.keyboard;

        self.reportModifier(0, "left_control", kb.ctrl());
        self.reportModifier(1, "left_alt", kb.alt());
        self.reportModifier(2, "left_shift", kb.shift());
        self.reportModifier(3, "left_super", kb.super());

        var any_pressed = false;
        const ctrl_held = kb.ctrl();
        const fields = @typeInfo(app_mod.Key).@"enum".fields;
        inline for (fields) |field| {
            const key = @field(app_mod.Key, field.name);
            const skip_static = switch (key) {
                // Forwarded by reportModifier above, not per physical key.
                .left_control, .right_control, .left_alt, .right_alt, .left_shift, .right_shift, .left_super, .right_super => true,
                // Ctrl + these are `window_sizing`'s font-zoom shortcuts;
                // swallow them here so the shell/grid never sees the
                // keystroke.
                .minus, .equal, .zero, .kp_subtract, .kp_add, .kp_0 => ctrl_held,
                else => false,
            };
            // Selection / clipboard shortcuts (Ctrl+Shift+C/V/Space) and,
            // in keyboard selection mode, the motion keys are consumed by
            // `selection.Selection.handleKeys` -- keep them off the wire
            // too.
            const skip = skip_static or self.app.selection.swallows(key, kb);
            if (skip) {
                // Consumed elsewhere; don't forward it.
            } else if (kb.pressed(key)) {
                any_pressed = true;
                self.app.server.reportKey(self.app.alloc, field.name, true) catch |err| {
                    std.log.err("reportKey({s}, true) failed: {t}", .{ field.name, err });
                };
            } else if (kb.released(key)) {
                self.app.server.reportKey(self.app.alloc, field.name, false) catch |err| {
                    std.log.err("reportKey({s}, false) failed: {t}", .{ field.name, err });
                };
            }
        }
        return any_pressed;
    }

    /// Forwards one modifier's down/up state under `name`, edge-detected
    /// against `mod_forwarded[idx]` so the in-process `Server` only sees a
    /// notification when it actually changes. `active` comes from the
    /// engine's logical modifier query (see `reportKeyEvents`).
    pub fn reportModifier(self: *KeyInput, idx: usize, name: []const u8, active: bool) void {
        if (active == self.mod_forwarded[idx]) return;
        self.mod_forwarded[idx] = active;
        self.app.server.reportKey(self.app.alloc, name, active) catch |err| {
            std.log.err("reportKey({s}, {}) failed: {t}", .{ name, active, err });
        };
    }

    /// Forwards the text the user actually typed this frame as a `text`
    /// notification -- `keyboard.text()` hands back the UTF-8 SDL
    /// delivered on `SDL_EVENT_TEXT_INPUT`, so this is already resolved
    /// through the OS keyboard layout, dead keys and IME composition (a
    /// QWERTZ 'z', an AZERTY AltGr '@', a committed CJK grapheme). Keys
    /// the IME consumes during a composition never surface as key events
    /// at all, so nothing has to filter them out. This is a separate stream
    /// from `reportKeyEvents`: a key event still fires for the same
    /// keystroke, carrying the physical key name for chords/navigation,
    /// but the character comes from here. glyphwire-shell's prompt inserts
    /// from `text` events and ignores the key event for plain typing, so
    /// there's no double-insertion.
    ///
    /// The 256-byte buffer bounds one frame's worth of committed text;
    /// `Keyboard`'s own per-frame text buffer is capped well below that.
    pub fn reportTextInput(self: *KeyInput, eng: *Engine) bool {
        var buf: [256]u8 = undefined;
        const n = eng.inputs.keyboard.text(&buf);
        if (n == 0) return false;
        self.app.server.reportText(self.app.alloc, buf[0..n]) catch |err| {
            std.log.err("reportText failed: {t}", .{err});
        };
        return true;
    }

    /// `skip_left` drops the left button for this frame -- set when
    /// `scroll.handleScrollbar` already consumed it (a scrollbar press,
    /// drag, or release), so the same click isn't also delivered to
    /// glyphwire-shell as a grid click. Mouse *move* reporting is
    /// unaffected.
    ///
    /// The `view_offset` passed alongside each button is the root layer's
    /// current scrollback view offset, so a click made while scrolled back
    /// carries enough context for glyphwire-shell to resolve it against
    /// the row actually under the pointer (see `Client.getMetadata`).
    pub fn reportMouseEvents(self: *KeyInput, eng: *Engine, skip_left: bool) void {
        if (!eng.inputs.mouse_enabled) return;
        const pos = eng.inputs.mouse.pos();
        const cell = geometry.cellFromPixel(pos.x, pos.y);

        if (pos.x != self.last_mouse_px.x or pos.y != self.last_mouse_px.y) {
            self.last_mouse_px = pos;
            self.app.server.reportMouseMove(self.app.alloc, .{ .x = pos.x, .y = pos.y }, cell) catch |err| {
                std.log.err("reportMouseMove failed: {t}", .{err});
            };
        }

        const server = self.app.server;
        const view_offset = blk: {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            break :blk server.ctx.root.view_scroll;
        };

        const fields = @typeInfo(app_mod.MouseButton).@"enum".fields;
        inline for (fields) |field| {
            const btn = @field(app_mod.MouseButton, field.name);
            const is_left = btn == .left;
            if (!(skip_left and is_left)) {
                if (eng.inputs.mouse.pressed(btn)) {
                    server.reportMouseButton(self.app.alloc, field.name, true, .{ .x = pos.x, .y = pos.y }, cell, view_offset) catch |err| {
                        std.log.err("reportMouseButton({s}, true) failed: {t}", .{ field.name, err });
                    };
                } else if (eng.inputs.mouse.released(btn)) {
                    server.reportMouseButton(self.app.alloc, field.name, false, .{ .x = pos.x, .y = pos.y }, cell, view_offset) catch |err| {
                        std.log.err("reportMouseButton({s}, false) failed: {t}", .{ field.name, err });
                    };
                }
            }
        }
    }

    /// Drives typematic repeat for the keys the OS repeat doesn't reach us
    /// as fresh events: the four arrows (which also move the root grid
    /// cursor -- generic terminal-style cursor addressing, independent of
    /// glyphwire-shell's line editor), plus Backspace, Delete and Ctrl+U.
    /// The initial press already reached `ctx.input`'s down-set and got
    /// broadcast via `reportKeyEvents`; held-down repeats are re-broadcast
    /// here via `reportKeyRepeat`, since `reportKey`/`setKey` would see no
    /// state change on a key that's already down and drop it. (Character
    /// keys repeat fine already -- their repeats come in on the `text`
    /// stream as fresh `SDL_EVENT_TEXT_INPUT` events.)
    pub fn handleRepeatKeys(self: *KeyInput, eng: *Engine, delta_ms: f64) void {
        // In keyboard selection mode the arrows/edit keys are swallowed
        // (they move the selection, not the shell's line) -- don't
        // synthesize repeats the shell would act on.
        if (self.app.selection.mode) return;
        // While a full-screen program owns the screen, its own output
        // drives `ctx.root.cursor` -- the host must not also nudge it on
        // an arrow press, or a program that redraws relative to the
        // cursor (`less`'s `:` prompt at BOF: `\r \x1b[K :`) lands a row
        // off per keypress. The keys are still forwarded (below / via
        // `reportKeyEvents`); only the local caret preview is skipped.
        //
        // Vertical arrows never get a caret preview: Up/Down at
        // glyphwire-shell's prompt mean history recall / break-into-
        // scrollback, not "move the raw cursor one row," and the shell
        // repositions the caret authoritatively in its redraw -- a local
        // row nudge here just flashes the caret off the prompt line for a
        // frame (and stuck there entirely when the shell has nothing to
        // redraw, e.g. Up at the oldest history entry). Horizontal
        // arrows keep the preview: it hides the round-trip latency while
        // moving through the live input line.
        const preview_caret = !self.app.scroll.screenOwnedByProgram();
        self.handleArrowRepeat(eng, .up, "up", &self.key_repeat.up, 0, -1, delta_ms, false);
        self.handleArrowRepeat(eng, .down, "down", &self.key_repeat.down, 0, 1, delta_ms, false);
        self.handleArrowRepeat(eng, .left, "left", &self.key_repeat.left, -1, 0, delta_ms, preview_caret);
        self.handleArrowRepeat(eng, .right, "right", &self.key_repeat.right, 1, 0, delta_ms, preview_caret);

        // Editing keys glyphwire-shell's line editor acts on directly.
        // No root-cursor move -- just the re-broadcast the held key needs
        // to keep deleting. Ctrl+U is gated on Ctrl actually being held
        // (a bare held `u` types through the `text` stream instead).
        self.handleEditRepeat(eng, .backspace, "backspace", &self.key_repeat.backspace, false, delta_ms);
        self.handleEditRepeat(eng, .delete, "delete", &self.key_repeat.delete, false, delta_ms);
        self.handleEditRepeat(eng, .u, "u", &self.key_repeat.ctrl_u, true, delta_ms);
    }

    fn handleArrowRepeat(
        self: *KeyInput,
        eng: *Engine,
        key: app_mod.Key,
        name: []const u8,
        state: *KeyRepeatState,
        dcol: i32,
        drow: i32,
        delta_ms: f64,
        preview_caret: bool,
    ) void {
        if (eng.inputs.keyboard.pressed(key)) {
            state.reset();
            if (preview_caret) self.moveCursor(dcol, drow);
        } else if (eng.inputs.keyboard.down(key)) {
            if (state.tick(delta_ms)) {
                if (preview_caret) self.moveCursor(dcol, drow);
                self.app.server.reportKeyRepeat(self.app.alloc, name) catch |err| {
                    std.log.err("reportKeyRepeat({s}) failed: {t}", .{ name, err });
                };
            }
        } else {
            state.reset();
        }
    }

    /// Like `handleArrowRepeat` but for an editing key with no root-cursor
    /// side effect: only the held repeat is synthesized (the press edge
    /// already went out via `reportKeyEvents`). `require_ctrl` limits the
    /// repeat to when Ctrl is also held.
    fn handleEditRepeat(
        self: *KeyInput,
        eng: *Engine,
        key: app_mod.Key,
        name: []const u8,
        state: *KeyRepeatState,
        require_ctrl: bool,
        delta_ms: f64,
    ) void {
        const kb = &eng.inputs.keyboard;
        if (kb.pressed(key)) {
            state.reset();
        } else if (kb.down(key) and (!require_ctrl or kb.ctrl())) {
            if (state.tick(delta_ms)) {
                self.app.server.reportKeyRepeat(self.app.alloc, name) catch |err| {
                    std.log.err("reportKeyRepeat({s}) failed: {t}", .{ name, err });
                };
            }
        } else {
            state.reset();
        }
    }

    /// Moves `ctx.root`'s cursor by one cell, clamped to the grid.
    /// `ctx_mutex`-guarded like `render`'s read, since this runs on the
    /// same thread as everything else in `update`/`render` but still
    /// shares `ctx` with connected clients' dispatch threads (e.g.
    /// glyphwire-shell's own `set_property cursor` calls).
    pub fn moveCursor(self: *KeyInput, dcol: i32, drow: i32) void {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        const layer = &server.ctx.root;
        const col: i32 = @as(i32, @intCast(layer.cursor.col)) + dcol;
        const row: i32 = @as(i32, @intCast(layer.cursor.row)) + drow;
        layer.cursor.col = @intCast(std.math.clamp(col, 0, @as(i32, @intCast(layer.width - 1))));
        layer.cursor.row = @intCast(std.math.clamp(row, 0, @as(i32, @intCast(layer.height - 1))));
    }
};
