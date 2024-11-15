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
    assert(wayland_context.pointer != null);
    assert(pointer == wayland_context.pointer.?);
    //const log_local = std.log.scoped(.Pointer);

    const checker = struct {
        pub fn checker(output: *const Output, target: *wl.Surface) bool {
            return output.surface == target;
        }
    }.checker;

    //log.debug("get event: {s}", .{@tagName(event)});

    switch (event) {
        .enter => |enter| {
            if (enter.surface) |surface| {
                const output_idx = wayland_context.findOutput(*wl.Surface, surface, &checker) orelse @panic("Pointer event on surface that doesn't exist!");

                const output = &wayland_context.outputs.items[output_idx];
                wayland_context.last_motion_surface = output;

                assert(output.root_container != null);
                const root_container = &output.root_container.?;

                const point = Point{
                    .x = @intCast(@max(enter.surface_x.toInt(), 0)),
                    .y = @intCast(@max(enter.surface_y.toInt(), 0)),
                };

                if (wayland_context.cursor_shape_manager) |cursor_shape_manager| set_pointer: {
                    const pointer_device = wp.CursorShapeManagerV1.getPointer(
                        cursor_shape_manager,
                        pointer,
                    ) catch |err| {
                        log.warn("Failed to get pointer device for surface '{s}' with: {s}", .{ output.output_context.name_str.constSlice(), @errorName(err) });
                        break :set_pointer;
                    };
                    defer pointer_device.destroy();
                    pointer_device.setShape(enter.serial, .default);
                }

                if (root_container.area.containsPoint(point)) root_container.motion(point);
            } else {
                //log_local.warn("Cursor entered but not on a surface?", .{});
            }
        },
        .motion => |motion| {
            if (wayland_context.last_motion_surface) |output| {
                assert(output.root_container != null);
                const root_container = &output.root_container.?;

                const point = Point{
                    .x = @intCast(@max(motion.surface_x.toInt(), 0)),
                    .y = @intCast(@max(motion.surface_y.toInt(), 0)),
                };

                if (root_container.area.containsPoint(point)) root_container.motion(point);
            } else {
                //log_local.warn("Cursor motion but not on a surface?", .{});
            }
        },
        .leave => |leave| {
            if (leave.surface) |surface| {
                const output_idx = wayland_context.findOutput(*wl.Surface, surface, &checker) orelse @panic("Pointer event on surface that doesn't exist!");

                const draw_context = &wayland_context.outputs.items[output_idx];

                assert(draw_context.root_container != null);

                draw_context.root_container.?.leave();
            } else {
                //log_local.warn("Cursor left but not on a surface?", .{});
            }
        },
        .button => |button| {
            if (button.state != .pressed) return;

            switch (@as(MouseButton, @enumFromInt(button.button))) {
                .middle_click => {
                    if (builtin.mode == .Debug) {
                        wayland_context.running = false;
                    }
                },
                .right_click => {
                    if (builtin.mode == .Debug) {
                        for (wayland_context.outputs.items) |*output| {
                            output.full_redraw = true;
                        }
                    }
                },
                else => {
                    if (wayland_context.last_motion_surface) |draw_context| {
                        assert(draw_context.root_container != null);
                        draw_context.root_container.?.click(@enumFromInt(button.button));
                    } else {
                        //log_local.warn("Cursor motion but not on a surface?", .{});
                    }
                },
            }
        },
        .axis => |axis| {
            //log.debug("axis: {}", .{axis});
            if (axis.value.toInt() == 0) return;

            if (wayland_context.last_motion_surface) |draw_context| {
                assert(draw_context.root_container != null);
                draw_context.root_container.?.scroll(axis.axis, axis.value.toInt());
            } else {
                //log_local.warn("Scroll event but not on a surface?", .{});
            }
        },
        // TODO: Implement input frames.
        .frame, .axis_stop, .axis_value120, .axis_discrete, .axis_relative_direction, .axis_source => {},
    }
}

pub const Axis = wl.Pointer.Axis;

pub const MouseButton = enum(u16) {
    left_click = 272,
    right_click = 273,
    middle_click = 274,
    _,
};

const WaylandContext = @import("WaylandContext.zig");
const Output = @import("Output.zig");

const drawing = @import("drawing.zig");
const Point = drawing.Point;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;

const builtin = @import("builtin");
const std = @import("std");

const assert = std.debug.assert;
const panic = std.debug.panic;
const maxInt = std.math.maxInt;

const log = std.log.scoped(.Seat);
