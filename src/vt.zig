// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The VT escape machine a `Layer` runs its `write_text` bytes through:
//! C0 controls, `ESC` / CSI / string sequences, SGR colour (`SgrPen`),
//! the line-drawing charsets, DEC private modes, tab stops, REP and the
//! replies to terminal queries. See `EscState` for what is interpreted
//! and what is only recognized and dropped.
//!
//! Its state is `Vt`, embedded in each layer as `Layer.vt`; the machine
//! itself is free functions over the `*Layer`, since nearly every step
//! moves the layer's cursor or writes its cells. `Layer.writeRuns` feeds
//! it (`consumeControl`), and everything else here is reached from there.
//! The scroll region and the alternate screen are `Vt` state too, since
//! only escapes change them. The grid operations the machine drives --
//! line feeds, scrolling a band, erasing, inserting and deleting cells --
//! stay `Layer`'s, because writes that never touch an escape use them too.

const std = @import("std");
const core = @import("core.zig");
const key_encode = @import("key_encode.zig");

const Layer = core.Layer;
const Cell = core.Cell;
const Cursor = core.Cursor;
const SavedCursor = core.SavedCursor;
const Color = core.Color;
const ColorRef = core.ColorRef;
const Background = core.Background;
const Underline = core.Underline;
const UnderlineStyle = core.UnderlineStyle;
const default_style = core.default_style;
const grapheme_inline_len = core.grapheme_inline_len;
const tab_width = core.tab_width;
const theme = core.theme;

/// One layer's VT state. Only the machine writes it. The layer's grid
/// reads the alternate screen and the scroll region (which buffer a row
/// comes from, where a line feed scrolls), and glyphwire-host reads the
/// few DEC modes that decide how it draws and scrolls the layer
/// (`cursor_visible`, `app_cursor_keys`).
pub const Vt = struct {
    /// Escape-sequence machine state (see `EscState`). `.ground` except
    /// partway through a single `writeText` call that is
    /// interpreting/discarding an `ESC ...` sequence -- reset back to
    /// `.ground` before that call returns, so an unterminated sequence
    /// never leaks into the next one.
    esc_state: EscState = .ground,
    /// Accumulates the parameter/intermediate bytes of the `ESC [ ...`
    /// sequence currently being parsed (`esc_state == .csi`), up to its
    /// final byte. Fixed-size: a sequence longer than this is abandoned
    /// (`csi_len` stops growing and the final byte finds a truncated
    /// buffer -- harmless, it just parses as far as it got). Cleared
    /// alongside `esc_state` at the end of every `writeText` call.
    csi_buf: [48]u8 = undefined,
    csi_len: usize = 0,
    /// True after `SO` (0x0E) shifted G1 into GL; false (the default, and
    /// after `SI` / 0x0F) means G0 is active. Which set is actually line
    /// drawing while active is `g0_line_drawing`/`g1_line_drawing`. Reset
    /// to `false` at the end of every `writeText` call, matching
    /// `esc_state`/`pen`'s call-scoped reset -- see `EscState`.
    shift_out: bool = false,
    /// True while G0 is designated as the VT100 special graphics/
    /// line-drawing set (`ESC ( 0`) rather than US-ASCII (`ESC ( B`, the
    /// default). xterm-style terminfo (`smacs`/`rmacs`) toggles this
    /// directly and never sends SO/SI. Reset to `false` at the end of
    /// every `writeText` call -- see `EscState`.
    g0_line_drawing: bool = false,
    /// Same as `g0_line_drawing` but for G1 (`ESC ) 0` / `ESC ) B`).
    /// screen/tmux-style terminfo designates this once and shifts into it
    /// with SO/SI (`shift_out`) instead of redesignating G0.
    g1_line_drawing: bool = false,
    /// Scratch SGR "pen" built up from `ESC [ ... m` sequences while a
    /// single `writeText` call runs -- see `SgrPen`. Reset to `.{}` at
    /// the *start* of every `writeTextTagged` call, so a colour is
    /// honoured only for the rest of the chunk that set it and never
    /// bleeds into a later call (the shell's prompt, the next command's
    /// output). Lives on the layer only because the `ESC [` machine
    /// (`consumeControl` -> `stepEscape` -> `execCsi`) needs somewhere to
    /// accumulate it mid-call.
    pen: SgrPen = .{},
    /// DECSC / DECRC (`ESC 7` / `ESC 8`, and the ANSI.SYS `CSI s` /
    /// `CSI u`) saved state, or null if nothing has been saved. See
    /// `SavedCursor`.
    saved_cursor: ?SavedCursor = null,
    /// DECTCEM (`CSI ? 25 h/l`): whether the host should paint a caret
    /// for this layer. Advisory data for the renderer only.
    cursor_visible: bool = true,
    /// DECCKM (`CSI ? 1 h/l`, application cursor keys). Tracked here only
    /// so glyphwire-host can tell a full-screen program (`less`, `vim`,
    /// `htop`, `fzf` -- they all set it; `ls`/`cat`/`grep` don't) is
    /// driving the primary screen and stop fighting it for the scrollback
    /// view -- see `host/main.zig`'s `screenOwnedByProgram`. The pty input
    /// path has its own copy in `pty.ModeTracker` (a synchronous local
    /// read; this one would need a wire round trip).
    app_cursor_keys: bool = false,
    /// DECAWM (`CSI ? 7 h/l`): whether printing past the last column
    /// wraps to the next line. Off, the last column is overwritten in
    /// place. On by default, like every terminal.
    autowrap: bool = true,
    /// IRM (`CSI 4 h/l`): while set, a printed character shifts the rest
    /// of the row right (`insertCells`) instead of overwriting.
    insert_mode: bool = false,
    /// Horizontal tab stops set by HTS / cleared by TBC, one flag per
    /// column, or null for the default stop every `tab_width` columns.
    /// Allocated the first time a program edits a stop, and rebuilt on a
    /// width change (new columns get the default stops). Owned.
    tab_stops: ?[]bool = null,
    /// The last graphic character printed, for REP (`CSI n b`, "repeat
    /// it n more times") -- the grapheme as placed (`last_glyph_len == 0`
    /// is "nothing printed yet") with the width and resolved style it was
    /// placed with. ncurses emits REP for runs of one character
    /// (borders, blank padding) under xterm-256color.
    last_glyph: [grapheme_inline_len]u8 = undefined,
    last_glyph_len: u8 = 0,
    last_glyph_w: u2 = 1,
    last_glyph_fg: Color = default_style.fg,
    last_glyph_bg: ?Background = null,
    last_glyph_ul: UnderlineStyle = .{},
    /// The kitty keyboard protocol flag stacks, tracked from the same
    /// stream `pty.ModeTracker` reads, only so `CSI ? u` (the protocol's
    /// "is this supported?" query) gets an answer here -- the encoding
    /// itself happens in glyphwire-shell. See `key_encode.KittyKeyboard`.
    kitty_keys: key_encode.KittyKeyboard = .{},
    /// Bytes this layer owes the program writing to it -- a terminal
    /// reply to a `CSI 6n` / `CSI c` / DECRQM query parsed out of
    /// `writeText`. The dispatcher drains it right after each `write_text`
    /// (`takeReply`) and forwards it as a `terminal_reply` notification;
    /// glyphwire-shell writes it to the pty master.
    reply_buf: [96]u8 = undefined,
    reply_len: usize = 0,
    /// The alternate screen (xterm `?1049` / `?47` / `?1047`): a
    /// lazily-allocated `width * height` cell array, row-major, with **no
    /// scrollback ring** -- a full-screen program's transient screen.
    /// Null until first entered; kept allocated after exit for reuse,
    /// rebuilt blank by `Layer.resize`, freed in `Layer.deinit`.
    alt_cells: ?[]Cell = null,
    /// True while the alt screen is the active target: `Layer.cell` /
    /// `liveRow` / `viewRow` read and write `alt_cells`, and scrolling
    /// shuffles within it with no history. `Layer.cursor` is then the alt
    /// cursor and the primary cursor is stashed in `stashed_cursor` (and
    /// vice versa). See `enterAltScreen` / `exitAltScreen`.
    on_alt: bool = false,
    stashed_cursor: Cursor = .{},
    /// DECSTBM scroll region, inclusive, in viewport rows. `[0, height-1]`
    /// (the default -- `Layer.regionActive()` false) keeps the classic
    /// ring-buffer scroll-into-scrollback on a line feed past the bottom;
    /// a narrower region confines line feeds, `SU`/`SD` and `IL`/`DL` to
    /// `[scroll_top, scroll_bot]` with no scrollback. `scroll_bot` is set
    /// to `height-1` by `Layer.init` and reset by `Layer.resize`.
    scroll_top: usize = 0,
    scroll_bot: usize = 0,
};

