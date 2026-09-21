//! Cast v2 control channel: a TLS connection to <device>:8009 carrying
//! `proto.Message` frames.
//!
//! Receivers present a self-signed certificate, so verification is off. All
//! devices seen so far negotiate TLS 1.3, which is what `std.crypto.tls`
//! speaks.
//!
//! Namespaces:
//!   urn:x-cast:com.google.cast.tp.connection   CONNECT / CLOSE
//!   urn:x-cast:com.google.cast.tp.heartbeat    the receiver PINGs every 5 s, we answer PONG
//!   urn:x-cast:com.google.cast.receiver        LAUNCH, STOP, GET_STATUS
//!   urn:x-cast:com.google.cast.media           LOAD, PLAY, PAUSE, SEEK, STOP, GET_STATUS
//!
//! Every request carries an incrementing `requestId` and the matching
//! response is picked out by it. After LAUNCH, media messages go to the
//! app's transport id, and a second CONNECT must be sent to that id first.
//!
//! Payloads are JSON; the wire structs below use the protocol's own camelCase
//! field names so `std.json` reads and writes them directly.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const tls = std.crypto.tls;
const proto = @import("proto.zig");

/// Every message exchanged with the receiver, at debug level.
const log = std.log.scoped(.cast);

pub const ns_connection = "urn:x-cast:com.google.cast.tp.connection";
pub const ns_heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat";
pub const ns_receiver = "urn:x-cast:com.google.cast.receiver";
pub const ns_media = "urn:x-cast:com.google.cast.media";

pub const default_media_receiver = "CC1AD845";

const sender_id = "sender-0";
const receiver_id = "receiver-0";
const buffer_len = tls.max_ciphertext_record_len;
/// Anything bigger than this is not a Cast message.
const max_frame = 1 << 20;

pub const Json = std.json.Value;

/// Receivers add fields freely, so unknown ones are ignored everywhere.
const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// A MEDIA_STATUS we could not read. Logged here so the failure is never
/// silent, whatever the caller does with the error.
fn badMediaStatus() error{BadReply} {
    log.warn("receiver sent a MEDIA_STATUS we cannot read", .{});
    return error.BadReply;
}

