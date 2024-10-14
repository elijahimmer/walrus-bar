//! For proper behavior, when updating the text update it using
//! either the setText function, or enable area_
//!
pub const TextBox = @This();

const MaxTextLenInt = u6;
const max_text_len = math.maxInt(MaxTextLenInt);
pub const TextArray = BoundedArray(u8, max_text_len);

pub const ScalingType = enum {
    normal,
    /// Set the scale of the TextBox to make sure it can
    /// vertically fit all of the characters given, while still
    /// being as large as they can.
    max,
};

pub const ScalingTypeArg = union(ScalingType) {
    normal: void,
    /// should live as long as the widget.
    max: []const u8,
};

const ScalingTypeInfoMax = struct {
    str: []const u8,

    max_ascent: u31,
    max_descent: u31,
};

const ScalingTypeInfo = union(ScalingType) {
    normal: void,
    max: ScalingTypeInfoMax,
};

text: TextArray,

text_first_diff: ?MaxTextLenInt = null,

text_color: Color,
outline_color: Color,
background_color: Color,

padding_north: u16,
padding_south: u16,
padding_east: u16,
padding_west: u16,

scaling: ScalingTypeInfo,

widget: Widget,

pub fn drawWidget(widget: *Widget, draw_context: *const DrawContext) !void {
    const self: *TextBox = @fieldParentPtr("widget", widget);

    self.draw(draw_context);
}

pub fn draw(self: *TextBox, draw_context: *const DrawContext) void {
    const area = self.widget.area;

    var render_text_idx: ?MaxTextLenInt = null;

    const full_redraw = draw_context.full_redraw or self.widget.full_redraw;
    if (full_redraw) {
        log.debug("area: {}", .{area});
        area.drawArea(draw_context, self.background_color);

        area.drawOutline(draw_context, self.outline_color);

        //const area_used = Rect{
        //    .x = area.x + self.padding_west,
        //    .y = area.y + self.padding_north,
        //    .width = area.width - self.padding_east - self.padding_west,
        //    .height = area.height - self.padding_south - self.padding_north,
        //};
        //area.drawOutline(draw_context, self.outline_color);
        //area_used.drawOutline(draw_context, colors.muted);

        self.setFontSize(draw_context);

        render_text_idx = 0;
    } else if (self.text_first_diff) |first_diff| {
        render_text_idx = first_diff;
    }

    if (render_text_idx) |text_idx| {
        // the leftmost point the glyph should draw
        var pen_x = @as(u63, area.x) << 6;

        log.debug("area y: {}, ascender: {}, descender: {}", .{ area.y, freetype_context.font_face.*.ascender, freetype_context.font_face.*.descender });

        // sets the Y pen to the glyph's origin (bottom left-ish)
        const pen_y = (area.y << 6) + switch (self.scaling) {
            .normal => @as(u31, @intCast(freetype_context.font_face.*.ascender + freetype_context.font_face.*.descender)),
            .max => |max_info| ((area.height << 6) - max_info.max_descent) - (self.padding_south << 6) - (1 << 6), // needs the - 1 so that it is more centered.
        };

        //{ // draw pen line
        //    const pen_row = draw_context.screen[(pen_y >> 6) * draw_context.window_area.width ..][0..area.width];
        //    @memset(pen_row, colors.hl_high);
        //}

        var utf8_iter = unicode.Utf8Iterator{ .bytes = self.text.slice(), .i = text_idx };
        while (utf8_iter.nextCodepointSlice()) |utf8_char| {
            log.debug("Loading glyph: '{s}'", .{utf8_char});
            const glyph = freetype_context.loadChar(utf8_char, .render);
            const bitmap = glyph.*.bitmap;

            defer pen_x += @intCast(glyph.*.advance.x);

            if (bitmap.rows == 0 or bitmap.width == 0) continue;

            const bitmap_left: u31 = @intCast(glyph.*.bitmap_left);
            const bitmap_top: u31 = @intCast(glyph.*.bitmap_top);

            //assert(bitmap_left + (pen_x >> 6));
            log.debug("\tbitmap_top: {}, pen_y: {}, bitmap rows: {}", .{ bitmap_top, pen_y >> 6, bitmap.rows });
            //assert(bitmap_top <= (pen_y >> 6));

            const glyph_area = Rect{
                .x = @as(u31, @intCast(pen_x >> 6)) + bitmap_left,
                .y = @as(u31, @intCast(pen_y >> 6)) -| bitmap_top,
                .width = @intCast(bitmap.width),
                .height = @intCast(bitmap.rows),
            };

            log.debug("\tarea: {}, glyph_area: {}", .{ area, glyph_area });
            const used_area = area.intersection(glyph_area);

            //assert(std.meta.eql(glyph_area, used_area));

            assert(used_area.width > 0);
            assert(used_area.height > 0);

            //used_area.drawOutline(draw_context, colors.muted);

            self.drawBitmap(draw_context, glyph_area, bitmap);
        }
    }

    self.widget.full_redraw = false;
    self.text_first_diff = null;
}

/// Draws a bitmap onto the draw_context's screen in the given glyph_area.
/// Only draws on the intersection of the glyph_area and the TextBox's area,
/// so any part of a glyph trailing outside will just be cut off.
///
/// returns immediately for zero width or zero height `glyph_area`s
fn drawBitmap(self: *const TextBox, draw_context: *const DrawContext, glyph_area: Rect, bitmap: anytype) void {
    if (glyph_area.width == 0 or glyph_area.height == 0) return;

    const used_area = self.widget.area.intersection(glyph_area);

    const y_start_local = used_area.y - glyph_area.y;

    for (y_start_local..y_start_local + used_area.height) |y_coord_local| {
        assert(y_coord_local <= glyph_area.height);
        const bitmap_row = bitmap.buffer[y_coord_local * bitmap.width ..][0..bitmap.width];

        const x_start_local = used_area.x - glyph_area.x;

        for (x_start_local..x_start_local + used_area.width) |x_coord_local| {
            assert(x_coord_local <= glyph_area.width);

            var color = self.text_color;
            color.a = bitmap_row[x_coord_local];

            glyph_area.putComposite(draw_context, .{ .x = @intCast(x_coord_local), .y = @intCast(y_coord_local) }, color);
        }
    }
}

