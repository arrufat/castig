//! `castig probe <file>`: open a media file through libavformat, list its
//! streams and say whether a default Cast receiver can play them as they are.
//!
//! The verdict is the input the media pipeline will use to choose between
//! serving the file directly, remuxing with an audio transcode, or a full
//! software transcode.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("av_extra.zig");
const subtitles = @import("media/subtitles.zig");

pub const Support = enum {
    /// Playable by every Cast receiver.
    direct,
    /// Playable by some receivers (Chromecast Ultra, Google TV, HDMI passthrough).
    device_dependent,
    /// Needs transcoding.
    transcode,

    fn label(s: Support) []const u8 {
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

pub fn run(gpa: std.mem.Allocator, out: *Io.Writer, path: []const u8) !void {
    const fc = extra.openInput(gpa, path) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer fc.close_input();

    try out.print("{s}\n", .{path});
    try out.print("  container: {s}", .{std.mem.span(fc.iformat.name)});
    if (extra.durationSeconds(fc)) |secs| try out.print(", duration: {d:.1} s", .{secs});
    try out.writeAll("\n");

    var worst_video: ?Support = null;
    var worst_audio: ?Support = null;
    var text_subs: usize = 0;
    var bitmap_subs: usize = 0;

    for (fc.streams[0..fc.nb_streams]) |st| {
        const par = st.codecpar;
        const codec = extra.codecName(extra.codecId(par));

        try out.print("  #{d} {s} {s}", .{ st.index, extra.mediaTypeName(par.codec_type), codec });
        if (extra.dictGet(st.metadata, "language")) |lang| try out.print(" [{s}]", .{lang});

        switch (par.codec_type) {
            .VIDEO => {
                const fps = if (st.avg_frame_rate.den != 0) st.avg_frame_rate.q2d() else 0;
                try out.print(" {d}x{d} {d:.3} fps", .{ par.width, par.height, fps });
                const s = videoSupport(codec);
                try out.print(" -> {s}", .{s.label()});
                worst_video = worse(worst_video, s);
            },
            .AUDIO => {
                try out.print(" {d} ch {d} Hz", .{ par.ch_layout.nb_channels, par.sample_rate });
                const s = audioSupport(codec);
                try out.print(" -> {s}", .{s.label()});
                worst_audio = worse(worst_audio, s);
            },
            .SUBTITLE => {
                if (subtitles.textIsSupported(codec)) {
                    text_subs += 1;
                    try out.writeAll(" -> webvtt");
                } else {
                    bitmap_subs += 1;
                    try out.writeAll(" -> bitmap, burn-in only");
                }
            },
            else => {},
        }
        try out.writeAll("\n");
    }

    try out.writeAll("  verdict: ");
    if (worst_video == null and worst_audio == null) {
        try out.writeAll("nothing to cast\n");
        return;
    }
    if (worst_video) |v| try out.print("video {s}", .{v.label()});
    if (worst_audio) |a| {
        if (worst_video != null) try out.writeAll(", ");
        try out.print("audio {s}", .{a.label()});
    }
    if (text_subs > 0) try out.print(", {d} text subtitle track(s)", .{text_subs});
    if (bitmap_subs > 0) try out.print(", {d} bitmap subtitle track(s)", .{bitmap_subs});
    try out.writeAll("\n");
}

/// The worst support level seen across the streams of one kind.
fn worse(current: ?Support, candidate: Support) Support {
    const c = current orelse return candidate;
    return if (@backingInt(candidate) > @backingInt(c)) candidate else c;
}

test "support tables" {
    try std.testing.expectEqual(Support.direct, videoSupport("h264"));
    try std.testing.expectEqual(Support.direct, videoSupport("av1"));
    try std.testing.expectEqual(Support.device_dependent, videoSupport("hevc"));
    try std.testing.expectEqual(Support.transcode, videoSupport("mpeg4"));
    try std.testing.expectEqual(Support.direct, audioSupport("aac"));
    try std.testing.expectEqual(Support.transcode, audioSupport("dts"));
    try std.testing.expectEqual(Support.transcode, audioSupport("truehd"));
}
