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
//! showing the filtered matches. The list is a *self-scrolling* pane in
//! the sense `docs/api.md`'s Layer section describes: it stays sized to
//! the visible rows and redraws whichever slice is in view rather than
//! growing to hold every match, while `content_extent` + `scrollbars`
//! tell the host the true total so it can draw a proportional, draggable
//! scrollbar. Up/Down move the selection by one and PageUp/PageDown by a
//! screenful, dragging the view along with it (`syncScroll`); the host
//! can also move the view on its own (wheel, scrollbar drag), which
//! `drainEvents` picks up as a `scroll_offset` notification and follows
//! without touching the selection. Every redraw goes out as one `batch`
//! frame (`run`'s render step) rather than a round trip per row.
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
const history = @import("shell_support").history;
const fuzzy = @import("shell_support").fuzzy;

/// Rows the header block occupies: title, search field, hint line.
const header_rows: usize = 3;

const bg_header = glyphwire.Color{ .r = 40, .g = 90, .b = 170 };
const fg_header = glyphwire.Color{ .r = 235, .g = 240, .b = 250 };
const bg_list = glyphwire.Color{ .r = 16, .g = 16, .b = 20 };
const fg_list = glyphwire.Color{ .r = 210, .g = 210, .b = 216 };
// Selection uses the same blue as the header, tying the "you are here"
// highlight to the chrome around it rather than inventing a third color.
const bg_selected = glyphwire.Color{ .r = 70, .g = 120, .b = 200 };
const fg_selected = glyphwire.Color{ .r = 245, .g = 250, .b = 255 };

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const entries = loadHistory(alloc, io, init.environ_map) catch &.{};
    defer if (entries.len > 0) history.freeEntries(alloc, @constCast(entries));

    var client = try glyphwire.Client.connectFromEnv(io, alloc, init.environ_map);
    defer client.deinit();

    const listener = try glyphwire.InputListener.connectFromEnv(io, alloc, init.environ_map, &.{
        "key",
        "text",
        "resize",
        "scroll_offset",
    });
    defer listener.deinit();

    const ui = try Ui.init(alloc, &client, listener, entries);
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

