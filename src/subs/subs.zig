//! Getting a subtitle file for a video: search OpenSubtitles by moviehash and
//! guessed title, rank, let the user pick (or take a trusted hash match in
//! auto mode), download and save next to the video.

const std = @import("std");
const Io = std.Io;
const commands = @import("../commands.zig");
const extra = @import("../av_extra.zig");
/// Credentials and the language order.
pub const config = @import("config.zig");
const release = @import("release.zig");
const opensubtitles = @import("opensubtitles.zig");

const log = std.log.scoped(.subs);

pub const Options = struct {
    /// Overrides the configured language order.
    languages: ?[]const []const u8 = null,
    /// Download only a trusted hash match, never prompt.
    auto: bool = false,
    /// The video's frame rate when the caller already probed it.
    fps: ?f64 = null,
};

/// The subtitle file to side-load for `video`: a sidecar next to it, else,
/// with `download`, an OpenSubtitles hash match. Null when there is none;
/// a download that cannot happen is explained on stderr and is not an error,
/// since the cast goes on without a track.
pub fn resolve(env: commands.Env, video: []const u8, download: bool, fps: ?f64) !?[]const u8 {
    const cfg = try config.load(env.arena, env.io, env.environ);
    if (try release.findSidecar(env.arena, env.io, video, cfg.languages)) |path| {
        std.debug.print("subtitles: {s}\n", .{path});
        return path;
    }
    if (!download) return null;
    return fetchWith(env, &cfg, video, .{ .auto = true, .fps = fps }) catch |err| switch (err) {
        // Already explained on stderr by `fetchWith`.
        error.NoCredentials, error.NoSubtitles, error.RequestFailed, error.SourceUnreadable => null,
        else => err,
    };
}

/// Returns the saved path, or null when the user declined the pick. Every
/// failure is explained on stderr before its error.
pub fn fetch(env: commands.Env, video: []const u8, opts: Options) !?[]const u8 {
    const cfg = try config.load(env.arena, env.io, env.environ);
    return fetchWith(env, &cfg, video, opts);
}

fn fetchWith(env: commands.Env, cfg: *const config.Config, video: []const u8, opts: Options) !?[]const u8 {
    const io = env.io;
    const arena = env.arena;

    Io.Dir.cwd().access(io, video, .{}) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ video, @errorName(err) });
        return error.SourceUnreadable;
    };
    if (cfg.api_key.len == 0) {
        std.debug.print("no api_key: set it in {s} or CASTIG_OS_API_KEY (see README)\n", .{cfg.path});
        return error.NoCredentials;
    }

    const stem = std.fs.path.stem(video);
    const title = try release.guessTitle(arena, stem);
    const episode = release.parseEpisode(stem);
    const hash = release.moviehash(io, video) catch |err| blk: {
        log.debug("no moviehash: {s}", .{@errorName(err)});
        break :blk null;
    };
    const fps = opts.fps orelse videoFps(env.gpa, video);
    const languages = opts.languages orelse cfg.languages;

    var client = opensubtitles.Client.init(io, env.gpa, arena, cfg);
    defer client.deinit();
    std.debug.print("searching OpenSubtitles for \"{s}\"{s}\n", .{ title, if (hash != null) " (hash)" else "" });
    const cands = try client.search(.{ .hash = hash, .title = title, .languages = languages });
    if (cands.len == 0) {
        std.debug.print("no subtitles found\n", .{});
        return error.NoSubtitles;
    }
    for (cands) |*c| c.fps_mismatch = fps != null and c.fps != null and @abs(c.fps.? - fps.?) > 0.01;
    opensubtitles.rank(cands, .{ .languages = languages, .prefer_hi = cfg.prefer_hi, .episode = episode });

    var auto = opts.auto;
    if (!auto and !(Io.File.stdin().isTty(io) catch false)) {
        std.debug.print("stdin is not a terminal, picking automatically\n", .{});
        auto = true;
    }
    const pick = if (auto)
        pickAuto(cands, video) orelse return error.NoSubtitles
    else
        (try pickInteractive(env, cands, video, fps)) orelse return null;

    const c = cands[pick];
    const d = try client.download(c.file_id);
    const name = try release.destName(arena, video, c.lang, if (d.file_name.len > 0) d.file_name else c.file_name);
    const path = try save(env, cfg, video, name, d.bytes);
    try env.out.print("saved {s}", .{path});
    if (d.remaining) |n| try env.out.print(" ({d} downloads left today)", .{n});
    try env.out.writeAll("\n");
    try env.out.flush();
    return path;
}

