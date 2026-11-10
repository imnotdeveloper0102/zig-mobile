// permissions.zig — Trạng thái xin quyền của app.
//
// Zig không tự xin quyền được: hộp thoại xin quyền là việc của
// Android (Activity.requestPermissions) / iOS (phần hệ thống). Zig
// chỉ giữ bảng trạng thái chung, để logic "đã xin chưa, bị từ chối
// chưa, bị từ chối vĩnh viễn chưa" viết một lần, khỏi viết hai lần
// bằng Kotlin và Swift. Luồng thật:
//   native hỏi PermissionStore.needsRequest() -> hiện hộp thoại
//   native báo kết quả về bằng markResult() -> Zig đẩy event
//   permission_result (payload "camera:granted") vào hàng đợi.
const std = @import("std");
const errors = @import("errors.zig");

pub const MobileError = errors.MobileError;

pub const Permission = enum(u8) {
    camera = 0,
    microphone = 1,
    location = 2,
    storage = 3,
    notifications = 4,

    pub fn toString(self: Permission) []const u8 {
        return switch (self) {
            .camera => "camera",
            .microphone => "microphone",
            .location => "location",
            .storage => "storage",
            .notifications => "notifications",
        };
    }

    pub fn code(self: Permission) c_int {
        return @intFromEnum(self);
    }

    pub fn fromCode(n: c_int) ?Permission {
        if (n < 0 or n > 4) return null;
        return @enumFromInt(@as(u8, @intCast(n)));
    }

    pub fn fromName(name: []const u8) ?Permission {
        if (std.mem.eql(u8, name, "camera")) return .camera;
        if (std.mem.eql(u8, name, "microphone")) return .microphone;
        if (std.mem.eql(u8, name, "location")) return .location;
        if (std.mem.eql(u8, name, "storage")) return .storage;
        if (std.mem.eql(u8, name, "notifications")) return .notifications;
        return null;
    }
};

pub const PermissionState = enum(u8) {
    not_requested = 0,
    granted = 1,
    denied = 2,
    permanently_denied = 3,

    pub fn toString(self: PermissionState) []const u8 {
        return switch (self) {
            .not_requested => "not_requested",
            .granted => "granted",
            .denied => "denied",
            .permanently_denied => "permanently_denied",
        };
    }

    pub fn code(self: PermissionState) c_int {
        return @intFromEnum(self);
    }

    pub fn fromCode(n: c_int) ?PermissionState {
        if (n < 0 or n > 3) return null;
        return @enumFromInt(@as(u8, @intCast(n)));
    }

    pub fn fromName(name: []const u8) ?PermissionState {
        if (std.mem.eql(u8, name, "not_requested")) return .not_requested;
        if (std.mem.eql(u8, name, "granted")) return .granted;
        if (std.mem.eql(u8, name, "denied")) return .denied;
        if (std.mem.eql(u8, name, "permanently_denied")) return .permanently_denied;
        return null;
    }
};

