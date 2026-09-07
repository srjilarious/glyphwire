//! glyphwire-host's concrete instantiation of the shared frame-timing
//! profiler (`src/profiler.zig`). Defines the phases the host loop times
//! and the volume counters `render.zig` feeds, plus the runtime HUD
//! toggle state.
//!
//! Wiring:
//!  - `host_eng/root.zig`'s `gameLoopCore` calls `profileFrameStart` at
//!    the top of every iteration and hands back the `wait` and `present`
//!    durations it measures around `waitEvents` / `swapBuffers`.
//!  - `host/app.zig` times `update` and `redraw_check`, marks each frame
//!    drawn or skipped, and copies `snapshot()` onto `Session.profile`
//!    under `ctx_mutex` so `get_property "profile"` can read it.
//!  - `host/render.zig` times `sync_batches` and the whole `draw`, and
//!    adds the `layers_rebuilt` / `draw_calls` / `quads` counters, then
//!    paints the HUD when `hud_visible`.
//!  - `host/input.zig` toggles `hud_visible` on Ctrl+Shift+P.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// The timed phases of one main-loop iteration, in display order. `frame`
/// is the whole wall-clock period between iterations (so `wait` plus the
/// work below plus scheduling slop); `draw` already includes
/// `sync_batches`.
pub const Span = enum {
    frame,
    wait,
    update,
    redraw_check,
    sync_batches,
    draw,
    present,
};

/// Per-frame volume counters, summed across the frame and reported as a
/// windowed mean plus an all-time total.
pub const Counter = enum {
    layers_rebuilt,
    draw_calls,
    quads,
};

pub const Profiler = glyphwire.Profiler(Span, Counter);

/// Owns the shared profiler plus the host-only HUD toggle. One lives on
/// `App`; `App.init` builds it from `config.ProfileConfig`.
pub const HostProfiler = struct {
    core: Profiler,
    /// Whether the on-screen overlay is currently painted. Only ever true
    /// when `core.enabled`; `host.conf`'s `profile_hud` seeds it and
    /// Ctrl+Shift+P flips it.
    hud_visible: bool = false,
    /// When set, `App.needsRedraw` always returns true and
    /// `App.idleTimeoutMs` stops blocking, so the host repaints every
    /// frame the way it did before redraw-on-demand -- for measuring
    /// draw cost continuously and A/B-ing it against the idle path. Only
    /// ever true when `core.enabled`; `host.conf`'s `profile_force_redraw`
    /// seeds it and Ctrl+Shift+R flips it.
    force_redraw: bool = false,

    pub fn init(io: std.Io, enabled: bool, hud: bool, force_redraw: bool, window_ms: f64, log_interval_ms: f64) HostProfiler {
        return .{
            .core = Profiler.init(io, enabled, window_ms, log_interval_ms),
            .hud_visible = enabled and hud,
            .force_redraw = enabled and force_redraw,
        };
    }

    /// True when the profiler subsystem is collecting samples.
    pub fn active(self: *const HostProfiler) bool {
        return self.core.enabled;
    }

    /// A monotonic timestamp for bracketing a caller-side span.
    pub fn now(self: *HostProfiler) std.Io.Timestamp {
        return self.core.nowTs();
    }

    /// Records the elapsed time since `start` as `span`.
    pub fn recordSince(self: *HostProfiler, span: Span, start: std.Io.Timestamp) void {
        self.core.record(span, self.core.elapsedNs(start));
    }

    /// Flips the HUD, ignored unless profiling is enabled. Returns the
    /// new visibility.
    pub fn toggleHud(self: *HostProfiler) bool {
        if (!self.core.enabled) return false;
        self.hud_visible = !self.hud_visible;
        return self.hud_visible;
    }

    /// Flips forced every-frame redraw, ignored unless profiling is
    /// enabled. Returns the new state.
    pub fn toggleForceRedraw(self: *HostProfiler) bool {
        if (!self.core.enabled) return false;
        self.force_redraw = !self.force_redraw;
        return self.force_redraw;
    }

    pub fn record(self: *HostProfiler, span: Span, ns: u64) void {
        self.core.record(span, ns);
    }
    pub fn add(self: *HostProfiler, counter: Counter, n: u64) void {
        self.core.add(counter, n);
    }
    pub fn frameBoundary(self: *HostProfiler) void {
        self.core.frameBoundary();
    }
    pub fn markDrawn(self: *HostProfiler) void {
        self.core.markDrawn();
    }
    pub fn markSkipped(self: *HostProfiler) void {
        self.core.markSkipped();
    }
    pub fn snapshot(self: *HostProfiler) glyphwire.ProfileSnapshot {
        return self.core.snapshot();
    }
};
