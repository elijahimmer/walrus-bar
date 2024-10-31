pub const DrawContext = @This();
pub const MAX_DAMAGE_LIST_LEN = 16;
pub const DamageList = if (options.track_damage) BoundedArray(Rect, MAX_DAMAGE_LIST_LEN) else void;
pub const damage_list_init = if (options.track_damage) .{} else {};

output_context: OutputContext,

surface: ?*wl.Surface = null,
layer_surface: ?*zwlr.LayerSurfaceV1 = null,
shm_buffer: ?*wl.Buffer = null,
shm_fd: ?posix.fd_t = null,
frame_callback: ?*wl.Callback = null,

screen: []Color = undefined,

current_area: Rect = undefined,

window_area: Rect = .{
    .x = 0,
    .y = 0,
    .width = 0,
    .height = 0,
},

damage_list: DamageList = damage_list_init,
damage_prev: DamageList = damage_list_init,

has_started: bool = false,
full_redraw: bool = true,

last_motion: ?Point = null,

// TODO: Remove these widgets and make a separate container struct for them.
widget_left: if (!options.workspaces_disable) ?Workspaces else void = if (!options.workspaces_disable) null else {},
widget_center: if (!options.clock_disable) ?Clock else void = if (!options.clock_disable) null else {},
widget_right: if (!options.battery_disable) ?Battery else void = if (!options.battery_disable) null else {},

pub const OutputContext = struct {
    output: *wl.Output,
    id: u32,

    physical_height: u16 = undefined,
    physical_width: u16 = undefined,

    height: u16 = undefined,
    width: u16 = undefined,

    has_geometry: bool = false,
    has_mode: bool = false,
    has_name: bool = false,
    changed: bool = true, // start off as changed to initialize output

    name: []const u8 = undefined,
};

pub fn damage(draw_context: *DrawContext, area: Rect) void {
    draw_context.current_area.assertContains(area);

    if (options.track_damage) {
        draw_context.damage_list.append(area) catch @panic("the Damage list is full, increase list size.");
    } else {
        draw_context.surface.?.damageBuffer(area.x, area.y, area.width, area.height);
    }
}

pub const InitArgs = struct {
    output: *wl.Output,
    id: u32,
};

pub fn init(args: InitArgs) DrawContext {
    return .{
        .output_context = .{
            .output = args.output,
            .id = args.id,
        },
    };
}

pub fn deinit(draw_context: *DrawContext, allocator: Allocator) void {
    if (draw_context.output_context.has_name)
        log.debug("Output '{s}' (id #{}) was deinited", .{ draw_context.output_context.name, draw_context.output_context.id })
    else
        log.debug("Output id #{} was deinited", .{draw_context.output_context.id});

    if (!options.workspaces_disable) if (draw_context.widget_left) |*widget_left| widget_left.deinit();
    //// no clock deinit needed
    //if (!options.clock_disable) if (draw_context.widget_center) |*widget_center| widget_center.deinit();
    if (!options.battery_disable) if (draw_context.widget_right) |*widget_right| widget_right.deinit();

    if (draw_context.shm_buffer) |shm_buffer| shm_buffer.destroy();
    if (draw_context.shm_fd) |shm_fd| posix.close(shm_fd);
    if (draw_context.frame_callback) |frame_callback| frame_callback.destroy();

    if (draw_context.layer_surface) |layer_surface| layer_surface.destroy();
    if (draw_context.surface) |surface| surface.destroy();

    if (draw_context.output_context.has_name) allocator.free(draw_context.output_context.name);
    draw_context.output_context.output.release();

    draw_context.* = undefined;
}

