// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Opening a full-screen program's own context: the handful of calls
//! gwmd, gw-read, salacommander, zoe and gw-hist all start with, in the
//! one order that works.
//!
//!   1. `createContext`, shown at once, with no window scrollbar (each of
//!      these draws its own bars, or has nothing to scroll at the root).
//!   2. `listener.attachContext`, so the listener's subscriptions follow
//!      this context's visibility.
//!   3. The title the context switcher and `jobs` show.
//!   4. The caret: off unless the program takes typed text at it, or
//!      left alone for one that manages it per mode.
//!   5. The theme: the program's own (sent), or the window's.
//!   6. The window's size and cell metrics, for the first layout.
//!   7. The root layer's background, when the program paints one.
//!
//! From step 1 on, every layer call on `client` targets the new context,
//! not the shell's. `Opened.close` destroys it, which brings the shell's
//! back underneath; `open` does that itself if a later step fails.
//!
//! The first thing someone writing a new program copies, so it lives
//! here rather than in five slightly different spellings.

const std = @import("std");
const glyphwire = @import("glyphwire");

const theme = glyphwire.theme;

pub const Options = struct {
    /// What the context switcher, the shell's `jobs` and the window
    /// title call this context until the program changes it.
    title: []const u8,
    /// The host caret. Off for a program that draws its own (a field in
    /// a dialog) or takes no typed text. Null sends nothing and leaves the
    /// host's default (shown), for a program like zoe that sets it per
    /// mode from its first frame on.
    caret: ?bool = false,
    /// The program's own theme (from its config), sent for this context
    /// alone. Null follows the window's.
    theme: ?theme.Theme = null,
    /// Fetch the window's theme into `Opened.th` when `theme` is null.
    /// Wanted by a program that keeps the theme for what the host can't
    /// recolour itself (a popup's nine-patch frame, picked by name).
    keep_theme: bool = false,
    /// The root layer's background: the letterbox colour painted under
    /// every cell no other layer covers. Null leaves the host's.
    root_background: ?glyphwire.Color = null,
};

pub const CellMetrics = struct { w: u32, h: u32 };

pub const Opened = struct {
    /// The context and its token: `grant.context` is the handle, and the
    /// token is what an embedded `gw-shell` panel joins it with
    /// (`shellpanel.Panel.init`).
    grant: glyphwire.ContextGrant,
    /// The window, in cells, when the context opened.
    size: glyphwire.LayerSize,
    /// One cell, in pixels.
    metrics: CellMetrics,
    /// The theme this context draws with: `Options.theme`, or the
    /// window's when `keep_theme` asked for it. Null otherwise.
    th: ?theme.Stored,

    /// Destroys the context. Best effort: on the way out there's
    /// nothing better to do with a failure than carry on.
    pub fn close(self: *const Opened, client: *glyphwire.Client) void {
        client.destroyContext(self.grant.context) catch {};
    }
};

pub fn open(
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,
    opts: Options,
) !Opened {
    const grant = try client.createContext(null, null, 0, false);
    errdefer client.destroyContext(grant.context) catch {};
    try listener.attachContext(grant.context, &grant.token);
    try client.setContextTitle(opts.title);
    if (opts.caret) |c| try client.setCaretVisible(c);

    const th: ?theme.Stored = if (opts.theme) |t| blk: {
        try client.setTheme(&t);
        break :blk .init(t);
    } else if (opts.keep_theme) try client.getTheme() else null;

    const size = try client.getSize();
    const m = try client.getCellMetrics();
    if (opts.root_background) |bg| try client.setLayerBackground(glyphwire.root_layer_handle, bg);

    return .{
        .grant = grant,
        .size = size,
        .metrics = .{ .w = m.w, .h = m.h },
        .th = th,
    };
}

/// `style` with its `frame_style` set to `th`'s panel style: the one
/// field of a popup's style that follows the theme by name rather than
/// by role, so the host can't swap it on a theme change. Every popup
/// style (`finderpopup`, `palette`, zoe's own) has the field.
pub fn panelFramed(style: anytype, th: *const theme.Stored) @TypeOf(style) {
    var s = style;
    s.frame_style = th.panelStyle();
    return s;
}
