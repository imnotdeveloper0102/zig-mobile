// device.zig — Thông tin thiết bị / app.
//
// Zig không tự đọc được model máy hay phiên bản hệ điều hành: trên
// Android phải hỏi Build.MODEL / Build.VERSION, trên iOS hỏi
// UIDevice. Native đưa 4 chuỗi đó sang lúc init, Zig chỉ giữ,
// kiểm tra cho hợp lệ rồi format ra để log / gửi kèm báo lỗi.
// Chuỗi rỗng hoặc quá dài đều bị từ chối, thà báo lỗi còn hơn giữ
// dữ liệu rác trong app.
const std = @import("std");
const errors = @import("errors.zig");
const platform = @import("platform.zig");

pub const MobileError = errors.MobileError;
pub const Platform = platform.Platform;

pub const max_field_len = 128;
pub const max_locale_len = 32;

pub const DeviceInfo = struct {
    alloc: std.mem.Allocator,
    platform: Platform,
    arch: []u8,
    os_version: []u8,
    app_version: []u8,
    locale: []u8,
    model: []u8,

    pub fn init(
        alloc: std.mem.Allocator,
        plat: Platform,
        arch: []const u8,
        os_version: []const u8,
        app_version: []const u8,
        locale: []const u8,
        model: []const u8,
    ) MobileError!DeviceInfo {
        if (arch.len == 0 or arch.len > max_field_len) return error.InvalidDeviceInfo;
        if (os_version.len == 0 or os_version.len > max_field_len) return error.InvalidDeviceInfo;
        if (app_version.len == 0 or app_version.len > max_field_len) return error.InvalidDeviceInfo;
        if (!isValidLocale(locale)) return error.InvalidDeviceInfo;
        if (model.len > max_field_len) return error.InvalidDeviceInfo;
        // model được phép rỗng (native chưa đọc được thì để trống).
        const arch_c = alloc.dupe(u8, arch) catch return error.OutOfMemory;
        errdefer alloc.free(arch_c);
        const os_c = alloc.dupe(u8, os_version) catch return error.OutOfMemory;
        errdefer alloc.free(os_c);
        const app_c = alloc.dupe(u8, app_version) catch return error.OutOfMemory;
        errdefer alloc.free(app_c);
        const loc_c = alloc.dupe(u8, locale) catch return error.OutOfMemory;
        errdefer alloc.free(loc_c);
        const model_c = alloc.dupe(u8, model) catch return error.OutOfMemory;
        return .{
            .alloc = alloc,
            .platform = plat,
            .arch = arch_c,
            .os_version = os_c,
            .app_version = app_c,
            .locale = loc_c,
            .model = model_c,
        };
    }

    pub fn deinit(self: *DeviceInfo) void {
        self.alloc.free(self.arch);
        self.alloc.free(self.os_version);
        self.alloc.free(self.app_version);
        self.alloc.free(self.locale);
        self.alloc.free(self.model);
        self.arch = &.{};
        self.os_version = &.{};
        self.app_version = &.{};
        self.locale = &.{};
        self.model = &.{};
    }

    pub fn isMobile(self: *const DeviceInfo) bool {
        return self.platform.isMobile();
    }

    /// "android aarch64, os 14, app 1.0.0, vi-VN, model Pixel 8".
    /// Người gọi sở hữu chuỗi trả về.
    pub fn display(self: *const DeviceInfo, alloc: std.mem.Allocator) MobileError![]u8 {
        return std.fmt.allocPrint(alloc, "{s} {s}, os {s}, app {s}, {s}, model {s}", .{
            self.platform.toString(),
            self.arch,
            self.os_version,
            self.app_version,
            self.locale,
            self.model,
        }) catch return error.OutOfMemory;
    }
};

/// Locale dạng "vi", "vi-VN", "en_US": chữ cái + '-'/'_' + chữ cái,
/// dài 2..32 ký tự. Chặn chuỗi có ký tự lạ để khỏi lọt vào log/file.
pub fn isValidLocale(locale: []const u8) bool {
    if (locale.len < 2 or locale.len > max_locale_len) return false;
    for (locale) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

test "device info valid" {
    const t = std.testing;
    const alloc = t.allocator;
    var info = try DeviceInfo.init(alloc, .android, "aarch64", "14", "1.0.0", "vi-VN", "Pixel 8");
    defer info.deinit();

    try t.expect(info.isMobile());
    try t.expectEqualStrings("android", info.platform.toString());
    const text = try info.display(alloc);
    defer alloc.free(text);
    try t.expectEqualStrings("android aarch64, os 14, app 1.0.0, vi-VN, model Pixel 8", text);
}

test "device info invalid" {
    const t = std.testing;
    const alloc = t.allocator;
    // app_version rỗng, os_version rỗng, locale sai định dạng đều bị chặn.
    try t.expectError(error.InvalidDeviceInfo, DeviceInfo.init(alloc, .android, "aarch64", "14", "", "vi-VN", "Pixel 8"));
    try t.expectError(error.InvalidDeviceInfo, DeviceInfo.init(alloc, .android, "aarch64", "", "1.0.0", "vi-VN", "Pixel 8"));
    try t.expectError(error.InvalidDeviceInfo, DeviceInfo.init(alloc, .android, "aarch64", "14", "1.0.0", "vi VN!", "Pixel 8"));
    try t.expectError(error.InvalidDeviceInfo, DeviceInfo.init(alloc, .android, "aarch64", "14", "1.0.0", "v", "Pixel 8"));
    try t.expectError(error.InvalidDeviceInfo, DeviceInfo.init(alloc, .android, "", "14", "1.0.0", "vi-VN", "Pixel 8"));

    // model rỗng thì được (native chưa đọc được model).
    var info = try DeviceInfo.init(alloc, .ios, "aarch64", "17.4", "2.0.0", "en_US", "");
    defer info.deinit();
    try t.expectEqualStrings("", info.model);

    try t.expect(isValidLocale("vi"));
    try t.expect(isValidLocale("en_US"));
    try t.expect(!isValidLocale(""));
    try t.expect(!isValidLocale("vi-VN;rm"));
}
