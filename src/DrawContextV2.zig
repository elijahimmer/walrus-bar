//! The context for drawing and damaging a surface.

pub const DrawContext = @This();

pub const MAX_DAMAGE_LIST_LEN = 16;
pub const DamageList = if (options.track_damage) BoundedArray(Rect, MAX_DAMAGE_LIST_LEN) else void;
pub const damage_list_init = if (options.track_damage) .{} else {};

surface: *wl.Surface,

current_area: Rect = undefined,

window_area: Rect,

screen: []Color = undefined,

damage_list: DamageList = damage_list_init,
damage_prev: DamageList = damage_list_init,

pub const InitArgs = struct {
    surface: *wl.Surface,
    shm_pool: *wl.ShmPool,
    frame_callback: *wl.Callback,
};

pub fn init(args: InitArgs) DrawContext {
    return DrawContext{
        .surface = args.surface,
        .window_area = .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        },
    };
}

pub fn deinit(draw_context: *DrawContext) void {
    _ = draw_context;
}

pub fn damage(draw_context: *DrawContext, area: Rect) void {
    draw_context.current_area.assertContains(area);

    if (options.track_damage) {
        draw_context.damage_list.append(area) catch @panic("the Damage list is full, increase list size.");
    } else {
        draw_context.surface.?.damageBuffer(area.x, area.y, area.width, area.height);
    }
}

const options = @import("options.zig");

const drawing = @import("drawing.zig");
const Size = drawing.Size;
const Rect = drawing.Rect;

const colors = @import("colors.zig");
const Color = colors.Color;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const BoundedArray = std.BoundedArray;
