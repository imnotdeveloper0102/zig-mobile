import Foundation
import UIKit // Cần cho ví dụ render UI v0.3.0 (UIStackView/UILabel/UIButton).

/// Cầu Swift sang libmobile.a (viết bằng Zig) qua C ABI.
/// Cần bridging header `zig-mobile-Bridging-Header.h` (xem cùng thư mục)
/// và link `libmobile.a` trong Xcode.
///
/// Mã trạng thái: 0 unknown, 1 created, 2 started, 3 resumed, 4 paused,
/// 5 stopped, 6 destroyed. -1 = chưa init.
/// Mã event: 0 lifecycle, 1 custom, 2 network_changed, 3 low_memory,
/// 4 back_pressed, 5 permission_result, 6 deep_link.
final class MobileBridge {
    static let shared = MobileBridge()
    private init() {}

    /// Gọi một lần lúc app mở (AppDelegate / SwiftUI App.init).
    /// Trả true nếu init Zig thành công.
    @discardableResult
    func start() -> Bool {
        let fm = FileManager.default
        guard
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
            let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return false }

        mobile_set_log_callback(zigMobileLogCallback)
        let rc = mobile_init(docs.path, cache.path)
        if rc != 0 {
            print("[zig-mobile] mobile_init failed rc=\(rc)")
            return false
        }
        _ = mobile_lifecycle(1) // created
        _ = mobile_lifecycle(2) // started
        _ = mobile_lifecycle(3) // resumed
        return true
    }

    func pause() {
        _ = mobile_lifecycle(4) // paused
    }

    func resume() {
        // paused -> resumed, hoặc stopped -> started -> resumed
        if mobile_state() == 5 {
            _ = mobile_lifecycle(2)
        }
        _ = mobile_lifecycle(3)
    }

    func stop() {
        _ = mobile_lifecycle(5) // stopped
    }

    func shutdown() {
        if mobile_state() == 5 {
            _ = mobile_lifecycle(6) // destroyed
        }
        mobile_shutdown()
    }

    /// Post event về Zig. Trả 0 nếu ok, số âm nếu lỗi.
    @discardableResult
    func postEvent(code: Int32, payload: String = "") -> Int32 {
        return payload.withCString { ptr in
            mobile_on_event(code, UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), payload.utf8.count)
        }
    }

    /// Poll hết event Zig đang giữ.
    func pollEvents() -> [(code: Int32, payload: String)] {
        var out: [(Int32, String)] = []
        var code: Int32 = -1
        var buf = [UInt8](repeating: 0, count: 1024)
        var written = 0
        while true {
            let r = mobile_poll_event(&code, &buf, buf.count, &written)
            if r == 0 { break } // trống
            if r < 0 { break } // buffer quá nhỏ: event đó bị bỏ, tăng buf rồi poll lại
            let text = String(bytes: buf[0..<written], encoding: .utf8) ?? ""
            out.append((code, text))
        }
        return out
    }

    var state: Int32 { mobile_state() }

    var version: String { String(cString: mobile_version()) }

    // MARK: - v0.2.0: quyền, mạng, thiết bị, cài đặt, file, task nền

    /// Mã quyền: 0 camera, 1 microphone, 2 location, 3 storage,
    /// 4 notifications. Trả trạng thái: 0 chưa xin, 1 đã cấp,
    /// 2 bị từ chối, 3 từ chối vĩnh viễn, -1 mã sai.
    func permissionState(_ perm: Int32) -> Int32 {
        mobile_permission_state(perm)
    }

    /// Báo kết quả xin quyền về Zig (hộp thoại là việc của iOS).
    /// Trả 0 nếu ok, số âm nếu lỗi. Zig đẩy event permission_result.
    @discardableResult
    func permissionMarkResult(perm: Int32, state: Int32) -> Int32 {
        mobile_permission_mark_result(perm, state)
    }

    /// Báo trạng thái mạng từ NWPathMonitor: 0 offline, 1 wifi,
    /// 2 cellular, 3 unknown. Zig đẩy event network_changed.
    @discardableResult
    func networkSetConnectivity(_ code: Int32) -> Int32 {
        mobile_network_set_connectivity(code)
    }

    /// Kiểm tra TCP tới host:port. Trả 1 = tới được, 0 = không,
    /// -1 = tham số sai. Chỉ IPv4 dạng "8.8.8.8", chưa phân giải tên.
    func networkReachable(host: String, port: Int32, timeoutMs: Int32) -> Int32 {
        mobile_network_reachable(host, port, timeoutMs)
    }

    /// Đặt thông tin thiết bị (UIDevice / Bundle bên Swift đưa sang).
    @discardableResult
    func deviceSetInfo(osVersion: String, appVersion: String, locale: String, model: String) -> Int32 {
        mobile_device_set_info(osVersion, appVersion, locale, model)
    }

    // MARK: Cài đặt (lưu ở files_dir/settings.txt)

    @discardableResult
    func settingsSetString(key: String, value: String) -> Int32 {
        mobile_settings_set_string(key, value)
    }

    @discardableResult
    func settingsSetInt(key: String, value: Int64) -> Int32 {
        mobile_settings_set_int(key, value)
    }

    @discardableResult
    func settingsSetBool(key: String, value: Bool) -> Int32 {
        mobile_settings_set_bool(key, value ? 1 : 0)
    }

    func settingsGetString(key: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 1024)
        var written = 0
        let r = mobile_settings_get_string(key, &buf, buf.count, &written)
        guard r == 1 else { return nil }
        return String(bytes: buf[0..<written], encoding: .utf8)
    }

    func settingsGetInt(key: String, defaultValue: Int64 = 0) -> Int64 {
        mobile_settings_get_int(key, defaultValue)
    }

    func settingsGetBool(key: String, defaultValue: Bool = false) -> Bool {
        mobile_settings_get_bool(key, defaultValue ? 1 : 0) != 0
    }

    @discardableResult
    func settingsSave() -> Int32 { mobile_settings_save() }

    @discardableResult
    func settingsLoad() -> Int32 { mobile_settings_load() }

    // MARK: File trong files_dir

    @discardableResult
    func fileWriteText(relative: String, text: String, append: Bool = false) -> Int32 {
        mobile_file_write_text(relative, text, append ? 1 : 0)
    }

    func fileReadText(relative: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 1024 * 1024)
        var written = 0
        let r = mobile_file_read_text(relative, &buf, buf.count, &written)
        guard r == 1 else { return nil }
        return String(bytes: buf[0..<written], encoding: .utf8)
    }

    @discardableResult
    func fileDelete(relative: String) -> Int32 { mobile_file_delete(relative) }

    func fileExists(relative: String) -> Bool { mobile_file_exists(relative) == 1 }

    // MARK: Task nền (BGTaskScheduler bên iOS mới là bên gọi pollDue)

    /// kind: 0 one-shot, 1 repeating. maxRuns <= 0 = lặp vô hạn.
    @discardableResult
    func backgroundAddTask(id: String, kind: Int32, intervalMs: Int64, maxRuns: Int32) -> Int32 {
        mobile_background_add_task(id, kind, intervalMs, maxRuns)
    }

    /// Lấy id task tới hạn (nowMs tính bằng mili-giây), nil nếu chưa
    /// tới lượt. Gọi lặp tới khi trả nil.
    func backgroundPollDue(nowMs: Int64) -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        var written = 0
        let r = mobile_background_poll_due(nowMs, &buf, buf.count, &written)
        guard r == 1 else { return nil }
        return String(bytes: buf[0..<written], encoding: .utf8)
    }

    @discardableResult
    func backgroundRemoveTask(id: String) -> Int32 {
        mobile_background_remove_task(id)
    }

    // MARK: - v0.3.0: thời gian, hash, HTTP, JSON, UI/canvas, event bị bỏ

    /// Giờ tường (mili-giây từ epoch), giống Date().timeIntervalSince1970 * 1000.
    var timeNowMs: Int64 { mobile_time_now_ms() }

    /// Đồng hồ monotonic (mili-giây), dùng đo khoảng cách, không bị đổi giờ hệ thống.
    var timeMonotonicMs: Int64 { mobile_time_monotonic_ms() }

    /// SHA-256 hex (64 ký tự) của chuỗi, nil nếu buffer lỗi.
    func hashSha256(_ text: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 64)
        var written = 0
        let r = text.withCString { ptr in
            mobile_hash_sha256(ptr, &buf, buf.count, &written)
        }
        guard r == 1 else { return nil }
        return String(bytes: buf[0..<written], encoding: .utf8)
    }

    /// SHA-256 hex của file trong files_dir, nil nếu file không có.
    func hashFileSha256(relative: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 64)
        var written = 0
        let r = relative.withCString { ptr in
            mobile_hash_file_sha256(ptr, &buf, buf.count, &written)
        }
        guard r == 1 else { return nil }
        return String(bytes: buf[0..<written], encoding: .utf8)
    }

    /// Status code HTTP (200, 404, ...), -1 nếu nối không được / hết giờ.
    /// Chỉ nhận IP, không phân giải tên miền, không TLS.
    func httpHeadStatus(host: String, port: Int32, path: String, timeoutMs: Int32) -> Int32 {
        mobile_http_head_status(host, port, path, timeoutMs)
    }

    func httpGetStatus(host: String, port: Int32, path: String, timeoutMs: Int32) -> Int32 {
        mobile_http_get_status(host, port, path, timeoutMs)
    }

    /// Số event đã bị bỏ vì hàng đợi đầy (hàng đợi tối đa 256).
    var droppedEvents: Int64 { mobile_dropped_events() }

    /// Encode event thành JSON {"kind":"custom","seq":0,"payload":"..."}.
    /// seq luôn là 0 qua FFI (Swift tự điền nếu cần).
    func jsonEncodeEvent(code: Int32, payload: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 4096)
        var written = 0
        let r = payload.withCString { ptr in
            mobile_json_encode_event(
                code,
                UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                payload.utf8.count, &buf, buf.count, &written
            )
        }
        guard r == 1 else { return nil }
        return String(bytes: buf[0..<written], encoding: .utf8)
    }

    /// JSON cây UI demo đã layout trong khung width x height.
    func uiDemoJson(width: Int32, height: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 16384)
        var written = 0
        let r = mobile_ui_demo_json(width, height, &buf, buf.count, &written)
        guard r == 1 else { return nil }
        return String(bytes: buf[0..<written], encoding: .utf8)
    }

    /// JSON danh sách lệnh vẽ của cây UI demo đã layout.
    func canvasDemoJson(width: Int32, height: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 16384)
        var written = 0
        let r = mobile_canvas_demo_json(width, height, &buf, buf.count, &written)
        guard r == 1 else { return nil }
        return String(bytes: buf[0..<written], encoding: .utf8)
    }

    /// Swift báo click theo id (cây UI demo): Zig kiểm tra id có phải
    /// nút bấm không rồi đẩy event "ui:click:<id>" vào hàng đợi.
    /// Trả 0 nếu ok, số âm nếu lỗi.
    @discardableResult
    func uiClick(id: String) -> Int32 { mobile_ui_click(id) }

    /// Ví dụ render v0.3.0: lấy cây UI demo từ Zig (JSON) rồi dựng
    /// thành View iOS thật (UIStackView/UILabel/UIButton).
    ///
    /// Đây chỉ là VÍ DỤ RENDER — chưa từng biên dịch/chạy thật trên
    /// máy này (không có Xcode). Zig chỉ định nghĩa cây UI + layout
    /// + sự kiện; việc vẽ lên màn hình vẫn do Swift làm. Text trong
    /// Zig chỉ là ước lượng độ rộng (không có font thật), nên app
    /// thật cần tự đo lại bằng UIFont.
    func renderDemoUi() -> UIStackView? {
        guard let json = uiDemoJson(width: 360, height: 640),
              let data = json.data(using: .utf8),
              let node = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return buildView(node) as? UIStackView
    }

    private func buildView(_ node: [String: Any]) -> UIView {
        let kind = node["kind"] as? String ?? ""
        switch kind {
        case "text":
            let label = UILabel()
            label.text = node["text"] as? String
            return label
        case "button":
            let button = UIButton(type: .system)
            button.setTitle(node["text"] as? String, for: .normal)
            button.accessibilityIdentifier = node["id"] as? String
            button.addTarget(self, action: #selector(uiButtonTapped(_:)), for: .touchUpInside)
            return button
        case "image":
            let view = UIImageView()
            // Chỉ có tên/đường dẫn từ Zig; app tự load ảnh thật.
            view.accessibilityIdentifier = node["image"] as? String
            return view
        default:
            let stack = UIStackView()
            stack.axis = (kind == "row") ? .horizontal : .vertical
            for child in (node["children"] as? [[String: Any]] ?? []) {
                stack.addArrangedSubview(buildView(child))
            }
            return stack
        }
    }

    @objc private func uiButtonTapped(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier else { return }
        // Swift báo click về Zig, Zig đẩy event "ui:click:<id>".
        _ = uiClick(id: id)
    }
}

/// Log từ Zig chảy về đây, in ra console Xcode (os_log).
/// Phải là hàm global thì Swift mới chuyển được thành con trỏ hàm C.
private func zigMobileLogCallback(level: Int32, msgPtr: UnsafePointer<UInt8>?, msgLen: Int) {
    guard let msgPtr else { return }
    let msg = String(bytes: UnsafeBufferPointer(start: msgPtr, count: msgLen), encoding: .utf8) ?? ""
    print("[zig-mobile:\(level)] \(msg)")
}
