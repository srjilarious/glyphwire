const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
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
/// Scope of this first cut: tables on the **visible context's root
/// layer** only (where `glyphwire-ls -l` puts them), and only while the
/// view is at the live tail -- `Table.headerColumnAt` maps a screen cell
/// against `Table.row`/`painted`, which model the on-screen footprint,
/// so a scrolled-back view would resolve the wrong row.
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
        const cell = geometry.cellFromPixel(pos.x, pos.y);

        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        const layer = &server.ctx.root;
        // A scrolled-back view or a full-screen program owning the screen
        // both make the header's screen row unknowable here -- leave the
        // click for selection / mouse reporting.
        if (layer.view_scroll != 0 or scroll_mod.rootOwned(layer)) return false;

        // Paint order (`table_order`) = last drawn wins where two tables
        // overlap, matching how the renderer composites them.
        var hit_table: ?*glyphwire.Table = null;
        var hit_col: usize = 0;
        for (layer.table_order.items) |handle| {
            const table = layer.tables.getPtr(handle) orelse continue;
            const col = table.headerColumnAt(cell.row, cell.col) orelse continue;
            if (!table.columns[col].sortable) continue;
            hit_table = table;
            hit_col = col;
        }
        const table = hit_table orelse return false;

        table.cycleSortOnColumn(hit_col);
        table.render(layer, server.ctx) catch |err| {
            std.log.err("table header sort repaint failed: {t}", .{err});
        };
        self.swallow_release = true;
        return true;
    }
};