/// State of `Layer`'s small escape-sequence machine (see
/// `consumeControl` / `stepEscape`). glyphwire has no full
/// VT100/ANSI model -- it replaces that, per decisions.md -- but a plain
/// program mirrored onto the grid emits colour codes and simple
/// cursor-move sequences, and drawing the raw bytes (`[31m` etc.) as
/// garbage graphemes reads worse than acting on the common ones. So
/// `writeText`:
///
///  - **interprets** `ESC [ ... m` (SGR): colours + bold/dim/inverse are
///    folded into `Vt.pen` and thence into each printed cell's
///    `Style` -- see `SgrPen`. Italic/underline/strikethrough are parsed
///    and ignored (colour-only for now).
///  - **interprets** a handful of `ESC [ ...` cursor/erase finals:
///    `A`/`B`/`C`/`D` (cursor up/down/right/left), `G` (column),
///    `H`/`f` (row;col), `J` (erase in display), `K` (erase in line).
///  - **interprets** VT100 charset designation/shift: `ESC ( <c>` / `ESC )
///    <c>` designate G0/G1 as the special graphics and line-drawing set
///    (`c == '0'`) or plain ASCII (anything else), and `SO`/`SI` (0x0E/
///    0x0F) shift which of G0/G1 is active. While the active set is line
///    drawing, printable bytes `` ` ``..`~` (0x60..0x7e) are mapped to
///    their Unicode box-drawing/symbol glyph (`acsGraphic`) instead of
///    printed literally -- see `g0_line_drawing`/`g1_line_drawing`. This is
///    what `smacs`/`rmacs` (xterm-style, redesignates G0 directly) and
///    `screen`/`tmux`-style (SO/SI over a G1 designated once) both compile
///    down to, and it's how ncurses draws panel borders when it isn't
///    using UTF-8 line-drawing glyphs directly.
///  - **discards** every other `ESC [ ...` (CSI) final and every
///    `ESC ] ... ` / `ESC P|X|^|_ ... ` (OSC and other string-terminated)
///    sequence, same as the old stripper -- recognized well enough to
///    find the end, then dropped. So is `ESC` + any other intermediate
///    (`ESC # 8`, `ESC % G`). A sequence's payload never reaches the
///    grid, multi-byte characters included (`consumeInSequence`).
///  - follows xterm for controls *inside* a sequence: a C0 control is
///    carried out and the sequence goes on, CAN/SUB cancel it, and ESC
///    starts a new one (`consumeControl`).
///
/// Nothing carries across `writeText` calls. The machine is reset to
/// `.ground` (and the CSI parameter buffer cleared) at the end of every
/// call, and the SGR `pen` (colour state) is reset at the *start* of
/// every call -- a sequence, or a colour, is scoped entirely to the
/// chunk that carried it. This deliberately gives up on a sequence or an
/// SGR colour a pipe split across two `write_text` chunks (rare -- a
/// plain program emits each escape in one `write`, and its colour
/// usually with the text it colours) in exchange for never letting a
/// lone trailing `ESC`, a truncated `ESC [ ...`, an unterminated
/// `ESC ] ...` (OSC), or an un-reset `ESC [ 31 m` silently affect
/// anything written afterward -- glyphwire-shell's own prompt included.
pub const EscState = enum {
    /// Not inside a sequence -- the normal case.
    ground,
    /// Last byte was ESC (0x1b); the next byte selects the sequence kind.
    esc,
    /// Inside `ESC [ ...` -- consume parameter/intermediate bytes
    /// (0x20..0x3f) until a final byte (0x40..0x7e) ends it.
    csi,
    /// Inside a string-terminated sequence (`ESC ]`, `ESC P`, `ESC X`,
    /// `ESC ^`, `ESC _`) -- consume until BEL (0x07) or ST (`ESC \`).
    string,
    /// Saw `ESC (`; the next byte designates G0 (`g0_line_drawing`).
    charset_g0,
    /// Saw `ESC )`; the next byte designates G1 (`g1_line_drawing`).
    charset_g1,
    /// Saw `ESC` and an intermediate byte (0x20..0x2f) other than `(`
    /// / `)` -- `ESC # 8`, `ESC % G`, `ESC * 0`, `ESC SP F`. More
    /// intermediates may follow; a final byte (0x30..0x7e) ends it.
    /// Recognized and dropped.
    esc_intermediate,
};


// ── Screen state ────────────────────────────────────────────────────────
//
// The pending-wrap column, the scroll region and the alternate screen.
// Only escapes set the region or switch screens, so that state is `Vt`'s;
// `Layer`'s grid code reads it to pick a row's buffer and to decide where
// a line feed scrolls.

/// The cursor column with the pending-wrap position folded in. After
/// a character lands on the last column the cursor sits one *past*
/// it (`col == width`) so the next character wraps; a real terminal
/// keeps the cursor on the last column with a "wrap next" flag
/// instead. Every VT operation that isn't printing -- an erase, a
/// cursor report, a relative move -- sees that last column, not the
/// phantom one past it.
fn pendingCol(self: *const Layer) usize {
    return @min(self.cursor.col, self.width - 1);
}

/// Whether viewport row `row` is inside the DECSTBM scroll region.
fn rowInRegion(self: *const Layer, row: usize) bool {
    return row >= self.vt.scroll_top and row <= self.vt.scroll_bot;
}

/// `CSI ? 1049 h` (or `?47` / `?1047`) -- switch to the alternate
/// screen: stash the primary cursor, home, and show a cleared
/// full-screen buffer with no scrollback. All three variants are
/// treated alike (save cursor + clear on entry) -- the B1
/// simplification; virtually every modern full-screen program uses
/// `?1049`.
fn enterAltScreen(self: *Layer) !void {
    if (self.vt.on_alt) return;
    if (self.vt.alt_cells == null)
        self.vt.alt_cells = try self.alloc.alloc(Cell, self.width * self.height);
    for (self.vt.alt_cells.?) |*c| c.* = .{};
    self.vt.stashed_cursor = self.cursor;
    self.cursor = .{};
    self.vt.scroll_top = 0;
    self.vt.scroll_bot = self.height - 1;
    self.vt.on_alt = true;
    self.revision += 1;
    self.render_gen +%= 1;
}

