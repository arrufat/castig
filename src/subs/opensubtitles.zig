//! OpenSubtitles.com REST client and result ranking, ported from mpv-jamak.
//!
//! Search needs only the API key. Download needs a login token, cached in
//! `<cache_dir>/token.json` for 20 hours. Results are ranked so that a
//! moviehash match for the feature most hash matches agree on comes first,
//! then by the user's language order, human over AI translation, matching
//! frame rate, hearing-impaired preference and download count.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const release = @import("release.zig");

const log = std.log.scoped(.subs);

const api_default = "https://api.opensubtitles.com/api/v1";
const user_agent = "castig v0.1";
const token_max_age_s: i64 = 20 * 60 * 60;
/// The API adds fields freely.
const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

pub const Candidate = struct {
    file_id: u64,
    file_name: []const u8,
    lang: []const u8,
    release: []const u8,
    feature_id: ?u64,
    /// "Show S01E02" or "Title (2004)"; null when the API named no feature.
    feature: ?[]const u8,
    season: ?u32,
    episode: ?u32,
    downloads: u64,
    /// 0 none, 1 hash match, 2 hash match whose feature won the vote.
    hash: u2,
    hi: bool,
    ai: bool,
    fps: ?f64,
    /// Set by the caller who knows the video's frame rate.
    fps_mismatch: bool = false,
};

pub const Download = struct {
    bytes: []const u8,
    /// The API's name for the file, for its extension.
    file_name: []const u8,
    remaining: ?i64,
};

pub const SearchQuery = struct {
    hash: ?u64,
    title: []const u8,
    languages: []const []const u8,
};

// --- wire structs (field names are the JSON keys; all optional, the API nulls freely) ---

const LoginReply = struct { token: ?[]const u8 = null, base_url: ?[]const u8 = null };
const Message = struct { message: ?[]const u8 = null };
const SearchReply = struct { data: ?[]const Item = null };
const Item = struct { attributes: ?Attributes = null };
const Attributes = struct {
    language: ?[]const u8 = null,
    release: ?[]const u8 = null,
    download_count: ?i64 = null,
    moviehash_match: ?bool = null,
    hearing_impaired: ?bool = null,
    ai_translated: ?bool = null,
    machine_translated: ?bool = null,
    fps: std.json.Value = .null,
    files: ?[]const File = null,
    feature_details: ?FeatureDetails = null,
};
const File = struct { file_id: ?u64 = null, file_name: ?[]const u8 = null };
const FeatureDetails = struct {
    feature_id: ?u64 = null,
    feature_type: ?[]const u8 = null,
    title: ?[]const u8 = null,
    parent_title: ?[]const u8 = null,
    year: ?i64 = null,
    season_number: ?u32 = null,
    episode_number: ?u32 = null,
};
const DownloadReply = struct {
    link: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    remaining: ?i64 = null,
    reset_time: ?[]const u8 = null,
    message: ?[]const u8 = null,
};
const Session = struct { token: []const u8, created: i64, base: []const u8 };

const Reply = struct { status: std.http.Status, body: []u8 };

