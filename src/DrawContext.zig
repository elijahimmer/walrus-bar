pub const DrawContext = @This();

output_context: OutputContext,

surface: ?*wl.Surface = null,
layer_surface: ?*zwlr.LayerSurfaceV1 = null,
//// Do I really need to reuse the pool? 1 buffer should be enough.
//shm_pool: ?*wl.ShmPool = null,
shm_buffer: ?*wl.Buffer = null,
shm_fd: ?posix.fd_t = null,
frame_callback: ?*wl.Callback = null,

screen: []Color = undefined,

window_width: u31 = 0,
window_height: u31 = 0,

has_started: bool = false,

pub const OutputContext = struct {
    output: *wl.Output,
    id: u32,

    physical_height: u16 = undefined,
    physical_width: u16 = undefined,

    height: u16 = undefined,
    width: u16 = undefined,

    has_geometry: bool = false,
    has_mode: bool = false,
    has_name: bool = false,
    changed: bool = true, // start off as changed to initialize output

    name: []const u8 = undefined,
};

pub fn deinit(self: *DrawContext, allocator: Allocator) void {
    if (self.output_context.has_name)
        log.debug("Output '{s}' (id #{}) was deinited", .{ self.output_context.name, self.output_context.id })
    else
        log.debug("Output id #{} was deinited", .{self.output_context.id});

    if (self.shm_buffer) |shm_buffer| shm_buffer.destroy();
    if (self.shm_fd) |shm_fd| posix.close(shm_fd);
    if (self.frame_callback) |frame_callback| frame_callback.destroy();

    if (self.layer_surface) |layer_surface| layer_surface.destroy();
    if (self.surface) |surface| surface.destroy();

    if (self.output_context.has_name) allocator.free(self.output_context.name);
    self.output_context.output.release();

    //if (self.shm_pool) |shm_pool| shm_pool.destroy();

    self.* = undefined;
}

const InitializeShmError = posix.MMapError || posix.MemFdCreateError || posix.TruncateError;
fn initializeShm(self: *DrawContext, wayland_context: *WaylandContext) InitializeShmError!void {
    assert(wayland_context.shm != null);
    assert(self.output_context.width >= self.window_width);
    assert(self.output_context.height >= self.window_height);
    assert(self.surface != null);

    const width = self.output_context.width;
    const height = config.height;
    const stride = @as(u31, width) * @sizeOf(Color);

    const size: u31 = stride * @as(u31, height);
    const fd = try posix.memfd_createZ(constants.WAYLAND_NAMESPACE, 0);
    self.shm_fd = fd;
    try posix.ftruncate(fd, size);
    const screen = try posix.mmap(
        null,
        size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    var screen_adjusted: []Color = undefined;
    screen_adjusted.ptr = @ptrCast(screen.ptr);
    screen_adjusted.len = @as(usize, height) * width;

    self.screen = screen_adjusted;

    @memset(screen_adjusted, all_colors.surface);

    const shm_pool = try wayland_context.shm.?.createPool(fd, size);
    defer shm_pool.destroy();

    self.shm_buffer = try shm_pool.createBuffer(0, width, height, stride, Color.FORMAT);
}

pub const OutputChangedError = InitializeShmError || error{OutOfMemory};
pub fn outputChanged(self: *DrawContext, wayland_context: *WaylandContext) OutputChangedError!void {
    assert(self.output_context.width > 0);
    assert(self.output_context.height > 0);
    assert(wayland_context.layer_shell != null);
    assert(wayland_context.compositor != null);
    assert(wayland_context.shm != null);

    std.log.scoped(.Output).debug("width: {}, height: {}", .{ self.output_context.width, self.output_context.height });

    if (!self.has_started) {
        if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");

        const surface = try wayland_context.compositor.?.createSurface();
        self.surface = surface;

        surface.setListener(*WaylandContext, surfaceListener, wayland_context);

        const layer_surface = try wayland_context.layer_shell.?.getLayerSurface(
            surface,
            self.output_context.output,
            constants.WAYLAND_LAYER,
            constants.WAYLAND_NAMESPACE,
        );
        self.layer_surface = layer_surface;

        layer_surface.setSize(config.width orelse 0, config.height);
        layer_surface.setAnchor(constants.WAYLAND_ZWLR_ANCHOR);
        layer_surface.setExclusiveZone(config.height);
        layer_surface.setKeyboardInteractivity(zwlr.LayerSurfaceV1.KeyboardInteractivity.none);

        layer_surface.setListener(*WaylandContext, layerSurfaceListener, wayland_context);

        self.surface.?.commit();
        if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");

        try self.initializeShm(wayland_context);
        self.has_started = true;
    } else {
        @panic("resizing output unimplemented");
    }

    assert(self.layer_surface != null);
    assert(self.shm_buffer != null);
    //assert(self.shm_pool != null);
    assert(self.shm_fd != null);

    self.surface.?.attach(self.shm_buffer.?, 0, 0);
    self.surface.?.commit();
    if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");

    self.frame_callback = self.surface.?.frame() catch @panic("Getting Frame Callback Failed.");
    self.frame_callback.?.setListener(*WaylandContext, nextFrame, wayland_context);
}

pub fn draw(drawing_context: *DrawContext, wayland_context: *WaylandContext) void {
    _ = wayland_context;

    //drawing_context.surface.?.damageBuffer(0, 0, drawing_context.window_width, drawing_context.window_height);

    drawing_context.surface.?.attach(drawing_context.shm_buffer.?, 0, 0);
    drawing_context.surface.?.commit();
}

pub fn nextFrame(callback: *wl.Callback, event: wl.Callback.Event, wayland_context: *WaylandContext) void {
    // make sure no other events can happen.
    switch (event) {
        .done => {},
    }

    const output_checker = struct {
        pub fn checker(draw_context: *DrawContext, target: *wl.Callback) bool {
            return draw_context.frame_callback == target;
        }
    };

    // if not found, return because the output likely isn't alive anymore and this callback is stale.
    const output_idx = wayland_context.findOutput(
        *wl.Callback,
        callback,
        &output_checker.checker,
    ) orelse @panic("Output not found for drawing!");

    const drawing_context = &wayland_context.outputs.slice()[output_idx];

    drawing_context.draw(wayland_context);

    drawing_context.frame_callback = drawing_context.surface.?.frame() catch @panic("Failed Getting Frame Callback.");
    drawing_context.frame_callback.?.setListener(*WaylandContext, nextFrame, wayland_context);
}

pub fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, wayland_context: *WaylandContext) void {
    const output_checker = struct {
        pub fn checker(draw_context: *DrawContext, target: *zwlr.LayerSurfaceV1) bool {
            return draw_context.layer_surface == target;
        }
    };

    const output_idx = wayland_context.findOutput(
        *zwlr.LayerSurfaceV1,
        layer_surface,
        &output_checker.checker,
    ) orelse @panic("LayerSurface not found for event!");

    const drawing_context = &wayland_context.outputs.slice()[output_idx];

    switch (event) {
        .configure => |configure| {
            log.debug("Output: '{s}', Layer Shell was configured. width: {}, height: {}", .{
                drawing_context.output_context.name,
                configure.width,
                configure.height,
            });
            drawing_context.window_width = @intCast(configure.width);
            drawing_context.window_height = @intCast(configure.height);

            layer_surface.ackConfigure(configure.serial);
        },
        .closed => {
            // TODO: Make sure this is cleaned up properly
            log.debug("Output: '{s}', Surface done", .{drawing_context.output_context.name});
            //@panic("layer surface closed unimplemented");
        },
    }
}

