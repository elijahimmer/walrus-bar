//! A shared memory pool for a specific surface.
//! This is double buffered.

pub const ShmPool = @This();

pub const NUMBER_OF_BUFFERS = 2;

/// the shared memory pool for output's display
pool: *wl.ShmPool,

/// the filed descriptor for the shm pool.
fd: posix.fd_t,

/// Wayland only supports 'i32's as buffer sizes, so
/// this uses a u31 to have the same range, with no negatives.
mapped_memory_len: u31,

/// the entire mmap'ed area's buffer.
total_buffer: []align(mem.page_size) u8,

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

/// initializes the shm pool. Caller takes ownership and must `deinit` it when done.
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
    assert(buffer_1_buffer.len == @as(u31, @intCast(width)) * height);

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
        .mapped_memory_len = @intCast(total_buffer.len),

        .buffer_1 = buffer_1,
        .buffer_1_buffer = buffer_1_buffer,
        .buffer_1_free = true,
        .buffer_2 = buffer_2,
        .buffer_2_buffer = buffer_2_buffer,
        .buffer_2_free = true,
    };
}

/// 80% used should still be fine.
inline fn resizeInternalShrinkSizeThreshold(total_buffer_size: u31, mapped_memory_len: u31) bool {
    return total_buffer_size >= mapped_memory_len * 8 / 10;
}

const ResizeInternalMakeNewBufferResult = struct {
    pool: *wl.ShmPool,
    total_buffer: []align(mem.page_size) u8,
    mapped_memory_len: u31,
};

fn resizeInternalMakeNewBuffer(shm_pool: *ShmPool, wayland_context: *WaylandContext, total_buffer_size: u31, mmap_count: *u16) !ResizeInternalMakeNewBufferResult {
    const buffer_order = std.math.order(total_buffer_size, shm_pool.total_buffer.len);

    assert(mmap_count.* == 1);
    defer assert(mmap_count.* == 1 or (mmap_count.* == 2 and buffer_order == .lt));

    switch (buffer_order) {
        // if the size is equal, nothing to do.
        .eq => unreachable,
        .gt => {
            const mapped_memory_order = std.math.order(total_buffer_size, shm_pool.mapped_memory_len);

            switch (mapped_memory_order) {
                // just continue, this is the normal case.
                .gt => {},
                // the memory expanded, but we still have some available space, just use that.
                .eq, .lt => {
                    log.info("Resizing up, keeping pool size!", .{});
                    var total_buffer = shm_pool.total_buffer;
                    // should be save given we have then entire space up to shm_pool.mapped_memory_len.
                    total_buffer.len = total_buffer_size;

                    return .{
                        .pool = shm_pool.pool,
                        .total_buffer = total_buffer,
                        .mapped_memory_len = shm_pool.mapped_memory_len,
                    };
                },
            }

            log.info("Resizing up, increasing pool!", .{});

            // TODO: don't change backing file until all of the shm_pool buffers to free and destroyed...
            // update mem file size
            posix.ftruncate(shm_pool.fd, total_buffer_size) catch |err| {
                log.warn("Failed to resize memory file with error {s}", .{@errorName(err)});
                return err;
            };
            // shorten the file back down on error.
            errdefer posix.ftruncate(shm_pool.fd, shm_pool.total_buffer.len) catch |err| {
                log.warn("Failed to shorten memory file to it's former length after error, with error {s}.", .{@errorName(err)});
            };

            // increase it now as we did increase the mapped memory.
            shm_pool.mapped_memory_len = total_buffer_size;

            // re-mmap the new buffer for the new size.
            const total_buffer = posix.mmap(
                null,
                total_buffer_size,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                shm_pool.fd,
                0,
            ) catch |err| {
                log.warn("Failed to reallocate shm pool's buffer during resize with error {s}", .{@errorName(err)});
                return err;
            };
            assert(mmap_count.* == 1);

            // remove the old buffer and resize the pool.
            posix.munmap(shm_pool.total_buffer);
            shm_pool.pool.resize(total_buffer_size);

            return .{
                .pool = shm_pool.pool,
                .total_buffer = total_buffer,
                .mapped_memory_len = @intCast(total_buffer.len),
            };
        },
        .lt => {
            assert(total_buffer_size <= shm_pool.mapped_memory_len);

            // if the buffer is only a little smaller, don't allocate a new one.
            if (resizeInternalShrinkSizeThreshold(total_buffer_size, shm_pool.mapped_memory_len)) {
                log.debug("Resizing down, keeping pool!", .{});
                return .{
                    .pool = shm_pool.pool,
                    .total_buffer = shm_pool.total_buffer[0..total_buffer_size],
                    .mapped_memory_len = shm_pool.mapped_memory_len,
                };
            }
            log.debug("Resizing down!", .{});

            posix.ftruncate(shm_pool.fd, total_buffer_size) catch |err| {
                log.warn("Failed to resize memory file with error {s}", .{@errorName(err)});
                return err;
            };
            // shorten the file back down on error.
            errdefer posix.ftruncate(shm_pool.fd, shm_pool.total_buffer.len) catch |err| {
                log.warn("Failed to shorten memory file to it's former length after error, with error {s}.", .{@errorName(err)});
            };

            const pool = wayland_context.shm.?.createPool(shm_pool.fd, total_buffer_size) catch |err| {
                log.warn("Failed to create new memory pool while resizing existing with error: {s}", .{@errorName(err)});
                return err;
            };

            assert(mmap_count.* == 1);
            const total_buffer = posix.mmap(
                null,
                total_buffer_size,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                shm_pool.fd,
                0,
            ) catch |err| {
                log.warn("Failed to reallocate shm pool's buffer during resize with error {s}", .{@errorName(err)});
                return err;
            };
            mmap_count.* += 1;

            return .{
                .pool = pool,
                .total_buffer = total_buffer,
                .mapped_memory_len = @intCast(total_buffer.len),
            };
        },
    }
}

