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

const BorderJson = struct {
    thickness: usize = 2,
    color: []const u8 = "0xFF00FF",
};

const ConfigJson = struct {
    gap: i32 = 5,
    splitRatio: f64 = 0.6,
    wrapMonitors: bool = true,
    wrapWindows: bool = true,
    disableOutlineForFullscreen: bool = true,
    monitorBorder: BorderJson = .{},
    windowFocusedBorder: BorderJson = .{},
    windowUnfocusedBorder: BorderJson = .{},
    ignoredPrograms: [][]const u8,
    ignoredClasses: [][]const u8,
    ignoredTitles: [][]const u8,
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

const Border = struct {
    thickness: usize = 2,
    color: u32 = 0,
};

pub const Config = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,

    gap: i32 = 5,
    splitRatio: f64 = 0.6,
    wrapMonitors: bool = true,
    wrapWindows: bool = true,

    disableOutlineForFullscreen: bool = true,
    monitorBorder: Border = .{},
    windowFocusedBorder: Border = .{},
    windowUnfocusedBorder: Border = .{},

    ignoredPrograms: std.StringHashMap(IgnoredProgram),
    ignoredClasses: std.StringHashMap(IgnoredProgram),
    ignoredTitles: std.StringHashMap(IgnoredProgram),
    commands: std.StringHashMap(fn (*root.WindowManager, HotkeyArgs) void),
    hotkeys: std.ArrayList(Hotkey),

    loadedConfig: ?ConfigJson = null,

    pub fn init(allocator: *std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .ignoredPrograms = std.StringHashMap(IgnoredProgram).init(allocator),
            .ignoredClasses = std.StringHashMap(IgnoredProgram).init(allocator),
            .ignoredTitles = std.StringHashMap(IgnoredProgram).init(allocator),
            .hotkeys = std.ArrayList(Hotkey).init(allocator),
            .commands = std.StringHashMap(fn (*root.WindowManager, HotkeyArgs) void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.ignoredPrograms.deinit();
        self.ignoredClasses.deinit();
        self.ignoredTitles.deinit();
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

        @setEvalBranchQuota(100000);
        self.loadedConfig = try std.json.parse(ConfigJson, &tokenStream, options);

        const config = &self.loadedConfig.?;

        // Copy fields.
        self.gap = config.gap;
        self.splitRatio = config.splitRatio;
        self.wrapMonitors = config.wrapMonitors;
        self.wrapWindows = config.wrapWindows;

        self.disableOutlineForFullscreen = config.disableOutlineForFullscreen;
        self.monitorBorder = self.parseBorderConfig(config.monitorBorder);
        self.windowFocusedBorder = self.parseBorderConfig(config.windowFocusedBorder);
        self.windowUnfocusedBorder = self.parseBorderConfig(config.windowUnfocusedBorder);

        //
        for (config.ignoredPrograms) |name| {
            try self.ignoredPrograms.put(name, .{});
        }

        for (config.ignoredClasses) |name| {
            try self.ignoredClasses.put(name, .{});
        }

        for (config.ignoredTitles) |name| {
            try self.ignoredTitles.put(name, .{});
        }

        // Get hotkeys
        hotkeyLoop: for (config.hotkeys) |*hotkey| {
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

    fn parseBorderConfig(self: *Self, json: BorderJson) Border {
        var border = Border{};
        border.thickness = json.thickness;
        if (std.mem.startsWith(u8, json.color, "0x")) {
            const color = std.fmt.parseUnsigned(u32, json.color[2..], 16) catch blk: {
                std.log.err("Failed to parse color string as hex number: '{s}'", .{json.color});
                break :blk 0;
            };
            // Config uses RGB format but windows uses BGR format, so convert.
            border.color = ((color & 0x0000FF) << 16) | (color & 0x00FF00) | ((color & 0xFF0000) >> 16);
        } else if (std.mem.eql(u8, json.color, "red")) {
            border.color = 0x0000FF;
        } else if (std.mem.eql(u8, json.color, "green")) {
            border.color = 0x00FF00;
        } else if (std.mem.eql(u8, json.color, "blue")) {
            border.color = 0xFF0000;
        } else {
            std.log.err("Unknown color: '{s}'", .{json.color});
        }
        return border;
    }
};
