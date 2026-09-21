//! UPnP AV: driving a MediaRenderer over SOAP.
//!
//! The model is Cast's: the renderer is handed a URL and pulls the bytes
//! back over HTTP with Range. What differs is that there is no app to
//! launch, no status pushed to us, and no agreement between renderers about
//! anything the specification left open. So capabilities are read from the
//! device's own SCPD rather than assumed, and playback is polled.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Env = @import("../env.zig").Env;
const playback = @import("playback.zig");
const xml = @import("xml.zig");

/// SSDP discovery and the device description.
pub const ssdp = @import("dlna/ssdp.zig");
/// The SOAP envelope, the call, and what a refusal means.
pub const soap = @import("dlna/soap.zig");
/// `SetAVTransportURI` metadata and the UPnP clock format.
pub const didl = @import("dlna/didl.zig");

const log = std.log.scoped(.dlna);

/// Every AVTransport action takes this first.
const instance: soap.Arg = .{ .name = "InstanceID", .value = "0" };

pub const Renderer = struct {
    env: Env,
    gpa: std.mem.Allocator,
    http: std.http.Client,
    address: net.Ip4Address,
    friendly_name: []const u8,
    /// The AVTransport service type, as advertised.
    service: []const u8,
    control_url: []const u8,
    caps: Caps,
    /// Reset at the start of each operation, so a poll a second for the
    /// length of a film stays bounded.
    scratch: std.heap.ArenaAllocator,

    last: playback.Playback = .{},
    /// Set once the renderer has actually played, which is what makes a
    /// later STOPPED the end of something rather than the start.
    played: bool = false,
    /// Consecutive polls reporting a stop. A seek passes through STOPPED on
    /// some renderers, so one reading is not an ending.
    stops: u8 = 0,
    /// Polls since the URI was set, to notice a load that never starts.
    polls: u32 = 0,
    /// Consecutive polls that could not reach the renderer at all.
    failures: u8 = 0,
    /// What the item is worth, once anything has said so.
    duration: ?f64 = null,
    /// The furthest point reached while actually playing. A renderer resets
    /// its reported position to zero when it stops, including when it stops
    /// because the item ended, so the live reading cannot say where it got
    /// to and this is what decides finished from cancelled.
    played_to: f64 = 0,

    /// What the device admits to in its SCPD, rather than what we hope.
    pub const Caps = struct {
        rel_time_seek: bool = false,
        abs_time_seek: bool = false,
        /// Any speed other than 1 in `TransportPlaySpeed`. A renderer that
        /// declares no list at all plays at 1x only.
        speeds: bool = false,
    };

    /// Reads the description at `location`, then the AVTransport SCPD for
    /// what the renderer can actually be asked to do.
    pub fn connect(env: Env, address: net.Ip4Address, location: []const u8) !*Renderer {
        const r = try env.gpa.create(Renderer);
        errdefer env.gpa.destroy(r);
        r.* = .{
            .env = env,
            .gpa = env.gpa,
            .http = .{ .allocator = env.gpa, .io = env.io },
            .address = address,
            .friendly_name = "",
            .service = "",
            .control_url = "",
            .caps = .{},
            .scratch = .init(env.gpa),
        };
        errdefer r.http.deinit();
        errdefer r.scratch.deinit();

        const description = try ssdp.describe(env.arena, &r.http, location);
        r.friendly_name = description.friendly_name;
        r.service = description.av_transport.type;
        r.control_url = description.av_transport.control_url;
        r.caps = r.readCaps(description.av_transport.scpd_url);
        log.debug("{s}: {s} at {s}", .{ r.friendly_name, r.service, r.control_url });
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        r.http.deinit();
        r.scratch.deinit();
        r.gpa.destroy(r);
    }

    /// The SCPD lists what each argument accepts. Reading it is one GET, and
    /// it turns "seek silently does nothing" into a refusal we can explain.
    fn readCaps(r: *Renderer, scpd_url: []const u8) Caps {
        if (scpd_url.len == 0) return .{};
        var body: Io.Writer.Allocating = .init(r.scratch.allocator());
        const res = r.http.fetch(.{
            .location = .{ .url = scpd_url },
            .method = .GET,
            .headers = .{ .user_agent = .{ .override = soap.user_agent } },
            .response_writer = &body.writer,
        }) catch |err| {
            log.debug("no scpd at {s}: {s}", .{ scpd_url, @errorName(err) });
            return .{};
        };
        if (res.status != .ok) return .{};
        return parseCaps(body.written());
    }

    pub fn localAddress(r: *const Renderer) net.Ip4Address {
        return r.address;
    }

    fn action(r: *Renderer, name: []const u8, args: []const soap.Arg) ![]const u8 {
        return soap.call(r.scratch.allocator(), &r.http, r.control_url, .{
            .service = r.service,
            .name = name,
            .args = args,
        });
    }

    /// Hands the renderer a URL, with the metadata it decides everything from.
    pub fn load(r: *Renderer, req: playback.LoadRequest) !playback.Playback {
        _ = r.scratch.reset(.retain_capacity);
        var meta: Io.Writer.Allocating = .init(r.scratch.allocator());
        try didl.write(&meta.writer, .{
            .url = req.url,
            .content_type = req.content_type,
            .protocol_info = req.protocol_info orelse
                try didl.protocolInfo(r.scratch.allocator(), req.content_type, didl.contentFeatures(true)),
            .title = req.title orelse "castig",
            .duration = req.duration,
        });

        // A renderer that is still playing refuses the new URI with 701, so
        // clear it first. Failing here is fine: it may already be stopped.
        _ = r.action("Stop", &.{instance}) catch {};
        _ = try r.action("SetAVTransportURI", &.{
            instance,
            .{ .name = "CurrentURI", .value = req.url },
            .{ .name = "CurrentURIMetaData", .value = meta.written() },
        });
        try r.startPlaying();

        r.duration = req.duration;
        r.played = false;
        r.played_to = 0;
        r.stops = 0;
        r.polls = 0;
        r.last = .{ .state = .buffering, .duration = req.duration };
        return r.last;
    }

    pub fn play(r: *Renderer) !playback.Playback {
        try r.startPlaying();
        return r.poll();
    }

    /// A renderer backed by GStreamer changes state in its own time, so a
    /// Play that follows a Stop can land while the transport is still
    /// settling and be refused with 701. Asking again is the whole fix.
    fn startPlaying(r: *Renderer) !void {
        var attempt: u8 = 1;
        while (true) : (attempt += 1) {
            _ = r.action("Play", &.{ instance, .{ .name = "Speed", .value = "1" } }) catch |err| switch (err) {
                error.TransitionNotAvailable => {
                    if (attempt >= play_attempts) return err;
                    const settle: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(300), .clock = .awake } };
                    settle.sleep(r.env.io) catch {};
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    pub fn pause(r: *Renderer) !playback.Playback {
        _ = try r.action("Pause", &.{instance});
        return r.settled(.{ .state = .paused });
    }

    pub fn stop(r: *Renderer) !playback.Playback {
        _ = try r.action("Stop", &.{instance});
        return r.settled(.{ .state = .idle });
    }

    /// A poll right after a command still describes the state before it: a
    /// renderer transitions in its own time and only then updates what it
    /// reports. So take the fresh reading and put back what we just asked
    /// for, which is what the next poll will say anyway.
    fn settled(r: *Renderer, intent: struct { state: ?playback.State = null, position: ?f64 = null }) !playback.Playback {
        var now = try r.poll();
        if (intent.state) |state| {
            now.state = state;
            // An intended stop is a command, not the item ending.
            now.ended = null;
            r.stops = 0;
        }
        if (intent.position) |at| now.position = at;
        r.last = now;
        return now;
    }

    /// Seeks by whichever time unit the renderer said it understands,
    /// falling through when it refuses one it advertised anyway.
    pub fn seek(r: *Renderer, seconds: f64) !playback.Playback {
        _ = r.scratch.reset(.retain_capacity);
        var buf: [16]u8 = undefined;
        const target = didl.clock(&buf, seconds);

        const units = [_]struct { ok: bool, name: []const u8 }{
            .{ .ok = r.caps.rel_time_seek, .name = "REL_TIME" },
            .{ .ok = r.caps.abs_time_seek, .name = "ABS_TIME" },
        };
        var offered = false;
        for (units) |unit| {
            if (!unit.ok) continue;
            offered = true;
            _ = r.action("Seek", &.{
                instance,
                .{ .name = "Unit", .value = unit.name },
                .{ .name = "Target", .value = target },
            }) catch |err| switch (err) {
                error.SeekModeNotSupported, error.IllegalSeekTarget => continue,
                else => return err,
            };
            // The renderer reports the old position for a moment yet, so
            // answer with where it was asked to go.
            return r.settled(.{ .position = seconds });
        }
        log.warn("{s} does not seek by time", .{r.friendly_name});
        if (!offered) return error.InvalidSeek;
        return error.InvalidSeek;
    }

    /// Nothing worth having implements a speed other than 1.
    pub fn setRate(r: *Renderer, value: f64) !playback.Playback {
        _ = r.scratch.reset(.retain_capacity);
        if (value != 1 and !r.caps.speeds) {
            log.warn("{s} plays at 1x only", .{r.friendly_name});
            return error.InvalidRate;
        }
        var buf: [16]u8 = undefined;
        const speed = std.mem.print(&buf, "{d}", .{value}) catch "1";
        _ = try r.action("Play", &.{ instance, .{ .name = "Speed", .value = speed } });
        return r.poll();
    }

    /// Joins whatever is already loaded, for the one-shot control verbs.
    pub fn attach(r: *Renderer) !playback.Playback {
        _ = r.scratch.reset(.retain_capacity);
        const transport = try r.action("GetTransportInfo", &.{instance});
        const state = xml.text(transport, "CurrentTransportState") orelse "";
        if (std.mem.eql(u8, state, "NO_MEDIA_PRESENT")) {
            log.warn("nothing is loaded on {s}", .{r.friendly_name});
            return error.NothingPlaying;
        }
        // It was already going before we arrived, so a stop from here is an
        // ending rather than a load that never started.
        r.played = true;
        return r.poll();
    }

    /// One tick: what the transport is doing, and where it has got to.
    pub fn poll(r: *Renderer) !playback.Playback {
        _ = r.scratch.reset(.retain_capacity);
        const transport = try r.action("GetTransportInfo", &.{instance});
        const state = xml.text(transport, "CurrentTransportState") orelse "";
        const status = xml.text(transport, "CurrentTransportStatus") orelse "OK";

        const position = try r.action("GetPositionInfo", &.{instance});
        const reported = stateOf(state);
        // A stopped renderer reports a duration of its own devising, so only
        // believe one while there is something loaded to measure.
        if (reported != .idle) {
            if (didl.parseClock(xml.text(position, "TrackDuration") orelse "")) |d| {
                if (d > 0) r.duration = d;
            }
        }
        const at = didl.parseClock(xml.text(position, "RelTime") orelse "") orelse r.last.position;

        r.polls += 1;
        r.failures = 0;
        var now: playback.Playback = .{
            .state = reported,
            .position = at,
            .duration = r.duration,
            .rate = r.last.rate,
        };
        if (now.state == .playing) {
            r.played = true;
            r.played_to = @max(r.played_to, at);
        }

        if (std.mem.eql(u8, status, "ERROR_OCCURRED")) {
            now.ended = .failed;
        } else if (now.state == .idle) {
            r.stops += 1;
            now.ended = r.ending();
        } else {
            r.stops = 0;
        }

        r.last = now;
        return now;
    }

    /// Whether a stop is the end of the item. A seek passes through STOPPED
    /// on several renderers, so it takes two readings; and a load that never
    /// reaches PLAYING is a refusal the renderer did not put into words.
    fn ending(r: *const Renderer) ?playback.EndReason {
        if (r.played) {
            if (r.stops < 2) return null;
            const total = r.duration orelse return .cancelled;
            return if (r.played_to >= total - end_slack) .finished else .cancelled;
        }
        // Nothing ever played. Give it a while before calling it a failure,
        // since a renderer may take seconds to fetch the first bytes.
        return if (r.polls >= silent_failure_polls) .failed else null;
    }
};

/// How many idle polls without ever playing before the load is called dead.
const silent_failure_polls = 15;
/// How many times to ask a settling transport to start.
const play_attempts = 4;
/// How near the end counts as having reached it. Polling is a second apart
/// and a renderer stops a little short of the last frame.
const end_slack = 5;

fn stateOf(transport_state: []const u8) playback.State {
    if (std.mem.eql(u8, transport_state, "PLAYING")) return .playing;
    if (std.mem.eql(u8, transport_state, "PAUSED_PLAYBACK")) return .paused;
    if (std.mem.eql(u8, transport_state, "PAUSED_RECORDING")) return .paused;
    if (std.mem.eql(u8, transport_state, "TRANSITIONING")) return .buffering;
    if (std.mem.eql(u8, transport_state, "STOPPED")) return .idle;
    if (std.mem.eql(u8, transport_state, "NO_MEDIA_PRESENT")) return .idle;
    return .unknown;
}

/// The seek units and play speeds an AVTransport SCPD admits to.
pub fn parseCaps(scpd: []const u8) Renderer.Caps {
    var caps: Renderer.Caps = .{};
    const table = xml.text(scpd, "serviceStateTable") orelse return caps;

    var variables: xml.Scanner = .init(table);
    while (variables.next()) |variable| {
        if (!variable.is("stateVariable")) continue;
        const name = xml.text(variable.body, "name") orelse continue;
        const allowed = xml.text(variable.body, "allowedValueList") orelse continue;

        var values: xml.Scanner = .init(allowed);
        while (values.next()) |value| {
            if (!value.is("allowedValue")) continue;
            if (std.mem.eql(u8, name, "A_ARG_TYPE_SeekMode")) {
                if (std.mem.eql(u8, value.body, "REL_TIME")) caps.rel_time_seek = true;
                if (std.mem.eql(u8, value.body, "ABS_TIME")) caps.abs_time_seek = true;
            } else if (std.mem.eql(u8, name, "TransportPlaySpeed")) {
                if (!std.mem.eql(u8, std.mem.trim(u8, value.body, " "), "1")) caps.speeds = true;
            }
        }
    }
    return caps;
}

test {
    _ = ssdp;
    _ = soap;
    _ = didl;
}

const testing = std.testing;

test "transport states" {
    try testing.expectEqual(playback.State.playing, stateOf("PLAYING"));
    try testing.expectEqual(playback.State.paused, stateOf("PAUSED_PLAYBACK"));
    try testing.expectEqual(playback.State.buffering, stateOf("TRANSITIONING"));
    try testing.expectEqual(playback.State.idle, stateOf("STOPPED"));
    try testing.expectEqual(playback.State.idle, stateOf("NO_MEDIA_PRESENT"));
    try testing.expectEqual(playback.State.unknown, stateOf("RECORDING"));
}

test "capabilities come from the scpd, not from hope" {
    const scpd =
        \\<scpd><serviceStateTable>
        \\<stateVariable><name>A_ARG_TYPE_SeekMode</name>
        \\<allowedValueList><allowedValue>TRACK_NR</allowedValue>
        \\<allowedValue>REL_TIME</allowedValue><allowedValue>ABS_TIME</allowedValue>
        \\<allowedValue>X_DLNA_REL_BYTE</allowedValue></allowedValueList></stateVariable>
        \\<stateVariable><name>TransportPlaySpeed</name>
        \\<allowedValueList><allowedValue>1</allowedValue></allowedValueList></stateVariable>
        \\</serviceStateTable></scpd>
    ;
    const caps = parseCaps(scpd);
    try testing.expect(caps.rel_time_seek);
    try testing.expect(caps.abs_time_seek);
    // A list holding only "1" is not support for another speed.
    try testing.expect(!caps.speeds);

    // Rygel declares TransportPlaySpeed with no list at all, which means 1x.
    const bare = "<scpd><serviceStateTable><stateVariable><name>TransportPlaySpeed</name>" ++
        "<dataType>string</dataType></stateVariable></serviceStateTable></scpd>";
    try testing.expect(!parseCaps(bare).speeds);

    // Nothing to read is nothing claimed.
    try testing.expectEqual(Renderer.Caps{}, parseCaps(""));
    try testing.expectEqual(Renderer.Caps{}, parseCaps("<scpd></scpd>"));
}
