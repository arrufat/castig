//! Media server the receiver pulls from (planned).
//!
//! One `std.Io.net.Server` on a LAN address, one `std.http.Server` per
//! accepted connection. Routes:
//!   GET /media          the file as is, honouring Range (206 Partial Content)
//!   GET /media.mp4      live remux/transcode output, chunked, no Range;
//!                       `?t=<seconds>` restarts the pipeline at that position
//!   GET /sub.vtt        subtitles converted to WebVTT
//!
//! Cast receivers require CORS headers on media and subtitle responses
//! (`Access-Control-Allow-Origin: *`) and probe with HEAD first.
//!
//! Planned API:
//!   pub const Server = struct { pub fn start(io, gpa, source: Source) !Server; pub fn url(buf, route) []const u8; pub fn stop(); };

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
