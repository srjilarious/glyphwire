// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's Lua extensions: scripts that add named commands to the editor,
//! which the command palette lists and `keys` can bind like any built-in
//! action. `zoe.conf.lua` opts in by name, with an options table each:
//!
//!     config = {
//!         extensions = { task_journal = { tags = { "MGMT", "BUG" } } },
//!         keys = { normal = { ["ctrl+alt+t"] = "taskToggle" } },
//!     }
//!
//! An extension `<name>` is `<config dir>/zoe/extensions/<name>.lua` when
//! that exists, else the copy built into zoe (`bundled`). It runs once at
//! startup, with its options as `...`, and registers its commands through
//! the global `zoe` table; docs/zoe-extensions.md is the API reference.
//!
//! Unlike every other Lua file glyphwire reads, the state here lives as
//! long as zoe does: a command is a Lua function called when its key or
//! palette entry is. So it runs the config a second time in its own
//! state (`zoe/langconf.zig`'s parse keeps only plain values) to reach
//! `config.extensions`.
//!
//! Nothing an extension does can take zoe down. Every call into Lua is
//! protected, its error lands in the statusline, and a command that runs
//! past `max_steps` VM instructions is stopped -- zoe is single-threaded,
//! so a loop that never ends would otherwise freeze the window.

const std = @import("std");
const ziglua = @import("ziglua");
const glyphwire = @import("glyphwire");
const keybind = @import("applib").keybind;
const homepath = @import("applib").homepath;
const actions = @import("actions.zig");
const Editor = @import("editor.zig").Editor;

const Lua = ziglua.Lua;

/// Extensions built into zoe, by name. A file of the same name in the
/// user's extension directory wins, so one can be copied out and changed.
pub const bundled = [_]struct { name: []const u8, source: [:0]const u8 }{
    .{ .name = "task_journal", .source = @embedFile("extensions/task_journal.lua") },
};

/// The most of an extension file zoe reads, the same cap `luaconf` puts
/// on a config.
pub const max_source_bytes: usize = 256 * 1024;

/// VM instructions one command (or one extension's load) may run before
/// it is stopped, counted in `hook_every` steps: tens of milliseconds of
/// real work, far more than a command that edits a line or opens a file
/// needs, and short enough that a runaway loop is a hiccup, not a hang.
pub const max_steps: u32 = 50_000_000;
const hook_every: i32 = 1000;

/// What the runtime needs from the window it runs in. `zoe/ui.zig`
/// supplies the real one; tests hand in a fake over a bare `Editor`.
pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The buffer the keyboard is in, or null when it is elsewhere
        /// (the file tree).
        editor: *const fn (ctx: *anyopaque) ?*Editor,
        /// Opens `path` in a tab, or switches to the one it is in.
        open: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        /// Puts `text` in the statusline.
        message: *const fn (ctx: *anyopaque, text: []const u8) void,
    };
};

/// One command an extension registered with `zoe.command`.
pub const Command = struct {
    /// What the palette searches and `keys` names. Owned.
    name: []const u8,
    /// The palette's text, or null to make one from `name`. Owned.
    label: ?[]const u8,
    /// The Lua function, as a registry reference.
    ref: i32,
};

