//! Decides how a file reaches the receiver, and remuxes a time window of it.
//!
//! `plan` inspects a file once:
//!   video playable + audio playable   -> serve the file directly (no remux)
//!   video playable + audio unplayable -> remux (copy video, audio to AAC)
//!   video unplayable                  -> caller falls back to direct; software
//!                                        video transcode is not implemented yet
//!
//! `remuxWindow(gpa, path, start, end, format, w)` transcodes the window
//! [start, end) into `format` ("mpegts" for HLS segments), copying video and
//! encoding audio to AAC, written through a custom `av.IOContext` into an
//! `std.Io.Writer` so nothing hits disk. For MPEG-TS the copied H.264/HEVC is
//! passed through the Annex-B bitstream filter (in-band SPS/PPS). Audio is
//! downmixed to stereo.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("../av_extra.zig");
const probe = @import("../probe.zig");
const subtitles = @import("subtitles.zig");

const av_time_base: f64 = 1_000_000;
const io_buffer_len = 64 * 1024;
const aac_bitrate = 192_000;
/// fMP4: init is ftyp+moov, each fragment is moof+mdat, timestamps kept absolute.
const fmp4_movflags = "frag_keyframe+empty_moov+default_base_moof";

/// A text subtitle stream embedded in the source that we can side-load as a
/// WebVTT track. `language`/`title` are duped into the `plan` allocator.
pub const SubtitleStream = struct {
    index: usize,
    language: []const u8,
    title: []const u8,
};

pub const Plan = struct {
    direct: bool,
    video_unsupported: bool,
    duration: ?f64,
    video_codec: []const u8,
    audio_codec: []const u8,
    video_height: c_int,
    /// Text subtitle streams we can offer as WebVTT tracks (bitmap subs skipped).
    subtitles: []const SubtitleStream,
};

fn dictGet(dict: av.Dictionary.Mutable, key: [*:0]const u8) ?[]const u8 {
    const entry = dict.get(key, null, .{}) orelse return null;
    return std.mem.span(entry.value);
}

/// Inspects `path` once: how to deliver it, and which text subtitle streams it
/// carries. `gpa` owns the returned subtitle strings.
pub fn plan(gpa: std.mem.Allocator, path: []const u8) !Plan {
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);

    av.LOG.set_level(.ERROR);
    const ic = try av.FormatContext.open_input(path_z, null, null, null);
    defer ic.close_input();
    try ic.find_stream_info(null);

    var video_codec: []const u8 = "";
    var audio_codec: []const u8 = "";
    var video_ok = true;
    var audio_ok = true;
    var have_video = false;
    var have_audio = false;
    var video_height: c_int = 0;
    var subs: std.ArrayList(SubtitleStream) = .empty;
    errdefer subs.deinit(gpa);

    for (ic.streams[0..ic.nb_streams], 0..) |st, i| {
        const par = st.codecpar;
        const name = extra.codecName(extra.codecId(par));
        switch (par.codec_type) {
            .VIDEO => if (!have_video) {
                have_video = true;
                video_codec = name;
                video_ok = probe.videoSupport(name) != .transcode;
                video_height = par.height;
            },
            .AUDIO => if (!have_audio) {
                have_audio = true;
                audio_codec = name;
                audio_ok = probe.audioSupport(name) == .direct;
            },
            .SUBTITLE => if (subtitles.textIsSupported(name)) {
                try subs.append(gpa, .{
                    .index = i,
                    .language = try gpa.dupe(u8, dictGet(st.metadata, "language") orelse "und"),
                    .title = try gpa.dupe(u8, dictGet(st.metadata, "title") orelse ""),
                });
            },
            else => {},
        }
    }

    const duration: ?f64 = if (ic.duration != av.NOPTS_VALUE)
        @as(f64, @floatFromInt(ic.duration)) / av_time_base
    else
        null;

    return .{
        .direct = video_ok and audio_ok,
        .video_unsupported = have_video and !video_ok,
        .duration = duration,
        .video_codec = video_codec,
        .audio_codec = audio_codec,
        .video_height = video_height,
        .subtitles = try subs.toOwnedSlice(gpa),
    };
}

