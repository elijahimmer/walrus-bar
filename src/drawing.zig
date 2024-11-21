pub const SizeSigned = i32;
pub const Size = u16;

pub const Point = struct {
    x: Size,
    y: Size,

    pub const ZERO = Point{ .x = 0, .y = 0 };

    pub fn extendTo(self: Point, other: Point) Rect {
        const x_min, const x_max = .{ @min(self.x, other.x), @max(self.x, other.x) };
        const y_min, const y_max = .{ @min(self.y, other.y), @max(self.y, other.y) };

        return .{
            .x = x_min,
            .y = y_min,
            .width = x_max - x_min,
            .height = y_max - y_min,
        };
    }
};

pub const Padding = struct {
    north: Size,
    south: Size,
    east: Size,
    west: Size,

    pub fn from(args: anytype) Padding {
        return .{
            .north = args.padding_north orelse args.padding,
            .south = args.padding_south orelse args.padding,
            .east = args.padding_east orelse args.padding,
            .west = args.padding_west orelse args.padding,
        };
    }

    pub fn uniform(padding: u16) Padding {
        return .{
            .north = padding,
            .south = padding,
            .east = padding,
            .west = padding,
        };
    }
};

pub const Rect = struct {
    x: Size,
    y: Size,
    width: Size,
    height: Size,

    pub const ZERO = Rect{
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
    };

    /// Returns true if the `self` rect fully contains the `inner` rect
    pub fn contains(self: Rect, inner: Rect) bool {
        return (self.x <= inner.x) and
            (self.y <= inner.y) and
            (self.width >= inner.width) and
            (self.height >= inner.height) and
            (self.x + self.width >= inner.x + inner.width) and
            (self.y + self.height >= inner.y + inner.height);
    }

    /// Returns true if the `self` rect contains the point
    pub fn containsPoint(self: Rect, point: Point) bool {
        return (self.x <= point.x) and
            (self.y <= point.y) and
            (self.x + self.width >= point.x) and
            (self.y + self.height >= point.y);
    }

    /// Returns if the rect contains the given local point.
    pub fn containsLocalPoint(self: Rect, point: Point) bool {
        return (self.width <= point.x) and
            (self.height <= point.y);
    }

    /// Asserts that the `self` rect fully contains the `inner` rect
    pub fn assertContains(self: Rect, inner: Rect) void {
        assert(self.x <= inner.x);
        assert(self.y <= inner.y);
        assert(self.width >= inner.width);
        assert(self.height >= inner.height);
        assert(self.x + self.width >= inner.x + inner.width);
        assert(self.y + self.height >= inner.y + inner.height);
    }

    /// Asserts that the `self` rect fully contains the point.
    pub fn assertContainsPoint(self: Rect, point: Point) void {
        assert(self.x <= point.x);
        assert(self.y <= point.y);
        assert(self.x + self.width >= point.x);
        assert(self.y + self.height >= point.y);
    }

    /// asserts that the `self` rect fully contains the `inner` circle
    pub fn assertContainsCircle(self: Rect, inner: Circle) void {
        const circle_bb = inner.boundingBox();

        self.assertContains(circle_bb);
    }

    /// returns the X and Y coordinates of the Rect
    pub fn origin(self: Rect) Point {
        return .{
            .x = self.x,
            .y = self.y,
        };
    }

    /// returns the Width and Height dims of the Rect
    pub fn dims(self: Rect) Point {
        return .{
            .x = self.width,
            .y = self.height,
        };
    }

    /// Returns a intersecting rectangle, null if they don't intersect.
    /// Their width and height will be greater zero.
    pub fn intersection(self: Rect, other: Rect) ?Rect {
        const x_start = @max(self.x, other.x);
        const y_start = @max(self.y, other.y);
        const x_end = @min(self.x + self.width, other.x + other.width);
        const y_end = @min(self.y + self.height, other.y + other.height);

        // they don't actually intersect
        // TODO: Check if this should be `>` or `>=`
        if (x_start >= x_end or y_start >= y_end) return null;

        return .{
            .x = x_start,
            .y = y_start,
            .width = x_end - x_start,
            .height = y_end - y_start,
        };
    }

    /// Returns the smallest possible rectangle that contains both other rectangles.
    pub fn boundingBox(self: Rect, other: Rect) Rect {
        const x_start = @min(self.x, other.x);
        const y_start = @min(self.y, other.y);
        const x_end = @max(self.x + self.width, other.x + other.width);
        const y_end = @max(self.y + self.height, other.y + other.height);

        return .{
            .x = x_start,
            .y = y_start,
            .width = x_end - x_start,
            .height = y_end - y_start,
        };
    }

    /// Center inner box in self. Asserts self is larger than inner
    pub fn center(self: Rect, inner: Point) Rect {
        return self.alignWith(inner, .center, .center);
    }

    /// Inner is the width and height of the returned Rect.
    pub fn alignWith(self: Rect, inner: Point, hori_align: Align, vert_align: Align) Rect {
        const new_x = switch (hori_align) {
            .start => self.x,
            .end => self.x + self.width - inner.x,
            .center => @as(Size, @intCast(self.x + @divFloor(@as(SizeSigned, self.width) - inner.x, 2))),
        };

        const new_y = switch (vert_align) {
            .start => self.y,
            .end => self.y + self.height - inner.y,
            .center => @as(Size, @intCast(self.y + @divFloor(@as(SizeSigned, self.height) - inner.y, 2))),
        };

        return .{
            .x = new_x,
            .y = new_y,
            .width = inner.x,
            .height = inner.y,
        };
    }

    /// Remove the padding from each side of Rect
    pub fn removePadding(self: Rect, padding: Padding) ?Rect {
        if (self.height < (padding.north + padding.south) or self.width < (padding.east + padding.west)) {
            return null;
        }

        return .{
            .x = self.x + padding.east,
            .y = self.y + padding.north,
            .width = self.width - padding.east - padding.west,
            .height = self.height - padding.north - padding.south,
        };
    }

    /// Add padding to each side of the Rect
    pub fn addPadding(self: Rect, padding: Padding) Rect {
        assert(self.x >= padding.east);
        assert(self.y >= padding.north);

        return .{
            .x = self.x - padding.east,
            .y = self.y - padding.north,
            .width = self.width + padding.east + padding.west,
            .height = self.height + padding.north + padding.south,
        };
    }

    /// Rects containing the padding on each side.
    pub const ReturnPaddingResult = struct {
        /// the padding to the north
        north: Rect,
        /// the padding to the south
        south: Rect,
        /// the padding to the east
        east: Rect,
        /// the padding to the west
        west: Rect,
    };

    /// Returns a series of rects that together make up the padding of the given rect.
    pub fn returnPadding(self: Rect, padding: Padding) ReturnPaddingResult {
        return .{
            .north = .{
                .x = self.x,
                .y = self.y,
                .width = self.width,
                .height = padding.north,
            },
            .south = .{
                .x = self.x,
                .y = self.height - padding.south + self.y,
                .width = self.width,
                .height = padding.south,
            },
            .west = .{
                .x = self.x,
                .y = self.y + padding.north,
                .width = padding.west,
                .height = self.height - padding.north - padding.south,
            },
            .east = .{
                .x = self.width - padding.east + self.x,
                .y = self.y + padding.north,
                .width = padding.east,
                .height = self.height - padding.north - padding.south,
            },
        };
    }

    /// Draws all the area of the padding in the given rect.
    pub fn drawPadding(self: Rect, draw_context: *const DrawContext, color: Color, padding: Padding) void {
        const rects = self.returnPadding(padding);

        self.assertContains(rects.north);
        self.assertContains(rects.south);
        self.assertContains(rects.east);
        self.assertContains(rects.west);

        rects.north.drawArea(draw_context, color);
        rects.west.drawArea(draw_context, color);
        rects.east.drawArea(draw_context, color);
        rects.south.drawArea(draw_context, color);
    }

    /// Draws the area of the rectangle in the given color
    pub fn drawArea(self: Rect, draw_context: *const DrawContext, color: Color) void {
        const x_min = self.x;
        const y_min = self.y;

        const x_max = self.x + self.width;
        const y_max = self.y + self.height;
        const window_width = draw_context.window_area.width;

        for (y_min..y_max) |y_coord| {
            const screen_line = draw_context.screen[@as(usize, y_coord) * window_width + x_min ..][0 .. x_max - x_min];

            @memset(screen_line, color);
        }
    }

    /// like `drawArea`, but puts the color compositely.
    pub fn drawAreaComposite(self: Rect, draw_context: *const DrawContext, color: Color) void {
        for (0..self.height) |y_coord| {
            for (0..self.width) |x_coord| {
                self.putComposite(draw_context, .{
                    .x = @intCast(x_coord),
                    .y = @intCast(y_coord),
                }, color);
            }
        }
    }

    /// Draws the outline of the given rect in the given color
    pub fn drawOutline(self: Rect, draw_context: *const DrawContext, color: Color) void {
        const x_min = self.x;
        const y_min = self.y;

        const x_max = self.x + self.width;
        const y_max = self.y + self.height;
        const window_width = draw_context.window_area.width;
        const window_height = draw_context.window_area.height;

        assert(window_width >= x_max);
        assert(window_height >= y_max);

        for (y_min..y_max) |y_coord| {
            draw_context.screen[@as(usize, y_coord) * window_width + x_min] = color;
            draw_context.screen[@as(usize, y_coord) * window_width + x_max - 1] = color;
        }

        for (x_min..x_max) |x_coord| {
            draw_context.screen[@as(usize, y_min) * window_width + x_coord] = color;
            draw_context.screen[@as(usize, y_max - 1) * window_width + x_coord] = color;
        }
    }

    /// damages the given rect's outlines.
    pub fn damageOutline(self: Rect, draw_context: *const DrawContext) void {
        draw_context.surface.damageBuffer(self.x, self.y, self.width, 1);
        draw_context.surface.damageBuffer(self.x, self.y, 1, self.height);
        draw_context.surface.damageBuffer(self.x + self.width, self.y, 1, self.height);
        draw_context.surface.damageBuffer(self.x, self.y + self.height, self.width, 1);
    }

    /// Draw a pixel at the given `area_local_point`, in the given rect, in the given color.
    pub fn putPixel(self: Rect, draw_context: *const DrawContext, area_local_point: Point, color: Color) void {
        const x_coord = self.x + area_local_point.x;
        const y_coord = self.y + area_local_point.y;

        const window_width = draw_context.window_area.width;

        draw_context.window_area.assertContainsPoint(.{ .x = x_coord, .y = y_coord });
        draw_context.screen[@as(usize, y_coord) * window_width + x_coord] = color;
    }

    /// Draw a pixel at the given `area_local_point`, in the given rect, in the given color composited with the color already there.
    pub fn putComposite(
        self: Rect,
        draw_context: *const DrawContext,
        area_local_point: Point,
        color: Color,
    ) void {
        const x_coord = self.x + area_local_point.x;
        const y_coord = self.y + area_local_point.y;

        const window_width = draw_context.window_area.width;

        draw_context.current_area.assertContainsPoint(.{ .x = x_coord, .y = y_coord });

        const base_color = draw_context.screen[@as(usize, y_coord) * window_width + x_coord];

        const new_color = base_color.composite(color);

        draw_context.screen[@as(usize, y_coord) * window_width + x_coord] = new_color;
    }
};