/// A chord that runs a command, in one of `actions.Scope`'s tables.
pub const Binding = struct {
    scope: actions.Scope,
    chord: keybind.Chord,
    /// Index into `Runtime.commands`.
    command: u32,
};

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// `$HOME`, for `~` in paths. Borrowed from the environment.
    home: ?[]const u8,
    lua: *Lua,
    host: Host,
    commands: std.ArrayList(Command) = .empty,
    /// The extensions' own `zoe.bind`s, then the config's `keys` over
    /// them (`resolveKeys`).
    bindings: std.ArrayList(Binding) = .empty,
    /// What went wrong loading, one owned line each, for the caller to
    /// log and show.
    problems: std.ArrayList([]u8) = .empty,
    /// The extension whose file is running, while one is: only then may
    /// it register commands and bindings.
    loading: ?[]const u8 = null,
    /// The editors the command in progress has edited, each with an undo
    /// step open (`Editor.beginScriptEdit`) until it returns.
    edited: std.ArrayList(*Editor) = .empty,
    /// Instructions run so far by the call in progress, in `hook_every`s.
    steps: u32 = 0,
    /// Where a call is stopped: `max_steps`, lowered by tests that don't
    /// want to spin for long proving it.
    step_limit: u32 = max_steps,

    /// On the heap, because the Lua state keeps a pointer back to it.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, home: ?[]const u8, host: Host) !*Runtime {
        const self = try alloc.create(Runtime);
        errdefer alloc.destroy(self);
        const lua = try Lua.init(alloc);
        errdefer lua.deinit();
        self.* = .{ .alloc = alloc, .io = io, .home = home, .lua = lua, .host = host };
        @as(*align(1) *Runtime, @ptrCast(lua.getExtraSpace().ptr)).* = self;
        lua.openLibs();
        // Unsaved buffers would go with it, unasked.
        if ((lua.getGlobal("os") catch .nil) == .table) {
            lua.pushNil();
            lua.setField(-2, "exit");
        }
        lua.pop(1);
        lua.newLib(&api);
        lua.setGlobal("zoe");
        lua.setHook(ziglua.wrap(countHook), .{ .count = true }, hook_every);
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.lua.deinit();
        for (self.commands.items) |c| {
            self.alloc.free(c.name);
            if (c.label) |l| self.alloc.free(l);
        }
        self.commands.deinit(self.alloc);
        self.bindings.deinit(self.alloc);
        for (self.problems.items) |p| self.alloc.free(p);
        self.problems.deinit(self.alloc);
        self.edited.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Runs the config `source` and loads every extension its
    /// `config.extensions` names, from `user_dir` (null: none) or
    /// `bundled`. A config that fails part-way still loads whatever
    /// `config.extensions` it had set; zoe's config parse has already
    /// reported the error.
    pub fn load(self: *Runtime, source: [:0]const u8, user_dir: ?[]const u8) void {
        const lua = self.lua;
        const top = lua.getTop();
        defer lua.setTop(top);

        if (self.call(source, "=zoe.conf.lua")) |msg| self.alloc.free(msg);
        if ((lua.getGlobal("config") catch return) != .table) return;
        if (lua.getField(-1, "extensions") != .table) {
            if (lua.typeOf(-1) != .nil) self.problem("config.extensions is not a table; ignored", .{});
            return;
        }

        // Both shapes: `{ "a", "b" }` (no options) and `{ a = {...} }`.
        // Lua's own order for the second is unspecified, so the names are
        // sorted: two extensions claiming one chord should settle the same
        // way every start.
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
        }
        lua.pushNil();
        while (lua.next(-2)) {
            defer lua.pop(1);
            const name_index: i32 = switch (lua.typeOf(-2)) {
                .number => -1,
                .string => -2,
                else => continue,
            };
            if (lua.typeOf(name_index) != .string) {
                self.problem("config.extensions: an entry that is not a name; ignored", .{});
                continue;
            }
            if (name_index == -2 and lua.typeOf(-1) == .boolean and !lua.toBoolean(-1)) continue;
            const name = self.alloc.dupe(u8, lua.toString(name_index) catch continue) catch return;
            names.append(self.alloc, name) catch {
                self.alloc.free(name);
                return;
            };
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        for (names.items, 0..) |name, i| {
            // `{ "a", a = {...} }` names one extension twice.
            if (i > 0 and std.mem.eql(u8, names.items[i - 1], name)) continue;
            self.loadOne(name, user_dir);
        }
    }

    /// One extension, with `config.extensions[name]` (at the top of the
    /// stack) as its options when that is a table.
    fn loadOne(self: *Runtime, name: []const u8, user_dir: ?[]const u8) void {
        if (!validExtensionName(name)) {
            self.problem("extension \"{s}\": names are letters, digits, _ and -; ignored", .{name});
            return;
        }
        // The chunk name is what Lua puts in front of an error's line
        // number: the file, or a note that it is the built-in copy.
        var chunk_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        var chunk_name: [:0]const u8 = undefined;
        var source: [:0]const u8 = undefined;
        var owned: ?[:0]u8 = null;
        defer if (owned) |o| self.alloc.free(o);
        if (self.readUser(name, user_dir, &chunk_buf)) |r| {
            owned = r.source;
            source = r.source;
            chunk_name = r.chunk_name;
        } else for (bundled) |b| {
            if (std.mem.eql(u8, b.name, name)) {
                source = b.source;
                chunk_name = std.fmt.bufPrintSentinel(&chunk_buf, "@{s}.lua (built in)", .{name}, 0) catch "=extension";
                break;
            }
        } else {
            self.problem("extension \"{s}\": not found", .{name});
            return;
        }

        // Its options, or an empty table, as the chunk's `...`.
        const lua = self.lua;
        var name_buf: [128]u8 = undefined;
        const name_z = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{name}, 0) catch return;
        if (lua.getField(-1, name_z) != .table) {
            lua.pop(1);
            lua.newTable();
        }
        self.loading = name;
        defer self.loading = null;
        if (self.callWithArg(source, chunk_name)) |msg| {
            defer self.alloc.free(msg);
            self.problem("extension \"{s}\": {s}", .{ name, msg });
        }
    }

    const UserSource = struct { source: [:0]u8, chunk_name: [:0]const u8 };

    /// `<user_dir>/<name>.lua`, or null when there is no such file. A
    /// file that is there but can't be read is a problem, and null. The
    /// chunk name (`@<path>`) is written into `buf`.
    fn readUser(self: *Runtime, name: []const u8, user_dir: ?[]const u8, buf: []u8) ?UserSource {
        const dir = user_dir orelse return null;
        const chunk_name = std.fmt.bufPrintSentinel(buf, "@{s}/{s}.lua", .{ dir, name }, 0) catch return null;
        const path = chunk_name[1..];
        const src = std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.alloc, .limited(max_source_bytes), .of(u8), 0) catch |err| {
            if (err != error.FileNotFound) self.problem("extension \"{s}\": couldn't read {s} ({t})", .{ name, path, err });
            return null;
        };
        return .{ .source = src, .chunk_name = chunk_name };
    }

    /// Loads `source` as a chunk and calls it with no arguments. The
    /// error message, owned, or null when it ran.
    fn call(self: *Runtime, source: []const u8, chunk_name: [:0]const u8) ?[]u8 {
        const lua = self.lua;
        lua.loadBuffer(source, chunk_name, .text) catch return self.popError();
        return self.protected(0);
    }

    /// `call`, passing the value on top of the stack (popped) as `...`.
    fn callWithArg(self: *Runtime, source: []const u8, chunk_name: [:0]const u8) ?[]u8 {
        const lua = self.lua;
        lua.loadBuffer(source, chunk_name, .text) catch {
            lua.remove(-2);
            return self.popError();
        };
        lua.insert(-2);
        return self.protected(1);
    }

    /// Calls the function under `args` arguments with the step budget
    /// reset; the error message (owned) or null.
    fn protected(self: *Runtime, args: i32) ?[]u8 {
        self.steps = 0;
        self.lua.protectedCall(.{ .args = args }) catch return self.popError();
        return null;
    }

    fn popError(self: *Runtime) ?[]u8 {
        defer self.lua.pop(1);
        const msg = self.lua.toString(-1) catch "error object is not a string";
        return self.alloc.dupe(u8, msg) catch null;
    }

    fn problem(self: *Runtime, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.problems.append(self.alloc, line) catch self.alloc.free(line);
    }

    /// Lays the config's `keys` over the extensions' own bindings: an
    /// entry naming a command binds it (replacing whatever an extension
    /// put on that chord), and one naming a built-in action -- or `false`
    /// -- takes the chord back from an extension. A name that is neither
    /// a built-in action nor a command is a problem, the warning the
    /// config parse held back (`luaconf.scopedKeysNamed`).
    pub fn resolveKeys(self: *Runtime, named: []const actions.NamedOverride, plain: []const actions.Override) void {
        for (plain) |o| self.unbind(o.scope, o.chord);
        for (named) |n| {
            self.unbind(n.scope, n.chord);
            const cmd = self.find(n.name) orelse {
                var buf: [64]u8 = undefined;
                self.problem("keys.{t}[\"{s}\"] = \"{s}\": unknown action or command; ignored", .{ n.scope, n.chord.format(&buf), n.name });
                continue;
            };
            self.bindings.append(self.alloc, .{ .scope = n.scope, .chord = n.chord, .command = cmd }) catch return;
        }
    }

    fn unbind(self: *Runtime, scope: actions.Scope, chord: keybind.Chord) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            const b = &self.bindings.items[i];
            if (b.scope == scope and b.chord.eql(&chord)) {
                _ = self.bindings.orderedRemove(i);
            } else i += 1;
        }
    }

    /// The command bound to the key in `scope`'s own table, without the
    /// fallback to `global` (the caller interleaves that with the
    /// built-in keymaps).
    pub fn lookup(self: *const Runtime, scope: actions.Scope, key: []const u8, mods: keybind.Mods) ?u32 {
        // Newest first: a later binding of the same chord wins.
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const b = &self.bindings.items[i];
            if (b.scope == scope and b.chord.matches(key, mods)) return b.command;
        }
        return null;
    }

    /// A chord that runs `command` in `scope`, or in `global` behind it,
    /// for the palette to show.
    pub fn chordFor(self: *const Runtime, scope: actions.Scope, command: u32) ?keybind.Chord {
        for ([_]actions.Scope{ scope, .global }) |s| {
            var i = self.bindings.items.len;
            while (i > 0) {
                i -= 1;
                const b = self.bindings.items[i];
                if (b.scope == s and b.command == command) return b.chord;
            }
        }
        return null;
    }

    pub fn find(self: *const Runtime, name: []const u8) ?u32 {
        for (self.commands.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Runs command `index`. Whatever it edited is one undo step per
    /// buffer; an error is put in the statusline as `<name>: <message>`.
    pub fn run(self: *Runtime, index: u32) void {
        const cmd = self.commands.items[index];
        _ = self.lua.rawGetIndex(ziglua.registry_index, cmd.ref);
        const err = self.protected(0);
        for (self.edited.items) |ed| ed.endScriptEdit();
        self.edited.clearRetainingCapacity();
        const msg = err orelse return;
        defer self.alloc.free(msg);
        var buf: [512]u8 = undefined;
        self.host.vtable.message(self.host.ctx, std.fmt.bufPrint(&buf, "{s}: {s}", .{ cmd.name, msg }) catch msg);
    }

    /// The editor a buffer call acts on, its undo step opened on first
    /// use in this command.
    fn editorForEdit(self: *Runtime) ?*Editor {
        const ed = self.host.vtable.editor(self.host.ctx) orelse return null;
        if (std.mem.indexOfScalar(*Editor, self.edited.items, ed) == null) {
            self.edited.append(self.alloc, ed) catch return null;
            ed.beginScriptEdit();
        }
        return ed;
    }
};

/// Extension names are file names, so no `/`, `.` or anything a shell
/// would make awkward.
pub fn validExtensionName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

/// Command names go into `keys` strings and the palette: an identifier,
/// dots allowed for a namespace (`journal.today`).
pub fn validCommandName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.') return false;
    }
    return true;
}

