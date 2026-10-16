// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Dragging out of the window on Wayland: the drag *source* half of
//! drag-and-drop, which SDL3 doesn't have (it only receives drops).
//!
//! SDL owns the connection, so this rides on it rather than opening a
//! second one: the `wl_display` and the window's `wl_surface` come from
//! SDL's window properties, and libwayland-client is `dlopen`ed by the
//! same soname SDL itself loads it by, which hands back SDL's instance
//! rather than a second copy. Everything this file creates lives on its
//! own event queue, so SDL's dispatch never runs our listeners and ours
//! never runs SDL's -- `dispatch` drains it once a frame. SDL's own read
//! of the socket fills both queues.
//!
//! The objects are our own binds of the globals SDL also uses: a
//! `wl_seat` and its `wl_pointer` (only for the button-press serial
//! `start_drag` has to quote, which SDL keeps to itself), a
//! `wl_data_device` for that seat, and `wl_compositor` + `wl_shm` for the
//! drag icon.
//!
//! The protocol requests are marshalled by hand with
//! `wl_proxy_marshal_array_flags`: libwayland's own `wl_seat_get_pointer`
//! style helpers are inline functions in its headers, not symbols, and
//! there are only a dozen requests here.
//!
//! When the drag begins the compositor moves the pointer focus off our
//! surface, and SDL's leave handler releases every held button -- so
//! the host sees an ordinary release and no client is left with a press
//! it never gets the other half of.

const std = @import("std");
const sdl = @import("sdl3");

const platform = @import("platform_sdl.zig");

const Proxy = opaque {};
const EventQueue = opaque {};

/// `struct wl_interface`. Only `name` is read here (`wl_registry.bind`
/// sends it); the rest is libwayland's business.
const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?*const anyopaque,
    event_count: c_int,
    events: ?*const anyopaque,
};

/// `union wl_argument`: one request argument, by its signature letter.
/// A `new_id` argument is passed as a null `o`; libwayland fills it in.
const Arg = extern union {
    i: i32,
    u: u32,
    s: ?[*:0]const u8,
    o: ?*Proxy,
    h: i32,
};

/// `WL_MARSHAL_FLAG_DESTROY`: the request is a destructor, so the proxy
/// is freed along with sending it.
const marshal_destroy: u32 = 1;

/// The libwayland-client entry points used, named as the library exports
/// them so `load` can look each up by its field name.
const Fns = struct {
    wl_display_create_queue: *const fn (display: *Proxy) callconv(.c) ?*EventQueue,
    wl_event_queue_destroy: *const fn (queue: *EventQueue) callconv(.c) void,
    wl_display_roundtrip_queue: *const fn (display: *Proxy, queue: *EventQueue) callconv(.c) c_int,
    wl_display_dispatch_queue_pending: *const fn (display: *Proxy, queue: *EventQueue) callconv(.c) c_int,
    wl_display_flush: *const fn (display: *Proxy) callconv(.c) c_int,
    wl_proxy_create_wrapper: *const fn (proxy: *Proxy) callconv(.c) ?*Proxy,
    wl_proxy_wrapper_destroy: *const fn (wrapper: *Proxy) callconv(.c) void,
    wl_proxy_set_queue: *const fn (proxy: *Proxy, queue: ?*EventQueue) callconv(.c) void,
    wl_proxy_marshal_array_flags: *const fn (proxy: *Proxy, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, args: [*]Arg) callconv(.c) ?*Proxy,
    wl_proxy_add_listener: *const fn (proxy: *Proxy, listener: *const anyopaque, data: ?*anyopaque) callconv(.c) c_int,
    wl_proxy_get_version: *const fn (proxy: *Proxy) callconv(.c) u32,
    wl_proxy_destroy: *const fn (proxy: *Proxy) callconv(.c) void,
};

/// The interface descriptions libwayland-client exports for the core
/// protocol, again named by their symbols.
const Interfaces = struct {
    wl_registry_interface: *const Interface,
    wl_seat_interface: *const Interface,
    wl_pointer_interface: *const Interface,
    wl_data_device_manager_interface: *const Interface,
    wl_data_device_interface: *const Interface,
    wl_data_source_interface: *const Interface,
    wl_compositor_interface: *const Interface,
    wl_surface_interface: *const Interface,
    wl_shm_interface: *const Interface,
    wl_shm_pool_interface: *const Interface,
    wl_buffer_interface: *const Interface,
};

