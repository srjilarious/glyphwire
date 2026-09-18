// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! AI translation lookup for a whole OCR bubble: prompt construction,
//! the per-provider request/response JSON, and the background job that
//! does the HTTP round trip.
//!
//! **What gets sent.** OCR text only -- the current bubble, optionally
//! its neighbours in reading order, the highlighted word when there is
//! one, and (only when `ai_include_book_info` is set) the book's file
//! name and page number. Never an image, never a path.
//!
//! **Providers.** A provider is only three things: the JSON body it
//! wants (`buildBody`), where the answer sits in the JSON it returns
//! (`parseAnswer`), and how it authenticates (`Provider.needsKey`).
//! OpenAI's Responses API and Ollama's `/api/chat` are the two today;
//! another is a new enum tag plus a case in each of those switches.
//!
//! **Threading.** `Job.run` is handed to `io.concurrent` by the UI, so
//! the reader keeps drawing while a request is out. The job owns every
//! byte it touches; the UI polls `Job.done` once a tick, and cancels by
//! cancelling the future -- the network reads inside `fetch` are
//! cancellation points, so an in-flight request stops promptly.
//!
//! Split into `read_support` so `tests/read_tests.zig` can cover the
//! prompt and the JSON on both sides without a network.

const std = @import("std");

pub const Provider = enum {
    openai,
    ollama,

    pub fn parse(text: []const u8) ?Provider {
        if (std.mem.eql(u8, text, "openai")) return .openai;
        if (std.mem.eql(u8, text, "ollama")) return .ollama;
        return null;
    }

    /// For the confirm/sending panels: who the text is going to.
    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .openai => "OpenAI",
            .ollama => "Ollama",
        };
    }

    pub fn defaultModel(self: Provider) []const u8 {
        return switch (self) {
            .openai => "gpt-5",
            // Qwen handles Japanese far better than most local models of
            // its size; a user with something else pulled sets `ai_model`.
            .ollama => "qwen2.5",
        };
    }

    pub fn defaultEndpoint(self: Provider) []const u8 {
        return switch (self) {
            .openai => "https://api.openai.com/v1/responses",
            .ollama => "http://localhost:11434/api/chat",
        };
    }

    /// Whether a send without an API key is pointless. Ollama is local
    /// and unauthenticated.
    pub fn needsKey(self: Provider) bool {
        return self == .openai;
    }
};

/// `ai_prompt`'s default: the reading-level/style instruction a user
/// replaces with their own.
pub const default_style =
    "Translate this for an intermediate (around JLPT N3) Japanese learner. " ++
    "Keep the explanations brief.";

/// The fixed half of the instructions, before the user's style. This is
/// the response contract: the answer is drawn into a small character-cell
/// panel, so anything but short plain text reads badly.
pub const app_rules =
    "You help someone read a Japanese manga. You are given the OCR text of one speech bubble, " ++
    "sometimes with the bubbles before and after it for context. " ++
    "Give a natural English translation of the current bubble first, then brief notes on any " ++
    "words or grammar a learner might miss. If a highlighted word is given, explain it in this " ++
    "context. The text comes from OCR and may contain recognition errors; if something looks " ++
    "garbled, say what it most likely says. " ++
    "Answer in short plain text: no markdown tables, headings, bold or bullet symbols, and no " ++
    "romanization unless asked.";

pub const PromptInput = struct {
    dialog: []const u8,
    highlight: ?[]const u8 = null,
    previous: ?[]const u8 = null,
    next: ?[]const u8 = null,
    /// The book's name -- a file name, never a path.
    title: ?[]const u8 = null,
    /// 1-based, as the reader shows it.
    page: ?usize = null,
};

/// The book's name as the prompt (and the cache's `title` column) gives
/// it: the last path component, never the path, with a comic-archive
/// extension dropped. Only the archive extensions -- a directory named
/// `Vol 1.5` keeps its `.5`.
pub fn bookTitle(path: []const u8) []const u8 {
    const base = std.fs.path.basename(std.mem.trimEnd(u8, path, "/"));
    const ext = std.fs.path.extension(base);
    const archives = [_][]const u8{ ".cbz", ".cbr", ".cb7", ".zip", ".rar", ".7z" };
    for (archives) |a| {
        if (std.ascii.eqlIgnoreCase(ext, a)) return base[0 .. base.len - ext.len];
    }
    return base;
}

