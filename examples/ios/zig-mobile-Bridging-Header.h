// zig-mobile-Bridging-Header.h — Khai C ABI của thư viện Zig cho Swift.
// Đặt đường dẫn file này vào Build Settings > Objective-C Bridging Header.
#ifndef ZIG_MOBILE_BRIDGING_HEADER_H
#define ZIG_MOBILE_BRIDGING_HEADER_H

#include <stdint.h>
#include <stddef.h>

int32_t mobile_init(const char *files_dir, const char *cache_dir);
void mobile_shutdown(void);
int32_t mobile_lifecycle(int32_t state_code);
int32_t mobile_state(void);
int32_t mobile_on_event(int32_t event_code, const uint8_t *payload_ptr, size_t payload_len);
int32_t mobile_poll_event(int32_t *out_code, uint8_t *out_buf, size_t out_capacity, size_t *out_written);
const char *mobile_version(void);
void mobile_set_log_callback(void (*cb)(int32_t level, const uint8_t *msg_ptr, size_t msg_len));
void mobile_set_event_callback(void (*cb)(int32_t event_code, const uint8_t *payload_ptr, size_t payload_len));

// v0.2.0: quyền, mạng, thiết bị, cài đặt, file, task nền.
int32_t mobile_permission_state(int32_t perm_code);
int32_t mobile_permission_mark_result(int32_t perm_code, int32_t state_code);
int32_t mobile_network_set_connectivity(int32_t code);
int32_t mobile_network_reachable(const char *host, int32_t port, int32_t timeout_ms);
int32_t mobile_device_set_info(const char *os_version, const char *app_version, const char *locale, const char *model);
int32_t mobile_settings_set_string(const char *key, const char *value);
int32_t mobile_settings_set_int(const char *key, int64_t value);
int32_t mobile_settings_set_bool(const char *key, int32_t value);
int32_t mobile_settings_get_string(const char *key, uint8_t *out_buf, size_t out_capacity, size_t *out_written);
int64_t mobile_settings_get_int(const char *key, int64_t default_value);
int32_t mobile_settings_get_bool(const char *key, int32_t default_value);
int32_t mobile_settings_save(void);
int32_t mobile_settings_load(void);
int32_t mobile_file_write_text(const char *relative, const char *text, int32_t append);
int32_t mobile_file_read_text(const char *relative, uint8_t *out_buf, size_t out_capacity, size_t *out_written);
int32_t mobile_file_delete(const char *relative);
int32_t mobile_file_exists(const char *relative);
int32_t mobile_background_add_task(const char *id, int32_t kind, int64_t interval_ms, int32_t max_runs);
int32_t mobile_background_poll_due(int64_t now_ms, uint8_t *out_buf, size_t out_capacity, size_t *out_written);
int32_t mobile_background_remove_task(const char *id);

// v0.3.0: thời gian, hash, HTTP, JSON, UI/canvas, event bị bỏ.
// Hàm *_json trả 1 = có (copy vào out_buf), -12 = BufferTooSmall
// (out_written = số byte cần), số âm khác = mã lỗi.
int64_t mobile_time_now_ms(void);
int64_t mobile_time_monotonic_ms(void);
int32_t mobile_hash_sha256(const char *text, uint8_t *out_buf, size_t out_capacity, size_t *out_written);
int32_t mobile_hash_file_sha256(const char *relative, uint8_t *out_buf, size_t out_capacity, size_t *out_written);
int32_t mobile_http_head_status(const char *host, int32_t port, const char *path, int32_t timeout_ms);
int32_t mobile_http_get_status(const char *host, int32_t port, const char *path, int32_t timeout_ms);
int64_t mobile_dropped_events(void);
int32_t mobile_json_encode_event(int32_t event_code, const uint8_t *payload_ptr, size_t payload_len, uint8_t *out_buf, size_t out_capacity, size_t *out_written);
int32_t mobile_ui_demo_json(int32_t width, int32_t height, uint8_t *out_buf, size_t out_capacity, size_t *out_written);
int32_t mobile_ui_click(const char *id);
int32_t mobile_canvas_demo_json(int32_t width, int32_t height, uint8_t *out_buf, size_t out_capacity, size_t *out_written);

#endif
