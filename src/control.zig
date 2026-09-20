//! Controlling whatever is playing on a receiver, whoever started it.
//!
//! Each call opens a connection, finds the app that speaks the media
//! namespace, sends one command and returns the receiver's answer.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Env = @import("env.zig").Env;
const channel = @import("device/channel.zig");
const Channel = channel.Channel;
const discovery = @import("device/discovery.zig");

pub const Status = struct {
    address: net.Ip4Address,
    receiver: Channel.Status,
};

pub fn status(env: Env, device: []const u8) !Status {
    const address = try discovery.resolve(env.io, env.gpa, device);
    const ch = try Channel.connect(env.io, env.gpa, address);
    defer ch.deinit();
    return .{ .address = address, .receiver = try ch.getStatus(env.arena) };
}

/// Stops every app that is not the idle screen, and names the ones it stopped.
pub fn stop(env: Env, device: []const u8) ![]const []const u8 {
    const address = try discovery.resolve(env.io, env.gpa, device);
    const ch = try Channel.connect(env.io, env.gpa, address);
    defer ch.deinit();

    const st = try ch.getStatus(env.arena);
    var stopped: std.ArrayList([]const u8) = .empty;
    for (st.applications) |a| {
        if (a.isIdleScreen) continue;
        try ch.stopApp(env.arena, a.sessionId);
        try stopped.append(env.arena, a.displayName);
    }
    return stopped.toOwnedSlice(env.arena);
}

const Playing = struct {
    ch: *Channel,
    transport_id: []const u8,
    media: Channel.MediaStatus,

    /// Replies to commands carry no `media` object, so the duration learned
    /// when the session was opened is kept.
    fn withMedia(p: Playing, reply: Channel.MediaStatus) Channel.MediaStatus {
        var m = reply;
        if (m.media == null) m.media = p.media.media;
        return m;
    }
};

/// Connects to the app that is playing on the device and fetches its status.
fn open(env: Env, device: []const u8) !Playing {
    const address = try discovery.resolve(env.io, env.gpa, device);
    const ch = try Channel.connect(env.io, env.gpa, address);
    errdefer ch.deinit();

    const st = try ch.getStatus(env.arena);
    const app = st.mediaApp() orelse {
        std.debug.print("nothing is playing on {f}\n", .{address});
        return error.NoMedia;
    };
    try ch.connectTransport(app.transportId);
    const media = ch.getMediaStatus(env.arena, app.transportId) catch |err| switch (err) {
        error.NoMedia => {
            std.debug.print("{s} has no media loaded\n", .{app.displayName});
            return err;
        },
        else => return err,
    };
    return .{ .ch = ch, .transport_id = app.transportId, .media = media };
}

pub fn pause(env: Env, device: []const u8) !Channel.MediaStatus {
    const p = try open(env, device);
    defer p.ch.deinit();
    return p.withMedia(try p.ch.mediaCommand(env.arena, p.transport_id, p.media.mediaSessionId, "PAUSE"));
}

pub fn play(env: Env, device: []const u8) !Channel.MediaStatus {
    const p = try open(env, device);
    defer p.ch.deinit();
    return p.withMedia(try p.ch.mediaCommand(env.arena, p.transport_id, p.media.mediaSessionId, "PLAY"));
}

/// `spec` is absolute ("90", "1:30", "1:02:03") or relative ("+30", "-10"),
/// so it is resolved against the position the receiver reports.
pub fn seek(env: Env, device: []const u8, spec: []const u8) !Channel.MediaStatus {
    const p = try open(env, device);
    defer p.ch.deinit();

    var target = parseSeek(spec, p.media.currentTime) catch {
        std.debug.print("cannot parse position {s}\n", .{spec});
        return error.InvalidSeek;
    };
    target = std.math.clamp(target, 0, p.media.duration() orelse std.math.inf(f64));
    return p.withMedia(try p.ch.seek(env.arena, p.transport_id, p.media.mediaSessionId, target));
}

pub const rate_min = 0.5;
pub const rate_max = 2.0;

/// The Default Media Receiver accepts 0.5 to 2.0 and ignores anything else.
pub fn rate(env: Env, device: []const u8, value: f64) !Channel.MediaStatus {
    if (value < rate_min or value > rate_max) {
        std.debug.print("rate must be between {d} and {d}\n", .{ rate_min, rate_max });
        return error.InvalidRate;
    }
    const p = try open(env, device);
    defer p.ch.deinit();
    return p.withMedia(try p.ch.setPlaybackRate(env.arena, p.transport_id, p.media.mediaSessionId, value));
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
