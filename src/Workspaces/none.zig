pub fn work(state: *WorkspaceState) void {
    _ = state;
}

pub fn available() bool {
    return false;
}

pub fn setWorkspace(wksp_id: WorkspaceID) !void {
    _ = wksp_id;
}

const WorkspaceState = @import("WorkspaceState.zig");
const WorkspaceID = WorkspaceState.WorkspaceID;
