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
