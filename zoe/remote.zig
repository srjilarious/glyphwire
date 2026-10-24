// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `zoe <file>` typed into a zoe's own shell panel opens the file in that
//! zoe instead of starting another one -- what VS Code's `code` does from
//! its integrated terminal.
//!
//! Each UI zoe listens on a Unix socket of its own (`Server`) and puts its
//! path in the panel shell's environment as `ZOE_SOCK` (`env_var`), so
//! the shell and everything it runs can find it and nothing else can: a
//! shell in another pane never had the variable. A `zoe` that sees it
//! sends the one file or directory it was given (`forward`) and exits;
//! `--new` skips that, and so does every other kind of start -- bare
//! `zoe`, a workspace, several directories, `--keys`.
//!
//! One request per connection, NUL-separated fields, the client's write
//! side shut down to end it (`encode` / `decode`):
//!
//!     <file|dir> NUL <line, or empty> NUL <0|1 wait> NUL <absolute path>
//!
//! The answer is one line, `ok` or `error: <why>`. With `--wait` the
//! connection then stays open until the file's tab closes (`Document.waiters`)
//! -- the server just closes it, so the client's read hits EOF -- which
//! is what makes `EDITOR='zoe --wait' git commit` work in the panel.
//!
//! The server thread only accepts and reads, then parks the request and
//! wakes the run loop (`InputListener.wake`); opening the file is the main
//! thread's (`Ui.drainRemote`). Everything is close-on-exec, so neither
//! the listening socket nor a waiting client's connection leaks into the
//! panel's shell or a language server -- a leaked copy of the latter
//! would keep `--wait` blocked after its tab closed.

const std = @import("std");
const builtin = @import("builtin");
const glyphwire = @import("glyphwire");
const linux = std.os.linux;

/// The variable the panel's shell inherits: this zoe's socket path.
pub const env_var = "ZOE_SOCK";

pub const Kind = enum { file, dir };

pub const Request = struct {
    kind: Kind,
    /// Absolute: the client resolves it against its own cwd, which is not
    /// the server's.
    path: []const u8,
    /// `--line`, 1-based. Ignored for a directory.
    line: ?usize = null,
    /// `--wait`: hold the connection until the tab closes.
    wait: bool = false,
};

/// The largest request `decode` is ever asked to read: the fixed fields
/// plus a path.
pub const max_request = 64 + std.fs.max_path_bytes;

/// The request's bytes. Caller owns them.
pub fn encode(alloc: std.mem.Allocator, req: Request) ![]u8 {
    var line_buf: [24]u8 = undefined;
    const line = if (req.line) |n| try std.fmt.bufPrint(&line_buf, "{d}", .{n}) else "";
    return std.fmt.allocPrint(alloc, "{t}\x00{s}\x00{s}\x00{s}", .{
        req.kind,
        line,
        if (req.wait) "1" else "0",
        req.path,
    });
}

/// Parses what `encode` wrote. The path is a slice of `bytes`.
pub fn decode(bytes: []const u8) !Request {
    var it = std.mem.splitScalar(u8, bytes, 0);
    const kind_text = it.next() orelse return error.BadRequest;
    const line_text = it.next() orelse return error.BadRequest;
    const wait_text = it.next() orelse return error.BadRequest;
    // The rest is the path: a NUL can't be in one, so there is nothing
    // more to split.
    const path = it.rest();
    const kind = std.meta.stringToEnum(Kind, kind_text) orelse return error.BadRequest;
    const line: ?usize = if (line_text.len == 0)
        null
    else
        std.fmt.parseInt(usize, line_text, 10) catch return error.BadRequest;
    const wait = if (std.mem.eql(u8, wait_text, "1"))
        true
    else if (std.mem.eql(u8, wait_text, "0"))
        false
    else
        return error.BadRequest;
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.BadRequest;
    return .{ .kind = kind, .path = path, .line = line, .wait = wait };
}

