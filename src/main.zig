pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    try Config.init_global(alloc);
    // no deinit needed

    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();
    //defer registry.destroy();

    wayland_context.* = try WaylandContext.init(alloc, display);
    //defer wayland_context.deinit();

    log.debug("Starting Registry", .{});
    registry.setListener(*WaylandContext, registryListener, wayland_context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    var shm_has_argb8888 = false;
    const shm = wayland_context.shm orelse return error.@"No Wayland Shared Memory";
    shm.setListener(*bool, shmListener, &shm_has_argb8888);

    //const compositor = wayland_context.compositor orelse return error.@"No Wayland Compositor";

    switch (display.roundtrip()) {
        .SUCCESS => {},
        .PROTO => return error.ProtocolError,
        else => |err| {
            log.warn("roundtrip failed with: '{s}'", .{@tagName(err)});
            return error.RoundtripFailed;
        },
    }
    assert(shm_has_argb8888); // supposed to according to Wayland protocol
    if (wayland_context.outputs.len == 0) return error.@"No Wayland Outputs";

    while (wayland_context.running) {
        if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;

        var outputs_iter = wayland_context.outputs.iterator(0);
        var output_idx: u16 = 0;
        while (outputs_iter.next()) |output| {
            output_idx += 1;
            if (!output.is_alive) continue;
        }
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
                log_local.debug("Output #{} Added with id #{}", .{ context.outputs.len + 1, global.name });

                const output = registry.bind(global.name, wl.Output, wl.Output.generated_version) catch @panic("Failed to register output");

                const output_context = output_context: {
                    var outputs_iter = context.outputs.iterator(0);
                    while (outputs_iter.next()) |output_space| {
                        if (!output_space.is_alive) break :output_context output_space;
                    }

                    // if there is no available space, add a new one.

                    context.drawing_contexts.append(context.allocator, .{}) catch @panic("OOM");
                    break :output_context context.outputs.addOne(context.allocator) catch @panic("OOM");
                };
                output_context.* = .{
                    .output = output,
                    .serial = global.name,
                };

                output.setListener(*OutputContext, OutputContext.outputListener, output_context);
                return;
            }

            inline for (listen_for) |variable| {
                const resource, const field = variable;

                if (mem.orderZ(u8, global.interface, resource.getInterface().name) == .eq) {
                    log_local.debug("global added: '{s}'", .{global.interface});
                    @field(context, field) = registry.bind(global.name, resource, resource.generated_version) catch return;
                    // fix so SHM is only on version 1, not 2
                    @field(context, field ++ "_serial") = global.name;

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
                    if (output_ctx.is_alive) {
                        if (global.name == output_ctx.serial) {
                            log_local.info("Output {} at idx {} was removed", .{ output_ctx.serial, idx });
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
            }

            if (was_removed) {
                var outputs_iter = context.outputs.iterator(last_alive + 1);
                while (outputs_iter.next()) |output_ctx| assert(!output_ctx.is_alive);

                context.drawing_contexts.shrinkAndFree(context.allocator, last_alive + 1);
                context.outputs.shrinkCapacity(context.allocator, last_alive + 1);
                context.outputs.shrink(last_alive + 1);

                return;
            }

            inline for (listen_for) |variable| {
                _, const field = variable;

                if (@field(context, field) != null) {
                    if (global.name == @field(context, field ++ "_serial")) {
                        log_local.info("Resource '{s}' was removed", .{field});
                        assert(@field(context, field) != null);

                        @field(context, field ++ "_serial") = undefined;
                        @field(context, field) = null;

                        return;
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
    std.testing.refAllDecls(drawing);
    std.testing.refAllDecls(@import("Config.zig"));
    std.testing.refAllDecls(@import("wayland"));
}

const colors = @import("colors.zig");
const Color = colors.Color;
const Config = @import("Config.zig");
const config = Config.config;

const drawing = @import("drawing.zig");

const WaylandContext = @import("WaylandContext.zig");
const wayland_context = &WaylandContext.global;

//const DrawingContext = @import("DrawingContext.zig");
const OutputContext = @import("OutputContext.zig");
const Screen = drawing.Screen;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const Allocator = mem.Allocator;
const SegmentedList = std.SegmentedList;
const MultiArrayList = std.MultiArrayList;

const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"walrus-bar");
