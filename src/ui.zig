// ui.zig — Cây UI khai báo trong Zig: định nghĩa UI + layout + sự kiện.
//
// TRUNG THỰC: Zig KHÔNG vẽ được Jetpack Compose / SwiftUI trực tiếp.
// Module này chỉ làm 3 việc trong Zig:
//   1. Định nghĩa cây UI (Text, Button, Image, Row, Column, Scroll,
//      Spacer) kèm thuộc tính — viết một lần, dùng chung Android+iOS.
//   2. Tính layout kiểu flex dọc/ngang trên host (khung x/y/w/h cho
//      từng node) — để native biết đặt View ở đâu.
//   3. Sự kiện bấm: native báo click theo id, Zig đẩy event custom
//      "ui:click:<id>" vào hàng đợi event đã có.
//
// Việc vẽ thật vẫn do Kotlin/Swift làm: đọc cây UI (JSON, xem
// toJson) rồi tạo TextView/Button/LinearLayout hoặc
// Text/Button/VStack tương ứng (ví dụ ở MainActivity.kt và
// MobileBridge.swift). Không có font rendering thật trong này:
// chiều rộng text chỉ là ước lượng (mỗi ký tự ~0.6 * font_size),
// native đo lại bằng font thật khi vẽ.
//
// Mọi node/chuỗi đều cấp phát từ ArenaAllocator của cây — deinit cây
// là trả hết, khỏi lo free từng node.
const std = @import("std");
const errors = @import("errors.zig");
const json = @import("json.zig");

pub const MobileError = errors.MobileError;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const gray: Color = .{ .r = 128, .g = 128, .b = 128 };
    pub const light_gray: Color = .{ .r = 220, .g = 220, .b = 220 };

    pub fn eql(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }
};

pub const Align = enum {
    start,
    center,
    end,

    pub fn toString(self: Align) []const u8 {
        return switch (self) {
            .start => "start",
            .center => "center",
            .end => "end",
        };
    }
};

pub const NodeKind = enum {
    text,
    button,
    image,
    row,
    column,
    scroll,
    spacer,

    pub fn toString(self: NodeKind) []const u8 {
        return switch (self) {
            .text => "text",
            .button => "button",
            .image => "image",
            .row => "row",
            .column => "column",
            .scroll => "scroll",
            .spacer => "spacer",
        };
    }
};

pub const Props = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    padding: f32 = 0,
    background: ?Color = null,
    text_color: Color = Color.black,
    font_size: f32 = 16,
    alignment: Align = .start,
};

pub const Frame = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn eql(self: Frame, other: Frame) bool {
        return self.x == other.x and self.y == other.y and self.w == other.w and self.h == other.h;
    }
};

pub const Node = struct {
    kind: NodeKind,
    id: []const u8,
    text: []const u8,
    image_path: []const u8,
    props: Props,
    children: std.ArrayList(*Node),
    frame: Frame = .{},

    pub fn isClickable(self: *const Node) bool {
        return self.kind == .button;
    }
};