/// Demuxes subtitle stream `stream_index` from `path` and returns it as WebVTT.
/// Reads the whole container (subtitle packets are interleaved), so callers
/// should do this lazily, only when the receiver requests the track.
pub fn extractSubtitle(gpa: std.mem.Allocator, path: []const u8, stream_index: usize) ![]u8 {
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);

    av.LOG.set_level(.ERROR);
    const ic = try av.FormatContext.open_input(path_z, null, null, null);
    defer ic.close_input();
    try ic.find_stream_info(null);
    if (stream_index >= ic.nb_streams) return error.NoSuchStream;

    const st = ic.streams[stream_index];
    const tb = st.time_base;
    const codec = extra.codecName(extra.codecId(st.codecpar));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try subtitles.writeVttHeader(gpa, &out);

    const pkt = try av.Packet.alloc();
    defer pkt.free();
    while (true) {
        ic.read_frame(pkt) catch |err| switch (err) {
            error.EndOfFile => break,
            else => return err,
        };
        defer pkt.unref();
        if (pkt.stream_index != @as(c_int, @intCast(stream_index))) continue;
        if (pkt.pts == av.NOPTS_VALUE) continue;

        const start_ms = ptsToMs(pkt.pts, tb);
        const end_ms = if (pkt.duration > 0) ptsToMs(pkt.pts + pkt.duration, tb) else start_ms + 2000;
        const data = pkt.data[0..@intCast(pkt.size)];
        try subtitles.writeVttCue(gpa, &out, start_ms, end_ms, codec, data);
    }
    return out.toOwnedSlice(gpa);
}

fn ptsToMs(pts: i64, tb: av.Rational) i64 {
    return @intFromFloat(@as(f64, @floatFromInt(pts)) * tb.q2d() * 1000.0);
}

// --- AVIO bridge ------------------------------------------------------------

const Sink = struct {
    w: *Io.Writer,
    failed: bool = false,
};

fn writeCallback(userdata: ?*anyopaque, buf: [*:0]u8, size: c_int) callconv(.c) c_int {
    const sink: *Sink = @ptrCast(@alignCast(userdata.?));
    const n: usize = @intCast(size);
    const bytes: [*]const u8 = @ptrCast(buf);
    sink.w.writeAll(bytes[0..n]) catch {
        sink.failed = true;
        return -1;
    };
    return size;
}

// --- audio transcoder setup -------------------------------------------------

/// A decoder for the input audio and an AAC encoder that downmixes to stereo.
/// Shared by the remux `Session` and the on-the-fly MP4 assembler so their
/// encoder parameters (bitrate, stereo policy, global header) never diverge.
pub const AacTranscode = struct { dec: *av.Codec.Context, enc: *av.Codec.Context };

pub fn openStereoAac(par: *av.Codec.Parameters) !AacTranscode {
    const dec_codec = try av.Codec.find_decoder(par.codec_id);
    const dec = try av.Codec.Context.alloc(dec_codec);
    errdefer dec.free();
    try dec.parameters_to_context(par);
    try dec.open(dec_codec, null);

    const enc_codec = try av.Codec.find_encoder_by_name("aac");
    const enc = try av.Codec.Context.alloc(enc_codec);
    errdefer enc.free();
    enc.sample_rate = dec.sample_rate;
    // Downmix to stereo. Many receivers (and stereo devices like the Pixel
    // Tablet) reject multichannel AAC in an HLS stream; swr does the mix.
    extra.av_channel_layout_default(&enc.ch_layout, 2);
    enc.sample_fmt = .FLTP;
    enc.bit_rate = aac_bitrate;
    enc.time_base = .{ .num = 1, .den = dec.sample_rate };
    enc.flags |= extra.CODEC_FLAG_GLOBAL_HEADER;
    try enc.open(enc_codec, null);
    return .{ .dec = dec, .enc = enc };
}

// --- session ----------------------------------------------------------------

