//! TODO: Clock verbose logging
//! TODO: Ensure padding works properly
pub const Clock = @This();

pub const ClockConfig = struct {
    pub const text_color_comment = "The icons's color";
    pub const spacer_color_comment = "The icons's color";
    pub const background_color_comment = "The background color.";

    pub const spacer_char_comment = "The character to use as a space";

    pub const padding_comment = "The general padding for each size between the letters.";

    pub const padding_north_comment = "Overrides general padding the top side";
    pub const padding_south_comment = "Overrides general padding the bottom side";
    pub const padding_east_comment = "Overrides general padding the right side";
    pub const padding_west_comment = "Overrides general padding the left side";

    text_color: Color = colors.rose,
    spacer_color: Color = colors.pine,
    background_color: Color = colors.surface,

    spacer_char: u21 = '',

    padding: ?Size = null,

    padding_north: ?Size = null,
    padding_south: ?Size = null,
    padding_east: ?Size = null,
    padding_west: ?Size = null,

    //inner_padding: ?Size = null,
};

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

pub fn init(area: Rect, config: ClockConfig) Clock {
    const padding = config.padding orelse 0;
    const default_text_box = TextBox.init(.{
        .text = "00",
        .text_color = config.text_color,
        .background_color = config.background_color,

        .outline = options.clock_outlines,

        // area undefined because the self.setArea() will set it.
        .area = undefined,

        // center the text to be more central
        .padding = padding,
        .padding_north = config.padding_north orelse config.padding orelse area.height / 8,
        .padding_south = config.padding_south orelse config.padding orelse area.height / 8,

        // all of the characters a clock would display
        .scaling = .{ .max = "1234567890" },
    });

    var self = Clock{
        .hours_box = default_text_box,
        .minutes_box = default_text_box,
        .seconds_box = default_text_box,

        .background_color = config.background_color,
        .spacer_color = config.spacer_color,

        .spacer_char = config.spacer_char,

        .padding = .{
            .north = config.padding_north orelse config.padding orelse area.height / 8,
            .south = config.padding_south orelse config.padding orelse area.height / 8,
            .east = config.padding_east orelse padding,
            .west = config.padding_west orelse padding,
        },

        .widget = .{
            .vtable = Widget.generateVTable(Clock),

            .area = area,
        },
    };

    self.setArea(area);

    return self;
}

inline fn timeGlyphScaling(size: Size) Size {
    return size * 27 / 20;
}

inline fn spacerGlyphScaling(size: Size) Size {
    return size * 8 / 10;
}

// TODO: use FreeTypeContext.maxGlyphSize(...)
inline fn spacerFontSize(self: *const Clock) Size {
    const area_wo_padding = self.widget.area.removePadding(self.padding) orelse return 0;
    return spacerGlyphScaling(area_wo_padding.height);
}

/// conversion to draw from the widget vtable
pub fn drawWidget(widget: *Widget, draw_context: *DrawContext) !void {
    const self: *Clock = @fieldParentPtr("widget", widget);
    defer {
        self.widget.full_redraw = false;
        assert(!self.hours_box.full_redraw);
        assert(!self.minutes_box.full_redraw);
        assert(!self.seconds_box.full_redraw);
    }

    const tod = ctime.time(null);
    const localtime = ctime.localtime(&tod);
    assert(localtime != null);

    const should_redraw = draw_context.full_redraw or self.widget.full_redraw;

    if (should_redraw) {
        self.hours_box.full_redraw = true;
        self.minutes_box.full_redraw = true;
        self.seconds_box.full_redraw = true;
        if (options.clock_outlines) self.widget.area.drawOutline(draw_context, colors.border);
    }

    // if the padding is larger than the area, then there is nothing to draw.
    const area_wo_padding = self.widget.area.removePadding(self.padding) orelse return;

    self.hours_box.setText(&num2Char(@intCast(localtime.*.tm_hour)));
    // there are no errors that can happen.
    self.hours_box.draw(draw_context);
    const hours_width = self.hours_box.getWidth();

    self.minutes_box.setText(&num2Char(@intCast(localtime.*.tm_min)));
    self.minutes_box.draw(draw_context);
    const minutes_width = self.minutes_box.getWidth();

    self.seconds_box.setText(&num2Char(@intCast(localtime.*.tm_sec)));
    self.seconds_box.draw(draw_context);

    if (should_redraw) {
        const font_size = self.spacerFontSize();

        const spacer_width: Size = self.getSpacerWidth();

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

/// No deinit needed.
pub fn deinit(self: *Clock) void {
    _ = self;
}

/// returns the used width in pixels
pub fn getWidth(self: *Clock) Size {
    const hours_width = self.hours_box.getWidth();
    const minutes_width = self.minutes_box.getWidth();
    const seconds_width = self.seconds_box.getWidth();

    const spacer_width: Size = self.getSpacerWidth();

    return hours_width + spacer_width + minutes_width + spacer_width + seconds_width;
}

fn getSpacerWidth(self: *Clock) Size {
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

    area.assertContains(self.hours_box.area);
    area.assertContains(self.minutes_box.area);
    area.assertContains(self.seconds_box.area);
}

test {
    std.testing.refAllDecls(@This());
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
const Size = drawing.Size;

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
