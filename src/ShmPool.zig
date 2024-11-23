//! A shared memory pool for a specific surface.
//! This is double buffered.

pub const ShmPool = @This();

pub const NUMBER_OF_BUFFERS = 2;

/// the shared memory pool for output's display
pool: *wl.ShmPool,

/// the filed descriptor for the shm pool.
fd: posix.fd_t,

/// the entire mmap'ed area's buffer.
total_buffer: []align(std.mem.page_size) u8,

/// The first of two buffers to use. This one is prioritised.
buffer_1: *wl.Buffer,
/// When true, the first buffer is free to use.
buffer_1_free: bool,
/// The actual color buffer for this buffer.
buffer_1_buffer: []Color,

/// The second of two buffers to use
buffer_2: *wl.Buffer,
/// When true, the second buffer is free to use.
buffer_2_free: bool,
/// The actual color buffer for this buffer.
buffer_2_buffer: []Color,

pub const InitError = posix.MMapError || posix.MemFdCreateError || posix.TruncateError;
pub const InitArgs = struct {
    wayland_context: *WaylandContext,
    height: Size,
    width: Size,
};

pub fn init(args: InitArgs) !ShmPool {
    assert(args.wayland_context.shm != null);
    assert(args.wayland_context.has_argb8888);

    const width = args.width;
    const height = args.height;
    const stride = @as(u31, width) * @sizeOf(Color);

    const size: u31 = stride * @as(u31, height);

    const fd = posix.memfd_createZ(
        constants.WAYLAND_NAMESPACE,
        std.os.linux.MFD.HUGE_1MB | std.os.linux.MFD.CLOEXEC,
    ) catch |err| switch (err) {
        // not actually name too long, but it permission denied,
        //  which likely means we cannot use huge pages.
        error.NameTooLong => try posix.memfd_createZ(
            constants.WAYLAND_NAMESPACE,
            std.os.linux.MFD.CLOEXEC,
        ),
        else => return err,
    };
    errdefer posix.close(fd);

    try posix.ftruncate(fd, size * NUMBER_OF_BUFFERS);

    const total_buffer = try posix.mmap(
        null,
        size * NUMBER_OF_BUFFERS,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer posix.munmap(total_buffer);

    const shm_pool = try args.wayland_context.shm.?.createPool(fd, size);
    errdefer shm_pool.destroy();

    // start first buffer at 0.
    const buffer_1 = try shm_pool.createBuffer(0, width, height, stride, Color.FORMAT);
    errdefer buffer_1.destroy();

    const buffer_1_buffer = u8ToColorBuffer(total_buffer[0..size]);
    assert(buffer_1_buffer.len == @as(usize, @intCast(width)) * height);

    buffer_1.setListener(*WaylandContext, bufferListener, args.wayland_context);

    // start second buffer after first.
    const buffer_2 = try shm_pool.createBuffer(size, width, height, stride, Color.FORMAT);
    errdefer buffer_2.destroy();

    const buffer_2_buffer = u8ToColorBuffer(total_buffer[size..]);
    assert(buffer_2_buffer.len == buffer_1_buffer.len);

    buffer_2.setListener(*WaylandContext, bufferListener, args.wayland_context);

    return .{
        .pool = shm_pool,
        .fd = fd,

        .total_buffer = total_buffer,

        .buffer_1 = buffer_1,
        .buffer_1_buffer = buffer_1_buffer,
        .buffer_1_free = true,
        .buffer_2 = buffer_2,
        .buffer_2_buffer = buffer_2_buffer,
        .buffer_2_free = true,
    };
}

/// Resize the memory pool to hold displays of size `size`
pub fn resize(shm_pool: *ShmPool, wayland_context: *WaylandContext, size: Point) !void {
    const width: u31 = size.x;
    const height: u31 = size.y;
    const stride = width * @sizeOf(Color);

    const buffer_size = stride * @as(u31, height);
    const total_buffer_size = buffer_size * NUMBER_OF_BUFFERS;

    switch (std.math.order(total_buffer_size, shm_pool.total_buffer.len)) {
        // if the size is equal, nothing to do.
        .eq => return,
        .gt => {
            shm_pool.pool.resize(buffer_size);
        },
        .lt => {
            const pool = try wayland_context.shm.?.createPool(shm_pool.fd, buffer_size);
            // set after so if it fails to make the pool, don't mess up.
            shm_pool.pool.destroy();
            shm_pool.pool = pool;
        },
    }

    const fd = shm_pool.fd;
    const pool = shm_pool.pool;

    // TODO: don't change backing file until all of the shm_pool buffers to free and destroyed...
    // update mem file size
    try posix.ftruncate(fd, total_buffer_size);

    // re-mmap the new buffer for the new size.
    const total_buffer = try posix.mmap(
        null,
        total_buffer_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer posix.munmap(total_buffer);
    assert(total_buffer.len == total_buffer_size);

    // start first buffer at 0.
    const buffer_1 = try pool.createBuffer(0, width, height, stride, Color.FORMAT);
    errdefer buffer_1.destroy();

    // make sure the buffer is correct.
    const buffer_1_buffer = u8ToColorBuffer(total_buffer[0..buffer_size]);
    assert(buffer_1_buffer.len == @as(usize, width) * height);

    // set new listener
    buffer_1.setListener(*WaylandContext, bufferListener, wayland_context);

    // start second buffer after first.
    const buffer_2 = try pool.createBuffer(buffer_size, width, height, stride, Color.FORMAT);
    errdefer buffer_2.destroy();

    // make sure the buffer is correct.
    const buffer_2_buffer = u8ToColorBuffer(total_buffer[buffer_size..]);
    assert(buffer_2_buffer.len == buffer_1_buffer.len);

    // set listener
    buffer_2.setListener(*WaylandContext, bufferListener, wayland_context);

    // deinit the rest at the end, so if it does wrong we are not
    // in an invalid state.

    // destroy old mmap to buffer.
    posix.munmap(shm_pool.total_buffer);
    // if we can destroy the old buffers, do so, otherwise the listener will.
    if (shm_pool.buffer_1_free) shm_pool.buffer_1.destroy();
    if (shm_pool.buffer_2_free) shm_pool.buffer_2.destroy();

    shm_pool.* = .{
        .pool = pool,
        .fd = fd,

        .total_buffer = total_buffer,

        .buffer_1 = buffer_1,
        .buffer_1_buffer = buffer_1_buffer,
        .buffer_1_free = true,
        .buffer_2 = buffer_2,
        .buffer_2_buffer = buffer_2_buffer,
        .buffer_2_free = true,
    };
}

pub fn u8ToColorBuffer(buffer: []u8) []Color {
    assert(buffer.len % @sizeOf(Color) == 0);

    var ret: []Color = undefined;
    ret.ptr = @alignCast(@ptrCast(buffer.ptr));
    ret.len = @divExact(buffer.len, @sizeOf(Color));

    return ret;
}

/// Caller takes ownership and must call destroy on returned buffer after use.
/// Returns null if no buffers are available (so just don't draw.)
pub fn getBuffer(shm: *ShmPool) ?Tuple(&[_]type{ *wl.Buffer, []Color }) {
    const ret = ret: {
        if (shm.buffer_1_free) {
            shm.buffer_1_free = false;

            break :ret .{ shm.buffer_1, shm.buffer_1_buffer };
        } else if (shm.buffer_2_free) {
            shm.buffer_2_free = false;
            break :ret .{ shm.buffer_2, shm.buffer_2_buffer };
        } else {
            // no buffers available.
            return null;
        }
    };

    // TODO: Re add this when the damage is working properly.
    //if (std.debug.runtime_safety) @memset(shm.buffer_1_buffer, colors.red);

    return ret;
}

pub fn deinit(shm: *ShmPool) void {
    shm.buffer_1.destroy();
    shm.buffer_2.destroy();

    shm.pool.destroy();

    posix.close(shm.fd);
    posix.munmap(shm.total_buffer);
}

pub fn bufferListener(buffer: *wl.Buffer, event: wl.Buffer.Event, wayland_context: *WaylandContext) void {
    const output_checker = struct {
        pub fn checker(output: *const Output, target: *wl.Buffer) bool {
            if (output.shm_pool == null) return false;

            const buffer_1 = output.shm_pool.?.buffer_1 == target;
            const buffer_2 = output.shm_pool.?.buffer_2 == target;

            return buffer_1 or buffer_2;
        }
    }.checker;

    switch (event) {
        .release => {
            const output = wayland_context.findOutput(
                *wl.Buffer,
                buffer,
                &output_checker,
            ) orelse {
                // stranded buffer that just wasn't destroyed because it was in use.
                // So, destroy it.
                buffer.destroy();
                return;
            };
            assert(output.shm_pool != null);

            const shm_pool = &output.shm_pool.?;

            if (shm_pool.buffer_1 == buffer) {
                shm_pool.buffer_1_free = true;
            } else {
                assert(shm_pool.buffer_2 == buffer);
                shm_pool.buffer_2_free = true;
            }
        },
    }
}

const options = @import("options");
const constants = @import("constants.zig");

const Config = @import("Config.zig");
const config = &Config.global;

const colors = @import("colors.zig");
const Color = colors.Color;

const Output = @import("Output.zig");
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

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const posix = std.posix;

const Tuple = std.meta.Tuple;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const assert = std.debug.assert;

const log = std.log.scoped(.ShmPool);
