pub fn work(state: *WorkspaceState) void {
    log.info("Stub Worker Started!", .{});
    defer log.info("Testing Worker Stopped!", .{});

    {
        state.rwlock.lock();
        defer state.rwlock.unlock();

        state.workspaces.appendSliceAssumeCapacity(&[_]WorkspaceID{ 1, 2, 3, 4, 5, 6, 7 });
        state.active_workspace = 1;
    }

    // Seed it with the same thing so it is always the same pattern
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rand = prng.random();

    var counter: u2 = 0;
    var add_remove: enum { add, remove } = .remove;
    var last_removed: WorkspaceID = undefined;

    while (state.rc.load(.seq_cst) > 0) {
        counter +%= 1;

        std.time.sleep(std.time.ns_per_ms * 250);

        state.rwlock.lock();
        defer state.rwlock.unlock();

        if (counter > 2) {
            switch (add_remove) {
                .remove => {
                    last_removed = state.workspaces.orderedRemove(rand.uintLessThan(u5, state.workspaces.len));
                    add_remove = .add;
                },
                .add => {
                    const idx = idx: for (state.workspaces.slice(), 0..) |wksp, idx| {
                        if (wksp > last_removed) break :idx idx;
                    } else state.workspaces.len;

                    state.workspaces.insert(idx, last_removed) catch unreachable;
                    add_remove = .remove;
                },
            }
        }

        state.active_workspace += 1;
        if (state.active_workspace > state.workspaces.slice()[state.workspaces.len - 1]) {
            state.active_workspace = 1;
        }
    }
}

pub fn available() bool {
    return true;
}

pub fn setWorkspace(wksp_id: WorkspaceID) !void {
    _ = wksp_id;
}

const WorkspaceState = @import("WorkspaceState.zig");
const WorkspaceID = WorkspaceState.WorkspaceID;
const max_workspaces_count = @import("Workspaces.zig").max_workspaces_count;

const std = @import("std");

const log = std.log.scoped(.WorkspacesWorker);
