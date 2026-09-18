const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zig build -fsys=ffmpeg` links the libav* libraries installed on the
    // system (found through pkg-config) instead of compiling the bundled
    // ffmpeg from source. The Zig bindings still come from the package.
    const system_ffmpeg = b.systemIntegrationOption("ffmpeg", .{});

    const ffmpeg_dep = b.dependency("ffmpeg", .{
        .target = target,
        .optimize = optimize,
    });

    const av = if (system_ffmpeg) blk: {
        const mod = b.createModule(.{
            .root_source_file = ffmpeg_dep.path("av.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        for ([_][]const u8{ "avformat", "avcodec", "avutil", "avfilter", "swresample", "swscale" }) |lib| {
            mod.linkSystemLibrary(lib, .{});
        }
        break :blk mod;
    } else ffmpeg_dep.module("av");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "av", .module = av },
        },
    });

    const exe = b.addExecutable(.{
        .name = "castig",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run castig");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
