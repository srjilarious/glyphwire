// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-shell's job control: running a command on a pty (`runCommand`),
//! foregrounding, parking and reaping jobs, the pty reader thread that
//! pumps a job's output onto the grid, the result pipe, and crash
//! reports. `Prompt` methods moved out of main.zig and aliased back.

const std = @import("std");
const glyphwire = @import("glyphwire");
const hs = @import("shell_support").handshake;
const crashlog = @import("shell_support").crashlog;
const keyencode = @import("shell_support").keyencode;
const parse = @import("shell_support").parse;

const main = @import("main.zig");
const Prompt = main.Prompt;
const ModeTracker = main.ModeTracker;
const Pty = main.Pty;
const c = main.c;
const err_color = main.err_color;
const job_color = main.job_color;
const job_hangup_grace_ms = main.job_hangup_grace_ms;
const ptyMods = main.ptyMods;
const ptyMouseButton = main.ptyMouseButton;
const ptyMouseMove = main.ptyMouseMove;
const result_fd_env = main.result_fd_env;

/// Runs `argv` under a B0 "dumb PTY" (`src/pty.zig`): the child's
/// stdin/stdout/stderr are a pseudo-terminal. A background thread
/// (`ptyReaderThread`) mirrors the master onto the grid via
/// `write_text` -- `Layer.writeText` interprets the child's own SGR
/// colour + simple cursor/erase (Phase A) -- and the key loop below
/// encodes `InputListener` keystrokes (`keyencode.toPtyBytes`) back
/// into the master. Versus the previous piped, stdin-less spawn this
/// gets: output as it happens (a child on a tty line-buffers instead
/// of block-buffering into a pipe), working stdin, `isatty()`-gated
/// colour/progress, and Ctrl-C as a real SIGINT via the tty line
/// discipline. Full-screen apps (alternate screen, scroll regions)
/// still need more: the screen model `core.Layer` interprets.
///
/// The handshake (`glyphwire.handshake_marker`) is unchanged: a
/// glyphwire-aware child writes the marker to its stdout (= pty
/// slave), the reader thread detects it and stops mirroring, passing
/// the rest through to this process's own real stdio instead -- the
/// child is drawing over its own wire connection. `argv[0]` is
/// PATH-resolved by libc `execvp` (`PATH` already has `zig-out/bin`
/// prepended -- see `prependZigOutBinToPath`). A spawn failure is
/// reported onto the grid, not propagated.
///
/// Every argument gets the same leading `~`/`~/...` expansion `cd`
/// already gives its target (see `expandTilde`) -- `runCommandOpts`
/// is the same thing with that switchable.
pub fn runCommand(self: *Prompt, argv: []const []const u8) !void {
    _ = try self.runCommandOpts(argv, .{});
}

/// Knobs for `runCommandOpts`. Everything here defaults to what a
/// typed command line gets, so plain `runCommand` is `.{}`.
pub const RunOptions = struct {
    /// Whether each argument gets `expandTilde`. Off for an argument
    /// that is *data* rather than a path: `gw-hist`'s seed query (see
    /// `historySearch`), where expanding a typed `~/code` into
    /// `/home/you/code` would stop it matching the history lines that
    /// literally contain `~/code`.
    expand_tilde: bool = true,
};

/// How a `runCommandOpts` run ended.
pub const RunEnd = union(enum) {
    /// The child was reaped, or never started (then 127 / 1, the same
    /// status recorded for `{exit}`).
    status: u8,
    /// The child is still running behind the shell, parked on `jobs`.
    /// `runChain` hangs the rest of its line on it (`Job.rest`).
    backgrounded: *Job,
};

