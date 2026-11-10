// log.zig — Log của thư viện. Trên host ghi ra stderr, trên mobile thì
// phía native đăng ký callback để log chảy về logcat (Android) hoặc
// os_log (iOS). Log không bao giờ làm crash app: lỗi ghi log được nuốt.
const std = @import("std");
const builtin = @import("builtin");

pub const Level = enum {
    debug,
    info,
    warn,
    @"error",

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
        };
    }

    pub fn code(self: Level) c_int {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .@"error" => 3,
        };
    }

    pub fn fromCode(n: c_int) ?Level {
        return switch (n) {
            0 => .debug,
            1 => .info,
            2 => .warn,
            3 => .@"error",
            else => null,
        };
    }
};

/// Callback log cho phía native (Swift/Kotlin qua JNI gọi lại không được
/// nên callback này chủ yếu cho iOS và cho host C). Nhận level dạng số,
/// con trỏ + độ dài của message đã format sẵn (không có '\n' cuối).
pub const LogCallback = *const fn (level: c_int, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) void;

var g_log_callback: ?LogCallback = null;

/// Đăng ký / gỡ callback log toàn cục. Gọi từ mobile_set_log_callback.
pub fn setGlobalLogCallback(cb: ?LogCallback) void {
    g_log_callback = cb;
}

pub fn getGlobalLogCallback() ?LogCallback {
    return g_log_callback;
}

pub const Sink = enum {
    stderr,
    file,
    none,
};

pub const Logger = struct {
    level: Level = .info,
    sink: Sink = .stderr,
    /// File C mở sẵn bằng fopen (ghi bằng fwrite). Zig 0.17.1 đổi
    /// API file sang std.Io cần Io instance nên logger file dùng
    /// thẳng libc cho gọn — bên nào mở file thì bên đó fclose.
    file: ?*std.c.FILE = null,

    pub fn init(level: Level) Logger {
        return .{ .level = level };
    }

    pub fn initFile(level: Level, file: *std.c.FILE) Logger {
        return .{ .level = level, .sink = .file, .file = file };
    }

    pub fn shouldLog(self: Logger, level: Level) bool {
        return @intFromEnum(level) >= @intFromEnum(self.level);
    }

    pub fn setLevel(self: *Logger, level: Level) void {
        self.level = level;
    }

    pub fn log(self: *Logger, level: Level, scope: []const u8, msg: []const u8) void {
        if (!self.shouldLog(level)) return;
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "[{s}] [{s}] {s}", .{ level.toString(), scope, msg }) catch blk: {
            const keep = @min(msg.len, 512);
            break :blk std.fmt.bufPrint(&buf, "[{s}] [{s}] {s}...", .{ level.toString(), scope, msg[0..keep] }) catch buf[0..0];
        };
        // Callback native (nếu có) được ưu tiên: trên iOS log phải chảy
        // về os_log, stderr ở đó không ai đọc.
        if (g_log_callback) |cb| {
            cb(level.code(), text.ptr, text.len);
            return;
        }
        switch (self.sink) {
            .stderr => std.debug.print("{s}\n", .{text}),
            .file => {
                // Bản Android không link libc (Zig không cấp được bionic,
                // máy build không có NDK) nên không gọi fwrite được:
                // sink file trên Android hiện là no-op, dùng callback
                // hoặc stderr thay thế. Trên host/iOS vẫn ghi file thường.
                if (comptime builtin.target.abi == .android) {
                    // no-op
                } else if (self.file) |f| {
                    _ = std.c.fwrite(text.ptr, 1, text.len, f);
                    _ = std.c.fwrite("\n", 1, 1, f);
                }
            },
            .none => {},
        }
    }

    pub fn debug(self: *Logger, scope: []const u8, msg: []const u8) void {
        self.log(.debug, scope, msg);
    }

    pub fn info(self: *Logger, scope: []const u8, msg: []const u8) void {
        self.log(.info, scope, msg);
    }

    pub fn warn(self: *Logger, scope: []const u8, msg: []const u8) void {
        self.log(.warn, scope, msg);
    }

    pub fn err(self: *Logger, scope: []const u8, msg: []const u8) void {
        self.log(.@"error", scope, msg);
    }
};

test "level" {
    const t = std.testing;
    try t.expectEqualStrings("DEBUG", Level.debug.toString());
    try t.expectEqualStrings("ERROR", Level.@"error".toString());
    try t.expectEqual(@as(c_int, 3), Level.@"error".code());
    try t.expectEqual(Level.warn, Level.fromCode(2).?);
    try t.expectEqual(@as(?Level, null), Level.fromCode(99));

    var logger = Logger.init(.warn);
    try t.expect(!logger.shouldLog(.debug));
    try t.expect(!logger.shouldLog(.info));
    try t.expect(logger.shouldLog(.warn));
    try t.expect(logger.shouldLog(.@"error"));
    logger.setLevel(.debug);
    try t.expect(logger.shouldLog(.debug));

    // Log ra file rồi đọc lại để chắc là ghi đúng.
    const log_path = "/tmp/zig-mobile-log-test.log";
    const f = std.c.fopen(log_path, "w") orelse return error.TestFailed;
    var file_logger = Logger.initFile(.info, f);
    file_logger.info("app", "hello log");
    file_logger.debug("app", "cai nay khong duoc ghi vi level info");
    _ = std.c.fclose(f);
    const g = std.c.fopen(log_path, "r") orelse return error.TestFailed;
    defer _ = std.c.fclose(g);
    var buf: [4096]u8 = undefined;
    const n = std.c.fread(&buf, 1, buf.len, g);
    try t.expectEqualStrings("[INFO] [app] hello log\n", buf[0..n]);
}