/// `<config dir>/zoe/extensions`, owned, or null with no config home.
pub fn userDir(alloc: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]u8 {
    const dir = glyphwire.configDirPath(alloc, environ) catch return null;
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "zoe", "extensions" }) catch null;
}

fn runtimeOf(lua: *Lua) *Runtime {
    return @as(*align(1) *Runtime, @ptrCast(lua.getExtraSpace().ptr)).*;
}

fn countHook(lua: *Lua, _: ziglua.Event, _: *ziglua.DebugInfo) void {
    const rt = runtimeOf(lua);
    rt.steps += 1;
    if (rt.steps > rt.step_limit / @as(u32, hook_every)) {
        rt.steps = 0;
        lua.raiseErrorStr("ran too long and was stopped", .{});
    }
}

// ── The `zoe` table ──────────────────────────────────────────────────
//
// Each function raises a Lua error rather than returning one, so a
// mistake stops the command and lands in the statusline. An error is
// raised from `entry`, after the function body (and its defers) have
// finished: Lua's error is a longjmp, which would skip them.

const api = [_]ziglua.FnReg{
    .{ .name = "command", .func = entry(apiCommand) },
    .{ .name = "bind", .func = entry(apiBind) },
    .{ .name = "line", .func = entry(apiLine) },
    .{ .name = "set_line", .func = entry(apiSetLine) },
    .{ .name = "line_count", .func = entry(apiLineCount) },
    .{ .name = "cursor", .func = entry(apiCursor) },
    .{ .name = "path", .func = entry(apiPath) },
    .{ .name = "open", .func = entry(apiOpen) },
    .{ .name = "message", .func = entry(apiMessage) },
    .{ .name = "expand", .func = entry(apiExpand) },
    .{ .name = "exists", .func = entry(apiExists) },
    .{ .name = "mkdir", .func = entry(apiMkdir) },
    .{ .name = "list_dir", .func = entry(apiListDir) },
};