fn videoFps(gpa: std.mem.Allocator, path: []const u8) ?f64 {
    const ic = extra.openInput(gpa, path) catch return null;
    defer ic.close_input();
    return extra.videoFps(ic);
}

/// The first trusted hash match with the video's frame rate; otherwise says
/// why nothing was taken. Never spends a download on a guess.
fn pickAuto(cands: []const opensubtitles.Candidate, video: []const u8) ?usize {
    for (cands, 0..) |c, i| if (c.hash == 2 and !c.fps_mismatch) return i;
    const why: []const u8 = switch (cands[0].hash) {
        2 => "hash match has an fps mismatch",
        1 => "hash match has a doubtful title",
        else => "no hash match",
    };
    std.debug.print("{s}; run `castig subs {s}` to pick from {d} result(s)\n", .{ why, video, cands.len });
    return null;
}

/// Numbered list, best last so it sits right above the prompt; Enter takes it.
fn pickInteractive(env: commands.Env, cands: []const opensubtitles.Candidate, video: []const u8, fps: ?f64) !?usize {
    const out = env.out;
    var first_feature: ?u64 = null;
    var multi_feature = false;
    for (cands) |c| {
        if (c.feature_id == null) continue;
        if (first_feature == null) first_feature = c.feature_id else if (first_feature != c.feature_id) multi_feature = true;
    }

    try out.print("subtitles for {s}", .{std.fs.path.basename(video)});
    if (fps) |f| {
        try out.writeAll(" (video ");
        try opensubtitles.writeFps(out, f);
        try out.writeAll(" fps)");
    }
    try out.writeAll("\n");
    var i = cands.len;
    while (i > 0) {
        i -= 1;
        try out.print("{d:>3}) ", .{i + 1});
        try opensubtitles.formatRow(out, cands[i], multi_feature);
        try out.writeAll("\n");
    }

    var buf: [256]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(env.io, &buf);
    var tries: u8 = 0;
    while (tries < 2) : (tries += 1) {
        try out.writeAll("pick [1]: ");
        try out.flush();
        const raw = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => "x",
            else => return null,
        };
        const line = std.mem.trim(u8, raw orelse return null, " \t\r");
        if (line.len == 0) return 0;
        if (std.mem.eql(u8, line, "q")) return null;
        const n = std.fmt.parseInt(usize, line, 10) catch 0;
        if (n >= 1 and n <= cands.len) return n - 1;
        try out.print("enter a number from 1 to {d}, or q\n", .{cands.len});
    }
    return null;
}

/// Next to the video, else `fallback_dir`, else `<cache_dir>/subs`.
fn save(env: commands.Env, cfg: *const config.Config, video: []const u8, name: []const u8, bytes: []const u8) ![]const u8 {
    const io = env.io;
    const arena = env.arena;
    const beside = try std.fs.path.join(arena, &.{ std.fs.path.dirname(video) orelse ".", name });
    if (Io.Dir.cwd().writeFile(io, .{ .sub_path = beside, .data = bytes })) |_| return beside else |err| {
        log.debug("cannot write {s}: {s}", .{ beside, @errorName(err) });
    }
    const dir = if (cfg.fallback_dir.len > 0) cfg.fallback_dir else try std.fs.path.join(arena, &.{ cfg.cache_dir, "subs" });
    std.debug.print("video dir not writable, saving to {s}\n", .{dir});
    const path = try std.fs.path.join(arena, &.{ dir, name });
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.debug.print("cannot create {s}: {s}\n", .{ dir, @errorName(err) });
        return error.SourceUnreadable;
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
        std.debug.print("cannot write {s}: {s}\n", .{ path, @errorName(err) });
        return error.SourceUnreadable;
    };
    return path;
}

test {
    _ = config;
    _ = release;
    _ = opensubtitles;
}
