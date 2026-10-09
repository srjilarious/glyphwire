// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-shell's builtins: `cd`, `zj`, `alias`/`unalias`, `export`/`unset`/`env`,
//! `jobs`/`fg`, `gwssh` and `reload`, plus `runBuiltin`, which dispatches
//! them. Each is a `Prompt` method moved out of main.zig; `Prompt` aliases
//! them back, so `self.doCd(..)` still reads as a method call.

const std = @import("std");
const glyphwire = @import("glyphwire");
const wordsplit = @import("applib").wordsplit;
const envassign = @import("shell_support").envassign;
const homepath = @import("applib").homepath;
const zjump = @import("applib").zjump;
const logicalpath = @import("shell_support").logicalpath;
const remotecmd = @import("shell_support").remotecmd;

const main = @import("main.zig");
const Prompt = main.Prompt;
const c = main.c;
const drainResizes = main.drainResizes;
const err_color = main.err_color;
const provisioned_agent_path = main.provisioned_agent_path;
const zjExistsProbe = main.zjExistsProbe;

/// Alias store backing the prompt's `alias`/`unalias` builtins. Seeded at
/// startup from `~/.config/glyphwire/shell.conf.lua`'s `alias(name, value)`
/// calls (see `Prompt.loadStartupConfig`), then mutated for the rest of
/// the session by the builtins; nothing here is written back to disk, so
/// a session-only `alias` doesn't survive `exit`. Keys and values are
/// owned dups; `Prompt.deinit` frees the whole table.
pub const AliasTable = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *AliasTable, alloc: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        self.map.deinit(alloc);
    }

    /// Binds `name` to `value`, replacing (and freeing) any prior binding
    /// for `name`.
    pub fn set(self: *AliasTable, alloc: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const key = try alloc.dupe(u8, name);
        errdefer alloc.free(key);
        const val = try alloc.dupe(u8, value);
        errdefer alloc.free(val);

        const gop = try self.map.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            alloc.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val;
    }

    /// Removes `name`'s binding; returns whether there was one to remove.
    pub fn remove(self: *AliasTable, alloc: std.mem.Allocator, name: []const u8) bool {
        if (self.map.fetchRemove(name)) |kv| {
            alloc.free(kv.key);
            alloc.free(kv.value);
            return true;
        }
        return false;
    }

    pub fn get(self: *const AliasTable, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }
};

pub fn isBuiltinName(self: *Prompt, name: []const u8) bool {
    if (std.mem.eql(u8, name, "exit") or std.mem.eql(u8, name, "unalias") or
        std.mem.eql(u8, name, "cd") or std.mem.eql(u8, name, "alias") or
        std.mem.eql(u8, name, "export") or std.mem.eql(u8, name, "unset") or
        std.mem.eql(u8, name, "zj") or std.mem.eql(u8, name, "gwssh") or
        std.mem.eql(u8, name, "reload") or std.mem.eql(u8, name, "jobs") or
        std.mem.eql(u8, name, "fg")) return true;
    if (self.script_engine) |eng| return eng.hasCommand(name);
    return false;
}

/// Dispatches a builtin that is the sole stage of its pipeline. `cd` /
/// `unalias` report their own errors onto the grid and are treated as
/// status 0 here; `alias` mid-chain isn't supported (its rest-of-line
/// value is already gone by parse time).
pub fn runBuiltin(self: *Prompt, argv: []const []const u8) !u8 {
    if (std.mem.eql(u8, argv[0], "exit")) {
        self.should_exit = true;
        return 0;
    }
    if (std.mem.eql(u8, argv[0], "unalias")) {
        try self.doUnalias(argv[1..]);
        return 0;
    }
    if (std.mem.eql(u8, argv[0], "cd")) {
        try self.doCd(argv[1..]);
        return 0;
    }
    if (std.mem.eql(u8, argv[0], "export")) {
        return self.doExport(argv[1..]);
    }
    if (std.mem.eql(u8, argv[0], "unset")) {
        return self.doUnset(argv[1..]);
    }
    if (std.mem.eql(u8, argv[0], "zj")) {
        try self.doZj(argv[1..]);
        return 0;
    }
    if (std.mem.eql(u8, argv[0], "gwssh")) {
        return self.doGwssh(argv[1..]);
    }
    if (std.mem.eql(u8, argv[0], "reload")) {
        return self.doReload(argv[1..]);
    }
    if (std.mem.eql(u8, argv[0], "jobs")) {
        return self.doJobs();
    }
    if (std.mem.eql(u8, argv[0], "fg")) {
        return self.doFg(argv[1..]);
    }
    if (std.mem.eql(u8, argv[0], "alias")) {
        try self.drawText("alias: only supported as a standalone command", err_color, null);
        return 2;
    }
    if (self.script_engine) |eng| {
        if (eng.hasCommand(argv[0])) return eng.runCommand(argv[0], argv[1..]);
    }
    return 127;
}

