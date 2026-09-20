//! Decides how a file reaches the receiver, and remuxes a time window of it.
//!
//! `plan` inspects a file once:
//!   video playable + audio playable   -> serve the file directly (no remux)
//!   video playable + audio unplayable -> remux (copy video, audio to AAC)
//!   video unplayable                  -> caller falls back to direct; software
//!                                        video transcode is not implemented yet
//!
//! A remux copies video and encodes audio to AAC into `Container`, written
//! through a custom `av.IOContext` into an `std.Io.Writer` so nothing hits
//! disk. The demuxer and audio decoder (`Input`) are reusable across windows,
//! since opening and probing a file per HLS segment cost more than the segment
//! itself; the muxer and encoder (`Output`) are per window.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("av_extra.zig");
const support = @import("support.zig");
const webvtt = @import("webvtt.zig");

const aac_bitrate = 192_000;

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
    /// First video stream's average frame rate, when the demuxer knows it.
    fps: ?f64,
    video_codec: []const u8,
    audio_codec: []const u8,
    /// Text subtitle streams we can offer as WebVTT tracks (bitmap subs skipped).
    subtitles: []const SubtitleStream,
    /// The probed demuxer, for the delivery that needs it; the caller closes
    /// it otherwise.
    ic: *av.FormatContext,
};

/// Inspects `path` once: how to deliver it, and which text subtitle streams it
/// carries. `gpa` owns the returned subtitle strings.
pub fn plan(gpa: std.mem.Allocator, path: []const u8) !Plan {
    const ic = try extra.openInput(gpa, path);
    errdefer ic.close_input();

    var video_codec: []const u8 = "";
    var audio_codec: []const u8 = "";
    var video_ok = true;
    var audio_ok = true;
    var have_video = false;
    var have_audio = false;
    var subs: std.ArrayList(SubtitleStream) = .empty;
    errdefer subs.deinit(gpa);

    for (ic.streams[0..ic.nb_streams], 0..) |st, i| {
        const par = st.codecpar;
        const name = extra.codecName(extra.codecId(par));
        switch (par.codec_type) {
            .VIDEO => if (!have_video) {
                have_video = true;
                video_codec = name;
                video_ok = support.videoSupport(name) != .transcode;
            },
            .AUDIO => if (!have_audio) {
                have_audio = true;
                audio_codec = name;
                audio_ok = support.audioSupport(name) == .direct;
            },
            .SUBTITLE => if (support.textIsSupported(name)) {
                try subs.append(gpa, .{
                    .index = i,
                    .language = try gpa.dupe(u8, extra.dictGet(st.metadata, "language") orelse "und"),
                    .title = try gpa.dupe(u8, extra.dictGet(st.metadata, "title") orelse ""),
                });
            },
            else => {},
        }
    }

    return .{
        .direct = video_ok and audio_ok,
        .video_unsupported = have_video and !video_ok,
        .duration = extra.durationSeconds(ic),
        .fps = extra.videoFps(ic),
        .video_codec = video_codec,
        .audio_codec = audio_codec,
        .subtitles = try subs.toOwnedSlice(gpa),
        .ic = ic,
    };
}

