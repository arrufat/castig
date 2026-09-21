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
    /// How the device copes with this codec. Null for a track no device
    /// decodes, and until `Report.judgeAgainst` has said.
    support: ?support.Support = null,
    video: ?struct { width: u32, height: u32, fps: f64 } = null,
    audio: ?struct { channels: u32, sample_rate: u32 } = null,
    /// A subtitle stream castig can turn into WebVTT; bitmap subtitles cannot.
    text: bool = false,

    /// The codec and what the receiver will do with it. `index` is the
    /// caller's to print: a window has no room for it.
    pub fn format(s: Stream, w: *std.Io.Writer) !void {
        try w.print("{s} {s}", .{ s.type_name, s.codec });
        if (s.language) |l| try w.print(" [{s}]", .{l});
        if (s.video) |v| try w.print(" {d}x{d} {d:.3} fps", .{ v.width, v.height, v.fps });
        if (s.audio) |a| try w.print(" {d} ch {d} Hz", .{ a.channels, a.sample_rate });
        if (s.support) |sup| try w.print(" -> {s}", .{sup.label()});
        if (s.kind == .subtitle) try w.writeAll(if (s.text) " -> webvtt" else " -> bitmap, burn-in only");
    }
};

pub const Report = struct {
    path: []const u8,
    container: []const u8,
    duration: ?f64,
    streams: []Stream,
    /// The worst support level across the streams of each kind, so a file
    /// with one unplayable track is reported by that track. Both are
    /// `judgeAgainst`'s to fill.
    video: ?support.Support = null,
    audio: ?support.Support = null,
    text_subs: usize = 0,
    bitmap_subs: usize = 0,

    /// Says what `profile` would have to do with each stream. No I/O: the
    /// same report answers for another device without the file being read
    /// again, which is what the window does when the device changes.
    pub fn judgeAgainst(r: *Report, profile: support.Profile) void {
        r.video = null;
        r.audio = null;
        for (r.streams) |*s| switch (s.kind) {
            .video => {
                s.support = profile.videoSupport(s.codec);
                r.video = worse(r.video, s.support.?);
            },
            .audio => {
                s.support = profile.audioSupport(s.codec);
                r.audio = worse(r.audio, s.support.?);
            },
            .subtitle, .other => {},
        };
    }

    /// Whether the file has anything a receiver could play.
    pub fn castable(r: Report) bool {
        return r.video != null or r.audio != null;
    }

    /// The verdict line: what each kind of track costs to deliver.
    pub fn writeVerdict(r: Report, w: *std.Io.Writer) !void {
        if (!r.castable()) return w.writeAll("nothing to cast");
        if (r.video) |v| try w.print("video {s}", .{v.label()});
        if (r.audio) |a| {
            if (r.video != null) try w.writeAll(", ");
            try w.print("audio {s}", .{a.label()});
        }
        if (r.text_subs > 0) try w.print(", {d} text subtitle track(s)", .{r.text_subs});
        if (r.bitmap_subs > 0) try w.print(", {d} bitmap subtitle track(s)", .{r.bitmap_subs});
    }
};

/// Lists the streams of `path`. Strings taken from the container are duped
/// into `gpa`; codec and container names are libav's own static ones. What
/// a device would make of them is `Report.judgeAgainst`'s to say, since
/// that depends on the device and this does not.
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
            },
            .audio => {
                s.audio = .{
                    .channels = @intCast(par.ch_layout.nb_channels),
                    .sample_rate = @intCast(par.sample_rate),
                };
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
