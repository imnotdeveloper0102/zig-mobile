// ios.zig — Cầu C ABI cho iOS (và cho host C nói chung).
//
// Swift không gọi được Zig trực tiếp, nhưng gọi được C qua bridging
// header (xem examples/ios/). Các hàm dưới đây đều là C thuần:
//   mobile_init(files_dir, cache_dir) — files/cache lấy từ FileManager
//   mobile_lifecycle(state_code)      — chuyển trạng thái vòng đời
//   mobile_on_event(code, ptr, len)   — post event kèm payload
//   mobile_poll_event(...)            — Swift poll event ra
//   mobile_state() / mobile_version() — đọc trạng thái / version
//   mobile_set_log_callback(cb)       — log chảy về os_log qua Swift
//   mobile_set_event_callback(cb)     — nhận event ngay, không cần poll
//   mobile_shutdown()                 — dọn app
//
// Trả về 0 = ok, số âm = mã lỗi (xem errors.errorCode). Riêng
// mobile_poll_event trả 1 = có event, 0 = trống.
//
// CHƯA kiểm chứng trên iOS thật: máy này không có Xcode, không có
// iPhone Simulator, không sign được app. Phần C ABI chỉ mới kiểm chứng
// bằng test host (gọi đúng các hàm này trên Linux) và cross-compile
// sang aarch64-ios (xem README).
const std = @import("std");
const app_mod = @import("app.zig");
const background = @import("background.zig");
const canvas = @import("canvas.zig");
const device = @import("device.zig");
const errors = @import("errors.zig");
const event = @import("event.zig");
const files_mod = @import("files.zig");
const hash = @import("hash.zig");
const http = @import("http.zig");
const json = @import("json.zig");
const log = @import("log.zig");
const network = @import("network.zig");
const permissions = @import("permissions.zig");
const platform = @import("platform.zig");
const settings = @import("settings.zig");
const spinlock = @import("spinlock.zig");
const time = @import("time.zig");
const ui = @import("ui.zig");
const version = @import("version.zig");

const App = app_mod.App;
const State = app_mod.State;
const MobileError = errors.MobileError;

const alloc = std.heap.page_allocator;

var g_mutex: spinlock.SpinLock = .{};
var g_app: ?App = null;
/// Trạng thái xin quyền + mạng (v0.2.0), không cần allocator.
var g_permissions: permissions.PermissionStore = .{};
var g_network: network.NetworkStatus = .{};
/// Cài đặt + task nền + thông tin thiết bị (v0.2.0), tạo lúc init.
var g_settings: ?settings.Settings = null;
var g_tasks: ?background.TaskQueue = null;
var g_device: ?device.DeviceInfo = null;

fn appPtr() ?*App {
    if (g_app) |*a| return a;
    return null;
}

/// Tạo Settings/TaskQueue nếu chưa có. Gọi khi đã giữ g_mutex.
fn ensureExtras() void {
    if (g_settings == null) g_settings = settings.Settings.init(alloc);
    if (g_tasks == null) g_tasks = background.TaskQueue.init(alloc);
}

/// Dọn Settings/TaskQueue/DeviceInfo. Gọi khi đã giữ g_mutex.
fn deinitExtras() void {
    if (g_settings) |*s| s.deinit();
    g_settings = null;
    if (g_tasks) |*q| q.deinit();
    g_tasks = null;
    if (g_device) |*d| d.deinit();
    g_device = null;
}

fn storagePtr() ?*const @import("storage.zig").Storage {
    const a = appPtr() orelse return null;
    return &a.storage;
}

fn isNullPtr(p: anytype) bool {
    return @intFromPtr(p) == 0;
}

pub export fn mobile_init(files_dir: [*:0]const u8, cache_dir: [*:0]const u8) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_app != null) return errors.errorCode(error.AlreadyInitialized);
    if (@intFromPtr(files_dir) == 0 or @intFromPtr(cache_dir) == 0) {
        return errors.errorCode(error.InvalidPath);
    }
    const files = std.mem.span(files_dir);
    const cache = std.mem.span(cache_dir);
    g_app = App.init(alloc, .{
        .platform = .ios,
        .files_dir = files,
        .cache_dir = cache,
    }) catch |e| {
        return errors.errorCode(e);
    };
    ensureExtras();
    return 0;
}

pub export fn mobile_shutdown() callconv(.c) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (appPtr()) |a| {
        a.deinit();
    }
    g_app = null;
    deinitExtras();
}