const Raise = error{Raise};

fn entry(comptime f: fn (*Lua) Raise!i32) ziglua.CFn {
    return ziglua.wrap(struct {
        fn call(lua: *Lua) i32 {
            return f(lua) catch lua.raiseError();
        }
    }.call);
}

/// Pushes the error message `entry` raises.
fn fail(lua: *Lua, comptime fmt: []const u8, args: anytype) Raise {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    _ = lua.pushString(msg);
    return error.Raise;
}

fn str(lua: *Lua, arg: i32, comptime func: []const u8) Raise![]const u8 {
    if (lua.typeOf(arg) != .string) return fail(lua, "zoe." ++ func ++ ": argument {d} must be a string", .{arg});
    return lua.toString(arg) catch unreachable;
}

/// `zoe.command(name, fn [, label])`: registers a command.
fn apiCommand(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    if (rt.loading == null) return fail(lua, "zoe.command: only an extension loading may register commands", .{});
    const name = try str(lua, 1, "command");
    if (lua.typeOf(2) != .function) return fail(lua, "zoe.command: argument 2 must be a function", .{});
    const label: ?[]const u8 = switch (lua.typeOf(3)) {
        .none, .nil => null,
        .string => lua.toString(3) catch unreachable,
        else => return fail(lua, "zoe.command: argument 3 (the label) must be a string", .{}),
    };
    if (!validCommandName(name)) return fail(lua, "zoe.command: \"{s}\" is not a command name (letters, digits, _ and .)", .{name});
    if (std.meta.stringToEnum(actions.Action, name) != null) return fail(lua, "zoe.command: \"{s}\" is a built-in action", .{name});
    if (rt.find(name) != null) return fail(lua, "zoe.command: \"{s}\" is already registered", .{name});

    const name_owned = rt.alloc.dupe(u8, name) catch return fail(lua, "zoe.command: out of memory", .{});
    errdefer rt.alloc.free(name_owned);
    const label_owned: ?[]const u8 = if (label) |l| rt.alloc.dupe(u8, l) catch return fail(lua, "zoe.command: out of memory", .{}) else null;
    errdefer if (label_owned) |l| rt.alloc.free(l);
    lua.pushValue(2);
    const ref = lua.ref(ziglua.registry_index) catch return fail(lua, "zoe.command: couldn't keep the function", .{});
    rt.commands.append(rt.alloc, .{ .name = name_owned, .label = label_owned, .ref = ref }) catch
        return fail(lua, "zoe.command: out of memory", .{});
    return 0;
}