/// Everything libav needs to remux one file into one output, minus the header
/// write and the packet loop, which the callers drive differently. Output goes
/// to a streaming `Sink` (a custom AVIO writing to an `Io.Writer`).
const Session = struct {
    gpa: std.mem.Allocator,
    sink: *Sink,
    ic: *av.FormatContext,
    video_index: ?usize,
    audio_index: usize,
    dec: *av.Codec.Context,
    enc: *av.Codec.Context,
    oc: *av.FormatContext,
    avio: *av.IOContext,
    out_video_index: ?c_int,
    video_bsf: ?*extra.BSFContext,
    out_audio_index: c_int,

    /// `format` is an ffmpeg muxer name ("mp4" or "mpegts"). MPEG-TS gets the
    /// Annex-B bitstream filter on copied video; MP4 keeps AVCC.
    fn open(gpa: std.mem.Allocator, path: []const u8, format: [*:0]const u8, sink: *Sink) !Session {
        const path_z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(path_z);

        av.LOG.set_level(.ERROR);
        const ic = try av.FormatContext.open_input(path_z, null, null, null);
        errdefer ic.close_input();
        try ic.find_stream_info(null);

        const video_index: ?usize = if (ic.find_best_stream(.VIDEO, -1, -1)) |v| @intCast(v[0]) else |_| null;
        const audio_index: usize = if (ic.find_best_stream(.AUDIO, -1, -1)) |a| @intCast(a[0]) else |_| return error.NoAudioStream;
        const in_audio = ic.streams[audio_index];

        const at = try openStereoAac(in_audio.codecpar);
        errdefer at.dec.free();
        errdefer at.enc.free();
        const dec = at.dec;
        const enc = at.enc;

        const oc = try extra.allocOutputContext(format);
        errdefer av.avformat_free_context(oc);

        const io_buffer = try av.malloc(io_buffer_len);
        const avio = try av.IOContext.alloc(io_buffer, .writable, sink, null, writeCallback, null);
        oc.pb = avio;
        errdefer av.IOContext.free(avio);

        const annexb = std.mem.orderZ(u8, format, "mpegts") == .eq;

        var out_video_index: ?c_int = null;
        var video_bsf: ?*extra.BSFContext = null;
        errdefer if (video_bsf) |b| {
            var bb: ?*extra.BSFContext = b;
            extra.av_bsf_free(&bb);
        };
        if (video_index) |vi| {
            const in_video = ic.streams[vi];
            const out_video = try extra.newStream(oc);
            const vcodec = extra.codecName(extra.codecId(in_video.codecpar));
            if (annexb) if (extra.annexbFilterName(vcodec)) |filter_name| {
                const filter = extra.av_bsf_get_by_name(filter_name) orelse return error.BsfNotFound;
                var ctx: ?*extra.BSFContext = null;
                _ = try av.wrap(extra.av_bsf_alloc(filter, &ctx));
                const b = ctx.?;
                try extra.copyParameters(b.par_in, in_video.codecpar);
                b.time_base_in = in_video.time_base;
                _ = try av.wrap(extra.av_bsf_init(b));
                video_bsf = b;
            };
            if (video_bsf) |b| {
                try extra.copyParameters(out_video.codecpar, b.par_out);
            } else {
                try extra.copyParameters(out_video.codecpar, in_video.codecpar);
            }
            out_video.codecpar.codec_tag = 0;
            out_video.time_base = in_video.time_base;
            out_video_index = out_video.index;
        }

        const out_audio = try extra.newStream(oc);
        try extra.parametersFromContext(out_audio.codecpar, enc);
        out_audio.time_base = enc.time_base;

        return .{
            .gpa = gpa,
            .sink = sink,
            .ic = ic,
            .video_index = video_index,
            .audio_index = audio_index,
            .dec = dec,
            .enc = enc,
            .oc = oc,
            .avio = avio,
            .out_video_index = out_video_index,
            .video_bsf = video_bsf,
            .out_audio_index = out_audio.index,
        };
    }

    fn deinit(s: *Session) void {
        if (s.video_bsf) |b| {
            var bb: ?*extra.BSFContext = b;
            extra.av_bsf_free(&bb);
        }
        av.IOContext.free(s.avio);
        av.avformat_free_context(s.oc);
        s.enc.free();
        s.dec.free();
        s.ic.close_input();
    }

    fn failed(s: *Session) bool {
        return s.sink.failed;
    }

    fn writeHeader(s: *Session, movflags: ?[*:0]const u8, keep_absolute_ts: bool) !void {
        if (keep_absolute_ts) s.oc.avoid_negative_ts = 0; // AVFMT_AVOID_NEG_TS_DISABLED
        var opts: av.Dictionary.Mutable = .empty;
        defer opts.free();
        if (movflags) |f| try opts.set("movflags", f, .{});
        try extra.writeHeader(s.oc, &opts);
    }

    /// Copies video and transcodes audio for [start_time, end_time) into the
    /// already-headered output. `end_time` null runs to end of file.
    fn runWindow(s: *Session, start_time: f64, end_time: ?f64) !void {
        if (start_time > 0) try s.ic.seek_frame(-1, @intFromFloat(start_time * av_time_base), 1);

        const in_audio = s.ic.streams[s.audio_index];
        var ctx: AudioCtx = .{
            .gpa = s.gpa,
            .dec = s.dec,
            .enc = s.enc,
            .swr = try av.swr.Context.alloc_set_opts(&s.enc.ch_layout, s.enc.sample_fmt, s.enc.sample_rate, &s.dec.ch_layout, s.dec.sample_fmt, s.dec.sample_rate, 0, null),
            .fifo = extra.av_audio_fifo_alloc(s.enc.sample_fmt, s.enc.ch_layout.nb_channels, 1) orelse return error.OutOfMemory,
            .oc = s.oc,
            .out_index = s.out_audio_index,
            .enc_frame = try av.Frame.alloc(),
            .out_packet = try av.Packet.alloc(),
            .next_pts = @intFromFloat(start_time * @as(f64, @floatFromInt(s.dec.sample_rate))),
            .pts_set = false,
            .in_time_base = in_audio.time_base,
            .sink = s.sink,
        };
        try ctx.swr.init();
        defer ctx.swr.free();
        defer extra.av_audio_fifo_free(ctx.fifo);
        defer ctx.enc_frame.free();
        defer ctx.out_packet.free();

        const pkt = try av.Packet.alloc();
        defer pkt.free();
        const vpkt = try av.Packet.alloc();
        defer vpkt.free();
        const dec_frame = try av.Frame.alloc();
        defer dec_frame.free();

        while (true) {
            s.ic.read_frame(pkt) catch |err| switch (err) {
                error.EndOfFile => break,
                else => return err,
            };
            defer pkt.unref();
            if (s.failed()) return error.WriteFailed;

            if (s.out_video_index != null and pkt.stream_index == @as(c_int, @intCast(s.video_index.?))) {
                const in_video = s.ic.streams[s.video_index.?];
                const out_tb = s.oc.streams[@intCast(s.out_video_index.?)].time_base;
                if (pkt.pts != av.NOPTS_VALUE) {
                    const secs = @as(f64, @floatFromInt(pkt.pts)) * in_video.time_base.q2d();
                    if (end_time) |end| if (secs >= end) break;
                }
                if (s.video_bsf) |b| {
                    try extra.bsfSend(b, pkt);
                    while (true) {
                        extra.bsfReceive(b, vpkt) catch |err| switch (err) {
                            error.WouldBlock, error.EndOfFile => break,
                            else => return err,
                        };
                        extra.av_packet_rescale_ts(vpkt, in_video.time_base, out_tb);
                        vpkt.stream_index = s.out_video_index.?;
                        try extra.writeFrame(s.oc, vpkt);
                        vpkt.unref();
                    }
                } else {
                    extra.av_packet_rescale_ts(pkt, in_video.time_base, out_tb);
                    pkt.stream_index = s.out_video_index.?;
                    try extra.writeFrame(s.oc, pkt);
                }
            } else if (pkt.stream_index == @as(c_int, @intCast(s.audio_index))) {
                if (s.out_video_index == null) if (end_time) |end| if (pkt.pts != av.NOPTS_VALUE) {
                    if (@as(f64, @floatFromInt(pkt.pts)) * in_audio.time_base.q2d() >= end) break;
                };
                try s.dec.send_packet(pkt);
                try drainDecoder(&ctx, dec_frame);
            }
        }

        try s.dec.send_packet(null);
        try drainDecoder(&ctx, dec_frame);
        try encodeFifo(&ctx, true);
        try encodeFrame(&ctx, null);
    }
};