/// Cây UI: root luôn là Column (màn hình xếp dọc). Mọi bộ nhớ của
/// cây nằm trong arena, deinit() trả hết một lượt.
pub const UiTree = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,

    pub fn init(backing: std.mem.Allocator) MobileError!UiTree {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const root = alloc.create(Node) catch return error.OutOfMemory;
        root.* = .{
            .kind = .column,
            .id = "root",
            .text = "",
            .image_path = "",
            .props = .{},
            .children = std.ArrayList(*Node).empty,
        };
        return .{ .arena = arena, .root = root };
    }

    pub fn deinit(self: *UiTree) void {
        self.arena.deinit();
    }

    fn arenaAlloc(self: *UiTree) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn addChild(self: *UiTree, parent: *Node, kind: NodeKind, id: []const u8, text: []const u8, props: Props) MobileError!*Node {
        const a = self.arenaAlloc();
        const node = a.create(Node) catch return error.OutOfMemory;
        node.* = .{
            .kind = kind,
            .id = try a.dupe(u8, id),
            .text = try a.dupe(u8, text),
            .image_path = "",
            .props = props,
            .children = std.ArrayList(*Node).empty,
        };
        parent.children.append(a, node) catch return error.OutOfMemory;
        return node;
    }

    pub fn addText(self: *UiTree, parent: *Node, id: []const u8, text: []const u8) MobileError!*Node {
        return self.addChild(parent, .text, id, text, .{});
    }

    pub fn addButton(self: *UiTree, parent: *Node, id: []const u8, text: []const u8) MobileError!*Node {
        return self.addChild(parent, .button, id, text, .{ .background = Color.rgb(47, 111, 94), .text_color = Color.white });
    }

    pub fn addImage(self: *UiTree, parent: *Node, id: []const u8, path: []const u8) MobileError!*Node {
        const node = try self.addChild(parent, .image, id, "", .{});
        node.image_path = try self.arenaAlloc().dupe(u8, path);
        return node;
    }

    pub fn addRow(self: *UiTree, parent: *Node, id: []const u8) MobileError!*Node {
        return self.addChild(parent, .row, id, "", .{});
    }

    pub fn addColumn(self: *UiTree, parent: *Node, id: []const u8) MobileError!*Node {
        return self.addChild(parent, .column, id, "", .{});
    }

    pub fn addScroll(self: *UiTree, parent: *Node, id: []const u8) MobileError!*Node {
        return self.addChild(parent, .scroll, id, "", .{});
    }

    pub fn addSpacer(self: *UiTree, parent: *Node, id: []const u8) MobileError!*Node {
        return self.addChild(parent, .spacer, id, "", .{});
    }

    /// Tìm node theo id (duyệt sâu). Trả null nếu không có.
    pub fn findById(self: *const UiTree, id: []const u8) ?*Node {
        return findIn(self.root, id);
    }

    /// Tính layout cho cả cây trong khung width x height. Root lấp
    /// đầy màn hình (để Spacer trong root ăn hết phần còn lại).
    pub fn layout(self: *UiTree, width: f32, height: f32) void {
        const old_w = self.root.props.width;
        const old_h = self.root.props.height;
        self.root.props.width = width;
        self.root.props.height = height;
        layoutNode(self.root, 0, 0, width, height);
        self.root.props.width = old_w;
        self.root.props.height = old_h;
    }

    /// Payload event khi native báo click theo id:
    /// "ui:click:<id>". Trả null nếu id không phải node bấm được.
    /// Người gọi post event này vào App với kind .custom.
    pub fn clickPayload(self: *const UiTree, id: []const u8, buf: []u8) ?[]u8 {
        const node = self.findById(id) orelse return null;
        if (!node.isClickable()) return null;
        return std.fmt.bufPrint(buf, "ui:click:{s}", .{id}) catch null;
    }

    /// Xuất cây UI (kèm khung đã layout) thành JSON cho native đọc.
    pub fn toJson(self: *const UiTree, alloc: std.mem.Allocator) MobileError![]u8 {
        var jn = try toJsonNode(alloc, self.root);
        defer freeJsonNode(alloc, &jn);
        return json.stringify(alloc, jn);
    }
};

fn findIn(node: *Node, id: []const u8) ?*Node {
    if (std.mem.eql(u8, node.id, id)) return node;
    for (node.children.items) |child| {
        if (findIn(child, id)) |found| return found;
    }
    return null;
}

/// Chiều rộng ước lượng của text (không có font thật): mỗi ký tự
/// rộng ~0.6 * font_size, cộng padding 2 bên.
fn measureTextWidth(text: []const u8, font_size: f32, padding: f32) f32 {
    return @as(f32, @floatFromInt(text.len)) * font_size * 0.6 + padding * 2;
}

fn measureTextHeight(font_size: f32, padding: f32) f32 {
    return font_size * 1.5 + padding * 2;
}

