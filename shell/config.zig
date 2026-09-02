//! Loads glyphwire-shell's startup config, `~/.config/glyphwire/shell.conf`,
//! which is a Lua script. Running it produces a `ShellConfig` -- the Lua
//! bindings (right now just `alias(name, value)`) append into that struct
//! rather than touching the live prompt, so `shell/main.zig` can apply the
//! parsed result in one place and the parsing itself is unit-testable
//! without a running shell. Mirrors how pixzig parses a Lua config into a
//! Zig structure; new bindings add a field here and a collector in `load`.
//!
//! `load` spins up a throwaway Lua state for a one-shot parse (this is
//! what the unit tests drive). The live shell instead keeps one Lua state
//! for the whole session -- see `shell/script_engine.zig` -- and reuses
//! the `alias`/`prompt` collectors here through `installBindings` +
//! `beginCollecting`/`endCollecting`, so a `function` defined in
//! `shell.conf` stays callable as a builtin afterwards.

const std = @import("std");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;
const openaction = @import("openaction.zig");

/// One `alias(name, value)` call collected from a shell.conf run. Both
/// fields are owned by the enclosing `ShellConfig`.
pub const AliasDef = struct {
    name: []const u8,
    value: []const u8,
};

/// One `open_actions{ ["key"] = ... }` entry -- `openaction.Action`
/// verbatim (key = a mimetype "image/png" / group "image/*" / kind
/// keyword; `commands` = the ordered command templates, `{sel}` /
/// `{selections}` expanding to shell-quoted paths). A string value in the
/// conf becomes a one-element list; a table value is taken in order. Only
/// `commands[0]` runs today -- the list shape is kept for a future action
/// picker. All strings are owned by the enclosing `ShellConfig`
/// (`prompt_arena`).
pub const OpenActionDef = openaction.Action;

/// When a powerline segment is shown. `always` is the default; `err`
/// shows it only after a non-zero exit; `slow` only when the last
/// command ran at least `dur_min_ms`. A segment whose text renders empty
/// is dropped regardless.
pub const SegmentWhen = enum { always, err, slow };

/// One powerline segment from a `left_segments` / `right_segments` list.
/// `text` is itself a template (run through `shell/prompt_template.zig`,
/// so `{cwd}` / `{icon:...}` / `{time}` / `{env:VAR}` all work inside).
/// `fg`/`bg` are `#rgb` / `#rrggbb`. All strings owned by the enclosing
/// `ShellConfig`.
pub const PromptSegment = struct {
    text: []const u8,
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    when: SegmentWhen = .always,
    /// Set when the segment's `when` value was a template expression (it
    /// contained a `{`) rather than one of the `always|error|slow`
    /// keywords -- `shell/main.zig` renders it against the command vars
    /// and shows the segment only when the result is truthy (non-empty,
    /// not `0`/`false`); a leading `!` negates. `when` stays `.always` in
    /// that case so the keyword filter is a pass-through.
    when_expr: ?[]const u8 = null,
};

/// One `commands = { name = ... }` entry from a `prompt{}` call. `run` is
/// a `/bin/sh -c` command line the shell runs *on demand* -- only when a
/// segment or a `when` clause actually references `{name}` -- and whose
/// trimmed stdout is interpolated for `{name}`. `when`, if set, is a
/// template expression (`{other_var}` tokens, optional leading `!`)
/// gating whether the command runs at all, so a `git` command can be
/// guarded by a cheap "am I in a repo" probe. `timeout_ms` overrides the
/// built-in per-command timeout. All strings owned by the enclosing
/// `ShellConfig` (`prompt_arena`).
pub const CommandVar = struct {
    name: []const u8,
    run: []const u8,
    when: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
};

