//! What a device can play, by codec name.
//!
//! Codecs are matched by name, never by `av.Codec.ID`: ffmpeg renumbered the
//! video ids between 8.1 and 9, so the numeric values are not stable.
//!
//! A Cast receiver's abilities are known and fixed. A renderer's are not, so
//! its profile starts conservative and is widened by what it says it accepts
//! in `ConnectionManager::GetProtocolInfo`. Guessing wide instead would mean
//! handing a device something it plays silently, or not at all.

const std = @import("std");
const testing = std.testing;

pub const Support = enum {
    /// Playable by every Cast receiver.
    direct,
    /// Playable by some receivers (Chromecast Ultra, Google TV, HDMI passthrough).
    device_dependent,
    /// Needs transcoding.
    transcode,

    /// The word `probe` prints for this level of support.
    pub fn label(s: Support) []const u8 {
        return switch (s) {
            .direct => "direct",
            .device_dependent => "device-dependent",
            .transcode => "transcode",
        };
    }
};

const Names = std.StaticStringMap(void);
/// The MIME types a device might use to name a codec or container. A sink
/// list names formats, not codecs, and no two implementations spell them
/// alike: Kodi says `audio/ac3` where Rygel says `audio/x-ac3`.
const Spellings = std.StaticStringMap([]const []const u8);

pub const Profile = struct {
    direct_video: Names,
    dependent_video: Names,
    direct_audio: Names,
    dependent_audio: Names,
    /// MIME types the device said it accepts. Empty means it was not asked
    /// or did not answer, and then nothing is read into its silence.
    sinks: []const []const u8 = &.{},

    /// The same profile, with what this device actually claims.
    pub fn withSinks(p: Profile, sinks: []const []const u8) Profile {
        var out = p;
        out.sinks = sinks;
        return out;
    }

    /// Whether the device plays this video codec as it is.
    pub fn videoSupport(p: Profile, codec: []const u8) Support {
        if (p.direct_video.has(codec)) return .direct;
        // It said it takes this, which is better than our guess.
        if (p.advertises(video_mimes, codec)) return .direct;
        if (p.dependent_video.has(codec)) return .device_dependent;
        return .transcode;
    }

    /// Whether the device plays this audio codec as it is.
    pub fn audioSupport(p: Profile, codec: []const u8) Support {
        if (p.direct_audio.has(codec)) return .direct;
        if (p.advertises(audio_mimes, codec)) return .direct;
        if (p.dependent_audio.has(codec)) return .device_dependent;
        return .transcode;
    }

    /// Whether the device takes this container. Null when it never said,
    /// so a caller can tell "no" from "no idea".
    pub fn acceptsContainer(p: Profile, mime: []const u8) ?bool {
        if (p.sinks.len == 0) return null;
        const spellings = container_mimes.get(mime) orelse return p.accepts(mime);
        for (spellings) |name| if (p.accepts(name)) return true;
        return false;
    }

    /// Whether the sink list names this type, or everything.
    pub fn accepts(p: Profile, mime: []const u8) bool {
        for (p.sinks) |sink| {
            if (std.mem.eql(u8, sink, "*")) return true;
            if (std.ascii.eqlIgnoreCase(sink, mime)) return true;
        }
        return false;
    }

    fn advertises(p: Profile, table: Spellings, codec: []const u8) bool {
        if (p.sinks.len == 0) return false;
        const spellings = table.get(codec) orelse return false;
        for (spellings) |name| if (p.accepts(name)) return true;
        return false;
    }
};

/// What a Cast receiver plays. Named for the protocol rather than for any
/// one product: a Nest speaker and a television are neither of them a
/// Chromecast, and all three decode the same list.
///
/// Codec names are as `avcodec_get_name` returns them.
pub const cast: Profile = .{
    .direct_video = .initComptime(.{ .{"h264"}, .{"vp8"}, .{"vp9"}, .{"av1"} }),
    .dependent_video = .initComptime(.{.{"hevc"}}),
    .direct_audio = .initComptime(.{ .{"aac"}, .{"mp3"}, .{"opus"}, .{"vorbis"}, .{"flac"} }),
    .dependent_audio = .initComptime(.{ .{"ac3"}, .{"eac3"} }),
};

/// What a renderer is taken to manage before it says otherwise. H.264 is
/// universal; everything else waits to be claimed.
pub const dlna: Profile = .{
    .direct_video = .initComptime(.{.{"h264"}}),
    .dependent_video = .initComptime(.{ .{"hevc"}, .{"vp8"}, .{"vp9"}, .{"av1"}, .{"mpeg4"}, .{"mpeg2video"} }),
    .direct_audio = .initComptime(.{ .{"aac"}, .{"mp3"} }),
    .dependent_audio = .initComptime(.{ .{"ac3"}, .{"eac3"}, .{"dts"}, .{"flac"}, .{"vorbis"}, .{"opus"} }),
};

const video_mimes: Spellings = .initComptime(.{
    .{ "h264", &[_][]const u8{ "video/h264", "video/x-h264", "video/avc" } },
    .{ "hevc", &[_][]const u8{ "video/hevc", "video/x-h265", "video/h265" } },
    .{ "vp8", &[_][]const u8{ "video/x-vp8", "video/vp8" } },
    .{ "vp9", &[_][]const u8{ "video/x-vp9", "video/vp9" } },
    .{ "av1", &[_][]const u8{ "video/av01", "video/x-av1" } },
    .{ "mpeg2video", &[_][]const u8{ "video/mpeg", "video/mpeg2" } },
});

