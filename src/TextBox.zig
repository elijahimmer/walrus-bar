//! For proper behavior, when updating the text update it using
//! either the setText function, or enable area_
//!
pub const TextBox = @This();

pub const MaxTextLenInt = u6;
pub const max_text_len = math.maxInt(MaxTextLenInt);
pub const TextArray = BoundedArray(u8, max_text_len);

pub const ScalingType = enum {
    normal,
    /// Set the scale of the TextBox to make sure it can
    /// vertically fit all of the characters given, while still
    /// being as large as they can.
    max,
};

pub const ScalingTypeArg = union(ScalingType) {
    normal,
    /// should live as long as the TextBox.
    max: []const u8,
};

// Internal Information
const ScalingTypeInfoMax = struct {
    str: []const u8,

    max_ascent: Size,
    max_descent: Size,

    last_calculated_scale: ?Size,
};

const ScalingTypeInfo = union(ScalingType) {
    normal,
    max: ScalingTypeInfoMax,
};

text: TextArray,

text_first_diff: ?MaxTextLenInt = null,
last_calculated_width: ?Size = null,

text_color: Color,
background_color: Color,

should_outline: bool,

// TODO: Switch to padding struct.
padding_north: Size,
padding_south: Size,
padding_east: Size,
padding_west: Size,

scaling: ScalingTypeInfo,

area: Rect,
full_redraw: bool = true,

pub fn draw(self: *TextBox, draw_context: *DrawContext) void {
    defer self.text_first_diff = null;
    defer self.full_redraw = false;
    const area = self.area;

    const full_redraw = draw_context.full_redraw or self.full_redraw;
    const render_text_idx: ?MaxTextLenInt = if (full_redraw)
        0
    else
        self.text_first_diff;

    if (render_text_idx) |text_idx| {
        const font_size = self.getFontSize();

        // the leftmost point the glyph should draw
        var pen_x = @as(u32, area.x) << 6;

        // sets the Y pen to the glyph's origin (bottom left-ish)
        const pen_y = (area.y << 6) + switch (self.scaling) {
            .normal => @as(Size, @intCast(freetype_context.font_face.*.ascender + freetype_context.font_face.*.descender)),
            .max => |max_info| ((area.height << 6) - max_info.max_descent) - (self.padding_south << 6) - (1 << 6), // needs the - 1 so that it is more centered.
        };

        // Get how wide the glyphs that don't need to be render are
        var utf8_iter = unicode.Utf8Iterator{ .bytes = self.text.slice(), .i = 0 };
        for (0..text_idx) |_| {
            const utf8_char = utf8_iter.nextCodepoint().?;
            // we only need the default here.
            const glyph = freetype_context.loadChar(utf8_char, .{
                .font_size = font_size,
                .load_mode = .default,
                .transform = Transform.identity,
            });

            pen_x += glyph.advance_x;
        }

        assert(utf8_iter.i == text_idx); // it should have only looped up to the glyph that need to be rendered

        // the max area the glyphs to be rendered should take up
        const complete_glyph_area = Rect{
            .x = @intCast(pen_x >> 6),
            .y = area.y,
            .width = @intCast(area.width - ((pen_x >> 6) - area.x)),
            .height = area.height,
        };
        area.assertContains(complete_glyph_area);

        // cover up old glyphs drawn.
        complete_glyph_area.drawArea(draw_context, self.background_color);

        draw_context.damage(complete_glyph_area);

        // Actually render the glyphs
        var loop_counter: usize = 0;
        while (utf8_iter.nextCodepoint()) |utf8_char| : (loop_counter += 1) {
            assert(loop_counter < max_text_len);

            // render because we are about to do that.
            const glyph = freetype_context.loadChar(utf8_char, .{
                .font_size = font_size,
                .load_mode = .render,
                .transform = Transform.identity,
            });

            drawBitmap(draw_context, .{
                .origin = .{ .x = @intCast(pen_x >> 6), .y = @intCast(pen_y >> 6) },
                .text_color = self.text_color,
                .max_area = self.area,
                .glyph = glyph,

                .no_alpha = false,
            });

            pen_x += glyph.advance_x;
        }

        if (self.should_outline) {
            area.drawOutline(draw_context, colors.gold);
        }
    }
}

/// Gets the total width of the textbox.
/// This only computes it if the position or font size was changed
/// since last calculation.
pub fn getWidth(self: *TextBox) Size {
    // if it was already calculated and the size hasn't changed, return that.
    if (self.last_calculated_width) |width| return width;

    const font_size = self.getFontSize();

    var width: Size = 0;
    var utf8_iter = unicode.Utf8Iterator{ .bytes = self.text.slice(), .i = 0 };
    var loop_counter: usize = 0;
    while (utf8_iter.nextCodepoint()) |utf8_char| : (loop_counter += 1) {
        assert(loop_counter < max_text_len);
        const glyph = freetype_context.loadChar(utf8_char, .{
            .font_size = font_size,
            .load_mode = .default,
            .transform = Transform.identity,
        });
        width += glyph.advance_x;
    }

    // the @intFromBool(...) is to round up the pixel height
    const final_width = (width >> 6) + @intFromBool(((width >> 6) << 6) < width);

    self.last_calculated_width = final_width;

    return final_width;
}

