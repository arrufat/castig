//! `status`, `cast` and `stop`: the commands that drive a receiver.

const std = @import("std");
const Io = std.Io;
const discovery = @import("discovery.zig");
const channel = @import("cast/channel.zig");
const Channel = channel.Channel;
const http = @import("http/server.zig");
const subtitles = @import("media/subtitles.zig");
const pipeline = @import("media/pipeline.zig");
const hls = @import("media/hls.zig");
const vmp4 = @import("media/vmp4.zig");

/// Shared by every command that opens a channel.
pub const Options = struct {
    /// Dump the messages exchanged with the receiver on stderr (CASTIG_DEBUG).
    debug: bool = false,
};

pub fn status(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, options: Options) !void {
    const address = try discovery.resolve(io, arena, device);
    const ch = try Channel.connect(io, arena, address, .{ .debug = options.debug });
    defer ch.deinit();

    const st = try ch.getStatus(arena);
    try out.print("{f}\n", .{address});
    try out.print("  volume: {d:.0}%{s}\n", .{ st.volume_level * 100, if (st.muted) " (muted)" else "" });
    if (st.apps.len == 0) try out.writeAll("  no app running\n");
    for (st.apps) |a| {
        try out.print("  app: {s} ({s}){s}", .{ a.display_name, a.app_id, if (a.is_idle_screen) " idle screen" else "" });
        if (a.status_text.len > 0) try out.print(" - {s}", .{a.status_text});
        try out.print("\n       session {s}, transport {s}\n", .{ a.session_id, a.transport_id });
    }
}

pub fn stop(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, options: Options) !void {
    const address = try discovery.resolve(io, arena, device);
    const ch = try Channel.connect(io, arena, address, .{ .debug = options.debug });
    defer ch.deinit();

    const st = try ch.getStatus(arena);
    var stopped: usize = 0;
    for (st.apps) |a| {
        if (a.is_idle_screen) continue;
        try ch.stopApp(arena, a.session_id);
        try out.print("stopped {s}\n", .{a.display_name});
        stopped += 1;
    }
    if (stopped == 0) try out.writeAll("nothing to stop\n");
}

/// How to deliver a file whose audio must be remuxed.
pub const Remux = enum {
    /// Pick by resolution: hls for video up to ~720p (instant + seek), mp4
    /// above that (seekable where hls is refused). The default.
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

pub const CastOptions = struct {
    /// http(s) URL the receiver fetches itself, or a local path castig serves.
    source: []const u8,
    title: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// WebVTT URL, or a local .srt/.vtt file castig converts and serves.
    subtitles: ?[]const u8 = null,
    remux: Remux = .auto,
};

fn isUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

/// Streams a fragmented-MP4 (`--remux stream`) as it is muxed.
const StreamCtx = struct { gpa: std.mem.Allocator, path: []const u8 };

fn streamHandle(context: *const anyopaque, s: *http.Server, request: *http.Request) anyerror!void {
    const c: *const StreamCtx = @ptrCast(@alignCast(context));
    if (request.head.method == .HEAD) return http.respondHead(request, "video/mp4");
    var buf: [64 * 1024]u8 = undefined;
    var body = try http.beginStream(request, &buf, "video/mp4");
    pipeline.remuxWindow(c.gpa, c.path, 0, null, "mp4", &body.writer) catch |err| {
        if (s.debug) std.debug.print("stream aborted: {s}\n", .{@errorName(err)});
        return;
    };
    try body.end();
}

fn vmp4ReadFn(ctx: *anyopaque, offset: u64, dest: []u8) anyerror!void {
    const vm: *vmp4.VMp4 = @ptrCast(@alignCast(ctx));
    try vm.readInto(offset, dest);
}

fn vmp4Handle(context: *const anyopaque, s: *http.Server, request: *http.Request) anyerror!void {
    _ = s;
    const vm: *vmp4.VMp4 = @constCast(@ptrCast(@alignCast(context)));
    try http.respondVirtual(request, "video/mp4", vm.totalSize(), vm, vmp4ReadFn);
}

/// Registers the fragmented-MP4 live-stream route at /media.mp4 (instant, no
/// seek). Used by `--remux stream` and as the `--remux mp4` fallback.
fn addStreamRoute(arena: std.mem.Allocator, routes: *std.ArrayList(http.Route), source: []const u8) !void {
    const c = try arena.create(StreamCtx);
    c.* = .{ .gpa = arena, .path = source };
    try routes.append(arena, .{
        .path = "/media.mp4",
        .content_type = "video/mp4",
        .body = .{ .dynamic = .{ .context = c, .handle = streamHandle } },
    });
}

/// Registers the on-the-fly seekable-mp4 route at /media.mp4, or the no-seek
/// stream route if the file cannot be made seekable byte-exactly.
fn addMp4Route(arena: std.mem.Allocator, io: Io, routes: *std.ArrayList(http.Route), source: []const u8, debug: bool) !void {
    if (try vmp4.build(arena, io, source, debug)) |vm| {
        try routes.append(arena, .{
            .path = "/media.mp4",
            .content_type = "video/mp4",
            .body = .{ .dynamic = .{ .context = vm, .handle = vmp4Handle } },
        });
    } else {
        std.debug.print("note: this file cannot be made seekable without a copy; serving without seek.\n", .{});
        try addStreamRoute(arena, routes, source);
    }
}

/// One embedded subtitle stream, converted to WebVTT the first time the
/// receiver asks for it (scanning the source), then cached.
const EmbSubCtx = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    stream_index: usize,
    cached: ?[]const u8 = null,
};