/// The prompt templating a `prompt{ ... }` call declared. Two forms:
///
///  - **Plain:** `left` / `right` are template strings (see
///    `shell/prompt_template.zig`); `exit` / `dur` are the sub-templates
///    `{exit}` / `{dur}` expand to.
///  - **Powerline:** `left_segments` / `right_segments` are lists of
///    `PromptSegment`, joined with `sep` (a Nerd Font separator glyph)
///    and optionally capped with `head` / `tail` / `right_head`. `lines`
///    makes the prompt multi-row (segments on the first row, input on the
///    last, prefixed with `input`).
///
/// A `null` field was never set across any `prompt` call and the prompt
/// keeps its built-in default for that piece. Every non-null string is
/// owned by the enclosing `ShellConfig`.
pub const PromptConfig = struct {
    left: ?[]const u8 = null,
    right: ?[]const u8 = null,
    exit: ?[]const u8 = null,
    dur: ?[]const u8 = null,
    /// Minimum last-command run time, in milliseconds, before `{dur}`
    /// (and a `when = "slow"` segment) renders anything. `null` -> the
    /// prompt's default (2000).
    dur_min_ms: ?u64 = null,

    left_segments: ?[]PromptSegment = null,
    right_segments: ?[]PromptSegment = null,
    /// On-demand command vars from `commands = { ... }`. `null` -> none
    /// declared. Looked up by `name` when a template hits an otherwise
    /// unknown `{name}` token (see `shell/main.zig`'s `resolveCmdVar`).
    command_vars: ?[]CommandVar = null,
    /// Separator glyph drawn between adjacent segments (fg = the left
    /// segment's bg, bg = the right segment's bg -- the powerline trick).
    sep: ?[]const u8 = null,
    /// Separator between right-side segments, if it should differ from
    /// `sep` (e.g. a left-pointing glyph). Falls back to `sep`.
    sep_right: ?[]const u8 = null,
    /// Cap glyph before the first left segment / after the last left
    /// segment / before the first right segment. Drawn in the adjacent
    /// segment's bg over the terminal background.
    head: ?[]const u8 = null,
    tail: ?[]const u8 = null,
    /// Left cap of the right-aligned chain (the edge facing the input).
    /// Unset, it falls back to `head`, mirroring `sep_right` -> `sep`.
    right_head: ?[]const u8 = null,
    /// Total prompt rows. `null`/1 -> single line. `>= 2` -> segments on
    /// the first row, the input line on the last row.
    lines: ?u8 = null,
    /// Prefix drawn on the input row (default `"> "`).
    input: ?[]const u8 = null,
    /// `strftime` format for `{time}` (default `"%H:%M"`).
    time_format: ?[]const u8 = null,
    /// Rows of context to keep between the browse cursor and the edge of
    /// the window while scrolling through scrollback with Up/Down (a
    /// vim-style "scrolloff"). `null` -> the built-in default (8). Clamped
    /// at use to leave room for the cursor itself.
    scrolloff: ?u32 = null,
};

/// Everything one shell.conf run declared, parsed into Zig data. Owns its
/// contents; call `deinit` once the caller has copied what it needs.
pub const ShellConfig = struct {
    alloc: std.mem.Allocator,
    /// `alias` bindings, in the order the conf declared them -- a later
    /// duplicate name is kept as its own entry, so whoever applies these
    /// (see `Prompt`) gets last-write-wins for free.
    aliases: std.ArrayList(AliasDef) = .empty,
    /// Prompt templating from `prompt{ ... }` calls. Multiple calls merge
    /// key by key, last write winning per key.
    prompt: PromptConfig = .{},
    /// `open_actions{ ... }` entries, in declaration order across every
    /// call (a later entry for the same key wins -- `openaction.resolve`
    /// scans last-match). Empty means "defaults only". Backed by
    /// `prompt_arena` -- see its doc comment on why an arena.
    open_actions: std.ArrayList(OpenActionDef) = .empty,
    /// Backs every string and segment array in `prompt`, plus every
    /// `open_actions` entry (and its own list backing). An arena because
    /// `luaPrompt`'s / `luaOpenActions`' validation raises Lua errors (a C
    /// `longjmp` past Zig `defer`/`errdefer`), so per-allocation cleanup on
    /// a bad-config path is unreachable -- the arena frees the partial work
    /// wholesale in `deinit` instead. Merging calls just accumulates here.
    prompt_arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ShellConfig) void {
        for (self.aliases.items) |a| {
            self.alloc.free(a.name);
            self.alloc.free(a.value);
        }
        self.aliases.deinit(self.alloc);
        self.prompt_arena.deinit();
    }
};

/// Outcome of `load`: the parsed config plus, on a Lua load/run failure,
/// an owned diagnostic string. `config` still holds whatever the conf
/// managed to declare before the error (Lua stops at the failing line),
/// so the caller can apply the partial result and surface `err`.
pub const LoadResult = struct {
    config: ShellConfig,
    err: ?[]const u8 = null,

    pub fn deinit(self: *LoadResult) void {
        if (self.err) |e| self.config.alloc.free(e);
        self.config.deinit();
    }
};

/// The config currently being populated, reachable from the C-ABI Lua
/// callbacks. Set only while a config run is in flight (`load` here, or a
/// `shell.conf` run inside `script_engine`) -- the shell runs
/// single-threaded, so a module-level pointer is enough (same pattern as
/// pixzig's `sequencer.SeqScriptingContext`).
var g_active: ?*ShellConfig = null;

