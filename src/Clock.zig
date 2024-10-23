pub const Clock = @This();

hours_box: TextBox,
minutes_box: TextBox,
seconds_box: TextBox,

background_color: Color,
spacer_color: Color,

/// The character put between the hours and the minutes and the minutes and the seconds.
/// This should only be a single UTF-8 character.
spacer_char: BoundedArray(u8, 4),

/// The widget object used for the text box.
widget: Widget,

inline fn timeGlyphScaling(size: u31) u31 {
    return size * 27 / 20;
}

inline fn spacerSizeScale(size: u31) u31 {
    return size * 8 / 10;
}

/// conversion to draw from the widget vtable
pub fn drawWidget(widget: *Widget, draw_context: *DrawContext) !void {
    const self: *Clock = @fieldParentPtr("widget", widget);

    try self.draw(draw_context);
}

pub fn draw(self: *Clock, draw_context: *DrawContext) !void {
    assert(self.spacer_char.len > 0);

    const tod = ctime.time(null);
    const localtime = ctime.localtime(&tod);
    assert(localtime != null);

    const should_redraw = draw_context.full_redraw or self.widget.full_redraw;

    if (should_redraw) {
        self.hours_box.widget.full_redraw = true;
        self.minutes_box.widget.full_redraw = true;
        self.seconds_box.widget.full_redraw = true;
    }

    self.hours_box.setText(&num2Char(@intCast(localtime.*.tm_hour)));
    const hours_width = self.hours_box.getWidth();
    self.hours_box.draw(draw_context);

    self.minutes_box.setText(&num2Char(@intCast(localtime.*.tm_min)));
    const minutes_width = self.minutes_box.getWidth();
    self.minutes_box.draw(draw_context);

    self.seconds_box.setText(&num2Char(@intCast(localtime.*.tm_sec)));
    self.seconds_box.draw(draw_context);

    if (should_redraw) {
        freetype_context.setFontPixelSize(spacerSizeScale(self.widget.area.height), 0);

        const spacer_width: u31 = self.getSpacerWidth();

        var max_time_glyph_area = Rect{
            .x = self.widget.area.x + hours_width,
            .y = self.widget.area.y,
            .height = self.widget.area.height,
            .width = spacer_width,
        };

        for (0..2) |_| {
            freetype_context.drawChar(.{
                .draw_context = draw_context,
                .text_color = self.spacer_color,
                .area = max_time_glyph_area,

                .char = self.spacer_char.slice(),
                .width = .{ .fixed = spacer_width },

                .hori_align = .center,
                .vert_align = .center,
            });

            max_time_glyph_area.x += spacer_width + minutes_width;
        }
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

/// returns the used width in pixels
pub fn getWidth(self: *Clock) u31 {
    const hours_width = self.hours_box.getWidth();
    const minutes_width = self.minutes_box.getWidth();
    const seconds_width = self.seconds_box.getWidth();

    const spacer_width: u31 = self.getSpacerWidth();

    return hours_width + spacer_width + minutes_width + spacer_width + seconds_width;
}

fn getSpacerWidth(self: *Clock) u31 {
    freetype_context.setFontPixelSize(0, spacerSizeScale(self.widget.area.height));
    const glyph = freetype_context.loadChar(self.spacer_char.slice(), .default);
    return timeGlyphScaling(@intCast(glyph.*.advance.x >> 6));
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
    const clock = try allocator.create(TextBox);

    clock.* = Clock.init(args);

    return &Clock.widget;
}

pub fn init(args: NewArgs) Clock {
    assert(args.spacer_char.len > 0);
    assert(unicode.utf8ValidateSlice(args.spacer_char));

    const spacer_char_sequence_len = unicode.utf8ByteSequenceLength(args.spacer_char[0]) catch {
        @panic("Space Char start with invalid UTF-8 Byte.");
    };
    assert(spacer_char_sequence_len == args.spacer_char.len);

    const default_text_box = TextBox.init(.{
        .text = &.{ '0', '0' },
        .text_color = args.text_color,
        .background_color = args.background_color,

        // area undefined because the self.setArea() will set it.
        .area = undefined,

        // center the text to be more central
        .padding_north = @intCast(args.area.height / 10),

        // all of the characters a clock would display
        .scaling = .{ .max = "1234567890" },
    });

    var self = Clock{
        .hours_box = default_text_box,
        .minutes_box = default_text_box,
        .seconds_box = default_text_box,

        .background_color = args.background_color,
        .spacer_color = args.spacer_color,

        .spacer_char = BoundedArray(u8, 4).fromSlice(args.spacer_char) catch unreachable,

        .widget = .{
            .vtable = &.{
                .draw = &Clock.drawWidget,
                .deinit = &Clock.deinitWidget,
                .setArea = &Clock.setAreaWidget,
            },

            .area = args.area,
        },
    };

    self.setArea(args.area);

    return self;
}

const TextBox = @import("TextBox.zig");

const DrawContext = @import("DrawContext.zig");
const drawing = @import("drawing.zig");

const FreeTypeContext = @import("FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;

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
