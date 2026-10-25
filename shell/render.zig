// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-shell's prompt rendering: the default, templated and powerline
//! prefixes, `{cmd}` vars, the right-hand chain, and the input line.
//! `Prompt` methods moved out of main.zig and aliased back.

const std = @import("std");
const glyphwire = @import("glyphwire");
const homepath = @import("applib").homepath;
const lineedit = @import("applib").lineedit;
const config = @import("shell_support").config;
const prompt_template = @import("shell_support").prompt_template;

const main = @import("main.zig");
const Prompt = main.Prompt;
const autocomplete_hint_color = main.autocomplete_hint_color;
const default_cmd_var_timeout_ms = main.default_cmd_var_timeout_ms;
const default_prompt_left = main.default_prompt_left;
const icon_native_px = Prompt.icon_native_px;
const timelib = main.timelib;

/// A powerline segment's colour: a palette slot (`"bright_blue"`), a
/// theme role (`"status_bg"`) -- both follow the window's theme -- or a
/// fixed `#rgb` / `#rrggbb` (the `#` optional). `null` for an unset field
/// or a malformed value.
pub fn plColor(s: ?[]const u8) ?glyphwire.Color {
    const spec = s orelse return null;
    if (glyphwire.theme.slotByName(spec)) |sl| return glyphwire.Color.slot(sl);
    if (glyphwire.theme.roleByName(spec)) |r| return glyphwire.Color.role(r);
    const p = prompt_template.parseColor(spec) orelse return null;
    return .{ .r = p.r, .g = p.g, .b = p.b };
}

/// Works out how a `{icon:...}` should be drawn from the session's cell
/// pixel size (`get_cell_metrics`): natural-scaled, capped to one
/// cell-height so it fills the row without spilling onto the row above
/// or below, and how many columns that makes it (`ceil(h / w)`, ~2 for
/// a square icon in a roughly 1:2 cell). Leaves the fit-in-one-cell
/// default if the metrics request fails.
pub fn resolveIconMetrics(self: *Prompt) void {
    const m = self.client.getCellMetrics() catch return;
    if (m.w == 0 or m.h == 0) return;
    self.icon_max_h = m.h;
    const render_px = @min(icon_native_px, m.h);
    self.icon_cols = @max(1, (render_px + m.w - 1) / m.w);
}

/// Writes the prompt prefix at the cursor's current position and
/// returns where the input line begins, for the caller to record as
/// `line_start_row`/`_col`. Everything is read fresh each time (cwd,
/// exit status, time, ...) so a `cd` or a failed command shows on the
/// very next prompt.
///
/// Three shapes, by `shell.conf.lua`:
///   - nothing configured -> `writeDefaultPrefix` (`<cwd> > `)
///   - `prompt.left` / `prompt.right` strings -> `writeTemplatedPrefix`
///   - `prompt.left_segments` / `right_segments` -> `writePowerlinePrefix`
///
/// Also (re)sets the input-box bounds: `input_max_col` (right edge the
/// typed text may not cross), `input_scroll`, `right_dynamic`,
/// `prompt_lines`.
/// Draws the prompt prefix as a single host frame. With `sink` null
/// each prefix writer opens its own `batch`, appends every draw, and
/// sends it once -- so the prompt appears all at once, not segment by
/// segment. With `sink` non-null the draws are appended to the
/// caller's batch instead (it does the send), letting `handleResize`
/// fold the prefix redraw into the same frame as its clear.
pub fn writePromptPrefix(self: *Prompt, sink: ChainSink) !glyphwire.Cursor {
    self.input_max_col = self.grid_cols;
    self.input_scroll = 0;
    self.right_dynamic = false;
    self.prompt_lines = 1;

    // A brand-new prompt: re-run the `commands` vars. Everything drawn
    // for *this* prompt after here (the idle right-chain refresh, a
    // multi-line redraw) reuses whatever they resolve to now.
    self.resetCmdVars();

    const p = self.promptCfg() orelse return self.writeDefaultPrefix(sink);
    if (p.left_segments != null or p.right_segments != null) return self.writePowerlinePrefix(p, sink);
    if (p.left != null or p.right != null) return self.writeTemplatedPrefix(p, sink);
    return self.writeDefaultPrefix(sink);
}

/// The cursor `w` display-columns past `from`, wrapping at `grid_cols`
/// onto later rows. Locates where input begins after a prefix has been
/// appended to a batch, so no post-draw `getCursor` round trip (which
/// couldn't see the not-yet-sent batch anyway) is needed.
pub fn cursorAfter(self: *Prompt, from: glyphwire.Cursor, w: usize) glyphwire.Cursor {
    if (self.grid_cols == 0) return .{ .row = from.row, .col = from.col + w };
    const abs = from.col + w;
    return .{ .row = from.row + abs / self.grid_cols, .col = abs % self.grid_cols };
}

/// The built-in prompt: the absolute working directory followed by
/// `" > "`. Unchanged from before prompt templating existed.
pub fn writeDefaultPrefix(self: *Prompt, sink: ChainSink) !glyphwire.Cursor {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = self.logicalCwd(&cwd_buf);

    var prefix_buf: [std.fs.max_path_bytes + 4]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s} > ", .{cwd}) catch "> ";

    const start = try self.client.getCursor(.{});

    var local = self.client.batch();
    defer local.deinit();
    const b: *glyphwire.Client.Batch = sink orelse &local;
    try b.setCursor(start.row, start.col, .{});
    try b.writeText(prefix, .{});
    if (sink == null) {
        var res = try local.send();
        res.deinit();
    }

    return self.cursorAfter(start, prompt_template.displayWidth(prefix));
}

