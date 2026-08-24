const std = @import("std");
const glyphwire = @import("glyphwire");

/// glyphwire-notify: a transient notification box in the top-right corner
/// of the screen, showing the message given on the command line. Drawn on
/// its own layer (`create_layer`/`destroy_layer` -- see docs/decisions.md's
/// Layer section and docs/api.md) rather than directly on the root layer
/// the way glyphwire-demo's panel is, so it can slide in over whatever's
/// already on screen and be torn down cleanly afterward: "killing its
/// layer" (`destroyLayer`) is the entire cleanup, no `clear` needed to
/// erase it first.
///
/// Slides the layer in from off-screen right, holds for `hold_ms`, then
/// slides it back off before destroying the layer and exiting -- a
/// `set_property(layer, "position", ...)` call per animation frame, which
/// is why the position property is pixel-precise rather than cell-snapped
/// (decisions.md).
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);

    if (args.len < 2) {
        return fallback(io, "usage: glyphwire-notify <message>\n");
    }
    const message = try std.mem.join(alloc, " ", args[1..]);
    defer alloc.free(message);

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        return fallback(io, message);
    };
    defer client.deinit();

    run(io, &client, message) catch return fallback(io, message);
}

fn fallback(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

// One border cell plus one blank padding cell on each side of the text,
// so the message doesn't collide with the box's border line -- same
// border-then-padding convention glyphwire-demo's panel already uses
// (`panel_col + 2`).
const h_pad = 2;
const box_rows = 3;
const text_row = 1;

const slide_steps = 20;
const slide_frame_ms: u64 = 15;
const hold_ms: u64 = 2000;

fn run(io: std.Io, client: *glyphwire.Client, message: []const u8) !void {
    var snapshot = try client.getCells();
    const grid_cols = snapshot.cols();
    snapshot.deinit();

    const metrics = try client.getCellMetrics();

    const inner_w = @min(message.len, grid_cols -| (2 * h_pad));
    const text = message[0..inner_w];
    const box_cols = inner_w + 2 * h_pad;
    const col = grid_cols -| box_cols;

    const handle = try client.createLayer(box_cols, box_rows, 0);
    errdefer client.destroyLayer(handle) catch {};

    // Starts fully past the grid's right edge (off-screen) and slides to
    // its resting spot flush against the top-right corner.
    const off_x: f32 = @floatFromInt(grid_cols * metrics.w);
    const rest_x: f32 = @floatFromInt(col * metrics.w);
    try client.setLayerPosition(handle, off_x, 0);

    try client.drawBoxOn(handle, 0, 0, box_rows, box_cols, "box");
    try client.setCursorOn(handle, text_row, h_pad);
    try client.writeTextOn(handle, text, .{ .r = 255, .g = 255, .b = 255 }, null);

    try slide(io, client, handle, off_x, rest_x);
    try std.Io.sleep(io, .fromMilliseconds(hold_ms), .awake);
    try slide(io, client, handle, rest_x, off_x);

    try client.destroyLayer(handle);
}

/// Steps `handle`'s position linearly from `from_x` to `to_x` (y fixed at
/// 0 -- this notification only ever moves horizontally) over
/// `slide_steps` frames, so the move reads as a slide rather than a jump.
fn slide(io: std.Io, client: *glyphwire.Client, handle: glyphwire.LayerHandle, from_x: f32, to_x: f32) !void {
    var i: usize = 0;
    while (i <= slide_steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(slide_steps));
        try client.setLayerPosition(handle, from_x + (to_x - from_x) * t, 0);
        if (i < slide_steps) try std.Io.sleep(io, .fromMilliseconds(slide_frame_ms), .awake);
    }
}
