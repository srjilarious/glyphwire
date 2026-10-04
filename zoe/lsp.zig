// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's Language Server Protocol client: the transport, the handshake, and
//! the handful of requests the editor makes.
//!
//! **The framing is already ours.** An LSP message is a `Content-Length`
//! header, a blank line, then that many body bytes -- which is glyphwire's
//! own wire format, so `glyphwire.wire.FrameDecoder` reassembles a server's
//! stdout without a line of new framing code.
//!
//! **One reader thread per server, and it does as little as possible.** It
//! reads bytes, reassembles frames, duplicates each body onto an inbox, and
//! calls `InputListener.wake` -- nothing else. Every bit of parsing happens
//! on the UI thread in `nextEvent`. That split is deliberate: it means no
//! JSON arena, no `Diagnostic`, no `Server` field is ever touched by two
//! threads, and the only shared state is a mutex-guarded list of byte
//! slices. A server is attached for the whole session, so the "future with
//! an atomic done flag" pattern `read/ai.zig` uses for a request that
//! finishes doesn't fit here; a thread that lives as long as the child does.
//!
//! **Nothing here blocks the editor.** `start` sends `initialize` and
//! returns; documents opened before the reply lands are held in
//! `pending_opens` and flushed when it does. A request in flight is an id in
//! `in_flight`, not a wait.
//!
//! **Positions are not byte offsets.** LSP counts UTF-16 code units by
//! default; zls negotiates UTF-8, basedpyright (pyright underneath) does
//! not. Both encodings are implemented, the choice is negotiated per server
//! and stored on it, and every position crossing the boundary goes through
//! `byteToCharacter` / `characterToByte`. Getting this wrong is invisible in
//! ASCII and silently off-by-N on the first line with a non-ASCII character
//! in it, which is why those two functions have unit tests.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// How a server counts the `character` field of a `Position`. LSP's default
/// is `utf16`; a server may agree to `utf8` during `initialize`, which makes
/// every conversion below a no-op.
pub const PositionEncoding = enum {
    utf8,
    utf16,

    /// The wire names, in the order we prefer them: UTF-8 first, since a
    /// server that takes it saves every position conversion in the editor.
    pub const preferred = [_][]const u8{ "utf-8", "utf-16" };

    fn fromWire(name: []const u8) ?PositionEncoding {
        if (std.mem.eql(u8, name, "utf-8")) return .utf8;
        if (std.mem.eql(u8, name, "utf-16")) return .utf16;
        // "utf-32" exists in the spec. Nothing implements it, and guessing
        // wrong is worse than falling back to the default.
        return null;
    }
};

/// `GLYPHWIRE_LSP_DEBUG=1`: trace the server lifecycle to stderr -- spawn,
/// handshake, each chunk of bytes, each routed reply, death. Off by default.
///
/// A language server failing is quiet by design (see `Pool.start`), which is
/// right for someone who simply hasn't installed one and useless when
/// something is actually wrong. This is the switch that makes it loud, and
/// the precursor to the `:lsp log` the design note wants.
pub var debug: bool = false;

fn trace(comptime fmt: []const u8, args: anytype) void {
    if (!debug) return;
    std.debug.print("zoe-lsp: " ++ fmt ++ "\n", args);
}

/// Whatever the editor wants poked when a message lands. In the running
/// editor this is `InputListener.wake`, which releases the blocked `next` in
/// `Ui.run` so the UI thread comes round and drains the inbox.
///
/// A function pointer rather than the listener itself because a language
/// server connection has no business knowing what a display server is -- and
/// because `tests/zoe_tests.zig` can then drive the whole transport, the
/// handshake and the message parsing with no process and no window, which is
/// the point: the transport is tested against bytes, not against an
/// installed zls.
pub const Waker = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (?*anyopaque) void = null,

    pub fn wake(self: Waker) void {
        if (self.func) |f| f(self.ctx);
    }

    pub fn fromListener(listener: *glyphwire.InputListener) Waker {
        return .{ .ctx = listener, .func = &wakeListener };
    }

    fn wakeListener(ctx: ?*anyopaque) void {
        const listener: *glyphwire.InputListener = @ptrCast(@alignCast(ctx.?));
        listener.wake();
    }
};

pub const Position = struct { line: u32 = 0, character: u32 = 0 };
pub const Range = struct { start: Position = .{}, end: Position = .{} };

/// LSP's `DiagnosticSeverity`, with its wire numbering. Ordered worst
/// first, which is the order `diag.zig` sorts by for the sign column.
pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    information = 3,
    hint = 4,

    fn fromWire(n: i64) Severity {
        return switch (n) {
            1 => .err,
            2 => .warning,
            3 => .information,
            4 => .hint,
            // The spec says the field is optional and a client may pick;
            // an error is the safe guess -- better to over-report than to
            // silently file something as a hint.
            else => .err,
        };
    }
};

/// One diagnostic, with everything it points at owned by the struct (freed
/// by `deinit`). `source` is the server's own `source` field when it sends
/// one and the configured server name otherwise, because with basedpyright
/// and ruff both publishing for the same file, "which tool said this" is
/// half of what the message means.
pub const Diagnostic = struct {
    range: Range,
    severity: Severity,
    message: []const u8,
    source: []const u8,
    code: ?[]const u8 = null,

    pub fn deinit(self: *const Diagnostic, alloc: std.mem.Allocator) void {
        alloc.free(self.message);
        alloc.free(self.source);
        if (self.code) |c| alloc.free(c);
    }
};

