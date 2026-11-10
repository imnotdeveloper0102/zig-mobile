# Ví dụ iOS — zig-mobile

App iOS mẫu dùng `libmobile.a` (build từ Zig) làm ruột, Swift làm vỏ.

## Build file .a

```sh
cd ~/workspace/zig-mobile
~/workspace/tools/zig-x86_64-linux-0.17.1/zig build ios
# ra zig-out/lib/ios/libmobile.a (aarch64-ios)
```

Lưu ý: bước này chỉ biên dịch + đóng gói `.a`. Để link vào app thật
và chạy trên máy thật/Simulator vẫn cần Xcode + SDK của Apple, máy
này không có nên chưa kiểm chứng được đoạn đó.

## Đưa .a vào app iOS

1. Tạo project iOS bằng Xcode (Swift, iOS 15+).
2. Kéo `zig-out/lib/ios/libmobile.a` vào project, tick vào target
   (Build Phases > Link Binary With Libraries).
3. Copy `MobileBridge.swift` và `zig-mobile-Bridging-Header.h` vào project.
4. Vào Build Settings > Objective-C Bridging Header, điền đường dẫn
   tới `zig-mobile-Bridging-Header.h`.
5. Trong `AppDelegate` hoặc `SwiftUI App.init`, gọi
   `MobileBridge.shared.start()`. Khi app vào background/foreground thì
   gọi `pause()` / `resume()` / `stop()` cho khớp vòng đời.

## Cách nó chạy

- `start()` lấy Documents + Caches từ FileManager rồi đưa sang Zig
  bằng `mobile_init`, sau đó chuyển trạng thái created → started →
  resumed.
- Log từ Zig chảy về Swift qua callback đã đăng ký trong `start()`
  (hàm global `zigMobileLogCallback` — phải là hàm global thì Swift
  mới chuyển được thành con trỏ hàm C).
- Muốn biết Zig có event gì thì poll bằng `pollEvents()`, hoặc đăng ký
  `mobile_set_event_callback` để nhận ngay.

## Giới hạn

- Chưa kiểm chứng trên iOS thật (không có Xcode trên máy này).
- `mobile_poll_event` với buffer quá nhỏ sẽ bỏ event đó — Swift nên
  dùng buffer 1024 byte trở lên, hoặc tăng buffer rồi poll lại.
- `MobileBridge.swift` dùng các hàm C mới của v0.2.0 (quyền, mạng,
  cài đặt, file, task nền — khai trong bridging header); file Swift
  này chưa từng được biên dịch bằng Xcode.

## Module mới ở v0.2.0 (xem MobileBridge.swift)

- Quyền: sau khi hộp thoại xin quyền trả kết quả thì gọi
  `permissionMarkResult(perm:state:)`; Zig giữ trạng thái và đẩy
  event `permission_result`.
- Mạng: `NWPathMonitor` bên Swift báo trạng thái qua
  `networkSetConnectivity(_:)`; kiểm tra TCP thì gọi
  `networkReachable(host:port:timeoutMs:)`.
- Cài đặt: `settingsSetString/Int/Bool`, `settingsGetString/Int/Bool`,
  `settingsSave()` / `settingsLoad()` (file `settings.txt`).
- File: `fileWriteText(fileReadText(fileDelete(fileExists(` trong
  files_dir.
- Task nền: `backgroundAddTask(id:kind:intervalMs:maxRuns:)`, tới
  lịch thì `backgroundPollDue(nowMs:)` lấy id task ra chạy việc thật
  (BGTaskScheduler bên iOS mới là bên gọi đúng lịch).