pub const Client = struct {
    io: Io,
    arena: std.mem.Allocator,
    cfg: config.Config,
    http: std.http.Client,
    base: []const u8 = api_default,
    token: ?[]const u8 = null,

    pub fn init(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: config.Config) Client {
        return .{ .io = io, .arena = arena, .cfg = cfg, .http = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
    }

    /// Candidates in API order; `rank` sorts them.
    pub fn search(c: *Client, q: SearchQuery) ![]Candidate {
        const arena = c.arena;
        var params: std.ArrayList(Param) = .empty;
        const sorted = try arena.dupe([]const u8, q.languages);
        std.mem.sort([]const u8, sorted, {}, stringLessThan);
        try params.append(arena, .{ .name = "languages", .value = try std.mem.join(arena, ",", sorted) });
        if (q.hash) |h| try params.append(arena, .{ .name = "moviehash", .value = try std.fmt.allocPrint(arena, "{x:0>16}", .{h}) });
        if (q.title.len > 0) try params.append(arena, .{ .name = "query", .value = q.title });
        const url = try std.fmt.allocPrint(arena, "{s}/subtitles?{s}", .{ api_default, try queryString(arena, params.items) });

        const reply = try c.request(.GET, url, null, null);
        if (reply.status != .ok) return c.apiError("search failed", reply);
        const sr = std.json.parseFromSliceLeaky(SearchReply, arena, reply.body, parse_options) catch return c.apiError("search failed", reply);

        var cands: std.ArrayList(Candidate) = .empty;
        for (sr.data orelse &.{}) |item| {
            const a = item.attributes orelse continue;
            const files = a.files orelse continue;
            if (files.len == 0) continue;
            const file_id = files[0].file_id orelse continue;
            const file_name = files[0].file_name orelse "";
            const fd = a.feature_details;
            try cands.append(arena, .{
                .file_id = file_id,
                .file_name = file_name,
                .lang = a.language orelse "",
                .release = a.release orelse (if (file_name.len > 0) file_name else "?"),
                .feature_id = if (fd) |f| f.feature_id else null,
                .feature = try featureLabel(arena, fd),
                .season = if (fd) |f| f.season_number else null,
                .episode = if (fd) |f| f.episode_number else null,
                .downloads = @intCast(@max(a.download_count orelse 0, 0)),
                .hash = if (a.moviehash_match == true) 1 else 0,
                .hi = a.hearing_impaired == true,
                .ai = a.ai_translated == true or a.machine_translated == true,
                .fps = jsonFps(a.fps),
            });
        }
        return cands.toOwnedSlice(arena);
    }

    /// Asks for a download link (logging in when needed, once more on a
    /// stale token) and fetches it. Each call spends one of the day's quota.
    pub fn download(c: *Client, file_id: u64) !Download {
        const arena = c.arena;
        if (c.token == null) c.loadSession();
        if (c.token == null) try c.login();
        const body = try std.json.Stringify.valueAlloc(arena, .{ .file_id = file_id }, .{});

        var attempt: u8 = 0;
        const reply = while (attempt < 2) : (attempt += 1) {
            const url = try std.fmt.allocPrint(arena, "{s}/download", .{c.base});
            const r = try c.request(.POST, url, body, c.token.?);
            if (r.status != .unauthorized) break r;
            try c.login();
        } else {
            log.warn("authentication failed", .{});
            return error.RequestFailed;
        };

        const dr = std.json.parseFromSliceLeaky(DownloadReply, arena, reply.body, parse_options) catch DownloadReply{};
        if (reply.status != .ok or dr.link == null) {
            if (dr.message) |m| log.warn("download refused: {s}{s}{s}", .{ m, if (dr.reset_time != null) "; quota resets " else "", dr.reset_time orelse "" }) else log.warn("download refused: HTTP {d}", .{@backingInt(reply.status)});
            return error.RequestFailed;
        }
        return .{ .bytes = try c.fetchBytes(dr.link.?), .file_name = dr.file_name orelse "", .remaining = dr.remaining };
    }

    fn request(c: *Client, method: std.http.Method, url: []const u8, payload: ?[]const u8, bearer: ?[]const u8) !Reply {
        var aw: Io.Writer.Allocating = .init(c.arena);
        const auth: std.http.Client.Request.Headers.Value = if (bearer) |t| .{ .override = try std.fmt.allocPrint(c.arena, "Bearer {s}", .{t}) } else .default;
        log.debug("{s} {s}", .{ @tagName(method), url });
        const res = c.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
                .authorization = auth,
            },
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "api-key", .value = c.cfg.api_key },
            },
            .response_writer = &aw.writer,
        }) catch |err| {
            log.warn("network error: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        log.debug("  -> {d} ({d} bytes)", .{ @backingInt(res.status), aw.written().len });
        if (res.status == .too_many_requests) {
            log.warn("rate limited by OpenSubtitles, retry in a minute", .{});
            return error.RequestFailed;
        }
        return .{ .status = res.status, .body = aw.written() };
    }

    /// The download link is a plain file URL: no API headers.
    fn fetchBytes(c: *Client, url: []const u8) ![]u8 {
        var aw: Io.Writer.Allocating = .init(c.arena);
        log.debug("GET {s}", .{url});
        const res = c.http.fetch(.{ .location = .{ .url = url }, .response_writer = &aw.writer }) catch |err| {
            log.warn("fetch failed: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        if (res.status != .ok) {
            log.warn("fetch failed: HTTP {d}", .{@backingInt(res.status)});
            return error.RequestFailed;
        }
        return aw.written();
    }

    fn apiError(c: *Client, what: []const u8, reply: Reply) error{RequestFailed} {
        const msg = std.json.parseFromSliceLeaky(Message, c.arena, reply.body, parse_options) catch Message{};
        if (msg.message) |m| log.warn("{s}: {s}", .{ what, m }) else log.warn("{s}: HTTP {d}", .{ what, @backingInt(reply.status) });
        return error.RequestFailed;
    }

    fn login(c: *Client) !void {
        const arena = c.arena;
        if (c.cfg.username.len == 0 or c.cfg.password.len == 0) {
            log.warn("no username/password: set them in {s} or OPENSUBTITLES_USERNAME/OPENSUBTITLES_PASSWORD", .{c.cfg.path});
            return error.NoCredentials;
        }
        const body = try std.json.Stringify.valueAlloc(arena, .{ .username = c.cfg.username, .password = c.cfg.password }, .{});
        const reply = try c.request(.POST, api_default ++ "/login", body, null);
        if (reply.status == .unauthorized) {
            log.warn("bad credentials (check {s})", .{c.cfg.path});
            return error.RequestFailed;
        }
        if (reply.status != .ok) return c.apiError("login failed", reply);
        const lr = std.json.parseFromSliceLeaky(LoginReply, arena, reply.body, parse_options) catch return c.apiError("login failed", reply);
        c.token = lr.token orelse return c.apiError("login failed", reply);
        c.base = try apiBase(arena, lr.base_url orelse "");
        c.saveSession();
    }

    fn tokenPath(c: *Client) ![]const u8 {
        return std.fs.path.join(c.arena, &.{ c.cfg.cache_dir, "token.json" });
    }

    fn loadSession(c: *Client) void {
        const path = c.tokenPath() catch return;
        const text = Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(4096)) catch return;
        const s = std.json.parseFromSliceLeaky(Session, c.arena, text, parse_options) catch return;
        if (!sessionFresh(s.created, Io.Clock.real.now(c.io).toSeconds())) return;
        c.token = s.token;
        c.base = s.base;
    }

    fn saveSession(c: *Client) void {
        const s: Session = .{ .token = c.token.?, .created = Io.Clock.real.now(c.io).toSeconds(), .base = c.base };
        const path = c.tokenPath() catch return;
        const text = std.json.Stringify.valueAlloc(c.arena, s, .{}) catch return;
        Io.Dir.cwd().createDirPath(c.io, c.cfg.cache_dir) catch |err| {
            log.debug("cannot create {s}: {s}", .{ c.cfg.cache_dir, @errorName(err) });
            return;
        };
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = text }) catch |err| {
            log.debug("cannot write {s}: {s}", .{ path, @errorName(err) });
        };
    }
};