/// Sends `text` down a client connection. Best-effort, and never a
/// SIGPIPE: a client that gave up (Ctrl+C on `zoe --wait`) must not take
/// the editor down with it.
pub fn send(fd: i32, text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        const n = linux.sendto(fd, rest.ptr, rest.len, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(n)) {
            .SUCCESS => rest = rest[n..],
            .INTR => continue,
            else => return,
        }
    }
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}

/// A request the thread has read and the run loop has yet to act on.
pub const Pending = struct {
    /// The client's connection. Whoever takes the `Pending` owns it: it
    /// answers, then closes it or hands it to a tab to wait on.
    fd: i32,
    /// `req.path` points into this. Owned.
    bytes: []u8,
    req: Request,

    /// Frees the bytes; the fd is the caller's business.
    pub fn deinit(self: Pending, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

/// `SO_PEERCRED`'s answer, which `std.os.linux` doesn't declare.
const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

pub const Server = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// The socket's path, NUL-terminated for `bind`/`unlink`. Owned.
    path: [:0]u8,
    listen_fd: i32,
    /// An eventfd `stop` writes to, so the thread's `poll` returns.
    stop_fd: i32,
    thread: std.Thread,
    /// Woken when a request is parked. Null in tests, which poll `take`.
    listener: ?*glyphwire.InputListener,
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(Pending) = .empty,

    /// Binds `<dir>/zoe-<pid>.sock` and starts accepting on it. `dir` is
    /// `glyphwire.runtime_dir.runtimeDir`, like the host's own socket, and
    /// the socket is owner-only like the host's. `error.Unsupported` off Linux.
    pub fn start(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, listener: ?*glyphwire.InputListener) !*Server {
        if (builtin.os.tag != .linux) return error.Unsupported;

        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/zoe-{d}.sock", .{ dir, linux.getpid() }, 0);
        errdefer alloc.free(path);
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);

        const sock_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(sock_rc) != .SUCCESS) return error.SocketFailed;
        const listen_fd: i32 = @intCast(sock_rc);
        errdefer _ = linux.close(listen_fd);

        // The name has this pid in it, so one already there is left by
        // a zoe that died without cleaning up and had the same pid.
        _ = linux.unlink(path.ptr);
        if (linux.errno(linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS)
            return error.BindFailed;
        errdefer _ = linux.unlink(path.ptr);
        if (linux.errno(linux.chmod(path.ptr, 0o600)) != .SUCCESS) return error.BindFailed;
        if (linux.errno(linux.listen(listen_fd, 8)) != .SUCCESS) return error.ListenFailed;

        const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC);
        if (linux.errno(efd_rc) != .SUCCESS) return error.EventFdFailed;
        const stop_fd: i32 = @intCast(efd_rc);
        errdefer _ = linux.close(stop_fd);

        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .path = path,
            .listen_fd = listen_fd,
            .stop_fd = stop_fd,
            .thread = undefined,
            .listener = listener,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops the thread, removes the socket, and closes every request
    /// still parked -- their clients see EOF and give up.
    pub fn stop(self: *Server) void {
        const one: u64 = 1;
        _ = linux.write(self.stop_fd, std.mem.asBytes(&one), @sizeOf(u64));
        self.thread.join();
        _ = linux.close(self.listen_fd);
        _ = linux.close(self.stop_fd);
        _ = linux.unlink(self.path.ptr);
        for (self.pending.items) |p| {
            close(p.fd);
            p.deinit(self.alloc);
        }
        self.pending.deinit(self.alloc);
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }

    /// Everything parked since the last call, oldest first. The caller
    /// owns the slice and each `Pending` in it.
    pub fn take(self: *Server) ![]Pending {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pending.toOwnedSlice(self.alloc);
    }

    fn run(self: *Server) void {
        while (true) {
            var fds = [_]linux.pollfd{
                .{ .fd = self.listen_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const rc = linux.poll(&fds, fds.len, -1);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            if (fds[1].revents != 0) return;
            if (fds[0].revents == 0) continue;

            const acc = linux.accept4(self.listen_fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(acc) != .SUCCESS) continue;
            const fd: i32 = @intCast(acc);
            self.serve(fd) catch {
                send(fd, "error: bad request\n");
                close(fd);
            };
        }
    }

    /// Reads one request and parks it. An error leaves `fd` to the caller.
    fn serve(self: *Server, fd: i32) !void {
        // Only this user's processes. The runtime dir is private anyway;
        // `/tmp`, the fallback, is not.
        var cred: Ucred = undefined;
        var cred_len: linux.socklen_t = @sizeOf(Ucred);
        if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred), &cred_len)) != .SUCCESS)
            return error.NoCredentials;
        if (cred.uid != linux.getuid()) return error.ForeignUser;

        // A client that connects and never finishes writing must not
        // wedge this thread for good.
        const timeout: linux.timeval = .{ .sec = 2, .usec = 0 };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));

        const bytes = try self.alloc.alloc(u8, max_request);
        defer self.alloc.free(bytes);
        var len: usize = 0;
        while (true) {
            if (len == bytes.len) return error.TooLong;
            const n = linux.read(fd, bytes[len..].ptr, bytes.len - len);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) break;
                    len += n;
                },
                .INTR => continue,
                else => return error.ReadFailed,
            }
        }
        const owned = try self.alloc.dupe(u8, bytes[0..len]);
        errdefer self.alloc.free(owned);
        const req = try decode(owned);

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.pending.append(self.alloc, .{ .fd = fd, .bytes = owned, .req = req });
        }
        if (self.listener) |l| l.wake();
    }
};