/// `CSI ? 1049 l` -- back to the primary screen (its scrollback and
/// contents were never touched), restoring the stashed cursor.
fn exitAltScreen(self: *Layer) void {
    if (!self.vt.on_alt) return;
    self.vt.on_alt = false;
    self.cursor = self.clampCursor(self.vt.stashed_cursor);
    self.vt.scroll_top = 0;
    self.vt.scroll_bot = self.height - 1;
    self.revision += 1;
    self.render_gen +%= 1;
}

/// Maps a byte of the VT100 "special graphics and line drawing" set
/// (`Layer.g0_line_drawing` / `g1_line_drawing`, designated by `ESC ( 0` /
/// `ESC ) 0`) to its Unicode glyph. Only `` ` ``..`~` (0x60..0x7e) are part
/// of the set; callers must not pass anything outside that range. Table
/// per the DEC VT220 reference manual (table 2-4), reproduced verbatim by
/// the Linux console (`console_codes(4)`) and ncurses/terminfo's `acsc`
/// capability -- this is the same mapping every terminal that supports the
/// set uses.
pub fn acsGraphic(byte: u8) u21 {
    return switch (byte) {
        '`' => 0x25c6, // ◆ diamond
        'a' => 0x2592, // ▒ medium shade
        'b' => 0x2409, // ␉ HT symbol
        'c' => 0x240c, // ␌ FF symbol
        'd' => 0x240d, // ␍ CR symbol
        'e' => 0x240a, // ␊ LF symbol
        'f' => 0x00b0, // ° degree
        'g' => 0x00b1, // ± plus-minus
        'h' => 0x2424, // ␤ NL symbol
        'i' => 0x240b, // ␋ VT symbol
        'j' => 0x2518, // ┘ lower-right corner
        'k' => 0x2510, // ┐ upper-right corner
        'l' => 0x250c, // ┌ upper-left corner
        'm' => 0x2514, // └ lower-left corner
        'n' => 0x253c, // ┼ crossing lines
        'o' => 0x23ba, // ⎺ scan line 1
        'p' => 0x23bb, // ⎻ scan line 3
        'q' => 0x2500, // ─ horizontal line
        'r' => 0x23bc, // ⎼ scan line 7
        's' => 0x23bd, // ⎽ scan line 9
        't' => 0x251c, // ├ left T
        'u' => 0x2524, // ┤ right T
        'v' => 0x2534, // ┴ bottom T
        'w' => 0x252c, // ┬ top T
        'x' => 0x2502, // │ vertical line
        'y' => 0x2264, // ≤ less-or-equal
        'z' => 0x2265, // ≥ greater-or-equal
        '{' => 0x03c0, // π pi
        '|' => 0x2260, // ≠ not equal
        '}' => 0x00a3, // £ pound sterling
        '~' => 0x00b7, // · middle dot
        else => byte, // not part of the set -- callers never pass this
    };
}

/// Which of the pen's three colours an SGR `38` / `48` / `58` sets. Named
/// rather than anonymous only so `applySgr` and `setSgrColor` can name the
/// same type.
const SgrColorTarget = enum { fg, bg, ul };

