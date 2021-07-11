const std = @import("std");
const root = @import("root");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");
usingnamespace @import("layer.zig");
usingnamespace @import("monitor.zig");

const CWM_WINDOW_CREATED = WM_USER + 1;
const HK_CLOSE_WINDOW: i32 = 42069;

const Hotkey = struct {
    key: u32,
    mods: HOT_KEY_MODIFIERS,
    func: fn (*WindowManager, HotkeyArgs) void,
    args: HotkeyArgs = .{},
};

const Command = enum {
    None,
    ToggleWindowOnLayer,
    MoveWindowToLayer,
};

pub const WindowManager = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,

    monitors: std.ArrayList(Monitor),
    currentMonitor: usize = 0,

    hotkeys: std.ArrayList(Hotkey),
    currentCommand: Command = .None,
    nextCommand: Command = .None,

    hHookObjectCreate: HWINEVENTHOOK,
    hHookObjectHide: HWINEVENTHOOK,
    hHookObjectFocus: HWINEVENTHOOK,
    hHookObjectMoved: HWINEVENTHOOK,

    // Settings
    ignoredClassNames: std.StringHashMap(bool),
    options: Options = .{
        .gap = 5,
        .splitRatio = 0.5,
    },

    pub fn init(allocator: *std.mem.Allocator) !Self {
        const hInstance = GetModuleHandleA(null);
        const winClass = WNDCLASSEXA{
            .cbSize = @intCast(u32, @sizeOf(WNDCLASSEXA)),
            .style = WNDCLASS_STYLES.initFlags(.{}),
            .lpfnWndProc = Self.WndProc,
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

        var hHookObjectCreate = SetWinEventHook(
            EVENT_OBJECT_SHOW,
            EVENT_OBJECT_SHOW,
            null,
            WindowManager.handleWindowEventCallback,
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
        ) orelse return error.FailedToCreateWinEventHook;

        var hHookObjectHide = SetWinEventHook(
            EVENT_OBJECT_DESTROY,
            EVENT_OBJECT_DESTROY,
            null,
            WindowManager.handleWindowEventCallback,
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
        ) orelse return error.FailedToCreateWinEventHook;

        var hHookObjectFocus = SetWinEventHook(
            EVENT_SYSTEM_FOREGROUND,
            EVENT_SYSTEM_FOREGROUND,
            null,
            WindowManager.handleWindowEventCallback,
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
        ) orelse return error.FailedToCreateWinEventHook;

        var hHookObjectMoved = SetWinEventHook(
            EVENT_SYSTEM_MOVESIZESTART,
            EVENT_SYSTEM_MOVESIZEEND,
            null,
            WindowManager.handleWindowEventCallback,
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
        ) orelse return error.FailedToCreateWinEventHook;

        return Self{
            .allocator = allocator,
            .monitors = std.ArrayList(Monitor).init(allocator),
            .hotkeys = std.ArrayList(Hotkey).init(allocator),
            .ignoredClassNames = std.StringHashMap(bool).init(allocator),

            .hHookObjectCreate = hHookObjectCreate,
            .hHookObjectHide = hHookObjectHide,
            .hHookObjectFocus = hHookObjectFocus,
            .hHookObjectMoved = hHookObjectMoved,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = UnhookWinEvent(self.hHookObjectCreate);
        _ = UnhookWinEvent(self.hHookObjectHide);
        _ = UnhookWinEvent(self.hHookObjectFocus);
        _ = UnhookWinEvent(self.hHookObjectMoved);

        for (self.monitors.items) |*monitor| {
            monitor.deinit();
        }
        self.monitors.deinit();
        self.hotkeys.deinit();
        self.ignoredClassNames.deinit();
    }

    pub fn setup(self: *Self) !void {
        try self.ignoredClassNames.put("IME", true);
        try self.ignoredClassNames.put("MSCTFIME UI", true);
        try self.ignoredClassNames.put("WorkerW", true);
        try self.ignoredClassNames.put("vguiPopupWindow", true);
        try self.ignoredClassNames.put("tooltips_class32", true);
        try self.ignoredClassNames.put("ForegroundStaging", true);

        // Register hotkey to close window. (win+escape)
        if (RegisterHotKey(
            null, // @todo
            HK_CLOSE_WINDOW,
            HOT_KEY_MODIFIERS.initFlags(.{
                .WIN = 1,
                .NOREPEAT = 1,
            }),
            VK_ESCAPE,
        ) == 0) {
            return error.FailedToRegisterHotkey;
        }

        try self.updateMonitorInfos();

        // Initial update + layout.
        self.updateWindowInfos();
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();

        const defaultHotkeys = [_]Hotkey{
            .{
                .key = @intCast(u32, 'K'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.decreaseGap,
            },
            .{
                .key = @intCast(u32, 'Q'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.increaseGap,
            },

            .{
                .key = @intCast(u32, 'H'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.decreaseSplit,
            },
            .{
                .key = @intCast(u32, 'F'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.increaseSplit,
            },

            .{
                .key = @intCast(u32, 'N'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.selectPrevWindow,
            },
            .{
                .key = @intCast(u32, 'T'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.selectNextWindow,
            },

            .{
                .key = @intCast(u32, 'W'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.toggleForegroundWindowManaged,
            },
            .{
                .key = @intCast(u32, 'C'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.moveCurrentWindowToTop,
            },
            .{
                .key = @intCast(u32, 'L'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.moveNextWindowToLayer,
            },
            .{
                .key = @intCast(u32, 'V'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.toggleNextWindowOnLayer,
            },
            .{
                .key = @intCast(u32, 'X'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.toggleWindowFullscreen,
            },
            .{
                .key = @intCast(u32, 'U'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.moveWindowToNextMonitor,
            },
            .{
                .key = @intCast(u32, 'I'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.goToNextMonitor,
            },

            .{
                .key = @intCast(u32, 'G'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.printForegroundWindowInfo,
            },

            //.{
            //    .key = @intCast(u32, 'S'),
            //    .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            //    .func = WindowManager.moveWindowToNextMonitor,
            //},

            //.{
            //    .key = @intCast(u32, 'Y'),
            //    .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            //    .func = WindowManager.goToNextMonitor,
            //},
        };

        for (defaultHotkeys[0..]) |hotkey| {
            try self.registerHotkey(hotkey);
        }

        var i: u32 = 0;
        while (i < 9) : (i += 1) {
            // Switch layer.
            try self.registerHotkey(.{
                .key = @intCast(u32, '1') + i,
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .NOREPEAT = 1 }),
                .func = WindowManager.layerCommand,
                .args = .{ .usizeParam = @intCast(usize, i) },
            });
        }
    }

    pub fn registerHotkey(self: *Self, hotkey: Hotkey) !void {
        if (RegisterHotKey(
            null,
            @intCast(i32, self.hotkeys.items.len),
            hotkey.mods,
            hotkey.key,
        ) == 0) {
            std.log.err("Failed to register hotkey {} '{c}' ({})", .{ hotkey.key, @intCast(u8, hotkey.key), hotkey.mods });
            return;
        }

        try self.hotkeys.append(hotkey);
    }

    pub fn handleHotkey(self: *Self, wParam: WPARAM) void {
        switch (wParam) {
            HK_CLOSE_WINDOW => PostQuitMessage(0),
            else => self.runHotkey(@intCast(usize, wParam)),
        }

        const hdc = GetDC(null);
        defer _ = ReleaseDC(null, hdc);

        for (self.monitors.items) |*monitor| {
            var clientRect: RECT = undefined;
            _ = GetClientRect(monitor.overlayWindow, &clientRect);
            monitor.renderOverlay(hdc, clientRect, monitor == self.getCurrentMonitor(), false);
        }
    }

    pub fn runHotkey(self: *Self, index: usize) void {
        if (index >= self.hotkeys.items.len) {
            std.log.err("Failed to run hotkey {}: No such hotkey.", .{index});
            return;
        }

        self.currentCommand = self.nextCommand;
        self.nextCommand = .None;
        self.hotkeys.items[index].func(self, self.hotkeys.items[index].args);
        if (self.currentCommand == self.nextCommand and self.currentCommand != .None) {
            std.log.info("Cancel next command: {}", .{self.nextCommand});
            self.nextCommand = .None;
        }
        self.currentCommand = .None;
    }

    fn handleWindowEvent(self: *WindowManager, event: u32, hwnd: HWND) void {
        const className = getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena) catch unreachable;
        defer className.deinit();
        const windowTitle = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, root.gWindowStringArena) catch unreachable;
        defer windowTitle.deinit();

        switch (event) {
            EVENT_OBJECT_SHOW => {
                if (!self.isWindowManageable(hwnd)) {
                    return;
                }

                if (!self.isWindowManaged(hwnd)) {
                    const monitor = self.manageWindow(hwnd, true) catch {
                        std.log.err("Failed to manage window {}:{s}: '{s}'", .{ hwnd, className.value, windowTitle.value });
                        return;
                    };
                    monitor.currentWindow = 0;
                    monitor.layoutWindows();
                    self.rerenderOverlay();
                }
            },

            EVENT_OBJECT_DESTROY => {
                if (self.isWindowManaged(hwnd)) {
                    self.removeManagedWindow(hwnd);
                    self.focusCurrentWindow();
                    self.layoutWindowsOnAllMonitors();
                    self.rerenderOverlay();
                }
            },

            EVENT_SYSTEM_FOREGROUND => {
                if (self.isWindowManaged(hwnd)) {
                    self.setCurrentWindow(hwnd);
                    self.layoutWindows();
                }
                self.rerenderOverlay();
            },

            EVENT_SYSTEM_MOVESIZESTART => {
                if (self.isWindowManaged(hwnd)) {
                    var rect: RECT = undefined;
                    if (self.getWindow(hwnd)) |window| {
                        _ = GetWindowRect(hwnd, &rect);
                        window.rect = Rect.fromRECT(rect);
                        self.rerenderOverlay();
                    }
                }
            },
            EVENT_SYSTEM_MOVESIZEEND => {
                if (self.isWindowManaged(hwnd)) {
                    self.removeManagedWindow(hwnd);
                    self.layoutWindows();
                    self.rerenderOverlay();
                }
            },

            else => unreachable,
        }
    }

    fn handleWindowEventCallback(
        hWinEventHook: HWINEVENTHOOK,
        event: u32,
        hwnd: HWND,
        idObject: i32,
        idChild: i32,
        idEventThread: u32,
        dwmsEventTime: u32,
    ) callconv(@import("std").os.windows.WINAPI) void {
        if (idObject != 0) return;

        root.gWindowManager.handleWindowEvent(event, hwnd);
        //_ = PostMessageA(root.gWindowManager.overlayWindow, CWM_WINDOW_CREATED, @ptrToInt(hwnd), @intCast(isize, event));
    }

    pub fn WndProc(
        hwnd: HWND,
        msg: u32,
        wParam: WPARAM,
        lParam: LPARAM,
    ) callconv(@import("std").os.windows.WINAPI) LRESULT {
        switch (msg) {
            WM_CREATE => {},
            WM_CLOSE => {},
            WM_DESTROY => PostQuitMessage(0),

            WM_DISPLAYCHANGE => {
                var self = @intToPtr(*WindowManager, @bitCast(usize, GetWindowLongPtrA(hwnd, GWLP_USERDATA)));
                std.log.debug("Display info changed: {}, {}, {any}", .{ wParam, lParam, @bitCast([4]u16, lParam) });
                self.updateMonitorInfos() catch {
                    std.log.err("Failed to update monitor infos.", .{});
                };
                self.layoutWindowsOnAllMonitors();
                self.rerenderOverlay();
            },

            WM_HOTKEY => {
                var self = @intToPtr(*WindowManager, @bitCast(usize, GetWindowLongPtrA(hwnd, GWLP_USERDATA)));
            },

            WM_PAINT => {
                var self = @intToPtr(*WindowManager, @bitCast(usize, GetWindowLongPtrA(hwnd, GWLP_USERDATA)));

                var ps: PAINTSTRUCT = undefined;
                var hdc = BeginPaint(hwnd, &ps);
                defer _ = EndPaint(hwnd, &ps);
                const monitor = self.getMonitorFromOverlayWindow(hwnd);
                self.clearBackground(hdc, ps.rcPaint);
                monitor.renderOverlay(hdc, ps.rcPaint, monitor == self.getCurrentMonitor(), true);
            },

            CWM_WINDOW_CREATED => {
                var self = @intToPtr(*WindowManager, @bitCast(usize, GetWindowLongPtrA(hwnd, GWLP_USERDATA)));
                const window = @intToPtr(HWND, wParam);
                const event = @intCast(u32, lParam);
                self.handleWindowEvent(event, window);
            },

            else => return DefWindowProcA(hwnd, msg, wParam, lParam),
        }

        return 0;
    }

    fn clearBackground(self: *Self, hdc: HDC, region: RECT) void {
        //var backgroundBrush = CreateSolidBrush(rgb(255, 0, 255));
        var backgroundBrush = CreateSolidBrush(0);
        defer _ = DeleteObject(backgroundBrush);
        _ = FillRect(hdc, &region, backgroundBrush);
    }

    fn updateWindowInfos(self: *Self) void {
        _ = EnumWindows(Self.handleEnumWindows, @bitCast(isize, @ptrToInt(self)));

        if (root.LOG_LAYERS) {
            for (self.monitors.items) |*monitor, k| {
                std.debug.print("Monitor {}\n", .{k});
                for (monitor.layers.items) |*layer, i| {
                    if (layer.isEmpty()) continue;

                    std.debug.print("  Layer {}\n", .{i});
                    for (layer.windows.items) |*window| {
                        std.debug.print("  {s}: ", .{window.className.value});
                        std.debug.print("{s}", .{window.title.value});
                        std.debug.print("   -   {}\n", .{window.rect});
                    }
                }
            }
        }
    }

    fn handleEnumWindows(
        hwnd: HWND,
        param: LPARAM,
    ) callconv(@import("std").os.windows.WINAPI) BOOL {
        var self = @intToPtr(*WindowManager, @bitCast(usize, param));

        const className = getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena) catch return 1;
        defer className.deinit();
        if (self.ignoredClassNames.get(className.value)) |_| {
            return 1;
        }

        if (!self.isWindowManageable(hwnd)) {
            return 1;
        }

        const windowTitle = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, root.gWindowStringArena) catch return 1;
        defer windowTitle.deinit();

        var rect: RECT = undefined;
        if (GetWindowRect(hwnd, &rect) == 0) {
            return 1;
        }

        _ = self.manageWindow(hwnd, false) catch {
            std.log.err("Failed to manage window {}:{s}: '{s}'", .{ hwnd, className.value, windowTitle.value });
        };

        return 1;
    }

    const MonitorInfo = struct {
        hmonitor: HMONITOR,
        info: MONITORINFO,
        center: POINT,
    };

    fn updateMonitorInfos(self: *Self) !void {
        var newMonitors = std.ArrayList(MonitorInfo).init(self.allocator);
        defer newMonitors.deinit();
        _ = EnumDisplayMonitors(null, null, Self.handleEnumDisplayMonitors, @bitCast(isize, @ptrToInt(&newMonitors)));
        for (newMonitors.items) |*mon| {
            std.log.debug("Monitor: {}, {}, {}", .{ mon.hmonitor, mon.info.rcMonitor, mon.info.rcWork });
        }

        // Try to match new monitors to existing monitors and just update the existing one.
        std.log.debug("Match monitors.", .{});

        var deleteMonitorsStartingAt: ?usize = null;
        for (self.monitors.items) |*monitor, k| {
            const center = monitor.getCenter();
            var closestIndex: ?usize = null;
            var closestDistance: i32 = 0;
            std.log.debug("  [{}] {}", .{ k, center });
            for (newMonitors.items) |*new, i| {
                const newCenter = new.center;
                const distanceX = std.math.absInt(newCenter.x - center.x) catch unreachable;
                const distanceY = std.math.absInt(newCenter.y - center.y) catch unreachable;
                const distance = distanceX + distanceY;

                std.log.debug("    [{}] {} -> {}", .{ i, newCenter, distance });
                if (closestIndex == null or distance < closestDistance) {
                    closestIndex = i;
                    closestDistance = distance;
                }
            }

            if (closestIndex) |i| {
                std.log.debug("  [{}] closest is {}", .{ k, i });
                const new = newMonitors.orderedRemove(i);
                monitor.updateMonitorInfo(new.hmonitor);
            } else {
                // No closest one found, monitors have been removed.
                std.log.debug("  No closest monitor found, which means at least one monitor has been removed.", .{});

                deleteMonitorsStartingAt = k;
                break;
            }
        }

        if (deleteMonitorsStartingAt) |i| {
            std.debug.assert(newMonitors.items.len == 0);
            while (i < self.monitors.items.len) {
                std.log.debug("Remove monitor at {}", .{i});
                self.monitors.items[i].deinit();
                _ = self.monitors.swapRemove(i);
            }
        } else if (newMonitors.items.len > 0) {
            // New monitors found.
            std.log.debug("Add new monitors", .{});
            for (newMonitors.items) |*new| {
                if (new.info.rcMonitor.left == 0 and new.info.rcMonitor.top == 0) {
                    // 0, 0 is the primary monitor, insert that one at the beginning.
                    std.log.debug("Add new primary monitor {}", .{new.info.rcMonitor});
                    try self.monitors.insert(0, try Monitor.init(new.hmonitor, self));
                } else {
                    try self.monitors.append(try Monitor.init(new.hmonitor, self));
                }
            }
        }

        for (self.monitors.items) |*monitor, i| {
            std.log.debug("[{}] {}, {}", .{ i, monitor.rect, monitor.workingArea });
            _ = SetWindowLongPtrA(monitor.overlayWindow, GWLP_USERDATA, @bitCast(isize, @ptrToInt(self)));
        }
        std.log.debug("Update monitor infos done.", .{});
    }

    fn handleEnumDisplayMonitors(
        hmonitor: HMONITOR,
        hdc: HDC,
        rect: *RECT,
        param: LPARAM,
    ) callconv(@import("std").os.windows.WINAPI) BOOL {
        var monitors = @intToPtr(*std.ArrayList(MonitorInfo), @bitCast(usize, param));
        var monitorInfo: MONITORINFO = undefined;
        monitorInfo.cbSize = @sizeOf(MONITORINFO);
        if (GetMonitorInfoA(hmonitor, &monitorInfo) == 0) {
            std.log.err("Failed to get monitor info for {}", .{hmonitor});
            return 0;
        }
        monitors.append(.{
            .hmonitor = hmonitor,
            .info = monitorInfo,
            .center = .{
                .x = @divTrunc(monitorInfo.rcMonitor.left + monitorInfo.rcMonitor.right, 2),
                .y = @divTrunc(monitorInfo.rcMonitor.top + monitorInfo.rcMonitor.bottom, 2),
            },
        }) catch return 0;
        return 1;
    }

    fn isWindowObscured(self: *Self, hwnd: HWND) bool {
        const hdc = GetWindowDC(hwnd);
        defer _ = ReleaseDC(hwnd, hdc);
        var rect: RECT = undefined;
        return GetClipBox(hdc, &rect) == NULLREGION;
    }

    fn isWindowManageable(self: *Self, hwnd: HWND) bool {
        for (self.monitors.items) |*monitor| {
            if (hwnd == monitor.overlayWindow)
                return false;
        }

        const className = getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena) catch return false;
        defer className.deinit();
        if (!std.mem.eql(u8, className.value, "CabinetWClass")) {
            return false;
        }

        if (getWindowExeName(hwnd, root.gWindowStringArena) catch null) |name| {
            defer name.deinit();
            std.log.warn("Window exe name of {s}: {s}", .{ className.value, name.value });
        } else {
            //
            std.log.err("Failed to get exe name from window {}: {s}", .{ hwnd, className.value });
        }

        const parent = GetParent(hwnd);
        const owner = GetWindow(hwnd, GW_OWNER);
        const style = GetWindowLongA(hwnd, GWL_STYLE);
        const exstyle = GetWindowLongA(hwnd, GWL_EXSTYLE);
        const parentOk = (parent != null and self.isWindowManageable(parent.?));
        const istool = (exstyle & @intCast(i32, @enumToInt(WS_EX_TOOLWINDOW))) != 0;
        const isapp = (exstyle & @intCast(i32, @enumToInt(WS_EX_APPWINDOW))) != 0;

        if (false) {
            std.log.debug(
                \\isManageable({}) class name = {s}
                \\parent:  {}
                \\owner:   {}
                \\style:   {}
                \\exstyle: {}
                \\parentOk:{}
                \\istool:  {}
                \\isapp:   {}
            , .{ hwnd, className.value, parent, owner, style, exstyle, parentOk, istool, isapp });
        }

        if (style & @intCast(i32, @enumToInt(WS_DISABLED)) != 0) {
            return false;
        }
        if (IsWindowVisible(hwnd) == 0) {
            return false;
        }

        if (self.ignoredClassNames.get(className.value)) |_| {
            return false;
        }
        if ((parent == null and IsWindowVisible(hwnd) != 0) or parentOk) {
            if ((!istool and parent == null) or (istool and parentOk)) {
                return true;
            }
            if (isapp and parent != null) {
                return true;
            }
        }

        return false;
    }

    fn getWindow(self: *Self, hwnd: HWND) ?*Window {
        for (self.monitors.items) |*monitor| {
            if (monitor.getCurrentLayer().getWindow(hwnd)) |window| {
                return window;
            }
        }
        return null;
    }

    fn isWindowManaged(self: *Self, hwnd: HWND) bool {
        for (self.monitors.items) |*monitor| {
            if (monitor.isWindowManaged(hwnd)) {
                return true;
            }
        }
        return false;
    }

    fn manageWindow(self: *Self, hwnd: HWND, onTop: bool) !*Monitor {
        for (self.monitors.items) |*monitor| {
            if (monitor.isWindowManaged(hwnd)) {
                return monitor;
            }
        }

        //_ = ShowWindow(hwnd, .RESTORE);
        //_ = SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SET_WINDOW_POS_FLAGS.initFlags(.{ .NOMOVE = 1, .NOSIZE = 1 }));
        //_ = SetForegroundWindow(hwnd);
        //_ = BringWindowToTop(hwnd);

        // Try to put window on monitor with the greatest intersection area.
        const hmonitor = MonitorFromWindow(hwnd, .PRIMARY);
        for (self.monitors.items) |*monitor, i| {
            if (monitor.hmonitor == hmonitor) {
                try monitor.manageWindow(hwnd, onTop);
                self.currentMonitor = i;
                return monitor;
            }
        }

        // Otherwise put it on the current monitor.
        var monitor = self.getCurrentMonitor();
        try monitor.manageWindow(hwnd, onTop);
        return monitor;
    }

    fn removeManagedWindow(self: *Self, hwnd: HWND) void {
        for (self.monitors.items) |*monitor| {
            monitor.removeManagedWindow(hwnd);
        }
    }

    fn setCurrentWindow(self: *Self, hwnd: HWND) void {
        for (self.monitors.items) |*monitor, i| {
            if (monitor.isWindowManaged(hwnd)) {
                monitor.setCurrentWindow(hwnd);
                self.currentMonitor = i;
            }
        }
    }

    fn getMonitor(self: *Self, index: usize) *Monitor {
        std.debug.assert(index < self.monitors.items.len);
        return &self.monitors.items[index];
    }

    fn getCurrentMonitor(self: *Self) *Monitor {
        return self.getMonitor(self.currentMonitor);
    }

    fn getMonitorFromOverlayWindow(self: *Self, hwnd: HWND) *Monitor {
        for (self.monitors.items) |*monitor| {
            if (monitor.overlayWindow == hwnd)
                return monitor;
        }

        unreachable;
    }

    fn selectPrevWindow(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().selectPrevWindow(args);
    }

    fn selectNextWindow(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().selectNextWindow(args);
    }

    fn moveCurrentWindowToTop(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().moveCurrentWindowToTop(args);
    }

    fn focusCurrentWindow(self: *Self) void {
        self.getCurrentMonitor().focusCurrentWindow();
    }

    pub fn rerenderOverlay(self: *Self) void {
        for (self.monitors.items) |*monitor| {
            monitor.rerenderOverlay();
        }
    }

    fn layoutWindowsOnAllMonitors(self: *Self) void {
        for (self.monitors.items) |*monitor| {
            monitor.layoutWindows();
        }
    }

    fn layoutWindows(self: *Self) void {
        self.getCurrentMonitor().layoutWindows();
    }

    fn updateWindowVisibility(self: *Self, hwnd: HWND) void {
        self.setWindowVisibility(hwnd, self.getCurrentLayer().containsWindow(hwnd));
    }

    fn increaseGap(self: *Self, args: HotkeyArgs) void {
        self.options.gap.? += 5;
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();
    }

    fn decreaseGap(self: *Self, args: HotkeyArgs) void {
        self.options.gap.? -= 5;
        if (self.options.gap.? < 0) {
            self.options.gap.? = 0;
        }
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();
    }

    fn increaseSplit(self: *Self, args: HotkeyArgs) void {
        self.options.splitRatio.? += 0.025;
        if (self.options.splitRatio.? > 0.9) {
            self.options.splitRatio.? = 0.9;
        }
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();
    }

    fn decreaseSplit(self: *Self, args: HotkeyArgs) void {
        self.options.splitRatio.? -= 0.025;
        if (self.options.splitRatio.? < 0.1) {
            self.options.splitRatio.? = 0.1;
        }
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();
    }

    fn moveCurrentWindowToLayer(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().moveCurrentWindowToLayer(args);
    }

    fn toggleCurrentWindowOnLayer(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().toggleCurrentWindowOnLayer(args);
    }

    fn switchLayer(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().switchLayer(args);
    }

    fn layerCommand(self: *Self, args: HotkeyArgs) void {
        std.log.info("Layer command", .{});
        switch (self.currentCommand) {
            .None => self.switchLayer(args),
            .ToggleWindowOnLayer => self.toggleCurrentWindowOnLayer(args),
            .MoveWindowToLayer => self.moveCurrentWindowToLayer(args),
            //else => unreachable,
        }
    }

    fn moveNextWindowToLayer(self: *Self, args: HotkeyArgs) void {
        std.log.info("Move next window to layer", .{});
        self.nextCommand = .MoveWindowToLayer;
    }

    fn toggleNextWindowOnLayer(self: *Self, args: HotkeyArgs) void {
        std.log.info("Toggle next window on layer", .{});
        self.nextCommand = .ToggleWindowOnLayer;
    }

    fn goToNextMonitor(self: *Self, args: HotkeyArgs) void {
        if (self.monitors.items.len < 2) {
            // Only zero/one monitor, nothing to do.
            return;
        }
        self.currentMonitor = @mod(self.currentMonitor + 1, self.monitors.items.len);
        self.getCurrentMonitor().focusCurrentWindow();
        self.rerenderOverlay();
    }

    fn moveWindowToNextMonitor(self: *Self, args: HotkeyArgs) void {
        if (self.monitors.items.len < 2) {
            // Only zero/one monitor, nothing to do.
            return;
        }

        var srcMonitor = self.getCurrentMonitor();
        var srcLayer = srcMonitor.getCurrentLayer();

        self.currentMonitor = @mod(self.currentMonitor + 1, self.monitors.items.len);
        var dstMonitor = self.getCurrentMonitor();
        var dstLayer = dstMonitor.getCurrentLayer();

        if (srcLayer.getWindowAt(srcMonitor.currentWindow)) |window| {
            dstLayer.addWindow(window.hwnd, false) catch unreachable;

            // Completely remove window from source monitor
            // because having a window on two monitors doesn't make sense.
            srcMonitor.removeManagedWindow(window.hwnd);
        }

        srcMonitor.layoutWindows();
        dstMonitor.layoutWindows();
        self.rerenderOverlay();
    }

    fn toggleWindowFullscreen(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().toggleWindowFullscreen(args);
    }

    fn toggleForegroundWindowManaged(self: *Self, args: HotkeyArgs) void {
        const hwnd = GetForegroundWindow();
        if (self.isWindowManaged(hwnd)) {
            self.removeManagedWindow(hwnd);
            self.layoutWindowsOnAllMonitors();
            self.rerenderOverlay();
        } else
        //if (self.isWindowManageable(hwnd)) // @todo
        {
            const monitor = self.manageWindow(hwnd, true) catch return;
            monitor.layoutWindows();
            self.rerenderOverlay();
        }
    }

    fn printForegroundWindowInfo(self: *Self, args: HotkeyArgs) void {
        const hwnd = GetForegroundWindow();
        var className = getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena) catch return;
        defer className.deinit();

        var title = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, root.gWindowStringArena) catch return;
        defer title.deinit();

        std.log.notice("{s} ({}): '{s}'", .{ className.value, self.isWindowManageable(hwnd), title.value });

        if (getWindowExeName(hwnd, root.gWindowStringArena) catch null) |name| {
            defer name.deinit();
            std.log.notice("Window exe name of {s}: {s}", .{ className.value, name.value });
        } else {
            //
            std.log.err("Failed to get exe name from window {}: {s}", .{ hwnd, className.value });
        }
    }
};
