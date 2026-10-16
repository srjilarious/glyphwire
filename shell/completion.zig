// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-shell's Tab completion: candidate collection and sorting, the
//! fish-style inline hint (history autosuggestion first), and the
//! interactive picker drawn under the prompt. `Prompt` methods moved out
//! of main.zig and aliased back.
//!
//! Where candidates come from, by what is being completed (see
//! `gatherCandidates`):
//!
//!   * the command name -- builtins, aliases, script builtins, every
//!     executable on `$PATH`, and directories (to walk into a path);
//!   * an argument of a command with a `defcomplete` -- that Lua
//!     function's list, nothing else;
//!   * any other argument -- fish's completions for it when fish is
//!     installed (`prompt{ fish_completions }`): subcommands, flags with
//!     their descriptions, branches, and fish's own file matching;
//!   * a redirect target, or whatever the above left empty -- the files
//!     in the directory the word names. That includes a word fish
//!     answered for but none of whose entries extend it
//!     (`git worktree remove bui<Tab>`, where fish only lists worktrees).
//!
//! The word under the caret is read with the shell's own quoting rules
//! (`compctx.scan`), so `cat 'My Fi<Tab>` completes inside the quote and
//! closes it.

const std = @import("std");
const glyphwire = @import("glyphwire");
const wordsplit = @import("applib").wordsplit;
const lineedit = @import("applib").lineedit;
const complete = @import("shell_support").complete;
const compctx = @import("shell_support").compctx;
const ScriptEngine = @import("shell_support").script_engine.ScriptEngine;
const ListCursor = @import("applib").listcursor.ListCursor;

const main = @import("main.zig");
const Prompt = main.Prompt;
const autocomplete_hint_color = main.autocomplete_hint_color;
const autocomplete_idle_ms = main.autocomplete_idle_ms;
const core_builtin_names = main.core_builtin_names;

/// How long Tab waits on fish before giving up on it (and falling back to
/// file names). fish answers in ~100 ms; this only bounds a wedged one.
const fish_timeout_ms: i64 = 1500;

/// Where a completion candidate came from -- drives both the terminator
/// (only `.dir` gets `/`) and the dimmed `[tag]` the interactive picker
/// shows next to a row that has no description.
pub const CompletionSource = enum {
    file,
    dir,
    alias,
    builtin,
    script,
    /// An executable found on `$PATH`.
    command,
    /// An argument fish or a `defcomplete` function offered: a
    /// subcommand, a flag, a branch name.
    arg,
};

pub fn completionSourceTag(source: CompletionSource) []const u8 {
    return switch (source) {
        .file => "file",
        .dir => "dir",
        .alias => "alias",
        .builtin => "builtin",
        .script => "script",
        .command => "cmd",
        .arg => "arg",
    };
}

/// One candidate offered by Tab completion.
pub const CompletionCandidate = struct {
    /// What the picker shows and what is matched against
    /// `Candidates.prefix`: a directory entry's name for a directory
    /// scan, a whole word otherwise (a command, a fish or Lua argument,
    /// a path fish completed). Never ends in `/`; `source == .dir` says
    /// one goes after it. Owned.
    name: []const u8,
    source: CompletionSource,
    /// The picker's second column (fish's or a `defcomplete` entry's
    /// description). Owned; empty for none.
    desc: []const u8 = "",
};

/// The candidates for the word under the caret, with what they extend.
pub const Candidates = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(CompletionCandidate) = .empty,
    ctx: compctx.Context,
    /// The typed text every `name` starts with: the word's final path
    /// segment for a directory scan, the whole word otherwise. Points into
    /// `ctx.word`. What gets inserted is a name's rest past this.
    prefix: []const u8 = "",

    pub fn deinit(self: *Candidates) void {
        for (self.items.items) |c| {
            self.alloc.free(c.name);
            self.alloc.free(c.desc);
        }
        self.items.deinit(self.alloc);
        self.ctx.deinit(self.alloc);
    }

    /// Appends a candidate (duping `name` and `desc`), skipping a name
    /// already present -- a script and a like-named file, an alias and
    /// the `$PATH` command it wraps, are offered once, the first source
    /// winning. `seen` holds the names appended so far.
    fn push(
        self: *Candidates,
        seen: *std.StringHashMapUnmanaged(void),
        name: []const u8,
        source: CompletionSource,
        desc: []const u8,
    ) !void {
        if (seen.contains(name)) return;
        // Room in both first, so nothing can fail once the list owns the
        // strings.
        try self.items.ensureUnusedCapacity(self.alloc, 1);
        try seen.ensureUnusedCapacity(self.alloc, 1);
        const name_owned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(name_owned);
        const desc_owned = try self.alloc.dupe(u8, desc);
        self.items.appendAssumeCapacity(.{ .name = name_owned, .source = source, .desc = desc_owned });
        seen.putAssumeCapacity(name_owned, {});
    }
};

