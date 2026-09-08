//! The `Context`-derived half of glyphwire-host's "only draw when
//! something changed" check (see decisions.md's "Redraw on change" and
//! `render.zig`'s static-batch cache, which this sits on top of).
//!
//! `App.needsRedraw` compares a full fingerprint of everything the
//! renderer composites -- this module covers the shared grid model, the
//! part that is pure and worth unit-testing on its own; the host-local
//! rest (framebuffer size, cell size, caret, IME preedit) is folded in by
//! `App.needsRedraw` directly since it needs the engine handle.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// A value fingerprint of the drawable state held in a `Context`. No
/// allocation, compared with `std.meta.eql`. Recomputed each frame under
/// `ctx_mutex`; a difference from the last drawn frame's value means a
/// repaint is due.
pub const ContextSig = struct {
    /// Wrapping sum of the root layer's and every `create_layer` layer's
    /// `render_gen`. `render_gen` is a superset of the wire `revision`
    /// counter -- `Layer.touchRender` bumps it for every change to what
    /// the renderer would draw: cell content, style, selection,
    /// highlights, the layer viewport, the per-layer scroll offset. Summed
    /// (not hashed in order) because the set of layers is handled
    /// separately by `topo` and addition doesn't care about iteration
    /// order.
    gen_sum: u64 = 0,

    /// Rolling hash of the compositing order and per-layer visibility:
    /// each entry of `layer_order` folded in with its `visible` flag, plus
    /// the live layer count. `raise_layer` / `lower_layer` deliberately
    /// don't touch `render_gen` (the host reads `layer_order` live), and a
    /// show/hide toggle only flips a bool -- this line is what catches
    /// both, plus create / destroy.
    topo: u64 = 0,

    /// Root scrollback view offset (`view_scroll`) in the low bits and,
    /// in bit 63, whether a full-screen program currently owns the screen
    /// (which pins the view to the live tail regardless of `view_scroll`).
    /// Bit 62 is the context's `window_scrollbar` flag -- a
    /// `set_window_scrollbar` toggle changes nothing else the renderer
    /// hashes, so it needs its own bit here to force the repaint.
    /// A wheel / scrollbar scroll moves `view_scroll` through
    /// `Layer.scrollView`, which does bump `render_gen` -- this is belt
    /// and braces, and makes the scroll state explicit in the fingerprint.
    root_view: u64 = 0,
};

/// FNV-1a step -- small, order-sensitive, good enough for a
/// change-detection fingerprint (not security).
fn mix(acc: u64, v: u64) u64 {
    return (acc ^ v) *% 0x100000001b3;
}

/// Builds the `ContextSig` for `ctx`. The caller must hold the server's
/// `ctx_mutex` (same lock `render` takes) for the duration.
pub fn contextSig(ctx: *const glyphwire.Context) ContextSig {
    var sig: ContextSig = .{};

    sig.gen_sum = ctx.root.renderGeneration();
    var it = ctx.layers.valueIterator();
    while (it.next()) |layer| {
        sig.gen_sum +%= layer.renderGeneration();
    }

    var topo: u64 = mix(0xcbf29ce484222325, ctx.layers.count());
    for (ctx.layer_order.items) |handle| {
        topo = mix(topo, handle);
        const visible: u64 = if (ctx.layers.getPtr(handle)) |l| @intFromBool(l.visible) else 0;
        topo = mix(topo, visible);
    }
    sig.topo = topo;

    sig.root_view = ctx.root.view_scroll;
    if (rootScreenOwned(&ctx.root)) sig.root_view |= @as(u64, 1) << 63;
    if (ctx.window_scrollbar) sig.root_view |= @as(u64, 1) << 62;

    return sig;
}

/// Whether a foregrounded full-screen program owns the root screen: the
/// alt buffer is active, a DECSTBM scroll region narrower than the screen
/// is set, or DECCKM application-cursor-keys mode is on. Mirrors
/// `scroll.rootOwned` -- duplicated here (a few field reads) to keep this
/// module free of the engine-linked `scroll.zig`.
fn rootScreenOwned(root: *const glyphwire.Layer) bool {
    return root.on_alt or root.regionActive() or root.app_cursor_keys;
}
