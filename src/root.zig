//! castig as a library: what the tool does, minus the command line. A module
//! unreachable from here is neither documented (`zig build docs`) nor tested.

/// Cast v2 over TLS: the receiver and media namespaces.
pub const channel = @import("cast/channel.zig");
/// Cast channel framing: a length prefix around a protobuf CastMessage.
pub const proto = @import("cast/proto.zig");
/// Receiver-driving commands: status, cast, stop, playback control.
pub const commands = @import("commands.zig");
/// Receiver discovery over mDNS.
pub const discovery = @import("discovery.zig");
/// DNS wire format: query builder, record parser.
pub const dns = @import("dns.zig");
/// The media server the receiver pulls from.
pub const http = @import("http/server.zig");
/// On-demand HLS: keyframe segmenter, playlists, per-segment MPEG-TS.
pub const hls = @import("media/hls.zig");
/// Delivery decision and the remux driver.
pub const pipeline = @import("media/pipeline.zig");
/// SubRip and libav subtitle packets to WebVTT.
pub const subtitles = @import("media/subtitles.zig");
/// Seekable MP4 assembled on the fly, no temporary file.
pub const vmp4 = @import("media/vmp4.zig");
/// Stream listing and the cast verdict.
pub const probe = @import("probe.zig");
/// Subtitle lookup: sidecars and OpenSubtitles.
pub const subs = @import("subs/subs.zig");
/// libav declarations the `av` bindings do not expose yet.
pub const av_extra = @import("av_extra.zig");

test {
    _ = channel;
    _ = proto;
    _ = commands;
    _ = discovery;
    _ = dns;
    _ = http;
    _ = hls;
    _ = pipeline;
    _ = subtitles;
    _ = vmp4;
    _ = probe;
    _ = subs;
    _ = av_extra;
}