const InitializeShmError = posix.MMapError || posix.MemFdCreateError || posix.TruncateError;
fn initializeShm(draw_context: *DrawContext, wayland_context: *WaylandContext) InitializeShmError!void {
    assert(wayland_context.shm != null);
    assert(draw_context.output_context.width >= draw_context.window_area.width);
    assert(draw_context.output_context.height >= draw_context.window_area.height);
    assert(draw_context.surface != null);

    const width = draw_context.output_context.width;
    const height = config.height;
    const stride = @as(u31, width) * @sizeOf(Color);

    const size: u31 = stride * @as(u31, height);
    const fd = try posix.memfd_createZ(constants.WAYLAND_NAMESPACE, 0);
    draw_context.shm_fd = fd;
    try posix.ftruncate(fd, size);
    const screen = try posix.mmap(
        null,
        size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    var screen_adjusted: []Color = undefined;
    screen_adjusted.ptr = @ptrCast(screen.ptr);
    screen_adjusted.len = @as(usize, height) * width;

    draw_context.screen = screen_adjusted;

    @memset(screen_adjusted, all_colors.surface);

    const shm_pool = try wayland_context.shm.?.createPool(fd, size);

    draw_context.shm_buffer = try shm_pool.createBuffer(0, width, height, stride, Color.FORMAT);
}

pub const OutputChangedError = InitializeShmError || error{OutOfMemory};
pub fn outputChanged(draw_context: *DrawContext, wayland_context: *WaylandContext) OutputChangedError!void {
    assert(draw_context.output_context.width > 0);
    assert(draw_context.output_context.height > 0);
    assert(wayland_context.layer_shell != null);
    assert(wayland_context.compositor != null);
    assert(wayland_context.shm != null);

    std.log.scoped(.Output).debug("width: {}, height: {}", .{ draw_context.output_context.width, draw_context.output_context.height });

    if (!draw_context.has_started) {
        if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");

        const surface = try wayland_context.compositor.?.createSurface();
        draw_context.surface = surface;

        surface.setListener(*WaylandContext, surfaceListener, wayland_context);

        const layer_surface = try wayland_context.layer_shell.?.getLayerSurface(
            surface,
            draw_context.output_context.output,
            constants.WAYLAND_LAYER,
            constants.WAYLAND_NAMESPACE,
        );
        draw_context.layer_surface = layer_surface;

        layer_surface.setSize(config.width orelse 0, config.height);
        layer_surface.setAnchor(constants.WAYLAND_ZWLR_ANCHOR);
        layer_surface.setExclusiveZone(config.height);
        layer_surface.setKeyboardInteractivity(zwlr.LayerSurfaceV1.KeyboardInteractivity.none);

        layer_surface.setListener(*WaylandContext, layerSurfaceListener, wayland_context);

        draw_context.surface.?.commit();
        if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");

        try draw_context.initializeShm(wayland_context);
        draw_context.has_started = true;
    } else {
        @panic("resizing output unimplemented");
    }

    assert(draw_context.layer_surface != null);
    assert(draw_context.shm_buffer != null);
    assert(draw_context.shm_fd != null);

    draw_context.initWidgets();

    draw_context.draw(wayland_context);
    draw_context.surface.?.attach(draw_context.shm_buffer.?, 0, 0);

    if (draw_context.frame_callback) |fc| fc.destroy();
    draw_context.frame_callback = draw_context.surface.?.frame() catch @panic("Getting Frame Callback Failed.");
    draw_context.frame_callback.?.setListener(*WaylandContext, nextFrame, wayland_context);

    draw_context.surface.?.commit();
}

fn initWidgets(draw_context: *DrawContext) void {
    if (!options.clock_disable) {
        var clock = Clock.init(.{
            .text_color = config.text_color,
            .background_color = config.background_color,

            .spacer_color = colors.pine,

            .padding = 0,
            .padding_north = @intCast(draw_context.window_area.height / 6),
            .padding_south = @intCast(draw_context.window_area.height / 6),

            .area = .{
                .x = 0,
                .y = 0,
                .width = 1000,
                .height = draw_context.window_area.height,
            },
        });

        var center_area = clock.widget.area;
        center_area.width = clock.getWidth();

        clock.setArea(draw_context.window_area.center(center_area.dims()));

        draw_context.widget_center = clock;
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
                .height = draw_context.window_area.height,
            },
        }) catch |err| {
            log.warn("Failed to initialize Workspace with: {s}", .{@errorName(err)});
            break :workspaces;
        };

        var left_area = workspaces.widget.area;
        left_area.width = workspaces.getWidth();

        workspaces.setArea(left_area);

        draw_context.widget_left = workspaces;
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

            .padding = @as(u16, @intCast(draw_context.window_area.height / 10)),

            .area = .{
                .x = draw_context.window_area.width - 1000,
                .y = 0,
                .width = 1000,
                .height = draw_context.window_area.height,
            },
        }) catch |err| {
            log.warn("Failed to initalized Battery with: {s}", .{@errorName(err)});
            break :battery;
        };

        var right_area = battery.widget.area;
        right_area.width = battery.getWidth();
        right_area.x = draw_context.window_area.width - right_area.width;

        battery.widget.setArea(right_area);
        log.debug("battery: area: {}, {}", .{ battery.widget.area, battery.progress_area });

        battery.widget.area.assertContains(battery.progress_area);

        draw_context.widget_right = battery;
    }
}

