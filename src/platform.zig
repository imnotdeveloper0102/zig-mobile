// platform.zig — App đang chạy trên nền tảng nào. Zig biết target lúc
// biên dịch nên hàm này không tốn gì lúc chạy, và code gọi nó có thể
// quyết định đường đi theo platform mà không cần #ifdef kiểu C.
const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum {
    android,
    ios,
    host,
    unknown,

    pub fn toString(self: Platform) []const u8 {
        return switch (self) {
            .android => "android",
            .ios => "ios",
            .host => "host",
            .unknown => "unknown",
        };
    }

    pub fn isMobile(self: Platform) bool {
        return self == .android or self == .ios;
    }

    pub fn isHost(self: Platform) bool {
        return self == .host;
    }
};

/// Platform của target đang biên dịch: aarch64-linux-android -> android,
/// aarch64-ios -> ios, linux/macos/windows trên máy dev -> host.
pub fn current() Platform {
    const target = builtin.target;
    if (target.os.tag == .ios) return .ios;
    if (target.abi == .android) return .android;
    return switch (target.os.tag) {
        .linux, .macos, .windows => .host,
        else => .unknown,
    };
}

/// Tên kiến trúc, ví dụ "aarch64", "x86_64". Để log lúc debug cho dễ.
pub fn archName() []const u8 {
    return @tagName(builtin.target.cpu.arch);
}

test "platform" {
    const t = std.testing;
    // Máy này build host (linux x86_64) nên current() phải là host.
    try t.expectEqual(Platform.host, current());
    try t.expect(current().isHost());
    try t.expect(!current().isMobile());
    try t.expectEqualStrings("android", Platform.android.toString());
    try t.expectEqualStrings("ios", Platform.ios.toString());
    try t.expect(Platform.android.isMobile());
    try t.expect(Platform.ios.isMobile());
    try t.expect(!Platform.host.isMobile());
    try t.expectEqualStrings("x86_64", archName());
}
