//! A Brightness widget poll the screen and display the brightness.

pub const Brightness = @This();

/// The brightness symbol to draw.
const brightness_symbol: u21 = unicode.utf8Decode("󰃞") catch unreachable;
/// Don't transform
const brightness_transform = Transform.identity;

/// The default brightness directory, public for Config.zig to use
pub const default_brightness_directory = "/sys/class/backlight/intel_backlight";

/// The file name of the full file.
const max_brightness_file_name = "max_brightness";

/// the file name of the charge file.
const current_brightness_file_name = "brightness";

/// The max length between all the file names.
const max_file_name = @max(max_brightness_file_name.len, current_brightness_file_name.len);

/// The background color.
background_color: Color,

/// The color of the icon.
brightness_color: Color,

/// How many pixels are filled on the progress bar
/// Should always be smaller than or equal to the progress area's width.
fill_pixels: Size,

/// the total area of the progress bar
progress_area: Rect,

/// File for the max brightness
max_file: std.fs.File,

/// File for the current brightness
current_file: std.fs.File,

/// The font size of the brightness symbol.
/// Should always be up to date with the area.
brightness_font_size: Size,

/// The width the brightness takes up.
/// Should always be up to date with the area.
brightness_width: Size,

/// The padding area to not put anything in.
padding: Padding,

/// The padding between the brightness and the progress_bar.
inner_padding: Size,
inner_padding_was_specified: bool,

/// The inner widget for dynamic dispatch and generic fields.
widget: Widget,

/// The arguments to build a new brightness
pub const NewArgs = struct {
    /// The area to contain the brightness.
    area: Rect,

    /// The background color.
    background_color: Color,

    /// The color of the icon.
    brightness_color: Color,

    /// The directory to look up all the brightness files in.
    brightness_directory: []const u8,

    /// The padding between the brightness and the progress_bar.
    /// If null, use default.
    inner_padding: ?Size = null,

    /// The general padding for each size.
    padding: Size,

    /// Overrides general padding the top side
    padding_north: ?Size = null,
    /// Overrides general padding the bottom side
    padding_south: ?Size = null,
    /// Overrides general padding the right side
    padding_east: ?Size = null,
    /// Overrides general padding the left side
    padding_west: ?Size = null,
};

/// Initializes the widget with the given arguments.
pub fn init(args: NewArgs) !Brightness {
    assert(args.brightness_directory.len > 0);

    const brightness_directory_should_add_sep = args.brightness_directory[args.brightness_directory.len - 1] != fs.path.sep;

    const path_length = args.brightness_directory.len + @intFromBool(brightness_directory_should_add_sep) + max_file_name;

    if (path_length > std.fs.max_path_bytes) {
        log.err("provided brightness directory makes path too long to be a valid path.", .{});
        // crash or not to crash, that is the question...
        return error.PathTooLong;
    }

    var brightness_path = BoundedArray(u8, std.fs.max_path_bytes){};

    // base directory path
    brightness_path.appendSliceAssumeCapacity(args.brightness_directory);
    if (brightness_directory_should_add_sep) brightness_path.appendAssumeCapacity(fs.path.sep);

    // the full file's name
    brightness_path.appendSliceAssumeCapacity(max_brightness_file_name);

    const max_file = std.fs.openFileAbsolute(brightness_path.slice(), .{}) catch |err| {
        log.warn("Failed to open Max Brightness File with: {s}", .{@errorName(err)});
        return error.MaxFileError;
    };
    errdefer max_file.close();

    // remove the full file's name, add the charge file's
    brightness_path.len -= @intCast(max_brightness_file_name.len);
    brightness_path.appendSliceAssumeCapacity(current_brightness_file_name);

    const current_file = std.fs.openFileAbsolute(brightness_path.slice(), .{}) catch |err| {
        log.warn("Failed to open Current Brightness File with: {s}", .{@errorName(err)});
        return error.CurrentFileError;
    };
    errdefer current_file.close();

    // undefined fields because they will set before used on draw or the immediate setArea.
    var self = Brightness{
        .background_color = args.background_color,

        .brightness_color = args.brightness_color,

        .brightness_font_size = undefined,
        .brightness_width = undefined,

        .fill_pixels = undefined,

        .progress_area = undefined,

        .max_file = max_file,
        .current_file = current_file,

        .padding = Padding.from(args),
        // if no inner padding was specified, it will be overridden before used.
        .inner_padding = args.inner_padding orelse undefined,
        .inner_padding_was_specified = args.inner_padding != null,

        .widget = .{
            .vtable = Widget.generateVTable(Brightness),

            // set to an empty area because if undefined it could do
            // something weird in setArea
            .area = .{
                .x = 0,
                .y = 0,
                .width = 0,
                .height = 0,
            },
        },
    };

    // set the area to find the progress area and everything.
    self.setArea(args.area);

    return self;
}

