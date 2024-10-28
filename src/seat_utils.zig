pub fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, wayland_context: *WaylandContext) void {
    const log_local = std.log.scoped(.Seat);

    switch (event) {
        .name => |name| {
            log_local.debug("Seat name {s}", .{name.name});
        },
        .capabilities => |capabilities| {
            if (wayland_context.pointer) |pointer| pointer.release();
            wayland_context.pointer = null;

            if (capabilities.capabilities.pointer) {
                const pointer = seat.getPointer() catch @panic("Failed to get pointer");

                assert(wayland_context.pointer == null); // only allow one pointer device. TODO: See if we should allow multiple
                wayland_context.pointer = pointer;

                pointer.setListener(*WaylandContext, pointerListener, wayland_context);
            }
        },
    }
}

pub fn pointerListener(pointer: *wl.Pointer, event: wl.Pointer.Event, wayland_context: *WaylandContext) void {
    assert(wayland_context.pointer != null and pointer == wayland_context.pointer.?);
    const log_local = std.log.scoped(.Pointer);

    const checker = struct {
        pub fn checker(draw_context: *const DrawContext, target: *wl.Surface) bool {
            return draw_context.surface == target;
        }
    }.checker;

    switch (event) {
        .enter => |enter| {
            const surface_x: u31 = @intCast(@max(enter.surface_x.toInt(), 0));
            const surface_y: u31 = @intCast(@max(enter.surface_y.toInt(), 0));

            if (enter.surface) |surface| {
                const output_idx = wayland_context.findOutput(*wl.Surface, surface, &checker) orelse @panic("Pointer event on surface that doesn't exist!");

                const draw_context = &wayland_context.outputs.items[output_idx];
                wayland_context.last_motion_surface = draw_context;

                draw_context.motion(.{
                    .x = surface_x,
                    .y = surface_y,
                });
            } else {
                log_local.warn("Cursor entered but not on a surface?", .{});
            }
        },
        .motion => |motion| {
            const surface_x: u31 = @intCast(@max(motion.surface_x.toInt(), 0));
            const surface_y: u31 = @intCast(@max(motion.surface_y.toInt(), 0));

            if (wayland_context.last_motion_surface) |draw_context| {
                draw_context.motion(.{
                    .x = surface_x,
                    .y = surface_y,
                });
            } else {
                log_local.warn("Cursor motion but not on a surface?", .{});
            }
        },
        .leave => |leave| {
            if (leave.surface) |surface| {
                const output_idx = wayland_context.findOutput(*wl.Surface, surface, &checker) orelse @panic("Pointer event on surface that doesn't exist!");

                const draw_context = &wayland_context.outputs.items[output_idx];

                draw_context.leave();
            } else {
                log_local.warn("Cursor left but not on a surface?", .{});
            }
        },
        .button => |button| {
            if (button.state != .pressed) return;

            switch (@as(MouseButtons, @enumFromInt(button.button))) {
                .middle_click => {
                    wayland_context.running = false;
                },
                .left_click, .right_click => {
                    for (wayland_context.outputs.items) |*output| {
                        output.full_redraw = true;
                    }
                },
                _ => {
                    log.debug("unknown button pressed: {}", .{button.button});
                },
            }
        },
        // TODO: Implement input frames.
        .axis, .frame, .axis_source, .axis_stop, .axis_discrete, .axis_value120, .axis_relative_direction => {},
    }
}

pub const MouseButtons = enum(u16) {
    left_click = 272,
    right_click = 273,
    middle_click = 274,
    _,
};

const WaylandContext = @import("WaylandContext.zig");
const DrawContext = @import("DrawContext.zig");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");

const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"walrus-bar");
const maxInt = std.math.maxInt;
