//! What a video's name and bytes say about it, for subtitle lookup: the
//! OpenSubtitles moviehash, a title guess from a release name, episode
//! codes, the sidecar names to look for and the name a download gets.

const std = @import("std");
const Io = std.Io;

pub const Episode = struct { season: u16, episode: u16 };

const hash_chunk = 64 * 1024;

/// OpenSubtitles moviehash: the file size plus the first and last 64 KiB as
/// little-endian u64 words, summed with wrap-around.
pub fn moviehash(io: Io, path: []const u8) error{ FileTooSmall, Unreadable }!u64 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return error.Unreadable;
    defer file.close(io);
    const size = file.length(io) catch return error.Unreadable;
    if (size < 2 * hash_chunk) return error.FileTooSmall;
    var head: [hash_chunk]u8 = undefined;
    var tail: [hash_chunk]u8 = undefined;
    const got_head = file.readPositionalAll(io, &head, 0) catch return error.Unreadable;
    const got_tail = file.readPositionalAll(io, &tail, size - hash_chunk) catch return error.Unreadable;
    if (got_head != hash_chunk or got_tail != hash_chunk) return error.Unreadable;
    return hashChunks(&head, &tail, size);
}

fn hashChunks(head: *const [hash_chunk]u8, tail: *const [hash_chunk]u8, size: u64) u64 {
    var h: u64 = size;
    for ([_]*const [hash_chunk]u8{ head, tail }) |chunk| {
        var i: usize = 0;
        while (i < hash_chunk) : (i += 8) h +%= std.mem.readInt(u64, chunk[i..][0..8], .little);
    }
    return h;
}

/// A search title from a release-style file name (no extension): dots and
/// underscores become spaces, bracketed groups go, then everything from the
/// first quality/source token on. The episode code stays, since the search
/// wants it.
pub fn guessTitle(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, name.len);
    var n: usize = 0;
    var i: usize = 0;
    var pending_space = false;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        if (c == '[' or c == '(') {
            if (std.mem.findAny(u8, name[i + 1 ..], "])")) |close| {
                i += close + 1;
                pending_space = true;
                continue;
            }
        }
        if (std.ascii.isWhitespace(c) or c == '.' or c == '_') {
            pending_space = true;
            continue;
        }
        if (pending_space and n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        pending_space = false;
        buf[n] = c;
        n += 1;
    }
    var s: []const u8 = buf[0..n];
    if (noiseStart(s)) |cut| s = s[0..cut];
    return std.mem.trimEnd(u8, s, " -");
}