pub const Channel = struct {
    io: Io,
    gpa: std.mem.Allocator,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    client: tls.Client,
    buffers: *[4][buffer_len]u8,
    request_id: u32 = 0,
    /// Body of the last received frame; a `proto.Message` from `receive`
    /// points into it and is valid until the next call.
    frame: std.ArrayList(u8) = .empty,
    /// Scratch for the JSON text of each outgoing message.
    json: Io.Writer.Allocating,

    /// Opens the TLS connection and sends CONNECT to the receiver.
    /// The channel lives on the heap because the TLS client keeps pointers into it.
    pub fn connect(io: Io, gpa: std.mem.Allocator, address: net.Ip4Address) !*Channel {
        const ch = try gpa.create(Channel);
        errdefer gpa.destroy(ch);
        const buffers = try gpa.create([4][buffer_len]u8);
        errdefer gpa.destroy(buffers);

        const ip: net.IpAddress = .{ .ip4 = address };
        const stream = try ip.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);

        ch.* = .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .stream_reader = stream.reader(io, &buffers[0]),
            .stream_writer = stream.writer(io, &buffers[1]),
            .client = undefined,
            .buffers = buffers,
            .json = .init(gpa),
        };
        errdefer ch.json.deinit();

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        try io.randomSecure(&entropy);
        ch.client = try tls.Client.init(&ch.stream_reader.interface, &ch.stream_writer.interface, .{
            .host = .no_verification,
            .ca = .no_verification,
            .read_buffer = &buffers[2],
            .write_buffer = &buffers[3],
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(io),
        });

        try ch.sendJson(receiver_id, ns_connection, Connect{});
        return ch;
    }

    /// Says goodbye to the receiver, then frees everything the channel holds.
    pub fn deinit(ch: *Channel) void {
        ch.sendJson(receiver_id, ns_connection, Close{}) catch {};
        ch.client.end() catch {};
        ch.stream_writer.interface.flush() catch {};
        ch.stream.close(ch.io);
        ch.frame.deinit(ch.gpa);
        ch.json.deinit();
        ch.gpa.destroy(ch.buffers);
        ch.gpa.destroy(ch);
    }

    /// Our own address on the interface that reaches the receiver (the
    /// connected socket's local address), for URLs the receiver must fetch
    /// from us. The port is the socket's, not one to serve on.
    pub fn localAddress(ch: *const Channel) net.Ip4Address {
        return ch.stream.socket.address.ip4;
    }

    /// Sends one UTF-8 payload on `namespace` to `destination`.
    pub fn send(ch: *Channel, destination: []const u8, namespace: []const u8, payload_utf8: []const u8) !void {
        log.debug("-> {s} {s}\n   {s}", .{ destination, namespace, payload_utf8 });
        try proto.encode(.{
            .source_id = sender_id,
            .destination_id = destination,
            .namespace = namespace,
            .payload = .{ .utf8 = payload_utf8 },
        }, &ch.client.writer);
        try ch.client.writer.flush();
        try ch.stream_writer.interface.flush();
    }

    /// Serialises `value` and sends it, reusing the channel's JSON buffer.
    pub fn sendJson(ch: *Channel, destination: []const u8, namespace: []const u8, value: anytype) !void {
        ch.json.clearRetainingCapacity();
        try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &ch.json.writer);
        try ch.send(destination, namespace, ch.json.written());
    }

    /// Blocks for the next message, answering heartbeat PINGs itself.
    /// The receiver ending the session, either with a CLOSE message or by
    /// hanging up (a TCP FIN, `error.EndOfStream` from the reader), is the
    /// normal end of a session and surfaces as `error.ConnectionClosed`.
    pub fn receive(ch: *Channel) !proto.Message {
        while (true) {
            const r = &ch.client.reader;
            const len = r.takeInt(u32, .big) catch |err| switch (err) {
                error.EndOfStream => return error.ConnectionClosed,
                else => return err,
            };
            if (len > max_frame) return error.FrameTooLarge;
            try ch.frame.resize(ch.gpa, len);
            r.readSliceAll(ch.frame.items) catch |err| switch (err) {
                error.EndOfStream => return error.ConnectionClosed,
                else => return err,
            };

            const msg = try proto.decode(ch.frame.items);
            const text = if (msg.payload == .utf8) msg.payload.utf8 else "<binary>";
            if (std.mem.eql(u8, msg.namespace, ns_heartbeat)) {
                if (std.mem.find(u8, text, "\"PING\"") != null) {
                    try ch.sendJson(msg.source_id, ns_heartbeat, Pong{});
                }
                continue;
            }
            log.debug("<- {s} {s}\n   {s}", .{ msg.source_id, msg.namespace, text });
            if (std.mem.eql(u8, msg.namespace, ns_connection)) {
                if (std.mem.find(u8, text, "\"CLOSE\"") != null) return error.ConnectionClosed;
                continue;
            }
            return msg;
        }
    }

    /// The fields every receiver message may carry; `status` is decoded per
    /// message type since it is an object, an array or a string.
    pub const Reply = struct {
        type: []const u8 = "",
        requestId: ?i64 = null,
        launchRequestId: ?i64 = null,
        reason: ?[]const u8 = null,
        status: Json = .null,
    };

    /// Parses a message's JSON payload; null when it is binary or not JSON.
    pub fn parseReply(arena: std.mem.Allocator, msg: proto.Message) ?Reply {
        if (msg.payload != .utf8) return null;
        return std.json.parseFromSliceLeaky(Reply, arena, msg.payload.utf8, parse_options) catch null;
    }

    /// Sends `payload` (a pointer to a struct with a `requestId` field) and
    /// waits for the reply that carries the same id. Unrelated messages in
    /// between are dropped. An error reply (LAUNCH_ERROR, LOAD_FAILED, ...)
    /// is logged and returned as `error.ReceiverRefused`.
    pub fn request(ch: *Channel, arena: std.mem.Allocator, destination: []const u8, namespace: []const u8, payload: anytype, expected_type: []const u8) !Reply {
        ch.request_id += 1;
        payload.requestId = ch.request_id;
        try ch.sendJson(destination, namespace, payload.*);

        while (true) {
            const msg = try ch.receive();
            const reply = parseReply(arena, msg) orelse continue;
            // Progress of our LAUNCH: the device may ask its user first.
            if (reply.launchRequestId == ch.request_id) {
                const status = if (reply.status == .string) reply.status.string else "";
                if (std.mem.eql(u8, status, "USER_PENDING_AUTHORIZATION")) {
                    log.info("waiting for the cast to be allowed on the device...", .{});
                } else if (std.mem.eql(u8, status, "USER_NOT_ALLOWED")) {
                    log.warn("the cast was denied on the device", .{});
                    return error.ReceiverRefused;
                }
                continue;
            }
            if (reply.requestId != ch.request_id) continue;
            if (std.mem.eql(u8, reply.type, expected_type)) return reply;
            log.warn("receiver answered {s}{s}{s}", .{ reply.type, if (reply.reason != null) ": " else "", reply.reason orelse "" });
            return error.ReceiverRefused;
        }
    }

    // --- receiver namespace -------------------------------------------------

    pub const App = struct {
        appId: []const u8 = "",
        displayName: []const u8 = "",
        transportId: []const u8 = "",
        sessionId: []const u8 = "",
        statusText: []const u8 = "",
        isIdleScreen: bool = false,
        namespaces: []const struct { name: []const u8 = "" } = &.{},

        /// Whether the app accepts media namespace commands.
        pub fn hasMedia(a: App) bool {
            for (a.namespaces) |n| if (std.mem.eql(u8, n.name, ns_media)) return true;
            return false;
        }
    };

    pub const Status = struct {
        applications: []const App = &.{},
        volume: struct { level: f64 = 0, muted: bool = false } = .{},

        /// The running app with this id, if the receiver reports one.
        pub fn find(s: Status, app_id: []const u8) ?App {
            for (s.applications) |a| if (std.mem.eql(u8, a.appId, app_id)) return a;
            return null;
        }

        /// The app currently able to play media, if any.
        pub fn mediaApp(s: Status) ?App {
            for (s.applications) |a| if (a.hasMedia() and !a.isIdleScreen) return a;
            return null;
        }
    };

    fn parseStatus(arena: std.mem.Allocator, reply: Reply) !Status {
        return std.json.parseFromValueLeaky(Status, arena, reply.status, parse_options) catch |err| {
            log.warn("unexpected RECEIVER_STATUS shape: {s}", .{@errorName(err)});
            return error.BadReply;
        };
    }

    /// Asks the receiver what it is running.
    pub fn getStatus(ch: *Channel, arena: std.mem.Allocator) !Status {
        var req: GetStatus = .{};
        return parseStatus(arena, try ch.request(arena, receiver_id, ns_receiver, &req, "RECEIVER_STATUS"));
    }

    /// Starts an app and waits until the receiver lists it as running.
    pub fn launch(ch: *Channel, arena: std.mem.Allocator, app_id: []const u8) !App {
        var req: Launch = .{ .appId = app_id };
        const status = try parseStatus(arena, try ch.request(arena, receiver_id, ns_receiver, &req, "RECEIVER_STATUS"));
        return status.find(app_id) orelse error.LaunchFailed;
    }

    /// Stops the app holding `session_id`.
    pub fn stopApp(ch: *Channel, arena: std.mem.Allocator, session_id: []const u8) !void {
        var req: StopApp = .{ .sessionId = session_id };
        _ = try ch.request(arena, receiver_id, ns_receiver, &req, "RECEIVER_STATUS");
    }

    /// Required before talking to an app on its transport id.
    pub fn connectTransport(ch: *Channel, transport_id: []const u8) !void {
        try ch.sendJson(transport_id, ns_connection, Connect{});
    }

    // --- media namespace ----------------------------------------------------

    /// `playerState` of a MEDIA_STATUS; tags are the protocol's own words.
    pub const PlayerState = enum {
        IDLE,
        PLAYING,
        PAUSED,
        BUFFERING,
        UNKNOWN,

        pub const jsonParseFromValue = LenientJson(@This()).jsonParseFromValue;
        pub const jsonParse = LenientJson(@This()).jsonParse;
    };

    /// `idleReason` of a MEDIA_STATUS; INTERRUPTED (which a seek-reload
    /// produces) is not terminal.
    pub const IdleReason = enum {
        FINISHED,
        CANCELLED,
        INTERRUPTED,
        ERROR,
        UNKNOWN,

        pub const jsonParseFromValue = LenientJson(@This()).jsonParseFromValue;
        pub const jsonParse = LenientJson(@This()).jsonParse;
    };

    pub const MediaStatus = struct {
        mediaSessionId: i64 = 0,
        playerState: PlayerState = .UNKNOWN,
        currentTime: f64 = 0,
        playbackRate: f64 = 1,
        idleReason: ?IdleReason = null,
        /// Absent from replies to commands; only status broadcasts carry it.
        media: ?struct { duration: ?f64 = null } = null,

        /// The item's length in seconds, when the receiver knows it.
        pub fn duration(m: MediaStatus) ?f64 {
            return if (m.media) |x| x.duration else null;
        }

        /// True only for terminal states.
        pub fn isFinished(m: MediaStatus) bool {
            if (m.playerState != .IDLE) return false;
            return switch (m.idleReason orelse return false) {
                .FINISHED, .CANCELLED, .ERROR => true,
                .INTERRUPTED, .UNKNOWN => false,
            };
        }
    };

    /// A side-loaded WebVTT track offered to the receiver.
    pub const TextTrack = struct {
        id: u32,
        /// WebVTT URL the receiver fetches.
        url: []const u8,
        language: []const u8 = "und",
        /// Shown in the receiver's subtitle menu.
        name: []const u8 = "Subtitles",
    };

    pub const LoadOptions = struct {
        url: []const u8,
        content_type: []const u8,
        title: ?[]const u8 = null,
        /// Sidecar subtitle tracks, each WebVTT and reachable by the receiver.
        text_tracks: []const TextTrack = &.{},
        /// Which track ids start enabled; empty means subtitles off.
        active_track_ids: []const u32 = &.{},
        /// Total length in seconds, shown by the receiver's progress bar.
        duration: ?f64 = null,
        /// True when the URL is an HLS playlist with MPEG-TS segments; the
        /// receiver must be told, or it assumes fMP4 and fails to load.
        hls: bool = false,
    };

    /// Hands the app a URL to play, with its subtitle tracks.
    pub fn load(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8, opts: LoadOptions) !MediaStatus {
        const tracks = try arena.alloc(Load.Track, opts.text_tracks.len);
        for (opts.text_tracks, 0..) |t, i| tracks[i] = .{
            .trackId = t.id,
            .trackContentId = t.url,
            .language = t.language,
            .name = t.name,
        };
        var req: Load = .{
            .currentTime = 0,
            .media = .{
                .contentId = opts.url,
                .contentType = opts.content_type,
                .duration = opts.duration,
                .metadata = if (opts.title) |t| .{ .title = t } else null,
                .hlsSegmentFormat = if (opts.hls) "ts" else null,
                .hlsVideoSegmentFormat = if (opts.hls) "MPEG2_TS" else null,
            },
        };
        if (tracks.len > 0) {
            req.media.tracks = tracks;
            req.media.textTrackStyle = .{};
            // activeTrackIds goes on the LOAD itself: a later EDIT_TRACKS_INFO
            // races the session and fails with INVALID_MEDIA_SESSION_ID.
            req.activeTrackIds = opts.active_track_ids;
        }
        return ch.mediaRequest(arena, transport_id, &req);
    }

    fn mediaRequest(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8, req: anytype) !MediaStatus {
        const reply = try ch.request(arena, transport_id, ns_media, req, "MEDIA_STATUS");
        return mediaStatusFrom(arena, reply) orelse badMediaStatus();
    }

    /// The first entry of a MEDIA_STATUS reply, or null if it has none.
    pub fn mediaStatusFrom(arena: std.mem.Allocator, reply: Reply) ?MediaStatus {
        const list = std.json.parseFromValueLeaky([]const MediaStatus, arena, reply.status, parse_options) catch return null;
        return if (list.len > 0) list[0] else null;
    }

    /// Asks the app for its media status. `error.NoMedia` when nothing is loaded.
    pub fn getMediaStatus(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8) !MediaStatus {
        var req: GetStatus = .{};
        const reply = try ch.request(arena, transport_id, ns_media, &req, "MEDIA_STATUS");
        return mediaStatusFrom(arena, reply) orelse error.NoMedia;
    }

    /// Rate between 0.5 and 2.0 on the Default Media Receiver.
    pub fn setPlaybackRate(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8, media_session_id: i64, rate: f64) !MediaStatus {
        var req: SetPlaybackRate = .{ .mediaSessionId = media_session_id, .playbackRate = rate };
        return ch.mediaRequest(arena, transport_id, &req);
    }

    /// A media command that takes no arguments, such as PAUSE or STOP.
    pub fn mediaCommand(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8, media_session_id: i64, kind: []const u8) !MediaStatus {
        var req: MediaCommand = .{ .type = kind, .mediaSessionId = media_session_id };
        return ch.mediaRequest(arena, transport_id, &req);
    }

    /// Jumps to `seconds` within the current item.
    pub fn seek(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8, media_session_id: i64, seconds: f64) !MediaStatus {
        var req: Seek = .{ .mediaSessionId = media_session_id, .currentTime = seconds };
        return ch.mediaRequest(arena, transport_id, &req);
    }
};

