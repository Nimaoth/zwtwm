const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe
    const release = b.option(bool, "release", "Optimizations on and safety on, log to file") orelse false;

    var mode = if (release) std.builtin.Mode.ReleaseSafe else std.builtin.Mode.Debug;
    mode = .Debug;
    b.is_release = mode != .Debug;
    b.release_mode = mode;

    const exe = b.addExecutable(if (release) "zwtwm" else "zwtwm_debug", "src/main.zig");
    exe.addBuildOption(bool, "RUN_IN_CONSOLE", !release);
    if (release) {
        exe.addBuildOption([]const u8, "TRAY_GUID", "99b74174-d3a4-48ba-a886-9af100149755");
    } else {
        exe.addBuildOption([]const u8, "TRAY_GUID", "b3e926bb-e7ee-4f2a-b513-0080167ec220");
    }
    exe.subsystem = if (release) .Windows else .Console;
    exe.addPackage(.{ .name = "zigwin32", .path = "./deps/custom_zigwin32/win32.zig" });

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    // Add config to install.
    b.installFile("config.json", "bin/config.json");
    b.installFile("icon.ico", "bin/icon.ico");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
