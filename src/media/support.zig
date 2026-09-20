//! What a Cast receiver can play, by codec name.
//!
//! Codecs are matched by name, never by `av.Codec.ID`: ffmpeg renumbered the
//! video ids between 8.1 and 9, so the numeric values are not stable.

const std = @import("std");

pub const Support = enum {
    /// Playable by every Cast receiver.
    direct,
    /// Playable by some receivers (Chromecast Ultra, Google TV, HDMI passthrough).
    device_dependent,
    /// Needs transcoding.
    transcode,

    pub fn label(s: Support) []const u8 {
        return switch (s) {
            .direct => "direct",
            .device_dependent => "device-dependent",
            .transcode => "transcode",
        };
    }
};

/// Codec names as returned by `avcodec_get_name`. Names are used instead of
/// `av.Codec.ID` because the numeric ids differ between ffmpeg releases.
const direct_video = std.StaticStringMap(void).initComptime(.{ .{"h264"}, .{"vp8"}, .{"vp9"}, .{"av1"} });
const dependent_video = std.StaticStringMap(void).initComptime(.{.{"hevc"}});
const direct_audio = std.StaticStringMap(void).initComptime(.{ .{"aac"}, .{"mp3"}, .{"opus"}, .{"vorbis"}, .{"flac"} });
const dependent_audio = std.StaticStringMap(void).initComptime(.{ .{"ac3"}, .{"eac3"} });

pub fn videoSupport(codec: []const u8) Support {
    if (direct_video.has(codec)) return .direct;
    if (dependent_video.has(codec)) return .device_dependent;
    return .transcode;
}

pub fn audioSupport(codec: []const u8) Support {
    if (direct_audio.has(codec)) return .direct;
    if (dependent_audio.has(codec)) return .device_dependent;
    return .transcode;
}

/// Whether a libav subtitle codec name is a text format we can turn into
/// WebVTT from its packets alone. Bitmap subtitles (PGS, DVB, VOBSUB, DVD)
/// are images and cannot become text tracks.
pub fn textIsSupported(codec: []const u8) bool {
    return text_codecs.has(codec);
}

const text_codecs = std.StaticStringMap(void).initComptime(.{
    .{"subrip"}, .{"srt"}, .{"text"}, .{"ass"}, .{"ssa"}, .{"mov_text"}, .{"webvtt"},
});

test "support tables" {
    try std.testing.expectEqual(Support.direct, videoSupport("h264"));
    try std.testing.expectEqual(Support.direct, videoSupport("av1"));
    try std.testing.expectEqual(Support.device_dependent, videoSupport("hevc"));
    try std.testing.expectEqual(Support.transcode, videoSupport("mpeg4"));
    try std.testing.expectEqual(Support.direct, audioSupport("aac"));
    try std.testing.expectEqual(Support.transcode, audioSupport("dts"));
    try std.testing.expectEqual(Support.transcode, audioSupport("truehd"));
}

test "text codec detection" {
    try std.testing.expect(textIsSupported("subrip"));
    try std.testing.expect(textIsSupported("ass"));
    try std.testing.expect(textIsSupported("mov_text"));
    try std.testing.expect(!textIsSupported("hdmv_pgs_subtitle"));
    try std.testing.expect(!textIsSupported("dvb_subtitle"));
}
