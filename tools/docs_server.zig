//! Serves a directory on localhost and opens it in a browser, the way
//! `zig std` does: autodoc fetches `sources.tar` over HTTP, so the rendered
//! pages cannot be opened from disk.
//!
//! usage: docs-server <dir> [port]   (port 0, the default, is ephemeral)

const std = @import("std");
const Io = std.Io;

const Context = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or args.len > 3) {
        std.log.err("usage: docs-server <dir> [port]", .{});
        return error.BadUsage;
    }
    const port = if (args.len == 3) try std.fmt.parseInt(u16, args[2], 10) else 0;

    var dir = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.socket.close(io);

    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{listener.socket.address.getPort()});
    std.debug.print("serving the documentation at {s}\n", .{url});
    openBrowserTab(io, url) catch |err| std.log.warn("no browser opened: {t}", .{err});

    var context: Context = .{ .io = io, .gpa = init.gpa, .dir = dir };
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = try listener.accept(io);
        // Inline when no thread is free: the browser's other connections wait.
        group.concurrent(io, serveConnection, .{ &context, stream }) catch serveConnection(&context, stream);
    }
}

fn serveConnection(context: *Context, stream: Io.net.Stream) void {
    const io = context.io;
    defer stream.close(io);
    var in_buf: [4096]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch return;
        serveFile(context, &request) catch |err| {
            std.log.err("unable to serve {s}: {t}", .{ request.head.target, err });
            return;
        };
    }
}

fn serveFile(context: *Context, request: *std.http.Server.Request) !void {
    const path = std.mem.sliceTo(request.head.target, '?');
    const name = if (std.mem.eql(u8, path, "/")) "index.html" else path[1..];
    // Nothing outside the documentation directory is served.
    if (name.len == 0 or std.mem.findPosLinear(u8, name, 0, "..") != null) return notFound(request);

    const bytes = context.dir.readFileAlloc(context.io, name, context.gpa, .limited(64 * 1024 * 1024)) catch
        return notFound(request);
    defer context.gpa.free(bytes);
    // The pages are re-rendered under the same names, so nothing is cached.
    try request.respond(bytes, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = contentType(name) },
        .{ .name = "cache-control", .value = "max-age=0, must-revalidate" },
    } });
}

fn notFound(request: *std.http.Server.Request) !void {
    try request.respond("not found\n", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

/// The four types autodoc emits; anything else is downloaded rather than read.
fn contentType(name: []const u8) []const u8 {
    const types = .{
        .{ ".html", "text/html" },
        .{ ".js", "application/javascript" },
        .{ ".wasm", "application/wasm" },
        .{ ".tar", "application/x-tar" },
    };
    inline for (types) |t| {
        if (std.mem.endsWith(u8, name, t[0])) return t[1];
    }
    return "application/octet-stream";
}

/// Leaks the task: the browser opener may outlive the call, and the server
/// runs until it is interrupted anyway.
fn openBrowserTab(io: Io, url: []const u8) !void {
    _ = try io.concurrent(openBrowserTabTask, .{ io, url });
}

fn openBrowserTabTask(io: Io, url: []const u8) !void {
    const opener = switch (@import("builtin").os.tag) {
        .windows => "explorer",
        .macos => "open",
        else => "xdg-open",
    };
    var child = try std.process.spawn(io, .{
        .argv = &.{ opener, url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
}
