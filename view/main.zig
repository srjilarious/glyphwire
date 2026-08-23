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

    try client.drawImage(handle, 0, 0, rows, cols);
}

fn fallback(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
}
