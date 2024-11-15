//! All the stuff needed for a popup window.

pub const Popup = @This();

draw_context: *const DrawContext,

surface: *wl.Surface,
xdg_surface: *xdg.Surface,
xdg_positioner: *xdg.Positioner,
xdg_popup: *xdg.Popup,

shm_buffer: *wl.Buffer,
shm_fd: posix.fd_t,

screen: []const Color,

frame_callback: *wl.Callback,

widget: TextBox,

/// uses the area of the text_box_init_args for how big this should be.
pub fn init(draw_context: *const DrawContext, text_box_init_args: TextBox.InitArgs) !Popup {
    log.debug("Initializing popup for output: '{s}'", .{draw_context.output_context.name});
    const area = text_box_init_args.area;
    assert(area.x == 0);
    assert(area.y == 0);

    const wayland_context = draw_context.wayland_context;
    assert(wayland_context.compositor != null);
    assert(wayland_context.xdg_wm_base != null);
    assert(draw_context.surface != null);

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

    var popup = Popup{
        .draw_context = draw_context,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .xdg_positioner = xdg_positioner,
        .xdg_popup = xdg_popup,

        // the following are set by initializeShm
        .shm_buffer = undefined,
        .shm_fd = undefined,
        .screen = undefined,

        // this is set after first draw.
        .frame_callback = undefined,

        .widget = TextBox.init(text_box_init_args),
    };

    try popup.initializeShm(wayland_context);
    surface.commit();
    if (wayland_context.display.roundtrip() != .SUCCESS) @panic("Roundtrip Failed");

    draw_context.surface.?.attach(draw_context.shm_buffer.?, 0, 0);

    const frame_callback = surface.frame() catch @panic("Failed Getting Frame Callback.");
    frame_callback.setListener(*WaylandContext, nextFrame, wayland_context);

    return popup;
}

const InitializeShmError = posix.MMapError || posix.MemFdCreateError || posix.TruncateError;
fn initializeShm(self: *Popup, wayland_context: *WaylandContext) InitializeShmError!void {
    assert(self.draw_context.wayland_context == wayland_context);

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
    log.debug("destroying popup for output: '{s}'", .{self.draw_context.output_context.name});
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
    const output_idx = wayland_context.findOutput(*const xdg.Popup, xdg_popup, struct {
        pub fn check(draw_context: *const DrawContext, item: *const xdg.Popup) bool {
            return draw_context.popup != null and draw_context.popup.?.xdg_popup == item;
        }
    }.check);
    assert(output_idx != null);

    const draw_context = &wayland_context.outputs.items[output_idx.?];
    assert(draw_context.wayland_context == wayland_context);

    assert(draw_context.popup != null);

    switch (event) {
        .configure => |configure| {
            // TODO: do ack this configure, or do we let the xdg surface do that?
            _ = configure;
            log.debug("popup got xdg popup configure event.", .{});
            //draw_context.popup.?.xdg_surface.ackConfigure(configure.serial);
        },
        .popup_done => {
            draw_context.popup.?.deinit();
            draw_context.popup = null;
        },
        // ignore this.
        .repositioned => {},
    }
}

pub fn nextFrame(callback: *wl.Callback, event: wl.Callback.Event, wayland_context: *WaylandContext) void {
    log.debug("Popup next frame.", .{});
    // make sure no other events can happen.
    switch (event) {
        .done => {},
    }

    const output_checker = struct {
        pub fn checker(draw_context: *const DrawContext, target: *wl.Callback) bool {
            return draw_context.popup != null and draw_context.popup.?.frame_callback == target;
        }
    }.checker;

    // if not found, return because the output likely isn't alive anymore and this callback is stale.
    const output_idx = wayland_context.findOutput(
        *wl.Callback,
        callback,
        &output_checker,
    ) orelse @panic("Output not found for drawing!");

    const draw_context = &wayland_context.outputs.items[output_idx];
    assert(draw_context.wayland_context == wayland_context);
    assert(draw_context.popup != null);

    const popup = &draw_context.popup.?;

    popup.frame_callback.destroy();
    popup.frame_callback = popup.surface.frame() catch @panic("Failed Getting Frame Callback.");
    popup.frame_callback.setListener(*WaylandContext, nextFrame, wayland_context);

    popup.surface.attach(popup.shm_buffer, 0, 0);
    popup.surface.commit();
}

const constants = @import("constants.zig");

const colors = @import("colors.zig");
const Color = colors.Color;

const drawing = @import("drawing.zig");

const TextBox = @import("TextBox.zig");

const WaylandContext = @import("WaylandContext.zig");
const DrawContext = @import("DrawContext.zig");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const posix = std.posix;

const assert = std.debug.assert;

const log = std.log.scoped(.Popup);
