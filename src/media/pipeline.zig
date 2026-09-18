//! Decides how a file reaches the receiver, and remuxes a time window of it.
//!
//! `plan` inspects a file once:
//!   video playable + audio playable   -> serve the file directly (no remux)
//!   video playable + audio unplayable -> remux (copy video, audio to AAC)
//!   video unplayable                  -> caller falls back to direct; software
//!                                        video transcode is not implemented yet
//!
//! `remuxWindow` transcodes the window [start, end) of a file into a chosen
//! container, writing through a custom `av.IOContext` whose callback feeds an
//! `std.Io.Writer`, so nothing touches the disk. The HLS segmenter
//! (`hls.zig`) calls it once per MPEG-TS segment; the seek callback is null
//! because both mp4-fragment and mpegts output only stream forward.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("../av_extra.zig");
const probe = @import("../probe.zig");

/// AV_TIME_BASE: container-level timestamps are microseconds.
const av_time_base: f64 = 1_000_000;

pub const Plan = struct {
    /// True when the file can be served untouched.
    direct: bool,
    /// True when the video codec is not playable and remux cannot help.
    video_unsupported: bool,
    duration: ?f64,
    video_codec: []const u8,
    audio_codec: []const u8,
};

/// Opens the file, looks at the primary video and audio streams, and decides
/// whether a remux is needed. Codecs are matched by name (see `av_extra`).
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

    for (ic.streams[0..ic.nb_streams]) |st| {
        const par = st.codecpar;
        const name = extra.codecName(extra.codecId(par));
        switch (par.codec_type) {
            .VIDEO => if (!have_video) {
                have_video = true;
                video_codec = name;
                video_ok = probe.videoSupport(name) != .transcode;
            },
            .AUDIO => if (!have_audio) {
                have_audio = true;
                audio_codec = name;
                audio_ok = probe.audioSupport(name) == .direct;
            },
            else => {},
        }
    }

    const duration: ?f64 = if (ic.duration != av.NOPTS_VALUE)
        @as(f64, @floatFromInt(ic.duration)) / 1_000_000
    else
        null;

    return .{
        .direct = video_ok and audio_ok,
        .video_unsupported = have_video and !video_ok,
        .duration = duration,
        .video_codec = video_codec,
        .audio_codec = audio_codec,
    };
}

/// Bridges libav's AVIO to an `std.Io.Writer`.
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
        return -1; // any negative value aborts the muxer
    };
    return size;
}

const io_buffer_len = 64 * 1024;
const aac_bitrate = 192_000;

