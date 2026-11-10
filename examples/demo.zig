// demo.zig — Demo host đầy đủ v0.3.0: vòng đời app + mọi module
// (quyền, mạng, thiết bị, cài đặt, file, task nền, thời gian, hash,
// HTTP local, JSON, UI tree + canvas).
// Chạy bằng: zig build && ./zig-out/bin/mobile-demo
// Demo ghi file vào /tmp/zig-mobile-demo để khỏi bẩn repo.
const std = @import("std");
const mobile = @import("mobile");
const posix = std.posix;

const DemoServer = struct {
    port: std.atomic.Value(u16),
};

fn demoServerThread(state: *DemoServer) void {
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
    const resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}";
    var off: usize = 0;
    while (off < resp.len) {
        const wrc = posix.system.sendto(cs, resp.ptr + off, resp.len - off, 0, null, 0);
        if (posix.errno(wrc) != .SUCCESS) return;
        off += @intCast(wrc);
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("zig-mobile {s} — platform: {s} ({s})\n", .{
        mobile.version_mod.version_string,
        mobile.Platform.toString(mobile.platform.current()),
        mobile.platform.archName(),
    });

    var app = try mobile.App.init(alloc, .{
        .files_dir = "/tmp/zig-mobile-demo",
        .cache_dir = "/tmp/zig-mobile-demo",
    });
    defer app.deinit();

    try app.onCreate();
    try app.onStart();
    try app.onResume();
    std.debug.print("dang chay? {any}, dang foreground? {any}\n", .{ app.isRunning(), app.isForeground() });

    // Thời gian: giờ tường + monotonic + format.
    var dur_buf: [32]u8 = undefined;
    var dur_buf2: [32]u8 = undefined;
    std.debug.print("gio hien tai (ms): {d}, monotonic (ms): {d}\n", .{ mobile.time.nowMs(), mobile.time.monotonicMs() });
    std.debug.print("1500ms viet gon: {s}, 3723000ms viet gon: {s}\n", .{
        mobile.time.formatDuration(1500, &dur_buf),
        mobile.time.formatDuration(3_723_000, &dur_buf2),
    });
    var sw = mobile.Stopwatch.start();
    std.debug.print("stopwatch vua bat dau: {d}ms\n", .{sw.elapsedMs()});

    // Quyền: native (ở đây là demo) báo camera đã được cấp.
    var perms = mobile.PermissionStore.init();
    _ = perms.markGranted(.camera, true, false);
    std.debug.print("quyen camera: {s}, can xin them? {any}\n", .{
        perms.state(.camera).toString(),
        perms.needsRequest(.microphone),
    });
    var pbuf: [64]u8 = undefined;
    try app.postEvent(.permission_result, mobile.PermissionStore.formatPayload(.camera, .granted, &pbuf));

    // Mạng: native báo wifi; check TCP tới port đóng trên localhost.
    var net = mobile.NetworkStatus.init();
    net.setConnectivity(.wifi);
    const local_ok = mobile.network.checkTcp("127.0.0.1", 1, 200);
    std.debug.print("mang: {s}, check localhost:1 toi duoc? {any}\n", .{ net.connectivity.toString(), local_ok });

    // Thiết bị: thông tin do native đưa sang (demo tự điền).
    var info = try mobile.DeviceInfo.init(alloc, .host, "x86_64", "linux", "0.3.0-demo", "vi-VN", "demo-pc");
    defer info.deinit();
    const display = try info.display(alloc);
    defer alloc.free(display);
    std.debug.print("thiet bi: {s}\n", .{display});

    // Cài đặt: set rồi lưu file, đọc lại vào Settings mới.
    var cfg = mobile.Settings.init(alloc);
    defer cfg.deinit();
    try cfg.setString("theme", "dark");
    try cfg.setInt("font_size", 16);
    try cfg.setBool("sound", true);
    try cfg.save(&app.storage, "settings.txt");
    var cfg2 = mobile.Settings.init(alloc);
    defer cfg2.deinit();
    try cfg2.load(&app.storage, "settings.txt");
    std.debug.print("cai dat: theme={s} font_size={d} sound={any}\n", .{
        cfg2.getString("theme").?,
        cfg2.getInt("font_size").?,
        cfg2.getBool("sound").?,
    });

    // JSON: cài đặt -> JSON và ngược lại.
    const cfg_json = try mobile.json.settingsToJson(alloc, &cfg2);
    defer alloc.free(cfg_json);
    std.debug.print("cai dat dang JSON: {s}\n", .{cfg_json});

    // File: ghi rồi đọc lại, kiểm tra hash.
    try mobile.files.writeText(&app.storage, alloc, "notes/hello.txt", "chao zig-mobile", false, false);
    const text = try mobile.files.readText(&app.storage, alloc, "notes/hello.txt", mobile.files.default_max_read_bytes, false);
    defer alloc.free(text);
    std.debug.print("file notes/hello.txt: {s}\n", .{text});
    const file_hash = try mobile.hash.sha256File(&app.storage, alloc, "notes/hello.txt", mobile.files.default_max_read_bytes, false);
    defer alloc.free(file_hash);
    std.debug.print("sha256 notes/hello.txt: {s} (verify: {any})\n", .{
        file_hash,
        mobile.hash.verifyFile(&app.storage, alloc, "notes/hello.txt", file_hash),
    });
    var hex: [64]u8 = undefined;
    mobile.hash.sha256Hex("abc", &hex);
    std.debug.print("sha256(\"abc\") = {s}\n", .{&hex});

    // HTTP: server local trên thread riêng, GET /health về.
    var server = DemoServer{ .port = .init(0) };
    const th = try std.Thread.spawn(.{}, demoServerThread, .{&server});
    defer th.join();
    var http_port: u16 = 0;
    const deadline = mobile.time.monotonicMs() + 2000;
    while (mobile.time.monotonicMs() < deadline) {
        http_port = server.port.load(.acquire);
        if (http_port != 0) break;
        var spin: u32 = 0;
        while (spin < 10000) : (spin += 1) std.atomic.spinLoopHint();
    }
    if (http_port != 0) {
        var resp = try mobile.http.request(alloc, .get, "127.0.0.1", http_port, "/health", 2000);
        defer resp.deinit(alloc);
        std.debug.print("http GET /health: status={d} ok={any} body={s}\n", .{ resp.status, resp.isOk(), resp.body });
    } else {
        std.debug.print("http: server local khong len kip\n", .{});
    }

    // Task nền: hẹn chạy sau 1000ms, poll ở 3 mốc thời gian.
    var tasks = mobile.TaskQueue.init(alloc);
    defer tasks.deinit();
    try tasks.add("sync", .repeating, 1000, 3, 0);
    for ([_]u64{ 999, 1000, 1500 }) |now| {
        if (tasks.pollDue(now)) |id| {
            std.debug.print("task toi han luc {d}ms: {s}\n", .{ now, id });
        }
    }

    // UI: cây demo, layout 360x640, in khung từng node.
    var tree = try mobile.ui.demoTree(alloc);
    defer tree.deinit();
    tree.layout(360, 640);
    std.debug.print("--- ui demo (360x640) ---\n", .{});
    for ([_][]const u8{ "title", "btn_sync", "btn_settings", "hero" }) |id| {
        if (tree.findById(id)) |n| {
            std.debug.print("  {s} ({s}): x={d:.0} y={d:.0} w={d:.0} h={d:.0}\n", .{
                n.id, n.kind.toString(), n.frame.x, n.frame.y, n.frame.w, n.frame.h,
            });
        }
    }
    // Click nút sync: Zig đẩy event ui:click:btn_sync vào app.
    var click_buf: [64]u8 = undefined;
    if (tree.clickPayload("btn_sync", &click_buf)) |payload| {
        try app.postEvent(.custom, payload);
        std.debug.print("click btn_sync -> event: {s}\n", .{payload});
    }
    const ui_json = try tree.toJson(alloc);
    defer alloc.free(ui_json);
    std.debug.print("ui json: {s}\n", .{ui_json});

    // Canvas: từ cây UI ra lệnh vẽ, render ảnh PPM test.
    var cv = try mobile.canvas.fromUiTree(alloc, &tree);
    defer cv.deinit();
    const canvas_json = try mobile.canvas.toJson(alloc, &cv);
    defer alloc.free(canvas_json);
    std.debug.print("canvas: {d} lenh ve, json: {s}\n", .{ cv.count(), canvas_json });
    const ppm = try mobile.canvas.renderPpm(alloc, &cv, 360, 640);
    defer alloc.free(ppm);
    try mobile.files.writeText(&app.storage, alloc, "ui.ppm", ppm, false, false);
    std.debug.print("anh PPM test: ui.ppm ({d} byte)\n", .{ppm.len});

    // Event bị bỏ: nhồi đầy 1 hàng đợi riêng, đếm số bị bỏ.
    var q = mobile.EventQueue.init(alloc);
    defer q.deinit();
    var i: usize = 0;
    while (i < 257) : (i += 1) {
        q.push(.custom, "x") catch {};
    }
    std.debug.print("hang doi rieng: {d} event, bi bo {d} event (app hien tai bi bo {d})\n", .{
        q.count(), q.droppedCount(), app.droppedEvents(),
    });

    try app.postEvent(.custom, "hello-mobile");
    try app.postEvent(.network_changed, "wifi");
    try app.postEvent(.back_pressed, "");

    std.debug.print("--- event trong hang doi ---\n", .{});
    while (app.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit(alloc);
        std.debug.print("[{d}] {s}: {s}\n", .{ e.seq, e.kind.toString(), e.payload });
    }

    try app.onPause();
    try app.onStop();
    try app.onDestroy();
    std.debug.print("state cuoi: {s}\n", .{app.state.toString()});
}