/// Demuxes the subtitle streams `indices` from `path` in one pass (their
/// packets are interleaved) and returns each as WebVTT, in the same order.
/// Callers do this lazily, when the receiver first requests a track.
pub fn extractSubtitles(gpa: std.mem.Allocator, path: []const u8, indices: []const usize) ![]const []u8 {
    const ic = try extra.openInput(gpa, path);
    defer ic.close_input();
    for (indices) |i| if (i >= ic.nb_streams) return error.NoSuchStream;
    extra.discardOthers(ic, indices);

    const outs = try gpa.alloc(std.ArrayList(u8), indices.len);
    defer gpa.free(outs);
    @memset(outs, .empty);
    errdefer for (outs) |*out| out.deinit(gpa);
    for (outs) |*out| try webvtt.writeVttHeader(gpa, out);

    const pkt = try av.Packet.alloc();
    defer pkt.free();
    while (true) {
        ic.read_frame(pkt) catch |err| switch (err) {
            error.EndOfFile => break,
            else => return err,
        };
        defer pkt.unref();
        if (pkt.pts == av.NOPTS_VALUE) continue;
        const slot = std.mem.findScalar(usize, indices, @intCast(pkt.stream_index)) orelse continue;

        const st = ic.streams[@intCast(pkt.stream_index)];
        const codec = extra.codecName(extra.codecId(st.codecpar));
        const start_ms = extra.av_rescale_q(pkt.pts, st.time_base, extra.millis);
        const end_ms = if (pkt.duration > 0) extra.av_rescale_q(pkt.pts + pkt.duration, st.time_base, extra.millis) else start_ms + 2000;
        try webvtt.writeVttCue(gpa, &outs[slot], start_ms, end_ms, codec, pkt.data[0..@intCast(pkt.size)]);
    }

    const result = try gpa.alloc([]u8, indices.len);
    errdefer gpa.free(result);
    for (outs, 0..) |*out, i| result[i] = try out.toOwnedSlice(gpa);
    return result;
}

// --- AVIO bridge ------------------------------------------------------------

const Sink = struct {
    w: *Io.Writer,
    failed: bool = false,

    const Avio = extra.WriteAvio(Sink, write);

    fn write(sink: *Sink, bytes: []const u8) !void {
        try sink.w.writeAll(bytes);
    }
};

// --- codecs -----------------------------------------------------------------

pub fn openDecoder(par: *av.Codec.Parameters) !*av.Codec.Context {
    const codec = try av.Codec.find_decoder(par.codec_id);
    const dec = try av.Codec.Context.alloc(codec);
    errdefer dec.free();
    try dec.parameters_to_context(par);
    try dec.open(codec, null);
    return dec;
}

/// An AAC encoder at the decoder's sample rate. Stereo, since many receivers
/// reject multichannel AAC in an HLS stream. Shared by the remux `Output` and
/// the on-the-fly MP4 assembler so their parameters never diverge.
pub fn openStereoAacEncoder(dec: *const av.Codec.Context) !*av.Codec.Context {
    const codec = try av.Codec.find_encoder_by_name("aac");
    const enc = try av.Codec.Context.alloc(codec);
    errdefer enc.free();
    enc.sample_rate = dec.sample_rate;
    extra.av_channel_layout_default(&enc.ch_layout, 2);
    enc.sample_fmt = .FLTP;
    enc.bit_rate = aac_bitrate;
    enc.time_base = .{ .num = 1, .den = dec.sample_rate };
    enc.flags |= extra.CODEC_FLAG_GLOBAL_HEADER;
    try enc.open(codec, null);
    std.debug.assert(enc.frame_size > 0); // AAC frames are 1024 samples
    return enc;
}

// --- input ------------------------------------------------------------------

/// A demuxer and its audio decoder, reusable across windows: each window
/// seeks the demuxer and flushes the decoder.
pub const Input = struct {
    gpa: std.mem.Allocator,
    ic: *av.FormatContext,
    video_index: ?usize,
    audio_index: usize,
    dec: *av.Codec.Context,

    pub fn open(gpa: std.mem.Allocator, path: []const u8) !*Input {
        const ic = try extra.openInput(gpa, path);
        errdefer ic.close_input();
        return adopt(gpa, ic);
    }

    /// Takes ownership of an already probed `ic`.
    pub fn adopt(gpa: std.mem.Allocator, ic: *av.FormatContext) !*Input {
        const video_index: ?usize = if (ic.find_best_stream(.VIDEO, -1, -1)) |v| @intCast(v[0]) else |_| null;
        const audio_index: usize = if (ic.find_best_stream(.AUDIO, -1, -1)) |a| @intCast(a[0]) else |_| return error.NoAudioStream;
        if (video_index) |vi| extra.discardOthers(ic, &.{ vi, audio_index }) else extra.discardOthers(ic, &.{audio_index});

        const dec = try openDecoder(ic.streams[audio_index].codecpar);
        errdefer dec.free();

        const in = try gpa.create(Input);
        in.* = .{ .gpa = gpa, .ic = ic, .video_index = video_index, .audio_index = audio_index, .dec = dec };
        return in;
    }

    pub fn deinit(in: *Input) void {
        in.dec.free();
        in.ic.close_input();
        in.gpa.destroy(in);
    }
};

