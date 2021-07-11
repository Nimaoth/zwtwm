const std = @import("std");

usingnamespace @import("zigwin32").everything;

pub const WINDOW_PER_MONITOR = true;

pub const String = struct {
    value: []const u8,
    allocator: ?*std.mem.Allocator = null,

    pub fn deinit(self: @This()) void {
        if (self.allocator) |allocator| {
            allocator.free(self.value);
        }
    }
};

pub const Rect = struct {
    const Self = @This();

    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn fromRECT(rect: RECT) Self {
        return Self{
            .x = rect.left,
            .y = rect.top,
            .width = rect.right - rect.left,
            .height = rect.bottom - rect.top,
        };
    }

    pub fn toRECT(self: Self) RECT {
        return RECT{
            .left = self.x,
            .top = self.y,
            .right = self.x + self.width,
            .bottom = self.y + self.height,
        };
    }

    pub fn expand(self: Self, amount: i32) Self {
        return Self{
            .x = self.x - amount,
            .y = self.y - amount,
            .width = self.width + amount + amount,
            .height = self.height + amount + amount,
        };
    }
};

pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return @intCast(u32, r) | (@intCast(u32, g) << 8) | (@intCast(u32, b) << 16);
}

pub fn getWindowString(hwnd: HWND, comptime func: anytype, comptime lengthFunc: anytype, allocator: *std.mem.Allocator) !String {
    var size: usize = 256;

    if (@typeInfo(@TypeOf(lengthFunc)) == .Fn) {
        size = @intCast(usize, lengthFunc(hwnd)) + 1;
    }

    while (true) {
        var buffer: []u8 = try allocator.alloc(u8, size);
        const len = @intCast(u64, func(hwnd, @ptrCast([*:0]u8, buffer.ptr), @intCast(i32, buffer.len)));
        if (len == 0) {
            return String{ .value = "" };
        }

        if (len >= size - 1) {
            allocator.free(buffer);
            size *= 2;
            continue;
        }

        const str = buffer[0..len];
        return String{ .value = str, .allocator = allocator };
    }
}

pub fn getMonitorRect() !Rect {
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
}

pub fn isWindowMaximized(hwnd: HWND) !bool {
    var placement: WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(WINDOWPLACEMENT);
    if (GetWindowPlacement(hwnd, &placement) == 0) {
        return error.FailedToGetWindowPlacement;
    }
    return placement.showCmd == .MAXIMIZE;
}

pub fn getRectWithoutBorder(hwnd: HWND, rect: Rect) Rect {
    const border = getBorderThickness(hwnd) catch return rect;
    const newRect = Rect{
        .x = rect.x - border.left,
        .y = rect.y - border.top,
        .width = rect.width + border.left + border.right,
        .height = rect.height + border.top + border.bottom,
    };
    //std.log.debug("\nrect: {}\nbord: {}\n new: {}", .{ rect, border, newRect });
    return newRect;
}

pub fn getBorderThickness(hwnd: HWND) !RECT {
    var rect: RECT = undefined;
    var frame: RECT = undefined;
    if (GetWindowRect(hwnd, &rect) == 0) {
        return error.FailedToGetWindowRect;
    }
    if (DwmGetWindowAttribute(
        hwnd,
        @enumToInt(DWMWA_EXTENDED_FRAME_BOUNDS),
        &frame,
        @intCast(u32, @sizeOf(RECT)),
    ) != 0) {
        return error.FailedToGetWindowAttribute;
    }

    return RECT{
        .left = frame.left - rect.left,
        .top = frame.top - rect.top,
        .right = rect.right - frame.right,
        .bottom = rect.bottom - frame.bottom,
    };
}

pub fn setWindowVisibility(hwnd: HWND, shouldBeVisible: bool) void {
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

    if (shouldBeVisible) {
        _ = ShowWindow(hwnd, SW_RESTORE);
    } else {
        _ = ShowWindow(hwnd, SW_HIDE);
    }
}

pub fn screenToClient(hwnd: HWND, rect: RECT) RECT {
    if (true) {
        var overlayRect: RECT = undefined;
        _ = GetWindowRect(hwnd, &overlayRect);

        return RECT{
            .left = rect.left - overlayRect.left,
            .right = rect.right - overlayRect.left,
            .top = rect.top - overlayRect.top,
            .bottom = rect.bottom - overlayRect.top,
        };
    } else {
        var result = rect;

        var temp = POINT{ .x = rect.left, .y = rect.top };
        std.debug.assert(ScreenToClient(hwnd, &temp) != 0);
        result.left = temp.x;
        result.top = temp.y;

        temp = POINT{ .x = rect.right, .y = rect.bottom };
        std.debug.assert(ScreenToClient(hwnd, &temp) != 0);
        result.right = temp.x;
        result.bottom = temp.y;

        return rect;
    }
}
