# zig-mobile — Thư viện Zig làm app mobile (Android + iOS)

Thư viện Zig để viết **ruột** app mobile một lần, dùng chung cho cả
Android và iOS: vòng đời app, hàng đợi sự kiện, log, đường dẫn lưu trữ,
xin quyền, trạng thái mạng, thông tin thiết bị, cài đặt, file, task nền,
thời gian, hash, HTTP, JSON, và cây UI khai báo + layout.
Viết cho Zig **0.17.1**, cùng phong cách với thư viện
`security-netsec` (test xanh mới tính là xong, không giấu giới hạn).

**Zig làm ruột, Kotlin/Swift làm vỏ.** Trong này không có UI vẽ thật:
nút bấm, màn hình, navigation vẫn viết bằng Jetpack Compose / SwiftUI
như bình thường. Từ v0.3.0, Zig có thêm module `ui.zig` để **khai báo**
cây UI (Text/Button/Image/Row/Column/Scroll/Spacer) và **tính layout**
(x, y, width, height) — nhưng việc vẽ lên màn hình vẫn do Kotlin/Swift
làm, dựa trên JSON cây UI / danh sách lệnh vẽ mà Zig trả về. Zig không
vẽ được Jetpack Compose / SwiftUI trực tiếp, không có font rendering
thật, không có animation.

## Cài Zig

Máy này đã có Zig 0.17.1 ở `~/workspace/tools/zig-x86_64-linux-0.17.1/zig`.
Trên máy khác, tải ở https://ziglang.org/download/ rồi cho `zig` vào PATH.

```sh
export PATH=~/workspace/tools/zig-x86_64-linux-0.17.1:$PATH
zig version   # 0.17.1
```

## Build và test

```sh
cd ~/workspace/zig-mobile
zig build test     # unit test (host)
zig build          # thư viện host + demo vào zig-out/bin/
./zig-out/bin/mobile-demo

zig build android  # libmobile.so cho aarch64-linux-android -> zig-out/lib/android/arm64-v8a/
zig build ios      # libmobile.a cho aarch64-ios -> zig-out/lib/ios/
```

## Dùng trong code Zig

```zig
const mobile = @import("mobile");

var app = try mobile.App.init(alloc, .{});
defer app.deinit();

try app.onCreate();
try app.onStart();
try app.onResume();

try app.postEvent(.custom, "hello-mobile");
while (app.pollEvent()) |*ev| {
    defer ev.deinit(alloc);
    std.debug.print("[{d}] {s}: {s}\n", .{ ev.seq, ev.kind.toString(), ev.payload });
}

try app.onPause();
try app.onStop();
try app.onDestroy();
```

Chuyển trạng thái sai (ví dụ `created` nhảy thẳng sang `resumed`)
trả `error.InvalidTransition` và giữ nguyên trạng thái cũ.

## Dùng cho Android (Kotlin + JNI)

Build `.so` rồi copy vào `app/src/main/jniLibs/arm64-v8a/libmobile.so`,
xem chi tiết trong `examples/android/README.md` và
`examples/android/MainActivity.kt`.

> Lưu ý khi build: Zig **không tự cấp được bionic libc** cho Android
> (cần NDK, máy này không có) nên `zig build android` build `.so`
> **không link libc**. Các chỗ gọi libc (log ghi file, `getcwd`,
> `mkdir`) đều bị chặn bằng `comptime` trên bản Android — log file
> trên Android hiện là no-op, dùng callback hoặc stderr thay thế.
> Đã kiểm chứng: `.so` build ra được, `nm -D` thấy đủ 84 symbol
> export (44 `Java_*` + 40 `mobile_*`). Chưa kiểm chứng load `.so`
> thật trên máy Android (cần APK + máy thật).