/// Whether a lookup may start a process or call into Lua: yes for Tab and
/// the picker, no for the idle inline hint, which must stay instant and
/// side-effect free (it reuses fish's cached answer if there is one).
pub const Lookup = enum { interactive, idle };

/// Live state for the interactive Tab-completion dropdown (see
/// `Prompt.recomputeAndDrawPicker`). The candidate list itself is never
/// cached here -- every redraw rescans via `gatherCandidates` from the
/// current buffer/cursor, so typing narrows the list for free and
/// there's no stale-cache case to handle. `list` indexes into that
/// freshly-scanned list; `drawn_rows` is how many rows are currently
/// painted below the input, so a redraw knows how much to clear first
/// and whether the screen still needs scrolling to make room.
pub const CompletionPickerState = struct {
    list: ListCursor = .{},
    drawn_rows: usize = 0,
};

/// fish's last answer, kept so narrowing the picker as you type (and the
/// idle hint) filter it locally instead of asking fish again: `key` is
/// the exact query fish was given, `output` its raw stdout, and `items`
/// slices into `output`. Cleared after every command (`submitLine`),
/// since cwd, branches and files may all have changed.
pub const FishCache = struct {
    key: []u8 = "",
    output: []u8 = "",
    items: []compctx.FishItem = &.{},

    pub fn clear(self: *FishCache, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.output);
        alloc.free(self.items);
        self.* = .{};
    }
};

/// Every executable on `$PATH`, sorted and unique, for command-name
/// completion. Rebuilt lazily when `$PATH` changes or after a command ran
/// (`stale`, set by `submitLine` -- the command may have installed one).
pub const PathCommands = struct {
    names: std.ArrayList([]const u8) = .empty,
    /// The `$PATH` the list was built from. Owned.
    path: []u8 = "",
    stale: bool = true,

    pub fn deinit(self: *PathCommands, alloc: std.mem.Allocator) void {
        for (self.names.items) |n| alloc.free(n);
        self.names.deinit(alloc);
        alloc.free(self.path);
        self.* = .{};
    }
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

/// Tab: completes the word under the caret from `gatherCandidates`
/// (a showing inline hint is taken whole first, as Right does -- see the
/// key handler):
///
///   * 0 matches       -> nothing;
///   * exactly 1 match -> fills it in and appends `/` (a directory) or
///                        the closing quote and a space (anything else);
///   * >1 matches with a longer shared prefix -> extends the word to
///                        that common prefix (bash's first-Tab behaviour);
///   * >1 matches, nothing more to share -> opens the interactive
///                        completion picker (see `recomputeAndDrawPicker`)
///                        instead of bash's flat printed list.
///
/// Dot-files are skipped unless the typed prefix itself starts with a
/// dot, matching every shell.
pub fn doComplete(self: *Prompt) !void {
    var set = try self.gatherCandidates(.interactive);
    defer set.deinit();
    if (set.items.items.len == 0) return;

    if (set.items.items.len == 1) {
        try self.insertCandidate(&set, set.items.items[0]);
        return;
    }

    const alloc = self.client.alloc;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (set.items.items) |cand| try names.append(alloc, cand.name);
    const lcp = complete.commonPrefixLen(names.items);

    if (lcp > set.prefix.len) {
        const escaped = try compctx.escapeInsert(alloc, set.items.items[0].name[set.prefix.len..lcp], set.ctx.open_quote);
        defer alloc.free(escaped);
        try self.insertText(escaped);
        return;
    }

    try self.recomputeAndDrawPicker(0);
}

/// The bytes accepting `cand` inserts at the caret: the rest of its name
/// past `set.prefix`, escaped for the quote open there, then the
/// terminator -- `/` after a directory (any quote stays open, the path
/// goes on), nothing after a name ending in `=` (`--color=`), otherwise
/// the closing quote if one is open and a space. Shared by Tab, the
/// picker and the inline hint, so the hint shows exactly what Tab would
/// type. Caller owns the result.
pub fn insertionFor(alloc: std.mem.Allocator, set: *const Candidates, cand: CompletionCandidate) ![]u8 {
    const rest = try compctx.escapeInsert(alloc, cand.name[set.prefix.len..], set.ctx.open_quote);
    defer alloc.free(rest);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, rest);
    if (cand.source == .dir) {
        try out.append(alloc, '/');
    } else if (!std.mem.endsWith(u8, cand.name, "=")) {
        if (set.ctx.open_quote != 0) try out.append(alloc, set.ctx.open_quote);
        try out.append(alloc, ' ');
    }
    return out.toOwnedSlice(alloc);
}