/// Sets the FreeType font size to the size needed for this text box.
/// This does some calculation depending on the scaling type.
///
/// Assumes the text size is different, and always sets it.
fn getFontSize(self: *TextBox) Size {
    const area = self.area;
    const area_height_used = (area.height - self.padding_north) - self.padding_south;

    switch (self.scaling) {
        .normal => return area_height_used,
        .max => |*max_info| {
            // if the last_calculated_scale is correct, just use that,
            if (!self.full_redraw and max_info.last_calculated_scale != null and self.text_first_diff == null) {
                return max_info.last_calculated_scale.?;
            }
            // else, calculate the scale.

            var utf8_iter = unicode.Utf8Iterator{ .bytes = max_info.str, .i = 0 };

            var ascent: u32 = 0;
            var descent: u32 = 0;

            var loop_counter: usize = 0;
            while (utf8_iter.nextCodepoint()) |utf8_char| : (loop_counter += 1) {
                assert(loop_counter < max_text_len);
                const glyph = freetype_context.loadChar(utf8_char, .{
                    .font_size = area_height_used,
                    .load_mode = .metrics,
                    .transform = Transform.identity,
                });

                // metrics is only null when transform != identity
                const height: u32 = @intCast(glyph.metrics.?.height);
                const y_bearing: u32 = @intCast(glyph.metrics.?.horiBearingY);

                ascent = @max(ascent, y_bearing);
                descent = @max(descent, height - y_bearing);
            }

            const height = ascent + descent;
            const area_height = @as(u32, area_height_used) << 6;

            const font_height = (area_height * area_height) / height;

            //log.debug("height: {}, area_height: {}, pixel_height: {}", .{ height, area_height, pixel_height });

            max_info.max_ascent = @intCast(ascent);
            max_info.max_descent = @intCast(descent);

            max_info.last_calculated_scale = @intCast(font_height >> 6);

            return max_info.last_calculated_scale.?;
        },
    }
}

pub fn setArea(self: *TextBox, area: Rect) void {
    self.area = area;
    self.full_redraw = true;
    self.last_calculated_width = null;
}

pub const SetColorsArgs = struct {
    background_color: Color,
    text_color: Color,
};

pub fn setColors(self: *TextBox, args: SetColorsArgs) void {
    if (!std.meta.eql(self.background_color, args.background_color)) {
        self.background_color = args.background_color;
        self.full_redraw = true;
    }
    if (!std.meta.eql(self.text_color, args.text_color)) {
        self.text_color = args.text_color;
        self.full_redraw = true;
    }
}

pub fn setText(self: *TextBox, text: []const u8) void {
    assert(text.len <= max_text_len);

    const diff: MaxTextLenInt = @intCast(mem.indexOfDiff(u8, text, self.text.slice()) orelse return);

    self.text.resize(text.len) catch @panic("");
    @memcpy(self.text.slice()[diff..text.len], text[diff..]);

    if (diff == 0) self.full_redraw = true;

    // Find the first unicode character that is different.
    var new_utf8_iter = unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var idx: MaxTextLenInt = 0;

    var loop_counter: usize = 0;
    while (new_utf8_iter.nextCodepointSlice()) |char_slice| : (loop_counter += 1) {
        assert(loop_counter < max_text_len);
        if (idx + char_slice.len > diff) break;
        idx += @intCast(char_slice.len);
    }

    self.text_first_diff = idx;
    self.last_calculated_width = null;
}

pub const InitArgs = struct {
    area: Rect,

    text: []const u8,

    text_color: Color,
    background_color: Color,

    scaling: ScalingTypeArg = .normal,

    outline: bool,

    padding: Size,

    padding_north: ?Size = null,
    padding_south: ?Size = null,
    padding_east: ?Size = null,
    padding_west: ?Size = null,
};

pub fn init(args: InitArgs) TextBox {
    assert(unicode.utf8ValidateSlice(args.text));

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
        .background_color = args.background_color,

        .scaling = switch (args.scaling) {
            .normal => .{ .normal = undefined },
            .max => |max_str| .{ .max = .{
                .str = max_str,
                .max_ascent = undefined,
                .max_descent = undefined,
                .last_calculated_scale = null,
            } },
        },

        .should_outline = args.outline,

        .padding_north = args.padding_north orelse args.padding,
        .padding_south = args.padding_south orelse args.padding,
        .padding_east = args.padding_east orelse args.padding,
        .padding_west = args.padding_west orelse args.padding,

        .area = args.area,
    };
}

test {
    std.testing.refAllDecls(@This());
}

const drawing = @import("drawing.zig");
const Transform = drawing.Transform;
const Point = drawing.Point;
const Rect = drawing.Rect;
const Size = drawing.Size;

const drawBitmap = @import("draw_bitmap.zig").drawBitmap;

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