/// If `argv[0]` names a script builtin (a `defcmd` registration or a
/// `~/.config/glyphwire/scripts/<name>.lua`), runs it in-process and
/// returns true, recording its exit status the same way an external
/// command's is. Returns false -- untouched -- when there's no engine
/// or no such builtin, so dispatch falls through to `$PATH`.
pub fn runScriptBuiltin(self: *Prompt, argv: []const []const u8) bool {
    const eng = self.script_engine orelse return false;
    if (!eng.hasCommand(argv[0])) return false;
    const code = eng.runCommand(argv[0], argv[1..]);
    self.last_status = code;
    self.last_dur_ms = 0;
    self.have_status = true;
    return true;
}

/// `jobs`: one line per background job, `[n] title`, newest last.
pub fn doJobs(self: *Prompt) !u8 {
    self.reportFinishedJobs();
    for (self.jobs.items) |job| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[{d}] {s}\n", .{ job.id, self.jobTitle(job) }) catch continue;
        try self.drawText(msg, null, null);
    }
    return 0;
}

/// `fg [n]` (`%n` also accepted): brings a background job's screen
/// back and gives it the keyboard again, until it exits or is put in
/// the background once more. With no argument, the newest job.
pub fn doFg(self: *Prompt, args: []const []const u8) !u8 {
    self.reportFinishedJobs();
    if (self.jobs.items.len == 0) {
        try self.drawText("fg: no current job", err_color, null);
        return 1;
    }
    const index: usize = if (args.len == 0) self.jobs.items.len - 1 else blk: {
        const spec = std.mem.trimStart(u8, args[0], "%");
        const id = std.fmt.parseInt(u32, spec, 10) catch {
            try self.drawText("fg: usage: fg [n]", err_color, null);
            return 2;
        };
        for (self.jobs.items, 0..) |job, i| {
            if (job.id == id) break :blk i;
        }
        var buf: [64]u8 = undefined;
        try self.drawText(std.fmt.bufPrint(&buf, "fg: {d}: no such job", .{id}) catch "fg: no such job", err_color, null);
        return 1;
    };
    const job = self.jobs.items[index];
    const ctx = job.context orelse {
        try self.drawText("fg: that job has no screen to bring back", err_color, null);
        return 1;
    };
    _ = self.jobs.orderedRemove(index);
    self.client.activateContext(ctx) catch {};

    switch (self.foregroundJob(job)) {
        .exited => {
            // Put in the background partway through a line: the rest of
            // it runs now, against the job's status, and its outcome is
            // what `fg` reports.
            var rest = job.rest;
            job.rest = null;
            self.finishForegroundJob(job);
            if (rest) |*r| {
                defer r.deinit();
                return self.runContinuation(r.segments, self.last_status);
            }
            return self.last_status;
        },
        .backgrounded => {
            try self.parkJob(job);
            return 0;
        },
    }
}

