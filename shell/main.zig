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
/// insert/delete (arrow keys, ctrl+a/e/u, ctrl+arrow word jumps -- see
/// `Prompt`), and now launches a child process per submitted line (see
/// `Prompt.runCommand`). Every child is assumed "glyphwire compatible":
/// it inherits `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX` from this process and
/// writes to the grid itself over its own connection, the same way
/// `glyphwire-demo` or `glyphwire-ls` do -- the shell just spawns it and
/// waits, no stdout/stderr capture. Capturing output from a plain,
/// non-glyphwire-aware program is separate, later work. `cd` is a builtin
/// (see `Prompt.doCd`) rather than spawned, since changing directory in a
/// child process wouldn't affect this one; the prompt shows the current
/// directory before `> ` so a `cd` actually taking effect is visible.
/// ctrl+c/ctrl+v are ignored for now too.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

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

        if (std.mem.eql(u8, ev.key, "enter")) {
            try prompt.submitLine();
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
        } else if (ctrl and std.mem.eql(u8, ev.key, "left")) {
            try prompt.moveCursorTo(prompt.wordLeft());
        } else if (ctrl and std.mem.eql(u8, ev.key, "right")) {
            try prompt.moveCursorTo(prompt.wordRight());
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
        } else {
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

    /// Writes the current directory followed by `> ` -- reading it fresh
    /// each time (rather than caching it) is what makes a successful `cd`
    /// visible on the very next prompt.
    fn showPrompt(self: *Prompt) !void {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(self.client.io, &cwd_buf) catch 0;

        var prefix_buf: [std.fs.max_path_bytes + 4]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s} > ", .{cwd_buf[0..cwd_len]}) catch "> ";

        try self.client.writeText(prefix, null, null);
        const cur = try self.client.getCursor();
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;
        self.cursor = 0;
        self.buffer.clearRetainingCapacity();
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
    /// back when this just echoed the line to a fixed offset.
    fn submitLine(self: *Prompt) !void {
        try self.client.setCursor(self.line_start_row + 1, 0);

        const alloc = self.client.alloc;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        var it = std.mem.tokenizeAny(u8, self.buffer.items, " \t");
        while (it.next()) |tok| try argv.append(alloc, tok);

        if (argv.items.len > 0) {
            if (std.mem.eql(u8, argv.items[0], "cd")) {
                try self.doCd(argv.items[1..]);
            } else {
                try self.runCommand(argv.items);
            }
        }

        const cur = self.client.getCursor() catch glyphwire.Cursor{ .row = self.line_start_row + 1, .col = 0 };
        try self.client.setCursor(cur.row + 1, 0);
        try self.showPrompt();
    }

    /// Resolves `argv[0]` (see `resolveCommand`), spawns it, and waits for
    /// it to exit. No stdout/stderr capture, no argument quoting -- the
    /// child is expected to be a glyphwire-aware program that draws to the
    /// grid itself over its own connection (inheriting
    /// `GLYPHWIRE_SOCK`/`GLYPHWIRE_CTX` automatically, since child
    /// processes inherit the environment by default). A resolution or
    /// spawn failure (e.g. unknown command) is reported onto the grid
    /// rather than propagated, so a typo doesn't take down the prompt.
    fn runCommand(self: *Prompt, argv: []const []const u8) !void {
        const alloc = self.client.alloc;

        const resolved = resolveCommand(alloc, self.client.io, argv[0]) catch argv[0];
        defer if (resolved.ptr != argv[0].ptr) alloc.free(resolved);

        const full_argv = try alloc.dupe([]const u8, argv);
        defer alloc.free(full_argv);
        full_argv[0] = resolved;

        var child = std.process.spawn(self.client.io, .{ .argv = full_argv }) catch |err| {
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
    /// affect this one, so it has to happen here directly. No args goes
    /// to `$HOME`, matching a real shell; a bad path or missing `$HOME`
    /// is reported onto the grid the same way `runCommand` reports a
    /// spawn failure, rather than propagated.
    fn doCd(self: *Prompt, args: []const []const u8) !void {
        const io = self.client.io;
        const target = if (args.len > 0)
            args[0]
        else
            self.environ_map.get("HOME") orelse {
                try self.client.writeText("cd: HOME not set", .{ .r = 255, .g = 85, .b = 85 }, null);
                return;
            };

        var dir = std.Io.Dir.cwd().openDir(io, target, .{}) catch |err| {
            try self.reportCdError(target, err);
            return;
        };
        defer dir.close(io);

        std.process.setCurrentDir(io, dir) catch |err| {
            try self.reportCdError(target, err);
        };
    }

    fn reportCdError(self: *Prompt, target: []const u8, err: anyerror) !void {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "cd: {s}: {t}", .{ target, err }) catch "cd: failed";
        try self.client.writeText(msg, .{ .r = 255, .g = 85, .b = 85 }, null);
    }
};

/// Resolves a command name to a path to exec. Checks
/// `<cwd>/zig-out/bin/<name>` first -- a dev-mode convenience so typing
/// `ls` or `glyphwire-demo` at the prompt finds binaries built alongside
/// glyphwire-shell itself, mirroring `host/main.zig`'s `resolveSibling` --
/// falling back to the bare name unresolved, which `std.process.spawn`
/// then resolves via `$PATH` the normal way. Already-qualified names
/// (containing `/`) are passed through untouched either way.
fn resolveCommand(alloc: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const candidate = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/{s}", .{ cwd_buf[0..cwd_len], name });

    std.Io.Dir.cwd().access(io, candidate, .{}) catch {
        alloc.free(candidate);
        return name;
    };
    return candidate;
}

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