pub const Answer = union(enum) {
    /// The file (or folder) is open in the other zoe -- and, with `wait`,
    /// its tab has since closed.
    opened,
    /// The other zoe refused, with why (a slice of the caller's buffer).
    refused: []const u8,
};

/// Asks the zoe at `sock_path` to open `req`. `error.Unavailable` when
/// nothing answers there -- that zoe has gone -- which is the caller's
/// cue to start one of its own instead.
pub fn forward(alloc: std.mem.Allocator, sock_path: []const u8, req: Request, reply_buf: []u8) !Answer {
    if (builtin.os.tag != .linux) return error.Unavailable;
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (sock_path.len >= addr.path.len) return error.Unavailable;
    @memcpy(addr.path[0..sock_path.len], sock_path);

    const sock_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(sock_rc) != .SUCCESS) return error.Unavailable;
    const fd: i32 = @intCast(sock_rc);
    defer close(fd);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS)
        return error.Unavailable;

    const bytes = try encode(alloc, req);
    defer alloc.free(bytes);
    send(fd, bytes);
    _ = linux.shutdown(fd, linux.SHUT.WR);

    // The one-line answer.
    var len: usize = 0;
    while (len < reply_buf.len) {
        const n = linux.read(fd, reply_buf[len..].ptr, reply_buf.len - len);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) break;
                len += n;
                if (std.mem.indexOfScalar(u8, reply_buf[0..len], '\n') != null) break;
            },
            .INTR => continue,
            else => return error.Unavailable,
        }
    }
    const line = std.mem.trimEnd(u8, reply_buf[0 .. std.mem.indexOfScalar(u8, reply_buf[0..len], '\n') orelse len], "\r");
    // Accepted, then gone before it answered: as good as no one there.
    if (line.len == 0) return error.Unavailable;
    if (!std.mem.eql(u8, line, "ok")) {
        const prefix = "error: ";
        return .{ .refused = if (std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else line };
    }

    // `--wait`: the server closes the connection when the tab does.
    if (req.wait) {
        var sink: [256]u8 = undefined;
        while (true) {
            const n = linux.read(fd, &sink, sink.len);
            switch (linux.errno(n)) {
                .SUCCESS => if (n == 0) break,
                .INTR => continue,
                else => break,
            }
        }
    }
    return .opened;
}
