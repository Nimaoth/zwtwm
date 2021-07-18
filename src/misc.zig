const std = @import("std");

usingnamespace @import("zigwin32").everything;

pub const String = struct {
    value: []const u8,
    allocator: ?*std.mem.Allocator = null,

    pub fn deinit(self: @This()) void {
        if (self.allocator) |allocator| {
            allocator.free(self.value);
        }
    }
};

pub fn expand(self: RECT, amount: i32) RECT {
    return RECT{
        .left = self.left - amount,
        .top = self.top - amount,
        .right = self.right + amount,
        .bottom = self.bottom + amount,
    };
}

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
pub fn getWindowExeName(hwnd: HWND, allocator: *std.mem.Allocator) !String {
    var path = try getWindowExePath(hwnd, allocator);
    path.value = std.fs.path.basename(path.value);
    return path;
}

pub fn getWindowExePath(hwnd: HWND, allocator: *std.mem.Allocator) !String {
    var dwProcId: u32 = 0;
    const threadId = GetWindowThreadProcessId(hwnd, &dwProcId);
    const hProc = OpenProcess(PROCESS_ACCESS_RIGHTS.initFlags(.{
        .QUERY_INFORMATION = 1,
        .VM_READ = 1,
    }), 0, dwProcId);

    if (hProc) |hproc| {
        defer _ = CloseHandle(hproc);

        var buffer: []u8 = try allocator.alloc(u8, 260);
        errdefer allocator.free(buffer);

        const len = K32GetModuleFileNameExA(
            hproc,
            null,
            @ptrCast([*:0]u8, buffer.ptr),
            @intCast(u32, buffer.len),
        );
        if (len == 0) {
            std.log.err("Failed to get process name {}: {}", .{ dwProcId, GetLastError() });
            return error.FailedToGetProcessName;
        }

        const str = buffer[0..len];
        return String{ .value = str, .allocator = allocator };
    } else {
        std.log.err("Failed to open process {}: {}", .{ dwProcId, GetLastError() });
        return error.FailedToOpenProcess;
    }
}

pub fn getMonitorRect() !RECT {
    var rect: RECT = undefined;
    if (SystemParametersInfoA(
        .GETWORKAREA,
        0,
        @ptrCast(*c_void, &rect),
        SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS.initFlags(.{}),
    ) == 0) {
        return error.SystemParametersInfo;
    }
    return rect;
}

pub fn isWindowMaximized(hwnd: HWND) !bool {
    var placement: WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(WINDOWPLACEMENT);
    if (GetWindowPlacement(hwnd, &placement) == 0) {
        return error.FailedToGetWindowPlacement;
    }
    return placement.showCmd == .MAXIMIZE;
}

pub fn getRectWithoutBorder(hwnd: HWND, rect: RECT) RECT {
    const border = getBorderThickness(hwnd) catch return rect;
    return RECT{
        .left = rect.left - border.left,
        .top = rect.top - border.top,
        .right = rect.right + border.right,
        .bottom = rect.bottom + border.bottom,
    };
}

pub fn getBorderThickness(hwnd: HWND) !RECT {
    const rect: RECT = try getWindowRect(hwnd);
    var frame: RECT = undefined;
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
        const overlayRect: RECT = getWindowRect(hwnd) catch return rect;

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

pub fn getWindowRect(hwnd: HWND) !RECT {
    var rect: RECT = undefined;
    if (GetWindowRect(hwnd, &rect) == 0) {
        return error.FailedToGetWindowRect;
    }
    return rect;
}

pub fn getCursorPos() !POINT {
    var cursorPos: POINT = undefined;
    if (GetCursorPos(&cursorPos) == 0) {
        return error.FailedToGetCursorPos;
    }

    return cursorPos;
}

pub fn rectContainsPoint(rect: RECT, point: POINT) bool {
    return point.x >= rect.left and point.x <= rect.right and point.y >= rect.top and point.y <= rect.bottom;
}
