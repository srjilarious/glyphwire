const std = @import("std");
const glyphwire = @import("glyphwire");
const wordsplit = @import("shell_support").wordsplit;
const complete = @import("shell_support").complete;
const glob = @import("shell_support").glob;
const hs = @import("shell_support").handshake;
const config = @import("shell_support").config;
const script_engine = @import("shell_support").script_engine;
const history = @import("shell_support").history;
const keyencode = @import("shell_support").keyencode;
const lineedit = @import("shell_support").lineedit;
const prompt_template = @import("shell_support").prompt_template;
const browsescroll = @import("shell_support").browsescroll;
const Pty = @import("pty.zig").Pty;

/// The left prompt template used when `shell.conf` configured a prompt
/// (`prompt.right` and/or the sub-templates) but not `prompt.left`. Byte
/// for byte the same as the unconfigured default `writeDefaultPrefix`
/// produces -- an absolute cwd, then `" > "`.
const default_prompt_left = "{cwd_full} > ";

/// Rows of context kept between the browse cursor and the top/bottom of
/// the window while walking scrollback with Up/Down, when `shell.conf`'s
/// `prompt{ scrolloff = N }` isn't set. See `Prompt.scrolloffRows`.
const default_scrolloff: usize = 8;

/// Per-command wall-clock budget for a `prompt{ commands = { ... } }`
/// var when its entry doesn't set `timeout_ms`. Kept short: the command
/// runs synchronously while the prompt is being drawn, so a hung `git`
/// in a huge repo must not stall the prompt for long -- it's killed and
/// `{name}` renders empty. See `Prompt.runCmdVar`.
const default_cmd_var_timeout_ms: u64 = 400;

/// Resize debounce (see the resize handling in `runPrompt`). A resize
/// drag emits an event per frame; redrawing the prompt on each one looks
/// messy, so the redraw waits until the size has been quiet for
/// `resize_settle_ms`. `resize_poll_ms` is the short `waitInputEvent`
/// timeout used while a resize is pending -- resize notifications don't
/// wake that wait, so the loop has to check back on its own.
const resize_settle_ms: i64 = 140;
const resize_poll_ms: i64 = 50;

comptime {
    // The captured-child marker detector keeps its own copy of the
    // marker string to stay dependency-free (see shell/handshake.zig);
    // keep it identical to what an aware client actually writes.
    if (!std.mem.eql(u8, hs.marker, glyphwire.handshake_marker))
        @compileError("shell_support.handshake.marker is out of sync with glyphwire.handshake_marker");
}

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    /// Resolves `path` against the filesystem into `resolved` (must be at
    /// least `PATH_MAX`); returns `resolved` on success, null otherwise.
    extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
};

/// libc time formatting for the prompt's `{time}` token -- this reduced
/// std has no `strftime`/`localtime`. `Tm` is glibc's `struct tm` (the
/// nine `int` fields, then `tm_gmtoff` / `tm_zone`).
const timelib = struct {
    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
    extern "c" fn time(t: ?*c_long) c_long;
    extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;
    extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const Tm) usize;
};

/// Parses a `#rgb` / `#rrggbb` (the `#` optional) colour for a powerline
/// segment; `null` for an unset field or a malformed value.
fn plColor(s: ?[]const u8) ?glyphwire.Color {
    const spec = s orelse return null;
    const p = prompt_template.parseColor(spec) orelse return null;
    return .{ .r = p.r, .g = p.g, .b = p.b };
}

/// glyphwire-shell: sets up discovery, then either execs into a given
/// command (`glyphwire-shell <command> [args...]`, unchanged from
/// milestone 5) or, given no command, runs the interactive prompt itself
/// -- see decisions.md, Discovery & Connection. Deliberately has no
/// pixzig dependency: input arrives as wire-level key events (see
/// src/client.zig's `InputListener`), captured by glyphwire-host and
/// relayed through the server, not read directly.
///
/// The prompt supports echo, Enter, real cursor movement and interior
/// insert/delete (arrow keys, ctrl+a/e/u, ctrl+arrow word jumps, ctrl+up/
/// down history recall -- see `Prompt`), and now launches a child process
/// per submitted line (see `Prompt.runCommand`). Every child's
/// stdout/stderr is piped and mirrored onto the grid via `write_text` by
/// default -- the assumption for any spawned command is "plain program
/// writing to a terminal" until proven otherwise. A child that's actually
/// "glyphwire compatible" (inherits `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX` and
/// draws to the grid itself over its own connection, the same way
/// `glyphwire-demo` or `glyphwire-ls` do) opts out of the mirroring
/// automatically: `Client.connect` signals the handshake as part of
/// connecting, with no separate call for a glyphwire-aware program to
/// remember -- see `Prompt.pumpChildOutput`. `cd` is a builtin (see `Prompt.doCd`) rather than spawned, since
/// changing directory in a child process wouldn't affect this one; the
/// prompt shows the current directory before `> ` so a `cd` actually
/// taking effect is visible. `exit` is a builtin too -- typing it is the
/// only way to quit, deliberately unlike the escape-quits-immediately
/// convention most pixzig examples/games use, which would kill an
/// interactive shell session out from under whatever's running in it;
/// `glyphwire-host` watches for this process actually exiting (see
/// host/main.zig's `reapChild`) rather than listening for a keypress
/// itself. Any key chorded with ctrl/alt/super that isn't one of the
/// sequences above is swallowed rather than typed literally into the
/// line (see `runPrompt`'s key loop) -- ctrl+c/ctrl+v included.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // Must run before *any* std.process.spawn/replace call below (both
    // the exec path a few lines down and everything Prompt.runCommand
    // spawns later) -- see the doc comment for why.
    try prependZigOutBinToPath(init.io, arena, init.environ_map);

    const socket_path = if (init.environ_map.get("GLYPHWIRE_SOCK")) |sp|
        sp
    else
        try spawnOwnServer(init.io, arena, init.environ_map);

    if (args.len < 2) {
        return runPrompt(init.io, alloc, socket_path, init.environ_map);
    }

    const child_argv = try arena.allocSentinel(?[*:0]const u8, args.len - 1, null);
    for (args[1..], 0..) |arg, i| child_argv[i] = arg.ptr;

    _ = c.execvp(args[1].ptr, child_argv.ptr);
    // execvp only returns on failure.
    std.debug.print("failed to exec {s}\n", .{args[1]});
    return error.ExecFailed;
}

/// Prepends `<startup cwd>/zig-out/bin` to `PATH` -- a dev-mode
/// convenience so typing `ls` or `glyphwire-demo` at the prompt finds
/// binaries built alongside glyphwire-shell itself, the same way an
/// installed program's sibling binaries would already be on `$PATH`.
/// Deliberately mutates *this* process's real environment (`libc`
/// `setenv`, like `spawnOwnServer` already does for the discovery vars)
/// rather than passing a one-off `environ_map` to each spawn call: an
/// `environ_map` passed to `std.process.spawn` only replaces the
/// *child's* environment, and per its own doc comment PATH from there is
/// never used to resolve `argv[0]` -- that resolution always reads the
/// *parent* (this process's) environment instead. And unlike a live
/// `cd`-relative lookup, an entry on `PATH` stays valid regardless of
/// where the shell's cwd wanders later.
///
/// Must run before the first `std.process.spawn`/`replace` call anywhere
/// in this process (verified empirically, not documented behavior): the
/// IO backend scans and caches `PATH` lazily on first use and never
/// rescans, so a `setenv` after that first call has no effect on argv[0]
/// resolution for any spawn after it either.
fn prependZigOutBinToPath(io: std.Io, alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return;
    const old_path = environ_map.get("PATH") orelse "";
    const new_path = try std.fmt.allocPrintSentinel(alloc, "{s}/zig-out/bin:{s}", .{ cwd_buf[0..cwd_len], old_path }, 0);
    defer alloc.free(new_path);
    if (c.setenv("PATH", new_path.ptr, 1) != 0) return error.SetEnvFailed;
}

/// Sets up its own server and discovery env vars (GLYPHWIRE_SOCK isn't
/// already inherited -- standalone use, e.g. `zig build shell -- <cmd>`
/// with no host), exactly like the original milestone-5 launcher.
/// Returns the socket path directly rather than relying on the caller to
/// re-read `environ_map`: std.process.spawn (used by the interactive
/// prompt path below) builds a child's environment from a snapshot taken
/// once at process startup, so a libc setenv() here wouldn't be visible
/// through `environ_map` afterward -- see host/main.zig's comment on the
/// same issue. execvp (the other path out of main) doesn't have this
/// problem: it inherits the live, setenv-mutated environ directly.
fn spawnOwnServer(io: std.Io, alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const socket_path = try socketPath(alloc, environ_map);

    // Relies on PATH resolution (std.process.spawn resolves argv[0] via the
    // parent's PATH when it contains no '/'), the same way any installed
    // pair of binaries would find each other — no self-exe lookup needed.
    var server_child = try std.process.spawn(io, .{
        .argv = &.{ "glyphwire-server", socket_path },
    });
    // Deliberately not waited on here: it keeps running as a background
    // process (later an orphan, reparented by the kernel) after this
    // process execs into (or runs the prompt in place of) the child.
    _ = &server_child;

    try waitForSocketReady(io, socket_path);

    const socket_path_z = try alloc.dupeZ(u8, socket_path);
    if (c.setenv("GLYPHWIRE_SOCK", socket_path_z, 1) != 0) return error.SetEnvFailed;
    if (c.setenv("GLYPHWIRE_CTX", glyphwire.default_context_id, 1) != 0) return error.SetEnvFailed;
    return socket_path;
}

fn socketPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(alloc, "{s}/glyphwire-{d}.sock", .{ dir, pid });
}