/// Reads a file that only contains an int.
fn readFileInt(comptime T: type, file: std.fs.File) !T {
    assert(@typeInfo(T) == .Int);
    assert(@typeInfo(T).Int.signedness == .unsigned);

    // get total possible number of digits the number could be, plus 1 for overflow saturation
    const digits = comptime math.log(T, 10, maxInt(T)) + 1;

    // set the files back so we can re-read the changes.
    try file.seekTo(0);

    var bytes = try file.reader().readBoundedBytes(digits);
    // remove any (unlikely) whitespace
    const str = mem.trim(u8, bytes.constSlice(), &ascii.whitespace);

    if (str.len == 0) return error.EmptyFile;

    return parseUnsigned(T, str, 10) catch |err| switch (err) {
        // if the number is too big, saturate it.
        error.Overflow => maxInt(T),
        error.InvalidCharacter => error.InvalidCharacter,
    };
}

/// Updates and draws what is needed
/// TODO: handle read errors
pub fn draw(self: *Brightness, draw_context: *DrawContext) !void {
    defer self.widget.full_redraw = false;

    const area_after_padding = self.widget.area.removePadding(self.padding) orelse return;

    var brightness_capacity = try readFileInt(u32, self.max_file);
    // if the charge is greater than capacity, saturate it.
    const brightness_charge = @min(try readFileInt(u32, self.current_file), brightness_capacity);

    // avoid divide by zero.
    // Do it after the brightness_charge so if capacity is zero, it will show the brightness as empty
    brightness_capacity = @max(brightness_capacity, 1);

    // a ratio of how full over maxInt(u8)
    const fill_ratio: u8 = @intCast(@as(u64, maxInt(u8)) * brightness_charge / brightness_capacity);

    // if the widget should to redraw
    const should_redraw = draw_context.full_redraw or self.widget.full_redraw;

    const inner_padding = Padding.uniform(self.inner_padding);
    const progress_area = self.progress_area.removePadding(inner_padding) orelse {
        // if the area is too small for a progress bar, don't draw it.
        if (should_redraw) {
            // if there is no area to put the progress, then don't.
            area_after_padding.drawArea(draw_context, self.background_color);
            self.drawBrightness(draw_context, area_after_padding, null, self.brightness_color);

            if (options.brightness_outlines) {
                self.widget.area.drawOutline(draw_context, colors.border);
            }

            draw_context.damage(area_after_padding);
        }
        return;
    };
    area_after_padding.assertContains(progress_area);

    const outer_progress_circle = Circle.largestCircle(self.progress_area);
    const progress_circle = Circle.largestCircle(progress_area);
    area_after_padding.assertContainsCircle(progress_circle);
    assert(meta.eql(progress_circle.boundingBox(), progress_area));

    const new_fill_pixels: Size = @intCast(@as(u64, brightness_charge) * progress_area.width / brightness_capacity);
    assert(new_fill_pixels <= progress_area.width);
    defer self.fill_pixels = new_fill_pixels;

    if (should_redraw) {
        area_after_padding.drawArea(draw_context, self.background_color);
        self.drawBrightness(draw_context, area_after_padding, null, self.brightness_color);

        outer_progress_circle.drawArea(draw_context, self.background_color);

        var to_draw = progress_area;
        to_draw.y += to_draw.height - new_fill_pixels;
        to_draw.height = new_fill_pixels;
        progress_area.assertContains(to_draw);

        progress_circle.drawAreaWithin(draw_context, to_draw, self.brightness_color);

        //area_after_padding.assertContains(to_draw);

        //to_draw.drawArea(draw_context, self.brightness_color);

        draw_context.damage(area_after_padding);

        if (options.brightness_outlines) {
            self.widget.area.drawOutline(draw_context, colors.love);
            area_after_padding.drawOutline(draw_context, colors.border);
            progress_area.drawOutline(draw_context, colors.gold);
        }
    } else switch (math.order(new_fill_pixels, self.fill_pixels)) {
        // add some
        .gt => {
            log.debug("gt: fill_ratio: {}/255", .{fill_ratio});
            // The area to add
            var to_draw = progress_area;
            to_draw.y += to_draw.height - new_fill_pixels;
            to_draw.height = new_fill_pixels - self.fill_pixels;

            progress_area.assertContains(to_draw);

            self.drawBrightness(draw_context, area_after_padding, to_draw, self.brightness_color);

            outer_progress_circle.drawAreaWithin(draw_context, to_draw, self.background_color);
            progress_circle.drawAreaWithin(draw_context, to_draw, self.brightness_color);
            draw_context.damage(to_draw);

            if (options.brightness_outlines) {
                progress_area.drawOutline(draw_context, colors.gold);
            }
        },
        // remove some
        .lt => {
            log.debug("lt: fill_ratio: {}/255", .{fill_ratio});

            // Draw the area to remove
            var to_draw = progress_area;
            to_draw.y += to_draw.height - self.fill_pixels;
            to_draw.height = self.fill_pixels - new_fill_pixels;

            progress_area.assertContains(to_draw);

            // re-draw everything else within that area so damage works correctly.
            self.drawBrightness(draw_context, area_after_padding, to_draw, self.brightness_color);
            outer_progress_circle.drawAreaWithin(draw_context, to_draw, self.background_color);
            progress_circle.drawAreaWithin(draw_context, to_draw, self.background_color);

            draw_context.damage(to_draw);

            if (options.brightness_outlines) {
                progress_area.drawOutline(draw_context, colors.gold);
            }
        },
        // do nothing
        .eq => {},
    }
}

