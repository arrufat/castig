//! What a renderer says it can do, as opposed to what we hope.
//!
//! Two documents answer that, and neither is the device description the
//! renderer is found by: the AVTransport SCPD says which seek units and
//! play speeds its arguments admit, and ConnectionManager's
//! `GetProtocolInfo` lists the content types it will take. Both are read on
//! demand, because the one-shot verbs need neither, and a device that will
//! not answer keeps the conservative reading.

const std = @import("std");

const soap = @import("soap.zig");
const ssdp = @import("ssdp.zig");
const xml = @import("../xml.zig");

const log = std.log.scoped(.dlna);

/// An AVTransport SCPD runs to a few tens of kilobytes; this is room to spare.
const max_scpd = 512 * 1024;

/// What the device admits to in its SCPD, rather than what we hope.
pub const Caps = struct {
    rel_time_seek: bool = false,
    abs_time_seek: bool = false,
    /// Any speed other than 1 in `TransportPlaySpeed`. A renderer that
    /// declares no list at all plays at 1x only.
    speeds: bool = false,
};

/// Reads the SCPD at `url`. One GET, and it turns "seek silently does
/// nothing" into a refusal we can explain.
pub fn transport(arena: std.mem.Allocator, http: *std.http.Client, url: []const u8) Caps {
    if (url.len == 0) return .{};
    const body = soap.get(arena, http, url, max_scpd) catch return .{};
    return parseTransport(body);
}

/// The MIME types `service` says it accepts. One call, and it is the
/// difference between remuxing a file and handing it over whole.
pub fn sinks(arena: std.mem.Allocator, http: *std.http.Client, service: ?ssdp.Service) []const []const u8 {
    const manager = service orelse return &.{};
    const reply = soap.call(arena, http, manager.control_url, .{
        .service = manager.type,
        .name = "GetProtocolInfo",
    }) catch return &.{};
    const raw = xml.text(reply, "Sink") orelse return &.{};
    const sink = xml.unescape(arena, raw) catch return &.{};
    return parseSinks(arena, sink) catch &.{};
}

/// The seek units and play speeds an AVTransport SCPD admits to.
pub fn parseTransport(scpd: []const u8) Caps {
    var caps: Caps = .{};
    const table = xml.text(scpd, "serviceStateTable") orelse return caps;

    var variables: xml.Scanner = .init(table);
    while (variables.next()) |variable| {
        if (!variable.is("stateVariable")) continue;
        const name = xml.text(variable.body, "name") orelse continue;
        const allowed = xml.text(variable.body, "allowedValueList") orelse continue;

        var values: xml.Scanner = .init(allowed);
        while (values.next()) |value| {
            if (!value.is("allowedValue")) continue;
            if (std.mem.eql(u8, name, "A_ARG_TYPE_SeekMode")) {
                if (std.mem.eql(u8, value.body, "REL_TIME")) caps.rel_time_seek = true;
                if (std.mem.eql(u8, value.body, "ABS_TIME")) caps.abs_time_seek = true;
            } else if (std.mem.eql(u8, name, "TransportPlaySpeed")) {
                if (!std.mem.eql(u8, std.mem.trim(u8, value.body, " "), "1")) caps.speeds = true;
            }
        }
    }
    return caps;
}

/// A sink list is comma separated `protocol:network:mime:extras`, and the
/// MIME is the only field worth keeping.
pub fn parseSinks(arena: std.mem.Allocator, sink: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var entries = std.mem.splitScalar(u8, sink, ',');
    while (entries.next()) |entry| {
        var fields = std.mem.splitScalar(u8, std.mem.trim(u8, entry, " \t\r\n"), ':');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const mime = fields.next() orelse continue;
        if (mime.len > 0) try out.append(arena, mime);
    }
    return out.toOwnedSlice(arena);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "capabilities come from the scpd, not from hope" {
    const scpd =
        \\<scpd><serviceStateTable>
        \\<stateVariable><name>A_ARG_TYPE_SeekMode</name>
        \\<allowedValueList><allowedValue>TRACK_NR</allowedValue>
        \\<allowedValue>REL_TIME</allowedValue><allowedValue>ABS_TIME</allowedValue>
        \\<allowedValue>X_DLNA_REL_BYTE</allowedValue></allowedValueList></stateVariable>
        \\<stateVariable><name>TransportPlaySpeed</name>
        \\<allowedValueList><allowedValue>1</allowedValue></allowedValueList></stateVariable>
        \\</serviceStateTable></scpd>
    ;
    const caps = parseTransport(scpd);
    try testing.expect(caps.rel_time_seek);
    try testing.expect(caps.abs_time_seek);
    // A list holding only "1" is not support for another speed.
    try testing.expect(!caps.speeds);

    // Rygel declares TransportPlaySpeed with no list at all, which means 1x.
    const bare = "<scpd><serviceStateTable><stateVariable><name>TransportPlaySpeed</name>" ++
        "<dataType>string</dataType></stateVariable></serviceStateTable></scpd>";
    try testing.expect(!parseTransport(bare).speeds);

    // Nothing to read is nothing claimed.
    try testing.expectEqual(Caps{}, parseTransport(""));
    try testing.expectEqual(Caps{}, parseTransport("<scpd></scpd>"));
}

test "the sink list names types, not codecs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Rygel's shape: `protocol:network:mime:extras`, comma separated.
    const list = "http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_BL_L3_SD_AAC," ++
        "http-get:*:audio/x-ac3:*, http-get:*:video/x-matroska:*";
    const types = try parseSinks(arena.allocator(), list);
    try testing.expectEqual(@as(usize, 3), types.len);
    try testing.expectEqualStrings("video/mp4", types[0]);
    // The space after a comma is not part of the next entry.
    try testing.expectEqualStrings("audio/x-ac3", types[1]);
    try testing.expectEqualStrings("video/x-matroska", types[2]);

    // A device that answers with nothing has claimed nothing.
    try testing.expectEqual(@as(usize, 0), (try parseSinks(arena.allocator(), "")).len);
    // Too few fields to name a type is not a type.
    try testing.expectEqual(@as(usize, 0), (try parseSinks(arena.allocator(), "http-get:*")).len);
}
