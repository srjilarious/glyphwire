// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const modal_list = @import("modal_list.zig");
const listcursor = @import("listcursor");

const App = app_mod.App;
const Engine = app_mod.Engine;

/// The context switcher: a small modal list of the programs the focused
/// pane is holding (its context stack), opened by a host-owned chord
/// (`host.conf.lua`'s `context_switcher_key`, Super+F12 by default).
/// Picking one brings it to the top of the stack, which is all
/// "foregrounding" a glyphwire program means -- a context that isn't on
/// top keeps running and keeps its screen, it just isn't drawn and gets
/// no input.
///
/// Below the programs is a pinned "+ new shell" row (also `n`): a fresh
/// `gw-shell` on a context of its own in the same pane, started in the
/// directory of the shell it was opened over (`App.spawnShell`). That is
/// how one pane holds several shells, each with its own long-running
/// program (an agent, a build) going on in the background.
///
/// Host-side rather than a client, so it works whichever program is in
/// front, pops up over the current screen instead of replacing it, and
/// the keys that drive it never reach a program at all.
///
/// Keys while open are `modal_list.readAction`'s: Up/Down move (held,
/// they keep moving), Enter switches, a row's label (1..9, then letters)
/// switches straight to that row, Escape closes; plus `n`
/// for a new shell. Drawn by `Renderer.drawListDialog` from `view`, like
/// the theme switcher. It opens with the *second* program selected, so
/// the chord then Enter flips between the two most recent programs.
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
    /// Programs in `entries`. The rows are these plus the new-shell row,
    /// which is always row `len`.
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
    /// `view`'s rows, rebuilt each time it is asked for.
    row_buf: [max_entries + 1]modal_list.Row = undefined,

    pub const max_entries = 32;
    pub const max_title = glyphwire.Context.max_title_len;
    pub const new_shell_text = "+ new shell";

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

        if (kb.pressed(.n) and !kb.ctrl() and !kb.alt() and !kb.super()) {
            self.commit(self.len);
            return true;
        }
        switch (modal_list.readAction(kb, chord_hit)) {
            .none => {},
            .close => self.close(),
            .commit => self.commit(self.selected),
            .move => |d| self.move(d),
            .pick => |i| if (i < self.rowCount()) self.commit(i),
        }
        return true;
    }

    /// Programs plus the new-shell row.
    fn rowCount(self: *const Switcher) usize {
        return self.len + 1;
    }

    fn openOn(self: *Switcher) void {
        self.pane = self.app.server.session.focusedPaneHandle();
        if (!self.snapshot()) return;
        self.open = true;
        self.selected = if (self.len > 1) 1 else 0;
        self.gen +%= 1;
    }

    /// Re-reads the pane's stack, keeping the selection on the same
    /// context (or on the new-shell row) when it is still there. Closes if
    /// the pane went away.
    fn refresh(self: *Switcher) void {
        const keep: ?glyphwire.ContextHandle = if (self.selected < self.len) self.entries[self.selected].context else null;
        const on_new_shell = self.selected == self.len;
        const before_len = self.len;
        if (!self.snapshot()) {
            self.close();
            return;
        }
        if (on_new_shell) {
            self.selected = self.len;
        } else if (keep) |h| {
            for (self.entries[0..self.len], 0..) |e, i| {
                if (e.context == h) {
                    self.selected = i;
                    break;
                }
            } else self.selected = @min(self.selected, self.len);
        }
        if (self.len != before_len) self.gen +%= 1;
    }

    /// Copies `pane`'s stack, top first, with each context's title (or a
    /// fallback name). False when the pane is gone. A pane whose own
    /// program has exited while other things hold it open has nothing
    /// alive on its base context, so that one is left out.
    fn snapshot(self: *Switcher) bool {
        // Asked before taking `ctx_mutex`: it takes the process table's
        // lock, which is never taken while holding that one.
        const hide_base = self.app.paneProgramExited(self.pane);

        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        const session = &server.session;
        const pane = session.panePtr(self.pane) orelse {
            self.len = 0;
            return false;
        };
        const stack = pane.stack.items;
        var n: usize = 0;
        var i: usize = stack.len;
        while (i > 0 and n < max_entries) {
            i -= 1;
            const handle = stack[i];
            if (hide_base and handle == pane.base) continue;
            var e: Entry = .{ .context = handle };
            const title = if (session.contextPtr(handle)) |ctx| ctx.title.items else "";
            if (title.len > 0) {
                const len = @min(title.len, max_title);
                @memcpy(e.title_buf[0..len], title[0..len]);
                e.title_len = len;
            } else {
                // A program that never named itself: a pane's base is
                // whatever the pane was started with, which is a shell
                // unless a window manager says otherwise, and the switcher
                // only ever makes shells.
                const fallback = if (session.isShellContext(handle))
                    std.fmt.bufPrint(&e.title_buf, "shell", .{}) catch ""
                else
                    std.fmt.bufPrint(&e.title_buf, "context {d}", .{handle}) catch "";
                e.title_len = fallback.len;
            }
            self.entries[n] = e;
            n += 1;
        }
        self.len = n;
        return true;
    }

    fn move(self: *Switcher, delta: isize) void {
        self.selected = listcursor.wrap(self.selected, self.rowCount(), delta);
        self.gen +%= 1;
    }

    fn commit(self: *Switcher, index: usize) void {
        self.close();
        if (index == self.len) {
            self.app.spawnShell(self.pane);
            return;
        }
        const target = self.entries[index].context;
        _ = self.app.server.activateContext(self.app.alloc, target) catch |err| {
            std.log.err("glyphwire-host: context switch failed: {t}", .{err});
        };
    }

    fn close(self: *Switcher) void {
        self.open = false;
        self.gen +%= 1;
    }

    /// What to draw while open: the pane's stack, top first, the top
    /// one tagged as the program in front, then the new-shell row.
    /// Borrowed; valid until the next `handleKeys`.
    pub fn view(self: *Switcher) ?modal_list.View {
        if (!self.open) return null;
        for (self.entries[0..self.len], 0..) |*e, i| {
            self.row_buf[i] = .{ .text = e.title(), .tag = if (i == 0) "  (current)" else "" };
        }
        self.row_buf[self.len] = .{ .text = new_shell_text };
        return .{
            .pane = self.pane,
            .title = "Switch to",
            .foot = "Enter switch  n new shell  Esc close",
            .rows = self.row_buf[0..self.rowCount()],
            .selected = self.selected,
        };
    }
};
