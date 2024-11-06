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

/// Checks whether or not we can even talk to Hyprland
/// Does not check whether or not you can connect to the sockets.
pub fn available() bool {
    const xdg = posix.getenv("XDG_RUNTIME_DIR") orelse return false;

    // checks whether or not the path exists.
    if (!std.fs.path.isAbsolute(xdg)) return false;

    std.fs.accessAbsolute(xdg, .{}) catch return false;

    const his = posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return false;

    if (mem.trim(u8, his, &ascii.whitespace).len == 0) return false;

    var path = BoundedArray(u8, std.fs.max_path_bytes){};

    path.writer().print("{s}/hypr/{s}/", .{ xdg, his }) catch return false;

    // checks make sure the Hyprland sockets exist.
    {
        var dir = std.fs.openDirAbsolute(path.slice(), .{}) catch return false;
        dir.access(command_socket, .{}) catch return false;
        dir.access(event_socket, .{}) catch return false;
        dir.close();
    }

    return true;
}

pub const OpenHyprSocketError = error{
    NoXdgRuntimeDir,
    NoHyprlandInstanceSignature,
    PathTooLong,
} || posix.ConnectError || posix.SocketError || error{NameTooLong};

/// Opens a unix socket to talk to Hyprland.
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

/// send a Hyprland command to specified socket.
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

/// Send a Hyprland command, making a new command socket.
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

/// Gets the current active workspace from Hyprland
pub fn getActiveWorkspace() !WorkspaceID {
    const response = try sendHyprCommand(get_workspace_id_input_len, .active_workspace);

    return try getWorkspaceID(response.slice());
}

test getActiveWorkspace {
    _ = getActiveWorkspace() catch |err| switch (err) {
        // there is no hyprland instance.
        error.NoXdgRuntimeDir, error.NoHyprlandInstanceSignature => return error.SkipTest,
        else => |e| return e,
    };
}

/// The start of every workspace command
const workspace_cmd_start: [:0]const u8 = "workspace ID ";

/// The max read length when requesting the active workspace.
///
/// 8 characters should be enough for any int hyprland returns
const get_workspace_id_input_len = workspace_cmd_start.len + 8;

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

const get_current_workspaces_max_response_len = 4096;

pub fn getCurrentWorkspaces() !WorkspaceArray {
    const resp = try sendHyprCommand(get_current_workspaces_max_response_len, .workspaces);

    var workspaces = WorkspaceArray{};

    var line_iter = mem.splitScalar(u8, resp.slice(), '\n');

    var loop_counter: usize = 0;
    while (line_iter.next()) |line| : (loop_counter += 1) {
        assert(loop_counter < get_current_workspaces_max_response_len);

        if (mem.startsWith(u8, line, workspace_cmd_start)) {
            const wksp_id = getWorkspaceID(line) catch continue;
            workspaces.append(wksp_id) catch break;
        }
    }

    mem.sort(WorkspaceID, workspaces.slice(), {}, std.sort.asc(WorkspaceID));

    return workspaces;
}

const max_failed_reads = 10;
/// Should be more than enough
const resp_buffer_len = 8196;
const loop_sleep_time = std.time.ns_per_ms * 50;

pub fn work(state: *WorkspaceState) void {
    log.info("Hyprland Worker Started!", .{});
    defer log.info("Hyprland Worker Stopped!", .{});

    initalizeState(state);

    var hyprland_socket = openHyprSocket(.event) catch |err| {
        log.err("Failed to connect to hyprland! worker exiting... err: '{s}'", .{@errorName(err)});
        return;
    };

    var non_blocking = true;

    // set socket non-blocking
    // If that doesn't work, it wouldn't be great, but it's alright.
    _ = posix.fcntl(hyprland_socket.handle, posix.F.SETFL, posix.SOCK.NONBLOCK) catch |err| {
        log.warn("Failed to set hyprland socket non-blocking with: '{s}'", .{@errorName(err)});
        non_blocking = false;
    };

    var resp_buffer: [resp_buffer_len]u8 = undefined;

    var failed_reads: usize = 0;

    // TODO: Find out which atomic order is best for this :)
    while (state.rc.load(.monotonic) > 0) {
        // if the stream is blocking, then sleep at start, not
        // on WouldBlock
        if (!non_blocking) std.time.sleep(loop_sleep_time);

        const read_length = hyprland_socket.read(&resp_buffer) catch |err| {
            if (err == error.WouldBlock) {
                // non_blocking should be true, but an assert here maybe wouldn't be good.
                std.time.sleep(loop_sleep_time);
                continue;
            }

            failed_reads += 1;

            if (failed_reads > max_failed_reads) {
                log.err("Failed to read from hyprland socket too many times, exiting... failed with: '{s}'", .{@errorName(err)});
                return;
            }

            log.warn("Failed to read from hyprland socket with: {s}", .{@errorName(err)});

            continue;
        };

        failed_reads = 0;

        assert(read_length >= 0);

        const resp_used = resp_buffer[0..read_length];

        var line_iter = mem.splitScalar(u8, resp_used, '\n');

        var loop_counter: usize = 0;
        while (line_iter.next()) |line| : (loop_counter += 1) {
            assert(loop_counter < read_length);

            if (line.len == 0) continue;

            const sep_idx = if (mem.indexOf(u8, line, ">>")) |idx| idx else {
                log.warn("Hyprland event without a '>>'?, event: '{s}'", .{line});
                continue;
            };

            const event = line[0..sep_idx];
            const value = line[sep_idx + 2 ..];

            processEvent(state, event, value);
        }
    }
}

