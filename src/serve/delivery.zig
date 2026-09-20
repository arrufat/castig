//! How one source reaches the receiver: the HTTP routes that serve it and the
//! description of what to LOAD.
//!
//! A direct file is one static route. A file whose audio must be transcoded
//! gets the route of the chosen `Remux` mode, and the demuxer that `plan`
//! already opened is handed to whichever mode can reuse it. Subtitle tracks,
//! embedded and side-loaded, are routes too.

const std = @import("std");
const Io = std.Io;
const av = @import("av");

const Env = @import("../env.zig").Env;
const language = @import("../language.zig");
const channel = @import("../device/channel.zig");
const http = @import("server.zig");
const hls = @import("../media/hls.zig");
const pipeline = @import("../media/pipeline.zig");
const vmp4 = @import("../media/vmp4.zig");
const webvtt = @import("../media/webvtt.zig");

const log = std.log.scoped(.cast);

/// How to deliver a file whose audio must be remuxed.
pub const Remux = enum {
    /// HLS first (instant + seek); if the receiver refuses it, mp4.
    auto,
    /// On-demand HLS (MPEG-TS), instant + native seek. Best for video up to
    /// ~720p; some receivers refuse higher-resolution HLS-TS.
    hls,
    /// On-the-fly seekable MP4 (no temp file). Plays where HLS is refused and
    /// seeks natively, but starts after a one-time pass over the source.
    mp4,
    /// Fragmented-MP4 live stream. Instant start, no seek.
    stream,
};

/// What the receiver is told to LOAD: a served route (until `base` is
/// prepended) or a URL it fetches itself.
pub const Target = struct {
    path: []const u8,
    content_type: []const u8,
    /// HLS with MPEG-TS segments, which the receiver must be told about.
    hls: bool = false,
};

pub fn isUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

const mp4_path = "/media.mp4";
const mp4_type = "video/mp4";

/// Streams a fragmented-MP4 (`--remux stream`) as it is muxed.
const StreamCtx = struct { gpa: std.mem.Allocator, path: []const u8 };

fn streamHandle(context: *const anyopaque, request: *http.Request, _: []const u8) anyerror!void {
    const c: *const StreamCtx = @ptrCast(@alignCast(context));
    if (request.head.method == .HEAD) return http.respondHead(request, mp4_type);
    var buf: [64 * 1024]u8 = undefined;
    var body = try http.beginStream(request, &buf, mp4_type);
    pipeline.remuxFile(c.gpa, c.path, .fmp4, &body.writer) catch |err| {
        log.debug("stream aborted: {s}", .{@errorName(err)});
        return;
    };
    try body.end();
}

fn vmp4ReadFn(ctx: *anyopaque, offset: u64, dest: []u8) anyerror!void {
    const vm: *vmp4.VMp4 = @ptrCast(@alignCast(ctx));
    try vm.readInto(offset, dest);
}

fn vmp4Handle(context: *const anyopaque, request: *http.Request, _: []const u8) anyerror!void {
    const vm: *vmp4.VMp4 = @ptrCast(@alignCast(@constCast(context)));
    try http.respondVirtual(request, mp4_type, vm.total, vm, vmp4ReadFn);
}

/// The text subtitle streams embedded in the source, all converted to WebVTT
/// in one pass over the file the first time any of them is requested.
const EmbeddedSubtitles = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    indices: []const usize,
    mutex: Io.Mutex = .init,
    cached: ?[]const []u8 = null,

    fn vtt(self: *EmbeddedSubtitles, slot: usize) ![]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.cached == null) self.cached = try pipeline.extractSubtitles(self.gpa, self.path, self.indices);
        return self.cached.?[slot];
    }

    fn deinit(self: *EmbeddedSubtitles) void {
        if (self.cached) |tracks| {
            for (tracks) |t| self.gpa.free(t);
            self.gpa.free(tracks);
        }
    }
};

const EmbeddedSubtitleRoute = struct { subs: *EmbeddedSubtitles, slot: usize };

