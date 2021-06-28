const std = @import("std");

usingnamespace @import("zigwin32").everything;

var ignoredClassNames: std.StringHashMap(bool) = undefined;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var windowStringArena: *std.mem.Allocator = undefined;

const String = struct {
    value: []const u8,
    allocator: *std.mem.Allocator,

    pub fn deinit(self: @This()) void {
        defer self.allocator.free(self.value);
    }
};

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @intCast(u32, r) | (@intCast(u32, g) << 8) | (@intCast(u32, b) << 16);
}

const HK_CLOSE_WINDOW: i32 = 1;
const HK_LAYOUT_WINDOWS: i32 = 2;

var overlayWindow: HWND = undefined;

pub fn main() anyerror!void {
    try enableVTMode();

    defer {
        _ = gpa.deinit();
    }
    var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer arena.deinit();
    windowStringArena = &arena.allocator;

    ignoredClassNames = std.StringHashMap(bool).init(&gpa.allocator);
    defer ignoredClassNames.deinit();
    try ignoredClassNames.put("IME", true);
    try ignoredClassNames.put("MSCTFIME UI", true);
    try ignoredClassNames.put("WorkerW", true);
    try ignoredClassNames.put("vguiPopupWindow", true);
    try ignoredClassNames.put("tooltips_class32", true);
    try ignoredClassNames.put("ForegroundStaging", true);

    const instance = GetModuleHandleA(null);

    overlayWindow = try createOverlayWindow(instance);

    var msg: MSG = undefined;
    while (GetMessageA(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageA(&msg);
    }

    var stdOut = std.io.getStdOut().writer();

    //vtCsi("?1049h"); // use alternate screen buffer
    //defer vtCsi("?1049l"); // use main screen buffer

    while (false) {
        vtEsc("7"); // store current cursor position
        if (EnumWindows(HandleEnumWindows, 0) == 0) {
            return;
        }

        std.time.sleep(std.time.ns_per_ms * 250);
        vtEsc("8"); // restore cursor position
        vtCsi("0J"); // clear screen (from cursor to end)
    }
}

fn WndProc(
    hwnd: HWND,
    msg: u32,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(@import("std").os.windows.WINAPI) LRESULT {
    //std.debug.print("WndProc({}, {}, {})\n", .{ msg, wParam, lParam });

    switch (msg) {
        WM_CREATE => {},
        WM_CLOSE => {},
        WM_DESTROY => PostQuitMessage(0),
        WM_HOTKEY => {
            //std.debug.print("Received hotkey. w={}, l={}\n", .{ wParam, lParam });
            switch (wParam) {
                HK_CLOSE_WINDOW => PostQuitMessage(0),
                HK_LAYOUT_WINDOWS => {
                    std.log.info("Layout windows", .{});
                    _ = EnumWindows(HandleEnumWindows, 0);
                },

                else => std.log.err("Received unknown hotkey {}", .{wParam}),
            }
        },
        else => return DefWindowProcA(hwnd, msg, wParam, lParam),
    }

    return 0;
}

fn createOverlayWindow(hInstance: HINSTANCE) !HWND {
    const WINDOW_NAME = "zwtwm";

    const winClass = WNDCLASSEXA{
        .cbSize = @intCast(u32, @sizeOf(WNDCLASSEXA)),
        .style = WNDCLASS_STYLES.initFlags(.{}),
        .lpfnWndProc = WndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_NAME,
        .hIconSm = null,
    };

    if (RegisterClassExA(&winClass) == 0) {
        return error.FailedToRegisterWindowClass;
    }

    const hwnd = CreateWindowExA(
        WINDOW_EX_STYLE.initFlags(.{
            .LAYERED = 1,
            .TRANSPARENT = 1,
            .COMPOSITED = 1,
            .NOACTIVATE = 0,
            .TOPMOST = 1,
        }),
        WINDOW_NAME,
        WINDOW_NAME,
        WINDOW_STYLE.initFlags(.{
            .VISIBLE = 1,
            .MAXIMIZE = 1,
        }),
        100, // x
        100, // y
        200, // width
        200, // height
        null,
        null,
        hInstance,
        null,
    );

    if (hwnd) |window| {
        // Make window transparent.
        if (SetLayeredWindowAttributes(
            window,
            0,
            150,
            LAYERED_WINDOW_ATTRIBUTES_FLAGS.initFlags(.{ .ALPHA = 1 }),
        ) == 0) {
            return error.FailedToSetWindowOpacity;
        }

        // Register hotkey to close window. (win+escape)
        if (RegisterHotKey(
            window,
            HK_CLOSE_WINDOW,
            HOT_KEY_MODIFIERS.initFlags(.{
                .WIN = 1,
                .NOREPEAT = 1,
            }),
            VK_ESCAPE,
        ) == 0) {
            return error.FailedToRegisterHotkey;
        }

        // Layout windows
        if (RegisterHotKey(
            window,
            HK_LAYOUT_WINDOWS,
            HOT_KEY_MODIFIERS.initFlags(.{
                .WIN = 1,
                .SHIFT = 1,
                .NOREPEAT = 1,
            }),
            @intCast(i32, 'N'),
        ) == 0) {
            return error.FailedToRegisterHotkey;
        }

        // Remove title bar and other styles.
        if (SetWindowLongPtrA(window, GWL_STYLE, 0) == 0) {
            return error.FailedToSetWindowLongPtr;
        }

        const x = 0;
        const y = 0;
        const width = GetSystemMetrics(SM_CXSCREEN);
        const height = GetSystemMetrics(SM_CYSCREEN);

        if (SetWindowPos(window, null, x, y, width, height, //
            SET_WINDOW_POS_FLAGS.initFlags(.{
            .NOACTIVATE = 1,
        })) == 0) {
            return error.FailedToSetWindowPosition;
        }

        _ = ShowWindow(window, SW_SHOW);
    }
    return hwnd orelse error.FailedToCreateOverlayWindow;
}

fn getWindowString(hwnd: HWND, comptime func: anytype, comptime lengthFunc: anytype) !String {
    var size: usize = 256;

    if (@typeInfo(@TypeOf(lengthFunc)) == .Fn) {
        size = @intCast(usize, lengthFunc(hwnd)) + 1;
    }

    while (true) {
        var buffer: []u8 = try windowStringArena.alloc(u8, size);
        const len = @intCast(u64, func(hwnd, @ptrCast([*:0]u8, buffer.ptr), @intCast(i32, buffer.len)));
        if (len == 0) {
            return error.FailedToGetWindowString;
        }

        if (len >= size - 1) {
            windowStringArena.free(buffer);
            size *= 2;
            continue;
        }

        const str = buffer[0..len];
        return String{ .value = str, .allocator = windowStringArena };
    }
}

fn HandleEnumWindows(
    hwnd: HWND,
    param: LPARAM,
) callconv(@import("std").os.windows.WINAPI) BOOL {
    const className = getWindowString(hwnd, GetClassNameA, .{}) catch return 1;
    defer className.deinit();
    if (ignoredClassNames.get(className.value)) |_| {
        return 1;
    }

    if (!isWindowManageable(hwnd)) {
        return 1;
    }

    const windowTitle = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA) catch return 1;
    defer windowTitle.deinit();

    var rect: RECT = undefined;
    if (GetWindowRect(hwnd, &rect) == 0) {
        return 1;
    }

    vtCsi("1m");
    std.debug.print("{s}", .{windowTitle.value});
    vtCsi("0m");
    std.debug.print("   -   {}\n", .{rect});

    //
    return 1;
}

fn isWindowManageable(hwnd: HWND) bool {
    if (hwnd == overlayWindow)
        return false;

    const parent = GetParent(hwnd);
    const owner = GetWindow(hwnd, GW_OWNER);
    const style = GetWindowLongA(hwnd, GWL_STYLE);
    const exstyle = GetWindowLongA(hwnd, GWL_EXSTYLE);
    const pok = (parent != null and isWindowManageable(parent.?));
    const istool = (exstyle & @intCast(i32, @enumToInt(WS_EX_TOOLWINDOW))) != 0;
    const isapp = (exstyle & @intCast(i32, @enumToInt(WS_EX_APPWINDOW))) != 0;

    if (false) {
        const className = getWindowString(hwnd, GetClassNameA, .{}) catch return false;
        defer className.deinit();

        std.log.info(
            \\isManageable({}) class name = {s}
            \\parent:  {}
            \\owner:   {}
            \\style:   {}
            \\exstyle: {}
            \\pok:     {}
            \\istool:  {}
            \\isapp:   {}
        , .{ hwnd, className.value, parent, owner, style, exstyle, pok, istool, isapp });
    }

    if (style & @intCast(i32, @enumToInt(WS_DISABLED)) != 0) {
        return false;
    }

    if ((parent == null and IsWindowVisible(hwnd) != 0) or pok) {
        if ((!istool and parent == null) or (istool and pok)) {
            return true;
        }
        if (isapp and parent != null) {
            return true;
        }
    }

    return false;
}

fn enableVTMode() !void {
    // Set output mode to handle virtual terminal sequences
    const hOut = GetStdHandle(STD_OUTPUT_HANDLE);
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

fn vtEsc(arg: anytype) void {
    var writer = std.io.getStdOut().writer();
    writer.writeByte(0x1b) catch {};
    switch (@typeInfo(@TypeOf(arg))) {
        .Int => writer.writeByte(@intCast(u8, arg)) catch {},
        .ComptimeInt => writer.writeByte(@intCast(u8, arg)) catch {},
        else => writer.writeAll(arg) catch {},
    }
}

fn vtCsi(arg: anytype) void {
    var writer = std.io.getStdOut().writer();
    writer.writeByte(0x1b) catch {};
    writer.writeByte('[') catch {};
    switch (@typeInfo(@TypeOf(arg))) {
        .Int => writer.writeByte(@intCast(u8, arg)) catch {},
        .ComptimeInt => writer.writeByte(@intCast(u8, arg)) catch {},
        else => writer.writeAll(arg) catch {},
    }
}
