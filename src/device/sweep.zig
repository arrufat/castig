//! One round of multicast discovery: ask a well known group, then collect
//! the answers until a deadline.
//!
//! mDNS and SSDP differ in their packets and their parsers, not in their
//! shape. Neither needs to join the group, because both answer back to the
//! socket that asked: mDNS because the query sets the unicast-response bit
//! (RFC 6762 §5.4), SSDP because an M-SEARCH reply is unicast by
//! definition. Should a device answer to the group instead, the fallback is
//! IP_ADD_MEMBERSHIP on `Socket.handle` plus binding the group's port with
//! SO_REUSEADDR.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

/// The largest datagram either protocol sends: RFC 6762 §17 caps an mDNS
/// message at 9000 bytes, and an SSDP reply is a few hundred.
pub const max_packet = 9000;

/// A wall-clock timeout `ms` from now.
pub fn after(ms: u32) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

pub const Options = struct {
    group: net.IpAddress,
    /// Sent in order, `gap_ms` apart. SSDP repeats its query, because UDP
    /// loses it and devices answer after a delay of their own choosing;
    /// mDNS sends one.
    queries: []const []const u8,
    gap_ms: u32 = 0,
    timeout_ms: u32,
};

/// Sends each query, then hands every datagram to `handle` until the
/// deadline, or until `handle` returns true because it has what it wanted.
///
/// `handle` failing is not fatal: one device's malformed packet must not
/// end the round. Only `error.OutOfMemory` stops it, since nothing after it
/// would work either.
pub fn run(
    io: Io,
    opts: Options,
    context: anytype,
    comptime handle: fn (@TypeOf(context), []const u8, ?net.Ip4Address) anyerror!bool,
) !void {
    const bind_addr: net.IpAddress = .{ .ip4 = .unspecified(0) };
    const sock = try bind_addr.bind(io, .{ .mode = .dgram });
    defer sock.close(io);

    const deadline = after(opts.timeout_ms).toDeadline(io);

    // Replies to an earlier query wait in the socket buffer while the rest
    // go out, so spacing them costs nothing but the gap itself.
    for (opts.queries, 0..) |query, i| {
        if (i > 0 and opts.gap_ms > 0) after(opts.gap_ms).sleep(io) catch {};
        try sock.send(io, &opts.group, query);
    }

    var packet: [max_packet]u8 = undefined;
    while (true) {
        const msg = sock.receiveTimeout(io, &packet, deadline) catch |err| switch (err) {
            error.Timeout => return,
            else => return err,
        };
        const from: ?net.Ip4Address = switch (msg.from) {
            .ip4 => |a| a,
            .ip6 => null,
        };
        const done = handle(context, msg.data, from) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        if (done) return;
    }
}

test {
    std.testing.refAllDecls(@This());
}
