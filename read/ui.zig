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
const ai = @import("ai.zig");
const ai_cache = @import("ai_cache.zig");
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
    /// Cells per text row/column the last `renderDialog` drew at --
    /// `glyphwire.scaledPitch(Ui.ocr_scale)`. A panel point maps back to
    /// text by dividing by this (`Ui.dialogTextPos`).
    pitch: usize = 1,
    /// The clickable ` a:AI ` tag on the dialog's bottom border, in
    /// panel columns, when `ai_lookup` is on and the panel is wide enough
    /// to carry it.
    ai_tag: ?struct { col: usize, cols: usize } = null,

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

/// A dictionary lookup result shown in `Ui.dict_layer`. `match` holds
/// every ranked hit (owned by `Ui.alloc`; `Ui.clearLookup` frees it
/// before every replacement and on shutdown) -- not only homographs of
/// one word but shorter words off the same start, since
/// `dict_mod.lookup` collects every length the way Yomitan does. `hit`
/// picks which one is shown, cycled with `]`/`[` while the panel is up
/// (`Ui.cycleLookupHit`).
const Lookup = struct {
    match: dict_mod.Match,
    hit: usize = 0,
    /// Where the looked-up text began, as a byte offset into
    /// `Ocr.text.joined`. Every hit's span starts here and runs its own
    /// `source_len`, which is what the dialog's highlight follows as the
    /// shown hit changes (`Ui.highlightLookup`).
    source_start: usize,

    fn current(self: Lookup) dict_mod.Hit {
        return self.match.hits[self.hit];
    }

    fn count(self: Lookup) usize {
        return self.match.hits.len;
    }
};