/// A place in a file, as `textDocument/definition` answers. `path` is a
/// filesystem path, already decoded out of the `file://` URI the server
/// sent, and owned.
pub const Location = struct {
    path: []const u8,
    range: Range,

    pub fn deinit(self: *const Location, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

/// One `CompletionItem`, reduced to what the popup shows and what accepting
/// it does. Every string owned (freed by `deinit`).
pub const CompletionItem = struct {
    label: []const u8,
    /// LSP's `CompletionItemKind` (1 = Text ... 25 = TypeParameter), 0 when
    /// the server didn't say. `complete.kindLabel` names it.
    kind: u8 = 0,
    /// The type or signature shown after the label, when the server sends
    /// one (`detail`, else `labelDetails.detail` + `.description`).
    detail: ?[]const u8 = null,
    /// What accepting inserts: `textEdit.newText`, else `insertText`, else
    /// the label -- with snippet placeholders already flattened to their
    /// default text, since zoe has no snippet engine to tab through them.
    insert: []const u8,
    /// What typed text is matched against: `filterText`, else the label.
    filter: []const u8,
    /// The server's ordering key: `sortText`, else the label.
    sort: []const u8,
    /// `textEdit`'s range (an `InsertReplaceEdit`'s `insert` range): the
    /// text accepting replaces. Null means "the word before the cursor",
    /// which is what an item without one leaves to the client. In the
    /// server's position encoding until the editor converts it.
    edit_range: ?Range = null,

    pub fn deinit(self: *const CompletionItem, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        if (self.detail) |d| alloc.free(d);
        alloc.free(self.insert);
        alloc.free(self.filter);
        alloc.free(self.sort);
    }
};

/// What a reply is a reply *to*. Recorded per outstanding request id so a
/// response can be routed without the caller having stashed a continuation
/// -- and so a stale reply (the user has since moved on) can be recognised
/// and dropped.
pub const RequestKind = enum {
    initialize,
    hover,
    definition,
    completion,
    shutdown,

    /// Whether an unanswered request of this kind is given up on after
    /// `request_timeout_ms`. Only the ones the user is waiting on: a slow
    /// `initialize` is a server still indexing (and its documents queue
    /// meanwhile), and `shutdown` is on the way out anyway.
    pub fn expires(self: RequestKind) bool {
        return switch (self) {
            .hover, .definition, .completion => true,
            .initialize, .shutdown => false,
        };
    }
};

/// How long a request the user is waiting on gets before it is dropped and
/// the statusline says so. Long enough for a server busy with a big
/// workspace; short enough that a wedged one doesn't leave `K` looking like
/// it did nothing at all.
pub const request_timeout_ms: i64 = 5000;

/// Milliseconds on the monotonic clock, the unit in-flight requests are
/// stamped with and `Pool.expire` is given.
pub fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

/// Everything the editor gets back, already parsed and owned. Mirrors
/// `glyphwire.Event`'s convention: the caller takes ownership and frees with
/// `deinit` and the same allocator.
pub const Event = union(enum) {
    /// A server republished the whole diagnostic set for one file. The
    /// editor replaces what it held for `(path, server)` -- never merges,
    /// since a fixed problem is expressed by its absence from this list.
    diagnostics: struct {
        path: []const u8,
        server: []const u8,
        items: []Diagnostic,
    },
    /// A `textDocument/hover` reply. `text` is null when the server had
    /// nothing to say at that position, which is a normal answer.
    hover: struct { request_id: i64, server: []const u8, text: ?[]const u8 },
    /// A `textDocument/definition` reply; `target` null for "no definition
    /// found", also a normal answer.
    definition: struct { request_id: i64, server: []const u8, target: ?Location },
    /// A `textDocument/completion` reply. `incomplete` is the server saying
    /// its list was cut short (`CompletionList.isIncomplete`), so typing
    /// more should ask again rather than only filter what came back.
    completion: struct {
        request_id: i64,
        server: []const u8,
        incomplete: bool,
        items: []CompletionItem,
    },
    /// A request went `request_timeout_ms` without an answer and has been
    /// forgotten; a reply that turns up later is dropped as unknown. The
    /// server itself is left alone -- slow once is not dead.
    timed_out: struct { request_id: i64, server: []const u8, kind: RequestKind },
    /// The server's stdout closed: it exited or crashed. The editor clears
    /// its diagnostics and says so once -- see `Pool.reap`.
    died: struct { server: []const u8 },

    pub fn deinit(self: *const Event, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .diagnostics => |d| {
                alloc.free(d.path);
                for (d.items) |*it| it.deinit(alloc);
                alloc.free(d.items);
            },
            .hover => |h| if (h.text) |t| alloc.free(t),
            .definition => |d| if (d.target) |*t| t.deinit(alloc),
            .completion => |c| freeCompletionItems(alloc, c.items),
            .timed_out, .died => {},
        }
    }
};

pub fn freeCompletionItems(alloc: std.mem.Allocator, items: []CompletionItem) void {
    for (items) |*it| it.deinit(alloc);
    alloc.free(items);
}

/// One configured server: what to run, and what it is for. Owned by the
/// caller (`langconf.Config`'s arena in practice) and only read here.
pub const ServerConfig = struct {
    /// The name the editor shows and the config merges by.
    name: []const u8,
    /// Grammar names (`syntax.default_langs`) this server serves. Also the
    /// LSP `languageId`s, except where `languageId` maps them otherwise.
    languages: []const []const u8,
    /// argv. `cmd[0]` is probed on `PATH` before anything is spawned.
    cmd: []const []const u8,
    /// `initializationOptions`, as raw JSON text (the Lua config's table,
    /// already serialized). Null sends none.
    settings_json: ?[]const u8 = null,
    enabled: bool = true,
};

/// The LSP `languageId` for one of zoe's grammar names. They coincide for
/// nearly everything that matters -- `zig`, `python`, `c`, `lua`, `json`,
/// `toml` -- and where they don't, the difference is a fixed fact about LSP
/// rather than anything configurable.
pub fn languageId(grammar: []const u8) []const u8 {
    if (std.mem.eql(u8, grammar, "bash")) return "shellscript";
    if (std.mem.eql(u8, grammar, "markdown_inline")) return "markdown";
    return grammar;
}

/// Whether `exe` can be found and executed. A bare name is looked up in
/// `PATH`; a name with a separator in it is taken as a path and checked
/// directly. This is what keeps a server nobody has installed from being a
/// startup error: it simply isn't there, and `:lsp` says so.
pub fn onPath(
    io: std.Io,
    exe: []const u8,
    environ: *const std.process.Environ.Map,
) bool {
    if (exe.len == 0) return false;
    if (std.mem.indexOfScalar(u8, exe, '/') != null) {
        std.Io.Dir.cwd().access(io, exe, .{}) catch return false;
        return true;
    }
    const path = environ.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, exe }) catch continue;
        std.Io.Dir.cwd().access(io, full, .{}) catch continue;
        return true;
    }
    return false;
}

// ─── Position conversion ─────────────────────────────────────────────────

/// The `character` an LSP `Position` carries for byte offset `byte` within
/// `line` (the line's text, no terminator), under `enc`.
///
/// Under `utf8` a character *is* a byte, so this is the offset clamped to
/// the line. Under `utf16` it counts UTF-16 code units, which means one per
/// codepoint below U+10000 and two above it -- so an emoji counts double and
/// a Japanese character counts single, however many UTF-8 bytes either takes.
pub fn byteToCharacter(line: []const u8, byte: usize, enc: PositionEncoding) u32 {
    const at = @min(byte, line.len);
    if (enc == .utf8) return @intCast(at);

    var units: u32 = 0;
    var i: usize = 0;
    while (i < at) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        // A truncated or invalid sequence at the end of the line counts as
        // one unit rather than running off the end: a malformed byte should
        // not move every later position.
        if (i + len > line.len) {
            units += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(line[i .. i + len]) catch {
            units += 1;
            i += 1;
            continue;
        };
        units += if (cp >= 0x10000) 2 else 1;
        i += len;
    }
    return units;
}

/// The inverse: the byte offset in `line` for an LSP `character`. A
/// `character` past the end of the line clamps to its length, which is what
/// servers mean by a range ending at a line's end; one landing *inside* a
/// codepoint (a surrogate half, from a server counting differently than it
/// said) rounds down to that codepoint's start rather than splitting it.
pub fn characterToByte(line: []const u8, character: u32, enc: PositionEncoding) usize {
    if (enc == .utf8) return @min(@as(usize, character), line.len);

    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (units >= character) return i;
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        if (i + len > line.len) return line.len;
        const cp = std.unicode.utf8Decode(line[i .. i + len]) catch {
            units += 1;
            i += 1;
            continue;
        };
        const width: u32 = if (cp >= 0x10000) 2 else 1;
        // Landing mid-codepoint: stop before it.
        if (units + width > character) return i;
        units += width;
        i += len;
    }
    return line.len;
}

// ─── URIs ────────────────────────────────────────────────────────────────

/// `path` as a `file://` URI, percent-encoding everything outside the
/// unreserved set (and leaving `/` alone). Owned by the caller.
/// One entry of LSP's `workspaceFolders`: a directory and its display
/// name. Owned by whoever holds the list.
pub const WorkspaceFolder = struct {
    path: []const u8,
    name: []const u8,
};

fn freeFolder(alloc: std.mem.Allocator, f: WorkspaceFolder) void {
    alloc.free(f.path);
    alloc.free(f.name);
}

/// `folders` as LSP's `WorkspaceFolder[]` JSON: `[{"uri":..,"name":..}]`.
/// Caller owns the result.
pub fn workspaceFoldersJson(alloc: std.mem.Allocator, folders: []const WorkspaceFolder) ![]u8 {
    const Wire = struct { uri: []const u8, name: []const u8 };
    const wire = try alloc.alloc(Wire, folders.len);
    defer alloc.free(wire);
    var made: usize = 0;
    defer for (wire[0..made]) |w| alloc.free(w.uri);
    for (folders, wire) |f, *w| {
        w.* = .{ .uri = try pathToUri(alloc, f.path), .name = f.name };
        made += 1;
    }
    return std.json.Stringify.valueAlloc(alloc, wire, .{});
}