pub fn initalizeState(state: *WorkspaceState) void {
    state.rwlock.lock();
    defer state.rwlock.unlock();

    state.workspaces = getCurrentWorkspaces() catch workspaces: {
        log.warn("Failed to get current active workspace.", .{});

        var workspaces = WorkspaceArray{};

        workspaces.appendAssumeCapacity(1);

        break :workspaces workspaces;
    };
    state.active_workspace = getActiveWorkspace() catch active_workspace: {
        log.warn("Failed to get current active workspace.", .{});

        break :active_workspace 1;
    };
}

/// Process a event given the event and the value
pub fn processEvent(state: *WorkspaceState, event: []const u8, value: []const u8) void {
    if (mem.eql(u8, event, "workspace")) {
        const new_active = parseInt(WorkspaceID, value, 10) catch {
            log.warn("Hyprland sent invalid workspace id! '{s}'>>'{s}'", .{ event, value });
            return;
        };

        log.debug("Set active workspace: {}", .{new_active});

        state.rwlock.lock();
        defer state.rwlock.unlock();

        const potential_wksp_idx = sort.lowerBound(WorkspaceID, new_active, state.workspaces.constSlice(), {}, sort.asc(WorkspaceID));

        assert(potential_wksp_idx <= state.workspaces.len);

        const is_within_max = potential_wksp_idx < max_workspace_count;
        const extends_list = state.workspaces.len == potential_wksp_idx;
        const can_be_inserted = extends_list or (state.workspaces.len < max_workspace_count and state.workspaces.get(potential_wksp_idx) != new_active);

        // if the workspace doesn't exist, add it.
        if (is_within_max and can_be_inserted) {
            // should never fail to insert.
            state.workspaces.insert(potential_wksp_idx, new_active) catch unreachable;
        }

        state.active_workspace = new_active;
    } else if (mem.eql(u8, event, "createworkspace")) {
        const new_wksp = parseInt(WorkspaceID, value, 10) catch {
            log.warn("Hyprland sent invalid workspace id! '{s}'>>'{s}'", .{ event, value });
            return;
        };

        log.debug("Created workspace: {}", .{new_wksp});

        state.rwlock.lock();
        defer state.rwlock.unlock();

        const new_wksp_idx = sort.lowerBound(WorkspaceID, new_wksp, state.workspaces.slice(), {}, sort.asc(WorkspaceID));

        // if there is a overflow, just continue and don't add it
        state.workspaces.insert(new_wksp_idx, new_wksp) catch {
            log.warn("Hyprland made too many workspaces! Ignoring new ones!", .{});
        };
    } else if (mem.eql(u8, event, "destroyworkspace")) {
        const wksp_to_destroy = parseInt(WorkspaceID, value, 10) catch {
            log.warn("Hyprland sent invalid workspace id! '{s}'>>'{s}'", .{ event, value });
            return;
        };

        log.debug("Destroyed workspace: {}", .{wksp_to_destroy});

        state.rwlock.lock();
        defer state.rwlock.unlock();

        const wksp_idx = sort.binarySearch(
            WorkspaceID,
            wksp_to_destroy,
            state.workspaces.slice(),
            {},
            struct {
                pub fn order(_: void, key: WorkspaceID, mid: WorkspaceID) math.Order {
                    return math.order(key, mid);
                }
            }.order,
        );

        if (wksp_idx) |idx| {
            const removed = state.workspaces.orderedRemove(idx);
            assert(removed == wksp_to_destroy);
        } else {
            log.warn("Hyprland destroyed non-existent workspace: {}", .{wksp_to_destroy});
        }
    } else {
        log.debug("unknown hyprland event: '{s}'>>'{s}'", .{ event, value });
    }
}

pub fn setWorkspace(wksp_id: WorkspaceID) !void {
    const resp = try sendHyprCommand(2, .{ .move_to_workspace = wksp_id });
    assert(mem.eql(u8, resp.slice(), "ok"));
}

test {
    std.testing.refAllDecls(@This());
}

const options = @import("options");

const WorkspaceState = @import("WorkspaceState.zig");
const WorkspaceArray = WorkspaceState.WorkspaceArray;
const WorkspaceID = WorkspaceState.WorkspaceID;
const max_workspace_count = WorkspaceState.max_workspace_count;

const std = @import("std");
const fmt = std.fmt;
const net = std.net;
const mem = std.mem;
const sort = std.sort;
const math = std.math;
const ascii = std.ascii;
const posix = std.posix;

const parseInt = fmt.parseInt;
const assert = std.debug.assert;

const log = std.log.scoped(.WorkspacesWorker);

const Stream = net.Stream;
const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
