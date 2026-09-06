const std = @import("std");
const glyphwire = @import("glyphwire");
const wordsplit = @import("shell_support").wordsplit;
const parse = @import("shell_support").parse;
const pipeexec = @import("shell_support").pipeexec;
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
const openaction = @import("shell_support").openaction;
const Pty = glyphwire.Pty;
const ModeTracker = glyphwire.ModeTracker;

/// The left prompt template used when `shell.conf` configured a prompt
/// (`prompt.right` and/or the sub-templates) but not `prompt.left`. Byte
/// for byte the same as the unconfigured default `writeDefaultPrefix`
/// produces -- an absolute cwd, then `" > "`.
const default_prompt_left = "{cwd_full} > ";

/// The red glyphwire-shell uses for every error line it prints onto the
/// grid itself (a bad `cd`, a spawn failure, a pipeline syntax error).
const err_color = glyphwire.Color{ .r = 255, .g = 85, .b = 85 };

/// Rows of context kept between the browse cursor and the top/bottom of
/// the window while walking scrollback with the arrow keys, when
/// `shell.conf`'s `prompt{ scrolloff = N }` isn't set. See
/// `Prompt.scrolloffRows`.
const default_scrolloff: usize = 8;

/// Rows Ctrl+Up / Ctrl+Down jump per press while browsing scrollback,
/// when `shell.conf`'s `prompt{ scrollback_jump = N }` isn't set. See
/// `Prompt.scrollbackJumpRows`.
const default_scrollback_jump: usize = 5;

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

/// Fish-style inline completion hint delay. The prompt loop already uses
/// a 500ms idle heartbeat, so this stays aligned with that cadence.
const autocomplete_idle_ms: i64 = 500;
const autocomplete_hint_color = glyphwire.Color{ .r = 120, .g = 120, .b = 120 };

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
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
};