/// `cd` is a shell builtin, not a spawned program -- unlike
/// `runCommand`, changing directory in a *child* process wouldn't
/// affect this one, so it has to happen here directly. No args (or a
/// bare `~`) goes to `$HOME`, matching a real shell; a bad path or
/// missing `$HOME` is reported onto the grid the same way
/// `runCommand` reports a spawn failure, rather than propagated.
pub fn doCd(self: *Prompt, args: []const []const u8) !void {
    const alloc = self.client.alloc;
    const raw_target: []const u8 = if (args.len > 0) args[0] else "~";

    const target = self.expandTilde(raw_target) catch {
        try self.drawText("cd: HOME not set", err_color, null);
        return;
    };
    defer if (target.ptr != raw_target.ptr) alloc.free(target);

    self.chdir(target) catch |err| try self.reportCdError(target, err);
}

/// Changes the shell's working directory to `target` (already
/// tilde-expanded) and, on success, records the new directory as a
/// `zj` visit. Every directory change funnels through here -- an
/// interactive `cd`, a `zj` jump, a script's `sh.chdir` -- so a visit
/// is recorded exactly once per change and in exactly one place. The
/// `openDir` / `setCurrentDir` error is returned unreported: `cd` and
/// `zj` word their failure messages differently.
///
/// Also maintains `$PWD`/`$OLDPWD` the way bash/fish do: `$PWD` is
/// built by joining `target` onto the *previous* `$PWD`
/// (`logicalpath.resolve`) -- lexical `.`/`..` collapsing, no
/// filesystem lookups -- so a linked directory keeps its own name
/// instead of expanding to whatever it points at.
///
/// Critically, the actual `chdir(2)` targets that computed logical
/// path, not the raw `target` -- otherwise the two would drift apart
/// the moment a `..` follows a symlink hop. E.g. from
/// `/home/j/temp/pics` (`pics -> /home/j/Pictures`), `cd ..`'s literal
/// kernel `..` is relative to the *physical* cwd, landing in
/// `/home/j` -- one level up from the symlink target, not from the
/// symlink itself -- while the lexical `$PWD` computation says
/// `/home/j/temp`. Real bash avoids exactly this split by `chdir`ing
/// to its own computed logical path rather than the typed argument;
/// doing the same here keeps the process's real cwd and the displayed
/// `$PWD` in agreement, at the cost of a `cd` that fails outright
/// (rather than silently landing somewhere else) if the lexical
/// collapse ever names a path that doesn't itself exist -- no `cd -P`
/// physical mode is offered as a fallback for that case.
///
/// `recordVisit` (the `zj` frecency database) intentionally keeps
/// using the real physical cwd, not this logical one, so two
/// different links to the same real directory accumulate one
/// ranking, not two.
pub fn chdir(self: *Prompt, target: []const u8) !void {
    const io = self.client.io;
    const alloc = self.client.alloc;

    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_pwd = self.logicalCwd(&old_buf);
    const new_pwd = try logicalpath.resolve(alloc, old_pwd, target);
    defer alloc.free(new_pwd);

    var dir = try std.Io.Dir.cwd().openDir(io, new_pwd, .{});
    defer dir.close(io);
    try std.process.setCurrentDir(io, dir);

    self.setEnvVar("OLDPWD", old_pwd);
    self.setEnvVar("PWD", new_pwd);

    self.recordVisit();
    self.queueChdirListing();
}

/// After a successful directory change, decides whether the
/// `on{ chdir = { command = ... } }` listing should run once the
/// current line finishes dispatching, per the configured `list` mode:
/// `off` never, `always` for any change, `metadata` only when
/// `chdir_method == .metadata` (a directory activated in gw-ls
/// output). `submitLine` picks `chdir_pending_list` up and runs it.
pub fn queueChdirListing(self: *Prompt) void {
    const cfg = self.prompt_config orelse return;
    const oc = cfg.on.chdir;
    const fire = switch (oc.list) {
        .off => false,
        .always => true,
        .metadata => self.chdir_method == .metadata,
    };
    if (!fire or oc.command.len == 0) return;
    self.chdir_pending_list = oc.command;
}

