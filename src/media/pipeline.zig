//! Decides how a file reaches the receiver, and remuxes a time window of it.
//!
//! `plan` inspects a file once:
//!   video playable + audio playable   -> serve the file directly (no remux)
//!   video playable + audio unplayable -> remux (copy video, audio to AAC)
//!   video unplayable                  -> caller falls back to direct; software
//!                                        video transcode is not implemented yet
//!
//! `remuxWindow(gpa, path, start, end, container, w)` transcodes the window
//! [start, end) into `container`, copying video and encoding audio to AAC,
//! written through a custom `av.IOContext` into an `std.Io.Writer` so nothing
//! hits disk. For MPEG-TS the copied H.264/HEVC is passed through the Annex-B
//! bitstream filter (in-band SPS/PPS). Audio is downmixed to stereo.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("../av_extra.zig");
const probe = @import("../probe.zig");
const subtitles = @import("subtitles.zig");

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
    video_codec: []const u8,
    audio_codec: []const u8,
    /// Text subtitle streams we can offer as WebVTT tracks (bitmap subs skipped).
    subtitles: []const SubtitleStream,
};

/// Inspects `path` once: how to deliver it, and which text subtitle streams it
/// carries. `gpa` owns the returned subtitle strings.
pub fn plan(gpa: std.mem.Allocator, path: []const u8) !Plan {
    const ic = try extra.openInput(gpa, path);
    defer ic.close_input();

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
                video_ok = probe.videoSupport(name) != .transcode;
            },
            .AUDIO => if (!have_audio) {
                have_audio = true;
                audio_codec = name;
                audio_ok = probe.audioSupport(name) == .direct;
            },
            .SUBTITLE => if (subtitles.textIsSupported(name)) {
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
        .video_codec = video_codec,
        .audio_codec = audio_codec,
        .subtitles = try subs.toOwnedSlice(gpa),
    };
}

/// Demuxes subtitle stream `stream_index` from `path` and returns it as WebVTT.
/// Reads the whole container (subtitle packets are interleaved), so callers
/// should do this lazily, only when the receiver requests the track.
pub fn extractSubtitle(gpa: std.mem.Allocator, path: []const u8, stream_index: usize) ![]u8 {
    const ic = try extra.openInput(gpa, path);
    defer ic.close_input();
    if (stream_index >= ic.nb_streams) return error.NoSuchStream;
    extra.discardOthers(ic, &.{stream_index});

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

        const start_ms = extra.av_rescale_q(pkt.pts, tb, extra.millis);
        const end_ms = if (pkt.duration > 0) extra.av_rescale_q(pkt.pts + pkt.duration, tb, extra.millis) else start_ms + 2000;
        const data = pkt.data[0..@intCast(pkt.size)];
        try subtitles.writeVttCue(gpa, &out, start_ms, end_ms, codec, data);
    }
    return out.toOwnedSlice(gpa);
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
    // Stereo: many receivers reject multichannel AAC in an HLS stream.
    extra.av_channel_layout_default(&enc.ch_layout, 2);
    enc.sample_fmt = .FLTP;
    enc.bit_rate = aac_bitrate;
    enc.time_base = .{ .num = 1, .den = dec.sample_rate };
    enc.flags |= extra.CODEC_FLAG_GLOBAL_HEADER;
    try enc.open(enc_codec, null);
    return .{ .dec = dec, .enc = enc };
}

// --- session ----------------------------------------------------------------

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

