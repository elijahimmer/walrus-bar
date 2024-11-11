pub const comment_delimiters = ";";
pub const set_separators = "=";
pub const default_section_name = "general";
pub const max_setting_name_len = 64;

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

    var section_name: ?[]const u8 = "general";

    var line_number: u32 = 1;
    line_loop: while (line_iter.next()) |line| : (line_number += 1) {
        if (line.len == 0) continue;

        // line_number - 1 because it starts at 1
        assert(line_number - 1 <= file_length); // loop counter check

        if (section_name) |sn| assert(!ascii.eqlIgnoreCase(sn, "internal"));

        const option = parseLine(line) catch |err| {
            switch (err) {
                error.SectionHeaderWithNoEnding => log.warn("Section Header doesn't have a ending ']' on line {}", .{line_number}),
                error.SectionHeaderWithEmptyName => log.warn("Section Header with no name on line {}", .{line_number}),
                error.IllegalSectionHeaderName => log.warn("Illegal Section Name on line {}", .{line_number}),
                error.SettingLineNoSetSeparator => log.warn("Setting line without any set separator '{s}' on line {}", .{ set_separators, line_number }),
                error.SettingNameTooLong => log.warn("Setting Name too long on line {}", .{line_number}),
            }

            switch (err) {
                error.SectionHeaderWithNoEnding, error.SectionHeaderWithEmptyName, error.IllegalSectionHeaderName => {
                    section_name = null;
                },
                error.SettingLineNoSetSeparator, error.SettingNameTooLong => {},
            }
            continue :line_loop;
        };

        // if there isn't a section name (i.e. the section was invalid) skip until a new section arises.
        if (section_name == null and option != .section_header) continue :line_loop;

        switch (option) {
            .section_header => |section_header| {
                // make sure they don't try to set the internal stuff
                assert(!ascii.eqlIgnoreCase(section_header, "internal"));

                section_loop: inline for (@typeInfo(T).Struct.fields) |section_field| {
                    if (comptime ascii.eqlIgnoreCase(section_field.name, "internal")) continue :section_loop;

                    if (ascii.eqlIgnoreCase(section_field.name, section_header)) break :section_loop;
                } else {
                    log.warn("Unknown section name: '{s}', skipping section", .{section_header});
                    section_name = null;
                    continue :line_loop;
                }

                section_name = section_header;
            },
            .setting => |setting| {
                assert(section_name != null);

                setOption(config, section_name.?, setting, line_number) catch |err| {
                    switch (err) {
                        error.OptionNotFound => log.warn("Option '{s}' not found on line {}", .{ setting.name.constSlice(), line_number }),
                        // already logged there
                        error.ParserError => {},
                    }
                };
            },
            .none => {},
        }
    }
}

pub const SetOptionError = error{ OptionNotFound, ParserError };

pub fn setOption(config: anytype, section_name: []const u8, setting: Setting, line_number: usize) SetOptionError!void {
    comptime assert(@typeInfo(@TypeOf(config)) == .Pointer);
    const ConfigPointerChild = @typeInfo(@TypeOf(config)).Pointer.child;

    comptime assert(@typeInfo(ConfigPointerChild) == .Struct);
    const config_info = @typeInfo(ConfigPointerChild).Struct;

    const is_transient = is_transient: {
        if (!ascii.eqlIgnoreCase(section_name, "general")) break :is_transient false;

        inline for (transient_settings) |transient_setting| {
            if (ascii.eqlIgnoreCase(transient_setting, setting.name.constSlice())) break :is_transient true;
        }

        break :is_transient false;
    };

    inline for (config_info.fields) |config_field| {
        comptime if (ascii.eqlIgnoreCase(config_field.name, "internal")) continue;

        const section = &@field(config, config_field.name);
        const SectionType = @TypeOf(@field(config, config_field.name));
        comptime assert(@typeInfo(SectionType) == .Struct);

        if (is_transient or ascii.eqlIgnoreCase(config_field.name, section_name)) {
            inline for (@typeInfo(SectionType).Struct.fields) |section_field| {
                if (ascii.eqlIgnoreCase(section_field.name, setting.name.constSlice())) {
                    const section_type = if (@typeInfo(section_field.type) == .Optional)
                        @typeInfo(section_field.type).Optional.child
                    else
                        section_field.type;

                    @field(section, section_field.name) = parseToType(section_type, setting.value) catch |err| {
                        log.warn("error: {s} on line {}", .{ @errorName(err), line_number });

                        return error.ParserError;
                    };

                    if (!is_transient) return;
                }
            } else {
                if (!is_transient) log.warn("Setting '{s}' not found in section '{s}'", .{ setting.name.constSlice(), section_name });
            }
        }
    } else if (!is_transient) unreachable;
}

// TODO: Remove anyerror here
fn parseToType(comptime T: type, value: []const u8) TypeToParserReturn(T) {
    const type_name = comptime Config.resolveTypeName(T);

    comptime assert(@hasField(@TypeOf(Config.parsers), type_name));

    const parser = comptime @field(Config.parsers, type_name);

    return parser(value);
}

fn TypeToParserReturn(comptime T: type) type {
    const type_name = comptime Config.resolveTypeName(T);

    comptime assert(@hasField(@TypeOf(Config.parsers), type_name));

    return @typeInfo(@TypeOf(@field(Config.parsers, type_name))).Fn.return_type.?;
}

const ParseLineError = error{
    SectionHeaderWithNoEnding,
    SectionHeaderWithEmptyName,
    IllegalSectionHeaderName,
    SettingLineNoSetSeparator,
    SettingNameTooLong,
};

const Setting = struct {
    pub const Name = BoundedArray(u8, max_setting_name_len);
    name: Name,
    value: []const u8,
};

const ConfigOption = union(enum) {
    section_header: []const u8,
    setting: Setting,
    none,
};

fn parseLine(line: []const u8) ParseLineError!ConfigOption {
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
            return error.SectionHeaderWithNoEnding;
        }
        if (active_line.len <= 2) {
            return error.SectionHeaderWithEmptyName;
        }

        const section_name = active_line[1 .. active_line.len - 1];

        if (ascii.eqlIgnoreCase(section_name, "internal")) return error.IllegalSectionHeaderName;

        return .{ .section_header = mem.trim(u8, section_name, &ascii.whitespace) };
    }

    const setting_separator = mem.indexOfAny(u8, active_line, set_separators) orelse {
        return error.SettingLineNoSetSeparator;
    };

    const setting_name_raw = mem.trim(u8, active_line[0..setting_separator], &ascii.whitespace);

    if (setting_name_raw.len > max_setting_name_len) return error.SettingNameTooLong;

    var setting_name = Setting.Name{};

    {
        const lower_string = ascii.lowerString(setting_name.unusedCapacitySlice(), setting_name_raw);
        assert(lower_string.len == setting_name_raw.len);
        setting_name.resize(setting_name_raw.len) catch unreachable;
    }

    mem.replaceScalar(u8, setting_name.slice(), '-', '_');

    const setting_value = mem.trim(u8, active_line[setting_separator + 1 ..], &ascii.whitespace);

    return .{
        .setting = .{
            .name = setting_name,
            .value = setting_value,
        },
    };
}

const Config = @import("Config.zig");
const Path = Config.Path;
const transient_settings = Config.transient_settings;

const colors = @import("colors.zig");
const Color = colors.Color;

const std = @import("std");
const posix = std.posix;
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;

const log = std.log.scoped(.ParseConfig);
