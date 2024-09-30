pub fn Vector(T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

pub fn Box(T: type) type {
    return struct {
        x: T,
        y: T,
        width: T,
        height: T,

        pub fn origin(self: @This()) Vector(T) {
            return .{
                .x = self.x,
                .y = self.y,
            };
        }

        pub fn size(self: @This()) Vector(T) {
            return .{
                .x = self.width,
                .y = self.height,
            };
        }
    };
}

pub const Screen = struct {
    screen: []align(mem.page_size) Color,
    fd: posix.fd_t,
    width: u31,
    height: u31,

    pub fn init(size: Vector(u31)) !@This() {
        const width, const height = .{ size.x, size.y };
        const stride: u31 = @as(u31, width) * @sizeOf(Color);

        const fd = try posix.memfd_create("walrus-bar", 0);
        try posix.ftruncate(fd, stride * height);
        const screen = try posix.mmap(
            null,
            stride * height,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        // convert it from a u8 array into a color array
        var screen_adjusted: []align(mem.page_size) Color = undefined;
        screen_adjusted.ptr = @ptrCast(screen.ptr);
        screen_adjusted.len = @divExact(screen.len, @sizeOf(Color));

        return .{
            .screen = screen_adjusted,
            .fd = fd,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *const Screen) void {
        var screen_unadjusted: []align(mem.page_size) u8 = undefined;
        screen_unadjusted.ptr = @ptrCast(self.screen.ptr);
        screen_unadjusted.len = self.screen.len * @sizeOf(Color);

        posix.munmap(screen_unadjusted);
        posix.close(self.fd);
    }

    pub fn put_pixel(self: *const Screen, vec: Vector(u31), color: Color) void {
        assert(vec.x < self.width);
        assert(vec.y < self.height);

        self.screen[vec.y * self.width + vec.x] = color;
    }

    pub fn fill_box(self: *const Screen, box: Box(u31), color: Color) void {
        assert(box.width > 0);
        assert(box.height > 0);
        assert(box.x < self.width);
        assert(box.y < self.height);
        assert(box.x + box.width <= self.width);
        assert(box.y + box.height <= self.height);

        for (box.y..box.y + box.height) |y| {
            for (box.x..box.x + box.width) |x| {
                self.screen[y * self.width + x] = color;
            }
        }
    }
};

test Screen {
    for (1..10) |height| {
        for (1..10) |width| {
            const screen = try Screen.init(.{ .x = @intCast(width), .y = @intCast(height) });
            defer screen.deinit();

            screen.fill_box(.{ .x = 0, .y = 0, .width = @intCast(width), .height = @intCast(height) }, colors.rose);

            for (screen.screen) |color| try std.testing.expectEqual(color, colors.rose);
        }
    }
}

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");
const posix = std.posix;
const mem = std.mem;

const log = std.log.scoped(.drawing);
const assert = std.debug.assert;