/// Records the shell's current directory (post-`chdir`) in the `zj`
/// database. A no-op when `zj` is disabled or unavailable. `$HOME`
/// and `/` are skipped on purpose -- both are a single keystroke away
/// without any help (`zj` with no argument, `cd /`) and would only
/// crowd the rankings -- as is anything under a configured
/// `exclude_dirs` entry.
pub fn recordVisit(self: *Prompt) void {
    if (!self.zj_enabled) return;
    if (self.zdb == null) return;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(self.client.io, &buf) catch return;
    const cwd = buf[0..n];

    if (self.environ_map.get("HOME")) |home| {
        if (std.mem.eql(u8, cwd, home)) return;
    }
    if (std.mem.eql(u8, cwd, "/")) return;
    if (zjump.isExcluded(cwd, self.zj_excludes)) return;

    const now = self.nowSecs();
    self.zdb.?.record(cwd, now) catch return;
    // Also as a delta, for the flush to replay onto the re-read file
    // -- see `zdb_journal`.
    if (self.zdb_journal) |*j| j.recordVisit(cwd, now) catch return;
    self.zdb_dirty = true;
    self.persist_gate.note();
}

/// `gwssh <dest>` -- drop this pane into a remote session.
///
/// The host does the work (`start_remote`): it spawns `ssh`, surfaces
/// its auth prompts on the grid, and turns the trunk's channels back
/// into connections, so the remote `gw-shell` draws into this pane
/// exactly as this one does. What is left here is the waiting, and the
/// waiting is the point -- this shell is not replaced. It sits behind
/// the session and has the pane back the moment it ends, the way it
/// sits behind `ssh` in an ordinary terminal.
///
/// A builtin rather than a program because the thing that has to be
/// seated in the pane is *this process's* connection: a child would
/// hand over its own pane binding, not ours.
pub fn doGwssh(self: *Prompt, args: []const []const u8) !u8 {
    const spec = remotecmd.parse(args) catch |err| {
        try self.drawText(remotecmd.errorText(err), err_color, null);
        return 2;
    };

    const listener = self.listener orelse {
        try self.drawText("gwssh: no interactive session", err_color, null);
        return 1;
    };

    const session = self.client.startRemote(spec.dest, spec.ssh_args, self.remoteAgentCommand(spec)) catch |err| {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gwssh: {s}: {t}", .{ spec.dest, err }) catch "gwssh: could not start remote session";
        try self.drawText(msg, err_color, null);
        return 1;
    };

    const outcome = self.waitOutRemote(listener, session);

    // The remote shell left its own output on this pane's grid, and
    // may have resized it; the caller's prompt redraw picks up from
    // wherever that ended, like returning from any foreground program.
    drainResizes(listener, self);
    if (!outcome.started) try self.reportRemoteFailure(spec, outcome.status);
    self.last_status = outcome.status;
    self.have_status = true;
    return outcome.status;
}

/// The far-side agent command: `--remote-command` if given, else
/// `$GLYPHWIRE_REMOTE_COMMAND`, else null (the host's own `gw-agent`
/// default).
///
/// The variable exists because the default only works when `gw-agent`
/// is on the remote box's `PATH` -- and a non-login `ssh -T` session
/// has a minimal one, which misses a work tree's `zig-out/bin`
/// entirely. Setting it once beats retyping `--remote-command` on
/// every connection.
pub fn remoteAgentCommand(self: *Prompt, spec: remotecmd.Spec) ?[]const u8 {
    if (spec.remote_command) |cmd| return cmd;
    const from_env = self.env.get("GLYPHWIRE_REMOTE_COMMAND") orelse return null;
    return if (from_env.len == 0) null else from_env;
}

