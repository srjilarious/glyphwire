// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Which emoji the colour font draws: Unicode's emoji presentation rule,
//! the one terminals and browsers follow.
//!
//! A colour emoji font maps more than emoji. Noto Color Emoji has `0`-`9`,
//! `#`, `*` and `©` (they are the bases of keycap and other sequences),
//! so "the colour font has it" can't be the test, or every digit would
//! turn into a picture. Instead:
//!
//!  - U+FE0F after a codepoint asks for emoji style, U+FE0E for text style.
//!  - Otherwise a codepoint that is emoji *by default* (Emoji_Presentation)
//!    is drawn in colour. Those are exactly the emoji the width table
//!    already makes two cells wide, less the handful of wide CJK symbols
//!    in `text_default_wide` that default to text.
//!  - Anything else stays with the text fonts -- unless none of them has
//!    it, when the colour glyph beats the tofu box (the caller's half).

const std = @import("std");
const glyphwire = @import("glyphwire");

/// VARIATION SELECTOR-16: the preceding character as emoji.
pub const vs16: u21 = 0xFE0F;
/// VARIATION SELECTOR-15: the preceding character as text.
pub const vs15: u21 = 0xFE0E;

/// Wide in the width table, and in emoji fonts, but text by default
/// (Emoji=Yes, Emoji_Presentation=No): 〰 〽 ㊗ ㊙ 🈂 🈷.
const text_default_wide = [_]u21{ 0x3030, 0x303D, 0x3297, 0x3299, 0x1F202, 0x1F237 };

/// Whether `cp`, followed in its grapheme by `next`, asks to be drawn as
/// a colour emoji.
pub fn prefersColor(cp: u21, next: ?u21) bool {
    if (next) |n| {
        if (n == vs16) return true;
        if (n == vs15) return false;
    }
    if (std.mem.indexOfScalar(u21, &text_default_wide, cp) != null) return false;
    return glyphwire.codepointWidth(cp) == 2;
}

/// Whether `cp` is a variation selector, which picks a presentation and
/// draws nothing itself.
pub fn isVariationSelector(cp: u21) bool {
    return cp == vs15 or cp == vs16;
}
