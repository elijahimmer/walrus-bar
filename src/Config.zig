//! TODO: Implement configuration files

pub const Config = @This();

pub const default_text_color = colors.rose;
pub const default_background_color = colors.surface;
pub const default_window_height = 28;
pub const minimum_window_height = 15;
pub const minimum_window_width = 500;

pub const transient_settings = .{
    "background_color",
    "text_color",
};

pub const Path = BoundedArray(u8, fs.max_path_bytes);

pub const General = struct {
    width: ?u16 = null,
    height: u16 = default_window_height,

    text_color: Color = default_text_color,
    background_color: Color = default_background_color,
};

/// global config. Use only after you have initialized it with init
pub var global: Config = undefined;

/// Reads and initializes the config from CLI args.
pub fn init_global(allocator: Allocator) Allocator.Error!void {
    global = try parseArgv(allocator);
}

pub fn deinit_global() void {
    global.internal.clap_res.deinit();
    global = undefined;
}

/// internal setting, should never be user-accessible
internal: struct {
    clap_res: clap.Result(clap.Help, &params, parsers),
},

general: General,
clock: if (options.clock_enabled) ClockConfig else void,
battery: if (options.battery_enabled) BatteryConfig else void,
brightness: if (options.brightness_enabled) BrightnessConfig else void,
workspaces: if (options.workspaces_enabled) WorkspacesConfig else void,

fn parseArgv(allocator: Allocator) Allocator.Error!Config {
    var iter = std.process.ArgIterator.init();
    defer iter.deinit();

    var diag = clap.Diagnostic{};
    const res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.report(std.io.getStdErr().writer(), err) catch {};
        exit(1);
    };

    const args = &res.args;

    const stdout = std.io.getStdOut();
    defer stdout.close();

    const stdout_writer = stdout.writer();

    if (args.help != 0) {
        _ = stdout_writer.write(help_message_prelude) catch {};
        clap.help(std.io.getStdOut().writer(), clap.Help, &params, .{}) catch {};
        exit(0);
    }

    if (args.dependencies != 0) {
        _ = stdout_writer.write(dependencies_message) catch {};
        exit(0);
    }

    if (args.colors != 0) {
        printColorsMessage(stdout_writer) catch {};
        exit(0);
    }

    if (args.height != null and args.height.? < constants.MINIMUM_WINDOW_HEIGHT) {
        stdout_writer.print("Height provided ({}) is smaller than minimum height ({})", .{ args.height.?, constants.MINIMUM_WINDOW_HEIGHT }) catch {};
        exit(1);
    }

    var config = Config{
        .internal = .{ .clap_res = res },

        .general = .{},
        .battery = if (options.battery_enabled) .{} else {},
        .brightness = if (options.brightness_enabled) .{} else {},
        .clock = if (options.clock_enabled) .{} else {},
        .workspaces = if (options.workspaces_enabled) .{} else {},
    };

    ini_config: {
        const specified_config_file = if (args.@"config-file") |config_path| specified_config_path: {
            assert(fs.path.isAbsolute(config_path.constSlice()));
            break :specified_config_path config_path.constSlice();
        } else null;

        const config_path = specified_config_file orelse
            if (getDefaultConfigPath()) |cp| cp.constSlice() else break :ini_config;

        assert(fs.path.isAbsolute(config_path));

        const config_file = fs.openFileAbsolute(config_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => log.warn("Config not found at `{s}`", .{config_path}),
                else => log.warn("Failed to open configuration at `{s}` with: {s}", .{ config_path, @errorName(err) }),
            }
            break :ini_config;
        };
        defer config_file.close();

        const metadata = config_file.metadata() catch |err| {
            log.warn("Failed to get config file metadata with error: {s}", .{@errorName(err)});
            break :ini_config;
        };

        const file_kind = metadata.kind();

        if (file_kind != .file) {
            log.warn("Specified config file isn't a file, it is a {s}", .{@tagName(file_kind)});
            break :ini_config;
        }

        const old_cwd = fs.cwd();
        defer old_cwd.setAsCwd() catch |err| {
            log.warn("Failed to set Current Working Directory Back to prior CWD with error: {s}", .{@errorName(err)});
        };

        change_cwd: {
            const base_name = fs.path.basename(config_path);
            const directory_path = config_path[0 .. config_path.len - base_name.len];

            if (directory_path.len == 0) break :change_cwd;

            const new_cwd = old_cwd.openDir(directory_path, .{}) catch |err| {
                log.warn("Failed to open directory: '{s}' with error: {s}", .{ directory_path, @errorName(err) });
                break :change_cwd;
            };

            new_cwd.setAsCwd() catch |err| {
                log.warn("Failed to set directory '{s}' as current working directory with error: {s}", .{ directory_path, @errorName(err) });
                break :change_cwd;
            };
        }

        parseConfig(Config, &config, config_file) catch |err| {
            log.warn("Failed to parse config with: {s}", .{@errorName(err)});
            break :ini_config;
        };
    }

    createConfig(General, args, &config.general);
    if (options.battery_enabled) createConfig(BatteryConfig, args, &config.battery);
    if (options.brightness_enabled) createConfig(BrightnessConfig, args, &config.brightness);
    if (options.clock_enabled) createConfig(ClockConfig, args, &config.clock);
    if (options.workspaces_enabled) createConfig(WorkspacesConfig, args, &config.workspaces);

    return config;
}