// --- output -----------------------------------------------------------------

/// The output container of a remux, and what each one needs from the muxer.
pub const Container = enum {
    /// MPEG-TS, for HLS segments: copied H.264/HEVC goes through the Annex-B
    /// bitstream filter (start codes, in-band SPS/PPS).
    mpegts,
    /// Fragmented MP4 live stream: init is ftyp+moov, each fragment is
    /// moof+mdat, timestamps kept absolute.
    fmp4,

    fn muxerName(c: Container) [*:0]const u8 {
        return switch (c) {
            .mpegts => "mpegts",
            .fmp4 => "mp4",
        };
    }

    fn annexb(c: Container) bool {
        return c == .mpegts;
    }

    fn movflags(c: Container) ?[*:0]const u8 {
        return switch (c) {
            .mpegts => null,
            .fmp4 => "frag_keyframe+empty_moov+default_base_moof",
        };
    }

    fn keepAbsoluteTs(c: Container) bool {
        return c == .fmp4;
    }
};

/// Copied video, when the source has any.
const VideoCopy = struct {
    in_index: usize,
    out_index: c_int,
    /// Annex-B filter for MPEG-TS; null when the container takes AVCC as is.
    bsf: ?*extra.BSFContext,

    fn deinit(v: *VideoCopy) void {
        if (v.bsf) |b| {
            var bb: ?*extra.BSFContext = b;
            extra.av_bsf_free(&bb);
        }
    }
};

