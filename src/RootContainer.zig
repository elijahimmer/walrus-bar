//! The main container that holds all of the widgets

pub const RootContainer = @This();

widget: Widget,

// TODO: Remove these widgets and make a separate container struct for them.
workspaces: if (options.workspaces_enabled) ?Workspaces else void = if (options.workspaces_enabled) null else {},
clock: if (options.clock_enabled) ?Clock else void = if (options.clock_enabled) null else {},
battery: if (options.battery_enabled) ?Battery else void = if (options.battery_enabled) null else {},
brightness: if (options.brightness_enabled) ?Brightness else void = if (options.brightness_enabled) null else {},

pub fn deinit(self: *RootContainer) void {
    if (options.workspaces_enabled) if (self.workspaces) |*w| w.deinit();
    if (options.clock_enabled) if (self.clock) |*w| w.deinit();
    if (options.battery_enabled) if (self.battery) |*w| w.deinit();
    if (options.brightness_enabled) if (self.brightness) |*w| w.deinit();
}

pub fn setArea(self: *RootContainer, area: Rect) void {
    self.widget.area = area;

    if (options.clock_enabled and self.clock != null) {
        var center_area = self.clock.?.widget.area;
        center_area.width = self.clock.?.getWidth();

        self.clock.?.setArea(area.center(center_area.dims()));
    }

    if (options.workspaces_enabled and self.workspaces != null) {
        var left_area = self.workspaces.?.widget.area;
        left_area.width = self.workspaces.?.getWidth();

        self.workspaces.?.setArea(left_area);
    }

    if (options.battery_enabled and self.battery != null) {
        var right_area = self.battery.?.widget.area;
        right_area.width = self.battery.?.getWidth();
        right_area.x = area.width - right_area.width;

        self.battery.?.widget.setArea(right_area);
    }

    if (options.brightness_enabled and self.brightness != null) {
        const x_pos = if (options.battery_enabled and self.battery != null)
            self.battery.?.widget.area.x
        else
            area.width;

        var right_area = self.brightness.?.widget.area;
        right_area.width = self.brightness.?.getWidth();
        right_area.x = x_pos - right_area.width;

        self.brightness.?.widget.setArea(right_area);
    }
}

pub fn getWidth(self: *RootContainer) Size {
    _ = self;
    @panic("unimplemented");
}

pub fn draw(self: *RootContainer, draw_context: *DrawContext) error{}!void {
    defer draw_context.current_area = Rect.ZERO;
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
    assert(self.widget.last_motion != null);
    self.widget.area.assertContainsPoint(self.widget.last_motion.?);

    inline for (.{ "workspaces", "clock", "battery", "brightness" }) |widget_name| {
        if (@TypeOf(@field(self, widget_name)) == void) continue;
        if (@field(self, widget_name)) |*widget| {
            const area = widget.widget.area;
            if (area.containsPoint(self.widget.last_motion.?)) widget.widget.scroll(axis, discrete);
        }
    }
}

pub fn motion(self: *RootContainer, point: Point) void {
    self.widget.area.assertContainsPoint(point);
    if (self.widget.last_motion) |lm| self.widget.area.assertContainsPoint(lm);

    const last_motion = self.widget.last_motion;

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
    if (self.widget.last_motion == null) return;
    self.widget.area.assertContainsPoint(self.widget.last_motion.?);

    var left = false;
    inline for (.{ "workspaces", "clock", "battery", "brightness" }) |widget_name| {
        if (@TypeOf(@field(self, widget_name)) == void) continue;
        if (@field(self, widget_name)) |*widget| {
            if (widget.widget.area.containsPoint(self.widget.last_motion.?)) {
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
    assert(self.widget.last_motion != null);
    self.widget.area.assertContainsPoint(self.widget.last_motion.?);

    var clicked = false;
    inline for (.{ "workspaces", "clock", "battery", "brightness" }) |widget_name| {
        if (@TypeOf(@field(self, widget_name)) == void) continue;
        if (@field(self, widget_name)) |*widget| {
            if (widget.widget.area.containsPoint(self.widget.last_motion.?)) {
                assert(!clicked); // make sure no widgets overlap.
                clicked = true;
                widget.widget.click(button);
            }
        }
    }
}

pub fn init(area: Rect) RootContainer {
    var root_container = RootContainer{
        .widget = .{
            .vtable = Widget.generateVTable(RootContainer),
            .area = Rect.ZERO,
        },
    };

    if (options.clock_enabled) {
        root_container.clock = Clock.init(
            .{
                .x = 0,
                .y = 0,
                .width = 1000,
                .height = area.height,
            },
            config.clock,
        );
    }

    if (options.workspaces_enabled) workspaces: {
        root_container.workspaces = Workspaces.init(
            .{
                .x = 0,
                .y = 0,
                .width = 1000,
                .height = area.height,
            },
            config.workspaces,
        ) catch |err| {
            log.warn("Failed to initialize Workspace with: {s}", .{@errorName(err)});
            break :workspaces;
        };
    }

    if (options.battery_enabled) battery: {
        root_container.battery = Battery.init(.{
            .x = 0,
            .y = 0,
            .width = 1000,
            .height = area.height,
        }, config.battery) catch |err| {
            log.warn("Failed to initalized Battery with: {s}", .{@errorName(err)});
            break :battery;
        };
    }

    if (options.brightness_enabled) brightness: {
        root_container.brightness = Brightness.init(.{
            .x = 0,
            .y = 0,
            .width = 1000,
            .height = area.height,
        }, config.brightness) catch |err| {
            log.warn("Failed to initalized Brightness with: {s}", .{@errorName(err)});
            break :brightness;
        };
    }

    root_container.setArea(area);

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
const OutputContext = @import("OutputContext.zig");
const WaylandContext = @import("WaylandContext.zig");

const Workspaces = @import("workspaces/Workspaces.zig");
const Clock = @import("Clock.zig");
const Battery = @import("Battery.zig");
const Brightness = @import("Brightness.zig");

const drawing = @import("drawing.zig");
const Widget = drawing.Widget;
const Point = drawing.Point;
const Rect = drawing.Rect;
const Size = drawing.Size;

const seat_utils = @import("seat_utils.zig");
const MouseButton = seat_utils.MouseButton;
const Axis = seat_utils.Axis;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const assert = std.debug.assert;

const log = std.log.scoped(.RootContainer);