pub fn insertCandidate(self: *Prompt, set: *const Candidates, cand: CompletionCandidate) !void {
    const text = try insertionFor(self.client.alloc, set, cand);
    defer self.client.alloc.free(text);
    try self.insertText(text);
}

/// Appends the command-position names matching `prefix` to `set`: the
/// core builtins (`core_builtin_names`), the `alias` bindings, and the
/// script builtins (`ScriptEngine.collectCommandNames` -- `defcmd` names
/// plus `~/.config/glyphwire/scripts/*.lua`). The `$PATH` executables
/// and directories follow in `gatherCandidates`.
pub fn appendCommandNameCandidates(
    self: *Prompt,
    set: *Candidates,
    seen: *std.StringHashMapUnmanaged(void),
    prefix: []const u8,
) !void {
    const alloc = self.client.alloc;

    for (core_builtin_names) |name| {
        if (std.mem.startsWith(u8, name, prefix)) try set.push(seen, name, .builtin, "");
    }

    var ai = self.aliases.map.keyIterator();
    while (ai.next()) |key| {
        if (std.mem.startsWith(u8, key.*, prefix)) try set.push(seen, key.*, .alias, "");
    }

    if (self.script_engine) |eng| {
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        try eng.collectCommandNames(alloc, prefix, &names);
        for (names.items) |n| try set.push(seen, n, .script, "");
    }

    for (try self.pathCommands()) |name| {
        if (std.mem.startsWith(u8, name, prefix)) try set.push(seen, name, .command, "");
    }
}

/// The candidates for the word under the caret -- see the module doc
/// comment for which sources apply where. `.idle` skips anything that
/// would spawn fish or call Lua; Tab and the picker pass `.interactive`.
/// The caller owns the result (`deinit`).
pub fn gatherCandidates(self: *Prompt, lookup: Lookup) !Candidates {
    const alloc = self.client.alloc;
    const before = self.line.text()[0..self.line.caret];

    var set: Candidates = .{ .alloc = alloc, .ctx = try compctx.scan(alloc, before, self.expansion()) };
    errdefer set.deinit();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);

    const word = set.ctx.word;
    const dp = complete.dirPrefix(word);

    if (set.ctx.commandPosition() and dp.dir.len == 0) {
        set.prefix = word;
        try self.appendCommandNameCandidates(&set, &seen, word);
        // Directories too, to walk into a path (`./build/run`); plain
        // files can't be run from here without one.
        try appendDirScan(self, &set, &seen, "", word, .dirs_only);
        sortCompletionCandidates(set.items.items);
        return set;
    }

    if (!set.ctx.after_redirect and set.ctx.words.len > 0) {
        const cmd = set.ctx.words[0];
        if (self.script_engine) |eng| {
            if (eng.hasCompleter(cmd)) {
                // A completer owns the command's arguments. The idle hint
                // doesn't run it, and guessing file names in its place
                // would only disagree with what Tab offers.
                if (lookup == .idle) return set;
                if (try appendLuaCandidates(self, eng, &set, &seen, before)) return set;
            }
        }
        if (self.fishCompletionsEnabled()) {
            switch (try appendFishCandidates(self, &set, &seen, dp, before, lookup)) {
                .matched => return set,
                // fish knew this argument but nothing it offered extends
                // the word: the word is something else, likely a path.
                .unmatched => {},
                // With fish in charge of arguments, the idle hint only
                // falls back to file names for a word that is plainly a
                // path.
                .none => if (lookup == .idle and !looksLikePath(word)) return set,
            }
        }
    }

    set.prefix = dp.prefix;
    try appendDirScan(self, &set, &seen, dp.dir, dp.prefix, .all);
    sortCompletionCandidates(set.items.items);
    return set;
}

