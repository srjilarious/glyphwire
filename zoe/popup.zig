// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's single-layer floats: the hover popup, the completion popup, the
//! `:` line's path menu, the find widget and the tab tooltip. Each is one
//! hidden layer with the host's dialog shadow, drawn either on the
//! theme's panel nine-patch (falling back to flat `popup_bg` when the
//! host has no such style) or always flat. `Popup` is that layer, its
//! patch and its dirty flag; `Popups` is the set of them, so `Ui.run`'s
//! "anything to draw?" and a theme change walk them all without naming
//! each one.
//!
//! The list popups (finder, palette, extension list, theme picker) are
//! not here: they are three layers each, `applib/popupframe.zig`'s
//! `Chrome`. salacommander's dialog and drag card are single layers too,
//! but always flat with nothing to swap on a theme change, so this stays
//! zoe's rather than moving into applib.

const std = @import("std");
const glyphwire = @import("glyphwire");

const role = glyphwire.Color.role;
const Batch = glyphwire.Client.Batch;

pub const Look = enum {
    /// On the theme's panel nine-patch, flat when the host has none.
    panel,
    /// Always flat `popup_bg`: the completion list and the path menu,
    /// whose rows are a list rather than a framed note.
    flat,
};

/// Where a popup goes, in context cells, and how big it is.
pub const Rect = struct {
    row: usize,
    col: usize,
    rows: usize,
    cols: usize,
};

pub const Popup = struct {
    layer: glyphwire.LayerHandle,
    look: Look,
    /// The panel nine-patch over the whole layer, or null when flat.
    patch: ?glyphwire.NinePatchHandle = null,
    /// What the patch is first created at; `place` resizes it to fit.
    init_rows: usize,
    init_cols: usize,
    /// Named in the warning when the theme's panel style is missing.
    what: []const u8,
    /// Repainted on the next frame (`Ui.render`).
    dirty: bool = false,

    pub const Spec = struct {
        what: []const u8,
        look: Look,
        rows: usize,
        cols: usize,
    };

    /// Creates the layer hidden, shadowed and on its panel (or flat). In
    /// creation order: a later popup stacks over an earlier one.
    pub fn init(client: *glyphwire.Client, spec: Spec, panel_style: []const u8) !Popup {
        const layer = try client.createLayer(spec.cols, spec.rows, 0);
        try client.setLayerVisible(layer, false);
        try client.setLayerShadow(layer, glyphwire.Shadow.dialog);
        var p: Popup = .{
            .layer = layer,
            .look = spec.look,
            .init_rows = spec.rows,
            .init_cols = spec.cols,
            .what = spec.what,
        };
        if (spec.look == .panel) p.patch = p.createPatch(client, panel_style);
        if (p.patch == null) try client.setLayerBackground(layer, role(.popup_bg));
        return p;
    }

    fn createPatch(self: *const Popup, client: *glyphwire.Client, panel_style: []const u8) ?glyphwire.NinePatchHandle {
        return client.createNinePatch(self.layer, 0, 0, self.init_rows, self.init_cols, panel_style) catch |err| {
            std.log.warn("zoe: no '{s}' nine-patch for the {s} ({t}); drawing it flat", .{ panel_style, self.what, err });
            return null;
        };
    }

    /// A theme change: a new panel style replaces the patch (or drops to
    /// flat, or comes back from it), and the flat background follows.
    pub fn applyTheme(self: *Popup, client: *glyphwire.Client, panel_style: []const u8, frame_changed: bool) !void {
        if (self.look != .panel) return;
        if (frame_changed) {
            if (self.patch) |np| try client.destroyNinePatch(self.layer, np);
            self.patch = self.createPatch(client, panel_style);
        }
        try client.setLayerBackground(self.layer, if (self.patch == null) role(.popup_bg) else null);
    }

    /// Sizes and moves the layer to `r`, its patch with it. Doesn't show
    /// it: the caller draws the content first.
    pub fn place(self: *const Popup, batch: *Batch, r: Rect) !void {
        try batch.setLayerSize(self.layer, r.cols, r.rows);
        try batch.setLayerCellPosition(self.layer, r.row, r.col);
        if (self.patch) |np| try batch.updateNinePatch(self.layer, np, .{ .rows = r.rows, .cols = r.cols });
    }

    pub fn show(self: *const Popup, batch: *Batch) !void {
        try batch.setLayerVisible(self.layer, true);
    }

    pub fn hide(self: *const Popup, batch: *Batch) !void {
        try batch.setLayerVisible(self.layer, false);
    }
};

/// Every single-layer popup zoe has. A new one is a field here and a
/// `Spec` in `Ui.init`; `anyDirty`, `clearDirty` and `applyTheme` pick
/// it up without being told.
pub const Popups = struct {
    hover: Popup,
    completion: Popup,
    path_menu: Popup,
    find_bar: Popup,
    tab_tip: Popup,

    pub fn anyDirty(self: *const Popups) bool {
        inline for (@typeInfo(Popups).@"struct".field_names) |name| {
            if (@field(self, name).dirty) return true;
        }
        return false;
    }

    pub fn clearDirty(self: *Popups) void {
        inline for (@typeInfo(Popups).@"struct".field_names) |name| @field(self, name).dirty = false;
    }

    pub fn applyTheme(self: *Popups, client: *glyphwire.Client, panel_style: []const u8, frame_changed: bool) !void {
        inline for (@typeInfo(Popups).@"struct".field_names) |name| try @field(self, name).applyTheme(client, panel_style, frame_changed);
    }
};
