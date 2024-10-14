//! This holds the entire context of the Wayland connection
//! The names are only valid when the ptr assosiated is not null.

pub const WaylandContext = @This();
pub const OutputsArray = ArrayListUnmanaged(DrawContext);
display: *wl.Display,
registry: *wl.Registry,
allocator: Allocator,

outputs: OutputsArray,

compositor: ?*wl.Compositor = null,
compositor_name: u32 = undefined,

shm: ?*wl.Shm = null,
shm_name: u32 = undefined,

layer_shell: ?*zwlr.LayerShellV1 = null,
layer_shell_name: u32 = undefined,

seat: ?*wl.Seat = null,
seat_name: u32 = undefined,

pointer: ?*wl.Pointer = null,

running: bool = true,

pub fn deinit(self: *WaylandContext) void {
    // destroy pointers first so it is less likely that a event will happen after the output was removed.
    if (self.pointer) |pointer| pointer.release();
    if (self.seat) |seat| seat.release();

    for (self.outputs.items) |*output| output.deinit(self.allocator);

    if (self.shm) |shm| shm.destroy();
    if (self.layer_shell) |layer_shell| layer_shell.destroy();
    if (self.compositor) |compositor| compositor.destroy();

    self.outputs.deinit(self.allocator);

    self.* = undefined;
}

/// Runs the checker on all outputs in the outputs field of a WaylandContext.
/// Used to identify a output by a pointer to a object it contains.
/// This panics if the checker returns true on two or more outputs, so the identifier
/// should be output unique
pub fn findOutput(self: *WaylandContext, comptime T: type, target: T, checker: *const fn (*const DrawContext, T) bool) ?u32 {
    var output_idx: ?u32 = null;

    for (self.outputs.items, 0..) |*output, index| {
        if (checker(output, target)) {
            if (output_idx != null) @panic("Two Outputs with the same " ++ @typeName(T) ++ " found!");
            output_idx = @intCast(index);
        }
    }

    return output_idx;
}

pub fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *WaylandContext) void {
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
                output.setListener(*WaylandContext, DrawContext.outputListener, context);

                context.outputs.append(context.allocator, .{
                    .output_context = .{
                        .output = output,
                        .id = global.name,
                    },

                    .widget_left = undefined,
                }) catch @panic("Too many outputs!");

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

            inline for (listen_for) |variable| {
                const resource, const field = variable;

                if (mem.orderZ(u8, global.interface, resource.getInterface().name) == .eq) {
                    log_local.debug("global added: '{s}'", .{global.interface});
                    assert(@field(context, field) == null);
                    @field(context, field) = registry.bind(global.name, resource, resource.generated_version) catch @panic("Failed to bind resource");
                    @field(context, field ++ "_name") = global.name;

                    return;
                }
            }

            log_local.debug("unknown global ignored: '{s}'", .{global.interface});
        },
        .global_remove => |global| {
            for (context.outputs.items, 0..) |*draw_context, idx| {
                const output_context = &draw_context.output_context;
                if (output_context.id == global.name) {
                    log_local.debug("Output '{s}' was removed", .{output_context.name});
                    draw_context.deinit(context.allocator);

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
const DrawContext = @import("DrawContext.zig");
const seat_utils = @import("seat_utils.zig");
const TextBox = @import("TextBox.zig");
const drawing = @import("drawing.zig");

const colors = @import("colors.zig");
const Color = colors.Color;

const config = &@import("Config.zig").global;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const mem = std.mem;

const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.WaylandContext);
