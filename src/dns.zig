//! Minimal DNS wire format, enough for mDNS service discovery: build a
//! one-question query and walk the records of a response. Pure functions,
//! no I/O, no allocation. Names are returned dotted and without a trailing
//! dot ("_googlecast._tcp.local").

const std = @import("std");

pub const Type = struct {
    pub const A: u16 = 1;
    pub const PTR: u16 = 12;
    pub const TXT: u16 = 16;
    pub const AAAA: u16 = 28;
    pub const SRV: u16 = 33;
};

pub const class_in: u16 = 1;
/// mDNS: set on a question to ask for a unicast reply (RFC 6762 §5.4).
pub const unicast_response_flag: u16 = 0x8000;
/// mDNS: set on a record to signal cache flush (RFC 6762 §10.2). Stripped by the parser.
const cache_flush_flag: u16 = 0x8000;

pub const max_name_len = 255;
const header_len = 12;

pub const Error = error{ NoSpaceLeft, InvalidName, Truncated, InvalidPointer };

/// Writes a query with one question into `buf` and returns the used slice.
pub fn buildQuery(buf: []u8, name: []const u8, qtype: u16, unicast_response: bool) Error![]u8 {
    if (buf.len < header_len) return error.NoSpaceLeft;
    @memset(buf[0..header_len], 0);
    std.mem.writeInt(u16, buf[4..6], 1, .big); // qdcount

    var pos = try writeName(buf, header_len, name);
    if (buf.len < pos + 4) return error.NoSpaceLeft;
    std.mem.writeInt(u16, buf[pos..][0..2], qtype, .big);
    const qclass = class_in | @as(u16, if (unicast_response) unicast_response_flag else 0);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], qclass, .big);
    pos += 4;
    return buf[0..pos];
}

fn writeName(buf: []u8, start: usize, name: []const u8) Error!usize {
    var pos = start;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0) continue;
        if (label.len > 63) return error.InvalidName;
        if (buf.len < pos + 1 + label.len) return error.NoSpaceLeft;
        buf[pos] = @intCast(label.len);
        @memcpy(buf[pos + 1 ..][0..label.len], label);
        pos += 1 + label.len;
    }
    if (buf.len < pos + 1) return error.NoSpaceLeft;
    buf[pos] = 0;
    return pos + 1;
}

pub const Name = struct {
    name: []const u8,
    /// Position just after the name field, in the packet where it started.
    end: usize,
};

/// Decodes a possibly compressed name at `pos` into `out`.
pub fn readName(packet: []const u8, pos: usize, out: []u8) Error!Name {
    var p = pos;
    var end: ?usize = null;
    var out_len: usize = 0;
    var jumps: usize = 0;

    while (true) {
        if (p >= packet.len) return error.Truncated;
        const len: usize = packet[p];
        if (len == 0) {
            p += 1;
            break;
        }
        if (len & 0xC0 == 0xC0) {
            if (p + 1 >= packet.len) return error.Truncated;
            const target = ((len & 0x3F) << 8) | packet[p + 1];
            if (target >= p) return error.InvalidPointer; // pointers only go backwards
            jumps += 1;
            if (jumps > 16) return error.InvalidPointer;
            if (end == null) end = p + 2;
            p = target;
            continue;
        }
        if (len & 0xC0 != 0) return error.InvalidName;
        p += 1;
        if (p + len > packet.len) return error.Truncated;
        const sep: usize = if (out_len > 0) 1 else 0;
        if (out_len + sep + len > out.len) return error.NoSpaceLeft;
        if (sep == 1) {
            out[out_len] = '.';
            out_len += 1;
        }
        @memcpy(out[out_len..][0..len], packet[p..][0..len]);
        out_len += len;
        p += len;
    }
    return .{ .name = out[0..out_len], .end = end orelse p };
}

pub const Record = struct {
    /// Owner name, valid until the next call to `Parser.next` with the same buffer.
    name: []const u8,
    type: u16,
    /// Class with the mDNS cache-flush bit removed.
    class: u16,
    ttl: u32,
    rdata: []const u8,
    /// Offset of `rdata` in the packet, needed to follow compression pointers inside it.
    rdata_pos: usize,
};