/// `runCommand`'s body -- see its doc comment. Split out so a caller
/// that builds argv itself can turn off the tilde expansion meant for a
/// *typed* path argument, and so a chain (`runChain`) learns how the
/// run ended.
pub fn runCommandOpts(self: *Prompt, argv: []const []const u8, opts: RunOptions) !RunEnd {
    const alloc = self.client.alloc;
    var expanded: std.ArrayList([]const u8) = .empty;
    defer {
        // Only the prefix actually appended before an early return
        // (the HOME-not-set case below) needs freeing.
        for (expanded.items, argv[0..expanded.items.len]) |exp, raw| {
            if (exp.ptr != raw.ptr) alloc.free(exp);
        }
        expanded.deinit(alloc);
    }
    for (argv) |arg| {
        const exp = if (opts.expand_tilde)
            self.expandTilde(arg) catch {
                try self.drawText("~: HOME not set", err_color, null);
                return .{ .status = 1 };
            }
        else
            arg;
        try expanded.append(alloc, exp);
    }

    // NUL-terminated, NULL-terminated argv for libc `execvp`.
    var argv_bufs: std.ArrayList([:0]u8) = .empty;
    defer {
        for (argv_bufs.items) |b| alloc.free(b);
        argv_bufs.deinit(alloc);
    }
    for (expanded.items) |a| try argv_bufs.append(alloc, try std.mem.concatWithSentinel(alloc, u8, &.{a}, 0));
    const argv_z = try alloc.allocSentinel(?[*:0]const u8, argv_bufs.items.len, null);
    defer alloc.free(argv_z);
    for (argv_bufs.items, 0..) |b, i| argv_z[i] = b.ptr;

    // Size the pty from the grid so a curses-ish child lays out right.
    const size = self.drawGetSize() catch glyphwire.LayerSize{ .cols = self.grid_cols, .rows = 24 };

    // Monotonic start time of the whole run, for `{dur}` on the next
    // prompt (this reduced std has no `std.time.Timer`).
    const started = std.Io.Clock.Timestamp.now(self.client.io, .awake);

    // A "result pipe" every foreground child gets for free: a
    // glyphwire-aware interactive program (`gw-hist`'s fuzzy history
    // search is the first) can `write()` a value to
    // `$GLYPHWIRE_RESULT_FD` before exiting and have it become this
    // prompt's line once the child is reaped -- see `result_fd_env`
    // and `readResultPipe`. No `O_CLOEXEC` on either end, matching
    // `pipeexec.zig`'s pipes: the write end has to survive fork+exec
    // into the child with no changes to `Pty.spawn` itself, and the
    // child inheriting the unused read end too is harmless.
    var result_pipe: [2]c_int = undefined;
    if (c.pipe2(&result_pipe, 0) != 0) return error.PipeFailed;
    const result_fd_var = try std.fmt.allocPrintSentinel(alloc, "{s}={d}", .{ result_fd_env, result_pipe[1] }, 0);
    defer alloc.free(result_fd_var);

    // Embedded, this prompt's surface is a layer someone else owns,
    // and a glyphwire-aware child drawing "inline" means inline
    // *here*. `GLYPHWIRE_LAYER` is what its `Client.connect` turns
    // into an `attach_layer`, so it lands in the panel instead of on
    // the root layer underneath it -- the layer counterpart of
    // `GLYPHWIRE_PANE`. Nothing is added when the shell owns its
    // context, so an ordinary session's children see no new variable.
    const layer_var: ?[:0]u8 = if (self.layer) |l|
        try std.fmt.allocPrintSentinel(alloc, "GLYPHWIRE_LAYER={d}", .{l}, 0)
    else
        null;
    defer if (layer_var) |v| alloc.free(v);
    const envp = if (layer_var) |v|
        try glyphwire.pty.buildEnvWith(alloc, &.{ result_fd_var, v })
    else
        try glyphwire.pty.buildEnvWith(alloc, &.{result_fd_var});
    defer alloc.free(envp);

    const pty = Pty.spawn(argv_z.ptr, @intCast(size.cols), @intCast(size.rows), envp) catch |err| {
        _ = c.close(result_pipe[0]);
        _ = c.close(result_pipe[1]);
        var buf: [160]u8 = undefined;
        const msg = switch (err) {
            error.CommandNotFound => std.fmt.bufPrint(&buf, "{s}: command not found", .{argv[0]}) catch "command not found",
            else => std.fmt.bufPrint(&buf, "{s}: {t}", .{ argv[0], err }) catch "failed to start command",
        };
        try self.drawText(msg, err_color, null);
        // Couldn't start it: record a status so `{exit}` reflects the
        // failure, but no duration (it never ran).
        self.last_status = if (err == error.CommandNotFound) 127 else 1;
        self.last_dur_ms = 0;
        self.have_status = true;
        return .{ .status = self.last_status };
    };
    // The child now holds its own copy of the write end (or, if it
    // never touches it, will simply exit and close it); this process
    // only ever reads (`readResultPipe`, once the child is reaped).
    // Closing the parent's own write-end copy now is what lets that
    // read see EOF once every process holding the write end -- just
    // the child -- has exited.
    _ = c.close(result_pipe[1]);

    // A foreground child's output is the only thing this layer draws
    // until it exits -- turn on cross-call VT state
    // (`core.Layer.pty_mode`) so a `CSI`/OSC sequence split across two
    // master reads still parses as one and a colour it sets stays set
    // until it resets it, instead of the shell's usual call-scoped
    // reset (which exists for exactly the opposite reason: interleaved
    // prompt/echo writes on this same layer). Best-effort -- a failure
    // here just means this run keeps the old call-scoped behaviour.
    self.drawSetPtyMode(true) catch {};

    // From here the job owns the pty, the result pipe's read end and
    // the reader thread -- on the heap, since a job put in the
    // background outlives this call.
    const job = try self.startJob(expanded.items, pty, result_pipe[0], started);

    // No listener means this isn't the interactive prompt (shouldn't
    // happen -- the exec path in `main` never calls here). Just wait.
    if (self.listener == null) {
        job.pty.wait();
        self.finishForegroundJob(job);
        return .{ .status = self.last_status };
    }

    switch (self.foregroundJob(job)) {
        .exited => {
            self.finishForegroundJob(job);
            return .{ .status = self.last_status };
        },
        .backgrounded => {
            try self.parkJob(job);
            return .{ .backgrounded = job };
        },
    }
}

