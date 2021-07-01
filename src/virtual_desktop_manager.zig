const virtual_desktop_manager = @cImport({
    @cInclude("virtual_desktop_manager.h");
});

usingnamespace @import("zigwin32").system.com;
usingnamespace @import("zigwin32").foundation;

const GUID = extern struct {
    data1: u64,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub const VirtualDesktopManager = struct {
    const Self = @This();

    comObj: *c_void,

    pub fn init() !Self {
        if (CoInitialize(null) != 0) {
            return error.FailedToInitializeCom;
        }

        //var comObj: ?*c_void = undefined;
        //if (virtual_desktop_manager.CreateVirtualDesktopManagerInstance(&comObj) != 0) {
        //    return error.FailedToInitializeInstance;
        //}

        var comObj = virtual_desktop_manager.CreateVirtualDesktopManagerInstance() //
        orelse return error.FailedToInitializeInstance;

        return Self{
            .comObj = comObj,
        };
    }

    pub fn deinit(self: Self) void {
        //
    }

    pub fn GetWindowDesktopId(self: *Self, hwnd: HWND) !GUID {
        var result: GUID = undefined;
        if (virtual_desktop_manager.GetWindowDesktopId(self.comObj, @ptrCast(virtual_desktop_manager.HWND, @alignCast(4, hwnd)), &result) != 0) {
            return error.GetWindowDesktopId;
        }
        return result;
    }

    pub fn IsWindowOnCurrentVirtualDesktop(self: *Self, hwnd: HWND) !bool {
        var result: BOOL = undefined;

        if (virtual_desktop_manager.IsWindowOnCurrentVirtualDesktop(self.comObj, @ptrCast(virtual_desktop_manager.HWND, @alignCast(4, hwnd)), &result) != 0) {
            return error.IsWindowOnCurrentVirtualDesktop;
        }
        return result != 0;
    }
};
