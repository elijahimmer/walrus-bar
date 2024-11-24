pub fn main() !void {
    defer if (std.debug.runtime_safety) checkForFileLeaks();

    // we don't need it. We do use stdout in config
    std.io.getStdIn().close();

    var gpa = std.heap.GeneralPurposeAllocator(.{
        // we should only ever use it on the main (wayland) thread.
        .thread_safe = false,
    }){};
    defer _ = gpa.deinit();

    var logging_allocator = std.heap.ScopedLoggingAllocator(.Allocations, .debug, .warn).init(gpa.allocator());
    const allocator = logging_allocator.allocator();

    try Config.init_global(allocator);
    defer Config.deinit_global();

    // don't use logging allocator as you can enable it separately.
    try FreeTypeContext.init_global(gpa.allocator(), Config.global.general.font_path);
    defer FreeTypeContext.global.deinit();

    // initialize the app's context.
    var wayland_context: WaylandContext = undefined;

    try WaylandContext.init(&wayland_context);
    defer wayland_context.deinit();

    while (wayland_context.running) {
        // dispatch and handle all messages to and fro.
        switch (wayland_context.display.dispatch()) {
            .SUCCESS => {},
            .INVAL => {
                // we sent a invalid response (which is a bug) and should just stop
                log.warn("Roundtrip Failed with Invalid Request", .{});
                break;
            },
            .CONNRESET => {
                log.warn("Connection reset. exiting...", .{});
                break;
            },
            else => |err| {
                log.warn("Roundtrip Failed with {s}", .{@tagName(err)});
                break;
            },
        }
    }

    log.info("Shutting Down...", .{});
}

pub fn checkForFileLeaks() void {
    log.info("Starting file leak test...", .{});

    const fd_dir_path = "/proc/self/fd/";

    const fd_dir = std.fs.openDirAbsoluteZ(fd_dir_path, .{ .iterate = true }) catch |err| {
        log.err("Failed to open directory holding open files with {s}", .{@errorName(err)});
        return;
    };

    var fd_dir_iter = fd_dir.iterateAssumeFirstIteration();

    var found_leaks = false;
    defer if (!found_leaks) log.info("No leaks found!", .{});

    var ignore_open_dir = false;

    iter_loop: while (fd_dir_iter.next()) |entry_maybe_null| {
        if (entry_maybe_null == null) break;
        const entry = &entry_maybe_null.?;

        var path_buff: [posix.PATH_MAX]u8 = undefined;
        const real_path = fd_dir.realpath(entry.name, &path_buff) catch |err| {
            switch (err) {
                error.FileNotFound => unreachable,
                else => log.warn("Failed to get real path from sym link file '{s}' with {s}", .{ entry.name, @errorName(err) }),
            }
            continue :iter_loop;
        };

        // ignore stdin/out/err files
        if (mem.eql(u8, real_path, "/dev/pts/0")) {
            continue;
        }

        // ignore the directory we are iterating through
        if (mem.startsWith(u8, real_path, "/proc/") and mem.endsWith(u8, real_path, "/fd")) this_dir: {
            const pid_str = real_path["/proc/".len .. real_path.len - "/fd".len];

            const pid_dir = std.fmt.parseInt(posix.pid_t, pid_str, 10) catch break :this_dir;

            // TODO: find a portable PID method.
            const pid = std.os.linux.getpid();

            // not the same PID
            if (pid != pid_dir) break :this_dir;

            if (ignore_open_dir) {
                log.warn("The open fd file directory '{s}' has been opened else ware!", .{real_path});
                continue;
            }
            ignore_open_dir = true;

            continue;
        }

        log.debug("file '{s}' open", .{entry.name});

        switch (entry.kind) {
            .sym_link => {
                found_leaks = true;

                log.warn("Failed to close file '{s}'", .{real_path});
            },
            else => {
                // I'm pretty sure only sym links should be here, but we might as well...
                found_leaks = true;

                log.warn("Failed to close file '{s}' which is a {s}", .{ entry.name, @tagName(entry.kind) });
            },
        }
    } else |err| {
        log.err("Failed to iterate open files directory with {s}", .{@errorName(err)});
        return;
    }
}

test {
    std.testing.refAllDecls(@This());

    std.testing.refAllDecls(@import("workspaces/Workspaces.zig"));
    std.testing.refAllDecls(@import("workspaces/hyprland.zig"));
    std.testing.refAllDecls(@import("workspaces/testing.zig"));
    std.testing.refAllDecls(@import("workspaces/none.zig"));
    std.testing.refAllDecls(@import("FreeTypeContext.zig"));
    std.testing.refAllDecls(@import("freetype_utils.zig"));
    std.testing.refAllDecls(@import("WaylandContext.zig"));
    std.testing.refAllDecls(@import("OutputContext.zig"));
    std.testing.refAllDecls(@import("RootContainer.zig"));
    std.testing.refAllDecls(@import("parse_config.zig"));
    std.testing.refAllDecls(@import("DrawContext.zig"));
    std.testing.refAllDecls(@import("draw_bitmap.zig"));
    std.testing.refAllDecls(@import("Brightness.zig"));
    std.testing.refAllDecls(@import("seat_utils.zig"));
    std.testing.refAllDecls(@import("constants.zig"));
    std.testing.refAllDecls(@import("Battery.zig"));
    std.testing.refAllDecls(@import("drawing.zig"));
    std.testing.refAllDecls(@import("TextBox.zig"));
    std.testing.refAllDecls(@import("logging.zig"));
    std.testing.refAllDecls(@import("ShmPool.zig"));
    std.testing.refAllDecls(@import("colors.zig"));
    std.testing.refAllDecls(@import("Config.zig"));
    std.testing.refAllDecls(@import("Output.zig"));
    std.testing.refAllDecls(@import("Clock.zig"));
    std.testing.refAllDecls(@import("Popup.zig"));
}

pub const std_options = .{
    .logFn = logging.logFn,
    .log_scope_levels = &logging.logging_scope_levels,
};

const WaylandContext = @import("WaylandContext.zig");
const DrawContext = @import("DrawContext.zig");

const wayland = @import("wayland");
const wl = wayland.client.wl;

const Config = @import("Config.zig");

const FreeTypeContext = @import("FreeTypeContext.zig");

const logging = @import("logging.zig");

const std = @import("std");
const posix = std.posix;
const mem = std.mem;

const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const panic = std.debug.panic;

const log = std.log.scoped(.@"walrus-bar");
