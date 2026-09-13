// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-read's glyphwire client: a full-screen reader for one book.
//!
//! **Layout.** Three free-floating layers in a dedicated context, placed
//! by `set_property(cell_position)` rather than by a split tree. zoe uses
//! splits because its panes tile; this doesn't, because a fitted page has
//! to be *centred* in whatever space is left over, and a split tree only
//! knows how to fill.
//!
//!   - `page_layer` -- exactly as big as the scaled page (zoom.zig), which
//!     is bigger than the window whenever you're zoomed in. The window is
//!     its viewport, and panning is `set_property(scroll_offset)`. That's
//!     also what makes the host route the wheel and draw the scrollbars
//!     for free: `scrollablePaneAt` matches any layer with slack.
//!   - `status_layer` -- one row across the bottom.
//!   - `help_layer` -- the `?` overlay, hidden until asked for.
//!
//! **Page turning is direction-aware.** Manga reads right-to-left, so by
//! default Left is *forward*. `Direction` (config.zig) flips that, `d`
//! toggles it at runtime, and the choice is remembered per book.
//!
//! **The OCR overlay.** A book that came with a mokuro sidecar
//! (archive.zig finds it, mokuro.zig parses it) gets a fourth layer: a
//! floating dialog showing one speech bubble's text, opened by clicking
//! the bubble on the page or walked with `Tab`. Two things make it worth
//! having next to the page rather than instead of it -- the text is
//! *selectable* (the host's copy shortcut finds a selection on any
//! layer), and it gets out of the way on demand, because mokuro drops
//! furigana often enough that checking the artwork is part of reading:
//! hold `z` to fade the dialog to `ocr_peek`, or `\` to hide it outright.
//!
//! **The arrow keys do two jobs.** When the page overflows an axis they
//! pan it; when it doesn't there's nothing to pan, so the horizontal pair
//! turns the page instead. That's the rule every comic reader uses and it
//! is never ambiguous, because "does this axis overflow" is exactly what
//! `Layout.max_pan_*` reports. `hjkl` always pans and `space` /
//! `backspace` always turn, for anyone who wants the unambiguous form.

const std = @import("std");
const glyphwire = @import("glyphwire");

const archive_mod = @import("archive.zig");
const cache_mod = @import("cache.zig");
const config_mod = @import("config.zig");
const mokuro = @import("mokuro.zig");
const dict_mod = @import("dict.zig");
const state_mod = @import("state.zig");
const zoom = @import("zoom.zig");

const Direction = config_mod.Direction;

/// Rows the statusline occupies at the bottom of the window. The page
/// gets everything above it.
const status_rows: usize = 1;

/// Colors. Deliberately few: a reader is a picture on a background, and
/// anything else competing for attention is noise.
const bg_page = glyphwire.Color{ .r = 12, .g = 12, .b = 14 };
const bg_status = glyphwire.Color{ .r = 28, .g = 28, .b = 34 };
const fg_status = glyphwire.Color{ .r = 190, .g = 190, .b = 200 };
const fg_dim = glyphwire.Color{ .r = 120, .g = 120, .b = 132 };
const fg_warn = glyphwire.Color{ .r = 230, .g = 170, .b = 90 };
/// The OCR dialog: a near-black panel so Japanese at cell size stays
/// legible over whatever artwork it lands on, and a warm border that
/// reads as "this is not part of the page".
const bg_dialog = glyphwire.Color{ .r = 20, .g = 20, .b = 26 };
const fg_dialog = glyphwire.Color{ .r = 232, .g = 232, .b = 238 };
/// The panel's drawn border. Dimmer than its text so the frame reads as
/// chrome rather than competing with the Japanese inside it.
const fg_dialog_border = glyphwire.Color{ .r = 150, .g = 150, .b = 165 };
/// The lookup panel's term/reading line -- same warm highlight as the
/// current OCR block's outline, so the two feel like one interaction.
const fg_lookup_term = glyphwire.Color{ .r = 250, .g = 205, .b = 90 };
/// The region hints drawn over the page (`o`). Written with a transparent
/// background so the artwork still shows around the box glyphs.
const fg_hint = glyphwire.Color{ .r = 120, .g = 200, .b = 235 };
/// The block currently in the dialog, outlined whether hints are on or
/// not -- it is the answer to "which bubble am I reading".
const fg_hint_current = glyphwire.Color{ .r = 250, .g = 205, .b = 90 };

/// Everything the mokuro overlay needs, present only for a book that
/// came with OCR (`archive.Archive.mokuro`) and `ocr` left on in the
/// config.
const Ocr = struct {
    volume: mokuro.Volume,
    /// The current page's OCR, re-resolved on every page turn. Null for a
    /// page the sidecar has no entry for -- a common enough case (a cover
    /// scanned in later, a bonus page) that it is not an error.
    page: ?*const mokuro.Page = null,
    /// `page.blocks` indices in reading order (mokuro.readingOrder), which
    /// is what `Tab` walks. Rebuilt per page and when the direction flips.
    order: std.ArrayList(usize) = .empty,
    /// Where in `order` the open dialog sits. Null means no dialog.
    at: ?usize = null,
    /// The `o` toggle: outline every region on the page.
    hints: bool = false,
    /// `\` -- the dialog is hidden outright until toggled back.
    hidden: bool = false,
    /// `z` is held: the dialog is faded to `conf.ocr_peek`. Separate from
    /// `hidden` so releasing the key restores the right state.
    peeking: bool = false,
    /// The dialog's on-screen rect in window cells, from the last render.
    /// A press inside it starts a text selection instead of a page pan.
    rect: struct { row: usize = 0, col: usize = 0, rows: usize = 0, cols: usize = 0 } = .{},
    /// The text the last `renderDialog` drew: the joined-and-rewrapped
    /// source and the rows it wrapped to. `rows` are slices *into*
    /// `joined`. Kept so a stationary click on the panel (`Ui.wordLookupAt`)
    /// can turn its row/column back into source text without redoing the
    /// join/wrap `renderDialog` already did.
    text: struct { joined: []u8 = &.{}, rows: []const []const u8 = &.{} } = .{},

    /// The block the dialog is showing, or null.
    fn current(self: *const Ocr) ?*const mokuro.Block {
        const page = self.page orelse return null;
        const at = self.at orelse return null;
        if (at >= self.order.items.len) return null;
        return &page.blocks[self.order.items[at]];
    }

    fn freeText(self: *Ocr, alloc: std.mem.Allocator) void {
        if (self.text.joined.len > 0) alloc.free(self.text.joined);
        if (self.text.rows.len > 0) alloc.free(self.text.rows);
        self.text = .{};
    }

    fn deinit(self: *Ocr, alloc: std.mem.Allocator) void {
        self.freeText(alloc);
        self.order.deinit(alloc);
        self.volume.deinit();
    }
};

/// A dictionary lookup result shown in `Ui.dict_layer`. `dict_mod.lookup`
/// now queries a SQLite file rather than holding the whole dictionary in
/// memory, so its `Entry` results are heap-allocated per call -- `term`,
/// `reading` and `glossary` here are owned (by `Ui.alloc`) and must be
/// freed, which `Ui.clearLookup` does before every replacement and on
/// shutdown. `reason` is never owned: it's one of `dict_mod.deinflect_rules`'s
/// static strings.
const Lookup = struct {
    term: []const u8,
    reading: []const u8,
    glossary: []const []const u8,
    /// The deinflection reason, or null for a direct dictionary-form
    /// match.
    reason: ?[]const u8,
    /// How many other entries also matched this term and aren't shown --
    /// homographs the dialog picks the first of rather than listing.
    extra: usize,
    rect: struct { row: usize = 0, col: usize = 0, rows: usize = 0, cols: usize = 0 } = .{},
};

