//! Minimal XML, enough for UPnP: walk the elements of a document, pull the
//! text of one, and escape or unescape a value. Pure functions, no I/O, and
//! no allocation outside `unescape`.
//!
//! Namespace prefixes are stripped when matching, because renderers spell
//! the same document with `u:`, `s:`, `dc:`, `upnp:`, `sec:` and `pv:` and
//! disagree about which. There is no DTD, no validation and no entity
//! declaration: the inputs are device descriptions and SOAP replies, which
//! are generated, not written.

const std = @import("std");
const Io = std.Io;

/// How deep `text` will look before giving up. UPnP descriptions nest about
/// five levels; the cap is there so a malformed document cannot recurse.
pub const max_depth = 32;

pub const Element = struct {
    /// As written, prefix included.
    name: []const u8,
    /// Between the name and the end of the open tag.
    attrs: []const u8,
    /// Between the tags, still escaped. Empty for a self-closing element,
    /// and the input for a nested `Scanner`.
    body: []const u8,

    /// Whether this element's name, prefix ignored, is `want`.
    pub fn is(e: Element, want: []const u8) bool {
        return std.mem.eql(u8, localName(e.name), want);
    }
};

/// The elements of a document, or of one element's body, in order and
/// without descending into them.
pub const Scanner = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn init(source: []const u8) Scanner {
        return .{ .source = source };
    }

    /// The next element, or null at the end. Comments, processing
    /// instructions, declarations and stray close tags are skipped.
    pub fn next(s: *Scanner) ?Element {
        while (s.pos < s.source.len) {
            const lt = std.mem.findScalarPos(u8, s.source, s.pos, '<') orelse return null;
            const rest = s.source[lt..];

            if (std.mem.startsWith(u8, rest, "<!--")) {
                s.pos = skipPast(s.source, lt + 4, "-->");
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                s.pos = skipPast(s.source, lt + 9, "]]>");
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<?")) {
                s.pos = skipPast(s.source, lt + 2, "?>");
                continue;
            }
            const gt = tagEnd(s.source, lt) orelse return null;
            // A declaration, or a close tag belonging to a level above this
            // one: neither starts an element here.
            if (std.mem.startsWith(u8, rest, "<!") or std.mem.startsWith(u8, rest, "</")) {
                s.pos = gt + 1;
                continue;
            }

            const name = tagName(s.source, lt + 1);
            if (name.len == 0) {
                s.pos = gt + 1;
                continue;
            }
            const raw_attrs = s.source[lt + 1 + name.len .. gt];
            const attrs = std.mem.trim(u8, raw_attrs, " \t\r\n/");

            if (selfClosing(raw_attrs)) {
                s.pos = gt + 1;
                return .{ .name = name, .attrs = attrs, .body = "" };
            }
            const close = findClose(s.source, gt + 1, name) orelse {
                // Unclosed: take the rest as the body rather than lose it.
                s.pos = s.source.len;
                return .{ .name = name, .attrs = attrs, .body = s.source[gt + 1 ..] };
            };
            s.pos = close.after;
            return .{ .name = name, .attrs = attrs, .body = s.source[gt + 1 .. close.body_end] };
        }
        return null;
    }
};

/// A qualified name without its namespace prefix: "u:Play" is "Play".
pub fn localName(qname: []const u8) []const u8 {
    const colon = std.mem.findScalar(u8, qname, ':') orelse return qname;
    return qname[colon + 1 ..];
}

/// The body of the first element in document order whose local name is
/// `local`, still escaped. This is all a SOAP reply needs: they are flat.
pub fn text(xml: []const u8, local: []const u8) ?[]const u8 {
    return textAt(xml, local, 0);
}

fn textAt(xml: []const u8, local: []const u8, depth: usize) ?[]const u8 {
    if (depth >= max_depth) return null;
    var it: Scanner = .init(xml);
    while (it.next()) |el| {
        if (el.is(local)) return el.body;
        if (textAt(el.body, local, depth + 1)) |found| return found;
    }
    return null;
}

