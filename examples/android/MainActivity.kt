package com.zigmobile.app

import android.app.Activity
import android.os.Bundle
import android.os.SystemClock
import android.util.Log

/**
 * Cầu JNI sang libmobile.so (viết bằng Zig).
 *
 * Tên hàm Java_* trong src/android.zig gắn với package + class này:
 * Java_com_zigmobile_app_MobileBridge_mobileInit, ...
 * Đổi package hoặc tên class thì phải đổi tên hàm bên Zig theo.
 *
 * Mã trạng thái (xem app.zig): 0 unknown, 1 created, 2 started,
 * 3 resumed, 4 paused, 5 stopped, 6 destroyed. -1 = chưa init.
 * Mã event (xem event.zig): 0 lifecycle, 1 custom, 2 network_changed,
 * 3 low_memory, 4 back_pressed, 5 permission_result, 6 deep_link.
 * Mã quyền (permissions.zig): 0 camera, 1 microphone, 2 location,
 * 3 storage, 4 notifications. Trạng thái quyền: 0 chưa xin,
 * 1 đã cấp, 2 bị từ chối, 3 từ chối vĩnh viễn.
 * Mã mạng (network.zig): 0 offline, 1 wifi, 2 cellular, 3 unknown.
 * Mã lỗi trả về: 0 = ok, số âm xem errors.zig (ví dụ -15 quyền
 * không hợp lệ, -16 cài đặt không hợp lệ, -17 không tìm thấy file).
 */
object MobileBridge {
    init {
        System.loadLibrary("mobile")
    }

    external fun mobileInit(filesDir: String, cacheDir: String): Int
    external fun mobileOnCreate()
    external fun mobileOnStart()
    external fun mobileOnResume()
    external fun mobileOnPause()
    external fun mobileOnStop()
    external fun mobileOnDestroy()
    external fun mobilePostEvent(eventCode: Int): Int
    external fun mobilePostEventWithPayload(eventCode: Int, payload: String): Int
    external fun mobilePollEventCode(): Int
    external fun mobilePollEventPayload(): String?
    external fun mobileGetState(): Int
    external fun mobileVersion(): String?

    // v0.2.0: quyền, mạng, thiết bị, cài đặt, file, task nền.
    external fun mobilePermissionState(permCode: Int): Int
    external fun mobilePermissionMarkResult(permCode: Int, stateCode: Int): Int
    external fun mobileNetworkSetConnectivity(code: Int): Int
    external fun mobileNetworkReachable(host: String, port: Int, timeoutMs: Int): Int
    external fun mobileDeviceSetInfo(osVersion: String, appVersion: String, locale: String, model: String): Int
    external fun mobileSettingsSetString(key: String, value: String): Int
    external fun mobileSettingsSetInt(key: String, value: Long): Int
    external fun mobileSettingsSetBool(key: String, value: Boolean): Int
    external fun mobileSettingsGetString(key: String): String?
    external fun mobileSettingsGetInt(key: String, defaultValue: Long): Long
    external fun mobileSettingsGetBool(key: String, defaultValue: Boolean): Boolean
    external fun mobileSettingsSave(): Int
    external fun mobileSettingsLoad(): Int
    external fun mobileFileWriteText(relative: String, text: String, append: Boolean): Int
    external fun mobileFileReadText(relative: String): String?
    external fun mobileFileDelete(relative: String): Int
    external fun mobileFileExists(relative: String): Int
    external fun mobileBackgroundAddTask(id: String, kind: Int, intervalMs: Long, maxRuns: Int): Int
    external fun mobileBackgroundPollDue(nowMs: Long): String?
    external fun mobileBackgroundRemoveTask(id: String): Int