/// Chuyển trạng thái vòng đời bằng mã số (0 unknown ... 6 destroyed).
pub export fn mobile_lifecycle(state_code: c_int) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = appPtr() orelse return errors.errorCode(error.NotInitialized);
    const to = State.fromCode(state_code) orelse return errors.errorCode(error.InvalidTransition);
    a.transition(to) catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

pub export fn mobile_state() callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = appPtr() orelse return -1;
    return a.state.code();
}

pub export fn mobile_on_event(event_code: c_int, payload_ptr: [*]const u8, payload_len: usize) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = appPtr() orelse return errors.errorCode(error.NotInitialized);
    if (payload_len > 0 and @intFromPtr(payload_ptr) == 0) {
        return errors.errorCode(error.InvalidEvent);
    }
    const kind = event.EventType.fromCode(event_code) orelse return errors.errorCode(error.InvalidEvent);
    const payload = if (payload_len == 0) "" else payload_ptr[0..payload_len];
    a.postEvent(kind, payload) catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

/// Poll event cũ nhất. Trả 1 và ghi mã event vào out_code, copy payload
/// vào out_buf (ghi số byte đã copy vào out_written); trả 0 khi trống;
/// trả mã lỗi âm khi buffer quá nhỏ (lúc đó out_written = số byte cần).
pub export fn mobile_poll_event(out_code: *c_int, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = appPtr() orelse return errors.errorCode(error.NotInitialized);
    var ev = a.pollEvent() orelse return 0;
    defer ev.deinit(a.alloc);
    out_code.* = ev.kind.code();
    if (ev.payload.len > out_capacity) {
        out_written.* = ev.payload.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..ev.payload.len], ev.payload);
    out_written.* = ev.payload.len;
    return 1;
}

pub export fn mobile_version() callconv(.c) [*:0]const u8 {
    return version.version_string;
}

pub export fn mobile_set_log_callback(cb: ?log.LogCallback) callconv(.c) void {
    log.setGlobalLogCallback(cb);
}

pub export fn mobile_set_event_callback(cb: ?event.EventCallback) callconv(.c) void {
    event.setGlobalEventCallback(cb);
}

// ---- v0.2.0: quyền, mạng, cài đặt, file, thiết bị, task nền ----

/// Mã trạng thái quyền (0..3), -1 nếu mã quyền sai.
pub export fn mobile_permission_state(perm_code: c_int) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const perm = permissions.Permission.fromCode(perm_code) orelse return -1;
    return g_permissions.state(perm).code();
}

/// Báo kết quả xin quyền về Zig. Đẩy event permission_result với
/// payload "camera:granted". Trả 0 = ok, số âm = mã lỗi.
pub export fn mobile_permission_mark_result(perm_code: c_int, state_code: c_int) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const perm = permissions.Permission.fromCode(perm_code) orelse return errors.errorCode(error.InvalidPermission);
    const st = permissions.PermissionState.fromCode(state_code) orelse return errors.errorCode(error.InvalidPermission);
    g_permissions.markResult(perm, st);
    if (appPtr()) |a| {
        var buf: [64]u8 = undefined;
        const payload = permissions.PermissionStore.formatPayload(perm, st, &buf);
        a.postEvent(.permission_result, payload) catch {};
    }
    return 0;
}

/// Native báo trạng thái mạng (0 offline, 1 wifi, 2 cellular,
// 3 unknown). Đẩy event network_changed với payload là tên trạng thái.
pub export fn mobile_network_set_connectivity(code: c_int) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const c = network.Connectivity.fromCode(code) orelse return errors.errorCode(error.NetworkUnavailable);
    g_network.setConnectivity(c);
    if (appPtr()) |a| {
        a.postEvent(.network_changed, c.toString()) catch {};
    }
    return 0;
}

/// Kiểm tra TCP tới host:port, chờ timeout_ms. Trả 1 = tới được,
// 0 = không tới được, -1 = tham số sai.
pub export fn mobile_network_reachable(host: [*:0]const u8, port: c_int, timeout_ms: c_int) callconv(.c) c_int {
    if (isNullPtr(host)) return -1;
    if (port <= 0 or port > 65535) return -1;
    return if (network.checkTcp(std.mem.span(host), @intCast(port), timeout_ms)) 1 else 0;
}