```kotlin
MobileBridge.mobileInit(filesDir.absolutePath, cacheDir.absolutePath)
MobileBridge.mobileOnCreate()   // onStart/onResume/onPause/onStop/onDestroy tương tự
MobileBridge.mobilePostEvent(4) // 4 = back_pressed
val code = MobileBridge.mobilePollEventCode()
val payload = MobileBridge.mobilePollEventPayload()
```

Tên hàm JNI gắn với package `com.zigmobile.app` + class `MobileBridge`
(`Java_com_zigmobile_app_MobileBridge_*`). Đổi package thì sửa tên hàm
trong `src/android.zig` rồi build lại `.so`.

## Dùng cho iOS (Swift + C ABI)

Build `.a` rồi link trong Xcode, thêm bridging header, xem chi tiết
trong `examples/ios/README.md`, `examples/ios/MobileBridge.swift` và
`examples/ios/zig-mobile-Bridging-Header.h`.

```swift
MobileBridge.shared.start()              // init + created -> started -> resumed
MobileBridge.shared.postEvent(code: 1, payload: "hello-ios")
let events = MobileBridge.shared.pollEvents()
MobileBridge.shared.pause()              // / resume() / stop() / shutdown()
```

## Cấu trúc

| File | Làm gì |
| --- | --- |
| `src/root.zig` | Module `mobile`, re-export các module con |
| `src/version.zig` | Tên + phiên bản (`zig-mobile 0.3.0`) |
| `src/errors.zig` | Error set chung + mã lỗi FFI (0 = ok, âm = lỗi) |
| `src/platform.zig` | Phát hiện android/ios/host lúc biên dịch |
| `src/log.zig` | Log level debug/info/warn/error, stderr/file/callback |
| `src/event.zig` | Sự kiện + hàng đợi FIFO (tối đa 256, ring buffer, khóa spin) |
| `src/storage.zig` | files_dir/cache_dir, chặn đường dẫn `..` và tuyệt đối |
| `src/app.zig` | App: state machine vòng đời + event + log + storage |
| `src/permissions.zig` | Trạng thái xin quyền camera/mic/vị trí/bộ nhớ/thông báo |
| `src/network.zig` | Trạng thái mạng + kiểm tra TCP tới được host không |
| `src/device.zig` | Thông tin thiết bị/app do native đưa sang |
| `src/settings.zig` | Cài đặt key-value, lưu file `settings.txt` |
| `src/files.zig` | Đọc/ghi/xóa/liệt kê file trong files_dir/cache_dir |
| `src/background.zig` | Mô tả task nền, native trigger theo lịch |
| `src/time.zig` | Giờ tường/monotonic (ms), đo khoảng cách, format thời gian |
| `src/hash.zig` | SHA-256 cho chuỗi và file, kiểm tra file integrity |
| `src/http.zig` | Kiểm tra HTTP đơn giản bằng TCP IPv4 (không TLS, không DNS) |
| `src/json.zig` | Helper JSON mỏng trên std.json (event, cài đặt) |
| `src/ui.zig` | Cây UI khai báo + layout flex + sự kiện bấm |
| `src/canvas.zig` | Danh sách lệnh vẽ từ UI tree, render PPM trên host |
| `src/jni.zig` | Helper JNI: chuỗi UTF-8, bảng hàm JNI, registry callback |
| `src/android.zig` | Export `Java_*` cho Kotlin |
| `src/ios.zig` | Export `mobile_*` C ABI cho Swift |
| `src/spinlock.zig` | Khóa spin atomic cho global App (Zig 0.17.1 bỏ `Thread.Mutex`) |
| `examples/demo.zig` | Demo host: vòng đời + event + mọi module v0.2.0/v0.3.0 |
| `examples/android/` | `MainActivity.kt`, `AndroidManifest.xml`, Gradle mẫu, hướng dẫn |
| `examples/ios/` | `MobileBridge.swift`, bridging header, hướng dẫn |
| `docs/API.md` | Tài liệu API đầy đủ: module, hàm chính, mã lỗi, FFI |
| `CHANGELOG.md` | Lịch sử thay đổi v0.1.0 → v0.3.0 |
| `.github/workflows/ci.yml` | CI: `zig build test` + `zig build android` + `zig build ios` |