/// `zoe.bind(scope, chord, name)`: the extension's own binding for one
/// of its commands; the config's `keys` override it.
fn apiBind(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    if (rt.loading == null) return fail(lua, "zoe.bind: only an extension loading may bind keys", .{});
    const scope_name = try str(lua, 1, "bind");
    const chord_text = try str(lua, 2, "bind");
    const name = try str(lua, 3, "bind");
    const scope = std.meta.stringToEnum(actions.Scope, scope_name) orelse
        return fail(lua, "zoe.bind: \"{s}\" is not a key table (global, normal, visual, insert)", .{scope_name});
    const chord = keybind.Chord.parse(chord_text) catch |err|
        return fail(lua, "zoe.bind: \"{s}\": {t}", .{ chord_text, err });
    const cmd = rt.find(name) orelse return fail(lua, "zoe.bind: no command \"{s}\"", .{name});
    rt.bindings.append(rt.alloc, .{ .scope = scope, .chord = chord, .command = cmd }) catch
        return fail(lua, "zoe.bind: out of memory", .{});
    return 0;
}

fn focusedEditor(lua: *Lua, comptime func: []const u8) Raise!*Editor {
    const rt = runtimeOf(lua);
    return rt.host.vtable.editor(rt.host.ctx) orelse fail(lua, "zoe." ++ func ++ ": no text buffer has the focus", .{});
}

