//! Controlling whatever is playing on a device, whoever started it.
//!
//! Each call opens a connection, joins what is playing, sends one command and
//! returns what the device answered.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Env = @import("env.zig").Env;
const discovery = @import("device/discovery.zig");
const player = @import("device/player.zig");
const Player = player.Player;
const playback = @import("device/playback.zig");

const log = std.log.scoped(.cast);

/// A transport command that takes no argument.
pub const Verb = player.Verb;

pub const Status = struct {
    address: net.Ip4Address,
    protocol: discovery.Protocol,
    device: player.DeviceStatus,
};

/// What `device` is doing: its volume, and on Cast the apps it runs.
pub fn status(env: Env, device: []const u8) !Status {
    const endpoint = try discovery.resolve(env, device, null);
    return .{
        .address = endpoint.address(),
        .protocol = endpoint.protocol(),
        .device = try player.deviceStatus(env, endpoint),
    };
}

/// Stops everything that is playing, and names what it stopped.
pub fn stop(env: Env, device: []const u8) ![]const []const u8 {
    return player.stopAll(env, try discovery.resolve(env, device, null));
}

/// Connects to whatever is playing on the device.
fn open(env: Env, device: []const u8) !Player {
    return Player.attach(env, try discovery.resolve(env, device, null));
}

/// One transport command for whatever is playing.
pub fn command(env: Env, device: []const u8, verb: Verb) !playback.Playback {
    var p = try open(env, device);
    defer p.deinit();
    return p.command(env, verb);
}

/// `spec` is absolute ("90", "1:30", "1:02:03") or relative ("+30", "-10"),
/// so it is resolved against the position the device reports.
pub fn seek(env: Env, device: []const u8, spec: []const u8) !playback.Playback {
    var p = try open(env, device);
    defer p.deinit();

    const now = p.current();
    var target = parseSeek(spec, now.position) catch {
        log.warn("cannot parse position {s}", .{spec});
        return error.InvalidSeek;
    };
    target = std.math.clamp(target, 0, now.duration orelse std.math.inf(f64));
    return p.seek(env, target);
}

/// Following whatever is already playing, without having started it.
///
/// The same reports a session gives about an item, minus the ones about
/// serving a file: a Cast receiver pushes them, a renderer is polled. This
/// is what lets something other than the process that started a cast show
/// and drive it.
pub const Follow = struct {
    player: Player,
    /// Reset per update, so a long watch stays bounded.
    scratch: std.heap.ArenaAllocator,
    now: playback.Playback,
    /// The first answer is what joining already learned, not a new wait.
    fresh: bool = true,
    done: bool = false,

    /// Joins what is playing. `error.NothingPlaying` when the device is
    /// idle, `error.NoMedia` when something is up with nothing loaded.
    pub fn start(env: Env, device: []const u8) !Follow {
        const p = try open(env, device);
        return .{ .player = p, .scratch = .init(env.gpa), .now = p.current() };
    }

    pub fn deinit(f: *Follow) void {
        f.player.deinit();
        f.scratch.deinit();
    }

    /// What it is doing now, or null once the item ended or the device went
    /// away.
    pub fn next(f: *Follow, env: Env) !?playback.Playback {
        if (f.done) return null;
        if (f.fresh) {
            f.fresh = false;
            return f.now;
        }
        if (f.now.isFinished()) {
            f.done = true;
            return null;
        }
        _ = f.scratch.reset(.retain_capacity);
        f.now = f.player.next(env, f.scratch.allocator()) catch |err| switch (err) {
            error.ConnectionClosed => {
                f.done = true;
                return null;
            },
            else => return err,
        };
        return f.now;
    }
};

pub const rate_min = 0.5;
pub const rate_max = 2.0;

/// The Default Media Receiver accepts 0.5 to 2.0 and ignores anything else.
pub fn rate(env: Env, device: []const u8, value: f64) !playback.Playback {
    if (value < rate_min or value > rate_max) {
        log.warn("rate must be between {d:.1} and {d:.1}", .{ rate_min, rate_max });
        return error.InvalidRate;
    }
    var p = try open(env, device);
    defer p.deinit();
    return p.setRate(env, value);
}

/// A seek position in seconds. `+N` and `-N` are relative to `current`.
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
