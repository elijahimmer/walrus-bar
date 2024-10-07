pub const Config = @This();

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

background_color: Color,

font_size: u16,

fn parse_argv(allocator: Allocator) Allocator.Error!Config {
    var iter = std.process.ArgIterator.init();
    defer iter.deinit();

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

    if (args.help != 0) {
        clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{}) catch {};
        exit(0);
    }

    return Config{
        .clap_res = res,
        .program_name = program_name,

        .width = args.width,
        .height = args.height orelse 28,

        .background_color = args.@"background-color" orelse all_colors.surface,
        .font_size = args.@"font-size" orelse 20,

        .title = args.title orelse std.mem.span(std.os.argv[0]),
    };
}

const help =
    \\-h, --help                     Display this help and exit.
    \\-w, --width <INT>              The window's width (full screen if not specified)
    \\-l, --height <INT>             The window's height (default: 28)
    \\-t, --title <STR>              The window's title
    \\-b, --background-color <COLOR> The background color in hex
    \\-T, --text-color <COLOR>       The text color in hex (default)
    \\-f, --font-size <INT>          The font size in points
    \\
;

const params = clap.parseParamsComptime(help);

const parsers = .{
    .STR = clap.parsers.string,
    .INT = clap.parsers.int(u16, 10),
    .COLOR = colors.str2Color,
};

const colors = @import("colors.zig");
const Color = colors.Color;
const all_colors = colors.all_colors;

const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;
const exit = std.process.exit;

const Allocator = std.mem.Allocator;

const clap = @import("clap");
