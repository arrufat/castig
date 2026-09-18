//! Decides how a file reaches the receiver and drives libav to do it (planned).
//!
//! Input is the probe verdict (see `probe.zig`):
//!   video direct + audio direct        -> serve the file directly
//!   video direct + audio transcode     -> remux to fragmented MP4, copy video,
//!                                         decode audio and encode AAC
//!   video transcode                    -> software H.264 encode, same muxer
//!
//! Output is written through a custom `av.IOContext` whose write callback
//! feeds the HTTP response, so nothing touches the disk. The muxer uses
//! `movflags=frag_keyframe+empty_moov+default_base_moof` so playback can
//! start before the end is known. Seeking is done in-process: `seek_frame`
//! on the demuxer, then the muxer is restarted for the new response.
//!
//! Text subtitle tracks are decoded and re-encoded as WebVTT by a separate
//! demux pass over the same file.
//!
//! Externs still missing from the `av` module live in `av_extra.zig`.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
