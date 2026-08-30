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
/// Background is the bundled `"dialog"` 9-patch style drawn in
/// `BoxMode.stretch` (the `assets/icons/dialog/` set) -- a light-to-dark
/// blue gradient with a white border that reads as one continuous image
/// regardless of the box's size, rather than `BoxMode.tile`'s repeated-
/// per-cell look, which would band a gradient instead of blending it.
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
        return fallback(io, "usage: glyphwire-notify [info|warn|error] <message>\n");
    }

    // The first arg is a type keyword only if there's still a message left
    // over after consuming it -- `glyphwire-notify error` (one bare word)
    // is far more likely to be someone's error *message* than a typeless
    // notification, so it's left as the message instead.
    const notify_type: NotifyType, const message_args = if (args.len >= 3 and NotifyType.fromString(args[1]) != null)
        .{ NotifyType.fromString(args[1]).?, args[2..] }
    else
        .{ .info, args[1..] };

    const message = try std.mem.join(alloc, " ", message_args);
    defer alloc.free(message);

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        return fallback(io, message);
    };
    defer client.deinit();

    run(io, &client, notify_type, message) catch return fallback(io, message);
}

const NotifyType = enum {
    info,
    warn,
    err,

    fn fromString(s: []const u8) ?NotifyType {
        if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
        return null;
    }

    /// Icon-catalog name (the bundled `assets/icons/notify/` set).
    fn iconName(self: NotifyType) []const u8 {
        return switch (self) {
            .info => "notify/info",
            .warn => "notify/warn",
            .err => "notify/error",
        };
    }
};

fn fallback(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

const right_pad = 2;
const icon_col = 1;
const box_rows = 3;
const text_row = 1;

// Native pixel size of the bundled `notify/*` icons (`assets/icons/
// notify/*.png`) -- same 32x32 as every other bundled icon/tile.
const icon_native_px = 32;
// Icon can grow up to 2 cell-heights tall (`.natural`, uniform, never
// upscaled past native size) before shrinking -- the same cap
// `glyphwire-ls`'s entry icons use, so a type icon here reads at the same
// scale as a file icon there rather than a token-sized glyph.
const icon_max_h_cells = 2;

const slide_steps = 20;
const slide_frame_ms: u64 = 15;
const hold_ms: u64 = 2000;

fn run(io: std.Io, client: *glyphwire.Client, notify_type: NotifyType, message: []const u8) !void {
    var snapshot = try client.getCells();
    const grid_cols = snapshot.cols();
    snapshot.deinit();

    const metrics = try client.getCellMetrics();
    const cell_w = metrics.w;
    const cell_h = metrics.h;

    // Same formula `glyphwire-ls` uses: how many columns (from the icon's
    // anchor at `icon_col`) its rendered width reaches, plus one blank
    // padding column, so the text starts clear of it.
    const icon_col_width = (icon_native_px + cell_w - 1) / cell_w + 1;
    const left_margin = icon_col + icon_col_width;
    const text_col = left_margin;
    const max_icon_h: u32 = @intCast(icon_max_h_cells * cell_h);

    const inner_w = @min(message.len, grid_cols -| (left_margin + right_pad));
    const text = message[0..inner_w];
    const box_cols = inner_w + left_margin + right_pad;
    const col = grid_cols -| box_cols;

    const handle = try client.createLayer(box_cols, box_rows, 0);
    errdefer client.destroyLayer(handle) catch {};

    // Starts fully past the grid's right edge (off-screen) and slides to
    // its resting spot flush against the top-right corner.
    const off_x: f32 = @floatFromInt(grid_cols * metrics.w);
    const rest_x: f32 = @floatFromInt(col * metrics.w);
    try client.setLayerPosition(handle, off_x, 0);

    try client.drawBoxOnStyled(handle, 0, 0, box_rows, box_cols, "dialog", .{ .mode = .stretch });
    // `foreground = true` draws into `Cell.fg_icon`, over the dialog fill
    // `drawBoxOnStyled` just set, rather than replacing it the way a plain
    // `draw_icon` would -- see `core.Cell.fg_icon`'s doc comment. `.natural`
    // + `max_h` matches `glyphwire-ls`'s own icon treatment (bigger than a
    // shrunk-to-fit `.fit` icon would be, vertically centered on its row).
    try client.drawIconOnStyled(handle, text_row, icon_col, notify_type.iconName(), .{
        .scale = .natural,
        .h_align = .start,
        .v_align = .center,
        .max_h = max_icon_h,
        .foreground = true,
    });
    try client.setCursorOn(handle, text_row, text_col);
    // `transparent_bg: true` leaves the dialog fill `drawBoxOnStyled`
    // already drew on these cells alone instead of `write_text`'s default
    // of resetting it to opaque black -- see `Client.writeTextTransparent`.
    try client.writeTextOnTransparent(handle, text, .{ .r = 255, .g = 255, .b = 255 });

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
