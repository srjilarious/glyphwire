// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `zoe` -- a modal editor for glyphwire.
//!
//! Launched from a glyphwire-aware shell it connects to the display
//! server and runs the real UI (`ui.zig`): a file tree beside the buffer
//! with a statusline under both, laid out by a host-side split tree.
//! Launched from anywhere else -- no `GLYPHWIRE_SOCK` -- it falls back to
//! the headless driver, which replays a vim-notation key script against
//! the editor core and prints the result. That fallback is how the core
//! is exercised by hand and in CI, where there is no window.

const std = @import("std");
const glyphwire = @import("glyphwire");
const build_info = @import("build_info");
const zargs = @import("zargunaught");
const zoe = @import("zoe_support");
const interrupt = @import("applib").interrupt;
const homepath = @import("applib").homepath;
const cli = @import("applib").cli;
const workspace = zoe.workspace;
const remote = zoe.remote;

// const usage =
//     \\usage: zoe [--keys <script>] [--quiet] [file|directory]
//     \\
//     \\  --keys <script>  Headless: replay a vim-notation key script against
//     \\                   the buffer, e.g. 'ihello<esc>dd' or ':w<cr>'.
//     \\  --quiet          Headless: don't print the buffer afterwards.
//     \\
//     \\A directory argument changes into it (as `:cd` would) and starts on
//     \\the file tree with an empty buffer; anything else is a file to open.
//     \\
//     \\With GLYPHWIRE_SOCK set and no --keys, zoe opens its editor UI on the
//     \\glyphwire display server. Ctrl+W is vim's window prefix: then v or s
//     \\splits the editor into a new group beside or below (:vsplit / :split
//     \\[file]), each with its own tabs and a draggable divider; q closes a
//     \\group (:close) and w cycles focus. Ctrl+L/K/J and the Ctrl+arrows
//     \\move focus that way, Ctrl+Left out to the tree (in insert mode
//     \\Ctrl+Left/Right jump by word instead, and Ctrl+Home/End go to the
//     \\start and end of the file). Ctrl+B (or Ctrl+N, e.g. under gmux) toggles
//     \\the file tree and focuses it; Ctrl+Tab / Ctrl+Shift+Tab walk the open
//     \\buffers (also :bn / :bp, closed with :bd or a tab's ×). Alt+H shows
//     \\or hides dotfiles and anything .gitignore excludes in the tree; in
//     \\its / search and Ctrl+P it reveals dotfiles only, so .zig-cache and
//     \\.venv stay out. Git worktrees inside the folder are searched anyway,
//     \\as are zoe.conf.lua's unignore globs. A tab shows a red ✘ when its file
//     \\is deleted on disk; file_watch = "poll" | "inotify" | "off" in
//     \\zoe.conf.lua picks how zoe notices.
//     \\
//     \\In the file tree, j/k/arrows and Page Up/Page Down move and Enter or
//     \\Space opens. f jumps to the next name starting with what you type; /
//     \\does the same over the whole tree, opening whatever folders that
//     \\takes; Tab cycles the matches.
//     \\
// ;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var parser = try zargs.ArgParser.init(alloc, .{
        .name = "zoe",
        .description =
        \\A glyphwire vim-like editor
        \\
        \\A directory argument changes into it (as `:cd` would) and starts on
        \\the file tree with an empty buffer; anything else is a file to open.
        \\--line N (before the file) starts the cursor on line N.
        \\
        \\Several directory arguments, or one workspace file (zoe's own
        \\.zoe-workspace or VS Code's .code-workspace), open a workspace:
        \\every folder gets its own collapsible section in the sidebar, and
        \\Ctrl+P and the tree's / search cover all of them. Only a
        \\.code-workspace's "folders" list is read, and zoe never writes one.
        \\:addfolder <dir> and :rmfolder [dir] change the folders for this
        \\session (a bare :rmfolder drops the one the tree cursor is in).
        \\:wssave [file] writes the folders, and the theme if :theme or
        \\zoe.conf.lua chose one, to a .zoe-workspace (bare: the one zoe was
        \\opened from or last saved to); :wsopen <file> switches to another.
        \\That .zoe-workspace is rewritten on :q, :wq and the window closing
        \\(not :q!); workspace_autosave = false in zoe.conf.lua turns it off.
        \\
        \\Every modified buffer is backed up about a second behind your typing
        \\to $XDG_STATE_HOME/glyphwire/zoe/backups (not beside the file), so :q
        \\quits with unsaved changes, and reopening the file (or the workspace,
        \\for untitled buffers) brings them back; u undoes the restore. :w
        \\deletes the backup, :q! throws it away, :recover opens every backup
        \\no tab has. backups = false in zoe.conf.lua turns it off.
        \\
        \\With GLYPHWIRE_SOCK set and no --keys, zoe opens its editor UI on the
        \\glyphwire display server. Ctrl+W is vim's window prefix: then v or s
        \\splits the editor into a new group beside or below (:vsplit / :split
        \\[file]), each with its own tabs and a draggable divider; q closes a
        \\group (:close), w cycles focus and z zooms the group to the whole
        \\editor area and back (:zoom). Ctrl+L/K/J and the Ctrl+arrows
        \\move focus that way, Ctrl+Left out to the tree (in insert mode
        \\Ctrl+Left/Right jump by word instead, and Ctrl+Home/End go to the
        \\start and end of the file). Ctrl+B (or Ctrl+N, e.g. under gmux) toggles
        \\the file tree and focuses it; Ctrl+Tab / Ctrl+Shift+Tab walk the open
        \\buffers (also :bn / :bp, closed with :bd or a tab's ×). Alt+H shows
        \\or hides dotfiles and anything .gitignore excludes in the tree; in
        \\its / search and Ctrl+P it reveals dotfiles only, so .zig-cache and
        \\.venv stay out. Git worktrees inside the folder are searched anyway,
        \\as are zoe.conf.lua's unignore globs. A tab shows a red ✘ when its file
        \\is deleted on disk; file_watch = "poll" | "inotify" | "off" in
        \\zoe.conf.lua picks how zoe notices.
        \\
        \\Ctrl+F opens a VS Code style find box over the buffer and Ctrl+H the
        \\same with a replace row: Enter / Shift+Enter step, Enter in the
        \\replace field replaces one, Ctrl+Alt+Enter replaces all, and Alt+C,
        \\Alt+W, Alt+L toggle match case, whole word and in selection.
        \\:[range]s/pat/rep/[giI] substitutes, with ranges like %, 5,$, .,+3
        \\and '<,'> (what : from visual mode starts with). Both are literal
        \\text, like / search.
        \\
        \\In the file tree, j/k/arrows and Page Up/Page Down move and Enter or
        \\Space opens. f jumps to the next name starting with what you type; /
        \\does the same over the whole tree, opening whatever folders that
        \\takes; Tab cycles the matches. a (or Shift+F4) makes a new file
        \\there -- end the name with / for a folder -- F7 a folder, and r
        \\(or F2) renames in place. The tree follows changes on disk.
        \\
        \\On the : line, Up/Down recall earlier commands (filtered by what
        \\is typed; / searches have their own history) and Tab completes a
        \\filename for :e, :w, :sp, :vs and :cd. ~ means $HOME.
        \\
        \\Typed into zoe's own shell panel (Ctrl+`), `zoe <file>` opens the file
        \\in that zoe and returns, rather than starting another one, and
        \\`zoe <dir>` adds the folder to its sidebar. --wait holds until the
        \\file's tab is closed, for EDITOR='zoe --wait'; --new starts a new zoe
        \\anyway. A bare zoe, a workspace or several folders always start one.
        \\
        \\ZOE_PROFILE=<file> writes one timing line per drawn frame (input,
        \\parse, highlight queries, paint, send) to <file>.
        ,
        .opts = &.{
            .{
                .longName = "keys",
                .description = "Headless: replay a vim-notation key script against the buffer, e.g. 'ihello<esc>dd' or ':w<cr>'.",
                .minNumParams = 1,
                .maxNumParams = 1,
            },
            .{
                .longName = "line",
                .description = "Start the cursor on this 1-based line.",
                .minNumParams = 1,
                .maxNumParams = 1,
            },
            .{
                .longName = "new",
                .description = "Start a new zoe even from a zoe's shell panel, instead of opening the file in that one.",
                .maxNumParams = 0,
            },
            .{
                .longName = "wait",
                .description = "From a zoe's shell panel: return only once the file's tab there is closed (EDITOR='zoe --wait').",
                .maxNumParams = 0,
            },
            .{
                .longName = "quiet",
                .description = "Headless: don't print the buffer afterwards.",
                .maxNumParams = 0,
            },
            .{ .longName = "help", .shortName = "h", .description = "Print this help and exit" },
            .{ .longName = "version", .shortName = "V", .description = "Print the version and exit", .maxNumParams = 0 },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "zoe: error parsing args: {t}\n", .{err}) catch "gw-view: error parsing args\n";
        return write(io, msg);
    };
    defer args.deinit();

    if (args.hasOption("version")) glyphwire.version.printAndExit(io, .of(build_info));
    if (args.hasOption("help")) {
        var stdout = try zargs.print.Printer.stdout(alloc);
        defer stdout.deinit();
        var help = try zargs.help.HelpFormatter.init(&parser, stdout, zargs.help.DefaultTheme, alloc);
        defer help.deinit();
        help.printHelpText() catch |err| std.debug.print("zoe: error printing help: {t}\n", .{err});
        try stdout.flush();
        return;
    }

    const script: ?[]const u8 = args.optionVal("keys");
    var path: ?[]const u8 = null;
    if (args.positional.items.len > 0) {
        path = args.positional.items[0];
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const start_cwd = cwd_buf[0..cwd_len];

    // A workspace: one workspace file, or more than one argument
    // (which then all have to be directories -- zoe opens one file, not
    // a list of them). Resolved against the cwd zoe was started in,
    // before anything changes it.
    var ws: ?workspace.Workspace = null;
    defer if (ws) |*w| w.deinit();
    // A `.zoe-workspace` argument, absolute: where a bare `:wssave`
    // writes. A `.code-workspace` is VS Code's and never written, so it
    // leaves this null.
    var ws_file: ?[]u8 = null;
    defer if (ws_file) |f| alloc.free(f);
    if (args.positional.items.len > 1) {
        for (args.positional.items) |p| {
            if (!isDirectory(io, p)) cli.fail(io, "zoe: with several arguments, each must be a directory\n", .{});
        }
        ws = try workspace.fromDirs(alloc, start_cwd, args.positional.items);
    } else if (path) |p| {
        if (workspace.isWorkspacePath(p) and !isDirectory(io, p)) {
            ws = workspace.load(alloc, io, start_cwd, p) catch |err|
                cli.fail(io, "zoe: can't read workspace {s}: {t}\n", .{ p, err });
            if (workspace.formatOf(p) == .zoe) ws_file = try std.fs.path.resolve(alloc, &.{ start_cwd, p });
        }
    }
    // What glyphwire-shell's default text `open_actions` entry passes
    // (`zoe --line {line} {sel}`), so a `gw-grep` hit opens on its match.
    // An option rather than vim's `+N`: zargunaught takes a bare `+N` as
    // the file name.
    var start_line: ?usize = null;
    if (args.optionVal("line")) |text| {
        start_line = std.fmt.parseInt(usize, text, 10) catch cli.fail(io, "zoe: --line needs a number\n", .{});
    }
    const quiet = args.hasOption("quiet");

    // Inside a zoe's shell panel, one file or one directory goes to that
    // zoe (see `zoe/remote.zig`). Nothing else does: a bare `zoe` or a
    // workspace is a new session by nature, and `--keys` never has a UI.
    if (ws == null and script == null and !args.hasOption("new")) {
        if (path) |p| {
            if (init.environ_map.get(remote.env_var)) |sock| {
                if (try forwardOpen(alloc, io, sock, start_cwd, p, start_line, args.hasOption("wait"))) return;
            }
        }
    }

    // Ctrl+C is a vim-style cancel here, and a SIGINT from the shell
    // would throw away unsaved buffers. After the forwarding above, so
    // `zoe --wait` still stops on one. See `applib.interrupt`.
    interrupt.keep();

    // A directory argument is a place to work, not a file to open, so it
    // is resolved here rather than deeper in: change into it, and from
    // then on it is simply the working directory -- the file tree roots
    // on it, a relative `:w` lands in it, `:pwd` agrees. Same as `:cd`,
    // just spelled on the command line. Everything else (including a
    // name that doesn't exist yet) is a file.
    var target: zoe.Target = .none;
    if (ws) |w| {
        // The first folder becomes the cwd, the way a single directory
        // argument does: a relative `:w` or `:e` has to land somewhere,
        // and the first folder is the one listed first. A first folder
        // that doesn't exist leaves the cwd alone; its section is just
        // empty.
        std.process.setCurrentPath(io, w.folders.items[0].path) catch {};
        target = .workspace;
    } else if (path) |p| {
        if (isDirectory(io, p)) {
            std.process.setCurrentPath(io, p) catch cli.fail(io, "zoe: cannot change directory\n", .{});
            target = .directory;
        } else {
            target = .{ .file = .{ .path = p, .line = start_line } };
        }
    }

    // `--keys` always means the headless driver, even under a display
    // server: it's how the core is tested, and a script racing a live UI
    // would be neither. The UI opens the target itself: it owns every
    // buffer in its tab strip, and the first one is no different.
    if (script == null) {
        if (try runUi(alloc, io, target, if (ws) |*w| w else null, ws_file, init.environ_map)) return;
    }

    // A missing file is a new buffer, not an error -- `zoe newfile.txt`
    // is how you create one. A directory target has already been changed
    // into and leaves nothing to read.
    const file_path: ?[]const u8 = switch (target) {
        .file => |f| f.path,
        .none, .directory, .workspace => null,
    };
    const text: []u8 = if (file_path) |p|
        std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try alloc.dupe(u8, ""),
            else => cli.fail(io, "zoe: cannot read file\n", .{}),
        }
    else
        try alloc.dupe(u8, "");
    defer alloc.free(text);
    // Same refusal the UI gives, so `zoe --keys` and a live window agree
    // on what zoe will open (see applib/filetype.zig).
    if (zoe.filetype.looksBinary(text)) cli.fail(io, "zoe: not a text file\n", .{});

    var ed = try zoe.Editor.initFromText(alloc, text, file_path);
    defer ed.deinit();
    if (start_line) |line| ed.gotoStartLine(line);

    if (script) |s| {
        switch (try zoe.keys.feed(&ed, s)) {
            // `:bn` / `:bp` / `:bd` need the UI's buffer list, `:vsplit`
            // / `:close` its editor groups, `:cd` / `:pwd` a live client
            // and a real cwd, the clipboard ones a live host, and every
            // LSP one a running language server. The headless driver
            // just reports what parsed.
            .none,
            .quit,
            .chdir,
            .pwd,
            .add_folder,
            .remove_folder,
            .ws_save,
            .ws_open,
            .set_clipboard,
            .paste,
            .buffer_step,
            .buffer_close,
            .buffer_new,
            .tabs_close,
            .split,
            .close_group,
            .zoom_group,
            .lsp_hover,
            .lsp_definition,
            .diag_step,
            .lsp_status,
            .diag_list,
            .extensions_list,
            .theme_picker,
            .recover,
            .theme,
            .shell_position,
            => {},
            .write, .write_quit, .edit => |dest| try headlessSave(io, &ed, dest, init.environ_map.get("HOME")),
        }
    }

    if (!quiet) {
        const out = try ed.buf.text(alloc);
        defer alloc.free(out);
        try write(io, out);
        if (out.len > 0 and out[out.len - 1] != '\n') try write(io, "\n");
    }

    if (ed.status.items.len > 0) {
        try write(io, ed.status.items);
        try write(io, "\n");
    }
}

