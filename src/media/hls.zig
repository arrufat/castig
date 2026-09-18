//! On-demand HLS VOD for remuxed files.
//!
//! At cast start `Segmenter.init` computes keyframe-aligned segment boundaries
//! (video is copied, so each segment must begin on a keyframe). It reads the
//! demuxer's keyframe index when present (instant for MP4 and MKV-with-cues)
//! and falls back to a linear keyframe scan otherwise.
//!
//! The playlist is a complete VOD list (`#EXT-X-ENDLIST`) with exact per-
//! segment durations, so the receiver knows the total length, starts on the
//! first segment, and seeks natively by fetching the segment at the target
//! time. Each `.ts` segment is transcoded on demand by `pipeline.remuxWindow`.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("../av_extra.zig");
const pipeline = @import("pipeline.zig");
const server = @import("../http/server.zig");

pub const url_prefix = "/hls/";
pub const master_name = "master.m3u8";
pub const playlist_name = "index.m3u8";
pub const master_content_type = "application/vnd.apple.mpegurl";
pub const playlist_content_type = "application/vnd.apple.mpegurl";
pub const segment_content_type = "video/mp2t";
/// Cast expects this content type on the LOAD for an HLS source.
pub const cast_content_type = "application/x-mpegURL";

const target_seconds: f64 = 6;

pub const Segmenter = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    /// Start time of each segment, in seconds; ascending, first is 0.
    starts: []f64,
    duration: f64,
    width: c_int,
    height: c_int,
    /// RFC 6381 codecs string for the master playlist, e.g.
    /// "avc1.640028,mp4a.40.2". The Default Media Receiver needs this to
    /// initialise its media source, or it never fetches a segment.
    codecs: []const u8,
    bandwidth: u64,

    pub fn init(gpa: std.mem.Allocator, path: []const u8) !Segmenter {
        const path_z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(path_z);

        av.LOG.set_level(.ERROR);
        const ic = try av.FormatContext.open_input(path_z, null, null, null);
        defer ic.close_input();
        try ic.find_stream_info(null);

        const video_index: usize = if (ic.find_best_stream(.VIDEO, -1, -1)) |v|
            @intCast(v[0])
        else |_|
            return error.NoVideoStream;
        const vstream = ic.streams[video_index];
        const tb = vstream.time_base;
        const vpar = vstream.codecpar;

        const duration: f64 = if (ic.duration != av.NOPTS_VALUE)
            @as(f64, @floatFromInt(ic.duration)) / 1_000_000
        else
            return error.UnknownDuration;

        // avc1 profile/compat/level come from the AVCDecoderConfigurationRecord
        // (extradata bytes 1..4); fall back to High@4.0 if unavailable.
        var avc1: [16]u8 = undefined;
        const avc1_str = if (vpar.extradata_size >= 4)
            try std.fmt.bufPrint(&avc1, "avc1.{x:0>2}{x:0>2}{x:0>2}", .{ vpar.extradata[1], vpar.extradata[2], vpar.extradata[3] })
        else
            "avc1.640028";
        const codecs = try std.fmt.allocPrint(gpa, "{s},mp4a.40.2", .{avc1_str});
        const bandwidth: u64 = if (vpar.bit_rate > 0) @as(u64, @intCast(vpar.bit_rate)) + 192_000 else 6_000_000;

        var keyframes: std.ArrayList(f64) = .empty;
        defer keyframes.deinit(gpa);

        const index_count = extra.avformat_index_get_entries_count(vstream);
        if (index_count > 1) {
            var i: c_int = 0;
            while (i < index_count) : (i += 1) {
                const entry = extra.avformat_index_get_entry(vstream, i) orelse continue;
                if (!entry.isKeyframe()) continue;
                if (entry.timestamp == av.NOPTS_VALUE) continue;
                try keyframes.append(gpa, @as(f64, @floatFromInt(entry.timestamp)) * tb.q2d());
            }
        }
        if (keyframes.items.len < 2) {
            keyframes.clearRetainingCapacity();
            try scanKeyframes(gpa, ic, video_index, tb, &keyframes);
        }

        const starts = try boundaries(gpa, keyframes.items, duration);
        return .{
            .gpa = gpa,
            .path = try gpa.dupe(u8, path),
            .starts = starts,
            .duration = duration,
            .width = vpar.width,
            .height = vpar.height,
            .codecs = codecs,
            .bandwidth = bandwidth,
        };
    }

    pub fn writeMaster(s: *const Segmenter, w: *Io.Writer) !void {
        try w.writeAll("#EXTM3U\n#EXT-X-VERSION:3\n");
        try w.print("#EXT-X-STREAM-INF:BANDWIDTH={d},RESOLUTION={d}x{d},CODECS=\"{s}\"\n", .{ s.bandwidth, s.width, s.height, s.codecs });
        try w.print("{s}\n", .{playlist_name});
    }

    pub fn count(s: *const Segmenter) usize {
        return s.starts.len;
    }

    fn segmentDuration(s: *const Segmenter, index: usize) f64 {
        const end = if (index + 1 < s.starts.len) s.starts[index + 1] else s.duration;
        return end - s.starts[index];
    }

    pub fn writePlaylist(s: *const Segmenter, w: *Io.Writer) !void {
        var max: f64 = 0;
        for (0..s.starts.len) |i| max = @max(max, s.segmentDuration(i));

        try w.writeAll("#EXTM3U\n#EXT-X-VERSION:3\n");
        try w.writeAll("#EXT-X-PLAYLIST-TYPE:VOD\n");
        try w.print("#EXT-X-TARGETDURATION:{d}\n", .{@as(u64, @intFromFloat(@ceil(max)))});
        try w.writeAll("#EXT-X-MEDIA-SEQUENCE:0\n");
        for (0..s.starts.len) |i| {
            try w.print("#EXTINF:{d:.3},\nseg{d}.ts\n", .{ s.segmentDuration(i), i });
        }
        try w.writeAll("#EXT-X-ENDLIST\n");
    }
};

