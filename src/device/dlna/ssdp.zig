//! SSDP: find UPnP MediaRenderers with an M-SEARCH, then read each one's
//! device description for the services castig drives.
//!
//! Service types carry a version (`...:AVTransport:2` on everything current)
//! which is matched loosely and then kept verbatim, because `SOAPAction` and
//! the envelope's `xmlns:u` have to repeat exactly what the device said.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const sweep = @import("../sweep.zig");
const xml = @import("../xml.zig");
const version = @import("build_options").version;

const log = std.log.scoped(.dlna);

pub const group: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 239, 255, 255, 250 }, .port = 1900 } };

/// A device must answer a search for any version at or below its own, so
/// asking for :1 also reaches the :2 renderers every current device is.
pub const search_target = "urn:schemas-upnp-org:device:MediaRenderer:1";

/// Service types without their version suffix.
pub const av_transport = "urn:schemas-upnp-org:service:AVTransport";
pub const connection_manager = "urn:schemas-upnp-org:service:ConnectionManager";
pub const rendering_control = "urn:schemas-upnp-org:service:RenderingControl";

/// How many times the M-SEARCH goes out, and how far apart.
const attempts = 3;
const gap_ms = 250;
/// A device description is a couple of kilobytes; this is room to spare.
const max_description = 256 * 1024;

/// One service, as the description advertised it.
pub const Service = struct {
    /// Verbatim, version included: `SOAPAction` must repeat it.
    type: []const u8,
    /// Absolute, resolved against the description URL.
    control_url: []const u8,
    /// Absolute, or empty when the description omits it.
    scpd_url: []const u8 = "",
};

/// A renderer, as its description describes it.
pub const Description = struct {
    friendly_name: []const u8,
    manufacturer: []const u8 = "",
    model: []const u8 = "",
    udn: []const u8 = "",
    av_transport: Service,
    connection_manager: ?Service = null,
    rendering_control: ?Service = null,
};

