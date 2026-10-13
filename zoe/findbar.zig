// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The Ctrl+F / Ctrl+H find widget's box: where its parts sit, which part
//! a click lands on, and drawing it. The state it shows is the editor's
//! (`Mode.find` and the `find_*` fields in `editor.zig`); this only lays
//! it out, the way VS Code's widget is laid out:
//!
//!     ┌──────────────────────────────────────────────────────┐
//!     │ [find text          ] Aa ab ≡  3 of 12    ↑ ↓ ×     │
//!     │ [replace text       ] ⇄ All                         │
//!     └──────────────────────────────────────────────────────┘
//!
//! on the theme's panel nine-patch (`panel_style`, the hover popup's),
//! whose frame takes the first and last columns. The second row is only
//! there with replace showing. `layout` and `hit`
//! are pure, so `tests/zoe_tests.zig` covers them without a client.

const std = @import("std");
const glyphwire = @import("glyphwire");
const lineedit = @import("applib").lineedit;
const editor = @import("editor.zig");

const role = glyphwire.Color.role;
const Batch = glyphwire.Client.Batch;

/// A part of the widget a click can land on.
pub const Zone = enum {
    find_field,
    replace_field,
    case,
    word,
    selection,
    prev,
    next,
    close,
    replace_one,
    replace_all,
};

/// The fixed-width parts of the find row after the field: a space, the
/// three toggles (`Aa ab ≡ `), the match count, and `↑ ↓ ×` with a
/// space either side.
const toggles_cols = 1 + 8;
pub const count_cols = 11;
const buttons_cols = 7;
/// The find row less its field, the leading space included.
pub const fixed_cols = 1 + toggles_cols + count_cols + buttons_cols;

/// The field widths the widget picks between.
pub const min_field_cols = 6;
pub const max_field_cols = 30;

/// Where everything is, as columns within the widget.
pub const Layout = struct {
    /// The whole widget's width and height.
    cols: usize,
    rows: usize,
    /// Both fields start at `field_col` and are `field_cols` wide.
    field_col: usize,
    field_cols: usize,
    case_col: usize,
    word_col: usize,
    selection_col: usize,
    count_col: usize,
    prev_col: usize,
    next_col: usize,
    close_col: usize,
    replace_one_col: usize,
    replace_all_col: usize,
};

/// The widget's layout in a pane `pane_cols` wide, or null when it
/// can't fit there at all.
pub fn layout(pane_cols: usize, show_replace: bool) ?Layout {
    // A cell of the pane is left free on each side.
    if (pane_cols < fixed_cols + min_field_cols + 2) return null;
    // Typed: `@min` against a comptime bound would narrow it to a `u5`.
    const field: usize = @min(pane_cols - 2 - fixed_cols, max_field_cols);
    const field_col: usize = 1;
    const case_col = field_col + field + 1;
    const count_col = case_col + 8;
    const prev_col = count_col + count_cols + 1;
    return .{
        .cols = fixed_cols + field,
        .rows = if (show_replace) 2 else 1,
        .field_col = field_col,
        .field_cols = field,
        .case_col = case_col,
        .word_col = case_col + 3,
        .selection_col = case_col + 6,
        .count_col = count_col,
        .prev_col = prev_col,
        .next_col = prev_col + 2,
        .close_col = prev_col + 4,
        .replace_one_col = case_col,
        .replace_all_col = case_col + 2,
    };
}

/// The part of the widget at row `row`, column `col` (both within it),
/// or null for the space between parts.
pub fn hit(l: Layout, row: usize, col: usize) ?Zone {
    const inField = col >= l.field_col and col < l.field_col + l.field_cols;
    if (row == 0) {
        if (inField) return .find_field;
        if (col >= l.case_col and col < l.case_col + 2) return .case;
        if (col >= l.word_col and col < l.word_col + 2) return .word;
        if (col == l.selection_col) return .selection;
        if (col == l.prev_col) return .prev;
        if (col == l.next_col) return .next;
        if (col == l.close_col) return .close;
        return null;
    }
    if (row == 1 and l.rows == 2) {
        if (inField) return .replace_field;
        if (col == l.replace_one_col) return .replace_one;
        if (col >= l.replace_all_col and col < l.replace_all_col + 3) return .replace_all;
    }
    return null;
}

/// The byte offset a field showing `text` in `cols` cells starts from,
/// so the caret at byte `caret` is in view: from the start while it
/// fits, otherwise with the caret in the last cell.
pub fn scrollStart(text: []const u8, caret: usize, cols: usize) usize {
    const caret_col = lineedit.displayCol(text, caret);
    if (caret_col < cols) return 0;
    return lineedit.offsetAtCol(text, 0, caret_col - cols + 1);
}

