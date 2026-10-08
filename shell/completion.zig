// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-shell's Tab completion: candidate collection and sorting, the
//! fish-style inline hint, and the interactive picker drawn under the
//! prompt. `Prompt` methods moved out of main.zig and aliased back.

const std = @import("std");
const glyphwire = @import("glyphwire");
const wordsplit = @import("applib").wordsplit;
const complete = @import("shell_support").complete;
const ListCursor = @import("applib").listcursor.ListCursor;

const main = @import("main.zig");
const Prompt = main.Prompt;
const autocomplete_hint_color = main.autocomplete_hint_color;
const autocomplete_idle_ms = main.autocomplete_idle_ms;
const core_builtin_names = main.core_builtin_names;

/// Where a completion candidate came from -- drives both the `/` vs ` `
/// terminator (only `.dir` gets `/`) and the dimmed `[tag]` the
/// interactive picker shows next to each row (`completionSourceTag`), a
/// hook for a later completion source (git branches, flags, ...) to
/// identify itself the same way.
pub const CompletionSource = enum { file, dir, alias, builtin, script };

pub fn completionSourceTag(source: CompletionSource) []const u8 {
    return switch (source) {
        .file => "file",
        .dir => "dir",
        .alias => "alias",
        .builtin => "builtin",
        .script => "script",
    };
}

/// One filename offered by Tab completion -- `name` is the raw directory
/// entry (no trailing slash); `source` drives the `/` vs ` ` suffix on a
/// unique match and the picker's metadata tag.
pub const CompletionCandidate = struct { name: []const u8, source: CompletionSource };

/// Live state for the interactive Tab-completion dropdown (see
/// `Prompt.recomputeAndDrawPicker`). The candidate list itself is never
/// cached here -- every redraw rescans via `collectCompletionCandidates`
/// from the current buffer/cursor, so typing narrows the list for free
/// and there's no stale-cache case to handle. `list` indexes into that
/// freshly-scanned list; `drawn_rows` is how many rows are currently
/// painted below the input line, so a redraw knows how much to clear
/// first and whether the screen still needs scrolling to make room.
pub const CompletionPickerState = struct {
    list: ListCursor = .{},
    drawn_rows: usize = 0,
};

/// Any real prompt edit or cursor move invalidates the displayed
/// inline completion. The next idle tick recomputes it from the new
/// buffer/cursor state.
pub fn armCompletionHint(self: *Prompt) void {
    self.completion_hint_visible = false;
    self.completion_hint_dirty = true;
    self.completion_hint_activity_at = std.Io.Clock.Timestamp.now(self.client.io, .awake);
}

pub fn hideCompletionHint(self: *Prompt) void {
    self.completion_hint_visible = false;
    self.completion_hint_dirty = false;
    self.completion_hint.clearRetainingCapacity();
}

/// Tab: filename completion for the word under the cursor. Reads the
/// directory named by the word's leading `dir/` part (cwd if none;
/// `~`/`~/` expanded), keeps entries whose name starts with the
/// word's final segment, and:
///
///   * 0 matches       -> nothing;
///   * exactly 1 match -> fills it in and appends `/` (a directory) or
///                        a space (anything else);
///   * >1 matches with a longer shared prefix -> extends the word to
///                        that common prefix (bash's first-Tab behaviour);
///   * >1 matches, nothing more to share -> opens the interactive
///                        completion picker (see `recomputeAndDrawPicker`)
///                        instead of bash's flat printed list.
///
/// Dot-files are skipped unless the typed prefix itself starts with a
/// dot, matching every shell. Quoting inside the word isn't
/// interpreted -- see `complete.wordRange`.
pub fn doComplete(self: *Prompt) !void {
    const alloc = self.client.alloc;

    const line = self.line.text();
    const wr = complete.wordRange(line, self.line.caret);
    const word = line[wr.start..self.line.caret];
    const dp = complete.dirPrefix(word);

    var cands: std.ArrayList(CompletionCandidate) = .empty;
    defer {
        for (cands.items) |cand| alloc.free(cand.name);
        cands.deinit(alloc);
    }
    try self.collectCompletionCandidates(&cands, line, wr, dp);
    if (cands.items.len == 0) return;

    if (cands.items.len == 1) {
        const only = cands.items[0];
        const escaped = try wordsplit.escapeSpecial(alloc, only.name[dp.prefix.len..]);
        defer alloc.free(escaped);
        try self.insertText(escaped);
        try self.insertText(if (only.source == .dir) "/" else " ");
        return;
    }

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (cands.items) |cand| try names.append(alloc, cand.name);
    const lcp = complete.commonPrefixLen(names.items);

    if (lcp > dp.prefix.len) {
        const escaped = try wordsplit.escapeSpecial(alloc, cands.items[0].name[dp.prefix.len..lcp]);
        defer alloc.free(escaped);
        try self.insertText(escaped);
        return;
    }

    try self.recomputeAndDrawPicker(0);
}