/// The AI translation panel, shown in the dictionary panel's slot
/// (`Ui.dict_layer`) -- the two replace each other, never both. Opened
/// by `a` or a click on the dialog's ` a:AI ` tag (`Ui.startAi`).
const AiPanel = struct {
    phase: union(enum) {
        /// `ai_confirm_before_send`: the first send of the session waits
        /// here for Enter, naming where the text is about to go.
        confirm,
        /// A request is out. `future` runs `job.run`; `run` polls
        /// `job.done` once a tick and `Ui.cancelAi` cancels the future.
        sending: struct { job: *ai.Job, future: std.Io.Future(void), started: std.Io.Timestamp },
        /// Owned, already passed through `ai.plainText`.
        answer: []u8,
        /// Owned: why there is no answer.
        failure: []u8,
    },
    /// Owned. Kept for the send after a confirm, and for the cache write
    /// when the answer arrives.
    prompt: ai.Prompt,
    key: ai_cache.Key,
    /// What `ai_cache.Meta` records beside the answer. `highlight` is
    /// owned (or empty).
    page: usize,
    block: usize,
    highlight: []u8,
    /// Whole seconds shown on the sending panel, so `run` only redraws it
    /// when the count changes.
    shown_secs: u64 = 0,
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
    /// The AI panel, shown in the same slot. See `AiPanel`. At most one
    /// of `lookup` / `ai` is set.
    ai: ?AiPanel = null,
    /// Either side panel's content changed: `renderSide` redraws
    /// whichever one is up.
    side_dirty: bool = false,
    /// The side panel's on-screen rect in window cells (its *viewport*,
    /// when it scrolls), from the last `renderSide`. A press inside it is
    /// swallowed rather than panning or closing anything.
    side_rect: struct { row: usize = 0, col: usize = 0, rows: usize = 0, cols: usize = 0 } = .{},
    /// How far the side panel is scrolled, and how far it can be. Reset
    /// to the top whenever its content changes; the wheel reports it back
    /// through `scroll_offset`, PgUp/PgDn move it (`scrollSide`).
    side_scroll: usize = 0,
    side_max_scroll: usize = 0,
    /// Set by anything that replaces the side panel's content, so the
    /// next `renderSide` starts it at the top rather than keeping the
    /// previous content's offset.
    side_reset_scroll: bool = false,
    /// The lookup panel's title size -- `conf.dictionary_title_scale` at
    /// startup, cycled 1x -> 1.5x -> 2x -> 3x -> 1x by `s` for the rest of
    /// the session (`Ui.cycleDictTitleScale`).
    dict_title_scale: glyphwire.TextScale = .x1,
    /// The OCR dialog's text size -- `conf.ocr_text_scale` at startup,
    /// cycled by `S` (`Ui.cycleOcrScale`).
    ocr_scale: glyphwire.TextScale = .x1,

    /// The first AI send of the session has been confirmed (or
    /// `ai_confirm_before_send` is off). Never persisted: every session
    /// starts by asking again.
    ai_confirmed: bool = false,
    /// The answer cache, opened on first use. `ai_cache_failed` stops a
    /// broken cache file from being retried (and logged) on every send.
    ai_cache: ?ai_cache.Cache = null,
    ai_cache_failed: bool = false,
    /// glyphwire's config directory, where the cache lives. Borrowed from
    /// main.zig, which outlives the UI.
    config_dir: ?[]const u8 = null,
    /// The API key, read from `conf.ai_api_key_env` by main.zig. Borrowed
    /// from the environment map.
    ai_api_key: ?[]const u8 = null,

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
    /// A transient message shown in place of the page name -- a failed
    /// load, an out-of-range jump. Owned, cleared on the next keystroke.
    message: ?[]u8 = null,

    pub fn init(
        alloc: std.mem.Allocator,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        book: *archive_mod.Archive,
        conf: config_mod.ReadConfig,
        start: struct {
            page: usize,
            mode: zoom.Mode,
            direction: Direction,
            config_dir: ?[]const u8 = null,
            ai_api_key: ?[]const u8 = null,
        },
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
        // Nothing here takes typed text, so there's nowhere for a caret
        // to point.
        try client.setCaretVisible(false);

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

        // The letterbox around a fitted page: the root layer's background
        // colour, painted by the host under every cell -- once, rather
        // than a row of spaces per window row on every resize.
        try client.setLayerBackground(glyphwire.root_layer_handle, bg_page);
        // The panels' fill, so a row only has to write its border and its
        // text; the cells between composite as `bg_dialog`.
        try client.setLayerBackground(dialog_layer, bg_dialog);
        try client.setLayerBackground(dict_layer, bg_dialog);
        try client.setLayerBackground(dict_build_layer, bg_dialog);

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
            .dict_title_scale = conf.dictionary_title_scale,
            .ocr_scale = conf.ocr_text_scale,
            .ai_confirmed = !conf.ai_confirm_before_send,
            .config_dir = start.config_dir,
            .ai_api_key = start.ai_api_key,
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
        // Cancels a request still in flight: the job must be finished
        // before it is freed, and nobody is left to read its answer.
        self.clearAi();
        if (self.ai_cache) |*cch| cch.close();
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
            // One term bank file per tick rather than looping to
            // completion here: the wait below times out while a build is
            // running, so ticks keep coming with no input, and the reader
            // stays responsive (and `renderDictBuild` gets to actually
            // show a frame) the whole time a real dictionary is indexed.
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
            self.pollAi();
            if (self.page_dirty) try self.renderPage();
            // Both after the page: `renderPage` recomputes the layout the
            // marks and the dialog are placed against, and marks them
            // dirty when it does.
            if (self.hints_dirty) try self.renderHints();
            if (self.dialog_dirty) {
                try self.renderDialog();
                // The side panel is placed against the dialog's rect,
                // which may just have moved or resized.
                if (self.lookup != null or self.ai != null) self.side_dirty = true;
            }
            if (self.side_dirty) try self.renderSide();
            if (self.dict_build_dirty) try self.renderDictBuild();
            if (self.status_dirty) try self.renderStatus();
            if (self.quit) break;

            // Every notification wakes this, so with nothing to do in the
            // background it blocks outright; only a dictionary build (to
            // keep stepping) and an AI request (to notice it finishing and
            // tick the elapsed counter) need the timeout. Then everything
            // already queued is handled in arrival order before the next
            // frame.
            const timeout: std.Io.Timeout = if (self.dict_build != null or self.aiSending())
                .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }
            else
                .none;
            const first = try self.listener.next(timeout) orelse continue;
            try self.handleEvent(first);
            while (!self.quit) {
                const ev = self.listener.pollNext() orelse break;
                try self.handleEvent(ev);
            }
        }
    }

    fn handleEvent(self: *Ui, ev: glyphwire.Event) !void {
        defer ev.deinit(self.alloc);
        switch (ev) {
            .resize => |r| {
                self.win = .{ .cols = r.cols, .rows = r.rows };
                // A font-size step reflows the grid *and* changes the cell
                // metrics, and arrives as one resize -- so re-read them here
                // rather than only at startup.
                if (self.client.getCellMetrics()) |m| {
                    self.cell = .{ .w = m.w, .h = m.h };
                } else |_| {}
                self.page_dirty = true;
                self.status_dirty = true;
            },
            .scroll_offset => |so| {
                // The wheel or a scrollbar thumb over the page: the host has
                // already moved the viewport and is telling us where it
                // landed. Follow it rather than pushing our own value back --
                // but the *other* layer still has to be told, since the host
                // only moved the one under the pointer. That can be the marks
                // layer: it covers the page exactly and, while visible, is the
                // topmost thing `scrollablePaneAt` finds there.
                if (so.layer == self.page_layer or so.layer == self.hint_layer) {
                    self.pan = .{ .row = so.row, .col = so.col };
                    const other = if (so.layer == self.page_layer) self.hint_layer else self.page_layer;
                    self.client.setLayerScrollOffset(other, so.row, so.col) catch {};
                    self.status_dirty = true;
                } else if (so.layer == self.dict_layer) {
                    // The wheel over a side panel taller than its slot.
                    // Only remembered, so PgUp/PgDn continue from here.
                    self.side_scroll = so.row;
                }
            },
            .mouse_move => |m| try self.handleMouseMove(m),
            // `defer ev.deinit` above frees the button string.
            .mouse_button => |m| try self.handleMouseButton(m),
            else => if (ev.asInput()) |input| try self.handleInput(input),
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
            // Same for an AI answer, and a request still out for the old
            // bubble is cancelled rather than left to land on the new one.
            self.clearLookup();
            self.clearAi();
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
        self.clearAi();
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
        // the page layer stays in the default `host` scroll mode, the one
        // zoe's *tree* pane uses, so a grid bigger than the viewport is
        // all it takes to turn the bars and the wheel on.
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
            .{},
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
    fn emitMarkRow(self: *Ui, b: *glyphwire.Client.Batch, row: usize, col: usize, text: []const u8, fg: glyphwire.Color) !void {
        try b.writeTextOpts(text, .{ .layer = self.hint_layer, .row = row, .col = col, .fg = fg, .transparent_bg = true });
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
        // `ocr_dialog_cols` is the wrap width at 1x: a scaled dialog wraps
        // to the same characters a line and is `pitch` times wider --
        // unless that would run off the window, when it wraps sooner.
        const pitch = glyphwire.scaledPitch(self.ocr_scale);
        const inner_max = @max(@min(self.conf.ocr_dialog_cols -| 4, (self.win.cols -| 4) / pitch), 2);
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
        o.pitch = pitch;

        // The widest row decides the panel's width, capped at the wrap
        // width it was produced against -- in display columns, then
        // scaled to cells.
        var text_cols: usize = 1;
        for (rows) |r| text_cols = @max(text_cols, mokuro.displayWidth(r));
        text_cols = @min(text_cols, inner_max);
        // Wide enough for the AI tag when there is one: a one-word bubble
        // still needs somewhere to click.
        const tag_cols = mokuro.displayWidth(ai_tag);
        var inner = text_cols * pitch;
        if (self.conf.ai_lookup) inner = @max(inner, tag_cols + 2);
        // One pad column each side of the text, plus the two border cells.
        const interior = inner + 2;
        const box_cols = interior + 2;
        // A scaled row is `pitch` cells tall: the glyph draws down into
        // the rows below its own (see `core.TextScale`).
        const box_rows = rows.len * pitch + 2;

        const at = self.placeDialog(page, block.box, box_rows, box_cols);
        o.rect = .{ .row = at.row, .col = at.col, .rows = box_rows, .cols = box_cols };
        // Right-aligned on the bottom border, one border cell in from the
        // corner.
        o.ai_tag = if (self.conf.ai_lookup) .{ .col = box_cols - 2 - tag_cols, .cols = tag_cols } else null;

        var b = c.batch();
        defer b.deinit();

        try b.setLayerSize(self.dialog_layer, box_cols, box_rows);
        try b.setLayerCellPosition(self.dialog_layer, at.row, at.col);
        try b.clearOn(self.dialog_layer, 0, 0, null, null);

        // Allocated rather than a fixed buffer: a scaled dialog is up to
        // the window's width, which has no fixed ceiling.
        const h_line = try repeatAlloc(self.alloc, box_h, interior);
        defer self.alloc.free(h_line);

        try chromeAt(&b, self.dialog_layer, 0, 0, box_tl, fg_dialog_border, bg_dialog);
        try chromeOn(&b, self.dialog_layer, h_line, fg_dialog_border, bg_dialog);
        try chromeOn(&b, self.dialog_layer, box_tr, fg_dialog_border, bg_dialog);

        // Each text row is written as border, pad, text, pad-to-width,
        // border -- one run per piece, all with the panel's background, so
        // the row is opaque from edge to edge however short the text is.
        // The pad is measured in *display* columns because Japanese sets
        // two cells per character (`mokuro.displayWidth`).
        // The text is clipped and padded to the interior by the host
        // (`max_cols` + `pad`, in display columns, so CJK can't overrun
        // the border). A scaled row's extra rows below carry only their
        // border cells: the glyph's own fill already paints the rest.
        for (rows, 0..) |line, i| {
            const row = 1 + i * pitch;
            try chromeAt(&b, self.dialog_layer, row, 0, box_v_pad, fg_dialog_border, bg_dialog);
            try b.writeTextOpts(line, .{
                .layer = self.dialog_layer,
                .row = row,
                .col = 2,
                .fg = fg_dialog,
                .bg = bg_dialog,
                .scale = self.ocr_scale,
                .max_cols = inner,
                .pad = true,
            });
            try chromeAt(&b, self.dialog_layer, row, inner + 2, pad_box_v, fg_dialog_border, bg_dialog);
            for (1..pitch) |k| {
                try chromeAt(&b, self.dialog_layer, row + k, 0, box_v_pad, fg_dialog_border, bg_dialog);
                try chromeAt(&b, self.dialog_layer, row + k, inner + 2, pad_box_v, fg_dialog_border, bg_dialog);
            }
        }

        try chromeAt(&b, self.dialog_layer, box_rows - 1, 0, box_bl, fg_dialog_border, bg_dialog);
        try chromeOn(&b, self.dialog_layer, h_line, fg_dialog_border, bg_dialog);
        try chromeOn(&b, self.dialog_layer, box_br, fg_dialog_border, bg_dialog);
        if (o.ai_tag) |tag| try chromeAt(&b, self.dialog_layer, box_rows - 1, tag.col, ai_tag, fg_lookup_term, bg_dialog);

        // Both in the same batch, so the layer's first visible frame is
        // already the finished panel -- see `setHelp` for the same trick.
        try b.setLayerOpacity(self.dialog_layer, if (o.peeking) self.conf.ocr_peek else 1.0);
        try b.setLayerVisible(self.dialog_layer, true);

        var results = try b.send();
        results.deinit();

        // The lookup's highlight is in panel cells, which a re-wrap or a
        // new text scale (`S`) just moved.
        if (self.lookup != null) self.highlightLookup();
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

    /// One row of a side panel before it is laid out. A `scale`d row is
    /// `scaledPitch(scale)` cells tall and each of its display columns
    /// that many cells wide (see `core.TextScale`).
    const PanelLine = struct {
        text: []const u8,
        fg: glyphwire.Color = fg_dialog,
        scale: glyphwire.TextScale = .x1,
    };

    /// Widest an AI answer's panel wraps to. Wider than the dictionary
    /// panel's `ocr_dialog_cols`: the answer is English prose, which reads
    /// badly in a 36-column ribbon.
    const ai_panel_cols: usize = 64;

    /// Shortest a side panel is squeezed to before it gives up on staying
    /// clear of the OCR dialog and covers it instead (`placeSide`).
    const side_min_rows: usize = 5;

    /// Draws whichever side panel is up -- the AI panel if there is one,
    /// else the dictionary lookup -- or hides the slot.
    fn renderSide(self: *Ui) !void {
        self.side_dirty = false;
        if (self.ai != null) return self.renderAi();
        return self.renderLookup();
    }

    fn hideSide(self: *Ui) !void {
        self.side_rect = .{};
        self.side_max_scroll = 0;
        try self.client.setLayerVisible(self.dict_layer, false);
    }

    /// The wrap cap for a side panel's text: `cap` display columns, but
    /// never wider than the window leaves room for.
    fn sideInnerMax(self: *const Ui, cap: usize) usize {
        return @max(@min(cap, self.win.cols -| 4), 8);
    }

    /// Draws the dictionary lookup panel for `self.lookup`, or hides it
    /// when there's nothing to show.
    ///
    /// Follows the OCR dialog's own hide state (`o.hidden`): the panel is
    /// answering something *on* the dialog, so it has no business staying
    /// on screen after the thing it's annotating has gone.
    fn renderLookup(self: *Ui) !void {
        if (self.ocr) |o| if (o.hidden) return self.hideSide();
        const lk = self.lookup orelse return self.hideSide();
        const shown = lk.current();
        const entry = shown.entry;
        if (entry.term.len == 0) return self.hideSide();

        // Every wrapped row points into a buffer built here, so one arena
        // holds the lot until the panel has been sent.
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        // Subheader: the reading when that differs from the term itself
        // (kana-only entries have the same string in both), the
        // deinflection reason when this wasn't the dictionary form, and
        // -- when the lookup found more than one hit -- a "[hit/total]"
        // position, cycled with `]`/`[` (`Ui.cycleLookupHit`).
        var sub_buf: std.ArrayList(u8) = .empty;
        if (entry.reading.len > 0 and !std.mem.eql(u8, entry.reading, entry.term)) {
            try sub_buf.appendSlice(a, "\u{3010}");
            try sub_buf.appendSlice(a, entry.reading);
            try sub_buf.appendSlice(a, "\u{3011}");
        }
        if (shown.reason) |r| {
            if (sub_buf.items.len > 0) try sub_buf.append(a, ' ');
            try sub_buf.append(a, '(');
            try sub_buf.appendSlice(a, r);
            try sub_buf.append(a, ')');
        }
        if (lk.count() > 1) {
            if (sub_buf.items.len > 0) try sub_buf.append(a, ' ');
            try sub_buf.print(a, "[{d}/{d}]", .{ lk.hit + 1, lk.count() });
        }

        // Body: every sense joined onto one ribbon before wrapping, not
        // one row per sense -- a homograph can carry a dozen, and this
        // panel is meant to answer "what does this word mean", not
        // replace the dictionary. A long one scrolls (`drawSidePanel`).
        var body_buf: std.ArrayList(u8) = .empty;
        for (entry.glossary, 0..) |g, i| {
            if (i > 0) try body_buf.appendSlice(a, "; ");
            try body_buf.appendSlice(a, g);
        }

        const inner_max = self.sideInnerMax(self.conf.ocr_dialog_cols -| 4);
        const sub_rows = try mokuro.wrap(a, sub_buf.items, inner_max);
        const body_rows = try mokuro.wrap(a, body_buf.items, inner_max);

        // The term gets its own row at `dict_title_scale`: a scaled glyph
        // draws down into the rows below its own, so it can't share a row
        // with the subheader. `drawSidePanel` reserves those rows -- all
        // of them, which is what 3x used to overrun.
        var lines: std.ArrayList(PanelLine) = .empty;
        try lines.append(a, .{ .text = entry.term, .fg = fg_lookup_term, .scale = self.dict_title_scale });
        for (sub_rows) |r| try lines.append(a, .{ .text = r });
        // A blank separator row before the body, but only when there is
        // one -- the term (plus its subheader) is always shown.
        if (body_rows.len > 0) try lines.append(a, .{ .text = "" });
        for (body_rows) |r| try lines.append(a, .{ .text = r });

        try self.drawSidePanel(lines.items, inner_max);
    }

    /// Draws the AI panel for `self.ai` in the side slot: the first-send
    /// confirmation, the "sending" notice, the answer, or why there isn't
    /// one.
    fn renderAi(self: *Ui) !void {
        if (self.ocr) |o| if (o.hidden) return self.hideSide();
        const panel = self.ai orelse return self.hideSide();

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const inner_max = self.sideInnerMax(@max(self.conf.ocr_dialog_cols, ai_panel_cols) -| 4);
        const provider = self.conf.ai_provider;
        const model = self.conf.aiModel();
        var lines: std.ArrayList(PanelLine) = .empty;

        switch (panel.phase) {
            .confirm => {
                try lines.append(a, .{ .text = try std.fmt.allocPrint(a, "Send this bubble to {s}?", .{provider.label()}), .fg = fg_lookup_term });
                try lines.append(a, .{ .text = "" });
                // Spelled out, once a session: this is the moment text
                // leaves the machine.
                const neighbours = self.conf.ai_include_neighbor_dialog;
                const book_info = self.conf.ai_include_book_info;
                // `claude_code` has no URL to name: the text goes to
                // Anthropic through the CLI, on the user's own login.
                const dest = if (provider == .claude_code)
                    try std.fmt.allocPrint(a, "Anthropic through `{s} -p` on your Claude Code login", .{self.conf.aiEndpoint()})
                else
                    self.conf.aiEndpoint();
                const what = try std.fmt.allocPrint(a, "This bubble's OCR text{s}{s} will be sent to {s} ({s}). No images are sent.", .{
                    if (neighbours and book_info) ", the bubbles either side of it" else if (neighbours) " and the bubbles either side of it" else "",
                    if (book_info) " and the book's title and page number" else "",
                    dest,
                    model,
                });
                try appendWrapped(a, &lines, what, inner_max, fg_dialog);
                try lines.append(a, .{ .text = "" });
                try lines.append(a, .{ .text = "Enter  send        Esc  cancel", .fg = fg_dim });
            },
            .sending => |s| {
                try lines.append(a, .{ .text = try std.fmt.allocPrint(a, "Asking {s} ({s})...", .{ model, provider.label() }), .fg = fg_lookup_term });
                const secs = s.started.durationTo(std.Io.Clock.awake.now(self.client.io)).toSeconds();
                try lines.append(a, .{ .text = try std.fmt.allocPrint(a, "{d}s        Esc  cancel", .{secs}), .fg = fg_dim });
            },
            .answer => |text| {
                try lines.append(a, .{ .text = try std.fmt.allocPrint(a, "AI  {s}", .{model}), .fg = fg_lookup_term });
                try lines.append(a, .{ .text = "" });
                try appendWrapped(a, &lines, text, inner_max, fg_dialog);
            },
            .failure => |msg| {
                try lines.append(a, .{ .text = "AI lookup failed", .fg = fg_warn });
                try appendWrapped(a, &lines, msg, inner_max, fg_dialog);
            },
        }

        try self.drawSidePanel(lines.items, inner_max);
    }

    /// Wraps `text` paragraph by paragraph -- `mokuro.wrap` knows nothing
    /// of newlines -- keeping a blank line wherever the text has one.
    fn appendWrapped(a: std.mem.Allocator, lines: *std.ArrayList(PanelLine), text: []const u8, width: usize, fg: glyphwire.Color) !void {
        var paras = std.mem.splitScalar(u8, text, '\n');
        while (paras.next()) |para| {
            const rows = try mokuro.wrap(a, para, width);
            if (rows.len == 0) {
                try lines.append(a, .{ .text = "", .fg = fg });
                continue;
            }
            for (rows) |r| try lines.append(a, .{ .text = r, .fg = fg });
        }
    }

    /// Lays `lines` out as a bordered panel on `dict_layer`, placed by
    /// `placeSide`. The layer's grid holds the whole panel; when that is
    /// taller than the slot it gets, the *viewport* is the slot and the
    /// panel scrolls in the host's own scroll mode -- a grid bigger than
    /// its viewport is all it takes for the host to route the wheel to it
    /// and draw its scrollbar, exactly as for the page layer.
    ///
    /// `inner_cap` bounds the interior width; the panel is otherwise sized
    /// to its widest line.
    fn drawSidePanel(self: *Ui, lines: []const PanelLine, inner_cap: usize) !void {
        var inner: usize = 1;
        var content_rows: usize = 0;
        for (lines) |l| {
            const p = glyphwire.scaledPitch(l.scale);
            inner = @max(inner, mokuro.displayWidth(l.text) * p);
            content_rows += p;
        }
        inner = @min(inner, inner_cap);
        const interior = inner + 2;
        const box_cols = interior + 2;
        const box_rows = content_rows + 2;

        const slot = self.placeSide(box_rows, box_cols);
        self.side_max_scroll = box_rows - slot.rows;
        if (self.side_reset_scroll) {
            self.side_scroll = 0;
            self.side_reset_scroll = false;
        }
        self.side_scroll = @min(self.side_scroll, self.side_max_scroll);
        self.side_rect = .{ .row = slot.row, .col = slot.col, .rows = slot.rows, .cols = box_cols };

        const layer = self.dict_layer;
        var b = self.client.batch();
        defer b.deinit();

        try b.setLayerSize(layer, box_cols, box_rows);
        try b.setLayerViewport(layer, box_cols, slot.rows);
        try b.setLayerScrollbars(layer, self.side_max_scroll > 0, false);
        try b.setLayerScrollOffset(layer, self.side_scroll, 0);
        try b.setLayerCellPosition(layer, slot.row, slot.col);
        try b.clearOn(layer, 0, 0, null, null);

        const h_line = try repeatAlloc(self.alloc, box_h, interior);
        defer self.alloc.free(h_line);

        try chromeAt(&b, layer, 0, 0, box_tl, fg_dialog_border, bg_dialog);
        try chromeOn(&b, layer, h_line, fg_dialog_border, bg_dialog);
        try chromeOn(&b, layer, box_tr, fg_dialog_border, bg_dialog);

        var row: usize = 1;
        for (lines) |l| {
            const p = glyphwire.scaledPitch(l.scale);
            try writePanelRow(&b, layer, row, l.text, inner, l.fg, l.scale);
            // The rows a scaled glyph draws down into carry only their
            // border cells; its own fill paints the rest.
            for (1..p) |k| {
                try chromeAt(&b, layer, row + k, 0, box_v, fg_dialog_border, bg_dialog);
                try chromeAt(&b, layer, row + k, inner + 3, box_v, fg_dialog_border, bg_dialog);
            }
            row += p;
        }

        try chromeAt(&b, layer, box_rows - 1, 0, box_bl, fg_dialog_border, bg_dialog);
        try chromeOn(&b, layer, h_line, fg_dialog_border, bg_dialog);
        try chromeOn(&b, layer, box_br, fg_dialog_border, bg_dialog);

        try b.setLayerOpacity(layer, if (self.ocr) |o| (if (o.peeking) self.conf.ocr_peek else 1.0) else 1.0);
        try b.setLayerVisible(layer, true);

        var results = try b.send();
        results.deinit();
    }

    /// Where a side panel `rows` x `cols` goes, and how many rows of it
    /// are visible: below the OCR dialog when it fits, above when that
    /// fits instead, left-aligned with the dialog and always wholly on
    /// screen. A panel that fits neither side takes whichever side is
    /// bigger and scrolls; only when neither side has even
    /// `side_min_rows` does it give up and cover the dialog.
    fn placeSide(self: *const Ui, rows: usize, cols: usize) struct { row: usize, col: usize, rows: usize } {
        const view = self.pageView();
        const anchor_row: usize = if (self.ocr) |o| o.rect.row else 0;
        const anchor_col: usize = if (self.ocr) |o| o.rect.col else 0;
        const anchor_rows: usize = if (self.ocr) |o| o.rect.rows else 0;

        const col = @min(anchor_col, view.cols -| cols);
        const below = anchor_row + anchor_rows;
        const below_space = view.rows -| below;
        const above_space = @min(anchor_row, view.rows);

        if (rows <= below_space) return .{ .row = below, .col = col, .rows = rows };
        if (rows <= above_space) return .{ .row = anchor_row - rows, .col = col, .rows = rows };
        if (below_space >= above_space and below_space >= side_min_rows)
            return .{ .row = below, .col = col, .rows = below_space };
        if (above_space >= side_min_rows) return .{ .row = 0, .col = col, .rows = above_space };
        const fit = @max(@min(rows, view.rows), 1);
        return .{ .row = view.rows -| fit, .col = col, .rows = fit };
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

        try batch.setLayerSize(self.dict_build_layer, box_cols, box_rows);
        try batch.setLayerCellPosition(self.dict_build_layer, (self.win.rows -| box_rows) / 2, (self.win.cols -| box_cols) / 2);
        try batch.clearOn(self.dict_build_layer, 0, 0, null, null);

        var h_buf: [config_mod.ocr_dialog_cols_max * box_h.len]u8 = undefined;
        const h_line = repeatInto(&h_buf, box_h, interior);

        try chromeAt(&batch, self.dict_build_layer, 0, 0, box_tl, fg_dialog_border, bg_dialog);
        try chromeOn(&batch, self.dict_build_layer, h_line, fg_dialog_border, bg_dialog);
        try chromeOn(&batch, self.dict_build_layer, box_tr, fg_dialog_border, bg_dialog);

        try writePanelRow(&batch, self.dict_build_layer, 1, line1, inner, fg_dialog, .x1);
        try writePanelRow(&batch, self.dict_build_layer, 2, line2, inner, fg_dialog, .x1);

        try chromeAt(&batch, self.dict_build_layer, box_rows - 1, 0, box_bl, fg_dialog_border, bg_dialog);
        try chromeOn(&batch, self.dict_build_layer, h_line, fg_dialog_border, bg_dialog);
        try chromeOn(&batch, self.dict_build_layer, box_br, fg_dialog_border, bg_dialog);

        try batch.setLayerVisible(self.dict_build_layer, true);

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
        "  S                    cycle the dialog's text size",
        "  click a word         dictionary lookup",
        "  ] / [                other matches of the lookup",
        "  s                    cycle the lookup title size",
        "  a                    AI translation of the bubble",
        "  page_up / page_down  scroll a long lookup / answer",
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
    /// A text row's left and right edges: the border plus its one-cell
    /// pad, written as one chrome run so the pad is unselectable too and
    /// a wrapped selection's tint starts at the text, not the pad.
    const box_v_pad = box_v ++ " ";
    const pad_box_v = " " ++ box_v;

    /// `s` repeated `n` times into `buf` (sized by the caller for exactly
    /// that many copies) -- used to draw a solid horizontal border run
    /// without a `zig 0.17` `**` repeat operator, which no longer exists.
    fn repeatInto(buf: []u8, s: []const u8, n: usize) []const u8 {
        var i: usize = 0;
        while (i < n) : (i += 1) @memcpy(buf[i * s.len ..][0 .. s.len], s);
        return buf[0 .. n * s.len];
    }

    /// `repeatInto`, into a caller-freed allocation -- for a border whose
    /// width follows the window rather than a config cap.
    fn repeatAlloc(alloc: std.mem.Allocator, s: []const u8, n: usize) ![]u8 {
        const buf = try alloc.alloc(u8, n * s.len);
        _ = repeatInto(buf, s, n);
        return buf;
    }

    /// The OCR dialog's clickable AI tag, drawn into its bottom border
    /// when `ai_lookup` is on. Names the key that does the same thing.
    const ai_tag = " a:AI ";

    /// Panel chrome (border, pad, the AI tag) on `layer` at `(row, col)`,
    /// queued on `b`. Written `selectable = false`, so a selection over
    /// the panel tints and copies only the text inside it
    /// (`core.Cell.selectable`).
    fn chromeAt(b: *glyphwire.Client.Batch, layer: glyphwire.LayerHandle, row: usize, col: usize, text: []const u8, fg: glyphwire.Color, bg: glyphwire.Color) !void {
        try b.writeTextOpts(text, .{ .layer = layer, .row = row, .col = col, .fg = fg, .bg = bg, .selectable = false });
    }

    /// `chromeAt` continuing from wherever the last write left the
    /// cursor.
    fn chromeOn(b: *glyphwire.Client.Batch, layer: glyphwire.LayerHandle, text: []const u8, fg: glyphwire.Color, bg: glyphwire.Color) !void {
        try b.writeTextOpts(text, .{ .layer = layer, .fg = fg, .bg = bg, .selectable = false });
    }

    /// One panel row -- border, text, border -- the piece every bordered
    /// panel repeats once per line. The text is clipped and padded to the
    /// interior by the host (`max_cols` + `pad`, in display columns, so a
    /// CJK line can't overrun the border); the one-cell pad either side is
    /// written with its border as chrome, so a selection skips it. A
    /// `scale`d row is still one write: the
    /// host advances each glyph by its scaled width and fills the cells
    /// it steps over, the rows below included (`core.TextScale`) -- the
    /// caller leaves those rows alone apart from their borders.
    fn writePanelRow(
        b: *glyphwire.Client.Batch,
        layer: glyphwire.LayerHandle,
        row: usize,
        text: []const u8,
        inner: usize,
        fg: glyphwire.Color,
        scale: glyphwire.TextScale,
    ) !void {
        try chromeAt(b, layer, row, 0, box_v_pad, fg_dialog_border, bg_dialog);
        try b.writeTextOpts(text, .{
            .layer = layer,
            .row = row,
            .col = 2,
            .fg = fg,
            .bg = bg_dialog,
            .scale = scale,
            .max_cols = inner,
            .pad = true,
        });
        try chromeAt(b, layer, row, inner + 2, pad_box_v, fg_dialog_border, bg_dialog);
    }

    /// Queues the dialog's full redraw (border + every line) onto `b`
    /// rather than sending each piece as its own notification: a
    /// half-drawn dialog would otherwise be visible for a frame between
    /// round trips, which is what caused the flicker the character
    /// border replaced the 9-patch with -- see `setHelp`, which folds
    /// the `visibility` flip into the same batch on open so the layer's
    /// very first visible frame is already the finished dialog.
    fn buildHelp(self: *Ui, b: *glyphwire.Client.Batch) !void {
        try b.setLayerCellPosition(self.help_layer, (self.win.rows -| help_rows) / 2, (self.win.cols -| help_cols) / 2);
        try b.clearOn(self.help_layer, 0, 0, null, null);

        var h_buf: [help_interior * box_h.len]u8 = undefined;
        const h_line = repeatInto(&h_buf, box_h, help_interior);

        try chromeAt(b, self.help_layer, 0, 0, box_tl, fg_status, bg_status);
        try chromeOn(b, self.help_layer, h_line, fg_status, bg_status);
        try chromeOn(b, self.help_layer, box_tr, fg_status, bg_status);

        var line_buf: [help_interior]u8 = undefined;
        for (help_lines, 0..) |line, i| {
            const keep = @min(line.len, help_interior);
            @memcpy(line_buf[0..keep], line[0..keep]);
            @memset(line_buf[keep..], ' ');

            try chromeAt(b, self.help_layer, i + 1, 0, box_v, fg_status, bg_status);
            try b.writeTextOpts(&line_buf, .{ .layer = self.help_layer, .fg = fg_status, .bg = bg_status });
            try chromeOn(b, self.help_layer, box_v, fg_status, bg_status);
        }

        try chromeAt(b, self.help_layer, help_rows - 1, 0, box_bl, fg_status, bg_status);
        try chromeOn(b, self.help_layer, h_line, fg_status, bg_status);
        try chromeOn(b, self.help_layer, box_br, fg_status, bg_status);
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
            .key => |k| if (k.pressed) try self.handleKey(k) else try self.handleKeyRelease(k.key),
            .text => |t| try self.handleText(t.text),
            .shutdown => self.quit = true,
            else => {},
        }
    }

    fn handleKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const key = k.key;
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

        // Off the event, as it was pressed -- not the live down-set.
        const shift = k.shift();

        // ── AI panel ──
        // The first-send confirmation takes Enter (or `a` again) and
        // Escape; a request in flight takes Escape as "cancel". Both before
        // the quit block, so that Escape doesn't close the dialog instead.
        if (self.ai) |panel| switch (panel.phase) {
            .confirm => {
                if (eq(u8, key, "enter") or eq(u8, key, "kp_enter") or eq(u8, key, "a")) return self.confirmAi();
                if (eq(u8, key, "escape")) return self.clearAi();
            },
            .sending => if (eq(u8, key, "escape")) {
                self.clearAi();
                try self.setMessage("AI request cancelled", .{});
                self.status_dirty = true;
                return;
            },
            else => {},
        };
        if (eq(u8, key, "a")) return self.startAi();
        // A side panel taller than its slot captures the page keys for as
        // long as it has somewhere to scroll -- the same "capture while
        // there's something to do" rule `]`/`[` follow for lookup hits.
        if (self.side_max_scroll > 0) {
            if (eq(u8, key, "page_down")) return self.scrollSide(.down);
            if (eq(u8, key, "page_up")) return self.scrollSide(.up);
        }

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
        if (eq(u8, key, "s")) return if (shift) self.cycleOcrScale() else self.cycleDictTitleScale();

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
        // `side_dirty`: the panels' contents haven't changed, only how
        // they composite, and a full redraw per keypress would be a lot
        // of writes for a fade.
        const opacity: f32 = if (on) self.conf.ocr_peek else 1.0;
        self.client.setLayerOpacity(self.dialog_layer, opacity) catch {};
        if (self.lookup != null or self.ai != null) self.client.setLayerOpacity(self.dict_layer, opacity) catch {};
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
        if (self.lookup != null or self.ai != null) self.side_dirty = true;
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
        // While the lookup panel is showing more than one homograph,
        // `]`/`[` cycle through them instead of jumping pages -- the
        // panel "captures" the keys for as long as there's something to
        // cycle, same as `goto_prompt` captures every key above.
        if (self.lookup) |lk| if (lk.count() > 1) {
            if (eq(u8, text, "]")) return self.cycleLookupHit(1);
            if (eq(u8, text, "[")) return self.cycleLookupHit(-1);
        };
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
            try b.setLayerVisible(self.help_layer, true);
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
            // A press on the side panel is reading it (or reaching for
            // its scrollbar), not a click on the page behind it -- which
            // would pan, turn the page, or close the dialog the panel
            // belongs to.
            if (self.onSidePanel(ev.cell)) return;
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
            } else if (self.onAiTag(td.anchor)) {
                // The ` a:AI ` tag: the same as pressing `a`. The zero-
                // width selection goes, but a highlighted lookup word
                // stays selected -- it is part of what gets asked about.
                if (self.lookup == null) self.client.clearSelection(self.dialog_layer) catch {};
                self.startAi();
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

    fn onSidePanel(self: *const Ui, cell: glyphwire.CellPos) bool {
        if (self.lookup == null and self.ai == null) return false;
        const r = self.side_rect;
        if (r.rows == 0 or r.cols == 0) return false;
        return cell.row >= r.row and cell.row < r.row + r.rows and cell.col >= r.col and cell.col < r.col + r.cols;
    }

    /// Whether dialog-local point `p` is on the ` a:AI ` tag in the
    /// dialog's bottom border.
    fn onAiTag(self: *const Ui, p: glyphwire.SelectionPoint) bool {
        const o = &(self.ocr orelse return false);
        const tag = o.ai_tag orelse return false;
        if (-p.above != @as(i64, @intCast(o.rect.rows -| 1))) return false;
        return p.col >= tag.col and p.col < tag.col + tag.cols;
    }

    /// Text row and display column under dialog-local point `p`, or null
    /// on the border/pad or past the last row. Row 0 is the border and
    /// column 0/1 the border and pad, so text starts at (1, 2); a scaled
    /// dialog's rows and columns are `o.pitch` cells each.
    fn dialogTextPos(o: *const Ocr, p: glyphwire.SelectionPoint) ?struct { row_idx: usize, col: usize } {
        const panel_row = -p.above;
        if (panel_row < 1 or p.col < 2) return null;
        const row_idx: usize = @intCast(@divTrunc(panel_row - 1, @as(i64, @intCast(o.pitch))));
        if (row_idx >= o.text.rows.len) return null;
        return .{ .row_idx = row_idx, .col = (p.col - 2) / o.pitch };
    }

    /// Resolves a stationary click at dialog-local point `p` (see
    /// `dialogPoint`) to a word and looks it up, replacing -- or, on no
    /// match, clearing -- `self.lookup`. A no-op with no dictionary
    /// loaded; also a no-op (clearing any open lookup) when the click
    /// landed on the border/pad rather than on text, since that's not a
    /// word either.
    ///
    /// No tokenizing happens here: `dict.lookup` is handed everything
    /// from the click point to the end of the *bubble* (`Ocr.text.joined`,
    /// not just the wrapped row, so a word split across a wrap is still
    /// found whole) and tries every prefix itself, the same trick Yomitan
    /// uses since Japanese has no spaces to split words on. The span of
    /// the hit being shown is then selected on the dialog layer
    /// (`highlightLookup`).
    fn wordLookupAt(self: *Ui, p: glyphwire.SelectionPoint) void {
        const d = &(self.dict orelse return);
        const o = &(self.ocr orelse return);

        const pos = dialogTextPos(o, p) orelse return self.clearLookup();
        const row = o.text.rows[pos.row_idx];
        const byte_off = mokuro.columnToByte(row, pos.col);
        if (byte_off >= row.len) return self.clearLookup();

        const start = mokuro.rowOffset(o.text.joined, row) + byte_off;
        const m = dict_mod.lookup(self.alloc, d, o.text.joined[start..]) catch null;
        self.setLookupFromMatch(m, start);
    }

    /// Resolves a completed drag inside the dialog (`a`/`b`, the anchor
    /// and release point, in either order) to source text and looks it
    /// up. The dragged text is the longest thing `dict.lookup` tries, so
    /// an exact match on it ranks first; shorter prefixes of it follow
    /// only as fallbacks, for a drag that overshot the word.
    ///
    /// The selection's end is inclusive -- the character under the
    /// release cell is part of it -- so the byte range runs to the end
    /// of that character (`mokuro.charEnd`), not to its start. (Treating
    /// it as exclusive used to drop the last character, so dragging over
    /// 面白い looked up 面白 and landed on 面.)
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
        const row_second = o.text.rows[second.row_idx];
        const abs_start = mokuro.rowOffset(joined, o.text.rows[first.row_idx]) + first.byte_off;
        const abs_end = mokuro.rowOffset(joined, row_second) + mokuro.charEnd(row_second, second.byte_off);
        if (abs_end <= abs_start) return self.clearLookup();

        const m = dict_mod.lookup(self.alloc, d, joined[abs_start..abs_end]) catch null;
        self.setLookupFromMatch(m, abs_start);
    }

    /// Clamps dialog-local point `p` to the nearest text cell: rows above
    /// the first text row (or below the last) clamp to that row, and
    /// `mokuro.columnToByte` already clamps a column past a row's own
    /// width to its end. Used for selection endpoints, which -- unlike a
    /// plain click's exact point -- can legitimately land on the border
    /// or the pad when a drag overshoots the panel.
    fn clampToText(o: *const Ocr, p: glyphwire.SelectionPoint) struct { row_idx: usize, byte_off: usize } {
        const pitch: i64 = @intCast(o.pitch);
        const panel_row = -p.above;
        const max_idx: i64 = @intCast(o.text.rows.len - 1);
        const row_idx: usize = @intCast(std.math.clamp(@divFloor(panel_row - 1, pitch), 0, max_idx));
        const row = o.text.rows[row_idx];
        const text_col: usize = if (p.col < 2) 0 else (p.col - 2) / o.pitch;
        return .{ .row_idx = row_idx, .byte_off = mokuro.columnToByte(row, text_col) };
    }

    /// Common tail of `wordLookupAt` and `lookupSelection`: keeps every
    /// ranked hit as `self.lookup`, shown one at a time via `hit` (`]`/`[`
    /// cycle through them, `cycleLookupHit`), and highlights the best
    /// one's span. `source_start` is where the looked-up text began in
    /// `Ocr.text.joined`. Clears any open lookup on no match.
    fn setLookupFromMatch(self: *Ui, m: ?dict_mod.Match, source_start: usize) void {
        const match = m orelse return self.clearLookup();
        self.clearLookup();
        // The two share a slot: a dictionary click replaces an AI answer
        // (and cancels a request still out).
        self.clearAi();
        self.lookup = .{ .match = match, .source_start = source_start };
        self.side_dirty = true;
        self.side_reset_scroll = true;
        self.highlightLookup();
    }

    /// Selects the shown hit's span on the dialog layer -- the same as
    /// dragging it by hand -- so it's visible which word the panel is
    /// answering for, and Ctrl+Shift+C copies exactly that. Hits cover
    /// different lengths (食べ物, then 食べる, then 食), so this runs again
    /// on every `]`/`[` and the highlight resizes to match.
    fn highlightLookup(self: *Ui) void {
        const lk = self.lookup orelse return;
        const o = &(self.ocr orelse return);
        const start = lk.source_start;
        const span = mokuro.spanCells(o.text.joined, o.text.rows, start, start + lk.current().source_len) orelse return;
        // Text rows are 1-based on the panel (row 0 is the border) and
        // text columns start at 2 (border, then pad) -- see
        // `dialogTextPos`. At scale each display column is `pitch` cells,
        // and the inclusive end runs to the last of them. Both ends sit
        // on glyph rows; the host extends the tint down over the rows a
        // scaled glyph draws into (`core.Cell.under_scaled`).
        const pitch = o.pitch;
        const first: glyphwire.SelectionPoint = .{ .above = -@as(i64, @intCast(span.first.row * pitch + 1)), .col = span.first.col * pitch + 2 };
        const last: glyphwire.SelectionPoint = .{ .above = -@as(i64, @intCast(span.last.row * pitch + 1)), .col = span.last.col * pitch + pitch - 1 + 2 };
        self.client.setSelection(self.dialog_layer, first, last) catch {};
    }

    fn clearLookup(self: *Ui) void {
        const lk = self.lookup orelse return;
        lk.match.deinit(self.alloc);
        self.lookup = null;
        self.side_dirty = true;
    }

    /// `]`/`[` while the lookup panel is showing more than one hit --
    /// see `Ui.handleText`, which only routes here instead of its own
    /// page-jump binding when that condition holds. Wraps at both ends.
    fn cycleLookupHit(self: *Ui, delta: i64) void {
        if (self.lookup == null) return;
        const n: i64 = @intCast(self.lookup.?.count());
        if (n <= 1) return;
        const idx = @mod(@as(i64, @intCast(self.lookup.?.hit)) + delta, n);
        self.lookup.?.hit = @intCast(idx);
        self.side_dirty = true;
        self.side_reset_scroll = true;
        self.highlightLookup();
    }

    /// `s` -- cycles the lookup panel's title size for the rest of the
    /// session (`conf.dictionary_title_scale` is only the starting
    /// value). Redraws immediately if a lookup is already showing.
    fn cycleDictTitleScale(self: *Ui) void {
        self.dict_title_scale = switch (self.dict_title_scale) {
            .x1 => .x1_5,
            .x1_5 => .x2,
            .x2 => .x3,
            .x3 => .x1,
        };
        if (self.lookup != null) self.side_dirty = true;
    }

    /// `S` -- cycles the OCR dialog's text size for the rest of the
    /// session (`conf.ocr_text_scale` is only the starting value).
    fn cycleOcrScale(self: *Ui) void {
        self.ocr_scale = nextScale(self.ocr_scale);
        const o = &(self.ocr orelse return);
        // A drag in progress was measured against the old layout.
        self.text_drag = null;
        if (o.at != null) self.dialog_dirty = true;
    }

    fn nextScale(s: glyphwire.TextScale) glyphwire.TextScale {
        return switch (s) {
            .x1 => .x1_5,
            .x1_5 => .x2,
            .x2 => .x3,
            .x3 => .x1,
        };
    }

    /// PgUp/PgDn over a side panel taller than its slot: a slot's worth
    /// at a time, less one row so the reader keeps their place.
    fn scrollSide(self: *Ui, dir: enum { up, down }) void {
        const step = @max(self.side_rect.rows -| 1, 1);
        self.side_scroll = switch (dir) {
            .up => self.side_scroll -| step,
            .down => @min(self.side_scroll + step, self.side_max_scroll),
        };
        self.client.setLayerScrollOffset(self.dict_layer, self.side_scroll, 0) catch {};
    }

    // -- AI lookup --------------------------------------------------------

    fn aiSending(self: *const Ui) bool {
        const panel = self.ai orelse return false;
        return panel.phase == .sending;
    }

    /// `a`, or a click on the dialog's ` a:AI ` tag: ask about the open
    /// bubble. Opens the AI panel in the side slot and, in order: answers
    /// from the cache when it can (no confirm, nothing sent), reports a
    /// missing API key, waits on the first-send confirmation, or sends.
    fn startAi(self: *Ui) void {
        if (!self.conf.ai_lookup) {
            self.setMessage("AI lookup is off -- set ai_lookup = true in read.conf.lua", .{}) catch {};
            self.status_dirty = true;
            return;
        }
        const o = &(self.ocr orelse return);
        if (o.current() == null or o.hidden) return;
        // One request at a time; `a` again while it's out is a no-op
        // rather than a second bill.
        if (self.aiSending()) return;
        self.openAi(o) catch |err| {
            self.setMessage("AI lookup failed ({t})", .{err}) catch {};
            self.status_dirty = true;
        };
    }

    fn openAi(self: *Ui, o: *Ocr) !void {
        const alloc = self.alloc;
        const page = o.page orelse return;
        const at = o.at orelse return;
        const block = o.current() orelse return;

        const dialog = try mokuro.joinLines(alloc, block.lines);
        defer alloc.free(dialog);

        // The bubbles either side in reading order, when asked for --
        // context for a line that only makes sense as a reply.
        var previous: ?[]u8 = null;
        defer if (previous) |p| alloc.free(p);
        var next: ?[]u8 = null;
        defer if (next) |n| alloc.free(n);
        if (self.conf.ai_include_neighbor_dialog) {
            if (at > 0) previous = try mokuro.joinLines(alloc, page.blocks[o.order.items[at - 1]].lines);
            if (at + 1 < o.order.items.len) next = try mokuro.joinLines(alloc, page.blocks[o.order.items[at + 1]].lines);
        }

        // The word the dictionary panel is showing, when there is one --
        // read out before `clearLookup` below drops it.
        const highlight = try alloc.dupe(u8, if (self.lookup) |lk| blk: {
            const end = @min(lk.source_start + lk.current().source_len, o.text.joined.len);
            break :blk o.text.joined[@min(lk.source_start, end)..end];
        } else "");
        errdefer alloc.free(highlight);

        const prompt = try ai.buildPrompt(alloc, self.conf.ai_prompt, .{
            .dialog = dialog,
            .highlight = if (highlight.len > 0) highlight else null,
            .previous = previous,
            .next = next,
            .title = if (self.conf.ai_include_book_info) ai.bookTitle(self.book.path) else null,
            .page = if (self.conf.ai_include_book_info) self.page + 1 else null,
        });
        errdefer prompt.deinit(alloc);

        self.clearLookup();
        self.clearAi();
        self.ai = .{
            .phase = .confirm,
            .prompt = prompt,
            .key = ai_cache.key(self.conf.ai_provider, self.conf.aiModel(), prompt),
            .page = self.page + 1,
            .block = at,
            .highlight = highlight,
        };
        self.side_dirty = true;
        self.side_reset_scroll = true;
        const panel = &self.ai.?;

        if (self.cacheGet(panel.key)) |text| {
            panel.phase = .{ .answer = text };
            return;
        }
        if (self.conf.ai_provider.needsKey() and self.ai_api_key == null) {
            panel.phase = .{ .failure = try std.fmt.allocPrint(
                alloc,
                "No API key: ${s} is not set. Export it before starting gw-read, or point ai_api_key_env at the variable that holds it.",
                .{self.conf.aiApiKeyEnv()},
            ) };
            return;
        }
        // Stays on `.confirm` until Enter.
        if (!self.ai_confirmed) return;
        self.sendAi();
    }

    /// Enter on the confirmation: send, and don't ask again this session.
    fn confirmAi(self: *Ui) void {
        self.ai_confirmed = true;
        self.sendAi();
    }

    /// Starts the request for `self.ai`'s prompt on a background task.
    fn sendAi(self: *Ui) void {
        const panel = &(self.ai orelse return);
        const alloc = self.alloc;
        const io = self.client.io;
        const provider = self.conf.ai_provider;

        const job = ai.Job.create(alloc, io, .{
            .provider = provider,
            .endpoint = self.conf.aiEndpoint(),
            .model = self.conf.aiModel(),
            .api_key = if (provider.needsKey()) self.ai_api_key else null,
            .prompt = panel.prompt,
        }) catch return self.failAi("out of memory building the request");
        const future = io.concurrent(ai.Job.run, .{job}) catch |err| {
            job.destroy();
            const msg = std.fmt.allocPrint(alloc, "couldn't start the request ({t})", .{err}) catch return;
            panel.phase = .{ .failure = msg };
            self.side_dirty = true;
            return;
        };
        panel.phase = .{ .sending = .{ .job = job, .future = future, .started = std.Io.Clock.awake.now(io) } };
        panel.shown_secs = 0;
        self.side_dirty = true;
    }

    fn failAi(self: *Ui, msg: []const u8) void {
        const panel = &(self.ai orelse return);
        const copy = self.alloc.dupe(u8, msg) catch return;
        panel.phase = .{ .failure = copy };
        self.side_dirty = true;
    }

    /// Once a tick while a request is out: collect it when it's done,
    /// otherwise keep the elapsed counter on the panel current.
    fn pollAi(self: *Ui) void {
        const panel = &(self.ai orelse return);
        const sending = switch (panel.phase) {
            .sending => |s| s,
            else => return,
        };
        const io = self.client.io;
        if (!sending.job.done.load(.acquire)) {
            const secs: u64 = @intCast(@max(sending.started.durationTo(std.Io.Clock.awake.now(io)).toSeconds(), 0));
            if (secs != panel.shown_secs) {
                panel.shown_secs = secs;
                self.side_dirty = true;
            }
            return;
        }

        var future = sending.future;
        future.await(io);
        const result = sending.job.takeResult();
        sending.job.destroy();

        self.side_dirty = true;
        self.side_reset_scroll = true;
        const answer = result orelse return self.failAi("the request produced no result");
        switch (answer) {
            .failure => |msg| panel.phase = .{ .failure = msg },
            .text => |raw| {
                defer self.alloc.free(raw);
                const text = ai.plainText(self.alloc, raw) catch return self.failAi("out of memory");
                panel.phase = .{ .answer = text };
                self.cachePut(panel);
            },
        }
    }

    /// Drops the AI panel. A request still out is cancelled -- the
    /// future is cancelled and awaited before its job is freed, so the
    /// background task never touches freed memory.
    fn clearAi(self: *Ui) void {
        const panel = &(self.ai orelse return);
        switch (panel.phase) {
            .sending => |s| {
                var future = s.future;
                future.cancel(self.client.io);
                s.job.destroy();
            },
            .answer, .failure => |text| self.alloc.free(text),
            .confirm => {},
        }
        panel.prompt.deinit(self.alloc);
        self.alloc.free(panel.highlight);
        self.ai = null;
        self.side_dirty = true;
    }

    /// The cache, opened on first use. Null when caching is off, there's
    /// no config directory to keep it in, or it failed to open once
    /// already this session.
    fn aiCache(self: *Ui) ?*ai_cache.Cache {
        if (!self.conf.ai_cache or self.ai_cache_failed) return null;
        if (self.ai_cache) |*cch| return cch;
        const dir = self.config_dir orelse return null;
        const path = std.fs.path.joinZ(self.alloc, &.{ dir, ai_cache.file_name }) catch return null;
        defer self.alloc.free(path);
        // SQLite does its own file I/O and won't create the directory.
        std.Io.Dir.cwd().createDirPath(self.client.io, dir) catch {};
        self.ai_cache = ai_cache.Cache.open(path) catch |err| {
            std.log.warn("gw-read: couldn't open the AI cache '{s}' ({t}); answers won't be kept", .{ path, err });
            self.ai_cache_failed = true;
            return null;
        };
        return &self.ai_cache.?;
    }

    fn cacheGet(self: *Ui, key: ai_cache.Key) ?[]u8 {
        const cch = self.aiCache() orelse return null;
        return cch.get(self.alloc, key) catch null;
    }

    fn cachePut(self: *Ui, panel: *const AiPanel) void {
        const text = switch (panel.phase) {
            .answer => |t| t,
            else => return,
        };
        const cch = self.aiCache() orelse return;
        cch.put(panel.key, text, .{
            .title = ai.bookTitle(self.book.path),
            .page = panel.page,
            .block = panel.block,
            .highlight = panel.highlight,
            .provider = self.conf.ai_provider,
            .model = self.conf.aiModel(),
        }) catch |err| std.log.warn("gw-read: couldn't cache the AI answer ({t})", .{err});
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