/// Đặt thông tin thiết bị. Trả 0 = ok, số âm = mã lỗi.
pub export fn mobile_device_set_info(os_version: [*:0]const u8, app_version: [*:0]const u8, locale: [*:0]const u8, model: [*:0]const u8) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(os_version) or isNullPtr(app_version) or isNullPtr(locale) or isNullPtr(model)) {
        return errors.errorCode(error.InvalidDeviceInfo);
    }
    const info = device.DeviceInfo.init(
        alloc,
        .ios,
        platform.archName(),
        std.mem.span(os_version),
        std.mem.span(app_version),
        std.mem.span(locale),
        std.mem.span(model),
    ) catch |e| {
        return errors.errorCode(e);
    };
    if (g_device) |*d| d.deinit();
    g_device = info;
    return 0;
}

pub export fn mobile_settings_set_string(key: [*:0]const u8, value: [*:0]const u8) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(key) or isNullPtr(value)) return errors.errorCode(error.InvalidSetting);
    ensureExtras();
    const s = if (g_settings) |*st| st else return errors.errorCode(error.NotInitialized);
    s.setString(std.mem.span(key), std.mem.span(value)) catch |e| return errors.errorCode(e);
    return 0;
}

pub export fn mobile_settings_set_int(key: [*:0]const u8, value: i64) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(key)) return errors.errorCode(error.InvalidSetting);
    ensureExtras();
    const s = if (g_settings) |*st| st else return errors.errorCode(error.NotInitialized);
    s.setInt(std.mem.span(key), value) catch |e| return errors.errorCode(e);
    return 0;
}

pub export fn mobile_settings_set_bool(key: [*:0]const u8, value: c_int) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(key)) return errors.errorCode(error.InvalidSetting);
    ensureExtras();
    const s = if (g_settings) |*st| st else return errors.errorCode(error.NotInitialized);
    s.setBool(std.mem.span(key), value != 0) catch |e| return errors.errorCode(e);
    return 0;
}

/// Lấy chuỗi cài đặt. Trả 1 = có (copy vào out_buf, out_written =
/// số byte), 0 = key không có hoặc không phải chuỗi, -12 =
/// BufferTooSmall (out_written = số byte cần), số âm khác = mã lỗi.
pub export fn mobile_settings_get_string(key: [*:0]const u8, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(key)) return errors.errorCode(error.InvalidSetting);
    ensureExtras();
    const s = if (g_settings) |*st| st else return errors.errorCode(error.NotInitialized);
    const v = s.getString(std.mem.span(key)) orelse return 0;
    if (v.len > out_capacity) {
        out_written.* = v.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..v.len], v);
    out_written.* = v.len;
    return 1;
}

pub export fn mobile_settings_get_int(key: [*:0]const u8, default_value: i64) callconv(.c) i64 {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(key)) return default_value;
    ensureExtras();
    const s = if (g_settings) |*st| st else return default_value;
    return s.getInt(std.mem.span(key)) orelse default_value;
}

pub export fn mobile_settings_get_bool(key: [*:0]const u8, default_value: c_int) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(key)) return default_value;
    ensureExtras();
    const s = if (g_settings) |*st| st else return default_value;
    const v = s.getBool(std.mem.span(key)) orelse return default_value;
    return if (v) 1 else 0;
}

/// Lưu cài đặt xuống files_dir/settings.txt.
pub export fn mobile_settings_save() callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    ensureExtras();
    const s = if (g_settings) |*st| st else return errors.errorCode(error.NotInitialized);
    s.save(store, "settings.txt") catch |e| return errors.errorCode(e);
    return 0;
}

/// Tải cài đặt từ files_dir/settings.txt (chưa có file thì không lỗi).
pub export fn mobile_settings_load() callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    ensureExtras();
    const s = if (g_settings) |*st| st else return errors.errorCode(error.NotInitialized);
    s.load(store, "settings.txt") catch |e| return errors.errorCode(e);
    return 0;
}

pub export fn mobile_file_write_text(relative: [*:0]const u8, text: [*:0]const u8, append: c_int) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(relative) or isNullPtr(text)) return errors.errorCode(error.InvalidPath);
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    files_mod.writeText(store, alloc, std.mem.span(relative), std.mem.span(text), append != 0, false) catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

