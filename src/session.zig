//! One cast, from a file or URL to the end of playback.
//!
//! `start` does the slow part: probe the source, build the routes that serve
//! it, resolve the device, connect, and LOAD. `next` then reports what the
//! receiver does, one event at a time, until the item finishes. A receiver
//! that refuses the HLS delivery is retried as a seekable mp4 inside `next`,
//! so a caller sees `.falling_back` and then a second `.loaded`.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const av = @import("av");

const Env = @import("env.zig").Env;
const channel = @import("device/channel.zig");
const Channel = channel.Channel;
const discovery = @import("device/discovery.zig");
const extra = @import("media/av_extra.zig");
const pipeline = @import("media/pipeline.zig");
const http = @import("serve/server.zig");
const delivery = @import("serve/delivery.zig");
const subs = @import("subs/lookup.zig");

/// Where the side-loaded subtitle track comes from.
pub const Subtitles = union(enum) {
    /// A sidecar next to the video, when there is one.
    sidecar,
    /// The sidecar, else an OpenSubtitles hash match.
    download,
    /// A WebVTT URL, or a local .srt/.vtt castig converts and serves.
    source: []const u8,
};

pub const Options = struct {
    /// http(s) URL the receiver fetches itself, or a local path castig serves.
    source: []const u8,
    title: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    subtitles: Subtitles = .sidecar,
    remux: delivery.Remux = .auto,
};

pub const Event = union(enum) {
    /// The built-in server is listening at this base URL.
    serving: []const u8,
    /// The receiver accepted the LOAD.
    loaded: struct { address: net.Ip4Address, content_type: []const u8 },
    /// A status update from the receiver.
    state: Channel.MediaStatus,
    /// The receiver refused this delivery; retrying as a seekable mp4.
    falling_back,
    /// The item ended.
    finished: ?Channel.IdleReason,
    /// The receiver hung up mid-session.
    closed,
};

/// Everything a LOAD needs besides the target.
const Extras = struct {
    title: ?[]const u8,
    text_tracks: []const Channel.TextTrack,
    active_track_ids: []const u32,
    duration: ?f64,
};

