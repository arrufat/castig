//! Decides how a file reaches the receiver and drives libav to remux it.
//!
//! Input is inspected once:
//!   video playable + audio playable   -> serve the file directly (no remux)
//!   video playable + audio unplayable -> remux to fragmented MP4, copy the
//!                                        video stream, transcode audio to AAC
//!   video unplayable                  -> caller falls back to direct; software
//!                                        video transcode is not implemented yet
//!
//! The remux output is written through a custom `av.IOContext` whose write
//! callback feeds an `std.Io.Writer` (the HTTP response body), so nothing
//! touches the disk. The muxer uses `movflags=frag_keyframe+empty_moov+
//! default_base_moof`, which streams forward without ever seeking back, so the
//! AVIO seek callback is null.
//!
//! Seeking a transcoded stream restarts the pipeline; that is not wired up
//! yet, so the receiver treats the remuxed stream as unseekable.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("../av_extra.zig");
const probe = @import("../probe.zig");

/// AV_TIME_BASE: container-level timestamps are microseconds.
const time_base_q: av.Rational = .{ .num = 1, .den = 1_000_000 };

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

/// A remux job. `generate` runs the whole transcode, writing MP4 to `w`.
pub const Remux = struct {
    gpa: std.mem.Allocator,
    path: []const u8,

    pub fn generate(ctx: *const Remux, start_time: f64, w: *Io.Writer) anyerror!void {
        try transcode(ctx.gpa, ctx.path, start_time, w);
    }
};

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

fn transcode(gpa: std.mem.Allocator, path: []const u8, start_time: f64, w: *Io.Writer) !void {
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);

    av.LOG.set_level(.ERROR);
    const ic = try av.FormatContext.open_input(path_z, null, null, null);
    defer ic.close_input();
    try ic.find_stream_info(null);

    const video_index: ?usize = if (ic.find_best_stream(.VIDEO, -1, -1)) |v| @intCast(v[0]) else |_| null;
    const audio_index: usize = if (ic.find_best_stream(.AUDIO, -1, -1)) |a| @intCast(a[0]) else |_| return error.NoAudioStream;
    const in_audio = ic.streams[audio_index];

    // Seek the input to the requested offset. AV_TIME_BASE is microseconds,
    // flag 1 (BACKWARD) lands on the keyframe at or before the target.
    if (start_time > 0) {
        try ic.seek_frame(-1, @intFromFloat(start_time * 1_000_000), 1);
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

    // Output: fragmented MP4 to a custom AVIO backed by the HTTP writer.
    const oc = try extra.allocOutputContext("mp4");
    defer av.avformat_free_context(oc);

    var sink: Sink = .{ .w = w };
    const io_buffer = try av.malloc(io_buffer_len);
    const avio = try av.IOContext.alloc(io_buffer, .writable, &sink, null, writeCallback, null);
    oc.pb = avio;
    defer av.IOContext.free(avio);

    // Copy the video stream as is.
    var out_video_index: ?c_int = null;
    if (video_index) |vi| {
        const in_video = ic.streams[vi];
        const out_video = try extra.newStream(oc);
        try extra.copyParameters(out_video.codecpar, in_video.codecpar);
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
    try opts.set("movflags", "frag_keyframe+empty_moov+default_base_moof", .{});
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

    const fifo = av_fifo: {
        break :av_fifo extra.av_audio_fifo_alloc(enc.sample_fmt, enc.ch_layout.nb_channels, 1) orelse return error.OutOfMemory;
    };
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
            extra.av_packet_rescale_ts(pkt, in_video.time_base, oc.streams[@intCast(out_video_index.?)].time_base);
            pkt.stream_index = out_video_index.?;
            try extra.writeFrame(oc, pkt);
        } else if (pkt.stream_index == @as(c_int, @intCast(audio_index))) {
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
