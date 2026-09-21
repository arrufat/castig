//! The DIDL-Lite metadata that rides along with `SetAVTransportURI`, the
//! DLNA flag strings that go with it, and the clock format UPnP states
//! times in.
//!
//! A renderer reads the metadata, not the URL, to decide whether it is
//! playing a film or a song (`upnp:class`), what to hand its decoder
//! (`res@protocolInfo`), whether it may seek (`DLNA.ORG_OP` inside that
//! same string) and what to draw on screen (`dc:title`). Sending an empty
//! `CurrentURIMetaData` is what makes a TV answer 714, or accept the URI
//! and then silently sit in STOPPED.

const std = @import("std");
const Io = std.Io;

const xml = @import("../xml.zig");

/// `DLNA.ORG_OP` is two flags: time-seek then byte-seek. We serve HTTP
/// Range and not `TimeSeekRange.dlna.org`, so byte-seek only, and `00`
/// where the body has no length to range over.
pub fn contentFeatures(seekable: bool) []const u8 {
    return if (seekable)
        "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
    else
        "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000";
}

/// `res@protocolInfo`, which must say the same thing as the
/// `contentFeatures.dlna.org` header on the response that serves it.
///
/// Deliberately no `DLNA.ORG_PN=`: naming the wrong profile is worse than
/// naming none, and we cannot know the right one for an arbitrary file.
pub fn protocolInfo(arena: std.mem.Allocator, content_type: []const u8, features: []const u8) ![]const u8 {
    return arena.print("http-get:*:{s}:{s}", .{ content_type, features });
}

/// The `upnp:class` for a content type.
pub fn upnpClass(content_type: []const u8) []const u8 {
    if (std.mem.startsWith(u8, content_type, "audio/")) return "object.item.audioItem.musicTrack";
    if (std.mem.startsWith(u8, content_type, "image/")) return "object.item.imageItem.photo";
    return "object.item.videoItem";
}

// --- clock times -------------------------------------------------------------

/// `H:MM:SS`, hours unpadded and no fraction. Some renderers reject a
/// fractional `Target` on a Seek even though they put one in `RelTime`.
pub fn clock(buf: *[16]u8, seconds: f64) []const u8 {
    const whole: u64 = @intFromFloat(@max(0, @floor(seconds)));
    return std.mem.print(buf, "{d}:{d:0>2}:{d:0>2}", .{
        whole / 3600,
        (whole % 3600) / 60,
        whole % 60,
    }) catch buf[0..0];
}

/// `H:MM:SS.mmm`, which is the form DIDL's `duration` attribute wants.
pub fn clockMillis(buf: *[24]u8, seconds: f64) []const u8 {
    const total_ms: u64 = @intFromFloat(@max(0, seconds) * 1000);
    const whole = total_ms / 1000;
    return std.mem.print(buf, "{d}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        whole / 3600,
        (whole % 3600) / 60,
        whole % 60,
        total_ms % 1000,
    }) catch buf[0..0];
}

/// Reads a UPnP time back. Renderers write `H:MM:SS`, `HH:MM:SS.mmm`, and
/// the literal `NOT_IMPLEMENTED` for a field they do not fill in.
pub fn parseClock(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "NOT_IMPLEMENTED")) return null;

    var seconds: f64 = 0;
    var parts = std.mem.splitScalar(u8, trimmed, ':');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (count == 3) return null;
        const v = std.fmt.parseFloat(f64, part) catch return null;
        if (v < 0) return null;
        seconds = seconds * 60 + v;
    }
    return seconds;
}

// --- the document ------------------------------------------------------------

pub const Item = struct {
    /// The URL the renderer will fetch.
    url: []const u8,
    content_type: []const u8,
    /// From `protocolInfo`, so it agrees with what the server will send.
    protocol_info: []const u8,
    title: []const u8,
    /// Gives the renderer a progress bar before it has parsed anything.
    duration: ?f64 = null,
};

const namespaces =
    "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"" ++
    " xmlns:dc=\"http://purl.org/dc/elements/1.1/\"" ++
    " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"" ++
    " xmlns:sec=\"http://www.sec.co.kr/\"" ++
    " xmlns:pv=\"http://www.pv.com/pvns/\">";

/// Writes the metadata, escaped once. The SOAP layer escapes it again on
/// the way into `CurrentURIMetaData`, so an `&` in a title reaches the wire
/// as `&amp;amp;`.
pub fn write(w: *Io.Writer, item: Item) Io.Writer.Error!void {
    try w.writeAll(namespaces);
    try w.writeAll("<item id=\"0\" parentID=\"-1\" restricted=\"1\">");

    try w.writeAll("<dc:title>");
    try xml.escape(w, item.title);
    try w.writeAll("</dc:title>");

    try w.print("<upnp:class>{s}</upnp:class>", .{upnpClass(item.content_type)});

    try w.writeAll("<res protocolInfo=\"");
    try xml.escape(w, item.protocol_info);
    try w.writeAll("\"");
    if (item.duration) |d| {
        var buf: [24]u8 = undefined;
        try w.print(" duration=\"{s}\"", .{clockMillis(&buf, d)});
    }
    try w.writeAll(">");
    try xml.escape(w, item.url);
    try w.writeAll("</res>");

    try w.writeAll("</item></DIDL-Lite>");
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "clock times" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0:00:00", clock(&buf, 0));
    try testing.expectEqualStrings("0:01:30", clock(&buf, 90));
    try testing.expectEqualStrings("1:02:03", clock(&buf, 3723));
    // No fraction, and rounded down, so a Target never lands past the end.
    try testing.expectEqualStrings("0:00:09", clock(&buf, 9.99));
    try testing.expectEqualStrings("0:00:00", clock(&buf, -5));
    try testing.expectEqualStrings("10:00:00", clock(&buf, 36000));

    var wide: [24]u8 = undefined;
    try testing.expectEqualStrings("0:09:56.000", clockMillis(&wide, 596));
    try testing.expectEqualStrings("0:00:01.500", clockMillis(&wide, 1.5));
}