/// The value of one attribute, still escaped. Matched on the local name,
/// since a renderer may or may not put a prefix on it.
pub fn attr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        i = skipSpace(attrs, i);
        const key_start = i;
        while (i < attrs.len and attrs[i] != '=' and !isSpace(attrs[i])) i += 1;
        const key = attrs[key_start..i];
        i = skipSpace(attrs, i);
        // A bare word with no value; the next round reads it as a key.
        if (i >= attrs.len or attrs[i] != '=') continue;
        i = skipSpace(attrs, i + 1);
        if (i >= attrs.len) return null;

        const quote = attrs[i];
        const value = if (quote == '"' or quote == '\'') blk: {
            const end = std.mem.findScalarPos(u8, attrs, i + 1, quote) orelse return null;
            defer i = end + 1;
            break :blk attrs[i + 1 .. end];
        } else blk: {
            const start = i;
            while (i < attrs.len and !isSpace(attrs[i])) i += 1;
            break :blk attrs[start..i];
        };
        if (std.mem.eql(u8, localName(key), name)) return value;
    }
    return null;
}

/// Resolves the five XML entities and numeric character references. Always a
/// fresh allocation, so the result outlives `raw`. Anything else that looks
/// like an entity is kept as written rather than dropped.
pub fn unescape(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, raw.len);

    var i: usize = 0;
    while (i < raw.len) {
        const amp = std.mem.findScalarPos(u8, raw, i, '&') orelse break;
        try out.appendSlice(arena, raw[i..amp]);
        i = amp;

        const semi = std.mem.findScalarPos(u8, raw, amp, ';') orelse break;
        const body = raw[amp + 1 .. semi];
        if (entity(body)) |c| {
            try out.append(arena, c);
        } else if (codepoint(body)) |cp| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch {
                try out.append(arena, '&');
                i = amp + 1;
                continue;
            };
            try out.appendSlice(arena, buf[0..n]);
        } else {
            try out.appendSlice(arena, raw[amp .. semi + 1]);
        }
        i = semi + 1;
    }
    try out.appendSlice(arena, raw[i..]);
    return out.toOwnedSlice(arena);
}

/// Writes `raw` with the five XML entities replaced, which is safe for both
/// element text and a quoted attribute value. Applying it twice is what a
/// DIDL document needs, since it travels as the value of a SOAP argument.
pub fn escape(w: *Io.Writer, raw: []const u8) Io.Writer.Error!void {
    var start: usize = 0;
    for (raw, 0..) |c, i| {
        const replacement = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => continue,
        };
        try w.writeAll(raw[start..i]);
        try w.writeAll(replacement);
        start = i + 1;
    }
    try w.writeAll(raw[start..]);
}

// --- internals ---------------------------------------------------------------

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn skipSpace(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and isSpace(s[i])) i += 1;
    return i;
}

/// Just past `needle`, or the end of the text when it is not there.
fn skipPast(s: []const u8, from: usize, needle: []const u8) usize {
    const at = std.mem.findPos(u8, s, from, needle) orelse return s.len;
    return at + needle.len;
}

/// The `>` closing the tag at `lt`, ignoring any inside a quoted value.
fn tagEnd(s: []const u8, lt: usize) ?usize {
    var i = lt + 1;
    var quote: u8 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else switch (c) {
            '"', '\'' => quote = c,
            '>' => return i,
            else => {},
        }
    }
    return null;
}

/// The element name at `from`, up to whitespace, `/` or `>`.
fn tagName(s: []const u8, from: usize) []const u8 {
    var i = from;
    while (i < s.len) : (i += 1) switch (s[i]) {
        ' ', '\t', '\r', '\n', '/', '>' => break,
        else => {},
    };
    return s[from..i];
}

fn selfClosing(raw_attrs: []const u8) bool {
    const t = std.mem.trim(u8, raw_attrs, " \t\r\n");
    return t.len > 0 and t[t.len - 1] == '/';
}

const Close = struct { body_end: usize, after: usize };

