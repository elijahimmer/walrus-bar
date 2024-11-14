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

    const font_path = b.option([]const u8, "font-path", "Path to font to use (default: 'fonts/NerdFont/FiraCodeNerdFontMono-Regular.ttf')") orelse "fonts/NerdFont/FiraCodeNerdFontMono-Regular.ttf";
    const font_file = std.fs.cwd().openFile(font_path, .{ .mode = .read_only }) catch @panic("Failed to open font file");
    const font_data = font_file.readToEndAlloc(b.allocator, 5_000_000) catch @panic("Failed to read font file (maybe larger than 5Mbs)?");
    font.addOption([]const u8, "font_data", font_data);

    const versions = b.addOptions();
    { // versions
        versions.addOption([]const u8, "version", "0.1.6");
        versions.addOption([]const u8, "zig_clap_version", "0.0.0");
    }

    const options = b.addOptions();
    const logging_options = b.addOptions();

    const allocation_logging_level = b.option(LogLevel, "allocation-logging-level", "Which logging level to use for allocations (default: warn)") orelse .warn;
    logging_options.addOption(LogLevel, "allocations", allocation_logging_level);
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

    { // root container
        const root_container_debug = b.option(bool, "root-container-debug", "Enable all the debugging options for Root Container (default: false)") orelse false;
        const root_container_logging_level = b.option(
            LogLevel,
            "root-container-logging",
            "What log level to enable for Root Container         (default: if root-container-debug is true, debug. Otherwise warn)",
        );

        // don't have space so it matches correctly.
        options.addOption(bool, "rootcontainer_debug", root_container_debug);

        logging_options.addOption(LogLevel, "RootContainer", root_container_logging_level orelse if (root_container_debug) .debug else .warn);
    }

    const WorkspacesOptions = enum { hyprland, testing, none };
    const workspaces_provider = b.option(WorkspacesOptions, "workspaces-provider", "Which compositor the workspaces should be compiled for (default: hyprland)") orelse .hyprland;
    options.addOption(WorkspacesOptions, "workspaces_provider", workspaces_provider);

    inline for (.{
        "clock",
        "workspaces",
        "battery",
        "brightness",
    }) |widget| {
        const disable_widget = b.option(bool, widget ++ "-disable", "Enable the " ++ widget ++ "                           (default: false)") orelse false;
        const debug_widget = b.option(bool, widget ++ "-debug", "Enable all the debugging options for " ++ widget ++ " (default: false)") orelse false;
        const enable_outlines = b.option(bool, widget ++ "-outlines", "Enable outlines for " ++ widget ++ "                  (default: debug-widget)") orelse debug_widget;
        const logging_level = b.option(
            LogLevel,
            widget ++ "-logging",
            "What log level to enable for " ++ widget ++ "         (default: if " ++ widget ++ "-debug is true, debug. Otherwise warn)",
        );

        if (disable_widget and debug_widget) @panic("You have to enable " ++ widget ++ " to debug it!");
        if (disable_widget and logging_level != null) @panic("You have to enable " ++ widget ++ " specify it's logging level!");
        if (disable_widget and enable_outlines) @panic("You have to enable " ++ widget ++ " to draw it's outline!");

        options.addOption(bool, widget ++ "_enabled", !disable_widget);
        options.addOption(bool, widget ++ "_debug", debug_widget);
        options.addOption(bool, widget ++ "_outlines", enable_outlines);

        if (mem.eql(u8, widget, "workspaces")) {
            logging_options.addOption(LogLevel, "WorkspacesWorker", logging_level orelse if (debug_widget) .debug else .warn);
        }

        logging_options.addOption(LogLevel, widget, logging_level orelse if (debug_widget) .debug else .warn);
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

    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_seat", 9);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);

    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml"); // needed for cursor-shape-v1
    scanner.generate("zwp_tablet_manager_v2", 1);

    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.generate("wp_cursor_shape_manager_v1", 1);

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml"); // needed by wlr-layer-shell
    //scanner.generate("xdg_wm_base", 2);

    scanner.addSystemProtocol("wlr/unstable/wlr-layer-shell-unstable-v1.xml");
    scanner.generate("zwlr_layer_shell_v1", 4);

    inline for (.{ exe, exe_unit_tests }) |l| {
        // TODO: Statically link this all.
        // TODO: remove when https://github.com/ziglang/zig/issues/131 is implemented
        scanner.addCSource(l);

        l.step.dependOn(&font.step);
        l.step.dependOn(&options.step);
        l.root_module.addOptions("font", font);
        l.root_module.addOptions("options", options);
        l.root_module.addOptions("versions", versions);
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

const std = @import("std");
const mem = std.mem;

const LogLevel = std.log.Level;

const Scanner = @import("zig-wayland").Scanner;
