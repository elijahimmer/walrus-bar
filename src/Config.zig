//! TODO: Implement configuration files

pub const Config = @This();

pub const default_text_color = colors.rose;
pub const default_background_color = colors.surface;
pub const default_window_height = 28;
pub const minimum_window_height = 15;
pub const minimum_window_width = 500;

pub const Path = struct {
    path: []const u8,
};

/// global config. Use only after you have initialized it with init
pub var global: Config = undefined;

/// Reads and initializes the config from CLI args.
/// May not return if bad args or help is passed.
pub fn init_global(allocator: Allocator) Allocator.Error!void {
    global = try parse_argv(allocator);
}

pub fn deinit_global() void {
    global.clap_res.deinit();
    global = undefined;
}

clap_res: clap.Result(clap.Help, &params, parsers), // general things
program_name: []const u8,

// params
width: ?u16,
height: u16,

title: []const u8,

text_color: Color,
background_color: Color,

clock_config: if (options.clock_enabled) ClockConfig else void,
battery_config: if (options.battery_enabled) BatteryConfig else void,
brightness_config: if (options.brightness_enabled) BrightnessConfig else void,
workspaces_config: if (options.workspaces_enabled) WorkspacesConfig else void,

fn parse_argv(allocator: Allocator) Allocator.Error!Config {
    var iter = std.process.ArgIterator.init();
    defer iter.deinit();

    // technically, there should always be a first arg,
    // but whatever.
    const program_name = if (std.os.argv.len > 0)
        std.mem.span(std.os.argv[0])
    else
        "walrus-bar";

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

    const text_color = args.@"text-color" orelse default_text_color;
    const background_color = args.@"background-color" orelse default_background_color;

    return Config{
        .clap_res = res,
        .program_name = program_name,

        .width = args.width,
        .height = args.height orelse default_window_height,

        .text_color = text_color,
        .background_color = background_color,

        .battery_config = if (options.battery_enabled) createConfig(BatteryConfig, args) else {},
        .brightness_config = if (options.brightness_enabled) createConfig(BrightnessConfig, args) else {},
        .clock_config = if (options.clock_enabled) createConfig(ClockConfig, args) else {},
        .workspaces_config = if (options.workspaces_enabled) createConfig(WorkspacesConfig, args) else {},

        .title = args.title orelse std.mem.span(std.os.argv[0]),
    };
}

fn getArgName(comptime T: type, name: []const u8) []const u8 {
    // Not sure why 1_000 branches isn't enough, seems to be something with lastIndexOfScalar or lowerString
    @setEvalBranchQuota(10_000);

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
pub fn createConfig(comptime T: type, args: anytype) T {
    assert(@typeInfo(T) == .Struct);
    const type_info = @typeInfo(T).Struct;

    var out: T = .{};

    inline for (type_info.fields) |field| {
        const arg_name = comptime getArgName(T, field.name);

        const arg_type = @TypeOf(@field(out, field.name));

        // place transient configs here, like background and text colors.

        inline for (.{
            .{ "background_color", Color, default_background_color },
            .{ "text_color", Color, default_text_color },
        }) |loop| {
            const name, const ttype, const default = loop;

            if (comptime ascii.eqlIgnoreCase(field.name, name)) {
                if (field.type != ttype) @compileError(name ++ " field isn't a " ++ @typeName(ttype) ++ "! type: " ++ @typeName(field.type));

                const transient_arg_name = comptime transient_arg_name: {
                    var tan = name.*;

                    mem.replaceScalar(u8, &tan, '_', '-');

                    break :transient_arg_name &tan;
                };

                @field(out, field.name) = @field(args, arg_name) orelse @field(args, transient_arg_name) orelse default;

                break;
            }
        } else if (@field(args, arg_name)) |value| {
            @field(out, field.name) = switch (arg_type) {
                Path => .{ .path = value },
                else => value,
            };
        }
    }

    return out;
}

pub fn resolveTypeName(comptime T: type) []const u8 {
    const tt = if (@typeInfo(T) == .Optional) @typeInfo(T).Optional.child else T;

    return switch (tt) {
        Path => "Path",
        []const u8 => "String",
        u21 => "Character",
        Size => "Size",
        Color => "Color",
        else => @typeName(T),
    };
}

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
    \\-h, --help                     Display this message and exit.
    \\    --dependencies             Print a list of the dependencies and versions and exit.
    \\    --colors                   Print a list of all the named colors and exit.
    \\-w, --width <Size>              The window's width (minimum: {}) (full screen width if not specified)
    \\-l, --height <Size>             The window's height (minimum: {}) (default: {})
    \\-t, --title <String>              The window's title (default: OS Process Name (likely 'walrus-bar'))
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
const parsers = .{
    .Path = pathParser,
    .Character = characterParser,
    .String = clap.parsers.string,
    .Size = clap.parsers.int(Size, 0),
    .u8 = clap.parsers.int(u8, 0),
    .Color = colors.str2Color,
};

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

fn parseString(str: []const u8) ![]const u8 {
    if (str.len == 0) return error.@"String empty!";
    if (!unicode.utf8ValidateSlice(str)) return error.@"Invalid UTF-8 String!";
    return str;
}

const PathParserError = error{
    @"Path too long",
    @"Path isn't absolute",
};

fn pathParser(path: []const u8) PathParserError![]const u8 {
    if (path.len > std.fs.max_path_bytes) return error.@"Path too long";
    if (!fs.path.isAbsolute(path)) return error.@"Path isn't absolute";

    return path;
}

const CharacterParserError = error{
    @"No character provided",
    @"Character isn't valid UTF-8",
    @"Too many characters provided, only 1 character allowed",
};

fn characterParser(character: []const u8) CharacterParserError!u21 {
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
//const default_workspaces_hover_text_color = Workspaces.default_workspaces_hover_text_color;
//const default_workspaces_hover_background_color = Workspaces.default_workspaces_hover_background_color;
//const default_workspaces_active_text_color = Workspaces.default_workspaces_active_text_color;
//const default_workspaces_active_background_color = Workspaces.default_workspaces_active_background_color;
//const default_workspaces_spacing = Workspaces.default_workspaces_spacing;

const colors = @import("colors.zig");
const Color = colors.Color;
const all_colors = colors.all_colors;

const constants = @import("constants.zig");

const drawing = @import("drawing.zig");
const Size = drawing.Size;

const builtin = @import("builtin");
const std = @import("std");
const unicode = std.unicode;
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const assert = std.debug.assert;
const print = std.debug.print;
const exit = std.process.exit;

const Allocator = std.mem.Allocator;

const clap = @import("clap");