fn embSubHandle(context: *const anyopaque, s: *http.Server, request: *http.Request) anyerror!void {
    const c: *EmbSubCtx = @constCast(@ptrCast(@alignCast(context)));
    if (c.cached == null) {
        c.cached = pipeline.extractSubtitle(c.gpa, c.path, c.stream_index) catch |err| {
            if (s.debug) std.debug.print("subtitle extract failed: {s}\n", .{@errorName(err)});
            return request.respond("subtitle extract failed\n", .{ .status = .internal_server_error, .extra_headers = http.cors });
        };
    }
    try http.respondBuffer(request, "text/vtt", c.cached.?);
}

/// Launches the default media receiver, loads the source and follows
/// playback until it ends. Local files are served from a built-in HTTP
/// server for as long as the session lasts.
pub fn cast(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, opts: CastOptions, options: Options) !void {
    const address = try discovery.resolve(io, arena, device);

    // Routes for whatever must be served locally.
    var routes: std.ArrayList(http.Route) = .empty;
    var media_path: []const u8 = opts.source;
    var text_tracks: std.ArrayList(Channel.TextTrack) = .empty;
    var active_tracks: std.ArrayList(u32) = .empty;
    var next_track_id: u32 = 1;
    var media_content_type: []const u8 = opts.content_type orelse guessContentType(opts.source);
    var duration: ?f64 = null;
    // Also true for an HLS URL the receiver fetches directly, so it gets the
    // MPEG-TS segment hint too.
    var is_hls = std.ascii.findIgnoreCase(media_content_type, "mpegurl") != null;
    // Embedded text subtitle streams, discovered by plan() for a local source.
    var embedded_subs: []const pipeline.SubtitleStream = &.{};

    if (!isUrl(opts.source)) {
        Io.Dir.cwd().access(io, opts.source, .{}) catch |err| {
            std.debug.print("cannot read {s}: {s}\n", .{ opts.source, @errorName(err) });
            return error.SourceUnreadable;
        };
        const p = try pipeline.plan(arena, opts.source);
        duration = p.duration;
        embedded_subs = p.subtitles;
        if (p.video_unsupported) {
            std.debug.print("warning: {s} video is not castable and video transcoding is not implemented; trying direct\n", .{p.video_codec});
        }
        if (p.direct or p.video_unsupported) {
            const ext = std.fs.path.extension(opts.source);
            media_path = try std.fmt.allocPrint(arena, "/media{s}", .{ext});
            try routes.append(arena, .{
                .path = media_path,
                .content_type = media_content_type,
                .body = .{ .file = opts.source },
            });
        } else switch (opts.remux) {
            // Auto starts with HLS (instant + seek); if the receiver refuses it
            // (e.g. high-resolution HLS-TS), the load below falls back to mp4.
            .auto, .hls => {
                std.debug.print("remuxing {s} audio to aac (hls)\n", .{p.audio_codec});
                const seg = try arena.create(hls.Segmenter);
                seg.* = try hls.Segmenter.init(arena, opts.source);
                media_path = hls.url_prefix ++ hls.master_name;
                media_content_type = hls.cast_content_type;
                is_hls = true;
                try routes.append(arena, .{
                    .path = hls.url_prefix,
                    .content_type = hls.cast_content_type,
                    .body = .{ .dynamic = .{ .context = seg, .handle = hls.handleRoute } },
                });
            },
            .stream => {
                // Fragmented-MP4 live stream: instant, no seek.
                std.debug.print("remuxing {s} audio to aac (fragmented mp4, no seek)\n", .{p.audio_codec});
                media_path = "/media.mp4";
                media_content_type = "video/mp4";
                try addStreamRoute(arena, &routes, opts.source);
            },
            .mp4 => {
                // Seekable MP4 assembled on the fly: video copied, audio to AAC
                // in memory, moov precomputed for byte-range seeking. No temp.
                // addMp4Route shows a std.Progress bar during the build pass.
                try out.flush();
                media_path = "/media.mp4";
                media_content_type = "video/mp4";
                try addMp4Route(arena, io, &routes, opts.source, options.debug);
            },
        }
    }
    // Subtitles: an explicit --subs track (a file converted to WebVTT, or a
    // URL), enabled by default; plus any text subtitle streams embedded in a
    // local source, advertised but off by default and extracted on demand.
    if (opts.subtitles) |sub| {
        const url = if (isUrl(sub)) sub else blk: {
            const srt = Io.Dir.cwd().readFileAlloc(io, sub, arena, .limited(16 * 1024 * 1024)) catch |err| {
                std.debug.print("cannot read {s}: {s}\n", .{ sub, @errorName(err) });
                return error.SourceUnreadable;
            };
            try routes.append(arena, .{
                .path = "/sub.vtt",
                .content_type = "text/vtt",
                .body = .{ .bytes = try subtitles.srtToVtt(arena, srt) },
            });
            break :blk "/sub.vtt";
        };
        const id = next_track_id;
        next_track_id += 1;
        try text_tracks.append(arena, .{ .id = id, .url = url, .name = "Subtitles" });
        try active_tracks.append(arena, id);
    }
    for (embedded_subs) |e| {
        const id = next_track_id;
        next_track_id += 1;
        const path = try std.fmt.allocPrint(arena, "/embsub{d}.vtt", .{e.index});
        const ctx = try arena.create(EmbSubCtx);
        ctx.* = .{ .gpa = arena, .path = opts.source, .stream_index = e.index };
        try routes.append(arena, .{
            .path = path,
            .content_type = "text/vtt",
            .body = .{ .dynamic = .{ .context = ctx, .handle = embSubHandle } },
        });
        const name = if (e.title.len > 0)
            e.title
        else if (!std.mem.eql(u8, e.language, "und"))
            subtitles.languageName(e.language)
        else
            "Subtitles";
        try text_tracks.append(arena, .{ .id = id, .url = path, .language = e.language, .name = name });
    }
    if (embedded_subs.len > 0) {
        std.debug.print("found {d} embedded subtitle track(s); pick one from the receiver's subtitle menu\n", .{embedded_subs.len});
    }

    // Connect only now: a `--remux mp4` transcode above can take minutes, and
    // an idle control channel gets dropped by the receiver (unanswered
    // heartbeat PINGs), which then surfaces as ConnectionClosed on the first
    // request. Opening it after the heavy work keeps it live through LOAD.
    var ch = try Channel.connect(io, arena, address, .{ .debug = options.debug });
    defer ch.deinit();

    var server: ?*http.Server = null;
    defer if (server) |s| s.stop();
    var base: []const u8 = "";
    if (routes.items.len > 0) {
        const s = try http.Server.start(io, arena, routes.items, options.debug);
        server = s;
        const ip = try ch.localIp4();
        base = try std.fmt.allocPrint(arena, "http://{d}.{d}.{d}.{d}:{d}", .{ ip[0], ip[1], ip[2], ip[3], s.port });
        if (!isUrl(opts.source)) media_path = try std.mem.concat(arena, u8, &.{ base, media_path });
        for (text_tracks.items) |*t| if (!isUrl(t.url)) {
            t.url = try std.mem.concat(arena, u8, &.{ base, t.url });
        };
        try out.print("serving at {s}\n", .{base});
        try out.flush();
    }

    const title = opts.title orelse (if (isUrl(opts.source)) null else std.fs.path.basename(opts.source));
    var st = try ch.getStatus(arena);
    var app = st.find(channel.default_media_receiver) orelse try ch.launch(arena, channel.default_media_receiver);
    try ch.connectTransport(app.transport_id);

    var media = try ch.load(arena, app.transport_id, .{
        .url = media_path,
        .content_type = media_content_type,
        .title = title,
        .text_tracks = text_tracks.items,
        .active_track_ids = active_tracks.items,
        .duration = duration,
        .hls = is_hls,
    });

    session: while (true) {
        try out.print("loaded on {f} as {s}\n", .{ address, media_content_type });
        try printMedia(out, media);
        try out.flush();

        // Follow MEDIA_STATUS until the item finishes, noting if it ever played.
        var played = false;
        while (!media.isFinished()) {
            const msg = ch.receive() catch |err| switch (err) {
                // The receiver hanging up (a TCP FIN rather than a CLOSE message)
                // is the normal end of a session, not a failure.
                error.ConnectionClosed => {
                    try out.writeAll("receiver closed the session\n");
                    return;
                },
                else => return err,
            };
            if (std.mem.eql(u8, msg.namespace, channel.ns_connection)) {
                if (std.mem.indexOf(u8, msg.payload.utf8, "\"CLOSE\"") != null) {
                    try out.writeAll("receiver closed the session\n");
                    return;
                }
                continue;
            }
            if (!std.mem.eql(u8, msg.namespace, channel.ns_media)) continue;
            const json = try Channel.parsePayload(arena, msg);
            media = Channel.mediaStatusFrom(json) orelse continue;
            if (std.mem.eql(u8, media.player_state, "PLAYING")) played = true;
            try printMedia(out, media);
            try out.flush();
        }

        // Auto mode: the receiver accepts the HLS load, then fails it
        // asynchronously (LOAD_FAILED / idleReason ERROR) before playback ever
        // starts. If it never played, build a seekable mp4 and load that. The
        // mp4 build can take a while, so close the idle channel and reconnect.
        const errored = std.mem.eql(u8, media.idle_reason orelse "", "ERROR");
        if (!played and errored and opts.remux == .auto and is_hls and !isUrl(opts.source)) {
            std.debug.print("receiver refused HLS; falling back to seekable mp4 ...\n", .{});
            try out.flush();
            ch.deinit();
            try addMp4Route(arena, io, &routes, opts.source, options.debug);
            if (server) |s| s.setRoutes(routes.items);
            media_content_type = "video/mp4";
            is_hls = false;
            media_path = try std.mem.concat(arena, u8, &.{ base, "/media.mp4" });

            ch = try Channel.connect(io, arena, address, .{ .debug = options.debug });
            st = try ch.getStatus(arena);
            app = st.find(channel.default_media_receiver) orelse try ch.launch(arena, channel.default_media_receiver);
            try ch.connectTransport(app.transport_id);
            media = try ch.load(arena, app.transport_id, .{
                .url = media_path,
                .content_type = media_content_type,
                .title = title,
                .text_tracks = text_tracks.items,
                .active_track_ids = active_tracks.items,
                .duration = duration,
                .hls = false,
            });
            continue :session;
        }

        try out.print("finished: {s}\n", .{media.idle_reason orelse "?"});
        // Leave the receiver as we found it instead of parked on the idle screen.
        ch.stopApp(arena, app.session_id) catch {};
        return;
    }
}

