//! TODO: Implement configuration files

pub const Config = @This();

pub const default_text_color = "rose";
pub const default_background_color = "surface";
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

background_color: Color,

clock_text_color: if (!options.clock_disable) Color else void,
clock_spacer_color: if (!options.clock_disable) Color else void,
clock_background_color: if (!options.clock_disable) Color else void,

workspaces_text_color: if (!options.workspaces_disable) Color else void,
workspaces_background_color: if (!options.workspaces_disable) Color else void,

workspaces_hover_text_color: if (!options.workspaces_disable) Color else void,
workspaces_hover_background_color: if (!options.workspaces_disable) Color else void,

workspaces_active_text_color: if (!options.workspaces_disable) Color else void,
workspaces_active_background_color: if (!options.workspaces_disable) Color else void,

workspaces_spacing: if (!options.workspaces_disable) Size else void,

battery_config: if (!options.battery_disable) BatteryConfig else void,
brightness_config: if (!options.brightness_disable) BrightnessConfig else void,

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

    const text_color = args.@"text-color" orelse @field(colors, default_text_color);
    const background_color = args.@"background-color" orelse @field(colors, default_background_color);

    return Config{
        .clap_res = res,
        .program_name = program_name,

        .width = args.width,
        .height = args.height orelse 28,

        .background_color = background_color,

        .battery_config = if (!options.battery_disable) createConfig(BatteryConfig, args) else {},
        .brightness_config = if (!options.brightness_disable) createConfig(BrightnessConfig, args) else {},

        .clock_text_color = if (!options.clock_disable) args.@"clock-text-color" orelse text_color else {},
        .clock_spacer_color = if (!options.clock_disable) args.@"clock-spacer-color" orelse colors.pine else {},
        .clock_background_color = if (!options.clock_disable) args.@"clock-background-color" orelse background_color else {},

        .workspaces_text_color = if (!options.workspaces_disable) args.@"workspaces-text-color" orelse text_color else {},
        .workspaces_background_color = if (!options.workspaces_disable) args.@"workspaces-background-color" orelse background_color else {},

        .workspaces_hover_text_color = if (!options.workspaces_disable) args.@"workspaces-hover-text-color" orelse @field(colors, default_workspaces_hover_text_color) else {},
        .workspaces_hover_background_color = if (!options.workspaces_disable) args.@"workspaces-hover-background-color" orelse @field(colors, default_workspaces_hover_background_color) else {},

        .workspaces_active_text_color = if (!options.workspaces_disable) args.@"workspaces-active-text-color" orelse @field(colors, default_workspaces_active_text_color) else {},
        .workspaces_active_background_color = if (!options.workspaces_disable) args.@"workspaces-active-background-color" orelse @field(colors, default_workspaces_active_background_color) else {},

        .workspaces_spacing = if (!options.workspaces_disable) args.@"workspaces-spacing" orelse 0 else {},

        .title = args.title orelse std.mem.span(std.os.argv[0]),
    };
}

