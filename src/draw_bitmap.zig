pub const DrawBitmapArgs = struct {
    /// The glyph to draw
    glyph: *const FreeTypeContext.Glyph,

    /// Color to color glyph
    text_color: Color,

    /// Maximum area the glyph can take up
    max_area: Rect,

    /// The origin of the glyph (bottom right-ish)
    origin: Point,

    /// Mainly used for debugging.
    /// change dimensions if it is rotated right or left.
    /// Draw all pixels at full strength if there
    /// is any alpha in the bitmap.
    no_alpha: bool,
};

/// Draws a bitmap onto the draw_context's screen in the given max_area.
/// Any parts the extend past the max_area are not drawn.
/// This does not damage the draw_context, but assumes the caller will.
///
/// Returns immediately if the bitmap or the glyph's area have a zero height or width.
pub fn drawBitmap(draw_context: *const DrawContext, args: DrawBitmapArgs) void {
    assert(args.glyph.load_mode == .render);
    assert(args.glyph.bitmap_buffer != null);
    const glyph = args.glyph;

    if (glyph.bitmap_height == 0 or glyph.bitmap_width == 0) return;

    const glyph_area = Rect{
        .x = @intCast(args.origin.x + glyph.bitmap_left),
        .y = @intCast(args.origin.y -| glyph.bitmap_top),
        .width = glyph.bitmap_width,
        .height = glyph.bitmap_height,
    };

    if (glyph_area.width == 0 or glyph_area.height == 0) return;

    const used_area = args.max_area.intersection(glyph_area) orelse return;

    assert(used_area.width > 0);
    assert(used_area.height > 0);

    const y_start_local = used_area.y - glyph_area.y;

    for (y_start_local..y_start_local + used_area.height) |y_coord_local| {
        assert(y_coord_local <= glyph_area.height);
        const bitmap_row = glyph.bitmap_buffer.?[y_coord_local * glyph.bitmap_width ..][0..glyph.bitmap_width];

        const x_start_local = used_area.x - glyph_area.x;

        for (x_start_local..x_start_local + used_area.width) |x_coord_local| {
            assert(x_coord_local <= glyph_area.width);

            const point = Point{ .x = @intCast(x_coord_local), .y = @intCast(y_coord_local) };

            const alpha = bitmap_row[x_coord_local];

            if (args.no_alpha) {
                if (alpha > 0) glyph_area.putPixel(draw_context, point, args.text_color);
            } else {
                glyph_area.putComposite(
                    draw_context,
                    point,
                    args.text_color.withAlpha(alpha),
                );
            }
        }
    }
}

const DrawContext = @import("DrawContext.zig");
const FreeTypeContext = @import("FreeTypeContext.zig");

const drawing = @import("drawing.zig");
const Point = drawing.Point;
const Size = drawing.Size;
const Rect = drawing.Rect;

const colors = @import("colors.zig");
const Color = colors.Color;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