pub fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |c| {
        if (unreserved(c) or c == '/') {
            try out.append(alloc, c);
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The filesystem path inside a `file://` URI, percent-decoded. Owned by
/// the caller. A URI with any other scheme (`untitled:`, `jdt:`) is not a
/// file we can open, and answers null.
pub fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    const rest = uri["file://".len..];
    // `file://host/path` -- only an empty or `localhost` authority names
    // this machine, and only this machine's files can be opened.
    const body = if (std.mem.startsWith(u8, rest, "localhost/")) rest["localhost".len..] else rest;
    if (body.len == 0 or body[0] != '/') return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == '%' and i + 2 < body.len) {
            const hi = std.fmt.charToDigit(body[i + 1], 16) catch {
                try out.append(alloc, body[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(body[i + 2], 16) catch {
                try out.append(alloc, body[i]);
                i += 1;
                continue;
            };
            try out.append(alloc, @intCast(hi * 16 + lo));
            i += 3;
            continue;
        }
        try out.append(alloc, body[i]);
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}

fn unreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

// ─── One server ──────────────────────────────────────────────────────────

/// What a server said it can do, from its `initialize` result. Only the
/// capabilities the editor actually asks about: a request sent to a server
/// that doesn't advertise it gets an error back, which is noise the editor
/// can avoid by asking first.
pub const Caps = struct {
    hover: bool = false,
    definition: bool = false,
    completion: bool = false,
    /// `completionProvider.triggerCharacters`: typing one of these asks for
    /// completions straight away (`.` for a field, `@` for a zig builtin).
    /// Owned by the server's allocator.
    completion_triggers: []const []const u8 = &.{},
};

const State = enum {
    /// `initialize` sent, reply outstanding. Document syncs queue up.
    starting,
    /// Handshake done; requests may be sent.
    ready,
    /// The child is gone (crashed, exited, or failed to start). Nothing is
    /// sent, and nothing is retried automatically -- see `Pool.reap`.
    dead,
};

/// A document opened before the handshake finished, held until it can be
/// sent. Both fields owned.
const PendingOpen = struct {
    uri: []const u8,
    language_id: []const u8,
    text: []const u8,
};

/// An outstanding request: what it was, and when it went out (`nowMs`), so
/// `Pool.expire` can give up on it.
const InFlight = struct {
    id: i64,
    kind: RequestKind,
    sent_ms: i64,
};

/// One language server process and the connection to it.
pub const Server = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// The configured name (`"zls"`, `"basedpyright"`), owned. Used for
    /// display, for the diagnostic `source` fallback, and as the identity
    /// the editor keys stored diagnostics by.
    name: []const u8,
    /// Grammar names this server serves, owned.
    languages: []const []const u8,

    /// Null for a `Server` with no process behind it: one being torn down,
    /// or one a test drives directly through `feedBytes`.
    child: ?std.process.Child = null,
    reader_thread: ?std.Thread = null,

    /// Guards `inbox` and `dead_reported`, and is the only lock the reader
    /// thread takes.
    mutex: std.Io.Mutex = .init,
    /// Reassembles frames out of whatever `feedBytes` is handed. Touched
    /// only by whoever feeds bytes in -- the reader thread, or a test.
    decoder: glyphwire.wire.FrameDecoder = .{},
    /// Raw JSON bodies framed so far, oldest first. Owned.
    inbox: std.ArrayList([]u8) = .empty,
    /// Set by the reader thread when stdout closes. Atomic because the UI
    /// thread reads it every drain without taking the lock.
    stdout_closed: std.atomic.Value(bool) = .init(false),
    /// Whether a `.died` event has already been handed out, so a dead
    /// server is reported once rather than every drain.
    died_reported: bool = false,

    /// Poked when something lands in the inbox. See `Waker`.
    waker: Waker,

    state: State = .starting,
    encoding: PositionEncoding = .utf16,
    caps: Caps = .{},

    next_id: i64 = 1,
    in_flight: std.ArrayList(InFlight) = .empty,
    pending_opens: std.ArrayList(PendingOpen) = .empty,
    /// Every uri `didOpen` has been sent for and `didClose` has not, owned.
    /// Kept so `deinit` can close them and so a `didChange` for a document
    /// the server never saw opened can be turned into a `didOpen`.
    open_docs: std.ArrayList([]const u8) = .empty,

    /// Spawns `cfg.cmd` and sends `initialize`. Returns with the server in
    /// `.starting`: it is usable immediately (documents queue), and becomes
    /// `.ready` when the reply is drained.
    ///
    /// The caller has already checked `onPath`, so a failure here is a real
    /// one (fork failure, a binary that isn't executable) rather than "not
    /// installed".
    /// `folders[0]` is the root: the server's cwd and its `rootUri`.
    /// Every folder goes into `workspaceFolders`.
    pub fn start(
        alloc: std.mem.Allocator,
        io: std.Io,
        waker: Waker,
        cfg: ServerConfig,
        folders: []const WorkspaceFolder,
    ) !*Server {
        const root = folders[0].path;
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);

        const name = try alloc.dupe(u8, cfg.name);
        errdefer alloc.free(name);
        const langs = try dupeStrings(alloc, cfg.languages);
        errdefer freeStrings(alloc, langs);

        var child = try std.process.spawn(io, .{
            .argv = cfg.cmd,
            .cwd = .{ .path = root },
            .stdin = .pipe,
            .stdout = .pipe,
            // Discarded for now: a server's stderr is chatter until
            // something goes wrong, and it has nowhere to go that isn't
            // over the top of the editor. `:lsp log` is the follow-up.
            .stderr = .ignore,
            // A group of its own, so the shell's Ctrl+C SIGINT to zoe's
            // group doesn't take the server with it (see
            // `applib.interrupt`).
            .pgid = 0,
        });
        errdefer child.kill(io);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .name = name,
            .languages = langs,
            .child = child,
            .waker = waker,
        };

        self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{ self, child.stdout.? });
        trace("{s}: spawned {s}, reader thread up", .{ cfg.name, cfg.cmd[0] });

        trace("{s}: sending initialize (root {s})", .{ cfg.name, root });
        self.sendInitialize(cfg, folders) catch |err| {
            trace("{s}: initialize failed to send: {t}", .{ cfg.name, err });
            // A server we can't even greet is no use; let the pool treat it
            // like one that isn't installed.
            self.state = .dead;
            return err;
        };
        return self;
    }

    /// A `Server` with no child process, with `initialize` recorded as in
    /// flight so a fed reply completes the handshake. See `Pool.addForTest`;
    /// nothing else should build one, because a server with no process can
    /// receive but never send.
    fn detached(
        alloc: std.mem.Allocator,
        io: std.Io,
        waker: Waker,
        cfg: ServerConfig,
    ) !*Server {
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        const name = try alloc.dupe(u8, cfg.name);
        errdefer alloc.free(name);
        const langs = try dupeStrings(alloc, cfg.languages);
        errdefer freeStrings(alloc, langs);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .name = name,
            .languages = langs,
            .waker = waker,
        };
        self.next_id = 2;
        try self.in_flight.append(alloc, .{ .id = 1, .kind = .initialize, .sent_ms = nowMs(io) });
        return self;
    }

    /// `shutdown`, `exit`, then stop waiting. Every step is best-effort and
    /// bounded: zoe's own quit path must not hang on a language server that
    /// has stopped listening.
    pub fn deinit(self: *Server) void {
        const alloc = self.alloc;

        if (self.state != .dead) {
            // A polite shutdown lets a server flush its caches; a rude one
            // is fine too, which is why neither result is checked.
            _ = self.request(.shutdown, "shutdown", null) catch 0;
            self.notify("exit", null) catch {};
        }
        // Closing stdin is what actually makes a well-behaved server leave.
        // Through `child.stdin`, and nulled, because `kill` closes whichever
        // of the three streams the child still holds -- closing our own copy
        // of the same descriptor and then letting `kill` close it again is a
        // double close, and the number could belong to something else by
        // then.
        if (self.child) |*child| {
            if (child.stdin) |stdin| {
                stdin.close(self.io);
                child.stdin = null;
            }
            // Closes the child's stdout too, which is what unblocks the
            // reader thread's read so the join below returns.
            child.kill(self.io);
        }
        if (self.reader_thread) |t| t.join();

        for (self.inbox.items) |body| alloc.free(body);
        self.inbox.deinit(alloc);
        self.decoder.deinit(alloc);
        for (self.pending_opens.items) |p| {
            alloc.free(p.uri);
            alloc.free(p.language_id);
            alloc.free(p.text);
        }
        self.pending_opens.deinit(alloc);
        freeListStrings(alloc, &self.open_docs);
        self.in_flight.deinit(alloc);
        freeStrings(alloc, self.caps.completion_triggers);
        freeStrings(alloc, self.languages);
        alloc.free(self.name);
        alloc.destroy(self);
    }

    /// Whether the handshake has finished and requests may be sent. A
    /// predicate rather than an exposed `state` field, because "can I ask
    /// this server something" is the only question callers have.
    pub fn ready(self: *const Server) bool {
        return self.state == .ready;
    }

    /// Whether the handshake is still outstanding. Distinct from "no server"
    /// and from "dead", because those three deserve three different messages.
    pub fn starting(self: *const Server) bool {
        return self.state == .starting;
    }

    /// Stands in for the reader thread reaching EOF, so a test can exercise
    /// the death path without a process to kill.
    pub fn markStdoutClosedForTest(self: *Server) void {
        self.stdout_closed.store(true, .release);
        self.waker.wake();
    }

    pub fn serves(self: *const Server, grammar: []const u8) bool {
        for (self.languages) |l| if (std.mem.eql(u8, l, grammar)) return true;
        return false;
    }

    pub fn alive(self: *const Server) bool {
        return self.state != .dead;
    }

    // ── The reader thread ────────────────────────────────────────────────

    /// The whole of the reader thread: bytes in, `feedBytes`, repeat. It
    /// never parses a message and never touches a field other than the ones
    /// `feedBytes` does.
    ///
    /// **`readStreaming`, not a buffered reader.** This wants "whatever has
    /// arrived, at least one byte", and a `std.Io.Reader` over a 16K buffer
    /// gives "fill the buffer, or hit end of stream". Against a program that
    /// writes a reply and then stays alive -- which is every language server
    /// -- that second thing never happens: the reply sits in the pipe, the
    /// read blocks on for the rest of the buffer, and the handshake never
    /// completes. It looks like a server that ignored `initialize`, and it
    /// cost an afternoon. `InputListener.listenLoop` reads its own frames the
    /// same way, for the same reason.
    fn readLoop(self: *Server, stdout: std.Io.File) void {
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            var data: [1][]u8 = .{&chunk};
            const n = stdout.readStreaming(self.io, &data) catch |err| switch (err) {
                error.EndOfStream => {
                    trace("{s}: stdout EOF", .{self.name});
                    break;
                },
                else => {
                    trace("{s}: stdout read failed: {t}", .{ self.name, err });
                    break;
                },
            };
            // A zero-length read is not end of stream here (that is its own
            // error), so it is nothing to act on -- go round again.
            if (n == 0) continue;
            trace("{s}: read {d} bytes", .{ self.name, n });
            self.feedBytes(chunk[0..n]) catch |err| {
                trace("{s}: feed failed: {t}", .{ self.name, err });
                break;
            };
        }

        trace("{s}: reader thread leaving", .{self.name});
        self.stdout_closed.store(true, .release);
        self.waker.wake();
    }

    /// Reassembles whatever arrived into frames and queues their bodies, then
    /// wakes the editor once. Called by the reader thread with a chunk off the
    /// server's stdout -- and directly by tests, which is the seam that lets
    /// the handshake and the message parsing be exercised against bytes with
    /// no process in the picture.
    ///
    /// One wake per chunk, not per message: the UI drains everything queued
    /// in a single turn, so more wakes would be more turns round the loop for
    /// the same work.
    pub fn feedBytes(self: *Server, chunk: []const u8) !void {
        try self.decoder.feed(self.alloc, chunk);

        var queued: usize = 0;
        while (true) {
            const body = self.decoder.next(self.alloc) catch |err| {
                // A frame we can't parse a header out of means the stream is
                // no longer in sync, and nothing later in it can be trusted.
                trace("{s}: framing error: {t}", .{ self.name, err });
                break;
            } orelse break;
            self.mutex.lockUncancelable(self.io);
            self.inbox.append(self.alloc, body) catch {
                self.mutex.unlock(self.io);
                self.alloc.free(body);
                break;
            };
            self.mutex.unlock(self.io);
            queued += 1;
        }
        if (queued > 0) {
            trace("{s}: queued {d} message(s)", .{ self.name, queued });
            self.waker.wake();
        }
    }

    /// Pops the oldest queued body, or null. Caller owns it.
    fn takeBody(self: *Server) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.inbox.items.len == 0) return null;
        return self.inbox.orderedRemove(0);
    }

    // ── Sending ──────────────────────────────────────────────────────────

    /// One JSON-RPC notification. `params_json` is raw JSON text (or null
    /// for none) -- built by the callers below, which know their own
    /// parameter shapes, rather than through one big anytype.
    fn notify(self: *Server, method: []const u8, params_json: ?[]const u8) !void {
        if (self.state == .dead) return;
        const body = if (params_json) |p|
            try std.fmt.allocPrint(self.alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, p })
        else
            try std.fmt.allocPrint(self.alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}", .{method});
        defer self.alloc.free(body);
        try self.writeFrame(body);
    }

    /// One JSON-RPC request. Returns the id it went out with, recorded in
    /// `in_flight` so the reply can be routed and a stale one recognised.
    fn request(self: *Server, kind: RequestKind, method: []const u8, params_json: ?[]const u8) !i64 {
        if (self.state == .dead) return error.ServerDead;
        const id = self.next_id;
        self.next_id += 1;
        const body = if (params_json) |p|
            try std.fmt.allocPrint(
                self.alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
                .{ id, method, p },
            )
        else
            try std.fmt.allocPrint(
                self.alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}",
                .{ id, method },
            );
        defer self.alloc.free(body);
        try self.in_flight.append(self.alloc, .{ .id = id, .kind = kind, .sent_ms = nowMs(self.io) });
        try self.writeFrame(body);
        return id;
    }

    /// Frames and writes one body to the child's stdin. A write that fails
    /// means the far end is gone, so the server is marked dead rather than
    /// the error being propagated into an editor command -- a language server
    /// that stopped listening is not an editing error.
    fn writeFrame(self: *Server, body: []const u8) !void {
        // The child owns the descriptor (see `deinit`); a null one means the
        // connection is already being torn down.
        const child = self.child orelse {
            // No process: a `Server` a test drives, or one being torn down.
            // Nothing to write to, and nothing to complain about.
            return;
        };
        const stdin = child.stdin orelse {
            self.state = .dead;
            return error.ServerDead;
        };
        const framed = try glyphwire.wire.framedAlloc(self.alloc, body);
        defer self.alloc.free(framed);
        var buf: [4096]u8 = undefined;
        var w = stdin.writer(self.io, &buf);
        w.interface.writeAll(framed) catch {
            self.state = .dead;
            return error.ServerDead;
        };
        w.interface.flush() catch {
            self.state = .dead;
            return error.ServerDead;
        };
    }

    fn sendInitialize(self: *Server, cfg: ServerConfig, folders: []const WorkspaceFolder) !void {
        const root_uri = try pathToUri(self.alloc, folders[0].path);
        defer self.alloc.free(root_uri);
        const folders_json = try workspaceFoldersJson(self.alloc, folders);
        defer self.alloc.free(folders_json);

        // Written out rather than built from a struct because
        // `initializationOptions` is already-serialized JSON from the Lua
        // config, which a typed value can't carry verbatim.
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.alloc);
        try params.print(self.alloc,
            \\{{"processId":{d},"clientInfo":{{"name":"zoe"}},"rootUri":"{s}","workspaceFolders":{s},
        , .{ std.os.linux.getpid(), root_uri, folders_json });
        // `workspaceFolders: true` is the promise behind
        // `didChangeWorkspaceFolders`: `:addfolder` / `:rmfolder` tell a
        // running server rather than restarting it.
        try params.appendSlice(self.alloc,
            \\"capabilities":{"general":{"positionEncodings":["utf-8","utf-16"]},"workspace":{"workspaceFolders":true},
        );
        try params.appendSlice(self.alloc,
            \\"textDocument":{"synchronization":{"didSave":true},"publishDiagnostics":{},"hover":{"contentFormat":["markdown","plaintext"]},"definition":{},
        );
        // `snippetSupport: false` asks for plain text to insert; a server
        // that sends a snippet anyway gets it flattened (`flattenSnippet`).
        try params.appendSlice(self.alloc,
            \\"completion":{"contextSupport":true,"completionItem":{"snippetSupport":false,"labelDetailsSupport":true}}}}
        );
        if (cfg.settings_json) |s| try params.print(self.alloc, ",\"initializationOptions\":{s}", .{s});
        try params.append(self.alloc, '}');

        _ = try self.request(.initialize, "initialize", params.items);
    }

    /// Applies an `initialize` result: the negotiated position encoding and
    /// the capabilities we ask about. Then `initialized`, then every
    /// document that was opened while we waited.
    fn finishHandshake(self: *Server, result: std.json.Value) void {
        if (result == .object) {
            const caps = result.object.get("capabilities");
            if (caps) |c| if (c == .object) {
                if (c.object.get("positionEncoding")) |pe| if (pe == .string) {
                    if (PositionEncoding.fromWire(pe.string)) |e| self.encoding = e;
                };
                self.caps.hover = providerEnabled(c.object.get("hoverProvider"));
                self.caps.definition = providerEnabled(c.object.get("definitionProvider"));
                const cp = c.object.get("completionProvider");
                self.caps.completion = providerEnabled(cp);
                if (cp) |v| if (v == .object) {
                    if (v.object.get("triggerCharacters")) |tc| if (tc == .array) {
                        self.caps.completion_triggers = self.dupeTriggers(tc.array.items) catch &.{};
                    };
                };
            };
        }
        self.state = .ready;
        trace("{s}: ready (encoding {t}, hover {}, definition {})", .{
            self.name,
            self.encoding,
            self.caps.hover,
            self.caps.definition,
        });
        self.notify("initialized", "{}") catch return;

        // Drain in order, and give up the whole queue either way -- a
        // document that fails to open here would otherwise be retried
        // forever with no one watching.
        for (self.pending_opens.items) |p| {
            self.sendDidOpen(p.uri, p.language_id, p.text) catch {};
            self.alloc.free(p.uri);
            self.alloc.free(p.language_id);
            self.alloc.free(p.text);
        }
        self.pending_opens.clearRetainingCapacity();
    }

    fn dupeTriggers(self: *Server, items: []const std.json.Value) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer freeListStrings(self.alloc, &out);
        for (items) |v| {
            if (v != .string or v.string.len == 0) continue;
            try out.append(self.alloc, try self.alloc.dupe(u8, v.string));
        }
        return out.toOwnedSlice(self.alloc);
    }

    /// Whether typing `text` should ask this server for completions at
    /// once: it ends with one of the server's trigger characters.
    pub fn isCompletionTrigger(self: *const Server, text: []const u8) bool {
        for (self.caps.completion_triggers) |t| {
            if (std.mem.endsWith(u8, text, t)) return true;
        }
        return false;
    }

    /// A capability is either a bool or an options object; both mean yes,
    /// and `false`/absent/null mean no.
    fn providerEnabled(v: ?std.json.Value) bool {
        const val = v orelse return false;
        return switch (val) {
            .bool => |b| b,
            .object => true,
            else => false,
        };
    }

    fn sendDidOpen(self: *Server, uri: []const u8, language_id: []const u8, text: []const u8) !void {
        const params = try std.json.Stringify.valueAlloc(self.alloc, .{
            .textDocument = .{
                .uri = uri,
                .languageId = language_id,
                .version = @as(i64, 1),
                .text = text,
            },
        }, .{});
        defer self.alloc.free(params);
        try self.notify("textDocument/didOpen", params);
    }

    /// `workspace/didChangeWorkspaceFolders`. Dropped while the handshake
    /// is still out: the server was started with the folder list as it
    /// stood, and a folder changed in the second or so before it answers
    /// is a rare enough case not to queue for.
    pub fn didChangeWorkspaceFolders(self: *Server, added: []const WorkspaceFolder, removed: []const WorkspaceFolder) !void {
        if (self.state != .ready) return;
        const added_json = try workspaceFoldersJson(self.alloc, added);
        defer self.alloc.free(added_json);
        const removed_json = try workspaceFoldersJson(self.alloc, removed);
        defer self.alloc.free(removed_json);
        const params = try std.fmt.allocPrint(self.alloc, "{{\"event\":{{\"added\":{s},\"removed\":{s}}}}}", .{ added_json, removed_json });
        defer self.alloc.free(params);
        try self.notify("workspace/didChangeWorkspaceFolders", params);
    }

    /// `didOpen`, or a queued open while the handshake is still out.
    pub fn didOpen(self: *Server, uri: []const u8, language_id: []const u8, text: []const u8) !void {
        if (self.state == .dead) return;
        if (!self.isOpen(uri)) try self.open_docs.append(self.alloc, try self.alloc.dupe(u8, uri));
        if (self.state == .starting) {
            try self.pending_opens.append(self.alloc, .{
                .uri = try self.alloc.dupe(u8, uri),
                .language_id = try self.alloc.dupe(u8, language_id),
                .text = try self.alloc.dupe(u8, text),
            });
            return;
        }
        try self.sendDidOpen(uri, language_id, text);
    }

    /// Full-text `didChange`. See the design note: the incremental form
    /// wants a second consumer of `Buffer.pending_edits`, which the
    /// highlighter currently drains alone.
    pub fn didChange(self: *Server, uri: []const u8, version: i64, text: []const u8) !void {
        if (self.state != .ready) return;
        const params = try std.json.Stringify.valueAlloc(self.alloc, .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = .{.{ .text = text }},
        }, .{});
        defer self.alloc.free(params);
        try self.notify("textDocument/didChange", params);
    }

    pub fn didSave(self: *Server, uri: []const u8) !void {
        if (self.state != .ready) return;
        const params = try std.json.Stringify.valueAlloc(self.alloc, .{
            .textDocument = .{ .uri = uri },
        }, .{});
        defer self.alloc.free(params);
        try self.notify("textDocument/didSave", params);
    }

    pub fn didClose(self: *Server, uri: []const u8) !void {
        self.forgetOpen(uri);
        if (self.state != .ready) return;
        const params = try std.json.Stringify.valueAlloc(self.alloc, .{
            .textDocument = .{ .uri = uri },
        }, .{});
        defer self.alloc.free(params);
        try self.notify("textDocument/didClose", params);
    }

    /// A position-taking request (`hover`, `definition`). Returns the id to
    /// match the reply against, or null when this server can't serve it.
    pub fn positionRequest(
        self: *Server,
        kind: RequestKind,
        uri: []const u8,
        pos: Position,
    ) !?i64 {
        if (self.state != .ready) return null;
        const method = switch (kind) {
            .hover => "textDocument/hover",
            .definition => "textDocument/definition",
            // Has a `context` of its own: `completionRequest`.
            .completion, .initialize, .shutdown => return null,
        };
        switch (kind) {
            .hover => if (!self.caps.hover) return null,
            .definition => if (!self.caps.definition) return null,
            else => {},
        }
        const params = try std.json.Stringify.valueAlloc(self.alloc, .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = pos.line, .character = pos.character },
        }, .{});
        defer self.alloc.free(params);
        return try self.request(kind, method, params);
    }

    /// `textDocument/completion` at `pos`. `trigger` is the trigger
    /// character that prompted it, or null for an explicit request (Ctrl+
    /// Space) or one made because an identifier is being typed -- LSP's
    /// `TriggerKind.Invoked`. Returns the id, or null when this server
    /// can't complete.
    pub fn completionRequest(
        self: *Server,
        uri: []const u8,
        pos: Position,
        trigger: ?[]const u8,
    ) !?i64 {
        if (self.state != .ready or !self.caps.completion) return null;
        const params = if (trigger) |t|
            try std.json.Stringify.valueAlloc(self.alloc, .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = pos.line, .character = pos.character },
                .context = .{ .triggerKind = @as(u8, 2), .triggerCharacter = t },
            }, .{})
        else
            try std.json.Stringify.valueAlloc(self.alloc, .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = pos.line, .character = pos.character },
                .context = .{ .triggerKind = @as(u8, 1) },
            }, .{});
        defer self.alloc.free(params);
        return try self.request(.completion, "textDocument/completion", params);
    }

    fn isOpen(self: *const Server, uri: []const u8) bool {
        for (self.open_docs.items) |u| if (std.mem.eql(u8, u, uri)) return true;
        return false;
    }

    fn forgetOpen(self: *Server, uri: []const u8) void {
        for (self.open_docs.items, 0..) |u, i| {
            if (!std.mem.eql(u8, u, uri)) continue;
            self.alloc.free(self.open_docs.orderedRemove(i));
            return;
        }
    }

    fn takeInFlight(self: *Server, id: i64) ?RequestKind {
        for (self.in_flight.items, 0..) |f, i| {
            if (f.id != id) continue;
            return self.in_flight.orderedRemove(i).kind;
        }
        return null;
    }
};