/// The json.Parse hooks that read a protocol word as `E`, falling back to
/// `E.UNKNOWN` for a word we do not know, since receivers may add states.
fn LenientJson(comptime E: type) type {
    return struct {
        fn jsonParseFromValue(_: std.mem.Allocator, source: Json, _: std.json.ParseOptions) error{UnexpectedToken}!E {
            if (source != .string) return error.UnexpectedToken;
            return std.meta.stringToEnum(E, source.string) orelse .UNKNOWN;
        }

        fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !E {
            return jsonParseFromValue(allocator, try Json.jsonParse(allocator, source, options), options);
        }
    };
}

// --- wire structs (field names are the JSON keys) ----------------------------

const Connect = struct { type: []const u8 = "CONNECT" };
const Close = struct { type: []const u8 = "CLOSE" };
const Pong = struct { type: []const u8 = "PONG" };
const GetStatus = struct { type: []const u8 = "GET_STATUS", requestId: u32 = 0 };
const Launch = struct { type: []const u8 = "LAUNCH", requestId: u32 = 0, appId: []const u8 };
const StopApp = struct { type: []const u8 = "STOP", requestId: u32 = 0, sessionId: []const u8 };
const MediaCommand = struct { type: []const u8, requestId: u32 = 0, mediaSessionId: i64 };
const Seek = struct { type: []const u8 = "SEEK", requestId: u32 = 0, mediaSessionId: i64, currentTime: f64 };
const SetPlaybackRate = struct { type: []const u8 = "SET_PLAYBACK_RATE", requestId: u32 = 0, mediaSessionId: i64, playbackRate: f64 };

