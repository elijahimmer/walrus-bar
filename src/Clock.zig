//! TODO: Clock verbose logging
pub const Clock = @This();

hours_box: TextBox,
minutes_box: TextBox,
seconds_box: TextBox,

background_color: Color,
spacer_color: Color,

/// The character put between the hours and the minutes and the minutes and the seconds.
/// This should only be a single UTF-8 character.
spacer_char: u21,

/// The widget object used for the text box.
widget: Widget,

padding: Padding,

inline fn timeGlyphScaling(size: u31) u31 {
    return size * 27 / 20;
}

inline fn spacerGlyphScaling(size: u31) u31 {
    return size * 8 / 10;
}

// TODO: use FreeTypeContext.maxGlyphSize(...)
inline fn spacerFontSize(self: *const Clock) u31 {
    const area_wo_padding = self.widget.area.removePadding(self.padding) orelse return 0;
    return spacerGlyphScaling(area_wo_padding.height);
}

/// conversion to draw from the widget vtable
pub fn drawWidget(widget: *Widget, draw_context: *DrawContext) !void {
    const self: *Clock = @fieldParentPtr("widget", widget);

    try self.draw(draw_context);
}

pub fn draw(self: *Clock, draw_context: *DrawContext) !void {
    const tod = ctime.time(null);
    const localtime = ctime.localtime(&tod);
    assert(localtime != null);

    const should_redraw = draw_context.full_redraw or self.widget.full_redraw;

    if (should_redraw) {
        self.hours_box.widget.full_redraw = true;
        self.minutes_box.widget.full_redraw = true;
        self.seconds_box.widget.full_redraw = true;
        if (options.clock_outlines) self.widget.area.drawOutline(draw_context, colors.border);
    }

    self.hours_box.setText(&num2Char(@intCast(localtime.*.tm_hour)));
    self.hours_box.draw(draw_context);
    const hours_width = self.hours_box.getWidth();

    self.minutes_box.setText(&num2Char(@intCast(localtime.*.tm_min)));
    self.minutes_box.draw(draw_context);
    const minutes_width = self.minutes_box.getWidth();

    self.seconds_box.setText(&num2Char(@intCast(localtime.*.tm_sec)));
    self.seconds_box.draw(draw_context);

    if (should_redraw) spacer_drawing: {
        const font_size = self.spacerFontSize();

        const spacer_width: u31 = self.getSpacerWidth();

        // if the padding is larger than the area, then there is nothing to draw.
        const area_wo_padding = self.widget.area.removePadding(self.padding) orelse break :spacer_drawing;

        var draw_args = FreeTypeContext.DrawCharArgs{
            .draw_context = draw_context,
            .text_color = self.spacer_color,
            .area = Rect{
                .x = area_wo_padding.x + hours_width,
                .y = area_wo_padding.y,
                .height = area_wo_padding.height,
                .width = spacer_width,
            },
            .transform = Transform.identity,

            .bounding_box = options.clock_outlines,

            .char = self.spacer_char,
            .width = .{ .fixed = spacer_width },
            .font_size = font_size,

            .hori_align = .center,
            .vert_align = .center,
        };

        draw_args.area.drawArea(draw_context, self.background_color);
        freetype_context.drawChar(draw_args);

        draw_args.area.x += spacer_width + minutes_width;

        draw_args.area.drawArea(draw_context, self.background_color);
        freetype_context.drawChar(draw_args);
    }
}

/// Turns the num into two number characters.
/// Asserts num is less than 100
fn num2Char(num: u7) [2]u8 {
    assert(num < 100);
    return .{
        '0' + @as(u8, @intCast(num / 10)),
        '0' + @as(u8, @intCast(num % 10)),
    };
}

fn getWidthWidget(widget: *Widget) u31 {
    const self: *Clock = @fieldParentPtr("widget", widget);
    return self.getWidth();
}

/// returns the used width in pixels
pub fn getWidth(self: *Clock) u31 {
    const hours_width = self.hours_box.getWidth();
    const minutes_width = self.minutes_box.getWidth();
    const seconds_width = self.seconds_box.getWidth();

    const spacer_width: u31 = self.getSpacerWidth();

    return hours_width + spacer_width + minutes_width + spacer_width + seconds_width;
}

