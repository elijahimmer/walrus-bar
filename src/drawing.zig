pub const Point = struct {
    x: u31,
    y: u31,

    pub fn extendTo(self: Point, other: Point) Rect {
        const x_min, const x_max = .{ @min(self.x, other.x), @max(self.x, other.x) };
        const y_min, const y_max = .{ @min(self.y, other.y), @max(self.y, other.y) };

        return .{
            .x = x_min,
            .y = y_min,
            .width = x_max - x_min,
            .height = y_max - y_min,
        };
    }
};

pub const Rect = struct {
    x: u31,
    y: u31,
    width: u31,
    height: u31,

    pub fn fill(self: Rect, draw_context: *const DrawContext, color: Color) void {
        assert(draw_context.window_rect.width >= self.x + self.width);
        assert(draw_context.window_rect.height >= self.y + self.height);

        for (self.y..self.y + self.height) |y_coord| {
            const row = draw_context.screen[y_coord * draw_context.window_width ..][0..draw_context.window_width];

            @memset(row, color);
        }
    }

    pub fn assertContains(self: Rect, inner: Rect) void {
        assert(self.x <= inner.x);
        assert(self.y <= inner.y);
        assert(self.width >= inner.width);
        assert(self.height >= inner.height);
        assert(self.x + self.width >= inner.x + inner.width);
        assert(self.y + self.height >= inner.y + inner.height);
    }

    pub fn assertContainsPoint(self: Rect, point: Point) void {
        assert(self.x <= point.x);
        assert(self.y <= point.y);
        assert(self.x + self.width >= point.x);
        assert(self.y + self.height >= point.y);
    }

    /// Returns a intersecting rectangle. Asserts they actually intersect.
    pub fn intersection(self: Rect, other: Rect) Rect {
        const x_start = @max(self.x, other.x);
        const y_start = @max(self.y, other.y);
        const x_end = @min(self.x + self.width, other.x + other.width);
        const y_end = @min(self.y + self.height, other.y + other.height);

        assert(x_start <= x_end); // make sure they actually intersect
        assert(y_start <= y_end); // make sure they actually intersect

        return .{
            .x = x_start,
            .y = y_start,
            .width = x_end - x_start,
            .height = y_end - y_start,
        };
    }

    /// Returns the smallest possible rectangle that contains both other rectangles.
    pub fn boundingBox(self: Rect, other: Rect) Rect {
        const x_start = @min(self.x, other.x);
        const y_start = @min(self.y, other.y);
        const x_end = @max(self.x + self.width, other.x + other.width);
        const y_end = @max(self.y + self.height, other.y + other.height);

        return .{
            .x = x_start,
            .y = y_start,
            .width = x_end - x_start,
            .height = y_end - y_start,
        };
    }

    pub fn drawArea(self: Rect, draw_context: *const DrawContext, color: Color) void {
        const x_min = self.x;
        const y_min = self.y;

        const x_max = self.x + self.width;
        const y_max = self.y + self.height;
        const width = draw_context.window_area.width;

        for (y_min..y_max) |y_coord| {
            for (x_min..x_max) |x_coord| {
                draw_context.window_area.assertContainsPoint(.{ .x = @intCast(x_coord), .y = @intCast(y_coord) });
                draw_context.screen[y_coord * width + x_coord] = color;
            }
        }
    }

    pub fn damageArea(self: Rect, draw_context: *const DrawContext) void {
        draw_context.surface.?.damageBuffer(self.x, self.y, self.width, self.height);
    }

    pub fn drawOutline(self: Rect, draw_context: *const DrawContext, color: Color) void {
        const x_min = self.x;
        const y_min = self.y;

        const x_max = self.x + self.width;
        const y_max = self.y + self.height;
        const width = draw_context.window_area.width;
        const height = draw_context.window_area.height;

        assert(width >= x_max);
        assert(height >= y_max);

        for (y_min..y_max) |y_coord| {
            draw_context.screen[y_coord * width + x_min] = color;
            draw_context.screen[y_coord * width + x_max - 1] = color;
        }

        for (x_min..x_max) |x_coord| {
            draw_context.screen[y_min * width + x_coord] = color;
            draw_context.screen[(y_max - 1) * width + x_coord] = color;
        }
    }

    pub fn damageOutline(self: Rect, draw_context: *const DrawContext) void {
        draw_context.surface.?.damageBuffer(self.x, self.y, self.width, 1);
        draw_context.surface.?.damageBuffer(self.x, self.y, 1, self.height);
        draw_context.surface.?.damageBuffer(self.x + self.width, self.y, 1, self.height);
        draw_context.surface.?.damageBuffer(self.x, self.y + self.height, self.width, 1);
    }

    pub fn putPixel(self: Rect, area_local_point: Point, draw_context: *const DrawContext, color: Color) void {
        const x_coord = self.x + area_local_point.x;
        const y_coord = self.y + area_local_point.y;

        const width = draw_context.window_area.width;

        draw_context.window_area.assertContainsPoint(.{ .x = x_coord, .y = y_coord });
        draw_context.screen[y_coord * width + x_coord] = color;
    }

    pub fn putComposite(
        self: Rect,
        draw_context: *const DrawContext,
        area_local_point: Point,
        color: Color,
    ) void {
        const x_coord = self.x + area_local_point.x;
        const y_coord = self.y + area_local_point.y;

        const width = draw_context.window_area.width;

        draw_context.window_area.assertContainsPoint(.{ .x = x_coord, .y = y_coord });

        const base_color = draw_context.screen[y_coord * width + x_coord];

        const new_color = colors.composite(base_color, color);

        draw_context.screen[y_coord * width + x_coord] = new_color;
    }
};

pub const Widget = struct {
    const VTable = struct {
        draw: *const fn (*Widget, *const DrawContext) anyerror!void,
        deinit: *const fn (*Widget, Allocator) void,
    };
    vtable: *const VTable,

    area: Rect,

    /// This should be true anytime the widget needs to redraw.
    /// So if the area is changed or the glyph needs to for other reasons.
    full_redraw: bool = true,

    pub inline fn draw(self: *Widget, draw_context: *const DrawContext) anyerror!void {
        try self.vtable.draw(self, draw_context);
    }

    pub inline fn deinit(self: *Widget, allocator: Allocator) void {
        self.vtable.deinit(self, allocator);
    }

    pub fn getParent(self: *Widget, T: type) *T {
        return @fieldParentPtr("widget", self);
    }
};

pub const Align = enum { start, center, end };

const DrawContext = @import("DrawContext.zig");
const freetype_context = &@import("FreeTypeContext.zig").global;

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