/// A 1-based line number argument as a 0-based line, or the cursor's
/// line when it is absent.
fn lineArg(lua: *Lua, ed: *Editor, arg: i32, comptime func: []const u8) Raise!usize {
    switch (lua.typeOf(arg)) {
        .none, .nil => return ed.buf.lineAt(ed.cursor),
        .number => {},
        else => return fail(lua, "zoe." ++ func ++ ": the line number must be a number", .{}),
    }
    const n = lua.toInteger(arg) catch return fail(lua, "zoe." ++ func ++ ": the line number must be a whole number", .{});
    const count = ed.buf.lineCount();
    if (n < 1 or n > count) return fail(lua, "zoe." ++ func ++ ": line {d} is outside 1..{d}", .{ n, count });
    return @intCast(n - 1);
}

/// `zoe.line([n])`: line `n`'s text (the cursor's line by default),
/// without its newline.
fn apiLine(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    const ed = try focusedEditor(lua, "line");
    const line = try lineArg(lua, ed, 1, "line");
    const text = ed.buf.lineText(rt.alloc, line) catch return fail(lua, "zoe.line: out of memory", .{});
    defer rt.alloc.free(text);
    _ = lua.pushString(text);
    return 1;
}

/// `zoe.set_line([n,] text)`: replaces line `n` (the cursor's by
/// default). One line in, one line out: `text` may not hold a newline.
fn apiSetLine(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    _ = try focusedEditor(lua, "set_line");
    const text_arg: i32 = if (lua.getTop() >= 2) 2 else 1;
    const text = try str(lua, text_arg, "set_line");
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return fail(lua, "zoe.set_line: the text may not contain a line break", .{});
    const ed = rt.editorForEdit() orelse return fail(lua, "zoe.set_line: out of memory", .{});
    const line = if (text_arg == 2) try lineArg(lua, ed, 1, "set_line") else ed.buf.lineAt(ed.cursor);
    ed.setLineText(line, text) catch return fail(lua, "zoe.set_line: out of memory", .{});
    return 0;
}