/// Offset of the earliest noise token that does not start the name, or null.
fn noiseStart(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (!std.ascii.isAlphanumeric(s[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < s.len and std.ascii.isAlphanumeric(s[i])) i += 1;
        if (start > 0 and isNoise(s[start..i], s[i..])) return start;
    }
    return null;
}

const noise_words = std.StaticStringMap(void).initComptime(.{
    .{"web"},  .{"bluray"}, .{"bdrip"}, .{"brrip"}, .{"hdtv"}, .{"x264"},
    .{"h264"}, .{"x265"},   .{"h265"},  .{"hevc"},  .{"aac"},
});

fn isNoise(run: []const u8, rest: []const u8) bool {
    var lower_buf: [16]u8 = undefined;
    if (run.len <= lower_buf.len) {
        const lower = std.ascii.lowerString(&lower_buf, run);
        if (noise_words.has(lower)) return true;
        // "blu-ray": the run "blu", a dash, then the run "ray".
        if (std.mem.eql(u8, lower, "blu") and rest.len >= 4 and rest[0] == '-' and std.ascii.eqlIgnoreCase(rest[1..4], "ray") and (rest.len == 4 or !std.ascii.isAlphanumeric(rest[4]))) return true;
    }
    // 720p, 1080i: three or more digits and a p or i.
    if (run.len >= 4 and (run[run.len - 1] == 'p' or run[run.len - 1] == 'i') and allDigits(run[0 .. run.len - 1])) return true;
    // A year.
    if (run.len == 4 and allDigits(run) and (std.mem.startsWith(u8, run, "19") or std.mem.startsWith(u8, run, "20"))) return true;
    return false;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// `S01E02` (one to three digits each) or `1x02` (one or two), word-bounded.
/// An `S..E..` anywhere wins over an `NxNN` anywhere.
pub fn parseEpisode(name: []const u8) ?Episode {
    return scan(name, "sS", 3, "eE", 3) orelse scan(name, "", 2, "xX", 2);
}

/// The first `<prefix?><digits><sep><digits>` that starts a word.
fn scan(name: []const u8, prefix: []const u8, max_a: usize, seps: []const u8, max_b: usize) ?Episode {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (i > 0 and std.ascii.isAlphanumeric(name[i - 1])) continue;
        const rest = if (prefix.len == 0) name[i..] else blk: {
            if (std.mem.findScalar(u8, prefix, name[i]) == null) continue;
            break :blk name[i + 1 ..];
        };
        if (parseCode(rest, max_a, seps, max_b)) |ep| return ep;
    }
    return null;
}

/// `<digits><sep><digits>` followed by a word boundary.
fn parseCode(s: []const u8, max_a: usize, seps: []const u8, max_b: usize) ?Episode {
    var i: usize = 0;
    while (i < s.len and i < max_a and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0 or i >= s.len or std.mem.findScalar(u8, seps, s[i]) == null) return null;
    const season = std.fmt.parseInt(u16, s[0..i], 10) catch return null;
    const b = i + 1;
    var j = b;
    while (j < s.len and j - b < max_b and std.ascii.isDigit(s[j])) j += 1;
    if (j == b or (j < s.len and std.ascii.isAlphanumeric(s[j]))) return null;
    const episode = std.fmt.parseInt(u16, s[b..j], 10) catch return null;
    return .{ .season = season, .episode = episode };
}

const sidecar_exts = [_][]const u8{ ".srt", ".vtt" };

/// Sidecar subtitle paths to look for, in preference order:
/// `<stem>.<lang>.srt|vtt` per configured language, then `<stem>.srt|vtt`.
fn sidecarNames(arena: std.mem.Allocator, video: []const u8, languages: []const []const u8) ![]const []const u8 {
    const dir = std.fs.path.dirname(video);
    const stem = std.fs.path.stem(video);
    var names: std.ArrayList([]const u8) = .empty;
    for (languages) |lang| {
        for (sidecar_exts) |ext| try names.append(arena, try joinName(arena, dir, stem, lang, ext));
    }
    for (sidecar_exts) |ext| try names.append(arena, try joinName(arena, dir, stem, null, ext));
    return names.toOwnedSlice(arena);
}

fn joinName(arena: std.mem.Allocator, dir: ?[]const u8, stem: []const u8, lang: ?[]const u8, ext: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (dir) |d| try out.print(arena, "{s}/", .{d});
    try out.appendSlice(arena, stem);
    if (lang) |l| try out.print(arena, ".{s}", .{l});
    try out.appendSlice(arena, ext);
    return out.toOwnedSlice(arena);
}

/// The first sidecar of `sidecarNames` that exists, or null.
pub fn findSidecar(arena: std.mem.Allocator, io: Io, video: []const u8, languages: []const []const u8) !?[]const u8 {
    for (try sidecarNames(arena, video, languages)) |name| {
        Io.Dir.cwd().access(io, name, .{}) catch continue;
        return name;
    }
    return null;
}

/// `<stem>.<lang>.<ext>`, the extension taken from the downloaded file's name
/// (`.srt` when it has none).
pub fn destName(arena: std.mem.Allocator, video: []const u8, lang: []const u8, remote_name: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(remote_name);
    return joinName(arena, null, std.fs.path.stem(video), lang, if (ext.len > 1) ext else sidecar_exts[0]);
}

test "moviehash of synthetic chunks" {
    var head: [hash_chunk]u8 = @splat(0);
    var tail: [hash_chunk]u8 = @splat(0);
    try std.testing.expectEqual(@as(u64, 2 * hash_chunk), hashChunks(&head, &tail, 2 * hash_chunk));
    head[0] = 1;
    tail[hash_chunk - 8] = 2;
    try std.testing.expectEqual(@as(u64, 2 * hash_chunk + 3), hashChunks(&head, &tail, 2 * hash_chunk));
    @memset(&head, 0xff);
    // Wrap-around: 8192 words of all ones plus the rest.
    try std.testing.expectEqual(@as(u64, 2 * hash_chunk + 2) -% 8192, hashChunks(&head, &tail, 2 * hash_chunk));
}

test "title guesses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("The Movie", try guessTitle(a, "The.Movie.2019.1080p.BluRay.x264-GRP"));
    try std.testing.expectEqualStrings("Show S02E05", try guessTitle(a, "Show.S02E05.720p.WEB-DL"));
    try std.testing.expectEqualStrings("Title", try guessTitle(a, "[Grp] Title (BD 1080p)"));
    try std.testing.expectEqualStrings("Movie", try guessTitle(a, "[1080p] Movie"));
    try std.testing.expectEqualStrings("Life", try guessTitle(a, "Life.Blu-Ray.2001"));
    try std.testing.expectEqualStrings("Plain Name", try guessTitle(a, "Plain_Name"));
    try std.testing.expectEqualStrings("1080p Test", try guessTitle(a, "1080p.Test"));
    try std.testing.expectEqualStrings("Movie", try guessTitle(a, "Movie - 2010"));
}

test "episode codes" {
    try std.testing.expectEqual(Episode{ .season = 1, .episode = 2 }, parseEpisode("Show.S01E02.mkv").?);
    try std.testing.expectEqual(Episode{ .season = 1, .episode = 2 }, parseEpisode("show s1e2").?);
    try std.testing.expectEqual(Episode{ .season = 3, .episode = 7 }, parseEpisode("Show 3x07").?);
    try std.testing.expectEqual(@as(?Episode, null), parseEpisode("xS01E02"));
    try std.testing.expectEqual(@as(?Episode, null), parseEpisode("1920x1080"));
    try std.testing.expectEqual(@as(?Episode, null), parseEpisode("Movie 2019"));
}

test "sidecar and destination names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = try sidecarNames(a, "/v/Movie.mkv", &.{ "en", "ko" });
    const want = [_][]const u8{ "/v/Movie.en.srt", "/v/Movie.en.vtt", "/v/Movie.ko.srt", "/v/Movie.ko.vtt", "/v/Movie.srt", "/v/Movie.vtt" };
    try std.testing.expectEqual(want.len, names.len);
    for (want, names) |w, n| try std.testing.expectEqualStrings(w, n);
    const bare = try sidecarNames(a, "Movie.mkv", &.{});
    try std.testing.expectEqualStrings("Movie.srt", bare[0]);
    try std.testing.expectEqualStrings("Movie.en.SRT", try destName(a, "/v/Movie.mkv", "en", "x.SRT"));
    try std.testing.expectEqualStrings("Movie.en.srt", try destName(a, "/v/Movie.mkv", "en", "noext"));
}
