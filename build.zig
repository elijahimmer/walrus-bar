pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "walrus-bar",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const font = b.addOptions();

    const font_path = b.option([]const u8, "font-path", "Path to font to use") orelse "fonts/FiraCodeNerdFontMono-Regular.ttf";
    const font_file = std.fs.cwd().openFile(font_path, .{ .mode = .read_only }) catch @panic("Failed to open font file");
    const font_data = font_file.readToEndAlloc(b.allocator, 5_000_000) catch @panic("Failed to read font file (maybe larger than 5Mbs)?");
    font.addOption([]const u8, "font_data", font_data);

    //
    // TODO: Change all these logging to be log levels...
    //       so don't be stupid...
    //

    const options = b.addOptions();
    const logging_options = b.addOptions();
    { // freetype
        const FreeTypeAllocatorOptions = enum { c, zig };
        const freetype_allocator = b.option(FreeTypeAllocatorOptions, "freetype-allocator", "Which allocator freetype should use (default: zig)") orelse .zig;
        options.addOption(FreeTypeAllocatorOptions, "freetype_allocator", freetype_allocator);

        const freetype_allocation_logging = b.option(LogLevel, "freetype-allocation-logging", "Enable FreeType allocations logging (default: warn)") orelse .warn;
        logging_options.addOption(LogLevel, "FreeTypeAlloc", freetype_allocation_logging);

        const freetype_cache_size = b.option(usize, "freetype-cache-size", "The default glyph cache size in bytes (default: 16384)") orelse 16384;
        options.addOption(usize, "freetype_cache_size", freetype_cache_size);

        const freetype_cache_logging = b.option(LogLevel, "freetype-cache-logging", "Enable logging for the FreeType cache (default: warn)") orelse .warn;
        logging_options.addOption(LogLevel, "FreeTypeCache", freetype_cache_logging);

        const freetype_logging = b.option(LogLevel, "freetype-logging", "Enable verbose logging for FreeType (default: warn)") orelse .warn;
        logging_options.addOption(LogLevel, "FreeTypeContext", freetype_logging);
    }

    const registry_logging = b.option(LogLevel, "registry_logging", "Enable Wayland Registry Logging (default: warn)") orelse .warn;
    logging_options.addOption(LogLevel, "Registry", registry_logging);

    const track_damage = b.option(bool, "track-damage", "Enable damage outlines. (default: false)") orelse false;
    options.addOption(bool, "track_damage", track_damage);

    const WorkspacesOptions = enum { hyprland, testing, none };
    const workspaces_provider = b.option(WorkspacesOptions, "workspaces-provider", "Which compositor the workspaces should be compiled for (default: hyprland)") orelse .hyprland;
    options.addOption(WorkspacesOptions, "workspaces_provider", workspaces_provider);

    inline for (.{
        "clock",
        "workspaces",
        "battery",
    }) |widget| {
        const disable_widget = b.option(bool, widget ++ "-disable", "Enable the " ++ widget ++ "                           (default: false)") orelse false;
        const debug_widget = b.option(bool, widget ++ "-debug", "Enable all the debugging options for " ++ widget ++ " (default: false)") orelse false;
        const enable_outlines = b.option(bool, widget ++ "-outlines", "Enable outlines for " ++ widget ++ "                  (default: debug-widget)") orelse debug_widget;
        const verbose_logging = b.option(
            LogLevel,
            widget ++ "-logging",
            "Enable verbose logging for " ++ widget ++ "           (default: warn, debug if " ++ widget ++ "-debug is true)",
        );

        if (disable_widget and debug_widget) @panic("You have to enable " ++ widget ++ " to debug it!");
        if (disable_widget and verbose_logging != null) @panic("You have to enable " ++ widget ++ " to have it log verbosely it!");
        if (disable_widget and enable_outlines) @panic("You have to enable " ++ widget ++ " to draw it's outline!");

        options.addOption(bool, widget ++ "_disable", disable_widget);
        options.addOption(bool, widget ++ "_debug", debug_widget);
        options.addOption(bool, widget ++ "_outlines", enable_outlines);

        if (mem.eql(u8, widget, "workspaces")) {
            logging_options.addOption(LogLevel, "WorkspacesWorker", verbose_logging orelse if (debug_widget) .debug else .warn);
        }

        // TODO: Find a nicer way to do this
        var logging_name: [widget.len]u8 = undefined;
        @memcpy(&logging_name, widget);
        logging_name[0] = std.ascii.toUpper(logging_name[0]);

        logging_options.addOption(LogLevel, &logging_name, verbose_logging orelse if (debug_widget) .debug else .warn);
    }

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const clap = b.dependency("clap", .{});
    const freetype = b.dependency("freetype", .{
        .enable_brotli = false,
        .use_system_zlib = false,
    });

    const scanner = Scanner.create(b, .{
        .wayland_xml_path = "protocols/wayland.xml",
        .wayland_protocols_path = "protocols",
    });

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml"); // needed by wlr-layer-shell
    scanner.addSystemProtocol("wlr/unstable/wlr-layer-shell-unstable-v1.xml");

    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_seat", 9);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    //scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwlr_layer_shell_v1", 4);

    inline for (.{ exe, exe_unit_tests }) |l| {
        // TODO: remove when https://github.com/ziglang/zig/issues/131 is implemented
        scanner.addCSource(l);

        l.step.dependOn(&font.step);
        l.step.dependOn(&options.step);
        l.root_module.addOptions("font", font);
        l.root_module.addOptions("options", options);
        l.root_module.addOptions("logging-options", logging_options);

        l.root_module.addImport("clap", clap.module("clap"));

        l.linkLibrary(freetype.artifact("freetype"));

        l.root_module.addImport("wayland", wayland);
        l.linkSystemLibrary("wayland-client");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

const LogLevel = enum { debug, info, warn, err };

const std = @import("std");
const mem = std.mem;

const Scanner = @import("zig-wayland").Scanner;
