//! Media server the receiver pulls from.
//!
//! One listener on an ephemeral port, one task per connection, each running
//! `std.http.Server`. Routes are fixed at start: a file served with Range
//! support (206 Partial Content), or an in-memory body such as converted
//! subtitles. The receiver probes with HEAD first and needs
//! `Access-Control-Allow-Origin: *` on subtitle tracks, so every response
//! carries it.
//!
//! Live remux/transcode output will be a third route kind, chunked and
//! without Range, once the media pipeline exists.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const http = std.http;

pub const Route = struct {
    /// Request target, e.g. "/media.mkv". Query strings are ignored on match.
    path: []const u8,
    content_type: []const u8,
    body: Body,

    pub const Body = union(enum) {
        /// Path on disk, streamed with `sendFile`.
        file: []const u8,
        /// Fixed content kept in memory.
        bytes: []const u8,
        /// Live-generated output of unknown length (chunked, no Range).
        stream: Stream,
    };

    pub const Stream = struct {
        context: *const anyopaque,
        generate: *const fn (context: *const anyopaque, start_time: f64, w: *std.Io.Writer) anyerror!void,
    };
};

pub const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: net.Server,
    routes: []const Route,
    group: Io.Group = .init,
    port: u16,
    /// Log every request on stderr.
    debug: bool = false,

    pub fn start(io: Io, gpa: std.mem.Allocator, routes: []const Route, debug: bool) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        const any: net.IpAddress = .{ .ip4 = .unspecified(0) };
        const listener = try any.listen(io, .{ .reuse_address = true });
        s.* = .{
            .io = io,
            .gpa = gpa,
            .listener = listener,
            .routes = routes,
            .port = listener.socket.address.getPort(),
            .debug = debug,
        };
        try s.group.concurrent(io, acceptLoop, .{s});
        return s;
    }

    pub fn stop(s: *Server) void {
        // Wake the blocked accept, then cancel the connection tasks.
        _ = std.os.linux.shutdown(s.listener.socket.handle, std.os.linux.SHUT.RDWR);
        s.group.cancel(s.io);
        s.listener.socket.close(s.io);
        s.gpa.destroy(s);
    }

    fn acceptLoop(s: *Server) Io.Cancelable!void {
        while (true) {
            const stream = s.listener.accept(s.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            s.group.concurrent(s.io, handleConnection, .{ s, stream }) catch stream.close(s.io);
        }
    }

    fn handleConnection(s: *Server, stream: net.Stream) Io.Cancelable!void {
        defer stream.close(s.io);
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(s.io, &in_buf);
        var writer = stream.writer(s.io, &out_buf);
        var server: http.Server = .init(&reader.interface, &writer.interface);

        while (true) {
            var request = server.receiveHead() catch return;
            s.serve(&request) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            if (!request.head.keep_alive) return;
        }
    }

    /// Sent with every response. The receiver loads side-loaded tracks (and
    /// adaptive media) through XHR, so it needs CORS on everything, including
    /// a preflight for the Range header.
    const cors_headers = [_]http.Header{
        .{ .name = "access-control-allow-origin", .value = "*" },
        .{ .name = "access-control-allow-methods", .value = "GET, HEAD, OPTIONS" },
        .{ .name = "access-control-allow-headers", .value = "Range, Content-Type, Accept-Encoding" },
        .{ .name = "access-control-expose-headers", .value = "Content-Range, Content-Length, Accept-Ranges, Content-Type" },
        .{ .name = "access-control-max-age", .value = "86400" },
    };

    fn serve(s: *Server, request: *http.Server.Request) !void {
        const target = request.head.target;
        const method = request.head.method;

        var range_header: ?[]const u8 = null;
        var requested_headers: ?[]const u8 = null;
        var it = request.iterateHeaders();
        if (s.debug) std.debug.print("http {s} {s}\n", .{ @tagName(method), target });
        while (it.next()) |h| {
            if (s.debug) std.debug.print("     {s}: {s}\n", .{ h.name, h.value });
            if (std.ascii.eqlIgnoreCase(h.name, "range")) range_header = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "access-control-request-headers")) requested_headers = h.value;
        }

        if (method == .OPTIONS) {
            // Allow exactly what the preflight asks for, on top of the fixed list.
            var preflight = cors_headers;
            if (requested_headers) |rh| preflight[2] = .{ .name = "access-control-allow-headers", .value = rh };
            return request.respond("", .{ .status = .no_content, .extra_headers = &preflight });
        }

        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
        const route = for (s.routes) |r| {
            if (std.mem.eql(u8, r.path, path)) break r;
        } else {
            if (s.debug) std.debug.print("http {s} {s} -> 404\n", .{ @tagName(method), target });
            return request.respond("not found\n", .{ .status = .not_found, .extra_headers = &cors_headers });
        };

        if (method != .GET and method != .HEAD) {
            return request.respond("", .{ .status = .method_not_allowed, .extra_headers = &cors_headers });
        }

        if (route.body == .stream) return s.serveStream(request, route);

        var file_reader_buf: [64 * 1024]u8 = undefined;
        var file: ?Io.File = null;
        defer if (file) |f| f.close(s.io);
        var file_reader: Io.File.Reader = undefined;

        const total: u64 = switch (route.body) {
            .bytes => |b| b.len,
            .file => |p| blk: {
                const f = try Io.Dir.cwd().openFile(s.io, p, .{});
                file = f;
                file_reader = f.reader(s.io, &file_reader_buf);
                break :blk try file_reader.getSize();
            },
            .stream => unreachable, // handled before this point
        };

        const range = parseRange(range_header, total) catch {
            var buf: [64]u8 = undefined;
            const content_range = try std.fmt.bufPrint(&buf, "bytes */{d}", .{total});
            return request.respond("", .{
                .status = .range_not_satisfiable,
                .extra_headers = &(cors_headers ++ [_]http.Header{.{ .name = "content-range", .value = content_range }}),
            });
        };

        var content_range_buf: [96]u8 = undefined;
        var headers: [cors_headers.len + 4]http.Header = undefined;
        var n: usize = cors_headers.len;
        @memcpy(headers[0..n], &cors_headers);
        headers[n] = .{ .name = "content-type", .value = route.content_type };
        n += 1;
        headers[n] = .{ .name = "accept-ranges", .value = "bytes" };
        n += 1;
        headers[n] = .{ .name = "cache-control", .value = "no-store" };
        n += 1;
        if (range) |r| {
            headers[n] = .{
                .name = "content-range",
                .value = try std.fmt.bufPrint(&content_range_buf, "bytes {d}-{d}/{d}", .{ r.start, r.end, total }),
            };
            n += 1;
        }

        const offset: u64 = if (range) |r| r.start else 0;
        const len: u64 = if (range) |r| r.end - r.start + 1 else total;

        var send_buf: [64 * 1024]u8 = undefined;
        var body = try request.respondStreaming(&send_buf, .{
            .content_length = len,
            .respond_options = .{
                .status = if (range != null) .partial_content else .ok,
                .extra_headers = headers[0..n],
            },
        });
        if (method == .HEAD) {
            // Headers only. The eliding writer would still insist on seeing
            // every byte pass through, so finish the response by hand.
            try body.writer.flush();
            body.state = .end;
            try body.http_protocol_output.flush();
            return;
        }
        switch (route.body) {
            .bytes => |b| try body.writer.writeAll(b[@intCast(offset)..][0..@intCast(len)]),
            .file => {
                try file_reader.seekTo(offset);
                _ = try body.writer.sendFileAll(&file_reader, .limited(@intCast(len)));
            },
            .stream => unreachable, // handled before this point
        }
        try body.end();
    }

    /// Streams live-generated output. Length is unknown, so the response is
    /// chunked and Range is not offered. HEAD returns headers only.
    fn serveStream(s: *Server, request: *http.Server.Request, route: Route) !void {
        var headers: [cors_headers.len + 2]http.Header = undefined;
        @memcpy(headers[0..cors_headers.len], &cors_headers);
        headers[cors_headers.len] = .{ .name = "content-type", .value = route.content_type };
        headers[cors_headers.len + 1] = .{ .name = "cache-control", .value = "no-store" };

        if (request.head.method == .HEAD) {
            return request.respond("", .{ .status = .ok, .extra_headers = &headers });
        }

        const start_time = queryTime(request.head.target);
        var send_buf: [64 * 1024]u8 = undefined;
        var body = try request.respondStreaming(&send_buf, .{
            .respond_options = .{ .status = .ok, .extra_headers = &headers },
        });
        route.body.stream.generate(route.body.stream.context, start_time, &body.writer) catch |err| {
            if (s.debug) std.debug.print("stream {s} aborted: {s}\n", .{ route.path, @errorName(err) });
            return; // the connection is torn down by the caller
        };
        try body.end();
    }
};