/// Đọc file text trong files_dir. Trả 1 = có (copy vào out_buf),
/// 0 = file không có, số âm = mã lỗi (kể cả BufferTooSmall).
pub export fn mobile_file_read_text(relative: [*:0]const u8, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(relative)) return errors.errorCode(error.InvalidPath);
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    const data = files_mod.readText(store, alloc, std.mem.span(relative), files_mod.default_max_read_bytes, false) catch |e| {
        if (e == error.FileNotFound) return 0;
        return errors.errorCode(e);
    };
    defer alloc.free(data);
    if (data.len > out_capacity) {
        out_written.* = data.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..data.len], data);
    out_written.* = data.len;
    return 1;
}

pub export fn mobile_file_delete(relative: [*:0]const u8) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(relative)) return errors.errorCode(error.InvalidPath);
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    files_mod.deleteFile(store, alloc, std.mem.span(relative), false) catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

/// Trả 1 = file có, 0 = không có, số âm = mã lỗi.
pub export fn mobile_file_exists(relative: [*:0]const u8) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(relative)) return errors.errorCode(error.InvalidPath);
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    const ok = files_mod.exists(store, alloc, std.mem.span(relative), false) catch |e| {
        return errors.errorCode(e);
    };
    return if (ok) 1 else 0;
}

/// Thêm task nền. max_runs <= 0 nghĩa là lặp vô hạn (chỉ task
/// repeating). Trả 0 = ok, số âm = mã lỗi.
pub export fn mobile_background_add_task(id: [*:0]const u8, kind: c_int, interval_ms: i64, max_runs: c_int) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(id)) return errors.errorCode(error.InvalidTask);
    const k = background.TaskKind.fromCode(kind) orelse return errors.errorCode(error.InvalidTask);
    ensureExtras();
    const q = if (g_tasks) |*tq| tq else return errors.errorCode(error.NotInitialized);
    q.add(std.mem.span(id), k, @intCast(interval_ms), if (max_runs <= 0) null else @intCast(max_runs), 0) catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

/// Lấy id task tới hạn (now_ms tính bằng mili-giây). Trả 1 = có task
/// (copy id vào out_buf), 0 = chưa tới lượt, số âm = mã lỗi.
pub export fn mobile_background_poll_due(now_ms: i64, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    ensureExtras();
    const q = if (g_tasks) |*tq| tq else return errors.errorCode(error.NotInitialized);
    const id = q.pollDue(@intCast(now_ms)) orelse return 0;
    if (id.len > out_capacity) {
        out_written.* = id.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..id.len], id);
    out_written.* = id.len;
    return 1;
}

/// Trả 1 = đã xóa, 0 = không có task đó.
pub export fn mobile_background_remove_task(id: [*:0]const u8) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(id)) return errors.errorCode(error.InvalidTask);
    ensureExtras();
    const q = if (g_tasks) |*tq| tq else return errors.errorCode(error.NotInitialized);
    return if (q.remove(std.mem.span(id))) 1 else 0;
}

// ---- v0.3.0: thời gian, hash, HTTP, JSON, UI/canvas, event bị bỏ ----
//
// mobile_ui_demo_json / mobile_canvas_demo_json trả JSON của cây UI
// demo (xem ui.demoTree): Swift dùng để thử render, chưa phải cây
// UI thật của app.

pub export fn mobile_time_now_ms() callconv(.c) i64 {
    return time.nowMs();
}

pub export fn mobile_time_monotonic_ms() callconv(.c) i64 {
    return time.monotonicMs();
}

/// SHA-256 hex (64 ký tự) của chuỗi. Trả 1 = có (copy vào out_buf),
/// -12 = BufferTooSmall (out_written = 64), số âm khác = mã lỗi.
pub export fn mobile_hash_sha256(text: [*:0]const u8, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    if (isNullPtr(text)) return errors.errorCode(error.InvalidPath);
    var hex: [hash.hex_len]u8 = undefined;
    hash.sha256Hex(std.mem.span(text), &hex);
    if (hex.len > out_capacity) {
        out_written.* = hex.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..hex.len], &hex);
    out_written.* = hex.len;
    return 1;
}

/// SHA-256 hex của file trong files_dir. Trả 1 = có, 0 = file không
/// có, -12 = BufferTooSmall, số âm khác = mã lỗi.
pub export fn mobile_hash_file_sha256(relative: [*:0]const u8, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(relative)) return errors.errorCode(error.InvalidPath);
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    const hex = hash.sha256File(store, alloc, std.mem.span(relative), files_mod.default_max_read_bytes, false) catch |e| {
        if (e == error.FileNotFound) return 0;
        return errors.errorCode(e);
    };
    defer alloc.free(hex);
    if (hex.len > out_capacity) {
        out_written.* = hex.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..hex.len], hex);
    out_written.* = hex.len;
    return 1;
}

