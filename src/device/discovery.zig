//! `castig ls`: find the devices castig can drive, of either kind.
//!
//! Cast receivers answer an mDNS query for `_googlecast._tcp`; UPnP AV
//! renderers answer an SSDP M-SEARCH. Both rounds are `sweep.run` with a
//! different packet, and neither joins its multicast group. See `sweep.zig`
//! for why that works and what the fallback would be.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Env = @import("../env.zig").Env;
const dns = @import("dns.zig");
const ssdp = @import("dlna/ssdp.zig");
const sweep = @import("sweep.zig");

const log = std.log.scoped(.cast);

pub const service = "_googlecast._tcp.local";
pub const default_port: u16 = 8009;
pub const default_timeout_ms: u32 = 2000;

const mdns_group: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 224, 0, 0, 251 }, .port = 5353 } };

/// What a device speaks. The spec a user types may name it, `cast:living
/// room`, when a name alone would be ambiguous.
pub const Protocol = enum { cast, dlna };

/// A device to connect to, once its address is known.
pub const Endpoint = union(enum) {
    cast: net.Ip4Address,
    dlna: struct {
        address: net.Ip4Address,
        /// The description URL; the renderer reads it for its control URLs.
        location: []const u8,
    },

    pub fn protocol(e: Endpoint) Protocol {
        return switch (e) {
            .cast => .cast,
            .dlna => .dlna,
        };
    }

    /// Where the device is, for a message or for the base URL we serve on.
    pub fn address(e: Endpoint) net.Ip4Address {
        return switch (e) {
            .cast => |a| a,
            .dlna => |d| d.address,
        };
    }
};

pub const Device = struct {
    protocol: Protocol,
    /// Cast: the TXT "id", stable across reboots. DLNA: the UDN.
    id: []const u8,
    /// User-visible name: Cast's "fn", or DLNA's `<friendlyName>`.
    friendly_name: []const u8,
    /// Cast's "md", or DLNA's manufacturer and model.
    model: []const u8,
    address: net.Ip4Address,
    /// DLNA only: the description URL, which also names it as a `<device>`.
    location: []const u8 = "",

    /// Frees the strings the device owns.
    pub fn deinit(d: Device, gpa: std.mem.Allocator) void {
        gpa.free(d.id);
        gpa.free(d.friendly_name);
        gpa.free(d.model);
        gpa.free(d.location);
    }

    /// Case-insensitive fragment of the friendly name or model, or a prefix
    /// of the id.
    pub fn matches(d: Device, spec: []const u8) bool {
        return std.ascii.findIgnoreCase(d.friendly_name, spec) != null or
            std.ascii.findIgnoreCase(d.model, spec) != null or
            std.mem.startsWith(u8, d.id, spec);
    }

    /// How to name this device back to castig. A Cast receiver is named by
    /// its address, which resolves without a discovery round; a renderer is
    /// named by its description URL, which is the only thing that locates
    /// it. An address would name the wrong protocol entirely.
    pub fn writeSpec(d: Device, w: *Io.Writer) Io.Writer.Error!void {
        if (d.protocol == .dlna and d.location.len > 0) return w.writeAll(d.location);
        return w.print("{f}", .{d.address});
    }

    /// Everything a connection needs, without a second discovery round.
    pub fn endpoint(d: Device) Endpoint {
        return switch (d.protocol) {
            .cast => .{ .cast = d.address },
            .dlna => .{ .dlna = .{ .address = d.address, .location = d.location } },
        };
    }
};

pub const Query = struct {
    timeout_ms: u32 = default_timeout_ms,
    /// Stop as soon as a device matches this spec.
    match: ?[]const u8 = null,
    /// Only this kind of device, or both when null.
    protocol: ?Protocol = null,
};

/// Every device that answers within `q.timeout_ms`, of either kind.
pub fn discover(io: Io, gpa: std.mem.Allocator, q: Query) ![]Device {
    var found: std.ArrayList(Device) = .empty;
    // Reverse order: the strings go first, while the list still holds them.
    errdefer found.deinit(gpa);
    errdefer freeDevices(gpa, found.items);

    if (q.protocol) |p| {
        switch (p) {
            .cast => try castScan(io, gpa, q, &found),
            .dlna => try dlnaScan(io, gpa, q, &found),
        }
        return found.toOwnedSlice(gpa);
    }

    // Both rounds are mostly waiting on the network, so they overlap: `ls`
    // costs one timeout rather than two.
    var renderers: std.ArrayList(Device) = .empty;
    errdefer renderers.deinit(gpa);
    errdefer freeDevices(gpa, renderers.items);

    var scanning = io.async(dlnaScan, .{ io, gpa, q, &renderers });
    castScan(io, gpa, q, &found) catch |err| {
        _ = scanning.cancel(io) catch {};
        return err;
    };
    // A LAN with no renderer on it is the normal case, not a failure.
    scanning.await(io) catch |err| log.debug("ssdp round failed: {s}", .{@errorName(err)});

    try found.appendSlice(gpa, renderers.items);
    // The strings belong to `found` now, so drop the second view of them
    // before anything else can fail.
    renderers.deinit(gpa);
    renderers = .empty;

    return found.toOwnedSlice(gpa);
}

