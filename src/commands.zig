//! `status`, `cast` and `stop`: the commands that drive a receiver.

const std = @import("std");
const Io = std.Io;
const discovery = @import("discovery.zig");
const channel = @import("cast/channel.zig");
const Channel = channel.Channel;
const http = @import("http/server.zig");
const subtitles = @import("media/subtitles.zig");

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

pub const CastOptions = struct {
    /// http(s) URL the receiver fetches itself, or a local path castig serves.
    source: []const u8,
    title: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// WebVTT URL, or a local .srt/.vtt file castig converts and serves.
    subtitles: ?[]const u8 = null,
};

fn isUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

/// Launches the default media receiver, loads the source and follows
/// playback until it ends. Local files are served from a built-in HTTP
/// server for as long as the session lasts.
pub fn cast(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, opts: CastOptions, options: Options) !void {
    const address = try discovery.resolve(io, arena, device);
    const ch = try Channel.connect(io, arena, address, .{ .debug = options.debug });
    defer ch.deinit();

    // Routes for whatever must be served locally.
    var routes: std.ArrayList(http.Route) = .empty;
    var media_path: []const u8 = opts.source;
    var subtitles_path: ?[]const u8 = opts.subtitles;

    if (!isUrl(opts.source)) {
        Io.Dir.cwd().access(io, opts.source, .{}) catch |err| {
            std.debug.print("cannot read {s}: {s}\n", .{ opts.source, @errorName(err) });
            return error.SourceUnreadable;
        };
        const ext = std.fs.path.extension(opts.source);
        media_path = try std.fmt.allocPrint(arena, "/media{s}", .{ext});
        try routes.append(arena, .{
            .path = media_path,
            .content_type = opts.content_type orelse guessContentType(opts.source),
            .body = .{ .file = opts.source },
        });
    }
    if (opts.subtitles) |sub| if (!isUrl(sub)) {
        const srt = Io.Dir.cwd().readFileAlloc(io, sub, arena, .limited(16 * 1024 * 1024)) catch |err| {
            std.debug.print("cannot read {s}: {s}\n", .{ sub, @errorName(err) });
            return error.SourceUnreadable;
        };
        subtitles_path = "/sub.vtt";
        try routes.append(arena, .{
            .path = "/sub.vtt",
            .content_type = "text/vtt",
            .body = .{ .bytes = try subtitles.srtToVtt(arena, srt) },
        });
    };

    var server: ?*http.Server = null;
    defer if (server) |s| s.stop();
    if (routes.items.len > 0) {
        const s = try http.Server.start(io, arena, routes.items, options.debug);
        server = s;
        const ip = try ch.localIp4();
        const base = try std.fmt.allocPrint(arena, "http://{d}.{d}.{d}.{d}:{d}", .{ ip[0], ip[1], ip[2], ip[3], s.port });
        if (!isUrl(opts.source)) media_path = try std.mem.concat(arena, u8, &.{ base, media_path });
        if (subtitles_path) |p| if (!isUrl(p)) {
            subtitles_path = try std.mem.concat(arena, u8, &.{ base, p });
        };
        try out.print("serving at {s}\n", .{base});
        try out.flush();
    }

    const st = try ch.getStatus(arena);
    const app = st.find(channel.default_media_receiver) orelse try ch.launch(arena, channel.default_media_receiver);
    try ch.connectTransport(app.transport_id);

    const content_type = opts.content_type orelse guessContentType(opts.source);
    var media = try ch.load(arena, app.transport_id, .{
        .url = media_path,
        .content_type = content_type,
        .title = opts.title orelse (if (isUrl(opts.source)) null else std.fs.path.basename(opts.source)),
        .subtitles_url = subtitles_path,
    });
    try out.print("loaded on {f} as {s}\n", .{ address, content_type });
    try printMedia(out, media);
    try out.flush();

    // Follow unsolicited MEDIA_STATUS updates until the item finishes.
    while (!media.isFinished()) {
        const msg = try ch.receive();
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
        try printMedia(out, media);
        try out.flush();
    }
    try out.print("finished: {s}\n", .{media.idle_reason orelse "?"});
    // Leave the receiver as we found it instead of parked on the idle screen.
    ch.stopApp(arena, app.session_id) catch {};
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
