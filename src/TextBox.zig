//! For proper behavior, when updating the text update it using
//! either the setText function, or enable area_
//!
pub const TextBox = @This();

const MaxTextLenInt = u6;
const max_text_len = math.maxInt(MaxTextLenInt);
pub const TextArray = BoundedArray(u8, max_text_len);

/// How should the text be scaled. Always maintains aspect ratio of characters.
pub const ScalingType = enum {
    /// Makes sure most characters in font can fit in area.
    normal,

    /// Gets the scale to fix the Zero character as large as possible (scaled down slightly)
    /// Useful for displaying numbers and things that are strictly smaller
    /// than the zero character.
    ///
    /// Any part lower higher or lower than the zero will be cropped out.
    zero,

    /// Finds the largest possible font size for the area and text provided.
    max,
};
text: TextArray,

text_first_diff: ?MaxTextLenInt = null,

text_color: Color,
outline_color: Color,
background_color: Color,

scaling: ScalingType,

widget: Widget,

pub fn draw(widget: *Widget, draw_context: *const DrawContext) !void {
    const self: *TextBox = @fieldParentPtr("widget", widget);
    const area = widget.area;

    var render_text_idx: ?MaxTextLenInt = null;

    const full_redraw = draw_context.full_redraw or widget.full_redraw;
    if (full_redraw) {
        area.drawArea(draw_context, self.background_color);

        area.drawOutline(draw_context, self.outline_color);

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
            .zero => pen_y: {
                const ascender = @as(u31, @intCast(freetype_context.font_face.*.ascender + freetype_context.font_face.*.descender));
                const ascender_rounded = (ascender >> 6) << 6;
                const height = area.height << 6;

                log.debug("height: {}, ascender: {}", .{ height, ascender_rounded });
                break :pen_y height;
            },
            .max => @panic("Max Scaling Unimplemented"),
        };

        var utf8_iter = unicode.Utf8Iterator{ .bytes = self.text.slice(), .i = text_idx };
        while (utf8_iter.nextCodepointSlice()) |utf8_char| {
            log.debug("Loading glyph: '{s}'", .{utf8_char});
            const glyph = freetype_context.loadChar(utf8_char, .render);
            const bitmap = glyph.*.bitmap;

            const bitmap_left: u31 = @intCast(glyph.*.bitmap_left);
            const bitmap_top: u31 = @intCast(glyph.*.bitmap_top);

            //assert(bitmap_left + (pen_x >> 6));
            log.debug("bitmap_top: {}, pen_y: {}, bitmap rows: {}", .{ bitmap_top, pen_y >> 6, bitmap.rows });
            //assert(bitmap_top <= (pen_y >> 6));

            const glyph_area = Rect{
                .x = @as(u31, @intCast(pen_x >> 6)) + bitmap_left,
                .y = @as(u31, @intCast(pen_y >> 6)) -| bitmap_top,
                .width = @intCast(bitmap.width),
                .height = @intCast(bitmap.rows),
            };

            //const used_area = area.intersection(glyph_area);

            //used_area.drawOutline(draw_context, colors.muted);

            pen_x += @intCast(glyph.*.advance.x);

            self.drawBitmap(draw_context, glyph_area, bitmap);
        }
    }

    widget.full_redraw = false;
    self.text_first_diff = null;
}

fn drawBitmap(self: *const TextBox, draw_context: *const DrawContext, glyph_area: Rect, bitmap: anytype) void {
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

fn setFontSize(self: *const TextBox, draw_context: *const DrawContext) void {
    const freetype = FreeTypeContext.freetype;
    const area = self.widget.area;

    switch (self.scaling) {
        .normal => {
            //freetype_context.setFontSize(&draw_context.output_context, 24);
            freetype_context.setFontPixelSize(&draw_context.output_context, area.height, 0);
        },
        .zero => {
            const font_face = freetype_context.font_face;
            // start by scaling how normally,
            freetype_context.setFontPixelSize(&draw_context.output_context, area.height, 0);

            // then find how much bigger the zero glyph can be.
            {
                const err = freetype.FT_Load_Char(freetype_context.font_face, '0', freetype.FT_LOAD_COMPUTE_METRICS);
                freetype_utils.errorAssert(err, "Failed to load '0' glyph", .{});
            }

            const metrics = font_face.*.glyph.*.metrics;
            const height = area.height << 6;

            const new_pixel_size: u31 = @intCast(((((height * height) / @as(u63, @intCast(metrics.height))) >> 6)));

            freetype_context.setFontPixelSize(&draw_context.output_context, new_pixel_size, 0);

            {
                const err = freetype.FT_Load_Char(freetype_context.font_face, '0', freetype.FT_LOAD_COMPUTE_METRICS);
                freetype_utils.errorAssert(err, "Failed to load '0' glyph", .{});
            }

            log.debug("glyph height: {}, area height: {}", .{ font_face.*.glyph.*.metrics.height, area.height });
            assert(font_face.*.glyph.*.metrics.height >> 6 <= area.height);
        },
        .max => {},
    }
}

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
    allocator: Allocator,

    area: Rect,

    /// Text has to be alive for the lifetime of the widget.
    text: []const u8,

    text_color: Color,
    outline_color: Color,
    background_color: Color,

    scaling: ScalingType,
};

pub fn new(args: NewArgs) Allocator.Error!*Widget {
    const text_box = try args.allocator.create(TextBox);
    text_box.* = .{
        .text = TextBox.TextArray.fromSlice(args.text) catch @panic("Text too large for text box."),

        .text_color = args.text_color,
        .outline_color = args.outline_color,
        .background_color = args.background_color,

        .scaling = args.scaling,

        .widget = .{
            .vtable = &.{
                .draw = &TextBox.draw,
                //.update = &TextBox.update,

                .deinit = &TextBox.deinit,
            },
            .area = args.area,
        },
    };

    return &text_box.widget;
}

const drawing = @import("drawing.zig");
const Widget = drawing.Widget;
const Rect = drawing.Rect;

const DrawContext = @import("DrawContext.zig");
const FreeTypeContext = @import("FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;
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