    // v0.3.0: thời gian, hash, HTTP, JSON, UI/canvas, event bị bỏ.
    external fun mobileTimeNowMs(): Long
    external fun mobileTimeMonotonicMs(): Long
    external fun mobileHashSha256(text: String): String?
    external fun mobileHashFileSha256(relative: String): String?
    external fun mobileHttpHeadStatus(host: String, port: Int, path: String, timeoutMs: Int): Int
    external fun mobileHttpGetStatus(host: String, port: Int, path: String, timeoutMs: Int): Int
    external fun mobileJsonEncodeEvent(eventCode: Int, payload: String): String?
    external fun mobileUiDemoJson(width: Int, height: Int): String?
    external fun mobileUiClick(id: String): Int
    external fun mobileCanvasDemoJson(width: Int, height: Int): String?
    external fun mobileDroppedEvents(): Int
}

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val rc = MobileBridge.mobileInit(filesDir.absolutePath, cacheDir.absolutePath)
        Log.i("zig-mobile", "mobileInit rc=$rc version=${MobileBridge.mobileVersion()}")
        MobileBridge.mobileOnCreate()

        // Ví dụ v0.2.0: thông tin thiết bị + tải cài đặt đã lưu.
        // Build.MODEL / Build.VERSION.RELEASE lấy từ Android thật.
        MobileBridge.mobileDeviceSetInfo(
            android.os.Build.VERSION.RELEASE,
            BuildConfig.VERSION_NAME,
            java.util.Locale.getDefault().toLanguageTag(),
            android.os.Build.MODEL,
        )
        MobileBridge.mobileSettingsLoad()

        // Ví dụ: hẹn task nền lặp mỗi 15 phút, tối đa không giới hạn.
        // WorkManager / AlarmManager bên Android mới là bên gọi
        // mobileBackgroundPollDue đúng lịch — ở đây chỉ đăng ký task.
        MobileBridge.mobileBackgroundAddTask("sync", 1, 15 * 60 * 1000L, 0)

        // Ví dụ v0.3.0: giờ, hash, HTTP, JSON, event bị bỏ.
        // HTTP chỉ nhận IP (không phân giải tên miền, không TLS).
        val nowMs = MobileBridge.mobileTimeNowMs()
        val hash = MobileBridge.mobileHashSha256("abc")
        val status = MobileBridge.mobileHttpGetStatus("127.0.0.1", 8080, "/health", 2000)
        val eventJson = MobileBridge.mobileJsonEncodeEvent(1, "hello")
        val dropped = MobileBridge.mobileDroppedEvents()
        Log.i("zig-mobile", "now=$nowMs sha256(abc)=$hash http=$status json=$eventJson dropped=$dropped")
    }

    /**
     * Ví dụ render v0.3.0: lấy cây UI demo từ Zig (JSON) rồi dựng
     * thành View Android thật (LinearLayout/TextView/Button).
     *
     * Đây chỉ là VÍ DỤ RENDER — chưa từng biên dịch/chạy thật trên
     * máy này (không có Android SDK). Zig chỉ định nghĩa cây UI +
     * layout + sự kiện; việc vẽ lên màn hình vẫn do Kotlin làm.
     * Text trong Zig chỉ là ước lượng độ rộng (không có font thật),
     * nên app thật cần tự đo lại bằng Paint/StaticLayout.
     */
    fun renderDemoUi(): android.view.View {
        val json = MobileBridge.mobileUiDemoJson(360, 640) ?: return android.widget.LinearLayout(this)
        val root = org.json.JSONObject(json)
        return buildView(root)
    }

    private fun buildView(node: org.json.JSONObject): android.view.View {
        val ctx = this
        return when (node.optString("kind")) {
            "text" -> android.widget.TextView(ctx).apply {
                text = node.optString("text")
                textSize = 16f
            }
            "button" -> android.widget.Button(ctx).apply {
                text = node.optString("text")
                val id = node.optString("id")
                setOnClickListener {
                    // Native báo click về Zig, Zig đẩy event "ui:click:<id>".
                    MobileBridge.mobileUiClick(id)
                }
            }
            "image" -> android.widget.ImageView(ctx).apply {
                // Chỉ có tên/đường dẫn từ Zig; app tự load ảnh thật.
                contentDescription = node.optString("image")
            }
            else -> android.widget.LinearLayout(ctx).apply {
                orientation = if (node.optString("kind") == "row") {
                    android.widget.LinearLayout.HORIZONTAL
                } else {
                    android.widget.LinearLayout.VERTICAL
                }
                val children = node.optJSONArray("children") ?: org.json.JSONArray()
                for (i in 0 until children.length()) {
                    addView(buildView(children.getJSONObject(i)))
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        MobileBridge.mobileOnStart()
    }

    override fun onResume() {
        super.onResume()
        MobileBridge.mobileOnResume()
        drainEvents()
        drainBackgroundTasks()
    }

    override fun onPause() {
        MobileBridge.mobileOnPause()
        super.onPause()
    }

    override fun onStop() {
        MobileBridge.mobileOnStop()
        super.onStop()
    }

    override fun onDestroy() {
        MobileBridge.mobileSettingsSave()
        MobileBridge.mobileOnDestroy()
        super.onDestroy()
    }

    override fun onBackPressed() {
        // Ví dụ post event về Zig thay vì xử lý hết bên Kotlin.
        MobileBridge.mobilePostEvent(4) // 4 = back_pressed
        super.onBackPressed()
    }

    /**
     * Ví dụ xin quyền camera: hộp thoại là việc của Android, Zig chỉ
     * giữ trạng thái. Gọi hàm này sau khi người dùng trả lời hộp thoại
     * (onRequestPermissionsResult): granted = đã cấp, permanent =
     * bị từ chối vĩnh viễn (hệ thống không hiện hộp thoại nữa).
     */
    fun onCameraPermissionResult(granted: Boolean, permanent: Boolean) {
        val state = when {
            granted -> 1
            permanent -> 3
            else -> 2
        }
        MobileBridge.mobilePermissionMarkResult(0, state) // 0 = camera
    }

    /** Poll hết event Zig đang giữ, log ra logcat. */
    private fun drainEvents() {
        while (true) {
            val code = MobileBridge.mobilePollEventCode()
            if (code < 0) break
            val payload = MobileBridge.mobilePollEventPayload()
            Log.i("zig-mobile", "event code=$code payload=$payload")
        }
    }

    /** Lấy task nền tới hạn rồi thực thi việc thật bên Kotlin. */
    private fun drainBackgroundTasks() {
        val now = SystemClock.elapsedRealtime()
        while (true) {
            val id = MobileBridge.mobileBackgroundPollDue(now) ?: break
            Log.i("zig-mobile", "task toi han: $id")
            // TODO: chạy việc thật theo id (đồng bộ, tải dữ liệu, ...).
        }
    }
}