/// `signal(2)` just for the one-shot SIGPIPE ignore in `main`. Linux
/// constants; the shell is Linux-only in practice (pty / pipeexec).
const csig = struct {
    extern "c" fn signal(sig: c_int, handler: usize) usize;
    const SIGPIPE: c_int = 13;
    const SIG_IGN: usize = 1;
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
/// engine dependency: input arrives as wire-level key events (see
/// src/client.zig's `InputListener`), captured by glyphwire-host and
/// relayed through the server, not read directly.
///
/// The prompt supports echo, Enter, real cursor movement and interior
/// insert/delete (arrow keys, ctrl+a/e/u, ctrl+arrow word jumps, Up/Down
/// history recall, Ctrl+Up to browse scrollback -- see `Prompt`), and now
/// launches a child process
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
/// convention most game examples use, which would kill an
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

    // A pipeline writes to a child's stdin fd (`pipeexec`); when that
    // child has already exited the write raises SIGPIPE, which would kill
    // the shell. Ignore it process-wide and take the EPIPE return
    // instead -- nothing here streams to a pipe it must not outlive.
    _ = csig.signal(csig.SIGPIPE, csig.SIG_IGN);

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

/// The modifier keys currently held, as `key_encode` wants them -- shared
/// by the pty key loop and the mouse encoder.
fn ptyMods(listener: *glyphwire.InputListener) keyencode.Mods {
    return .{
        .ctrl = listener.isKeyDown("left_control") or listener.isKeyDown("right_control"),
        .shift = listener.isKeyDown("left_shift") or listener.isKeyDown("right_shift"),
        .alt = listener.isKeyDown("left_alt") or listener.isKeyDown("right_alt"),
    };
}

/// The primary mouse button currently held, or null if none -- used to
/// decide whether `?1002` (motion only while dragging) should report, and
/// which button to name in the report.
fn heldMouseButton(listener: *glyphwire.InputListener) ?keyencode.MouseButton {
    if (listener.isMouseButtonDown("left")) return .left;
    if (listener.isMouseButtonDown("middle")) return .middle;
    if (listener.isMouseButtonDown("right")) return .right;
    return null;
}

/// Drains `InputListener`'s mouse queues once. When the foregrounded pty
/// child has a mouse-reporting mode on (`glyphwire.ModeTracker`), each
/// event is re-encoded as an xterm mouse report and written to the pty;
/// otherwise the events are just discarded so the queues don't fill while
/// a command runs. `mev.button` is freed either way.
fn pumpPtyMouse(
    alloc: std.mem.Allocator,
    listener: *glyphwire.InputListener,
    pty: *Pty,
    modes: *ModeTracker,
) void {
    const reporting = modes.mouseReporting();
    const enc: keyencode.MouseEncoding = if (modes.sgrMouse()) .sgr else .legacy;

    while (listener.pollMouseButtonEvent()) |mev| {
        defer alloc.free(mev.button);
        if (!reporting) continue;
        const btn = keyencode.mouseButtonFromName(mev.button) orelse continue;
        const action: keyencode.MouseAction = if (mev.pressed) .press else .release;
        var buf: [16]u8 = undefined;
        if (keyencode.encodeMouse(enc, btn, action, mev.cell.col, mev.cell.row, ptyMods(listener), &buf)) |seq|
            pty.writeAll(seq);
    }

    const want_motion = reporting and modes.wantsMotion();
    while (listener.pollMouseMoveEvent()) |mev| {
        if (!want_motion) continue;
        // `?1002` reports motion only while a button is held; `?1003`
        // reports it with a "no button" code the rest of the time.
        const btn = heldMouseButton(listener) orelse
            (if (modes.wantsAnyMotion()) keyencode.MouseButton.none else continue);
        var buf: [16]u8 = undefined;
        if (keyencode.encodeMouse(enc, btn, .motion, mev.cell.col, mev.cell.row, ptyMods(listener), &buf)) |seq|
            pty.writeAll(seq);
    }
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

    // `mouse_move` is subscribed session-wide but only consumed by the
    // pty foreground loop (`runCommand`) when a child turns on motion
    // reporting; the prompt loop lets `InputListener`'s own cap drop the
    // backlog.
    const listener = glyphwire.InputListener.connect(io, alloc, socket_path, &.{ "key", "text", "mouse_button", "mouse_move", "scroll", "resize", "clipboard", "terminal" }) catch |err| {
        std.log.err("prompt: failed to subscribe: {t}", .{err});
        return;
    };
    defer listener.deinit();

    var prompt: Prompt = .{ .client = &client, .environ_map = environ_map, .listener = listener };
    // The live environment `sh.setenv` mutates (alongside libc, for
    // children). Seeded from the *live* libc environ, not the
    // `std.process.Init` snapshot in `environ_map`: `main` prepends
    // `<cwd>/zig-out/bin` to PATH and sets the GLYPHWIRE_* discovery vars
    // with libc `setenv` *after* that snapshot is taken (see
    // `prependZigOutBinToPath`), so seeding from the snapshot would give a
    // stale PATH -- and then a script that rewrites PATH (venv_activate
    // prepending its bin/) would write the stale value back through
    // `c.setenv` and drop `zig-out/bin`, so `ls` would stop resolving to
    // the bundled `glyphwire-ls`. Seeded before `defer prompt.deinit()`
    // so the deinit is always safe.
    prompt.env = std.process.Environ.Map.init(alloc);
    {
        const live: std.process.Environ.PosixBlock.View = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) };
        try prompt.env.putPosixBlock(live);
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
                const ctrl_held = listener.isKeyDown("left_control") or listener.isKeyDown("right_control");
                if (ctrl_held) {
                    // Ctrl+click toggles the entry in the multi-select mark
                    // set (same as Space while browsing).
                    try prompt.toggleHighlightAt(mev.cell.row, mev.cell.col, mev.view_offset);
                } else {
                    // A plain click always runs the entry's own action
                    // (the first `open_actions` command for its type),
                    // regardless of what's marked -- marks are built and
                    // acted on from the keyboard (Space to mark, Enter to
                    // run) or copied with Ctrl+Shift+C.
                    try prompt.activateSelectionAt(mev.cell.row, mev.cell.col, mev.view_offset);
                }
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
            if (prompt.pending_resize == null and prompt.browse_pos == null) {
                const drew_hint = prompt.maybeShowCompletionHint() catch false;
                if (drew_hint) continue;
            }
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
                // Off the browse path this just edits the live line. While
                // browsing scrollback, `scrollback_type_exits` (default
                // true) decides whether a keystroke snaps back to the
                // prompt and inserts (`insertText` funnels through
                // `setCursorAt`, which clears `browse_pos` and the scroll
                // view) or is ignored until Escape. A lone space is the
                // exception: while browsing it toggles the mark under the
                // cursor (handled by the `.key` "space" arm below), so it
                // must not be consumed as type-to-exit here.
                const browse_space = prompt.browse_pos != null and std.mem.eql(u8, tev.text, " ");
                if (!browse_space and (prompt.browse_pos == null or prompt.scrollbackTypeExits())) {
                    try prompt.insertText(tev.text);
                }
                continue;
            },
            .paste => |tev| {
                defer alloc.free(tev.text);
                // Ctrl+Shift+V: insert the clipboard text into the live
                // line without submitting (the user presses Enter). The
                // editor is single-line, so newline runs are flattened to
                // single spaces first -- a pasted file list then reads as
                // space-separated arguments instead of one unusable blob.
                // A paste while browsing follows the same
                // `scrollback_type_exits` rule as typed text.
                if (prompt.browse_pos == null or prompt.scrollbackTypeExits()) {
                    const flat = try lineedit.flattenNewlines(alloc, tev.text);
                    defer alloc.free(flat);
                    try prompt.insertText(flat);
                }
                continue;
            },
            .copy_request => {
                // Ctrl+Shift+C was pressed with nothing selected in the
                // host. With entries marked, answer with their paths as
                // one space-separated line (each quoted only if it needs
                // it); otherwise with the current line. Either way it
                // lands on the OS clipboard.
                if (prompt.marks.items.len > 0) {
                    if (prompt.markedPathsText(alloc)) |text| {
                        defer alloc.free(text);
                        client.setClipboard(text) catch |err| {
                            std.log.err("prompt: set_clipboard (copy_request) failed: {t}", .{err});
                        };
                    } else |err| {
                        std.log.err("prompt: could not build marked-paths clipboard text: {t}", .{err});
                    }
                } else {
                    client.setClipboard(prompt.buffer.items) catch |err| {
                        std.log.err("prompt: set_clipboard (copy_request) failed: {t}", .{err});
                    };
                }
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
            // The explicit "never mind" key. If entries are marked, the
            // first Escape just clears the marks (and their highlight),
            // leaving you where you were; otherwise it snaps browsing back
            // to the prompt. Everything else that ends browsing (below)
            // does so as a side effect of also doing something.
            if (prompt.marks.items.len > 0) {
                try prompt.resetMarks();
            } else {
                try prompt.setCursorAt(prompt.cursor);
            }
        } else if (std.mem.eql(u8, ev.key, "space")) {
            // Space while browsing a listing toggles the entry under the
            // cursor in the multi-select mark set (Ctrl+click does the
            // same with the mouse). Ignored off the browse path -- a
            // literal space on the live line comes from the `.text` stream.
            if (prompt.browse_pos) |bp| try prompt.toggleHighlightAt(bp.row, bp.col, prompt.view_scroll);
        } else if (std.mem.eql(u8, ev.key, "tab")) {
            // Filename completion on the live line only -- Tab does
            // nothing while browsing scrollback.
            if (prompt.browse_pos == null) try prompt.doComplete();
        } else if (std.mem.eql(u8, ev.key, "backspace")) {
            try prompt.deleteBackward();
        } else if (std.mem.eql(u8, ev.key, "delete")) {
            try prompt.deleteForward();
        } else if (std.mem.eql(u8, ev.key, "home") and prompt.browse_pos != null) {
            // Home/End while browsing act on the scrollback row the browse
            // cursor is on (column 0 / just past its last non-blank cell),
            // staying in browse mode -- unlike ctrl+a / ctrl+e, which
            // still snap back to the live prompt in every state.
            try prompt.browseHome();
        } else if (std.mem.eql(u8, ev.key, "end") and prompt.browse_pos != null) {
            try prompt.browseEnd();
        } else if ((ctrl and std.mem.eql(u8, ev.key, "a")) or std.mem.eql(u8, ev.key, "home")) {
            // On the live line Home mirrors ctrl+a (go to column 0); via
            // `moveCursorTo` -> `setCursorAt` it also ends any browse and
            // snaps the view back to the live tail.
            try prompt.moveCursorTo(0);
        } else if ((ctrl and std.mem.eql(u8, ev.key, "e")) or std.mem.eql(u8, ev.key, "end")) {
            // End mirrors ctrl+e on the live line; the browse-mode form is
            // handled above.
            try prompt.moveCursorTo(prompt.buffer.items.len);
        } else if (ctrl and std.mem.eql(u8, ev.key, "u")) {
            try prompt.killToStart();
        } else if (ctrl and std.mem.eql(u8, ev.key, "l")) {
            try prompt.clearScreen();
        } else if (ctrl and std.mem.eql(u8, ev.key, "left")) {
            // While browsing, ctrl+left/right is a bigger horizontal step
            // (`scrollback_jump` columns), mirroring ctrl+up/down's row
            // jump -- it does not snap back to the prompt. On the live
            // line it's the word jump, which (via moveCursorTo ->
            // setCursorAt) ends any browse.
            if (prompt.browse_pos != null) {
                try prompt.browseLeft(prompt.scrollbackJumpRows());
            } else {
                try prompt.moveCursorTo(prompt.wordLeft());
            }
        } else if (ctrl and std.mem.eql(u8, ev.key, "right")) {
            if (prompt.browse_pos != null) {
                try prompt.browseRight(prompt.scrollbackJumpRows());
            } else {
                try prompt.moveCursorTo(prompt.wordRight());
            }
        } else if (ctrl and std.mem.eql(u8, ev.key, "up")) {
            // Ctrl+Up breaks into scrollback browse mode from the live
            // prompt (a one-row step off the input line); once browsing
            // it's a bigger jump (`scrollback_jump` rows, default 5) for
            // scanning a long listing faster.
            if (prompt.browse_pos != null) {
                try prompt.browseUp(prompt.scrollbackJumpRows());
            } else {
                try prompt.browseUp(1);
            }
        } else if (ctrl and std.mem.eql(u8, ev.key, "down")) {
            // The mirror jump while browsing. At the live prompt there's
            // nothing below the input line, so Ctrl+Down does nothing.
            if (prompt.browse_pos != null) try prompt.browseDown(prompt.scrollbackJumpRows());
        } else if (std.mem.eql(u8, ev.key, "up")) {
            // Plain Up: readline-style history recall at the prompt, a
            // one-row browse step while already in scrollback mode.
            if (prompt.browse_pos != null) {
                try prompt.browseUp(1);
            } else {
                try prompt.historyUp();
            }
        } else if (std.mem.eql(u8, ev.key, "down")) {
            if (prompt.browse_pos != null) {
                try prompt.browseDown(1);
            } else {
                try prompt.historyDown();
            }
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
                try prompt.browseLeft(1);
            } else {
                // Step a whole codepoint, not one byte: a CJK character is
                // three bytes but one cursor stop (see `lineedit`).
                try prompt.moveCursorTo(lineedit.prevBoundary(prompt.buffer.items, prompt.cursor));
            }
        } else if (std.mem.eql(u8, ev.key, "right")) {
            if (prompt.browse_pos != null) {
                try prompt.browseRight(1);
            } else if (prompt.cursor == prompt.buffer.items.len) {
                try prompt.acceptCompletionHintOrComplete();
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

/// The core builtins `dispatchLine` recognises by name (see the
/// precedence comment there). Offered by Tab completion in command
/// position alongside aliases and script builtins. `alias` is handled a
/// step earlier than the rest but is still a name worth completing.
const core_builtin_names = [_][]const u8{ "alias", "cd", "exit", "unalias" };

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

/// One marked `ls` entry -- the `kind` / `path` / `mimetype` fields
/// parsed out of a `HighlightState` entry's metadata blob (owned,
/// `client.alloc`). The mark set is rebuilt wholesale from every
/// `toggle_highlight` / `clear_highlight` response (`applyHighlight`); the
/// host owns which ids are highlighted and their on-screen tint.
const Mark = struct {
    path: []const u8,
    kind: []const u8,
    mimetype: ?[]const u8,
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
    /// Fish-style inline autocomplete hint: after the prompt has been idle
    /// for `autocomplete_idle_ms`, the first completion candidate's suffix
    /// is drawn in a dim colour after the caret. The real line buffer is
    /// unchanged; every edit hides the hint and arms a new idle delay.
    completion_hint: std.ArrayList(u8) = .empty,
    completion_hint_visible: bool = false,
    completion_hint_dirty: bool = true,
    completion_hint_activity_at: ?std.Io.Clock.Timestamp = null,
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
    /// Entries the user has marked for a multi-open (Ctrl+click, or Space
    /// while browsing). Empty most of the time. A marked set changes what
    /// a plain click / browse-Enter does (run the resolved `open_actions`
    /// command once over every marked path) and what Ctrl+Shift+C copies
    /// (the paths as one space-separated line). Cleared -- with its `set_highlight`
    /// overlay -- whenever a command runs, the window resizes, or Escape
    /// is pressed. Owned; freed in `deinit`.
    marks: std.ArrayList(Mark) = .empty,
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
        self.completion_hint.deinit(alloc);
        self.aliases.deinit(alloc);
        for (self.marks.items) |m| freeMark(alloc, m);
        self.marks.deinit(alloc);
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

    /// Rows a Ctrl+Up / Ctrl+Down jump covers while browsing scrollback
    /// (see `default_scrollback_jump`): `prompt.scrollback_jump` if set,
    /// else the default. Floored at 1 so a jump always moves.
    fn scrollbackJumpRows(self: *Prompt) usize {
        if (self.promptCfg()) |p| if (p.scrollback_jump) |n| return @max(@as(usize, n), 1);
        return default_scrollback_jump;
    }

    /// Whether typing a printable character while browsing scrollback
    /// ends browse mode and inserts it on the live line (the default),
    /// vs. being ignored until Escape. Config:
    /// `prompt{ scrollback_type_exits = false }`.
    fn scrollbackTypeExits(self: *Prompt) bool {
        if (self.promptCfg()) |p| if (p.scrollback_type_exits) |b| return b;
        return true;
    }

    /// Any real prompt edit or cursor move invalidates the displayed
    /// inline completion. The next idle tick recomputes it from the new
    /// buffer/cursor state.
    fn armCompletionHint(self: *Prompt) void {
        self.completion_hint_visible = false;
        self.completion_hint_dirty = true;
        self.completion_hint_activity_at = std.Io.Clock.Timestamp.now(self.client.io, .awake);
    }

    fn hideCompletionHint(self: *Prompt) void {
        self.completion_hint_visible = false;
        self.completion_hint_dirty = false;
        self.completion_hint.clearRetainingCapacity();
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

        var hint_end: usize = 0;
        var hint_w: usize = 0;
        if (self.completion_hint_visible and vis_end == buf.len) {
            const room = box_w -| w;
            const hint = self.completion_hint.items;
            while (hint_end < hint.len) {
                const nb = lineedit.nextBoundary(hint, hint_end);
                const cw = lineedit.cellWidth(hint[hint_end..nb]);
                if (hint_w + cw > room) break;
                hint_w += cw;
                hint_end = nb;
            }
        }

        var spaces: [1024]u8 = undefined;
        const fill_w = box_w -| (w + hint_w);
        const fill = @min(fill_w, spaces.len);
        @memset(spaces[0..fill], ' ');

        // Box repaint + caret placement go out as one `batch` frame, so
        // the host never renders an intermediate frame with the caret
        // parked at the box's left edge -- the brief caret "jump" seen on
        // a history recall or line swap otherwise. Same trick as
        // `drawRightChain`.
        var b = self.client.batch();
        defer b.deinit();
        try b.setCursor(row, left);
        if (visible.len > 0) try b.writeText(visible, null, null);
        if (hint_end > 0) try b.writeText(self.completion_hint.items[0..hint_end], autocomplete_hint_color, null);
        if (fill > 0) try b.writeText(spaces[0..fill], null, null);
        try b.setCursor(row, self.line_start_col + self.caretCol());
        var res = try b.send();
        res.deinit();

        // The dynamic right chain is its own `batch` frame (ending with
        // its own caret restore); it only redraws when configured.
        if (self.right_dynamic and self.prompt_lines == 1) self.drawRightChain() catch {};
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
        self.armCompletionHint();
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
        self.armCompletionHint();
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

        // Highlights are keyed by metadata id, so they (and `self.marks`)
        // carry across a resize untouched -- the tagged cells keep their
        // tags through the reflow.

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
        self.armCompletionHint();
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
        self.armCompletionHint();
        try self.renderInputLine();
    }

    /// Up at the prompt: recalls the previous (older) history entry, most
    /// recent first. The first press of a recall stashes the in-progress
    /// line in `scratch` so `historyDown` can get back to it later;
    /// further presses just walk `history_index` back, stopping at the
    /// oldest entry rather than wrapping.
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

    /// Down at the prompt: the mirror of `historyUp`. Walking past the newest entry
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
        self.armCompletionHint();
        try self.setCursorAt(self.cursor);
    }

    /// Deletes the codepoint at the cursor (forward delete).
    fn deleteForward(self: *Prompt) !void {
        if (self.cursor >= self.buffer.items.len) return;
        const end = lineedit.nextBoundary(self.buffer.items, self.cursor);
        try self.buffer.replaceRange(self.client.alloc, self.cursor, end - self.cursor, &.{});
        self.armCompletionHint();
        try self.setCursorAt(self.cursor);
    }

    /// ctrl+u: deletes from the start of the line through the cursor.
    fn killToStart(self: *Prompt) !void {
        if (self.cursor == 0) return;
        try self.buffer.replaceRange(self.client.alloc, 0, self.cursor, &.{});
        self.cursor = 0;
        self.armCompletionHint();
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

    /// Moves the cursor up into the scrollback above the prompt instead
    /// of editing anything. Ctrl+Up enters "browse" mode (`browse_pos`)
    /// from the live prompt with `count == 1`, starting directly above
    /// wherever the real cursor currently sits so it reads as "look
    /// straight up from here" rather than jumping to a fixed column;
    /// while already browsing, plain Up is `count == 1` and Ctrl+Up is
    /// `count == scrollbackJumpRows()` for scanning a long listing
    /// faster (see the key loop).
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
    /// down a row; Ctrl+Down (`count == scrollbackJumpRows()`) is a
    /// bigger step. Symmetric
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

    /// Left/Right while browsing: move `count` columns within whatever row
    /// the browse cursor is currently on, clamped to the grid's width
    /// (`set_property` doesn't clamp `col` itself -- see `Layer.setProperty`
    /// -- so an unclamped move here could park the caret off-grid). Plain
    /// Left/Right pass 1; ctrl+Left/Right pass `scrollbackJumpRows()` for a
    /// bigger step (matching ctrl+Up/Down while browsing). No-ops when not
    /// browsing; the caller is expected to check `browse_pos` first and
    /// call `moveCursorTo` instead (plain line editing) when it's null.
    fn browseLeft(self: *Prompt, count: usize) !void {
        var bp = self.browse_pos orelse return;
        bp.col -|= count;
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    fn browseRight(self: *Prompt, count: usize) !void {
        var bp = self.browse_pos orelse return;
        bp.col = @min(bp.col + count, self.grid_cols -| 1);
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    /// Home while browsing: move the browse cursor to column 0 of the row
    /// it's on, staying in browse mode. No-op when not browsing.
    fn browseHome(self: *Prompt) !void {
        var bp = self.browse_pos orelse return;
        bp.col = 0;
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    /// End while browsing: move the browse cursor just past the last
    /// non-blank cell of the row it's on (a fully blank row -> column 0),
    /// clamped to the grid width, staying in browse mode. No-op when not
    /// browsing. Costs one `get_cells` snapshot of the current view --
    /// acceptable on a key pressed this rarely; there's no lighter
    /// per-row text query on the wire.
    fn browseEnd(self: *Prompt) !void {
        var bp = self.browse_pos orelse return;
        bp.col = self.rowContentEnd(bp.row) catch bp.col;
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    /// The column just past the last non-blank cell of window row `row`
    /// as the view currently sits (`view_scroll`), clamped to
    /// `grid_cols - 1`. A blank row returns 0. Used by `browseEnd`.
    fn rowContentEnd(self: *Prompt, row: usize) !usize {
        var snap = try self.client.getCellsView(self.view_scroll);
        defer snap.deinit();
        if (row >= snap.rows()) return 0;

        const cols = snap.cols();
        var last_content: ?usize = null;
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const g = snap.cellAt(row, col).grapheme;
            if (std.mem.trim(u8, g, " ").len != 0) last_content = col;
        }
        const end = if (last_content) |lc| lc + 1 else 0;
        return @min(end, self.grid_cols -| 1);
    }

    /// Enter while browsing: looks up whatever cell the browse cursor is
    /// over and acts on it. With entries marked (Space / Ctrl+click), Enter
    /// runs the marked set (`runMarkedAction`); otherwise it acts on the
    /// single entry under the cursor (`activateSelectionAt`).
    fn browseEnter(self: *Prompt) !void {
        const bp = self.browse_pos orelse return;
        if (self.marks.items.len > 0) {
            try self.runMarkedAction();
        } else {
            try self.activateSelectionAt(bp.row, bp.col, self.view_scroll);
        }
    }

    /// The metadata blob glyphwire-ls tags every listed entry with (see
    /// `ls/main.zig`'s `entryMetadataJson`). `kind` and `path` are always
    /// present; `mimetype` only for a regular file.
    const MetaEntry = struct { kind: ?[]const u8 = null, path: ?[]const u8 = null, mimetype: ?[]const u8 = null };

    /// Parses the metadata at `(row, col)` in the view scrolled back by
    /// `view_offset`, or null if there's no tag there / it doesn't parse /
    /// it's missing `kind` or `path`. On success the caller must, in this
    /// order, `.parsed.deinit()` then free `.json` with `client.alloc`
    /// (the parsed strings can point into `json`).
    fn metaEntryAt(self: *Prompt, row: usize, col: usize, view_offset: usize) ?struct {
        json: []u8,
        parsed: std.json.Parsed(MetaEntry),
    } {
        const alloc = self.client.alloc;
        const lookup = self.client.getMetadata(null, row, col, view_offset) catch return null;
        const json = lookup.json orelse return null;
        const parsed = std.json.parseFromSlice(MetaEntry, alloc, json, .{ .ignore_unknown_fields = true }) catch {
            alloc.free(json);
            return null;
        };
        if (parsed.value.kind == null or parsed.value.path == null) {
            parsed.deinit();
            alloc.free(json);
            return null;
        }
        return .{ .json = json, .parsed = parsed };
    }

    /// Resolves the `open_actions` command for one entry and runs it as if
    /// typed. The user's `shell.conf` table is checked first, then the
    /// built-in defaults (`cd` into a directory, `glyphwire-view` an
    /// image) -- see `shell/openaction.zig`. A no-op when nothing matches,
    /// per the "don't guess" policy: an unrecognized file type does
    /// nothing rather than guessing. `setLine` echoes the command and,
    /// via `setCursorAt`, ends any browsing / snaps the view back to the
    /// live tail before `submitLine` runs it -- the same path a typed
    /// command takes, so e.g. `glyphwire-view`'s "wait for a keypress"
    /// blocks the prompt loop exactly as it would for a real command.
    ///
    /// `view_offset` is how far the host was scrolled back when
    /// `(row, col)` was picked -- forwarded to `get_metadata` so a click
    /// on a scrolled-back row resolves against the cell actually there.
    fn activateSelectionAt(self: *Prompt, row: usize, col: usize, view_offset: usize) !void {
        const alloc = self.client.alloc;

        const got = self.metaEntryAt(row, col, view_offset) orelse return;
        defer alloc.free(got.json);
        defer got.parsed.deinit();

        const line = self.openActionLine(alloc, &.{.{
            .kind = got.parsed.value.kind.?,
            .path = got.parsed.value.path.?,
            .mimetype = got.parsed.value.mimetype,
        }}) catch return orelse return;
        defer alloc.free(line);

        try self.setLine(line);
        try self.submitLine();
    }

    /// The command line to run for `entries` (one or more), or null when
    /// no `open_actions` entry / default matches the first entry's type.
    /// The first entry decides which action runs; `{sel}` / `{selections}`
    /// in its template expand to the shell-quoted path(s) -- a `{sel}`
    /// template given more than one entry surfaces an error line and
    /// returns null (nothing runs). Owned result; free with `alloc`.
    fn openActionLine(self: *Prompt, alloc: std.mem.Allocator, entries: []const openaction.Entry) !?[]u8 {
        std.debug.assert(entries.len >= 1);
        const user: []const openaction.Action = if (self.prompt_config) |pc| pc.open_actions.items else &.{};
        const action = openaction.resolve(user, entries[0]) orelse return null;

        const paths = try alloc.alloc([]const u8, entries.len);
        defer alloc.free(paths);
        for (entries, paths) |e, *p| p.* = e.path;

        return openaction.expand(alloc, action.commands[0], paths) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NeedsSingle => {
                try self.client.writeText(
                    "glyphwire-shell: that action opens one file at a time\n",
                    .{ .r = 255, .g = 85, .b = 85 },
                    null,
                );
                return null;
            },
        };
    }

    // ── Multi-select marks ─────────────────────────────────────────────

    fn freeMark(alloc: std.mem.Allocator, m: Mark) void {
        alloc.free(m.path);
        alloc.free(m.kind);
        if (m.mimetype) |mt| alloc.free(mt);
    }

    /// Frees every mark and empties the list -- local only, no wire
    /// traffic. `applyHighlight` and `deinit` use it.
    fn clearMarks(self: *Prompt) void {
        const alloc = self.client.alloc;
        for (self.marks.items) |m| freeMark(alloc, m);
        self.marks.clearRetainingCapacity();
    }

    /// Rebuilds `self.marks` from a `HighlightState` the host just sent
    /// back (`toggle_highlight` / `clear_highlight` / `set_highlight`
    /// response). Each entry carries the highlighted id's metadata blob;
    /// an entry with no blob, or one missing `kind`/`path`, is skipped.
    fn applyHighlight(self: *Prompt, snap: *const glyphwire.HighlightSnapshot) !void {
        const alloc = self.client.alloc;
        self.clearMarks();
        for (snap.entries()) |e| {
            const json = e.json orelse continue;
            const parsed = std.json.parseFromSlice(MetaEntry, alloc, json, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const kind = parsed.value.kind orelse continue;
            const path = parsed.value.path orelse continue;

            const path_owned = try alloc.dupe(u8, path);
            errdefer alloc.free(path_owned);
            const kind_owned = try alloc.dupe(u8, kind);
            errdefer alloc.free(kind_owned);
            const mime_owned: ?[]const u8 = if (parsed.value.mimetype) |mt| try alloc.dupe(u8, mt) else null;
            errdefer if (mime_owned) |mt| alloc.free(mt);

            try self.marks.append(alloc, .{ .path = path_owned, .kind = kind_owned, .mimetype = mime_owned });
        }
    }

    /// Toggles the `ls` entry at `(row, col)` in the host's highlight set
    /// (`toggle_highlight`) and rebuilds `self.marks` from the response.
    /// The host resolves the cell to a metadata id, flood-fills it, and
    /// hands back every highlighted id with its blob -- the shell does no
    /// grid scanning of its own.
    fn toggleHighlightAt(self: *Prompt, row: usize, col: usize, view_offset: usize) !void {
        var snap = try self.client.toggleHighlight(null, row, col, view_offset);
        defer snap.deinit();
        try self.applyHighlight(&snap);
    }

    /// Clears the marks and the host's highlight overlay
    /// (`clear_highlight`). A no-op (no wire message) when nothing was
    /// marked.
    fn resetMarks(self: *Prompt) !void {
        if (self.marks.items.len == 0) return;
        var snap = try self.client.clearHighlight(null);
        defer snap.deinit();
        try self.applyHighlight(&snap);
    }

    /// The marked entries' paths as one line -- space-separated, in mark
    /// order, each path passed through `wordsplit.quoteArgIfNeeded` so a
    /// plain path stays bare and one with a space or a metacharacter is
    /// quoted. This is what Ctrl+Shift+C copies while a listing has marks;
    /// pasting it after a command name (`ls `, `cp ... `) gives a valid
    /// argument list. Owned; free with `alloc`.
    fn markedPathsText(self: *Prompt, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        for (self.marks.items, 0..) |m, i| {
            if (i > 0) try out.append(alloc, ' ');
            const tok = try wordsplit.quoteArgIfNeeded(alloc, m.path);
            defer alloc.free(tok);
            try out.appendSlice(alloc, tok);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Runs the `open_actions` command for the marked entries as one
    /// command line (the first mark's type picks the action, every marked
    /// path is passed). Marks and their highlight are dropped by
    /// `submitLine`. A no-op if nothing resolves.
    fn runMarkedAction(self: *Prompt) !void {
        if (self.marks.items.len == 0) return;
        const alloc = self.client.alloc;

        const entries = try alloc.alloc(openaction.Entry, self.marks.items.len);
        defer alloc.free(entries);
        for (self.marks.items, entries) |m, *e| {
            e.* = .{ .kind = m.kind, .path = m.path, .mimetype = m.mimetype };
        }

        const line = (try self.openActionLine(alloc, entries)) orelse return;
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
        // Running any command spends the multi-select: drop the marks and
        // their highlight before the command's output scrolls in.
        try self.resetMarks();

        if (self.completion_hint_visible) {
            self.hideCompletionHint();
            try self.renderInputLine();
        }

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

    /// Runs whatever the just-committed line (`self.buffer`) names.
    ///
    /// The line goes through `parse.parse` first (pipes, redirects,
    /// `&&` / `||` / `;`). A *bare* command -- one stage, no redirects --
    /// keeps the original PTY-backed path (`dispatchBareCommand` ->
    /// `runCommand`): interactive full-screen programs, the glyphwire
    /// handshake and `{dur}` timing all depend on it. Anything with an
    /// operator runs through the pipe-based executor (`runLine` ->
    /// `runPipeline`). `alias NAME=VALUE` is still handled off the raw
    /// line ahead of the parser -- its value has rest-of-line semantics
    /// (`wordsplit.parseAliasDef`) the tokenizer would destroy.
    ///
    /// Within each command: quote-aware splitting, then alias expansion
    /// (`expandAliases`), then `*` globs (`expandGlobs`), then
    /// builtin / `$PATH` dispatch -- bash order. A core or script builtin
    /// (`cd`, `exit`, a `defcmd`) works as a whole stage in an
    /// `&&` / `||` / `;` chain, but not as one stage of a `|` pipeline
    /// (see `runPipeline`).
    fn dispatchLine(self: *Prompt) !void {
        const alloc = self.client.alloc;
        const trimmed = std.mem.trimStart(u8, self.buffer.items, " \t");

        if (std.mem.startsWith(u8, trimmed, "alias") and
            (trimmed.len == "alias".len or trimmed["alias".len] == ' ' or trimmed["alias".len] == '\t'))
        {
            return self.doAlias(self.buffer.items);
        }

        switch (try parse.parse(alloc, self.buffer.items)) {
            .err => |msg| {
                defer alloc.free(msg);
                try self.client.writeText(msg, err_color, null);
                self.last_status = 2;
                self.last_dur_ms = 0;
                self.have_status = true;
            },
            .ok => |ok_line| {
                var line = ok_line;
                defer line.deinit();
                if (line.segments.len == 0) return; // blank / whitespace only

                if (line.isBareCommand()) {
                    try self.dispatchBareCommand(line.segments[0].pipeline.commands[0]);
                    return;
                }

                const started = std.Io.Clock.Timestamp.now(self.client.io, .awake);
                const status = try self.runLine(line);
                const elapsed_ms = started.untilNow(self.client.io).raw.toMilliseconds();
                self.last_status = status;
                self.last_dur_ms = if (elapsed_ms > 0) @intCast(elapsed_ms) else 0;
                self.have_status = true;
            },
        }
    }

    /// The bare-command path: the pre-pipeline dispatch, unchanged in
    /// behavior from before pipelines existed. `cmd` is always a single
    /// stage with no redirects (`Line.isBareCommand`).
    fn dispatchBareCommand(self: *Prompt, cmd: parse.Command) !void {
        const alloc = self.client.alloc;

        var args = try alloc.alloc(wordsplit.Arg, cmd.words.len);
        defer alloc.free(args);
        for (cmd.words, cmd.quoted, 0..) |w, q, i| args[i] = .{ .text = w, .quoted = q };

        const expanded = try self.expandAliases(args);
        defer wordsplit.freeArgs(alloc, expanded);
        if (expanded.len == 0) return;

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

    /// Walks a parsed line's segments left to right, running each
    /// pipeline whose `&&` / `||` / `;` link permits it given the running
    /// exit status. Returns the status of the last pipeline actually run
    /// (0 if a chain short-circuited before running anything). Interactive
    /// path only -- `sh.run` / `sh.exec` drive `runPipeline` directly.
    fn runLine(self: *Prompt, line: parse.Line) !u8 {
        var status: u8 = 0;
        for (line.segments) |seg| {
            const run = switch (seg.sep) {
                .first, .semi => true,
                .and_then => status == 0,
                .or_else => status != 0,
            };
            if (!run) continue;
            status = try self.runPipeline(seg.pipeline, .interactive);
            if (self.should_exit) return status;
        }
        return status;
    }

    /// Where a running pipeline's output goes and where its stdin / Ctrl-C
    /// come from.
    const PipeSink = union(enum) {
        /// A typed line: mirror stdout+stderr to the grid, forward
        /// `Prompt.listener` keystrokes to stage 0, Ctrl-C -> SIGINT.
        interactive,
        /// `sh.exec("...")`: mirror to the grid, stdin is `/dev/null`, no
        /// keystroke forwarding; Ctrl-C still interrupts.
        script_grid,
        /// `sh.run("...")`: collect stdout / stderr into buffers, feed
        /// `stdin` to stage 0 then close it.
        capture: *Capture,
    };

    const Capture = struct {
        out: *std.ArrayList(u8),
        err_buf: *std.ArrayList(u8),
        stdin: []const u8,
    };

    /// Runs one `|`-pipeline. A single-stage pipeline naming a builtin is
    /// dispatched in-process (so `cd x && ls` works); a builtin as one
    /// stage of a real `|` pipeline is rejected with a message (see
    /// docs/decisions.md, Shell). Everything else -- one external command
    /// with redirects, or two-plus stages -- goes to `pipeexec.spawn`.
    /// Returns the last stage's exit status (bash semantics, no
    /// `pipefail`).
    fn runPipeline(self: *Prompt, pl: parse.Pipeline, sink: PipeSink) !u8 {
        const alloc = self.client.alloc;

        if (pl.commands.len == 1) {
            const argv = try self.resolveArgv(pl.commands[0]);
            defer wordsplit.freeTokens(alloc, argv);
            if (argv.len == 0) return 0;
            if (self.isBuiltinName(argv[0])) {
                // Redirects on a builtin are parsed but not applied in v1.
                return self.runBuiltin(argv);
            }
            return self.spawnAndPump(pl.commands, &.{argv}, sink);
        }

        var argvs = try alloc.alloc([]const []const u8, pl.commands.len);
        for (argvs) |*a| a.* = &.{};
        defer {
            for (argvs) |a| wordsplit.freeTokens(alloc, a);
            alloc.free(argvs);
        }
        for (pl.commands, 0..) |cmd, i| {
            argvs[i] = try self.resolveArgv(cmd);
            if (argvs[i].len == 0) {
                try self.client.writeText("pipeline: empty command", err_color, null);
                return 2;
            }
            if (self.isBuiltinName(argvs[i][0])) {
                var buf: [160]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "{s}: not supported inside a pipeline", .{argvs[i][0]}) catch
                    "builtin not supported inside a pipeline";
                try self.client.writeText(m, err_color, null);
                return 2;
            }
        }
        return self.spawnAndPump(pl.commands, argvs, sink);
    }

    /// alias-expands then glob-expands one parsed command into an owned
    /// argv (`wordsplit.freeTokens` to free). The per-token "quoted" flag
    /// is carried into `expandGlobs` so a quoted `*` stays literal.
    fn resolveArgv(self: *Prompt, cmd: parse.Command) ![]const []const u8 {
        const alloc = self.client.alloc;
        var args = try alloc.alloc(wordsplit.Arg, cmd.words.len);
        defer alloc.free(args);
        for (cmd.words, cmd.quoted, 0..) |w, q, i| args[i] = .{ .text = w, .quoted = q };

        const expanded = try self.expandAliases(args);
        defer wordsplit.freeArgs(alloc, expanded);
        return self.expandGlobs(expanded);
    }

    fn isBuiltinName(self: *Prompt, name: []const u8) bool {
        if (std.mem.eql(u8, name, "exit") or std.mem.eql(u8, name, "unalias") or
            std.mem.eql(u8, name, "cd") or std.mem.eql(u8, name, "alias")) return true;
        if (self.script_engine) |eng| return eng.hasCommand(name);
        return false;
    }

    /// Dispatches a builtin that is the sole stage of its pipeline. `cd` /
    /// `unalias` report their own errors onto the grid and are treated as
    /// status 0 here; `alias` mid-chain isn't supported (its rest-of-line
    /// value is already gone by parse time).
    fn runBuiltin(self: *Prompt, argv: []const []const u8) !u8 {
        if (std.mem.eql(u8, argv[0], "exit")) {
            self.should_exit = true;
            return 0;
        }
        if (std.mem.eql(u8, argv[0], "unalias")) {
            try self.doUnalias(argv[1..]);
            return 0;
        }
        if (std.mem.eql(u8, argv[0], "cd")) {
            try self.doCd(argv[1..]);
            return 0;
        }
        if (std.mem.eql(u8, argv[0], "alias")) {
            try self.client.writeText("alias: only supported as a standalone command", err_color, null);
            return 2;
        }
        if (self.script_engine) |eng| {
            if (eng.hasCommand(argv[0])) return eng.runCommand(argv[0], argv[1..]);
        }
        return 127;
    }

    /// Builds `pipeexec.Stage`s for `commands` (already resolved to
    /// `argvs`), spawns them, and pumps output / input / Ctrl-C until the
    /// last stage exits. All heap scratch is freed before returning; the
    /// children hold their own copies. Reports a spawn failure onto the
    /// grid and returns 127.
    fn spawnAndPump(
        self: *Prompt,
        commands: []const parse.Command,
        argvs: []const []const []const u8,
        sink: PipeSink,
    ) !u8 {
        const alloc = self.client.alloc;
        const n = commands.len;

        // NUL-terminated strings referenced by the argv arrays and the
        // redirect targets; freed after the spawn.
        var zbufs: std.ArrayList([:0]u8) = .empty;
        defer {
            for (zbufs.items) |b| alloc.free(b);
            zbufs.deinit(alloc);
        }
        var argv_arrays: std.ArrayList([]?[*:0]const u8) = .empty;
        defer {
            for (argv_arrays.items) |a| alloc.free(a);
            argv_arrays.deinit(alloc);
        }
        var redir_store: std.ArrayList(pipeexec.Redir) = .empty;
        defer redir_store.deinit(alloc);
        var redir_counts = try alloc.alloc(usize, n);
        defer alloc.free(redir_counts);

        const stages = try alloc.alloc(pipeexec.Stage, n);
        defer alloc.free(stages);

        for (commands, argvs, 0..) |cmd, argv, i| {
            const arr = try alloc.alloc(?[*:0]const u8, argv.len + 1);
            try argv_arrays.append(alloc, arr);
            for (argv, 0..) |a, k| {
                const exp = self.expandTilde(a) catch a;
                const z = try alloc.dupeZ(u8, exp);
                if (exp.ptr != a.ptr) alloc.free(exp);
                try zbufs.append(alloc, z);
                arr[k] = z.ptr;
            }
            arr[argv.len] = null;

            redir_counts[i] = cmd.redirs.len;
            for (cmd.redirs) |r| {
                const pr = (try self.resolveRedir(r, &zbufs)) orelse return 2;
                try redir_store.append(alloc, pr);
            }
            stages[i] = .{ .argv = @ptrCast(arr.ptr), .redirs = &.{} };
        }
        // Slice the flat redirect store per stage now that no more
        // appends can move it.
        {
            var off: usize = 0;
            for (stages, 0..) |*s, i| {
                s.redirs = redir_store.items[off..][0..redir_counts[i]];
                off += redir_counts[i];
            }
        }

        // stage-0 stdin: a pipe (write end kept for keystrokes / a fed
        // string) for the interactive and capture sinks; `/dev/null` for
        // `sh.exec`.
        var devnull_fd: c_int = -1;
        const stage0_stdin: i32 = switch (sink) {
            .script_grid => blk: {
                devnull_fd = c.open("/dev/null", 0, 0);
                break :blk devnull_fd;
            },
            else => -1,
        };

        var sp = pipeexec.spawn(alloc, stages, .{ .stage0_stdin = stage0_stdin }) catch |e| {
            if (devnull_fd >= 0) _ = c.close(devnull_fd);
            const m = switch (e) {
                error.Unsupported => "pipelines need Linux",
                error.OutOfMemory => return error.OutOfMemory,
                else => "pipeline: could not start",
            };
            try self.client.writeText(m, err_color, null);
            return 127;
        };
        if (devnull_fd >= 0) _ = c.close(devnull_fd); // the child dup'd it
        defer sp.deinit(alloc);

        try self.pumpPipeline(&sp, sink);
        return sp.exit_code;
    }

    /// Turns a parsed redirect into a `pipeexec.Redir`. Resolves a `~`
    /// and (for an unquoted target) a single glob match; a multi-match
    /// glob is an "ambiguous redirect" reported onto the grid, and the
    /// function returns null to mean "abort this pipeline". The target's
    /// NUL-terminated storage is appended to `zbufs`.
    fn resolveRedir(
        self: *Prompt,
        r: parse.Redir,
        zbufs: *std.ArrayList([:0]u8),
    ) !?pipeexec.Redir {
        const alloc = self.client.alloc;
        if (r.mode == .dup) {
            return .{ .fd = r.fd, .mode = .dup, .dup_fd = r.dup_fd };
        }

        const tilded = self.expandTilde(r.path) catch r.path;
        defer if (tilded.ptr != r.path.ptr) alloc.free(tilded);

        var chosen: []const u8 = tilded;
        var matched: ?[]const []const u8 = null;
        defer if (matched) |m| wordsplit.freeTokens(alloc, m);
        if (!r.path_quoted and glob.hasWildcard(tilded)) {
            const one = [_]wordsplit.Arg{.{ .text = tilded, .quoted = false }};
            const m = try self.expandGlobs(&one);
            matched = m;
            if (m.len > 1) {
                try self.client.writeText("ambiguous redirect", err_color, null);
                return null;
            }
            if (m.len == 1) chosen = m[0];
        }

        const z = try alloc.dupeZ(u8, chosen);
        try zbufs.append(alloc, z);
        return .{
            .fd = r.fd,
            .mode = switch (r.mode) {
                .read => .read,
                .write => .write,
                .append => .append,
                .dup => unreachable,
            },
            .path = z.ptr,
            .also_stderr = r.also_stderr,
        };
    }

    /// Drives a spawned pipeline to completion: drains its stdout / stderr
    /// pipes onto the grid (or into capture buffers), feeds stdin, and
    /// turns Ctrl-C into a group SIGINT. Non-blocking `poll` throughout so
    /// output appears as it happens; a 20 ms poll timeout paces the
    /// non-interactive sinks and `listener.waitInputEvent` paces the
    /// interactive one.
    fn pumpPipeline(self: *Prompt, sp: *pipeexec.Spawned, sink: PipeSink) !void {
        var buf: [4096]u8 = undefined;

        var stdin_rest: []const u8 = switch (sink) {
            .capture => |cap| cap.stdin,
            else => &.{},
        };
        if (sink == .capture and stdin_rest.len == 0 and sp.stdin_w >= 0) {
            _ = c.close(sp.stdin_w);
            sp.stdin_w = -1;
        }

        while (true) {
            _ = self.drainPipeOnce(sp, sink, &buf, 0);

            switch (sink) {
                .interactive => {
                    if (try self.forwardKeystroke(sp)) sp.signal(std.posix.SIG.INT);
                },
                .capture => {
                    if (stdin_rest.len > 0 and sp.stdin_w >= 0) {
                        const w = c.write(sp.stdin_w, stdin_rest.ptr, stdin_rest.len);
                        if (w > 0) stdin_rest = stdin_rest[@intCast(w)..];
                        if (w < 0 or stdin_rest.len == 0) {
                            _ = c.close(sp.stdin_w);
                            sp.stdin_w = -1;
                        }
                    }
                    if (self.pollPipeInterrupt()) sp.signal(std.posix.SIG.INT);
                },
                .script_grid => {
                    if (self.pollPipeInterrupt()) sp.signal(std.posix.SIG.INT);
                },
            }

            if (sp.reapAll()) {
                // Every writer is gone: the pipes EOF promptly. Flush
                // what's buffered and stop.
                while (sp.stdout_r >= 0 or sp.stderr_r >= 0) {
                    if (!self.drainPipeOnce(sp, sink, &buf, 50)) break;
                }
                break;
            }

            if (sink != .interactive) {
                // A plain sleep when there's nothing to read (all fds
                // redirected to files); `poll` with a timeout doubles as
                // one even with an empty set.
                var pf: [2]std.posix.pollfd = undefined;
                var nf: usize = 0;
                if (sp.stdout_r >= 0) {
                    pf[nf] = .{ .fd = sp.stdout_r, .events = std.posix.POLL.IN, .revents = 0 };
                    nf += 1;
                }
                if (sp.stderr_r >= 0) {
                    pf[nf] = .{ .fd = sp.stderr_r, .events = std.posix.POLL.IN, .revents = 0 };
                    nf += 1;
                }
                _ = std.posix.poll(pf[0..nf], 20) catch 0;
            }
        }
    }

    /// One non-blocking drain of `sp`'s stdout / stderr read ends.
    /// `timeout_ms` is passed to `poll` (0 for a pure poll). Returns true
    /// if it read any bytes -- the post-exit flush loop uses that to know
    /// when the pipes are truly empty.
    fn drainPipeOnce(
        self: *Prompt,
        sp: *pipeexec.Spawned,
        sink: PipeSink,
        buf: *[4096]u8,
        timeout_ms: i32,
    ) bool {
        var pf: [2]std.posix.pollfd = undefined;
        var slot: [2]i32 = undefined;
        var nf: usize = 0;
        if (sp.stdout_r >= 0) {
            pf[nf] = .{ .fd = sp.stdout_r, .events = std.posix.POLL.IN, .revents = 0 };
            slot[nf] = 1;
            nf += 1;
        }
        if (sp.stderr_r >= 0) {
            pf[nf] = .{ .fd = sp.stderr_r, .events = std.posix.POLL.IN, .revents = 0 };
            slot[nf] = 2;
            nf += 1;
        }
        if (nf == 0) return false;

        _ = std.posix.poll(pf[0..nf], timeout_ms) catch return false;

        var read_any = false;
        for (pf[0..nf], slot[0..nf]) |p, which| {
            if (p.revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) == 0) continue;
            const fd = if (which == 1) sp.stdout_r else sp.stderr_r;
            if (fd < 0) continue;
            const nr = c.read(fd, buf, buf.len);
            if (nr <= 0) {
                _ = c.close(fd);
                if (which == 1) sp.stdout_r = -1 else sp.stderr_r = -1;
                continue;
            }
            read_any = true;
            const chunk = buf[0..@intCast(nr)];
            switch (sink) {
                .capture => |cap| {
                    const dst = if (which == 2) cap.err_buf else cap.out;
                    dst.appendSlice(self.client.alloc, chunk) catch {};
                },
                else => self.client.writeText(chunk, null, null) catch {},
            }
        }
        return read_any;
    }

    /// Interactive pipeline stdin: waits briefly for one input event and
    /// forwards it to stage 0. Returns true if the event was Ctrl-C (the
    /// caller SIGINTs the group); Ctrl-D closes stage 0's stdin. Simpler
    /// than `runCommand`'s pty loop -- no mode tracking, mouse or resize,
    /// since a pipe has no line discipline to match.
    fn forwardKeystroke(self: *Prompt, sp: *pipeexec.Spawned) !bool {
        const listener = self.listener orelse return false;
        const alloc = self.client.alloc;

        const ev = (listener.waitInputEvent(.{
            .duration = .{ .raw = .fromMilliseconds(25), .clock = .awake },
        }) catch null) orelse return false;

        switch (ev) {
            .text => |tev| {
                defer alloc.free(tev.text);
                if (sp.stdin_w >= 0) _ = c.write(sp.stdin_w, tev.text.ptr, tev.text.len);
                return false;
            },
            .paste => |tev| {
                defer alloc.free(tev.text);
                if (sp.stdin_w >= 0) _ = c.write(sp.stdin_w, tev.text.ptr, tev.text.len);
                return false;
            },
            .copy_request => return false,
            .key => |kev| {
                defer alloc.free(kev.key);
                if (!kev.pressed) return false;
                const ctrl = listener.isKeyDown("left_control") or listener.isKeyDown("right_control");
                if (ctrl and std.mem.eql(u8, kev.key, "c")) return true;
                if (ctrl and std.mem.eql(u8, kev.key, "d")) {
                    if (sp.stdin_w >= 0) {
                        _ = c.close(sp.stdin_w);
                        sp.stdin_w = -1;
                    }
                    return false;
                }
                const mods = keyencode.Mods{
                    .ctrl = ctrl,
                    .shift = listener.isKeyDown("left_shift") or listener.isKeyDown("right_shift"),
                    .alt = listener.isKeyDown("left_alt") or listener.isKeyDown("right_alt"),
                };
                // A plain printable key already arrived as `.text`.
                if (!mods.ctrl and !mods.alt and keyencode.charFromKeyName(kev.key, false) != null)
                    return false;
                var kb: [8]u8 = undefined;
                if (keyencode.toPtyBytes(kev.key, mods, .normal, &kb)) |seq| {
                    if (sp.stdin_w >= 0) _ = c.write(sp.stdin_w, seq.ptr, seq.len);
                }
                return false;
            },
        }
    }

    /// Drains pending input events (dropped as type-ahead) while a
    /// non-interactive pipeline runs, returning true the moment it sees
    /// Ctrl-C -- the same shape as `hookPollInterrupt`.
    fn pollPipeInterrupt(self: *Prompt) bool {
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
            .paste => |tev| self.client.alloc.free(tev.text),
            .copy_request => {},
        };
        return hit;
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

        // Sniffed from the child's own output by the reader thread; read
        // by the key/mouse encoding below to match the modes the child
        // turned on (application cursor keys, bracketed paste, mouse
        // reporting). See `glyphwire.ModeTracker`.
        var modes: ModeTracker = .{};

        var reader_ctx = PtyReaderCtx{ .prompt = self, .master = pty.master, .modes = &modes };
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
            // Terminal resize -> SIGWINCH the child (via the kernel line
            // discipline). Coalesced: only the final size matters.
            var new_size: ?glyphwire.ResizeEvent = null;
            while (listener.pollResizeEvent()) |rev| new_size = rev;
            if (new_size) |rev| pty.resize(@intCast(rev.cols), @intCast(rev.rows));

            // Once the handshake resolves an aware child, it's drawing
            // over its own wire connection and never reads its own stdin
            // -- forwarding anything into its pty would just sit unread
            // or, worse, come back as a kernel-line-discipline echo (the
            // pty's termios is never put in raw/no-echo mode for it) that
            // the block below would then pass straight through to this
            // process's own real stdout as if the child had printed it.
            const is_aware = awareState(&reader_ctx) orelse false;

            // Mouse: encode to the child when it asked for reporting,
            // otherwise drain the queues so `InputListener` doesn't sit
            // full while a command runs.
            if (!is_aware) pumpPtyMouse(alloc, listener, &pty, &modes);

            // Terminal query replies (`CSI 6n` / DA / DECRQM) the host
            // parsed out of the child's own output on the way to the grid.
            while (listener.pollTerminalReply()) |reply| {
                defer alloc.free(reply);
                if (!is_aware) pty.writeAll(reply);
            }

            // Poll faster while a mouse-mode TUI is foregrounded so
            // pointer motion isn't a frame behind; the plain case stays
            // lazy.
            const wait_ms: i64 = if (modes.mouseReporting()) 16 else 120;
            const input_ev = (listener.waitInputEvent(.{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } }) catch null) orelse continue;

            if (is_aware) {
                switch (input_ev) {
                    .text => |tev| alloc.free(tev.text),
                    .paste => |tev| alloc.free(tev.text),
                    .key => |kev| alloc.free(kev.key),
                    .copy_request => {},
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
            const cursor_mode: keyencode.CursorKeyMode = if (modes.appCursor()) .application else .normal;
            var kb: [8]u8 = undefined;
            if (keyencode.toPtyBytes(ev.key, mods, cursor_mode, &kb)) |seq| pty.writeAll(seq);
        }

        // Child reaped -> its slave is closed -> the reader's next master
        // read returns EOF/EIO and the thread exits on its own.
        reader.join();

        // Undo the screen state a program that died without cleaning up
        // could leave behind: `?1049l` exits the alt screen, then `! p`
        // (DECSTR soft reset) puts the scroll region back to full and
        // un-hides the caret without moving the cursor or clearing
        // anything. Both are no-ops if the program already reset them.
        // This matters for `less -X` / `bat` / git's default pager, which
        // set a bottom-margin scroll region on the *primary* screen (no
        // alt screen) and would otherwise leave `regionActive()` stuck,
        // freezing scrollback and making the host wheel page the shell.
        self.client.writeText("\x1b[?1049l\x1b[!p", null, null) catch {};
    }

    /// Context for `ptyReaderThread`. `master` is owned by `runCommand`
    /// (which closes it after the thread joins); the thread only reads it.
    const PtyReaderCtx = struct {
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
    };

    fn awareState(ctx: *const PtyReaderCtx) ?bool {
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

            // Watch for `ESC [ ? ... h/l` the child emits regardless of
            // whether we're mirroring it or handing it to an aware child
            // (aware output is wire JSON -- no such sequences, harmless).
            ctx.modes.feed(chunk);

            if (aware == null) {
                pending.appendSlice(alloc, chunk) catch break;
                aware = hs.aware(pending.items);
                if (aware == null) continue; // still a prefix of the marker
                ctx.aware.store(if (aware.?) 1 else 2, .release);
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
            .run_line = hookRunLine,
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

    /// Loads `~/.config/glyphwire/history` into `self.history` so Up-arrow
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
        self.armCompletionHint();
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

        const line = self.buffer.items;
        const wr = complete.wordRange(line, self.cursor);
        const word = line[wr.start..self.cursor];
        const dp = complete.dirPrefix(word);

        var cands: std.ArrayList(CompletionCandidate) = .empty;
        defer {
            for (cands.items) |cand| alloc.free(cand.name);
            cands.deinit(alloc);
        }
        try self.collectCompletionCandidates(&cands, line, wr, dp);
        if (cands.items.len == 0) return;

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

    /// Appends the command-position names matching `prefix` to `cands`
    /// (which already holds the cwd filesystem matches): the `alias`
    /// bindings, the core builtins (`core_builtin_names`), and the script
    /// builtins (`ScriptEngine.collectCommandNames` -- `defcmd` names plus
    /// `~/.config/glyphwire/scripts/*.lua`). A name already in `cands`
    /// (from the directory scan or an earlier source here) is skipped, so
    /// a script and a like-named file are offered once. All get
    /// `is_dir = false`; `doComplete` sorts the merged list.
    fn appendCommandNameCandidates(
        self: *Prompt,
        cands: *std.ArrayList(CompletionCandidate),
        prefix: []const u8,
    ) !void {
        const alloc = self.client.alloc;

        const push = struct {
            fn f(a: std.mem.Allocator, list: *std.ArrayList(CompletionCandidate), name: []const u8) !void {
                for (list.items) |cand| {
                    if (std.mem.eql(u8, cand.name, name)) return;
                }
                try list.append(a, .{ .name = try a.dupe(u8, name), .is_dir = false });
            }
        }.f;

        for (core_builtin_names) |name| {
            if (std.mem.startsWith(u8, name, prefix)) try push(alloc, cands, name);
        }

        var ai = self.aliases.map.keyIterator();
        while (ai.next()) |key| {
            if (std.mem.startsWith(u8, key.*, prefix)) try push(alloc, cands, key.*);
        }

        if (self.script_engine) |eng| {
            var names: std.ArrayList([]const u8) = .empty;
            defer {
                for (names.items) |n| alloc.free(n);
                names.deinit(alloc);
            }
            try eng.collectCommandNames(alloc, prefix, &names);
            for (names.items) |n| try push(alloc, cands, n);
        }
    }

    /// Gathers the same sorted candidate set used by Tab completion. The
    /// inline hint path calls this too, so a dim suggestion agrees with
    /// what pressing Tab would consider completions for the current word.
    fn collectCompletionCandidates(
        self: *Prompt,
        cands: *std.ArrayList(CompletionCandidate),
        line: []const u8,
        wr: complete.WordRange,
        dp: complete.DirPrefix,
    ) !void {
        const alloc = self.client.alloc;
        const io = self.client.io;

        const scan_dir = try self.completionDir(dp.dir);
        defer alloc.free(scan_dir);

        if (std.Io.Dir.cwd().openDir(io, scan_dir, .{ .iterate = true })) |*dir| {
            defer dir.close(io);
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
        } else |_| {}

        // In command position (`argv[0]`, no `dir/` part) completion also
        // offers the names the plain directory scan can't see: aliases,
        // core builtins, and script builtins.
        if (dp.dir.len == 0 and std.mem.indexOfNone(u8, line[0..wr.start], " \t") == null)
            try self.appendCommandNameCandidates(cands, dp.prefix);

        sortCompletionCandidates(cands.items);
    }

    fn sortCompletionCandidates(cands: []CompletionCandidate) void {
        std.mem.sort(CompletionCandidate, cands, {}, struct {
            fn lessThan(_: void, a: CompletionCandidate, b: CompletionCandidate) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
    }

    /// On an idle tick, compute and draw the first completion candidate as
    /// dimmed text after the caret. Returns true when it repainted the
    /// input row, letting the caller skip a redundant idle redraw.
    fn maybeShowCompletionHint(self: *Prompt) !bool {
        if (!self.completion_hint_dirty or self.completion_hint_visible) return false;
        if (self.browse_pos != null or self.pending_resize != null) return false;
        const active_at = self.completion_hint_activity_at orelse return false;
        if (active_at.untilNow(self.client.io).raw.toMilliseconds() < autocomplete_idle_ms) return false;

        const line = self.buffer.items;
        if (self.cursor != line.len) return false;

        const wr = complete.wordRange(line, self.cursor);
        if (wr.end != self.cursor) return false;

        const word = line[wr.start..self.cursor];
        if (word.len == 0) return false;

        self.completion_hint_dirty = false;
        self.completion_hint.clearRetainingCapacity();

        const dp = complete.dirPrefix(word);
        var cands: std.ArrayList(CompletionCandidate) = .empty;
        defer {
            for (cands.items) |cand| self.client.alloc.free(cand.name);
            cands.deinit(self.client.alloc);
        }
        try self.collectCompletionCandidates(&cands, line, wr, dp);
        if (cands.items.len == 0) return false;

        const first = cands.items[0];
        const suffix = (try complete.candidateSuffix(self.client.alloc, dp.prefix, first.name, first.is_dir)) orelse return false;
        defer self.client.alloc.free(suffix);
        if (suffix.len == 0) return false;

        try self.completion_hint.appendSlice(self.client.alloc, suffix);
        self.completion_hint_visible = true;
        try self.renderInputLine();
        return true;
    }

    /// Right arrow at the end of the input accepts the visible inline
    /// hint. If no hint has been drawn yet, use the same completion path
    /// as Tab so Right-at-end is still a completion gesture.
    fn acceptCompletionHintOrComplete(self: *Prompt) !void {
        if (self.cursor != self.buffer.items.len or self.buffer.items.len == 0) return;
        if (self.completion_hint_visible and self.completion_hint.items.len > 0) {
            try self.insertText(self.completion_hint.items);
            self.completion_armed = false;
            return;
        }
        try self.doComplete();
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
        // Type-ahead (paste included) is dropped while a script builtin
        // runs; a copy_request carries nothing to free.
        .paste => |tev| self.client.alloc.free(tev.text),
        .copy_request => {},
    };
    return hit;
}

/// `sh.run` / `sh.exec` -- parse `line` and run its segments through the
/// same `runPipeline` the interactive prompt uses, with the pipe
/// executor's capture (`sh.run`) or grid-streaming (`sh.exec`) sink.
/// `stdin` feeds only the first pipeline actually run.
fn hookRunLine(
    ctx: *anyopaque,
    line: []const u8,
    capture: bool,
    stdin: []const u8,
    out: *std.ArrayList(u8),
    err_buf: *std.ArrayList(u8),
) u8 {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    const alloc = self.client.alloc;

    switch (parse.parse(alloc, line) catch return 2) {
        .err => |msg| {
            defer alloc.free(msg);
            if (capture) {
                err_buf.appendSlice(alloc, msg) catch {};
            } else {
                self.client.writeText(msg, err_color, null) catch {};
            }
            return 2;
        },
        .ok => |ok_line| {
            var parsed = ok_line;
            defer parsed.deinit();
            if (parsed.segments.len == 0) return 0;

            var cap = Prompt.Capture{ .out = out, .err_buf = err_buf, .stdin = stdin };
            var status: u8 = 0;
            var fed = false;
            for (parsed.segments) |seg| {
                const run = switch (seg.sep) {
                    .first, .semi => true,
                    .and_then => status == 0,
                    .or_else => status != 0,
                };
                if (!run) continue;
                if (fed) cap.stdin = "";
                const sink: Prompt.PipeSink = if (capture) .{ .capture = &cap } else .script_grid;
                status = self.runPipeline(seg.pipeline, sink) catch return status;
                fed = true;
            }
            return status;
        },
    }
}
