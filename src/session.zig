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
const Player = @import("device/player.zig").Player;
const discovery = @import("device/discovery.zig");
const playback = @import("device/playback.zig");
const extra = @import("media/av_extra.zig");
const pipeline = @import("media/pipeline.zig");
const http = @import("serve/server.zig");
const delivery = @import("serve/delivery.zig");
const subs = @import("subs/lookup.zig");

const log = std.log.scoped(.cast);

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
    /// Which kind of device the name means, when the name alone is
    /// ambiguous. A `cast:` or `dlna:` prefix on the spec says the same.
    protocol: ?discovery.Protocol = null,
};

pub const Event = union(enum) {
    /// The built-in server is listening at this base URL.
    serving: []const u8,
    /// The receiver accepted the LOAD.
    loaded: struct { address: net.Ip4Address, content_type: []const u8 },
    /// A status update from the receiver.
    state: playback.Playback,
    /// The receiver refused this delivery; retrying as a seekable mp4.
    falling_back,
    /// The item ended.
    finished: ?playback.EndReason,
    /// The receiver hung up mid-session.
    closed,
};

pub const Session = struct {
    env: Env,
    opts: Options,
    local: bool,
    endpoint: discovery.Endpoint,
    player: Player,
    routes: delivery.Routes,
    server: ?*http.Server = null,
    base: []const u8 = "",
    target: delivery.Target,
    /// What the LOAD carries besides the target; the tracks come from `routes`.
    title: ?[]const u8 = null,
    duration: ?f64 = null,
    media: playback.Playback,
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
        var resolving = io.async(discovery.resolve, .{ env, device, opts.protocol });
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
            .endpoint = undefined,
            .player = undefined,
            .routes = .{ .env = env, .source = opts.source },
            .target = .{ .path = opts.source, .content_type = content_type },
            .media = .{},
            .scratch = std.heap.ArenaAllocator.init(env.gpa),
        };
        errdefer s.scratch.deinit();
        errdefer s.routes.deinit();
        // Function scope: the server outlives the block that starts it, so a
        // later failure (the LOAD) has to stop it too.
        errdefer if (s.server) |server| server.stop();

        var duration: ?f64 = null;
        var sub_source: ?subs.Subtitle = switch (opts.subtitles) {
            .source => |p| .{ .path = p, .lang = subs.languageOf(p) },
            .sidecar, .download => null,
        };
        const want_download = opts.subtitles == .download;

        if (local) {
            Io.Dir.cwd().access(io, opts.source, .{}) catch |err| {
                log.warn("cannot read {s}: {s}", .{ opts.source, @errorName(err) });
                return error.SourceUnreadable;
            };
            const p = try pipeline.plan(arena, opts.source);
            // The probed demuxer goes to the delivery that can reuse it.
            var probed: ?*av.FormatContext = p.ic;
            defer if (probed) |ic| ic.close_input();
            duration = p.duration;
            if (p.video_unsupported) {
                log.warn("{s} video is not castable and video transcoding is not implemented; trying direct", .{p.video_codec});
            }
            if (p.direct or p.video_unsupported) {
                s.target = try s.routes.addFile(content_type);
            } else switch (opts.remux) {
                .auto, .hls => {
                    log.info("remuxing {s} audio to aac (hls)", .{p.audio_codec});
                    probed = null;
                    s.target = try s.routes.addHls(p.ic);
                },
                .stream => {
                    log.info("remuxing {s} audio to aac (fragmented mp4, no seek)", .{p.audio_codec});
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
            log.warn("--subs auto needs a local file", .{});
        }
        // The side-loaded track starts enabled; embedded tracks are advertised off.
        if (sub_source) |sub| try s.routes.addSideloaded(sub.path, sub.lang);

        resolved = true;
        s.endpoint = try resolving.await(io);

        // Connect after the heavy work: the receiver drops a channel whose
        // heartbeat PINGs go unanswered during a long mp4 build.
        s.player = try Player.connect(env, s.endpoint);
        errdefer s.player.deinit();

        if (s.routes.list.items.len > 0) {
            const server = try http.Server.start(io, env.gpa, s.routes.list.items);
            s.server = server;
            var served_at = s.player.localAddress();
            served_at.port = server.port;
            s.base = try arena.print("http://{f}", .{served_at});
            try s.routes.absolutise(s.base, &s.target, local);
            s.push(.{ .serving = s.base });
        }

        s.title = opts.title orelse (if (local) Io.Dir.path.basename(opts.source) else null);
        s.duration = duration;
        try s.load();
        return s;
    }

    /// Stops the server, closes the connection and frees the session.
    pub fn deinit(s: *Session) void {
        if (s.server) |server| server.stop();
        s.player.deinit();
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

        if (s.media.isFinished()) {
            if (try s.fallBack()) return s.pop().?;
            s.done = true;
            s.player.endSession(s.env);
            return .{ .finished = s.media.ended };
        }
        _ = s.scratch.reset(.retain_capacity);
        s.media = s.player.next(s.env, s.scratch.allocator()) catch |err| switch (err) {
            error.ConnectionClosed => {
                s.done = true;
                return .closed;
            },
            else => return err,
        };
        if (s.media.state == .playing) s.played = true;
        return .{ .state = s.media };
    }

    /// Hands the connected device the target to play.
    fn load(s: *Session) !void {
        s.media = try s.player.load(s.env, .{
            .url = s.target.path,
            .content_type = s.target.content_type,
            .title = s.title,
            .text_tracks = s.routes.tracks.items,
            .active_track_ids = s.routes.active.items,
            .duration = s.duration,
            .hls = s.target.isHls(),
        });
        s.push(.{ .loaded = .{ .address = s.endpoint.address(), .content_type = s.target.content_type } });
        s.push(.{ .state = s.media });
    }

    /// In auto mode a refused HLS load fails asynchronously, ending the item
    /// before it ever played, and the seekable mp4 is the fallback. The build
    /// takes a while, so the idle connection is reopened afterwards.
    fn fallBack(s: *Session) !bool {
        const failed = if (s.media.ended) |e| e == .failed else false;
        if (s.played or !failed) return false;
        if (s.opts.remux != .auto or !s.target.isHls() or !s.local) return false;

        s.push(.falling_back);
        s.player.deinit();
        s.target = try s.routes.addMp4(try extra.openInput(s.env.gpa, s.opts.source));
        try s.routes.absolutise(s.base, &s.target, s.local);
        if (s.server) |server| server.setRoutes(s.routes.list.items);
        s.player = try Player.connect(s.env, s.endpoint);
        try s.load();
        return true;
    }

    fn push(s: *Session, e: Event) void {
        std.debug.assert(s.head + s.queued < s.queue.len);
        s.queue[s.head + s.queued] = e;
        s.queued += 1;
    }

    fn pop(s: *Session) ?Event {
        if (s.queued == 0) return null;
        const e = s.queue[s.head];
        s.head += 1;
        s.queued -= 1;
        // Empty: start the next fill at the front, so `head` never wraps.
        if (s.queued == 0) s.head = 0;
        return e;
    }
};