/// Transcodes the window [start_time, end_time) of `path` into `format`
/// ("mpegts" or "mp4"), copying video and encoding audio to AAC, writing the
/// container to `w`. `end_time` null runs to end of file.
pub fn remuxWindow(
    gpa: std.mem.Allocator,
    path: []const u8,
    start_time: f64,
    end_time: ?f64,
    format: [*:0]const u8,
    w: *Io.Writer,
) !void {
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);

    av.LOG.set_level(.ERROR);
    const ic = try av.FormatContext.open_input(path_z, null, null, null);
    defer ic.close_input();
    try ic.find_stream_info(null);

    const video_index: ?usize = if (ic.find_best_stream(.VIDEO, -1, -1)) |v| @intCast(v[0]) else |_| null;
    const audio_index: usize = if (ic.find_best_stream(.AUDIO, -1, -1)) |a| @intCast(a[0]) else |_| return error.NoAudioStream;
    const in_audio = ic.streams[audio_index];

    // Seek the input to the window start. AV_TIME_BASE is microseconds,
    // flag 1 (BACKWARD) lands on the keyframe at or before the target.
    if (start_time > 0) {
        try ic.seek_frame(-1, @intFromFloat(start_time * av_time_base), 1);
    }

    // Audio decoder.
    const dec_codec = try av.Codec.find_decoder(in_audio.codecpar.codec_id);
    const dec = try av.Codec.Context.alloc(dec_codec);
    defer dec.free();
    try dec.parameters_to_context(in_audio.codecpar);
    try dec.open(dec_codec, null);

    // AAC encoder, same sample rate and channel layout as the source.
    const enc_codec = try av.Codec.find_encoder_by_name("aac");
    const enc = try av.Codec.Context.alloc(enc_codec);
    defer enc.free();
    enc.sample_rate = dec.sample_rate;
    try extra.copyChannelLayout(&enc.ch_layout, &dec.ch_layout);
    enc.sample_fmt = .FLTP;
    enc.bit_rate = aac_bitrate;
    enc.time_base = .{ .num = 1, .den = dec.sample_rate };
    enc.flags |= extra.CODEC_FLAG_GLOBAL_HEADER;
    try enc.open(enc_codec, null);

    // Output to a custom AVIO backed by the HTTP writer.
    const oc = try extra.allocOutputContext(format);
    defer av.avformat_free_context(oc);

    var sink: Sink = .{ .w = w };
    const io_buffer = try av.malloc(io_buffer_len);
    const avio = try av.IOContext.alloc(io_buffer, .writable, &sink, null, writeCallback, null);
    oc.pb = avio;
    defer av.IOContext.free(avio);

    // Copy the video stream as is. H.264/HEVC from MP4/MKV keeps its parameter
    // sets in extradata, so route copied packets through the Annex-B bitstream
    // filter, which repeats SPS/PPS in-band before each keyframe (MPEG-TS and
    // the Cast decoder need that; the muxer API will not do it for us).
    var out_video_index: ?c_int = null;
    var video_bsf: ?*extra.BSFContext = null;
    defer if (video_bsf) |b| {
        var bb: ?*extra.BSFContext = b;
        extra.av_bsf_free(&bb);
    };
    if (video_index) |vi| {
        const in_video = ic.streams[vi];
        const out_video = try extra.newStream(oc);
        const vcodec = extra.codecName(extra.codecId(in_video.codecpar));
        if (extra.annexbFilterName(vcodec)) |filter_name| {
            const filter = extra.av_bsf_get_by_name(filter_name) orelse return error.BsfNotFound;
            var ctx: ?*extra.BSFContext = null;
            _ = try av.wrap(extra.av_bsf_alloc(filter, &ctx));
            const b = ctx.?;
            try extra.copyParameters(b.par_in, in_video.codecpar);
            b.time_base_in = in_video.time_base;
            _ = try av.wrap(extra.av_bsf_init(b));
            video_bsf = b;
            try extra.copyParameters(out_video.codecpar, b.par_out);
        } else {
            try extra.copyParameters(out_video.codecpar, in_video.codecpar);
        }
        out_video.codecpar.codec_tag = 0;
        out_video.time_base = in_video.time_base;
        out_video_index = out_video.index;
    }

    // Transcoded audio stream.
    const out_audio = try extra.newStream(oc);
    try extra.parametersFromContext(out_audio.codecpar, enc);
    out_audio.time_base = enc.time_base;
    const out_audio_index = out_audio.index;

    var opts: av.Dictionary.Mutable = .empty;
    defer opts.free();
    if (std.mem.orderZ(u8, format, "mp4") == .eq) {
        try opts.set("movflags", "frag_keyframe+empty_moov+default_base_moof", .{});
    }
    try extra.writeHeader(oc, &opts);

    // Audio pipeline: decode -> resample to the encoder format -> FIFO ->
    // encode in fixed-size frames.
    const swr = try av.swr.Context.alloc_set_opts(
        &enc.ch_layout,
        enc.sample_fmt,
        enc.sample_rate,
        &dec.ch_layout,
        dec.sample_fmt,
        dec.sample_rate,
        0,
        null,
    );
    defer swr.free();
    try swr.init();

    const fifo = extra.av_audio_fifo_alloc(enc.sample_fmt, enc.ch_layout.nb_channels, 1) orelse return error.OutOfMemory;
    defer extra.av_audio_fifo_free(fifo);

    var ctx: AudioCtx = .{
        .gpa = gpa,
        .dec = dec,
        .enc = enc,
        .swr = swr,
        .fifo = fifo,
        .oc = oc,
        .out_index = out_audio_index,
        .enc_frame = try av.Frame.alloc(),
        .out_packet = try av.Packet.alloc(),
        .next_pts = @intFromFloat(start_time * @as(f64, @floatFromInt(dec.sample_rate))),
        .pts_set = false,
        .in_time_base = in_audio.time_base,
        .sink = &sink,
    };
    defer ctx.enc_frame.free();
    defer ctx.out_packet.free();

    const pkt = try av.Packet.alloc();
    defer pkt.free();
    const vpkt = try av.Packet.alloc();
    defer vpkt.free();
    const dec_frame = try av.Frame.alloc();
    defer dec_frame.free();

    while (true) {
        ic.read_frame(pkt) catch |err| switch (err) {
            error.EndOfFile => break,
            else => return err,
        };
        defer pkt.unref();
        if (sink.failed) return error.WriteFailed;

        if (out_video_index != null and pkt.stream_index == @as(c_int, @intCast(video_index.?))) {
            const in_video = ic.streams[video_index.?];
            const out_tb = oc.streams[@intCast(out_video_index.?)].time_base;
            // Stop once we reach the segment's end keyframe (video is copied,
            // so segment boundaries fall on keyframes).
            if (end_time) |end| if (pkt.pts != av.NOPTS_VALUE) {
                if (@as(f64, @floatFromInt(pkt.pts)) * in_video.time_base.q2d() >= end) break;
            };
            if (video_bsf) |b| {
                try extra.bsfSend(b, pkt); // takes ownership of pkt
                while (true) {
                    extra.bsfReceive(b, vpkt) catch |err| switch (err) {
                        error.WouldBlock, error.EndOfFile => break,
                        else => return err,
                    };
                    extra.av_packet_rescale_ts(vpkt, in_video.time_base, out_tb);
                    vpkt.stream_index = out_video_index.?;
                    try extra.writeFrame(oc, vpkt);
                    vpkt.unref();
                }
            } else {
                extra.av_packet_rescale_ts(pkt, in_video.time_base, out_tb);
                pkt.stream_index = out_video_index.?;
                try extra.writeFrame(oc, pkt);
            }
        } else if (pkt.stream_index == @as(c_int, @intCast(audio_index))) {
            // With no video, an audio packet past the window ends the segment.
            if (out_video_index == null) if (end_time) |end| if (pkt.pts != av.NOPTS_VALUE) {
                if (@as(f64, @floatFromInt(pkt.pts)) * in_audio.time_base.q2d() >= end) break;
            };
            try dec.send_packet(pkt);
            try drainDecoder(&ctx, dec_frame);
        }
    }

    // Flush the decoder, then the FIFO tail, then the encoder.
    try dec.send_packet(null);
    try drainDecoder(&ctx, dec_frame);
    try encodeFifo(&ctx, true);
    try encodeFrame(&ctx, null);

    if (sink.failed) return error.WriteFailed;
    try extra.writeTrailer(oc);
}

