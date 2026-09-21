//! What a device needs of the bytes we serve it, as opposed to which
//! codecs it can decode.
//!
//! `media/support.zig` answers "will it play this codec". This answers the
//! rest: which deliveries it can take, how a subtitle reaches it, and what
//! a response has to say about itself before the device will seek in it.
//! Both are facts about a device, and carrying them as a value is what
//! keeps the serving and window code from testing which protocol it is and
//! writing the answer out by hand.
//!
//! Everything here is settled by the protocol alone, so it is known before
//! anything connects. What only the device itself can say stays in
//! `support.Profile`, which is widened once it has been asked.

const std = @import("std");

const didl = @import("dlna/didl.zig");
const discovery = @import("discovery.zig");
const playback = @import("playback.zig");

pub const Traits = struct {
    /// Whether it plays an HLS playlist. It is the delivery that starts
    /// soonest and seeks, so it is what `auto` reaches for where it works.
    plays_hls: bool,
    /// Whether it plays at a speed other than 1.
    variable_rate: bool,
    /// The format a side-loaded subtitle is served in.
    subtitle_format: playback.TextTrack.Format,
    /// Whether the text tracks inside the file can be offered to it as a
    /// menu of its own, each on its own route.
    subtitle_menu: bool,
    /// Whether what it plays is settled by asking it. Where it is, the
    /// asking has to happen before the delivery is chosen.
    profile_is_claimed: bool,
    /// `contentFeatures.dlna.org`, one string per kind of response. Null
    /// where the header means nothing to the device.
    features: ?Features = null,

    pub const Features = struct {
        /// A body with a length, which Range can seek within.
        seekable: []const u8,
        /// A body with no length to range over.
        whole: []const u8,
    };

    /// A Cast receiver. It reads WebVTT and nothing else, and every
    /// receiver answers the same, so there is nothing to ask it.
    pub const cast: Traits = .{
        .plays_hls = true,
        .variable_rate = true,
        .subtitle_format = .vtt,
        .subtitle_menu = true,
        .profile_is_claimed = false,
    };

    /// A UPnP AV renderer. The conventions for side-loading a subtitle all
    /// assume SubRip, and UPnP AV has no verb for choosing a track, so the
    /// ones inside the file are the renderer's own business.
    pub const dlna: Traits = .{
        .plays_hls = false,
        .variable_rate = false,
        .subtitle_format = .srt,
        .subtitle_menu = false,
        .profile_is_claimed = true,
        .features = .{
            .seekable = didl.contentFeatures(true),
            .whole = didl.contentFeatures(false),
        },
    };

    pub fn of(protocol: discovery.Protocol) Traits {
        return switch (protocol) {
            .cast => Traits.cast,
            .dlna => Traits.dlna,
        };
    }

    /// What a response of this kind must say about itself, or null when
    /// the device does not read such a thing.
    pub fn featuresFor(t: Traits, seekable: bool) ?[]const u8 {
        const f = t.features orelse return null;
        return if (seekable) f.seekable else f.whole;
    }
};

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "a protocol settles its traits" {
    try testing.expectEqual(Traits.cast, Traits.of(.cast));
    try testing.expectEqual(Traits.dlna, Traits.of(.dlna));

    // The header a renderer reads must agree with the `res@protocolInfo`
    // the same file is announced with.
    try testing.expectEqualStrings(didl.contentFeatures(true), Traits.dlna.featuresFor(true).?);
    try testing.expectEqualStrings(didl.contentFeatures(false), Traits.dlna.featuresFor(false).?);
    // A receiver ignores it, so it is left off entirely.
    try testing.expectEqual(@as(?[]const u8, null), Traits.cast.featuresFor(true));
}