/// A program started from this prompt, from spawn until it is reaped.
/// Heap-owned, because one that is put in the background (see
/// `foregroundJob`) keeps running while the prompt takes the next
/// line, and its pty, reader thread and result pipe go with it.
pub const Job = struct {
    /// `jobs` / `fg` number, assigned when it first goes to the
    /// background; 0 while it never has.
    id: u32 = 0,
    /// The command line, space-joined, for `jobs` when the program
    /// never named its context.
    name: []u8,
    pty: Pty,
    modes: ModeTracker = .{},
    reader_ctx: PtyReaderCtx = undefined,
    reader: std.Thread = undefined,
    /// The result pipe's read end -- see `result_fd_env`.
    result_fd: c_int,
    started: std.Io.Clock.Timestamp,
    /// The context the program drew its screen on, learned from this
    /// pane's stack while it ran (see `noteVisibleContext`). Null for a
    /// program that never made one: that includes every plain PTY
    /// program, which draws on the shell's own layer and so can't be
    /// put behind it.
    context: ?glyphwire.ContextHandle = null,
    /// What is left of the line this job was started from, when it was
    /// put in the background partway through a chain: `&& ./run` of
    /// `make && ./run`. Runs once the job exits, judged against its
    /// status -- straight away when it exits under `fg`, else through
    /// `ready_chains` (see `reportFinishedJobs`). Owned; null when the
    /// job ended its line.
    rest: ?parse.Line = null,
};

/// Wraps a just-spawned child as a `Job` and starts its output reader.
/// On failure the child is killed and everything is released, the
/// same as the old inline path did for a failed reader spawn.
pub fn startJob(self: *Prompt, argv: []const []const u8, pty: Pty, result_fd: c_int, started: std.Io.Clock.Timestamp) !*Job {
    const alloc = self.client.alloc;
    errdefer {
        var p = pty;
        p.signalGroup(std.posix.SIG.KILL);
        p.wait();
        p.deinit();
        _ = c.close(result_fd);
    }
    const job = try alloc.create(Job);
    errdefer alloc.destroy(job);
    const name = try std.mem.join(alloc, " ", argv);
    errdefer alloc.free(name);
    job.* = .{ .name = name, .pty = pty, .result_fd = result_fd, .started = started };
    job.reader_ctx = .{ .prompt = self, .master = job.pty.master, .modes = &job.modes };
    job.reader = try std.Thread.spawn(.{}, ptyReaderThread, .{&job.reader_ctx});
    return job;
}

/// How a stretch of `foregroundJob` ended.
pub const ForegroundEnd = enum {
    /// The child was reaped (or the host is going away).
    exited,
    /// This shell's own context came back on top of its pane while
    /// the child was still running -- the context switcher, or the
    /// program deactivating itself. The child keeps running behind.
    backgrounded,
};

