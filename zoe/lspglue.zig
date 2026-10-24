// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's side of the language servers: starting and restarting them,
//! the didOpen/didChange/didSave notifications, draining their events,
//! and applying what comes back -- diagnostics, hover, go-to-definition.
//! `Ui` methods moved out of ui.zig and aliased back.

const std = @import("std");
const homepath = @import("applib").homepath;
const syntax = @import("applib").syntax;
const lsp = @import("lsp.zig");
const diag = @import("diag.zig");
const hover_mod = @import("hover.zig");
const buffer_mod = @import("buffer.zig");

const ui = @import("ui.zig");
const Ui = ui.Ui;
const Slot = ui.Slot;
const Tree = ui.Tree;
const lsp_change_debounce_ms = ui.lsp_change_debounce_ms;

/// Starts the configured servers, if any. Best-effort in every
/// direction: LSP is not part of the editor's correctness, so a server
/// that isn't installed, won't spawn or won't answer leaves zoe exactly
/// as it was without one.
pub fn startLsp(self: *Ui, folders: []const Tree.RootSpec, environ: *const std.process.Environ.Map) void {
    lsp.debug = environ.get("GLYPHWIRE_LSP_DEBUG") != null;
    const cfg = self.hl_config orelse {
        // No config means no server list, and also no grammar registry --
        // so this is the same failure that turns highlighting off.
        std.log.warn("zoe: no config loaded; language servers are off", .{});
        return;
    };
    if (!cfg.lsp_enabled) return;

    // Rooted at the first folder, with every folder in its
    // `workspaceFolders` (added before `start`, so they ride along in
    // `initialize` rather than as a change).
    var pool = lsp.Pool.init(self.alloc, self.io, lsp.Waker.fromListener(self.listener), folders[0].path) catch return;
    for (folders[1..]) |f| pool.addFolder(f.path, f.name) catch {};
    pool.start(cfg.lsp_servers, environ) catch {};
    if (pool.servers.items.len == 0) {
        // Nothing started. Keep the pool anyway so `:lsp` can list what
        // it looked for and didn't find, but don't reserve the gutter
        // column for marks that will never come.
        self.lsp_pool = pool;
        return;
    }
    self.lsp_pool = pool;
    self.signs = true;
}

/// The grammar name for `path`, which doubles as the key servers are
/// registered under. Null when nothing claims the extension -- the same
/// answer that turns highlighting off for a file.
pub fn lspGrammarFor(self: *Ui, path: ?[]const u8) ?[]const u8 {
    const reg = if (self.grammars) |*r| r else return null;
    const p = path orelse return null;
    return reg.nameForPath(p);
}

/// Tells every server that serves this buffer's language about it.
/// A buffer with no path (a scratch one) and a file no server claims are
/// both simply not announced.
pub fn lspDidOpen(self: *Ui, slot: *Slot) void {
    const pool = if (self.lsp_pool) |*p| p else return;
    if (slot.doc.lsp_opened) return;
    const path = slot.ed.path orelse return;
    const grammar = self.lspGrammarFor(path) orelse return;

    const abs = self.slotAbs(slot) orelse return;
    const uri = lsp.pathToUri(self.alloc, abs) catch return;
    defer self.alloc.free(uri);
    const text = slot.ed.buf.text(self.alloc) catch return;
    defer self.alloc.free(text);

    var any = false;
    var it = pool.forLanguage(grammar);
    while (it.next()) |s| {
        s.didOpen(uri, lsp.languageId(grammar), text) catch continue;
        any = true;
    }
    if (!any) return;
    slot.doc.lsp_opened = true;
    slot.doc.lsp_sent_edits = slot.ed.buf.edits;
}

/// The counterpart, on `:bd`. The stored diagnostics go too: a closed
/// buffer's marks would otherwise come back with the next file to reuse
/// the slot.
pub fn lspDidClose(self: *Ui, slot: *Slot) void {
    const pool = if (self.lsp_pool) |*p| p else return;
    if (!slot.doc.lsp_opened) return;
    const path = slot.ed.path orelse return;
    const grammar = self.lspGrammarFor(path) orelse return;

    const abs = self.slotAbs(slot) orelse return;
    const uri = lsp.pathToUri(self.alloc, abs) catch return;
    defer self.alloc.free(uri);

    var it = pool.forLanguage(grammar);
    while (it.next()) |s| s.didClose(uri) catch {};
    self.diags.clearPath(abs);
    slot.doc.lsp_opened = false;
}

