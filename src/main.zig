pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = false, // we should only ever use it on the main (wayland) thread.
    }){};
    defer _ = gpa.deinit();
    var logging_allocator = std.heap.ScopedLoggingAllocator(.Allocations, .debug, .warn).init(gpa.allocator());
    const allocator = logging_allocator.allocator();

    try Config.init_global(allocator);
    defer Config.deinit_global();

    // don't use logging allocator as you can enable it separately.
    try FreeTypeContext.init_global(gpa.allocator());
    defer FreeTypeContext.global.deinit();

    // initialize the app's context.
    var wayland_context: WaylandContext = undefined;

    try WaylandContext.init(&wayland_context, allocator);
    defer wayland_context.deinit();

    while (wayland_context.running) {
        // dispatch and handle all messages to and fro.
        switch (wayland_context.display.dispatch()) {
            .SUCCESS => {},
            .INVAL => {
                // we sent a invalid response (which is a bug) and should just stop
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

    std.testing.refAllDecls(@import("workspaces/Workspaces.zig"));
    std.testing.refAllDecls(@import("workspaces/hyprland.zig"));
    std.testing.refAllDecls(@import("workspaces/testing.zig"));
    std.testing.refAllDecls(@import("workspaces/none.zig"));
    std.testing.refAllDecls(@import("RootContainer.zig"));
    std.testing.refAllDecls(@import("Brightness.zig"));
    std.testing.refAllDecls(@import("TextBox.zig"));
    std.testing.refAllDecls(@import("Battery.zig"));
    std.testing.refAllDecls(@import("Clock.zig"));
    std.testing.refAllDecls(FreeTypeContext);
    std.testing.refAllDecls(WaylandContext);
    std.testing.refAllDecls(DrawContext);
    std.testing.refAllDecls(Config);
}

pub const std_options = .{
    .logFn = logging.logFn,
    .log_scope_levels = &logging.logging_scope_levels,
};

const WaylandContext = @import("WaylandContext.zig");
const DrawContext = @import("DrawContext.zig");

const wayland = @import("wayland");
const wl = wayland.client.wl;

const Config = @import("Config.zig");

const FreeTypeContext = @import("FreeTypeContext.zig");

const logging = @import("logging.zig");

const std = @import("std");

const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const panic = std.debug.panic;

const log = std.log.scoped(.@"walrus-bar");
