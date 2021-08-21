const std = @import("std");

const Guid = @import("zigwin32").zig.Guid;
usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");
usingnamespace @import("window_manager.zig");
usingnamespace @import("layer.zig");

const BuildOptions = @import("build_options");

pub const LOG_LAYERS = true;
pub const ONLY_USE_HALF_MONITOR = false;
pub const TRAY_GUID = Guid.initString(BuildOptions.TRAY_GUID);

const LOG_TO_FILE = !BuildOptions.RUN_IN_CONSOLE;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub var gWindowManager: WindowManager = undefined;
pub var gWindowStringArena: *std.mem.Allocator = undefined;

var gLogFile: ?std.fs.File = undefined;

pub const log_level: std.log.Level = switch (std.builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .debug,
    .ReleaseFast => .err,
    .ReleaseSmall => .err,
};

pub fn main() anyerror!void {
    defer _ = gpa.deinit();

    if (LOG_TO_FILE) {
        const time = @divFloor(std.time.milliTimestamp(), std.time.ms_per_s);
        var fileNameBuffer = std.ArrayList(u8).init(&gpa.allocator);
        if (std.fmt.format(fileNameBuffer.writer(), "log-{}.txt", .{time})) {
            gLogFile = try std.fs.cwd().createFile(fileNameBuffer.items, .{});
        } else |err| {
            gLogFile = try std.fs.cwd().createFile("log.txt", .{});
        }
    }
    defer if (gLogFile) |logFile| {
        logFile.close();
    };

    zwtwmMain() catch |err| {
        std.log.crit("{}", .{err});

        if (gLogFile) |logFile| {
            if (@errorReturnTrace()) |trace| {
                writeStackTraceToLogFile(logFile.writer(), trace.*);
            }
        } else {
            return err;
        }
    };
    std.log.notice("Terminating zwtwm", .{});
}

fn writeStackTraceToLogFile(writer: anytype, trace: std.builtin.StackTrace) void {
    nosuspend {
        if (!std.builtin.strip_debug_info) {
            const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                writer.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch return;
                return;
            };
            std.debug.writeStackTrace(trace, writer, &gpa.allocator, debug_info, std.debug.detectTTYConfig()) catch |err| {
                writer.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
                return;
            };
        }
    }
}
pub fn zwtwmMain() anyerror!void {
    var windowStringArena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer windowStringArena.deinit();
    gWindowStringArena = &windowStringArena.allocator;

    if (BuildOptions.RUN_IN_CONSOLE) {
        try enableVTMode();
    }

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

    if (BuildOptions.RUN_IN_CONSOLE) {
        if (SetConsoleCtrlHandler(ConsoleCtrlHandler, 1) == 0) {
            std.log.err("Failed to install console ctrl handle: {}", .{GetLastError()});
        }
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

    // @todo: handle thread synchronization.
    std.log.info("Make all managed windows visible again.", .{});
    for (gWindowManager.monitors.items) |*monitor| {
        for (monitor.layers.items) |*layer| {
            for (layer.windows.items) |*window| {
                _ = ShowWindow(window.hwnd, SW_SHOW);
            }
        }
    }

    gWindowManager.writeWindowInfosToFile() catch |err| {
        std.log.err("Failed to save window data in file: {}", .{err});
    };

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
    if (LOG_TO_FILE) {
        const out = gLogFile.?.writer();

        nosuspend out.print("[{}] [" ++ level_txt ++ prefix2 ++ "] ", .{GetCurrentThreadId()}) catch {};
        nosuspend out.print(format, args) catch {};
        nosuspend out.writeAll("\n") catch {};
    } else {
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