pub const Parser = struct {
    packet: []const u8,
    flags: u16,
    pos: usize,
    /// Records left across the answer, authority and additional sections.
    remaining: usize,

    /// Reads the header and skips the question section.
    pub fn init(packet: []const u8) Error!Parser {
        if (packet.len < header_len) return error.Truncated;
        const flags = std.mem.readInt(u16, packet[2..4], .big);
        const qdcount = std.mem.readInt(u16, packet[4..6], .big);
        const ancount: usize = std.mem.readInt(u16, packet[6..8], .big);
        const nscount: usize = std.mem.readInt(u16, packet[8..10], .big);
        const arcount: usize = std.mem.readInt(u16, packet[10..12], .big);

        var pos: usize = header_len;
        var scratch: [max_name_len]u8 = undefined;
        for (0..qdcount) |_| {
            const q = try readName(packet, pos, &scratch);
            pos = q.end + 4;
            if (pos > packet.len) return error.Truncated;
        }
        return .{ .packet = packet, .flags = flags, .pos = pos, .remaining = ancount + nscount + arcount };
    }

    pub fn isResponse(p: *const Parser) bool {
        return p.flags & 0x8000 != 0;
    }

    /// Next record, with its owner name decoded into `name_buf`.
    pub fn next(p: *Parser, name_buf: []u8) Error!?Record {
        if (p.remaining == 0) return null;
        p.remaining -= 1;

        const owner = try readName(p.packet, p.pos, name_buf);
        var pos = owner.end;
        if (pos + 10 > p.packet.len) return error.Truncated;
        const rtype = std.mem.readInt(u16, p.packet[pos..][0..2], .big);
        const class = std.mem.readInt(u16, p.packet[pos + 2 ..][0..2], .big);
        const ttl = std.mem.readInt(u32, p.packet[pos + 4 ..][0..4], .big);
        const rdlen: usize = std.mem.readInt(u16, p.packet[pos + 8 ..][0..2], .big);
        pos += 10;
        if (pos + rdlen > p.packet.len) return error.Truncated;

        const rec: Record = .{
            .name = owner.name,
            .type = rtype,
            .class = class & ~cache_flush_flag,
            .ttl = ttl,
            .rdata = p.packet[pos..][0..rdlen],
            .rdata_pos = pos,
        };
        p.pos = pos + rdlen;
        return rec;
    }

    pub fn ptrTarget(p: *const Parser, rec: Record, out: []u8) Error![]const u8 {
        return (try readName(p.packet, rec.rdata_pos, out)).name;
    }

    pub const Srv = struct {
        priority: u16,
        weight: u16,
        port: u16,
        target: []const u8,
    };

    pub fn srv(p: *const Parser, rec: Record, out: []u8) Error!Srv {
        if (rec.rdata.len < 7) return error.Truncated;
        const target = try readName(p.packet, rec.rdata_pos + 6, out);
        return .{
            .priority = std.mem.readInt(u16, rec.rdata[0..2], .big),
            .weight = std.mem.readInt(u16, rec.rdata[2..4], .big),
            .port = std.mem.readInt(u16, rec.rdata[4..6], .big),
            .target = target.name,
        };
    }
};

pub const TxtIterator = struct {
    rdata: []const u8,
    pos: usize = 0,

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub fn next(it: *TxtIterator) ?Entry {
        while (it.pos < it.rdata.len) {
            const len: usize = it.rdata[it.pos];
            it.pos += 1;
            const end = @min(it.pos + len, it.rdata.len);
            const s = it.rdata[it.pos..end];
            it.pos = end;
            if (s.len == 0) continue;
            if (std.mem.indexOfScalar(u8, s, '=')) |eq| return .{ .key = s[0..eq], .value = s[eq + 1 ..] };
            return .{ .key = s, .value = "" };
        }
        return null;
    }
};

pub fn txtIterator(rec: Record) TxtIterator {
    return .{ .rdata = rec.rdata };
}

pub fn aRecord(rec: Record) Error![4]u8 {
    if (rec.rdata.len != 4) return error.Truncated;
    return rec.rdata[0..4].*;
}

pub fn aaaaRecord(rec: Record) Error![16]u8 {
    if (rec.rdata.len != 16) return error.Truncated;
    return rec.rdata[0..16].*;
}

// --- tests -----------------------------------------------------------------

test "buildQuery round trip" {
    var buf: [64]u8 = undefined;
    const q = try buildQuery(&buf, "_googlecast._tcp.local", Type.PTR, true);

    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, q[2..4], .big)); // flags
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[4..6], .big)); // qdcount

    var name_buf: [max_name_len]u8 = undefined;
    const n = try readName(q, header_len, &name_buf);
    try std.testing.expectEqualStrings("_googlecast._tcp.local", n.name);
    try std.testing.expectEqual(q.len - 4, n.end);
    try std.testing.expectEqual(Type.PTR, std.mem.readInt(u16, q[n.end..][0..2], .big));
    try std.testing.expectEqual(@as(u16, 0x8001), std.mem.readInt(u16, q[n.end + 2 ..][0..2], .big));

    var p = try Parser.init(q);
    try std.testing.expect(!p.isResponse());
    try std.testing.expectEqual(@as(?Record, null), try p.next(&name_buf));
}

