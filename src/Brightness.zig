//! A Brightness widget poll the screen and display the brightness.

pub const Brightness = @This();

/// The brightness symbol to draw.
const brightness_symbol: u21 = '󰃞';

/// Don't transform
const brightness_transform = Transform.identity;

pub const BrightnessConfig = struct {
    pub const directory_comment = "The directory the battery is in.";

    pub const max_brightness_file_name_comment = "The file name of the max brightness file.";
    pub const current_brightness_file_name_comment = "The file name of the current brightness file.";

    pub const scroll_ticks_comment = "The number of scroll ticks to get from 0 to 100% brightness.";

    pub const color_comment = "The icons's color";
    pub const background_color_comment = "The background color.";

    pub const padding_comment = "The general padding for each size.";

    pub const padding_north_comment = "Overrides general padding the top side";
    pub const padding_south_comment = "Overrides general padding the bottom side";
    pub const padding_east_comment = "Overrides general padding the right side";
    pub const padding_west_comment = "Overrides general padding the left side";

    pub const inner_padding_comment = "The padding between the battery and the progress_bar.";

    directory: Config.Path = Config.Path.fromSlice("/sys/class/backlight/intel_backlight") catch unreachable,

    max_brightness_file_name: []const u8 = "max_brightness",
    current_brightness_file_name: []const u8 = "brightness",

    scroll_ticks: u8 = 100,

    color: Color = colors.iris,
    background_color: Color = colors.surface,

    padding: Size = 0,

    padding_north: ?Size = null,
    padding_south: ?Size = null,
    padding_east: ?Size = null,
    padding_west: ?Size = null,

    inner_padding: ?Size = null,
};

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
max_file: fs.File,

/// File for the current brightness
current_file: fs.File,

/// whether or not the current_file was opened as writeable.
current_file_writeable: bool,

/// The font size of the brightness symbol.
/// Should always be up to date with the area.
brightness_font_size: Size,

/// The width the brightness takes up.
/// Should always be up to date with the area.
brightness_width: Size,

/// the number of total scroll ticks to get from 0% to 100% brightness
scroll_ticks: u8,

/// The padding area to not put anything in.
padding: Padding,

/// The padding between the brightness and the progress_bar.
inner_padding: Size,
inner_padding_was_specified: bool,

/// The inner widget for dynamic dispatch and generic fields.
widget: Widget,

/// Initializes the widget with the given arguments.
pub fn init(area: Rect, config: BrightnessConfig) !Brightness {
    const directory = config.directory.constSlice();
    assert(directory.len > 0);

    const brightness_directory_should_add_sep = directory[directory.len - 1] != fs.path.sep;

    const max_file_name = @max(config.max_brightness_file_name.len, config.current_brightness_file_name.len);

    const path_length = directory.len + @intFromBool(brightness_directory_should_add_sep) + max_file_name;

    if (path_length > fs.max_path_bytes) {
        log.err("provided brightness directory makes path too long to be a valid path.", .{});
        // crash or not to crash, that is the question...
        return error.PathTooLong;
    }

    var brightness_path = BoundedArray(u8, fs.max_path_bytes){};

    // base directory path
    brightness_path.appendSliceAssumeCapacity(directory);
    if (brightness_directory_should_add_sep) brightness_path.appendAssumeCapacity(fs.path.sep);

    // the full file's name
    brightness_path.appendSliceAssumeCapacity(config.max_brightness_file_name);

    const max_file = fs.openFileAbsolute(brightness_path.slice(), .{}) catch |err| {
        log.warn("Failed to open Max Brightness File with: {s}", .{@errorName(err)});
        return error.MaxFileError;
    };
    errdefer max_file.close();

    // remove the full file's name, add the charge file's
    brightness_path.len -= @intCast(config.max_brightness_file_name.len);
    brightness_path.appendSliceAssumeCapacity(config.current_brightness_file_name);

    var current_file_writeable = true;
    const current_file = fs.openFileAbsolute(brightness_path.slice(), .{ .mode = .read_write }) catch |rw_err| current_file: {
        switch (rw_err) {
            error.AccessDenied => {
                // try to open file without write permissions
                const file = fs.openFileAbsolute(brightness_path.slice(), .{ .mode = .read_only }) catch |read_err| {
                    log.warn("Failed to open Current Brightness File with: {s}", .{@errorName(read_err)});
                    return error.CurrentFileError;
                };
                current_file_writeable = false;
                break :current_file file;
            },
            else => {
                log.warn("Failed to open Current Brightness File with: {s}", .{@errorName(rw_err)});
                return error.CurrentFileError;
            },
        }
    };
    errdefer current_file.close();

    // undefined fields because they will set before used on draw or the immediate setArea.
    var self = Brightness{
        .background_color = config.background_color,

        .brightness_color = config.color,

        .brightness_font_size = undefined,
        .brightness_width = undefined,

        .fill_pixels = undefined,

        .progress_area = undefined,

        .max_file = max_file,
        .current_file = current_file,
        .current_file_writeable = current_file_writeable,

        .padding = .{
            .north = config.padding_north orelse config.padding,
            .south = config.padding_south orelse config.padding,
            .east = config.padding_east orelse config.padding,
            .west = config.padding_west orelse config.padding,
        },

        // if no inner padding was specified, it will be overridden before used.
        .inner_padding = config.inner_padding orelse undefined,
        .inner_padding_was_specified = config.inner_padding != null,

        .scroll_ticks = config.scroll_ticks,

        .widget = .{
            .vtable = Widget.generateVTable(Brightness),

            // set to an empty area because if undefined it could do
            // something weird in setArea
            .area = Rect.ZERO,
        },
    };

    // set the area to find the progress area and everything.
    self.setArea(area);

    return self;
}

