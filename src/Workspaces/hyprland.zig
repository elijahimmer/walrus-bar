pub const utils = @import("hyprland/utils.zig");
pub const worker = @import("hyprland/worker.zig");

pub const work = worker.work;
pub const available = utils.hyprlandExists;

test {
    std.testing.refAllDecls(utils);
    std.testing.refAllDecls(worker);
}

const std = @import("std");
