// http.zig — Kiểm tra HTTP đơn giản bằng TCP IPv4 có timeout.
//
// Chỉ HTTP thường, KHÔNG TLS: nối TCP tới IP:port, gửi HEAD hoặc
// GET, đọc status code + header cơ bản + body. Không phân giải tên
// miền — chỉ nhận IPv4 dạng "8.8.8.8" (muốn check tên miền thì
// native phân giải trước rồi đưa IP sang, giống network.zig).
// Socket làm theo đúng cách network.zig: non-blocking + poll, vì
// std.Io.net của Zig 0.17.1 không đặt được timeout.
//
// Dùng để làm gì: app kiểm tra server của mình còn sống không,
// đọc version/health endpoint, tải file nhỏ. Không dùng để lướt web
// hay gọi API phức tạp — việc đó để native (URLSession/OkHttp) lo.
const std = @import("std");
const builtin = @import("builtin");
const errors = @import("errors.zig");
const network = @import("network.zig");
const time = @import("time.zig");

const posix = std.posix;
pub const MobileError = errors.MobileError;

pub const Method = enum {
    head,
    get,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .head => "HEAD",
            .get => "GET",
        };
    }
};

pub const max_response_bytes: usize = 64 * 1024;
pub const max_timeout_ms: i32 = 30000;

/// Response HTTP đã đọc xong. Người gọi sở hữu và phải deinit().
pub const Response = struct {
    status: u16,
    content_length: ?usize,
    content_type: []u8,
    body: []u8,

    pub fn deinit(self: *Response, alloc: std.mem.Allocator) void {
        alloc.free(self.content_type);
        alloc.free(self.body);
        self.content_type = &.{};
        self.body = &.{};
    }

    pub fn isOk(self: *const Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

/// Kết quả parse phần header, các slice mượn từ text gốc.
const ParsedHead = struct {
    status: u16,
    content_length: ?usize,
    content_type: []const u8,
    body: []const u8,
};

/// Parse response HTTP đã đọc đủ header. Lỗi định dạng -> InvalidHttp.
pub fn parseResponse(text: []const u8) MobileError!ParsedHead {
    const sep = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.InvalidHttp;
    const head = text[0..sep];
    const body = text[sep + 4 ..];

    // Dòng đầu: "HTTP/1.1 200 OK". Có thể không có header nào
    // ("HTTP/1.1 200 OK\r\n\r\nabc") thì head chính là dòng đầu.
    const first_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const first = head[0..first_end];
    if (!std.mem.startsWith(u8, first, "HTTP/")) return error.InvalidHttp;
    const sp = std.mem.indexOfScalar(u8, first, ' ') orelse return error.InvalidHttp;
    if (first.len < sp + 4) return error.InvalidHttp;
    const code_text = first[sp + 1 .. sp + 4];
    const status = std.fmt.parseInt(u16, code_text, 10) catch return error.InvalidHttp;

    var content_length: ?usize = null;
    var content_type: []const u8 = "";
    const rest = if (first_end < head.len) head[first_end + 2 ..] else "";
    var lines = std.mem.splitSequence(u8, rest, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch continue;
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            content_type = value;
        }
    }
    return .{
        .status = status,
        .content_length = content_length,
        .content_type = content_type,
        .body = body,
    };
}

/// Gửi HEAD/GET tới ip:port/path, chờ tối đa timeout_ms. Trả Response
/// đầy đủ. Lỗi: sai IP/path -> InvalidPath/InvalidHttp, nối không
/// được hoặc hết giờ -> NetworkUnavailable, response quá lớn ->
/// BufferTooSmall, response hỏng -> InvalidHttp.
pub fn request(alloc: std.mem.Allocator, method: Method, ip_text: []const u8, port: u16, path: []const u8, timeout_ms: i32) MobileError!Response {
    if (timeout_ms <= 0 or timeout_ms > max_timeout_ms) return error.NetworkUnavailable;
    if (port == 0) return error.InvalidPath;
    if (path.len == 0 or path[0] != '/') return error.InvalidHttp;
    if (network.parseIpv4(ip_text) == null) return error.InvalidPath;

    const fd = openConnection(ip_text, port, timeout_ms) orelse return error.NetworkUnavailable;
    defer _ = posix.system.close(fd);
    const deadline = time.monotonicMs() + @as(i64, timeout_ms);

    const req = std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ method.toString(), path, ip_text }) catch return error.OutOfMemory;
    defer alloc.free(req);
    if (!sendAll(fd, req, deadline)) return error.NetworkUnavailable;

    const raw = try readResponse(alloc, fd, method, deadline);
    defer alloc.free(raw);
    const parsed = try parseResponse(raw);
    if (method == .head) {
        return .{
            .status = parsed.status,
            .content_length = parsed.content_length,
            .content_type = try alloc.dupe(u8, parsed.content_type),
            .body = try alloc.dupe(u8, ""),
        };
    }
    if (parsed.content_length) |need| {
        if (parsed.body.len < need) return error.InvalidHttp;
        return .{
            .status = parsed.status,
            .content_length = need,
            .content_type = try alloc.dupe(u8, parsed.content_type),
            .body = try alloc.dupe(u8, parsed.body[0..need]),
        };
    }
    return .{
        .status = parsed.status,
        .content_length = null,
        .content_type = try alloc.dupe(u8, parsed.content_type),
        .body = try alloc.dupe(u8, parsed.body),
    };
}