fn looksLikePath(word: []const u8) bool {
    return std.mem.indexOfScalar(u8, word, '/') != null or
        std.mem.startsWith(u8, word, ".") or std.mem.startsWith(u8, word, "~");
}

const ScanMode = enum { all, dirs_only };

/// The entries of the directory `dir_part` names (cwd if empty, `~`
/// expanded) whose names start with `prefix`, as `.file` / `.dir`
/// candidates.
fn appendDirScan(
    self: *Prompt,
    set: *Candidates,
    seen: *std.StringHashMapUnmanaged(void),
    dir_part: []const u8,
    prefix: []const u8,
    mode: ScanMode,
) !void {
    const alloc = self.client.alloc;
    const scan_dir = try self.completionDir(dir_part);
    defer alloc.free(scan_dir);

    const matches = try complete.scanDir(alloc, self.client.io, scan_dir, prefix);
    defer complete.freeMatches(alloc, matches);
    for (matches) |m| {
        if (mode == .dirs_only and !m.is_dir) continue;
        try set.push(seen, m.name, if (m.is_dir) .dir else .file, "");
    }
}

/// Runs the `defcomplete` function for the command and appends what it
/// offered that extends the word, in the order it gave them. False when
/// it declined (returned nil) or failed, so the next source gets a turn.
fn appendLuaCandidates(
    self: *Prompt,
    eng: *ScriptEngine,
    set: *Candidates,
    seen: *std.StringHashMapUnmanaged(void),
    before: []const u8,
) !bool {
    const alloc = self.client.alloc;
    var got: std.ArrayList(ScriptEngine.Completion) = .empty;
    defer {
        for (got.items) |c| {
            alloc.free(c.text);
            alloc.free(c.desc);
        }
        got.deinit(alloc);
    }
    const words: []const []const u8 = set.ctx.words;
    if (!try eng.runCompleter(alloc, words, set.ctx.word, before, &got)) return false;

    set.prefix = set.ctx.word;
    for (got.items) |c| try pushWordCandidate(set, seen, c.text, c.desc);
    return true;
}

/// Adds a whole-word candidate from fish or Lua if it extends the word.
/// A trailing `/` marks a directory (stripped -- `insertionFor` puts it
/// back); anything else is an `.arg`.
fn pushWordCandidate(set: *Candidates, seen: *std.StringHashMapUnmanaged(void), text: []const u8, desc: []const u8) !void {
    if (!std.mem.startsWith(u8, text, set.prefix)) return;
    if (text.len > 1 and std.mem.endsWith(u8, text, "/")) {
        const name = text[0 .. text.len - 1];
        if (name.len < set.prefix.len) return;
        try set.push(seen, name, .dir, desc);
        return;
    }
    try set.push(seen, text, .arg, desc);
}

/// What `appendFishCandidates` got from fish.
const FishAnswer = enum {
    /// fish answered and at least one entry extends the word.
    matched,
    /// fish answered, but none of its entries extend the word.
    unmatched,
    /// fish was unavailable, failed, timed out, had nothing, or -- for
    /// `.idle` -- has no cached answer for this query.
    none,
};