pub const Prompt = struct {
    /// The developer/system message: `app_rules` then the user's style.
    instructions: []u8,
    /// The user message: the bubble text, labelled.
    user: []u8,

    pub fn deinit(self: Prompt, alloc: std.mem.Allocator) void {
        alloc.free(self.instructions);
        alloc.free(self.user);
    }
};

/// Builds the two messages a request carries. Every piece is labelled
/// so the model can tell the bubble it is asked about from its context.
pub fn buildPrompt(alloc: std.mem.Allocator, style: []const u8, in: PromptInput) !Prompt {
    const instructions = if (style.len > 0)
        try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ app_rules, style })
    else
        try alloc.dupe(u8, app_rules);
    errdefer alloc.free(instructions);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    if (in.title) |t| {
        try w.print("Book: {s}", .{t});
        if (in.page) |p| try w.print(", page {d}", .{p});
        try w.writeAll("\n");
    } else if (in.page) |p| {
        try w.print("Page {d}\n", .{p});
    }
    if (in.previous) |p| try w.print("Previous bubble: {s}\n", .{p});
    try w.print("Current bubble: {s}\n", .{in.dialog});
    if (in.next) |n| try w.print("Next bubble: {s}\n", .{n});
    if (in.highlight) |h| try w.print("Highlighted: {s}\n", .{h});

    return .{ .instructions = instructions, .user = try out.toOwnedSlice() };
}

/// The request body for `provider`.
pub fn buildBody(alloc: std.mem.Allocator, provider: Provider, model: []const u8, prompt: Prompt) ![]u8 {
    return switch (provider) {
        // Responses API: `instructions` is the developer message and
        // `input` may be a bare string for a single user turn.
        .openai => std.json.Stringify.valueAlloc(alloc, .{
            .model = model,
            .instructions = prompt.instructions,
            .input = prompt.user,
        }, .{}),
        .ollama => std.json.Stringify.valueAlloc(alloc, .{
            .model = model,
            .stream = false,
            .messages = .{
                .{ .role = "system", .content = prompt.instructions },
                .{ .role = "user", .content = prompt.user },
            },
        }, .{}),
    };
}

/// How a job ended. Both payloads are owned.
pub const Answer = union(enum) {
    text: []u8,
    /// Shown in the panel as-is: an HTTP status, a provider's own error
    /// message, or a transport error name.
    failure: []u8,

    pub fn deinit(self: Answer, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |s| alloc.free(s),
        }
    }
};

/// Pulls the answer (or the provider's error message) out of a response
/// body. `status` decides which one is expected, but an error object is
/// honoured whatever the status says.
pub fn parseAnswer(alloc: std.mem.Allocator, provider: Provider, status: u16, body: []const u8) !Answer {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d}: response was not JSON", .{status}) };
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d}: unexpected response", .{status}) };

    if (errorMessage(root)) |msg| return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d}: {s}", .{ status, msg }) };
    if (status < 200 or status >= 300) return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d}", .{status}) };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    switch (provider) {
        // `output` is a list of items; the answer is every `output_text`
        // part of every `message` item, in order. (`output_text` at the
        // top level is an SDK convenience, not part of the wire format.)
        .openai => {
            const output = root.object.get("output") orelse return noText(alloc);
            if (output != .array) return noText(alloc);
            for (output.array.items) |item| {
                if (item != .object) continue;
                const content = item.object.get("content") orelse continue;
                if (content != .array) continue;
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    const kind = part.object.get("type") orelse continue;
                    if (kind != .string or !std.mem.eql(u8, kind.string, "output_text")) continue;
                    const text = part.object.get("text") orelse continue;
                    if (text == .string) try out.writer.writeAll(text.string);
                }
            }
        },
        .ollama => {
            const message = root.object.get("message") orelse return noText(alloc);
            if (message != .object) return noText(alloc);
            const content = message.object.get("content") orelse return noText(alloc);
            if (content == .string) try out.writer.writeAll(stripThink(content.string));
        },
    }
    const text = std.mem.trim(u8, out.written(), " \t\r\n");
    if (text.len == 0) return noText(alloc);
    return .{ .text = try alloc.dupe(u8, text) };
}

fn noText(alloc: std.mem.Allocator) !Answer {
    return .{ .failure = try alloc.dupe(u8, "the response had no answer text") };
}

