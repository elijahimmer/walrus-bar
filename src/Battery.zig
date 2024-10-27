//! A battery widget poll the battery and display it's charge.

pub const Battery = @This();

/// The battery symbol to draw.
const battery_symbol: u21 = unicode.utf8Decode("") catch unreachable;
/// How quickly the critical animation will go.
/// 8 is pretty quick.
const critical_animation_speed: u4 = 8;

/// The default battery directory, public for Config.zig to use
pub const default_battery_directory = "/sys/class/power_supply/BAT0";

/// The file name of the full file.
const full_file_name = "energy_full";

/// the file name of the charge file.
const charge_file_name = "energy_now";

/// The file name of the status file.
const status_file_name = "status";

/// The max length between all the file names.
const max_file_name = @max(full_file_name.len, charge_file_name.len, status_file_name.len);

/// The maximum length a battery status message can be.
const max_status_length = 64;

/// The background color.
background_color: Color,

/// The color to display when the battery is full.
full_color: Color,

/// The color to display when the battery is charging.
charging_color: Color,

/// The color to display when the battery is discharging.
/// So anytime it is not plugged in and at a modest to high charge.
discharging_color: Color,

/// The color to display when the battery is critically low.
critical_color: Color,

/// The critical blink animation tracker.
critical_animation_percentage: u8 = 0,

/// The color to display when the battery is low.
warning_color: Color,

/// The color draw the battery.
/// Changes depending on percent and status.
fill_color: Color,

/// How many pixels are filled on the progress bar
/// Should always be smaller than or equal to the progress area's width.
fill_pixels: u31,

/// the total area of the progress bar
progress_area: Rect,

/// File for the battery status strings
status_file: std.fs.File,

/// File for the current energy level
charge_file: std.fs.File,

/// File for the full energy level
full_file: std.fs.File,

/// The font size of the battery symbol.
/// Should always be up to date with the area.
battery_font_size: u31,

/// The width the battery takes up.
/// Should always be up to date with the area.
battery_width: u31,

/// The padding area to not put anything in.
padding: Padding,

/// The inner widget for dynamic dispatch and generic fields.
widget: Widget,

/// The arguments to build a new Battery
pub const NewArgs = struct {
    /// The area to contain the battery.
    area: Rect,

    /// The background color of the battery.
    background_color: Color,

    /// The color to display when the battery is full.
    full_color: Color,

    /// The color to display when the battery is charging.
    charging_color: Color,

    /// The color to display when the battery is discharging.
    /// So anytime it is not plugged in and at a modest to high charge.
    discharging_color: Color,

    /// The color to display when the battery is critically low.
    critical_color: Color,

    /// The color to display when the battery is low.
    warning_color: Color,

    /// The directory to look up all the battery files in.
    battery_directory: []const u8,

    /// The general padding for each size.
    padding: u16 = 0,

    /// Overrides general padding the top side
    padding_north: ?u16 = null,
    /// Overrides general padding the bottom side
    padding_south: ?u16 = null,
    /// Overrides general padding the right side
    padding_east: ?u16 = null,
    /// Overrides general padding the left side
    padding_west: ?u16 = null,
};

/// Allocates the Battery and returns the inner Widget.
pub fn newWidget(allocator: Allocator, args: NewArgs) !*Widget {
    const battery = try allocator.create(Battery);

    battery.* = try Battery.init(args);

    return &battery.widget;
}