/// The "current pen" a `Layer` builds up from SGR (`ESC [ ... m`) sequences
/// seen in mirrored plain-command output -- glyphwire's small, deliberate
/// step toward honouring the escape codes a non-glyphwire-aware program
/// emits (compiler diagnostics in colour, `pip`/`npm` progress bars),
/// rather than the full VT model a real terminal library would bring.
///
/// **Colour, plus underline.** The basic and bright colours (and 0-15 of
/// `38;5;N`) are references to the theme's palette slots, not RGB --
/// see `theme`. `bold` maps a basic (30-37) foreground to its bright
/// (90-97) slot; `dim` moves a slot to its dim level (`SgrPen.dimmed`);
/// `inverse` swaps foreground and background. All three are folded into the
/// concrete `Cell.style` at write time -- no attribute bitflags on `Style`.
/// Underline (`4`, `4:1`..`4:5`, `21`, `24`) and its colour (`58`, `59`)
/// are carried through to `Style.underline` and drawn -- see `Underline`.
/// Italic / blink / strikethrough are still *parsed and ignored*: they need
/// font faces in the atlas rather than a rect at the baseline.
///
/// A `null` `fg` / `bg` override means "fall back to the `write_text`
/// call's own `fg`/`bg` argument (and then `default_style`)". `ESC [ 0 m`
/// (or `ESC [ m`) resets the whole pen. See `Vt.pen` for the
/// cross-call persistence rule.
pub const SgrPen = struct {
    /// Resolved foreground override, or null for "use the call's fg arg".
    fg: ?Color = null,
    /// Resolved background override, or null for "use the call's bg arg".
    bg: ?Color = null,
    /// Palette index 0-7 when `fg` was set by a basic `30`-`37` code, so a
    /// later `bold` can promote it to bright. Null once `fg` is bright,
    /// 256-indexed, truecolor, or default.
    fg_basic: ?u3 = null,
    bold: bool = false,
    dim: bool = false,
    inverse: bool = false,
    /// Underline style and colour from `4` / `4:n` / `21` / `24` / `58` /
    /// `59`. Unlike `bold`/`dim`/`inverse` this is not folded into the
    /// colours -- it passes straight through to `Style.underline`.
    underline: UnderlineStyle = .{},

    /// ANSI colour `n` (0-7 normal, 8-15 bright) -- a reference to the
    /// theme's palette slot for it, not a fixed RGB, so terminal output
    /// takes the theme's colours.
    pub fn ansi16(n: u4) Color {
        return Color.slot(theme.ansiSlot(n));
    }

    /// Maps an xterm 256-colour index to a colour: 0-15 the theme's
    /// palette slots (`ansi16`), 16-231 the 6x6x6 cube, 232-255 the
    /// 24-step grey ramp.
    pub fn xterm256(idx: u8) Color {
        if (idx < 16) return ansi16(@intCast(idx));
        if (idx < 232) {
            const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
            const c = idx - 16;
            return .{
                .r = levels[(c / 36) % 6],
                .g = levels[(c / 6) % 6],
                .b = levels[c % 6],
            };
        }
        const v: u8 = @intCast(8 + 10 * @as(u16, idx - 232));
        return .{ .r = v, .g = v, .b = v };
    }

    /// Applies one SGR parameter list (the bytes between `ESC [` and the
    /// `m`, e.g. `"1;38;5;208"`) to the pen. Tolerant: unknown or
    /// malformed parameters are skipped, never an error -- matching the
    /// "recognize and don't choke" spirit of the old escape *stripper*
    /// this replaces.
    ///
    /// `:` sub-parameter separators are accepted where `;` is, *and* which
    /// separator preceded each parameter is remembered (`colon`). That
    /// distinction used to be discardable, when the colon forms only ever
    /// appeared in `38`/`48` colours where either spelling means the same
    /// thing. It stopped being discardable with underline styles: `4:3` is
    /// a curly underline, while `4;3` is an underline *and* an italic, and
    /// collapsing the two would turn every `ESC [ 4;3 m` into a squiggle.
    pub fn applySgr(self: *SgrPen, params: []const u8) void {
        // At most a handful of numeric params in any real SGR sequence;
        // a longer/garbled one is truncated rather than grown. `null` =
        // an empty field -- a standalone empty param means 0 (reset), and
        // an empty colour-space id in the colon form `38:2::r:g:b` is
        // skipped over (see below).
        var nums: [24]?u16 = undefined;
        // `colon[i]` is true when parameter `i` was introduced by a `:`
        // rather than a `;` -- i.e. it is a sub-parameter of `i - 1`.
        // Never true for `i == 0`.
        var colon: [24]bool = @splat(false);
        var n: usize = 0;
        var start: usize = 0;
        var idx: usize = 0;
        while (idx <= params.len) : (idx += 1) {
            const at_end = idx == params.len;
            if (!at_end and params[idx] != ';' and params[idx] != ':') continue;
            if (n == nums.len) break;
            const tok = params[start..idx];
            nums[n] = if (tok.len == 0) null else (std.fmt.parseInt(u16, tok, 10) catch null);
            // The separator *before* this token decided whether it is a
            // sub-parameter, so it is the one at `start - 1`.
            colon[n] = start > 0 and params[start - 1] == ':';
            n += 1;
            if (at_end) break;
            start = idx + 1;
        }
        if (n == 0) {
            self.* = .{}; // bare `ESC [ m` is `ESC [ 0 m`
            return;
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const code = nums[i] orelse 0; // empty standalone param == 0
            switch (code) {
                0 => self.* = .{},
                1 => self.bold = true,
                2 => self.dim = true,
                22 => {
                    self.bold = false;
                    self.dim = false;
                },
                7 => self.inverse = true,
                27 => self.inverse = false,
                // `4` alone is a single underline; `4:n` names the style.
                // Only a *sub*-parameter can do that -- `4;3` is an
                // underline followed by an italic, which is why the
                // tokenizer keeps the separators (see above).
                4 => {
                    if (i + 1 < n and colon[i + 1]) {
                        self.underline.style = switch (nums[i + 1] orelse 0) {
                            0 => .none,
                            1 => .single,
                            2 => .double,
                            3 => .curly,
                            4 => .dotted,
                            5 => .dashed,
                            // An unknown style id still means "underlined"
                            // -- better a plain line than none at all.
                            else => .single,
                        };
                        i += 1;
                    } else {
                        self.underline.style = .single;
                    }
                },
                // ECMA-48 calls 21 "doubly underlined" and xterm reads it
                // as "bold off"; kitty, VTE and every terminal that draws
                // underline styles take the ECMA reading, so we do too.
                21 => self.underline.style = .double,
                24 => self.underline.style = .none,
                59 => self.underline.color = null,
                // Parsed and ignored: italic (3/23), blink (5/25),
                // strikethrough (9/29) -- see `SgrPen`'s doc comment.
                3, 5, 9, 23, 25, 29 => {},
                30...37 => {
                    self.fg_basic = @intCast(code - 30);
                    self.fg = ansi16(@intCast(code - 30));
                },
                39 => {
                    self.fg = null;
                    self.fg_basic = null;
                },
                40...47 => self.bg = ansi16(@intCast(code - 40)),
                49 => self.bg = null,
                90...97 => {
                    self.fg_basic = null;
                    self.fg = ansi16(@intCast(8 + (code - 90)));
                },
                100...107 => self.bg = ansi16(@intCast(8 + (code - 100))),
                38, 48, 58 => {
                    // `38;5;N` (256) / `38;2;R;G;B` (truecolor), with the
                    // colon variants `38:5:N` and `38:2[:cs]:R:G:B`. Skip
                    // the params consumed so the outer loop doesn't re-read
                    // them as standalone codes. `58` is the same grammar
                    // for the underline colour (`59` resets it) -- which is
                    // how a red squiggle gets under white text.
                    const target: SgrColorTarget = switch (code) {
                        38 => .fg,
                        48 => .bg,
                        else => .ul,
                    };
                    if (i + 1 >= n) break;
                    const mode = nums[i + 1] orelse 0;
                    if (mode == 5) {
                        if (i + 2 >= n) break;
                        const col = xterm256(@intCast((nums[i + 2] orelse 0) & 0xff));
                        self.setSgrColor(target, col);
                        i += 2;
                    } else if (mode == 2) {
                        // The colon form may carry an empty colour-space
                        // id right after the `2` -- step past it.
                        var base = i + 2;
                        if (base < n and nums[base] == null) base += 1;
                        if (base + 2 >= n) break;
                        const col = Color{
                            .r = @intCast((nums[base] orelse 0) & 0xff),
                            .g = @intCast((nums[base + 1] orelse 0) & 0xff),
                            .b = @intCast((nums[base + 2] orelse 0) & 0xff),
                        };
                        self.setSgrColor(target, col);
                        i = base + 2;
                    } else break;
                },
                else => {}, // unknown SGR code -- ignore
            }
        }
    }

    /// Stores one resolved 256-colour / truecolor value on the pen, for
    /// whichever of `38` / `48` / `58` introduced it. Split out only
    /// because all three spellings share the parameter grammar above.
    fn setSgrColor(self: *SgrPen, target: SgrColorTarget, col: Color) void {
        switch (target) {
            .fg => {
                self.fg = col;
                // No longer a basic 30-37 colour, so a later `bold` can't
                // promote it -- same rule as `90`-`97`.
                self.fg_basic = null;
            },
            .bg => self.bg = col,
            .ul => self.underline.color = col,
        }
    }

    /// Resolves the concrete `(fg, bg, underline)` a printed cell gets,
    /// given the pen and the `write_text` call's own arguments (`bg` is a
    /// `?Background`: `null` = "leave the cell's existing background",
    /// per `write_text`'s `transparent_bg`). The pen overrides the
    /// arguments where it has an opinion; `bold`/`dim`/`inverse` are then
    /// folded into the result.
    ///
    /// The underline is "whichever of the two asked for one": an SGR `4`
    /// in a mirrored program's output underlines text the call itself left
    /// plain, and a call's own `underline` (a client drawing a diagnostic
    /// squiggle) survives output that never mentions underlines. They can
    /// only conflict inside one `write_text` whose text also carries SGR,
    /// and there the escape in the text is the more specific instruction.
    pub fn resolve(
        self: SgrPen,
        arg_fg: Color,
        arg_bg: ?Background,
        arg_ul: UnderlineStyle,
    ) struct { fg: Color, bg: ?Background, underline: UnderlineStyle } {
        var fg: Color = self.fg orelse arg_fg;
        if (self.bold) {
            if (self.fg_basic) |idx| fg = Color.slot(theme.ansiSlot(@as(u4, idx) + 8));
        }
        if (self.dim) fg = SgrPen.dimmed(fg);

        var bg: ?Background = if (self.bg) |c| .{ .color = c } else arg_bg;

        if (self.inverse) {
            const bg_color: Color = switch (bg orelse Background{ .color = default_style.bg.color }) {
                .color => |c| c,
                // An image/icon background can't be swapped into the fg;
                // fall back to the default bg colour for the inverse.
                else => default_style.bg.color,
            };
            const new_bg = fg;
            // The default background is transparent (alpha 0); swapped
            // into the foreground it has to become visible ink -- the
            // theme's background colour, which is what it showed.
            fg = if (bg_color.a == 0 and bg_color.ref == .none) Color.role(.bg) else bg_color.withAlpha(255);
            bg = .{ .color = new_bg };
        }

        // The pen wins only where it has something to say: a style of
        // `.none` is "no opinion", not "no underline". Its colour follows
        // the same rule, and falls back to the argument's rather than to
        // the fg, so `ESC [ 4 m` inside a run the client already gave a
        // colour keeps that colour.
        var ul = arg_ul;
        if (self.underline.style != .none) ul.style = self.underline.style;
        if (self.underline.color) |c| ul.color = c;

        return .{ .fg = fg, .bg = bg, .underline = ul };
    }

    /// SGR `2`'s faint foreground. A slot steps down to its hue's dim
    /// level, which is what the dim row of the palette is for, and the
    /// default text colour becomes `fg_dim`. Any other role is left as it
    /// is -- darkening it needs the theme, which the pen doesn't have --
    /// and a literal is darkened directly.
    fn dimmed(c: Color) Color {
        return switch (c.ref) {
            .slot => |s| Color.slot(theme.atLevel(s, .dim)).withAlpha(c.a),
            .role => |r| if (r == .fg) Color.role(.fg_dim).withAlpha(c.a) else c,
            .none => .{
                .r = @intCast(@as(u16, c.r) * 55 / 100),
                .g = @intCast(@as(u16, c.g) * 55 / 100),
                .b = @intCast(@as(u16, c.b) * 55 / 100),
                .a = c.a,
            },
        };
    }
};

