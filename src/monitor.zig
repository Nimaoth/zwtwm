const std = @import("std");
const root = @import("root");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");
usingnamespace @import("util.zig");
usingnamespace @import("layer.zig");
usingnamespace @import("window_manager.zig");
usingnamespace @import("config.zig");

pub const WINDOW_NAME = "zwtwm";

pub const Monitor = struct {
    const Self = @This();

    windowManager: *WindowManager,

    layers: std.ArrayList(Layer),
    currentLayer: usize = 0,

    index: usize = 0,
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

        const overlayWindow = try createOverlayWindow(monitorInfo.rcMonitor);
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

    pub fn manageWindow(self: *Self, hwnd: HWND, index: ?usize) !void {
        if (self.isWindowManaged(hwnd)) {
            return;
        }

        var layer = self.getCurrentLayer();
        try layer.addWindow(hwnd, index);
        if (index) |i| {
            layer.currentWindow = i;
        }
    }

    pub fn removeManagedWindow(self: *Self, hwnd: HWND) void {
        if (!self.isWindowManaged(hwnd)) {
            return;
        }

        for (self.layers.items) |*layer, i| {
            const removedIndex = layer.removeWindow(hwnd);

            if (removedIndex < layer.currentWindow) {
                layer.currentWindow -= 1;
            }
            layer.clampCurrentWindowIndex();
        }
    }

    pub fn setCurrentWindow(self: *Self, hwnd: HWND) void {
        const layer = self.getCurrentLayer();

        if (layer.getWindowIndex(hwnd)) |index| {
            layer.currentWindow = index;
        }
    }

    pub fn getLayer(self: *Self, index: usize) *Layer {
        std.debug.assert(index < self.layers.items.len);
        return &self.layers.items[index];
    }

    pub fn getCurrentLayer(self: *Self) *Layer {
        return self.getLayer(self.currentLayer);
    }

    pub fn getCurrentWindow(self: *Self) ?*Window {
        return self.getCurrentLayer().getCurrentWindow();
    }

    pub fn selectPrevWindow(self: *Self) void {
        const layer = self.getCurrentLayer();
        if (layer.windows.items.len == 0) {
            layer.currentWindow = 0;
        } else {
            layer.currentWindow = moveIndex(layer.currentWindow, -1, layer.windows.items.len, self.windowManager.config.wrapWindows);
        }

        self.focusCurrentWindow();
        self.layoutWindows();
        self.rerenderOverlay();
    }

    pub fn selectNextWindow(self: *Self) void {
        const layer = self.getCurrentLayer();
        if (layer.windows.items.len == 0) {
            layer.currentWindow = 0;
        } else {
            layer.currentWindow = moveIndex(layer.currentWindow, 1, layer.windows.items.len, self.windowManager.config.wrapWindows);
        }

        self.focusCurrentWindow();
        self.layoutWindows();
        self.rerenderOverlay();
    }

    pub fn moveWindowToIndex(self: *Self, srcIndex: usize, dstIndex: usize) void {
        const layer = self.getCurrentLayer();
        layer.moveWindowToIndex(srcIndex, dstIndex);
        layer.currentWindow = dstIndex;
    }

    pub fn moveCurrentWindowUp(self: *Self) void {
        const layer = self.getCurrentLayer();
        const dstIndex = moveIndex(layer.currentWindow, -1, layer.windows.items.len, self.windowManager.config.wrapWindows);
        layer.moveWindowToIndex(layer.currentWindow, dstIndex);
        layer.currentWindow = dstIndex;
    }

    pub fn moveCurrentWindowDown(self: *Self) void {
        const layer = self.getCurrentLayer();
        const dstIndex = moveIndex(layer.currentWindow, 1, layer.windows.items.len, self.windowManager.config.wrapWindows);
        layer.moveWindowToIndex(layer.currentWindow, dstIndex);
        layer.currentWindow = dstIndex;
    }

    pub fn moveCurrentWindowToTop(self: *Self) void {
        self.moveWindowToIndex(self.getCurrentLayer().currentWindow, 0);
    }

    pub fn moveCurrentWindowToIndex(self: *Self, index: usize) void {
        self.moveWindowToIndex(self.getCurrentLayer().currentWindow, index);
    }

    pub fn bringCurrentWindowToTop(self: *Self) void {
        if (self.getCurrentWindow()) |window| {
            _ = BringWindowToTop(window.hwnd);
        }
    }
    pub fn focusCurrentWindow(self: *Self) void {
        const layer = self.getCurrentLayer();
        if (layer.getWindowAt(layer.currentWindow)) |window| {
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
        var monitorArea = self.workingArea;

        if (root.ONLY_USE_HALF_MONITOR) {
            monitorArea.left = @divTrunc(monitorArea.left + monitorArea.right, 2);
        }

        var layer = self.getCurrentLayer();
        const gap = self.windowManager.config.gap;
        const splitRatio = self.windowManager.config.splitRatio;
        const maximizeFullSizeWindows = self.windowManager.config.maximizeFullSizeWindows;
        const noGapForSingleWindow = self.windowManager.config.noGapForSingleWindow;

        const monitorAreaWithGap = RECT{
            .left = monitorArea.left + gap,
            .top = monitorArea.top + gap,
            .right = monitorArea.right - gap,
            .bottom = monitorArea.bottom - gap,
        };
        var area = monitorAreaWithGap;

        const singleWindow = layer.fullscreen or (layer.windows.items.len == 1);

        const numWindows: i32 = @intCast(i32, layer.windows.items.len);
        if (numWindows > 0) {
            var currentWindowFullscreen = false;
            if (self.getCurrentWindow()) |window| {
                currentWindowFullscreen = windowHasRect(window.hwnd, self.rect) catch false;
            }

            var hdwp = BeginDeferWindowPos(@intCast(i32, numWindows));
            if (hdwp == 0) {
                return;
            }

            var x: i32 = area.left;
            for (layer.windows.items) |*window, i| {
                if (windowHasRect(window.hwnd, self.rect) catch false) {
                    // Special case: window is in true fullscreen mode (meaning the entire screen, including the task bar).
                    // In this case we don't want to mess with the window.
                    window.rect = self.rect;
                    continue;
                }

                if (singleWindow and maximizeFullSizeWindows) {
                    window.rect = monitorArea;
                    maximizeWindowOnMonitor(window.hwnd, self.hmonitor) catch {};
                    continue;
                }

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
                        const split = @floatToInt(i32, @intToFloat(f64, windowArea.right - windowArea.left) * ratio);

                        area.left += split + gap;
                        windowArea.right = windowArea.left + split;
                    } else {
                        const ratio = if (i == 0) splitRatio else 0.5;
                        const split = @floatToInt(i32, @intToFloat(f64, windowArea.bottom - windowArea.top) * ratio);

                        area.top += split + gap;
                        windowArea.bottom = windowArea.top + split;
                    }
                }

                if (singleWindow) {
                    windowArea = if (noGapForSingleWindow) monitorArea else monitorAreaWithGap;
                }

                window.rect = windowArea;

                const visualRect = getRectWithoutBorder(window.hwnd, window.rect);
                hdwp = DeferWindowPos(
                    hdwp,
                    window.hwnd,
                    null,
                    visualRect.left,
                    visualRect.top,
                    visualRect.right - visualRect.left,
                    visualRect.bottom - visualRect.top,
                    SET_WINDOW_POS_FLAGS.initFlags(.{
                        .NOOWNERZORDER = 1,
                        .SHOWWINDOW = if ((i == layer.currentWindow) or (!singleWindow and !currentWindowFullscreen)) 1 else 0,
                        .NOACTIVATE = if ((i == layer.currentWindow) or (!singleWindow and !currentWindowFullscreen)) 0 else 1,
                        .NOZORDER = if ((i == layer.currentWindow) or (!singleWindow and !currentWindowFullscreen)) 0 else 1,
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

        if (root.LOG_LAYERS) {
            std.log.info("Monitor {}, {}, {}", .{ self.index, self.hmonitor, self.rect });
            for (self.layers.items) |*l, i| {
                if (l.isEmpty()) continue;

                std.log.info(" Layer {}", .{i});
                for (l.windows.items) |*window| {
                    std.log.info("  {}: '{s}', '{s}', '{s}', {}", .{ window.hwnd, window.program.value, window.className.value, window.title.value, window.rect });
                }
            }
        }
    }

    pub fn renderOverlay(self: *Self, hdc: HDC, region: RECT, isCurrent: bool, convertToClient: bool) void {
        const config = &self.windowManager.config;

        var brushFocused = CreateSolidBrush(config.windowFocusedBorder.color);
        defer _ = DeleteObject(brushFocused);
        var brushUnfocused = CreateSolidBrush(config.windowUnfocusedBorder.color);
        defer _ = DeleteObject(brushUnfocused);
        var brushCurrentMonitor = CreateSolidBrush(config.monitorBorder.color);
        defer _ = DeleteObject(brushCurrentMonitor);

        var layer = self.getCurrentLayer();

        if (isCurrent) {
            if (self.getCurrentWindow()) |window| {
                if (windowHasRect(window.hwnd, self.rect) catch false) {
                    // Current window is fullscreen.
                    if (config.disableOutlineForFullscreen) {
                        return;
                    }
                }
            }
            const foregroundWindow = GetForegroundWindow();

            {
                // monitor border
                var monitorRect = if (convertToClient) screenToClient(self.overlayWindow, self.rect) else self.rect;
                var i: i32 = 0;
                while (i < config.monitorBorder.thickness) : (i += 1) {
                    const rect = expand(monitorRect, -i);
                    _ = FrameRect(hdc, &rect, brushCurrentMonitor);
                }
            }

            // Render outline except if there is only one window or a fullscreen window and outlines for single windows are disabled.
            if ((layer.windows.items.len != 1 and !layer.fullscreen) or !config.disableOutlineForSingleWindow) {
                for (layer.windows.items) |*window, windowIndex| {
                    const winRect = if (convertToClient) screenToClient(self.overlayWindow, window.rect) else window.rect;

                    if (windowIndex == layer.currentWindow) {
                        var brush = brushUnfocused;
                        var thickness = config.windowUnfocusedBorder.thickness;

                        if (window.hwnd == foregroundWindow) {
                            brush = brushFocused;
                            thickness = config.windowFocusedBorder.thickness;
                        }

                        {
                            // window border
                            var i: i32 = 0;
                            while (i < thickness) : (i += 1) {
                                const rect = expand(winRect, -i);
                                _ = FrameRect(hdc, &rect, brush);
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn updateAllWindowVisibilities(self: *Self) void {
        const currentLayer = self.getCurrentLayer();
        for (self.layers.items) |*layer| {
            for (layer.windows.items) |*window| {
                if (layer == currentLayer) {
                    setWindowVisibility(window.hwnd, true);
                } else if (!currentLayer.containsWindow(window.hwnd)) {
                    setWindowVisibility(window.hwnd, false);
                }
            }
        }
    }

    pub fn updateWindowVisibility(self: *Self, hwnd: HWND) void {
        setWindowVisibility(hwnd, self.getCurrentLayer().containsWindow(hwnd));
    }

    pub fn moveCurrentWindowToLayer(self: *Self, dstIndex: usize) void {
        std.log.info("Move current window to layer: {}", .{dstIndex});
        const newLayer = dstIndex;
        if (newLayer == self.currentLayer) return;

        if (newLayer < 0 or newLayer >= self.layers.items.len) {
            std.log.err("Can't move window to layer {}: outside of range", .{dstIndex});
            return;
        }

        var fromLayer = self.getCurrentLayer();
        var toLayer = self.getLayer(@intCast(usize, newLayer));

        if (fromLayer.getWindowAt(fromLayer.currentWindow)) |window| {
            toLayer.addWindow(window.hwnd, null) catch unreachable;
            _ = fromLayer.removeWindow(window.hwnd);
            setWindowVisibility(window.hwnd, false);
        }

        fromLayer.clampCurrentWindowIndex();
        toLayer.clampCurrentWindowIndex();
        self.focusCurrentWindow();
        self.layoutWindows();
        self.rerenderOverlay();
    }

    pub fn toggleCurrentWindowOnLayer(self: *Self, dstIndex: usize) void {
        std.log.info("Toggle current window on layer: {}", .{dstIndex});
        if (dstIndex == self.currentLayer) return;

        if (dstIndex < 0 or dstIndex >= self.layers.items.len) {
            std.log.err("Layer {}: outside of range", .{dstIndex});
            return;
        }

        var layer = self.getCurrentLayer();
        var toLayer = self.getLayer(dstIndex);

        if (layer.getWindowAt(layer.currentWindow)) |window| {
            if (toLayer.containsWindow(window.hwnd)) {
                _ = toLayer.removeWindow(window.hwnd);
            } else {
                toLayer.addWindow(window.hwnd, null) catch unreachable;
            }
        }
    }

    pub fn switchLayer(self: *Self, dstIndex: usize, windowsToHide: *std.ArrayList(*Window)) void {
        const newLayer = dstIndex;
        if (newLayer == self.currentLayer) return;

        if (newLayer < 0 or newLayer >= self.layers.items.len) {
            std.log.err("Can't switch to layer {}: outside of range", .{dstIndex});
            return;
        }

        var fromLayer = self.getCurrentLayer();
        var toLayer = self.getLayer(@intCast(usize, newLayer));

        for (toLayer.windows.items) |*window| {
            // This doesn't do anything if the window is already visible.
            setWindowVisibility(window.hwnd, true);
        }

        self.currentLayer = dstIndex;

        // Hide windows in the current layer except ones that are also on the target layer.
        for (fromLayer.windows.items) |*window| {
            if (!toLayer.containsWindow(window.hwnd)) {
                windowsToHide.append(window) catch {};
            }
        }
    }

    pub fn toggleWindowFullscreen(self: *Self) void {
        var layer = self.getCurrentLayer();
        layer.fullscreen = !layer.fullscreen;
        self.layoutWindows();
        self.rerenderOverlay();
    }

    pub fn getWindowIndexContainingPoint(self: *Self, point: POINT, excludeHwnd: ?HWND) ?usize {
        for (self.getCurrentLayer().windows.items) |window, index| {
            if (window.hwnd == excludeHwnd) continue;

            if (getWindowRect(window.hwnd) catch null) |rect| {
                if (rectContainsPoint(rect, point)) {
                    return index;
                }
            }
        }

        return null;
    }

    pub fn getWindowContainingPoint(self: *Self, point: POINT, excludeHwnd: ?HWND) ?*Window {
        if (self.getWindowIndexContainingPoint(point, excludeHwnd)) |index| {
            return self.getCurrentLayer().getWindowAt(index);
        }
        return null;
    }

    pub fn isPointOnMonitor(self: *Self, point: POINT) bool {
        return rectContainsPoint(self.rect, point);
    }

    pub fn isPointInWorkingArea(self: *Self, point: POINT) bool {
        return rectContainsPoint(self.workingArea, point);
    }
};