/// Whether `advertised` names `kind`, whatever version it carries.
pub fn sameService(advertised: []const u8, kind: []const u8) bool {
    if (!std.mem.startsWith(u8, advertised, kind)) return false;
    const tail = advertised[kind.len..];
    if (tail.len == 0) return true;
    // Only a version suffix may follow, so `AVTransportFoo` does not match.
    if (tail[0] != ':' or tail.len == 1) return false;
    for (tail[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// "http://host:port" of a URL, without its path.
pub fn originOf(url: []const u8) ?[]const u8 {
    const scheme = std.mem.find(u8, url, "://") orelse return null;
    const slash = std.mem.findScalarPos(u8, url, scheme + 3, '/') orelse return url;
    return url[0..slash];
}

/// Resolves `ref` against `base`: an absolute URL as it is, a rooted path
/// onto the base's origin, anything else onto the base's directory.
pub fn resolveUrl(arena: std.mem.Allocator, base: []const u8, ref: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, ref, "http://") or std.mem.startsWith(u8, ref, "https://")) return ref;
    const origin = originOf(base) orelse return error.BadDescription;
    if (ref.len > 0 and ref[0] == '/') return std.mem.concat(arena, u8, &.{ origin, ref });

    const path = base[origin.len..];
    const cut = std.mem.findScalarLast(u8, path, '/') orelse return std.mem.concat(arena, u8, &.{ origin, "/", ref });
    return std.mem.concat(arena, u8, &.{ origin, path[0 .. cut + 1], ref });
}

/// The address a description URL points at, or `fallback` when its host is
/// not a literal address.
pub fn addressOf(location: []const u8, fallback: ?net.Ip4Address) ?net.Ip4Address {
    const origin = originOf(location) orelse return fallback;
    const scheme = std.mem.find(u8, origin, "://") orelse return fallback;
    const parsed = net.IpAddress.parseLiteral(origin[scheme + 3 ..]) catch return fallback;
    return switch (parsed) {
        .ip4 => |a| a,
        .ip6 => fallback,
    };
}

/// The value of one header of an M-SEARCH reply. Lines are split on LF and
/// the CR trimmed, since not every device sends both.
pub fn header(packet: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, packet, '\n');
    _ = lines.next(); // the status line
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// The unique device name of a `USN`, which is the part before `::`.
pub fn udnOf(usn: []const u8) []const u8 {
    const sep = std.mem.find(u8, usn, "::") orelse return usn;
    return usn[0..sep];
}

/// Writes the M-SEARCH into `buf`. `MAN` must be quoted and `MX` must not
/// exceed the round's own timeout, or answers arrive after we stop reading.
pub fn query(buf: []u8, mx: u32) ![]u8 {
    return std.mem.print(buf,
        "M-SEARCH * HTTP/1.1\r\n" ++
        "HOST: 239.255.255.250:1900\r\n" ++
        "MAN: \"ssdp:discover\"\r\n" ++
        "MX: {d}\r\n" ++
        "ST: " ++ search_target ++ "\r\n" ++
        "USER-AGENT: Linux/1.0 UPnP/1.0 castig/{s}\r\n" ++
        "\r\n", .{ mx, version });
}

/// The `<service>` of `kind` in a device's `<serviceList>`, with its URLs
/// made absolute against `base`.
fn serviceOf(arena: std.mem.Allocator, base: []const u8, device: []const u8, kind: []const u8) ?Service {
    const list = xml.text(device, "serviceList") orelse return null;
    var it: xml.Scanner = .init(list);
    while (it.next()) |service| {
        if (!service.is("service")) continue;
        const kind_advertised = xml.text(service.body, "serviceType") orelse continue;
        if (!sameService(kind_advertised, kind)) continue;
        const control = xml.text(service.body, "controlURL") orelse continue;
        return .{
            .type = kind_advertised,
            .control_url = resolveUrl(arena, base, control) catch continue,
            .scpd_url = if (xml.text(service.body, "SCPDURL")) |s|
                resolveUrl(arena, base, s) catch ""
            else
                "",
        };
    }
    return null;
}

/// The first `<device>` that drives AVTransport.
///
/// Descends through `<root>`, which wraps the top device, and through
/// `<deviceList>`, because a renderer is often nested under a root device
/// of some other type rather than being the root itself.
fn findRenderer(arena: std.mem.Allocator, base: []const u8, body: []const u8, depth: usize) ?[]const u8 {
    if (depth >= 8) return null;
    var it: xml.Scanner = .init(body);
    while (it.next()) |el| {
        const device = el.is("device");
        if (device and serviceOf(arena, base, el.body, av_transport) != null) return el.body;
        if (device or el.is("root") or el.is("deviceList")) {
            if (findRenderer(arena, base, el.body, depth + 1)) |found| return found;
        }
    }
    return null;
}

/// Reads a device description. `location` is where it came from, which is
/// what relative control URLs resolve against when there is no `URLBase`.
pub fn parseDescription(arena: std.mem.Allocator, location: []const u8, body: []const u8) !Description {
    const base = if (xml.text(body, "URLBase")) |b| std.mem.trim(u8, b, " \t\r\n") else location;
    const device = findRenderer(arena, base, body, 0) orelse return error.NotARenderer;
    const transport = serviceOf(arena, base, device, av_transport) orelse return error.NotARenderer;

    return .{
        .friendly_name = try unescaped(arena, xml.text(device, "friendlyName") orelse "?"),
        .manufacturer = try unescaped(arena, xml.text(device, "manufacturer") orelse ""),
        .model = try unescaped(arena, xml.text(device, "modelName") orelse ""),
        .udn = try arena.dupe(u8, xml.text(device, "UDN") orelse ""),
        .av_transport = transport,
        .connection_manager = serviceOf(arena, base, device, connection_manager),
        .rendering_control = serviceOf(arena, base, device, rendering_control),
    };
}

fn unescaped(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return xml.unescape(arena, std.mem.trim(u8, raw, " \t\r\n"));
}

/// Fetches and parses the description at `location`.
pub fn describe(arena: std.mem.Allocator, http: *std.http.Client, location: []const u8) !Description {
    var body: Io.Writer.Allocating = .init(arena);
    log.debug("GET {s}", .{location});
    const res = http.fetch(.{
        .location = .{ .url = location },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = "Linux/1.0 UPnP/1.0 castig/" ++ version } },
        .response_writer = &body.writer,
    }) catch |err| {
        log.debug("cannot read {s}: {s}", .{ location, @errorName(err) });
        return error.DescriptionUnreachable;
    };
    if (res.status != .ok) {
        log.debug("{s} answered {d}", .{ location, @backingInt(res.status) });
        return error.DescriptionUnreachable;
    }
    if (body.written().len > max_description) return error.DescriptionUnreachable;
    return parseDescription(arena, location, body.written());
}