fn printMedia(out: *Io.Writer, m: Channel.MediaStatus) !void {
    try out.print("  {s} at {d:.1} s", .{ m.player_state, m.current_time });
    if (m.duration) |d| try out.print(" of {d:.1} s", .{d});
    if (m.playback_rate != 1) try out.print(" x{d:.2}", .{m.playback_rate});
    if (m.idle_reason) |r| try out.print(" ({s})", .{r});
    try out.writeAll("\n");
}

// --- controlling a session started by anyone ---------------------------------

const Session = struct {
    ch: *Channel,
    transport_id: []const u8,
    media: Channel.MediaStatus,
};

/// Connects to the app that is playing on the device and fetches its media status.
fn openSession(io: Io, arena: std.mem.Allocator, device: []const u8, options: Options) !Session {
    const address = try discovery.resolve(io, arena, device);
    const ch = try Channel.connect(io, arena, address, .{ .debug = options.debug });
    errdefer ch.deinit();

    const st = try ch.getStatus(arena);
    const app = st.mediaApp() orelse {
        std.debug.print("nothing is playing on {f}\n", .{address});
        return error.NoMedia;
    };
    try ch.connectTransport(app.transport_id);
    const media = ch.getMediaStatus(arena, app.transport_id) catch |err| switch (err) {
        error.NoMedia => {
            std.debug.print("{s} has no media loaded\n", .{app.display_name});
            return err;
        },
        else => return err,
    };
    return .{ .ch = ch, .transport_id = app.transport_id, .media = media };
}