/// `:w` -- some servers only report on save (and `ruff`'s formatting
/// checks are among them), so this is not redundant with `didChange`.
pub fn lspDidSave(self: *Ui) void {
    const pool = if (self.lsp_pool) |*p| p else return;
    // A `:w <newname>` makes this a file the servers have never seen;
    // announce it rather than saving under a name they don't know.
    if (!self.buf.doc.lsp_opened) {
        self.lspDidOpen(self.buf);
        return;
    }
    const path = self.buf.ed.path orelse return;
    const grammar = self.lspGrammarFor(path) orelse return;
    const abs = self.slotAbs(self.buf) orelse return;
    const uri = lsp.pathToUri(self.alloc, abs) catch return;
    defer self.alloc.free(uri);

    // The save is the newest state, so any debounced change is spent.
    self.lspFlushChange();
    var it = pool.forLanguage(grammar);
    while (it.next()) |s| s.didSave(uri) catch {};
}

/// Arms the `didChange` debounce if the active buffer has moved on since
/// the servers were last told. Called once a frame from `run`, which is
/// enough: the deadline is what decides when the message goes, not how
/// often this is called.
pub fn armLspChange(self: *Ui) void {
    if (self.lsp_pool == null) return;
    if (!self.buf.doc.lsp_opened) return;
    if (self.buf.ed.buf.edits == self.buf.doc.lsp_sent_edits) return;
    if (self.timers.armed(.lsp_change)) return;
    self.timers.armIn(self.io, .lsp_change, lsp_change_debounce_ms);
}

/// Sends the active buffer's whole text as a `didChange` and disarms the
/// debounce. Full text rather than ranges -- see the design note: the
/// incremental form needs a second consumer of `Buffer.pending_edits`,
/// which the highlighter currently drains alone.
pub fn lspFlushChange(self: *Ui) void {
    self.timers.disarm(.lsp_change);
    const pool = if (self.lsp_pool) |*p| p else return;
    if (!self.buf.doc.lsp_opened) return;
    if (self.buf.ed.buf.edits == self.buf.doc.lsp_sent_edits) return;

    const path = self.buf.ed.path orelse return;
    const grammar = self.lspGrammarFor(path) orelse return;
    const abs = self.slotAbs(self.buf) orelse return;
    const uri = lsp.pathToUri(self.alloc, abs) catch return;
    defer self.alloc.free(uri);
    const text = self.buf.ed.buf.text(self.alloc) catch return;
    defer self.alloc.free(text);

    self.buf.doc.lsp_version += 1;
    var it = pool.forLanguage(grammar);
    while (it.next()) |s| s.didChange(uri, self.buf.doc.lsp_version, text) catch {};
    self.buf.doc.lsp_sent_edits = self.buf.ed.buf.edits;
}

/// The earliest of the `didChange` debounce, the completion and tab
/// tooltip delays, and the oldest outstanding request's timeout, or null
/// for none -- the loop's whole notion of time.
/// When the oldest outstanding language-server request times out, as a
/// deadline on the awake clock; `Ui.nextDeadline` folds it in with the
/// timers.
pub fn lspRequestDeadline(self: *Ui) ?std.Io.Clock.Timestamp {
    const pool = if (self.lsp_pool) |*p| p else return null;
    const req_ms = pool.nextDeadlineMs() orelse return null;
    return .{
        .raw = .fromNanoseconds(@as(i96, req_ms) * std.time.ns_per_ms),
        .clock = .awake,
    };
}