/// Where `name`'s own close tag is, counting nested elements of the same
/// name so that a `<device>` inside a `<deviceList>` does not end its parent.
fn findClose(s: []const u8, from: usize, name: []const u8) ?Close {
    var depth: usize = 1;
    var i = from;
    while (i < s.len) {
        const lt = std.mem.findScalarPos(u8, s, i, '<') orelse return null;
        const rest = s[lt..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            i = skipPast(s, lt + 4, "-->");
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            i = skipPast(s, lt + 9, "]]>");
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<?")) {
            i = skipPast(s, lt + 2, "?>");
            continue;
        }
        const gt = tagEnd(s, lt) orelse return null;
        if (std.mem.startsWith(u8, rest, "</")) {
            if (std.mem.eql(u8, tagName(s, lt + 2), name)) {
                depth -= 1;
                if (depth == 0) return .{ .body_end = lt, .after = gt + 1 };
            }
        } else if (!std.mem.startsWith(u8, rest, "<!")) {
            const open = tagName(s, lt + 1);
            if (std.mem.eql(u8, open, name) and !selfClosing(s[lt + 1 + open.len .. gt])) depth += 1;
        }
        i = gt + 1;
    }
    return null;
}

fn entity(name: []const u8) ?u8 {
    const table = std.StaticStringMap(u8).initComptime(.{
        .{ "amp", '&' },
        .{ "lt", '<' },
        .{ "gt", '>' },
        .{ "quot", '"' },
        .{ "apos", '\'' },
    });
    return table.get(name);
}

fn codepoint(body: []const u8) ?u21 {
    if (body.len < 2 or body[0] != '#') return null;
    const hex = body[1] == 'x' or body[1] == 'X';
    const digits = if (hex) body[2..] else body[1..];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch null;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn expectText(xml: []const u8, local: []const u8, want: []const u8) !void {
    try testing.expectEqualStrings(want, text(xml, local) orelse return error.NotFound);
}

test "local names" {
    try testing.expectEqualStrings("Play", localName("u:Play"));
    try testing.expectEqualStrings("Play", localName("Play"));
    try testing.expectEqualStrings("CaptionInfoEx", localName("sec:CaptionInfoEx"));
    try testing.expectEqualStrings("", localName("u:"));
}

test "scanner walks siblings without descending" {
    var it: Scanner = .init("<a>1</a><b><c>2</c></b><d/>");
    const a = it.next().?;
    try testing.expectEqualStrings("a", a.name);
    try testing.expectEqualStrings("1", a.body);
    const b = it.next().?;
    try testing.expectEqualStrings("b", b.name);
    try testing.expectEqualStrings("<c>2</c>", b.body);
    const d = it.next().?;
    try testing.expectEqualStrings("d", d.name);
    try testing.expectEqualStrings("", d.body);
    try testing.expectEqual(@as(?Element, null), it.next());
}

test "same name nested does not end its parent" {
    const xml =
        \\<device><friendlyName>outer</friendlyName>
        \\<deviceList><device><friendlyName>inner</friendlyName></device></deviceList>
        \\</device>
    ;
    var it: Scanner = .init(xml);
    const outer = it.next().?;
    try testing.expectEqual(@as(?Element, null), it.next());
    try expectText(outer.body, "friendlyName", "outer");

    // The nested one is reachable, and only through the list.
    const list = text(outer.body, "deviceList").?;
    var inner: Scanner = .init(list);
    try expectText(inner.next().?.body, "friendlyName", "inner");
}

test "declarations, comments and CDATA are skipped" {
    const xml =
        \\<?xml version="1.0"?>
        \\<!DOCTYPE root SYSTEM "x.dtd">
        \\<!-- <fake>not an element</fake> -->
        \\<root><![CDATA[<also>not</also>]]><real>yes</real></root>
    ;
    var it: Scanner = .init(xml);
    const root = it.next().?;
    try testing.expectEqualStrings("root", root.name);
    try testing.expectEqual(@as(?Element, null), it.next());
    try expectText(root.body, "real", "yes");
    // Neither the comment nor the CDATA contributed an element.
    try testing.expectEqual(@as(?[]const u8, null), text(root.body, "fake"));
    try testing.expectEqual(@as(?[]const u8, null), text(root.body, "also"));
}

test "a close tag inside a comment does not end an element" {
    var it: Scanner = .init("<a>x<!-- </a> -->y</a><b>2</b>");
    const a = it.next().?;
    try testing.expectEqualStrings("x<!-- </a> -->y", a.body);
    try testing.expectEqualStrings("b", it.next().?.name);
}

test "attributes" {
    const el = blk: {
        var it: Scanner = .init("<res protocolInfo=\"http-get:*:video/mp4:*\" sec:type='srt' bare size=12>u</res>");
        break :blk it.next().?;
    };
    try testing.expectEqualStrings("u", el.body);
    try testing.expectEqualStrings("http-get:*:video/mp4:*", attr(el.attrs, "protocolInfo").?);
    // Matched on the local name, so the prefix a renderer adds does not matter.
    try testing.expectEqualStrings("srt", attr(el.attrs, "type").?);
    try testing.expectEqualStrings("12", attr(el.attrs, "size").?);
    try testing.expectEqual(@as(?[]const u8, null), attr(el.attrs, "missing"));
}

test "a greater-than inside an attribute does not end the tag" {
    var it: Scanner = .init("<a t=\"1 > 0\">body</a>");
    const a = it.next().?;
    try testing.expectEqualStrings("body", a.body);
    try testing.expectEqualStrings("1 > 0", attr(a.attrs, "t").?);
}

test "unescape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("plain", try unescape(a, "plain"));
    try testing.expectEqualStrings("a&b<c>d\"e'f", try unescape(a, "a&amp;b&lt;c&gt;d&quot;e&apos;f"));
    try testing.expectEqualStrings("caf\u{e9}", try unescape(a, "caf&#233;"));
    try testing.expectEqualStrings("caf\u{e9}", try unescape(a, "caf&#xE9;"));
    // Anything we do not know is kept as written rather than dropped.
    try testing.expectEqualStrings("a&nbsp;b", try unescape(a, "a&nbsp;b"));
    try testing.expectEqualStrings("Q&A", try unescape(a, "Q&A"));
    try testing.expectEqualStrings("a&#zz;b", try unescape(a, "a&#zz;b"));
}

