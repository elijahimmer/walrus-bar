//! TODO: Implement configuration files

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

battery_directory: if (!options.battery_disable) []const u8 else void,

battery_background_color: if (!options.battery_disable) Color else void,
battery_critical_animation_speed: if (!options.battery_disable) u8 else void,

battery_full_color: if (!options.battery_disable) Color else void,
battery_charging_color: if (!options.battery_disable) Color else void,
battery_discharging_color: if (!options.battery_disable) Color else void,
battery_warning_color: if (!options.battery_disable) Color else void,
battery_critical_color: if (!options.battery_disable) Color else void,

brightness_directory: if (!options.brightness_disable) []const u8 else void,
brightness_color: if (!options.brightness_disable) Color else void,
brightness_background_color: if (!options.brightness_disable) Color else void,

scroll_ticks: if (!options.brightness_disable) u8 else void,

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

        .font_size = args.@"font-size" orelse 20,

        .background_color = background_color,

        .clock_text_color = if (!options.clock_disable) args.@"clock-text-color" orelse text_color else {},
        .clock_spacer_color = if (!options.clock_disable) args.@"clock-spacer-color" orelse colors.pine else {},
        .clock_background_color = if (!options.clock_disable) args.@"clock-background-color" orelse background_color else {},

        .workspaces_text_color = if (!options.workspaces_disable) args.@"workspaces-text-color" orelse text_color else {},
        .workspaces_background_color = if (!options.workspaces_disable) args.@"workspaces-background-color" orelse background_color else {},

        .workspaces_hover_text_color = if (!options.workspaces_disable) args.@"workspaces-hover-text-color" orelse colors.gold else {},
        .workspaces_hover_background_color = if (!options.workspaces_disable) args.@"workspaces-hover-background-color" orelse colors.hl_med else {},

        .workspaces_active_text_color = if (!options.workspaces_disable) args.@"workspaces-active-text-color" orelse colors.gold else {},
        .workspaces_active_background_color = if (!options.workspaces_disable) args.@"workspaces-active-background-color" orelse colors.pine else {},

        .workspaces_spacing = if (!options.workspaces_disable) args.@"workspaces-spacing" orelse 0 else {},

        .battery_directory = if (!options.battery_disable) args.@"battery-directory" orelse default_battery_directory else {},

        .battery_background_color = if (!options.battery_disable) args.@"battery-background-color" orelse background_color else {},
        .battery_critical_animation_speed = if (!options.battery_disable) args.@"battery-critical-animation-speed" orelse 8 else {},

        .battery_full_color = if (!options.battery_disable) args.@"battery-full-color" orelse colors.gold else {},
        .battery_charging_color = if (!options.battery_disable) args.@"battery-charging-color" orelse colors.iris else {},
        .battery_discharging_color = if (!options.battery_disable) args.@"battery-discharging-color" orelse colors.pine else {},
        .battery_warning_color = if (!options.battery_disable) args.@"battery-warning-color" orelse colors.rose else {},
        .battery_critical_color = if (!options.battery_disable) args.@"battery-critical-color" orelse colors.love else {},

        .brightness_directory = if (!options.brightness_disable) args.@"brightness-directory" orelse default_brightness_directory else {},
        .brightness_color = if (!options.brightness_disable) args.@"brightness-color" orelse colors.rose else {},
        .brightness_background_color = if (!options.brightness_disable) args.@"brightness-background-color" orelse background_color else {},

        .scroll_ticks = if (!options.brightness_disable) args.@"brightness-scroll-ticks" orelse default_brightness_scoll_ticks else {},

        .title = args.title orelse std.mem.span(std.os.argv[0]),
    };
}

const help =
    \\-h, --help                     Display this help and exit.
    \\    --dependencies             Print a list of the dependencies and versions and exit.
    \\    --colors                   Print a list of all the named colors and exit.
    \\-w, --width <U16>              The window's width (full screen if not specified)
    \\-l, --height <U16>             The window's height (minimum: 15) (default: 28)
    \\-t, --title <STR>              The window's title (default: OS Process Name [likely 'walrus-bar'])
    \\
