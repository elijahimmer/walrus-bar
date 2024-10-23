pub fn work(state: *WorkspaceState) void {
    _ = state;
}

pub fn available() bool {
    return false;
}

const WorkspaceState = @import("WorkspaceState.zig");
const WorkspaceID = WorkspaceState.WorkspaceID;