// --- public entry points ----------------------------------------------------

/// Generic remux of a window into `format` streamed to `w`. Writes a full
/// container: header, body, trailer. Used for MPEG-TS HLS segments, and for
/// the `--remux stream` fragmented-MP4 live stream (format "mp4").
pub fn remuxWindow(gpa: std.mem.Allocator, path: []const u8, start_time: f64, end_time: ?f64, format: [*:0]const u8, w: *Io.Writer) !void {
    var sink: Sink = .{ .w = w };
    var s = try Session.open(gpa, path, format, &sink);
    defer s.deinit();
    const is_mp4 = std.mem.orderZ(u8, format, "mp4") == .eq;
    try s.writeHeader(if (is_mp4) fmp4_movflags else null, is_mp4);
    try s.runWindow(start_time, end_time);
    if (sink.failed) return error.WriteFailed;
    try extra.writeTrailer(s.oc);
}

// --- audio transcode helpers ------------------------------------------------

pub const AudioCtx = struct {
    gpa: std.mem.Allocator,
    dec: *av.Codec.Context,
    enc: *av.Codec.Context,
    swr: *av.swr.Context,
    fifo: *extra.AudioFifo,
    oc: *av.FormatContext,
    out_index: c_int,
    enc_frame: *av.Frame,
    out_packet: *av.Packet,
    next_pts: i64,
    pts_set: bool,
    in_time_base: av.Rational,
    sink: ?*Sink,
    /// When set, encoded packets go here (in encoder time_base) instead of being
    /// muxed. Used by the virtual-MP4 assembler to capture AAC packets.
    collect: ?*const fn (*anyopaque, *av.Packet) anyerror!void = null,
    collect_ctx: ?*anyopaque = null,
};