fn sessionFresh(created: i64, now: i64) bool {
    return now >= created and now - created < token_max_age_s;
}

/// The session base from `/login`'s `base_url`. Anything on the default
/// domain (vip-api included, as jamak does) stays on the default; another
/// host gets the scheme and path.
fn apiBase(arena: std.mem.Allocator, host: []const u8) ![]const u8 {
    if (host.len == 0 or std.mem.find(u8, host, "api.opensubtitles.com") != null) return api_default;
    const scheme: []const u8 = if (std.mem.find(u8, host, "://") == null) "https://" else "";
    return std.fmt.allocPrint(arena, "{s}{s}/api/v1", .{ scheme, host });
}

fn jsonFps(v: std.json.Value) ?f64 {
    const f: f64 = switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch return null,
        else => return null,
    };
    return if (f > 0) f else null;
}

fn featureLabel(arena: std.mem.Allocator, fd: ?FeatureDetails) !?[]const u8 {
    const f = fd orelse return null;
    const title = f.title orelse return null;
    if (f.parent_title) |parent| if (std.mem.eql(u8, f.feature_type orelse "", "Episode")) {
        if (f.season_number) |season| if (f.episode_number) |ep| return try std.fmt.allocPrint(arena, "{s} S{d:0>2}E{d:0>2}", .{ parent, season, ep });
        if (f.episode_number) |ep| return try std.fmt.allocPrint(arena, "{s} E{d:0>2}", .{ parent, ep });
        return parent;
    };
    if (f.year) |y| return try std.fmt.allocPrint(arena, "{s} ({d})", .{ title, y });
    return title;
}

