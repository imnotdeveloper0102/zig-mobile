// json.zig — Helper JSON mỏng trên std.json, không viết parser tay.
//
// Chỉ bọc 3 việc hay dùng trong app:
//   1. Encode/decode event (kind + seq + payload) để native lấy UI
//      tree / lệnh vẽ / event dạng JSON.
//   2. Encode/decode 3 cài đặt hay dùng (theme, font_size, sound)
//      để đồng bộ cài đặt với native.
//   3. stringify/parse chung cho struct bất kỳ (native tự định nghĩa
//      struct của nó rồi dùng 2 hàm này).
//
// Lỗi parse JSON trả về error.InvalidJson (mã -23, xem errors.zig),
// không trả thẳng lỗi của std.json để phía native chỉ cần nhớ một
// mã lỗi duy nhất cho JSON.
const std = @import("std");
const errors = @import("errors.zig");
const settings = @import("settings.zig");

pub const MobileError = errors.MobileError;
pub const Settings = settings.Settings;

/// Encode struct/slice bất kỳ thành chuỗi JSON (người gọi sở hữu).
pub fn stringify(alloc: std.mem.Allocator, value: anytype) MobileError![]u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{}) catch return error.OutOfMemory;
}

/// Parse JSON thành struct T (người gọi sở hữu giá trị trả về, gọi
/// deinit của nó nếu T chứa slice/string). Lỗi định dạng -> InvalidJson.
pub fn parse(comptime T: type, alloc: std.mem.Allocator, text: []const u8) MobileError!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, text, .{}) catch return error.InvalidJson;
}

/// Một sự kiện dạng JSON, để native lấy event/UI qua JSON.
///   {"kind":"custom","seq":12,"payload":"hello"}
pub const EventJson = struct {
    kind: []const u8,
    seq: u64,
    payload: []const u8,
};

pub fn encodeEvent(alloc: std.mem.Allocator, kind: []const u8, seq: u64, payload: []const u8) MobileError![]u8 {
    return stringify(alloc, EventJson{ .kind = kind, .seq = seq, .payload = payload });
}

pub const DecodedEvent = struct {
    kind: []u8,
    seq: u64,
    payload: []u8,

    pub fn deinit(self: *DecodedEvent, alloc: std.mem.Allocator) void {
        alloc.free(self.kind);
        alloc.free(self.payload);
        self.kind = &.{};
        self.payload = &.{};
    }
};

/// Decode JSON event thành bản copy do người gọi sở hữu.
pub fn decodeEvent(alloc: std.mem.Allocator, text: []const u8) MobileError!DecodedEvent {
    var parsed = try parse(EventJson, alloc, text);
    defer parsed.deinit();
    const kind = alloc.dupe(u8, parsed.value.kind) catch return error.OutOfMemory;
    errdefer alloc.free(kind);
    const payload = alloc.dupe(u8, parsed.value.payload) catch return error.OutOfMemory;
    return .{ .kind = kind, .seq = parsed.value.seq, .payload = payload };
}

/// 3 cài đặt hay dùng, dạng JSON. Thiếu field thì lấy mặc định
/// (theme "", font_size 0, sound false) để JSON cũ vẫn đọc được.
pub const ConfigJson = struct {
    theme: []const u8 = "",
    font_size: i64 = 0,
    sound: bool = false,
};

/// Đọc 3 cài đặt từ Settings rồi encode thành JSON.
pub fn settingsToJson(alloc: std.mem.Allocator, s: *const Settings) MobileError![]u8 {
    return stringify(alloc, ConfigJson{
        .theme = s.getString("theme") orelse "",
        .font_size = s.getInt("font_size") orelse 0,
        .sound = s.getBool("sound") orelse false,
    });
}

/// Decode JSON cài đặt rồi ghi vào Settings. Chỉ ghi field nào có
/// trong JSON (dùng struct field optional để phân biệt "không có"
/// với "có nhưng là giá trị mặc định").
pub fn jsonToSettings(alloc: std.mem.Allocator, s: *Settings, text: []const u8) MobileError!void {
    const Partial = struct {
        theme: ?[]const u8 = null,
        font_size: ?i64 = null,
        sound: ?bool = null,
    };
    var parsed = try parse(Partial, alloc, text);
    defer parsed.deinit();
    if (parsed.value.theme) |v| try s.setString("theme", v);
    if (parsed.value.font_size) |v| try s.setInt("font_size", v);
    if (parsed.value.sound) |v| try s.setBool("sound", v);
}

test "json event roundtrip" {
    const t = std.testing;
    const alloc = t.allocator;

    const text = try encodeEvent(alloc, "custom", 12, "hello-mobile");
    defer alloc.free(text);
    try t.expectEqualStrings("{\"kind\":\"custom\",\"seq\":12,\"payload\":\"hello-mobile\"}", text);

    var ev = try decodeEvent(alloc, text);
    defer ev.deinit(alloc);
    try t.expectEqualStrings("custom", ev.kind);
    try t.expectEqual(@as(u64, 12), ev.seq);
    try t.expectEqualStrings("hello-mobile", ev.payload);

    // Ký tự đặc biệt (ngoặc kép, xuống dòng) phải được escape rồi đọc lại đúng.
    const text2 = try encodeEvent(alloc, "custom", 1, "a\"b\nc");
    defer alloc.free(text2);
    var ev2 = try decodeEvent(alloc, text2);
    defer ev2.deinit(alloc);
    try t.expectEqualStrings("a\"b\nc", ev2.payload);

    // JSON hỏng / thiếu field thì InvalidJson.
    try t.expectError(error.InvalidJson, decodeEvent(alloc, "{khong-phai-json"));
    try t.expectError(error.InvalidJson, decodeEvent(alloc, "{\"kind\":\"custom\"}"));
}

test "json settings roundtrip" {
    const t = std.testing;
    const alloc = t.allocator;

    var s = Settings.init(alloc);
    defer s.deinit();
    try s.setString("theme", "dark");
    try s.setInt("font_size", 16);
    try s.setBool("sound", true);
    const text = try settingsToJson(alloc, &s);
    defer alloc.free(text);
    try t.expectEqualStrings("{\"theme\":\"dark\",\"font_size\":16,\"sound\":true}", text);

    // Chỉ ghi field có trong JSON, field khác giữ nguyên.
    var s2 = Settings.init(alloc);
    defer s2.deinit();
    try s2.setString("theme", "light");
    try jsonToSettings(alloc, &s2, "{\"font_size\":20}");
    try t.expectEqualStrings("light", s2.getString("theme").?);
    try t.expectEqual(@as(i64, 20), s2.getInt("font_size").?);
    try t.expect(s2.getBool("sound") == null);

    // JSON đầy đủ thì ghi đủ 3 field; JSON hỏng thì lỗi, không ghi gì thêm.
    try jsonToSettings(alloc, &s2, "{\"theme\":\"dark\",\"font_size\":16,\"sound\":true}");
    try t.expectEqualStrings("dark", s2.getString("theme").?);
    try t.expectError(error.InvalidJson, jsonToSettings(alloc, &s2, "{\"theme\":}"));
}

test "json generic stringify parse" {
    const t = std.testing;
    const alloc = t.allocator;
    const Point = struct { x: i64, y: i64 };
    const text = try stringify(alloc, Point{ .x = 3, .y = 4 });
    defer alloc.free(text);
    try t.expectEqualStrings("{\"x\":3,\"y\":4}", text);
    var parsed = try parse(Point, alloc, text);
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 3), parsed.value.x);
    try t.expectError(error.InvalidJson, parse(Point, alloc, "khong-phai-json"));
}
