//! The main container that holds all of the widgets

pub const RootContainer = @This();

area: Rect,
last_motion: ?Point = null,

// TODO: Remove these widgets and make a separate container struct for them.
workspaces: if (has_workspaces) ?Workspaces else void = if (has_workspaces) null else {},
clock: if (has_clock) ?Clock else void = if (has_clock) null else {},
battery: if (has_battery) ?Battery else void = if (has_battery) null else {},
brightness: if (has_brightness) ?Brightness else void = if (has_brightness) null else {},

const has_workspaces = !options.workspaces_disable;
const has_clock = !options.clock_disable;
const has_battery = !options.battery_disable;
const has_brightness = !options.brightness_disable;

pub fn deinit(self: *RootContainer) void {
    if (has_workspaces) if (self.workspaces) |*w| w.deinit();
    if (has_clock) if (self.clock) |*w| w.deinit();
    if (has_battery) if (self.battery) |*w| w.deinit();
    if (has_brightness) if (self.brightness) |*w| w.deinit();
}

pub fn setArea(self: RootContainer, area: Rect) void {
    _ = self;
    _ = area;
    @panic("unimplemented");
}

pub fn getWidth(self: RootContainer) Size {
    _ = self;
    @panic("unimplemented");
}

pub fn draw(self: *RootContainer, draw_context: *DrawContext) !void {
    inline for (.{ "workspaces", "clock", "battery", "brightness" }) |name| {
        if (@TypeOf(@field(self, name)) == void) continue;

        if (@field(self, name)) |*w| {
            if (@TypeOf(w.*) != void) {
                draw_context.current_area = w.widget.area;
                w.widget.draw(draw_context) catch |err| log.warn("Drawing of '{s}' failed with: '{s}'", .{ name, @errorName(err) });
            }
        }
    }
}

pub fn scroll(self: *RootContainer, axis: Axis, discrete: i32) void {
    assert(self.last_motion != null);
    self.area.assertContainsPoint(self.last_motion.?);

    inline for (.{ "workspaces", "clock", "battery", "brightness" }) |widget_name| {
        if (@TypeOf(@field(self, widget_name)) == void) continue;
        if (@field(self, widget_name)) |*widget| {
            const area = widget.widget.area;
            if (area.containsPoint(self.last_motion.?)) widget.widget.scroll(axis, discrete);
        }
    }
}

pub fn motion(self: *RootContainer, point: Point) void {
    self.area.assertContainsPoint(point);
    if (self.last_motion) |lm| self.area.assertContainsPoint(lm);

    const last_motion = self.last_motion;
    defer self.last_motion = point;

    inline for (.{ "workspaces", "clock", "battery", "brightness" }) |widget_name| {
        if (@TypeOf(@field(self, widget_name)) == void) continue;
        if (@field(self, widget_name)) |*widget| {
            const area = widget.widget.area;
            if (last_motion) |lm| {
                if (area.containsPoint(lm) and !area.containsPoint(point)) widget.widget.leave();
                if (!area.containsPoint(lm) and area.containsPoint(point)) widget.widget.motion(point);
            }
            if (area.containsPoint(point)) widget.widget.motion(point);
        }
    }
}

/// asserts the it has a valid a last motion.
pub fn leave(self: *RootContainer) void {
    assert(self.last_motion != null);
    self.area.assertContainsPoint(self.last_motion.?);
    defer self.last_motion = null;

    var left = false;
    inline for (.{ "workspaces", "clock", "battery", "brightness" }) |widget_name| {
        if (@TypeOf(@field(self, widget_name)) == void) continue;
        if (@field(self, widget_name)) |*widget| {
            if (widget.widget.area.containsPoint(self.last_motion.?)) {
                // make sure no widgets overlap
                assert(!left);
                left = true;
                widget.widget.leave();
            }
        }
    }
}

/// asserts the it has a valid a last motion.
pub fn click(self: *RootContainer, button: MouseButton) void {
    assert(self.last_motion != null);
    self.area.assertContainsPoint(self.last_motion.?);

    var clicked = false;
    inline for (.{ "workspaces", "clock", "battery", "brightness" }) |widget_name| {
        if (@TypeOf(@field(self, widget_name)) == void) continue;
        if (@field(self, widget_name)) |*widget| {
            if (widget.widget.area.containsPoint(self.last_motion.?)) {
                assert(!clicked);
                clicked = true;
                widget.widget.click(self.last_motion.?, button);
            }
        }
    }
}