fn waitForSocketReady(io: std.Io, socket_path: []const u8) !void {
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (addr.connect(io)) |stream| {
            var s = stream;
            s.close(io);
            return;
        } else |_| {
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
    return error.ServerNeverCameUp;
}

/// Owned path to glyphwire's config directory (holds `shell.conf` and
/// `history`). Shared with glyphwire-host and glyphwire-ls -- see
/// `glyphwire.configDirPath`.
const configDirPath = glyphwire.configDirPath;

/// Drains every queued `resize` notification into `prompt.pending_resize`
/// (see `Prompt.noteResize`) and then applies it if the size has settled
/// (`applyPendingResize`). The prompt is *not* redrawn while a resize is
/// still in flight.
fn drainResizes(listener: *glyphwire.InputListener, prompt: *Prompt) void {
    var last: ?glyphwire.ResizeEvent = null;
    while (listener.pollResizeEvent()) |rev| last = rev;
    if (last) |rev| prompt.noteResize(rev.cols, rev.rows);
    prompt.applyPendingResize(false) catch {};
}

/// Prints the current directory followed by `> `, echoes typed characters
/// live, Enter commits the line and starts a new prompt row below it. See
/// `Prompt` for the rest of the line editing (cursor movement, interior
/// insert/delete) and command dispatch. Runs forever (killed along with
/// the rest of the process tree, same as any other long-lived child in
/// this codebase).
fn runPrompt(io: std.Io, alloc: std.mem.Allocator, socket_path: []const u8, environ_map: *const std.process.Environ.Map) !void {
    var client = glyphwire.Client.connect(io, alloc, socket_path) catch |err| {
        std.log.err("prompt: failed to connect: {t}", .{err});
        return;
    };
    defer client.deinit();

    const listener = glyphwire.InputListener.connect(io, alloc, socket_path, &.{ "key", "text", "mouse_button", "scroll", "resize" }) catch |err| {
        std.log.err("prompt: failed to subscribe: {t}", .{err});
        return;
    };
    defer listener.deinit();

    var prompt: Prompt = .{ .client = &client, .environ_map = environ_map, .listener = listener };
    // The live environment starts as a working copy of the startup
    // snapshot; `sh.setenv` from a script mutates this copy (and libc, for
    // children). Seeded before `defer prompt.deinit()` so the deinit is
    // always safe.
    prompt.env = std.process.Environ.Map.init(alloc);
    {
        var it = environ_map.iterator();
        while (it.next()) |e| try prompt.env.put(e.key_ptr.*, e.value_ptr.*);
    }
    // Unreachable before `exit` gave this loop a clean return path --
    // every previous exit was a hard kill, so this never ran and the leak
    // never surfaced.
    defer prompt.deinit();

    {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        prompt.grid_cols = snapshot.cols();
        prompt.grid_rows = snapshot.rows();
    }

    // For `{host}` in a configured prompt template -- resolved once, it
    // doesn't change over a session.
    prompt.resolveHostname();
    prompt.resolveIconMetrics();

    // Startup config + persistent history, both under
    // `$XDG_CONFIG_HOME/glyphwire` (or `$HOME/.config/glyphwire`). A
    // missing config directory or file is not an error -- the shell just
    // starts with no configured aliases and an empty history.
    if (configDirPath(alloc, environ_map)) |config_dir| {
        defer alloc.free(config_dir);
        prompt.initScriptEngine(config_dir) catch |err| {
            std.log.warn("prompt: couldn't start the script engine: {t}", .{err});
        };
        try prompt.loadStartupConfig(config_dir);
        try prompt.loadHistory(config_dir);
    } else |_| {}

    try prompt.showPrompt();

    // Scripted input for automated screenshots / smoke runs: if
    // GLYPHWIRE_SHELL_SCRIPT names a readable file, each non-blank,
    // non-`#`-comment line is played through the prompt exactly as if it
    // had been typed and submitted, before the interactive key loop
    // starts. The prompt then carries on normally (the window stays up so
    // a screenshot tool -- see the host's `--screenshot` -- can capture
    // the result), unless one of the scripted lines was `exit`.
    if (environ_map.get("GLYPHWIRE_SHELL_SCRIPT")) |script_path| {
        if (script_path.len > 0) {
            runScriptFile(io, alloc, &prompt, script_path) catch |err| {
                std.log.err("prompt: couldn't run GLYPHWIRE_SHELL_SCRIPT '{s}': {t}", .{ script_path, err });
            };
            if (prompt.should_exit) return;
        }
    }

    while (true) {
        // Drains any pending mouse click before (possibly) blocking below
        // -- non-blocking, so this never delays key handling. A left
        // click resolves the same way Enter-while-browsing does
        // (`activateSelectionAt`), regardless of whether anything's
        // currently being typed: a click is a deliberate, targeted
        // action, not something that should be gated on browse state the
        // way keyboard Enter is. Worst-case latency for a click that
        // arrives with no keyboard activity at all is bounded by the
        // 500ms fallback timeout below, same as this loop's general
        // responsiveness tradeoff -- there's no single wait that blocks
        // on both key and mouse events at once.
        if (listener.pollMouseButtonEvent()) |mev| {
            defer alloc.free(mev.button);
            if (mev.pressed and std.mem.eql(u8, mev.button, "left")) {
                // `mev.view_offset` is how far the host was scrolled back
                // when the click happened -- ground truth, stamped by the
                // host atomically with the click, so trust it over the
                // locally-mirrored `view_scroll` (which can lag a
                // host-driven wheel/scrollbar scroll by a loop iteration).
                // It's both the lookup offset (resolve against the row
                // actually under the pointer) and, once recorded here,
                // what makes `setLine` -> `setCursorAt` snap the view back
                // down to the live prompt when the click activates a
                // command -- clicking an `ls` entry in scrollback should
                // land you back at the new prompt, not leave you scrolled
                // up.
                prompt.view_scroll = mev.view_offset;
                try prompt.activateSelectionAt(mev.cell.row, mev.cell.col, mev.view_offset);
            }
        }

        // Keep `prompt.view_scroll` current with any host-driven scroll
        // (mouse wheel, scrollbar) so browse-down and the type-to-snap-back
        // in `setCursorAt` know the real offset. Drained non-blocking,
        // same as the mouse queue above.
        while (listener.pollScrollEvent()) |sev| prompt.view_scroll = sev.offset;

        // A window resize rebuilt the grid (bottom-anchored) and changed
        // its dimensions, so the recorded prompt rows, the right chain's
        // column and every grid-size clamp are stale. The re-layout is
        // debounced (`Prompt.noteResize` / `applyPendingResize`): drain
        // the burst here, redraw only once the size has settled.
        drainResizes(listener, &prompt);

        // One ordered stream of key + text events (see `InputEvent`).
        // Blocks until one is queued rather than polling on a fixed
        // interval; the timeout is just a fallback heartbeat -- but while a
        // resize is settling it polls fast (`resize_poll_ms`), since resize
        // notifications don't wake this wait.
        const wait_ms: i64 = if (prompt.pending_resize != null) resize_poll_ms else 500;
        const input_ev = (try listener.waitInputEvent(.{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } })) orelse {
            // Idle tick. Drain/apply any resize first; skip the right-chain
            // refresh entirely while a resize is still in flight so it
            // isn't drawn at an intermediate size.
            drainResizes(listener, &prompt);
            if (prompt.pending_resize == null and prompt.right_dynamic and prompt.browse_pos == null) {
                // Refresh the powerline right chain so `{time}` keeps
                // ticking while nothing is typed.
                prompt.drawRightChain() catch {};
                prompt.placeInputCursor() catch {};
            }
            continue;
        };
        // A real keystroke means the drag (if any) is over -- apply a
        // still-settling resize now so the keystroke lands on a correct
        // layout.
        prompt.applyPendingResize(true) catch {};

        // Committed text input -- the characters the user typed, already
        // resolved through their OS keyboard layout / dead keys / IME.
        // Taken from the same queue as key events so "type then Enter"
        // can't reorder. Text only edits the live line, so it's held back
        // while browsing scrollback, matching how the printable-key path
        // used to gate on `browse_pos`. The physical key event that
        // accompanies each keystroke in real host use is a separate
        // `.key` event and just falls through the handling below doing
        // nothing.
        const ev: glyphwire.KeyEvent = switch (input_ev) {
            .text => |tev| {
                defer alloc.free(tev.text);
                if (prompt.browse_pos == null) try prompt.insertText(tev.text);
                continue;
            },
            .key => |kev| kev,
        };
        defer alloc.free(ev.key);
        if (!ev.pressed) continue; // only key-down drives the prompt

        // Only `ctrl` gates key-event handling now (the ctrl+letter / ctrl+
        // arrow editing chords below). `alt` / `super` chords have no
        // explicit cases and no longer need checking: plain characters
        // come from the `text` stream, and the host doesn't emit `text`
        // for a genuine modifier chord, so an unhandled alt/super combo
        // simply does nothing here.
        const ctrl = listener.isKeyDown("left_control") or listener.isKeyDown("right_control");

        // Tab completion's "list on the second press" needs to know the
        // previous key was also Tab; any other key breaks that streak.
        if (!std.mem.eql(u8, ev.key, "tab")) prompt.completion_armed = false;

        if (std.mem.eql(u8, ev.key, "enter")) {
            if (prompt.browse_pos != null) {
                try prompt.browseEnter();
            } else {
                try prompt.submitLine();
                if (prompt.should_exit) return; // "exit" was typed -- see submitLine
            }
        } else if (std.mem.eql(u8, ev.key, "escape")) {
            // The explicit "never mind, back to typing" key -- everything
            // else that snaps browsing back to the prompt (below) does so
            // as a side effect of also doing something; this does nothing
            // else.
            try prompt.setCursorAt(prompt.cursor);
        } else if (std.mem.eql(u8, ev.key, "tab")) {
            // Filename completion on the live line only -- Tab does
            // nothing while browsing scrollback.
            if (prompt.browse_pos == null) try prompt.doComplete();
        } else if (std.mem.eql(u8, ev.key, "backspace")) {
            try prompt.deleteBackward();
        } else if (std.mem.eql(u8, ev.key, "delete")) {
            try prompt.deleteForward();
        } else if ((ctrl and std.mem.eql(u8, ev.key, "a")) or std.mem.eql(u8, ev.key, "home")) {
            // Home mirrors ctrl+a in every state: on the live line it goes
            // to column 0, and while browsing scrollback `moveCursorTo` ->
            // `setCursorAt` snaps back to the live line first (same as
            // ctrl+a does today).
            try prompt.moveCursorTo(0);
        } else if ((ctrl and std.mem.eql(u8, ev.key, "e")) or std.mem.eql(u8, ev.key, "end")) {
            // End mirrors ctrl+e, likewise unaffected by browse mode.
            try prompt.moveCursorTo(prompt.buffer.items.len);
        } else if (ctrl and std.mem.eql(u8, ev.key, "u")) {
            try prompt.killToStart();
        } else if (ctrl and std.mem.eql(u8, ev.key, "l")) {
            try prompt.clearScreen();
        } else if (ctrl and std.mem.eql(u8, ev.key, "left")) {
            // Deliberately unaffected by browse mode, unlike ctrl+up/down
            // above: ctrl+left/right always means "word-jump on the live
            // line," which (via moveCursorTo -> setCursorAt) always snaps
            // browsing back to the prompt first -- there's no "bigger
            // browse step" meaning for these two.
            try prompt.moveCursorTo(prompt.wordLeft());
        } else if (ctrl and std.mem.eql(u8, ev.key, "right")) {
            try prompt.moveCursorTo(prompt.wordRight());
        } else if (ctrl and std.mem.eql(u8, ev.key, "up")) {
            // Ctrl+up means history recall at the prompt (unchanged), but
            // a bigger browse-step (5 rows) while already browsing --
            // there's no real "recall history while browsing" case to
            // preserve, since browsing and editing the live line are
            // mutually exclusive states.
            if (prompt.browse_pos != null) {
                try prompt.browseUp(5);
            } else {
                try prompt.historyUp();
            }
        } else if (ctrl and std.mem.eql(u8, ev.key, "down")) {
            if (prompt.browse_pos != null) {
                try prompt.browseDown(5);
            } else {
                try prompt.historyDown();
            }
        } else if (std.mem.eql(u8, ev.key, "up")) {
            try prompt.browseUp(1);
        } else if (std.mem.eql(u8, ev.key, "down")) {
            try prompt.browseDown(1);
        } else if (std.mem.eql(u8, ev.key, "left")) {
            // Not explicitly asked for, but needed alongside ctrl+left/
            // right: without plain single-character movement too, the
            // caret (drawn by glyphwire-host wherever the raw grid cursor
            // sits) could wander away from `prompt.cursor` -- the offset
            // typing/backspace actually act on -- which would look
            // confusing (caret in one place, edits landing in another).
            // While browsing (`browse_pos != null`), Left instead moves
            // within whatever row is currently being browsed -- see
            // `browseLeft`.
            if (prompt.browse_pos != null) {
                try prompt.browseLeft();
            } else {
                // Step a whole codepoint, not one byte: a CJK character is
                // three bytes but one cursor stop (see `lineedit`).
                try prompt.moveCursorTo(lineedit.prevBoundary(prompt.buffer.items, prompt.cursor));
            }
        } else if (std.mem.eql(u8, ev.key, "right")) {
            if (prompt.browse_pos != null) {
                try prompt.browseRight();
            } else {
                try prompt.moveCursorTo(lineedit.nextBoundary(prompt.buffer.items, prompt.cursor));
            }
        }
        // Plain character insertion is not handled here: it comes from the
        // `.text` branch of the switch above, which is the only correct
        // source for a non-US layout, an AltGr combo or CJK IME. An
        // unhandled key event (a bare letter, or a ctrl/alt chord with no
        // explicit case above like ctrl+c / alt+f) just falls through and
        // does nothing -- a real terminal swallows those too, and the host
        // suppresses `text` for genuine modifier chords, so
        // nothing types.
    }
}

/// Plays a file of shell commands through `prompt`, one line at a time,
/// each `setLine` + `submitLine` -- the exact path a typed-and-entered
/// line takes, so a scripted `ls` blocks on its child and draws to the
/// grid identically. Lines are trimmed; blank lines and `#` comments are
/// skipped. Stops early if a line was `exit` (sets `prompt.should_exit`).
/// See `runPrompt`'s GLYPHWIRE_SHELL_SCRIPT block for why this exists.
fn runScriptFile(io: std.Io, alloc: std.mem.Allocator, prompt: *Prompt, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024));
    defer alloc.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try prompt.setLine(line);
        try prompt.submitLine();
        if (prompt.should_exit) return;
    }
}

/// One filename offered by Tab completion -- `name` is the raw directory
/// entry (no trailing slash), `is_dir` drives the `/` vs ` ` suffix on a
/// unique match and the `/` shown in a listing.
const CompletionCandidate = struct { name: []const u8, is_dir: bool };

/// Alias store backing the prompt's `alias`/`unalias` builtins. Seeded at
/// startup from `~/.config/glyphwire/shell.conf`'s `alias(name, value)`
/// calls (see `Prompt.loadStartupConfig`), then mutated for the rest of
/// the session by the builtins; nothing here is written back to disk, so
/// a session-only `alias` doesn't survive `exit`. Keys and values are
/// owned dups; `Prompt.deinit` frees the whole table.
const AliasTable = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn deinit(self: *AliasTable, alloc: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        self.map.deinit(alloc);
    }

    /// Binds `name` to `value`, replacing (and freeing) any prior binding
    /// for `name`.
    fn set(self: *AliasTable, alloc: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const key = try alloc.dupe(u8, name);
        errdefer alloc.free(key);
        const val = try alloc.dupe(u8, value);
        errdefer alloc.free(val);

        const gop = try self.map.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            alloc.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val;
    }

    /// Removes `name`'s binding; returns whether there was one to remove.
    fn remove(self: *AliasTable, alloc: std.mem.Allocator, name: []const u8) bool {
        if (self.map.fetchRemove(name)) |kv| {
            alloc.free(kv.key);
            alloc.free(kv.value);
            return true;
        }
        return false;
    }

    fn get(self: *const AliasTable, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }
};

