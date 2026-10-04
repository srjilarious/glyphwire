// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-hist: Ctrl+R-style fuzzy history search for glyphwire-shell, and
//! glyphwire's answer to mcfly -- a real glyphwire client (its own
//! context and layers over the wire protocol), not a plain terminal
//! program drawing raw ANSI. Requires a glyphwire session
//! (`GLYPHWIRE_SOCK`); there is no headless fallback, since this program
//! only ever makes sense launched as a foreground command by
//! glyphwire-shell, itself always a glyphwire client.
//!
//! Layout: a 3-row header (title, search field with its own drawn caret,
//! match count / key hints) on a blue layer, and a list layer below it
//! showing the filtered matches. The list layer is in `client` scroll
//! mode (see `docs/api.md`'s `scroll_mode`): it stays sized to the
//! visible rows and redraws whichever slice is in view rather than
//! growing to hold every match, while `content_extent` + `scrollbars`
//! tell the host the true total so it can draw a proportional, draggable
//! scrollbar. Up/Down move the selection by one and PageUp/PageDown by a
//! screenful, dragging the view along with it (`followSelection`); the
//! host can also move the view on its own (wheel, scrollbar drag), which
//! arrives as a `scroll_offset` event and is followed without touching
//! the selection. Every redraw -- rows, sizes and scroll position -- goes
//! out as one `batch` frame (`render`).
//!
//! `gw-hist [query...]` opens with the search field already holding
//! `query` and the list already filtered by it -- glyphwire-shell's
//! Ctrl+R passes whatever was typed at the prompt (see
//! `Prompt.historySearch`), so reaching for the history mid-line keeps
//! that typing instead of discarding it. See `seedQuery`.
//!
//! `gw-hist --dirs [query...]` opens on the *directory* view instead:
//! every directory the shell has changed into, read from `zj`'s
//! frecency database (`z.db`, see `applib.zjump`) -- one entry per path,
//! so no duplicates -- and listed `~`-collapsed, best frecency first. A
//! query fuzzy-matches the same way it does over history but only
//! narrows the list; the survivors keep their frecency order, the way
//! zoxide's `zi` behaves, since "where do I usually go" is the question
//! this view answers. Picking one hands back `cd <path>` (`zjump.cdLine`)
//! rather than the path itself. glyphwire-shell's Alt+C opens this view
//! (see `Prompt.dirSearch`). Tab flips between the two views, keeping
//! the query.
//!
//! On Enter, the selected line is written to `$GLYPHWIRE_RESULT_FD` --
//! the shell opens this pipe before spawning every foreground command
//! (see `shell/main.zig`'s `result_fd_env`) so any program, not just this
//! one, can hand a value back to become the next prompt line. Esc /
//! Ctrl+C exit without writing anything, leaving the shell's current line
//! untouched. Run without that env var set (e.g. testing by hand), the
//! pick goes to stdout instead.

const std = @import("std");
const glyphwire = @import("glyphwire");
const history = @import("applib").history;
const fuzzy = @import("applib").fuzzy;
const interrupt = @import("applib").interrupt;
const zjump = @import("applib").zjump;
const homepath = @import("applib").homepath;

/// Rows the header block occupies: title, search field, hint line.
const header_rows: usize = 3;