/// A circle on the screen.
pub const Circle = struct {
    /// The diameter of the circle going through the center.
    d: Size,
    /// the x coord of the center of the circle.
    x: Size,
    /// the y coord of the center of the circle.
    y: Size,

    /// returns the largest circle that fits inside of the given rect.
    pub fn largestCircle(rect: Rect) Circle {
        const diameter = @min(rect.width, rect.height);

        const circle = Circle{
            .d = diameter,
            .x = rect.x + diameter / 2,
            .y = rect.y + diameter / 2,
        };

        rect.assertContainsCircle(circle);

        return circle;
    }

    /// return the smallest rect that completely contains the circle.
    pub fn boundingBox(self: Circle) Rect {
        return .{
            .x = self.x - self.d / 2,
            .y = self.y - self.d / 2,
            .width = self.d,
            .height = self.d,
        };
    }

    /// draws the outline of the given circle.
    pub fn drawOutline(self: Circle, draw_context: *const DrawContext, color: Color) void {
        self.drawOutlineWithin(draw_context, self.boundingBox(), color);
    }

    /// draws the outline of the given circle only within the given area.
    pub fn drawOutlineWithin(self: Circle, draw_context: *const DrawContext, area: Rect, color: Color) void {
        var t1: Size = self.d / 32;
        var x: Size = self.d / 2;
        var y: Size = 0;

        while (x >= y) {
            self.reflectPoint(draw_context, area, .{
                .x = x,
                .y = y,
            }, color);

            y += 1;
            t1 += y;
            if (t1 >= x) {
                t1 -= x;
                x -= 1;
            }
        }
    }

    /// internal use of drawOutlineWithin to put point on all symmetric points.
    fn reflectPoint(self: Circle, draw_context: *const DrawContext, area: Rect, point: Point, color: Color) void {
        const base = self.d / 2;

        const one = Point{
            .x = base + point.x,
            .y = base + point.y,
        };

        const two = Point{
            .x = base - point.x,
            .y = base + point.y,
        };

        const three = Point{
            .x = base - point.x,
            .y = base - point.y,
        };
        const four = Point{
            .x = base + point.x,
            .y = base - point.y,
        };
        const five = Point{
            .x = base + point.y,
            .y = base + point.x,
        };
        const six = Point{
            .y = base - point.x,
            .x = base + point.y,
        };
        const seven = Point{
            .y = base - point.x,
            .x = base - point.y,
        };
        const eight = Point{
            .y = base + point.x,
            .x = base - point.y,
        };

        const draw_area = self.boundingBox().intersection(area) orelse return;

        inline for (.{
            one, two, three, four, five, six, seven, eight,
        }) |section| {
            if (draw_area.containsPoint(section)) {
                draw_area.putPixel(draw_context, section, color);
            }
        }
    }

    /// draws the area of the given circle in the given color
    pub fn drawArea(self: Circle, draw_context: *const DrawContext, color: Color) void {
        self.drawAreaWithin(draw_context, self.boundingBox(), color);
    }

    /// like drawArea, but only draws points within the given Rect
    pub fn drawAreaWithin(self: Circle, draw_context: *const DrawContext, area: Rect, color: Color) void {
        var t1: Size = self.d / 32;
        var x: Size = self.d / 2;
        var y: Size = 0;

        while (x >= y) {
            self.reflectPointFillIn(draw_context, area, .{
                .x = x,
                .y = y,
            }, color);

            y += 1;
            t1 += y;
            if (t1 >= x) {
                t1 -= x;
                x -= 1;
            }
        }
    }

    /// internal function used by drawOutlineWithin for taking a point and drawing the area.
    fn reflectPointFillIn(self: Circle, draw_context: *const DrawContext, area: Rect, point: Point, color: Color) void {
        const bounding_box = self.boundingBox();
        const odd_width: u1 = @intCast(self.d & 1);

        const top_rect = Rect{
            .x = self.x - point.x,
            .y = self.y - point.y,
            .width = point.x * 2 + odd_width,
            .height = 1,
        };
        const middle_top_rect = Rect{
            .x = self.x - point.y,
            .y = self.y - point.x,
            .width = point.y * 2 + odd_width,
            .height = 1,
        };
        // move the lower ones up to avoid a weird off by 1 error when it is a even width.
        const middle_bottom_rect = Rect{
            .x = self.x - point.x,
            .y = self.y + point.y + odd_width - 1,
            .width = point.x * 2 + odd_width,
            .height = 1,
        };
        const bottom_rect = Rect{
            .x = self.x - point.y,
            .y = self.y + point.x + odd_width - 1,
            .width = point.y * 2 + odd_width,
            .height = 1,
        };

        inline for (.{
            top_rect,
            middle_top_rect,
            middle_bottom_rect,
            bottom_rect,
        }) |rect| {
            if (rect.intersection(area)) |to_draw| {
                bounding_box.assertContains(to_draw);
                to_draw.drawArea(draw_context, color);
            }
        }
    }

    /// damages the circle's area.
    pub fn damageArea(self: Circle, draw_context: *const DrawContext) void {
        // TODO: Make some accurate damage box.
        draw_context.damageArea(self.boundingBox());
    }
};