// Request opcodes, from wayland.xml.
const display_get_registry = 1;
const registry_bind = 0;
const seat_get_pointer = 0;
const pointer_release = 1;
const data_device_manager_create_data_source = 0;
const data_device_manager_get_data_device = 1;
const data_device_start_drag = 0;
const data_device_release = 2;
const data_offer_destroy = 2;
const data_source_offer = 0;
const data_source_destroy = 1;
const data_source_set_actions = 2;
const compositor_create_surface = 0;
const surface_destroy = 0;
const surface_attach = 1;
const surface_damage = 2;
const surface_commit = 6;
const surface_set_buffer_scale = 8;
const shm_create_pool = 0;
const shm_pool_create_buffer = 0;
const shm_pool_destroy = 1;
const buffer_destroy = 0;

const seat_capability_pointer: u32 = 1;
const pointer_button_pressed: u32 = 1;
const dnd_action_copy: u32 = 1;
const shm_format_argb8888: u32 = 0;

/// The versions bound. `wl_seat` 3 is the newest whose `wl_pointer`
/// sends nothing past `axis`, so the listener below covers every event;
/// `wl_data_device_manager` 3 is where drag actions and `dnd_finished`
/// arrive, which a drag needs to end cleanly; `wl_compositor` 4 is the
/// newest whose surfaces still take a buffer offset on `attach`.
const seat_version: u32 = 3;
const data_device_manager_version: u32 = 3;
const compositor_version: u32 = 4;
const shm_version: u32 = 1;

/// The mime types a drag offers. `text/uri-list` is what file managers,
/// editors and media players read; the plain-text forms carry the same
/// URIs for a target that only takes text.
const mime_uri_list = "text/uri-list";
const mime_text = [_][*:0]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING" };

/// A drag icon's pixels: premultiplied ARGB8888 (B, G, R, A bytes in
/// memory), `width` x `height` buffer pixels drawn at `scale` buffer
/// pixels per surface unit. `width` and `height` must be multiples of
/// `scale`.
pub const IconImage = struct {
    width: u32,
    height: u32,
    scale: u32 = 1,
    pixels: []const u8,
};

pub const DragOptions = struct {
    uris: []const []const u8,
    icon: ?IconImage = null,
    /// Where the icon's top-left sits relative to the pointer, in surface
    /// units.
    icon_offset_x: i32 = 0,
    icon_offset_y: i32 = 0,
};

