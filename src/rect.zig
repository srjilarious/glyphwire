// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A first-class overlay primitive: a plain coloured box (filled or
//! outlined) positioned in a layer's own *content pixel space* rather than
//! on the cell grid -- `x`/`y`/`w`/`h` are pixels measured from the
//! layer's row-0/col-0 corner (the same frame `ImageBg.offset_x/offset_y`
//! sample within one cell, generalized to the whole layer), scaled by the
//! session's fixed cell pixel metrics but not otherwise tied to any cell
//! boundary. Exists so a client drawing an overlay (gw-read's mokuro
//! bubble highlight boxes) doesn't have to approximate a box out of
//! character cells -- see decisions.md's Rect section for the rejected
//! alternatives (box-drawing characters, a cell-anchored span like
//! `ImageBg`). A rect is a component of the layer it's drawn on
//! (`Layer.rects`), exactly like a `Table`, and is composited by
//! glyphwire-host as its own quad batch drawn on top of everything else
//! the layer paints (see `host/render.zig`'s `rects` batch).

const std = @import("std");
const core = @import("core.zig");

const Color = core.Color;

pub const RectHandle = u32;

pub const RectError = error{UnknownRect};

/// One overlay rectangle. `line_width` only matters when `filled` is
/// false -- an outline's stroke thickness in pixels, drawn as four
/// non-overlapping strips so a translucent `color` doesn't double up at
/// the corners.
pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    color: Color,
    line_width: u32 = 1,
    filled: bool = false,
};

/// `update_rect`'s partial patch: each `null` field leaves that property
/// of the existing rect unchanged, unlike `Rect`'s own fields (which are
/// always fully specified at `create_rect` time). Distinct from `Rect`
/// rather than `?Rect`-of-everything so a caller moving a rect doesn't
/// have to re-send its color/size just to avoid resetting them.
pub const RectUpdate = struct {
    x: ?u32 = null,
    y: ?u32 = null,
    w: ?u32 = null,
    h: ?u32 = null,
    color: ?Color = null,
    line_width: ?u32 = null,
    filled: ?bool = null,
};
