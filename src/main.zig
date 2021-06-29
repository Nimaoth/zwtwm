const std = @import("std");

usingnamespace @import("zigwin32").everything;

var ignoredClassNames: std.StringHashMap(bool) = undefined;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var windowStringArena: *std.mem.Allocator = undefined;

var allWindows: std.ArrayList(Window) = undefined;

const Window = struct {
    const Self = @This();

    hwnd: HWND,
    className: String,
    title: String,
    rect: RECT,

    fn deinit(self: *Self) void {
        self.className.deinit();
        self.title.deinit();
    }
};

const String = struct {
    value: []const u8,
    allocator: *std.mem.Allocator,

    pub fn deinit(self: @This()) void {
        defer self.allocator.free(self.value);
    }
};

const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @intCast(u32, r) | (@intCast(u32, g) << 8) | (@intCast(u32, b) << 16);
}

const HK_CLOSE_WINDOW: i32 = 1;
const HK_LAYOUT_WINDOWS: i32 = 2;
const HK_GAP_INC: i32 = 3;
const HK_GAP_DEC: i32 = 4;
const HK_SPLIT_INC: i32 = 5;
const HK_SPLIT_DEC: i32 = 6;

var gap: i32 = 5;
var splitRatio: f64 = 0.66;

var overlayWindow: HWND = undefined;

