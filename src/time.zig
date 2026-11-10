// time.zig — Thời gian: mốc mili-giây, đo khoảng cách, format.
//
// Zig 0.17.1 không còn std.time.milliTimestamp / Instant nữa; thời
// gian lấy qua std.Io (Clock.real = đồng hồ treo tường, Clock.awake
// = monotonic, không quay ngược). Module này dùng std.Io.Threaded
// bản single-threaded giống files.zig nên chạy được cả trên bản
// Android không link libc.
//
// Hai loại mốc:
//   - nowMs(): giờ tường, mili-giây từ Unix epoch — dùng để hiển thị
//     giờ, hẹn giờ theo giờ hệ thống. Có thể nhảy nếu người dùng
//     đổi giờ máy.
//   - monotonicMs(): mili-giây từ một mốc không xác định, chỉ tăng
//     không giảm — dùng để đo khoảng cách, hẹn task nền, timeout.
//     Đừng so sánh monotonicMs của 2 lần chạy app khác nhau.
const std = @import("std");

var g_threaded: std.Io.Threaded = .init_single_threaded;

fn io() std.Io {
    return g_threaded.io();
}

/// Mili-giây từ Unix epoch (đồng hồ tường).
pub fn nowMs() i64 {
    return std.Io.Clock.now(.real, io()).toMilliseconds();
}

/// Mili-giây monotonic (chỉ tăng, không quay ngược).
pub fn monotonicMs() i64 {
    return std.Io.Clock.now(.awake, io()).toMilliseconds();
}

/// Khoảng cách giữa 2 mốc cùng loại (end - start). Âm nếu end < start.
pub fn diffMs(start_ms: i64, end_ms: i64) i64 {
    return end_ms - start_ms;
}

/// Đồng hồ bấm giờ: chụp mốc monotonic lúc bắt đầu, hỏi sau bao lâu.
pub const Stopwatch = struct {
    start_ms: i64,

    pub fn start() Stopwatch {
        return .{ .start_ms = monotonicMs() };
    }

    pub fn elapsedMs(self: *const Stopwatch) i64 {
        const d = diffMs(self.start_ms, monotonicMs());
        return if (d < 0) 0 else d;
    }

    pub fn reset(self: *Stopwatch) void {
        self.start_ms = monotonicMs();
    }
};

/// Format khoảng thời gian mili-giây ra dạng đọc được:
///
///   0ms, 999ms, 1s, 1.5s, 1m05s, 1h02m03s, 2d03h04m
///
/// Giây có phần thập phân 1 chữ số khi < 60s (1.5s); từ 1 phút trở
/// lên thì chỉ còn phút/giây nguyên (1m05s). Âm thì về "0ms".
pub fn formatDuration(ms: i64, buf: []u8) []u8 {
    var n: usize = 0;
    if (ms <= 0) return buf[0..writeStr(buf, n, "0ms")];
    if (ms < 1000) {
        n = writeNum(buf, n, @intCast(ms));
        return buf[0..writeStr(buf, n, "ms")];
    }
    if (ms < 60_000) {
        n = writeNum(buf, n, @intCast(@divTrunc(ms, 1000)));
        n = writeStr(buf, n, ".");
        n = writeNum(buf, n, @intCast(@divTrunc(@mod(ms, 1000), 100)));
        return buf[0..writeStr(buf, n, "s")];
    }
    const total_s = @divTrunc(ms, 1000);
    const s = @mod(total_s, 60);
    const total_m = @divTrunc(total_s, 60);
    const m = @mod(total_m, 60);
    const total_h = @divTrunc(total_m, 60);
    const h = @mod(total_h, 24);
    const d = @divTrunc(total_h, 24);
    if (d > 0) {
        n = writeNum(buf, n, @intCast(d));
        n = writeStr(buf, n, "d");
        n = writePad2(buf, n, @intCast(h));
        n = writeStr(buf, n, "h");
        n = writePad2(buf, n, @intCast(m));
        return buf[0..writeStr(buf, n, "m")];
    }
    if (h > 0) {
        n = writeNum(buf, n, @intCast(h));
        n = writeStr(buf, n, "h");
        n = writePad2(buf, n, @intCast(m));
        n = writeStr(buf, n, "m");
        n = writePad2(buf, n, @intCast(s));
        return buf[0..writeStr(buf, n, "s")];
    }
    n = writeNum(buf, n, @intCast(m));
    n = writeStr(buf, n, "m");
    n = writePad2(buf, n, @intCast(s));
    return buf[0..writeStr(buf, n, "s")];
}

/// Ghi số 0..99 thành 2 chữ số ("05"), dùng trong formatDuration.
fn writePad2(buf: []u8, n: usize, v: u64) usize {
    var m = n;
    if (v < 10 and m < buf.len) {
        buf[m] = '0';
        m += 1;
    }
    return writeNum(buf, m, v);
}

fn writeNum(buf: []u8, n: usize, v: u64) usize {
    const s = std.fmt.bufPrint(buf[n..], "{d}", .{v}) catch return n;
    return n + s.len;
}

fn writeStr(buf: []u8, n: usize, s: []const u8) usize {
    const end = @min(buf.len, n + s.len);
    @memcpy(buf[n..end], s[0 .. end - n]);
    return end;
}

test "time format duration" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("0ms", formatDuration(0, &buf));
    try t.expectEqualStrings("0ms", formatDuration(-5, &buf));
    try t.expectEqualStrings("1ms", formatDuration(1, &buf));
    try t.expectEqualStrings("999ms", formatDuration(999, &buf));
    try t.expectEqualStrings("1.0s", formatDuration(1000, &buf));
    try t.expectEqualStrings("1.5s", formatDuration(1500, &buf));
    try t.expectEqualStrings("59.9s", formatDuration(59999, &buf));
    try t.expectEqualStrings("1m00s", formatDuration(60_000, &buf));
    try t.expectEqualStrings("1m05s", formatDuration(65_000, &buf));
    try t.expectEqualStrings("1h02m03s", formatDuration(3_723_000, &buf));
    try t.expectEqualStrings("2d03h04m", formatDuration(183_840_000, &buf));
}

test "time diff and stopwatch" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 500), diffMs(1000, 1500));
    try t.expectEqual(@as(i64, -200), diffMs(1500, 1300));

    // Giờ tường phải dương và hợp lý (sau 2020-01-01).
    try t.expect(nowMs() > 1_577_836_800_000);
    // Monotonic không âm, gọi 2 lần không giảm.
    const a = monotonicMs();
    const b = monotonicMs();
    try t.expect(a >= 0);
    try t.expect(b >= a);

    var sw = Stopwatch.start();
    try t.expect(sw.elapsedMs() >= 0);
    sw.reset();
    try t.expect(sw.elapsedMs() >= 0);
}