/// Asks fish what completes the word and appends the entries of its
/// answer that extend it (see `FishAnswer` for the outcomes).
///
/// The query is the command's raw text up to the word, plus the word's
/// directory part (escaped) and, for a flag, its leading `-`: the parts
/// fish's own matching depends on. The rest of the word is filtered here,
/// so typing while the picker is open narrows one cached answer instead
/// of starting fish per keystroke.
fn appendFishCandidates(
    self: *Prompt,
    set: *Candidates,
    seen: *std.StringHashMapUnmanaged(void),
    dp: complete.DirPrefix,
    before: []const u8,
    lookup: Lookup,
) !FishAnswer {
    const alloc = self.client.alloc;
    const word = set.ctx.word;

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(alloc);
    try query.appendSlice(alloc, std.mem.trimStart(u8, before[set.ctx.cmd_start..set.ctx.word_start], " \t\r\n"));
    const dir_escaped = try wordsplit.escapeSpecial(alloc, dp.dir);
    defer alloc.free(dir_escaped);
    try query.appendSlice(alloc, dir_escaped);
    if (dp.dir.len == 0 and word.len > 0 and word[0] == '-') try query.append(alloc, '-');

    if (!std.mem.eql(u8, self.fish_cache.key, query.items)) {
        if (lookup == .idle) return .none;
        const output = (try runFish(self, query.items)) orelse return .none;
        errdefer alloc.free(output);
        const items = try compctx.parseFishOutput(alloc, output);
        errdefer alloc.free(items);
        const key = try alloc.dupe(u8, query.items);
        self.fish_cache.clear(alloc);
        self.fish_cache = .{ .key = key, .output = output, .items = items };
    }
    if (self.fish_cache.items.len == 0) return .none;

    set.prefix = word;
    for (self.fish_cache.items) |item| try pushWordCandidate(set, seen, item.text, item.desc);
    return if (set.items.items.len > 0) .matched else .unmatched;
}

/// `fish --no-config -c 'complete --do-complete=...'` with `query` as the
/// command line, run in the shell's cwd and environment. The line goes
/// in through `$GW_COMPLETE_LINE` rather than the `-c` text so it needs
/// no fish quoting. `--no-config` keeps a `config.fish` that prints a
/// greeting or starts something slow out of the answer; fish still loads
/// the completions it ships. Null when fish isn't installed, fails, or
/// takes longer than `fish_timeout_ms`. Caller owns the result.
fn runFish(self: *Prompt, query: []const u8) !?[]u8 {
    const alloc = self.client.alloc;
    const fish = fishPath(self) orelse return null;

    var env = try self.env.clone(alloc);
    defer env.deinit();
    try env.put("GW_COMPLETE_LINE", query);

    const argv = [_][]const u8{ fish, "--no-config", "-c", "complete --do-complete=\"$GW_COMPLETE_LINE\"" };
    const res = std.process.run(alloc, self.client.io, .{
        .argv = &argv,
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(4 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(fish_timeout_ms), .clock = .awake } },
    }) catch return null;
    alloc.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code == 0) return res.stdout,
        else => {},
    }
    alloc.free(res.stdout);
    return null;
}

/// Whether Tab may ask fish: `prompt{ fish_completions }` (default on)
/// and a `fish` on `$PATH`.
pub fn fishCompletionsEnabled(self: *Prompt) bool {
    if (self.promptCfg()) |p| if (p.fish_completions) |on| if (!on) return false;
    return fishPath(self) != null;
}

/// The `fish` executable on `$PATH`, looked up once per `$PATH` value
/// alongside the command-name list (`pathCommands`).
fn fishPath(self: *Prompt) ?[]const u8 {
    _ = self.pathCommands() catch return null;
    return if (self.fish_path.len > 0) self.fish_path else null;
}

/// The sorted, de-duplicated executables on `$PATH` (see `PathCommands`),
/// rebuilt first if `$PATH` changed or a command has run since.
pub fn pathCommands(self: *Prompt) ![]const []const u8 {
    const alloc = self.client.alloc;
    const io = self.client.io;
    const path = self.env.get("PATH") orelse "";
    const pc = &self.path_commands;
    if (!pc.stale and std.mem.eql(u8, pc.path, path)) return pc.names.items;

    pc.deinit(alloc);
    alloc.free(self.fish_path);
    self.fish_path = "";
    pc.path = try alloc.dupe(u8, path);
    pc.stale = false;

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);

    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .directory) continue;
            if (seen.contains(entry.name)) continue;
            dir.access(io, entry.name, .{ .execute = true }) catch continue;
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);
            try pc.names.append(alloc, name);
            try seen.put(alloc, name, {});
            if (self.fish_path.len == 0 and std.mem.eql(u8, entry.name, "fish")) {
                self.fish_path = try std.fs.path.join(alloc, &.{ dir_path, "fish" });
            }
        }
    }
    std.mem.sort([]const u8, pc.names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return pc.names.items;
}

