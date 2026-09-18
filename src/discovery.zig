//! `castig ls`: find Cast receivers with an mDNS query for `_googlecast._tcp`.
//!
//! The query sets the unicast-response bit, so receivers answer straight to
//! our socket and we never need to join the 224.0.0.251 multicast group.
//! Should a device ignore that bit, the fallback is IP_ADD_MEMBERSHIP on
//! `Socket.handle` plus binding port 5353 with SO_REUSEADDR.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const dns = @import("dns.zig");

pub const service = "_googlecast._tcp.local";
pub const default_port: u16 = 8009;

const mdns_group: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 224, 0, 0, 251 }, .port = 5353 } };
/// RFC 6762 §17: mDNS messages fit in 9000 bytes.
const max_packet = 9000;

pub const Device = struct {
    /// Receiver id from the TXT record ("id"). Stable across reboots.
    id: []const u8,
    /// User-visible name ("fn"), e.g. "Living Room speaker".
    friendly_name: []const u8,
    /// Model ("md"), e.g. "Pixel Tablet".
    model: []const u8,
    /// Service instance name, e.g. "Pixel-Tablet-30dab5...".
    instance: []const u8,
    address: net.Ip4Address,
};

/// Sends one query and collects answers until `timeout_ms` elapses.
pub fn discover(io: Io, gpa: std.mem.Allocator, timeout_ms: u32) ![]Device {
    const bind_addr: net.IpAddress = .{ .ip4 = .unspecified(0) };
    const sock = try bind_addr.bind(io, .{ .mode = .dgram });
    defer sock.close(io);

    var query_buf: [64]u8 = undefined;
    const query = try dns.buildQuery(&query_buf, service, dns.Type.PTR, true);
    try sock.send(io, &mdns_group, query);

    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
    const deadline = timeout.toDeadline(io);

    var devices: std.ArrayList(Device) = .empty;
    errdefer devices.deinit(gpa);
    var packet: [max_packet]u8 = undefined;

    while (true) {
        const msg = sock.receiveTimeout(io, &packet, deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        const from: ?net.Ip4Address = switch (msg.from) {
            .ip4 => |a| a,
            .ip6 => null,
        };
        parseResponse(gpa, msg.data, from, &devices) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A malformed packet from one device must not abort discovery.
            else => continue,
        };
    }
    return devices.toOwnedSlice(gpa);
}

fn parseResponse(gpa: std.mem.Allocator, packet: []const u8, from: ?net.Ip4Address, devices: *std.ArrayList(Device)) !void {
    var parser = try dns.Parser.init(packet);
    if (!parser.isResponse()) return;

    var name_buf: [dns.max_name_len]u8 = undefined;
    var target_buf: [dns.max_name_len]u8 = undefined;

    var instance: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var friendly: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var port: ?u16 = null;
    var ip: ?[4]u8 = null;

    while (try parser.next(&name_buf)) |rec| {
        switch (rec.type) {
            dns.Type.PTR => if (std.ascii.eqlIgnoreCase(rec.name, service)) {
                instance = try gpa.dupe(u8, try parser.ptrTarget(rec, &target_buf));
            },
            dns.Type.SRV => {
                const s = try parser.srv(rec, &target_buf);
                port = s.port;
                if (instance == null) instance = try gpa.dupe(u8, rec.name);
            },
            dns.Type.TXT => {
                var it = dns.txtIterator(rec);
                while (it.next()) |e| {
                    if (std.mem.eql(u8, e.key, "id")) {
                        id = try gpa.dupe(u8, e.value);
                    } else if (std.mem.eql(u8, e.key, "fn")) {
                        friendly = try gpa.dupe(u8, e.value);
                    } else if (std.mem.eql(u8, e.key, "md")) {
                        model = try gpa.dupe(u8, e.value);
                    }
                }
                if (instance == null) instance = try gpa.dupe(u8, rec.name);
            },
            dns.Type.A => ip = try dns.aRecord(rec),
            else => {},
        }
    }

    // Not a cast announcement (or an answer to somebody else's question).
    if (id == null and port == null) return;

    const bytes = ip orelse (from orelse return).bytes;
    const dev: Device = .{
        .id = id orelse "",
        .friendly_name = friendly orelse instance orelse "?",
        .model = model orelse "",
        .instance = instance orelse "",
        .address = .{ .bytes = bytes, .port = port orelse default_port },
    };

    for (devices.items) |d| {
        const same_id = dev.id.len > 0 and std.mem.eql(u8, d.id, dev.id);
        const same_addr = std.mem.eql(u8, &d.address.bytes, &dev.address.bytes) and d.address.port == dev.address.port;
        if (same_id or same_addr) return;
    }
    try devices.append(gpa, dev);
}

/// Turns a device argument into an address: "192.168.1.39", "192.168.1.39:8009",
/// or a case-insensitive fragment of the friendly name, model or id, which
/// triggers a discovery round.
pub fn resolve(io: Io, gpa: std.mem.Allocator, spec: []const u8) !net.Ip4Address {
    if (spec.len > 0 and std.ascii.isDigit(spec[0])) {
        if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
            const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch return error.InvalidAddress;
            return net.Ip4Address.parse(spec[0..colon], port) catch error.InvalidAddress;
        }
        return net.Ip4Address.parse(spec, default_port) catch error.InvalidAddress;
    }

    const devices = try discover(io, gpa, 2000);
    defer gpa.free(devices);
    for (devices) |d| {
        if (std.ascii.findIgnoreCase(d.friendly_name, spec) != null or
            std.ascii.findIgnoreCase(d.model, spec) != null or
            std.mem.startsWith(u8, d.id, spec))
        {
            return d.address;
        }
    }
    std.debug.print("no cast device matches \"{s}\"; try `castig ls`\n", .{spec});
    return error.DeviceNotFound;
}

pub fn run(io: Io, gpa: std.mem.Allocator, out: *Io.Writer, timeout_ms: u32) !void {
    const devices = try discover(io, gpa, timeout_ms);
    if (devices.len == 0) {
        try out.print("no cast devices answered within {d} ms\n", .{timeout_ms});
        try out.writeAll("(check with `avahi-browse -rt _googlecast._tcp`; if devices show there, they ignore unicast-response queries)\n");
        return;
    }
    for (devices) |d| {
        try out.print("{s}\t{s}\t{f}\t{s}\n", .{ d.friendly_name, d.model, d.address, d.id });
    }
}

test {
    std.testing.refAllDecls(@This());
}
