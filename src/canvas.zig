// canvas.zig — Danh sách lệnh vẽ + render ra buffer pixel trên host.
//
// UI tree (ui.zig) chỉ định nghĩa UI; canvas là bước giữa để native
// vẽ: Zig biến cây UI thành danh sách lệnh (rect, text, image),
// native đọc danh sách này (JSON, xem toJson) rồi vẽ bằng Canvas
// (Android) hoặc Core Graphics (iOS).
//
// TRUNG THỰC: không có font rendering thật trong này. Lệnh text khi
// render ra PPM chỉ vẽ thành một vạch placeholder (không phải chữ
// thật) — để test layout/pixel, không phải để đọc chữ. Native vẽ
// text bằng font thật của hệ thống.
//
// renderPpm xuất ảnh PPM (P6, RGB 8-bit) để test trên host: mở bằng
// GIMP / trình xem ảnh bất kỳ, hoặc đọc header bằng tay.
const std = @import("std");
const errors = @import("errors.zig");
const json = @import("json.zig");
const ui = @import("ui.zig");

pub const MobileError = errors.MobileError;
pub const Color = ui.Color;
pub const Frame = ui.Frame;
pub const UiTree = ui.UiTree;

pub const DrawCmd = union(enum) {
    rect: struct { frame: Frame, color: Color, radius: f32 },
    text: struct { frame: Frame, text: []const u8, color: Color, font_size: f32 },
    image: struct { frame: Frame, path: []const u8 },
};

pub const Canvas = struct {
    alloc: std.mem.Allocator,
    cmds: std.ArrayList(DrawCmd),

    pub fn init(alloc: std.mem.Allocator) Canvas {
        return .{ .alloc = alloc, .cmds = std.ArrayList(DrawCmd).empty };
    }

    pub fn deinit(self: *Canvas) void {
        self.cmds.deinit(self.alloc);
    }

    pub fn count(self: *const Canvas) usize {
        return self.cmds.items.len;
    }

    pub fn clear(self: *Canvas) void {
        self.cmds.clearRetainingCapacity();
    }

    pub fn addRect(self: *Canvas, frame: Frame, color: Color, radius: f32) MobileError!void {
        self.cmds.append(self.alloc, .{ .rect = .{ .frame = frame, .color = color, .radius = radius } }) catch return error.OutOfMemory;
    }

    pub fn addText(self: *Canvas, frame: Frame, text: []const u8, color: Color, font_size: f32) MobileError!void {
        self.cmds.append(self.alloc, .{ .text = .{ .frame = frame, .text = text, .color = color, .font_size = font_size } }) catch return error.OutOfMemory;
    }

    pub fn addImage(self: *Canvas, frame: Frame, path: []const u8) MobileError!void {
        self.cmds.append(self.alloc, .{ .image = .{ .frame = frame, .path = path } }) catch return error.OutOfMemory;
    }
};

/// Biến cây UI đã layout thành danh sách lệnh vẽ (theo thứ tự duyệt
/// sâu): nền của node nào có background thì vẽ rect trước, text/
/// button vẽ lệnh text, image vẽ rect placeholder xám + lệnh image.
pub fn fromUiTree(alloc: std.mem.Allocator, tree: *const UiTree) MobileError!Canvas {
    var canvas = Canvas.init(alloc);
    errdefer canvas.deinit();
    try emitNode(&canvas, tree.root);
    return canvas;
}

fn emitNode(canvas: *Canvas, node: *ui.Node) MobileError!void {
    if (node.props.background) |bg| {
        const radius: f32 = if (node.kind == .button) 8 else 0;
        try canvas.addRect(node.frame, bg, radius);
    }
    switch (node.kind) {
        .text, .button => {
            try canvas.addText(node.frame, node.text, node.props.text_color, node.props.font_size);
        },
        .image => {
            // Placeholder xám sau ảnh (ảnh thật do native tải + vẽ).
            try canvas.addRect(node.frame, Color.light_gray, 0);
            try canvas.addImage(node.frame, node.image_path);
        },
        else => {},
    }
    for (node.children.items) |child| {
        try emitNode(canvas, child);
    }
}

