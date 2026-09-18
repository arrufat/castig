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

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const tls = std.crypto.tls;
const proto = @import("proto.zig");

pub const ns_connection = "urn:x-cast:com.google.cast.tp.connection";
pub const ns_heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat";
pub const ns_receiver = "urn:x-cast:com.google.cast.receiver";
pub const ns_media = "urn:x-cast:com.google.cast.media";

pub const default_media_receiver = "CC1AD845";
pub const default_port: u16 = 8009;

const sender_id = "sender-0";
const receiver_id = "receiver-0";
const buffer_len = tls.max_ciphertext_record_len;
/// Anything bigger than this is not a Cast message.
const max_frame = 1 << 20;

pub const Json = std.json.Value;

pub const Error = error{
    FrameTooLarge,
    RequestFailed,
    LaunchFailed,
    ConnectionClosed,
};

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
    /// Dump every message on stderr.
    debug: bool = false,

    /// Opens the TLS connection and sends CONNECT to the receiver.
    /// The channel lives on the heap because the TLS client keeps pointers into it.
    pub const Options = struct {
        /// Print every message exchanged on stderr.
        debug: bool = false,
    };

    pub fn connect(io: Io, gpa: std.mem.Allocator, address: net.Ip4Address, options: Options) !*Channel {
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
            .debug = options.debug,
        };

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

    pub fn deinit(ch: *Channel) void {
        ch.sendJson(receiver_id, ns_connection, Close{}) catch {};
        ch.client.end() catch {};
        ch.stream_writer.interface.flush() catch {};
        ch.stream.close(ch.io);
        ch.frame.deinit(ch.gpa);
        ch.gpa.destroy(ch.buffers);
        ch.gpa.destroy(ch);
    }

    pub fn send(ch: *Channel, destination: []const u8, namespace: []const u8, payload_utf8: []const u8) !void {
        if (ch.debug) std.debug.print("-> {s} {s}\n   {s}\n", .{ destination, namespace, payload_utf8 });
        try proto.encode(.{
            .source_id = sender_id,
            .destination_id = destination,
            .namespace = namespace,
            .payload = .{ .utf8 = payload_utf8 },
        }, &ch.client.writer);
        try ch.client.writer.flush();
        try ch.stream_writer.interface.flush();
    }

    pub fn sendJson(ch: *Channel, destination: []const u8, namespace: []const u8, value: anytype) !void {
        const text = try std.json.Stringify.valueAlloc(ch.gpa, value, .{ .emit_null_optional_fields = false });
        defer ch.gpa.free(text);
        try ch.send(destination, namespace, text);
    }

    /// Blocks for the next message, answering heartbeat PINGs itself.
    pub fn receive(ch: *Channel) !proto.Message {
        while (true) {
            const r = &ch.client.reader;
            const prefix = try r.takeArray(4);
            const len = std.mem.readInt(u32, prefix, .big);
            if (len > max_frame) return error.FrameTooLarge;
            try ch.frame.resize(ch.gpa, len);
            try r.readSliceAll(ch.frame.items);

            const msg = try proto.decode(ch.frame.items);
            if (ch.debug and !std.mem.eql(u8, msg.namespace, ns_heartbeat)) {
                std.debug.print("<- {s} {s}\n   {s}\n", .{ msg.source_id, msg.namespace, if (msg.payload == .utf8) msg.payload.utf8 else "<binary>" });
            }
            if (std.mem.eql(u8, msg.namespace, ns_heartbeat)) {
                if (msg.payload == .utf8 and std.mem.indexOf(u8, msg.payload.utf8, "\"PING\"") != null) {
                    try ch.sendJson(msg.source_id, ns_heartbeat, Pong{});
                }
                continue;
            }
            return msg;
        }
    }

    pub fn parsePayload(arena: std.mem.Allocator, msg: proto.Message) !Json {
        if (msg.payload != .utf8) return .null;
        return std.json.parseFromSliceLeaky(Json, arena, msg.payload.utf8, .{});
    }

    /// Sends `payload` (a pointer to a struct with a `requestId` field) and
    /// waits for the reply that carries the same id. Unrelated messages in
    /// between are dropped. An error reply (LAUNCH_ERROR, LOAD_FAILED, ...)
    /// is reported on stderr and returned as `error.RequestFailed`.
    pub fn request(ch: *Channel, arena: std.mem.Allocator, destination: []const u8, namespace: []const u8, payload: anytype, expected_type: []const u8) !Json {
        ch.request_id += 1;
        payload.requestId = ch.request_id;
        try ch.sendJson(destination, namespace, payload.*);

        while (true) {
            const msg = try ch.receive();
            if (std.mem.eql(u8, msg.namespace, ns_connection)) {
                if (std.mem.indexOf(u8, msg.payload.utf8, "\"CLOSE\"") != null) return error.ConnectionClosed;
                continue;
            }
            const json = try parsePayload(arena, msg);
            if (getInt(json, "requestId") != ch.request_id) continue;
            const kind = getStr(json, "type") orelse continue;
            if (std.mem.eql(u8, kind, expected_type)) return json;
            std.debug.print("receiver answered {s}", .{kind});
            if (getStr(json, "reason")) |reason| std.debug.print(": {s}", .{reason});
            std.debug.print("\n", .{});
            return error.RequestFailed;
        }
    }

    // --- receiver namespace -------------------------------------------------

    pub const App = struct {
        app_id: []const u8,
        display_name: []const u8,
        transport_id: []const u8,
        session_id: []const u8,
        status_text: []const u8,
        is_idle_screen: bool,
    };

    pub const Status = struct {
        apps: []App,
        volume_level: f64,
        muted: bool,

        pub fn find(s: Status, app_id: []const u8) ?App {
            for (s.apps) |a| if (std.mem.eql(u8, a.app_id, app_id)) return a;
            return null;
        }
    };

    pub fn getStatus(ch: *Channel, arena: std.mem.Allocator) !Status {
        var req: GetStatus = .{};
        const json = try ch.request(arena, receiver_id, ns_receiver, &req, "RECEIVER_STATUS");
        return parseStatus(arena, json);
    }

    pub fn launch(ch: *Channel, arena: std.mem.Allocator, app_id: []const u8) !App {
        var req: Launch = .{ .appId = app_id };
        const json = try ch.request(arena, receiver_id, ns_receiver, &req, "RECEIVER_STATUS");
        const status = try parseStatus(arena, json);
        return status.find(app_id) orelse error.LaunchFailed;
    }

    pub fn stopApp(ch: *Channel, arena: std.mem.Allocator, session_id: []const u8) !void {
        var req: StopApp = .{ .sessionId = session_id };
        _ = try ch.request(arena, receiver_id, ns_receiver, &req, "RECEIVER_STATUS");
    }

    /// Required before talking to an app on its transport id.
    pub fn connectTransport(ch: *Channel, transport_id: []const u8) !void {
        try ch.sendJson(transport_id, ns_connection, Connect{});
    }

    fn parseStatus(arena: std.mem.Allocator, json: Json) !Status {
        const status = getObj(json, "status") orelse return error.RequestFailed;
        var apps: std.ArrayList(App) = .empty;
        if (getArr(status, "applications")) |list| {
            for (list) |a| try apps.append(arena, .{
                .app_id = getStr(a, "appId") orelse "",
                .display_name = getStr(a, "displayName") orelse "",
                .transport_id = getStr(a, "transportId") orelse "",
                .session_id = getStr(a, "sessionId") orelse "",
                .status_text = getStr(a, "statusText") orelse "",
                .is_idle_screen = getBool(a, "isIdleScreen") orelse false,
            });
        }
        const volume = getObj(status, "volume");
        return .{
            .apps = try apps.toOwnedSlice(arena),
            .volume_level = if (volume) |v| getNum(v, "level") orelse 0 else 0,
            .muted = if (volume) |v| getBool(v, "muted") orelse false else false,
        };
    }

    // --- media namespace ----------------------------------------------------

    pub const MediaStatus = struct {
        media_session_id: i64,
        player_state: []const u8,
        current_time: f64,
        duration: ?f64,
        idle_reason: ?[]const u8,

        pub fn isFinished(m: MediaStatus) bool {
            return std.mem.eql(u8, m.player_state, "IDLE") and m.idle_reason != null;
        }
    };

    pub const LoadOptions = struct {
        url: []const u8,
        content_type: []const u8,
        title: ?[]const u8 = null,
        /// Sidecar subtitles, must be WebVTT and reachable by the receiver.
        subtitles_url: ?[]const u8 = null,
        start_time: f64 = 0,
    };

    pub fn load(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8, opts: LoadOptions) !MediaStatus {
        var tracks: [1]Load.Track = undefined;
        var req: Load = .{
            .currentTime = opts.start_time,
            .media = .{
                .contentId = opts.url,
                .contentType = opts.content_type,
                .metadata = if (opts.title) |t| .{ .title = t } else null,
            },
        };
        if (opts.subtitles_url) |vtt| {
            tracks[0] = .{ .trackContentId = vtt };
            req.media.tracks = &tracks;
            req.activeTrackIds = &.{1};
        }
        const json = try ch.request(arena, transport_id, ns_media, &req, "MEDIA_STATUS");
        return mediaStatusFrom(json) orelse error.RequestFailed;
    }

    /// Extracts the first entry of a MEDIA_STATUS message, or null if it has none.
    pub fn mediaStatusFrom(json: Json) ?MediaStatus {
        const list = getArr(json, "status") orelse return null;
        if (list.len == 0) return null;
        const s = list[0];
        const media = getObj(s, "media");
        return .{
            .media_session_id = getInt(s, "mediaSessionId") orelse 0,
            .player_state = getStr(s, "playerState") orelse "UNKNOWN",
            .current_time = getNum(s, "currentTime") orelse 0,
            .duration = if (media) |m| getNum(m, "duration") else null,
            .idle_reason = getStr(s, "idleReason"),
        };
    }

    pub fn mediaCommand(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8, media_session_id: i64, kind: []const u8) !MediaStatus {
        var req: MediaCommand = .{ .type = kind, .mediaSessionId = media_session_id };
        const json = try ch.request(arena, transport_id, ns_media, &req, "MEDIA_STATUS");
        return mediaStatusFrom(json) orelse error.RequestFailed;
    }

    pub fn seek(ch: *Channel, arena: std.mem.Allocator, transport_id: []const u8, media_session_id: i64, seconds: f64) !MediaStatus {
        var req: Seek = .{ .mediaSessionId = media_session_id, .currentTime = seconds };
        const json = try ch.request(arena, transport_id, ns_media, &req, "MEDIA_STATUS");
        return mediaStatusFrom(json) orelse error.RequestFailed;
    }
};