/// Appends the command-position names matching `prefix` to `cands`
/// (which already holds the cwd filesystem matches): the `alias`
/// bindings, the core builtins (`core_builtin_names`), and the script
/// builtins (`ScriptEngine.collectCommandNames` -- `defcmd` names plus
/// `~/.config/glyphwire/scripts/*.lua`). A name already in `cands`
/// (from the directory scan or an earlier source here) is skipped, so
/// a script and a like-named file are offered once. `doComplete` sorts
/// the merged list.
pub fn appendCommandNameCandidates(
    self: *Prompt,
    cands: *std.ArrayList(CompletionCandidate),
    prefix: []const u8,
) !void {
    const alloc = self.client.alloc;

    const push = struct {
        fn f(a: std.mem.Allocator, list: *std.ArrayList(CompletionCandidate), name: []const u8, source: CompletionSource) !void {
            for (list.items) |cand| {
                if (std.mem.eql(u8, cand.name, name)) return;
            }
            try list.append(a, .{ .name = try a.dupe(u8, name), .source = source });
        }
    }.f;

    for (core_builtin_names) |name| {
        if (std.mem.startsWith(u8, name, prefix)) try push(alloc, cands, name, .builtin);
    }

    var ai = self.aliases.map.keyIterator();
    while (ai.next()) |key| {
        if (std.mem.startsWith(u8, key.*, prefix)) try push(alloc, cands, key.*, .alias);
    }

    if (self.script_engine) |eng| {
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        try eng.collectCommandNames(alloc, prefix, &names);
        for (names.items) |n| try push(alloc, cands, n, .script);
    }
}

/// Gathers the same sorted candidate set used by Tab completion. The
/// inline hint path calls this too, so a dim suggestion agrees with
/// what pressing Tab would consider completions for the current word.
pub fn collectCompletionCandidates(
    self: *Prompt,
    cands: *std.ArrayList(CompletionCandidate),
    line: []const u8,
    wr: complete.WordRange,
    dp: complete.DirPrefix,
) !void {
    const alloc = self.client.alloc;
    const io = self.client.io;

    const scan_dir = try self.completionDir(dp.dir);
    defer alloc.free(scan_dir);

    const matches = try complete.scanDir(alloc, io, scan_dir, dp.prefix);
    defer complete.freeMatches(alloc, matches);
    for (matches) |m| {
        try cands.append(alloc, .{
            .name = try alloc.dupe(u8, m.name),
            .source = if (m.is_dir) .dir else .file,
        });
    }

    // In command position (`argv[0]`, no `dir/` part) completion also
    // offers the names the plain directory scan can't see: aliases,
    // core builtins, and script builtins.
    if (dp.dir.len == 0 and std.mem.indexOfNone(u8, line[0..wr.start], " \t") == null)
        try self.appendCommandNameCandidates(cands, dp.prefix);

    sortCompletionCandidates(cands.items);
}

