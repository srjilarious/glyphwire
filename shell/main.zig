// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const glyphwire = @import("glyphwire");
const wordsplit = @import("applib").wordsplit;
const embed = @import("shell_support").embed;
const parse = @import("shell_support").parse;
const envassign = @import("shell_support").envassign;
const pipeexec = @import("shell_support").pipeexec;
const complete = @import("shell_support").complete;
const glob = @import("shell_support").glob;
const hs = @import("shell_support").handshake;
const config = @import("shell_support").config;
const script_engine = @import("shell_support").script_engine;
const themeconf = @import("themeconf");
const history = @import("applib").history;
const homepath = @import("applib").homepath;
const ListCursor = @import("applib").listcursor.ListCursor;
const zjump = @import("applib").zjump;
const flushgate = @import("shell_support").flushgate;
const crashlog = @import("shell_support").crashlog;
const keyencode = @import("shell_support").keyencode;
const lineedit = @import("applib").lineedit;
const prompt_template = @import("shell_support").prompt_template;
const browsescroll = @import("shell_support").browsescroll;
const promptrow = @import("shell_support").promptrow;
const openaction = @import("shell_support").openaction;
const logicalpath = @import("shell_support").logicalpath;
const remotecmd = @import("shell_support").remotecmd;
const builtins = @import("builtins.zig");
const completion = @import("completion.zig");
const jobs = @import("jobs.zig");
const persist = @import("persist.zig");
const render = @import("render.zig");
pub const Pty = glyphwire.Pty;
pub const ModeTracker = glyphwire.ModeTracker;

/// The left prompt template used when `shell.conf.lua` configured a prompt
/// (`prompt.right` and/or the sub-templates) but not `prompt.left`. Byte
/// for byte the same as the unconfigured default `writeDefaultPrefix`
/// produces -- an absolute cwd, then `" > "`.
pub const default_prompt_left = "{cwd_full} > ";

/// The colour glyphwire-shell uses for every error line it prints onto
/// the grid itself (a bad `cd`, a spawn failure, a pipeline syntax
/// error). A theme role, like every colour the shell draws, so the host
/// resolves it against the window's theme.
pub const err_color = glyphwire.Color.role(.message_error);
/// `[1] zoe main.zig  (background)` and the other job notices.
pub const job_color = glyphwire.Color.role(.accent);
/// How long `hangUpJobs` waits after SIGHUP before SIGKILL, when the shell
/// exits with jobs still in the background.
pub const job_hangup_grace_ms = 500;

/// Rows of context kept between the browse cursor and the top/bottom of
/// the window while walking scrollback with the arrow keys, when
/// `shell.conf.lua`'s `prompt{ scrolloff = N }` isn't set. See
/// `Prompt.scrolloffRows`.
const default_scrolloff: usize = 8;

/// Rows Ctrl+Up / Ctrl+Down jump per press while browsing scrollback,
/// when `shell.conf.lua`'s `prompt{ scrollback_jump = N }` isn't set. See
/// `Prompt.scrollbackJumpRows`.
const default_scrollback_jump: usize = 5;

/// Max candidates the interactive Tab-completion picker shows at once,
/// when `shell.conf.lua`'s `prompt{ completion_max_items = N }` isn't
/// set. See `Prompt.completionMaxItems`.
const default_completion_max_items: usize = 5;

/// Per-command wall-clock budget for a `prompt{ commands = { ... } }`
/// var when its entry doesn't set `timeout_ms`. Kept short: the command
/// runs synchronously while the prompt is being drawn, so a hung `git`
/// in a huge repo must not stall the prompt for long -- it's killed and
/// `{name}` renders empty. See `Prompt.runCmdVar`.
pub const default_cmd_var_timeout_ms: u64 = 400;

/// Resize debounce (see the resize handling in `runPrompt`). A resize
/// drag emits an event per frame; redrawing the prompt on each one looks
/// messy, so the redraw waits until the size has been quiet for
/// `resize_settle_ms`. Every resize wakes the prompt's wait, so while one
/// is pending the loop only has to time out once the drag goes quiet.
const resize_settle_ms: i64 = 140;

/// How often the prompt's idle work (the ticking `{time}` right chain, a
/// due persistent-state flush) runs when nothing is typed. Also the
/// prompt loop's wait timeout.
const prompt_idle_ms: i64 = 500;

/// Fish-style inline completion hint delay. The prompt loop already uses
/// a 500ms idle heartbeat, so this stays aligned with that cadence.
pub const autocomplete_idle_ms: i64 = 500;
pub const autocomplete_hint_color = glyphwire.Color.role(.suggestion);

/// Env var naming the write end of the "result pipe" `runCommand` opens
/// before spawning every foreground command (see `Prompt.spawnResultPipe`):
/// a glyphwire-aware interactive program -- an argument picker, a fuzzy
/// finder, anything that builds up a value interactively and then hands
/// it back -- can `write()` that value to this fd before exiting, and the
/// shell replaces its own input line with it once the child is reaped
/// (`Prompt.readResultPipe`). Not documented to the user as a public API
/// yet, just a convention between the shell and its own bundled tools
/// (`gw-hist` is the first); see docs/decisions.md "Shell result pipe".
pub const result_fd_env = "GLYPHWIRE_RESULT_FD";

comptime {
    // The captured-child marker detector keeps its own copy of the
    // marker string to stay dependency-free (see shell/handshake.zig);
    // keep it identical to what an aware client actually writes.
    if (!std.mem.eql(u8, hs.marker, glyphwire.handshake_marker))
        @compileError("shell_support.handshake.marker is out of sync with glyphwire.handshake_marker");
}

pub const c = struct {
    pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    pub extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    /// Resolves `path` against the filesystem into `resolved` (must be at
    /// least `PATH_MAX`); returns `resolved` on success, null otherwise.
    pub extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
    pub extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    pub extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    /// No `O_CLOEXEC`, matching `pipeexec.zig`'s pipes: `runCommand` wants
    /// both ends to survive `fork`+`exec` into the spawned child with no
    /// extra plumbing (see `Prompt.spawnResultPipe`), and it closes its
    /// own copies explicitly rather than relying on close-on-exec.
    pub extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
};

/// `signal(2)` for the SIGHUP guard in `dropControllingTty` and
/// `restoreInterruptSignals`. Linux constants; the shell is Linux-only
/// in practice (pty / pipeexec).
const csig = struct {
    extern "c" fn signal(sig: c_int, handler: usize) usize;
    const SIGHUP: c_int = 1;
    const SIGINT: c_int = 2;
    const SIGQUIT: c_int = 3;
    const SIG_DFL: usize = 0;
    const SIG_IGN: usize = 1;
};

/// Keeps a write to a pipe whose reader is gone from killing the shell:
/// the write fails with EPIPE instead, and nothing here streams to a
/// pipe it must not outlive.
///
/// A no-op **handler** rather than `SIG_IGN`, for the same reason as
/// `applib.interrupt`: an ignored signal stays ignored across `exec`, so
/// every command run from here inherited it. `yes | head` then had `yes`
/// print "Broken pipe" instead of quietly dying, and any pipeline
/// producer kept going after its reader left. A caught signal goes back
/// to the default on `exec`, so children start out normal whichever way
/// they were spawned.
fn survivePipeWrites() void {
    if (std.posix.Sigaction == void) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = ignorePipeSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

fn ignorePipeSignal(_: std.posix.SIG) callconv(.c) void {}

/// Puts SIGINT and SIGQUIT back to their defaults, the way a terminal
/// emulator does for the shell it starts. A process can inherit them
/// ignored -- bash ignores both for anything it runs in the background
/// (`glyphwire &` from a script, a desktop launcher wrapping a shell
/// script) -- and an ignored signal stays ignored across `exec`, so
/// every command typed here would shrug off Ctrl-C and `kill -INT`.
/// Caught or default, it comes back as the default in a child, so this
/// one reset covers everything the shell spawns: pty commands,
/// pipelines, prompt command vars, a script's `os.execute`.
///
/// The default, not a no-op handler (`applib.interrupt.keep`): this
/// shell's own Ctrl-C story is a terminal's, so a Ctrl-C in the terminal
/// that ran `zig build gw-shell` should still end it. SIGHUP is left as
/// inherited, so `nohup` keeps meaning what it says.
fn restoreInterruptSignals() void {
    _ = csig.signal(csig.SIGINT, csig.SIG_DFL);
    _ = csig.signal(csig.SIGQUIT, csig.SIG_DFL);
}

/// Gives up whatever controlling terminal this process inherited, so
/// nothing it spawns can open `/dev/tty` and reach it. The inherited one
/// is never a terminal anyone is looking at: the one `glyphwire` was
/// launched from, or a gmux pane's pty, whose output this shell doesn't
/// draw. A command that wants a terminal gets its own pty (`runCommand`);
/// one that only has pipes (`pipeexec`) used to find the inherited one
/// instead and, being outside its foreground group, get stopped by
/// SIGTTIN/SIGTTOU the moment it touched it -- `sudo` in a pipeline
/// waiting forever on a password prompt nobody could see. With no
/// controlling terminal it fails straight away ("a terminal is
/// required") instead.
///
/// `TIOCNOTTY`, not `setsid`: this keeps the process group, so a Ctrl-C
/// in the terminal that ran `zig build gw-shell` still ends the shell.
/// A session leader (a gmux pane's shell, which `Pty.spawn` started)
/// makes the kernel SIGHUP its own foreground group on the way out --
/// this process -- so SIGHUP is ignored around the call. It goes back to
/// whatever it was before, not the default: the host's pane kill is a
/// SIGHUP and must still land, and a `nohup` must still hold.
/// Best-effort: no `/dev/tty` means there was nothing to drop.
fn dropControllingTty() void {
    if (builtin.os.tag != .linux) return;
    const fd = c.open("/dev/tty", O_RDWR | O_NOCTTY, 0);
    if (fd < 0) return;
    defer _ = c.close(fd);
    if (getsid(0) == std.os.linux.getpid()) {
        const prev = csig.signal(csig.SIGHUP, csig.SIG_IGN);
        _ = std.c.ioctl(fd, TIOCNOTTY, @as(c_int, 0));
        _ = csig.signal(csig.SIGHUP, prev);
    } else {
        _ = std.c.ioctl(fd, TIOCNOTTY, @as(c_int, 0));
    }
}

extern "c" fn getsid(pid: c_int) c_int;

// <asm-generic/fcntl.h> / <asm-generic/ioctls.h>, for `dropControllingTty`.
const O_RDWR: c_int = 0o2;
const O_NOCTTY: c_int = 0o400;
const TIOCNOTTY: c_int = 0x5422;

/// libc time formatting for the prompt's `{time}` token -- this reduced
/// std has no `strftime`/`localtime`. `Tm` is glibc's `struct tm` (the
/// nine `int` fields, then `tm_gmtoff` / `tm_zone`).
pub const timelib = struct {
    pub const Tm = extern struct {
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
    pub extern "c" fn time(t: ?*c_long) c_long;
    pub extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;
    pub extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const Tm) usize;
};

pub const plColor = render.plColor;

/// gw-shell: sets up discovery, then either execs into a given
/// command (`gw-shell <command> [args...]`, unchanged from
/// milestone 5) or, given no command, runs the interactive prompt itself
/// -- see decisions.md, Discovery & Connection. The third form,
/// `gw-shell --embed <context>,<layer>[,<control-fd>]`, runs that same
/// prompt inside a layer another client owns (salacommander's Ctrl+`
/// panel) -- see `shell/embed.zig`. Deliberately has no
/// engine dependency: input arrives as wire-level key events (see
/// src/client.zig's `InputListener`), captured by glyphwire-host and
/// relayed through the server, not read directly.
///
/// The prompt supports echo, Enter, real cursor movement and interior
/// insert/delete (arrow keys, ctrl+a/e/u, ctrl+arrow word jumps, Up/Down
/// history recall, Ctrl+Up to browse scrollback, alt+d to drop
/// `cd <cwd>` onto the line -- see `Prompt`), and now
/// launches a child process
/// per submitted line (see `Prompt.runCommand`). Every child's
/// stdout/stderr is piped and mirrored onto the grid via `write_text` by
/// default -- the assumption for any spawned command is "plain program
/// writing to a terminal" until proven otherwise. A child that's actually
/// "glyphwire compatible" (inherits `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX` and
/// draws to the grid itself over its own connection, the same way
/// `glyphwire-demo` or `gw-ls` do) opts out of the mirroring
/// automatically: `Client.connect` signals the handshake as part of
/// connecting, with no separate call for a glyphwire-aware program to
/// remember -- see `Prompt.pumpChildOutput`. `cd` is a builtin (see `Prompt.doCd`) rather than spawned, since
/// changing directory in a child process wouldn't affect this one; the
/// prompt shows the current directory before `> ` so a `cd` actually
/// taking effect is visible. `exit` is a builtin too -- typing it is the
/// only way to quit, deliberately unlike the escape-quits-immediately
/// convention most game examples use, which would kill an
/// interactive shell session out from under whatever's running in it;
/// `glyphwire` watches for this process actually exiting (see
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
    // the shell. See `survivePipeWrites`.
    survivePipeWrites();

    // Before anything is spawned, so no child inherits an ignored Ctrl-C
    // or the terminal glyphwire was started from -- see the doc comments.
    restoreInterruptSignals();
    dropControllingTty();

    // Must run before *any* std.process.spawn/replace call below (both
    // the exec path a few lines down and everything Prompt.runCommand
    // spawns later) -- see the doc comment for why.
    try prependZigOutBinToPath(init.io, arena, init.environ_map);
    try assertTermEnv();

    const socket_path = if (init.environ_map.get("GLYPHWIRE_SOCK")) |sp|
        sp
    else
        try spawnOwnServer(init.io, arena, init.environ_map);

    if (args.len < 2) {
        return runPrompt(init.io, alloc, socket_path, init.environ_map, null);
    }

    // `--embed <context>,<layer>[,<control-fd>]`: the prompt as a panel
    // in another client's context (see `shell/embed.zig`). Checked before
    // the exec path below, which takes anything else as a command to run.
    if (std.mem.eql(u8, args[1], "--embed")) {
        const value: []const u8 = if (args.len > 2) args[2] else {
            std.debug.print("gw-shell: --embed needs <context>,<layer>[,<control-fd>]\n", .{});
            return error.EmbedArgsMissing;
        };
        const opts = embed.parseOptions(value) catch {
            std.debug.print("gw-shell: --embed '{s}' isn't <context>,<layer>[,<control-fd>]\n", .{value});
            return error.EmbedArgsMalformed;
        };
        return runPrompt(init.io, alloc, socket_path, init.environ_map, opts);
    }

    const child_argv = try arena.allocSentinel(?[*:0]const u8, args.len - 1, null);
    for (args[1..], 0..) |arg, i| child_argv[i] = arg.ptr;

    _ = c.execvp(args[1].ptr, child_argv.ptr);
    // execvp only returns on failure.
    std.debug.print("failed to exec {s}\n", .{args[1]});
    return error.ExecFailed;
}

/// Prepends the installed binary dir to `PATH` -- a dev-mode
/// convenience so typing `gw-ls` or `glyphwire-demo` at the prompt finds
/// binaries built alongside gw-shell itself, the same way an
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
    const bin_dir = if (environ_map.get("GLYPHWIRE_BIN_DIR")) |dir|
        dir
    else
        std.process.executableDirPathAlloc(io, alloc) catch return;
    const old_path = environ_map.get("PATH") orelse "";
    const new_path = try std.fmt.allocPrintSentinel(alloc, "{s}:{s}", .{ bin_dir, old_path }, 0);
    defer alloc.free(new_path);
    if (c.setenv("PATH", new_path.ptr, 1) != 0) return error.SetEnvFailed;
}

/// Forces `TERM` / `COLORTERM` to a known-good pair for every command the
/// shell spawns. Like `prependZigOutBinToPath`, this mutates *this*
/// process's real environment (`libc` `setenv`) so `pty.zig` / `pipeexec`
/// children -- which `execvp` against the live environ -- inherit it.
///
/// A command run under glyphwire-shell talks to glyphwire's own cell grid
/// through the pty, not to whatever terminal emulator launched the host,
/// so an inherited `TERM` (`kitty`, `foot`, an unset value from a desktop
/// launcher, ...) describes the wrong terminal. Left alone, a bad value
/// breaks anything that initialises terminfo: `bat` / `git` / `delta`
/// spawn `less` as a pager, `less` calls ncurses `setupterm`, and an
/// unset or unknown `TERM` makes that abort with
/// `'unknown': I need something more specific.` -- the pager then prints
/// nothing, so `bat` shows only that one line and no highlighted file.
///
/// `xterm-256color` is the closest ubiquitous terminfo entry to what
/// `core.Layer.writeText` actually interprets (SGR incl. 256-colour and
/// truecolor, basic cursor/erase); `COLORTERM=truecolor` advertises the
/// 24-bit `38;2;R;G;B` support `core.zig` has. Both are set
/// unconditionally -- the inherited values are never right here.
fn assertTermEnv() !void {
    if (c.setenv("TERM", "xterm-256color", 1) != 0) return error.SetEnvFailed;
    if (c.setenv("COLORTERM", "truecolor", 1) != 0) return error.SetEnvFailed;
}

/// Sets up its own server and discovery env vars (GLYPHWIRE_SOCK isn't
/// already inherited -- standalone use, e.g. `zig build gw-shell -- <cmd>`
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

    const socket_path_z = try std.mem.concatWithSentinel(alloc, u8, &.{socket_path}, 0);
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

/// Owned path to glyphwire's config directory (holds `shell.conf.lua` and
/// `history`). Shared with glyphwire-host and glyphwire-ls -- see
/// `glyphwire.configDirPath`.
const configDirPath = glyphwire.configDirPath;

/// Drains every queued `resize` into `prompt.pending_resize` (see
/// `Prompt.noteResize`) and then applies it if the size has settled
/// (`applyPendingResize`). The prompt is *not* redrawn while a resize is
/// still in flight.
pub fn drainResizes(listener: *glyphwire.InputListener, prompt: *Prompt) void {
    var last: ?glyphwire.ResizeEvent = null;
    while (listener.pollResizeEvent()) |rev| last = rev;
    if (last) |rev| prompt.noteResize(rev.cols, rev.rows);
    prompt.applyPendingResize(false) catch {};
}

