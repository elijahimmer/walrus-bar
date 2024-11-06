//! TODO: Implement widget specific color options.

pub const Config = @This();

pub const default_text_color = "rose";
pub const default_background_color = "surface";

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

clap_res: clap.Result(clap.Help, &params, parsers),
// general things
program_name: []const u8,

// params
width: ?u16,
height: u16,

title: []const u8,

text_color: Color,
background_color: Color,

battery_directory: if (!options.battery_disable) []const u8 else void,
brightness_directory: if (!options.brightness_disable) []const u8 else void,

font_size: u16,

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

    if (args.height != null and args.height.? < constants.MINIMUM_WINDOW_HEIGHT) {
        stdout_writer.print("Height provided ({}) is smaller than minimum height ({})", .{ args.height.?, constants.MINIMUM_WINDOW_HEIGHT }) catch {};
        exit(1);
    }

    return Config{
        .clap_res = res,
        .program_name = program_name,

        .width = args.width,
        .height = args.height orelse 28,

        .text_color = args.@"text-color" orelse @field(colors, default_text_color),
        .background_color = args.@"background-color" orelse @field(colors, default_background_color),
        .font_size = args.@"font-size" orelse 20,

        .battery_directory = if (!options.battery_disable) args.@"battery-directory" orelse default_battery_directory else {},
        .brightness_directory = if (!options.brightness_disable) args.@"brightness-directory" orelse default_brightness_directory else {},

        .title = args.title orelse std.mem.span(std.os.argv[0]),
    };
}

const help =
    \\-h, --help                     Display this help and exit.
    \\    --dependencies             Print a list of the dependencies and versions and exit.
    \\-w, --width <INT>              The window's width (full screen if not specified)
    \\-l, --height <INT>             The window's height (minimum: 15) (default: 28)
    \\-t, --title <STR>              The window's title (default: OS Process Name [likely 'walrus-bar'])
    \\
++ (if (!options.battery_disable)
    std.fmt.comptimePrint(
        \\    --battery-directory <PATH> The absolute path to the battery directory (default: "{s}")
        \\
    , .{default_battery_directory})
else
    "") ++ (if (!options.brightness_disable)
    std.fmt.comptimePrint(
        \\    --brightness-directory <PATH> The absolute path to the brightness directory (default: "{s}")
        \\
    , .{default_brightness_directory})
else
    "") ++ std.fmt.comptimePrint(
    \\
    \\-T, --text-color <COLOR>       The text color by name or by hex code (starting with '#') (default: {s})
    \\-b, --background-color <COLOR> The background color by name or by hex code (starting with '#') (default: {s})
    \\
, .{ default_text_color, default_background_color }) ++
    \\-f, --font-size <INT>          The font size in points (default: 20)
    \\
;

const help_message_prelude = std.fmt.comptimePrint("Walrus-Bar v{s}\n", .{constants.version_str});

const dependencies_message =
    std.fmt.comptimePrint(
    \\ Walrus-Bar v{s}
    \\ Built with:
    \\ - Zig v{s}
    \\ - Freetype v{s}
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

const params = clap.parseParamsComptime(help);

const parsers = .{
    .PATH = pathParser,
    .STR = clap.parsers.string,
    .INT = clap.parsers.int(u16, 10),
    .COLOR = colors.str2Color,
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
const default_battery_directory = Battery.default_battery_directory;

const Brightness = @import("Brightness.zig");
const default_brightness_directory = Brightness.default_brightness_directory;

const colors = @import("colors.zig");
const Color = colors.Color;
const all_colors = colors.all_colors;

const constants = @import("constants.zig");

const builtin = @import("builtin");
const std = @import("std");

const assert = std.debug.assert;
const print = std.debug.print;
const exit = std.process.exit;
const fs = std.fs;

const Allocator = std.mem.Allocator;

const clap = @import("clap");
