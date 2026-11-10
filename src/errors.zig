// errors.zig — Một error set dùng chung cho toàn thư viện, để phía
// Kotlin/Swift chỉ cần nhớ mã số trả về thay vì nhớ từng lỗi Zig.
const std = @import("std");

pub const MobileError = error{
    NotInitialized,
    AlreadyInitialized,
    InvalidTransition,
    InvalidEvent,
    QueueFull,
    QueueEmpty,
    InvalidPath,
    MissingStoragePath,
    NoCallback,
    InvalidUtf8,
    JniError,
    BufferTooSmall,
    UnsupportedPlatform,
    OutOfMemory,
    InvalidPermission,
    InvalidSetting,
    FileNotFound,
    NetworkUnavailable,
    TaskNotFound,
    InvalidDeviceInfo,
    InvalidTask,
    InvalidHttp,
    InvalidJson,
};

/// Mã số trả về qua FFI (0 = ok). Kotlin/Swift switch theo số này.
pub fn errorCode(err: MobileError) c_int {
    return switch (err) {
        error.NotInitialized => -1,
        error.AlreadyInitialized => -2,
        error.InvalidTransition => -3,
        error.InvalidEvent => -4,
        error.QueueFull => -5,
        error.QueueEmpty => -6,
        error.InvalidPath => -7,
        error.MissingStoragePath => -8,
        error.NoCallback => -9,
        error.InvalidUtf8 => -10,
        error.JniError => -11,
        error.BufferTooSmall => -12,
        error.UnsupportedPlatform => -13,
        error.OutOfMemory => -14,
        error.InvalidPermission => -15,
        error.InvalidSetting => -16,
        error.FileNotFound => -17,
        error.NetworkUnavailable => -18,
        error.TaskNotFound => -19,
        error.InvalidDeviceInfo => -20,
        error.InvalidTask => -21,
        error.InvalidHttp => -22,
        error.InvalidJson => -23,
    };
}

pub fn describe(err: MobileError) []const u8 {
    return switch (err) {
        error.NotInitialized => "app chưa init",
        error.AlreadyInitialized => "app đã init rồi",
        error.InvalidTransition => "chuyển trạng thái vòng đời không hợp lệ",
        error.InvalidEvent => "sự kiện không hợp lệ",
        error.QueueFull => "hàng đợi sự kiện đã đầy",
        error.QueueEmpty => "hàng đợi sự kiện đang trống",
        error.InvalidPath => "đường dẫn không hợp lệ",
        error.MissingStoragePath => "thiếu đường dẫn files/cache (Android/iOS phải đưa từ native)",
        error.NoCallback => "chưa đăng ký callback",
        error.InvalidUtf8 => "chuỗi không phải UTF-8 hợp lệ",
        error.JniError => "lỗi JNI (env null, string null, hoặc hàm JNI trả null)",
        error.BufferTooSmall => "buffer phía gọi cấp quá nhỏ",
        error.UnsupportedPlatform => "platform này chưa hỗ trợ",
        error.OutOfMemory => "hết bộ nhớ",
        error.InvalidPermission => "quyền không hợp lệ",
        error.InvalidSetting => "cài đặt không hợp lệ",
        error.FileNotFound => "không tìm thấy file",
        error.NetworkUnavailable => "không có mạng",
        error.TaskNotFound => "không tìm thấy task nền",
        error.InvalidDeviceInfo => "thông tin thiết bị không hợp lệ",
        error.InvalidTask => "task nền không hợp lệ",
        error.InvalidHttp => "response HTTP không hợp lệ",
        error.InvalidJson => "JSON không hợp lệ",
    };
}

test "errorCode" {
    const t = std.testing;
    try t.expectEqual(@as(c_int, 0), 0); // ok không phải lỗi, giữ 0 cho FFI
    try t.expectEqual(@as(c_int, -3), errorCode(error.InvalidTransition));
    try t.expectEqual(@as(c_int, -7), errorCode(error.InvalidPath));
    try t.expectEqualStrings("app chưa init", describe(error.NotInitialized));
}
