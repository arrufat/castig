//! Finding a subtitle file for a video: a sidecar next to it, or a search of
//! OpenSubtitles by file hash and by a title guessed from the name.
//!
//! A search is a value: `Lookup` holds the ranked candidates and can download
//! any of them. Choosing is the caller's, so nothing here reads a terminal;
//! `confident` offers the one choice safe to make without asking.

const std = @import("std");
const Io = std.Io;
const Env = @import("../env.zig").Env;
const extra = @import("../media/av_extra.zig");
/// Credentials and the language order.
pub const config = @import("config.zig");
const release = @import("release.zig");
const opensubtitles = @import("opensubtitles.zig");

const log = std.log.scoped(.subs);

pub const Candidate = opensubtitles.Candidate;

pub const Options = struct {
    /// Overrides the configured language order.
    languages: ?[]const []const u8 = null,
    /// The video's frame rate when the caller already probed it. Candidates
    /// whose frame rate disagrees rank lower and are never taken blind.
    fps: ?f64 = null,
};

pub const Saved = struct {
    path: []const u8,
    /// Downloads left on the account today, when the API said.
    remaining: ?i64,
};

/// A ranked search for one video, and the means to download from it.
pub const Lookup = struct {
    env: Env,
    cfg: config.Config,
    client: opensubtitles.Client,
    video: []const u8,
    fps: ?f64,
    /// Best first. Empty is reported as `error.NoSubtitles` by `open`.
    candidates: []Candidate,

    /// Hashes the file, guesses a title, searches and ranks.
    pub fn open(env: Env, video: []const u8, opts: Options) !Lookup {
        const cfg = try config.load(env.arena, env.io, env.environ);
        return openWith(env, cfg, video, opts);
    }

    fn openWith(env: Env, cfg: config.Config, video: []const u8, opts: Options) !Lookup {
        const io = env.io;
        const arena = env.arena;

        Io.Dir.cwd().access(io, video, .{}) catch |err| {
            log.warn("cannot read {s}: {s}", .{ video, @errorName(err) });
            return error.SourceUnreadable;
        };
        if (cfg.api_key.len == 0) {
            log.warn("no api_key: set it in {s} or OPENSUBTITLES_API_KEY (see README)", .{cfg.path});
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

        var l: Lookup = .{
            .env = env,
            .cfg = cfg,
            .client = opensubtitles.Client.init(io, env.gpa, arena, cfg),
            .video = video,
            .fps = fps,
            .candidates = &.{},
        };
        errdefer l.client.deinit();

        log.info("searching OpenSubtitles for \"{s}\"{s}", .{ title, if (hash != null) " (hash)" else "" });
        l.candidates = try l.client.search(.{ .hash = hash, .title = title, .languages = languages });
        if (l.candidates.len == 0) {
            log.warn("no subtitles found", .{});
            return error.NoSubtitles;
        }
        for (l.candidates) |*c| c.fps_mismatch = fps != null and c.fps != null and @abs(c.fps.? - fps.?) > 0.01;
        opensubtitles.rank(l.candidates, .{ .languages = languages, .prefer_hi = cfg.prefer_hi, .episode = episode });
        return l;
    }

    pub fn deinit(l: *Lookup) void {
        l.client.deinit();
    }

    /// The one candidate worth taking without asking: a hash match for the
    /// feature the hash matches agree on, whose frame rate fits the video.
    /// A free account gets twenty downloads a day, so a guess is never taken.
    pub fn confident(l: Lookup) ?usize {
        for (l.candidates, 0..) |c, i| if (c.hash == 2 and !c.fps_mismatch) return i;
        return null;
    }

    /// Why `confident` found nothing, for a caller that has to explain itself.
    pub fn doubt(l: Lookup) []const u8 {
        return switch (l.candidates[0].hash) {
            2 => "hash match has an fps mismatch",
            1 => "hash match has a doubtful title",
            else => "no hash match",
        };
    }

    /// Downloads one candidate and saves it next to the video. This spends
    /// one of the day's downloads.
    pub fn take(l: *Lookup, index: usize) !Saved {
        const c = l.candidates[index];
        const d = try l.client.download(c.file_id);
        const name = try release.destName(l.env.arena, l.video, c.lang, if (d.file_name.len > 0) d.file_name else c.file_name);
        return .{ .path = try l.save(name, d.bytes), .remaining = d.remaining };
    }

    /// Next to the video, else `fallback_dir`, else `<cache_dir>/subs`.
    fn save(l: Lookup, name: []const u8, bytes: []const u8) ![]const u8 {
        const io = l.env.io;
        const arena = l.env.arena;
        const beside = try std.fs.path.join(arena, &.{ std.fs.path.dirname(l.video) orelse ".", name });
        if (Io.Dir.cwd().writeFile(io, .{ .sub_path = beside, .data = bytes })) |_| return beside else |err| {
            log.debug("cannot write {s}: {s}", .{ beside, @errorName(err) });
        }
        const dir = if (l.cfg.fallback_dir.len > 0) l.cfg.fallback_dir else try std.fs.path.join(arena, &.{ l.cfg.cache_dir, "subs" });
        log.warn("video dir not writable, saving to {s}", .{dir});
        const path = try std.fs.path.join(arena, &.{ dir, name });
        Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            log.warn("cannot create {s}: {s}", .{ dir, @errorName(err) });
            return error.SourceUnreadable;
        };
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
            log.warn("cannot write {s}: {s}", .{ path, @errorName(err) });
            return error.SourceUnreadable;
        };
        return path;
    }
};

/// The subtitle file to side-load for `video`: a sidecar next to it, else,
/// with `download`, a confident OpenSubtitles match. Null when there is none,
/// which is not an error: the cast goes on without a track.
pub fn resolve(env: Env, video: []const u8, download: bool, fps: ?f64) !?[]const u8 {
    const cfg = try config.load(env.arena, env.io, env.environ);
    if (try release.findSidecar(env.arena, env.io, video, cfg.languages)) |path| {
        log.info("subtitles: {s}", .{path});
        return path;
    }
    if (!download) return null;

    var l = Lookup.openWith(env, cfg, video, .{ .fps = fps }) catch |err| switch (err) {
        // Already explained; a cast without subtitles is still a cast.
        error.NoCredentials, error.NoSubtitles, error.SourceUnreadable, error.RequestFailed => return null,
        else => return err,
    };
    defer l.deinit();

    const index = l.confident() orelse {
        log.warn("{s}; run `castig subs {s}` to pick from {d} result(s)", .{ l.doubt(), video, l.candidates.len });
        return null;
    };
    const saved = l.take(index) catch |err| switch (err) {
        error.NoCredentials, error.RequestFailed => return null,
        else => return err,
    };
    return saved.path;
}

fn videoFps(gpa: std.mem.Allocator, path: []const u8) ?f64 {
    const ic = extra.openInput(gpa, path) catch return null;
    defer ic.close_input();
    return extra.videoFps(ic);
}

test {
    _ = config;
    _ = release;
    _ = opensubtitles;
}