/// Status code HTTP (200, 404, ...), -1 nếu nối không được / hết giờ.
pub export fn mobile_http_head_status(host: [*:0]const u8, port: c_int, path: [*:0]const u8, timeout_ms: c_int) callconv(.c) c_int {
    if (isNullPtr(host) or isNullPtr(path)) return -1;
    if (port <= 0 or port > 65535) return -1;
    return http.headStatus(std.mem.span(host), @intCast(port), std.mem.span(path), timeout_ms);
}

pub export fn mobile_http_get_status(host: [*:0]const u8, port: c_int, path: [*:0]const u8, timeout_ms: c_int) callconv(.c) c_int {
    if (isNullPtr(host) or isNullPtr(path)) return -1;
    if (port <= 0 or port > 65535) return -1;
    return http.getStatus(std.mem.span(host), @intCast(port), std.mem.span(path), timeout_ms);
}

/// Số event đã bị bỏ vì hàng đợi đầy, -1 nếu chưa init.
pub export fn mobile_dropped_events() callconv(.c) i64 {
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = appPtr() orelse return -1;
    return @intCast(a.droppedEvents());
}

/// Encode event thành JSON {"kind":"custom","seq":0,"payload":"..."}.
/// seq luôn là 0 qua FFI. Trả 1 = có, -12 = BufferTooSmall, âm = lỗi.
pub export fn mobile_json_encode_event(event_code: c_int, payload_ptr: [*]const u8, payload_len: usize, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    if (payload_len > 0 and @intFromPtr(payload_ptr) == 0) return errors.errorCode(error.InvalidEvent);
    const kind = event.EventType.fromCode(event_code) orelse return errors.errorCode(error.InvalidEvent);
    const payload = if (payload_len == 0) "" else payload_ptr[0..payload_len];
    const text = json.encodeEvent(alloc, kind.toString(), 0, payload) catch |e| return errors.errorCode(e);
    defer alloc.free(text);
    if (text.len > out_capacity) {
        out_written.* = text.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..text.len], text);
    out_written.* = text.len;
    return 1;
}

/// JSON cây UI demo đã layout trong khung width x height.
/// Trả 1 = có, -12 = BufferTooSmall, âm = lỗi.
pub export fn mobile_ui_demo_json(width: c_int, height: c_int, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    if (width <= 0 or height <= 0) return errors.errorCode(error.InvalidPath);
    var tree = ui.demoTree(alloc) catch |e| return errors.errorCode(e);
    defer tree.deinit();
    tree.layout(@floatFromInt(width), @floatFromInt(height));
    const text = tree.toJson(alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(text);
    if (text.len > out_capacity) {
        out_written.* = text.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..text.len], text);
    out_written.* = text.len;
    return 1;
}

/// Swift báo click theo id (cây UI demo): Zig kiểm tra id có phải
/// nút bấm không rồi đẩy event "ui:click:<id>" vào hàng đợi.
pub export fn mobile_ui_click(id: [*:0]const u8) callconv(.c) c_int {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (isNullPtr(id)) return errors.errorCode(error.InvalidEvent);
    var tree = ui.demoTree(alloc) catch |e| return errors.errorCode(e);
    defer tree.deinit();
    var buf: [256]u8 = undefined;
    const payload = tree.clickPayload(std.mem.span(id), &buf) orelse return errors.errorCode(error.InvalidEvent);
    const a = appPtr() orelse return errors.errorCode(error.NotInitialized);
    a.postEvent(.custom, payload) catch |e| return errors.errorCode(e);
    return 0;
}

/// JSON danh sách lệnh vẽ của cây UI demo đã layout.
/// Trả 1 = có, -12 = BufferTooSmall, âm = lỗi.
pub export fn mobile_canvas_demo_json(width: c_int, height: c_int, out_buf: [*]u8, out_capacity: usize, out_written: *usize) callconv(.c) c_int {
    if (width <= 0 or height <= 0) return errors.errorCode(error.InvalidPath);
    var tree = ui.demoTree(alloc) catch |e| return errors.errorCode(e);
    defer tree.deinit();
    tree.layout(@floatFromInt(width), @floatFromInt(height));
    var cv = canvas.fromUiTree(alloc, &tree) catch |e| return errors.errorCode(e);
    defer cv.deinit();
    const text = canvas.toJson(alloc, &cv) catch |e| return errors.errorCode(e);
    defer alloc.free(text);
    if (text.len > out_capacity) {
        out_written.* = text.len;
        return errors.errorCode(error.BufferTooSmall);
    }
    @memcpy(out_buf[0..text.len], text);
    out_written.* = text.len;
    return 1;
}

