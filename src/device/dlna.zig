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
const sweep = @import("sweep.zig");
const xml = @import("xml.zig");

/// SSDP discovery and the device description.
pub const ssdp = @import("dlna/ssdp.zig");
/// The SOAP envelope, the call, and what a refusal means.
pub const soap = @import("dlna/soap.zig");
/// What the renderer says it can do, read on demand.
pub const claims = @import("dlna/claims.zig");
/// `SetAVTransportURI` metadata and the UPnP clock format.
pub const didl = @import("dlna/didl.zig");

const log = std.log.scoped(.dlna);

/// Every AVTransport action takes this first.
const instance: soap.Arg = .{ .name = "InstanceID", .value = "0" };

pub const Renderer = struct {
    env: Env,
    http: std.http.Client,
    address: net.Ip4Address,
    /// Ours on the interface that reaches it, settled once at connect.
    local_address: net.Ip4Address,
    friendly_name: []const u8,
    /// The AVTransport service type, as advertised.
    service: []const u8,
    control_url: []const u8,
    /// Where the two extra documents live, read on demand: `status`, `stop`
    /// and the transport verbs need neither.
    scpd_url: []const u8,
    connection_manager: ?ssdp.Service,
    cached_caps: ?claims.Caps = null,
    cached_sinks: ?[]const []const u8 = null,
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
    /// Said once per renderer, not once per load.
    warned_subtitles: bool = false,
    /// What the item is worth, once anything has said so.
    duration: ?f64 = null,
    /// The furthest point reached while actually playing. A renderer resets
    /// its reported position to zero when it stops, including when it stops
    /// because the item ended, so the live reading cannot say where it got
    /// to and this is what decides finished from cancelled.
    played_to: f64 = 0,

    /// Reads the description at `location`, which is the one document every
    /// caller needs. `caps` and `sinks` fetch theirs when first asked.
    pub fn connect(env: Env, address: net.Ip4Address, location: []const u8) !*Renderer {
        const r = try env.gpa.create(Renderer);
        errdefer env.gpa.destroy(r);
        r.* = .{
            .env = env,
            .http = .{ .allocator = env.gpa, .io = env.io },
            .address = address,
            .local_address = try ourAddress(env.io, address),
            .friendly_name = "",
            .service = "",
            .control_url = "",
            .scpd_url = "",
            .connection_manager = null,
            .scratch = .init(env.gpa),
        };
        errdefer r.http.deinit();
        errdefer r.scratch.deinit();

        const description = try ssdp.describe(env.arena, &r.http, location);
        r.friendly_name = description.friendly_name;
        r.service = description.av_transport.type;
        r.control_url = description.av_transport.control_url;
        r.scpd_url = description.av_transport.scpd_url;
        r.connection_manager = description.connection_manager;
        log.debug("{s}: {s} at {s}", .{ r.friendly_name, r.service, r.control_url });
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        r.http.deinit();
        r.scratch.deinit();
        r.env.gpa.destroy(r);
    }

    /// What its SCPD admits to, read the first time something asks.
    pub fn caps(r: *Renderer) claims.Caps {
        if (r.cached_caps) |c| return c;
        // The SCPD is parsed into bools, so the scratch it lands in may go.
        const c = claims.transport(r.scratch.allocator(), &r.http, r.scpd_url);
        r.cached_caps = c;
        return c;
    }

    /// The MIME types it says it accepts, read the first time something asks.
    pub fn sinks(r: *Renderer) []const []const u8 {
        if (r.cached_sinks) |s| return s;
        const s = claims.sinks(r.env.arena, &r.http, r.connection_manager);
        r.cached_sinks = s;
        log.debug("{s} accepts {d} type(s)", .{ r.friendly_name, s.len });
        return s;
    }

    /// Our own address on the interface that reaches the renderer, for URLs
    /// the renderer must fetch from us. The port is the probe socket's, not
    /// one to serve on.
    pub fn localAddress(r: *const Renderer) net.Ip4Address {
        return r.local_address;
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
            .protocol_info = try didl.protocolInfo(r.scratch.allocator(), req.content_type, req.seekable),
            .title = req.title orelse "castig",
            .duration = req.duration,
            .subtitle = if (req.text_tracks.len > 0) .{
                .url = req.text_tracks[0].url,
                .format = req.text_tracks[0].format.name(),
            } else null,
        });
        if (req.text_tracks.len > 0 and !r.warned_subtitles) {
            r.warned_subtitles = true;
            log.info("side-loaded subtitles are device-specific; if none appears, {s} does not take one", .{r.friendly_name});
        }

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
        // Like pause and stop: a poll this soon still describes the state
        // before it, and reporting "paused" to someone who just pressed
        // play is worse than reporting a play that is still starting.
        return r.settled(.{ .state = .playing });
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
                    sweep.after(settle_ms).sleep(r.env.io) catch {};
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

        const seeks = r.caps();
        const units = [_]struct { ok: bool, name: []const u8 }{
            .{ .ok = seeks.rel_time_seek, .name = "REL_TIME" },
            .{ .ok = seeks.abs_time_seek, .name = "ABS_TIME" },
        };
        for (units) |unit| {
            if (!unit.ok) continue;
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
        return error.InvalidSeek;
    }

    /// Nothing worth having implements a speed other than 1.
    pub fn setRate(r: *Renderer, value: f64) !playback.Playback {
        _ = r.scratch.reset(.retain_capacity);
        if (value != 1 and !r.caps().speeds) {
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
        const now = try r.poll();
        // A renderer keeps the last URI after a Stop, so being stopped is
        // not the same as having nothing, but it is the same to us: the
        // verbs are all about something in progress, and a Cast receiver
        // whose app has gone answers the same way.
        if (now.state == .idle) return error.NothingPlaying;
        // It was already going before we arrived, so a stop from here is an
        // ending rather than a load that never started.
        r.played = true;
        return now;
    }

    /// Blocks until there is something new to report. Nothing is pushed, so
    /// a tick is a sleep and two questions.
    pub fn next(r: *Renderer, io: Io) !playback.Playback {
        try sweep.after(if (r.polls < quick_polls) quick_poll_ms else poll_ms).sleep(io);
        return r.poll() catch |err| switch (err) {
            error.RendererUnreachable => {
                r.failures += 1;
                // A renderer that went to standby should end the session
                // rather than be asked forever.
                if (r.failures >= unreachable_polls) return error.ConnectionClosed;
                return r.last;
            },
            else => return err,
        };
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
/// How many times to ask a settling transport to start, and how long to
/// leave it between attempts.
const play_attempts = 4;
const settle_ms = 300;
/// How long between polls. The first few are quick, so that starting to
/// play shows up at once; the rest are a second apart, which `end_slack`
/// assumes.
const quick_polls = 4;
const quick_poll_ms = 250;
const poll_ms = 1000;
/// How many unanswered polls before a renderer counts as gone for good.
const unreachable_polls = 3;
/// How near the end counts as having reached it: a renderer stops a little
/// short of the last frame, and `poll_ms` bounds how short we can see.
const end_slack = 5;

const transport_states: std.StaticStringMap(playback.State) = .initComptime(.{
    .{ "PLAYING", .playing },
    .{ "PAUSED_PLAYBACK", .paused },
    .{ "PAUSED_RECORDING", .paused },
    .{ "TRANSITIONING", .buffering },
    .{ "STOPPED", .idle },
    .{ "NO_MEDIA_PRESENT", .idle },
});

/// Which of our addresses `peer` would reach us on. Connecting a datagram
/// socket sends nothing; it only makes the kernel pick the route, and the
/// socket's own address is the answer. A Cast channel reads the same thing
/// off its TLS stream, but `std.http.Client` keeps its sockets to itself.
fn ourAddress(io: Io, peer: net.Ip4Address) !net.Ip4Address {
    const ip: net.IpAddress = .{ .ip4 = peer };
    const probe = try ip.connect(io, .{ .mode = .dgram });
    defer probe.close(io);
    return probe.socket.address.ip4;
}

fn stateOf(transport_state: []const u8) playback.State {
    return transport_states.get(transport_state) orelse .unknown;
}

test {
    _ = ssdp;
    _ = soap;
    _ = didl;
    _ = claims;
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
