pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    try Config.init_global(alloc);
    defer Config.deinit_global();

    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();
    defer registry.destroy();

    var wayland_context = try WaylandContext.init(alloc);
    defer wayland_context.deinit();

    log.debug("Starting Registry", .{});
    registry.setListener(*WaylandContext, registryListener, &wayland_context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    //const shm = wayland_context.shm orelse return error.@"No Wayland Shared Memory";

    const compositor = wayland_context.compositor orelse return error.@"No Wayland Compositor";

    const surface = try compositor.createSurface();
    defer surface.destroy();

    var surface_ctx = false;

    surface.setListener(*bool, surfaceListener, &surface_ctx);

    //if (wayland_context.outputs.len == 0) return error.@"No Wayland Outputs";

    //const wm_base = wayland_context.wm_base orelse return error.@"No Xdg Window Manager Base";
    //const layer_shell = wayland_context.layer_shell orelse return error.@"No WlRoots Layer Shell";

    //if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    //const width: u31 = config.width orelse unreachable;
    //orelse wayland_context.outputs.width orelse width: {
    //    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed; // try an additional time

    //    if (wayland_context.output_context.width) |width| break :width width;

    //    return error.@"No screen size given by wayland";
    //};
    //const height: u31 = config.height;

    //log.debug("width: {}, height: {}", .{ width, height });

    //const screen = try Screen.init(.{ .x = width, .y = height });
    //defer screen.deinit();

    //screen.fill_box(.{ .x = 0, .y = 0, .width = width, .height = height }, config.background_color);

    //const drawing_context = try DrawingContext.init(.{
    //    .parent_allocator = alloc,
    //    .output_context = &wayland_context.output_context,
    //    .config = &config,
    //    .screen = &screen,
    //});
    //defer drawing_context.deinit();

    //const pool = try shm.createPool(screen.fd, height * width * @sizeOf(Color));
    //defer pool.destroy();

    //const stride = width * @sizeOf(Color);

    //const buffer = try pool.createBuffer(0, width, height, stride, wl.Shm.Format.argb8888);
    //defer buffer.destroy();

    ////// ===== surface here

    //// TODO: Add output here
    //const layer_surface = try layer_shell.getLayerSurface(surface, null, zwlr.LayerShellV1.Layer.top, "elijah-immer/walrus-bar");
    //defer layer_surface.destroy();

    //layer_surface.setAnchor(zwlr.LayerSurfaceV1.Anchor{
    //    .bottom = false,
    //    .right = true,
    //    .left = true,
    //    .top = true,
    //});
    //layer_surface.setSize(0, height);
    //layer_surface.setKeyboardInteractivity(zwlr.LayerSurfaceV1.KeyboardInteractivity.none);
    //layer_surface.setExclusiveZone(height);

    const running = true;

    //layer_surface.setListener(*bool, layerSurfaceListener, &running);

    //surface.commit();
    //if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    //surface.attach(buffer, 0, 0);
    //surface.commit();

    //if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
}

