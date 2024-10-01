pub const DrawingContext = @This();

is_initalized: bool = false,
surface: *wl.Surface = undefined,
layer_surface: *zwlr.LayerSurfaceV1 = undefined,
mem_pool: *wl.ShmPool = undefined,

pub fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, context: *OutputContext) void {
    switch (event) {
        .configure => |configure| {
            log.debug("Output '{s}' Layer Shell Configured. width: {}, height: {}", .{ context.name.?, configure.width, configure.height });

            layer_surface.ackConfigure(configure.serial);
        },
        .closed => {
            log.debug("Output '{s}' Closed", .{context.name.?});
            context.deinit();
        },
    }
}

pub fn init(output: *wl.Output) !DrawingContext {
    const surface = try wayland_context.compositor.?.createSurface();
    const layer_surface = try wayland_context.layer_shell.?.getLayerSurface(
        surface,
        output,
        .bottom,
        "elijahimmer/walrus-bar",
    );
    layer_surface.setAnchor(.{
        .top = true,
        .bottom = false,
        .right = true,
        .left = true,
    });

    return .{
        .surface = surface,
        .layer_surface = layer_surface,
        .mem_pool = undefined,
    };
}

const OutputContext = @import("OutputContext.zig");
const config = &@import("Config.zig").config;
const freetype_context = &@import("FreetypeContext.zig").global;
const wayland_context = &@import("WaylandContext.zig").global;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

const log = std.log.scoped(.FreetypeContext);