pub fn drainDecoder(ctx: *AudioCtx, frame: *av.Frame) !void {
    while (true) {
        ctx.dec.receive_frame(frame) catch |err| switch (err) {
            error.WouldBlock, error.EndOfFile => return,
            else => return err,
        };
        defer frame.unref();
        if (!ctx.pts_set) {
            const ts = frame.best_effort_timestamp;
            if (ts != av.NOPTS_VALUE) {
                const seconds = @as(f64, @floatFromInt(ts)) * ctx.in_time_base.q2d();
                ctx.next_pts = @intFromFloat(seconds * @as(f64, @floatFromInt(ctx.enc.sample_rate)));
            }
            ctx.pts_set = true;
        }
        try pushToFifo(ctx, frame);
        try encodeFifo(ctx, false);
    }
}

pub fn pushToFifo(ctx: *AudioCtx, frame: *av.Frame) !void {
    const out_samples = frame.nb_samples + 32;
    var converted: [8]?[*]u8 = @splat(null);
    _ = try av.wrap(av.av_samples_alloc(&converted, null, ctx.enc.ch_layout.nb_channels, out_samples, ctx.enc.sample_fmt, 0));
    defer av.freep(@ptrCast(&converted[0]));

    const in_ptr: [*]const [*]const u8 = @ptrCast(&frame.extended_data[0]);
    const out_ptr: [*]const [*]u8 = @ptrCast(&converted[0]);
    const n = try ctx.swr.convert(out_ptr, out_samples, in_ptr, frame.nb_samples);

    if (n > 0) {
        const data_ptr: [*]const ?*anyopaque = @ptrCast(&converted[0]);
        if (extra.av_audio_fifo_write(ctx.fifo, data_ptr, @intCast(n)) < 0) return error.FifoWrite;
    }
}

pub fn encodeFifo(ctx: *AudioCtx, final: bool) !void {
    const frame_size = ctx.enc.frame_size;
    while (extra.av_audio_fifo_size(ctx.fifo) >= frame_size or (final and extra.av_audio_fifo_size(ctx.fifo) > 0)) {
        const have = extra.av_audio_fifo_size(ctx.fifo);
        const n = @min(frame_size, have);

        const frame = ctx.enc_frame;
        frame.unref();
        frame.nb_samples = n;
        frame.format = .{ .sample = ctx.enc.sample_fmt };
        try extra.copyChannelLayout(&frame.ch_layout, &ctx.enc.ch_layout);
        frame.sample_rate = ctx.enc.sample_rate;
        try extra.frameGetBuffer(frame);

        const data_ptr: [*]const ?*anyopaque = @ptrCast(&frame.data[0]);
        if (extra.av_audio_fifo_read(ctx.fifo, data_ptr, n) < n) return error.FifoRead;

        frame.pts = ctx.next_pts;
        ctx.next_pts += n;
        try encodeFrame(ctx, frame);
    }
}

pub fn encodeFrame(ctx: *AudioCtx, frame: ?*av.Frame) !void {
    try extra.sendFrame(ctx.enc, frame);
    while (true) {
        extra.receivePacket(ctx.enc, ctx.out_packet) catch |err| switch (err) {
            error.WouldBlock, error.EndOfFile => return,
            else => return err,
        };
        defer ctx.out_packet.unref();
        if (ctx.collect) |collect| {
            // Hand the encoder-time_base packet to the assembler; do not mux.
            try collect(ctx.collect_ctx.?, ctx.out_packet);
            continue;
        }
        ctx.out_packet.stream_index = ctx.out_index;
        extra.av_packet_rescale_ts(ctx.out_packet, ctx.enc.time_base, ctx.oc.streams[@intCast(ctx.out_index)].time_base);
        try extra.writeFrame(ctx.oc, ctx.out_packet);
        if (ctx.sink) |sk| if (sk.failed) return error.WriteFailed;
    }
}

test {
    std.testing.refAllDecls(@This());
}