pub fn surfaceListener(surface: *wl.Surface, event: wl.Surface.Event, wayland_context: *WaylandContext) void {
    _ = surface;
    _ = wayland_context;

    switch (event) {
        // TODO: Use this for scaling and transform
        .enter, .leave, .preferred_buffer_scale, .preferred_buffer_transform => {}, // says which surface the window is on. I'd hope it's on the same one.
    }
}

pub fn outputListener(output: *wl.Output, event: wl.Output.Event, wayland_context: *WaylandContext) void {
    const output_checker = struct {
        pub fn checker(draw_context: *DrawContext, target: *wl.Output) bool {
            return draw_context.output_context.output == target;
        }
    };

    const output_idx = wayland_context.findOutput(*wl.Output, output, &output_checker.checker) orelse @panic("Output not found!");

    var draw_context = &wayland_context.outputs.slice()[output_idx];
    var output_context = &draw_context.output_context;

    if (output_context.has_name) {
        log.debug("Output '{s}' (id #{}) had event {s}", .{ output_context.name, output_context.id, @tagName(event) });
    } else {
        log.debug("Output id #{} had event {s}", .{ output_context.id, @tagName(event) });
    }

    switch (event) {
        .geometry => |geometry| {
            assert(geometry.physical_width >= 0);
            assert(geometry.physical_height >= 0);

            output_context.changed = output_context.physical_height != geometry.physical_height or output_context.physical_width != geometry.physical_width;

            output_context.physical_height = @intCast(geometry.physical_height);
            output_context.physical_width = @intCast(geometry.physical_width);
            output_context.has_geometry = true;
        },
        .mode => |mode| {
            assert(mode.width >= 0);
            assert(mode.height >= 0);

            output_context.changed = output_context.height != mode.height or output_context.width != mode.width;

            output_context.height = @intCast(mode.height);
            output_context.width = @intCast(mode.width);
            output_context.has_mode = true;
        },
        .name => |name| {
            assert(!output_context.has_name); // only set name once.
            output_context.has_name = true;

            const name_str = mem.span(name.name);
            assert(name_str.len > 0);

            const name_str_owned = wayland_context.allocator.alloc(u8, name_str.len) catch |err| panic("error: {s}", .{@errorName(err)});
            @memcpy(name_str_owned, name_str);

            output_context.name = name_str_owned;
        },
        .scale, .description => {},
        .done => {
            assert(output_context.has_geometry);
            assert(output_context.has_name);
            assert(output_context.has_mode);

            if (output_context.height > 0 and output_context.width > 0) {
                if (output_context.changed) {
                    log.info("Output '{s}' changed, valid height.", .{output_context.name});
                    draw_context.outputChanged(wayland_context) catch |err| panic("error: {s}", .{@errorName(err)});
                }
            } else {
                if (output_context.changed) {
                    log.info("Output '{s}' changed, zero size.", .{output_context.name});
                    // TODO: shouldn't render (zero size)-- make sure it doesn't.
                }
            }
        },
    }
}

const WaylandContext = @import("WaylandContext.zig");

const constants = @import("constants.zig");

const colors = @import("colors.zig");
const Color = colors.Color;
const all_colors = colors.all_colors;
const Config = @import("Config.zig");
const config = &Config.config;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const meta = std.meta;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.DrawContext);
const panic = std.debug.panic;
const assert = std.debug.assert;
