const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const config = @import("config.zig");
const geometry = @import("geometry.zig");
const caret_mod = @import("caret.zig");
const input_mod = @import("input.zig");
const selection_mod = @import("selection.zig");
const scroll_mod = @import("scroll.zig");
const window_sizing_mod = @import("window_sizing.zig");
const preedit_mod = @import("preedit.zig");
const render_mod = @import("render.zig");
const panes_mod = @import("panes.zig");
const redraw_mod = @import("redraw.zig");

const CursorConfig = config.CursorConfig;
const CursorShape = config.CursorShape;

/// Everything `App.needsRedraw` compares one drawn frame to the next: the
/// pure `Context` fingerprint (`redraw.zig`) plus the host-local state
/// that also decides what ends up on screen. A plain value type, compared
/// with `std.meta.eql`.
const RedrawSig = struct {
    ctx: redraw_mod.ContextSig,
    /// The session's visibility change-counter
    /// (`Server.visibleContextGen`). A context switch re-points
    /// `server.ctx`, and two contexts could in principle share a
    /// `ContextSig`, so carry the gen explicitly.
    visible_gen: u64,
    /// Framebuffer pixel size -- a window resize moves every vertex.
    fb_w: i32,
    fb_h: i32,
    /// Cell pixel size -- a font zoom (Ctrl +/-) moves every vertex too.
    cell_w: i32,
    cell_h: i32,
    /// Caret screen cell + whether it is painted this phase + its shape.
    /// The caret is an immediate draw on its own blink clock, so a phase
    /// flip has to force a frame even when the grid didn't move.
    caret_shown: bool,
    caret_row: usize,
    caret_col: usize,
    caret_shape: CursorShape,
    /// FNV hash of the IME preedit string (empty when no composition is
    /// active) -- the overlay is drawn straight from engine keyboard
    /// state, which never touches `render_gen`.
    preedit_hash: u64,
    /// While a `--screenshot` capture is still pending every frame must
    /// draw, so the readback in `render` actually happens.
    screenshot_pending: bool,
};

pub const EngOptions: host_eng.EngineOptions = .{
    // `maxSprites`: a full-window character grid draws far more than the
    // 1000-quad default per category (background rects, glyphs, icons). The
    // per-category flushed passes in `render.Renderer.renderLayer` keep the
    // paint order correct regardless, but sizing every batch queue to hold
    // a whole large grid keeps each category to a single draw call. 30k
    // covers a ~240x125 cell grid of solid backgrounds; the renderer's
    // `u32` batch indices make it safe.
    .rendererOpts = .{ .textRendering = true, .maxSprites = 30_000 },
    // A terminal is static most of the time: block in the event loop when
    // idle and only repaint when `App.needsRedraw` says something changed
    // (see `redraw.zig`, `App.idleTimeoutMs`, decisions.md's "Redraw on
    // change"). The server's wake callback (registered in `main.zig`)
    // breaks the wait when a socket client mutates the grid.
    .redrawOnDemand = true,
};
pub const AppRunner = host_eng.AppRunner(App, EngOptions);

/// The engine instance type, aliased so the sub-struct modules
/// (`input.zig`, `render.zig`, ...) can name it without re-deriving the
/// `AppRunner` instantiation.
pub const Engine = AppRunner.Engine;

/// The engine's key / mouse-button enums and window handle. Both enums'
/// field names are wire-visible -- `input.zig` forwards them by
/// `@tagName` -- so read `host_eng/input.zig`'s doc comments before
/// renaming anything in them.
pub const Key = host_eng.input.Key;
pub const MouseButton = host_eng.input.MouseButton;
pub const Window = host_eng.input.Window;

/// Font file/size passed to `App.init` -- what `window_sizing`'s
/// `applyFontSize` needs to repeat the startup `measureFontFileIndexed` at
/// a new size.
pub const FontRuntime = window_sizing_mod.WindowSizing.FontRuntime;

