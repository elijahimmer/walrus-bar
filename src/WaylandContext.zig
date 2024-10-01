pub const WaylandContext = @This();
pub var global: WaylandContext = undefined;

pub const OutputsArray = SegmentedList(OutputContext, 4);
pub const DrawingContextsArray = MultiArrayList(DrawingContext);

allocator: Allocator,
running: bool = true,

outputs: OutputsArray = .{},
drawing_contexts: DrawingContextsArray = .{},

display: *wl.Display,

compositor: ?*wl.Compositor = null,
compositor_serial: u32 = undefined,

shm: ?*wl.Shm = null,
shm_serial: u32 = undefined,

layer_shell: ?*zwlr.LayerShellV1 = null,
layer_shell_serial: u32 = undefined,

pub fn init(allocator: Allocator, display: *wl.Display) Allocator.Error!@This() {
    return .{
        .allocator = allocator,
        .outputs = .{},
        .drawing_contexts = .{},
        .display = display,
    };
}

pub fn deinit(self: *@This()) void {
    var outputs_iter = self.outputs.iterator(0);
    while (outputs_iter.next()) |output| if (output.is_alive) output.deinit();
    self.outputs.deinit(self.allocator);
    self.drawing_contexts.deinit(self.allocator);

    if (self.compositor) |compositor| compositor.destroy();
    if (self.shm) |shm| shm.destroy();
    if (self.layer_shell) |layer_shell| layer_shell.destroy();
}

const OutputContext = @import("OutputContext.zig");
const DrawingContext = @import("DrawingContext.zig");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const Allocator = std.mem.Allocator;
const SegmentedList = std.SegmentedList;
const MultiArrayList = std.MultiArrayList;