/// Draw the brightness character itself.
fn drawBrightness(self: *const Brightness, draw_context: *DrawContext, area_after_padding: Rect, within: ?Rect, color: Color) void {
    freetype_context.drawChar(.{
        .draw_context = draw_context,

        .text_color = color,
        .area = area_after_padding,

        .font_size = self.brightness_font_size,

        .within = within,

        // used for debugging
        .bounding_box = options.brightness_outlines,
        .no_alpha = false,

        .transform = brightness_transform,

        .char = brightness_symbol,

        .hori_align = .center,
        .vert_align = .center,

        .width = .{ .fixed = self.brightness_width },
    });
}

/// Deinitializes the brightness widget.
pub fn deinit(self: *Brightness) void {
    self.current_file.close();
    self.max_file.close();
    self.* = undefined;
}

/// Sets the area of the brightness, and tells it to redraw.
/// This also re-calculates the brightness and charging, font_size and width
///     if the area changed (and there is some area after padding)
pub fn setArea(self: *Brightness, area: Rect) void {
    defer self.widget.area = area;
    defer self.widget.full_redraw = true;

    // if the size hasn't changed, then don't recalculate.
    if (meta.eql(area.dims(), self.widget.area.dims())) return;

    if (area.removePadding(self.padding)) |area_after_padding| {
        {
            const max = freetype_context.maximumFontSize(.{
                .transform = brightness_transform,
                .area = area_after_padding,
                .char = brightness_symbol,
                .scaling_fn = null,
            });

            self.brightness_font_size = max.font_size;
            self.brightness_width = max.width;
        }
        self.calculateProgressArea(area);
        area.assertContains(self.progress_area);
    }
}

