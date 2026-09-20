//! `castig probe <file>`: open a media file through libavformat, list its
//! streams and say whether a default Cast receiver can play them as they are.
//!
//! The verdict is the input the media pipeline will use to choose between
//! serving the file directly, remuxing with an audio transcode, or a full
//! software transcode.

const std = @import("std");
const Io = std.Io;
const extra = @import("av_extra.zig");
const support = @import("support.zig");

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

    var worst_video: ?support.Support = null;
    var worst_audio: ?support.Support = null;
    var text_subs: usize = 0;
    var bitmap_subs: usize = 0;

    for (fc.streams[0..fc.nb_streams]) |st| {
        const par = st.codecpar;
        const codec = extra.codecName(extra.codecId(par));

        try out.print("  #{d} {s} {s}", .{ st.index, extra.mediaTypeName(par.codec_type), codec });
        if (extra.dictGet(st.metadata, "language")) |lang| try out.print(" [{s}]", .{lang});

        switch (par.codec_type) {
            .VIDEO => {
                const fps = extra.streamFps(st) orelse 0;
                try out.print(" {d}x{d} {d:.3} fps", .{ par.width, par.height, fps });
                const s = support.videoSupport(codec);
                try out.print(" -> {s}", .{s.label()});
                worst_video = worse(worst_video, s);
            },
            .AUDIO => {
                try out.print(" {d} ch {d} Hz", .{ par.ch_layout.nb_channels, par.sample_rate });
                const s = support.audioSupport(codec);
                try out.print(" -> {s}", .{s.label()});
                worst_audio = worse(worst_audio, s);
            },
            .SUBTITLE => {
                if (support.textIsSupported(codec)) {
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
fn worse(current: ?support.Support, candidate: support.Support) support.Support {
    const c = current orelse return candidate;
    return if (@backingInt(candidate) > @backingInt(c)) candidate else c;
}
