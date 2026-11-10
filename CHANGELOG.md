# CHANGELOG — zig-mobile

Lịch sử thay đổi của thư viện. Phiên bản hiện tại: **0.3.0** (Zig 0.17.1).
Chỉ làm local, chưa từng push GitHub.

## v0.3.0 — 2026-11-10

Thư viện hoàn chỉnh: thêm 6 module mới, an toàn thread hơn, demo đầy đủ,
tài liệu API, CI.

### Mới
- **time.zig** — `nowMs()` (giờ tường), `monotonicMs()` (đồng hồ đơn
  điệu), `diffMs()`, `Stopwatch`, `formatDuration()` ra `"0ms"`,
  `"1.5s"`, `"1m05s"`, `"1h02m03s"`, `"2d03h04m"`.
- **hash.zig** — SHA-256 (`std.crypto`) cho chuỗi (`sha256Hex`,
  `sha256Alloc`) và file (`sha256File`), `verifyFile` kiểm tra file
  integrity. Test với vector chuẩn FIPS 180-4 (chuỗi rỗng, `"abc"`).
- **http.zig** — kiểm tra HTTP đơn giản bằng TCP IPv4 có timeout
  (`request` HEAD/GET, `getStatus`/`headStatus` trả status hoặc -1).
  Không TLS, không phân giải tên miền. Test trên host bằng listener local.
- **json.zig** — helper JSON mỏng trên `std.json`: `stringify`/`parse`,
  `encodeEvent`/`decodeEvent`, `settingsToJson`/`jsonToSettings`
  (round-trip test).
- **ui.zig** — cây UI khai báo trong Zig: Text, Button, Image (chỉ
  tên/đường dẫn), Row, Column, Scroll, Spacer; thuộc tính text, màu
  RGBA, kích thước, padding, căn lề, id, onClick. Layout flex dọc/ngang
  tính khung (x, y, width, height) trên host, có unit test. Click theo
  id thì Zig đẩy event `custom` `"ui:click:<id>"` vào hàng đợi event.
  `toJson()` xuất cây đã layout ra JSON cho native render.
- **canvas.zig** — danh sách lệnh vẽ (rect, rounded rect, text, image
  placeholder) từ UI tree; `toJson` cho native vẽ bằng Canvas;
  `renderPpm` render ra buffer pixel / ảnh PPM trên host để test.
- **FFI mới** — 11 hàm `Java_*` (time, hash, HTTP, JSON, UI/canvas,
  dropped) và 11 hàm `mobile_*` tương ứng; `MainActivity.kt` và
  `MobileBridge.swift` có thêm ví dụ render UI tree sang View native
  (ví dụ render, chưa từng biên dịch/chạy thật).
- **Tài liệu** — `docs/API.md` (đủ module + hàm chính + mã lỗi),
  `CHANGELOG.md` này, `.github/workflows/ci.yml` (chạy `zig build
  test`, `zig build android`, `zig build ios`).

### Thay đổi
- Version lên **0.3.0** (`src/version.zig`, `build.zig.zon`,
  `src/root.zig`).
- **An toàn thread hơn:** `Settings`, `files`, `TaskQueue` đã khóa
  bằng spinlock ở những chỗ hợp lý (v0.2.0 chỉ khóa vòng đời +
  event queue).
- **Event bị bỏ được đếm:** hàng đợi vẫn tối đa 256, nhưng
  `App.droppedEvents()` (FFI `mobileDroppedEvents` /
  `mobile_dropped_events`) cho biết đã bỏ bao nhiêu event vì đầy,
  thay vì mất im lặng.
- Mã lỗi mới: `InvalidHttp` (-22), `InvalidJson` (-23).
- Demo host mở rộng: dùng hết các module (quyền, mạng, device,
  settings, file, task nền, time, hash, HTTP local, JSON, UI tree +
  canvas, xuất ảnh PPM test `ui.ppm`).

### Giới hạn (nói thẳng)
- Zig chỉ định nghĩa UI + layout + sự kiện; vẽ thật vẫn do
  Kotlin/Swift làm. Không có font rendering thật (độ rộng text là
  ước lượng, canvas text chỉ là vạch placeholder), không có animation,
  không có native view thật trên máy này để kiểm chứng.
- HTTP: không TLS, IPv4 only, không phân giải tên miền.
- Chưa kiểm chứng APK thật (không có Android SDK), iOS thật
  (không có Xcode); ví dụ Kotlin/Swift chưa từng biên dịch/chạy.

## v0.2.0 — 2026-11-10

- Thêm 6 module: **permissions** (trạng thái xin quyền, native báo
  kết quả về, Zig đẩy event `permission_result`), **network** (trạng
  thái mạng + kiểm tra TCP tới được host không, IPv4 only),
  **device** (thông tin thiết bị/app do native đưa sang),
  **settings** (key-value, lưu file `settings.txt`), **files**
  (đọc/ghi/xóa/liệt kê file trong files_dir/cache_dir),
  **background** (giữ lịch task nền, native trigger theo lịch).
- Spinlock cho `postEvent`/`pollEvent`; 20 hàm `Java_*` + 20 hàm
  `mobile_*` mới; khung Gradle Android + README iOS.
- `zig build test` 31/31 pass; `zig build android` ra `libmobile.so`
  4,3 MB; `zig build ios` ra `libmobile.a` 3,4 MB.
- Lần làm đầu bị hệ thống an toàn từ chối; làm lại lần 2 khi người
  dùng hỏi lại thì xong.

## v0.1.0 — 2026-11-10

- Bản đầu: vòng đời app (state machine), hàng đợi sự kiện FIFO tối
  đa 256, log, storage (chặn `..` và đường dẫn tuyệt đối),
  platform/errors/version.
- Android: helper JNI + 13 hàm `Java_com_zigmobile_app_MobileBridge_*`,
  build `.so` arm64-v8a. iOS: 9 hàm C ABI `mobile_*`, ví dụ Swift
  MobileBridge.
- `zig build test` xanh, demo host chạy đúng vòng đời + 6 event,
  `.so` kiểm chứng là ELF aarch64.