/// Returns true when `byte` was consumed as a control byte (C0 control
/// or part of an `ESC ...` sequence) and must not be placed as a
/// grapheme; false for an ordinary printable byte the caller should
/// draw. Only ever called with a single-byte codepoint slice, so
/// `byte < 0x80` always holds. See `writeText`'s doc comment for the
/// per-control semantics and `EscState` for the escape-strip rationale.
pub fn consumeControl(self: *Layer, byte: u8) !bool {
    if (self.vt.esc_state != .ground) {
        // A C0 control inside a sequence is acted on as if it came
        // before it, and the sequence carries on (xterm, and the DEC
        // parser it follows): a CR or BS a program emits mid-CSI still
        // moves the cursor rather than landing in the parameters. CAN
        // and SUB cancel the sequence, and ESC starts a new one. A
        // string sequence is different -- its terminators are BEL and
        // ESC (see `stepEscape`), and any other control is payload.
        if (byte < 0x20 and self.vt.esc_state != .string) {
            switch (byte) {
                0x18, 0x1a => {
                    self.vt.esc_state = .ground;
                    self.vt.csi_len = 0;
                },
                0x1b => {
                    self.vt.esc_state = .esc;
                    self.vt.csi_len = 0;
                },
                else => execC0(self, byte),
            }
            return true;
        }
        if (self.vt.esc_state == .string and (byte == 0x18 or byte == 0x1a)) {
            self.vt.esc_state = .ground;
            return true;
        }
        try stepEscape(self, byte);
        return true;
    }
    if (byte == 0x1b) {
        self.vt.esc_state = .esc; // ESC: start of a sequence to strip
        return true;
    }
    if (byte >= 0x20 and byte != 0x7f) return false; // printable
    execC0(self, byte);
    return true;
}

/// Acts on one C0 control byte (or DEL) outside an escape sequence's
/// own syntax -- see `consumeControl`.
fn execC0(self: *Layer, byte: u8) void {
    switch (byte) {
        // LF, VT, FF. On an ordinary layer all three are a newline
        // (CR + LF), the cooked-terminal reading a client's `"a\nb"`
        // wants. A `pty_mode` layer takes them literally -- down one
        // row, same column: the kernel's ONLCR already turned a cooked
        // program's `\n` into `\r\n`, and a raw-mode one (vim, nvim,
        // Claude Code) that sends a bare LF means "cursor down".
        '\n', 0x0b, 0x0c => {
            self.cursor.col = if (self.pty_mode) pendingCol(self) else 0;
            self.lineFeed();
        },
        '\r' => self.cursor.col = 0, // CR
        // HT: to the next tab stop, clamped to the last column (no wrap)
        '\t' => self.cursor.col = nextTabStop(self, self.cursor.col),
        // BS: back one column, non-destructive; a no-op at column 0.
        // From the pending-wrap position past the last column it lands
        // on the second-to-last, as on a real terminal, where the
        // cursor was really still on the last column.
        0x08 => self.cursor.col = pendingCol(self) -| 1,
        0x0e => self.vt.shift_out = true, // SO -- invoke G1 into GL
        0x0f => self.vt.shift_out = false, // SI -- invoke G0 into GL
        // Every other C0 byte (NUL, BEL, DLE..SUB, FS..US) and DEL: dropped.
        else => {},
    }
}

/// Returns true when the multi-byte codepoint `cp` belongs to an escape
/// sequence still open (`esc_state != .ground`) and must not be placed
/// as a grapheme. `consumeControl` only ever sees single bytes, so
/// without this a non-ASCII character inside a sequence fell through and
/// was drawn at the cursor -- Claude Code animates its spinner in the
/// window title (`ESC ] 0 ; ✳ Claude Code BEL`), and every frame left
/// the glyph wherever its input caret sat.
///
/// Inside a string sequence (OSC and friends) the codepoint is payload,
/// and U+009C, the C1 form of ST, ends it. Anywhere else (`ESC`, CSI, a
/// charset designation) it can't be part of the sequence, which is
/// abandoned along with the codepoint.
pub fn consumeInSequence(self: *Layer, cp: u21) bool {
    switch (self.vt.esc_state) {
        .ground => return false,
        .string => if (cp == 0x9c) {
            self.vt.esc_state = .ground;
        },
        .esc, .csi, .charset_g0, .charset_g1, .esc_intermediate => {
            self.vt.esc_state = .ground;
            self.vt.csi_len = 0;
        },
    }
    return true;
}

/// Advances the escape-sequence machine by one byte while
/// `esc_state != .ground`. For `ESC [ ...` (CSI) it buffers the
/// parameter bytes and, on the final byte, either interprets the
/// sequence (`execCsi`) or drops it; for `ESC ] ...` and friends it
/// just finds the terminator and discards. See `EscState`.
fn stepEscape(self: *Layer, byte: u8) !void {
    switch (self.vt.esc_state) {
        .ground => unreachable,
        .esc => switch (byte) {
            '[' => {
                self.vt.esc_state = .csi;
                self.vt.csi_len = 0;
            },
            ']', 'P', 'X', '^', '_' => self.vt.esc_state = .string,
            '7' => { // DECSC -- save cursor
                saveCursor(self);
                self.vt.esc_state = .ground;
            },
            '8' => { // DECRC -- restore cursor
                restoreCursor(self);
                self.vt.esc_state = .ground;
            },
            'H' => { // HTS -- set a tab stop at the cursor column
                setTabStop(self, pendingCol(self), true) catch {};
                self.vt.esc_state = .ground;
            },
            'M' => { // RI -- reverse index (scroll down at the top margin)
                if (self.cursor.row == self.vt.scroll_top) {
                    self.scrollRangeFill(self.vt.scroll_top, self.vt.scroll_bot, 1, .down, self.eraseBlank());
                } else if (self.cursor.row < self.vt.scroll_top) {
                    // Above the region (a header over a scrolling
                    // pane): just move up, stopping at the top row.
                    self.cursor.row -|= 1;
                } else {
                    self.cursor.row -= 1;
                }
                self.vt.esc_state = .ground;
            },
            'D' => { // IND -- index (line feed, no carriage return)
                self.lineFeed();
                self.vt.esc_state = .ground;
            },
            'E' => { // NEL -- next line (carriage return + line feed)
                self.cursor.col = 0;
                self.lineFeed();
                self.vt.esc_state = .ground;
            },
            '(' => self.vt.esc_state = .charset_g0, // designate G0, next byte
            ')' => self.vt.esc_state = .charset_g1, // designate G1, next byte
            // Any other intermediate (`#`, `%`, `*`, `+`, a space...)
            // opens a longer escape that its final byte ends.
            0x20...0x27, 0x2a...0x2f => self.vt.esc_state = .esc_intermediate,
            // Anything else is a short two-byte escape (or the ST
            // half of `ESC \`) -- it ends here.
            else => self.vt.esc_state = .ground,
        },
        .csi => {
            if (byte >= 0x40 and byte <= 0x7e) {
                // Final byte: act on it, then done.
                try execCsi(self, byte);
                self.vt.esc_state = .ground;
                self.vt.csi_len = 0;
            } else if (byte == 0x7f) {
                // DEL is ignored anywhere in a CSI.
            } else if (self.vt.csi_len < self.vt.csi_buf.len) {
                // Parameter (0x30-0x3f) / intermediate (0x20-0x2f)
                // byte -- accumulate for `execCsi`.
                self.vt.csi_buf[self.vt.csi_len] = byte;
                self.vt.csi_len += 1;
            }
        },
        .string => switch (byte) {
            0x07 => self.vt.esc_state = .ground, // BEL terminator
            0x1b => self.vt.esc_state = .esc, // ESC of an `ESC \` (ST) terminator
            else => {},
        },
        // `0` is the VT100 special graphics/line-drawing set; anything
        // else (`B` for US-ASCII, or any other 94-charset final) is
        // treated as plain ASCII. See `g0_line_drawing`/`g1_line_drawing`.
        .charset_g0 => {
            self.vt.g0_line_drawing = byte == '0';
            self.vt.esc_state = .ground;
        },
        .charset_g1 => {
            self.vt.g1_line_drawing = byte == '0';
            self.vt.esc_state = .ground;
        },
        .esc_intermediate => if (byte >= 0x30 and byte <= 0x7e) {
            self.vt.esc_state = .ground;
        },
    }
}