/// An event's modifiers as `key_encode` wants them -- shared by every key
/// and mouse encoder here. Always the event's own `mods`, stamped by the
/// host when it generated the event: sampling the live down-set instead
/// lets a shell that fell behind send a TUI the wrong escape sequence
/// (Ctrl released before its keystroke was encoded).
pub fn ptyMods(mods: glyphwire.Mods) keyencode.Mods {
    return .{ .ctrl = mods.ctrl, .shift = mods.shift, .alt = mods.alt };
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

/// Re-encodes one mouse button event as an xterm mouse report for the
/// foregrounded pty child, when it has a mouse-reporting mode on
/// (`glyphwire.ModeTracker`); otherwise drops it.
/// `origin` is where the shell's surface starts in the context, which is
/// what the reported cell has to be measured from: the child's screen is
/// the shell's surface, and embedded that is a panel partway down the
/// host's window rather than the window itself.
pub fn ptyMouseButton(pty: *Pty, modes: *ModeTracker, mev: glyphwire.MouseButtonEvent, origin: glyphwire.CellPos) void {
    if (!modes.mouseReporting()) return;
    const enc: keyencode.MouseEncoding = if (modes.sgrMouse()) .sgr else .legacy;
    const btn = keyencode.mouseButtonFromName(mev.button) orelse return;
    // A wheel notch is a press alone in xterm's reports; the release the
    // host pairs it with is only there to keep the button state balanced.
    if (!mev.pressed and (btn == .wheel_up or btn == .wheel_down)) return;
    const action: keyencode.MouseAction = if (mev.pressed) .press else .release;
    var buf: [16]u8 = undefined;
    if (keyencode.encodeMouse(enc, btn, action, mev.cell.col -| origin.col, mev.cell.row -| origin.row, ptyMods(mev.mods), &buf)) |seq|
        pty.writeAll(seq);
}

/// `ptyMouseButton` for pointer motion.
pub fn ptyMouseMove(listener: *glyphwire.InputListener, pty: *Pty, modes: *ModeTracker, mev: glyphwire.MouseMoveEvent, origin: glyphwire.CellPos) void {
    if (!modes.mouseReporting() or !modes.wantsMotion()) return;
    const enc: keyencode.MouseEncoding = if (modes.sgrMouse()) .sgr else .legacy;
    // `?1002` reports motion only while a button is held; `?1003`
    // reports it with a "no button" code the rest of the time.
    const btn = heldMouseButton(listener) orelse
        (if (modes.wantsAnyMotion()) keyencode.MouseButton.none else return);
    var buf: [16]u8 = undefined;
    if (keyencode.encodeMouse(enc, btn, .motion, mev.cell.col -| origin.col, mev.cell.row -| origin.row, ptyMods(mev.mods), &buf)) |seq|
        pty.writeAll(seq);
}

/// The prompt's idle work: a due persistent-state flush, the inline
/// completion hint, and the ticking `{time}` right chain. Returns true
/// when it drew the completion hint (which already placed the cursor).
fn promptIdleTick(prompt: *Prompt) bool {
    // An idle moment is a good time to flush persistent state if the age
    // trigger has come due.
    prompt.maybeFlushPersistentState();
    // A background job finished and left the rest of its line to run.
    // That draws a whole new prompt, so the redraws below are moot.
    const ran_chain = prompt.runReadyChainsAtIdle() catch |err| blk: {
        std.log.warn("gw-shell: running the rest of a line failed: {t}", .{err});
        break :blk true;
    };
    if (ran_chain) return false;
    if (prompt.pending_resize == null and prompt.browse_pos == null) {
        const drew_hint = prompt.maybeShowCompletionHint() catch false;
        if (drew_hint) return true;
    }
    if (prompt.pending_resize == null and prompt.right_dynamic and prompt.browse_pos == null) {
        // Refresh the powerline right chain so `{time}` keeps ticking
        // while nothing is typed; skipped while a resize is in flight so
        // it isn't drawn at an intermediate size.
        prompt.drawRightChain() catch {};
        prompt.placeInputCursor() catch {};
    }
    return false;
}

/// A mouse click at the prompt. A left click resolves the same way
/// Enter-while-browsing does (`activateSelectionAt`), regardless of
/// whether anything's currently being typed: a click is a deliberate,
/// targeted action, not something that should be gated on browse state
/// the way keyboard Enter is.
fn promptClick(prompt: *Prompt, mev: glyphwire.MouseButtonEvent) !void {
    if (!mev.pressed or !std.mem.eql(u8, mev.button, "left")) return;
    // Every cell the host reports is a cell of the *context*, so embedded
    // it has to be brought into the panel's own frame first -- see
    // `surfaceCell`.
    const cell = prompt.surfaceCell(mev.cell) orelse return;

    // How far the surface was scrolled back when the click happened, which
    // is both the lookup offset (resolve against the row actually under
    // the pointer) and what makes `setLine` -> `setCursorAt` snap the view
    // back down to the live prompt when the click activates a command --
    // clicking an `ls` entry in scrollback should land you back at the new
    // prompt, not leave you scrolled up.
    //
    // On the root grid that is `mev.view_offset`: ground truth, stamped by
    // the host atomically with the click, so it beats the locally-mirrored
    // `view_scroll` (which can lag a host-driven wheel/scrollbar scroll).
    // Embedded it is not -- the host stamps the *root* layer's offset, and
    // the panel has a scrollback ring of its own -- so the mirrored value
    // is all there is, and `scroll` notifications for this layer keep it
    // current (see the `.scroll` arm of the prompt loop).
    const view_offset = if (prompt.layer != null) prompt.view_scroll else blk: {
        prompt.view_scroll = mev.view_offset;
        break :blk mev.view_offset;
    };

    if (mev.mods.ctrl) {
        // Ctrl+click toggles the entry in the multi-select mark set (same
        // as Space while browsing).
        try prompt.toggleHighlightAt(cell.row, cell.col, view_offset);
    } else {
        // A plain click always runs the entry's own action (the first
        // `open_actions` command for its type), regardless of what's
        // marked -- marks are built and acted on from the keyboard (Space
        // to mark, Enter to run) or copied with Ctrl+Shift+C.
        try prompt.activateSelectionAt(cell.row, cell.col, view_offset);
    }
}

/// Prints the current directory followed by `> `, echoes typed characters
/// live, Enter commits the line and starts a new prompt row below it. See
/// `Prompt` for the rest of the line editing (cursor movement, interior
/// insert/delete) and command dispatch. Runs forever (killed along with
/// the rest of the process tree, same as any other long-lived child in
/// this codebase).
///
/// The connections, the embed control pipe and the `Prompt` itself live in
/// this frame (their `defer`s are here); the phases below do the rest:
/// `seedPromptEnv`, `preparePrompt`, `runStartupScript`, then
/// `promptEventLoop` until the shell exits.
fn runPrompt(
    io: std.Io,
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    environ_map: *const std.process.Environ.Map,
    embed_opts: ?embed.Options,
) !void {
    // Before either connection: if a window manager seated this shell in a
    // pane, both the drawing `Client` and the `InputListener` below have to
    // bind to it. That's all the pane-awareness the shell needs -- see
    // `client.notePaneFromEnviron`.
    glyphwire.notePaneFromEnviron(environ_map);

    var client = glyphwire.Client.connect(io, alloc, socket_path) catch |err| {
        std.log.err("prompt: failed to connect: {t}", .{err});
        return;
    };
    defer client.deinit();

    // `mouse_move` is subscribed session-wide but only consumed by the
    // pty foreground loop (`runCommand`) when a child turns on motion
    // reporting; the prompt loop lets `InputListener`'s own cap drop the
    // backlog. `remote` is what `gwssh` waits on: the session's end
    // arrives here, not on the `Client` that asked for it. Free to
    // subscribe to always -- nothing broadcasts it in a session with no
    // remote panes. `focus` is only forwarded to a pty child that turned
    // on `?1004`.
    const listener = glyphwire.InputListener.connect(io, alloc, socket_path, &.{ "key", "text", "mouse_button", "mouse_move", "scroll", "resize", "shutdown", "clipboard", "terminal", "remote", "context", "focus" }) catch |err| {
        std.log.err("prompt: failed to subscribe: {t}", .{err});
        return;
    };
    defer listener.deinit();

    var prompt: Prompt = .{ .client = &client, .environ_map = environ_map, .listener = listener };
    prompt.profiler = shellProfilerFromEnv(io, environ_map);

    var control: ?embed.Control = null;
    defer if (control) |*ctl| ctl.deinit();
    if (embed_opts) |eo| {
        if (!attachEmbedded(&prompt, listener, alloc, eo, &control)) return;
    }

    try seedPromptEnv(&prompt, io, alloc);
    // Unreachable before `exit` gave this loop a clean return path --
    // every previous exit was a hard kill, so this never ran and the leak
    // never surfaced.
    defer prompt.deinit();

    try preparePrompt(&prompt, io, alloc, environ_map);
    if (runStartupScript(&prompt, io, alloc, environ_map)) return;
    try promptEventLoop(&prompt, io, alloc, listener);
}

/// `--embed`: join the host's context and draw on the layer it made for
/// us instead of on a context of our own. Both connections attach -- the
/// drawing one so `layer?`-scoped messages resolve there, the listener so
/// its input follows that context's visibility. `control` is the caller's,
/// so it outlives this call. False (already logged) when either attach
/// failed and the shell should give up.
fn attachEmbedded(prompt: *Prompt, listener: *glyphwire.InputListener, alloc: std.mem.Allocator, eo: embed.Options, control: *?embed.Control) bool {
    prompt.client.attachContext(eo.context) catch |err| {
        std.log.err("prompt: --embed: can't attach to context {d}: {t}", .{ eo.context, err });
        return false;
    };
    listener.attachContext(eo.context) catch |err| {
        std.log.err("prompt: --embed: listener can't attach to context {d}: {t}", .{ eo.context, err });
        return false;
    };
    prompt.layer = eo.layer;
    // The panel starts out of focus: the host opens it, then says so.
    prompt.focused = false;
    if (eo.control_fd) |fd| control.* = embed.Control.init(alloc, fd);
    prompt.control = if (control.*) |*ctl| ctl else null;
    return true;
}

/// The live environment `sh.setenv` mutates (alongside libc, for
/// children). Seeded from the *live* libc environ, not the
/// `std.process.Init` snapshot in `environ_map`: `main` prepends
/// `<cwd>/zig-out/bin` to PATH and sets the GLYPHWIRE_* discovery vars
/// with libc `setenv` *after* that snapshot is taken (see
/// `prependZigOutBinToPath`), so seeding from the snapshot would give a
/// stale PATH -- and then a script that rewrites PATH (venv_activate
/// prepending its bin/) would write the stale value back through
/// `c.setenv` and drop `zig-out/bin`, so `ls` would stop resolving to
/// the bundled `glyphwire-ls`. Called before `runPrompt`'s
/// `defer prompt.deinit()` so the deinit is always safe.
fn seedPromptEnv(prompt: *Prompt, io: std.Io, alloc: std.mem.Allocator) !void {
    prompt.env = std.process.Environ.Map.init(alloc);
    {
        const live: std.process.Environ.PosixBlock.View = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) };
        try prompt.env.putPosixBlock(live);
    }
    // `$PWD` is set from the real cwd here rather than trusted from
    // whatever launched this process -- see `Prompt.chdir` for why the
    // shell maintains it itself from this point on.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &cwd_buf) catch 0;
    if (n > 0) prompt.setEnvVar("PWD", cwd_buf[0..n]);
}

/// Everything between connecting and the first keystroke: the surface's
/// size, the `{host}` name and icon metrics, `shell.conf.lua`, history and
/// the zjump database, then the first prompt.
fn preparePrompt(prompt: *Prompt, io: std.Io, alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    {
        // Embedded, the surface is the host's panel layer, not the
        // context's root grid -- `drawGetCells` follows `prompt.layer`.
        var snapshot = try prompt.drawGetCells();
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
        prompt.config_dir = config_dir; // owned from here on -- freed in `deinit`
        prompt.initScriptEngine(config_dir) catch |err| {
            std.log.warn("prompt: couldn't start the script engine: {t}", .{err});
        };
        // Before `shell.conf.lua` runs, so it can branch on `sh.remote`.
        if (prompt.script_engine) |eng| {
            eng.setIdentity(environ_map.get("USER") orelse "", prompt.host, prompt.remoteDest());
        }
        try prompt.loadStartupConfig(config_dir);
        try prompt.loadHistory(config_dir);
        try prompt.loadZjump(config_dir);
    } else |_| {}

    // Seed the flush clock so the age-based trigger measures from now,
    // not from the epoch.
    prompt.persist_gate.reset(std.Io.Timestamp.now(io, .awake).toMilliseconds());

    try prompt.showPrompt();
}

/// Scripted input for automated screenshots / smoke runs: if
/// GLYPHWIRE_SHELL_SCRIPT names a readable file, each non-blank,
/// non-`#`-comment line is played through the prompt exactly as if it
/// had been typed and submitted, before the interactive key loop
/// starts. The prompt then carries on normally (the window stays up so
/// a screenshot tool -- see the host's `--screenshot` -- can capture
/// the result), unless one of the scripted lines was `exit`, which is
/// when this returns true.
fn runStartupScript(prompt: *Prompt, io: std.Io, alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) bool {
    const script_path = environ_map.get("GLYPHWIRE_SHELL_SCRIPT") orelse return false;
    if (script_path.len == 0) return false;
    runScriptFile(io, alloc, prompt, script_path) catch |err| {
        std.log.err("prompt: couldn't run GLYPHWIRE_SHELL_SCRIPT '{s}': {t}", .{ script_path, err });
    };
    return prompt.should_exit;
}

/// The interactive loop: waits for the next event (or the idle tick),
/// hands session events to `handleSessionEvent`, and turns input into a
/// key press for `handlePromptKey` via `takeKeyEvent`. Returns once the
/// shell should exit.
fn promptEventLoop(prompt: *Prompt, io: std.Io, alloc: std.mem.Allocator, listener: *glyphwire.InputListener) !void {
    var last_idle = std.Io.Clock.Timestamp.now(io, .awake);
    while (true) {
        // One profiler "tick" per loop iteration (per event or idle
        // timeout): rolls the counter windows and fires the periodic
        // summary. Inert unless GLYPHWIRE_SHELL_PROFILE is set.
        _ = prompt.profiler.frameBoundary();

        // A resize that has gone quiet for `resize_settle_ms` is applied
        // now; one still settling is left for the next pass.
        prompt.applyPendingResize(false) catch {};

        // What the host has asked for since the last pass (`--embed`
        // only): a directory to follow, focus changing hands, the panel
        // resized, or the host going away.
        prompt.drainControl();
        if (prompt.should_exit) return;

        // Every notification wakes this wait -- clicks, scrolls and
        // resizes included -- so its timeout is purely the idle cadence,
        // or the settle window while a resize drag is in flight.
        const wait_ms: i64 = if (prompt.pending_resize != null) resize_settle_ms else prompt_idle_ms;
        const any_ev = (try listener.next(.{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } })) orelse {
            last_idle = std.Io.Clock.Timestamp.now(io, .awake);
            _ = promptIdleTick(prompt);
            continue;
        };
        const input_ev = any_ev.asInput() orelse {
            defer any_ev.deinit(alloc);
            try handleSessionEvent(prompt, any_ev);
            // A steady stream of pointer events must not starve the idle
            // work a timeout would otherwise have run.
            if (last_idle.untilNow(io).raw.toMilliseconds() >= prompt_idle_ms) {
                last_idle = std.Io.Clock.Timestamp.now(io, .awake);
                _ = promptIdleTick(prompt);
            }
            continue;
        };
        // Someone else's keystroke: embedded and blurred, the host has
        // the keyboard and this event is only here because input is
        // delivered per context. Dropped, not queued -- what was typed
        // elsewhere isn't owed to the panel when it comes back.
        if (!prompt.focused) {
            input_ev.deinit(alloc);
            continue;
        }

        // A real keystroke means the drag (if any) is over -- apply a
        // still-settling resize now so the keystroke lands on a correct
        // layout.
        prompt.applyPendingResize(true) catch {};

        const ev = (try takeKeyEvent(prompt, alloc, input_ev)) orelse {
            if (prompt.should_exit) return;
            continue;
        };
        defer alloc.free(ev.key);
        if (!ev.pressed) continue; // only key-down drives the prompt
        try handlePromptKey(prompt, ev);
        if (prompt.should_exit) return; // "exit" was typed -- see submitLine
    }
}

/// A non-input notification at the prompt: a click, a scroll or a resize.
/// Out of focus, the pointer and the scrollback are the host's too -- only
/// the resize still concerns us, since the panel's layer moves with the
/// window whether or not we're typing.
fn handleSessionEvent(prompt: *Prompt, any_ev: glyphwire.Event) !void {
    if (!prompt.focused) {
        switch (any_ev) {
            .resize => |rev| prompt.noteResize(rev.cols, rev.rows),
            else => {},
        }
        return;
    }
    switch (any_ev) {
        .mouse_button => |mev| try promptClick(prompt, mev),
        // Keep `prompt.view_scroll` current with any host-driven
        // scroll (mouse wheel, scrollbar) so browse-down and the
        // type-to-snap-back in `setCursorAt` know the real offset.
        // Only for the surface this prompt draws on: embedded,
        // the context has other layers with rings of their own.
        .scroll => |sev| if (sev.layer == prompt.layer) {
            prompt.view_scroll = sev.offset;
        },
        // A window resize rebuilt the grid (bottom-anchored) and
        // changed its dimensions. The re-layout is debounced
        // (`Prompt.noteResize` / `applyPendingResize`).
        .resize => |rev| prompt.noteResize(rev.cols, rev.rows),
        else => {},
    }
}