/// Xuất danh sách lệnh vẽ thành JSON cho native đọc.
pub fn toJson(alloc: std.mem.Allocator, canvas: *const Canvas) MobileError![]u8 {
    const JsonCmd = struct {
        kind: []const u8,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]u8 = .{ 0, 0, 0, 255 },
        radius: f32 = 0,
        text: []const u8 = "",
        font_size: f32 = 0,
        path: []const u8 = "",
    };
    var cmds: std.ArrayList(JsonCmd) = .empty;
    defer cmds.deinit(alloc);
    for (canvas.cmds.items) |cmd| {
        switch (cmd) {
            .rect => |r| try cmds.append(alloc, .{
                .kind = "rect",
                .x = r.frame.x,
                .y = r.frame.y,
                .w = r.frame.w,
                .h = r.frame.h,
                .color = .{ r.color.r, r.color.g, r.color.b, r.color.a },
                .radius = r.radius,
            }),
            .text => |t| try cmds.append(alloc, .{
                .kind = "text",
                .x = t.frame.x,
                .y = t.frame.y,
                .w = t.frame.w,
                .h = t.frame.h,
                .color = .{ t.color.r, t.color.g, t.color.b, t.color.a },
                .text = t.text,
                .font_size = t.font_size,
            }),
            .image => |im| try cmds.append(alloc, .{
                .kind = "image",
                .x = im.frame.x,
                .y = im.frame.y,
                .w = im.frame.w,
                .h = im.frame.h,
                .path = im.path,
            }),
        }
    }
    return json.stringify(alloc, cmds.items);
}

/// Render canvas ra ảnh PPM (P6) kích thước width x height. Nền
/// trắng; rect tô màu; text vẽ thành vạch placeholder (KHÔNG phải
/// chữ thật — xem đầu file); image vẽ thành khung xám có viền.
/// Người gọi sở hữu mảng byte trả về.
pub fn renderPpm(alloc: std.mem.Allocator, canvas: *const Canvas, width: u32, height: u32) MobileError![]u8 {
    if (width == 0 or height == 0 or width > 4096 or height > 4096) return error.InvalidPath;
    const header = std.fmt.allocPrint(alloc, "P6\n{d} {d}\n255\n", .{ width, height }) catch return error.OutOfMemory;
    defer alloc.free(header);
    const pixels_len = @as(usize, width) * @as(usize, height) * 3;
    var out = try alloc.alloc(u8, header.len + pixels_len);
    errdefer alloc.free(out);
    @memcpy(out[0..header.len], header);
    const px = out[header.len..];
    // Nền trắng.
    @memset(px, 255);
    for (canvas.cmds.items) |cmd| {
        switch (cmd) {
            .rect => |r| fillRect(px, width, height, r.frame, r.color, r.radius),
            .text => |t| {
                // Vạch placeholder cho text: cao font_size/5, rộng theo
                // ước lượng text, đặt giữa khung theo chiều dọc.
                const bar_h = @max(2, t.font_size / 5);
                const bar_w = @min(t.frame.w, @as(f32, @floatFromInt(t.text.len)) * t.font_size * 0.6);
                const bar = Frame{
                    .x = t.frame.x,
                    .y = t.frame.y + (t.frame.h - bar_h) / 2,
                    .w = bar_w,
                    .h = bar_h,
                };
                fillRect(px, width, height, bar, t.color, 0);
            },
            .image => |im| {
                fillRect(px, width, height, im.frame, Color.light_gray, 0);
                // Viền đậm 1px quanh ảnh placeholder.
                const border = Color.gray;
                const top = Frame{ .x = im.frame.x, .y = im.frame.y, .w = im.frame.w, .h = 1 };
                const bottom = Frame{ .x = im.frame.x, .y = im.frame.y + im.frame.h - 1, .w = im.frame.w, .h = 1 };
                const left = Frame{ .x = im.frame.x, .y = im.frame.y, .w = 1, .h = im.frame.h };
                const right = Frame{ .x = im.frame.x + im.frame.w - 1, .y = im.frame.y, .w = 1, .h = im.frame.h };
                fillRect(px, width, height, top, border, 0);
                fillRect(px, width, height, bottom, border, 0);
                fillRect(px, width, height, left, border, 0);
                fillRect(px, width, height, right, border, 0);
            },
        }
    }
    return out;
}

fn setPixel(px: []u8, width: u32, height: u32, x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0) return;
    if (x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return;
    const idx = (@as(usize, @intCast(y)) * @as(usize, width) + @as(usize, @intCast(x))) * 3;
    px[idx] = color.r;
    px[idx + 1] = color.g;
    px[idx + 2] = color.b;
}

fn fillRect(px: []u8, width: u32, height: u32, frame: Frame, color: Color, radius: f32) void {
    const x0: i32 = @intFromFloat(@floor(frame.x));
    const y0: i32 = @intFromFloat(@floor(frame.y));
    const x1: i32 = @intFromFloat(@ceil(frame.x + frame.w));
    const y1: i32 = @intFromFloat(@ceil(frame.y + frame.h));
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            if (radius > 0 and !insideRounded(x, y, frame, radius)) continue;
            setPixel(px, width, height, x, y, color);
        }
    }
}

