//! Media server the receiver pulls from.
//!
//! One listener on an ephemeral port, one task per connection, each running
//! `std.http.Server`. A route serves a file with Range support (206 Partial
//! Content), an in-memory body such as converted subtitles, or a dynamic
//! handler that writes its own response (used for HLS, where one prefix serves
//! the playlist and every segment). The receiver probes with HEAD first and
//! needs `Access-Control-Allow-Origin: *` on everything, so every response
//! carries CORS headers.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const http = std.http;

/// Every request and its headers, at debug level.
const log = std.log.scoped(.http);

/// Convenience alias for dynamic handlers.
pub const Request = http.Server.Request;

pub const Route = struct {
    /// Request target to match. A trailing '/' matches by prefix (for dynamic
    /// handlers), otherwise the match is exact. Query strings are ignored.
    path: []const u8,
    body: Body,

    pub const Body = union(enum) {
        /// Path on disk, streamed with `sendFile`.
        file: Static([]const u8),
        /// Fixed content kept in memory.
        bytes: Static([]const u8),
        /// A handler that writes the whole response itself.
        dynamic: Dynamic,
    };

    pub fn Static(comptime T: type) type {
        return struct { content_type: []const u8, data: T };
    }

    pub const Dynamic = struct {
        context: *const anyopaque,
        /// `path` is the request target without its query string.
        handle: *const fn (context: *const anyopaque, request: *Request, path: []const u8) anyerror!void,
    };
};

pub const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: net.Server,
    routes: []const Route,
    group: Io.Group = .init,
    port: u16,

    pub fn start(io: Io, gpa: std.mem.Allocator, routes: []const Route) !*Server {
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
        };
        try s.group.concurrent(io, acceptLoop, .{s});
        return s;
    }

    /// Replaces the route table (used when the cast falls back to another
    /// delivery mode after the server is already running). The new slice must
    /// outlive the server.
    pub fn setRoutes(s: *Server, routes: []const Route) void {
        s.routes = routes;
    }

    pub fn stop(s: *Server) void {
        // Wake the blocked accept, then cancel the connection tasks.
        const listening: net.Stream = .{ .socket = s.listener.socket };
        listening.shutdown(s.io, .both) catch {};
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

    fn serve(s: *Server, request: *Request) !void {
        const target = request.head.target;
        const method = request.head.method;

        log.debug("{s} {s}", .{ @tagName(method), target });
        var it = request.iterateHeaders();
        while (it.next()) |h| log.debug("     {s}: {s}", .{ h.name, h.value });

        if (method == .OPTIONS) {
            // Allow exactly what the preflight asks for, on top of the fixed list.
            var preflight = cors_array;
            if (header(request, "access-control-request-headers")) |rh| {
                preflight[2] = .{ .name = "access-control-allow-headers", .value = rh };
            }
            return request.respond("", .{ .status = .no_content, .extra_headers = &preflight });
        }

        const path = requestPath(request);
        const route = for (s.routes) |r| {
            const matched = if (std.mem.endsWith(u8, r.path, "/"))
                std.mem.startsWith(u8, path, r.path)
            else
                std.mem.eql(u8, r.path, path);
            if (matched) break r;
        } else {
            log.debug("{s} {s} -> 404", .{ @tagName(method), target });
            return respondNotFound(request);
        };

        if (method != .GET and method != .HEAD) {
            return request.respond("", .{ .status = .method_not_allowed, .extra_headers = cors });
        }

        switch (route.body) {
            .dynamic => |d| try d.handle(d.context, request, path),
            .bytes => |b| try respondBuffer(request, b.content_type, b.data),
            .file => |f| {
                const file = try Io.Dir.cwd().openFile(s.io, f.data, .{});
                defer file.close(s.io);
                var buf: [64 * 1024]u8 = undefined;
                var reader = file.reader(s.io, &buf);
                try respondRanged(request, f.content_type, try reader.getSize(), .{ .file = &reader });
            },
        }
    }
};

/// The request target without its query string.
pub fn requestPath(request: *const Request) []const u8 {
    return std.mem.sliceTo(request.head.target, '?');
}

fn header(request: *Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// CORS sent with every response, including preflight for the Range header.
/// `cors` is the pointer form dynamic handlers pass as `extra_headers`.
const cors_array = [_]http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, HEAD, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Range, Content-Type, Accept-Encoding" },
    .{ .name = "access-control-expose-headers", .value = "Content-Range, Content-Length, Accept-Ranges, Content-Type" },
    .{ .name = "access-control-max-age", .value = "86400" },
};
pub const cors: []const http.Header = &cors_array;

pub fn respondNotFound(request: *Request) !void {
    try request.respond("not found\n", .{ .status = .not_found, .extra_headers = cors });
}

fn streamHeaders(content_type: []const u8) [cors_array.len + 2]http.Header {
    return cors_array ++ [_]http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    };
}

/// For a dynamic handler's HEAD: headers only, no body.
pub fn respondHead(request: *Request, content_type: []const u8) !void {
    const headers = streamHeaders(content_type);
    return request.respond("", .{ .status = .ok, .extra_headers = &headers });
}

