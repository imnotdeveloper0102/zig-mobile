// settings.zig — Cài đặt key-value của app (trong bộ nhớ + lưu file).
//
// Chỉ giữ cài đặt đơn giản: chuỗi / số nguyên / bool. Key chỉ gồm
// chữ, số, '_' '.' '-' (tối đa 64 ký tự) để khỏi lọt ký tự lạ vào
// file. Lưu xuống file dạng text, mỗi dòng một cài đặt:
//
//   theme=s:dark
//   font_size=i:16
//   notifications=b:true
//
// Chuỗi được escape (\, xuống dòng, '=') để đọc lại đúng. File lưu
// ở files_dir (qua files.zig) nên cũng được chặn ".." như mọi file
// khác của app. Lỗi ở một dòng khi load thì bỏ qua dòng đó, không
// làm hỏng toàn bộ cài đặt.
const std = @import("std");
const errors = @import("errors.zig");
const files = @import("files.zig");
const spinlock = @import("spinlock.zig");
const storage = @import("storage.zig");

pub const MobileError = errors.MobileError;
pub const Storage = storage.Storage;

pub const max_key_len = 64;
pub const max_entries = 128;
pub const max_settings_file_bytes: usize = 64 * 1024;

pub const Value = union(enum) {
    string: []u8,
    int: i64,
    boolean: bool,

    pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| alloc.free(s),
            .int, .boolean => {},
        }
    }
};

pub const Entry = struct {
    key: []u8,
    value: Value,
};

