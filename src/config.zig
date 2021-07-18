const std = @import("std");
const root = @import("root");

usingnamespace @import("zigwin32").everything;
usingnamespace @import("misc.zig");

pub const IgnoredProgram = struct {};

const HotkeyArgsJson = struct {
    intParam: i64 = 0,
    usizeParam: usize = 0,
    floatParam: f64 = 0,
    boolParam: bool = false,
    charParam: ?[]const u8 = null,
};

const HotkeyJson = struct {
    key: []const u8,
    command: []const u8,
    args: HotkeyArgsJson = .{},
};

const ConfigJson = struct {
    ignoredPrograms: [][]const u8,
    ignoredClasses: [][]const u8,
    ignoredTitles: [][]const u8,
    gap: i32 = 5,
    splitRatio: f64 = 0.6,
    wrapMonitors: bool = true,
    wrapWindows: bool = true,
    hotkeys: []HotkeyJson,
};

pub const HotkeyArgs = struct {
    intParam: i64 = 0,
    usizeParam: usize = 0,
    floatParam: f64 = 0.0,
    boolParam: bool = false,
    charParam: u21 = 0,
};

pub const Hotkey = struct {
    key: u32,
    mods: HOT_KEY_MODIFIERS,
    func: fn (*root.WindowManager, HotkeyArgs) void,
    args: HotkeyArgs = .{},
};