const WaylandContext = struct {
    allocator: Allocator,

    outputs: OutputsArray,

    compositor: ?*wl.Compositor = null,
    compositor_name: u32 = undefined,

    shm: ?*wl.Shm = null,
    shm_name: u32 = undefined,

    wm_base: ?*xdg.WmBase = null,
    wm_name: u32 = undefined,

    layer_shell: ?*zwlr.LayerShellV1 = null,
    layer_shell_name: u32 = undefined,

    pub const OutputsArray = SegmentedList(OutputContext, 0);

    pub fn init(allocator: Allocator) Allocator.Error!@This() {
        return .{
            .allocator = allocator,
            .outputs = OutputsArray{},
        };
    }

    pub fn deinit(self: *@This()) void {
        var outputs_iter = self.outputs.iterator(0);
        while (outputs_iter.next()) |output| if (output.is_alive) output.output.release();
        self.outputs.deinit(self.allocator);

        if (self.compositor) |compositor| compositor.destroy();
        if (self.shm) |shm| shm.destroy();
        //if (self.wm_base) |wm_base| wm_base.destroy();
        if (self.layer_shell) |layer_shell| layer_shell.destroy();
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *WaylandContext) void {
    const log_local = std.log.scoped(.@"Wayland-Registry");

    const listen_for = .{
        .{ wl.Compositor, "compositor" },
        .{ wl.Shm, "shm" },
        //.{ xdg.WmBase, "wm_base" },
        .{ zwlr.LayerShellV1, "layer_shell" },
    };

    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Output.getInterface().name) == .eq) {
                log_local.debug("Output #{} Added with id #{}", .{ context.outputs.len + 1, global.name });

                const output = registry.bind(global.name, wl.Output, 1) catch @panic("Failed to register output");

                const output_context = output_context: {
                    var outputs_iter = context.outputs.iterator(0);
                    while (outputs_iter.next()) |output_space| {
                        if (!output_space.is_alive) break :output_context output_space;
                    }

                    // if there is no available space, add a new one.
                    break :output_context context.outputs.addOne(context.allocator) catch @panic("OOM");
                };
                output_context.* = .{
                    .output = output,
                    .name = global.name,
                };

                output.setListener(*OutputContext, outputListener, output_context);
                return;
            }

            inline for (listen_for) |variable| {
                const resource, const field = variable;

                if (mem.orderZ(u8, global.interface, resource.getInterface().name) == .eq) {
                    log_local.debug("global added: '{s}'", .{global.interface});
                    @field(context, field) = registry.bind(global.name, resource, 1) catch return; // TODO: find out why it only accepts version 1
                    @field(context, field ++ "_name") = global.name;

                    return;
                }
            }

            //log_local.debug("unknown global added: '{s}'", .{global.interface});
        },
        .global_remove => |global| {
            var was_removed = false;
            var last_alive: usize = 0;
            var idx: usize = 0;

            if (context.outputs.len > 0) {
                var outputs_iter = context.outputs.iterator(0);
                while (outputs_iter.next()) |output_ctx| {
                    std.debug.print("{} ", .{idx});
                    if (output_ctx.is_alive) {
                        if (global.name == output_ctx.name) {
                            std.debug.print("\n", .{});
                            log_local.info("Output {} at idx {} was removed", .{ output_ctx.name, idx });
                            assert(!was_removed); // two outputs with the same name?

                            output_ctx.* = undefined;
                            output_ctx.is_alive = false;
                            // don't release, it was done for us.
                            was_removed = true;
                            idx += 1;
                            continue;
                        }
                        last_alive = idx;
                    }
                    idx += 1;
                }
                std.debug.print("\n", .{});
            }

            if (was_removed) {
                var outputs_iter = context.outputs.iterator(last_alive + 1);
                while (outputs_iter.next()) |output_ctx| {
                    assert(!output_ctx.is_alive);
                }

                context.outputs.shrinkCapacity(context.allocator, last_alive + 1);
                context.outputs.shrink(last_alive + 1);

                return;
            }

            inline for (listen_for) |variable| {
                _, const field = variable;

                if (@field(context, field) != null) {
                    if (global.name == @field(context, field ++ "_name")) {
                        log_local.info("Resource '{s}' was removed", .{field});
                        @field(context, field ++ "_name") = undefined;
                        @field(context, field) = null;

                        return;
                    }
                }
            }
        },
    }
}

pub const SurfaceContext = *bool;
fn surfaceListener(surface: *wl.Surface, event: wl.Surface.Event, ctx: SurfaceContext) void {
    _ = surface;
    _ = ctx;
    switch (event) {
        .enter, .leave => {},
    }
}

fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, running: *bool) void {
    switch (event) {
        .configure => |configure| layer_surface.ackConfigure(configure.serial),
        .closed => running.* = false,
    }
}

pub const OutputContext = struct {
    is_alive: bool = true,

    output: *wl.Output,
    name: u32,

    width: ?u16 = null,
    height: ?u16 = null,
    physical_width: ?u16 = null,
    physical_height: ?u16 = null,
    is_done: bool = false,
};

fn outputListener(output: *wl.Output, event: wl.Output.Event, ctx: *OutputContext) void {
    const log_local = std.log.scoped(.@"Wayland-Output");

    assert(ctx.is_alive);
    assert(output == ctx.output);

    switch (event) {
        .geometry => |geometry| {
            ctx.physical_width = @intCast(geometry.physical_width);
            ctx.physical_height = @intCast(geometry.physical_height);
            log_local.debug("{} :: geometry x: {}, y: {}, physical_width: {}, physical_height: {}", .{ ctx.name, geometry.x, geometry.y, geometry.physical_width, geometry.physical_height });
        },
        .mode => |mode| {
            ctx.width = @intCast(mode.width);
            ctx.height = @intCast(mode.height);
            log_local.debug("{} :: mode width: {}, height: {}, refresh: {}", .{ ctx.name, mode.width, mode.height, mode.refresh });
        },
        .done => {
            log_local.debug("{} :: output is done", .{ctx.name});
            ctx.is_done = true;
        },
        .scale => |scale| {
            log_local.debug("{} :: scale: {}", .{ ctx.name, scale });
        },
        .name => |name| {
            log_local.debug("{} :: name: '{}'", .{ ctx.name, name });
        },
        .description => |description| {
            log_local.debug("{} :: description: '{}'", .{ ctx.name, description });
        },
    }
}

test {
    std.testing.refAllDecls(colors);
    std.testing.refAllDecls(drawing);
    std.testing.refAllDecls(DrawingContext);
    std.testing.refAllDecls(@import("Config.zig"));
    std.testing.refAllDecls(@import("wayland")); // make sure the wayland binds work
}

const colors = @import("colors.zig");
const Color = colors.Color;
const Config = @import("Config.zig");
const config = Config.config;

const drawing = @import("drawing.zig");
const DrawingContext = @import("DrawingContext.zig");
const Screen = drawing.Screen;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const freetype = @import("freetype");

const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const Allocator = mem.Allocator;
const SegmentedList = std.SegmentedList;

const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"walrus-bar");