fn escaped(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try escape(&out.writer, raw);
    return out.toOwnedSlice();
}

test "escape, and escaping twice as a DIDL argument does" {
    const gpa = testing.allocator;

    const once = try escaped(gpa, "Tom & Jerry <1>");
    defer gpa.free(once);
    try testing.expectEqualStrings("Tom &amp; Jerry &lt;1&gt;", once);

    // The DIDL is built escaped, then escaped again into the SOAP envelope.
    const twice = try escaped(gpa, once);
    defer gpa.free(twice);
    try testing.expectEqualStrings("Tom &amp;amp; Jerry &amp;lt;1&amp;gt;", twice);

    // And it survives the round trip back.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const back = try unescape(arena.allocator(), try unescape(arena.allocator(), twice));
    try testing.expectEqualStrings("Tom & Jerry <1>", back);
}

test "a device description" {
    const xml =
        \\<?xml version="1.0"?>
        \\<root xmlns="urn:schemas-upnp-org:device-1-0">
        \\  <specVersion><major>1</major><minor>0</minor></specVersion>
        \\  <URLBase>http://192.168.1.50:9197/</URLBase>
        \\  <device>
        \\    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        \\    <friendlyName>Living Room TV</friendlyName>
        \\    <manufacturer>Samsung Electronics</manufacturer>
        \\    <modelName>UE55NU7100</modelName>
        \\    <UDN>uuid:08b40581-b7c2-4fbd-9b61-6e9f1a0d7f1c</UDN>
        \\    <serviceList>
        \\      <service>
        \\        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        \\        <controlURL>/upnp/control/ConnectionManager1</controlURL>
        \\      </service>
        \\      <service>
        \\        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        \\        <controlURL>/upnp/control/AVTransport1</controlURL>
        \\        <SCPDURL>/upnp/scpd/AVTransport1</SCPDURL>
        \\      </service>
        \\    </serviceList>
        \\  </device>
        \\</root>
    ;
    try expectText(xml, "URLBase", "http://192.168.1.50:9197/");
    try expectText(xml, "friendlyName", "Living Room TV");
    try expectText(xml, "modelName", "UE55NU7100");

    // What ssdp will do: walk the services and keep the ones it drives.
    var control: ?[]const u8 = null;
    var scpd: ?[]const u8 = null;
    var it: Scanner = .init(text(xml, "serviceList").?);
    while (it.next()) |service| {
        if (!service.is("service")) continue;
        const kind = text(service.body, "serviceType") orelse continue;
        if (!std.mem.eql(u8, kind, "urn:schemas-upnp-org:service:AVTransport:1")) continue;
        control = text(service.body, "controlURL");
        scpd = text(service.body, "SCPDURL");
    }
    try testing.expectEqualStrings("/upnp/control/AVTransport1", control.?);
    try testing.expectEqualStrings("/upnp/scpd/AVTransport1", scpd.?);
}