fn dupeStrings(alloc: std.mem.Allocator, in: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, in.len);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |s| alloc.free(s);
        alloc.free(out);
    }
    for (in, out) |src, *dst| {
        dst.* = try alloc.dupe(u8, src);
        made += 1;
    }
    return out;
}

/// Frees an owned slice of owned strings -- the slice itself included, so
/// this is only ever right for a slice that came from a single `alloc.alloc`
/// (`dupeStrings`), never for an `ArrayList`'s `items`: that slice is `len`
/// long while its allocation is `capacity` long, and freeing it as a slice is
/// a free of the wrong size. Use `freeListStrings` for a list.
fn freeStrings(alloc: std.mem.Allocator, in: []const []const u8) void {
    for (in) |s| alloc.free(s);
    alloc.free(in);
}

/// Frees the strings an `ArrayList` holds and then the list, which is the
/// pair that `freeStrings` cannot do (see above).
fn freeListStrings(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

// ─── The pool ────────────────────────────────────────────────────────────

/// Every running server, and the routing over them. One instance per
/// (workspace root, configured server): several servers can serve one
/// language -- basedpyright for types and navigation, ruff for lint -- and
/// that is the normal case rather than an edge one, so everything here is a
/// list rather than a lookup.
pub const Pool = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    waker: Waker,
    /// The workspace root every server was rooted at, owned.
    root: []const u8,
    servers: std.ArrayList(*Server) = .empty,
    /// Names from the config whose binary wasn't found, owned. Kept so
    /// `:lsp` can say "not installed" rather than saying nothing.
    missing: std.ArrayList([]const u8) = .empty,

    /// Every workspace folder, owned, `root` first. Servers start with
    /// the whole list and hear about changes to it.
    folders: std.ArrayList(WorkspaceFolder) = .empty,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        waker: Waker,
        root: []const u8,
    ) !Pool {
        var self: Pool = .{
            .alloc = alloc,
            .io = io,
            .waker = waker,
            .root = try alloc.dupe(u8, root),
        };
        errdefer self.deinit();
        try self.appendFolder(root, std.fs.path.basename(root));
        return self;
    }

    pub fn deinit(self: *Pool) void {
        for (self.servers.items) |s| s.deinit();
        self.servers.deinit(self.alloc);
        freeListStrings(self.alloc, &self.missing);
        for (self.folders.items) |f| freeFolder(self.alloc, f);
        self.folders.deinit(self.alloc);
        self.alloc.free(self.root);
    }

    fn appendFolder(self: *Pool, path: []const u8, name: []const u8) !void {
        const p = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(p);
        const n = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(n);
        try self.folders.append(self.alloc, .{ .path = p, .name = n });
    }

    /// Adds a workspace folder: before `start`, it is simply in the list
    /// every server starts with; after, each running server is told.
    /// A folder already present is ignored.
    pub fn addFolder(self: *Pool, path: []const u8, name: []const u8) !void {
        for (self.folders.items) |f| if (std.mem.eql(u8, f.path, path)) return;
        try self.appendFolder(path, name);
        const added = self.folders.items[self.folders.items.len - 1 ..];
        for (self.servers.items) |s| s.didChangeWorkspaceFolders(added, &.{}) catch {};
    }

    /// Drops a workspace folder and tells each running server. The root
    /// stays a server's cwd and `rootUri` either way -- those were fixed
    /// when it started.
    pub fn removeFolder(self: *Pool, path: []const u8) void {
        for (self.folders.items, 0..) |f, i| {
            if (!std.mem.eql(u8, f.path, path)) continue;
            for (self.servers.items) |s| s.didChangeWorkspaceFolders(&.{}, &.{f}) catch {};
            freeFolder(self.alloc, self.folders.orderedRemove(i));
            return;
        }
    }

    /// Starts every enabled server whose binary is present. A server that
    /// isn't installed is recorded in `missing` and is not an error: most
    /// people have one of these three, not all of them.
    pub fn start(
        self: *Pool,
        configs: []const ServerConfig,
        environ: *const std.process.Environ.Map,
    ) !void {
        for (configs) |cfg| {
            if (!cfg.enabled or cfg.cmd.len == 0) continue;
            if (!onPath(self.io, cfg.cmd[0], environ)) {
                trace("{s}: {s} not on PATH, skipping", .{ cfg.name, cfg.cmd[0] });
                try self.missing.append(self.alloc, try self.alloc.dupe(u8, cfg.name));
                continue;
            }
            const s = Server.start(self.alloc, self.io, self.waker, cfg, self.folders.items) catch |err| {
                trace("{s}: failed to start: {t}", .{ cfg.name, err });
                try self.missing.append(self.alloc, try self.alloc.dupe(u8, cfg.name));
                continue;
            };
            try self.servers.append(self.alloc, s);
        }
    }

    /// Adds a `Server` with no process behind it, in exactly the state a real
    /// one is in immediately after `start`: handshake outstanding, `initialize`
    /// recorded as in flight under id 1. A test then feeds it bytes with
    /// `Server.feedBytes` as though they had come off its stdout.
    ///
    /// Owned by the pool like any other server, so `Pool.deinit` frees it.
    pub fn addForTest(self: *Pool, cfg: ServerConfig) !*Server {
        const s = try Server.detached(self.alloc, self.io, self.waker, cfg);
        errdefer s.deinit();
        try self.servers.append(self.alloc, s);
        return s;
    }

    /// The live servers for a grammar name, in config order. The caller
    /// sends to all of them (a document sync) or takes the first that can
    /// answer (a request).
    pub fn forLanguage(self: *Pool, grammar: []const u8) ServerIterator {
        return .{ .pool = self, .grammar = grammar };
    }

    pub const ServerIterator = struct {
        pool: *Pool,
        grammar: []const u8,
        i: usize = 0,

        pub fn next(self: *ServerIterator) ?*Server {
            while (self.i < self.pool.servers.items.len) {
                const s = self.pool.servers.items[self.i];
                self.i += 1;
                if (s.alive() and s.serves(self.grammar)) return s;
            }
            return null;
        }
    };

    /// The position encoding a named server negotiated. Diagnostics are
    /// converted out of it the moment they arrive (see `Ui.applyDiagnostics`),
    /// and this is how the converter finds out which one to use. An unknown
    /// name answers the protocol default, which is also the safer guess.
    pub fn encodingOf(self: *const Pool, server: []const u8) PositionEncoding {
        for (self.servers.items) |s| {
            if (std.mem.eql(u8, s.name, server)) return s.encoding;
        }
        return .utf16;
    }

    pub fn anyAlive(self: *const Pool) bool {
        for (self.servers.items) |s| if (s.alive()) return true;
        return false;
    }

    /// When the oldest expiring request comes due, in `nowMs` terms, or
    /// null with none outstanding. `Ui.run` waits no longer than this, which
    /// is what lets a timeout fire with no keystroke to wake the loop.
    pub fn nextDeadlineMs(self: *const Pool) ?i64 {
        var best: ?i64 = null;
        for (self.servers.items) |s| {
            if (!s.alive()) continue;
            for (s.in_flight.items) |f| {
                if (!f.kind.expires()) continue;
                const due = f.sent_ms + request_timeout_ms;
                if (best == null or due < best.?) best = due;
            }
        }
        return best;
    }

    /// Forgets one request that has gone `request_timeout_ms` unanswered as
    /// of `now_ms`, and reports it; null when none has. Called in a loop
    /// until null, like `nextEvent`. `now_ms` is a parameter rather than
    /// read here so the tests can move time along without sleeping.
    pub fn expire(self: *Pool, now_ms: i64) ?Event {
        for (self.servers.items) |s| {
            if (!s.alive()) continue;
            for (s.in_flight.items, 0..) |f, i| {
                if (!f.kind.expires()) continue;
                if (now_ms - f.sent_ms < request_timeout_ms) continue;
                _ = s.in_flight.orderedRemove(i);
                trace("{s}: request {d} ({t}) timed out", .{ s.name, f.id, f.kind });
                return .{ .timed_out = .{ .request_id = f.id, .server = s.name, .kind = f.kind } };
            }
        }
        return null;
    }

    /// Drains one parsed event from whichever server has one, or null when
    /// everything queued has been handled. The caller owns the event and
    /// frees it with `Event.deinit`.
    ///
    /// All parsing happens here, on the UI thread, by design -- see this
    /// file's doc comment.
    pub fn nextEvent(self: *Pool) !?Event {
        for (self.servers.items) |s| {
            while (s.takeBody()) |body| {
                defer self.alloc.free(body);
                if (try self.parseBody(s, body)) |ev| return ev;
            }
            // Only once everything it queued has been read: a server that
            // published diagnostics and then exited should have both seen.
            if (s.stdout_closed.load(.acquire) and !s.died_reported) {
                s.died_reported = true;
                s.state = .dead;
                return .{ .died = .{ .server = s.name } };
            }
        }
        return null;
    }

    /// One message from a server: a notification we care about, a response
    /// to something we asked, or nothing. Anything unrecognised is dropped
    /// -- a server may send `window/logMessage`, progress, registration
    /// requests and more, and none of it is the editor's business yet.
    fn parseBody(self: *Pool, s: *Server, body: []const u8) !?Event {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch return null;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return null;

        if (root.object.get("method")) |m| {
            if (m != .string) return null;
            if (!std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) return null;
            return try self.parseDiagnostics(s, root.object.get("params") orelse return null);
        }

        // A response: route by the id we recorded when the request went out.
        const id_val = root.object.get("id") orelse return null;
        const id: i64 = switch (id_val) {
            .integer => |i| i,
            else => return null,
        };
        const kind = s.takeInFlight(id) orelse {
            trace("{s}: reply to unknown id {d}, dropped", .{ s.name, id });
            return null;
        };
        // An error response is a real answer -- the editor reports nothing
        // rather than pretending the server had no result.
        const result = root.object.get("result") orelse return null;

        switch (kind) {
            .initialize => {
                s.finishHandshake(result);
                return null;
            },
            .shutdown => return null,
            .hover => return .{ .hover = .{
                .request_id = id,
                .server = s.name,
                .text = try self.parseHover(result),
            } },
            .definition => return .{ .definition = .{
                .request_id = id,
                .server = s.name,
                .target = try self.parseDefinition(result),
            } },
            .completion => {
                var incomplete = false;
                const items = try self.parseCompletion(result, &incomplete);
                return .{ .completion = .{
                    .request_id = id,
                    .server = s.name,
                    .incomplete = incomplete,
                    .items = items,
                } };
            },
        }
    }

    /// A completion result is `CompletionItem[]`, a `CompletionList`
    /// (`{isIncomplete, items}`), or null for "nothing here" -- which is an
    /// answer too, and comes back as an empty list so the editor can stop
    /// asking about this word.
    fn parseCompletion(self: *Pool, result: std.json.Value, incomplete: *bool) ![]CompletionItem {
        const list: []const std.json.Value = switch (result) {
            .array => |a| a.items,
            .object => |o| blk: {
                if (o.get("isIncomplete")) |v| if (v == .bool) {
                    incomplete.* = v.bool;
                };
                const items = o.get("items") orelse break :blk &.{};
                break :blk if (items == .array) items.array.items else &.{};
            },
            else => &.{},
        };

        var out: std.ArrayList(CompletionItem) = .empty;
        errdefer {
            for (out.items) |*it| it.deinit(self.alloc);
            out.deinit(self.alloc);
        }
        for (list) |v| {
            if (v != .object) continue;
            const item = (try self.parseCompletionItem(v.object)) orelse continue;
            out.append(self.alloc, item) catch |err| {
                item.deinit(self.alloc);
                return err;
            };
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn parseCompletionItem(self: *Pool, o: std.json.ObjectMap) !?CompletionItem {
        const alloc = self.alloc;
        const label = stringField(o, "label") orelse return null;

        // `textEdit` is a `TextEdit` (`range`) or an `InsertReplaceEdit`
        // (`insert` / `replace`). The insert range is the one that doesn't
        // eat the rest of the identifier after the cursor, which is what
        // typing-then-accepting expects.
        var edit_range: ?Range = null;
        var edit_text: ?[]const u8 = null;
        if (o.get("textEdit")) |te| if (te == .object) {
            edit_text = stringField(te.object, "newText");
            edit_range = parseRange(te.object.get("range") orelse te.object.get("insert"));
        };
        const raw_insert = edit_text orelse stringField(o, "insertText") orelse label;
        const is_snippet = if (o.get("insertTextFormat")) |f| f == .integer and f.integer == 2 else false;

        const insert = if (is_snippet)
            try flattenSnippet(alloc, raw_insert)
        else
            try alloc.dupe(u8, raw_insert);
        errdefer alloc.free(insert);

        const label_owned = try alloc.dupe(u8, label);
        errdefer alloc.free(label_owned);
        const filter = try alloc.dupe(u8, stringField(o, "filterText") orelse label);
        errdefer alloc.free(filter);
        const sort = try alloc.dupe(u8, stringField(o, "sortText") orelse label);
        errdefer alloc.free(sort);

        // `detail` is the classic field; `labelDetails` is the newer split
        // into a signature-ish `detail` and a type-ish `description`.
        // basedpyright sends the second, zls the first.
        const detail: ?[]const u8 = if (stringField(o, "detail")) |d|
            try alloc.dupe(u8, d)
        else if (o.get("labelDetails")) |ld| blk: {
            if (ld != .object) break :blk null;
            const a = stringField(ld.object, "detail") orelse "";
            const b = stringField(ld.object, "description") orelse "";
            if (a.len == 0 and b.len == 0) break :blk null;
            const sep: []const u8 = if (a.len > 0 and b.len > 0) " " else "";
            break :blk try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ a, sep, b });
        } else null;

        const kind: u8 = if (o.get("kind")) |k|
            (if (k == .integer and k.integer > 0 and k.integer <= 25) @intCast(k.integer) else 0)
        else
            0;

        return .{
            .label = label_owned,
            .kind = kind,
            .detail = detail,
            .insert = insert,
            .filter = filter,
            .sort = sort,
            .edit_range = edit_range,
        };
    }

    fn parseDiagnostics(self: *Pool, s: *Server, params: std.json.Value) !?Event {
        if (params != .object) return null;
        const uri = params.object.get("uri") orelse return null;
        if (uri != .string) return null;
        const path = (try uriToPath(self.alloc, uri.string)) orelse return null;
        errdefer self.alloc.free(path);

        var items: std.ArrayList(Diagnostic) = .empty;
        errdefer {
            for (items.items) |*d| d.deinit(self.alloc);
            items.deinit(self.alloc);
        }

        if (params.object.get("diagnostics")) |list| if (list == .array) {
            for (list.array.items) |entry| {
                if (entry != .object) continue;
                const range = parseRange(entry.object.get("range")) orelse continue;
                const message = entry.object.get("message") orelse continue;
                if (message != .string) continue;

                const severity: Severity = if (entry.object.get("severity")) |sv|
                    (if (sv == .integer) Severity.fromWire(sv.integer) else .err)
                else
                    .err;

                // The server's own `source` when it gives one (ruff sends
                // `"ruff"`, zls `"zls"`), else the configured name -- what
                // matters is that a message says which tool it came from.
                const source = if (entry.object.get("source")) |src|
                    (if (src == .string) src.string else s.name)
                else
                    s.name;

                const code: ?[]const u8 = if (entry.object.get("code")) |c| switch (c) {
                    .string => |str| try self.alloc.dupe(u8, str),
                    .integer => |n| try std.fmt.allocPrint(self.alloc, "{d}", .{n}),
                    else => null,
                } else null;
                errdefer if (code) |c| self.alloc.free(c);

                const msg = try self.alloc.dupe(u8, message.string);
                errdefer self.alloc.free(msg);
                const src_owned = try self.alloc.dupe(u8, source);
                errdefer self.alloc.free(src_owned);

                try items.append(self.alloc, .{
                    .range = range,
                    .severity = severity,
                    .message = msg,
                    .source = src_owned,
                    .code = code,
                });
            }
        };

        return .{ .diagnostics = .{
            .path = path,
            .server = s.name,
            .items = try items.toOwnedSlice(self.alloc),
        } };
    }

    /// `hover.contents` has three historical shapes: a `MarkupContent`
    /// object, a `MarkedString` (string or `{language, value}`), and an
    /// array of those. All three are still in the wild, so all three are
    /// read; the text is returned as-is and flattened by the caller.
    fn parseHover(self: *Pool, result: std.json.Value) !?[]const u8 {
        if (result != .object) return null;
        const contents = result.object.get("contents") orelse return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        try self.appendHoverPart(&out, contents);
        if (out.items.len == 0) {
            out.deinit(self.alloc);
            return null;
        }
        return try out.toOwnedSlice(self.alloc);
    }

    fn appendHoverPart(self: *Pool, out: *std.ArrayList(u8), v: std.json.Value) !void {
        switch (v) {
            .string => |s| try out.appendSlice(self.alloc, s),
            .object => |o| {
                if (o.get("value")) |val| if (val == .string) try out.appendSlice(self.alloc, val.string);
            },
            .array => |a| for (a.items) |item| {
                if (out.items.len > 0) try out.appendSlice(self.alloc, "\n\n");
                try self.appendHoverPart(out, item);
            },
            else => {},
        }
    }

    /// `definition` answers a `Location`, a `Location[]`, or a
    /// `LocationLink[]`. The first entry of a list is the one to jump to;
    /// the rest belong to `references`, which is a later slice.
    fn parseDefinition(self: *Pool, result: std.json.Value) !?Location {
        const first: std.json.Value = switch (result) {
            .object => result,
            .array => |a| if (a.items.len == 0) return null else a.items[0],
            else => return null,
        };
        if (first != .object) return null;

        // A `LocationLink` names the file `targetUri` and the range
        // `targetSelectionRange` (the identifier itself) rather than
        // `targetRange` (the whole definition), which is where a jump
        // should land.
        const uri_val = first.object.get("uri") orelse first.object.get("targetUri") orelse return null;
        if (uri_val != .string) return null;
        const range = parseRange(first.object.get("range") orelse
            first.object.get("targetSelectionRange") orelse
            first.object.get("targetRange")) orelse Range{};

        const path = (try uriToPath(self.alloc, uri_val.string)) orelse return null;
        return .{ .path = path, .range = range };
    }
};

