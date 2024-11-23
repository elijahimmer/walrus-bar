pub const WorkspaceState = @This();

const workspaces_worker_name: [:0]const u8 = "Workspaces";

comptime {
    assert(workspaces_worker_name.len <= Thread.max_name_len);
}

const Impl = switch (options.workspaces_provider) {
    .hyprland => @import("hyprland.zig"),
    .testing => @import("testing.zig"),
    .none => @import("none.zig"),
};
pub const setWorkspace = &Impl.setWorkspace;

pub const WorkspaceID = i32;

pub var global = WorkspaceState{
    .rc = .{ .raw = 0 },
    .worker_thread = undefined,
    .rwlock = .{},
    .workspaces = .{},
    .active_workspace = 0,
};

/// only use this on the main thread.
rc: std.atomic.Value(WorkspaceID),
worker_thread: ?Thread,

rwlock: Thread.RwLock,

workspaces: WorkspaceArray,
active_workspace: WorkspaceID,

// whether or not to log if we failed to find the hyprland instance.
logged_service_not_found: bool = false,

// When error.ServiceNotFound is returned,
// the state will be valid, just empty with an invalid thread
pub fn init(self: *WorkspaceState) !void {
    _ = self.rc.fetchAdd(1, .monotonic);
    errdefer _ = self.rc.fetchSub(1, .monotonic);

    if (!Impl.available()) {
        if (!self.logged_service_not_found) log.warn(@tagName(options.workspaces_provider) ++ " Not Found", .{});

        self.logged_service_not_found = true;
        return error.ServiceNotFound;
    }

    self.logged_service_not_found = false;

    if (self.worker_thread == null) {
        self.rwlock = .{};
        self.active_workspace = 0;
        self.worker_thread = try Thread.spawn(.{}, Impl.work, .{self});
        self.worker_thread.?.setName(workspaces_worker_name) catch |err| {
            // we don't really care about the name, just log the error
            log.warn("Failed to set Workspaces Worker Thread's name with: {s}", .{@errorName(err)});
        };
    }
}

pub fn deinit(self: *WorkspaceState) void {
    const rc_remaining = rc_remaining: {
        var rc = self.rc.load(.acquire);
        defer self.rc.store(rc, .release);

        assert(rc > 0);
        rc -= 1;

        break :rc_remaining rc;
    };

    // if the previous value was 1 or less (so it is not zero)
    if (rc_remaining == 0) {
        self.logged_service_not_found = false;

        if (self.worker_thread) |*thread| {
            defer self.worker_thread = null;

            log.debug("Joining Worker...", .{});
            thread.join();
            log.debug("Worker Joined.", .{});
        } else {
            log.debug("Worker not started.", .{});
        }

        assert(self.rwlock.tryLock());
        self.rwlock.unlock();

        self.* = .{
            .rc = .{ .raw = 0 },
            .worker_thread = null,
            .rwlock = .{},
            .workspaces = .{},
            .active_workspace = 0,
        };
    }
}

pub const RC = u32;
pub const WorkspaceIndex = u4;
pub const max_workspace_count = std.math.maxInt(WorkspaceIndex);
pub const WorkspaceArray = BoundedArray(WorkspaceID, max_workspace_count);

const options = @import("options");
const log = std.log.scoped(.Workspaces);

const std = @import("std");
const atomic = std.atomic;

const assert = std.debug.assert;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
