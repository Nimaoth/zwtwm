const std = @import("std");
const root = @import("root");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");
usingnamespace @import("layer.zig");
usingnamespace @import("monitor.zig");

const CWM_WINDOW_CREATED = WM_USER + 1;
const HK_CLOSE_WINDOW: i32 = 42069;
const windowDataFileName = "window_data.json";

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

const WindowData = struct {
    rect: RECT,
};

// This stuff gets store in a file so that when you start
// the window server it can read some data from the previous
// run like positions of windows in the layers/stacks.
const PersistantWindowData = struct {
    hwnd: usize,
    monitor: usize,
    layers: []isize,
};

const IgnoredProgram = struct {};

pub const WindowManager = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,

    monitors: std.ArrayList(Monitor),
    currentMonitor: usize = 0,

    hotkeys: std.ArrayList(Hotkey),
    currentCommand: Command = .None,
    nextCommand: Command = .None,

    windowData: std.AutoHashMap(HWND, WindowData),

    hHookObjectCreate: HWINEVENTHOOK,
    hHookObjectHide: HWINEVENTHOOK,
    hHookObjectFocus: HWINEVENTHOOK,
    hHookObjectMoved: HWINEVENTHOOK,

    // Settings
    ignoredClassNames: std.StringHashMap(bool),
    ignoredTitles: std.StringHashMap(bool),
    ignoredPrograms: std.StringHashMap(IgnoredProgram),
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
            .ignoredTitles = std.StringHashMap(bool).init(allocator),
            .ignoredPrograms = std.StringHashMap(IgnoredProgram).init(allocator),
            .windowData = std.AutoHashMap(HWND, WindowData).init(allocator),

            .hHookObjectCreate = hHookObjectCreate,
            .hHookObjectHide = hHookObjectHide,
            .hHookObjectFocus = hHookObjectFocus,
            .hHookObjectMoved = hHookObjectMoved,
        };
    }

    pub fn deinit(self: *Self) void {
        self.writeWindowInfosToFile() catch |err| {
            std.log.err("Failed to save window data in file: {}", .{err});
        };

        _ = UnhookWinEvent(self.hHookObjectCreate);
        _ = UnhookWinEvent(self.hHookObjectHide);
        _ = UnhookWinEvent(self.hHookObjectFocus);
        _ = UnhookWinEvent(self.hHookObjectMoved);

        var iter = self.windowData.iterator();
        while (iter.next()) |entry| {
            if (self.isWindowManaged(entry.key)) {
                self.resetWindowPosToUnmanaged(entry.key);
            }
        }

        self.windowData.deinit();
        for (self.monitors.items) |*monitor| {
            monitor.deinit();
        }
        self.monitors.deinit();
        self.hotkeys.deinit();
        self.ignoredClassNames.deinit();
        self.ignoredTitles.deinit();
        self.ignoredPrograms.deinit();
    }

    pub fn setup(self: *Self) !void {
        try self.ignoredClassNames.put("IME", true);
        try self.ignoredClassNames.put("MSCTFIME UI", true);
        try self.ignoredClassNames.put("WorkerW", true);
        try self.ignoredClassNames.put("vguiPopupWindow", true);
        try self.ignoredClassNames.put("tooltips_class32", true);
        try self.ignoredClassNames.put("ForegroundStaging", true);
        try self.ignoredClassNames.put("TaskManagerWindow", true);
        try self.ignoredClassNames.put("Main HighGUI class", true);

        // Ignore windows with empty titles.
        try self.ignoredTitles.put("", true);

        try self.ignoredPrograms.put("ScreenClippingHost.exe", .{});
        try self.ignoredPrograms.put("PowerLauncher.exe", .{});
        try self.ignoredPrograms.put("TextInputHost.exe", .{});
        try self.ignoredPrograms.put("ShellExperienceHost.exe", .{});
        try self.ignoredPrograms.put("EpicGamesLauncher.exe", .{});
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
        try self.loadWindowInfosFromFile();
        self.updateAllWindowVisibilities();
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();

        const defaultHotkeys = [_]Hotkey{
            .{
                .key = @intCast(u32, 'Y'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.cmdDecreaseGap,
            },
            .{
                .key = @intCast(u32, 'P'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.cmdIncreaseGap,
            },

            .{
                .key = @intCast(u32, 'Y'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdDecreaseSplit,
            },
            .{
                .key = @intCast(u32, 'P'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdIncreaseSplit,
            },

            .{
                .key = @intCast(u32, 'J'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdSelectPrevWindow,
            },
            .{
                .key = @intCast(u32, 'L'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdSelectNextWindow,
            },

            .{
                .key = @intCast(u32, 'J'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.cmdMoveWindowUp,
            },
            .{
                .key = @intCast(u32, 'L'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.cmdMoveWindowDown,
            },

            .{
                .key = @intCast(u32, 'X'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdToggleForegroundWindowManaged,
            },
            .{
                .key = @intCast(u32, 'K'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdMoveCurrentWindowToTop,
            },
            .{
                .key = @intCast(u32, 'M'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdMoveNextWindowToLayer,
            },
            .{
                .key = @intCast(u32, 'N'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdToggleNextWindowOnLayer,
            },
            .{
                .key = @intCast(u32, 'I'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdToggleWindowFullscreen,
            },
            .{
                .key = @intCast(u32, 'U'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.cmdMoveWindowToPrevMonitor,
            },
            .{
                .key = @intCast(u32, 'O'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.cmdMoveWindowToNextMonitor,
            },
            .{
                .key = @intCast(u32, 'U'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdGoToPrevMonitor,
            },
            .{
                .key = @intCast(u32, 'O'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 0, .NOREPEAT = 1 }),
                .func = WindowManager.cmdGoToNextMonitor,
            },

            .{
                .key = @intCast(u32, 'G'),
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.cmdPrintForegroundWindowInfo,
            },
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
                .func = WindowManager.cmdLayerCommand,
                .args = .{
                    .usizeParam = @intCast(usize, i),
                    .boolParam = false,
                },
            });
            try self.registerHotkey(.{
                .key = @intCast(u32, '1') + i,
                .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .WIN = 1, .SHIFT = 1, .NOREPEAT = 1 }),
                .func = WindowManager.cmdLayerCommand,
                .args = .{
                    .usizeParam = @intCast(usize, i),
                    .boolParam = true,
                },
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
                    const monitor = self.manageWindow(hwnd, null, 0) catch {
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
                    if (self.getWindow(hwnd)) |window| {
                        if (getWindowRect(hwnd) catch null) |rect| {
                            window.rect = Rect.fromRECT(rect);
                            self.rerenderOverlay();
                        }
                    }
                }
            },
            EVENT_SYSTEM_MOVESIZEEND => {
                if (self.isWindowManaged(hwnd)) {
                    const dstHmonitor = MonitorFromWindow(hwnd, .NULL);
                    const srcMonitor = self.getMonitorFromWindow(hwnd).?;

                    // Check if mouse is outside of working areas
                    // and unmanage the window if that's the case.
                    if (getCursorPos() catch null) |cursorPos| {
                        if (!self.isPointInWorkingArea(cursorPos)) {
                            self.removeManagedWindow(hwnd);
                            self.resetWindowPosToUnmanaged(hwnd);
                            srcMonitor.layoutWindows();
                            self.rerenderOverlay();
                            return;
                        }
                    }

                    // Move window to other monitor or specific place in stack.
                    if (@as(?HMONITOR, dstHmonitor) != null) {
                        const dstMonitor = self.getMonitor(dstHmonitor);
                        if (srcMonitor != dstMonitor) {
                            // Window was dragged onto a different monitor, manage id in that other monitor.
                            self.moveWindowToMonitor(hwnd, srcMonitor, dstMonitor, null);

                            self.setCurrentMonitor(dstMonitor.hmonitor);
                            dstMonitor.setCurrentWindow(hwnd);

                            if (getCursorPos() catch null) |cursorPos| {
                                if (dstMonitor.getWindowIndexContainingPoint(cursorPos, hwnd)) |index| {
                                    dstMonitor.moveCurrentWindowToIndex(index);
                                }
                            }

                            srcMonitor.layoutWindows();
                            dstMonitor.layoutWindows();
                        } else {
                            if (getCursorPos() catch null) |cursorPos| {
                                if (dstMonitor.getWindowIndexContainingPoint(cursorPos, hwnd)) |index| {
                                    dstMonitor.moveCurrentWindowToIndex(index);
                                }
                            }
                            dstMonitor.layoutWindows();
                        }
                    }

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

    fn loadWindowInfosFromFile(self: *Self) !void {
        std.log.info("Loading window state from '{s}'", .{windowDataFileName});

        var file = try std.fs.cwd().openFile(windowDataFileName, .{ .read = true });
        defer file.close();
        const fileSize = try file.getEndPos();
        const fileContent = try self.allocator.alloc(u8, fileSize);
        defer self.allocator.free(fileContent);
        const fileSizeRead = try file.readAll(fileContent);
        if (fileSize != fileSizeRead) return error.FailedToReadDataFromFile;

        var tokenStream = std.json.TokenStream.init(fileContent);
        const options = std.json.ParseOptions{
            .allocator = self.allocator,
        };
        const TypeToParse = []PersistantWindowData;
        const persistantWindowData = try std.json.parse(TypeToParse, &tokenStream, options);
        defer std.json.parseFree(TypeToParse, persistantWindowData, options);

        for (persistantWindowData) |*data| {
            std.log.info("{}", .{data});

            const hwnd = @intToPtr(HWND, data.hwnd);
            if (self.getMonitorFromWindow(hwnd)) |oldMonitor| {
                var newMonitor = oldMonitor;
                // Move window to specific monitor.
                if (data.monitor < self.monitors.items.len) {
                    newMonitor = self.getMonitorAt(data.monitor);
                    self.moveWindowToMonitor(
                        hwnd,
                        oldMonitor,
                        newMonitor,
                        null,
                    );
                }

                // Move window to specific layers
                for (data.layers) |index, layerIndex| {
                    if (layerIndex >= newMonitor.layers.items.len) break;
                    var layer = newMonitor.getLayer(layerIndex);
                    if (index >= 0) {
                        try layer.addWindow(hwnd, @intCast(usize, index));
                    } else {
                        _ = layer.removeWindow(hwnd);
                    }
                }
            } else {
                // Window is not managed yet so add it.
                if (self.isWindowManageable(hwnd)) {
                    const monitorIndex = if (data.monitor < self.monitors.items.len) data.monitor else self.currentMonitor;
                    const monitor = self.getMonitorAt(monitorIndex);

                    try self.windowData.put(hwnd, .{
                        .rect = try getWindowRect(hwnd),
                    });

                    // Move window to specific layers
                    for (data.layers) |index, layerIndex| {
                        if (layerIndex >= monitor.layers.items.len) break;
                        var layer = monitor.getLayer(layerIndex);
                        if (index >= 0) {
                            try layer.addWindow(hwnd, @intCast(usize, index));
                        } else {
                            _ = layer.removeWindow(hwnd);
                        }
                    }
                } else {
                    std.log.warn("Window in saved data file is not valid anymore: {}", .{hwnd});
                }
            }
        }

        // Sort windows by index.
        for (self.monitors.items) |*monitor| {
            for (monitor.layers.items) |*layer| {
                layer.sortWindows();
            }
        }
    }

    pub fn writeWindowInfosToFile(self: *Self) !void {
        std.log.info("Saving window state to '{s}'", .{windowDataFileName});

        var file = try std.fs.cwd().createFile(windowDataFileName, .{ .truncate = true });
        defer file.close();

        var jw = std.json.writeStream(file.writer(), 10);
        try jw.beginArray();

        // Collect all windows.
        var allWindows = std.AutoHashMap(HWND, *Monitor).init(self.allocator);
        defer allWindows.deinit();
        for (self.monitors.items) |*monitor| {
            for (monitor.layers.items) |*layer| {
                for (layer.windows.items) |*window| {
                    try allWindows.put(window.hwnd, monitor);
                }
            }
        }

        for (self.monitors.items) |*monitor, monitorIndex| {
            var iter = allWindows.iterator();
            while (iter.next()) |entry| {
                if (entry.value != monitor) continue;

                const hwnd = entry.key;
                try jw.arrayElem();
                try jw.beginObject();

                try jw.objectField("hwnd");
                try jw.emitNumber(@ptrToInt(hwnd));

                try jw.objectField("monitor");
                try jw.emitNumber(monitorIndex);

                try jw.objectField("layers");
                try jw.beginArray();
                for (monitor.layers.items) |*layer| {
                    try jw.arrayElem();
                    if (layer.getWindowIndex(hwnd)) |index| {
                        try jw.emitNumber(index);
                    } else {
                        try jw.emitNumber(-1);
                    }
                }
                try jw.endArray();

                try jw.endObject();
            }
        }

        try jw.endArray();
    }

    fn handleEnumWindows(
        hwnd: HWND,
        param: LPARAM,
    ) callconv(@import("std").os.windows.WINAPI) BOOL {
        var self = @intToPtr(*WindowManager, @bitCast(usize, param));

        const className = getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena) catch return 1;
        defer className.deinit();

        if (!self.isWindowManageable(hwnd)) {
            return 1;
        }

        const windowTitle = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, root.gWindowStringArena) catch return 1;
        defer windowTitle.deinit();

        const rect = getWindowRect(hwnd) catch return 1;

        _ = self.manageWindow(hwnd, null, null) catch {
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
        if (IsWindow(hwnd) == 0) return false;

        for (self.monitors.items) |*monitor| {
            if (hwnd == monitor.overlayWindow)
                return false;
        }

        const className = getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena) catch return false;
        defer className.deinit();
        var title = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, root.gWindowStringArena) catch return false;
        defer title.deinit();

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
                \\title:   '{s}'
                \\parent:  {}
                \\owner:   {}
                \\style:   {}
                \\exstyle: {}
                \\parentOk:{}
                \\istool:  {}
                \\isapp:   {}
            , .{ hwnd, className.value, title.value, parent, owner, style, exstyle, parentOk, istool, isapp });
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

        if (self.ignoredTitles.get(title.value)) |_| {
            return false;
        }

        if (getWindowExeName(hwnd, root.gWindowStringArena) catch null) |name| {
            defer name.deinit();
            if (self.ignoredPrograms.get(name.value)) |_| {
                std.log.info("Window is not manageable because the program name is ignored: '{s}'", .{name.value});
                return false;
            }
        } else {
            //
            std.log.err("Failed to get exe name from window {}: {s}", .{ hwnd, className.value });
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

    fn getWindowIndexUnderCursor(self: *Self, excludeHwnd: ?HWND) ?*usize {
        var cursorPos = try getCursorPos();
        for (self.monitors.items) |*monitor| {
            if (monitor.getWindowIndexUnderCursor(cursorPos, excludeHwnd)) |index| {
                return index;
            }
        }
        return null;
    }

    fn getWindowUnderCursor(self: *Self, excludeHwnd: ?HWND) ?*Window {
        var cursorPos = try getCursorPos();
        for (self.monitors.items) |*monitor| {
            if (monitor.getWindowUnderCursor(cursorPos, excludeHwnd)) |window| {
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

    fn manageWindow(self: *Self, hwnd: HWND, _preferredMonitor: ?*Monitor, index: ?usize) !*Monitor {
        std.log.info("manageWindow({}, {})", .{ hwnd, index });
        try self.windowData.put(hwnd, .{
            .rect = try getWindowRect(hwnd),
        });

        for (self.monitors.items) |*monitor| {
            if (monitor.isWindowManaged(hwnd)) {
                return monitor;
            }
        }

        //_ = ShowWindow(hwnd, .RESTORE);
        //_ = SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SET_WINDOW_POS_FLAGS.initFlags(.{ .NOMOVE = 1, .NOSIZE = 1 }));
        //_ = SetForegroundWindow(hwnd);
        //_ = BringWindowToTop(hwnd);

        var preferredMonitor = _preferredMonitor;
        if (preferredMonitor == null) {
            // Try to put window on monitor with the greatest intersection area.
            const hmonitor = MonitorFromWindow(hwnd, .PRIMARY);
            for (self.monitors.items) |*monitor, i| {
                if (monitor.hmonitor == hmonitor) {
                    self.currentMonitor = i;
                    preferredMonitor = monitor;
                    break;
                }
            }
        }

        var monitor = preferredMonitor orelse self.getCurrentMonitor();
        try monitor.manageWindow(hwnd, index);
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

    fn setCurrentMonitor(self: *Self, hmonitor: HMONITOR) void {
        for (self.monitors.items) |*monitor, i| {
            if (monitor.hmonitor == hmonitor) {
                self.currentMonitor = i;
            }
        }
    }

    fn getMonitorAt(self: *Self, index: usize) *Monitor {
        std.debug.assert(index < self.monitors.items.len);
        return &self.monitors.items[index];
    }

    fn getCurrentMonitor(self: *Self) *Monitor {
        return self.getMonitorAt(self.currentMonitor);
    }

    fn getMonitor(self: *Self, hmonitor: HMONITOR) *Monitor {
        for (self.monitors.items) |*monitor| {
            if (monitor.hmonitor == hmonitor)
                return monitor;
        }
        unreachable;
    }

    fn getMonitorFromOverlayWindow(self: *Self, hwnd: HWND) *Monitor {
        for (self.monitors.items) |*monitor| {
            if (monitor.overlayWindow == hwnd)
                return monitor;
        }

        unreachable;
    }

    fn getMonitorFromWindow(self: *Self, hwnd: HWND) ?*Monitor {
        for (self.monitors.items) |*monitor| {
            if (monitor.isWindowManaged(hwnd))
                return monitor;
        }

        return null;
    }

    fn isPointInWorkingArea(self: *Self, point: POINT) bool {
        for (self.monitors.items) |*monitor| {
            if (monitor.isPointInWorkingArea(point)) {
                return true;
            }
        }
        return false;
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

    fn moveWindowToMonitor(self: *Self, hwnd: HWND, srcMonitor: *Monitor, dstMonitor: *Monitor, index: ?usize) void {
        if (srcMonitor == dstMonitor) return;
        if (!srcMonitor.isWindowManaged(hwnd)) return;

        var srcLayer = srcMonitor.getCurrentLayer();
        var dstLayer = dstMonitor.getCurrentLayer();

        dstLayer.addWindow(hwnd, index) catch unreachable;

        // Completely remove window from source monitor
        // because having a window on two monitors doesn't make sense.
        srcMonitor.removeManagedWindow(hwnd);
    }

    fn resetWindowPosToUnmanaged(self: *Self, hwnd: HWND) void {
        if (self.windowData.get(hwnd)) |data| {
            _ = SetWindowPos(
                hwnd,
                null,
                data.rect.left,
                data.rect.top,
                data.rect.right - data.rect.left,
                data.rect.bottom - data.rect.top,
                SET_WINDOW_POS_FLAGS.initFlags(.{}),
            );
        }
    }

    pub fn updateAllWindowVisibilities(self: *Self) void {
        for (self.monitors.items) |*monitor| {
            monitor.updateAllWindowVisibilities();
        }
    }

    fn cmdIncreaseGap(self: *Self, args: HotkeyArgs) void {
        self.options.gap.? += 5;
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();
    }

    fn cmdDecreaseGap(self: *Self, args: HotkeyArgs) void {
        self.options.gap.? -= 5;
        if (self.options.gap.? < 0) {
            self.options.gap.? = 0;
        }
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();
    }

    fn cmdIncreaseSplit(self: *Self, args: HotkeyArgs) void {
        self.options.splitRatio.? += 0.025;
        if (self.options.splitRatio.? > 0.9) {
            self.options.splitRatio.? = 0.9;
        }
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();
    }

    fn cmdDecreaseSplit(self: *Self, args: HotkeyArgs) void {
        self.options.splitRatio.? -= 0.025;
        if (self.options.splitRatio.? < 0.1) {
            self.options.splitRatio.? = 0.1;
        }
        self.layoutWindowsOnAllMonitors();
        self.rerenderOverlay();
    }

    fn cmdMoveCurrentWindowToLayer(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().moveCurrentWindowToLayer(args.usizeParam);
    }

    fn cmdToggleCurrentWindowOnLayer(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().toggleCurrentWindowOnLayer(args.usizeParam);
    }

    fn cmdSwitchLayer(self: *Self, args: HotkeyArgs) void {
        std.log.info("cmdSwitchLayer({}, {})", .{ args.usizeParam, args.boolParam });
        if (args.boolParam) {
            for (self.monitors.items) |*monitor| {
                monitor.switchLayer(args.usizeParam, true);
            }

            self.focusCurrentWindow();
            self.layoutWindowsOnAllMonitors();
            self.rerenderOverlay();
        } else {
            self.getCurrentMonitor().switchLayer(args.usizeParam, false);
        }
    }

    fn cmdLayerCommand(self: *Self, args: HotkeyArgs) void {
        std.log.info("Layer command", .{});
        switch (self.currentCommand) {
            .None => self.cmdSwitchLayer(args),
            .ToggleWindowOnLayer => self.cmdToggleCurrentWindowOnLayer(args),
            .MoveWindowToLayer => self.cmdMoveCurrentWindowToLayer(args),
            //else => unreachable,
        }
    }

    fn cmdMoveNextWindowToLayer(self: *Self, args: HotkeyArgs) void {
        std.log.info("Move next window to layer", .{});
        self.nextCommand = .MoveWindowToLayer;
    }

    fn cmdToggleNextWindowOnLayer(self: *Self, args: HotkeyArgs) void {
        std.log.info("Toggle next window on layer", .{});
        self.nextCommand = .ToggleWindowOnLayer;
    }

    fn cmdGoToPrevMonitor(self: *Self, args: HotkeyArgs) void {
        std.log.info("cmdGoToPrevMonitor", .{});
        if (self.monitors.items.len < 2) {
            // Only zero/one monitor, nothing to do.
            return;
        }
        self.currentMonitor = @mod(self.currentMonitor + self.monitors.items.len - 1, self.monitors.items.len);
        self.getCurrentMonitor().focusCurrentWindow();
        self.rerenderOverlay();
    }

    fn cmdGoToNextMonitor(self: *Self, args: HotkeyArgs) void {
        std.log.info("cmdGoToNextMonitor", .{});
        if (self.monitors.items.len < 2) {
            // Only zero/one monitor, nothing to do.
            return;
        }
        self.currentMonitor = @mod(self.currentMonitor + 1, self.monitors.items.len);
        self.getCurrentMonitor().focusCurrentWindow();
        self.rerenderOverlay();
    }

    fn cmdMoveWindowToPrevMonitor(self: *Self, args: HotkeyArgs) void {
        if (self.monitors.items.len < 2) {
            // Only zero/one monitor, nothing to do.
            return;
        }

        var srcMonitor = self.getCurrentMonitor();
        var srcLayer = srcMonitor.getCurrentLayer();

        const dstMonitorIndex = @mod(self.currentMonitor + self.monitors.items.len - 1, self.monitors.items.len);
        var dstMonitor = &self.monitors.items[dstMonitorIndex];

        if (srcMonitor.getCurrentWindow()) |window| {
            self.moveWindowToMonitor(window.hwnd, srcMonitor, dstMonitor, 0);
            dstMonitor.currentWindow = 0;
        }

        self.setCurrentMonitor(dstMonitor.hmonitor);
        dstMonitor.focusCurrentWindow();
        srcMonitor.layoutWindows();
        dstMonitor.layoutWindows();
        self.rerenderOverlay();
    }

    fn cmdMoveWindowToNextMonitor(self: *Self, args: HotkeyArgs) void {
        if (self.monitors.items.len < 2) {
            // Only zero/one monitor, nothing to do.
            return;
        }

        var srcMonitor = self.getCurrentMonitor();
        var srcLayer = srcMonitor.getCurrentLayer();

        const dstMonitorIndex = @mod(self.currentMonitor + 1, self.monitors.items.len);
        var dstMonitor = &self.monitors.items[dstMonitorIndex];

        if (srcMonitor.getCurrentWindow()) |window| {
            self.moveWindowToMonitor(window.hwnd, srcMonitor, dstMonitor, 0);
            dstMonitor.currentWindow = 0;
        }

        self.setCurrentMonitor(dstMonitor.hmonitor);
        dstMonitor.focusCurrentWindow();
        srcMonitor.layoutWindows();
        dstMonitor.layoutWindows();
        self.rerenderOverlay();
    }

    fn cmdToggleWindowFullscreen(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().toggleWindowFullscreen();
    }

    fn cmdToggleForegroundWindowManaged(self: *Self, args: HotkeyArgs) void {
        const hwnd = GetForegroundWindow();
        if (self.isWindowManaged(hwnd)) {
            self.removeManagedWindow(hwnd);
            self.resetWindowPosToUnmanaged(hwnd);
            self.layoutWindowsOnAllMonitors();
            self.rerenderOverlay();
        } else if (self.isWindowManageable(hwnd)) {
            const monitor = self.manageWindow(hwnd, null, 0) catch return;
            monitor.layoutWindows();
            self.rerenderOverlay();
        }
    }

    fn cmdSelectPrevWindow(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().selectPrevWindow();
    }

    fn cmdSelectNextWindow(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().selectNextWindow();
    }

    fn cmdMoveCurrentWindowToTop(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().moveCurrentWindowToTop();
        self.focusCurrentWindow();
        self.layoutWindows();
        self.rerenderOverlay();
    }

    fn cmdMoveWindowUp(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().moveCurrentWindowUp();
        self.focusCurrentWindow();
        self.layoutWindows();
        self.rerenderOverlay();
    }

    fn cmdMoveWindowDown(self: *Self, args: HotkeyArgs) void {
        self.getCurrentMonitor().moveCurrentWindowDown();
        self.focusCurrentWindow();
        self.layoutWindows();
        self.rerenderOverlay();
    }

    fn cmdPrintForegroundWindowInfo(self: *Self, args: HotkeyArgs) void {
        const hwnd = GetForegroundWindow();
        var className = getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena) catch return;
        defer className.deinit();

        var title = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, root.gWindowStringArena) catch return;
        defer title.deinit();
        std.log.notice(
            "Window '{s}' '{s}' manageable: {}",
            .{ title.value, className.value, self.isWindowManageable(hwnd) },
        );

        if (getWindowExeName(hwnd, root.gWindowStringArena) catch null) |name| {
            defer name.deinit();
            const classNameIgnored = self.ignoredClassNames.contains(className.value);
            const programIgnored = self.ignoredPrograms.contains(name.value);
            std.log.notice(
                "Window info of '{s}' (title: '{s}', class: '{s}', class ignored: {}, program ignored: {})",
                .{ name.value, title.value, className.value, classNameIgnored, programIgnored },
            );
        } else {
            //
            std.log.err("Failed to get exe name from window {}: {s}", .{ hwnd, className.value });
        }
    }
};