/// The mDNS round.
fn castScan(io: Io, gpa: std.mem.Allocator, q: Query, into: *std.ArrayList(Device)) !void {
    var query_buf: [64]u8 = undefined;
    const query = try dns.buildQuery(&query_buf, service, dns.Type.PTR, true);
    var ctx: CastScan = .{ .gpa = gpa, .into = into, .match = q.match };
    try sweep.run(io, .{
        .group = mdns_group,
        .queries = &.{query},
        .timeout_ms = q.timeout_ms,
    }, &ctx, CastScan.take);
}

const CastScan = struct {
    gpa: std.mem.Allocator,
    into: *std.ArrayList(Device),
    match: ?[]const u8,

    fn take(c: *CastScan, packet: []const u8, from: ?net.Ip4Address) anyerror!bool {
        if (!try parseResponse(c.gpa, packet, from, c.into)) return false;
        const spec = c.match orelse return false;
        return c.into.items[c.into.items.len - 1].matches(spec);
    }
};

/// The SSDP round. Descriptions are read into a scratch arena and only what
/// a `Device` keeps is copied out.
fn dlnaScan(io: Io, gpa: std.mem.Allocator, q: Query, into: *std.ArrayList(Device)) !void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    for (try ssdp.discover(io, gpa, scratch.allocator(), q.timeout_ms)) |r| {
        const model = if (r.description.manufacturer.len > 0 and r.description.model.len > 0)
            try std.mem.concat(scratch.allocator(), u8, &.{ r.description.manufacturer, " ", r.description.model })
        else if (r.description.model.len > 0) r.description.model else r.description.manufacturer;

        const device: Device = .{
            .protocol = .dlna,
            .id = try gpa.dupe(u8, r.description.udn),
            .friendly_name = try gpa.dupe(u8, r.description.friendly_name),
            .model = try gpa.dupe(u8, model),
            .address = r.address,
            .location = try gpa.dupe(u8, r.location),
        };
        errdefer device.deinit(gpa);
        try into.append(gpa, device);
    }
}

/// Frees each device in a slice; the slice itself is the caller's.
pub fn freeDevices(gpa: std.mem.Allocator, devices: []const Device) void {
    for (devices) |d| d.deinit(gpa);
}