/// The prompt's line-editing state. Tracks where the current line started
/// and a cursor *offset* into the line -- needed the moment editing can
/// happen anywhere but the end (ctrl+a/e/u, ctrl+arrow word jumps, plain
/// arrow movement). `buffer` mirrors the line's text locally: the server
/// holds the authoritative cells, but word-jump math (`wordLeft`/
/// `wordRight`) needs to inspect characters, and `submitLine` echoes the
/// full line to scrollback, neither of which is worth a round trip to
/// read back over the wire.
const Prompt = struct {
    client: *glyphwire.Client,
    /// The environment as it was at startup -- a read-only snapshot from
    /// `std.process.Init`. Everything that doesn't change over a session
    /// (`$USER`, `$HOME`, `$XDG_*`, hostname) reads from here.
    environ_map: *const std.process.Environ.Map,
    /// The shell's *live* environment: seeded from `environ_map`, then
    /// mutated by `sh.setenv` / `sh.unsetenv` from a script (which also
    /// push the change into libc so spawned children inherit it). The
    /// prompt's `{env:NAME}` token reads this, so e.g. a venv-activate
    /// script's `$VIRTUAL_ENV` shows up immediately. Set in `runPrompt`.
    env: std.process.Environ.Map = undefined,
    /// The prompt's key/mouse/scroll feed. Set by `runPrompt` after
    /// connecting; `runCommand`'s pty input loop reads keystrokes from it
    /// while a command holds the foreground.
    listener: ?*glyphwire.InputListener = null,
    line_start_row: usize = 0,
    line_start_col: usize = 0,
    buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,
    /// Offset into `buffer`, 0..=buffer.items.len, where the next
    /// insert/delete acts and where the on-screen cursor should sit.
    cursor: usize = 0,
    /// Set by `submitLine` when the typed line was `exit` -- the caller
    /// (`runPrompt`'s key loop) checks this after every submitted line and
    /// returns instead of drawing another prompt, ending this process.
    should_exit: bool = false,
    /// Every non-empty line ever submitted, oldest first -- `submitLine`
    /// appends to it, `historyUp`/`historyDown` read from it. Each entry
    /// is an owned dupe (the submitted line's `buffer` gets cleared by the
    /// next `showPrompt`, so history can't just borrow it).
    history: std.ArrayList([]const u8) = .empty,
    /// Alias bindings from the `alias` builtin -- see `AliasTable` and
    /// `expandAliases`. Empty until the user defines one.
    aliases: AliasTable = .{},
    /// True when the last key was a Tab that found multiple matches with
    /// no further common prefix to fill in -- the next Tab then prints the
    /// candidate list (bash's "ring the bell once, list on the second
    /// press"). Any non-Tab key clears it (see `runPrompt`).
    completion_armed: bool = false,
    /// `null` means the line on screen is the one actually being typed
    /// (not a recalled history entry). Otherwise, an index into `history`
    /// for whichever entry `historyUp`/`historyDown` last loaded.
    history_index: ?usize = null,
    /// What `buffer` held right before the first `historyUp` of a
    /// recall -- `historyDown` past the newest entry restores this,
    /// mirroring a real shell's "go back to what I was typing" behavior.
    /// Only meaningful while `history_index != null`.
    scratch: std.ArrayList(u8) = .empty,
    /// The root layer's size -- fetched once at startup (`runPrompt`) to
    /// clamp browse-mode horizontal movement (`browseLeft`/`browseRight`)
    /// and to keep the prompt from `setCursor`ing off the bottom row after
    /// a command's output scrolled the layer.
    grid_cols: usize = 0,
    grid_rows: usize = 0,
    /// A window resize that hasn't been applied yet -- the prompt redraw
    /// is held off until the size settles (see `resize_settle_ms` and the
    /// resize handling in `runPrompt`). Only the latest size in a burst is
    /// kept; `resize_seen_at` is when it arrived.
    pending_resize: ?glyphwire.ResizeEvent = null,
    resize_seen_at: ?std.Io.Clock.Timestamp = null,
    /// Non-null while the cursor is browsing the grid instead of sitting on
    /// the live prompt (`browseUp`/`browseDown`/`browseLeft`/`browseRight`,
    /// entered by plain Up with nothing being typed) -- see those methods'
    /// doc comments, and `setCursorAt`'s for how every ordinary editing
    /// operation implicitly ends browsing just by moving the real cursor.
    browse_pos: ?glyphwire.Cursor = null,
    /// The host's current scrollback view offset in rows (see
    /// `core.Layer.view_scroll`), mirrored locally: bumped by
    /// `scrollWindow` when browsing past the top of the window scrolls the
    /// host view, updated from `scroll` notifications when the host's own
    /// wheel/scrollbar moves it, and reset to 0 by `setCursorAt` so
    /// starting to type snaps back to the live prompt.
    view_scroll: usize = 0,
    /// Last-known maximum scrollback offset (`{offset, max}.max` from
    /// `scroll_view` -- how many retained history rows are above the live
    /// viewport). Refreshed on entering browse and on every `scrollWindow`
    /// so `browsescroll.up` knows when the scrollback is exhausted. Grows
    /// over a session; a slightly stale value just means a browse step
    /// scrolls one iteration less far before the next call corrects it.
    view_max: usize = 0,
    /// Absolute path to `~/.config/glyphwire/history`, set by
    /// `loadHistory` once it knows the config directory exists. `null`
    /// when there's no `$HOME`/`$XDG_CONFIG_HOME` to derive it from, or
    /// the directory couldn't be created -- history just isn't persisted
    /// then. Owned; freed in `deinit`.
    history_path: ?[]const u8 = null,

    /// The persistent Lua interpreter -- runs `shell.conf` and every
    /// script builtin (`~/.config/glyphwire/scripts/*.lua`, `defcmd`).
    /// `null` when the shell has no config directory. Heap-allocated and
    /// owned; `deinit` tears it down.
    script_engine: ?*script_engine.ScriptEngine = null,

    /// The parsed `shell.conf`, kept alive for the whole session so the
    /// prompt can read `.prompt` live on every redraw (see `promptCfg` /
    /// `writePromptPrefix`). `null` when there was no config file or no
    /// config directory. Borrowed from `script_engine.?.cfg` -- the
    /// engine owns the storage, not this pointer.
    prompt_config: ?*const config.ShellConfig = null,

    /// Memoised output of the `prompt{ commands = { ... } }` vars for the
    /// current prompt. `writePromptPrefix` clears it (`resetCmdVars`) so
    /// each fresh prompt re-runs the commands, but the idle right-chain
    /// refresh and multi-line redraws in between reuse the cached values
    /// rather than shelling out again. Keyed by the config-owned
    /// `CommandVar.name` (not duped); values are `client.alloc`-owned
    /// (freed in `resetCmdVars` / `deinit`); an empty value means the
    /// command was gated off by its `when`, failed, or timed out.
    cmd_var_cache: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Names currently being resolved, for cycle / depth breaking when a
    /// command var's `when` references another. `resolveCmdVar` pushes on
    /// entry and pops on exit; a name already present (or a full stack)
    /// resolves to empty.
    cmd_var_stack: [16][]const u8 = undefined,
    cmd_var_depth: usize = 0,

    /// The last command's exit status and wall-clock run time, plus
    /// whether any command has run this session -- feeds `{exit}` /
    /// `{exit_code}` / `{dur}` / `{duration}` and a segment's `when =
    /// "error" | "slow"`. `runCommand` (external) and `runScriptBuiltin`
    /// (a Lua builtin's numeric return) update these; the script builtin
    /// always reports `last_dur_ms = 0`. The `cd` / `alias` / `unalias`
    /// builtins leave them alone.
    last_status: u8 = 0,
    last_dur_ms: u64 = 0,
    have_status: bool = false,

    /// Machine hostname for `{host}`, resolved once by `resolveHostname`
    /// into `host_buf` (so the slice stays valid for the session). Empty
    /// until then, or if it couldn't be determined.
    host: []const u8 = "",
    host_buf: [64]u8 = undefined,

    /// Input-line box for the repaint model. `line_start_row`/`_col` (above)
    /// are its top-left; `input_max_col` is the exclusive right edge the
    /// typed text may not cross (so a locked right-side prompt stays put),
    /// and `input_scroll` is the first buffer byte shown when the line is
    /// longer than the box. `renderInputLine` repaints the whole box on
    /// every edit rather than shifting cells with `insert_cells`/
    /// `delete_cells`.
    input_max_col: usize = 0,
    input_scroll: usize = 0,

    /// Powerline layout state, set by `writePowerlinePrefix`. `pl_top_row`
    /// is the row the segment chains live on; `right_dynamic` is true when
    /// `right_segments` are configured (they get refreshed on the idle
    /// timeout so `{time}` ticks, and -- on a single-line prompt -- after
    /// every keystroke so they stay pinned).
    pl_top_row: usize = 0,
    right_dynamic: bool = false,
    prompt_lines: u8 = 1,

    /// How a `{icon:...}` in a prompt template is drawn, from the session's
    /// cell pixel metrics (`resolveIconMetrics`). `icon_max_h == 0` means
    /// metrics were unavailable -> fall back to the old aspect-fit-in-one-
    /// cell behavior. Otherwise the icon is `.natural`-scaled and capped to
    /// one cell-height (so it fills the row without vertical overflow) and
    /// occupies `icon_cols` columns (~2 for a square icon in a ~1:2 cell).
    icon_cols: usize = 1,
    icon_max_h: u32 = 0,

    fn deinit(self: *Prompt) void {
        const alloc = self.client.alloc;
        for (self.history.items) |line| alloc.free(line);
        self.history.deinit(alloc);
        self.scratch.deinit(alloc);
        self.buffer.deinit(alloc);
        self.aliases.deinit(alloc);
        if (self.history_path) |p| alloc.free(p);
        // `prompt_config` just borrows `script_engine.?.cfg`; the engine
        // frees it.
        if (self.script_engine) |eng| eng.deinit();
        self.env.deinit();
        self.resetCmdVars();
        self.cmd_var_cache.deinit(alloc);
    }

    /// Drops every memoised command-var value. Called at the top of
    /// `writePromptPrefix` (so a new prompt re-runs the commands) and
    /// from `deinit`.
    fn resetCmdVars(self: *Prompt) void {
        const alloc = self.client.alloc;
        var it = self.cmd_var_cache.valueIterator();
        while (it.next()) |v| alloc.free(v.*);
        self.cmd_var_cache.clearRetainingCapacity();
        self.cmd_var_depth = 0;
    }

    /// The parsed prompt config, or `null` when there's no `shell.conf`.
    fn promptCfg(self: *Prompt) ?*const config.PromptConfig {
        if (self.prompt_config) |pcfg| return &pcfg.prompt;
        return null;
    }

    /// `prompt.dur_min_ms` if set, else the built-in default.
    fn durMinMs(self: *Prompt) u64 {
        if (self.promptCfg()) |p| if (p.dur_min_ms) |m| return m;
        return 2000;
    }

    /// Scrolloff for scrollback browsing (see `default_scrolloff`):
    /// `prompt.scrolloff` if set, else the default, clamped by
    /// `browsescroll.clampScrolloff` so the cursor still has room to move
    /// between the prompt row and the top margin.
    fn scrolloffRows(self: *Prompt) usize {
        const want: usize = if (self.promptCfg()) |p|
            (if (p.scrolloff) |s| @as(usize, s) else default_scrolloff)
        else
            default_scrolloff;
        return browsescroll.clampScrolloff(want, self.line_start_row);
    }

    /// Fills `host`/`host_buf` from `$HOSTNAME` or `/etc/hostname`. Best
    /// effort: leaves `host` empty (so `{host}` renders nothing) on any
    /// failure. Called once at startup.
    fn resolveHostname(self: *Prompt) void {
        if (self.environ_map.get("HOSTNAME")) |h| {
            if (h.len > 0 and h.len <= self.host_buf.len) {
                @memcpy(self.host_buf[0..h.len], h);
                self.host = self.host_buf[0..h.len];
                return;
            }
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.client.io, "/etc/hostname", self.client.alloc, .limited(256)) catch return;
        defer self.client.alloc.free(bytes);
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > self.host_buf.len) return;
        @memcpy(self.host_buf[0..trimmed.len], trimmed);
        self.host = self.host_buf[0..trimmed.len];
    }

    /// The bundled prompt icons (`assets/icons/...`) are 32x32.
    const icon_native_px: u32 = 32;

    /// Works out how a `{icon:...}` should be drawn from the session's cell
    /// pixel size (`get_cell_metrics`): natural-scaled, capped to one
    /// cell-height so it fills the row without spilling onto the row above
    /// or below, and how many columns that makes it (`ceil(h / w)`, ~2 for
    /// a square icon in a roughly 1:2 cell). Leaves the fit-in-one-cell
    /// default if the metrics request fails.
    fn resolveIconMetrics(self: *Prompt) void {
        const m = self.client.getCellMetrics() catch return;
        if (m.w == 0 or m.h == 0) return;
        self.icon_max_h = m.h;
        const render_px = @min(icon_native_px, m.h);
        self.icon_cols = @max(1, (render_px + m.w - 1) / m.w);
    }

    /// Writes the prompt prefix at the cursor's current position and
    /// returns where the input line begins, for the caller to record as
    /// `line_start_row`/`_col`. Everything is read fresh each time (cwd,
    /// exit status, time, ...) so a `cd` or a failed command shows on the
    /// very next prompt.
    ///
    /// Three shapes, by `shell.conf`:
    ///   - nothing configured -> `writeDefaultPrefix` (`<cwd> > `)
    ///   - `prompt.left` / `prompt.right` strings -> `writeTemplatedPrefix`
    ///   - `prompt.left_segments` / `right_segments` -> `writePowerlinePrefix`
    ///
    /// Also (re)sets the input-box bounds: `input_max_col` (right edge the
    /// typed text may not cross), `input_scroll`, `right_dynamic`,
    /// `prompt_lines`.
    fn writePromptPrefix(self: *Prompt) !glyphwire.Cursor {
        self.input_max_col = self.grid_cols;
        self.input_scroll = 0;
        self.right_dynamic = false;
        self.prompt_lines = 1;

        // A brand-new prompt: re-run the `commands` vars. Everything drawn
        // for *this* prompt after here (the idle right-chain refresh, a
        // multi-line redraw) reuses whatever they resolve to now.
        self.resetCmdVars();

        const p = self.promptCfg() orelse return self.writeDefaultPrefix();
        if (p.left_segments != null or p.right_segments != null) return self.writePowerlinePrefix(p);
        if (p.left != null or p.right != null) return self.writeTemplatedPrefix(p);
        return self.writeDefaultPrefix();
    }

    /// The built-in prompt: the absolute working directory followed by
    /// `" > "`. Unchanged from before prompt templating existed.
    fn writeDefaultPrefix(self: *Prompt) !glyphwire.Cursor {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(self.client.io, &cwd_buf) catch 0;

        var prefix_buf: [std.fs.max_path_bytes + 4]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s} > ", .{cwd_buf[0..cwd_len]}) catch "> ";

        try self.client.writeText(prefix, null, null);
        return try self.client.getCursor();
    }

    /// Stack buffers backing a `prompt_template.Data` snapshot -- the
    /// caller holds one of these for the lifetime of the `Data`.
    const PromptDataBufs = struct {
        cwd: [std.fs.max_path_bytes]u8 = undefined,
        tilde: [std.fs.max_path_bytes]u8 = undefined,
        time: [64]u8 = undefined,
    };

    /// Fills a `prompt_template.Data` from the shell's live state, using
    /// `b` for the strings that need somewhere to live.
    fn buildPromptData(self: *Prompt, b: *PromptDataBufs, p: *const config.PromptConfig) prompt_template.Data {
        const cwd_full = b.cwd[0 .. std.process.currentPath(self.client.io, &b.cwd) catch 0];
        return .{
            .cwd = self.collapseHome(cwd_full, &b.tilde),
            .cwd_full = cwd_full,
            .user = self.environ_map.get("USER") orelse "",
            .host = self.host,
            .time = self.formatTime(&b.time, p.time_format orelse "%H:%M"),
            .environ = &self.env,
            .last_status = self.last_status,
            .have_status = self.have_status,
            .last_dur_ms = self.last_dur_ms,
            .dur_min_ms = self.durMinMs(),
            .exit_section = p.exit,
            .dur_section = p.dur,
            .vars = self.cmdVarResolver(),
        };
    }

    /// The `prompt_template.VarResolver` for this prompt's `commands`
    /// vars, or `null` when none are configured (so an unknown `{token}`
    /// keeps its literal-passthrough behaviour). The `ctx` is the
    /// `*Prompt`; `resolveCmdVarThunk` casts it back.
    fn cmdVarResolver(self: *Prompt) ?prompt_template.VarResolver {
        const p = self.promptCfg() orelse return null;
        if (p.command_vars == null) return null;
        return .{ .ctx = self, .resolve = resolveCmdVarThunk };
    }

    fn resolveCmdVarThunk(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *Prompt = @ptrCast(@alignCast(ctx));
        return self.resolveCmdVar(name);
    }

    /// Resolves a `{name}` token against `prompt{ commands = { ... } }`.
    /// Returns `null` when `name` isn't a declared command var (the
    /// template then leaves the token verbatim); otherwise the command's
    /// trimmed stdout, or `""` when it was gated off by its `when`,
    /// failed, timed out, or hit the cycle/depth guard. Memoised in
    /// `cmd_var_cache` for the life of the current prompt.
    fn resolveCmdVar(self: *Prompt, name: []const u8) ?[]const u8 {
        const p = self.promptCfg() orelse return null;
        const vars = p.command_vars orelse return null;

        const cv: *const config.CommandVar = blk: {
            for (vars) |*entry| {
                if (std.mem.eql(u8, entry.name, name)) break :blk entry;
            }
            return null;
        };

        if (self.cmd_var_cache.get(name)) |cached| return cached;

        // Cycle / runaway-depth guard: a `when` that (transitively)
        // references its own var resolves to empty rather than looping.
        if (self.cmd_var_depth >= self.cmd_var_stack.len) return "";
        for (self.cmd_var_stack[0..self.cmd_var_depth]) |n| {
            if (std.mem.eql(u8, n, name)) return "";
        }
        self.cmd_var_stack[self.cmd_var_depth] = name;
        self.cmd_var_depth += 1;
        defer self.cmd_var_depth -= 1;

        // `runCmdVar` hands back a `client.alloc`-owned slice (or a static
        // "" on failure / empty output); the cache takes it as-is and
        // `resetCmdVars` frees it. The gated-off path stores the same
        // static "".
        const gated_off = if (cv.when) |w| !self.cmdWhenTrue(w) else false;
        const owned: []const u8 = if (gated_off) "" else self.runCmdVar(cv);

        self.cmd_var_cache.put(self.client.alloc, name, owned) catch {};
        return owned;
    }

    /// Runs `cv.run` through `/bin/sh -c`, synchronously, and returns its
    /// trimmed stdout as a fresh `client.alloc` slice -- or `""` on a
    /// spawn failure, an exit with no output, or the timeout firing (the
    /// child is killed). Exit status is otherwise ignored: `{name}` *is*
    /// the command's output, and a `when` clause treats a non-empty
    /// output as true.
    fn runCmdVar(self: *Prompt, cv: *const config.CommandVar) []const u8 {
        const gpa = self.client.alloc;
        const timeout_ms: i64 = @intCast(cv.timeout_ms orelse default_cmd_var_timeout_ms);

        const argv = [_][]const u8{ "/bin/sh", "-c", cv.run };
        const res = std.process.run(gpa, self.client.io, .{
            .argv = &argv,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(4 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
        }) catch return "";
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (trimmed.len == 0) return "";
        return gpa.dupe(u8, trimmed) catch "";
    }

    /// Evaluates a `when` template expression (a segment's `when_expr` or
    /// a command var's own `when`) against the command vars: renders it,
    /// trims, and reports whether the result is "truthy" -- non-empty and
    /// not `0` / `false`. A leading `!` (repeatable) negates. A render
    /// failure counts as falsy (before negation).
    fn cmdWhenTrue(self: *Prompt, expr_in: []const u8) bool {
        var expr = std.mem.trim(u8, expr_in, " \t");
        var negate = false;
        while (expr.len > 0 and expr[0] == '!') {
            negate = !negate;
            expr = std.mem.trim(u8, expr[1..], " \t");
        }

        var arena_state = std.heap.ArenaAllocator.init(self.client.alloc);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const data = prompt_template.Data{
            .environ = &self.env,
            .vars = self.cmdVarResolver(),
        };
        const ops = prompt_template.renderOps(a, expr, data) catch return negate;

        var buf: std.ArrayList(u8) = .empty;
        for (ops) |op| switch (op) {
            .text => |t| buf.appendSlice(a, t) catch return negate,
            .icon => {},
        };
        return prompt_template.whenTruthy(buf.items) != negate;
    }

    /// Local time formatted per `fmt` (a `strftime` string), into `buf`.
    /// Uses libc directly (this reduced std has no time-formatting) and
    /// returns "" on any failure.
    fn formatTime(_: *Prompt, buf: []u8, fmt: []const u8) []const u8 {
        var fmtz: [96]u8 = undefined;
        if (fmt.len == 0 or fmt.len >= fmtz.len) return "";
        @memcpy(fmtz[0..fmt.len], fmt);
        fmtz[fmt.len] = 0;

        const t: c_long = timelib.time(null);
        var tm: timelib.Tm = undefined;
        if (timelib.localtime_r(&t, &tm) == null) return "";
        const n = timelib.strftime(buf.ptr, buf.len, @ptrCast(&fmtz), &tm);
        return buf[0..n];
    }

    /// Renders the configured `prompt.left` / `prompt.right` template
    /// strings (see `shell/prompt_template.zig`). `prompt.right` is drawn
    /// right-aligned on the prompt row (a long input line overwrites it --
    /// accepted, like starship's transient right prompt); `prompt.left`
    /// from column 0. Returns where input begins.
    fn writeTemplatedPrefix(self: *Prompt, p: *const config.PromptConfig) !glyphwire.Cursor {
        const alloc = self.client.alloc;

        var bufs: PromptDataBufs = .{};
        const data = self.buildPromptData(&bufs, p);

        const start = try self.client.getCursor();

        if (p.right) |rt| {
            var r = try prompt_template.render(alloc, rt, data);
            defer r.deinit();
            const w = prompt_template.opsWidth(r.ops, self.icon_cols);
            if (w > 0 and w < self.grid_cols) {
                try self.client.setCursor(start.row, self.grid_cols - w);
                try self.emitOps(null, r.ops, start.row, self.grid_cols - w, .{});
            }
            try self.client.setCursor(start.row, 0);
        }

        var l = try prompt_template.render(alloc, p.left orelse default_prompt_left, data);
        defer l.deinit();
        try self.emitOps(null, l.ops, start.row, 0, .{});

        return try self.client.getCursor();
    }

    const RenderedSeg = struct {
        ops: []const prompt_template.Op,
        width: usize,
        fg: ?glyphwire.Color,
        bg: ?glyphwire.Color,
    };

    /// Renders each *visible* segment of `segs` (dropping `when`-filtered
    /// and empty ones) into `out` (allocated in `arena`), returns the
    /// summed on-screen width of the segments themselves (separators and
    /// caps not included -- see `chainWidth`).
    fn renderChain(
        self: *Prompt,
        arena: std.mem.Allocator,
        segs: []const config.PromptSegment,
        data: prompt_template.Data,
        out: *std.ArrayList(RenderedSeg),
    ) !usize {
        var total: usize = 0;
        for (segs) |seg| {
            switch (seg.when) {
                .always => {},
                .err => if (!(data.have_status and data.last_status != 0)) continue,
                .slow => if (!(data.dur_min_ms > 0 and data.last_dur_ms >= data.dur_min_ms)) continue,
            }
            // A `when = "{var}"` expression form -- shown only when the
            // expression renders truthy against the command vars.
            if (seg.when_expr) |we| {
                if (!self.cmdWhenTrue(we)) continue;
            }
            const ops = try prompt_template.renderOps(arena, seg.text, data);
            const w = prompt_template.opsWidth(ops, self.icon_cols);
            if (w == 0) continue;
            try out.append(arena, .{
                .ops = ops,
                .width = w,
                .fg = plColor(seg.fg),
                .bg = plColor(seg.bg),
            });
            total += w;
        }
        return total;
    }

    /// Total on-screen width of a rendered chain: segment widths (`seg_sum`)
    /// plus `count - 1` separators plus the caps that are non-empty.
    fn chainWidth(count: usize, seg_sum: usize, sep: []const u8, head: []const u8, tail: []const u8) usize {
        if (count == 0) return 0;
        var w = seg_sum + prompt_template.displayWidth(sep) * (count - 1);
        if (head.len > 0) w += prompt_template.displayWidth(head);
        if (tail.len > 0) w += prompt_template.displayWidth(tail);
        return w;
    }

    /// Draw target for the powerline chain helpers: either straight to the
    /// client (`null`) or accumulated into one `batch` frame. `drawRightChain`
    /// batches so the periodic redraw of the right chain plus the trailing
    /// caret restore land in a single render -- no visible caret blip out
    /// to the right side and back.
    const ChainSink = ?*glyphwire.Client.Batch;

    fn sinkSetCursor(self: *Prompt, sink: ChainSink, row: usize, col: usize) !void {
        if (sink) |b| try b.setCursor(row, col) else try self.client.setCursor(row, col);
    }
    fn sinkWriteText(self: *Prompt, sink: ChainSink, text: []const u8, fg: ?glyphwire.Color, bg: ?glyphwire.Color) !void {
        if (sink) |b| try b.writeText(text, fg, bg) else try self.client.writeText(text, fg, bg);
    }
    fn sinkWriteTextTransparent(self: *Prompt, sink: ChainSink, text: []const u8, fg: ?glyphwire.Color) !void {
        if (sink) |b| try b.writeTextTransparent(text, fg) else try self.client.writeTextTransparent(text, fg);
    }
    fn sinkDrawIconStyled(self: *Prompt, sink: ChainSink, row: usize, col: usize, name: []const u8, opts: glyphwire.Client.DrawIconOpts) !void {
        if (sink) |b| try b.drawIconStyled(row, col, name, opts) else try self.client.drawIconStyled(row, col, name, opts);
    }

    /// Draws a rendered chain left to right starting at `(row, start_col)`:
    /// optional `head` cap, then each segment (a background strip, then its
    /// text/icons composited over it), with `sep` between adjacent
    /// segments, then optional `tail` cap. A separator is drawn in the two
    /// neighbours' backgrounds -- for `right_side` chains the fg/bg are
    /// swapped so a left-pointing glyph reads correctly. `sink` routes
    /// every draw either straight to the client or into a `batch`.
    fn drawChain(
        self: *Prompt,
        row: usize,
        start_col: usize,
        segs: []const RenderedSeg,
        sep: []const u8,
        head: []const u8,
        tail: []const u8,
        right_side: bool,
        sink: ChainSink,
    ) !void {
        if (segs.len == 0) return;
        var col = start_col;

        if (head.len > 0) {
            try self.sinkSetCursor(sink, row, col);
            try self.sinkWriteText(sink, head, segs[0].bg, null);
            col += prompt_template.displayWidth(head);
        }

        for (segs, 0..) |seg, i| {
            if (i > 0 and sep.len > 0) {
                const prev = segs[i - 1];
                try self.sinkSetCursor(sink, row, col);
                if (right_side) {
                    try self.sinkWriteText(sink, sep, seg.bg, prev.bg);
                } else {
                    try self.sinkWriteText(sink, sep, prev.bg, seg.bg);
                }
                col += prompt_template.displayWidth(sep);
            }
            // Background strip, then text/icons composited over it.
            try self.sinkSetCursor(sink, row, col);
            try self.writeSpaces(sink, seg.width, seg.fg, seg.bg);
            try self.emitOps(sink, seg.ops, row, col, .{ .fg = seg.fg, .transparent = true });
            col += seg.width;
        }

        if (tail.len > 0) {
            try self.sinkSetCursor(sink, row, col);
            try self.sinkWriteText(sink, tail, segs[segs.len - 1].bg, null);
        }
    }

    /// Re-renders and redraws the `right_segments` chain at its pinned
    /// position -- called on the idle timeout so `{time}` ticks, and (on a
    /// single-line prompt) after every keystroke so it stays put while the
    /// input line is repainted. A no-op when no right chain is configured.
    ///
    /// The whole redraw plus a trailing "put the caret back on the input
    /// line" go out as one `batch` frame, so the host never renders a
    /// frame with the caret stranded out on the right where the chain is
    /// drawn -- the "cursor blip to the right" this used to cause.
    fn drawRightChain(self: *Prompt) !void {
        const p = self.promptCfg() orelse return;
        const segs = p.right_segments orelse return;

        var arena_state = std.heap.ArenaAllocator.init(self.client.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bufs: PromptDataBufs = .{};
        const data = self.buildPromptData(&bufs, p);

        var list: std.ArrayList(RenderedSeg) = .empty;
        const seg_sum = try self.renderChain(arena, segs, data, &list);
        if (list.items.len == 0) return;

        const sep_right = p.sep_right orelse (p.sep orelse "");
        // `right_head` caps the left edge of the right-aligned chain (the
        // side facing the input). Unset, it falls back to `head` -- the
        // same left-cap glyph the left chain uses -- mirroring how
        // `sep_right` falls back to `sep`. `drawChain` draws it in the
        // first visible segment's bg (red on an error segment, the time's
        // bg otherwise).
        const right_head = p.right_head orelse (p.head orelse "");
        const w = chainWidth(list.items.len, seg_sum, sep_right, right_head, "");
        if (w >= self.grid_cols) return;
        const row = if (self.grid_rows > 0) @min(self.pl_top_row, self.grid_rows - 1) else self.pl_top_row;

        var b = self.client.batch();
        defer b.deinit();
        try self.drawChain(row, self.grid_cols - w, list.items, sep_right, right_head, "", true, &b);
        // Caret restore, same frame -- mirrors `placeInputCursor`. Always
        // the input line: the idle-tick caller gates on `browse_pos == null`
        // and `renderInputLine` only runs for the live line.
        const caret_row = if (self.grid_rows > 0) @min(self.line_start_row, self.grid_rows - 1) else self.line_start_row;
        try b.setCursor(caret_row, self.line_start_col + self.caretCol());
        var res = try b.send();
        res.deinit();
    }

    /// The powerline prompt: `left_segments` from column 0, `right_segments`
    /// right-aligned, on `prompt_lines`-1 rows above the input line (or all
    /// on one row when `prompt_lines == 1`). Returns where input begins.
    fn writePowerlinePrefix(self: *Prompt, p: *const config.PromptConfig) !glyphwire.Cursor {
        var arena_state = std.heap.ArenaAllocator.init(self.client.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bufs: PromptDataBufs = .{};
        const data = self.buildPromptData(&bufs, p);

        self.prompt_lines = p.lines orelse 1;

        // The prompt needs `prompt_lines` consecutive rows. If the cursor
        // (left where the last command's output ended) is close enough to
        // the bottom that they wouldn't fit, scroll the layer up-front by
        // writing that many newlines at the bottom row -- so every draw
        // below works with an on-grid `top` and the recorded
        // `line_start_row` can't end up one past the last row (which made
        // every later `renderInputLine` / idle refresh scroll again).
        const start = try self.client.getCursor();
        var top = start.row;
        if (self.grid_rows > 0 and top + self.prompt_lines > self.grid_rows) {
            const overshoot = top + self.prompt_lines - self.grid_rows;
            try self.client.setCursor(self.grid_rows - 1, 0);
            var k: usize = 0;
            while (k < overshoot) : (k += 1) try self.client.writeText("\n", null, null);
            top -= overshoot;
        }
        self.pl_top_row = top;

        const sep = p.sep orelse "";
        const sep_right = p.sep_right orelse sep;
        const head = p.head orelse "";
        const tail = p.tail orelse "";
        // See `drawRightChain`: unset, the right chain's left cap reuses
        // `head`, the same fallback shape as `sep_right` -> `sep`.
        const right_head = p.right_head orelse head;

        var left_end: usize = 0;
        if (p.left_segments) |segs| {
            var list: std.ArrayList(RenderedSeg) = .empty;
            const seg_sum = try self.renderChain(arena, segs, data, &list);
            try self.drawChain(top, 0, list.items, sep, head, tail, false, null);
            left_end = @min(chainWidth(list.items.len, seg_sum, sep, head, tail), self.grid_cols);
        }

        var right_w: usize = 0;
        if (p.right_segments) |segs| {
            var list: std.ArrayList(RenderedSeg) = .empty;
            const seg_sum = try self.renderChain(arena, segs, data, &list);
            right_w = chainWidth(list.items.len, seg_sum, sep_right, right_head, "");
            if (list.items.len > 0 and right_w < self.grid_cols) {
                self.right_dynamic = true;
                try self.drawChain(top, self.grid_cols - right_w, list.items, sep_right, right_head, "", true, null);
            }
        }

        const input_prefix = p.input orelse "> ";
        if (self.prompt_lines >= 2) {
            // `top + prompt_lines <= grid_rows` now, so this row is on-grid.
            const irow = top + self.prompt_lines - 1;
            try self.client.setCursor(irow, 0);
            if (input_prefix.len > 0) try self.client.writeText(input_prefix, null, null);
            self.line_start_row = irow;
            self.line_start_col = prompt_template.displayWidth(input_prefix);
            self.input_max_col = self.grid_cols;
        } else {
            var col = left_end;
            try self.client.setCursor(top, col);
            if (input_prefix.len > 0) {
                try self.client.writeText(input_prefix, null, null);
                col += prompt_template.displayWidth(input_prefix);
            }
            self.line_start_row = top;
            self.line_start_col = col;
            self.input_max_col = if (self.right_dynamic and right_w + 1 < self.grid_cols)
                self.grid_cols - right_w - 1
            else
                self.grid_cols;
            if (self.input_max_col <= self.line_start_col) self.input_max_col = self.grid_cols;
        }
        self.input_scroll = 0;
        return .{ .row = self.line_start_row, .col = self.line_start_col };
    }

    /// Writes `n` spaces at the cursor with the given fg/bg -- the
    /// background strip a powerline segment's text then composites over.
    fn writeSpaces(self: *Prompt, sink: ChainSink, n: usize, fg: ?glyphwire.Color, bg: ?glyphwire.Color) !void {
        var buf: [256]u8 = undefined;
        var left = n;
        while (left > 0) {
            const chunk = @min(left, buf.len);
            @memset(buf[0..chunk], ' ');
            try self.sinkWriteText(sink, buf[0..chunk], fg, bg);
            left -= chunk;
        }
    }

    const EmitOpts = struct { fg: ?glyphwire.Color = null, transparent: bool = false };

    /// Walks a rendered template's ops, starting at `(row, col)`. Text runs
    /// go through `write_text` (or `write_text` transparent, keeping any
    /// background strip) with `opts.fg`; icons through `draw_icon` at the
    /// running cell (which `draw_icon` doesn't advance, so the column is
    /// bumped by hand).
    ///
    /// Straight-to-client (`sink == null`), text runs resync the cursor
    /// from `getCursor` so an embedded `\n` (server CR+LF) needs no local
    /// bookkeeping. Batched (`sink != null`), there's no round trip:
    /// segment text has no `\n`, so the column is advanced by its display
    /// width instead.
    ///
    /// The explicit `setCursor` up front matters: `drawChain` calls this
    /// right after `writeSpaces` has left the cursor at the *end* of the
    /// segment's background strip, not its start.
    fn emitOps(self: *Prompt, sink: ChainSink, ops: []const prompt_template.Op, row: usize, col: usize, opts: EmitOpts) !void {
        try self.sinkSetCursor(sink, row, col);
        var cur_row = row;
        var cur_col = col;
        for (ops) |op| switch (op) {
            .text => |t| {
                if (opts.transparent) {
                    try self.sinkWriteTextTransparent(sink, t, opts.fg);
                } else {
                    try self.sinkWriteText(sink, t, opts.fg, null);
                }
                if (sink == null) {
                    const cur = try self.client.getCursor();
                    cur_row = cur.row;
                    cur_col = cur.col;
                } else {
                    cur_col += prompt_template.displayWidth(t);
                    try self.sinkSetCursor(sink, cur_row, cur_col);
                }
            },
            .icon => |name| {
                // A `draw_icon` notification for an unregistered name is
                // logged and dropped server-side, not returned as an error.
                // With cell metrics: draw it at its natural size, capped to
                // one cell-height (fills the row, no vertical spill), and
                // step past the `icon_cols` cells it covers. Without them:
                // the old aspect-fit-in-one-cell behavior.
                if (self.icon_max_h > 0) {
                    try self.sinkDrawIconStyled(sink, cur_row, cur_col, name, .{
                        .scale = .natural,
                        .h_align = .start,
                        .v_align = .center,
                        .max_h = self.icon_max_h,
                        .foreground = opts.transparent,
                    });
                    cur_col += self.icon_cols;
                } else {
                    try self.sinkDrawIconStyled(sink, cur_row, cur_col, name, .{ .foreground = opts.transparent });
                    cur_col += 1;
                }
                try self.sinkSetCursor(sink, cur_row, cur_col);
            },
        };
    }

    /// Returns `path` with a leading `$HOME` replaced by `~` (`~` alone
    /// for exactly `$HOME`), written into `buf`. Falls back to `path`
    /// unchanged when there's no `$HOME`, it isn't a prefix, or `buf` is
    /// too small.
    fn collapseHome(self: *Prompt, path: []const u8, buf: []u8) []const u8 {
        const home = self.environ_map.get("HOME") orelse return path;
        if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
        if (path.len == home.len) return "~";
        if (path[home.len] != '/') return path; // `/home/foobar` isn't under `/home/foo`
        const rest = path[home.len..];
        if (rest.len + 1 > buf.len) return path;
        buf[0] = '~';
        @memcpy(buf[1 .. rest.len + 1], rest);
        return buf[0 .. rest.len + 1];
    }

    /// The caret's column offset from `line_start_col` -- the display
    /// width of `buffer` between `input_scroll` and `cursor` (both byte
    /// offsets on codepoint boundaries). Byte count and column count only
    /// coincide for ASCII; a CJK char is one codepoint, two columns.
    fn caretCol(self: *Prompt) usize {
        const buf = self.buffer.items;
        const from = @min(self.input_scroll, buf.len);
        const to = @min(self.cursor, buf.len);
        if (to <= from) return 0;
        return lineedit.displayCol(buf[from..], to - from);
    }

    /// Repaints the whole input box -- `[line_start_col, input_max_col)` on
    /// `line_start_row` -- from `buffer`, scrolling horizontally
    /// (`input_scroll`, a byte offset kept on a codepoint boundary) so the
    /// caret stays visible, then places the server cursor. Replaces the
    /// old per-edit `insert_cells` / `delete_cells` dance: every editing
    /// op mutates `buffer`/`cursor` locally and calls this. All width math
    /// is in display columns (`lineedit`), so a CJK line lays out right.
    /// On a single-line powerline prompt it also redraws the pinned right
    /// chain so typing can't disturb it.
    fn renderInputLine(self: *Prompt) !void {
        const buf = self.buffer.items;
        // Clamp to the last real row: a stale `line_start_row` past the
        // grid bottom (see `writePowerlinePrefix`) would otherwise make
        // every `setCursor` below scroll the layer.
        const row = if (self.grid_rows > 0) @min(self.line_start_row, self.grid_rows - 1) else self.line_start_row;
        const left = self.line_start_col;
        const right = if (self.input_max_col > left + 1) self.input_max_col else self.grid_cols;
        const box_w = right -| left;
        if (box_w == 0) {
            try self.client.setCursor(row, @min(left, self.grid_cols -| 1));
            return;
        }

        // Keep the caret within the box, working in columns not bytes.
        if (self.cursor < self.input_scroll) {
            self.input_scroll = self.cursor;
        } else {
            while (self.input_scroll < self.cursor and
                lineedit.displayCol(buf[self.input_scroll..], self.cursor - self.input_scroll) >= box_w)
            {
                self.input_scroll = lineedit.nextBoundary(buf, self.input_scroll);
            }
        }
        if (lineedit.cellWidth(buf) <= box_w) self.input_scroll = 0;

        // Visible slice: whole codepoints from `input_scroll` while they fit.
        const vis_start = @min(self.input_scroll, buf.len);
        var vis_end = vis_start;
        var w: usize = 0;
        while (vis_end < buf.len) {
            const nb = lineedit.nextBoundary(buf, vis_end);
            const cw = lineedit.cellWidth(buf[vis_end..nb]);
            if (w + cw > box_w) break;
            w += cw;
            vis_end = nb;
        }
        const visible = buf[vis_start..vis_end];

        var line_buf: [1024]u8 = undefined;
        if (visible.len >= line_buf.len) return; // absurdly long; bail
        @memcpy(line_buf[0..visible.len], visible);
        const total = @min(visible.len + (box_w - w), line_buf.len);
        @memset(line_buf[visible.len..total], ' ');

        try self.client.setCursor(row, left);
        try self.client.writeText(line_buf[0..total], null, null);

        if (self.right_dynamic and self.prompt_lines == 1) self.drawRightChain() catch {};

        try self.placeInputCursor();
    }

    /// Puts the server cursor at the caret's screen cell -- `line_start_col`
    /// plus `caretCol()` (the display-width offset of `cursor` from
    /// `input_scroll`), on the input row clamped to the grid. Used by
    /// `renderInputLine` and the idle right-chain refresh (which moves the
    /// cursor while redrawing).
    fn placeInputCursor(self: *Prompt) !void {
        const row = if (self.grid_rows > 0) @min(self.line_start_row, self.grid_rows - 1) else self.line_start_row;
        try self.client.setCursor(row, self.line_start_col + self.caretCol());
    }

    /// A fresh prompt: writes the prefix, resets the line, repaints the
    /// (empty) input box. Used to start a brand new input line (after
    /// `submitLine` or at startup); see `clearScreen` for ctrl+l, which
    /// keeps whatever's already typed.
    fn showPrompt(self: *Prompt) !void {
        const cur = try self.writePromptPrefix();
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;
        self.cursor = 0;
        self.buffer.clearRetainingCapacity();
        try self.renderInputLine();
    }

    /// Records a resize event without redrawing -- the re-layout waits for
    /// the size to settle (`resize_settle_ms`), since a resize drag emits
    /// one event per frame and redrawing on each looks messy. Coalesces a
    /// burst: keeps only the latest size, each event pushes the deadline.
    fn noteResize(self: *Prompt, cols: usize, rows: usize) void {
        self.pending_resize = .{ .cols = cols, .rows = rows };
        self.resize_seen_at = std.Io.Clock.Timestamp.now(self.client.io, .awake);
    }

    /// Applies a pending resize once it's been quiet for `resize_settle_ms`
    /// -- or immediately when `force` (the user pressed a key, so the drag
    /// is over and the keystroke should land on a correct layout).
    fn applyPendingResize(self: *Prompt, force: bool) !void {
        const rev = self.pending_resize orelse return;
        if (!force) {
            const quiet = self.resize_seen_at.?.untilNow(self.client.io).raw.toMilliseconds();
            if (quiet < resize_settle_ms) return;
        }
        self.pending_resize = null;
        self.resize_seen_at = null;
        try self.handleResize(rev.cols, rev.rows);
    }

    /// Re-lays-out the prompt after a window resize (see `noteResize` /
    /// `applyPendingResize`). The grid was rebuilt bottom-anchored, so the
    /// previously-drawn prompt cells moved by the height change, and
    /// `grid_cols`/`grid_rows` -- hence the right chain's column, the
    /// input-box bounds and every row clamp -- are stale. Shift the
    /// recorded prompt top by the same height delta, then redraw the
    /// prefix from there (`writePowerlinePrefix` scrolls up-front if it
    /// now overflows the bottom) and repaint the input box with whatever's
    /// typed. Keeps `buffer`/`cursor`; ends any in-progress browse (the
    /// old viewport rows it referred to are gone).
    fn handleResize(self: *Prompt, cols: usize, rows: usize) !void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.grid_cols and rows == self.grid_rows) return;

        const old_rows = self.grid_rows;
        self.grid_cols = cols;
        self.grid_rows = rows;

        self.browse_pos = null;
        if (self.view_scroll != 0) {
            const res = try self.client.scrollView(0, null);
            self.view_scroll = res.offset;
        }

        // The prompt's current top row: input row minus the segment rows
        // above it (0 for a single-line prompt).
        const cur_top = self.line_start_row -| (self.prompt_lines -| 1);
        const delta: isize = @as(isize, @intCast(rows)) - @as(isize, @intCast(old_rows));
        const shifted: isize = @as(isize, @intCast(cur_top)) + delta;
        const top: usize = if (shifted < 0) 0 else @min(@as(usize, @intCast(shifted)), rows -| 1);

        try self.client.setCursor(top, 0);
        const start = try self.writePromptPrefix();
        self.line_start_row = start.row;
        self.line_start_col = start.col;
        self.input_scroll = 0;
        try self.renderInputLine();
    }

    /// ctrl+l: clears the screen, redraws the whole prompt (all segment
    /// rows included) at the top, then repaints the input box with
    /// whatever's already typed. Unlike `showPrompt`, doesn't touch
    /// `buffer`/`cursor`.
    fn clearScreen(self: *Prompt) !void {
        try self.client.clear(0, 0, null, null);
        try self.client.setCursor(0, 0);

        const cur = try self.writePromptPrefix();
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;
        self.input_scroll = 0;
        try self.renderInputLine();
    }

    /// Replaces the whole line -- `buffer` and on screen -- with `text`,
    /// cursor at its end. Shared by `historyUp`/`historyDown`. With the
    /// repaint model this is just a buffer swap plus `renderInputLine`.
    fn setLine(self: *Prompt, text: []const u8) !void {
        self.browse_pos = null;
        if (self.view_scroll != 0) {
            const res = try self.client.scrollView(0, null);
            self.view_scroll = res.offset;
        }
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.client.alloc, text);
        self.cursor = self.buffer.items.len;
        self.input_scroll = 0;
        try self.renderInputLine();
    }

    /// ctrl+up: recalls the previous (older) history entry, most recent
    /// first. The first press of a recall stashes the in-progress line in
    /// `scratch` so `historyDown` can get back to it later; further presses
    /// just walk `history_index` back, stopping at the oldest entry rather
    /// than wrapping.
    fn historyUp(self: *Prompt) !void {
        if (self.history.items.len == 0) return;

        if (self.history_index) |i| {
            if (i == 0) return;
            self.history_index = i - 1;
        } else {
            self.scratch.clearRetainingCapacity();
            try self.scratch.appendSlice(self.client.alloc, self.buffer.items);
            self.history_index = self.history.items.len - 1;
        }
        try self.setLine(self.history.items[self.history_index.?]);
    }

    /// ctrl+down: the mirror of `historyUp`. Walking past the newest entry
    /// restores whatever `historyUp` stashed in `scratch` and clears
    /// `history_index` back to `null` -- "the current scratch one" the line
    /// was on before recall started. A no-op when not currently recalling
    /// (`history_index == null`): there's nothing further "down" than the
    /// line already on screen.
    fn historyDown(self: *Prompt) !void {
        const i = self.history_index orelse return;
        if (i + 1 < self.history.items.len) {
            self.history_index = i + 1;
            try self.setLine(self.history.items[self.history_index.?]);
        } else {
            self.history_index = null;
            try self.setLine(self.scratch.items);
        }
    }

    /// Deletes the codepoint before the cursor (backspace). `buffer` /
    /// `cursor` are mutated locally; `setCursorAt` -> `renderInputLine`
    /// repaints the box (no `delete_cells` in the repaint model).
    fn deleteBackward(self: *Prompt) !void {
        if (self.cursor == 0) return;
        const start = lineedit.prevBoundary(self.buffer.items, self.cursor);
        try self.buffer.replaceRange(self.client.alloc, start, self.cursor - start, &.{});
        self.cursor = start;
        try self.setCursorAt(self.cursor);
    }

    /// Deletes the codepoint at the cursor (forward delete).
    fn deleteForward(self: *Prompt) !void {
        if (self.cursor >= self.buffer.items.len) return;
        const end = lineedit.nextBoundary(self.buffer.items, self.cursor);
        try self.buffer.replaceRange(self.client.alloc, self.cursor, end - self.cursor, &.{});
        try self.setCursorAt(self.cursor);
    }

    /// ctrl+u: deletes from the start of the line through the cursor.
    fn killToStart(self: *Prompt) !void {
        if (self.cursor == 0) return;
        try self.buffer.replaceRange(self.client.alloc, 0, self.cursor, &.{});
        self.cursor = 0;
        try self.setCursorAt(0);
    }

    /// Moves the cursor without changing the buffer -- ctrl+a/ctrl+e,
    /// ctrl+arrow word jumps, and plain arrow movement all end here.
    fn moveCursorTo(self: *Prompt, offset: usize) !void {
        try self.setCursorAt(offset);
    }

    /// Moves the host's scrollback view (see `Prompt.view_scroll` /
    /// `Client.scrollView`) to absolute offset `offset` and records the
    /// clamped result (offset + max) the server hands back. This is the
    /// "scroll the window along" half of browsing: `browseUp`/`browseDown`
    /// compute the target with `browsescroll` and apply it here.
    fn scrollWindow(self: *Prompt, offset: usize) !void {
        const res = try self.client.scrollView(offset, null);
        self.view_scroll = res.offset;
        self.view_max = res.max;
    }

    /// Refreshes `view_scroll` / `view_max` from the host without moving
    /// the view -- a get-only `get_property("scroll")` query (no `scroll`
    /// broadcast). Called when entering browse so `browsescroll.up` starts
    /// from a current scrollback size.
    fn syncScrollState(self: *Prompt) !void {
        const res = try self.client.getScroll();
        self.view_scroll = res.offset;
        self.view_max = res.max;
    }

    /// Plain Up (`count == 1`) moves the cursor up into the scrollback
    /// above the prompt instead of editing anything -- entering "browse"
    /// mode (`browse_pos`) on the first press, starting directly above
    /// wherever the real cursor currently sits so it reads as "look
    /// straight up from here" rather than jumping to a fixed column.
    /// Ctrl+Up (`count == 5`, only while already browsing -- see the key
    /// loop) is a bigger step for scanning a long listing faster.
    ///
    /// The browse cursor keeps `scrolloffRows()` rows of context between
    /// itself and the top of the window: once it's that close to the top,
    /// further upward movement scrolls the host window back into
    /// scrollback (`scrollWindow`) instead, keeping the cursor at the
    /// margin -- until the scrollback is exhausted, when the cursor is
    /// allowed to climb the rest of the way to row 0. Entering browse at
    /// the very first prompt (`line_start_row == 0`) is fine -- an empty
    /// `scroll_view` clamps to a no-op.
    fn browseUp(self: *Prompt, count: usize) !void {
        const entering = self.browse_pos == null;
        if (entering) try self.syncScrollState();

        var bp = self.browse_pos orelse glyphwire.Cursor{
            .row = self.line_start_row -| 1,
            .col = self.line_start_col + self.caretCol(),
        };

        const plan = browsescroll.up(
            .{ .bp_row = bp.row, .view_scroll = self.view_scroll },
            count,
            self.scrolloffRows(),
            self.view_max,
            entering,
        );
        bp.row = plan.bp_row;
        if (plan.view_scroll != self.view_scroll) try self.scrollWindow(plan.view_scroll);
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    /// Plain Down (`count == 1`) while browsing moves the browse cursor
    /// down a row; Ctrl+Down (`count == 5`) is a bigger step. Symmetric
    /// with `browseUp`: the cursor keeps `scrolloffRows()` rows of context
    /// below itself by scrolling the window toward the live tail once it
    /// gets that close to the bottom, and only once the view is back at
    /// the tail does it move down onto the last browsable row (the one
    /// just above the prompt). Reaching the prompt row ends browsing and
    /// lands back on the real prompt cursor -- it can't be scrolled past.
    /// A no-op when not currently browsing.
    fn browseDown(self: *Prompt, count: usize) !void {
        var bp = self.browse_pos orelse return;
        const bottom = self.line_start_row -| 1; // last browsable row

        const plan = browsescroll.down(
            .{ .bp_row = bp.row, .view_scroll = self.view_scroll },
            count,
            self.scrolloffRows(),
            bottom,
        );
        if (plan.ended) {
            // Ran into the prompt row -- land back on the real cursor
            // (`setCursorAt` also snaps the view back to the live tail).
            try self.setCursorAt(self.cursor);
            return;
        }
        if (plan.view_scroll != self.view_scroll) try self.scrollWindow(plan.view_scroll);
        bp.row = plan.bp_row;
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    /// Left/Right while browsing: move within whatever row the browse
    /// cursor is currently on, clamped to the grid's width (`set_property`
    /// doesn't clamp `col` itself -- see `Layer.setProperty` -- so an
    /// unclamped move here could park the caret off-grid). No-ops when not
    /// browsing; the caller is expected to check `browse_pos` first and
    /// call `moveCursorTo` instead (plain line editing) when it's null.
    fn browseLeft(self: *Prompt) !void {
        var bp = self.browse_pos orelse return;
        bp.col -|= 1;
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    fn browseRight(self: *Prompt) !void {
        var bp = self.browse_pos orelse return;
        bp.col = @min(bp.col + 1, self.grid_cols -| 1);
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    /// Enter while browsing: looks up whatever cell the browse cursor is
    /// over and acts on it -- see `activateSelectionAt`'s doc comment for
    /// the actual logic, shared with `runPrompt`'s mouse-click handling.
    fn browseEnter(self: *Prompt) !void {
        const bp = self.browse_pos orelse return;
        try self.activateSelectionAt(bp.row, bp.col, self.view_scroll);
    }

    /// Looks up `(row, col)`'s metadata (`get_metadata`) and, depending on
    /// its `mimetype` (glyphwire-ls tags every entry it draws this way --
    /// see `iconForEntry`'s caller in ls/main.zig), runs a command as if
    /// it had been typed: `cd <path>` for `"directory"`, `glyphwire-view
    /// <path>` for any image type glyphwire-view can open
    /// (`core.ImageFormat.fromMimetype` -- PNG/JPEG/BMP/GIF, but not
    /// `image/svg+xml` or `image/webp`). The `<path>` is single-quoted
    /// (`wordsplit.quoteArg`) so a name with spaces or shell
    /// metacharacters survives `dispatchLine`'s re-split. `setLine` both
    /// echoes the command and, via `setCursorAt`, ends any in-progress
    /// browsing before `submitLine` runs it -- same path a real typed
    /// command takes, so e.g. `glyphwire-view`'s own "wait for a keypress
    /// before exiting" behavior (see view/main.zig) just works, blocking
    /// the prompt loop exactly like it would for a command the user typed
    /// themselves. A no-op for anything else (untagged, an unrecognized
    /// mimetype, empty space) per the "don't guess" policy: nothing should
    /// happen on a cell that isn't unambiguously actionable. Shared by
    /// `browseEnter` (Enter while browsing) and `runPrompt`'s left-click
    /// handling.
    ///
    /// `view_offset` is how many rows of scrollback the host was showing
    /// when `(row, col)` was picked (0 at the live tail) -- forwarded to
    /// `get_metadata` so a click/Enter on a scrolled-back row resolves
    /// against the cell actually there, not the live-buffer cell at the
    /// same screen position. `setLine` -> `setCursorAt` snaps the view
    /// back to the live tail before the command runs.
    fn activateSelectionAt(self: *Prompt, row: usize, col: usize, view_offset: usize) !void {
        const alloc = self.client.alloc;

        const lookup = self.client.getMetadata(null, row, col, view_offset) catch return;
        const json = lookup.json orelse return;
        defer alloc.free(json);

        const Meta = struct { mimetype: ?[]const u8 = null, path: ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(Meta, alloc, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const mimetype = parsed.value.mimetype orelse return;
        const path = parsed.value.path orelse return;

        // Single-quote the path so `dispatchLine` re-splits it back into
        // one token even with spaces / shell metacharacters in the name.
        const quoted = wordsplit.quoteArg(alloc, path) catch return;
        defer alloc.free(quoted);

        const line = if (std.mem.eql(u8, mimetype, "directory"))
            std.fmt.allocPrint(alloc, "cd {s}", .{quoted}) catch return
        else if (glyphwire.ImageFormat.fromMimetype(mimetype) != null)
            std.fmt.allocPrint(alloc, "glyphwire-view {s}", .{quoted}) catch return
        else
            return;
        defer alloc.free(line);

        try self.setLine(line);
        try self.submitLine();
    }

    /// The offset ctrl+right lands on: past any whitespace right of the
    /// cursor, then past the following run of non-whitespace.
    fn wordRight(self: *const Prompt) usize {
        const buf = self.buffer.items;
        var i = self.cursor;
        while (i < buf.len and buf[i] == ' ') : (i += 1) {}
        while (i < buf.len and buf[i] != ' ') : (i += 1) {}
        return i;
    }

    /// The offset ctrl+left lands on: back past any whitespace left of the
    /// cursor, then back past the preceding run of non-whitespace.
    fn wordLeft(self: *const Prompt) usize {
        const buf = self.buffer.items;
        var i = self.cursor;
        while (i > 0 and buf[i - 1] == ' ') : (i -= 1) {}
        while (i > 0 and buf[i - 1] != ' ') : (i -= 1) {}
        return i;
    }

    /// Clamps `self.cursor` to `offset` (a byte offset into `buffer`),
    /// ends any browse / scrollback view, and repaints the input line
    /// (`renderInputLine`) so the server cursor lands at the right screen
    /// cell -- the column is the *display width* left of the cursor, not
    /// the byte count, so a CJK line's caret is placed right (see
    /// `lineedit` / `caretCol`).
    ///
    /// Every ordinary editing operation (`moveCursorTo`, `insertText`,
    /// `deleteBackward`/`deleteForward`, `killToStart`, `setLine`) funnels
    /// through here, so clearing `browse_pos` unconditionally is the
    /// entire "snap back to the prompt" mechanism -- the moment any of
    /// those run, the grid cursor lands back on the live prompt as a side
    /// effect.
    ///
    /// If the host window was scrolled back into scrollback (via browsing
    /// past the top, or the host's own wheel/scrollbar), snap it back to
    /// the live tail here too -- starting to type, moving the cursor, etc.
    /// all mean "I'm done looking at history".
    fn setCursorAt(self: *Prompt, offset: usize) !void {
        self.browse_pos = null;
        if (self.view_scroll != 0) {
            const res = try self.client.scrollView(0, null);
            self.view_scroll = res.offset;
        }
        self.cursor = std.math.clamp(offset, 0, self.buffer.items.len);
        try self.renderInputLine();
    }

    /// Re-echoes the whole command line unbounded from `line_start` (the
    /// input box normally shows only a horizontally-scrolled window of it)
    /// so scrollback keeps the full command, then drops to the row below
    /// the prompt line and runs it as a command if it names one (see
    /// `runCommand`), resyncing from the server before a fresh prompt.
    /// `exit` skips all of that and just sets `should_exit`.
    ///
    /// The drop is to `line_start_row + 1`, not the end of a re-echo that
    /// wrapped -- matching the pre-repaint editor, where a long command
    /// naturally wrapped onto the next row as it was typed and the
    /// command's output then drew over that wrapped tail.
    fn submitLine(self: *Prompt) !void {
        try self.client.setCursor(self.line_start_row, self.line_start_col);
        if (self.buffer.items.len > 0) try self.client.writeText(self.buffer.items, null, null);
        try self.client.setCursor(self.line_start_row + 1, 0);

        const alloc = self.client.alloc;

        // Record into history before `showPrompt` clears `buffer` below --
        // an owned dupe, since `buffer`'s own storage gets reused for the
        // next line. Blank lines and a line identical to the previous
        // entry aren't worth recalling, so they're skipped (bash
        // `ignoredups`); `history.shouldRecord` is the same rule the
        // persisted file uses. Submitting always leaves the next prompt on
        // the not-recalling line, `historyUp` included.
        {
            const prev: ?[]const u8 = if (self.history.items.len > 0)
                self.history.items[self.history.items.len - 1]
            else
                null;
            if (history.shouldRecord(prev, self.buffer.items)) {
                try self.history.append(alloc, try alloc.dupe(u8, self.buffer.items));
                self.persistHistory();
            }
        }
        self.history_index = null;

        try self.dispatchLine();
        if (self.should_exit) return; // "exit" (typed or via an alias) -- see dispatchLine

        const cur = self.client.getCursor() catch glyphwire.Cursor{ .row = self.line_start_row + 1, .col = 0 };
        try self.client.setCursor(cur.row + 1, 0);
        try self.showPrompt();
    }

    /// Runs whatever the just-committed line (`self.buffer`) names -- the
    /// `alias`/`unalias`/`cd`/`exit` builtins, or an external command via
    /// `runCommand`.
    ///
    /// Order matches bash: word-splitting is quote-aware
    /// (`wordsplit.splitArgs`: single/double quotes and backslash
    /// escapes), then a leading alias is expanded (`expandAliases`), then
    /// `*` globs (`expandGlobs`), then builtin/command dispatch -- so an
    /// `alias`-defined name reaches exactly the same dispatch a typed
    /// name would. `alias` itself is handled off the raw line ahead of
    /// splitting -- its value has rest-of-line semantics
    /// (`wordsplit.parseAliasDef`), unlike every other argument.
    fn dispatchLine(self: *Prompt) !void {
        const alloc = self.client.alloc;
        const trimmed = std.mem.trimStart(u8, self.buffer.items, " \t");

        if (std.mem.startsWith(u8, trimmed, "alias") and
            (trimmed.len == "alias".len or trimmed["alias".len] == ' ' or trimmed["alias".len] == '\t'))
        {
            return self.doAlias(self.buffer.items);
        }

        const words = try wordsplit.splitArgs(alloc, self.buffer.items);
        defer wordsplit.freeArgs(alloc, words);
        if (words.len == 0) return;

        const expanded = try self.expandAliases(words);
        defer wordsplit.freeArgs(alloc, expanded);
        if (expanded.len == 0) return;

        // Glob expansion happens after alias expansion (bash order) and
        // drops the per-token "was quoted" flag, so it's the last step
        // before dispatch.
        const argv = try self.expandGlobs(expanded);
        defer wordsplit.freeTokens(alloc, argv);
        if (argv.len == 0) return;

        // Precedence: core builtins > aliases (already expanded above) >
        // script builtins > $PATH. A `cd.lua` can't shadow the real `cd`.
        if (std.mem.eql(u8, argv[0], "exit")) {
            self.should_exit = true;
        } else if (std.mem.eql(u8, argv[0], "unalias")) {
            try self.doUnalias(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "cd")) {
            try self.doCd(argv[1..]);
        } else if (self.runScriptBuiltin(argv)) {
            // handled by the persistent Lua engine
        } else {
            try self.runCommand(argv);
        }
    }

    /// If `argv[0]` names a script builtin (a `defcmd` registration or a
    /// `~/.config/glyphwire/scripts/<name>.lua`), runs it in-process and
    /// returns true, recording its exit status the same way an external
    /// command's is. Returns false -- untouched -- when there's no engine
    /// or no such builtin, so dispatch falls through to `$PATH`.
    fn runScriptBuiltin(self: *Prompt, argv: []const []const u8) bool {
        const eng = self.script_engine orelse return false;
        if (!eng.hasCommand(argv[0])) return false;
        const code = eng.runCommand(argv[0], argv[1..]);
        self.last_status = code;
        self.last_dur_ms = 0;
        self.have_status = true;
        return true;
    }

    /// Runs `argv` under a B0 "dumb PTY" (`shell/pty.zig`): the child's
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
    /// still need more -- see `docs/investigations/libghostty-vt-
    /// fallback.md` §7a.
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
    /// already gives its target (see `expandTilde`).
    fn runCommand(self: *Prompt, argv: []const []const u8) !void {
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
            const exp = self.expandTilde(arg) catch {
                try self.client.writeText("~: HOME not set", .{ .r = 255, .g = 85, .b = 85 }, null);
                return;
            };
            try expanded.append(alloc, exp);
        }

        // NUL-terminated, NULL-terminated argv for libc `execvp`.
        var argv_bufs: std.ArrayList([:0]u8) = .empty;
        defer {
            for (argv_bufs.items) |b| alloc.free(b);
            argv_bufs.deinit(alloc);
        }
        for (expanded.items) |a| try argv_bufs.append(alloc, try alloc.dupeZ(u8, a));
        const argv_z = try alloc.allocSentinel(?[*:0]const u8, argv_bufs.items.len, null);
        defer alloc.free(argv_z);
        for (argv_bufs.items, 0..) |b, i| argv_z[i] = b.ptr;

        // Size the pty from the grid so a curses-ish child lays out right.
        const size = self.client.getSize() catch glyphwire.LayerSize{ .cols = self.grid_cols, .rows = 24 };

        // Monotonic start time of the whole run, for `{dur}` on the next
        // prompt (this reduced std has no `std.time.Timer`).
        const started = std.Io.Clock.Timestamp.now(self.client.io, .awake);

        var pty = Pty.spawn(argv_z.ptr, @intCast(size.cols), @intCast(size.rows)) catch |err| {
            var buf: [160]u8 = undefined;
            const msg = switch (err) {
                error.CommandNotFound => std.fmt.bufPrint(&buf, "{s}: command not found", .{argv[0]}) catch "command not found",
                else => std.fmt.bufPrint(&buf, "{s}: {t}", .{ argv[0], err }) catch "failed to start command",
            };
            try self.client.writeText(msg, .{ .r = 255, .g = 85, .b = 85 }, null);
            // Couldn't start it: record a status so `{exit}` reflects the
            // failure, but no duration (it never ran).
            self.last_status = if (err == error.CommandNotFound) 127 else 1;
            self.last_dur_ms = 0;
            self.have_status = true;
            return;
        };
        defer pty.deinit();

        // Record the run's outcome for the next prompt's `{exit}` / `{dur}`.
        // Runs before `pty.deinit` (defers are LIFO) so `pty` is still
        // valid; `pty.exit_code` is set by whichever of `reaped`/`wait`
        // reaped the child below.
        defer {
            const elapsed_ms = started.untilNow(self.client.io).raw.toMilliseconds();
            self.last_dur_ms = if (elapsed_ms > 0) @intCast(elapsed_ms) else 0;
            self.last_status = pty.exit_code;
            self.have_status = true;
        }

        var reader_ctx = PtyReaderCtx{ .prompt = self, .master = pty.master };
        const reader = std.Thread.spawn(.{}, ptyReaderThread, .{&reader_ctx}) catch |err| {
            // Can't mirror output -- tear the child down rather than leak it.
            pty.signalGroup(std.posix.SIG.KILL);
            pty.wait();
            return err;
        };

        // No listener means this isn't the interactive prompt (shouldn't
        // happen -- the exec path in `main` never calls here). Just wait.
        const listener = self.listener orelse {
            pty.wait();
            reader.join();
            return;
        };

        // Foreground: forward keystrokes to the pty until the child exits.
        // `pty.reaped()` polls (WNOHANG) once per loop; the wait's short
        // timeout bounds how long an exit-with-no-keypress waits.
        while (!pty.reaped()) {
            const input_ev = (listener.waitInputEvent(.{ .duration = .{ .raw = .fromMilliseconds(120), .clock = .awake } }) catch null) orelse continue;

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
                .key => |kev| kev,
            };
            defer alloc.free(ev.key);
            if (!ev.pressed) continue;
            const mods = keyencode.Mods{
                .ctrl = listener.isKeyDown("left_control") or listener.isKeyDown("right_control"),
                .shift = listener.isKeyDown("left_shift") or listener.isKeyDown("right_shift"),
                .alt = listener.isKeyDown("left_alt") or listener.isKeyDown("right_alt"),
            };
            // A plain printable key (no ctrl/alt) is delivered as a `text`
            // event, not re-encoded here -- otherwise the child sees it
            // twice. `toPtyBytes` still handles the named keys (Enter,
            // arrows, ...) and ctrl/alt combos, which produce no `text`.
            if (!mods.ctrl and !mods.alt and keyencode.charFromKeyName(ev.key, false) != null) continue;
            var kb: [8]u8 = undefined;
            if (keyencode.toPtyBytes(ev.key, mods, &kb)) |seq| pty.writeAll(seq);
        }

        // Child reaped -> its slave is closed -> the reader's next master
        // read returns EOF/EIO and the thread exits on its own.
        reader.join();
    }

    /// Context for `ptyReaderThread`. `master` is owned by `runCommand`
    /// (which closes it after the thread joins); the thread only reads it.
    const PtyReaderCtx = struct {
        prompt: *Prompt,
        master: std.c.fd_t,
    };

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
    fn ptyReaderThread(ctx: *PtyReaderCtx) void {
        const self = ctx.prompt;
        const alloc = self.client.alloc;
        const io = self.client.io;

        var pending: std.ArrayList(u8) = .empty; // held until the handshake resolves
        defer pending.deinit(alloc);
        var aware: ?bool = null;

        var out_buf: [512]u8 = undefined;
        var real_out = std.Io.File.stdout().writer(io, &out_buf);

        var buf: [4096]u8 = undefined;
        while (true) {
            var pfd = [_]std.posix.pollfd{.{ .fd = ctx.master, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&pfd, 1000) catch break;
            if (pfd[0].revents == 0) continue; // timeout, nothing ready

            const n = std.c.read(ctx.master, &buf, buf.len);
            if (n <= 0) break; // EOF, or EIO once the slave is fully closed
            const chunk = buf[0..@intCast(n)];

            if (aware == null) {
                pending.appendSlice(alloc, chunk) catch break;
                aware = hs.aware(pending.items);
                if (aware == null) continue; // still a prefix of the marker
                const body = if (aware.?) pending.items[hs.marker.len..] else pending.items;
                emitChunk(self, &real_out, aware.?, body);
                pending.clearRetainingCapacity();
                continue;
            }
            emitChunk(self, &real_out, aware.?, chunk);
        }

        // EOF before the handshake could resolve (total output shorter
        // than the marker) -> treat as a plain child, flush what we held.
        if (aware == null and pending.items.len > 0) {
            emitChunk(self, &real_out, false, pending.items);
        }
    }

    /// One chunk from `ptyReaderThread`: onto the grid (plain child) or to
    /// this process's real stdout (aware child). Best-effort -- a write
    /// failure here has nowhere useful to go.
    fn emitChunk(self: *Prompt, real_out: *std.Io.File.Writer, aware: bool, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (aware) {
            real_out.interface.writeAll(bytes) catch {};
            real_out.interface.flush() catch {};
        } else {
            self.client.writeText(bytes, null, null) catch {};
        }
    }

    /// `cd` is a shell builtin, not a spawned program -- unlike
    /// `runCommand`, changing directory in a *child* process wouldn't
    /// affect this one, so it has to happen here directly. No args (or a
    /// bare `~`) goes to `$HOME`, matching a real shell; a bad path or
    /// missing `$HOME` is reported onto the grid the same way
    /// `runCommand` reports a spawn failure, rather than propagated.
    fn doCd(self: *Prompt, args: []const []const u8) !void {
        const io = self.client.io;
        const alloc = self.client.alloc;
        const raw_target: []const u8 = if (args.len > 0) args[0] else "~";

        const target = self.expandTilde(raw_target) catch {
            try self.client.writeText("cd: HOME not set", .{ .r = 255, .g = 85, .b = 85 }, null);
            return;
        };
        defer if (target.ptr != raw_target.ptr) alloc.free(target);

        var dir = std.Io.Dir.cwd().openDir(io, target, .{}) catch |err| {
            try self.reportCdError(target, err);
            return;
        };
        defer dir.close(io);

        std.process.setCurrentDir(io, dir) catch |err| {
            try self.reportCdError(target, err);
        };
    }

    /// Expands a leading `~` to `$HOME` -- bare `~` or `~/rest`; `~user`
    /// (another account's home directory) isn't supported, matching how
    /// most shells treat that as a rarer case not worth the lookup here.
    /// Returns `target` itself (same pointer) when there's nothing to
    /// expand, so `doCd` knows whether the result needs freeing.
    fn expandTilde(self: *Prompt, target: []const u8) ![]const u8 {
        if (target.len == 0 or target[0] != '~') return target;
        if (target.len > 1 and target[1] != '/') return target;

        const home = self.environ_map.get("HOME") orelse return error.HomeNotSet;
        if (target.len == 1) return try self.client.alloc.dupe(u8, home);
        return try std.fmt.allocPrint(self.client.alloc, "{s}{s}", .{ home, target[1..] });
    }

    fn reportCdError(self: *Prompt, target: []const u8, err: anyerror) !void {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "cd: {s}: {t}", .{ target, err }) catch "cd: failed";
        try self.client.writeText(msg, .{ .r = 255, .g = 85, .b = 85 }, null);
    }

    /// `alias` builtin. Given a `NAME=VALUE` argument
    /// (`wordsplit.parseAliasDef` -- rest-of-line value, one binding per
    /// line), records the binding; a bare `alias` lists every current
    /// binding, one `NAME='VALUE'` per row sorted by name, matching
    /// bash's output shape. Takes the raw prompt line because the value
    /// is not word-split.
    fn doAlias(self: *Prompt, line: []const u8) !void {
        const alloc = self.client.alloc;
        if (wordsplit.parseAliasDef(line)) |def| {
            try self.aliases.set(alloc, def.name, def.value);
            return;
        }
        try self.listAliases();
    }

    fn listAliases(self: *Prompt) !void {
        const alloc = self.client.alloc;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(alloc);
        var it = self.aliases.map.iterator();
        while (it.next()) |e| try names.append(alloc, e.key_ptr.*);

        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        for (names.items) |name| {
            const value = self.aliases.get(name).?;
            var buf: [1024]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buf, "alias {s}='{s}'\n", .{ name, value }) catch continue;
            try self.client.writeText(rendered, null, null);
        }
    }

    /// `unalias NAME...` builtin. A name with no current binding is
    /// reported onto the grid (bash-style) rather than propagated as an
    /// error.
    fn doUnalias(self: *Prompt, names: []const []const u8) !void {
        const alloc = self.client.alloc;
        for (names) |name| {
            if (!self.aliases.remove(alloc, name)) {
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "unalias: {s}: not found", .{name}) catch "unalias: not found";
                try self.client.writeText(msg, .{ .r = 255, .g = 85, .b = 85 }, null);
            }
        }
    }

    /// Stands up the persistent Lua interpreter (`script_engine`), wired
    /// to this prompt's environment overlay, cwd and grid. Safe to skip:
    /// on failure `script_engine` stays null and script builtins are just
    /// unavailable.
    fn initScriptEngine(self: *Prompt, config_dir: []const u8) !void {
        self.script_engine = try script_engine.ScriptEngine.init(
            self.client.alloc,
            self.client.io,
            self.scriptHooks(),
            config_dir,
        );
    }

    /// The `script_engine.HostHooks` for this prompt -- how a running
    /// script reaches the live shell (env, cwd, grid, Ctrl-C).
    fn scriptHooks(self: *Prompt) script_engine.HostHooks {
        return .{
            .ctx = self,
            .setenv = hookSetenv,
            .unsetenv = hookUnsetenv,
            .getenv = hookGetenv,
            .cwd = hookCwd,
            .realpath = hookRealpath,
            .write = hookWrite,
            .poll_interrupt = hookPollInterrupt,
        };
    }

    /// Reads `shell.conf` and runs it through the persistent
    /// `script_engine` (so a `function` it defines survives as a
    /// builtin). Its `alias` declarations are replayed into the live
    /// alias table; a syntax/runtime error is shown in red with whatever
    /// ran first still in effect. A missing file or no engine is fine.
    fn loadStartupConfig(self: *Prompt, config_dir: []const u8) !void {
        const alloc = self.client.alloc;
        const io = self.client.io;

        const eng = self.script_engine orelse return;

        const path = try std.fs.path.join(alloc, &.{ config_dir, "shell.conf" });
        defer alloc.free(path);

        const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, alloc, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("shell.conf: could not read {s}: {t}", .{ path, err });
                return;
            },
        };
        defer alloc.free(source);

        try eng.runConf(source);

        for (eng.cfg.aliases.items) |a| {
            try self.aliases.set(alloc, a.name, a.value);
        }

        if (eng.conf_err) |msg| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "shell.conf: {s}\n", .{msg}) catch "shell.conf: error\n";
            try self.client.writeText(line, .{ .r = 255, .g = 85, .b = 85 }, null);
        }

        // The engine owns the parsed config for the session --
        // `writePromptPrefix` reads `.prompt` off it live on every redraw
        // (so `{time}` and cwd stay current).
        self.prompt_config = &eng.cfg;
    }

    /// Loads `~/.config/glyphwire/history` into `self.history` so ctrl+up
    /// recall picks up where the last session left off, then records the
    /// file path in `self.history_path` and rewrites the file once
    /// (trimmed to the last `history.max_entries`, consecutive duplicates
    /// dropped) so it stays bounded. Creates the config directory if it's
    /// missing. Any IO failure just leaves `history_path` null -- the
    /// session runs with in-memory-only history rather than failing.
    ///
    /// Setting `$GLYPHWIRE_NO_HISTORY` (to any non-empty value) skips all
    /// of this: no file is read or written and `history_path` stays null,
    /// so recall works within the session but nothing is persisted. The
    /// e2e tests set it so driving the real shell binary doesn't touch
    /// the developer's own history file.
    fn loadHistory(self: *Prompt, config_dir: []const u8) !void {
        const alloc = self.client.alloc;
        const io = self.client.io;

        if (self.environ_map.get("GLYPHWIRE_NO_HISTORY")) |v| {
            if (v.len > 0) return;
        }

        std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
            std.log.warn("history: could not create {s}: {t}", .{ config_dir, err });
            return;
        };

        const path = try std.fs.path.join(alloc, &.{ config_dir, "history" });
        errdefer alloc.free(path);

        if (std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20))) |bytes| {
            defer alloc.free(bytes);
            const entries = try history.parse(alloc, bytes);
            defer history.freeEntries(alloc, entries);
            for (entries) |e| try self.history.append(alloc, try alloc.dupe(u8, e));
        } else |err| switch (err) {
            error.FileNotFound => {}, // first run -- nothing to load
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("history: could not read {s}: {t}", .{ path, err });
                alloc.free(path);
                return;
            },
        }

        self.history_path = path;
        self.persistHistory();
    }

    /// Rewrites the whole history file from `self.history` (trimmed to the
    /// last `history.max_entries`). Called after every recorded line --
    /// the file is small and interactive commands are human-slow, so a
    /// full rewrite each time is simpler than an append + periodic
    /// compaction, and it means the file survives this process being
    /// killed rather than exited (the usual way an interactive session
    /// ends here). A no-op when there's no `history_path`; an IO failure
    /// is logged, not propagated.
    fn persistHistory(self: *Prompt) void {
        const path = self.history_path orelse return;
        const alloc = self.client.alloc;

        const bytes = history.serialize(alloc, self.history.items) catch return;
        defer alloc.free(bytes);

        std.Io.Dir.cwd().writeFile(self.client.io, .{ .sub_path = path, .data = bytes }) catch |err| {
            std.log.warn("history: could not write {s}: {t}", .{ path, err });
        };
    }

    /// Expands a leading alias in `words` into a fresh owned `Arg` list.
    /// Follows an alias whose body again begins with an alias name
    /// (bash-style chaining), but stops the first time a name would be
    /// expanded twice on one line -- so `alias ls='ls --color'` resolves
    /// exactly once instead of looping -- with a hard depth cap as a
    /// backstop. When `words[0]` isn't an alias the result is just an
    /// owned copy of `words`. Always freshly allocated; free with
    /// `wordsplit.freeArgs`.
    ///
    /// Tokens introduced from an alias body are marked `quoted = false`
    /// (glob-eligible): re-evaluating an alias body is exactly what makes
    /// `alias x='echo *'` expand the `*` in the caller's directory, the
    /// same as bash. Tokens carried over from the original line keep
    /// their own `quoted` flag.
    fn expandAliases(self: *Prompt, words: []const wordsplit.Arg) ![]wordsplit.Arg {
        const alloc = self.client.alloc;

        var list: std.ArrayList(wordsplit.Arg) = .empty;
        errdefer {
            for (list.items) |a| alloc.free(a.text);
            list.deinit(alloc);
        }
        for (words) |a| try list.append(alloc, .{ .text = try alloc.dupe(u8, a.text), .quoted = a.quoted });

        var seen: std.ArrayList([]const u8) = .empty;
        defer {
            for (seen.items) |n| alloc.free(n);
            seen.deinit(alloc);
        }

        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            if (list.items.len == 0) break;
            const first = list.items[0].text;
            // A quoted first word ('ls' foo) is a literal command name,
            // never an alias key -- matches bash.
            if (list.items[0].quoted) break;

            for (seen.items) |n| {
                if (std.mem.eql(u8, n, first)) return list.toOwnedSlice(alloc);
            }
            const body = self.aliases.get(first) orelse break;
            try seen.append(alloc, try alloc.dupe(u8, first));

            const body_words = try wordsplit.split(alloc, body);
            defer wordsplit.freeTokens(alloc, body_words);

            alloc.free(list.orderedRemove(0).text);
            var at: usize = 0;
            for (body_words) |bw| {
                try list.insert(alloc, at, .{ .text = try alloc.dupe(u8, bw), .quoted = false });
                at += 1;
            }
        }

        return list.toOwnedSlice(alloc);
    }

    /// Expands single-segment `*` / `?` / `[...]` globs in `args` into a
    /// plain owned token list (the `quoted` flag is consumed here and
    /// dropped). For each arg: a quoted token or one with no wildcard
    /// passes through unchanged; otherwise its final path segment is
    /// matched against the entries of the directory its `dir/` prefix
    /// names (cwd if none; `~`/`~/` expanded), and the sorted matches
    /// replace it -- each with the original `dir/` prefix kept. A pattern
    /// with no matches is left literally in place (bash's default,
    /// nullglob off). Only the last segment is a pattern; a wildcard in
    /// the `dir/` part is not expanded yet (see decisions.md). Free the
    /// result with `wordsplit.freeTokens`.
    fn expandGlobs(self: *Prompt, args: []const wordsplit.Arg) ![]const []const u8 {
        const alloc = self.client.alloc;
        const io = self.client.io;

        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |t| alloc.free(t);
            out.deinit(alloc);
        }

        for (args) |arg| {
            if (arg.quoted or !glob.hasWildcard(arg.text)) {
                try out.append(alloc, try alloc.dupe(u8, arg.text));
                continue;
            }

            const dp = complete.dirPrefix(arg.text);
            const scan_dir = try self.completionDir(dp.dir);
            defer alloc.free(scan_dir);

            var dir = std.Io.Dir.cwd().openDir(io, scan_dir, .{ .iterate = true }) catch {
                try out.append(alloc, try alloc.dupe(u8, arg.text));
                continue;
            };
            defer dir.close(io);

            var matches: std.ArrayList([]const u8) = .empty;
            defer {
                for (matches.items) |m| alloc.free(m);
                matches.deinit(alloc);
            }

            const want_hidden = dp.prefix.len > 0 and dp.prefix[0] == '.';
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (!want_hidden and std.mem.startsWith(u8, entry.name, ".")) continue;
                if (!glob.match(dp.prefix, entry.name)) continue;
                try matches.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s}", .{ dp.dir, entry.name }));
            }

            if (matches.items.len == 0) {
                try out.append(alloc, try alloc.dupe(u8, arg.text));
                continue;
            }

            std.mem.sort([]const u8, matches.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            for (matches.items) |m| try out.append(alloc, try alloc.dupe(u8, m));
        }

        return out.toOwnedSlice(alloc);
    }

    /// Inserts a run of characters at the cursor -- used both by the
    /// prompt loop's `text`-event handler (the characters the user typed,
    /// already layout/dead-key/IME resolved) and by Tab completion. The
    /// buffer edit plus `setCursorAt` -> `renderInputLine` repaint the box;
    /// column math in the repaint is display-width-correct so a CJK run
    /// lands right.
    fn insertText(self: *Prompt, text: []const u8) !void {
        if (text.len == 0) return;
        try self.buffer.insertSlice(self.client.alloc, self.cursor, text);
        self.cursor += text.len;
        try self.setCursorAt(self.cursor); // -> renderInputLine repaints the box
    }

    /// Tab: filename completion for the word under the cursor. Reads the
    /// directory named by the word's leading `dir/` part (cwd if none;
    /// `~`/`~/` expanded), keeps entries whose name starts with the
    /// word's final segment, and:
    ///
    ///   * 0 matches       -> nothing;
    ///   * exactly 1 match -> fills it in and appends `/` (a directory) or
    ///                        a space (anything else);
    ///   * >1 matches with a longer shared prefix -> extends the word to
    ///                        that common prefix (bash's first-Tab behaviour);
    ///   * >1 matches, nothing more to share -> prints the candidate list
    ///                        below the prompt, but only on the *second*
    ///                        consecutive Tab (`completion_armed`).
    ///
    /// Dot-files are skipped unless the typed prefix itself starts with a
    /// dot, matching every shell. Quoting inside the word isn't
    /// interpreted -- see `complete.wordRange`.
    fn doComplete(self: *Prompt) !void {
        const alloc = self.client.alloc;
        const io = self.client.io;

        const line = self.buffer.items;
        const wr = complete.wordRange(line, self.cursor);
        const word = line[wr.start..self.cursor];
        const dp = complete.dirPrefix(word);

        const scan_dir = try self.completionDir(dp.dir);
        defer alloc.free(scan_dir);

        var dir = std.Io.Dir.cwd().openDir(io, scan_dir, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var cands: std.ArrayList(CompletionCandidate) = .empty;
        defer {
            for (cands.items) |cand| alloc.free(cand.name);
            cands.deinit(alloc);
        }

        const want_hidden = dp.prefix.len > 0 and dp.prefix[0] == '.';
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, dp.prefix)) continue;
            if (!want_hidden and std.mem.startsWith(u8, entry.name, ".")) continue;
            try cands.append(alloc, .{
                .name = try alloc.dupe(u8, entry.name),
                .is_dir = entry.kind == .directory,
            });
        }
        if (cands.items.len == 0) return;

        std.mem.sort(CompletionCandidate, cands.items, {}, struct {
            fn lessThan(_: void, a: CompletionCandidate, b: CompletionCandidate) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        if (cands.items.len == 1) {
            const only = cands.items[0];
            try self.insertText(only.name[dp.prefix.len..]);
            try self.insertText(if (only.is_dir) "/" else " ");
            self.completion_armed = false;
            return;
        }

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(alloc);
        for (cands.items) |cand| try names.append(alloc, cand.name);
        const lcp = complete.commonPrefixLen(names.items);

        if (lcp > dp.prefix.len) {
            try self.insertText(cands.items[0].name[dp.prefix.len..lcp]);
            self.completion_armed = true;
            return;
        }

        if (self.completion_armed) {
            try self.listCompletions(cands.items);
            self.completion_armed = false;
        } else {
            self.completion_armed = true;
        }
    }

    /// Resolves the `dir/` portion of a completion word to a path
    /// `openDir` can take: an owned copy of `"."` when there's no
    /// directory part, otherwise the part itself with `~`/`~/` expanded.
    /// Always returns an owned string for the caller to free.
    fn completionDir(self: *Prompt, dir_part: []const u8) ![]const u8 {
        const alloc = self.client.alloc;
        if (dir_part.len == 0) return alloc.dupe(u8, ".");
        const expanded = self.expandTilde(dir_part) catch return alloc.dupe(u8, dir_part);
        if (expanded.ptr == dir_part.ptr) return alloc.dupe(u8, dir_part);
        return expanded; // expandTilde already returned an owned allocation
    }

    /// Prints the completion candidates on the row below the prompt
    /// (two spaces between, `/` after directories), then redraws the
    /// prompt prefix and the in-progress line underneath and restores the
    /// cursor -- the same "write below, then re-show the prompt" shape
    /// `submitLine` uses.
    fn listCompletions(self: *Prompt, cands: []const CompletionCandidate) !void {
        try self.client.setCursor(self.line_start_row + 1, 0);
        for (cands, 0..) |cand, i| {
            if (i != 0) try self.client.writeText("  ", null, null);
            try self.client.writeText(cand.name, null, null);
            if (cand.is_dir) try self.client.writeText("/", null, null);
        }
        try self.client.writeText("\n", null, null);

        const cur = try self.writePromptPrefix();
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;
        self.input_scroll = 0;
        try self.setCursorAt(self.cursor); // -> renderInputLine redraws the typed line
    }
};