const AudioCtx = struct {
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
    /// Set once the first decoded frame anchors the output timeline.
    pts_set: bool,
    in_time_base: av.Rational,
    sink: *Sink,
};

fn drainDecoder(ctx: *AudioCtx, frame: *av.Frame) !void {
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

/// Resamples one decoded frame into the encoder format and appends it to the FIFO.
fn pushToFifo(ctx: *AudioCtx, frame: *av.Frame) !void {
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

/// Pulls encoder-sized chunks out of the FIFO and encodes them. When `final`
/// is set, a smaller last chunk is flushed too.
fn encodeFifo(ctx: *AudioCtx, final: bool) !void {
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

fn encodeFrame(ctx: *AudioCtx, frame: ?*av.Frame) !void {
    try extra.sendFrame(ctx.enc, frame);
    while (true) {
        extra.receivePacket(ctx.enc, ctx.out_packet) catch |err| switch (err) {
            error.WouldBlock, error.EndOfFile => return,
            else => return err,
        };
        defer ctx.out_packet.unref();
        ctx.out_packet.stream_index = ctx.out_index;
        extra.av_packet_rescale_ts(ctx.out_packet, ctx.enc.time_base, ctx.oc.streams[@intCast(ctx.out_index)].time_base);
        try extra.writeFrame(ctx.oc, ctx.out_packet);
        if (ctx.sink.failed) return error.WriteFailed;
    }
}

test {
    std.testing.refAllDecls(@This());
}