/// Forwards input to `job`'s pty until the child exits or is put in
/// the background, in the order the host sent it -- a click, a resize
/// and a keystroke reach the child in the sequence they happened.
/// `pty.reaped()` polls (WNOHANG) once per loop; every event wakes
/// the wait, so its timeout only bounds how long an exit-with-no-input
/// waits. `fg` re-enters this for a job it brings back.
pub fn foregroundJob(self: *Prompt, job: *Job) ForegroundEnd {
    const alloc = self.client.alloc;
    const listener = self.listener.?;
    const pty = &job.pty;
    const modes = &job.modes;

    // Where the surface's top-left cell sits in the context, so a
    // click can be reported to the child in *its* screen's
    // coordinates. Zero when the shell owns the context and its
    // screen is the whole grid. Read once rather than per event: the
    // panel only moves on a window resize, which is handled in the
    // loop, and motion reporting would otherwise put a round trip on
    // every pointer move.
    var mouse_origin = self.surfaceOrigin();

    // Whether this pane's stack may have changed since it was last
    // read. A `context` event only sets this; the stack is read once
    // the child is known to be glyphwire-aware. The two race: an aware
    // program writes its handshake marker and creates its context
    // within a few milliseconds, so the event announcing its context
    // routinely arrives before the reader thread has resolved the
    // handshake. Acting on the event immediately dropped it, the
    // shell never learned the program's context, and switching back to
    // the shell left it stuck waiting. Starts true so a job brought
    // back by `fg` is checked straight away too.
    var stack_dirty = true;

    while (!pty.reaped()) {
        // Once the handshake resolves an aware child, it's drawing
        // over its own wire connection and never reads its own stdin
        // -- forwarding anything into its pty would just sit unread
        // or, worse, come back as a kernel-line-discipline echo (the
        // pty's termios is never put in raw/no-echo mode for it) that
        // the block below would then pass straight through to this
        // process's own real stdout as if the child had printed it.
        const is_aware = awareState(&job.reader_ctx) orelse false;

        // Only an aware child has a context of its own to put behind
        // the shell; a plain PTY child draws on this very layer. Also
        // the only case where the `Client` is free to ask: for a plain
        // child the reader thread is drawing through it.
        if (is_aware and stack_dirty) {
            stack_dirty = false;
            // The command-line title `dispatchLineText` set is now the
            // program's own context's job; left on this one, the
            // switcher would list two near-identical entries. Back to
            // `gw-shell <cwd>` (a no-op after the first time).
            self.syncPromptTitle();
            if (self.noteVisibleContext(job)) return .backgrounded;
        }

        const any_ev = (listener.next(.{ .duration = .{ .raw = .fromMilliseconds(120), .clock = .awake } }) catch null) orelse continue;
        const input_ev = any_ev.asInput() orelse {
            defer any_ev.deinit(alloc);
            switch (any_ev) {
                // Terminal resize -> SIGWINCH the child (via the kernel
                // line discipline). The listener coalesces a burst.
                //
                // It is also recorded for *this* process: the prompt's
                // own `grid_cols`/`grid_rows` and `line_start_row`
                // describe a grid that just moved out from under it,
                // and this loop is the only place those events are
                // read while a child holds the foreground. Dropping
                // them here (what used to happen) left the shell
                // laying out the next prompt against the pre-resize
                // grid -- the prompt landing mid-screen on top of
                // retained output, unusable until a ctrl+l. Applied by
                // `adoptPendingResize` once the child is reaped; not
                // here, since `handleResize` would redraw a prompt
                // over whatever the child is showing.
                .resize => |rev| {
                    pty.resize(@intCast(rev.cols), @intCast(rev.rows));
                    self.noteResize(rev.cols, rev.rows);
                    // A resize is also when an embedded panel is
                    // re-placed, so the click origin moves with it.
                    mouse_origin = self.surfaceOrigin();
                },
                // Visibility moved: read the pane's stack at the top of
                // the next pass, where awareness is current (see
                // `stack_dirty`).
                .context => stack_dirty = true,
                // Mouse: encoded to the child when it asked for
                // reporting, dropped otherwise.
                .mouse_button => |mev| if (!is_aware) ptyMouseButton(pty, modes, mev, mouse_origin),
                .mouse_move => |mev| if (!is_aware) ptyMouseMove(listener, pty, modes, mev, mouse_origin),
                // Terminal query replies (`CSI 6n` / DA / DECRQM) the
                // host parsed out of the child's own output on the way
                // to the grid.
                .terminal_reply => |reply| if (!is_aware) pty.writeAll(reply),
                // `?1004`: tell the child it gained or lost the
                // keyboard. The server sends `focus` per connection,
                // so under gmux this follows the focused pane.
                .focus => |fev| if (!is_aware and modes.focusEvents())
                    pty.writeAll(if (fev.focused) "\x1b[I" else "\x1b[O"),
                else => {},
            }
            continue;
        };

        if (is_aware) {
            switch (input_ev) {
                .text => |tev| alloc.free(tev.text),
                .paste => |tev| alloc.free(tev.text),
                // Ctrl+C interrupts an aware child the way the tty line
                // discipline does a plain one: SIGINT to its whole
                // group (a `gw-grep` and its `rg`). Nothing reaches its
                // pty to be turned into one. A program that wants
                // Ctrl+C as a key of its own (zoe, gw-hist) ignores
                // SIGINT -- see `applib.interrupt` -- and still gets
                // the key on its own listener. Ctrl+Shift+C is copy.
                .key => |kev| {
                    defer alloc.free(kev.key);
                    if (kev.pressed and kev.ctrl() and !kev.shift() and std.mem.eql(u8, kev.key, "c"))
                        pty.signalGroup(std.posix.SIG.INT);
                },
                .copy_request => {},
                .shutdown => {
                    self.should_exit = true;
                    pty.signalGroup(std.posix.SIG.HUP);
                    return .exited;
                },
                // A window manager's own commands (see `InputEvent.window_key`).
                // Never delivered here: this program is not one.
                .window_key, .window_text => {},
            }
            continue;
        }

        // Typed text (layout/dead-key/IME resolved) goes to the child's
        // stdin verbatim, exactly as a terminal feeds a pty -- taken
        // from the same ordered queue as key events so it can't
        // reorder around an Enter.
        const ev = switch (input_ev) {
            .text => |tev| {
                defer alloc.free(tev.text);
                pty.writeAll(tev.text);
                continue;
            },
            .paste => |tev| {
                // Ctrl+Shift+V while a child owns the pty: feed the
                // clipboard straight to its stdin, like a terminal
                // pasting into a running program. Wrap it in the
                // bracketed-paste guards if the child turned that mode
                // on (`?2004`), so an editor treats it as one literal
                // block instead of interpreting each line.
                defer alloc.free(tev.text);
                if (modes.bracketedPaste()) pty.writeAll("\x1b[200~");
                pty.writeAll(tev.text);
                if (modes.bracketedPaste()) pty.writeAll("\x1b[201~");
                continue;
            },
            // No shell prompt to copy while a child is foregrounded;
            // a selection copy is handled entirely host-side.
            .copy_request => continue,
            // Host window closing: SIGHUP the child and break the
            // foreground loop so the shell can flush and exit.
            .shutdown => {
                self.should_exit = true;
                pty.signalGroup(std.posix.SIG.HUP);
                return .exited;
            },
            // A window manager's own commands (see
            // `InputEvent.window_key`). Never delivered here.
            .window_key => |kev| {
                alloc.free(kev.key);
                continue;
            },
            .window_text => |tev| {
                alloc.free(tev.text);
                continue;
            },
            .key => |kev| kev,
        };
        defer alloc.free(ev.key);
        if (!ev.pressed) continue;
        const mods = ptyMods(ev.mods);
        // A plain printable key (no ctrl/alt) is delivered as a `text`
        // event, not re-encoded here -- otherwise the child sees it
        // twice. `toPtyBytes` still handles the named keys (Enter,
        // arrows, ...) and ctrl/alt combos, which produce no `text`.
        if (!mods.ctrl and !mods.alt and keyencode.charFromKeyName(ev.key, false) != null) continue;
        var kb: [32]u8 = undefined;
        if (keyencode.toPtyBytesOpts(ev.key, mods, modes.encodeOpts(), &kb)) |seq| pty.writeAll(seq);
    }
    return .exited;
}

