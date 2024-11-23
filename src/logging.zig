// Give these default log scope.
const other_logging_scopes = [_]@TypeOf(.enum_literal){
    .default,
    .@"walrus-bar",
    .gpa,
    .DrawContext,
    .Seat,
    .Output,
    .Pointer,
    .Config,
    .ParseConfig,
    .OutputContext,
    .Output,
    .WaylandContext,
    .ShmPool,
};

// These have build script specified logging levels.
const log_scopes = [_]@TypeOf(.enum_literal){
    // General
    .Allocations,

    // FreeType
    .FreeTypeAlloc,
    .FreeTypeCache,
    .FreeTypeContext,

    // Wayland
    .Registry,

    // Widgets
    .RootContainer,
    .Clock,
    .WorkspacesWorker,
    .Workspaces,
    .Brightness,
    .Battery,
};

/// The custom logging function.
pub fn logFn(
    comptime level: LogLevel,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix: []const u8 = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    const printing_log_level: LogLevel = comptime printing_log_level: {
        const is_ignored = mem.indexOfScalar(@TypeOf(.enum_literal), &other_logging_scopes, scope) != null;
        if (is_ignored) break :printing_log_level std.log.default_level;

        for (@typeInfo(logging_options).Struct.decls) |decl| {
            if (!ascii.eqlIgnoreCase(decl.name, @tagName(scope))) continue;

            break :printing_log_level @enumFromInt(@intFromEnum(@field(logging_options, decl.name)));
        }

        @compileError("Log scope '" ++ @tagName(scope) ++ "' not found. Put in logging.zig!");
    };

    // if the logging level isn't high enough, don't print or anything.
    if (@intFromEnum(level) > @intFromEnum(printing_log_level)) return;

    const S = struct {
        pub var tty_config: ?tty.Config = null;
        pub var scope_width: u32 = 0;
    };

    if (scope_prefix.len > S.scope_width) S.scope_width = scope_prefix.len;

    const stderr = std.io.getStdErr();
    if (S.tty_config == null) S.tty_config = tty.detectConfig(stderr);

    const log_text = comptime switch (level) {
        .err => "Error",
        .warn => "Warn ",
        .info => "Info ",
        .debug => "Debug",
    };

    const log_color = comptime switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .blue,
    };

    var buffered_writer = std.io.bufferedWriter(stderr.writer());
    const writer = buffered_writer.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    nosuspend {
        defer buffered_writer.flush() catch {};
        // Colored log type
        S.tty_config.?.setColor(writer, log_color) catch return;
        _ = writer.write(log_text) catch return;
        S.tty_config.?.setColor(writer, .reset) catch return;

        // Log Scope
        _ = writer.write(" " ++ scope_prefix) catch return;
        // Spacing so its pretty
        _ = writer.writeByteNTimes(' ', S.scope_width - scope_prefix.len) catch return;

        // The actual log
        writer.print(format ++ "\n", args) catch return;
    }
}

// TODO: Make this nicer.
pub const logging_scope_levels: [log_scopes.len]ScopeLevel = logging_scope_levels: {
    var scope_levels: [log_scopes.len]ScopeLevel = undefined;
    var scope_idx = 0;

    for (@typeInfo(logging_options).Struct.decls) |decl| {
        if (@TypeOf(@field(logging_options, decl.name)) != logging_options.@"log.Level") continue;
        defer scope_idx += 1;
        scope_levels[scope_idx] = .{
            .scope = scope: {
                for (log_scopes) |scope| {
                    if (ascii.eqlIgnoreCase(decl.name, @tagName(scope))) break :scope scope;
                }
                @compileError("Log scope '" ++ decl.name ++ "' not found! Put in /logging.zig");
            },
            .level = @enumFromInt(@intFromEnum(@field(logging_options, decl.name))),
        };
    }

    assert(scope_idx == log_scopes.len);

    break :logging_scope_levels scope_levels;
};

const logging_options = @import("logging-options");

const std = @import("std");
const mem = std.mem;
const tty = std.io.tty;
const math = std.math;
const ascii = std.ascii;

const assert = std.debug.assert;

const LogLevel = std.log.Level;
const ScopeLevel = std.log.ScopeLevel;