test "clock times read back" {
    try testing.expectEqual(@as(?f64, 0), parseClock("0:00:00"));
    try testing.expectEqual(@as(?f64, 90), parseClock("0:01:30"));
    try testing.expectEqual(@as(?f64, 3723), parseClock("1:02:03"));
    try testing.expectEqual(@as(?f64, 3723), parseClock("01:02:03"));
    try testing.expectEqual(@as(?f64, 596.5), parseClock("0:09:56.500"));
    try testing.expectEqual(@as(?f64, 90), parseClock(" 0:01:30 "));
    // The two ways a renderer says "I am not telling you".
    try testing.expectEqual(@as(?f64, null), parseClock("NOT_IMPLEMENTED"));
    try testing.expectEqual(@as(?f64, null), parseClock(""));
    try testing.expectEqual(@as(?f64, null), parseClock("garbage"));
    try testing.expectEqual(@as(?f64, null), parseClock("1:2:3:4"));

    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(?f64, 3723), parseClock(clock(&buf, 3723)));
}

test "upnp classes" {
    try testing.expectEqualStrings("object.item.videoItem", upnpClass("video/mp4"));
    try testing.expectEqualStrings("object.item.audioItem.musicTrack", upnpClass("audio/mpeg"));
    try testing.expectEqualStrings("object.item.imageItem.photo", upnpClass("image/png"));
    // An unknown type is more likely a video than anything else.
    try testing.expectEqualStrings("object.item.videoItem", upnpClass("application/octet-stream"));
}

test "protocol info agrees with the response header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const features = contentFeatures(true);
    try testing.expectEqualStrings(
        "http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000",
        try protocolInfo(arena.allocator(), "video/mp4", features),
    );
    // Byte-seek is what Range gives us; a body with no length has neither.
    try testing.expect(std.mem.find(u8, contentFeatures(true), "DLNA.ORG_OP=01") != null);
    try testing.expect(std.mem.find(u8, contentFeatures(false), "DLNA.ORG_OP=00") != null);
    // Never time-seek: we do not answer TimeSeekRange.dlna.org.
    try testing.expect(std.mem.find(u8, contentFeatures(true), "DLNA.ORG_OP=10") == null);
}

test "the metadata a renderer needs" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{
        .url = "http://192.168.1.20:41234/media.mp4",
        .content_type = "video/mp4",
        .protocol_info = "http-get:*:video/mp4:DLNA.ORG_OP=01",
        .title = "Tom & Jerry",
        .duration = 596,
    });
    const didl = out.written();

    try testing.expect(std.mem.startsWith(u8, didl, "<DIDL-Lite xmlns="));
    try testing.expect(std.mem.find(u8, didl, "xmlns:sec=\"http://www.sec.co.kr/\"") != null);
    try testing.expect(std.mem.find(u8, didl, "<dc:title>Tom &amp; Jerry</dc:title>") != null);
    try testing.expect(std.mem.find(u8, didl, "<upnp:class>object.item.videoItem</upnp:class>") != null);
    try testing.expect(std.mem.find(u8, didl, "duration=\"0:09:56.000\"") != null);
    try testing.expect(std.mem.find(u8, didl, ">http://192.168.1.20:41234/media.mp4</res>") != null);
    try testing.expect(std.mem.endsWith(u8, didl, "</item></DIDL-Lite>"));
}

test "the metadata survives being an argument" {
    const gpa = testing.allocator;
    var meta: Io.Writer.Allocating = .init(gpa);
    defer meta.deinit();
    try write(&meta.writer, .{
        .url = "http://h/a.mp4?x=1&y=2",
        .content_type = "video/mp4",
        .protocol_info = "http-get:*:video/mp4:*",
        .title = "Q&A <live>",
    });

    // What the SOAP layer does to it on the way into CurrentURIMetaData.
    var argument: Io.Writer.Allocating = .init(gpa);
    defer argument.deinit();
    try xml.escape(&argument.writer, meta.written());
    // The document's own markup is escaped once on its way into the
    // argument; only its content, escaped when built, ends up doubled.
    try testing.expect(std.mem.find(u8, argument.written(), "&lt;DIDL-Lite") != null);
    try testing.expect(std.mem.find(u8, argument.written(), "Q&amp;amp;A") != null);

    // And what the renderer gets back after undoing one layer.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const once = try xml.unescape(arena.allocator(), argument.written());
    try testing.expectEqualStrings(meta.written(), once);
    try testing.expect(std.mem.find(u8, once, "<dc:title>Q&amp;A &lt;live&gt;</dc:title>") != null);
}
