// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const config = @import("config.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;
const Key = app_mod.Key;

/// The context switcher: a small modal list of the programs the focused
/// pane is holding (its context stack), opened by a host-owned chord
/// (`host.conf.lua`'s `context_switcher_key`, Super+F12 by default).
/// Picking one brings it to the top of the stack, which is all
/// "foregrounding" a glyphwire program means -- a context that isn't on
/// top keeps running and keeps its screen, it just isn't drawn and gets
/// no input.
///
/// Host-side rather than a client, so it works whichever program is in
/// front, pops up over the current screen instead of replacing it, and
/// the keys that drive it never reach a program at all.
///
/// Keys while open: Up/Down (or k/j, Tab/Shift+Tab, or the chord again)
/// move, Enter switches, 1..9 switch straight to that row, Escape closes.
/// It opens with the *second* row selected, so the chord then Enter flips
/// between the two most recent programs.
pub const Switcher = struct {
    app: *App,
    /// Null disables the switcher entirely.
    chord: ?config.Chord = config.context_switcher_default,

    open: bool = false,
    /// The pane the list was taken from. The list follows that pane's
    /// stack while open (a program exiting drops out of it), but never
    /// jumps to another pane's.
    pane: glyphwire.PaneHandle = glyphwire.root_pane_handle,
    entries: [max_entries]Entry = undefined,
    len: usize = 0,
    selected: usize = 0,
    /// Bumped on every visible change, so the redraw fingerprint notices
    /// a selection move that touches no cell.
    gen: u64 = 0,
    /// Whether this frame's key presses and typed text belong to the
    /// switcher: set by `handleKeys` for every frame it was open *at any
    /// point*, so the chord that opens it and the Enter that closes it are
    /// both held back -- that Enter would otherwise land in the program
    /// just brought forward. Releases are never withheld (see
    /// `input.KeyInput.reportKeyEvents`).
    consumed: bool = false,

    pub const max_entries = 32;
    pub const max_title = glyphwire.Context.max_title_len;

    pub const Entry = struct {
        context: glyphwire.ContextHandle,
        title_buf: [max_title]u8 = undefined,
        title_len: usize = 0,

        pub fn title(self: *const Entry) []const u8 {
            return self.title_buf[0..self.title_len];
        }
    };

    /// Runs once per frame, before any key reaches the wire. Returns
    /// `consumed`.
    pub fn handleKeys(self: *Switcher, eng: *Engine) bool {
        self.consumed = self.step(eng);
        return self.consumed;
    }

    fn step(self: *Switcher, eng: *Engine) bool {
        const kb = &eng.inputs.keyboard;
        const chord_hit = if (self.chord) |c|
            kb.pressed(c.key) and c.matches(kb.ctrl(), kb.alt(), kb.shift(), kb.super())
        else
            false;

        if (!self.open) {
            if (!chord_hit) return false;
            self.openOn();
            return true;
        }

        self.refresh();
        if (!self.open) return true;

        if (chord_hit) {
            self.move(1);
        } else if (kb.pressed(.escape)) {
            self.close();
        } else if (kb.pressed(.enter) or kb.pressed(.kp_enter)) {
            self.commit(self.selected);
        } else if (kb.pressed(.up) or kb.pressed(.k) or (kb.pressed(.tab) and kb.shift())) {
            self.move(-1);
        } else if (kb.pressed(.down) or kb.pressed(.j) or kb.pressed(.tab)) {
            self.move(1);
        } else {
            const digits = [_]Key{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine };
            const kp_digits = [_]Key{ .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7, .kp_8, .kp_9 };
            for (digits, kp_digits, 0..) |d, kp, i| {
                if (kb.pressed(d) or kb.pressed(kp)) {
                    if (i < self.len) self.commit(i);
                    break;
                }
            }
        }
        return true;
    }

    fn openOn(self: *Switcher) void {
        const server = self.app.server;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            self.pane = server.session.focusedPaneHandle();
            self.snapshotLocked();
        }
        if (self.len == 0) return;
        self.open = true;
        self.selected = if (self.len > 1) 1 else 0;
        self.gen +%= 1;
    }

    /// Re-reads the pane's stack, keeping the selection on the same
    /// context when it is still there. Closes if the pane went away.
    fn refresh(self: *Switcher) void {
        const keep = if (self.selected < self.len) self.entries[self.selected].context else null;
        const before_len = self.len;
        const server = self.app.server;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            self.snapshotLocked();
        }
        if (self.len == 0) {
            self.close();
            return;
        }
        if (keep) |h| {
            for (self.entries[0..self.len], 0..) |e, i| {
                if (e.context == h) {
                    self.selected = i;
                    break;
                }
            } else self.selected = @min(self.selected, self.len - 1);
        }
        if (self.len != before_len) self.gen +%= 1;
    }

    /// Copies `pane`'s stack, top first, with each context's title (or a
    /// fallback name). Call under `ctx_mutex`.
    fn snapshotLocked(self: *Switcher) void {
        const session = &self.app.server.session;
        const stack = session.paneStack(self.pane) orelse {
            self.len = 0;
            return;
        };
        const n = @min(stack.len, max_entries);
        for (0..n) |i| {
            const handle = stack[stack.len - 1 - i];
            var e: Entry = .{ .context = handle };
            const title = if (session.contextPtr(handle)) |ctx| ctx.title.items else "";
            if (title.len > 0) {
                const len = @min(title.len, max_title);
                @memcpy(e.title_buf[0..len], title[0..len]);
                e.title_len = len;
            } else {
                // A program that never named itself: a pane's base is
                // whatever the pane was started with, which is a shell
                // unless a window manager says otherwise.
                const fallback = if (session.isBaseContext(handle))
                    std.fmt.bufPrint(&e.title_buf, "shell", .{}) catch ""
                else
                    std.fmt.bufPrint(&e.title_buf, "context {d}", .{handle}) catch "";
                e.title_len = fallback.len;
            }
            self.entries[i] = e;
        }
        self.len = n;
    }

    fn move(self: *Switcher, delta: isize) void {
        if (self.len == 0) return;
        const n: isize = @intCast(self.len);
        const cur: isize = @intCast(self.selected);
        self.selected = @intCast(@mod(cur + delta, n));
        self.gen +%= 1;
    }

    fn commit(self: *Switcher, index: usize) void {
        const target = self.entries[index].context;
        self.close();
        _ = self.app.server.activateContext(self.app.alloc, target) catch |err| {
            std.log.err("glyphwire-host: context switch failed: {t}", .{err});
        };
    }

    fn close(self: *Switcher) void {
        self.open = false;
        self.gen +%= 1;
    }

    /// The rows to draw, top first. Borrowed; valid until the next
    /// `handleKeys`.
    pub fn rows(self: *const Switcher) []const Entry {
        return self.entries[0..self.len];
    }
};