pub fn getDefaultConfigPath() ?Path {
    const xdg_config_home = posix.getenvZ("XDG_CONFIG_HOME") orelse {
        log.warn("environment variable 'XDG_CONFIG_HOME' not found!", .{});
        return null;
    };

    if (!fs.path.isAbsolute(xdg_config_home)) {
        log.warn("environment variable 'XDG_CONFIG_HOME' isn't a absolute path!", .{});
        return null;
    }

    const from_config_home = "/walrus-bar/config.ini";

    if (xdg_config_home.len > max_path_bytes - from_config_home.len) {
        log.warn("environment variable 'XDG_CONFIG_HOME' is too long to be a proper path", .{});
        return null;
    }

    var path: Path = .{};

    path.appendSliceAssumeCapacity(xdg_config_home);
    path.appendSliceAssumeCapacity(from_config_home);

    assert(fs.path.isAbsolute(path.constSlice()));

    return path;
}

fn getArgName(comptime T: type, name: []const u8) []const u8 {
    // Not sure why 1_000 branches isn't enough, seems to be something with lastIndexOfScalar or lowerString
    @setEvalBranchQuota(10_000);

    if (T == General) {
        var arg_name: [name.len]u8 = undefined;

        _ = ascii.lowerString(&arg_name, name);

        mem.replaceScalar(u8, &arg_name, '_', '-');
        return &arg_name;
    }

    const type_name = comptime type_name: {
        const type_name = @typeName(T);
        const ends_with_config = ascii.endsWithIgnoreCase(type_name, "config");

        const single_name = if (mem.lastIndexOfScalar(u8, type_name, '.')) |idx|
            type_name[idx + 1 ..]
        else
            type_name;

        break :type_name single_name[0 .. single_name.len - @intFromBool(ends_with_config) * "config".len];
    };

    const arg_name_init = type_name ++ "_" ++ name;
    var arg_name: [arg_name_init.len]u8 = undefined;

    _ = ascii.lowerString(&arg_name, arg_name_init);

    mem.replaceScalar(u8, &arg_name, '_', '-');
    return &arg_name;
}

/// Gets all the config options from the clap config
pub fn createConfig(comptime T: type, args: anytype, out: *T) void {
    assert(@typeInfo(T) == .Struct);
    const type_info = @typeInfo(T).Struct;

    inline for (type_info.fields) |field| {
        const arg_name = comptime getArgName(T, field.name);

        const value = inline for (transient_settings) |name| {

            // check if it is a transient field
            if (comptime ascii.eqlIgnoreCase(field.name, name)) {
                const transient_arg_name = comptime transient_arg_name: {
                    var tan = name.*;

                    mem.replaceScalar(u8, &tan, '_', '-');

                    break :transient_arg_name &tan;
                };

                const transient_type = @typeInfo(@TypeOf(@field(args, transient_arg_name))).Optional.child;
                if (field.type != transient_type) @compileError("transient field " ++ name ++ " isn't a " ++ @typeName(transient_type) ++ "! type: " ++ @typeName(field.type));

                // if that field was configured, use that
                if (@field(args, arg_name)) |specified_arg|
                    break specified_arg;
                // otherwise use the transient name
                if (@field(args, transient_arg_name)) |transient_specified_field|
                    break transient_specified_field;
            }
            // otherwise, find the widget-specific config
        } else if (@field(args, arg_name)) |specified_arg| specified_arg else null;

        if (value) |v| {
            @field(out, field.name) = v;
        }
    }
}