/// Reads the `t` query parameter (seconds) from a request target, 0 if absent.
pub fn queryTime(target: []const u8) f64 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return 0;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "t=")) {
            return std.fmt.parseFloat(f64, kv[2..]) catch 0;
        }
    }
    return 0;
}

test "query time" {
    try std.testing.expectEqual(@as(f64, 0), queryTime("/remux.mp4"));
    try std.testing.expectEqual(@as(f64, 120), queryTime("/remux.mp4?t=120"));
    try std.testing.expectEqual(@as(f64, 5.5), queryTime("/remux.mp4?x=1&t=5.5"));
}

pub const Range = struct { start: u64, end: u64 };

/// Parses a single `bytes=` range against `total`. Null when there is no
/// header; error when the range cannot be satisfied.
pub fn parseRange(header: ?[]const u8, total: u64) error{Unsatisfiable}!?Range {
    const h = header orelse return null;
    if (!std.mem.startsWith(u8, h, "bytes=")) return null;
    const spec = h["bytes=".len..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null; // multipart ranges: serve everything
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.Unsatisfiable;
    const first = std.mem.trim(u8, spec[0..dash], " ");
    const last = std.mem.trim(u8, spec[dash + 1 ..], " ");
    if (total == 0) return error.Unsatisfiable;

    if (first.len == 0) {
        // suffix: last N bytes
        const n = std.fmt.parseInt(u64, last, 10) catch return error.Unsatisfiable;
        if (n == 0) return error.Unsatisfiable;
        const start = if (n >= total) 0 else total - n;
        return .{ .start = start, .end = total - 1 };
    }
    const start = std.fmt.parseInt(u64, first, 10) catch return error.Unsatisfiable;
    if (start >= total) return error.Unsatisfiable;
    var end: u64 = total - 1;
    if (last.len > 0) {
        end = std.fmt.parseInt(u64, last, 10) catch return error.Unsatisfiable;
        if (end < start) return error.Unsatisfiable;
        if (end > total - 1) end = total - 1;
    }
    return .{ .start = start, .end = end };
}

test "range parsing" {
    try std.testing.expectEqual(@as(?Range, null), try parseRange(null, 100));
    try std.testing.expectEqual(Range{ .start = 0, .end = 99 }, (try parseRange("bytes=0-", 100)).?);
    try std.testing.expectEqual(Range{ .start = 10, .end = 19 }, (try parseRange("bytes=10-19", 100)).?);
    try std.testing.expectEqual(Range{ .start = 10, .end = 99 }, (try parseRange("bytes=10-500", 100)).?);
    try std.testing.expectEqual(Range{ .start = 90, .end = 99 }, (try parseRange("bytes=-10", 100)).?);
    try std.testing.expectError(error.Unsatisfiable, parseRange("bytes=100-", 100));
    try std.testing.expectError(error.Unsatisfiable, parseRange("bytes=20-10", 100));
}
