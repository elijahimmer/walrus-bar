pub const WAYLAND_NAMESPACE: [:0]const u8 = "elijahimmer/walrus-bar";
pub const WAYLAND_LAYER: zwlr.LayerShellV1.Layer = .bottom;
pub const WAYLAND_ZWLR_ANCHOR: zwlr.LayerSurfaceV1.Anchor = .{
    .top = true,
    .bottom = false,
    .left = true,
    .right = true,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try Config.init_global(allocator);

    const display = try wl.Display.connect(null);
    var registry = try display.getRegistry();

    var context = WaylandContext{
        .display = display,
        .registry = registry,
        .allocator = allocator,
    };
    defer context.deinit();

    registry.setListener(*WaylandContext, registryListener, &context);

    // populate initial registry
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (true) {
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }
}

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

    pub fn deinit(self: *OutputContext, allocator: Allocator) void {
        const log_local = std.log.scoped(.Output);
        if (self.has_name) {
            log_local.debug("Output '{s}' (id #{}) was deinited", .{ self.name, self.id });
        } else {
            log_local.debug("Output id #{} was deinited", .{self.id});
        }

        if (self.has_name) allocator.free(self.name);
        self.output.release();

        self.* = undefined;
    }
};

pub const DrawContext = struct {
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

    pub fn deinit(self: *DrawContext, allocator: Allocator) void {
        if (self.shm_buffer) |shm_buffer| shm_buffer.destroy();
        if (self.shm_fd) |shm_fd| posix.close(shm_fd);
        if (self.surface) |surface| surface.destroy();
        if (self.frame_callback) |frame_callback| frame_callback.destroy();

        //if (self.shm_pool) |shm_pool| shm_pool.destroy();
        if (self.layer_surface) |layer_surface| layer_surface.destroy();

        self.output_context.deinit(allocator);

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
        const fd = try posix.memfd_createZ(WAYLAND_NAMESPACE, 0);
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

            self.surface = try wayland_context.compositor.?.createSurface();

            self.surface.?.setListener(*WaylandContext, surfaceListener, wayland_context);

            const layer_surface = try wayland_context.layer_shell.?.getLayerSurface(
                self.surface.?,
                self.output_context.output,
                WAYLAND_LAYER,
                WAYLAND_NAMESPACE,
            );
            self.layer_surface = layer_surface;

            layer_surface.setSize(0, config.height);
            layer_surface.setAnchor(WAYLAND_ZWLR_ANCHOR);
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
};

pub fn nextFrame(callback: *wl.Callback, event: wl.Callback.Event, wayland_context: *WaylandContext) void {
    //const log_local = std.log.scoped(.nextFrame);

    // make sure no other events can happen.
    switch (event) {
        .done => {},
    }

    const output_idx = output_idx: {
        var output_idx: ?u32 = null;
        for (wayland_context.outputs.slice(), 0..) |draw_context, idx| {
            if (draw_context.frame_callback == callback) {
                if (output_idx != null) @panic("Duplicate Layer Surfaces?");
                output_idx = @intCast(idx);
            }
        }

        if (output_idx) |idx| break :output_idx idx;

        // if the surface is not found, then it is a stale frame request.
        return;
    };

    const drawing_context = &wayland_context.outputs.slice()[output_idx];

    // TODO: draw frame here.

    // TODO: Change damage to what is drawn.
    drawing_context.surface.?.damageBuffer(0, 0, drawing_context.window_width, drawing_context.window_height);

    drawing_context.surface.?.attach(drawing_context.shm_buffer.?, 0, 0);
    drawing_context.surface.?.commit();

    drawing_context.frame_callback = drawing_context.surface.?.frame() catch @panic("Getting Frame Callback Failed.");
    drawing_context.frame_callback.?.setListener(*WaylandContext, nextFrame, wayland_context);
}

pub fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, wayland_context: *WaylandContext) void {
    const log_local = std.log.scoped(.LayerSurface);

    const output_idx = output_idx: {
        var output_idx: ?u32 = null;
        for (wayland_context.outputs.slice(), 0..) |draw_context, idx| {
            if (draw_context.layer_surface == layer_surface) {
                if (output_idx != null) @panic("Duplicate Layer Surfaces?");
                output_idx = @intCast(idx);
            }
        }

        if (output_idx) |idx| break :output_idx idx;

        @panic("Layer Surface for event not found.");
    };

    const drawing_context = &wayland_context.outputs.slice()[output_idx];

    switch (event) {
        .configure => |configure| {
            log_local.debug("Output: '{s}', Layer Shell was configured. width: {}, height: {}", .{
                drawing_context.output_context.name,
                configure.width,
                configure.height,
            });
            drawing_context.window_width = @intCast(configure.width);
            drawing_context.window_height = @intCast(configure.height);

            layer_surface.ackConfigure(configure.serial);
        },
        .closed => {
            log_local.debug("Output: '{s}', Surface done", .{drawing_context.output_context.name});
            //@panic("layer surface closed unimplemented");
        },
    }
}

