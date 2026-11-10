// version.zig — Tên và phiên bản của thư viện, dùng chung cho cả
// Android, iOS và host. Đổi version thì đổi ở đây, một chỗ duy nhất.
pub const name = "zig-mobile";
pub const version = "0.3.0";
pub const zig_version = "0.17.1";

/// "zig-mobile 0.3.0 (zig 0.17.1)" — chuỗi tĩnh, gọi từ C/Swift cũng được.
pub const version_string = "zig-mobile 0.3.0 (zig 0.17.1)";