/// Readable defaults; without a style some receivers render nothing.
const TextTrackStyle = struct {
    backgroundColor: []const u8 = "#00000080",
    foregroundColor: []const u8 = "#FFFFFFFF",
    edgeType: []const u8 = "DROP_SHADOW",
    edgeColor: []const u8 = "#000000FF",
    fontScale: f64 = 1.0,
    fontStyle: []const u8 = "NORMAL",
    fontFamily: []const u8 = "Droid Sans",
    fontGenericFamily: []const u8 = "SANS_SERIF",
    windowType: []const u8 = "NONE",
};

const Load = struct {
    type: []const u8 = "LOAD",
    requestId: u32 = 0,
    autoplay: bool = true,
    currentTime: f64 = 0,
    media: Media,
    activeTrackIds: ?[]const u32 = null,

    const Media = struct {
        contentId: []const u8,
        contentType: []const u8,
        duration: ?f64 = null,
        streamType: []const u8 = "BUFFERED",
        metadata: ?Metadata = null,
        tracks: ?[]const Track = null,
        textTrackStyle: ?TextTrackStyle = null,
        hlsSegmentFormat: ?[]const u8 = null,
        hlsVideoSegmentFormat: ?[]const u8 = null,
    };
    const Metadata = struct { metadataType: u32 = 0, title: []const u8 };
    const Track = struct {
        trackId: u32,
        type: []const u8 = "TEXT",
        subtype: []const u8 = "SUBTITLES",
        trackContentId: []const u8,
        trackContentType: []const u8 = "text/vtt",
        language: []const u8,
        name: []const u8,
    };
};

