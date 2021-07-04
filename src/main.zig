const std = @import("std");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const HK_CLOSE_WINDOW: i32 = 42069;

var gWindowManager: WindowManager = undefined;
var gWindowStringArena: *std.mem.Allocator = undefined;

const CWM_WINDOW_CREATED = WM_USER + 1;

const Hotkey = struct {
    key: u32,
    mods: HOT_KEY_MODIFIERS,
    func: fn (*WindowManager) void,
};

pub fn main() anyerror!void {
    defer {
        _ = gpa.deinit();
    }
    var windowStringArena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer windowStringArena.deinit();
    gWindowStringArena = &windowStringArena.allocator;

    gWindowManager = try WindowManager.init(&gpa.allocator);
    defer gWindowManager.deinit();

    try gWindowManager.setup();

    const defaultHotkeys = [_]Hotkey{
        .{
            .key = @intCast(i32, 'G'),
            .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            .func = WindowManager.layoutWindows,
        },

        .{
            .key = @intCast(i32, 'H'),
            .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            .func = WindowManager.increaseGap,
        },
        .{
            .key = @intCast(i32, 'F'),
            .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            .func = WindowManager.decreaseGap,
        },

        .{
            .key = @intCast(i32, 'S'),
            .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            .func = WindowManager.decreaseSplit,
        },
        .{
            .key = @intCast(i32, 'D'),
            .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            .func = WindowManager.increaseSplit,
        },

        .{
            .key = @intCast(i32, 'N'),
            .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            .func = WindowManager.selectPrevWindow,
        },
        .{
            .key = @intCast(i32, 'T'),
            .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            .func = WindowManager.selectNextWindow,
        },

        .{
            .key = @intCast(i32, 'K'),
            .mods = HOT_KEY_MODIFIERS.initFlags(.{ .CONTROL = 1, .ALT = 1, .SHIFT = 1, .NOREPEAT = 1 }),
            .func = WindowManager.moveCurrentWindowToTop,
        },
    };
    for (defaultHotkeys[0..]) |hotkey| {
        try gWindowManager.registerHotkey(hotkey);
    }

    var msg: MSG = undefined;
    while (GetMessageA(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageA(&msg);
    }
}

const Window = struct {
    const Self = @This();

    hwnd: HWND,
    className: String,
    title: String,
    rect: Rect,

    fn deinit(self: *Self) void {
        self.className.deinit();
        self.title.deinit();
    }
};

const Layer = struct {
    const Self = @This();

    windows: std.ArrayList(Window),

    pub fn init(allocator: *std.mem.Allocator) !Self {
        return Self{
            .windows = std.ArrayList(Window).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.windows.items) |*window| {
            window.deinit();
        }
        self.windows.deinit();
    }

    pub fn isEmpty(self: *Self) bool {
        return self.windows.items.len == 0;
    }

    pub fn containsWindow(self: *Self, hwnd: HWND) bool {
        for (self.windows.items) |*window| {
            if (window.hwnd == hwnd) return true;
        }
        return false;
    }

    pub fn getWindowIndex(self: *Self, hwnd: HWND) ?usize {
        for (self.windows.items) |*window, i| {
            if (window.hwnd == hwnd) return i;
        }
        return null;
    }

    pub fn removeWindow(self: *Self, hwnd: HWND) usize {
        defer std.debug.assert(!self.containsWindow(hwnd));
        for (self.windows.items) |*window, i| {
            if (window.hwnd == hwnd) {
                var win = self.windows.orderedRemove(i);
                win.deinit();
                return i;
            }
        }

        return std.math.maxInt(usize);
    }

    pub fn addWindow(self: *Self, hwnd: HWND) !void {
        if (self.containsWindow(hwnd)) {
            return;
        }

        var className = try getWindowString(hwnd, GetClassNameA, .{}, gWindowStringArena);
        errdefer className.deinit();

        var title = try getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, gWindowStringArena);
        errdefer title.deinit();

        var rect: RECT = undefined;
        _ = GetWindowRect(hwnd, &rect);

        try self.windows.append(.{
            .hwnd = hwnd,
            .className = className,
            .title = title,
            .rect = Rect.fromRECT(rect),
        });
    }

    pub fn getWindowAt(self: *Self, index: usize) ?*Window {
        if (index >= self.windows.items.len) {
            return null;
        }
        return &self.windows.items[index];
    }

    pub fn getWindow(self: *Self, hwnd: HWND) ?*Window {
        for (self.windows.items) |*window| {
            if (window.hwnd == hwnd) {
                return window;
            }
        }

        return null;
    }

    pub fn moveWindowToTop(self: *Self, index: usize) void {
        if (index == 0 or index >= self.windows.items.len) {
            return;
        }
        const temp = self.windows.orderedRemove(index);
        self.windows.insert(0, temp) catch unreachable;
    }
};

