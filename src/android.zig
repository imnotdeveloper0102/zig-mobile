// android.zig — Entry point JNI cho Android.
//
// Kotlin gọi qua `external fun` trong object MobileBridge (package
// com.zigmobile.app, xem examples/android/MainActivity.kt). Tên hàm
// Java_* gắn chặt với package + tên class đó: app khác package thì
// đổi tên hàm ở đây (hoặc copy file này rồi sửa prefix), vì JNI tìm
// hàm theo tên.
//
// Hai loại hàm:
//   - Chỉ nhận số nguyên / không tham số (lifecycle, mã event, poll
//     code, getState): KHÔNG đụng tới bảng hàm JNI, đường an toàn.
//   - Nhận/trả jstring (mobileInit, postEventWithPayload, poll payload,
//     version): dùng bảng hàm JNI trong jni.zig (xem cảnh báo ở đó —
//     chưa kiểm chứng trên máy thật).
//
// App Zig là global duy nhất, chỉ gọi từ main thread (giống Activity).
// Kotlin poll event thay vì Zig gọi ngược, vì gọi ngược cần method ID
// và AttachCurrentThread — v0.2.0 vẫn chưa làm phần đó.
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
const jni = @import("jni.zig");
const json = @import("json.zig");
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
/// Payload của event vừa poll ra bằng mobilePollEventCode, để
/// mobilePollEventPayload lấy sau. Sở hữu bởi page_allocator.
var g_last_payload: ?[]u8 = null;
/// Trạng thái xin quyền + mạng, không cần allocator.
var g_permissions: permissions.PermissionStore = .{};
var g_network: network.NetworkStatus = .{};
/// Cài đặt + task nền + thông tin thiết bị (v0.2.0), tạo lúc init.
var g_settings: ?settings.Settings = null;
var g_tasks: ?background.TaskQueue = null;
var g_device: ?device.DeviceInfo = null;
/// Chuỗi trả về cho các hàm JNI trả jstring (settings/file/task).
var g_last_string: ?[]u8 = null;

fn appPtr() ?*App {
    if (g_app) |*a| return a;
    return null;
}

fn ensureAppLocked(env: *jni.JNIEnv, files_dir: ?jni.jstring, cache_dir: ?jni.jstring) MobileError!void {
    if (g_app != null) return;
    const files = try jni.getStringUtf8(env, files_dir, alloc);
    defer alloc.free(files);
    const cache = try jni.getStringUtf8(env, cache_dir, alloc);
    defer alloc.free(cache);
    g_app = try App.init(alloc, .{
        .platform = .android,
        .files_dir = files,
        .cache_dir = cache,
    });
    ensureExtrasLocked();
}

/// Tạo Settings/TaskQueue nếu chưa có. Gọi khi đã giữ g_mutex.
fn ensureExtrasLocked() void {
    if (g_settings == null) g_settings = settings.Settings.init(alloc);
    if (g_tasks == null) g_tasks = background.TaskQueue.init(alloc);
}

/// Dọn Settings/TaskQueue/DeviceInfo. Gọi khi đã giữ g_mutex.
fn deinitExtrasLocked() void {
    if (g_settings) |*s| s.deinit();
    g_settings = null;
    if (g_tasks) |*q| q.deinit();
    g_tasks = null;
    if (g_device) |*d| d.deinit();
    g_device = null;
    if (g_last_string) |s| alloc.free(s);
    g_last_string = null;
}

fn setLastString(text: []const u8) void {
    if (g_last_string) |s| alloc.free(s);
    g_last_string = alloc.dupe(u8, text) catch null;
}

fn settingsPtr() ?*settings.Settings {
    ensureExtrasLocked();
    if (g_settings) |*s| return s;
    return null;
}

fn tasksPtr() ?*background.TaskQueue {
    ensureExtrasLocked();
    if (g_tasks) |*q| return q;
    return null;
}

fn storagePtr() ?*const @import("storage.zig").Storage {
    const a = appPtr() orelse return null;
    return &a.storage;
}

fn transitionLocked(to: State) void {
    if (appPtr()) |a| {
        a.transition(to) catch {};
    }
}