/// Pushes the `alias` and `prompt` bindings as globals on `lua`. Split
/// out from `load` so the persistent `ScriptEngine` can install the same
/// collectors on its session-long state. Pair a run with
/// `beginCollecting`/`endCollecting`.
pub fn installBindings(lua: *Lua) void {
    lua.pushFunction(ziglua.wrap(luaAlias));
    lua.setGlobal("alias");

    lua.pushFunction(ziglua.wrap(luaPrompt));
    lua.setGlobal("prompt");

    lua.pushFunction(ziglua.wrap(luaOpenActions));
    lua.setGlobal("open_actions");
}

/// Makes `cfg` the `ShellConfig` every `alias`/`prompt` call appends
/// into, returning the previous target for `endCollecting` to restore.
pub fn beginCollecting(cfg: *ShellConfig) ?*ShellConfig {
    const prev = g_active;
    g_active = cfg;
    return prev;
}

/// Restores whatever `beginCollecting` displaced. Always pair the two.
pub fn endCollecting(prev: ?*ShellConfig) void {
    g_active = prev;
}

/// Runs `source` (the contents of shell.conf, null-terminated) as Lua
/// with glyphwire's config bindings installed, collecting what it
/// declares. The standard Lua libraries are opened, so a conf can use
/// `string`/`table`/loops/conditionals to build its alias list. Only a
/// genuine allocation failure is returned as an error; a Lua syntax or
/// runtime error lands in `LoadResult.err` with a partial config.
pub fn load(alloc: std.mem.Allocator, source: [:0]const u8) error{OutOfMemory}!LoadResult {
    var cfg: ShellConfig = .{ .alloc = alloc, .prompt_arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer cfg.deinit();

    const lua = Lua.init(alloc) catch {
        return .{ .config = cfg, .err = try alloc.dupe(u8, "shell.conf: could not create Lua interpreter") };
    };
    defer lua.deinit();
    lua.openLibs();

    installBindings(lua);

    const prev = beginCollecting(&cfg);
    defer endCollecting(prev);

    lua.doString(source) catch {
        const msg = lua.toString(-1) catch "shell.conf: unknown Lua error";
        return .{ .config = cfg, .err = try alloc.dupe(u8, msg) };
    };

    return .{ .config = cfg };
}

/// `alias(name, value)` -- both arguments must be strings (a non-string
/// raises a Lua error, reported through `LoadResult.err`). Appends the
/// binding to the active `ShellConfig`.
fn luaAlias(lua: *Lua) !i32 {
    const cfg = g_active orelse return 0;
    const name = lua.checkString(1);
    const value = lua.checkString(2);

    const name_owned = try cfg.alloc.dupe(u8, name);
    errdefer cfg.alloc.free(name_owned);
    const value_owned = try cfg.alloc.dupe(u8, value);
    errdefer cfg.alloc.free(value_owned);

    try cfg.aliases.append(cfg.alloc, .{ .name = name_owned, .value = value_owned });
    return 0;
}

/// `prompt{ ... }` -- one table argument, every key optional. String keys
/// must be strings (a number coerces, like `alias`; other types raise).
/// `left_segments` / `right_segments` are arrays of `{ text|[1], fg, bg,
/// when }` tables. `dur_min_ms` / `lines` must be non-negative numbers.
/// Multiple `prompt` calls merge: a key set again replaces (and frees)
/// the earlier value, an omitted key is left as a prior call set it.
fn luaPrompt(lua: *Lua) !i32 {
    const cfg = g_active orelse return 0;
    lua.checkType(1, .table);

    inline for (.{
        .{ "left", &cfg.prompt.left },       .{ "right", &cfg.prompt.right },
        .{ "exit", &cfg.prompt.exit },       .{ "dur", &cfg.prompt.dur },
        .{ "sep", &cfg.prompt.sep },         .{ "sep_right", &cfg.prompt.sep_right },
        .{ "head", &cfg.prompt.head },       .{ "tail", &cfg.prompt.tail },
        .{ "right_head", &cfg.prompt.right_head }, .{ "input", &cfg.prompt.input },
        .{ "time_format", &cfg.prompt.time_format },
    }) |pair| {
        try promptStrField(lua, cfg, pair[1], pair[0]);
    }

    try promptSegmentsField(lua, cfg, &cfg.prompt.left_segments, "left_segments");
    try promptSegmentsField(lua, cfg, &cfg.prompt.right_segments, "right_segments");
    try promptCommandsField(lua, cfg, &cfg.prompt.command_vars, "commands");

    _ = lua.getField(1, "dur_min_ms");
    if (!lua.isNoneOrNil(-1)) {
        const n = lua.checkNumber(-1);
        if (n < 0) lua.raiseErrorStr("prompt: dur_min_ms must be >= 0", .{});
        cfg.prompt.dur_min_ms = @as(u64, @intFromFloat(n));
    }
    lua.pop(1);

    _ = lua.getField(1, "lines");
    if (!lua.isNoneOrNil(-1)) {
        const n = lua.checkNumber(-1);
        if (n < 1) lua.raiseErrorStr("prompt: lines must be >= 1", .{});
        cfg.prompt.lines = @as(u8, @intFromFloat(@min(n, 255)));
    }
    lua.pop(1);

    _ = lua.getField(1, "scrolloff");
    if (!lua.isNoneOrNil(-1)) {
        const n = lua.checkNumber(-1);
        if (n < 0) lua.raiseErrorStr("prompt: scrolloff must be >= 0", .{});
        cfg.prompt.scrolloff = @as(u32, @intFromFloat(@min(n, 1_000_000)));
    }
    lua.pop(1);

    return 0;
}

/// Reads one string key off the table at stack index 1 into `slot`.
/// A missing/nil key leaves `slot` untouched; a set key overwrites (the
/// old value stays in `prompt_arena` until `deinit`).
fn promptStrField(lua: *Lua, cfg: *ShellConfig, slot: *?[]const u8, key: [:0]const u8) !void {
    _ = lua.getField(1, key);
    defer lua.pop(1);
    if (lua.isNoneOrNil(-1)) return;

    const s = lua.checkString(-1); // raises on a non-string/non-number
    slot.* = try cfg.prompt_arena.allocator().dupe(u8, s);
}

/// Reads an array-of-tables segment list off the table at stack index 1
/// into `slot`, replacing any previous list. Each entry is
/// `{ text = "..." (or [1]), fg = "#rgb", bg = "#rgb", when = "..." }`.
fn promptSegmentsField(lua: *Lua, cfg: *ShellConfig, slot: *?[]PromptSegment, key: [:0]const u8) !void {
    _ = lua.getField(1, key);
    defer lua.pop(1);
    if (lua.isNoneOrNil(-1)) return;
    lua.checkType(-1, .table);

    const arena = cfg.prompt_arena.allocator();
    const tbl = lua.getTop();
    const n = lua.rawLen(tbl);
    if (n == 0) return;

    const list = try arena.alloc(PromptSegment, n);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        _ = lua.getIndex(tbl, @intCast(i));
        defer lua.pop(1);
        lua.checkType(-1, .table);
        list[i - 1] = try readSegment(lua, arena, lua.getTop());
    }
    slot.* = list;
}

