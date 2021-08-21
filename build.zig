const std = @import("std");

const Guid = std.os.windows.GUID;

pub extern "RPCRT4" fn UuidCreate(
    Uuid: *Guid,
) callconv(std.os.windows.WINAPI) i32;

pub extern "RPCRT4" fn UuidToStringA(
    Uuid: *Guid,
    StringUuid: *[*:0]u8,
) callconv(@import("std").os.windows.WINAPI) i32;

pub extern "RPCRT4" fn RpcStringFreeA(
    String: *[*:0]u8,
) callconv(@import("std").os.windows.WINAPI) i32;

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe
    const release = b.option(bool, "release", "Optimizations on and safety on.") orelse false;
    const console = b.option(bool, "console", "Log to the console.") orelse false;
    std.log.info("Building with release={}, console={}", .{ release, console });

    var mode = if (release) std.builtin.Mode.ReleaseSafe else std.builtin.Mode.Debug;
    b.is_release = mode != .Debug;
    b.release_mode = mode;

    // Generate guid
    var guid: Guid = undefined;
    _ = UuidCreate(&guid);
    var guidStringPtr: [*:0]u8 = undefined;
    _ = UuidToStringA(&guid, &guidStringPtr);
    const guidString = guidStringPtr[0..std.mem.len(guidStringPtr)];
    std.log.info("Using tray icon guid: {s}", .{guidString});
    defer _ = RpcStringFreeA(&guidStringPtr);

    const exe = b.addExecutable(if (release) "zwtwm" else "zwtwm_debug", "src/main.zig");
    exe.addBuildOption(bool, "RUN_IN_CONSOLE", console);
    exe.addBuildOption([]const u8, "TRAY_GUID", guidString);
    exe.addPackage(.{ .name = "zigwin32", .path = "./deps/custom_zigwin32/win32.zig" });

    exe.subsystem = if (!console) .Windows else .Console;
    std.log.info("Using subsystem {}", .{exe.subsystem});
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
