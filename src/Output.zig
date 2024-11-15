//! The storage for everything related to a single output.
//! Holds all the wayland objects for the output. (like the surfaces)

pub const Output = @This();

output_context: OutputContext,
root_container: ?RootContainer = null,

full_redraw: bool = true,

/// the main wayland surface.
surface: ?*wl.Surface = null,
/// the shared memory pool for output's display
shm_pool: ?*wl.ShmPool = null,

pub fn init(args: OutputContext.InitArgs) Output {
    return Output{
        .output_context = OutputContext.init(args),
    };
}

pub fn deinit(self: *Output) void {
    self.output_context.deinit();
    if (self.root_container) |*rc| rc.deinit();
    self.* = undefined;
}

test {
    std.testing.refAllDecls(@This());
}

const options = @import("options");

const Config = @import("Config.zig");
const config = &Config.global;

const colors = @import("colors.zig");

const DrawContext = @import("DrawContext.zig");
const OutputContext = @import("OutputContext.zig");
const WaylandContext = @import("WaylandContext.zig");
const RootContainer = @import("RootContainer.zig");

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

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const assert = std.debug.assert;

const log = std.log.scoped(.Output);
