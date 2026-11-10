// storage.zig — Đường dẫn lưu trữ của app. Zig không tự biết filesDir
// của Android hay Documents của iOS ở đâu, nên phía native phải đưa
// đường dẫn thật vào lúc init. Trên host thì lấy thư mục hiện tại làm
// mặc định để test/demo chạy được ngay.
const std = @import("std");
const builtin = @import("builtin");
const errors = @import("errors.zig");
const platform = @import("platform.zig");

pub const MobileError = errors.MobileError;
pub const Platform = platform.Platform;

pub const Storage = struct {
    alloc: std.mem.Allocator,
    files_dir: []u8,
    cache_dir: []u8,
    platform: Platform,

    pub fn init(alloc: std.mem.Allocator, plat: Platform, files_dir: []const u8, cache_dir: []const u8) MobileError!Storage {
        if (files_dir.len == 0 or cache_dir.len == 0) return error.InvalidPath;
        const files = alloc.dupe(u8, files_dir) catch return error.OutOfMemory;
        errdefer alloc.free(files);
        const cache = alloc.dupe(u8, cache_dir) catch return error.OutOfMemory;
        return .{ .alloc = alloc, .files_dir = files, .cache_dir = cache, .platform = plat };
    }

    /// Chỉ dùng trên host (test/demo). Android/iOS bắt buộc đưa path thật
    /// vì Zig không gọi được Context.getFilesDir() hay FileManager.
    pub fn initDefault(alloc: std.mem.Allocator, plat: Platform) MobileError!Storage {
        if (plat.isMobile()) return error.MissingStoragePath;
        // Bản Android không link libc nên không gọi getcwd được.
        if (comptime builtin.target.abi == .android) return error.MissingStoragePath;
        var buf: [4096]u8 = undefined;
        const ptr = std.c.getcwd(&buf, buf.len) orelse return error.InvalidPath;
        _ = ptr;
        const end = std.mem.indexOfScalar(u8, buf[0..], 0) orelse return error.InvalidPath;
        const cwd = alloc.dupe(u8, buf[0..end]) catch return error.OutOfMemory;
        errdefer alloc.free(cwd);
        const cache = std.fs.path.join(alloc, &.{ cwd, ".cache" }) catch return error.OutOfMemory;
        errdefer alloc.free(cache);
        return .{ .alloc = alloc, .files_dir = cwd, .cache_dir = cache, .platform = plat };
    }

    pub fn deinit(self: *Storage) void {
        self.alloc.free(self.files_dir);
        self.alloc.free(self.cache_dir);
        self.files_dir = &.{};
        self.cache_dir = &.{};
    }

    /// Ghép đường dẫn file trong files_dir. Từ chối đường dẫn tuyệt đối
    /// và ".." để phía native không vô tình (hay cố tình) đọc ra ngoài.
    pub fn filesPath(self: *const Storage, alloc: std.mem.Allocator, relative: []const u8) MobileError![]u8 {
        if (!isValidRelative(relative)) return error.InvalidPath;
        return std.fs.path.join(alloc, &.{ self.files_dir, relative }) catch return error.OutOfMemory;
    }

    pub fn cachePath(self: *const Storage, alloc: std.mem.Allocator, relative: []const u8) MobileError![]u8 {
        if (!isValidRelative(relative)) return error.InvalidPath;
        return std.fs.path.join(alloc, &.{ self.cache_dir, relative }) catch return error.OutOfMemory;
    }

    /// Tạo files_dir nếu chưa có. Đã có rồi thì mkdir báo lỗi nhưng cứ
    /// bỏ qua — trên Android/iOS thư mục này hệ thống đã tạo sẵn, trên
    /// host thì mặc định là thư mục hiện tại (đã có).
    pub fn ensureFilesDir(self: *const Storage) MobileError!void {
        // Bản Android không link libc nên không gọi mkdir được; thư mục
        // files trên Android hệ thống đã tạo sẵn nên cứ bỏ qua.
        if (comptime builtin.target.abi == .android) return;
        const z = self.alloc.dupeSentinel(u8, self.files_dir, 0) catch return error.OutOfMemory;
        defer self.alloc.free(z);
        _ = std.c.mkdir(z.ptr, 0o755);
    }
};

pub fn isValidRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    if (std.mem.indexOf(u8, path, "..") != null) {
        // Chặn ".." ở bất cứ đâu, kể cả "a/../b".
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return false;
        }
    }
    return true;
}

test "storage paths" {
    const t = std.testing;
    const alloc = t.allocator;
    var s = try Storage.init(alloc, .android, "/data/data/com.zigmobile.app/files", "/data/data/com.zigmobile.app/cache");
    defer s.deinit();

    const p = try s.filesPath(alloc, "notes/app.db");
    defer alloc.free(p);
    try t.expectEqualStrings("/data/data/com.zigmobile.app/files/notes/app.db", p);

    const c = try s.cachePath(alloc, "thumb.png");
    defer alloc.free(c);
    try t.expectEqualStrings("/data/data/com.zigmobile.app/cache/thumb.png", c);

    try t.expectError(error.InvalidPath, s.filesPath(alloc, "/etc/passwd"));
    try t.expectError(error.InvalidPath, s.filesPath(alloc, "../secret"));
    try t.expectError(error.InvalidPath, s.filesPath(alloc, "a/../../b"));
    try t.expectError(error.InvalidPath, s.filesPath(alloc, ""));
    try t.expectError(error.InvalidPath, Storage.init(alloc, .host, "", "/tmp"));
    try t.expectError(error.MissingStoragePath, Storage.initDefault(alloc, .android));
    try t.expectError(error.MissingStoragePath, Storage.initDefault(alloc, .ios));

    var host = try Storage.initDefault(alloc, .host);
    defer host.deinit();
    try t.expect(host.files_dir.len > 0);
}