const WindowManager = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,

    hotkeys: std.ArrayList(Hotkey),
    layers: std.ArrayList(Layer),
    currentLayer: usize = 0,
    currentWindow: usize = 0,

    overlayWindow: HWND,

    hHookObjectCreate: HWINEVENTHOOK,
    hHookObjectHide: HWINEVENTHOOK,
    hHookObjectFocus: HWINEVENTHOOK,
    hHookObjectMoved: HWINEVENTHOOK,

    // Settings
    ignoredClassNames: std.StringHashMap(bool),
    gap: i32 = 5,
    splitRatio: f64 = 0.66,

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
            EVENT_OBJECT_HIDE,
            EVENT_OBJECT_HIDE,
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
    }

    pub fn registerHotkey(self: *Self, hotkey: Hotkey) !void {
        if (RegisterHotKey(
            self.overlayWindow,
            @intCast(i32, self.hotkeys.items.len),
            hotkey.mods,
            hotkey.key,
        ) == 0) {
            std.log.err("Failed to register hotkey {} ({})", .{ hotkey.key, hotkey.mods });
            return;
        }

        try self.hotkeys.append(hotkey);
    }

    pub fn runHotkey(self: *Self, index: usize) void {
        if (index >= self.hotkeys.items.len) {
            std.log.err("Failed to run hotkey {}: No such hotkey.", .{index});
            return;
        }

        self.hotkeys.items[index].func(self);
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
        const className = getWindowString(hwnd, GetClassNameA, .{}, gWindowStringArena) catch unreachable;
        defer className.deinit();
        const windowTitle = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, gWindowStringArena) catch unreachable;
        defer windowTitle.deinit();

        std.log.debug("window event: {}, {} ({s}, '{s}')", .{ event, hwnd, className.value, windowTitle.value });

        switch (event) {
            EVENT_OBJECT_SHOW => {
                if (!self.isWindowManageable(hwnd)) {
                    return;
                }
                std.log.debug("window is manageable: {}, {} ({s}, '{s}')", .{ event, hwnd, className.value, windowTitle.value });

                self.manageWindow(hwnd) catch {
                    std.log.err("Failed to manage window {}:{s}: '{s}'", .{ hwnd, className.value, windowTitle.value });
                    return;
                };

                self.layoutWindows();
            },

            EVENT_OBJECT_HIDE => {
                self.removeManagedWindow(hwnd);
                self.layoutWindows();
                self.focusCurrentWindow();
            },

            EVENT_SYSTEM_FOREGROUND => {
                if (self.isWindowManaged(hwnd)) {
                    self.setCurrentWindow(hwnd);
                }
                self.rerenderOverlay();
            },

            EVENT_SYSTEM_MOVESIZESTART,
            EVENT_SYSTEM_MOVESIZEEND,
            => {
                if (self.isWindowManaged(hwnd)) {
                    var rect: RECT = undefined;
                    _ = GetWindowRect(hwnd, &rect);
                    self.getWindow(hwnd).?.rect = Rect.fromRECT(rect);
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

        gWindowManager.handleWindowEvent(event, hwnd);
        //_ = PostMessageA(gWindowManager.overlayWindow, CWM_WINDOW_CREATED, @ptrToInt(hwnd), @intCast(isize, event));
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
                std.log.info("WM_PAINT", .{});
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

    fn handleEnumWindows(
        hwnd: HWND,
        param: LPARAM,
    ) callconv(@import("std").os.windows.WINAPI) BOOL {
        var self = @intToPtr(*WindowManager, @bitCast(usize, param));

        const className = getWindowString(hwnd, GetClassNameA, .{}, gWindowStringArena) catch return 1;
        defer className.deinit();
        if (self.ignoredClassNames.get(className.value)) |_| {
            return 1;
        }

        if (!self.isWindowManageable(hwnd)) {
            return 1;
        }

        const windowTitle = getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, gWindowStringArena) catch return 1;
        defer windowTitle.deinit();

        var rect: RECT = undefined;
        if (GetWindowRect(hwnd, &rect) == 0) {
            return 1;
        }

        self.manageWindow(hwnd) catch {
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

        const className = getWindowString(hwnd, GetClassNameA, .{}, gWindowStringArena) catch return false;
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

        if (true) {
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
            std.log.debug("isManageable: window is disabled", .{});
            return false;
        }
        if (IsWindowVisible(hwnd) == 0) {
            std.log.debug("isManageable: window is not visible", .{});
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

    fn manageWindow(self: *Self, hwnd: HWND) !void {
        if (self.isWindowManaged(hwnd)) {
            return;
        }

        var layer = self.getCurrentLayer();
        try layer.addWindow(hwnd);
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

    fn selectPrevWindow(self: *Self) void {
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

    fn selectNextWindow(self: *Self) void {
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

    fn moveCurrentWindowToTop(self: *Self) void {
        std.log.info("moveCurrentWindowToTop", .{});
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
        const monitor = getMonitorRect() catch return;

        var workingArea = Rect{
            .x = monitor.x + self.gap,
            .y = monitor.y + self.gap,
            .width = monitor.width - self.gap * 2,
            .height = monitor.height - self.gap * 2,
        };

        var layer = self.getCurrentLayer();

        const numWindows: i32 = @intCast(i32, layer.windows.items.len);
        if (numWindows > 0) {
            const windowWidth = @divTrunc(workingArea.width - (numWindows - 1) * self.gap, numWindows);
            const windowHeight = workingArea.height;

            var hdwp = BeginDeferWindowPos(@intCast(i32, numWindows));
            if (hdwp == 0) {
                return;
            }

            var x: i32 = workingArea.x;
            for (layer.windows.items) |*window, i| {
                var area = workingArea;
                if (i + 1 < layer.windows.items.len) {
                    // More windows after this one.
                    if (@mod(i, 2) == 0) {
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

        self.rerenderOverlay();
    }

    fn increaseGap(self: *Self) void {
        self.gap += 5;
        std.log.info("Inc gap: {}", .{self.gap});
        self.updateWindowInfos();
        self.layoutWindows();
    }

    fn decreaseGap(self: *Self) void {
        self.gap -= 5;
        if (self.gap < 0) {
            self.gap = 0;
        }
        std.log.info("Dec gap: {}", .{self.gap});
        self.updateWindowInfos();
        self.layoutWindows();
    }

    fn increaseSplit(self: *Self) void {
        self.splitRatio += 0.025;
        if (self.splitRatio > 0.9) {
            self.splitRatio = 0.9;
        }
        std.log.info("Inc split: {}", .{self.splitRatio});
        self.updateWindowInfos();
        self.layoutWindows();
    }

    fn decreaseSplit(self: *Self) void {
        self.splitRatio -= 0.025;
        if (self.splitRatio < 0.1) {
            self.splitRatio = 0.1;
        }
        std.log.info("Dec split: {}", .{self.splitRatio});
        self.updateWindowInfos();
        self.layoutWindows();
    }
};
