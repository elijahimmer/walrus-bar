const max_failed_reads = 10;
/// Should be more than enough
const resp_buffer_len = 8196;

pub fn work(state: *WorkspaceState) void {
    log.info("Hyprland Worker Started!", .{});

    initalizeState(state);

    var hyprland_socket = utils.openHyprSocket(.event) catch {
        log.err("Failed to connect to hyprland! worker exiting...", .{});
        return;
    };

    // set socket non-blocking
    _ = posix.fcntl(hyprland_socket.handle, posix.F.SETFL, posix.SOCK.NONBLOCK) catch |err| {
        log.warn("Failed to set hyprland socket non-blocking with: '{s}'", .{@errorName(err)});
    };

    var resp_buffer: [resp_buffer_len]u8 = undefined;

    var failed_reads: usize = 0;

    // TODO: Find out which atomic order is best for this :)
    while (state.rc.load(.monotonic) > 0) {
        std.time.sleep(std.time.ns_per_ms * 50);

        const read_length = hyprland_socket.read(&resp_buffer) catch |err| {
            if (err == error.WouldBlock) continue;

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

        var lines_iter = mem.splitScalar(u8, resp_used, '\n');

        while (lines_iter.next()) |line| {
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

    log.info("Hyprland Worker Stopped!", .{});
}

pub fn initalizeState(state: *WorkspaceState) void {
    state.rwlock.lock();
    defer state.rwlock.unlock();

    state.workspaces = utils.getCurrentWorkspaces() catch workspaces: {
        log.warn("Failed to get current active workspace.", .{});

        var workspaces = WorkspaceArray{};

        workspaces.appendAssumeCapacity(1);

        break :workspaces workspaces;
    };
    state.active_workspace = utils.getActiveWorkspace() catch active_workspace: {
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

        //log.debug("Set active workspace: {}", .{new_active});

        state.rwlock.lock();
        defer state.rwlock.unlock();

        state.active_workspace = new_active;
    } else if (mem.eql(u8, event, "createworkspace")) {
        const new_wksp = parseInt(WorkspaceID, value, 10) catch {
            log.warn("Hyprland sent invalid workspace id! '{s}'>>'{s}'", .{ event, value });
            return;
        };

        //log.debug("Created workspace: {}", .{new_wksp});

        state.rwlock.lock();
        defer state.rwlock.unlock();

        const new_wksp_idx = sort.lowerBound(WorkspaceID, new_wksp, state.workspaces.slice(), {}, sort.asc(WorkspaceID));

        // if there is a overflow, just continue and don't add it
        state.workspaces.insert(new_wksp_idx, new_wksp) catch {};
    } else if (mem.eql(u8, event, "destroyworkspace")) {
        const wksp_to_destroy = parseInt(WorkspaceID, value, 10) catch {
            log.warn("Hyprland sent invalid workspace id! '{s}'>>'{s}'", .{ event, value });
            return;
        };

        //log.debug("Destroyed workspace: {}", .{wksp_to_destroy});

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
        //log.debug("unknown hyprland event: '{s}'>>'{s}'", .{ event, value });
    }
}

pub fn validateState(state: *WorkspaceState) void {
    if (state.workspaces.len == 0) return;

    var last_wksp = state.workspaces.slice()[0] - 1;
    for (state.workspaces.slice(), 0..) |wksp, idx| {
        assert(wksp > last_wksp);
        last_wksp = wksp;

        for (state.workspaces.slice(), 0..) |wksp_2, idx_2| {
            if (idx == idx_2) continue;
            assert(wksp != wksp_2);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}

const utils = @import("utils.zig");

const WorkspaceState = @import("../WorkspaceState.zig");
const WorkspaceArray = WorkspaceState.WorkspaceArray;
const WorkspaceID = WorkspaceState.WorkspaceID;

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const sort = std.sort;
const math = std.math;
const posix = std.posix;

const parseInt = fmt.parseInt;
const assert = std.debug.assert;

const log = std.log.scoped(.HyprlandWorker);