test "wire structs serialise to the expected JSON" {
    const gpa = std.testing.allocator;
    var req: Load = .{ .media = .{ .contentId = "http://x/a.mp4", .contentType = "video/mp4" } };
    req.requestId = 7;
    const text = try std.json.Stringify.valueAlloc(gpa, req, .{ .emit_null_optional_fields = false });
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        \\{"type":"LOAD","requestId":7,"autoplay":true,"currentTime":0,"media":{"contentId":"http://x/a.mp4","contentType":"video/mp4","streamType":"BUFFERED"}}
    , text);
}

test "media status parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{"type":"MEDIA_STATUS","requestId":3,"status":[{"mediaSessionId":1,"playerState":"PLAYING","currentTime":12.5,"playbackRate":1,"media":{"duration":600,"contentId":"x"},"extra":true}]}
    ;
    const reply = try std.json.parseFromSliceLeaky(Channel.Reply, arena.allocator(), text, parse_options);
    try std.testing.expectEqual(@as(?i64, 3), reply.requestId);
    const s = Channel.mediaStatusFrom(arena.allocator(), reply).?;
    try std.testing.expectEqual(@as(i64, 1), s.mediaSessionId);
    try std.testing.expectEqual(Channel.PlayerState.PLAYING, s.playerState);
    try std.testing.expectEqual(@as(f64, 12.5), s.currentTime);
    try std.testing.expectEqual(@as(?f64, 600), s.duration());
    try std.testing.expect(!s.isFinished());
}