/// Đo kích thước tự nhiên của node (chưa có khung cha). Dùng cho
/// Column/Row để xếp con: spacer đo bằng 0, phần còn lại chia sau.
fn measure(node: *Node, avail_w: f32, avail_h: f32) Frame {
    const p = node.props;
    switch (node.kind) {
        .text => {
            return .{
                .w = p.width orelse measureTextWidth(node.text, p.font_size, p.padding),
                .h = p.height orelse measureTextHeight(p.font_size, p.padding),
            };
        },
        .button => {
            return .{
                .w = p.width orelse measureTextWidth(node.text, p.font_size, p.padding) + 16,
                .h = p.height orelse measureTextHeight(p.font_size, p.padding) + 8,
            };
        },
        .image => {
            return .{
                .w = p.width orelse 100,
                .h = p.height orelse 100,
            };
        },
        .spacer => return .{ .w = 0, .h = 0 },
        .row, .column, .scroll => {
            // Container: đo con rồi cộng padding 2 bên.
            var w: f32 = 0;
            var h: f32 = 0;
            if (node.kind == .column or node.kind == .scroll) {
                for (node.children.items) |child| {
                    const c = measure(child, avail_w - p.padding * 2, avail_h);
                    if (c.w > w) w = c.w;
                    h += c.h;
                }
            } else {
                for (node.children.items) |child| {
                    const c = measure(child, avail_w, avail_h - p.padding * 2);
                    w += c.w;
                    if (c.h > h) h = c.h;
                }
            }
            return .{
                .w = p.width orelse w + p.padding * 2,
                .h = p.height orelse h + p.padding * 2,
            };
        },
    }
}

fn layoutNode(node: *Node, x: f32, y: f32, avail_w: f32, avail_h: f32) void {
    const p = node.props;
    const m = measure(node, avail_w, avail_h);
    // Spacer không có kích thước tự nhiên: lấy đúng phần khung
    // mà cha đã chia cho nó, không đo lại thành 0.
    const w = if (node.kind == .spacer) avail_w else p.width orelse @min(m.w, avail_w);
    const h = if (node.kind == .spacer) avail_h else p.height orelse @min(m.h, avail_h);
    node.frame = .{ .x = x, .y = y, .w = w, .h = h };
    if (node.children.items.len == 0) return;

    const inner_x = x + p.padding;
    const inner_y = y + p.padding;
    const inner_w = @max(0, w - p.padding * 2);
    const inner_h = @max(0, h - p.padding * 2);
    switch (node.kind) {
        .column, .scroll => {
            // Spacer ăn phần còn lại theo chiều dọc.
            var fixed_h: f32 = 0;
            var spacers: usize = 0;
            for (node.children.items) |child| {
                if (child.kind == .spacer) {
                    spacers += 1;
                } else {
                    fixed_h += measure(child, inner_w, inner_h).h;
                }
            }
            const rest = @max(0, inner_h - fixed_h);
            const each = if (spacers > 0) rest / @as(f32, @floatFromInt(spacers)) else 0;
            var cy = inner_y;
            for (node.children.items) |child| {
                const ch = if (child.kind == .spacer) each else measure(child, inner_w, inner_h).h;
                layoutNode(child, inner_x, cy, inner_w, ch);
                cy += child.frame.h;
            }
        },
        .row => {
            var fixed_w: f32 = 0;
            var spacers: usize = 0;
            for (node.children.items) |child| {
                if (child.kind == .spacer) {
                    spacers += 1;
                } else {
                    fixed_w += measure(child, inner_w, inner_h).w;
                }
            }
            const rest = @max(0, inner_w - fixed_w);
            const each = if (spacers > 0) rest / @as(f32, @floatFromInt(spacers)) else 0;
            var cx = inner_x;
            for (node.children.items) |child| {
                const cw = if (child.kind == .spacer) each else measure(child, inner_w, inner_h).w;
                layoutNode(child, cx, inner_y, cw, inner_h);
                cx += child.frame.w;
            }
        },
        else => {},
    }
}

/// Cây demo dùng chung cho demo host + FFI: tiêu đề, 2 nút trong 1
/// hàng, 1 ảnh placeholder, 1 spacer đẩy nội dung lên trên.
pub fn demoTree(backing: std.mem.Allocator) MobileError!UiTree {
    var tree = try UiTree.init(backing);
    errdefer tree.deinit();
    const root = tree.root;
    root.props.padding = 16;
    _ = try tree.addText(root, "title", "Chao zig-mobile");
    const row = try tree.addRow(root, "actions");
    _ = try tree.addButton(row, "btn_sync", "Dong bo");
    _ = try tree.addButton(row, "btn_settings", "Cai dat");
    _ = try tree.addImage(root, "hero", "assets/hero.png");
    _ = try tree.addSpacer(root, "spacer_bottom");
    return tree;
}

// ---- JSON export (cho native đọc cây UI) ----

const JsonNode = struct {
    kind: []const u8,
    id: []const u8,
    text: []const u8,
    image: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    bg: ?[4]u8 = null,
    children: []JsonNode = &.{},
};

