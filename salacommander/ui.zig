// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! salacommander's client half: a full-screen context split into two pane
//! layers side by side, a one-row function-key bar under them, and a
//! dialog layer on top that's only visible while a modal question is up.
//!
//! Each pane layer is drawn client-side, a window of rows at a time:
//!
//!     row 0        the pane's directory (highlighted on the active side),
//!                  or a text field holding it once Alt+D or a click on
//!                  the row has opened one
//!     row 1        column headers
//!     rows 2..     the listing, one row per entry (small view) or two
//!                  (large view: tall icon, name, then perms/owner)
//!     last row     a summary: what's marked (or the cursor entry) on the
//!                  left, the directory's item count and total on the right
//!
//! Two more layers sit over those: the modal dialog layer, and the
//! Ctrl+` shell panel -- a `gw-shell --embed` drawing its own prompt
//! into a layer of ours across the bottom (see `shellpanel.zig`).
//!
//! A server-side `Table` would sort and paint for us, but it paints every
//! row and scrolls its layer the way terminal output does; a file pane
//! needs a fixed header, a cursor bar and marked-row colours, so the rows
//! are written here instead. Only the visible rows are sent, so a
//! directory of any size costs one screenful per redraw. The pane layers
//! are in `client` scroll mode with a `content_extent`, which gets a host
//! scrollbar and turns the wheel into `scroll_offset` events we follow.
//!
//! Keys go through the `Keymap` (`actions.zig`); every command is an
//! `Action` handled in `perform`. Typed text isn't a binding: with no
//! field open it's type-to-find, moving the cursor to the first entry
//! starting with what's been typed. A Ctrl+click marks a row the way
//! Space does, and never activates it. The dialogs run their own nested event
//! loop (`runDialog`), which is also what the file operations' conflict
//! and error hooks call -- so an operation is synchronous, and a question
//! halfway through a copy is just a dialog opened from inside it.

const std = @import("std");
const glyphwire = @import("glyphwire");
const ls = @import("ls_support");
const pane_mod = @import("pane.zig");
const actions = @import("actions.zig");
const fileops = @import("fileops.zig");
const dialog_mod = @import("dialog.zig");
const config_mod = @import("config.zig");
const openaction = @import("openaction.zig");
const shellpanel = @import("shellpanel.zig");

const Pane = pane_mod.Pane;
const FileEntry = pane_mod.FileEntry;
const Action = actions.Action;
const Dialog = dialog_mod.Dialog;
const Button = dialog_mod.Button;
const LineEdit = dialog_mod.LineEdit;
const Color = glyphwire.Color;
const Batch = glyphwire.Client.Batch;
const lsfmt = ls.format;
const lsentries = ls.entries;
const gridlayout = ls.gridlayout;

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b };
}

const bg_pane = rgb(24, 26, 31);
/// Every other listing row, a shade up from `bg_pane` so a wide pane's
/// name and size columns stay on one line for the eye. Kept below the
/// header/footer shade: a stripe shouldn't read as chrome.
const bg_row_alt = rgb(28, 30, 36);
const bg_header = rgb(30, 33, 39);
const bg_footer = rgb(30, 33, 39);
const bg_title_active = rgb(52, 101, 164);
const bg_title_inactive = rgb(40, 44, 52);
const bg_cursor = rgb(52, 101, 164);
const bg_cursor_inactive = rgb(50, 54, 62);
const bg_bar = rgb(24, 26, 31);
const bg_bar_label = rgb(56, 132, 140);
const bg_dialog = rgb(44, 48, 58);
const bg_dialog_title = rgb(52, 101, 164);
const bg_dialog_danger = rgb(150, 60, 60);
const bg_input = rgb(24, 26, 31);
const bg_button_focus = rgb(52, 101, 164);
const bg_button = rgb(60, 65, 77);

const fg_title_active = rgb(240, 241, 245);
const fg_title_inactive = rgb(150, 156, 168);
const fg_header = rgb(229, 192, 123);
const fg_file = rgb(205, 209, 216);
const fg_dir = rgb(130, 170, 255);
const fg_link = rgb(86, 182, 194);
const fg_exec = rgb(152, 195, 121);
const fg_other = rgb(198, 120, 221);
const fg_marked = rgb(255, 204, 64);
const fg_detail = rgb(120, 126, 138);
const fg_footer = rgb(171, 178, 191);
const fg_bar_key = rgb(220, 220, 220);
const fg_bar_label = rgb(16, 18, 22);
const fg_message = rgb(229, 192, 123);
const fg_dialog = rgb(220, 223, 228);

/// Rows every pane spends on chrome: title, column header, footer.
const chrome_rows = 3;
const list_top = 2;
const size_w = 8;
const date_w = 16;
const double_click_ms = 400;
/// The longest type-to-find prefix. Well past the point where a listing
/// has one match left.
const find_max = 64;

/// A pane's directory being edited where it's shown: which side, and the
/// field holding it.
const PathEdit = struct {
    pane: usize,
    line: LineEdit,
    /// The byte the field was last drawn from -- it scrolls with the
    /// caret on a path wider than the pane -- so a click in the row can
    /// be turned back into an offset in the text.
    view_start: usize = 0,
};

/// Where one pane's columns fall, for its current width and view.
const Columns = struct {
    icon_col: usize,
    name_col: usize,
    name_w: usize,
    size_col: ?usize,
    date_col: ?usize,
};

