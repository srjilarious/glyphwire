// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const key_repeat = @import("key_repeat.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

/// Forwards keyboard / text / mouse events from the engine's per-frame input
/// state to the in-process `Server`, and synthesizes the typematic key
/// repeats the OS repeat doesn't reach the host as fresh events. Owns the
/// last-forwarded modifier / mouse state; the hold timers themselves
/// belong to the engine's `Keyboard` (see `handleRepeatKeys`).
pub const KeyInput = struct {
    app: *App,

    last_mouse_px: host_eng.Vec2F = .{ .x = -1, .y = -1 },

    /// Session-wide repeat timing from `host.conf`, used for every
    /// context that hasn't asked for its own with `set_key_repeat`. See
    /// `syncRepeatTiming`.
    repeat_default: key_repeat.Timing = .{},

    /// Last `core.Context.key_repeat_gen` and focused context acted on,
    /// so each arriving `set_key_repeat` -- and each focus change --
    /// cancels the in-flight repeat exactly once. See `syncRepeatTiming`.
    repeat_gen_seen: u64 = 0,
    repeat_ctx_seen: glyphwire.ContextHandle = glyphwire.root_context_handle,

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

        // Ctrl+Shift+P toggles the profiler HUD and Ctrl+Shift+R toggles
        // forced every-frame redraw, but only when `host.conf.lua` enabled
        // profiling at all. Handled once here (not per-key in the loop)
        // and swallowed below so the shell / grid never see them.
        const profile_toggle = self.profileToggleArmed(kb);
        if (profile_toggle and kb.pressed(.p)) _ = self.app.profiler.toggleHud();
        if (profile_toggle and kb.pressed(.r)) _ = self.app.profiler.toggleForceRedraw();

        var any_pressed = false;
        const field_names = @typeInfo(app_mod.Key).@"enum".field_names;
        inline for (field_names) |field_name| {
            const key = @field(app_mod.Key, field_name);
            if (self.swallowsKey(key, kb, profile_toggle)) {
                // Consumed elsewhere; don't forward it.
            } else if (kb.pressed(key)) {
                any_pressed = true;
                self.app.server.reportKey(self.app.alloc, field_name, true) catch |err| {
                    std.log.err("reportKey({s}, true) failed: {t}", .{ field_name, err });
                };
            } else if (kb.released(key)) {
                self.app.server.reportKey(self.app.alloc, field_name, false) catch |err| {
                    std.log.err("reportKey({s}, false) failed: {t}", .{ field_name, err });
                };
            }
        }
        return any_pressed;
    }

    /// Whether Ctrl+Shift is held with profiling enabled, i.e. whether
    /// the Ctrl+Shift+P / Ctrl+Shift+R host shortcuts are live this
    /// frame. Both `reportKeyEvents` and `handleRepeatKeys` need it, so
    /// the condition lives in one place.
    fn profileToggleArmed(self: *KeyInput, kb: *const host_eng.input.Keyboard) bool {
        return self.app.profiler.active() and kb.ctrl() and kb.shift();
    }

    /// Whether `key` is consumed by the host itself this frame and so
    /// must not reach the wire at all -- neither as a press/release
    /// (`reportKeyEvents`) nor as a typematic repeat
    /// (`handleRepeatKeys`), which is why both route through here.
    fn swallowsKey(self: *KeyInput, key: app_mod.Key, kb: *const host_eng.input.Keyboard, profile_toggle: bool) bool {
        const skip_static = switch (key) {
            // Forwarded by reportModifier, not per physical key.
            .left_control, .right_control, .left_alt, .right_alt, .left_shift, .right_shift, .left_super, .right_super => true,
            // Ctrl + these are `window_sizing`'s font-zoom shortcuts;
            // swallow them here so the shell/grid never sees the
            // keystroke.
            .minus, .equal, .zero, .kp_subtract, .kp_add, .kp_0 => kb.ctrl(),
            // Ctrl+Shift+P / Ctrl+Shift+R are profiler toggles.
            .p, .r => profile_toggle,
            else => false,
        };
        // Selection / clipboard shortcuts (Ctrl+Shift+C/V/Space) and, in
        // keyboard selection mode, the motion keys are consumed by
        // `selection.Selection.handleKeys` -- keep them off the wire too.
        return skip_static or self.app.selection.swallows(key, kb);
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
    /// A held printable key repeats through here too, on the same clock
    /// as every other key (`Keyboard.textRepeated`): the engine swallows
    /// the OS's own text auto-repeat and re-emits the same committed text
    /// at the focused program's cadence, so a held `j` and a held Down
    /// arrow move at one rate rather than two. Fresh text and a repeat
    /// can't collide in the same tick -- a press restarts the hold
    /// schedule, so nothing is due on the tick the press lands.
    ///
    /// The 256-byte buffer bounds one frame's worth of committed text;
    /// `Keyboard`'s own per-frame text buffer is capped well below that.
    pub fn reportTextInput(self: *KeyInput, eng: *Engine) bool {
        var buf: [256]u8 = undefined;
        const n = eng.inputs.keyboard.text(&buf);
        if (n > 0) {
            self.app.server.reportText(self.app.alloc, buf[0..n]) catch |err| {
                std.log.err("reportText failed: {t}", .{err});
            };
            return true;
        }

        const repeated = eng.inputs.keyboard.textRepeated();
        if (repeated.len == 0) return false;
        self.app.server.reportText(self.app.alloc, repeated) catch |err| {
            std.log.err("reportText (repeat) failed: {t}", .{err});
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
        const server = self.app.server;
        const pos = eng.inputs.mouse.pos();
        const window_cell = geometry.cellFromPixel(pos.x, pos.y);

        // Click-to-focus, before the event itself is delivered: a press in
        // an unfocused pane moves focus there first, so the click lands in
        // the pane the user just picked rather than the one they left. The
        // host owns this rather than the window manager, because the
        // manager doesn't see mouse events for panes it isn't focused on
        // -- and requiring it to would mean giving it every raw event.
        if (eng.inputs.mouse.pressed(.left) or eng.inputs.mouse.pressed(.right) or eng.inputs.mouse.pressed(.middle)) {
            _ = server.focusPaneAt(self.app.alloc, window_cell) catch |err| {
                std.log.err("focusPaneAt failed: {t}", .{err});
            };
        }

        // Everything below is reported in the focused context's own frame.
        // A pointer outside the focused pane (over a neighbour, or in a
        // divider band) reports nothing: those events are not that
        // client's business, and a window-cell coordinate would be outside
        // its grid entirely.
        const cell = server.focusedCell(window_cell) orelse return;

        if (pos.x != self.last_mouse_px.x or pos.y != self.last_mouse_px.y) {
            self.last_mouse_px = pos;
            self.app.server.reportMouseMove(self.app.alloc, .{ .x = pos.x, .y = pos.y }, cell) catch |err| {
                std.log.err("reportMouseMove failed: {t}", .{err});
            };
        }

        const view_offset = blk: {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            break :blk server.ctx.root.view_scroll;
        };

        const field_names = @typeInfo(app_mod.MouseButton).@"enum".field_names;
        inline for (field_names) |field_name| {
            const btn = @field(app_mod.MouseButton, field_name);
            const is_left = btn == .left;
            if (!(skip_left and is_left)) {
                if (eng.inputs.mouse.pressed(btn)) {
                    server.reportMouseButton(self.app.alloc, field_name, true, .{ .x = pos.x, .y = pos.y }, cell, view_offset) catch |err| {
                        std.log.err("reportMouseButton({s}, true) failed: {t}", .{ field_name, err });
                    };
                } else if (eng.inputs.mouse.released(btn)) {
                    server.reportMouseButton(self.app.alloc, field_name, false, .{ .x = pos.x, .y = pos.y }, cell, view_offset) catch |err| {
                        std.log.err("reportMouseButton({s}, false) failed: {t}", .{ field_name, err });
                    };
                }
            }
        }
    }

    /// Puts this tick's typematic key repeats on the wire.
    ///
    /// The hold timers are the engine's (`Keyboard.tickRepeats`, which
    /// runs for every key), so what's left here is glyphwire's policy:
    /// `key_repeat.repeatsKey` decides which repeats are meaningful --
    /// the named keys always, a text key only as a Ctrl/Alt chord, since
    /// a held `j` already repeats down the `text` stream -- and
    /// `swallowsKey` keeps back the ones the host itself consumed.
    ///
    /// A repeat goes out as `reportKeyRepeat` rather than `reportKey`,
    /// because `reportKey`/`setKey` would see no state change on a key
    /// that is already down and drop it.
    pub fn handleRepeatKeys(self: *KeyInput, eng: *Engine) void {
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
        const kb = &eng.inputs.keyboard;
        const preview_caret = !self.app.scroll.screenOwnedByProgram();
        if (preview_caret) {
            if (kb.pressed(.left) or kb.repeated(.left)) self.moveCursor(-1, 0);
            if (kb.pressed(.right) or kb.repeated(.right)) self.moveCursor(1, 0);
        }

        const profile_toggle = self.profileToggleArmed(kb);
        const ctrl = kb.ctrl();
        const alt = kb.alt();
        const field_names = @typeInfo(app_mod.Key).@"enum".field_names;
        inline for (field_names) |field_name| {
            const key = @field(app_mod.Key, field_name);
            if (kb.repeated(key) and
                key_repeat.repeatsKey(key, ctrl, alt) and
                !self.swallowsKey(key, kb, profile_toggle))
            {
                self.app.server.reportKeyRepeat(self.app.alloc, field_name) catch |err| {
                    std.log.err("reportKeyRepeat({s}) failed: {t}", .{ field_name, err });
                };
            }
        }
    }

    /// Hands the engine the repeat timing the focused program asked for
    /// with `set_key_repeat`, or the `host.conf` default when it asked
    /// for nothing (see `key_repeat.resolve`). Run once per tick, before
    /// the repeats themselves: a pane switch between the shell and zoe
    /// changes the cadence with it, and the change takes effect from the
    /// next press -- a key already held keeps the schedule it started on.
    pub fn syncRepeatTiming(self: *KeyInput, eng: *Engine) void {
        const server = self.app.server;
        const override, const gen, const ctx_handle = blk: {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            const handle = server.session.focusedContextHandle();
            const ctx = server.session.focusedContext();
            break :blk .{ ctx.key_repeat, ctx.key_repeat_gen, handle };
        };
        // Two boundaries where whatever is held was pressed under rules
        // that no longer apply, and so must stop repeating until it is
        // pressed again.
        //
        // A retime: a program only sends one when the meaning of its
        // keys has changed. zoe pressing `i` is the case that needs it --
        // `i` types, so without the cancel the keystroke that switched
        // to insert mode goes on typing itself into the buffer it just
        // opened. The cadence may well be unchanged (zoe retimes on
        // every mode change), which is why this tracks the generation
        // rather than the numbers.
        //
        // A focus change: the key that moved focus is usually still
        // down, and its repeats belong to neither the pane it left nor
        // the one it just arrived in.
        if (gen != self.repeat_gen_seen or ctx_handle != self.repeat_ctx_seen) {
            self.repeat_gen_seen = gen;
            self.repeat_ctx_seen = ctx_handle;
            eng.inputs.keyboard.cancelRepeats();
        }
        eng.inputs.keyboard.repeat = key_repeat.resolve(self.repeat_default, override);
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

/// How long the event loop may sleep before a held key's next typematic
/// repeat comes due, or null when nothing repeatable is held.
///
/// The host blocks in `waitEvents` when idle and the hold timers only
/// advance while the loop runs -- so without this deadline a held key
/// sleeps through its whole schedule until something else (the caret
/// blink, the OS's own first key-repeat event) happens to wake the loop,
/// which then catches up several repeats' worth of simulated time in one
/// frame. That reads as a burst of motion, a pause, then an uneven
/// cadence. Waking on the schedule keeps the repeats evenly spaced.
///
/// Floored at one update step: the loop advances the hold timers in
/// fixed steps, so waking sooner would only spin through iterations that
/// can't move the clock far enough to fire anything.
pub fn repeatTimeoutMs(eng: *Engine) ?f64 {
    const kb = &eng.inputs.keyboard;
    const ctrl = kb.ctrl();
    const alt = kb.alt();
    var soonest: ?f64 = null;
    const field_names = @typeInfo(app_mod.Key).@"enum".field_names;
    inline for (field_names) |field_name| {
        const key = @field(app_mod.Key, field_name);
        if (key_repeat.repeatsKey(key, ctrl, alt)) {
            if (kb.repeatDueMs(key)) |due| {
                soonest = if (soonest) |s| @min(s, due) else due;
            }
        }
    }
    // A held printable key repeats its text rather than its key name, so
    // it isn't in the loop above -- but the loop still has to wake for
    // it, or a held `j` sleeps through the same schedule a held arrow
    // now doesn't (see `Keyboard.textRepeated`).
    if (kb.text_repeat_key) |key| {
        if (kb.repeatDueMs(key)) |due| {
            soonest = if (soonest) |s| @min(s, due) else due;
        }
    }
    const due = soonest orelse return null;
    return @max(due, app_mod.update_step_ms);
}