/// For a dynamic handler's GET: begins a chunked response of unknown length.
/// `buffer` must outlive the returned writer; the caller writes the body and
/// calls `end()`.
pub fn beginStream(request: *Request, buffer: []u8, content_type: []const u8) !http.BodyWriter {
    const headers = streamHeaders(content_type);
    return request.respondStreaming(buffer, .{
        .respond_options = .{ .status = .ok, .extra_headers = &headers },
    });
}

pub const ReadFn = *const fn (ctx: *anyopaque, offset: u64, dest: []u8) anyerror!void;

/// Where the bytes of a ranged response come from.
pub const Source = union(enum) {
    bytes: []const u8,
    /// Streamed with `sendFile`.
    file: *Io.File.Reader,
    /// `read(ctx, offset, dest)` fills `dest` with the bytes at `offset`.
    virtual: struct { ctx: *anyopaque, read: ReadFn },
};

/// Serves an in-memory body with a Content-Length and single-range support
/// (206), handling HEAD. Used by dynamic handlers that produce the whole body
/// first (the Cast receiver's HLS loader needs a Content-Length on segments).
pub fn respondBuffer(request: *Request, content_type: []const u8, bytes: []const u8) !void {
    return respondRanged(request, content_type, bytes.len, .{ .bytes = bytes });
}

/// Serves a body of `total` bytes that lives anywhere (the on-the-fly MP4
/// assembler) with Content-Length, single-range (206) and HEAD support.
pub fn respondVirtual(request: *Request, content_type: []const u8, total: u64, ctx: *anyopaque, readFn: ReadFn) !void {
    return respondRanged(request, content_type, total, .{ .virtual = .{ .ctx = ctx, .read = readFn } });
}

/// Serves `total` bytes from `source` with Content-Length, single-range (206)
/// and HEAD support.
pub fn respondRanged(request: *Request, content_type: []const u8, total: u64, source: Source) !void {
    const range = parseRange(header(request, "range"), total) catch {
        var buf: [64]u8 = undefined;
        const content_range = try std.mem.print(&buf, "bytes */{d}", .{total});
        return request.respond("", .{
            .status = .range_not_satisfiable,
            .extra_headers = &(cors_array ++ [_]http.Header{.{ .name = "content-range", .value = content_range }}),
        });
    };

    var content_range_buf: [96]u8 = undefined;
    var headers_buf: [cors_array.len + 4]http.Header = undefined;
    var headers: std.ArrayList(http.Header) = .initBuffer(&headers_buf);
    headers.appendSliceAssumeCapacity(&cors_array);
    headers.appendAssumeCapacity(.{ .name = "content-type", .value = content_type });
    headers.appendAssumeCapacity(.{ .name = "accept-ranges", .value = "bytes" });
    headers.appendAssumeCapacity(.{ .name = "cache-control", .value = "no-store" });
    if (range) |r| headers.appendAssumeCapacity(.{
        .name = "content-range",
        .value = try std.mem.print(&content_range_buf, "bytes {d}-{d}/{d}", .{ r.start, r.end, total }),
    });

    var offset: u64 = if (range) |r| r.start else 0;
    var remaining: u64 = if (range) |r| r.end - r.start + 1 else total;

    var send_buf: [64 * 1024]u8 = undefined;
    var body = try request.respondStreaming(&send_buf, .{
        .content_length = remaining,
        .respond_options = .{
            .status = if (range != null) .partial_content else .ok,
            .extra_headers = headers.items,
        },
    });
    if (request.head.method == .HEAD) {
        // The eliding writer insists on seeing every byte, so HEAD ends by hand.
        try body.writer.flush();
        body.state = .end;
        try body.http_protocol_output.flush();
        return;
    }

    switch (source) {
        .bytes => |b| try body.writer.writeAll(b[@intCast(offset)..][0..@intCast(remaining)]),
        .file => |reader| {
            try reader.seekTo(offset);
            _ = try body.writer.sendFileAll(reader, .limited(@intCast(remaining)));
        },
        .virtual => |v| while (remaining > 0) {
            // Fill the writer's buffer directly to avoid an intermediate copy.
            const dst = try body.writer.writableSliceGreedy(1);
            const take: usize = @intCast(@min(@as(u64, dst.len), remaining));
            try v.read(v.ctx, offset, dst[0..take]);
            body.writer.advance(take);
            offset += take;
            remaining -= take;
        },
    }
    try body.end();
}

pub const Range = struct { start: u64, end: u64 };

/// Parses a single `bytes=` range against `total`. Null when there is no
/// header; error when the range cannot be satisfied.
pub fn parseRange(header_value: ?[]const u8, total: u64) error{Unsatisfiable}!?Range {
    const h = header_value orelse return null;
    if (!std.mem.startsWith(u8, h, "bytes=")) return null;
    const spec = h["bytes=".len..];
    if (std.mem.findScalar(u8, spec, ',') != null) return null; // multipart ranges: serve everything
    const first_last = std.mem.cutScalar(u8, spec, '-') orelse return error.Unsatisfiable;
    const first = std.mem.trim(u8, first_last[0], " ");
    const last = std.mem.trim(u8, first_last[1], " ");
    if (total == 0) return error.Unsatisfiable;

    if (first.len == 0) {
        // A suffix range: the last N bytes.
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