fn stringField(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// A snippet (`insertTextFormat: 2`) as the plain text accepting it should
/// insert: every placeholder replaced by its default text, choices by their
/// first option, tab stops and variables dropped, escapes undone.
/// `foo(${1:a}, ${2:b})$0` becomes `foo(a, b)`.
///
/// zoe advertises `snippetSupport: false`, and servers mostly honour it; this
/// is for the ones that send a snippet anyway, where inserting the raw `${1:`
/// syntax into the buffer would be the worst of the options.
pub fn flattenSnippet(alloc: std.mem.Allocator, snippet: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    _ = try flattenInto(alloc, &out, snippet, 0, false);
    return out.toOwnedSlice(alloc);
}

/// Copies `s[i..]` into `out`, flattening as it goes, until the end or --
/// when `nested` -- the `}` that closes the placeholder being read. Returns
/// the index just past what it consumed.
fn flattenInto(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, start: usize, nested: bool) !usize {
    var i = start;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len) {
            try out.append(alloc, s[i + 1]);
            i += 2;
            continue;
        }
        if (nested and c == '}') return i + 1;
        if (c != '$') {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        // `$1`, `$name`: a bare tab stop or variable, which inserts nothing.
        if (i + 1 < s.len and (std.ascii.isAlphanumeric(s[i + 1]) or s[i + 1] == '_')) {
            i += 1;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
            continue;
        }
        if (i + 1 >= s.len or s[i + 1] != '{') {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        // `${...}`: skip the number or name, then `:default}`, `|a,b|}` or
        // just `}`.
        i += 2;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
        if (i >= s.len) break;
        switch (s[i]) {
            ':' => i = try flattenInto(alloc, out, s, i + 1, true),
            '|' => {
                const end = std.mem.indexOfScalarPos(u8, s, i + 1, '|') orelse s.len;
                const first = std.mem.indexOfScalarPos(u8, s[0..end], i + 1, ',') orelse end;
                try out.appendSlice(alloc, s[i + 1 .. first]);
                i = @min(end + 2, s.len); // past `|}`
            },
            '}' => i += 1,
            // Something this doesn't understand (a regex transform on a
            // variable): skip to its closing brace rather than inserting it.
            else => i = if (std.mem.indexOfScalarPos(u8, s, i, '}')) |e| e + 1 else s.len,
        }
    }
    return i;
}

fn parseRange(v: ?std.json.Value) ?Range {
    const val = v orelse return null;
    if (val != .object) return null;
    return .{
        .start = parsePosition(val.object.get("start")) orelse return null,
        .end = parsePosition(val.object.get("end")) orelse return null,
    };
}

fn parsePosition(v: ?std.json.Value) ?Position {
    const val = v orelse return null;
    if (val != .object) return null;
    const line = val.object.get("line") orelse return null;
    const character = val.object.get("character") orelse return null;
    if (line != .integer or character != .integer) return null;
    // A negative coordinate is malformed; clamp rather than refuse the
    // whole diagnostic over it.
    return .{
        .line = @intCast(@max(0, line.integer)),
        .character = @intCast(@max(0, character.integer)),
    };
}
