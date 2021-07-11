const std = @import("std");
const root = @import("root");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");
usingnamespace @import("layer.zig");
usingnamespace @import("window_manager.zig");

pub const WINDOW_NAME = "zwtwm";

pub const HotkeyArgs = struct {
    intParam: i64 = 0,
    usizeParam: usize = 0,
    floatParam: f64 = 0.0,
    boolParam: bool = false,
    charParam: i27 = 0,
};

pub const Monitor = struct {
    const Self = @This();

    windowManager: *WindowManager,

    layers: std.ArrayList(Layer),
    currentLayer: usize = 0,
    currentWindow: usize = 0,

    hmonitor: HMONITOR,
    rect: RECT,
    workingArea: RECT,
    overlayWindow: HWND,

    pub fn init(hmonitor: HMONITOR, windowManager: *WindowManager) !Monitor {
        var monitorInfo: MONITORINFO = undefined;
        monitorInfo.cbSize = @sizeOf(MONITORINFO);
        if (GetMonitorInfoA(hmonitor, &monitorInfo) == 0) {
            return error.FailedToGetMonitorInfo;
        }

        var layers = try std.ArrayList(Layer).initCapacity(windowManager.allocator, 10);
        errdefer layers.deinit();
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            try layers.append(try Layer.init(windowManager.allocator));
        }

        const overlayWindow = if (WINDOW_PER_MONITOR)
            try createOverlayWindow(monitorInfo.rcMonitor)
        else
            undefined;
        std.log.info("Created overlay window for monitor: {}", .{overlayWindow});

        return Monitor{
            .windowManager = windowManager,
            .layers = layers,
            .hmonitor = hmonitor,
            .rect = monitorInfo.rcMonitor,
            .workingArea = monitorInfo.rcWork,
            .overlayWindow = overlayWindow,
        };
    }

    pub fn updateMonitorInfo(self: *Self, hmonitor: HMONITOR) void {
        var monitorInfo: MONITORINFO = undefined;
        monitorInfo.cbSize = @sizeOf(MONITORINFO);
        if (GetMonitorInfoA(hmonitor, &monitorInfo) == 0) {
            std.log.err("Failed to get monitor info for {}", .{hmonitor});
            return;
        }

        self.hmonitor = hmonitor;
        self.rect = monitorInfo.rcMonitor;
        self.workingArea = monitorInfo.rcWork;

        if (WINDOW_PER_MONITOR) {
            if (SetWindowPos(
                self.overlayWindow,
                null,
                self.workingArea.left,
                self.workingArea.top,
                self.workingArea.right - self.workingArea.left,
                self.workingArea.bottom - self.workingArea.top,
                SET_WINDOW_POS_FLAGS.initFlags(.{ .NOACTIVATE = 1 }),
            ) == 0) {
                std.log.err("Failed to set window rect of overlay window for monitor {}", .{self.workingArea});
            }
        }
    }

    pub fn getCenter(self: *Self) POINT {
        return .{
            .x = @divTrunc(self.rect.left + self.rect.right, 2),
            .y = @divTrunc(self.rect.top + self.rect.bottom, 2),
        };
    }

    pub fn deinit(self: *Self) void {
        // Show all windows.
        for (self.layers.items) |*layer| {
            for (layer.windows.items) |*window| {
                _ = ShowWindow(window.hwnd, SW_SHOW);
            }
        }

        for (self.layers.items) |*layer| {
            layer.deinit();
        }
        self.layers.deinit();
    }

    fn createOverlayWindow(rect: RECT) !HWND {
        const hInstance = GetModuleHandleA(null);
        const hwnd = CreateWindowExA(
            WINDOW_EX_STYLE.initFlags(.{
                .LAYERED = 1,
                .TRANSPARENT = 1,
                .COMPOSITED = 1,
                .NOACTIVATE = 1,
                .TOPMOST = 1,
            }),
            WINDOW_NAME,
            WINDOW_NAME,
            WINDOW_STYLE.initFlags(.{
                .VISIBLE = 1,
                .MAXIMIZE = 1,
            }),
            rect.left, // x
            rect.top, // y
            rect.right - rect.left, // width
            rect.bottom - rect.top, // height
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

            // Remove title bar and other styles.
            if (SetWindowLongPtrA(window, GWL_STYLE, 0) == 0) {
                return error.FailedToSetWindowLongPtr;
            }

            if (SetWindowPos(
                window,
                null,
                rect.left, // x
                rect.top, // y
                rect.right - rect.left, // width
                rect.bottom - rect.top, // height
                SET_WINDOW_POS_FLAGS.initFlags(.{
                    .NOACTIVATE = 1,
                }),
            ) == 0) {
                return error.FailedToSetWindowPosition;
            }

            _ = ShowWindow(window, SW_SHOW);

            return window;
        }
        return error.FailedToCreateOverlayWindow;
    }

    pub fn isWindowManaged(self: *Self, hwnd: HWND) bool {
        for (self.layers.items) |*layer| {
            if (layer.containsWindow(hwnd)) {
                return true;
            }
        }
        return false;
    }

    pub fn manageWindow(self: *Self, hwnd: HWND, onTop: bool) !void {
        if (self.isWindowManaged(hwnd)) {
            return;
        }

        var layer = self.getCurrentLayer();
        try layer.addWindow(hwnd, onTop);
    }

    pub fn removeManagedWindow(self: *Self, hwnd: HWND) void {
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

    pub fn setCurrentWindow(self: *Self, hwnd: HWND) void {
        if (!self.isWindowManaged(hwnd)) {
            return;
        }

        const layer = self.getCurrentLayer();
        if (!layer.containsWindow(hwnd)) {
            return;
        }

        self.currentWindow = layer.getWindowIndex(hwnd).?;
    }

    pub fn getLayer(self: *Self, index: usize) *Layer {
        std.debug.assert(index < self.layers.items.len);
        return &self.layers.items[index];
    }

    pub fn getCurrentLayer(self: *Self) *Layer {
        return self.getLayer(self.currentLayer);
    }

    pub fn clampCurrentWindowIndex(self: *Self) void {
        const layer = self.getCurrentLayer();
        if (layer.windows.items.len == 0) {
            self.currentWindow = 0;
        } else if (self.currentWindow >= layer.windows.items.len) {
            self.currentWindow = layer.windows.items.len - 1;
        }
    }

    pub fn selectPrevWindow(self: *Self, args: HotkeyArgs) void {
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

    pub fn selectNextWindow(self: *Self, args: HotkeyArgs) void {
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

    pub fn moveCurrentWindowToTop(self: *Self, args: HotkeyArgs) void {
        const layer = self.getCurrentLayer();
        layer.moveWindowToTop(self.currentWindow);
        self.currentWindow = 0;
        self.focusCurrentWindow();
        self.layoutWindows();
    }

    pub fn focusCurrentWindow(self: *Self) void {
        const layer = self.getCurrentLayer();
        if (layer.getWindowAt(self.currentWindow)) |window| {
            _ = SetForegroundWindow(window.hwnd);
        }
    }

    pub fn rerenderOverlay(self: *Self) void {
        _ = InvalidateRect(self.overlayWindow, null, 1);
        _ = RedrawWindow(
            self.overlayWindow,
            null,
            null,
            REDRAW_WINDOW_FLAGS.initFlags(.{ .UPDATENOW = 1 }),
        );
    }

    pub fn layoutWindows(self: *Self) void {
        std.log.notice("Layout windows", .{});

        var monitor = self.workingArea;

        if (root.ONLY_USE_HALF_MONITOR) {
            monitor.width = @divTrunc(monitor.width, 2) - 1;
            monitor.x += monitor.width + 2;
        }

        var layer = self.getCurrentLayer();
        var gap = layer.options.getGap(self.windowManager.options);
        var splitRatio = layer.options.getSplitRatio(self.windowManager.options);

        var area = Rect{
            .x = monitor.left + gap,
            .y = monitor.top + gap,
            .width = monitor.right - monitor.left - gap * 2,
            .height = monitor.bottom - monitor.top - gap * 2,
        };

        const numWindows: i32 = @intCast(i32, layer.windows.items.len);
        if (numWindows > 0) {
            if (layer.fullscreen) {
                const window = layer.getWindowAt(self.currentWindow).?;

                if (isWindowMaximized(window.hwnd) catch false) {
                    std.log.debug("Restoring window because it is maximized: {}", .{window.hwnd});
                    _ = ShowWindow(window.hwnd, SW_RESTORE);
                }

                window.rect = area;

                const visualRect = getRectWithoutBorder(window.hwnd, window.rect);
                if (SetWindowPos(
                    window.hwnd,
                    null,
                    visualRect.x,
                    visualRect.y,
                    visualRect.width,
                    visualRect.height,
                    SET_WINDOW_POS_FLAGS.initFlags(.{}),
                ) == 0) {
                    std.log.err("Failed to set window position of {}", .{window.hwnd});
                }
            } else {
                var hdwp = BeginDeferWindowPos(@intCast(i32, numWindows));
                if (hdwp == 0) {
                    return;
                }

                var x: i32 = area.x;
                for (layer.windows.items) |*window, i| {
                    if (isWindowMaximized(window.hwnd) catch false) {
                        std.log.debug("Restoring window because it is maximized: {}", .{window.hwnd});
                        _ = ShowWindow(window.hwnd, SW_RESTORE);
                    }

                    var windowArea = area;
                    if (i + 1 < layer.windows.items.len) {
                        // More windows after this one.
                        const horizontalOrVertical = if (root.ONLY_USE_HALF_MONITOR) 1 else 0;
                        if (@mod(i, 2) == horizontalOrVertical) {
                            const ratio = if (i == 0) splitRatio else 0.5;
                            const split = @floatToInt(i32, @intToFloat(f64, windowArea.width) * ratio);

                            area.x += split + gap;
                            area.width -= split + gap;
                            windowArea.width = split;
                        } else {
                            const ratio = if (i == 0) splitRatio else 0.5;
                            const split = @floatToInt(i32, @intToFloat(f64, windowArea.height) * ratio);

                            area.y += split + gap;
                            area.height -= split + gap;
                            windowArea.height = split;
                        }
                    }

                    window.rect = windowArea;

                    const visualRect = getRectWithoutBorder(window.hwnd, window.rect);
                    hdwp = DeferWindowPos(
                        hdwp,
                        window.hwnd,
                        null,
                        visualRect.x,
                        visualRect.y,
                        visualRect.width,
                        visualRect.height,
                        SET_WINDOW_POS_FLAGS.initFlags(.{
                            .NOOWNERZORDER = 1,
                            .SHOWWINDOW = 1,
                        }),
                    );

                    if (hdwp == 0) {
                        return;
                    }
                }

                _ = EndDeferWindowPos(hdwp);
            }

            for (layer.windows.items) |*window| {
                _ = InvalidateRect(window.hwnd, null, 1);
            }
        }

        if (WINDOW_PER_MONITOR) {
            self.rerenderOverlay();
        } else {
            self.windowManager.rerenderOverlay();
        }

        if (root.LOG_LAYERS) {
            std.debug.print("Monitor {}\n", .{self.rect});
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

    pub fn renderOverlay(self: *Self, hdc: HDC, region: RECT, isCurrent: bool, convertToClient: bool) void {
        var brushFocused = CreateSolidBrush(rgb(200, 50, 25));
        defer _ = DeleteObject(brushFocused);
        var brushUnfocused = CreateSolidBrush(rgb(25, 50, 200));
        defer _ = DeleteObject(brushUnfocused);
        var brushUnfocused2 = CreateSolidBrush(rgb(255, 0, 255));
        defer _ = DeleteObject(brushUnfocused2);

        var layer = self.getCurrentLayer();
        const gap = layer.options.getGap(self.windowManager.options);

        var j: i32 = 0;
        const monitorRect = if (convertToClient) screenToClient(self.overlayWindow, self.rect) else self.rect;
        while (j < 2) : (j += 1) {
            const winRect2 = Rect.fromRECT(monitorRect).expand(-j).toRECT();
            const brush = if (isCurrent) brushFocused else brushUnfocused2;
            _ = FrameRect(hdc, &winRect2, brush);
        }

        for (layer.windows.items) |*window, i| {
            const winRect = if (convertToClient) Rect.fromRECT(screenToClient(self.overlayWindow, window.rect.toRECT())) else window.rect;

            if (i == self.currentWindow) {
                const brush = if (window.hwnd == GetForegroundWindow()) brushFocused else brushUnfocused;

                var k: i32 = 0;
                while (k < 2) : (k += 1) {
                    const winRect2 = winRect.expand(-k).toRECT();
                    _ = FrameRect(hdc, &winRect2, brush);
                }
            }
        }
    }

    pub fn updateWindowVisibility(self: *Self, hwnd: HWND) void {
        setWindowVisibility(hwnd, self.getCurrentLayer().containsWindow(hwnd));
    }

    pub fn moveCurrentWindowToLayer(self: *Self, args: HotkeyArgs) void {
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
            setWindowVisibility(window.hwnd, false);
        }

        self.clampCurrentWindowIndex();
        self.focusCurrentWindow();
        self.layoutWindows();
    }

    pub fn toggleCurrentWindowOnLayer(self: *Self, args: HotkeyArgs) void {
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

    pub fn switchLayer(self: *Self, args: HotkeyArgs) void {
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
                setWindowVisibility(window.hwnd, false);
            }
        }

        for (toLayer.windows.items) |*window| {
            // This doesn't do anything if the window is already visible.
            setWindowVisibility(window.hwnd, true);
        }

        self.currentLayer = args.usizeParam;
        self.currentWindow = 0;
        self.focusCurrentWindow();
        self.layoutWindows();
    }

    pub fn toggleWindowFullscreen(self: *Self, args: HotkeyArgs) void {
        var layer = self.getCurrentLayer();
        layer.fullscreen = !layer.fullscreen;
        self.layoutWindows();
    }
};