pub fn surfaceListener(surface: *wl.Surface, event: wl.Surface.Event, wayland_context: *WaylandContext) void {
    _ = surface;
    _ = wayland_context;
    //const log_local = std.log.scoped(.LayerSurface);

    //const output_idx = output_idx: {
    //    var output_idx: ?u32 = null;
    //    for (wayland_context.outputs.slice(), 0..) |draw_context, idx| {
    //        if (draw_context.surface == surface) {
    //            if (output_idx != null) @panic("Duplicate Surfaces?");
    //            output_idx = @intCast(idx);
    //        }
    //    }

    //    if (output_idx) |idx| break :output_idx idx;

    //    @panic("Surface for event not found.");
    //};

    //const drawing_context = &wayland_context.outputs.slice()[output_idx];

    switch (event) {
        .enter, .leave, .preferred_buffer_scale, .preferred_buffer_transform => {}, // says which surface the window is on. I'd hope it's on the same one.
        //.preferred_buffer_scale => |scale| {
        //    log_local.debug("Output: '{s}', preferred_buffer_scale: {}", .{ drawing_context.output_context.name, scale.factor });
        //},
        //.preferred_buffer_transform => |transform| {
        //    log_local.debug("Output: '{s}', preferred_buffer_transform: {}", .{ drawing_context.output_context.name, transform.transform });
        //},
    }
}

/// The names are only valid when the ptr assosiated is not null.
pub const WaylandContext = struct {
    pub const MAX_OUTPUT_COUNT: usize = 16;
    display: *wl.Display,
    registry: *wl.Registry,
    allocator: Allocator,

    outputs: BoundedArray(DrawContext, MAX_OUTPUT_COUNT) = .{},

    compositor: ?*wl.Compositor = null,
    compositor_name: u32 = undefined,

    shm: ?*wl.Shm = null,
    shm_name: u32 = undefined,

    layer_shell: ?*zwlr.LayerShellV1 = null,
    layer_shell_name: u32 = undefined,

    pub fn deinit(self: *WaylandContext) void {
        for (self.outputs.slice()) |*output| {
            output.deinit(self.allocator);
        }

        if (self.shm) |shm| shm.destroy();
        if (self.compositor) |compositor| compositor.destroy();
        if (self.layer_shell) |layer_shell| layer_shell.destroy();

        self.* = undefined;
    }

    /// returns the index of the DrawContext the target Output is in.
    /// Panics if there are two DrawContexts for the same output,
    /// or if no context was found for the output.
    pub fn findOutput(self: *WaylandContext, target: *wl.Output) u32 {
        var output_idx: ?u32 = null;
        for (self.outputs.slice(), 0..) |draw_context, idx| {
            if (draw_context.output_context.output == target) {
                if (output_idx != null) @panic("Duplicate outputs?");
                output_idx = @intCast(idx);
            }
        }

        if (output_idx) |idx| return idx;

        @panic("Output for event not found.");
    }
};

fn outputListener(output: *wl.Output, event: wl.Output.Event, wayland_context: *WaylandContext) void {
    const log_local = std.log.scoped(.Output);

    const output_idx = wayland_context.findOutput(output);

    var draw_context = &wayland_context.outputs.slice()[output_idx];
    var output_context = &draw_context.output_context;

    if (output_context.has_name) {
        log_local.debug("Output '{s}' (id #{}) had event {s}", .{ output_context.name, output_context.id, @tagName(event) });
    } else {
        log_local.debug("Output id #{} had event {s}", .{ output_context.id, @tagName(event) });
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
                    log_local.info("Output '{s}' changed, valid height.", .{output_context.name});
                    draw_context.outputChanged(wayland_context) catch |err| panic("error: {s}", .{@errorName(err)});
                }
            } else {
                if (output_context.changed) {
                    log_local.info("Output '{s}' changed, zero size.", .{output_context.name});
                    // TODO: shouldn't render (zero size)-- make sure it doesn't.
                }
            }
        },
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *WaylandContext) void {
    const log_local = std.log.scoped(.Registry);

    const listen_for = .{
        .{ wl.Compositor, "compositor" },
        .{ wl.Shm, "shm" },
        .{ zwlr.LayerShellV1, "layer_shell" },
    };

    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Output.getInterface().name) == .eq) {
                log_local.debug("Output Added with id #{}", .{global.name});

                const output = registry.bind(global.name, wl.Output, wl.Output.generated_version) catch return;
                output.setListener(*WaylandContext, outputListener, context);

                context.outputs.append(.{
                    .output_context = .{
                        .output = output,
                        .id = global.name,
                    },
                }) catch @panic("Too many outputs!");

                return;
            }

            inline for (listen_for) |variable| {
                const resource, const field = variable;

                if (mem.orderZ(u8, global.interface, resource.getInterface().name) == .eq) {
                    log_local.debug("global added: '{s}'", .{global.interface});
                    @field(context, field) = registry.bind(global.name, resource, resource.generated_version) catch return;
                    @field(context, field ++ "_name") = global.name;

                    return;
                }
            }

            log_local.debug("unknown global ignored: '{s}'", .{global.interface});
        },
        .global_remove => |global| {
            for (context.outputs.slice(), 0..) |*draw_context, idx| {
                const output_context = &draw_context.output_context;
                if (output_context.id == global.name) {
                    log_local.debug("Output '{s}' was removed", .{output_context.name});
                    output_context.deinit(context.allocator);

                    _ = context.outputs.swapRemove(idx);

                    return;
                }
            }

            inline for (listen_for) |variable| {
                _, const field = variable;

                if (@field(context, field) != null) {
                    if (global.name == @field(context, field ++ "_name")) {
                        @panic("Resource '" ++ field ++ "' was removed, this is unimplemented.");
                    }
                }
            }
        },
    }
}

fn shmListener(shm: *wl.Shm, event: wl.Shm.Event, has_argb8888: *bool) void {
    _ = shm;
    switch (event) {
        .format => |format| {
            if (format.format == .argb8888) {
                has_argb8888.* = true;
            }
        },
    }
}

test {
    std.testing.refAllDecls(colors);
    std.testing.refAllDecls(@import("Config.zig"));
    std.testing.refAllDecls(@import("wayland"));
}

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

const BoundedArray = std.BoundedArray;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"walrus-bar");
const maxInt = std.math.maxInt;