/// `slot`'s absolute path, resolved once and cached on the slot (see
/// `Document.abs_path`). Borrowed -- the slot owns it. Null for a buffer with
/// no file behind it, which is also "nothing a language server can say
/// anything about".
pub fn slotAbs(self: *Ui, slot: *Slot) ?[]const u8 {
    if (slot.doc.abs_path) |p| return p;
    const path = slot.ed.path orelse return null;
    // Every LSP URI is absolute, and a buffer path is whatever was typed,
    // so this is also what makes `./src/main.zig` and its absolute
    // spelling the same file.
    const abs = homepath.absolute(self.io, self.alloc, path) catch return null;
    slot.doc.abs_path = abs;
    return abs;
}

/// Drops the cached absolute path, for whatever just changed `ed.path`
/// (`:w <newname>`, `:e`).
pub fn invalidateAbs(self: *Ui, slot: *Slot) void {
    if (slot.doc.abs_path) |p| self.alloc.free(p);
    slot.doc.abs_path = null;
}

/// Drains everything the servers have said since the last turn round the
/// loop. Called once per iteration of `run`, before the frame, so an
/// arriving diagnostic is drawn in the same frame as the keystroke that
/// happened to wake us.
pub fn drainLsp(self: *Ui) void {
    const pool = if (self.lsp_pool) |*p| p else return;
    while (pool.nextEvent() catch null) |ev| self.handleLspEvent(ev);
    // After the replies, so one that landed just inside its deadline
    // counts as answered rather than timed out.
    const now = lsp.nowMs(self.io);
    while (pool.expire(now)) |ev| self.handleLspEvent(ev);
}

pub fn handleLspEvent(self: *Ui, ev: lsp.Event) void {
    var e = ev;
    defer e.deinit(self.alloc);
    switch (e) {
        .diagnostics => |d| self.applyDiagnostics(d.path, d.server, d.items),
        .hover => |h| self.applyHover(h.request_id, h.text),
        .definition => |d| self.applyDefinition(d.request_id, d.target),
        .completion => |*c| {
            // The items move into the popup rather than being copied:
            // a completion list can run to thousands of entries.
            const items = c.items;
            c.items = &.{};
            self.applyCompletion(c.request_id, c.server, items, c.incomplete);
        },
        .timed_out => |t| self.applyTimeout(t.request_id, t.server, t.kind),
        .died => |d| {
            // Its marks will never be refreshed again, so they go
            // rather than growing stale on screen.
            self.diags.clearServer(d.server);
            self.buf.ed.setStatus("LSP: {s} exited (:lsp restart)", .{d.server});
            self.status_dirty = true;
            self.buf.full_redraw = true;
            self.grp.buffer_dirty = true;
        },
    }
}

/// A request the server never answered. Said on the statusline only when
/// it is the one the editor is still waiting on: a stale request timing
/// out (the user already asked again) is nobody's business.
pub fn applyTimeout(self: *Ui, request_id: i64, server: []const u8, kind: lsp.RequestKind) void {
    const slot: *?i64 = switch (kind) {
        .hover => &self.hover_request,
        .definition => &self.definition_request,
        .completion => &self.completion_request,
        .initialize, .shutdown => return,
    };
    if (slot.* != request_id) return;
    slot.* = null;
    self.buf.ed.setStatus("LSP: {s} didn't answer {t}", .{ server, kind });
    self.status_dirty = true;
}

/// Stores one publish, converting each range out of the server's
/// position encoding into byte columns first.
///
/// Converting here rather than at paint time is the only correct moment:
/// the positions describe the text the server analysed, and the buffer
/// may have moved on by the time a row is drawn. It also puts the
/// encoding question in one place -- from here down, a diagnostic's
/// `character` is a byte offset in its line, like every other column in
/// the editor.
pub fn applyDiagnostics(self: *Ui, path: []const u8, server: []const u8, items: []lsp.Diagnostic) void {
    const pool = if (self.lsp_pool) |*p| p else return;
    const enc = pool.encodingOf(server);

    // The buffer this is about, if it is open. A server may publish for
    // any file in the project, including ones zoe has never opened;
    // those are stored unconverted (nothing paints them) rather than
    // dropped, so `:diag` could list them later.
    const slot: ?*Slot = self.slotForPath(path);
    if (slot) |sl| {
        for (items) |*d| {
            d.range.start.character = self.byteColumn(sl, d.range.start, enc);
            d.range.end.character = self.byteColumn(sl, d.range.end, enc);
        }
    }

    // `publish` copies, so `items` stays the event's to free either way.
    self.diags.publish(path, server, items) catch return;

    // Every visible row may have gained or lost a mark, and the marks
    // live on cells the row painter owns.
    //
    // Whichever group shows it, focused or not.
    if (slot) |sl| if (self.findSlot(sl)) |at| if (at.group.slot() == sl) {
        sl.full_redraw = true;
        at.group.buffer_dirty = true;
        self.status_dirty = true;
    };
}