/// Stack buffers backing a `prompt_template.Data` snapshot -- the
/// caller holds one of these for the lifetime of the `Data`.
pub const PromptDataBufs = struct {
    cwd: [std.fs.max_path_bytes]u8 = undefined,
    tilde: [std.fs.max_path_bytes]u8 = undefined,
    /// `{cwd}` with its middle cut out, when the prompt doesn't fit.
    short_cwd: [std.fs.max_path_bytes]u8 = undefined,
    time: [64]u8 = undefined,
};

/// The narrowest `shortenCwd` cuts `{cwd}` down to, `…` included: below
/// this it says too little to be worth the space it saves.
const min_cwd_cols = 8;

/// Cuts `over` more columns out of the middle of `data.cwd` (never below
/// `min_cwd_cols`), always working from the uncut `full` so `b.short_cwd`
/// is never read and written at once. False when there is nothing left
/// to cut, which ends the caller's fit loop.
fn shortenCwd(data: *prompt_template.Data, full: []const u8, over: usize, b: *PromptDataBufs) bool {
    const w = prompt_template.displayWidth(data.cwd);
    if (over == 0 or w <= min_cwd_cols) return false;
    const cut = prompt_template.ellipsizeMiddle(full, @max(w -| over, min_cwd_cols), &b.short_cwd);
    if (prompt_template.displayWidth(cut) >= w) return false;
    data.cwd = cut;
    return true;
}

/// How many times a prompt writer re-renders with a shorter `{cwd}`
/// before drawing whatever it has. One pass is enough when `{cwd}`
/// appears once; this only bounds a template that repeats it.
const max_fit_passes = 3;

/// Fills a `prompt_template.Data` from the shell's live state, using
/// `b` for the strings that need somewhere to live.
pub fn buildPromptData(self: *Prompt, b: *PromptDataBufs, p: *const config.PromptConfig) prompt_template.Data {
    const cwd_full = self.logicalCwd(&b.cwd);
    return .{
        .cwd = self.collapseHome(cwd_full, &b.tilde),
        .cwd_full = cwd_full,
        .user = self.environ_map.get("USER") orelse "",
        .host = self.host,
        .remote = self.remoteDest(),
        .time = self.formatTime(&b.time, p.time_format orelse "%H:%M"),
        .environ = &self.env,
        .last_status = self.last_status,
        .have_status = self.have_status,
        .last_dur_ms = self.last_dur_ms,
        .dur_min_ms = self.durMinMs(),
        .exit_section = p.exit,
        .dur_section = p.dur,
        .remote_section = p.remote,
        .vars = self.cmdVarResolver(),
    };
}

/// The `prompt_template.VarResolver` for this prompt's `commands`
/// vars, or `null` when none are configured (so an unknown `{token}`
/// keeps its literal-passthrough behaviour). The `ctx` is the
/// `*Prompt`; `resolveCmdVarThunk` casts it back.
pub fn cmdVarResolver(self: *Prompt) ?prompt_template.VarResolver {
    const p = self.promptCfg() orelse return null;
    if (p.command_vars == null) return null;
    return .{ .ctx = self, .resolve = resolveCmdVarThunk };
}

pub fn resolveCmdVarThunk(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const self: *Prompt = @ptrCast(@alignCast(ctx));
    return self.resolveCmdVar(name);
}

/// Resolves a `{name}` token against `prompt{ commands = { ... } }`.
/// Returns `null` when `name` isn't a declared command var (the
/// template then leaves the token verbatim); otherwise the command's
/// trimmed stdout, or `""` when it was gated off by its `when`,
/// failed, timed out, or hit the cycle/depth guard. Memoised in
/// `cmd_var_cache` for the life of the current prompt.
pub fn resolveCmdVar(self: *Prompt, name: []const u8) ?[]const u8 {
    const p = self.promptCfg() orelse return null;
    const vars = p.command_vars orelse return null;

    const cv: *const config.CommandVar = blk: {
        for (vars) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) break :blk entry;
        }
        return null;
    };

    if (self.cmd_var_cache.get(name)) |cached| return cached;

    // Cycle / runaway-depth guard: a `when` that (transitively)
    // references its own var resolves to empty rather than looping.
    if (self.cmd_var_depth >= self.cmd_var_stack.len) return "";
    for (self.cmd_var_stack[0..self.cmd_var_depth]) |n| {
        if (std.mem.eql(u8, n, name)) return "";
    }
    self.cmd_var_stack[self.cmd_var_depth] = name;
    self.cmd_var_depth += 1;
    defer self.cmd_var_depth -= 1;

    // `runCmdVar` hands back a `client.alloc`-owned slice (or a static
    // "" on failure / empty output); the cache takes it as-is and
    // `resetCmdVars` frees it. The gated-off path stores the same
    // static "".
    const gated_off = if (cv.when) |w| !self.cmdWhenTrue(w) else false;
    const owned: []const u8 = if (gated_off) "" else self.runCmdVar(cv);

    self.cmd_var_cache.put(self.client.alloc, name, owned) catch {};
    return owned;
}

