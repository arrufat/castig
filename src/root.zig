//! castig as a library: what the tool does, minus the command line. A module
//! unreachable from here is neither documented (`zig build docs`) nor tested.

/// What every operation runs with: the Io, the allocators, the environment.
pub const Env = @import("env.zig").Env;
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

/// Subtitle lookup: sidecars and OpenSubtitles.
pub const subs = @import("subs/lookup.zig");

/// Receiver-driving commands. Shell-shaped still; stage 2 splits it into a
/// session iterator and one-shot controls.
pub const commands = @import("commands.zig");

test {
    _ = Env;
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
    _ = commands;
}
