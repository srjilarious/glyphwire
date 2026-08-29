//! Column-packing math for glyphwire-ls's plain (non `-l`) listing. Given
//! the entry count, the widest entry's display width in *cells*, and the
//! layer width in cells, it decides how many entry columns fit and where
//! each entry lands (column-major, like `ls -C`). Kept in its own file --
//! only `glyphwire.codepointWidth` (East Asian Width) is imported, no
//! IO/client/server -- and exposed as the `ls_support` build module so
//! both `ls/main.zig` and the test runner (`tests/ls_tests.zig`) can
//! import it; a Zig module can't reach across directories with a relative
//! `@import`.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// Display width of `text` in terminal cells: each codepoint counts 1,
/// except East Asian Wide/Fullwidth ones (CJK, kana, ...) which count 2 --
/// the same width model `core.writeText` advances the cursor by. Invalid
/// UTF-8 falls back to a byte count.
pub fn displayWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return text.len;
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += len;
            w += 1;
            continue;
        };
        w += glyphwire.codepointWidth(cp);
        i += len;
    }
    return w;
}

/// The parts of the layout that don't depend on the particular listing:
/// how wide the icon area before a name is, how many cell-rows one
/// entry's block occupies, the gap between adjacent columns, and the
/// floor/cap on the name area.
pub const Options = struct {
    /// Cell columns reserved for the entry's icon before its name starts.
    icon_cols: usize,
    /// Cell-rows one entry occupies: 1 for the small single-cell icons,
    /// 2 for the natural-scaled large icons that overflow into the row
    /// below (the existing `-L` / default behavior in `writeGrid`).
    block_rows: usize,
    /// Blank cell columns between one entry-block and the next.
    gap: usize = 2,
    /// The name area is clamped to at least this many columns, so an
    /// all-short-names listing doesn't collapse to a sliver ...
    min_name_cols: usize = 8,
    /// ... and at most this many, so one very long name (a deep symlink
    /// target) doesn't force a single super-wide column. Names past this
    /// are truncated with an ellipsis (`truncateToCols`).
    max_name_cols: usize = 40,
};

pub const Grid = struct {
    /// Number of entry columns across the layer (always >= 1).
    cols: usize,
    /// Rows of entries per column. Column-major fill means the last
    /// column can be short; every earlier column is full.
    rows: usize,
    /// Cell columns from one block's left edge to the next block's.
    block_cols: usize,
    /// Cell rows from one block's top edge to the next block's -- equal
    /// to `Options.block_rows`, carried here so callers have the whole
    /// layout in one struct.
    block_rows: usize,
    /// Codepoints the name area holds before `truncateToCols` cuts it.
    name_cols: usize,

    /// Column-major slot for entry `index` (0-based): entries fill the
    /// first column top to bottom, then the next, matching `ls -C`.
    /// `row`/`col` are in entry units -- multiply by `block_rows` /
    /// `block_cols` for cell offsets from the grid's anchor.
    pub fn slot(self: Grid, index: usize) struct { row: usize, col: usize } {
        return .{ .row = index % self.rows, .col = index / self.rows };
    }
};

/// Decide the grid for a listing. `entry_count` must be >= 1.
/// `longest_name_cols` is the widest entry's full display width (filename
/// plus any `/` or ` -> target` suffix) in codepoints. `layer_cols` is
/// the layer viewport width in cells.
pub fn compute(entry_count: usize, longest_name_cols: usize, layer_cols: usize, opts: Options) Grid {
    std.debug.assert(entry_count >= 1);

    const name_cols = std.math.clamp(longest_name_cols, opts.min_name_cols, opts.max_name_cols);
    const block_cols = opts.icon_cols + name_cols + opts.gap;

    // How many whole blocks fit. The last column carries no trailing
    // gap, so allow one extra `gap` of slack when dividing.
    var cols: usize = 1;
    if (block_cols > 0 and layer_cols + opts.gap >= block_cols) {
        cols = (layer_cols + opts.gap) / block_cols;
    }
    if (cols < 1) cols = 1;
    if (cols > entry_count) cols = entry_count;

    // With `cols` picked, `rows` is fixed; then tighten `cols` back down
    // so there's no fully-empty trailing column (N=5 over 4 columns is
    // really 3 columns of 2), same shape `ls -C` produces.
    var rows = (entry_count + cols - 1) / cols;
    if (rows < 1) rows = 1;
    cols = (entry_count + rows - 1) / rows;

    return .{
        .cols = cols,
        .rows = rows,
        .block_cols = block_cols,
        .block_rows = opts.block_rows,
        .name_cols = name_cols,
    };
}

/// `text` limited to at most `max_cols` display cells (East Asian wide
/// codepoints count 2 -- see `displayWidth`). Returns `text` unchanged
/// when it already fits; otherwise copies whole codepoints into `buf`
/// until adding the next would leave no room for a trailing `…`, appends
/// the `…`, and returns that slice -- same trailing-ellipsis shape the
/// server-side table cells use (`core.writeCellRun`). A wide codepoint is
/// never split; the result can therefore be `max_cols - 2` wide when the
/// cut lands just before one. `buf` must hold at least `text.len + 3`
/// bytes.
pub fn truncateToCols(buf: []u8, text: []const u8, max_cols: usize) []const u8 {
    if (max_cols == 0) return text[0..0];
    if (!std.unicode.utf8ValidateSlice(text)) {
        // Invalid UTF-8: fall back to a plain byte clamp.
        return text[0..@min(text.len, max_cols)];
    }
    if (displayWidth(text) <= max_cols) return text;

    const ellipsis = "\u{2026}"; // one display cell
    var out: usize = 0;
    var used: usize = 0; // display cells written so far
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch 0xFFFD;
        const cw = glyphwire.codepointWidth(cp);
        if (used + cw + 1 > max_cols) break; // +1 leaves room for the ellipsis
        @memcpy(buf[out..][0..len], text[i..][0..len]);
        out += len;
        used += cw;
        i += len;
    }
    @memcpy(buf[out..][0..ellipsis.len], ellipsis);
    return buf[0 .. out + ellipsis.len];
}