/// After a command ran: it may have installed an executable, changed
/// branches or files, or moved the cwd, so the `$PATH` list and fish's
/// cached answer are both rebuilt on next use.
pub fn invalidateCompletionCaches(self: *Prompt) void {
    self.path_commands.stale = true;
    self.fish_cache.clear(self.client.alloc);
}

pub fn sortCompletionCandidates(cands: []CompletionCandidate) void {
    std.mem.sort(CompletionCandidate, cands, {}, struct {
        fn lessThan(_: void, a: CompletionCandidate, b: CompletionCandidate) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

/// fish's autosuggestion: the rest of the newest history entry that
/// starts with everything typed so far, or null. One that would continue
/// onto another line is skipped -- the hint is drawn on a single row --
/// so an older single-line match can still show.
pub fn historySuggestion(self: *Prompt) ?[]const u8 {
    const typed = self.line.text();
    if (typed.len == 0) return null;
    var i = self.history.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.history.items[i];
        if (entry.len <= typed.len or !std.mem.startsWith(u8, entry, typed)) continue;
        const rest = entry[typed.len..];
        if (std.mem.indexOfScalar(u8, rest, '\n') == null) return rest;
    }
    return null;
}

/// On an idle tick, draw a dim suggestion after the caret: the history
/// autosuggestion if there is one (`historySuggestion`,
/// `prompt{ autosuggest }`), otherwise what Tab would insert for the
/// first completion candidate. Returns true when it repainted the input
/// row, letting the caller skip a redundant idle redraw.
pub fn maybeShowCompletionHint(self: *Prompt) !bool {
    if (!self.completion_hint_dirty or self.completion_hint_visible) return false;
    if (self.browse_pos != null or self.pending_resize != null) return false;
    if (self.completion_picker != null) return false;
    const active_at = self.completion_hint_activity_at orelse return false;
    if (active_at.untilNow(self.client.io).raw.toMilliseconds() < autocomplete_idle_ms) return false;

    const line = self.line.text();
    if (self.line.caret != line.len) return false;

    self.completion_hint_dirty = false;
    self.completion_hint.clearRetainingCapacity();

    if (self.autosuggestEnabled()) {
        if (self.historySuggestion()) |rest| {
            try self.completion_hint.appendSlice(self.client.alloc, rest);
            self.completion_hint_visible = true;
            try self.renderInputLine();
            return true;
        }
    }

    var set = try self.gatherCandidates(.idle);
    defer set.deinit();
    // A word has to be started: after a blank every entry in the
    // directory "matches", and suggesting the first one is noise.
    if (set.ctx.word.len == 0 or set.items.items.len == 0) return false;

    const suffix = try insertionFor(self.client.alloc, &set, set.items.items[0]);
    defer self.client.alloc.free(suffix);
    if (suffix.len == 0) return false;

    try self.completion_hint.appendSlice(self.client.alloc, suffix);
    self.completion_hint_visible = true;
    try self.renderInputLine();
    return true;
}

/// Whether the idle prompt offers history autosuggestions. Config:
/// `prompt{ autosuggest = false }`.
pub fn autosuggestEnabled(self: *Prompt) bool {
    if (self.promptCfg()) |p| if (p.autosuggest) |on| return on;
    return true;
}

/// Right arrow at the end of the input accepts the visible inline
/// hint. If no hint has been drawn yet, use the same completion path
/// as Tab so Right-at-end is still a completion gesture.
pub fn acceptCompletionHintOrComplete(self: *Prompt) !void {
    if (self.line.caret != self.line.text().len or self.line.text().len == 0) return;
    if (self.acceptCompletionHint()) return;
    try self.doComplete();
}

/// End / Ctrl+E (and Right, and Tab) at the end of the input with a
/// hint showing: takes all of it, as fish does. False when there was nothing to take.
pub fn acceptCompletionHint(self: *Prompt) bool {
    if (self.line.caret != self.line.text().len) return false;
    if (!self.completion_hint_visible or self.completion_hint.items.len == 0) return false;
    const alloc = self.client.alloc;
    const hint = alloc.dupe(u8, self.completion_hint.items) catch return false;
    defer alloc.free(hint);
    self.insertText(hint) catch return false;
    return true;
}

/// Ctrl+Right at the end of the input with a hint showing: takes the
/// hint's next word only (fish's `forward-word` over an autosuggestion)
/// -- any leading blanks, then up to and including the next blank or `/`.
/// False when there was no hint to take from.
pub fn acceptCompletionHintWord(self: *Prompt) !bool {
    if (self.line.caret != self.line.text().len) return false;
    if (!self.completion_hint_visible or self.completion_hint.items.len == 0) return false;
    const hint = self.completion_hint.items;
    var end: usize = 0;
    while (end < hint.len and hint[end] == ' ') : (end += 1) {}
    while (end < hint.len and hint[end] != ' ' and hint[end] != '/') : (end += 1) {}
    if (end < hint.len) end += 1; // the blank or `/` that ended the word

    const alloc = self.client.alloc;
    const taken = try alloc.dupe(u8, hint[0..end]);
    defer alloc.free(taken);
    try self.insertText(taken);
    return true;
}

/// Resolves the `dir/` portion of a completion word to a path
/// `openDir` can take: an owned copy of `"."` when there's no
/// directory part, otherwise the part itself (already `~`-expanded by
/// `compctx.scan` when it was unquoted). Always returns an owned string
/// for the caller to free.
pub fn completionDir(self: *Prompt, dir_part: []const u8) ![]const u8 {
    const alloc = self.client.alloc;
    if (dir_part.len == 0) return alloc.dupe(u8, ".");
    return alloc.dupe(u8, dir_part);
}

/// The interactive Tab-completion dropdown: recomputes the candidate
/// list from the *current* buffer/cursor (never cached -- see
/// `CompletionPickerState`), then either resolves it away (0 or, on a
/// fresh recompute, exactly 1 match) or (re)draws up to
/// `completionMaxItems()` dimmed rows below the input, one of them
/// highlighted as the current selection. Each row is the name, then
/// (lined up in a second column) its description, or its `[tag]` when
/// it has none.
///
/// `move_delta` is 0 for "the buffer changed, re-filter in place"
/// (called from `doComplete`'s first open and from every edit while
/// open -- `insertText`/`deleteBackward`/... via
/// `refreshCompletionPickerIfOpen`) and +-1 for "Up/Down/Tab moved the
/// selection" (`moveCompletionPicker`), which skips the single-match
/// auto-accept (the candidate count can't have changed from pure
/// navigation) and wraps the selection instead of resetting it.
pub fn recomputeAndDrawPicker(self: *Prompt, move_delta: isize) anyerror!void {
    var set = try self.gatherCandidates(.interactive);
    defer set.deinit();
    const cands = set.items.items;

    if (cands.len == 0) {
        try self.closeCompletionPicker();
        return;
    }
    if (move_delta == 0 and cands.len == 1) {
        try self.closeCompletionPicker();
        try self.insertCandidate(&set, cands[0]);
        return;
    }

    if (self.completion_picker == null) self.completion_picker = .{};
    var st = self.completion_picker.?;

    const max_items = self.completionMaxItems();
    const visible = @min(max_items, cands.len);

    if (move_delta == 0) {
        st.list.reset();
    } else {
        st.list.step(move_delta, cands.len, .wrap);
    }
    st.list.follow(visible);

    if (st.drawn_rows == 0) try self.reservePickerRows(visible);

    // The name column is as wide as the widest visible name (plus its
    // `/`), capped at half the grid so a long path can't push every
    // description off screen.
    const marker_w = 2; // "> " / "  "
    var name_w: usize = 0;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const cand = cands[st.list.top + i];
        name_w = @max(name_w, lineedit.cellWidth(cand.name) + @intFromBool(cand.source == .dir));
    }
    name_w = @min(name_w, (self.grid_cols / 2) -| marker_w);

    var b = self.client.batch();
    defer b.deinit();
    const top = self.inputBottomRow() + 1;
    try self.batchClear(&b, top, 0, @max(st.drawn_rows, visible), self.grid_cols);

    i = 0;
    while (i < visible) : (i += 1) {
        const idx = st.list.top + i;
        const cand = cands[idx];
        const selected = idx == st.list.selected;
        const dim: ?glyphwire.Color = if (selected) null else autocomplete_hint_color;

        try self.batchSetCursor(&b, top + i, 0);
        try self.batchText(&b, if (selected) "> " else "  ", dim, null);

        const name_cols = clipWidth(cand.name, name_w);
        try self.batchText(&b, cand.name[0..name_cols.bytes], dim, null);
        if (cand.source == .dir and name_cols.bytes == cand.name.len and name_cols.width < name_w) {
            try self.batchText(&b, "/", dim, null);
        }

        // Second column: two spaces past the name column.
        const col2 = marker_w + name_w + 2;
        if (col2 >= self.grid_cols) continue;
        try self.batchSetCursor(&b, top + i, col2);
        const room = self.grid_cols - col2;
        if (cand.desc.len > 0) {
            const d = clipWidth(cand.desc, room);
            try self.batchText(&b, cand.desc[0..d.bytes], autocomplete_hint_color, null);
        } else {
            var tag_buf: [32]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "[{s}]", .{completionSourceTag(cand.source)}) catch "";
            const t = clipWidth(tag, room);
            try self.batchText(&b, tag[0..t.bytes], autocomplete_hint_color, null);
        }
    }

    try self.appendInputLine(&b); // restores the caret to the live line
    var res = try b.send();
    res.deinit();

    st.drawn_rows = visible;
    self.completion_picker = st;
}

