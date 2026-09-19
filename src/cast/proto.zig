//! Cast channel framing.
//!
//! Every message on the TLS connection to port 8009 is a big-endian u32
//! length followed by one protobuf `CastMessage`:
//!
//!   1  protocol_version  enum, always CASTV2_1_0 = 0
//!   2  source_id         string, e.g. "sender-0"
//!   3  destination_id    string, "receiver-0" or a transport id after LAUNCH
//!   4  namespace         string, e.g. "urn:x-cast:com.google.cast.tp.connection"
//!   5  payload_type      enum, STRING = 0 or BINARY = 1
//!   6  payload_utf8      string, JSON when payload_type == STRING
//!   7  payload_binary    bytes
//!
//! Only varint (wire type 0) and length-delimited (wire type 2) fields are
//! needed, so this is hand-rolled: no protobuf dependency.

const std = @import("std");
const Io = std.Io;

pub const Message = struct {
    source_id: []const u8,
    destination_id: []const u8,
    namespace: []const u8,
    payload: Payload,

    pub const Payload = union(enum) {
        utf8: []const u8,
        binary: []const u8,
    };
};

const Field = struct {
    const protocol_version: u32 = 1;
    const source_id: u32 = 2;
    const destination_id: u32 = 3;
    const namespace: u32 = 4;
    const payload_type: u32 = 5;
    const payload_utf8: u32 = 6;
    const payload_binary: u32 = 7;
};

const Wire = enum(u3) { varint = 0, fixed64 = 1, len = 2, fixed32 = 5 };

fn tag(field: u32, wire: Wire) u32 {
    return (field << 3) | @backingInt(wire);
}

/// A protobuf varint is an unsigned LEB128.
pub fn varintLen(value: u64) usize {
    var n: usize = 1;
    var v = value;
    while (v >= 0x80) : (v >>= 7) n += 1;
    return n;
}

fn lenFieldLen(field: u32, bytes: []const u8) usize {
    return varintLen(tag(field, .len)) + varintLen(bytes.len) + bytes.len;
}

fn writeLenField(w: *Io.Writer, field: u32, bytes: []const u8) Io.Writer.Error!void {
    try w.writeUleb128(tag(field, .len));
    try w.writeUleb128(bytes.len);
    try w.writeAll(bytes);
}

/// Size of the protobuf body, without the u32 length prefix.
pub fn bodyLen(msg: Message) usize {
    const payload_field, const payload = payloadField(msg);
    return varintLen(tag(Field.protocol_version, .varint)) + 1 +
        lenFieldLen(Field.source_id, msg.source_id) +
        lenFieldLen(Field.destination_id, msg.destination_id) +
        lenFieldLen(Field.namespace, msg.namespace) +
        varintLen(tag(Field.payload_type, .varint)) + 1 +
        lenFieldLen(payload_field, payload);
}

fn payloadField(msg: Message) struct { u32, []const u8 } {
    return switch (msg.payload) {
        .utf8 => |s| .{ Field.payload_utf8, s },
        .binary => |b| .{ Field.payload_binary, b },
    };
}

/// Writes the length prefix and the body. The caller flushes.
pub fn encode(msg: Message, w: *Io.Writer) Io.Writer.Error!void {
    try w.writeInt(u32, @intCast(bodyLen(msg)), .big);

    try w.writeUleb128(tag(Field.protocol_version, .varint));
    try w.writeUleb128(@as(u8, 0));
    try writeLenField(w, Field.source_id, msg.source_id);
    try writeLenField(w, Field.destination_id, msg.destination_id);
    try writeLenField(w, Field.namespace, msg.namespace);
    try w.writeUleb128(tag(Field.payload_type, .varint));
    const payload_field, const payload = payloadField(msg);
    try w.writeUleb128(@as(u8, if (payload_field == Field.payload_binary) 1 else 0));
    try writeLenField(w, payload_field, payload);
}

pub const DecodeError = Io.Reader.TakeLeb128Error || error{ UnsupportedWireType, MissingField };

