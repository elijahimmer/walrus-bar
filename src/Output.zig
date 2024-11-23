//! The storage for everything related to a single output.
//! Holds all the wayland objects for the output. (like the surfaces)

pub const Output = @This();

output_context: OutputContext,
root_container: ?RootContainer = null,

wayland_context: *WaylandContext,

full_redraw: bool = true,

/// The main wayland surface.
surface: ?*wl.Surface,

/// The wl object that allows for layer shell configuration
layer_surface: ?*zwlr.LayerSurfaceV1,

/// The shared memory pool for output's display
shm_pool: ?ShmPool = null,

/// The callback to draw the next frame.
frame_callback: ?*wl.Callback = null,

/// The size of the window.
window_size: Point = Point.ZERO,

popup: ?Popup = null,

pub fn init(args: OutputContext.InitArgs) !Output {
    return Output{
        .output_context = OutputContext.init(args),
        .surface = null,
        .layer_surface = null,
        .wayland_context = args.wayland_context,
    };
}

pub fn deinit(output: *Output) void {
    output.output_context.deinit();

    if (output.root_container) |*rc| rc.deinit();
    if (output.shm_pool) |*pool| pool.deinit();
    if (output.surface) |surface| surface.destroy();
    if (output.layer_surface) |layer_surface| layer_surface.destroy();
    if (output.frame_callback) |frame_callback| frame_callback.destroy();

    output.* = undefined;
}

pub fn outputChanged(output: *Output, wayland_context: *WaylandContext) !void {
    assert(wayland_context.compositor != null);
    assert(wayland_context.layer_shell != null);

    // if it is zero sized, no need for drawing or anything.
    // if the surface isn't set up yet, do so.
    if (output.surface == null) {
        assert(output.layer_surface == null);

        const surface = try wayland_context.compositor.?.createSurface();
        surface.setListener(*WaylandContext, surfaceListener, wayland_context);

        output.surface = surface;

        const layer_surface = try wayland_context.layer_shell.?.getLayerSurface(
            surface,
            output.output_context.output,
            constants.WAYLAND_LAYER,
            constants.WAYLAND_NAMESPACE,
        );
        output.layer_surface = layer_surface;

        layer_surface.setSize(config.general.width orelse 0, config.general.height);
        layer_surface.setAnchor(constants.WAYLAND_ZWLR_ANCHOR);
        layer_surface.setExclusiveZone(config.general.height);
        layer_surface.setKeyboardInteractivity(zwlr.LayerSurfaceV1.KeyboardInteractivity.none);

        layer_surface.setListener(*WaylandContext, layerSurfaceListener, wayland_context);

        surface.commit();

        if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");
    } else {
        assert(output.layer_surface != null);
    }

    assert(output.surface != null);
    assert(output.layer_surface != null);

    if (output.window_size.x < constants.MINIMUM_WINDOW_WIDTH or output.window_size.y < constants.MINIMUM_WINDOW_HEIGHT) {
        log.info("Output '{s}' too small to show at width: {}, height: {}", .{
            output.output_context.name_str.constSlice(),
            output.window_size.x,
            output.window_size.y,
        });

        if (output.frame_callback) |frame_callback| frame_callback.destroy();
        output.frame_callback = null;

        return;
    }

    if (output.shm_pool) |*shm_pool| {
        shm_pool.resize(wayland_context, .{
            .x = output.window_size.x,
            .y = output.window_size.y,
        }) catch |err| {
            log.warn("Failed to create Shared memory pool on output resize. error={s}", .{@errorName(err)});
            shm_pool.pool.destroy();
            return err;
        };
    } else {
        output.shm_pool = ShmPool.init(.{
            .wayland_context = wayland_context,

            .width = output.window_size.x,
            .height = output.window_size.y,
        }) catch |err| {
            log.warn("Failed to create Shared memory pool on output resize. error={s}", .{@errorName(err)});
            return err;
        };
    }
    errdefer {
        output.shm_pool.deinit();
        output.shm_pool = null;
    }

    output.full_redraw = true;

    //TODO: Implement root container resizing.
    if (output.root_container == null) {
        output.root_container = RootContainer.init(output.window_size.extendTo(Point.ZERO));
    }
    assert(output.root_container != null);

    output.root_container.?.setArea(output.window_size.extendTo(Point.ZERO));

    output.draw();

    if (output.frame_callback) |fc| fc.destroy();
    output.frame_callback = output.surface.?.frame() catch @panic("Failed Getting Frame Callback.");
    output.frame_callback.?.setListener(*WaylandContext, nextFrame, wayland_context);

    output.surface.?.commit();
}

