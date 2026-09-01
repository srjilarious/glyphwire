const std = @import("std");
const glyphwire = @import("glyphwire");
const wordsplit = @import("shell_support").wordsplit;
const complete = @import("shell_support").complete;

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

    const listener = glyphwire.InputListener.connect(io, alloc, socket_path, &.{ "key", "mouse_button", "scroll" }) catch |err| {
        std.log.err("prompt: failed to subscribe: {t}", .{err});
        return;
    };
    defer listener.deinit();

    var prompt: Prompt = .{ .client = &client, .environ_map = environ_map };
    // Unreachable before `exit` gave this loop a clean return path --
    // every previous exit was a hard kill, so this never ran and the leak
    // never surfaced.
    defer prompt.deinit();

    {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        prompt.grid_cols = snapshot.cols();
    }

    try prompt.showPrompt();

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
        } else if (ctrl and std.mem.eql(u8, ev.key, "a")) {
            try prompt.moveCursorTo(0);
        } else if (ctrl and std.mem.eql(u8, ev.key, "e")) {
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
                try prompt.moveCursorTo(prompt.cursor -| 1);
            }
        } else if (std.mem.eql(u8, ev.key, "right")) {
            if (prompt.browse_pos != null) {
                try prompt.browseRight();
            } else {
                try prompt.moveCursorTo(prompt.cursor + 1);
            }
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

/// One filename offered by Tab completion -- `name` is the raw directory
/// entry (no trailing slash), `is_dir` drives the `/` vs ` ` suffix on a
/// unique match and the `/` shown in a listing.
const CompletionCandidate = struct { name: []const u8, is_dir: bool };

/// Session-only alias store backing the prompt's `alias`/`unalias`
/// builtins. There's no config file yet (a Lua-backed startup config is a
/// planned next step), so nothing here survives `exit`. Keys and values
/// are owned dups; `Prompt.deinit` frees the whole table.
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
    /// The root layer's column count -- fetched once at startup (`runPrompt`)
    /// to clamp browse-mode horizontal movement (`browseLeft`/`browseRight`);
    /// there's no lighter-weight "get grid size" property yet (`size` is
    /// still 🔶 in decisions.md), and it doesn't change over a session.
    grid_cols: usize = 0,
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

    fn deinit(self: *Prompt) void {
        const alloc = self.client.alloc;
        for (self.history.items) |line| alloc.free(line);
        self.history.deinit(alloc);
        self.scratch.deinit(alloc);
        self.buffer.deinit(alloc);
        self.aliases.deinit(alloc);
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

    /// Moves the host's scrollback view (see `Prompt.view_scroll` /
    /// `Client.scrollView`) by `delta` rows -- positive scrolls back into
    /// history, negative toward the live tail -- and records the clamped
    /// result the server hands back. This is the "scroll the window along"
    /// half of browsing: `browseUp`/`browseDown` call it once the browse
    /// cursor hits the top of the visible area.
    fn scrollWindow(self: *Prompt, delta: i64) !void {
        const res = try self.client.scrollView(null, delta);
        self.view_scroll = res.offset;
    }

    /// Plain Up (`count == 1`) moves the cursor up into the scrollback
    /// above the prompt instead of editing anything -- entering "browse"
    /// mode (`browse_pos`) on the first press, starting directly above
    /// wherever the real cursor currently sits so it reads as "look
    /// straight up from here" rather than jumping to a fixed column.
    /// Ctrl+Up (`count == 5`, only while already browsing -- see the key
    /// loop) is a bigger step for scanning a long listing faster.
    ///
    /// Once the browse cursor reaches the top visible row, any further
    /// upward movement scrolls the host window back into scrollback
    /// (`scrollWindow`) instead of clamping -- so a listing longer than
    /// the window can be walked all the way up. Entering browse at the
    /// very first prompt (`line_start_row == 0`) is allowed now too, as
    /// long as there's history to scroll to (an empty `scroll_view`
    /// clamps to a no-op otherwise).
    fn browseUp(self: *Prompt, count: usize) !void {
        if (self.browse_pos == null) {
            const start_row = if (self.line_start_row > 0)
                (self.line_start_row - 1) -| (count - 1)
            else
                0;
            self.browse_pos = .{ .row = start_row, .col = self.line_start_col + self.cursor };
            const absorbed = self.line_start_row -| start_row;
            const overshoot = count -| absorbed;
            if (overshoot > 0) try self.scrollWindow(@intCast(overshoot));
            try self.client.setCursor(start_row, self.browse_pos.?.col);
            return;
        }

        var bp = self.browse_pos.?;
        if (bp.row >= count) {
            bp.row -= count;
        } else {
            const overshoot = count - bp.row;
            bp.row = 0;
            try self.scrollWindow(@intCast(overshoot));
        }
        self.browse_pos = bp;
        try self.client.setCursor(bp.row, bp.col);
    }

    /// Plain Down (`count == 1`) while browsing moves the browse cursor
    /// down a row, or -- when already at the bottom of the browsable
    /// range (one row above the prompt) -- ends browsing and lands back
    /// on the real prompt cursor instead (rather than "browsing" a row
    /// that's actually the live line). Ctrl+Down (`count == 5`, only
    /// while already browsing) is a bigger step, but clamps at that same
    /// bottom row rather than overshooting into a snap-back.
    ///
    /// When the host window is scrolled back (`view_scroll > 0`), Down
    /// first scrolls it toward the live tail (`scrollWindow`), the mirror
    /// of `browseUp`'s scroll-past-the-top; only once the view is back at
    /// the tail does Down resume moving the browse cursor down toward the
    /// prompt. A no-op when not currently browsing.
    fn browseDown(self: *Prompt, count: usize) !void {
        var bp = self.browse_pos orelse return;

        var remaining = count;
        if (self.view_scroll > 0) {
            const consume = @min(remaining, self.view_scroll);
            try self.scrollWindow(-@as(i64, @intCast(consume)));
            remaining -= consume;
            if (remaining == 0) {
                try self.client.setCursor(bp.row, bp.col);
                return;
            }
        }

        if (bp.row + 1 >= self.line_start_row) {
            try self.setCursorAt(self.cursor);
            return;
        }
        bp.row = @min(bp.row + remaining, self.line_start_row - 1);
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
    /// <path>` for `"image/png"`. `setLine` both echoes the command and,
    /// via `setCursorAt`, ends any in-progress browsing before
    /// `submitLine` runs it -- same path a real typed command takes, so
    /// e.g. `glyphwire-view`'s own "wait for a keypress before exiting"
    /// behavior (see view/main.zig) just works, blocking the prompt loop
    /// exactly like it would for a command the user typed themselves. A
    /// no-op for anything else (untagged, an unrecognized mimetype, empty
    /// space) per the "don't guess" policy: nothing should happen on a
    /// cell that isn't unambiguously actionable. Doesn't handle a `path`
    /// containing a space -- this shell doesn't support quoted arguments
    /// anywhere yet (see `runCommand`'s doc comment), so neither does
    /// this. Shared by `browseEnter` (Enter while browsing) and
    /// `runPrompt`'s left-click handling.
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

        var line_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
        const line = if (std.mem.eql(u8, mimetype, "directory"))
            std.fmt.bufPrint(&line_buf, "cd {s}", .{path}) catch return
        else if (std.mem.eql(u8, mimetype, "image/png"))
            std.fmt.bufPrint(&line_buf, "glyphwire-view {s}", .{path}) catch return
        else
            return;

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

    /// Positions the server-side cursor at buffer offset `offset` on the
    /// current line.
    /// Every ordinary editing operation (`moveCursorTo`, `insertChar`,
    /// `deleteBackward`/`deleteForward`, `killToStart`, `setLine`,
    /// `clearScreen`) funnels through here to place the real, buffer-offset
    /// cursor -- so clearing `browse_pos` here, unconditionally, is the
    /// entire "snap back to the prompt" mechanism. Nothing else needs to
    /// know browsing was happening: the moment any of those run, the grid
    /// cursor lands back on the live prompt as a side effect of what it was
    /// already going to do anyway.
    ///
    /// If the host window was scrolled back into scrollback (via browsing
    /// past the top, or the host's own wheel/scrollbar), snap it back to
    /// the live tail here too -- starting to type, recall history, move
    /// the cursor, etc. all mean "I'm done looking at history", the same
    /// as this already does for `browse_pos`.
    fn setCursorAt(self: *Prompt, offset: usize) !void {
        self.browse_pos = null;
        if (self.view_scroll != 0) {
            const res = try self.client.scrollView(0, null);
            self.view_scroll = res.offset;
        }
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
    /// Word-splitting is quote-aware (`wordsplit.split`: single/double
    /// quotes and backslash escapes), and a leading alias is expanded
    /// first (`expandAliases`), so an `alias`-defined name reaches exactly
    /// the same builtin/command dispatch a typed name would. `alias`
    /// itself is handled off the raw line ahead of splitting -- its value
    /// has rest-of-line semantics (`wordsplit.parseAliasDef`), unlike
    /// every other argument on the line.
    fn dispatchLine(self: *Prompt) !void {
        const alloc = self.client.alloc;
        const trimmed = std.mem.trimStart(u8, self.buffer.items, " \t");

        if (std.mem.startsWith(u8, trimmed, "alias") and
            (trimmed.len == "alias".len or trimmed["alias".len] == ' ' or trimmed["alias".len] == '\t'))
        {
            return self.doAlias(self.buffer.items);
        }

        const words = try wordsplit.split(alloc, self.buffer.items);
        defer wordsplit.freeTokens(alloc, words);
        if (words.len == 0) return;

        const argv = try self.expandAliases(words);
        defer wordsplit.freeTokens(alloc, argv);
        if (argv.len == 0) return;

        if (std.mem.eql(u8, argv[0], "exit")) {
            self.should_exit = true;
        } else if (std.mem.eql(u8, argv[0], "unalias")) {
            try self.doUnalias(argv[1..]);
        } else if (std.mem.eql(u8, argv[0], "cd")) {
            try self.doCd(argv[1..]);
        } else {
            try self.runCommand(argv);
        }
    }

    /// Spawns `argv` and waits for it to exit, treating its stdout/stderr
    /// as the default output mechanism -- mirrored onto the grid via
    /// `write_text`, terminal-style -- until it performs the handshake
    /// documented on `glyphwire.handshake_marker`: a glyphwire-aware
    /// program's `Client.connect` writes that marker to its own stdout as
    /// part of connecting, this launcher's cue that the process is
    /// drawing to the grid itself over its own connection (inheriting
    /// `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX` automatically, since child
    /// processes inherit the environment by default) rather than
    /// expecting its stdio echoed there. Once that's
    /// resolved either way (see `pumpChildOutput`), the rest of that
    /// stream is either kept mirroring to the grid (never handshaken) or
    /// passed straight through to this process's own real stdio (already
    /// handshaken) -- stdio keeps working either way, only the mirroring
    /// stops, per decisions.md's Discovery & connection section. `argv[0]`
    /// resolution (including the `zig-out/bin` dev convenience) is
    /// `std.process.spawn`'s own `$PATH` search -- see
    /// `prependZigOutBinToPath`. A spawn failure (e.g. unknown command) is
    /// reported onto the grid rather than propagated, so a typo doesn't
    /// take down the prompt. Stdin is deliberately not connected
    /// (`.ignore`): this handles commands that only produce output, not
    /// ones that read input interactively -- see this file's top doc
    /// comment.
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

        var child = std.process.spawn(self.client.io, .{
            .argv = expanded.items,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: command not found ({t})", .{ argv[0], err }) catch "command not found";
            try self.client.writeText(msg, .{ .r = 255, .g = 85, .b = 85 }, null);
            return;
        };
        // Safe to run after the explicit `wait` below too -- `Child.kill`
        // is documented idempotent and a no-op once `wait` has already
        // reaped the child; this is only here to reap it if
        // `pumpChildOutput` returns early on an error.
        defer child.kill(self.client.io);

        self.pumpChildOutput(child.stdout.?, child.stderr.?) catch |err| {
            std.log.err("runCommand: output capture failed for {s}: {t}", .{ argv[0], err });
        };

        _ = child.wait(self.client.io) catch |err| {
            std.log.err("runCommand: wait({s}) failed: {t}", .{ argv[0], err });
        };
    }

    /// Reads `stdout`/`stderr` concurrently via `std.Io.File.MultiReader`
    /// -- the same mechanism `std.process.run` uses to avoid deadlocking
    /// if both pipes fill up at once -- forwarding each chunk as it
    /// arrives rather than buffering the whole run, so a long-running
    /// command's output appears incrementally instead of all at once at
    /// the end. `stdout`'s very first bytes are checked against
    /// `glyphwire.handshake_marker` as soon as enough of them have
    /// arrived; everything read before that resolves (or all of it, if
    /// total output before EOF never reaches the marker's length) is
    /// still routed to the grid, since "not yet handshaken" is exactly
    /// the default this whole mechanism exists for.
    fn pumpChildOutput(self: *Prompt, stdout_file: std.Io.File, stderr_file: std.Io.File) !void {
        const io = self.client.io;
        const gpa = self.client.alloc;

        var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
        var mr: std.Io.File.MultiReader = undefined;
        mr.init(gpa, io, mr_buf.toStreams(), &.{ stdout_file, stderr_file });
        defer mr.deinit();

        // Only opened lazily in spirit but declared up front since Zig has
        // no default-initialized-on-first-use locals -- cheap either way,
        // and only ever written to once a child has already handshaken.
        var passthrough_out_buf: [256]u8 = undefined;
        var passthrough_out = std.Io.File.stdout().writer(io, &passthrough_out_buf);
        var passthrough_err_buf: [256]u8 = undefined;
        var passthrough_err = std.Io.File.stderr().writer(io, &passthrough_err_buf);

        var handshake: ?bool = null;

        while (true) {
            mr.fill(64, .none) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };

            if (handshake == null and mr.reader(0).bufferedLen() >= glyphwire.handshake_marker.len) {
                const seen = std.mem.eql(u8, mr.reader(0).buffered()[0..glyphwire.handshake_marker.len], glyphwire.handshake_marker);
                if (seen) mr.reader(0).toss(glyphwire.handshake_marker.len);
                handshake = seen;
            }

            // Nothing is drained from either stream until the handshake
            // question resolves -- `MultiReader` grows its buffers to
            // hold whatever arrives meanwhile, same as it would while
            // waiting on the other stream in `std.process.run`.
            if (handshake) |aware| {
                try self.flushCapturedStream(mr.reader(0), aware, null, &passthrough_out.interface);
                try self.flushCapturedStream(mr.reader(1), aware, .{ .r = 255, .g = 85, .b = 85 }, &passthrough_err.interface);
            }
        }

        // Covers the case where the handshake question never resolved
        // inside the loop (e.g. a plain command whose entire stdout, if
        // any, is shorter than the marker) -- treated as "not handshaken"
        // and flushed to the grid like everything else this mechanism
        // defaults to.
        const aware = handshake orelse false;
        try self.flushCapturedStream(mr.reader(0), aware, null, &passthrough_out.interface);
        try self.flushCapturedStream(mr.reader(1), aware, .{ .r = 255, .g = 85, .b = 85 }, &passthrough_err.interface);

        try mr.checkAnyError();
    }

    /// Drains whatever `r` currently has buffered: onto the grid (`fg`) as
    /// plain text if `aware` is false, or straight through to this
    /// process's own real stdio (`passthrough`) if it's true -- see
    /// `runCommand`'s doc comment for what `aware` means. A no-op when
    /// nothing is buffered, so it's safe to call speculatively before the
    /// handshake question is even resolved (see `pumpChildOutput`).
    ///
    /// The grid path is a single `write_text` of the raw chunk:
    /// `Layer.writeText` handles `\n` (and `\r`, `\t`, `\b`, and stripping
    /// stray `ESC ...` sequences) itself now, so there's no line-splitting
    /// or cursor bookkeeping to do here. A line straddling two chunks just
    /// works -- the second `write_text` picks up exactly where the first
    /// left the cursor.
    fn flushCapturedStream(self: *Prompt, r: *std.Io.Reader, aware: bool, fg: ?glyphwire.Color, passthrough: *std.Io.Writer) !void {
        const chunk = r.buffered();
        if (chunk.len == 0) return;
        defer r.toss(chunk.len);

        if (aware) {
            try passthrough.writeAll(chunk);
            try passthrough.flush();
            return;
        }

        try self.client.writeText(chunk, fg, null);
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

    /// Expands a leading alias in `words` into a fresh owned token list.
    /// Follows an alias whose body again begins with an alias name
    /// (bash-style chaining), but stops the first time a name would be
    /// expanded twice on one line -- so `alias ls='ls --color'` resolves
    /// exactly once instead of looping -- with a hard depth cap as a
    /// backstop. When `words[0]` isn't an alias the result is just an
    /// owned copy of `words`. Always freshly allocated; free with
    /// `wordsplit.freeTokens`.
    fn expandAliases(self: *Prompt, words: []const []const u8) ![]const []const u8 {
        const alloc = self.client.alloc;

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |w| alloc.free(w);
            list.deinit(alloc);
        }
        for (words) |w| try list.append(alloc, try alloc.dupe(u8, w));

        var seen: std.ArrayList([]const u8) = .empty;
        defer {
            for (seen.items) |n| alloc.free(n);
            seen.deinit(alloc);
        }

        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            if (list.items.len == 0) break;
            const first = list.items[0];

            for (seen.items) |n| {
                if (std.mem.eql(u8, n, first)) return list.toOwnedSlice(alloc);
            }
            const body = self.aliases.get(first) orelse break;
            try seen.append(alloc, try alloc.dupe(u8, first));

            const body_words = try wordsplit.split(alloc, body);
            defer wordsplit.freeTokens(alloc, body_words);

            alloc.free(list.orderedRemove(0));
            var at: usize = 0;
            for (body_words) |bw| {
                try list.insert(alloc, at, try alloc.dupe(u8, bw));
                at += 1;
            }
        }

        return list.toOwnedSlice(alloc);
    }

    /// Inserts a run of characters at the cursor -- the multi-char sibling
    /// of `insertChar`, used by Tab completion to drop in a completed
    /// suffix in one `insert_cells` + `write_text` pair instead of a round
    /// trip per character.
    fn insertText(self: *Prompt, text: []const u8) !void {
        if (text.len == 0) return;
        try self.buffer.insertSlice(self.client.alloc, self.cursor, text);
        try self.setCursorAt(self.cursor);
        try self.client.insertCells(text.len);
        try self.client.writeText(text, null, null);
        self.cursor += text.len;
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
        if (self.buffer.items.len > 0) try self.client.writeText(self.buffer.items, null, null);
        try self.setCursorAt(self.cursor);
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
