// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const hit = @import("hit.zig");
const scroll_mod = @import("scroll.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

/// Left-click expand/collapse of a `core.Outline`'s nodes, by their ▸/▾
/// marker.
///
/// The sibling of `table_sort.zig`, and there for the same reason: an
/// outline is first-class server-side state that compiles into ordinary
/// cells, so toggling a node is `Outline.setNodeCollapsed` with **no
/// client running**. That is the whole point of the feature -- `gw-grep`
/// paints its results into the shell's scrollback and exits, and the hits
/// stay expandable afterwards, the same way `glyphwire-ls -l`'s table
/// stays sortable.
///
/// Only the two marker cells take the click (`core.outline_marker_cols`).
/// A press anywhere else on the row is left unconsumed so it still
/// reaches glyphwire-shell as a grid click, where the node's
/// `metadata_id` resolves it: the marker expands the hit, the text opens
/// the file.
pub const OutlineToggle = struct {
    app: *App,

    /// Set when a press was consumed on a marker so the matching release
    /// is swallowed too and never arrives as a stray click -- same reason
    /// `TableSort.swallow_release` exists.
    swallow_release: bool = false,

    /// Returns true when this frame's left button belongs to a marker
    /// toggle -- a press that hit one (node toggled, layer reflowed,
    /// outline repainted) or the release that ends one.
    pub fn handleMarkerClick(self: *OutlineToggle, eng: *Engine) bool {
        if (!eng.inputs.mouse_enabled) return false;

        if (eng.inputs.mouse.released(.left)) {
            if (self.swallow_release) {
                self.swallow_release = false;
                return true;
            }
            return false;
        }
        if (!eng.inputs.mouse.pressed(.left)) return false;

        const server = self.app.server;
        const pos = eng.inputs.mouse.pos();

        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        const ctx = server.ctx;
        const target = hit.layerUnder(ctx, pos.x, pos.y) orelse return false;
        const layer = target.layer;
        // While a full-screen program owns the screen its own content is
        // on the grid, not an outline -- leave the click for mouse
        // reporting. Only root can be taken over that way.
        if (target.is_root and scroll_mod.rootOwned(layer)) return false;

        // Paint order = last drawn wins where two overlap, matching how
        // the renderer composites them.
        var found: ?*glyphwire.Outline = null;
        var found_node: usize = 0;
        for (layer.outline_order.items) |handle| {
            const outline = layer.outlines.getPtr(handle) orelse continue;
            const node = outline.toggleAt(target.row, target.col, layer.view_scroll) orelse continue;
            found = outline;
            found_node = node;
        }
        const outline = found orelse return false;

        outline.setNodeCollapsed(layer, ctx, found_node, null) catch |err| {
            std.log.err("outline marker toggle failed: {t}", .{err});
        };
        self.swallow_release = true;
        return true;
    }
};
