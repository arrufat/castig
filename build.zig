const std = @import("std");

const castig_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

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

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", b.fmt("{f}", .{resolveVersion(b)}));
    castig.addOptions("build_options", build_options);

    // The shell. Rooted in src/cli/, so a relative import of a library file is
    // outside its module path and the compiler rejects it: the CLI can only
    // reach the library through `@import("castig")`.
    const exe_mod = frontEnd(b, target, optimize, "src/cli/main.zig", &.{
        .{ .name = "castig", .module = castig },
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

    const version_step = b.step("version", "Print the resolved version");
    const version_run = b.addRunArtifact(exe);
    version_run.addArg("version");
    version_step.dependOn(&version_run.step);

    // Rendered from the library root, so the pages are the API and not the
    // CLI entry point.
    const docs_obj = b.addObject(.{ .name = "castig", .root_module = castig });
    const docs_install = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Render the API documentation to zig-out/docs");
    docs_step.dependOn(&docs_install.step);

    // Autodoc loads its sources over HTTP, so the pages cannot be opened from
    // disk: this step serves them and opens a browser, the way `zig std` does.
    // It runs until interrupted, which is why rendering has a step of its own.
    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const serve_docs = b.addRunArtifact(docs_server);
    serve_docs.step.dependOn(&docs_install.step);
    serve_docs.addDirectoryArg(docs_obj.getEmittedDocs());
    serve_docs.addPassthruArgs(); // `zig build docs-serve -- 8080` pins the port.
    serve_docs.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation and open a browser");
    docs_serve_step.dependOn(&serve_docs.step);

    // Both modules: the CLI files are reachable only from the exe.
    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ castig, exe_mod }) |mod| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

    // The window: a second shell over the same library, behind its own
    // step, so `zig build` still compiles just the CLI.
    const gui_step = b.step("gui", "Build the castig window");
    if (b.lazyDependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    })) |dvui_dep| {
        const gui_mod = frontEnd(b, target, optimize, "src/gui/main.zig", &.{
            .{ .name = "castig", .module = castig },
            .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
        });
        const gui = b.addExecutable(.{
            .name = "castigui",
            .root_module = gui_mod,
        });
        gui_step.dependOn(&b.addInstallArtifact(gui, .{}).step);

        const run_gui = b.addRunArtifact(gui);
        run_gui.step.dependOn(gui_step);
        run_gui.addPassthruArgs();
        const run_gui_step = b.step("run-gui", "Run the castig window");
        run_gui_step.dependOn(&run_gui.step);

        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = gui_mod })).step);
    }
}

/// The version the binary reports: the declared one on a tag, otherwise a dev
/// version carrying the commit count and hash.
fn resolveVersion(b: *std.Build) std.SemanticVersion {
    if (b.option([]const u8, "version-string", "Override the version of this build")) |override| {
        return std.SemanticVersion.parse(override) catch |err| {
            std.debug.panic("Expected -Dversion-string={s} to be a semantic version: {}", .{ override, err });
        };
    }

    if (castig_version.pre == null and castig_version.build == null) return castig_version;
    if (runGit(b, &.{ "describe", "--tags", "--exact-match" }) != null) return castig_version;

    const commit_hash = runGit(b, &.{ "rev-parse", "--short", "HEAD" }) orelse return castig_version;
    const revspec = if (runGit(b, &.{ "describe", "--tags", "--match=*.0", "--abbrev=0" })) |base_tag|
        b.fmt("{s}..HEAD", .{base_tag})
    else
        "HEAD";
    const commit_count = runGit(b, &.{ "rev-list", "--count", revspec }) orelse return castig_version;

    return .{
        .major = castig_version.major,
        .minor = castig_version.minor,
        .patch = castig_version.patch,
        .pre = b.fmt("dev.{s}", .{commit_count}),
        .build = commit_hash,
    };
}

/// Git in the repo root, or null on any failure: no git, no repo, no tag.
fn runGit(b: *std.Build, args: []const []const u8) ?[]const u8 {
    const dir = b.root.root_dir.path orelse ".";
    const argv = std.mem.concat(b.allocator, []const u8, &.{ &.{ "git", "-C", dir }, args }) catch return null;
    defer b.allocator.free(argv);
    var code: u8 = undefined;
    const out = b.runAllowFail(argv, &code, .ignore) catch return null;
    const trimmed = std.mem.trim(u8, out, " \r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// A front end over the library: its own root, and one policy for both.
fn frontEnd(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
        .imports = imports,
    });
}