## Vòng đời app

```
unknown -> created -> started -> resumed -> paused -> resumed ...
                                     paused -> stopped -> started ...
                                     stopped -> destroyed
                                     created -> destroyed
```

`destroyed` là trạng thái cuối, không quay lại được. Mỗi lần chuyển
trạng thái hợp lệ đều đẩy một lifecycle event vào hàng đợi.

## Mã trạng thái / mã event (Kotlin/Swift switch theo số)

Trạng thái: 0 unknown, 1 created, 2 started, 3 resumed, 4 paused,
5 stopped, 6 destroyed (-1 = chưa init).

Event: 0 lifecycle, 1 custom, 2 network_changed, 3 low_memory,
4 back_pressed, 5 permission_result, 6 deep_link.

Quyền: 0 camera, 1 microphone, 2 location, 3 storage,
4 notifications. Trạng thái quyền: 0 chưa xin, 1 đã cấp,
2 bị từ chối, 3 từ chối vĩnh viễn.

Mạng: 0 offline, 1 wifi, 2 cellular, 3 unknown.

## Module mới ở v0.2.0

- **Quyền (`permissions.zig`).** Zig không tự hiện hộp thoại xin
  quyền được — hộp thoại là việc của Android/iOS. Zig giữ bảng trạng
  thái (`not_requested/granted/denied/permanently_denied`), native
  báo kết quả về bằng `markResult`, Zig đẩy event `permission_result`
  với payload dạng `"camera:granted"`.
- **Mạng (`network.zig`).** Native báo trạng thái mạng thật qua
  `setConnectivity` (Zig không đọc được ConnectivityManager /
  NWPathMonitor). Ngoài ra Zig tự kiểm tra được bằng TCP connect có
  timeout thật (`checkTcp`, socket non-blocking + poll, theo cách
  netsec làm): chỉ IPv4 dạng `"8.8.8.8"`, chưa phân giải tên miền.
- **Thiết bị (`device.zig`).** Native đưa `os_version`, `app_version`,
  `locale`, `model` sang, Zig kiểm tra (chuỗi rỗng/quá dài/locale sai
  định dạng đều bị chặn) rồi format ra để log.
- **Cài đặt (`settings.zig`).** Key-value chuỗi/số nguyên/bool, key
  chỉ gồm chữ/số/`_.-`, lưu file text `settings.txt` (mỗi dòng
  `key=loại:giá trị`, chuỗi được escape). Load file chưa có thì coi
  như trống; dòng lỗi thì bỏ qua, không hỏng cả file.
- **File (`files.zig`).** Đọc/ghi/nối thêm/xóa/kiểm tra/liệt kê file
  trong `files_dir`/`cache_dir`, qua đúng đường dẫn an toàn của
  Storage. Đọc tối đa 1 MiB mặc định. File IO dùng
  `std.Io.Threaded` bản single-threaded (không spawn thread, không
  dùng `std.c`) nên chạy được trên bản Android không link libc.
- **Task nền (`background.zig`).** Chỉ giữ lịch: id, chạy một lần
  hay lặp lại, bao lâu chạy một lần, tối đa mấy lần. Native gọi
  `pollDue(now_ms)` khi tới lịch (WorkManager/AlarmManager bên
  Android, BGTaskScheduler bên iOS), Zig trả id task tới hạn rồi
  native chạy việc thật. Zig không tự tạo thread/timer.

## Module mới ở v0.3.0

- **Thời gian (`time.zig`).** `nowMs()` (giờ tường, ms từ epoch),
  `monotonicMs()` (đồng hồ đơn điệu, đo khoảng cách, không bị đổi giờ
  hệ thống), `diffMs(a, b)`, `Stopwatch` (bắt đầu/đo/reset),
  `formatDuration(ms, buf)` ra `"0ms"`, `"1.5s"`, `"1m05s"`,
  `"1h02m03s"`, `"2d03h04m"`. Dùng `std.Io.Clock` (Zig 0.17.1 bỏ
  `std.time.milliTimestamp`).
