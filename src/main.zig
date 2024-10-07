pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try Config.init_global(allocator);
    defer Config.deinit_global();

    try FreeTypeContext.init_global(allocator);
    defer FreeTypeContext.deinit_global();

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

test {
    std.testing.refAllDecls(@This());

    std.testing.refAllDecls(FreeTypeContext);
    std.testing.refAllDecls(WaylandContext);
    std.testing.refAllDecls(DrawContext);
    std.testing.refAllDecls(Config);
}

const WaylandContext = @import("WaylandContext.zig");
const DrawContext = @import("DrawContext.zig");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Config = @import("Config.zig");

const FreeTypeContext = @import("FreeTypeContext.zig");

const std = @import("std");

const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"walrus-bar");
const maxInt = std.math.maxInt;
