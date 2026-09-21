//! SOAP over HTTP, the way UPnP uses it: one action, a flat list of
//! arguments, and a reply scraped for the few elements that matter.
//!
//! Everything that talks to a renderer goes through `call`, so if a device's
//! HTTP turns out to be too odd for `std.http.Client` there is one place to
//! replace.

const std = @import("std");
const Io = std.Io;

const xml = @import("../xml.zig");
const version = @import("build_options").version;

const log = std.log.scoped(.dlna);

/// Some renderers answer 500 to a request without one.
pub const user_agent = "Linux/1.0 UPnP/1.0 castig/" ++ version;

pub const Arg = struct {
    name: []const u8,
    value: []const u8,
};

pub const Action = struct {
    /// The serviceType exactly as the description advertised it, version and
    /// all. `SOAPAction` and `xmlns:u` both have to repeat it.
    service: []const u8,
    name: []const u8,
    /// In order. `InstanceID` comes first on every AVTransport action.
    args: []const Arg = &.{},
};

/// What a renderer says when it will not do something. The codes are worth
/// separating because each one says what to try next.
pub const Refusal = error{
    /// 701: it will not go from the state it is in, usually because
    /// something is still playing.
    TransitionNotAvailable,
    /// 710 and 711: it does not seek that way, or not to there.
    SeekModeNotSupported,
    IllegalSeekTarget,
    /// 714: it does not want the content type we offered.
    IllegalMimeType,
    /// 716: it could not fetch the URL we gave it.
    ResourceNotFound,
    /// 402: we built the request wrong.
    InvalidArgs,
    /// Anything else, already logged with its code.
    RendererRefused,
};

const envelope_head =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>" ++
    "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"" ++
    " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>";
const envelope_tail = "</s:Body></s:Envelope>";

/// Writes the envelope for `a`. Argument values are escaped here, which is
/// what makes an already escaped DIDL arrive escaped twice.
pub fn envelope(w: *Io.Writer, a: Action) Io.Writer.Error!void {
    try w.writeAll(envelope_head);
    try w.print("<u:{s} xmlns:u=\"", .{a.name});
    try xml.escape(w, a.service);
    try w.writeAll("\">");
    for (a.args) |arg| {
        try w.print("<{s}>", .{arg.name});
        try xml.escape(w, arg.value);
        try w.print("</{s}>", .{arg.name});
    }
    try w.print("</u:{s}>", .{a.name});
    try w.writeAll(envelope_tail);
}

/// Posts `a` and returns the reply body, allocated in `arena`. The caller
/// owns that arena and is expected to reset it between operations: a poll
/// every second for the length of a film adds up otherwise.
pub fn call(arena: std.mem.Allocator, http: *std.http.Client, control_url: []const u8, a: Action) ![]const u8 {
    var body: Io.Writer.Allocating = .init(arena);
    try envelope(&body.writer, a);

    // The quotes around the SOAPAction value are not optional: several
    // renderers reject the request without them.
    const soap_action = try arena.print("\"{s}#{s}\"", .{ a.service, a.name });
    var reply: Io.Writer.Allocating = .init(arena);

    log.debug("-> {s}\n   {s}", .{ control_url, body.written() });
    const res = http.fetch(.{
        .location = .{ .url = control_url },
        .method = .POST,
        .payload = body.written(),
        .headers = .{
            .user_agent = .{ .override = user_agent },
            .content_type = .{ .override = "text/xml; charset=\"utf-8\"" },
        },
        .extra_headers = &.{.{ .name = "soapaction", .value = soap_action }},
        .response_writer = &reply.writer,
    }) catch |err| {
        log.debug("{s} failed: {s}", .{ a.name, @errorName(err) });
        return error.RendererUnreachable;
    };
    log.debug("<- {d}\n   {s}", .{ @backingInt(res.status), reply.written() });

    if (res.status == .ok) return reply.written();
    return refusal(a.name, reply.written());
}

/// A non-200 carries a `<UPnPError>` somewhere inside a SOAP fault.
fn refusal(action: []const u8, body: []const u8) Refusal {
    const code = xml.text(body, "errorCode") orelse "";
    const description = xml.text(body, "errorDescription") orelse "";
    log.warn("the renderer refused {s}: {s}{s}{s}", .{
        action,
        if (code.len > 0) code else "no error code",
        if (description.len > 0) ", " else "",
        description,
    });
    const number = std.fmt.parseInt(u32, code, 10) catch return error.RendererRefused;
    return switch (number) {
        701 => error.TransitionNotAvailable,
        710 => error.SeekModeNotSupported,
        711 => error.IllegalSeekTarget,
        714 => error.IllegalMimeType,
        716 => error.ResourceNotFound,
        402 => error.InvalidArgs,
        else => error.RendererRefused,
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn built(gpa: std.mem.Allocator, a: Action) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try envelope(&out.writer, a);
    return out.toOwnedSlice();
}

test "an envelope repeats the service verbatim" {
    const gpa = testing.allocator;
    const body = try built(gpa, .{
        .service = "urn:schemas-upnp-org:service:AVTransport:2",
        .name = "Play",
        .args = &.{ .{ .name = "InstanceID", .value = "0" }, .{ .name = "Speed", .value = "1" } },
    });
    defer gpa.free(body);
    try testing.expect(std.mem.find(u8, body, "<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:2\">") != null);
    try testing.expect(std.mem.find(u8, body, "<InstanceID>0</InstanceID><Speed>1</Speed>") != null);
    try testing.expect(std.mem.endsWith(u8, body, "</u:Play></s:Body></s:Envelope>"));
}

test "an argument value is escaped on the way in" {
    const gpa = testing.allocator;
    const body = try built(gpa, .{
        .service = "urn:x:1",
        .name = "SetAVTransportURI",
        .args = &.{.{ .name = "CurrentURI", .value = "http://h/a?x=1&y=2" }},
    });
    defer gpa.free(body);
    try testing.expect(std.mem.find(u8, body, "<CurrentURI>http://h/a?x=1&amp;y=2</CurrentURI>") != null);
}
