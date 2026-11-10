// background.zig — Mô tả task chạy nền, không tự chạy.
//
// Zig không tự tạo thread/timer được trên mobile một cách an toàn
// (vòng đời app do hệ thống quyết định). Module này chỉ giữ danh
// sách task: id, chạy một lần hay lặp lại, bao lâu chạy một lần,
// chạy tối đa mấy lần. Phía native gọi pollDue(now_ms) khi tới lượt
// (WorkManager / AlarmManager bên Android, BGTaskScheduler bên iOS,
// hoặc đơn giản là mỗi lần app resume), Zig trả về id task tới hạn
// rồi native thực thi việc thật. Zig không chạy việc, chỉ nhắc lịch.
const std = @import("std");
const errors = @import("errors.zig");
const spinlock = @import("spinlock.zig");

pub const MobileError = errors.MobileError;

pub const max_tasks = 32;
pub const max_id_len = 64;

pub const TaskKind = enum(u8) {
    one_shot = 0,
    repeating = 1,

    pub fn toString(self: TaskKind) []const u8 {
        return switch (self) {
            .one_shot => "one_shot",
            .repeating => "repeating",
        };
    }

    pub fn code(self: TaskKind) c_int {
        return @intFromEnum(self);
    }

    pub fn fromCode(n: c_int) ?TaskKind {
        if (n < 0 or n > 1) return null;
        return @enumFromInt(@as(u8, @intCast(n)));
    }
};

pub const Task = struct {
    id: []u8,
    kind: TaskKind,
    interval_ms: u64,
    max_runs: ?u32,
    run_count: u32 = 0,
    next_due_ms: u64,
    active: bool = true,
};

pub const TaskQueue = struct {
    alloc: std.mem.Allocator,
    tasks: std.ArrayList(Task),
    /// Khóa cho add/remove/pollDue/count (v0.3.0). find() không tự
    /// khóa — chỉ gọi khi đã giữ mu hoặc từ 1 thread duy nhất, vì
    /// spinlock khóa lại trên cùng thread sẽ kẹt vĩnh viễn.
    mu: spinlock.SpinLock = .{},

    pub fn init(alloc: std.mem.Allocator) TaskQueue {
        return .{ .alloc = alloc, .tasks = std.ArrayList(Task).empty };
    }

    pub fn deinit(self: *TaskQueue) void {
        for (self.tasks.items) |task| {
            self.alloc.free(task.id);
        }
        self.tasks.deinit(self.alloc);
    }

    pub fn count(self: *const TaskQueue) usize {
        const mut = @constCast(self);
        mut.mu.lock();
        defer mut.mu.unlock();
        return mut.tasks.items.len;
    }

    pub fn countActive(self: *const TaskQueue) usize {
        const mut = @constCast(self);
        mut.mu.lock();
        defer mut.mu.unlock();
        var n: usize = 0;
        for (mut.tasks.items) |task| {
            if (task.active) n += 1;
        }
        return n;
    }

    pub fn find(self: *const TaskQueue, id: []const u8) ?*Task {
        for (self.tasks.items) |*task| {
            if (std.mem.eql(u8, task.id, id)) return task;
        }
        return null;
    }

    /// Thêm task. interval_ms là "sau bao lâu thì chạy lần đầu";
    /// task repeating mà interval = 0 thì vô nghĩa nên bị chặn.
    /// max_runs = null nghĩa là lặp vô hạn (chỉ task repeating).
    pub fn add(self: *TaskQueue, id: []const u8, kind: TaskKind, interval_ms: u64, max_runs: ?u32, now_ms: u64) MobileError!void {
        self.mu.lock();
        defer self.mu.unlock();
        if (id.len == 0 or id.len > max_id_len) return error.InvalidTask;
        if (self.find(id) != null) return error.InvalidTask;
        if (self.tasks.items.len >= max_tasks) return error.InvalidTask;
        if (kind == .repeating and interval_ms == 0) return error.InvalidTask;
        if (max_runs) |m| {
            if (m == 0) return error.InvalidTask;
        }
        if (kind == .one_shot and max_runs != null and max_runs.? != 1) return error.InvalidTask;
        const owned = self.alloc.dupe(u8, id) catch return error.OutOfMemory;
        errdefer self.alloc.free(owned);
        self.tasks.append(self.alloc, .{
            .id = owned,
            .kind = kind,
            .interval_ms = interval_ms,
            .max_runs = max_runs,
            .next_due_ms = now_ms + interval_ms,
        }) catch {
            self.alloc.free(owned);
            return error.OutOfMemory;
        };
    }

    pub fn remove(self: *TaskQueue, id: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.tasks.items, 0..) |task, i| {
            if (std.mem.eql(u8, task.id, id)) {
                self.alloc.free(task.id);
                _ = self.tasks.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Trả id task tới hạn đầu tiên tại now_ms, hoặc null nếu chưa
    /// tới lượt task nào. Chuỗi trả về mượn từ TaskQueue — người gọi
    /// phải copy ngay trước khi gọi pollDue/remove lần nữa.
    /// Task one-shot chạy xong thì tắt; repeating thì hẹn lần sau,
    /// đủ max_runs thì tắt.
    pub fn pollDue(self: *TaskQueue, now_ms: u64) ?[]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.tasks.items) |*task| {
            if (!task.active) continue;
            if (now_ms < task.next_due_ms) continue;
            task.run_count += 1;
            if (task.kind == .one_shot) {
                task.active = false;
            } else {
                if (task.max_runs) |m| {
                    if (task.run_count >= m) {
                        task.active = false;
                    } else {
                        task.next_due_ms = now_ms + task.interval_ms;
                    }
                } else {
                    task.next_due_ms = now_ms + task.interval_ms;
                }
            }
            return task.id;
        }
        return null;
    }

    /// Payload event khi task tới hạn, dạng "task:sync-photos".
    pub fn formatPayload(id: []const u8, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "task:{s}", .{id}) catch buf[0..0];
    }
};

