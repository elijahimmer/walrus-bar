pub const Battery = @This();

pub const battery_symbol: u21 = unicode.utf8Decode("") catch unreachable;
pub const battery_path: []const u8 = "/tmp/BAT0/"; //"/sys/class/power_supply/BAT0/";
pub const full_path: []const u8 = battery_path ++ "energy_full";
pub const charge_path: []const u8 = battery_path ++ "energy_now";
pub const status_path: []const u8 = battery_path ++ "status";

background_color: Color,

discharging_color: Color,
charging_color: Color,
critical_color: Color,
warning_color: Color,
full_color: Color,

fill_color: Color,
fill_pixels: u31,
progress_area: Rect,

status_file: std.fs.File,
charge_file: std.fs.File,
full_file: std.fs.File,

/// The font size of the battery symbol
/// Should always be up to date with the area
battery_font_size: u31,

/// The width the battery takes up.
/// Should always be up to date with the area
battery_width: u31,

padding: Padding,

widget: Widget,

pub const NewArgs = struct {
    area: Rect,

    background_color: Color,

    discharging_color: Color,
    charging_color: Color,
    critical_color: Color,
    warning_color: Color,
    full_color: Color,

    padding: u16 = 0,

    padding_north: ?u16 = null,
    padding_south: ?u16 = null,
    padding_east: ?u16 = null,
    padding_west: ?u16 = null,
};

pub fn newWidget(allocator: Allocator, args: NewArgs) !*Widget {
    const battery = try allocator.create(Battery);

    battery.* = try Battery.init(args);

    return &battery.widget;
}

pub fn init(args: NewArgs) !Battery {
    const full_file = std.fs.openFileAbsolute(full_path, .{}) catch |err| {
        log.err("Battery full file now found: {s}", .{@errorName(err)});
        return error.FullFileError;
    };
    const charge_file = std.fs.openFileAbsolute(charge_path, .{}) catch |err| {
        log.err("Battery charge file now found: {s}", .{@errorName(err)});
        return error.ChargeFileError;
    };
    const status_file = std.fs.openFileAbsolute(status_path, .{}) catch |err| {
        log.err("Battery charge file now found: {s}", .{@errorName(err)});
        return error.ChargeFileError;
    };

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

        .padding = .{
            .north = args.padding_north orelse args.padding,
            .south = args.padding_south orelse args.padding,
            .west = args.padding_west orelse args.padding,
            .east = args.padding_east orelse args.padding,
        },

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

    self.setArea(args.area);

    return self;
}

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

    return parseUnsigned(T, str, 10) catch |err| switch (err) {
        // if the number is tooDischarging big, saturate it.
        error.Overflow => maxInt(T),
        error.InvalidCharacter => return error.InvalidCharacter,
    };
}

const max_status_length = 64;

/// Returns the color the battery should be.
/// fill_ratio should be the amount of charge,
///     maxInt(u8) meaning 100% full, 0 meaning 0% full
fn getProgressColor(self: *const Battery, fill_ratio: u8) !Color {
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

    if (fill_ratio < max_int * 3 / 20) return self.critical_color;
    if (fill_ratio < max_int * 6 / 20) return self.warning_color;

    return self.discharging_color;
}

pub fn draw(self: *Battery, draw_context: *DrawContext) !void {
    const battery_capacity = try readFileInt(u31, self.full_file);
    const battery_charge = @min(try readFileInt(u31, self.charge_file), battery_capacity);

    const new_fill_pixels: u31 = @intCast(@as(u64, battery_charge) *| self.progress_area.width / battery_capacity);
    assert(new_fill_pixels <= self.progress_area.width);
    defer self.fill_pixels = new_fill_pixels;

    const fill_ratio: u8 = @intCast(maxInt(u8) * battery_charge / battery_capacity);

    const color: Color = try self.getProgressColor(fill_ratio);
    defer self.fill_color = color;

    // if the widget should to redraw, or if the color changed
    const should_redraw = draw_context.full_redraw or self.widget.full_redraw or !meta.eql(color, self.fill_color);

    if (should_redraw) {
        self.widget.area.drawArea(draw_context, self.background_color);

        if (self.widget.area.removePadding(self.padding)) |area_after_padding| {
            freetype_context.drawChar(.{
                .draw_context = draw_context,

                .text_color = color,
                .area = area_after_padding,

                .font_size = self.battery_font_size,

                .char = battery_symbol,

                .hori_align = .center,
                .vert_align = .center,

                .width = .{ .fixed = area_after_padding.width },
            });

            var progress_area = self.progress_area;
            progress_area.width = new_fill_pixels;

            self.progress_area.drawArea(draw_context, self.background_color);
            progress_area.drawArea(draw_context, color);
        }
    } else switch (math.order(new_fill_pixels, self.fill_pixels)) {
        .gt => {
            var progress_area = self.progress_area;
            progress_area.x += self.fill_pixels;
            progress_area.width = new_fill_pixels - self.fill_pixels;

            progress_area.drawArea(draw_context, color);
        },
        .lt => {
            var progress_area = self.progress_area;
            progress_area.x += new_fill_pixels;
            progress_area.width = self.fill_pixels - new_fill_pixels;

            progress_area.drawArea(draw_context, self.background_color);
        },
        // do nothing
        .eq => {},
    }
}