// A picker like the finder popups (zoe's Ctrl+P, salacommander's F3), so
// it draws in the same theme roles: the finder's header and selection
// over a popup's body.
const role = glyphwire.Color.role;
const bg_header = role(.finder_header_bg);
const fg_header = role(.finder_header_fg);
const bg_list = role(.popup_bg);
const fg_list = role(.popup_fg);
const bg_selected = role(.finder_selected_bg);
const fg_selected = role(.finder_selected_fg);

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    // Ctrl+C dismisses the search itself, handing the shell its
    // cancelled result rather than dying without one.
    // See `applib.interrupt`.
    interrupt.keep();
    const arena = init.arena.allocator();

    const args = try parseArgs(arena, try init.minimal.args.toSlice(arena));

    const entries = loadHistory(alloc, io, init.environ_map) catch &.{};
    defer if (entries.len > 0) history.freeEntries(alloc, @constCast(entries));
    // Both lists are loaded up front whichever view opens, so Tab
    // switches instantly. `z.db` is small (aging keeps it bounded), and
    // the strings live in `arena` for the life of the process.
    const dirs = loadDirs(arena, io, init.environ_map) catch &.{};

    var client = try glyphwire.Client.connectFromEnv(io, alloc, init.environ_map);
    defer client.deinit();

    const listener = try glyphwire.InputListener.connectFromEnv(io, alloc, init.environ_map, &.{
        "key",
        "text",
        "resize",
        "scroll_offset",
    });
    defer listener.deinit();

    const ui = try Ui.init(alloc, &client, listener, entries, dirs, args.mode, args.seed);
    defer ui.deinit();

    try ui.run();

    if (ui.picked) |p| {
        defer alloc.free(p);
        const maybe_fd = resultFd(init.environ_map);
        const out_file: std.Io.File = if (maybe_fd) |fd|
            .{ .handle = fd, .flags = .{ .nonblocking = false } }
        else
            std.Io.File.stdout();
        var buf: [4096]u8 = undefined;
        var w = out_file.writer(io, &buf);
        w.interface.writeAll(p) catch {};
        w.interface.flush() catch {};
        if (maybe_fd != null) out_file.close(io);
    }
}

/// Which list the picker is showing. Tab flips between them.
const Mode = enum {
    /// Every command line from the shell's history file.
    history,
    /// Every directory in `zj`'s `z.db`; a pick becomes `cd <path>`.
    dirs,
};

const Args = struct {
    mode: Mode = .history,
    seed: []const u8 = "",
};

/// `gw-hist [--dirs] [query...]`. Only a *leading* `--dirs` is the flag,
/// so a query that happens to contain the word (Ctrl+R over a typed
/// `ls --dirs`) is still searched for rather than swallowed.
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Args {
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--dirs")) {
        return .{ .mode = .dirs, .seed = try seedQuery(arena, args[1..]) };
    }
    return .{ .seed = try seedQuery(arena, args) };
}

/// The query the search opens with, from `gw-hist [query...]`: every
/// argument after the program name, joined with single spaces. Empty (no
/// arguments) opens on the whole history, which is what a bare `gw-hist`
/// has always done. (`parseArgs` passes `args` with any `--dirs` already
/// in the program name's slot, so it is skipped the same way.)
///
/// Joined rather than "take `args[1]`, ignore the rest" so both callers
/// read naturally: glyphwire-shell's Ctrl+R passes the typed line as one
/// argument (a query is one string, not an argv), while `gw-hist git
/// commit` typed by hand seeds `git commit` instead of silently dropping
/// everything past the first word. The two spellings coincide for any
/// line without runs of whitespace in it, and the fuzzy matcher
/// (`fuzzy.matches`) treats the space as just another character to find
/// in order, so neither needs the original spacing preserved exactly.
fn seedQuery(arena: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return "";
    return std.mem.join(arena, " ", args[1..]);
}

fn resultFd(environ_map: *const std.process.Environ.Map) ?std.Io.File.Handle {
    const s = environ_map.get("GLYPHWIRE_RESULT_FD") orelse return null;
    return std.fmt.parseInt(std.Io.File.Handle, s, 10) catch null;
}

