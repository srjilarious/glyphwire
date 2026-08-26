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
/// The prompt is intentionally minimal for now: echo, Enter, Backspace/
/// Delete, no command parsing or execution yet. That'll turn
/// `Prompt.submitLine` into something that spawns a child process per
/// line -- closer to a real shell -- without needing to restructure
/// what's built here; ctrl+c/ctrl+v are ignored for now too.
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
/// starts a new prompt row below it, Backspace/Delete erase the last
/// typed character. Runs forever (killed along with the rest of the
/// process tree, same as any other long-lived child in this codebase).
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

        if (std.mem.eql(u8, ev.key, "enter")) {
            try prompt.submitLine();
        } else if (std.mem.eql(u8, ev.key, "backspace") or std.mem.eql(u8, ev.key, "delete")) {
            // Without cursor movement (no left/right arrow support yet),
            // the cursor is always at the end of the line, so "delete"
            // (erase after cursor) and "backspace" (erase before cursor)
            // aren't distinguishable -- both just erase the last char.
            try prompt.eraseLast();
        } else {
            const shift = listener.isKeyDown("left_shift") or listener.isKeyDown("right_shift");
            if (charFromKeyName(ev.key, shift)) |ch| {
                try prompt.typeChar(ch);
            }
        }
    }
}

/// The prompt's line-editing state. Tracks only where the current line
/// started and how long it is -- not its actual text -- since the server
/// already holds the real characters in its cell grid; that's enough to
/// know where to move the cursor for editing.
const Prompt = struct {
    client: *glyphwire.Client,
    line_start_row: usize = 0,
    line_start_col: usize = 0,
    line_len: usize = 0,
    buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,

    fn showPrompt(self: *Prompt) !void {
        try self.client.writeText("> ", null, null);
        const cur = try self.client.getCursor();
        self.line_start_row = cur.row;
        self.line_start_col = cur.col;
        self.line_len = 0;
        self.buffer.clearRetainingCapacity();
    }

    fn typeChar(self: *Prompt, ch: u8) !void {
        try self.client.writeText(&[_]u8{ch}, null, null);
        try self.buffer.append(self.client.alloc, ch);
        self.line_len += 1;
    }

    fn eraseLast(self: *Prompt) !void {
        if (self.line_len == 0) return;
        self.line_len -= 1;
        try self.client.setCursor(self.line_start_row, self.line_start_col + self.line_len);
        try self.client.writeText(" ", null, null);
        try self.client.setCursor(self.line_start_row, self.line_start_col + self.line_len);
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
