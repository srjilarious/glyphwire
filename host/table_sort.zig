// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const hit = @import("hit.zig");
const scroll_mod = @import("scroll.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

/// Left-click sorting of a `core.Table`'s columns by its header row.
///
/// A table paints into ordinary layer cells and is a first-class model
/// object server-side (`core.Table`), so re-sorting is just
/// `Table.cycleSortOnColumn` + `Table.render` with no client running --
/// which is why the host drives this directly here rather than through a
/// `mouse_button` subscriber the way `glyphwire-shell` handles its own
/// grid clicks. A click that lands on a sortable header is consumed so
/// it isn't also forwarded to glyphwire-shell as a grid click.
///
/// Works on any layer of the visible context, not just its root:
/// `glyphwire-ls -l` puts its table on the root layer of a plain shell
/// session, but on salacommander's embedded `gw-shell --embed` panel the
/// same table lands on a `create_layer` layer, and a `gmux` pane is
/// another. The pointer is resolved against the top-most visible layer
/// whose bounds contain it, matching how the renderer composites them,
/// and only that layer's tables are tested -- a layer covers what is
/// under it for clicks the same way it does for pixels.
///
/// Either way `Table.headerColumnAt` maps the cell back through the
/// table's pinned `top_live` and the layer's scrollback offset, so output
/// scrolling the table up, or the user scrolling the view back to reach
/// the header, are both fine.
pub const TableSort = struct {
    app: *App,

    /// Set when a press was consumed on a header so the matching release
    /// is swallowed too and never reaches glyphwire-shell as a stray
    /// click (the same reason `Scroll.handleScrollbar` tracks its drag).
    swallow_release: bool = false,

    /// Returns true when this frame's left button belongs to a header
    /// sort -- a press that hit a sortable header (sort cycled, table
    /// repainted) or the release that ends one. The caller then drops the
    /// left button for the frame so `reportMouseEvents` doesn't also
    /// deliver it to the grid.
    pub fn handleHeaderClick(self: *TableSort, eng: *Engine) bool {
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
        // on the grid, not a table -- leave the click for mouse reporting.
        // Only root can be taken over that way.
        if (target.is_root and scroll_mod.rootOwned(layer)) return false;

        // Paint order (`table_order`) = last drawn wins where two tables
        // overlap, matching how the renderer composites them.
        var hit_table: ?*glyphwire.Table = null;
        var hit_col: usize = 0;
        for (layer.table_order.items) |handle| {
            const table = layer.tables.getPtr(handle) orelse continue;
            const col = table.headerColumnAt(target.row, target.col, layer.view_scroll) orelse continue;
            if (!table.columns[col].sortable) continue;
            hit_table = table;
            hit_col = col;
        }
        const table = hit_table orelse return false;

        table.cycleSortOnColumn(hit_col);
        table.repaint(layer, ctx) catch |err| {
            std.log.err("table header sort repaint failed: {t}", .{err});
        };
        self.swallow_release = true;
        return true;
    }
};