pub const Session = struct {
    env: Env,
    opts: Options,
    local: bool,
    address: net.Ip4Address,
    ch: *Channel,
    routes: delivery.Routes,
    server: ?*http.Server = null,
    base: []const u8 = "",
    target: delivery.Target,
    extras: Extras,
    app: Channel.App,
    media: Channel.MediaStatus,
    /// Reset per message, so a long session's memory stays bounded.
    scratch: std.heap.ArenaAllocator,
    played: bool = false,
    done: bool = false,
    queue: [3]Event = undefined,
    queued: usize = 0,
    head: usize = 0,

    /// Prepares the source, connects, and loads it. The returned session owns
    /// the HTTP server and the channel until `deinit`.
    pub fn start(env: Env, device: []const u8, opts: Options) !*Session {
        const io = env.io;
        const arena = env.arena;
        const local = !delivery.isUrl(opts.source);

        // Discovery waits on the network while the file is probed and prepared.
        var resolving = io.async(discovery.resolve, .{ io, env.gpa, device });
        var resolved = false;
        defer if (!resolved) {
            _ = resolving.cancel(io) catch {};
        };

        const s = try env.gpa.create(Session);
        errdefer env.gpa.destroy(s);

        const content_type = opts.content_type orelse delivery.guessContentType(opts.source);
        s.* = .{
            .env = env,
            .opts = opts,
            .local = local,
            .address = undefined,
            .ch = undefined,
            .routes = .{ .env = env, .source = opts.source },
            .target = .{
                .path = opts.source,
                .content_type = content_type,
                // A remote HLS URL needs the MPEG-TS segment hint too.
                .hls = std.ascii.findIgnoreCase(content_type, "mpegurl") != null,
            },
            .extras = undefined,
            .app = undefined,
            .media = undefined,
            .scratch = std.heap.ArenaAllocator.init(env.gpa),
        };
        errdefer s.scratch.deinit();
        errdefer s.routes.deinit();
        // Function scope: the server outlives the block that starts it, so a
        // later failure (the LOAD) has to stop it too.
        errdefer if (s.server) |server| server.stop();

        var duration: ?f64 = null;
        var sub_source: ?[]const u8 = switch (opts.subtitles) {
            .source => |p| p,
            .sidecar, .download => null,
        };
        const want_download = opts.subtitles == .download;

        if (local) {
            Io.Dir.cwd().access(io, opts.source, .{}) catch |err| {
                std.debug.print("cannot read {s}: {s}\n", .{ opts.source, @errorName(err) });
                return error.SourceUnreadable;
            };
            const p = try pipeline.plan(arena, opts.source);
            // The probed demuxer goes to the delivery that can reuse it.
            var probed: ?*av.FormatContext = p.ic;
            defer if (probed) |ic| ic.close_input();
            duration = p.duration;
            if (p.video_unsupported) {
                std.debug.print("warning: {s} video is not castable and video transcoding is not implemented; trying direct\n", .{p.video_codec});
            }
            if (p.direct or p.video_unsupported) {
                s.target = try s.routes.addFile(content_type);
            } else switch (opts.remux) {
                .auto, .hls => {
                    std.debug.print("remuxing {s} audio to aac (hls)\n", .{p.audio_codec});
                    probed = null;
                    s.target = try s.routes.addHls(p.ic);
                },
                .stream => {
                    std.debug.print("remuxing {s} audio to aac (fragmented mp4, no seek)\n", .{p.audio_codec});
                    s.target = try s.routes.addStream();
                },
                .mp4 => {
                    probed = null;
                    s.target = try s.routes.addMp4(p.ic);
                },
            }
            try s.routes.addEmbeddedSubtitles(p.subtitles);
            if (sub_source == null) sub_source = try subs.resolve(env, opts.source, want_download, p.fps);
        } else if (want_download) {
            std.debug.print("--subs auto needs a local file\n", .{});
        }
        // The side-loaded track starts enabled; embedded tracks are advertised off.
        if (sub_source) |sub| try s.routes.addSideloaded(sub);

        resolved = true;
        s.address = try resolving.await(io);

        // Connect after the heavy work: the receiver drops a channel whose
        // heartbeat PINGs go unanswered during a long mp4 build.
        s.ch = try Channel.connect(io, env.gpa, s.address);
        errdefer s.ch.deinit();

        if (s.routes.list.items.len > 0) {
            const server = try http.Server.start(io, env.gpa, s.routes.list.items);
            s.server = server;
            var served_at = s.ch.localAddress();
            served_at.port = server.port;
            s.base = try arena.print("http://{f}", .{served_at});
            try s.routes.absolutise(s.base, &s.target, local);
            s.push(.{ .serving = s.base });
        }

        s.extras = .{
            .title = opts.title orelse (if (local) std.fs.path.basename(opts.source) else null),
            .text_tracks = s.routes.tracks.items,
            .active_track_ids = s.routes.active.items,
            .duration = duration,
        };
        try s.load();
        return s;
    }

    pub fn deinit(s: *Session) void {
        if (s.server) |server| server.stop();
        s.ch.deinit();
        s.routes.deinit();
        s.scratch.deinit();
        s.env.gpa.destroy(s);
    }

    /// The next thing the receiver did, or null once the session is over.
    /// A `.state` borrows from a scratch arena that the following call
    /// resets, so render or copy it before asking for the next event.
    pub fn next(s: *Session) !?Event {
        if (s.pop()) |e| return e;
        if (s.done) return null;

        while (true) {
            if (s.media.isFinished()) {
                if (try s.fallBack()) return s.pop().?;
                s.done = true;
                // Leave the receiver as we found it, not parked on the idle screen.
                s.ch.stopApp(s.env.arena, s.app.sessionId) catch {};
                return .{ .finished = s.media.idleReason };
            }
            const msg = s.ch.receive() catch |err| switch (err) {
                error.ConnectionClosed => {
                    s.done = true;
                    return .closed;
                },
                else => return err,
            };
            if (!std.mem.eql(u8, msg.namespace, channel.ns_media)) continue;
            _ = s.scratch.reset(.retain_capacity);
            const reply = Channel.parseReply(s.scratch.allocator(), msg) orelse continue;
            s.media = Channel.mediaStatusFrom(s.scratch.allocator(), reply) orelse continue;
            if (s.media.playerState == .PLAYING) s.played = true;
            return .{ .state = s.media };
        }
    }

    /// Launches (or joins) the default media receiver and loads the target.
    fn load(s: *Session) !void {
        const arena = s.env.arena;
        const st = try s.ch.getStatus(arena);
        s.app = st.find(channel.default_media_receiver) orelse try s.ch.launch(arena, channel.default_media_receiver);
        try s.ch.connectTransport(s.app.transportId);
        s.media = try s.ch.load(arena, s.app.transportId, .{
            .url = s.target.path,
            .content_type = s.target.content_type,
            .title = s.extras.title,
            .text_tracks = s.extras.text_tracks,
            .active_track_ids = s.extras.active_track_ids,
            .duration = s.extras.duration,
            .hls = s.target.hls,
        });
        s.push(.{ .loaded = .{ .address = s.address, .content_type = s.target.content_type } });
        s.push(.{ .state = s.media });
    }

    /// In auto mode a refused HLS load fails asynchronously (idleReason ERROR)
    /// before ever playing, and the seekable mp4 is the fallback. The build
    /// takes a while, so the idle channel is reopened afterwards.
    fn fallBack(s: *Session) !bool {
        if (s.played or s.media.idleReason != .ERROR) return false;
        if (s.opts.remux != .auto or !s.target.hls or !s.local) return false;

        s.push(.falling_back);
        s.ch.deinit();
        s.target = try s.routes.addMp4(try extra.openInput(s.env.gpa, s.opts.source));
        try s.routes.absolutise(s.base, &s.target, s.local);
        if (s.server) |server| server.setRoutes(s.routes.list.items);
        s.ch = try Channel.connect(s.env.io, s.env.gpa, s.address);
        try s.load();
        return true;
    }

    fn push(s: *Session, e: Event) void {
        std.debug.assert(s.queued < s.queue.len);
        s.queue[(s.head + s.queued) % s.queue.len] = e;
        s.queued += 1;
    }

    fn pop(s: *Session) ?Event {
        if (s.queued == 0) return null;
        const e = s.queue[s.head];
        s.head = (s.head + 1) % s.queue.len;
        s.queued -= 1;
        return e;
    }
};