/// glyphwire-host: the SDL3-windowed glyphwire renderer (Milestone 8 --
/// see docs/slice_plan.md). Owns the `Context` and `Server` in-process --
/// it's the graphical front end, not just another client of a separately
/// spawned server -- and reads/writes the grid directly (see
/// `render.Renderer.render`, `Server.reportKey`/`reportMouseButton`/
/// `reportMouseMove`), with no wire round trip for its own state.
/// glyphwire-shell is still a separate process (no engine dependency, so
/// it can't own an in-process `Context` itself) and only ever sees the grid
/// through the socket, exactly like any other client would --
/// `Server.serveForever` runs on a background thread the whole time so that
/// connection keeps working normally.
///
/// The struct is a thin owner: shared handles (`alloc`, `server`,
/// `window`) plus seven concern sub-structs, each of which holds a back
/// `app` pointer set in `init` (stable: `App` is heap-allocated once and
/// never moves). `update` is the per-frame orchestrator; `render` forwards
/// to `renderer`.
pub const App = struct {
    alloc: std.mem.Allocator,
    server: *glyphwire.server.Server,
    /// The platform window, kept so the OS clipboard can be read/written
    /// from the main thread (both backends' clipboard calls are
    /// main-thread-only, so the wire `set_clipboard` path can't touch it
    /// directly -- it goes through `ctx.clipboard` +
    /// `Selection.syncClipboardToOs` instead).
    window: *Window,
    /// Set by `reapChild` once glyphwire-shell's process actually exits
    /// (normally from its `exit` builtin, but this covers a crash or
    /// external kill just as well) -- the one thing that ends the host,
    /// deliberately not `escape` the way a typical engine example/game
    /// would: an accidental Escape shouldn't kill an interactive shell
    /// session out from under whatever's running in it.
    shell_exited: *std.atomic.Value(bool),

    /// Set from `--screenshot <path>`: once `elapsed_ms` passes `delay_ms`,
    /// `render` writes the composited grid region to `path` (see
    /// `render.Renderer.captureContentArea`) and `update` quits the next
    /// frame. `path` null for a normal run. Used by
    /// `scripts/regen-readme-assets.sh` together with the shell's
    /// `GLYPHWIRE_SHELL_SCRIPT` (see shell/main.zig) to produce the README
    /// screenshots without any keystroke injection.
    screenshot: struct {
        path: ?[]const u8 = null,
        delay_ms: f64 = 2500,
        elapsed_ms: f64 = 0,
        done: bool = false,
    } = .{},

    /// Previous frame's `Scroll.screenOwnedByProgram()`, to catch the
    /// moment a full-screen program takes the screen and snap the
    /// scrollback view back to the live tail (see `update`).
    screen_was_owned: bool = false,

    /// The last drawn frame's redraw fingerprint (see `needsRedraw`).
    /// Null until the first frame, which always draws.
    redraw_prev: ?RedrawSig = null,

    caret: caret_mod.Caret,
    keys: input_mod.KeyInput,
    preedit: preedit_mod.Preedit,
    selection: selection_mod.Selection,
    scroll: scroll_mod.Scroll,
    panes: panes_mod.Panes,
    window_sizing: window_sizing_mod.WindowSizing,
    renderer: render_mod.Renderer,

    pub fn init(
        alloc: std.mem.Allocator,
        eng: *Engine,
        server: *glyphwire.server.Server,
        shell_exited: *std.atomic.Value(bool),
        screenshot_path: ?[]const u8,
        screenshot_delay_ms: f64,
        font: FontRuntime,
        cursor: CursorConfig,
    ) !*App {
        const app = try alloc.create(App);
        app.* = .{
            .alloc = alloc,
            .server = server,
            .window = eng.window,
            .shell_exited = shell_exited,
            .screenshot = .{ .path = screenshot_path, .delay_ms = screenshot_delay_ms },
            .caret = .{
                .app = undefined,
                .shape = cursor.shape,
                .blink = cursor.blink,
                .blink_ms = cursor.blink_ms,
            },
            .keys = .{ .app = undefined },
            .preedit = .{ .app = undefined },
            .selection = .{ .app = undefined },
            .scroll = .{ .app = undefined },
            .panes = .{ .app = undefined },
            .window_sizing = .{
                .app = undefined,
                .font_path = font.path,
                .font_face_index = font.face_index,
                .font_size = font.size,
                .initial_font_size = font.size,
            },
            .renderer = .{
                .app = undefined,
                .image_textures = std.AutoHashMap(glyphwire.ImageHandle, *host_eng.ManagedTexture).init(alloc),
                .icon_uv = std.AutoHashMap(glyphwire.ImageHandle, host_eng.RectF).init(alloc),
            },
        };
        // Back-pointers: `app` is at a stable heap address for its whole
        // lifetime, so each concern can reach the shared handles through
        // `self.app.*`.
        app.caret.app = app;
        app.keys.app = app;
        app.preedit.app = app;
        app.selection.app = app;
        app.scroll.app = app;
        app.panes.app = app;
        app.window_sizing.app = app;
        app.renderer.app = app;

        // Pack the bundled icons into one texture now that a GL context
        // exists (the window is already open by the time `App.init` runs).
        // Non-fatal: on failure `icon_atlas` stays null and each icon
        // draws from its own lazily-uploaded texture instead.
        app.renderer.buildIconAtlas(eng) catch |err| {
            std.log.warn("glyphwire-host: icon atlas build failed ({t}); falling back to per-icon textures", .{err});
        };

        return app;
    }

    pub fn deinit(self: *App) void {
        self.panes.deinit();
        self.renderer.deinit();
        self.alloc.destroy(self);
    }

    pub fn update(self: *App, eng: *Engine, deltaTimeMs: f64) bool {
        if (self.shell_exited.load(.monotonic)) return false;
        // A `--screenshot` run quits the frame after `render` has taken
        // the capture, so an automated run terminates on its own.
        if (self.screenshot.done) return false;
        if (self.screenshot.path != null) self.screenshot.elapsed_ms += deltaTimeMs;

        self.window_sizing.syncWindowSize(eng);
        // After syncWindowSize so a font change (which alters cell_w/cell_h
        // and then resizes the window) is only reconciled against the
        // framebuffer on the *next* frame, once both have settled.
        self.window_sizing.handleFontZoom(eng);
        // Ctrl+Shift+C / +V / +Space and, in keyboard selection mode, the
        // arrow/Home/End/Escape/Enter motions. Runs before
        // `reportKeyEvents`, which swallows the same keys so the shell
        // never sees them (see `Selection.swallows`).
        self.selection.handleKeys(eng, deltaTimeMs);
        // Push the session clipboard buffer to the OS clipboard if it
        // changed (a client's `set_clipboard`, or a selection copy just
        // above). Main-thread SDL call.
        self.selection.syncClipboardToOs();
        const key_pressed = self.keys.reportKeyEvents(eng);
        const text_typed = self.keys.reportTextInput(eng);
        // The scrollbar gets first refusal on the left button: a press or
        // drag that belongs to it is consumed here so `reportMouseEvents`
        // doesn't also forward it to the grid as a click. Mouse
        // drag-selection gets second refusal, for the same reason.
        // A divider drag gets first refusal of all: it sits *over* the
        // panes, so a press on the band between two of them is a resize,
        // never a click into either.
        const divider_took_left = self.panes.handleMouse(eng);
        // Then a pane's own scrollbar, which sits inside a pane and so
        // covers the window bar wherever the two overlap.
        const pane_bar_took_left = !divider_took_left and self.scroll.handlePaneScrollbar(eng);
        const chrome_took_left = divider_took_left or pane_bar_took_left;
        const scrollbar_took_left = !chrome_took_left and self.scroll.handleScrollbar(eng);
        const took_left = chrome_took_left or scrollbar_took_left;
        const select_took_left = self.selection.handleMouseSelection(eng, took_left);
        self.keys.reportMouseEvents(eng, took_left or select_took_left);
        self.keys.handleRepeatKeys(eng, deltaTimeMs);
        self.scroll.handleScroll(eng);
        // When a full-screen program takes the screen, drop any scrollback
        // view the user had scrolled to -- its content is about to be
        // hidden behind the program anyway, and leaving `view_scroll` set
        // would show the wrong rows the moment the program exits.
        {
            const owned = self.scroll.screenOwnedByProgram();
            if (owned and !self.screen_was_owned) {
                self.server.reportScroll(self.alloc, 0, null) catch {};
            }
            self.screen_was_owned = owned;
        }
        // After both the key/text forwarding and the scroll handlers: a
        // key used this frame releases a mouse-scroll caret pin and snaps
        // the view back to the live tail (see `Caret.clearPinForKey`).
        self.caret.clearPinForKey(key_pressed or text_typed);
        self.caret.reconcilePin();

        self.caret.tickBlink(deltaTimeMs);
        // Last, so the OS text-input area follows wherever every path
        // above left the caret. Drives the IME candidate window's
        // placement.
        self.preedit.syncInputArea(eng);

        return true;
    }

    pub fn render(self: *App, eng: *Engine) void {
        self.renderer.render(eng);
    }

    /// Whether anything the renderer composites has moved since the last
    /// drawn frame. `AppRunner.gameLoopCore` calls this before `render` +
    /// `swapBuffers` when `EngOptions.redrawOnDemand` is set (it is), so a
    /// terminal sitting idle stops repainting entirely. Cheap: one
    /// `ctx_mutex`-held pass over the layers (`redraw.contextSig`) plus a
    /// few host-local reads. Always true on the first frame and while a
    /// `--screenshot` capture is still pending.
    pub fn needsRedraw(self: *App, eng: *Engine) bool {
        const cur = self.redrawSig(eng);
        defer self.redraw_prev = cur;
        if (self.redraw_prev) |prev| return !std.meta.eql(prev, cur);
        return true;
    }

    fn redrawSig(self: *App, eng: *Engine) RedrawSig {
        const server = self.server;
        const fb = eng.window_state.framebuffer_size;

        var ctx_sig: redraw_mod.ContextSig = .{};
        var caret_shown = false;
        var caret_row: usize = 0;
        var caret_col: usize = 0;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            ctx_sig = redraw_mod.contextSig(server.ctx);
            const root = &server.ctx.root;
            const view: usize = if (scroll_mod.rootOwned(root)) 0 else root.view_scroll;
            if (self.caret.visible()) {
                if (self.caret.screenCell(root, view)) |cell| {
                    caret_shown = true;
                    caret_row = cell.row;
                    caret_col = cell.col;
                }
            }
        }

        return .{
            .ctx = ctx_sig,
            .visible_gen = server.visibleContextGen(),
            .fb_w = fb.x,
            .fb_h = fb.y,
            .cell_w = geometry.cell_w,
            .cell_h = geometry.cell_h,
            .caret_shown = caret_shown,
            .caret_row = caret_row,
            .caret_col = caret_col,
            .caret_shape = self.caret.shape,
            .preedit_hash = std.hash.Fnv1a_64.hash(self.preedit.text(eng)),
            .screenshot_pending = self.screenshot.path != null and !self.screenshot.done,
        };
    }

    /// How long `AppRunner.gameLoopCore` may block in `waitEvents` before
    /// waking to re-check state a background thread may have changed. Null
    /// means block until an OS event or an `Engine.wakeEventLoop` call --
    /// the server's wake callback fires that on any wire activity, so a
    /// socket-driven grid change needs no timeout. A pending screenshot or
    /// a configured caret blink still needs the loop back on its own
    /// clock, so those return a bounded wait in milliseconds.
    pub fn idleTimeoutMs(self: *App) ?f64 {
        if (self.screenshot.path != null and !self.screenshot.done) return 16;
        if (self.caret.blink) {
            const period = @max(self.caret.blink_ms, 1.0);
            const into = @mod(self.caret.blink_elapsed_ms, period);
            return @max(4.0, period - into);
        }
        return null;
    }
};