const Param = struct { name: []const u8, value: []const u8 };

/// Keys sorted, values lowercased and percent-encoded with `+` for space:
/// the canonical form the API otherwise redirects to.
fn queryString(arena: std.mem.Allocator, params: []const Param) ![]u8 {
    const sorted = try arena.dupe(Param, params);
    std.mem.sort(Param, sorted, {}, paramLessThan);
    var out: std.ArrayList(u8) = .empty;
    for (sorted, 0..) |p, i| {
        if (i > 0) try out.append(arena, '&');
        try out.appendSlice(arena, p.name);
        try out.append(arena, '=');
        for (p.value) |raw| {
            const c = std.ascii.toLower(raw);
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
                try out.append(arena, c);
            } else if (c == ' ') {
                try out.append(arena, '+');
            } else {
                try out.print(arena, "%{X:0>2}", .{c});
            }
        }
    }
    return out.toOwnedSlice(arena);
}

fn paramLessThan(_: void, a: Param, b: Param) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const RankOptions = struct {
    languages: []const []const u8,
    prefer_hi: bool,
    /// The video's own episode code, to spot hash matches that name another one.
    episode: ?release.Episode,
};

/// Promotes the hash matches that agree on a feature, then sorts. The vote is
/// a plurality among hash matches that do not contradict the file's episode
/// code; a tie promotes nobody.
pub fn rank(cands: []Candidate, opts: RankOptions) void {
    var top: ?u64 = null;
    var top_n: usize = 0;
    var tied = false;
    for (cands) |c| {
        const fid = voterFeature(c, opts.episode) orelse continue;
        var n: usize = 0;
        for (cands) |o| if (voterFeature(o, opts.episode) == fid) {
            n += 1;
        };
        if (n > top_n) {
            top_n = n;
            top = fid;
            tied = false;
        } else if (n == top_n and top != fid) {
            tied = true;
        }
    }
    if (top != null and !tied) {
        for (cands) |*c| if (c.hash > 0 and c.feature_id == top) {
            c.hash = 2;
        };
    }
    std.mem.sort(Candidate, cands, opts, lessThan);
}

fn voterFeature(c: Candidate, episode: ?release.Episode) ?u64 {
    if (c.hash == 0) return null;
    const fid = c.feature_id orelse return null;
    if (episode) |ep| if (c.season != null and c.episode != null) {
        if (c.season.? != ep.season or c.episode.? != ep.episode) return null;
    };
    return fid;
}

fn langPriority(languages: []const []const u8, lang: []const u8) usize {
    for (languages, 0..) |l, i| if (std.mem.eql(u8, l, lang)) return i;
    return 99;
}

fn lessThan(opts: RankOptions, a: Candidate, b: Candidate) bool {
    if (a.hash != b.hash) return a.hash > b.hash;
    const pa = langPriority(opts.languages, a.lang);
    const pb = langPriority(opts.languages, b.lang);
    if (pa != pb) return pa < pb;
    if (a.ai != b.ai) return !a.ai;
    if (a.fps_mismatch != b.fps_mismatch) return !a.fps_mismatch;
    if (a.hi != b.hi) return a.hi == opts.prefer_hi;
    return a.downloads > b.downloads;
}

test "query string is canonical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try queryString(arena.allocator(), &.{
        .{ .name = "query", .value = "The Movie" },
        .{ .name = "languages", .value = "ko,en" },
        .{ .name = "moviehash", .value = "00ab" },
    });
    try std.testing.expectEqualStrings("languages=ko%2Cen&moviehash=00ab&query=the+movie", q);
    try std.testing.expectEqualStrings("q=a-b.c_d~", try queryString(arena.allocator(), &.{.{ .name = "q", .value = "a-b.c_d~" }}));
}

