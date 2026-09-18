//! Declarations that the `av` bindings module of the ffmpeg package does not
//! expose yet. They follow the same `pub extern fn` pattern as `av.zig` and
//! resolve against the ffmpeg library the module links.
//!
//! Rule: never depend on the numeric values of `av.Codec.ID`. The bindings
//! are written for ffmpeg 8.1 and ffmpeg 9 renumbered the video ids (AV1 is
//! 225 in 8.1 and 222 in 9.0). With `-fsys=ffmpeg` an enum compare would be
//! wrong and an unknown value would trip Zig's enum safety checks, so codecs
//! are identified by name (`avcodec_get_name`, `avcodec_find_encoder_by_name`)
//! and ids are read as raw integers.
//!
//! Planned additions, in the order the pipeline will need them:
//!
//! Muxing (libavformat):
//!   avformat_alloc_output_context2, avformat_new_stream,
//!   avformat_write_header, av_interleaved_write_frame, av_write_trailer,
//!   avformat_free_context, avcodec_parameters_copy
//!
//! Encoding (libavcodec):
//!   avcodec_find_encoder_by_name, avcodec_send_frame, avcodec_receive_packet,
//!   av_packet_rescale_ts
//!
//! Each addition should come with a small wrapper returning `av.Error`
//! through `av.wrap`, mirroring the style of the upstream bindings.

const std = @import("std");
const av = @import("av");

/// Raw `AVCodecID`, see the rule above.
pub const CodecId = c_uint;

/// Short codec name such as "h264" or "dts". Never null; unknown ids yield "unknown_codec".
pub extern fn avcodec_get_name(id: CodecId) [*:0]const u8;

/// Media type name such as "video". Null for `MediaType.UNKNOWN`.
pub extern fn av_get_media_type_string(media_type: av.MediaType) ?[*:0]const u8;

/// Reads the codec id of a stream without materialising it as `av.Codec.ID`.
pub fn codecId(par: *const av.Codec.Parameters) CodecId {
    const raw: *const CodecId = @ptrCast(&par.codec_id);
    return raw.*;
}

pub fn codecName(id: CodecId) []const u8 {
    return std.mem.span(avcodec_get_name(id));
}

pub fn mediaTypeName(media_type: av.MediaType) []const u8 {
    return if (av_get_media_type_string(media_type)) |s| std.mem.span(s) else "unknown";
}

test "codec ids resolve to names" {
    // H264 has kept the value 27 in every ffmpeg release. Unknown ids are not
    // probed here: debug builds of libavcodec assert on them.
    try std.testing.expectEqualStrings("h264", codecName(27));
}

// --- muxing (libavformat) --------------------------------------------------

pub extern fn avformat_alloc_output_context2(ctx: *?*av.FormatContext, oformat: ?*const av.OutputFormat, format_name: ?[*:0]const u8, filename: ?[*:0]const u8) c_int;
pub extern fn avformat_new_stream(s: *av.FormatContext, c: ?*const av.Codec) ?*av.Stream;
pub extern fn avformat_write_header(s: *av.FormatContext, options: ?*av.Dictionary.Mutable) c_int;
pub extern fn av_interleaved_write_frame(s: *av.FormatContext, pkt: ?*av.Packet) c_int;
pub extern fn av_write_trailer(s: *av.FormatContext) c_int;
pub extern fn avcodec_parameters_copy(dst: *av.Codec.Parameters, src: *const av.Codec.Parameters) c_int;

// --- encoding (libavcodec) -------------------------------------------------

pub extern fn avcodec_parameters_from_context(par: *av.Codec.Parameters, codec: *const av.Codec.Context) c_int;
pub extern fn avcodec_send_frame(avctx: *av.Codec.Context, frame: ?*const av.Frame) c_int;
pub extern fn avcodec_receive_packet(avctx: *av.Codec.Context, avpkt: *av.Packet) c_int;
pub extern fn av_packet_rescale_ts(pkt: *av.Packet, tb_src: av.Rational, tb_dst: av.Rational) void;

// --- util ------------------------------------------------------------------

pub extern fn av_channel_layout_copy(dst: *av.ChannelLayout, src: *const av.ChannelLayout) c_int;
pub extern fn av_frame_get_buffer(frame: *av.Frame, alignment: c_int) c_int;

// --- audio fifo (libavutil) ------------------------------------------------

pub const AudioFifo = opaque {};
pub extern fn av_audio_fifo_alloc(sample_fmt: av.SampleFormat, channels: c_int, nb_samples: c_int) ?*AudioFifo;
pub extern fn av_audio_fifo_free(af: *AudioFifo) void;
pub extern fn av_audio_fifo_write(af: *AudioFifo, data: [*]const ?*anyopaque, nb_samples: c_int) c_int;
pub extern fn av_audio_fifo_read(af: *AudioFifo, data: [*]const ?*anyopaque, nb_samples: c_int) c_int;
pub extern fn av_audio_fifo_size(af: *AudioFifo) c_int;

// --- wrappers, returning av.Error through av.wrap --------------------------

/// MP4 muxer sets AVFMT_GLOBALHEADER; the AAC encoder must know so it puts the
/// AudioSpecificConfig in the container instead of in the stream.
pub const CODEC_FLAG_GLOBAL_HEADER: c_int = 1 << 22;

pub fn allocOutputContext(format_name: [*:0]const u8) av.Error!*av.FormatContext {
    var oc: ?*av.FormatContext = null;
    _ = try av.wrap(avformat_alloc_output_context2(&oc, null, format_name, null));
    return oc.?;
}