/// Replies to commands carry no `media` object, so the duration learned at
/// session start is kept.
fn report(out: *Io.Writer, s: Session, reply: Channel.MediaStatus) !void {
    var m = reply;
    if (m.duration == null) m.duration = s.media.duration;
    try printMedia(out, m);
}

pub fn pause(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, options: Options) !void {
    const s = try openSession(io, arena, device, options);
    defer s.ch.deinit();
    try report(out, s, try s.ch.mediaCommand(arena, s.transport_id, s.media.media_session_id, "PAUSE"));
}

pub fn play(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, options: Options) !void {
    const s = try openSession(io, arena, device, options);
    defer s.ch.deinit();
    try report(out, s, try s.ch.mediaCommand(arena, s.transport_id, s.media.media_session_id, "PLAY"));
}

/// `spec` is absolute ("90", "1:30", "1:02:03") or relative ("+30", "-10").
pub fn seek(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, spec: []const u8, options: Options) !void {
    const s = try openSession(io, arena, device, options);
    defer s.ch.deinit();

    var target = parseSeek(spec, s.media.current_time) catch {
        std.debug.print("cannot parse position {s}\n", .{spec});
        return error.InvalidSeek;
    };
    if (target < 0) target = 0;
    if (s.media.duration) |d| if (target > d) {
        target = d;
    };
    // Both direct files (byte ranges) and HLS (segment fetch) seek natively.
    try report(out, s, try s.ch.seek(arena, s.transport_id, s.media.media_session_id, target));
}

