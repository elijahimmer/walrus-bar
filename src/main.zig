pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try Config.init_global(allocator);

    const display = try wl.Display.connect(null);
    var registry = try display.getRegistry();

    var wayland_context = WaylandContext{
        .display = display,
        .registry = registry,
        .allocator = allocator,
    };
    defer wayland_context.deinit();

    registry.setListener(*WaylandContext, WaylandContext.registryListener, &wayland_context);
    // populate initial registry
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    wayland_context.seat.?.setListener(*WaylandContext, seatListener, &wayland_context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (wayland_context.running) {
        switch (display.dispatch()) {
            .SUCCESS => {},
            .INVAL => {
                log.warn("Roundtrip Failed with Invalid Request", .{});
                break;
            },
            else => |err| {
                log.warn("Roundtrip Failed: {s}", .{@tagName(err)});
            },
        }
    }

    log.info("Shutting Down.", .{});
}

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
        pub fn checker(draw_context: *DrawContext, target: *wl.Surface) bool {
            return draw_context.surface == target;
        }
    };

    switch (event) {
        .enter => |enter| {
            if (enter.surface) |surface| {
                const output_idx = wayland_context.findOutput(*wl.Surface, surface, &checker.checker) orelse @panic("Pointer event on surface that doesn't exist!");

                const draw_context = wayland_context.outputs.slice()[output_idx];

                log_local.debug("Cursor entered surface on {s}", .{draw_context.output_context.name});
            } else {
                log_local.warn("Cursor entered but not on a surface?", .{});
            }
        },
        .leave => |leave| {
            if (leave.surface) |surface| {
                const output_idx = wayland_context.findOutput(*wl.Surface, surface, &checker.checker) orelse @panic("Pointer event on surface that doesn't exist!");

                const draw_context = wayland_context.outputs.slice()[output_idx];

                log_local.debug("Cursor left surface on {s}", .{draw_context.output_context.name});
            } else {
                log_local.warn("Cursor left but not on a surface?", .{});
            }
        },
        .button => {
            wayland_context.running = false;
        },
        .motion, .axis, .frame, .axis_source, .axis_stop, .axis_discrete, .axis_value120, .axis_relative_direction => {},
    }
}

test {
    std.testing.refAllDecls(@import("Config.zig"));
    std.testing.refAllDecls(@import("wayland"));
    std.testing.refAllDecls(@This());
}

const WaylandContext = @import("WaylandContext.zig");
const DrawContext = @import("DrawContext.zig");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Config = @import("Config.zig");

const std = @import("std");

const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"walrus-bar");
const maxInt = std.math.maxInt;
