// event.zig — Sự kiện và hàng đợi sự kiện (FIFO, ring buffer cố định).
// App Zig không gọi thẳng sang Kotlin/Swift khi có sự kiện, vì gọi ngược
// qua JNI cần method ID và thread attach; thay vào đó app đẩy sự kiện
// vào hàng đợi, phía native poll ra (xem android.zig / ios.zig).
// Riêng iOS và host C có thể đăng ký callback để nhận sự kiện ngay.
//
// Thread-safety (v0.2.0): push/pop được bảo vệ bằng spinlock, nên
// Kotlin/Swift gọi postEvent/pollEvent lệch thread cũng không làm
// hỏng hàng đợi. count/isEmpty/isFull/peek chỉ đọc, không khóa —
// gọi chúng từ nhiều thread cùng lúc thì số liệu có thể lệch một
// nhịp, đừng dùng làm điều kiện đồng bộ.
const std = @import("std");
const errors = @import("errors.zig");
const spinlock = @import("spinlock.zig");

pub const MobileError = errors.MobileError;

pub const EventType = enum(u8) {
    lifecycle = 0,
    custom = 1,
    network_changed = 2,
    low_memory = 3,
    back_pressed = 4,
    permission_result = 5,
    deep_link = 6,

    pub fn toString(self: EventType) []const u8 {
        return switch (self) {
            .lifecycle => "lifecycle",
            .custom => "custom",
            .network_changed => "network_changed",
            .low_memory => "low_memory",
            .back_pressed => "back_pressed",
            .permission_result => "permission_result",
            .deep_link => "deep_link",
        };
    }

    pub fn code(self: EventType) c_int {
        return @intFromEnum(self);
    }

    pub fn fromCode(n: c_int) ?EventType {
        if (n < 0 or n > 6) return null;
        return @enumFromInt(@as(u8, @intCast(n)));
    }

    pub fn fromName(name: []const u8) ?EventType {
        if (std.mem.eql(u8, name, "lifecycle")) return .lifecycle;
        if (std.mem.eql(u8, name, "custom")) return .custom;
        if (std.mem.eql(u8, name, "network_changed")) return .network_changed;
        if (std.mem.eql(u8, name, "low_memory")) return .low_memory;
        if (std.mem.eql(u8, name, "back_pressed")) return .back_pressed;
        if (std.mem.eql(u8, name, "permission_result")) return .permission_result;
        if (std.mem.eql(u8, name, "deep_link")) return .deep_link;
        return null;
    }
};

/// Callback nhận sự kiện ngay khi nó được post (iOS / host C).
pub const EventCallback = *const fn (event_code: c_int, payload_ptr: [*]const u8, payload_len: usize) callconv(.c) void;

var g_event_callback: ?EventCallback = null;

pub fn setGlobalEventCallback(cb: ?EventCallback) void {
    g_event_callback = cb;
}

pub fn getGlobalEventCallback() ?EventCallback {
    return g_event_callback;
}

pub fn notifyEventCallback(kind: EventType, payload: []const u8) void {
    if (g_event_callback) |cb| {
        cb(kind.code(), payload.ptr, payload.len);
    }
}

/// Một sự kiện. payload là bản copy do hàng đợi sở hữu, người lấy ra
/// bằng pop() phải gọi deinit() để trả bộ nhớ.
pub const Event = struct {
    kind: EventType,
    seq: u64,
    payload: []u8,

    pub fn init(alloc: std.mem.Allocator, kind: EventType, seq: u64, payload: []const u8) MobileError!Event {
        const owned = alloc.dupe(u8, payload) catch return error.OutOfMemory;
        return .{ .kind = kind, .seq = seq, .payload = owned };
    }

    pub fn deinit(self: *Event, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
        self.payload = &.{};
    }
};

pub const max_queue = 256;