pub fn getWidth(self: *TextBox, draw_context: *const DrawContext) u31 {
    self.setFontSize(draw_context);

    var width: u31 = 0;
    var utf8_iter = unicode.Utf8Iterator{ .bytes = self.text.slice(), .i = 0 };
    while (utf8_iter.nextCodepointSlice()) |utf8_char| {
        const glyph = freetype_context.loadChar(utf8_char, .default);
        width += @intCast(glyph.*.advance.x);
    }

    return (width >> 6) + @intFromBool(((width >> 6) << 6) < width);
}

fn setFontSize(self: *TextBox, draw_context: *const DrawContext) void {
    const area = self.widget.area;
    const area_height_used = (area.height - self.padding_north) - self.padding_south;

    switch (self.scaling) {
        .normal => freetype_context.setFontPixelSize(&draw_context.output_context, area_height_used, 0),
        .max => |*max_info| {
            freetype_context.setFontPixelSize(&draw_context.output_context, area_height_used, 0);

            var utf8_iter = unicode.Utf8Iterator{ .bytes = max_info.str, .i = 0 };

            var ascent: u63 = 0;
            var descent: u63 = 0;

            while (utf8_iter.nextCodepointSlice()) |utf8_char| {
                const glyph = freetype_context.loadChar(utf8_char, .default);

                const height = glyph.*.metrics.height;
                const y_bearing = glyph.*.metrics.horiBearingY;

                ascent = @max(ascent, y_bearing);
                descent = @max(descent, height - y_bearing);
            }

            const height = ascent + descent;
            const area_height = area_height_used << 6;

            const pixel_height = (area_height * area_height) / height;

            log.debug("height: {}, area_height: {}, pixel_height: {}", .{ height, area_height, pixel_height });

            freetype_context.setFontPixelSize(&draw_context.output_context, @intCast(pixel_height >> 6), 0);

            max_info.max_ascent = @intCast(ascent);
            max_info.max_descent = @intCast(descent);
        },
    }
}

/// Only call if the TextBox was create via `new`
pub fn deinit(widget: *Widget, allocator: Allocator) void {
    const self: *TextBox = @fieldParentPtr("widget", widget);

    allocator.destroy(self);
}

pub fn setText(self: *TextBox, text: []const u8) void {
    const widget = self.widget;
    assert(text.len <= max_text_len);

    const diff: MaxTextLenInt = @intCast(mem.indexOfDiff(u8, text, self.text) orelse return);

    self.text.resize(text.len);
    @memcpy(self.text.slice()[diff..text.len], text[diff..]);

    if (diff == 0) widget.full_redraw = true;

    // Find the first unicode character that is different.
    var new_utf8_iter = unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var idx: MaxTextLenInt = 0;

    while (new_utf8_iter.nextCodePointSlice()) |char_slice| {
        // TODO: Do testing on this diff thing.
        if (idx + char_slice.len > diff) break;
        idx += char_slice.len;
    }

    self.text_first_diff = idx;
}

pub const NewArgs = struct {
    area: Rect,

    text: []const u8,

    text_color: Color,
    outline_color: Color,
    background_color: Color,

    scaling: ScalingTypeArg = .normal,

    padding: u16 = 0,

    padding_north: ?u16 = null,
    padding_south: ?u16 = null,
    padding_east: ?u16 = null,
    padding_west: ?u16 = null,
};

pub fn new(allocator: Allocator, args: NewArgs) Allocator.Error!*Widget {
    const text_box = try allocator.create(TextBox);

    text_box.* = TextBox.init(args);

    return &text_box.widget;
}

pub fn init(args: NewArgs) TextBox {
    switch (args.scaling) {
        .normal => {},
        .max => |max_str| {
            assert(max_str.len > 0);
            assert(unicode.utf8ValidateSlice(max_str));
        },
    }
    return .{
        .text = TextBox.TextArray.fromSlice(args.text) catch @panic("Text too large for text box."),

        .text_color = args.text_color,
        .outline_color = args.outline_color,
        .background_color = args.background_color,

        .scaling = switch (args.scaling) {
            .normal => .{ .normal = undefined },
            .max => |max_str| .{ .max = .{
                .str = max_str,
                .max_ascent = undefined,
                .max_descent = undefined,
            } },
        },

        .padding_north = args.padding_north orelse args.padding,
        .padding_south = args.padding_south orelse args.padding,
        .padding_east = args.padding_east orelse args.padding,
        .padding_west = args.padding_west orelse args.padding,

        .widget = .{
            .vtable = &.{
                .draw = &TextBox.drawWidget,
                .deinit = &TextBox.deinit,
            },
            .area = args.area,
        },
    };
}

const drawing = @import("drawing.zig");
const Widget = drawing.Widget;
const Rect = drawing.Rect;

const DrawContext = @import("DrawContext.zig");
const FreeTypeContext = @import("FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;
const freetype = FreeTypeContext.freetype;
const freetype_utils = @import("freetype_utils.zig");

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");
const mem = std.mem;
const math = std.math;
const unicode = std.unicode;

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
const log = std.log.scoped(.TextBox);