/// One window's muxer, AAC encoder and sink.
const Output = struct {
    sink: *Sink,
    enc: *av.Codec.Context,
    oc: *av.FormatContext,
    avio: *av.IOContext,
    video: ?VideoCopy,
    out_audio_index: c_int,

    fn open(in: *const Input, container: Container, sink: *Sink) !Output {
        const enc = try openStereoAacEncoder(in.dec);
        errdefer enc.free();

        const oc = try extra.allocOutputContext(container.muxerName());
        errdefer av.avformat_free_context(oc);

        const avio = try Sink.Avio.alloc(sink, null);
        errdefer av.IOContext.free(avio);
        oc.pb = avio;

        var video: ?VideoCopy = null;
        errdefer if (video) |*v| v.deinit();
        if (in.video_index) |vi| {
            const in_video = in.ic.streams[vi];
            var bsf: ?*extra.BSFContext = null;
            const vcodec = extra.codecName(extra.codecId(in_video.codecpar));
            if (container.annexb()) if (extra.annexbFilterName(vcodec)) |filter_name| {
                const filter = extra.av_bsf_get_by_name(filter_name) orelse return error.BsfNotFound;
                var ctx: ?*extra.BSFContext = null;
                _ = try av.wrap(extra.av_bsf_alloc(filter, &ctx));
                const b = ctx.?;
                try extra.copyParameters(b.par_in, in_video.codecpar);
                b.time_base_in = in_video.time_base;
                _ = try av.wrap(extra.av_bsf_init(b));
                bsf = b;
            };
            const par = if (bsf) |b| b.par_out else in_video.codecpar;
            const out_video = try extra.addCopiedStream(oc, par, in_video.time_base);
            video = .{ .in_index = vi, .out_index = out_video.index, .bsf = bsf };
        }

        const out_audio = try extra.addEncodedStream(oc, enc);

        return .{
            .sink = sink,
            .enc = enc,
            .oc = oc,
            .avio = avio,
            .video = video,
            .out_audio_index = out_audio.index,
        };
    }

    fn deinit(o: *Output) void {
        if (o.video) |*v| v.deinit();
        av.IOContext.free(o.avio);
        av.avformat_free_context(o.oc);
        o.enc.free();
    }

    fn writeHeader(o: *Output, container: Container) !void {
        if (container.keepAbsoluteTs()) o.oc.avoid_negative_ts = extra.AVFMT_AVOID_NEG_TS_DISABLED;
        var opts: av.Dictionary.Mutable = .empty;
        defer opts.free();
        if (container.movflags()) |f| try opts.set("movflags", f, .{});
        try extra.writeHeader(o.oc, &opts);
    }

    /// Copies video and transcodes audio for [start_time, end_time) into the
    /// already-headered output. `end_time` null runs to end of file.
    fn run(o: *Output, in: *Input, start_time: f64, end_time: ?f64) !void {
        try in.ic.seek_frame(-1, @intFromFloat(start_time * extra.TIME_BASE), extra.AVSEEK_FLAG_BACKWARD);
        in.dec.flush_buffers();

        const in_audio = in.ic.streams[in.audio_index];
        var mux: MuxEmit = .{ .oc = o.oc, .out_index = o.out_audio_index, .enc = o.enc, .sink = o.sink };
        var ctx = try AudioCtx.init(in.dec, o.enc, in_audio.time_base, start_time, MuxEmit.emit, &mux);
        defer ctx.deinit();

        const pkt = try av.Packet.alloc();
        defer pkt.free();
        const vpkt = try av.Packet.alloc();
        defer vpkt.free();

        while (true) {
            in.ic.read_frame(pkt) catch |err| switch (err) {
                error.EndOfFile => break,
                else => return err,
            };
            defer pkt.unref();
            if (o.sink.failed) return error.WriteFailed;

            if (o.video != null and pkt.stream_index == @as(c_int, @intCast(o.video.?.in_index))) {
                const v = o.video.?;
                const in_tb = in.ic.streams[v.in_index].time_base;
                const out_tb = o.oc.streams[@intCast(v.out_index)].time_base;
                if (end_time) |end| if (pkt.pts != av.NOPTS_VALUE and extra.toSeconds(pkt.pts, in_tb) >= end) break;
                if (v.bsf) |b| {
                    try extra.bsfSend(b, pkt);
                    while (true) {
                        extra.bsfReceive(b, vpkt) catch |err| switch (err) {
                            error.WouldBlock, error.EndOfFile => break,
                            else => return err,
                        };
                        extra.av_packet_rescale_ts(vpkt, in_tb, out_tb);
                        vpkt.stream_index = v.out_index;
                        try extra.writeFrame(o.oc, vpkt);
                        vpkt.unref();
                    }
                } else {
                    extra.av_packet_rescale_ts(pkt, in_tb, out_tb);
                    pkt.stream_index = v.out_index;
                    try extra.writeFrame(o.oc, pkt);
                }
            } else if (pkt.stream_index == @as(c_int, @intCast(in.audio_index))) {
                // Without video the audio timestamps bound the window.
                if (o.video == null) if (end_time) |end| if (pkt.pts != av.NOPTS_VALUE) {
                    if (extra.toSeconds(pkt.pts, in_audio.time_base) >= end) break;
                };
                try ctx.feed(pkt);
            }
        }

        try ctx.finish();
    }
};

// --- public entry points ----------------------------------------------------

/// Remuxes [start_time, end_time) of `in` into `container`, streamed to `w`
/// as a full container: header, body, trailer.
pub fn remuxWindow(in: *Input, start_time: f64, end_time: ?f64, container: Container, w: *Io.Writer) !void {
    var sink: Sink = .{ .w = w };
    var o = try Output.open(in, container, &sink);
    defer o.deinit();
    try o.writeHeader(container);
    try o.run(in, start_time, end_time);
    if (sink.failed) return error.WriteFailed;
    try extra.writeTrailer(o.oc);
}