pub const Transform = struct {
    xx: i64,
    xy: i64,
    yx: i64,
    yy: i64,

    pub const identity = fromRadians(0.0);
    pub const right = fromRadians(math.pi / 2.0);
    pub const left = fromRadians(-math.pi / 2.0);
    pub const upsidedown = fromRadians(math.pi);

    pub fn fromRadians(radian: f32) Transform {
        return .{
            .xx = @intFromFloat(@cos(radian) * 0x10000),
            .xy = @intFromFloat(-@sin(radian) * 0x10000),
            .yx = @intFromFloat(@sin(radian) * 0x10000),
            .yy = @intFromFloat(@cos(radian) * 0x10000),
        };
    }

    pub fn isIdentity(self: Transform) bool {
        return std.meta.eql(self, identity);
    }
};

pub const Widget = struct {
    const VTable = struct {
        // TODO: Don't use anyerror here. It sucks.
        draw: *const fn (*Widget, *DrawContext) anyerror!void,
        deinit: *const fn (*Widget, Allocator) void,
        setArea: *const fn (*Widget, Rect) void,
        getWidth: *const fn (*Widget) u31,

        motion: ?*const fn (*Widget, Point) void,
        leave: ?*const fn (*Widget) void,
        click: ?*const fn (*Widget, MouseButton) void,
        scroll: ?*const fn (*Widget, Axis, i32) void,
    };
    vtable: *const VTable,

    area: Rect,

    last_motion: ?Point = null,
    last_motion_time: ?Timer = null,

    /// This should be true anytime the widget needs to redraw.
    /// So if the area is changed or the glyph needs to for other reasons.
    full_redraw: bool = true,

    // Draws the widget.
    pub inline fn draw(self: *Widget, draw_context: *DrawContext) anyerror!void {
        defer self.full_redraw = false;
        try self.vtable.draw(self, draw_context);
    }

    /// Deinitializes the widget
    pub inline fn deinit(self: *Widget, allocator: Allocator) void {
        self.vtable.deinit(self, allocator);
    }

    /// Sets the widget's area. Don't set it directly or drawing may mess up.
    pub inline fn setArea(self: *Widget, area: Rect) void {
        self.vtable.setArea(self, area);
    }

    /// Returns the actual width used, including padding.
    pub inline fn getWidth(self: *Widget) u32 {
        return self.vtable.getWidth(self);
    }

    /// Tells the widget the mouse has moved in
    pub inline fn motion(self: *Widget, point: Point) void {
        defer {
            self.last_motion = point;
            self.last_motion_time = Timer.start() catch |err| switch (err) {
                error.TimerUnsupported => null,
            };
        }

        self.area.assertContainsPoint(point);
        if (self.vtable.motion) |motion_fn| {
            motion_fn(self, point);
        }
    }

    /// Tells the widget the mouse has moved in
    pub inline fn leave(self: *Widget) void {
        defer self.last_motion = null;
        defer self.last_motion_time = null;

        if (self.vtable.leave) |leave_fn| leave_fn(self);
    }

    pub inline fn click(self: *Widget, button: MouseButton) void {
        assert(self.last_motion != null);
        if (self.vtable.click) |click_fn| click_fn(self, button);
    }

    pub inline fn scroll(self: *Widget, axis: Axis, discrete: i32) void {
        if (self.vtable.scroll) |scroll_fn| scroll_fn(self, axis, discrete);
    }

    pub fn getParent(self: *Widget, T: type) *T {
        return @fieldParentPtr("widget", self);
    }

    pub fn generateVTable(Outer: type) *const VTable {
        comptime {
            assert(meta.hasMethod(Outer, "deinit"));
            assert(meta.hasMethod(Outer, "setArea"));
            assert(meta.hasMethod(Outer, "getWidth"));
        }

        const S = struct {
            pub fn draw(widget: *Widget, draw_context: *DrawContext) anyerror!void {
                const self: *Outer = @fieldParentPtr("widget", widget);

                try self.draw(draw_context);
            }

            pub fn deinit(widget: *Widget, allocator: Allocator) void {
                const self: *Outer = @fieldParentPtr("widget", widget);

                self.deinit();

                allocator.destroy(self);
                self.* = undefined;
            }

            pub fn setArea(widget: *Widget, area: Rect) void {
                const self: *Outer = @fieldParentPtr("widget", widget);

                self.setArea(area);
            }

            pub fn getWidth(widget: *Widget) u31 {
                const self: *Outer = @fieldParentPtr("widget", widget);

                return self.getWidth();
            }

            pub fn motion(widget: *Widget, point: Point) void {
                const self: *Outer = @fieldParentPtr("widget", widget);

                self.motion(point);
            }

            pub fn click(widget: *Widget, button: MouseButton) void {
                assert(widget.last_motion != null);

                const self: *Outer = @fieldParentPtr("widget", widget);
                self.click(button);
            }

            pub fn scroll(widget: *Widget, axis: Axis, discrete: i32) void {
                assert(widget.last_motion != null);

                const self: *Outer = @fieldParentPtr("widget", widget);
                self.scroll(axis, discrete);
            }

            pub fn leave(widget: *Widget) void {
                const self: *Outer = @fieldParentPtr("widget", widget);
                self.leave();
            }

            pub const vtable = VTable{
                .draw = if (std.meta.hasFn(Outer, "drawWidget")) Outer.drawWidget else @This().draw,
                .deinit = if (std.meta.hasFn(Outer, "deinitWidget")) Outer.deinitWidget else @This().deinit,
                .setArea = if (std.meta.hasFn(Outer, "setAreaWidget")) Outer.setAreaWidget else @This().setArea,
                .getWidth = if (std.meta.hasFn(Outer, "getWidthWidget")) Outer.getWidthWidget else @This().getWidth,

                .motion = if (@hasDecl(Outer, "motion")) @This().motion else null,
                .leave = if (@hasDecl(Outer, "leave")) @This().leave else null,
                .click = if (@hasDecl(Outer, "click")) @This().click else null,
                .scroll = if (@hasDecl(Outer, "scroll")) @This().scroll else null,
            };
        };

        return &S.vtable;
    }
};

pub const Align = enum { start, center, end };

const seat_utils = @import("seat_utils.zig");
const MouseButton = seat_utils.MouseButton;
const Axis = seat_utils.Axis;

const DrawContext = @import("DrawContext.zig");
const freetype_context = &@import("FreeTypeContext.zig").global;

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");
const math = std.math;
const meta = std.meta;

const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;

const assert = std.debug.assert;