fn deinitWidget(widget: *Widget, allocator: Allocator) void {
    const self: *Battery = @fieldParentPtr("widget", widget);

    self.deinit();

    allocator.destroy(self);
    self.* = undefined;
}

pub fn deinit(self: *Battery) void {
    self.* = undefined;
}

fn setAreaWidget(widget: *Widget, area: Rect) void {
    const self: *Battery = @fieldParentPtr("widget", widget);

    self.setArea(area);
}

pub fn setArea(self: *Battery, area: Rect) void {
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

pub fn calculateProgressArea(self: *Battery) void {
    const glyph = freetype_context.loadChar(battery_symbol, self.battery_font_size, .render);
    const bitmap = glyph.bitmap_buffer.?;

    const alpha_max = math.maxInt(u8);

    const mid_height = glyph.bitmap_height / 2;
    const mid_width = glyph.bitmap_width / 2;

    const middle_row = bitmap[mid_height * glyph.bitmap_width ..][0..glyph.bitmap_width];

    const left_start: u31 = left_start: {
        const glyph_start = mem.indexOfScalar(u8, middle_row, math.maxInt(u8)) orelse @panic("Invalid battery symbol");

        for (middle_row[glyph_start..], 0..) |alpha, idx| {
            if (alpha < alpha_max) {
                break :left_start @intCast(idx);
            }
        }
        unreachable;
    };

    const left_end: u31 = left_end: {
        var glyph_end = mem.lastIndexOfScalar(u8, middle_row, math.maxInt(u8)) orelse @panic("Invalid battery symbol");

        var reverse_iter = mem.reverseIterator(middle_row[0..glyph_end]);

        while (reverse_iter.next()) |alpha| {
            if (alpha < alpha_max) {
                break :left_end @intCast(glyph_end);
            }
            glyph_end -= 1;
        }
        unreachable;
    };

    const top_start: u31 = top_start: {
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
                break :top_start @intCast(idx);
            }
        }

        unreachable;
    };

    const top_end: u31 = top_end: {
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
                break :top_end @intCast(idx + 1);
            }
        }

        unreachable;
    };

    // TODO: Maybe add padding so it looks like 
    const progress_area = Rect{
        .x = self.widget.area.x + left_start + self.padding.west,
        .y = self.widget.area.y + top_start + self.padding.north,
        .width = left_end - left_start,
        .height = top_end - top_start,
    };

    log.debug("progress_area: {}, widget area: {}", .{ progress_area, self.widget.area });

    self.widget.area.assertContains(progress_area);

    self.progress_area = progress_area;
}

fn getWidthWidget(widget: *Widget) u31 {
    const self: *Battery = @fieldParentPtr("widget", widget);

    return self.getWidth();
}

pub fn getWidth(self: *Battery) u31 {
    //return self.widget.area.height * 3 / 2;
    return self.battery_width + self.padding.east + self.padding.west;
}

test {
    std.testing.refAllDecls(Battery);
}

const DrawContext = @import("DrawContext.zig");

const drawing = @import("drawing.zig");
const Padding = drawing.Padding;
const Widget = drawing.Widget;
const Point = drawing.Point;
const Rect = drawing.Rect;

const FreeTypeContext = @import("FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const ascii = std.ascii;
const posix = std.posix;
const unicode = std.unicode;

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
const parseUnsigned = std.fmt.parseUnsigned;
const maxInt = std.math.maxInt;

const log = std.log.scoped(.Battery);