pub fn init(area: Rect) RootContainer {
    var root_container = RootContainer{
        .area = area,
    };

    if (!options.clock_disable) {
        var clock = Clock.init(.{
            .text_color = config.clock_text_color,
            .background_color = config.clock_background_color,

            .spacer_color = config.clock_spacer_color,

            .padding = 0,
            .padding_north = @intCast(area.height / 6),
            .padding_south = @intCast(area.height / 6),

            .area = .{
                .x = 0,
                .y = 0,
                .width = 1000,
                .height = area.height,
            },
        });

        var center_area = clock.widget.area;
        center_area.width = clock.getWidth();

        clock.setArea(area.center(center_area.dims()));

        root_container.clock = clock;
    }

    if (!options.workspaces_disable) workspaces: {
        var workspaces = Workspaces.init(.{
            .text_color = config.workspaces_text_color,
            .background_color = config.workspaces_background_color,

            .hover_workspace_background = config.workspaces_hover_background_color,
            .hover_workspace_text = config.workspaces_hover_text_color,

            .active_workspace_background = config.workspaces_active_background_color,
            .active_workspace_text = config.workspaces_active_text_color,

            .workspace_spacing = config.workspaces_spacing,
            .padding = 0,

            .area = .{
                .x = 0,
                .y = 0,
                .width = 1000,
                .height = area.height,
            },
        }) catch |err| {
            log.warn("Failed to initialize Workspace with: {s}", .{@errorName(err)});
            break :workspaces;
        };

        var left_area = workspaces.widget.area;
        left_area.width = workspaces.getWidth();

        workspaces.setArea(left_area);

        root_container.workspaces = workspaces;
    }

    if (!options.battery_disable) battery: {
        var battery = Battery.init(.{
            .x = area.width - 1000,
            .y = 0,
            .width = 1000,
            .height = area.height,
        }, config.battery_config) catch |err| {
            log.warn("Failed to initalized Battery with: {s}", .{@errorName(err)});
            break :battery;
        };

        var right_area = battery.widget.area;
        right_area.width = battery.getWidth();
        right_area.x = area.width - right_area.width;

        battery.widget.setArea(right_area);
        log.debug("battery: area: {}, {}", .{ battery.widget.area, battery.progress_area });

        battery.widget.area.assertContains(battery.progress_area);

        root_container.battery = battery;
    }

    if (!options.brightness_disable) brightness: {
        const x_pos = if (has_battery and root_container.battery != null) root_container.battery.?.widget.area.x - 1000 else root_container.area.width - 1000;

        var brightness = Brightness.init(.{
            .background_color = config.brightness_background_color,
            .brightness_color = config.brightness_color,

            .brightness_directory = config.brightness_directory,

            .scroll_ticks = config.scroll_ticks,

            .padding = 0, //@as(u16, @intCast(area.height / 10)),

            .area = .{
                .x = x_pos,
                .y = 0,
                .width = 1000,
                .height = area.height,
            },
        }) catch |err| {
            log.warn("Failed to initalized Brightness with: {s}", .{@errorName(err)});
            break :brightness;
        };

        var right_area = brightness.widget.area;
        right_area.width = brightness.getWidth();
        right_area.x = x_pos + 1000 - right_area.width;

        brightness.widget.setArea(right_area);
        log.debug("brightness: area: {}, {}", .{ brightness.widget.area, brightness.progress_area });

        brightness.widget.area.assertContains(brightness.progress_area);

        root_container.brightness = brightness;
    }

    return root_container;
}

test {
    std.testing.refAllDecls(@This());
}

const options = @import("options");

const Config = @import("Config.zig");
const config = &Config.global;

const colors = @import("colors.zig");

const DrawContext = @import("DrawContext.zig");
const Workspaces = @import("workspaces/Workspaces.zig");
const Clock = @import("Clock.zig");
const Battery = @import("Battery.zig");
const Brightness = @import("Brightness.zig");

const drawing = @import("drawing.zig");
const Point = drawing.Point;
const Rect = drawing.Rect;
const Size = drawing.Size;

const seat_utils = @import("seat_utils.zig");
const MouseButton = seat_utils.MouseButton;
const Axis = seat_utils.Axis;

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const assert = std.debug.assert;

const log = std.log.scoped(.RootContainer);