test "ios c abi on host" {
    const t = std.testing;
    const alloc_test = t.allocator;

    // Reset trạng thái toàn cục trước (test khác có thể đã init).
    mobile_shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // tmpDir tạo thư mục .zig-cache/tmp/<random> dưới thư mục chạy test.
    const files = try std.fmt.allocPrint(alloc_test, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer alloc_test.free(files);
    const files_z = try alloc_test.dupeSentinel(u8, files, 0);
    defer alloc_test.free(files_z);
    const cache_z = try alloc_test.dupeSentinel(u8, files, 0);
    defer alloc_test.free(cache_z);

    try t.expectEqualStrings("zig-mobile 0.3.0 (zig 0.17.1)", std.mem.span(mobile_version()));
    try t.expectEqual(@as(c_int, -1), mobile_state());

    try t.expectEqual(@as(c_int, 0), mobile_init(files_z.ptr, cache_z.ptr));
    defer mobile_shutdown();
    // Init lần nữa phải báo AlreadyInitialized (-2).
    try t.expectEqual(@as(c_int, -2), mobile_init(files_z.ptr, cache_z.ptr));
    // Init xong state vẫn unknown (0), chưa created — Swift gọi mobile_lifecycle(1) mới lên created.
    try t.expectEqual(@as(c_int, 0), mobile_state());

    // Đi hết vòng đời bằng mã số, giống Swift sẽ gọi.
    try t.expectEqual(@as(c_int, 0), mobile_lifecycle(1)); // created
    try t.expectEqual(@as(c_int, 0), mobile_lifecycle(2)); // started
    try t.expectEqual(@as(c_int, 0), mobile_lifecycle(3)); // resumed
    try t.expectEqual(@as(c_int, 3), mobile_state());
    // Nhảy sai: resumed -> started không hợp lệ (-3).
    try t.expectEqual(@as(c_int, -3), mobile_lifecycle(2));

    // Post event rồi poll ra.
    const payload = "hello-ios";
    try t.expectEqual(@as(c_int, 0), mobile_on_event(1, payload.ptr, payload.len));
    var code: c_int = -99;
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    // Event đầu tiên trong hàng đợi là lifecycle "created".
    try t.expectEqual(@as(c_int, 1), mobile_poll_event(&code, &buf, buf.len, &written));
    try t.expectEqual(@as(c_int, 0), code);
    try t.expectEqualStrings("created", buf[0..written]);
    // Poll tiếp tới event custom (bỏ qua các lifecycle ở giữa).
    var found_custom = false;
    while (true) {
        const r = mobile_poll_event(&code, &buf, buf.len, &written);
        if (r == 0) break;
        try t.expectEqual(@as(c_int, 1), r);
        if (code == 1 and std.mem.eql(u8, buf[0..written], "hello-ios")) found_custom = true;
    }
    try t.expect(found_custom);

    // Buffer quá nhỏ phải báo BufferTooSmall (-12) và cho biết cần bao nhiêu.
    try t.expectEqual(@as(c_int, 0), mobile_on_event(1, payload.ptr, payload.len));
    var small: [4]u8 = undefined;
    var need: usize = 0;
    var code2: c_int = -99;
    try t.expectEqual(@as(c_int, -12), mobile_poll_event(&code2, &small, small.len, &need));
    try t.expectEqual(@as(usize, 9), need);
}

test "ios c abi v0.2 modules" {
    const t = std.testing;
    const alloc_test = t.allocator;

    // Reset trạng thái toàn cục trước (test khác có thể đã init).
    mobile_shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = try std.fmt.allocPrint(alloc_test, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer alloc_test.free(files);
    const files_z = try alloc_test.dupeSentinel(u8, files, 0);
    defer alloc_test.free(files_z);
    const cache_z = try alloc_test.dupeSentinel(u8, files, 0);
    defer alloc_test.free(cache_z);

    try t.expectEqual(@as(c_int, 0), mobile_init(files_z.ptr, cache_z.ptr));
    defer mobile_shutdown();

    // Quyền: chưa xin -> cấp camera -> kiểm tra trạng thái.
    try t.expectEqual(@as(c_int, 0), mobile_permission_state(0));
    try t.expectEqual(@as(c_int, 0), mobile_permission_mark_result(0, 1));
    try t.expectEqual(@as(c_int, 1), mobile_permission_state(0));
    try t.expectEqual(@as(c_int, -15), mobile_permission_mark_result(99, 1));
    try t.expectEqual(@as(c_int, -15), mobile_permission_mark_result(0, 99));

    // Mạng: native báo wifi -> check TCP tới listener localhost.
    // Listener mở bằng syscall thô (giống network.zig), vì std.net
    // đã bỏ ở Zig 0.17.1.
    try t.expectEqual(@as(c_int, 0), mobile_network_set_connectivity(1));
    const listener = try openTestListener();
    defer _ = std.posix.system.close(listener.fd);
    const port = listener.port;
    try t.expectEqual(@as(c_int, 1), mobile_network_reachable("127.0.0.1", @intCast(port), 1000));
    try t.expectEqual(@as(c_int, 0), mobile_network_reachable("127.0.0.1", 1, 500));
    try t.expectEqual(@as(c_int, 0), mobile_network_reachable("not-an-ip", 80, 500));

    // Thiết bị: thông tin hợp lệ thì ok, locale sai thì lỗi.
    try t.expectEqual(@as(c_int, 0), mobile_device_set_info("17.4", "1.2.3", "vi-VN", "iPhone 15"));
    try t.expectEqual(@as(c_int, -20), mobile_device_set_info("17.4", "1.2.3", "vi VN!", "iPhone 15"));

    // Cài đặt qua C ABI, rồi save/load lại từ file.
    try t.expectEqual(@as(c_int, 0), mobile_settings_set_string("theme", "dark"));
    try t.expectEqual(@as(c_int, 0), mobile_settings_set_int("font_size", 16));
    try t.expectEqual(@as(c_int, 0), mobile_settings_set_bool("sound", 1));
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    try t.expectEqual(@as(c_int, 1), mobile_settings_get_string("theme", &buf, buf.len, &written));
    try t.expectEqualStrings("dark", buf[0..written]);
    try t.expectEqual(@as(i64, 16), mobile_settings_get_int("font_size", 0));
    try t.expectEqual(@as(c_int, 1), mobile_settings_get_bool("sound", 0));
    try t.expectEqual(@as(c_int, 0), mobile_settings_get_string("khong-co", &buf, buf.len, &written));
    try t.expectEqual(@as(c_int, 0), mobile_settings_save());
    // Đổi giá trị trong RAM rồi load lại từ file, phải về giá trị cũ.
    try t.expectEqual(@as(c_int, 0), mobile_settings_set_string("theme", "light"));
    try t.expectEqual(@as(c_int, 0), mobile_settings_load());
    try t.expectEqual(@as(c_int, 1), mobile_settings_get_string("theme", &buf, buf.len, &written));
    try t.expectEqualStrings("dark", buf[0..written]);

    // File qua C ABI.
    try t.expectEqual(@as(c_int, 0), mobile_file_write_text("hello.txt", "chao ios", 0));
    try t.expectEqual(@as(c_int, 1), mobile_file_exists("hello.txt"));
    try t.expectEqual(@as(c_int, 1), mobile_file_read_text("hello.txt", &buf, buf.len, &written));
    try t.expectEqualStrings("chao ios", buf[0..written]);
    try t.expectEqual(@as(c_int, 0), mobile_file_read_text("khong-co.txt", &buf, buf.len, &written));
    try t.expectEqual(@as(c_int, 0), mobile_file_delete("hello.txt"));
    try t.expectEqual(@as(c_int, 0), mobile_file_exists("hello.txt"));

    // Task nền qua C ABI.
    try t.expectEqual(@as(c_int, 0), mobile_background_add_task("sync", 0, 1000, 0));
    try t.expectEqual(@as(c_int, 0), mobile_background_poll_due(999, &buf, buf.len, &written));
    try t.expectEqual(@as(c_int, 1), mobile_background_poll_due(1000, &buf, buf.len, &written));
    try t.expectEqualStrings("sync", buf[0..written]);
    try t.expectEqual(@as(c_int, 0), mobile_background_poll_due(99999, &buf, buf.len, &written));
    try t.expectEqual(@as(c_int, 1), mobile_background_remove_task("sync"));
    try t.expectEqual(@as(c_int, 0), mobile_background_remove_task("sync"));
}

test "ios c abi v0.3 modules" {
    const t = std.testing;
    const alloc_test = t.allocator;

    mobile_shutdown();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = try std.fmt.allocPrint(alloc_test, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer alloc_test.free(files);
    const files_z = try alloc_test.dupeSentinel(u8, files, 0);
    defer alloc_test.free(files_z);
    const cache_z = try alloc_test.dupeSentinel(u8, files, 0);
    defer alloc_test.free(cache_z);
    try t.expectEqual(@as(c_int, 0), mobile_init(files_z.ptr, cache_z.ptr));
    defer mobile_shutdown();

    // Thời gian: giờ tường dương, monotonic không âm.
    try t.expect(mobile_time_now_ms() > 1_577_836_800_000);
    try t.expect(mobile_time_monotonic_ms() >= 0);

    // Hash: "abc" phải ra đúng vector chuẩn.
    var buf: [4096]u8 = undefined;
    var written: usize = 0;
    try t.expectEqual(@as(c_int, 1), mobile_hash_sha256("abc", &buf, buf.len, &written));
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", buf[0..written]);
    // Buffer nhỏ thì báo -12 và cho biết cần bao nhiêu.
    var small: [4]u8 = undefined;
    var need: usize = 0;
    try t.expectEqual(@as(c_int, -12), mobile_hash_sha256("abc", &small, small.len, &need));
    try t.expectEqual(@as(usize, 64), need);

    // HTTP: port đóng thì -1, không treo.
    try t.expectEqual(@as(c_int, -1), mobile_http_get_status("127.0.0.1", 1, "/", 500));
    try t.expectEqual(@as(c_int, -1), mobile_http_head_status("127.0.0.1", 1, "/", 500));
    try t.expectEqual(@as(c_int, -1), mobile_http_get_status("not-an-ip", 80, "/", 500));

    // JSON encode event.
    const payload = "hello";
    try t.expectEqual(@as(c_int, 1), mobile_json_encode_event(1, payload.ptr, payload.len, &buf, buf.len, &written));
    try t.expectEqualStrings("{\"kind\":\"custom\",\"seq\":0,\"payload\":\"hello\"}", buf[0..written]);

    // UI demo JSON: phải chứa nút btn_sync; canvas JSON phải chứa rect.
    try t.expectEqual(@as(c_int, 1), mobile_ui_demo_json(360, 640, &buf, buf.len, &written));
    try t.expect(std.mem.indexOf(u8, buf[0..written], "btn_sync") != null);
    try t.expectEqual(@as(c_int, 1), mobile_canvas_demo_json(360, 640, &buf, buf.len, &written));
    try t.expect(std.mem.indexOf(u8, buf[0..written], "\"kind\":\"rect\"") != null);

    // Click nút thì ok và đẩy event ui:click vào hàng đợi.
    try t.expectEqual(@as(c_int, 0), mobile_ui_click("btn_sync"));
    // Click text (không phải nút) thì lỗi InvalidEvent (-4).
    try t.expectEqual(@as(c_int, -4), mobile_ui_click("title"));

    // Event bị bỏ: nhồi 260 event custom vào hàng đợi 256.
    var i: usize = 0;
    var failed: usize = 0;
    while (i < 260) : (i += 1) {
        const r = mobile_on_event(1, payload.ptr, payload.len);
        if (r != 0) failed += 1;
    }
    try t.expect(failed > 0);
    try t.expect(mobile_dropped_events() >= @as(i64, @intCast(failed)));
}

/// Mở socket TCP listen trên 127.0.0.1:0, chỉ dùng trong test.
fn openTestListener() !struct { fd: std.posix.socket_t, port: u16 } {
    const posix = std.posix;
    const flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(posix.AF.INET, flags, 0);
    if (posix.errno(rc) != .SUCCESS) return error.Unexpected;
    const fd: posix.socket_t = @intCast(rc);
    errdefer _ = posix.system.close(fd);
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (posix.errno(posix.system.bind(fd, @ptrCast(&addr), addr_len)) != .SUCCESS) {
        return error.Unexpected;
    }
    if (posix.errno(posix.system.listen(fd, 1)) != .SUCCESS) {
        return error.Unexpected;
    }
    var bound: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (posix.errno(posix.system.getsockname(fd, @ptrCast(&bound), &bound_len)) != .SUCCESS) {
        return error.Unexpected;
    }
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, bound.port) };
}