/// Whether `path` names a directory, following symlinks -- a link to one
/// is one for this purpose. Anything unreadable answers false and is
/// treated as a file, which is also what gives `zoe newfile.txt` its
/// new buffer.
fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Sends `path` to the zoe whose shell panel this is. True when that zoe
/// took it (or refused it, which is reported here): either way this one
/// is done. False when that zoe has gone, so this one starts in its place.
fn forwardOpen(
    alloc: std.mem.Allocator,
    io: std.Io,
    sock: []const u8,
    cwd: []const u8,
    path: []const u8,
    line: ?usize,
    wait: bool,
) !bool {
    // The other zoe has a cwd of its own, so it gets the path absolute.
    const abs = try std.fs.path.resolve(alloc, &.{ cwd, path });
    defer alloc.free(abs);
    const req: remote.Request = .{
        .kind = if (isDirectory(io, abs)) .dir else .file,
        .path = abs,
        .line = line,
        .wait = wait,
    };
    var reply_buf: [512]u8 = undefined;
    const answer = remote.forward(alloc, sock, req, &reply_buf) catch |err| switch (err) {
        error.Unavailable => return false,
        else => return err,
    };
    switch (answer) {
        .opened => {},
        .refused => |why| cli.fail(io, "zoe: {s}\n", .{why}),
    }
    return true;
}

