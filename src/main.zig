const std = @import("std");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");
usingnamespace @import("window_manager.zig");
usingnamespace @import("layer.zig");

pub const LOG_LAYERS = false;
pub const ONLY_USE_HALF_MONITOR = false;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub var gWindowManager: WindowManager = undefined;
pub var gWindowStringArena: *std.mem.Allocator = undefined;

pub fn main() anyerror!void {
    defer _ = gpa.deinit();

    var windowStringArena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer windowStringArena.deinit();
    gWindowStringArena = &windowStringArena.allocator;

    std.log.emerg("emerg", .{});
    std.log.alert("alert", .{});
    std.log.crit("crit", .{});
    std.log.err("err", .{});
    std.log.warn("warn", .{});
    std.log.notice("notice", .{});
    std.log.info("info", .{});
    std.log.debug("debug", .{});

    gWindowManager = try WindowManager.init(&gpa.allocator);
    defer gWindowManager.deinit();

    try gWindowManager.setup();

    if (SetConsoleCtrlHandler(ConsoleCtrlHandler, 1) == 0) {
        std.log.err("Failed to install console ctrl handle: {}", .{GetLastError()});
    }

    var msg: MSG = undefined;
    while (GetMessageA(&msg, null, 0, 0) > 0) {
        if (msg.message == WM_HOTKEY) {
            gWindowManager.handleHotkey(msg.wParam);
        } else {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageA(&msg);
        }
    }
}

fn ConsoleCtrlHandler(CtrlType: u32) callconv(@import("std").os.windows.WINAPI) BOOL {
    std.log.debug("ConsoleCtrlHandler: {}", .{CtrlType});

    gWindowManager.writeWindowInfosToFile() catch |err| {
        std.log.err("Failed to save window data in file: {}", .{err});
    };

    // @todo: handle thread synchronization.
    std.log.info("Make all managed windows visible again.", .{});
    for (gWindowManager.monitors.items) |*monitor| {
        for (monitor.layers.items) |*layer| {
            for (layer.windows.items) |*window| {
                _ = ShowWindow(window.hwnd, SW_SHOW);
            }
        }
    }
    return 0;
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = switch (message_level) {
        .emerg => "emrg",
        .alert => "alrt",
        .crit => "crit",
        .err => "errr",
        .warn => "warn",
        .notice => "notc",
        .info => "info",
        .debug => "debg",
    };
    const color = switch (message_level) {
        .emerg => "41m",
        .alert => "41m",
        .crit => "41m",
        .err => "31m",
        .warn => "33m",
        .notice => "36m",
        .info => "37m",
        .debug => "32m",
    };

    const prefix2 = if (scope == .default) "" else ":" ++ @tagName(scope);
    const stderr = std.io.getStdErr().writer();
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();

    {
        defer vtCsi(stderr, "0m");

        vtCsi(stderr, "0m");
        nosuspend stderr.print("[{}] ", .{GetCurrentThreadId()}) catch {};

        vtCsi(stderr, "1m");
        nosuspend stderr.print("[" ++ level_txt ++ prefix2 ++ "] ", .{}) catch {};

        vtCsi(stderr, color);
        nosuspend stderr.print(format, args) catch {};
    }
    nosuspend stderr.writeAll("\n") catch {};
}

fn enableVTMode() !void {
    // Set output mode to handle virtual terminal sequences
    const hOut = GetStdHandle(STD_ERROR_HANDLE);
    if (hOut == INVALID_HANDLE_VALUE) {
        return error.InvalidStdoutHandle;
    }

    var dwMode: CONSOLE_MODE = undefined;
    if (GetConsoleMode(hOut, &dwMode) == 0) {
        return error.FailedToGetConsoleMode;
    }

    dwMode = @intToEnum(CONSOLE_MODE, @enumToInt(dwMode) | @enumToInt(ENABLE_VIRTUAL_TERMINAL_PROCESSING));
    if (SetConsoleMode(hOut, dwMode) == 0) {
        return error.FailedToSetConsoleMode;
    }
}

fn vtEsc(writer: anytype, arg: anytype) void {
    writer.writeByte(0x1b) catch {};
    switch (@typeInfo(@TypeOf(arg))) {
        .Int => writer.writeByte(@intCast(u8, arg)) catch {},
        .ComptimeInt => writer.writeByte(@intCast(u8, arg)) catch {},
        else => writer.writeAll(arg) catch {},
    }
}

fn vtCsi(writer: anytype, arg: anytype) void {
    writer.writeByte(0x1b) catch {};
    writer.writeByte('[') catch {};
    switch (@typeInfo(@TypeOf(arg))) {
        .Int => writer.writeByte(@intCast(u8, arg)) catch {},
        .ComptimeInt => writer.writeByte(@intCast(u8, arg)) catch {},
        else => writer.writeAll(arg) catch {},
    }
}
