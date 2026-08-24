const std = @import("std");
const glyphwire = @import("glyphwire");

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

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
/// per submitted line (see `Prompt.runCommand`). Every child is assumed
/// "glyphwire compatible": it inherits `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX`
/// from this process and writes to the grid itself over its own
/// connection, the same way `glyphwire-demo` or `glyphwire-ls` do -- the
/// shell just spawns it and waits, no stdout/stderr capture. Capturing
/// output from a plain, non-glyphwire-aware program is separate, later
/// work. `cd` is a builtin (see `Prompt.doCd`) rather than spawned, since
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

    const listener = glyphwire.InputListener.connect(io, alloc, socket_path, &.{"key"}) catch |err| {
        std.log.err("prompt: failed to subscribe: {t}", .{err});
        return;
    };
    defer listener.deinit();

    var prompt: Prompt = .{ .client = &client, .environ_map = environ_map };
    // Unreachable before `exit` gave this loop a clean return path --
    // every previous exit was a hard kill, so this never ran and the leak
    // never surfaced.
    defer prompt.deinit();
    try prompt.showPrompt();

    while (true) {
        // Blocks until a key event is queued rather than polling on a fixed
        // interval, so a keystroke gets picked up immediately instead of
        // waiting out however much of the poll interval was left; the
        // timeout is just a fallback heartbeat, not load-bearing.
        const ev = (try listener.waitKeyEvent(.{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } })) orelse continue;
        defer alloc.free(ev.key);
        if (!ev.pressed) continue; // only key-down drives the prompt

        const ctrl = listener.isKeyDown("left_control") or listener.isKeyDown("right_control");
        const alt = listener.isKeyDown("left_alt") or listener.isKeyDown("right_alt");
        const super = listener.isKeyDown("left_super") or listener.isKeyDown("right_super");

        if (std.mem.eql(u8, ev.key, "enter")) {
            try prompt.submitLine();
            if (prompt.should_exit) return; // "exit" was typed -- see submitLine
        } else if (std.mem.eql(u8, ev.key, "backspace")) {
            try prompt.deleteBackward();
        } else if (std.mem.eql(u8, ev.key, "delete")) {
            try prompt.deleteForward();
        } else if (ctrl and std.mem.eql(u8, ev.key, "a")) {
            try prompt.moveCursorTo(0);
        } else if (ctrl and std.mem.eql(u8, ev.key, "e")) {
            try prompt.moveCursorTo(prompt.buffer.items.len);
        } else if (ctrl and std.mem.eql(u8, ev.key, "u")) {
            try prompt.killToStart();
        } else if (ctrl and std.mem.eql(u8, ev.key, "l")) {
            try prompt.clearScreen();
        } else if (ctrl and std.mem.eql(u8, ev.key, "left")) {
            try prompt.moveCursorTo(prompt.wordLeft());
        } else if (ctrl and std.mem.eql(u8, ev.key, "right")) {
            try prompt.moveCursorTo(prompt.wordRight());
        } else if (ctrl and std.mem.eql(u8, ev.key, "up")) {
            try prompt.historyUp();
        } else if (ctrl and std.mem.eql(u8, ev.key, "down")) {
            try prompt.historyDown();
        } else if (std.mem.eql(u8, ev.key, "left")) {
            // Not explicitly asked for, but needed alongside ctrl+left/
            // right: without plain single-character movement too, the
            // caret (drawn by glyphwire-host wherever the raw grid cursor
            // sits) could wander away from `prompt.cursor` -- the offset
            // typing/backspace actually act on -- which would look
            // confusing (caret in one place, edits landing in another).
            try prompt.moveCursorTo(prompt.cursor -| 1);
        } else if (std.mem.eql(u8, ev.key, "right")) {
            try prompt.moveCursorTo(prompt.cursor + 1);
        } else if (!ctrl and !alt and !super) {
            // A ctrl/alt/super chord that isn't one of the explicit cases
            // above (e.g. ctrl+c, ctrl+z, alt+f) falls through to here too
            // -- `charFromKeyName` only looks at the base key and shift,
            // so without this guard an unhandled chord would still type
            // its plain character into the line instead of being
            // swallowed like a real terminal does.
            const shift = listener.isKeyDown("left_shift") or listener.isKeyDown("right_shift");
            if (charFromKeyName(ev.key, shift)) |ch| {
                try prompt.insertChar(ch);
            }
        }
    }
}

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
    environ_map: *const std.process.Environ.Map,
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
    /// `null` means the line on screen is the one actually being typed
    /// (not a recalled history entry). Otherwise, an index into `history`
    /// for whichever entry `historyUp`/`historyDown` last loaded.
    history_index: ?usize = null,
    /// What `buffer` held right before the first `historyUp` of a
    /// recall -- `historyDown` past the newest entry restores this,
    /// mirroring a real shell's "go back to what I was typing" behavior.
    /// Only meaningful while `history_index != null`.
    scratch: std.ArrayList(u8) = .empty,

    fn deinit(self: *Prompt) void {
        const alloc = self.client.alloc;
        for (self.history.items) |line| alloc.free(line);
        self.history.deinit(alloc);
        self.scratch.deinit(alloc);
        self.buffer.deinit(alloc);
    }

    /// Writes the current directory followed by `> ` at the cursor's
    /// current position -- reading the directory fresh each time (rather
    /// than caching it) is what makes a successful `cd` visible on the
    /// very next prompt. Returns the cursor position right after the
    /// prefix, for the caller to record as `line_start_row`/`_col`.
    fn writePromptPrefix(self: *Prompt) !glyphwire.Cursor {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(self.client.io, &cwd_buf) catch 0;

        var prefix_buf: [std.fs.max_path_bytes + 4]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s} > ", .{cwd_buf[0..cwd_len]}) catch "> ";

        try self.client.writeText(prefix, null, null);
        return try self.client.getCursor();
    }

    /// A fresh prompt: writes the prefix and resets the line -- empty
    /// buffer, cursor at 0. Used to start a brand new input line (after
    /// `submitLine` or at startup); see `clearScreen` for the ctrl+l case,
    /// which redraws the prefix but keeps whatever's already typed.
    fn showPrompt(self: *Prompt) !void {
        const cur = try self.writePromptPrefix();
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;
        self.cursor = 0;
        self.buffer.clearRetainingCapacity();
    }

    /// ctrl+l: clears the whole screen (`Client.clear`) and redraws the
    /// current prompt line -- prefix plus whatever's already typed -- at
    /// the top, with the cursor restored to its same offset within the
    /// line. Unlike `showPrompt`, doesn't touch `buffer`/`cursor`: this is
    /// a mid-edit redraw, not a fresh prompt.
    fn clearScreen(self: *Prompt) !void {
        try self.client.clear(0, 0, null, null);
        try self.client.setCursor(0, 0);

        const cur = try self.writePromptPrefix();
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;

        if (self.buffer.items.len > 0) try self.client.writeText(self.buffer.items, null, null);
        try self.setCursorAt(self.cursor);
    }

    /// Replaces the whole line -- on-screen and in `buffer` -- with
    /// `text`, leaving the cursor at its end. Shared by `historyUp`/
    /// `historyDown`: clears whatever's currently drawn via
    /// `deleteCells` from column 0 (same `setCursorAt(0)`-then-
    /// `deleteCells` order `killToStart` already uses) rather than
    /// tracking a diff against the old text, since a recalled history
    /// entry has no relation to what it's replacing.
    fn setLine(self: *Prompt, text: []const u8) !void {
        try self.setCursorAt(0);
        if (self.buffer.items.len > 0) try self.client.deleteCells(self.buffer.items.len);

        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.client.alloc, text);
        if (text.len > 0) try self.client.writeText(text, null, null);
        self.cursor = self.buffer.items.len;
        try self.setCursorAt(self.cursor);
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

    /// Inserts `ch` at the cursor (append, if the cursor's at the end):
    /// `insert_cells` opens a blank cell there (see `Client.insertCells`),
    /// then `ch` is written into it -- no retransmitting the rest of the
    /// line, unlike shifting it around client-side would need.
    fn insertChar(self: *Prompt, ch: u8) !void {
        try self.buffer.insert(self.client.alloc, self.cursor, ch);
        try self.setCursorAt(self.cursor);
        try self.client.insertCells(1);
        try self.client.writeText(&[_]u8{ch}, null, null);
        self.cursor += 1;
    }

    /// Deletes the character before the cursor (backspace).
    fn deleteBackward(self: *Prompt) !void {
        if (self.cursor == 0) return;
        _ = self.buffer.orderedRemove(self.cursor - 1);
        self.cursor -= 1;
        try self.setCursorAt(self.cursor);
        try self.client.deleteCells(1);
    }

    /// Deletes the character at the cursor (forward delete) -- distinct
    /// from `deleteBackward` now that the cursor isn't always pinned to
    /// the end of the line.
    fn deleteForward(self: *Prompt) !void {
        if (self.cursor >= self.buffer.items.len) return;
        _ = self.buffer.orderedRemove(self.cursor);
        try self.setCursorAt(self.cursor);
        try self.client.deleteCells(1);
    }

    /// ctrl+u: deletes from the start of the line through the cursor.
    fn killToStart(self: *Prompt) !void {
        if (self.cursor == 0) return;
        const count = self.cursor;
        try self.buffer.replaceRange(self.client.alloc, 0, self.cursor, &.{});
        self.cursor = 0;
        try self.setCursorAt(0);
        try self.client.deleteCells(count);
    }

    /// Moves the cursor without changing the buffer -- ctrl+a/ctrl+e,
    /// ctrl+arrow word jumps, and plain arrow movement all end here.
    fn moveCursorTo(self: *Prompt, offset: usize) !void {
        self.cursor = std.math.clamp(offset, 0, self.buffer.items.len);
        try self.setCursorAt(self.cursor);
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

    /// Positions the server-side cursor at buffer offset `offset` on the
    /// current line.
    fn setCursorAt(self: *Prompt, offset: usize) !void {
        try self.client.setCursor(self.line_start_row, self.line_start_col + offset);
    }

    /// Leaves the just-typed line where it already is (it's been live-
    /// echoed character by character), moves to the row below it, runs
    /// the line as a command if it names one (see `runCommand`), then
    /// resyncs from the server before starting a fresh prompt -- the
    /// child may have written any number of rows while it ran, so the
    /// next prompt's position isn't knowable in advance the way it was
    /// back when this just echoed the line to a fixed offset. `exit`
    /// skips all of that and just sets `should_exit` for the caller.
    fn submitLine(self: *Prompt) !void {
        try self.client.setCursor(self.line_start_row + 1, 0);

        const alloc = self.client.alloc;

        // Record into history before `showPrompt` clears `buffer` below --
        // an owned dupe, since `buffer`'s own storage gets reused for the
        // next line. Blank lines aren't worth recalling, so they're not
        // recorded, matching a real shell. Submitting always leaves the
        // next prompt on the not-recalling line, `historyUp` included.
        if (self.buffer.items.len > 0) {
            try self.history.append(alloc, try alloc.dupe(u8, self.buffer.items));
        }
        self.history_index = null;

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        var it = std.mem.tokenizeAny(u8, self.buffer.items, " \t");
        while (it.next()) |tok| try argv.append(alloc, tok);

        if (argv.items.len > 0) {
            if (std.mem.eql(u8, argv.items[0], "exit")) {
                self.should_exit = true;
                return;
            } else if (std.mem.eql(u8, argv.items[0], "cd")) {
                try self.doCd(argv.items[1..]);
            } else {
                try self.runCommand(argv.items);
            }
        }

        const cur = self.client.getCursor() catch glyphwire.Cursor{ .row = self.line_start_row + 1, .col = 0 };
        try self.client.setCursor(cur.row + 1, 0);
        try self.showPrompt();
    }

    /// Spawns `argv` and waits for it to exit. No stdout/stderr capture,
    /// no argument quoting -- the child is expected to be a
    /// glyphwire-aware program that draws to the grid itself over its own
    /// connection (inheriting `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX`
    /// automatically, since child processes inherit the environment by
    /// default). `argv[0]` resolution (including the `zig-out/bin` dev
    /// convenience) is `std.process.spawn`'s own `$PATH` search -- see
    /// `prependZigOutBinToPath`. A spawn failure (e.g. unknown command) is
    /// reported onto the grid rather than propagated, so a typo doesn't
    /// take down the prompt.
    ///
    /// Every argument gets the same leading `~`/`~/...` expansion `cd`
    /// already gives its target (see `expandTilde`) -- most spawned
    /// programs don't do their own tilde expansion (that's normally the
    /// shell's job), so `cat ~/notes.txt` would otherwise hand the child a
    /// literal `~` it has no way to resolve.
    fn runCommand(self: *Prompt, argv: []const []const u8) !void {
        const alloc = self.client.alloc;
        var expanded: std.ArrayList([]const u8) = .empty;
        defer {
            // Only the prefix actually appended before an early return
            // (the HOME-not-set case below) needs freeing -- zip against
            // that same prefix of argv, not the full slice, or this would
            // walk past the end of `expanded.items`.
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

        var child = std.process.spawn(self.client.io, .{ .argv = expanded.items }) catch |err| {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: command not found ({t})", .{ argv[0], err }) catch "command not found";
            try self.client.writeText(msg, .{ .r = 255, .g = 85, .b = 85 }, null);
            return;
        };
        _ = child.wait(self.client.io) catch |err| {
            std.log.err("runCommand: wait({s}) failed: {t}", .{ argv[0], err });
        };
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
};

/// Resolves a wire-level key name (see `client.zig`'s doc comment --
/// `@tagName` of pixzig's GLFW-backed key enum, e.g. "a", "left_bracket")
/// to the character it types, mirroring pixzig's own `charFromKey` table
/// without depending on pixzig (shell has no such dependency -- see this
/// file's top doc comment). Returns null for non-printable keys.
fn charFromKeyName(key: []const u8, shift: bool) ?u8 {
    if (key.len == 1) {
        const ch = key[0];
        if (ch >= 'a' and ch <= 'z') return if (shift) ch - 32 else ch;
    }

    const Entry = struct { name: []const u8, plain: u8, shifted: u8 };
    const table = [_]Entry{
        .{ .name = "zero", .plain = '0', .shifted = ')' },
        .{ .name = "one", .plain = '1', .shifted = '!' },
        .{ .name = "two", .plain = '2', .shifted = '@' },
        .{ .name = "three", .plain = '3', .shifted = '#' },
        .{ .name = "four", .plain = '4', .shifted = '$' },
        .{ .name = "five", .plain = '5', .shifted = '%' },
        .{ .name = "six", .plain = '6', .shifted = '^' },
        .{ .name = "seven", .plain = '7', .shifted = '&' },
        .{ .name = "eight", .plain = '8', .shifted = '*' },
        .{ .name = "nine", .plain = '9', .shifted = '(' },
        .{ .name = "space", .plain = ' ', .shifted = ' ' },
        .{ .name = "apostrophe", .plain = '\'', .shifted = '"' },
        .{ .name = "comma", .plain = ',', .shifted = '<' },
        .{ .name = "minus", .plain = '-', .shifted = '_' },
        .{ .name = "period", .plain = '.', .shifted = '>' },
        .{ .name = "slash", .plain = '/', .shifted = '?' },
        .{ .name = "semicolon", .plain = ';', .shifted = ':' },
        .{ .name = "equal", .plain = '=', .shifted = '+' },
        .{ .name = "left_bracket", .plain = '[', .shifted = '{' },
        .{ .name = "backslash", .plain = '\\', .shifted = '|' },
        .{ .name = "right_bracket", .plain = ']', .shifted = '}' },
        .{ .name = "grave_accent", .plain = '`', .shifted = '~' },
    };
    for (table) |e| {
        if (std.mem.eql(u8, key, e.name)) return if (shift) e.shifted else e.plain;
    }
    return null;
}
