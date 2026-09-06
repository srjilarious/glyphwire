const std = @import("std");
const glyphwire = @import("glyphwire");
const zargs = @import("zargunaught");

/// gw-view: a minimal client that loads an image file (PNG, JPEG,
/// BMP, or GIF) and draws it as a sprite spanning the cells it needs -- the
/// first real exercise of Image support (`load_image`/`get_image_info`/
/// `draw_image`) end to end, see docs/roadmap.md's Phase 3. The container
/// format is sniffed from the file's magic bytes (`detectImageFormat`),
/// not its extension, and sent as `load_image`'s `format` so the server
/// reads the right header; glyphwire's stb_image decodes all four.
///
/// By default the image is scaled down (aspect preserved) to fit the
/// width of the layer it lands on -- `get_property("size")` gives the
/// layer's cell width, the fixed cell metrics turn that into a pixel
/// width, and `draw_image`'s `scale` carries the ratio; an image already
/// no wider than the layer is left at natural size (never upscaled).
/// `--size full` opts back into natural pixel size (the original
/// behavior). Either way this client still computes `row_span`/`col_span`
/// from the *scaled* dimensions -- aspect-ratio-aware placement is the
/// client's job per decisions.md.
///
/// Arg parsing is zargunaught, the same library and pattern glyphwire-ls
/// uses (`zargs.ArgParser` + `hasOption`/`optionVal`/`positional`), rather
/// than a hand-rolled slice walk -- `parser.deinit()` + `args.deinit()`
/// also plug the small `init.minimal.args.toSlice` leak the old loop left
/// on exit.
///
/// Draws the image and exits as soon as the pixels are on the grid -- no
/// keypress wait. `draw_image` is a request, so by the time it returns
/// the server has the cells and any client rendering them (glyphwire)
/// will paint them on its next frame; nothing further needs this process
/// alive. Launched from gw-shell's prompt (the common case) the
/// image simply stays on screen and the prompt returns immediately;
/// launched directly as glyphwire's exec'd child (`glyphwire
/// gw-view <path>`, replacing gw-shell -- see
/// shell/main.zig's exec path), this process exiting ends the host, so
/// the window closes right after the image is drawn.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var parser = try zargs.ArgParser.init(alloc, .{
        .name = "gw-view",
        .description = "Loads an image (PNG, JPEG, BMP, or GIF) and draws it over a glyphwire connection.",
        .opts = &.{
            .{
                .longName = "size",
                .shortName = "s",
                .description = "Scaling mode: 'fit-width' (the default) shrinks the image to the layer's width, leaving one already narrower at its own size; 'full' draws it at natural pixel size",
                .minNumParams = 1,
                .maxNumParams = 1,
            },
            .{ .longName = "help", .shortName = "h", .description = "Print this help and exit" },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gw-view: error parsing args: {t}\n", .{err}) catch "gw-view: error parsing args\n";
        return fallback(io, msg);
    };
    defer args.deinit();

    if (args.hasOption("help")) {
        var stdout = try zargs.print.Printer.stdout(alloc);
        defer stdout.deinit();
        var help = try zargs.help.HelpFormatter.init(&parser, stdout, zargs.help.DefaultTheme, alloc);
        defer help.deinit();
        help.printHelpText() catch |err| std.debug.print("gw-view: error printing help: {t}\n", .{err});
        try stdout.flush();
        return;
    }

    // Resolve the scaling mode before touching the file or the connection
    // so a bad `--size` value fails fast.
    const SizeMode = enum { fit_width, full };
    const size_mode: SizeMode = blk: {
        const v = args.optionVal("size") orelse break :blk .fit_width;
        if (std.mem.eql(u8, v, "fit-width")) break :blk .fit_width;
        if (std.mem.eql(u8, v, "full")) break :blk .full;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gw-view: unknown --size '{s}' (want 'fit-width' or 'full')\n", .{v}) catch "gw-view: unknown --size value\n";
        return fallback(io, msg);
    };

    if (args.positional.items.len < 1) {
        return fallback(io, "usage: gw-view [--size fit-width|full] <image>   (PNG, JPEG, BMP, or GIF)\n");
    }
    const path = args.positional.items[0];

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gw-view: couldn't read '{s}': {t}\n", .{ path, err }) catch "gw-view: couldn't read the given path\n";
        return fallback(io, msg);
    };
    defer alloc.free(bytes);

    // Sniff the container format from the file's own bytes rather than its
    // name -- `load_image`'s `format` is parsed server-side now, and a
    // wrong hint fails the request.
    const format = glyphwire.detectImageFormat(bytes) orelse {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "gw-view: '{s}' isn't a PNG, JPEG, BMP, or GIF\n", .{path}) catch "gw-view: unsupported image format\n";
        return fallback(io, msg);
    };

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        return fallback(io, "gw-view: no session, falling back to plain output\n");
    };
    defer client.deinit();

    const handle = try client.loadImage(format.name(), bytes);
    const info = try client.getImageInfo(handle);
    const metrics = try client.getCellMetrics();

    // Natural-size placement: the cell span the image needs at scale 1.0,
    // and the scale `draw_image` gets. `--size full` stops here.
    var scale: f32 = 1.0;
    var cols: usize = (info.width + metrics.w - 1) / metrics.w;
    var rows: usize = (info.height + metrics.h - 1) / metrics.h;

    if (size_mode == .fit_width) {
        const layer_size = try client.getSize();
        const target_w: usize = layer_size.cols * metrics.w;
        // Never upscale: an image already within the layer's width keeps
        // its natural size and scale 1.0.
        if (target_w > 0 and info.width > target_w) {
            const img_w_f: f32 = @floatFromInt(info.width);
            scale = @as(f32, @floatFromInt(target_w)) / img_w_f;
            const disp_h: f32 = @as(f32, @floatFromInt(info.height)) * scale;
            const cell_h_f: f32 = @floatFromInt(metrics.h);
            cols = layer_size.cols;
            rows = @intFromFloat(@ceil(disp_h / cell_h_f));
            if (rows == 0) rows = 1;
        }
    }

    // Draw at the cursor rather than a fixed (0, 0) -- like a real inline
    // image viewer (iTerm2's imgcat, kitty's icat), the image should land
    // wherever the caller's cursor already is, then leave the cursor just
    // past its bottom edge so whatever runs next continues below the
    // image instead of overlapping it. Same get-cursor/draw/set-cursor
    // shape glyphwire-ls uses per entry -- see its writeGrid doc comment.
    const cur = try client.getCursor();
    try client.drawImage(handle, null, null, rows, cols, scale);

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
    // counting scrolls it already performed. Same "cap the locally
    // tracked next row at the grid height so `resolveRow` isn't handed a
    // runaway overshoot" shape core_tests.zig's
    // `manyLinesPastBottomCursorCappedAtHeight...Test` covers.
    var snapshot = try client.getCells();
    const grid_rows = snapshot.rows();
    snapshot.deinit();
    try client.setCursor(@min(cur.row + rows, grid_rows), 0);

    // Every request above has already round-tripped, so the image and the
    // follow-up cursor move are committed server-side -- nothing left to
    // wait for. Return (and exit); see the doc comment above.
}

fn fallback(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
}