/// Runs `cv.run` through `/bin/sh -c`, synchronously, and returns its
/// trimmed stdout as a fresh `client.alloc` slice -- or `""` on a
/// spawn failure, an exit with no output, or the timeout firing (the
/// child is killed). Exit status is otherwise ignored: `{name}` *is*
/// the command's output, and a `when` clause treats a non-empty
/// output as true.
pub fn runCmdVar(self: *Prompt, cv: *const config.CommandVar) []const u8 {
    const gpa = self.client.alloc;
    const timeout_ms: i64 = @intCast(cv.timeout_ms orelse default_cmd_var_timeout_ms);

    const argv = [_][]const u8{ "/bin/sh", "-c", cv.run };
    const res = std.process.run(gpa, self.client.io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch return "";
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (trimmed.len == 0) return "";
    return gpa.dupe(u8, trimmed) catch "";
}

/// Evaluates a `when` template expression (a segment's `when_expr` or
/// a command var's own `when`) against the command vars: renders it,
/// trims, and reports whether the result is "truthy" -- non-empty and
/// not `0` / `false`. A leading `!` (repeatable) negates. A render
/// failure counts as falsy (before negation).
pub fn cmdWhenTrue(self: *Prompt, expr_in: []const u8) bool {
    var expr = std.mem.trim(u8, expr_in, " \t");
    var negate = false;
    while (expr.len > 0 and expr[0] == '!') {
        negate = !negate;
        expr = std.mem.trim(u8, expr[1..], " \t");
    }

    var arena_state = std.heap.ArenaAllocator.init(self.client.alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const data = prompt_template.Data{
        .environ = &self.env,
        .vars = self.cmdVarResolver(),
    };
    const ops = prompt_template.renderOps(a, expr, data) catch return negate;

    var buf: std.ArrayList(u8) = .empty;
    for (ops) |op| switch (op) {
        .text => |t| buf.appendSlice(a, t) catch return negate,
        .icon => {},
    };
    return prompt_template.whenTruthy(buf.items) != negate;
}

/// Local time formatted per `fmt` (a `strftime` string), into `buf`.
/// Uses libc directly (this reduced std has no time-formatting) and
/// returns "" on any failure.
pub fn formatTime(_: *Prompt, buf: []u8, fmt: []const u8) []const u8 {
    var fmtz: [96]u8 = undefined;
    if (fmt.len == 0 or fmt.len >= fmtz.len) return "";
    @memcpy(fmtz[0..fmt.len], fmt);
    fmtz[fmt.len] = 0;

    const t: c_long = timelib.time(null);
    var tm: timelib.Tm = undefined;
    if (timelib.localtime_r(&t, &tm) == null) return "";
    const n = timelib.strftime(buf.ptr, buf.len, @ptrCast(&fmtz), &tm);
    return buf[0..n];
}

/// Renders the configured `prompt.left` / `prompt.right` template
/// strings (see `shell/prompt_template.zig`). `prompt.right` is drawn
/// right-aligned on the prompt row (a long input line overwrites it --
/// accepted, like starship's transient right prompt); `prompt.left`
/// from column 0. Returns where input begins.
pub fn writeTemplatedPrefix(self: *Prompt, p: *const config.PromptConfig, sink: ChainSink) !glyphwire.Cursor {
    const alloc = self.client.alloc;

    var bufs: PromptDataBufs = .{};
    var data = self.buildPromptData(&bufs, p);

    const start = try self.client.getCursor(.{});

    var local = self.client.batch();
    defer local.deinit();
    const b: *glyphwire.Client.Batch = sink orelse &local;

    var right_w: usize = 0;
    if (p.right) |rt| {
        var r = try prompt_template.render(alloc, rt, data);
        defer r.deinit();
        const w = prompt_template.opsWidth(r.ops, self.icon_cols);
        if (w > 0 and w < self.grid_cols) {
            // `emitOps` positions itself with a leading `setCursor`.
            try self.emitOps(b, r.ops, start.row, self.grid_cols - w, .{});
            right_w = w + 1;
        }
    }

    // The left template has to fit beside the right one, so a long
    // `{cwd}` loses its middle until it does.
    const budget = self.grid_cols -| right_w;
    const full_cwd = data.cwd;
    var l = try prompt_template.render(alloc, p.left orelse default_prompt_left, data);
    defer l.deinit();
    var pass: usize = 0;
    while (pass < max_fit_passes) : (pass += 1) {
        const over = prompt_template.opsWidth(l.ops, self.icon_cols) -| budget;
        if (!shortenCwd(&data, full_cwd, over, &bufs)) break;
        const shorter = try prompt_template.render(alloc, p.left orelse default_prompt_left, data);
        l.deinit();
        l = shorter;
    }
    try self.emitOps(b, l.ops, start.row, 0, .{});

    if (sink == null) {
        var res = try local.send();
        res.deinit();
    }

    // Input begins just past the left template (single row -- templated
    // prompts keep the right prompt on the same line).
    return self.cursorAfter(.{ .row = start.row, .col = 0 }, prompt_template.opsWidth(l.ops, self.icon_cols));
}

pub const RenderedSeg = struct {
    ops: []const prompt_template.Op,
    width: usize,
    fg: ?glyphwire.Color,
    bg: ?glyphwire.Color,
};

/// Renders each *visible* segment of `segs` (dropping `when`-filtered
/// and empty ones) into `out` (allocated in `arena`), returns the
/// summed on-screen width of the segments themselves (separators and
/// caps not included -- see `chainWidth`).
pub fn renderChain(
    self: *Prompt,
    arena: std.mem.Allocator,
    segs: []const config.PromptSegment,
    data: prompt_template.Data,
    out: *std.ArrayList(RenderedSeg),
) !usize {
    var total: usize = 0;
    for (segs) |seg| {
        switch (seg.when) {
            .always => {},
            .err => if (!(data.have_status and data.last_status != 0)) continue,
            .slow => if (!(data.dur_min_ms > 0 and data.last_dur_ms >= data.dur_min_ms)) continue,
        }
        // A `when = "{var}"` expression form -- shown only when the
        // expression renders truthy against the command vars.
        if (seg.when_expr) |we| {
            if (!self.cmdWhenTrue(we)) continue;
        }
        const ops = try prompt_template.renderOps(arena, seg.text, data);
        const w = prompt_template.opsWidth(ops, self.icon_cols);
        if (w == 0) continue;
        try out.append(arena, .{
            .ops = ops,
            .width = w,
            .fg = plColor(seg.fg),
            .bg = plColor(seg.bg),
        });
        total += w;
    }
    return total;
}

/// Total on-screen width of a rendered chain: segment widths (`seg_sum`)
/// plus `count - 1` separators plus the caps that are non-empty.
pub fn chainWidth(count: usize, seg_sum: usize, sep: []const u8, head: []const u8, tail: []const u8) usize {
    if (count == 0) return 0;
    var w = seg_sum + prompt_template.displayWidth(sep) * (count - 1);
    if (head.len > 0) w += prompt_template.displayWidth(head);
    if (tail.len > 0) w += prompt_template.displayWidth(tail);
    return w;
}

/// Draw target for the powerline chain helpers: either straight to the
/// client (`null`) or accumulated into one `batch` frame. `drawRightChain`
/// batches so the periodic redraw of the right chain plus the trailing
/// caret restore land in a single render -- no visible caret blip out
/// to the right side and back.
pub const ChainSink = ?*glyphwire.Client.Batch;

pub fn sinkSetCursor(self: *Prompt, sink: ChainSink, row: usize, col: usize) !void {
    if (sink) |b| try b.setCursor(row, col, .{}) else try self.client.setCursor(row, col, .{});
}

pub fn sinkWriteText(self: *Prompt, sink: ChainSink, text: []const u8, fg: ?glyphwire.Color, bg: ?glyphwire.Color) !void {
    if (sink) |b| try b.writeText(text, .{ .fg = fg, .bg = bg }) else try self.client.writeText(text, .{ .fg = fg, .bg = bg });
}

pub fn sinkWriteTextTransparent(self: *Prompt, sink: ChainSink, text: []const u8, fg: ?glyphwire.Color) !void {
    if (sink) |b| try b.writeText(text, .{ .fg = fg, .transparent_bg = true }) else try self.client.writeText(text, .{ .fg = fg, .transparent_bg = true });
}

pub fn sinkDrawIcon(self: *Prompt, sink: ChainSink, row: usize, col: usize, name: []const u8, opts: glyphwire.Client.DrawIconOpts) !void {
    if (sink) |b| try b.drawIcon(row, col, name, opts) else try self.client.drawIcon(row, col, name, opts);
}

/// Draws a rendered chain left to right starting at `(row, start_col)`:
/// optional `head` cap, then each segment (a background strip, then its
/// text/icons composited over it), with `sep` between adjacent
/// segments, then optional `tail` cap. A separator is drawn in the two
/// neighbours' backgrounds -- for `right_side` chains the fg/bg are
/// swapped so a left-pointing glyph reads correctly. `sink` routes
/// every draw either straight to the client or into a `batch`.
pub fn drawChain(
    self: *Prompt,
    row: usize,
    start_col: usize,
    segs: []const RenderedSeg,
    sep: []const u8,
    head: []const u8,
    tail: []const u8,
    right_side: bool,
    sink: ChainSink,
) !void {
    if (segs.len == 0) return;
    var col = start_col;

    if (head.len > 0) {
        try self.sinkSetCursor(sink, row, col);
        try self.sinkWriteText(sink, head, segs[0].bg, null);
        col += prompt_template.displayWidth(head);
    }

    for (segs, 0..) |seg, i| {
        if (i > 0 and sep.len > 0) {
            const prev = segs[i - 1];
            try self.sinkSetCursor(sink, row, col);
            if (right_side) {
                try self.sinkWriteText(sink, sep, seg.bg, prev.bg);
            } else {
                try self.sinkWriteText(sink, sep, prev.bg, seg.bg);
            }
            col += prompt_template.displayWidth(sep);
        }
        // Background strip, then text/icons composited over it.
        try self.sinkSetCursor(sink, row, col);
        try self.writeSpaces(sink, seg.width, seg.fg, seg.bg);
        try self.emitOps(sink, seg.ops, row, col, .{ .fg = seg.fg, .transparent = true });
        col += seg.width;
    }

    if (tail.len > 0) {
        try self.sinkSetCursor(sink, row, col);
        try self.sinkWriteText(sink, tail, segs[segs.len - 1].bg, null);
    }
}

/// Re-renders and redraws the `right_segments` chain at its pinned
/// position -- called on the idle timeout so `{time}` ticks, and (on a
/// single-line prompt) after every keystroke so it stays put while the
/// input line is repainted. A no-op when no right chain is configured.
///
/// The whole redraw plus a trailing "put the caret back on the input
/// line" go out as one `batch` frame, so the host never renders a
/// frame with the caret stranded out on the right where the chain is
/// drawn -- the "cursor blip to the right" this used to cause.
pub fn drawRightChain(self: *Prompt) !void {
    const rt0: ?std.Io.Timestamp = if (self.profiler.enabled) self.profiler.nowTs() else null;
    defer if (rt0) |s| self.profiler.record(.right_chain, self.profiler.elapsedNs(s));

    const p = self.promptCfg() orelse return;
    const segs = p.right_segments orelse return;

    var arena_state = std.heap.ArenaAllocator.init(self.client.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bufs: PromptDataBufs = .{};
    const data = self.buildPromptData(&bufs, p);

    var list: std.ArrayList(RenderedSeg) = .empty;
    const seg_sum = try self.renderChain(arena, segs, data, &list);
    if (list.items.len == 0) return;

    const sep_right = p.sep_right orelse (p.sep orelse "");
    // `right_head` caps the left edge of the right-aligned chain (the
    // side facing the input). Unset, it falls back to `head` -- the
    // same left-cap glyph the left chain uses -- mirroring how
    // `sep_right` falls back to `sep`. `drawChain` draws it in the
    // first visible segment's bg (red on an error segment, the time's
    // bg otherwise).
    const right_head = p.right_head orelse (p.head orelse "");
    const w = chainWidth(list.items.len, seg_sum, sep_right, right_head, "");
    if (w >= self.grid_cols) return;
    const row = if (self.grid_rows > 0) @min(self.pl_top_row, self.grid_rows - 1) else self.pl_top_row;

    var b = self.client.batch();
    defer b.deinit();
    try self.drawChain(row, self.grid_cols - w, list.items, sep_right, right_head, "", true, &b);
    // Caret restore, same frame -- mirrors `placeInputCursor`. Always
    // the input line: the idle-tick caller gates on `browse_pos == null`
    // and `renderInputLine` only runs for the live line.
    const caret = self.caretCell();
    try b.setCursor(caret.row, caret.col, .{});
    var res = try b.send();
    res.deinit();
    self.profiler.add(.batch_sends, 1);
}

/// The powerline prompt: `left_segments` from column 0, `right_segments`
/// right-aligned, on `prompt_lines`-1 rows above the input line (or all
/// on one row when `prompt_lines == 1`). Returns where input begins.
pub fn writePowerlinePrefix(self: *Prompt, p: *const config.PromptConfig, sink: ChainSink) !glyphwire.Cursor {
    var arena_state = std.heap.ArenaAllocator.init(self.client.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bufs: PromptDataBufs = .{};
    var data = self.buildPromptData(&bufs, p);

    self.prompt_lines = p.lines orelse 1;

    // Every draw below goes into one frame: the caller's batch when
    // `sink` is set, otherwise a batch this function opens and sends.
    var local = self.client.batch();
    defer local.deinit();
    const b: *glyphwire.Client.Batch = sink orelse &local;

    // The prompt needs `prompt_lines` consecutive rows. If the cursor
    // (left where the last command's output ended) is close enough to
    // the bottom that they wouldn't fit, scroll the layer up-front by
    // writing that many newlines at the bottom row -- so every draw
    // below works with an on-grid `top` and the recorded
    // `line_start_row` can't end up one past the last row (which made
    // every later `renderInputLine` / idle refresh scroll again).
    const start = try self.client.getCursor(.{});
    var top = start.row;
    if (self.grid_rows > 0 and top + self.prompt_lines > self.grid_rows) {
        const overshoot = top + self.prompt_lines - self.grid_rows;
        try b.setCursor(self.grid_rows - 1, 0, .{});
        var k: usize = 0;
        while (k < overshoot) : (k += 1) try b.writeText("\n", .{});
        top -= overshoot;
    }
    self.pl_top_row = top;

    const sep = p.sep orelse "";
    const sep_right = p.sep_right orelse sep;
    const head = p.head orelse "";
    const tail = p.tail orelse "";
    // See `drawRightChain`: unset, the right chain's left cap reuses
    // `head`, the same fallback shape as `sep_right` -> `sep`.
    const right_head = p.right_head orelse head;

    const input_prefix = p.input orelse "> ";

    // The right chain is rendered first: its width is what the left one
    // has to fit beside on the top row.
    var right_list: std.ArrayList(RenderedSeg) = .empty;
    var right_w: usize = 0;
    if (p.right_segments) |segs| {
        const seg_sum = try self.renderChain(arena, segs, data, &right_list);
        right_w = chainWidth(right_list.items.len, seg_sum, sep_right, right_head, "");
    }
    const right_shown = right_list.items.len > 0 and right_w < self.grid_cols;

    var left_end: usize = 0;
    if (p.left_segments) |segs| {
        // A `{cwd}` too long for the row loses its middle, so the
        // segments after it (the git branch) stay on screen. On a
        // one-row prompt the input prefix has to fit there too.
        var budget = self.grid_cols -| (if (right_shown) right_w + 1 else 0);
        if (self.prompt_lines < 2) budget -|= prompt_template.displayWidth(input_prefix);
        const full_cwd = data.cwd;
        var list: std.ArrayList(RenderedSeg) = .empty;
        var seg_sum = try self.renderChain(arena, segs, data, &list);
        var pass: usize = 0;
        while (pass < max_fit_passes) : (pass += 1) {
            const over = chainWidth(list.items.len, seg_sum, sep, head, tail) -| budget;
            if (!shortenCwd(&data, full_cwd, over, &bufs)) break;
            list.clearRetainingCapacity();
            seg_sum = try self.renderChain(arena, segs, data, &list);
        }
        try self.drawChain(top, 0, list.items, sep, head, tail, false, b);
        left_end = @min(chainWidth(list.items.len, seg_sum, sep, head, tail), self.grid_cols);
    }

    if (right_shown) {
        self.right_dynamic = true;
        try self.drawChain(top, self.grid_cols - right_w, right_list.items, sep_right, right_head, "", true, b);
    }

    if (self.prompt_lines >= 2) {
        // `top + prompt_lines <= grid_rows` now, so this row is on-grid.
        const irow = top + self.prompt_lines - 1;
        try b.setCursor(irow, 0, .{});
        if (input_prefix.len > 0) try b.writeText(input_prefix, .{});
        self.line_start_row = irow;
        self.line_start_col = prompt_template.displayWidth(input_prefix);
        self.input_max_col = self.grid_cols;
    } else {
        var col = left_end;
        try b.setCursor(top, col, .{});
        if (input_prefix.len > 0) {
            try b.writeText(input_prefix, .{});
            col += prompt_template.displayWidth(input_prefix);
        }
        self.line_start_row = top;
        self.line_start_col = col;
        self.input_max_col = if (self.right_dynamic and right_w + 1 < self.grid_cols)
            self.grid_cols - right_w - 1
        else
            self.grid_cols;
        if (self.input_max_col <= self.line_start_col) self.input_max_col = self.grid_cols;
    }
    self.input_scroll = 0;
    if (sink == null) {
        var res = try local.send();
        res.deinit();
    }
    return .{ .row = self.line_start_row, .col = self.line_start_col };
}

/// Writes `n` spaces at the cursor with the given fg/bg -- the
/// background strip a powerline segment's text then composites over.
pub fn writeSpaces(self: *Prompt, sink: ChainSink, n: usize, fg: ?glyphwire.Color, bg: ?glyphwire.Color) !void {
    var buf: [256]u8 = undefined;
    var left = n;
    while (left > 0) {
        const chunk = @min(left, buf.len);
        @memset(buf[0..chunk], ' ');
        try self.sinkWriteText(sink, buf[0..chunk], fg, bg);
        left -= chunk;
    }
}

pub const EmitOpts = struct { fg: ?glyphwire.Color = null, transparent: bool = false };

/// Walks a rendered template's ops, starting at `(row, col)`. Text runs
/// go through `write_text` (or `write_text` transparent, keeping any
/// background strip) with `opts.fg`; icons through `draw_icon` at the
/// running cell (which `draw_icon` doesn't advance, so the column is
/// bumped by hand).
///
/// Straight-to-client (`sink == null`), text runs resync the cursor
/// from `getCursor` so an embedded `\n` (server CR+LF) needs no local
/// bookkeeping. Batched (`sink != null`), there's no round trip:
/// segment text has no `\n`, so the column is advanced by its display
/// width instead.
///
/// The explicit `setCursor` up front matters: `drawChain` calls this
/// right after `writeSpaces` has left the cursor at the *end* of the
/// segment's background strip, not its start.
pub fn emitOps(self: *Prompt, sink: ChainSink, ops: []const prompt_template.Op, row: usize, col: usize, opts: EmitOpts) !void {
    try self.sinkSetCursor(sink, row, col);
    var cur_row = row;
    var cur_col = col;
    for (ops) |op| switch (op) {
        .text => |t| {
            if (opts.transparent) {
                try self.sinkWriteTextTransparent(sink, t, opts.fg);
            } else {
                try self.sinkWriteText(sink, t, opts.fg, null);
            }
            if (sink == null) {
                const cur = try self.client.getCursor(.{});
                cur_row = cur.row;
                cur_col = cur.col;
            } else {
                cur_col += prompt_template.displayWidth(t);
                try self.sinkSetCursor(sink, cur_row, cur_col);
            }
        },
        .icon => |name| {
            // A `draw_icon` notification for an unregistered name is
            // logged and dropped server-side, not returned as an error.
            // With cell metrics: draw it at its natural size, capped to
            // one cell-height (fills the row, no vertical spill), and
            // step past the `icon_cols` cells it covers. Without them:
            // the old aspect-fit-in-one-cell behavior.
            if (self.icon_max_h > 0) {
                try self.sinkDrawIcon(sink, cur_row, cur_col, name, .{
                    .scale = .natural,
                    .h_align = .start,
                    .v_align = .center,
                    .max_h = self.icon_max_h,
                    .foreground = opts.transparent,
                });
                cur_col += self.icon_cols;
            } else {
                try self.sinkDrawIcon(sink, cur_row, cur_col, name, .{ .foreground = opts.transparent });
                cur_col += 1;
            }
            try self.sinkSetCursor(sink, cur_row, cur_col);
        },
    };
}

/// Returns `path` with a leading `$HOME` replaced by `~` (`~` alone
/// for exactly `$HOME`), written into `buf`. Falls back to `path`
/// unchanged when there's no `$HOME`, it isn't a prefix, or `buf` is
/// too small. The rule itself lives in `logicalpath` so it can be
/// tested without a prompt; this just supplies `$HOME`.
pub fn collapseHome(self: *Prompt, path: []const u8, buf: []u8) []const u8 {
    return homepath.collapseHome(path, self.environ_map.get("HOME"), buf);
}

/// The caret's column offset from the left edge of its input row --
/// the display width of `line` between the row's scroll origin
/// (`input_scroll`, never before the start of the caret's logical line)
/// and the caret (both byte offsets on codepoint boundaries). Byte count
/// and column count only coincide for ASCII; a CJK char is one
/// codepoint, two columns.
pub fn caretCol(self: *Prompt) usize {
    const buf = self.line.text();
    const to = @min(self.line.caret, buf.len);
    const from = @max(@min(self.input_scroll, buf.len), lineedit.lineStartFrom(buf, to));
    if (to <= from) return 0;
    return lineedit.displayCol(buf[from..], to - from);
}

/// What every input row after the first starts with, dimmed -- bash's
/// `PS2`. Those rows begin at column 0 rather than under the first row's
/// text: a long prompt prefix would otherwise leave a pasted JSON body a
/// sliver of the window.
pub const continuation_prefix = "> ";

/// How many grid rows the input occupies: one per logical line of the
/// buffer (see `lineedit.shell_newlines` and Enter's continuation rule).
pub fn inputRowCount(self: *Prompt) usize {
    return std.mem.count(u8, self.line.text(), "\n") + 1;
}

/// The grid row of the input's last logical line -- where the completion
/// picker hangs below, and what a resize or submit must clear through.
pub fn inputBottomRow(self: *Prompt) usize {
    return self.line_start_row + self.inputRowCount() - 1;
}

/// The screen cell the caret is drawn in: its logical line's row, and
/// that row's left edge (`line_start_col` on the first row, past
/// `continuation_prefix` on the rest) plus `caretCol`. Clamped to the
/// last grid row, like every other input-row position.
pub fn caretCell(self: *Prompt) glyphwire.Cursor {
    const idx = lineedit.lineIndexAt(self.line.text(), self.line.caret);
    const row = self.line_start_row + idx;
    const left = if (idx == 0) self.line_start_col else continuation_prefix.len;
    return .{
        .row = if (self.grid_rows > 0) @min(row, self.grid_rows - 1) else row,
        .col = left + self.caretCol(),
    };
}

/// Repaints the whole input box from `line`, then places the server
/// cursor. The first logical line goes in `[line_start_col,
/// input_max_col)` on `line_start_row`; each further one (the buffer can
/// hold `\n`s -- a continued line, a pasted multi-line command) gets a
/// row of its own below, starting with `continuation_prefix`. Only the
/// caret's row scrolls horizontally (`input_scroll`, a byte offset kept
/// on a codepoint boundary and inside that row) to keep the caret
/// visible; the others show their start. Replaces the old per-edit
/// `insert_cells` / `delete_cells` dance: every editing op mutates
/// `buffer`/`cursor` locally and calls this. All width math is in
/// display columns (`lineedit`), so a CJK line lays out right. On a
/// single-line powerline prompt it also redraws the pinned right chain
/// so typing can't disturb it.
pub fn renderInputLine(self: *Prompt) !void {
    const pt0: ?std.Io.Timestamp = if (self.profiler.enabled) self.profiler.nowTs() else null;
    defer if (pt0) |s| self.profiler.record(.prompt_render, self.profiler.elapsedNs(s));

    // Box repaint + caret placement go out as one `batch` frame, so
    // the host never renders an intermediate frame with the caret
    // parked at the box's left edge -- the brief caret "jump" seen on
    // a history recall or line swap otherwise. Same trick as
    // `drawRightChain`.
    var b = self.client.batch();
    defer b.deinit();
    try self.appendInputLine(&b);
    var res = try b.send();
    res.deinit();
    self.profiler.add(.batch_sends, 1);

    // The dynamic right chain is its own `batch` frame (ending with
    // its own caret restore); it only redraws when configured.
    if (self.right_dynamic and self.prompt_lines == 1) self.drawRightChain() catch {};
}

/// Appends the input-box repaint (every input row's visible slice,
/// completion hint, blank fill) and the trailing caret placement to `b`,
/// updating `input_scroll` and `input_rows_drawn` along the way. Split
/// out of `renderInputLine` so `handleResize` can fold the input box into
/// the same frame as its clear + prefix redraw.
pub fn appendInputLine(self: *Prompt, b: *glyphwire.Client.Batch) !void {
    const buf = self.line.text();
    const rows = self.inputRowCount();

    // A line that grew past the grid bottom: scroll the layer up front
    // (`reservePickerRows`' overshoot trick), moving the prompt with it.
    if (self.grid_rows > 0 and self.line_start_row + rows > self.grid_rows) {
        const overshoot = @min(self.line_start_row + rows - self.grid_rows, self.line_start_row);
        if (overshoot > 0) {
            try b.setCursor(self.grid_rows - 1, 0, .{});
            var k: usize = 0;
            while (k < overshoot) : (k += 1) try b.writeText("\n", .{});
            self.line_start_row -= overshoot;
            self.pl_top_row -|= overshoot;
        }
    }

    const caret_line = lineedit.lineIndexAt(buf, self.line.caret);
    var row_start: usize = 0;
    var idx: usize = 0;
    while (idx < rows) : (idx += 1) {
        const row_end = lineedit.lineEndFrom(buf, row_start);
        const screen_row = self.line_start_row + idx;
        if (self.grid_rows > 0 and screen_row >= self.grid_rows) break;

        const left = if (idx == 0) self.line_start_col else continuation_prefix.len;
        const right = if (idx == 0 and self.input_max_col > left + 1) self.input_max_col else self.grid_cols;
        if (idx > 0) {
            try b.setCursor(screen_row, 0, .{});
            try b.writeText(continuation_prefix, .{ .fg = autocomplete_hint_color });
        }
        try appendInputRow(self, b, buf, row_start, row_end, screen_row, left, right, idx == caret_line, idx == rows - 1);
        row_start = row_end + 1;
    }

    // Rows a longer buffer used and this one doesn't (a joined line,
    // a recalled shorter entry).
    if (self.input_rows_drawn > rows) {
        try b.clear(.{ .row = self.line_start_row + rows, .rows = self.input_rows_drawn - rows });
    }
    self.input_rows_drawn = rows;

    const caret = self.caretCell();
    try b.setCursor(caret.row, @min(caret.col, self.grid_cols -| 1), .{});
}

/// One input row of `appendInputLine`: `buf[row_start..row_end]` drawn
/// in `[left, right)` on `screen_row`, scrolled to keep the caret in view
/// when it is the caret's row, with the inline completion hint after it
/// when it is the last row and its end is on screen.
fn appendInputRow(
    self: *Prompt,
    b: *glyphwire.Client.Batch,
    buf: []const u8,
    row_start: usize,
    row_end: usize,
    screen_row: usize,
    left: usize,
    right: usize,
    has_caret: bool,
    is_last: bool,
) !void {
    const box_w = right -| left;
    if (box_w == 0) return;
    const row_text = buf[0..row_end];

    var vis_start = row_start;
    if (has_caret) {
        // Keep the caret within the box, working in columns not bytes.
        if (self.input_scroll < row_start or self.input_scroll > row_end) self.input_scroll = row_start;
        if (self.line.caret < self.input_scroll) {
            self.input_scroll = self.line.caret;
        } else {
            while (self.input_scroll < self.line.caret and
                lineedit.displayCol(row_text[self.input_scroll..], self.line.caret - self.input_scroll) >= box_w)
            {
                self.input_scroll = lineedit.nextBoundary(row_text, self.input_scroll);
            }
        }
        if (lineedit.cellWidth(row_text[row_start..]) <= box_w) self.input_scroll = row_start;
        vis_start = self.input_scroll;
    }

    // Visible slice: whole codepoints from `vis_start` while they fit.
    var vis_end = vis_start;
    var w: usize = 0;
    while (vis_end < row_end) {
        const nb = lineedit.nextBoundary(row_text, vis_end);
        const cw = lineedit.cellWidth(row_text[vis_end..nb]);
        if (w + cw > box_w) break;
        w += cw;
        vis_end = nb;
    }
    const visible = row_text[vis_start..vis_end];

    var hint_end: usize = 0;
    var hint_w: usize = 0;
    if (is_last and self.completion_hint_visible and vis_end == buf.len) {
        const room = box_w -| w;
        const hint = self.completion_hint.items;
        while (hint_end < hint.len) {
            const nb = lineedit.nextBoundary(hint, hint_end);
            const cw = lineedit.cellWidth(hint[hint_end..nb]);
            if (hint_w + cw > room) break;
            hint_w += cw;
            hint_end = nb;
        }
    }

    var spaces: [1024]u8 = undefined;
    const fill_w = box_w -| (w + hint_w);
    const fill = @min(fill_w, spaces.len);
    @memset(spaces[0..fill], ' ');

    try b.setCursor(screen_row, left, .{});
    if (visible.len > 0) try b.writeText(visible, .{});
    if (hint_end > 0) try b.writeText(self.completion_hint.items[0..hint_end], .{ .fg = autocomplete_hint_color });
    if (fill > 0) try b.writeText(spaces[0..fill], .{});
}

/// Puts the server cursor at the caret's screen cell (`caretCell`). Used
/// by the idle right-chain refresh (which moves the cursor while
/// redrawing) and the foreground loop's caret restore.
pub fn placeInputCursor(self: *Prompt) !void {
    const caret = self.caretCell();
    try self.client.setCursor(caret.row, caret.col, .{});
}

/// A fresh prompt: writes the prefix, resets the line, repaints the
/// (empty) input box. Used to start a brand new input line (after
/// `submitLine` or at startup); see `clearScreen` for ctrl+l, which
/// keeps whatever's already typed.
pub fn showPrompt(self: *Prompt) !void {
    // A directory the host asked for lands here, just before the
    // prompt that will show it -- see `applyPendingCd`.
    self.applyPendingCd();
    self.syncPromptTitle();
    const cur = try self.writePromptPrefix(null);
    self.line_start_row = cur.row;
    self.line_start_col = cur.col;
    self.input_rows_drawn = 1;
    self.line.clear();
    // A plain typed invocation of a result-returning program (e.g.
    // `gw-hist` run by hand rather than via its Ctrl+R binding) left
    // its pick here instead of an empty line -- see
    // `pending_result_line`.
    if (self.takePendingResultLine()) |line| {
        defer self.client.alloc.free(line);
        try self.line.setText(self.client.alloc, line);
    }
    self.armCompletionHint();
    try self.renderInputLine();
}
