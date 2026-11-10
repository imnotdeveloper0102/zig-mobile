// app.zig — Cái app, phần lõi chung. Giữ trạng thái vòng đời, hàng đợi
// sự kiện, logger và storage. Kotlin/Swift chỉ việc gọi onCreate /
// onResume / ... đúng lúc, còn chuyển trạng thái nào hợp lệ thì Zig lo.
// Thread-safety (v0.2.0): chuyển trạng thái được khóa bằng spinlock
// (check + đổi trạng thái là một nhịp nguyên tử), postEvent/pollEvent
// được khóa trong EventQueue. Các hàm còn lại vẫn nên gọi từ main
// thread như Activity/ViewController vẫn làm.
const std = @import("std");
const errors = @import("errors.zig");
const event = @import("event.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const spinlock = @import("spinlock.zig");
const storage = @import("storage.zig");

pub const MobileError = errors.MobileError;
pub const EventType = event.EventType;
pub const Event = event.Event;
pub const Platform = platform.Platform;

pub const State = enum {
    unknown,
    created,
    started,
    resumed,
    paused,
    stopped,
    destroyed,

    pub fn toString(self: State) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .created => "created",
            .started => "started",
            .resumed => "resumed",
            .paused => "paused",
            .stopped => "stopped",
            .destroyed => "destroyed",
        };
    }

    pub fn code(self: State) c_int {
        return switch (self) {
            .unknown => 0,
            .created => 1,
            .started => 2,
            .resumed => 3,
            .paused => 4,
            .stopped => 5,
            .destroyed => 6,
        };
    }

    pub fn fromCode(n: c_int) ?State {
        return switch (n) {
            0 => .unknown,
            1 => .created,
            2 => .started,
            3 => .resumed,
            4 => .paused,
            5 => .stopped,
            6 => .destroyed,
            else => null,
        };
    }
};

/// Bảng chuyển trạng thái hợp lệ, theo vòng đời Activity (Android) và
/// ViewController (iOS) — hai bên giống nhau ở mức này nên dùng chung.
pub fn canTransition(from: State, to: State) bool {
    return switch (from) {
        .unknown => to == .created,
        .created => to == .started or to == .destroyed,
        .started => to == .resumed or to == .stopped,
        .resumed => to == .paused,
        .paused => to == .resumed or to == .stopped,
        .stopped => to == .started or to == .destroyed,
        .destroyed => false,
    };
}

pub const AppOptions = struct {
    platform: Platform = platform.current(),
    files_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    log_level: log.Level = .info,
    name: []const u8 = "zig-mobile",
};

