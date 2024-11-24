//! All the stuff needed for a popup window.

pub const Popup = @This();

wayland_context: *WaylandContext,

full_redraw: bool = true,

/// the wayland surface itself.
surface: *wl.Surface,

/// The xdg surface which is a popup
xdg_surface: *xdg.Surface,

/// The thing that says where the popup should be
xdg_positioner: *xdg.Positioner,

/// The actual popup
xdg_popup: *xdg.Popup,

/// The size of the window.
window_size: Point = Point.ZERO,

/// The memory pool for the popup.
shm_pool: ShmPool,

/// The callback to draw the next frame.
frame_callback: ?*wl.Callback = null,

/// The
widget: TextBox,

/// uses the area of the text_box_init_args for how big this should be.
pub fn init(output: *const Output, text_box_init_args: TextBox.InitArgs) !Popup {
    log.debug("Initializing popup for output: '{s}'", .{output.output_context.name_str.constSlice()});
    const area = text_box_init_args.area;
    assert(area.x == 0);
    assert(area.y == 0);

    const wayland_context = output.wayland_context;
    assert(wayland_context.compositor != null);
    assert(wayland_context.xdg_wm_base != null);
    assert(output.surface != null);

    const compositor = wayland_context.compositor.?;
    const xdg_wm_base = wayland_context.xdg_wm_base.?;

    const surface = try compositor.createSurface();

    surface.setListener(*WaylandContext, surfaceListener, wayland_context);

    const xdg_surface = try xdg_wm_base.getXdgSurface(surface);

    xdg_surface.setListener(*WaylandContext, xdgSurfaceListener, wayland_context);
    xdg_surface.setWindowGeometry(area.x, area.y, area.width, area.height);

    surface.commit();
    if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");

    const xdg_positioner = try xdg_wm_base.createPositioner();

    const xdg_popup = try xdg_surface.getPopup(xdg_surface, xdg_positioner);

    xdg_popup.setListener(*WaylandContext, xdgPopupListener, wayland_context);

    surface.commit();
    if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");

    const frame_callback = surface.frame() catch @panic("Failed Getting Frame Callback.");
    frame_callback.setListener(*WaylandContext, nextFrame, wayland_context);

    return Popup{
        .wayland_context = wayland_context,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .xdg_positioner = xdg_positioner,
        .xdg_popup = xdg_popup,

        // the following are set by initializeShm
        .shm_pool = try ShmPool.init(.{
            .wayland_context = wayland_context,
            .height = area.height,
            .width = area.width,
        }),

        // this is set after first draw.
        .frame_callback = undefined,

        .widget = TextBox.init(text_box_init_args),
    };
}

const InitializeShmError = posix.MMapError || posix.MemFdCreateError || posix.TruncateError;
fn initializeShm(self: *Popup, wayland_context: *WaylandContext) InitializeShmError!void {
    assert(self.output.wayland_context == wayland_context);

    assert(wayland_context.shm != null);

    const width = self.widget.area.width;
    const height = self.widget.area.height;
    const stride = @as(u31, width) * @sizeOf(Color);

    const size: u31 = stride * @as(u31, height);
    const fd = try posix.memfd_createZ(constants.WAYLAND_NAMESPACE, 0);
    self.shm_fd = fd;
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
    assert(screen_adjusted.len * @sizeOf(Color) == screen.len);

    self.screen = screen_adjusted;

    const shm_pool = try wayland_context.shm.?.createPool(fd, size);

    self.shm_buffer = try shm_pool.createBuffer(0, width, height, stride, Color.FORMAT);
}

pub fn deinit(self: *Popup) void {
    self.surface.destroy();
    self.xdg_surface.destroy();
    self.xdg_positioner.destroy();
    self.* = undefined;
}

pub fn surfaceListener(surface: *wl.Surface, event: wl.Surface.Event, wayland_context: *WaylandContext) void {
    _ = surface;
    _ = wayland_context;

    switch (event) {
        // TODO: Use this for scaling and transform
        .enter, .leave, .preferred_buffer_scale, .preferred_buffer_transform => {},
    }
}

pub fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, wayland_context: *WaylandContext) void {
    _ = wayland_context;

    switch (event) {
        .configure => |configure| {
            log.debug("popup got xdg_surface configure event.", .{});
            xdg_surface.ackConfigure(configure.serial);
        },
    }
}

pub fn xdgPopupListener(xdg_popup: *xdg.Popup, event: xdg.Popup.Event, wayland_context: *WaylandContext) void {
    const output = wayland_context.findOutput(*const xdg.Popup, xdg_popup, struct {
        pub fn check(output: *const Output, item: *const xdg.Popup) bool {
            return output.popup != null and output.popup.?.xdg_popup == item;
        }
    }.check) orelse unreachable;

    assert(output.wayland_context == wayland_context);

    assert(output.popup != null);

    switch (event) {
        .configure => |configure| {
            // TODO: do ack this configure, or do we let the xdg surface do that?
            _ = configure;
            log.debug("popup got xdg popup configure event.", .{});
            //draw_context.popup.?.xdg_surface.ackConfigure(configure.serial);
        },
        .popup_done => {
            output.popup.?.deinit();
            output.popup = null;
        },
    }
}

pub fn nextFrame(callback: *wl.Callback, event: wl.Callback.Event, wayland_context: *WaylandContext) void {
    log.debug("Popup next frame.", .{});

    // make sure no other events can happen.
    switch (event) {
        .done => {},
    }

    const output_checker = struct {
        pub fn checker(output: *const Output, target: *wl.Callback) bool {
            return output.popup != null and output.popup.?.frame_callback == target;
        }
    }.checker;

    // if not found, return because the output likely isn't alive anymore and this callback is stale.
    const output = wayland_context.findOutput(
        *wl.Callback,
        callback,
        &output_checker,
    ) orelse @panic("Output not found for drawing!");
    assert(output.popup != null);
    assert(output.popup.?.frame_callback != null);

    const popup = &output.popup.?;

    defer {
        // make new frame callback
        popup.frame_callback.?.destroy();
        popup.frame_callback = popup.surface.frame() catch @panic("Failed Getting Frame Callback.");
        popup.frame_callback.?.setListener(*WaylandContext, nextFrame, wayland_context);

        popup.surface.commit();
    }

    const buffer, const screen = popup.shm_pool.getBuffer() orelse return;

    var draw_context = DrawContext{
        .surface = output.surface.?,
        .window_area = output.window_size.extendTo(Point.ZERO),
        .screen = screen,

        .current_area = Rect.ZERO,

        .full_redraw = output.full_redraw,
    };
    defer draw_context.deinit();
    defer popup.full_redraw = false;

    popup.widget.draw(&draw_context);

    // commit the changes.
    popup.surface.attach(buffer, 0, 0);
}

const constants = @import("constants.zig");

const colors = @import("colors.zig");
const Color = colors.Color;

const drawing = @import("drawing.zig");
const Point = drawing.Point;
const Rect = drawing.Rect;

const TextBox = @import("TextBox.zig");

const WaylandContext = @import("WaylandContext.zig");
const DrawContext = @import("DrawContext.zig");
const ShmPool = @import("ShmPool.zig");
const Output = @import("Output.zig");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const posix = std.posix;

const assert = std.debug.assert;

const log = std.log.scoped(.Popup);