pub fn nextFrame(callback: *wl.Callback, event: wl.Callback.Event, wayland_context: *WaylandContext) void {
    // make sure no other events can happen.
    switch (event) {
        .done => {},
    }

    const output_checker = struct {
        pub fn checker(draw_context: *const DrawContext, target: *wl.Callback) bool {
            return draw_context.frame_callback == target;
        }
    }.checker;

    // if not found, return because the output likely isn't alive anymore and this callback is stale.
    const output_idx = wayland_context.findOutput(
        *wl.Callback,
        callback,
        &output_checker,
    ) orelse @panic("Output not found for drawing!");

    const draw_context = &wayland_context.outputs.items[output_idx];

    draw_context.draw(wayland_context);

    if (draw_context.frame_callback) |fc| fc.destroy();
    draw_context.frame_callback = draw_context.surface.?.frame() catch @panic("Failed Getting Frame Callback.");
    draw_context.frame_callback.?.setListener(*WaylandContext, nextFrame, wayland_context);

    draw_context.surface.?.attach(draw_context.shm_buffer.?, 0, 0);
    draw_context.surface.?.commit();
}

pub fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, wayland_context: *WaylandContext) void {
    const output_checker = struct {
        pub fn checker(draw_context: *const DrawContext, target: *zwlr.LayerSurfaceV1) bool {
            return draw_context.layer_surface == target;
        }
    }.checker;

    const output_idx = wayland_context.findOutput(
        *zwlr.LayerSurfaceV1,
        layer_surface,
        &output_checker,
    ) orelse @panic("LayerSurface not found for event!");

    const draw_context = &wayland_context.outputs.items[output_idx];

    switch (event) {
        .configure => |configure| {
            log.debug("Output: '{s}', Layer Shell was configured. width: {}, height: {}", .{
                draw_context.output_context.name,
                configure.width,
                configure.height,
            });
            draw_context.window_area.width = @intCast(configure.width);
            draw_context.window_area.height = @intCast(configure.height);

            layer_surface.ackConfigure(configure.serial);
        },
        .closed => {
            // TODO: Make sure this is cleaned up properly. I think it is...
            log.debug("Output: '{s}', Surface done", .{draw_context.output_context.name});
            draw_context.layer_surface = null;
        },
    }
}

pub fn surfaceListener(surface: *wl.Surface, event: wl.Surface.Event, wayland_context: *WaylandContext) void {
    _ = surface;
    _ = wayland_context;

    switch (event) {
        // TODO: Use this for scaling and transform
        .enter, .leave, .preferred_buffer_scale, .preferred_buffer_transform => {},
    }
}