/// Decodes one body (without the length prefix). Slices point into `body`.
pub fn decode(body: []const u8) DecodeError!Message {
    var r: Io.Reader = .fixed(body);
    var source_id: ?[]const u8 = null;
    var destination_id: ?[]const u8 = null;
    var namespace: ?[]const u8 = null;
    var payload_type: u64 = 0;
    var utf8: ?[]const u8 = null;
    var binary: ?[]const u8 = null;

    while (r.bufferedLen() > 0) {
        const key = try r.takeLeb128(u64);
        const field: u32 = @intCast(key >> 3);
        switch (@as(u3, @intCast(key & 7))) {
            0 => {
                const v = try r.takeLeb128(u64);
                if (field == Field.payload_type) payload_type = v;
            },
            2 => {
                const n: usize = @intCast(try r.takeLeb128(u64));
                const bytes = try r.take(n);
                switch (field) {
                    Field.source_id => source_id = bytes,
                    Field.destination_id => destination_id = bytes,
                    Field.namespace => namespace = bytes,
                    Field.payload_utf8 => utf8 = bytes,
                    Field.payload_binary => binary = bytes,
                    else => {},
                }
            },
            1 => _ = try r.take(8),
            5 => _ = try r.take(4),
            else => return error.UnsupportedWireType,
        }
    }

    return .{
        .source_id = source_id orelse return error.MissingField,
        .destination_id = destination_id orelse return error.MissingField,
        .namespace = namespace orelse return error.MissingField,
        .payload = if (payload_type == 1)
            .{ .binary = binary orelse "" }
        else
            .{ .utf8 = utf8 orelse "" },
    };
}

test "encode matches hand-computed bytes" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(.{ .source_id = "a", .destination_id = "b", .namespace = "c", .payload = .{ .utf8 = "{}" } }, &w);
    const expected = [_]u8{
        0, 0, 0, 17, // length prefix
        0x08, 0x00, // protocol_version = 0
        0x12, 0x01, 'a', // source_id
        0x1a, 0x01, 'b', // destination_id
        0x22, 0x01, 'c', // namespace
        0x28, 0x00, // payload_type = STRING
        0x32, 0x02, '{', '}', // payload_utf8
    };
    try std.testing.expectEqualSlices(u8, &expected, w.buffered());
}

test "decode round trip" {
    const msg: Message = .{
        .source_id = "sender-0",
        .destination_id = "receiver-0",
        .namespace = "urn:x-cast:com.google.cast.tp.heartbeat",
        .payload = .{ .utf8 = "{\"type\":\"PING\"}" },
    };
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(msg, &w);
    const frame = w.buffered();
    try std.testing.expectEqual(bodyLen(msg), std.mem.readInt(u32, frame[0..4], .big));

    const decoded = try decode(frame[4..]);
    try std.testing.expectEqualStrings(msg.source_id, decoded.source_id);
    try std.testing.expectEqualStrings(msg.destination_id, decoded.destination_id);
    try std.testing.expectEqualStrings(msg.namespace, decoded.namespace);
    try std.testing.expectEqualStrings(msg.payload.utf8, decoded.payload.utf8);
}

test "decode binary payload and unknown fields" {
    // Fields: protocol_version, source, dest, namespace, an unknown varint
    // field 9, payload_type=1, payload_binary.
    const body = [_]u8{ 0x08, 0x00, 0x12, 0x01, 's', 0x1a, 0x01, 'd', 0x22, 0x01, 'n', 0x48, 0x2a, 0x28, 0x01, 0x3a, 0x02, 0xde, 0xad };
    const m = try decode(&body);
    try std.testing.expectEqualStrings("n", m.namespace);
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad }, m.payload.binary);
}

test "decode rejects truncated input" {
    const body = [_]u8{ 0x12, 0x05, 'a', 'b' };
    try std.testing.expectError(error.EndOfStream, decode(&body));
    try std.testing.expectError(error.MissingField, decode(&.{ 0x08, 0x00 }));
}
