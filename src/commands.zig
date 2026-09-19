//! `status`, `cast` and `stop`: the commands that drive a receiver.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const discovery = @import("discovery.zig");
const channel = @import("cast/channel.zig");
const Channel = channel.Channel;
const http = @import("http/server.zig");
const subtitles = @import("media/subtitles.zig");
const pipeline = @import("media/pipeline.zig");
const hls = @import("media/hls.zig");
const vmp4 = @import("media/vmp4.zig");

const log = std.log.scoped(.cast);

pub fn status(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8) !void {
    const address = try discovery.resolve(io, arena, device);
    const ch = try Channel.connect(io, arena, address);
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

pub fn stop(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8) !void {
    const address = try discovery.resolve(io, arena, device);
    const ch = try Channel.connect(io, arena, address);
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

/// What the receiver is told to LOAD: a served route (until `base` is
/// prepended) or a URL it fetches itself.
const Delivery = struct {
    path: []const u8,
    content_type: []const u8,
    /// HLS with MPEG-TS segments, which the receiver must be told about.
    hls: bool = false,
};

const mp4_path = "/media.mp4";
const mp4_type = "video/mp4";

fn mp4Route(context: *const anyopaque, handle: @FieldType(http.Route.Dynamic, "handle")) http.Route {
    return .{ .path = mp4_path, .body = .{ .dynamic = .{ .context = context, .handle = handle } } };
}

/// Streams a fragmented-MP4 (`--remux stream`) as it is muxed.
const StreamCtx = struct { gpa: std.mem.Allocator, path: []const u8 };

fn streamHandle(context: *const anyopaque, request: *http.Request, _: []const u8) anyerror!void {
    const c: *const StreamCtx = @ptrCast(@alignCast(context));
    if (request.head.method == .HEAD) return http.respondHead(request, mp4_type);
    var buf: [64 * 1024]u8 = undefined;
    var body = try http.beginStream(request, &buf, mp4_type);
    pipeline.remuxWindow(c.gpa, c.path, 0, null, .fmp4, &body.writer) catch |err| {
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

/// Registers the fragmented-MP4 live-stream route (instant, no seek). Used by
/// `--remux stream` and as the `--remux mp4` fallback.
fn addStreamRoute(arena: std.mem.Allocator, routes: *std.ArrayList(http.Route), source: []const u8) !Delivery {
    const c = try arena.create(StreamCtx);
    c.* = .{ .gpa = arena, .path = source };
    try routes.append(arena, mp4Route(c, streamHandle));
    return .{ .path = mp4_path, .content_type = mp4_type };
}

/// Registers the on-the-fly seekable-mp4 route, or the no-seek stream route
/// if the file cannot be made seekable byte-exactly. Shows a std.Progress bar
/// during the build pass, so `out` should be flushed first.
fn addMp4Route(arena: std.mem.Allocator, io: Io, routes: *std.ArrayList(http.Route), source: []const u8) !Delivery {
    const vm = vmp4.build(arena, io, source) catch |err| switch (err) {
        error.NoVideoStream, error.NoAudioStream, error.VideoNotAddressable, error.MuxerInterleaved => {
            std.debug.print("note: this file cannot be made seekable without a copy ({s}); serving without seek.\n", .{@errorName(err)});
            return addStreamRoute(arena, routes, source);
        },
        else => return err,
    };
    try routes.append(arena, mp4Route(vm, vmp4Handle));
    return .{ .path = mp4_path, .content_type = mp4_type };
}

fn addHlsRoute(arena: std.mem.Allocator, routes: *std.ArrayList(http.Route), source: []const u8) !Delivery {
    const seg = try arena.create(hls.Segmenter);
    seg.* = try hls.Segmenter.init(arena, source);
    try routes.append(arena, .{
        .path = hls.url_prefix,
        .body = .{ .dynamic = .{ .context = seg, .handle = hls.handleRoute } },
    });
    return .{ .path = hls.url_prefix ++ hls.master_name, .content_type = hls.cast_content_type, .hls = true };
}

/// One embedded subtitle stream, converted to WebVTT the first time the
/// receiver asks for it (scanning the source), then cached.
const EmbSubCtx = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    stream_index: usize,
    cached: ?[]const u8 = null,
};

fn embSubHandle(context: *const anyopaque, request: *http.Request, _: []const u8) anyerror!void {
    const c: *EmbSubCtx = @ptrCast(@alignCast(@constCast(context)));
    if (c.cached == null) {
        c.cached = pipeline.extractSubtitle(c.gpa, c.path, c.stream_index) catch |err| {
            log.debug("subtitle extract failed: {s}", .{@errorName(err)});
            return request.respond("subtitle extract failed\n", .{ .status = .internal_server_error, .extra_headers = http.cors });
        };
    }
    try http.respondBuffer(request, "text/vtt", c.cached.?);
}

/// Everything a LOAD needs besides the delivery.
const LoadExtras = struct {
    title: ?[]const u8,
    text_tracks: []const Channel.TextTrack,
    active_track_ids: []const u32,
    duration: ?f64,
};

const Playback = struct { app: Channel.App, media: Channel.MediaStatus };

/// Launches (or joins) the default media receiver and loads `delivery`.
fn startPlayback(ch: *Channel, arena: std.mem.Allocator, delivery: Delivery, extras: LoadExtras) !Playback {
    const st = try ch.getStatus(arena);
    const app = st.find(channel.default_media_receiver) orelse try ch.launch(arena, channel.default_media_receiver);
    try ch.connectTransport(app.transport_id);
    const media = try ch.load(arena, app.transport_id, .{
        .url = delivery.path,
        .content_type = delivery.content_type,
        .title = extras.title,
        .text_tracks = extras.text_tracks,
        .active_track_ids = extras.active_track_ids,
        .duration = extras.duration,
        .hls = delivery.hls,
    });
    return .{ .app = app, .media = media };
}

/// Launches the default media receiver, loads the source and follows
/// playback until it ends. Local files are served from a built-in HTTP
/// server for as long as the session lasts.
pub fn cast(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, opts: CastOptions) !void {
    const address = try discovery.resolve(io, arena, device);
    const local = !isUrl(opts.source);

    // Routes for whatever must be served locally.
    var routes: std.ArrayList(http.Route) = .empty;
    var text_tracks: std.ArrayList(Channel.TextTrack) = .empty;
    var active_tracks: std.ArrayList(u32) = .empty;
    var duration: ?f64 = null;
    var embedded_subs: []const pipeline.SubtitleStream = &.{};
    const content_type = opts.content_type orelse guessContentType(opts.source);
    var delivery: Delivery = .{
        .path = opts.source,
        .content_type = content_type,
        // A remote HLS URL needs the MPEG-TS segment hint too.
        .hls = std.ascii.findIgnoreCase(content_type, "mpegurl") != null,
    };

    if (local) {
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
            delivery.path = try arena.print("/media{s}", .{std.fs.path.extension(opts.source)});
            try routes.append(arena, .{
                .path = delivery.path,
                .body = .{ .file = .{ .content_type = content_type, .data = opts.source } },
            });
        } else switch (opts.remux) {
            .auto, .hls => {
                std.debug.print("remuxing {s} audio to aac (hls)\n", .{p.audio_codec});
                delivery = try addHlsRoute(arena, &routes, opts.source);
            },
            .stream => {
                std.debug.print("remuxing {s} audio to aac (fragmented mp4, no seek)\n", .{p.audio_codec});
                delivery = try addStreamRoute(arena, &routes, opts.source);
            },
            .mp4 => {
                try out.flush();
                delivery = try addMp4Route(arena, io, &routes, opts.source);
            },
        }
    }
    // The --subs track starts enabled. Embedded tracks are advertised off and
    // extracted on demand, since each one costs a pass over the source.
    if (opts.subtitles) |sub| {
        const url = if (isUrl(sub)) sub else blk: {
            const srt = Io.Dir.cwd().readFileAlloc(io, sub, arena, .limited(16 * 1024 * 1024)) catch |err| {
                std.debug.print("cannot read {s}: {s}\n", .{ sub, @errorName(err) });
                return error.SourceUnreadable;
            };
            try routes.append(arena, .{
                .path = "/sub.vtt",
                .body = .{ .bytes = .{ .content_type = "text/vtt", .data = try subtitles.srtToVtt(arena, srt) } },
            });
            break :blk "/sub.vtt";
        };
        const id: u32 = @intCast(text_tracks.items.len + 1);
        try text_tracks.append(arena, .{ .id = id, .url = url, .name = "Subtitles" });
        try active_tracks.append(arena, id);
    }
    for (embedded_subs) |e| {
        const id: u32 = @intCast(text_tracks.items.len + 1);
        const path = try arena.print("/embsub{d}.vtt", .{e.index});
        const ctx = try arena.create(EmbSubCtx);
        ctx.* = .{ .gpa = arena, .path = opts.source, .stream_index = e.index };
        try routes.append(arena, .{
            .path = path,
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

    // Connect after the heavy work: the receiver drops a channel whose
    // heartbeat PINGs go unanswered during a long mp4 build.
    var ch = try Channel.connect(io, arena, address);
    defer ch.deinit();

    var server: ?*http.Server = null;
    defer if (server) |s| s.stop();
    var base: []const u8 = "";
    if (routes.items.len > 0) {
        const s = try http.Server.start(io, arena, routes.items);
        server = s;
        var served_at = ch.localAddress();
        served_at.port = s.port;
        base = try arena.print("http://{f}", .{served_at});
        if (local) delivery.path = try std.mem.concat(arena, u8, &.{ base, delivery.path });
        for (text_tracks.items) |*t| if (!isUrl(t.url)) {
            t.url = try std.mem.concat(arena, u8, &.{ base, t.url });
        };
        try out.print("serving at {s}\n", .{base});
        try out.flush();
    }

    const extras: LoadExtras = .{
        .title = opts.title orelse (if (local) std.fs.path.basename(opts.source) else null),
        .text_tracks = text_tracks.items,
        .active_track_ids = active_tracks.items,
        .duration = duration,
    };
    var pb = try startPlayback(ch, arena, delivery, extras);

    // A scratch arena reset per message keeps a long session's memory bounded.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    session: while (true) {
        try out.print("loaded on {f} as {s}\n", .{ address, delivery.content_type });
        try printMedia(out, pb.media);
        try out.flush();

        // Follow MEDIA_STATUS until the item finishes, noting if it ever played.
        var played = false;
        while (!pb.media.isFinished()) {
            const msg = ch.receive() catch |err| switch (err) {
                error.ConnectionClosed => {
                    try out.writeAll("receiver closed the session\n");
                    return;
                },
                else => return err,
            };
            if (!std.mem.eql(u8, msg.namespace, channel.ns_media)) continue;
            _ = scratch.reset(.retain_capacity);
            const json = try Channel.parsePayload(scratch.allocator(), msg);
            pb.media = Channel.mediaStatusFrom(json) orelse continue;
            if (pb.media.player_state == .PLAYING) played = true;
            try printMedia(out, pb.media);
            try out.flush();
        }

        // In auto mode a refused HLS load fails asynchronously (idleReason
        // ERROR) before ever playing, and the seekable mp4 is the fallback. The
        // build takes a while, so the idle channel is reopened afterwards.
        const errored = pb.media.idle_reason == .ERROR;
        if (!played and errored and opts.remux == .auto and delivery.hls and local) {
            std.debug.print("receiver refused HLS; falling back to seekable mp4 ...\n", .{});
            try out.flush();
            ch.deinit();
            delivery = try addMp4Route(arena, io, &routes, opts.source);
            delivery.path = try std.mem.concat(arena, u8, &.{ base, delivery.path });
            if (server) |s| s.setRoutes(routes.items);
            ch = try Channel.connect(io, arena, address);
            pb = try startPlayback(ch, arena, delivery, extras);
            continue :session;
        }

        try out.print("finished: {s}\n", .{if (pb.media.idle_reason) |r| @tagName(r) else "?"});
        // Leave the receiver as we found it instead of parked on the idle screen.
        ch.stopApp(arena, pb.app.session_id) catch {};
        return;
    }
}

fn printMedia(out: *Io.Writer, m: Channel.MediaStatus) !void {
    try out.print("  {t} at {d:.1} s", .{ m.player_state, m.current_time });
    if (m.duration) |d| try out.print(" of {d:.1} s", .{d});
    if (m.playback_rate != 1) try out.print(" x{d:.2}", .{m.playback_rate});
    if (m.idle_reason) |r| try out.print(" ({t})", .{r});
    try out.writeAll("\n");
}

// --- controlling a session started by anyone ---------------------------------

const Session = struct {
    ch: *Channel,
    transport_id: []const u8,
    media: Channel.MediaStatus,
};

/// Connects to the app that is playing on the device and fetches its media status.
fn openSession(io: Io, arena: std.mem.Allocator, device: []const u8) !Session {
    const address = try discovery.resolve(io, arena, device);
    const ch = try Channel.connect(io, arena, address);
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

pub fn pause(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8) !void {
    const s = try openSession(io, arena, device);
    defer s.ch.deinit();
    try report(out, s, try s.ch.mediaCommand(arena, s.transport_id, s.media.media_session_id, "PAUSE"));
}

pub fn play(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8) !void {
    const s = try openSession(io, arena, device);
    defer s.ch.deinit();
    try report(out, s, try s.ch.mediaCommand(arena, s.transport_id, s.media.media_session_id, "PLAY"));
}

/// `spec` is absolute ("90", "1:30", "1:02:03") or relative ("+30", "-10").
pub fn seek(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, spec: []const u8) !void {
    const s = try openSession(io, arena, device);
    defer s.ch.deinit();

    var target = parseSeek(spec, s.media.current_time) catch {
        std.debug.print("cannot parse position {s}\n", .{spec});
        return error.InvalidSeek;
    };
    target = std.math.clamp(target, 0, s.media.duration orelse std.math.inf(f64));
    try report(out, s, try s.ch.seek(arena, s.transport_id, s.media.media_session_id, target));
}

pub fn rate(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, spec: []const u8) !void {
    const value = std.fmt.parseFloat(f64, spec) catch {
        std.debug.print("rate must be a number\n", .{});
        return error.InvalidRate;
    };
    if (value < 0.5 or value > 2.0) {
        std.debug.print("rate must be between 0.5 and 2.0\n", .{});
        return error.InvalidRate;
    }
    const s = try openSession(io, arena, device);
    defer s.ch.deinit();
    try report(out, s, try s.ch.setPlaybackRate(arena, s.transport_id, s.media.media_session_id, value));
}

pub fn parseSeek(spec: []const u8, current: f64) !f64 {
    if (spec.len == 0) return error.InvalidSeek;
    const relative = spec[0] == '+' or spec[0] == '-';
    const body = if (relative) spec[1..] else spec;

    // Parts are h:m:s, m:s or plain seconds; each may be fractional.
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
    const ext = std.fs.path.extension(std.mem.sliceTo(url, '?'));
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
