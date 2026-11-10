# Ví dụ Android — zig-mobile

App Android mẫu dùng `libmobile.so` (build từ Zig) làm ruột, Kotlin làm vỏ.

## Build file .so

```sh
cd ~/workspace/zig-mobile
~/workspace/tools/zig-x86_64-linux-0.17.1/zig build android
# ra zig-out/lib/android/arm64-v8a/libmobile.so (aarch64-linux-android)
```

Không cần Android NDK để build file `.so` — Zig tự lo phần biên dịch
chéo. NDK chỉ cần khi build cả APK bằng Gradle.

## Đưa .so vào project Android mẫu

Thư mục `examples/android/` đã có sẵn khung project Gradle:

```
examples/android/
  build.gradle          # plugin Android + Kotlin (gốc)
  settings.gradle       # include ":app"
  gradle.properties
  app/build.gradle      # applicationId com.zigmobile.app, minSdk 24
  MainActivity.kt       # copy vào app/src/main/java/com/zigmobile/app/
  AndroidManifest.xml   # copy vào app/src/main/
```

Các bước:

1. Copy cả thư mục `examples/android/` ra một chỗ riêng (đừng build
   ngay trong repo zig-mobile — Gradle sẽ sinh nhiều file).
2. Copy `zig-out/lib/android/arm64-v8a/libmobile.so` vào
   `app/src/main/jniLibs/arm64-v8a/libmobile.so`.
3. Copy `MainActivity.kt` vào `app/src/main/java/com/zigmobile/app/`.
4. Copy `AndroidManifest.xml` vào `app/src/main/`.
5. Mở bằng Android Studio (hoặc `./gradlew assembleDebug` nếu đã có
   wrapper — thư mục này không kèm wrapper, chạy `gradle wrapper`
   hoặc mở bằng Android Studio để nó tự sinh).

> Chưa kiểm chứng: máy này không có Android SDK/Gradle nên chưa
> từng build APK từ khung này, chưa từng chạy `MainActivity.kt`
> trên máy thật. File Gradle viết theo AGP 8.5.2 / Kotlin 2.0.20 /
> compileSdk 34, đúng với project RN cùng thời; nếu Android Studio
> báo phiên bản plugin cũ thì nâng theo gợi ý của nó.

## Cách nó chạy

- `MainActivity.onCreate` gọi `MobileBridge.mobileInit(filesDir, cacheDir)`
  rồi `mobileOnCreate()`. Các hàm `onStart/onResume/...` gọi tiếp các
  hàm JNI tương ứng, Zig tự kiểm tra chuyển trạng thái có hợp lệ không.
- Khi cần báo sự kiện về Zig (ví dụ bấm back), gọi
  `mobilePostEvent(4)` hoặc `mobilePostEventWithPayload(1, "hello")`.
- Zig không gọi ngược sang Kotlin. Muốn biết Zig có event gì thì poll:
  `mobilePollEventCode()` rồi `mobilePollEventPayload()` (xem hàm
  `drainEvents()` trong `MainActivity.kt`).

## Module mới ở v0.2.0 (xem MainActivity.kt)

- Quyền: sau khi hộp thoại xin quyền trả kết quả thì gọi
  `mobilePermissionMarkResult(perm, state)`; Zig giữ trạng thái và
  đẩy event `permission_result` ("camera:granted").
- Mạng: `ConnectivityManager` bên Kotlin báo trạng thái qua
  `mobileNetworkSetConnectivity(code)`; kiểm tra TCP thì gọi
  `mobileNetworkReachable(host, port, timeoutMs)`.
- Cài đặt: `mobileSettingsSetString/Int/Bool`, `mobileSettingsGet*`,
  `mobileSettingsSave()` (ghi `settings.txt`) / `mobileSettingsLoad()`.
- File: `mobileFileWriteText/ReadText/Delete/Exists` trong files_dir.
- Task nền: `mobileBackgroundAddTask(id, kind, intervalMs, maxRuns)`,
  tới lịch thì `mobileBackgroundPollDue(nowMs)` lấy id task ra chạy
  việc thật (WorkManager/AlarmManager mới là bên gọi đúng lịch).

## Đổi package

Tên hàm JNI gắn với package + class (`Java_com_zigmobile_app_...`).
Đổi package thì sửa tên hàm trong `src/android.zig` cho khớp, rồi
build lại `.so`.