/// The byte column in `slot`'s line for an LSP position under `enc`.
pub fn byteColumn(self: *Ui, slot: *Slot, pos: lsp.Position, enc: lsp.PositionEncoding) u32 {
    if (pos.line >= slot.ed.buf.lineCount()) return pos.character;
    const text = slot.ed.buf.lineText(self.alloc, pos.line) catch return pos.character;
    defer self.alloc.free(text);
    return @intCast(lsp.characterToByte(text, pos.character, enc));
}

pub fn slotForPath(self: *Ui, abs: []const u8) ?*Slot {
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| {
            const slot_abs = self.slotAbs(slot) orelse continue;
            if (std.mem.eql(u8, slot_abs, abs)) return slot;
        }
    }
    return null;
}

/// `K` and `gd`: ask whichever attached server can answer.
///
/// The first capable server wins rather than all of them being asked.
/// With basedpyright and ruff both on a Python file only one of them
/// even claims `hover`, and if two did, two popups for one keystroke is
/// not an improvement.
pub fn requestLsp(self: *Ui, kind: lsp.RequestKind) void {
    const pool = if (self.lsp_pool) |*p| p else {
        self.buf.ed.setStatus("LSP: not enabled", .{});
        self.status_dirty = true;
        return;
    };
    const path = self.buf.ed.path orelse return;
    const grammar = self.lspGrammarFor(path) orelse return;
    const abs = self.slotAbs(self.buf) orelse return;
    const uri = lsp.pathToUri(self.alloc, abs) catch return;
    defer self.alloc.free(uri);

    // Anything typed since the last sync would make the server answer
    // about text that is no longer there.
    self.lspFlushChange();

    const cursor = self.buf.ed.pos();
    // Why nothing could answer, for the message below. "No server" and
    // "the server is still starting up" are very different situations to
    // be in, and one message for both sends you looking for a
    // misconfiguration when the answer is to wait a second.
    var any_server = false;
    var any_starting = false;
    var it = pool.forLanguage(grammar);
    while (it.next()) |s| {
        any_server = true;
        if (s.starting()) {
            any_starting = true;
            continue;
        }
        const line_text = self.buf.ed.buf.lineText(self.alloc, cursor.line) catch continue;
        defer self.alloc.free(line_text);
        const character = lsp.byteToCharacter(line_text, cursor.col, s.encoding);
        const id = s.positionRequest(kind, uri, .{
            .line = @intCast(cursor.line),
            .character = character,
        }) catch continue orelse continue;
        switch (kind) {
            .hover => self.hover_request = id,
            .definition => self.definition_request = id,
            else => {},
        }
        return;
    }
    self.status_dirty = true;
    if (any_starting) {
        self.buf.ed.setStatus("LSP: still starting up, try again", .{});
    } else if (any_server) {
        // A server is attached but doesn't advertise this request -- ruff
        // on a Python file has no hover, for instance.
        self.buf.ed.setStatus("LSP: attached server can't answer that", .{});
    } else {
        self.buf.ed.setStatus("LSP: no server for {s} (:lsp)", .{grammar});
    }
}