/// Says why a session that never connected didn't, in the pane.
/// Without this the only evidence is a line `ssh` wrote to the
/// *host's* stderr, which is not where anyone running `gwssh` is
/// looking.
///
/// Only for a session that never came up. A remote shell that ran and
/// exited non-zero is left to speak for itself, exactly as `ssh`
/// leaves it: the status is in `$?` and `{exit}` already.
///
/// 127 is singled out because it is both the likeliest failure and the
/// least self-explanatory -- `ssh` passes the remote command's status
/// through, so "no `gw-agent` on that box's PATH" arrives as a bare
/// 127.
pub fn reportRemoteFailure(self: *Prompt, spec: remotecmd.Spec, status: u8) !void {
    var buf: [512]u8 = undefined;
    const msg = if (status == 127)
        std.fmt.bufPrint(
            &buf,
            "gwssh: {s}: no '{s}' there. provision_remote installs it at {s}; pass that with --remote-command, or set GLYPHWIRE_REMOTE_COMMAND.",
            .{ spec.dest, self.remoteAgentCommand(spec) orelse "gw-agent", provisioned_agent_path },
        ) catch "gwssh: the remote agent was not found"
    else
        std.fmt.bufPrint(&buf, "gwssh: {s}: could not connect (ssh exited {d})", .{ spec.dest, status }) catch
            "gwssh: could not connect";
    try self.drawText(msg, err_color, null);
}

/// Parks until the remote session `session` ends, keeping this
/// connection quiet while it runs.
///
/// Quiet is the whole job. Both shells are attached to the same pane,
/// so both are handed every keystroke while it has focus (see
/// `Server.broadcast`) -- exactly the situation the pty foreground
/// loop is already in with a glyphwire-aware child. Draining and
/// dropping is what keeps this shell from echoing over the remote
/// one's screen, and keeps `InputListener`'s queues from filling.
///
/// Ctrl-C asks the host to tear the session down rather than returning
/// here, so the pane is never left with an orphaned `ssh` drawing into
/// it; the loop still exits on the `remote_exit` that follows.
pub const RemoteOutcome = struct {
    status: u8,
    /// False when the session never connected at all -- the only
    /// thing that distinguishes that from a remote shell exiting with
    /// the same status. See `protocol.RemoteExitParams.started`.
    started: bool,
};

pub fn waitOutRemote(self: *Prompt, listener: *glyphwire.InputListener, session: u64) RemoteOutcome {
    const alloc = self.client.alloc;
    while (true) {
        while (listener.pollRemoteExitEvent()) |ev| {
            if (ev.session != session) continue;
            return .{
                .status = std.math.cast(u8, ev.status) orelse 1,
                .started = ev.started,
            };
        }

        // The wait is woken by `remote_exit` itself; the timeout is
        // only a floor on how long a missed wake-up could cost.
        const ev = (listener.waitInputEvent(.{
            .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake },
        }) catch null) orelse continue;

        switch (ev) {
            .key => |kev| {
                defer alloc.free(kev.key);
                if (kev.pressed and kev.ctrl() and std.mem.eql(u8, kev.key, "c")) {
                    self.client.stopRemote(session) catch {};
                }
            },
            .text => |tev| alloc.free(tev.text),
            .paste => |tev| alloc.free(tev.text),
            .copy_request => {},
            // Host window closing: end the session and let the caller
            // flush and exit, the same as a foregrounded child.
            .shutdown => {
                self.should_exit = true;
                self.client.stopRemote(session) catch {};
                // `started: true` -- the window closing is not a
                // connection failure, and there is nothing to report
                // into a pane that is going away.
                return .{ .status = 1, .started = true };
            },
            // A window manager's own commands (see
            // `InputEvent.window_key`). Never delivered here.
            .window_key => |kev| alloc.free(kev.key),
            .window_text => |tev| alloc.free(tev.text),
        }
    }
}