fn getSpacerWidth(self: *Clock) u31 {
    const font_size = self.spacerFontSize();
    const glyph = freetype_context.loadChar(self.spacer_char, .{
        .font_size = font_size,
        .load_mode = .default,
        .transform = Transform.identity,
    });
    const glyph_scaling = (glyph.advance_x >> 6) * 10 / 8;
    return glyph_scaling;
}

pub fn deinitWidget(widget: *Widget, allocator: Allocator) void {
    const self: *Clock = @fieldParentPtr("widget", widget);
    allocator.destroy(self);
}

pub fn setAreaWidget(widget: *Widget, area: Rect) void {
    const self: *Clock = @fieldParentPtr("widget", widget);
    self.setArea(area);
}

pub fn setArea(self: *Clock, area: Rect) void {
    self.widget.full_redraw = true;
    self.widget.area = area;

    const spacer_width = self.getSpacerWidth();

    self.hours_box.setArea(area);
    self.minutes_box.setArea(area);
    self.seconds_box.setArea(area);
    const hours_width = self.hours_box.getWidth();
    const minutes_width = self.minutes_box.getWidth();
    const seconds_width = self.seconds_box.getWidth();

    self.hours_box.setArea(.{
        .x = area.x,
        .y = area.y,
        .width = hours_width,
        .height = area.height,
    });

    self.minutes_box.setArea(.{
        .x = area.x + hours_width + spacer_width,
        .y = area.y,
        .width = minutes_width,
        .height = area.height,
    });

    self.seconds_box.setArea(.{
        .x = area.x + hours_width + spacer_width + minutes_width + spacer_width,
        .y = area.y,
        .width = seconds_width,
        .height = area.height,
    });

    area.assertContains(self.hours_box.widget.area);
    area.assertContains(self.minutes_box.widget.area);
    area.assertContains(self.seconds_box.widget.area);
}

pub const NewArgs = struct {
    area: Rect,

    text_color: Color,
    spacer_color: Color,
    background_color: Color,

    spacer_char: []const u8 = "",

    padding: u16 = 0,

    padding_north: ?u16 = null,
    padding_south: ?u16 = null,
    padding_east: ?u16 = null,
    padding_west: ?u16 = null,
};

pub fn newWidget(allocator: Allocator, args: NewArgs) Allocator.Error!*Widget {
    const clock = try allocator.create(Clock);

    clock.* = Clock.init(args);

    return &clock.widget;
}

pub fn init(args: NewArgs) Clock {
    assert(args.spacer_char.len > 0);
    assert(args.spacer_char.len <= 4);
    assert(unicode.utf8ValidateSlice(args.spacer_char));

    const spacer_char = unicode.utf8Decode(args.spacer_char) catch {
        @panic("Spacer character isn't valid UTF-8!");
    };

    const default_text_box = TextBox.init(.{
        .text = &.{ '0', '0' },
        .text_color = args.text_color,
        .background_color = args.background_color,

        .outline = options.clock_outlines,

        // area undefined because the self.setArea() will set it.
        .area = undefined,

        // center the text to be more central
        .padding_north = args.padding_north orelse args.padding,
        .padding_south = args.padding_south orelse args.padding,

        // all of the characters a clock would display
        .scaling = .{ .max = "1234567890" },
    });

    var self = Clock{
        .hours_box = default_text_box,
        .minutes_box = default_text_box,
        .seconds_box = default_text_box,

        .background_color = args.background_color,
        .spacer_color = args.spacer_color,

        .spacer_char = spacer_char,

        .padding = Padding.from(args),

        .widget = .{
            .vtable = &.{
                .draw = &Clock.drawWidget,
                .deinit = &Clock.deinitWidget,
                .setArea = &Clock.setAreaWidget,
                .getWidth = &Clock.getWidthWidget,
                .motion = null,
                .leave = null,
                .click = null,
            },

            .area = args.area,
        },
    };

    self.setArea(args.area);

    return self;
}

const options = @import("options");

const TextBox = @import("TextBox.zig");

const DrawContext = @import("DrawContext.zig");

const FreeTypeContext = @import("FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;

const drawing = @import("drawing.zig");
const Transform = drawing.Transform;
const Padding = drawing.Padding;
const Widget = drawing.Widget;
const Point = drawing.Point;
const Rect = drawing.Rect;

const colors = @import("colors.zig");
const Color = colors.Color;

const ctime = @cImport({
    @cInclude("time.h");
});

const std = @import("std");
const posix = std.posix;
const unicode = std.unicode;

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
const assert = std.debug.assert;

const log = std.log.scoped(.Clock);