/// Handles every input event that isn't a key press -- text, a paste, a
/// copy request, the window closing -- and hands a key event back for
/// `handlePromptKey`. Null when the event was consumed here; the caller
/// owns the returned event's `key`.
///
/// Committed text input -- the characters the user typed, already
/// resolved through their OS keyboard layout / dead keys / IME -- is taken
/// from the same queue as key events so "type then Enter" can't reorder.
/// Text only edits the live line, so it's held back while browsing
/// scrollback, matching how the printable-key path used to gate on
/// `browse_pos`. The physical key event that accompanies each keystroke in
/// real host use is a separate `.key` event and just falls through
/// `handlePromptKey` doing nothing.
fn takeKeyEvent(prompt: *Prompt, alloc: std.mem.Allocator, input_ev: glyphwire.InputEvent) !?glyphwire.KeyEvent {
    switch (input_ev) {
        .text => |tev| {
            defer alloc.free(tev.text);
            // Off the browse path this just edits the live line. While
            // browsing scrollback, `scrollback_type_exits` (default
            // true) decides whether a keystroke snaps back to the
            // prompt and inserts (`insertText` funnels through
            // `setCursorAt`, which clears `browse_pos` and the scroll
            // view) or is ignored until Escape. A lone space is the
            // exception: while browsing it toggles the mark under the
            // cursor (handled by `handlePromptKey`'s "space" arm), so it
            // must not be consumed as type-to-exit here.
            const browse_space = prompt.browse_pos != null and std.mem.eql(u8, tev.text, " ");
            if (!browse_space and (prompt.browse_pos == null or prompt.scrollbackTypeExits())) {
                try prompt.insertText(tev.text);
            }
            return null;
        },
        .paste => |tev| {
            defer alloc.free(tev.text);
            // Ctrl+Shift+V: insert the clipboard text into the live
            // line without submitting (the user presses Enter). The
            // editor is single-line, so the field's
            // `.flatten_newlines` policy turns newline runs into
            // single spaces on the way in -- a pasted file list then
            // reads as space-separated arguments instead of one
            // unusable blob. A paste while browsing follows the same
            // `scrollback_type_exits` rule as typed text.
            if (prompt.browse_pos == null or prompt.scrollbackTypeExits()) {
                try prompt.insertText(tev.text);
            }
            return null;
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
                    prompt.client.setClipboard(text) catch |err| {
                        std.log.err("prompt: set_clipboard (copy_request) failed: {t}", .{err});
                    };
                } else |err| {
                    std.log.err("prompt: could not build marked-paths clipboard text: {t}", .{err});
                }
            } else {
                prompt.client.setClipboard(prompt.line.text()) catch |err| {
                    std.log.err("prompt: set_clipboard (copy_request) failed: {t}", .{err});
                };
            }
            return null;
        },
        .shutdown => {
            // The host window is closing. Flush persistent state and
            // end the loop the same way a typed `exit` does --
            // `defer prompt.deinit()` (which also flushes) then runs.
            prompt.flushPersistentState(.force);
            prompt.should_exit = true;
            return null;
        },
        // A window manager's own commands (see `InputEvent.window_key`).
        // Never delivered here: this program is not one.
        .window_key => |kev| {
            alloc.free(kev.key);
            return null;
        },
        .window_text => |tev| {
            alloc.free(tev.text);
            return null;
        },
        .key => |kev| return kev,
    }
}

/// One key press at the prompt: the editing, browsing, completion and
/// history chords.
///
/// Plain character insertion is not handled here: it comes from
/// `takeKeyEvent`'s `.text` arm, which is the only correct source for a
/// non-US layout, an AltGr combo or CJK IME. An unhandled key event (a
/// bare letter, or a ctrl/alt chord with no explicit case below like
/// ctrl+c / alt+f) just falls through and does nothing -- a real terminal
/// swallows those too, and the host suppresses `text` for genuine
/// modifier chords, so nothing types.
fn handlePromptKey(prompt: *Prompt, ev: glyphwire.KeyEvent) !void {
    // `ctrl` gates most of the chords below (the ctrl+letter / ctrl+
    // arrow editing ones); `alt` gates exactly one, alt+d. `super`
    // has no cases and needs no checking: plain characters come from
    // the `text` stream, and the host doesn't emit `text` for a
    // genuine modifier chord, so an unhandled alt/super combo simply
    // does nothing here. Read off the event, as it was pressed.
    const ctrl = ev.ctrl();
    const alt = ev.alt();
    if (std.mem.eql(u8, ev.key, "enter")) {
        // The completion picker takes priority over both browsing and
        // submitting -- accepting the highlighted candidate completes
        // the word, it doesn't run the line.
        if (prompt.completion_picker != null) {
            try prompt.acceptCompletionPicker();
        } else if (prompt.browse_pos != null) {
            try prompt.browseEnter();
        } else {
            try prompt.submitLine();
        }
    } else if (std.mem.eql(u8, ev.key, "escape")) {
        // The explicit "never mind" key. The picker, if open, is
        // dismissed first (leaving whatever's already typed); then, if
        // entries are marked, the first Escape just clears the marks
        // (and their highlight), leaving you where you were; otherwise
        // it snaps browsing back to the prompt. Everything else that
        // ends browsing (below) does so as a side effect of also doing
        // something.
        if (prompt.completion_picker != null) {
            try prompt.closeCompletionPicker();
        } else if (prompt.marks.items.len > 0) {
            try prompt.resetMarks();
        } else {
            try prompt.setCursorAt(prompt.line.caret);
        }
    } else if (std.mem.eql(u8, ev.key, "space")) {
        // Space while browsing a listing toggles the entry under the
        // cursor in the multi-select mark set (Ctrl+click does the
        // same with the mouse). Ignored off the browse path -- a
        // literal space on the live line comes from the `.text` stream.
        if (prompt.browse_pos) |bp| try prompt.toggleHighlightAt(bp.row, bp.col, prompt.view_scroll);
    } else if (std.mem.eql(u8, ev.key, "tab")) {
        // Tab cycles the picker's selection forward when it's open
        // (zsh menu-select style, alongside Down); otherwise it's
        // filename completion on the live line, which does nothing
        // while browsing scrollback.
        if (prompt.completion_picker != null) {
            try prompt.moveCompletionPicker(1);
        } else if (prompt.browse_pos == null) {
            try prompt.doComplete();
        }
    } else if (ctrl and std.mem.eql(u8, ev.key, "backspace")) {
        // Bash's Ctrl+Backspace/Ctrl+Delete (unix-word-rubout /
        // kill-word), stopping at the same class boundaries as
        // Ctrl+Left/Right below rather than bash's whitespace-only
        // rule -- see `deleteWordBackward`'s doc comment.
        try prompt.deleteWordBackward();
    } else if (ctrl and std.mem.eql(u8, ev.key, "delete")) {
        try prompt.deleteWordForward();
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
        try prompt.moveCursorTo(prompt.line.text().len);
    } else if (ctrl and std.mem.eql(u8, ev.key, "u")) {
        try prompt.killToStart();
    } else if (ctrl and std.mem.eql(u8, ev.key, "k")) {
        // readline's kill-line, the mirror of ctrl+u -- the shared
        // field has it, so the prompt may as well bind it.
        try prompt.killToEnd();
    } else if (ctrl and std.mem.eql(u8, ev.key, "l")) {
        try prompt.clearScreen();
    } else if (ctrl and std.mem.eql(u8, ev.key, "r")) {
        try prompt.historySearch();
    } else if (alt and std.mem.eql(u8, ev.key, "d")) {
        // Drops `cd <cwd>` onto the line to be edited into the
        // directory you actually want -- see `cdCwdLine`.
        try prompt.cdCwdLine();
    } else if (alt and std.mem.eql(u8, ev.key, "c")) {
        // fzf's chord for "cd into a directory I pick" -- see
        // `dirSearch`.
        try prompt.dirSearch();
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
        // The picker (if open) takes priority over browse mode too --
        // Ctrl+Up/Down move the selection exactly like plain Up/Down
        // do below rather than jumping by `scrollback_jump`, since the
        // picker's own list is short. Otherwise, Ctrl+Up breaks into
        // scrollback browse mode from the live prompt (a one-row step
        // off the input line); once browsing it's a bigger jump
        // (`scrollback_jump` rows, default 5) for scanning a long
        // listing faster.
        if (prompt.completion_picker != null) {
            try prompt.moveCompletionPicker(-1);
        } else if (prompt.browse_pos != null) {
            try prompt.browseUp(prompt.scrollbackJumpRows());
        } else {
            try prompt.browseUp(1);
        }
    } else if (ctrl and std.mem.eql(u8, ev.key, "down")) {
        // The mirror jump while browsing. At the live prompt there's
        // nothing below the input line, so Ctrl+Down does nothing.
        if (prompt.completion_picker != null) {
            try prompt.moveCompletionPicker(1);
        } else if (prompt.browse_pos != null) {
            try prompt.browseDown(prompt.scrollbackJumpRows());
        }
    } else if (ctrl and std.mem.eql(u8, ev.key, "page_up")) {
        // Ctrl+PgUp jumps the cursor to the previous metadata-id
        // span's landing cell (a gw-ls entry, say) -- the span's
        // focus cell if it named one, which is how a `gw-ls -l` row
        // lands on the filename rather than the permissions column,
        // else its first visible character. Enters scrollback browse
        // mode from the live prompt if needed.
        try prompt.metadataJump(.prev);
    } else if (ctrl and std.mem.eql(u8, ev.key, "page_down")) {
        // The mirror toward the live tail. A no-op at the live prompt
        // (nothing tagged below the input line).
        try prompt.metadataJump(.next);
    } else if (std.mem.eql(u8, ev.key, "up")) {
        // Moves the picker's selection when it's open. Otherwise plain
        // Up is readline-style history recall at the prompt, a
        // one-row browse step while already in scrollback mode.
        if (prompt.completion_picker != null) {
            try prompt.moveCompletionPicker(-1);
        } else if (prompt.browse_pos != null) {
            try prompt.browseUp(1);
        } else {
            try prompt.historyUp();
        }
    } else if (std.mem.eql(u8, ev.key, "down")) {
        if (prompt.completion_picker != null) {
            try prompt.moveCompletionPicker(1);
        } else if (prompt.browse_pos != null) {
            try prompt.browseDown(1);
        } else {
            try prompt.historyDown();
        }
    } else if (std.mem.eql(u8, ev.key, "left")) {
        // Not explicitly asked for, but needed alongside ctrl+left/
        // right: without plain single-character movement too, the
        // caret (drawn by glyphwire-host wherever the raw grid cursor
        // sits) could wander away from `prompt.line.caret` -- the offset
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
            try prompt.moveCursorTo(prompt.line.prevOffset());
        }
    } else if (std.mem.eql(u8, ev.key, "right")) {
        if (prompt.browse_pos != null) {
            try prompt.browseRight(1);
        } else if (prompt.completion_picker == null and prompt.line.caret == prompt.line.text().len) {
            try prompt.acceptCompletionHintOrComplete();
        } else {
            // While the picker is open this just moves the cursor --
            // `moveCursorTo` closes it, same as every other explicit
            // reposition.
            try prompt.moveCursorTo(prompt.line.nextOffset());
        }
    }
}

/// Plays a file of shell commands through `prompt`, one line at a time,
/// each `setLine` + `submitLine` -- the exact path a typed-and-entered
/// line takes, so a scripted `ls` blocks on its child and draws to the
/// grid identically. Lines are trimmed; blank lines and `#` comments are
/// skipped. Stops early if a line was `exit` (sets `prompt.should_exit`).
/// See `runStartupScript` for why this exists.
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

pub const CompletionSource = completion.CompletionSource;
pub const completionSourceTag = completion.completionSourceTag;
pub const CompletionCandidate = completion.CompletionCandidate;
pub const CompletionPickerState = completion.CompletionPickerState;

/// The core builtins `dispatchLine` recognises by name (see the
/// precedence comment there). Offered by Tab completion in command
/// position alongside aliases and script builtins. `alias` is handled a
/// step earlier than the rest but is still a name worth completing.
pub const core_builtin_names = [_][]const u8{ "alias", "cd", "exit", "export", "fg", "gwssh", "jobs", "reload", "unalias", "unset", "zj" };

/// Where `assets/scripts/provision_remote.lua` puts the remote-side
/// binaries. Deliberately *not* on the remote `PATH` -- the minimal one a
/// non-login `ssh -T` session gets has no user prefix on it -- so `gwssh`
/// names this path when the agent turns up missing, rather than leaving
/// the user to go and read the provisioning script.
///
/// Passed through to the remote shell unexpanded: nothing in the builtin
/// dispatch path expands `~`, so the far side resolves it against the
/// remote home, which is the one that matters.
pub const provisioned_agent_path = "~/.local/share/glyphwire/bin/gw-agent";

pub const AliasTable = builtins.AliasTable;

/// One marked `ls` entry -- the `kind` / `path` / `mimetype` fields
/// parsed out of a `HighlightState` entry's metadata blob (owned,
/// `client.alloc`). The mark set is rebuilt wholesale from every
/// `toggle_highlight` / `clear_highlight` response (`applyHighlight`); the
/// host owns which ids are highlighted and their on-screen tint.
const Mark = struct {
    path: []const u8,
    kind: []const u8,
    mimetype: ?[]const u8,
    line: ?u64 = null,
};

/// Where the in-flight directory change came from -- read by
/// `Prompt.queueChdirListing` to honour `on{ chdir = { list = "metadata" } }`.
/// `.metadata` is a directory activated in gw-ls output (a click, or
/// Enter/Space while browsing); `.command` is a typed `cd`, a `zj` jump,
/// or a script's `sh.chdir`. See `Prompt.chdir_method`.
const ChdirMethod = enum { command, metadata };

/// The prompt's line-editing state. Tracks where the current line started
/// and a cursor *offset* into the line -- needed the moment editing can
/// happen anywhere but the end (ctrl+a/e/u, ctrl+arrow word jumps, plain
/// arrow movement). `buffer` mirrors the line's text locally: the server
/// holds the authoritative cells, but word-jump math (`wordLeft`/
/// `wordRight`) needs to inspect characters, and `submitLine` echoes the
/// full line to scrollback, neither of which is worth a round trip to
/// read back over the wire.
/// Timed phases of a prompt redraw (see `renderInputLine` /
/// `drawRightChain`). `right_chain` nests inside `prompt_render` when the
/// redraw refreshes the powerline right side.
const ShellSpan = enum { prompt_render, right_chain };
/// Per-tick counters for the prompt profiler.
const ShellCounter = enum { batch_sends };
const ShellProfiler = glyphwire.Profiler(ShellSpan, ShellCounter);

/// Builds the prompt profiler from `GLYPHWIRE_SHELL_PROFILE` (periodic
/// summary interval in ms; unset / 0 / non-numeric = profiling off).
/// Output is a `std.log` table on that cadence -- there is no shell HUD
/// and no wire surface. Handy against the "prompt feels slow" work: set
/// `GLYPHWIRE_SHELL_PROFILE=2000` and watch `prompt_render` p95 / max.
fn shellProfilerFromEnv(io: std.Io, environ_map: *const std.process.Environ.Map) ShellProfiler {
    const raw = environ_map.get("GLYPHWIRE_SHELL_PROFILE") orelse return ShellProfiler.init(io, false, 0, 0);
    const ms = std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r\n")) catch 0;
    if (ms <= 0) return ShellProfiler.init(io, false, 0, 0);
    // The averaging window and the log cadence are the same value here:
    // each dumped table is an average over exactly the last `ms`.
    return ShellProfiler.init(io, true, ms, ms);
}