pub fn outputListener(output: *wl.Output, event: wl.Output.Event, wayland_context: *WaylandContext) void {
    const output_checker = struct {
        pub fn checker(draw_context: *const DrawContext, target: *wl.Output) bool {
            return draw_context.output_context.output == target;
        }
    }.checker;

    const output_idx = wayland_context.findOutput(*wl.Output, output, &output_checker) orelse @panic("Output not found!");

    var draw_context = &wayland_context.outputs.items[output_idx];
    var output_context = &draw_context.output_context;

    if (output_context.has_name) {
        log.debug("Output '{s}' (id #{}) had event {s}", .{ output_context.name, output_context.id, @tagName(event) });
    } else {
        log.debug("Output id #{} had event {s}", .{ output_context.id, @tagName(event) });
    }

    switch (event) {
        .geometry => |geometry| {
            assert(geometry.physical_width >= 0);
            assert(geometry.physical_height >= 0);

            output_context.changed = output_context.physical_height != geometry.physical_height or output_context.physical_width != geometry.physical_width;

            output_context.physical_height = @intCast(geometry.physical_height);
            output_context.physical_width = @intCast(geometry.physical_width);
            output_context.has_geometry = true;
        },
        .mode => |mode| {
            assert(mode.width >= 0);
            assert(mode.height >= 0);

            output_context.changed = output_context.height != mode.height or output_context.width != mode.width;

            output_context.height = @intCast(mode.height);
            output_context.width = @intCast(mode.width);
            output_context.has_mode = true;
        },
        .name => |name| {
            assert(!output_context.has_name); // protocol says name can only be set one.
            output_context.has_name = true;

            const name_str = mem.span(name.name);
            assert(name_str.len > 0);

            const name_str_owned = wayland_context.allocator.alloc(u8, name_str.len) catch |err| panic("error: {s}", .{@errorName(err)});
            @memcpy(name_str_owned, name_str);

            output_context.name = name_str_owned;
        },
        .scale, .description => {},
        .done => {
            assert(output_context.has_geometry);
            assert(output_context.has_name);
            assert(output_context.has_mode);

            if (output_context.height > 0 and output_context.width > 0) {
                if (output_context.changed) {
                    log.info("Output '{s}' changed, valid height.", .{output_context.name});
                    draw_context.outputChanged(wayland_context) catch |err| panic("error: {s}", .{@errorName(err)});
                }
            } else {
                if (output_context.changed) {
                    log.info("Output '{s}' changed, zero size.", .{output_context.name});
                    // TODO: shouldn't render (zero size)-- make sure it doesn't.
                }
            }

            output_context.changed = false;
        },
    }
}

/// Draw all widgets on to the draw_context's buffer.
pub fn draw(draw_context: *DrawContext, wayland_context: *WaylandContext) void {
    _ = wayland_context;

    if (draw_context.full_redraw) {
        draw_context.current_area = draw_context.window_area;
        draw_context.window_area.drawArea(draw_context, config.background_color);
    }

    inline for (.{ "widget_left", "widget_center", "widget_right" }) |name| {
        if (@TypeOf(@field(draw_context, name)) == void) continue;

        if (@field(draw_context, name)) |*w| {
            if (@TypeOf(w) != *void) {
                draw_context.current_area = w.widget.area;
                w.widget.draw(draw_context) catch |err| log.warn("Drawing of '{s}' failed with: '{s}'", .{ name, @errorName(err) });
            }
        }
    }

    if (options.track_damage) {
        while (draw_context.damage_prev.popOrNull()) |damage_last| {
            damage_last.drawOutline(draw_context, config.background_color);
            damage_last.damageOutline(draw_context);
        }

        assert(draw_context.damage_prev.len == 0);
        assert(draw_context.damage_list.len < MAX_DAMAGE_LIST_LEN);

        draw_context.current_area = draw_context.window_area;

        while (draw_context.damage_list.popOrNull()) |damage_item| {
            draw_context.damage_prev.appendAssumeCapacity(damage_item);
            damage_item.drawOutline(draw_context, colors.damage);
        }
    }

    draw_context.full_redraw = false;
}