/// `remuxWindow` over a freshly opened `path`; for one-off streams.
pub fn remuxFile(gpa: std.mem.Allocator, path: []const u8, container: Container, w: *Io.Writer) !void {
    const in = try Input.open(gpa, path);
    defer in.deinit();
    try remuxWindow(in, 0, null, container, w);
}

// --- audio transcoder -------------------------------------------------------

/// Where an `AudioCtx` sends each encoded AAC packet (in the encoder time_base).
pub const Emit = *const fn (ctx: *anyopaque, pkt: *av.Packet) anyerror!void;

/// Decodes the source audio, downmixes/resamples through a FIFO, and encodes
/// AAC. Each finished packet goes to `emit` — the remux `Output` muxes it, the
/// virtual-MP4 assembler stores it. Drive it with `feed` per packet, then
/// `finish`.
pub const AudioCtx = struct {
    dec: *av.Codec.Context,
    enc: *av.Codec.Context,
    swr: *av.swr.Context,
    fifo: *extra.AudioFifo,
    enc_frame: *av.Frame,
    out_packet: *av.Packet,
    dec_frame: *av.Frame,
    /// Resampler output, grown to the largest frame seen.
    converted: [8]?[*]u8 = @splat(null),
    converted_samples: c_int = 0,
    next_pts: i64,
    pts_set: bool = false,
    /// Timestamp of the first decoded sample (encoder time base); the origin
    /// every later pts counts from.
    first_pts: i64 = 0,
    /// Decoded samples to discard before encoding starts. The pts still
    /// advance over them, so the output stays where it would be in a full
    /// encode. Set before the first `feed`.
    skip_samples: i64 = 0,
    /// Only packets whose pts, counted from the first decoded sample, fall in
    /// [emit_lo, emit_hi) reach `emit`. Lets a slice of the audio be encoded
    /// with warm-up on both sides and only the slice kept.
    emit_lo: i64 = std.math.minInt(i64),
    emit_hi: i64 = std.math.maxInt(i64),
    in_time_base: av.Rational,
    emit: Emit,
    emit_ctx: *anyopaque,

    pub fn init(dec: *av.Codec.Context, enc: *av.Codec.Context, in_time_base: av.Rational, start_time: f64, emit: Emit, emit_ctx: *anyopaque) !AudioCtx {
        const swr = try av.swr.Context.alloc_set_opts(&enc.ch_layout, enc.sample_fmt, enc.sample_rate, &dec.ch_layout, dec.sample_fmt, dec.sample_rate, 0, null);
        errdefer swr.free();
        try swr.init();
        const fifo = extra.av_audio_fifo_alloc(enc.sample_fmt, enc.ch_layout.nb_channels, 1) orelse return error.OutOfMemory;
        errdefer extra.av_audio_fifo_free(fifo);
        const enc_frame = try av.Frame.alloc();
        errdefer enc_frame.free();
        const out_packet = try av.Packet.alloc();
        errdefer out_packet.free();
        const dec_frame = try av.Frame.alloc();
        errdefer dec_frame.free();
        return .{
            .dec = dec,
            .enc = enc,
            .swr = swr,
            .fifo = fifo,
            .enc_frame = enc_frame,
            .out_packet = out_packet,
            .dec_frame = dec_frame,
            .next_pts = @intFromFloat(start_time * @as(f64, @floatFromInt(dec.sample_rate))),
            .in_time_base = in_time_base,
            .emit = emit,
            .emit_ctx = emit_ctx,
        };
    }

    pub fn deinit(ctx: *AudioCtx) void {
        av.freep(@ptrCast(&ctx.converted[0]));
        ctx.swr.free();
        extra.av_audio_fifo_free(ctx.fifo);
        ctx.enc_frame.free();
        ctx.out_packet.free();
        ctx.dec_frame.free();
    }

    /// Samples consumed so far, counted from the first decoded one.
    pub fn consumed(ctx: *const AudioCtx) i64 {
        return ctx.next_pts - ctx.first_pts;
    }

    /// Decodes one audio packet, emitting any AAC packets it completes.
    pub fn feed(ctx: *AudioCtx, pkt: *av.Packet) !void {
        try ctx.dec.send_packet(pkt);
        try ctx.drain();
    }

    /// Flushes the decoder and encoder at end of stream.
    pub fn finish(ctx: *AudioCtx) !void {
        try ctx.dec.send_packet(null);
        try ctx.drain();
        try ctx.encodeFifo(true);
        try ctx.encodeFrame(null);
    }

    fn drain(ctx: *AudioCtx) !void {
        const frame = ctx.dec_frame;
        while (true) {
            ctx.dec.receive_frame(frame) catch |err| switch (err) {
                error.WouldBlock, error.EndOfFile => return,
                else => return err,
            };
            defer frame.unref();
            if (!ctx.pts_set) {
                // The encoder time base is 1/sample_rate, so this is a sample count.
                const ts = frame.best_effort_timestamp;
                if (ts != av.NOPTS_VALUE) ctx.next_pts = extra.av_rescale_q(ts, ctx.in_time_base, ctx.enc.time_base);
                ctx.first_pts = ctx.next_pts;
                ctx.pts_set = true;
            }
            try ctx.pushToFifo(frame);
            if (ctx.skip_samples > 0) {
                const drop: c_int = @intCast(@min(ctx.skip_samples, extra.av_audio_fifo_size(ctx.fifo)));
                if (extra.av_audio_fifo_drain(ctx.fifo, drop) < 0) return error.FifoRead;
                ctx.skip_samples -= drop;
                ctx.next_pts += drop;
            }
            try ctx.encodeFifo(false);
        }
    }

    fn pushToFifo(ctx: *AudioCtx, frame: *av.Frame) !void {
        const out_samples = extra.swr_get_out_samples(ctx.swr, frame.nb_samples);
        if (out_samples > ctx.converted_samples) {
            av.freep(@ptrCast(&ctx.converted[0]));
            ctx.converted_samples = 0;
            _ = try av.wrap(av.av_samples_alloc(&ctx.converted, null, ctx.enc.ch_layout.nb_channels, out_samples, ctx.enc.sample_fmt, 0));
            ctx.converted_samples = out_samples;
        }

        const in_ptr: [*]const [*]const u8 = @ptrCast(&frame.extended_data[0]);
        const out_ptr: [*]const [*]u8 = @ptrCast(&ctx.converted[0]);
        const n = try ctx.swr.convert(out_ptr, out_samples, in_ptr, frame.nb_samples);

        if (n > 0) {
            const data_ptr: [*]const ?*anyopaque = @ptrCast(&ctx.converted[0]);
            if (extra.av_audio_fifo_write(ctx.fifo, data_ptr, @intCast(n)) < 0) return error.FifoWrite;
        }
    }

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
            try ctx.encodeFrame(frame);
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
            const rel = ctx.out_packet.pts - ctx.first_pts;
            if (rel < ctx.emit_lo or rel >= ctx.emit_hi) continue;
            try ctx.emit(ctx.emit_ctx, ctx.out_packet);
        }
    }
};