fn embSubHandle(context: *const anyopaque, request: *http.Request, _: []const u8) anyerror!void {
    const r: *const EmbeddedSubtitleRoute = @ptrCast(@alignCast(context));
    const body = r.subs.vtt(r.slot) catch |err| {
        log.debug("subtitle extract failed: {s}", .{@errorName(err)});
        return request.respond("subtitle extract failed\n", .{ .status = .internal_server_error, .extra_headers = http.cors });
    };
    try http.respondBuffer(request, "text/vtt", body);
}

/// The routes of one cast, the text tracks they back, and the gpa-owned state
/// behind them. Route contexts live in the arena; the segmenter, mp4 assembler
/// and subtitle cache are freed by `deinit`, after the server has stopped.
pub const Routes = struct {
    env: Env,
    source: []const u8,
    list: std.ArrayList(http.Route) = .empty,
    tracks: std.ArrayList(channel.Channel.TextTrack) = .empty,
    active: std.ArrayList(u32) = .empty,
    segmenter: ?*hls.Segmenter = null,
    mp4: ?*vmp4.VMp4 = null,
    embedded: ?*EmbeddedSubtitles = null,

    pub fn deinit(s: *Routes) void {
        if (s.segmenter) |seg| {
            seg.deinit();
            s.env.gpa.destroy(seg);
        }
        if (s.mp4) |vm| vm.deinit();
        if (s.embedded) |e| e.deinit();
    }

    fn addRoute(s: *Routes, path: []const u8, context: *const anyopaque, handle: @FieldType(http.Route.Dynamic, "handle")) !void {
        try s.list.append(s.env.arena, .{ .path = path, .body = .{ .dynamic = .{ .context = context, .handle = handle } } });
    }

    /// The source as it is, with Range support.
    pub fn addFile(s: *Routes, content_type: []const u8) !Target {
        const path = try s.env.arena.print("/media{s}", .{Io.Dir.path.extension(s.source)});
        try s.list.append(s.env.arena, .{
            .path = path,
            .body = .{ .file = .{ .content_type = content_type, .data = s.source } },
        });
        return .{ .path = path, .content_type = content_type };
    }

    /// The fragmented-MP4 live stream (instant, no seek). Used by `--remux
    /// stream` and as the `--remux mp4` fallback.
    pub fn addStream(s: *Routes) !Target {
        const c = try s.env.arena.create(StreamCtx);
        c.* = .{ .gpa = s.env.gpa, .path = s.source };
        try s.addRoute(mp4_path, c, streamHandle);
        return .{ .path = mp4_path, .content_type = mp4_type };
    }

    /// The on-the-fly seekable mp4, or the no-seek stream if the file cannot
    /// be made seekable byte-exactly. Takes ownership of `ic`.
    pub fn addMp4(s: *Routes, ic: *av.FormatContext) !Target {
        const vm = vmp4.build(s.env.gpa, s.env.io, s.source, ic, s.env.progress) catch |err| switch (err) {
            error.NoVideoStream, error.NoAudioStream, error.VideoNotAddressable, error.MuxerInterleaved, error.SeamMismatch => {
                log.warn("this file cannot be made seekable without a copy ({s}); serving without seek", .{@errorName(err)});
                return s.addStream();
            },
            else => return err,
        };
        errdefer vm.deinit();
        try s.addRoute(mp4_path, vm, vmp4Handle);
        s.mp4 = vm;
        return .{ .path = mp4_path, .content_type = mp4_type };
    }

    /// On-demand HLS. Takes ownership of `ic`.
    pub fn addHls(s: *Routes, ic: *av.FormatContext) !Target {
        const seg = try s.env.gpa.create(hls.Segmenter);
        errdefer s.env.gpa.destroy(seg);
        seg.* = try hls.Segmenter.init(s.env.gpa, s.env.io, s.source, ic);
        errdefer seg.deinit();
        try s.addRoute(hls.url_prefix, seg, hls.handleRoute);
        s.segmenter = seg;
        return .{ .path = hls.url_prefix ++ hls.master_name, .content_type = hls.cast_content_type, .hls = true };
    }

    /// The `--subs` / sidecar / downloaded track, enabled from the start.
    /// A known language names it, so the receiver's menu reads "English"
    /// rather than "Subtitles".
    pub fn addSideloaded(s: *Routes, sub: []const u8, lang: ?[]const u8) !void {
        const arena = s.env.arena;
        const url = if (isUrl(sub)) sub else blk: {
            const srt = Io.Dir.cwd().readFileAlloc(s.env.io, sub, arena, .limited(16 * 1024 * 1024)) catch |err| {
                log.warn("cannot read {s}: {s}", .{ sub, @errorName(err) });
                return error.SourceUnreadable;
            };
            try s.list.append(arena, .{
                .path = "/sub.vtt",
                .body = .{ .bytes = .{ .content_type = "text/vtt", .data = try webvtt.srtToVtt(arena, srt) } },
            });
            break :blk "/sub.vtt";
        };
        const id: u32 = @intCast(s.tracks.items.len + 1);
        try s.tracks.append(arena, .{
            .id = id,
            .url = url,
            .language = lang orelse "und",
            .name = if (lang) |l| language.name(l) else "Subtitles",
        });
        try s.active.append(arena, id);
    }

    /// One route per embedded text subtitle stream, all extracted together.
    pub fn addEmbeddedSubtitles(s: *Routes, streams: []const pipeline.SubtitleStream) !void {
        if (streams.len == 0) return;
        const arena = s.env.arena;
        const indices = try arena.alloc(usize, streams.len);
        for (streams, 0..) |e, i| indices[i] = e.index;
        const embedded = try arena.create(EmbeddedSubtitles);
        embedded.* = .{ .gpa = s.env.gpa, .io = s.env.io, .path = s.source, .indices = indices };
        s.embedded = embedded;

        for (streams, 0..) |e, slot| {
            const path = try arena.print("/embsub{d}.vtt", .{e.index});
            const route = try arena.create(EmbeddedSubtitleRoute);
            route.* = .{ .subs = embedded, .slot = slot };
            try s.addRoute(path, route, embSubHandle);
            const name = if (e.title.len > 0)
                e.title
            else if (!std.mem.eql(u8, e.language, "und"))
                language.name(e.language)
            else
                "Subtitles";
            try s.tracks.append(arena, .{ .id = @intCast(s.tracks.items.len + 1), .url = path, .language = e.language, .name = name });
        }
        log.info("found {d} embedded subtitle track(s); pick one from the receiver's subtitle menu", .{streams.len});
    }

    /// Route paths are relative until the server is listening and its address
    /// is known; the receiver needs absolute URLs.
    pub fn absolutise(s: *Routes, base: []const u8, target: *Target, local: bool) !void {
        const arena = s.env.arena;
        if (local) target.path = try std.mem.concat(arena, u8, &.{ base, target.path });
        for (s.tracks.items) |*t| if (!isUrl(t.url)) {
            t.url = try std.mem.concat(arena, u8, &.{ base, t.url });
        };
    }
};

