//! Cast v2 control channel (planned).
//!
//! Connect a `std.Io.net.Stream` to <device>:8009 and wrap it in
//! `std.crypto.tls.Client` with `.host = .no_verification` and
//! `.ca = .no_verification` (receivers present a self-signed certificate;
//! all devices seen so far negotiate TLS 1.3). `entropy` comes from
//! `Io.randomSecure`, `realtime_now` from `Io.Clock.real.now(io)`.
//!
//! Namespaces:
//!   urn:x-cast:com.google.cast.tp.connection   CONNECT / CLOSE
//!   urn:x-cast:com.google.cast.tp.heartbeat    PING every 5 s, answer PONG
//!   urn:x-cast:com.google.cast.receiver        LAUNCH appId "CC1AD845", GET_STATUS, STOP
//!   urn:x-cast:com.google.cast.media           LOAD, PLAY, PAUSE, SEEK, STOP, GET_STATUS
//!
//! Every request carries an incrementing `requestId`; the receiver's
//! `MEDIA_STATUS` and `RECEIVER_STATUS` messages are matched on it.
//! After LAUNCH, media messages go to the app's `transportId`, and a second
//! CONNECT must be sent to that id first.
//!
//! Planned API:
//!   pub const Channel = struct { pub fn connect(io, gpa, address) !Channel; pub fn launchDefaultReceiver(...); pub fn load(url, content_type, subtitles_url) !void; pub fn pause/play/seek/stop; pub fn poll() !?Event; };

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