/// Reads a file that only contains an int.
fn readFileInt(comptime T: type, file: fs.File) !T {
    const type_info = @typeInfo(T);
    assert(type_info == .Int);

    const int_bits = type_info.Int.bits - @intFromBool(type_info.Int.signedness == .signed);

    const UnsignedType = @Type(.{ .Int = .{
        .bits = int_bits,
        .signedness = .unsigned,
    } });

    // get total possible number of digits the number could be, plus 1 for overflow saturation
    const digits = comptime math.log(UnsignedType, 10, (1 << int_bits) - 1) + 1;

    // set the files back so we can re-read the changes.
    try file.seekTo(0);

    var bytes = try file.reader().readBoundedBytes(digits);
    // remove any (unlikely) whitespace
    const str = mem.trim(u8, bytes.constSlice(), &ascii.whitespace);

    if (str.len == 0) return error.EmptyFile;

    return parseInt(T, str, 10) catch |err| switch (err) {
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

    var brightness_max = readFileInt(u32, self.max_file) catch |err| {
        log.warn("Failed to read Brightness Capacity", .{});
        return err;
    };
    // if the charge is greater than capacity, saturate it.
    const brightness_now = @min(try readFileInt(u32, self.current_file), brightness_max);

    // avoid divide by zero.
    // Do it after the brightness_charge so if capacity is zero, it will show the brightness as empty
    brightness_max = @max(brightness_max, 1);

    // a ratio of how full over maxInt(u8)
    const fill_ratio: u8 = @intCast(@as(u64, maxInt(u8)) * brightness_now / brightness_max);

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

    const new_fill_pixels: Size = @intCast(@as(u64, brightness_now) * progress_area.width / brightness_max);
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

pub fn scroll(self: *const Brightness, axis: Axis, discrete: i32) void {
    if (axis != .vertical_scroll) return;
    // if you cannot write to the file to set it, don't even calculate it.
    if (!self.current_file_writeable) return;

    var brightness_max = readFileInt(u32, self.max_file) catch |err| {
        log.warn("Failed to set brightness. Could not get max brightness with error: {s}", .{@errorName(err)});
        return;
    };
    const raw_brightness_current = readFileInt(u32, self.current_file) catch |err| {
        log.warn("Failed to set brightness. Could not get current brightness with error: {s}", .{@errorName(err)});
        return;
    };
    const brightness_current = @min(raw_brightness_current, brightness_max);

    brightness_max = @max(brightness_max, 1);

    const scroll_delta: i32 = @intCast(brightness_max / self.scroll_ticks);

    const raw_new_brightness = @as(i32, @intCast(brightness_current)) -| (discrete * scroll_delta);
    const new_brightness: u32 = @min(@as(u32, @intCast(@max(0, raw_new_brightness))), brightness_max);

    const digits = comptime math.log(u32, 10, maxInt(u32)) + 1;

    var digit_numbers: [digits]u8 = undefined;

    const bytes = std.fmt.formatIntBuf(&digit_numbers, new_brightness, 10, .lower, .{});

    self.current_file.seekTo(0) catch |err| {
        log.warn("Failed to seek to file start with error: {s}", .{@errorName(err)});
        return;
    };

    const written_bytes = self.current_file.write(digit_numbers[0..bytes]) catch |err| {
        log.warn("Failed to set brightness. Failed to write to brightness file with error: {s}", .{@errorName(err)});
        return;
    };

    self.current_file.setEndPos(written_bytes) catch |err| {
        log.warn("Failed to set file end pos, brightness data is likely wrong. error: {s}", .{@errorName(err)});
        return;
    };

    if (written_bytes != bytes) {
        log.warn("Failed to write entire number to brightness file.", .{});
        return;
    }
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

const seat_utils = @import("seat_utils.zig");
const Axis = seat_utils.Axis;

const colors = @import("colors.zig");
const Color = colors.Color;

const Config = @import("Config.zig");

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
const parseInt = std.fmt.parseInt;

const log = std.log.scoped(.Brightness);
