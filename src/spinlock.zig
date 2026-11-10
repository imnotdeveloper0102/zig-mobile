// spinlock.zig — Khóa spin nhỏ bằng atomic, dùng cho global App ở
// android.zig / ios.zig. Zig 0.17.1 bỏ std.Thread.Mutex, còn
// std.Io.Mutex thì cần Io instance nên không tiện cho code FFI;
// spinlock đủ cho critical section ngắn (chuyển trạng thái, push
// event). App vẫn chỉ gọi từ main thread, khóa này chỉ chống race
// vô tình khi Kotlin/Swift gọi lệch thread.
const std = @import("std");

pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) {}
    }

    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

test "spinlock" {
    var mu: SpinLock = .{};
    mu.lock();
    mu.unlock();
    mu.lock();
    mu.unlock();
}
