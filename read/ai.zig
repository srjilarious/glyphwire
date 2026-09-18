// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! AI translation lookup for a whole OCR bubble: prompt construction,
//! the per-provider request/response JSON, and the background job that
//! does the round trip.
//!
//! **What gets sent.** OCR text only -- the current bubble, optionally
//! its neighbours in reading order, the highlighted word when there is
//! one, and (only when `ai_include_book_info` is set) the book's file
//! name and page number. Never an image, never a path.
//!
//! **Providers.** Three speak HTTP -- OpenAI's Responses API,
//! Anthropic's Messages API, Ollama's `/api/chat` -- and differ only in
//! the JSON body they want (`buildBody`), where the answer sits in the
//! JSON they return (`parseAnswer`) and how they authenticate
//! (`Provider.needsKey`, `Job.perform`). The fourth, `claude_code`, runs
//! the `claude` CLI headless instead (`claude -p`), so it answers on the
//! user's own Claude Code login rather than on API credits.
//!
//! **Threading.** `Job.run` is handed to `io.concurrent` by the UI, so
//! the reader keeps drawing while a request is out. The job owns every
//! byte it touches; the UI polls `Job.done` once a tick, and cancels by
//! cancelling the future -- the network reads inside `fetch`, and the
//! pipe reads from a `claude` child, are cancellation points, so an
//! in-flight request stops promptly (and the child is killed).
//!
//! Split into `read_support` so `tests/read_tests.zig` can cover the
//! prompt and the JSON on both sides without a network.

const std = @import("std");

pub const Provider = enum {
    openai,
    anthropic,
    claude_code,
    ollama,

    pub fn parse(text: []const u8) ?Provider {
        if (std.mem.eql(u8, text, "openai")) return .openai;
        if (std.mem.eql(u8, text, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, text, "claude_code") or std.mem.eql(u8, text, "claude-code")) return .claude_code;
        if (std.mem.eql(u8, text, "ollama")) return .ollama;
        return null;
    }

    /// For the confirm/sending panels: who the text is going to.
    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .openai => "OpenAI",
            .anthropic => "Anthropic",
            .claude_code => "Claude Code",
            .ollama => "Ollama",
        };
    }

    pub fn defaultModel(self: Provider) []const u8 {
        return switch (self) {
            .openai => "gpt-5",
            .anthropic, .claude_code => "claude-opus-5",
            // Qwen handles Japanese far better than most local models of
            // its size; a user with something else pulled sets `ai_model`.
            .ollama => "qwen2.5",
        };
    }

    /// The URL posted to -- or, for `claude_code`, the executable run
    /// (looked up on PATH).
    pub fn defaultEndpoint(self: Provider) []const u8 {
        return switch (self) {
            .openai => "https://api.openai.com/v1/responses",
            .anthropic => "https://api.anthropic.com/v1/messages",
            .claude_code => "claude",
            .ollama => "http://localhost:11434/api/chat",
        };
    }

    /// The environment variable the key is read from when
    /// `ai_api_key_env` isn't set.
    pub fn defaultKeyEnv(self: Provider) []const u8 {
        return switch (self) {
            .openai => "OPENAI_API_KEY",
            .anthropic => "ANTHROPIC_API_KEY",
            .claude_code, .ollama => "",
        };
    }

    /// Whether a send without an API key is pointless. Ollama is local
    /// and unauthenticated; the `claude` CLI brings its own login.
    pub fn needsKey(self: Provider) bool {
        return self == .openai or self == .anthropic;
    }
};

/// Anthropic's `max_tokens`: generous, since hitting the cap truncates
/// the answer mid-sentence, and the panel scrolls anyway.
const anthropic_max_tokens = 16000;

