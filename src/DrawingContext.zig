pub const DrawingContext = @This();

const OutputContext = @import("OutputContext.zig");
const config = &@import("Config.zig").config;
const freetype_context = &@import("FreetypeContext.zig").global;
const wayland_context = &@import("WaylandContext.zig").global;

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

const log = std.log.scoped(.FreetypeContext);