pub const Ui = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,
    /// `$HOME`, for `~` in titles and typed paths. Borrowed.
    home: ?[]const u8,

    context: glyphwire.ContextHandle,
    pane_layers: [2]glyphwire.LayerHandle,
    bar_layer: glyphwire.LayerHandle,
    dialog_layer: glyphwire.LayerHandle,
    /// Ctrl+`: a `gw-shell` drawing into a layer across the bottom. It
    /// takes every keystroke but Ctrl+` while it's open, and follows the
    /// active pane's directory. See `shellpanel.zig`.
    shell: shellpanel.Panel,

    win: struct { cols: usize, rows: usize },
    cell: struct { w: u32, h: u32 },

    cfg: config_mod.Config,
    keymap: actions.Keymap,
    panes: [2]Pane,
    active: usize = 0,

    /// The dialog on screen, while `runDialog` has one up.
    dialog: ?*Dialog = null,
    /// Alt+D: a pane's title row turned into a text field. While one is
    /// open its pane draws the field instead of its directory, and keys
    /// go there rather than through the keymap.
    path_edit: ?PathEdit = null,
    /// Type-to-find: what's been typed so far, moving the cursor to the
    /// first entry that starts with it. Cleared by anything that moves
    /// the cursor or changes the listing -- see `clearFind`.
    find_buf: [find_max]u8 = undefined,
    find_len: usize = 0,
    /// Where each dialog button was drawn: its row and column span, in
    /// dialog-layer cells, for a click to hit.
    button_spans: [8]struct { row: usize, col: usize, w: usize } = undefined,
    dialog_pos: struct { row: usize, col: usize } = .{ .row = 0, .col = 0 },

    /// A transient bar message; cleared on the next key.
    message: ?[]u8 = null,
    pane_dirty: [2]bool = .{ true, true },
    bar_dirty: bool = true,
    /// The last `content_extent`/offset sent per pane, so an unchanged one
    /// isn't re-sent (and a host-driven scroll isn't echoed back).
    pushed_scroll: [2][2]usize = .{ .{ std.math.maxInt(usize), 0 }, .{ std.math.maxInt(usize), 0 } },
    last_click: struct { pane: usize = 0, row: usize = 0, at_ms: i64 = 0 } = .{},
    quit: bool = false,

    pub const InitOptions = struct {
        left: []const u8,
        right: []const u8,
        home: ?[]const u8,
        /// Taken over by the `Ui`.
        cfg: config_mod.Config,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        opts: InitOptions,
    ) !*Ui {
        var cfg = opts.cfg;
        errdefer cfg.deinit(alloc);

        var keymap = try actions.Keymap.initDefaults(alloc, &actions.defaults);
        errdefer keymap.deinit(alloc);
        _ = config_mod.applyKeys(alloc, &keymap, cfg.keys);

        const pane_opts: pane_mod.Options = .{ .show_hidden = cfg.show_hidden, .view = cfg.view };
        var left = try Pane.init(alloc, io, opts.left, pane_opts);
        errdefer left.deinit();
        var right = try Pane.init(alloc, io, opts.right, pane_opts);
        errdefer right.deinit();

        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        const context = try client.createContext(null, null, 0, false);
        errdefer client.destroyContext(context) catch {};
        try listener.attachContext(context);
        // Nothing here takes text at a host caret; the dialog's field
        // draws its own.
        try client.setCaretVisible(false);

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        const left_layer = try client.createLayer(size.cols, size.rows, 0);
        const right_layer = try client.createLayer(size.cols, size.rows, 0);
        const bar_layer = try client.createLayer(size.cols, 1, 0);
        // The Ctrl+` shell panel. `gw-shell --embed` draws its prompt and
        // its commands' output here, so it carries scrollback of its own
        // for the shell's Ctrl+Up browsing -- see `shellpanel.zig`.
        const shell_layer = try client.createLayer(size.cols, 1, shellpanel.scrollback_rows);
        // Created last so it composites over everything else, the panel
        // included: a modal question belongs on top of a shell.
        const dialog_layer = try client.createLayer(10, 5, 0);

        try client.setLayerBackground(glyphwire.root_layer_handle, bg_pane);
        for ([_]glyphwire.LayerHandle{ left_layer, right_layer }) |l| {
            try client.setLayerBackground(l, bg_pane);
            try client.setLayerScrollMode(l, .client);
            try client.setLayerScrollbars(l, true, false);
        }
        try client.setLayerBackground(bar_layer, bg_bar);
        try client.setLayerBackground(dialog_layer, bg_dialog);
        try client.setLayerVisible(dialog_layer, false);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .client = client,
            .listener = listener,
            .home = opts.home,
            .context = context,
            .pane_layers = .{ left_layer, right_layer },
            .bar_layer = bar_layer,
            .dialog_layer = dialog_layer,
            .shell = shellpanel.Panel.init(alloc, io, client, context, shell_layer),
            .win = .{ .cols = size.cols, .rows = size.rows },
            .cell = .{ .w = metrics.w, .h = metrics.h },
            .cfg = cfg,
            .keymap = keymap,
            .panes = .{ left, right },
        };
        try self.placeLayers();
        return self;
    }

    pub fn deinit(self: *Ui) void {
        const alloc = self.alloc;
        // Before the context goes: the shell draws on a layer inside it,
        // and closing its control pipe is what tells it to leave.
        self.shell.deinit();
        self.endPathEdit();
        for (&self.panes) |*p| p.deinit();
        self.keymap.deinit(alloc);
        self.cfg.deinit(alloc);
        if (self.message) |m| alloc.free(m);
        self.client.destroyContext(self.context) catch {};
        alloc.destroy(self);
    }

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            try self.flush();
            const first = try self.listener.next(.none) orelse continue;
            try self.handleEvent(first);
            while (!self.quit) {
                const ev = self.listener.pollNext() orelse break;
                try self.handleEvent(ev);
            }
        }
    }

    fn handleEvent(self: *Ui, ev: glyphwire.Event) !void {
        defer ev.deinit(self.alloc);
        // `exit` typed into the shell panel (or a shell that died): the
        // panel closes itself and this keystroke is the file manager's
        // again.
        if (self.shell.reapIfExited()) self.markAllDirty();
        switch (ev) {
            .resize => |r| try self.handleResize(r),
            .scroll_offset => |so| {
                for (self.pane_layers, 0..) |l, i| {
                    if (so.layer != l) continue;
                    self.clearFind();
                    const p = &self.panes[i];
                    p.scrollTo(so.row / p.view.rowHeight(), self.visibleRows(i));
                    self.pushed_scroll[i][1] = so.row;
                    self.pane_dirty[i] = true;
                }
            },
            .mouse_button => |m| try self.handleMouseButton(m),
            .key => |k| if (k.pressed) try self.handleKey(k),
            .text, .paste => |t| if (self.path_edit) |*e| {
                try e.line.insert(self.alloc, t.text);
                self.pane_dirty[e.pane] = true;
            } else {
                // Nothing else takes typing, so it's type-to-find.
                try self.typeToFind(t.text);
            },
            .shutdown => self.quit = true,
            else => {},
        }
    }

    fn handleResize(self: *Ui, r: glyphwire.ResizeEvent) !void {
        self.win = .{ .cols = r.cols, .rows = r.rows };
        // A font-size step changes the cell metrics too, and arrives as
        // one resize.
        if (self.client.getCellMetrics()) |m| {
            self.cell = .{ .w = m.w, .h = m.h };
        } else |_| {}
        try self.placeLayers();
        self.markAllDirty();
    }

    fn markAllDirty(self: *Ui) void {
        self.pane_dirty = .{ true, true };
        self.bar_dirty = true;
    }

    fn handleKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        // With the shell panel open the keyboard is the shell's: both
        // programs are sent every keystroke (one context, one input
        // stream), so the only one taken here is the key that closes it.
        if (self.shell.isOpen()) {
            if (self.keymap.lookup(k.key, k.mods)) |action| {
                if (action == .toggleShell) try self.perform(.toggleShell);
            }
            return;
        }

        self.clearMessage();
        if (self.path_edit != null) return self.pathEditKey(k);

        // Editing the find prefix comes before the keymap: with one up,
        // Backspace takes a character back off it and Escape drops it.
        if (self.find_len > 0) {
            if (std.mem.eql(u8, k.key, "escape")) return self.clearFind();
            if (std.mem.eql(u8, k.key, "backspace")) return self.findBackspace();
        }

        // An unbound key leaves the prefix alone -- only something that
        // actually does anything counts as moving on from it.
        const action = self.keymap.lookup(k.key, k.mods) orelse return;
        self.clearFind();
        try self.perform(action);
    }

    // ── Type to find ────────────────────────────────────────────────────

    /// Typed text: extend the prefix and put the cursor on the first
    /// entry that starts with it. Text that would match nothing is
    /// dropped rather than added, so the prefix always describes where
    /// the cursor is. Space is left out of it: it's the marking key.
    fn typeToFind(self: *Ui, text: []const u8) !void {
        const p = &self.panes[self.active];
        for (text) |c| {
            if (c < 0x20 or c == 0x7f or c == ' ') continue;
            if (self.find_len == find_max) break;
            self.find_buf[self.find_len] = c;
            const candidate = self.find_buf[0 .. self.find_len + 1];
            const row = p.rowStartingWith(candidate) orelse continue;
            self.find_len += 1;
            p.setCursor(row);
        }
        if (self.find_len == 0) return;
        self.pane_dirty[self.active] = true;
        try self.setMessage("find: {s}", .{self.find_buf[0..self.find_len]});
    }

    /// Backspace over the prefix, moving the cursor back to what the
    /// shorter one finds. Emptying it is the same as dropping it.
    fn findBackspace(self: *Ui) void {
        self.find_len -= 1;
        if (self.find_len == 0) return self.clearFind();
        const p = &self.panes[self.active];
        if (p.rowStartingWith(self.find_buf[0..self.find_len])) |row| p.setCursor(row);
        self.pane_dirty[self.active] = true;
        self.setMessage("find: {s}", .{self.find_buf[0..self.find_len]}) catch {};
    }

    /// Drops the prefix. Called by everything that moves the cursor or
    /// changes what's listed -- any action, a click, a wheel tick -- so
    /// the next letter typed starts a new search.
    fn clearFind(self: *Ui) void {
        if (self.find_len == 0) return;
        self.find_len = 0;
        self.clearMessage();
        self.pane_dirty[self.active] = true;
    }

    /// Carries out one action on the active pane. Every command, whatever
    /// key or click triggered it, comes through here.
    pub fn perform(self: *Ui, action: Action) !void {
        const i = self.active;
        const p = &self.panes[i];
        const visible = self.visibleRows(i);
        switch (action) {
            .cursorUp => p.moveCursor(-1),
            .cursorDown => p.moveCursor(1),
            .pageUp => p.moveCursor(-@as(i64, @intCast(@max(visible -| 1, 1)))),
            .pageDown => p.moveCursor(@intCast(@max(visible -| 1, 1))),
            .cursorHome => p.cursorHome(),
            .cursorEnd => p.cursorEnd(),
            .activate => try self.activate(i),
            .upToParentDir => {
                _ = p.upToParentDir() catch |err| try self.setMessage("can't go up: {t}", .{err});
            },
            .editPath => try self.beginPathEdit(),
            .switchPane => {
                self.active = 1 - i;
                self.pane_dirty = .{ true, true };
            },
            .otherPaneToSameDir => {
                const other = &self.panes[1 - i];
                other.load(p.path) catch |err| try self.setMessage("{s}: {t}", .{ p.path, err });
                self.pane_dirty[1 - i] = true;
            },
            .swapPanes => {
                std.mem.swap(Pane, &self.panes[0], &self.panes[1]);
                self.pane_dirty = .{ true, true };
            },

            .toggleMark => p.toggleMark(p.cursor),
            .toggleMarkAndDown => {
                p.toggleMark(p.cursor);
                p.moveCursor(1);
            },
            .markAll => p.markAll(),
            .unmarkAll => p.unmarkAll(),
            .invertMarks => p.invertMarks(),

            .copy => try self.transfer(.copy),
            .move => try self.transfer(.move),
            .makeDir => try self.makeDir(),
            .delete => try self.deleteSelection(),

            .toggleShell => try self.toggleShell(),

            .viewSmall => p.view = .small,
            .viewLarge => p.view = .large,
            .toggleView => p.view = if (p.view == .small) .large else .small,
            .toggleHidden => p.setShowHidden(!p.show_hidden) catch |err| try self.setMessage("reread failed: {t}", .{err}),
            .refresh => try self.reloadBoth(),
            .quit => self.quit = true,
        }
        self.pane_dirty[i] = true;
        self.bar_dirty = true;
        // Whatever just happened may have moved the active side or its
        // directory; the panel follows both, and says nothing when
        // neither changed.
        self.shell.setCwd(self.panes[self.active].path);
    }

    /// Ctrl+`: show the shell panel (starting it the first time) or hide
    /// it again. Hiding leaves the shell running -- its history and its
    /// half-typed line are still there when it comes back.
    fn toggleShell(self: *Ui) !void {
        if (self.shell.isOpen()) {
            self.shell.close();
            self.markAllDirty();
            return;
        }
        self.endPathEdit();
        self.clearFind();
        self.shell.open(self.panes[self.active].path, .{ .cols = self.win.cols, .rows = self.win.rows }) catch |err| {
            try self.setMessage("can't start gw-shell: {t}", .{err});
            return;
        };
    }

    fn activate(self: *Ui, i: usize) !void {
        const p = &self.panes[i];
        const result = p.enter() catch |err| {
            const name = if (p.current()) |e| e.name else "..";
            try self.setMessage("{s}: {t}", .{ name, err });
            return;
        };
        switch (result) {
            .none, .changed_dir => {},
            // `enter` borrows the path from the pane's listing, and
            // opening reloads it -- copy before anything can free it.
            .file => |path| {
                const owned = try self.alloc.dupe(u8, path);
                defer self.alloc.free(owned);
                try self.openFile(owned);
            },
        }
    }

    /// Opens a file with whatever `open_actions` says (see
    /// `openaction.zig`): a glyphwire client runs here in the session,
    /// anything unclaimed goes to the desktop opener.
    fn openFile(self: *Ui, path: []const u8) !void {
        const user = try self.cfg.openActions(self.alloc);
        defer self.alloc.free(user);
        const template = openaction.resolve(user, path) orelse return self.openExternal(path);

        var argv_buf: [openaction.max_args][]const u8 = undefined;
        const argv = openaction.buildArgv(&argv_buf, template, path) catch |err| {
            try self.setMessage("open_actions \"{s}\": {t}", .{ template, err });
            return;
        };
        try self.runInSession(argv);
    }

    /// Runs a glyphwire client and waits for it. The child inherits
    /// `GLYPHWIRE_SOCK`, so it opens its own context, which the host
    /// stacks over ours and hands the keyboard to; we're just blocked
    /// until it exits. Its stdio is dropped -- this pane's stdout is the
    /// shell's screen, sitting under our context, and writing there would
    /// show up as damage once we're gone.
    fn runInSession(self: *Ui, argv: []const []const u8) !void {
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            try self.setMessage("{s}: {t}", .{ argv[0], err });
            return;
        };
        const term = child.wait(self.io) catch |err| {
            try self.setMessage("{s}: {t}", .{ argv[0], err });
            try self.resync();
            return;
        };
        try self.resync();
        switch (term) {
            .exited => |code| if (code != 0) try self.setMessage("{s} exited with {d}", .{ argv[0], code }),
            else => try self.setMessage("{s} was killed", .{argv[0]}),
        }
    }

    /// Takes the screen back after a child had it. A resize that happened
    /// while we weren't drawing may have arrived as an event we haven't
    /// read yet, so re-read the size instead of trusting what we last
    /// saw, and reread both directories: the child may well have changed
    /// what's in them.
    fn resync(self: *Ui) !void {
        if (self.client.getSize()) |size| {
            self.win = .{ .cols = size.cols, .rows = size.rows };
        } else |_| {}
        if (self.client.getCellMetrics()) |m| {
            self.cell = .{ .w = m.w, .h = m.h };
        } else |_| {}
        try self.placeLayers();
        try self.reloadBoth();
        self.markAllDirty();
    }

    /// Hands a file to the desktop's opener, detached (`setsid -f`) so
    /// the commander doesn't wait on it.
    fn openExternal(self: *Ui, path: []const u8) !void {
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "setsid", "-f", "xdg-open", path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            try self.setMessage("couldn't run xdg-open ({t})", .{err});
            return;
        };
        _ = child.wait(self.io) catch {};
        try self.setMessage("opening {s}", .{std.fs.path.basename(path)});
    }

    // ── Editing a pane's path ───────────────────────────────────────────

    /// Alt+D: turn the active pane's title row into a text field holding
    /// its directory. There's no dialog -- the path is edited where it's
    /// shown, and until Enter or Escape every key goes to the field.
    fn beginPathEdit(self: *Ui) !void {
        self.endPathEdit(); // Alt+D on the other side moves the field.
        const p = &self.panes[self.active];
        self.path_edit = .{ .pane = self.active, .line = try LineEdit.init(self.alloc, p.path) };
        self.pane_dirty[self.active] = true;
    }

    /// Closes the field and puts the title back, keeping nothing typed.
    fn endPathEdit(self: *Ui) void {
        if (self.path_edit) |*e| {
            e.line.deinit(self.alloc);
            self.pane_dirty[e.pane] = true;
        }
        self.path_edit = null;
    }

    /// Puts the caret where a click in the open field landed. `col` is a
    /// window column; the field starts one cell into its pane, and a
    /// click left of the text or past its end clamps to the ends.
    fn movePathCaret(self: *Ui, col: usize) void {
        const e = if (self.path_edit) |*pe| pe else return;
        const cells = col -| (self.paneCol(e.pane) + 1);
        e.line.caret = offsetAtCol(e.line.text(), e.view_start, cells);
        self.pane_dirty[e.pane] = true;
    }

    /// Keys while a title row is a field: Enter goes where it says,
    /// Escape puts the directory back, and the rest are the same editing
    /// keys a dialog's field has. Nothing falls through to the keymap --
    /// a `d` typed into a path isn't a command.
    fn pathEditKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const e = if (self.path_edit) |*pe| pe else return;
        if (std.mem.eql(u8, k.key, "escape")) return self.endPathEdit();
        if (std.mem.eql(u8, k.key, "enter") or std.mem.eql(u8, k.key, "kp_enter")) {
            const i = e.pane;
            // Copied: closing the field frees the text it's read from.
            const typed = try self.alloc.dupe(u8, std.mem.trim(u8, e.line.text(), " "));
            defer self.alloc.free(typed);
            self.endPathEdit();
            if (typed.len == 0) return;

            const p = &self.panes[i];
            const path = try self.resolveTyped(p.path, typed);
            defer self.alloc.free(path);
            p.load(path) catch |err| try self.setMessage("{s}: {t}", .{ typed, err });
            self.pane_dirty[i] = true;
            self.bar_dirty = true;
            return;
        }
        _ = e.line.handleKey(k.key, k.ctrl());
        self.pane_dirty[e.pane] = true;
    }

    fn reloadBoth(self: *Ui) !void {
        for (&self.panes, 0..) |*p, i| {
            p.reload() catch |err| try self.setMessage("{s}: {t}", .{ p.path, err });
            self.pane_dirty[i] = true;
        }
    }

    // ── Mouse ───────────────────────────────────────────────────────────

    fn handleMouseButton(self: *Ui, m: glyphwire.MouseButtonEvent) !void {
        if (!m.pressed) return;
        const left = std.mem.eql(u8, m.button, "left");
        const right = std.mem.eql(u8, m.button, "right");
        if (!left and !right) return;
        if (m.cell.row >= self.paneHeight()) return;

        const i: usize = if (m.cell.col < self.leftWidth()) 0 else 1;
        if (i != self.active) {
            self.active = i;
            self.pane_dirty = .{ true, true };
        }

        // A left click on a title row is about the path: it opens the
        // field there, or moves the caret in the one already open --
        // Alt+D with the mouse.
        if (m.cell.row == 0 and left) {
            if (self.pathEditFor(i)) |_| self.movePathCaret(m.cell.col) else try self.beginPathEdit();
            return;
        }
        // Clicking anywhere else is leaving the field, not typing in it.
        self.endPathEdit();
        self.clearFind();

        const p = &self.panes[i];
        if (m.cell.row < list_top) return;
        const slot = (m.cell.row - list_top) / p.view.rowHeight();
        if (slot >= self.visibleRows(i)) return;
        const row = p.top + slot;
        if (row >= p.rowCount()) return;

        p.setCursor(row);
        self.pane_dirty[i] = true;
        if (right or (left and m.mods.ctrl)) {
            // Total Commander's right-click select, and Ctrl+click as the
            // mouse's Space. Neither opens anything: a Ctrl+click is
            // picking files out of a list, and two of them in a row must
            // not turn into an activation.
            p.toggleMark(row);
            self.last_click.at_ms = 0;
            return;
        }

        const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        const lc = self.last_click;
        self.last_click = .{ .pane = i, .row = row, .at_ms = now };
        if (lc.pane == i and lc.row == row and now - lc.at_ms <= double_click_ms) {
            self.last_click.at_ms = 0;
            try self.activate(i);
        }
    }

    // ── File operations ─────────────────────────────────────────────────

    /// F5 / F6: copy or move the selection, to a destination the user
    /// confirms (the other pane's directory to start with).
    fn transfer(self: *Ui, kind: fileops.Kind) !void {
        const src_i = self.active;
        const src = &self.panes[src_i];
        const sel = try src.selection(self.alloc);
        defer self.alloc.free(sel);
        if (sel.len == 0) return;

        const what = try describeSelection(self.alloc, sel);
        defer self.alloc.free(what);
        const prompt = try std.fmt.allocPrint(self.alloc, "{s} {s} to:", .{ kind.label(), what });
        defer self.alloc.free(prompt);

        var d = try Dialog.init(self.alloc, kind.label(), prompt, &dialog_mod.ok_cancel, .{ .input = self.panes[1 - src_i].path });
        defer d.deinit(self.alloc);
        if (try self.runDialog(&d) != .ok) return;

        const dest = try self.resolveTyped(src.path, d.inputText());
        defer self.alloc.free(dest);

        const result = self.runOperation(.{ .kind = kind, .sources = sel, .dest = dest });
        if (!result.cancelled and result.failed == 0) src.unmarkAll();
        try self.reloadBoth();
        try self.reportResult(kind, result);
    }

    /// F8: delete the selection after a yes/no. The default button is No,
    /// so a stray Enter doesn't delete anything.
    fn deleteSelection(self: *Ui) !void {
        const p = &self.panes[self.active];
        const sel = try p.selection(self.alloc);
        defer self.alloc.free(sel);
        if (sel.len == 0) return;

        const what = try describeSelection(self.alloc, sel);
        defer self.alloc.free(what);
        const prompt = try std.fmt.allocPrint(self.alloc, "Delete {s}?", .{what});
        defer self.alloc.free(prompt);

        var d = try Dialog.init(self.alloc, "Delete", prompt, &dialog_mod.yes_no, .{ .danger = true, .focus = 1 });
        defer d.deinit(self.alloc);
        if (try self.runDialog(&d) != .yes) return;

        const result = self.runOperation(.{ .kind = .delete, .sources = sel });
        try self.reloadBoth();
        try self.reportResult(.delete, result);
    }

    /// F7: make a directory (and any missing parents) in the active pane,
    /// then put the cursor on it.
    fn makeDir(self: *Ui) !void {
        const p = &self.panes[self.active];
        var d = try Dialog.init(self.alloc, "Make directory", "Name of the new directory:", &dialog_mod.ok_cancel, .{ .input = "" });
        defer d.deinit(self.alloc);
        if (try self.runDialog(&d) != .ok) return;
        const typed = std.mem.trim(u8, d.inputText(), " ");
        if (typed.len == 0) return;

        const path = try self.resolveTyped(p.path, typed);
        defer self.alloc.free(path);
        fileops.makeDir(self.io, path) catch |err| {
            try self.setMessage("mkdir {s}: {t}", .{ typed, err });
            return;
        };
        try self.reloadBoth();
        // `a/b/c` creates `a` here; land on that.
        const first = typed[0 .. std.mem.indexOfScalar(u8, typed, '/') orelse typed.len];
        if (p.rowOf(first)) |row| p.setCursor(row);
        try self.setMessage("created {s}", .{typed});
    }

    fn runOperation(self: *Ui, op: fileops.Operation) fileops.Result {
        const hooks: fileops.Hooks = .{
            .ctx = self,
            .onConflict = hookConflict,
            .onProgress = hookProgress,
            .onError = hookError,
        };
        return op.run(self.io, self.alloc, hooks);
    }

    fn hookConflict(ctx: *anyopaque, src: []const u8, dest: []const u8) fileops.Conflict {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        const msg = std.fmt.allocPrint(self.alloc, "Target already exists:\n{s}\n\nReplace it with:\n{s}", .{ dest, src }) catch return .cancel;
        defer self.alloc.free(msg);
        var d = Dialog.init(self.alloc, "File exists", msg, &dialog_mod.conflict_buttons, .{ .danger = true }) catch return .cancel;
        defer d.deinit(self.alloc);
        const b = self.runDialog(&d) catch return .cancel;
        return switch (b) {
            .overwrite => .overwrite,
            .skip => .skip,
            .overwrite_all => .overwrite_all,
            .skip_all => .skip_all,
            else => .cancel,
        };
    }

    fn hookProgress(ctx: *anyopaque, kind: fileops.Kind, index: usize, total: usize, path: []const u8) void {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.setMessage("{s} {d}/{d}: {s}", .{ kind.label(), index + 1, total, std.fs.path.basename(path) }) catch return;
        // Drawn now: the loop that would normally flush it is blocked
        // until the operation finishes.
        self.renderBar() catch {};
    }

    fn hookError(ctx: *anyopaque, path: []const u8, err: anyerror) bool {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        const msg = std.fmt.allocPrint(self.alloc, "{s}\n\n{s}", .{ path, errorText(err) }) catch return false;
        defer self.alloc.free(msg);
        var d = Dialog.init(self.alloc, "Error", msg, &dialog_mod.error_buttons, .{ .danger = true }) catch return false;
        defer d.deinit(self.alloc);
        const b = self.runDialog(&d) catch return false;
        return b == .@"continue";
    }

    fn reportResult(self: *Ui, kind: fileops.Kind, r: fileops.Result) !void {
        const verb = switch (kind) {
            .copy => "copied",
            .move => "moved",
            .delete => "deleted",
        };
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{s} {d}", .{ verb, r.done }) catch {};
        if (r.skipped > 0) w.print(", skipped {d}", .{r.skipped}) catch {};
        if (r.failed > 0) w.print(", {d} failed", .{r.failed}) catch {};
        if (r.first_error) |e| w.print(" ({s})", .{errorText(e)}) catch {};
        if (r.cancelled) w.writeAll(", cancelled") catch {};
        try self.setMessage("{s}", .{w.buffered()});
    }

    /// A path typed into a dialog, made absolute: `~` is the home
    /// directory and a relative path is taken from `base` (the pane's
    /// directory, where the user is looking). Caller owns the result.
    fn resolveTyped(self: *Ui, base: []const u8, typed: []const u8) ![]u8 {
        const t = std.mem.trim(u8, typed, " ");
        if (self.home) |home| {
            if (std.mem.eql(u8, t, "~")) return std.fs.path.resolve(self.alloc, &.{home});
            if (std.mem.startsWith(u8, t, "~/")) return std.fs.path.resolve(self.alloc, &.{ home, t[2..] });
        }
        if (std.fs.path.isAbsolute(t)) return std.fs.path.resolve(self.alloc, &.{t});
        return std.fs.path.resolve(self.alloc, &.{ base, t });
    }

    // ── Dialogs ─────────────────────────────────────────────────────────

    /// Shows `d` and runs a nested event loop until one of its buttons is
    /// pressed. Resizes keep redrawing everything underneath; a shutdown
    /// answers with the dialog's escape button and ends the program.
    pub fn runDialog(self: *Ui, d: *Dialog) !Button {
        self.dialog = d;
        defer {
            self.dialog = null;
            self.client.setLayerVisible(self.dialog_layer, false) catch {};
        }
        try self.flush();
        try self.renderDialog();

        while (true) {
            const ev = try self.listener.next(.none) orelse continue;
            defer ev.deinit(self.alloc);
            switch (ev) {
                .key => |k| if (k.pressed) {
                    if (d.handleKey(k.key, k.ctrl(), k.shift())) |b| return b;
                    try self.renderDialog();
                },
                .text, .paste => |t| {
                    try d.handleText(self.alloc, t.text);
                    try self.renderDialog();
                },
                .mouse_button => |m| if (m.pressed and std.mem.eql(u8, m.button, "left")) {
                    if (self.buttonAt(m.cell)) |b| return b;
                },
                .resize => |r| {
                    try self.handleResize(r);
                    try self.flush();
                    try self.renderDialog();
                },
                .shutdown => {
                    self.quit = true;
                    return d.handleKey("escape", false, false).?;
                },
                else => {},
            }
        }
    }

    fn buttonAt(self: *const Ui, cell: glyphwire.CellPos) ?Button {
        const d = self.dialog orelse return null;
        if (cell.row < self.dialog_pos.row or cell.col < self.dialog_pos.col) return null;
        const r = cell.row - self.dialog_pos.row;
        const c = cell.col - self.dialog_pos.col;
        for (d.buttons, 0..) |b, i| {
            if (i >= self.button_spans.len) break;
            const s = self.button_spans[i];
            if (r == s.row and c >= s.col and c < s.col + s.w) return b;
        }
        return null;
    }

    fn renderDialog(self: *Ui) !void {
        const d = self.dialog orelse return;
        const layer = self.dialog_layer;

        // Size: wide enough for the longest message line and the buttons,
        // a comfortable width for a path field, never wider than the
        // window allows.
        var widest: usize = glyphwire.stringWidth(d.title) + 4;
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, d.message, '\n');
        while (it.next()) |line| {
            widest = @max(widest, glyphwire.stringWidth(line));
            lines += 1;
        }
        var buttons_w: usize = 0;
        for (d.buttons) |b| buttons_w += b.label().len + 4 + 1;
        widest = @max(widest, buttons_w);
        if (d.input != null) widest = @max(widest, 60);
        const max_w = self.win.cols -| 4;
        const w = @min(widest + 4, @max(max_w, 20));
        const input_rows: usize = if (d.input != null) 2 else 0;
        // title, blank, message, blank, [input, blank], buttons, blank
        const h = @min(1 + 1 + lines + 1 + input_rows + 1 + 1, @max(self.win.rows -| 2, 6));
        const row0 = (self.win.rows -| h) / 2;
        const col0 = (self.win.cols -| w) / 2;
        self.dialog_pos = .{ .row = row0, .col = col0 };

        var b = self.client.batch();
        defer b.deinit();
        try b.setLayerSize(layer, w, h);
        try b.setLayerCellPosition(layer, row0, col0);
        try b.clearArea(.{ .layer = layer, .bg = bg_dialog });

        const title_bg = if (d.danger) bg_dialog_danger else bg_dialog_title;
        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, " {s} ", .{d.title}) catch d.title;
        const title_col = (w -| glyphwire.stringWidth(title)) / 2;
        try b.clearArea(.{ .layer = layer, .row = 0, .rows = 1, .bg = title_bg });
        try b.writeTextOpts(title, .{ .layer = layer, .row = 0, .col = title_col, .fg = fg_title_active, .bg = title_bg, .max_cols = w });

        var row: usize = 2;
        it = std.mem.splitScalar(u8, d.message, '\n');
        while (it.next()) |line| : (row += 1) {
            if (row >= h -| 2) break;
            try b.writeTextOpts(line, .{ .layer = layer, .row = row, .col = 2, .fg = fg_dialog, .bg = bg_dialog, .max_cols = w -| 4 });
        }
        row += 1;

        if (d.input) |*in| {
            const field_w = w -| 4;
            const view = fieldView(in.text(), in.caret, field_w);
            try b.writeTextOpts(in.text()[view.start..], .{ .layer = layer, .row = row, .col = 2, .fg = fg_dialog, .bg = bg_input, .max_cols = field_w, .pad = true });
            // The caret: the character under it (or a blank past the end)
            // drawn in reverse.
            const under = if (in.caret < in.text().len) in.text()[in.caret..nextCodepoint(in.text(), in.caret)] else " ";
            try b.writeTextOpts(under, .{ .layer = layer, .row = row, .col = 2 + view.caret_col, .fg = bg_input, .bg = fg_dialog });
            row += 2;
        }

        // Buttons, centred: `[ OK ]` with the hotkey letter picked out
        // when there's no text field to type it into.
        var col = (w -| buttons_w) / 2;
        for (d.buttons, 0..) |btn, i| {
            const label = btn.label();
            const bw = label.len + 4;
            const focused = i == d.focus;
            const bg = if (focused) bg_button_focus else bg_button;
            var lbuf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&lbuf, "[ {s} ]", .{label}) catch label;
            try b.writeTextOpts(text, .{ .layer = layer, .row = row, .col = col, .fg = fg_dialog, .bg = bg });
            if (d.input == null) {
                try b.writeTextOpts(label[0..1], .{ .layer = layer, .row = row, .col = col + 2, .fg = fg_marked, .bg = bg });
            }
            if (i < self.button_spans.len) self.button_spans[i] = .{ .row = row, .col = col, .w = bw };
            col += bw + 1;
        }

        try b.setLayerVisible(layer, true);
        var sent = try b.send();
        sent.deinit();
    }

    // ── Geometry ────────────────────────────────────────────────────────

    fn leftWidth(self: *const Ui) usize {
        return self.win.cols / 2;
    }

    fn paneHeight(self: *const Ui) usize {
        return self.win.rows -| 1;
    }

    fn paneCol(self: *const Ui, i: usize) usize {
        return if (i == 0) 0 else self.leftWidth();
    }

    fn paneWidth(self: *const Ui, i: usize) usize {
        return if (i == 0) self.leftWidth() else self.win.cols - self.leftWidth();
    }

    /// The field open on pane `i`'s title row, if that's where it is.
    fn pathEditFor(self: *Ui, i: usize) ?*PathEdit {
        if (self.path_edit) |*e| {
            if (e.pane == i) return e;
        }
        return null;
    }

    /// How many entries fit in pane `i`'s list area.
    fn visibleRows(self: *const Ui, i: usize) usize {
        const list_rows = self.paneHeight() -| chrome_rows;
        return @max(list_rows / self.panes[i].view.rowHeight(), 1);
    }

    fn placeLayers(self: *Ui) !void {
        var b = self.client.batch();
        defer b.deinit();
        for (self.pane_layers, 0..) |l, i| {
            try b.setLayerSize(l, self.paneWidth(i), self.paneHeight());
            try b.setLayerCellPosition(l, 0, self.paneCol(i));
        }
        try b.setLayerSize(self.bar_layer, self.win.cols, 1);
        try b.setLayerCellPosition(self.bar_layer, self.paneHeight(), 0);
        var sent = try b.send();
        sent.deinit();
        self.pushed_scroll = .{ .{ std.math.maxInt(usize), 0 }, .{ std.math.maxInt(usize), 0 } };
        // The panel spans the bottom of whatever the window is now, and
        // the shell inside it re-reads its layer when told.
        self.shell.place(.{ .cols = self.win.cols, .rows = self.win.rows }) catch {};
    }

    /// Icon height in pixels for `view`, capped to the rows it may use.
    fn iconPx(self: *const Ui, view: pane_mod.ViewMode) u32 {
        return switch (view) {
            .small => @min(self.cfg.small_icon_px, self.cell.h),
            .large => @min(self.cfg.large_icon_px, 2 * self.cell.h),
        };
    }

    fn columns(self: *const Ui, w: usize, view: pane_mod.ViewMode) Columns {
        const px: usize = self.iconPx(view);
        const cw: usize = @max(self.cell.w, 1);
        const icon_cols = (px + cw - 1) / cw;
        const name_col = 1 + icon_cols + 1;
        const min_name = 12;
        if (w >= name_col + min_name + 1 + size_w + 1 + date_w + 1) {
            const date_col = w - 1 - date_w;
            const size_col = date_col - 1 - size_w;
            return .{ .icon_col = 1, .name_col = name_col, .name_w = size_col - 1 - name_col, .size_col = size_col, .date_col = date_col };
        }
        if (w >= name_col + min_name + 1 + size_w + 1) {
            const size_col = w - 1 - size_w;
            return .{ .icon_col = 1, .name_col = name_col, .name_w = size_col - 1 - name_col, .size_col = size_col, .date_col = null };
        }
        return .{ .icon_col = 1, .name_col = name_col, .name_w = w -| (name_col + 1), .size_col = null, .date_col = null };
    }

    // ── Rendering ───────────────────────────────────────────────────────

    fn flush(self: *Ui) !void {
        for (0..2) |i| {
            if (self.pane_dirty[i]) try self.renderPane(i);
        }
        if (self.bar_dirty) try self.renderBar();
    }

    fn renderPane(self: *Ui, i: usize) !void {
        self.pane_dirty[i] = false;
        const p = &self.panes[i];
        const layer = self.pane_layers[i];
        const w = self.paneWidth(i);
        const h = self.paneHeight();
        const active = i == self.active;
        const rh = p.view.rowHeight();
        const visible = self.visibleRows(i);
        p.scrollIntoView(visible);
        const cols = self.columns(w, p.view);

        var b = self.client.batch();
        defer b.deinit();
        try b.clearArea(.{ .layer = layer, .bg = bg_pane });

        // Title: the directory, `~`-shortened and cut from the left so the
        // end of a long path (the part that changes) stays visible --
        // unless Alt+D has made this row a field, which takes the whole
        // row and shows the path in full, from the caret back.
        {
            const bg = if (active) bg_title_active else bg_title_inactive;
            const fg = if (active) fg_title_active else fg_title_inactive;
            try b.clearArea(.{ .layer = layer, .row = 0, .rows = 1, .bg = bg });
            if (self.pathEditFor(i)) |e| {
                const in = &e.line;
                const field_w = w -| 2;
                const view = fieldView(in.text(), in.caret, field_w);
                e.view_start = view.start;
                try b.writeTextOpts(in.text()[view.start..], .{ .layer = layer, .row = 0, .col = 1, .fg = fg_dialog, .bg = bg_input, .max_cols = field_w, .pad = true });
                // The caret: the character under it (or a blank past the
                // end) in reverse, as a dialog's field draws it.
                const under = if (in.caret < in.text().len) in.text()[in.caret..nextCodepoint(in.text(), in.caret)] else " ";
                try b.writeTextOpts(under, .{ .layer = layer, .row = 0, .col = 1 + view.caret_col, .fg = bg_input, .bg = fg_dialog });
            } else {
                var pbuf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
                const shown = self.displayPath(&pbuf, p.path, w -| 2);
                try b.writeTextOpts(shown, .{ .layer = layer, .row = 0, .col = 1, .fg = fg, .bg = bg, .max_cols = w -| 2 });
            }
        }

        // Column headers.
        try b.clearArea(.{ .layer = layer, .row = 1, .rows = 1, .bg = bg_header });
        try b.writeTextOpts("Name", .{ .layer = layer, .row = 1, .col = cols.name_col, .fg = fg_header, .bg = bg_header });
        if (cols.size_col) |c| try b.writeTextOpts("    Size", .{ .layer = layer, .row = 1, .col = c, .fg = fg_header, .bg = bg_header });
        if (cols.date_col) |c| try b.writeTextOpts("Modified", .{ .layer = layer, .row = 1, .col = c, .fg = fg_header, .bg = bg_header });

        // Rows: text first, icons last -- a text write clears a cell's
        // foreground icon, and a tall icon spills into the row below.
        const end = @min(p.top + visible, p.rowCount());
        for (p.top..end) |row| try writeRow(&b, layer, p, row, list_top + (row - p.top) * rh, w, cols, active);
        const icon_px = self.iconPx(p.view);
        for (p.top..end) |row| {
            const icon = if (p.entryAt(row)) |e| lsentries.iconForEntry(e.*) else "file/folder";
            try b.drawIconOnStyled(layer, list_top + (row - p.top) * rh, cols.icon_col, icon, .{
                .scale = .natural,
                .h_align = .start,
                .v_align = if (rh > 1) .start else .center,
                .max_h = icon_px,
                .foreground = true,
            });
        }

        try writeFooter(&b, layer, p, h -| 1, w);

        // The host scrollbar, in list-row units: the extent is the whole
        // listing plus the chrome, so its range matches `top`'s.
        const extent = p.rowCount() * rh + chrome_rows + (self.paneHeight() -| chrome_rows) % rh;
        const offset = p.top * rh;
        if (self.pushed_scroll[i][0] != extent) try b.setLayerContentExtent(layer, w, extent);
        if (self.pushed_scroll[i][0] != extent or self.pushed_scroll[i][1] != offset) try b.setLayerScrollOffset(layer, offset, 0);
        self.pushed_scroll[i] = .{ extent, offset };

        var sent = try b.send();
        sent.deinit();
    }

    fn writeRow(b: *Batch, layer: glyphwire.LayerHandle, p: *const Pane, row: usize, y: usize, w: usize, cols: Columns, active_pane: bool) !void {
        const rh = p.view.rowHeight();
        const on_cursor = row == p.cursor;
        const marked = p.isMarked(row);
        // Striped by the row's place in the listing, not by where it
        // landed on screen, so the pattern doesn't crawl as the pane
        // scrolls. A two-row entry is one stripe.
        const bg = if (on_cursor)
            (if (active_pane) bg_cursor else bg_cursor_inactive)
        else if (row % 2 == 1) bg_row_alt else bg_pane;
        try b.clearArea(.{ .layer = layer, .row = y, .rows = rh, .cols = w, .bg = bg });

        const entry = p.entryAt(row);
        const name = if (entry) |e| e.name else "..";
        const fg = if (marked) fg_marked else if (entry) |e| entryColor(e.*) else fg_dir;
        const detail_fg = if (marked) fg_marked else fg_detail;

        if (marked) try b.writeTextOpts("*", .{ .layer = layer, .row = y, .col = 0, .fg = fg_marked, .bg = bg });

        var nbuf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
        const name_text = gridlayout.truncateToCols(&nbuf, name, cols.name_w);
        try b.writeTextOpts(name_text, .{ .layer = layer, .row = y, .col = cols.name_col, .fg = fg, .bg = bg });

        if (cols.size_col) |c| {
            var sbuf: [24]u8 = undefined;
            const size_text = if (entry) |e| blk: {
                if ((e.link_target_kind orelse e.kind) == .directory) break :blk "   <DIR>";
                break :blk lsfmt.formatSize(&sbuf, e.size, false);
            } else "    <UP>";
            try b.writeTextOpts(size_text, .{ .layer = layer, .row = y, .col = c, .fg = detail_fg, .bg = bg });
        }
        if (cols.date_col) |c| {
            if (entry) |e| {
                var tbuf: [20]u8 = undefined;
                try b.writeTextOpts(lsfmt.formatTimestamp(&tbuf, e.mtime_sec), .{ .layer = layer, .row = y, .col = c, .fg = detail_fg, .bg = bg });
            }
        }

        // Large view: permissions and owner under the name.
        if (rh > 1) {
            if (entry) |e| {
                var perm_buf: [10]u8 = undefined;
                var owner_buf: [160]u8 = undefined;
                var line_buf: [200]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "{s}  {s}", .{
                    lsfmt.formatPermBits(&perm_buf, e.mode),
                    lsentries.ownerGroupText(&owner_buf, e.uid, e.gid),
                }) catch "";
                try b.writeTextOpts(line, .{ .layer = layer, .row = y + 1, .col = cols.name_col, .fg = detail_fg, .bg = bg, .max_cols = w -| (cols.name_col + 1) });
            }
        }
    }

    /// The last row of a pane: what's marked (or the cursor's entry) on
    /// the left, and the directory's own total on the right -- how many
    /// entries are listed and what they add up to (`Pane.totalBytes`,
    /// this directory only).
    fn writeFooter(b: *Batch, layer: glyphwire.LayerHandle, p: *const Pane, row: usize, w: usize) !void {
        try b.clearArea(.{ .layer = layer, .row = row, .rows = 1, .bg = bg_footer });
        var buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
        const marked = p.markedCount();
        const text: []const u8 = if (marked > 0) blk: {
            var sbuf: [24]u8 = undefined;
            const size = std.mem.trim(u8, lsfmt.formatSize(&sbuf, p.markedBytes(), false), " ");
            break :blk std.fmt.bufPrint(&buf, "{d} of {d} marked, {s}", .{ marked, p.entries.len, size }) catch "";
        } else if (p.current()) |e| blk: {
            if (e.link_target) |t| break :blk std.fmt.bufPrint(&buf, "{s} -> {s}", .{ e.name, t }) catch "";
            break :blk std.fmt.bufPrint(&buf, "{s}", .{e.name}) catch "";
        } else "";

        var total_buf: [64]u8 = undefined;
        var tsize_buf: [24]u8 = undefined;
        const total_size = std.mem.trim(u8, lsfmt.formatSize(&tsize_buf, p.totalBytes(), false), " ");
        const total = std.fmt.bufPrint(&total_buf, "{d} items, {s}", .{ p.entries.len, total_size }) catch "";
        const total_w = glyphwire.stringWidth(total);

        // The total owns the right end; the left text gets what's left,
        // with a gap, and is cut to it rather than running underneath.
        var left_max = w -| 2;
        if (total_w > 0 and w >= total_w + 3) {
            try b.writeTextOpts(total, .{ .layer = layer, .row = row, .col = w - 1 - total_w, .fg = fg_detail, .bg = bg_footer });
            left_max = w -| (total_w + 3);
        }
        if (text.len > 0 and left_max > 0) {
            try b.writeTextOpts(text, .{ .layer = layer, .row = row, .col = 1, .fg = if (marked > 0) fg_marked else fg_footer, .bg = bg_footer, .max_cols = left_max });
        }
    }

    /// The bottom bar: a message if there is one, else the function keys
    /// with their current bindings (`F5 Copy`, ...), so a rebinding in the
    /// config shows up here too.
    fn renderBar(self: *Ui) !void {
        self.bar_dirty = false;
        const layer = self.bar_layer;
        var b = self.client.batch();
        defer b.deinit();
        try b.clearArea(.{ .layer = layer, .bg = bg_bar });

        if (self.message) |m| {
            try b.writeTextOpts(m, .{ .layer = layer, .row = 0, .col = 1, .fg = fg_message, .bg = bg_bar, .max_cols = self.win.cols -| 2 });
        } else {
            var col: usize = 0;
            for (actions.bar_actions) |a| {
                const chord = self.keymap.chordFor(a) orelse continue;
                var kbuf: [48]u8 = undefined;
                const key = chord.format(&kbuf);
                const label = actions.barLabel(a);
                const need = key.len + label.len + 2;
                if (col + need > self.win.cols) break;
                try b.writeTextOpts(key, .{ .layer = layer, .row = 0, .col = col, .fg = fg_bar_key, .bg = bg_bar });
                col += key.len;
                var lbuf: [32]u8 = undefined;
                const padded = std.fmt.bufPrint(&lbuf, "{s} ", .{label}) catch label;
                try b.writeTextOpts(padded, .{ .layer = layer, .row = 0, .col = col, .fg = fg_bar_label, .bg = bg_bar_label });
                col += padded.len + 1;
            }
        }
        var sent = try b.send();
        sent.deinit();
    }

    /// `path` with `$HOME` shown as `~`, cut from the left with a leading
    /// `…` when wider than `max_cols`. Borrows `buf`.
    fn displayPath(self: *const Ui, buf: []u8, path: []const u8, max_cols: usize) []const u8 {
        var shown = path;
        if (self.home) |home| {
            if (home.len > 1 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/')) {
                shown = std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
            }
        }
        if (max_cols == 0 or glyphwire.stringWidth(shown) <= max_cols) return shown;
        // Drop whole codepoints from the front until the rest fits after a
        // one-cell `…`.
        var start: usize = 0;
        while (start < shown.len and glyphwire.stringWidth(shown[start..]) + 1 > max_cols) {
            start = nextCodepoint(shown, start);
        }
        const tail = shown[start..];
        var out: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
        const joined = std.fmt.bufPrint(&out, "\u{2026}{s}", .{tail}) catch return tail;
        if (joined.len > buf.len) return tail;
        @memcpy(buf[0..joined.len], joined);
        return buf[0..joined.len];
    }

    fn setMessage(self: *Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.message) |m| self.alloc.free(m);
        self.message = try std.fmt.allocPrint(self.alloc, fmt, args);
        self.bar_dirty = true;
    }

    fn clearMessage(self: *Ui) void {
        if (self.message) |m| {
            self.alloc.free(m);
            self.message = null;
            self.bar_dirty = true;
        }
    }
};