/// The MIME type for a path or URL, by extension. Receivers reject a LOAD
/// whose contentType they do not recognise, so an unknown extension gets the
/// most likely one rather than nothing.
pub fn guessContentType(url: []const u8) []const u8 {
    const ext = Io.Dir.path.extension(std.mem.sliceTo(url, '?'));
    const table = std.StaticStringMap([]const u8).initComptime(.{
        .{ ".mp4", "video/mp4" },
        .{ ".m4v", "video/mp4" },
        .{ ".webm", "video/webm" },
        .{ ".mkv", "video/x-matroska" },
        .{ ".m3u8", "application/x-mpegURL" },
        .{ ".mpd", "application/dash+xml" },
        .{ ".mp3", "audio/mpeg" },
        .{ ".aac", "audio/aac" },
        .{ ".flac", "audio/flac" },
        .{ ".ogg", "audio/ogg" },
        .{ ".opus", "audio/ogg" },
        .{ ".wav", "audio/wav" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".png", "image/png" },
    });
    return table.get(ext) orelse "video/mp4";
}

test "content type guess" {
    try std.testing.expectEqualStrings("video/webm", guessContentType("http://h/a.webm?x=1"));
    try std.testing.expectEqualStrings("video/mp4", guessContentType("http://h/noext"));
    try std.testing.expectEqualStrings("audio/mpeg", guessContentType("http://h/song.mp3"));
}

test "url detection" {
    try std.testing.expect(isUrl("https://h/a.mp4"));
    try std.testing.expect(isUrl("http://h/a.mp4"));
    try std.testing.expect(!isUrl("/home/a.mkv"));
}