/// A renderer that answered, with its description already read.
pub const Found = struct {
    /// The description URL, which is also how a user names this renderer.
    location: []const u8,
    address: net.Ip4Address,
    description: Description,
};

/// Everything the M-SEARCH turned up, arena allocated.
pub fn discover(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, timeout_ms: u32) ![]Found {
    var seen: Collector = .{ .arena = arena };

    var buf: [256]u8 = undefined;
    // MX bounds how long a device may wait before answering, so it has to
    // fit inside the round or the answers arrive after we stop reading.
    const mx = std.math.clamp(timeout_ms / 1000, 1, 3);
    const one = try query(&buf, mx);
    const queries: [attempts][]const u8 = @splat(one);

    try sweep.run(io, .{
        .group = group,
        .queries = &queries,
        .gap_ms = gap_ms,
        .timeout_ms = timeout_ms,
    }, &seen, Collector.take);

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var out: std.ArrayList(Found) = .empty;
    for (seen.locations.items, seen.sources.items) |location, from| {
        const description = describe(arena, &http, location) catch |err| {
            log.debug("skipping {s}: {s}", .{ location, @errorName(err) });
            continue;
        };
        try out.append(arena, .{
            .location = location,
            .address = addressOf(location, from) orelse continue,
            .description = description,
        });
    }
    return out.toOwnedSlice(arena);
}

/// The LOCATIONs that answered, one per device. A renderer answers each
/// repeat of the query, and often once per service it exports, so the UDN
/// is what makes it one entry.
const Collector = struct {
    arena: std.mem.Allocator,
    udns: std.ArrayList([]const u8) = .empty,
    locations: std.ArrayList([]const u8) = .empty,
    sources: std.ArrayList(?net.Ip4Address) = .empty,

    /// The packet points into the sweep's buffer, so anything kept is duped.
    fn take(c: *Collector, packet: []const u8, from: ?net.Ip4Address) anyerror!bool {
        const location = header(packet, "location") orelse return false;
        const udn = udnOf(header(packet, "usn") orelse "");
        for (c.udns.items) |known| if (std.mem.eql(u8, known, udn)) return false;

        try c.udns.append(c.arena, try c.arena.dupe(u8, udn));
        try c.locations.append(c.arena, try c.arena.dupe(u8, location));
        try c.sources.append(c.arena, from);
        // Others may still answer; the deadline ends the round.
        return false;
    }
};

