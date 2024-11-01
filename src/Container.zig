//! A Widget container that holds a number of widgets,
//! and controls their placement.
//! TODO: Redo entirely

pub const Container = @This();

inner_widgets: ArrayListUnmanaged(Widget),

widget: Widget,

pub fn deinit(self: *Container, allocator: Allocator) void {
    self.inner_widgets.deinit(allocator);
}

pub fn setArea(self: Container, area: Rect) void {
    _ = self;
    _ = area;
    @panic("Unimplemented");
}

pub fn getWidth(self: Container) u31 {
    _ = self;
    @panic("Unimplemented");
}

pub fn draw(self: *Container, draw_context: *DrawContext) !void {
    _ = self;
    _ = draw_context;
}

pub const NewWidgetArgs = struct {
    area: Rect,
};

pub fn newWidget(allocator: Allocator, args: NewWidgetArgs) Allocator.Error!*Widget {
    const new = try allocator.create(Container);

    new.* = Container.init(args);

    return &new.widget;
}

pub fn init(args: NewWidgetArgs) Container {
    return .{
        .inner_widgets = .{},
        .widget = .{
            .vtable = &.{
                .draw = &Container.drawWidget,
                .deinit = &Container.deinitWidget,
                .setArea = &Container.setAreaWidget,
                .getWidth = &Container.getWidthWidget,
                // TODO: Implement mouse interface.
                .motion = null,
                .leave = null,
                .click = null,
            },

            .area = args.area,
        },
    };
}

//test {
//    std.testing.refAllDecls(@This());
//}

const DrawContext = @import("DrawContext.zig");

const drawing = @import("drawing.zig");
const Widget = drawing.Widget;
const Rect = drawing.Rect;

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
