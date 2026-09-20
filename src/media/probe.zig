//! What a media file contains and whether a receiver can play it as it is.
//!
//! The same verdict drives the delivery decision: play the file directly,
//! remux with an audio transcode, or give up because the video would need a
//! software transcode, which castig does not do.

const std = @import("std");
const extra = @import("av_extra.zig");
const support = @import("support.zig");

pub const Kind = enum { video, audio, subtitle, other };

pub const Stream = struct {
    index: usize,
    kind: Kind,
    /// libav's name for the stream type, which is finer than `kind`:
    /// "attachment" and "data" both land in `.other`.
    type_name: []const u8,
    codec: []const u8,
    /// From container metadata, usually a three-letter ISO 639-2 code.
    language: ?[]const u8,
    /// How the receiver copes with this codec; null for `.other`.
    support: ?support.Support = null,
    video: ?struct { width: u32, height: u32, fps: f64 } = null,
    audio: ?struct { channels: u32, sample_rate: u32 } = null,
    /// A subtitle stream castig can turn into WebVTT; bitmap subtitles cannot.
    text: bool = false,
};

pub const Report = struct {
    path: []const u8,
    container: []const u8,
    duration: ?f64,
    streams: []const Stream,
    /// The worst support level across the streams of each kind, so a file
    /// with one unplayable track is reported by that track.
    video: ?support.Support = null,
    audio: ?support.Support = null,
    text_subs: usize = 0,
    bitmap_subs: usize = 0,

    pub fn castable(r: Report) bool {
        return r.video != null or r.audio != null;
    }
};

/// Opens `path`, reads its stream info and describes it. Strings taken from
/// the container are duped into `gpa`; codec and container names are libav's
/// own static ones.
pub fn inspect(gpa: std.mem.Allocator, path: []const u8) !Report {
    const fc = try extra.openInput(gpa, path);
    defer fc.close_input();

    var streams: std.ArrayList(Stream) = .empty;
    errdefer streams.deinit(gpa);
    var report: Report = .{
        .path = path,
        .container = std.mem.span(fc.iformat.name),
        .duration = extra.durationSeconds(fc),
        .streams = &.{},
    };

    for (fc.streams[0..fc.nb_streams]) |st| {
        const par = st.codecpar;
        const codec = extra.codecName(extra.codecId(par));
        const language = if (extra.dictGet(st.metadata, "language")) |l| try gpa.dupe(u8, l) else null;
        var s: Stream = .{
            .index = @intCast(st.index),
            .kind = switch (par.codec_type) {
                .VIDEO => .video,
                .AUDIO => .audio,
                .SUBTITLE => .subtitle,
                else => .other,
            },
            .type_name = extra.mediaTypeName(par.codec_type),
            .codec = codec,
            .language = language,
        };
        switch (s.kind) {
            .video => {
                s.video = .{
                    .width = @intCast(par.width),
                    .height = @intCast(par.height),
                    .fps = extra.streamFps(st) orelse 0,
                };
                s.support = support.videoSupport(codec);
                report.video = worse(report.video, s.support.?);
            },
            .audio => {
                s.audio = .{
                    .channels = @intCast(par.ch_layout.nb_channels),
                    .sample_rate = @intCast(par.sample_rate),
                };
                s.support = support.audioSupport(codec);
                report.audio = worse(report.audio, s.support.?);
            },
            .subtitle => {
                s.text = support.textIsSupported(codec);
                if (s.text) report.text_subs += 1 else report.bitmap_subs += 1;
            },
            .other => {},
        }
        try streams.append(gpa, s);
    }

    report.streams = try streams.toOwnedSlice(gpa);
    return report;
}

/// The worst support level seen across the streams of one kind.
fn worse(current: ?support.Support, candidate: support.Support) support.Support {
    const c = current orelse return candidate;
    return if (@backingInt(candidate) > @backingInt(c)) candidate else c;
}