pub const Config = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,

    commands: std.StringHashMap(fn (*root.WindowManager, HotkeyArgs) void),
    ignoredPrograms: std.StringHashMap(IgnoredProgram),
    ignoredClasses: std.StringHashMap(IgnoredProgram),
    ignoredTitles: std.StringHashMap(IgnoredProgram),

    gap: i32 = 5,
    splitRatio: f64 = 0.6,
    wrapMonitors: bool = true,
    wrapWindows: bool = true,

    hotkeys: std.ArrayList(Hotkey),

    loadedConfig: ?ConfigJson = null,

    pub fn init(allocator: *std.mem.Allocator) !Self {
        var ignoredClasses = std.StringHashMap(IgnoredProgram).init(allocator);
        var ignoredTitles = std.StringHashMap(IgnoredProgram).init(allocator);
        var ignoredPrograms = std.StringHashMap(IgnoredProgram).init(allocator);
        var commands = std.StringHashMap(fn (*root.WindowManager, HotkeyArgs) void).init(allocator);

        try ignoredClasses.put("IME", .{});
        try ignoredClasses.put("MSCTFIME UI", .{});
        try ignoredClasses.put("WorkerW", .{});
        try ignoredClasses.put("vguiPopupWindow", .{});
        try ignoredClasses.put("tooltips_class32", .{});
        try ignoredClasses.put("ForegroundStaging", .{});
        try ignoredClasses.put("TaskManagerWindow", .{});
        try ignoredClasses.put("Main HighGUI class", .{});

        // Ignore windows with empty titles.
        try ignoredTitles.put("", .{});

        try ignoredPrograms.put("ScreenClippingHost.exe", .{});
        try ignoredPrograms.put("PowerLauncher.exe", .{});
        try ignoredPrograms.put("TextInputHost.exe", .{});
        try ignoredPrograms.put("ShellExperienceHost.exe", .{});
        try ignoredPrograms.put("EpicGamesLauncher.exe", .{});
        try ignoredPrograms.put("ApplicationFrameHost.exe", .{});

        return Self{
            .allocator = allocator,
            .ignoredPrograms = ignoredPrograms,
            .ignoredClasses = ignoredClasses,
            .ignoredTitles = ignoredTitles,
            .hotkeys = std.ArrayList(Hotkey).init(allocator),
            .commands = commands,
        };
    }

    pub fn deinit(self: *Self) void {
        self.ignoredClasses.deinit();
        self.ignoredTitles.deinit();
        self.ignoredPrograms.deinit();
        self.hotkeys.deinit();
        self.commands.deinit();

        if (self.loadedConfig) |config| {
            const options = std.json.ParseOptions{
                .allocator = self.allocator,
            };
            std.json.parseFree(ConfigJson, config, options);
        }
    }

    pub fn addCommand(self: *Self, name: []const u8, func: fn (*root.WindowManager, HotkeyArgs) void) !void {
        try self.commands.put(name, func);
    }

    pub fn loadFromFile(self: *Self, filename: []const u8) !void {
        std.log.info("Loading config from '{s}'", .{filename});

        var file = try std.fs.cwd().openFile(filename, .{ .read = true });
        defer file.close();
        const fileSize = try file.getEndPos();
        const fileContent = try self.allocator.alloc(u8, fileSize);
        defer self.allocator.free(fileContent);
        const fileSizeRead = try file.readAll(fileContent);
        if (fileSize != fileSizeRead) return error.FailedToReadDataFromFile;

        var tokenStream = std.json.TokenStream.init(fileContent);
        const options = std.json.ParseOptions{
            .allocator = self.allocator,
        };
        self.loadedConfig = try std.json.parse(ConfigJson, &tokenStream, options);

        // Copy fields.
        self.gap = self.loadedConfig.?.gap;
        self.splitRatio = self.loadedConfig.?.splitRatio;
        self.wrapMonitors = self.loadedConfig.?.wrapMonitors;
        self.wrapWindows = self.loadedConfig.?.wrapWindows;

        for (self.loadedConfig.?.ignoredPrograms) |name| {
            try self.ignoredPrograms.put(name, .{});
        }

        for (self.loadedConfig.?.ignoredClasses) |name| {
            try self.ignoredClasses.put(name, .{});
        }

        for (self.loadedConfig.?.ignoredTitles) |name| {
            try self.ignoredTitles.put(name, .{});
        }

        // Get hotkeys
        hotkeyLoop: for (self.loadedConfig.?.hotkeys) |*hotkey| {
            var key: ?u32 = 0;
            var mods = HOT_KEY_MODIFIERS.initFlags(.{});

            // Get keys and modifiers.
            var keyTokens = std.mem.tokenize(hotkey.key, " ");
            while (keyTokens.next()) |token| {
                if (std.mem.eql(u8, "ctrl", token)) {
                    mods = @intToEnum(
                        HOT_KEY_MODIFIERS,
                        @enumToInt(mods) | @enumToInt(HOT_KEY_MODIFIERS.CONTROL),
                    );
                } else if (std.mem.eql(u8, "alt", token)) {
                    mods = @intToEnum(
                        HOT_KEY_MODIFIERS,
                        @enumToInt(mods) | @enumToInt(HOT_KEY_MODIFIERS.ALT),
                    );
                } else if (std.mem.eql(u8, "shift", token)) {
                    mods = @intToEnum(
                        HOT_KEY_MODIFIERS,
                        @enumToInt(mods) | @enumToInt(HOT_KEY_MODIFIERS.SHIFT),
                    );
                } else if (std.mem.eql(u8, "win", token)) {
                    mods = @intToEnum(
                        HOT_KEY_MODIFIERS,
                        @enumToInt(mods) | @enumToInt(HOT_KEY_MODIFIERS.WIN),
                    );
                } else if (std.mem.eql(u8, "norepeat", token)) {
                    mods = @intToEnum(
                        HOT_KEY_MODIFIERS,
                        @enumToInt(mods) | @enumToInt(HOT_KEY_MODIFIERS.NOREPEAT),
                    );
                } else {
                    if (std.mem.eql(u8, "enter", token)) {
                        key = VK_RETURN;
                    } else if (std.mem.eql(u8, "space", token)) {
                        key = VK_SPACE;
                    } else {
                        if (token.len != 1) {
                            std.log.err("Invalid key at end of hotkey string: '{s}' at end of '{s}'", .{ token, hotkey.key });
                            continue :hotkeyLoop;
                        } else {
                            key = @intCast(u32, token[0]);
                        }
                    }

                    break;
                }
            }
            if (key == null) {
                std.log.err("Missing key at end of hotkey string: '{s}'", .{hotkey.key});
                continue :hotkeyLoop;
            }
            while (keyTokens.next()) |token| {
                std.log.err("Unexpected key at end of hotkey string: '{s}' at end of '{s}'", .{ token, hotkey.key });
            }

            // Get function
            const func = self.commands.get(hotkey.command) orelse {
                std.log.err("Invalid command for hotkey: '{s}' in hotkey '{s}'", .{ hotkey.command, hotkey.key });
                continue :hotkeyLoop;
            };

            // Get hotkey args
            var args: HotkeyArgs = .{
                .intParam = hotkey.args.intParam,
                .usizeParam = hotkey.args.usizeParam,
                .floatParam = hotkey.args.floatParam,
                .boolParam = hotkey.args.boolParam,
            };
            if (hotkey.args.charParam) |value| {
                if (value.len == 0) {
                    std.log.err("Empty char param in hotkey args: '{s}'", .{hotkey.key});
                    continue :hotkeyLoop;
                } else {
                    args.charParam = std.unicode.utf8Decode(value) catch {
                        std.log.err("Invalid UTF8 char param in hotkey args: '{s}'", .{hotkey.key});
                        continue :hotkeyLoop;
                    };
                    const expectedLength = std.unicode.utf8ByteSequenceLength(value[0]) catch unreachable;
                    if (expectedLength != value.len) {
                        std.log.err("Too long UTF8 param in hotkey args: '{s}'", .{hotkey.key});
                        continue :hotkeyLoop;
                    }
                }
            }

            try self.hotkeys.append(.{
                .key = key.?,
                .mods = mods,
                .func = func,
                .args = args,
            });
        }
    }
};
