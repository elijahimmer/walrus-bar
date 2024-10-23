pub const command_socket = ".socket.sock";
pub const event_socket = ".socket2.sock";

pub const HyprSocketType = enum {
    command,
    event,
};

pub const Command = union(enum) {
    active_workspace,
    workspaces,
    move_to_workspace: WorkspaceID,

    pub fn write(self: Command, writer: anytype) @TypeOf(writer).Error!void {
        switch (self) {
            .move_to_workspace => |wid| try writer.print("dispatch workspace {}", .{wid}),
            .active_workspace => _ = try writer.write("activeworkspace"),
            .workspaces => _ = try writer.write("workspaces"),
        }
    }
};

/// returns true if and only if the path exists and the process and access it.
fn path_exists(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    _ = std.fs.openDirAbsolute(path, .{}) catch return false;
    return true;
}

pub fn hyprlandExists() bool {
    const xdg = posix.getenv("XDG_RUNTIME_DIR") orelse return false;

    if (!path_exists(xdg)) return false;

    const his = posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return false;

    if (mem.trim(u8, his, &ascii.whitespace).len == 0) return false;

    return true;
}

pub const OpenHyprSocketError = error{
    NoXdgRuntimeDir,
    NoHyprlandInstanceSignature,
    PathTooLong,
} || posix.ConnectError || posix.SocketError || error{NameTooLong};

pub fn openHyprSocket(socket_type: HyprSocketType) OpenHyprSocketError!Stream {
    const socket_path = switch (socket_type) {
        .command => command_socket,
        .event => event_socket,
    };

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const his = posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return error.NoHyprlandInstanceSignature;

    var path = BoundedArray(u8, std.fs.max_path_bytes){};

    path.writer().print("{s}/hypr/{s}/{s}", .{ xdg_runtime_dir, his, socket_path }) catch return error.PathTooLong;

    const stream = try net.connectUnixSocket(path.slice());

    return stream;
}

/// send a hyprland command to specified socket.
pub fn sendHyprCommandTo(
    /// This is stack allocated, so don't put too much
    comptime max_response_length: comptime_int,
    stream: Stream,
    command: Command,
) !BoundedArray(u8, max_response_length) {
    try command.write(stream.writer());

    const reader = stream.reader();

    return try reader.readBoundedBytes(max_response_length);
}

/// Send a hyprland command, making a new command socket.
pub fn sendHyprCommand(
    /// This is stack allocated, so don't put too much
    comptime max_response_length: comptime_int,
    command: Command,
) !BoundedArray(u8, max_response_length) {
    const stream = try openHyprSocket(.command);

    return sendHyprCommandTo(max_response_length, stream, command);
}

test sendHyprCommand {
    // const expect = std.testing.expect;
    const response = sendHyprCommand(100, .workspaces) catch |err| switch (err) {
        // there is no hyprland instance.
        error.NoXdgRuntimeDir, error.NoHyprlandInstanceSignature => return error.SkipTest,
        else => |e| return e,
    };
    _ = response;
}

pub fn getActiveWorkspace() !WorkspaceID {
    const response = try sendHyprCommand(get_workspace_id_input_len, .active_workspace);

    return getWorkspaceID(response.slice());
}

test getActiveWorkspace {
    _ = getActiveWorkspace() catch |err| switch (err) {
        // there is no hyprland instance.
        error.NoXdgRuntimeDir, error.NoHyprlandInstanceSignature => return error.SkipTest,
        else => |e| return e,
    };
}

const workspace_cmd_start: [:0]const u8 = "workspace ID ";

/// 8 characters should be enough for any int hyprland returns
pub const get_workspace_id_input_len = workspace_cmd_start.len + 8;

pub fn getWorkspaceID(msg: []const u8) !WorkspaceID {
    if (!mem.eql(u8, msg[0..workspace_cmd_start.len], workspace_cmd_start)) return error.InvalidWorkspaceResponse;

    const workable = msg[workspace_cmd_start.len..];
    const space_idx = mem.indexOfScalar(u8, workable, ' ') orelse return error.InvalidWorkspaceResponse;

    return parseInt(WorkspaceID, workable[0..space_idx], 10);
}

test getWorkspaceID {
    const expect = std.testing.expect;

    const resp = workspace_cmd_start ++ "123 test";

    try expect(try getWorkspaceID(resp) == 123);
}

pub fn getCurrentWorkspaces() !WorkspaceArray {
    const resp = try sendHyprCommand(4096, .workspaces);

    var workspaces = WorkspaceArray{};

    var line_iter = mem.splitScalar(u8, resp.slice(), '\n');

    while (line_iter.next()) |line| {
        if (mem.startsWith(u8, line, workspace_cmd_start)) {
            workspaces.append(try getWorkspaceID(line)) catch break;
        }
    }

    mem.sort(WorkspaceID, workspaces.slice(), {}, std.sort.asc(WorkspaceID));

    return workspaces;
}

const WorkspaceState = @import("../WorkspaceState.zig");
const WorkspaceID = WorkspaceState.WorkspaceID;
const WorkspaceArray = WorkspaceState.WorkspaceArray;

const std = @import("std");
const mem = std.mem;
const net = std.net;
const ascii = std.ascii;
const posix = std.posix;

const parseInt = std.fmt.parseInt;

const Stream = net.Stream;
const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