/// A hover reply. A reply to a request that is no longer the newest is
/// dropped: the user asked again, or has moved on, and a popup for a
/// cursor position two jumps back is worse than none.
pub fn applyHover(self: *Ui, request_id: i64, text: ?[]const u8) void {
    const want = self.hover_request orelse return;
    if (request_id != want) return;
    self.hover_request = null;

    const t = text orelse {
        self.buf.ed.setStatus("No hover information", .{});
        self.status_dirty = true;
        return;
    };
    // Parsed into the doc's own arena, so nothing is borrowed from the
    // event, which frees `t` on return.
    var doc = hover_mod.parse(self.alloc, t) catch return;
    if (doc.lines.len == 0) {
        doc.deinit();
        self.buf.ed.setStatus("No hover information", .{});
        self.status_dirty = true;
        return;
    }
    const spans = self.highlightHoverBlocks(&doc) catch {
        doc.deinit();
        return;
    };
    if (self.hover) |*h| h.deinit();
    self.hover = .{ .doc = doc, .spans = spans };
    self.popups.hover.dirty = true;
}

/// Colours every fenced block in a hover with the grammar its fence
/// names -- or, for a bare fence, the grammar of the buffer being
/// hovered, which is what a language server means by one. A block whose
/// language has no grammar installed stays plain; so does everything
/// when highlighting is off.
///
/// Each block is parsed on its own, as a tiny buffer, rather than as
/// part of the whole reply: a signature is a complete fragment in its
/// language, and the prose around it is not.
pub fn highlightHoverBlocks(self: *Ui, doc: *hover_mod.Doc) ![]const []const syntax.Span {
    const a = doc.arena.allocator();
    const out = try a.alloc([]const syntax.Span, doc.lines.len);
    @memset(out, &.{});
    if (doc.blocks.len == 0) return out;

    const reg = if (self.grammars) |*g| g else return out;
    const fallback: ?[]const u8 = if (self.buf.doc.hl) |*bh| bh.lang_name else null;
    if (self.hover_hl == null) {
        self.hover_hl = syntax.Highlighter.init(self.alloc, syntax.Theme.fromTheme(&self.th.theme)) catch return out;
        // No injections: a hover's code block is a signature, and a
        // grammar nested in one is not worth the second parse.
        self.hover_hl.?.configureInjections(reg, false);
    }
    const h = &self.hover_hl.?;
    // The language borrows the block's name out of the doc's arena, so
    // it must not outlive this call.
    defer h.clearLanguage();

    var scratch: std.ArrayList(syntax.Span) = .empty;
    defer scratch.deinit(self.alloc);
    for (doc.blocks) |b| {
        if (b.count == 0) continue;
        const lang = if (b.lang.len > 0) b.lang else fallback orelse continue;
        const grammar = reg.get(lang) orelse continue;
        h.setLanguage(lang, grammar) catch continue;

        const src = try doc.blockSource(self.alloc, b);
        defer self.alloc.free(src);
        var buf = try buffer_mod.Buffer.initFromText(self.alloc, src);
        defer buf.deinit();
        h.reparse(src) catch continue;

        for (b.first..b.first + b.count) |i| {
            const line = i - b.first;
            h.lineSpans(buf.lineStart(line), buf.lineEnd(line), &scratch) catch continue;
            out[i] = try a.dupe(syntax.Span, scratch.items);
        }
    }
    return out;
}

/// A definition reply: jump, recording where we came from so Ctrl+O
/// comes back.
pub fn applyDefinition(self: *Ui, request_id: i64, target: ?lsp.Location) void {
    const want = self.definition_request orelse return;
    if (request_id != want) return;
    self.definition_request = null;

    const loc = target orelse {
        self.buf.ed.setStatus("No definition found", .{});
        self.status_dirty = true;
        return;
    };

    self.pushJump();
    // Another file is a tab; the same file is just a cursor move. Either
    // way the target is the range's *start*: a definition's range covers
    // the whole declaration, and landing on its first character is what
    // every editor does.
    const same = if (self.slotAbs(self.buf)) |abs|
        std.mem.eql(u8, abs, loc.path)
    else
        false;

    if (!same) {
        self.openFile(loc.path) catch {
            self.buf.ed.setStatus("E484: Can't open {s}", .{loc.path});
            self.status_dirty = true;
            return;
        };
    }
    self.gotoLineColumn(loc.range.start.line, loc.range.start.character);
}