/// Test helper: appends bytes to a fixed buffer, returning the offset written at.
const Builder = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn bytes(b: *Builder, data: []const u8) usize {
        const at = b.len;
        @memcpy(b.buf[at..][0..data.len], data);
        b.len += data.len;
        return at;
    }
    fn u16be(b: *Builder, v: u16) void {
        std.mem.writeInt(u16, b.buf[b.len..][0..2], v, .big);
        b.len += 2;
    }
    fn u32be(b: *Builder, v: u32) void {
        std.mem.writeInt(u32, b.buf[b.len..][0..4], v, .big);
        b.len += 4;
    }
    fn name(b: *Builder, dotted: []const u8) usize {
        const at = b.len;
        b.len = writeName(&b.buf, b.len, dotted) catch unreachable;
        return at;
    }
    fn pointer(b: *Builder, to: usize) void {
        b.u16be(0xC000 | @as(u16, @intCast(to)));
    }
    fn slice(b: *Builder) []const u8 {
        return b.buf[0..b.len];
    }
};

test "parse a cast-style response with compression" {
    var b: Builder = .{};
    // header: id 0, flags response+authoritative, qd 0, an 1, ns 0, ar 3
    b.u16be(0);
    b.u16be(0x8400);
    b.u16be(0);
    b.u16be(1);
    b.u16be(0);
    b.u16be(3);

    // PTR _x._tcp.local -> inst._x._tcp.local
    const service_at = b.name("_x._tcp.local");
    b.u16be(Type.PTR);
    b.u16be(class_in);
    b.u32be(120);
    b.u16be(7); // rdlength: "\x04inst" + pointer
    const inst_at = b.bytes("\x04inst");
    b.pointer(service_at);

    // SRV inst._x._tcp.local -> port 8009, target host.local
    b.pointer(inst_at);
    b.u16be(Type.SRV);
    b.u16be(class_in | cache_flush_flag);
    b.u32be(120);
    b.u16be(6 + 12); // priority, weight, port + "\x04host\x05local\x00"
    b.u16be(0);
    b.u16be(0);
    b.u16be(8009);
    const host_at = b.name("host.local");

    // TXT inst._x._tcp.local
    b.pointer(inst_at);
    b.u16be(Type.TXT);
    b.u16be(class_in | cache_flush_flag);
    b.u32be(4500);
    const txt = "\x06id=abc\x09fn=Living\x05noval";
    b.u16be(txt.len);
    _ = b.bytes(txt);

    // A host.local -> 192.168.1.39
    b.pointer(host_at);
    b.u16be(Type.A);
    b.u16be(class_in | cache_flush_flag);
    b.u32be(120);
    b.u16be(4);
    _ = b.bytes(&.{ 192, 168, 1, 39 });

    var p = try Parser.init(b.slice());
    try std.testing.expect(p.isResponse());
    var name_buf: [max_name_len]u8 = undefined;
    var target_buf: [max_name_len]u8 = undefined;

    const ptr = (try p.next(&name_buf)).?;
    try std.testing.expectEqual(Type.PTR, ptr.type);
    try std.testing.expectEqualStrings("_x._tcp.local", ptr.name);
    try std.testing.expectEqualStrings("inst._x._tcp.local", try p.ptrTarget(ptr, &target_buf));

    const srv = (try p.next(&name_buf)).?;
    try std.testing.expectEqual(Type.SRV, srv.type);
    try std.testing.expectEqual(class_in, srv.class);
    try std.testing.expectEqualStrings("inst._x._tcp.local", srv.name);
    const s = try p.srv(srv, &target_buf);
    try std.testing.expectEqual(@as(u16, 8009), s.port);
    try std.testing.expectEqualStrings("host.local", s.target);

    const txt_rec = (try p.next(&name_buf)).?;
    try std.testing.expectEqual(Type.TXT, txt_rec.type);
    var it = txtIterator(txt_rec);
    const e1 = it.next().?;
    try std.testing.expectEqualStrings("id", e1.key);
    try std.testing.expectEqualStrings("abc", e1.value);
    const e2 = it.next().?;
    try std.testing.expectEqualStrings("fn", e2.key);
    try std.testing.expectEqualStrings("Living", e2.value);
    const e3 = it.next().?;
    try std.testing.expectEqualStrings("noval", e3.key);
    try std.testing.expectEqualStrings("", e3.value);
    try std.testing.expectEqual(@as(?TxtIterator.Entry, null), it.next());

    const a = (try p.next(&name_buf)).?;
    try std.testing.expectEqual(Type.A, a.type);
    try std.testing.expectEqualStrings("host.local", a.name);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 39 }, try aRecord(a));

    try std.testing.expectEqual(@as(?Record, null), try p.next(&name_buf));
}

test "malformed packets are rejected" {
    var name_buf: [max_name_len]u8 = undefined;
    try std.testing.expectError(error.Truncated, Parser.init("short"));

    // forward pointer
    const fwd = [_]u8{ 0xC0, 0x05, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidPointer, readName(&fwd, 0, &name_buf));

    // label running past the end
    const trunc = [_]u8{ 0x05, 'a', 'b' };
    try std.testing.expectError(error.Truncated, readName(&trunc, 0, &name_buf));
}
