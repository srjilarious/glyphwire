// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-read's AI request in flight: `ai.Job`, the network half gw-yomi's
//! `ai` module leaves to the app. It sends what gw-yomi builds -- the body
//! (`buildBody`) and headers (`requestHeaders`) over `std.http`, or the
//! `claude` CLI for `claude_code` -- and reads the reply back with
//! `parseAnswer`.
//!
//! **Threading.** `Job.run` is handed to `io.concurrent` by the UI, so
//! the reader keeps drawing while a request is out. The job owns every
//! byte it touches; the UI polls `Job.done` once a tick, and cancels by
//! cancelling the future -- the network reads inside `fetch`, and the
//! pipe reads from a `claude` child, are cancellation points, so an
//! in-flight request stops promptly (and the child is killed).

const std = @import("std");
const ai = @import("gw_yomi").ai;

/// One request in flight. Created by the UI with everything it needs
/// copied in, handed to `io.concurrent(run, .{job})`, polled via `done`,
/// and destroyed by the UI after awaiting or cancelling the future.
pub const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    provider: ai.Provider,
    /// The URL posted to, or the `claude` executable.
    endpoint: []u8,
    model: []u8,
    /// Null for a provider that doesn't authenticate.
    api_key: ?[]u8,
    /// The HTTP body (empty for `claude_code`).
    body: []u8,
    /// Copies of the prompt, for `claude_code`'s command line.
    prompt: ai.Prompt,
    /// Set by `run`, last thing it does; `result` is valid once it reads
    /// true.
    done: std.atomic.Value(bool) = .init(false),
    result: ?ai.Answer = null,

    pub const Options = struct {
        provider: ai.Provider,
        endpoint: []const u8,
        model: []const u8,
        api_key: ?[]const u8 = null,
        prompt: ai.Prompt,
    };

    pub fn create(alloc: std.mem.Allocator, io: std.Io, opts: Options) !*Job {
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        const endpoint = try alloc.dupe(u8, opts.endpoint);
        errdefer alloc.free(endpoint);
        const model = try alloc.dupe(u8, opts.model);
        errdefer alloc.free(model);
        const api_key: ?[]u8 = if (opts.api_key) |k| try alloc.dupe(u8, k) else null;
        errdefer if (api_key) |k| alloc.free(k);
        const body = if (opts.provider == .claude_code)
            try alloc.alloc(u8, 0)
        else
            try ai.buildBody(alloc, opts.provider, opts.model, opts.prompt);
        errdefer alloc.free(body);
        const instructions = try alloc.dupe(u8, opts.prompt.instructions);
        errdefer alloc.free(instructions);
        const user = try alloc.dupe(u8, opts.prompt.user);

        job.* = .{
            .alloc = alloc,
            .io = io,
            .provider = opts.provider,
            .endpoint = endpoint,
            .model = model,
            .api_key = api_key,
            .body = body,
            .prompt = .{ .instructions = instructions, .user = user },
        };
        return job;
    }

    /// Frees the job and anything its result still owns. Only after the
    /// future has been awaited or cancelled -- never while `run` might
    /// still be touching it.
    pub fn destroy(self: *Job) void {
        const alloc = self.alloc;
        if (self.result) |r| r.deinit(alloc);
        alloc.free(self.endpoint);
        alloc.free(self.model);
        if (self.api_key) |k| {
            // The key has no business lingering in freed heap memory.
            std.crypto.secureZero(u8, k);
            alloc.free(k);
        }
        alloc.free(self.body);
        self.prompt.deinit(alloc);
        alloc.destroy(self);
    }

    /// Takes ownership of the result out of a finished job.
    pub fn takeResult(self: *Job) ?ai.Answer {
        const r = self.result;
        self.result = null;
        return r;
    }

    pub fn run(self: *Job) void {
        const answer = switch (self.provider) {
            .claude_code => self.runClaude(),
            else => self.perform(),
        };
        self.result = answer catch |err| failure: {
            const msg = switch (err) {
                error.FileNotFound => std.fmt.allocPrint(self.alloc, "'{s}' was not found on PATH -- is Claude Code installed?", .{self.endpoint}),
                else => std.fmt.allocPrint(self.alloc, "request failed ({t})", .{err}),
            } catch break :failure null;
            break :failure .{ .failure = msg };
        };
        self.done.store(true, .release);
    }

    fn perform(self: *Job) !ai.Answer {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();

        // gw-yomi decides the headers (`requestHeaders`); the one carrying
        // the key goes out privileged, so it's dropped if a redirect ever
        // leaves the host. std.http's own `authorization` is omitted so a
        // bearer token is never sent twice.
        var bearer_buf: [512]u8 = undefined;
        defer std.crypto.secureZero(u8, &bearer_buf);
        var wanted_buf: [3]ai.Header = undefined;
        const wanted = try ai.requestHeaders(self.provider, self.model, self.api_key, &bearer_buf, &wanted_buf);
        var extra_buf: [3]std.http.Header = undefined;
        var privileged_buf: [3]std.http.Header = undefined;
        var extra_len: usize = 0;
        var privileged_len: usize = 0;
        for (wanted) |h| {
            const header: std.http.Header = .{ .name = h.name, .value = h.value };
            if (h.secret) {
                privileged_buf[privileged_len] = header;
                privileged_len += 1;
            } else {
                extra_buf[extra_len] = header;
                extra_len += 1;
            }
        }

        var response: std.Io.Writer.Allocating = .init(self.alloc);
        defer response.deinit();
        const res = try client.fetch(.{
            .location = .{ .url = self.endpoint },
            .method = .POST,
            .payload = self.body,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .omit,
            },
            .extra_headers = extra_buf[0..extra_len],
            .privileged_headers = privileged_buf[0..privileged_len],
            .response_writer = &response.writer,
        });
        return ai.parseAnswer(self.alloc, self.provider, @intFromEnum(res.status), response.written());
    }

    /// `claude_code`: runs the CLI and reads its one JSON result. From
    /// `/`, so a `CLAUDE.md` in whatever directory gw-read was launched
    /// from isn't loaded into a translation request.
    fn runClaude(self: *Job) !ai.Answer {
        var argv_buf: [13][]const u8 = undefined;
        const argv = ai.claudeArgv(&argv_buf, self.endpoint, self.model, self.prompt);
        const res = try std.process.run(self.alloc, self.io, .{
            .argv = argv,
            .cwd = .{ .path = "/" },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer self.alloc.free(res.stdout);
        defer self.alloc.free(res.stderr);

        const code: u8 = switch (res.term) {
            .exited => |c| c,
            else => 255,
        };
        // The CLI reports its own failures (not logged in, usage limit)
        // as a JSON result with `is_error`, often with a non-zero exit --
        // prefer that message, and fall back to stderr only when stdout
        // isn't JSON at all.
        if (std.mem.trim(u8, res.stdout, " \t\r\n").len > 0) {
            return ai.parseAnswer(self.alloc, .claude_code, if (code == 0) 200 else 500, res.stdout);
        }
        const why = std.mem.trim(u8, res.stderr, " \t\r\n");
        return .{ .failure = try std.fmt.allocPrint(self.alloc, "claude exited with status {d}{s}{s}", .{
            code,
            if (why.len > 0) ": " else "",
            why[0..@min(why.len, 400)],
        }) };
    }
};
