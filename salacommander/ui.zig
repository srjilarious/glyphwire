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
//!     row 1        column headers -- clicking one re-orders the pane by
//!                  that column, clicking the active one flips it
//!     rows 2..     the listing, one row per entry (small view) or two
//!                  (large view: tall icon, name, then perms/owner)
//!     last row     a summary: what's marked (or the cursor entry) on the
//!                  left, the directory's item count and total on the right
//!
//! More layers sit over those: the Ctrl+` shell panel -- a `gw-shell
//! --embed` drawing its own prompt into a layer of ours, docked along an
//! edge or floating in the middle (`shell_position`; see
//! `applib/shellpanel.zig`) -- then F3's finder popup, the same
//! framed popup as zoe's Ctrl+P (`applib/finderpopup.zig`), the
//! Ctrl+Shift+P command palette (`applib/palette.zig`, zoe's too),
//! Alt+Down's directory history (the palette's list over the active
//! pane, see `dirhistory.zig`), and the modal dialog layer on top.
//!
//! A server-side `Table` would sort and paint for us, but it paints every
//! row and scrolls its layer the way terminal output does; a file pane
//! needs a fixed header, a cursor bar and marked-row colours, so the rows
//! are written here instead. Only the visible rows are sent, so a
//! directory of any size costs one screenful per redraw. The pane layers
//! are in `client` scroll mode with a `content_extent`, which gets a host
//! scrollbar and turns the wheel into `scroll_offset` events we follow.
//!
//! Directories always lead whatever the order is, and the sort is the
//! pane's, not the window's -- the two sides sort independently, which is
//! the point of having two of them. See `pane.Sort`.
//!
//! Keys go through the `Keymap` (`actions.zig`); every command is an
//! `Action` handled in `perform`. Typed text isn't a binding: with no
//! field open it's type-to-find, moving the cursor to the first entry
//! starting with what's been typed. A Ctrl+click marks a row the way
//! Space does, and never activates it. A plain drag carries the row, or
//! the marked set it belongs to, onto a folder or into the other pane
//! and moves it there on release -- copies, with Ctrl down at that
//! moment (`dragMove`, `drag.zig`); an Alt+drag carries the same out of
//! the window instead (`startDrag`). The dialogs run their own nested event
//! loop (`runDialog`), which is also what the file operations' conflict
//! and error hooks call -- so an operation is synchronous, and a question
//! halfway through a copy is just a dialog opened from inside it. F1's
//! menu and its chmod/chown forms (`attrdialog.zig`) run the same way,
//! in `runModal`.
//!
//! Held modifiers are tracked (`held`) from the key and mouse events, so
//! the key bar can show what each F-key does under them and the F1 menu
//! can say what a pick would run before it's made.

const std = @import("std");
const glyphwire = @import("glyphwire");
const pane_mod = @import("pane.zig");
const actions = @import("actions.zig");
const fileops = @import("fileops.zig");
const attrs = @import("attrs.zig");
const attrdialog = @import("attrdialog.zig");
const form_mod = @import("form.zig");
const dialog_mod = @import("dialog.zig");
const config_mod = @import("config.zig");
const openaction = @import("openaction.zig");
const drag_mod = @import("drag.zig");
const sudo = @import("sudo.zig");
const shellpanel = @import("applib").shellpanel;
const wordsplit = @import("applib").wordsplit;
const filetype = @import("applib").filetype;
const finder_mod = @import("applib").finder;
const finderpopup = @import("applib").finderpopup;
const palette_mod = @import("applib").palette;
const trash_mod = @import("applib").trash;
const Finder = finder_mod.Finder;

const Pane = pane_mod.Pane;
const FileEntry = pane_mod.FileEntry;
pub const Action = actions.Action;
const Dialog = dialog_mod.Dialog;
const Button = dialog_mod.Button;
const LineEdit = dialog_mod.LineEdit;
const lineedit = @import("applib").lineedit;
const Color = glyphwire.Color;
const Batch = glyphwire.Client.Batch;
const lsfmt = @import("applib").format;
const lsentries = @import("applib").entries;
const gridlayout = @import("applib").gridlayout;

// Every colour is a theme role the host resolves against this context's
// theme -- the window's, or `salacommander.conf.lua`'s `theme` -- so the
// names below just say which role each part of the screen is.
const role = Color.role;

const bg_pane = role(.bg);
/// Every other listing row, a shade up from `bg_pane` so a wide pane's
/// name and size columns stay on one line for the eye. Kept below the
/// header/footer shade: a stripe shouldn't read as chrome.
const bg_row_alt = role(.table_alt_row_bg);
const bg_header = role(.table_header_bg);
const bg_footer = role(.status_bg);
const bg_title_active = role(.title_bg);
const bg_title_inactive = role(.title_inactive_bg);
const bg_cursor = role(.list_cursor_bg);
const bg_cursor_inactive = role(.list_cursor_inactive_bg);
const fg_cursor = role(.list_cursor_fg);
const fg_cursor_inactive = role(.list_cursor_inactive_fg);
const bg_bar = role(.keybar_bg);
/// The Ctrl+` shell panel: darker than a pane, so it reads as a terminal
/// dropped over the file manager rather than as part of it.
const bg_shell = role(.shell_bg);
const bg_bar_label = role(.keybar_label_bg);
const bg_dialog = role(.dialog_bg);
const bg_dialog_title = role(.dialog_title_bg);
const bg_dialog_danger = role(.danger_bg);
const bg_input = role(.input_bg);
const bg_button_focus = role(.button_focus_bg);
const bg_button = role(.button_bg);

const fg_title_active = role(.title_fg);
const fg_title_inactive = role(.title_inactive_fg);
const fg_header = role(.table_header);
const fg_file = role(.file);
const fg_dir = role(.dir);
const fg_link = role(.symlink);
const fg_exec = role(.exec);
const fg_other = role(.special);
const fg_marked = role(.marked);
const fg_detail = role(.fg_dim);
const fg_footer = role(.status_fg);
const fg_bar_key = role(.keybar_key);
const fg_bar_label = role(.keybar_label);
const fg_message = role(.message);
const fg_dialog = role(.dialog_fg);

// The F3 finder popup (`applib/finderpopup.zig`, zoe's Ctrl+P): the
// panes' text colours, directories in their blue, and wider than zoe's --
// a file manager's search is rooted wherever the pane happens to be, so
// its paths run longer.
const finder_style: finderpopup.Style = .{
    .selected_bg = bg_cursor,
    .selected_fg = fg_cursor,
    .text_fg = fg_file,
    .dim_fg = fg_detail,
    .dir_fg = fg_dir,
    .empty_text = "Nothing matches",
    .max_cols = 100,
    .max_rows = 20,
};

/// Alt+Down's directory history: the palette's list widget, dropped
/// over the active pane, as wide as the finder may be since what it
/// lists is paths.
const history_style: palette_mod.Style = blk: {
    var s = palette_style;
    s.empty_text = "No other directories this session";
    s.max_cols = finder_style.max_cols;
    break :blk s;
};

/// The Ctrl+Shift+P command palette (`applib/palette.zig`): the finder's
/// colours, in the palette's own top-anchored shape.
const palette_style: palette_mod.Style = blk: {
    var s = palette_mod.default_style;
    s.selected_bg = finder_style.selected_bg;
    s.selected_fg = finder_style.selected_fg;
    s.text_fg = finder_style.text_fg;
    s.dim_fg = finder_style.dim_fg;
    break :blk s;
};

/// Rows every pane spends on chrome: title, column header, footer.
const chrome_rows = 3;
/// The column-header row, between the title and the listing. Clicking it
/// re-orders the pane -- see `sortKeyForColumn`.
const header_row = 1;
const list_top = 2;
const size_w = 8;
const date_w = 16;
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

/// F2: the entry under the cursor being renamed where it's listed.
const NameEdit = struct {
    pane: usize,
    /// The listing row the field sits on. Nothing that could re-order
    /// or re-read the listing leaves the field open, so it stays valid.
    row: usize,
    /// The entry's name when the field opened -- what it's renamed from.
    /// Owned.
    original: []u8,
    line: LineEdit,
    /// Super+F2: Enter renames as root (`sudo.zig`).
    as_root: bool = false,
};

/// Where one pane's columns fall, for its current width and view.
const Columns = struct {
    icon_col: usize,
    name_col: usize,
    name_w: usize,
    size_col: ?usize,
    date_col: ?usize,
};

/// Which column a click at pane-local column `col` on the header row
/// belongs to, or null for the gutter left of the Name column (the icon
/// column, which sorts nothing). The columns run left to right with no
/// gaps worth caring about, so each one claims everything up to the next.
fn sortKeyForColumn(cols: Columns, col: usize) ?pane_mod.SortKey {
    if (col < cols.name_col) return null;
    if (cols.date_col) |d| {
        if (col >= d) return .time;
    }
    if (cols.size_col) |sz| {
        if (col >= sz) return .size;
    }
    return .name;
}

/// A header label with the sort arrow on the column currently in force,
/// matching `core.Table`'s `▴`/`▾`. Returns a slice of `buf`.
fn headerLabel(buf: []u8, text: []const u8, sort: pane_mod.Sort, key: pane_mod.SortKey) []const u8 {
    if (sort.key != key) return text;
    const arrow = switch (sort.dir) {
        .ascending => "\u{25B4}", // ▴
        .descending => "\u{25BE}", // ▾
    };
    return std.fmt.bufPrint(buf, "{s} {s}", .{ text, arrow }) catch text;
}

/// A layer's rect as the split tree laid it out, in context cells.
const Bounds = struct { row: usize = 0, col: usize = 0, cols: usize = 0, rows: usize = 0 };

/// See `Ui.press`.
const Press = struct {
    pane: usize,
    row: usize,
    px: glyphwire.PxPos,
    /// A Ctrl+click marks its row, but only once the button is released
    /// without a drag: Ctrl+drag is a copy, and must not mark on the way.
    ctrl_mark: bool,
};

/// See `Ui.drag`.
const Drag = struct {
    src_pane: usize,
    /// Borrowed from the source pane, which nothing reloads while a drag
    /// is live: keys and typing are swallowed until it ends. The slice
    /// is owned.
    sources: [][]const u8,
    /// The icon of the row the drag started on, for the card.
    icon: []const u8,
    /// Ctrl is down: the drop copies instead of moving.
    copy: bool,
    /// The pointer's cell, from the latest `mouse_move`.
    cell: glyphwire.CellPos,
    /// Where a drop right now would land, kept current by `updateDrag`.
    target: ?drag_mod.Target = null,
};

/// A program `runInSessionAs` started that hasn't been reaped yet. It
/// runs in a context of its own while this one goes on handling events;
/// `reapLaunched` picks its exit up on a later turn of the loop.
const Launched = struct {
    pid: std.posix.pid_t,
    /// What the bar calls it. Owned.
    name: []u8,
    /// sudoedit's stderr, read for the bar once it exits. Owned: closed
    /// with the entry.
    complaint: ?sudo.Complaint,
    /// Where to put the cursor once it exits. `land.path` is owned.
    land: ?Landing,

    fn deinit(self: Launched, alloc: std.mem.Allocator, io: std.Io) void {
        alloc.free(self.name);
        if (self.complaint) |c| c.close(io);
        if (self.land) |l| alloc.free(l.path);
    }
};

/// Shift+F4's new file, which only exists once the editor has saved it:
/// when the editor exits, pane `pane` lands on `path` if it never left
/// the directory it was showing. One that went elsewhere -- even back
/// again -- has a cursor the user put there since, and keeps it.
const Landing = struct {
    pane: usize,
    path: []const u8,
    /// The pane's `visits` when the editor started.
    visits: u64,
};

/// How long the loop waits for an event while a launched program is
/// still running, so one that exits with nothing else happening is
/// still noticed (and the panes reread) without a keystroke.
const reap_poll_ms = 250;

/// How often a drag held over a pane's header or footer row scrolls it
/// a row.
const autoscroll_ms = 60;

/// `pid`'s exit status if it has exited (and is now reaped), null while
/// it's still running. Never waits. A pid waitpid no longer knows
/// (ECHILD) counts as gone, with nothing to say about how. See
/// `Ui.reapLaunched`.
pub fn pollExit(pid: std.posix.pid_t) ?std.process.Child.Term {
    var status: c_int = 0;
    const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (r == 0) return null;
    if (r < 0) return .{ .unknown = 0 };
    const st: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(st)) return .{ .exited = std.c.W.EXITSTATUS(st) };
    if (std.c.W.IFSIGNALED(st)) return .{ .signal = std.c.W.TERMSIG(st) };
    return .{ .unknown = st };
}

