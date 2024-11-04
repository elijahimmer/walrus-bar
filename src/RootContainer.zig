//! The main container that holds all of the widgets

pub const RootContainer = @This();

area: Rect,
last_motion: ?Point = null,

// TODO: Remove these widgets and make a separate container struct for them.
widget_left: if (has_widget_left) ?Workspaces else void = if (!options.workspaces_disable) null else {},
widget_center: if (has_widget_center) ?Clock else void = if (!options.clock_disable) null else {},
widget_right: if (has_widget_right) ?Battery else void = if (!options.battery_disable) null else {},

const has_widget_left = !options.workspaces_disable;
const has_widget_center = !options.clock_disable;
const has_widget_right = !options.battery_disable;

pub fn deinit(self: *RootContainer) void {
    if (has_widget_left) if (self.widget_left) |*w| w.deinit();
    // No clock deinit needed
    if (has_widget_center) if (self.widget_center) |*w| w.deinit();
    if (has_widget_right) if (self.widget_right) |*w| w.deinit();
}

pub fn setArea(self: RootContainer, area: Rect) void {
    _ = self;
    _ = area;
    @panic("Unimplemented");
}

pub fn getWidth(self: RootContainer) u31 {
    _ = self;
    @panic("Unimplemented");
}

pub fn draw(self: *RootContainer, draw_context: *DrawContext) !void {
    inline for (.{ "widget_left", "widget_center", "widget_right" }) |name| {
        if (@TypeOf(@field(self, name)) == void) continue;

        if (@field(self, name)) |*w| {
            if (@TypeOf(w) != *void) {
                draw_context.current_area = w.widget.area;
                w.widget.draw(draw_context) catch |err| log.warn("Drawing of '{s}' failed with: '{s}'", .{ name, @errorName(err) });
            }
        }
    }
}

pub fn motion(self: *RootContainer, point: Point) void {
    assert(self.area.containsPoint(point));
    if (self.last_motion) |lm| assert(self.area.containsPoint(lm));

    const last_motion = self.last_motion;
    defer self.last_motion = point;

    inline for (.{
        "widget_left",
        "widget_center",
        "widget_right",
    }) |widget_name| {
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

pub fn leave(self: *RootContainer) void {
    assert(self.last_motion != null);
    assert(self.area.containsPoint(self.last_motion.?));
    defer self.last_motion = null;

    var left = false;
    inline for (.{
        "widget_left",
        "widget_center",
        "widget_right",
    }) |widget_name| {
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

/// asserts the it has had a last motion.
pub fn click(self: *RootContainer, button: MouseButton) void {
    assert(self.last_motion != null);
    assert(self.area.containsPoint(self.last_motion.?));

    var clicked = false;
    inline for (.{
        "widget_left",
        "widget_center",
        "widget_right",
    }) |widget_name| {
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
            .text_color = config.text_color,
            .background_color = config.background_color,

            .spacer_color = colors.pine,

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

        root_container.widget_center = clock;
    }

    if (!options.workspaces_disable) workspaces: {
        var workspaces = Workspaces.init(.{
            .text_color = config.text_color,
            .background_color = config.background_color,

            .hover_workspace_background = colors.hl_med,
            .hover_workspace_text = colors.gold,

            .active_workspace_background = colors.pine,
            .active_workspace_text = colors.gold,

            .workspace_spacing = 0,
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

        root_container.widget_left = workspaces;
    }

    if (!options.battery_disable) battery: {
        var battery = Battery.init(.{
            .background_color = config.background_color,

            .discharging_color = colors.pine,
            .charging_color = colors.iris,
            .critical_color = colors.love,
            .warning_color = colors.rose,
            .full_color = colors.gold,

            .battery_directory = config.battery_directory,

            .padding = @as(u16, @intCast(area.height / 10)),

            .area = .{
                .x = area.width - 1000,
                .y = 0,
                .width = 1000,
                .height = area.height,
            },
        }) catch |err| {
            log.warn("Failed to initalized Battery with: {s}", .{@errorName(err)});
            break :battery;
        };

        var right_area = battery.widget.area;
        right_area.width = battery.getWidth();
        right_area.x = area.width - right_area.width;

        battery.widget.setArea(right_area);
        log.debug("battery: area: {}, {}", .{ battery.widget.area, battery.progress_area });

        battery.widget.area.assertContains(battery.progress_area);

        root_container.widget_right = battery;
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

const drawing = @import("drawing.zig");
const Point = drawing.Point;
const Rect = drawing.Rect;

const seat_utils = @import("seat_utils.zig");
const MouseButton = seat_utils.MouseButton;

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const assert = std.debug.assert;

const log = std.log.scoped(.RootContainer);
