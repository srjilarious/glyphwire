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
/// The prompt is intentionally minimal for now: echo, Enter, real cursor
/// movement and interior insert/delete (arrow keys, ctrl+a/e/u, ctrl+
/// arrow word jumps -- see `Prompt`), but no command parsing or execution
/// yet. That'll turn `Prompt.submitLine` into something that spawns a
/// child process per line -- closer to a real shell -- without needing to
/// restructure what's built here; ctrl+c/ctrl+v are ignored for now too.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const socket_path = if (init.environ_map.get("GLYPHWIRE_SOCK")) |sp|
        sp
    else
        try spawnOwnServer(init.io, arena, init.environ_map);

    if (args.len < 2) {
        return runPrompt(init.io, alloc, socket_path);
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

/// Prints `> `, echoes typed characters live, Enter commits the line and
/// starts a new prompt row below it. See `Prompt` for the rest of the line
/// editing (cursor movement, interior insert/delete). Runs forever (killed
/// along with the rest of the process tree, same as any other long-lived
/// child in this codebase).
fn runPrompt(io: std.Io, alloc: std.mem.Allocator, socket_path: []const u8) !void {
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

    var prompt: Prompt = .{ .client = &client };
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
/// and, unlike the append-only version this grew from, the actual buffer
/// text plus a cursor *offset* into it -- needed the moment editing can
/// happen anywhere but the end (ctrl+a/e/u, ctrl+arrow word jumps, plain
/// arrow movement). The server still holds the authoritative on-screen
/// cells; `buffer` exists so edits away from the end (insert, delete,
/// kill) know what text is where without reading it back over the wire.
const Prompt = struct {
    client: *glyphwire.Client,
    line_start_row: usize = 0,
    line_start_col: usize = 0,
    buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,
    /// Offset into `buffer`, 0..=buffer.items.len, where the next
    /// insert/delete acts and where the on-screen cursor should sit.
    cursor: usize = 0,

    fn showPrompt(self: *Prompt) !void {
        try self.client.writeText("> ", null, null);
        const cur = try self.client.getCursor();
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;
        self.cursor = 0;
        self.buffer.clearRetainingCapacity();
    }

    /// Inserts `ch` at the cursor (append, if the cursor's at the end) and
    /// redraws everything from the insertion point onward, since the wire
    /// protocol has no "shift cells right" primitive to insert into an
    /// already-drawn line.
    fn insertChar(self: *Prompt, ch: u8) !void {
        const old_len = self.buffer.items.len;
        try self.buffer.insert(self.client.alloc, self.cursor, ch);
        self.cursor += 1;
        try self.redrawTail(self.cursor - 1, old_len);
    }

    /// Deletes the character before the cursor (backspace).
    fn deleteBackward(self: *Prompt) !void {
        if (self.cursor == 0) return;
        const old_len = self.buffer.items.len;
        _ = self.buffer.orderedRemove(self.cursor - 1);
        self.cursor -= 1;
        try self.redrawTail(self.cursor, old_len);
    }

    /// Deletes the character at the cursor (forward delete) -- distinct
    /// from `deleteBackward` now that the cursor isn't always pinned to
    /// the end of the line.
    fn deleteForward(self: *Prompt) !void {
        if (self.cursor >= self.buffer.items.len) return;
        const old_len = self.buffer.items.len;
        _ = self.buffer.orderedRemove(self.cursor);
        try self.redrawTail(self.cursor, old_len);
    }

    /// ctrl+u: deletes from the start of the line through the cursor.
    fn killToStart(self: *Prompt) !void {
        if (self.cursor == 0) return;
        const old_len = self.buffer.items.len;
        try self.buffer.replaceRange(self.client.alloc, 0, self.cursor, &.{});
        self.cursor = 0;
        try self.redrawTail(0, old_len);
    }

    /// Moves the cursor without changing the buffer -- ctrl+a/ctrl+e,
    /// ctrl+arrow word jumps, and plain arrow movement all end here.
    fn moveCursorTo(self: *Prompt, offset: usize) !void {
        self.cursor = std.math.clamp(offset, 0, self.buffer.items.len);
        try self.client.setCursor(self.line_start_row, self.line_start_col + self.cursor);
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

    /// Rewrites the line from `from` (a buffer offset) through the end of
    /// the *new* buffer, then blanks any cells left over from a longer
    /// `old_len` (a delete/kill shrank the buffer -- insert never needs
    /// this, since `old_len` is always the shorter one already covered by
    /// the first write), and finally restores the cursor to its real
    /// position. `writeText` advances the cursor as it writes, so the two
    /// writes below chain correctly with no `setCursor` between them.
    fn redrawTail(self: *Prompt, from: usize, old_len: usize) !void {
        try self.client.setCursor(self.line_start_row, self.line_start_col + from);
        try self.client.writeText(self.buffer.items[from..], null, null);

        const new_len = self.buffer.items.len;
        if (old_len > new_len) {
            var i: usize = new_len;
            while (i < old_len) : (i += 1) try self.client.writeText(" ", null, null);
        }

        try self.client.setCursor(self.line_start_row, self.line_start_col + self.cursor);
    }

    /// Leaves the just-typed line where it already is (it's been live-
    /// echoed character by character), echoes it back on the row below
    /// -- a stand-in for the command output `submitLine` will eventually
    /// produce once it spawns a child process per line -- then starts a
    /// fresh prompt on the row after that.
    fn submitLine(self: *Prompt) !void {
        try self.client.setCursor(self.line_start_row + 1, 0);
        try self.client.writeText(self.buffer.items, .{ .r = 128, .g = 128, .b = 128 }, null);
        try self.client.setCursor(self.line_start_row + 2, 0);
        try self.showPrompt();
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