pub const Settings = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    /// Khóa cho set/get/remove/save/load (v0.3.0). findIndex() không
    /// tự khóa — chỉ gọi khi đã giữ mu, vì spinlock khóa lại lần
    /// nữa trên cùng thread sẽ kẹt vĩnh viễn.
    mu: spinlock.SpinLock = .{},

    pub fn init(alloc: std.mem.Allocator) Settings {
        return .{ .alloc = alloc, .entries = std.ArrayList(Entry).empty };
    }

    pub fn deinit(self: *Settings) void {
        for (self.entries.items) |*e| {
            self.alloc.free(e.key);
            e.value.deinit(self.alloc);
        }
        self.entries.deinit(self.alloc);
    }

    pub fn count(self: *const Settings) usize {
        const mut = @constCast(self);
        mut.mu.lock();
        defer mut.mu.unlock();
        return mut.entries.items.len;
    }

    fn findIndex(self: *const Settings, key: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) return i;
        }
        return null;
    }

    pub fn setString(self: *Settings, key: []const u8, value: []const u8) MobileError!void {
        const owned = self.alloc.dupe(u8, value) catch return error.OutOfMemory;
        // Không errdefer ở đây: set() tự giải phóng value khi lỗi.
        try self.set(key, .{ .string = owned });
    }

    pub fn setInt(self: *Settings, key: []const u8, value: i64) MobileError!void {
        try self.set(key, .{ .int = value });
    }

    pub fn setBool(self: *Settings, key: []const u8, value: bool) MobileError!void {
        try self.set(key, .{ .boolean = value });
    }

    fn set(self: *Settings, key: []const u8, value: Value) MobileError!void {
        self.mu.lock();
        defer self.mu.unlock();
        if (!isValidKey(key)) {
            var v = value;
            v.deinit(self.alloc);
            return error.InvalidSetting;
        }
        if (self.findIndex(key)) |i| {
            // Ghi đè: giải phóng giá trị cũ trước.
            self.entries.items[i].value.deinit(self.alloc);
            self.entries.items[i].value = value;
            return;
        }
        if (self.entries.items.len >= max_entries) {
            var v = value;
            v.deinit(self.alloc);
            return error.InvalidSetting;
        }
        const owned_key = self.alloc.dupe(u8, key) catch {
            var v = value;
            v.deinit(self.alloc);
            return error.OutOfMemory;
        };
        self.entries.append(self.alloc, .{ .key = owned_key, .value = value }) catch {
            self.alloc.free(owned_key);
            var v = value;
            v.deinit(self.alloc);
            return error.OutOfMemory;
        };
    }

    /// Chuỗi trả về mượn từ Settings — dùng ngay, đừng giữ lâu.
    pub fn getString(self: *const Settings, key: []const u8) ?[]const u8 {
        const mut = @constCast(self);
        mut.mu.lock();
        defer mut.mu.unlock();
        const i = mut.findIndex(key) orelse return null;
        return switch (mut.entries.items[i].value) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getInt(self: *const Settings, key: []const u8) ?i64 {
        const mut = @constCast(self);
        mut.mu.lock();
        defer mut.mu.unlock();
        const i = mut.findIndex(key) orelse return null;
        return switch (mut.entries.items[i].value) {
            .int => |v| v,
            else => null,
        };
    }

    pub fn getBool(self: *const Settings, key: []const u8) ?bool {
        const mut = @constCast(self);
        mut.mu.lock();
        defer mut.mu.unlock();
        const i = mut.findIndex(key) orelse return null;
        return switch (mut.entries.items[i].value) {
            .boolean => |v| v,
            else => null,
        };
    }

    pub fn remove(self: *Settings, key: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const i = self.findIndex(key) orelse return false;
        var e = self.entries.orderedRemove(i);
        self.alloc.free(e.key);
        e.value.deinit(self.alloc);
        return true;
    }

    pub fn clear(self: *Settings) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |*e| {
            self.alloc.free(e.key);
            e.value.deinit(self.alloc);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Ghi toàn bộ cài đặt xuống file trong files_dir. Phần build
    /// buffer giữ khóa, phần ghi file thì không — để khỏi giữ khóa
    /// trong lúc chờ IO (file có thể chậm, spinlock không hợp để
    /// giữ lâu).
    pub fn save(self: *const Settings, store: *const Storage, relative: []const u8) MobileError!void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        {
            const mut = @constCast(self);
            mut.mu.lock();
            defer mut.mu.unlock();
            for (mut.entries.items) |e| {
                switch (e.value) {
                    .string => |s| {
                        const line = try escapeLine(self.alloc, e.key, 's', s);
                        defer self.alloc.free(line);
                        buf.appendSlice(self.alloc, line) catch return error.OutOfMemory;
                        buf.appendSlice(self.alloc, "\n") catch return error.OutOfMemory;
                    },
                    .int => |v| {
                        const line = std.fmt.allocPrint(self.alloc, "{s}=i:{d}\n", .{ e.key, v }) catch return error.OutOfMemory;
                        defer self.alloc.free(line);
                        buf.appendSlice(self.alloc, line) catch return error.OutOfMemory;
                    },
                    .boolean => |v| {
                        const line = std.fmt.allocPrint(self.alloc, "{s}=b:{s}\n", .{ e.key, if (v) "true" else "false" }) catch return error.OutOfMemory;
                        defer self.alloc.free(line);
                        buf.appendSlice(self.alloc, line) catch return error.OutOfMemory;
                    },
                }
            }
        }
        try files.writeText(store, self.alloc, relative, buf.items, false, false);
    }

    /// Đọc cài đặt từ file. File chưa có thì coi như trống (không
    /// lỗi) — app mới cài lần đầu chưa có file cài đặt là bình thường.
    /// Dòng nào lỗi định dạng thì bỏ qua, giữ lại các dòng đúng.
    pub fn load(self: *Settings, store: *const Storage, relative: []const u8) MobileError!void {
        const text = files.readText(store, self.alloc, relative, max_settings_file_bytes, false) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer self.alloc.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            self.loadLine(line) catch continue;
        }
    }

    fn loadLine(self: *Settings, line: []const u8) MobileError!void {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSetting;
        const key = line[0..eq];
        const rest = line[eq + 1 ..];
        if (rest.len < 2 or rest[1] != ':') return error.InvalidSetting;
        switch (rest[0]) {
            's' => {
                const value = try unescape(self.alloc, rest[2..]);
                defer self.alloc.free(value);
                try self.setString(key, value);
            },
            'i' => {
                const v = std.fmt.parseInt(i64, rest[2..], 10) catch return error.InvalidSetting;
                try self.setInt(key, v);
            },
            'b' => {
                if (std.mem.eql(u8, rest[2..], "true")) {
                    try self.setBool(key, true);
                } else if (std.mem.eql(u8, rest[2..], "false")) {
                    try self.setBool(key, false);
                } else {
                    return error.InvalidSetting;
                }
            },
            else => return error.InvalidSetting,
        }
    }
};

pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_len) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn escapeLine(alloc: std.mem.Allocator, key: []const u8, kind: u8, value: []const u8) MobileError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, key) catch return error.OutOfMemory;
    buf.append(alloc, '=') catch return error.OutOfMemory;
    buf.append(alloc, kind) catch return error.OutOfMemory;
    buf.append(alloc, ':') catch return error.OutOfMemory;
    for (value) |c| {
        switch (c) {
            '\\' => buf.appendSlice(alloc, "\\\\") catch return error.OutOfMemory,
            '\n' => buf.appendSlice(alloc, "\\n") catch return error.OutOfMemory,
            '=' => buf.appendSlice(alloc, "\\=") catch return error.OutOfMemory,
            else => buf.append(alloc, c) catch return error.OutOfMemory,
        }
    }
    return buf.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

fn unescape(alloc: std.mem.Allocator, text: []const u8) MobileError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\') {
            if (i + 1 >= text.len) return error.InvalidSetting;
            switch (text[i + 1]) {
                'n' => buf.append(alloc, '\n') catch return error.OutOfMemory,
                '=' => buf.append(alloc, '=') catch return error.OutOfMemory,
                '\\' => buf.append(alloc, '\\') catch return error.OutOfMemory,
                else => return error.InvalidSetting,
            }
            i += 2;
        } else {
            buf.append(alloc, c) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return buf.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

test "settings set get remove" {
    const t = std.testing;
    const alloc = t.allocator;
    var s = Settings.init(alloc);
    defer s.deinit();

    try s.setString("theme", "dark");
    try s.setInt("font_size", 16);
    try s.setBool("notifications", true);
    try t.expectEqual(@as(usize, 3), s.count());
    try t.expectEqualStrings("dark", s.getString("theme").?);
    try t.expectEqual(@as(i64, 16), s.getInt("font_size").?);
    try t.expect(s.getBool("notifications").?);
    // Sai kiểu thì trả null, không crash.
    try t.expect(s.getInt("theme") == null);
    try t.expect(s.getString("font_size") == null);
    try t.expect(s.getString("khong-co") == null);

    // Ghi đè key cũ.
    try s.setString("theme", "light");
    try t.expectEqual(@as(usize, 3), s.count());
    try t.expectEqualStrings("light", s.getString("theme").?);

    try t.expect(s.remove("font_size"));
    try t.expect(!s.remove("font_size"));
    try t.expectEqual(@as(usize, 2), s.count());

    // Key xấu thì bị chặn.
    try t.expectError(error.InvalidSetting, s.setString("key xấu", "x"));
    try t.expectError(error.InvalidSetting, s.setString("a=b", "x"));
    try t.expectError(error.InvalidSetting, s.setString("", "x"));
}

test "settings save load roundtrip" {
    const t = std.testing;
    const alloc = t.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer alloc.free(dir);
    var store = try Storage.init(alloc, .host, dir, dir);
    defer store.deinit();

    var s = Settings.init(alloc);
    defer s.deinit();
    try s.setString("theme", "dark");
    try s.setString("note", "a=b\nline2\\end");
    try s.setInt("font_size", -3);
    try s.setBool("notifications", false);
    try s.save(&store, "settings.txt");

    // Load vào Settings mới, phải đọc lại đúng hết.
    var s2 = Settings.init(alloc);
    defer s2.deinit();
    try s2.load(&store, "settings.txt");
    try t.expectEqualStrings("dark", s2.getString("theme").?);
    try t.expectEqualStrings("a=b\nline2\\end", s2.getString("note").?);
    try t.expectEqual(@as(i64, -3), s2.getInt("font_size").?);
    try t.expect(!s2.getBool("notifications").?);

    // Load file chưa có thì không lỗi, vẫn trống.
    var s3 = Settings.init(alloc);
    defer s3.deinit();
    try s3.load(&store, "chua-co.txt");
    try t.expectEqual(@as(usize, 0), s3.count());
}
