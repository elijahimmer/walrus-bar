//! The context for drawing and damaging a surface.

pub const DrawContext = @This();

pub const MAX_DAMAGE_LIST_LEN = 16;
pub const DamageList = if (options.track_damage) BoundedArray(Rect, MAX_DAMAGE_LIST_LEN) else void;
pub const damage_list_init = if (options.track_damage) .{} else {};

surface: *wl.Surface,

current_area: Rect,
window_area: Rect,

screen: []Color,

damage_list: DamageList = damage_list_init,
damage_prev: DamageList = damage_list_init,

full_redraw: bool,

/// Damages the given area of the surface in window coordinates.
pub fn damage(draw_context: *DrawContext, area: Rect) void {
    // no need for damage on full redraw. The whole thing is damaged.
    if (draw_context.full_redraw) return;
    draw_context.current_area.assertContains(area);

    if (options.track_damage) {
        draw_context.damage_list.append(area) catch @panic("the Damage list is full, increase list size.");
    } else {
        draw_context.surface.damageBuffer(area.x, area.y, area.width, area.height);
    }
}

pub fn deinit(draw_context: *DrawContext) void {
    if (options.track_damage and !draw_context.full_redraw) {
        // TODO: do Damage tracking here.

        var prev_loop_counter: usize = 0;
        while (draw_context.damage_prev.popOrNull()) |damage_last| : (prev_loop_counter += 1) {
            assert(prev_loop_counter < MAX_DAMAGE_LIST_LEN);
            damage_last.drawOutline(draw_context, config.general.background_color);
            damage_last.damageOutline(draw_context);
        }

        assert(draw_context.damage_prev.len == 0);
        assert(draw_context.damage_list.len < MAX_DAMAGE_LIST_LEN);

        draw_context.current_area = draw_context.window_area;

        var damage_loop_counter: usize = 0;
        while (draw_context.damage_list.popOrNull()) |damage_item| : (damage_loop_counter += 1) {
            assert(damage_loop_counter < MAX_DAMAGE_LIST_LEN);

            draw_context.damage_prev.appendAssumeCapacity(damage_item);
            damage_item.drawOutline(draw_context, colors.damage);
        }
    }
}

const options = @import("options");

const FreeTypeContext = @import("FreeTypeContext.zig");

const drawing = @import("drawing.zig");
const Size = drawing.Size;
const Rect = drawing.Rect;

const colors = @import("colors.zig");
const Color = colors.Color;

const config = &@import("Config.zig").global;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const std = @import("std");
const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
