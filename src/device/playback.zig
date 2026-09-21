//! What a device is doing, in words no protocol owns.
//!
//! Cast reports playback with its own vocabulary, and the next protocol will
//! report it with a different one. Everything above `device/` speaks this
//! instead, so a second protocol reaches neither `session`, `control` nor a
//! front end.

const std = @import("std");

/// What the device is doing right now.
pub const State = enum { idle, playing, paused, buffering, unknown };

/// Why an item stopped for good. Only a terminal state carries one.
pub const EndReason = enum { finished, cancelled, failed, unknown };

/// One snapshot of playback.
pub const Playback = struct {
    state: State = .unknown,
    position: f64 = 0,
    /// The item's length in seconds, when the device knows it.
    duration: ?f64 = null,
    rate: f64 = 1,
    /// Set only once the item has stopped and will not resume. A device that
    /// merely paused, buffered or was interrupted by a seek has none.
    ended: ?EndReason = null,

    /// True only for terminal states.
    pub fn isFinished(p: Playback) bool {
        return p.ended != null;
    }
};

/// A side-loaded subtitle track offered to the device.
pub const TextTrack = struct {
    id: u32,
    /// URL the device fetches the track from.
    url: []const u8,
    language: []const u8 = "und",
    /// Shown in the device's subtitle menu, where it has one.
    name: []const u8 = "Subtitles",
};

/// What a device is told to play.
pub const LoadRequest = struct {
    url: []const u8,
    content_type: []const u8,
    title: ?[]const u8 = null,
    /// Total length in seconds, for the device's progress bar.
    duration: ?f64 = null,
    /// Sidecar subtitle tracks, each reachable by the device.
    text_tracks: []const TextTrack = &.{},
    /// Which track ids start enabled; empty means subtitles off.
    active_track_ids: []const u32 = &.{},
    /// True when the URL is an HLS playlist with MPEG-TS segments.
    hls: bool = false,
};

test {
    std.testing.refAllDecls(@This());
}
