// hash.zig — SHA-256 cho chuỗi và file, để kiểm tra file integrity.
//
// Dùng std.crypto.hash.sha2.Sha256 (thuần Zig, không cần libc nên
// chạy được trên bản Android). Hash trả về dạng hex chữ thường, 64
// ký tự. File đọc tối đa 1 MiB mặc định (giới hạn của files.readText)
// — file lớn hơn thì native tự chia nhỏ rồi hash từng phần, không
// dùng hàm này.
const std = @import("std");
const errors = @import("errors.zig");
const files = @import("files.zig");
const storage = @import("storage.zig");

pub const MobileError = errors.MobileError;
pub const Storage = storage.Storage;

pub const hex_len = 64;

/// SHA-256 của data, ghi hex chữ thường vào out (đúng 64 byte).
pub fn sha256Hex(data: []const u8, out: *[hex_len]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(data);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);
}

/// SHA-256 của data, trả chuỗi hex do người gọi sở hữu.
pub fn sha256Alloc(alloc: std.mem.Allocator, data: []const u8) MobileError![]u8 {
    var hex: [hex_len]u8 = undefined;
    sha256Hex(data, &hex);
    return alloc.dupe(u8, &hex) catch return error.OutOfMemory;
}

/// SHA-256 của file trong files_dir/cache_dir. File không có thì
/// error.FileNotFound, file lớn hơn max_bytes thì BufferTooSmall.
pub fn sha256File(store: *const Storage, alloc: std.mem.Allocator, relative: []const u8, max_bytes: usize, use_cache: bool) MobileError![]u8 {
    const data = try files.readText(store, alloc, relative, max_bytes, use_cache);
    defer alloc.free(data);
    return sha256Alloc(alloc, data);
}

/// Kiểm tra file có đúng hash mong đợi không. Hash mong đợi so sánh
/// không phân biệt hoa/thường (hex viết hoa cũng được). Trả false
/// khi file không có hoặc hash lệch — không trả lỗi, để phía native
/// chỉ cần một câu trả lời có/không.
pub fn verifyFile(store: *const Storage, alloc: std.mem.Allocator, relative: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len != hex_len) return false;
    const actual = sha256File(store, alloc, relative, files.default_max_read_bytes, false) catch return false;
    defer alloc.free(actual);
    for (actual, expected_hex) |a, e| {
        if (std.ascii.toLower(a) != std.ascii.toLower(e)) return false;
    }
    return true;
}

test "sha256 known vectors" {
    const t = std.testing;
    const alloc = t.allocator;
    var hex: [hex_len]u8 = undefined;

    // Vector chuẩn FIPS 180-4.
    sha256Hex("", &hex);
    try t.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &hex);
    sha256Hex("abc", &hex);
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &hex);
    sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", &hex);
    try t.expectEqualStrings("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", &hex);

    const owned = try sha256Alloc(alloc, "hello");
    defer alloc.free(owned);
    try t.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", owned);
}

test "sha256 file verify" {
    const t = std.testing;
    const alloc = t.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer alloc.free(dir);
    var store = try Storage.init(alloc, .host, dir, dir);
    defer store.deinit();

    try files.writeText(&store, alloc, "data.txt", "abc", false, false);
    const hex = try sha256File(&store, alloc, "data.txt", files.default_max_read_bytes, false);
    defer alloc.free(hex);
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex);

    // Verify đúng (kể cả hex viết hoa) thì true, sai thì false.
    try t.expect(verifyFile(&store, alloc, "data.txt", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    try t.expect(verifyFile(&store, alloc, "data.txt", "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"));
    try t.expect(!verifyFile(&store, alloc, "data.txt", "0000000000000000000000000000000000000000000000000000000000000000"));
    try t.expect(!verifyFile(&store, alloc, "khong-co.txt", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    try t.expect(!verifyFile(&store, alloc, "data.txt", "ngan-qua"));

    try t.expectError(error.FileNotFound, sha256File(&store, alloc, "khong-co.txt", files.default_max_read_bytes, false));
}
