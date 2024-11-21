pub const WAYLAND_NAMESPACE: [:0]const u8 = "elijahimmer/walrus-bar";
pub const WAYLAND_LAYER: zwlr.LayerShellV1.Layer = .top;
pub const WAYLAND_ZWLR_ANCHOR: zwlr.LayerSurfaceV1.Anchor = .{
    .top = true,
    .bottom = false,
    .left = true,
    .right = true,
};

pub const DEFAULT_WINDOW_HEIGHT = 28;
pub const MINIMUM_WINDOW_HEIGHT = 15;
pub const MINIMUM_WINDOW_WIDTH = 500;

pub const version_str = versions.version;
pub const version = SemanticVersion.parse(versions.version) catch unreachable;

pub const freetype_version_str = std.fmt.comptimePrint("{}.{}.{}", .{
    freetype.FREETYPE_MAJOR,
    freetype.FREETYPE_MINOR,
    freetype.FREETYPE_PATCH,
});
pub const freetype_version = SemanticVersion{
    .major = freetype.FREETYPE_MAJOR,
    .minor = freetype.FREETYPE_MINOR,
    .patch = freetype.FREETYPE_PATCH,
};

const versions = @import("versions");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const freetype = @import("freetype_utils.zig").freetype;

const std = @import("std");

const SemanticVersion = std.SemanticVersion;