fn getArgName(comptime T: type, name: []const u8) []const u8 {
    const type_name = type_name: {
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
    @setEvalBranchQuota(10_000);
    assert(@typeInfo(T) == .Struct);
    const type_info = @typeInfo(T).Struct;

    var out: T = .{};

    inline for (type_info.fields) |field| {
        const arg_name = comptime getArgName(T, field.name);

        const arg_type = @TypeOf(@field(out, field.name));

        if (@field(args, arg_name)) |value| {
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
        Size => "Size",
        Color => "Color",
        else => @typeName(T),
    };
}

/// Turns a configuration struct into a help message.
pub fn generateHelpMessageComptime(comptime T: type) [helpMessageLen(T)]u8 {
    @setEvalBranchQuota(10_000);
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
    @setEvalBranchQuota(10_000);
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
    \\-h, --help                     Display this help and exit.
    \\    --dependencies             Print a list of the dependencies and versions and exit.
    \\    --colors                   Print a list of all the named colors and exit.
    \\-w, --width <Size>              The window's width (full screen if not specified)
    \\-l, --height <Size>             The window's height (minimum: 15) (default: 28)
    \\-t, --title <String>              The window's title (default: OS Process Name [likely 'walrus-bar'])
    \\
++ std.fmt.comptimePrint(
    \\-T, --text-color <Color>       The text color by name or by hex code (starting with '#') (default: {s})
    \\-b, --background-color <Color> The background color by name or by hex code (starting with '#') (default: {s})
    \\
, .{ default_text_color, default_background_color }) ++ (if (!options.battery_disable) generateHelpMessageComptime(BatteryConfig) else "") ++ (if (!options.brightness_disable) generateHelpMessageComptime(BrightnessConfig) else "") ++
    (if (!options.clock_disable)
    \\    --clock-text-color <Color>       The text color of the clock's numbers (default: text-color)
    \\    --clock-spacer-color <Color>     The text color of the clock's spacers (default: PINE)
    \\    --clock-background-color <Color> The background color of the clock (default: background-color)
    \\
else
    "") ++ (if (!options.workspaces_disable)
    std.fmt.comptimePrint(
        \\    --workspaces-text-color <Color>               The text color of the workspaces (default: text-color)
        \\    --workspaces-background-color <Color>         The background color of the workspaces (default: background-color)
        \\    --workspaces-hover-text-color <Color>         The text color of the workspaces when hovered (default: {s})
        \\    --workspaces-hover-background-color <Color>   The background color of the workspaces when hovered (default: {s})
        \\    --workspaces-active-text-color <Color>        The text color of the workspaces when active (default: {s})
        \\    --workspaces-active-background-color <Color>  The background color of the workspaces when active (default: {s})
        \\    --workspaces-spacing <Size>                    The space (in pixels) between two workspaces (default: {})
        \\
    , .{
        default_workspaces_hover_text_color,
        default_workspaces_hover_background_color,
        default_workspaces_active_text_color,
        default_workspaces_active_background_color,
        default_workspaces_spacing,
    })
else
    "");

const help_message_prelude = std.fmt.comptimePrint("Walrus-Bar v{s}\n", .{constants.version_str});

const dependencies_message =
    std.fmt.comptimePrint(
    \\ Walrus-Bar v{s}
    \\ Built with:
    \\ - Zig v{s}
    \\ - Freetype v{s}
    \\ WORK IN PROGRESS, CHECK SOURCE REPO FOR FULL LIST
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

const parsers = .{
    .Path = pathParser,
    .String = clap.parsers.string,
    .Size = clap.parsers.int(Size, 0),
    .u8 = clap.parsers.int(u8, 0),
    .Color = colors.str2Color,
};

const PathParserError = error{
    PathTooLong,
    PathNotAbsolute,
};

fn pathParser(path: []const u8) PathParserError![]const u8 {
    if (path.len > std.fs.max_path_bytes) return error.PathTooLong;
    if (!fs.path.isAbsolute(path)) return error.PathNotAbsolute;

    return path;
}

const options = @import("options");

const Battery = @import("Battery.zig");
const BatteryConfig = Battery.BatteryConfig;

const Brightness = @import("Brightness.zig");
const BrightnessConfig = Brightness.BrightnessConfig;

const Workspaces = @import("workspaces/Workspaces.zig");
const default_workspaces_hover_text_color = Workspaces.default_workspaces_hover_text_color;
const default_workspaces_hover_background_color = Workspaces.default_workspaces_hover_background_color;
const default_workspaces_active_text_color = Workspaces.default_workspaces_active_text_color;
const default_workspaces_active_background_color = Workspaces.default_workspaces_active_background_color;
const default_workspaces_spacing = Workspaces.default_workspaces_spacing;

const colors = @import("colors.zig");
const Color = colors.Color;
const all_colors = colors.all_colors;

const constants = @import("constants.zig");

const drawing = @import("drawing.zig");
const Size = drawing.Size;

const builtin = @import("builtin");
const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const assert = std.debug.assert;
const print = std.debug.print;
const exit = std.process.exit;

const Allocator = std.mem.Allocator;

const clap = @import("clap");