/// Muxes each encoded AAC packet into `oc` (used by the remux `Output`).
const MuxEmit = struct {
    oc: *av.FormatContext,
    out_index: c_int,
    enc: *av.Codec.Context,
    sink: *Sink,

    fn emit(ectx: *anyopaque, pkt: *av.Packet) anyerror!void {
        const m: *MuxEmit = @ptrCast(@alignCast(ectx));
        pkt.stream_index = m.out_index;
        extra.av_packet_rescale_ts(pkt, m.enc.time_base, m.oc.streams[@intCast(m.out_index)].time_base);
        try extra.writeFrame(m.oc, pkt);
        if (m.sink.failed) return error.WriteFailed;
    }
};

test {
    std.testing.refAllDecls(@This());
}

// --- tests ------------------------------------------------------------------

/// Encodes a second of silence with `codec_name` into an MPEG-TS buffer.
/// MPEG-TS needs no seeking, so the muxer can write straight to memory.
fn synthesise(gpa: std.mem.Allocator, codec_name: [*:0]const u8) ![]u8 {
    const codec = try av.Codec.find_encoder_by_name(codec_name);
    const enc = try av.Codec.Context.alloc(codec);
    defer enc.free();
    enc.sample_rate = 48000;
    extra.av_channel_layout_default(&enc.ch_layout, 2);
    enc.sample_fmt = .FLTP;
    enc.bit_rate = 128_000;
    enc.time_base = .{ .num = 1, .den = 48000 };
    try enc.open(codec, null);

    var buffer: Io.Writer.Allocating = .init(gpa);
    errdefer buffer.deinit();
    var sink: Sink = .{ .w = &buffer.writer };

    const oc = try extra.allocOutputContext("mpegts");
    defer av.avformat_free_context(oc);
    const avio = try Sink.Avio.alloc(&sink, null);
    defer av.IOContext.free(avio);
    oc.pb = avio;
    _ = try extra.addEncodedStream(oc, enc);
    try extra.writeHeader(oc, null);

    const frame = try av.Frame.alloc();
    defer frame.free();
    const pkt = try av.Packet.alloc();
    defer pkt.free();

    const frame_size: c_int = if (enc.frame_size > 0) enc.frame_size else 1024;
    var pts: i64 = 0;
    while (pts < enc.sample_rate) : (pts += frame_size) {
        frame.unref();
        frame.nb_samples = frame_size;
        frame.format = .{ .sample = enc.sample_fmt };
        try extra.copyChannelLayout(&frame.ch_layout, &enc.ch_layout);
        frame.sample_rate = enc.sample_rate;
        try extra.frameGetBuffer(frame);
        for (0..@intCast(frame.ch_layout.nb_channels)) |ch| {
            const plane = frame.data[ch];
            @memset(plane[0..@intCast(frame.linesize[0])], 0);
        }
        frame.pts = pts;
        try extra.sendFrame(enc, frame);
        try drainEncoder(oc, enc, pkt);
    }
    try extra.sendFrame(enc, null);
    try drainEncoder(oc, enc, pkt);
    try extra.writeTrailer(oc);
    return buffer.toOwnedSlice();
}

