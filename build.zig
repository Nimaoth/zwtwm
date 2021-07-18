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

    const mode = if (release) std.builtin.Mode.ReleaseSafe else std.builtin.Mode.Debug;
    b.is_release = mode != .Debug;
    b.release_mode = mode;

    const shipping = mode != .Debug;

    const exe = b.addExecutable(if (shipping) "zwtwm" else "zwtwm_debug", "src/main.zig");
    exe.addBuildOption(bool, "RUN_IN_CONSOLE", !shipping);
    exe.subsystem = if (shipping) .Windows else .Console;
    exe.addPackage(.{ .name = "zigwin32", .path = "./deps/custom_zigwin32/win32.zig" });

    exe.setTarget(target);
    exe.setBuildMode(if (shipping) .ReleaseSafe else mode);
    exe.install();

    // Add config to install.
    b.installFile("config.json", "bin/config.json");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
