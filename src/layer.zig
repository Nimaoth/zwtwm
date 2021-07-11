const std = @import("std");
const root = @import("root");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");

pub const Options = struct {
    const Self = @This();

    gap: ?i32 = null,
    splitRatio: ?f64 = null,

    pub fn getGap(self: Self, fallback: Options) i32 {
        return self.gap orelse (fallback.gap orelse 5);
    }

    pub fn getSplitRatio(self: Self, fallback: Options) f64 {
        return self.splitRatio orelse (fallback.splitRatio orelse 0.66);
    }
};

pub const Window = struct {
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

pub const Layer = struct {
    const Self = @This();

    windows: std.ArrayList(Window),
    fullscreen: bool = false,
    options: Options = .{},

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

    pub fn addWindow(self: *Self, hwnd: HWND, onTop: bool) !void {
        if (self.containsWindow(hwnd)) {
            return;
        }

        var className = try getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena);
        errdefer className.deinit();

        var title = try getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, root.gWindowStringArena);
        errdefer title.deinit();

        var rect: RECT = undefined;
        _ = GetWindowRect(hwnd, &rect);

        if (onTop) {
            try self.windows.insert(0, .{
                .hwnd = hwnd,
                .className = className,
                .title = title,
                .rect = Rect.fromRECT(rect),
            });
        } else {
            try self.windows.append(.{
                .hwnd = hwnd,
                .className = className,
                .title = title,
                .rect = Rect.fromRECT(rect),
            });
        }
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