/// Bảng trạng thái 5 quyền, không cần allocator. Quyền nào chưa xin
/// bao giờ thì ở not_requested; bị từ chối vĩnh viễn thì native phải
/// mở Settings cho người dùng bật tay, Zig không mở được.
pub const PermissionStore = struct {
    states: [5]PermissionState = .{
        .not_requested,
        .not_requested,
        .not_requested,
        .not_requested,
        .not_requested,
    },

    pub fn init() PermissionStore {
        return .{};
    }

    pub fn state(self: *const PermissionStore, perm: Permission) PermissionState {
        return self.states[@intFromEnum(perm)];
    }

    /// Có cần hiện hộp thoại xin quyền không. Đã granted thì không,
    /// bị từ chối vĩnh viễn thì cũng không (hiện hộp thoại nữa cũng
    /// bị hệ thống chặn) — trường hợp đó native mở Settings.
    pub fn needsRequest(self: *const PermissionStore, perm: Permission) bool {
        return switch (self.state(perm)) {
            .not_requested, .denied => true,
            .granted, .permanently_denied => false,
        };
    }

    pub fn markResult(self: *PermissionStore, perm: Permission, st: PermissionState) void {
        self.states[@intFromEnum(perm)] = st;
    }

    /// Ghi kết quả từ 2 cờ mà native hay trả về (được cấp / từ chối
    /// vĩnh viễn). granted=true thì granted, còn lại denied hoặc
    /// permanently_denied tùy cờ permanent.
    pub fn markGranted(self: *PermissionStore, perm: Permission, granted: bool, permanent: bool) PermissionState {
        const st: PermissionState = if (granted)
            .granted
        else if (permanent)
            .permanently_denied
        else
            .denied;
        self.markResult(perm, st);
        return st;
    }

    pub fn allGranted(self: *const PermissionStore) bool {
        for (self.states) |st| {
            if (st != .granted) return false;
        }
        return true;
    }

    pub fn anyPermanentlyDenied(self: *const PermissionStore) bool {
        for (self.states) |st| {
            if (st == .permanently_denied) return true;
        }
        return false;
    }

    /// Payload event permission_result, dạng "camera:granted".
    /// Ghi vào buffer của người gọi; App.postEvent copy lại nên dùng
    /// buffer trên stack cũng được.
    pub fn formatPayload(perm: Permission, st: PermissionState, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ perm.toString(), st.toString() }) catch buf[0..0];
    }
};

test "permission code roundtrip" {
    const t = std.testing;
    try t.expectEqual(@as(c_int, 0), Permission.camera.code());
    try t.expectEqual(@as(c_int, 4), Permission.notifications.code());
    try t.expectEqual(Permission.location, Permission.fromCode(2).?);
    try t.expectEqual(@as(?Permission, null), Permission.fromCode(5));
    try t.expectEqual(@as(?Permission, null), Permission.fromCode(-1));
    try t.expectEqual(Permission.microphone, Permission.fromName("microphone").?);
    try t.expectEqual(@as(?Permission, null), Permission.fromName("bluetooth"));

    try t.expectEqual(@as(c_int, 3), PermissionState.permanently_denied.code());
    try t.expectEqual(PermissionState.granted, PermissionState.fromCode(1).?);
    try t.expectEqual(@as(?PermissionState, null), PermissionState.fromCode(4));
    try t.expectEqual(PermissionState.denied, PermissionState.fromName("denied").?);
}

test "permission store flow" {
    const t = std.testing;
    var store = PermissionStore.init();

    // Mới đầu chưa xin quyền nào.
    try t.expectEqual(PermissionState.not_requested, store.state(.camera));
    try t.expect(store.needsRequest(.camera));
    try t.expect(!store.allGranted());

    // Cấp camera, từ chối location một lần, từ chối storage vĩnh viễn.
    _ = store.markGranted(.camera, true, false);
    try t.expectEqual(PermissionState.granted, store.state(.camera));
    try t.expect(!store.needsRequest(.camera));

    _ = store.markGranted(.location, false, false);
    try t.expectEqual(PermissionState.denied, store.state(.location));
    try t.expect(store.needsRequest(.location)); // từ chối thường thì xin lại được

    _ = store.markGranted(.storage, false, true);
    try t.expectEqual(PermissionState.permanently_denied, store.state(.storage));
    try t.expect(!store.needsRequest(.storage));
    try t.expect(store.anyPermanentlyDenied());

    // Xin lại location lần hai thì được cấp.
    store.markResult(.location, .granted);
    try t.expectEqual(PermissionState.granted, store.state(.location));

    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("camera:granted", PermissionStore.formatPayload(.camera, .granted, &buf));
    try t.expectEqualStrings("storage:permanently_denied", PermissionStore.formatPayload(.storage, .permanently_denied, &buf));
}