/// Everything libav needs to remux one file into one output, minus the header
/// write and the packet loop, which the callers drive differently. Output goes
/// to a streaming `Sink` (a custom AVIO writing to an `Io.Writer`).
const Session = struct {
    sink: *Sink,
    ic: *av.FormatContext,
    audio_index: usize,
    dec: *av.Codec.Context,
    enc: *av.Codec.Context,
    oc: *av.FormatContext,
    avio: *av.IOContext,
    video: ?VideoCopy,
    out_audio_index: c_int,

    fn open(gpa: std.mem.Allocator, path: []const u8, container: Container, sink: *Sink) !Session {
        const ic = try extra.openInput(gpa, path);
        errdefer ic.close_input();

        const video_index: ?usize = if (ic.find_best_stream(.VIDEO, -1, -1)) |v| @intCast(v[0]) else |_| null;
        const audio_index: usize = if (ic.find_best_stream(.AUDIO, -1, -1)) |a| @intCast(a[0]) else |_| return error.NoAudioStream;
        if (video_index) |vi| extra.discardOthers(ic, &.{ vi, audio_index }) else extra.discardOthers(ic, &.{audio_index});
        const in_audio = ic.streams[audio_index];

        const at = try openStereoAac(in_audio.codecpar);
        errdefer at.dec.free();
        errdefer at.enc.free();

        const oc = try extra.allocOutputContext(container.muxerName());
        errdefer av.avformat_free_context(oc);

        const avio = try Sink.Avio.alloc(sink, null);
        errdefer av.IOContext.free(avio);
        oc.pb = avio;

        var video: ?VideoCopy = null;
        errdefer if (video) |*v| v.deinit();
        if (video_index) |vi| {
            const in_video = ic.streams[vi];
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

        const out_audio = try extra.addEncodedStream(oc, at.enc);

        return .{
            .sink = sink,
            .ic = ic,
            .audio_index = audio_index,
            .dec = at.dec,
            .enc = at.enc,
            .oc = oc,
            .avio = avio,
            .video = video,
            .out_audio_index = out_audio.index,
        };
    }

    fn deinit(s: *Session) void {
        if (s.video) |*v| v.deinit();
        av.IOContext.free(s.avio);
        av.avformat_free_context(s.oc);
        s.enc.free();
        s.dec.free();
        s.ic.close_input();
    }

    fn writeHeader(s: *Session, container: Container) !void {
        if (container.keepAbsoluteTs()) s.oc.avoid_negative_ts = extra.AVFMT_AVOID_NEG_TS_DISABLED;
        var opts: av.Dictionary.Mutable = .empty;
        defer opts.free();
        if (container.movflags()) |f| try opts.set("movflags", f, .{});
        try extra.writeHeader(s.oc, &opts);
    }

    /// Copies video and transcodes audio for [start_time, end_time) into the
    /// already-headered output. `end_time` null runs to end of file.
    fn runWindow(s: *Session, start_time: f64, end_time: ?f64) !void {
        if (start_time > 0) try s.ic.seek_frame(-1, @intFromFloat(start_time * extra.TIME_BASE), extra.AVSEEK_FLAG_BACKWARD);

        const in_audio = s.ic.streams[s.audio_index];
        var mux: MuxEmit = .{ .oc = s.oc, .out_index = s.out_audio_index, .enc = s.enc, .sink = s.sink };
        var ctx = try AudioCtx.init(s.dec, s.enc, in_audio.time_base, start_time, MuxEmit.emit, &mux);
        defer ctx.deinit();

        const pkt = try av.Packet.alloc();
        defer pkt.free();
        const vpkt = try av.Packet.alloc();
        defer vpkt.free();

        while (true) {
            s.ic.read_frame(pkt) catch |err| switch (err) {
                error.EndOfFile => break,
                else => return err,
            };
            defer pkt.unref();
            if (s.sink.failed) return error.WriteFailed;

            if (s.video != null and pkt.stream_index == @as(c_int, @intCast(s.video.?.in_index))) {
                const v = s.video.?;
                const in_tb = s.ic.streams[v.in_index].time_base;
                const out_tb = s.oc.streams[@intCast(v.out_index)].time_base;
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
                        try extra.writeFrame(s.oc, vpkt);
                        vpkt.unref();
                    }
                } else {
                    extra.av_packet_rescale_ts(pkt, in_tb, out_tb);
                    pkt.stream_index = v.out_index;
                    try extra.writeFrame(s.oc, pkt);
                }
            } else if (pkt.stream_index == @as(c_int, @intCast(s.audio_index))) {
                // Without video the audio timestamps bound the window.
                if (s.video == null) if (end_time) |end| if (pkt.pts != av.NOPTS_VALUE) {
                    if (extra.toSeconds(pkt.pts, in_audio.time_base) >= end) break;
                };
                try ctx.feed(pkt);
            }
        }

        try ctx.finish();
    }
};

// --- public entry points ----------------------------------------------------

/// Generic remux of a window into `container` streamed to `w`. Writes a full
/// container: header, body, trailer. Used for MPEG-TS HLS segments, and for
/// the `--remux stream` fragmented-MP4 live stream.
pub fn remuxWindow(gpa: std.mem.Allocator, path: []const u8, start_time: f64, end_time: ?f64, container: Container, w: *Io.Writer) !void {
    var sink: Sink = .{ .w = w };
    var s = try Session.open(gpa, path, container, &sink);
    defer s.deinit();
    try s.writeHeader(container);
    try s.runWindow(start_time, end_time);
    if (sink.failed) return error.WriteFailed;
    try extra.writeTrailer(s.oc);
}

// --- audio transcoder -------------------------------------------------------

/// Where an `AudioCtx` sends each encoded AAC packet (in the encoder time_base).
pub const Emit = *const fn (ctx: *anyopaque, pkt: *av.Packet) anyerror!void;

/// Decodes the source audio, downmixes/resamples through a FIFO, and encodes
/// AAC. Each finished packet goes to `emit` — the remux `Session` muxes it, the
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
                ctx.pts_set = true;
            }
            try ctx.pushToFifo(frame);
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
            try ctx.emit(ctx.emit_ctx, ctx.out_packet);
        }
    }
};

/// Muxes each encoded AAC packet into `oc` (used by the remux `Session`).
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