/// Initializes the widget with the given arguments.
pub fn init(args: NewArgs) !Battery {
    assert(args.battery_directory.len > 0);

    const battery_directory_should_add_sep = args.battery_directory[args.battery_directory.len - 1] != fs.path.sep;

    const path_length = args.battery_directory.len + @intFromBool(battery_directory_should_add_sep) + max_file_name;

    if (path_length > std.fs.max_path_bytes) {
        log.err("provided battery directory and/or battery name makes path too long to be a valid path.", .{});
        return error.PathTooLong;
    }

    var battery_path = BoundedArray(u8, std.fs.max_path_bytes){};

    // base directory path
    battery_path.appendSliceAssumeCapacity(args.battery_directory);
    if (battery_directory_should_add_sep) battery_path.appendAssumeCapacity(fs.path.sep);

    // the full file's name
    battery_path.appendSliceAssumeCapacity(full_file_name);

    const full_file = std.fs.openFileAbsolute(battery_path.slice(), .{}) catch |err| {
        log.err("Failed to open Battery Full File with: {s}", .{@errorName(err)});
        return error.FullFileError;
    };
    errdefer full_file.close();

    // remove the full file's name, add the charge file's
    battery_path.len -= @intCast(full_file_name.len);
    battery_path.appendSliceAssumeCapacity(charge_file_name);

    const charge_file = std.fs.openFileAbsolute(battery_path.slice(), .{}) catch |err| {
        log.err("Failed to open Battery Charge File with: {s}", .{@errorName(err)});
        return error.ChargeFileError;
    };
    errdefer full_file.close();

    // remove the charge file, add status file.
    battery_path.len -= @intCast(charge_file_name.len);
    battery_path.appendSliceAssumeCapacity(status_file_name);

    const status_file = std.fs.openFileAbsolute(battery_path.slice(), .{}) catch |err| {
        log.err("Failed to open Battery Status File with: {s}", .{@errorName(err)});
        return error.StatusFileError;
    };
    errdefer full_file.close();

    var self = Battery{
        .background_color = args.background_color,

        .discharging_color = args.discharging_color,
        .charging_color = args.charging_color,
        .critical_color = args.critical_color,
        .warning_color = args.warning_color,
        .full_color = args.full_color,

        .fill_color = undefined,
        .battery_font_size = undefined,
        .battery_width = undefined,

        .fill_pixels = undefined,

        .progress_area = undefined,

        .status_file = status_file,
        .charge_file = charge_file,
        .full_file = full_file,

        .padding = Padding.from(args),

        .widget = .{
            .vtable = &.{
                .draw = &Battery.drawWidget,
                .deinit = &Battery.deinitWidget,
                .setArea = &Battery.setAreaWidget,
                .getWidth = &Battery.getWidthWidget,
            },

            .area = undefined,
        },
    };

    // set the area to find the progress area and everything.
    self.setArea(args.area);

    return self;
}

/// draw translation layer for widget calls.
fn drawWidget(widget: *Widget, draw_context: *DrawContext) !void {
    const self: *Battery = @fieldParentPtr("widget", widget);

    try self.draw(draw_context);
}

/// Reads a file that only contains an int.
fn readFileInt(comptime T: type, file: std.fs.File) !T {
    assert(@typeInfo(T) == .Int);
    assert(@typeInfo(T).Int.signedness == .unsigned);
    const digits = comptime math.log(T, 10, maxInt(T));

    try file.seekTo(0);

    var bytes = try file.reader().readBoundedBytes(digits);
    const str = mem.trim(u8, bytes.constSlice(), &ascii.whitespace);

    if (str.len == 0) return error.EmptyFile;

    return parseUnsigned(T, str, 10) catch |err| switch (err) {
        // if the number is too big, saturate it.
        error.Overflow => maxInt(T),
        error.InvalidCharacter => error.InvalidCharacter,
    };
}

/// Returns the color the battery should be.
/// fill_ratio should be the amount of charge,
///     maxInt(u8) meaning 100% full, 0 meaning 0% full
fn getProgressColor(self: *Battery, fill_ratio: u8) !Color {
    const max_int = maxInt(u8);

    try self.status_file.seekTo(0);

    const status_bb = try self.status_file.reader().readBoundedBytes(max_status_length);
    const status = mem.trim(u8, status_bb.constSlice(), &ascii.whitespace);

    // TODO am I missing any status codes besides for "discharging"?
    if (ascii.eqlIgnoreCase(status, "charging")) return self.charging_color;
    if (ascii.eqlIgnoreCase(status, "full")) return self.full_color;

    // if it is not charging, and it is close to full, assume it is full.
    if (ascii.eqlIgnoreCase(status, "not charging") and fill_ratio > max_int * 9 / 10) return self.full_color;

    if (!ascii.eqlIgnoreCase(status, "discharging")) {
        log.warn("Unknown battery status: {s}", .{status});
    }

    if (fill_ratio < max_int * 3 / 20) {
        self.critical_animation_percentage +%= critical_animation_speed;

        return self.critical_color.blend(self.warning_color, self.critical_animation_percentage);
    }
    if (fill_ratio < max_int * 6 / 20) return self.warning_color;

    return self.discharging_color;
}

