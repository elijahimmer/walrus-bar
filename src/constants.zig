pub const WAYLAND_NAMESPACE: [:0]const u8 = "elijahimmer/walrus-bar";
pub const WAYLAND_LAYER: zwlr.LayerShellV1.Layer = .top;
pub const WAYLAND_ZWLR_ANCHOR: zwlr.LayerSurfaceV1.Anchor = .{
    .top = true,
    .bottom = false,
    .left = true,
    .right = true,
};

// If the window is too small, some stuff won't work.
pub const MINIMUM_WINDOW_HEIGHT = 15;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