pub const DrawBitmapArgs = struct {
    /// The glyph to draw
    glyph: *FreeTypeContext.Glyph,

    /// Color to color glyph
    text_color: Color,

    /// Maximum area the glyph can take up
    max_area: Rect,

    /// The origin of the glyph (bottom right-ish)
    origin: Point,

    /// Mainly used for debugging.
    /// change dimensions if it is rotated right or left.
    /// Draw all pixels at full strength if there
    /// is any alpha in the bitmap.
    no_alpha: bool,
};

/// Draws a bitmap onto the draw_context's screen in the given max_area.
/// Any parts the extend past the max_area are not drawn.
/// This does not damage the draw_context, but assumes the caller will.
///
/// Returns immediately if the bitmap or the glyph's area have a zero height or width.
pub fn drawBitmap(draw_context: *const DrawContext, args: DrawBitmapArgs) void {
    assert(args.glyph.load_mode == .render);
    assert(args.glyph.bitmap_buffer != null);
    const glyph = args.glyph;

    if (glyph.bitmap_height == 0 or glyph.bitmap_width == 0) return;

    const glyph_area = Rect{
        .x = @intCast(args.origin.x + glyph.bitmap_left),
        .y = @intCast(args.origin.y -| glyph.bitmap_top),
        .width = glyph.bitmap_width,
        .height = glyph.bitmap_height,
    };

    if (glyph_area.width == 0 or glyph_area.height == 0) return;

    const used_area = args.max_area.intersection(glyph_area) orelse return;

    assert(used_area.width > 0);
    assert(used_area.height > 0);

    const y_start_local = used_area.y - glyph_area.y;

    for (y_start_local..y_start_local + used_area.height) |y_coord_local| {
        assert(y_coord_local <= glyph_area.height);
        const bitmap_row = glyph.bitmap_buffer.?[y_coord_local * glyph.bitmap_width ..][0..glyph.bitmap_width];

        const x_start_local = used_area.x - glyph_area.x;

        for (x_start_local..x_start_local + used_area.width) |x_coord_local| {
            assert(x_coord_local <= glyph_area.width);

            const point = Point{ .x = @intCast(x_coord_local), .y = @intCast(y_coord_local) };

            const alpha = bitmap_row[x_coord_local];

            if (args.no_alpha) {
                if (alpha > 0) glyph_area.putPixel(draw_context, point, args.text_color);
            } else {
                glyph_area.putComposite(
                    draw_context,
                    point,
                    args.text_color.withAlpha(alpha),
                );
            }
        }
    }
}

test drawBitmap {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;

    const window_area = Rect{
        .x = 0,
        .y = 0,
        .width = 10,
        .height = 10,
    };

    const draw_context = DrawContext{
        .output_context = undefined,
        .screen = try allocator.alloc(Color, window_area.width * window_area.height),
        .window_area = window_area,
        .current_area = window_area,
    };
    defer allocator.free(draw_context.screen);

    @memset(draw_context.screen, colors.black);

    const buffer = try allocator.alloc(u8, window_area.width * window_area.height);
    defer allocator.free(buffer);
    @memset(buffer, 0);

    var glyph = FreeTypeContext.Glyph{
        .metrics = undefined,
        .advance_x = undefined,
        .time = undefined,
        .transformed = false,
        .load_mode = .render,
        .bitmap_top = 0,
        .bitmap_left = 0,
        .bitmap_width = window_area.width,
        .bitmap_height = window_area.height,
        .bitmap_buffer = buffer,
    };

    drawBitmap(&draw_context, .{
        .glyph = &glyph,
        .text_color = colors.main,
        .max_area = window_area,

        .no_alpha = false,

        .origin = .{
            .x = 0,
            .y = 0,
        },
    });

    for (draw_context.screen) |pixel| {
        try expect(@as(u32, @bitCast(pixel)) == @as(u32, @bitCast(colors.black)));
    }

    @memset(buffer, std.math.maxInt(u8));

    drawBitmap(&draw_context, .{
        .glyph = &glyph,
        .text_color = colors.main,
        .max_area = window_area,

        .no_alpha = false,

        .origin = .{
            .x = 0,
            .y = 0,
        },
    });

    for (draw_context.screen) |pixel| {
        try expect(@as(u32, @bitCast(pixel)) == @as(u32, @bitCast(colors.main)));
    }

    @memset(buffer, maxInt(u8) / 2);

    const result = colors.main.composite(colors.rose.withAlpha(maxInt(u8) / 2));

    drawBitmap(&draw_context, .{
        .glyph = &glyph,
        .text_color = colors.rose,
        .max_area = window_area,

        .no_alpha = false,

        .origin = .{
            .x = 0,
            .y = 0,
        },
    });

    for (draw_context.screen) |pixel| {
        try std.testing.expectEqual(@as(u32, @bitCast(pixel)), @as(u32, @bitCast(result)));
    }
}