const audio_mimes: Spellings = .initComptime(.{
    .{ "ac3", &[_][]const u8{ "audio/ac3", "audio/x-ac3", "audio/vnd.dolby.dd-raw" } },
    .{ "eac3", &[_][]const u8{ "audio/eac3", "audio/x-eac3", "audio/vnd.dolby.ddplus" } },
    .{ "dts", &[_][]const u8{ "audio/vnd.dts", "audio/x-dts", "audio/dts" } },
    .{ "truehd", &[_][]const u8{"audio/vnd.dolby.mlp"} },
    .{ "flac", &[_][]const u8{ "audio/flac", "audio/x-flac" } },
    .{ "vorbis", &[_][]const u8{ "audio/x-vorbis", "audio/vorbis" } },
    .{ "opus", &[_][]const u8{ "audio/opus", "audio/x-opus" } },
    .{ "aac", &[_][]const u8{ "audio/aac", "audio/mp4", "audio/vnd.dlna.adts" } },
    .{ "mp3", &[_][]const u8{ "audio/mpeg", "audio/mp3" } },
});

const container_mimes: Spellings = .initComptime(.{
    .{ "video/x-matroska", &[_][]const u8{ "video/x-matroska", "video/x-mkv", "video/mkv" } },
    .{ "video/mp4", &[_][]const u8{ "video/mp4", "video/x-m4v", "video/quicktime" } },
    .{ "video/webm", &[_][]const u8{ "video/webm", "video/x-webm" } },
});

/// What a device would have to do with a file before it could play it.
pub const Verdict = struct {
    /// Playable as it is, with nothing to remux.
    direct: bool,
    /// The video itself would need transcoding, which castig does not do.
    video_unsupported: bool,
};

/// Judges a file's streams and container against one device.
pub fn judge(p: Profile, video_codec: []const u8, audio_codec: []const u8, container: []const u8) Verdict {
    const video = if (video_codec.len > 0) p.videoSupport(video_codec) else Support.direct;
    const audio = if (audio_codec.len > 0) p.audioSupport(audio_codec) else Support.direct;
    // A container the device listed without naming ours needs repackaging
    // even when everything inside it is fine.
    const container_ok = p.acceptsContainer(container) orelse true;
    return .{
        .direct = video != .transcode and audio == .direct and container_ok,
        .video_unsupported = video_codec.len > 0 and video == .transcode,
    };
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

test "a device's own word widens what it is taken to play" {
    const mkv = "video/x-matroska";

    // Nothing claimed, so the conservative reading stands and an AC3 MKV
    // would be remuxed.
    try testing.expectEqual(Support.device_dependent, dlna.audioSupport("ac3"));
    try testing.expect(!judge(dlna, "h264", "ac3", mkv).direct);
    try testing.expectEqual(@as(?bool, null), dlna.acceptsContainer(mkv));

    // Rygel spells it audio/x-ac3, Kodi spells it audio/ac3, and either is
    // the device telling us it does not need our help.
    for ([_][]const u8{ "audio/x-ac3", "audio/ac3" }) |spelling| {
        const claimed = dlna.withSinks(&.{ mkv, spelling });
        try testing.expectEqual(Support.direct, claimed.audioSupport("ac3"));
        try testing.expect(judge(claimed, "h264", "ac3", mkv).direct);
    }

    // A container it listed without naming needs repackaging even when the
    // codecs inside it are all fine.
    const no_mkv = dlna.withSinks(&.{ "video/mp4", "audio/ac3" });
    try testing.expectEqual(@as(?bool, false), no_mkv.acceptsContainer(mkv));
    try testing.expect(!judge(no_mkv, "h264", "ac3", mkv).direct);
    try testing.expect(judge(no_mkv, "h264", "ac3", "video/mp4").direct);

    // A bare wildcard means it will try anything.
    try testing.expect(judge(dlna.withSinks(&.{"*"}), "h264", "dts", mkv).direct);

    // Video it cannot decode is not something a remux can fix.
    const v = judge(dlna, "mpeg1video", "aac", mkv);
    try testing.expect(v.video_unsupported);
    try testing.expect(!v.direct);

    // A Cast receiver has fixed abilities; nothing it says changes them.
    try testing.expectEqual(Support.device_dependent, cast.audioSupport("ac3"));
    try testing.expect(!judge(cast, "h264", "ac3", mkv).direct);
    try testing.expect(judge(cast, "h264", "aac", mkv).direct);
}

test "support tables" {
    try std.testing.expectEqual(Support.direct, cast.videoSupport("h264"));
    try std.testing.expectEqual(Support.direct, cast.videoSupport("av1"));
    try std.testing.expectEqual(Support.device_dependent, cast.videoSupport("hevc"));
    try std.testing.expectEqual(Support.transcode, cast.videoSupport("mpeg4"));
    try std.testing.expectEqual(Support.direct, cast.audioSupport("aac"));
    try std.testing.expectEqual(Support.transcode, cast.audioSupport("dts"));
    try std.testing.expectEqual(Support.transcode, cast.audioSupport("truehd"));
}

test "text codec detection" {
    try std.testing.expect(textIsSupported("subrip"));
    try std.testing.expect(textIsSupported("ass"));
    try std.testing.expect(textIsSupported("mov_text"));
    try std.testing.expect(!textIsSupported("hdmv_pgs_subtitle"));
    try std.testing.expect(!textIsSupported("dvb_subtitle"));
}
