// network.zig — Trạng thái mạng + kiểm tra tới được host không.
//
// Hai phần riêng:
//   1. Connectivity: native (Android ConnectivityManager / iOS
//      NWPathMonitor) là bên biết máy đang dùng wifi hay 4G, nên
//      native báo sang bằng setConnectivity, Zig chỉ giữ trạng thái
//      và đẩy event network_changed.
//   2. checkTcp: Zig tự kiểm tra bằng TCP connect có timeout thật
//      (socket non-blocking + poll, theo đúng cách netsec làm —
//      std.Io.net của Zig 0.17.1 không đặt được timeout, gọi là panic).
//      Chỉ hỗ trợ IPv4 dạng "8.8.8.8", chưa phân giải tên miền:
//      muốn check tên miền thì native phân giải trước rồi đưa IP sang.
//
// checkTcp không bao giờ trả lỗi, chỉ trả true/false: phía native
// cần một câu trả lời gọn (tới được / không tới được), không cần
// biết chi tiết vì sao.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Connectivity = enum(u8) {
    offline = 0,
    wifi = 1,
    cellular = 2,
    unknown = 3,

    pub fn toString(self: Connectivity) []const u8 {
        return switch (self) {
            .offline => "offline",
            .wifi => "wifi",
            .cellular => "cellular",
            .unknown => "unknown",
        };
    }

    pub fn code(self: Connectivity) c_int {
        return @intFromEnum(self);
    }

    pub fn fromCode(n: c_int) ?Connectivity {
        if (n < 0 or n > 3) return null;
        return @enumFromInt(@as(u8, @intCast(n)));
    }

    pub fn fromName(name: []const u8) ?Connectivity {
        if (std.mem.eql(u8, name, "offline")) return .offline;
        if (std.mem.eql(u8, name, "wifi")) return .wifi;
        if (std.mem.eql(u8, name, "cellular")) return .cellular;
        if (std.mem.eql(u8, name, "unknown")) return .unknown;
        return null;
    }

    pub fn isOnline(self: Connectivity) bool {
        return self == .wifi or self == .cellular;
    }
};

/// Trạng thái mạng hiện tại mà native báo sang + kết quả lần check
/// TCP gần nhất. Host/port check mặc định là DNS Google 8.8.8.8:53
/// (mở TCP tới đó chỉ để biết mạng có ra ngoài được không, không
/// gửi dữ liệu gì).
pub const NetworkStatus = struct {
    connectivity: Connectivity = .unknown,
    reachable: bool = false,
    check_host: []const u8 = "8.8.8.8",
    check_port: u16 = 53,
    check_timeout_ms: i32 = 2000,

    pub fn init() NetworkStatus {
        return .{};
    }

    pub fn setConnectivity(self: *NetworkStatus, c: Connectivity) void {
        self.connectivity = c;
    }

    /// Kiểm tra lại bằng TCP tới host đã cấu hình, cập nhật reachable.
    pub fn refresh(self: *NetworkStatus) bool {
        self.reachable = checkTcp(self.check_host, self.check_port, self.check_timeout_ms);
        return self.reachable;
    }

    /// Có mạng không: native báo online VÀ check TCP vừa qua.
    /// Nếu chưa refresh lần nào thì reachable=false, nên gọi refresh()
    /// trước khi hỏi.
    pub fn isOnline(self: *const NetworkStatus) bool {
        return self.connectivity.isOnline() and self.reachable;
    }
};

/// "8.8.8.8" -> [8,8,8,8]. Chặn chuỗi sai định dạng, số >255, thiếu
/// hoặc thừa phần. Không phân giải tên miền (xem đầu file).
pub fn parseIpv4(text: []const u8) ?[4]u8 {
    var parts: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        // Chặn "01" kiểu octal gây nhầm — chỉ cho số viết bình thường.
        if (part.len > 1 and part[0] == '0') return null;
        parts[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    return parts;
}

/// TCP connect tới ip:port, chờ tối đa timeout_ms. true = nối được
/// (mạng tới được host đó), false = mọi trường hợp còn lại (timeout,
/// bị từ chối, sai IP, timeout không hợp lệ). Không gửi dữ liệu gì
/// qua kết nối, nối xong là đóng ngay.
pub fn checkTcp(ip_text: []const u8, port: u16, timeout_ms: i32) bool {
    if (timeout_ms <= 0 or timeout_ms > 30000) return false;
    if (port == 0) return false;
    const ip = parseIpv4(ip_text) orelse return false;
    const fd = openSocket() orelse return false;
    defer _ = posix.system.close(fd);

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(ip),
    };
    const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const rc = posix.system.connect(fd, @ptrCast(&addr), addr_len);
    switch (posix.errno(rc)) {
        .SUCCESS => return true,
        .INTR => {
            const rc2 = posix.system.connect(fd, @ptrCast(&addr), addr_len);
            switch (posix.errno(rc2)) {
                .SUCCESS => return true,
                .AGAIN, .INPROGRESS => {},
                else => return false,
            }
        },
        .AGAIN, .INPROGRESS => {},
        else => return false,
    }
    if (!waitWritable(fd, timeout_ms)) return false;

    // poll báo writable cả khi connect thất bại, phải đọc SO_ERROR.
    var so_error: i32 = 0;
    var optlen: posix.socklen_t = @sizeOf(i32);
    const grc = posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&so_error), &optlen);
    if (posix.errno(grc) != .SUCCESS) return false;
    return so_error == 0;
}