fn entryColor(e: FileEntry) Color {
    return switch (e.kind) {
        .directory => fg_dir,
        .sym_link => fg_link,
        .other => fg_other,
        .file => if (e.mode & 0o111 != 0) fg_exec else fg_file,
    };
}

/// `"foo.txt"` for one path, `"3 files"` for several.
fn describeSelection(alloc: std.mem.Allocator, sel: []const []const u8) ![]u8 {
    if (sel.len == 1) return std.fmt.allocPrint(alloc, "\"{s}\"", .{std.fs.path.basename(sel[0])});
    return std.fmt.allocPrint(alloc, "{d} files", .{sel.len});
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.FileNotFound => "no such file or directory",
        error.PathAlreadyExists => "already exists",
        error.DestNotDirectory => "destination is not a directory",
        error.DestInsideSource => "can't put a directory inside itself",
        error.NoSpaceLeft => "no space left on device",
        error.ReadOnlyFileSystem => "read-only file system",
        error.DirNotEmpty => "directory not empty",
        else => @errorName(err),
    };
}

fn nextCodepoint(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return @min(i + len, s.len);
}

/// The byte offset `cells` display columns past `start` in `text`, on a
/// UTF-8 boundary and clamped to the end. A click that lands on the far
/// half of a wide character puts the caret before it rather than inside
/// it -- there is no offset inside one.
pub fn offsetAtCol(text: []const u8, start: usize, cells: usize) usize {
    var i = @min(start, text.len);
    var w: usize = 0;
    while (i < text.len) {
        const next = nextCodepoint(text, i);
        const cw = glyphwire.stringWidth(text[i..next]);
        if (w + cw > cells) break;
        w += cw;
        i = next;
    }
    return i;
}

/// Which part of a text field's contents to show so the caret stays in a
/// `width`-cell field: the byte to start drawing from, and the caret's
/// column within the field.
fn fieldView(text: []const u8, caret: usize, width: usize) struct { start: usize, caret_col: usize } {
    const w = @max(width, 2);
    var start: usize = 0;
    while (start < caret and glyphwire.stringWidth(text[start..caret]) >= w) {
        start = nextCodepoint(text, start);
    }
    return .{ .start = start, .caret_col = glyphwire.stringWidth(text[start..caret]) };
}
