//! This holds the entire context of the Wayland connection
//! The names are only valid when the pointer associated is not null.

pub const WaylandContext = @This();

/// 8 outputs should be enough for anyone.
pub const MAX_OUTPUT_COUNT = 8;
pub const OutputsArray = BoundedArray(Output, MAX_OUTPUT_COUNT);

/// The Wayland connection itself.
display: *wl.Display,

/// The registry that holds and controls all the global variables.
registry: *wl.Registry,

/// Stores the info for all the outputs.
outputs: OutputsArray,

/// used to create all the Wayland surfaces.
compositor: ?*wl.Compositor = null,

/// only valid when `compositor` is not null.
compositor_name: u32 = undefined,

/// Handles all the shared memory buffers for the outputs
shm: ?*wl.Shm = null,

/// only valid when `shm` is not null.
shm_name: u32 = undefined,

/// handles window layer and placement (i.e. putting it up like a bar)
layer_shell: ?*zwlr.LayerShellV1 = null,

/// only valid when `layer_shell` is not null.
layer_shell_name: u32 = undefined,

/// handles window layer and placement (i.e. putting it up like a bar)
xdg_wm_base: ?*xdg.WmBase = null,

/// only valid when `layer_shell` is not null.
xdg_wm_base_name: u32 = undefined,

/// The seat that manages all inputs
/// TODO: See if we need to store a list here.
seat: ?*wl.Seat = null,

/// only valid when `seat` is not null.
seat_name: u32 = undefined,

/// The cursor manager that lets you set the cursor shape.
cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,

/// only valid when `cursor_shape_manager` is not null
cursor_shape_manager_name: u32 = undefined,

/// A pointer device.
/// TODO: See if we need to store a list here.
pointer: ?*wl.Pointer = null,

/// The last surface to have a motion on it.
/// TODO: Remove this and put it pointer local storage when we support multiple.
/// TODO: Make this not a pointer so on output remove it is still the correct output.
last_motion_surface: ?*Output = null,

/// The wayland protocol says it should, but let's check anyway.
has_argb8888: bool = false,

/// Whether or not the program should still be running.
running: bool = true,

pub const InitError = error{ ConnectFailed, RoundtripFailed, OutOfMemory };

pub fn init(wayland_context: *WaylandContext) InitError!void {
    // start wayland connection.
    const display = try wl.Display.connect(null);
    var registry = try display.getRegistry();

    wayland_context.* = WaylandContext{
        .display = display,
        .registry = registry,

        .outputs = .{},
    };

    // set registry to set values in wayland_context
    registry.setListener(*WaylandContext, registryListener, wayland_context);

    // populate initial registry
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
}

/// de-initialize the Wayland context and clean up all the Wayland objects.
pub fn deinit(self: *WaylandContext) void {
    // destroy pointers first so it is less likely that a event will happen after the output was removed.
    if (self.pointer) |pointer| pointer.release();
    if (self.seat) |seat| seat.release();

    for (self.outputs.slice()) |*output| output.deinit();
    // no deinit outputs-array, no need.

    if (self.shm) |shm| shm.destroy();
    if (self.layer_shell) |layer_shell| layer_shell.destroy();
    if (self.compositor) |compositor| compositor.destroy();

    self.* = undefined;
}

/// Runs the checker on all outputs in the outputs_slice field, and returns a pointer to the output if it is found.
/// This used to identify a output by a pointer to a object it contains.
///
/// This panics if the checker returns true for two or more outputs, so the identifier
///     must be output unique.
pub fn findOutput(self: *WaylandContext, comptime T: type, target: T, checker: *const fn (*const Output, T) bool) ?*Output {
    const index = self.findOutputIndex(T, target, checker) orelse return null;

    assert(index < MAX_OUTPUT_COUNT);
    assert(index < self.outputs.len);

    return &self.outputs.slice()[index];
}

/// Runs the checker on all the outputs in the outputs_slice field, and returns the index of the matching output if one is found.
/// This used to identify a output by a pointer to a object it contains.
///
/// This panics if the checker returns true for two or more outputs, so the identifier
///     must be output unique.
pub fn findOutputIndex(self: *WaylandContext, comptime T: type, target: T, checker: *const fn (*const Output, T) bool) ?u32 {
    var output_idx: ?u32 = null;

    for (self.outputs.constSlice(), 0..) |*output, index| {
        assert(index < MAX_OUTPUT_COUNT);

        if (checker(output, target)) {
            if (output_idx != null) @panic("Two Outputs with the same " ++ @typeName(T) ++ " found!");
            output_idx = @intCast(index);
        }
    }

    return output_idx;
}