test {
    std.testing.refAllDecls(@This());
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "service types match whatever version they carry" {
    try testing.expect(sameService("urn:schemas-upnp-org:service:AVTransport:2", av_transport));
    try testing.expect(sameService("urn:schemas-upnp-org:service:AVTransport:1", av_transport));
    try testing.expect(sameService("urn:schemas-upnp-org:service:AVTransport", av_transport));
    // A longer name that merely starts the same is a different service.
    try testing.expect(!sameService("urn:schemas-upnp-org:service:AVTransportFoo", av_transport));
    try testing.expect(!sameService("urn:schemas-upnp-org:service:ConnectionManager:2", av_transport));
    try testing.expect(!sameService("urn:schemas-upnp-org:service:AVTransport:", av_transport));
    try testing.expect(!sameService("urn:schemas-upnp-org:service:AVTransport:x", av_transport));
}

test "reply headers" {
    const packet = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\n" ++
        "LOCATION: http://192.168.1.50:9197/dmr.xml\r\n" ++
        "USN: uuid:abc-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";
    try testing.expectEqualStrings("http://192.168.1.50:9197/dmr.xml", header(packet, "location").?);
    // Header names are case-insensitive, and the value keeps its own colons.
    try testing.expectEqualStrings("max-age=1800", header(packet, "Cache-Control").?);
    try testing.expectEqual(@as(?[]const u8, null), header(packet, "server"));
    // The status line is not a header, whatever it looks like.
    try testing.expectEqual(@as(?[]const u8, null), header(packet, "HTTP/1.1 200 OK"));
    // Some devices send bare LF.
    try testing.expectEqualStrings("x", header("HTTP/1.1 200 OK\nST: x\n\n", "st").?);

    try testing.expectEqualStrings("uuid:abc-123", udnOf(header(packet, "usn").?));
    try testing.expectEqualStrings("uuid:solo", udnOf("uuid:solo"));
}

test "urls resolve against the description" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "http://192.168.1.37:42675/desc/device.xml";

    try testing.expectEqualStrings("http://192.168.1.37:42675", originOf(base).?);
    try testing.expectEqualStrings("http://h:1", originOf("http://h:1").?);

    try testing.expectEqualStrings("http://other/x", try resolveUrl(a, base, "http://other/x"));
    try testing.expectEqualStrings("http://192.168.1.37:42675/Control/AVT", try resolveUrl(a, base, "/Control/AVT"));
    try testing.expectEqualStrings("http://192.168.1.37:42675/desc/AVT", try resolveUrl(a, base, "AVT"));

    const addr = addressOf(base, null).?;
    try testing.expectEqual([4]u8{ 192, 168, 1, 37 }, addr.bytes);
    try testing.expectEqual(@as(u16, 42675), addr.port);
    // A hostname is not an address, so the datagram's sender stands in.
    const fallback: net.Ip4Address = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 1900 };
    try testing.expectEqual(fallback, addressOf("http://tv.local/desc.xml", fallback).?);
}

test "the M-SEARCH is what devices expect" {
    var buf: [256]u8 = undefined;
    const q = try query(&buf, 2);
    // MAN must be quoted or several renderers ignore the search.
    try testing.expect(std.mem.find(u8, q, "MAN: \"ssdp:discover\"\r\n") != null);
    try testing.expect(std.mem.find(u8, q, "MX: 2\r\n") != null);
    try testing.expect(std.mem.find(u8, q, "ST: " ++ search_target ++ "\r\n") != null);
    try testing.expect(std.mem.startsWith(u8, q, "M-SEARCH * HTTP/1.1\r\n"));
    try testing.expect(std.mem.endsWith(u8, q, "\r\n\r\n"));
}

