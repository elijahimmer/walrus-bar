pub const WAYLAND_NAMESPACE: [:0]const u8 = "elijahimmer/walrus-bar";
pub const WAYLAND_LAYER: zwlr.LayerShellV1.Layer = .bottom;
pub const WAYLAND_ZWLR_ANCHOR: zwlr.LayerSurfaceV1.Anchor = .{
    .top = true,
    .bottom = false,
    .left = true,
    .right = true,
};

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