/// Renders the bitmap of the brightness_symbol, then finds the inner box of the glyph for the progress bar.
/// If the glyph isn't the normal one, this function may do something wacky.
///
/// Update or at least test if the glyph isn't '󰃞 '
///
/// TODO: try to make this function simpler... or atleast shorter...
pub fn calculateProgressArea(self: *Brightness, full_area: Rect) void {
    // if the area is too small to even hold the widget, don't do any of this.
    const area = full_area.removePadding(self.padding) orelse return;

    const glyph = freetype_context.loadChar(brightness_symbol, .{
        .load_mode = .render,
        .font_size = self.brightness_font_size,
        .transform = brightness_transform,
    });
    const bitmap = glyph.bitmap_buffer.?;
    const bitmap_width = glyph.bitmap_width;
    const bitmap_height = glyph.bitmap_height;

    const alpha_max = math.maxInt(u8);

    const mid_height = bitmap_height / 2;
    const mid_width = bitmap_width / 2;

    const middle_row = bitmap[mid_height * bitmap_width ..][0..bitmap_width];

    // The inner left side of the glyph
    const left_side: Size = left_side: {
        const glyph_start = mem.indexOfScalar(u8, middle_row, alpha_max) orelse @panic("Invalid brightness symbol");

        for (middle_row[glyph_start..], 0..) |alpha, idx| {
            if (alpha < alpha_max) {
                break :left_side @intCast(idx + 1);
            }
        }
        unreachable;
    };

    // the inner right side of the glyph
    const right_side: Size = right_side: {
        const glyph_end = mem.lastIndexOfScalar(u8, middle_row, alpha_max) orelse @panic("Invalid brightness symbol");

        var reverse_iter = mem.reverseIterator(middle_row[0..glyph_end]);

        var idx: Size = @intCast(glyph_end);
        while (reverse_iter.next()) |alpha| : (idx -= 1) {
            if (alpha < alpha_max) {
                break :right_side @intCast(idx);
            }
        }
        unreachable;
    };

    // the inner top size of the glyph
    const top_side: Size = top_side: {
        const glyph_start = glyph_start: {
            var idx: Size = 0;
            while (idx < bitmap_height) : (idx += 1) {
                if (bitmap[idx * bitmap_width + mid_width] == alpha_max)
                    break :glyph_start idx;
            }
            unreachable;
        };

        var idx: Size = glyph_start;
        while (idx < bitmap_height) : (idx += 1) {
            if (bitmap[idx * bitmap_width + mid_width] < alpha_max) {
                break :top_side idx;
            }
        }

        unreachable;
    };

    // the inner bottom side of the glyph
    const bottom_side: Size = bottom_side: {
        const glyph_end = glyph_end: {
            var idx: Size = bitmap_height - 1;
            while (idx >= 0) : (idx -= 1) {
                if (bitmap[idx * bitmap_width + mid_width] == alpha_max)
                    break :glyph_end idx;
            }
            unreachable;
        };

        var idx: Size = glyph_end;
        while (idx >= 0) : (idx -= 1) {
            if (bitmap[idx * bitmap_width + mid_width] < alpha_max) {
                break :bottom_side idx + 1;
            }
        }

        unreachable;
    };

    const glyph_area = area.center(.{ .x = bitmap_width, .y = bitmap_height });

    const progress_area = Rect{
        .x = glyph_area.x + left_side,
        .y = glyph_area.y + top_side,
        .width = right_side - left_side,
        .height = bottom_side - top_side,
    };
    self.progress_area = progress_area;

    area.assertContains(progress_area);
    assert(self.brightness_width >= progress_area.width); // it shouldn't be larger than the brightness

    if (!self.inner_padding_was_specified) {
        // this padding looks pretty nice.
        self.inner_padding = math.log2_int(Size, progress_area.height) -| 1;
    }
}

/// returns the width the brightness will take up.
pub fn getWidth(self: *Brightness) Size {
    return self.brightness_width + self.padding.east + self.padding.west;
}

test {
    std.testing.refAllDecls(@This());
}

const options = @import("options");

const FreeTypeContext = @import("FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;

const DrawContext = @import("DrawContext.zig");

const drawing = @import("drawing.zig");
const Transform = drawing.Transform;
const Padding = drawing.Padding;
const Widget = drawing.Widget;
const Circle = drawing.Circle;
const Point = drawing.Point;
const Rect = drawing.Rect;
const Size = drawing.Size;

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const ascii = std.ascii;
const unicode = std.unicode;

const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const parseUnsigned = std.fmt.parseUnsigned;

const log = std.log.scoped(.Brightness);