/// The count's text: "3 of 12", "? of 12" off a match, "No results".
/// `cap` is where counting stopped, shown as "cap+".
pub fn countText(out: []u8, index: usize, total: usize, cap: usize) []const u8 {
    if (total == 0) return "No results";
    const plus = if (total >= cap) "+" else "";
    if (index == 0) return std.fmt.bufPrint(out, "? of {d}{s}", .{ total, plus }) catch "";
    return std.fmt.bufPrint(out, "{d} of {d}{s}", .{ index, total, plus }) catch "";
}

/// The most matches the count looks for before it says "N+".
pub const count_cap: usize = 9999;

/// Draws the widget for `ed` (which is in `Mode.find`) into `layer`,
/// already sized and placed to `l`. Everything but the fields and a lit
/// toggle is drawn without a background, so the layer's panel (a
/// nine-patch, or flat `popup_bg` where the theme has none) shows
/// through; the first and last columns are left to its frame.
pub fn render(batch: *Batch, layer: glyphwire.LayerHandle, l: Layout, ed: *const editor.Editor) !void {
    const counted = ed.findCount(count_cap);
    var count_buf: [32]u8 = undefined;
    const count = countText(&count_buf, counted.index, counted.total, count_cap);

    // A resize keeps whatever the old cells held, and a shorter count
    // or a replace row going away would otherwise leave it behind.
    try batch.clearArea(.{ .layer = layer });

    // The find row.
    try renderField(batch, layer, l, 0, &ed.cmdline, ed.find_field == .find, ed.find_fresh, ed.search_failed);
    try toggle(batch, layer, l.case_col, "Aa", ed.find_case, true);
    try toggle(batch, layer, l.word_col, "ab", ed.find_word, true);
    try toggle(batch, layer, l.selection_col, "\u{2261}", ed.find_in_selection, ed.find_scope != null);
    try batch.writeText(count, .{
        .layer = layer,
        .row = 0,
        .col = l.count_col,
        .fg = if (counted.total == 0 and !ed.cmdline.isEmpty()) role(.message_error) else role(.popup_fg),
        .max_cols = count_cols,
    });
    try batch.writeText("\u{2191} \u{2193} \u{00d7}", .{
        .layer = layer,
        .row = 0,
        .col = l.prev_col,
        .fg = role(.popup_fg),
        .selectable = false,
    });

    if (l.rows < 2) return;
    try renderField(batch, layer, l, 1, &ed.find_replace, ed.find_field == .replace, false, false);
    try batch.writeText("\u{21c4} All", .{
        .layer = layer,
        .row = 1,
        .col = l.replace_one_col,
        .fg = role(.popup_fg),
        .selectable = false,
    });
}

/// One field: its text on a darker ground, scrolled to keep the caret
/// in view, with the caret drawn as an inverted cell when it has the
/// keyboard. Prefilled (`fresh`) text is shown selected; a pattern that
/// matches nothing (`failed`) in the error colour.
fn renderField(
    batch: *Batch,
    layer: glyphwire.LayerHandle,
    l: Layout,
    row: usize,
    line: *const lineedit.LineEdit,
    focused: bool,
    fresh: bool,
    failed: bool,
) !void {
    const text = line.text();
    const start = scrollStart(text, line.caret, l.field_cols);
    const shown = text[start..];
    const fg = if (failed) role(.message_error) else role(.popup_fg);
    const bg = if (fresh and focused) role(.selection_bg) else role(.bg_dark);
    try batch.writeText(shown, .{
        .layer = layer,
        .row = row,
        .col = l.field_col,
        .fg = fg,
        .bg = bg,
        .max_cols = l.field_cols,
        .pad = true,
    });
    if (!focused) return;
    const caret_col = lineedit.displayCol(text, line.caret) - lineedit.displayCol(text, start);
    if (caret_col >= l.field_cols) return;
    const under = if (line.caret < text.len) text[line.caret..lineedit.nextBoundary(text, line.caret)] else " ";
    try batch.writeText(under, .{
        .layer = layer,
        .row = row,
        .col = l.field_col + caret_col,
        .fg = role(.cursor_fg),
        .bg = role(.cursor_bg),
    });
}

/// A toggle's label: lit when `on`, dim when off or not `available`.
fn toggle(batch: *Batch, layer: glyphwire.LayerHandle, col: usize, label: []const u8, on: bool, available: bool) !void {
    try batch.writeText(label, .{
        .layer = layer,
        .row = 0,
        .col = col,
        .fg = if (on) role(.accent) else if (available) role(.popup_fg) else role(.fg_dim),
        // Off, the panel shows through.
        .bg = if (on) role(.popup_selected_bg) else null,
        .selectable = false,
    });
}