// ─── script engine host hooks ────────────────────────────────────────
//
// `shell/script_engine.zig` reaches the live shell only through these
// function pointers (its `HostHooks`); `ctx` is always the `*Prompt`.
// Kept as free functions, not `Prompt` methods, because that's the shape
// a `*const fn (ctx: *anyopaque, ...)` pointer needs.

/// `sh.setenv` -- update libc (so children spawned afterwards inherit it;
/// pty.zig's `execvp` reads the live environ) and the prompt's own live
/// view that `{env:NAME}` renders from.
fn hookSetenv(ctx: *anyopaque, name: []const u8, value: []const u8) void {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    const alloc = self.client.alloc;
    const name_z = alloc.dupeZ(u8, name) catch return;
    defer alloc.free(name_z);
    const value_z = alloc.dupeZ(u8, value) catch return;
    defer alloc.free(value_z);
    _ = c.setenv(name_z, value_z, 1);
    self.env.put(name, value) catch {};
}

/// `sh.unsetenv` -- the mirror of `hookSetenv`.
fn hookUnsetenv(ctx: *anyopaque, name: []const u8) void {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    const alloc = self.client.alloc;
    const name_z = alloc.dupeZ(u8, name) catch return;
    defer alloc.free(name_z);
    _ = c.unsetenv(name_z);
    _ = self.env.swapRemove(name);
}

