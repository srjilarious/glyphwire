const std = @import("std");
const glyphwire = @import("glyphwire");

/// glyphwire-view: a minimal client that loads a PNG file and draws it as a
/// sprite spanning the cells it needs -- the first real exercise of Image
/// support (`load_image`/`get_image_info`/`draw_image`) end to end, see
/// docs/roadmap.md's Phase 3. Computes `row_span`/`col_span` from the
/// image's natural pixel size (`get_image_info`) and the session's fixed
/// cell metrics (`get_cell_metrics`) -- aspect-ratio-aware placement is the
/// client's job per decisions.md; `draw_image` itself only clips, never
/// stretches.
///
/// Waits for a keypress before exiting, like a real image viewer. When
/// launched directly as glyphwire-host's exec'd child (`glyphwire-host
/// glyphwire-view <path>`, replacing glyphwire-shell -- see
/// shell/main.zig's exec path), this process exiting is what ends the
/// whole host (host/main.zig's `reapChild`/`shell_exited` treats any
/// exec'd child's exit as "done"). Without this wait, the image would
/// draw and the window would close again in the same fraction of a
/// second -- indistinguishable from a crash even though nothing failed.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);

    if (args.len < 2) {
        return fallback(io, "usage: glyphwire-view <image.png>\n");
    }
    const path = args[1];

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "glyphwire-view: couldn't read '{s}': {t}\n", .{ path, err }) catch "glyphwire-view: couldn't read the given path\n";
        return fallback(io, msg);
    };
    defer alloc.free(bytes);

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        return fallback(io, "glyphwire-view: no session, falling back to plain output\n");
    };
    defer client.deinit();

    const handle = try client.loadImage("png", bytes);
    const info = try client.getImageInfo(handle);
    const metrics = try client.getCellMetrics();

    const cols = (info.width + metrics.w - 1) / metrics.w;
    const rows = (info.height + metrics.h - 1) / metrics.h;

    // Draw at the cursor rather than a fixed (0, 0) -- like a real inline
    // image viewer (iTerm2's imgcat, kitty's icat), the image should land
    // wherever the caller's cursor already is, then leave the cursor just
    // past its bottom edge so whatever runs next continues below the
    // image instead of overlapping it. Same get-cursor/draw/set-cursor
    // shape glyphwire-ls uses per entry -- see its writeGrid doc comment.
    const cur = try client.getCursor();
    try client.drawImage(handle, null, null, rows, cols);

    // `cur.row + rows` is the target row *before* `drawImage` ran, but an
    // image tall enough to reach the layer's bottom edge already scrolled
    // the viewport once per row past that edge (see `Layer.drawImage`'s
    // doc comment) -- every one of those rows shifted `cur.row`'s own
    // meaning up by one along with everything else. Passing the
    // un-adjusted sum straight to `set_property(cursor)` re-derives its
    // own overshoot from scratch against the *current* (already-scrolled)
    // viewport, scrolling past the image's real bottom edge by however
    // many rows it just scrolled to fit -- readable as "a lot of extra
    // blank space before the prompt" for a big enough image. Clamping to
    // `grid_rows` caps the target at exactly one past the layer's last
    // row -- the same row the image's own bottom edge actually resolved
    // to once `drawImage` finished scrolling -- so this always requests
    // at most the one further scroll needed to open a fresh line below
    // it, matching `Layer.resolveRow`'s contract instead of double
    // counting scrolls it already performed. Same fix shape
    // `writeCapturedText` (shell/main.zig) already applies to plain
    // captured command output.
    var snapshot = try client.getCells();
    const grid_rows = snapshot.rows();
    snapshot.deinit();
    try client.setCursor(@min(cur.row + rows, grid_rows), 0);

    // See the doc comment above: stay open until the user dismisses it
    // (any keypress) rather than returning immediately. Falls back to
    // returning right away if the subscription itself fails -- a viewer
    // that can't listen for a dismissal key isn't worth blocking forever
    // over.
    const listener = glyphwire.InputListener.connectFromEnv(io, alloc, init.environ_map, &.{"key"}) catch return;
    defer listener.deinit();
    while (true) {
        const ev = (try listener.waitKeyEvent(.{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } })) orelse continue;
        defer alloc.free(ev.key);
        if (ev.pressed) return;
    }
}

fn fallback(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
}