/// `]d` / `[d`, wrapping round the file like vim's quickfix stepping
/// does. A buffer with no diagnostics says so rather than moving the
/// cursor to nowhere.
pub fn stepDiagnostic(self: *Ui, forward: bool) void {
    const abs = self.slotAbs(self.buf) orelse return;

    const cursor = self.buf.ed.pos();
    const dir: diag.Direction = if (forward) .next else .prev;
    const found = self.diags.step(abs, @intCast(cursor.line), @intCast(cursor.col), dir) orelse
        // Off the end: wrap. Doing it here rather than in the store
        // keeps `step` honest for callers that shouldn't wrap.
        (if (forward) self.diags.first(abs) else self.diags.last(abs)) orelse {
            self.buf.ed.setStatus("No diagnostics", .{});
            self.status_dirty = true;
            return;
        };
    self.gotoLineColumn(found.range.start.line, found.range.start.character);
    self.buf.ed.setStatus("{s}: {s}", .{ found.source, found.message });
}

/// `:lsp` / `:lsp restart`.
pub fn lspStatus(self: *Ui, arg: ?[]const u8) void {
    self.status_dirty = true;
    const pool = if (self.lsp_pool) |*p| p else {
        self.buf.ed.setStatus("LSP: disabled in zoe.conf.lua", .{});
        return;
    };
    if (arg) |a| {
        if (std.mem.eql(u8, a, "restart")) {
            self.restartLsp();
            return;
        }
        self.buf.ed.setStatus("LSP: unknown argument \"{s}\" (try :lsp restart)", .{a});
        return;
    }

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(self.alloc);
    msg.appendSlice(self.alloc, "LSP:") catch return;
    if (pool.servers.items.len == 0 and pool.missing.items.len == 0) {
        msg.appendSlice(self.alloc, " no servers configured") catch return;
    }
    for (pool.servers.items) |s| {
        const state = if (!s.alive()) "dead" else if (s.state == .starting) "starting" else "ready";
        msg.print(self.alloc, " {s}[{s}]", .{ s.name, state }) catch return;
    }
    // Named rather than silently absent: "nothing happened" with no
    // explanation is the worst answer a feature like this can give.
    for (pool.missing.items) |name| {
        msg.print(self.alloc, " {s}[not installed]", .{name}) catch return;
    }
    self.buf.ed.setStatus("{s}", .{msg.items});
}

/// Tears the pool down and starts it again, re-announcing every open
/// buffer. The recovery path for a server that crashed -- deliberately
/// manual, because a server that died on a file will die on it again and
/// a respawn loop is worse than a dead server.
pub fn restartLsp(self: *Ui) void {
    if (self.lsp_pool) |*p| p.deinit();
    self.lsp_pool = null;
    self.diags.deinit();
    self.diags = diag.Store.init(self.alloc);
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| slot.doc.lsp_opened = false;
    }

    // The sidebar's folders as they stand now -- `:addfolder` and a
    // single-folder `:cd` included.
    var specs: std.ArrayList(Tree.RootSpec) = .empty;
    defer specs.deinit(self.alloc);
    for (self.tree.roots.items) |r| specs.append(self.alloc, .{ .path = r.path, .name = r.name }) catch return;
    self.startLsp(specs.items, self.environ);
    for (self.group_list.items) |g| {
        for (g.buffers.items) |slot| self.lspDidOpen(slot);
        // The sign column's marks went with the old store.
        g.markRedraw();
    }

    self.buf.ed.setStatus("LSP: restarted", .{});
}

/// `:diag` -- this buffer's diagnostics, on the statusline. A one-line
/// summary plus the first message, which is what fits; the popup list
/// this deserves is the finder's job and a later slice.
pub fn diagList(self: *Ui) void {
    self.status_dirty = true;
    const abs = self.slotAbs(self.buf) orelse return;

    const c = self.diags.counts(abs);
    if (c.errors == 0 and c.warnings == 0) {
        self.buf.ed.setStatus("No diagnostics", .{});
        return;
    }
    const first = self.diags.first(abs) orelse return;
    self.buf.ed.setStatus("{d}E {d}W  {d}: {s}: {s}", .{
        c.errors,
        c.warnings,
        first.range.start.line + 1,
        first.source,
        first.message,
    });
}