pub fn resolveTypeName(comptime T: type) []const u8 {
    const TInner = if (@typeInfo(T) == .Optional) @typeInfo(T).Optional.child else T;

    return comptime switch (TInner) {
        Path => "Path",
        []const u8 => "String",
        u21 => "Character",
        u8 => "u8",
        Size => "Size",
        Color => "Color",
        else => unreachable,
    };
}

// TODO: Remove the string generation and just do normal.
/// Turns a configuration struct into a help message.
pub fn generateHelpMessageComptime(comptime T: type) [helpMessageLen(T)]u8 {
    assert(@typeInfo(T) == .Struct);
    const type_info = @typeInfo(T).Struct;

    var message = std.BoundedArray(u8, helpMessageLen(T)){};

    const writer = message.writer();

    for (type_info.fields) |field| {
        if (!@hasDecl(T, field.name ++ "_comment"))
            @compileError("Struct " ++ @typeName(T) ++ "'s Field '" ++ field.name ++ "' doesn't have a comment field: " ++ field.name ++ "_comment");

        const arg_name = getArgName(T, field.name);

        const type_name = resolveTypeName(field.type);

        const comment = @field(T, field.name ++ "_comment");

        writer.print("--{s} <{s}> {s}\n", .{
            arg_name,
            type_name,
            comment,
        }) catch unreachable;
    }

    return message.buffer;
}

pub fn helpMessageLen(T: type) comptime_int {
    assert(@typeInfo(T) == .Struct);
    const type_info = @typeInfo(T).Struct;

    var len = 0;

    for (type_info.fields) |field| {
        if (!@hasDecl(T, field.name ++ "_comment"))
            @compileError("Struct " ++ @typeName(T) ++ "'s Field '" ++ field.name ++ "' doesn't have a comment field: " ++ field.name ++ "_comment");

        const arg_name = getArgName(T, field.name);

        const type_name = resolveTypeName(field.type);

        const comment = @field(T, field.name ++ "_comment");

        len += "--".len;
        len += arg_name.len;
        len += " <".len;
        len += type_name.len;
        len += "> ".len;
        len += comment.len;
        len += "\n".len;
    }
    return len;
}

const help =
    std.fmt.comptimePrint(
    \\-h, --help                 Display this message and exit.
    \\    --dependencies         Print a list of the dependencies and versions and exit.
    \\    --colors               Print a list of all the named colors and exit.
    \\    --config-file <Path>   The path to the config file (default: "$XDG_CONFIG_HOME/walrus-bar/config.ini")
    \\-w, --width <Size>         The window's width (minimum: {}) (full screen width if not specified)
    \\-l, --height <Size>        The window's height (minimum: {}) (default: {})
    //\\-t, --title <String>       The window's title (default: OS Process Name (likely 'walrus-bar'))
    \\
    \\--text-color <Color>       The default text colors (default: {s})
    \\--background-color <Color> The default background color (default: {s})
    \\
, .{ minimum_window_width, minimum_window_height, default_window_height, colors.comptimeColorToString(default_text_color), colors.comptimeColorToString(default_background_color) }) ++
    (if (options.clock_enabled) generateHelpMessageComptime(ClockConfig) else "") ++
    (if (options.battery_enabled) generateHelpMessageComptime(BatteryConfig) else "") ++
    (if (options.brightness_enabled) generateHelpMessageComptime(BrightnessConfig) else "") ++
    (if (options.workspaces_enabled) generateHelpMessageComptime(WorkspacesConfig) else "");

/// Keep up to date with `help_message_prelude`
pub const parsers = .{
    .Path = parsePath,
    .Character = parseCharacter,
    .String = parseString,
    .Size = generateIntParser(Size, 0),
    .u8 = generateIntParser(u8, 0),
    .Color = colors.parseColor,
};

pub const ParseIntError = std.fmt.ParseIntError;

pub fn generateIntParser(comptime T: type, bits: u8) fn ([]const u8) ParseIntError!T {
    assert(@typeInfo(T) == .Int);
    return struct {
        pub fn parse(input: []const u8) ParseIntError!T {
            return std.fmt.parseInt(T, input, bits);
        }
    }.parse;
}

/// Keep up to date with `parsers`
const help_message_prelude = std.fmt.comptimePrint(
    \\Walrus-Bar v{s}
    \\   Source Repo: https://github.com/elijahimmer/walrus-bar
    \\   Types:
    \\      - Color: A color by name (`--colors` to get options) or by hex code (starting with '#')
    \\      - String: A string of valid UTF-8 characters
    \\      - Character: A single valid UTF-8 character (can be multiple bytes)
    \\      - Path: A valid absolute file system path
    \\      - Size: An amount of pixels
    \\      - u8: A number between 0 and 255 inclusive.
    \\
    \\
, .{constants.version_str});

