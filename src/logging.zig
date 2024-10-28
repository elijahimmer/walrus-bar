var tty_config: ?tty.Config = null;
var scope_width: u32 = 0;

pub fn logFn(
    comptime level: LogLevel,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const in_other_scopes = comptime mem.indexOfScalar(@TypeOf(.enum_literal), &other_logging_scopes, scope);
    const is_default = scope == .default;
    const logging_options_has_scope = @hasDecl(logging_options, @tagName(scope));

    // if log level is not specified in build options
    if (in_other_scopes == null and !is_default and !logging_options_has_scope) {
        @compileError("Logging scope '" ++ @tagName(scope) ++ "' doesn't have a log level in logging_options");
    }

    const scope_prefix: []const u8 = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

    if (scope_prefix.len + 1 > scope_width) scope_width = scope_prefix.len + 1;

    const printing_log_level = if (logging_options_has_scope)
        @field(logging_options, @tagName(scope))
    else
        std.log.default_level;

    const stderr = std.io.getStdErr();

    if (tty_config == null) tty_config = tty.detectConfig(stderr);

    const log_text = switch (level) {
        .err => "Error",
        .warn => "Warn ",
        .info => "Info ",
        .debug => "Debug",
    };

    const log_color = switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .blue,
    };

    // if the logging level isn't high enough, don't print.
    if (@intFromEnum(level) > @intFromEnum(printing_log_level)) return;

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const writer = stderr.writer();
    nosuspend {
        tty_config.?.setColor(writer, log_color) catch return;
        _ = writer.write(log_text) catch return;
        tty_config.?.setColor(writer, .reset) catch return;
        _ = writer.write(" " ++ scope_prefix) catch return;
        _ = writer.writeByteNTimes(' ', scope_width - scope_prefix.len) catch return;
        writer.print(format ++ "\n", args) catch return;
    }
}

const other_logging_scopes = [_]@TypeOf(.enum_literal){
    .@"walrus-bar",
    .gpa,
    .DrawContext,
    .Seat,
    .Output,
    .Pointer,
};

const logging_options = @import("logging-options");

const std = @import("std");
const mem = std.mem;
const tty = std.io.tty;
const ascii = std.ascii;

const LogLevel = std.log.Level;