- **Hash (`hash.zig`).** SHA-256 bằng `std.crypto` cho chuỗi
  (`sha256Hex`/`sha256Alloc`, hex 64 ký tự) và file (`sha256File`,
  đọc tối đa 1 MiB mặc định), `verifyFile` so sánh hex không phân
  biệt hoa/thường. Test với vector chuẩn FIPS 180-4 (chuỗi rỗng,
  `"abc"`, chuỗi 56 byte).
- **HTTP (`http.zig`).** Kiểm tra HTTP đơn giản bằng TCP IPv4 có
  timeout (`request` HEAD/GET, trả status code + `Content-Type` +
  `Content-Length` + body; `getStatus`/`headStatus` trả status hoặc
  -1 khi lỗi). **Không TLS, không phân giải tên miền** — nhận IP
  hoặc host đã phân giải sẵn từ native. Test trên host bằng listener
  local (server test trên thread riêng).
- **JSON (`json.zig`).** Helper mỏng trên `std.json`, không viết
  parser tay: `stringify`/`parse`, `encodeEvent`/`decodeEvent`
  (event ↔ `{"kind","seq","payload"}`), `settingsToJson`/
  `jsonToSettings` (cài đặt ↔ JSON, chỉ ghi field có giá trị).
- **UI (`ui.zig`).** Cây UI khai báo trong Zig: node Text, Button,
  Image (chỉ tên/đường dẫn), Row, Column, Scroll, Spacer; thuộc tính
  text, màu RGBA, kích thước, padding, căn lề, id, onClick. Layout
  flex dọc/ngang tính khung (x, y, width, height) cho từng node trên
  host, có unit test. Khi native báo click theo id (`mobileUiClick`
  / `mobile_ui_click`), Zig kiểm tra id có phải nút bấm không rồi
  đẩy event `custom` dạng `"ui:click:<id>"` vào hàng đợi event đã có.
  `toJson()` xuất cây đã layout ra JSON cho native render.
- **Canvas (`canvas.zig`).** Từ cây UI sinh danh sách lệnh vẽ
  (rect, rounded rect, text, image placeholder) — `fromUiTree`,
  `toJson` cho native vẽ bằng Canvas. Trên host render được ra
  buffer pixel để test (`renderPpm`, xuất ảnh PPM): nền trắng,
  rect bo góc, ảnh là khung xám có viền. **Text trong canvas chỉ là
  vạch placeholder, không phải glyph thật** (không có font rendering).
- **An toàn thread hơn (v0.3.0).** `Settings` (spinlock riêng),
  `files` (khóa module chung cho các thao tác file) và `TaskQueue`
  (spinlock cho add/remove/pollDue/count) đã khóa ở những chỗ hợp lý.
  Hàng đợi event vẫn tối đa 256, nhưng từ nay event bị bỏ được **đếm**
  (`App.droppedEvents()`, FFI `mobileDroppedEvents` /
  `mobile_dropped_events`) thay vì mất im lặng — native poll chậm thì
  nhìn con số này là biết.

## Giới hạn đã biết (nói thẳng, không giấu)

- **UI: Zig chỉ định nghĩa UI + layout + sự kiện, không vẽ thật.**
  Muốn thấy giao diện thì Kotlin/Swift phải render cây UI (xem ví dụ
  `renderDemoUi()` trong `MainActivity.kt` / `MobileBridge.swift` —
  ví dụ render, chưa từng biên dịch/chạy thật). Không có font
  rendering thật (độ rộng text chỉ là ước lượng 0.6 × font_size,
  native cần đo lại bằng font thật), không có animation, không có
  native view thật trên máy này để kiểm chứng.