/// The longest leading run of whole codepoints of `text` that fits in
/// `cols` display columns: its byte length and the columns it takes. A
/// picker row has to be cut short rather than wrap onto the next one.
fn clipWidth(text: []const u8, cols: usize) struct { bytes: usize, width: usize } {
    const end = lineedit.offsetAtCol(text, 0, cols);
    return .{ .bytes = end, .width = lineedit.cellWidth(text[0..end]) };
}

/// Reserves `rows_needed` grid rows below the input for the picker's
/// first draw, scrolling the layer up-front (same trick as
/// `writePowerlinePrefix`'s overshoot) if the input is close enough to
/// the bottom that they wouldn't otherwise fit.
pub fn reservePickerRows(self: *Prompt, rows_needed: usize) !void {
    if (self.grid_rows == 0 or rows_needed == 0) return;
    const need_bottom = self.inputBottomRow() + rows_needed;
    if (need_bottom < self.grid_rows) return;

    const overshoot = need_bottom - self.grid_rows + 1;
    var b = self.client.batch();
    defer b.deinit();
    try self.batchSetCursor(&b, self.grid_rows - 1, 0);
    var k: usize = 0;
    while (k < overshoot) : (k += 1) try self.batchText(&b, "\n", null, null);
    var res = try b.send();
    res.deinit();
    self.line_start_row -|= overshoot;
    self.pl_top_row -|= overshoot;
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
/// highlighted candidate (same insertion as a single-match Tab) and
/// closes the picker, without submitting the line.
pub fn acceptCompletionPicker(self: *Prompt) !void {
    const st = self.completion_picker orelse return;

    var set = try self.gatherCandidates(.interactive);
    defer set.deinit();

    try self.closeCompletionPicker();
    if (st.list.selected >= set.items.items.len) return; // stale -- nothing sane to accept
    try self.insertCandidate(&set, set.items.items[st.list.selected]);
}

/// Escape, an explicit cursor move, or the candidate list narrowing to
/// nothing all close the picker: clears its drawn rows and repaints
/// the input + caret in their place, in one batch frame.
pub fn closeCompletionPicker(self: *Prompt) !void {
    const st = self.completion_picker orelse return;
    self.completion_picker = null;
    if (st.drawn_rows == 0) return;

    var b = self.client.batch();
    defer b.deinit();
    try self.batchClear(&b, self.inputBottomRow() + 1, 0, st.drawn_rows, self.grid_cols);
    try self.appendInputLine(&b);
    var res = try b.send();
    res.deinit();
}