test "task kind code" {
    const t = std.testing;
    try t.expectEqual(@as(c_int, 1), TaskKind.repeating.code());
    try t.expectEqual(TaskKind.one_shot, TaskKind.fromCode(0).?);
    try t.expectEqual(@as(?TaskKind, null), TaskKind.fromCode(2));
}

test "background one shot" {
    const t = std.testing;
    const alloc = t.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();

    try q.add("sync-once", .one_shot, 1000, null, 0);
    try t.expectEqual(@as(usize, 1), q.count());
    try t.expect(q.pollDue(999) == null);
    const due = q.pollDue(1000).?;
    try t.expectEqualStrings("sync-once", due);
    // One-shot chỉ chạy một lần.
    try t.expect(q.pollDue(5000) == null);
    try t.expectEqual(@as(usize, 0), q.countActive());
    try t.expect(q.remove("sync-once"));
    try t.expect(!q.remove("sync-once"));
}

test "background repeating with max runs" {
    const t = std.testing;
    const alloc = t.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();

    try q.add("heartbeat", .repeating, 500, 3, 0);
    try t.expectEqualStrings("heartbeat", q.pollDue(500).?);
    try t.expect(q.pollDue(600) == null);
    try t.expectEqualStrings("heartbeat", q.pollDue(1000).?);
    try t.expectEqualStrings("heartbeat", q.pollDue(1500).?);
    // Đủ 3 lần thì tắt.
    try t.expect(q.pollDue(10000) == null);
    try t.expectEqual(@as(usize, 0), q.countActive());
    try t.expectEqual(@as(u32, 3), q.find("heartbeat").?.run_count);
}

test "background invalid tasks" {
    const t = std.testing;
    const alloc = t.allocator;
    var q = TaskQueue.init(alloc);
    defer q.deinit();

    try t.expectError(error.InvalidTask, q.add("", .one_shot, 100, null, 0));
    try t.expectError(error.InvalidTask, q.add("x", .repeating, 0, null, 0));
    try t.expectError(error.InvalidTask, q.add("x", .repeating, 100, 0, 0));
    try t.expectError(error.InvalidTask, q.add("x", .one_shot, 100, 2, 0));
    try q.add("dup", .one_shot, 100, null, 0);
    try t.expectError(error.InvalidTask, q.add("dup", .one_shot, 100, null, 0));

    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("task:heartbeat", TaskQueue.formatPayload("heartbeat", &buf));
}