/// Acts on a completed `ESC [ <params> <final>` sequence --
/// `csi_buf[0..csi_len]` holds the parameter/intermediate bytes.
/// Only the finals glyphwire interprets are handled; every other
/// final returns without effect (the sequence's bytes were already
/// kept off the grid by `stepEscape`). See `EscState` and, for the
/// B1 screen-model finals, decisions.md's VT fallback section.
fn execCsi(self: *Layer, final: u8) !void {
    const params = self.vt.csi_buf[0..self.vt.csi_len];

    // `ESC [ ! p` -- DECSTR soft terminal reset: scroll region back to
    // full, cursor shown, saved cursor and SGR pen cleared. Per spec
    // it does *not* move the cursor, clear the screen, or leave the
    // alt screen -- exactly what glyphwire-shell wants to undo after a
    // pty child that may have died mid-screen.
    if (final == 'p' and params.len == 1 and params[0] == '!') {
        self.vt.scroll_top = 0;
        self.vt.scroll_bot = self.height - 1;
        self.vt.cursor_visible = true;
        self.vt.saved_cursor = null;
        self.vt.pen = .{};
        // DECSTR also puts the modes back. Autowrap goes back *on*
        // here, where the spec says off: the point of the reset in
        // glyphwire is to hand the layer back to the shell, whose
        // output wants wrapping.
        self.vt.autowrap = true;
        self.vt.insert_mode = false;
        self.vt.shift_out = false;
        self.vt.g0_line_drawing = false;
        self.vt.g1_line_drawing = false;
        return;
    }

    // `ESC [ > f u` / `ESC [ < n u` / `ESC [ = f ; m u` -- the kitty
    // keyboard protocol's flag stack. Kept here only to answer the
    // `ESC [ ? u` query; glyphwire-shell's `pty.ModeTracker` acts on
    // the same bytes. Checked first: `ESC [ < u` would otherwise fall
    // through to the ANSI.SYS restore-cursor `u` below.
    if (final == 'u' and params.len > 0 and (params[0] == '>' or params[0] == '<' or params[0] == '=')) {
        _ = self.vt.kitty_keys.apply(params[0], params[1..], self.vt.on_alt);
        return;
    }

    // `ESC [ ? ...` -- DEC private modes and DECRQM.
    if (params.len > 0 and params[0] == '?') {
        execPrivateCsi(self, final, params[1..]);
        return;
    }
    // `ESC [ > ...` / `ESC [ = ...` -- device attributes. Answer a
    // secondary DA (`> c`); skip the rest.
    if (params.len > 0 and (params[0] == '>' or params[0] == '=')) {
        if (final == 'c') queueReply(self, "\x1b[>0;10;1c");
        return;
    }
    // Any other private-parameter lead (`<`, or an intermediate this
    // model doesn't know) is not one of the plain finals below.
    if (params.len > 0 and params[0] >= '<' and params[0] <= '?') return;

    const n1 = @max(csiParam(params, 0, 1), 1); // count / distance, default 1

    switch (final) {
        'm' => self.vt.pen.applySgr(params),
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'f', 'd', '`', 'a', 'e' => csiCursor(self, final, params),
        'J' => csiEraseDisplay(self, csiParam(params, 0, 0)),
        'K' => csiEraseLine(self, csiParam(params, 0, 0)),
        'r' => setScrollRegion(self, params), // DECSTBM
        'S' => self.scrollRangeFill(self.vt.scroll_top, self.vt.scroll_bot, n1, .up, self.eraseBlank()), // SU
        'T' => self.scrollRangeFill(self.vt.scroll_top, self.vt.scroll_bot, n1, .down, self.eraseBlank()), // SD
        'L' => if (rowInRegion(self, self.cursor.row)) { // IL
            self.scrollRangeFill(self.cursor.row, self.vt.scroll_bot, n1, .down, self.eraseBlank());
            self.cursor.col = 0;
        },
        'M' => if (rowInRegion(self, self.cursor.row)) { // DL
            self.scrollRangeFill(self.cursor.row, self.vt.scroll_bot, n1, .up, self.eraseBlank());
            self.cursor.col = 0;
        },
        '@' => { // ICH
            self.cursor.col = pendingCol(self);
            self.insertCellsFill(n1, self.eraseBlank());
        },
        'P' => { // DCH
            self.cursor.col = pendingCol(self);
            self.deleteCellsFill(n1, self.eraseBlank());
        },
        'X' => self.clearFill(self.cursor.row, pendingCol(self), 1, n1, self.eraseBg()), // ECH
        'b' => repeatLastGlyph(self, n1), // REP
        'I' => { // CHT -- forward n tab stops
            var i: usize = 0;
            while (i < n1) : (i += 1) self.cursor.col = nextTabStop(self, self.cursor.col);
        },
        'Z' => { // CBT -- back n tab stops
            var i: usize = 0;
            while (i < n1) : (i += 1) self.cursor.col = prevTabStop(self, pendingCol(self));
        },
        'g' => switch (csiParam(params, 0, 0)) { // TBC
            0 => setTabStop(self, pendingCol(self), false) catch {},
            3 => clearAllTabStops(self) catch {},
            else => {},
        },
        // SM / RM: the one ANSI (non-DEC) mode a full-screen program
        // still uses is IRM (4), insert vs. replace.
        'h', 'l' => {
            var it = std.mem.splitScalar(u8, params, ';');
            while (it.next()) |tok| {
                if (std.mem.eql(u8, tok, "4")) self.vt.insert_mode = final == 'h';
            }
        },
        // ANSI.SYS save / restore cursor. With parameters `CSI s` is
        // DECSLRM (left/right margins), which this model doesn't do.
        's' => if (params.len == 0) saveCursor(self),
        'u' => if (params.len == 0) restoreCursor(self),
        'n' => csiDsr(self, csiParam(params, 0, 0)), // DSR
        'c' => queueReply(self, "\x1b[?1;2c"), // primary DA -- VT100 + AVO
        else => {}, // discarded, same as the old stripper
    }
}

/// DECSC: saves the cursor with the pen and charset state.
fn saveCursor(self: *Layer) void {
    self.vt.saved_cursor = .{
        .cursor = self.cursor,
        .pen = self.vt.pen,
        .shift_out = self.vt.shift_out,
        .g0_line_drawing = self.vt.g0_line_drawing,
        .g1_line_drawing = self.vt.g1_line_drawing,
    };
}