/// Rygel 45.2's description, as served on this network. Reformatted only by
/// adding newlines between tags.
const rygel_description =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
    \\<specVersion><major>1</major><minor>0</minor></specVersion>
    \\<device>
    \\<deviceType>urn:schemas-upnp-org:device:MediaRenderer:2</deviceType>
    \\<friendlyName>Audio/Video playback on ThinkPanda</friendlyName>
    \\<manufacturer>Rygel Developers</manufacturer>
    \\<manufacturerURL>http://www.rygel-project.org</manufacturerURL>
    \\<modelName>Rygel</modelName>
    \\<modelNumber>45.2</modelNumber>
    \\<UDN>uuid:9736f11b-5e1c-4266-9c22-9624746b4c2f</UDN>
    \\<iconList>
    \\<icon><mimetype>image/png</mimetype><width>120</width><height>120</height><depth>24</depth><url>/Playbin-120x120x24.png</url></icon>
    \\<icon><mimetype>image/jpeg</mimetype><width>48</width><height>48</height><depth>24</depth><url>/Playbin-48x48x24.jpg</url></icon>
    \\</iconList>
    \\<serviceList>
    \\<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:2</serviceType>
    \\<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
    \\<SCPDURL>/xml/ConnectionManager.xml</SCPDURL>
    \\<controlURL>/Control/Playbin/RygelSinkConnectionManager</controlURL></service>
    \\<service><serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType>
    \\<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
    \\<SCPDURL>/xml/AVTransport2.xml</SCPDURL>
    \\<controlURL>/Control/Playbin/RygelAVTransport</controlURL></service>
    \\<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:2</serviceType>
    \\<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
    \\<SCPDURL>/xml/RenderingControl2.xml</SCPDURL>
    \\<controlURL>/Control/Playbin/RygelRenderingControl</controlURL></service>
    \\</serviceList>
    \\<dlna:X_DLNADOC>DMR-1.51</dlna:X_DLNADOC>
    \\</device>
    \\</root>
;

test "a real renderer's description" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const location = "http://192.168.1.37:42675/9736f11b-5e1c-4266-9c22-9624746b4c2f.xml";

    const d = try parseDescription(arena.allocator(), location, rygel_description);
    try testing.expectEqualStrings("Audio/Video playback on ThinkPanda", d.friendly_name);
    try testing.expectEqualStrings("Rygel Developers", d.manufacturer);
    try testing.expectEqualStrings("Rygel", d.model);
    try testing.expectEqualStrings("uuid:9736f11b-5e1c-4266-9c22-9624746b4c2f", d.udn);

    // Version 2, and kept verbatim because SOAPAction has to repeat it.
    try testing.expectEqualStrings("urn:schemas-upnp-org:service:AVTransport:2", d.av_transport.type);
    try testing.expectEqualStrings(
        "http://192.168.1.37:42675/Control/Playbin/RygelAVTransport",
        d.av_transport.control_url,
    );
    try testing.expectEqualStrings("http://192.168.1.37:42675/xml/AVTransport2.xml", d.av_transport.scpd_url);
    try testing.expectEqualStrings(
        "http://192.168.1.37:42675/Control/Playbin/RygelSinkConnectionManager",
        d.connection_manager.?.control_url,
    );
    try testing.expect(d.rendering_control != null);
}

test "a renderer nested under another root device" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const xml_doc =
        \\<root><URLBase>http://10.0.0.5:2870/</URLBase><device>
        \\<deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
        \\<friendlyName>Outer Box</friendlyName>
        \\<serviceList><service>
        \\<serviceType>urn:schemas-upnp-org:service:Dimming:1</serviceType>
        \\<controlURL>/nope</controlURL></service></serviceList>
        \\<deviceList><device>
        \\<friendlyName>Inner Renderer</friendlyName>
        \\<serviceList><service>
        \\<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        \\<controlURL>ctrl/avt</controlURL></service></serviceList>
        \\</device></deviceList>
        \\</device></root>
    ;
    const d = try parseDescription(arena.allocator(), "http://10.0.0.5:2870/desc.xml", xml_doc);
    // The outer device has no AVTransport, so the nested one is the renderer.
    try testing.expectEqualStrings("Inner Renderer", d.friendly_name);
    // URLBase wins over the description URL, and a relative ref hangs off it.
    try testing.expectEqualStrings("http://10.0.0.5:2870/ctrl/avt", d.av_transport.control_url);
    try testing.expectEqual(@as(?Service, null), d.connection_manager);
}

test "a description with no renderer in it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NotARenderer, parseDescription(arena.allocator(), "http://h/d.xml",
        \\<root><device><friendlyName>Just a server</friendlyName><serviceList><service>
        \\<serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        \\<controlURL>/cd</controlURL></service></serviceList></device></root>
    ));
    try testing.expectError(error.NotARenderer, parseDescription(arena.allocator(), "http://h/d.xml", "not xml"));
}