// --- wire structs (field names are the JSON keys) ----------------------------

const Connect = struct { type: []const u8 = "CONNECT" };
const Close = struct { type: []const u8 = "CLOSE" };
const Pong = struct { type: []const u8 = "PONG" };
const GetStatus = struct { type: []const u8 = "GET_STATUS", requestId: u32 = 0 };
const Launch = struct { type: []const u8 = "LAUNCH", requestId: u32 = 0, appId: []const u8 };
const StopApp = struct { type: []const u8 = "STOP", requestId: u32 = 0, sessionId: []const u8 };
const MediaCommand = struct { type: []const u8, requestId: u32 = 0, mediaSessionId: i64 };
const Seek = struct { type: []const u8 = "SEEK", requestId: u32 = 0, mediaSessionId: i64, currentTime: f64 };

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
        streamType: []const u8 = "BUFFERED",
        metadata: ?Metadata = null,
        tracks: ?[]const Track = null,
    };
    const Metadata = struct { metadataType: u32 = 0, title: []const u8 };
    const Track = struct {
        trackId: u32 = 1,
        type: []const u8 = "TEXT",
        subtype: []const u8 = "SUBTITLES",
        trackContentId: []const u8,
        trackContentType: []const u8 = "text/vtt",
        language: []const u8 = "en",
    };
};