test "api base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(api_default, try apiBase(arena.allocator(), ""));
    try std.testing.expectEqualStrings(api_default, try apiBase(arena.allocator(), "api.opensubtitles.com"));
    try std.testing.expectEqualStrings(api_default, try apiBase(arena.allocator(), "vip-api.opensubtitles.com"));
    try std.testing.expectEqualStrings("https://other.example/api/v1", try apiBase(arena.allocator(), "other.example"));
    try std.testing.expectEqualStrings("http://x/api/v1", try apiBase(arena.allocator(), "http://x"));
}

test "session freshness" {
    try std.testing.expect(sessionFresh(1000, 1000 + token_max_age_s - 1));
    try std.testing.expect(!sessionFresh(1000, 1000 + token_max_age_s));
    try std.testing.expect(!sessionFresh(1000, 999));
}

fn cand(id: u64, lang: []const u8, hash: u2, fid: ?u64) Candidate {
    return .{
        .file_id = id,
        .file_name = "",
        .lang = lang,
        .release = "rel",
        .feature_id = fid,
        .feature = null,
        .season = null,
        .episode = null,
        .downloads = 0,
        .hash = hash,
        .hi = false,
        .ai = false,
        .fps = null,
    };
}

test "rank promotes the feature the hash matches agree on" {
    var cands = [_]Candidate{ cand(1, "en", 1, 7), cand(2, "en", 1, 9), cand(3, "en", 1, 7), cand(4, "en", 0, 7) };
    rank(&cands, .{ .languages = &.{"en"}, .prefer_hi = false, .episode = null });
    try std.testing.expectEqual(@as(u2, 2), cands[0].hash);
    try std.testing.expectEqual(@as(u2, 2), cands[1].hash);
    try std.testing.expectEqual(@as(u2, 1), cands[2].hash);
    try std.testing.expectEqual(@as(u64, 2), cands[2].file_id);
    try std.testing.expectEqual(@as(u2, 0), cands[3].hash);
}

test "rank: a tie promotes nobody, a contradicting episode does not vote" {
    var tie = [_]Candidate{ cand(1, "en", 1, 7), cand(2, "en", 1, 9) };
    rank(&tie, .{ .languages = &.{"en"}, .prefer_hi = false, .episode = null });
    try std.testing.expectEqual(@as(u2, 1), tie[0].hash);
    try std.testing.expectEqual(@as(u2, 1), tie[1].hash);

    var c = [_]Candidate{ cand(1, "en", 1, 7), cand(2, "en", 1, 9) };
    c[0].season = 1;
    c[0].episode = 3;
    rank(&c, .{ .languages = &.{"en"}, .prefer_hi = false, .episode = .{ .season = 1, .episode = 2 } });
    try std.testing.expectEqual(@as(u64, 2), c[0].file_id);
    try std.testing.expectEqual(@as(u2, 2), c[0].hash);
    try std.testing.expectEqual(@as(u2, 1), c[1].hash);
}

test "rank order: language, ai, fps, hi, downloads" {
    var c = [_]Candidate{ cand(1, "en", 0, null), cand(2, "ko", 0, null), cand(3, "ko", 0, null), cand(4, "ko", 0, null), cand(5, "ko", 0, null), cand(6, "fr", 0, null) };
    c[2].ai = true;
    c[3].fps_mismatch = true;
    c[1].downloads = 5;
    c[4].downloads = 50;
    c[4].hi = true;
    rank(&c, .{ .languages = &.{ "ko", "en" }, .prefer_hi = false, .episode = null });
    const order = [_]u64{ 2, 5, 4, 3, 1, 6 };
    for (order, c) |want, got| try std.testing.expectEqual(want, got.file_id);
    rank(&c, .{ .languages = &.{ "ko", "en" }, .prefer_hi = true, .episode = null });
    try std.testing.expectEqual(@as(u64, 5), c[0].file_id);
}
