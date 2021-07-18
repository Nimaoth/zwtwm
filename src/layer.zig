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
    program: String,
    title: String,
    rect: RECT,
    index: usize,

    fn deinit(self: *Self) void {
        self.className.deinit();
        self.title.deinit();
        self.program.deinit();
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

    pub fn addWindow(self: *Self, hwnd: HWND, index: ?usize) !void {
        if (self.containsWindow(hwnd)) {
            return;
        }

        var className = try getWindowString(hwnd, GetClassNameA, .{}, root.gWindowStringArena);
        errdefer className.deinit();

        var title = try getWindowString(hwnd, GetWindowTextA, GetWindowTextLengthA, root.gWindowStringArena);
        errdefer title.deinit();

        var program = getWindowExeName(hwnd, root.gWindowStringArena) catch String{ .value = "<unknown>" };

        const rect = try getWindowRect(hwnd);

        if (index) |i| {
            try self.windows.insert(
                std.math.min(i, self.windows.items.len),
                .{
                    .hwnd = hwnd,
                    .className = className,
                    .program = program,
                    .title = title,
                    .rect = rect,
                    .index = i,
                },
            );
        } else {
            try self.windows.append(.{
                .hwnd = hwnd,
                .className = className,
                .program = program,
                .title = title,
                .rect = rect,
                .index = self.windows.items.len,
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

    pub fn moveWindowToIndex(self: *Self, srcIndex: usize, dstIndex: usize) void {
        if (srcIndex == dstIndex or srcIndex >= self.windows.items.len or dstIndex >= self.windows.items.len) {
            return;
        }
        const temp = self.windows.orderedRemove(srcIndex);
        self.windows.insert(dstIndex, temp) catch unreachable;
    }

    pub fn moveWindowToTop(self: *Self, index: usize) void {
        self.moveWindowToIndex(index, 0);
    }

    pub fn sortWindows(self: *Self) void {
        std.sort.sort(Window, self.windows.items, self, Self.compareWindowIndex);
    }

    fn compareWindowIndex(context: *Self, a: Window, b: Window) bool {
        return a.index < b.index;
    }
};