pub const App = struct {
    alloc: std.mem.Allocator,
    name: []const u8,
    platform: Platform,
    state: State = .unknown,
    storage: storage.Storage,
    logger: log.Logger,
    events: event.EventQueue,
    mu: spinlock.SpinLock = .{},

    pub fn init(alloc: std.mem.Allocator, opts: AppOptions) MobileError!App {
        var store: storage.Storage = undefined;
        if (opts.files_dir != null and opts.cache_dir != null) {
            store = try storage.Storage.init(alloc, opts.platform, opts.files_dir.?, opts.cache_dir.?);
        } else if (opts.files_dir == null and opts.cache_dir == null) {
            store = try storage.Storage.initDefault(alloc, opts.platform);
        } else {
            // Đưa một cái mà thiếu cái kia: thà báo lỗi còn hơn đoán.
            return error.InvalidPath;
        }
        errdefer store.deinit();
        return .{
            .alloc = alloc,
            .name = opts.name,
            .platform = opts.platform,
            .storage = store,
            .logger = log.Logger.init(opts.log_level),
            .events = event.EventQueue.init(alloc),
        };
    }

    pub fn deinit(self: *App) void {
        self.events.deinit();
        self.storage.deinit();
        self.state = .unknown;
    }

    pub fn transition(self: *App, to: State) MobileError!void {
        self.mu.lock();
        const ok = canTransition(self.state, to);
        if (!ok) {
            self.mu.unlock();
            self.logger.warn("app", "chuyen trang thai khong hop le");
            return error.InvalidTransition;
        }
        self.state = to;
        self.mu.unlock();
        self.logger.info("app", to.toString());
        self.events.push(.lifecycle, to.toString()) catch {
            self.logger.warn("app", "hang doi su kien day, bo qua lifecycle event");
        };
        event.notifyEventCallback(.lifecycle, to.toString());
    }

    pub fn onCreate(self: *App) MobileError!void {
        try self.transition(.created);
    }

    pub fn onStart(self: *App) MobileError!void {
        try self.transition(.started);
    }

    pub fn onResume(self: *App) MobileError!void {
        try self.transition(.resumed);
    }

    pub fn onPause(self: *App) MobileError!void {
        try self.transition(.paused);
    }

    pub fn onStop(self: *App) MobileError!void {
        try self.transition(.stopped);
    }

    pub fn onDestroy(self: *App) MobileError!void {
        try self.transition(.destroyed);
    }

    pub fn postEvent(self: *App, kind: EventType, payload: []const u8) MobileError!void {
        try self.events.push(kind, payload);
        event.notifyEventCallback(kind, payload);
    }

    /// Lấy sự kiện cũ nhất ra, người gọi phải deinit() nó.
    pub fn pollEvent(self: *App) ?Event {
        return self.events.pop();
    }

    /// Số event đã bị bỏ vì hàng đợi đầy (v0.3.0). Native dùng để
    /// biết mình poll có kịp không — tăng liên tục nghĩa là native
    /// poll quá chậm, cần poll thường xuyên hơn.
    pub fn droppedEvents(self: *const App) u64 {
        return self.events.droppedCount();
    }

    pub fn isForeground(self: *const App) bool {
        return self.state == .resumed;
    }

    pub fn isRunning(self: *const App) bool {
        return self.state == .started or self.state == .resumed or self.state == .paused;
    }
};

test "lifecycle happy path" {
    const t = std.testing;
    const alloc = t.allocator;
    var app = try App.init(alloc, .{});
    defer app.deinit();

    try t.expectEqual(State.unknown, app.state);
    try app.onCreate();
    try app.onStart();
    try app.onResume();
    try t.expect(app.isForeground());
    try t.expect(app.isRunning());
    try app.onPause();
    try app.onResume();
    try app.onPause();
    try app.onStop();
    try app.onStart();
    try app.onResume();
    try app.onPause();
    try app.onStop();
    try app.onDestroy();
    try t.expect(!app.isRunning());
    try t.expectEqual(State.destroyed, app.state);

    // Mỗi lần chuyển trạng thái đều đẩy 1 lifecycle event.
    try t.expectEqual(@as(usize, 12), app.events.count());
    var first = app.pollEvent().?;
    defer first.deinit(alloc);
    try t.expectEqualStrings("created", first.payload);
}

test "lifecycle invalid transitions" {
    const t = std.testing;
    const alloc = t.allocator;
    var app = try App.init(alloc, .{});
    defer app.deinit();

    // Chưa create mà đòi resume.
    try t.expectError(error.InvalidTransition, app.onResume());
    // Create rồi nhảy thẳng resume, bỏ qua start.
    try app.onCreate();
    try t.expectError(error.InvalidTransition, app.onResume());
    try t.expectEqual(State.created, app.state);
    // Destroy xong thì hết đường quay lại.
    try app.onDestroy();
    try t.expectError(error.InvalidTransition, app.onStart());
    try t.expectError(error.InvalidTransition, app.onCreate());
}

test "app post and poll event" {
    const t = std.testing;
    const alloc = t.allocator;
    var app = try App.init(alloc, .{ .files_dir = "/tmp", .cache_dir = "/tmp" });
    defer app.deinit();

    try app.postEvent(.custom, "hello-mobile");
    try app.postEvent(.back_pressed, "");
    var ev = app.pollEvent().?;
    defer ev.deinit(alloc);
    try t.expectEqual(EventType.custom, ev.kind);
    try t.expectEqualStrings("hello-mobile", ev.payload);
    try t.expect(app.pollEvent() != null);
    try t.expect(app.pollEvent() == null);

    // Đưa một nửa đường dẫn storage thì báo lỗi, không đoán nốt.
    try t.expectError(error.InvalidPath, App.init(alloc, .{ .files_dir = "/tmp" }));
}
