//! One device under control, whichever protocol it speaks.
//!
//! A tagged union rather than a vtable: the set of protocols is closed and
//! lives inside this library, every call returns something and can fail, and
//! each arm keeps its own connection state. `switch` then turns a protocol
//! that forgot a verb into a compile error, which a vtable of function
//! pointers could not. `Reporter` is a vtable for the opposite reason: a
//! front end supplies it from outside, so that set is open.
//!
//! Everything here speaks `playback`, so nothing above `device/` learns a
//! protocol's own vocabulary.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Env = @import("../env.zig").Env;
const cast = @import("cast.zig");
const playback = @import("playback.zig");

const log = std.log.scoped(.cast);

/// A transport command that takes no argument.
pub const Verb = enum { play, pause, stop };

/// What a device reports about itself, as opposed to about one item.
pub const DeviceStatus = struct {
    volume: ?Volume = null,
    /// The apps the receiver lists. Only Cast has any; a protocol without an
    /// app model leaves this empty and a caller prints nothing for it.
    apps: []const cast.Channel.App = &.{},

    pub const Volume = struct { level: f64, muted: bool };
};

pub const Player = union(enum) {
    cast: Cast,

    /// A Cast channel plus the app session it is driving.
    pub const Cast = struct {
        ch: *cast.Channel,
        /// Where media messages go, once the app is running.
        transport_id: []const u8,
        /// The app's session, for stopping it at the end.
        session_id: []const u8,
        media_session_id: i64 = 0,
        /// Replies to commands carry no `media` object, so the duration
        /// learned when the item was loaded stands in for theirs.
        duration: ?f64 = null,
        /// The last status seen, so a caller that needs the position back
        /// does not pay for another round trip.
        last: playback.Playback = .{},

        fn track(c: *Cast, m: cast.Channel.MediaStatus) playback.Playback {
            var p = m.toPlayback();
            if (p.duration) |d| {
                c.duration = d;
            } else {
                p.duration = c.duration;
            }
            c.last = p;
            return p;
        }
    };

    /// Connects and gets the device ready to be loaded. On Cast that means
    /// joining the Default Media Receiver, or launching it, which is what
    /// raises the "allow this cast?" prompt some devices show.
    pub fn connect(env: Env, address: net.Ip4Address) !Player {
        const ch = try cast.Channel.connect(env.io, env.gpa, address);
        errdefer ch.deinit();
        const st = try ch.getStatus(env.arena);
        const app = st.find(cast.default_media_receiver) orelse
            try ch.launch(env.arena, cast.default_media_receiver);
        try ch.connectTransport(app.transportId);
        return .{ .cast = .{
            .ch = ch,
            .transport_id = app.transportId,
            .session_id = app.sessionId,
        } };
    }

    /// Joins whatever is already playing, whoever started it.
    /// `error.NothingPlaying` when the device is idle, `error.NoMedia` when
    /// something is running with nothing loaded.
    pub fn attach(env: Env, address: net.Ip4Address) !Player {
        const ch = try cast.Channel.connect(env.io, env.gpa, address);
        errdefer ch.deinit();

        const st = try ch.getStatus(env.arena);
        const app = st.mediaApp() orelse {
            log.warn("nothing is playing on {f}", .{address});
            return error.NothingPlaying;
        };
        try ch.connectTransport(app.transportId);
        const media = ch.getMediaStatus(env.arena, app.transportId) catch |err| switch (err) {
            error.NoMedia => {
                log.warn("{s} has no media loaded", .{app.displayName});
                return err;
            },
            else => return err,
        };
        var c: Cast = .{
            .ch = ch,
            .transport_id = app.transportId,
            .session_id = app.sessionId,
            .media_session_id = media.mediaSessionId,
        };
        _ = c.track(media);
        return .{ .cast = c };
    }

    /// The last thing the device said, without asking it again.
    pub fn current(p: Player) playback.Playback {
        return switch (p) {
            .cast => |c| c.last,
        };
    }

    /// Closes the connection and frees what it held.
    pub fn deinit(p: Player) void {
        switch (p) {
            .cast => |c| c.ch.deinit(),
        }
    }

    /// Our own address on the interface that reaches the device, for URLs the
    /// device must fetch from us. The port is the control socket's, not one
    /// to serve on.
    pub fn localAddress(p: Player) net.Ip4Address {
        return switch (p) {
            .cast => |c| c.ch.localAddress(),
        };
    }

    /// Hands the device a URL to play.
    pub fn load(p: *Player, env: Env, req: playback.LoadRequest) !playback.Playback {
        switch (p.*) {
            .cast => |*c| {
                const m = try c.ch.load(env.arena, c.transport_id, req);
                c.media_session_id = m.mediaSessionId;
                if (req.duration) |d| c.duration = d;
                return c.track(m);
            },
        }
    }

    /// One transport command for the item that is loaded.
    pub fn command(p: *Player, env: Env, verb: Verb) !playback.Playback {
        switch (p.*) {
            .cast => |*c| return c.track(try c.ch.mediaCommand(
                env.arena,
                c.transport_id,
                c.media_session_id,
                switch (verb) {
                    .play => "PLAY",
                    .pause => "PAUSE",
                    .stop => "STOP",
                },
            )),
        }
    }

    /// Jumps to `seconds` within the current item.
    pub fn seek(p: *Player, env: Env, seconds: f64) !playback.Playback {
        switch (p.*) {
            .cast => |*c| return c.track(try c.ch.seek(env.arena, c.transport_id, c.media_session_id, seconds)),
        }
    }

    /// Sets the playback speed, where the device has one to set.
    pub fn setRate(p: *Player, env: Env, value: f64) !playback.Playback {
        switch (p.*) {
            .cast => |*c| return c.track(try c.ch.setPlaybackRate(env.arena, c.transport_id, c.media_session_id, value)),
        }
    }

    /// What the device is playing right now.
    pub fn status(p: *Player, env: Env) !playback.Playback {
        switch (p.*) {
            .cast => |*c| return c.track(try c.ch.getMediaStatus(env.arena, c.transport_id)),
        }
    }

    /// Blocks until the device reports something new about the item.
    /// `scratch` backs the reply and is the caller's to reset between calls.
    pub fn next(p: *Player, scratch: std.mem.Allocator) !playback.Playback {
        switch (p.*) {
            .cast => |*c| while (true) {
                const msg = try c.ch.receive();
                if (!std.mem.eql(u8, msg.namespace, cast.ns_media)) continue;
                const reply = cast.Channel.parseReply(scratch, msg) orelse continue;
                const m = cast.Channel.mediaStatusFrom(scratch, reply) orelse continue;
                return c.track(m);
            },
        }
    }

    /// Leaves the device as we found it rather than parked on an idle screen.
    /// Best effort: the session is over either way.
    pub fn endSession(p: *Player, env: Env) void {
        switch (p.*) {
            .cast => |c| c.ch.stopApp(env.arena, c.session_id) catch {},
        }
    }
};

/// What `device` is doing, without joining whatever plays on it.
pub fn deviceStatus(env: Env, address: net.Ip4Address) !DeviceStatus {
    const ch = try cast.Channel.connect(env.io, env.gpa, address);
    defer ch.deinit();
    const st = try ch.getStatus(env.arena);
    return .{
        .volume = .{ .level = st.volume.level, .muted = st.volume.muted },
        .apps = st.applications,
    };
}

/// Stops everything playing on `device`, and names what it stopped.
pub fn stopAll(env: Env, address: net.Ip4Address) ![]const []const u8 {
    const ch = try cast.Channel.connect(env.io, env.gpa, address);
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

test {
    std.testing.refAllDecls(@This());
}
