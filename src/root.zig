// zig-mobile — Thư viện Zig làm app mobile (Android + iOS).
//
// Zig làm ruột, Kotlin/Swift làm vỏ: vòng đời app, hàng đợi sự kiện,
// log, đường dẫn lưu trữ viết bằng Zig một lần, rồi nhúng vào app
// Android qua JNI (.so) và app iOS qua C ABI (.a). Không có UI trong
// này — UI vẫn viết bằng Jetpack Compose / SwiftUI như bình thường.
//
// Các module:
//   version  — tên + phiên bản thư viện
//   errors   — error set dùng chung + mã lỗi FFI
//   platform — app đang chạy trên android/ios/host
//   log      — log level, ghi stderr/file, callback về native
//   event    — sự kiện + hàng đợi FIFO
//   storage  — files_dir/cache_dir, ghép đường dẫn an toàn
//   app      — App: state machine vòng đời + event + log + storage
//   permissions — trạng thái xin quyền (camera/mic/vị trí/...)
//   network  — trạng thái mạng + kiểm tra TCP tới được host không
//   device   — thông tin thiết bị/app do native đưa sang
//   settings — cài đặt key-value, lưu file
//   files    — đọc/ghi/xóa/liệt kê file trong files_dir/cache_dir
//   background — mô tả task nền, native trigger theo lịch
//   time       — mốc mili-giây, đo khoảng cách, format thời gian
//   hash       — SHA-256 cho chuỗi và file
//   http       — kiểm tra HTTP đơn giản bằng TCP IPv4 (không TLS)
//   json       — helper JSON mỏng trên std.json (event, cài đặt)
//   ui         — cây UI khai báo + layout flex + sự kiện bấm
//   canvas     — danh sách lệnh vẽ từ UI tree, render PPM trên host
//   jni      — helper JNI cho Android (chuỗi, callback)
//   android  — export Java_* cho Kotlin (package com.zigmobile.app)
//   ios      — export mobile_* C ABI cho Swift
//   spinlock — khóa spin atomic cho global App
//
// Ví dụ nhanh (host):
//   var app = try mobile.App.init(alloc, .{});
//   defer app.deinit();
//   try app.onCreate();
//   try app.onStart();
//   try app.onResume();
//   try app.postEvent(.custom, "hello");
const std = @import("std");

pub const version = "0.3.0";
pub const zig_version = "0.17.1";

pub const version_mod = @import("version.zig");
pub const errors = @import("errors.zig");
pub const platform = @import("platform.zig");
pub const log = @import("log.zig");
pub const event = @import("event.zig");
pub const storage = @import("storage.zig");
pub const app = @import("app.zig");
pub const permissions = @import("permissions.zig");
pub const network = @import("network.zig");
pub const device = @import("device.zig");
pub const settings = @import("settings.zig");
pub const files = @import("files.zig");
pub const background = @import("background.zig");
pub const time = @import("time.zig");
pub const hash = @import("hash.zig");
pub const http = @import("http.zig");
pub const json = @import("json.zig");
pub const ui = @import("ui.zig");
pub const canvas = @import("canvas.zig");
pub const jni = @import("jni.zig");
pub const android = @import("android.zig");
pub const ios = @import("ios.zig");
pub const spinlock = @import("spinlock.zig");

// Re-export những kiểu dùng nhiều nhất.
pub const App = app.App;
pub const AppOptions = app.AppOptions;
pub const State = app.State;
pub const Platform = platform.Platform;
pub const EventType = event.EventType;
pub const Event = event.Event;
pub const EventQueue = event.EventQueue;
pub const Logger = log.Logger;
pub const LogLevel = log.Level;
pub const Storage = storage.Storage;
pub const MobileError = errors.MobileError;
pub const Permission = permissions.Permission;
pub const PermissionState = permissions.PermissionState;
pub const PermissionStore = permissions.PermissionStore;
pub const Connectivity = network.Connectivity;
pub const NetworkStatus = network.NetworkStatus;
pub const DeviceInfo = device.DeviceInfo;
pub const Settings = settings.Settings;
pub const SettingValue = settings.Value;
pub const TaskQueue = background.TaskQueue;
pub const TaskKind = background.TaskKind;
pub const Stopwatch = time.Stopwatch;
pub const UiTree = ui.UiTree;
pub const NodeKind = ui.NodeKind;
pub const Color = ui.Color;
pub const Frame = ui.Frame;
pub const Canvas = canvas.Canvas;
pub const HttpMethod = http.Method;
pub const HttpResponse = http.Response;