/// Reads this pane's stack after a visibility change while `job` holds
/// the foreground. Returns true when this shell's own context is back
/// on top with the job's context still behind it -- the job has been
/// put in the background. Otherwise
/// remembers whatever else is on top as the job's screen the first
/// time there is one, which is how `fg` later knows what to activate.
///
/// The pane's stack rather than the event's own `context`: the event
/// names the *focused* context, and under a multiplexer that moves
/// every time focus changes pane, which says nothing about this one.
pub fn noteVisibleContext(self: *Prompt, job: *Job) bool {
    var list = self.client.listContexts() catch return false;
    defer list.deinit();
    const entries = list.entries();
    if (entries.len == 0) return false;
    const top = entries[0].context;
    if (top != list.current()) {
        if (job.context == null) job.context = top;
        return false;
    }
    // Back on top, but only a switch away if the job's screen is still
    // in the stack behind this one. A program on its way out destroys
    // its context before it is reaped, which also puts this shell back
    // on top; that is an exit in progress, and the loop keeps waiting
    // for the reap instead of announcing a background job.
    const ctx = job.context orelse return false;
    for (entries[1..]) |entry| {
        if (entry.context == ctx) return true;
    }
    return false;
}

/// The end of a foreground run: collects the reader thread and the
/// result pipe, puts the layer back in prompt mode, records `{exit}`
/// and `{dur}`, and frees the job. `job` has been reaped.
pub fn finishForegroundJob(self: *Prompt, job: *Job) void {
    const alloc = self.client.alloc;

    // Child reaped -> its slave is closed -> the reader's next master
    // read returns EOF/EIO and the thread exits on its own.
    job.reader.join();

    // Every process that held the write end (just the child) has now
    // exited, so this is a bounded read to EOF, not a block -- see
    // `readResultPipe`.
    if (self.readResultPipe(job.result_fd) catch null) |line| {
        if (self.pending_result_line) |old| alloc.free(old);
        self.pending_result_line = line;
    }

    // Back to the shell's own prompt/echo writes on this layer --
    // restore the call-scoped reset (setting the property either way
    // also clears whatever the child left half-open or un-reset, the
    // re-arm `core.Layer.pty_mode`'s doc comment describes) before the
    // reset write below and the next prompt redraw.
    self.drawSetPtyMode(false) catch {};
    // And the mouse is the host's again, even if the child died with
    // mouse reporting still on.
    self.drawSetMouseReport(false) catch {};

    // Undo the screen state a program that died without cleaning up
    // could leave behind: `?1049l` exits the alt screen, then `! p`
    // (DECSTR soft reset) puts the scroll region back to full and
    // un-hides the caret without moving the cursor or clearing
    // anything. Both are no-ops if the program already reset them.
    // This matters for `less -X` / `bat` / git's default pager, which
    // set a bottom-margin scroll region on the *primary* screen (no
    // alt screen) and would otherwise leave `regionActive()` stuck,
    // freezing scrollback and making the host wheel page the shell.
    self.drawText("\x1b[?1049l\x1b[!p", null, null) catch {};

    self.reportCrash(job);

    // Record the run's outcome for the next prompt's `{exit}` / `{dur}`.
    const elapsed_ms = job.started.untilNow(self.client.io).raw.toMilliseconds();
    self.last_dur_ms = if (elapsed_ms > 0) @intCast(elapsed_ms) else 0;
    self.last_status = job.pty.exit_code;
    self.have_status = true;

    self.freeJob(job);
}

/// Closes what `job` still holds and frees it. The reader thread must
/// already be joined.
pub fn freeJob(self: *Prompt, job: *Job) void {
    const alloc = self.client.alloc;
    if (job.rest) |*rest| rest.deinit();
    _ = c.close(job.result_fd);
    job.pty.deinit();
    alloc.free(job.name);
    alloc.destroy(job);
}

/// Puts `job` on the background list and says so, bash-style:
/// `[1] zoe main.zig`. It keeps its number if it had one (`fg` then
/// back again).
pub fn parkJob(self: *Prompt, job: *Job) !void {
    const alloc = self.client.alloc;
    if (job.id == 0) {
        self.next_job_id += 1;
        job.id = self.next_job_id;
    }
    self.jobs.append(alloc, job) catch |err| {
        // Nowhere to keep it: stop it rather than lose track of a
        // running child.
        job.pty.signalGroup(std.posix.SIG.HUP);
        job.pty.wait();
        job.reader.join();
        self.freeJob(job);
        return err;
    };
    // The child isn't writing this layer any more; the prompt is.
    self.drawSetPtyMode(false) catch {};
    self.drawSetMouseReport(false) catch {};
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}] {s}  (background)", .{ job.id, self.jobTitle(job) }) catch "[?] (background)";
    try self.drawText(msg, job_color, null);
}