/// Reads one segment table (at absolute stack index `idx`). Allocations
/// go in the `prompt_arena`, so a Lua error raised partway (bad `when`)
/// doesn't leak -- the arena frees everything in `ShellConfig.deinit`.
fn readSegment(lua: *Lua, arena: std.mem.Allocator, idx: i32) !PromptSegment {
    var seg = PromptSegment{ .text = &.{} };

    // text: the `text` field, or positional `[1]`.
    _ = lua.getField(idx, "text");
    if (lua.isNoneOrNil(-1)) {
        lua.pop(1);
        _ = lua.getIndex(idx, 1);
    }
    seg.text = try arena.dupe(u8, lua.checkString(-1));
    lua.pop(1);

    seg.fg = try optStrField(lua, arena, idx, "fg");
    seg.bg = try optStrField(lua, arena, idx, "bg");

    _ = lua.getField(idx, "when");
    if (!lua.isNoneOrNil(-1)) {
        const w = lua.checkString(-1);
        if (std.mem.indexOfScalar(u8, w, '{') != null) {
            // A `{var}` template expression, not a keyword -- kept as-is
            // and evaluated against the command vars by `shell/main.zig`.
            seg.when_expr = try arena.dupe(u8, w);
        } else {
            seg.when = if (std.mem.eql(u8, w, "always")) .always else if (std.mem.eql(u8, w, "error") or std.mem.eql(u8, w, "err"))
                .err
            else if (std.mem.eql(u8, w, "slow"))
                .slow
            else
                lua.raiseErrorStr("prompt: segment `when` must be always|error|slow or a {{var}} expression", .{});
        }
    }
    lua.pop(1);

    return seg;
}