pub fn motion(draw_context: *DrawContext, point: Point) void {
    const last_motion = draw_context.last_motion;
    defer draw_context.last_motion = point;

    inline for (.{
        "widget_left",
        "widget_center",
        "widget_right",
    }) |widget_name| {
        if (@TypeOf(@field(draw_context, widget_name)) == void) continue;
        if (@field(draw_context, widget_name)) |*widget| {
            const area = widget.widget.area;
            if (last_motion) |lm| {
                if (area.containsPoint(lm) and !area.containsPoint(point)) widget.widget.leave();
                if (!area.containsPoint(lm) and area.containsPoint(point)) widget.widget.motion(point);
            }
            if (area.containsPoint(point)) widget.widget.motion(point);
        }
    }
}

pub fn leave(draw_context: *DrawContext) void {
    var left = false;
    inline for (.{
        "widget_left",
        "widget_center",
        "widget_right",
    }) |widget_name| {
        if (@TypeOf(@field(draw_context, widget_name)) == void) continue;
        if (draw_context.last_motion) |last_motion| {
            if (@field(draw_context, widget_name)) |*widget| {
                if (widget.widget.area.containsPoint(last_motion)) {
                    // make sure no widgets overlap
                    assert(!left);
                    widget.widget.leave();
                    left = true;
                }
            }
        }
    }
    draw_context.last_motion = null;
}

pub fn click(draw_context: *DrawContext, button: MouseButton) void {
    var left = false;
    inline for (.{
        "widget_left",
        "widget_center",
        "widget_right",
    }) |widget_name| {
        if (@TypeOf(@field(draw_context, widget_name)) == void) continue;
        if (draw_context.last_motion) |last_motion| {
            if (@field(draw_context, widget_name)) |*widget| {
                if (widget.widget.area.containsPoint(last_motion)) {
                    assert(!left);
                    widget.widget.click(draw_context.last_motion.?, button);
                    left = true;
                }
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
const seat_utils = @import("seat_utils.zig");
const MouseButton = seat_utils.MouseButton;

const WaylandContext = @import("WaylandContext.zig");
const FreeTypeContext = @import("FreeTypeContext.zig");
const freetype = FreeTypeContext.freetype;

const constants = @import("constants.zig");
const options = @import("options");

const colors = @import("colors.zig");
const Color = colors.Color;
const all_colors = colors.all_colors;

const Config = @import("Config.zig");
const config = &Config.global;

const Workspaces = @import("Workspaces/Workspaces.zig");
const Battery = @import("Battery.zig");
const Clock = @import("Clock.zig");

const drawing = @import("drawing.zig");
const Widget = drawing.Widget;
const Point = drawing.Point;
const Rect = drawing.Rect;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const meta = std.meta;

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;

const panic = std.debug.panic;
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

const log = std.log.scoped(.DrawContext);