test "receiver status parsing tolerates unknown words and fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{"type":"RECEIVER_STATUS","requestId":1,"status":{"applications":[{"appId":"CC1AD845","displayName":"Default Media Receiver","namespaces":[{"name":"urn:x-cast:com.google.cast.media"}],"sessionId":"s","transportId":"t","isIdleScreen":false,"launchedFromCloud":false}],"volume":{"controlType":"attenuation","level":0.5,"muted":false,"stepInterval":0.05}}}
    ;
    const reply = try std.json.parseFromSliceLeaky(Channel.Reply, arena.allocator(), text, parse_options);
    const st = try Channel.parseStatus(arena.allocator(), reply);
    try std.testing.expectEqual(@as(f64, 0.5), st.volume.level);
    try std.testing.expect(st.mediaApp() != null);
    try std.testing.expectEqualStrings("t", st.find("CC1AD845").?.transportId);

    const media = try std.json.parseFromSliceLeaky(Channel.MediaStatus, arena.allocator(),
        \\{"playerState":"LOADING","idleReason":"WHATEVER"}
    , parse_options);
    try std.testing.expectEqual(Channel.PlayerState.UNKNOWN, media.playerState);
    try std.testing.expectEqual(@as(?Channel.IdleReason, .UNKNOWN), media.idleReason);
}
