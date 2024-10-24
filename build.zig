const std = @import("std");

const Scanner = @import("zig-wayland").Scanner;

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

    const options = b.addOptions();
    const FreeTypeAllocatorOptions = enum { c, zig, @"fixed-buffer" };
    const freetype_allocator = b.option(FreeTypeAllocatorOptions, "freetype-allocator", "Which allocator freetype should use") orelse .zig;
    options.addOption(FreeTypeAllocatorOptions, "freetype_allocator", freetype_allocator);

    const freetype_allocator_fixed_buffer_len = b.option(usize, "freetype-fixed-allocator-len", "How large should be fixed buffer allocator size be") orelse 100 * 1024;
    options.addOption(usize, "freetype_fixed_allocator_len", freetype_allocator_fixed_buffer_len);

    const freetype_allocation_logging = b.option(bool, "freetype-allocation-logging", "Whether or not to log FreeType Allocations.") orelse false;
    options.addOption(bool, "freetype_allocation_logging", freetype_allocation_logging);

    const track_damage = b.option(bool, "track-damage", "Whether to outline damage or not. (default: false)") orelse false;
    options.addOption(bool, "track_damage", track_damage);

    const WorkspacesOptions = enum { hyprland, testing, none };
    const workspaces_provider = b.option(WorkspacesOptions, "workspaces-provider", "Which compositor the workspaces should be compiled for") orelse .hyprland;
    options.addOption(WorkspacesOptions, "workspaces_provider", workspaces_provider);

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