// --- json.Value helpers ------------------------------------------------------

pub fn getObj(v: Json, key: []const u8) ?Json {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return if (child == .object) child else null;
}

pub fn getArr(v: Json, key: []const u8) ?[]Json {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return if (child == .array) child.array.items else null;
}

pub fn getStr(v: Json, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return if (child == .string) child.string else null;
}

pub fn getInt(v: Json, key: []const u8) ?i64 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return switch (child) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn getNum(v: Json, key: []const u8) ?f64 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return switch (child) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn getBool(v: Json, key: []const u8) ?bool {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return if (child == .bool) child.bool else null;
}

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
    const arena = std.testing.allocator;
    const text =
        \\{"type":"MEDIA_STATUS","requestId":3,"status":[{"mediaSessionId":1,"playerState":"PLAYING","currentTime":12.5,"media":{"duration":600}}]}
    ;
    const parsed = try std.json.parseFromSlice(Json, arena, text, .{});
    defer parsed.deinit();
    const s = Channel.mediaStatusFrom(parsed.value).?;
    try std.testing.expectEqual(@as(i64, 1), s.media_session_id);
    try std.testing.expectEqualStrings("PLAYING", s.player_state);
    try std.testing.expectEqual(@as(f64, 12.5), s.current_time);
    try std.testing.expectEqual(@as(?f64, 600), s.duration);
    try std.testing.expect(!s.isFinished());
}