/// DECRC: restores what `saveCursor` saved. With nothing saved, a
/// real terminal homes the cursor and resets the pen; glyphwire has
/// always left both alone there, and a program never relies on it.
fn restoreCursor(self: *Layer) void {
    const s = self.vt.saved_cursor orelse return;
    self.cursor = self.clampCursor(s.cursor);
    self.vt.pen = s.pen;
    self.vt.shift_out = s.shift_out;
    self.vt.g0_line_drawing = s.g0_line_drawing;
    self.vt.g1_line_drawing = s.g1_line_drawing;
}

/// Puts the VT modes a program can leave behind -- autowrap, insert
/// mode, custom tab stops, kitty keyboard flags, the REP character --
/// back to their defaults. Part of the `pty_mode` re-arm, so one
/// program's settings never reach the next.
pub fn resetVtModes(self: *Layer) void {
    self.vt.autowrap = true;
    self.vt.insert_mode = false;
    if (self.vt.tab_stops) |t| self.alloc.free(t);
    self.vt.tab_stops = null;
    self.vt.kitty_keys = .{};
    self.vt.last_glyph_len = 0;
}

/// Remembers a just-printed glyph for REP (`repeatLastGlyph`).
pub fn noteLastGlyph(self: *Layer, bytes: []const u8, w: u2, fg: Color, bg: ?Background, ul: UnderlineStyle) void {
    if (bytes.len > self.vt.last_glyph.len) return;
    @memcpy(self.vt.last_glyph[0..bytes.len], bytes);
    self.vt.last_glyph_len = @intCast(bytes.len);
    self.vt.last_glyph_w = w;
    self.vt.last_glyph_fg = fg;
    self.vt.last_glyph_bg = bg;
    self.vt.last_glyph_ul = ul;
}

/// REP (`CSI n b`): prints the last graphic character `n` more times,
/// wrapping like ordinary output. A no-op before anything is printed.
fn repeatLastGlyph(self: *Layer, n: usize) void {
    if (self.vt.last_glyph_len == 0) return;
    // A REP longer than the screen only repaints the same cells.
    const count = @min(n, self.width * self.height);
    const bytes = self.vt.last_glyph[0..self.vt.last_glyph_len];
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (self.vt.insert_mode) self.insertCellsFill(self.vt.last_glyph_w, .{});
        self.putAtCursor(bytes, self.vt.last_glyph_w, self.vt.last_glyph_fg, self.vt.last_glyph_bg, null, .x1, self.vt.last_glyph_ul);
    }
}

/// Joins a zero-width codepoint (`isZeroWidth`) onto the character
/// printed just before it -- the cell left of the cursor, or the lead
/// of a wide pair. Dropped when there is nothing to its left on the
/// row, or when the cluster would outgrow the cell's inline buffer
/// (a long ZWJ emoji sequence keeps its first few codepoints).
pub fn attachZeroWidth(self: *Layer, bytes: []const u8) void {
    if (self.cursor.col == 0) return;
    const row = self.cursor.row;
    var col = @min(self.cursor.col, self.width) - 1;
    if (self.cell(row, col).wide == .wide_spacer and col > 0) col -= 1;
    const c = self.cell(row, col);
    const len: usize = c.grapheme_len;
    if (len == 0 or len + bytes.len > grapheme_inline_len) return;
    @memcpy(c.grapheme_bytes[len..][0..bytes.len], bytes);
    c.grapheme_len = @intCast(len + bytes.len);
    if (self.vt.last_glyph_len != 0 and self.vt.last_glyph_len + bytes.len <= self.vt.last_glyph.len) {
        @memcpy(self.vt.last_glyph[self.vt.last_glyph_len..][0..bytes.len], bytes);
        self.vt.last_glyph_len += @intCast(bytes.len);
    }
}

fn isTabStop(self: *const Layer, col: usize) bool {
    if (self.vt.tab_stops) |t| return t[col];
    return col % tab_width == 0;
}

/// The next tab stop right of `col`, or the last column if there is
/// none (a tab never wraps).
fn nextTabStop(self: *const Layer, col: usize) usize {
    var c = col + 1;
    while (c < self.width) : (c += 1) {
        if (isTabStop(self, c)) return c;
    }
    return self.width - 1;
}

/// The previous tab stop left of `col`, or column 0.
fn prevTabStop(self: *const Layer, col: usize) usize {
    var c = col;
    while (c > 0) {
        c -= 1;
        if (isTabStop(self, c)) return c;
    }
    return 0;
}

/// The per-column stop table, allocated with the default stops the
/// first time a program edits one.
fn ensureTabStops(self: *Layer) ![]bool {
    if (self.vt.tab_stops) |t| return t;
    const t = try self.alloc.alloc(bool, self.width);
    for (t, 0..) |*s, col| s.* = col % tab_width == 0;
    self.vt.tab_stops = t;
    return t;
}

/// HTS (`on`) / TBC 0 (`!on`) at `col`.
fn setTabStop(self: *Layer, col: usize, on: bool) !void {
    const t = try ensureTabStops(self);
    t[col] = on;
}

/// TBC 3: no tab stops at all -- a tab then runs to the last column.
fn clearAllTabStops(self: *Layer) !void {
    @memset(try ensureTabStops(self), false);
}

/// `ESC [ ? <params> <final>` -- DEC private modes (`h`/`l`) and
/// DECRQM (`$ p`). Only the modes the screen model actually acts on
/// are handled here; the ones the pty input path cares about (`?1`,
/// `?2004`, `?1000`..`?1006`) are left to glyphwire-shell's
/// `pty.ModeTracker`, which sniffs the same byte stream.
fn execPrivateCsi(self: *Layer, final: u8, params: []const u8) void {
    // DECRQM: `CSI ? Ps $ p` -- the `$` intermediate is the last
    // buffered byte before the `p` final.
    if (final == 'p' and params.len > 0 and params[params.len - 1] == '$') {
        replyDecrqm(self, params[0 .. params.len - 1]);
        return;
    }
    // `CSI ? u` -- kitty keyboard protocol query: answer with the
    // flags in effect (masked to what glyphwire supports), which is
    // how a program learns the protocol is there at all.
    if (final == 'u') {
        var b: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "\x1b[?{d}u", .{self.vt.kitty_keys.flags(self.vt.on_alt)}) catch return;
        queueReply(self, s);
        return;
    }
    if (final != 'h' and final != 'l') return;
    const set = final == 'h';
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |tok| {
        const n = std.fmt.parseInt(u32, tok, 10) catch continue;
        switch (n) {
            1 => self.vt.app_cursor_keys = set, // DECCKM (see the field doc)
            7 => self.vt.autowrap = set, // DECAWM
            25 => self.vt.cursor_visible = set, // DECTCEM
            47, 1047, 1049 => if (set) {
                if (!self.vt.on_alt) self.vt.kitty_keys.enterAlt();
                enterAltScreen(self) catch {};
            } else exitAltScreen(self),
            else => {},
        }
    }
}

/// `ESC [ <top> ; <bot> r` -- DECSTBM. 1-based, inclusive; an omitted
/// or degenerate pair (or `ESC [ r`) resets to the full screen. Homes
/// the cursor, matching a real terminal.
fn setScrollRegion(self: *Layer, params: []const u8) void {
    const top = @max(csiParam(params, 0, 1), 1) - 1;
    const bot = @max(csiParam(params, 1, self.height), 1) - 1;
    if (top >= bot or bot >= self.height) {
        self.vt.scroll_top = 0;
        self.vt.scroll_bot = self.height - 1;
    } else {
        self.vt.scroll_top = top;
        self.vt.scroll_bot = bot;
    }
    self.cursor = .{ .row = self.vt.scroll_top, .col = 0 };
}

