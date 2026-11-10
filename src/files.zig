// files.zig — Đọc/ghi/xóa/liệt kê file trong files_dir/cache_dir.
//
// Mọi đường dẫn đều đi qua storage.filesPath/cachePath nên được chặn
// ".." và đường dẫn tuyệt đối giống như Storage. File IO dùng
// std.Io.Threaded bản single-threaded (init_single_threaded): không
// spawn thread, chỉ gọi syscall chặn trên thread hiện tại — vừa đủ
// cho file nhỏ của app, vừa chạy được trên bản Android không link
// libc (không dùng std.c ở đây).
//
// Giới hạn: đọc tối đa max_read_bytes (mặc định 1 MiB) để khỏi đọc
// nhầm file khổng lồ vào RAM; file lớn thì đọc từng phần bằng code
// native, không dùng hàm này.
const std = @import("std");
const errors = @import("errors.zig");
const spinlock = @import("spinlock.zig");
const storage = @import("storage.zig");

pub const MobileError = errors.MobileError;
pub const Storage = storage.Storage;

pub const default_max_read_bytes: usize = 1024 * 1024;

var g_threaded: std.Io.Threaded = .init_single_threaded;

/// Khóa chung cho các thao tác file (v0.3.0): 2 thread ghi cùng
/// 1 file lúc sẽ không xen kẽ nhau. Khóa chỉ giữ trong lúc làm
/// việc với file đó (file app thường nhỏ), đừng gọi hàm file trong
/// lúc đang giữ khóa khác của thư viện theo thứ tự ngược lại.
var g_lock: spinlock.SpinLock = .{};

fn io() std.Io {
    return g_threaded.io();
}

/// Ghi đè (append=false) hoặc nối thêm (append=true) text vào file
/// trong files_dir. Tự tạo thư mục cha nếu cần (ví dụ "notes/a.txt").
pub fn writeText(store: *const Storage, alloc: std.mem.Allocator, relative: []const u8, data: []const u8, append: bool, use_cache: bool) MobileError!void {
    g_lock.lock();
    defer g_lock.unlock();
    const path = if (use_cache)
        try store.cachePath(alloc, relative)
    else
        try store.filesPath(alloc, relative);
    defer alloc.free(path);
    try ensureParentDir(path);

    if (!append) {
        std.Io.Dir.writeFile(.cwd(), io(), .{ .sub_path = path, .data = data, .flags = .{} }) catch |e| {
            return mapError(e);
        };
        return;
    }
    // Append: mở file (tạo mới nếu chưa có), seek tới cuối rồi ghi.
    // Dùng bản openFile thường (không phải openFileAbsolute) vì đường
    // dẫn có thể là tương đối trong test host; đường dẫn tuyệt đối
    // của Android/iOS cũng chạy được qua đây.
    var file = std.Io.Dir.openFile(.cwd(), io(), path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => blk: {
            std.Io.Dir.writeFile(.cwd(), io(), .{ .sub_path = path, .data = "", .flags = .{} }) catch |e2| {
                return mapError(e2);
            };
            break :blk std.Io.Dir.openFile(.cwd(), io(), path, .{ .mode = .write_only }) catch |e3| {
                return mapError(e3);
            };
        },
        else => return mapError(e),
    };
    defer file.close(io());
    const st = file.stat(io()) catch |e| return mapError(e);
    file.writePositionalAll(io(), data, st.size) catch |e| return mapError(e);
}

/// Đọc toàn bộ file thành text (người gọi sở hữu). File không có
/// thì error.FileNotFound, file lớn hơn max_bytes thì
/// error.BufferTooSmall.
pub fn readText(store: *const Storage, alloc: std.mem.Allocator, relative: []const u8, max_bytes: usize, use_cache: bool) MobileError![]u8 {
    g_lock.lock();
    defer g_lock.unlock();
    const path = if (use_cache)
        try store.cachePath(alloc, relative)
    else
        try store.filesPath(alloc, relative);
    defer alloc.free(path);
    const data = std.Io.Dir.readFileAlloc(.cwd(), io(), path, alloc, std.Io.Limit.limited(max_bytes)) catch |e| {
        return mapError(e);
    };
    return data;
}

pub fn deleteFile(store: *const Storage, alloc: std.mem.Allocator, relative: []const u8, use_cache: bool) MobileError!void {
    g_lock.lock();
    defer g_lock.unlock();
    const path = if (use_cache)
        try store.cachePath(alloc, relative)
    else
        try store.filesPath(alloc, relative);
    defer alloc.free(path);
    std.Io.Dir.deleteFile(.cwd(), io(), path) catch |e| {
        return mapError(e);
    };
}

