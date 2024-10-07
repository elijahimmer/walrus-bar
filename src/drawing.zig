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

    pub fn fill(self: Rect, draw_context: *DrawContext, color: Color) void {
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
        assert(self.x + self.width <= inner.x + inner.width);
        assert(self.y + self.height <= inner.y + inner.height);
    }

    pub fn assertContainsPoint(self: Rect, point: Point) void {
        assert(self.x <= point.x);
        assert(self.y <= point.y);
        assert(self.x + self.width >= point.x);
        assert(self.y + self.height >= point.y);
    }

    pub fn drawArea(self: Rect, draw_context: *DrawContext, color: Color) void {
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

    pub fn damageArea(self: Rect, draw_context: *DrawContext) void {
        draw_context.surface.?.damageBuffer(self.x, self.y, self.width, self.height);
    }

    pub fn drawOutline(self: Rect, draw_context: *DrawContext, color: Color) void {
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
            draw_context.screen[(y_max - 1) * width + x_coord - 1] = color;
        }
    }

    pub fn damageOutline(self: Rect, draw_context: *DrawContext) void {
        draw_context.surface.?.damageBuffer(self.x, self.y, self.width, 1);
        draw_context.surface.?.damageBuffer(self.x, self.y, 1, self.height);
        draw_context.surface.?.damageBuffer(self.x + self.width, self.y, 1, self.height);
        draw_context.surface.?.damageBuffer(self.x, self.y + self.height, self.width, 1);
    }
};

pub const Widget = struct {
    const VTable = struct {
        draw: *const fn (*const Widget, *DrawContext) anyerror!void,
        //update: *const fn (*Widget, *DrawContext) anyerror!void,

        deinit: *const fn (*const Widget, Allocator) void,
    };
    vtable: VTable,
    inner: *anyopaque,

    area: Rect,
    area_changed: bool = true,

    pub inline fn draw(self: *const Widget, draw_context: *DrawContext) anyerror!void {
        try self.vtable.draw(self, draw_context);
    }

    pub inline fn deinit(self: *Widget, allocator: Allocator) void {
        self.vtable.deinit(self, allocator);
    }

    pub fn putPixel(
        self: *Widget,
        draw_context: *DrawContext,
        area_local_point: Point,
        color: Color,
    ) void {
        const x_coord = self.area.x + area_local_point.x;
        const y_coord = self.area.y + area_local_point.y;
        draw_context.window_area.assertContainsPoint(.{ .x = x_coord, .y = y_coord });

        draw_context.screen[y_coord * draw_context.window_area.width + x_coord] = color;
    }

    pub fn putPixelComposite(
        self: *Widget,
        draw_context: *DrawContext,
        area_local_point: Point,
        color: Color,
    ) void {
        const x_coord = self.area.x + area_local_point.x;
        const y_coord = self.area.y + area_local_point.y;
        const width = draw_context.window_area.width;

        draw_context.window_area.assertContainsPoint(.{ .x = x_coord, .y = y_coord });

        const base_color = draw_context.screen[y_coord * width + x_coord];

        const new_color = colors.composite(base_color, color);

        draw_context.screen[y_coord * width + x_coord] = new_color;
    }

    pub fn getInner(self: *Widget, T: type) *T {
        return @ptrCast(self.inner);
    }
};

pub const TextInner = struct {
    const TextArray = BoundedArray(u8, 32);
    text: TextArray,

    text_color: Color,
    outline_color: Color,
    background_color: Color,

    pub fn draw(widget: *const Widget, draw_context: *DrawContext) anyerror!void {
        const self: *TextInner = @ptrCast(@alignCast(widget.inner));
        const area = widget.area;

        if (draw_context.full_redraw or widget.area_changed) {
            area.drawArea(draw_context, self.text_color);

            area.drawOutline(draw_context, self.outline_color);
        }
    }

    //pub fn update(widget: *Widget, draw_context: *DrawContext) anyerror!void {
    //    const self: *TextInner = @ptrCast(@alignCast(widget.inner));
    //    const area = widget.area;

    //    _ = self;
    //    _ = area;
    //    _ = draw_context;
    //}

    pub fn deinit(widget: *const Widget, allocator: Allocator) void {
        const self: *TextInner = @ptrCast(@alignCast(widget.inner));

        allocator.destroy(self);
    }
};

pub const NewTextWidgetArgs = struct {
    allocator: Allocator,

    area: Rect,

    /// Text has to be alive for the lifetime of the widget.
    text: []const u8,

    text_color: Color,
    outline_color: Color,
    background_color: Color,
};

pub fn newTextWidget(args: NewTextWidgetArgs) Allocator.Error!Widget {
    const text_inner = try args.allocator.create(TextInner);
    text_inner.* = .{
        .text = TextInner.TextArray.fromSlice(args.text) catch @panic("Text too large for text box."),

        .text_color = args.text_color,
        .outline_color = args.outline_color,
        .background_color = args.background_color,
    };

    return .{
        .vtable = .{
            .draw = &TextInner.draw,
            //.update = &TextInner.update,

            .deinit = &TextInner.deinit,
        },
        .inner = text_inner,

        .area = args.area,
    };
}

const DrawContext = @import("DrawContext.zig");
const freetype_context = &@import("FreeTypeContext.zig").global;

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
