pub const DefaultOutputArraySize: usize = 2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = false, // we should only ever use it on the main (wayland) thread.
    }){};
    defer _ = gpa.deinit();
    var logging_allocator = std.heap.LoggingAllocator(.debug, .warn).init(gpa.allocator());
    const allocator = logging_allocator.allocator();

    try Config.init_global(allocator);
    defer Config.deinit_global();

    // don't use logging allocator as you can enable it separately.
    try FreeTypeContext.init_global(gpa.allocator());
    defer FreeTypeContext.global.deinit();

    // start wayland connection.
    const display = try wl.Display.connect(null);
    var registry = try display.getRegistry();

    // initialize the app's context.
    var wayland_context = WaylandContext{
        .display = display,
        .registry = registry,
        .allocator = allocator,

        .outputs = try WaylandContext.OutputsArray.initCapacity(allocator, DefaultOutputArraySize),
    };
    defer wayland_context.deinit();

    // set registry to set values in wayland_context
    registry.setListener(*WaylandContext, WaylandContext.registryListener, &wayland_context);

    // populate initial registry
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (wayland_context.running) {
        // dispatch and handle all messages to and fro.
        switch (display.dispatch()) {
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

    std.testing.refAllDecls(@import("Workspaces/Workspaces.zig"));
    std.testing.refAllDecls(@import("Workspaces/hyprland.zig"));
    std.testing.refAllDecls(@import("Workspaces/testing.zig"));
    std.testing.refAllDecls(@import("Workspaces/none.zig"));
    std.testing.refAllDecls(@import("TextBox.zig"));
    std.testing.refAllDecls(@import("Battery.zig"));
    std.testing.refAllDecls(@import("Clock.zig"));
    std.testing.refAllDecls(FreeTypeContext);
    std.testing.refAllDecls(WaylandContext);
    std.testing.refAllDecls(DrawContext);
    std.testing.refAllDecls(Config);
}

// build options
const bo = @import("options");
pub const std_options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        // TODO: Find a good way to automate this...
        // Workspaces
        .{
            .scope = .Workspaces,
            .level = if (bo.workspaces_verbose) .debug else .info,
        },
        .{
            .scope = .WorkspacesWorker,
            .level = if (bo.workspaces_verbose) .debug else .info,
        },
        // Battery
        .{
            .scope = .Battery,
            .level = if (bo.battery_verbose) .debug else .info,
        },
        // Clock
        .{
            .scope = .Clock,
            .level = if (bo.clock_verbose) .debug else .info,
        },
    },
};

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