/// Chỉ lấy status code, trả -1 khi mọi lỗi (cho FFI).
pub fn getStatus(ip_text: []const u8, port: u16, path: []const u8, timeout_ms: i32) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var resp = request(alloc, .get, ip_text, port, path, timeout_ms) catch return -1;
    defer resp.deinit(alloc);
    return resp.status;
}

pub fn headStatus(ip_text: []const u8, port: u16, path: []const u8, timeout_ms: i32) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var resp = request(alloc, .head, ip_text, port, path, timeout_ms) catch return -1;
    defer resp.deinit(alloc);
    return resp.status;
}

fn openConnection(ip_text: []const u8, port: u16, timeout_ms: i32) ?posix.socket_t {
    const ip = network.parseIpv4(ip_text) orelse return null;
    const flags: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(posix.AF.INET, flags, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: posix.socket_t = @intCast(rc);
    errdefer _ = posix.system.close(fd);

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(ip),
    };
    const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const crc = posix.system.connect(fd, @ptrCast(&addr), addr_len);
    switch (posix.errno(crc)) {
        .SUCCESS => return fd,
        .INTR => {
            const crc2 = posix.system.connect(fd, @ptrCast(&addr), addr_len);
            switch (posix.errno(crc2)) {
                .SUCCESS => return fd,
                .AGAIN, .INPROGRESS => {},
                else => return null,
            }
        },
        .AGAIN, .INPROGRESS => {},
        else => return null,
    }
    if (!waitFor(fd, posix.POLL.OUT, timeout_ms)) return null;
    var so_error: i32 = 0;
    var optlen: posix.socklen_t = @sizeOf(i32);
    const grc = posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&so_error), &optlen);
    if (posix.errno(grc) != .SUCCESS) return null;
    if (so_error != 0) return null;
    return fd;
}

fn remainingMs(deadline_ms: i64) i32 {
    const left = deadline_ms - time.monotonicMs();
    if (left <= 0) return 0;
    if (left > max_timeout_ms) return max_timeout_ms;
    return @intCast(left);
}

fn waitFor(fd: posix.socket_t, events: i16, timeout_ms: i32) bool {
    var pfd = [_]posix.pollfd{.{
        .fd = fd,
        .events = events,
        .revents = 0,
    }};
    const n = posix.poll(&pfd, timeout_ms) catch return false;
    if (n == 0) return false;
    return true;
}

fn waitUntil(fd: posix.socket_t, events: i16, deadline_ms: i64) bool {
    const left = remainingMs(deadline_ms);
    if (left <= 0) return false;
    return waitFor(fd, events, left);
}