/// Reads the `commands = { name = "cmd" | { "cmd" (or run), when,
/// timeout_ms }, ... }` map off the table at stack index 1 into `slot`,
/// replacing any previous list. Map keys are the var names; a string
/// value is the command line, a table value carries `when` /
/// `timeout_ms` alongside it. Allocations go in `prompt_arena`, so a Lua
/// error raised partway (a bad entry) frees wholesale in `deinit`.
fn promptCommandsField(lua: *Lua, cfg: *ShellConfig, slot: *?[]CommandVar, key: [:0]const u8) !void {
    _ = lua.getField(1, key);
    defer lua.pop(1);
    if (lua.isNoneOrNil(-1)) return;
    lua.checkType(-1, .table);

    const arena = cfg.prompt_arena.allocator();
    const tbl = lua.getTop();

    var list: std.ArrayList(CommandVar) = .empty;

    lua.pushNil();
    while (lua.next(tbl)) {
        // Key at -2, value at -1. A string coercion on a numeric key
        // mid-traversal would corrupt `next`, so type-check first.
        if (lua.typeOf(-2) != .string)
            lua.raiseErrorStr("prompt: `commands` keys must be strings (the var name)", .{});
        const name = try arena.dupe(u8, lua.toString(-2) catch unreachable);

        var cv = CommandVar{ .name = name, .run = &.{} };
        switch (lua.typeOf(-1)) {
            .string => cv.run = try arena.dupe(u8, lua.toString(-1) catch unreachable),
            .table => {
                const vidx = lua.getTop();

                _ = lua.getField(vidx, "run");
                if (lua.isNoneOrNil(-1)) {
                    lua.pop(1);
                    _ = lua.getIndex(vidx, 1);
                }
                cv.run = try arena.dupe(u8, lua.checkString(-1));
                lua.pop(1);

                cv.when = try optStrField(lua, arena, vidx, "when");

                _ = lua.getField(vidx, "timeout_ms");
                if (!lua.isNoneOrNil(-1)) {
                    const n = lua.checkNumber(-1);
                    if (n < 0) lua.raiseErrorStr("prompt: `commands` timeout_ms must be >= 0", .{});
                    cv.timeout_ms = @as(u64, @intFromFloat(n));
                }
                lua.pop(1);
            },
            else => lua.raiseErrorStr("prompt: a `commands` entry must be a string or a table", .{}),
        }

        try list.append(arena, cv);
        lua.pop(1); // pop value, leave key for the next `next`
    }

    if (list.items.len == 0) return;
    slot.* = try list.toOwnedSlice(arena);
}

/// `open_actions{ ["key"] = "cmd template" | { "cmd", ... }, ... }` --
/// one table argument, string keys (a mimetype / `"group/*"` / kind
/// keyword). A string value is a single command template; a table value
/// is an ordered list of them (for a future action picker). Every call
/// appends into `cfg.open_actions`; `openaction.resolve` handles a later
/// entry overriding an earlier one for the same key. Allocations go in
/// `prompt_arena`, so a Lua error raised partway frees wholesale in
/// `deinit`.
fn luaOpenActions(lua: *Lua) !i32 {
    const cfg = g_active orelse return 0;
    lua.checkType(1, .table);
    const arena = cfg.prompt_arena.allocator();

    lua.pushNil();
    while (lua.next(1)) {
        // Key at -2, value at -1. Type-check the key before any string
        // coercion so a stray numeric key can't corrupt `next`.
        if (lua.typeOf(-2) != .string)
            lua.raiseErrorStr("open_actions: keys must be strings (a mimetype, \"group/*\", or a kind keyword)", .{});
        const key = try arena.dupe(u8, lua.toString(-2) catch unreachable);

        var cmds: std.ArrayList([]const u8) = .empty;
        switch (lua.typeOf(-1)) {
            .string => try cmds.append(arena, try arena.dupe(u8, lua.toString(-1) catch unreachable)),
            .table => {
                const vidx = lua.getTop();
                const n = lua.rawLen(vidx);
                if (n == 0)
                    lua.raiseErrorStr("open_actions: a list value must hold at least one command string", .{});
                var i: usize = 1;
                while (i <= n) : (i += 1) {
                    _ = lua.getIndex(vidx, @intCast(i));
                    try cmds.append(arena, try arena.dupe(u8, lua.checkString(-1)));
                    lua.pop(1);
                }
            },
            else => lua.raiseErrorStr("open_actions: a value must be a command string or a list of them", .{}),
        }

        try cfg.open_actions.append(arena, .{ .key = key, .commands = try cmds.toOwnedSlice(arena) });
        lua.pop(1); // pop value, leave key for the next `next`
    }
    return 0;
}

fn optStrField(lua: *Lua, alloc: std.mem.Allocator, idx: i32, key: [:0]const u8) !?[]const u8 {
    _ = lua.getField(idx, key);
    defer lua.pop(1);
    if (lua.isNoneOrNil(-1)) return null;
    return try alloc.dupe(u8, lua.checkString(-1));
}