/// Connects and runs the UI. False when there's no display server to
/// connect to, which is the caller's cue to fall back to headless.
fn runUi(
    alloc: std.mem.Allocator,
    io: std.Io,
    target: zoe.Target,
    ws: ?*const workspace.Workspace,
    ws_file: ?[]const u8,
    environ: *std.process.Environ.Map,
) !bool {
    // Two connections: one for requests and drawing, one subscribed for
    // notifications. `layout` and `scroll_offset` are what the split tree
    // and the tree pane's scrollbars report back on.
    var conn = cli.connect(io, alloc, environ, &.{
        "key",
        "text",
        "clipboard",
        "resize",
        "scroll",
        "layout",
        "mouse_button",
        "mouse_move",
        "context",
        // The window gaining or losing the keyboard: zoe paints its own
        // cursor, so it has to be told to hollow it out (see `syncCaret`).
        "focus",
        // The window theme changed under a zoe that follows it: the
        // popups' nine-patch frame and the capture table catch up.
        "theme",
    }) catch |err| {
        if (err == error.NoSession) try write(io, "zoe: Requires a glyphwire host with GLYPHWIRE_SOCK set.\n");
        return false;
    };
    defer conn.deinit();

    // The sidebar's folders: the workspace's, or else just the cwd.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    var folders: std.ArrayList(zoe.Tree.RootSpec) = .empty;
    defer folders.deinit(alloc);
    if (ws) |w| {
        for (w.folders.items) |f| try folders.append(alloc, .{ .path = f.path, .name = f.name });
    } else {
        try folders.append(alloc, .{ .path = cwd, .name = workspace.defaultName(cwd) });
    }

    // The socket `zoe <file>` in the shell panel opens files in this zoe
    // through, its path put where the panel's shell will inherit it.
    // Best-effort: without it, a `zoe` typed there just starts another.
    const server: ?*remote.Server = blk: {
        const dir = glyphwire.runtime_dir.runtimeDir(alloc, environ) catch break :blk null;
        defer alloc.free(dir);
        break :blk remote.Server.start(alloc, io, dir, conn.listener) catch null;
    };
    defer if (server) |srv| srv.stop();
    if (server) |srv| try environ.put(remote.env_var, srv.path);

    const ui = try zoe.Ui.init(alloc, io, &conn.client, conn.listener, target, folders.items, .{
        .file = ws_file,
        .theme = if (ws) |w| w.theme else null,
        .editors = if (ws) |w| (if (w.editors) |e| e.root else null) else null,
    }, environ);
    defer ui.deinit();
    if (server) |srv| ui.attachRemote(srv);

    // Closing the window sends SIGHUP: catch it so the workspace file
    // still gets written on the way out.
    try zoe.hangup.watch(conn.listener);
    try ui.run();
    return true;
}

/// The headless `:w` -- the UI has its own, since it also refreshes the
/// statusline.
fn headlessSave(io: std.Io, ed: *zoe.Editor, raw_target: ?[]const u8, home: ?[]const u8) !void {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = if (raw_target) |t| homepath.expandHome(t, home, &home_buf) else null;
    const dest = target orelse ed.path orelse {
        ed.setStatus("E32: No file name", .{});
        return;
    };
    const bytes = try ed.buf.text(ed.alloc);
    defer ed.alloc.free(bytes);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes }) catch {
        ed.setStatus("E212: Can't open file for writing: {s}", .{dest});
        return;
    };
    if (target) |t| try ed.setPath(t);
    ed.markSaved();
    ed.setStatus("\"{s}\" {d}L written", .{ dest, ed.buf.lineCount() });
}

fn write(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}
