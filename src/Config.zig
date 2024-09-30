pub const Config = @This();

/// global config. Use only after you have initialized it with init
pub var config: Config = undefined;

pub fn init_global(allocator: Allocator) Allocator.Error!void {
    config = try parse_argv(allocator);
}

pub fn deinit_global() void {
    config.deinit();
}

// general things
arena: ArenaAllocator,
program_name: []const u8,

// params
width: ?u16,
height: u16,

title: []const u8,

background_color: Color,

font_size: u16,

pub fn deinit(self: *const Config) void {
    self.arena.deinit();
}

pub fn parse_argv(allocator: Allocator) Allocator.Error!Config {
    var arena = ArenaAllocator.init(allocator);
    const alloc = arena.allocator();

    var iter = try std.process.ArgIterator.initWithAllocator(alloc);
    defer iter.deinit();

    const program_name = iter.next() orelse "walrus-bar";

    var diag = clap.Diagnostic{};
    const res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        exit(1);
    };

    const args = &res.args;

    if (args.help != 0) {
        clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{}) catch {};
        exit(0);
    }

    return Config{
        .arena = arena,
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
const ArenaAllocator = std.heap.ArenaAllocator;

const clap = @import("clap");
