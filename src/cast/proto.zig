//! Cast channel framing (planned).
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
//!
//! Planned API:
//!   pub const Message = struct { source_id, destination_id, namespace, payload: union { utf8, binary } };
//!   pub fn encode(msg: Message, w: *std.Io.Writer) !void;   // writes length prefix + body
//!   pub fn decode(r: *std.Io.Reader, gpa: Allocator) !Message;

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
