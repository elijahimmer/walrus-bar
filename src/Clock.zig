pub const Clock = @This();

hours_text: [2]u8,
minutes_text: [2]u8,
seconds_text: [2]u8,

hours_box: TextBox,
minutes_box: TextBox,
seconds_box: TextBox,

widget: Widget,

pub const NewArgs = struct {
    area: Rect,

    text_color: Color,
    outline_color: Color,
    background_color: Color,

    padding: u16 = 0,

    padding_north: ?u16 = null,
    padding_south: ?u16 = null,
    padding_east: ?u16 = null,
    padding_west: ?u16 = null,
};

pub fn draw(widget: *Widget, draw_context: *const DrawContext) !void {
    const self: *Clock = @fieldParentPtr("widget", widget);

    self.hours_box.draw(draw_context);
    self.minutes_box.draw(draw_context);
    self.seconds_box.draw(draw_context);
}

pub fn deinit(widget: *Widget, allocator: Allocator) void {
    const self: *Clock = @fieldParentPtr("widget", widget);

    allocator.destroy(self);
}

pub fn new(allocator: Allocator, draw_context: *DrawContext, args: NewArgs) Allocator.Error!*Widget {
    const self = try allocator.create(Clock);

    self.* = .{
        .hours_text = .{ '0', '0' },
        .minutes_text = .{ '0', '0' },
        .seconds_text = .{ '0', '0' },

        .hours_box = undefined,
        .minutes_box = undefined,
        .seconds_box = undefined,

        .widget = .{
            .vtable = &.{
                .draw = &Clock.draw,
                .deinit = &Clock.deinit,
            },

            .area = args.area,
        },
    };

    self.hours_box = TextBox.init(.{
        .text = &self.hours_text,
        .text_color = args.text_color,
        .outline_color = args.outline_color,
        .background_color = args.background_color,

        .area = args.area,

        .scaling = .{ .max = "1234567890" },

        .padding = 0,
    });

    const time_width = self.hours_box.getWidth(draw_context);
    std.log.debug("---- time_width: {}", .{time_width});
    assert(time_width * 3 < args.area.width);

    self.hours_box.widget.area.width = time_width;
    var current_area = self.hours_box.widget.area;
    args.area.assertContains(current_area);

    current_area.x += time_width;

    self.minutes_box = TextBox.init(.{
        .text = &self.minutes_text,
        .text_color = args.text_color,
        .outline_color = args.outline_color,
        .background_color = args.background_color,

        // TODO: Make area only what is needed.
        .area = current_area,

        .scaling = .{ .max = "1234567890" },

        .padding = 0,
    });

    current_area.x += time_width;
    args.area.assertContains(current_area);

    self.seconds_box = TextBox.init(.{
        .text = &self.seconds_text,
        .text_color = args.text_color,
        .outline_color = args.outline_color,
        .background_color = args.background_color,

        // TODO: Make area only what is needed.
        .area = current_area,

        .scaling = .{ .max = "1234567890" },

        .padding = 0,
    });

    return &self.widget;
}

const TextBox = @import("TextBox.zig");

const DrawContext = @import("DrawContext.zig");
const drawing = @import("drawing.zig");
const Widget = drawing.Widget;
const Rect = drawing.Rect;

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