/// What `jobs` and the background notice call `job`: its context's
/// title when the program named one, else the command line. The
/// returned slice may point into `job_title_buf`, so use it before the
/// next call.
pub fn jobTitle(self: *Prompt, job: *const Job) []const u8 {
    const ctx = job.context orelse return job.name;
    var list = self.client.listContexts() catch return job.name;
    defer list.deinit();
    const title = list.title(ctx) orelse return job.name;
    if (title.len == 0) return job.name;
    const n = @min(title.len, self.job_title_buf.len);
    @memcpy(self.job_title_buf[0..n], title[0..n]);
    return self.job_title_buf[0..n];
}

/// Reaps every background job that has exited, printing a `[1] done`
/// line for each (bash reports these just before the next prompt,
/// which is where this runs). The exit status goes in the line, not in
/// `{exit}` -- that belongs to whatever was run in the foreground. A
/// job holding the rest of its line (`Job.rest`) hands it to
/// `ready_chains`, for `runReadyChains` to run between lines rather
/// than from inside whatever builtin called this.
pub fn reportFinishedJobs(self: *Prompt) void {
    var fresh_row = false;
    var i: usize = 0;
    while (i < self.jobs.items.len) {
        const job = self.jobs.items[i];
        if (!job.pty.reaped()) {
            i += 1;
            continue;
        }
        _ = self.jobs.orderedRemove(i);
        job.reader.join();
        // Onto a row of its own, not the tail of the last command's
        // output.
        if (!fresh_row) {
            fresh_row = true;
            const cur = self.drawGetCursor() catch glyphwire.Cursor{ .row = 0, .col = 0 };
            if (cur.col != 0) self.drawText("\n", null, null) catch {};
        }
        var buf: [256]u8 = undefined;
        const msg = if (job.pty.exit_code == 0)
            std.fmt.bufPrint(&buf, "[{d}] done  {s}\n", .{ job.id, job.name }) catch "[?] done\n"
        else
            std.fmt.bufPrint(&buf, "[{d}] exit {d}  {s}\n", .{ job.id, job.pty.exit_code, job.name }) catch "[?] done\n";
        self.drawText(msg, job_color, null) catch {};
        self.reportCrash(job);
        if (job.rest) |rest| {
            job.rest = null;
            self.ready_chains.append(self.client.alloc, .{ .rest = rest, .status = job.pty.exit_code }) catch {
                // Nowhere to queue it: the rest of the line is dropped,
                // as if the job had been the end of it.
                var dropped = rest;
                dropped.deinit();
            };
        }
        self.freeJob(job);
    }
}

/// True when a background job still holding the rest of its line has
/// exited, so the idle prompt has a chain to run (see
/// `Prompt.runReadyChainsAtIdle`). Reaps as it checks, harmlessly:
/// `Pty.reaped` remembers the result for `reportFinishedJobs`.
pub fn chainReady(self: *Prompt) bool {
    for (self.jobs.items) |job| {
        if (job.rest != null and job.pty.reaped()) return true;
    }
    return false;
}

/// Lines of a crashed program's output shown in the scrollback; the
/// log file keeps all of `crashlog.Tail`.
pub const crash_report_lines = 40;

/// When a glyphwire-aware `job` died badly (see
/// `crashlog.shouldReport`), puts what it last wrote to its pty where
/// someone will see it: a banner and the tail of that output in the
/// scrollback, and the whole of it in a log file under
/// `crashlog.logDir`. A plain child needs none of this -- its output
/// was on the grid all along. `job` has been reaped and its reader
/// joined. Best-effort throughout.
pub fn reportCrash(self: *Prompt, job: *Job) void {
    const alloc = self.client.alloc;
    if (awareState(&job.reader_ctx) != true) return;
    const exit: crashlog.Exit = if (job.pty.term_signal != 0)
        .{ .signal = job.pty.term_signal }
    else
        .{ .code = job.pty.exit_code };
    const tail = &job.reader_ctx.tail;
    if (!crashlog.shouldReport(exit, tail.len)) return;

    const raw = alloc.alloc(u8, crashlog.Tail.capacity) catch return;
    defer alloc.free(raw);
    const clean_buf = alloc.alloc(u8, crashlog.Tail.capacity) catch return;
    defer alloc.free(clean_buf);
    const output = crashlog.stripAnsi(tail.contents(raw), clean_buf);

    var program_it = std.mem.tokenizeScalar(u8, job.name, ' ');
    const program = std.fs.path.basename(program_it.next() orelse job.name);
    var what_buf: [128]u8 = undefined;
    const what = crashlog.describe(&what_buf, program, exit);

    const log_path = self.writeCrashLog(job, program, what, output);
    defer if (log_path) |p| alloc.free(p);

    // Onto a row of its own, not the tail of whatever was last drawn.
    const cur = self.drawGetCursor() catch glyphwire.Cursor{ .row = 0, .col = 0 };
    if (cur.col != 0) self.drawText("\n", null, null) catch {};
    var banner_buf: [192]u8 = undefined;
    const banner = std.fmt.bufPrint(&banner_buf, "{s}; its last output:\n", .{what}) catch "crashed; its last output:\n";
    self.drawText(banner, err_color, null) catch {};

    const shown = crashlog.lastLines(output, crash_report_lines);
    if (shown.len > 0) {
        self.drawText(shown, null, null) catch {};
        if (shown[shown.len - 1] != '\n') self.drawText("\n", null, null) catch {};
    } else {
        self.drawText("(nothing)\n", null, null) catch {};
    }

    if (log_path) |p| {
        var line_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "full log: {s}\n", .{p}) catch "";
        self.drawText(line, err_color, null) catch {};
    }
}

