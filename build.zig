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

    // The library. `b.addModule` publishes it, so another Zig project can
    // depend on castig and import it by name.
    const castig = b.addModule("castig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "av", .module = av },
        },
    });

    // The shell. Rooted in src/cli/, so a relative import of a library file is
    // outside its module path and the compiler rejects it: the CLI can only
    // reach the library through `@import("castig")`.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
        .imports = &.{
            .{ .name = "castig", .module = castig },
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

    // Rendered from the library root, so the pages are the API and not the
    // CLI entry point. Autodoc loads its sources over HTTP: serve zig-out/docs
    // rather than opening index.html from disk.
    const docs_obj = b.addObject(.{ .name = "castig", .root_module = castig });
    const docs_install = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Render the API documentation to zig-out/docs");
    docs_step.dependOn(&docs_install.step);

    // Both modules: the CLI files are reachable only from the exe.
    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ castig, exe_mod }) |mod| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
}