const Ui = struct {
    alloc: std.mem.Allocator,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,
    context: glyphwire.ContextHandle,
    header_layer: glyphwire.LayerHandle,
    list_layer: glyphwire.LayerHandle,

    entries: []const []const u8,
    query: std.ArrayList(u8) = .empty,
    filtered: std.ArrayList([]const u8) = .empty,
    /// Reused across renders so drawing a row/line never allocates on the
    /// hot path -- only `query`/`filtered`, which change shape, do.
    scratch: std.ArrayList(u8) = .empty,
    line_buf: std.ArrayList(u8) = .empty,

    selected: usize = 0,
    /// Index of the first entry drawn in the list layer's row 0.
    view_top: usize = 0,

    cols: usize,
    rows: usize,
    list_rows: usize,

    header_dirty: bool = true,
    list_dirty: bool = true,
    quit: bool = false,
    /// Set on Enter; `main` writes it out once `run` returns.
    picked: ?[]u8 = null,

    fn init(
        alloc: std.mem.Allocator,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        entries: []const []const u8,
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

        const size = try client.getSize();
        const cols = size.cols;
        const rows = size.rows;
        const list_rows = @max(rows -| header_rows, 1);

        const header_layer = try client.createLayer(cols, header_rows, 0);
        const list_layer = try client.createLayer(cols, list_rows, 0);
        try client.setLayerCellPosition(list_layer, header_rows, 0);
        // Sized to the visible rows only (self-scrolling); `syncScroll`
        // below tells the host the true total via `content_extent` so
        // its scrollbar thumb is proportional, not full-height.
        try client.setLayerScrollbars(list_layer, true, false);

        self.* = .{
            .alloc = alloc,
            .client = client,
            .listener = listener,
            .context = context,
            .header_layer = header_layer,
            .list_layer = list_layer,
            .entries = entries,
            .cols = cols,
            .rows = rows,
            .list_rows = list_rows,
        };

        try self.refilter();
        try self.syncScroll();
        return self;
    }

    fn deinit(self: *Ui) void {
        self.query.deinit(self.alloc);
        self.filtered.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        self.line_buf.deinit(self.alloc);
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
            try self.drainEvents();
            if (self.header_dirty or self.list_dirty) {
                // One `batch` frame for everything dirty this tick --
                // typing a character used to mean up to a dozen separate
                // `write_text`/cursor round trips (three header rows plus
                // every visible list row); now it's one.
                var b = self.client.batch();
                defer b.deinit();
                if (self.header_dirty) {
                    try self.renderHeader(&b);
                    self.header_dirty = false;
                }
                if (self.list_dirty) {
                    try self.renderList(&b);
                    self.list_dirty = false;
                }
                var results = try b.send();
                results.deinit();
            }
            if (self.quit) break;

            // Block rather than spin; the timeout only exists so the
            // resize/scroll queues polled in `drainEvents` get looked at
            // even with no keystrokes coming in.
            if (try self.listener.waitInputEvent(.{
                .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake },
            })) |ev| {
                defer ev.deinit(self.alloc);
                try self.handleInput(ev);
            }
        }
    }

    fn drainEvents(self: *Ui) !void {
        while (self.listener.pollResizeEvent()) |ev| {
            self.cols = ev.cols;
            self.rows = ev.rows;
            self.list_rows = @max(self.rows -| header_rows, 1);
            try self.client.setLayerSize(self.header_layer, self.cols, header_rows);
            try self.client.setLayerSize(self.list_layer, self.cols, self.list_rows);
            try self.syncScroll();
            self.header_dirty = true;
            self.list_dirty = true;
        }
        while (self.listener.pollScrollOffsetEvent()) |ev| {
            // The wheel or a scrollbar drag over the list: the host has
            // already moved the viewport and is telling us where it
            // landed. Follow it without touching `selected` -- scrolling
            // and picking are separate gestures here, same as browsing a
            // file list without moving your cursor onto every row you
            // pass over.
            if (ev.layer == self.list_layer) {
                self.view_top = @min(ev.row, self.filtered.items.len -| self.list_rows);
                self.list_dirty = true;
            }
        }
        while (self.listener.pollInputEvent()) |ev| {
            defer ev.deinit(self.alloc);
            try self.handleInput(ev);
        }
    }

    // ── Input ───────────────────────────────────────────────────────────

    fn handleInput(self: *Ui, ev: glyphwire.InputEvent) !void {
        switch (ev) {
            .key => |k| if (k.pressed) try self.handleKey(k.key),
            .text => |t| try self.handleText(t.text),
            .shutdown => self.quit = true,
            else => {},
        }
    }

    /// Named/control keys -- physical-key semantics (vim-style, same
    /// split `gw-read`/`zoe` use). Ordinary typed characters arrive via
    /// `handleText` instead, since `text` is already resolved through the
    /// OS layout/IME and a search box has no reason to care which
    /// physical key produced what was typed.
    fn handleKey(self: *Ui, key: []const u8) !void {
        const ctrl = self.listener.isKeyDown("left_control") or self.listener.isKeyDown("right_control");
        const eq = std.mem.eql;

        if (eq(u8, key, "enter")) {
            if (self.filtered.items.len == 0) return;
            self.picked = try self.alloc.dupe(u8, self.filtered.items[self.selected]);
            self.quit = true;
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
            try self.syncScroll();
            self.list_dirty = true;
        } else if (eq(u8, key, "down") or (ctrl and eq(u8, key, "r"))) {
            if (self.filtered.items.len > 0) self.selected = (self.selected + 1) % self.filtered.items.len;
            try self.syncScroll();
            self.list_dirty = true;
        } else if (eq(u8, key, "page_up")) {
            self.selected = self.selected -| self.list_rows;
            try self.syncScroll();
            self.list_dirty = true;
        } else if (eq(u8, key, "page_down")) {
            if (self.filtered.items.len > 0) {
                self.selected = @min(self.selected + self.list_rows, self.filtered.items.len - 1);
            }
            try self.syncScroll();
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
        try self.syncScroll();
        self.header_dirty = true;
        self.list_dirty = true;
    }

    /// Rewrites `filtered` with every entry of `entries` (oldest-first)
    /// that fuzzy-matches `query`, newest-first, sorted by `fuzzy.score`
    /// (tighter match first) with a stable sort so equal scores keep the
    /// newest-first order -- the recency tiebreak (see `fuzzy.score`'s
    /// doc comment).
    fn refilter(self: *Ui) !void {
        self.filtered.clearRetainingCapacity();
        var i: usize = self.entries.len;
        while (i > 0) {
            i -= 1;
            if (fuzzy.matches(self.entries[i], self.query.items)) try self.filtered.append(self.alloc, self.entries[i]);
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
        if (self.selected >= self.filtered.items.len) self.selected = self.filtered.items.len -| 1;
    }

    /// Keeps `view_top` covering `selected`, clamped to the list's actual
    /// extent, then pushes both the true content size and the resulting
    /// offset to the host so its scrollbar thumb and thumb position stay
    /// correct.
    fn syncScroll(self: *Ui) !void {
        if (self.filtered.items.len == 0) {
            self.view_top = 0;
        } else {
            if (self.selected < self.view_top) self.view_top = self.selected;
            if (self.selected >= self.view_top + self.list_rows) self.view_top = self.selected - self.list_rows + 1;
            const max_top = self.filtered.items.len -| self.list_rows;
            if (self.view_top > max_top) self.view_top = max_top;
        }
        try self.client.setLayerContentExtent(self.list_layer, self.cols, self.filtered.items.len);
        try self.client.setLayerScrollOffset(self.list_layer, self.view_top, 0);
    }

    // ── Rendering ───────────────────────────────────────────────────────

    fn renderHeader(self: *Ui, b: *glyphwire.Client.Batch) !void {
        try self.writeLine(b, self.header_layer, 0, "gw-hist -- fuzzy history search", fg_header, bg_header);

        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(self.alloc, "Search: ");
        try self.scratch.appendSlice(self.alloc, self.query.items);
        try self.writeLine(b, self.header_layer, 1, self.scratch.items, fg_header, bg_header);
        // A drawn caret (inverted cell), not the host's own cursor --
        // same choice `zoe` makes for its buffer caret, since a plain
        // text layer's cursor property is about the *next write*
        // position, not a persistent visual marker.
        const caret_col = @min(8 + self.query.items.len, self.cols -| 1);
        try b.notify("set_property", .{ .layer = self.header_layer, .property = "cursor", .row = 1, .col = caret_col });
        try b.notify("write_text", .{
            .layer = self.header_layer,
            .text = " ",
            .fg = glyphwire.Client.colorToJson(bg_header),
            .bg = glyphwire.Client.colorToJson(fg_header),
        });

        self.scratch.clearRetainingCapacity();
        try self.scratch.print(self.alloc, "{d} match(es)   Enter picks   Esc/^C cancels   Down/^R next   PgUp/PgDn page", .{self.filtered.items.len});
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
                try self.writeLine(b, self.list_layer, row, "", fg_list, bg_list);
            }
        }
    }

    /// Appends the sub-messages to draw `text` at `(row, 0)` on `layer`
    /// into `b`, truncated or blank-padded to the full window width so
    /// every cell in the row carries `bg` -- there is no `fillRect`/
    /// `clear(color)` call, so a solid-colored bar (the header) or a
    /// solid-colored empty row (past the last match) is built out of a
    /// space-padded `write_text` like every other glyphwire client does
    /// (see `read/ui.zig`'s status bar). Batched rather than sent
    /// straight through `self.client` -- `renderHeader`/`renderList`
    /// each draw several rows per redraw, and `run` wants all of them in
    /// one `batch` frame rather than one round trip per row.
    fn writeLine(self: *Ui, b: *glyphwire.Client.Batch, layer: glyphwire.LayerHandle, row: usize, text: []const u8, fg: glyphwire.Color, bg: glyphwire.Color) !void {
        self.line_buf.clearRetainingCapacity();
        const shown = text[0..@min(text.len, self.cols)];
        try self.line_buf.appendSlice(self.alloc, shown);
        var pad = self.cols -| shown.len;
        while (pad > 0) : (pad -= 1) try self.line_buf.append(self.alloc, ' ');
        try b.notify("set_property", .{ .layer = layer, .property = "cursor", .row = row, .col = 0 });
        try b.notify("write_text", .{
            .layer = layer,
            .text = self.line_buf.items,
            .fg = glyphwire.Client.colorToJson(fg),
            .bg = glyphwire.Client.colorToJson(bg),
        });
    }
};