fn sendAll(fd: posix.socket_t, data: []const u8, deadline_ms: i64) bool {
    var off: usize = 0;
    while (off < data.len) {
        const rc = posix.system.sendto(fd, data.ptr + off, data.len - off, 0, null, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return false;
                off += n;
            },
            .INTR => continue,
            .AGAIN => {
                if (!waitUntil(fd, posix.POLL.OUT, deadline_ms)) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn readResponse(alloc: std.mem.Allocator, fd: posix.socket_t, method: Method, deadline_ms: i64) MobileError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (buf.items.len < max_response_bytes) {
        // Đủ header + đủ body thì dừng, khỏi chờ server đóng kết nối.
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |_| {
            if (method == .head) break;
            const parsed = parseResponse(buf.items) catch null;
            if (parsed) |p| {
                if (p.content_length) |need| {
                    if (p.body.len >= need) break;
                }
            }
        }
        if (!waitUntil(fd, posix.POLL.IN, deadline_ms)) {
            // Hết giờ: có header đầy đủ + body đủ (hoặc HEAD) thì vẫn
            // dùng được, còn không thì coi như nối thất bại.
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |_| {
                if (method == .head) break;
                const parsed = parseResponse(buf.items) catch null;
                if (parsed) |p| {
                    if (p.content_length) |need| {
                        if (p.body.len >= need) break;
                    } else {
                        break;
                    }
                }
            }
            return error.NetworkUnavailable;
        }
        const n = posix.read(fd, &chunk) catch return error.NetworkUnavailable;
        if (n == 0) break; // server đóng kết nối
        const room = max_response_bytes - buf.items.len;
        const take = @min(n, room);
        buf.appendSlice(alloc, chunk[0..take]) catch return error.OutOfMemory;
        if (n > take) return error.BufferTooSmall;
    }
    if (buf.items.len >= max_response_bytes) {
        // Còn dữ liệu nữa nhưng đã chạm trần thì báo quá lớn.
        return error.BufferTooSmall;
    }
    return buf.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

test "http parse response" {
    const t = std.testing;
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";
    const p = try parseResponse(raw);
    try t.expectEqual(@as(u16, 200), p.status);
    try t.expectEqual(@as(?usize, 5), p.content_length);
    try t.expectEqualStrings("text/plain", p.content_type);
    try t.expectEqualStrings("hello", p.body);

    // Header viết hoa/thường lẫn lộn vẫn đọc được.
    const raw2 = "HTTP/1.0 404 Not Found\r\nCONTENT-LENGTH: 0\r\n\r\n";
    const p2 = try parseResponse(raw2);
    try t.expectEqual(@as(u16, 404), p2.status);
    try t.expectEqual(@as(?usize, 0), p2.content_length);

    // Không có Content-Length thì body là phần còn lại.
    const raw3 = "HTTP/1.1 200 OK\r\n\r\nabc";
    const p3 = try parseResponse(raw3);
    try t.expectEqual(@as(?usize, null), p3.content_length);
    try t.expectEqualStrings("abc", p3.body);

    // Hỏng thì lỗi, không panic.
    try t.expectError(error.InvalidHttp, parseResponse("khong-phai-http"));
    try t.expectError(error.InvalidHttp, parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nhello"));
    try t.expectError(error.InvalidHttp, parseResponse("HTTP/1.1 XX OK\r\n\r\n"));
}

test "http request local server" {
    const t = std.testing;
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;
    const alloc = t.allocator;

    // Server test: trả đúng 1 response rồi đóng, chạy trên thread riêng.
    var state = TestServer{ .port = .init(0) };
    const th = try std.Thread.spawn(.{}, testServerThread, .{&state});
    defer th.join();
    var port: u16 = 0;
    var tries: u32 = 0;
    while (tries < 500) : (tries += 1) {
        port = state.port.load(.acquire);
        if (port != 0) break;
        var spin: u32 = 0;
        while (spin < 10000) : (spin += 1) {
            std.atomic.spinLoopHint();
        }
    }
    try t.expect(port != 0);

    var resp = try request(alloc, .get, "127.0.0.1", port, "/health", 2000);
    defer resp.deinit(alloc);
    try t.expectEqual(@as(u16, 200), resp.status);
    try t.expect(resp.isOk());
    try t.expectEqualStrings("text/plain", resp.content_type);
    try t.expectEqualStrings("hello", resp.body);

    // Tham số sai thì lỗi gọn, không treo.
    try t.expectError(error.InvalidPath, request(alloc, .get, "not-an-ip", 80, "/", 1000));
    try t.expectError(error.InvalidHttp, request(alloc, .get, "127.0.0.1", 80, "khong-co-slash", 1000));
    try t.expectError(error.NetworkUnavailable, request(alloc, .get, "127.0.0.1", 1, "/", 500));
    try t.expectEqual(@as(i32, -1), getStatus("127.0.0.1", 1, "/", 500));
}

const TestServer = struct {
    port: std.atomic.Value(u16),
};

fn testServerThread(state: *TestServer) void {
    const flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(posix.AF.INET, flags, 0);
    if (posix.errno(rc) != .SUCCESS) return;
    const sfd: posix.socket_t = @intCast(rc);
    defer _ = posix.system.close(sfd);
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (posix.errno(posix.system.bind(sfd, @ptrCast(&addr), addr_len)) != .SUCCESS) return;
    if (posix.errno(posix.system.listen(sfd, 1)) != .SUCCESS) return;
    var bound: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (posix.errno(posix.system.getsockname(sfd, @ptrCast(&bound), &bound_len)) != .SUCCESS) return;
    state.port.store(std.mem.bigToNative(u16, bound.port), .release);
    const cfd = posix.system.accept(sfd, null, null);
    if (posix.errno(cfd) != .SUCCESS) return;
    const cs: posix.socket_t = @intCast(cfd);
    defer _ = posix.system.close(cs);
    var buf: [1024]u8 = undefined;
    _ = posix.read(cs, &buf) catch {};
    const resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";
    var off: usize = 0;
    while (off < resp.len) {
        const wrc = posix.system.sendto(cs, resp.ptr + off, resp.len - off, 0, null, 0);
        if (posix.errno(wrc) != .SUCCESS) return;
        off += @intCast(wrc);
    }
}
