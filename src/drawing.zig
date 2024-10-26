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

pub const Padding = struct {
    north: u16,
    south: u16,
    east: u16,
    west: u16,

    pub fn from(args: anytype) Padding {
        return .{
            .north = args.padding_north orelse args.padding,
            .south = args.padding_south orelse args.padding,
            .east = args.padding_east orelse args.padding,
            .west = args.padding_west orelse args.padding,
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

    /// returns the X and Y coordinates of the Rect
    pub fn origin(self: Rect) Point {
        return .{
            .x = self.x,
            .y = self.y,
        };
    }

    /// returns the Width and Height dims of the Rect
    pub fn dims(self: Rect) Point {
        return .{
            .x = self.width,
            .y = self.height,
        };
    }

    /// Returns a intersecting rectangle, null if they don't intersect.
    /// Their width and height will be greater zero.
    pub fn intersection(self: Rect, other: Rect) ?Rect {
        const x_start = @max(self.x, other.x);
        const y_start = @max(self.y, other.y);
        const x_end = @min(self.x + self.width, other.x + other.width);
        const y_end = @min(self.y + self.height, other.y + other.height);

        // they don't actually intersect
        // TODO: Check if this should be `>` or `>=`
        if (x_start >= x_end or y_start >= y_end) return null;

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

    /// Center inner box in self. Asserts self is larger than inner
    pub fn center(self: Rect, inner: Point) Rect {
        return self.alignWith(inner, .center, .center);
    }

    /// Inner is the width and height of the returned Rect.
    pub fn alignWith(self: Rect, inner: Point, hori_align: Align, vert_align: Align) Rect {
        assert(self.width >= inner.x);
        assert(self.height >= inner.y);

        const new_x = switch (hori_align) {
            .start => self.x,
            .end => self.x + self.width - inner.x,
            .center => self.x + (self.width - inner.x) / 2,
        };

        const new_y = switch (vert_align) {
            .start => self.y,
            .end => self.y + self.height - inner.y,
            .center => self.y + (self.height - inner.y) / 2,
        };

        return .{
            .x = new_x,
            .y = new_y,
            .width = inner.x,
            .height = inner.y,
        };
    }

    /// Remove the padding from each side of widget
    pub fn removePadding(self: Rect, padding: Padding) ?Rect {
        if (self.height < (padding.north + padding.south) or self.width < (padding.east + padding.west)) {
            return null;
        }

        return .{
            .x = self.x + padding.east,
            .y = self.y + padding.north,
            .width = self.width - padding.east - padding.west,
            .height = self.height - padding.north - padding.south,
        };
    }

    pub fn drawArea(self: Rect, draw_context: *const DrawContext, color: Color) void {
        const x_min = self.x;
        const y_min = self.y;

        const x_max = self.x + self.width;
        const y_max = self.y + self.height;
        const window_width = draw_context.window_area.width;

        for (y_min..y_max) |y_coord| {
            for (x_min..x_max) |x_coord| {
                draw_context.current_area.assertContainsPoint(.{ .x = @intCast(x_coord), .y = @intCast(y_coord) });
                draw_context.screen[y_coord * window_width + x_coord] = color;
            }
        }
    }

    pub fn damageArea(self: Rect, draw_context: *const DrawContext) void {
        draw_context.current_area.assertContains(self);
        draw_context.surface.?.damageBuffer(self.x, self.y, self.width, self.height);
    }

    pub fn drawOutline(self: Rect, draw_context: *const DrawContext, color: Color) void {
        const x_min = self.x;
        const y_min = self.y;

        const x_max = self.x + self.width;
        const y_max = self.y + self.height;
        const window_width = draw_context.window_area.width;
        const window_height = draw_context.window_area.height;

        assert(window_width >= x_max);
        assert(window_height >= y_max);

        for (y_min..y_max) |y_coord| {
            draw_context.screen[y_coord * window_width + x_min] = color;
            draw_context.screen[y_coord * window_width + x_max - 1] = color;
        }

        for (x_min..x_max) |x_coord| {
            draw_context.screen[y_min * window_width + x_coord] = color;
            draw_context.screen[(y_max - 1) * window_width + x_coord] = color;
        }
    }

    pub fn damageOutline(self: Rect, draw_context: *const DrawContext) void {
        draw_context.surface.?.damageBuffer(self.x, self.y, self.width, 1);
        draw_context.surface.?.damageBuffer(self.x, self.y, 1, self.height);
        draw_context.surface.?.damageBuffer(self.x + self.width, self.y, 1, self.height);
        draw_context.surface.?.damageBuffer(self.x, self.y + self.height, self.width, 1);
    }

    pub fn putPixel(self: Rect, draw_context: *const DrawContext, area_local_point: Point, color: Color) void {
        const x_coord = self.x + area_local_point.x;
        const y_coord = self.y + area_local_point.y;

        const window_width = draw_context.window_area.width;

        draw_context.window_area.assertContainsPoint(.{ .x = x_coord, .y = y_coord });
        draw_context.screen[y_coord * window_width + x_coord] = color;
    }

    pub fn putComposite(
        self: Rect,
        draw_context: *const DrawContext,
        area_local_point: Point,
        color: Color,
    ) void {
        const x_coord = self.x + area_local_point.x;
        const y_coord = self.y + area_local_point.y;

        const window_width = draw_context.window_area.width;

        draw_context.current_area.assertContainsPoint(.{ .x = x_coord, .y = y_coord });

        const base_color = draw_context.screen[y_coord * window_width + x_coord];

        const new_color = base_color.composite(color);

        draw_context.screen[y_coord * window_width + x_coord] = new_color;
    }
};

pub const Widget = struct {
    const VTable = struct {
        // TODO: Don't use anyerror here. It sucks.
        draw: *const fn (*Widget, *DrawContext) anyerror!void,
        deinit: *const fn (*Widget, Allocator) void,
        setArea: *const fn (*Widget, Rect) void,
        getWidth: *const fn (*Widget) u31,
    };
    vtable: *const VTable,

    area: Rect,

    /// This should be true anytime the widget needs to redraw.
    /// So if the area is changed or the glyph needs to for other reasons.
    full_redraw: bool = true,

    pub inline fn draw(self: *Widget, draw_context: *DrawContext) anyerror!void {
        try self.vtable.draw(self, draw_context);
    }

    /// Deinitializes the widget
    pub inline fn deinit(self: *Widget, allocator: Allocator) void {
        self.vtable.deinit(self, allocator);
    }

    /// Sets the widget's area. Don't set it directly or drawing may mess up.
    pub inline fn setArea(self: *Widget, area: Rect) void {
        self.vtable.setArea(self, area);
    }

    /// Returns the actual width used, including padding.
    pub inline fn getWidth(self: *Widget) u32 {
        return self.vtable.getWidth(self);
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