/// Updates and draws what is needed
/// TODO: handle read errors
pub fn draw(self: *Battery, draw_context: *DrawContext) !void {
    const area_after_padding = self.widget.area.removePadding(self.padding) orelse return;
    var battery_capacity = try readFileInt(u31, self.full_file);
    const battery_charge = @min(try readFileInt(u31, self.charge_file), battery_capacity);

    // avoid divide by zero.
    // Do it after the battery_charge so if capacity is zero, it will show the battery as empty
    battery_capacity = @max(battery_capacity, 1);

    const new_fill_pixels: u31 = @intCast(@as(u64, battery_charge) * self.progress_area.width / battery_capacity);
    assert(new_fill_pixels <= self.progress_area.width);
    defer self.fill_pixels = new_fill_pixels;

    const fill_ratio: u8 = @intCast(@as(u64, maxInt(u8)) * battery_charge / battery_capacity);

    const color: Color = try self.getProgressColor(fill_ratio);
    defer self.fill_color = color;

    const color_changed = @as(u32, @bitCast(color)) != @as(u32, @bitCast(self.fill_color));

    // if the widget should to redraw, or if the color changed
    const should_redraw = draw_context.full_redraw or self.widget.full_redraw or color_changed;

    if (should_redraw) {
        log.debug("fill_ratio: {}/255", .{fill_ratio});

        self.widget.area.drawArea(draw_context, self.background_color);

        self.drawBattery(draw_context, area_after_padding, color);

        var progress_area = self.progress_area;
        progress_area.width = new_fill_pixels;
        progress_area.drawArea(draw_context, color);
    } else switch (math.order(new_fill_pixels, self.fill_pixels)) {
        // add some
        .gt => {
            log.debug("fill_ratio: {}/255", .{fill_ratio});
            var progress_area = self.progress_area;
            progress_area.x += self.fill_pixels;
            progress_area.width = new_fill_pixels - self.fill_pixels;

            progress_area.drawArea(draw_context, color);
        },
        // remove some
        .lt => {
            log.debug("fill_ratio: {}/255", .{fill_ratio});
            var progress_area = self.progress_area;
            progress_area.x += new_fill_pixels;
            progress_area.width = self.fill_pixels - new_fill_pixels;

            progress_area.drawArea(draw_context, self.background_color);
        },
        // do nothing
        .eq => {},
    }
}

/// Draw the battery character itself.
fn drawBattery(self: *Battery, draw_context: *DrawContext, area_after_padding: Rect, color: Color) void {
    freetype_context.drawChar(.{
        .draw_context = draw_context,

        .text_color = color,
        .area = area_after_padding,

        .font_size = self.battery_font_size,

        .outline = false,

        .char = battery_symbol,

        .hori_align = .center,
        .vert_align = .center,

        .width = .{ .fixed = area_after_padding.width },
    });
}

/// Deallocates and deinitializes the battery that was made with newWidget
fn deinitWidget(widget: *Widget, allocator: Allocator) void {
    const self: *Battery = @fieldParentPtr("widget", widget);

    self.deinit();

    allocator.destroy(self);
    self.* = undefined;
}

/// Deinitializes the battery widget.
pub fn deinit(self: *Battery) void {
    self.status_file.close();
    self.charge_file.close();
    self.full_file.close();
    self.* = undefined;
}

/// Widget translation function to set area.
fn setAreaWidget(widget: *Widget, area: Rect) void {
    const self: *Battery = @fieldParentPtr("widget", widget);

    self.setArea(area);
}

/// Sets the area of the battery, and tells it to redraw.
/// This also re-calculates the battery_font_size and battery_width
///     if the area changed (and there is some area after padding)
pub fn setArea(self: *Battery, area: Rect) void {
    if (meta.eql(area, self.widget.area)) return;
    self.widget.area = area;
    self.widget.full_redraw = true;

    if (area.removePadding(self.padding)) |area_after_padding| {
        // TODO: don't recalculate if you won't be able to make the size different.
        const max = freetype_context.maximumFontSize(battery_symbol, area_after_padding);

        self.battery_font_size = max.font_size;
        self.battery_width = max.width;

        self.calculateProgressArea();
    }
}

