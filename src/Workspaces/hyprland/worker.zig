pub fn work(state: *WorkspaceState) void {
    log.info("Hyprland Worker Started!", .{});

    {
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

    var hyprland_socket = utils.openHyprSocket(.event) catch {
        log.err("Failed to connect to hyprland! worker exiting...", .{});
        return;
    };

    var resp_buffer: [4096]u8 = undefined;

    while (state.rc.load(.monotonic) > 0) {
        defer std.Thread.yield() catch std.time.sleep(0);

        const read_length = hyprland_socket.read(&resp_buffer) catch |err| {
            log.warn("Failed to read from hyprland socket with: {s}", .{@errorName(err)});
            continue;
        };

        if (read_length == 0) {
            continue;
        }

        const resp_used = resp_buffer[0..read_length];

        var lines_iter = mem.splitScalar(u8, resp_used, '\n');

        while (lines_iter.next()) |line| {
            if (line.len == 0) continue;
            const sep_idx = if (mem.indexOf(u8, line, ">>")) |idx| idx else {
                log.warn("Hyprland event without a '>>'?, event: '{s}'", .{line});
                continue;
            };

            const key = line[0..sep_idx];
            const value = line[sep_idx + 2 ..];

            if (mem.eql(u8, key, "workspace")) {
                const new_active = parseInt(WorkspaceID, value, 10) catch {
                    log.warn("Hyprland sent invalid workspace id! '{s}'>>'{s}'", .{ key, value });
                    continue;
                };

                //log.debug("Set active workspace: {}", .{new_active});

                state.rwlock.lock();
                defer state.rwlock.unlock();

                state.active_workspace = new_active;
            } else if (mem.eql(u8, key, "createworkspace")) {
                const new_wksp = parseInt(WorkspaceID, value, 10) catch {
                    log.warn("Hyprland sent invalid workspace id! '{s}'>>'{s}'", .{ key, value });
                    continue;
                };

                //log.debug("Created workspace: {}", .{new_wksp});

                state.rwlock.lock();
                defer state.rwlock.unlock();

                const new_wksp_idx = for (state.workspaces.slice(), 0..) |wksp, idx| {
                    if (wksp >= new_wksp) {
                        break idx;
                    }
                } else new_wksp_idx: {
                    break :new_wksp_idx state.workspaces.len;
                };

                // if there is a overflow, just continue and don't add it
                state.workspaces.insert(new_wksp_idx, new_wksp) catch {};
            } else if (mem.eql(u8, key, "destroyworkspace")) {
                const wksp_to_destroy = parseInt(WorkspaceID, value, 10) catch {
                    log.warn("Hyprland sent invalid workspace id! '{s}'>>'{s}'", .{ key, value });
                    continue;
                };

                //log.debug("Destroyed workspace: {}", .{wksp_to_destroy});

                state.rwlock.lock();
                defer state.rwlock.unlock();

                const wksp_idx = for (state.workspaces.slice(), 0..) |wksp, idx| {
                    if (wksp == wksp_to_destroy) {
                        break idx;
                    }
                } else wksp_idx: {
                    break :wksp_idx state.workspaces.len;
                };

                _ = state.workspaces.orderedRemove(wksp_idx);
            } else {
                //log.debug("unknown hyprland event: '{s}'>>'{s}'", .{ key, value });
            }
        }
    }

    log.info("Hyprland Worker Stopped!", .{});
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

const parseInt = fmt.parseInt;

const log = std.log.scoped(.HyprlandWorker);