pub fn newStream(oc: *av.FormatContext) error{OutOfMemory}!*av.Stream {
    return avformat_new_stream(oc, null) orelse error.OutOfMemory;
}

pub fn copyParameters(dst: *av.Codec.Parameters, src: *const av.Codec.Parameters) av.Error!void {
    _ = try av.wrap(avcodec_parameters_copy(dst, src));
}

pub fn parametersFromContext(par: *av.Codec.Parameters, cc: *const av.Codec.Context) av.Error!void {
    _ = try av.wrap(avcodec_parameters_from_context(par, cc));
}

pub fn writeHeader(oc: *av.FormatContext, options: ?*av.Dictionary.Mutable) av.Error!void {
    _ = try av.wrap(avformat_write_header(oc, options));
}

pub fn writeFrame(oc: *av.FormatContext, pkt: ?*av.Packet) av.Error!void {
    _ = try av.wrap(av_interleaved_write_frame(oc, pkt));
}

pub fn writeTrailer(oc: *av.FormatContext) av.Error!void {
    _ = try av.wrap(av_write_trailer(oc));
}

pub fn sendFrame(cc: *av.Codec.Context, frame: ?*const av.Frame) av.Error!void {
    _ = try av.wrap(avcodec_send_frame(cc, frame));
}

pub fn receivePacket(cc: *av.Codec.Context, pkt: *av.Packet) av.Error!void {
    _ = try av.wrap(avcodec_receive_packet(cc, pkt));
}

pub fn frameGetBuffer(frame: *av.Frame) av.Error!void {
    _ = try av.wrap(av_frame_get_buffer(frame, 0));
}

pub fn copyChannelLayout(dst: *av.ChannelLayout, src: *const av.ChannelLayout) av.Error!void {
    _ = try av.wrap(av_channel_layout_copy(dst, src));
}

// --- demuxer index (libavformat) -------------------------------------------

pub const AV_PKT_FLAG_KEY: c_int = 1;
pub const AVINDEX_KEYFRAME: c_int = 1;

/// AVIndexEntry. In C, `flags:2` and `size:30` are bitfields packed into one
/// 32-bit word; on little-endian x86-64 `flags` occupies the low two bits.
pub const IndexEntry = extern struct {
    pos: i64,
    timestamp: i64,
    flags_size: u32,
    min_distance: c_int,

    pub fn isKeyframe(e: *const IndexEntry) bool {
        return (e.flags_size & @as(u32, @intCast(AVINDEX_KEYFRAME))) != 0;
    }
};

pub extern fn avformat_index_get_entries_count(st: *const av.Stream) c_int;
pub extern fn avformat_index_get_entry(st: *av.Stream, idx: c_int) ?*const IndexEntry;

// --- bitstream filters (libavcodec) ----------------------------------------
//
// Copying H.264/HEVC from MP4/MKV (length-prefixed NALs, parameter sets in
// extradata) into MPEG-TS needs the `*_mp4toannexb` filter to emit start codes
// and repeat SPS/PPS in-band before each keyframe. The muxer API does not
// apply it automatically the way the ffmpeg CLI does.

pub const BSFContext = extern struct {
    av_class: ?*const anyopaque,
    filter: ?*const anyopaque,
    priv_data: ?*anyopaque,
    par_in: *av.Codec.Parameters,
    par_out: *av.Codec.Parameters,
    time_base_in: av.Rational,
    time_base_out: av.Rational,
};

pub extern fn av_bsf_get_by_name(name: [*:0]const u8) ?*const anyopaque;
pub extern fn av_bsf_alloc(filter: *const anyopaque, ctx: *?*BSFContext) c_int;
pub extern fn av_bsf_init(ctx: *BSFContext) c_int;
pub extern fn av_bsf_send_packet(ctx: *BSFContext, pkt: ?*av.Packet) c_int;
pub extern fn av_bsf_receive_packet(ctx: *BSFContext, pkt: *av.Packet) c_int;
pub extern fn av_bsf_free(ctx: *?*BSFContext) void;

/// The Annex-B filter for a codec, or null if none is needed.
pub fn annexbFilterName(codec: []const u8) ?[*:0]const u8 {
    if (std.mem.eql(u8, codec, "h264")) return "h264_mp4toannexb";
    if (std.mem.eql(u8, codec, "hevc")) return "hevc_mp4toannexb";
    return null;
}

pub fn bsfSend(ctx: *BSFContext, pkt: ?*av.Packet) av.Error!void {
    _ = try av.wrap(av_bsf_send_packet(ctx, pkt));
}

pub fn bsfReceive(ctx: *BSFContext, pkt: *av.Packet) av.Error!void {
    _ = try av.wrap(av_bsf_receive_packet(ctx, pkt));
}

// --- channel layout default (libavutil) ------------------------------------
pub extern fn av_channel_layout_default(ch_layout: *av.ChannelLayout, nb_channels: c_int) void;

// --- file output (libavformat) ---------------------------------------------
// For `--remux mp4`: transcode to a real, seekable MP4 on disk, which the
// receiver plays with native seek (via HTTP Range requests).
pub const AVIO_FLAG_WRITE: c_int = 2;
pub extern fn avio_open(pb: *?*av.IOContext, url: [*:0]const u8, flags: c_int) c_int;
pub extern fn avio_closep(pb: *?*av.IOContext) c_int;

pub fn avioOpen(url: [*:0]const u8) av.Error!*av.IOContext {
    var pb: ?*av.IOContext = null;
    _ = try av.wrap(avio_open(&pb, url, AVIO_FLAG_WRITE));
    return pb.?;
}
