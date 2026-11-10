const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "mobile",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Chạy unit test của thư viện");
    test_step.dependOn(&run_lib_tests.step);

    // Demo chạy trên host: vòng đời app + hàng đợi sự kiện.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "mobile", .module = lib_mod }},
    });
    const demo = b.addExecutable(.{
        .name = "mobile-demo",
        .root_module = demo_mod,
    });
    b.installArtifact(demo);

    // Android: libmobile.so cho arm64-v8a, root vẫn là src/root.zig nên
    // trong .so có đủ cả Java_* (Android) lẫn mobile_* (C ABI).
    // KHÔNG link libc: Zig không tự cấp được bionic libc cho Android,
    // muốn link libc thì cần NDK (máy này không có). Vì vậy các chỗ
    // gọi std.c (log file, getcwd, mkdir) đều bị chặn bằng comptime
    // khi build cho Android — xem log.zig / storage.zig.
    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });
    const android_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = android_target,
        .optimize = optimize,
        .link_libc = false,
    });
    const android_lib = b.addLibrary(.{
        .name = "mobile",
        .root_module = android_mod,
        .linkage = .dynamic,
    });
    const android_step = b.step("android", "Build libmobile.so cho aarch64-linux-android");
    android_step.dependOn(&b.addInstallArtifact(android_lib, .{ .dest_sub_path = "android/arm64-v8a/libmobile.so" }).step);

    // iOS: libmobile.a tĩnh cho arm64. Cần Xcode + SDK để link app thật;
    // trên máy không có Xcode thì bước này có thể gãy ở đoạn link libc.
    const ios_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
    });
    const ios_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = ios_target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ios_lib = b.addLibrary(.{
        .name = "mobile",
        .root_module = ios_mod,
        .linkage = .static,
    });
    const ios_step = b.step("ios", "Build libmobile.a cho aarch64-ios");
    // Để riêng thư mục ios/ để khỏi đè lên libmobile.a của host ở zig-out/lib/.
    ios_step.dependOn(&b.addInstallArtifact(ios_lib, .{ .dest_sub_path = "ios/libmobile.a" }).step);
}