/// Whether an Anthropic request for `model` carries `fallbacks:
/// "default"` -- a declined request is re-run server-side on the model
/// Anthropic recommends for that refusal category rather than coming
/// back empty. Only the models that publish fallback models accept it;
/// on any other the parameter is a 400.
fn anthropicFallbacks(model: []const u8) bool {
    return std.mem.eql(u8, model, "claude-opus-5") or std.mem.startsWith(u8, model, "claude-fable-5");
}

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

/// The request body for an HTTP `provider`. `claude_code` has none -- it
/// takes the prompt on its command line (`claudeArgv`).
pub fn buildBody(alloc: std.mem.Allocator, provider: Provider, model: []const u8, prompt: Prompt) ![]u8 {
    return switch (provider) {
        // Responses API: `instructions` is the developer message and
        // `input` may be a bare string for a single user turn.
        .openai => std.json.Stringify.valueAlloc(alloc, .{
            .model = model,
            .instructions = prompt.instructions,
            .input = prompt.user,
        }, .{}),
        // Messages API: the instructions are the top-level `system`.
        .anthropic => if (anthropicFallbacks(model))
            std.json.Stringify.valueAlloc(alloc, .{
                .model = model,
                .max_tokens = anthropic_max_tokens,
                .system = prompt.instructions,
                .messages = .{.{ .role = "user", .content = prompt.user }},
                .fallbacks = "default",
            }, .{})
        else
            std.json.Stringify.valueAlloc(alloc, .{
                .model = model,
                .max_tokens = anthropic_max_tokens,
                .system = prompt.instructions,
                .messages = .{.{ .role = "user", .content = prompt.user }},
            }, .{}),
        .claude_code => error.NotAnHttpProvider,
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
    // Not for `claude_code`: its "status" is only an exit code, and the
    // CLI's own message (`is_error` + `result`) says far more than it.
    if (provider != .claude_code and (status < 200 or status >= 300))
        return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d}", .{status}) };

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
        // `content` is a list of blocks; the answer is every `text` block
        // in order. Thinking blocks (Opus 5 thinks by default) and a
        // `fallback` marker are skipped. A policy decline comes back as
        // HTTP 200 with `stop_reason: "refusal"` and must be checked
        // before `content` is trusted.
        .anthropic => {
            if (root.object.get("stop_reason")) |sr| {
                if (sr == .string and std.mem.eql(u8, sr.string, "refusal"))
                    return .{ .failure = try alloc.dupe(u8, "Claude declined to answer this one") };
            }
            const content = root.object.get("content") orelse return noText(alloc);
            if (content != .array) return noText(alloc);
            for (content.array.items) |block| {
                if (block != .object) continue;
                const kind = block.object.get("type") orelse continue;
                if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
                const text = block.object.get("text") orelse continue;
                if (text == .string) try out.writer.writeAll(text.string);
            }
        },
        // `claude -p --output-format json`: one result object, the answer
        // in `result`, `is_error` set when the CLI itself failed (not
        // logged in, usage limit) -- `result` then says why.
        .claude_code => {
            const result = root.object.get("result") orelse return noText(alloc);
            if (result != .string) return noText(alloc);
            if (root.object.get("is_error")) |e| {
                if (e == .bool and e.bool) return .{ .failure = try alloc.dupe(u8, result.string) };
            }
            try out.writer.writeAll(result.string);
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

/// The `claude` CLI's command line for `claude_code`. Headless (`-p`),
/// one JSON result object on stdout, no session saved, no tools (a
/// translation needs none, and a tool-less run can't touch the disk), and
/// the app's own instructions *replacing* Claude Code's system prompt.
/// The user message is the last, positional argument. Deliberately not
/// `--bare`: that mode only accepts an API key, and the point of this
/// provider is the user's Claude Code login. Slices borrow from the
/// arguments.
pub fn claudeArgv(buf: *[13][]const u8, exe: []const u8, model: []const u8, prompt: Prompt) []const []const u8 {
    buf.* = .{
        exe,
        "-p",
        "--output-format",
        "json",
        "--no-session-persistence",
        // Variadic: an empty list disables every built-in tool. The next
        // flag ends it.
        "--tools",
        "",
        "--model",
        model,
        "--system-prompt",
        prompt.instructions,
        "--",
        prompt.user,
    };
    return buf;
}

/// One request in flight. Created by the UI with everything it needs
/// copied in, handed to `io.concurrent(run, .{job})`, polled via `done`,
/// and destroyed by the UI after awaiting or cancelling the future.
pub const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    /// The URL posted to, or the `claude` executable.
    endpoint: []u8,
    model: []u8,
    /// Null for a provider that doesn't authenticate.
    api_key: ?[]u8,
    /// The HTTP body (empty for `claude_code`).
    body: []u8,
    /// Copies of the prompt, for `claude_code`'s command line.
    prompt: Prompt,
    /// Set by `run`, last thing it does; `result` is valid once it reads
    /// true.
    done: std.atomic.Value(bool) = .init(false),
    result: ?Answer = null,

    pub const Options = struct {
        provider: Provider,
        endpoint: []const u8,
        model: []const u8,
        api_key: ?[]const u8 = null,
        prompt: Prompt,
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
            try buildBody(alloc, opts.provider, opts.model, opts.prompt);
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
    pub fn takeResult(self: *Job) ?Answer {
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

    fn perform(self: *Job) !Answer {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();

        var auth_buf: [512]u8 = undefined;
        defer std.crypto.secureZero(u8, &auth_buf);
        var headers: std.http.Client.Request.Headers = .{ .content_type = .{ .override = "application/json" } };
        // Anthropic authenticates with its own header rather than a
        // bearer token, and wants the API version pinned.
        var anthropic_headers: [2]std.http.Header = undefined;
        var extra: []const std.http.Header = &.{};
        var privileged: []const std.http.Header = &.{};
        const fallback_beta = [_]std.http.Header{.{ .name = "anthropic-beta", .value = "server-side-fallback-2026-07-01" }};
        if (self.provider == .anthropic) {
            extra = &[_]std.http.Header{.{ .name = "anthropic-version", .value = "2023-06-01" }};
            if (anthropicFallbacks(self.model)) {
                anthropic_headers = .{ extra[0], fallback_beta[0] };
                extra = &anthropic_headers;
            }
        }
        var key_header: [1]std.http.Header = undefined;
        if (self.api_key) |k| switch (self.provider) {
            .anthropic => {
                // Privileged: dropped if a redirect ever leaves the host.
                key_header = .{.{ .name = "x-api-key", .value = k }};
                privileged = &key_header;
            },
            else => {
                const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{k}) catch return error.ApiKeyTooLong;
                headers.authorization = .{ .override = auth };
            },
        };

        var response: std.Io.Writer.Allocating = .init(self.alloc);
        defer response.deinit();
        const res = try client.fetch(.{
            .location = .{ .url = self.endpoint },
            .method = .POST,
            .payload = self.body,
            .headers = headers,
            .extra_headers = extra,
            .privileged_headers = privileged,
            .response_writer = &response.writer,
        });
        return parseAnswer(self.alloc, self.provider, @intFromEnum(res.status), response.written());
    }

    /// `claude_code`: runs the CLI and reads its one JSON result. From
    /// `/`, so a `CLAUDE.md` in whatever directory gw-read was launched
    /// from isn't loaded into a translation request.
    fn runClaude(self: *Job) !Answer {
        var argv_buf: [13][]const u8 = undefined;
        const argv = claudeArgv(&argv_buf, self.endpoint, self.model, self.prompt);
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
            return parseAnswer(self.alloc, .claude_code, if (code == 0) 200 else 500, res.stdout);
        }
        const why = std.mem.trim(u8, res.stderr, " \t\r\n");
        return .{ .failure = try std.fmt.allocPrint(self.alloc, "claude exited with status {d}{s}{s}", .{
            code,
            if (why.len > 0) ": " else "",
            why[0..@min(why.len, 400)],
        }) };
    }
};