/// Groups keyframe times into ~`target_seconds` segments, each starting on a
/// keyframe. Returns the start time of every segment (first is 0).
fn boundaries(gpa: std.mem.Allocator, keyframes: []const f64, duration: f64) ![]f64 {
    var starts: std.ArrayList(f64) = .empty;
    errdefer starts.deinit(gpa);

    try starts.append(gpa, 0);
    var seg_start: f64 = 0;
    for (keyframes) |kf| {
        if (kf - seg_start >= target_seconds and duration - kf >= 1) {
            try starts.append(gpa, kf);
            seg_start = kf;
        }
    }
    return starts.toOwnedSlice(gpa);
}

/// Fallback when the demuxer has no usable index: one pass reading only the
/// video stream's keyframe packet timestamps.
fn scanKeyframes(
    gpa: std.mem.Allocator,
    ic: *av.FormatContext,
    video_index: usize,
    tb: av.Rational,
    out: *std.ArrayList(f64),
) !void {
    const pkt = try av.Packet.alloc();
    defer pkt.free();
    while (true) {
        ic.read_frame(pkt) catch |err| switch (err) {
            error.EndOfFile => break,
            else => return err,
        };
        defer pkt.unref();
        if (pkt.stream_index != @as(c_int, @intCast(video_index))) continue;
        if (pkt.flags & extra.AV_PKT_FLAG_KEY == 0) continue;
        if (pkt.pts == av.NOPTS_VALUE) continue;
        try out.append(gpa, @as(f64, @floatFromInt(pkt.pts)) * tb.q2d());
    }
    // Leave the demuxer rewound for the caller's next open (we opened our own).
}