pub fn sortCompletionCandidates(cands: []CompletionCandidate) void {
    std.mem.sort(CompletionCandidate, cands, {}, struct {
        fn lessThan(_: void, a: CompletionCandidate, b: CompletionCandidate) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

/// On an idle tick, compute and draw the first completion candidate as
/// dimmed text after the caret. Returns true when it repainted the
/// input row, letting the caller skip a redundant idle redraw.
pub fn maybeShowCompletionHint(self: *Prompt) !bool {
    if (!self.completion_hint_dirty or self.completion_hint_visible) return false;
    if (self.browse_pos != null or self.pending_resize != null) return false;
    if (self.completion_picker != null) return false;
    const active_at = self.completion_hint_activity_at orelse return false;
    if (active_at.untilNow(self.client.io).raw.toMilliseconds() < autocomplete_idle_ms) return false;

    const line = self.line.text();
    if (self.line.caret != line.len) return false;

    const wr = complete.wordRange(line, self.line.caret);
    if (wr.end != self.line.caret) return false;

    const word = line[wr.start..self.line.caret];
    if (word.len == 0) return false;

    self.completion_hint_dirty = false;
    self.completion_hint.clearRetainingCapacity();

    const dp = complete.dirPrefix(word);
    var cands: std.ArrayList(CompletionCandidate) = .empty;
    defer {
        for (cands.items) |cand| self.client.alloc.free(cand.name);
        cands.deinit(self.client.alloc);
    }
    try self.collectCompletionCandidates(&cands, line, wr, dp);
    if (cands.items.len == 0) return false;

    const first = cands.items[0];
    const suffix = (try complete.candidateSuffix(self.client.alloc, dp.prefix, first.name, first.source == .dir)) orelse return false;
    defer self.client.alloc.free(suffix);
    if (suffix.len == 0) return false;

    try self.completion_hint.appendSlice(self.client.alloc, suffix);
    self.completion_hint_visible = true;
    try self.renderInputLine();
    return true;
}

/// Right arrow at the end of the input accepts the visible inline
/// hint. If no hint has been drawn yet, use the same completion path
/// as Tab so Right-at-end is still a completion gesture.
pub fn acceptCompletionHintOrComplete(self: *Prompt) !void {
    if (self.line.caret != self.line.text().len or self.line.text().len == 0) return;
    if (self.completion_hint_visible and self.completion_hint.items.len > 0) {
        try self.insertText(self.completion_hint.items);
        return;
    }
    try self.doComplete();
}

/// Resolves the `dir/` portion of a completion word to a path
/// `openDir` can take: an owned copy of `"."` when there's no
/// directory part, otherwise the part itself with `~`/`~/` expanded.
/// Always returns an owned string for the caller to free.
pub fn completionDir(self: *Prompt, dir_part: []const u8) ![]const u8 {
    const alloc = self.client.alloc;
    if (dir_part.len == 0) return alloc.dupe(u8, ".");
    const expanded = self.expandTilde(dir_part) catch return alloc.dupe(u8, dir_part);
    if (expanded.ptr == dir_part.ptr) return alloc.dupe(u8, dir_part);
    return expanded; // expandTilde already returned an owned allocation
}

/// The interactive Tab-completion dropdown: recomputes the candidate
/// list from the *current* buffer/cursor (never cached -- see
/// `CompletionPickerState`), then either resolves it away (0 or, on a
/// fresh recompute, exactly 1 match) or (re)draws up to
/// `completionMaxItems()` dimmed rows below the input line, one of
/// them highlighted as the current selection.
///
/// `move_delta` is 0 for "the buffer changed, re-filter in place"
/// (called from `doComplete`'s first open and from every edit while
/// open -- `insertText`/`deleteBackward`/... via
/// `refreshCompletionPickerIfOpen`) and +-1 for "Up/Down/Tab moved the
/// selection" (`moveCompletionPicker`), which skips the single-match
/// auto-accept (the candidate count can't have changed from pure
/// navigation) and wraps the selection instead of resetting it.
pub fn recomputeAndDrawPicker(self: *Prompt, move_delta: isize) anyerror!void {
    const alloc = self.client.alloc;

    const line = self.line.text();
    const wr = complete.wordRange(line, self.line.caret);
    const word = line[wr.start..self.line.caret];
    const dp = complete.dirPrefix(word);

    var cands: std.ArrayList(CompletionCandidate) = .empty;
    defer {
        for (cands.items) |cand| alloc.free(cand.name);
        cands.deinit(alloc);
    }
    try self.collectCompletionCandidates(&cands, line, wr, dp);

    if (cands.items.len == 0) {
        try self.closeCompletionPicker();
        return;
    }
    if (move_delta == 0 and cands.items.len == 1) {
        const only = cands.items[0];
        try self.closeCompletionPicker();
        const escaped = try wordsplit.escapeSpecial(alloc, only.name[dp.prefix.len..]);
        defer alloc.free(escaped);
        try self.insertText(escaped);
        try self.insertText(if (only.source == .dir) "/" else " ");
        return;
    }

    if (self.completion_picker == null) self.completion_picker = .{};
    var st = self.completion_picker.?;

    const max_items = self.completionMaxItems();
    const visible = @min(max_items, cands.items.len);

    if (move_delta == 0) {
        st.list.reset();
    } else {
        st.list.step(move_delta, cands.items.len, .wrap);
    }
    st.list.follow(visible);

    if (st.drawn_rows == 0) try self.reservePickerRows(visible);

    var b = self.client.batch();
    defer b.deinit();
    try self.batchClear(&b, self.line_start_row + 1, 0, @max(st.drawn_rows, visible), self.grid_cols);

    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const idx = st.list.top + i;
        const cand = cands.items[idx];
        const selected = idx == st.list.selected;
        const dim: ?glyphwire.Color = if (selected) null else autocomplete_hint_color;

        try self.batchSetCursor(&b, self.line_start_row + 1 + i, 0);
        try self.batchText(&b, if (selected) "> " else "  ", dim, null);
        try self.batchText(&b, cand.name, dim, null);
        if (cand.source == .dir) try self.batchText(&b, "/", dim, null);
        try self.batchText(&b, "  [", autocomplete_hint_color, null);
        try self.batchText(&b, completionSourceTag(cand.source), autocomplete_hint_color, null);
        try self.batchText(&b, "]", autocomplete_hint_color, null);
    }

    try self.appendInputLine(&b); // restores the caret to the live line
    var res = try b.send();
    res.deinit();

    st.drawn_rows = visible;
    self.completion_picker = st;
}

/// Reserves `rows_needed` grid rows below the input line for the
/// picker's first draw, scrolling the layer up-front (same trick as
/// `writePowerlinePrefix`'s overshoot) if the input line is close
/// enough to the bottom that they wouldn't otherwise fit.
pub fn reservePickerRows(self: *Prompt, rows_needed: usize) !void {
    if (self.grid_rows == 0 or rows_needed == 0) return;
    const need_bottom = self.line_start_row + rows_needed;
    if (need_bottom < self.grid_rows) return;

    const overshoot = need_bottom - self.grid_rows + 1;
    var b = self.client.batch();
    defer b.deinit();
    try self.batchSetCursor(&b, self.grid_rows - 1, 0);
    var k: usize = 0;
    while (k < overshoot) : (k += 1) try self.batchText(&b, "\n", null, null);
    var res = try b.send();
    res.deinit();
    self.line_start_row -= overshoot;
}

/// Up/Down (or Tab, to cycle) while the picker is open: wraps the
/// selection by `delta` and redraws. A no-op if the picker isn't open
/// (callers already gate on that, but this stays safe to call bare).
pub fn moveCompletionPicker(self: *Prompt, delta: isize) !void {
    if (self.completion_picker == null) return;
    try self.recomputeAndDrawPicker(delta);
}

/// Buffer changed (typed a character, backspaced, ...) while the
/// picker is open: re-filter in place. A no-op if it isn't open.
pub fn refreshCompletionPickerIfOpen(self: *Prompt) !void {
    if (self.completion_picker != null) try self.recomputeAndDrawPicker(0);
}

/// Enter while the picker is open: completes the word with the
/// highlighted candidate (same suffix + terminator insertion as a
/// single-match Tab) and closes the picker, without submitting the
/// line.
pub fn acceptCompletionPicker(self: *Prompt) !void {
    const st = self.completion_picker orelse return;
    const alloc = self.client.alloc;

    const line = self.line.text();
    const wr = complete.wordRange(line, self.line.caret);
    const word = line[wr.start..self.line.caret];
    const dp = complete.dirPrefix(word);

    var cands: std.ArrayList(CompletionCandidate) = .empty;
    defer {
        for (cands.items) |cand| alloc.free(cand.name);
        cands.deinit(alloc);
    }
    try self.collectCompletionCandidates(&cands, line, wr, dp);

    try self.closeCompletionPicker();
    if (st.list.selected >= cands.items.len) return; // stale -- nothing sane to accept

    const chosen = cands.items[st.list.selected];
    const escaped = try wordsplit.escapeSpecial(alloc, chosen.name[dp.prefix.len..]);
    defer alloc.free(escaped);
    try self.insertText(escaped);
    try self.insertText(if (chosen.source == .dir) "/" else " ");
}

/// Escape, an explicit cursor move, or the candidate list narrowing to
/// nothing all close the picker: clears its drawn rows and repaints
/// the input line + caret in their place, in one batch frame.
pub fn closeCompletionPicker(self: *Prompt) !void {
    const st = self.completion_picker orelse return;
    self.completion_picker = null;
    if (st.drawn_rows == 0) return;

    var b = self.client.batch();
    defer b.deinit();
    try self.batchClear(&b, self.line_start_row + 1, 0, st.drawn_rows, self.grid_cols);
    try self.appendInputLine(&b);
    var res = try b.send();
    res.deinit();
}
