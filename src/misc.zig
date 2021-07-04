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