/// `CSI 5 n` / `CSI 6 n` -- device status / cursor position report.
fn csiDsr(self: *Layer, ps: usize) void {
    switch (ps) {
        5 => queueReply(self, "\x1b[0n"), // "terminal OK"
        6 => { // CPR -- 1-based row;col, never past the last column
            var b: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "\x1b[{d};{d}R", .{
                self.cursor.row + 1, pendingCol(self) + 1,
            }) catch return;
            queueReply(self, s);
        },
        else => {},
    }
}

/// DECRQM answer: `CSI ? Ps ; V $ y`, V = 1 set, 2 reset, 0 not
/// recognized. Only the modes the screen model tracks report a real
/// value.
fn replyDecrqm(self: *Layer, ps_tok: []const u8) void {
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, ps_tok, " ;"), 10) catch return;
    const v: u8 = switch (n) {
        1 => if (self.vt.app_cursor_keys) 1 else 2,
        7 => if (self.vt.autowrap) 1 else 2,
        25 => if (self.vt.cursor_visible) 1 else 2,
        47, 1047, 1049 => if (self.vt.on_alt) 1 else 2,
        else => 0,
    };
    var b: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "\x1b[?{d};{d}$y", .{ n, v }) catch return;
    queueReply(self, s);
}

/// Appends `bytes` to the pending terminal reply (see `reply_buf`).
/// Silently drops anything past the buffer -- replies are a handful of
/// bytes each and never legitimately overflow 96.
fn queueReply(self: *Layer, bytes: []const u8) void {
    const room = self.vt.reply_buf.len - self.vt.reply_len;
    const n = @min(bytes.len, room);
    @memcpy(self.vt.reply_buf[self.vt.reply_len..][0..n], bytes[0..n]);
    self.vt.reply_len += n;
}

/// Reads the `index`-th `;`-separated numeric parameter from a CSI
/// parameter string, returning `default_val` for a missing or empty
/// field (VT convention: an omitted parameter takes its default).
fn csiParam(params: []const u8, index: usize, default_val: usize) usize {
    var it = std.mem.splitScalar(u8, params, ';');
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i == index) {
            if (tok.len == 0) return default_val;
            return std.fmt.parseInt(usize, tok, 10) catch default_val;
        }
    }
    return default_val;
}

/// Cursor-movement CSI finals. **Every one clamps to the screen and
/// never scrolls** (the vertical relative moves stop at the scroll
/// region's margins too -- `cursorUp`/`cursorDown`) -- a real terminal only scrolls on a line feed /
/// `IND` / `RI` / an explicit scroll command, never on a cursor
/// address. (This used to route downward/absolute-row moves through
/// `resolveRow`, which scrolls; harmless for Phase A's colour+
/// progress-bar output, but a full-screen program that positions to
/// its last row -- `less`'s status line -- would scroll the whole
/// primary layer one row per keypress.)
///
/// Any move also ends a pending wrap (`pendingCol`): a relative move
/// starts from the last column, not from one past it.
fn csiCursor(self: *Layer, final: u8, params: []const u8) void {
    const last_row = self.height - 1;
    self.cursor.col = pendingCol(self);
    switch (final) {
        'A' => cursorUp(self, @max(csiParam(params, 0, 1), 1)),
        'B', 'e' => cursorDown(self, @max(csiParam(params, 0, 1), 1)), // CUD / VPR
        'C', 'a' => self.cursor.col = @min(self.cursor.col + @max(csiParam(params, 0, 1), 1), self.width - 1), // CUF / HPR
        'D' => self.cursor.col -|= @max(csiParam(params, 0, 1), 1),
        'E' => { // CNL -- down n lines, to column 0
            cursorDown(self, @max(csiParam(params, 0, 1), 1));
            self.cursor.col = 0;
        },
        'F' => { // CPL -- up n lines, to column 0
            cursorUp(self, @max(csiParam(params, 0, 1), 1));
            self.cursor.col = 0;
        },
        'G', '`' => self.cursor.col = @min(@max(csiParam(params, 0, 1), 1) - 1, self.width - 1), // CHA / HPA
        'd' => self.cursor.row = @min(@max(csiParam(params, 0, 1), 1) - 1, last_row),
        'H', 'f' => {
            self.cursor.row = @min(@max(csiParam(params, 0, 1), 1) - 1, last_row);
            self.cursor.col = @min(@max(csiParam(params, 1, 1), 1) - 1, self.width - 1);
        },
        else => unreachable,
    }
}

/// CUU / CPL: up `n` rows, stopping at the top margin when the cursor
/// starts inside the scroll region (xterm's rule), else at row 0.
fn cursorUp(self: *Layer, n: usize) void {
    const stop = if (self.cursor.row >= self.vt.scroll_top) self.vt.scroll_top else 0;
    self.cursor.row = @max(self.cursor.row -| n, stop);
}

/// CUD / VPR / CNL: down `n` rows, stopping at the bottom margin when
/// the cursor starts inside the scroll region, else at the last row.
fn cursorDown(self: *Layer, n: usize) void {
    const stop = if (self.cursor.row <= self.vt.scroll_bot) self.vt.scroll_bot else self.height - 1;
    self.cursor.row = @min(self.cursor.row +| n, stop);
}

/// `ESC [ <n> K` -- erase in line: 0 = cursor to end of line
/// (default), 1 = start of line to cursor, 2 = whole line. Blanks
/// cells in the cursor's row only; doesn't move the cursor. Erased
/// cells take the pen's background (`eraseBg`, BCE), and a cursor in
/// the pending-wrap position erases from the last column.
fn csiEraseLine(self: *Layer, mode: usize) void {
    const col = pendingCol(self);
    const bg = self.eraseBg();
    switch (mode) {
        0 => self.clearFill(self.cursor.row, col, 1, self.width, bg),
        1 => self.clearFill(self.cursor.row, 0, 1, col + 1, bg),
        2 => self.clearFill(self.cursor.row, 0, 1, self.width, bg),
        else => {},
    }
}

/// `ESC [ <n> J` -- erase in display: 0 = cursor to end of screen
/// (default), 1 = start of screen to cursor, 2 = whole screen, with
/// the same BCE / pending-wrap rules as `csiEraseLine`. Doesn't move
/// the cursor (a program that wants the cursor homed sends `ESC [ H`
/// too, which `csiCursor` handles).
///
/// 3 erases the *scrollback*, not the screen (`clearHistory`) --
/// xterm's extension, and how `clear` and Claude Code drop a stale
/// transcript before redrawing (`2J 3J H`). It used to be read as 2,
/// which left every earlier copy of the redrawn screen in history.
fn csiEraseDisplay(self: *Layer, mode: usize) void {
    const col = pendingCol(self);
    const bg = self.eraseBg();
    switch (mode) {
        0 => {
            self.clearFill(self.cursor.row, col, 1, self.width, bg);
            if (self.cursor.row + 1 < self.height)
                self.clearFill(self.cursor.row + 1, 0, self.height, self.width, bg);
        },
        1 => {
            if (self.cursor.row > 0) self.clearFill(0, 0, self.cursor.row, self.width, bg);
            self.clearFill(self.cursor.row, 0, 1, col + 1, bg);
        },
        2 => self.clearFill(0, 0, self.height, self.width, bg),
        3 => self.clearHistory(),
        else => {},
    }
}