pub fn rate(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, spec: []const u8, options: Options) !void {
    const value = std.fmt.parseFloat(f64, spec) catch {
        std.debug.print("rate must be a number\n", .{});
        return error.InvalidRate;
    };
    if (value < 0.5 or value > 2.0) {
        std.debug.print("rate must be between 0.5 and 2.0\n", .{});
        return error.InvalidRate;
    }
    const s = try openSession(io, arena, device, options);
    defer s.ch.deinit();
    try report(out, s, try s.ch.setPlaybackRate(arena, s.transport_id, s.media.media_session_id, value));
}

pub fn parseSeek(spec: []const u8, current: f64) !f64 {
    if (spec.len == 0) return error.InvalidSeek;
    const relative = spec[0] == '+' or spec[0] == '-';
    const body = if (relative) spec[1..] else spec;

    // h:m:s, m:s or plain seconds, each part may be fractional
    var seconds: f64 = 0;
    var parts = std.mem.splitScalar(u8, body, ':');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (count == 3) return error.InvalidSeek;
        const v = std.fmt.parseFloat(f64, part) catch return error.InvalidSeek;
        seconds = seconds * 60 + v;
    }
    if (!relative) return seconds;
    return if (spec[0] == '-') current - seconds else current + seconds;
}

test "seek specs" {
    try std.testing.expectEqual(@as(f64, 90), try parseSeek("90", 0));
    try std.testing.expectEqual(@as(f64, 90), try parseSeek("1:30", 0));
    try std.testing.expectEqual(@as(f64, 3723.5), try parseSeek("1:02:03.5", 0));
    try std.testing.expectEqual(@as(f64, 130), try parseSeek("+30", 100));
    try std.testing.expectEqual(@as(f64, 90), try parseSeek("-10", 100));
    try std.testing.expectError(error.InvalidSeek, parseSeek("1:2:3:4", 0));
    try std.testing.expectError(error.InvalidSeek, parseSeek("abc", 0));
}

pub fn guessContentType(url: []const u8) []const u8 {
    const path = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "video/mp4";
    const ext = path[dot + 1 ..];
    const table = std.StaticStringMap([]const u8).initComptime(.{
        .{ "mp4", "video/mp4" },
        .{ "m4v", "video/mp4" },
        .{ "webm", "video/webm" },
        .{ "mkv", "video/x-matroska" },
        .{ "m3u8", "application/x-mpegURL" },
        .{ "mpd", "application/dash+xml" },
        .{ "mp3", "audio/mpeg" },
        .{ "aac", "audio/aac" },
        .{ "flac", "audio/flac" },
        .{ "ogg", "audio/ogg" },
        .{ "opus", "audio/ogg" },
        .{ "wav", "audio/wav" },
        .{ "jpg", "image/jpeg" },
        .{ "jpeg", "image/jpeg" },
        .{ "png", "image/png" },
    });
    return table.get(ext) orelse "video/mp4";
}

test "content type guess" {
    try std.testing.expectEqualStrings("video/webm", guessContentType("http://h/a.webm?x=1"));
    try std.testing.expectEqualStrings("video/mp4", guessContentType("http://h/noext"));
    try std.testing.expectEqualStrings("audio/mpeg", guessContentType("http://h/song.mp3"));
}