pub fn draw(output: *Output) void {
    assert(output.root_container != null);
    assert(output.shm_pool != null);
    assert(output.surface != null);

    // if no buffers available, just don't draw.
    const buffer, const screen = output.shm_pool.?.getBuffer() orelse return;

    var draw_context = DrawContext{
        .surface = output.surface.?,
        .window_area = output.window_size.extendTo(Point.ZERO),
        .screen = screen,

        .current_area = Rect.ZERO,

        .full_redraw = output.full_redraw,
    };
    defer draw_context.deinit();
    defer output.full_redraw = false;

    if (output.full_redraw) {
        log.info("Full redraw...", .{});
        output.surface.?.damageBuffer(0, 0, output.window_size.x, output.window_size.y);
        @memset(screen, config.general.background_color);
    }

    output.root_container.?.draw(&draw_context) catch |err| switch (err) {};

    // add the changes to the surface.
    output.surface.?.attach(buffer, 0, 0);
}

pub fn nextFrame(callback: *wl.Callback, event: wl.Callback.Event, wayland_context: *WaylandContext) void {
    // make sure no other events can happen.
    switch (event) {
        .done => {},
    }

    const output_checker = struct {
        pub fn checker(output: *const Output, target: *wl.Callback) bool {
            return output.frame_callback == target;
        }
    }.checker;

    // if not found, return because the output likely isn't alive anymore and this callback is stale.
    const output = wayland_context.findOutput(
        *wl.Callback,
        callback,
        &output_checker,
    ) orelse @panic("Output not found for drawing!");

    output.draw();

    if (output.frame_callback) |fc| fc.destroy();
    output.frame_callback = output.surface.?.frame() catch @panic("Failed Getting Frame Callback.");
    output.frame_callback.?.setListener(*WaylandContext, nextFrame, wayland_context);

    output.surface.?.commit();
}

/// TODO: Find a new home for the listeners.
pub fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, wayland_context: *WaylandContext) void {
    const output_checker = struct {
        pub fn checker(output: *const Output, target: *zwlr.LayerSurfaceV1) bool {
            return output.layer_surface == target;
        }
    }.checker;

    const output = wayland_context.findOutput(
        *zwlr.LayerSurfaceV1,
        layer_surface,
        &output_checker,
    ) orelse @panic("LayerSurface not found for event!");

    switch (event) {
        .configure => |configure| {
            log.debug("Output '{s}' (id #{}) Layer Shell was configured. width: {}, height: {}", .{
                output.output_context.name_str.constSlice(),
                output.output_context.id,
                configure.width,
                configure.height,
            });
            output.window_size.x = @intCast(configure.width);
            output.window_size.y = @intCast(configure.height);

            layer_surface.ackConfigure(configure.serial);
        },
        .closed => {
            // TODO: Make sure this is cleaned up properly. I think it is...
            log.debug("Output '{s}' (id #{}) Surface done", .{ output.output_context.name_str.constSlice(), output.output_context.id });
            output.layer_surface = null;
        },
    }
}

pub fn surfaceListener(surface: *wl.Surface, event: wl.Surface.Event, wayland_context: *WaylandContext) void {
    _ = surface;
    _ = wayland_context;

    switch (event) {
        // TODO: Use this for scaling and transform
        .enter, .leave, .preferred_buffer_scale, .preferred_buffer_transform => {},
    }
}

test {
    std.testing.refAllDecls(@This());
}

const options = @import("options");
const constants = @import("constants.zig");

const Config = @import("Config.zig");
const config = &Config.global;

const colors = @import("colors.zig");

const DrawContext = @import("DrawContext.zig");
const OutputContext = @import("OutputContext.zig");
const WaylandContext = @import("WaylandContext.zig");
const RootContainer = @import("RootContainer.zig");

const ShmPool = @import("ShmPool.zig");
const Popup = @import("Popup.zig");

const Workspaces = @import("workspaces/Workspaces.zig");
const Clock = @import("Clock.zig");
const Battery = @import("Battery.zig");
const Brightness = @import("Brightness.zig");

const drawing = @import("drawing.zig");
const Point = drawing.Point;
const Rect = drawing.Rect;
const Size = drawing.Size;

const seat_utils = @import("seat_utils.zig");
const MouseButton = seat_utils.MouseButton;
const Axis = seat_utils.Axis;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const posix = std.posix;

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const assert = std.debug.assert;

const log = std.log.scoped(.Output);
