//! castig as a library: what the tool does, minus the command line. A module
//! unreachable from here is neither documented (`zig build docs`) nor tested.

/// The scopes the library logs under. A front end that shows the library's
/// own explanations asks here, so a new module reaches it without an edit.
pub const log_scopes = [_]@EnumLiteral(){ .cast, .subs, .http, .hls };

pub fn ownScope(comptime scope: @EnumLiteral()) bool {
    for (log_scopes) |s| if (s == scope) return true;
    return false;
}

/// What every operation runs with: the Io, the allocators, the environment.
pub const Env = @import("env.zig").Env;
/// Where the library reports the progress of a long operation.
pub const Reporter = @import("reporter.zig").Reporter;
/// ISO 639 code to a display name, for naming a subtitle track.
pub const language = @import("language.zig");

/// Cast v2 over TLS: the receiver and media namespaces.
pub const channel = @import("device/channel.zig");
/// Cast channel framing: a length prefix around a protobuf CastMessage.
pub const proto = @import("device/proto.zig");
/// Receiver discovery over mDNS.
pub const discovery = @import("device/discovery.zig");
/// DNS wire format: query builder, record parser.
pub const dns = @import("device/dns.zig");

/// What a receiver can play, by codec name.
pub const support = @import("media/support.zig");
/// Stream listing and the cast verdict.
pub const probe = @import("media/probe.zig");
/// Delivery decision and the remux driver.
pub const pipeline = @import("media/pipeline.zig");
/// On-demand HLS: keyframe segmenter, playlists, per-segment MPEG-TS.
pub const hls = @import("media/hls.zig");
/// Seekable MP4 assembled on the fly, no temporary file.
pub const vmp4 = @import("media/vmp4.zig");
/// Subtitle text to WebVTT.
pub const webvtt = @import("media/webvtt.zig");
/// libav declarations the `av` bindings do not expose yet.
pub const av_extra = @import("media/av_extra.zig");

/// The media server the receiver pulls from.
pub const http = @import("serve/server.zig");
/// The routes that serve one source, and what the receiver is told to load.
pub const delivery = @import("serve/delivery.zig");

/// Subtitle lookup: sidecars and OpenSubtitles.
pub const subs = @import("subs/lookup.zig");

/// One cast, from a source to the end of playback, as an event iterator.
pub const session = @import("session.zig");
/// Controlling whatever is already playing: status, stop, pause, seek, rate.
pub const control = @import("control.zig");

test {
    _ = Env;
    _ = Reporter;
    _ = language;
    _ = channel;
    _ = proto;
    _ = discovery;
    _ = dns;
    _ = support;
    _ = probe;
    _ = pipeline;
    _ = hls;
    _ = vmp4;
    _ = webvtt;
    _ = av_extra;
    _ = http;
    _ = subs;
    _ = session;
    _ = control;
    _ = delivery;
}