fn resizeInternalFixNewBuffersOnError(shm_pool: *ShmPool, total_buffer_size: u31, args: ResizeInternalMakeNewBufferResult, mmap_count: *u16) void {
    const buffer_order = std.math.order(total_buffer_size, shm_pool.total_buffer.len);

    assert(mmap_count.* == 1 or (mmap_count.* == 2 and buffer_order == .lt));
    defer assert(mmap_count.* == 1);

    switch (buffer_order) {
        .eq => unreachable,
        // When the buffer was increased, we will take a small memory
        // leakage if it failed to successfully make the new buffers.
        // What else can re really do?
        .gt => {},
        .lt => {
            // when only a small buffer size change, just ignore the
            if (resizeInternalShrinkSizeThreshold(total_buffer_size, shm_pool.mapped_memory_len)) return;

            args.pool.destroy();

            posix.munmap(args.total_buffer);
            mmap_count.* -= 1;

            posix.ftruncate(shm_pool.fd, shm_pool.mapped_memory_len) catch |err| {
                log.warn("Failed to yep memory file to it's former length after error, with error {s}.", .{@errorName(err)});
            };
        },
    }
}

/// Resize the memory pool to hold displays of size `size`
/// The memory pool is still in a valid state if an error happens, the resize just don't happen.
///
/// If a resize would make the pool larger, it is still larger after the call, but it is
///     still valid as the buffers are not updated.
///
pub fn resize(shm_pool: *ShmPool, wayland_context: *WaylandContext, size: Point) !void {
    assert(wayland_context.shm != null);

    var mmap_count: u16 = 1;

    assert(mmap_count == 1);
    defer assert(mmap_count == 1);

    const fd = shm_pool.fd;

    const width: u31 = size.x;
    const height: u31 = size.y;
    const stride = width * @sizeOf(Color);

    const buffer_size = stride * @as(u31, height);
    const total_buffer_size = buffer_size * NUMBER_OF_BUFFERS;

    // if no resize needed, just return.
    if (total_buffer_size == shm_pool.total_buffer.len) return;

    const new_buffers_result = try shm_pool.resizeInternalMakeNewBuffer(wayland_context, total_buffer_size, &mmap_count);
    errdefer shm_pool.resizeInternalFixNewBuffersOnError(total_buffer_size, new_buffers_result, &mmap_count);

    assert(mmap_count == 1 or mmap_count == 2);

    const total_buffer = new_buffers_result.total_buffer;
    const pool = new_buffers_result.pool;
    const mapped_memory_len = new_buffers_result.mapped_memory_len;

    if (std.debug.runtime_safety) {
        // make sure the entire total_buffer is valid memory to use.
        var counter: usize = 0;
        for (total_buffer) |byte| {
            counter +%= byte;
            mem.doNotOptimizeAway(byte);
        }
        mem.doNotOptimizeAway(counter);
    }

    assert(total_buffer.len == total_buffer_size);

    // start first buffer at 0.
    const buffer_1 = pool.createBuffer(0, width, height, stride, Color.FORMAT) catch |err| {
        log.warn("Failed to create new buffer on memory pool resize with error {s}", .{@errorName(err)});
        return err;
    };
    errdefer buffer_1.destroy();

    // start second buffer after first.
    const buffer_2 = pool.createBuffer(buffer_size, width, height, stride, Color.FORMAT) catch |err| {
        log.warn("Failed to create new buffer on memory pool resize with error {s}", .{@errorName(err)});
        return err;
    };
    errdefer buffer_2.destroy();

    // make sure the buffer is correct.
    const buffer_1_buffer = u8ToColorBuffer(total_buffer[0..buffer_size]);
    assert(buffer_1_buffer.len == @as(u31, width) * height);

    // set new listener
    buffer_1.setListener(*WaylandContext, bufferListener, wayland_context);

    // make sure the buffer is correct.
    const buffer_2_buffer = u8ToColorBuffer(total_buffer[buffer_size..]);
    assert(buffer_2_buffer.len == buffer_1_buffer.len);

    // set listener
    buffer_2.setListener(*WaylandContext, bufferListener, wayland_context);

    // Only destroy at the end, so we don't cause an invalid state.
    // if we can destroy the old buffers, do so, otherwise the listener will.
    if (shm_pool.buffer_1_free) shm_pool.buffer_1.destroy();
    if (shm_pool.buffer_2_free) shm_pool.buffer_2.destroy();

    if (shm_pool.pool != pool) shm_pool.pool.destroy();

    assert(mmap_count == 1 or mmap_count == 2);
    if (shm_pool.total_buffer.ptr != total_buffer.ptr and total_buffer_size < shm_pool.total_buffer.len) {
        assert(mmap_count == 2);

        posix.munmap(shm_pool.total_buffer);
        mmap_count -= 1;
    }
    assert(mmap_count == 1);

    // changed the entire thing at once, so the state is not invalid
    // before everything has successed.
    shm_pool.* = .{
        .pool = pool,
        .fd = fd,

        .total_buffer = total_buffer,
        .mapped_memory_len = mapped_memory_len,

        .buffer_1 = buffer_1,
        .buffer_1_buffer = buffer_1_buffer,
        .buffer_1_free = true,
        .buffer_2 = buffer_2,
        .buffer_2_buffer = buffer_2_buffer,
        .buffer_2_free = true,
    };
}

/// Converts a u8 buffer to a color buffer.
/// Asserts the buffer is divisible by the size of Color
pub fn u8ToColorBuffer(buffer: []u8) []Color {
    assert(buffer.len % @sizeOf(Color) == 0);

    var ret: []Color = undefined;
    ret.ptr = @alignCast(@ptrCast(buffer.ptr));
    ret.len = @divExact(buffer.len, @sizeOf(Color));

    return ret;
}

/// Caller does *not* have ownership of buffer, do not destroy it.
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

    shm.* = undefined;
}

pub fn bufferListener(buffer: *wl.Buffer, event: wl.Buffer.Event, wayland_context: *WaylandContext) void {
    assert(wayland_context.shm != null);

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
const mem = std.mem;

const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
const Tuple = std.meta.Tuple;

const runtime_safety = std.debug.runtime_safety;
const assert = std.debug.assert;

const log = std.log.scoped(.ShmPool);
