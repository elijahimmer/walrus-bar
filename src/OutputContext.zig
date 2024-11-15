pub const OutputContext = @This();

pub const NAME_STR_LEN = 16;

output: *wl.Output,
output_name: u32,

/// whether or not the output mode event has been handled
has_mode: bool = false,
/// Only valid when `has_mode` is true.
screen_height: Size = undefined,
/// Only valid when `has_mode` is true.
screen_width: Size = undefined,

/// whether or not the output geometry event has been handled
has_geometry: bool = false,
/// Only valid when `has_geometry` is true.
physical_height: Size = undefined,
/// Only valid when `has_geometry` is true.
physical_width: Size = undefined,

/// whether or not the output name event has been handled
has_name: bool = false,
/// Holds the output name as a string, any characters after 64 will be ignored.
/// Only valid when `has_name` is true.
name_str: BoundedArray(u8, NAME_STR_LEN) = .{},

/// whether or not the output has changed since last
changed: bool = true,

pub const InitArgs = struct {
    output: *wl.Output,
    output_name: u32,
    wayland_context: *WaylandContext,
};

pub fn init(args: InitArgs) OutputContext {
    args.output.setListener(*WaylandContext, outputListener, args.wayland_context);

    return .{
        .output = args.output,
        .output_name = args.output_name,
    };
}

pub fn deinit(self: *OutputContext) void {
    self.output.destroy();
}

//const InitializeShmError = posix.MMapError || posix.MemFdCreateError || posix.TruncateError;
//fn initializeShm(output_context: *OutputContext, wayland_context: *WaylandContext) InitializeShmError!void {
//    assert(wayland_context.shm != null);
//
//    const width = config.general.width orelse draw_context.output_context.width;
//    const height = config.general.height;
//    const stride = @as(u31, width) * @sizeOf(Color);
//
//    const size: u31 = stride * @as(u31, height);
//    const fd = try posix.memfd_createZ(constants.WAYLAND_NAMESPACE, 0);
//    draw_context.shm_fd = fd;
//    try posix.ftruncate(fd, size);
//    const screen = try posix.mmap(
//        null,
//        size,
//        posix.PROT.READ | posix.PROT.WRITE,
//        .{ .TYPE = .SHARED },
//        fd,
//        0,
//    );
//
//    var screen_adjusted: []Color = undefined;
//    screen_adjusted.ptr = @ptrCast(screen.ptr);
//    screen_adjusted.len = @as(usize, height) * width;
//    assert(screen_adjusted.len * @sizeOf(Color) == screen.len);
//
//    draw_context.screen = screen_adjusted;
//
//    const shm_pool = try wayland_context.shm.?.createPool(fd, size);
//
//    draw_context.shm_buffer = try shm_pool.createBuffer(0, width, height, stride, Color.FORMAT);
//}

pub fn outputListener(output: *wl.Output, event: wl.Output.Event, wayland_context: *WaylandContext) void {
    const output_checker = struct {
        pub fn checker(output_maybe: *const Output, target: *wl.Output) bool {
            return output_maybe.output_context.output == target;
        }
    }.checker;

    const output_idx = wayland_context.findOutput(*wl.Output, output, output_checker) orelse @panic("Output not found!");

    var root_container = &wayland_context.outputs.items[output_idx];
    var output_context = &root_container.output_context;

    if (output_context.has_name) {
        log.debug("Output '{s}' (id #{}) had event {s}", .{ output_context.name_str, output_context.output_name, @tagName(event) });
    } else {
        log.debug("Output id #{} had event {s}", .{ output_context.output_name, @tagName(event) });
    }

    switch (event) {
        .geometry => |geometry| {
            assert(geometry.physical_width >= 0);
            assert(geometry.physical_height >= 0);
            defer assert(output_context.physical_width >= 0);
            defer assert(output_context.physical_height >= 0);

            output_context.changed = output_context.changed or output_context.physical_height != geometry.physical_height or output_context.physical_width != geometry.physical_width;

            output_context.physical_height = @intCast(geometry.physical_height);
            output_context.physical_width = @intCast(geometry.physical_width);
            output_context.has_geometry = true;
        },
        .mode => |mode| {
            assert(mode.width >= 0);
            assert(mode.height >= 0);
            defer assert(output_context.screen_width >= 0);
            defer assert(output_context.screen_height >= 0);

            output_context.changed = output_context.changed or output_context.screen_height != mode.height or output_context.screen_width != mode.width;

            output_context.screen_height = @intCast(mode.height);
            output_context.screen_width = @intCast(mode.width);
            output_context.has_mode = true;
        },
        .name => |name| {
            assert(!output_context.has_name); // protocol says name can only be set one.
            assert(output_context.name_str.len == 0);
            output_context.has_name = true;

            const name_str = mem.span(name.name);
            assert(name_str.len > 0);

            const name_str_len = @min(name_str.len, output_context.name_str.capacity());

            output_context.name_str.appendSliceAssumeCapacity(name_str[0..name_str_len]);
        },
        .scale, .description => {},
        .done => {
            assert(output_context.has_geometry);
            assert(output_context.has_name);
            assert(output_context.has_mode);

            if (output_context.screen_height > 0 and output_context.screen_width > 0) {
                if (output_context.changed) {
                    log.info("Output '{s}' changed, valid height.", .{output_context.name_str.constSlice()});
                    //output_context.outputChanged(wayland_context) catch |err| panic("error: {s}", .{@errorName(err)});
                }
            } else {
                if (output_context.changed) {
                    log.info("Output '{s}' changed, zero size.", .{output_context.name_str.constSlice()});
                    // TODO: shouldn't render (zero size)-- make sure it doesn't.
                }
            }

            output_context.changed = false;
        },
    }
}

const Output = @import("Output.zig");
const WaylandContext = @import("WaylandContext.zig");

const drawing = @import("drawing.zig");
const Size = drawing.Size;

const Color = @import("colors.zig").Color;

const Screen = @import("drawing.zig").Screen;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const posix = std.posix;
const mem = std.mem;

const assert = std.debug.assert;
const panic = std.debug.panic;

const BoundedArray = std.BoundedArray;
const SafetyLock = std.debug.SafetyLock;

const log = std.log.scoped(.OutputContext);