/// Writes a crash report for `job` into `crashlog.logDir`, creating
/// the directory as needed. Returns the file's path (owned), or null
/// when there is nowhere to put it or the write failed -- the
/// scrollback report stands on its own either way.
pub fn writeCrashLog(self: *Prompt, job: *const Job, program: []const u8, what: []const u8, output: []const u8) ?[]u8 {
    const alloc = self.client.alloc;
    const io = self.client.io;

    const dir = (crashlog.logDir(alloc, self.environ_map) catch return null) orelse return null;
    defer alloc.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.warn("gw-shell: cannot create crash log dir {s}: {t}", .{ dir, err });
        return null;
    };

    var stamp_buf: [32]u8 = undefined;
    const stamp = self.formatTime(&stamp_buf, "%Y%m%d-%H%M%S");
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    const name = crashlog.logName(&name_buf, program, stamp, job.pty.pid);
    const path = std.fs.path.join(alloc, &.{ dir, name }) catch return null;

    var when_buf: [64]u8 = undefined;
    const when = self.formatTime(&when_buf, "%Y-%m-%d %H:%M:%S %z");
    const body = std.fmt.allocPrint(alloc, "command: {s}\nresult: {s}\ntime: {s}\n\n{s}", .{ job.name, what, when, output }) catch {
        alloc.free(path);
        return null;
    };
    defer alloc.free(body);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch |err| {
        std.log.warn("gw-shell: cannot write crash log {s}: {t}", .{ path, err });
        alloc.free(path);
        return null;
    };
    return path;
}

/// Stops every background job on the way out, the way a closing
/// terminal hangs up its session: SIGHUP, a short grace period to save
/// and exit, then SIGKILL for anything still there.
pub fn hangUpJobs(self: *Prompt) void {
    const alloc = self.client.alloc;
    for (self.jobs.items) |job| job.pty.signalGroup(std.posix.SIG.HUP);
    var waited_ms: u32 = 0;
    while (waited_ms < job_hangup_grace_ms) : (waited_ms += 20) {
        var all = true;
        for (self.jobs.items) |job| {
            if (!job.pty.reaped()) all = false;
        }
        if (all) break;
        std.Io.sleep(self.client.io, .fromMilliseconds(20), .awake) catch break;
    }
    for (self.jobs.items) |job| {
        if (!job.pty.reaped()) {
            job.pty.signalGroup(std.posix.SIG.KILL);
            job.pty.wait();
        }
        job.reader.join();
        self.freeJob(job);
    }
    self.jobs.deinit(alloc);
}

/// Drains `read_fd` (the result pipe's read end) to EOF and returns
/// what it held, trimming exactly one trailing `\n` for convenience --
/// or `null` if the child never wrote anything (the ordinary case: a
/// plain command that doesn't know about `$GLYPHWIRE_RESULT_FD`, or a
/// cancelled interactive picker). Caller frees a non-null result;
/// caller also owns closing `read_fd` itself (see `runCommand`'s
/// `defer`) -- this only reads.
pub fn readResultPipe(self: *Prompt, read_fd: c_int) !?[]u8 {
    const alloc = self.client.alloc;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = c.read(read_fd, &chunk, chunk.len);
        if (n <= 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(n)]);
    }
    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }
    if (out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return try out.toOwnedSlice(alloc);
}

/// Context for `ptyReaderThread`. `master` is owned by `runCommand`
/// (which closes it after the thread joins); the thread only reads it.
pub const PtyReaderCtx = struct {
    prompt: *Prompt,
    master: std.c.fd_t,
    /// Fed every master chunk so the foreground loop can see the DEC
    /// private modes the child sets.
    modes: *ModeTracker,
    /// Set once the handshake resolves: 0 = still unknown, 1 = aware,
    /// 2 = plain. The foreground loop below reads this to stop
    /// forwarding keystrokes/mouse/replies into an aware child's pty
    /// -- see `runCommand`'s use of `awareState`.
    aware: std.atomic.Value(u8) = .init(0),
    /// An aware child's output after the handshake, which goes to this
    /// process's real stdout where nobody sees it. Kept so a crash can
    /// be reported (see `reportCrash`). Written only by the reader
    /// thread and read only after it is joined.
    tail: crashlog.Tail = .{},
    /// The `mouse_report` value last sent for this child, so the
    /// reader only sends on a change (see `syncMouseReport`).
    mouse_report_sent: bool = false,
};