pub const Prompt = struct {
    client: *glyphwire.Client,
    /// The environment as it was at startup -- a read-only snapshot from
    /// `std.process.Init`. Everything that doesn't change over a session
    /// (`$USER`, `$HOME`, `$XDG_*`, hostname) reads from here.
    environ_map: *const std.process.Environ.Map,
    /// Prompt-redraw profiler. Disabled by default (its `io` is only ever
    /// touched on the enabled path); `runPrompt` replaces it with a real
    /// one built from `GLYPHWIRE_SHELL_PROFILE` (see `shellProfilerFromEnv`).
    profiler: ShellProfiler = .{ .io = undefined, .enabled = false },
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
    /// The line being typed: its bytes plus the caret (a byte offset)
    /// where the next insert/delete acts and where the on-screen cursor
    /// should sit. The editing itself -- word jumps, Ctrl+Backspace,
    /// Ctrl+U -- is `lineedit.LineEdit`'s, shared with salacommander's
    /// path row and zoe's `:` line; what stays here is everything that
    /// makes it a *shell* prompt: the incremental repaint, history
    /// recall, completion. `.flatten_newlines` because a multi-line
    /// paste at a prompt should become space-separated arguments rather
    /// than lose its line breaks silently.
    line: lineedit.LineEdit = .{ .controls = .flatten_newlines },
    /// Set by `submitLine` when the typed line was `exit` -- the caller
    /// (`runPrompt`'s key loop) checks this after every submitted line and
    /// returns instead of drawing another prompt, ending this process.
    should_exit: bool = false,
    /// Programs put in the background (see `foregroundJob`), oldest
    /// first. Each is heap-owned; `reportFinishedJobs` reaps and frees the
    /// ones that exit, `hangUpJobs` the rest on the way out.
    jobs: std.ArrayList(*Job) = .empty,
    /// The last `[n]` handed out. Numbers aren't reused within a session,
    /// so `fg 2` never means a different program than it did a minute ago.
    next_job_id: u32 = 0,
    /// The rest of a line whose background job has exited, oldest first,
    /// waiting for `runReadyChains`. Filled by `reportFinishedJobs`.
    ready_chains: std.ArrayList(ReadyChain) = .empty,
    /// Scratch `jobTitle` copies a context title into.
    job_title_buf: [glyphwire.Context.max_title_len]u8 = undefined,
    /// Every non-empty line ever submitted, oldest first -- `submitLine`
    /// appends to it, `historyUp`/`historyDown` read from it. Each entry
    /// is an owned dupe (the submitted line's `buffer` gets cleared by the
    /// next `showPrompt`, so history can't just borrow it).
    history: std.ArrayList([]const u8) = .empty,
    /// Alias bindings from the `alias` builtin -- see `AliasTable` and
    /// `expandAliases`. Empty until the user defines one.
    aliases: AliasTable = .{},
    /// Fish-style inline autocomplete hint: after the prompt has been idle
    /// for `autocomplete_idle_ms`, the first completion candidate's suffix
    /// is drawn in a dim colour after the caret. The real line buffer is
    /// unchanged; every edit hides the hint and arms a new idle delay.
    completion_hint: std.ArrayList(u8) = .empty,
    completion_hint_visible: bool = false,
    completion_hint_dirty: bool = true,
    completion_hint_activity_at: ?std.Io.Clock.Timestamp = null,
    /// The interactive Tab-completion dropdown, non-null while it's on
    /// screen -- see `CompletionPickerState` and
    /// `Prompt.recomputeAndDrawPicker`.
    completion_picker: ?CompletionPickerState = null,
    /// `null` means the line on screen is the one actually being typed
    /// (not a recalled history entry). Otherwise, an index into `history`
    /// for whichever entry `historyUp`/`historyDown` last loaded.
    history_index: ?usize = null,
    /// Set by `runCommand` when the child it just reaped wrote something
    /// to its result pipe (see `result_fd_env`) -- owned, taken (and
    /// nulled) by `takePendingResultLine`. `showPrompt` picks it up for a
    /// plain typed invocation; `historySearch` (Ctrl+R) takes it directly
    /// instead of waiting for the next prompt.
    pending_result_line: ?[]u8 = null,
    /// What `buffer` held right before the first `historyUp` of a
    /// recall -- `historyDown` past the newest entry restores this,
    /// mirroring a real shell's "go back to what I was typing" behavior.
    /// Only meaningful while `history_index != null`.
    scratch: std.ArrayList(u8) = .empty,
    /// The drawing surface's size -- fetched once at startup (`runPrompt`)
    /// to clamp browse-mode horizontal movement (`browseLeft`/`browseRight`)
    /// and to keep the prompt from `setCursor`ing off the bottom row after
    /// a command's output scrolled the layer.
    grid_cols: usize = 0,
    grid_rows: usize = 0,
    /// Whether keystrokes are ours. Always true for a shell that owns its
    /// context; embedded, the host says (`focus` / `blur` over the
    /// control pipe), because the input stream is delivered per context
    /// and both programs see all of it. See `shell/embed.zig`.
    focused: bool = true,
    /// The host's control pipe while embedded -- `cd`, `focus`, `blur`,
    /// `size` and `quit`, drained between keystrokes. Borrowed from
    /// `runPrompt`.
    control: ?*embed.Control = null,
    /// A directory the host asked for that hasn't been taken yet: applied
    /// before the next prompt is drawn rather than the moment it arrives,
    /// so following the file pane never lands in the middle of a command
    /// or a half-typed line. Owned.
    pending_cd: ?[]u8 = null,
    /// The layer the prompt draws on. Null is this shell's own context's
    /// root layer -- the normal case, and what every `draw*` helper below
    /// falls back to. `--embed` sets it to a layer another client created
    /// in a context of its own (salacommander's popup), and from then on
    /// the shell is a panel inside somebody else's window: same prompt,
    /// same pty loop, a different surface. See `Embed`.
    layer: ?glyphwire.LayerHandle = null,
    /// The context title last sent (`syncTitle`), so a prompt that didn't
    /// change it costs no message.
    title_buf: [glyphwire.Context.max_title_len]u8 = undefined,
    title_len: usize = 0,
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
    /// `$XDG_CONFIG_HOME/glyphwire` (or `$HOME/.config/glyphwire`),
    /// `null` when neither is set. Kept for the session rather than used
    /// and dropped at startup because `reload` has to find
    /// `shell.conf.lua` again long after `runPrompt` resolved the path.
    /// Owned; freed in `deinit`.
    config_dir: ?[]const u8 = null,
    /// Whether `shell.conf.lua`'s `theme(...)` gave this context its own
    /// theme, so a `reload` without one can hand it back to the window's.
    own_theme: bool = false,
    /// Absolute path to `~/.config/glyphwire/history`, set by
    /// `loadHistory` once it knows the config directory exists. `null`
    /// when there's no `$HOME`/`$XDG_CONFIG_HOME` to derive it from, or
    /// the directory couldn't be created -- history just isn't persisted
    /// then. Owned; freed in `deinit`.
    history_path: ?[]const u8 = null,

    /// Directory-jump database behind the `zj` builtin (`z` / zoxide
    /// style) -- every `cd` records the new directory here, `zj QUERY`
    /// picks the best-ranked match. `null` when there's no config
    /// directory or `$GLYPHWIRE_NO_HISTORY` opted this session out; the
    /// builtin then just reports it's unavailable. See `zjump.zig`.
    zdb: ?zjump.Db = null,
    /// Absolute path to `~/.config/glyphwire/z.db`; `null` alongside a
    /// `null` `zdb` or when the db is memory-only. Owned; freed in `deinit`.
    zdb_path: ?[]const u8 = null,
    /// Whether `zj` records visits and answers queries at all -- turned
    /// off by `zj{ enabled = false }` in `shell.conf.lua`. The db is still
    /// loaded (so flipping it back on mid-config-reload isn't lossy) but
    /// left untouched.
    zj_enabled: bool = true,
    /// Directories `zj` never records or returns, from
    /// `zj{ exclude_dirs = { ... } }`, with a leading `~` expanded. Owned
    /// (built by `loadStartupConfig`); each string and the slice are
    /// freed in `deinit`.
    zj_excludes: [][]const u8 = &.{},

    /// Lines submitted since the last flush, oldest first -- the *delta*
    /// the next flush appends to whatever the history file holds by then
    /// (`history.mergeSerialize`). Not a second copy of `self.history`:
    /// writing that whole list back is what let one shell revert another
    /// shell's lines, since it still carries the snapshot this session
    /// loaded at startup. Owned; each entry and the list are freed in
    /// `deinit`, and the list is emptied by every successful flush.
    history_pending: std.ArrayList([]const u8) = .empty,
    /// The `z.db` counterpart of `history_pending`: this session's visits
    /// and prunes as deltas, replayed onto the re-read file at flush time.
    /// See `zjump.Journal`. `null` alongside a `null` `zdb`.
    zdb_journal: ?zjump.Journal = null,

    /// Set when `history_pending` has anything in it. History is kept in
    /// memory and flushed lazily (see `persist_gate` /
    /// `flushPersistentState`) rather than rewritten on every submitted
    /// line.
    history_dirty: bool = false,
    /// Set when `zdb_journal` has anything in it.
    zdb_dirty: bool = false,
    /// Decides when the two lazily-flushed files (history, `z.db`) get
    /// written: after enough changes, or enough elapsed time, whichever
    /// comes first -- plus an unconditional flush on a clean exit and on
    /// the host's `shutdown` notification. See `flushgate.zig`.
    persist_gate: flushgate.FlushGate = .{},

    /// The persistent Lua interpreter -- runs `shell.conf.lua` and every
    /// script builtin (`~/.config/glyphwire/scripts/*.lua`, `defcmd`).
    /// `null` when the shell has no config directory. Heap-allocated and
    /// owned; `deinit` tears it down.
    script_engine: ?*script_engine.ScriptEngine = null,

    /// The parsed `shell.conf.lua`, kept alive for the whole session so the
    /// prompt can read `.prompt` live on every redraw (see `promptCfg` /
    /// `writePromptPrefix`). `null` when there was no config file or no
    /// config directory. Borrowed from `script_engine.?.cfg` -- the
    /// engine owns the storage, not this pointer.
    prompt_config: ?*const config.ShellConfig = null,

    /// How the directory change currently being dispatched was
    /// initiated. `activateSelectionAt` / `runMarkedAction` set it to
    /// `.metadata` before they submit; `submitLine` resets it to
    /// `.command` on the way out, so a typed `cd` / `zj` / `sh.chdir`
    /// always sees `.command`. Read by `queueChdirListing`.
    chdir_method: ChdirMethod = .command,
    /// The `on{ chdir }` listing command to run once the line that
    /// triggered a directory change finishes dispatching, or null. Set by
    /// `queueChdirListing` after a qualifying change, consumed (and
    /// cleared) by `submitLine`. Borrows `prompt_config`'s arena-owned
    /// string -- not freed here.
    chdir_pending_list: ?[]const u8 = null,

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

    pub fn deinit(self: *Prompt) void {
        const alloc = self.client.alloc;
        // Last chance to persist -- covers the `exit` builtin and the
        // socket-close (host gone) paths, which reach here without going
        // through the explicit `shutdown` flush. `.due` rather than
        // `.force` so an untouched session writes nothing.
        self.flushPersistentState(.due);
        self.hangUpJobs();
        for (self.ready_chains.items) |*rc| rc.rest.deinit();
        self.ready_chains.deinit(alloc);
        for (self.history.items) |line| alloc.free(line);
        self.history.deinit(alloc);
        self.clearHistoryPending();
        self.history_pending.deinit(alloc);
        self.scratch.deinit(alloc);
        self.line.deinit(alloc);
        if (self.pending_cd) |p| alloc.free(p);
        self.completion_hint.deinit(alloc);
        if (self.pending_result_line) |line| alloc.free(line);
        self.aliases.deinit(alloc);
        for (self.marks.items) |m| freeMark(alloc, m);
        self.marks.deinit(alloc);
        if (self.config_dir) |p| alloc.free(p);
        if (self.history_path) |p| alloc.free(p);
        if (self.zdb) |*db| db.deinit();
        if (self.zdb_journal) |*j| j.deinit();
        if (self.zdb_path) |p| alloc.free(p);
        self.clearZjExcludes();
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
    pub fn resetCmdVars(self: *Prompt) void {
        const alloc = self.client.alloc;
        var it = self.cmd_var_cache.valueIterator();
        while (it.next()) |v| alloc.free(v.*);
        self.cmd_var_cache.clearRetainingCapacity();
        self.cmd_var_depth = 0;
    }

    /// The parsed prompt config, or `null` when there's no `shell.conf.lua`.
    pub fn promptCfg(self: *Prompt) ?*const config.PromptConfig {
        if (self.prompt_config) |pcfg| return &pcfg.prompt;
        return null;
    }

    /// `prompt.dur_min_ms` if set, else the built-in default.
    pub fn durMinMs(self: *Prompt) u64 {
        if (self.promptCfg()) |p| if (p.dur_min_ms) |m| return m;
        return 2000;
    }

    /// Scrolloff for scrollback browsing (see `default_scrolloff`):
    /// `prompt.scrolloff` if set, else the default, clamped by
    /// `browsescroll.clampScrolloff` so the cursor still has room to move
    /// between the prompt row and the top margin.
    pub fn scrolloffRows(self: *Prompt) usize {
        const want: usize = if (self.promptCfg()) |p|
            (if (p.scrolloff) |s| @as(usize, s) else default_scrolloff)
        else
            default_scrolloff;
        return browsescroll.clampScrolloff(want, self.line_start_row);
    }

    /// Rows a Ctrl+Up / Ctrl+Down jump covers while browsing scrollback
    /// (see `default_scrollback_jump`): `prompt.scrollback_jump` if set,
    /// else the default. Floored at 1 so a jump always moves.
    pub fn scrollbackJumpRows(self: *Prompt) usize {
        if (self.promptCfg()) |p| if (p.scrollback_jump) |n| return @max(@as(usize, n), 1);
        return default_scrollback_jump;
    }

    /// Max rows the interactive Tab-completion picker shows at once
    /// (see `default_completion_max_items`): `prompt.completion_max_items`
    /// if set, else the default. Floored at 1.
    pub fn completionMaxItems(self: *Prompt) usize {
        if (self.promptCfg()) |p| if (p.completion_max_items) |n| return @max(@as(usize, n), 1);
        return default_completion_max_items;
    }

    /// Whether typing a printable character while browsing scrollback
    /// ends browse mode and inserts it on the live line (the default),
    /// vs. being ignored until Escape. Config:
    /// `prompt{ scrollback_type_exits = false }`.
    pub fn scrollbackTypeExits(self: *Prompt) bool {
        if (self.promptCfg()) |p| if (p.scrollback_type_exits) |b| return b;
        return true;
    }

    // ── Completion (completion.zig) ──────────────────────────────────────
    pub const armCompletionHint = completion.armCompletionHint;
    pub const hideCompletionHint = completion.hideCompletionHint;
    pub const doComplete = completion.doComplete;
    pub const appendCommandNameCandidates = completion.appendCommandNameCandidates;
    pub const collectCompletionCandidates = completion.collectCompletionCandidates;
    pub const sortCompletionCandidates = completion.sortCompletionCandidates;
    pub const maybeShowCompletionHint = completion.maybeShowCompletionHint;
    pub const acceptCompletionHintOrComplete = completion.acceptCompletionHintOrComplete;
    pub const completionDir = completion.completionDir;
    pub const recomputeAndDrawPicker = completion.recomputeAndDrawPicker;
    pub const reservePickerRows = completion.reservePickerRows;
    pub const moveCompletionPicker = completion.moveCompletionPicker;
    pub const refreshCompletionPickerIfOpen = completion.refreshCompletionPickerIfOpen;
    pub const acceptCompletionPicker = completion.acceptCompletionPicker;
    pub const closeCompletionPicker = completion.closeCompletionPicker;

    /// Fills `host`/`host_buf` from `$HOSTNAME` or `/etc/hostname`. Best
    /// effort: leaves `host` empty (so `{host}` renders nothing) on any
    /// failure. Called once at startup.
    pub fn resolveHostname(self: *Prompt) void {
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

    /// The `ssh` destination this shell was reached through, or empty when
    /// it is local. Set by `gw-agent` when it spawns the remote shell, so
    /// it is inherited by everything the shell launches too -- a remote
    /// `zoe` can tell where it is by the same variable.
    pub fn remoteDest(self: *Prompt) []const u8 {
        return self.env.get("GLYPHWIRE_REMOTE") orelse "";
    }

    /// The bundled prompt icons (`assets/icons/...`) are 32x32.
    pub const icon_native_px: u32 = 32;

    // ── Prompt rendering (render.zig) ────────────────────────────────────
    pub const resolveIconMetrics = render.resolveIconMetrics;
    pub const writePromptPrefix = render.writePromptPrefix;
    pub const cursorAfter = render.cursorAfter;
    pub const writeDefaultPrefix = render.writeDefaultPrefix;
    pub const PromptDataBufs = render.PromptDataBufs;
    pub const buildPromptData = render.buildPromptData;
    pub const cmdVarResolver = render.cmdVarResolver;
    pub const resolveCmdVarThunk = render.resolveCmdVarThunk;
    pub const resolveCmdVar = render.resolveCmdVar;
    pub const runCmdVar = render.runCmdVar;
    pub const cmdWhenTrue = render.cmdWhenTrue;
    pub const formatTime = render.formatTime;
    pub const writeTemplatedPrefix = render.writeTemplatedPrefix;
    pub const RenderedSeg = render.RenderedSeg;
    pub const renderChain = render.renderChain;
    pub const chainWidth = render.chainWidth;
    pub const ChainSink = render.ChainSink;
    pub const sinkSetCursor = render.sinkSetCursor;
    pub const sinkWriteText = render.sinkWriteText;
    pub const sinkWriteTextTransparent = render.sinkWriteTextTransparent;
    pub const sinkDrawIconStyled = render.sinkDrawIconStyled;
    pub const drawChain = render.drawChain;
    pub const drawRightChain = render.drawRightChain;
    pub const writePowerlinePrefix = render.writePowerlinePrefix;
    pub const writeSpaces = render.writeSpaces;
    pub const EmitOpts = render.EmitOpts;
    pub const emitOps = render.emitOps;
    pub const collapseHome = render.collapseHome;
    pub const caretCol = render.caretCol;
    pub const renderInputLine = render.renderInputLine;
    pub const appendInputLine = render.appendInputLine;
    pub const placeInputCursor = render.placeInputCursor;
    pub const showPrompt = render.showPrompt;

    /// The working directory shown in the prompt -- the maintained
    /// `$PWD` (see `chdir`'s doc comment) rather than the process's raw
    /// physical cwd, so a directory reached through a symlink keeps the
    /// symlink's own name. Falls back to the real physical cwd if `$PWD`
    /// is somehow unset (seeded at startup in `runPrompt`, so only a
    /// script explicitly unsetting it hits this path).
    pub fn logicalCwd(self: *Prompt, buf: []u8) []const u8 {
        if (self.env.get("PWD")) |pwd| return pwd;
        const n = std.process.currentPath(self.client.io, buf) catch 0;
        return buf[0..n];
    }

    // ── The host's control pipe (`--embed`) ─────────────────────────────

    /// Reads whatever the host has said since the last pass and acts on
    /// it. Called from the prompt loop rather than from a reader thread:
    /// a directive that arrives mid-command shouldn't take effect until
    /// the loop is somewhere it can honour it.
    pub fn drainControl(self: *Prompt) void {
        const ctl = self.control orelse return;
        ctl.drain(self, applyDirective) catch {};
        // Every writer closed: the host exited and took the layer we draw
        // on with it.
        if (ctl.host_gone) self.should_exit = true;
    }

    pub fn applyDirective(self: *Prompt, d: embed.Directive) void {
        switch (d) {
            .cd => |path| {
                const alloc = self.client.alloc;
                const copy = alloc.dupe(u8, path) catch return;
                if (self.pending_cd) |old| alloc.free(old);
                self.pending_cd = copy;
            },
            .focus => self.setFocused(true),
            .blur => self.setFocused(false),
            // The host re-placed the panel's layer. Re-laid out through
            // the same path a window resize takes, so the prompt lands
            // where the new size puts it.
            .size => {
                const size = self.drawGetSize() catch return;
                if (size.cols == self.grid_cols and size.rows == self.grid_rows) return;
                self.handleResize(size.cols, size.rows) catch {};
            },
            .quit => self.should_exit = true,
        }
    }

    /// Takes the keyboard, or gives it back. Embedded, the caret is the
    /// host's context's: the panel points it at its own layer, in the
    /// host's configured shape rather than whatever the host drew its own
    /// caret with, while it's typing.
    ///
    /// Giving it back sends nothing. The host is the one taking the
    /// keyboard, and it sets the caret up for itself (see
    /// `applib/shellpanel.zig`); a hide from here would land after the
    /// host's own caret for the mode it returned to, and win.
    pub fn setFocused(self: *Prompt, on: bool) void {
        if (self.focused == on) return;
        self.focused = on;
        if (self.layer) |l| {
            if (on) {
                self.client.setCaretLayer(l) catch {};
                self.client.setCaretShape(null) catch {};
                self.client.setCaretVisible(true) catch {};
            }
        }
    }

    /// Re-reads the drawing surface's size. Embedded, a `resize` reports
    /// the *context* -- the host's whole window -- while what matters is
    /// the panel's layer, which the host resizes on its own schedule.

    /// Applies a directory the host asked for, if one is waiting. Called
    /// where a new prompt is about to be drawn.
    pub fn applyPendingCd(self: *Prompt) void {
        const path = self.pending_cd orelse return;
        self.pending_cd = null;
        defer self.client.alloc.free(path);
        self.chdir(path) catch {};
    }

    // ── The drawing surface ─────────────────────────────────────────────
    //
    // Every draw the prompt makes goes through one of these rather than
    // straight at `client`, so that `layer` decides where it lands. With
    // no `--embed` the layer is null and each of them is the plain
    // root-layer call it replaced; embedded, the same prompt paints a
    // panel in someone else's context. The batch forms take the frame to
    // add to, since a `Batch` mirrors `Client` message for message.

    pub fn drawText(self: *Prompt, text: []const u8, fg: ?glyphwire.Color, bg: ?glyphwire.Color) !void {
        try self.client.writeText(text, .{ .layer = self.layer, .fg = fg, .bg = bg });
    }

    pub fn drawTextTransparent(self: *Prompt, text: []const u8, fg: ?glyphwire.Color) !void {
        try self.client.writeText(text, .{ .layer = self.layer, .fg = fg, .transparent_bg = true });
    }

    pub fn batchText(self: *Prompt, b: *glyphwire.Client.Batch, text: []const u8, fg: ?glyphwire.Color, bg: ?glyphwire.Color) !void {
        try b.writeText(text, .{ .layer = self.layer, .fg = fg, .bg = bg });
    }

    pub fn drawSetCursor(self: *Prompt, row: usize, col: usize) !void {
        if (self.layer) |l| return self.client.setCursorOn(l, row, col);
        try self.client.setCursor(row, col);
    }

    pub fn batchSetCursor(self: *Prompt, b: *glyphwire.Client.Batch, row: usize, col: usize) !void {
        if (self.layer) |l| return b.setCursorOn(l, row, col);
        try b.setCursor(row, col);
    }

    pub fn batchClear(self: *Prompt, b: *glyphwire.Client.Batch, row: usize, col: usize, rows: ?usize, cols: ?usize) !void {
        try b.clearOn(self.layer, row, col, rows, cols);
    }

    pub fn drawGetCursor(self: *Prompt) !glyphwire.Cursor {
        return self.client.getCursorOn(self.layer);
    }

    pub fn drawClear(self: *Prompt, row: usize, col: usize, rows: ?usize, cols: ?usize) !void {
        try self.client.clearOn(self.layer, row, col, rows, cols);
    }

    pub fn drawScrollView(self: *Prompt, offset: ?usize, delta: ?i64) !glyphwire.LayerScroll {
        return self.client.scrollViewOn(self.layer, offset, delta);
    }

    pub fn drawGetScroll(self: *Prompt) !glyphwire.LayerScroll {
        return self.client.getScrollOn(self.layer);
    }

    pub fn drawGetCells(self: *Prompt) !glyphwire.CellsSnapshot {
        if (self.layer) |l| return self.client.getCellsOn(l);
        return self.client.getCells();
    }

    pub fn drawGetCellsView(self: *Prompt, view_offset: usize) !glyphwire.CellsSnapshot {
        return self.client.getCellsViewOn(self.layer, view_offset);
    }

    pub fn drawGetMetadata(self: *Prompt, row: usize, col: usize, view_offset: usize) @TypeOf(self.client.getMetadata(null, 0, 0, 0)) {
        return self.client.getMetadata(self.layer, row, col, view_offset);
    }

    pub fn drawFindMetadata(self: *Prompt, above: i64, col: usize, dir: glyphwire.MetadataSpanDir) !?glyphwire.MetadataSpanHit {
        return self.client.findMetadata(self.layer, above, col, dir);
    }

    pub fn drawToggleHighlight(self: *Prompt, row: usize, col: usize, view_offset: usize) !glyphwire.HighlightSnapshot {
        return self.client.toggleHighlight(self.layer, row, col, view_offset);
    }

    pub fn drawActivateAt(self: *Prompt, row: usize, col: usize, view_offset: usize) !glyphwire.Client.ActivateResult {
        return self.client.activateAt(self.layer, row, col, view_offset);
    }

    pub fn drawClearHighlight(self: *Prompt) !glyphwire.HighlightSnapshot {
        return self.client.clearHighlight(self.layer);
    }

    pub fn drawIconStyled(self: *Prompt, row: usize, col: usize, name: []const u8, opts: glyphwire.Client.DrawIconOpts) !void {
        if (self.layer) |l| return self.client.drawIconOnStyled(l, row, col, name, opts);
        try self.client.drawIconStyled(row, col, name, opts);
    }

    /// A cell the host reported, in the surface's own frame -- or null
    /// when it landed somewhere the surface isn't.
    ///
    /// Owning the context, the surface *is* the root grid and a context
    /// cell is already a surface cell. Embedded, the panel's own corner
    /// has to come off it first -- see `embed.surfaceCell`, which is the
    /// arithmetic and the reason for it.
    ///
    /// The position is read at click time rather than cached: the host
    /// moves the panel whenever its window resizes, and one round trip is
    /// nothing on a path that is about to ask for metadata anyway.
    /// Where the surface's top-left cell sits in the context: zero when
    /// the shell owns the context, the panel's `cell_position` when
    /// embedded. Falls back to zero if the host can't be asked, which
    /// leaves a click where it used to be rather than dropping it.
    pub fn surfaceOrigin(self: *Prompt) glyphwire.CellPos {
        const layer = self.layer orelse return .{};
        return self.client.getLayerCellPosition(layer) catch .{};
    }

    pub fn surfaceCell(self: *Prompt, cell: glyphwire.CellPos) ?glyphwire.CellPos {
        const layer = self.layer orelse return cell;
        const pos = self.client.getLayerCellPosition(layer) catch return null;
        return embed.surfaceCell(cell, pos, self.grid_cols, self.grid_rows);
    }

    /// The surface's cell size: the window when the shell owns its
    /// context, the popup's layer when embedded.
    pub fn drawGetSize(self: *Prompt) !glyphwire.LayerSize {
        if (self.layer) |l| return self.client.getLayerSize(l);
        return self.client.getSize();
    }

    /// The escape-sequence machine a foreground child's byte stream needs
    /// kept across `write_text` calls, on whichever layer that stream is
    /// being written to.
    pub fn drawSetPtyMode(self: *Prompt, enabled: bool) !void {
        try self.client.setLayerPtyMode(self.layer orelse glyphwire.root_layer_handle, enabled);
    }

    /// Tells the host whether the foreground child wants the mouse
    /// (`core.Layer.mouse_report`), on the same layer its output goes to,
    /// so the host forwards raw clicks, drags and wheel notches instead
    /// of selecting text.
    pub fn drawSetMouseReport(self: *Prompt, enabled: bool) !void {
        try self.client.setLayerMouseReport(self.layer orelse glyphwire.root_layer_handle, enabled);
    }

    /// Takes and clears `pending_result_line`, if a foreground child left
    /// one -- see `runCommand`'s use of `result_fd_env`. Caller frees.
    pub fn takePendingResultLine(self: *Prompt) ?[]u8 {
        const line = self.pending_result_line;
        self.pending_result_line = null;
        return line;
    }

    /// Records a resize event without redrawing -- the re-layout waits for
    /// the size to settle (`resize_settle_ms`), since a resize drag emits
    /// one event per frame and redrawing on each looks messy. Coalesces a
    /// burst: keeps only the latest size, each event pushes the deadline.
    pub fn noteResize(self: *Prompt, cols: usize, rows: usize) void {
        self.pending_resize = .{ .cols = cols, .rows = rows };
        self.resize_seen_at = std.Io.Clock.Timestamp.now(self.client.io, .awake);
    }

    /// Applies a pending resize once it's been quiet for `resize_settle_ms`
    /// -- or immediately when `force` (the user pressed a key, so the drag
    /// is over and the keystroke should land on a correct layout).
    pub fn applyPendingResize(self: *Prompt, force: bool) !void {
        const rev = self.pending_resize orelse return;
        if (!force) {
            const quiet = self.resize_seen_at.?.untilNow(self.client.io).raw.toMilliseconds();
            if (quiet < resize_settle_ms) return;
        }
        self.pending_resize = null;
        self.resize_seen_at = null;
        self.armCompletionHint();
        // A `resize` reports the *context*: the host's whole window. When
        // this prompt is a panel inside it, what changed for us is the
        // layer the host re-placed, so ask it rather than believe the
        // event.
        const size: glyphwire.LayerSize = if (self.layer != null)
            self.drawGetSize() catch .{ .cols = rev.cols, .rows = rev.rows }
        else
            .{ .cols = rev.cols, .rows = rev.rows };
        try self.handleResize(size.cols, size.rows);
    }

    /// Takes on a resize that landed while a foreground child owned the
    /// screen (`runCommand`'s loop notes them but can't act on them) --
    /// adopting the new size and shifting the recorded prompt row, with no
    /// drawing at all.
    ///
    /// `handleResize` is the wrong tool on this path: it redraws the
    /// prompt where it used to be, and `submitLine` is about to lay a
    /// fresh one out from the server's cursor anyway. All that's needed is
    /// for `grid_cols`/`grid_rows` to describe the grid that now exists,
    /// and for `line_start_row` to follow the bottom-anchored content the
    /// same way `core.Layer.resize` moves the cursor -- it's only a
    /// fallback here, but a stale one is how the next prompt ends up over
    /// old output.
    pub fn adoptPendingResize(self: *Prompt) void {
        const rev = self.pending_resize orelse return;
        self.pending_resize = null;
        self.resize_seen_at = null;
        if (rev.cols == 0 or rev.rows == 0) return;

        // `grid_rows == 0` means no size has been learned yet (see
        // `runPrompt`'s startup snapshot), so there is no delta to shift by.
        const dh: i64 = if (self.grid_rows == 0)
            0
        else
            @as(i64, @intCast(rev.rows)) - @as(i64, @intCast(self.grid_rows));
        self.grid_cols = rev.cols;
        self.grid_rows = rev.rows;
        self.line_start_row = glyphwire.shiftRowByHeightDelta(self.line_start_row, dh, rev.rows);
        self.pl_top_row = glyphwire.shiftRowByHeightDelta(self.pl_top_row, dh, rev.rows);
        self.input_max_col = self.grid_cols;
        // The rows a browse cursor or a completion picker referred to are
        // gone, same as in `handleResize`.
        self.browse_pos = null;
        self.completion_picker = null;
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
    ///
    /// The clear + prefix redraw + input repaint go out as one `batch`
    /// frame. The clear spans the full grid width across every row the
    /// prompt occupies: growing the window widens the grid, which strands
    /// the old right chain out in the middle where nothing redraws over
    /// it, and a shrink that changes `prompt_lines`' worth of rows can
    /// leave a stale segment row above the new input line.
    pub fn handleResize(self: *Prompt, cols: usize, rows: usize) !void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.grid_cols and rows == self.grid_rows) return;

        const old_rows = self.grid_rows;
        self.grid_cols = cols;
        self.grid_rows = rows;

        // Highlights are keyed by metadata id, so they (and `self.marks`)
        // carry across a resize untouched -- the tagged cells keep their
        // tags through the reflow.

        self.browse_pos = null;
        // The picker's rows were positioned relative to the pre-resize
        // `line_start_row`/`grid_rows`; rather than try to re-derive where
        // they landed after the reflow, just drop it -- a stale dim row
        // below the new prompt is a rare, self-correcting cosmetic edge
        // case (the next redraw overwrites it), not worth chasing.
        self.completion_picker = null;
        if (self.view_scroll != 0) {
            const res = try self.drawScrollView(0, null);
            self.view_scroll = res.offset;
        }

        // The prompt's current top row: input row minus the segment rows
        // above it (0 for a single-line prompt).
        const cur_top = self.line_start_row -| (self.prompt_lines -| 1);
        const delta: isize = @as(isize, @intCast(rows)) - @as(isize, @intCast(old_rows));
        const shifted: isize = @as(isize, @intCast(cur_top)) + delta;
        const top: usize = if (shifted < 0) 0 else @min(@as(usize, @intCast(shifted)), rows -| 1);

        try self.drawSetCursor(top, 0);

        var b = self.client.batch();
        defer b.deinit();

        // Wipe the rows the prompt is about to be redrawn on, full width,
        // before anything is drawn over them -- same order, same frame.
        // `prompt_lines` is stable across a resize (it comes from config),
        // so it still describes how many rows the pre-resize prompt used.
        const span = @min(self.prompt_lines, rows -| top);
        if (span > 0) try self.batchClear(&b, top, 0, span, null);

        const start = try self.writePromptPrefix(&b);
        self.line_start_row = start.row;
        self.line_start_col = start.col;
        self.input_scroll = 0;
        try self.appendInputLine(&b);

        var res = try b.send();
        res.deinit();
    }

    /// ctrl+l: clears the screen, redraws the whole prompt (all segment
    /// rows included) at the top, then repaints the input box with
    /// whatever's already typed. Unlike `showPrompt`, doesn't touch
    /// `buffer`/`cursor`.
    pub fn clearScreen(self: *Prompt) !void {
        try self.drawClear(0, 0, null, null);
        try self.drawSetCursor(0, 0);

        const cur = try self.writePromptPrefix(null);
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;
        self.input_scroll = 0;
        self.armCompletionHint();
        try self.renderInputLine();
    }

    /// Replaces the whole line -- `buffer` and on screen -- with `text`,
    /// cursor at its end. Shared by `historyUp`/`historyDown`. With the
    /// repaint model this is just a buffer swap plus `renderInputLine`.
    pub fn setLine(self: *Prompt, text: []const u8) !void {
        self.browse_pos = null;
        if (self.view_scroll != 0) {
            const res = try self.drawScrollView(0, null);
            self.view_scroll = res.offset;
        }
        try self.line.setText(self.client.alloc, text);
        self.input_scroll = 0;
        self.armCompletionHint();
        try self.renderInputLine();
    }

    /// Up at the prompt: recalls the previous (older) history entry, most
    /// recent first. The first press of a recall stashes the in-progress
    /// line in `scratch` so `historyDown` can get back to it later;
    /// further presses just walk `history_index` back, stopping at the
    /// oldest entry rather than wrapping.
    pub fn historyUp(self: *Prompt) !void {
        if (self.history.items.len == 0) return;

        if (self.history_index) |i| {
            if (i == 0) return;
            self.history_index = i - 1;
        } else {
            self.scratch.clearRetainingCapacity();
            try self.scratch.appendSlice(self.client.alloc, self.line.text());
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
    pub fn historyDown(self: *Prompt) !void {
        const i = self.history_index orelse return;
        if (i + 1 < self.history.items.len) {
            self.history_index = i + 1;
            try self.setLine(self.history.items[self.history_index.?]);
        } else {
            self.history_index = null;
            try self.setLine(self.scratch.items);
        }
    }

    /// Deletes the codepoint before the cursor (backspace). The field
    /// does the edit; `setCursorAt` -> `renderInputLine` repaints the box
    /// (no `delete_cells` in the repaint model).
    pub fn deleteBackward(self: *Prompt) !void {
        if (!self.line.deleteBackward()) return;
        try self.afterEdit();
    }

    /// Deletes the codepoint at the cursor (forward delete).
    pub fn deleteForward(self: *Prompt) !void {
        if (!self.line.deleteForward()) return;
        try self.afterEdit();
    }

    /// Ctrl+Backspace: deletes the word behind the cursor, the same span
    /// Ctrl+Left would jump over (`wordLeft` -- character-class based, so
    /// it stops at `/` the way Ctrl+Left/Right already do on this line
    /// editor, unlike bash's whitespace-only `unix-word-rubout`).
    pub fn deleteWordBackward(self: *Prompt) !void {
        if (!self.line.deleteWordBackward()) return;
        try self.afterEdit();
    }

    /// Ctrl+Delete: deletes the word ahead of the cursor -- the mirror of
    /// `deleteWordBackward`, using `wordRight`'s span.
    pub fn deleteWordForward(self: *Prompt) !void {
        if (!self.line.deleteWordForward()) return;
        try self.afterEdit();
    }

    /// ctrl+u: deletes from the start of the line through the cursor.
    /// Unlike the other edits this closes the completion picker instead
    /// of re-filtering it -- there is no word left under the caret for it
    /// to have been filtering on.
    pub fn killToStart(self: *Prompt) !void {
        if (self.line.caret == 0) return;
        if (self.completion_picker != null) try self.closeCompletionPicker();
        _ = self.line.killToStart();
        self.armCompletionHint();
        try self.setCursorAt(0);
    }

    /// ctrl+k: deletes from the cursor to the end of the line. The
    /// mirror of `killToStart`, and picker-closing for the same reason:
    /// the word it was filtering ends at the caret.
    pub fn killToEnd(self: *Prompt) !void {
        if (self.line.caret >= self.line.text().len) return;
        if (self.completion_picker != null) try self.closeCompletionPicker();
        _ = self.line.killToEnd();
        self.armCompletionHint();
        try self.setCursorAt(self.line.caret);
    }

    /// The tail every buffer-changing edit shares: re-arm the idle
    /// autocomplete hint, repaint the input box at the field's new caret,
    /// and re-filter an open completion picker against the word now under
    /// it (an edit keeps the picker open, unlike a deliberate reposition
    /// -- see `moveCursorTo`).
    pub fn afterEdit(self: *Prompt) !void {
        self.armCompletionHint();
        try self.setCursorAt(self.line.caret);
        try self.refreshCompletionPickerIfOpen();
    }

    /// Moves the cursor without changing the buffer -- ctrl+a/ctrl+e,
    /// ctrl+arrow word jumps, and plain arrow movement all end here. Any
    /// of these is a deliberate reposition away from the word the
    /// completion picker (if open) was filtering, so it closes first --
    /// unlike an edit (`insertText`/`deleteBackward`/...), which keeps it
    /// open and re-filters instead (see `refreshCompletionPickerIfOpen`).
    pub fn moveCursorTo(self: *Prompt, offset: usize) !void {
        if (self.completion_picker != null) try self.closeCompletionPicker();
        try self.setCursorAt(offset);
    }

    /// Moves the host's scrollback view (see `Prompt.view_scroll` /
    /// `Client.scrollView`) to absolute offset `offset` and records the
    /// clamped result (offset + max) the server hands back. This is the
    /// "scroll the window along" half of browsing: `browseUp`/`browseDown`
    /// compute the target with `browsescroll` and apply it here.
    pub fn scrollWindow(self: *Prompt, offset: usize) !void {
        const res = try self.drawScrollView(offset, null);
        self.view_scroll = res.offset;
        self.view_max = res.max;
    }

    /// Refreshes `view_scroll` / `view_max` from the host without moving
    /// the view -- a get-only `get_property("scroll")` query (no `scroll`
    /// broadcast). Called when entering browse so `browsescroll.up` starts
    /// from a current scrollback size.
    pub fn syncScrollState(self: *Prompt) !void {
        const res = try self.drawGetScroll();
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
    pub fn browseUp(self: *Prompt, count: usize) !void {
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
        try self.drawSetCursor(bp.row, bp.col);
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
    pub fn browseDown(self: *Prompt, count: usize) !void {
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
            try self.setCursorAt(self.line.caret);
            return;
        }
        if (plan.view_scroll != self.view_scroll) try self.scrollWindow(plan.view_scroll);
        bp.row = plan.bp_row;
        self.browse_pos = bp;
        try self.drawSetCursor(bp.row, bp.col);
    }

    /// Left/Right while browsing: move `count` columns within whatever row
    /// the browse cursor is currently on, clamped to the grid's width
    /// (`set_property` doesn't clamp `col` itself -- see `Layer.setProperty`
    /// -- so an unclamped move here could park the caret off-grid). Plain
    /// Left/Right pass 1; ctrl+Left/Right pass `scrollbackJumpRows()` for a
    /// bigger step (matching ctrl+Up/Down while browsing). No-ops when not
    /// browsing; the caller is expected to check `browse_pos` first and
    /// call `moveCursorTo` instead (plain line editing) when it's null.
    pub fn browseLeft(self: *Prompt, count: usize) !void {
        var bp = self.browse_pos orelse return;
        bp.col -|= count;
        self.browse_pos = bp;
        try self.drawSetCursor(bp.row, bp.col);
    }

    pub fn browseRight(self: *Prompt, count: usize) !void {
        var bp = self.browse_pos orelse return;
        bp.col = @min(bp.col + count, self.grid_cols -| 1);
        self.browse_pos = bp;
        try self.drawSetCursor(bp.row, bp.col);
    }

    /// Home while browsing: move the browse cursor to column 0 of the row
    /// it's on, staying in browse mode. No-op when not browsing.
    pub fn browseHome(self: *Prompt) !void {
        var bp = self.browse_pos orelse return;
        bp.col = 0;
        self.browse_pos = bp;
        try self.drawSetCursor(bp.row, bp.col);
    }

    /// End while browsing: move the browse cursor just past the last
    /// non-blank cell of the row it's on (a fully blank row -> column 0),
    /// clamped to the grid width, staying in browse mode. No-op when not
    /// browsing. Costs one `get_cells` snapshot of the current view --
    /// acceptable on a key pressed this rarely; there's no lighter
    /// per-row text query on the wire.
    pub fn browseEnd(self: *Prompt) !void {
        var bp = self.browse_pos orelse return;
        bp.col = self.rowContentEnd(bp.row) catch bp.col;
        self.browse_pos = bp;
        try self.drawSetCursor(bp.row, bp.col);
    }

    /// The column just past the last non-blank cell of window row `row`
    /// as the view currently sits (`view_scroll`), clamped to
    /// `grid_cols - 1`. A blank row returns 0. Used by `browseEnd`.
    pub fn rowContentEnd(self: *Prompt, row: usize) !usize {
        var snap = try self.drawGetCellsView(self.view_scroll);
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

    /// Ctrl+PgUp (`dir == .prev`) / Ctrl+PgDn (`dir == .next`): move the
    /// cursor to the landing cell of the metadata-id span before / after
    /// the one it's currently on -- a gw-ls entry, typically. That's the
    /// span's *focus* cell when it declared one (see `core.Cell.meta_focus`
    /// -- a `gw-ls -l` row marks its Name column, so the cursor arrives on
    /// the filename, not the permissions the row's span starts at), else
    /// its first visible character. From the live
    /// prompt, `.prev` breaks into scrollback browse mode (like Ctrl+Up);
    /// `.next` there is a no-op, since nothing tagged sits below the input
    /// line.
    ///
    /// The span walk itself runs server-side (`find_metadata` ->
    /// `core.Layer.adjacentMetadataSpan`) so the shell never scans the grid
    /// for spans; this just turns the returned scroll-stable `above` back
    /// into a `{view_scroll, browse row}` pair, scrolling the host window
    /// if the target sits outside it (`browsescroll.locate` keeps the
    /// normal scrolloff margin above it when the scrollback allows).
    pub fn metadataJump(self: *Prompt, dir: glyphwire.MetadataSpanDir) !void {
        const entering = self.browse_pos == null;
        if (entering and dir == .next) return;

        // A rare keypress -- resync the authoritative scroll state so the
        // `locate` math below works from a current `view_max`.
        try self.syncScrollState();

        const from_row: usize, const from_col: usize = if (self.browse_pos) |bp|
            .{ bp.row, bp.col }
        else
            .{ self.line_start_row, self.line_start_col + self.caretCol() };
        // above = view_scroll - screen_row (see core.SelectionPoint).
        const from_above: i64 =
            @as(i64, @intCast(self.view_scroll)) - @as(i64, @intCast(from_row));

        const hit = (try self.drawFindMetadata(from_above, from_col, dir)) orelse return;

        const plan = browsescroll.locate(
            hit.above,
            self.scrolloffRows(),
            self.view_max,
            self.line_start_row -| 1,
        );
        if (plan.view_scroll != self.view_scroll) try self.scrollWindow(plan.view_scroll);

        const bp = glyphwire.Cursor{
            .row = plan.bp_row,
            .col = @min(hit.col, self.grid_cols -| 1),
        };
        self.browse_pos = bp;
        try self.drawSetCursor(bp.row, bp.col);
    }

    /// Enter while browsing: looks up whatever cell the browse cursor is
    /// over and acts on it. A sortable table header or an outline node the
    /// host resolves there (`activate_at`) comes first -- the keyboard form
    /// of clicking a header or a ▸/▾ marker. Failing that, with entries
    /// marked (Space / Ctrl+click), Enter runs the marked set
    /// (`runMarkedAction`); otherwise it acts on the single entry under the
    /// cursor (`activateSelectionAt`).
    pub fn browseEnter(self: *Prompt) !void {
        const bp = self.browse_pos orelse return;

        const act = try self.drawActivateAt(bp.row, bp.col, self.view_scroll);
        switch (act.action) {
            // Re-sorted in place: the header row doesn't move.
            .sorted => return,
            .toggled => {
                // The reflow changed how much history there is and may
                // have moved the view to keep the node on screen; the
                // node itself moved with its rows. Follow it so the
                // cursor stays on what was just toggled.
                try self.syncScrollState();
                var moved = bp;
                if (act.row) |r| moved.row = @min(r, self.line_start_row -| 1);
                self.browse_pos = moved;
                try self.drawSetCursor(moved.row, moved.col);
                return;
            },
            .none => {},
        }

        if (self.marks.items.len > 0) {
            try self.runMarkedAction();
        } else {
            try self.activateSelectionAt(bp.row, bp.col, self.view_scroll);
        }
    }

    /// The metadata blob glyphwire-ls tags every listed entry with (see
    /// `ls/main.zig`'s `entryMetadataJson`). `kind` and `path` are always
    /// present; `mimetype` only for a regular file; `line` only from
    /// `gw-grep`, which tags each hit and context line with its own.
    pub const MetaEntry = struct { kind: ?[]const u8 = null, path: ?[]const u8 = null, mimetype: ?[]const u8 = null, line: ?u64 = null };

    /// Parses the metadata at `(row, col)` in the view scrolled back by
    /// `view_offset`, or null if there's no tag there / it doesn't parse /
    /// it's missing `kind` or `path`. On success the caller must, in this
    /// order, `.parsed.deinit()` then free `.json` with `client.alloc`
    /// (the parsed strings can point into `json`).
    pub fn metaEntryAt(self: *Prompt, row: usize, col: usize, view_offset: usize) ?struct {
        json: []u8,
        parsed: std.json.Parsed(MetaEntry),
    } {
        const alloc = self.client.alloc;
        const lookup = self.drawGetMetadata(row, col, view_offset) catch return null;
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
    /// typed. The user's `shell.conf.lua` table is checked first, then the
    /// built-in defaults (`cd` into a directory, `gw-view` an
    /// image) -- see `shell/openaction.zig`. A no-op when nothing matches,
    /// per the "don't guess" policy: an unrecognized file type does
    /// nothing rather than guessing. `setLine` echoes the command and,
    /// via `setCursorAt`, ends any browsing / snaps the view back to the
    /// live tail before `submitLine` runs it -- the same path a typed
    /// command takes, so e.g. `gw-view`'s "wait for a keypress"
    /// blocks the prompt loop exactly as it would for a real command.
    ///
    /// `view_offset` is how far the host was scrolled back when
    /// `(row, col)` was picked -- forwarded to `get_metadata` so a click
    /// on a scrolled-back row resolves against the cell actually there.
    pub fn activateSelectionAt(self: *Prompt, row: usize, col: usize, view_offset: usize) !void {
        const alloc = self.client.alloc;

        const got = self.metaEntryAt(row, col, view_offset) orelse return;
        defer alloc.free(got.json);
        defer got.parsed.deinit();

        const line = self.openActionLine(alloc, &.{.{
            .kind = got.parsed.value.kind.?,
            .path = got.parsed.value.path.?,
            .mimetype = got.parsed.value.mimetype,
            .line = got.parsed.value.line,
        }}) catch return orelse return;
        defer alloc.free(line);

        try self.setLine(line);
        // Tell `queueChdirListing` this submit came from a gw-ls
        // activation, so `on{ chdir = { list = "metadata" } }` fires if
        // the action turns out to be a directory `cd`. `submitLine`
        // resets it regardless of what the line actually does.
        self.chdir_method = .metadata;
        try self.submitLine();
    }

    /// The command line to run for `entries` (one or more), or null when
    /// no `open_actions` entry / default matches the first entry's type.
    /// The first entry decides which action runs; `{sel}` / `{selections}`
    /// in its template expand to the shell-quoted path(s) -- a `{sel}`
    /// template given more than one entry surfaces an error line and
    /// returns null (nothing runs). `{line}` comes from the first entry
    /// too. Owned result; free with `alloc`.
    pub fn openActionLine(self: *Prompt, alloc: std.mem.Allocator, entries: []const openaction.Entry) !?[]u8 {
        std.debug.assert(entries.len >= 1);
        const user: []const openaction.Action = if (self.prompt_config) |pc| pc.open_actions.items else &.{};
        const action = openaction.resolve(user, entries[0]) orelse return null;

        const paths = try alloc.alloc([]const u8, entries.len);
        defer alloc.free(paths);
        for (entries, paths) |e, *p| p.* = e.path;

        return openaction.expand(alloc, action.commands[0], paths, entries[0].line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NeedsSingle => {
                try self.drawText(
                    "glyphwire-shell: that action opens one file at a time\n",
                    err_color,
                    null,
                );
                return null;
            },
        };
    }

    // ── Multi-select marks ─────────────────────────────────────────────

    pub fn freeMark(alloc: std.mem.Allocator, m: Mark) void {
        alloc.free(m.path);
        alloc.free(m.kind);
        if (m.mimetype) |mt| alloc.free(mt);
    }

    /// Frees every mark and empties the list -- local only, no wire
    /// traffic. `applyHighlight` and `deinit` use it.
    pub fn clearMarks(self: *Prompt) void {
        const alloc = self.client.alloc;
        for (self.marks.items) |m| freeMark(alloc, m);
        self.marks.clearRetainingCapacity();
    }

    /// Rebuilds `self.marks` from a `HighlightState` the host just sent
    /// back (`toggle_highlight` / `clear_highlight` / `set_highlight`
    /// response). Each entry carries the highlighted id's metadata blob;
    /// an entry with no blob, or one missing `kind`/`path`, is skipped.
    pub fn applyHighlight(self: *Prompt, snap: *const glyphwire.HighlightSnapshot) !void {
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

            try self.marks.append(alloc, .{ .path = path_owned, .kind = kind_owned, .mimetype = mime_owned, .line = parsed.value.line });
        }
    }

    /// Toggles the `ls` entry at `(row, col)` in the host's highlight set
    /// (`toggle_highlight`) and rebuilds `self.marks` from the response.
    /// The host resolves the cell to a metadata id, flood-fills it, and
    /// hands back every highlighted id with its blob -- the shell does no
    /// grid scanning of its own.
    pub fn toggleHighlightAt(self: *Prompt, row: usize, col: usize, view_offset: usize) !void {
        var snap = try self.drawToggleHighlight(row, col, view_offset);
        defer snap.deinit();
        try self.applyHighlight(&snap);
    }

    /// Clears the marks and the host's highlight overlay
    /// (`clear_highlight`). A no-op (no wire message) when nothing was
    /// marked.
    pub fn resetMarks(self: *Prompt) !void {
        if (self.marks.items.len == 0) return;
        var snap = try self.drawClearHighlight();
        defer snap.deinit();
        try self.applyHighlight(&snap);
    }

    /// The marked entries' paths as one line -- space-separated, in mark
    /// order, each path passed through `wordsplit.quoteArgIfNeeded` so a
    /// plain path stays bare and one with a space or a metacharacter is
    /// quoted. This is what Ctrl+Shift+C copies while a listing has marks;
    /// pasting it after a command name (`ls `, `cp ... `) gives a valid
    /// argument list. Owned; free with `alloc`.
    pub fn markedPathsText(self: *Prompt, alloc: std.mem.Allocator) ![]u8 {
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
    pub fn runMarkedAction(self: *Prompt) !void {
        if (self.marks.items.len == 0) return;
        const alloc = self.client.alloc;

        const entries = try alloc.alloc(openaction.Entry, self.marks.items.len);
        defer alloc.free(entries);
        for (self.marks.items, entries) |m, *e| {
            e.* = .{ .kind = m.kind, .path = m.path, .mimetype = m.mimetype, .line = m.line };
        }

        const line = (try self.openActionLine(alloc, entries)) orelse return;
        defer alloc.free(line);

        try self.setLine(line);
        // See `activateSelectionAt` -- same gw-ls-activation marker.
        self.chdir_method = .metadata;
        try self.submitLine();
    }

    /// The offset ctrl+right lands on -- see `lineedit.wordRightFrom`.
    pub fn wordRight(self: *const Prompt) usize {
        return self.line.wordRightOffset();
    }

    /// The offset ctrl+left lands on -- see `lineedit.wordLeftFrom`.
    pub fn wordLeft(self: *const Prompt) usize {
        return self.line.wordLeftOffset();
    }

    /// Moves the field's caret to `offset` (a byte offset into the line),
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
    pub fn setCursorAt(self: *Prompt, offset: usize) !void {
        self.browse_pos = null;
        if (self.view_scroll != 0) {
            const res = try self.drawScrollView(0, null);
            self.view_scroll = res.offset;
        }
        _ = self.line.moveTo(offset);
        try self.renderInputLine();
    }

    /// Re-echoes the whole command line unbounded from `line_start` (the
    /// input box normally shows only a horizontally-scrolled window of it)
    /// so scrollback keeps the full command, then drops to the row below
    /// the prompt line and runs it as a command if it names one (see
    /// `runCommand`), resyncing from the server before a fresh prompt.
    /// `exit` skips all of that and just sets `should_exit`.
    ///
    /// The drop is to the row the re-echo ended on (`promptrow.next` of
    /// the cursor the server reports back), so a command line long enough
    /// to wrap gets its output below the whole thing rather than over the
    /// wrapped tail.
    ///
    /// Afterwards the next prompt goes one blank row below whatever the
    /// command left behind (`promptrow.afterCommand` of the cursor the
    /// server reports). For a context-owning full-screen program (zoe)
    /// that cursor is still the row this dropped to, so its prompt lands
    /// one blank row under the command line with the shell's scrollback
    /// untouched.
    pub fn submitLine(self: *Prompt) !void {
        // A metadata activation (`activateSelectionAt` / `runMarkedAction`)
        // set `chdir_method` just before calling us; make sure it's back
        // to `.command` for the next line whichever way we return.
        defer self.chdir_method = .command;

        // Running any command spends the multi-select: drop the marks and
        // their highlight before the command's output scrolls in.
        try self.resetMarks();

        if (self.completion_hint_visible) {
            self.hideCompletionHint();
            try self.renderInputLine();
        }

        try self.drawSetCursor(self.line_start_row, self.line_start_col);
        if (self.line.text().len > 0) try self.drawText(self.line.text(), null, null);
        // Drop to the row the re-echo actually ended on, read back from
        // the server rather than assumed: a command line longer than the
        // grid wraps onto further rows here, and `line_start_row + 1`
        // (what this used to be) lands in the middle of that wrap. With
        // the repaint editor the input box scrolls horizontally instead
        // of wrapping as you type, so those wrapped rows are fresh
        // content nothing else is going to overwrite -- unlike in the
        // pre-repaint editor this rule was written for, where the line
        // had wrapped on screen already and the command's own output was
        // expected to draw over the tail.
        const echoed = self.drawGetCursor() catch
            glyphwire.Cursor{ .row = self.line_start_row, .col = self.line_start_col };
        try self.drawSetCursor(promptrow.next(echoed.row, echoed.col), 0);

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
            if (history.shouldRecord(prev, self.line.text())) {
                try self.history.append(alloc, try alloc.dupe(u8, self.line.text()));
                // The same line again in `history_pending`, which is what
                // the next flush actually appends to the file -- see that
                // field's doc comment on why the flush can't just write
                // `self.history` back.
                try self.history_pending.append(alloc, try alloc.dupe(u8, self.line.text()));
                self.history_dirty = true;
                self.persist_gate.note();
            }
        }
        self.history_index = null;

        // Cleared here (not just after) so a `sh.chdir` run from
        // `shell.conf.lua` at startup can't leave a stale listing queued for
        // the first real prompt.
        self.chdir_pending_list = null;

        try self.dispatchLine();
        self.maybeFlushPersistentState();
        if (self.should_exit) return; // "exit" (typed or via an alias) -- see dispatchLine

        // A directory change during dispatch may have queued an
        // `on{ chdir }` listing -- run it now, as its own line, after the
        // command that triggered the change (a `cd`, or the synthetic
        // `cd` a gw-ls activation submits) has completed.
        if (self.chdir_pending_list) |listing| {
            self.chdir_pending_list = null;
            try self.dispatchLineText(listing);
        }

        // A resize the foreground loop recorded but couldn't act on: adopt
        // it before anything below reads `grid_*` or `line_start_row`.
        self.adoptPendingResize();

        // Background jobs that ended while this line ran, reported under
        // its output and above the next prompt, then the rest of any line
        // one of them was holding.
        self.reportFinishedJobs();
        try self.runReadyChains();
        if (self.should_exit) return;

        const cur = self.drawGetCursor() catch glyphwire.Cursor{ .row = self.line_start_row + 1, .col = 0 };
        try self.drawSetCursor(promptrow.afterCommand(cur.row, cur.col), 0);
        try self.showPrompt();
    }

    /// Runs the rest of every line in `ready_chains`, oldest first, each
    /// judged against the status its background job exited with. One of
    /// them can park a job of its own or finish another, so this loops
    /// until the queue stays empty.
    pub fn runReadyChains(self: *Prompt) !void {
        while (self.ready_chains.items.len > 0) {
            var rc = self.ready_chains.orderedRemove(0);
            defer rc.rest.deinit();
            _ = try self.runContinuation(rc.rest.segments, rc.status);
            if (self.should_exit) return;
            self.adoptPendingResize();
            self.reportFinishedJobs();
        }
    }

    /// The idle prompt's side of `runReadyChains`: a background job
    /// holding the rest of its line exited while the prompt sat empty.
    /// That rest runs now, below the empty prompt as if Enter had been
    /// pressed on it, then a fresh prompt is drawn. A half-typed line, a
    /// browse, or a resize in flight waits instead; the chain then runs
    /// once that line is submitted (`submitLine`). Returns whether it
    /// ran anything.
    pub fn runReadyChainsAtIdle(self: *Prompt) !bool {
        if (self.line.text().len > 0 or self.browse_pos != null or self.pending_resize != null) return false;
        if (!self.chainReady()) return false;
        if (self.completion_hint_visible) self.hideCompletionHint();

        try self.drawSetCursor(promptrow.next(self.line_start_row, self.line_start_col), 0);
        self.reportFinishedJobs();
        try self.runReadyChains();
        if (self.should_exit) return true;

        const cur = self.drawGetCursor() catch glyphwire.Cursor{ .row = self.line_start_row + 1, .col = 0 };
        try self.drawSetCursor(promptrow.afterCommand(cur.row, cur.col), 0);
        try self.showPrompt();
        return true;
    }

    /// Ctrl+R: fuzzy history search. Runs the bundled `gw-hist` directly
    /// through `runCommand` -- not the full `submitLine` path, so it
    /// doesn't echo/record itself as a typed command -- and, on a pick,
    /// loads it into the *current* line right away (`setLine`) instead of
    /// waiting for `showPrompt` to pick up `pending_result_line` on the
    /// next prompt (see that field's doc comment for the plain-typed-
    /// invocation case this shares its plumbing with).
    ///
    /// Flushes history first (`.due` -- only if something's actually
    /// pending) so a line submitted earlier this session, not yet due for
    /// the periodic flush gate, is already in the file `gw-hist` reads
    /// directly rather than over any live connection to this process.
    pub fn historySearch(self: *Prompt) !void {
        try self.runHistPicker(false);
    }

    /// Alt+C: `gw-hist --dirs`, the same picker opened on `zj`'s
    /// directory database instead of the history, so a pick lands on the
    /// line as `cd <path>`. Waits for Enter like Ctrl+R does rather than
    /// changing directory on the spot (fzf's Alt+C does), so every
    /// directory change still goes through a line the user submitted.
    /// The flush in `runHistPicker` matters here too: it writes this
    /// session's `zj` visits into the `z.db` gw-hist reads.
    pub fn dirSearch(self: *Prompt) !void {
        try self.runHistPicker(true);
    }

    /// The shared body of Ctrl+R and Alt+C. `dirs` adds gw-hist's leading
    /// `--dirs` flag.
    pub fn runHistPicker(self: *Prompt, dirs: bool) !void {
        self.flushPersistentState(.due);
        // Whatever is already typed seeds the search (`gw-hist [query...]`,
        // see hist/main.zig's `seedQuery`), so Ctrl+R after `git com`
        // opens already filtered on `git com` instead of throwing that
        // typing away -- fish and mcfly both work this way. The whole
        // line goes as *one* argument, since a query is one string, not
        // an argv; `expand_tilde = false` keeps `runCommandOpts` from
        // turning a typed `~/code` into an absolute path that would then
        // match none of the history lines that literally contain
        // `~/code` (see `RunOptions`). Trimmed, and
        // a blank line spawns `gw-hist` bare, so a stray space doesn't
        // open the search filtered down to nothing.
        const seed = std.mem.trim(u8, self.line.text(), " \t");
        var argv_buf: [3][]const u8 = undefined;
        var argv: std.ArrayList([]const u8) = .initBuffer(&argv_buf);
        argv.appendAssumeCapacity("gw-hist");
        if (dirs) argv.appendAssumeCapacity("--dirs");
        if (seed.len == 0) {
            try self.runCommand(argv.items);
        } else {
            argv.appendAssumeCapacity(seed);
            _ = try self.runCommandOpts(argv.items, .{ .expand_tilde = false });
        }
        if (self.takePendingResultLine()) |line| {
            defer self.client.alloc.free(line);
            try self.setLine(line);
        }
    }

    /// Alt+D: replaces the line with `cd <cwd>`, so the directory you are
    /// already in can be *edited* into the one you want (up a level, over
    /// to a sibling) rather than retyped from scratch. The prompt-line
    /// counterpart of salacommander's Alt+D in-place path edit
    /// (`actions.editPath`), and bound to the same chord for that reason,
    /// deliberately over readline's `kill-word` -- the shell already has
    /// Ctrl+Delete for that.
    ///
    /// The path is written the way the default prompt shows it
    /// (`~`-collapsed); `runCommand`'s `expandTilde` turns it back into
    /// an absolute path when the line is submitted, so the round trip is
    /// exact. Replaces whatever was typed outright, with the caret at the
    /// end of the path (`setLine`), which is where an edit almost always
    /// starts.
    pub fn cdCwdLine(self: *Prompt) !void {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        var tilde_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = self.collapseHome(self.logicalCwd(&cwd_buf), &tilde_buf);

        // `max_path_bytes + 4` covers `"cd "` before a full-length path,
        // the same slack `writeDefaultPrefix` gives its `" > "` suffix.
        var line_buf: [std.fs.max_path_bytes + 4]u8 = undefined;
        const text = std.fmt.bufPrint(&line_buf, "cd {s}", .{cwd}) catch "cd ";
        try self.setLine(text);
    }

    /// At the prompt, this shell's context is `gw-shell <cwd>` -- the
    /// directory is what changes while you move around. See `setTitle`.
    pub fn syncPromptTitle(self: *Prompt) void {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = self.collapseHome(self.logicalCwd(&cwd_buf), &home_buf);
        var next: [glyphwire.Context.max_title_len]u8 = undefined;
        const title = std.fmt.bufPrint(&next, "gw-shell {s}", .{cwd}) catch "gw-shell";
        self.setTitle(title);
    }

    /// While a command runs, the title is the command line itself, as
    /// typed (`sudo htop -d 5`) -- what is running says more than where.
    /// Set before the handshake can tell a plain program from a
    /// glyphwire-aware one; `foregroundJob` puts the prompt title back
    /// once it knows the child is aware. Cut to the title cap on a UTF-8
    /// boundary.
    pub fn syncCommandTitle(self: *Prompt, line: []const u8) void {
        const text = std.mem.trimEnd(u8, line, " \t\r\n");
        if (text.len == 0) return;
        var len = @min(text.len, glyphwire.Context.max_title_len);
        while (len > 0 and len < text.len and (text[len] & 0xC0) == 0x80) len -= 1;
        self.setTitle(text[0..len]);
    }

    /// Names this shell's context, which glyphwire-host shows in the
    /// window title when this pane has focus and the context switcher
    /// lists. A glyphwire program started from here makes and names a
    /// context of its own, so once the handshake says so the shell goes
    /// back to its prompt title (see `foregroundJob`) and the command
    /// line only stays up for plain terminal programs. Embedded, the
    /// context is the host program's, and its title is not ours to set.
    /// Sends only on change.
    pub fn setTitle(self: *Prompt, title: []const u8) void {
        if (self.layer != null) return;
        if (std.mem.eql(u8, title, self.title_buf[0..self.title_len])) return;
        self.client.setContextTitle(title) catch return;
        @memcpy(self.title_buf[0..title.len], title);
        self.title_len = title.len;
    }

    /// Runs whatever the just-committed line (`self.line`) names.
    ///
    /// The line goes through `parse.parse` first (pipes, redirects,
    /// `&&` / `||` / `;`). A *bare* command -- one stage, no redirects --
    /// keeps the original PTY-backed path (`dispatchBareCommand` ->
    /// `runCommand`): interactive full-screen programs, the glyphwire
    /// handshake and `{dur}` timing all depend on it. A chain
    /// (`&&` / `||` / `;`) runs segment by segment (`runChain`): a bare
    /// segment takes that same pty path, anything with a `|` or a
    /// redirect the pipe-based executor (`runPipeline`).
    /// `alias NAME=VALUE` is still handled off the raw line ahead of the
    /// parser -- its value has rest-of-line semantics
    /// (`wordsplit.parseAliasDef`) the tokenizer would destroy.
    ///
    /// A leading `NAME=VALUE` run is also peeled off ahead of the parser
    /// (`envassign.scanLeading` -> `dispatchWithAssignments`): a bare run
    /// sets the session environment, a run before a command sets those
    /// names just for that line and restores them after.
    ///
    /// Within each command: quote-aware splitting, then alias expansion
    /// (`expandAliases`), then `*` globs (`expandGlobs`), then
    /// builtin / `$PATH` dispatch -- bash order. A core or script builtin
    /// (`cd`, `exit`, a `defcmd`) works as a whole stage in an
    /// `&&` / `||` / `;` chain, but not as one stage of a `|` pipeline
    /// (see `runPipeline`).
    pub fn dispatchLine(self: *Prompt) !void {
        return self.dispatchLineText(self.line.text());
    }

    /// The body of `dispatchLine`, split out so the `on{ chdir }`
    /// auto-listing can dispatch a command line that isn't sitting in
    /// `self.line`. See `dispatchLine`'s doc comment for the rules.
    pub fn dispatchLineText(self: *Prompt, text: []const u8) !void {
        const alloc = self.client.alloc;
        const trimmed = std.mem.trimStart(u8, text, " \t");

        if (std.mem.startsWith(u8, trimmed, "alias") and
            (trimmed.len == "alias".len or trimmed["alias".len] == ' ' or trimmed["alias".len] == '\t'))
        {
            return self.doAlias(text);
        }

        // Before any of the paths below, bare commands included: `htop`
        // has to be in the title while it runs, not after.
        self.syncCommandTitle(trimmed);

        // Leading `NAME=VALUE` words: a bare run sets the session
        // environment (`FOO=bar`), a run followed by a command sets those
        // names just for that line (`FOO=bar cmd args`), then restores.
        {
            const leading = try envassign.scanLeading(alloc, trimmed, &self.env);
            defer envassign.freeLeading(alloc, leading);
            if (leading.assignments.len > 0) {
                return self.dispatchWithAssignments(leading.assignments, leading.rest);
            }
        }

        switch (try parse.parse(alloc, text)) {
            .err => |msg| {
                defer alloc.free(msg);
                try self.drawText(msg, err_color, null);
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

                // A parked segment records nothing, like a bare command
                // put in the background.
                _ = try self.runContinuation(line.segments, 0);
            },
        }
    }

    /// The bare-command path: the pre-pipeline dispatch, unchanged in
    /// behavior from before pipelines existed. `cmd` is always a single
    /// stage with no redirects (`Line.isBareCommand`).
    pub fn dispatchBareCommand(self: *Prompt, cmd: parse.Command) !void {
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
        //
        // This chain is the bare-command mirror of `runBuiltin`, and the
        // set of names has to match `isBuiltinName` -- a builtin added to
        // one and not the other works in an `&&` chain and falls through
        // to `$PATH` when typed on its own.
        if (std.mem.eql(u8, argv[0], "exit")) {
            self.should_exit = true;
        } else if (std.mem.eql(u8, argv[0], "unalias")) {
            try self.doUnalias(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "cd")) {
            try self.doCd(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "export")) {
            _ = try self.doExport(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "unset")) {
            _ = try self.doUnset(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "zj")) {
            try self.doZj(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "gwssh")) {
            // Records its own `last_status` (it has a remote session's
            // exit to report), like `runCommand` does.
            _ = try self.doGwssh(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "reload")) {
            _ = try self.doReload(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "jobs")) {
            _ = try self.doJobs();
        } else if (std.mem.eql(u8, argv[0], "fg")) {
            _ = try self.doFg(argv[1..]);
        } else if (self.runScriptBuiltin(argv)) {
            // handled by the persistent Lua engine
        } else {
            try self.runCommand(argv);
        }
    }

    /// The rest of a line held by a `ReadyChain`: what is left of it and
    /// the exit status of the background job it was waiting on.
    pub const ReadyChain = struct {
        rest: parse.Line,
        status: u8,
    };

    /// How `runChain` ended.
    pub const ChainEnd = union(enum) {
        /// Every segment that was going to run has. The last one's
        /// status, or the starting status if none ran.
        finished: u8,
        /// A segment was put in the background (the context switcher)
        /// and now holds the segments after it (`Job.rest`).
        backgrounded,
    };

    /// Walks a chain's segments left to right, running each pipeline
    /// whose `&&` / `||` / `;` link permits it given the running exit
    /// status, which starts at `status` -- 0 for a fresh line, a parked
    /// job's exit status for the rest of its line. A segment killed by
    /// Ctrl-C ends the chain whatever the separators say
    /// (`parse.interrupted_status`). Interactive path only -- `sh.run` /
    /// `sh.exec` drive `runPipeline` directly.
    pub fn runChain(self: *Prompt, segments: []const parse.Segment, status: u8) !ChainEnd {
        var last = status;
        for (segments, 0..) |seg, i| {
            if (last == parse.interrupted_status) break;
            if (!seg.sep.permits(last)) continue;
            switch (try self.runSegment(seg.pipeline)) {
                .status => |s| last = s,
                .backgrounded => |job| {
                    if (i + 1 < segments.len) {
                        job.rest = try parse.Line.cloneSegments(self.client.alloc, segments[i + 1 ..]);
                    }
                    return .backgrounded;
                },
            }
            if (self.should_exit) break;
        }
        return .{ .finished = last };
    }

    /// `runChain`, then records its outcome for the next prompt's
    /// `{exit}` / `{dur}` the way a typed line does. Returns that status;
    /// 0 when a segment was parked, which records nothing. `anyerror`
    /// breaks the inferred-error-set cycle through `fg` (`doFg` runs the
    /// rest of a line it brings back to an end).
    pub fn runContinuation(self: *Prompt, segments: []const parse.Segment, status: u8) anyerror!u8 {
        const started = std.Io.Clock.Timestamp.now(self.client.io, .awake);
        switch (try self.runChain(segments, status)) {
            .finished => |s| {
                const elapsed_ms = started.untilNow(self.client.io).raw.toMilliseconds();
                self.last_status = s;
                self.last_dur_ms = if (elapsed_ms > 0) @intCast(elapsed_ms) else 0;
                self.have_status = true;
                return s;
            },
            .backgrounded => return 0,
        }
    }

    /// One segment of a chain. A single command with no redirects gets
    /// the bare-command treatment -- its own pty, which is its
    /// controlling terminal -- so `sudo a && sudo b` can ask for a
    /// password, `ls; ls` stays coloured, and `vim x && make` gets a real
    /// screen. A builtin runs in-process; anything with a `|` or a
    /// redirect goes to the pipe-based `runPipeline`.
    pub fn runSegment(self: *Prompt, pl: parse.Pipeline) !RunEnd {
        if (!pl.isBare()) return .{ .status = try self.runPipeline(pl, .interactive) };

        const argv = try self.resolveArgv(pl.commands[0]);
        defer wordsplit.freeTokens(self.client.alloc, argv);
        if (argv.len == 0) return .{ .status = 0 };
        if (self.isBuiltinName(argv[0])) return .{ .status = try self.runBuiltin(argv) };
        return self.runCommandOpts(argv, .{});
    }

    /// Where a running pipeline's output goes and where its stdin / Ctrl-C
    /// come from.
    pub const PipeSink = union(enum) {
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

    pub const Capture = struct {
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
    pub fn runPipeline(self: *Prompt, pl: parse.Pipeline, sink: PipeSink) !u8 {
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
                try self.drawText("pipeline: empty command", err_color, null);
                return 2;
            }
            if (self.isBuiltinName(argvs[i][0])) {
                var buf: [160]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "{s}: not supported inside a pipeline", .{argvs[i][0]}) catch
                    "builtin not supported inside a pipeline";
                try self.drawText(m, err_color, null);
                return 2;
            }
        }
        return self.spawnAndPump(pl.commands, argvs, sink);
    }

    /// alias-expands then glob-expands one parsed command into an owned
    /// argv (`wordsplit.freeTokens` to free). The per-token "quoted" flag
    /// is carried into `expandGlobs` so a quoted `*` stays literal.
    pub fn resolveArgv(self: *Prompt, cmd: parse.Command) ![]const []const u8 {
        const alloc = self.client.alloc;
        var args = try alloc.alloc(wordsplit.Arg, cmd.words.len);
        defer alloc.free(args);
        for (cmd.words, cmd.quoted, 0..) |w, q, i| args[i] = .{ .text = w, .quoted = q };

        const expanded = try self.expandAliases(args);
        defer wordsplit.freeArgs(alloc, expanded);
        return self.expandGlobs(expanded);
    }

    // ── Builtins (builtins.zig) ──────────────────────────────────────────
    pub const isBuiltinName = builtins.isBuiltinName;
    pub const runBuiltin = builtins.runBuiltin;
    pub const runScriptBuiltin = builtins.runScriptBuiltin;
    pub const doJobs = builtins.doJobs;
    pub const doFg = builtins.doFg;
    pub const doCd = builtins.doCd;
    pub const chdir = builtins.chdir;
    pub const queueChdirListing = builtins.queueChdirListing;
    pub const recordVisit = builtins.recordVisit;
    pub const doGwssh = builtins.doGwssh;
    pub const remoteAgentCommand = builtins.remoteAgentCommand;
    pub const reportRemoteFailure = builtins.reportRemoteFailure;
    pub const RemoteOutcome = builtins.RemoteOutcome;
    pub const waitOutRemote = builtins.waitOutRemote;
    pub const doZj = builtins.doZj;
    pub const reportZjError = builtins.reportZjError;
    pub const dirExists = builtins.dirExists;
    pub const expandTilde = builtins.expandTilde;
    pub const reportCdError = builtins.reportCdError;
    pub const doAlias = builtins.doAlias;
    pub const listAliases = builtins.listAliases;
    pub const doUnalias = builtins.doUnalias;
    pub const setEnvVar = builtins.setEnvVar;
    pub const unsetEnvVar = builtins.unsetEnvVar;
    pub const doExport = builtins.doExport;
    pub const doUnset = builtins.doUnset;
    pub const reportBadEnvName = builtins.reportBadEnvName;
    pub const printEnv = builtins.printEnv;
    pub const doReload = builtins.doReload;

    /// Builds `pipeexec.Stage`s for `commands` (already resolved to
    /// `argvs`), spawns them, and pumps output / input / Ctrl-C until the
    /// last stage exits. All heap scratch is freed before returning; the
    /// children hold their own copies. Reports a spawn failure onto the
    /// grid and returns 127.
    pub fn spawnAndPump(
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
                const z = try std.mem.concatWithSentinel(alloc, u8, &.{exp}, 0);
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
            try self.drawText(m, err_color, null);
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
    pub fn resolveRedir(
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
                try self.drawText("ambiguous redirect", err_color, null);
                return null;
            }
            if (m.len == 1) chosen = m[0];
        }

        const z = try std.mem.concatWithSentinel(alloc, u8, &.{chosen}, 0);
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
    pub fn pumpPipeline(self: *Prompt, sp: *pipeexec.Spawned, sink: PipeSink) !void {
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
    pub fn drainPipeOnce(
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
                else => self.drawText(chunk, null, null) catch {},
            }
        }
        return read_any;
    }

    /// Interactive pipeline stdin: waits briefly for one input event and
    /// forwards it to stage 0. Returns true if the event was Ctrl-C (the
    /// caller SIGINTs the group); Ctrl-D closes stage 0's stdin. Simpler
    /// than `runCommand`'s pty loop -- no mode tracking, mouse or resize,
    /// since a pipe has no line discipline to match.
    pub fn forwardKeystroke(self: *Prompt, sp: *pipeexec.Spawned) !bool {
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
            // Host window closing: report it as an interrupt so the
            // caller SIGINTs the pipeline group and unwinds.
            .shutdown => {
                self.should_exit = true;
                return true;
            },
            // A window manager's own commands (see `InputEvent.window_key`).
            // Never delivered here: this program is not one.
            .window_key, .window_text => return false,
            .key => |kev| {
                defer alloc.free(kev.key);
                if (!kev.pressed) return false;
                const ctrl = kev.ctrl();
                if (ctrl and std.mem.eql(u8, kev.key, "c")) return true;
                if (ctrl and std.mem.eql(u8, kev.key, "d")) {
                    if (sp.stdin_w >= 0) {
                        _ = c.close(sp.stdin_w);
                        sp.stdin_w = -1;
                    }
                    return false;
                }
                const mods = ptyMods(kev.mods);
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
    pub fn pollPipeInterrupt(self: *Prompt) bool {
        const listener = self.listener orelse return false;
        var hit = false;
        while (listener.pollInputEvent()) |iev| switch (iev) {
            .key => |kev| {
                defer self.client.alloc.free(kev.key);
                if (kev.pressed and kev.ctrl() and std.mem.eql(u8, kev.key, "c"))
                    hit = true;
            },
            .text => |tev| self.client.alloc.free(tev.text),
            .paste => |tev| self.client.alloc.free(tev.text),
            .copy_request => {},
            .shutdown => {
                self.should_exit = true;
                hit = true;
            },
            // A window manager's own commands (see `InputEvent.window_key`).
            // Never delivered here: this program is not one.
            .window_key => |kev| self.client.alloc.free(kev.key),
            .window_text => |tev| self.client.alloc.free(tev.text),
        };
        return hit;
    }

    // ── Jobs (jobs.zig) ──────────────────────────────────────────────────
    pub const runCommand = jobs.runCommand;
    pub const RunOptions = jobs.RunOptions;
    pub const runCommandOpts = jobs.runCommandOpts;
    pub const RunEnd = jobs.RunEnd;
    pub const Job = jobs.Job;
    pub const startJob = jobs.startJob;
    pub const ForegroundEnd = jobs.ForegroundEnd;
    pub const foregroundJob = jobs.foregroundJob;
    pub const noteVisibleContext = jobs.noteVisibleContext;
    pub const finishForegroundJob = jobs.finishForegroundJob;
    pub const freeJob = jobs.freeJob;
    pub const parkJob = jobs.parkJob;
    pub const jobTitle = jobs.jobTitle;
    pub const reportFinishedJobs = jobs.reportFinishedJobs;
    pub const chainReady = jobs.chainReady;
    pub const crash_report_lines = jobs.crash_report_lines;
    pub const reportCrash = jobs.reportCrash;
    pub const writeCrashLog = jobs.writeCrashLog;
    pub const hangUpJobs = jobs.hangUpJobs;
    pub const readResultPipe = jobs.readResultPipe;
    pub const PtyReaderCtx = jobs.PtyReaderCtx;
    pub const syncMouseReport = jobs.syncMouseReport;
    pub const awareState = jobs.awareState;
    pub const ptyReaderThread = jobs.ptyReaderThread;
    pub const Mirror = jobs.Mirror;
    pub const emitChunk = jobs.emitChunk;

    /// The `NAME=VALUE cmd ...` / bare `NAME=VALUE` path. `assignments`
    /// were already peeled and `expandValue`'d by `envassign.scanLeading`;
    /// `rest` is the remaining command text (empty for a bare run).
    ///
    /// Bare run: apply every assignment to the session environment.
    /// Otherwise: snapshot each name's current value, apply the
    /// assignments, dispatch `rest` as its own line, then restore every
    /// name (set back or unset). Restoring in a `defer` covers a `rest`
    /// that errors. The whole line -- pipeline / `&&` chain included --
    /// runs with the assignments in effect (bash scopes them per pipeline
    /// stage; that corner isn't worth the plumbing here -- see
    /// docs/decisions.md).
    ///
    /// Explicit `anyerror` rather than an inferred set: this and
    /// `dispatchLineText` call each other, and two inferred error sets in
    /// a cycle don't resolve.
    pub fn dispatchWithAssignments(
        self: *Prompt,
        assignments: []const envassign.Assignment,
        rest: []const u8,
    ) anyerror!void {
        const alloc = self.client.alloc;

        if (rest.len == 0) {
            for (assignments) |a| self.setEnvVar(a.name, a.value);
            self.last_status = 0;
            self.last_dur_ms = 0;
            self.have_status = true;
            return;
        }

        const Saved = struct { name: []const u8, old: ?[]const u8 };
        var saved: std.ArrayList(Saved) = .empty;
        defer {
            // LIFO restore is fine: `saved` holds one entry per distinct
            // name (first occurrence wins), so order doesn't matter.
            for (saved.items) |s| {
                if (s.old) |o| {
                    self.setEnvVar(s.name, o);
                    alloc.free(o);
                } else {
                    self.unsetEnvVar(s.name);
                }
            }
            saved.deinit(alloc);
        }

        for (assignments) |a| {
            var seen = false;
            for (saved.items) |s| {
                if (std.mem.eql(u8, s.name, a.name)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                const old: ?[]const u8 = if (self.env.get(a.name)) |v| try alloc.dupe(u8, v) else null;
                try saved.append(alloc, .{ .name = a.name, .old = old });
            }
            self.setEnvVar(a.name, a.value);
        }

        try self.dispatchLineText(rest);
    }

    /// Stands up the persistent Lua interpreter (`script_engine`), wired
    /// to this prompt's environment overlay, cwd and grid. Safe to skip:
    /// on failure `script_engine` stays null and script builtins are just
    /// unavailable.
    pub fn initScriptEngine(self: *Prompt, config_dir: []const u8) !void {
        self.script_engine = try script_engine.ScriptEngine.init(
            self.client.alloc,
            self.client.io,
            self.scriptHooks(),
            config_dir,
        );
    }

    /// The `script_engine.HostHooks` for this prompt -- how a running
    /// script reaches the live shell (env, cwd, grid, Ctrl-C).
    pub fn scriptHooks(self: *Prompt) script_engine.HostHooks {
        return .{
            .ctx = self,
            .setenv = hookSetenv,
            .unsetenv = hookUnsetenv,
            .getenv = hookGetenv,
            .cwd = hookCwd,
            .chdir = hookChdir,
            .realpath = hookRealpath,
            .write = hookWrite,
            .poll_interrupt = hookPollInterrupt,
            .run_line = hookRunLine,
        };
    }

    /// What `readConfSource` can fail with. `FileNotFound` is split out
    /// from the rest because the two callers disagree about it: startup
    /// treats no config file as perfectly normal, `reload` reports it.
    pub const ConfReadError = error{ FileNotFound, ReadFailed, OutOfMemory };

    /// Reads `<config_dir>/shell.conf.lua` into a null-terminated buffer
    /// (what the Lua loader takes), owned by the caller. An IO failure
    /// other than a missing file is logged here and reported as
    /// `error.ReadFailed`.
    pub fn readConfSource(self: *Prompt, config_dir: []const u8) ConfReadError![:0]u8 {
        return config.conf.readIn(self.client.alloc, self.client.io, config_dir);
    }

    /// Reads `shell.conf.lua` and runs it through the persistent
    /// `script_engine` (so a `function` it defines survives as a
    /// builtin), then applies what it declared. A missing file, an
    /// unreadable one, or no engine at all is fine -- the shell starts
    /// with its defaults.
    pub fn loadStartupConfig(self: *Prompt, config_dir: []const u8) !void {
        const alloc = self.client.alloc;

        const eng = self.script_engine orelse return;

        const source = self.readConfSource(config_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound, error.ReadFailed => return,
        };
        defer alloc.free(source);

        try eng.runConf(source);
        try self.applyConfig(eng);
    }

    /// Pushes the config `script_engine` has just parsed into the live
    /// prompt: the alias bindings, the borrowed `prompt_config` pointer
    /// every redraw reads, and the `zj{}` settings. A syntax/runtime error
    /// from the run is shown in red, with whatever ran before it still in
    /// effect. Shared by startup and `reload` so the two can't drift.
    pub fn applyConfig(self: *Prompt, eng: *script_engine.ScriptEngine) !void {
        const alloc = self.client.alloc;

        for (eng.cfg.aliases.items) |a| {
            try self.aliases.set(alloc, a.name, a.value);
        }

        if (eng.conf_err) |msg| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "shell.conf.lua: {s}\n", .{msg}) catch "shell.conf.lua: error\n";
            try self.drawText(line, err_color, null);
        }

        // The engine owns the parsed config for the session --
        // `writePromptPrefix` reads `.prompt` off it live on every redraw
        // (so `{time}` and cwd stay current).
        self.prompt_config = &eng.cfg;

        // `theme(...)`: this context's own theme, resolved against
        // `theme.lua`'s too. Without one, follow the window's -- which,
        // after a `reload` that removed the line, means saying so.
        const arena = eng.cfg.prompt_arena.allocator();
        const shared = themeconf.loadShared(arena, alloc, self.client.io, self.environ_map);
        if (eng.cfg.themes.resolve(arena, shared)) |t| {
            try self.client.setTheme(&t);
            self.own_theme = true;
        } else if (self.own_theme) {
            try self.client.setTheme(null);
            self.own_theme = false;
        }

        // `zj{}` settings. Copy the excludes into our own storage with a
        // leading `~` expanded, so the pure matcher can compare them
        // byte-for-byte against absolute paths.
        self.zj_enabled = eng.cfg.zj.enabled;
        if (eng.cfg.zj.exclude_dirs.len > 0) {
            var owned = try alloc.alloc([]const u8, eng.cfg.zj.exclude_dirs.len);
            var filled: usize = 0;
            errdefer {
                for (owned[0..filled]) |s| alloc.free(s);
                alloc.free(owned);
            }
            for (eng.cfg.zj.exclude_dirs) |raw| {
                const expanded = self.expandTilde(raw) catch raw;
                owned[filled] = if (expanded.ptr == raw.ptr) try alloc.dupe(u8, raw) else expanded;
                filled += 1;
            }
            self.zj_excludes = owned;
        }
    }

    /// Frees the `~`-expanded `zj{ exclude_dirs }` copies and leaves the
    /// list empty. Called before `reload` rebuilds them, and from `deinit`.
    pub fn clearZjExcludes(self: *Prompt) void {
        const alloc = self.client.alloc;
        if (self.zj_excludes.len == 0) return;
        for (self.zj_excludes) |s| alloc.free(s);
        alloc.free(self.zj_excludes);
        self.zj_excludes = &.{};
    }

    // ── Persistent state (persist.zig) ───────────────────────────────────
    pub const loadHistory = persist.loadHistory;
    pub const loadZjump = persist.loadZjump;
    pub const writeHistoryFile = persist.writeHistoryFile;
    pub const clearHistoryPending = persist.clearHistoryPending;
    pub const writeZdbFile = persist.writeZdbFile;
    pub const FlushMode = persist.FlushMode;
    pub const flushPersistentState = persist.flushPersistentState;
    pub const maybeFlushPersistentState = persist.maybeFlushPersistentState;

    /// Wall-clock time, unix seconds -- the timestamp `zj` entries carry.
    pub fn nowSecs(self: *Prompt) i64 {
        return std.Io.Timestamp.now(self.client.io, .real).toSeconds();
    }

    /// Monotonic milliseconds -- what the flush gate measures elapsed
    /// time with (immune to the wall clock being stepped).
    pub fn nowMillis(self: *Prompt) i64 {
        return std.Io.Timestamp.now(self.client.io, .awake).toMilliseconds();
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
    pub fn expandAliases(self: *Prompt, words: []const wordsplit.Arg) ![]wordsplit.Arg {
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
    pub fn expandGlobs(self: *Prompt, args: []const wordsplit.Arg) ![]const []const u8 {
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
    pub fn insertText(self: *Prompt, text: []const u8) !void {
        if (!try self.line.insert(self.client.alloc, text)) return;
        try self.afterEdit(); // -> renderInputLine repaints the box
    }

};

// ─── script engine host hooks ────────────────────────────────────────
//
// `shell/script_engine.zig` reaches the live shell only through these
// function pointers (its `HostHooks`); `ctx` is always the `*Prompt`.
// Kept as free functions, not `Prompt` methods, because that's the shape
// a `*const fn (ctx: *anyopaque, ...)` pointer needs.

/// `sh.setenv` -- same effect as the `export` builtin (`Prompt.setEnvVar`
/// updates libc so children inherit it, plus the `{env:NAME}` overlay).
fn hookSetenv(ctx: *anyopaque, name: []const u8, value: []const u8) void {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    self.setEnvVar(name, value);
}

/// `sh.unsetenv` -- same effect as the `unset` builtin.
fn hookUnsetenv(ctx: *anyopaque, name: []const u8) void {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    self.unsetEnvVar(name);
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

/// `sh.chdir` -- change the shell's working directory. Goes through the
/// same `Prompt.chdir` an interactive `cd` uses, so a script jump is
/// recorded in the `zj` database too. Returns false (no Lua error) if
/// the path doesn't open.
fn hookChdir(ctx: *anyopaque, path: [:0]const u8) bool {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    self.chdir(path) catch return false;
    return true;
}

/// The `zjump.MatchOpts.exists` probe -- `ctx` is the `*Prompt`.
pub fn zjExistsProbe(ctx: ?*anyopaque, path: []const u8) bool {
    const self: *Prompt = @ptrCast(@alignCast(ctx.?));
    return self.dirExists(path);
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
    self.drawText(bytes, null, null) catch {};
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
            if (kev.pressed and kev.ctrl() and std.mem.eql(u8, kev.key, "c"))
                hit = true;
        },
        .text => |tev| self.client.alloc.free(tev.text),
        // Type-ahead (paste included) is dropped while a script builtin
        // runs; a copy_request carries nothing to free.
        .paste => |tev| self.client.alloc.free(tev.text),
        .copy_request => {},
        // Host window closing mid-script: treat it as an interrupt so the
        // builtin unwinds; the loop in `runPrompt` then flushes and exits.
        .shutdown => {
            self.should_exit = true;
            hit = true;
        },
        // A window manager's own commands (see `InputEvent.window_key`).
        // Never delivered here: this program is not one.
        .window_key, .window_text => {},
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
                self.drawText(msg, err_color, null) catch {};
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
                if (!seg.sep.permits(status)) continue;
                if (fed) cap.stdin = "";
                const sink: Prompt.PipeSink = if (capture) .{ .capture = &cap } else .script_grid;
                status = self.runPipeline(seg.pipeline, sink) catch return status;
                fed = true;
            }
            return status;
        },
    }
}
