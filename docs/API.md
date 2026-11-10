# API — zig-mobile 0.3.0

Tài liệu API đầy đủ cho Zig 0.17.1. Module chính là `mobile`
(`src/root.zig`), re-export các module con. API cũ từ v0.1.0/v0.2.0
giữ nguyên, không phá vỡ.

> **Zig làm ruột, Kotlin/Swift làm vỏ.** Zig không vẽ UI trực tiếp,
> không build APK/Xcode. Các hàm FFI (`Java_*` / `mobile_*`) là cầu
> nối để native lấy dữ liệu / báo sự kiện về Zig.

## Mục lục

- [version / platform / errors](#version--platform--errors)
- [log](#log)
- [event](#event)
- [storage](#storage)
- [app](#app)
- [permissions](#permissions)
- [network](#network)
- [device](#device)
- [settings](#settings)
- [files](#files)
- [background](#background)
- [time](#time)
- [hash](#hash)
- [http](#http)
- [json](#json)
- [ui](#ui)
- [canvas](#canvas)
- [spinlock](#spinlock)
- [FFI Android (JNI)](#ffi-android-jni)
- [FFI iOS (C ABI)](#ffi-ios-c-abi)
- [Mã lỗi](#mã-lỗi)

## version / platform / errors

| Hàm / hằng | Ý nghĩa |
| --- | --- |
| `version.name` | `"zig-mobile"` |
| `version.version` | `"0.3.0"` |
| `version.zig_version` | `"0.17.1"` |
| `version.version_string` | `"zig-mobile 0.3.0 (zig 0.17.1)"` |
| `platform.current()` | `.host` / `.android` / `.ios` (lúc biên dịch) |
| `platform.archName()` | `"x86_64"` / `"aarch64"` / ... |
| `errors.errorCode(err)` | Mã FFI: 0 = ok, số âm = lỗi (xem [Mã lỗi](#mã-lỗi)) |
| `errors.describe(err)` | Mô tả lỗi bằng tiếng Việt |

## log

`log.Level`: `debug`, `info`, `warn`, `error` (mã 0..3).
`log.Logger`: ghi ra stderr, file, hoặc callback (iOS đăng ký được
`mobile_set_log_callback`; Android dùng stderr hoặc poll).

| Hàm | Ý nghĩa |
| --- | --- |
| `Logger.init(alloc)` | Logger mặc định (stderr, level info) |
| `setLevel(level)` | Đổi level |
| `debug/info/warn/error(tag, msg)` | Ghi 1 dòng `[LEVEL] [tag] msg` |
| `setFile(path)` | Ghi thêm vào file (trên Android là no-op, xem README) |
| `setCallback(cb)` | Gọi ngược sang native (iOS) |

## event

`EventType`: `lifecycle` (0), `custom` (1), `network_changed` (2),
`low_memory` (3), `back_pressed` (4), `permission_result` (5),
`deep_link` (6). `Event` có `seq`, `kind`, `payload` (chuỗi, tối đa
1024 ký tự, `deinit` để giải phóng).

`EventQueue`: FIFO ring buffer, tối đa **256** event, khóa spin.

| Hàm | Ý nghĩa |
| --- | --- |
| `EventQueue.init(alloc)` | Hàng đợi rỗng |
| `push(kind, payload)` | Đẩy event; đầy thì `error.QueueFull` **và tăng bộ đếm dropped** |
| `pop()` | Lấy event cũ nhất, `null` nếu trống |
| `peek()` | Xem event đầu mà không lấy ra |
| `count()` / `isEmpty()` / `isFull()` | Chỉ đọc, không khóa |
| `droppedCount()` | Số event đã bị bỏ vì hàng đợi đầy (v0.3.0, đọc có khóa) |

## storage

`Storage`: giữ `files_dir` + `cache_dir` do native đưa sang lúc init.
Chặn đường dẫn chứa `..` và đường dẫn tuyệt đối.

| Hàm | Ý nghĩa |
| --- | --- |
| `Storage.init(alloc, files_dir, cache_dir)` | Kiểm tra đường dẫn hợp lệ |
| `filesPath(alloc, relative)` | Nối `files_dir/relative` (đã kiểm tra) |
| `cachePath(alloc, relative)` | Nối `cache_dir/relative` |
| `validateRelative(relative)` | `true` nếu đường dẫn tương đối an toàn |

## app

`App`: state machine vòng đời + event + log + storage. Trạng thái:
`unknown` (0), `created` (1), `started` (2), `resumed` (3),
`paused` (4), `stopped` (5), `destroyed` (6).

```
unknown -> created -> started -> resumed -> paused -> resumed ...
                                     paused -> stopped -> started ...
                                     stopped -> destroyed
                                     created -> destroyed
```

| Hàm | Ý nghĩa |
| --- | --- |
| `App.init(alloc, .{ .files_dir, .cache_dir })` | Tạo app (files/cache mặc định là thư mục hiện tại trên host) |
| `onCreate/onStart/onResume/onPause/onStop/onDestroy()` | Chuyển trạng thái; sai thì `error.InvalidTransition`, giữ nguyên trạng thái cũ |
| `state` / `isRunning()` / `isForeground()` | Trạng thái hiện tại |
| `postEvent(kind, payload)` | Đẩy event (khóa spin) |
| `pollEvent()` | Lấy event cũ nhất, `null` nếu trống |
| `droppedEvents()` | Số event bị bỏ vì hàng đợi đầy (v0.3.0) |

Mỗi lần chuyển trạng thái hợp lệ đều đẩy 1 lifecycle event
(payload là tên trạng thái, ví dụ `"created"`).

## permissions

`Permission`: `camera` (0), `microphone` (1), `location` (2),
`storage` (3), `notifications` (4).
`PermissionState`: `not_requested` (0), `granted` (1), `denied` (2),
`permanently_denied` (3).

Zig **không** tự hiện hộp thoại xin quyền — hộp thoại là việc của
Android/iOS. Zig giữ bảng trạng thái; native báo kết quả về bằng
`markResult`, Zig đẩy event `permission_result` với payload dạng
`"camera:granted"`.

| Hàm | Ý nghĩa |
| --- | --- |
| `PermissionStore.init()` | Bảng trạng thái rỗng (mặc định `not_requested`) |
| `state(perm)` | Trạng thái hiện tại của 1 quyền |
| `markGranted(perm, granted, permanent)` | Cập nhật trạng thái, trả `PermissionState` mới |
| `needsRequest(perm)` | `true` nếu chưa xin hoặc bị từ chối thường |
| `formatPayload(perm, state, buf)` | `"camera:granted"` để post event |

## network

`Connectivity`: `offline` (0), `wifi` (1), `cellular` (2),
`unknown` (3).

| Hàm | Ý nghĩa |
| --- | --- |
| `NetworkStatus.init()` | Trạng thái mặc định `unknown` |
| `setConnectivity(code)` | Native báo mạng thật (Zig không đọc được ConnectivityManager / NWPathMonitor); đổi thì Zig đẩy event `network_changed` |
| `checkTcp(host, port, timeout_ms)` | TCP connect có timeout thật (socket non-blocking + poll); chỉ IPv4 dạng `"8.8.8.8"`, chưa phân giải tên miền; trả `true` nếu nối được |

## device

`DeviceInfo`: `os`, `arch`, `os_version`, `app_version`, `locale`,
`model`. Native đưa 4 chuỗi sau sang, Zig kiểm tra (rỗng/quá dài/
locale sai định dạng đều bị chặn).

| Hàm | Ý nghĩa |
| --- | --- |
| `DeviceInfo.init(alloc, os, arch, os_version, app_version, locale, model)` | Tạo + kiểm tra |
| `display(alloc)` | Format ra 1 dòng để log, ví dụ `"host x86_64, os linux, app 0.3.0-demo, vi-VN, model demo-pc"` |

## settings

`Settings`: key-value chuỗi/số nguyên/bool, lưu file text
`settings.txt` (mỗi dòng `key=loại:giá trị`, chuỗi được escape).
Key chỉ gồm chữ/số/`_.-`, tối đa 64 ký tự. Load file chưa có thì
coi như trống; dòng lỗi thì bỏ qua, không hỏng cả file.
Từ v0.3.0, `Settings` có spinlock riêng (set/get/remove/save/load
đều khóa).

| Hàm | Ý nghĩa |
| --- | --- |
| `Settings.init(alloc)` | Cài đặt rỗng |
| `setString/setInt/setBool(key, value)` | Ghi 1 key |
| `getString/getInt/getBool(key)` | Đọc 1 key, `null` nếu không có |
| `remove(key)` / `clear()` | Xóa 1 key / xóa hết |
| `count()` | Số key |
| `save(store, relative)` | Ghi file (mặc định `settings.txt`) |
| `load(store, relative)` | Đọc file vào settings |

## files

Đọc/ghi/xóa/liệt kê file trong `files_dir`/`cache_dir`, qua đúng
đường dẫn an toàn của `Storage`. Đọc tối đa 1 MiB mặc định
(`default_max_read_bytes`). Từ v0.3.0, các thao tác file có khóa
module chung (2 thread ghi cùng 1 file không xen kẽ nhau).

| Hàm | Ý nghĩa |
| --- | --- |
| `writeText(store, alloc, relative, data, append, use_cache)` | Ghi (hoặc nối thêm) file text |
| `readText(store, alloc, relative, max_bytes, use_cache)` | Đọc file, trả `[]u8` (caller free) |
| `deleteFile(store, alloc, relative, use_cache)` | Xóa file |
| `exists(store, alloc, relative, use_cache)` | `true` nếu file có |
| `listDir(store, alloc, relative, use_cache)` | Liệt kê tên file trong thư mục |

## background

`TaskKind`: `one_shot` (0), `repeating` (1). `Task`: id, kind,
`interval_ms`, `max_runs` (<= 0 = lặp vô hạn), `next_run_ms`,
`runs`, `active`.

Zig **chỉ giữ lịch** — native gọi `pollDue(now_ms)` khi tới lịch
(WorkManager/AlarmManager bên Android, BGTaskScheduler bên iOS),
Zig trả id task tới hạn rồi native chạy việc thật. Zig không tự
tạo thread/timer. Từ v0.3.0, `TaskQueue` có spinlock cho
add/remove/pollDue/count.

| Hàm | Ý nghĩa |
| --- | --- |
| `TaskQueue.init(alloc)` | Hàng đợi task rỗng |
| `add(id, kind, interval_ms, max_runs, now_ms)` | Đăng ký task |
| `remove(id)` | Xóa task, trả `true` nếu có |
| `pollDue(now_ms)` | Trả id task tới hạn (hoặc `null`), tự cập nhật `next_run_ms`/`runs` |
| `count()` / `countActive()` | Số task / số task đang chạy |
| `find(id)` | Tìm task (không tự khóa — chỉ gọi khi đã giữ khóa hoặc 1 thread) |

## time

| Hàm | Ý nghĩa |
| --- | --- |
| `nowMs()` | Giờ tường, mili-giây từ epoch (i64) |
| `monotonicMs()` | Đồng hồ đơn điệu, mili-giây (đo khoảng cách, không bị đổi giờ hệ thống) |
| `diffMs(a, b)` | `b - a` (mili-giây, có thể âm) |
| `Stopwatch.start()` / `elapsedMs()` / `reset()` | Bấm giờ: bắt đầu, đã trôi bao nhiêu ms, bấm lại |
| `formatDuration(ms, buf)` | `"0ms"`, `"999ms"`, `"1s"`, `"1.5s"`, `"1m05s"`, `"1h02m03s"`, `"2d03h04m"`; âm thì về `"0ms"`; trả slice vào `buf` |

Dùng `std.Io.Clock` (Zig 0.17.1 bỏ `std.time.milliTimestamp`).

## hash

SHA-256 bằng `std.crypto`. Hex dài 64 ký tự (`hex_len = 64`).

| Hàm | Ý nghĩa |
| --- | --- |
| `sha256Hex(data, out: *[64]u8)` | SHA-256 của chuỗi, ghi hex vào `out` |
| `sha256Alloc(alloc, data)` | Như trên, trả `[]u8` (caller free) |
| `sha256File(store, alloc, relative, max_bytes, use_cache)` | SHA-256 của file trong files_dir/cache_dir |
| `verifyFile(store, alloc, relative, expected_hex)` | `true` nếu hash file khớp (so sánh không phân biệt hoa/thường) |

Test với vector chuẩn FIPS 180-4: chuỗi rỗng →
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`,
`"abc"` → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.

## http

Kiểm tra HTTP đơn giản bằng TCP IPv4 có timeout. **Không TLS, không
phân giải tên miền** — nhận IP hoặc host đã phân giải sẵn từ native.
`Response`: `status` (u16), `content_length`, `content_type`, `body`
(caller `deinit`), `isOk()` (status 200..299). Giới hạn:
`max_response_bytes = 64 KiB`, `max_timeout_ms = 30000`.

| Hàm | Ý nghĩa |
| --- | --- |
| `request(alloc, method, host, port, path, timeout_ms)` | `Method.head` / `.get`; trả `Response` (đọc hết body theo Content-Length) |
| `getStatus(host, port, path, timeout_ms)` | Chỉ lấy status code, -1 nếu nối không được / hết giờ / response hỏng |
| `headStatus(host, port, path, timeout_ms)` | Như trên với HEAD |
| `parseResponse(text)` | Parse response đã đọc đủ header (dùng trong test; lỗi định dạng → `InvalidHttp`) |

## json

Helper mỏng trên `std.json` — không viết parser tay.

| Hàm | Ý nghĩa |
| --- | --- |
| `stringify(alloc, value)` | Struct/slice → JSON `[]u8` (caller free) |
| `parse(alloc, T, text)` | JSON → struct `T` (trả `Parsed(T)`, cần `deinit`) |
| `EventJson` | `{ "kind", "seq", "payload" }` |
| `encodeEvent(alloc, kind, seq, payload)` | Event → JSON |
| `decodeEvent(alloc, text)` | JSON → `DecodedEvent` (cần `deinit`) |
| `ConfigJson` | `{ "theme", "font_size", "sound" }` (có giá trị mặc định) |
| `settingsToJson(alloc, settings)` | Cài đặt → JSON (chỉ ghi field có giá trị) |
| `jsonToSettings(alloc, settings, text)` | JSON → ghi đè vào settings (field nào có trong JSON mới ghi) |

## ui

Cây UI khai báo trong Zig. **Zig chỉ định nghĩa UI + layout + sự
kiện; việc vẽ lên màn hình vẫn do Kotlin/Swift làm** (xem ví dụ
`renderDemoUi()` trong `MainActivity.kt` / `MobileBridge.swift`).

`NodeKind`: `text`, `button`, `image`, `row`, `column`, `scroll`,
`spacer`. `Props`: `text_color` (RGBA), `bg_color`, `font_size`
(mặc định 16), `width`/`height` (null = tự đo), `padding`,
`alignment` (`.start` / `.center` / `.end`). `Frame`: x, y, w, h
(f32, đơn vị dp).

`Color`: `rgba(r, g, b, a)`, `rgb(r, g, b)`, các màu có sẵn
(`black`, `white`, `transparent`, ...). `UiTree`: root là Column,
cấp phát bằng arena (gọi `deinit` 1 lần là xong).

| Hàm | Ý nghĩa |
| --- | --- |
| `UiTree.init(backing)` | Cây rỗng, root là Column |
| `root()` | Node gốc |
| `addText/addButton/addImage/addRow/addColumn/addScroll/addSpacer(parent, id, ...)` | Thêm node con (id trùng thì `error.InvalidEvent`) |
| `findById(id)` | Tìm node theo id (đệ quy), `null` nếu không có |
| `layout(width, height)` | Tính khung cho toàn cây trong khung width × height |
| `clickPayload(id, buf)` | `"ui:click:<id>"` nếu id là nút bấm, `null` nếu không phải / không có |
| `toJson(alloc)` | Cây đã layout → JSON (kind, id, text, image, x/y/w/h, bg, children) |
| `demoTree(backing)` | Cây demo dùng chung cho demo host + FFI: tiêu đề, 2 nút (`btn_sync`, `btn_settings`) trong 1 hàng, ảnh `assets/hero.png`, spacer |

**Giới hạn:** độ rộng text chỉ là ước lượng (mỗi ký tự ≈ 0.6 ×
font_size, cộng padding) — không có font rendering thật, native cần
đo lại bằng font thật. Không có animation. `Scroll` layout giống
Column (chưa có cuộn thật — cuộn là việc của native).

## canvas

Danh sách lệnh vẽ sinh từ UI tree, để native vẽ bằng Canvas.
`DrawCmd`: `kind` (`rect` / `text` / `image`), `x/y/w/h`, `color`
(RGBA), `radius` (bo góc, 0 = không bo), `text`, `font_size`, `path`
(ảnh).

| Hàm | Ý nghĩa |
| --- | --- |
| `fromUiTree(alloc, tree)` | UI tree → `Canvas` (danh sách lệnh vẽ) |
| `count()` | Số lệnh vẽ |
| `toJson(alloc, canvas)` | Lệnh vẽ → JSON cho native |
| `renderPpm(alloc, canvas, width, height)` | Render ra ảnh PPM P6 (nền trắng, rect bo góc, ảnh là khung xám có viền) để test trên host |

**Giới hạn:** text trong canvas chỉ là **vạch placeholder**, không
phải glyph thật (không có font rendering). Ảnh chỉ là placeholder
xám — native tự load ảnh thật theo `path`.

## spinlock

`SpinLock`: khóa spin bằng atomic (Zig 0.17.1 bỏ `Thread.Mutex`).
`lock()` / `unlock()` / `tryLock()`. Dùng cho global App, Settings,
files, TaskQueue, EventQueue. **Không khóa lại trên cùng 1 thread**
(spinlock khóa lại sẽ kẹt vĩnh viễn) — các hàm `find()`/`findIndex()`
không tự khóa vì lý do này, chỉ gọi khi đã giữ khóa.

## FFI Android (JNI)

Package `com.zigmobile.app`, class `MobileBridge`
(`Java_com_zigmobile_app_MobileBridge_*`). Xem
`examples/android/MainActivity.kt`. Các hàm chỉ nhận số nguyên là
đường an toàn (không đụng bảng hàm JNI); hàm chuỗi dùng
GetStringUTFChars (mục 169) / Release (170) / NewStringUTF (167) —
thứ tự lấy từ `jni.h` chuẩn nhưng **chưa kiểm chứng trên máy Android
thật**.

| Hàm | Ý nghĩa |
| --- | --- |
| `mobileInit(filesDir, cacheDir)` | Init, trả 0 = ok |
| `mobileOnCreate/OnStart/OnResume/OnPause/OnStop/OnDestroy()` | Vòng đời |
| `mobilePostEvent(code)` / `mobilePostEventWithPayload(code, payload)` | Post event |
| `mobilePollEventCode()` / `mobilePollEventPayload()` | Poll event (code < 0 = trống) |
| `mobileGetState()` / `mobileVersion()` | Trạng thái / version |
| `mobilePermissionState(code)` / `mobilePermissionMarkResult(code, state)` | Quyền |
| `mobileNetworkSetConnectivity(code)` / `mobileNetworkReachable(host, port, timeoutMs)` | Mạng (1 = tới được) |
| `mobileDeviceSetInfo(osVersion, appVersion, locale, model)` | Thiết bị |
| `mobileSettingsSetString/SetInt/SetBool`, `mobileSettingsGetString/GetInt/GetBool`, `mobileSettingsSave/Load()` | Cài đặt |
| `mobileFileWriteText/ReadText/Delete/Exists(relative, ...)` | File |
| `mobileBackgroundAddTask/PollDue/RemoveTask(...)` | Task nền |
| `mobileTimeNowMs()` / `mobileTimeMonotonicMs()` | Giờ (jlong) — v0.3.0 |
| `mobileHashSha256(text)` | SHA-256 hex, null nếu lỗi — v0.3.0 |
| `mobileHashFileSha256(relative)` | SHA-256 hex của file, null nếu file không có — v0.3.0 |
| `mobileHttpHeadStatus(host, port, path, timeoutMs)` / `mobileHttpGetStatus(...)` | Status code, -1 nếu lỗi — v0.3.0 |
| `mobileJsonEncodeEvent(code, payload)` | Event → JSON `{"kind","seq":0,"payload"}` (seq luôn 0 qua FFI) — v0.3.0 |
| `mobileUiDemoJson(width, height)` | JSON cây UI demo đã layout — v0.3.0 |
| `mobileUiClick(id)` | Báo click, Zig đẩy event `"ui:click:<id>"`, 0 = ok — v0.3.0 |
| `mobileCanvasDemoJson(width, height)` | JSON lệnh vẽ của cây UI demo — v0.3.0 |
| `mobileDroppedEvents()` | Số event bị bỏ, -1 nếu chưa init — v0.3.0 |

## FFI iOS (C ABI)

Xem `examples/ios/MobileBridge.swift` và
`examples/ios/zig-mobile-Bridging-Header.h`. Hàm trả chuỗi dùng
quy ước out-buffer: trả 1 = có (copy vào `out_buf`), 0 = không có,
-12 = `BufferTooSmall` (`out_written` = số byte cần), số âm khác =
mã lỗi.

| Hàm | Ý nghĩa |
| --- | --- |
| `mobile_init(files_dir, cache_dir)` | Init, trả 0 = ok |
| `mobile_shutdown()` | Dọn dẹp |
| `mobile_lifecycle(state_code)` | Chuyển trạng thái |
| `mobile_state()` | Trạng thái hiện tại |
| `mobile_on_event(code, payload_ptr, payload_len)` | Post event |
| `mobile_poll_event(out_code, out_buf, out_capacity, out_written)` | Poll event (0 = trống) |
| `mobile_version()` | Chuỗi version tĩnh |
| `mobile_set_log_callback(cb)` / `mobile_set_event_callback(cb)` | Callback log/event |
| `mobile_permission_state(code)` / `mobile_permission_mark_result(code, state)` | Quyền |
| `mobile_network_set_connectivity(code)` / `mobile_network_reachable(host, port, timeout_ms)` | Mạng |
| `mobile_device_set_info(os_version, app_version, locale, model)` | Thiết bị |
| `mobile_settings_set_string/set_int/set_bool`, `mobile_settings_get_string/get_int/get_bool`, `mobile_settings_save/load()` | Cài đặt |
| `mobile_file_write_text/read_text/delete/exists(...)` | File |
| `mobile_background_add_task/poll_due/remove_task(...)` | Task nền |
| `mobile_time_now_ms()` / `mobile_time_monotonic_ms()` | Giờ (i64) — v0.3.0 |
| `mobile_hash_sha256(text, out_buf, ...)` | SHA-256 hex — v0.3.0 |
| `mobile_hash_file_sha256(relative, out_buf, ...)` | SHA-256 hex của file (0 = file không có) — v0.3.0 |
| `mobile_http_head_status(host, port, path, timeout_ms)` / `mobile_http_get_status(...)` | Status code, -1 nếu lỗi — v0.3.0 |
| `mobile_dropped_events()` | Số event bị bỏ, -1 nếu chưa init — v0.3.0 |
| `mobile_json_encode_event(code, payload_ptr, payload_len, out_buf, ...)` | Event → JSON — v0.3.0 |
| `mobile_ui_demo_json(width, height, out_buf, ...)` | JSON cây UI demo đã layout — v0.3.0 |
| `mobile_ui_click(id)` | Báo click, 0 = ok — v0.3.0 |
| `mobile_canvas_demo_json(width, height, out_buf, ...)` | JSON lệnh vẽ của cây UI demo — v0.3.0 |

## Mã lỗi

0 = ok. Số âm trả về qua FFI (Kotlin/Swift switch theo số):

| Mã | Lỗi Zig | Ý nghĩa |
| --- | --- | --- |
| -1 | `NotInitialized` | App chưa init |
| -2 | `AlreadyInitialized` | App đã init rồi |
| -3 | `InvalidTransition` | Chuyển trạng thái vòng đời không hợp lệ |
| -4 | `InvalidEvent` | Sự kiện không hợp lệ |
| -5 | `QueueFull` | Hàng đợi sự kiện đã đầy |
| -6 | `QueueEmpty` | Hàng đợi sự kiện đang trống |
| -7 | `InvalidPath` | Đường dẫn không hợp lệ |
| -8 | `MissingStoragePath` | Thiếu đường dẫn files/cache (native phải đưa từ Android/iOS) |
| -9 | `NoCallback` | Chưa đăng ký callback |
| -10 | `InvalidUtf8` | Chuỗi không phải UTF-8 hợp lệ |
| -11 | `JniError` | Lỗi JNI (env null, string null, hoặc hàm JNI trả null) |
| -12 | `BufferTooSmall` | Buffer phía gọi cấp quá nhỏ |
| -13 | `UnsupportedPlatform` | Platform này chưa hỗ trợ |
| -14 | `OutOfMemory` | Hết bộ nhớ |
| -15 | `InvalidPermission` | Quyền không hợp lệ |
| -16 | `InvalidSetting` | Cài đặt không hợp lệ |
| -17 | `FileNotFound` | Không tìm thấy file |
| -18 | `NetworkUnavailable` | Không có mạng |
| -19 | `TaskNotFound` | Không tìm thấy task nền |
| -20 | `InvalidDeviceInfo` | Thông tin thiết bị không hợp lệ |
| -21 | `InvalidTask` | Task nền không hợp lệ |
| -22 | `InvalidHttp` | Response HTTP không hợp lệ (v0.3.0) |
| -23 | `InvalidJson` | JSON không hợp lệ (v0.3.0) |