fn postEventLocked(code: jni.jint, payload: []const u8) MobileError!void {
    const a = appPtr() orelse return error.NotInitialized;
    const kind = event.EventType.fromCode(code) orelse return error.InvalidEvent;
    try a.postEvent(kind, payload);
}

/// 0 = ok, số âm = mã lỗi (xem errors.errorCode).
pub export fn Java_com_zigmobile_app_MobileBridge_mobileInit(env: *jni.JNIEnv, thiz: jni.jobject, files_dir: ?jni.jstring, cache_dir: ?jni.jstring) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_app != null) return errors.errorCode(error.AlreadyInitialized);
    ensureAppLocked(env, files_dir, cache_dir) catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileOnCreate(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) void {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    transitionLocked(.created);
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileOnStart(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) void {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    transitionLocked(.started);
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileOnResume(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) void {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    transitionLocked(.resumed);
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileOnPause(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) void {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    transitionLocked(.paused);
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileOnStop(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) void {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    transitionLocked(.stopped);
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileOnDestroy(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) void {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    if (appPtr()) |a| {
        a.transition(.destroyed) catch {};
        a.deinit();
    }
    g_app = null;
    deinitExtrasLocked();
    if (g_last_payload) |p| {
        alloc.free(p);
        g_last_payload = null;
    }
}

/// Post event chỉ bằng mã số (không payload). Đường an toàn, không JNI string.
pub export fn Java_com_zigmobile_app_MobileBridge_mobilePostEvent(env: *jni.JNIEnv, thiz: jni.jobject, event_code: jni.jint) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    postEventLocked(event_code, "") catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

/// Post event kèm payload string. Dùng bảng hàm JNI để đọc jstring.
pub export fn Java_com_zigmobile_app_MobileBridge_mobilePostEventWithPayload(env: *jni.JNIEnv, thiz: jni.jobject, event_code: jni.jint, payload: ?jni.jstring) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const text = jni.getStringUtf8(env, payload, alloc) catch |e| {
        return errors.errorCode(e);
    };
    defer alloc.free(text);
    postEventLocked(event_code, text) catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

/// Poll event cũ nhất: trả mã event, -1 nếu trống hoặc chưa init.
/// Payload của event đó giữ lại để mobilePollEventPayload lấy sau.
pub export fn Java_com_zigmobile_app_MobileBridge_mobilePollEventCode(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = appPtr() orelse return -1;
    var ev = a.pollEvent() orelse return -1;
    defer ev.deinit(a.alloc);
    if (g_last_payload) |p| alloc.free(p);
    g_last_payload = alloc.dupe(u8, ev.payload) catch return -1;
    return ev.kind.code();
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobilePollEventPayload(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const payload = g_last_payload orelse return null;
    return jni.newStringUtf8(env, payload, alloc) catch null;
}

/// Mã trạng thái hiện tại (0 unknown, 1 created, 2 started, 3 resumed,
// 4 paused, 5 stopped, 6 destroyed), -1 nếu chưa init.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileGetState(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = appPtr() orelse return -1;
    return a.state.code();
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileVersion(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    return jni.newStringUtf8(env, version.version_string, alloc) catch null;
}

// ---- v0.2.0: quyền, mạng, cài đặt, file, thiết bị, task nền ----
//
// Quy ước chung: hàm nào chỉ nhận số nguyên thì không đụng tới bảng
// hàm JNI (đường an toàn); hàm nào nhận/trả jstring thì dùng helper
// trong jni.zig (xem cảnh báo chưa kiểm chứng máy thật ở đó).

/// Mã trạng thái quyền (0 not_requested, 1 granted, 2 denied,
// 3 permanently_denied), -1 nếu mã quyền sai hoặc chưa init.
pub export fn Java_com_zigmobile_app_MobileBridge_mobilePermissionState(env: *jni.JNIEnv, thiz: jni.jobject, perm_code: jni.jint) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const perm = permissions.Permission.fromCode(perm_code) orelse return -1;
    return g_permissions.state(perm).code();
}

/// Báo kết quả xin quyền về Zig. Đẩy event permission_result với
/// payload "camera:granted". Trả 0 = ok, số âm = mã lỗi.
pub export fn Java_com_zigmobile_app_MobileBridge_mobilePermissionMarkResult(env: *jni.JNIEnv, thiz: jni.jobject, perm_code: jni.jint, state_code: jni.jint) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
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
pub export fn Java_com_zigmobile_app_MobileBridge_mobileNetworkSetConnectivity(env: *jni.JNIEnv, thiz: jni.jobject, code: jni.jint) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
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
// 0 = không tới được, -1 = tham số sai (host null / sai IP / timeout
// ngoài 1..30000). Dùng bảng hàm JNI để đọc host.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileNetworkReachable(env: *jni.JNIEnv, thiz: jni.jobject, host: ?jni.jstring, port: jni.jint, timeout_ms: jni.jint) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const text = jni.getStringUtf8(env, host, alloc) catch return -1;
    defer alloc.free(text);
    if (port <= 0 or port > 65535) return -1;
    return if (network.checkTcp(text, @intCast(port), timeout_ms)) 1 else 0;
}

/// Đặt thông tin thiết bị (os_version, app_version, locale, model).
/// arch lấy từ target biên dịch, platform là android.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileDeviceSetInfo(env: *jni.JNIEnv, thiz: jni.jobject, os_version: ?jni.jstring, app_version: ?jni.jstring, locale: ?jni.jstring, model: ?jni.jstring) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const os = jni.getStringUtf8(env, os_version, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(os);
    const app_v = jni.getStringUtf8(env, app_version, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(app_v);
    const loc = jni.getStringUtf8(env, locale, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(loc);
    const mdl = jni.getStringUtf8(env, model, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(mdl);
    const info = device.DeviceInfo.init(alloc, .android, platform.archName(), os, app_v, loc, mdl) catch |e| {
        return errors.errorCode(e);
    };
    if (g_device) |*d| d.deinit();
    g_device = info;
    return 0;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileSettingsSetString(env: *jni.JNIEnv, thiz: jni.jobject, key: ?jni.jstring, value: ?jni.jstring) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const k = jni.getStringUtf8(env, key, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(k);
    const v = jni.getStringUtf8(env, value, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(v);
    const s = settingsPtr() orelse return errors.errorCode(error.NotInitialized);
    s.setString(k, v) catch |e| return errors.errorCode(e);
    return 0;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileSettingsSetInt(env: *jni.JNIEnv, thiz: jni.jobject, key: ?jni.jstring, value: jni.jlong) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const k = jni.getStringUtf8(env, key, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(k);
    const s = settingsPtr() orelse return errors.errorCode(error.NotInitialized);
    s.setInt(k, value) catch |e| return errors.errorCode(e);
    return 0;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileSettingsSetBool(env: *jni.JNIEnv, thiz: jni.jobject, key: ?jni.jstring, value: jni.jboolean) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const k = jni.getStringUtf8(env, key, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(k);
    const s = settingsPtr() orelse return errors.errorCode(error.NotInitialized);
    s.setBool(k, value != 0) catch |e| return errors.errorCode(e);
    return 0;
}

/// Lấy chuỗi cài đặt, trả null nếu key không có hoặc không phải chuỗi.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileSettingsGetString(env: *jni.JNIEnv, thiz: jni.jobject, key: ?jni.jstring) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const k = jni.getStringUtf8(env, key, alloc) catch return null;
    defer alloc.free(k);
    const s = settingsPtr() orelse return null;
    const v = s.getString(k) orelse return null;
    setLastString(v);
    const text = g_last_string orelse return null;
    return jni.newStringUtf8(env, text, alloc) catch null;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileSettingsGetInt(env: *jni.JNIEnv, thiz: jni.jobject, key: ?jni.jstring, default_value: jni.jlong) callconv(.c) jni.jlong {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const k = jni.getStringUtf8(env, key, alloc) catch return default_value;
    defer alloc.free(k);
    const s = settingsPtr() orelse return default_value;
    return s.getInt(k) orelse default_value;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileSettingsGetBool(env: *jni.JNIEnv, thiz: jni.jobject, key: ?jni.jstring, default_value: jni.jboolean) callconv(.c) jni.jboolean {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const k = jni.getStringUtf8(env, key, alloc) catch return default_value;
    defer alloc.free(k);
    const s = settingsPtr() orelse return default_value;
    const v = s.getBool(k) orelse return default_value;
    return if (v) 1 else 0;
}

/// Lưu cài đặt xuống files_dir/settings.txt.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileSettingsSave(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    const s = settingsPtr() orelse return errors.errorCode(error.NotInitialized);
    s.save(store, "settings.txt") catch |e| return errors.errorCode(e);
    return 0;
}

/// Tải cài đặt từ files_dir/settings.txt (chưa có file thì không lỗi).
pub export fn Java_com_zigmobile_app_MobileBridge_mobileSettingsLoad(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    const s = settingsPtr() orelse return errors.errorCode(error.NotInitialized);
    s.load(store, "settings.txt") catch |e| return errors.errorCode(e);
    return 0;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileFileWriteText(env: *jni.JNIEnv, thiz: jni.jobject, relative: ?jni.jstring, text: ?jni.jstring, append: jni.jboolean) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const rel = jni.getStringUtf8(env, relative, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(rel);
    const data = jni.getStringUtf8(env, text, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(data);
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    files_mod.writeText(store, alloc, rel, data, append != 0, false) catch |e| return errors.errorCode(e);
    return 0;
}

/// Đọc file text trong files_dir, trả null nếu file không có.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileFileReadText(env: *jni.JNIEnv, thiz: jni.jobject, relative: ?jni.jstring) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const rel = jni.getStringUtf8(env, relative, alloc) catch return null;
    defer alloc.free(rel);
    const store = storagePtr() orelse return null;
    const data = files_mod.readText(store, alloc, rel, files_mod.default_max_read_bytes, false) catch return null;
    setLastString(data);
    alloc.free(data);
    const text = g_last_string orelse return null;
    return jni.newStringUtf8(env, text, alloc) catch null;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileFileDelete(env: *jni.JNIEnv, thiz: jni.jobject, relative: ?jni.jstring) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const rel = jni.getStringUtf8(env, relative, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(rel);
    const store = storagePtr() orelse return errors.errorCode(error.NotInitialized);
    files_mod.deleteFile(store, alloc, rel, false) catch |e| return errors.errorCode(e);
    return 0;
}

/// Trả 1 = file có, 0 = không có, -1 = lỗi khác.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileFileExists(env: *jni.JNIEnv, thiz: jni.jobject, relative: ?jni.jstring) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const rel = jni.getStringUtf8(env, relative, alloc) catch return -1;
    defer alloc.free(rel);
    const store = storagePtr() orelse return -1;
    const ok = files_mod.exists(store, alloc, rel, false) catch return -1;
    return if (ok) 1 else 0;
}

/// Thêm task nền. max_runs <= 0 nghĩa là lặp vô hạn (chỉ task
/// repeating). Trả 0 = ok, số âm = mã lỗi.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileBackgroundAddTask(env: *jni.JNIEnv, thiz: jni.jobject, id: ?jni.jstring, kind: jni.jint, interval_ms: jni.jlong, max_runs: jni.jint) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const task_id = jni.getStringUtf8(env, id, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(task_id);
    const k = background.TaskKind.fromCode(kind) orelse return errors.errorCode(error.InvalidTask);
    const q = tasksPtr() orelse return errors.errorCode(error.NotInitialized);
    q.add(task_id, k, @intCast(interval_ms), if (max_runs <= 0) null else @intCast(max_runs), 0) catch |e| {
        return errors.errorCode(e);
    };
    return 0;
}

/// Lấy id task tới hạn (now_ms tính bằng mili-giây), trả null nếu
/// chưa tới lượt task nào. now_ms nên lấy từ SystemClock.elapsedRealtime().
pub export fn Java_com_zigmobile_app_MobileBridge_mobileBackgroundPollDue(env: *jni.JNIEnv, thiz: jni.jobject, now_ms: jni.jlong) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const q = tasksPtr() orelse return null;
    const id = q.pollDue(@intCast(now_ms)) orelse return null;
    setLastString(id);
    const text = g_last_string orelse return null;
    return jni.newStringUtf8(env, text, alloc) catch null;
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileBackgroundRemoveTask(env: *jni.JNIEnv, thiz: jni.jobject, id: ?jni.jstring) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const task_id = jni.getStringUtf8(env, id, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(task_id);
    const q = tasksPtr() orelse return errors.errorCode(error.NotInitialized);
    return if (q.remove(task_id)) 0 else errors.errorCode(error.TaskNotFound);
}

// ---- v0.3.0: thời gian, hash, HTTP, JSON, UI/canvas, event bị bỏ ----
//
// mobileUiDemoJson / mobileCanvasDemoJson trả JSON của cây UI demo
// (xem ui.demoTree): native dùng để thử render, chưa phải cây UI
// thật của app — app thật tự build cây bằng UiTree rồi render.

pub export fn Java_com_zigmobile_app_MobileBridge_mobileTimeNowMs(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) jni.jlong {
    _ = env;
    _ = thiz;
    return time.nowMs();
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileTimeMonotonicMs(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) jni.jlong {
    _ = env;
    _ = thiz;
    return time.monotonicMs();
}

/// SHA-256 hex (64 ký tự) của chuỗi, trả null nếu chuỗi có NUL.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileHashSha256(env: *jni.JNIEnv, thiz: jni.jobject, text: ?jni.jstring) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const data = jni.getStringUtf8(env, text, alloc) catch return null;
    defer alloc.free(data);
    const hex = hash.sha256Alloc(alloc, data) catch return null;
    defer alloc.free(hex);
    setLastString(hex);
    const out = g_last_string orelse return null;
    return jni.newStringUtf8(env, out, alloc) catch null;
}

/// SHA-256 hex của file trong files_dir, trả null nếu file không có.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileHashFileSha256(env: *jni.JNIEnv, thiz: jni.jobject, relative: ?jni.jstring) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const rel = jni.getStringUtf8(env, relative, alloc) catch return null;
    defer alloc.free(rel);
    const store = storagePtr() orelse return null;
    const hex = hash.sha256File(store, alloc, rel, files_mod.default_max_read_bytes, false) catch return null;
    defer alloc.free(hex);
    setLastString(hex);
    const out = g_last_string orelse return null;
    return jni.newStringUtf8(env, out, alloc) catch null;
}

/// Status code HTTP (200, 404, ...), -1 nếu nối không được / hết giờ.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileHttpHeadStatus(env: *jni.JNIEnv, thiz: jni.jobject, host: ?jni.jstring, port: jni.jint, path: ?jni.jstring, timeout_ms: jni.jint) callconv(.c) jni.jint {
    _ = thiz;
    const h = jni.getStringUtf8(env, host, alloc) catch return -1;
    defer alloc.free(h);
    const p = jni.getStringUtf8(env, path, alloc) catch return -1;
    defer alloc.free(p);
    if (port <= 0 or port > 65535) return -1;
    return http.headStatus(h, @intCast(port), p, timeout_ms);
}

pub export fn Java_com_zigmobile_app_MobileBridge_mobileHttpGetStatus(env: *jni.JNIEnv, thiz: jni.jobject, host: ?jni.jstring, port: jni.jint, path: ?jni.jstring, timeout_ms: jni.jint) callconv(.c) jni.jint {
    _ = thiz;
    const h = jni.getStringUtf8(env, host, alloc) catch return -1;
    defer alloc.free(h);
    const p = jni.getStringUtf8(env, path, alloc) catch return -1;
    defer alloc.free(p);
    if (port <= 0 or port > 65535) return -1;
    return http.getStatus(h, @intCast(port), p, timeout_ms);
}

/// Encode event thành JSON {"kind":"custom","seq":0,"payload":"..."}.
/// seq luôn là 0 qua FFI (native tự điền nếu cần).
pub export fn Java_com_zigmobile_app_MobileBridge_mobileJsonEncodeEvent(env: *jni.JNIEnv, thiz: jni.jobject, event_code: jni.jint, payload: ?jni.jstring) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const kind = event.EventType.fromCode(event_code) orelse return null;
    const text = jni.getStringUtf8(env, payload, alloc) catch return null;
    defer alloc.free(text);
    const text_json = json.encodeEvent(alloc, kind.toString(), 0, text) catch return null;
    defer alloc.free(text_json);
    setLastString(text_json);
    const out = g_last_string orelse return null;
    return jni.newStringUtf8(env, out, alloc) catch null;
}

/// JSON cây UI demo đã layout trong khung width x height.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileUiDemoJson(env: *jni.JNIEnv, thiz: jni.jobject, width: jni.jint, height: jni.jint) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    if (width <= 0 or height <= 0) return null;
    var tree = ui.demoTree(alloc) catch return null;
    defer tree.deinit();
    tree.layout(@floatFromInt(width), @floatFromInt(height));
    const text = tree.toJson(alloc) catch return null;
    defer alloc.free(text);
    setLastString(text);
    const out = g_last_string orelse return null;
    return jni.newStringUtf8(env, out, alloc) catch null;
}

/// Native báo click theo id (cây UI demo): Zig kiểm tra id có phải
/// nút bấm không rồi đẩy event "ui:click:<id>" vào hàng đợi.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileUiClick(env: *jni.JNIEnv, thiz: jni.jobject, id: ?jni.jstring) callconv(.c) jni.jint {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const node_id = jni.getStringUtf8(env, id, alloc) catch |e| return errors.errorCode(e);
    defer alloc.free(node_id);
    var tree = ui.demoTree(alloc) catch |e| return errors.errorCode(e);
    defer tree.deinit();
    var buf: [256]u8 = undefined;
    const payload = tree.clickPayload(node_id, &buf) orelse return errors.errorCode(error.InvalidEvent);
    const a = appPtr() orelse return errors.errorCode(error.NotInitialized);
    a.postEvent(.custom, payload) catch |e| return errors.errorCode(e);
    return 0;
}

/// JSON danh sách lệnh vẽ của cây UI demo đã layout.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileCanvasDemoJson(env: *jni.JNIEnv, thiz: jni.jobject, width: jni.jint, height: jni.jint) callconv(.c) ?jni.jstring {
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    if (width <= 0 or height <= 0) return null;
    var tree = ui.demoTree(alloc) catch return null;
    defer tree.deinit();
    tree.layout(@floatFromInt(width), @floatFromInt(height));
    var cv = canvas.fromUiTree(alloc, &tree) catch return null;
    defer cv.deinit();
    const text = canvas.toJson(alloc, &cv) catch return null;
    defer alloc.free(text);
    setLastString(text);
    const out = g_last_string orelse return null;
    return jni.newStringUtf8(env, out, alloc) catch null;
}

/// Số event đã bị bỏ vì hàng đợi đầy, -1 nếu chưa init.
pub export fn Java_com_zigmobile_app_MobileBridge_mobileDroppedEvents(env: *jni.JNIEnv, thiz: jni.jobject) callconv(.c) jni.jint {
    _ = env;
    _ = thiz;
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = appPtr() orelse return -1;
    const n = a.droppedEvents();
    if (n > std.math.maxInt(jni.jint)) return std.math.maxInt(jni.jint);
    return @intCast(n);
}

test "android event code mapping" {
    const t = std.testing;
    // Phần JNI cần JVM thật nên không test ở đây; chỉ test phần đổi mã
    // mà các hàm Java_* dùng chung.
    try t.expectEqual(event.EventType.lifecycle, event.EventType.fromCode(0).?);
    try t.expectEqual(@as(?event.EventType, null), event.EventType.fromCode(99));
    try t.expectEqual(@as(c_int, 3), State.resumed.code());
    try t.expectEqual(State.paused, State.fromCode(4).?);
}