/// Mirrors the child's mouse-reporting modes onto the layer's
/// `mouse_report` whenever `ModeTracker` says they flipped. On the
/// reader thread, which is already the one drawing through the
/// client for a plain child.
pub fn syncMouseReport(ctx: *PtyReaderCtx) void {
    const on = ctx.modes.mouseReporting();
    if (on == ctx.mouse_report_sent) return;
    ctx.mouse_report_sent = on;
    ctx.prompt.drawSetMouseReport(on) catch {};
}

pub fn awareState(ctx: *const PtyReaderCtx) ?bool {
    return switch (ctx.aware.load(.acquire)) {
        1 => true,
        2 => false,
        else => null,
    };
}

/// Reads the pty master and mirrors it onto the grid via `write_text`
/// with the default foreground -- `Layer.writeText` interprets the
/// child's own SGR colour + simple cursor/erase sequences (Phase A),
/// so no line-splitting or cursor bookkeeping is needed here (a pty
/// also merges the child's stdout and stderr onto the one fd).
///
/// The first bytes are sniffed for `glyphwire.handshake_marker`: once
/// a definite answer is in, an aware child's remaining output goes to
/// this process's real stdout instead (it's drawing over its own wire
/// connection), a plain child's keeps mirroring. Runs until the master
/// hits EOF/EIO, which happens right after the child exits. Errors are
/// logged at worst, never propagated -- there's no caller waiting.
pub fn ptyReaderThread(ctx: *PtyReaderCtx) void {
    const self = ctx.prompt;
    const alloc = self.client.alloc;
    const io = self.client.io;

    var pending: std.ArrayList(u8) = .empty; // held until the handshake resolves
    defer pending.deinit(alloc);
    var aware: ?bool = null;

    var out_buf: [512]u8 = undefined;
    var real_out = std.Io.File.stdout().writer(io, &out_buf);

    // Mirrored output goes out as `write_text`, which must be valid
    // UTF-8: a character split across two reads is held back to the
    // next one, and stray non-UTF-8 bytes become U+FFFD. See
    // `pty.Utf8Carry`.
    var carry: glyphwire.pty.Utf8Carry = .{};
    defer carry.deinit(alloc);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    const mirror: Mirror = .{ .carry = &carry, .text = &text };

    var buf: [4096]u8 = undefined;
    while (true) {
        var pfd = [_]std.posix.pollfd{.{ .fd = ctx.master, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 1000) catch break;
        if (pfd[0].revents == 0) continue; // timeout, nothing ready

        const n = std.c.read(ctx.master, &buf, buf.len);
        if (n <= 0) break; // EOF, or EIO once the slave is fully closed
        const chunk = buf[0..@intCast(n)];

        // Watch for `ESC [ ? ... h/l` the child emits regardless of
        // whether we're mirroring it or handing it to an aware child
        // (aware output is wire JSON -- no such sequences, harmless).
        ctx.modes.feed(chunk);
        // Only a plain child's screen is this layer; an aware child
        // draws on its own and handles its own mouse.
        if (aware == null or aware.? == false) syncMouseReport(ctx);

        if (aware == null) {
            pending.appendSlice(alloc, chunk) catch break;
            aware = hs.aware(pending.items);
            if (aware == null) continue; // still a prefix of the marker
            ctx.aware.store(if (aware.?) 1 else 2, .release);
            const body = if (aware.?) pending.items[hs.marker.len..] else pending.items;
            emitChunk(ctx, &real_out, mirror, aware.?, body);
            pending.clearRetainingCapacity();
            continue;
        }
        emitChunk(ctx, &real_out, mirror, aware.?, chunk);
    }

    // EOF before the handshake could resolve (total output shorter
    // than the marker) -> treat as a plain child, flush what we held.
    if (aware == null and pending.items.len > 0) {
        emitChunk(ctx, &real_out, mirror, false, pending.items);
    }
    // A character the child's last write cut short.
    if (aware != true) {
        carry.finish(alloc, &text) catch {};
        if (text.items.len > 0) self.drawText(text.items, null, null) catch {};
    }
}

/// `ptyReaderThread`'s UTF-8 repair state for mirrored output, handed
/// to `emitChunk`.
pub const Mirror = struct {
    carry: *glyphwire.pty.Utf8Carry,
    text: *std.ArrayList(u8),
};

/// One chunk from `ptyReaderThread`: onto the grid (plain child) or to
/// this process's real stdout and the crash tail (aware child).
/// Best-effort -- a write failure here has nowhere useful to go.
pub fn emitChunk(ctx: *PtyReaderCtx, real_out: *std.Io.File.Writer, mirror: Mirror, aware: bool, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const self = ctx.prompt;
    if (aware) {
        ctx.tail.append(bytes);
        real_out.interface.writeAll(bytes) catch {};
        real_out.interface.flush() catch {};
    } else {
        mirror.carry.feed(self.client.alloc, bytes, mirror.text) catch return;
        if (mirror.text.items.len > 0) self.drawText(mirror.text.items, null, null) catch {};
    }
}