pub const Ui = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,
    /// `$HOME`, for `~` in titles and typed paths. Borrowed.
    home: ?[]const u8,
    /// The environment salacommander started with, for what Super+F4's
    /// sudoedit passes on to the editor (`sudo.editArgv`). Borrowed.
    environ: ?*const std.process.Environ.Map = null,

    context: glyphwire.ContextHandle,
    pane_layers: [2]glyphwire.LayerHandle,
    bar_layer: glyphwire.LayerHandle,
    dialog_layer: glyphwire.LayerHandle,
    /// Ctrl+`: a `gw-shell` drawing into a layer docked along an edge or
    /// floating in the middle. It takes every keystroke but Ctrl+` while it's open, and follows the
    /// active pane's directory. See `applib/shellpanel.zig`.
    shell: shellpanel.Panel,

    win: struct { cols: usize, rows: usize },
    cell: struct { w: u32, h: u32 },
    /// Where the split tree put each pane layer, in context cells. The
    /// server lays them out (the band between them is the host's, and
    /// draggable), so these only ever come from a `layout` notification
    /// or `readBounds` -- never from arithmetic on `win`.
    pane_bounds: [2]Bounds = .{ .{}, .{} },

    cfg: config_mod.Config,
    keymap: actions.Keymap,
    /// F1's menu: `actions.menu_defaults` under `menu_keys`.
    menu_keymap: actions.Keymap,
    /// The modifiers down right now, as the last key or mouse event
    /// carried them. Changing it redraws the key bar (and an open F1
    /// menu): both show what a key would do under them.
    held: glyphwire.Mods = .{},
    /// A chmod/chown that isn't already root offers "Retry as root" on
    /// a permission error (`hookError`); `chosen` once it's been taken,
    /// which stops the run so `runAttrs` can start it over through sudo.
    root_retry: enum { off, offered, chosen } = .off,
    panes: [2]Pane,
    active: usize = 0,

    /// The dialog on screen, while `runDialog` has one up.
    dialog: ?*Dialog = null,
    /// Alt+D: a pane's title row turned into a text field. While one is
    /// open its pane draws the field instead of its directory, and keys
    /// go there rather than through the keymap.
    path_edit: ?PathEdit = null,
    /// F2: an entry's name turned into a text field, in the name column
    /// of its row. Keys go there, as for `path_edit`; the two are never
    /// open at once.
    name_edit: ?NameEdit = null,
    /// F3: the search popup. Modal while open -- keys, typing and clicks
    /// all go to it -- and walked afresh on every open, as zoe's Ctrl+P is
    /// (see applib/finder.zig).
    finder: finderpopup.Popup,
    /// Ctrl+Shift+P: the command palette. Modal while open, like F3's.
    palette: palette_mod.Popup,
    /// Alt+Down: the active pane's directory history, in the palette's
    /// list widget (each row a path rather than a command). Modal too.
    history_popup: palette_mod.Popup,
    /// The theme this context resolves against, for the popups' frames
    /// (`finder.chrome.style.frame_style` borrows its name).
    th: glyphwire.theme.Stored,
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
    pane_dirty: [2]PaneDirty = .{ .full, .full },
    /// The context title last sent (`syncTitle`): `salacommander` and the
    /// active pane's directory, which glyphwire-host shows in the window
    /// title.
    title_buf: [glyphwire.Context.max_title_len]u8 = undefined,
    title_len: usize = 0,
    /// The cursor row and scroll position each pane's layer was last
    /// drawn with. A `.rows` repaint diffs against these to know which
    /// two rows to redraw, and falls back to a full one when `top` has
    /// moved -- every row shifted then, so there is no small diff.
    drawn_cursor: [2]usize = .{ 0, 0 },
    drawn_top: [2]usize = .{ 0, 0 },
    bar_dirty: bool = true,
    /// The last `content_extent`/offset sent per pane, so an unchanged one
    /// isn't re-sent (and a host-driven scroll isn't echoed back).
    pushed_scroll: [2][2]usize = .{ .{ std.math.maxInt(usize), 0 }, .{ std.math.maxInt(usize), 0 } },
    /// The row the last plain left click landed on, or null after a click
    /// that must not start a double (a Ctrl+click or right-click mark).
    /// The host counts the clicks (`MouseButtonEvent.clicks`); this only
    /// makes sure both halves of a double were plain clicks on one row.
    last_click: ?struct { pane: usize, row: usize } = null,
    /// A left press on a listing row with the button still down. It
    /// turns into `drag` once the pointer travels `drag_mod.threshold_px`,
    /// or is just a click when the button comes back up first.
    press: ?Press = null,
    /// Files being dragged between the panes. See `drag.zig`.
    drag: ?Drag = null,
    /// The card under the pointer while `drag` is live: what's being
    /// carried, `+` in front when the drop would copy.
    drag_layer: glyphwire.LayerHandle,
    /// `GLYPHWIRE_SALA_PROFILE=1`: print what each pane repaint cost on
    /// the wire -- rows drawn and body bytes -- to stderr. Off by
    /// default and read once at startup. It exists because "the remote
    /// pane feels laggy" is unanswerable without knowing whether a
    /// keystroke costs one 20 KB frame or a hundred small round trips,
    /// and over `--ssh` neither is visible from the outside.
    profile: bool = false,
    /// Programs started from here (an `open_actions` reader, the F4
    /// editor) that are still running. Quitting leaves them be.
    launched: std.ArrayList(Launched) = .empty,
    quit: bool = false,

    pub const InitOptions = struct {
        left: []const u8,
        right: []const u8,
        home: ?[]const u8,
        /// See `Ui.environ`.
        environ: ?*const std.process.Environ.Map = null,
        /// See `Ui.profile`.
        profile: bool = false,
        /// Taken over by the `Ui`.
        cfg: config_mod.Config,
        /// `salacommander.conf.lua`'s own `theme`, or null to follow the
        /// window's (`themeconf.programTheme`).
        theme: ?glyphwire.theme.Theme = null,
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
        try keymap.apply(alloc, cfg.keys);
        var menu_keymap = try actions.Keymap.initDefaults(alloc, &actions.menu_defaults);
        errdefer menu_keymap.deinit(alloc);
        try menu_keymap.apply(alloc, cfg.menu_keys);

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
        try client.setContextTitle("salacommander");
        // Nothing here takes text at a host caret; the dialog's field
        // draws its own.
        try client.setCaretVisible(false);
        // Kept for the one thing the host can't recolour: the F3 popup's
        // nine-patch frame, picked by name.
        const th: glyphwire.theme.Stored = if (opts.theme) |t| blk: {
            try client.setTheme(&t);
            break :blk .init(t);
        } else try client.getTheme();
        self.th = th;
        var popup_style = finder_style;
        popup_style.frame_style = self.th.panelStyle();

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        const left_layer = try client.createLayer(size.cols, size.rows, 0);
        const right_layer = try client.createLayer(size.cols, size.rows, 0);
        const bar_layer = try client.createLayer(size.cols, 1, 0);
        // The Ctrl+` shell panel. `gw-shell --embed` draws its prompt and
        // its commands' output here, so it carries scrollback of its own
        // for the shell's Ctrl+Up browsing -- see `applib/shellpanel.zig`.
        const shell_layers = try shellpanel.createLayers(client, size.cols);
        const shell_layer = shell_layers.shell;
        // F3's popup, over the panes and the panel (it can't be opened
        // while the panel has the keyboard, but the panel stays drawn
        // underneath). Placed per frame by `Popup.render`.
        var finder = try finderpopup.Popup.init(alloc, client, popup_style);
        errdefer finder.deinit();
        var palette_init_style = palette_style;
        palette_init_style.frame_style = self.th.panelStyle();
        var palette = try palette_mod.Popup.init(alloc, client, palette_init_style);
        errdefer palette.deinit();
        var history_init_style = history_style;
        history_init_style.frame_style = self.th.panelStyle();
        var history_popup = try palette_mod.Popup.init(alloc, client, history_init_style);
        errdefer history_popup.deinit();
        // The drag card rides over the panes; sized and filled per drag.
        const drag_layer = try client.createLayer(10, 1, 0);
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
        // Opaque, and darker than the panes: the shell's own writes leave
        // the cells they don't touch transparent, and a prompt with a
        // file listing showing through it is unreadable.
        try client.setLayerBackground(shell_layer, bg_shell);
        // A bar down its right edge for the shell's scrollback, so a
        // command that printed more than the panel holds can be scrolled
        // back to with the wheel or the thumb.
        try client.setLayerScrollbars(shell_layer, true, false);
        // The one layer here the host may run its own drag-to-select on.
        // A click in a file pane is ours (it moves that pane's cursor),
        // but the panel holds terminal output -- a command's result the
        // user wants to copy -- and `gw-shell --embed` has no use for the
        // press. See `core.Layer.mouse_select`.
        try client.setLayerMouseSelect(shell_layer, true);
        try client.setLayerBackground(dialog_layer, bg_dialog);
        // Host-drawn, so it follows the dialog as it's resized for each
        // question and hides with it.
        try client.setLayerShadow(dialog_layer, glyphwire.Shadow.dialog);
        try client.setLayerVisible(dialog_layer, false);
        try client.setLayerBackground(drag_layer, bg_dialog);
        try client.setLayerShadow(drag_layer, glyphwire.Shadow.dialog);
        try client.setLayerVisible(drag_layer, false);

        self.* = .{
            .th = th,
            .alloc = alloc,
            .io = io,
            .client = client,
            .listener = listener,
            .home = opts.home,
            .environ = opts.environ,
            .profile = opts.profile,
            .context = context,
            .pane_layers = .{ left_layer, right_layer },
            .bar_layer = bar_layer,
            .dialog_layer = dialog_layer,
            .drag_layer = drag_layer,
            .finder = finder,
            .palette = palette,
            .history_popup = history_popup,
            .shell = shellpanel.Panel.init(alloc, io, client, context, shell_layers),
            .win = .{ .cols = size.cols, .rows = size.rows },
            .cell = .{ .w = metrics.w, .h = metrics.h },
            .cfg = cfg,
            .keymap = keymap,
            .menu_keymap = menu_keymap,
            .panes = .{ left, right },
        };

        // The panes side by side over the one-row key bar. The pane split
        // is user-resizable, so the host draws the band between them --
        // in `salacommander.conf.lua`'s `divider_style`, or the host's
        // own -- and lets it be dragged. The column split is not: a drag
        // handle above a fixed one-row bar is a wasted row.
        const pane_split = try client.createSplit(.row, true);
        const root_split = try client.createSplit(.column, false);
        try client.setSplitChildren(pane_split, &.{
            glyphwire.SplitChildInput.layerWeighted(left_layer, 1),
            glyphwire.SplitChildInput.layerWeighted(right_layer, 1),
        });
        try client.setSplitChildren(root_split, &.{
            glyphwire.SplitChildInput.splitWeighted(pane_split, 1),
            glyphwire.SplitChildInput.layerFixed(bar_layer, 1),
        });
        try client.setRootSplit(root_split);
        if (!self.cfg.divider_style.inherits()) try client.setDividerStyle(&self.cfg.divider_style);
        self.shell.setPosition(self.cfg.shell_position, self.cfg.shell_float_percent, .{ .cols = self.win.cols, .rows = self.win.rows });
        self.shell.setFrameStyle(self.th.panelStyle());

        // The listener will get a `layout` for this too, but reading the
        // bounds back now keeps the first frame off guessed geometry.
        try self.readBounds();
        return self;
    }

    pub fn deinit(self: *Ui) void {
        const alloc = self.alloc;
        // Before the context goes: the shell draws on a layer inside it,
        // and closing its control pipe is what tells it to leave.
        self.shell.deinit();
        self.endPathEdit();
        self.endNameEdit();
        if (self.drag) |d| alloc.free(d.sources);
        self.finder.deinit();
        self.palette.deinit();
        self.history_popup.deinit();
        for (&self.panes) |*p| p.deinit();
        self.keymap.deinit(alloc);
        self.menu_keymap.deinit(alloc);
        self.cfg.deinit(alloc);
        if (self.message) |m| alloc.free(m);
        // Anything still running keeps its own context and outlives us;
        // only the bookkeeping goes.
        for (self.launched.items) |l| l.deinit(alloc, self.io);
        self.launched.deinit(alloc);
        self.client.destroyContext(self.context) catch {};
        alloc.destroy(self);
    }

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            try self.reapLaunched();
            try self.flush();
            // A drag parked on a header or footer row scrolls that pane
            // for as long as it stays there, so the loop wakes on a timer
            // then rather than waiting for the pointer to move. A
            // launched program still running wakes it too, more slowly,
            // to notice the exit.
            const timeout: std.Io.Timeout = if (self.autoScrollStep() != null)
                .{ .duration = .{ .raw = .fromMilliseconds(autoscroll_ms), .clock = .awake } }
            else if (self.launched.items.len > 0)
                .{ .duration = .{ .raw = .fromMilliseconds(reap_poll_ms), .clock = .awake } }
            else
                .none;
            const first = try self.listener.next(timeout) orelse {
                try self.autoScroll();
                continue;
            };
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
            .layout => |l| try self.handleLayout(l),
            // The shell panel's inner edge was dragged. It floats over the
            // panes rather than squeezing them, so nothing else moves.
            .layer_resize => |lr| _ = self.shell.handleLayerResize(lr, .{ .cols = self.win.cols, .rows = self.win.rows }),
            .scroll_offset => |so| {
                // A wheel or thumb drag over a popup's list.
                if (self.finder.scrolled(so) or self.palette.scrolled(so) or self.history_popup.scrolled(so)) return;
                for (self.pane_layers, 0..) |l, i| {
                    if (so.layer != l) continue;
                    self.clearFind();
                    self.endNameEdit();
                    const p = &self.panes[i];
                    p.scrollTo(so.row / p.view.rowHeight(), self.visibleRows(i));
                    self.pushed_scroll[i][1] = so.row;
                    self.markDirty(i, .full);
                    // The wheel mid-drag: a different row is under the
                    // pointer now.
                    if (self.drag != null) try self.updateDrag();
                }
            },
            .mouse_button => |m| {
                _ = self.noteMods(m.mods);
                try self.handleMouseButton(m);
            },
            .mouse_move => |mv| {
                _ = self.noteMods(mv.mods);
                try self.dragMove(mv);
            },
            .focus => |f| if (!f.focused) {
                _ = self.noteMods(.{});
            },
            .copy_request => try self.copySelectionPaths(),
            // A drag takes the keyboard: Esc cancels and Ctrl flips copy
            // and move, and nothing else may reload the listing the drag
            // is carrying paths out of. A modifier on its own does
            // nothing but change the bar (`noteKey`).
            .key => |k| {
                _ = self.noteKey(k);
                if (self.drag != null) {
                    try self.dragKey(k);
                } else if (!isModifierKey(k.key) and k.pressed) {
                    try self.handleKey(k);
                }
            },
            // Typed text is the shell's while its panel is up -- it has
            // a line editor, and this one has type-to-find.
            .text, .paste => |t| if (self.drag != null or self.shell.isOpen()) {} else if (self.palette.isOpen()) {
                try self.palette.text(t.text);
            } else if (self.history_popup.isOpen()) {
                try self.history_popup.text(t.text);
            } else if (self.finder.isOpen()) {
                try self.finder.text(t.text);
            } else if (self.path_edit) |*e| {
                _ = try e.line.insert(self.alloc, t.text);
                self.markDirty(e.pane, .full);
            } else if (self.name_edit) |*e| {
                _ = try e.line.insert(self.alloc, t.text);
                self.markDirty(e.pane, .full);
            } else {
                // Nothing else takes typing, so it's type-to-find.
                try self.typeToFind(t.text);
            },
            .shutdown => self.quit = true,
            .theme => try self.themeChanged(),
            else => {},
        }
    }

    /// The window theme changed under a salacommander that follows it
    /// (the event only comes then). Every colour drawn is a role, so the
    /// panes recolour on the host by themselves; the F3 popup's frame is
    /// a nine-patch picked by name and has to be swapped.
    fn themeChanged(self: *Ui) !void {
        self.th = try self.client.getTheme();
        var style = finder_style;
        style.frame_style = self.th.panelStyle();
        try self.finder.setStyle(style);
        var pstyle = palette_style;
        pstyle.frame_style = self.th.panelStyle();
        try self.palette.setStyle(pstyle);
        var hstyle = history_style;
        hstyle.frame_style = self.th.panelStyle();
        try self.history_popup.setStyle(hstyle);
        self.shell.setFrameStyle(self.th.panelStyle());
    }

    fn handleResize(self: *Ui, r: glyphwire.ResizeEvent) !void {
        self.win = .{ .cols = r.cols, .rows = r.rows };
        // A font-size step changes the cell metrics too, and arrives as
        // one resize.
        if (self.client.getCellMetrics()) |m| {
            self.cell = .{ .w = m.w, .h = m.h };
        } else |_| {}
        // No pane geometry from this: the `layout` that comes with it
        // carries the new pane rects. Only the floating panel, which is
        // outside the split tree, is placed against the window here.
        self.shell.place(.{ .cols = self.win.cols, .rows = self.win.rows }) catch {};
        self.markAllDirty();
    }

    /// The split tree was re-laid-out: a window resize, or the band
    /// between the panes dragged.
    fn handleLayout(self: *Ui, l: glyphwire.LayoutEvent) !void {
        var moved = false;
        for (self.pane_layers, 0..) |layer, i| {
            const b = l.boundsFor(layer) orelse continue;
            self.pane_bounds[i] = .{ .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows };
            moved = true;
        }
        if (!moved) return;
        try self.sizeLayers();
        self.markAllDirty();
    }

    fn markAllDirty(self: *Ui) void {
        self.pane_dirty = .{ .full, .full };
        self.bar_dirty = true;
        if (self.finder.isOpen()) self.finder.dirty = true;
        if (self.palette.isOpen()) self.palette.dirty = true;
        if (self.history_popup.isOpen()) self.history_popup.dirty = true;
    }

    /// Follows the held modifiers from a key event. A modifier key's own
    /// event is trusted for its bit over the event's `mods`, which the
    /// server captures as it routes the event and so may or may not
    /// count the key itself yet. True when `held` changed.
    fn noteKey(self: *Ui, k: glyphwire.KeyEvent) bool {
        var m = k.mods;
        const eq = std.mem.eql;
        if (eq(u8, k.key, "left_shift") or eq(u8, k.key, "right_shift")) m.shift = k.pressed;
        if (eq(u8, k.key, "left_control") or eq(u8, k.key, "right_control")) m.ctrl = k.pressed;
        if (eq(u8, k.key, "left_alt") or eq(u8, k.key, "right_alt")) m.alt = k.pressed;
        if (eq(u8, k.key, "left_super") or eq(u8, k.key, "right_super")) m.super = k.pressed;
        return self.noteMods(m);
    }

    /// Sets `held`, redrawing the bar if that changes what it shows.
    fn noteMods(self: *Ui, m: glyphwire.Mods) bool {
        if (std.meta.eql(m, self.held)) return false;
        self.held = m;
        self.bar_dirty = true;
        return true;
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
        if (self.palette.isOpen()) return self.paletteKey(k);
        if (self.history_popup.isOpen()) return self.historyKey(k);
        if (self.finder.isOpen()) return self.finderKey(k);
        if (self.path_edit != null) return self.pathEditKey(k);
        if (self.name_edit != null) return self.nameEditKey(k);

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

    /// Raises a pane's pending repaint to at least `level`. Never lowers
    /// it: a `.full` already owed stays owed however many cursor moves
    /// land on top of it before the next `flush`.
    fn markDirty(self: *Ui, i: usize, level: PaneDirty) void {
        if (@intFromEnum(level) > @intFromEnum(self.pane_dirty[i])) self.pane_dirty[i] = level;
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
        // Type-to-find only ever moves the cursor, so it is the cheapest
        // repaint too -- and it is one per keystroke, which is exactly
        // where a full one hurts.
        self.markDirty(self.active, .bg);
        try self.setMessage("find: {s}", .{self.find_buf[0..self.find_len]});
    }

    /// Backspace over the prefix, moving the cursor back to what the
    /// shorter one finds. Emptying it is the same as dropping it.
    fn findBackspace(self: *Ui) void {
        self.find_len -= 1;
        if (self.find_len == 0) return self.clearFind();
        const p = &self.panes[self.active];
        if (p.rowStartingWith(self.find_buf[0..self.find_len])) |row| p.setCursor(row);
        self.markDirty(self.active, .bg);
        self.setMessage("find: {s}", .{self.find_buf[0..self.find_len]}) catch {};
    }

    /// Drops the prefix. Called by everything that moves the cursor or
    /// changes what's listed -- any action, a click, a wheel tick -- so
    /// the next letter typed starts a new search.
    fn clearFind(self: *Ui) void {
        if (self.find_len == 0) return;
        self.find_len = 0;
        self.clearMessage();
        // The prefix itself lives in the bar, not the pane; the pane is
        // marked only because the cursor may have been left somewhere
        // the caller is about to move it from.
        self.markDirty(self.active, .bg);
    }

    /// Carries out one action on the active pane. Every command, whatever
    /// key or click triggered it, comes through here.
    pub fn perform(self: *Ui, action: Action) !void {
        const i = self.active;
        const p = &self.panes[i];
        switch (action) {
            .cursorUp => p.moveCursor(-1),
            .cursorDown => p.moveCursor(1),
            // `page_lines` rows, not a screenful: a page is the same
            // jump whatever the window is or whether the shell panel is
            // open. `Pane.moveCursor` clamps at the ends.
            .pageUp => p.moveCursor(-@as(i64, @intCast(self.cfg.page_lines))),
            .pageDown => p.moveCursor(@intCast(self.cfg.page_lines)),
            .cursorHome => p.cursorHome(),
            .cursorEnd => p.cursorEnd(),
            .activate => try self.activate(i),
            .upToParentDir => {
                _ = p.upToParentDir() catch |err| try self.setMessage("can't go up: {t}", .{err});
            },
            .historyBack => {
                const moved = p.back() catch |err| blk: {
                    try self.setMessage("can't go back: {t}", .{err});
                    break :blk true;
                };
                if (!moved) try self.setMessage("nothing further back", .{});
            },
            .historyForward => {
                const moved = p.forward() catch |err| blk: {
                    try self.setMessage("can't go forward: {t}", .{err});
                    break :blk true;
                };
                if (!moved) try self.setMessage("nothing further forward", .{});
            },
            .showHistory => try self.openHistory(),
            .editPath => try self.beginPathEdit(),
            .switchPane => {
                self.active = 1 - i;
                self.pane_dirty = .{ .full, .full };
            },
            .otherPaneToSameDir => try self.otherPaneToSameDir(),
            // `panes[0]` is always the left side (Ctrl+U swaps contents,
            // not positions), so the arrow only reaches across from 0 or 1.
            .rightPaneToSameDir => if (i == 0) try self.otherPaneToSameDir(),
            .leftPaneToSameDir => if (i == 1) try self.otherPaneToSameDir(),
            .swapPanes => {
                std.mem.swap(Pane, &self.panes[0], &self.panes[1]);
                self.pane_dirty = .{ .full, .full };
            },

            .toggleMark => p.toggleMark(p.list.selected),
            .toggleMarkAndDown => {
                p.toggleMark(p.list.selected);
                p.moveCursor(1);
            },
            .markAll => p.markAll(),
            .unmarkAll => p.unmarkAll(),
            .invertMarks => p.invertMarks(),

            .rename => try self.beginNameEdit(false),
            .find => try self.openFinder(),
            .commandPalette => try self.openPalette(),
            .edit => try self.editCurrent(false),
            .copy => try self.transfer(.copy, false),
            .move => try self.transfer(.move, false),
            .makeDir => try self.makeDir(false),
            .trash => try self.trashSelection(),
            .delete => try self.deleteSelection(false),
            .newFile => try self.newFile(false),
            .fileOpsMenu => try self.fileOpsMenu(),
            .chmod => try self.changeMode(false),
            .chown => try self.changeOwner(false),

            .sudoRename => try self.beginNameEdit(true),
            .sudoEdit => try self.editCurrent(true),
            .sudoNewFile => try self.newFile(true),
            .sudoCopy => try self.transfer(.copy, true),
            .sudoMove => try self.transfer(.move, true),
            .sudoMakeDir => try self.makeDir(true),
            .sudoDelete => try self.deleteSelection(true),
            .sudoChmod => try self.changeMode(true),
            .sudoChown => try self.changeOwner(true),

            .toggleShell => try self.toggleShell(),

            .sortByName => p.setSort(p.sort.cycled(.name)),
            .sortByExt => p.setSort(p.sort.cycled(.ext)),
            .sortBySize => p.setSort(p.sort.cycled(.size)),
            .sortByTime => p.setSort(p.sort.cycled(.time)),

            .viewSmall => p.view = .small,
            .viewLarge => p.view = .large,
            .toggleView => p.view = if (p.view == .small) .large else .small,
            .toggleHidden => p.setShowHidden(!p.show_hidden) catch |err| try self.setMessage("reread failed: {t}", .{err}),
            .refresh => try self.reloadBoth(),
            .quit => self.quit = true,
        }
        self.markDirty(i, dirtyFor(action));
        self.bar_dirty = true;
        // Whatever just happened may have moved the active side or its
        // directory; the panel follows both, and says nothing when
        // neither changed.
        self.shell.setCwd(self.panes[self.active].path);
    }

    /// How much of the pane an action can have changed. The cheap answers
    /// are for the ones that touch nothing but the row the cursor left
    /// and the row it landed on.
    ///
    /// A navigation key only moves the highlight, so it earns `.bg` --
    /// two rows' colours and the footer. The two mark toggles also change
    /// the rows' text (a `*` in column 0), so
    /// they earn `.rows`. Either way a move that *scrolls* is still
    /// correct: `renderPaneRows` notices `top` moved and shifts the band,
    /// or gives up and repaints the pane.
    pub fn dirtyFor(action: Action) PaneDirty {
        return switch (action) {
            .cursorUp,
            .cursorDown,
            .pageUp,
            .pageDown,
            .cursorHome,
            .cursorEnd,
            => .bg,
            .toggleMark,
            .toggleMarkAndDown,
            => .rows,
            // Opening a popup leaves the pane behind it alone; picking
            // a result marks the pane itself (`acceptFinder`), and a
            // palette pick goes back through here.
            .find, .commandPalette, .showHistory => .none,
            else => .full,
        };
    }

    /// Alt+O, and Ctrl+Left/Right toward the other side: the other pane
    /// lists the active pane's directory.
    fn otherPaneToSameDir(self: *Ui) !void {
        const i = self.active;
        const path = self.panes[i].path;
        self.panes[1 - i].load(path) catch |err| try self.setMessage("{s}: {t}", .{ path, err });
        self.markDirty(1 - i, .full);
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
                // Checked first: an opener handed a file it can't read
                // takes the screen, or detaches, before failing where
                // the bar can't say why.
                std.Io.Dir.cwd().access(self.io, owned, .{ .read = true }) catch |err| {
                    return self.refuseUnreadable(owned, err);
                };
                try self.openFile(owned);
            },
        }
    }

    /// Says in the bar why `path` can't be opened, pointing at Super+F4
    /// (whatever `sudoEdit` is bound to) when the reason is permission.
    fn refuseUnreadable(self: *Ui, path: []const u8, err: anyerror) !void {
        const name = std.fs.path.basename(path);
        const denied = err == error.AccessDenied or err == error.PermissionDenied;
        if (denied) {
            if (self.keymap.chordFor(.sudoEdit)) |chord| {
                var kbuf: [48]u8 = undefined;
                return self.setMessage("{s}: {s} ({s} edits it as root)", .{ name, errorText(err), chord.format(&kbuf) });
            }
        }
        try self.setMessage("{s}: {s}", .{ name, errorText(err) });
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
        try self.runInSession(argv, self.startDir(path));
    }

    /// Starts a glyphwire client without waiting for it. The child
    /// inherits `GLYPHWIRE_SOCK`, so it opens its own context, which the
    /// host stacks over ours and hands the keyboard to; switching back
    /// here finds the file manager still answering, and `reapLaunched`
    /// rereads the panes once the child exits. Its stdio is dropped --
    /// this pane's stdout is the shell's screen, sitting under our
    /// context, and writing there would show up as damage once we're
    /// gone. It starts in `cwd` (see `startDir`), not wherever
    /// salacommander was started.
    fn runInSession(self: *Ui, argv: []const []const u8, cwd: []const u8) !void {
        return self.runInSessionAs(argv, argv[0], null, cwd, null);
    }

    /// Where a program opened on `path` starts: the file's own directory,
    /// so zoe's sidebar, its Ctrl+P and a `:e` there are about the file.
    /// For a new file under a directory that isn't there yet, the active
    /// pane's. Borrows from `path` or the pane.
    fn startDir(self: *const Ui, path: []const u8) []const u8 {
        if (std.fs.path.dirname(path)) |dir| {
            if (std.Io.Dir.cwd().statFile(self.io, dir, .{})) |st| {
                if (st.kind == .directory) return dir;
            } else |_| {}
        }
        return self.panes[self.active].path;
    }

    /// `runInSession`, named `name` in the bar, with stderr kept in
    /// `complaint` (when given) so a failure can say why, and `land`
    /// (when given) to put the cursor on once it exits. Takes
    /// `complaint` over, closing it when the child is reaped or failed
    /// to start; `land` is copied.
    fn runInSessionAs(self: *Ui, argv: []const []const u8, name: []const u8, complaint: ?sudo.Complaint, cwd: []const u8, land: ?Landing) !void {
        // Everything the entry needs is in hand before the child starts:
        // one that's running with nothing tracking it would never be
        // reaped.
        var entry = self.newLaunched(name, complaint, land) catch |err| {
            if (complaint) |c| c.close(self.io);
            return err;
        };
        const child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = if (complaint) |c| c.stdio() else .ignore,
            // A group of its own, like the shell panel's: a Ctrl+C the
            // shell that started us sends our group, or the host's
            // SIGHUP when our pane closes, is not for a program that has
            // a context of its own and outlives us.
            .pgid = 0,
        }) catch |err| {
            entry.deinit(self.alloc, self.io);
            return self.setMessage("{s}: {t}", .{ name, err });
        };
        entry.pid = child.id.?;
        self.launched.appendAssumeCapacity(entry);
    }

    /// A `launched` entry for a child not yet started (its `pid` is
    /// filled in once it is), with room reserved for it in the list.
    /// Owns copies of `name` and `land`, and takes `complaint` over only
    /// on success.
    fn newLaunched(self: *Ui, name: []const u8, complaint: ?sudo.Complaint, land: ?Landing) !Launched {
        try self.launched.ensureUnusedCapacity(self.alloc, 1);
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const owned_land: ?Landing = if (land) |l| .{ .pane = l.pane, .path = try self.alloc.dupe(u8, l.path), .visits = l.visits } else null;
        return .{ .pid = 0, .name = owned_name, .complaint = complaint, .land = owned_land };
    }

    /// Collects every launched program that has exited, without waiting
    /// on one that hasn't: rereads both panes (it may well have changed
    /// what's in them), lands Shift+F4's cursor, and says in the bar why
    /// one failed. Held off while something borrows from a listing -- a
    /// rename field, a press or a drag -- which a reread would pull out
    /// from under it; the exit keeps until they're done.
    fn reapLaunched(self: *Ui) !void {
        if (self.launched.items.len == 0) return;
        if (self.name_edit != null or self.press != null or self.drag != null) return;
        var reloaded = false;
        var i: usize = 0;
        while (i < self.launched.items.len) {
            const term = pollExit(self.launched.items[i].pid) orelse {
                i += 1;
                continue;
            };
            const done = self.launched.orderedRemove(i);
            defer done.deinit(self.alloc, self.io);
            if (!reloaded) {
                try self.reloadBoth();
                reloaded = true;
            }
            if (done.land) |l| self.landOn(l);
            try self.reportExit(done, term);
        }
    }

    /// A launched program's exit, in the bar when it went wrong: what it
    /// last said on stderr if that was kept (sudoedit), else its status.
    fn reportExit(self: *Ui, done: Launched, term: std.process.Child.Term) !void {
        if (term.success()) return;
        var why_buf: [512]u8 = undefined;
        const why = if (done.complaint) |c| c.last(self.io, &why_buf) else "";
        if (why.len > 0) return self.setMessage("{s}: {s}", .{ done.name, why });
        switch (term) {
            .exited => |code| try self.setMessage("{s} exited with {d}", .{ done.name, code }),
            .unknown => {},
            else => try self.setMessage("{s} was killed", .{done.name}),
        }
    }

    /// `land`'s pane onto its file, if the pane hasn't moved since the
    /// editor started, is showing the file's directory, and the file is
    /// there now.
    fn landOn(self: *Ui, land: Landing) void {
        const p = &self.panes[land.pane];
        if (p.visits != land.visits) return;
        if (!std.mem.eql(u8, std.fs.path.dirname(land.path) orelse "", p.path)) return;
        if (p.rowOf(std.fs.path.basename(land.path))) |row| {
            p.setCursor(row);
            self.markDirty(land.pane, .full);
        }
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

    // ── F4: edit ────────────────────────────────────────────────────────

    /// F4: the file under the cursor in the configured `editor`. Only the
    /// cursor's entry, never the marks -- an editor takes one file. A
    /// directory, the `..` row and a file that isn't text are refused in
    /// the bar before anything starts: zoe would refuse a binary file
    /// too, but only after taking the screen to say so. `as_root`
    /// (Super+F4) is sudoedit -- see `editAsRoot`.
    fn editCurrent(self: *Ui, as_root: bool) !void {
        const p = &self.panes[self.active];
        const e = p.current() orelse return;
        if ((e.link_target_kind orelse e.kind) == .directory) {
            return self.setMessage("{s} is a directory", .{e.name});
        }
        // Copied: `e` borrows from the listing, and Super+F4 puts sudo's
        // password dialog up before the editor starts.
        const path = try self.alloc.dupe(u8, e.abs_path);
        defer self.alloc.free(path);
        const name = std.fs.path.basename(path);

        const binary = filetype.fileLooksBinary(self.io, path) catch |err| switch (err) {
            // A file only root can read is what Super+F4 is for: sudo
            // reads it, and the editor judges what it gets.
            error.AccessDenied, error.PermissionDenied => if (as_root) false else {
                return self.refuseUnreadable(path, err);
            },
            else => return self.refuseUnreadable(path, err),
        };
        if (binary) return self.setMessage("{s} is not a text file", .{name});
        try self.openInEditor(path, as_root, null);
    }

    /// Shift+F4: asks for a name and opens it in the `editor` without
    /// creating it -- the editor makes the file when it saves, so backing
    /// out leaves nothing behind. A name that is already a file opens
    /// that file; a directory is refused. Relative to the active pane,
    /// like F7's names. `as_root` is Super+Shift+F4, a sudoedit, which
    /// creates a missing file the same way.
    fn newFile(self: *Ui, as_root: bool) !void {
        const p = &self.panes[self.active];
        var title_buf: [64]u8 = undefined;
        var d = try Dialog.init(self.alloc, titleFor(&title_buf, "New file", as_root), "Name of the file to edit:", &dialog_mod.ok_cancel, .{ .input = "" });
        defer d.deinit(self.alloc);
        if (try self.runDialog(&d) != .ok) return;
        const typed = std.mem.trim(u8, d.inputText(), " ");
        if (typed.len == 0) return;

        const path = try self.resolveTyped(p.path, typed);
        defer self.alloc.free(path);
        if (std.Io.Dir.cwd().statFile(self.io, path, .{})) |st| {
            if (st.kind == .directory) return self.setMessage("{s} is a directory", .{typed});
        } else |_| {}
        // Saved into this pane's directory: land on it once the editor
        // exits (`reapLaunched`), which is when the file is there.
        try self.openInEditor(path, as_root, .{ .pane = self.active, .path = path, .visits = p.visits });
    }

    /// `path` in the configured `editor`, or through sudoedit, landing
    /// on `land` when it exits (see `runInSessionAs`).
    fn openInEditor(self: *Ui, path: []const u8, as_root: bool, land: ?Landing) !void {
        const template = self.cfg.editorCommand();
        if (as_root) return self.editAsRoot(template, path, land);
        var argv_buf: [openaction.max_args][]const u8 = undefined;
        const argv = openaction.buildArgv(&argv_buf, template, path) catch |err| {
            return self.setMessage("editor \"{s}\": {t}", .{ template, err });
        };
        try self.runInSessionAs(argv, argv[0], null, self.startDir(path), land);
    }

    /// sudoedit: sudo copies `path` somewhere you can write, runs the
    /// editor on the copy *as you*, and puts it back as root if it
    /// changed. Safer than an editor running as root, and a missing file
    /// is created on save. sudo's refusals ("editing files in a writable
    /// directory is not permitted") land in the bar.
    fn editAsRoot(self: *Ui, template: []const u8, path: []const u8, land: ?Landing) !void {
        if (!try self.sudoAuthorize()) return;
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const argv = sudo.editArgv(arena.allocator(), self.environ, template, path) catch |err| {
            return self.setMessage("editor \"{s}\": {t}", .{ template, err });
        };
        // `runInSessionAs` keeps it until sudoedit exits, and closes it.
        try self.runInSessionAs(argv, "sudoedit", sudo.Complaint.open(), self.startDir(path), land);
    }

    // ── F3: find ────────────────────────────────────────────────────────

    /// F3: walks everything under the active pane's directory and opens
    /// the popup over the panes. Hidden entries follow the pane's own
    /// Ctrl+H, and with it off `.gitignore`d paths stay out too -- the
    /// rule zoe's Ctrl+P has, and what keeps a built tree searchable.
    fn openFinder(self: *Ui) !void {
        self.endPathEdit();
        self.endNameEdit();
        self.clearFind();
        const p = &self.panes[self.active];
        const f = Finder.init(self.alloc, self.io, p.path, .{
            .visible = .{ .show_hidden = p.show_hidden },
            .include_dirs = true,
        }) catch |err| {
            return self.setMessage("can't search {s}: {t}", .{ p.path, err });
        };
        var pbuf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
        var tbuf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "Find in {s}", .{self.displayPath(&pbuf, p.path, 0)}) catch "Find";
        try self.finder.open(f, title);
    }

    /// Enter on a result: point the active pane at it and close the
    /// popup. A file lands the cursor on it in its own directory; a
    /// directory is entered. Nothing is opened -- Enter or F4 from there
    /// is one more key, and a search that opened things would need a
    /// second way to just go somewhere.
    fn acceptFinder(self: *Ui) !void {
        const rel = self.finder.selected() orelse return self.finder.close();
        const target = try findTarget(self.alloc, self.finder.root().?, rel);
        defer target.deinit(self.alloc);
        self.finder.close();

        const i = self.active;
        const p = &self.panes[i];
        const result = if (target.name) |name| p.reveal(target.dir, name) else p.load(target.dir);
        result catch |err| try self.setMessage("{s}: {t}", .{ target.dir, err });
        self.markDirty(i, .full);
        self.bar_dirty = true;
        self.shell.setCwd(p.path);
    }

    /// A keystroke while the popup is open. F3 again closes it, the way
    /// Ctrl+` toggles the shell panel; everything else is the popup's
    /// (see `finderpopup.applyKey`).
    fn finderKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const toggles = if (self.keymap.lookup(k.key, k.mods)) |a| a == .find else false;
        if (toggles) return self.finder.close();
        if (try self.finder.key(k) == .accept) try self.acceptFinder();
    }

    /// Centred over the pane area: everything but the bar.
    fn renderFinder(self: *Ui) !void {
        var b = self.client.batch();
        defer b.deinit();
        try self.finder.render(&b, .{ .row = 0, .col = 0, .cols = self.win.cols, .rows = self.paneHeight() });
        var sent = try b.send();
        sent.deinit();
    }

    // ── Command palette ─────────────────────────────────────────────────

    /// Ctrl+Shift+P: every action `inPalette` admits, with its chord.
    fn openPalette(self: *Ui) !void {
        if (self.finder.isOpen()) self.finder.close();
        var list = palette_mod.List.init(self.alloc);
        errdefer list.deinit();
        for (std.enums.values(Action)) |a| {
            if (!actions.inPalette(a)) continue;
            try list.add(@intFromEnum(a), @tagName(a), actions.paletteLabel(a), self.keymap.chordFor(a));
        }
        try self.palette.open(list);
    }

    /// Runs the palette's pick as if its chord had been pressed: closed
    /// first, so a dialog the action raises isn't under the palette.
    fn acceptPalette(self: *Ui) !void {
        const action = self.palette.selectedAs(Action) orelse return self.palette.close();
        self.palette.close();
        self.clearFind();
        try self.perform(action);
    }

    /// A keystroke while the palette is open. Ctrl+Shift+P again closes
    /// it, the way F3 toggles the finder; everything else is the
    /// palette's.
    fn paletteKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const toggles = if (self.keymap.lookup(k.key, k.mods)) |a| a == .commandPalette else false;
        if (toggles) return self.palette.close();
        if (try self.palette.key(k) == .accept) try self.acceptPalette();
    }

    /// Across the top of the pane area, as VS Code's palette sits.
    fn renderPalette(self: *Ui) !void {
        var b = self.client.batch();
        defer b.deinit();
        try self.palette.render(&b, .{ .row = 0, .col = 0, .cols = self.win.cols, .rows = self.paneHeight() });
        var sent = try b.send();
        sent.deinit();
    }

    // ── Directory history ───────────────────────────────────────────────

    /// Alt+Down: every directory the active pane has shown this session,
    /// newest first, leaving out the one it shows now -- so the top row
    /// is where Alt+Left would go. Typing filters it the way the palette
    /// filters commands, on the path as shown (`~/...`) or in full.
    fn openHistory(self: *Ui) !void {
        self.endPathEdit();
        self.endNameEdit();
        self.clearFind();
        if (self.finder.isOpen()) self.finder.close();
        const p = &self.panes[self.active];
        var list = palette_mod.List.init(self.alloc);
        errdefer list.deinit();
        // A row's id is its index in `recent`, which can't change while
        // the popup is up: it's modal, so the pane can't move.
        for (p.history.recent.items, 0..) |path, idx| {
            if (std.mem.eql(u8, path, p.path)) continue;
            var buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
            try list.add(@intCast(idx), path, self.displayPath(&buf, path, 0), null);
        }
        // The palette puts what was picked from it lately first; a
        // history is already in that order, and its ids are positions
        // that shift between opens, so it starts every open with none.
        self.history_popup.recent = .{};
        try self.history_popup.open(list);
    }

    /// Enter or a click on a row: the pane goes there, as a visit of its
    /// own (so Alt+Left comes back from it).
    fn acceptHistory(self: *Ui) !void {
        const idx = self.history_popup.selected() orelse return self.history_popup.close();
        self.history_popup.close();
        const i = self.active;
        const p = &self.panes[i];
        // `load` reorders `recent`, so the path can't be borrowed from it.
        const path = try self.alloc.dupe(u8, p.history.recent.items[idx]);
        defer self.alloc.free(path);
        p.load(path) catch |err| try self.setMessage("{s}: {t}", .{ path, err });
        self.markDirty(i, .full);
        self.bar_dirty = true;
        self.shell.setCwd(p.path);
    }

    /// A keystroke while the history is open. Alt+Down again closes it;
    /// everything else is the list's.
    fn historyKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const toggles = if (self.keymap.lookup(k.key, k.mods)) |a| a == .showHistory else false;
        if (toggles) return self.history_popup.close();
        if (try self.history_popup.key(k) == .accept) try self.acceptHistory();
    }

    /// Dropped from the top of the active pane, the way a path box's
    /// dropdown hangs under it.
    fn renderHistory(self: *Ui) !void {
        var b = self.client.batch();
        defer b.deinit();
        const i = self.active;
        try self.history_popup.render(&b, .{ .row = 0, .col = self.paneCol(i), .cols = self.paneWidth(i), .rows = self.paneHeight() });
        var sent = try b.send();
        sent.deinit();
    }

    // ── Editing a pane's path ───────────────────────────────────────────

    /// Alt+D: turn the active pane's title row into a text field holding
    /// its directory. There's no dialog -- the path is edited where it's
    /// shown, and until Enter or Escape every key goes to the field.
    fn beginPathEdit(self: *Ui) !void {
        self.endPathEdit(); // Alt+D on the other side moves the field.
        self.endNameEdit();
        const p = &self.panes[self.active];
        self.path_edit = .{ .pane = self.active, .line = try LineEdit.init(self.alloc, p.path) };
        self.markDirty(self.active, .full);
    }

    /// Closes the field and puts the title back, keeping nothing typed.
    fn endPathEdit(self: *Ui) void {
        if (self.path_edit) |*e| {
            e.line.deinit(self.alloc);
            self.markDirty(e.pane, .full);
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
        self.markDirty(e.pane, .full);
    }

    /// Keys while a title row is a field: the shared `LineEdit`'s --
    /// Home/Ctrl+A, End/Ctrl+E, Ctrl+Left/Right word jumps over the path
    /// segments, Ctrl+Backspace to drop one -- with Enter going where the
    /// field says and Escape putting the directory back. Nothing falls
    /// through to the keymap: a `d` typed into a path isn't a command.
    /// An Alt or Super chord is the exception the field itself declines
    /// (`.ignored`), so Alt+D on the *other* pane still moves the field
    /// there rather than being swallowed.
    fn pathEditKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const e = if (self.path_edit) |*pe| pe else return;
        switch (e.line.handleKey(k.key, k.mods)) {
            .moved, .edited => {
                self.markDirty(e.pane, .full);
                return;
            },
            .cancel => return self.endPathEdit(),
            .ignored => {
                if (k.mods.alt or k.mods.super) {
                    if (self.keymap.lookup(k.key, k.mods)) |action| {
                        self.clearMessage();
                        return self.perform(action);
                    }
                }
                return;
            },
            .submit => {
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
                self.markDirty(i, .full);
                self.bar_dirty = true;
            },
        }
    }

    // ── Renaming in place ───────────────────────────────────────────────

    /// F2: turn the name of the entry under the cursor into a text field
    /// in its row, the caret before the extension (see `renameCaret`).
    /// The `..` row has no name of its own to change.
    /// `as_root` is Super+F2: the same field, renaming through sudo.
    fn beginNameEdit(self: *Ui, as_root: bool) !void {
        self.endPathEdit();
        self.endNameEdit();
        const p = &self.panes[self.active];
        const e = p.current() orelse return;
        const original = try self.alloc.dupe(u8, e.name);
        errdefer self.alloc.free(original);
        var line = try LineEdit.init(self.alloc, e.name);
        _ = line.moveTo(renameCaret(e.name, (e.link_target_kind orelse e.kind) == .directory));
        self.name_edit = .{ .pane = self.active, .row = p.list.selected, .original = original, .line = line, .as_root = as_root };
        self.markDirty(self.active, .full);
    }

    /// Closes the field and puts the name back, renaming nothing.
    fn endNameEdit(self: *Ui) void {
        if (self.name_edit) |*e| {
            e.line.deinit(self.alloc);
            self.alloc.free(e.original);
            self.markDirty(e.pane, .full);
        }
        self.name_edit = null;
    }

    /// Keys while a name is a field: the shared `LineEdit`'s editing
    /// keys, Enter to rename and Escape to leave it be. Any other key
    /// that is a command -- Tab, an arrow, F5, Alt+D -- drops the rename
    /// and then does what it would have; one that types a character
    /// (Space marks, keypad `+` marks all) is the field's, since its
    /// text is on its way down the `text` stream.
    fn nameEditKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const e = if (self.name_edit) |*ne| ne else return;
        switch (e.line.handleKey(k.key, k.mods)) {
            .moved, .edited => self.markDirty(e.pane, .full),
            .cancel => self.endNameEdit(),
            .ignored => {
                if (typesText(k.key, k.mods)) return;
                const action = self.keymap.lookup(k.key, k.mods) orelse return;
                self.endNameEdit();
                try self.perform(action);
            },
            .submit => try self.commitNameEdit(),
        }
    }

    /// Enter in the F2 field. An unchanged or blank name just closes it;
    /// a name that can't be used, or that's taken, says so in the bar and
    /// leaves the field open to fix. After a rename the cursor follows
    /// the entry to wherever the sort puts its new name.
    fn commitNameEdit(self: *Ui) !void {
        const e = if (self.name_edit) |*ne| ne else return;
        const p = &self.panes[e.pane];
        const typed = e.line.text();
        if (typed.len == 0 or std.mem.eql(u8, typed, e.original)) return self.endNameEdit();

        const renamed = if (e.as_root)
            self.runSudoSingle(&.{ "rename", p.path, e.original, typed })
        else
            fileops.renameInDir(self.io, self.alloc, p.path, e.original, typed);
        renamed catch |err| {
            switch (err) {
                // Cancelled at the password, or sudo said why in the bar.
                error.NotRun => {},
                error.PathAlreadyExists => try self.setMessage("{s} already exists", .{typed}),
                error.InvalidName => try self.setMessage("can't rename to {s}: a name only, no '/'", .{typed}),
                else => try self.setMessage("rename {s}: {t}", .{ e.original, err }),
            }
            return;
        };

        // Copied: closing the field frees the text it's read from.
        const new_name = try self.alloc.dupe(u8, typed);
        defer self.alloc.free(new_name);
        self.endNameEdit();
        try self.reloadBoth();
        if (p.rowOf(new_name)) |row| p.setCursor(row);
        try self.setMessage("renamed to {s}", .{new_name});
    }

    fn reloadBoth(self: *Ui) !void {
        for (&self.panes, 0..) |*p, i| {
            p.reload() catch |err| try self.setMessage("{s}: {t}", .{ p.path, err });
            self.markDirty(i, .full);
        }
    }

    // ── Mouse ───────────────────────────────────────────────────────────

    fn handleMouseButton(self: *Ui, m: glyphwire.MouseButtonEvent) !void {
        // The pointer follows the keyboard: with the shell panel up,
        // clicks are its business (its own prompt handles them), not a
        // cursor move in a pane nobody is looking at.
        if (self.shell.isOpen()) return;
        // A press held on a row, or a drag under way, gets the next
        // button event whatever it is: the release that ends it, or
        // another button that cancels it.
        if (self.press != null or self.drag != null) return self.dragButton(m);
        if (!m.pressed) return;
        // The popup owns the pointer while it's up: a click picks a row
        // or dismisses it, and never reaches a pane behind it.
        if (self.palette.isOpen()) {
            if (std.mem.eql(u8, m.button, "left") and self.palette.click(m.cell) == .accept) try self.acceptPalette();
            return;
        }
        if (self.history_popup.isOpen()) {
            if (std.mem.eql(u8, m.button, "left") and self.history_popup.click(m.cell) == .accept) try self.acceptHistory();
            return;
        }
        if (self.finder.isOpen()) {
            if (std.mem.eql(u8, m.button, "left") and self.finder.click(m.cell) == .accept) try self.acceptFinder();
            return;
        }
        const left = std.mem.eql(u8, m.button, "left");
        const right = std.mem.eql(u8, m.button, "right");
        if (!left and !right) return;
        if (m.cell.row >= self.paneHeight()) return;

        const i = self.paneAtCol(m.cell.col) orelse return;
        if (i != self.active) {
            self.active = i;
            self.pane_dirty = .{ .full, .full };
        }

        // A left click on a title row is about the path: it opens the
        // field there, or moves the caret in the one already open --
        // Alt+D with the mouse.
        if (m.cell.row == 0 and left) {
            if (self.pathEditFor(i)) |_| self.movePathCaret(m.cell.col) else try self.beginPathEdit();
            return;
        }
        // Clicking anywhere else is leaving the field, not typing in it.
        // The F2 field is left the same way even when the click lands on
        // it: only Enter renames.
        self.endPathEdit();
        self.endNameEdit();
        self.clearFind();

        const p = &self.panes[i];
        // The column header row: a click re-orders the pane by that
        // column, the same cycle `sortByName` and friends run.
        if (m.cell.row == header_row and left) {
            const cols = self.columns(self.paneWidth(i), p.view);
            if (sortKeyForColumn(cols, m.cell.col -| self.paneCol(i))) |key| {
                p.setSort(p.sort.cycled(key));
                self.markDirty(i, .full);
            }
            return;
        }
        if (m.cell.row < list_top) return;
        const slot = (m.cell.row - list_top) / p.view.rowHeight();
        if (slot >= self.visibleRows(i)) return;
        const row = p.list.top + slot;
        if (row >= p.rowCount()) return;

        p.setCursor(row);
        self.markDirty(i, .full);
        if (left and m.mods.alt) {
            // Alt+drag carries files out of the window. The host begins
            // the drag once the pointer moves; a plain Alt+click just
            // lands the cursor here.
            self.last_click = null;
            try self.startDrag(i, row);
            return;
        }
        if (right) {
            // Total Commander's right-click select. It opens nothing, and
            // two in a row must not turn into an activation.
            p.toggleMark(row);
            self.last_click = null;
            return;
        }
        if (m.mods.ctrl) {
            // Ctrl+click is the mouse's Space, but it marks on the
            // release (`dragButton`): held and dragged instead, it's a
            // copy. Never half of a double click, for the same reason as
            // the right button.
            self.last_click = null;
            self.press = .{ .pane = i, .row = row, .px = m.px, .ctrl_mark = true };
            return;
        }

        const lc = self.last_click;
        self.last_click = .{ .pane = i, .row = row };
        if (m.clicks == 2) {
            if (lc) |prev| {
                if (prev.pane == i and prev.row == row) {
                    self.last_click = null;
                    try self.activate(i);
                    return;
                }
            }
        }
        // Held and moved, this press is a drag (`dragMove`).
        self.press = .{ .pane = i, .row = row, .px = m.px, .ctrl_mark = false };
    }

    // ── Drag and drop between the panes ─────────────────────────────────

    /// A button event while `press` or `drag` is live.
    fn dragButton(self: *Ui, m: glyphwire.MouseButtonEvent) !void {
        const left = std.mem.eql(u8, m.button, "left");
        if (self.drag != null) {
            // Letting go drops; any other button pressed meanwhile
            // (the right one, say) calls the whole thing off.
            if (left and !m.pressed) return self.finishDrag();
            if (m.pressed) self.endDrag();
            return;
        }
        const pr = self.press.?;
        self.press = null;
        // Released where it was pressed: a plain click already did its
        // work on the press, a Ctrl+click marks now.
        if (left and !m.pressed and pr.ctrl_mark) {
            self.panes[pr.pane].toggleMark(pr.row);
            self.markDirty(pr.pane, .full);
        }
    }

    /// The pointer moved: a held press past the threshold becomes a drag,
    /// and a drag follows the pointer.
    fn dragMove(self: *Ui, mv: glyphwire.MouseMoveEvent) !void {
        if (self.drag) |*d| {
            d.cell = mv.cell;
            d.copy = mv.mods.ctrl;
            return self.updateDrag();
        }
        const pr = self.press orelse return;
        if (!drag_mod.pastThreshold(pr.px.x, pr.px.y, mv.px.x, mv.px.y)) return;
        self.press = null;

        const p = &self.panes[pr.pane];
        const sources = try drag_mod.carried(self.alloc, p, pr.row);
        // `..` carries nothing, so there's nothing to drag.
        if (sources.len == 0) {
            self.alloc.free(sources);
            return;
        }
        const entry = p.entryAt(pr.row).?;
        self.drag = .{
            .src_pane = pr.pane,
            .sources = sources,
            .icon = lsentries.iconForEntry(entry.*),
            .copy = mv.mods.ctrl,
            .cell = mv.cell,
        };
        try self.updateDrag();
    }

    /// A key while a drag is live. Esc calls it off; Ctrl going down or
    /// up flips the drop between copy and move. Everything else waits.
    fn dragKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const d = &self.drag.?;
        if (std.mem.eql(u8, k.key, "left_control") or std.mem.eql(u8, k.key, "right_control")) {
            if (d.copy == k.pressed) return;
            d.copy = k.pressed;
            return self.updateDrag();
        }
        if (k.pressed and std.mem.eql(u8, k.key, "escape")) self.endDrag();
    }

    /// What's under window cell `cell` for a drop: a pane, and the
    /// listing row there if the pointer is over one.
    fn dropHitAt(self: *const Ui, cell: glyphwire.CellPos) ?drag_mod.Hit {
        if (cell.row >= self.paneHeight()) return null;
        const i = self.paneAtCol(cell.col) orelse return null;
        var hit: drag_mod.Hit = .{ .pane = i };
        if (cell.row >= list_top) {
            const p = &self.panes[i];
            const slot = (cell.row - list_top) / p.view.rowHeight();
            const row = p.list.top + slot;
            if (slot < self.visibleRows(i) and row < p.rowCount()) hit.row = row;
        }
        return hit;
    }

    /// Re-resolves the drop target under the pointer, and redraws the
    /// highlight and the card to match.
    fn updateDrag(self: *Ui) !void {
        const d = &self.drag.?;
        d.target = if (self.dropHitAt(d.cell)) |hit| drag_mod.resolve(&self.panes, d.src_pane, d.sources, hit) else null;

        var b = self.client.batch();
        defer b.deinit();

        // The target folder's row, or the whole listing when it's the
        // pane's own directory. Re-sending an unchanged target is free.
        for (self.pane_layers, 0..) |layer, i| {
            const t = d.target orelse {
                try b.setDropTarget(layer, null);
                continue;
            };
            if (t.pane != i) {
                try b.setDropTarget(layer, null);
                continue;
            }
            const p = &self.panes[i];
            const rh = p.view.rowHeight();
            const w = self.paneWidth(i);
            if (t.row) |row| {
                try b.setDropTarget(layer, .{ .cells = .{ .row = list_top + (row - p.list.top) * rh, .col = 0, .rows = rh, .cols = w } });
            } else {
                try b.setDropTarget(layer, .{ .cells = .{ .row = list_top, .col = 0, .rows = self.visibleRows(i) * rh, .cols = w } });
            }
        }

        // The card: `+` when it would copy, the row's icon, then the
        // name or how many there are -- just off the pointer's corner,
        // pulled back inside the window near the edges.
        var label_buf: [32]u8 = undefined;
        const label = if (d.sources.len == 1)
            std.fs.path.basename(d.sources[0])
        else
            try std.fmt.bufPrint(&label_buf, "{d} files", .{d.sources.len});
        const label_cols = @min(glyphwire.stringWidth(label), 40);
        // ` + ` (or three blanks), the icon's two cells, a space, the
        // label, a space.
        const card_cols = 3 + 2 + 1 + label_cols + 1;
        const row = if (d.cell.row + 1 < self.win.rows) d.cell.row + 1 else d.cell.row -| 1;
        const col = @min(d.cell.col + 2, self.win.cols -| card_cols);

        const layer = self.drag_layer;
        try b.setLayerSize(layer, card_cols, 1);
        try b.setLayerCellPosition(layer, row, col);
        try b.clearArea(.{ .layer = layer, .bg = bg_dialog });
        if (d.copy) try b.writeText("+", .{ .layer = layer, .row = 0, .col = 1, .fg = fg_marked, .bg = bg_dialog });
        try b.writeText(label, .{ .layer = layer, .row = 0, .col = 6, .fg = fg_dialog, .bg = bg_dialog, .max_cols = label_cols });
        try b.drawIconOnStyled(layer, 0, 3, d.icon, .{
            .scale = .natural,
            .h_align = .start,
            .v_align = .center,
            .max_h = self.cell.h,
            .foreground = true,
        });
        try b.setLayerVisible(layer, true);

        var sent = try b.send();
        sent.deinit();
    }

    /// The button came up with a drag live: move or copy the files to
    /// where the pointer is, if that's anywhere. No confirmation -- the
    /// highlight already said where they'd go, and a clash with a file
    /// already there still asks (`hookConflict`).
    fn finishDrag(self: *Ui) !void {
        const d = self.drag.?;
        const target = d.target orelse return self.endDrag();
        const kind: fileops.Kind = if (d.copy) .copy else .move;
        // The target borrows from a pane; the operation outlives nothing
        // that reloads one, but the copy costs nothing and says so.
        const dest = try self.alloc.dupe(u8, target.dest);
        defer self.alloc.free(dest);
        const sources = d.sources;
        self.drag = null;
        defer self.alloc.free(sources);
        try self.hideDrag();

        const result = self.runOperation(.{ .kind = kind, .sources = sources, .dest = dest });
        if (!result.cancelled and result.failed == 0) self.panes[d.src_pane].unmarkAll();
        try self.reloadBoth();
        try self.reportResult(kind, result);
    }

    /// Calls a drag off: nothing moves.
    fn endDrag(self: *Ui) void {
        self.press = null;
        const d = self.drag orelse return;
        self.drag = null;
        self.alloc.free(d.sources);
        self.hideDrag() catch {};
    }

    /// Takes the card and both highlights down.
    fn hideDrag(self: *Ui) !void {
        var b = self.client.batch();
        defer b.deinit();
        for (self.pane_layers) |layer| try b.setDropTarget(layer, null);
        try b.setLayerVisible(self.drag_layer, false);
        var sent = try b.send();
        sent.deinit();
    }

    /// Which way, and which pane, a live drag should scroll: up while the
    /// pointer sits on a pane's column headers, down on its footer, when
    /// there's more listing that way. Null otherwise -- including over
    /// the first and last listing rows, which are drop targets like any
    /// other.
    fn autoScrollStep(self: *const Ui) ?struct { pane: usize, up: bool } {
        const d = self.drag orelse return null;
        if (d.cell.row >= self.paneHeight()) return null;
        const i = self.paneAtCol(d.cell.col) orelse return null;
        const p = &self.panes[i];
        if (d.cell.row == header_row and p.list.top > 0) return .{ .pane = i, .up = true };
        if (d.cell.row == self.paneHeight() -| 1 and p.list.top + self.visibleRows(i) < p.rowCount()) return .{ .pane = i, .up = false };
        return null;
    }

    /// One row of `autoScrollStep`'s scroll, when the loop's timer fired
    /// with the pointer still there.
    fn autoScroll(self: *Ui) !void {
        const step = self.autoScrollStep() orelse return;
        const p = &self.panes[step.pane];
        const top = if (step.up) p.list.top - 1 else p.list.top + 1;
        p.scrollTo(top, self.visibleRows(step.pane));
        self.markDirty(step.pane, .full);
        try self.updateDrag();
    }

    /// Hands glyphwire-host the files an Alt+drag from `row` carries: the
    /// whole marked set when the row is marked, else that row alone --
    /// the same rule F5/F6 follow, except a drag starts on a row and so
    /// never falls back to the cursor. The `..` row carries nothing.
    fn startDrag(self: *Ui, pane_i: usize, row: usize) !void {
        const alloc = self.alloc;
        const p = &self.panes[pane_i];
        const entry = p.entryAt(row) orelse return;

        var uris: std.ArrayList([]const u8) = .empty;
        defer {
            for (uris.items) |u| alloc.free(u);
            uris.deinit(alloc);
        }
        if (p.isMarked(row)) {
            for (p.entries, p.marked) |e, marked| {
                if (marked) try appendUri(alloc, &uris, e.abs_path);
            }
        } else {
            try appendUri(alloc, &uris, entry.abs_path);
        }

        var label_buf: [32]u8 = undefined;
        const label = if (uris.items.len == 1) entry.name else try std.fmt.bufPrint(&label_buf, "{d} files", .{uris.items.len});
        try self.client.startDrag(.{ .uris = uris.items, .label = label, .icon = lsentries.iconForEntry(entry.*) });
    }

    fn appendUri(alloc: std.mem.Allocator, uris: *std.ArrayList([]const u8), path: []const u8) !void {
        const uri = try lsentries.fileUri(alloc, path);
        errdefer alloc.free(uri);
        try uris.append(alloc, uri);
    }

    // ── Clipboard ───────────────────────────────────────────────────────

    /// Ctrl+Shift+C: put the active pane's selected paths on the OS
    /// clipboard, so they can be pasted straight into a command --
    /// `zip shots.zip ` then Ctrl+Shift+V in the Ctrl+` panel.
    ///
    /// There is no key binding for this: glyphwire-host swallows
    /// Ctrl+Shift+C as its own copy shortcut, and broadcasts
    /// `copy_request` only when its selection is empty (see
    /// `host/selection.zig`'s `copyShortcut`). That is the behaviour we
    /// want anyway -- text dragged out of the shell panel copies as text,
    /// and the shortcut falls through to the paths the rest of the time.
    ///
    /// Marked entries, or the entry under the cursor when nothing is
    /// marked (`Pane.selection` -- the same set F5/F6 act on), as one
    /// space-separated line with each path quoted only if it needs it.
    /// Byte for byte the line gw-shell answers the same request with, so
    /// the two paste identically.
    ///
    /// While the shell panel is up the request is its business, not ours:
    /// it has its own prompt line to copy, and the pointer and the
    /// keyboard both follow it (see `handleMouseButton`).
    fn copySelectionPaths(self: *Ui) !void {
        if (self.shell.isOpen()) return;
        const alloc = self.alloc;

        const sel = try self.panes[self.active].selection(alloc);
        defer alloc.free(sel);
        if (sel.len == 0) return;

        const line = try pathsLine(alloc, sel);
        defer alloc.free(line);

        try self.client.setClipboard(line);
        try self.setMessage("copied {d} path{s}", .{ sel.len, if (sel.len == 1) "" else "s" });
    }

    // ── File operations ─────────────────────────────────────────────────

    /// F5 / F6: copy or move the selection, to a destination the user
    /// confirms (the other pane's directory to start with). `as_root` is
    /// Super+F5 / Super+F6.
    fn transfer(self: *Ui, kind: fileops.Kind, as_root: bool) !void {
        const src_i = self.active;
        const src = &self.panes[src_i];
        const sel = try src.selection(self.alloc);
        defer self.alloc.free(sel);
        if (sel.len == 0) return;

        const what = try describeSelection(self.alloc, sel);
        defer self.alloc.free(what);
        const prompt = try std.fmt.allocPrint(self.alloc, "{s} {s} to:", .{ kind.label(), what });
        defer self.alloc.free(prompt);

        var title_buf: [64]u8 = undefined;
        var d = try Dialog.init(self.alloc, titleFor(&title_buf, kind.label(), as_root), prompt, &dialog_mod.ok_cancel, .{ .input = self.panes[1 - src_i].path });
        defer d.deinit(self.alloc);
        if (try self.runDialog(&d) != .ok) return;

        const dest = try self.resolveTyped(src.path, d.inputText());
        defer self.alloc.free(dest);

        const result = (try self.runOperationAs(.{ .kind = kind, .sources = sel, .dest = dest }, as_root)) orelse return;
        if (!result.cancelled and result.failed == 0) src.unmarkAll();
        try self.reloadBoth();
        try self.reportResult(kind, result);
    }

    /// F8: move the selection to the trash after a yes/no. Yes is the
    /// default, since the trash gives it back. Anything the trash can't
    /// take is put to `hookNoTrash`.
    fn trashSelection(self: *Ui) !void {
        const p = &self.panes[self.active];
        const sel = try p.selection(self.alloc);
        defer self.alloc.free(sel);
        if (sel.len == 0) return;

        const what = try describeSelection(self.alloc, sel);
        defer self.alloc.free(what);
        const prompt = try std.fmt.allocPrint(self.alloc, "Move {s} to the trash?", .{what});
        defer self.alloc.free(prompt);

        var d = try Dialog.init(self.alloc, "Trash", prompt, &dialog_mod.yes_no, .{});
        defer d.deinit(self.alloc);
        if (try self.runDialog(&d) != .yes) return;

        const xdg = if (self.environ) |env| env.get("XDG_DATA_HOME") else null;
        const home_trash = try trash_mod.homeTrashPath(self.alloc, xdg, self.home);
        defer if (home_trash) |h| self.alloc.free(h);
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        var date_buf: [32]u8 = undefined;
        const opts: trash_mod.Options = .{
            .home_trash = home_trash,
            .deletion_date = trash_mod.formatDeletionDate(&date_buf, now, trash_mod.localUtcOffset(now)),
            .uid = trash_mod.currentUid(),
        };

        const result = self.runOperation(.{ .kind = .trash, .sources = sel, .trash = opts });
        try self.reloadBoth();
        try self.reportResult(.trash, result);
    }

    /// Shift+F8: delete the selection outright after a yes/no. The
    /// default button is No, so a stray Enter doesn't delete anything.
    /// `as_root` is Super+F8, which never goes through the trash.
    fn deleteSelection(self: *Ui, as_root: bool) !void {
        const p = &self.panes[self.active];
        const sel = try p.selection(self.alloc);
        defer self.alloc.free(sel);
        if (sel.len == 0) return;

        const what = try describeSelection(self.alloc, sel);
        defer self.alloc.free(what);
        const prompt = try std.fmt.allocPrint(self.alloc, "Delete {s}?", .{what});
        defer self.alloc.free(prompt);

        var title_buf: [64]u8 = undefined;
        var d = try Dialog.init(self.alloc, titleFor(&title_buf, "Delete", as_root), prompt, &dialog_mod.yes_no, .{ .danger = true, .focus = 1 });
        defer d.deinit(self.alloc);
        if (try self.runDialog(&d) != .yes) return;

        const result = (try self.runOperationAs(.{ .kind = .delete, .sources = sel }, as_root)) orelse return;
        try self.reloadBoth();
        try self.reportResult(.delete, result);
    }

    /// F7: make a directory (and any missing parents) in the active pane,
    /// then put the cursor on it. `as_root` is Super+F7.
    fn makeDir(self: *Ui, as_root: bool) !void {
        const p = &self.panes[self.active];
        var title_buf: [64]u8 = undefined;
        var d = try Dialog.init(self.alloc, titleFor(&title_buf, "Make directory", as_root), "Name of the new directory:", &dialog_mod.ok_cancel, .{ .input = "" });
        defer d.deinit(self.alloc);
        if (try self.runDialog(&d) != .ok) return;
        const typed = std.mem.trim(u8, d.inputText(), " ");
        if (typed.len == 0) return;

        const path = try self.resolveTyped(p.path, typed);
        defer self.alloc.free(path);
        const made = if (as_root) self.runSudoSingle(&.{ "mkdir", path }) else fileops.makeDir(self.io, path);
        made catch |err| {
            if (err == error.NotRun) return;
            try self.setMessage("mkdir {s}: {t}", .{ typed, err });
            return;
        };
        try self.reloadBoth();
        // `a/b/c` creates `a` here; land on that.
        const first = typed[0 .. std.mem.indexOfScalar(u8, typed, '/') orelse typed.len];
        if (p.rowOf(first)) |row| p.setCursor(row);
        try self.setMessage("created {s}", .{typed});
    }

    // ── F1: the file operations menu, chmod and chown ───────────────────

    /// F1: the menu of `menu_keys`' unmodified chords. What it picks goes
    /// through `perform` like a key would, so a binding in `menu_keys` to
    /// any action works from here. `anyerror` because it and `perform`
    /// call each other, which an inferred error set can't resolve.
    fn fileOpsMenu(self: *Ui) anyerror!void {
        var menu = attrdialog.Menu.init(&self.menu_keymap);
        menu.load();
        if (menu.entries.len == 0) {
            try self.setMessage("menu_keys binds nothing without modifiers", .{});
            return;
        }
        const pick = try self.runModal(MenuModal{ .ui = self, .menu = &menu });
        switch (pick) {
            .cancel => {},
            // Not itself again: a menu inside the menu is no help.
            .run => |a| if (a != .fileOpsMenu) try self.perform(a),
        }
    }

    /// chmod: the twelve-toggle dialog, starting from the first selected
    /// entry's mode, then the same mode on everything selected.
    fn changeMode(self: *Ui, as_root: bool) !void {
        const p = &self.panes[self.active];
        const sel = try p.selection(self.alloc);
        defer self.alloc.free(sel);
        const first = p.firstSelected() orelse return;
        if (sel.len == 0) return;

        const what = try describeSelection(self.alloc, sel);
        defer self.alloc.free(what);
        var f = try attrdialog.ModeForm.init(self.alloc, what, @truncate(first.mode & 0o7777), p.selectionHasDir(), as_root);
        defer f.deinit(self.alloc);
        if (try self.runModal(FormModal(attrdialog.ModeForm){ .ui = self, .form = &f }) != .set) return;

        try self.runAttrs(.{ .change = .{ .mode = f.mode }, .sources = sel, .recursive = f.recursive(), .filter = f.filter() }, as_root);
    }

    /// chown: owner and group fields, starting from the first selected
    /// entry's names.
    fn changeOwner(self: *Ui, as_root: bool) !void {
        const p = &self.panes[self.active];
        const sel = try p.selection(self.alloc);
        defer self.alloc.free(sel);
        const first = p.firstSelected() orelse return;
        if (sel.len == 0) return;

        const what = try describeSelection(self.alloc, sel);
        defer self.alloc.free(what);
        var ubuf: [16]u8 = undefined;
        var gbuf: [16]u8 = undefined;
        // Copied out: `userName`'s answer points into libc's own buffer,
        // which `groupName` may reuse.
        var user_buf: [256]u8 = undefined;
        const user_name = lsentries.userName(first.uid, &ubuf);
        const user = user_buf[0..@min(user_name.len, user_buf.len)];
        @memcpy(user, user_name[0..user.len]);
        const group = lsentries.groupName(first.gid, &gbuf);

        var f = try attrdialog.OwnerForm.init(self.alloc, what, user, group, p.selectionHasDir(), as_root);
        defer f.deinit(self.alloc);
        if (try self.runModal(FormModal(attrdialog.OwnerForm){ .ui = self, .form = &f }) != .set) return;

        try self.runAttrs(.{ .change = .{ .owner = f.owner }, .sources = sel, .recursive = f.recursive(), .filter = f.filter() }, as_root);
    }

    /// Runs a chmod/chown, in-process or through the sudo helper. An
    /// in-process run offers "Retry as root" on a permission error; taken,
    /// it stops there and the whole change starts over as root -- it sets
    /// absolute values, so what the first run already did is harmless to
    /// do again.
    fn runAttrs(self: *Ui, op: attrs.Operation, as_root: bool) !void {
        const p = &self.panes[self.active];
        const result = if (as_root) (try self.runAttrsAsRoot(op)) orelse return else blk: {
            self.root_retry = .offered;
            const r = op.run(self.io, self.alloc, self.fileHooks());
            const chosen = self.root_retry == .chosen;
            self.root_retry = .off;
            if (!chosen) break :blk r;
            break :blk (try self.runAttrsAsRoot(op)) orelse {
                try self.reloadBoth();
                return;
            };
        };
        if (!result.cancelled and result.failed == 0) p.unmarkAll();
        try self.reloadBoth();
        try self.reportResult(op.change.kind(), result);
    }

    fn runAttrsAsRoot(self: *Ui, op: attrs.Operation) !?fileops.Result {
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        return self.runSudo(try attrs.helperArgs(arena.allocator(), op));
    }

    fn runOperation(self: *Ui, op: fileops.Operation) fileops.Result {
        return op.run(self.io, self.alloc, self.fileHooks());
    }

    /// `runOperation`, or as root through the sudo helper. Null when the
    /// root run never happened -- cancelled at the password, or sudo
    /// refused, which the bar already says.
    fn runOperationAs(self: *Ui, op: fileops.Operation, as_root: bool) !?fileops.Result {
        if (!as_root) return self.runOperation(op);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.alloc);
        try args.append(self.alloc, @tagName(op.kind));
        if (op.kind != .delete) try args.append(self.alloc, op.dest);
        try args.appendSlice(self.alloc, op.sources);
        return self.runSudo(args.items);
    }

    /// The dialogs and progress line every file operation reports
    /// through, in-process or relayed from the sudo helper.
    fn fileHooks(self: *Ui) fileops.Hooks {
        return .{
            .ctx = self,
            .onConflict = hookConflict,
            .onProgress = hookProgress,
            .onError = hookError,
            .onNoTrash = hookNoTrash,
        };
    }

    /// Runs the sudo helper for `args` (see `sudo.Op`), after the
    /// password if sudo wants one. Null when it didn't run.
    fn runSudo(self: *Ui, args: []const []const u8) !?fileops.Result {
        if (!try self.sudoAuthorize()) return null;
        const exe = try std.process.executablePathAlloc(self.io, self.alloc);
        defer self.alloc.free(exe);
        const outcome = try sudo.run(self.io, self.alloc, exe, args, self.fileHooks());
        defer outcome.deinit(self.alloc);
        switch (outcome) {
            .result => |r| return r,
            .failed => |why| {
                try self.setMessage("sudo: {s}", .{why});
                return null;
            },
        }
    }

    /// `runSudo` for a one-shot operation (mkdir, rename), as the error
    /// it failed with, so its caller reads it like the in-process call's.
    /// `error.NotRun` when it never ran.
    fn runSudoSingle(self: *Ui, args: []const []const u8) anyerror!void {
        const r = (try self.runSudo(args)) orelse return error.NotRun;
        if (r.first_error) |err| return err;
    }

    /// Makes sure sudo will run things without asking: straight through
    /// when it remembers a recent password (or needs none), otherwise a
    /// masked password dialog, three tries as sudo itself gives. False
    /// when cancelled or refused; a refusal is said in the bar.
    fn sudoAuthorize(self: *Ui) !bool {
        if (sudo.hasCachedCredentials(self.io)) return true;
        var why: ?[]u8 = null;
        defer if (why) |w| self.alloc.free(w);
        for (0..3) |_| {
            const prompt = if (why) |w|
                try std.fmt.allocPrint(self.alloc, "{s}\nPassword for sudo:", .{w})
            else
                try self.alloc.dupe(u8, "Password for sudo:");
            defer self.alloc.free(prompt);
            var d = try Dialog.init(self.alloc, "sudo", prompt, &dialog_mod.ok_cancel, .{ .input = "", .masked = true });
            defer d.deinit(self.alloc);
            if (try self.runDialog(&d) != .ok) return false;

            try self.setMessage("checking the password...", .{});
            self.renderBar() catch {};
            switch (try sudo.checkPassword(self.io, self.alloc, d.inputText())) {
                .ok => {
                    try self.setMessage("", .{});
                    return true;
                },
                .rejected => |w| {
                    if (why) |old| self.alloc.free(old);
                    why = w;
                },
            }
        }
        try self.setMessage("sudo: {s}", .{why.?});
        return false;
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
        // See `runAttrs`: a chmod/chown refused for want of permission
        // can be started over as root.
        const offer_root = self.root_retry == .offered and (err == error.AccessDenied or err == error.PermissionDenied);
        const buttons: []const Button = if (offer_root) &dialog_mod.error_root_buttons else &dialog_mod.error_buttons;
        var d = Dialog.init(self.alloc, "Error", msg, buttons, .{ .danger = true }) catch return false;
        defer d.deinit(self.alloc);
        const b = self.runDialog(&d) catch return false;
        if (b == .retry_as_root) {
            self.root_retry = .chosen;
            return false;
        }
        return b == .@"continue";
    }

    /// An entry the trash can't take: delete it outright instead? Skip is
    /// the focused answer, as No is for Shift+F8.
    fn hookNoTrash(ctx: *anyopaque, path: []const u8, err: anyerror) fileops.NoTrash {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        const msg = std.fmt.allocPrint(self.alloc, "Can't move to the trash:\n{s}\n\n{s}\n\nDelete it permanently?", .{ path, errorText(err) }) catch return .cancel;
        defer self.alloc.free(msg);
        var d = Dialog.init(self.alloc, "No trash", msg, &dialog_mod.no_trash_buttons, .{ .danger = true, .focus = dialog_mod.no_trash_skip }) catch return .cancel;
        defer d.deinit(self.alloc);
        const b = self.runDialog(&d) catch return .cancel;
        return switch (b) {
            .delete => .delete,
            .skip => .skip,
            .delete_all => .delete_all,
            .skip_all => .skip_all,
            else => .cancel,
        };
    }

    fn reportResult(self: *Ui, kind: fileops.Kind, r: fileops.Result) !void {
        const verb = switch (kind) {
            .copy => "copied",
            .move => "moved",
            .trash => "trashed",
            .delete => "deleted",
            .chmod => "changed the mode of",
            .chown => "changed the owner of",
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
                    if (d.handleKey(k.key, k.mods)) |b| return b;
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
                    return d.handleKey("escape", .{}).?;
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
        try b.writeText(title, .{ .layer = layer, .row = 0, .col = title_col, .fg = fg_title_active, .bg = title_bg, .max_cols = w });

        var row: usize = 2;
        it = std.mem.splitScalar(u8, d.message, '\n');
        while (it.next()) |line| : (row += 1) {
            if (row >= h -| 2) break;
            try b.writeText(line, .{ .layer = layer, .row = row, .col = 2, .fg = fg_dialog, .bg = bg_dialog, .max_cols = w -| 4 });
        }
        row += 1;

        if (d.input) |*in| {
            const field_w = w -| 4;
            // A password field shows its mask instead, on masked cells,
            // so the text never leaves this process and the ●s never
            // read back out of the grid. See `Dialog.masked`.
            var mask_buf: [512 * dialog_mod.mask_glyph.len]u8 = undefined;
            const shown = if (d.masked)
                dialog_mod.maskText(&mask_buf, in.text(), in.caret)
            else
                dialog_mod.Shown{ .text = in.text(), .caret = in.caret };
            const view = fieldView(shown.text, shown.caret, field_w);
            try b.writeText(shown.text[view.start..], .{ .layer = layer, .row = row, .col = 2, .fg = fg_dialog, .bg = bg_input, .max_cols = field_w, .pad = true, .masked = d.masked });
            // The caret: the character under it (or a blank past the end)
            // drawn in reverse.
            const under = if (shown.caret < shown.text.len) shown.text[shown.caret..nextCodepoint(shown.text, shown.caret)] else " ";
            try b.writeText(under, .{ .layer = layer, .row = row, .col = 2 + view.caret_col, .fg = bg_input, .bg = fg_dialog, .masked = d.masked });
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
            try b.writeText(text, .{ .layer = layer, .row = row, .col = col, .fg = fg_dialog, .bg = bg });
            if (d.input == null) {
                try b.writeText(label[0..1], .{ .layer = layer, .row = row, .col = col + 2, .fg = fg_marked, .bg = bg });
            }
            if (i < self.button_spans.len) self.button_spans[i] = .{ .row = row, .col = col, .w = bw };
            col += bw + 1;
        }

        try b.setLayerVisible(layer, true);
        var sent = try b.send();
        sent.deinit();
    }

    /// `runDialog` for F1's menu and forms: `modal` is a `MenuModal` or a
    /// `FormModal`, and this loops on the dialog layer until it answers.
    /// A modifier going down or up redraws it as well as the bar -- the
    /// menu's lines say what a pick would run under them.
    fn runModal(self: *Ui, modal: anytype) !@TypeOf(modal).Result {
        defer self.client.setLayerVisible(self.dialog_layer, false) catch {};
        try self.flush();
        try modal.render();

        // Typing sends a key press before its text, so text that comes
        // before any press here belongs to the key that opened this --
        // the `m` that picked chmod in the F1 menu -- and would otherwise
        // land in the form's first field.
        var pressed_here = false;
        while (true) {
            const ev = try self.listener.next(.none) orelse continue;
            defer ev.deinit(self.alloc);
            switch (ev) {
                .key => |k| {
                    const mods_changed = self.noteKey(k);
                    if (!isModifierKey(k.key) and k.pressed) {
                        pressed_here = true;
                        if (try modal.key(k)) |r| return r;
                    } else if (!mods_changed) continue;
                    try self.flush();
                    try modal.render();
                },
                .text => |t| if (pressed_here) {
                    if (try modal.text(t.text)) |r| return r;
                    try modal.render();
                },
                .paste => |t| {
                    if (try modal.text(t.text)) |r| return r;
                    try modal.render();
                },
                .mouse_move => |mv| if (self.noteMods(mv.mods)) {
                    try self.flush();
                    try modal.render();
                },
                .mouse_button => |m| {
                    _ = self.noteMods(m.mods);
                    if (m.pressed and std.mem.eql(u8, m.button, "left")) {
                        if (self.dialogCell(m.cell)) |c| {
                            if (try modal.click(c, m.mods)) |r| return r;
                        }
                    }
                    try self.flush();
                    try modal.render();
                },
                .focus => |f| if (!f.focused and self.noteMods(.{})) {
                    try self.flush();
                    try modal.render();
                },
                .resize => |r| {
                    try self.handleResize(r);
                    try self.flush();
                    try modal.render();
                },
                .layout => |l| {
                    try self.handleLayout(l);
                    try self.flush();
                    try modal.render();
                },
                .shutdown => {
                    self.quit = true;
                    return modal.cancelled();
                },
                else => {},
            }
        }
    }

    /// `cell` in dialog-layer cells, or null left of or above it.
    fn dialogCell(self: *const Ui, cell: glyphwire.CellPos) ?glyphwire.CellPos {
        if (cell.row < self.dialog_pos.row or cell.col < self.dialog_pos.col) return null;
        return .{ .row = cell.row - self.dialog_pos.row, .col = cell.col - self.dialog_pos.col };
    }

    /// Sizes the dialog layer to `w` x `h` (clamped to the window),
    /// centres it, clears it and draws the title bar. Returns the size
    /// used.
    fn beginDialogFrame(self: *Ui, b: *Batch, title: []const u8, w_want: usize, h_want: usize, danger: bool) !struct { w: usize, h: usize } {
        const layer = self.dialog_layer;
        const w = @min(w_want, @max(self.win.cols, 10));
        const h = @min(h_want, @max(self.win.rows, 4));
        const row0 = (self.win.rows -| h) / 2;
        const col0 = (self.win.cols -| w) / 2;
        self.dialog_pos = .{ .row = row0, .col = col0 };
        try b.setLayerSize(layer, w, h);
        try b.setLayerCellPosition(layer, row0, col0);
        try b.clearArea(.{ .layer = layer, .bg = bg_dialog });

        const title_bg = if (danger) bg_dialog_danger else bg_dialog_title;
        var title_buf: [256]u8 = undefined;
        const shown = std.fmt.bufPrint(&title_buf, " {s} ", .{title}) catch title;
        try b.clearArea(.{ .layer = layer, .row = 0, .rows = 1, .bg = title_bg });
        try b.writeText(shown, .{ .layer = layer, .row = 0, .col = (w -| glyphwire.stringWidth(shown)) / 2, .fg = fg_title_active, .bg = title_bg, .max_cols = w });
        return .{ .w = w, .h = h };
    }

    /// The F1 menu: one line per entry, worded for what a pick does with
    /// the modifiers held right now, its hotkey picked out, and a hint
    /// under them naming the focused entry's modified chord. The title
    /// turns the warning colour while a pick would run as root.
    fn renderMenu(self: *Ui, menu: *const attrdialog.Menu) !void {
        const layer = self.dialog_layer;
        const held = self.held;

        var hint_buf: [128]u8 = undefined;
        const hint = menuHint(&hint_buf, menu);
        // Wide enough for every wording a line can take, so holding a
        // modifier doesn't resize the dialog under the pointer.
        var widest: usize = @max("File operations".len + 4, glyphwire.stringWidth(hint));
        for (self.menu_keymap.bindings.items) |bnd| widest = @max(widest, 5 + glyphwire.stringWidth(actions.menuLabel(bnd.action)));
        const n = menu.entries.len;

        var b = self.client.batch();
        defer b.deinit();
        const size = try self.beginDialogFrame(&b, "File operations", widest + 4, n + 5, menu.asRoot(held));

        for (menu.entries, 0..) |entry, i| {
            const row = 2 + i;
            const bg = if (i == menu.focus) bg_button_focus else bg_dialog;
            try b.clearArea(.{ .layer = layer, .row = row, .rows = 1, .col = 1, .cols = size.w -| 2, .bg = bg });
            if (self.menu_keymap.chordFor(entry)) |chord| {
                var kbuf: [48]u8 = undefined;
                try b.writeText(chord.format(&kbuf), .{ .layer = layer, .row = row, .col = 2, .fg = fg_marked, .bg = bg });
            }
            const action = menu.shown(i, held);
            const fg = if (actions.isRoot(action)) fg_message else fg_dialog;
            try b.writeText(actions.menuLabel(action), .{ .layer = layer, .row = row, .col = 5, .fg = fg, .bg = bg, .max_cols = size.w -| 6 });
        }
        try b.writeText(hint, .{ .layer = layer, .row = 3 + n, .col = 2, .fg = fg_detail, .bg = bg_dialog, .max_cols = size.w -| 4 });

        try b.setLayerVisible(layer, true);
        var sent = try b.send();
        sent.deinit();
    }

    /// A `form.Form`: its widgets where it laid them out, the focused
    /// one highlighted, and its complaint (if any) in the message colour.
    fn renderForm(self: *Ui, f: *const form_mod.Form) !void {
        const layer = self.dialog_layer;
        var b = self.client.batch();
        defer b.deinit();
        const size = try self.beginDialogFrame(&b, f.title, f.w, f.h, f.danger);

        for (f.widgets.items, 0..) |*wd, i| {
            if (wd.row >= size.h or wd.col >= size.w) continue;
            const focused = i == f.focus;
            const room = size.w - wd.col;
            const at: glyphwire.Client.TextOpts = .{ .layer = layer, .row = wd.row, .col = wd.col, .fg = fg_dialog, .bg = bg_dialog, .max_cols = room };
            switch (wd.kind) {
                .text => |t| try b.writeText(t, at),
                .field => |fl| {
                    const width = @min(fl.width, room);
                    const text = fl.edit.text();
                    const view = fieldView(text, fl.edit.caret, width);
                    var o = at;
                    o.bg = bg_input;
                    o.max_cols = width;
                    o.pad = true;
                    try b.writeText(text[view.start..], o);
                    if (focused and view.caret_col < width) {
                        const under = if (fl.edit.caret < text.len) text[fl.edit.caret..nextCodepoint(text, fl.edit.caret)] else " ";
                        try b.writeText(under, .{ .layer = layer, .row = wd.row, .col = wd.col + view.caret_col, .fg = bg_input, .bg = fg_dialog });
                    }
                },
                .check, .radio => |t| {
                    const box = switch (wd.kind) {
                        .check => if (t.on) "[x]" else "[ ]",
                        else => if (t.on) "(\u{2022})" else "( )",
                    };
                    var o = at;
                    if (focused) o.bg = bg_button_focus;
                    if (t.on) o.fg = fg_marked;
                    try b.writeText(box, o);
                    if (t.label.len > 0 and room > 4) {
                        var lo = at;
                        lo.col = wd.col + 4;
                        lo.max_cols = room - 4;
                        if (focused) lo.bg = bg_button_focus;
                        try b.writeText(t.label, lo);
                    }
                },
                .button => |btn| {
                    var lbuf: [32]u8 = undefined;
                    var o = at;
                    o.bg = if (focused) bg_button_focus else bg_button;
                    try b.writeText(std.fmt.bufPrint(&lbuf, "[ {s} ]", .{btn.label()}) catch btn.label(), o);
                },
            }
        }
        if (f.err) |e| {
            try b.writeText(e, .{ .layer = layer, .row = f.error_row, .col = 2, .fg = fg_message, .bg = bg_dialog, .max_cols = size.w -| 4 });
        }

        try b.setLayerVisible(layer, true);
        var sent = try b.send();
        sent.deinit();
    }

    // ── Geometry ────────────────────────────────────────────────────────

    /// Both panes share one row split, so they are always the same height.
    fn paneHeight(self: *const Ui) usize {
        return self.pane_bounds[0].rows;
    }

    fn paneCol(self: *const Ui, i: usize) usize {
        return self.pane_bounds[i].col;
    }

    fn paneWidth(self: *const Ui, i: usize) usize {
        return self.pane_bounds[i].cols;
    }

    /// The pane under window column `col`, or null on the band between
    /// them (the host takes a press there for the drag anyway).
    fn paneAtCol(self: *const Ui, col: usize) ?usize {
        for (self.pane_bounds, 0..) |b, i| {
            if (col >= b.col and col < b.col + b.cols) return i;
        }
        return null;
    }

    /// The field open on pane `i`'s title row, if that's where it is.
    fn pathEditFor(self: *Ui, i: usize) ?*PathEdit {
        if (self.path_edit) |*e| {
            if (e.pane == i) return e;
        }
        return null;
    }

    /// The F2 field, if it's open in pane `i`.
    fn nameEditFor(self: *Ui, i: usize) ?*NameEdit {
        if (self.name_edit) |*e| {
            if (e.pane == i) return e;
        }
        return null;
    }

    /// How many entries fit in pane `i`'s list area.
    fn visibleRows(self: *const Ui, i: usize) usize {
        const list_rows = self.paneHeight() -| chrome_rows;
        return @max(list_rows / self.panes[i].view.rowHeight(), 1);
    }

    /// Asks the server where the split tree put the panes, for when no
    /// `layout` is on its way: startup.
    fn readBounds(self: *Ui) !void {
        for (self.pane_layers, 0..) |l, i| {
            const cell = try self.client.getLayerCellPosition(l);
            const vp = try self.client.getLayerViewport(l);
            self.pane_bounds[i] = .{ .row = cell.row, .col = cell.col, .cols = vp.cols, .rows = vp.rows };
        }
        try self.sizeLayers();
    }

    /// Keeps each layer's content grid the size of the pane it was laid
    /// out in. Where the layers sit is the split tree's business; what
    /// they hold is ours.
    fn sizeLayers(self: *Ui) !void {
        var b = self.client.batch();
        defer b.deinit();
        for (self.pane_layers, 0..) |l, i| {
            try b.setLayerSize(l, self.paneWidth(i), self.paneHeight());
        }
        try b.setLayerSize(self.bar_layer, self.win.cols, 1);
        var sent = try b.send();
        sent.deinit();
        self.pushed_scroll = .{ .{ std.math.maxInt(usize), 0 }, .{ std.math.maxInt(usize), 0 } };
        // The panel is placed against whatever the window is now, and
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
        self.syncTitle();
        for (0..2) |i| {
            switch (self.pane_dirty[i]) {
                .none => {},
                .bg, .rows => |level| try self.renderPaneRows(i, level),
                .full => try self.renderPane(i),
            }
        }
        if (self.bar_dirty) try self.renderBar();
        if (self.finder.dirty) try self.renderFinder();
        if (self.palette.dirty) try self.renderPalette();
        if (self.history_popup.dirty) try self.renderHistory();
    }

    /// The cheap repaint, for a move that left the listing itself alone:
    /// the row the cursor left, the row it landed on, and the footer --
    /// plus, when the move scrolled, a `move_content` shift of the list
    /// band and the band of rows that shift exposed.
    ///
    /// This is what makes a remote pane usable. The full repaint below is
    /// a ~54 KB frame at 160x50; holding an arrow key sends one repaint
    /// per keystroke either way, and this one is a couple of KB.
    ///
    /// `level` says what the two cursor rows owe. At `.bg` -- every plain
    /// cursor move -- only the highlight moved, so each is one `set_bg`
    /// over its band and its text is never resent. At `.rows` they are
    /// redrawn outright, which is what a mark toggle needs: a mark
    /// changes the row's foreground and puts a `*` in column 0.
    ///
    /// Falls back to `renderPane` when the small diff isn't valid: an open
    /// path field (the title row is a live text field), or a jump of a
    /// screenful or more, where no row survives the shift and moving the
    /// content first would only add a message to a full redraw.
    fn renderPaneRows(self: *Ui, i: usize, level: PaneDirty) !void {
        const p = &self.panes[i];
        const visible = self.visibleRows(i);
        p.scrollIntoView(visible);
        if (self.pathEditFor(i) != null or self.nameEditFor(i) != null) return self.renderPane(i);

        const old_top = self.drawn_top[i];
        const scrolled_down = p.list.top > old_top;
        const delta = if (scrolled_down) p.list.top - old_top else old_top - p.list.top;
        if (delta >= visible) return self.renderPane(i);

        self.pane_dirty[i] = .none;
        const layer = self.pane_layers[i];
        const w = self.paneWidth(i);
        const h = self.paneHeight();
        const rh = p.view.rowHeight();
        const cols = self.columns(w, p.view);
        const end = @min(p.list.top + visible, p.rowCount());

        const before = self.client.bytes_sent;
        const frames_before = self.client.frames_sent;

        var b = self.client.batch();
        defer b.deinit();

        // Shift what's already on the host rather than resending it. The
        // band is the list area only -- the title, the header and the
        // footer stay put.
        var exposed_from = p.list.top;
        var exposed_to = p.list.top;
        if (delta > 0) {
            try b.moveContent(
                layer,
                list_top,
                list_top + visible * rh - 1,
                delta * rh,
                if (scrolled_down) .up else .down,
            );
            // Scrolling toward the end exposes the last `delta` rows;
            // toward the start, the first `delta`.
            if (scrolled_down) {
                exposed_from = p.list.top + visible - delta;
                exposed_to = p.list.top + visible;
            } else {
                exposed_to = p.list.top + delta;
            }
        }

        // The exposed band, plus the two cursor rows: the one the cursor
        // left needs its highlight taken off, the one it landed on needs
        // it put on. Deduplicated against the band, and against each
        // other -- a mark toggle without a move, or a Home already at the
        // top, leaves the cursor where it was.
        var drawn: usize = 0;
        var row = exposed_from;
        while (row < @min(exposed_to, end)) : (row += 1) {
            try self.writeListRow(&b, i, row, w, cols);
            drawn += 1;
        }
        const cursor_rows = [2]usize{ self.drawn_cursor[i], p.list.selected };
        for (cursor_rows, 0..) |r, n| {
            if (n == 1 and cursor_rows[0] == cursor_rows[1]) break;
            if (r < p.list.top or r >= end) continue;
            if (r >= exposed_from and r < exposed_to) continue; // already drawn
            if (level == .bg) {
                try self.setRowColors(&b, i, r, cols);
            } else {
                try self.writeListRow(&b, i, r, w, cols);
            }
            drawn += 1;
        }

        // The footer counts marked entries and names the one under the
        // cursor, so it follows every move.
        try writeFooter(&b, layer, p, h -| 1, w);

        // The scrollbar's position, when the move scrolled. The extent is
        // the listing's and hasn't changed, so only the offset is sent.
        if (delta > 0) {
            const offset = p.list.top * rh;
            if (self.pushed_scroll[i][1] != offset) try b.setLayerScrollOffset(layer, offset, 0);
            self.pushed_scroll[i][1] = offset;
        }

        var sent = try b.send();
        sent.deinit();

        self.drawn_cursor[i] = p.list.selected;
        self.drawn_top[i] = p.list.top;
        self.reportRedraw(i, drawn, self.client.bytes_sent - before, self.client.frames_sent - frames_before);
    }

    /// One listing row and its icon, at the screen position `p.list.top` puts
    /// it. The icon goes last for the same reason the full repaint draws
    /// all of them last: a text write clears a cell's foreground icon.
    fn writeListRow(self: *Ui, b: *Batch, i: usize, row: usize, w: usize, cols: Columns) !void {
        const p = &self.panes[i];
        const rh = p.view.rowHeight();
        const y = list_top + (row - p.list.top) * rh;
        try writeRow(b, self.pane_layers[i], p, row, y, w, cols, i == self.active);
        const icon = if (p.entryAt(row)) |e| lsentries.iconForEntry(e.*) else "file/folder";
        try b.drawIconOnStyled(self.pane_layers[i], y, cols.icon_col, icon, .{
            .scale = .natural,
            .h_align = .start,
            .v_align = if (rh > 1) .start else .center,
            .max_h = self.iconPx(p.view),
            .foreground = true,
        });
    }

    fn renderPane(self: *Ui, i: usize) !void {
        self.pane_dirty[i] = .none;
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
                e.view_start = try writeField(&b, layer, &e.line, 0, 1, w -| 2);
            } else {
                var pbuf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
                const shown = self.displayPath(&pbuf, p.path, w -| 2);
                try b.writeText(shown, .{ .layer = layer, .row = 0, .col = 1, .fg = fg, .bg = bg, .max_cols = w -| 2 });
            }
        }

        // Column headers, the one in force carrying the sort arrow. The
        // Size label is right-aligned in its column the way the sizes
        // under it are, so the arrow sits against the numbers.
        var head_buf: [32]u8 = undefined;
        try b.clearArea(.{ .layer = layer, .row = header_row, .rows = 1, .bg = bg_header });
        try b.writeText(headerLabel(&head_buf, "Name", p.sort, .name), .{ .layer = layer, .row = header_row, .col = cols.name_col, .fg = fg_header, .bg = bg_header });
        if (cols.size_col) |c| {
            const label = headerLabel(&head_buf, "Size", p.sort, .size);
            const pad = size_w -| gridlayout.displayWidth(label);
            try b.writeText(label, .{ .layer = layer, .row = header_row, .col = c + pad, .fg = fg_header, .bg = bg_header });
        }
        if (cols.date_col) |c| try b.writeText(headerLabel(&head_buf, "Modified", p.sort, .time), .{ .layer = layer, .row = header_row, .col = c, .fg = fg_header, .bg = bg_header });

        // Rows: text first, icons last -- a text write clears a cell's
        // foreground icon, and a tall icon spills into the row below.
        const end = @min(p.list.top + visible, p.rowCount());
        for (p.list.top..end) |row| try writeRow(&b, layer, p, row, list_top + (row - p.list.top) * rh, w, cols, active);
        // The F2 field over its row's name, before the icons for the
        // same reason the rows are.
        if (self.nameEditFor(i)) |e| {
            if (e.row >= p.list.top and e.row < end) _ = try writeField(&b, layer, &e.line, list_top + (e.row - p.list.top) * rh, cols.name_col, cols.name_w);
        }
        const icon_px = self.iconPx(p.view);
        for (p.list.top..end) |row| {
            const icon = if (p.entryAt(row)) |e| lsentries.iconForEntry(e.*) else "file/folder";
            try b.drawIconOnStyled(layer, list_top + (row - p.list.top) * rh, cols.icon_col, icon, .{
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
        const offset = p.list.top * rh;
        if (self.pushed_scroll[i][0] != extent) try b.setLayerContentExtent(layer, w, extent);
        if (self.pushed_scroll[i][0] != extent or self.pushed_scroll[i][1] != offset) try b.setLayerScrollOffset(layer, offset, 0);
        self.pushed_scroll[i] = .{ extent, offset };

        const before = self.client.bytes_sent;
        const frames_before = self.client.frames_sent;
        var sent = try b.send();
        sent.deinit();

        // What the next `.rows` repaint diffs against.
        self.drawn_cursor[i] = p.list.selected;
        self.drawn_top[i] = p.list.top;
        self.reportRedraw(i, end -| p.list.top, self.client.bytes_sent - before, self.client.frames_sent - frames_before);
    }

    /// One line per pane repaint under `GLYPHWIRE_SALA_PROFILE` -- see
    /// `Ui.profile`. Straight to stderr rather than through `std.log`
    /// so it can't be swallowed by a log-level default, and
    /// `writerStreaming` rather than `writer` because these lines are
    /// written one at a time over a whole session: the positional form
    /// starts each writer at offset 0, so redirecting the run to a file
    /// would leave nothing but the last line.
    fn reportRedraw(self: *Ui, pane: usize, rows: usize, bytes: u64, frames: u64) void {
        if (!self.profile) return;
        var buf: [160]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(self.io, &buf);
        w.interface.print(
            "sala: pane {d} redraw rows={d} bytes={d} frames={d}\n",
            .{ pane, rows, bytes, frames },
        ) catch return;
        w.interface.flush() catch {};
    }

    /// A listing row's background: the cursor highlight, or the stripe.
    /// Striped by the row's place in the listing, not by where it landed
    /// on screen, so the pattern doesn't crawl as the pane scrolls. A
    /// two-row entry is one stripe.
    ///
    /// Split out of `writeRow` because `setRowColors` needs the same answer
    /// without the text -- the two have to agree or a highlight move
    /// would leave the wrong stripe behind.
    fn rowBg(p: *const Pane, row: usize, active_pane: bool) glyphwire.Color {
        if (row == p.list.selected) return if (active_pane) bg_cursor else bg_cursor_inactive;
        return if (row % 2 == 1) bg_row_alt else bg_pane;
    }

    /// A listing row's text colours: `name` for the name column, `detail`
    /// for everything else on the row (size, date, the permissions line,
    /// the mark's `*`). The cursor row is all `list_cursor_fg`, which is
    /// what reads on a light theme's saturated cursor; a marked row is
    /// all the mark colour. Shared by `writeRow` and `setRowColors` for
    /// the same reason `rowBg` is.
    const RowFg = struct { name: glyphwire.Color, detail: glyphwire.Color };

    fn rowFg(p: *const Pane, row: usize, active_pane: bool) RowFg {
        if (row == p.list.selected) {
            const c = if (active_pane) fg_cursor else fg_cursor_inactive;
            return .{ .name = c, .detail = c };
        }
        if (p.isMarked(row)) return .{ .name = fg_marked, .detail = fg_marked };
        const name = if (p.entryAt(row)) |e| entryColor(e.*) else fg_dir;
        return .{ .name = name, .detail = fg_detail };
    }

    /// One listing row's colours and nothing else: a `set_bg` over the
    /// row's band, a `set_fg` over it in the detail colour, and one more
    /// over the name column when that differs. This is the whole point
    /// of the `.bg` dirty level: the row's text and icon are already on
    /// the host and correct, because nothing but the highlight moved --
    /// a few hundred bytes against resending the row.
    fn setRowColors(self: *Ui, b: *Batch, i: usize, row: usize, cols: Columns) !void {
        const p = &self.panes[i];
        const rh = p.view.rowHeight();
        const layer = self.pane_layers[i];
        const y = list_top + (row - p.list.top) * rh;
        const w = self.paneWidth(i);
        const fg = rowFg(p, row, i == self.active);
        try b.setBg(.{ .layer = layer, .row = y, .rows = rh, .cols = w, .bg = rowBg(p, row, i == self.active) });
        try b.setFg(.{ .layer = layer, .row = y, .rows = rh, .cols = w, .fg = fg.detail });
        if (!fg.name.eql(fg.detail)) {
            try b.setFg(.{ .layer = layer, .row = y, .col = cols.name_col, .rows = 1, .cols = cols.name_w, .fg = fg.name });
        }
    }

    fn writeRow(b: *Batch, layer: glyphwire.LayerHandle, p: *const Pane, row: usize, y: usize, w: usize, cols: Columns, active_pane: bool) !void {
        const rh = p.view.rowHeight();
        const marked = p.isMarked(row);
        const bg = rowBg(p, row, active_pane);
        try b.clearArea(.{ .layer = layer, .row = y, .rows = rh, .cols = w, .bg = bg });

        const entry = p.entryAt(row);
        const name = if (entry) |e| e.name else "..";
        const colors = rowFg(p, row, active_pane);
        const fg = colors.name;
        const detail_fg = colors.detail;

        if (marked) try b.writeText("*", .{ .layer = layer, .row = y, .col = 0, .fg = detail_fg, .bg = bg });

        var nbuf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
        const name_text = gridlayout.truncateToCols(&nbuf, name, cols.name_w);
        try b.writeText(name_text, .{ .layer = layer, .row = y, .col = cols.name_col, .fg = fg, .bg = bg });

        if (cols.size_col) |c| {
            var sbuf: [24]u8 = undefined;
            const size_text = if (entry) |e| blk: {
                if ((e.link_target_kind orelse e.kind) == .directory) break :blk "   <DIR>";
                break :blk lsfmt.formatSize(&sbuf, e.size, false);
            } else "    <UP>";
            try b.writeText(size_text, .{ .layer = layer, .row = y, .col = c, .fg = detail_fg, .bg = bg });
        }
        if (cols.date_col) |c| {
            if (entry) |e| {
                var tbuf: [20]u8 = undefined;
                try b.writeText(lsfmt.formatTimestamp(&tbuf, e.mtime_sec), .{ .layer = layer, .row = y, .col = c, .fg = detail_fg, .bg = bg });
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
                try b.writeText(line, .{ .layer = layer, .row = y + 1, .col = cols.name_col, .fg = detail_fg, .bg = bg, .max_cols = w -| (cols.name_col + 1) });
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
            try b.writeText(total, .{ .layer = layer, .row = row, .col = w - 1 - total_w, .fg = fg_detail, .bg = bg_footer });
            left_max = w -| (total_w + 3);
        }
        if (text.len > 0 and left_max > 0) {
            try b.writeText(text, .{ .layer = layer, .row = row, .col = 1, .fg = if (marked > 0) fg_marked else fg_footer, .bg = bg_footer, .max_cols = left_max });
        }
    }

    /// The bottom bar: a message if there is one, else the function keys
    /// with their current bindings (`F5 Copy`, ...), so a rebinding in the
    /// config shows up here too. While modifiers are held it shows what
    /// each F-key does under them instead, message or not (Far Manager's
    /// and Total Commander's bar), root ones in the warning colour.
    fn renderBar(self: *Ui) !void {
        self.bar_dirty = false;
        const layer = self.bar_layer;
        var b = self.client.batch();
        defer b.deinit();
        try b.clearArea(.{ .layer = layer, .bg = bg_bar });

        if (!std.meta.eql(self.held, glyphwire.Mods{})) {
            try self.writeModifiedBar(&b);
        } else if (self.message) |m| {
            try b.writeText(m, .{ .layer = layer, .row = 0, .col = 1, .fg = fg_message, .bg = bg_bar, .max_cols = self.win.cols -| 2 });
        } else {
            var col: usize = 0;
            for (actions.bar_actions) |a| {
                const chord = self.keymap.chordFor(a) orelse continue;
                var kbuf: [48]u8 = undefined;
                const key = chord.format(&kbuf);
                const label = actions.barLabel(a);
                const need = key.len + label.len + 2;
                if (col + need > self.win.cols) break;
                try b.writeText(key, .{ .layer = layer, .row = 0, .col = col, .fg = fg_bar_key, .bg = bg_bar });
                col += key.len;
                var lbuf: [32]u8 = undefined;
                const padded = std.fmt.bufPrint(&lbuf, "{s} ", .{label}) catch label;
                try b.writeText(padded, .{ .layer = layer, .row = 0, .col = col, .fg = fg_bar_label, .bg = bg_bar_label });
                col += padded.len + 1;
            }
        }
        var sent = try b.send();
        sent.deinit();
    }

    /// `renderBar` with modifiers held: `Ctrl+` (whatever is down), then
    /// `F1`..`F12` each with the action the keymap gives it under those
    /// modifiers, skipping keys that have none, then every other key
    /// bound with exactly those modifiers (`H Hidden`, `R Reread`), in
    /// binding order, each action once.
    fn writeModifiedBar(self: *Ui, b: *Batch) !void {
        const layer = self.bar_layer;
        const m = self.held;
        var pbuf: [32]u8 = undefined;
        const prefix = std.fmt.bufPrint(&pbuf, "{s}{s}{s}{s}", .{
            if (m.ctrl) "Ctrl+" else "",
            if (m.alt) "Alt+" else "",
            if (m.shift) "Shift+" else "",
            if (m.super) "Super+" else "",
        }) catch "";
        try b.writeText(prefix, .{ .layer = layer, .row = 0, .col = 0, .fg = fg_bar_key, .bg = bg_bar });
        var col: usize = prefix.len + 1;
        var shown: std.EnumSet(Action) = .empty;
        for (1..13) |n| {
            var kbuf: [4]u8 = undefined;
            const key = std.fmt.bufPrint(&kbuf, "F{d}", .{n}) catch unreachable;
            const action = self.keymap.lookup(key, m) orelse continue;
            if (!try self.writeBarEntry(b, &col, key, action)) return;
            shown.insert(action);
        }
        for (self.keymap.bindings.items) |bnd| {
            if (bnd.chord.text or !std.meta.eql(bnd.chord.mods, m) or shown.contains(bnd.action)) continue;
            var kbuf: [24]u8 = undefined;
            if (!try self.writeBarEntry(b, &col, barKeyText(&kbuf, bnd.chord.key()), bnd.action)) return;
            shown.insert(bnd.action);
        }
    }

    /// One `key label` pair of the modified bar at `col`, moving it on.
    /// False when it doesn't fit, which ends the bar.
    fn writeBarEntry(self: *Ui, b: *Batch, col: *usize, key: []const u8, action: Action) !bool {
        const layer = self.bar_layer;
        const label = actions.barLabel(action);
        const need = key.len + label.len + 2;
        if (col.* + need > self.win.cols) return false;
        try b.writeText(key, .{ .layer = layer, .row = 0, .col = col.*, .fg = fg_bar_key, .bg = bg_bar });
        col.* += key.len;
        var lbuf: [32]u8 = undefined;
        const padded = std.fmt.bufPrint(&lbuf, "{s} ", .{label}) catch label;
        const bg = if (actions.isRoot(action)) bg_dialog_danger else bg_bar_label;
        try b.writeText(padded, .{ .layer = layer, .row = 0, .col = col.*, .fg = fg_bar_label, .bg = bg });
        col.* += padded.len + 1;
        return true;
    }

    /// Names this context after the active pane's directory. Navigating
    /// or switching panes marks something dirty, so `flush` is where it
    /// gets noticed; an unchanged title sends nothing.
    fn syncTitle(self: *Ui) void {
        var path_buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
        const dir = self.displayPath(&path_buf, self.panes[self.active].path, 0);
        var next: [glyphwire.Context.max_title_len]u8 = undefined;
        const title = std.fmt.bufPrint(&next, "salacommander {s}", .{dir}) catch "salacommander";
        if (std.mem.eql(u8, title, self.title_buf[0..self.title_len])) return;
        self.client.setContextTitle(title) catch return;
        @memcpy(self.title_buf[0..title.len], title);
        self.title_len = title.len;
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

/// The F1 menu under `Ui.runModal`.
const MenuModal = struct {
    ui: *Ui,
    menu: *attrdialog.Menu,

    pub const Result = attrdialog.Menu.Pick;

    fn key(self: MenuModal, k: glyphwire.KeyEvent) !?Result {
        return self.menu.handleKey(k.key, k.mods);
    }

    fn text(_: MenuModal, _: []const u8) !?Result {
        return null;
    }

    /// The entries start on the dialog's third row.
    fn click(self: MenuModal, cell: glyphwire.CellPos, mods: glyphwire.Mods) !?Result {
        if (cell.row < 2) return null;
        return self.menu.click(cell.row - 2, mods);
    }

    fn cancelled(_: MenuModal) Result {
        return .cancel;
    }

    fn render(self: MenuModal) !void {
        try self.ui.renderMenu(self.menu);
    }
};

/// `attrdialog.ModeForm` or `.OwnerForm` under `Ui.runModal`.
fn FormModal(comptime T: type) type {
    return struct {
        const Self = @This();
        ui: *Ui,
        form: *T,

        pub const Result = attrdialog.Answer;

        fn key(self: Self, k: glyphwire.KeyEvent) !?Result {
            return self.form.handleKey(self.ui.alloc, k.key, k.mods);
        }

        fn text(self: Self, s: []const u8) !?Result {
            return self.form.handleText(self.ui.alloc, s);
        }

        fn click(self: Self, cell: glyphwire.CellPos, _: glyphwire.Mods) !?Result {
            return self.form.click(self.ui.alloc, cell.row, cell.col);
        }

        fn cancelled(_: Self) Result {
            return .cancel;
        }

        fn render(self: Self) !void {
            try self.ui.renderForm(&self.form.form);
        }
    };
}

/// A key name as the modified bar shows it, the modifiers already said
/// once in front: `one` is `1`, `grave_accent` is the backtick, and
/// anything else is spelled the way `Chord.format` does (`H`, `Up`,
/// `Page down`). Borrows `buf`.
pub fn barKeyText(buf: []u8, key: []const u8) []const u8 {
    const digits = [_][]const u8{ "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" };
    for (digits, 0..) |d, i| {
        if (std.mem.eql(u8, key, d)) return std.fmt.bufPrint(buf, "{d}", .{i}) catch key;
    }
    if (std.mem.eql(u8, key, "grave_accent")) return "`";
    const n = @min(key.len, buf.len);
    for (key[0..n], buf[0..n], 0..) |c, *out, i| {
        out.* = if (c == '_') ' ' else if (i == 0) std.ascii.toUpper(c) else c;
    }
    return buf[0..n];
}

const modifier_keys = [_][]const u8{ "left_shift", "right_shift", "left_control", "right_control", "left_alt", "right_alt", "left_super", "right_super" };

/// Whether `key` is a modifier on its own: it changes what the bar and
/// the F1 menu show, and is never a command.
fn isModifierKey(key: []const u8) bool {
    for (modifier_keys) |m| {
        if (std.mem.eql(u8, key, m)) return true;
    }
    return false;
}

/// The line under the F1 menu's entries: the focused entry's first
/// modified chord and what it runs (`Super+M  Change mode as root...`),
/// so the way to the root form is on screen. Borrows `buf`.
fn menuHint(buf: []u8, menu: *const attrdialog.Menu) []const u8 {
    if (menu.entries.len == 0) return "";
    const plain = menu.keymap.chordFor(menu.entries[menu.focus]) orelse return "";
    for (menu.keymap.bindings.items) |bnd| {
        if (std.meta.eql(bnd.chord.mods, glyphwire.Mods{})) continue;
        if (!std.ascii.eqlIgnoreCase(bnd.chord.key(), plain.key())) continue;
        var kbuf: [48]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}  {s}", .{ bnd.chord.format(&kbuf), actions.menuLabel(bnd.action) }) catch "";
    }
    return "";
}

/// `"foo.txt"` for one path, `"3 files"` for several.
fn describeSelection(alloc: std.mem.Allocator, sel: []const []const u8) ![]u8 {
    if (sel.len == 1) return std.fmt.allocPrint(alloc, "\"{s}\"", .{std.fs.path.basename(sel[0])});
    return std.fmt.allocPrint(alloc, "{d} files", .{sel.len});
}

/// A dialog title, with "sudo " in front for an operation run as root.
fn titleFor(buf: []u8, label: []const u8, as_root: bool) []const u8 {
    if (!as_root) return label;
    return std.fmt.bufPrint(buf, "sudo {s}", .{label}) catch label;
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
        error.NoTrash => "no trash on its filesystem could be used",
        error.InTrash => "it's in the trash already",
        else => @errorName(err),
    };
}

/// How much of a pane its layer owes on the next `flush`. Ordered, so
/// `markDirty` can take the larger of what is pending and what just
/// happened and never quietly downgrade a full repaint.
///
/// The split exists because a full repaint is *expensive on the wire*:
/// measured at 160x50 over a 200-entry directory it is one ~54 KB frame
/// (a `clear_area` plus a `write_text` per column per visible row plus a
/// `draw_icon` per row). That is invisible on a local socket and the
/// reason moving the cursor in a remote session lagged -- at key-repeat
/// rates it is over a megabyte a second of JSON through the ssh trunk.
/// A cursor move changes two rows, so it sends those two instead: ~2 KB.
pub const PaneDirty = enum {
    /// Nothing changed; nothing is sent.
    none,
    /// Only the *colours* of the row the cursor left and the row it
    /// landed on, plus the footer: the highlight moved and nothing else
    /// did, so their text is already right on the host. A `set_bg` and
    /// one or two `set_fg`s per row (`setRowColors`; the cursor row's
    /// text is `list_cursor_fg`), a few hundred bytes -- the cheapest a
    /// cursor move can be, and what every navigation key earns.
    bg,
    /// The row the cursor left and the row it landed on redrawn in full,
    /// plus the footer (its selection summary follows the cursor). What a
    /// mark toggle needs, since a mark changes a row's text too.
    rows,
    /// Everything: a reload, a sort, a scroll, a resize, a view switch,
    /// a mark-all, an open path field.
    full,
};

const nextCodepoint = lineedit.nextBoundary;

/// The byte offset `cells` display columns past `start` in `text` -- the
/// shared field's, re-exported because it is also what a click in the
/// Alt+D row resolves through and the tests reach for it by name.
pub const offsetAtCol = lineedit.offsetAtCol;

/// Draws a one-row text field at (`row`, `col`), `width` cells wide,
/// scrolled so the caret stays in it: the text on the input background
/// and the caret as the character under it (or a blank past the end) in
/// reverse, as a dialog's field draws it. Returns the byte the text was
/// drawn from, which a click in the field needs to find its offset.
fn writeField(b: *Batch, layer: glyphwire.LayerHandle, in: *const LineEdit, row: usize, col: usize, width: usize) !usize {
    const view = fieldView(in.text(), in.caret, width);
    try b.writeText(in.text()[view.start..], .{ .layer = layer, .row = row, .col = col, .fg = fg_dialog, .bg = bg_input, .max_cols = width, .pad = true });
    const under = if (in.caret < in.text().len) in.text()[in.caret..nextCodepoint(in.text(), in.caret)] else " ";
    try b.writeText(under, .{ .layer = layer, .row = row, .col = col + view.caret_col, .fg = bg_input, .bg = fg_dialog });
    return view.start;
}

/// Where F2 puts the caret in `name`. Shared with zoe's sidebar rename;
/// see `applib/fsops.zig`.
pub const renameCaret = @import("applib").fsops.renameCaret;

/// True when a key event is one half of a keystroke whose text arrives
/// separately on the `text` stream -- a letter, Space, a keypad digit or
/// operator -- as opposed to a command key. The F2 field lets these
/// through untouched rather than reading Space as "mark" and giving up.
pub fn typesText(key: []const u8, mods: glyphwire.Mods) bool {
    if (mods.ctrl or mods.alt or mods.super) return false;
    if ((std.unicode.utf8CountCodepoints(key) catch 0) == 1) return true;
    if (std.mem.eql(u8, key, "space")) return true;
    return std.mem.startsWith(u8, key, "kp_") and !std.mem.eql(u8, key, "kp_enter");
}

/// Which part of a text field's contents to show so the caret stays in a
/// `width`-cell field: the byte to start drawing from, and the caret's
/// column within the field.
fn fieldView(text: []const u8, caret: usize, width: usize) struct { start: usize, caret_col: usize } {
    const w = @max(width, 2);
    var start: usize = 0;
    while (start < caret and lineedit.cellWidth(text[start..caret]) >= w) {
        start = nextCodepoint(text, start);
    }
    return .{ .start = start, .caret_col = lineedit.cellWidth(text[start..caret]) };
}

/// `paths` as one clipboard line: space-separated, in the order given,
/// each entry passed through `wordsplit.quoteArgIfNeeded` so an ordinary
/// path stays bare and one with a space or a shell metacharacter comes
/// back quoted.
///
/// Byte for byte the format gw-shell's own marked-paths copy produces
/// (`Prompt.markedPathsText`), deliberately: both answer the same
/// Ctrl+Shift+C, and a user who pastes one after `zip out.zip ` must not
/// get a different kind of argument list depending on which program was
/// on screen. Caller owns the result.
pub fn pathsLine(alloc: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    for (paths, 0..) |path, i| {
        if (i > 0) try line.append(alloc, ' ');
        const tok = try wordsplit.quoteArgIfNeeded(alloc, path);
        defer alloc.free(tok);
        try line.appendSlice(alloc, tok);
    }
    return line.toOwnedSlice(alloc);
}

/// Where an F3 result sends the pane: the directory to list and, for a
/// file, the name to put the cursor on. `dir` and `name` borrow `buf`.
pub const FindTarget = struct {
    buf: []u8,
    dir: []const u8,
    /// Null for a directory result, which is entered rather than shown.
    name: ?[]const u8,

    pub fn deinit(self: FindTarget, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }
};

/// Resolves a finder result (`rel`, relative to `root`, a directory with
/// the trailing `/` the finder gives it) into a `FindTarget`.
pub fn findTarget(alloc: std.mem.Allocator, root: []const u8, rel: []const u8) !FindTarget {
    const is_dir = std.mem.endsWith(u8, rel, "/");
    const body = if (is_dir) rel[0 .. rel.len - 1] else rel;
    const full = try std.fs.path.join(alloc, &.{ root, body });
    if (is_dir) return .{ .buf = full, .dir = full, .name = null };
    return .{
        .buf = full,
        .dir = std.fs.path.dirname(full) orelse "/",
        .name = std.fs.path.basename(full),
    };
}