fn loadHistory(alloc: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ![]const []const u8 {
    if (environ_map.get("GLYPHWIRE_NO_HISTORY")) |v| {
        if (v.len > 0) return &.{};
    }
    const config_dir = try glyphwire.configDirPath(alloc, environ_map);
    defer alloc.free(config_dir);
    const path = try std.fs.path.join(alloc, &.{ config_dir, "history" });
    defer alloc.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer alloc.free(bytes);
    return try history.parse(alloc, bytes);
}

/// The directory view's rows: `z.db`'s paths, best frecency first
/// (`zjump.byFrecency`), `~`-collapsed for display. Two kinds of entry
/// are left out: the current directory, since a `cd` to where you
/// already are does nothing (`zj` skips it too), and any path that no
/// longer opens as a directory. The shell prunes those from the file
/// itself only when a `zj` jump trips over one, so they can linger.
/// `$GLYPHWIRE_NO_HISTORY` empties the list, the same opt-out the shell
/// honours for the file.
fn loadDirs(arena: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ![]const []const u8 {
    if (environ_map.get("GLYPHWIRE_NO_HISTORY")) |v| {
        if (v.len > 0) return &.{};
    }
    const config_dir = try glyphwire.configDirPath(arena, environ_map);
    const path = try std.fs.path.join(arena, &.{ config_dir, "z.db" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    // Never deinit'd: its lists and strings all come out of `arena`.
    const db = try zjump.Db.parse(arena, bytes);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const ranked = try zjump.byFrecency(arena, db.entries.items, now);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd: ?[]const u8 = if (std.process.currentPath(io, &cwd_buf)) |n| cwd_buf[0..n] else |_| null;
    const home = environ_map.get("HOME");

    var out: std.ArrayList([]const u8) = .empty;
    var tilde_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (ranked) |e| {
        if (cwd) |c| if (std.mem.eql(u8, c, e.path)) continue;
        var d = std.Io.Dir.cwd().openDir(io, e.path, .{}) catch continue;
        d.close(io);
        try out.append(arena, try arena.dupe(u8, homepath.collapseHome(e.path, home, &tilde_buf)));
    }
    return out.items;
}

const Ui = struct {
    alloc: std.mem.Allocator,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,
    context: glyphwire.ContextHandle,
    header_layer: glyphwire.LayerHandle,
    list_layer: glyphwire.LayerHandle,

    /// History lines, oldest-first (the file's order).
    history_entries: []const []const u8,
    /// Directories, best frecency first (`loadDirs`).
    dir_entries: []const []const u8,
    mode: Mode,
    query: std.ArrayList(u8) = .empty,
    filtered: std.ArrayList([]const u8) = .empty,
    /// Reused across renders so drawing a line never allocates on the hot
    /// path -- only `query`/`filtered`, which change shape, do.
    scratch: std.ArrayList(u8) = .empty,

    selected: usize = 0,
    /// Index of the first entry drawn in the list layer's row 0.
    view_top: usize = 0,

    cols: usize,
    rows: usize,
    list_rows: usize,

    header_dirty: bool = true,
    list_dirty: bool = true,
    /// Layer sizes need re-sending (a `resize` arrived).
    layout_dirty: bool = false,
    quit: bool = false,
    /// Set on Enter; `main` writes it out once `run` returns.
    picked: ?[]u8 = null,

    fn init(
        alloc: std.mem.Allocator,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        history_entries: []const []const u8,
        dir_entries: []const []const u8,
        mode: Mode,
        /// The query to open on -- see `seedQuery`. Copied into `query`,
        /// so the caller's storage doesn't have to outlive this.
        seed: []const u8,
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        // A dedicated context: from here on every layer call on `client`
        // targets this, not the shell's, and it composites over the
        // shell the way `read`/`zoe`'s own contexts do. `destroy_context`
        // restores the shell's context underneath on the way out.
        const context = try client.createContext(null, null, 0, false);
        errdefer client.destroyContext(context) catch {};
        try listener.attachContext(context);
        try client.setContextTitle("gw-hist");

        const size = try client.getSize();
        const cols = size.cols;
        const rows = size.rows;
        const list_rows = @max(rows -| header_rows, 1);

        const header_layer = try client.createLayer(cols, header_rows, 0);
        const list_layer = try client.createLayer(cols, list_rows, 0);
        try client.setLayerCellPosition(list_layer, header_rows, 0);
        // Solid panels without padding every row with spaces: whatever
        // isn't written composites as the layer background.
        try client.setLayerBackground(header_layer, bg_header);
        try client.setLayerBackground(list_layer, bg_list);
        // Sized to the visible rows only; `render` tells the host the
        // true total via `content_extent` so its scrollbar thumb is
        // proportional, not full-height.
        try client.setLayerScrollMode(list_layer, .client);
        try client.setLayerScrollbars(list_layer, true, false);

        self.* = .{
            .alloc = alloc,
            .client = client,
            .listener = listener,
            .context = context,
            .header_layer = header_layer,
            .list_layer = list_layer,
            .history_entries = history_entries,
            .dir_entries = dir_entries,
            .mode = mode,
            .cols = cols,
            .rows = rows,
            .list_rows = list_rows,
        };

        // Before the first `refilter`, so the opening list is already
        // narrowed rather than showing everything for one frame. The
        // drawn caret needs nothing extra: `renderHeader` puts it right
        // after `query`, and typing appends to the end of it, so a seeded
        // field behaves exactly like one typed into.
        try self.query.appendSlice(alloc, seed);

        try self.refilter();
        self.followSelection();
        return self;
    }

    fn deinit(self: *Ui) void {
        self.query.deinit(self.alloc);
        self.filtered.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        // Doesn't have to be called on a clean exit (the server culls an
        // owning connection's contexts on disconnect), but doing it
        // explicitly restores the shell's context immediately rather
        // than waiting on socket teardown.
        self.client.destroyContext(self.context) catch {};
        self.alloc.destroy(self);
    }

    // ── Loop ────────────────────────────────────────────────────────────

    fn run(self: *Ui) !void {
        while (!self.quit) {
            try self.render();
            // Every notification wakes this, so it can block outright.
            const first = try self.listener.next(.none) orelse continue;
            try self.handleEvent(first);
            // Fold everything else already queued into the same redraw.
            while (!self.quit) {
                const ev = self.listener.pollNext() orelse break;
                try self.handleEvent(ev);
            }
        }
    }

    fn handleEvent(self: *Ui, ev: glyphwire.Event) !void {
        defer ev.deinit(self.alloc);
        switch (ev) {
            .key => |k| if (k.pressed) try self.handleKey(k),
            .text => |t| try self.handleText(t.text),
            .shutdown => self.quit = true,
            .resize => |r| {
                self.cols = r.cols;
                self.rows = r.rows;
                self.list_rows = @max(self.rows -| header_rows, 1);
                self.followSelection();
                self.layout_dirty = true;
                self.header_dirty = true;
                self.list_dirty = true;
            },
            // The wheel or a scrollbar drag over the list: the host has
            // already moved the viewport and is telling us where it
            // landed. Follow it without touching `selected` -- scrolling
            // and picking are separate gestures here, same as browsing a
            // file list without moving your cursor onto every row you
            // pass over.
            .scroll_offset => |so| if (so.layer == self.list_layer) {
                self.view_top = @min(so.row, self.filtered.items.len -| self.list_rows);
                self.list_dirty = true;
            },
            else => {},
        }
    }

    // ── Input ───────────────────────────────────────────────────────────

    /// Named/control keys -- physical-key semantics (vim-style, same
    /// split `gw-read`/`zoe` use). Ordinary typed characters arrive via
    /// `handleText` instead, since `text` is already resolved through the
    /// OS layout/IME and a search box has no reason to care which
    /// physical key produced what was typed.
    fn handleKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        // Read off the event, not the live down-set, so a fast Ctrl+C is
        // still Ctrl+C when this loop is behind.
        const ctrl = k.ctrl();
        const key = k.key;
        const eq = std.mem.eql;

        if (eq(u8, key, "enter")) {
            if (self.filtered.items.len == 0) return;
            const row = self.filtered.items[self.selected];
            self.picked = switch (self.mode) {
                .history => try self.alloc.dupe(u8, row),
                .dirs => try zjump.cdLine(self.alloc, row),
            };
            self.quit = true;
        } else if (eq(u8, key, "tab")) {
            // The query carries over: `glyph` typed into the history
            // view is just as likely to be the name of the directory.
            self.mode = switch (self.mode) {
                .history => .dirs,
                .dirs => .history,
            };
            try self.onQueryChanged();
        } else if (eq(u8, key, "escape") or (ctrl and eq(u8, key, "c"))) {
            self.quit = true;
        } else if (eq(u8, key, "backspace")) {
            self.deleteBackward();
            try self.onQueryChanged();
        } else if (ctrl and eq(u8, key, "u")) {
            self.query.clearRetainingCapacity();
            try self.onQueryChanged();
        } else if (eq(u8, key, "up")) {
            if (self.selected > 0) self.selected -= 1;
            self.followSelection();
            self.list_dirty = true;
        } else if (eq(u8, key, "down") or (ctrl and eq(u8, key, "r"))) {
            if (self.filtered.items.len > 0) self.selected = (self.selected + 1) % self.filtered.items.len;
            self.followSelection();
            self.list_dirty = true;
        } else if (eq(u8, key, "page_up")) {
            self.selected = self.selected -| self.list_rows;
            self.followSelection();
            self.list_dirty = true;
        } else if (eq(u8, key, "page_down")) {
            if (self.filtered.items.len > 0) {
                self.selected = @min(self.selected + self.list_rows, self.filtered.items.len - 1);
            }
            self.followSelection();
            self.list_dirty = true;
        }
    }

    fn handleText(self: *Ui, text: []const u8) !void {
        try self.query.appendSlice(self.alloc, text);
        try self.onQueryChanged();
    }

    /// Removes one codepoint, not just one byte, off the end of `query`
    /// -- typing is UTF-8 (`text` events), so backspace should be too.
    fn deleteBackward(self: *Ui) void {
        if (self.query.items.len == 0) return;
        var i = self.query.items.len - 1;
        while (i > 0 and (self.query.items[i] & 0xC0) == 0x80) i -= 1;
        self.query.items.len = i;
    }

    fn onQueryChanged(self: *Ui) !void {
        self.selected = 0;
        try self.refilter();
        self.followSelection();
        self.header_dirty = true;
        self.list_dirty = true;
    }

    /// Rewrites `filtered` from the current view's entries.
    fn refilter(self: *Ui) !void {
        self.filtered.clearRetainingCapacity();
        switch (self.mode) {
            .history => try self.refilterHistory(),
            .dirs => try self.refilterDirs(),
        }
        if (self.selected >= self.filtered.items.len) self.selected = self.filtered.items.len -| 1;
    }

    /// Every directory that fuzzy-matches `query`, in the frecency order
    /// `dir_entries` already has. The match only decides membership --
    /// see the module doc for why it doesn't re-rank.
    fn refilterDirs(self: *Ui) !void {
        for (self.dir_entries) |d| {
            if (fuzzy.matches(d, self.query.items)) try self.filtered.append(self.alloc, d);
        }
    }

    /// Every history line (`history_entries` is oldest-first) that
    /// fuzzy-matches `query`, newest-first, sorted by `fuzzy.score`
    /// (tighter match first) with a stable sort so equal scores keep the
    /// newest-first order -- the recency tiebreak (see `fuzzy.score`'s
    /// doc comment).
    fn refilterHistory(self: *Ui) !void {
        const entries = self.history_entries;
        var i: usize = entries.len;
        while (i > 0) {
            i -= 1;
            if (fuzzy.matches(entries[i], self.query.items)) try self.filtered.append(self.alloc, entries[i]);
        }
        const Ctx = struct {
            query: []const u8,
            fn lessThan(ctx: @This(), a: []const u8, b: []const u8) bool {
                const sa = fuzzy.score(a, ctx.query) orelse return false;
                const sb = fuzzy.score(b, ctx.query) orelse return false;
                return sa < sb;
            }
        };
        std.mem.sort([]const u8, self.filtered.items, Ctx{ .query = self.query.items }, Ctx.lessThan);
    }

    /// Keeps `view_top` covering `selected`, clamped to the list's actual
    /// extent. `render` pushes the result to the host.
    fn followSelection(self: *Ui) void {
        if (self.filtered.items.len == 0) {
            self.view_top = 0;
        } else {
            if (self.selected < self.view_top) self.view_top = self.selected;
            if (self.selected >= self.view_top + self.list_rows) self.view_top = self.selected - self.list_rows + 1;
            const max_top = self.filtered.items.len -| self.list_rows;
            if (self.view_top > max_top) self.view_top = max_top;
        }
    }

    // ── Rendering ───────────────────────────────────────────────────────

    /// Sends everything dirty as one `batch` frame -- typing a character
    /// used to mean a dozen separate round trips, and the scroll position
    /// used to go out ahead of the rows it described.
    fn render(self: *Ui) !void {
        if (!self.header_dirty and !self.list_dirty and !self.layout_dirty) return;
        var b = self.client.batch();
        defer b.deinit();
        if (self.layout_dirty) {
            try b.setLayerSize(self.header_layer, self.cols, header_rows);
            try b.setLayerSize(self.list_layer, self.cols, self.list_rows);
            self.layout_dirty = false;
        }
        if (self.header_dirty) {
            try self.renderHeader(&b);
            self.header_dirty = false;
        }
        if (self.list_dirty) {
            try self.renderList(&b);
            // The host only broadcasts a `scroll_offset` that actually
            // moved, so re-sending an unchanged one every frame is silent.
            try b.setLayerContentExtent(self.list_layer, self.cols, self.filtered.items.len);
            try b.setLayerScrollOffset(self.list_layer, self.view_top, 0);
            self.list_dirty = false;
        }
        var results = try b.send();
        results.deinit();
    }

    fn renderHeader(self: *Ui, b: *glyphwire.Client.Batch) !void {
        const title = switch (self.mode) {
            .history => "gw-hist -- fuzzy history search   [Tab: directories]",
            .dirs => "gw-hist -- frecent directories   [Tab: history]",
        };
        try self.writeLine(b, self.header_layer, 0, title, fg_header, bg_header);

        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(self.alloc, "Search: ");
        try self.scratch.appendSlice(self.alloc, self.query.items);
        // The caret goes right after the query, wherever the host's own
        // width table put it: blank the row back to the layer background,
        // write the text unpadded, then one inverted cell at the cursor it
        // left. A drawn caret rather than the host's -- a text layer's
        // cursor property is the *next write* position, not a visual
        // marker.
        try b.clearArea(.{ .layer = self.header_layer, .row = 1, .rows = 1 });
        try b.writeTextOpts(self.scratch.items, .{
            .layer = self.header_layer,
            .row = 1,
            .col = 0,
            .fg = fg_header,
            .bg = bg_header,
            .max_cols = self.cols,
        });
        try b.writeTextOpts(" ", .{ .layer = self.header_layer, .fg = bg_header, .bg = fg_header, .max_cols = 1 });

        self.scratch.clearRetainingCapacity();
        const pick = switch (self.mode) {
            .history => "Enter picks",
            .dirs => "Enter: cd",
        };
        try self.scratch.print(self.alloc, "{d} match(es)   {s}   Esc/^C cancels   Down/^R next   PgUp/PgDn page", .{ self.filtered.items.len, pick });
        try self.writeLine(b, self.header_layer, 2, self.scratch.items, fg_header, bg_header);
    }

    fn renderList(self: *Ui, b: *glyphwire.Client.Batch) !void {
        var row: usize = 0;
        while (row < self.list_rows) : (row += 1) {
            const idx = self.view_top + row;
            if (idx < self.filtered.items.len) {
                self.scratch.clearRetainingCapacity();
                try self.scratch.append(self.alloc, ' ');
                try self.scratch.appendSlice(self.alloc, self.filtered.items[idx]);
                const fg = if (idx == self.selected) fg_selected else fg_list;
                const bg = if (idx == self.selected) bg_selected else bg_list;
                try self.writeLine(b, self.list_layer, row, self.scratch.items, fg, bg);
            } else {
                // Rows past the last match: back to transparent, which
                // the layer background paints.
                try b.clearArea(.{ .layer = self.list_layer, .row = row, .rows = 1 });
            }
        }
    }

    /// One full-width row at `(row, 0)` in a single `write_text`: the host
    /// clips `text` to the window at a display-column boundary (CJK-safe)
    /// and pads the rest of the row in `bg`, so stale content from a
    /// longer previous line never survives.
    fn writeLine(self: *Ui, b: *glyphwire.Client.Batch, layer: glyphwire.LayerHandle, row: usize, text: []const u8, fg: glyphwire.Color, bg: glyphwire.Color) !void {
        try b.writeTextOpts(text, .{
            .layer = layer,
            .row = row,
            .col = 0,
            .fg = fg,
            .bg = bg,
            .max_cols = self.cols,
            .pad = true,
        });
    }
};