pub fn main() anyerror!void {
    try enableVTMode();

    defer {
        _ = gpa.deinit();
    }
    var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer arena.deinit();
    windowStringArena = &arena.allocator;

    allWindows = std.ArrayList(Window).init(&gpa.allocator);
    defer allWindows.deinit();

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
        updateWindowInfos();

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
                    updateWindowInfos();
                    layoutWindows() catch unreachable;
                },
                HK_GAP_INC => {
                    gap += 5;
                    std.log.info("Inc gap: {}", .{gap});
                    updateWindowInfos();
                    layoutWindows() catch unreachable;
                },
                HK_GAP_DEC => {
                    gap -= 5;
                    if (gap < 0) {
                        gap = 0;
                    }
                    std.log.info("Dec gap: {}", .{gap});
                    updateWindowInfos();
                    layoutWindows() catch unreachable;
                },
                HK_SPLIT_INC => {
                    splitRatio += 0.025;
                    if (splitRatio > 0.9) {
                        splitRatio = 0.9;
                    }
                    std.log.info("Inc split: {}", .{splitRatio});
                    updateWindowInfos();
                    layoutWindows() catch unreachable;
                },
                HK_SPLIT_DEC => {
                    splitRatio -= 0.025;
                    if (splitRatio < 0.1) {
                        splitRatio = 0.1;
                    }
                    std.log.info("Dec split: {}", .{splitRatio});
                    updateWindowInfos();
                    layoutWindows() catch unreachable;
                },

                else => std.log.err("Received unknown hotkey {}", .{wParam}),
            }
        },

        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            var hdc = BeginPaint(hwnd, &ps);
            defer _ = EndPaint(hwnd, &ps);

            var brush = CreateSolidBrush(rgb(200, 50, 25));
            defer _ = DeleteObject(brush);
            var backgroundBrush = CreateSolidBrush(0);
            defer _ = DeleteObject(backgroundBrush);

            const rect = RECT{
                .left = ps.rcPaint.left + gap,
                .right = ps.rcPaint.right - gap,
                .top = ps.rcPaint.top + gap,
                .bottom = ps.rcPaint.bottom - gap,
            };
            _ = FillRect(hdc, &ps.rcPaint, backgroundBrush);
            _ = FrameRect(hdc, &rect, brush);
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
            10,
            LAYERED_WINDOW_ATTRIBUTES_FLAGS.initFlags(.{
                .ALPHA = 0,
                .COLORKEY = 1,
            }),
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
                .CONTROL = 1,
                .ALT = 1,
                .SHIFT = 1,
                .NOREPEAT = 1,
            }),
            @intCast(i32, 'R'),
        ) == 0) {
            return error.FailedToRegisterHotkey;
        }

        if (RegisterHotKey(
            window,
            HK_GAP_INC,
            HOT_KEY_MODIFIERS.initFlags(.{
                .CONTROL = 1,
                .ALT = 1,
                .SHIFT = 1,
                .NOREPEAT = 1,
            }),
            @intCast(i32, 'H'),
        ) == 0) {
            return error.FailedToRegisterHotkey;
        }

        if (RegisterHotKey(
            window,
            HK_GAP_DEC,
            HOT_KEY_MODIFIERS.initFlags(.{
                .CONTROL = 1,
                .ALT = 1,
                .SHIFT = 1,
                .NOREPEAT = 1,
            }),
            @intCast(i32, 'F'),
        ) == 0) {
            return error.FailedToRegisterHotkey;
        }

        if (RegisterHotKey(
            window,
            HK_SPLIT_DEC,
            HOT_KEY_MODIFIERS.initFlags(.{
                .CONTROL = 1,
                .ALT = 1,
                .SHIFT = 1,
                .NOREPEAT = 1,
            }),
            @intCast(i32, 'N'),
        ) == 0) {
            return error.FailedToRegisterHotkey;
        }

        if (RegisterHotKey(
            window,
            HK_SPLIT_INC,
            HOT_KEY_MODIFIERS.initFlags(.{
                .CONTROL = 1,
                .ALT = 1,
                .SHIFT = 1,
                .NOREPEAT = 1,
            }),
            @intCast(i32, 'T'),
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

fn updateWindowInfos() void {
    for (allWindows.items) |*window| {
        window.deinit();
    }
    allWindows.resize(0) catch unreachable;

    _ = EnumWindows(HandleEnumWindows, 0);

    for (allWindows.items) |*window| {
        vtCsi("1m");
        std.debug.print("{s}: ", .{window.className.value});
        std.debug.print("{s}", .{window.title.value});
        vtCsi("0m");
        std.debug.print("   -   {}\n", .{window.rect});
    }
}

fn layoutWindows() !void {
    const monitor = try getMonitorRect();

    var workingArea = Rect{
        .x = monitor.x + gap,
        .y = monitor.y + gap,
        .width = monitor.width - gap * 2,
        .height = monitor.height - gap * 2,
    };

    const numWindows: i32 = @intCast(i32, allWindows.items.len);
    const windowWidth = @divTrunc(workingArea.width - (numWindows - 1) * gap, numWindows);
    const windowHeight = workingArea.height;

    var hdwp = BeginDeferWindowPos(@intCast(i32, numWindows));
    if (hdwp == 0) {
        return error.OutOfMemory;
    }

    var x: i32 = workingArea.x;
    for (allWindows.items) |*window, i| {
        var area = workingArea;
        if (i + 1 < allWindows.items.len) {
            // More windows after this one.
            if (@mod(i, 2) == 0) {
                const ratio = if (i == 0) splitRatio else 0.5;
                const split = @floatToInt(i32, @intToFloat(f64, area.width) * ratio);

                workingArea.x += split + gap;
                workingArea.width -= split + gap;
                area.width = split;
            } else {
                const ratio = if (i == 0) splitRatio else 0.5;
                const split = @floatToInt(i32, @intToFloat(f64, area.height) * ratio);

                workingArea.y += split + gap;
                workingArea.height -= split + gap;
                area.height = split;
            }
        }

        std.debug.print("{}, {}, {}, {}\n", .{
            area.x,
            area.y,
            area.width,
            area.height,
        });

        hdwp = DeferWindowPos(
            hdwp,
            window.hwnd,
            null,
            area.x,
            area.y,
            area.width,
            area.height,
            SET_WINDOW_POS_FLAGS.initFlags(.{
                .NOOWNERZORDER = 1,
                .NOZORDER = 1,
                .SHOWWINDOW = 1,
            }),
        );

        if (hdwp == 0) {
            return error.OutOfMemory;
        }
    }

    if (EndDeferWindowPos(hdwp) == 0) {
        return error.FailedToPositionWindows;
    }
}

fn HandleEnumWindows(
    hwnd: HWND,
    param: LPARAM,
) callconv(@import("std").os.windows.WINAPI) BOOL {
    const className = getWindowString(hwnd, GetClassNameA, .{}) catch return 1;
    if (ignoredClassNames.get(className.value)) |_| {
        return 1;
    }

    if (!std.mem.eql(u8, className.value, "CabinetWClass")) {
        return 1;
    }

    if (!isWindowManageable(hwnd)) {
        return 1;
    }

    const windowTitle = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA) catch return 1;

    var rect: RECT = undefined;
    if (GetWindowRect(hwnd, &rect) == 0) {
        return 1;
    }

    allWindows.append(.{
        .hwnd = hwnd,
        .className = className,
        .title = windowTitle,
        .rect = rect,
    }) catch unreachable;

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

fn getMonitorRect() !Rect {
    var rect: RECT = undefined;
    if (SystemParametersInfoA(
        .GETWORKAREA,
        0,
        @ptrCast(*c_void, &rect),
        SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS.initFlags(.{}),
    ) == 0) {
        return error.SystemParametersInfo;
    }
    return Rect{
        .x = rect.left,
        .y = rect.top,
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    };
    //return .{
    //    .x = 0,
    //    .y = 0,
    //    .width = GetSystemMetrics(SM_CXSCREEN),
    //    .height = GetSystemMetrics(SM_CYSCREEN),
    //};
}
