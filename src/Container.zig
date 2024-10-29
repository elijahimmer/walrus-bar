//! A Widget container that holds a number of widgets,
//! and controls their placement.

pub const Container = @This();

inner_widgets: ArrayListUnmanaged(Widget),

widget: Widget,

pub fn newWidget(allocator: Allocator) Allocator.Error!*Widget {
    const new = allocator.create(Container);

    new.* = try Container.init();

    return new;
}

pub fn init() !Container {
    return .{
        .inner_widgets = .{},
        .widget = .{ .vtable = .{} },
    };
}

const drawing = @import("drawing.zig");
const Widget = drawing.Widget;

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