/// `sh.getenv` -- the shell's live value (script-set values included).
fn hookGetenv(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    return self.env.get(name);
}

/// `sh.cwd` -- absolute working directory into `buf`.
fn hookCwd(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    const n = std.process.currentPath(self.client.io, buf) catch return null;
    return buf[0..n];
}

/// `sh.realpath` -- libc `realpath`, so `..`/symlinks/relative all
/// collapse against the real filesystem. `buf` must be `PATH_MAX`.
fn hookRealpath(ctx: *anyopaque, path: [:0]const u8, buf: []u8) ?[]const u8 {
    _ = ctx;
    if (buf.len < std.fs.max_path_bytes) return null;
    const resolved = c.realpath(path, buf.ptr) orelse return null;
    return std.mem.span(resolved);
}

/// Grid sink for a script's `print` / `io.write`.
fn hookWrite(ctx: *anyopaque, bytes: []const u8) void {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    self.client.writeText(bytes, null, null) catch {};
}

/// Polled from the interrupt hook while a script runs: drains pending
/// input (type-ahead is dropped for the duration of the builtin) and
/// returns true the moment it sees Ctrl-C.
fn hookPollInterrupt(ctx: *anyopaque) bool {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    const listener = self.listener orelse return false;
    var hit = false;
    while (listener.pollInputEvent()) |iev| switch (iev) {
        .key => |kev| {
            defer self.client.alloc.free(kev.key);
            if (kev.pressed and std.mem.eql(u8, kev.key, "c") and
                (listener.isKeyDown("left_control") or listener.isKeyDown("right_control")))
                hit = true;
        },
        .text => |tev| self.client.alloc.free(tev.text),
    };
    return hit;
}

