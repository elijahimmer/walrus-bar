pub const comment_delimiters = ";#";
pub const set_separators = "=";
pub const default_section_name = "general";

pub const ParseConfigError = posix.MMapError || fs.File.StatError;

pub fn parseConfig(T: type, config: *T, file: fs.File) ParseConfigError!void {
    const file_length = (try file.stat()).size;
    if (file_length == 0) return;

    const config_data = try posix.mmap(
        null,
        file_length,
        posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    defer posix.munmap(config_data);

    var line_iter = mem.splitScalar(u8, config_data, '\n');

    var section_header: []const u8 = default_section_name;
    var wait_until_next_header = false;

    var line_number: u32 = 1;
    while (line_iter.next()) |line| : (line_number += 1) {
        assert(line_number < file_length); // loop counter check

        const option = parseLine(line, line_number) catch |err| switch (err) {
            error.SectionHeaderWithNoEnding, error.SectionHeaderWithEmptyName => {
                wait_until_next_header = true;
                continue;
            },
            error.InvalidSettingLine => continue,
        };

        if (wait_until_next_header) {
            if (option != .section_start) continue;
            wait_until_next_header = false;
        }

        switch (option) {
            .section_start => |section_start| section_header = section_start,
            .setting => |setting| setOption(T, config, setting),
            .none => {},
        }
    }
}

pub fn setOption(comptime T: type, config: *T, setting: Setting) void {
    _ = config;
    _ = setting;
}

const ParseLineError = error{
    SectionHeaderWithNoEnding,
    SectionHeaderWithEmptyName,
    InvalidSettingLine,
};

const Setting = struct {
    name: []const u8,
    value: []const u8,
};

const ConfigOption = union(enum) {
    section_start: []const u8,
    setting: Setting,
    none,
};

fn parseLine(line: []const u8, line_number: u32) ParseLineError!ConfigOption {
    const active_line = active_line: {
        const without_comment = if (mem.indexOfAny(u8, line, comment_delimiters)) |idx|
            line[0..idx]
        else
            line;

        const trimmed = mem.trim(u8, without_comment, &ascii.whitespace);
        break :active_line trimmed;
    };

    if (active_line.len == 0) return .none;

    if (active_line[0] == '[') {
        if (active_line[active_line.len - 1] != ']') {
            log.warn("Section Header doesn't have a ending ']' on line: {}", .{line_number});
            return error.SectionHeaderWithNoEnding;
        }
        if (active_line.len <= 2) {
            log.warn("Section Header with no name on line: {}", .{line_number});
            return error.SectionHeaderWithEmptyName;
        }

        const section_name = active_line[1 .. active_line.len - 1];

        return .{ .section_start = mem.trim(u8, section_name, &ascii.whitespace) };
    }

    const setting_separator = mem.indexOfAny(u8, active_line, set_separators) orelse {
        log.warn("Setting line without a set separator. line: {}", .{line_number});
        return error.InvalidSettingLine;
    };

    const setting_name = mem.trim(u8, active_line[0..setting_separator], &ascii.whitespace);
    const setting_value = mem.trim(u8, active_line[setting_separator + 1 ..], &ascii.whitespace);

    return .{
        .setting = .{
            .name = setting_name,
            .value = setting_value,
        },
    };
}

const std = @import("std");
const posix = std.posix;
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const assert = std.debug.assert;

const log = std.log.scoped(.ParseConfig);