pub const Ui = struct {
    alloc: std.mem.Allocator,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,

    book: *archive_mod.Archive,
    conf: config_mod.ReadConfig,
    cache: cache_mod.Cache,

    context: glyphwire.ContextHandle,
    page_layer: glyphwire.LayerHandle,
    /// The OCR region marks. Geometry mirrors `page_layer` exactly -- same
    /// size, viewport, placement and scroll offset -- so the marks pan
    /// with the artwork. Its own layer rather than glyphs written into the
    /// page because moving one mark would otherwise mean redrawing the
    /// whole scaled page (`draw_image` has no source offset, so there is
    /// no way to repaint just the cells a mark covered).
    hint_layer: glyphwire.LayerHandle,
    status_layer: glyphwire.LayerHandle,
    help_layer: glyphwire.LayerHandle,
    /// The mokuro text panel. Created for every session (a layer costs
    /// nothing while hidden) but only ever shown when `ocr` is set.
    dialog_layer: glyphwire.LayerHandle,
    /// The dictionary lookup panel. Same story as `dialog_layer`: created
    /// unconditionally, only ever shown when `conf.dictionary` loaded.
    dict_layer: glyphwire.LayerHandle,
    /// The "building dictionary index..." progress panel, shown only
    /// while `dict_build` is set -- i.e. only the first time a given
    /// dictionary directory is opened. Same "created unconditionally,
    /// costs nothing hidden" story as the other overlay layers.
    dict_build_layer: glyphwire.LayerHandle,

    /// Window size in cells, from `resize`, and the session's cell
    /// metrics. Both are re-read on every resize: a Ctrl+`+` font step
    /// changes the metrics *and* reflows the grid, so one notification
    /// covers both.
    win: struct { cols: usize, rows: usize },
    cell: zoom.Size,

    page: usize = 0,
    mode: zoom.Mode,
    direction: Direction,
    /// The `.free` mode's factor. Seeded from whatever the last fit
    /// resolved to so the first `+` zooms in from what's on screen rather
    /// than jumping to 1:1 first.
    free_scale: f32 = 1.0,
    /// Pan offset in cells, i.e. the page layer's `scroll_offset`.
    pan: struct { row: usize = 0, col: usize = 0 } = .{},
    /// The layout the current frame drew, so key handlers can ask "does
    /// this axis overflow" without recomputing it.
    layout: zoom.Layout = .{ .scale = 1, .cols = 1, .rows = 1, .col = 0, .row = 0, .max_pan_col = 0, .max_pan_row = 0 },

    /// The current page image's real pixel dimensions, from `getImageInfo`
    /// via the cache. The OCR boxes are in whatever dimensions *mokuro*
    /// ran against, which is not always the same thing (a volume
    /// re-encoded after being OCR'd), so mapping a box onto the page goes
    /// through the ratio between the two -- see `ocrScale`.
    page_px: zoom.Size = .{ .w = 0, .h = 0 },

    /// Set by `goToPage` and consumed by `renderPage`: the pan can only
    /// be put at the new page's reading edge once its overflow is known,
    /// which is after its dimensions have been fetched.
    pan_to_reading_edge: bool = false,

    /// A left-button drag over the page: where it started, in cells, and
    /// the pan offset it started from. Null when no button is down.
    drag: ?struct { cell: glyphwire.CellPos, pan_row: usize, pan_col: usize, moved: bool } = null,

    /// A left-button drag *inside the OCR dialog*, which selects its text
    /// rather than panning the page. Held separately from `drag` because
    /// the two are decided at press time and never both live. `active` is
    /// wherever the drag currently is -- kept so mouse-up can hand the
    /// whole span to `lookupSelection` without the host round-tripping it
    /// back first.
    text_drag: ?struct { anchor: glyphwire.SelectionPoint, active: glyphwire.SelectionPoint, moved: bool } = null,

    /// The book's mokuro OCR, when it has any. See `Ocr`.
    ocr: ?Ocr = null,
    dialog_dirty: bool = false,
    hints_dirty: bool = false,

    /// The loaded dictionary, when `conf.dictionary` named one and it
    /// parsed. Null -- the common case for now -- leaves a click on the
    /// OCR dialog doing nothing but clearing its selection, same as
    /// before this feature existed.
    dict: ?dict_mod.Dict = null,
    /// The last word looked up, shown in `dict_layer`. See `Lookup`.
    lookup: ?Lookup = null,
    lookup_dirty: bool = false,

    /// Set for as long as `conf.dictionary` is being indexed for the
    /// first time -- `run` steps it one `term_bank_*.json` file per tick
    /// rather than blocking on `dict_mod.loadFromDir` up front, so the
    /// reader stays responsive and `dict_build_layer` can show progress.
    /// Null once the build finishes (or never started, because the
    /// directory was already indexed).
    dict_build: ?dict_mod.Builder = null,
    dict_build_dirty: bool = false,

    /// The `g` prefix (as in `gg`) and the `:` goto-page prompt. Only one
    /// can be pending at a time, which is why they share a field.
    pending: union(enum) { none, goto_prefix, goto_prompt: std.ArrayList(u8) } = .none,

    help_visible: bool = false,
    quit: bool = false,
    page_dirty: bool = true,
    status_dirty: bool = true,
    /// The root-layer fill behind everything. Only redrawn on a resize --
    /// nothing else can uncover it.
    backdrop_dirty: bool = true,
    /// A transient message shown in place of the page name -- a failed
    /// load, an out-of-range jump. Owned, cleared on the next keystroke.
    message: ?[]u8 = null,

    pub fn init(
        alloc: std.mem.Allocator,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        book: *archive_mod.Archive,
        conf: config_mod.ReadConfig,
        start: struct { page: usize, mode: zoom.Mode, direction: Direction },
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        // A dedicated context, shown immediately -- from here on every
        // layer call on `client` targets it, not the shell's. No window
        // scrollbar: the reader's root holds no scrollback, and the page
        // layer draws its own bars when it has something to scroll.
        const context = try client.createContext(null, null, 0, false);
        errdefer client.destroyContext(context) catch {};
        try listener.attachContext(context);

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        // Provisional sizes: `applyLayout` resizes the page layer on the
        // first frame, and every resize after.
        const page_layer = try client.createLayer(size.cols, size.rows, 0);
        // Right after the page: `layer_order` is creation order, so this
        // composites over the artwork and under the statusline.
        // 1x1 until `renderPage` sizes it: a book with no OCR never grows
        // it past that, and a book with OCR resizes it every frame the
        // page layout moves anyway.
        const hint_layer = try client.createLayer(1, 1, 0);
        const status_layer = try client.createLayer(size.cols, status_rows, 0);
        const help_layer = try client.createLayer(help_cols, help_rows, 0);
        // Created last so it composites above the page and the help box:
        // `layer_order` is creation order and the dialog is the topmost
        // thing on screen when it is up.
        const dialog_layer = try client.createLayer(conf.ocr_dialog_cols, 3, 0);
        // Created after the dialog, so a lookup panel composites above it
        // -- it's answering a click made *on* the dialog.
        const dict_layer = try client.createLayer(conf.ocr_dialog_cols, 3, 0);
        // Created last: whenever it's up, nothing else should be able to
        // cover it. 1x1 until `renderDictBuild` sizes it, same as
        // `hint_layer` -- most sessions never touch a dictionary at all,
        // let alone one that still needs building.
        const dict_build_layer = try client.createLayer(1, 1, 0);

        try client.setLayerVisible(help_layer, false);
        try client.setLayerVisible(dialog_layer, false);
        try client.setLayerVisible(dict_layer, false);
        try client.setLayerVisible(dict_build_layer, false);
        try client.setLayerVisible(hint_layer, false);

        self.* = .{
            .alloc = alloc,
            .client = client,
            .listener = listener,
            .book = book,
            .conf = conf,
            .cache = .init(conf.cache_pages),
            .context = context,
            .page_layer = page_layer,
            .hint_layer = hint_layer,
            .status_layer = status_layer,
            .help_layer = help_layer,
            .dialog_layer = dialog_layer,
            .dict_layer = dict_layer,
            .dict_build_layer = dict_build_layer,
            .win = .{ .cols = size.cols, .rows = size.rows },
            .cell = .{ .w = metrics.w, .h = metrics.h },
            .page = @min(start.page, book.count() -| 1),
            .mode = start.mode,
            .direction = start.direction,
        };

        // After `self.*` is populated: the load reads `self.conf` and
        // records its outcome on `self.ocr`. A book with no sidecar, or a
        // sidecar that won't parse, just leaves `ocr` null -- the reader
        // opens exactly as it did before this feature existed.
        if (conf.ocr) self.loadOcr();
        self.loadDict();

        return self;
    }

    /// Opens `conf.dictionary`, if one is set. Best effort, the same
    /// policy `loadOcr` follows: a missing directory or a bank that
    /// parses to nothing just leaves `dict` null and word lookup off,
    /// because a book you can still read without a dictionary is not a
    /// book that should refuse to open.
    ///
    /// If the directory hasn't been indexed yet, this does *not* block
    /// on the build -- it starts `self.dict_build` and returns, so `run`
    /// can step it one file at a time behind a progress panel instead of
    /// freezing the reader for however long indexing a real dictionary
    /// takes.
    fn loadDict(self: *Ui) void {
        if (self.conf.dictionary.len == 0) return;
        const load = dict_mod.openOrBeginBuild(self.alloc, self.client.io, self.conf.dictionary) catch |err| {
            std.log.warn("gw-read: couldn't load dictionary '{s}' ({t}); lookup off", .{ self.conf.dictionary, err });
            return;
        };
        switch (load) {
            .ready => |d| self.finishDictLoad(d),
            .building => |b| {
                self.dict_build = b;
                self.dict_build_dirty = true;
            },
        }
    }

    /// Common tail of `loadDict`'s fast path and `run`'s "a build just
    /// finished" path: an empty dictionary (nothing parsed to anything)
    /// is treated the same as no dictionary at all.
    fn finishDictLoad(self: *Ui, dict_in: dict_mod.Dict) void {
        var d = dict_in;
        if (dict_mod.isEmpty(&d)) {
            d.deinit();
            std.log.warn("gw-read: dictionary '{s}' has no term bank entries; lookup off", .{self.conf.dictionary});
            return;
        }
        self.dict = d;
    }

    /// Reads and parses the book's mokuro sidecar, if it has one. Best
    /// effort throughout: a read error or an unparseable file is logged
    /// and the feature stays off, because a book you can still read
    /// without OCR is not a book that should refuse to open.
    fn loadOcr(self: *Ui) void {
        if (!self.book.hasMokuro()) return;
        const bytes = self.book.readMokuro(self.alloc) catch |err| {
            std.log.warn("gw-read: couldn't read the mokuro sidecar ({t}); OCR off", .{err});
            return;
        } orelse return;
        defer self.alloc.free(bytes);

        var volume = mokuro.parse(self.alloc, bytes) catch return;
        if (volume.pages.len == 0) {
            volume.deinit();
            std.log.warn("gw-read: the mokuro sidecar has no pages; OCR off", .{});
            return;
        }
        // A sidecar whose `img_path`s match none of this book's pages is
        // almost always the wrong volume's, dropped in beside the right
        // one. It still "works" -- every page just silently has no text --
        // so say so rather than leaving the reader to wonder why `Tab`
        // never does anything.
        if (volume.pagesWithText() > 0 and !self.anyPageMatches(&volume)) {
            std.log.warn(
                "gw-read: the mokuro sidecar names none of this book's pages; is it the right volume's?",
                .{},
            );
        }

        self.ocr = .{ .volume = volume, .hints = self.conf.ocr_hints };
        self.syncOcrPage();
    }

    /// Whether any of the book's pages resolves to an OCR page. Stops at
    /// the first hit, so the usual case costs one lookup.
    fn anyPageMatches(self: *const Ui, volume: *const mokuro.Volume) bool {
        for (self.book.pages.items) |p| {
            if (volume.pageFor(p.name)) |ocr_page| {
                if (ocr_page.blocks.len > 0) return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *Ui) void {
        // A local copy, not `self.alloc`: `self` is destroyed at the end
        // of this function, and a `defer` that reaches back through it
        // would be reading freed memory by the time it runs.
        const alloc = self.alloc;

        // Hand every cached page's bytes back before the connection goes:
        // the server reclaims them anyway once this connection closes,
        // but a reader launched inside a long-lived shell session has
        // scrollback that could pin them until it scrolls away.
        var drained: std.ArrayList(cache_mod.Entry) = .empty;
        defer drained.deinit(alloc);
        self.cache.drain(alloc, &drained) catch {};
        for (drained.items) |e| self.client.destroyImage(e.handle) catch {};
        self.cache.deinit(alloc);

        if (self.ocr) |*o| o.deinit(alloc);
        self.clearLookup();
        if (self.dict) |*d| d.deinit();
        // A quit mid-build: abandon it rather than let it finish
        // unobserved -- there is no reader left to hand the result to.
        if (self.dict_build) |*b| b.deinit();
        if (self.message) |m| alloc.free(m);
        switch (self.pending) {
            .goto_prompt => |*buf| buf.deinit(alloc),
            else => {},
        }
        self.client.destroyContext(self.context) catch {};
        alloc.destroy(self);
    }

    /// Where the reader currently is, for the resume state file.
    pub fn bookmark(self: *const Ui) state_mod.Bookmark {
        return .{
            .page = self.page,
            .mode = @tagName(self.mode),
            .direction = self.direction.name(),
        };
    }

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            try self.drainEvents();
            // One term bank file per tick rather than looping to
            // completion here: `waitInputEvent`'s 20ms timeout below
            // keeps ticks coming even with no input, so this still
            // finishes promptly, but the reader stays responsive (and
            // `renderDictBuild` gets to actually show a frame) the whole
            // time a real dictionary is being indexed.
            if (self.dict_build) |*b| {
                self.dict_build_dirty = true;
                if (b.isDone()) {
                    if (b.finish()) |d| {
                        self.finishDictLoad(d);
                    } else |err| {
                        std.log.warn("gw-read: building dictionary '{s}' failed ({t}); lookup off", .{ self.conf.dictionary, err });
                    }
                    self.dict_build = null;
                } else if (b.step()) |_| {} else |err| {
                    std.log.warn("gw-read: building dictionary '{s}' failed ({t}); lookup off", .{ self.conf.dictionary, err });
                    b.deinit();
                    self.dict_build = null;
                }
            }
            if (self.backdrop_dirty) {
                self.backdrop_dirty = false;
                try self.renderBackdrop();
            }
            if (self.page_dirty) try self.renderPage();
            // Both after the page: `renderPage` recomputes the layout the
            // marks and the dialog are placed against, and marks them
            // dirty when it does.
            if (self.hints_dirty) try self.renderHints();
            if (self.dialog_dirty) try self.renderDialog();
            if (self.lookup_dirty) try self.renderLookup();
            if (self.dict_build_dirty) try self.renderDictBuild();
            if (self.status_dirty) try self.renderStatus();
            if (self.quit) break;

            // Block rather than spin; the timeout is only so the other
            // queues (resize, mouse, scroll) get looked at. The waiting
            // form *consumes* what it waited for, so it's handled here --
            // `drainEvents` will never see it.
            if (self.listener.waitInputEvent(.{
                .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake },
            }) catch null) |ev| {
                defer ev.deinit(self.alloc);
                try self.handleInput(ev);
            }
        }
    }

    fn drainEvents(self: *Ui) !void {
        while (self.listener.pollResizeEvent()) |ev| {
            self.win = .{ .cols = ev.cols, .rows = ev.rows };
            // A font-size step reflows the grid *and* changes the cell
            // metrics, and arrives as one resize -- so re-read them here
            // rather than only at startup.
            if (self.client.getCellMetrics()) |m| {
                self.cell = .{ .w = m.w, .h = m.h };
            } else |_| {}
            self.backdrop_dirty = true;
            self.page_dirty = true;
            self.status_dirty = true;
        }
        while (self.listener.pollScrollOffsetEvent()) |ev| {
            // The wheel or a scrollbar thumb over the page: the host has
            // already moved the viewport and is telling us where it
            // landed. Follow it rather than pushing our own value back --
            // but the *other* layer still has to be told, since the host
            // only moved the one under the pointer. That can be the marks
            // layer: it covers the page exactly and, while visible, is the
            // topmost thing `scrollablePaneAt` finds there.
            if (ev.layer == self.page_layer or ev.layer == self.hint_layer) {
                self.pan = .{ .row = ev.row, .col = ev.col };
                const other = if (ev.layer == self.page_layer) self.hint_layer else self.page_layer;
                self.client.setLayerScrollOffset(other, ev.row, ev.col) catch {};
                self.status_dirty = true;
            }
        }
        while (self.listener.pollMouseMoveEvent()) |ev| {
            try self.handleMouseMove(ev);
        }
        while (self.listener.pollMouseButtonEvent()) |ev| {
            defer ev.deinit(self.alloc);
            try self.handleMouseButton(ev);
        }
        while (self.listener.pollInputEvent()) |ev| {
            defer ev.deinit(self.alloc);
            try self.handleInput(ev);
        }
    }

    // ── Paging ──────────────────────────────────────────────────────────

    /// Moves `delta` pages in *reading* order (positive is forward, which
    /// is leftward in `rtl`). Clamps at both ends rather than wrapping --
    /// a reader that jumps from the last page back to the cover on one
    /// extra keypress has lost your place.
    fn stepPage(self: *Ui, delta: i64) void {
        const last = self.book.count() -| 1;
        const target: usize = if (delta < 0)
            self.page -| @as(usize, @intCast(-delta))
        else
            @min(self.page + @as(usize, @intCast(delta)), last);
        self.goToPage(target);
    }

    fn goToPage(self: *Ui, page: usize) void {
        const clamped = @min(page, self.book.count() -| 1);
        if (clamped == self.page) {
            self.status_dirty = true;
            return;
        }
        self.page = clamped;
        // A new page starts at its top-left in reading order: the top
        // *right* corner for manga, which is where the first panel is.
        self.pan = .{ .row = 0, .col = 0 };
        self.pan_to_reading_edge = true;
        self.page_dirty = true;
        self.status_dirty = true;
        self.syncOcrPage();
    }

    // -- OCR ------------------------------------------------------------

    /// Points the overlay at the current page's OCR and rebuilds its
    /// reading order. Closes any open dialog: the block it was showing
    /// belonged to the page you just left.
    fn syncOcrPage(self: *Ui) void {
        const o = &(self.ocr orelse return);
        const name = self.book.pages.items[@min(self.page, self.book.count() -| 1)].name;
        o.page = o.volume.pageFor(name);
        self.rebuildOcrOrder();
        self.closeDialog();
    }

    /// Refills `ocr.order` from the current page. Also called when `d`
    /// flips the reading direction, which reverses what `Tab` walks.
    fn rebuildOcrOrder(self: *Ui) void {
        const o = &(self.ocr orelse return);
        o.order.clearRetainingCapacity();
        const page = o.page orelse return;
        if (page.blocks.len == 0) return;
        o.order.ensureTotalCapacity(self.alloc, page.blocks.len) catch return;
        o.order.items.len = page.blocks.len;

        // The band scratch `readingOrder` needs, one entry per block. A
        // page with more bubbles than the buffer holds falls back to the
        // file order rather than to no order: the allocation is a few
        // hundred bytes and failing it should not cost the whole overlay.
        const bands = self.alloc.alloc(u32, page.blocks.len) catch {
            for (o.order.items, 0..) |*slot, i| slot.* = i;
            return;
        };
        defer self.alloc.free(bands);

        _ = mokuro.readingOrder(page, switch (self.direction) {
            .rtl => .rtl,
            .ltr => .ltr,
        }, o.order.items, bands);
    }

    /// Opens the dialog on position `at` in reading order, clamped.
    fn showBlock(self: *Ui, at: usize) void {
        const o = &(self.ocr orelse return);
        if (o.order.items.len == 0) return;
        const next = @min(at, o.order.items.len - 1);

        // A selection belongs to the text that was on the panel, and
        // `clear` doesn't drop one -- `core.Layer.clear` resets cells and
        // leaves `Layer.selection` alone, so without this the old tint
        // would sit over the *new* bubble's text at the old coordinates,
        // and the copy shortcut would copy whatever now lies under it.
        if (o.at != next) {
            self.text_drag = null;
            self.client.clearSelection(self.dialog_layer) catch {};
            // A lookup belongs to the bubble it was clicked in; stepping
            // to a different one leaves it looking like the wrong word.
            self.clearLookup();
        }

        o.at = next;
        o.hidden = false;
        self.dialog_dirty = true;
        // The current block is marked whether the hints are on or not, so
        // the marks move with it -- but only the marks: they have their
        // own layer precisely so stepping through a page's bubbles doesn't
        // redraw the scaled page once per `Tab`.
        self.hints_dirty = true;
        self.status_dirty = true;
    }

    /// Walks `delta` blocks in reading order, opening the dialog if it
    /// wasn't already. Clamps at both ends rather than wrapping, the same
    /// call `stepPage` makes: `Tab` past the last bubble should sit on the
    /// last bubble, not silently jump back to the first.
    fn stepBlock(self: *Ui, delta: i64) void {
        const o = &(self.ocr orelse return);
        if (o.order.items.len == 0) {
            self.setMessage("no OCR text on this page", .{}) catch {};
            self.status_dirty = true;
            return;
        }
        const last = o.order.items.len - 1;
        const at: usize = if (o.at) |cur|
            (if (delta < 0) cur -| @as(usize, @intCast(-delta)) else @min(cur + @as(usize, @intCast(delta)), last))
        else
            // The first `Tab` on a page opens the first bubble in reading
            // order regardless of direction; Shift+Tab opens the last.
            (if (delta < 0) last else 0);
        self.showBlock(at);
    }

    fn closeDialog(self: *Ui) void {
        const o = &(self.ocr orelse return);
        if (o.at == null) return;
        o.at = null;
        o.peeking = false;
        o.hidden = false;
        self.text_drag = null;
        self.client.clearSelection(self.dialog_layer) catch {};
        self.client.setLayerVisible(self.dialog_layer, false) catch {};
        self.client.setLayerOpacity(self.dialog_layer, 1.0) catch {};
        self.clearLookup();
        self.hints_dirty = true;
        self.status_dirty = true;
    }

    /// Ensures page `index` is loaded server-side and returns its cache
    /// entry. The bytes are read from the archive, handed to
    /// `load_image`, and freed again immediately -- the server owns the
    /// only copy from then on, and the LRU owns the handle.
    fn ensureLoaded(self: *Ui, index: usize) !cache_mod.Entry {
        if (self.cache.get(index)) |e| return e;

        const bytes = try self.book.readPage(self.alloc, index);
        defer self.alloc.free(bytes);

        const format = glyphwire.detectImageFormat(bytes) orelse return error.UnsupportedImageFormat;
        const handle = try self.client.loadImage(format.name(), bytes);
        errdefer self.client.destroyImage(handle) catch {};
        const info = try self.client.getImageInfo(handle);

        const entry: cache_mod.Entry = .{
            .page = index,
            .handle = handle,
            .width = info.width,
            .height = info.height,
        };
        if (try self.cache.put(self.alloc, entry)) |evicted| {
            self.client.destroyImage(evicted.handle) catch {};
        }
        return entry;
    }

    /// Loads the next `conf.prefetch` pages in reading order if they
    /// aren't resident, so the page turn itself doesn't wait on a read.
    /// Failures are silent: a prefetch that can't load is only a missed
    /// optimisation, and the real load will report the error properly.
    fn prefetch(self: *Ui) void {
        var i: usize = 1;
        while (i <= self.conf.prefetch) : (i += 1) {
            const next = self.page + i;
            if (next >= self.book.count()) return;
            if (self.cache.contains(next)) continue;
            _ = self.ensureLoaded(next) catch return;
        }
    }

    // ── Rendering ───────────────────────────────────────────────────────

    /// The window area the page gets: everything above the statusline.
    fn pageView(self: *const Ui) zoom.View {
        return .{ .cols = self.win.cols, .rows = self.win.rows -| status_rows };
    }

    /// Fills the context's root layer with the page background.
    ///
    /// A fitted page is *smaller* than the window on at least one axis,
    /// and the page layer is exactly the page's size -- so without this
    /// the letterbox around it is transparent and the shell's scrollback
    /// shows through, which is the same trap zoe's sidebar fell into.
    /// `clear` resets to the default style rather than a chosen colour,
    /// so the fill is rows of spaces; one batch keeps it to a single
    /// round trip per resize rather than one per row.
    fn renderBackdrop(self: *Ui) !void {
        if (self.win.cols == 0 or self.win.rows == 0) return;

        const blanks = try self.alloc.alloc(u8, self.win.cols);
        defer self.alloc.free(blanks);
        @memset(blanks, ' ');

        var b = self.client.batch();
        defer b.deinit();
        var row: usize = 0;
        while (row < self.win.rows) : (row += 1) {
            try b.setCursor(row, 0);
            try b.writeText(blanks, null, bg_page);
        }
        var results = try b.send();
        results.deinit();
    }

    fn renderPage(self: *Ui) !void {
        self.page_dirty = false;

        const entry = self.ensureLoaded(self.page) catch |err| {
            try self.setMessage("page {d} failed to load ({t})", .{ self.page + 1, err });
            self.status_dirty = true;
            return;
        };

        self.page_px = .{ .w = entry.width, .h = entry.height };
        const view = self.pageView();
        self.layout = zoom.layout(
            self.mode,
            self.free_scale,
            .{ .w = entry.width, .h = entry.height },
            .{ .cols = view.cols, .rows = view.rows },
            self.cell,
            self.conf.limits(),
        );
        // Keep `free_scale` tracking whatever is on screen, so switching
        // to `.free` with `+` continues from the current size.
        if (self.mode != .free) self.free_scale = self.layout.scale;

        if (self.pan_to_reading_edge) {
            self.pan_to_reading_edge = false;
            // Manga starts at the page's right edge; a left-to-right book
            // at its left. Vertically both start at the top.
            self.pan.col = switch (self.direction) {
                .rtl => self.layout.max_pan_col,
                .ltr => 0,
            };
            self.pan.row = 0;
        }
        self.clampPan();

        const c = self.client;
        try c.setLayerSize(self.page_layer, self.layout.cols, self.layout.rows);
        // The window is the layer's window onto its own, larger grid --
        // the host-scrolled model, the one zoe's *tree* pane uses.
        //
        // Deliberately **no `content_extent`**. That property switches a
        // layer into the client-scrolled model zoe's *buffer* pane uses:
        // the host then moves a virtual `content_off` and broadcasts a
        // `scroll_offset` for the client to repaint against, and the real
        // `scroll_off` the renderer reads never moves -- the scrollbar
        // slides and the picture sits still. It isn't needed for the
        // scrollbars either: `maxScroll` falls back to the real grid, so
        // a grid bigger than the viewport already reports slack, which is
        // what turns the bars and the wheel on.
        try c.setLayerViewport(self.page_layer, @min(self.layout.cols, view.cols), @min(self.layout.rows, view.rows));
        try c.setLayerScrollbars(self.page_layer, self.layout.max_pan_row > 0, self.layout.max_pan_col > 0);
        try c.setLayerCellPosition(self.page_layer, self.layout.row, self.layout.col);

        // Wipe first: a page narrower than the last one would otherwise
        // leave the previous page's right-hand columns behind.
        try c.clearOn(self.page_layer, 0, 0, null, null);
        try c.drawImageOn(
            self.page_layer,
            entry.handle,
            0,
            0,
            self.layout.rows,
            self.layout.cols,
            self.layout.scale,
        );
        try c.setLayerScrollOffset(self.page_layer, self.pan.row, self.pan.col);

        // The marks layer sits exactly on top of the page, so every piece
        // of the geometry just computed applies to it too. Only for a book
        // that has OCR: the layer is the size of the *whole scaled page*,
        // which at 4x is a few hundred thousand server-side cells, and a
        // book with no sidecar will never write one of them.
        if (self.ocr != null) {
            try c.setLayerSize(self.hint_layer, self.layout.cols, self.layout.rows);
            try c.setLayerViewport(self.hint_layer, @min(self.layout.cols, view.cols), @min(self.layout.rows, view.rows));
            try c.setLayerCellPosition(self.hint_layer, self.layout.row, self.layout.col);
            try c.setLayerScrollOffset(self.hint_layer, self.pan.row, self.pan.col);
            self.hints_dirty = true;
        }

        self.prefetch();
        self.status_dirty = true;
        // The layout the dialog is placed against just moved.
        if (self.ocr) |o| {
            if (o.at != null) self.dialog_dirty = true;
        }
    }

    // -- OCR geometry -----------------------------------------------------

    /// Multiplier from a mokuro box coordinate to a **page-layer pixel**.
    ///
    /// Two steps in one: mokuro's pixel space to the actual image's (they
    /// differ when a volume was re-encoded at another size after being
    /// OCR'd), then the image's to the scaled page on screen. A sidecar
    /// that never says how big it ran against is taken at face value.
    fn ocrScale(self: *const Ui, page: *const mokuro.Page) struct { x: f32, y: f32 } {
        const sx: f32 = if (page.img_width > 0 and self.page_px.w > 0)
            @as(f32, @floatFromInt(self.page_px.w)) / @as(f32, @floatFromInt(page.img_width))
        else
            1.0;
        const sy: f32 = if (page.img_height > 0 and self.page_px.h > 0)
            @as(f32, @floatFromInt(self.page_px.h)) / @as(f32, @floatFromInt(page.img_height))
        else
            1.0;
        return .{ .x = sx * self.layout.scale, .y = sy * self.layout.scale };
    }

    /// A cell rectangle, signed so it can sit partly (or wholly) off the
    /// left/top of whatever it is being placed in.
    const CellRect = struct { row: i64, col: i64, rows: i64, cols: i64 };

    /// A block's box in **page-layer** cells -- the grid the artwork is
    /// drawn on, which is what the region marks are written into.
    fn blockLayerRect(self: *const Ui, page: *const mokuro.Page, box: mokuro.Box) CellRect {
        const k = self.ocrScale(page);
        const cw: f32 = @floatFromInt(@max(self.cell.w, 1));
        const ch: f32 = @floatFromInt(@max(self.cell.h, 1));
        const c0: i64 = @intFromFloat(@floor(@as(f32, @floatFromInt(box.x1)) * k.x / cw));
        const r0: i64 = @intFromFloat(@floor(@as(f32, @floatFromInt(box.y1)) * k.y / ch));
        const c1: i64 = @intFromFloat(@ceil(@as(f32, @floatFromInt(box.x2)) * k.x / cw));
        const r1: i64 = @intFromFloat(@ceil(@as(f32, @floatFromInt(box.y2)) * k.y / ch));
        return .{ .row = r0, .col = c0, .rows = @max(r1 - r0, 1), .cols = @max(c1 - c0, 1) };
    }

    /// The same box in **window** cells: the layer rect shifted by where
    /// the page layer sits and by how far it is panned. Used to place the
    /// dialog next to the bubble it belongs to.
    fn blockWindowRect(self: *const Ui, page: *const mokuro.Page, box: mokuro.Box) CellRect {
        const r = self.blockLayerRect(page, box);
        return .{
            .row = r.row + @as(i64, @intCast(self.layout.row)) - @as(i64, @intCast(self.pan.row)),
            .col = r.col + @as(i64, @intCast(self.layout.col)) - @as(i64, @intCast(self.pan.col)),
            .rows = r.rows,
            .cols = r.cols,
        };
    }

    /// The mokuro pixel a **window** cell points at, or null when the cell
    /// isn't over the page at all. The inverse of `blockWindowRect`, and
    /// what turns a click into a bubble.
    fn ocrPixelAt(self: *const Ui, page: *const mokuro.Page, cell: glyphwire.CellPos) ?struct { x: i64, y: i64 } {
        const layer_col = @as(i64, @intCast(cell.col)) + @as(i64, @intCast(self.pan.col)) - @as(i64, @intCast(self.layout.col));
        const layer_row = @as(i64, @intCast(cell.row)) + @as(i64, @intCast(self.pan.row)) - @as(i64, @intCast(self.layout.row));
        if (layer_col < 0 or layer_row < 0) return null;
        if (layer_col >= @as(i64, @intCast(self.layout.cols)) or layer_row >= @as(i64, @intCast(self.layout.rows))) return null;

        const k = self.ocrScale(page);
        if (k.x <= 0 or k.y <= 0) return null;
        // The cell's *centre*, not its corner: a bubble whose edge falls
        // mid-cell is then hit by clicking the cell that mostly shows it.
        const px = (@as(f32, @floatFromInt(layer_col)) + 0.5) * @as(f32, @floatFromInt(self.cell.w));
        const py = (@as(f32, @floatFromInt(layer_row)) + 0.5) * @as(f32, @floatFromInt(self.cell.h));
        return .{ .x = @intFromFloat(px / k.x), .y = @intFromFloat(py / k.y) };
    }

    // -- OCR rendering ----------------------------------------------------

    /// The marks are the **heavy** box-drawing set, not the light one the
    /// dialog's own border uses. A light vertical is a one-pixel stroke in
    /// the middle of a cell, and over busy artwork at a small font size it
    /// disappears -- the heavy set is the only "thicker" a character grid
    /// offers. See the note on `renderHints` for why this is characters at
    /// all, and what it costs.
    const mark_tl = "\u{250f}";
    const mark_tr = "\u{2513}";
    const mark_bl = "\u{2517}";
    const mark_br = "\u{251b}";
    const mark_h = "\u{2501}";
    const mark_v = "\u{2503}";

    /// Widest and tallest mark drawn, in cells. A bubble bigger than this
    /// is drawn clipped rather than skipped: at 4x zoom a mark can be
    /// hundreds of cells across, and the cap bounds both the scratch
    /// buffer and the per-render message count without ever making a
    /// bubble unmarked.
    const mark_max_cols: usize = 400;
    const mark_max_rows: usize = 400;

    /// Marks every OCR region on the page (when hints are on) plus the one
    /// the dialog is showing (always).
    ///
    /// **A full rectangle, drawn as one `write_text` per row.** The sides
    /// matter: two horizontal rules alone read as two unrelated lines
    /// rather than as a box around a bubble. Each row of the box is a
    /// single run -- `┃`, interior spaces, `┃` -- written with
    /// `transparent_bg`, so it costs one cursor move and one write per row
    /// regardless of width, and the interior spaces are *not* a fill: on
    /// this layer every cell starts transparent and a space glyph draws
    /// nothing, so the artwork on the page layer below shows straight
    /// through the middle of every mark.
    ///
    /// That is the cheap version of a shape the cell grid is not really
    /// the right tool for -- see docs/decisions.md on why a pixel-space
    /// `draw_rect` would suit OCR boxes better than characters do.
    fn renderHints(self: *Ui) !void {
        self.hints_dirty = false;
        const o = &(self.ocr orelse return);

        const page = o.page orelse return self.hideHints();
        if (page.blocks.len == 0) return self.hideHints();

        const current: ?usize = blk: {
            const at = o.at orelse break :blk null;
            if (at >= o.order.items.len) break :blk null;
            break :blk o.order.items[at];
        };
        // Nothing to mark: hide the layer rather than leave an empty one
        // on top of the page, so it stops taking the wheel as well.
        if (!o.hints and current == null) return self.hideHints();

        try self.client.clearOn(self.hint_layer, 0, 0, null, null);

        // Three scratch runs, each built once per render and sliced per
        // block: the top edge, the bottom edge, and a middle row. Sized
        // for `mark_max_cols` cells of 3-byte box glyphs.
        var top_buf: [mark_max_cols * 3]u8 = undefined;
        var bot_buf: [mark_max_cols * 3]u8 = undefined;
        var mid_buf: [mark_max_cols * 3]u8 = undefined;

        var b = self.client.batch();
        defer b.deinit();
        var any = false;

        for (page.blocks, 0..) |blk, i| {
            const is_current = current != null and current.? == i;
            if (!o.hints and !is_current) continue;

            const r = self.blockLayerRect(page, blk.box);
            if (r.row < 0 or r.col < 0) continue;
            const row0: usize = @intCast(r.row);
            const col0: usize = @intCast(r.col);
            if (row0 >= self.layout.rows or col0 >= self.layout.cols) continue;

            // Clipped to the layer and to the mark caps, so a box running
            // off the page draws the part that is on it.
            const cols = @min(@min(@as(usize, @intCast(r.cols)), self.layout.cols - col0), mark_max_cols);
            const rows = @min(@min(@as(usize, @intCast(r.rows)), self.layout.rows - row0), mark_max_rows);
            if (cols < 2 or rows < 1) continue;

            const fg = if (is_current) fg_hint_current else fg_hint;
            const interior = cols - 2;

            const top = markRow(&top_buf, mark_tl, mark_h, mark_tr, interior);
            try self.emitMarkRow(&b, row0, col0, top, fg);

            // A one-row box is just its top edge; a two-row box has no
            // interior. Both are common for a small sound-effect bubble.
            if (rows >= 3) {
                const mid = markRow(&mid_buf, mark_v, " ", mark_v, interior);
                for (row0 + 1..row0 + rows - 1) |row| {
                    try self.emitMarkRow(&b, row, col0, mid, fg);
                }
            }
            if (rows >= 2) {
                const bot = markRow(&bot_buf, mark_bl, mark_h, mark_br, interior);
                try self.emitMarkRow(&b, row0 + rows - 1, col0, bot, fg);
            }
            any = true;
        }
        if (!any) return self.hideHints();

        var results = try b.send();
        results.deinit();
        try self.client.setLayerVisible(self.hint_layer, true);
    }

    /// `left` + `interior` copies of `mid` + `right`, into `buf`. The
    /// caller sizes `buf` for the widest run it will ask for.
    fn markRow(buf: []u8, left: []const u8, mid: []const u8, right: []const u8, interior: usize) []const u8 {
        var n: usize = 0;
        @memcpy(buf[n..][0..left.len], left);
        n += left.len;
        for (0..interior) |_| {
            @memcpy(buf[n..][0..mid.len], mid);
            n += mid.len;
        }
        @memcpy(buf[n..][0..right.len], right);
        n += right.len;
        return buf[0..n];
    }

    fn hideHints(self: *Ui) void {
        self.client.setLayerVisible(self.hint_layer, false) catch {};
    }

    /// One row of a mark on the marks layer. Transparent-backgrounded, and
    /// the layer's cells start blank, so the page shows through both the
    /// box's interior and the gaps around the glyphs themselves.
    fn emitMarkRow(self: *Ui, b: anytype, row: usize, col: usize, text: []const u8, fg: glyphwire.Color) !void {
        try b.notify("set_property", .{ .layer = self.hint_layer, .property = "cursor", .row = row, .col = col });
        try b.notify("write_text", .{
            .layer = self.hint_layer,
            .text = text,
            .fg = glyphwire.Client.colorToJson(fg),
            .transparent_bg = true,
        });
    }

    /// Draws (and places) the OCR text panel for the block the dialog is
    /// on, or hides it when there isn't one.
    ///
    /// The panel is sized to its text rather than to `ocr_dialog_cols`:
    /// that config value is the *cap* on the wrap, and a two-word bubble
    /// in a 40-column box would cover artwork for nothing.
    ///
    /// Border and fill are drawn the same way `buildHelp` draws the help
    /// popup: a flat background colour and box-drawing characters, not the
    /// bundled "dialog" 9-patch, whose gradient tiled badly at this scale
    /// and whose per-cell background didn't survive text drawn over it.
    /// Every cell -- border, pad and text alike -- is written with an
    /// explicit `bg`, so there is no transparent gap for the page to show
    /// through and nothing depends on a *previous* write's background
    /// still being there.
    ///
    /// The whole panel goes out as one `Batch`, again like the help popup:
    /// sent piecemeal, a half-drawn dialog is visible for a frame between
    /// round trips, which reads as a flicker every time you press `Tab`.
    fn renderDialog(self: *Ui) !void {
        self.dialog_dirty = false;
        const c = self.client;
        const o = &(self.ocr orelse return);

        const block = o.current() orelse {
            try c.setLayerVisible(self.dialog_layer, false);
            return;
        };
        if (o.hidden) {
            try c.setLayerVisible(self.dialog_layer, false);
            return;
        }
        const page = o.page orelse return;

        // Joined and re-wrapped: mokuro's lines follow the bubble's
        // columns, not the sentence. See `mokuro.joinLines`.
        const joined = try mokuro.joinLines(self.alloc, block.lines);
        errdefer self.alloc.free(joined);
        // Two border columns and a one-column pad inside each of them.
        const inner_max = self.conf.ocr_dialog_cols -| 4;
        const rows = try mokuro.wrap(self.alloc, joined, inner_max);
        errdefer self.alloc.free(rows);
        if (rows.len == 0) {
            self.alloc.free(joined);
            self.alloc.free(rows);
            try c.setLayerVisible(self.dialog_layer, false);
            return;
        }

        // Replace what a click on the panel resolves against. Freed
        // *after* the new join/wrap succeeds, not before, so a failed
        // render above never leaves `o.text` pointing at freed memory.
        o.freeText(self.alloc);
        o.text = .{ .joined = joined, .rows = rows };

        // The widest row decides the panel's width, capped at the wrap
        // width it was produced against.
        var inner: usize = 1;
        for (rows) |r| inner = @max(inner, mokuro.displayWidth(r));
        inner = @min(inner, inner_max);
        // One pad column each side of the text, plus the two border cells.
        const interior = inner + 2;
        const box_cols = interior + 2;
        const box_rows = rows.len + 2;

        const at = self.placeDialog(page, block.box, box_rows, box_cols);
        o.rect = .{ .row = at.row, .col = at.col, .rows = box_rows, .cols = box_cols };

        var b = c.batch();
        defer b.deinit();

        try b.notify("set_property", .{ .layer = self.dialog_layer, .property = "size", .cols = box_cols, .rows = box_rows });
        try b.notify("set_property", .{ .layer = self.dialog_layer, .property = "cell_position", .row = at.row, .col = at.col });
        try b.notify("clear", .{ .layer = self.dialog_layer, .row = 0, .col = 0, .rows = @as(?usize, null), .cols = @as(?usize, null) });

        // Sized for the widest panel `ocr_dialog_cols` can be clamped to,
        // so the runtime width never overruns it.
        var h_buf: [config_mod.ocr_dialog_cols_max * box_h.len]u8 = undefined;
        const h_line = repeatInto(&h_buf, box_h, interior);

        try cursorOn(&b, self.dialog_layer, 0, 0);
        try textOn(&b, self.dialog_layer, box_tl, fg_dialog_border, bg_dialog);
        try textOn(&b, self.dialog_layer, h_line, fg_dialog_border, bg_dialog);
        try textOn(&b, self.dialog_layer, box_tr, fg_dialog_border, bg_dialog);

        // Each text row is written as border, pad, text, pad-to-width,
        // border -- one run per piece, all with the panel's background, so
        // the row is opaque from edge to edge however short the text is.
        // The pad is measured in *display* columns because Japanese sets
        // two cells per character (`mokuro.displayWidth`).
        var pad_buf: [config_mod.ocr_dialog_cols_max]u8 = undefined;
        @memset(&pad_buf, ' ');
        for (rows, 0..) |line, i| {
            const used = @min(mokuro.displayWidth(line), inner);
            try cursorOn(&b, self.dialog_layer, i + 1, 0);
            try textOn(&b, self.dialog_layer, box_v, fg_dialog_border, bg_dialog);
            try textOn(&b, self.dialog_layer, pad_buf[0..1], fg_dialog, bg_dialog);
            try textOn(&b, self.dialog_layer, line, fg_dialog, bg_dialog);
            try textOn(&b, self.dialog_layer, pad_buf[0 .. inner - used + 1], fg_dialog, bg_dialog);
            try textOn(&b, self.dialog_layer, box_v, fg_dialog_border, bg_dialog);
        }

        try cursorOn(&b, self.dialog_layer, box_rows - 1, 0);
        try textOn(&b, self.dialog_layer, box_bl, fg_dialog_border, bg_dialog);
        try textOn(&b, self.dialog_layer, h_line, fg_dialog_border, bg_dialog);
        try textOn(&b, self.dialog_layer, box_br, fg_dialog_border, bg_dialog);

        // Both in the same batch, so the layer's first visible frame is
        // already the finished panel -- see `setHelp` for the same trick.
        try b.notify("set_property", .{
            .layer = self.dialog_layer,
            .property = "opacity",
            .value = if (o.peeking) self.conf.ocr_peek else @as(f32, 1.0),
        });
        try b.notify("set_property", .{ .layer = self.dialog_layer, .property = "visibility", .visible = true });

        var results = try b.send();
        results.deinit();
    }

    /// Where the dialog goes: below the bubble it came from when there is
    /// room, above it when there isn't, left-aligned with it, and always
    /// wholly on screen.
    ///
    /// Below-first because a manga bubble's tail points down more often
    /// than not, so the panel lands on the artwork you have already
    /// looked past rather than on the panel you are about to read.
    fn placeDialog(self: *const Ui, page: *const mokuro.Page, box: mokuro.Box, rows: usize, cols: usize) glyphwire.CellPos {
        const view = self.pageView();
        const max_row: i64 = @as(i64, @intCast(view.rows)) - @as(i64, @intCast(rows));
        const max_col: i64 = @as(i64, @intCast(view.cols)) - @as(i64, @intCast(cols));

        const r = self.blockWindowRect(page, box);
        var row = r.row + r.rows;
        if (row > max_row) {
            const above = r.row - @as(i64, @intCast(rows));
            // Only move above if that actually fits; otherwise leave it
            // below and let the clamp below pin it to the bottom edge,
            // which is still better than half off the top.
            if (above >= 0) row = above;
        }
        return .{
            .row = @intCast(std.math.clamp(row, 0, @max(max_row, 0))),
            .col = @intCast(std.math.clamp(r.col, 0, @max(max_col, 0))),
        };
    }

    /// Draws the dictionary lookup panel for `self.lookup`, or hides it
    /// when there's nothing to show. Same box-drawing shape as
    /// `renderDialog`, anchored below (or above) the OCR dialog rather
    /// than a page bubble -- it's answering a click made *on* that
    /// dialog, not on the artwork.
    ///
    /// Follows the OCR dialog's own peek/hide state (`o.peeking`,
    /// `o.hidden`): the panel is answering something *on* the dialog, so
    /// it has no business staying on screen, full-opacity, after the
    /// thing it's annotating has faded or gone.
    fn renderLookup(self: *Ui) !void {
        self.lookup_dirty = false;
        const c = self.client;
        if (self.ocr) |o| if (o.hidden) {
            try c.setLayerVisible(self.dict_layer, false);
            return;
        };
        const lk = self.lookup orelse {
            try c.setLayerVisible(self.dict_layer, false);
            return;
        };

        // Header: term, plus its reading when that differs from the term
        // itself (kana-only entries have the same string in both), plus
        // the deinflection reason when this wasn't the dictionary form.
        var header_buf: std.ArrayList(u8) = .empty;
        defer header_buf.deinit(self.alloc);
        try header_buf.appendSlice(self.alloc, lk.term);
        if (lk.reading.len > 0 and !std.mem.eql(u8, lk.reading, lk.term)) {
            try header_buf.appendSlice(self.alloc, " \u{3010}");
            try header_buf.appendSlice(self.alloc, lk.reading);
            try header_buf.appendSlice(self.alloc, "\u{3011}");
        }
        if (lk.reason) |r| {
            try header_buf.append(self.alloc, ' ');
            try header_buf.append(self.alloc, '(');
            try header_buf.appendSlice(self.alloc, r);
            try header_buf.append(self.alloc, ')');
        }

        // Body: every sense joined onto one ribbon before wrapping, not
        // one row per sense -- a homograph can carry a dozen, and this
        // panel is meant to answer "what does this word mean", not
        // replace the dictionary.
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.alloc);
        for (lk.glossary, 0..) |g, i| {
            if (i > 0) try body_buf.appendSlice(self.alloc, "; ");
            try body_buf.appendSlice(self.alloc, g);
        }
        if (lk.extra > 0) {
            const extra_str = try std.fmt.allocPrint(self.alloc, " (+{d} more)", .{lk.extra});
            defer self.alloc.free(extra_str);
            try body_buf.appendSlice(self.alloc, extra_str);
        }

        const inner_max = self.conf.ocr_dialog_cols -| 4;
        const header_rows = try mokuro.wrap(self.alloc, header_buf.items, inner_max);
        defer self.alloc.free(header_rows);
        const body_rows = try mokuro.wrap(self.alloc, body_buf.items, inner_max);
        defer self.alloc.free(body_rows);
        if (header_rows.len == 0 and body_rows.len == 0) {
            try c.setLayerVisible(self.dict_layer, false);
            return;
        }

        var inner: usize = 1;
        for (header_rows) |r| inner = @max(inner, mokuro.displayWidth(r));
        for (body_rows) |r| inner = @max(inner, mokuro.displayWidth(r));
        inner = @min(inner, inner_max);
        const interior = inner + 2;
        const box_cols = interior + 2;
        // A blank separator row between header and body, but only when
        // both are present.
        const sep_rows: usize = if (header_rows.len > 0 and body_rows.len > 0) 1 else 0;
        const box_rows = header_rows.len + sep_rows + body_rows.len + 2;

        const at = self.placeLookup(box_rows, box_cols);
        if (self.lookup) |*ptr| ptr.rect = .{ .row = at.row, .col = at.col, .rows = box_rows, .cols = box_cols };

        var b = c.batch();
        defer b.deinit();

        try b.notify("set_property", .{ .layer = self.dict_layer, .property = "size", .cols = box_cols, .rows = box_rows });
        try b.notify("set_property", .{ .layer = self.dict_layer, .property = "cell_position", .row = at.row, .col = at.col });
        try b.notify("clear", .{ .layer = self.dict_layer, .row = 0, .col = 0, .rows = @as(?usize, null), .cols = @as(?usize, null) });

        var h_buf: [config_mod.ocr_dialog_cols_max * box_h.len]u8 = undefined;
        const h_line = repeatInto(&h_buf, box_h, interior);

        try cursorOn(&b, self.dict_layer, 0, 0);
        try textOn(&b, self.dict_layer, box_tl, fg_dialog_border, bg_dialog);
        try textOn(&b, self.dict_layer, h_line, fg_dialog_border, bg_dialog);
        try textOn(&b, self.dict_layer, box_tr, fg_dialog_border, bg_dialog);

        var pad_buf: [config_mod.ocr_dialog_cols_max]u8 = undefined;
        @memset(&pad_buf, ' ');
        var row_i: usize = 1;
        for (header_rows) |line| {
            try writeLookupRow(&b, self.dict_layer, row_i, line, inner, &pad_buf, fg_lookup_term);
            row_i += 1;
        }
        if (sep_rows > 0) {
            try writeLookupRow(&b, self.dict_layer, row_i, "", inner, &pad_buf, fg_dialog);
            row_i += 1;
        }
        for (body_rows) |line| {
            try writeLookupRow(&b, self.dict_layer, row_i, line, inner, &pad_buf, fg_dialog);
            row_i += 1;
        }

        try cursorOn(&b, self.dict_layer, box_rows - 1, 0);
        try textOn(&b, self.dict_layer, box_bl, fg_dialog_border, bg_dialog);
        try textOn(&b, self.dict_layer, h_line, fg_dialog_border, bg_dialog);
        try textOn(&b, self.dict_layer, box_br, fg_dialog_border, bg_dialog);

        try b.notify("set_property", .{
            .layer = self.dict_layer,
            .property = "opacity",
            .value = if (self.ocr) |o| (if (o.peeking) self.conf.ocr_peek else @as(f32, 1.0)) else @as(f32, 1.0),
        });
        try b.notify("set_property", .{ .layer = self.dict_layer, .property = "visibility", .visible = true });

        var results = try b.send();
        results.deinit();
    }

    /// Below the OCR dialog when that fits, above it when it doesn't,
    /// left-aligned with it and always wholly on screen -- the same
    /// placement rule `placeDialog` applies to the dialog itself, just
    /// anchored to `ocr.rect` instead of a page bubble's box.
    fn placeLookup(self: *const Ui, rows: usize, cols: usize) glyphwire.CellPos {
        const view = self.pageView();
        const max_row: i64 = @as(i64, @intCast(view.rows)) - @as(i64, @intCast(rows));
        const max_col: i64 = @as(i64, @intCast(view.cols)) - @as(i64, @intCast(cols));

        const anchor_row: usize = if (self.ocr) |o| o.rect.row else 0;
        const anchor_col: usize = if (self.ocr) |o| o.rect.col else 0;
        const anchor_rows: usize = if (self.ocr) |o| o.rect.rows else 0;

        var row: i64 = @as(i64, @intCast(anchor_row)) + @as(i64, @intCast(anchor_rows));
        if (row > max_row) {
            const above = @as(i64, @intCast(anchor_row)) - @as(i64, @intCast(rows));
            if (above >= 0) row = above;
        }
        return .{
            .row = @intCast(std.math.clamp(row, 0, @max(max_row, 0))),
            .col = @intCast(std.math.clamp(@as(i64, @intCast(anchor_col)), 0, @max(max_col, 0))),
        };
    }

    /// Draws (or hides) the "building dictionary index" panel for
    /// `self.dict_build`. Unlike `renderDialog` / `renderLookup`, which
    /// anchor to something already on screen, this has nothing to anchor
    /// to -- a build can start before the reader has ever shown an OCR
    /// dialog -- so it's centered on the window instead, the same
    /// placement `buildHelp` uses for the same reason.
    fn renderDictBuild(self: *Ui) !void {
        self.dict_build_dirty = false;
        const c = self.client;
        const b = self.dict_build orelse {
            try c.setLayerVisible(self.dict_build_layer, false);
            return;
        };

        const line1 = "Building dictionary index...";
        const line2 = try std.fmt.allocPrint(
            self.alloc,
            "file {d} / {d} -- {d} terms indexed",
            .{ b.file_idx, b.totalFiles(), b.terms_indexed },
        );
        defer self.alloc.free(line2);

        var inner: usize = @max(mokuro.displayWidth(line1), mokuro.displayWidth(line2));
        inner = std.math.clamp(inner, 1, config_mod.ocr_dialog_cols_max);
        const interior = inner + 2;
        const box_cols = interior + 2;
        const box_rows: usize = 4; // top border, two text rows, bottom border

        var batch = c.batch();
        defer batch.deinit();

        try batch.notify("set_property", .{ .layer = self.dict_build_layer, .property = "size", .cols = box_cols, .rows = box_rows });
        try batch.notify("set_property", .{
            .layer = self.dict_build_layer,
            .property = "cell_position",
            .row = (self.win.rows -| box_rows) / 2,
            .col = (self.win.cols -| box_cols) / 2,
        });
        try batch.notify("clear", .{ .layer = self.dict_build_layer, .row = 0, .col = 0, .rows = @as(?usize, null), .cols = @as(?usize, null) });

        var h_buf: [config_mod.ocr_dialog_cols_max * box_h.len]u8 = undefined;
        const h_line = repeatInto(&h_buf, box_h, interior);

        try cursorOn(&batch, self.dict_build_layer, 0, 0);
        try textOn(&batch, self.dict_build_layer, box_tl, fg_dialog_border, bg_dialog);
        try textOn(&batch, self.dict_build_layer, h_line, fg_dialog_border, bg_dialog);
        try textOn(&batch, self.dict_build_layer, box_tr, fg_dialog_border, bg_dialog);

        var pad_buf: [config_mod.ocr_dialog_cols_max]u8 = undefined;
        @memset(&pad_buf, ' ');
        try writeLookupRow(&batch, self.dict_build_layer, 1, line1, inner, &pad_buf, fg_dialog);
        try writeLookupRow(&batch, self.dict_build_layer, 2, line2, inner, &pad_buf, fg_dialog);

        try cursorOn(&batch, self.dict_build_layer, box_rows - 1, 0);
        try textOn(&batch, self.dict_build_layer, box_bl, fg_dialog_border, bg_dialog);
        try textOn(&batch, self.dict_build_layer, h_line, fg_dialog_border, bg_dialog);
        try textOn(&batch, self.dict_build_layer, box_br, fg_dialog_border, bg_dialog);

        try batch.notify("set_property", .{ .layer = self.dict_build_layer, .property = "visibility", .visible = true });

        var results = try batch.send();
        results.deinit();
    }

    fn renderStatus(self: *Ui) !void {
        self.status_dirty = false;
        const c = self.client;

        try c.setLayerSize(self.status_layer, self.win.cols, status_rows);
        try c.setLayerCellPosition(self.status_layer, self.win.rows -| status_rows, 0);

        // Lay the band down first, then write the three groups over it.
        // `clear` resets a cell to the *default* style, not to a chosen
        // colour, so without this the gaps between the groups would be
        // transparent and the backdrop would show through -- a status
        // bar in three islands rather than one strip.
        var blanks_buf: [512]u8 = undefined;
        const band_len = @min(self.win.cols, blanks_buf.len);
        @memset(blanks_buf[0..band_len], ' ');
        try c.setCursorOn(self.status_layer, 0, 0);
        try c.writeTextOn(self.status_layer, blanks_buf[0..band_len], fg_status, bg_status);
        try c.setCursorOn(self.status_layer, 0, 0);

        var buf: [512]u8 = undefined;

        // Left: where you are in the book, and which way it pages.
        const left = std.fmt.bufPrint(&buf, " {d}/{d} {s} ", .{
            self.page + 1,
            self.book.count(),
            self.direction.label(),
        }) catch " ";
        try c.writeTextOn(self.status_layer, left, fg_status, bg_status);

        // Middle: the goto prompt while it's open, else the page's own
        // name, else whatever went wrong.
        switch (self.pending) {
            .goto_prompt => |prompt| {
                const text = std.fmt.bufPrint(&buf, ":{s}_ ", .{prompt.items}) catch ":";
                try c.writeTextOn(self.status_layer, text, fg_warn, bg_status);
            },
            else => if (self.message) |m| {
                try c.writeTextOn(self.status_layer, m, fg_warn, bg_status);
            } else {
                const name = self.book.pages.items[@min(self.page, self.book.count() -| 1)].name;
                try c.writeTextOn(self.status_layer, name, fg_dim, bg_status);
            },
        }

        // Right: the OCR marker (only for a book that has any), then the
        // sizing mode and, when it isn't a plain fit, the factor -- "fit"
        // alone says everything, "1:1 100%" does not.
        var ocr_buf: [32]u8 = undefined;
        const ocr_label: []const u8 = if (self.ocr) |o| blk: {
            const n = o.order.items.len;
            if (n == 0) break :blk "  ocr -";
            // 1-based, like the page counter next to it; 0 while the
            // dialog is closed, which reads as "none of the 5 open".
            const at = if (o.at) |i| i + 1 else 0;
            break :blk std.fmt.bufPrint(&ocr_buf, "  ocr {d}/{d}", .{ at, n }) catch "  ocr";
        } else "";
        const right = std.fmt.bufPrint(&buf, "{s}  {s} {d:.0}%  ? help ", .{
            ocr_label,
            self.mode.label(),
            self.layout.scale * 100,
        }) catch "";
        const at: usize = self.win.cols -| right.len;
        try c.setCursorOn(self.status_layer, 0, at);
        try c.writeTextOn(self.status_layer, right, fg_status, bg_status);

        if (self.help_visible) try self.renderHelp();
    }

    /// Wide enough for the longest line below plus the box's two border
    /// columns and the one-column inset the text is drawn at -- a line
    /// that doesn't fit wraps onto the next one and eats it. `help_rows`
    /// is derived rather than written down for the same reason.
    const help_cols: usize = 54;
    const help_rows: usize = help_lines.len + 2;

    /// Cells between the two border columns -- where the border corners
    /// and the padded interior line share the row.
    const help_interior: usize = help_cols - 2;

    const help_lines = [_][]const u8{
        "  gw-read",
        "",
        "  space / page_down    next page",
        "  backspace / page_up  previous page",
        "  left / right         turn, or pan when zoomed",
        "  h j k l              pan",
        "  ] / [                jump 5 pages",
        "  g g / G              first / last page",
        "  :  <digits> enter    go to page",
        "",
        "  f / w / t / 1        fit / width / height / 1:1",
        "  + / -                zoom in / out",
        "  d                    flip reading direction",
        "",
        "  mokuro OCR (when the book has a .mokuro file)",
        "  click a bubble       show its text",
        "  tab / shift-tab      next / previous bubble",
        "  o                    outline every text region",
        "  z (hold)             fade the dialog to see the page",
        "  \\                    hide the dialog",
        "  escape               close the dialog",
        "",
        "  ? toggle this   q quit",
    };

    const box_tl = "\u{250c}";
    const box_tr = "\u{2510}";
    const box_bl = "\u{2514}";
    const box_br = "\u{2518}";
    const box_h = "\u{2500}";
    const box_v = "\u{2502}";

    /// `s` repeated `n` times into `buf` (sized by the caller for exactly
    /// that many copies) -- used to draw a solid horizontal border run
    /// without a `zig 0.17` `**` repeat operator, which no longer exists.
    fn repeatInto(buf: []u8, s: []const u8, n: usize) []const u8 {
        var i: usize = 0;
        while (i < n) : (i += 1) @memcpy(buf[i * s.len ..][0 .. s.len], s);
        return buf[0 .. n * s.len];
    }

    /// `set_property(help_layer, "cursor", ...)` queued on `b` -- the
    /// `Batch` type has no non-default-layer convenience for this (its
    /// typed methods are all root-implicit, see `Client.Batch`'s doc
    /// comment), so this goes through `notify`, the same escape hatch
    /// `Client.setCursorOn` itself is built on.
    fn cursorOn(b: *glyphwire.Client.Batch, layer: glyphwire.LayerHandle, row: usize, col: usize) !void {
        try b.notify("set_property", .{ .layer = layer, .property = "cursor", .row = row, .col = col });
    }

    /// `write_text(help_layer, ...)` queued on `b` -- see `cursorOn`.
    /// `fg`/`bg` serialize the same whether passed as `core.Color` or
    /// the wire's own `protocol.Color` (identical field shape), so this
    /// skips the private `colorToJson` conversion `Client.writeTextOn`
    /// uses internally.
    fn textOn(b: *glyphwire.Client.Batch, layer: glyphwire.LayerHandle, text: []const u8, fg: glyphwire.Color, bg: glyphwire.Color) !void {
        try b.notify("write_text", .{ .layer = layer, .text = text, .fg = fg, .bg = bg });
    }

    /// One panel row -- border, pad, text, pad-to-width, border -- the
    /// piece `renderDialog` and `renderLookup` both repeat once per line.
    /// `pad_buf` is scratch, spaces already `@memset`, at least `inner`
    /// long.
    fn writeLookupRow(
        b: *glyphwire.Client.Batch,
        layer: glyphwire.LayerHandle,
        row: usize,
        text: []const u8,
        inner: usize,
        pad_buf: []u8,
        fg: glyphwire.Color,
    ) !void {
        const used = @min(mokuro.displayWidth(text), inner);
        try cursorOn(b, layer, row, 0);
        try textOn(b, layer, box_v, fg_dialog_border, bg_dialog);
        try textOn(b, layer, pad_buf[0..1], fg, bg_dialog);
        try textOn(b, layer, text, fg, bg_dialog);
        try textOn(b, layer, pad_buf[0 .. inner - used + 1], fg, bg_dialog);
        try textOn(b, layer, box_v, fg_dialog_border, bg_dialog);
    }

    /// Queues the dialog's full redraw (border + every line) onto `b`
    /// rather than sending each piece as its own notification: a
    /// half-drawn dialog would otherwise be visible for a frame between
    /// round trips, which is what caused the flicker the character
    /// border replaced the 9-patch with -- see `setHelp`, which folds
    /// the `visibility` flip into the same batch on open so the layer's
    /// very first visible frame is already the finished dialog.
    fn buildHelp(self: *Ui, b: *glyphwire.Client.Batch) !void {
        try b.notify("set_property", .{
            .layer = self.help_layer,
            .property = "cell_position",
            .row = (self.win.rows -| help_rows) / 2,
            .col = (self.win.cols -| help_cols) / 2,
        });
        try b.notify("clear", .{ .layer = self.help_layer, .row = 0, .col = 0, .rows = @as(?usize, null), .cols = @as(?usize, null) });

        var h_buf: [help_interior * box_h.len]u8 = undefined;
        const h_line = repeatInto(&h_buf, box_h, help_interior);

        try cursorOn(b, self.help_layer, 0, 0);
        try textOn(b, self.help_layer, box_tl, fg_status, bg_status);
        try textOn(b, self.help_layer, h_line, fg_status, bg_status);
        try textOn(b, self.help_layer, box_tr, fg_status, bg_status);

        var line_buf: [help_interior]u8 = undefined;
        for (help_lines, 0..) |line, i| {
            const keep = @min(line.len, help_interior);
            @memcpy(line_buf[0..keep], line[0..keep]);
            @memset(line_buf[keep..], ' ');

            try cursorOn(b, self.help_layer, i + 1, 0);
            try textOn(b, self.help_layer, box_v, fg_status, bg_status);
            try textOn(b, self.help_layer, &line_buf, fg_status, bg_status);
            try textOn(b, self.help_layer, box_v, fg_status, bg_status);
        }

        try cursorOn(b, self.help_layer, help_rows - 1, 0);
        try textOn(b, self.help_layer, box_bl, fg_status, bg_status);
        try textOn(b, self.help_layer, h_line, fg_status, bg_status);
        try textOn(b, self.help_layer, box_br, fg_status, bg_status);
    }

    /// Redraws the dialog in place -- e.g. `render()` keeping it current
    /// across a resize while it's already showing. `setHelp` handles the
    /// open/close transition itself rather than calling this.
    fn renderHelp(self: *Ui) !void {
        var b = self.client.batch();
        defer b.deinit();
        try self.buildHelp(&b);
        var results = try b.send();
        results.deinit();
    }

    /// Moves the viewport over the page. Both layers, always: the marks
    /// layer is a second window onto the same geometry, and letting the
    /// two offsets drift would slide every mark off its bubble.
    fn applyPan(self: *Ui, row: usize, col: usize) void {
        self.pan = .{ .row = row, .col = col };
        self.client.setLayerScrollOffset(self.page_layer, row, col) catch {};
        self.client.setLayerScrollOffset(self.hint_layer, row, col) catch {};
    }

    fn clampPan(self: *Ui) void {
        self.pan.row = @min(self.pan.row, self.layout.max_pan_row);
        self.pan.col = @min(self.pan.col, self.layout.max_pan_col);
    }

    fn setMessage(self: *Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.message) |m| self.alloc.free(m);
        self.message = std.fmt.allocPrint(self.alloc, fmt, args) catch null;
    }

    fn clearMessage(self: *Ui) void {
        if (self.message) |m| {
            self.alloc.free(m);
            self.message = null;
            self.status_dirty = true;
        }
    }

    // ── Input ───────────────────────────────────────────────────────────

    fn handleInput(self: *Ui, ev: glyphwire.InputEvent) !void {
        switch (ev) {
            // Every physical keystroke is a press *and* a release; acting
            // on both would turn two pages per tap. The one exception is
            // the hold-to-peek key, which is *defined* by the release.
            .key => |k| if (k.pressed) try self.handleKey(k.key) else try self.handleKeyRelease(k.key),
            .text => |t| try self.handleText(t.text),
            .shutdown => self.quit = true,
            else => {},
        }
    }

    fn handleKey(self: *Ui, key: []const u8) !void {
        const eq = std.mem.eql;
        self.clearMessage();

        // The goto prompt swallows everything but its own control keys,
        // so a digit typed into it doesn't also page the book.
        if (self.pending == .goto_prompt) {
            if (eq(u8, key, "enter") or eq(u8, key, "kp_enter")) return self.commitGoto();
            if (eq(u8, key, "escape")) return self.cancelGoto();
            if (eq(u8, key, "backspace")) {
                var prompt = &self.pending.goto_prompt;
                if (prompt.items.len > 0) _ = prompt.pop();
                self.status_dirty = true;
                return;
            }
            return;
        }

        // `gg` -- the second `g` arrives as its own keystroke, so the
        // first one only arms the prefix.
        if (self.pending == .goto_prefix) {
            self.pending = .none;
            if (eq(u8, key, "g")) {
                self.goToPage(0);
                return;
            }
            // Anything else cancels the prefix and is handled normally.
        }

        const shift = self.listener.isKeyDown("left_shift") or self.listener.isKeyDown("right_shift");

        // ── quit / overlay ──
        if (eq(u8, key, "q") or eq(u8, key, "escape")) {
            if (self.help_visible) {
                try self.setHelp(false);
                return;
            }
            // Escape closes the OCR dialog before it quits; `q` doesn't,
            // so there is still a one-key way out with the dialog up.
            if (eq(u8, key, "escape")) {
                if (self.ocr) |o| {
                    if (o.at != null) {
                        self.closeDialog();
                        return;
                    }
                }
            }
            self.quit = true;
            return;
        }
        // -- OCR --
        if (eq(u8, key, "tab")) return self.stepBlock(if (shift) -1 else 1);
        if (eq(u8, key, "o")) return self.toggleHints();
        if (eq(u8, key, "z")) return self.setPeek(true);
        // ── unambiguous page turns ──
        if (eq(u8, key, "space") or eq(u8, key, "page_down")) return self.stepPage(1);
        if (eq(u8, key, "backspace") or eq(u8, key, "page_up")) return self.stepPage(-1);
        if (eq(u8, key, "home")) return self.goToPage(0);
        if (eq(u8, key, "end")) return self.goToPage(self.book.count() -| 1);
        if (eq(u8, key, "g")) {
            if (shift) return self.goToPage(self.book.count() -| 1); // G
            self.pending = .goto_prefix;
            return;
        }
        // ── pan (always) ──
        if (eq(u8, key, "h")) return self.panBy(0, -@as(i64, @intCast(self.conf.pan_step)));
        if (eq(u8, key, "l")) return self.panBy(0, @intCast(self.conf.pan_step));
        if (eq(u8, key, "k")) return self.panBy(-@as(i64, @intCast(self.conf.pan_step)), 0);
        if (eq(u8, key, "j")) return self.panBy(@intCast(self.conf.pan_step), 0);

        // ── arrows: pan the axis if it overflows, else turn the page ──
        if (eq(u8, key, "left")) {
            if (self.layout.max_pan_col > 0) return self.panBy(0, -@as(i64, @intCast(self.conf.pan_step)));
            return self.turn(.left);
        }
        if (eq(u8, key, "right")) {
            if (self.layout.max_pan_col > 0) return self.panBy(0, @intCast(self.conf.pan_step));
            return self.turn(.right);
        }
        if (eq(u8, key, "up")) {
            if (self.layout.max_pan_row > 0) return self.panBy(-@as(i64, @intCast(self.conf.pan_step)), 0);
            return self.stepPage(-1);
        }
        if (eq(u8, key, "down")) {
            if (self.layout.max_pan_row > 0) return self.panBy(@intCast(self.conf.pan_step), 0);
            return self.stepPage(1);
        }

        // ── sizing ──
        if (eq(u8, key, "f")) return self.setMode(.fit_screen);
        if (eq(u8, key, "w")) return self.setMode(.fit_width);
        if (eq(u8, key, "t")) return self.setMode(.fit_height);
        if (eq(u8, key, "one")) return self.setMode(.natural);

        // ── direction ──
        if (eq(u8, key, "d")) return self.flipDirection();
    }

    /// The release half of a keystroke. Only the hold-to-peek key cares:
    /// everything else acts on the press and ignores this.
    fn handleKeyRelease(self: *Ui, key: []const u8) !void {
        if (std.mem.eql(u8, key, "z")) self.setPeek(false);
    }

    /// `z` down / up: fade the dialog -- and the lookup panel, when one is
    /// open -- to `ocr_peek` and back. A held key repeats, so the
    /// redundant set is filtered here rather than sent down the wire
    /// dozens of times a second.
    fn setPeek(self: *Ui, on: bool) void {
        const o = &(self.ocr orelse return);
        if (o.at == null or o.peeking == on) return;
        o.peeking = on;
        // Straight to the wire rather than through `dialog_dirty` /
        // `lookup_dirty`: the panels' contents haven't changed, only how
        // they composite, and a full redraw per keypress would be a lot
        // of writes for a fade.
        const opacity: f32 = if (on) self.conf.ocr_peek else 1.0;
        self.client.setLayerOpacity(self.dialog_layer, opacity) catch {};
        if (self.lookup != null) self.client.setLayerOpacity(self.dict_layer, opacity) catch {};
    }

    /// `\`: hide the dialog -- and the lookup panel, when one is open --
    /// outright, for when even a faded panel is in the way. A no-op with
    /// no dialog open -- there is nothing to hide, and silently arming
    /// the flag would make the *next* `Tab` open nothing.
    fn toggleDialogHidden(self: *Ui) void {
        const o = &(self.ocr orelse return);
        if (o.at == null) return;
        o.hidden = !o.hidden;
        self.dialog_dirty = true;
        if (self.lookup != null) self.lookup_dirty = true;
    }

    /// `o`: outline every OCR region on the page.
    fn toggleHints(self: *Ui) void {
        const o = &(self.ocr orelse return);
        o.hints = !o.hints;
        self.hints_dirty = true;
        self.status_dirty = true;
    }

    /// Committed text input. Two jobs:
    ///
    /// 1. The digits of the goto prompt.
    /// 2. Every **punctuation** command -- `:` `?` `+` `-` `[` `]`.
    ///
    /// Punctuation deliberately does *not* go through `handleKey`. A key
    /// event names the physical key, so `:` would have to be spelled
    /// "shift held and the `semicolon` key", which is only true on a US
    /// layout -- on a German one that key is `ö` and the colon is
    /// somewhere else entirely. `text` is the host's char-callback
    /// output, already resolved through the OS layout and any IME, so
    /// matching the character itself is both simpler and correct
    /// everywhere. Letters and named keys stay on `handleKey`, where the
    /// physical position *is* what's wanted (vim-style, same as zoe).
    fn handleText(self: *Ui, text: []const u8) !void {
        if (self.pending == .goto_prompt) {
            var prompt = &self.pending.goto_prompt;
            for (text) |ch| {
                if (!std.ascii.isDigit(ch)) continue;
                // A page number longer than this isn't a page number.
                if (prompt.items.len >= 9) break;
                try prompt.append(self.alloc, ch);
            }
            self.status_dirty = true;
            return;
        }

        const eq = std.mem.eql;
        if (eq(u8, text, ":")) return self.startGoto();
        if (eq(u8, text, "?")) return self.setHelp(!self.help_visible);
        // `=` as well as `+`: the unshifted key is just as good a "zoom
        // in" and saves the reach.
        if (eq(u8, text, "+") or eq(u8, text, "=")) return self.zoomBy(.in);
        if (eq(u8, text, "-")) return self.zoomBy(.out);
        if (eq(u8, text, "\\")) return self.toggleDialogHidden();
        if (eq(u8, text, "]")) return self.stepPage(@intCast(self.conf.jump_pages));
        if (eq(u8, text, "[")) return self.stepPage(-@as(i64, @intCast(self.conf.jump_pages)));
    }

    /// A page turn expressed as a screen direction, resolved against the
    /// reading direction: in `rtl`, leftward is forward.
    fn turn(self: *Ui, side: enum { left, right }) void {
        const forward = switch (self.direction) {
            .rtl => side == .left,
            .ltr => side == .right,
        };
        self.stepPage(if (forward) 1 else -1);
    }

    fn panBy(self: *Ui, d_row: i64, d_col: i64) void {
        const row = zoom.clampPan(@as(i64, @intCast(self.pan.row)) + d_row, self.layout.max_pan_row);
        const col = zoom.clampPan(@as(i64, @intCast(self.pan.col)) + d_col, self.layout.max_pan_col);
        if (row == self.pan.row and col == self.pan.col) return;
        self.applyPan(row, col);
        self.status_dirty = true;
    }

    fn setMode(self: *Ui, mode: zoom.Mode) void {
        if (self.mode == mode) return;
        self.mode = mode;
        // Land at the page's reading edge, same as a page turn: switching
        // a manga page to fit-width should show its top *right*, which is
        // where the first panel is. A `+`/`-` zoom deliberately doesn't do
        // this -- stepping the magnification shouldn't also jump you
        // across the page you were looking at.
        self.pan = .{};
        self.pan_to_reading_edge = true;
        self.page_dirty = true;
    }

    fn zoomBy(self: *Ui, dir: enum { in, out }) void {
        // The first zoom step from a fit mode continues from the size
        // currently on screen (`free_scale` tracks it in `renderPage`).
        self.free_scale = zoom.step(self.free_scale, switch (dir) {
            .in => .in,
            .out => .out,
        }, self.conf.limits());
        self.mode = .free;
        self.page_dirty = true;
    }

    fn flipDirection(self: *Ui) void {
        self.direction = switch (self.direction) {
            .rtl => .ltr,
            .ltr => .rtl,
        };
        // `Tab` walks the bubbles the way the page reads, so the order
        // reverses with the direction. The open dialog closes with it: its
        // position was an index into the old order.
        if (self.ocr != null) {
            self.closeDialog();
            self.rebuildOcrOrder();
        }
        self.status_dirty = true;
    }

    /// Showing the dialog flips `visibility` and redraws it in the same
    /// batch, so the layer never turns visible with last render's stale
    /// content (or nothing at all) for a frame before the real content
    /// lands -- see `buildHelp`. Hiding it is just the one flip.
    fn setHelp(self: *Ui, visible: bool) !void {
        self.help_visible = visible;
        if (visible) {
            var b = self.client.batch();
            defer b.deinit();
            try b.notify("set_property", .{ .layer = self.help_layer, .property = "visibility", .visible = true });
            try self.buildHelp(&b);
            var results = try b.send();
            results.deinit();
        } else {
            try self.client.setLayerVisible(self.help_layer, false);
        }
        self.status_dirty = true;
    }

    fn startGoto(self: *Ui) void {
        self.pending = .{ .goto_prompt = .empty };
        self.status_dirty = true;
    }

    fn cancelGoto(self: *Ui) void {
        self.pending.goto_prompt.deinit(self.alloc);
        self.pending = .none;
        self.status_dirty = true;
    }

    fn commitGoto(self: *Ui) void {
        // Everything the message needs is read out *before* the prompt's
        // buffer is freed. `handleText` caps the entry at 9 digits, so
        // this can't truncate anything the user actually typed.
        var typed: [9]u8 = undefined;
        const entered = self.pending.goto_prompt.items;
        const len = @min(entered.len, typed.len);
        @memcpy(typed[0..len], entered[0..len]);
        const n = std.fmt.parseInt(usize, typed[0..len], 10) catch 0;

        self.pending.goto_prompt.deinit(self.alloc);
        self.pending = .none;

        if (n == 0 or n > self.book.count()) {
            self.setMessage("no page {s}", .{typed[0..len]}) catch {};
            self.status_dirty = true;
            return;
        }
        // Pages are 1-based everywhere the reader shows them.
        self.goToPage(n - 1);
    }

    // ── Mouse ───────────────────────────────────────────────────────────

    fn handleMouseButton(self: *Ui, ev: glyphwire.MouseButtonEvent) !void {
        if (!std.mem.eql(u8, ev.button, "left")) return;

        if (ev.pressed) {
            // A press inside the open dialog selects its text rather than
            // panning the page behind it -- the reader's context is
            // client-owned, so glyphwire-host leaves the drag to us (see
            // `Selection.handleMouseSelection`), and this is the client
            // half of the same gesture. The selection lands on the dialog
            // layer, where the host's Ctrl+Shift+C finds it.
            if (self.dialogPoint(ev.cell)) |p| {
                self.text_drag = .{ .anchor = p, .active = p, .moved = false };
                self.client.setSelection(self.dialog_layer, p, p) catch {};
                return;
            }
            self.drag = .{
                .cell = ev.cell,
                .pan_row = self.pan.row,
                .pan_col = self.pan.col,
                .moved = false,
            };
            return;
        }

        if (self.text_drag) |td| {
            self.text_drag = null;
            if (td.moved) {
                // A real selection: look up exactly what was dragged over
                // rather than guessing a word boundary, and leave the
                // selection as drawn so Ctrl+Shift+C still copies it.
                self.lookupSelection(td.anchor, td.active);
            } else {
                // A click inside the dialog that never moved isn't a
                // selection; drop the zero-width one so it doesn't sit
                // there tinting a cell -- and try it as a word lookup
                // instead.
                self.client.clearSelection(self.dialog_layer) catch {};
                self.wordLookupAt(td.anchor);
            }
            return;
        }

        const started = self.drag orelse return;
        self.drag = null;
        // A release that never moved is a click, not a drag: click the
        // near half of the window to go back, the far half to go on --
        // the gesture every comic reader has, and direction-aware for the
        // same reason the arrow keys are.
        if (started.moved) return;
        self.clearMessage();

        // ...unless it landed on a bubble, which opens that bubble's text
        // instead. A click that misses every bubble while the dialog is up
        // *closes* it and stops there: having just been reading a bubble,
        // "get this out of the way" is far likelier to be what was meant
        // than "and also turn the page".
        if (self.blockAtCell(ev.cell)) |at| return self.showBlock(at);
        if (self.ocr) |o| {
            if (o.at != null) return self.closeDialog();
        }
        self.turn(if (ev.cell.col * 2 < self.win.cols) .left else .right);
    }

    /// Position in reading order of the OCR block under window cell
    /// `cell`, or null when there isn't one (no OCR, no page entry, or a
    /// click that missed every bubble).
    fn blockAtCell(self: *const Ui, cell: glyphwire.CellPos) ?usize {
        const o = &(self.ocr orelse return null);
        const page = o.page orelse return null;
        const px = self.ocrPixelAt(page, cell) orelse return null;
        const block = mokuro.blockAt(page, px.x, px.y) orelse return null;
        // `showBlock` and `Tab` both index reading order, not the file
        // order `blockAt` reports, so map across.
        for (o.order.items, 0..) |idx, at| {
            if (idx == block) return at;
        }
        return null;
    }

    /// The selection point for window cell `cell` inside the open dialog,
    /// or null when the cell isn't over it. The dialog layer has no
    /// viewport offset, so a content row is just the row within the panel
    /// and `above` is its negation (see `core.SelectionPoint`).
    fn dialogPoint(self: *const Ui, cell: glyphwire.CellPos) ?glyphwire.SelectionPoint {
        const o = &(self.ocr orelse return null);
        if (o.at == null or o.hidden) return null;
        const r = o.rect;
        if (r.rows == 0 or r.cols == 0) return null;
        if (cell.row < r.row or cell.row >= r.row + r.rows) return null;
        if (cell.col < r.col or cell.col >= r.col + r.cols) return null;
        return .{ .above = -@as(i64, @intCast(cell.row - r.row)), .col = cell.col - r.col };
    }

    /// Resolves a stationary click at dialog-local point `p` (see
    /// `dialogPoint`) to a word and looks it up, replacing -- or, on no
    /// match, clearing -- `self.lookup`. A no-op with no dictionary
    /// loaded; also a no-op (clearing any open lookup) when the click
    /// landed on the border/pad rather than on text, since that's not a
    /// word either.
    ///
    /// No tokenizing happens here: `dict.lookup` is handed everything
    /// from the click point to the end of the row and tries decreasing
    /// substrings itself, the same trick Yomitan uses since Japanese has
    /// no spaces to split words on. On a match, the span it settled on
    /// (`Match.len`) is selected on the dialog layer -- same as dragging
    /// it by hand -- so it's visible which word the panel is answering
    /// for, and Ctrl+Shift+C copies exactly that without a separate drag.
    fn wordLookupAt(self: *Ui, p: glyphwire.SelectionPoint) void {
        const d = &(self.dict orelse return);
        const o = &(self.ocr orelse return);

        // `above` is `-(panel row)`, and row 0 is the border -- text rows
        // are 1-based, matching how `renderDialog` writes them.
        const panel_row = -p.above;
        if (panel_row < 1) return self.clearLookup();
        const row_idx: usize = @intCast(panel_row - 1);
        if (row_idx >= o.text.rows.len) return self.clearLookup();
        // Column 0 is the border, column 1 the pad -- text starts at 2.
        if (p.col < 2) return self.clearLookup();
        const text_col = p.col - 2;

        const row = o.text.rows[row_idx];
        const byte_off = mokuro.columnToByte(row, text_col);
        if (byte_off >= row.len) return self.clearLookup();

        const m = dict_mod.lookup(self.alloc, d, row[byte_off..]) catch null;
        self.setLookupFromMatch(m);
        if (self.lookup != null) {
            const end_col = p.col + mokuro.displayWidth(row[byte_off .. byte_off + m.?.len]);
            self.client.setSelection(self.dialog_layer, p, .{ .above = p.above, .col = end_col }) catch {};
        }
    }

    /// Resolves a completed drag inside the dialog (`a`/`b`, the anchor
    /// and release point, in either order) to source text and looks it
    /// up -- the same substring-and-deinflect search `wordLookupAt` uses,
    /// but bounded to exactly what was dragged over instead of "click to
    /// end of row". The selection itself is left alone: it already shows
    /// what was dragged, so there's nothing to add the way `wordLookupAt`
    /// adds one for a plain click.
    ///
    /// `a` and `b` are clamped into the text region rather than rejected
    /// outright (`clampToText`) -- a drag that overshoots the border or
    /// pad, easy to do this close to a panel edge, still resolves to the
    /// nearest text instead of finding nothing.
    ///
    /// `Ocr.text.rows` are slices *into* `Ocr.text.joined` (see
    /// `mokuro.wrap`), so the span between two rows -- even across a
    /// multi-row selection -- is read straight out of `joined` by byte
    /// offset rather than reassembled row by row, which would either drop
    /// or duplicate whatever wrap folded into the seam between them.
    fn lookupSelection(self: *Ui, a: glyphwire.SelectionPoint, b: glyphwire.SelectionPoint) void {
        const d = &(self.dict orelse return);
        const o = &(self.ocr orelse return);
        if (o.text.rows.len == 0) return self.clearLookup();

        const pa = clampToText(o, a);
        const pb = clampToText(o, b);
        const a_first = pa.row_idx < pb.row_idx or (pa.row_idx == pb.row_idx and pa.byte_off <= pb.byte_off);
        const first = if (a_first) pa else pb;
        const second = if (a_first) pb else pa;

        const joined = o.text.joined;
        const row_first = o.text.rows[first.row_idx];
        const row_second = o.text.rows[second.row_idx];
        const abs_start = (@intFromPtr(row_first.ptr) - @intFromPtr(joined.ptr)) + first.byte_off;
        const abs_end = (@intFromPtr(row_second.ptr) - @intFromPtr(joined.ptr)) + second.byte_off;
        if (abs_end <= abs_start) return self.clearLookup();

        const m = dict_mod.lookup(self.alloc, d, joined[abs_start..abs_end]) catch null;
        self.setLookupFromMatch(m);
    }

    /// Clamps dialog-local point `p` to the nearest text cell: rows above
    /// the first text row (or below the last) clamp to that row, and
    /// `mokuro.columnToByte` already clamps a column past a row's own
    /// width to its end. Used for selection endpoints, which -- unlike a
    /// plain click's exact point -- can legitimately land on the border
    /// or the pad when a drag overshoots the panel.
    fn clampToText(o: *const Ocr, p: glyphwire.SelectionPoint) struct { row_idx: usize, byte_off: usize } {
        const panel_row = -p.above;
        const max_idx: i64 = @intCast(o.text.rows.len - 1);
        const row_idx: usize = @intCast(std.math.clamp(panel_row - 1, 0, max_idx));
        const row = o.text.rows[row_idx];
        const text_col: usize = if (p.col < 2) 0 else p.col - 2;
        return .{ .row_idx = row_idx, .byte_off = mokuro.columnToByte(row, text_col) };
    }

    /// Common tail of `wordLookupAt` and `lookupSelection`: takes a
    /// `dict_mod.lookup` result and keeps its first entry as
    /// `self.lookup`, dropping every other homograph here with its count
    /// carried as `extra` rather than shown in full. A no-op (clearing
    /// any open lookup) on no match, same as before this was shared.
    fn setLookupFromMatch(self: *Ui, m: ?dict_mod.Match) void {
        const match = m orelse return self.clearLookup();
        if (match.entries.len == 0) {
            dict_mod.freeEntries(self.alloc, match.entries);
            return self.clearLookup();
        }

        // Keep the first entry (its strings become `self.lookup`'s, so
        // it's not `deinit`'d).
        for (match.entries[1..]) |e| e.deinit(self.alloc);
        const kept = match.entries[0];
        const extra = match.entries.len - 1;
        self.alloc.free(match.entries);
        self.alloc.free(kept.rules);

        self.clearLookup();
        self.lookup = .{
            .term = kept.term,
            .reading = kept.reading,
            .glossary = kept.glossary,
            .reason = match.reason,
            .extra = extra,
        };
        self.lookup_dirty = true;
    }

    fn clearLookup(self: *Ui) void {
        const lk = self.lookup orelse return;
        self.alloc.free(lk.term);
        self.alloc.free(lk.reading);
        for (lk.glossary) |g| self.alloc.free(g);
        self.alloc.free(lk.glossary);
        self.lookup = null;
        self.lookup_dirty = true;
    }

    fn handleMouseMove(self: *Ui, ev: glyphwire.MouseMoveEvent) !void {
        if (self.text_drag) |*td| {
            // Clamped to the panel: dragging off its edge extends the
            // selection to the nearest cell inside rather than stopping.
            const o = &(self.ocr orelse return);
            const r = o.rect;
            if (r.rows == 0 or r.cols == 0) return;
            const row = std.math.clamp(ev.cell.row, r.row, r.row + r.rows - 1) - r.row;
            const col = std.math.clamp(ev.cell.col, r.col, r.col + r.cols - 1) - r.col;
            const active: glyphwire.SelectionPoint = .{ .above = -@as(i64, @intCast(row)), .col = col };
            td.active = active;
            if (active.above == td.anchor.above and active.col == td.anchor.col and !td.moved) return;
            td.moved = true;
            self.client.updateSelection(self.dialog_layer, active) catch {};
            return;
        }

        var started = self.drag orelse return;
        // Cell-granular, because that's what the pan offset is. The host
        // coalesces motion to cell changes anyway, so there's no finer
        // signal to act on here.
        const d_col = @as(i64, @intCast(started.cell.col)) - @as(i64, @intCast(ev.cell.col));
        const d_row = @as(i64, @intCast(started.cell.row)) - @as(i64, @intCast(ev.cell.row));
        if (d_col == 0 and d_row == 0) return;

        started.moved = true;
        self.drag = started;

        // Drag *the page*, not the viewport: pulling the pointer left
        // moves the page left, which means the window moves right.
        const row = zoom.clampPan(@as(i64, @intCast(started.pan_row)) + d_row, self.layout.max_pan_row);
        const col = zoom.clampPan(@as(i64, @intCast(started.pan_col)) + d_col, self.layout.max_pan_col);
        if (row == self.pan.row and col == self.pan.col) return;
        self.applyPan(row, col);
    }
};
