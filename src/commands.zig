//! `status`, `cast` and `stop`: the commands that drive a receiver.

const std = @import("std");
const Io = std.Io;
const discovery = @import("discovery.zig");
const channel = @import("cast/channel.zig");
const Channel = channel.Channel;

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
    url: []const u8,
    title: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    subtitles_url: ?[]const u8 = null,
};

/// Launches the default media receiver, loads the URL and follows playback
/// until it ends. The URL must be reachable by the receiver, not by us.
pub fn cast(io: Io, arena: std.mem.Allocator, out: *Io.Writer, device: []const u8, opts: CastOptions, options: Options) !void {
    const address = try discovery.resolve(io, arena, device);
    const ch = try Channel.connect(io, arena, address, .{ .debug = options.debug });
    defer ch.deinit();

    const st = try ch.getStatus(arena);
    const app = st.find(channel.default_media_receiver) orelse try ch.launch(arena, channel.default_media_receiver);
    try ch.connectTransport(app.transport_id);

    const content_type = opts.content_type orelse guessContentType(opts.url);
    var media = try ch.load(arena, app.transport_id, .{
        .url = opts.url,
        .content_type = content_type,
        .title = opts.title,
        .subtitles_url = opts.subtitles_url,
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
    if (m.idle_reason) |r| try out.print(" ({s})", .{r});
    try out.writeAll("\n");
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