/// OpenAI: `{"error": {"message": ...}}`. Ollama: `{"error": "..."}`.
fn errorMessage(root: std.json.Value) ?[]const u8 {
    const err = root.object.get("error") orelse return null;
    return switch (err) {
        .string => |s| s,
        .object => |o| if (o.get("message")) |m| (if (m == .string) m.string else "error") else "error",
        else => null,
    };
}

/// A local reasoning model (deepseek-r1, qwq) puts its chain of thought
/// in a leading `<think>...</think>` block. That is not the answer.
fn stripThink(text: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "<think>")) return text;
    const end = std.mem.find(u8, trimmed, "</think>") orelse return text;
    return trimmed[end + "</think>".len ..];
}

/// Makes answer text safe for a character-cell panel: markdown emphasis
/// markers and heading hashes the model sent despite being asked not to
/// are dropped, and runs of blank lines collapse to one. Returned slice
/// is owned.
pub fn plainText(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var blank_run: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, " \t\r");
        const lead = std.mem.trimStart(u8, line, "#");
        if (lead.len != line.len and (lead.len == 0 or lead[0] == ' ')) line = std.mem.trimStart(u8, lead, " ");
        if (line.len == 0) {
            blank_run += 1;
            if (blank_run > 1) continue;
        } else blank_run = 0;
        if (!first) try out.append(alloc, '\n');
        first = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] == '*' or line[i] == '`') continue;
            try out.append(alloc, line[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// One request in flight. Created by the UI with everything owned,
/// handed to `io.concurrent(run, .{job})`, polled via `done`, and
/// destroyed by the UI after awaiting or cancelling the future.
pub const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    url: []u8,
    /// Null for a provider that doesn't authenticate.
    api_key: ?[]u8,
    body: []u8,
    /// Set by `run`, last thing it does; `result` is valid once it reads
    /// true.
    done: std.atomic.Value(bool) = .init(false),
    result: ?Answer = null,

    pub fn create(
        alloc: std.mem.Allocator,
        io: std.Io,
        provider: Provider,
        url: []const u8,
        api_key: ?[]const u8,
        body: []u8,
    ) !*Job {
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        const url_copy = try alloc.dupe(u8, url);
        errdefer alloc.free(url_copy);
        const key_copy: ?[]u8 = if (api_key) |k| try alloc.dupe(u8, k) else null;
        job.* = .{
            .alloc = alloc,
            .io = io,
            .provider = provider,
            .url = url_copy,
            .api_key = key_copy,
            .body = body,
        };
        return job;
    }

    /// Frees the job and anything its result still owns. Only after the
    /// future has been awaited or cancelled -- never while `run` might
    /// still be touching it.
    pub fn destroy(self: *Job) void {
        const alloc = self.alloc;
        if (self.result) |r| r.deinit(alloc);
        alloc.free(self.url);
        if (self.api_key) |k| {
            // The key has no business lingering in freed heap memory.
            std.crypto.secureZero(u8, k);
            alloc.free(k);
        }
        alloc.free(self.body);
        alloc.destroy(self);
    }

    /// Takes ownership of the result out of a finished job.
    pub fn takeResult(self: *Job) ?Answer {
        const r = self.result;
        self.result = null;
        return r;
    }

    pub fn run(self: *Job) void {
        self.result = self.perform() catch |err| failure: {
            const msg = std.fmt.allocPrint(self.alloc, "request failed ({t})", .{err}) catch break :failure null;
            break :failure .{ .failure = msg };
        };
        self.done.store(true, .release);
    }

    fn perform(self: *Job) !Answer {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();

        var auth_buf: [512]u8 = undefined;
        var headers: std.http.Client.Request.Headers = .{ .content_type = .{ .override = "application/json" } };
        if (self.api_key) |k| {
            const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{k}) catch return error.ApiKeyTooLong;
            headers.authorization = .{ .override = auth };
        }
        defer std.crypto.secureZero(u8, &auth_buf);

        var response: std.Io.Writer.Allocating = .init(self.alloc);
        defer response.deinit();
        const res = try client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = self.body,
            .headers = headers,
            .response_writer = &response.writer,
        });
        return parseAnswer(self.alloc, self.provider, @intFromEnum(res.status), response.written());
    }
};