pub const DragSource = struct {
    alloc: std.mem.Allocator,
    lib: std.DynLib,
    fns: Fns,
    ifaces: Interfaces,

    display: *Proxy,
    /// The SDL window's surface: the drag's origin, which must be the
    /// surface holding the implicit grab of the press being dragged.
    origin: *Proxy,
    queue: *EventQueue,
    registry: *Proxy,

    seat: ?*Proxy = null,
    pointer: ?*Proxy = null,
    manager: ?*Proxy = null,
    device: ?*Proxy = null,
    compositor: ?*Proxy = null,
    shm: ?*Proxy = null,

    /// Serial of the newest button press on our `wl_pointer`, which is
    /// what `start_drag` must quote. Null until the first press.
    press_serial: ?u32 = null,

    drag: ?Drag = null,

    const Drag = struct {
        source: *Proxy,
        /// What `send` writes for `text/uri-list`: each URI and a CRLF.
        uri_list: []u8,
        /// What `send` writes for the plain-text mime types: the URIs,
        /// one per line.
        text: []u8,
        icon_surface: ?*Proxy = null,
        icon_buffer: ?*Proxy = null,
        icon_fd: ?std.posix.fd_t = null,
    };

    /// The drag source for `window`, or null when the window isn't on
    /// Wayland or the compositor lacks what a drag needs (logged; the
    /// host simply has no drag-out then).
    pub fn create(alloc: std.mem.Allocator, window: *platform.Window) ?*DragSource {
        const driver = sdl.SDL_GetCurrentVideoDriver() orelse return null;
        if (!std.mem.eql(u8, std.mem.span(driver), "wayland")) return null;

        const props = sdl.SDL_GetWindowProperties(window.handle);
        const display: *Proxy = @ptrCast(sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null) orelse return null);
        const origin: *Proxy = @ptrCast(sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) orelse return null);

        const self = createFor(alloc, display, origin) catch |err| {
            std.log.warn("wayland drag source unavailable, Alt+drag out of the window is off: {t}", .{err});
            return null;
        };
        std.log.info("wayland drag source ready: Alt+drag carries files out of the window", .{});
        return self;
    }

    fn createFor(alloc: std.mem.Allocator, display: *Proxy, origin: *Proxy) !*DragSource {
        // Until `self` exists the pieces are freed here; after, its
        // `destroy` frees them all.
        var handed_over = false;
        var lib = try std.DynLib.open("libwayland-client.so.0");
        errdefer if (!handed_over) lib.close();
        const fns = try lookupAll(Fns, &lib);
        const ifaces = try lookupAll(Interfaces, &lib);

        const queue = fns.wl_display_create_queue(display) orelse return error.WaylandQueueFailed;
        errdefer if (!handed_over) fns.wl_event_queue_destroy(queue);

        // The registry has to be created through a wrapper that is on our
        // queue, or its `global` events would go to SDL's.
        const wrapper = fns.wl_proxy_create_wrapper(display) orelse return error.WaylandWrapperFailed;
        fns.wl_proxy_set_queue(wrapper, queue);
        var reg_args = [_]Arg{.{ .o = null }};
        const registry = fns.wl_proxy_marshal_array_flags(wrapper, display_get_registry, ifaces.wl_registry_interface, fns.wl_proxy_get_version(wrapper), 0, &reg_args);
        fns.wl_proxy_wrapper_destroy(wrapper);
        const reg = registry orelse return error.WaylandRegistryFailed;
        errdefer if (!handed_over) fns.wl_proxy_destroy(reg);

        const self = try alloc.create(DragSource);
        self.* = .{
            .alloc = alloc,
            .lib = lib,
            .fns = fns,
            .ifaces = ifaces,
            .display = display,
            .origin = origin,
            .queue = queue,
            .registry = reg,
        };
        handed_over = true;
        errdefer self.destroy();
        _ = fns.wl_proxy_add_listener(reg, &registry_listener, self);

        // First round trip: the globals, bound as they're announced.
        if (fns.wl_display_roundtrip_queue(display, queue) < 0) return error.WaylandRoundtripFailed;
        const seat = self.seat orelse return error.NoSeat;
        const manager = self.manager orelse return error.NoDataDeviceManager;
        if (self.compositor == null) return error.NoCompositor;
        if (self.shm == null) return error.NoShm;

        var dev_args = [_]Arg{ .{ .o = null }, .{ .o = seat } };
        self.device = self.fns.wl_proxy_marshal_array_flags(manager, data_device_manager_get_data_device, ifaces.wl_data_device_interface, fns.wl_proxy_get_version(manager), 0, &dev_args) orelse return error.NoDataDevice;
        _ = fns.wl_proxy_add_listener(self.device.?, &data_device_listener, self);

        // Second: the seat's capabilities, which is when the pointer is
        // asked for.
        if (fns.wl_display_roundtrip_queue(display, queue) < 0) return error.WaylandRoundtripFailed;
        if (self.pointer == null) return error.NoPointer;
        return self;
    }

    fn lookupAll(comptime T: type, lib: *std.DynLib) !T {
        var out: T = undefined;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, FieldType| {
            @field(out, name) = lib.lookup(FieldType, name) orelse {
                std.log.warn("libwayland-client has no {s}", .{name});
                return error.WaylandSymbolMissing;
            };
        }
        return out;
    }

    pub fn destroy(self: *DragSource) void {
        self.endDrag();
        // `wl_pointer.release` arrived with version 3, the most a seat is
        // bound at here; an older one can only be dropped client-side.
        if (self.pointer) |p| {
            if (self.fns.wl_proxy_get_version(p) >= 3) self.request(p, pointer_release, null, &.{}, marshal_destroy) else self.fns.wl_proxy_destroy(p);
        }
        if (self.device) |d| self.request(d, data_device_release, null, &.{}, marshal_destroy);
        // wl_seat 3 has no release request, nor do these globals.
        if (self.seat) |p| self.fns.wl_proxy_destroy(p);
        if (self.manager) |p| self.fns.wl_proxy_destroy(p);
        if (self.compositor) |p| self.fns.wl_proxy_destroy(p);
        if (self.shm) |p| self.fns.wl_proxy_destroy(p);
        self.fns.wl_proxy_destroy(self.registry);
        _ = self.fns.wl_display_flush(self.display);
        self.fns.wl_event_queue_destroy(self.queue);
        self.lib.close();
        self.alloc.destroy(self);
    }

    /// Runs our listeners for whatever SDL's last read of the socket
    /// queued for us. Once a frame, before input is looked at, so a press
    /// SDL just reported already has its serial here.
    pub fn dispatch(self: *DragSource) void {
        _ = self.fns.wl_display_dispatch_queue_pending(self.display, self.queue);
    }

    /// Whether a drag is in flight -- the host keeps its loop ticking
    /// then, because a drop target asking for the data wakes nothing SDL
    /// would report.
    pub fn dragging(self: *const DragSource) bool {
        return self.drag != null;
    }

    /// Begins an OS drag of `opts.uris` from the newest button press. The
    /// press must still be held: the compositor ignores a drag whose grab
    /// has already ended. A drag still in flight is dropped first.
    pub fn start(self: *DragSource, opts: DragOptions) !void {
        const serial = self.press_serial orelse return error.NoPressSerial;
        if (opts.uris.len == 0) return error.EmptyDrag;
        self.endDrag();

        const uri_list = try joinUris(self.alloc, opts.uris, "\r\n");
        errdefer self.alloc.free(uri_list);
        const text = try joinUris(self.alloc, opts.uris, "\n");
        errdefer self.alloc.free(text);

        const manager = self.manager.?;
        var src_args = [_]Arg{.{ .o = null }};
        const source = self.fns.wl_proxy_marshal_array_flags(manager, data_device_manager_create_data_source, self.ifaces.wl_data_source_interface, self.fns.wl_proxy_get_version(manager), 0, &src_args) orelse return error.DataSourceFailed;
        self.drag = .{ .source = source, .uri_list = uri_list, .text = text };
        _ = self.fns.wl_proxy_add_listener(source, &data_source_listener, self);

        self.request(source, data_source_offer, null, &.{.{ .s = mime_uri_list }}, 0);
        for (mime_text) |m| self.request(source, data_source_offer, null, &.{.{ .s = m }}, 0);
        // Copy only: a target that picked "move" would expect us to delete
        // the files afterwards.
        self.request(source, data_source_set_actions, null, &.{.{ .u = dnd_action_copy }}, 0);

        const icon_surface: ?*Proxy = if (opts.icon != null) self.createSurface() else null;
        self.drag.?.icon_surface = icon_surface;
        self.request(self.device.?, data_device_start_drag, null, &.{ .{ .o = source }, .{ .o = self.origin }, .{ .o = icon_surface }, .{ .u = serial } }, 0);

        // The surface took its drag-icon role from `start_drag`; now give
        // it something to show.
        if (opts.icon) |img| {
            if (icon_surface) |surface| self.attachIcon(surface, img, opts.icon_offset_x, opts.icon_offset_y) catch |err| {
                std.log.warn("drag icon failed, dragging without one: {t}", .{err});
            };
        }
        _ = self.fns.wl_display_flush(self.display);
    }

    fn createSurface(self: *DragSource) ?*Proxy {
        const compositor = self.compositor.?;
        var args = [_]Arg{.{ .o = null }};
        return self.fns.wl_proxy_marshal_array_flags(compositor, compositor_create_surface, self.ifaces.wl_surface_interface, self.fns.wl_proxy_get_version(compositor), 0, &args);
    }

    /// Copies `img` into a memfd-backed `wl_shm` buffer and commits it to
    /// the icon surface. The fd stays open, and the buffer alive, until
    /// the drag ends.
    fn attachIcon(self: *DragSource, surface: *Proxy, img: IconImage, dx: i32, dy: i32) !void {
        const size = img.pixels.len;
        if (size != @as(usize, img.width) * img.height * 4) return error.BadIconSize;

        const fd = std.c.memfd_create("glyphwire-drag-icon", std.c.MFD.CLOEXEC);
        if (fd < 0) return error.MemfdFailed;
        // Closed with the drag from here on, whatever fails below.
        self.drag.?.icon_fd = fd;
        try writeAll(fd, img.pixels);

        const shm = self.shm.?;
        var pool_args = [_]Arg{ .{ .o = null }, .{ .h = fd }, .{ .i = @intCast(size) } };
        const pool = self.fns.wl_proxy_marshal_array_flags(shm, shm_create_pool, self.ifaces.wl_shm_pool_interface, self.fns.wl_proxy_get_version(shm), 0, &pool_args) orelse return error.ShmPoolFailed;
        var buf_args = [_]Arg{ .{ .o = null }, .{ .i = 0 }, .{ .i = @intCast(img.width) }, .{ .i = @intCast(img.height) }, .{ .i = @intCast(img.width * 4) }, .{ .u = shm_format_argb8888 } };
        const buffer = self.fns.wl_proxy_marshal_array_flags(pool, shm_pool_create_buffer, self.ifaces.wl_buffer_interface, self.fns.wl_proxy_get_version(pool), 0, &buf_args);
        // The buffer keeps the pool's memory; the pool itself can go.
        self.request(pool, shm_pool_destroy, null, &.{}, marshal_destroy);
        self.drag.?.icon_buffer = buffer orelse return error.ShmBufferFailed;

        if (img.scale > 1 and self.fns.wl_proxy_get_version(surface) >= 3) {
            self.request(surface, surface_set_buffer_scale, null, &.{.{ .i = @intCast(img.scale) }}, 0);
        }
        self.request(surface, surface_attach, null, &.{ .{ .o = buffer }, .{ .i = dx }, .{ .i = dy } }, 0);
        const scale = @max(img.scale, 1);
        self.request(surface, surface_damage, null, &.{ .{ .i = 0 }, .{ .i = 0 }, .{ .i = @intCast(img.width / scale) }, .{ .i = @intCast(img.height / scale) } }, 0);
        self.request(surface, surface_commit, null, &.{}, 0);
    }

    /// Tears down whatever the current drag holds. Safe with none.
    fn endDrag(self: *DragSource) void {
        const d = self.drag orelse return;
        self.drag = null;
        self.request(d.source, data_source_destroy, null, &.{}, marshal_destroy);
        if (d.icon_surface) |s| self.request(s, surface_destroy, null, &.{}, marshal_destroy);
        if (d.icon_buffer) |b| self.request(b, buffer_destroy, null, &.{}, marshal_destroy);
        if (d.icon_fd) |fd| _ = std.c.close(fd);
        self.alloc.free(d.uri_list);
        self.alloc.free(d.text);
        _ = self.fns.wl_display_flush(self.display);
    }

    /// Sends a request that creates nothing. `args` is copied because
    /// libwayland takes a mutable array.
    fn request(self: *DragSource, proxy: *Proxy, opcode: u32, interface: ?*const Interface, args: []const Arg, flags: u32) void {
        var buf: [8]Arg = undefined;
        @memcpy(buf[0..args.len], args);
        _ = self.fns.wl_proxy_marshal_array_flags(proxy, opcode, interface, self.fns.wl_proxy_get_version(proxy), flags, &buf);
    }

    fn bind(self: *DragSource, name: u32, iface: *const Interface, advertised: u32, wanted: u32) ?*Proxy {
        const version = @min(advertised, wanted);
        var args = [_]Arg{ .{ .u = name }, .{ .s = iface.name }, .{ .u = version }, .{ .o = null } };
        return self.fns.wl_proxy_marshal_array_flags(self.registry, registry_bind, iface, version, 0, &args);
    }

    // ── Listeners ───────────────────────────────────────────────────────

    fn fromData(data: ?*anyopaque) *DragSource {
        return @ptrCast(@alignCast(data.?));
    }

    const RegistryListener = extern struct {
        global: *const fn (?*anyopaque, *Proxy, u32, [*:0]const u8, u32) callconv(.c) void,
        global_remove: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
    };
    const registry_listener: RegistryListener = .{ .global = onGlobal, .global_remove = onGlobalRemove };

    fn onGlobal(data: ?*anyopaque, _: *Proxy, name: u32, interface: [*:0]const u8, version: u32) callconv(.c) void {
        const self = fromData(data);
        const iface = std.mem.span(interface);
        if (self.seat == null and std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = self.bind(name, self.ifaces.wl_seat_interface, version, seat_version);
            if (self.seat) |s| _ = self.fns.wl_proxy_add_listener(s, &seat_listener, self);
        } else if (self.manager == null and std.mem.eql(u8, iface, "wl_data_device_manager")) {
            // Drag actions and `dnd_finished` arrived in version 3; below
            // that a drag can't be ended cleanly, so go without.
            if (version >= data_device_manager_version) {
                self.manager = self.bind(name, self.ifaces.wl_data_device_manager_interface, version, data_device_manager_version);
            }
        } else if (self.compositor == null and std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = self.bind(name, self.ifaces.wl_compositor_interface, version, compositor_version);
        } else if (self.shm == null and std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = self.bind(name, self.ifaces.wl_shm_interface, version, shm_version);
        }
    }

    fn onGlobalRemove(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}

    const SeatListener = extern struct {
        capabilities: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
        name: *const fn (?*anyopaque, *Proxy, [*:0]const u8) callconv(.c) void,
    };
    const seat_listener: SeatListener = .{ .capabilities = onSeatCapabilities, .name = onSeatName };

    fn onSeatCapabilities(data: ?*anyopaque, seat: *Proxy, caps: u32) callconv(.c) void {
        const self = fromData(data);
        // Asking a seat that has never had a pointer for one is a protocol
        // error, so wait for it to say it has.
        if (self.pointer != null or caps & seat_capability_pointer == 0) return;
        var args = [_]Arg{.{ .o = null }};
        self.pointer = self.fns.wl_proxy_marshal_array_flags(seat, seat_get_pointer, self.ifaces.wl_pointer_interface, self.fns.wl_proxy_get_version(seat), 0, &args);
        if (self.pointer) |p| _ = self.fns.wl_proxy_add_listener(p, &pointer_listener, self);
    }

    fn onSeatName(_: ?*anyopaque, _: *Proxy, _: [*:0]const u8) callconv(.c) void {}

    /// Every `wl_pointer` event up to version 3. Only `button` matters.
    const PointerListener = extern struct {
        enter: *const fn (?*anyopaque, *Proxy, u32, ?*Proxy, i32, i32) callconv(.c) void,
        leave: *const fn (?*anyopaque, *Proxy, u32, ?*Proxy) callconv(.c) void,
        motion: *const fn (?*anyopaque, *Proxy, u32, i32, i32) callconv(.c) void,
        button: *const fn (?*anyopaque, *Proxy, u32, u32, u32, u32) callconv(.c) void,
        axis: *const fn (?*anyopaque, *Proxy, u32, u32, i32) callconv(.c) void,
    };
    const pointer_listener: PointerListener = .{
        .enter = onPointerEnter,
        .leave = onPointerLeave,
        .motion = onPointerMotion,
        .button = onPointerButton,
        .axis = onPointerAxis,
    };

    fn onPointerEnter(_: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy, _: i32, _: i32) callconv(.c) void {}
    fn onPointerLeave(_: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy) callconv(.c) void {}
    fn onPointerMotion(_: ?*anyopaque, _: *Proxy, _: u32, _: i32, _: i32) callconv(.c) void {}
    fn onPointerAxis(_: ?*anyopaque, _: *Proxy, _: u32, _: u32, _: i32) callconv(.c) void {}

    fn onPointerButton(data: ?*anyopaque, _: *Proxy, serial: u32, _: u32, _: u32, state: u32) callconv(.c) void {
        if (state == pointer_button_pressed) fromData(data).press_serial = serial;
    }

    /// Our data device sees every drag that crosses the window and every
    /// clipboard change, same as SDL's. None of it is ours to act on, so
    /// each offer is destroyed the moment it's introduced.
    const DataDeviceListener = extern struct {
        data_offer: *const fn (?*anyopaque, *Proxy, *Proxy) callconv(.c) void,
        enter: *const fn (?*anyopaque, *Proxy, u32, ?*Proxy, i32, i32, ?*Proxy) callconv(.c) void,
        leave: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
        motion: *const fn (?*anyopaque, *Proxy, u32, i32, i32) callconv(.c) void,
        drop: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
        selection: *const fn (?*anyopaque, *Proxy, ?*Proxy) callconv(.c) void,
    };
    const data_device_listener: DataDeviceListener = .{
        .data_offer = onDataOffer,
        .enter = onDeviceEnter,
        .leave = onDeviceLeave,
        .motion = onDeviceMotion,
        .drop = onDeviceDrop,
        .selection = onDeviceSelection,
    };

    fn onDataOffer(data: ?*anyopaque, _: *Proxy, offer: *Proxy) callconv(.c) void {
        fromData(data).request(offer, data_offer_destroy, null, &.{}, marshal_destroy);
    }
    fn onDeviceEnter(_: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy, _: i32, _: i32, _: ?*Proxy) callconv(.c) void {}
    fn onDeviceLeave(_: ?*anyopaque, _: *Proxy) callconv(.c) void {}
    fn onDeviceMotion(_: ?*anyopaque, _: *Proxy, _: u32, _: i32, _: i32) callconv(.c) void {}
    fn onDeviceDrop(_: ?*anyopaque, _: *Proxy) callconv(.c) void {}
    fn onDeviceSelection(_: ?*anyopaque, _: *Proxy, _: ?*Proxy) callconv(.c) void {}

    const DataSourceListener = extern struct {
        target: *const fn (?*anyopaque, *Proxy, ?[*:0]const u8) callconv(.c) void,
        send: *const fn (?*anyopaque, *Proxy, [*:0]const u8, i32) callconv(.c) void,
        cancelled: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
        dnd_drop_performed: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
        dnd_finished: *const fn (?*anyopaque, *Proxy) callconv(.c) void,
        action: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
    };
    const data_source_listener: DataSourceListener = .{
        .target = onSourceTarget,
        .send = onSourceSend,
        .cancelled = onSourceDone,
        .dnd_drop_performed = onSourceDropPerformed,
        .dnd_finished = onSourceDone,
        .action = onSourceAction,
    };

    fn onSourceTarget(_: ?*anyopaque, _: *Proxy, _: ?[*:0]const u8) callconv(.c) void {}
    fn onSourceDropPerformed(_: ?*anyopaque, _: *Proxy) callconv(.c) void {}
    fn onSourceAction(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}

    /// The drop target reading the data: write the form it asked for and
    /// close the pipe, which is how it knows the data is complete.
    fn onSourceSend(data: ?*anyopaque, source: *Proxy, mime: [*:0]const u8, fd: i32) callconv(.c) void {
        const self = fromData(data);
        defer _ = std.c.close(fd);
        const d = self.drag orelse return;
        if (d.source != source) return;
        const bytes = if (std.mem.eql(u8, std.mem.span(mime), mime_uri_list)) d.uri_list else d.text;
        writeAll(fd, bytes) catch |err| std.log.warn("drag data write failed: {t}", .{err});
    }

    /// `cancelled` and `dnd_finished` both end the drag: refused or
    /// dropped nowhere, or dropped and read.
    fn onSourceDone(data: ?*anyopaque, source: *Proxy) callconv(.c) void {
        const self = fromData(data);
        const d = self.drag orelse return;
        if (d.source == source) self.endDrag();
    }
};

fn joinUris(alloc: std.mem.Allocator, uris: []const []const u8, sep: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (uris) |u| {
        try out.appendSlice(alloc, u);
        try out.appendSlice(alloc, sep);
    }
    return out.toOwnedSlice(alloc);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
}