/// Appends the device announced by `packet`, if any and not seen yet.
fn parseResponse(gpa: std.mem.Allocator, packet: []const u8, from: ?net.Ip4Address, devices: *std.ArrayList(Device)) !bool {
    var parser = try dns.Parser.init(packet);
    if (!parser.isResponse()) return false;

    var name_buf: [dns.max_name_len]u8 = undefined;
    var target_buf: [dns.max_name_len]u8 = undefined;

    var instance: ?[]const u8 = null;
    defer if (instance) |i| gpa.free(i);
    var id: ?[]const u8 = null;
    errdefer if (id) |i| gpa.free(i);
    var friendly: ?[]const u8 = null;
    errdefer if (friendly) |f| gpa.free(f);
    var model: ?[]const u8 = null;
    errdefer if (model) |m| gpa.free(m);
    var port: ?u16 = null;
    var ip: ?[4]u8 = null;

    while (try parser.next(&name_buf)) |rec| {
        switch (rec.type) {
            dns.Type.PTR => if (std.ascii.eqlIgnoreCase(rec.name, service)) {
                if (instance == null) instance = try gpa.dupe(u8, try parser.ptrTarget(rec, &target_buf));
            },
            dns.Type.SRV => {
                const s = try parser.srv(rec, &target_buf);
                port = s.port;
                if (instance == null) instance = try gpa.dupe(u8, rec.name);
            },
            dns.Type.TXT => {
                var it = dns.txtIterator(rec);
                while (it.next()) |e| {
                    if (std.mem.eql(u8, e.key, "id") and id == null) {
                        id = try gpa.dupe(u8, e.value);
                    } else if (std.mem.eql(u8, e.key, "fn") and friendly == null) {
                        friendly = try gpa.dupe(u8, e.value);
                    } else if (std.mem.eql(u8, e.key, "md") and model == null) {
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
    if (id == null and port == null) return false;
    const bytes = ip orelse (from orelse return false).bytes;

    const dev: Device = .{
        .protocol = .cast,
        .location = try gpa.dupe(u8, ""),
        .id = id orelse try gpa.dupe(u8, ""),
        .friendly_name = friendly orelse try gpa.dupe(u8, instance orelse "?"),
        .model = model orelse try gpa.dupe(u8, ""),
        .address = .{ .bytes = bytes, .port = port orelse default_port },
    };
    id = null;
    friendly = null;
    model = null;

    for (devices.items) |d| {
        const same_id = dev.id.len > 0 and std.mem.eql(u8, d.id, dev.id);
        if (same_id or d.address.eql(dev.address)) {
            dev.deinit(gpa);
            return false;
        }
    }
    try devices.append(gpa, dev);
    return true;
}

/// Turns a device argument into an endpoint:
///
///   192.168.1.39             a Cast receiver, port 8009 unless given
///   http://host:port/x.xml   a renderer, named by its description URL
///   cast:living room         a name, with the protocol settled
///   dlna:living room
///   living room              a name; on a tie a receiver wins
pub fn resolve(env: Env, spec_in: []const u8, want_in: ?Protocol) !Endpoint {
    var spec = spec_in;
    var want = want_in;
    if (std.mem.cutScalar(u8, spec, ':')) |cut| {
        const head, const tail = cut;
        if (std.meta.stringToEnum(Protocol, head)) |p| {
            want = p;
            spec = std.mem.trim(u8, tail, " ");
        }
    }

    if (std.mem.startsWith(u8, spec, "http://") or std.mem.startsWith(u8, spec, "https://")) {
        const location = try env.arena.dupe(u8, spec);
        const address = ssdp.addressOf(location, null) orelse {
            log.warn("cannot tell an address from {s}", .{location});
            return error.InvalidAddress;
        };
        return .{ .dlna = .{ .address = address, .location = location } };
    }

    if (spec.len > 0 and std.ascii.isDigit(spec[0])) {
        const literal = net.IpAddress.parseLiteral(spec) catch return error.InvalidAddress;
        var address = switch (literal) {
            .ip4 => |a| a,
            .ip6 => return error.InvalidAddress,
        };
        if ((want orelse .cast) == .cast) {
            if (address.port == 0) address.port = default_port;
            return .{ .cast = address };
        }
        // A renderer is named by its description URL, so go and find the
        // one living at that address rather than guess a path.
        if (try firstMatching(env, .{ .protocol = .dlna }, address)) |d| return d.endpoint();
        log.warn("no renderer answered at {f}; try `castig ls`", .{address});
        return error.DeviceNotFound;
    }

    // A name. Cast goes first: its round stops as soon as the name matches,
    // where the renderer round always waits out its deadline.
    if (want != .dlna) {
        if (try firstMatching(env, .{ .match = spec, .protocol = .cast }, null)) |d| return d.endpoint();
    }
    if (want != .cast) {
        if (try firstMatching(env, .{ .match = spec, .protocol = .dlna }, null)) |d| return d.endpoint();
    }
    log.warn("no device matches \"{s}\"; try `castig ls`", .{spec});
    return error.DeviceNotFound;
}

/// One round, returning the first device that matches, copied into the
/// arena because the round's own strings are freed on the way out.
fn firstMatching(env: Env, q: Query, address: ?net.Ip4Address) !?Device {
    const devices = try discover(env.io, env.gpa, q);
    defer env.gpa.free(devices);
    defer freeDevices(env.gpa, devices);

    for (devices) |d| {
        const hit = if (address) |a| std.mem.eql(u8, &d.address.bytes, &a.bytes) else d.matches(q.match.?);
        if (!hit) continue;
        return .{
            .protocol = d.protocol,
            .id = try env.arena.dupe(u8, d.id),
            .friendly_name = try env.arena.dupe(u8, d.friendly_name),
            .model = try env.arena.dupe(u8, d.model),
            .address = d.address,
            .location = try env.arena.dupe(u8, d.location),
        };
    }
    return null;
}

test "a device names itself in a way resolve understands" {
    var buf: [128]u8 = undefined;

    var cast_w: Io.Writer = .fixed(&buf);
    const receiver: Device = .{
        .protocol = .cast,
        .id = "abc",
        .friendly_name = "Living Room",
        .model = "Nest Audio",
        .address = .{ .bytes = .{ 192, 168, 1, 34 }, .port = 8009 },
    };
    try receiver.writeSpec(&cast_w);
    try std.testing.expectEqualStrings("192.168.1.34:8009", cast_w.buffered());

    // A renderer's address would resolve as a Cast receiver and try TLS
    // against its HTTP port, so it has to name itself by its description.
    var dlna_w: Io.Writer = .fixed(&buf);
    const renderer: Device = .{
        .protocol = .dlna,
        .id = "uuid:1",
        .friendly_name = "Kodi",
        .model = "Kodi",
        .address = .{ .bytes = .{ 192, 168, 1, 37 }, .port = 1254 },
        .location = "http://192.168.1.37:1254/",
    };
    try renderer.writeSpec(&dlna_w);
    try std.testing.expectEqualStrings("http://192.168.1.37:1254/", dlna_w.buffered());
}

test {
    std.testing.refAllDecls(@This());
}