/// Renders the bitmap of the battery_symbol, then finds the inner box of the glyph for the progress bar.
/// If the glyph isn't the normal one, this function may do something wacky.
///
/// Update or at least test if the glyph isn't ' '
///
/// TODO: try to make this function simpler... or atleast shorter...
pub fn calculateProgressArea(self: *Battery) void {
    const glyph = freetype_context.loadChar(battery_symbol, self.battery_font_size, .render);
    const bitmap = glyph.bitmap_buffer.?;

    const alpha_max = math.maxInt(u8);

    const mid_height = glyph.bitmap_height / 2;
    const mid_width = glyph.bitmap_width / 2;

    const middle_row = bitmap[mid_height * glyph.bitmap_width ..][0..glyph.bitmap_width];

    // The inner left side of the glyph
    const left_side: u31 = left_side: {
        const glyph_start = mem.indexOfScalar(u8, middle_row, math.maxInt(u8)) orelse @panic("Invalid battery symbol");

        for (middle_row[glyph_start..], 0..) |alpha, idx| {
            if (alpha < alpha_max) {
                break :left_side @intCast(idx);
            }
        }
        unreachable;
    };

    // the inner right side of the glyph
    const right_side: u31 = right_side: {
        var glyph_end = mem.lastIndexOfScalar(u8, middle_row, math.maxInt(u8)) orelse @panic("Invalid battery symbol");

        var reverse_iter = mem.reverseIterator(middle_row[0..glyph_end]);

        while (reverse_iter.next()) |alpha| {
            if (alpha < alpha_max) {
                break :right_side @intCast(glyph_end);
            }
            glyph_end -= 1;
        }
        unreachable;
    };

    // the inner top size of the glyph
    const top_side: u31 = top_side: {
        const glyph_start = glyph_start: {
            var idx: usize = 0;
            while (idx < glyph.bitmap_height) : (idx += 1) {
                if (bitmap[idx * glyph.bitmap_width + mid_width] == alpha_max)
                    break :glyph_start idx;
            }
            unreachable;
        };

        var idx: usize = glyph_start;
        while (idx < glyph.bitmap_height) : (idx += 1) {
            if (bitmap[idx * glyph.bitmap_width + mid_width] < alpha_max) {
                break :top_side @intCast(idx);
            }
        }

        unreachable;
    };

    // the inner bottom side of the glyph
    const bottom_side: u31 = bottom_side: {
        const glyph_end = glyph_end: {
            var idx: usize = glyph.bitmap_height - 1;
            while (idx >= 0) : (idx -= 1) {
                if (bitmap[idx * glyph.bitmap_width + mid_width] == alpha_max)
                    break :glyph_end idx;
            }
            unreachable;
        };

        var idx: usize = glyph_end;
        while (idx >= 0) : (idx -= 1) {
            if (bitmap[idx * glyph.bitmap_width + mid_width] < alpha_max) {
                break :bottom_side @intCast(idx + 1);
            }
        }

        unreachable;
    };

    const progress_area = Rect{
        .x = self.widget.area.x + left_side + self.padding.west,
        .y = self.widget.area.y + top_side + self.padding.north,
        .width = right_side - left_side,
        .height = bottom_side - top_side,
    };

    log.debug("progress_area: {}, widget area: {}", .{ progress_area, self.widget.area });

    self.widget.area.assertContains(progress_area);

    self.progress_area = progress_area;
}

/// Widget translation function to get the battery's width
fn getWidthWidget(widget: *Widget) u31 {
    const self: *Battery = @fieldParentPtr("widget", widget);

    return self.getWidth();
}

/// returns the width the battery will take up.
pub fn getWidth(self: *Battery) u31 {
    return self.battery_width + self.padding.east + self.padding.west;
}

test {
    std.testing.refAllDecls(Battery);
}

const FreeTypeContext = @import("FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;

const DrawContext = @import("DrawContext.zig");

const drawing = @import("drawing.zig");
const Padding = drawing.Padding;
const Widget = drawing.Widget;
const Rect = drawing.Rect;

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const ascii = std.ascii;
const unicode = std.unicode;

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const parseUnsigned = std.fmt.parseUnsigned;

const log = std.log.scoped(.Battery);