pub fn exists(store: *const Storage, alloc: std.mem.Allocator, relative: []const u8, use_cache: bool) MobileError!bool {
    g_lock.lock();
    defer g_lock.unlock();
    const path = if (use_cache)
        try store.cachePath(alloc, relative)
    else
        try store.filesPath(alloc, relative);
    defer alloc.free(path);
    // Dùng access thường thay vì accessAbsolute: test host dùng
    // đường dẫn tương đối, còn Android/iOS dùng tuyệt đối — cả hai
    // đều chạy qua đây.
    std.Io.Dir.access(.cwd(), io(), path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return mapError(e),
    };
    return true;
}

/// Liệt kê tên file/thư mục con trong một thư mục con (relative là
/// thư mục, "" nghĩa là chính files_dir/cache_dir). Trả về danh sách
/// tên (không kèm đường dẫn), người gọi phải freeList() sau.
pub fn listDir(store: *const Storage, alloc: std.mem.Allocator, relative: []const u8, use_cache: bool) MobileError![][]u8 {
    g_lock.lock();
    defer g_lock.unlock();
    const path = if (relative.len == 0)
        alloc.dupe(u8, if (use_cache) store.cache_dir else store.files_dir) catch return error.OutOfMemory
    else if (use_cache)
        try store.cachePath(alloc, relative)
    else
        try store.filesPath(alloc, relative);
    defer alloc.free(path);

    var dir = std.Io.Dir.openDir(.cwd(), io(), path, .{ .iterate = true }) catch |e| {
        return mapError(e);
    };
    defer dir.close(io());
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (it.next(io()) catch |e| return mapError(e)) |entry| {
        const name = alloc.dupe(u8, entry.name) catch return error.OutOfMemory;
        names.append(alloc, name) catch {
            alloc.free(name);
            return error.OutOfMemory;
        };
    }
    return names.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

pub fn freeList(alloc: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

fn ensureParentDir(path: []const u8) MobileError!void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    const dir = path[0..slash];
    std.Io.Dir.createDirPath(.cwd(), io(), dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return mapError(e),
    };
}

fn mapError(e: anyerror) MobileError {
    return switch (e) {
        error.FileNotFound => error.FileNotFound,
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.BufferTooSmall,
        error.AccessDenied => error.InvalidPath,
        else => error.InvalidPath,
    };
}

test "files write read append delete" {
    const t = std.testing;
    const alloc = t.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer alloc.free(dir);
    var store = try Storage.init(alloc, .host, dir, dir);
    defer store.deinit();

    try t.expect(!try exists(&store, alloc, "notes/a.txt", false));
    try writeText(&store, alloc, "notes/a.txt", "hello", false, false);
    try t.expect(try exists(&store, alloc, "notes/a.txt", false));

    const first = try readText(&store, alloc, "notes/a.txt", default_max_read_bytes, false);
    defer alloc.free(first);
    try t.expectEqualStrings("hello", first);

    try writeText(&store, alloc, "notes/a.txt", " zig", true, false);
    const second = try readText(&store, alloc, "notes/a.txt", default_max_read_bytes, false);
    defer alloc.free(second);
    try t.expectEqualStrings("hello zig", second);

    // Đọc file quá giới hạn thì báo BufferTooSmall.
    try t.expectError(error.BufferTooSmall, readText(&store, alloc, "notes/a.txt", 4, false));
    // File không có thì FileNotFound, đường dẫn xấu thì InvalidPath.
    try t.expectError(error.FileNotFound, readText(&store, alloc, "khong-co.txt", default_max_read_bytes, false));
    try t.expectError(error.InvalidPath, readText(&store, alloc, "../secret", default_max_read_bytes, false));

    try deleteFile(&store, alloc, "notes/a.txt", false);
    try t.expect(!try exists(&store, alloc, "notes/a.txt", false));
    try t.expectError(error.FileNotFound, deleteFile(&store, alloc, "notes/a.txt", false));
}

test "files list dir" {
    const t = std.testing;
    const alloc = t.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer alloc.free(dir);
    var store = try Storage.init(alloc, .host, dir, dir);
    defer store.deinit();

    try writeText(&store, alloc, "a.txt", "1", false, false);
    try writeText(&store, alloc, "b.txt", "2", false, false);
    const names = try listDir(&store, alloc, "", false);
    defer freeList(alloc, names);
    try t.expectEqual(@as(usize, 2), names.len);
    var found_a = false;
    var found_b = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "a.txt")) found_a = true;
        if (std.mem.eql(u8, n, "b.txt")) found_b = true;
    }
    try t.expect(found_a and found_b);

    try t.expectError(error.FileNotFound, listDir(&store, alloc, "khong-co", false));
}