fn openSocket() ?posix.socket_t {
    const flags: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(posix.AF.INET, flags, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn waitWritable(fd: posix.socket_t, timeout_ms: i32) bool {
    var pfd = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};
    const n = posix.poll(&pfd, timeout_ms) catch return false;
    if (n == 0) return false; // timeout
    return true;
}

test "connectivity code" {
    const t = std.testing;
    try t.expectEqual(@as(c_int, 1), Connectivity.wifi.code());
    try t.expectEqual(Connectivity.cellular, Connectivity.fromCode(2).?);
    try t.expectEqual(@as(?Connectivity, null), Connectivity.fromCode(4));
    try t.expectEqual(Connectivity.offline, Connectivity.fromName("offline").?);
    try t.expect(Connectivity.wifi.isOnline());
    try t.expect(!Connectivity.offline.isOnline());
    try t.expect(!Connectivity.unknown.isOnline());
}

test "parse ipv4" {
    const t = std.testing;
    try t.expectEqual([4]u8{ 8, 8, 8, 8 }, parseIpv4("8.8.8.8").?);
    try t.expectEqual([4]u8{ 127, 0, 0, 1 }, parseIpv4("127.0.0.1").?);
    try t.expect(parseIpv4("") == null);
    try t.expect(parseIpv4("8.8.8") == null);
    try t.expect(parseIpv4("8.8.8.8.8") == null);
    try t.expect(parseIpv4("256.0.0.1") == null);
    try t.expect(parseIpv4("8.8.8.x") == null);
    try t.expect(parseIpv4("example.com") == null);
    try t.expect(parseIpv4("08.8.8.8") == null);
}

test "check tcp localhost" {
    const t = std.testing;
    // Mở một listener thật trên localhost rồi check tới nó.
    // Chỉ chạy trên Linux (test host): dùng syscall bind/listen/
    // getsockname trực tiếp, giống cách netsec làm.
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;
    const listener = try openTestListener();
    defer _ = posix.system.close(listener.fd);
    const port = listener.port;

    try t.expect(checkTcp("127.0.0.1", port, 1000));
    // Port 1 trên localhost hầu như chắc chắn đóng.
    try t.expect(!checkTcp("127.0.0.1", 1, 500));
    // Tham số sai thì false, không panic.
    try t.expect(!checkTcp("127.0.0.1", port, 0));
    try t.expect(!checkTcp("127.0.0.1", 0, 500));
    try t.expect(!checkTcp("not-an-ip", port, 500));

    var status = NetworkStatus.init();
    status.setConnectivity(.wifi);
    // refresh() check tới 8.8.8.8:53 — trong sandbox có thể không ra
    // ngoài được nên chỉ kiểm tra là nó trả về mà không treo.
    _ = status.refresh();
    try t.expectEqual(Connectivity.wifi, status.connectivity);
}

/// Mở socket TCP listen trên 127.0.0.1:0 (hệ thống chọn port trống),
/// trả về fd + port thật. Chỉ dùng trong test.
fn openTestListener() !struct { fd: posix.socket_t, port: u16 } {
    const flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(posix.AF.INET, flags, 0);
    if (posix.errno(rc) != .SUCCESS) return error.Unexpected;
    const fd: posix.socket_t = @intCast(rc);
    errdefer _ = posix.system.close(fd);

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (posix.errno(posix.system.bind(fd, @ptrCast(&addr), addr_len)) != .SUCCESS) {
        return error.Unexpected;
    }
    if (posix.errno(posix.system.listen(fd, 1)) != .SUCCESS) {
        return error.Unexpected;
    }
    var bound: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (posix.errno(posix.system.getsockname(fd, @ptrCast(&bound), &bound_len)) != .SUCCESS) {
        return error.Unexpected;
    }
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, bound.port) };
}
