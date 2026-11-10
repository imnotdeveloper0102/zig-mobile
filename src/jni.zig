// jni.zig — Cầu nối JNI cho Android.
//
// Hai phần:
//   1. Hàm thuần, test được trên host: kiểm tra UTF-8, copy chuỗi Zig
//      sang chuỗi C, đổi mã event/state sang số.
//   2. Bảng hàm JNI: lấy chuỗi Java (jstring) và tạo chuỗi Java mới.
//      Bảng này khai theo đúng thứ tự trong jni.h của NDK — các hàm
//      không dùng để kiểu *anyopaque để không sai offset. Chỉ số lấy
//      từ thứ tự chuẩn: GetVersion=4, NewStringUTF=167,
//      GetStringUTFLength=168, GetStringUTFChars=169,
//      ReleaseStringUTFChars=170. CHƯA kiểm chứng trên máy thật (máy
//      này không có Android SDK/NDK), nên đường an toàn là các hàm
//      JNI chỉ nhận số nguyên (lifecycle, mã event) — chúng không đụng
//      tới bảng hàm. Hàm nào nhận jstring thì ghi rõ là dùng bảng.
//
// Ngoài ra jni.zig giữ hộ registry callback: phía iOS/host C đăng ký
// callback để nhận log/event ngay; phía Android thì poll (xem
// android.zig) vì gọi ngược sang Kotlin cần method ID.
const std = @import("std");
const errors = @import("errors.zig");
const event = @import("event.zig");
const log = @import("log.zig");

pub const MobileError = errors.MobileError;
pub const LogCallback = log.LogCallback;
pub const EventCallback = event.EventCallback;

/// Đăng ký callback log/event (cho iOS / host C). Android dùng poll.
pub const setLogCallback = log.setGlobalLogCallback;
pub const setEventCallback = event.setGlobalEventCallback;

pub const jint = i32;
pub const jlong = i64;
pub const jboolean = u8;
pub const jbyte = i8;
pub const jsize = jint;

/// jstring/jobject là con trỏ opaque, có thể null.
pub const jstring = *anyopaque;
pub const jobject = *anyopaque;
pub const jclass = *anyopaque;

/// JNIEnv trong C là `const JNINativeInterface*`, nên ở Zig nó là struct
/// chỉ chứa một con trỏ tới bảng hàm.
pub const JniFunctions = extern struct {
    entries: [232]*anyopaque,
};

pub const JNIEnv = extern struct {
    functions: *const JniFunctions,
};

pub const idx_get_version = 4;
pub const idx_new_string_utf = 167;
pub const idx_get_string_utf_length = 168;
pub const idx_get_string_utf_chars = 169;
pub const idx_release_string_utf_chars = 170;

const GetStringUtfCharsFn = *const fn (*JNIEnv, ?jstring, ?*jboolean) callconv(.c) [*c]const u8;
const ReleaseStringUtfCharsFn = *const fn (*JNIEnv, ?jstring, [*c]const u8) callconv(.c) void;
const NewStringUtfFn = *const fn (*JNIEnv, [*c]const u8) callconv(.c) ?jstring;
const GetStringUtfLengthFn = *const fn (*JNIEnv, ?jstring) callconv(.c) jsize;

/// Đọc jstring thành chuỗi Zig (bản copy, người gọi sở hữu).
/// Trả về dạng byte UTF-8 đã sửa (modified UTF-8) của JNI: chuỗi có ký
/// tự NUL hoặc ngoài BMP sẽ khác UTF-8 thường, phía Kotlin nên tránh
/// gửi hai loại đó qua đây, hoặc gửi payload dạng byte qua poll.
pub fn getStringUtf8(env: *JNIEnv, str: ?jstring, alloc: std.mem.Allocator) MobileError![]u8 {
    const s = str orelse return error.JniError;
    const get_chars: GetStringUtfCharsFn = @ptrCast(@alignCast(env.functions.entries[idx_get_string_utf_chars]));
    const get_len: GetStringUtfLengthFn = @ptrCast(@alignCast(env.functions.entries[idx_get_string_utf_length]));
    const release: ReleaseStringUtfCharsFn = @ptrCast(@alignCast(env.functions.entries[idx_release_string_utf_chars]));
    const cstr = get_chars(env, s, null);
    if (@intFromPtr(cstr) == 0) return error.JniError;
    const len = get_len(env, s);
    if (len < 0) {
        release(env, s, cstr);
        return error.JniError;
    }
    const out = alloc.dupe(u8, cstr[0..@intCast(len)]) catch return error.OutOfMemory;
    release(env, s, cstr);
    return out;
}

/// Tạo jstring mới từ chuỗi Zig. Trả null (lỗi JniError) nếu JVM hết
/// bộ nhớ hoặc chuỗi có ký tự NUL.
pub fn newStringUtf8(env: *JNIEnv, text: []const u8, alloc: std.mem.Allocator) MobileError!?jstring {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidUtf8;
    const cstr = alloc.dupeSentinel(u8, text, 0) catch return error.OutOfMemory;
    defer alloc.free(cstr);
    const new_fn: NewStringUtfFn = @ptrCast(@alignCast(env.functions.entries[idx_new_string_utf]));
    const out = new_fn(env, cstr.ptr);
    return out orelse error.JniError;
}

/// Chuỗi Zig có phải UTF-8 hợp lệ không (để chặn trước khi đưa qua JNI).
pub fn validateUtf8(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text);
}

/// Copy chuỗi Zig sang chuỗi C có '\0' cuối. Dùng khi cần đưa chuỗi
/// sang phía C mà không qua JNI.
pub fn copyToCString(alloc: std.mem.Allocator, text: []const u8) MobileError![:0]u8 {
    if (!validateUtf8(text)) return error.InvalidUtf8;
    return alloc.dupeSentinel(u8, text, 0) catch return error.OutOfMemory;
}

test "jni pure helpers" {
    const t = std.testing;
    const alloc = t.allocator;

    try t.expect(validateUtf8("hello zig-mobile"));
    try t.expect(validateUtf8("tiếng Việt"));
    try t.expect(!validateUtf8(&.{ 0xFF, 0xFE, 0x41 }));
    try t.expect(validateUtf8(""));

    const cstr = try copyToCString(alloc, "abc");
    defer alloc.free(cstr);
    try t.expectEqualStrings("abc", cstr);
    try t.expectEqual(@as(u8, 0), cstr[3]);
    try t.expectError(error.InvalidUtf8, copyToCString(alloc, &.{ 0xFF, 0x41 }));

    // Mã event/state đổi qua lại phải khớp, vì Kotlin/Swift switch theo số.
    try t.expectEqual(@as(c_int, 1), event.EventType.custom.code());
    try t.expectEqual(event.EventType.custom, event.EventType.fromCode(1).?);
    try t.expectEqual(@as(c_int, 169), @as(c_int, idx_get_string_utf_chars));
    try t.expectEqual(@as(c_int, 170), @as(c_int, idx_release_string_utf_chars));
}