pub const EventQueue = struct {
    alloc: std.mem.Allocator,
    items: [max_queue]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    next_seq: u64 = 1,
    /// Số event đã bị bỏ vì hàng đợi đầy (v0.3.0). Đọc qua
    /// droppedCount(), đừng đọc trực tiếp từ nhiều thread.
    dropped: u64 = 0,
    lock: spinlock.SpinLock = .{},

    pub fn init(alloc: std.mem.Allocator) EventQueue {
        return .{ .alloc = alloc };
    }

    /// Số event đã bị bỏ vì đầy. Khóa khi đọc nên gọi từ nhiều
    /// thread cũng an toàn.
    pub fn droppedCount(self: *const EventQueue) u64 {
        const mut = @constCast(self);
        mut.lock.lock();
        defer mut.lock.unlock();
        return mut.dropped;
    }

    pub fn deinit(self: *EventQueue) void {
        while (self.pop()) |ev| {
            var e = ev;
            e.deinit(self.alloc);
        }
    }

    pub fn count(self: *const EventQueue) usize {
        return self.len;
    }

    pub fn isEmpty(self: *const EventQueue) bool {
        return self.len == 0;
    }

    pub fn isFull(self: *const EventQueue) bool {
        return self.len >= max_queue;
    }

    pub fn push(self: *EventQueue, kind: EventType, payload: []const u8) MobileError!void {
        // Cấp phát trước khi khóa: giữ khóa càng ngắn càng tốt, và
        // allocator (nhất là DebugAllocator ở test) không nên chạy
        // trong lúc đang giữ spinlock.
        var ev = try Event.init(self.alloc, kind, self.next_seq, payload);
        self.lock.lock();
        defer self.lock.unlock();
        if (self.isFull()) {
            ev.deinit(self.alloc);
            self.dropped += 1;
            return error.QueueFull;
        }
        self.next_seq += 1;
        const idx = (self.head + self.len) % max_queue;
        self.items[idx] = ev;
        self.len += 1;
        return;
    }

    /// Lấy sự kiện cũ nhất ra. Trả null khi trống. Người gọi sở hữu
    /// event trả về và phải deinit() nó.
    pub fn pop(self: *EventQueue) ?Event {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.len == 0) return null;
        const ev = self.items[self.head];
        self.head = (self.head + 1) % max_queue;
        self.len -= 1;
        return ev;
    }

    pub fn peek(self: *const EventQueue) ?*const Event {
        if (self.len == 0) return null;
        return &self.items[self.head];
    }

    pub fn clear(self: *EventQueue) void {
        while (self.pop()) |ev| {
            var e = ev;
            e.deinit(self.alloc);
        }
    }
};

test "event type code" {
    const t = std.testing;
    try t.expectEqual(@as(c_int, 0), EventType.lifecycle.code());
    try t.expectEqual(@as(c_int, 6), EventType.deep_link.code());
    try t.expectEqual(EventType.custom, EventType.fromCode(1).?);
    try t.expectEqual(@as(?EventType, null), EventType.fromCode(7));
    try t.expectEqual(@as(?EventType, null), EventType.fromCode(-1));
    try t.expectEqual(EventType.back_pressed, EventType.fromName("back_pressed").?);
    try t.expectEqual(@as(?EventType, null), EventType.fromName("khong-co"));
}

test "event queue fifo" {
    const t = std.testing;
    const alloc = t.allocator;
    var q = EventQueue.init(alloc);
    defer q.deinit();

    try t.expect(q.isEmpty());
    try t.expect(q.pop() == null);

    try q.push(.custom, "hello");
    try q.push(.lifecycle, "resumed");
    try q.push(.custom, "");
    try t.expectEqual(@as(usize, 3), q.count());
    try t.expectEqualStrings("hello", q.peek().?.payload);

    var ev1 = q.pop().?;
    defer ev1.deinit(alloc);
    try t.expectEqual(EventType.custom, ev1.kind);
    try t.expectEqualStrings("hello", ev1.payload);
    try t.expectEqual(@as(u64, 1), ev1.seq);

    var ev2 = q.pop().?;
    defer ev2.deinit(alloc);
    try t.expectEqualStrings("resumed", ev2.payload);
    try t.expectEqual(@as(u64, 2), ev2.seq);

    q.clear();
    try t.expect(q.isEmpty());
}

test "event queue full" {
    const t = std.testing;
    const alloc = t.allocator;
    var q = EventQueue.init(alloc);
    defer q.deinit();
    var i: usize = 0;
    while (i < max_queue) : (i += 1) {
        try q.push(.custom, "x");
    }
    try t.expect(q.isFull());
    try t.expectError(error.QueueFull, q.push(.custom, "them-mot-cai-nua"));
    // Event bị bỏ được đếm (v0.3.0), không mất dấu lặng lẽ nữa.
    try t.expectEqual(@as(u64, 1), q.droppedCount());
    try t.expectError(error.QueueFull, q.push(.custom, "them-mot-cai-nua"));
    try t.expectEqual(@as(u64, 2), q.droppedCount());
    // Pop ra 1 chỗ thì push lại được, số dropped giữ nguyên.
    var ev = q.pop().?;
    defer ev.deinit(alloc);
    try q.push(.custom, "cho-moi");
    try t.expectEqual(@as(u64, 2), q.droppedCount());
}