/// Serves `/hls/index.m3u8` and `/hls/segN.ts`. Wired as a dynamic route whose
/// context is a `*Segmenter`.
pub fn handleRoute(context: *const anyopaque, s: *server.Server, request: *server.Request) anyerror!void {
    const seg: *const Segmenter = @ptrCast(@alignCast(context));
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    const tail = path[url_prefix.len..];

    if (std.mem.eql(u8, tail, master_name)) {
        var aw: Io.Writer.Allocating = .init(seg.gpa);
        defer aw.deinit();
        try seg.writeMaster(&aw.writer);
        return server.respondBuffer(request, master_content_type, aw.written());
    }

    if (std.mem.eql(u8, tail, playlist_name)) {
        var aw: Io.Writer.Allocating = .init(seg.gpa);
        defer aw.deinit();
        try seg.writePlaylist(&aw.writer);
        return server.respondBuffer(request, playlist_content_type, aw.written());
    }

    if (std.mem.startsWith(u8, tail, "seg") and std.mem.endsWith(u8, tail, ".ts")) {
        const digits = tail["seg".len .. tail.len - ".ts".len];
        const index = std.fmt.parseInt(usize, digits, 10) catch return notFound(request);
        if (index >= seg.starts.len) return notFound(request);
        if (request.head.method == .HEAD) return server.respondHead(request, segment_content_type);
        // Stream the segment as it is muxed. Buffering the whole thing first
        // delayed the first byte by seconds and the receiver timed the load out.
        const start = seg.starts[index];
        const end: ?f64 = if (index + 1 < seg.starts.len) seg.starts[index + 1] else null;
        var buffer: [64 * 1024]u8 = undefined;
        var body = try server.beginStream(request, &buffer, segment_content_type);
        pipeline.remuxWindow(seg.gpa, seg.path, start, end, "mpegts", &body.writer) catch |err| {
            if (s.debug) std.debug.print("segment {d} aborted: {s}\n", .{ index, @errorName(err) });
            return; // connection torn down by the caller
        };
        try body.end();
        return;
    }

    return notFound(request);
}

fn notFound(request: *server.Request) !void {
    try request.respond("not found\n", .{ .status = .not_found, .extra_headers = server.cors });
}

test "boundaries group keyframes by target" {
    const gpa = std.testing.allocator;
    // Keyframes every 2s; target 6s -> segments start at 0,6,12,...
    var kf: [30]f64 = undefined;
    for (0..30) |i| kf[i] = @floatFromInt(i * 2);
    const starts = try boundaries(gpa, &kf, 60);
    defer gpa.free(starts);
    try std.testing.expectEqual(@as(f64, 0), starts[0]);
    try std.testing.expectEqual(@as(f64, 6), starts[1]);
    try std.testing.expectEqual(@as(f64, 12), starts[2]);
    try std.testing.expect(starts.len >= 9 and starts.len <= 10);
}

test "master playlist declares codecs and resolution" {
    const gpa = std.testing.allocator;
    const starts = try gpa.dupe(f64, &.{0});
    var seg: Segmenter = .{ .gpa = gpa, .path = "", .starts = starts, .duration = 5, .width = 1920, .height = 818, .codecs = "avc1.640028,mp4a.40.2", .bandwidth = 6000000 };
    defer gpa.free(seg.starts);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try seg.writeMaster(&aw.writer);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "#EXT-X-STREAM-INF:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "RESOLUTION=1920x818") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CODECS=\"avc1.640028,mp4a.40.2\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "index.m3u8\n"));
}

test "playlist renders a VOD list" {
    const gpa = std.testing.allocator;
    const starts = try gpa.dupe(f64, &.{ 0, 6, 12 });
    var seg: Segmenter = .{ .gpa = gpa, .path = "", .starts = starts, .duration = 15, .width = 1920, .height = 818, .codecs = "avc1.640028,mp4a.40.2", .bandwidth = 6000000 };
    defer gpa.free(seg.starts);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try seg.writePlaylist(&aw.writer);
    const text = aw.written();

    try std.testing.expect(std.mem.startsWith(u8, text, "#EXTM3U"));
    try std.testing.expect(std.mem.indexOf(u8, text, "#EXT-X-PLAYLIST-TYPE:VOD") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "seg2.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "#EXTINF:3.000") != null); // last segment 15-12
    try std.testing.expect(std.mem.endsWith(u8, text, "#EXT-X-ENDLIST\n"));
}