/// `zj [QUERY...]` -- the directory-jump builtin. Bare `zj` goes to
/// `$HOME`; a single argument that is itself an existing directory
/// acts like `cd` (so `zj ../sibling` and `zj ./build` still work);
/// otherwise every argument is a query term matched against the `zj`
/// database and the best-ranked directory wins. A jump target that
/// has since disappeared is pruned and reported.
pub fn doZj(self: *Prompt, args: []const []const u8) !void {
    const alloc = self.client.alloc;

    if (self.zdb == null) {
        try self.drawText("zj: directory database unavailable", err_color, null);
        return;
    }

    if (args.len == 0) {
        const home = self.environ_map.get("HOME") orelse {
            try self.drawText("zj: HOME not set", err_color, null);
            return;
        };
        self.chdir(home) catch |err| try self.reportZjError(home, err);
        return;
    }

    if (args.len == 1) {
        const expanded = self.expandTilde(args[0]) catch args[0];
        defer if (expanded.ptr != args[0].ptr) alloc.free(expanded);
        if (self.dirExists(expanded)) {
            self.chdir(expanded) catch |err| try self.reportZjError(expanded, err);
            return;
        }
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd: ?[]const u8 = if (std.process.currentPath(self.client.io, &buf)) |n| buf[0..n] else |_| null;

    const hit = self.zdb.?.bestMatch(args, self.nowSecs(), .{
        .cwd = cwd,
        .exclude = self.zj_excludes,
        .exists = zjExistsProbe,
        .exists_ctx = self,
    }) orelse {
        const joined = try std.mem.join(alloc, " ", args);
        defer alloc.free(joined);
        var msg: [320]u8 = undefined;
        const line = std.fmt.bufPrint(&msg, "zj: no match for '{s}'", .{joined}) catch "zj: no match";
        try self.drawText(line, err_color, null);
        return;
    };

    // `bestMatch` hands back a slice borrowed from the database, and
    // `chdir` then records into (mutates) it -- and a failure prunes
    // the entry. Copy the path out before either can move it.
    const target = try alloc.dupe(u8, hit);
    defer alloc.free(target);

    self.chdir(target) catch |err| {
        self.zdb.?.remove(target);
        if (self.zdb_journal) |*j| j.recordForget(target) catch {};
        self.zdb_dirty = true;
        try self.reportZjError(target, err);
    };
}

pub fn reportZjError(self: *Prompt, target: []const u8, err: anyerror) !void {
    var buf: [320]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zj: {s}: {t}", .{ target, err }) catch "zj: jump failed";
    try self.drawText(msg, err_color, null);
}

/// Whether `path` opens as a directory. Used by `zj`'s "single
/// existing-dir argument acts like cd" shortcut and, via
/// `zjExistsProbe`, to filter vanished entries out of a match.
pub fn dirExists(self: *Prompt, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(self.client.io, path, .{}) catch return false;
    d.close(self.client.io);
    return true;
}

/// Expands a leading `~` to `$HOME` -- bare `~` or `~/rest`; `~user`
/// (another account's home directory) isn't supported, matching how
/// most shells treat that as a rarer case not worth the lookup here.
/// Returns `target` itself (same pointer) when there's nothing to
/// expand, so `doCd` knows whether the result needs freeing.
pub fn expandTilde(self: *Prompt, target: []const u8) ![]const u8 {
    if (!homepath.isHomeRelative(target)) return target;
    const home = self.environ_map.get("HOME") orelse return error.HomeNotSet;
    return homepath.expandHomeAlloc(self.client.alloc, target, home);
}

pub fn reportCdError(self: *Prompt, target: []const u8, err: anyerror) !void {
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "cd: {s}: {t}", .{ target, err }) catch "cd: failed";
    try self.drawText(msg, err_color, null);
}

/// `alias` builtin. Given a `NAME=VALUE` argument
/// (`wordsplit.parseAliasDef` -- rest-of-line value, one binding per
/// line), records the binding; a bare `alias` lists every current
/// binding, one `NAME='VALUE'` per row sorted by name, matching
/// bash's output shape. Takes the raw prompt line because the value
/// is not word-split.
pub fn doAlias(self: *Prompt, line: []const u8) !void {
    const alloc = self.client.alloc;
    if (wordsplit.parseAliasDef(line)) |def| {
        try self.aliases.set(alloc, def.name, def.value);
        return;
    }
    try self.listAliases();
}

pub fn listAliases(self: *Prompt) !void {
    const alloc = self.client.alloc;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    var it = self.aliases.map.iterator();
    while (it.next()) |e| try names.append(alloc, e.key_ptr.*);

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (names.items) |name| {
        const value = self.aliases.get(name).?;
        var buf: [1024]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, "alias {s}='{s}'\n", .{ name, value }) catch continue;
        try self.drawText(rendered, null, null);
    }
}