- **HTTP chỉ IPv4, không TLS, không phân giải tên miền.** Muốn check
  tên miền thì native phân giải trước rồi đưa IP sang. Check ra
  Internet trên máy build này không đáng tin (mạng sandbox chặn /
  chuyển hướng) — xem `security-netsec` và `nettrace` cũng gặp vậy.
- **Task nền không tự chạy.** Zig chỉ giữ lịch; hệ thống (WorkManager
  / BGTaskScheduler) mới là bên đánh thức app đúng giờ.
- **File trên Android chưa kiểm chứng runtime.** File IO dùng syscall
  qua `std.Io` single-threaded (không cần libc) nên về lý thuyết
  chạy được, nhưng chưa từng chạy thật trên máy Android.
- **Zig không gọi ngược sang Kotlin.** Event/log từ Zig sang Android
  phải poll (`mobilePollEventCode/Payload`), vì gọi ngược cần method ID
  và AttachCurrentThread. Phía iOS thì đăng ký callback được
  (`mobile_set_log_callback`, `mobile_set_event_callback`).
- **JNI đọc/tạo chuỗi Java dùng bảng hàm JNI** theo thứ tự trong
  `jni.h` (GetStringUTFChars = mục 169, Release = 170, NewStringUTF =
  167). Thứ tự này lấy từ header chuẩn của NDK nhưng **chưa kiểm chứng
  trên máy Android thật** (máy này không có Android SDK/NDK). Đường an
  toàn là các hàm JNI chỉ nhận số nguyên — chúng không đụng tới bảng.
  Trước khi dùng app thật, cần chạy thử trên máy Android thật và xem
  log có crash ở đoạn đọc chuỗi không.
- **iOS chưa kiểm chứng.** Máy này không có Xcode, không có iPhone
  Simulator, không sign được app. Phần C ABI chỉ mới kiểm chứng bằng
  test host (gọi đúng các hàm `mobile_*` trên Linux) và cross-compile
  sang `aarch64-ios` (ra `zig-out/lib/ios/libmobile.a`, `strings` thấy đủ
  40 symbol `_mobile_*`).
- **Chưa build APK thật.** `zig build android` chỉ ra file `.so`;
  đóng gói APK vẫn cần Android Studio/Gradle trên máy có SDK. `.so`
  đã kiểm chứng export đủ symbol, nhưng chưa kiểm chứng load thật
  trên máy Android (cần APK + máy thật).
- **Chuỗi qua JNI là modified UTF-8.** Ký tự NUL hoặc ngoài BMP
  (một số emoji) khi qua `GetStringUTFChars` sẽ khác UTF-8 thường.
  Tránh gửi hai loại đó qua payload, hoặc gửi dạng byte.
- **Poll event với buffer quá nhỏ sẽ bỏ event đó** (iOS). Swift nên
  dùng buffer từ 1024 byte trở lên.
- **App không thread-safe hoàn toàn.** Từ v0.2.0, chuyển trạng thái
  và postEvent/pollEvent đã được khóa bằng spinlock; từ v0.3.0,
  cài đặt, file và task nền cũng đã khóa ở những chỗ hợp lý nên gọi
  lệch thread không làm hỏng hàng đợi hay dữ liệu chung. Nhưng device
  và log vẫn nên gọi từ main thread, giống Activity/ViewController
  vẫn làm. count/isEmpty của hàng đợi chỉ đọc, không khóa — đừng dùng
  làm điều kiện đồng bộ.
- **Hàng đợi tối đa 256 event.** Đầy thì `postEvent` trả
  `error.QueueFull`, phía native phải poll thường xuyên. Từ v0.3.0,
  số event bị bỏ được đếm (`App.droppedEvents()`) thay vì mất im lặng.
- **Android/iOS bắt buộc đưa files_dir/cache_dir thật** lúc init.
  Zig không gọi được `Context.getFilesDir()` hay FileManager.