// Giữ các hàm export cho linker: Zig chỉ biên dịch những decl được tham
// chiếu, mà không có code Zig nào gọi hàm Java_*/mobile_* (chỉ Kotlin
// và Swift gọi từ ngoài). Không giữ ở đây thì .so/.a build ra sẽ không
// có symbol nào cho native gọi — đã gặp đúng lỗi này khi kiểm chứng.
comptime {
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileInit;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileOnCreate;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileOnStart;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileOnResume;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileOnPause;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileOnStop;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileOnDestroy;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobilePostEvent;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobilePostEventWithPayload;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobilePollEventCode;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobilePollEventPayload;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileGetState;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileVersion;
    _ = ios.mobile_init;
    _ = ios.mobile_shutdown;
    _ = ios.mobile_lifecycle;
    _ = ios.mobile_state;
    _ = ios.mobile_on_event;
    _ = ios.mobile_poll_event;
    _ = ios.mobile_version;
    _ = ios.mobile_set_log_callback;
    _ = ios.mobile_set_event_callback;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobilePermissionState;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobilePermissionMarkResult;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileNetworkSetConnectivity;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileNetworkReachable;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileSettingsSetString;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileSettingsSetInt;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileSettingsSetBool;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileSettingsGetString;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileSettingsGetInt;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileSettingsGetBool;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileSettingsSave;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileSettingsLoad;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileFileWriteText;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileFileReadText;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileFileDelete;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileFileExists;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileDeviceSetInfo;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileBackgroundAddTask;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileBackgroundPollDue;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileBackgroundRemoveTask;
    _ = ios.mobile_permission_state;
    _ = ios.mobile_permission_mark_result;
    _ = ios.mobile_network_set_connectivity;
    _ = ios.mobile_network_reachable;
    _ = ios.mobile_device_set_info;
    _ = ios.mobile_settings_set_string;
    _ = ios.mobile_settings_set_int;
    _ = ios.mobile_settings_set_bool;
    _ = ios.mobile_settings_get_string;
    _ = ios.mobile_settings_get_int;
    _ = ios.mobile_settings_get_bool;
    _ = ios.mobile_settings_save;
    _ = ios.mobile_settings_load;
    _ = ios.mobile_file_write_text;
    _ = ios.mobile_file_read_text;
    _ = ios.mobile_file_delete;
    _ = ios.mobile_file_exists;
    _ = ios.mobile_background_add_task;
    _ = ios.mobile_background_poll_due;
    _ = ios.mobile_background_remove_task;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileTimeNowMs;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileTimeMonotonicMs;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileHashSha256;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileHashFileSha256;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileHttpHeadStatus;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileHttpGetStatus;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileJsonEncodeEvent;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileUiDemoJson;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileUiClick;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileCanvasDemoJson;
    _ = android.Java_com_zigmobile_app_MobileBridge_mobileDroppedEvents;
    _ = ios.mobile_time_now_ms;
    _ = ios.mobile_time_monotonic_ms;
    _ = ios.mobile_hash_sha256;
    _ = ios.mobile_hash_file_sha256;
    _ = ios.mobile_http_head_status;
    _ = ios.mobile_http_get_status;
    _ = ios.mobile_dropped_events;
    _ = ios.mobile_json_encode_event;
    _ = ios.mobile_ui_demo_json;
    _ = ios.mobile_ui_click;
    _ = ios.mobile_canvas_demo_json;
}

test {
    // Chạy toàn bộ test trong các module con.
    std.testing.refAllDecls(@This());
    _ = @import("version.zig");
    _ = @import("errors.zig");
    _ = @import("platform.zig");
    _ = @import("log.zig");
    _ = @import("event.zig");
    _ = @import("storage.zig");
    _ = @import("app.zig");
    _ = @import("permissions.zig");
    _ = @import("network.zig");
    _ = @import("device.zig");
    _ = @import("settings.zig");
    _ = @import("files.zig");
    _ = @import("background.zig");
    _ = @import("time.zig");
    _ = @import("hash.zig");
    _ = @import("http.zig");
    _ = @import("json.zig");
    _ = @import("ui.zig");
    _ = @import("canvas.zig");
    _ = @import("jni.zig");
    _ = @import("android.zig");
    _ = @import("ios.zig");
    _ = @import("spinlock.zig");
}