/// `unalias NAME...` builtin. A name with no current binding is
/// reported onto the grid (bash-style) rather than propagated as an
/// error.
pub fn doUnalias(self: *Prompt, names: []const []const u8) !void {
    const alloc = self.client.alloc;
    for (names) |name| {
        if (!self.aliases.remove(alloc, name)) {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "unalias: {s}: not found", .{name}) catch "unalias: not found";
            try self.drawText(msg, err_color, null);
        }
    }
}

/// Sets `name` to `value` in this process's libc environment (so
/// children spawned afterwards inherit it -- `pty.zig` / `pipeexec`
/// both `execvp` against the live environ) and in `Prompt.env`, the
/// overlay `{env:NAME}` renders from. The mirror of `sh.setenv`;
/// `name` must already be a valid identifier (`envassign.validName`).
pub fn setEnvVar(self: *Prompt, name: []const u8, value: []const u8) void {
    const alloc = self.client.alloc;
    const name_z = std.mem.concatWithSentinel(alloc, u8, &.{name}, 0) catch return;
    defer alloc.free(name_z);
    const value_z = std.mem.concatWithSentinel(alloc, u8, &.{value}, 0) catch return;
    defer alloc.free(value_z);
    _ = c.setenv(name_z, value_z, 1);
    self.env.put(name, value) catch {};
}

/// Removes `name` from the libc environment and `Prompt.env`. The
/// mirror of `sh.unsetenv`.
pub fn unsetEnvVar(self: *Prompt, name: []const u8) void {
    const alloc = self.client.alloc;
    const name_z = std.mem.concatWithSentinel(alloc, u8, &.{name}, 0) catch return;
    defer alloc.free(name_z);
    _ = c.unsetenv(name_z);
    _ = self.env.swapRemove(name);
}

/// `export` builtin. No args -> print every variable as `NAME=VALUE`,
/// sorted. `export NAME=VALUE` -> set it (`$NAME` / `${NAME}` and a
/// leading `~` in VALUE are expanded against the current environment;
/// see `envassign`). `export NAME` with no `=` -> ensure NAME exists
/// (created empty if unset), since this shell keeps a single
/// environment and has no separate "not yet exported" state. An
/// invalid name is reported and makes the builtin's status 1.
pub fn doExport(self: *Prompt, args: []const []const u8) !u8 {
    const alloc = self.client.alloc;

    if (args.len == 0) {
        try self.printEnv();
        return 0;
    }

    var status: u8 = 0;
    for (args) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const name = arg[0..eq];
            if (!envassign.validName(name)) {
                try self.reportBadEnvName("export", arg);
                status = 1;
                continue;
            }
            const value = envassign.expandValue(alloc, arg[eq + 1 ..], &self.env) catch {
                status = 1;
                continue;
            };
            defer alloc.free(value);
            self.setEnvVar(name, value);
        } else {
            if (!envassign.validName(arg)) {
                try self.reportBadEnvName("export", arg);
                status = 1;
                continue;
            }
            if (self.env.get(arg) == null) self.setEnvVar(arg, "");
        }
    }
    return status;
}

/// `unset NAME...` builtin. Removes each name; an unset name is not an
/// error (bash). An invalid name is reported and makes the status 1.
pub fn doUnset(self: *Prompt, names: []const []const u8) !u8 {
    var status: u8 = 0;
    for (names) |name| {
        if (!envassign.validName(name)) {
            try self.reportBadEnvName("unset", name);
            status = 1;
            continue;
        }
        self.unsetEnvVar(name);
    }
    return status;
}

pub fn reportBadEnvName(self: *Prompt, comptime builtin: []const u8, name: []const u8) !void {
    var buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, builtin ++ ": `{s}`: not a valid variable name", .{name}) catch
        builtin ++ ": not a valid variable name";
    try self.drawText(msg, err_color, null);
}

