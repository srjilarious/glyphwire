// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-read's AnkiConnect request in flight: `anki.Job`, the network half
//! gw-yomi's `anki` module leaves to the app. It posts what gw-yomi builds
//! (`buildAddNote`, `buildAction`), reads the reply with `parseReply`, and
//! asks JapanesePod101 whether a word has a clip.

const std = @import("std");
const anki = @import("gw_yomi").anki;

/// One request in flight, the same ownership rules as `ai.Job`: created
/// with everything copied in, run by `io.concurrent`, polled through
/// `done`, destroyed by the UI only after awaiting or cancelling it.
pub const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    kind: Kind,
    url: []u8,
    /// The `addNote` body; empty for a probe.
    body: []u8,
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,

    pub const Kind = union(enum) {
        /// HEAD the audio URL to learn whether the word has a clip.
        probe,
        /// POST `body` to AnkiConnect, then a `sync` when asked.
        add: struct { sync: bool },
    };

    pub const Result = union(enum) {
        audio: anki.AudioState,
        added: struct { note_id: i64, sync_failure: ?[]u8 = null },
        /// Owned: why the note wasn't added.
        failure: []u8,

        pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
            switch (self) {
                .audio => {},
                .added => |a| if (a.sync_failure) |f| alloc.free(f),
                .failure => |f| alloc.free(f),
            }
        }
    };

    pub fn create(alloc: std.mem.Allocator, io: std.Io, kind: Kind, url: []const u8, body: []const u8) !*Job {
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        const url_copy = try alloc.dupe(u8, url);
        errdefer alloc.free(url_copy);
        job.* = .{ .alloc = alloc, .io = io, .kind = kind, .url = url_copy, .body = try alloc.dupe(u8, body) };
        return job;
    }

    pub fn destroy(self: *Job) void {
        const alloc = self.alloc;
        if (self.result) |r| r.deinit(alloc);
        alloc.free(self.url);
        alloc.free(self.body);
        alloc.destroy(self);
    }

    pub fn takeResult(self: *Job) ?Result {
        const r = self.result;
        self.result = null;
        return r;
    }

    pub fn run(self: *Job) void {
        self.result = switch (self.kind) {
            .probe => .{ .audio = self.probe() },
            .add => |a| self.add(a.sync) catch |err| failure: {
                const msg = switch (err) {
                    error.ConnectionRefused => std.fmt.allocPrint(self.alloc, "couldn't reach AnkiConnect at {s} -- is Anki running with the AnkiConnect add-on?", .{self.url}),
                    else => std.fmt.allocPrint(self.alloc, "request to AnkiConnect failed ({t})", .{err}),
                } catch break :failure null;
                break :failure .{ .failure = msg };
            },
        };
        self.done.store(true, .release);
    }

    /// JapanesePod101 redirects a word it has a clip for to the clip, and
    /// answers 200 with its placeholder otherwise -- so a HEAD without
    /// following redirects is the whole question. Anything else (another
    /// source, a network error) stays `unknown` and the clip is attached
    /// anyway.
    ///
    /// Asked over plain HTTP: `assets.languagepod101.com` is an old
    /// Apache whose TLS 1.2 handshake Zig's std TLS client can't complete
    /// (`TlsInitializationFailed`), while its HTTP side gives the same
    /// 301-or-200 answer. Only the status is read, and the clip itself is
    /// still downloaded by Anki from the `https` URL.
    fn probe(self: *Job) anki.AudioState {
        if (!anki.isJpodUrl(self.url)) return .unknown;
        const https = "https://";
        const probe_url = if (std.mem.startsWith(u8, self.url, https))
            std.fmt.allocPrint(self.alloc, "http://{s}", .{self.url[https.len..]}) catch return .unknown
        else
            self.alloc.dupe(u8, self.url) catch return .unknown;
        defer self.alloc.free(probe_url);

        // Not `client.fetch`: for a HEAD it drains the body through
        // `Reader.ending`, a `const` that lands in read-only memory, and
        // `discardRemaining` writes to it -- a segfault in ReleaseSafe.
        // `receiveHead` returns a HEAD response before touching any body
        // reader, and the status is all that's needed.
        const uri = std.Uri.parse(probe_url) catch return .unknown;
        var client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();
        var req = client.request(.HEAD, uri, .{ .redirect_behavior = .unhandled }) catch return .unknown;
        defer req.deinit();
        req.sendBodiless() catch return .unknown;
        const res = req.receiveHead(&.{}) catch return .unknown;
        return switch (res.head.status.class()) {
            .redirect => .available,
            .success => .missing,
            else => .unknown,
        };
    }

    fn add(self: *Job, sync: bool) !Result {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();

        const reply = try self.post(&client, self.body);
        const note_id = switch (reply) {
            .failure => |f| return .{ .failure = f },
            .ok => |id| id,
        };
        if (!sync) return .{ .added = .{ .note_id = note_id } };

        const sync_body = try anki.buildAction(self.alloc, "sync");
        defer self.alloc.free(sync_body);
        const sync_reply = self.post(&client, sync_body) catch |err|
            return .{ .added = .{ .note_id = note_id, .sync_failure = try std.fmt.allocPrint(self.alloc, "{t}", .{err}) } };
        return .{ .added = .{ .note_id = note_id, .sync_failure = switch (sync_reply) {
            .failure => |f| f,
            .ok => null,
        } } };
    }

    fn post(self: *Job, client: *std.http.Client, body: []const u8) !anki.Reply {
        var response: std.Io.Writer.Allocating = .init(self.alloc);
        defer response.deinit();
        const res = try client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response.writer,
        });
        return anki.parseReply(self.alloc, @intFromEnum(res.status), response.written());
    }
};