/// Điểm (x,y) có nằm trong hình chữ nhật bo góc không. Góc bo chỉ
/// kiểm tra ở 4 ô góc, phần còn lại luôn tính là trong.
fn insideRounded(x: i32, y: i32, frame: Frame, radius: f32) bool {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const r = radius;
    // Góc trái-trên.
    if (fx < frame.x + r and fy < frame.y + r) {
        const dx = (frame.x + r) - fx - 0.5;
        const dy = (frame.y + r) - fy - 0.5;
        return dx * dx + dy * dy <= r * r;
    }
    if (fx >= frame.x + frame.w - r and fy < frame.y + r) {
        const dx = fx + 0.5 - (frame.x + frame.w - r);
        const dy = (frame.y + r) - fy - 0.5;
        return dx * dx + dy * dy <= r * r;
    }
    if (fx < frame.x + r and fy >= frame.y + frame.h - r) {
        const dx = (frame.x + r) - fx - 0.5;
        const dy = fy + 0.5 - (frame.y + frame.h - r);
        return dx * dx + dy * dy <= r * r;
    }
    if (fx >= frame.x + frame.w - r and fy >= frame.y + frame.h - r) {
        const dx = fx + 0.5 - (frame.x + frame.w - r);
        const dy = fy + 0.5 - (frame.y + frame.h - r);
        return dx * dx + dy * dy <= r * r;
    }
    return true;
}

fn pixelAt(ppm: []const u8, width: u32, x: u32, y: u32) [3]u8 {
    const header_end = std.mem.indexOf(u8, ppm, "255\n").? + 4;
    const idx = header_end + ( @as(usize, y) * @as(usize, width) + @as(usize, x)) * 3;
    return .{ ppm[idx], ppm[idx + 1], ppm[idx + 2] };
}

test "canvas from ui tree" {
    const t = std.testing;
    const alloc = t.allocator;
    var tree = try ui.demoTree(alloc);
    defer tree.deinit();
    tree.layout(360, 640);
    var canvas = try fromUiTree(alloc, &tree);
    defer canvas.deinit();
    // Demo tree: 2 nút có nền -> 2 rect; title + 2 nút -> 3 text;
    // ảnh -> 1 rect placeholder + 1 image. Tổng 7 lệnh.
    try t.expectEqual(@as(usize, 7), canvas.count());
    var rects: usize = 0;
    var texts: usize = 0;
    var images: usize = 0;
    for (canvas.cmds.items) |cmd| {
        switch (cmd) {
            .rect => rects += 1,
            .text => texts += 1,
            .image => images += 1,
        }
    }
    try t.expectEqual(@as(usize, 3), rects);
    try t.expectEqual(@as(usize, 3), texts);
    try t.expectEqual(@as(usize, 1), images);
}

test "canvas render ppm pixels" {
    const t = std.testing;
    const alloc = t.allocator;
    var canvas = Canvas.init(alloc);
    defer canvas.deinit();
    try canvas.addRect(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, Color.rgb(255, 0, 0), 0);
    const ppm = try renderPpm(alloc, &canvas, 100, 100);
    defer alloc.free(ppm);
    try t.expect(std.mem.startsWith(u8, ppm, "P6\n100 100\n255\n"));
    const header_len = std.mem.indexOf(u8, ppm, "255\n").? + 4;
    try t.expectEqual(header_len + 100 * 100 * 3, ppm.len);
    // Điểm trong rect thì đỏ, điểm ngoài thì trắng.
    try t.expectEqual([3]u8{ 255, 0, 0 }, pixelAt(ppm, 100, 15, 15));
    try t.expectEqual([3]u8{ 255, 255, 255 }, pixelAt(ppm, 100, 0, 0));
    try t.expectEqual([3]u8{ 255, 255, 255 }, pixelAt(ppm, 100, 99, 99));

    // Góc bo: góc của rect bo thì vẫn trắng.
    var canvas2 = Canvas.init(alloc);
    defer canvas2.deinit();
    try canvas2.addRect(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, Color.rgb(0, 0, 255), 8);
    const ppm2 = try renderPpm(alloc, &canvas2, 100, 100);
    defer alloc.free(ppm2);
    try t.expectEqual([3]u8{ 255, 255, 255 }, pixelAt(ppm2, 100, 10, 10));
    try t.expectEqual([3]u8{ 0, 0, 255 }, pixelAt(ppm2, 100, 20, 20));

    try t.expectError(error.InvalidPath, renderPpm(alloc, &canvas, 0, 100));
}

test "canvas to json" {
    const t = std.testing;
    const alloc = t.allocator;
    var canvas = Canvas.init(alloc);
    defer canvas.deinit();
    try canvas.addRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, Color.rgb(1, 2, 3), 0);
    try canvas.addText(.{ .x = 0, .y = 20, .w = 50, .h = 16 }, "Hi", Color.black, 16);
    const text = try toJson(alloc, &canvas);
    defer alloc.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"kind\":\"rect\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"kind\":\"text\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"text\":\"Hi\"") != null);
}