fn drainEncoder(oc: *av.FormatContext, enc: *av.Codec.Context, pkt: *av.Packet) !void {
    while (true) {
        extra.receivePacket(enc, pkt) catch |err| switch (err) {
            error.WouldBlock, error.EndOfFile => return,
            else => return err,
        };
        defer pkt.unref();
        pkt.stream_index = 0;
        try extra.writeFrame(oc, pkt);
    }
}

/// Writes `bytes` into the test's temp directory and returns the path libav
/// should open, which is relative to the cwd the test runner inherits.
fn fixture(gpa: std.mem.Allocator, dir: *std.testing.TmpDir, name: []const u8, bytes: []const u8) ![]u8 {
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    return gpa.print(".zig-cache/tmp/{s}/{s}", .{ dir.sub_path, name });
}

test "plan: aac plays directly, ac3 has to be remuxed" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]struct { codec: [*:0]const u8, name: []const u8, direct: bool }{
        .{ .codec = "aac", .name = "direct.ts", .direct = true },
        .{ .codec = "ac3", .name = "remux.ts", .direct = false },
    }) |c| {
        const bytes = try synthesise(gpa, c.codec);
        defer gpa.free(bytes);
        const path = try fixture(gpa, &tmp, c.name, bytes);
        defer gpa.free(path);

        const p = try plan(gpa, path);
        defer p.ic.close_input();
        defer gpa.free(p.subtitles);

        try std.testing.expectEqualStrings(std.mem.span(c.codec), p.audio_codec);
        try std.testing.expectEqual(c.direct, p.direct);
        try std.testing.expect(!p.video_unsupported);
        try std.testing.expectEqual(@as(usize, 0), p.subtitles.len);
    }
}