const dependencies_message =
    std.fmt.comptimePrint(
    \\ Walrus-Bar v{s}
    \\ Built with:
    \\ - Zig v{s}
    \\ - Freetype v{s}
    \\
    \\ WORK IN PROGRESS, CHECK SOURCE REPO FOR FULL LIST
    \\ > https://github.com/elijahimmer/walrus-bar
    //// TODO: Implement version fetching for dependencies.
    //\\ - Wayland-Client v
    //\\ - Wayland-Scanner v
    //\\ - Zig Clap v
    \\
    \\
, .{
    constants.version_str,
    constants.freetype_version_str,
    builtin.zig_version_string,
    //options.wayland_client_version,
    //options.wayland_scanner_version,
    //options.zig_clap_version,
});

// TODO: Make this look prettier.
pub fn printColorsMessage(writer: anytype) !void {
    const max_width = comptime max_width: {
        var width = 0;
        for (colors.COLOR_LIST) |color| {
            width = @max(width, color.name.len);
        }

        break :max_width width;
    };

    const tty_config = std.io.tty.detectConfig(writer.context);
    const colors_supported = tty_config == .escape_codes;

    inline for (colors.COLOR_LIST) |color| {
        if (colors_supported) {
            try writer.print("\x1b[{}m\x1b[38;2;{};{};{}m", .{
                if (color.color.isDark())
                    @as(u8, 47)
                else
                    40,
                color.color.r,
                color.color.g,
                color.color.b,
            });
        }
        const spacing = .{' '} ** (max_width - color.name.len);
        try writer.print(color.name ++ spacing ++ " = #{x:0>2}{x:0>2}{x:0>2}{x:0>2}{s}\n", .{
            color.color.r,
            color.color.g,
            color.color.b,
            color.color.a,
            // clear color after
            if (colors_supported) "\x1b[0m" else "",
        });
    }
}

const params = clap.parseParamsComptime(help);

const ParseStringError = error{
    @"String empty!",
    @"Invalid UTF-8 String!",
};

fn parseString(str: []const u8) ParseStringError![]const u8 {
    if (str.len == 0) return error.@"String empty!";
    if (!unicode.utf8ValidateSlice(str)) return error.@"Invalid UTF-8 String!";
    return str;
}

const ParsePathError = error{
    @"Path too long",
    @"Failed to resolve real path",
};

fn parsePath(path: []const u8) ParsePathError!Path {
    var out_path = Path{};

    const real_path = std.fs.realpath(path, &out_path.buffer) catch |err| {
        log.warn("Failed to resolve real path with error: {s}", .{@errorName(err)});
        return error.@"Failed to resolve real path";
    };

    out_path.resize(real_path.len) catch unreachable;

    return Path.fromSlice(path) catch return error.@"Path too long";
}

const ParserCharacterError = error{
    @"No character provided",
    @"Character isn't valid UTF-8",
    @"Too many characters provided, only 1 character allowed",
};

fn parseCharacter(character: []const u8) ParserCharacterError!u21 {
    if (character.len == 0) return error.@"No character provided";
    const sequence_length = unicode.utf8ByteSequenceLength(character[0]) catch {
        return error.@"Character isn't valid UTF-8";
    };
    if (sequence_length != character.len) return error.@"Too many characters provided, only 1 character allowed";

    const char = unicode.utf8Decode(character) catch {
        return error.@"Character isn't valid UTF-8";
    };

    return char;
}

const options = @import("options");

const ClockConfig = @import("Clock.zig").ClockConfig;
const BatteryConfig = @import("Battery.zig").BatteryConfig;
const BrightnessConfig = @import("Brightness.zig").BrightnessConfig;
const WorkspacesConfig = @import("workspaces/Workspaces.zig").WorkspacesConfig;

const colors = @import("colors.zig");
const Color = colors.Color;
const all_colors = colors.all_colors;

const constants = @import("constants.zig");

const drawing = @import("drawing.zig");
const Size = drawing.Size;

const parse_config = @import("parse_config.zig");
const parseConfig = parse_config.parseConfig;

const clap = @import("clap");

const builtin = @import("builtin");
const std = @import("std");
const unicode = std.unicode;
const posix = std.posix;
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const assert = std.debug.assert;
const print = std.debug.print;
const exit = std.process.exit;
const max_path_bytes = std.fs.max_path_bytes;

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;

const log = std.log.scoped(.Config);