/// Listens for all global events to add and remove variables, and does so to the WaylandContext.
/// i.e. if a output is added or removed, add or remove it.
/// TODO: Implement removing non-output globals, like seats and such.
pub fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *WaylandContext) void {
    const log_local = std.log.scoped(.Registry);

    const listen_for = .{
        .{ wl.Compositor, "compositor" },
        .{ zwlr.LayerShellV1, "layer_shell" },
        .{ wp.CursorShapeManagerV1, "cursor_shape_manager" },
    };

    switch (event) {
        .global => |global| {
            // TODO: Implement the matching better maybe?
            // Hashmaps?
            if (mem.orderZ(u8, global.interface, wl.Output.getInterface().name) == .eq) {
                log_local.debug("Output Added with id #{}", .{global.name});

                const output = registry.bind(global.name, wl.Output, wl.Output.generated_version) catch return;

                if (std.debug.runtime_safety) {
                    for (context.outputs.constSlice()) |*existing_output| {
                        assert(existing_output.output_context.output != output);
                    }
                }

                const output_info = Output.init(.{
                    .id = global.name,
                    .output = output,
                    .wayland_context = context,
                }) catch |err| {
                    log.warn("Failed to initialize output with error: {s}", .{@errorName(err)});
                    return;
                };

                context.outputs.append(output_info) catch @panic("Too many outputs!");

                return;
            }

            if (mem.orderZ(u8, global.interface, wl.Seat.getInterface().name) == .eq) {
                log_local.debug("Seat added with id #{}", .{global.name});
                assert(context.seat == null);
                const seat = registry.bind(global.name, wl.Seat, wl.Seat.generated_version) catch @panic("Failed to bind resource");
                context.seat = seat;
                context.seat_name = global.name;

                seat.setListener(*WaylandContext, seat_utils.seatListener, context);

                return;
            }

            if (mem.orderZ(u8, global.interface, wl.Shm.getInterface().name) == .eq) {
                assert(context.shm == null);

                const shm = registry.bind(global.name, wl.Shm, wl.Shm.generated_version) catch @panic("Failed to bind Shm");
                context.shm = shm;
                context.shm_name = global.name;

                shm.setListener(*bool, shmListener, &context.has_argb8888);

                return;
            }

            inline for (listen_for) |variable| {
                const resource, const field = variable;

                if (mem.orderZ(u8, global.interface, resource.getInterface().name) == .eq) {
                    log_local.debug("global added: '{s}'", .{global.interface});
                    assert(@field(context, field) == null);
                    @field(context, field) = registry.bind(global.name, resource, resource.generated_version) catch @panic("Failed to bind resource '" ++ field ++ "'");
                    @field(context, field ++ "_name") = global.name;

                    return;
                }
            }

            log_local.debug("unknown global ignored: '{s}'", .{global.interface});
        },
        .global_remove => |global| {
            for (context.outputs.slice(), 0..) |*output, idx| {
                assert(idx < MAX_OUTPUT_COUNT); // loop counter

                const output_id = output.output_context.id;
                if (output_id == global.name) {
                    log_local.debug("Output '{s}' was removed", .{output.output_context.name_str.constSlice()});
                    const ctx = context.outputs.swapRemove(idx);
                    assert(ctx.output_context.id == output_id);

                    output.deinit();

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

/// stub listener to ensure the argb8888 format for buffers is supported.
/// This should be according to the protocol, but might as well check.0
pub fn shmListener(shm: *wl.Shm, event: wl.Shm.Event, has_argb8888: *bool) void {
    _ = shm;
    switch (event) {
        .format => |format| {
            if (format.format == .argb8888) {
                has_argb8888.* = true;
            }
        },
    }
}

const Clock = @import("Clock.zig");
const Output = @import("Output.zig");
const OutputContext = @import("OutputContext.zig");
const seat_utils = @import("seat_utils.zig");
const TextBox = @import("TextBox.zig");
const drawing = @import("drawing.zig");

const colors = @import("colors.zig");
const Color = colors.Color;

const config = &@import("Config.zig").global;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const mem = std.mem;

const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
const log = std.log.scoped(.WaylandContext);