fn toJsonNode(alloc: std.mem.Allocator, node: *Node) MobileError!JsonNode {
    var children: std.ArrayList(JsonNode) = .empty;
    errdefer {
        for (children.items) |*c| freeJsonNode(alloc, c);
        children.deinit(alloc);
    }
    for (node.children.items) |child| {
        children.append(alloc, try toJsonNode(alloc, child)) catch return error.OutOfMemory;
    }
    const bg: ?[4]u8 = if (node.props.background) |c| .{ c.r, c.g, c.b, c.a } else null;
    return .{
        .kind = node.kind.toString(),
        .id = node.id,
        .text = node.text,
        .image = node.image_path,
        .x = node.frame.x,
        .y = node.frame.y,
        .w = node.frame.w,
        .h = node.frame.h,
        .bg = bg,
        .children = children.toOwnedSlice(alloc) catch return error.OutOfMemory,
    };
}

fn freeJsonNode(alloc: std.mem.Allocator, jn: *JsonNode) void {
    for (jn.children) |*c| freeJsonNode(alloc, c);
    alloc.free(jn.children);
    jn.children = &.{};
}

test "ui layout column" {
    const t = std.testing;
    const alloc = t.allocator;
    var tree = try UiTree.init(alloc);
    defer tree.deinit();
    tree.root.props.padding = 10;
    _ = try tree.addText(tree.root, "title", "Hello");
    _ = try tree.addButton(tree.root, "ok", "OK");
    _ = try tree.addSpacer(tree.root, "sp");
    tree.layout(360, 640);

    const title = tree.findById("title").?;
    // Text "Hello": 5 ký tự * 16 * 0.6 + padding 0 = 48 rộng, cao 24.
    try t.expectEqual(@as(f32, 10), title.frame.x);
    try t.expectEqual(@as(f32, 10), title.frame.y);
    try t.expectEqual(@as(f32, 48), title.frame.w);
    try t.expectEqual(@as(f32, 24), title.frame.h);

    const btn = tree.findById("ok").?;
    // Button: text "OK" 2 ký tự * 9.6 + 16 = 35.2 rộng, cao 24 + 8 = 32.
    try t.expectEqual(@as(f32, 10), btn.frame.x);
    try t.expectEqual(@as(f32, 34), btn.frame.y);
    try t.expect(btn.frame.w > 30 and btn.frame.w < 40);
    try t.expectEqual(@as(f32, 32), btn.frame.h);

    // Spacer ăn hết phần còn lại của cột (640 - 10 - 24 - 32 - 10).
    const spacer = tree.findById("sp").?;
    try t.expectEqual(@as(f32, 564), spacer.frame.h);
    try t.expect(tree.findById("khong-co") == null);
}

test "ui layout row and click" {
    const t = std.testing;
    const alloc = t.allocator;
    var tree = try demoTree(alloc);
    defer tree.deinit();
    tree.layout(360, 640);

    // 2 nút trong hàng phải nằm cạnh nhau, nút sau bắt đầu sau nút trước.
    const b1 = tree.findById("btn_sync").?;
    const b2 = tree.findById("btn_settings").?;
    try t.expectEqual(b1.frame.y, b2.frame.y);
    try t.expect(b2.frame.x > b1.frame.x);
    try t.expect(b1.frame.w > 0 and b2.frame.w > 0);

    // Click nút thì ra payload event, click text thì không.
    var buf: [64]u8 = undefined;
    const payload = tree.clickPayload("btn_sync", &buf).?;
    try t.expectEqualStrings("ui:click:btn_sync", payload);
    try t.expect(tree.clickPayload("title", &buf) == null);
    try t.expect(tree.clickPayload("khong-co", &buf) == null);

    // Ảnh giữ đúng id + đường dẫn.
    const img = tree.findById("hero").?;
    try t.expectEqualStrings("assets/hero.png", img.image_path);
}

test "ui to json" {
    const t = std.testing;
    const alloc = t.allocator;
    var tree = try UiTree.init(alloc);
    defer tree.deinit();
    _ = try tree.addText(tree.root, "hi", "Hi");
    tree.layout(200, 400);
    const text = try tree.toJson(alloc);
    defer alloc.free(text);
    // JSON phải chứa kind/id/text và khung đã layout.
    try t.expect(std.mem.indexOf(u8, text, "\"kind\":\"column\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"id\":\"hi\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"text\":\"Hi\"") != null);
}