/// `zoe.line_count()`.
fn apiLineCount(lua: *Lua) Raise!i32 {
    const ed = try focusedEditor(lua, "line_count");
    lua.pushInteger(@intCast(ed.buf.lineCount()));
    return 1;
}

/// `zoe.cursor()`: the cursor's 1-based line and byte column.
fn apiCursor(lua: *Lua) Raise!i32 {
    const ed = try focusedEditor(lua, "cursor");
    const p = ed.buf.posOf(ed.cursor);
    lua.pushInteger(@intCast(p.line + 1));
    lua.pushInteger(@intCast(p.col + 1));
    return 2;
}

/// `zoe.path()`: the focused buffer's file as an absolute path, or nil
/// (unnamed, or the keyboard is not in a buffer).
fn apiPath(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    const ed = rt.host.vtable.editor(rt.host.ctx) orelse {
        lua.pushNil();
        return 1;
    };
    const p = ed.path orelse {
        lua.pushNil();
        return 1;
    };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = lua.pushString(homepath.absoluteBuf(rt.io, p, &buf) orelse p);
    return 1;
}

/// `zoe.open(path)`: opens `path` (`~` expanded) in a tab, or switches
/// to it. A file that doesn't exist yet opens empty, as `:e` does.
fn apiOpen(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    const path = try str(lua, 1, "open");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = homepath.expandHome(path, rt.home, &buf);
    rt.host.vtable.open(rt.host.ctx, full) catch |err| return fail(lua, "zoe.open: {s}: {t}", .{ full, err });
    return 0;
}

/// `zoe.message(text)`: puts `text` in the statusline.
fn apiMessage(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    const text = try str(lua, 1, "message");
    rt.host.vtable.message(rt.host.ctx, text);
    return 0;
}

/// `zoe.expand(path)`: `path` with a leading `~` made `$HOME`.
fn apiExpand(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    const path = try str(lua, 1, "expand");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = lua.pushString(homepath.expandHome(path, rt.home, &buf));
    return 1;
}

/// `zoe.exists(path)`: whether anything is at `path`.
fn apiExists(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    const path = try str(lua, 1, "exists");
    _ = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch {
        lua.pushBoolean(false);
        return 1;
    };
    lua.pushBoolean(true);
    return 1;
}

/// `zoe.mkdir(path)`: creates `path` and any missing parents. True, or
/// nil and the error's name.
fn apiMkdir(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    const path = try str(lua, 1, "mkdir");
    std.Io.Dir.cwd().createDirPath(rt.io, path) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    lua.pushBoolean(true);
    return 1;
}

/// `zoe.list_dir(path)`: the names in directory `path`, sorted, as a
/// list -- files and directories alike, `.` and `..` left out. Nil and
/// the error's name when it can't be read.
fn apiListDir(lua: *Lua) Raise!i32 {
    const rt = runtimeOf(lua);
    const path = try str(lua, 1, "list_dir");
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| rt.alloc.free(n);
        names.deinit(rt.alloc);
    }
    readDirNames(rt, path, &names) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    lua.createTable(@intCast(names.items.len), 0);
    for (names.items, 1..) |n, i| {
        _ = lua.pushString(n);
        lua.rawSetIndex(-2, @intCast(i));
    }
    return 1;
}

fn readDirNames(rt: *Runtime, path: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(rt.io, path, .{ .iterate = true });
    defer dir.close(rt.io);
    var it = dir.iterate();
    while (try it.next(rt.io)) |e| {
        const name = try rt.alloc.dupe(u8, e.name);
        out.append(rt.alloc, name) catch |err| {
            rt.alloc.free(name);
            return err;
        };
    }
}