++ std.fmt.comptimePrint(
    \\-T, --text-color <COLOR>       The text color by name or by hex code (starting with '#') (default: {s})
    \\-b, --background-color <COLOR> The background color by name or by hex code (starting with '#') (default: {s})
    \\-f, --font-size <U16>          The font size in points (default: 20)
    \\
, .{ default_text_color, default_background_color }) ++ (if (!options.battery_disable)
    std.fmt.comptimePrint(
        \\    --battery-directory <PATH>               The absolute path to the battery directory (default: "{s}")
        \\    --battery-critical-animation-speed <U8>  The speed of the animation (default: 8)
        \\
        \\    --battery-background-color <COLOR>       The background color of the battery (default: background-color)
        \\
        \\    --battery-full-color <COLOR>             The color of the battery when it is full (default: GOLD)
        \\    --battery-charging-color <COLOR>         The color of the battery when it is charging (default: IRIS)
        \\    --battery-discharging-color <COLOR>      The color of the battery when it is discharging (default: PINE)
        \\    --battery-warning-color <COLOR>          The color of the battery when it is low (default: ROSE)
        \\    --battery-critical-color <COLOR>         The color of the battery when it is critically low (default: LOVE)
        \\
    , .{default_battery_directory})
else
    "") ++ (if (!options.brightness_disable)
    std.fmt.comptimePrint(
        \\    --brightness-directory <PATH>         The absolute path to the brightness directory (default: "{s}")
        \\    --brightness-scroll-ticks <U8>        The number of scroll ticks to get from (default: {})
        \\
        \\    --brightness-color <COLOR>            The color of the brightness icon (default: ROSE)
        \\    --brightness-background-color <COLOR> The background color of the brightness (default: background-color)
        \\
    , .{ default_brightness_directory, default_brightness_scoll_ticks })
else
    "") ++ (if (!options.clock_disable)
    \\    --clock-text-color <COLOR>       The text color of the clock's numbers (default: text-color)
    \\    --clock-spacer-color <COLOR>     The text color of the clock's spacers (default: PINE)
    \\    --clock-background-color <COLOR> The background color of the clock (default: background-color)
    \\
else
    "") ++ (if (!options.workspaces_disable)
    \\    --workspaces-text-color <COLOR>               The text color of the workspaces (default: text-color)
    \\    --workspaces-background-color <COLOR>         The background color of the workspaces (default: background-color)
    \\    --workspaces-hover-text-color <COLOR>         The text color of the workspaces when hovered (default: GOLD)
    \\    --workspaces-hover-background-color <COLOR>   The background color of the workspaces when hovered (default: HL_MED)
    \\    --workspaces-active-text-color <COLOR>        The text color of the workspaces when active (default: GOLD)
    \\    --workspaces-active-background-color <COLOR>  The background color of the workspaces when active (default: PINE)
    \\    --workspaces-spacing <U16>                    The space (in pixels) between two workspaces (default: 0)
    \\
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
    .PATH = pathParser,
    .STR = clap.parsers.string,
    .U16 = clap.parsers.int(u16, 0),
    .U8 = clap.parsers.int(u8, 0),
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
const default_brightness_scoll_ticks = Brightness.default_brightness_scoll_ticks;

const colors = @import("colors.zig");
const Color = colors.Color;
const all_colors = colors.all_colors;

const constants = @import("constants.zig");

const drawing = @import("drawing.zig");
const Size = drawing.Size;

const builtin = @import("builtin");
const std = @import("std");

const assert = std.debug.assert;
const print = std.debug.print;
const exit = std.process.exit;
const fs = std.fs;

const Allocator = std.mem.Allocator;

const clap = @import("clap");