/// Writes the whole environment to the grid, one `NAME=VALUE` per
/// line, name-sorted -- `export` with no arguments.
pub fn printEnv(self: *Prompt) !void {
    const alloc = self.client.alloc;

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| alloc.free(l);
        lines.deinit(alloc);
    }

    var it = self.env.iterator();
    while (it.next()) |entry| {
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}\n", .{
            entry.key_ptr.*,
            entry.value_ptr.*,
        }));
    }

    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (lines.items) |l| try self.drawText(l, null, null);
}

/// `reload` builtin -- re-reads `shell.conf.lua` and applies it to the
/// running shell, so editing the config doesn't need a restart.
///
/// The conf re-runs in the *same* Lua state: `defcmd` registrations,
/// globals a script built up and anything `sh.setenv` changed all
/// survive, which is what a source-style reload should do. What does
/// not survive is the parsed config -- it is reset rather than merged
/// into (see `config.ShellConfig.reset`), or a `prompt{}` key or
/// `open_actions` entry deleted from the file would keep its old value
/// until the next restart. The alias table goes the same way, wiped
/// and reseeded from the conf, so a deleted `alias` line really goes
/// away; the price is that aliases typed interactively this session go
/// with it.
///
/// Everything outside the config file is untouched: cwd, environment,
/// history and the `zj` database all carry on.
pub fn doReload(self: *Prompt, args: []const []const u8) !u8 {
    const alloc = self.client.alloc;

    if (args.len > 0) {
        try self.drawText("reload: takes no arguments\n", err_color, null);
        return 2;
    }

    const config_dir = self.config_dir orelse {
        try self.drawText("reload: no config directory ($HOME and $XDG_CONFIG_HOME are unset)\n", err_color, null);
        return 1;
    };
    const eng = self.script_engine orelse {
        try self.drawText("reload: the script engine isn't running\n", err_color, null);
        return 1;
    };

    // Read the file *before* touching anything live, so a config that
    // has gone missing (or won't read) leaves the session exactly as
    // it was instead of wiping it.
    const source = self.readConfSource(config_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => {
            try self.drawText("reload: no shell.conf.lua to reload\n", err_color, null);
            return 1;
        },
        error.ReadFailed => {
            try self.drawText("reload: could not read shell.conf.lua\n", err_color, null);
            return 1;
        },
    };
    defer alloc.free(source);

    // A `cd` earlier on this same line (`cd /tmp && reload`) queues an
    // `on{ chdir }` listing that `submitLine` runs once dispatch
    // finishes. That queued string belongs to the config we're about
    // to throw away, so note that one is waiting and re-point it at
    // the reloaded command below rather than swallowing the listing.
    const listing_queued = self.chdir_pending_list != null;

    // Drop every borrow into the previous parse before the arena
    // backing it goes away: the memoised command-var values are keyed
    // by config-owned names, the queued listing *is* a config-owned
    // string, and `prompt_config` has to read as null across the reset
    // -- a resize arriving mid-reload then redraws the default prompt
    // instead of following a dangling pointer.
    self.prompt_config = null;
    self.resetCmdVars();
    self.chdir_pending_list = null;
    self.clearZjExcludes();
    // Back to the built-in default; the conf turns it off again if it
    // still says so.
    self.zj_enabled = true;
    self.aliases.deinit(alloc);
    self.aliases = .{};

    eng.cfg.reset();
    try eng.runConf(source);
    try self.applyConfig(eng);

    // The re-pointed listing (see above). An `on{ chdir }` the new conf
    // turned off leaves it dropped, which is the reloaded config
    // getting the last word.
    if (listing_queued and eng.cfg.on.chdir.command.len > 0) {
        self.chdir_pending_list = eng.cfg.on.chdir.command;
    }

    // `applyConfig` has already drawn the diagnostic in red -- no
    // "reloaded" line on top of it.
    if (eng.conf_err != null) return 1;

    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "reload: shell.conf.lua -- {d} aliases, {d} open actions\n", .{
        eng.cfg.aliases.items.len,
        eng.cfg.open_actions.items.len,
    }) catch "reload: shell.conf.lua\n";
    try self.drawText(line, null, null);
    return 0;
}