test "a SOAP reply" {
    const xml =
        \\<?xml version="1.0"?>
        \\<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        \\<s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
        \\<Track>1</Track><TrackDuration>0:09:56</TrackDuration>
        \\<RelTime>0:01:23</RelTime><AbsTime>NOT_IMPLEMENTED</AbsTime>
        \\</u:GetPositionInfoResponse></s:Body></s:Envelope>
    ;
    try expectText(xml, "TrackDuration", "0:09:56");
    try expectText(xml, "RelTime", "0:01:23");
    try expectText(xml, "AbsTime", "NOT_IMPLEMENTED");
    // The prefix on the wrapper is not ours to predict.
    try testing.expect(text(xml, "GetPositionInfoResponse") != null);
}

test "a SOAP fault" {
    const xml =
        \\<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
        \\<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
        \\<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
        \\<errorCode>701</errorCode><errorDescription>Transition not available</errorDescription>
        \\</UPnPError></detail></s:Fault></s:Body></s:Envelope>
    ;
    try expectText(xml, "errorCode", "701");
    try expectText(xml, "errorDescription", "Transition not available");
}

test "an SCPD allowed value list" {
    const xml =
        \\<scpd><serviceStateTable>
        \\<stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
        \\<stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekMode</name><dataType>string</dataType>
        \\<allowedValueList><allowedValue>TRACK_NR</allowedValue><allowedValue>REL_TIME</allowedValue></allowedValueList>
        \\</stateVariable>
        \\</serviceStateTable></scpd>
    ;
    var modes: std.ArrayList([]const u8) = .empty;
    defer modes.deinit(testing.allocator);

    var vars: Scanner = .init(text(xml, "serviceStateTable").?);
    while (vars.next()) |v| {
        if (!std.mem.eql(u8, text(v.body, "name") orelse "", "A_ARG_TYPE_SeekMode")) continue;
        var values: Scanner = .init(text(v.body, "allowedValueList") orelse "");
        while (values.next()) |value| try modes.append(testing.allocator, value.body);
    }
    try testing.expectEqual(@as(usize, 2), modes.items.len);
    try testing.expectEqualStrings("TRACK_NR", modes.items[0]);
    try testing.expectEqualStrings("REL_TIME", modes.items[1]);
}

test "malformed input does not hang or overrun" {
    try testing.expectEqual(@as(?[]const u8, null), text("", "a"));
    try testing.expectEqual(@as(?[]const u8, null), text("no markup at all", "a"));
    try testing.expectEqual(@as(?[]const u8, null), text("<<<>>>", "a"));
    try testing.expectEqual(@as(?[]const u8, null), text("<a attr=\"unterminated", "a"));
    // An unclosed element keeps what follows rather than losing it.
    try expectText("<a>tail", "a", "tail");
    try testing.expectEqual(@as(?[]const u8, null), attr("=", "x"));
    try testing.expectEqual(@as(?[]const u8, null), attr("a b c", "a"));

}

test "nesting past the cap stops instead of recursing" {
    const gpa = testing.allocator;
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    for (0..max_depth + 4) |_| try deep.appendSlice(gpa, "<n>");
    try deep.appendSlice(gpa, "<needle>found</needle>");
    for (0..max_depth + 4) |_| try deep.appendSlice(gpa, "</n>");

    try testing.expectEqual(@as(?[]const u8, null), text(deep.items, "needle"));
    // Shallow enough, so the cap is what stopped the one above.
    try expectText("<n><n><needle>found</needle></n></n>", "needle", "found");
}
