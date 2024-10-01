pub const OutputContext = @This();
pub const State = enum {
    configuring,
    done,
    acked,
};

output: *wl.Output,
serial: u32,

is_alive: bool = true,
state: State = .configuring,

name: ?[]u8 = null,

has_mode: bool = false,
width: u16 = undefined,
height: u16 = undefined,

has_geometry: bool = false,
physical_width: u16 = undefined,
physical_height: u16 = undefined,

pub fn deinit(self: *OutputContext) void {
    if (self.name != null) wayland_context.allocator.free(self.name.?);
    self.output.release();
    self.* = undefined;
}

pub fn outputListener(output: *wl.Output, event: wl.Output.Event, ctx: *OutputContext) void {
    assert(ctx.is_alive);
    assert(output == ctx.output);

    switch (event) {
        .geometry => |geometry| {
            ctx.physical_width = @intCast(geometry.physical_width);
            ctx.physical_height = @intCast(geometry.physical_height);
            log.debug("{} :: geometry x: {}, y: {}, physical_width: {}, physical_height: {}, subpixel: {s}", .{
                ctx.serial,
                geometry.x,
                geometry.y,
                geometry.physical_width,
                geometry.physical_height,
                @tagName(geometry.subpixel),
            });

            ctx.state = .configuring;
            ctx.has_geometry = true;
        },
        .mode => |mode| {
            ctx.width = @intCast(mode.width);
            ctx.height = @intCast(mode.height);
            log.debug("{} :: mode width: {}, height: {}, refresh: {}", .{
                ctx.serial,
                mode.width,
                mode.height,
                mode.refresh,
            });

            ctx.state = .configuring;
            ctx.has_mode = true;
        },
        .name => |name| {
            log.debug("{} :: name: '{s}'", .{ ctx.serial, name.name });

            const name_str = std.mem.span(name.name);

            if (ctx.name != null) wayland_context.allocator.free(ctx.name.?);
            ctx.name = wayland_context.allocator.alloc(u8, name_str.len) catch return;
            @memcpy(ctx.name.?, name_str);

            ctx.state = .configuring;
        },
        // don't need description or scale (right now)
        .description, .scale => {},
        .done => {
            log.debug("{} :: output is done", .{ctx.serial});

            assert(ctx.state == .configuring or ctx.state == .done);
            assert(ctx.has_mode);
            assert(ctx.has_geometry);
            assert(ctx.name != null);
            ctx.state = .done;
        },
    }
}

pub fn surfaceListener(surface: *wl.Surface, event: wl.Surface.Event, ctx: *OutputContext) void {
    _ = surface;
    _ = ctx;

    switch (event) {
        .enter => |enter| log.debug("entered surface: {?}", enter),
        .leave => |leave| log.debug("left surface: {?}", leave),
        .preferred_buffer_scale => |scale| log.debug("told to use scale: {?}", scale),
        .preferred_buffer_transform => |transform| log.debug("buffer is transformed: {s}", .{@tagName(transform.transform)}),
    }
}

fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, ctx: *OutputContext) void {
    _ = layer_surface;
    _ = ctx;

    switch (event) {
        .configure => {},
        .closed => {
            panic("Layer Surface Closed (unimplemented)", .{}); // close output maybe?
        },
    }
}

//pub fn startOutput(self: *OutputContext) void {
//    log.info("Starting Output '{s}'", .{self.name_str.?});
//
//    assert(self.details == .is_done);
//    assert(self.display_width != null and self.display_height != null);
//    assert(self.display_physical_width != null and self.display_physical_height != null);
//    //assert(self.wayland_context.shm != null);
//    self.details = .has_started;
//
//    const wayland_context = self.wayland_context;
//
//    // get compositor surface
//    const surface = wayland_context.compositor.?.createSurface() catch |err| panic("Failed to create surface with: {s}", .{@errorName(err)});
//    self.surface = surface;
//
//    surface.setListener(*OutputContext, surfaceListener, self);
//
//    // create layer surface
//    const layer_surface = wayland_context.layer_shell.?.getLayerSurface(surface, null, zwlr.LayerShellV1.Layer.top, "elijah-immer/walrus-bar") catch |err|
//        panic("Failed to create layer surface with: {s}", .{@errorName(err)});
//    self.layer_surface = layer_surface;
//
//    layer_surface.setAnchor(zwlr.LayerSurfaceV1.Anchor{
//        .bottom = false,
//        .right = true,
//        .left = true,
//        .top = true,
//    });
//    layer_surface.setSize(0, config.height);
//    layer_surface.setKeyboardInteractivity(zwlr.LayerSurfaceV1.KeyboardInteractivity.none);
//    layer_surface.setExclusiveZone(config.height);
//
//    layer_surface.setListener(*OutputContext, layerSurfaceListener, self);
//
//    surface.commit();
//    if (wayland_context.display.roundtrip() != .SUCCESS) panic("Roundtrip Failed", .{});
//
//    if (self.display_width.? == 0 or self.display_height.? == 0) {
//        log.warn("Output '{s}' not displaying, zero width or height detected", .{self.name_str.?});
//        return;
//    }
//
//    const width: u31 = config.width orelse self.display_width.?;
//    const height: u31 = config.height;
//
//    log.debug("width: {}, height: {}", .{ width, height });
//
//    self.screen = Screen.init(.{ .x = width, .y = height }) catch |err| panic("Failed to create screen: {s}", .{@errorName(err)});
//
//    self.screen.?.fill_box(.{ .x = 0, .y = 0, .width = width, .height = height }, config.background_color);
//
//    const pool = wayland_context.shm.?.createPool(self.screen.?.fd, height * width * @sizeOf(Color)) catch |err| panic("Failed to create SHM pool: {s}", .{@errorName(err)});
//    self.pool = pool;
//
//    const stride = width * @sizeOf(Color);
//
//    const buffer = self.pool.?.createBuffer(0, width, height, stride, wl.Shm.Format.argb8888) catch |err| panic("failed to create buffer from pool: {s}", .{@errorName(err)});
//    self.buffer = buffer;
//
//    surface.attach(buffer, 0, 0);
//    if (wayland_context.display.roundtrip() != .SUCCESS) panic("Roundtrip Failed", .{});
//
//    // create buffer
//    // attach buffer
//    // request frame
//}

const wayland_context = &@import("WaylandContext.zig").global;
const Config = @import("Config.zig");
const config = &Config.config;

const Color = @import("colors.zig").Color;

const Screen = @import("drawing.zig").Screen;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const log = std.log.scoped(.OutputContext);
const assert = std.debug.assert;
const panic = std.debug.panic;
