const std = @import("std");
const root = @import("root");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");
usingnamespace @import("layer.zig");

const CWM_WINDOW_CREATED = WM_USER + 1;
const HK_CLOSE_WINDOW: i32 = 42069;

const HotkeyArgs = struct {
    intParam: i64 = 0,
    usizeParam: usize = 0,
    floatParam: f64 = 0.0,
    boolParam: bool = false,
    charParam: i27 = 0,
};

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

    hotkeys: std.ArrayList(Hotkey),
    layers: std.ArrayList(Layer),
    currentLayer: usize = 0,
    currentWindow: usize = 0,

    currentCommand: Command = .None,
    nextCommand: Command = .None,

    overlayWindow: HWND,

    hHookObjectCreate: HWINEVENTHOOK,
    hHookObjectHide: HWINEVENTHOOK,
    hHookObjectFocus: HWINEVENTHOOK,
    hHookObjectMoved: HWINEVENTHOOK,

    // Settings
    ignoredClassNames: std.StringHashMap(bool),
    gap: i32 = 5,
    splitRatio: f64 = 0.5,

    pub fn init(allocator: *std.mem.Allocator) !Self {
        const overlayWindow = try createOverlayWindow();
        std.log.info("Created overlay window: {}", .{overlayWindow});
        var layers = try std.ArrayList(Layer).initCapacity(allocator, 10);
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            try layers.append(try Layer.init(allocator));
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
            .layers = layers,
            .hotkeys = std.ArrayList(Hotkey).init(allocator),
            .ignoredClassNames = std.StringHashMap(bool).init(allocator),
            .overlayWindow = overlayWindow,

            .hHookObjectCreate = hHookObjectCreate,
            .hHookObjectHide = hHookObjectHide,
            .hHookObjectFocus = hHookObjectFocus,
            .hHookObjectMoved = hHookObjectMoved,
        };
    }

    pub fn deinit(self: *Self) void {
        // Show all windows.
        for (self.layers.items) |*layer| {
            for (layer.windows.items) |*window| {
                _ = ShowWindow(window.hwnd, SW_SHOW);
            }
        }

        _ = UnhookWinEvent(self.hHookObjectCreate);
        _ = UnhookWinEvent(self.hHookObjectHide);
        _ = UnhookWinEvent(self.hHookObjectFocus);
        _ = UnhookWinEvent(self.hHookObjectMoved);

        for (self.layers.items) |*layer| {
            layer.deinit();
        }
        self.layers.deinit();
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

        _ = SetWindowLongPtrA(self.overlayWindow, GWLP_USERDATA, @bitCast(isize, @ptrToInt(self)));

        //SetWindowsHookExA(.CALLWNDPROCRET, this.handleWindowProcRette);

        // Initial update + layout.
        self.updateWindowInfos();
        self.layoutWindows();

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
            self.overlayWindow,
            @intCast(i32, self.hotkeys.items.len),
            hotkey.mods,
            hotkey.key,
        ) == 0) {
            std.log.err("Failed to register hotkey {} '{c}' ({})", .{ hotkey.key, @intCast(u8, hotkey.key), hotkey.mods });
            return;
        }

        try self.hotkeys.append(hotkey);
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

    fn createOverlayWindow() !HWND {
        const hInstance = GetModuleHandleA(null);
        const WINDOW_NAME = "zwtwm";

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

            return window;
        }
        return error.FailedToCreateOverlayWindow;
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
                    self.manageWindow(hwnd, false) catch {
                        std.log.err("Failed to manage window {}:{s}: '{s}'", .{ hwnd, className.value, windowTitle.value });
                        return;
                    };

                    self.layoutWindows();
                }
            },

            EVENT_OBJECT_DESTROY => {
                if (self.isWindowManaged(hwnd)) {
                    self.removeManagedWindow(hwnd);
                    self.layoutWindows();
                    self.focusCurrentWindow();
                }
            },

            EVENT_SYSTEM_FOREGROUND => {
                if (self.isWindowManaged(hwnd)) {
                    self.setCurrentWindow(hwnd);
                }
                self.rerenderOverlay();
            },

            EVENT_SYSTEM_MOVESIZESTART => {
                if (self.isWindowManaged(hwnd)) {
                    var rect: RECT = undefined;
                    _ = GetWindowRect(hwnd, &rect);
                    self.getWindow(hwnd).?.rect = Rect.fromRECT(rect);
                    self.rerenderOverlay();
                }
            },
            EVENT_SYSTEM_MOVESIZEEND => {
                if (self.isWindowManaged(hwnd)) {
                    self.removeManagedWindow(hwnd);
                    self.layoutWindows();
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
                var self = @intToPtr(*WindowManager, @bitCast(usize, GetWindowLongPtrA(hwnd, GWLP_USERDATA)));
                switch (wParam) {
                    HK_CLOSE_WINDOW => PostQuitMessage(0),
                    else => self.runHotkey(@intCast(usize, wParam)),
                }

                const hdc = GetDC(null);
                defer _ = ReleaseDC(null, hdc);

                var clientRect: RECT = undefined;
                _ = GetClientRect(hwnd, &clientRect);
                self.renderOverlay(hdc, clientRect);
            },

            WM_PAINT => {
                var self = @intToPtr(*WindowManager, @bitCast(usize, GetWindowLongPtrA(hwnd, GWLP_USERDATA)));
                var ps: PAINTSTRUCT = undefined;
                var hdc = BeginPaint(hwnd, &ps);
                defer _ = EndPaint(hwnd, &ps);
                self.clearBackground(hdc, ps.rcPaint);
                self.renderOverlay(hdc, ps.rcPaint);
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
        var backgroundBrush = CreateSolidBrush(0);
        defer _ = DeleteObject(backgroundBrush);
        _ = FillRect(hdc, &region, backgroundBrush);
    }

    fn renderOverlay(self: *Self, hdc: HDC, region: RECT) void {
        var brushFocused = CreateSolidBrush(rgb(200, 50, 25));
        defer _ = DeleteObject(brushFocused);
        var brushUnfocused = CreateSolidBrush(rgb(25, 50, 200));
        defer _ = DeleteObject(brushUnfocused);

        const rect = RECT{
            .left = region.left + self.gap,
            .right = region.right - self.gap,
            .top = region.top + self.gap,
            .bottom = region.bottom - self.gap,
        };

        var layer = self.getCurrentLayer();

        for (layer.windows.items) |*window, i| {
            const winRect = window.rect.expand(0).toRECT();

            if (i == self.currentWindow) {
                const brush = if (window.hwnd == GetForegroundWindow()) brushFocused else brushUnfocused;

                var k: i32 = 0;
                while (k < 2) : (k += 1) {
                    const winRect2 = window.rect.expand(-k).toRECT();
                    _ = FrameRect(hdc, &winRect2, brush);
                }
            }
        }
    }

    fn updateWindowInfos(self: *Self) void {
        _ = EnumWindows(Self.handleEnumWindows, @bitCast(isize, @ptrToInt(self)));

        if (root.LOG_LAYERS) {
            for (self.layers.items) |*layer, i| {
                if (layer.isEmpty()) continue;

                std.debug.print("Layer {}\n", .{i});
                for (layer.windows.items) |*window| {
                    std.debug.print("  {s}: ", .{window.className.value});
                    std.debug.print("{s}", .{window.title.value});
                    std.debug.print("   -   {}\n", .{window.rect});
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

        self.manageWindow(hwnd, false) catch {
            std.log.err("Failed to manage window {}:{s}: '{s}'", .{ hwnd, className.value, windowTitle.value });
        };

        return 1;
    }

    fn isWindowObscured(self: *Self, hwnd: HWND) bool {
        const hdc = GetWindowDC(hwnd);
        defer _ = ReleaseDC(hwnd, hdc);
        var rect: RECT = undefined;
        return GetClipBox(hdc, &rect) == NULLREGION;
    }

    fn isWindowManageable(self: *Self, hwnd: HWND) bool {
        if (hwnd == self.overlayWindow)
            return false;

        const className = getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena) catch return false;
        defer className.deinit();
        if (!std.mem.eql(u8, className.value, "CabinetWClass")) {
            return false;
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
        return self.getCurrentLayer().getWindow(hwnd);
    }

    fn isWindowManaged(self: *Self, hwnd: HWND) bool {
        for (self.layers.items) |*layer| {
            if (layer.containsWindow(hwnd)) {
                return true;
            }
        }
        return false;
    }

    fn manageWindow(self: *Self, hwnd: HWND, onTop: bool) !void {
        if (self.isWindowManaged(hwnd)) {
            return;
        }

        var layer = self.getCurrentLayer();
        try layer.addWindow(hwnd, onTop);
    }

    fn removeManagedWindow(self: *Self, hwnd: HWND) void {
        if (!self.isWindowManaged(hwnd)) {
            return;
        }

        var removedIndex: usize = 0;
        for (self.layers.items) |*layer, i| {
            const k = layer.removeWindow(hwnd);
            if (i == self.currentLayer) {
                removedIndex = k;
            }
        }

        if (removedIndex < self.currentWindow) {
            self.currentWindow -= 1;
        }
        self.clampCurrentWindowIndex();
    }

    fn setCurrentWindow(self: *Self, hwnd: HWND) void {
        if (!self.isWindowManaged(hwnd)) {
            return;
        }

        const layer = self.getCurrentLayer();
        if (!layer.containsWindow(hwnd)) {
            return;
        }

        self.currentWindow = layer.getWindowIndex(hwnd).?;
    }

    fn getLayer(self: *Self, index: usize) *Layer {
        std.debug.assert(index < self.layers.items.len);
        return &self.layers.items[index];
    }

    fn getCurrentLayer(self: *Self) *Layer {
        return self.getLayer(self.currentLayer);
    }

    fn clampCurrentWindowIndex(self: *Self) void {
        const layer = self.getCurrentLayer();
        if (layer.windows.items.len == 0) {
            self.currentWindow = 0;
        } else if (self.currentWindow >= layer.windows.items.len) {
            self.currentWindow = layer.windows.items.len - 1;
        }
    }

    fn selectPrevWindow(self: *Self, args: HotkeyArgs) void {
        std.log.info("selectPrevWindow", .{});
        const layer = self.getCurrentLayer();
        if (layer.windows.items.len == 0) {
            self.currentWindow = 0;
        } else {
            if (self.currentWindow == 0) {
                self.currentWindow = layer.windows.items.len - 1;
            } else {
                self.currentWindow -= 1;
            }
        }

        self.focusCurrentWindow();
        self.layoutWindows();
    }

    fn selectNextWindow(self: *Self, args: HotkeyArgs) void {
        std.log.info("selectNextWindow", .{});
        const layer = self.getCurrentLayer();
        if (layer.windows.items.len == 0) {
            self.currentWindow = 0;
        } else {
            self.currentWindow += 1;
            if (self.currentWindow >= layer.windows.items.len) {
                self.currentWindow = 0;
            }
        }

        self.focusCurrentWindow();
        self.layoutWindows();
    }

    fn moveCurrentWindowToTop(self: *Self, args: HotkeyArgs) void {
        //std.log.info("moveCurrentWindowToTop", .{});
        const layer = self.getCurrentLayer();
        layer.moveWindowToTop(self.currentWindow);
        self.currentWindow = 0;

        self.focusCurrentWindow();
        self.layoutWindows();
    }

    fn focusCurrentWindow(self: *Self) void {
        const layer = self.getCurrentLayer();
        if (layer.getWindowAt(self.currentWindow)) |window| {
            _ = SetForegroundWindow(window.hwnd);
        }
    }

    fn rerenderOverlay(self: *Self) void {
        _ = InvalidateRect(self.overlayWindow, null, 1);
        _ = RedrawWindow(
            self.overlayWindow,
            null,
            null,
            REDRAW_WINDOW_FLAGS.initFlags(.{ .UPDATENOW = 1 }),
        );
    }

    fn layoutWindows(self: *Self) void {
        std.log.notice("Layout windows", .{});

        var monitor = getMonitorRect() catch return;
        monitor.width = @divTrunc(monitor.width, 2) - 1;
        monitor.x += monitor.width + 2;

        var workingArea = Rect{
            .x = monitor.x + self.gap,
            .y = monitor.y + self.gap,
            .width = monitor.width - self.gap * 2,
            .height = monitor.height - self.gap * 2,
        };

        var layer = self.getCurrentLayer();

        const numWindows: i32 = @intCast(i32, layer.windows.items.len);
        if (numWindows > 0) {
            if (layer.fullscreen) {
                const win = layer.getWindowAt(self.currentWindow).?;
                win.rect = workingArea;
                if (SetWindowPos(
                    win.hwnd,
                    null,
                    workingArea.x - 7,
                    workingArea.y,
                    workingArea.width + 14,
                    workingArea.height + 7,
                    SET_WINDOW_POS_FLAGS.initFlags(.{}),
                ) == 0) {
                    std.log.err("Failed to set window position of {}", .{win.hwnd});
                }
            } else {
                var hdwp = BeginDeferWindowPos(@intCast(i32, numWindows));
                if (hdwp == 0) {
                    return;
                }

                var x: i32 = workingArea.x;
                for (layer.windows.items) |*window, i| {
                    var area = workingArea;
                    if (i + 1 < layer.windows.items.len) {
                        // More windows after this one.
                        if (@mod(i, 2) != 0) {
                            const ratio = if (i == 0) self.splitRatio else 0.5;
                            const split = @floatToInt(i32, @intToFloat(f64, area.width) * ratio);

                            workingArea.x += split + self.gap;
                            workingArea.width -= split + self.gap;
                            area.width = split;
                        } else {
                            const ratio = if (i == 0) self.splitRatio else 0.5;
                            const split = @floatToInt(i32, @intToFloat(f64, area.height) * ratio);

                            workingArea.y += split + self.gap;
                            workingArea.height -= split + self.gap;
                            area.height = split;
                        }
                    }

                    window.rect = area;

                    hdwp = DeferWindowPos(
                        hdwp,
                        window.hwnd,
                        null,
                        area.x - 7,
                        area.y,
                        area.width + 14,
                        area.height + 7,
                        SET_WINDOW_POS_FLAGS.initFlags(.{
                            .NOOWNERZORDER = 1,
                            .NOZORDER = 0,
                            .SHOWWINDOW = 1,
                        }),
                    );

                    if (hdwp == 0) {
                        return;
                    }
                }

                _ = EndDeferWindowPos(hdwp);
            }
        }

        self.rerenderOverlay();

        if (root.LOG_LAYERS) {
            for (self.layers.items) |*l, i| {
                if (l.isEmpty()) continue;

                std.debug.print("  Layer {}\n", .{i});
                for (l.windows.items) |*window| {
                    std.debug.print("    {s}: ", .{window.className.value});
                    std.debug.print("{s}", .{window.title.value});
                    std.debug.print("   -   {}\n", .{window.rect});
                }
            }
        }
    }

    fn setWindowVisibility(self: *Self, hwnd: HWND, shouldBeVisible: bool) void {
        const isMinimized = IsIconic(hwnd) != 0;
        const isVisible = IsWindowVisible(hwnd) != 0;

        if (shouldBeVisible and !isMinimized and isVisible) {
            // Already visible, nothing to do.
            //std.log.debug("Window {} is already visible.", .{hwnd});
            return;
        }

        if (!shouldBeVisible and !isVisible) {
            // Already hidden, nothing to do.
            //std.log.debug("Window {} is already hidden.", .{hwnd});
            return;
        }

        // Temp: only minimize window, later we actually want to hide them.
        if (shouldBeVisible) {
            _ = ShowWindow(hwnd, SW_RESTORE);
        } else {
            _ = ShowWindow(hwnd, SW_HIDE);
        }
    }

    fn updateWindowVisibility(self: *Self, hwnd: HWND) void {
        self.setWindowVisibility(hwnd, self.getCurrentLayer().containsWindow(hwnd));
    }

    fn increaseGap(self: *Self, args: HotkeyArgs) void {
        self.gap += 5;
        std.log.info("Inc gap: {}", .{self.gap});
        self.layoutWindows();
    }

    fn decreaseGap(self: *Self, args: HotkeyArgs) void {
        self.gap -= 5;
        if (self.gap < 0) {
            self.gap = 0;
        }
        std.log.info("Dec gap: {}", .{self.gap});
        self.layoutWindows();
    }

    fn increaseSplit(self: *Self, args: HotkeyArgs) void {
        self.splitRatio += 0.025;
        if (self.splitRatio > 0.9) {
            self.splitRatio = 0.9;
        }
        std.log.info("Inc split: {}", .{self.splitRatio});
        self.layoutWindows();
    }

    fn decreaseSplit(self: *Self, args: HotkeyArgs) void {
        self.splitRatio -= 0.025;
        if (self.splitRatio < 0.1) {
            self.splitRatio = 0.1;
        }
        std.log.info("Dec split: {}", .{self.splitRatio});
        self.layoutWindows();
    }

    fn moveCurrentWindowToLayer(self: *Self, args: HotkeyArgs) void {
        std.log.info("Move current window to layer: {}", .{args.usizeParam});
        const newLayer = args.usizeParam;
        if (newLayer == self.currentLayer) return;

        if (newLayer < 0 or newLayer >= self.layers.items.len) {
            std.log.err("Can't move window to layer {}: outside of range", .{args.usizeParam});
            return;
        }

        var fromLayer = self.getCurrentLayer();
        var toLayer = self.getLayer(@intCast(usize, newLayer));

        if (fromLayer.getWindowAt(self.currentWindow)) |window| {
            toLayer.addWindow(window.hwnd, false) catch unreachable;
            _ = fromLayer.removeWindow(window.hwnd);
            self.setWindowVisibility(window.hwnd, false);
        }

        self.layoutWindows();
        self.clampCurrentWindowIndex();
        self.focusCurrentWindow();
        self.layoutWindows();
    }

    fn toggleCurrentWindowOnLayer(self: *Self, args: HotkeyArgs) void {
        std.log.info("Toggle current window on layer: {}", .{args.usizeParam});
        const newLayer = args.usizeParam;
        if (newLayer == self.currentLayer) return;

        if (newLayer < 0 or newLayer >= self.layers.items.len) {
            std.log.err("Layer {}: outside of range", .{args.usizeParam});
            return;
        }

        var layer = self.getCurrentLayer();
        var toLayer = self.getLayer(@intCast(usize, newLayer));

        if (layer.getWindowAt(self.currentWindow)) |window| {
            if (toLayer.containsWindow(window.hwnd)) {
                _ = toLayer.removeWindow(window.hwnd);
            } else {
                toLayer.addWindow(window.hwnd, false) catch unreachable;
            }
        }
    }

    fn switchLayer(self: *Self, args: HotkeyArgs) void {
        std.log.info("Switch to layer: {}", .{args.usizeParam});
        const newLayer = args.usizeParam;
        if (newLayer == self.currentLayer) return;

        if (newLayer < 0 or newLayer >= self.layers.items.len) {
            std.log.err("Can't switch to layer {}: outside of range", .{args.usizeParam});
            return;
        }

        var fromLayer = self.getCurrentLayer();
        var toLayer = self.getLayer(@intCast(usize, newLayer));

        // Hide windows in the current layer except ones that are also on the target layer.
        for (fromLayer.windows.items) |*window| {
            if (!toLayer.containsWindow(window.hwnd)) {
                self.setWindowVisibility(window.hwnd, false);
            }
        }

        for (toLayer.windows.items) |*window| {
            // This doesn't do anything if the window is already visible.
            self.setWindowVisibility(window.hwnd, true);
        }

        self.currentLayer = args.usizeParam;
        self.currentWindow = 0;
        self.focusCurrentWindow();
        self.layoutWindows();
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

    fn toggleWindowFullscreen(self: *Self, args: HotkeyArgs) void {
        var layer = self.getCurrentLayer();
        layer.fullscreen = !layer.fullscreen;
        self.layoutWindows();
    }

    fn toggleForegroundWindowManaged(self: *Self, args: HotkeyArgs) void {
        const hwnd = GetForegroundWindow();
        if (self.isWindowManaged(hwnd)) {
            self.removeManagedWindow(hwnd);
        } else {
            self.manageWindow(hwnd, true) catch {};
        }

        self.layoutWindows();
    }
};
