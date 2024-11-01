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

pub const WorkspaceID = i32;

pub var global = WorkspaceState{
    .rc = .{ .raw = 0 },
    .worker_thread = undefined,
    .workspaces = .{},
    .active_workspace = 0,
};

/// only use this on the main thread.
rc: std.atomic.Value(WorkspaceID),
worker_thread: Thread,

rwlock: Thread.RwLock = .{},

workspaces: WorkspaceArray,
active_workspace: WorkspaceID,

pub fn init(self: *WorkspaceState) !void {
    const rc = self.rc.fetchAdd(1, .acq_rel);

    if (!Impl.available()) return error.@"Service Not Found";

    if (rc == 0) {
        self.worker_thread = try Thread.spawn(.{}, Impl.work, .{self});
        self.worker_thread.setName(workspaces_worker_name) catch |err| {
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
        log.debug("Joining Worker...", .{});
        self.worker_thread.join();
        log.debug("Worker Joined.", .{});
    }

    self.* = undefined;
}

pub fn setWorkspace(workspace_id: WorkspaceID) !void {
    try Impl.setWorkspace(workspace_id);
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
